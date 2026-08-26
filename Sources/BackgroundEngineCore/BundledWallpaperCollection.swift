import Darwin
import Foundation

/// An embedded, versioned collection shipped with Background Engine. The
/// catalog is deliberately independent from the app bundle so tests and
/// future optional collections can validate the exact same on-disk shape.
public struct BundledWallpaperCollectionCatalog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Entry: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let license: String
        public let licenseFiles: [String]
        public let sourceArchive: String
        public let sourceArchiveSHA256: String
        public let sourcePath: String
        public let contentHash: String
        public let limitedCapabilities: [WallpaperCapability]

        public init(
            id: String,
            title: String,
            license: String,
            licenseFiles: [String],
            sourceArchive: String,
            sourceArchiveSHA256: String,
            sourcePath: String,
            contentHash: String,
            limitedCapabilities: [WallpaperCapability] = []
        ) {
            self.id = id
            self.title = title
            self.license = license
            self.licenseFiles = licenseFiles
            self.sourceArchive = sourceArchive
            self.sourceArchiveSHA256 = sourceArchiveSHA256
            self.sourcePath = sourcePath
            self.contentHash = contentHash
            self.limitedCapabilities = limitedCapabilities
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case title
            case license
            case licenseFiles
            case sourceArchive
            case sourceArchiveSHA256
            case sourcePath
            case contentHash
            case limitedCapabilities
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            license = try container.decode(String.self, forKey: .license)
            licenseFiles = try container.decode([String].self, forKey: .licenseFiles)
            sourceArchive = try container.decode(String.self, forKey: .sourceArchive)
            sourceArchiveSHA256 = try container.decode(String.self, forKey: .sourceArchiveSHA256)
            sourcePath = try container.decode(String.self, forKey: .sourcePath)
            contentHash = try container.decode(String.self, forKey: .contentHash)
            limitedCapabilities = try container.decodeIfPresent(
                [WallpaperCapability].self,
                forKey: .limitedCapabilities
            ) ?? []
        }
    }

    public let schemaVersion: Int
    public let collectionID: String
    public let displayName: String
    public let sourceRepository: String
    public let sourceRelease: String
    public let sourceCommit: String
    public let sourceInstallerSHA256: String
    public let wallpapers: [Entry]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        collectionID: String,
        displayName: String,
        sourceRepository: String,
        sourceRelease: String,
        sourceCommit: String,
        sourceInstallerSHA256: String,
        wallpapers: [Entry]
    ) {
        self.schemaVersion = schemaVersion
        self.collectionID = collectionID
        self.displayName = displayName
        self.sourceRepository = sourceRepository
        self.sourceRelease = sourceRelease
        self.sourceCommit = sourceCommit
        self.sourceInstallerSHA256 = sourceInstallerSHA256
        self.wallpapers = wallpapers
    }
}

/// An opaque catalog-validated value. Its initializer is intentionally not
/// public, so callers cannot mark an arbitrary user import as redistributable
/// merely by constructing a WallpaperAsset with a bundled source enum.
public struct BundledWallpaperCandidate: Sendable {
    public let asset: WallpaperAsset

    init(asset: WallpaperAsset) {
        self.asset = asset
    }
}

