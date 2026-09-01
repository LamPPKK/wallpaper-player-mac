import Darwin
import Foundation

enum LivelySourceCopyCheckpoint: Sendable, Equatable {
    case archiveOpened
    case entryInspected(String)
    case entryOpened(String)
}

/// Imports a user-supplied Lively Wallpaper project without trusting its
/// archive paths or mutating the selected source. Lively metadata is converted
/// in an isolated staging directory before the regular library importer sees
/// the project.
public actor LivelyWallpaperPackageImporter {
    public struct Limits: Sendable, Equatable {
        public let maximumEntries: Int
        public let maximumArchiveBytes: UInt64
        public let maximumEntryBytes: UInt64
        public let maximumUncompressedBytes: UInt64
        public let maximumCompressionRatio: Double

        public init(
            maximumEntries: Int = 100_000,
            maximumArchiveBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024,
            maximumEntryBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024,
            maximumUncompressedBytes: UInt64 = 20 * 1_024 * 1_024 * 1_024,
            maximumCompressionRatio: Double = 200
        ) {
            self.maximumEntries = maximumEntries
            self.maximumArchiveBytes = maximumArchiveBytes
            self.maximumEntryBytes = maximumEntryBytes
            self.maximumUncompressedBytes = maximumUncompressedBytes
            self.maximumCompressionRatio = maximumCompressionRatio
        }
    }

    private static let metadataLimit = 1_048_576
    private static let propertiesLimit = 1_048_576
    private static let rootReferenceRewriteLimit = 8 * 1_024 * 1_024

    private let importer: WallpaperImporter
    private let limits: Limits
    private let unzipExecutable: URL
    private let entryExtractionTimeout: Duration
    private let sourceCopyObserver: (@Sendable (LivelySourceCopyCheckpoint) -> Void)?

    public init(
        store: LibraryStore,
        limits: Limits = Limits()
    ) {
        importer = WallpaperImporter(store: store)
        self.limits = limits
        unzipExecutable = URL(filePath: "/usr/bin/unzip")
        entryExtractionTimeout = .seconds(300)
        sourceCopyObserver = nil
    }

    init(
        store: LibraryStore,
        limits: Limits,
        unzipExecutable: URL,
        entryExtractionTimeout: Duration = .seconds(300),
        sourceCopyObserver: (@Sendable (LivelySourceCopyCheckpoint) -> Void)? = nil,
        convertedVideoCacheDirectory: URL? = nil
    ) {
        importer = WallpaperImporter(
            store: store,
            convertedVideoCacheDirectory: convertedVideoCacheDirectory
        )
        self.limits = limits
        self.unzipExecutable = unzipExecutable
        self.entryExtractionTimeout = entryExtractionTimeout
        self.sourceCopyObserver = sourceCopyObserver
    }

    /// Imports either a project directory or a `.zip` export. The returned
    /// asset is already passed through automatic video preparation.
    public func importAndPrepare(_ source: URL) async throws -> WallpaperAsset {
        try Task.checkCancellation()
        let source = source.standardizedFileURL
        let workspace = try Self.makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let stagedContainer: URL
        var sourceDescriptor = source.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard sourceDescriptor >= 0 else {
            throw LivelyWallpaperImportError.unsupportedSource(source.path)
        }
        defer {
            if sourceDescriptor >= 0 { Darwin.close(sourceDescriptor) }
        }
        var sourceAttributes = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceAttributes) == 0 else {
            throw LivelyWallpaperImportError.unsupportedSource(source.path)
        }
        if sourceAttributes.st_mode & S_IFMT == S_IFDIR {
            stagedContainer = workspace.appending(path: "folder", directoryHint: .isDirectory)
            try stageDirectorySnapshot(
                sourceDescriptor: sourceDescriptor,
                sourceURL: source,
                openedAttributes: sourceAttributes,
                at: stagedContainer
            )
            Darwin.close(sourceDescriptor)
            sourceDescriptor = -1
            try validateTree(stagedContainer)
        } else if sourceAttributes.st_mode & S_IFMT == S_IFREG,
                  source.pathExtension.lowercased() == "zip" {
            let stableArchive = workspace.appending(path: "package.zip")
            try stageArchiveSnapshot(
                sourceDescriptor: sourceDescriptor,
                sourceURL: source,
                openedAttributes: sourceAttributes,
                at: stableArchive
            )
            Darwin.close(sourceDescriptor)
            sourceDescriptor = -1
            let archive = try LivelyZIPArchive(
                url: stableArchive,
                limits: limits
            )
            stagedContainer = workspace.appending(path: "extracted", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: stagedContainer,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try await extract(archive, from: stableArchive, into: stagedContainer)
            let extractedTree = try validateTree(stagedContainer)
            guard extractedTree.files == archive.filePaths else {
                throw LivelyWallpaperImportError.extractedTreeMismatch
            }
        } else {
            throw LivelyWallpaperImportError.unsupportedSource(source.path)
        }

        try Task.checkCancellation()
        let livelyRoot = try locateLivelyRoot(in: stagedContainer)
        let normalizedRoot = workspace.appending(path: "normalized", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: livelyRoot, to: normalizedRoot)
        try validateTree(normalizedRoot)
        let sourceTitle = source.pathExtension.lowercased() == "zip"
            ? source.deletingPathExtension().lastPathComponent
            : source.lastPathComponent
        try normalizeProject(
            at: normalizedRoot,
            fallbackTitle: sourceTitle.isEmpty ? "Lively Wallpaper" : sourceTitle
        )
        try validateTree(normalizedRoot)

        let scan = try await importer.scan(root: normalizedRoot)
        guard scan.assets.count == 1, let scanned = scan.assets.first else {
            throw LivelyWallpaperImportError.normalizedProjectMissing
        }
        let contentHash = try WallpaperContentHasher.hashDirectory(normalizedRoot)
        let candidate = WallpaperAsset(
            id: "lively-\(contentHash.prefix(24))",
            title: scanned.title,
            kind: scanned.kind,
            supportStatus: scanned.supportStatus,
            source: .manualFolder,
            projectDirectory: scanned.projectDirectory,
            entrypoint: scanned.entrypoint,
            thumbnail: scanned.thumbnail,
            workshopId: nil,
            dateAdded: scanned.dateAdded,
            contentHash: contentHash,
            compatibility: scanned.compatibility,
            compatibilityReport: scanned.compatibilityReport,
            allowsNetworkAccess: false,
            redistributionAllowed: false,
            issues: scanned.issues
        )
        try Task.checkCancellation()
        return try await importer.importAndPrepareAsset(candidate)
    }

    /// Copies a user-selected directory through descriptors rooted at the
    /// directory that was actually opened. Every child is opened relative to
    /// its pinned parent with `O_NOFOLLOW`, so a concurrent rename or symlink
    /// swap cannot redirect staging outside the selected tree.
    private func stageDirectorySnapshot(
        sourceDescriptor: Int32,
        sourceURL: URL,
        openedAttributes: stat,
        at destination: URL
    ) throws {
        guard openedAttributes.st_mode & S_IFMT == S_IFDIR else {
            throw LivelyWallpaperImportError.unsafeTree(sourceURL.path)
        }
        let created = destination.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.mkdir(path, S_IRWXU)
        }
        guard created == 0 else {
            throw LivelyWallpaperImportError.cannotCreateStaging
        }
        let destinationDescriptor = destination.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard destinationDescriptor >= 0 else {
            throw LivelyWallpaperImportError.cannotCreateStaging
        }
        defer { Darwin.close(destinationDescriptor) }

        var state = LivelyDirectoryCopyState()
        try copyDirectoryContents(
            sourceDescriptor: sourceDescriptor,
            destinationDescriptor: destinationDescriptor,
            relativeDirectory: "",
            state: &state
        )
        var finalAttributes = stat()
        guard Darwin.fstat(sourceDescriptor, &finalAttributes) == 0,
              Self.sameRevision(openedAttributes, finalAttributes),
              Self.path(sourceURL, stillReferences: finalAttributes) else {
            throw LivelyWallpaperImportError.unsafeTree(sourceURL.path)
        }
    }

    /// Takes a byte-bounded snapshot of the archive before parsing it. The
    /// source descriptor is pinned once and the destination is exclusive, so
    /// validation can never describe different bytes from extraction.
    private func stageArchiveSnapshot(
        sourceDescriptor: Int32,
        sourceURL: URL,
        openedAttributes: stat,
        at destination: URL
    ) throws {
        guard openedAttributes.st_mode & S_IFMT == S_IFREG,
              openedAttributes.st_size >= 0 else {
            throw LivelyWallpaperImportError.unsafeTree(sourceURL.path)
        }
        let expectedBytes = UInt64(openedAttributes.st_size)
        guard expectedBytes <= limits.maximumArchiveBytes else {
            throw LivelyWallpaperImportError.archiveTooLarge(
                actual: expectedBytes,
                limit: limits.maximumArchiveBytes
            )
        }
        sourceCopyObserver?(.archiveOpened)

        let destinationDescriptor = destination.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard destinationDescriptor >= 0 else {
            throw LivelyWallpaperImportError.cannotCreateStaging
        }
        var keepDestination = false
        defer {
            Darwin.close(destinationDescriptor)
            if !keepDestination {
                _ = destination.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return Int32(-1) }
                    return Darwin.unlink(path)
                }
            }
        }

        var copiedBytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let amount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(sourceDescriptor, bytes.baseAddress, bytes.count)
            }
            if amount == 0 { break }
            if amount < 0 {
                if errno == EINTR { continue }
                throw LivelyWallpaperImportError.unsafeTree(sourceURL.path)
            }
            let (next, overflow) = copiedBytes.addingReportingOverflow(UInt64(amount))
            guard !overflow, next <= limits.maximumArchiveBytes else {
                throw LivelyWallpaperImportError.archiveTooLarge(
                    actual: overflow ? UInt64.max : next,
                    limit: limits.maximumArchiveBytes
                )
            }
            guard next <= expectedBytes else {
                throw LivelyWallpaperImportError.unsafeTree(sourceURL.path)
            }
            try Self.writeAll(
                descriptor: destinationDescriptor,
                bytes: buffer,
                count: amount,
                errorPath: sourceURL.path
            )
            copiedBytes = next
        }
        var finalAttributes = stat()
        guard copiedBytes == expectedBytes,
              Darwin.fstat(sourceDescriptor, &finalAttributes) == 0,
              Self.sameRevision(openedAttributes, finalAttributes),
              Self.path(sourceURL, stillReferences: finalAttributes) else {
            throw LivelyWallpaperImportError.unsafeTree(sourceURL.path)
        }
        keepDestination = true
    }

    private func copyDirectoryContents(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        relativeDirectory: String,
        state: inout LivelyDirectoryCopyState
    ) throws {
        let enumerationDescriptor = Darwin.fcntl(sourceDescriptor, F_DUPFD_CLOEXEC, 0)
        guard enumerationDescriptor >= 0,
              let stream = Darwin.fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { Darwin.close(enumerationDescriptor) }
            throw LivelyWallpaperImportError.unsafeTree(relativeDirectory)
        }
        defer { Darwin.closedir(stream) }

        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                guard errno == 0 else {
                    throw LivelyWallpaperImportError.unsafeTree(relativeDirectory)
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { tuplePointer -> String? in
                tuplePointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
                ) { String(validatingCString: $0) }
            }
            guard let name else {
                throw LivelyWallpaperImportError.unsafeTree(relativeDirectory)
            }
            if name == "." || name == ".." { continue }
            guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
                throw LivelyWallpaperImportError.unsafeTree(name)
            }
            let relativePath = relativeDirectory.isEmpty
                ? name
                : "\(relativeDirectory)/\(name)"
            let normalized = try Self.normalizedTreePath(relativePath)
            guard state.normalizedPaths.insert(normalized).inserted else {
                throw LivelyWallpaperImportError.pathCollision(relativePath)
            }
            state.entryCount += 1
            guard state.entryCount <= limits.maximumEntries else {
                throw LivelyWallpaperImportError.tooManyEntries(
                    state.entryCount,
                    limits.maximumEntries
                )
            }

            var inspectedAttributes = stat()
            let inspected = name.withCString {
                Darwin.fstatat(
                    sourceDescriptor,
                    $0,
                    &inspectedAttributes,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard inspected == 0 else {
                throw LivelyWallpaperImportError.unsafeTree(relativePath)
            }
            sourceCopyObserver?(.entryInspected(relativePath))

            switch inspectedAttributes.st_mode & S_IFMT {
            case S_IFDIR:
                try copySourceDirectory(
                    name: name,
                    relativePath: relativePath,
                    inspectedAttributes: inspectedAttributes,
                    sourceParentDescriptor: sourceDescriptor,
                    destinationParentDescriptor: destinationDescriptor,
                    state: &state
                )
            case S_IFREG:
                try copySourceFile(
                    name: name,
                    relativePath: relativePath,
                    inspectedAttributes: inspectedAttributes,
                    sourceParentDescriptor: sourceDescriptor,
                    destinationParentDescriptor: destinationDescriptor,
                    state: &state
                )
            default:
                throw LivelyWallpaperImportError.unsafeTree(relativePath)
            }
        }
    }

    private func copySourceDirectory(
        name: String,
        relativePath: String,
        inspectedAttributes: stat,
        sourceParentDescriptor: Int32,
        destinationParentDescriptor: Int32,
        state: inout LivelyDirectoryCopyState
    ) throws {
        let sourceDescriptor = name.withCString {
            Darwin.openat(
                sourceParentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard sourceDescriptor >= 0 else {
            throw LivelyWallpaperImportError.unsafeTree(relativePath)
        }
        defer { Darwin.close(sourceDescriptor) }
        var openedAttributes = stat()
        guard Darwin.fstat(sourceDescriptor, &openedAttributes) == 0,
              openedAttributes.st_mode & S_IFMT == S_IFDIR,
              Self.sameRevision(inspectedAttributes, openedAttributes) else {
            throw LivelyWallpaperImportError.unsafeTree(relativePath)
        }

        let created = name.withCString {
            Darwin.mkdirat(destinationParentDescriptor, $0, S_IRWXU)
        }
        guard created == 0 else {
            throw LivelyWallpaperImportError.cannotCreateStaging
        }
        let destinationDescriptor = name.withCString {
            Darwin.openat(
                destinationParentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard destinationDescriptor >= 0 else {
            throw LivelyWallpaperImportError.cannotCreateStaging
        }
        defer { Darwin.close(destinationDescriptor) }

        try copyDirectoryContents(
            sourceDescriptor: sourceDescriptor,
            destinationDescriptor: destinationDescriptor,
            relativeDirectory: relativePath,
            state: &state
        )
        var finalAttributes = stat()
        var finalPathAttributes = stat()
        let pathStatus = name.withCString {
            Darwin.fstatat(
                sourceParentDescriptor,
                $0,
                &finalPathAttributes,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard Darwin.fstat(sourceDescriptor, &finalAttributes) == 0,
              pathStatus == 0,
              Self.sameRevision(openedAttributes, finalAttributes),
              Self.sameRevision(openedAttributes, finalPathAttributes) else {
            throw LivelyWallpaperImportError.unsafeTree(relativePath)
        }
    }

    private func copySourceFile(
        name: String,
        relativePath: String,
        inspectedAttributes: stat,
        sourceParentDescriptor: Int32,
        destinationParentDescriptor: Int32,
        state: inout LivelyDirectoryCopyState
    ) throws {
        let sourceDescriptor = name.withCString {
            Darwin.openat(
                sourceParentDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard sourceDescriptor >= 0 else {
            throw LivelyWallpaperImportError.unsafeTree(relativePath)
        }
        defer { Darwin.close(sourceDescriptor) }
        var openedAttributes = stat()
        guard Darwin.fstat(sourceDescriptor, &openedAttributes) == 0,
              openedAttributes.st_mode & S_IFMT == S_IFREG,
              openedAttributes.st_size >= 0,
              Self.sameRevision(inspectedAttributes, openedAttributes) else {
            throw LivelyWallpaperImportError.unsafeTree(relativePath)
        }
        let expectedBytes = UInt64(openedAttributes.st_size)
        guard expectedBytes <= limits.maximumEntryBytes else {
            throw LivelyWallpaperImportError.entryTooLarge(relativePath, expectedBytes)
        }
        guard state.totalBytes <= limits.maximumUncompressedBytes - min(
            expectedBytes,
            limits.maximumUncompressedBytes
        ) else {
            throw LivelyWallpaperImportError.uncompressedDataTooLarge
        }
        sourceCopyObserver?(.entryOpened(relativePath))

        let destinationDescriptor = name.withCString {
            Darwin.openat(
                destinationParentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard destinationDescriptor >= 0 else {
            throw LivelyWallpaperImportError.cannotCreateStaging
        }
        defer { Darwin.close(destinationDescriptor) }

        var copiedBytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let amount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(sourceDescriptor, bytes.baseAddress, bytes.count)
            }
            if amount == 0 { break }
            if amount < 0 {
                if errno == EINTR { continue }
                throw LivelyWallpaperImportError.unsafeTree(relativePath)
            }
            let (next, overflow) = copiedBytes.addingReportingOverflow(UInt64(amount))
            guard !overflow, next <= expectedBytes else {
                throw LivelyWallpaperImportError.unsafeTree(relativePath)
            }
            try Self.writeAll(
                descriptor: destinationDescriptor,
                bytes: buffer,
                count: amount,
                errorPath: relativePath
            )
            copiedBytes = next
        }

        var finalAttributes = stat()
        var finalPathAttributes = stat()
        let pathStatus = name.withCString {
            Darwin.fstatat(
                sourceParentDescriptor,
                $0,
                &finalPathAttributes,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard copiedBytes == expectedBytes,
              Darwin.fstat(sourceDescriptor, &finalAttributes) == 0,
              pathStatus == 0,
              Self.sameRevision(openedAttributes, finalAttributes),
              Self.sameRevision(openedAttributes, finalPathAttributes) else {
            throw LivelyWallpaperImportError.unsafeTree(relativePath)
        }
        state.totalBytes += copiedBytes
    }

    private static func writeAll(
        descriptor: Int32,
        bytes: [UInt8],
        count: Int,
        errorPath: String
    ) throws {
        try bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            while written < count {
                let amount = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    count - written
                )
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw LivelyWallpaperImportError.unsafeTree(errorPath)
                }
                guard amount > 0 else {
                    throw LivelyWallpaperImportError.unsafeTree(errorPath)
                }
                written += amount
            }
        }
    }

    private static func sameRevision(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func path(_ url: URL, stillReferences attributes: stat) -> Bool {
        var current = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &current)
        }
        return status == 0 && sameRevision(attributes, current)
    }

    private func extract(
        _ archive: LivelyZIPArchive,
        from archiveURL: URL,
        into destination: URL
    ) async throws {
        guard FileManager.default.isExecutableFile(atPath: unzipExecutable.path) else {
            throw LivelyWallpaperImportError.unzipUnavailable(unzipExecutable.path)
        }

        // The system extractor is never allowed to choose a destination path.
        // Directory entries and parents are materialized by us inside the
        // private staging root; each regular entry is then streamed to one
        // descriptor-bound file with a hard output limit.
        for entry in archive.entries where entry.isDirectory {
            try Self.createSafeDirectory(
                relativePath: entry.destinationPath,
                inside: destination
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1_800))
        for entry in archive.entries where !entry.isDirectory {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw LivelyWallpaperImportError.extractionTimedOut(entry.destinationPath)
            }
            let timeout = min(remaining, entryExtractionTimeout)
            try await extractEntry(
                entry,
                archiveURL: archiveURL,
                destination: destination,
                timeout: timeout
            )
        }
    }

    private func extractEntry(
        _ entry: LivelyZIPEntry,
        archiveURL: URL,
        destination: URL,
        timeout: Duration
    ) async throws {
        let parentPath = (entry.destinationPath as NSString).deletingLastPathComponent
        if !parentPath.isEmpty {
            try Self.createSafeDirectory(relativePath: parentPath, inside: destination)
        }
        let output = destination.appending(path: entry.destinationPath).standardizedFileURL
        guard Self.isStrictDescendant(output, of: destination) else {
            throw LivelyWallpaperImportError.unsafeTree(output.path)
        }

        let descriptor = output.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw LivelyWallpaperImportError.unsafeTree(output.path)
        }
        let outputHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let errorHandle: FileHandle
        do {
            errorHandle = try FileHandle(forWritingTo: URL(filePath: "/dev/null"))
        } catch {
            throw LivelyWallpaperImportError.extractionFailed(-1)
        }
        var keepOutput = false
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
            if !keepOutput { try? FileManager.default.removeItem(at: output) }
        }

        guard timeout > .zero else {
            throw LivelyWallpaperImportError.extractionTimedOut(entry.destinationPath)
        }
        let extractor = LivelyEntryExtractionProcess(
            executable: unzipExecutable,
            arguments: ["-p", archiveURL.path, entry.archiveName],
            currentDirectory: destination,
            outputDescriptor: descriptor,
            expectedBytes: entry.uncompressedSize,
            standardError: errorHandle
        )
        let outcome: LivelyEntryExtractionOutcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: LivelyEntryExtractionRace.self) { group in
                    defer { group.cancelAll() }
                    group.addTask {
                        try Task.checkCancellation()
                        return .completed(try await extractor.run())
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        return .timedOut
                    }
                    guard let first = try await group.next() else {
                        extractor.stop()
                        throw LivelyWallpaperImportError.extractionTimedOut(entry.destinationPath)
                    }
                    switch first {
                    case .completed(let value):
                        return value
                    case .timedOut:
                        extractor.stop()
                        throw LivelyWallpaperImportError.extractionTimedOut(entry.destinationPath)
                    }
                }
            } onCancel: {
                extractor.stop()
            }
        } catch let failure as LivelyEntryExtractionFailure {
            switch failure {
            case .launchOrIOFailure:
                throw LivelyWallpaperImportError.extractionFailed(-1)
            case .outputExceeded(let observed):
                throw LivelyWallpaperImportError.extractedEntrySizeMismatch(
                    entry.destinationPath,
                    actual: observed,
                    expected: entry.uncompressedSize
                )
            }
        }

        // `LivelyEntryExtractionProcess` writes at most the central-directory
        // declaration to this descriptor. The on-disk size check is retained
        // as a second invariant before interpreting unzip's exit status.
        let observed = try Self.sizeOfRegularFile(output)
        guard observed == entry.uncompressedSize else {
            throw LivelyWallpaperImportError.extractedEntrySizeMismatch(
                entry.destinationPath,
                actual: observed,
                expected: entry.uncompressedSize
            )
        }
        guard outcome.observedBytes == entry.uncompressedSize else {
            throw LivelyWallpaperImportError.extractedEntrySizeMismatch(
                entry.destinationPath,
                actual: outcome.observedBytes,
                expected: entry.uncompressedSize
            )
        }
        guard outcome.terminationStatus == 0 else {
            throw LivelyWallpaperImportError.extractionFailed(outcome.terminationStatus)
        }
        let checksum = try Self.crc32OfRegularFile(output)
        guard checksum == entry.crc32 else {
            throw LivelyWallpaperImportError.extractedEntryChecksumMismatch(entry.destinationPath)
        }
        keepOutput = true
    }

    private static func createSafeDirectory(relativePath: String, inside root: URL) throws {
        let safePath = try safeRelativePath(relativePath)
        var current = root.standardizedFileURL
        for component in safePath.split(separator: "/") {
            current.append(path: String(component), directoryHint: .isDirectory)
            guard isStrictDescendant(current, of: root) else {
                throw LivelyWallpaperImportError.unsafeTree(current.path)
            }
            var status = stat()
            let result = current.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.lstat(path, &status)
            }
            if result == 0 {
                guard status.st_mode & S_IFMT == S_IFDIR else {
                    throw LivelyWallpaperImportError.unsafeTree(current.path)
                }
                continue
            }
            guard errno == ENOENT else {
                throw LivelyWallpaperImportError.unsafeTree(current.path)
            }
            let created = current.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.mkdir(path, S_IRWXU)
            }
            guard created == 0 else {
                throw LivelyWallpaperImportError.unsafeTree(current.path)
            }
        }
    }

    private static func sizeOfRegularFile(_ url: URL) throws -> UInt64 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw LivelyWallpaperImportError.unsafeTree(url.path) }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0 else {
            throw LivelyWallpaperImportError.unsafeTree(url.path)
        }
        return UInt64(status.st_size)
    }

    private static func crc32OfRegularFile(_ url: URL) throws -> UInt32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw LivelyWallpaperImportError.unsafeTree(url.path) }
        defer { Darwin.close(descriptor) }

        var checksum = UInt32.max
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let amount = Darwin.read(descriptor, &buffer, buffer.count)
            if amount == 0 { return ~checksum }
            if amount < 0 {
                if errno == EINTR { continue }
                throw LivelyWallpaperImportError.unsafeTree(url.path)
            }
            for byte in buffer.prefix(amount) {
                checksum = Self.crc32Table[Int((checksum ^ UInt32(byte)) & 0xff)] ^ (checksum >> 8)
            }
        }
    }

    private static let crc32Table: [UInt32] = (0..<256).map { value in
        var current = UInt32(value)
        for _ in 0..<8 {
            current = (current >> 1) ^ (0xedb8_8320 & (0 &- (current & 1)))
        }
        return current
    }

    private func locateLivelyRoot(in container: URL) throws -> URL {
        let metadata = container.appending(path: "LivelyInfo.json")
        if Self.isRegularFile(metadata) {
            return container
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        guard children.count == 1, let wrapper = children.first else {
            throw LivelyWallpaperImportError.missingOrAmbiguousMetadata
        }
        let values = try wrapper.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              Self.isRegularFile(wrapper.appending(path: "LivelyInfo.json")) else {
            throw LivelyWallpaperImportError.missingOrAmbiguousMetadata
        }
        return wrapper
    }

    private func normalizeProject(
        at root: URL,
        fallbackTitle: String
    ) throws {
        let metadataURL = root.appending(path: "LivelyInfo.json")
        let metadataData = try Self.readBoundedRegularFile(
            metadataURL,
            maximumBytes: Self.metadataLimit,
            tooLarge: .metadataTooLarge
        )
        let metadataObject: Any
        do {
            metadataObject = try JSONSerialization.jsonObject(with: metadataData)
        } catch {
            throw LivelyWallpaperImportError.malformedMetadata
        }
        guard let metadata = metadataObject as? [String: Any] else {
            throw LivelyWallpaperImportError.malformedMetadata
        }
        let livelyType = try Self.wallpaperType(metadata["Type"])
        if livelyType != .url, livelyType != .videoStream {
            // This metadata file is owned exclusively by Background Engine's
            // generated remote-website importer. A local Lively project must
            // not be able to replace its authored entrypoint after network
            // permission is granted.
            try Self.requireGeneratedPathsAvailable([
                root.appending(path: RemoteWebWallpaperConfiguration.fileName)
            ])
        }
        let usesAbsolutePath = try Self.absolutePathFlag(metadata["IsAbsolutePath"])
        let entrypoint: String
        let projectType: String
        switch livelyType {
        case .url, .videoStream:
            let targetURL = try Self.requiredRemoteURL(metadata["FileName"])
            projectType = "web"
            entrypoint = livelyType == .url
                ? ".background-engine-lively-url.html"
                : ".background-engine-lively-stream.html"
            // Lively's default stream backend is a browser and stream targets
            // may be video pages (for example a hosted player), not just raw
            // media URLs. Reuse the restricted remote-Web path for both.
            try Self.writeRemoteWebsiteProject(
                targetURL: targetURL,
                entrypoint: entrypoint,
                root: root
            )
        case .application, .bizhawk, .unity, .godot, .unityAudio:
            projectType = "application"
            if usesAbsolutePath {
                guard let value = Self.boundedString(
                    metadata["FileName"],
                    maximumLength: 4_096
                )?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                    throw LivelyWallpaperImportError.missingMetadataField("FileName")
                }
                // A reference-style Windows package may point outside the export.
                // Preserve it as a visible Unsupported library item without ever
                // copying, resolving, or launching the external executable.
                entrypoint = ".background-engine-unsupported-application.exe"
                try Self.writeUnsupportedApplicationPlaceholder(
                    entrypoint: entrypoint,
                    root: root
                )
            } else {
                entrypoint = try Self.requiredRelativeFile(
                    metadata["FileName"],
                    field: "FileName",
                    root: root
                )
            }
        default:
            if usesAbsolutePath {
                throw LivelyWallpaperImportError.absolutePathMetadata
            }
            entrypoint = try Self.requiredRelativeFile(
                metadata["FileName"],
                field: "FileName",
                root: root
            )
            projectType = livelyType.projectType
        }
        let thumbnail = try Self.optionalExistingRelativeFile(
            metadata["Thumbnail"],
            useBasename: usesAbsolutePath,
            root: root
        )
        let preview = try Self.optionalExistingRelativeFile(
            metadata["Preview"],
            useBasename: usesAbsolutePath,
            root: root
        )

        if livelyType == .web || livelyType == .webAudio {
            try Self.normalizeReachableRootRelativeWebReferences(
                entrypoint: entrypoint,
                root: root
            )
        }

        var project: [String: Any] = [
            "title": Self.safeTitle(metadata["Title"], fallback: fallbackTitle),
            "type": projectType,
            "file": entrypoint,
        ]
        // Lively's animated Preview is the preferred gallery representation;
        // Thumbnail is only the still-image fallback.
        if let previewPath = preview ?? thumbnail {
            project["preview"] = previewPath
        }
        let propertyConversion = try convertProperties(at: root, entrypoint: entrypoint)
        if let propertyConversion, !propertyConversion.properties.isEmpty {
            var general: [String: Any] = ["properties": propertyConversion.properties]
            if livelyType.requiresNeutralAudio {
                general["supportsaudioprocessing"] = true
            }
            project["general"] = general
        } else if livelyType.requiresNeutralAudio {
            project["general"] = ["supportsaudioprocessing": true]
        }
        var limitations = propertyConversion?.limitations ?? []
        if livelyType.usesNativeMediaPlayback,
           propertyConversion?.properties.isEmpty == false {
            limitations.insert(.nativeMediaProperties)
        }
        if livelyType.requiresNeutralAudio {
            limitations.insert(.neutralAudioReactive)
        }
        if !limitations.isEmpty {
            project[LivelyPropertyCompatibility.metadataKey] = limitations
                .map(\.rawValue)
                .sorted()
        }

        let output: Data
        do {
            output = try JSONSerialization.data(
                withJSONObject: project,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw LivelyWallpaperImportError.malformedMetadata
        }
        try output.write(to: root.appending(path: "project.json"), options: .atomic)
    }

    /// Lively serves a local Web package from its own virtual origin, so an
    /// authored `/js/runtime.js` points at that package root. Background
    /// Engine deliberately places a random token before `/project/` on its
    /// loopback origin; leaving the leading slash intact would discard that
    /// token and fail closed at the server. Rewrite only unambiguous HTML
    /// resource attributes, inline CSS, and target values inside import maps on the
    /// private staging copy. Root-relative import-map keys remain unchanged so
    /// the compatibility analyzer rejects them instead of silently changing
    /// their matching semantics. Arbitrary inline JSON and protocol-relative
    /// URLs remain untouched. A `<base>` element makes root semantics
    /// ambiguous, so it is left unchanged for the regular compatibility probe
    /// to reject or classify. The user-selected package is never edited.
    private static func normalizeUnambiguousRootRelativeWebReferences(
        documentURL: URL,
        root: URL
    ) throws {
        let values = try documentURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= rootReferenceRewriteLimit else {
            return
        }
        let data = try Data(contentsOf: documentURL, options: [.mappedIfSafe])
        guard let source = String(data: data, encoding: .utf8),
              let scan = WebRuntimeFeatureAnalyzer().htmlReferencesForStaging(in: source),
              !scan.hasAuthoredBase else {
            return
        }

        guard let directoryDepth = relativeDirectoryDepth(of: documentURL, root: root) else {
            return
        }
        let projectRootPrefix = directoryDepth == 0
            ? "./"
            : String(repeating: "../", count: directoryDepth)
        let analyzer = WebRuntimeFeatureAnalyzer()
        var edits = [(range: Range<Int>, replacement: Data)]()
        for literal in scan.resourceAttributes {
            guard literal.reference.hasPrefix("/"),
                  !literal.reference.hasPrefix("//"),
                  analyzer.isSafeProjectRootReferenceForStaging(literal.reference),
                  literal.utf8ContentRange.lowerBound < literal.utf8ContentRange.upperBound else {
                continue
            }
            edits.append(
                (
                    literal.utf8ContentRange.lowerBound..<(literal.utf8ContentRange.lowerBound + 1),
                    Data(projectRootPrefix.utf8)
                )
            )
        }
        for literal in scan.sourceSetAttributes {
            let rewrittenValue = rewriteRootRelativeSourceSet(
                literal.reference,
                prefix: projectRootPrefix,
                analyzer: analyzer
            )
            guard rewrittenValue != literal.reference else { continue }
            edits.append((literal.utf8ContentRange, Data(rewrittenValue.utf8)))
        }
        for styleRange in scan.inlineStyleUTF8Ranges {
            guard styleRange.lowerBound >= 0,
                  styleRange.upperBound <= data.count,
                  let style = String(data: data.subdata(in: styleRange), encoding: .utf8) else {
                continue
            }
            let rewrittenStyle = rewriteRootRelativeCSSLiterals(
                in: style,
                containingFile: documentURL,
                root: root
            )
            guard rewrittenStyle != style else { continue }
            edits.append((styleRange, Data(rewrittenStyle.utf8)))
        }
        for bodyRange in scan.importMapUTF8Ranges {
            guard bodyRange.lowerBound >= 0,
                  bodyRange.upperBound <= data.count,
                  let body = String(data: data.subdata(in: bodyRange), encoding: .utf8) else {
                continue
            }
            let rewrittenBody = rewriteRootRelativeImportMapTargets(
                in: body,
                prefix: projectRootPrefix,
                analyzer: analyzer
            )
            guard rewrittenBody != body else { continue }
            edits.append((bodyRange, Data(rewrittenBody.utf8)))
        }
        guard !edits.isEmpty else { return }
        var rewritten = data
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            guard edit.range.lowerBound >= 0,
                  edit.range.upperBound <= rewritten.count else {
                continue
            }
            rewritten.replaceSubrange(edit.range, with: edit.replacement)
        }
        guard rewritten != data else { return }
        try rewritten.write(to: documentURL, options: .atomic)
    }

    private static func relativeDirectoryDepth(of fileURL: URL, root: URL) -> Int? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let parentComponents = fileURL.deletingLastPathComponent()
            .standardizedFileURL.pathComponents
        guard parentComponents.count >= rootComponents.count,
              Array(parentComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return parentComponents.count - rootComponents.count
    }

    private static func rewriteRootRelativeSourceSet(
        _ source: String,
        prefix: String,
        analyzer: WebRuntimeFeatureAnalyzer
    ) -> String {
        let bytes = Array(source.utf8)
        var slashOffsets = [Int]()
        var index = 0
        while index < bytes.count {
            while index < bytes.count,
                  bytes[index] == 0x2C || isHTMLSpace(bytes[index]) {
                index += 1
            }
            guard index < bytes.count else { break }
            let candidateStart = index
            while index < bytes.count, !isHTMLSpace(bytes[index]) { index += 1 }
            var candidateEnd = index
            while candidateEnd > candidateStart, bytes[candidateEnd - 1] == 0x2C {
                candidateEnd -= 1
            }
            if candidateEnd > candidateStart {
                let reference = String(
                    decoding: bytes[candidateStart..<candidateEnd],
                    as: UTF8.self
                )
                if reference.hasPrefix("/"),
                   !reference.hasPrefix("//"),
                   analyzer.isSafeProjectRootReferenceForStaging(reference) {
                    slashOffsets.append(candidateStart)
                }
            }
            while index < bytes.count, bytes[index] != 0x2C { index += 1 }
        }
        guard !slashOffsets.isEmpty else { return source }
        var rewritten = Data(source.utf8)
        for offset in slashOffsets.reversed() {
            rewritten.replaceSubrange(offset..<(offset + 1), with: Data(prefix.utf8))
        }
        return String(data: rewritten, encoding: .utf8) ?? source
    }

    private static func rewriteRootRelativeImportMapTargets(
        in source: String,
        prefix: String,
        analyzer: WebRuntimeFeatureAnalyzer
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(:\s*\")(/(?!/)(?:\\.|[^\"\\])*)\""#
        ) else {
            return source
        }
        var rewritten = source
        let matches = expression.matches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        )
        for match in matches.reversed() {
            guard match.numberOfRanges > 2,
                  let targetRange = Range(match.range(at: 2), in: rewritten) else {
                continue
            }
            let reference = String(rewritten[targetRange])
            guard analyzer.isSafeProjectRootReferenceForStaging(reference) else { continue }
            rewritten.replaceSubrange(
                targetRange,
                with: prefix + reference.dropFirst()
            )
        }
        return rewritten
    }

    private static func normalizeRootRelativeCSSReferences(
        in stylesheetURL: URL,
        root: URL
    ) throws {
        let data = try Data(contentsOf: stylesheetURL, options: [.mappedIfSafe])
        guard let source = String(data: data, encoding: .utf8) else { return }
        let rewritten = rewriteRootRelativeCSSLiterals(
            in: source,
            containingFile: stylesheetURL,
            root: root
        )
        guard rewritten != source else { return }
        try Data(rewritten.utf8).write(to: stylesheetURL, options: .atomic)
    }

    private static func rewriteRootRelativeCSSLiterals(
        in source: String,
        containingFile: URL,
        root: URL
    ) -> String {
        let analyzer = WebRuntimeFeatureAnalyzer()
        guard let literals = analyzer.stylesheetLiteralsForStaging(in: source),
              let depth = relativeDirectoryDepth(of: containingFile, root: root),
              !literals.isEmpty else {
            return source
        }
        let prefix = depth == 0 ? "./" : String(repeating: "../", count: depth)
        var bytes = Data(source.utf8)
        for literal in literals.reversed() {
            let reference = literal.reference
            guard reference.hasPrefix("/"),
                  !reference.hasPrefix("//"),
                  analyzer.isSafeProjectRootReferenceForStaging(reference),
                  literal.utf8ContentRange.lowerBound >= 0,
                  literal.utf8ContentRange.upperBound <= bytes.count,
                  bytes.subdata(in: literal.utf8ContentRange) == Data(reference.utf8) else {
                continue
            }
            bytes.replaceSubrange(
                literal.utf8ContentRange,
                with: Data((prefix + reference.dropFirst()).utf8)
            )
        }
        return String(data: bytes, encoding: .utf8) ?? source
    }

    private static func isHTMLSpace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
    }

    /// WebKit resolves `/module.js` at the loopback host root, which would
    /// intentionally omit the per-view capability token and receive 404.
    /// Unlike passive DOM resource setters, module resolution cannot be
    /// intercepted by a document-start bridge. Rewrite only module literals
    /// proven by the compatibility analyzer's syntax-aware JavaScript lexer,
    /// only on the private staging copy, and only when the referenced regular
    /// file exists below the project root. Escaped literals, unsafe paths and
    /// packages beyond the analyzer's own bounded graph remain unchanged and
    /// are subsequently classified fail-closed.
    private static func normalizeReachableRootRelativeWebReferences(
        entrypoint: String,
        root: URL
    ) throws {
        let entrypointURL = root.appending(path: entrypoint)
        let analyzer = WebRuntimeFeatureAnalyzer()
        var processedFiles = Set<String>()
        var totalBytes = 0
        let iterationLimit = WebRuntimeFeatureAnalyzer.maximumJavaScriptNestingDepth
            + WebRuntimeFeatureAnalyzer.maximumHTMLNestingDepth
            + 2
        for _ in 0..<iterationLimit {
            let features = analyzer.analyze(
                entrypoint: entrypointURL,
                projectRoot: root
            )
            var resources = features.localResourceMIMEOverrides.filter {
                $0.mimeType == "text/html"
                    || $0.mimeType == "text/css"
                    || $0.mimeType == "text/javascript"
            }
            let canonicalEntrypoint = entrypointURL.standardizedFileURL
            if !resources.contains(where: {
                $0.sourceURL.standardizedFileURL.path == canonicalEntrypoint.path
            }) {
                resources.append(
                    WebLocalResourceMIMEOverride(
                        sourceURL: canonicalEntrypoint,
                        mimeType: "text/html"
                    )
                )
            }
            resources = resources
                .filter { !processedFiles.contains($0.sourceURL.standardizedFileURL.path) }
                .sorted {
                    if $0.sourceURL.path != $1.sourceURL.path {
                        return $0.sourceURL.path < $1.sourceURL.path
                    }
                    return $0.mimeType < $1.mimeType
                }
            guard !resources.isEmpty else { return }
            for resource in resources {
                let fileURL = resource.sourceURL.standardizedFileURL
                let canonicalPath = fileURL.path
                processedFiles.insert(canonicalPath)
                guard processedFiles.count <= WebRuntimeFeatureAnalyzer.maximumDependencyNodes,
                      isStrictDescendant(fileURL.resolvingSymlinksInPath(), of: root) else {
                    return
                }
                let values = try fileURL.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let fileSize = values.fileSize,
                      fileSize >= 0,
                      fileSize <= rootReferenceRewriteLimit,
                      totalBytes <= WebRuntimeFeatureAnalyzer.maximumDependencyTextBytes - fileSize else {
                    continue
                }
                totalBytes += fileSize
                switch resource.mimeType {
                case "text/html":
                    try normalizeUnambiguousRootRelativeWebReferences(
                        documentURL: fileURL,
                        root: root
                    )
                    try normalizeInlineJavaScriptModuleSpecifiers(
                        in: fileURL,
                        root: root
                    )
                case "text/css":
                    try normalizeRootRelativeCSSReferences(in: fileURL, root: root)
                case "text/javascript":
                    try normalizeRootRelativeJavaScriptModuleSpecifiers(
                        in: fileURL,
                        root: root
                    )
                default:
                    break
                }
            }
        }
    }

    private static func normalizeRootRelativeJavaScriptModuleSpecifiers(
        in scriptURL: URL,
        root: URL
    ) throws {
        let data = try Data(contentsOf: scriptURL, options: [.mappedIfSafe])
        guard let source = String(data: data, encoding: .utf8) else { return }
        let rewritten = rewriteRootRelativeJavaScriptModuleLiterals(
            in: source,
            containingFile: scriptURL,
            root: root
        )
        guard rewritten != source else { return }
        try Data(rewritten.utf8).write(to: scriptURL, options: .atomic)
    }

    private static func normalizeInlineJavaScriptModuleSpecifiers(
        in entrypointURL: URL,
        root: URL
    ) throws {
        let values = try entrypointURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= rootReferenceRewriteLimit else {
            return
        }
        let data = try Data(contentsOf: entrypointURL, options: [.mappedIfSafe])
        guard let source = String(data: data, encoding: .utf8) else { return }
        guard let scan = WebRuntimeFeatureAnalyzer()
            .inlineJavaScriptRangesForStaging(in: source),
              !scan.hasAuthoredBase else {
            return
        }
        var rewritten = data
        for bodyRange in scan.utf8Ranges.reversed() {
            guard bodyRange.lowerBound >= 0,
                  bodyRange.upperBound <= rewritten.count,
                  let body = String(
                      data: rewritten.subdata(in: bodyRange),
                      encoding: .utf8
                  ) else {
                continue
            }
            let rewrittenBody = rewriteRootRelativeJavaScriptModuleLiterals(
                in: body,
                containingFile: entrypointURL,
                root: root
            )
            guard rewrittenBody != body else { continue }
            rewritten.replaceSubrange(bodyRange, with: Data(rewrittenBody.utf8))
        }
        guard rewritten != data else { return }
        try rewritten.write(to: entrypointURL, options: .atomic)
    }

    private static func rewriteRootRelativeJavaScriptModuleLiterals(
        in source: String,
        containingFile: URL,
        root: URL
    ) -> String {
        guard let literals = WebRuntimeFeatureAnalyzer()
            .javaScriptModuleLiteralsForStaging(in: source),
              !literals.isEmpty else {
            return source
        }
        let rootComponents = root.standardizedFileURL.pathComponents
        let parentComponents = containingFile.deletingLastPathComponent()
            .standardizedFileURL.pathComponents
        guard parentComponents.count >= rootComponents.count,
              Array(parentComponents.prefix(rootComponents.count)) == rootComponents else {
            return source
        }
        let depth = parentComponents.count - rootComponents.count
        let prefix = depth == 0 ? "./" : String(repeating: "../", count: depth)
        var bytes = Data(source.utf8)
        for literal in literals.reversed() {
            let reference = literal.reference
            guard reference.hasPrefix("/"),
                  !reference.hasPrefix("//"),
                  isExistingSafeRootRelativeModule(reference, root: root),
                  literal.utf8ContentRange.lowerBound >= 0,
                  literal.utf8ContentRange.upperBound <= bytes.count else {
                continue
            }
            let authoredBytes = Data(reference.utf8)
            guard bytes.subdata(in: literal.utf8ContentRange) == authoredBytes else {
                // Do not rewrite escaped literals. Their decoded value remains
                // visible to the analyzer, which will classify them fail-closed.
                continue
            }
            bytes.replaceSubrange(
                literal.utf8ContentRange,
                with: Data((prefix + reference.dropFirst()).utf8)
            )
        }
        return String(data: bytes, encoding: .utf8) ?? source
    }

    private static func isExistingSafeRootRelativeModule(
        _ reference: String,
        root: URL
    ) -> Bool {
        guard reference.hasPrefix("/"),
              !reference.hasPrefix("//"),
              !reference.contains("\\"),
              !reference.unicodeScalars.contains(where: {
                  $0.value <= 0x1F || $0.value == 0x7F
              }) else {
            return false
        }
        let pathEnd = [reference.firstIndex(of: "?"), reference.firstIndex(of: "#")]
            .compactMap { $0 }
            .min() ?? reference.endIndex
        let encodedPath = String(reference[reference.index(after: reference.startIndex)..<pathEnd])
        guard !encodedPath.isEmpty else { return false }
        let encodedSegments = encodedPath.split(separator: "/", omittingEmptySubsequences: false)
        for (index, segment) in encodedSegments.enumerated() {
            if segment.isEmpty {
                guard index == encodedSegments.count - 1, index > 0 else { return false }
                continue
            }
            guard let decoded = String(segment).removingPercentEncoding,
                  !decoded.isEmpty,
                  decoded != ".",
                  decoded != "..",
                  !decoded.contains("/"),
                  !decoded.contains("\\"),
                  !decoded.unicodeScalars.contains(where: {
                      $0.value <= 0x1F || $0.value == 0x7F
                  }) else {
                return false
            }
        }
        let rootDirectory = URL(fileURLWithPath: root.path, isDirectory: true)
        guard let candidate = URL(string: "." + reference, relativeTo: rootDirectory)?.absoluteURL,
              candidate.isFileURL else {
            return false
        }
        let fileURL = URL(filePath: candidate.path).standardizedFileURL
        let resolved = fileURL.resolvingSymlinksInPath()
        guard isStrictDescendant(resolved, of: root),
              let values = try? fileURL.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return false
        }
        return true
    }

    private func convertProperties(
        at root: URL,
        entrypoint: String
    ) throws -> LivelyPropertyConversion? {
        let url = root.appending(path: "LivelyProperties.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Self.readBoundedRegularFile(
            url,
            maximumBytes: Self.propertiesLimit,
            tooLarge: .propertiesTooLarge
        )
        let normalizedJSONC = try Self.normalizingLivelyJSONC(data)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: normalizedJSONC)
        } catch {
            throw LivelyWallpaperImportError.malformedProperties
        }
        guard let raw = object as? [String: Any] else {
            throw LivelyWallpaperImportError.malformedProperties
        }

        var converted: [String: Any] = [:]
        var limitations = Set<LivelyPropertyLimitation>()
        var order = 0
        for name in raw.keys.sorted() {
            guard Self.isSafePropertyName(name),
                  let descriptor = raw[name] as? [String: Any],
                  let rawType = descriptor["type"] as? String else {
                limitations.insert(.unmappedControl)
                continue
            }
            let normalizedType = rawType.lowercased()
            if normalizedType == "folderdropdown" {
                limitations.insert(.folderDropdown)
            }
            guard let property = Self.convertProperty(
                      descriptor,
                      type: normalizedType,
                      order: order,
                      root: root,
                      entrypoint: entrypoint
                  ) else {
                if normalizedType != "label" {
                    limitations.insert(.unmappedControl)
                }
                continue
            }
            converted[name] = property
            order += 1
        }
        return LivelyPropertyConversion(
            properties: converted,
            limitations: limitations
        )
    }

    private static func convertProperty(
        _ source: [String: Any],
        type: String,
        order: Int,
        root: URL,
        entrypoint: String
    ) -> [String: Any]? {
        let label = boundedString(source["text"], maximumLength: 1_024)
        var result: [String: Any] = ["order": order]
        if let label { result["text"] = label }

        switch type {
        case "checkbox":
            guard let value = boolValue(source["value"]) else { return nil }
            result["type"] = "bool"
            result["value"] = value
        case "slider":
            guard let value = finiteNumber(source["value"]) else { return nil }
            result["type"] = "slider"
            result["value"] = value
            let minimum = finiteNumber(source["min"])
            let maximum = finiteNumber(source["max"])
            if let minimum { result["min"] = minimum }
            if let maximum { result["max"] = maximum }
            if let step = finiteNumber(source["step"]), step > 0 {
                result["step"] = step
            } else {
                // Lively's pinned SliderModel ignores `tick` and defaults a
                // missing Step value to 1. Deriving a step from tick changes
                // authored controls from the Windows runtime.
                result["step"] = 1
            }
        case "color":
            guard let value = boundedString(source["value"], maximumLength: 256) else { return nil }
            result["type"] = "color"
            result["value"] = value
        case "dropdown":
            guard let options = comboOptions(source), !options.isEmpty else { return nil }
            let selected = integerValue(source["value"]) ?? 0
            let boundedIndex = min(max(0, selected), options.count - 1)
            result["type"] = "combo"
            result["value"] = String(boundedIndex)
            result["options"] = options.enumerated().map { index, label in
                ["label": label, "value": String(index)]
            }
            result["backgroundEngineLivelyType"] = "dropdown"
        case "textbox":
            guard let value = boundedString(source["value"], maximumLength: 16_384) else { return nil }
            result["type"] = "text"
            result["value"] = value
        case "folderdropdown":
            guard let folder = livelyFolderDropdown(
                source,
                root: root,
                entrypoint: entrypoint
            ) else {
                return nil
            }
            result["type"] = "combo"
            result["value"] = folder.selectedValue ?? ""
            result["options"] = folder.options.map {
                ["label": $0.label, "value": $0.callbackValue]
            }
            result["backgroundEngineLivelyType"] = "folderDropdown"
            result["backgroundEngineLivelyFolder"] = folder.projectRelativeFolder
            if let filter = folder.filter {
                result["backgroundEngineLivelyFilter"] = filter
            }
        case "button":
            // Lively's ButtonModel uses `text` as the descriptive label and
            // `value` as the button caption. A click is a one-shot event and is
            // therefore retained as a descriptor but never restored/persisted.
            result["type"] = "button"
            result["value"] = boundedString(source["value"], maximumLength: 1_024)
                ?? label
                ?? "Run"
            result["backgroundEngineLivelyType"] = "button"
        case "label":
            return nil
        default:
            return nil
        }
        return result
    }

    private static func comboOptions(_ source: [String: Any]) -> [String]? {
        let candidate = source["items"] ?? source["options"]
        guard let array = candidate as? [Any], array.count <= 1_024 else { return nil }
        return array.compactMap { item in
            if let string = boundedString(item, maximumLength: 1_024) { return string }
            if let dictionary = item as? [String: Any] {
                return boundedString(dictionary["label"] ?? dictionary["text"], maximumLength: 1_024)
            }
            return nil
        }
    }

    private struct LivelyFolderDropdown {
        struct Option {
            let label: String
            let callbackValue: String
        }

        let projectRelativeFolder: String
        let selectedValue: String?
        let options: [Option]
        let filter: String?
    }

    /// Lively scans only the authored folder next to the parent HTML file and
    /// sends `folder/file.ext` to `livelyPropertyListener`. Materializing the
    /// file list during import gives the native combo editor the same choices
    /// without treating an authored directory as a user-selected override.
    private static func livelyFolderDropdown(
        _ source: [String: Any],
        root: URL,
        entrypoint: String
    ) -> LivelyFolderDropdown? {
        guard let rawFolder = boundedString(source["folder"], maximumLength: 4_096),
              let callbackFolder = try? safeRelativePath(rawFolder) else {
            return nil
        }
        let entrypointComponents = entrypoint.split(separator: "/").map(String.init)
        let entrypointDirectory = entrypointComponents.dropLast().joined(separator: "/")
        let joinedFolder = entrypointDirectory.isEmpty
            ? callbackFolder
            : entrypointDirectory + "/" + callbackFolder
        guard let projectRelativeFolder = try? safeRelativePath(joinedFolder) else {
            return nil
        }
        let directory = root.appending(path: projectRelativeFolder).standardizedFileURL
        guard isStrictDescendant(directory, of: root),
              isDirectoryWithoutSymlink(directory),
              hasNoSymlinkComponent(
                  projectRelativeFolder,
                  root: root,
                  finalComponentMustBeDirectory: true
              ) else {
            return nil
        }

        let filter = boundedString(source["filter"], maximumLength: 4_096)
        let allowedExtensions = livelyFolderExtensions(from: filter)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var seen = Set<String>()
        let options = contents.compactMap { candidate -> LivelyFolderDropdown.Option? in
            guard seen.count < 1_024,
                  !candidate.lastPathComponent.hasPrefix("."),
                  let values = try? candidate.resourceValues(
                      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  isStrictDescendant(candidate.standardizedFileURL, of: directory),
                  allowedExtensions?.contains(candidate.pathExtension.lowercased()) != false else {
                return nil
            }
            let normalizedName = candidate.lastPathComponent
                .precomposedStringWithCanonicalMapping
                .lowercased()
            guard seen.insert(normalizedName).inserted else { return nil }
            return LivelyFolderDropdown.Option(
                label: candidate.lastPathComponent,
                callbackValue: callbackFolder + "/" + candidate.lastPathComponent
            )
        }.sorted {
            $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }

        let selectedValue: String?
        if let rawValue = boundedString(source["value"], maximumLength: 4_096),
           let normalizedValue = try? safeRelativePath(rawValue),
           !normalizedValue.contains("/"),
           let option = options.first(where: {
               $0.label.precomposedStringWithCanonicalMapping
                   .caseInsensitiveCompare(normalizedValue.precomposedStringWithCanonicalMapping)
                   == .orderedSame
           }) {
            selectedValue = option.callbackValue
        } else {
            selectedValue = nil
        }
        return LivelyFolderDropdown(
            projectRelativeFolder: projectRelativeFolder,
            selectedValue: selectedValue,
            options: options,
            filter: filter
        )
    }

    /// Supports Lively's documented `*.jpg|*.png` form. Unknown glob syntax
    /// is deliberately ignored instead of being evaluated as a path pattern.
    private static func livelyFolderExtensions(from filter: String?) -> Set<String>? {
        guard let filter, !filter.isEmpty else { return nil }
        var extensions = Set<String>()
        var sawUniversalPattern = false
        for rawPattern in filter.split(separator: "|", omittingEmptySubsequences: true) {
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if pattern == "*" || pattern == "*.*" {
                sawUniversalPattern = true
                continue
            }
            guard pattern.hasPrefix("*."), pattern.count > 2 else { continue }
            let value = String(pattern.dropFirst(2))
            guard value.count <= 32,
                  value.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
                  }) else {
                continue
            }
            extensions.insert(value)
        }
        if sawUniversalPattern || extensions.isEmpty { return nil }
        return extensions
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func hasNoSymlinkComponent(
        _ relativePath: String,
        root: URL,
        finalComponentMustBeDirectory: Bool
    ) -> Bool {
        var candidate = root
        let components = relativePath.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            candidate.append(path: component)
            var attributes = stat()
            let status = candidate.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.lstat(path, &attributes)
            }
            guard status == 0,
                  attributes.st_mode & S_IFMT != S_IFLNK else {
                return false
            }
            if index < components.count - 1 || finalComponentMustBeDirectory {
                guard attributes.st_mode & S_IFMT == S_IFDIR else { return false }
            }
        }
        return true
    }

    private static func wallpaperType(_ raw: Any?) throws -> LivelyWallpaperType {
        let value: Int?
        if let number = raw as? NSNumber, !isBoolean(number) {
            value = number.intValue
        } else if let string = raw as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let numeric = Int(normalized) {
                value = numeric
            } else {
                value = [
                    "application": 0, "app": 0,
                    "web": 1, "webaudio": 2,
                    "url": 3, "bizhawk": 4,
                    "unity": 5, "godot": 6,
                    "video": 7, "gif": 8,
                    "unityaudio": 9, "videostream": 10,
                    "picture": 11, "image": 11,
                ][normalized]
            }
        } else {
            value = nil
        }
        guard let value, let type = LivelyWallpaperType(rawValue: value) else {
            throw LivelyWallpaperImportError.unsupportedWallpaperType
        }
        return type
    }

    private static func absolutePathFlag(_ raw: Any?) throws -> Bool {
        guard let raw else { return false }
        if let number = raw as? NSNumber, isBoolean(number) { return number.boolValue }
        if let string = raw as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: break
            }
        }
        throw LivelyWallpaperImportError.malformedMetadata
    }

    private static func requiredRelativeFile(
        _ raw: Any?,
        field: String,
        root: URL
    ) throws -> String {
        guard let value = boundedString(raw, maximumLength: 4_096), !value.isEmpty else {
            throw LivelyWallpaperImportError.missingMetadataField(field)
        }
        let path = try safeRelativePath(value)
        let candidate = root.appending(path: path).standardizedFileURL
        guard isStrictDescendant(candidate, of: root), isRegularFile(candidate) else {
            throw LivelyWallpaperImportError.missingReferencedFile(field, path)
        }
        return path
    }

    private static func requiredRemoteURL(_ raw: Any?) throws -> URL {
        guard let value = boundedString(raw, maximumLength: 4_096)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), let targetURL = URL(string: value) else {
            throw LivelyWallpaperImportError.unsupportedRemoteURL
        }
        do {
            return try RemoteWebWallpaperConfiguration(targetURL: targetURL).targetURL
        } catch {
            throw LivelyWallpaperImportError.unsupportedRemoteURL
        }
    }

    private static func writeRemoteWebsiteProject(
        targetURL: URL,
        entrypoint: String,
        root: URL
    ) throws {
        let configuration = try RemoteWebWallpaperConfiguration(targetURL: targetURL)
        let configurationURL = root.appending(path: RemoteWebWallpaperConfiguration.fileName)
        let entrypointURL = root.appending(path: entrypoint)
        try requireGeneratedPathsAvailable([configurationURL, entrypointURL])
        let placeholder = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Lively URL Wallpaper</title></head>
        <body><p>This HTTPS wallpaper is opened securely by Background Engine.</p></body></html>
        """
        do {
            try JSONEncoder().encode(configuration).write(to: configurationURL, options: .atomic)
            try Data(placeholder.utf8).write(to: entrypointURL, options: .atomic)
        } catch {
            throw LivelyWallpaperImportError.cannotCreateGeneratedEntrypoint
        }
    }

    private static func requireGeneratedPathsAvailable(_ urls: [URL]) throws {
        for url in urls {
            var attributes = stat()
            let status = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.lstat(path, &attributes)
            }
            if status == 0 || errno != ENOENT {
                throw LivelyWallpaperImportError.generatedFileConflict
            }
        }
    }

    private static func writeUnsupportedApplicationPlaceholder(
        entrypoint: String,
        root: URL
    ) throws {
        let entrypointURL = root.appending(path: entrypoint)
        try requireGeneratedPathsAvailable([entrypointURL])
        do {
            try Data().write(to: entrypointURL, options: .atomic)
        } catch {
            throw LivelyWallpaperImportError.cannotCreateGeneratedEntrypoint
        }
    }

    private static func optionalExistingRelativeFile(
        _ raw: Any?,
        useBasename: Bool,
        root: URL
    ) throws -> String? {
        guard let value = boundedString(raw, maximumLength: 4_096), !value.isEmpty else { return nil }
        let relativeValue: String
        if useBasename {
            // Lively stores artwork beside LivelyInfo.json even when imported
            // metadata retains an absolute path from its original machine.
            // Resolve only the basename inside our private staged copy; never
            // inspect the external path.
            relativeValue = value.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/", omittingEmptySubsequences: true)
                .last
                .map(String.init) ?? ""
        } else {
            relativeValue = value
        }
        let path = try safeRelativePath(relativeValue)
        let candidate = root.appending(path: path).standardizedFileURL
        guard isStrictDescendant(candidate, of: root) else {
            throw LivelyWallpaperImportError.unsafeMetadataPath(value)
        }
        // Lively independently resolves Preview and Thumbnail and treats a
        // stale/missing optional path as nil. Preserve that fallback behavior
        // while still rejecting unsafe relative paths above.
        return isRegularFile(candidate) ? path : nil
    }

    fileprivate static func safeRelativePath(_ raw: String) throws -> String {
        let path = raw.replacingOccurrences(of: "\\", with: "/")
            .precomposedStringWithCanonicalMapping
        guard !path.isEmpty,
              !path.contains("\0"),
              !path.hasPrefix("/"),
              path.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil else {
            throw LivelyWallpaperImportError.unsafeMetadataPath(raw)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LivelyWallpaperImportError.unsafeMetadataPath(raw)
        }
        return components.joined(separator: "/")
    }

    private static func safeTitle(_ raw: Any?, fallback: String) -> String {
        boundedString(raw, maximumLength: 1_024)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? fallback
    }

    private static func boundedString(_ raw: Any?, maximumLength: Int) -> String? {
        guard let value = raw as? String,
              value.count <= maximumLength,
              !value.contains("\0") else { return nil }
        return value
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        if let number = raw as? NSNumber, isBoolean(number) { return number.boolValue }
        if let string = raw as? String {
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private static func finiteNumber(_ raw: Any?) -> Double? {
        let value: Double?
        if let number = raw as? NSNumber, !isBoolean(number) {
            value = number.doubleValue
        } else if let string = raw as? String {
            value = Double(string)
        } else {
            value = nil
        }
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func integerValue(_ raw: Any?) -> Int? {
        guard let number = finiteNumber(raw),
              number.rounded(.towardZero) == number,
              number >= Double(Int.min), number <= Double(Int.max) else { return nil }
        return Int(number)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func isSafePropertyName(_ value: String) -> Bool {
        !value.isEmpty
            && value.lengthOfBytes(using: .utf8) <= WebWallpaperUserFileStore.maximumPropertyNameBytes
            && !value.contains("\0")
    }

    /// Lively's own wallpaper packages commonly use JSON-with-comments and
    /// trailing commas even though the file is named `.json`. Normalize only
    /// that documented, bounded extension; quoted comment markers and commas
    /// remain byte-for-byte data, while malformed strings/comments fail closed.
    private static func normalizingLivelyJSONC(_ data: Data) throws -> Data {
        guard var input = String(data: data, encoding: .utf8) else {
            throw LivelyWallpaperImportError.malformedProperties
        }
        var uncommented = ""
        uncommented.reserveCapacity(input.utf8.count)
        var index = input.startIndex
        var inString = false
        var escaped = false
        var inBlockComment = false
        while index < input.endIndex {
            let character = input[index]
            let next = input.index(after: index)
            if inBlockComment {
                if character == "*", next < input.endIndex, input[next] == "/" {
                    uncommented.append(" ")
                    uncommented.append(" ")
                    index = input.index(after: next)
                } else {
                    uncommented.append(character == "\n" || character == "\r" ? character : " ")
                    index = next
                }
                if character == "*", next < input.endIndex, input[next] == "/" {
                    inBlockComment = false
                }
                continue
            }
            if inString {
                uncommented.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = next
                continue
            }
            if character == "\"" {
                inString = true
                uncommented.append(character)
                index = next
                continue
            }
            if character == "/", next < input.endIndex, input[next] == "/" {
                uncommented.append(" ")
                uncommented.append(" ")
                index = input.index(after: next)
                while index < input.endIndex, input[index] != "\n", input[index] != "\r" {
                    uncommented.append(" ")
                    index = input.index(after: index)
                }
                continue
            }
            if character == "/", next < input.endIndex, input[next] == "*" {
                uncommented.append(" ")
                uncommented.append(" ")
                inBlockComment = true
                index = input.index(after: next)
                continue
            }
            uncommented.append(character)
            index = next
        }
        input.removeAll(keepingCapacity: false)
        guard !inString, !inBlockComment else {
            throw LivelyWallpaperImportError.malformedProperties
        }

        var normalized = ""
        normalized.reserveCapacity(uncommented.utf8.count)
        index = uncommented.startIndex
        inString = false
        escaped = false
        while index < uncommented.endIndex {
            let character = uncommented[index]
            let next = uncommented.index(after: index)
            if inString {
                normalized.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = next
                continue
            }
            if character == "\"" {
                inString = true
                normalized.append(character)
                index = next
                continue
            }
            if character == "," {
                var lookahead = next
                while lookahead < uncommented.endIndex,
                      uncommented[lookahead].isWhitespace {
                    lookahead = uncommented.index(after: lookahead)
                }
                if lookahead < uncommented.endIndex {
                    let following = uncommented[lookahead]
                    if following == "}" || following == "]" {
                        index = next
                        continue
                    }
                }
            }
            normalized.append(character)
            index = next
        }
        guard !inString else { throw LivelyWallpaperImportError.malformedProperties }
        return Data(normalized.utf8)
    }

    @discardableResult
    private func validateTree(_ root: URL) throws -> ValidatedTree {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw LivelyWallpaperImportError.unsafeTree(root.path)
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            ],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw LivelyWallpaperImportError.unsafeTree(root.path)
        }
        var count = 0
        var total: UInt64 = 0
        var paths: [String: TreeNodeKind] = [:]
        var files: Set<String> = []
        for case let url as URL in enumerator {
            if let enumerationError { throw enumerationError }
            try Task.checkCancellation()
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true,
                  Self.isStrictDescendant(url, of: root) else {
                throw LivelyWallpaperImportError.unsafeTree(url.path)
            }
            let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            let itemComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard itemComponents.count > rootComponents.count,
                  Array(itemComponents.prefix(rootComponents.count)) == rootComponents else {
                throw LivelyWallpaperImportError.unsafeTree(url.path)
            }
            let relative = itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
            let normalized = try Self.normalizedTreePath(relative)
            let kind: TreeNodeKind = values.isDirectory == true ? .directory : .file
            guard paths[normalized] == nil else {
                throw LivelyWallpaperImportError.pathCollision(relative)
            }
            paths[normalized] = kind
            count += 1
            guard count <= limits.maximumEntries else {
                throw LivelyWallpaperImportError.tooManyEntries(count, limits.maximumEntries)
            }
            if kind == .file {
                let size = UInt64(max(0, values.fileSize ?? 0))
                guard size <= limits.maximumEntryBytes else {
                    throw LivelyWallpaperImportError.entryTooLarge(relative, size)
                }
                guard total <= limits.maximumUncompressedBytes - min(
                    size,
                    limits.maximumUncompressedBytes
                ) else {
                    throw LivelyWallpaperImportError.uncompressedDataTooLarge
                }
                total += size
                files.insert(normalized)
            }
        }
        if let enumerationError { throw enumerationError }
        return ValidatedTree(files: files)
    }

    private static func normalizedTreePath(_ raw: String) throws -> String {
        let path = try safeRelativePath(raw)
        guard path.unicodeScalars.allSatisfy({ $0.value > 0x1f && $0.value != 0x7f }) else {
            throw LivelyWallpaperImportError.unsafeMetadataPath(raw)
        }
        return path.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func isStrictDescendant(_ url: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let urlComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return urlComponents.count > rootComponents.count
            && Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func readBoundedRegularFile(
        _ url: URL,
        maximumBytes: Int,
        tooLarge: LivelyWallpaperImportError
    ) throws -> Data {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw LivelyWallpaperImportError.unsafeTree(url.path)
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            throw LivelyWallpaperImportError.unsafeTree(url.path)
        }
        guard status.st_size >= 0, status.st_size <= maximumBytes else { throw tooLarge }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let amount = Darwin.read(descriptor, &buffer, buffer.count)
            if amount == 0 { return result }
            if amount < 0 {
                if errno == EINTR { continue }
                throw LivelyWallpaperImportError.unsafeTree(url.path)
            }
            guard result.count + amount <= maximumBytes else { throw tooLarge }
            result.append(contentsOf: buffer.prefix(amount))
        }
    }

    private static func makePrivateTemporaryDirectory() throws -> URL {
        let template = FileManager.default.temporaryDirectory
            .appending(path: "background-engine-lively.XXXXXX").path
        var bytes = Array(template.utf8CString)
        guard let created = mkdtemp(&bytes) else {
            throw LivelyWallpaperImportError.cannotCreateStaging
        }
        let url = URL(filePath: String(cString: created), directoryHint: .isDirectory)
        guard chmod(url.path, S_IRWXU) == 0 else {
            try? FileManager.default.removeItem(at: url)
            throw LivelyWallpaperImportError.cannotCreateStaging
        }
        return url
    }
}

private struct LivelyEntryExtractionOutcome: Sendable {
    let terminationStatus: Int32
    let observedBytes: UInt64
}

private enum LivelyEntryExtractionRace: Sendable {
    case completed(LivelyEntryExtractionOutcome)
    case timedOut
}

private enum LivelyEntryExtractionFailure: Error, Sendable {
    case launchOrIOFailure
    case outputExceeded(UInt64)
}

/// Runs one trusted `/usr/bin/unzip -p` invocation without the general process
/// supervisor. Stdout is a pipe, so the child cannot write directly to disk:
/// the app copies only the declared number of bytes into its descriptor-bound
/// `O_EXCL | O_NOFOLLOW` destination. Closing the app side also gives unzip a
/// broken pipe if the owner exits unexpectedly.
private final class LivelyEntryExtractionProcess: @unchecked Sendable {
    private enum StopReason: Sendable {
        case cancellation
        case outputExceeded(UInt64)
        case ioFailure
    }

    private static let bufferSize = 16 * 1_024
    private static let terminationGrace = DispatchTimeInterval.milliseconds(250)

    private let executable: URL
    private let arguments: [String]
    private let currentDirectory: URL
    private let outputDescriptor: Int32
    private let expectedBytes: UInt64
    private let standardError: FileHandle
    private let lock = NSLock()
    private var processIdentifier: Int32?
    private var stopReason: StopReason?
    private var finished = false

    init(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        outputDescriptor: Int32,
        expectedBytes: UInt64,
        standardError: FileHandle
    ) {
        self.executable = executable
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.outputDescriptor = outputDescriptor
        self.expectedBytes = expectedBytes
        self.standardError = standardError
    }

    func run() async throws -> LivelyEntryExtractionOutcome {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.runBlocking())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        requestStop(.cancellation)
    }

    private func runBlocking() throws -> LivelyEntryExtractionOutcome {
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = standardError
        defer {
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
        }

        do {
            try process.run()
        } catch {
            markFinished()
            throw LivelyEntryExtractionFailure.launchOrIOFailure
        }
        try? outputPipe.fileHandleForWriting.close()

        let processIdentifier = process.processIdentifier
        let wasAlreadyStopped = lock.withLock { () -> Bool in
            self.processIdentifier = processIdentifier
            return stopReason != nil
        }
        if wasAlreadyStopped {
            signalAndEscalate(processIdentifier)
        }

        var observedBytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
        extractionLoop: while true {
            let amount: Int = buffer.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.read(
                    outputPipe.fileHandleForReading.fileDescriptor,
                    baseAddress,
                    bytes.count
                )
            }
            if amount == 0 { break }
            if amount < 0 {
                if errno == EINTR { continue }
                requestStop(.ioFailure)
                break
            }

            let (nextObserved, overflowed) = observedBytes.addingReportingOverflow(UInt64(amount))
            let remaining = expectedBytes - min(observedBytes, expectedBytes)
            let permitted = Int(min(UInt64(amount), remaining))
            if permitted > 0 {
                do {
                    try Self.writeAll(
                        buffer: buffer,
                        count: permitted,
                        to: outputDescriptor
                    )
                } catch {
                    requestStop(.ioFailure)
                    break extractionLoop
                }
            }
            observedBytes = overflowed ? UInt64.max : nextObserved
            if observedBytes > expectedBytes {
                requestStop(.outputExceeded(observedBytes))
                break
            }
        }

        process.waitUntilExit()
        let reason = markFinished()
        switch reason {
        case .cancellation:
            throw CancellationError()
        case .outputExceeded(let actual):
            throw LivelyEntryExtractionFailure.outputExceeded(actual)
        case .ioFailure:
            throw LivelyEntryExtractionFailure.launchOrIOFailure
        case nil:
            return LivelyEntryExtractionOutcome(
                terminationStatus: process.terminationStatus,
                observedBytes: observedBytes
            )
        }
    }

    private func requestStop(_ reason: StopReason) {
        let processIdentifier: Int32? = lock.withLock {
            guard !finished else { return nil }
            if stopReason == nil { stopReason = reason }
            return self.processIdentifier
        }
        if let processIdentifier {
            signalAndEscalate(processIdentifier)
        }
    }

    private func signalAndEscalate(_ processIdentifier: Int32) {
        guard processIdentifier > 1 else { return }
        _ = Darwin.kill(processIdentifier, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.terminationGrace
        ) { [self] in
            let shouldKill = lock.withLock {
                !finished && self.processIdentifier == processIdentifier
            }
            if shouldKill {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }
    }

    @discardableResult
    private func markFinished() -> StopReason? {
        lock.withLock {
            finished = true
            processIdentifier = nil
            return stopReason
        }
    }

    private static func writeAll(
        buffer: [UInt8],
        count: Int,
        to descriptor: Int32
    ) throws {
        try buffer.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < count {
                let amount = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    count - written
                )
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw LivelyEntryExtractionFailure.launchOrIOFailure
                }
                guard amount > 0 else {
                    throw LivelyEntryExtractionFailure.launchOrIOFailure
                }
                written += amount
            }
        }
    }
}

private struct LivelyPropertyConversion {
    let properties: [String: Any]
    let limitations: Set<LivelyPropertyLimitation>
}

private enum LivelyPropertyLimitation: String, Hashable {
    case folderDropdown
    case nativeMediaProperties
    case neutralAudioReactive
    case unmappedControl
}

private enum LivelyWallpaperType: Int {
    case application = 0
    case web = 1
    case webAudio = 2
    case url = 3
    case bizhawk = 4
    case unity = 5
    case godot = 6
    case video = 7
    case gif = 8
    case unityAudio = 9
    case videoStream = 10
    case picture = 11

    var projectType: String {
        switch self {
        case .web, .webAudio, .url: "web"
        case .video, .videoStream: "video"
        case .gif, .picture: "image"
        case .application, .bizhawk, .unity, .godot, .unityAudio: "application"
        }
    }

    var requiresNeutralAudio: Bool {
        self == .webAudio
    }

    var usesNativeMediaPlayback: Bool {
        switch self {
        case .video, .gif, .picture: true
        default: false
        }
    }
}

private struct ValidatedTree {
    let files: Set<String>
}

private struct LivelyDirectoryCopyState {
    var entryCount = 0
    var totalBytes: UInt64 = 0
    var normalizedPaths: Set<String> = []
}

private enum TreeNodeKind: Equatable {
    case file
    case directory
}

public enum LivelyWallpaperImportError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSource(String)
    case cannotCreateStaging
    case missingOrAmbiguousMetadata
    case metadataTooLarge
    case propertiesTooLarge
    case malformedMetadata
    case malformedProperties
    case missingMetadataField(String)
    case absolutePathMetadata
    case unsupportedRemoteURL
    case generatedFileConflict
    case cannotCreateGeneratedEntrypoint
    case unsupportedWallpaperType
    case unsafeMetadataPath(String)
    case missingReferencedFile(String, String)
    case unsafeTree(String)
    case pathCollision(String)
    case tooManyEntries(Int, Int)
    case archiveTooLarge(actual: UInt64, limit: UInt64)
    case entryTooLarge(String, UInt64)
    case uncompressedDataTooLarge
    case invalidZIP
    case encryptedZIP
    case multiDiskZIP
    case unsupportedZIPFeature(String)
    case compressionRatioTooHigh(String)
    case unzipUnavailable(String)
    case extractionFailed(Int32)
    case extractionTimedOut(String)
    case extractedEntrySizeMismatch(String, actual: UInt64, expected: UInt64)
    case extractedEntryChecksumMismatch(String)
    case extractedTreeMismatch
    case normalizedProjectMissing

    public var errorDescription: String? {
        switch self {
        case .unsupportedSource: "Choose a Lively project folder or .zip export."
        case .cannotCreateStaging: "A private Lively import staging directory could not be created."
        case .missingOrAmbiguousMetadata:
            "LivelyInfo.json must be at the package root or inside exactly one wrapper directory."
        case .metadataTooLarge: "LivelyInfo.json exceeds the 1 MiB metadata limit."
        case .propertiesTooLarge: "LivelyProperties.json exceeds the 1 MiB metadata limit."
        case .malformedMetadata: "LivelyInfo.json is malformed."
        case .malformedProperties: "LivelyProperties.json is malformed."
        case .missingMetadataField(let field): "LivelyInfo.json is missing \(field)."
        case .absolutePathMetadata: "Lively packages that use absolute paths cannot be imported safely."
        case .unsupportedRemoteURL:
            "Lively URL and video-stream wallpapers require a public HTTPS URL without credentials."
        case .generatedFileConflict:
            "The Lively package conflicts with a reserved Background Engine compatibility file."
        case .cannotCreateGeneratedEntrypoint:
            "Background Engine could not create the Lively URL compatibility entrypoint."
        case .unsupportedWallpaperType: "This Lively wallpaper type is unknown."
        case .unsafeMetadataPath(let path): "Lively metadata contains an unsafe path: \(path)"
        case .missingReferencedFile(let field, let path): "\(field) does not reference a regular package file: \(path)"
        case .unsafeTree(let path): "The Lively package contains a symbolic link or special item: \(path)"
        case .pathCollision(let path): "The Lively package contains a duplicate or ambiguous path: \(path)"
        case .tooManyEntries(let actual, let limit): "The Lively package has too many entries (\(actual), limit \(limit))."
        case .archiveTooLarge(let actual, let limit): "The ZIP archive is too large (\(actual) bytes, limit \(limit))."
        case .entryTooLarge(let path, let size): "ZIP entry \(path) is too large (\(size) bytes)."
        case .uncompressedDataTooLarge: "The Lively package expands beyond the safe import limit."
        case .invalidZIP: "The selected ZIP archive is malformed."
        case .encryptedZIP: "Encrypted ZIP archives are not supported."
        case .multiDiskZIP: "Multi-disk ZIP archives are not supported."
        case .unsupportedZIPFeature(let feature): "The ZIP archive uses an unsupported feature: \(feature)."
        case .compressionRatioTooHigh(let path): "ZIP entry \(path) has an unsafe compression ratio."
        case .unzipUnavailable(let path): "The system ZIP extractor is unavailable at \(path)."
        case .extractionFailed(let status): "The system ZIP extractor failed with status \(status)."
        case .extractionTimedOut(let path): "Extracting ZIP entry \(path) timed out."
        case .extractedEntrySizeMismatch(let path, let actual, let expected):
            "ZIP entry \(path) produced \(actual) bytes instead of the declared \(expected) bytes."
        case .extractedEntryChecksumMismatch(let path):
            "ZIP entry \(path) did not match its declared checksum."
        case .extractedTreeMismatch: "The extracted ZIP contents do not match the validated archive."
        case .normalizedProjectMissing: "The normalized Lively package does not contain one playable project."
        }
    }
}

private struct LivelyZIPArchive {
    private static let endSignature: UInt32 = 0x0605_4b50
    private static let centralSignature: UInt32 = 0x0201_4b50
    private static let localSignature: UInt32 = 0x0403_4b50

    let filePaths: Set<String>
    let entries: [LivelyZIPEntry]

    init(url: URL, limits: LivelyWallpaperPackageImporter.Limits) throws {
        let reader = try ZIPReader(url: url, maximumBytes: limits.maximumArchiveBytes)
        defer { reader.close() }
        let end = try Self.readEndRecord(reader)
        guard end.diskNumber == 0,
              end.centralDisk == 0,
              end.entriesOnDisk == end.totalEntries else {
            throw LivelyWallpaperImportError.multiDiskZIP
        }
        guard end.totalEntries > 0, Int(end.totalEntries) <= limits.maximumEntries else {
            if Int(end.totalEntries) > limits.maximumEntries {
                throw LivelyWallpaperImportError.tooManyEntries(
                    Int(end.totalEntries),
                    limits.maximumEntries
                )
            }
            throw LivelyWallpaperImportError.invalidZIP
        }
        guard end.centralOffset != UInt32.max,
              end.centralSize != UInt32.max,
              UInt64(end.centralOffset) + UInt64(end.centralSize) == end.recordOffset else {
            throw LivelyWallpaperImportError.unsupportedZIPFeature("ZIP64 or invalid central directory")
        }

        var cursor = UInt64(end.centralOffset)
        let centralEnd = cursor + UInt64(end.centralSize)
        var total: UInt64 = 0
        var nodes: [String: ZIPNode] = [:]
        var filePaths: Set<String> = []
        var entries: [LivelyZIPEntry] = []
        var occupiedRanges: [Range<UInt64>] = []
        for _ in 0..<Int(end.totalEntries) {
            let fixed = try reader.read(offset: cursor, count: 46)
            guard fixed.uint32LE(at: 0) == Self.centralSignature else {
                throw LivelyWallpaperImportError.invalidZIP
            }
            let madeBy = fixed.uint16LE(at: 4)
            let needed = fixed.uint16LE(at: 6)
            let flags = fixed.uint16LE(at: 8)
            let method = fixed.uint16LE(at: 10)
            let crc = fixed.uint32LE(at: 16)
            let compressed = fixed.uint32LE(at: 20)
            let uncompressed = fixed.uint32LE(at: 24)
            let nameLength = Int(fixed.uint16LE(at: 28))
            let extraLength = Int(fixed.uint16LE(at: 30))
            let commentLength = Int(fixed.uint16LE(at: 32))
            let diskStart = fixed.uint16LE(at: 34)
            let externalAttributes = fixed.uint32LE(at: 38)
            let localOffset = fixed.uint32LE(at: 42)
            guard needed <= 20,
                  compressed != UInt32.max,
                  uncompressed != UInt32.max,
                  localOffset != UInt32.max else {
                throw LivelyWallpaperImportError.unsupportedZIPFeature("ZIP64")
            }
            guard diskStart == 0 else { throw LivelyWallpaperImportError.multiDiskZIP }
            try Self.validateFlags(flags, method: method)
            guard method == 0 || method == 8 else {
                throw LivelyWallpaperImportError.unsupportedZIPFeature("compression method \(method)")
            }
            guard method != 0 || compressed == uncompressed else {
                throw LivelyWallpaperImportError.invalidZIP
            }
            let variableCount = try Self.checkedSum(nameLength, extraLength, commentLength)
            guard cursor + 46 + UInt64(variableCount) <= centralEnd else {
                throw LivelyWallpaperImportError.invalidZIP
            }
            let variable = try reader.read(offset: cursor + 46, count: variableCount)
            let nameData = variable.prefix(nameLength)
            let extra = variable.dropFirst(nameLength).prefix(extraLength)
            guard !Self.containsExtraField(0x0001, in: extra),
                  !Self.containsExtraField(0x9901, in: extra),
                  !Self.containsExtraField(0x7075, in: extra) else {
                throw LivelyWallpaperImportError.unsupportedZIPFeature(
                    "ZIP64, AES encryption, or Unicode path overrides"
                )
            }
            let rawName = try Self.decodeName(Data(nameData), flags: flags)
            let isDirectory = try Self.isDirectory(
                rawName: rawName,
                madeBy: madeBy,
                externalAttributes: externalAttributes
            )
            let registeredPath = try Self.registerPath(
                rawName,
                isDirectory: isDirectory,
                nodes: &nodes
            )
            let path = registeredPath.normalizedKey

            let uncompressedSize = UInt64(uncompressed)
            let compressedSize = UInt64(compressed)
            guard uncompressedSize <= limits.maximumEntryBytes else {
                throw LivelyWallpaperImportError.entryTooLarge(path, uncompressedSize)
            }
            guard total <= limits.maximumUncompressedBytes - min(
                uncompressedSize,
                limits.maximumUncompressedBytes
            ) else {
                throw LivelyWallpaperImportError.uncompressedDataTooLarge
            }
            total += uncompressedSize
            if uncompressedSize > 0 {
                guard compressedSize > 0,
                      Double(uncompressedSize) / Double(compressedSize) <= limits.maximumCompressionRatio else {
                    throw LivelyWallpaperImportError.compressionRatioTooHigh(path)
                }
            }
            if isDirectory {
                guard compressed == 0, uncompressed == 0 else {
                    throw LivelyWallpaperImportError.invalidZIP
                }
            } else {
                filePaths.insert(path)
            }
            entries.append(
                LivelyZIPEntry(
                    archiveName: rawName,
                    destinationPath: registeredPath.destinationPath,
                    isDirectory: isDirectory,
                    uncompressedSize: uncompressedSize,
                    crc32: crc
                )
            )

            let localRange = try Self.validateLocalHeader(
                reader: reader,
                offset: UInt64(localOffset),
                centralOffset: UInt64(end.centralOffset),
                expectedName: Data(nameData),
                flags: flags,
                method: method,
                crc: crc,
                compressed: compressed,
                uncompressed: uncompressed
            )
            occupiedRanges.append(localRange)
            cursor += 46 + UInt64(variableCount)
        }
        guard cursor == centralEnd else { throw LivelyWallpaperImportError.invalidZIP }
        occupiedRanges.sort { $0.lowerBound < $1.lowerBound }
        for index in occupiedRanges.indices.dropFirst() {
            guard occupiedRanges[index - 1].upperBound <= occupiedRanges[index].lowerBound else {
                throw LivelyWallpaperImportError.invalidZIP
            }
        }
        self.filePaths = filePaths
        self.entries = entries
    }

    private static func readEndRecord(_ reader: ZIPReader) throws -> EndRecord {
        let tailSize = Int(min(reader.size, 65_557))
        let tailOffset = reader.size - UInt64(tailSize)
        let tail = try reader.read(offset: tailOffset, count: tailSize)
        guard tail.count >= 22 else { throw LivelyWallpaperImportError.invalidZIP }
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            guard tail.uint32LE(at: index) == endSignature else { continue }
            let commentLength = Int(tail.uint16LE(at: index + 20))
            guard index + 22 + commentLength == tail.count else { continue }
            return EndRecord(
                diskNumber: tail.uint16LE(at: index + 4),
                centralDisk: tail.uint16LE(at: index + 6),
                entriesOnDisk: tail.uint16LE(at: index + 8),
                totalEntries: tail.uint16LE(at: index + 10),
                centralSize: tail.uint32LE(at: index + 12),
                centralOffset: tail.uint32LE(at: index + 16),
                recordOffset: tailOffset + UInt64(index)
            )
        }
        throw LivelyWallpaperImportError.invalidZIP
    }

    private static func validateFlags(_ flags: UInt16, method: UInt16) throws {
        if flags & 0x2041 != 0 { throw LivelyWallpaperImportError.encryptedZIP }
        let allowed: UInt16 = 0x080e
        guard flags & ~allowed == 0,
              method == 8 || flags & 0x0006 == 0 else {
            throw LivelyWallpaperImportError.unsupportedZIPFeature("general-purpose flags")
        }
    }

    private static func decodeName(_ data: Data, flags: UInt16) throws -> String {
        guard !data.isEmpty, !data.contains(0) else {
            throw LivelyWallpaperImportError.invalidZIP
        }
        if flags & 0x0800 != 0 {
            guard let value = String(data: data, encoding: .utf8) else {
                throw LivelyWallpaperImportError.invalidZIP
            }
            return value
        }
        guard data.allSatisfy({ $0 < 0x80 }) else {
            throw LivelyWallpaperImportError.unsupportedZIPFeature("non-UTF-8 file names")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isDirectory(
        rawName: String,
        madeBy: UInt16,
        externalAttributes: UInt32
    ) throws -> Bool {
        let host = madeBy >> 8
        let mode = externalAttributes >> 16
        let fileType = mode & UInt32(S_IFMT)
        if host == 3, fileType != 0,
           fileType != UInt32(S_IFREG), fileType != UInt32(S_IFDIR) {
            throw LivelyWallpaperImportError.unsafeTree(rawName)
        }
        let trailingSlash = rawName.hasSuffix("/")
        let attributeDirectory = fileType == UInt32(S_IFDIR) || externalAttributes & 0x10 != 0
        if attributeDirectory && !trailingSlash {
            throw LivelyWallpaperImportError.invalidZIP
        }
        return trailingSlash
    }

    private static func registerPath(
        _ raw: String,
        isDirectory: Bool,
        nodes: inout [String: ZIPNode]
    ) throws -> RegisteredZIPPath {
        let pathWithoutSlash = isDirectory ? String(raw.dropLast()) : raw
        guard !pathWithoutSlash.contains("\\"),
              !pathWithoutSlash.hasPrefix("-"),
              pathWithoutSlash.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]")) == nil else {
            throw LivelyWallpaperImportError.unsafeMetadataPath(raw)
        }
        let safe = try LivelyWallpaperPackageImporter.safeRelativePath(pathWithoutSlash)
        guard safe.unicodeScalars.allSatisfy({ $0.value > 0x1f && $0.value != 0x7f }) else {
            throw LivelyWallpaperImportError.unsafeMetadataPath(raw)
        }
        let components = safe.split(separator: "/").map(String.init)
        var current: [String] = []
        for component in components.dropLast() {
            current.append(component)
            let key = try normalizedKey(current.joined(separator: "/"))
            if let node = nodes[key], node.kind == .file {
                throw LivelyWallpaperImportError.pathCollision(safe)
            }
            if nodes[key] == nil { nodes[key] = ZIPNode(kind: .directory, explicit: false) }
        }
        let key = try normalizedKey(safe)
        let kind: TreeNodeKind = isDirectory ? .directory : .file
        if let existing = nodes[key] {
            if existing.kind == .directory, !existing.explicit, kind == .directory {
                nodes[key] = ZIPNode(kind: .directory, explicit: true)
            } else {
                throw LivelyWallpaperImportError.pathCollision(safe)
            }
        } else {
            nodes[key] = ZIPNode(kind: kind, explicit: true)
        }
        return RegisteredZIPPath(destinationPath: safe, normalizedKey: key)
    }

    private static func normalizedKey(_ path: String) throws -> String {
        let safe = try LivelyWallpaperPackageImporter.safeRelativePath(path)
        return safe.precomposedStringWithCanonicalMapping
            .folding(
                options: String.CompareOptions.caseInsensitive,
                locale: Locale(identifier: "en_US_POSIX")
            )
            .precomposedStringWithCanonicalMapping
    }

    private static func containsExtraField(_ identifier: UInt16, in extra: Data.SubSequence) -> Bool {
        var cursor = extra.startIndex
        while cursor + 4 <= extra.endIndex {
            let header = Data(extra[cursor..<extra.endIndex])
            let fieldID = header.uint16LE(at: 0)
            let length = Int(header.uint16LE(at: 2))
            guard cursor + 4 + length <= extra.endIndex else { return true }
            if fieldID == identifier { return true }
            cursor += 4 + length
        }
        return cursor != extra.endIndex
    }

    private static func validateLocalHeader(
        reader: ZIPReader,
        offset: UInt64,
        centralOffset: UInt64,
        expectedName: Data,
        flags: UInt16,
        method: UInt16,
        crc: UInt32,
        compressed: UInt32,
        uncompressed: UInt32
    ) throws -> Range<UInt64> {
        guard offset + 30 <= centralOffset else { throw LivelyWallpaperImportError.invalidZIP }
        let fixed = try reader.read(offset: offset, count: 30)
        guard fixed.uint32LE(at: 0) == localSignature,
              fixed.uint16LE(at: 4) <= 20,
              fixed.uint16LE(at: 6) == flags,
              fixed.uint16LE(at: 8) == method else {
            throw LivelyWallpaperImportError.invalidZIP
        }
        let localCRC = fixed.uint32LE(at: 14)
        let localCompressed = fixed.uint32LE(at: 18)
        let localUncompressed = fixed.uint32LE(at: 22)
        if flags & 0x0008 == 0 {
            guard localCRC == crc,
                  localCompressed == compressed,
                  localUncompressed == uncompressed else {
                throw LivelyWallpaperImportError.invalidZIP
            }
        } else {
            guard (localCRC == 0 || localCRC == crc),
                  (localCompressed == 0 || localCompressed == compressed),
                  (localUncompressed == 0 || localUncompressed == uncompressed) else {
                throw LivelyWallpaperImportError.invalidZIP
            }
        }
        let nameLength = Int(fixed.uint16LE(at: 26))
        let extraLength = Int(fixed.uint16LE(at: 28))
        guard nameLength == expectedName.count else { throw LivelyWallpaperImportError.invalidZIP }
        let name = try reader.read(offset: offset + 30, count: nameLength)
        guard name == expectedName else { throw LivelyWallpaperImportError.invalidZIP }
        let localExtra = try reader.read(
            offset: offset + 30 + UInt64(nameLength),
            count: extraLength
        )
        guard !containsExtraField(0x0001, in: localExtra[...]),
              !containsExtraField(0x9901, in: localExtra[...]),
              !containsExtraField(0x7075, in: localExtra[...]) else {
            throw LivelyWallpaperImportError.unsupportedZIPFeature(
                "ZIP64, AES encryption, or Unicode path overrides"
            )
        }
        let dataStart = offset + 30 + UInt64(nameLength) + UInt64(extraLength)
        let dataEnd = dataStart + UInt64(compressed)
        guard dataStart >= offset, dataEnd >= dataStart, dataEnd <= centralOffset else {
            throw LivelyWallpaperImportError.invalidZIP
        }
        return offset..<dataEnd
    }

    private static func checkedSum(_ values: Int...) throws -> Int {
        var result = 0
        for value in values {
            guard value >= 0, result <= Int.max - value else {
                throw LivelyWallpaperImportError.invalidZIP
            }
            result += value
        }
        return result
    }
}

private struct LivelyZIPEntry {
    let archiveName: String
    let destinationPath: String
    let isDirectory: Bool
    let uncompressedSize: UInt64
    let crc32: UInt32
}

private struct RegisteredZIPPath {
    let destinationPath: String
    let normalizedKey: String
}

private struct ZIPNode {
    let kind: TreeNodeKind
    let explicit: Bool
}

private struct EndRecord {
    let diskNumber: UInt16
    let centralDisk: UInt16
    let entriesOnDisk: UInt16
    let totalEntries: UInt16
    let centralSize: UInt32
    let centralOffset: UInt32
    let recordOffset: UInt64
}

private final class ZIPReader {
    let descriptor: Int32
    let size: UInt64

    init(url: URL, maximumBytes: UInt64) throws {
        descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw LivelyWallpaperImportError.invalidZIP }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0 else {
            Darwin.close(descriptor)
            throw LivelyWallpaperImportError.invalidZIP
        }
        size = UInt64(status.st_size)
        guard size <= maximumBytes else {
            Darwin.close(descriptor)
            throw LivelyWallpaperImportError.archiveTooLarge(actual: size, limit: maximumBytes)
        }
    }

    func close() {
        Darwin.close(descriptor)
    }

    func read(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0,
              offset <= size,
              UInt64(count) <= size - offset,
              offset <= UInt64(off_t.max) else {
            throw LivelyWallpaperImportError.invalidZIP
        }
        var result = Data(count: count)
        var completed = 0
        while completed < count {
            let amount = result.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.pread(
                    descriptor,
                    base.advanced(by: completed),
                    count - completed,
                    off_t(offset + UInt64(completed))
                )
            }
            if amount < 0 {
                if errno == EINTR { continue }
                throw LivelyWallpaperImportError.invalidZIP
            }
            guard amount > 0 else { throw LivelyWallpaperImportError.invalidZIP }
            completed += amount
        }
        return result
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[index(startIndex, offsetBy: offset)])
            | UInt16(self[index(startIndex, offsetBy: offset + 1)]) << 8
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(uint16LE(at: offset)) | UInt32(uint16LE(at: offset + 2)) << 16
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
