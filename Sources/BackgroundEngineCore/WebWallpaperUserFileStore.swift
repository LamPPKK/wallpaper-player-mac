import Foundation
import CryptoKit
import Darwin

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
}

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
    public static let maximumOverrideMetadataBytes = 1_048_576
    public static let maximumScalarProperties = 1_000
    public static let maximumPropertyNameBytes = 512
    public static let maximumTextValueBytes = 64 * 1_024
    private let limits: Limits
    private let metadataCommitter: any WebWallpaperMetadataCommitting

    public init(limits: Limits = Limits()) {
        self.limits = limits
        metadataCommitter = AtomicWebWallpaperMetadataCommitter()
    }

    init(
        limits: Limits = Limits(),
        metadataCommitter: any WebWallpaperMetadataCommitting
    ) {
        self.limits = limits
        self.metadataCommitter = metadataCommitter
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

    /// Atomically replaces every scalar override for one imported Web asset.
    /// Callers pass the complete editor state so Reset can remove stale keys
    /// without a read/modify/write race with another store instance.
    public func saveValueOverrides(
        _ overrides: [String: WebWallpaperPropertyOverrideValue],
        into assetDirectory: URL
    ) throws {
        let accessLock = WebWallpaperUserFileAccessLockRegistry.lock(for: assetDirectory)
        try accessLock.withLock {
            try validateValueOverrides(overrides)
            let storageRoot = try validatedStorageRoot(in: assetDirectory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(overrides)
            guard encoded.count <= Self.maximumOverrideMetadataBytes else {
                throw WallpaperImportError.tooLarge(
                    UInt64(encoded.count),
                    UInt64(Self.maximumOverrideMetadataBytes)
                )
            }
            try replaceMetadataFile(
                named: Self.valueOverridesFileName,
                data: encoded,
                in: storageRoot
            )
        }
    }

    public func loadValueOverrides(
        from assetDirectory: URL
    ) throws -> [String: WebWallpaperPropertyOverrideValue] {
        let accessLock = WebWallpaperUserFileAccessLockRegistry.lock(for: assetDirectory)
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

    private func loadOverrides(at url: URL) throws -> [String: String] {
        let data = try loadMetadataData(at: url)
        guard !data.isEmpty else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
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