public enum BundledWallpaperCollectionError: LocalizedError, Equatable {
    case unavailable
    case unsafeRoot(String)
    case catalogMissing
    case catalogNotRegular
    case catalogTooLarge
    case catalogMalformed
    case unsupportedSchema(Int)
    case emptyCollection
    case tooManyWallpapers(Int)
    case invalidIdentifier(String)
    case duplicateIdentifier(String)
    case identifierConflict(String)
    case unexpectedItem(String)
    case missingProject(String)
    case unsafeProject(String)
    case missingLicense(String, String)
    case invalidHash(String)
    case contentHashMismatch(String)
    case projectMismatch(String)
    case unsupportedWallpaper(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "The bundled wallpaper collection is not available in this build."
        case .unsafeRoot(let path):
            "The bundled wallpaper collection root is unsafe: \(path)"
        case .catalogMissing:
            "The bundled wallpaper catalog is missing."
        case .catalogNotRegular:
            "The bundled wallpaper catalog must be a regular file."
        case .catalogTooLarge:
            "The bundled wallpaper catalog exceeds its size limit."
        case .catalogMalformed:
            "The bundled wallpaper catalog is malformed."
        case .unsupportedSchema(let version):
            "Bundled wallpaper catalog schema \(version) is not supported."
        case .emptyCollection:
            "The bundled wallpaper catalog is empty."
        case .tooManyWallpapers(let count):
            "The bundled wallpaper catalog contains too many entries (\(count))."
        case .invalidIdentifier(let id):
            "Bundled wallpaper identifier is invalid: \(id)"
        case .duplicateIdentifier(let id):
            "Bundled wallpaper identifier is duplicated: \(id)"
        case .identifierConflict(let id):
            "Bundled wallpaper \(id) conflicts with a non-bundled library item."
        case .unexpectedItem(let name):
            "The bundled wallpaper collection contains an uncatalogued item: \(name)"
        case .missingProject(let id):
            "Bundled wallpaper \(id) is missing."
        case .unsafeProject(let id):
            "Bundled wallpaper \(id) is not a safe project directory."
        case .missingLicense(let id, let path):
            "Bundled wallpaper \(id) is missing its license notice: \(path)"
        case .invalidHash(let id):
            "Bundled wallpaper \(id) has an invalid catalog hash."
        case .contentHashMismatch(let id):
            "Bundled wallpaper \(id) does not match its embedded catalog hash."
        case .projectMismatch(let id):
            "Bundled wallpaper \(id) does not match its catalog metadata."
        case .unsupportedWallpaper(let id):
            "Bundled wallpaper \(id) is not a playable Web wallpaper."
        }
    }
}

