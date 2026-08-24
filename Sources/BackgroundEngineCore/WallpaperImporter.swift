import CryptoKit
import Foundation

/// Shares one FFmpeg process for every conversion cache key. A cancelled
/// waiter is detached without poisoning another active importer; the process
/// itself is cancelled as soon as no waiter still needs it.
actor ImportedVideoConversionCoordinator {
    static let shared = ImportedVideoConversionCoordinator()

    private struct Job {
        let id: UUID
        let task: Task<Void, Never>
        var acceptsWaiters: Bool
        var waiters: [UUID: CheckedContinuation<WallpaperAsset, any Error>]
        var drainingCancellationWaiters: [CheckedContinuation<WallpaperAsset, any Error>]
    }

    private var jobs: [String: Job] = [:]

    /// Internal observability used by concurrency regression tests. Keeping
    /// this actor-isolated avoids timing guesses in tests that need to prove a
    /// second waiter has joined before the first waiter is cancelled.
    func registeredWaiterCount(for key: String) -> Int {
        jobs[key]?.waiters.count ?? 0
    }

    func convert(
        key: String,
        operation: @escaping @Sendable () async throws -> WallpaperAsset
    ) async throws -> WallpaperAsset {
        while let draining = jobs[key], !draining.acceptsWaiters {
            // The previous process must finish its TERM/KILL/reap sequence
            // before a retry can write the same atomic cache destination.
            await draining.task.value
            try Task.checkCancellation()
        }

        let jobID: UUID
        if let existing = jobs[key] {
            jobID = existing.id
        } else {
            let id = UUID()
            let coordinator = self
            let task = Task.detached(priority: .utility) {
                let result: Result<WallpaperAsset, any Error>
                do {
                    try Task.checkCancellation()
                    let output = try await operation()
                    try Task.checkCancellation()
                    result = .success(output)
                } catch {
                    result = .failure(error)
                }
                await coordinator.complete(key: key, jobID: id, result: result)
            }
            jobs[key] = Job(
                id: id,
                task: task,
                acceptsWaiters: true,
                waiters: [:],
                drainingCancellationWaiters: []
            )
            jobID = id
        }

        let waiterID = UUID()
        let alreadyCancelled = Task.isCancelled
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard var job = jobs[key], job.id == jobID else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                job.waiters[waiterID] = continuation
                jobs[key] = job
                if alreadyCancelled {
                    cancelWaiter(key: key, jobID: jobID, waiterID: waiterID)
                }
            }
        }, onCancel: {
            Task {
                await self.cancelWaiter(
                    key: key,
                    jobID: jobID,
                    waiterID: waiterID
                )
            }
        })
    }

    private func cancelWaiter(key: String, jobID: UUID, waiterID: UUID) {
        guard var job = jobs[key], job.id == jobID,
              let continuation = job.waiters.removeValue(forKey: waiterID) else {
            return
        }
        if job.waiters.isEmpty {
            job.acceptsWaiters = false
            job.drainingCancellationWaiters.append(continuation)
            jobs[key] = job
            job.task.cancel()
        } else {
            jobs[key] = job
            continuation.resume(throwing: CancellationError())
        }
    }

    private func complete(
        key: String,
        jobID: UUID,
        result: Result<WallpaperAsset, any Error>
    ) {
        guard let job = jobs[key], job.id == jobID else { return }
        jobs[key] = nil
        for continuation in job.drainingCancellationWaiters {
            continuation.resume(throwing: CancellationError())
        }
        for continuation in job.waiters.values {
            continuation.resume(with: result)
        }
    }
}

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
    private let videoConverter: VideoConverter
    private let convertedVideoCacheDirectory: URL

    public init(
        store: LibraryStore,
        scanner: WallpaperScanner = WallpaperScanner(),
        limits: Limits = Limits(),
        videoConverter: VideoConverter = VideoConverter(),
        convertedVideoCacheDirectory: URL? = nil
    ) {
        let cacheDirectory = convertedVideoCacheDirectory
            ?? VideoConversionCacheLocation.defaultDirectory()
        self.store = store.usingConvertedVideoCacheDirectory(cacheDirectory)
        self.scanner = scanner
        self.limits = limits
        self.videoConverter = videoConverter
        self.convertedVideoCacheDirectory = cacheDirectory
    }

    public func scan(root: URL) throws -> ScanResult {
        try validateTree(root)
        return try scanner.scan(root: root)
    }

    /// Copies a project into the private library. This preserves the original
    /// synchronous actor API; callers that also want automatic FFmpeg
    /// preparation use `importAndPrepareAsset`.
    public func importAsset(_ asset: WallpaperAsset) throws -> WallpaperAsset {
        let source = URL(filePath: asset.projectDirectory).standardizedFileURL
        try validateTree(source)
        // LibraryStore performs the authoritative deduplication while holding
        // its root-shared manifest lock. Validation and hashing are repeated
        // against the immutable staging copy so a changing source cannot make
        // the manifest or conversion cache key describe different bytes.
        return try store.importAsset(asset) { staging in
            try validateTree(staging)
            let stagedScan = try scanner.scan(root: staging)
            guard let staged = stagedScan.assets.first else {
                throw WallpaperImportError.stagedProjectMissing(asset.id)
            }
            let stagedContentHash = try WallpaperContentHasher.hashDirectory(staging)
            let preservedNetworkAccess: Bool?
            if staged.kind == .web {
                preservedNetworkAccess = asset.allowsNetworkAccess == true
                    && asset.contentHash == stagedContentHash
            } else {
                preservedNetworkAccess = asset.allowsNetworkAccess
            }
            let stagedAsset = WallpaperAsset(
                id: asset.id,
                title: asset.title,
                kind: staged.kind,
                supportStatus: staged.supportStatus,
                source: asset.source,
                projectDirectory: staging.path,
                entrypoint: staged.entrypoint,
                thumbnail: staged.thumbnail,
                workshopId: asset.workshopId,
                dateAdded: asset.dateAdded,
                contentHash: stagedContentHash,
                compatibility: staged.compatibility,
                compatibilityReport: staged.compatibilityReport,
                allowsNetworkAccess: preservedNetworkAccess,
                redistributionAllowed: false,
                issues: staged.issues
            )
            return staged.kind == .web
                ? stagedAsset.allowingNetworkAccess(preservedNetworkAccess == true)
                : stagedAsset
        }
    }

    public func importAndPrepareAsset(_ asset: WallpaperAsset) async throws -> WallpaperAsset {
        try await prepareVideoForPlaybackIfNeeded(importAsset(asset))
    }

    public func importVideoFile(_ url: URL) throws -> WallpaperAsset {
        try importStandaloneFile(url) { try store.importVideoFile($0) }
    }

    public func importAndPrepareVideoFile(_ url: URL) async throws -> WallpaperAsset {
        try await prepareVideoForPlaybackIfNeeded(importVideoFile(url))
    }

    public func importMediaFile(_ url: URL) throws -> WallpaperAsset {
        try importStandaloneFile(url) { try store.importMediaFile($0) }
    }

    public func importAndPrepareMediaFile(_ url: URL) async throws -> WallpaperAsset {
        try await prepareVideoForPlaybackIfNeeded(importMediaFile(url))
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

    /// Converts every imported video that AVFoundation cannot play, regardless
    /// of whether it came from a standalone picker, a copied folder, legacy
    /// migration, or SteamCMD. Import remains durable when conversion fails:
    /// the original private-library copy is kept and receives an actionable
    /// issue so a later Retry can reuse it.
    private func prepareVideoForPlaybackIfNeeded(_ asset: WallpaperAsset) async throws -> WallpaperAsset {
        guard asset.kind == .video, asset.supportStatus == .needsConversion else {
            return asset
        }
        guard let entrypoint = asset.entrypoint else {
            return try persistAutomaticConversionFailure(
                for: asset,
                message: "The imported video has no entrypoint."
            )
        }
        guard videoConverter.ffmpegPath() != nil, videoConverter.ffprobePath() != nil else {
            return try persistAutomaticConversionFailure(
                for: asset,
                message: "The bundled FFmpeg runtime is unavailable."
            )
        }

        let input = URL(filePath: entrypoint)
        let contentHash: String
        do {
            if let existingHash = asset.contentHash {
                contentHash = existingHash
            } else {
                let hashInput = try store.copyStableVideoInput(
                    for: asset,
                    originalInput: input,
                    into: convertedVideoCacheDirectory
                )
                defer { hashInput.cleanup() }
                contentHash = hashInput.contentHash
            }
        } catch is CancellationError {
            return try persistAutomaticConversionCancellation(for: asset)
        } catch {
            return try persistAutomaticConversionFailure(
                for: asset,
                message: automaticConversionFailureMessage(error)
            )
        }

        let output = convertedVideoCacheDirectory.appending(
            path: VideoConversionCacheKey(contentHash: contentHash).fileName
        )
        let converter = videoConverter
        do {
            return try await ImportedVideoConversionCoordinator.shared.convert(
                key: asset.id + "\u{0}" + output.standardizedFileURL.path
            ) {
                let stableInput = try self.store.copyStableVideoInput(
                    for: asset,
                    originalInput: input,
                    into: self.convertedVideoCacheDirectory
                )
                defer { stableInput.cleanup() }
                try await converter.convertToPlayableVideo(
                    input: stableInput,
                    output: output,
                    timeout: VideoConverter.defaultTimeout
                )
                var outputIsReferenced = false
                defer {
                    if !outputIsReferenced {
                        self.store.removeConvertedVideoIfUnreferenced(
                            output,
                            contentHash: contentHash
                        )
                    }
                }
                let persisted = try await self.persistConvertedVideo(asset, output: output)
                outputIsReferenced = persisted.entrypoint == output.path
                return persisted
            }
        } catch is CancellationError {
            return try persistAutomaticConversionCancellation(for: asset)
        } catch {
            return try persistAutomaticConversionFailure(
                for: asset,
                message: automaticConversionFailureMessage(error)
            )
        }
    }

    private func automaticConversionFailureMessage(_ error: Error) -> String {
        let message: String
        if let conversionError = error as? ConversionError,
           case .ffmpegFailed(let status, _) = conversionError {
            // ffmpeg stderr can contain megabytes of codec diagnostics and
            // absolute local paths. Keep the manifest/UI diagnostic stable
            // and bounded; detailed process output belongs in runtime logs.
            message = "FFmpeg exited with status \(status)."
        } else {
            message = error.localizedDescription
        }
        let flattened = message
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(flattened.prefix(512))
    }

    private func persistAutomaticConversionFailure(
        for asset: WallpaperAsset,
        message: String
    ) throws -> WallpaperAsset {
        let warning = ScanIssue(
            code: "automatic_conversion_failed",
            message: "Automatic video conversion failed: \(message)"
        )
        return try persistPendingVideoIssue(warning, for: asset)
    }

    private func persistAutomaticConversionCancellation(
        for asset: WallpaperAsset
    ) throws -> WallpaperAsset {
        try persistPendingVideoIssue(
            ScanIssue(
                code: "automatic_conversion_cancelled",
                message: "Automatic video conversion was cancelled. Use Convert to retry."
            ),
            for: asset
        )
    }

    private func persistPendingVideoIssue(
        _ issue: ScanIssue,
        for asset: WallpaperAsset
    ) throws -> WallpaperAsset {
        var expected = asset
        // A manifest JSON round-trip can normalize dates while conversion is
        // suspended. Retry against the current, still-identical import instead
        // of overwriting a genuinely newer replacement.
        for _ in 0..<2 {
            let updated = replacingIssues(
                of: expected,
                with: [issue] + expected.issues.filter {
                    $0.code != "automatic_conversion_failed"
                        && $0.code != "automatic_conversion_cancelled"
                }
            )
            if try store.replaceAsset(updated, ifUnchangedFrom: expected) {
                return updated
            }
            guard let current = try currentAsset(id: asset.id) else {
                throw WallpaperImportError.assetRemovedDuringPreparation(asset.id)
            }
            guard isSamePendingVideo(current, as: asset) else { return current }
            expected = current
        }
        guard let current = try currentAsset(id: asset.id) else {
            throw WallpaperImportError.assetRemovedDuringPreparation(asset.id)
        }
        return current
    }

    private func currentAsset(id: WallpaperAsset.ID) throws -> WallpaperAsset? {
        try store.load().assets.first { $0.id == id }
    }

    private func persistConvertedVideo(_ asset: WallpaperAsset, output: URL) throws -> WallpaperAsset {
        var expected = asset
        for _ in 0..<2 {
            let converted = convertedVideoAsset(expected, output: output)
            if try store.replaceAsset(converted, ifUnchangedFrom: expected) {
                return converted
            }
            guard let current = try currentAsset(id: asset.id) else {
                throw WallpaperImportError.assetRemovedDuringPreparation(asset.id)
            }
            guard isSamePendingVideo(current, as: asset) else { return current }
            expected = current
        }
        guard let current = try currentAsset(id: asset.id) else {
            throw WallpaperImportError.assetRemovedDuringPreparation(asset.id)
        }
        return current
    }

    private func isSamePendingVideo(_ candidate: WallpaperAsset, as asset: WallpaperAsset) -> Bool {
        candidate.kind == .video
            && candidate.supportStatus == .needsConversion
            && candidate.contentHash == asset.contentHash
            && candidate.entrypoint == asset.entrypoint
    }

    private func convertedVideoAsset(_ asset: WallpaperAsset, output: URL) -> WallpaperAsset {
        WallpaperAsset(
            id: asset.id,
            title: asset.title,
            kind: .video,
            supportStatus: .playable,
            source: asset.source,
            projectDirectory: asset.projectDirectory,
            entrypoint: output.path,
            thumbnail: asset.thumbnail,
            workshopId: asset.workshopId,
            dateAdded: asset.dateAdded,
            contentHash: asset.contentHash,
            compatibility: .cached(reason: "Converted for AVFoundation playback."),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .convertedVideo),
            allowsNetworkAccess: asset.allowsNetworkAccess,
            redistributionAllowed: asset.redistributionAllowed,
            issues: asset.issues.filter {
                $0.code != "needs_conversion"
                    && $0.code != "automatic_conversion_failed"
                    && $0.code != "automatic_conversion_cancelled"
                    && $0.code != VideoConverter.outdatedRecipeIssueCode
            }
        )
    }

    private func replacingIssues(of asset: WallpaperAsset, with issues: [ScanIssue]) -> WallpaperAsset {
        WallpaperAsset(
            id: asset.id,
            title: asset.title,
            kind: asset.kind,
            supportStatus: asset.supportStatus,
            source: asset.source,
            projectDirectory: asset.projectDirectory,
            entrypoint: asset.entrypoint,
            thumbnail: asset.thumbnail,
            workshopId: asset.workshopId,
            dateAdded: asset.dateAdded,
            contentHash: asset.contentHash,
            compatibility: asset.compatibility,
            compatibilityReport: asset.compatibilityReport,
            allowsNetworkAccess: asset.allowsNetworkAccess,
            redistributionAllowed: asset.redistributionAllowed,
            issues: issues
        )
    }

    private func validateTree(_ root: URL) throws {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw WallpaperImportError.unsafeRoot(root.path)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
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
            guard values.isRegularFile == true || values.isDirectory == true else {
                throw WallpaperImportError.notRegularFile(url.path)
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
            options: []
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
    case stagedProjectMissing(WallpaperAsset.ID)
    case assetRemovedDuringPreparation(WallpaperAsset.ID)

    public var errorDescription: String? {
        switch self {
        case .unsafeRoot(let path): "The import root is not a safe directory: \(path)"
        case .cannotEnumerate(let path): "The import directory cannot be inspected: \(path)"
        case .notRegularFile(let path): "The selected item is not a regular file: \(path)"
        case .symbolicLink(let path): "Symbolic links are not allowed in imported projects: \(path)"
        case .pathEscape(let path): "A project item escapes the selected directory: \(path)"
        case .tooManyFiles(let actual, let limit): "The project has too many files (\(actual), limit \(limit))."
        case .tooLarge(let actual, let limit): "The project is too large (\(actual) bytes, limit \(limit))."
        case .stagedProjectMissing(let id):
            "Wallpaper \(id) no longer contains a valid project after it was copied."
        case .assetRemovedDuringPreparation(let id):
            "Wallpaper \(id) was removed while its video conversion was finishing."
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
        let report: CompatibilityReport?
        let updatedSupportStatus: SupportStatus
        if kind == .web {
            let projectRoot = URL(filePath: projectDirectory)
            let analyzed = WallpaperCompatibilityAnalyzer().analyze(
                kind: .web,
                status: .playable,
                entrypoint: entrypoint.map { URL(filePath: $0) },
                projectRoot: projectRoot,
                networkAccessAllowed: allowed
            )
            report = analyzed
            updatedSupportStatus = analyzed.level == .unsupported ? .unsupported : .playable
        } else {
            report = compatibilityReport
            updatedSupportStatus = supportStatus
        }
        return WallpaperAsset(
            id: id,
            title: title,
            kind: kind,
            supportStatus: updatedSupportStatus,
            source: source,
            projectDirectory: projectDirectory,
            entrypoint: entrypoint,
            thumbnail: thumbnail,
            workshopId: workshopId,
            dateAdded: dateAdded,
            contentHash: contentHash,
            compatibility: report?.supportMode ?? compatibility,
            compatibilityReport: report,
            allowsNetworkAccess: allowed,
            redistributionAllowed: redistributionAllowed,
            issues: issues
        )
    }
}
