import Foundation
import CryptoKit

/// Copies user-selected Web wallpaper property files into the imported
/// asset. A WKWebView is only ever given URLs under this directory, never the
/// original security-scoped location.
public actor WebWallpaperUserFileStore {
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
        let assetRoot = assetDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let rootValues = try assetDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw WallpaperImportError.unsafeRoot(assetDirectory.path)
        }
        try validate(source.standardizedFileURL)
        let storageRoot = assetDirectory.appending(path: Self.directoryName)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        guard isInside(storageRoot.resolvingSymlinksInPath(), root: assetRoot) else {
            throw WallpaperImportError.pathEscape(storageRoot.path)
        }
        let safeName = destinationName(propertyName: propertyName, source: source)
        let destination = storageRoot.appending(path: safeName)
        let incoming = storageRoot.appending(path: ".\(safeName).incoming-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: incoming) }
        try FileManager.default.copyItem(at: source.standardizedFileURL, to: incoming)
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
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw WallpaperImportError.cannotEnumerate(source.path)
        }
        var fileCount = 0
        var byteCount: UInt64 = 0
        for case let candidate as URL in enumerator {
            let item = try candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            if item.isSymbolicLink == true { throw WallpaperImportError.symbolicLink(candidate.path) }
            guard isInside(candidate.resolvingSymlinksInPath(), root: source.resolvingSymlinksInPath()) else {
                throw WallpaperImportError.pathEscape(candidate.path)
            }
            if item.isRegularFile == true {
                fileCount += 1
                byteCount += UInt64(max(0, item.fileSize ?? 0))
                guard fileCount <= limits.maximumFiles else {
                    throw WallpaperImportError.tooManyFiles(fileCount, limits.maximumFiles)
                }
                guard byteCount <= limits.maximumBytes else {
                    throw WallpaperImportError.tooLarge(byteCount, limits.maximumBytes)
                }
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
