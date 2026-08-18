import CryptoKit
import Foundation

/// The single mutation boundary for adding user-provided wallpaper content to
/// the private Background Engine library.
public actor WallpaperImporter {
    public struct Limits: Sendable {
        public let maximumFiles: Int
        public let maximumBytes: UInt64

        public init(maximumFiles: Int = 100_000, maximumBytes: UInt64 = 20 * 1_024 * 1_024 * 1_024) {
            self.maximumFiles = maximumFiles
            self.maximumBytes = maximumBytes
        }
    }

    private let store: LibraryStore
    private let scanner: WallpaperScanner
    private let limits: Limits

    public init(store: LibraryStore, scanner: WallpaperScanner = WallpaperScanner(), limits: Limits = Limits()) {
        self.store = store
        self.scanner = scanner
        self.limits = limits
    }

    public func scan(root: URL) throws -> ScanResult {
        try validateTree(root)
        return try scanner.scan(root: root)
    }

    public func importAsset(_ asset: WallpaperAsset) throws -> WallpaperAsset {
        let source = URL(filePath: asset.projectDirectory).standardizedFileURL
        try validateTree(source)
        let contentHash = try WallpaperContentHasher.hashDirectory(source)
        if let existing = try duplicate(workshopID: asset.workshopId, contentHash: contentHash) {
            return existing
        }
        let enriched = asset.replacing(contentHash: contentHash)
        return try store.importAsset(enriched)
    }

    public func importVideoFile(_ url: URL) throws -> WallpaperAsset {
        try importStandaloneFile(url) { try store.importVideoFile($0) }
    }

    public func importMediaFile(_ url: URL) throws -> WallpaperAsset {
        try importStandaloneFile(url) { try store.importMediaFile($0) }
    }

    private func importStandaloneFile(
        _ url: URL,
        storeImport: (URL) throws -> WallpaperAsset
    ) throws -> WallpaperAsset {
        let source = url.standardizedFileURL
        try validateRegularFile(source)
        // LibraryStore owns the immutable staging snapshot, content probe,
        // hash-based deduplication and the single manifest commit.
        return try storeImport(source)
    }

    private func duplicate(workshopID: String?, contentHash: String) throws -> WallpaperAsset? {
        try store.load().assets.first { candidate in
            if let workshopID, candidate.workshopId == workshopID {
                return true
            }
            return candidate.contentHash == contentHash
        }
    }

    private func validateTree(_ root: URL) throws {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw WallpaperImportError.unsafeRoot(root.path)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw WallpaperImportError.cannotEnumerate(root.path)
        }

        var fileCount = 0
        var byteCount: UInt64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            if values.isSymbolicLink == true {
                throw WallpaperImportError.symbolicLink(url.path)
            }
            guard isInside(url, root: root) else {
                throw WallpaperImportError.pathEscape(url.path)
            }
            if values.isRegularFile == true {
                fileCount += 1
                byteCount += UInt64(max(0, values.fileSize ?? 0))
                if fileCount > limits.maximumFiles {
                    throw WallpaperImportError.tooManyFiles(fileCount, limits.maximumFiles)
                }
                if byteCount > limits.maximumBytes {
                    throw WallpaperImportError.tooLarge(byteCount, limits.maximumBytes)
                }
            }
        }
    }

    private func validateRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw WallpaperImportError.notRegularFile(url.path)
        }
        let size = UInt64(max(0, values.fileSize ?? 0))
        guard size <= limits.maximumBytes else {
            throw WallpaperImportError.tooLarge(size, limits.maximumBytes)
        }
    }

    private func isInside(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let urlComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard urlComponents.count > rootComponents.count else { return false }
        return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }
}

public enum WallpaperContentHasher {
    public static func hashDirectory(_ root: URL) throws -> String {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = canonicalRoot.pathComponents
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw WallpaperImportError.cannotEnumerate(root.path)
        }
        let files = enumerator.compactMap { item -> (path: String, url: URL)? in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
            let components = canonicalURL.pathComponents
            guard components.count > rootComponents.count,
                  Array(components.prefix(rootComponents.count)) == rootComponents else {
                return nil
            }
            let relativePath = components.dropFirst(rootComponents.count).joined(separator: "/")
                .precomposedStringWithCanonicalMapping
            return (relativePath, canonicalURL)
        }.sorted { $0.path < $1.path }

        var digest = SHA256()
        for file in files {
            digest.update(data: Data(file.path.utf8))
            digest.update(data: Data([0]))
            try update(&digest, from: file.url)
            digest.update(data: Data([0]))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func hashFile(_ url: URL) throws -> String {
        var digest = SHA256()
        try update(&digest, from: url)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func update(_ digest: inout SHA256, from url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            digest.update(data: data)
        }
    }
}

public enum WallpaperImportError: LocalizedError, Equatable {
    case unsafeRoot(String)
    case cannotEnumerate(String)
    case notRegularFile(String)
    case symbolicLink(String)
    case pathEscape(String)
    case tooManyFiles(Int, Int)
    case tooLarge(UInt64, UInt64)

    public var errorDescription: String? {
        switch self {
        case .unsafeRoot(let path): "The import root is not a safe directory: \(path)"
        case .cannotEnumerate(let path): "The import directory cannot be inspected: \(path)"
        case .notRegularFile(let path): "The selected item is not a regular file: \(path)"
        case .symbolicLink(let path): "Symbolic links are not allowed in imported projects: \(path)"
        case .pathEscape(let path): "A project item escapes the selected directory: \(path)"
        case .tooManyFiles(let actual, let limit): "The project has too many files (\(actual), limit \(limit))."
        case .tooLarge(let actual, let limit): "The project is too large (\(actual) bytes, limit \(limit))."
        }
    }
}

public extension WallpaperAsset {
    func replacing(
        contentHash: String? = nil,
        compatibility: SupportMode? = nil,
        compatibilityReport: CompatibilityReport? = nil,
        source: SourceKind? = nil
    ) -> WallpaperAsset {
        WallpaperAsset(
            id: id,
            title: title,
            kind: kind,
            supportStatus: supportStatus,
            source: source ?? self.source,
            projectDirectory: projectDirectory,
            entrypoint: entrypoint,
            thumbnail: thumbnail,
            workshopId: workshopId,
            dateAdded: dateAdded,
            contentHash: contentHash ?? self.contentHash,
            compatibility: compatibility ?? self.compatibility,
            compatibilityReport: compatibilityReport ?? self.compatibilityReport,
            allowsNetworkAccess: allowsNetworkAccess,
            redistributionAllowed: redistributionAllowed,
            issues: issues
        )
    }

    func allowingNetworkAccess(_ allowed: Bool) -> WallpaperAsset {
        WallpaperAsset(
            id: id,
            title: title,
            kind: kind,
            supportStatus: supportStatus,
            source: source,
            projectDirectory: projectDirectory,
            entrypoint: entrypoint,
            thumbnail: thumbnail,
            workshopId: workshopId,
            dateAdded: dateAdded,
            contentHash: contentHash,
            compatibility: compatibility,
            compatibilityReport: compatibilityReport,
            allowsNetworkAccess: allowed,
            redistributionAllowed: redistributionAllowed,
            issues: issues
        )
    }
}