/// Validates and scans a bundled collection before any item reaches the
/// user's private library. Installation still goes through
/// ``WallpaperImporter`` so the same atomic copy and deduplication rules used
/// for Workshop and manual content remain authoritative.
public actor BundledWallpaperCollection {
    public static let catalogFileName = "catalog.json"
    public static let maximumCatalogBytes = 1 * 1_024 * 1_024
    public static let maximumWallpaperCount = 100

    private let root: URL
    private let store: LibraryStore

    public init(root: URL, store: LibraryStore) {
        self.root = root.standardizedFileURL
        self.store = store
    }

    public func candidates() async throws -> [BundledWallpaperCandidate] {
        let canonicalRoot = try validatedRoot()
        let catalog = try loadCatalog(from: canonicalRoot)
        try validateCatalog(catalog)
        try validateNoUncataloguedItems(catalog, root: canonicalRoot)
        // A malformed or legacy manifest can contain duplicate IDs. Reject a
        // catalog ID when any matching entry is user-owned, regardless of its
        // order, so installation can never discard a later duplicate.
        let conflictingIdentifiers = Set(
            try store.load().assets.lazy
                .filter { $0.source != .bundledLively }
                .map(\.id)
        )

        let importer = WallpaperImporter(store: store)
        var candidates = [BundledWallpaperCandidate]()
        candidates.reserveCapacity(catalog.wallpapers.count)
        for entry in catalog.wallpapers {
            try Task.checkCancellation()
            if conflictingIdentifiers.contains(entry.id) {
                throw BundledWallpaperCollectionError.identifierConflict(entry.id)
            }
            let directory = try validatedProjectDirectory(entry.id, root: canonicalRoot)
            try validateLicenseFiles(entry, directory: directory)
            guard isSHA256(entry.contentHash), isSHA256(entry.sourceArchiveSHA256) else {
                throw BundledWallpaperCollectionError.invalidHash(entry.id)
            }
            let contentHash = try WallpaperContentHasher.hashDirectory(directory)
            guard contentHash == entry.contentHash.lowercased() else {
                throw BundledWallpaperCollectionError.contentHashMismatch(entry.id)
            }
            let result = try await importer.scan(root: directory)
            guard result.assets.count == 1,
                  let scanned = result.assets.first,
                  scanned.id == entry.id,
                  scanned.title == entry.title else {
                throw BundledWallpaperCollectionError.projectMismatch(entry.id)
            }
            guard scanned.kind == .web,
                  scanned.supportStatus == .playable,
                  scanned.compatibilityReport?.level != .unsupported else {
                throw BundledWallpaperCollectionError.unsupportedWallpaper(entry.id)
            }
            let catalogReport = try report(
                applying: entry.limitedCapabilities,
                to: scanned.compatibilityReport,
                wallpaperID: entry.id
            )
            let asset = scanned.replacing(
                contentHash: contentHash,
                compatibility: catalogReport?.supportMode,
                compatibilityReport: catalogReport,
                source: .bundledLively,
                redistributionAllowed: true
            )
            candidates.append(BundledWallpaperCandidate(asset: asset))
        }
        return candidates
    }

    private func report(
        applying limitedCapabilities: [WallpaperCapability],
        to scannedReport: CompatibilityReport?,
        wallpaperID: String
    ) throws -> CompatibilityReport? {
        guard !limitedCapabilities.isEmpty else { return scannedReport }
        guard Set(limitedCapabilities).count == limitedCapabilities.count,
              limitedCapabilities.allSatisfy({ $0 == .interaction }),
              let scannedReport,
              scannedReport.playbackPath == .webLive,
              scannedReport.level != .unsupported else {
            throw BundledWallpaperCollectionError.projectMismatch(wallpaperID)
        }
        let warning = "Pointer interaction is unavailable while the desktop wallpaper window ignores input."
        return CompatibilityReport(
            level: .limited,
            playbackPath: scannedReport.playbackPath,
            requiredCapabilities: scannedReport.requiredCapabilities + limitedCapabilities,
            missingCapabilities: scannedReport.missingCapabilities + limitedCapabilities,
            warnings: scannedReport.warnings.contains(warning)
                ? scannedReport.warnings
                : scannedReport.warnings + [warning],
            diagnosticCode: scannedReport.missingCapabilities.isEmpty
                ? "web_interaction_limited"
                : "web_runtime_limited"
        )
    }

    public func catalog() throws -> BundledWallpaperCollectionCatalog {
        let canonicalRoot = try validatedRoot()
        let catalog = try loadCatalog(from: canonicalRoot)
        try validateCatalog(catalog)
        return catalog
    }

    private func validatedRoot() throws -> URL {
        var attributes = stat()
        let status = root.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &attributes)
        }
        guard status == 0,
              attributes.st_mode & S_IFMT == S_IFDIR,
              root.path != "/",
              root.lastPathComponent == "LivelyWallpapers" else {
            throw BundledWallpaperCollectionError.unsafeRoot(root.path)
        }
        return root.resolvingSymlinksInPath()
    }

    private func loadCatalog(from root: URL) throws -> BundledWallpaperCollectionCatalog {
        let url = root.appending(path: Self.catalogFileName)
        var attributes = stat()
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            if FileManager.default.fileExists(atPath: url.path) {
                throw BundledWallpaperCollectionError.catalogNotRegular
            }
            throw BundledWallpaperCollectionError.catalogMissing
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG else {
            throw BundledWallpaperCollectionError.catalogNotRegular
        }
        guard attributes.st_size >= 0,
              attributes.st_size <= Self.maximumCatalogBytes else {
            throw BundledWallpaperCollectionError.catalogTooLarge
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let bytesRead = Darwin.read(descriptor, &buffer, buffer.count)
            if bytesRead == 0 { break }
            guard bytesRead > 0 else {
                if errno == EINTR { continue }
                throw BundledWallpaperCollectionError.catalogMalformed
            }
            guard bytesRead <= Self.maximumCatalogBytes - data.count else {
                throw BundledWallpaperCollectionError.catalogTooLarge
            }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }
        do {
            return try JSONDecoder().decode(BundledWallpaperCollectionCatalog.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BundledWallpaperCollectionError.catalogMalformed
        }
    }

    private func validateCatalog(_ catalog: BundledWallpaperCollectionCatalog) throws {
        guard catalog.schemaVersion == BundledWallpaperCollectionCatalog.currentSchemaVersion else {
            throw BundledWallpaperCollectionError.unsupportedSchema(catalog.schemaVersion)
        }
        guard !catalog.wallpapers.isEmpty else {
            throw BundledWallpaperCollectionError.emptyCollection
        }
        guard catalog.wallpapers.count <= Self.maximumWallpaperCount else {
            throw BundledWallpaperCollectionError.tooManyWallpapers(catalog.wallpapers.count)
        }
        var identifiers = Set<String>()
        for entry in catalog.wallpapers {
            guard isSafeIdentifier(entry.id) else {
                throw BundledWallpaperCollectionError.invalidIdentifier(entry.id)
            }
            guard identifiers.insert(entry.id).inserted else {
                throw BundledWallpaperCollectionError.duplicateIdentifier(entry.id)
            }
            guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.licenseFiles.isEmpty,
                  !entry.sourceArchive.isEmpty,
                  !entry.sourcePath.isEmpty else {
                throw BundledWallpaperCollectionError.projectMismatch(entry.id)
            }
        }
    }

    private func validateNoUncataloguedItems(
        _ catalog: BundledWallpaperCollectionCatalog,
        root: URL
    ) throws {
        let expected = Set(catalog.wallpapers.map(\.id)).union([Self.catalogFileName])
        let items = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isHiddenKey],
            options: [.skipsHiddenFiles]
        )
        for item in items where !expected.contains(item.lastPathComponent) {
            throw BundledWallpaperCollectionError.unexpectedItem(item.lastPathComponent)
        }
    }

    private func validatedProjectDirectory(_ id: String, root: URL) throws -> URL {
        let directory = root.appending(path: id).standardizedFileURL
        let rootComponents = root.pathComponents
        let resolved = directory.resolvingSymlinksInPath()
        guard resolved.pathComponents.count == rootComponents.count + 1,
              Array(resolved.pathComponents.prefix(rootComponents.count)) == rootComponents else {
            throw BundledWallpaperCollectionError.unsafeProject(id)
        }
        var attributes = stat()
        let status = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &attributes)
        }
        guard status == 0 else {
            throw BundledWallpaperCollectionError.missingProject(id)
        }
        guard attributes.st_mode & S_IFMT == S_IFDIR,
              directory.path == resolved.path else {
            throw BundledWallpaperCollectionError.unsafeProject(id)
        }
        return directory
    }

    private func validateLicenseFiles(
        _ entry: BundledWallpaperCollectionCatalog.Entry,
        directory: URL
    ) throws {
        let rootComponents = directory.pathComponents
        for relativePath in entry.licenseFiles {
            guard isSafeRelativePath(relativePath) else {
                throw BundledWallpaperCollectionError.missingLicense(entry.id, relativePath)
            }
            let candidate = directory.appending(path: relativePath).standardizedFileURL
            let resolved = candidate.resolvingSymlinksInPath()
            var attributes = stat()
            let status = candidate.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.lstat(path, &attributes)
            }
            guard status == 0,
                  attributes.st_mode & S_IFMT == S_IFREG,
                  resolved.pathComponents.count > rootComponents.count,
                  Array(resolved.pathComponents.prefix(rootComponents.count)) == rootComponents,
                  candidate.path == resolved.path else {
                throw BundledWallpaperCollectionError.missingLicense(entry.id, relativePath)
            }
        }
    }

    private func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128,
              value.first?.isLetter == true,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return false
        }
        return value != "." && value != ".."
    }

    private func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func isSHA256(_ value: String) -> Bool {
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        return value.utf8.count == 64
            && value.lowercased().unicodeScalars.allSatisfy(hexadecimal.contains)
    }
}
