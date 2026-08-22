import Foundation
import CryptoKit

/// Copies user-selected Web wallpaper property files into the imported
/// asset. A WKWebView is only ever given URLs under this directory, never the
/// original security-scoped location.
public actor WebWallpaperUserFileStore {
    public static let shared = WebWallpaperUserFileStore()

    public struct Limits: Sendable {
        public let maximumFiles: Int
        public let maximumBytes: UInt64

        public init(maximumFiles: Int = 2_000, maximumBytes: UInt64 = 512 * 1_024 * 1_024) {
            self.maximumFiles = maximumFiles
            self.maximumBytes = maximumBytes
        }
    }

    public static let directoryName = ".background-engine-web-properties"
    public static let overridesFileName = "overrides.json"
    private let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public func copySelection(
        _ source: URL,
        propertyName: String,
        into assetDirectory: URL
    ) throws -> URL {
        let accessLock = WebWallpaperUserFileAccessLockRegistry.lock(for: assetDirectory)
        return try accessLock.withLock {
            try copySelectionLocked(source, propertyName: propertyName, into: assetDirectory)
        }
    }

    private func copySelectionLocked(
        _ source: URL,
        propertyName: String,
        into assetDirectory: URL
    ) throws -> URL {
        let assetRoot = assetDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let rootValues = try assetDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw WallpaperImportError.unsafeRoot(assetDirectory.path)
        }
        let storageRoot = assetDirectory.appending(path: Self.directoryName)
        let standardizedSource = source.standardizedFileURL
        let sourceValues = try standardizedSource.resourceValues(forKeys: [.isDirectoryKey])
        if sourceValues.isDirectory == true {
            let resolvedSource = standardizedSource.resolvingSymlinksInPath()
            let resolvedStorage = storageRoot.standardizedFileURL.resolvingSymlinksInPath()
            if resolvedStorage == resolvedSource || isInside(resolvedStorage, root: resolvedSource) {
                throw WallpaperImportError.unsafeRoot(source.path)
            }
        }
        try validate(standardizedSource)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let storageValues = try storageRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard storageValues.isDirectory == true, storageValues.isSymbolicLink != true else {
            throw WallpaperImportError.unsafeRoot(storageRoot.path)
        }
        guard isInside(storageRoot.resolvingSymlinksInPath(), root: assetRoot) else {
            throw WallpaperImportError.pathEscape(storageRoot.path)
        }
        let safeName = destinationName(propertyName: propertyName, source: source)
        let destination = storageRoot.appending(path: safeName)
        let incoming = storageRoot.appending(path: ".\(safeName).incoming-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: incoming) }
        try FileManager.default.copyItem(at: standardizedSource, to: incoming)
        try validate(incoming)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: incoming)
        } else {
            try FileManager.default.moveItem(at: incoming, to: destination)
        }
        try saveOverride(
            propertyName: propertyName,
            relativePath: "\(Self.directoryName)/\(safeName)",
            storageRoot: storageRoot
        )
        return destination
    }

    private func saveOverride(propertyName: String, relativePath: String, storageRoot: URL) throws {
        let url = storageRoot.appending(path: Self.overridesFileName)
        var overrides: [String: String] = [:]
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            overrides = decoded
        }
        overrides[propertyName] = relativePath
        try JSONEncoder().encode(overrides).write(to: url, options: [.atomic])
    }

    private func validate(_ source: URL) throws {
        let values = try source.resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isSymbolicLink != true else { throw WallpaperImportError.symbolicLink(source.path) }
        if values.isRegularFile == true {
            let size = UInt64(max(0, values.fileSize ?? 0))
            guard size <= limits.maximumBytes else {
                throw WallpaperImportError.tooLarge(size, limits.maximumBytes)
            }
            return
        }
        guard values.isDirectory == true else { throw WallpaperImportError.notRegularFile(source.path) }
        guard let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]
        ) else {
            throw WallpaperImportError.cannotEnumerate(source.path)
        }
        var fileCount = 0
        var byteCount: UInt64 = 0
        for case let candidate as URL in enumerator {
            let item = try candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            if item.isSymbolicLink == true { throw WallpaperImportError.symbolicLink(candidate.path) }
            guard isInside(candidate.resolvingSymlinksInPath(), root: source.resolvingSymlinksInPath()) else {
                throw WallpaperImportError.pathEscape(candidate.path)
            }
            if item.isRegularFile == true {
                fileCount += 1
                let size = UInt64(max(0, item.fileSize ?? 0))
                let (newByteCount, overflow) = byteCount.addingReportingOverflow(size)
                guard !overflow else {
                    throw WallpaperImportError.tooLarge(UInt64.max, limits.maximumBytes)
                }
                byteCount = newByteCount
                guard fileCount <= limits.maximumFiles else {
                    throw WallpaperImportError.tooManyFiles(fileCount, limits.maximumFiles)
                }
                guard byteCount <= limits.maximumBytes else {
                    throw WallpaperImportError.tooLarge(byteCount, limits.maximumBytes)
                }
            } else if item.isDirectory != true {
                throw WallpaperImportError.notRegularFile(candidate.path)
            }
        }
    }

    private func sanitized(_ value: String) -> String {
        let result = value.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        return result.isEmpty ? "property" : String(result.prefix(120))
    }

    private func destinationName(propertyName: String, source: URL) -> String {
        let digest = SHA256.hash(data: Data(propertyName.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let base = "\(sanitized(propertyName))-\(digest.prefix(16))"
        guard (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return base
        }
        let ext = sanitized(source.pathExtension)
        return source.pathExtension.isEmpty ? base : "\(base).\(ext)"
    }

    private func isInside(_ candidate: URL, root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}

private final class WebWallpaperUserFileAccessLock: @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private final class WeakWebWallpaperUserFileAccessLock: @unchecked Sendable {
    weak var value: WebWallpaperUserFileAccessLock?

    init(_ value: WebWallpaperUserFileAccessLock) {
        self.value = value
    }
}

private enum WebWallpaperUserFileAccessLockRegistry {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var locks: [String: WeakWebWallpaperUserFileAccessLock] = [:]

    static func lock(for assetDirectory: URL) -> WebWallpaperUserFileAccessLock {
        let key = assetDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[key]?.value {
            return existing
        }
        let created = WebWallpaperUserFileAccessLock()
        locks[key] = WeakWebWallpaperUserFileAccessLock(created)
        return created
    }
}
