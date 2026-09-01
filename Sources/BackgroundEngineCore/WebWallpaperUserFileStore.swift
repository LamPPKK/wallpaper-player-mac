import Foundation
import CryptoKit

public enum WebWallpaperMetadataFileReader {
    public static let maximumProjectMetadataBytes = 1_048_576
    public static let maximumAuxiliaryMetadataBytes = WebWallpaperUserFileStore.maximumOverrideMetadataBytes

    /// Reads runtime metadata without following a symlink or blocking on a
    /// FIFO/device. Legacy libraries and files changed after import still
    /// cross this boundary immediately before playback or compatibility work.
    public static func data(at url: URL, maximumByteCount: Int) -> Data? {
        guard case .data(let data) = read(
            at: url,
            maximumByteCount: maximumByteCount
        ) else {
            return nil
        }
        return data
    }

    /// Describes the result of opening a metadata file through one pinned
    /// descriptor. Callers that assign meaning to a metadata file's presence
    /// must not turn an unsafe, unreadable, or oversized file into "absent".
    public enum ReadResult: Equatable, Sendable {
        case absent
        case data(Data)
        case invalid
    }

    public static func read(at url: URL, maximumByteCount: Int) -> ReadResult {
        guard maximumByteCount >= 0 else { return .invalid }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            return errno == ENOENT ? .absent : .invalid
        }
        defer { Darwin.close(descriptor) }

        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size >= 0,
              attributes.st_size <= maximumByteCount else {
            return .invalid
        }

        var data = Data()
        data.reserveCapacity(Int(attributes.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let bytesRead = Darwin.read(descriptor, &buffer, buffer.count)
            if bytesRead == 0 { return .data(data) }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return .invalid
            }
            guard bytesRead <= maximumByteCount - data.count else { return .invalid }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }
    }
}

public enum RemoteWebWallpaperConfigurationInvalidReason: String, Equatable, Sendable {
    case unsafeOrUnreadableMetadata
    case malformedMetadata
    case unsupportedSchema
    case invalidTargetURL
}

public enum RemoteWebWallpaperConfigurationState: Equatable, Sendable {
    case absent
    case valid(RemoteWebWallpaperConfiguration)
    case invalid(RemoteWebWallpaperConfigurationInvalidReason)
}

public struct RemoteWebWallpaperConfiguration: Codable, Equatable, Sendable {
    public static let fileName = ".background-engine-web.json"
    public static let currentSchemaVersion = 1
    public static let maximumMetadataBytes = 16 * 1_024

    public let schemaVersion: Int
    public let targetURL: URL

    public init(targetURL: URL, schemaVersion: Int = currentSchemaVersion) throws {
        guard let scheme = targetURL.scheme?.lowercased(),
              scheme == "https",
              let host = targetURL.host,
              !host.isEmpty,
              !WebWallpaperNetworkPolicy.isBlockedExternalHost(host),
              targetURL.user == nil,
              targetURL.password == nil,
              targetURL.absoluteString.utf8.count <= 4_096 else {
            throw RemoteWebWallpaperConfigurationError.invalidURL
        }
        self.schemaVersion = schemaVersion
        self.targetURL = targetURL
    }

    public static func load(projectRoot: URL) -> RemoteWebWallpaperConfiguration? {
        guard case .valid(let configuration) = state(projectRoot: projectRoot) else {
            return nil
        }
        return configuration
    }

    /// Distinguishes a normal local Web project (no remote metadata) from a
    /// generated website project whose metadata was corrupted, replaced by a
    /// symlink, or written by an incompatible/legacy build. The file is read
    /// and validated from one no-follow descriptor so its presence cannot be
    /// checked separately from the bytes being decoded.
    public static func state(projectRoot: URL) -> RemoteWebWallpaperConfigurationState {
        let url = projectRoot.appending(path: fileName)
        switch WebWallpaperMetadataFileReader.read(
            at: url,
            maximumByteCount: maximumMetadataBytes
        ) {
        case .absent:
            return .absent
        case .invalid:
            return .invalid(.unsafeOrUnreadableMetadata)
        case .data(let data):
            guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
                return .invalid(.malformedMetadata)
            }
            guard decoded.schemaVersion == currentSchemaVersion else {
                return .invalid(.unsupportedSchema)
            }
            guard let validated = try? Self(
                targetURL: decoded.targetURL,
                schemaVersion: decoded.schemaVersion
            ) else {
                return .invalid(.invalidTargetURL)
            }
            return .valid(validated)
        }
    }
}

public enum RemoteWebWallpaperConfigurationError: LocalizedError, Equatable, Sendable {
    case invalidURL

    public var errorDescription: String? {
        "The remote Web wallpaper URL must use HTTPS, cannot contain credentials, and cannot target a literal local or private host."
    }
}

/// A persisted scalar value for a Wallpaper Engine Web user property.
///
/// File and directory properties keep using ``overridesFileName`` because
/// their values are sandbox-relative paths. Scalar values are stored in a
/// separate typed document so untrusted JSON cannot change a value's type
/// between the property editor and the Web bootstrap bridge.
public enum WebWallpaperPropertyOverrideValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case text(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum ValueType: String, Codable {
        case bool
        case number
        case text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .number:
            let value = try container.decode(Double.self, forKey: .value)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Web property numbers must be finite."
                )
            }
            self = .number(value)
        case .text:
            self = .text(try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let value):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(value, forKey: .value)
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Web property numbers must be finite."
                    )
                )
            }
            try container.encode(ValueType.number, forKey: .type)
            try container.encode(value, forKey: .value)
        case .text(let value):
            try container.encode(ValueType.text, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

protocol WebWallpaperMetadataCommitting: Sendable {
    func commit(incoming: URL, destination: URL) throws
    func commit(
        incomingName: String,
        destinationName: String,
        directoryDescriptor: Int32
    ) throws
}

private let webWallpaperMetadataRollbackErrorDomain =
    "com.lamppkk.backgroundengine.web-metadata-rollback"

struct AtomicWebWallpaperMetadataCommitter: WebWallpaperMetadataCommitting {
    func commit(incoming: URL, destination: URL) throws {
        let result = incoming.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        // Persist the directory entry as well as the file contents. A crash is
        // therefore observed as either the complete old document or the
        // complete new document, never a missing metadata file between moves.
        let directory = destination.deletingLastPathComponent()
        let descriptor = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC)
        }
        if descriptor >= 0 {
            defer { Darwin.close(descriptor) }
            _ = Darwin.fsync(descriptor)
        }
    }

    func commit(
        incomingName: String,
        destinationName: String,
        directoryDescriptor: Int32
    ) throws {
        let result = incomingName.withCString { incomingPath in
            destinationName.withCString { destinationPath in
                Darwin.renameat(
                    directoryDescriptor,
                    incomingPath,
                    directoryDescriptor,
                    destinationPath
                )
            }
        }
        guard result == 0, Darwin.fsync(directoryDescriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

enum WebWallpaperLivelyCopyEvent: Sendable {
    case sourceOpened
    case destinationFolderOpened
    case privateFileCopied
}

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
    public static let valueOverridesFileName = "values.json"
    public static let folderDropdownFilesFileName = "folder-dropdown-files.json"
    public static let folderDropdownFilesDirectoryName = "folder-dropdown-files"
    public static let maximumOverrideMetadataBytes = 1_048_576
    public static let maximumScalarProperties = 1_000
    public static let maximumPropertyNameBytes = 512
    public static let maximumTextValueBytes = 64 * 1_024
    private let limits: Limits
    private let metadataCommitter: any WebWallpaperMetadataCommitting
    private let livelyCopyObserver: (@Sendable (WebWallpaperLivelyCopyEvent) -> Void)?

    public init(limits: Limits = Limits()) {
        self.limits = limits
        metadataCommitter = AtomicWebWallpaperMetadataCommitter()
        livelyCopyObserver = nil
    }

    init(
        limits: Limits = Limits(),
        metadataCommitter: any WebWallpaperMetadataCommitting,
        livelyCopyObserver: (@Sendable (WebWallpaperLivelyCopyEvent) -> Void)? = nil
    ) {
        self.limits = limits
        self.metadataCommitter = metadataCommitter
        self.livelyCopyObserver = livelyCopyObserver
    }

    public func copySelection(
        _ source: URL,
        propertyName: String,
        into assetDirectory: URL
    ) throws -> URL {
        let accessLock = WallpaperAssetMutationLockRegistry.lock(for: assetDirectory)
        return try accessLock.withLock {
            try copySelectionLocked(source, propertyName: propertyName, into: assetDirectory)
        }
    }

    /// Matches Lively's folder-dropdown copy semantics inside the app-owned
    /// project copy. The authored folder and original filename are preserved,
    /// while collisions receive a numbered filename and the source file never
    /// becomes visible to WebKit.
    public func copyLivelyFolderDropdownSelection(
        _ source: URL,
        propertyName: String,
        projectRelativeFolder: String,
        allowedExtensions: [String]?,
        into assetDirectory: URL
    ) throws -> URL {
        let accessLock = WallpaperAssetMutationLockRegistry.lock(for: assetDirectory)
        return try accessLock.withLock {
            try copyLivelyFolderDropdownSelectionLocked(
                source,
                propertyName: propertyName,
                projectRelativeFolder: projectRelativeFolder,
                allowedExtensions: allowedExtensions,
                into: assetDirectory
            )
        }
    }

    /// Copies multiple files selected for one Lively folder dropdown while
    /// holding the asset mutation lock for the complete batch. Every copied
    /// file remains available as an option and the final file becomes the
    /// active selection, matching Lively's multi-file picker behavior.
    public func copyLivelyFolderDropdownSelections(
        _ sources: [URL],
        propertyName: String,
        projectRelativeFolder: String,
        allowedExtensions: [String]?,
        into assetDirectory: URL
    ) throws -> [URL] {
        guard !sources.isEmpty else {
            throw WallpaperImportError.notRegularFile("Choose at least one file.")
        }
        guard sources.count <= limits.maximumFiles else {
            throw WallpaperImportError.tooManyFiles(sources.count, limits.maximumFiles)
        }
        let accessLock = WallpaperAssetMutationLockRegistry.lock(for: assetDirectory)
        return try accessLock.withLock {
            let existingMappingCount: Int
            if let storageRoot = try existingValidatedStorageRoot(in: assetDirectory) {
                existingMappingCount = try loadOverrides(
                    at: storageRoot.appending(path: Self.folderDropdownFilesFileName)
                ).count
            } else {
                existingMappingCount = 0
            }
            guard existingMappingCount <= limits.maximumFiles,
                  sources.count <= limits.maximumFiles - existingMappingCount else {
                throw WallpaperImportError.tooManyFiles(
                    existingMappingCount + sources.count,
                    limits.maximumFiles
                )
            }
            return try sources.map { source in
                try copyLivelyFolderDropdownSelectionLocked(
                    source,
                    propertyName: propertyName,
                    projectRelativeFolder: projectRelativeFolder,
                    allowedExtensions: allowedExtensions,
                    into: assetDirectory
                )
            }
        }
    }

    /// Deletes one app-managed Lively folder-dropdown copy. Authored project
    /// files are never eligible. The mapping and every affected selection are
    /// removed together before the private file is cleaned up, so a crash can
    /// leave an inaccessible orphan but never an active missing-file mapping.
    public func deleteLivelyFolderDropdownFile(
        projectRelativePath: String,
        callbackValue: String,
        affectedPropertyNames: Set<String>,
        from assetDirectory: URL
    ) throws -> Bool {
        let accessLock = WallpaperAssetMutationLockRegistry.lock(for: assetDirectory)
        return try accessLock.withLock {
            try deleteLivelyFolderDropdownFileLocked(
                projectRelativePath: projectRelativePath,
                callbackValue: callbackValue,
                affectedPropertyNames: affectedPropertyNames,
                from: assetDirectory
            )
        }
    }

    /// Stops using a sandboxed file for one Web property without deleting the
    /// copied bytes. Keeping the private copy makes a failed metadata update
    /// recoverable and lets a later selection replace it atomically.
    public func clearSelection(
        propertyName: String,
        from assetDirectory: URL
    ) throws {
        let accessLock = WallpaperAssetMutationLockRegistry.lock(for: assetDirectory)
        try accessLock.withLock {
            let nameBytes = propertyName.lengthOfBytes(using: .utf8)
            guard !propertyName.isEmpty,
                  !propertyName.contains("\0"),
                  nameBytes <= Self.maximumPropertyNameBytes else {
                throw WallpaperImportError.notRegularFile("Invalid Web property name.")
            }
            guard let storageRoot = try existingValidatedStorageRoot(in: assetDirectory) else {
                return
            }
            let overridesURL = storageRoot.appending(path: Self.overridesFileName)
            var overrides = try loadOverrides(at: overridesURL)
            guard overrides.removeValue(forKey: propertyName) != nil else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(overrides)
            guard data.count <= Self.maximumOverrideMetadataBytes else {
                throw WallpaperImportError.tooLarge(
                    UInt64(data.count),
                    UInt64(Self.maximumOverrideMetadataBytes)
                )
            }
            try replaceMetadataFile(
                named: Self.overridesFileName,
                data: data,
                in: storageRoot
            )
        }
    }

    /// Atomically replaces every scalar override for one imported Web asset.
    /// Callers pass the complete editor state so Reset can remove stale keys
    /// without a read/modify/write race with another store instance.
    public func saveValueOverrides(
        _ overrides: [String: WebWallpaperPropertyOverrideValue],
        into assetDirectory: URL
    ) throws {
        let accessLock = WallpaperAssetMutationLockRegistry.lock(for: assetDirectory)
        try accessLock.withLock {
            try saveValueOverridesLocked(
                overrides,
                clearingFileSelections: [],
                into: assetDirectory
            )
        }
    }

    /// Publishes scalar overrides and clears selected file overrides as one
    /// locked transaction. If either metadata commit fails, both previous
    /// documents are restored before the error is returned.
    public func saveValueOverrides(
        _ overrides: [String: WebWallpaperPropertyOverrideValue],
        clearingFileSelections: Set<String>,
        into assetDirectory: URL
    ) throws {
        let accessLock = WallpaperAssetMutationLockRegistry.lock(for: assetDirectory)
        try accessLock.withLock {
            try saveValueOverridesLocked(
                overrides,
                clearingFileSelections: clearingFileSelections,
                into: assetDirectory
            )
        }
    }

    public func loadValueOverrides(
        from assetDirectory: URL
    ) throws -> [String: WebWallpaperPropertyOverrideValue] {
        let accessLock = WallpaperAssetMutationLockRegistry.lock(for: assetDirectory)
        return try accessLock.withLock {
            guard let storageRoot = try existingValidatedStorageRoot(in: assetDirectory) else {
                return [:]
            }
            let url = storageRoot.appending(path: Self.valueOverridesFileName)
            let data = try loadMetadataData(at: url)
            guard !data.isEmpty else { return [:] }
            let decoded = try JSONDecoder().decode(
                [String: WebWallpaperPropertyOverrideValue].self,
                from: data
            )
            try validateValueOverrides(decoded)
            return decoded
        }
    }

    private func saveValueOverridesLocked(
        _ overrides: [String: WebWallpaperPropertyOverrideValue],
        clearingFileSelections: Set<String>,
        into assetDirectory: URL
    ) throws {
        try validateValueOverrides(overrides)
        guard clearingFileSelections.count <= Self.maximumScalarProperties else {
            throw WallpaperImportError.tooManyFiles(
                clearingFileSelections.count,
                Self.maximumScalarProperties
            )
        }
        for propertyName in clearingFileSelections {
            try validatePropertyName(propertyName)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let valueData = try encoder.encode(overrides)
        guard valueData.count <= Self.maximumOverrideMetadataBytes else {
            throw WallpaperImportError.tooLarge(
                UInt64(valueData.count),
                UInt64(Self.maximumOverrideMetadataBytes)
            )
        }

        // Validate every value before creating the private metadata directory.
        // The asset and storage directories stay pinned for every load, stage,
        // backup, and rename in this transaction.
        let assetRoot = try openPinnedAssetDirectory(assetDirectory)
        defer { Darwin.close(assetRoot.descriptor) }
        let diagnosticRoot = assetDirectory.appending(path: Self.directoryName)
        let storage = try openOrCreateDirectory(
            named: Self.directoryName,
            beneath: assetRoot.descriptor,
            diagnosticPath: diagnosticRoot.path
        )
        defer { Darwin.close(storage.descriptor) }
        guard !clearingFileSelections.isEmpty else {
            try replaceMetadataFilesAtomically(
                [Self.valueOverridesFileName: valueData],
                inDirectoryDescriptor: storage.descriptor,
                diagnosticRoot: diagnosticRoot
            )
            return
        }

        var fileOverrides = try loadStringMap(
            named: Self.overridesFileName,
            from: storage.descriptor,
            diagnosticRoot: diagnosticRoot
        )
        var removedFileSelection = false
        for propertyName in clearingFileSelections {
            removedFileSelection = fileOverrides.removeValue(forKey: propertyName) != nil
                || removedFileSelection
        }
        guard removedFileSelection else {
            try replaceMetadataFilesAtomically(
                [Self.valueOverridesFileName: valueData],
                inDirectoryDescriptor: storage.descriptor,
                diagnosticRoot: diagnosticRoot
            )
            return
        }

        let fileOverrideData = try encoder.encode(fileOverrides)
        guard fileOverrideData.count <= Self.maximumOverrideMetadataBytes else {
            throw WallpaperImportError.tooLarge(
                UInt64(fileOverrideData.count),
                UInt64(Self.maximumOverrideMetadataBytes)
            )
        }
        try replaceMetadataFilesAtomically(
            [
                Self.valueOverridesFileName: valueData,
                Self.overridesFileName: fileOverrideData
            ],
            inDirectoryDescriptor: storage.descriptor,
            diagnosticRoot: diagnosticRoot
        )
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
        let overridesURL = storageRoot.appending(path: Self.overridesFileName)
        let overridesIncoming = storageRoot.appending(
            path: ".\(Self.overridesFileName).incoming-\(UUID().uuidString)"
        )
        let destinationBackup = storageRoot.appending(
            path: ".\(safeName).previous-\(UUID().uuidString)"
        )
        let overridesBackup = storageRoot.appending(
            path: ".\(Self.overridesFileName).previous-\(UUID().uuidString)"
        )
        var transactionCommitted = false
        defer {
            try? FileManager.default.removeItem(at: incoming)
            try? FileManager.default.removeItem(at: overridesIncoming)
            if transactionCommitted {
                try? FileManager.default.removeItem(at: destinationBackup)
                try? FileManager.default.removeItem(at: overridesBackup)
            }
        }

        var overrides = try loadOverrides(at: overridesURL)
        overrides[propertyName] = "\(Self.directoryName)/\(safeName)"
        let encodedOverrides = try JSONEncoder().encode(overrides)
        guard encodedOverrides.count <= Self.maximumOverrideMetadataBytes else {
            throw WallpaperImportError.tooLarge(
                UInt64(encodedOverrides.count),
                UInt64(Self.maximumOverrideMetadataBytes)
            )
        }
        try encodedOverrides.write(to: overridesIncoming, options: [.withoutOverwriting])
        try FileManager.default.copyItem(at: standardizedSource, to: incoming)
        try validate(incoming)

        let hadDestination = FileManager.default.fileExists(atPath: destination.path)
        let hadOverrides = FileManager.default.fileExists(atPath: overridesURL.path)
        var destinationInstalled = false
        var destinationRetired = false
        var overridesRetired = false
        do {
            if hadDestination {
                try FileManager.default.moveItem(at: destination, to: destinationBackup)
                destinationRetired = true
            }
            try FileManager.default.moveItem(at: incoming, to: destination)
            destinationInstalled = true
            if hadOverrides {
                try FileManager.default.moveItem(at: overridesURL, to: overridesBackup)
                overridesRetired = true
            }
            try FileManager.default.moveItem(at: overridesIncoming, to: overridesURL)
        } catch {
            if overridesRetired {
                try? FileManager.default.moveItem(at: overridesBackup, to: overridesURL)
            }
            if destinationInstalled {
                try? FileManager.default.moveItem(at: destination, to: incoming)
            }
            if destinationRetired {
                try? FileManager.default.moveItem(at: destinationBackup, to: destination)
            }
            throw error
        }
        transactionCommitted = true
        return destination
    }

    private func copyLivelyFolderDropdownSelectionLocked(
        _ source: URL,
        propertyName: String,
        projectRelativeFolder: String,
        allowedExtensions: [String]?,
        into assetDirectory: URL
    ) throws -> URL {
        try validatePropertyName(propertyName)
        let standardizedSource = source.standardizedFileURL
        if let allowedExtensions {
            guard !allowedExtensions.isEmpty,
                  allowedExtensions.contains(standardizedSource.pathExtension.lowercased()) else {
                throw WallpaperImportError.notRegularFile(
                    "The selected file does not match the Lively folder filter."
                )
            }
        }
        let originalName = standardizedSource.lastPathComponent
        guard !originalName.isEmpty,
              originalName != ".",
              originalName != "..",
              !originalName.contains("\\"),
              !originalName.contains("\0"),
              !originalName.unicodeScalars.contains(
                  where: CharacterSet.controlCharacters.contains
              ),
              originalName.lengthOfBytes(using: .utf8) <= 240 else {
            throw WallpaperImportError.notRegularFile(source.path)
        }

        let sourceDescriptor = standardizedSource.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard sourceDescriptor >= 0 else {
            if errno == ELOOP { throw WallpaperImportError.symbolicLink(source.path) }
            throw WallpaperImportError.notRegularFile(source.path)
        }
        defer { Darwin.close(sourceDescriptor) }
        var sourceAttributes = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceAttributes) == 0,
              sourceAttributes.st_mode & S_IFMT == S_IFREG,
              sourceAttributes.st_size >= 0 else {
            throw WallpaperImportError.notRegularFile(source.path)
        }
        let sourceSize = UInt64(sourceAttributes.st_size)
        guard sourceSize <= limits.maximumBytes else {
            throw WallpaperImportError.tooLarge(sourceSize, limits.maximumBytes)
        }
        livelyCopyObserver?(.sourceOpened)

        let assetRoot = try openPinnedAssetDirectory(assetDirectory)
        let canonicalAssetPath = assetRoot.canonicalPath
        defer { Darwin.close(assetRoot.descriptor) }
        let folderComponents = try validatedRelativePathComponents(projectRelativeFolder)
        let destinationFolder = try openDirectory(
            components: folderComponents,
            beneath: assetRoot.descriptor,
            diagnosticPath: assetDirectory.appending(path: projectRelativeFolder).path
        )
        defer { Darwin.close(destinationFolder.descriptor) }
        livelyCopyObserver?(.destinationFolderOpened)
        let storage = try openOrCreateDirectory(
            named: Self.directoryName,
            beneath: assetRoot.descriptor,
            diagnosticPath: assetDirectory.appending(path: Self.directoryName).path
        )
        defer { Darwin.close(storage.descriptor) }
        let managedFiles = try openOrCreateDirectory(
            named: Self.folderDropdownFilesDirectoryName,
            beneath: storage.descriptor,
            diagnosticPath: Self.folderDropdownFilesDirectoryName
        )
        defer { Darwin.close(managedFiles.descriptor) }

        var fileMappings = try loadStringMap(
            named: Self.folderDropdownFilesFileName,
            from: storage.descriptor,
            diagnosticRoot: assetDirectory.appending(path: Self.directoryName)
        )
        guard fileMappings.count < limits.maximumFiles else {
            throw WallpaperImportError.tooManyFiles(
                fileMappings.count,
                limits.maximumFiles
            )
        }
        let destinationName = try nextAvailableDestinationName(
            named: originalName,
            in: destinationFolder.descriptor,
            projectRelativeFolder: projectRelativeFolder,
            reservedProjectPaths: Set(fileMappings.keys)
        )
        let projectRelativeDestination = projectRelativeFolder + "/" + destinationName
        let storedExtension = standardizedSource.pathExtension.lowercased()
        let storedName = storedExtension.isEmpty
            ? UUID().uuidString.lowercased()
            : "\(UUID().uuidString.lowercased()).\(storedExtension)"
        let storedRelativePath = Self.folderDropdownFilesDirectoryName + "/" + storedName
        let storedDescriptor = storedName.withCString {
            Darwin.openat(
                managedFiles.descriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard storedDescriptor >= 0 else {
            throw WallpaperImportError.notRegularFile(storedRelativePath)
        }
        defer { Darwin.close(storedDescriptor) }
        do {
            try copyOpenedRegularFile(
                sourceDescriptor: sourceDescriptor,
                sourceAttributes: sourceAttributes,
                sourcePath: source.path,
                destinationDescriptor: storedDescriptor
            )
            livelyCopyObserver?(.privateFileCopied)
            guard regularFileStillReferences(
                standardizedSource,
                device: sourceAttributes.st_dev,
                inode: sourceAttributes.st_ino
            ) else {
                throw WallpaperImportError.notRegularFile(source.path)
            }

            var overrides = try loadStringMap(
                named: Self.overridesFileName,
                from: storage.descriptor,
                diagnosticRoot: assetDirectory.appending(path: Self.directoryName)
            )
            overrides[propertyName] = projectRelativeDestination
            fileMappings[projectRelativeDestination] = storedRelativePath
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encodedOverrides = try encoder.encode(overrides)
            let encodedFileMappings = try encoder.encode(fileMappings)
            guard encodedOverrides.count <= Self.maximumOverrideMetadataBytes,
                  encodedFileMappings.count <= Self.maximumOverrideMetadataBytes else {
                throw WallpaperImportError.tooLarge(
                    UInt64(max(encodedOverrides.count, encodedFileMappings.count)),
                    UInt64(Self.maximumOverrideMetadataBytes)
                )
            }
            guard directoryStillReferences(
                      canonicalAssetPath,
                      device: assetRoot.attributes.st_dev,
                      inode: assetRoot.attributes.st_ino
                  ),
                  directoryStillReferences(
                      canonicalAssetPath + "/" + projectRelativeFolder,
                      device: destinationFolder.attributes.st_dev,
                      inode: destinationFolder.attributes.st_ino
                  ),
                  directoryStillReferences(
                      canonicalAssetPath + "/" + Self.directoryName,
                      device: storage.attributes.st_dev,
                      inode: storage.attributes.st_ino
                  ),
                  directoryStillReferences(
                      canonicalAssetPath + "/" + Self.directoryName + "/"
                          + Self.folderDropdownFilesDirectoryName,
                      device: managedFiles.attributes.st_dev,
                      inode: managedFiles.attributes.st_ino
                  ) else {
                throw WallpaperImportError.unsafeRoot(projectRelativeFolder)
            }
            // Persist the newly created directory entry before publishing any
            // metadata that points to it.
            guard Darwin.fsync(managedFiles.descriptor) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try replaceMetadataFilesAtomically(
                [
                    Self.overridesFileName: encodedOverrides,
                    Self.folderDropdownFilesFileName: encodedFileMappings
                ],
                inDirectoryDescriptor: storage.descriptor,
                diagnosticRoot: assetDirectory.appending(path: Self.directoryName)
            )
            return assetDirectory.appending(path: projectRelativeDestination)
        } catch {
            let operationError = error
            if (operationError as NSError).domain == webWallpaperMetadataRollbackErrorDomain {
                throw NSError(
                    domain: "com.lamppkk.backgroundengine.lively-file-recovery",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "A Lively metadata rollback failed. The private file was retained for recovery at \(storedRelativePath).",
                        NSUnderlyingErrorKey: operationError,
                        "BackgroundEngineRecoveryPath": assetDirectory
                            .appending(path: Self.directoryName)
                            .appending(path: storedRelativePath).path
                    ]
                )
            }
            let unlinkResult = storedName.withCString {
                Darwin.unlinkat(managedFiles.descriptor, $0, 0)
            }
            let unlinkError = errno
            let syncResult = Darwin.fsync(managedFiles.descriptor)
            let syncError = errno
            guard (unlinkResult == 0 || unlinkError == ENOENT), syncResult == 0 else {
                throw NSError(
                    domain: "com.lamppkk.backgroundengine.lively-file-rollback",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "A Lively file selection failed and its private file could not be durably removed.",
                        NSUnderlyingErrorKey: operationError,
                        "BackgroundEngineUnlinkErrno": Int(unlinkError),
                        "BackgroundEngineFsyncErrno": Int(syncError)
                    ]
                )
            }
            throw operationError
        }
    }

    private func deleteLivelyFolderDropdownFileLocked(
        projectRelativePath: String,
        callbackValue: String,
        affectedPropertyNames: Set<String>,
        from assetDirectory: URL
    ) throws -> Bool {
        let projectPathComponents = try validatedRelativePathComponents(projectRelativePath)
        let callbackComponents = try validatedRelativePathComponents(callbackValue)
        guard !callbackValue.isEmpty,
              !callbackValue.contains("\0"),
              callbackValue.lengthOfBytes(using: .utf8) <= Self.maximumTextValueBytes,
              callbackComponents.last == projectPathComponents.last,
              !affectedPropertyNames.isEmpty,
              affectedPropertyNames.count <= Self.maximumScalarProperties else {
            throw WallpaperImportError.notRegularFile(
                "Invalid Lively folder-dropdown deletion request."
            )
        }
        for propertyName in affectedPropertyNames {
            try validatePropertyName(propertyName)
        }

        let assetRoot = try openPinnedAssetDirectory(assetDirectory)
        let canonicalAssetPath = assetRoot.canonicalPath
        defer { Darwin.close(assetRoot.descriptor) }
        let storage = try openDirectory(
            components: [Self.directoryName],
            beneath: assetRoot.descriptor,
            diagnosticPath: assetDirectory.appending(path: Self.directoryName).path
        )
        defer { Darwin.close(storage.descriptor) }
        let managedFiles = try openDirectory(
            components: [Self.folderDropdownFilesDirectoryName],
            beneath: storage.descriptor,
            diagnosticPath: assetDirectory
                .appending(path: Self.directoryName)
                .appending(path: Self.folderDropdownFilesDirectoryName).path
        )
        defer { Darwin.close(managedFiles.descriptor) }
        let diagnosticRoot = assetDirectory.appending(path: Self.directoryName)

        var fileMappings = try loadStringMap(
            named: Self.folderDropdownFilesFileName,
            from: storage.descriptor,
            diagnosticRoot: diagnosticRoot
        )
        guard let storedRelativePath = fileMappings[projectRelativePath] else {
            throw WallpaperImportError.notRegularFile(
                "The selected Lively file is no longer managed by Background Engine."
            )
        }
        let storedComponents = try validatedRelativePathComponents(storedRelativePath)
        guard storedComponents.count == 2,
              storedComponents[0] == Self.folderDropdownFilesDirectoryName else {
            throw WallpaperImportError.pathEscape(storedRelativePath)
        }
        let storedName = storedComponents[1]
        let fileDescriptor = storedName.withCString {
            Darwin.openat(
                managedFiles.descriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard fileDescriptor >= 0 else {
            if errno == ELOOP {
                throw WallpaperImportError.symbolicLink(storedRelativePath)
            }
            throw WallpaperImportError.notRegularFile(storedRelativePath)
        }
        defer { Darwin.close(fileDescriptor) }
        var fileAttributes = stat()
        guard Darwin.fstat(fileDescriptor, &fileAttributes) == 0,
              fileAttributes.st_mode & S_IFMT == S_IFREG else {
            throw WallpaperImportError.notRegularFile(storedRelativePath)
        }

        var overrides = try loadStringMap(
            named: Self.overridesFileName,
            from: storage.descriptor,
            diagnosticRoot: diagnosticRoot
        )
        overrides = overrides.filter { $0.value != projectRelativePath }

        let existingValueData = try loadMetadataData(
            named: Self.valueOverridesFileName,
            from: storage.descriptor,
            diagnosticRoot: diagnosticRoot
        )
        var valueOverrides: [String: WebWallpaperPropertyOverrideValue]
        if let existingValueData, !existingValueData.isEmpty {
            valueOverrides = try JSONDecoder().decode(
                [String: WebWallpaperPropertyOverrideValue].self,
                from: existingValueData
            )
            try validateValueOverrides(valueOverrides)
        } else {
            valueOverrides = [:]
        }
        for propertyName in affectedPropertyNames
            where valueOverrides[propertyName] == .text(callbackValue) {
            valueOverrides.removeValue(forKey: propertyName)
        }
        fileMappings.removeValue(forKey: projectRelativePath)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let documents = [
            Self.overridesFileName: try encoder.encode(overrides),
            Self.valueOverridesFileName: try encoder.encode(valueOverrides),
            Self.folderDropdownFilesFileName: try encoder.encode(fileMappings),
        ]
        guard documents.values.allSatisfy({
            $0.count <= Self.maximumOverrideMetadataBytes
        }) else {
            throw WallpaperImportError.tooLarge(
                UInt64(documents.values.map(\.count).max() ?? 0),
                UInt64(Self.maximumOverrideMetadataBytes)
            )
        }
        guard directoryStillReferences(
                  canonicalAssetPath,
                  device: assetRoot.attributes.st_dev,
                  inode: assetRoot.attributes.st_ino
              ),
              directoryStillReferences(
                  canonicalAssetPath + "/" + Self.directoryName,
                  device: storage.attributes.st_dev,
                  inode: storage.attributes.st_ino
              ),
              directoryStillReferences(
                  canonicalAssetPath + "/" + Self.directoryName + "/"
                      + Self.folderDropdownFilesDirectoryName,
                  device: managedFiles.attributes.st_dev,
                  inode: managedFiles.attributes.st_ino
              ) else {
            throw WallpaperImportError.unsafeRoot(projectRelativePath)
        }

        // Remove every runtime reference first. A crash after this commit can
        // leave only an inaccessible orphan, never an active mapping whose
        // file disappeared. The normal path immediately removes that orphan.
        try replaceMetadataFilesAtomically(
            documents,
            inDirectoryDescriptor: storage.descriptor,
            diagnosticRoot: diagnosticRoot,
            commitOrder: [
                Self.valueOverridesFileName,
                Self.overridesFileName,
                Self.folderDropdownFilesFileName,
            ]
        )

        var currentAttributes = stat()
        let currentStatus = storedName.withCString {
            Darwin.fstatat(
                managedFiles.descriptor,
                $0,
                &currentAttributes,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard currentStatus == 0,
              currentAttributes.st_mode & S_IFMT == S_IFREG,
              currentAttributes.st_dev == fileAttributes.st_dev,
              currentAttributes.st_ino == fileAttributes.st_ino,
              directoryStillReferences(
                  canonicalAssetPath,
                  device: assetRoot.attributes.st_dev,
                  inode: assetRoot.attributes.st_ino
              ),
              directoryStillReferences(
                  canonicalAssetPath + "/" + Self.directoryName,
                  device: storage.attributes.st_dev,
                  inode: storage.attributes.st_ino
              ),
              directoryStillReferences(
                  canonicalAssetPath + "/" + Self.directoryName + "/"
                      + Self.folderDropdownFilesDirectoryName,
                  device: managedFiles.attributes.st_dev,
                  inode: managedFiles.attributes.st_ino
              ) else {
            return false
        }

        let tombstoneName = ".deleted-\(UUID().uuidString.lowercased())"
        let renamed = storedName.withCString { sourceName in
            tombstoneName.withCString { destinationName in
                Darwin.renameat(
                    managedFiles.descriptor,
                    sourceName,
                    managedFiles.descriptor,
                    destinationName
                )
            }
        }
        guard renamed == 0 else { return false }
        var tombstoneAttributes = stat()
        let tombstoneStatus = tombstoneName.withCString {
            Darwin.fstatat(
                managedFiles.descriptor,
                $0,
                &tombstoneAttributes,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard tombstoneStatus == 0,
              tombstoneAttributes.st_mode & S_IFMT == S_IFREG,
              tombstoneAttributes.st_dev == fileAttributes.st_dev,
              tombstoneAttributes.st_ino == fileAttributes.st_ino else {
            return false
        }
        let removed = tombstoneName.withCString {
            Darwin.unlinkat(managedFiles.descriptor, $0, 0)
        }
        let removeError = removed == 0 ? 0 : errno
        let synced = Darwin.fsync(managedFiles.descriptor)
        return (removed == 0 || removeError == ENOENT) && synced == 0
    }

    private func loadOverrides(at url: URL) throws -> [String: String] {
        let data = try loadMetadataData(at: url)
        guard !data.isEmpty else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func loadMetadataData(at url: URL) throws -> Data {
        var pathAttributes = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &pathAttributes)
        }
        if status != 0 {
            if errno == ENOENT { return Data() }
            throw WallpaperImportError.notRegularFile(url.path)
        }
        guard pathAttributes.st_mode & S_IFMT != S_IFLNK else {
            throw WallpaperImportError.symbolicLink(url.path)
        }

        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if descriptor < 0 {
            if errno == ENOENT { return Data() }
            if errno == ELOOP { throw WallpaperImportError.symbolicLink(url.path) }
            throw WallpaperImportError.notRegularFile(url.path)
        }
        defer { Darwin.close(descriptor) }

        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size >= 0 else {
            throw WallpaperImportError.notRegularFile(url.path)
        }
        let maximumBytes = Self.maximumOverrideMetadataBytes
        guard attributes.st_size <= maximumBytes else {
            throw WallpaperImportError.tooLarge(UInt64(attributes.st_size), UInt64(maximumBytes))
        }

        var data = Data()
        data.reserveCapacity(Int(attributes.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let bytesRead = Darwin.read(descriptor, &buffer, buffer.count)
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw WallpaperImportError.notRegularFile(url.path)
            }
            guard bytesRead <= maximumBytes - data.count else {
                throw WallpaperImportError.tooLarge(
                    UInt64(data.count + bytesRead),
                    UInt64(maximumBytes)
                )
            }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }
        return data
    }

    private func validatedStorageRoot(in assetDirectory: URL) throws -> URL {
        let assetRoot = assetDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let rootValues = try assetDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw WallpaperImportError.unsafeRoot(assetDirectory.path)
        }
        let storageRoot = assetDirectory.appending(path: Self.directoryName)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let storageValues = try storageRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard storageValues.isDirectory == true, storageValues.isSymbolicLink != true,
              isInside(storageRoot.resolvingSymlinksInPath(), root: assetRoot) else {
            throw WallpaperImportError.unsafeRoot(storageRoot.path)
        }
        return storageRoot
    }

    private func existingValidatedStorageRoot(in assetDirectory: URL) throws -> URL? {
        let assetRoot = assetDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let rootValues = try assetDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw WallpaperImportError.unsafeRoot(assetDirectory.path)
        }
        let storageRoot = assetDirectory.appending(path: Self.directoryName)
        var attributes = stat()
        let metadataStatus = storageRoot.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &attributes)
        }
        if metadataStatus != 0 {
            if errno == ENOENT { return nil }
            throw WallpaperImportError.unsafeRoot(storageRoot.path)
        }
        guard attributes.st_mode & S_IFMT == S_IFDIR,
              isInside(storageRoot.resolvingSymlinksInPath(), root: assetRoot) else {
            throw WallpaperImportError.unsafeRoot(storageRoot.path)
        }
        return storageRoot
    }

    private func replaceMetadataFile(named name: String, data: Data, in storageRoot: URL) throws {
        let destination = storageRoot.appending(path: name)
        let incoming = storageRoot.appending(path: ".\(name).incoming-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: incoming)
        }

        try data.write(to: incoming, options: [.withoutOverwriting])
        let values = try incoming.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw WallpaperImportError.notRegularFile(incoming.path)
        }
        let incomingDescriptor = incoming.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard incomingDescriptor >= 0 else {
            throw WallpaperImportError.notRegularFile(incoming.path)
        }
        defer { Darwin.close(incomingDescriptor) }
        guard Darwin.fsync(incomingDescriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try loadMetadataData(at: destination)
        }
        try metadataCommitter.commit(incoming: incoming, destination: destination)
    }

    private func replaceMetadataFilesAtomically(
        _ documents: [String: Data],
        inDirectoryDescriptor directoryDescriptor: Int32,
        diagnosticRoot: URL,
        commitOrder: [String]? = nil
    ) throws {
        struct StagedDocument {
            let name: String
            let incomingName: String
            let backupName: String
            let hadPreviousValue: Bool
        }

        guard !documents.isEmpty else { return }
        let orderedNames = commitOrder ?? documents.keys.sorted()
        guard orderedNames.count == documents.count,
              Set(orderedNames) == Set(documents.keys) else {
            throw WallpaperImportError.notRegularFile("Invalid Web metadata commit order.")
        }
        let transactionID = UUID().uuidString.lowercased()
        var stagedDocuments: [StagedDocument] = []
        var incomingNames: [String] = []
        var backupNames: [String] = []
        var retainBackupsForRecovery = false
        defer {
            for incomingName in incomingNames {
                _ = incomingName.withCString {
                    Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
            }
            if !retainBackupsForRecovery {
                for backupName in backupNames {
                    _ = backupName.withCString {
                        Darwin.unlinkat(directoryDescriptor, $0, 0)
                    }
                }
            }
        }

        for name in orderedNames {
            guard name == URL(filePath: name).lastPathComponent,
                  !name.isEmpty,
                  !name.contains("\0"),
                  let data = documents[name],
                  data.count <= Self.maximumOverrideMetadataBytes else {
                throw WallpaperImportError.notRegularFile("Invalid Web metadata document.")
            }
            let incomingName = ".\(name).incoming-\(transactionID)"
            let backupName = ".\(name).previous-\(transactionID)"
            incomingNames.append(incomingName)
            try writeMetadataData(
                data,
                named: incomingName,
                to: directoryDescriptor,
                diagnosticRoot: diagnosticRoot
            )
            let previousData = try loadMetadataData(
                named: name,
                from: directoryDescriptor,
                diagnosticRoot: diagnosticRoot
            )
            if let previousData {
                backupNames.append(backupName)
                try writeMetadataData(
                    previousData,
                    named: backupName,
                    to: directoryDescriptor,
                    diagnosticRoot: diagnosticRoot
                )
            }
            stagedDocuments.append(
                StagedDocument(
                    name: name,
                    incomingName: incomingName,
                    backupName: backupName,
                    hadPreviousValue: previousData != nil
                )
            )
        }

        var attemptedDocuments: [StagedDocument] = []
        do {
            for document in stagedDocuments {
                attemptedDocuments.append(document)
                try metadataCommitter.commit(
                    incomingName: document.incomingName,
                    destinationName: document.name,
                    directoryDescriptor: directoryDescriptor
                )
            }
        } catch {
            let commitError = error
            do {
                for document in attemptedDocuments.reversed() {
                    if document.hadPreviousValue {
                        try AtomicWebWallpaperMetadataCommitter().commit(
                            incomingName: document.backupName,
                            destinationName: document.name,
                            directoryDescriptor: directoryDescriptor
                        )
                    } else {
                        let result = document.name.withCString {
                            Darwin.unlinkat(directoryDescriptor, $0, 0)
                        }
                        guard result == 0 || errno == ENOENT else {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                        }
                    }
                }
                guard Darwin.fsync(directoryDescriptor) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            } catch let rollbackError {
                retainBackupsForRecovery = true
                throw NSError(
                    domain: webWallpaperMetadataRollbackErrorDomain,
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "A Lively file selection failed and its metadata rollback also failed.",
                        NSUnderlyingErrorKey: rollbackError,
                        "BackgroundEngineCommitError": commitError
                    ]
                )
            }
            throw commitError
        }
        // Each successful committer call fsyncs this directory. Do not add a
        // second fallible step after all renames: at that point a thrown error
        // could make the caller remove the private file while committed
        // metadata already points at it.
    }

    private func validatedRelativePathComponents(_ relativePath: String) throws -> [String] {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              relativePath.lengthOfBytes(using: .utf8) <= 4_096,
              !relativePath.hasPrefix("/"),
              components.allSatisfy({
                  !$0.isEmpty
                      && $0 != "."
                      && $0 != ".."
                      && !$0.contains("\\")
                      && !$0.contains("\0")
              }) else {
            throw WallpaperImportError.pathEscape(relativePath)
        }
        return components
    }

    private func openPinnedDirectory(_ directory: URL) throws -> (descriptor: Int32, attributes: stat) {
        var inspectedAttributes = stat()
        let inspected = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &inspectedAttributes)
        }
        guard inspected == 0, inspectedAttributes.st_mode & S_IFMT == S_IFDIR else {
            throw WallpaperImportError.unsafeRoot(directory.path)
        }
        let descriptor = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw WallpaperImportError.unsafeRoot(directory.path)
        }
        var openedAttributes = stat()
        guard Darwin.fstat(descriptor, &openedAttributes) == 0,
              openedAttributes.st_mode & S_IFMT == S_IFDIR,
              openedAttributes.st_dev == inspectedAttributes.st_dev,
              openedAttributes.st_ino == inspectedAttributes.st_ino else {
            Darwin.close(descriptor)
            throw WallpaperImportError.unsafeRoot(directory.path)
        }
        return (descriptor, openedAttributes)
    }

    private func openPinnedAssetDirectory(
        _ directory: URL
    ) throws -> (descriptor: Int32, attributes: stat, canonicalPath: String) {
        let standardizedDirectory = directory.standardizedFileURL
        let pinned = try openPinnedDirectory(standardizedDirectory)
        guard let canonicalPath = canonicalPath(of: standardizedDirectory),
              directoryStillReferences(
                  canonicalPath,
                  device: pinned.attributes.st_dev,
                  inode: pinned.attributes.st_ino
              ) else {
            Darwin.close(pinned.descriptor)
            throw WallpaperImportError.unsafeRoot(directory.path)
        }
        return (pinned.descriptor, pinned.attributes, canonicalPath)
    }

    private func openDirectory(
        components: [String],
        beneath rootDescriptor: Int32,
        diagnosticPath: String
    ) throws -> (descriptor: Int32, attributes: stat) {
        var current = Darwin.dup(rootDescriptor)
        guard current >= 0 else { throw WallpaperImportError.unsafeRoot(diagnosticPath) }
        for component in components {
            let next = component.withCString {
                Darwin.openat(
                    current,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard next >= 0 else {
                Darwin.close(current)
                throw WallpaperImportError.unsafeRoot(diagnosticPath)
            }
            Darwin.close(current)
            current = next
        }
        var attributes = stat()
        guard Darwin.fstat(current, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(current)
            throw WallpaperImportError.unsafeRoot(diagnosticPath)
        }
        return (current, attributes)
    }

    private func openOrCreateDirectory(
        named name: String,
        beneath parentDescriptor: Int32,
        diagnosticPath: String
    ) throws -> (descriptor: Int32, attributes: stat) {
        guard !name.isEmpty,
              name == URL(filePath: name).lastPathComponent,
              !name.contains("\0") else {
            throw WallpaperImportError.unsafeRoot(diagnosticPath)
        }
        let created = name.withCString {
            Darwin.mkdirat(parentDescriptor, $0, S_IRWXU)
        }
        guard created == 0 || errno == EEXIST else {
            throw WallpaperImportError.unsafeRoot(diagnosticPath)
        }
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw WallpaperImportError.unsafeRoot(diagnosticPath)
        }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(descriptor)
            throw WallpaperImportError.unsafeRoot(diagnosticPath)
        }
        if created == 0, Darwin.fsync(parentDescriptor) != 0 {
            let syncError = errno
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(syncError))
        }
        return (descriptor, attributes)
    }

    private func loadStringMap(
        named name: String,
        from directoryDescriptor: Int32,
        diagnosticRoot: URL
    ) throws -> [String: String] {
        guard let data = try loadMetadataData(
            named: name,
            from: directoryDescriptor,
            diagnosticRoot: diagnosticRoot
        ), !data.isEmpty else {
            return [:]
        }
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        guard decoded.count <= max(Self.maximumScalarProperties, limits.maximumFiles),
              decoded.allSatisfy({ key, value in
                  !key.isEmpty
                      && !key.contains("\0")
                      && key.lengthOfBytes(using: .utf8) <= Self.maximumTextValueBytes
                      && !value.isEmpty
                      && !value.contains("\0")
                      && value.lengthOfBytes(using: .utf8) <= Self.maximumTextValueBytes
              }) else {
            throw WallpaperImportError.notRegularFile(
                diagnosticRoot.appending(path: name).path
            )
        }
        return decoded
    }

    private func loadMetadataData(
        named name: String,
        from directoryDescriptor: Int32,
        diagnosticRoot: URL
    ) throws -> Data? {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP {
                throw WallpaperImportError.symbolicLink(
                    diagnosticRoot.appending(path: name).path
                )
            }
            throw WallpaperImportError.notRegularFile(
                diagnosticRoot.appending(path: name).path
            )
        }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size >= 0,
              attributes.st_size <= Self.maximumOverrideMetadataBytes else {
            throw WallpaperImportError.notRegularFile(
                diagnosticRoot.appending(path: name).path
            )
        }
        var data = Data()
        data.reserveCapacity(Int(attributes.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let amount = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if amount == 0 { return data }
            if amount < 0 {
                if errno == EINTR { continue }
                throw WallpaperImportError.notRegularFile(
                    diagnosticRoot.appending(path: name).path
                )
            }
            guard amount <= Self.maximumOverrideMetadataBytes - data.count else {
                throw WallpaperImportError.tooLarge(
                    UInt64(data.count + amount),
                    UInt64(Self.maximumOverrideMetadataBytes)
                )
            }
            data.append(contentsOf: buffer.prefix(amount))
        }
    }

    private func writeMetadataData(
        _ data: Data,
        named name: String,
        to directoryDescriptor: Int32,
        diagnosticRoot: URL
    ) throws {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw WallpaperImportError.notRegularFile(
                diagnosticRoot.appending(path: name).path
            )
        }
        var keepFile = false
        defer {
            Darwin.close(descriptor)
            if !keepFile {
                _ = name.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
            }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw WallpaperImportError.notRegularFile(
                        diagnosticRoot.appending(path: name).path
                    )
                }
                guard amount > 0 else {
                    throw WallpaperImportError.notRegularFile(
                        diagnosticRoot.appending(path: name).path
                    )
                }
                offset += amount
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        keepFile = true
    }

    private func copyOpenedRegularFile(
        sourceDescriptor: Int32,
        sourceAttributes: stat,
        sourcePath: String,
        destinationDescriptor: Int32
    ) throws {
        let expectedBytes = UInt64(sourceAttributes.st_size)
        var copiedBytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let amount = buffer.withUnsafeMutableBytes {
                Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
            }
            if amount == 0 { break }
            if amount < 0 {
                if errno == EINTR { continue }
                throw WallpaperImportError.notRegularFile(sourcePath)
            }
            let (nextBytes, overflow) = copiedBytes.addingReportingOverflow(UInt64(amount))
            guard !overflow,
                  nextBytes <= expectedBytes,
                  nextBytes <= limits.maximumBytes else {
                throw WallpaperImportError.tooLarge(
                    overflow ? UInt64.max : nextBytes,
                    limits.maximumBytes
                )
            }
            var written = 0
            while written < amount {
                let writeAmount = buffer.withUnsafeBytes {
                    Darwin.write(
                        destinationDescriptor,
                        $0.baseAddress?.advanced(by: written),
                        amount - written
                    )
                }
                if writeAmount < 0 {
                    if errno == EINTR { continue }
                    throw WallpaperImportError.notRegularFile(sourcePath)
                }
                guard writeAmount > 0 else {
                    throw WallpaperImportError.notRegularFile(sourcePath)
                }
                written += writeAmount
            }
            copiedBytes = nextBytes
        }
        var finalSourceAttributes = stat()
        var destinationAttributes = stat()
        guard copiedBytes == expectedBytes,
              Darwin.fstat(sourceDescriptor, &finalSourceAttributes) == 0,
              finalSourceAttributes.st_mode & S_IFMT == S_IFREG,
              finalSourceAttributes.st_dev == sourceAttributes.st_dev,
              finalSourceAttributes.st_ino == sourceAttributes.st_ino,
              finalSourceAttributes.st_size == sourceAttributes.st_size,
              finalSourceAttributes.st_mtimespec.tv_sec == sourceAttributes.st_mtimespec.tv_sec,
              finalSourceAttributes.st_mtimespec.tv_nsec == sourceAttributes.st_mtimespec.tv_nsec,
              Darwin.fstat(destinationDescriptor, &destinationAttributes) == 0,
              destinationAttributes.st_mode & S_IFMT == S_IFREG,
              destinationAttributes.st_size >= 0,
              UInt64(destinationAttributes.st_size) == expectedBytes,
              Darwin.fsync(destinationDescriptor) == 0 else {
            throw WallpaperImportError.notRegularFile(sourcePath)
        }
    }

    private func nextAvailableDestinationName(
        named name: String,
        in directoryDescriptor: Int32,
        projectRelativeFolder: String,
        reservedProjectPaths: Set<String>
    ) throws -> String {
        let normalizedReservations = Set(reservedProjectPaths.map {
            $0.precomposedStringWithCanonicalMapping.lowercased()
        })
        let nsName = NSString(string: name)
        let pathExtension = nsName.pathExtension
        let stem = pathExtension.isEmpty ? name : nsName.deletingPathExtension
        for index in 0...10_000 {
            let candidateName: String
            if index == 0 {
                candidateName = name
            } else if pathExtension.isEmpty {
                candidateName = "\(stem) (\(index))"
            } else {
                candidateName = "\(stem) (\(index)).\(pathExtension)"
            }
            guard candidateName.lengthOfBytes(using: .utf8) <= 255 else { continue }
            let relativePath = projectRelativeFolder + "/" + candidateName
            guard !normalizedReservations.contains(
                relativePath.precomposedStringWithCanonicalMapping.lowercased()
            ) else {
                continue
            }
            var attributes = stat()
            let status = candidateName.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &attributes, AT_SYMLINK_NOFOLLOW)
            }
            if status != 0, errno == ENOENT { return candidateName }
            if status != 0 {
                throw WallpaperImportError.notRegularFile(relativePath)
            }
        }
        throw WallpaperImportError.tooManyFiles(10_001, 10_000)
    }

    private func canonicalPath(of url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return Darwin.realpath(path, &buffer) != nil
        }
        guard resolved else { return nil }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private func directoryStillReferences(_ path: String, device: dev_t, inode: ino_t) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        for component in components {
            let next = component.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            Darwin.close(descriptor)
            guard next >= 0 else { return false }
            descriptor = next
        }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        return Darwin.fstat(descriptor, &attributes) == 0
            && attributes.st_mode & S_IFMT == S_IFDIR
            && attributes.st_dev == device
            && attributes.st_ino == inode
    }

    private func regularFileStillReferences(_ file: URL, device: dev_t, inode: ino_t) -> Bool {
        var attributes = stat()
        let status = file.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &attributes)
        }
        return status == 0
            && attributes.st_mode & S_IFMT == S_IFREG
            && attributes.st_dev == device
            && attributes.st_ino == inode
    }

    private func validateValueOverrides(
        _ overrides: [String: WebWallpaperPropertyOverrideValue]
    ) throws {
        guard overrides.count <= Self.maximumScalarProperties else {
            throw WallpaperImportError.tooManyFiles(overrides.count, Self.maximumScalarProperties)
        }
        for (name, value) in overrides {
            let nameBytes = name.lengthOfBytes(using: .utf8)
            guard !name.isEmpty,
                  !name.contains("\0"),
                  nameBytes <= Self.maximumPropertyNameBytes else {
                throw WallpaperImportError.notRegularFile("Invalid Web property name.")
            }
            switch value {
            case .bool:
                break
            case .number(let number):
                guard number.isFinite else {
                    throw WallpaperImportError.notRegularFile("Invalid Web property number.")
                }
            case .text(let text):
                let size = text.lengthOfBytes(using: .utf8)
                guard size <= Self.maximumTextValueBytes else {
                    throw WallpaperImportError.tooLarge(
                        UInt64(size),
                        UInt64(Self.maximumTextValueBytes)
                    )
                }
            }
        }
    }

    private func validatePropertyName(_ propertyName: String) throws {
        let nameBytes = propertyName.lengthOfBytes(using: .utf8)
        guard !propertyName.isEmpty,
              !propertyName.contains("\0"),
              nameBytes <= Self.maximumPropertyNameBytes else {
            throw WallpaperImportError.notRegularFile("Invalid Web property name.")
        }
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

final class WallpaperAssetMutationLock: @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private final class WeakWallpaperAssetMutationLock: @unchecked Sendable {
    weak var value: WallpaperAssetMutationLock?

    init(_ value: WallpaperAssetMutationLock) {
        self.value = value
    }
}

enum WallpaperAssetMutationLockRegistry {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var locks: [String: WeakWallpaperAssetMutationLock] = [:]

    static func lock(for assetDirectory: URL) -> WallpaperAssetMutationLock {
        let key = assetDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[key]?.value {
            return existing
        }
        let created = WallpaperAssetMutationLock()
        locks[key] = WeakWallpaperAssetMutationLock(created)
        return created
    }
}
