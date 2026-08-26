import BackgroundEngineCore
import Darwin
import Foundation

/// App-layer description of one authored Web resource whose bytes were
/// normalized for WKWebView. Keeping this type independent from the WebKit
/// scheme handler lets preparation finish before a display session exists and
/// avoids coupling the shared conversion queue to one view implementation.
struct WebMediaRuntimePreparedResource: Equatable, Sendable {
    let sourceURL: URL
    let preparedURL: URL
    let mimeType: String

    init(sourceURL: URL, preparedURL: URL, mimeType: String) {
        self.sourceURL = sourceURL
        self.preparedURL = preparedURL
        self.mimeType = mimeType
    }
}

/// One local authored source that could not be normalized before page load.
/// Keeping failures beside successful resources lets callers preserve valid
/// HTML `<source>` fallbacks without silently losing diagnostics.
struct WebMediaRuntimePreparationFailure: Equatable, Sendable {
    let sourceURL: URL
    let diagnosticCode: String
    let reason: String

    var warning: String {
        "Could not prepare \(sourceURL.lastPathComponent): \(reason)"
    }
}

/// Keeps a completed cache handoff alive until the consumer has pinned every
/// returned file. Cache maintenance waits for these leases, closing the small
/// but real gap between a converter publishing a pathname and the per-view
/// loopback server opening its descriptor.
final class WebMediaRuntimePreparationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var isReleased = false
    private let releaseOperation: @Sendable () -> Void

    init(releaseOperation: @escaping @Sendable () -> Void) {
        self.releaseOperation = releaseOperation
    }

    deinit { release() }

    func release() {
        let shouldRelease = lock.withLock {
            guard !isReleased else { return false }
            isReleased = true
            return true
        }
        if shouldRelease { releaseOperation() }
    }
}

/// Preparation is intentionally a collection so existing callers can install
/// successful resources with `map` while newer callers can also surface the
/// warnings. A single optional source failure must not hide usable fallbacks.
struct WebMediaRuntimePreparationResult: RandomAccessCollection, Equatable, Sendable {
    typealias Element = WebMediaRuntimePreparedResource
    typealias Index = Int

    let preparedResources: [WebMediaRuntimePreparedResource]
    let failures: [WebMediaRuntimePreparationFailure]
    let localResourceMIMEOverrides: [WebLocalResourceMIMEOverride]
    private let cacheHandoffLeases: [WebMediaRuntimePreparationLease]

    init(
        preparedResources: [WebMediaRuntimePreparedResource],
        failures: [WebMediaRuntimePreparationFailure],
        localResourceMIMEOverrides: [WebLocalResourceMIMEOverride] = [],
        cacheHandoffLeases: [WebMediaRuntimePreparationLease] = []
    ) {
        self.preparedResources = preparedResources
        self.failures = failures
        self.localResourceMIMEOverrides = localResourceMIMEOverrides
        self.cacheHandoffLeases = cacheHandoffLeases
    }

    var warnings: [String] { failures.map(\.warning) }
    var startIndex: Int { preparedResources.startIndex }
    var endIndex: Int { preparedResources.endIndex }

    subscript(position: Int) -> WebMediaRuntimePreparedResource {
        preparedResources[position]
    }

    /// Releases the cache-maintenance barrier after a renderer has opened and
    /// pinned the returned paths. This method is idempotent; deinit is a final
    /// safety net for cancelled/error paths.
    func releaseCacheHandoff() {
        for lease in cacheHandoffLeases { lease.release() }
    }

    static func == (
        lhs: WebMediaRuntimePreparationResult,
        rhs: WebMediaRuntimePreparationResult
    ) -> Bool {
        lhs.preparedResources == rhs.preparedResources
            && lhs.failures == rhs.failures
            && lhs.localResourceMIMEOverrides == rhs.localResourceMIMEOverrides
    }
}

enum WebMediaRuntimeCoordinatorError: Error, Equatable, LocalizedError, Sendable {
    case unsafeProjectRoot
    case dynamicMediaDiscoveryLimitExceeded(maximumEntries: Int, maximumCandidates: Int)

    var errorDescription: String? {
        switch self {
        case .unsafeProjectRoot:
            return "The Web wallpaper project root failed secure local-media validation."
        case .dynamicMediaDiscoveryLimitExceeded(let maximumEntries, let maximumCandidates):
            return "Dynamic Web media discovery exceeded its safe limit "
                + "(\(maximumEntries) files or \(maximumCandidates) media candidates)."
        }
    }
}

/// Bounded fallback for JavaScript media expressions whose concrete URL is
/// not knowable statically (for example `video.src = folder + selectedName`).
/// Only regular files under the canonical project root can become candidates.
/// Known code/image/document extensions are never probed as media; an
/// extensionless or asset-named file needs a positive container signature.
struct WebDynamicMediaCandidateDiscovery: Sendable {
    static let maximumExaminedEntries = 10_000
    static let maximumCandidates = 64
    private static let signatureProbeBytes = 512

    private static let mediaExtensions: Set<String> = [
        "3g2", "3gp", "aac", "ac3", "aif", "aifc", "aiff", "amr", "ape",
        "asf", "au", "avi", "caf", "dts", "dv", "eac3", "flac", "flv",
        "h264", "hevc", "ivf", "m2ts", "m4a", "m4v", "mka", "mkv", "mov",
        "mp2", "mp3", "mp4", "mpeg", "mpg", "mxf", "nut", "oga", "ogg",
        "ogv", "opus", "rm", "ts", "vc1", "w64", "wav", "webm", "wma",
        "wmv"
    ]
    private static let knownNonMediaExtensions: Set<String> = [
        "apng", "avif", "bmp", "cjs", "css", "gif", "heic", "heif", "htm",
        "html", "ico", "jpeg", "jpg", "js", "json", "mjs", "otf", "pdf",
        "png", "srt", "svg", "tif", "tiff", "ttf", "txt", "vtt", "wasm",
        "webp", "woff", "woff2", "xml"
    ]

    func discover(
        projectRoot: URL,
        excludingCanonicalPaths: Set<String>,
        maximumCandidateCount: Int = Self.maximumCandidates,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let lexicalRoot = projectRoot.standardizedFileURL
        let canonicalRoot = lexicalRoot.resolvingSymlinksInPath()
        guard projectRoot.isFileURL,
              lexicalRoot == canonicalRoot,
              let rootValues = try? lexicalRoot.resourceValues(
                  forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true,
              maximumCandidateCount >= 0 else {
            throw WebMediaRuntimeCoordinatorError.unsafeProjectRoot
        }
        guard let enumerator = fileManager.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw WebMediaRuntimeCoordinatorError.unsafeProjectRoot
        }

        var examinedEntries = 0
        var candidates = [URL]()
        for case let candidate as URL in enumerator {
            if Task.isCancelled { throw CancellationError() }
            examinedEntries += 1
            guard examinedEntries <= Self.maximumExaminedEntries else {
                throw WebMediaRuntimeCoordinatorError.dynamicMediaDiscoveryLimitExceeded(
                    maximumEntries: Self.maximumExaminedEntries,
                    maximumCandidates: maximumCandidateCount
                )
            }
            guard let values = try? candidate.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ]
            ) else { continue }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0,
                  UInt64(size) <= WebMediaPreparer.maximumSourceBytes else {
                continue
            }

            let lexical = candidate.standardizedFileURL
            let canonical = lexical.resolvingSymlinksInPath()
            guard lexical == canonical,
                  Self.isInside(canonical, root: canonicalRoot),
                  !excludingCanonicalPaths.contains(canonical.path),
                  Self.isMediaCandidate(canonical) else {
                continue
            }
            guard candidates.count < maximumCandidateCount else {
                throw WebMediaRuntimeCoordinatorError.dynamicMediaDiscoveryLimitExceeded(
                    maximumEntries: Self.maximumExaminedEntries,
                    maximumCandidates: maximumCandidateCount
                )
            }
            candidates.append(canonical)
        }
        return candidates.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count > rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func isMediaCandidate(_ candidate: URL) -> Bool {
        let pathExtension = candidate.pathExtension.lowercased()
        if mediaExtensions.contains(pathExtension) { return true }
        if knownNonMediaExtensions.contains(pathExtension) { return false }
        return hasMediaContainerSignature(candidate)
    }

    private static func hasMediaContainerSignature(_ candidate: URL) -> Bool {
        var expected = stat()
        let inspected = candidate.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &expected)
        }
        guard inspected == 0,
              expected.st_mode & S_IFMT == S_IFREG,
              expected.st_size > 0 else { return false }
        let descriptor = candidate.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var actual = stat()
        guard Darwin.fstat(descriptor, &actual) == 0,
              actual.st_mode & S_IFMT == S_IFREG,
              actual.st_dev == expected.st_dev,
              actual.st_ino == expected.st_ino,
              actual.st_size == expected.st_size else { return false }
        var bytes = [UInt8](repeating: 0, count: signatureProbeBytes)
        let count = Darwin.pread(descriptor, &bytes, bytes.count, 0)
        guard count > 0 else { return false }
        bytes.removeSubrange(Int(count)..<bytes.count)

        func matches(_ offset: Int, _ signature: String) -> Bool {
            let expected = Array(signature.utf8)
            guard offset >= 0,
                  offset <= bytes.count,
                  expected.count <= bytes.count - offset else { return false }
            return bytes[offset..<(offset + expected.count)].elementsEqual(expected)
        }
        func matches(_ offset: Int, _ signature: [UInt8]) -> Bool {
            guard offset >= 0,
                  offset <= bytes.count,
                  signature.count <= bytes.count - offset else { return false }
            return bytes[offset..<(offset + signature.count)].elementsEqual(signature)
        }

        return matches(0, "OggS")
            || matches(0, "fLaC")
            || matches(0, "ID3")
            || matches(0, ".snd")
            || matches(0, "MThd")
            || matches(0, [0x1A, 0x45, 0xDF, 0xA3])
            || matches(0, [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
                           0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C])
            || (matches(0, "RIFF") && (matches(8, "AVI ") || matches(8, "WAVE")))
            || (matches(0, "FORM") && (matches(8, "AIFF") || matches(8, "AIFC")))
            || matches(4, "ftyp")
            || (bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0)
            || (bytes.count > 188 && bytes[0] == 0x47 && bytes[188] == 0x47)
    }
}

/// Finds statically-authored local media that WebKit cannot play directly and
/// prepares only those files through the bounded Core converter. Concurrent
/// displays requesting the same source share one task; cancelling a display's
/// waiter keeps the shared conversion alive for remaining displays, while the
/// final waiter cancels an otherwise orphaned FFmpeg job.
actor WebMediaRuntimeCoordinator {
    typealias PreparationOperation = @Sendable (
        URL,
        URL,
        Duration
    ) async throws -> PreparedWebMedia
    typealias StartupPruneOperation = @Sendable (URL) -> Void
    typealias CacheMaintenanceOperation = @Sendable (URL) async throws -> Void
    typealias JobCompletionObserver = @Sendable (UUID) async -> Void
    typealias PreparedMediaHandoffObserver = @Sendable (URL) async -> Void
    typealias ResultLeaseWaitObserver = @Sendable () async -> Void
    typealias WaiterWillRegisterObserver = @Sendable (PlaybackLifecycleScope) async -> Void
    typealias WaiterRegistrationObserver = @Sendable (PlaybackLifecycleScope) -> Void

    static let shared = WebMediaRuntimeCoordinator()
    static let defaultPreparationTimeout = WebMediaPreparer.defaultTimeout
    /// One page must not inherit the aggregate two-hour budget of every
    /// authored source. Individual jobs remain shareable across displays, but
    /// a page stops waiting after this bounded project-level deadline.
    static let defaultProjectPreparationTimeout: Duration = .seconds(15 * 60)
    static let defaultPlaybackProbeTimeout: Duration = .seconds(15)
    static let maximumConcurrentPreparations = 2
    static let maximumProjectMediaCandidates = WebDynamicMediaCandidateDiscovery.maximumCandidates
    private static let processPreparationLimiter = WebMediaRuntimePreparationLimiter(
        maximumConcurrentPreparations: maximumConcurrentPreparations
    )

    private struct JobKey: Hashable, Sendable {
        let canonicalSourcePath: String
    }

    private struct Job {
        let generation: UUID
        let task: Task<PreparedWebMedia, any Error>
        var waiters: [UUID: JobWaiter]
    }

    /// Kept as a separate value so lifecycle cancellation can attach metadata
    /// to a waiter without changing the shared conversion task itself.
    private struct JobWaiter {
        let lifecycleScope: PlaybackLifecycleScope
        let continuation: CheckedContinuation<PreparedJobResult, any Error>
    }

    private struct TrackedPreparationTask {
        let task: Task<PreparedWebMedia, any Error>
        var lifecycleScopesByWaiterID: [UUID: PlaybackLifecycleScope]
    }

    private struct ActivePlaybackProbeTask {
        let lifecycleScope: PlaybackLifecycleScope
        let task: Task<Bool, Never>
        let timeoutTask: Task<Void, Never>
        let continuation: CheckedContinuation<Bool, any Error>
    }

    private struct OrphanedPlaybackProbeTask {
        let lifecycleScope: PlaybackLifecycleScope
        let task: Task<Bool, Never>
    }

    /// A converter result and the cache-maintenance barrier created for the
    /// exact display waiter receiving it. Concurrent displays therefore keep
    /// independent protection while pinning the same shared output.
    private struct PreparedJobResult: Sendable {
        let media: PreparedWebMedia
        let cacheHandoffLease: WebMediaRuntimePreparationLease
    }

    private enum WaiterState {
        case awaitingRegistration(JobKey)
        case registered(JobKey, generation: UUID)
    }

    private enum MaintenanceWaiterState {
        case awaitingRegistration
        case registered(CheckedContinuation<Void, any Error>)
    }

    private enum ResultLeaseWaiterState {
        case awaitingRegistration
        case registered(CheckedContinuation<Void, any Error>)
    }

    private enum JobResult: Sendable {
        case success(PreparedWebMedia)
        case failure(any Error)
    }

    private enum SourcePreparationOutcome: Sendable {
        case success(
            WebMediaRuntimePreparedResource,
            cacheHandoffLease: WebMediaRuntimePreparationLease
        )
        case failure(WebMediaRuntimePreparationFailure)
    }

    private enum ProjectDeadlineError: Error, LocalizedError, Sendable {
        case timedOut

        var errorDescription: String? {
            "Web media preparation exceeded the project-level time limit."
        }
    }

    private let analyzer: WebRuntimeFeatureAnalyzer
    private let playbackProbe: WebMediaPlaybackProbe
    private let cacheDirectory: URL
    private let preparationTimeout: Duration
    private let projectPreparationTimeout: Duration
    private let preparationOperation: PreparationOperation
    private let startupPruneOperation: StartupPruneOperation
    private let preparationLimiter: WebMediaRuntimePreparationLimiter
    private let jobCompletionObserver: JobCompletionObserver?
    private let preparedMediaHandoffObserver: PreparedMediaHandoffObserver?
    private let resultLeaseWaitObserver: ResultLeaseWaitObserver?
    private let waiterWillRegisterObserver: WaiterWillRegisterObserver?
    private let waiterRegistrationObserver: WaiterRegistrationObserver?
    private nonisolated let lifecycleScopeCounter = PlaybackLifecycleScopeCounter()
    private nonisolated let shutdownGate = RuntimeShutdownGate()

    private var jobs: [JobKey: Job] = [:]
    /// Includes active jobs plus orphaned/cancelled generations whose detached
    /// converter is still unwinding. Cache maintenance must drain both sets.
    private var tasksByGeneration: [UUID: TrackedPreparationTask] = [:]
    private var activePlaybackProbeTasks = [UUID: ActivePlaybackProbeTask]()
    private var orphanedPlaybackProbeTasks = [UUID: OrphanedPlaybackProbeTask]()
    private var waiterStates: [UUID: WaiterState] = [:]
    private var latestCancelledLifecycleScope = PlaybackLifecycleScope(rawValue: 0)
    private var maintenanceInProgress = false
    private var maintenanceWaiterStates: [UUID: MaintenanceWaiterState] = [:]
    /// Cache maintenance runs in the caller's task rather than a coordinator-
    /// owned child task. Track accepted requests explicitly so app shutdown
    /// can wait for both the active operation and callers queued behind it.
    private var activeMaintenanceRequestIDs = Set<UUID>()
    private var maintenanceDrainWaiters = [CheckedContinuation<Void, Never>]()
    private var activeResultLeaseIDs = Set<UUID>()
    private var resultLeaseWaiterStates: [UUID: ResultLeaseWaiterState] = [:]
    private var startupPruneTask: Task<Void, Never>?
    private var hasCompletedStartupPrune = false

    init(
        analyzer: WebRuntimeFeatureAnalyzer = WebRuntimeFeatureAnalyzer(),
        playbackProbe: WebMediaPlaybackProbe = WebMediaPlaybackProbe(),
        cacheDirectory: URL = WebMediaRuntimeCoordinator.defaultCacheDirectory(),
        preparationTimeout: Duration = WebMediaRuntimeCoordinator.defaultPreparationTimeout,
        projectPreparationTimeout: Duration = WebMediaRuntimeCoordinator.defaultProjectPreparationTimeout,
        preparer: WebMediaPreparer = WebMediaPreparer()
    ) {
        self.analyzer = analyzer
        self.playbackProbe = playbackProbe
        self.cacheDirectory = cacheDirectory.standardizedFileURL
        self.preparationTimeout = preparationTimeout
        self.projectPreparationTimeout = projectPreparationTimeout
        startupPruneOperation = { cacheDirectory in
            _ = try? WebMediaPreparer.pruneOrphanedTemporaryFiles(in: cacheDirectory)
        }
        preparationLimiter = Self.processPreparationLimiter
        jobCompletionObserver = nil
        preparedMediaHandoffObserver = nil
        resultLeaseWaitObserver = nil
        waiterWillRegisterObserver = nil
        waiterRegistrationObserver = nil
        preparationOperation = { source, cacheDirectory, timeout in
            try await preparer.prepare(
                source: source,
                cacheDirectory: cacheDirectory,
                timeout: timeout
            )
        }
    }

    /// Test seam for a deterministic converter without weakening the
    /// production initializer's use of the bundled MediaToolResolver.
    init(
        analyzer: WebRuntimeFeatureAnalyzer = WebRuntimeFeatureAnalyzer(),
        playbackProbe: WebMediaPlaybackProbe,
        cacheDirectory: URL,
        preparationTimeout: Duration = WebMediaRuntimeCoordinator.defaultPreparationTimeout,
        projectPreparationTimeout: Duration = WebMediaRuntimeCoordinator.defaultProjectPreparationTimeout,
        maximumConcurrentPreparations: Int = WebMediaRuntimeCoordinator.maximumConcurrentPreparations,
        jobCompletionObserver: JobCompletionObserver? = nil,
        preparedMediaHandoffObserver: PreparedMediaHandoffObserver? = nil,
        resultLeaseWaitObserver: ResultLeaseWaitObserver? = nil,
        waiterWillRegisterObserver: WaiterWillRegisterObserver? = nil,
        waiterRegistrationObserver: WaiterRegistrationObserver? = nil,
        startupPruneOperation: @escaping StartupPruneOperation = { cacheDirectory in
            _ = try? WebMediaPreparer.pruneOrphanedTemporaryFiles(in: cacheDirectory)
        },
        preparationOperation: @escaping PreparationOperation
    ) {
        self.analyzer = analyzer
        self.playbackProbe = playbackProbe
        self.cacheDirectory = cacheDirectory.standardizedFileURL
        self.preparationTimeout = preparationTimeout
        self.projectPreparationTimeout = projectPreparationTimeout
        preparationLimiter = WebMediaRuntimePreparationLimiter(
            maximumConcurrentPreparations: maximumConcurrentPreparations
        )
        self.jobCompletionObserver = jobCompletionObserver
        self.preparedMediaHandoffObserver = preparedMediaHandoffObserver
        self.resultLeaseWaitObserver = resultLeaseWaitObserver
        self.waiterWillRegisterObserver = waiterWillRegisterObserver
        self.waiterRegistrationObserver = waiterRegistrationObserver
        self.startupPruneOperation = startupPruneOperation
        self.preparationOperation = preparationOperation
    }

    static func defaultCacheDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appending(path: "Background Engine", directoryHint: .isDirectory)
            .appending(path: "WebMediaCache", directoryHint: .isDirectory)
    }

    /// Allocates a scope synchronously so callers can bind preparation work to
    /// the display session that created it before entering an unstructured
    /// task. A later stop/sleep checkpoint can then cancel only older work.
    nonisolated func makePlaybackScope() -> PlaybackLifecycleScope {
        lifecycleScopeCounter.makeScope()
    }

    /// Captures every playback scope created up to this exact lifecycle event.
    /// Scopes allocated after this call are intentionally outside its sweep.
    nonisolated func cancellationCheckpoint() -> PlaybackLifecycleScope {
        lifecycleScopeCounter.checkpoint()
    }

    /// Synchronously prevents new preparation or maintenance requests from
    /// being admitted while the application termination task is being set up.
    nonisolated func beginShutdown() {
        shutdownGate.close()
    }

    func prepareResources(
        entrypoint: URL,
        projectRoot: URL,
        lifecycleScope providedLifecycleScope: PlaybackLifecycleScope? = nil
    ) async throws -> WebMediaRuntimePreparationResult {
        let lifecycleScope = providedLifecycleScope ?? makePlaybackScope()
        try ensureLifecycleScopeIsActive(lifecycleScope)
        try Task.checkCancellation()
        await performStartupPruneIfNeeded()
        try ensureLifecycleScopeIsActive(lifecycleScope)
        try Task.checkCancellation()
        let projectDeadline = ContinuousClock.now.advanced(
            by: projectPreparationTimeout
        )
        let features = analyzer.analyze(
            entrypoint: entrypoint,
            projectRoot: projectRoot
        )
        try Task.checkCancellation()
        let localResourceMIMEOverrides = features.localResourceMIMEOverrides

        // The same authored file may appear in multiple <source>, <video>, or
        // <audio> elements. If any use cannot play directly, one normalized
        // resource replaces that exact source path for every use.
        let playbackProbeDeadline = min(
            projectDeadline,
            ContinuousClock.now.advanced(by: Self.defaultPlaybackProbeTimeout)
        )
        var sourceByCanonicalPath = [String: URL]()
        let staticallyReferencedCanonicalPaths = Set(
            features.localMediaReferences.map {
                $0.sourceURL.standardizedFileURL.resolvingSymlinksInPath().path
            }
        )
        for reference in features.localMediaReferences {
            try ensureLifecycleScopeIsActive(lifecycleScope)
            try Task.checkCancellation()
            let isDirectlyPlayable: Bool
            do {
                isDirectlyPlayable = try await probeDirectPlayback(
                    reference,
                    lifecycleScope: lifecycleScope,
                    deadline: playbackProbeDeadline
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The bounded runtime probe is advisory. Unknown or stalled
                // local media follows the validated FFmpeg preparation path.
                isDirectlyPlayable = false
            }
            try ensureLifecycleScopeIsActive(lifecycleScope)
            try Task.checkCancellation()
            if isDirectlyPlayable {
                continue
            }
            let source = reference.sourceURL.standardizedFileURL
            let key = source.resolvingSymlinksInPath().path
            sourceByCanonicalPath[key] = source
        }

        if features.hasOpaqueOrDynamicMediaReferences {
            try ensureLifecycleScopeIsActive(lifecycleScope)
            try Task.checkCancellation()
            let remainingCandidateCapacity = max(
                0,
                Self.maximumProjectMediaCandidates - sourceByCanonicalPath.count
            )
            let candidates = try WebDynamicMediaCandidateDiscovery().discover(
                projectRoot: projectRoot,
                excludingCanonicalPaths: staticallyReferencedCanonicalPaths,
                maximumCandidateCount: remainingCandidateCapacity
            )
            for candidate in candidates {
                sourceByCanonicalPath[candidate.path] = candidate
            }
        }

        let sources = sourceByCanonicalPath.values.sorted(by: {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        })
        guard !sources.isEmpty else {
            return WebMediaRuntimePreparationResult(
                preparedResources: [],
                failures: [],
                localResourceMIMEOverrides: localResourceMIMEOverrides
            )
        }

        let preparedMediaHandoffObserver = preparedMediaHandoffObserver
        let outcomes = try await withThrowingTaskGroup(
            of: SourcePreparationOutcome.self,
            returning: [SourcePreparationOutcome].self
        ) { group in
            for source in sources {
                group.addTask { [self] in
                    try Task.checkCancellation()
                    do {
                        let prepared = try await Self.run(
                            before: projectDeadline
                        ) {
                            try await self.preparedMedia(
                                for: source,
                                lifecycleScope: lifecycleScope
                            )
                        }
                        if let preparedMediaHandoffObserver {
                            await preparedMediaHandoffObserver(source)
                        }
                        try await self.ensureLifecycleScopeIsActive(lifecycleScope)
                        try Task.checkCancellation()
                        return .success(
                            WebMediaRuntimePreparedResource(
                                sourceURL: source,
                                preparedURL: prepared.media.url,
                                mimeType: Self.mimeType(for: prepared.media.kind)
                            ),
                            cacheHandoffLease: prepared.cacheHandoffLease
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let diagnosticCode = error is ProjectDeadlineError
                            ? "web_media_project_deadline"
                            : "web_media_preparation_failed"
                        return .failure(
                            WebMediaRuntimePreparationFailure(
                                sourceURL: source,
                                diagnosticCode: diagnosticCode,
                                reason: error.localizedDescription
                            )
                        )
                    }
                }
            }
            var outcomes = [SourcePreparationOutcome]()
            outcomes.reserveCapacity(sources.count)
            for try await outcome in group { outcomes.append(outcome) }
            return outcomes
        }
        try ensureLifecycleScopeIsActive(lifecycleScope)

        var resources = [WebMediaRuntimePreparedResource]()
        var failures = [WebMediaRuntimePreparationFailure]()
        var cacheHandoffLeases = [WebMediaRuntimePreparationLease]()
        for outcome in outcomes {
            switch outcome {
            case .success(let resource, let cacheHandoffLease):
                resources.append(resource)
                cacheHandoffLeases.append(cacheHandoffLease)
            case .failure(let failure): failures.append(failure)
            }
        }
        resources.sort {
            $0.sourceURL.path.localizedStandardCompare($1.sourceURL.path) == .orderedAscending
        }
        failures.sort {
            $0.sourceURL.path.localizedStandardCompare($1.sourceURL.path) == .orderedAscending
        }

        // A failed local candidate cannot prove the authored page is unusable:
        // an opaque JavaScript expression may actually target an image, the
        // candidate may be optional, or HTML may fall back to remote media
        // when the wallpaper has network permission. Return bounded warnings
        // and let the page select its authored fallback. Security/infrastructure
        // failures (unsafe roots, discovery limits, cancellation) still throw.
        return WebMediaRuntimePreparationResult(
            preparedResources: resources,
            failures: failures,
            localResourceMIMEOverrides: localResourceMIMEOverrides,
            cacheHandoffLeases: cacheHandoffLeases
        )
    }

    /// Stops every preparation. Continuations are resumed first so display
    /// sessions never remain hung; awaiting each task then guarantees
    /// supervised FFmpeg children have exited before this method returns.
    func cancelAll() async {
        await cancelAll(upTo: cancellationCheckpoint())
    }

    /// Cancels only display waiters that existed when the caller captured its
    /// checkpoint. Shared conversions remain alive when a newer display scope
    /// also needs them, and scopes that register late are rejected using the
    /// retained cancellation watermark.
    func cancelAll(upTo checkpoint: PlaybackLifecycleScope) async {
        if checkpoint > latestCancelledLifecycleScope {
            latestCancelledLifecycleScope = checkpoint
        }
        cancelPlaybackProbeTasks(upTo: checkpoint)
        let activeTasks = cancelAndDetachJobs(upTo: checkpoint)
        for task in activeTasks {
            _ = try? await task.value
        }
    }

    /// Final process-lifetime drain. It includes orphaned converter and probe
    /// tasks, the one-time startup prune, and cache maintenance performed in
    /// external caller tasks. No new work can pass the synchronous gate after
    /// this method begins.
    func shutdownAndWait() async {
        beginShutdown()
        latestCancelledLifecycleScope = max(
            latestCancelledLifecycleScope,
            cancellationCheckpoint()
        )

        let preparationTasks = cancelAndDetachAllJobs()
        let playbackProbeTasks = cancelAndDetachAllPlaybackProbeTasks()
        let startupTask = startupPruneTask

        for task in preparationTasks {
            _ = try? await task.value
        }
        for task in playbackProbeTasks {
            _ = await task.value
        }
        await startupTask?.value
        await waitForMaintenanceRequestsToDrain()
        // An accepted maintenance request may have joined or created the
        // startup prune after the first snapshot but before its own drain.
        await startupPruneTask?.value
    }

    /// Clears the derived Web media cache as one actor-owned maintenance
    /// transaction. New preparation waiters are held until every old converter
    /// has exited and deletion is complete, preventing a retry from publishing
    /// into a directory that is about to be removed.
    func clearCache() async throws {
        try await performCacheMaintenance { cacheDirectory in
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: cacheDirectory.path) else { return }
            try fileManager.removeItem(at: cacheDirectory)
        }
    }

    /// Test/maintenance seam that preserves the same exclusive transaction
    /// while allowing callers to perform additional cache housekeeping.
    func performCacheMaintenance(
        _ operation: @escaping CacheMaintenanceOperation
    ) async throws {
        guard shutdownGate.acceptsWork else {
            throw CancellationError()
        }
        let maintenanceRequestID = UUID()
        activeMaintenanceRequestIDs.insert(maintenanceRequestID)
        defer { finishMaintenanceRequest(maintenanceRequestID) }

        await performStartupPruneIfNeeded()
        try Task.checkCancellation()
        try await beginCacheMaintenance()
        let activeTasks = cancelAndDetachAllJobs()
        do {
            for task in activeTasks {
                _ = try? await task.value
            }
            try await waitForResultLeasesToDrain()
            try Task.checkCancellation()
            try await operation(cacheDirectory)
        } catch {
            endCacheMaintenance()
            throw error
        }
        endCacheMaintenance()
    }

    /// Runs crash-recovery cleanup once per coordinator without doing any
    /// filesystem work in actor initialization. The detached task is shared
    /// across reentrant callers, including cache maintenance, so pruning can
    /// neither block app startup nor race a cache clear.
    private func performStartupPruneIfNeeded() async {
        guard !hasCompletedStartupPrune else { return }
        let task: Task<Void, Never>
        if let startupPruneTask {
            task = startupPruneTask
        } else {
            let cacheDirectory = cacheDirectory
            let operation = startupPruneOperation
            let created = Task.detached(priority: .utility) {
                operation(cacheDirectory)
            }
            startupPruneTask = created
            task = created
        }
        await task.value
        hasCompletedStartupPrune = true
        startupPruneTask = nil
    }

    private func makeResultLease() -> WebMediaRuntimePreparationLease {
        let identifier = UUID()
        activeResultLeaseIDs.insert(identifier)
        return WebMediaRuntimePreparationLease { [weak self] in
            Task { await self?.releaseResultLease(identifier) }
        }
    }

    private func releaseResultLease(_ identifier: UUID) {
        guard activeResultLeaseIDs.remove(identifier) != nil,
              activeResultLeaseIDs.isEmpty else { return }
        let waiting = resultLeaseWaiterStates
        resultLeaseWaiterStates.removeAll()
        for state in waiting.values {
            guard case .registered(let continuation) = state else { continue }
            continuation.resume()
        }
    }

    private func waitForResultLeasesToDrain() async throws {
        guard !activeResultLeaseIDs.isEmpty else { return }
        if let resultLeaseWaitObserver {
            await resultLeaseWaitObserver()
        }
        guard !activeResultLeaseIDs.isEmpty else { return }
        try Task.checkCancellation()
        let waiterID = UUID()
        resultLeaseWaiterStates[waiterID] = .awaitingRegistration
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                registerResultLeaseWaiter(continuation, waiterID: waiterID)
            }
        }, onCancel: {
            Task { await self.cancelResultLeaseWaiter(waiterID) }
        })
        try Task.checkCancellation()
    }

    private func registerResultLeaseWaiter(
        _ continuation: CheckedContinuation<Void, any Error>,
        waiterID: UUID
    ) {
        guard case .awaitingRegistration = resultLeaseWaiterStates[waiterID] else {
            continuation.resume(throwing: CancellationError())
            return
        }
        guard !activeResultLeaseIDs.isEmpty else {
            resultLeaseWaiterStates[waiterID] = nil
            continuation.resume()
            return
        }
        resultLeaseWaiterStates[waiterID] = .registered(continuation)
    }

    private func cancelResultLeaseWaiter(_ waiterID: UUID) {
        guard let state = resultLeaseWaiterStates.removeValue(forKey: waiterID) else {
            return
        }
        guard case .registered(let continuation) = state else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func preparedMedia(
        for source: URL,
        lifecycleScope: PlaybackLifecycleScope
    ) async throws -> PreparedJobResult {
        try await waitForCacheMaintenanceIfNeeded()
        try ensureLifecycleScopeIsActive(lifecycleScope)
        try Task.checkCancellation()
        let key = JobKey(
            canonicalSourcePath: source.standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        )
        if let waiterWillRegisterObserver {
            await waiterWillRegisterObserver(lifecycleScope)
        }
        try Task.checkCancellation()
        let waiterID = UUID()
        waiterStates[waiterID] = .awaitingRegistration(key)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                registerOrStart(
                    continuation: continuation,
                    waiterID: waiterID,
                    for: key,
                    source: source,
                    lifecycleScope: lifecycleScope
                )
            }
        }, onCancel: {
            Task { await self.cancelWaiter(waiterID, for: key) }
        })
    }

    private func startJob(
        for key: JobKey,
        source: URL,
        initialWaiterID: UUID,
        lifecycleScope: PlaybackLifecycleScope,
        continuation: CheckedContinuation<PreparedJobResult, any Error>
    ) {
        let generation = UUID()
        let operation = preparationOperation
        let cacheDirectory = cacheDirectory
        let timeout = preparationTimeout
        let limiter = preparationLimiter
        let task = Task.detached(priority: .utility) {
            try await limiter.perform {
                try await operation(source, cacheDirectory, timeout)
            }
        }
        jobs[key] = Job(
            generation: generation,
            task: task,
            waiters: [
                initialWaiterID: JobWaiter(
                    lifecycleScope: lifecycleScope,
                    continuation: continuation
                )
            ]
        )
        tasksByGeneration[generation] = TrackedPreparationTask(
            task: task,
            lifecycleScopesByWaiterID: [initialWaiterID: lifecycleScope]
        )
        waiterStates[initialWaiterID] = .registered(key, generation: generation)
        waiterRegistrationObserver?(lifecycleScope)

        Task.detached { [weak self] in
            let result: JobResult
            do {
                result = .success(try await task.value)
            } catch {
                result = .failure(error)
            }
            await self?.finishJob(for: key, generation: generation, result: result)
        }
    }

    private func registerOrStart(
        continuation: CheckedContinuation<PreparedJobResult, any Error>,
        waiterID: UUID,
        for key: JobKey,
        source: URL,
        lifecycleScope: PlaybackLifecycleScope
    ) {
        guard case .awaitingRegistration(let expectedKey) = waiterStates[waiterID],
              expectedKey == key else {
            continuation.resume(throwing: CancellationError())
            return
        }
        guard shutdownGate.acceptsWork,
              lifecycleScope > latestCancelledLifecycleScope else {
            waiterStates[waiterID] = nil
            continuation.resume(throwing: CancellationError())
            return
        }
        guard var job = jobs[key] else {
            startJob(
                for: key,
                source: source,
                initialWaiterID: waiterID,
                lifecycleScope: lifecycleScope,
                continuation: continuation
            )
            return
        }
        job.waiters[waiterID] = JobWaiter(
            lifecycleScope: lifecycleScope,
            continuation: continuation
        )
        jobs[key] = job
        if var trackedTask = tasksByGeneration[job.generation] {
            trackedTask.lifecycleScopesByWaiterID[waiterID] = lifecycleScope
            tasksByGeneration[job.generation] = trackedTask
        }
        waiterStates[waiterID] = .registered(key, generation: job.generation)
        waiterRegistrationObserver?(lifecycleScope)
    }

    private func cancelWaiter(_ waiterID: UUID, for key: JobKey) {
        guard let state = waiterStates.removeValue(forKey: waiterID) else { return }
        guard case .registered(let registeredKey, let generation) = state,
              registeredKey == key,
              var job = jobs[registeredKey],
              job.generation == generation,
              let waiter = job.waiters.removeValue(forKey: waiterID) else {
            return
        }
        if var trackedTask = tasksByGeneration[generation] {
            trackedTask.lifecycleScopesByWaiterID[waiterID] = nil
            tasksByGeneration[generation] = trackedTask
        }
        if job.waiters.isEmpty {
            jobs[registeredKey] = nil
            job.task.cancel()
        } else {
            jobs[registeredKey] = job
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func finishJob(
        for key: JobKey,
        generation: UUID,
        result: JobResult
    ) async {
        if let job = jobs[key], job.generation == generation {
            // Create every successful waiter's lease while the generation is
            // still protected by tasksByGeneration. Only after all leases are
            // registered may maintenance observe the job as complete.
            var successfulHandoffs = [(JobWaiter, PreparedJobResult)]()
            switch result {
            case .success(let prepared):
                successfulHandoffs.reserveCapacity(job.waiters.count)
                for waiter in job.waiters.values {
                    successfulHandoffs.append((
                        waiter,
                        PreparedJobResult(
                            media: prepared,
                            cacheHandoffLease: makeResultLease()
                        )
                    ))
                }
            case .failure:
                break
            }
            jobs[key] = nil
            for waiterID in job.waiters.keys {
                waiterStates[waiterID] = nil
            }
            tasksByGeneration[generation] = nil
            switch result {
            case .success:
                for (waiter, handoff) in successfulHandoffs {
                    waiter.continuation.resume(returning: handoff)
                }
            case .failure(let error):
                for waiter in job.waiters.values {
                    waiter.continuation.resume(throwing: error)
                }
            }
        } else {
            tasksByGeneration[generation] = nil
        }
        if let jobCompletionObserver {
            await jobCompletionObserver(generation)
        }
    }

    private func ensureLifecycleScopeIsActive(
        _ lifecycleScope: PlaybackLifecycleScope
    ) throws {
        guard shutdownGate.acceptsWork,
              lifecycleScope > latestCancelledLifecycleScope else {
            throw CancellationError()
        }
    }

    private func probeDirectPlayback(
        _ reference: WebLocalMediaReference,
        lifecycleScope: PlaybackLifecycleScope,
        deadline: ContinuousClock.Instant
    ) async throws -> Bool {
        try ensureLifecycleScopeIsActive(lifecycleScope)
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return false }

        let identifier = UUID()
        let result = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                startPlaybackProbe(
                    identifier: identifier,
                    reference: reference,
                    lifecycleScope: lifecycleScope,
                    timeout: remaining,
                    continuation: continuation
                )
            }
        }, onCancel: {
            Task { await self.cancelPlaybackProbe(identifier: identifier) }
        })
        try ensureLifecycleScopeIsActive(lifecycleScope)
        try Task.checkCancellation()
        return result
    }

    private func startPlaybackProbe(
        identifier: UUID,
        reference: WebLocalMediaReference,
        lifecycleScope: PlaybackLifecycleScope,
        timeout: Duration,
        continuation: CheckedContinuation<Bool, any Error>
    ) {
        guard shutdownGate.acceptsWork,
              lifecycleScope > latestCancelledLifecycleScope else {
            continuation.resume(throwing: CancellationError())
            return
        }
        let playbackProbe = playbackProbe
        let task = Task.detached(priority: .utility) {
            await playbackProbe.isDirectlyPlayableAsync(reference)
        }
        let timeoutTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                await self?.timeoutPlaybackProbe(identifier: identifier)
            } catch {
                // Completion or lifecycle cancellation removed the deadline.
            }
        }
        activePlaybackProbeTasks[identifier] = ActivePlaybackProbeTask(
            lifecycleScope: lifecycleScope,
            task: task,
            timeoutTask: timeoutTask,
            continuation: continuation
        )
        Task.detached(priority: .utility) { [weak self] in
            let result = await task.value
            await self?.finishPlaybackProbe(identifier: identifier, result: result)
        }
    }

    private func finishPlaybackProbe(identifier: UUID, result: Bool) {
        if let activeTask = activePlaybackProbeTasks.removeValue(forKey: identifier) {
            activeTask.timeoutTask.cancel()
            activeTask.continuation.resume(returning: result)
        }
        orphanedPlaybackProbeTasks[identifier] = nil
    }

    private func timeoutPlaybackProbe(identifier: UUID) {
        guard let activeTask = activePlaybackProbeTasks.removeValue(forKey: identifier) else {
            return
        }
        activeTask.task.cancel()
        orphanedPlaybackProbeTasks[identifier] = OrphanedPlaybackProbeTask(
            lifecycleScope: activeTask.lifecycleScope,
            task: activeTask.task
        )
        // Runtime probing is advisory. A deadline falls back to the secure
        // conversion path without waiting for an uncooperative AV operation.
        activeTask.continuation.resume(returning: false)
    }

    private func cancelPlaybackProbe(identifier: UUID) {
        guard let activeTask = activePlaybackProbeTasks.removeValue(forKey: identifier) else {
            return
        }
        activeTask.timeoutTask.cancel()
        activeTask.task.cancel()
        orphanedPlaybackProbeTasks[identifier] = OrphanedPlaybackProbeTask(
            lifecycleScope: activeTask.lifecycleScope,
            task: activeTask.task
        )
        activeTask.continuation.resume(throwing: CancellationError())
    }

    private func cancelPlaybackProbeTasks(
        upTo checkpoint: PlaybackLifecycleScope
    ) {
        let matchingIdentifiers = activePlaybackProbeTasks.compactMap {
            identifier, trackedTask in
            trackedTask.lifecycleScope <= checkpoint ? identifier : nil
        }
        for identifier in matchingIdentifiers {
            cancelPlaybackProbe(identifier: identifier)
        }
        for trackedTask in orphanedPlaybackProbeTasks.values
        where trackedTask.lifecycleScope <= checkpoint {
            trackedTask.task.cancel()
        }
    }

    private func cancelAndDetachAllPlaybackProbeTasks() -> [Task<Bool, Never>] {
        let activeTasks = activePlaybackProbeTasks.values.map(\.task)
        let orphanedTasks = orphanedPlaybackProbeTasks.values.map(\.task)
        let active = activePlaybackProbeTasks
        activePlaybackProbeTasks.removeAll()
        orphanedPlaybackProbeTasks.removeAll()

        for trackedTask in active.values {
            trackedTask.timeoutTask.cancel()
            trackedTask.task.cancel()
            trackedTask.continuation.resume(throwing: CancellationError())
        }
        orphanedTasks.forEach { $0.cancel() }
        return activeTasks + orphanedTasks
    }

    private func cancelAndDetachJobs(
        upTo checkpoint: PlaybackLifecycleScope
    ) -> [Task<PreparedWebMedia, any Error>] {
        var taskGenerationsToAwait = Set<UUID>()

        for key in Array(jobs.keys) {
            guard var job = jobs[key] else { continue }
            let waiterIDsToCancel = job.waiters.compactMap { waiterID, waiter in
                waiter.lifecycleScope <= checkpoint ? waiterID : nil
            }
            guard !waiterIDsToCancel.isEmpty else { continue }

            for waiterID in waiterIDsToCancel {
                guard let waiter = job.waiters.removeValue(forKey: waiterID) else {
                    continue
                }
                waiterStates[waiterID] = nil
                if var trackedTask = tasksByGeneration[job.generation] {
                    trackedTask.lifecycleScopesByWaiterID[waiterID] = nil
                    tasksByGeneration[job.generation] = trackedTask
                }
                waiter.continuation.resume(throwing: CancellationError())
            }

            if job.waiters.isEmpty {
                jobs[key] = nil
                job.task.cancel()
                taskGenerationsToAwait.insert(job.generation)
            } else {
                jobs[key] = job
            }
        }

        // A caller may have cancelled its final waiter just before the
        // lifecycle event, leaving a detached converter to unwind without a
        // Job entry. Await those old orphan generations too, but never touch a
        // generation that still carries any scope newer than the checkpoint.
        let activeGenerations = Set(jobs.values.map(\.generation))
        for (generation, trackedTask) in tasksByGeneration
        where !activeGenerations.contains(generation)
            && trackedTask.lifecycleScopesByWaiterID.values.allSatisfy({ $0 <= checkpoint }) {
            trackedTask.task.cancel()
            taskGenerationsToAwait.insert(generation)
        }

        return taskGenerationsToAwait.compactMap { tasksByGeneration[$0]?.task }
    }

    private func cancelAndDetachAllJobs() -> [Task<PreparedWebMedia, any Error>] {
        let activeJobs = Array(jobs.values)
        let activeTasks = tasksByGeneration.values.map(\.task)
        jobs.removeAll()
        waiterStates.removeAll()
        for task in activeTasks {
            task.cancel()
        }
        for job in activeJobs {
            for waiter in job.waiters.values {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
        return activeTasks
    }

    private func beginCacheMaintenance() async throws {
        while maintenanceInProgress {
            try await waitForCacheMaintenanceIfNeeded()
        }
        try Task.checkCancellation()
        maintenanceInProgress = true
    }

    private func finishMaintenanceRequest(_ requestID: UUID) {
        guard activeMaintenanceRequestIDs.remove(requestID) != nil,
              activeMaintenanceRequestIDs.isEmpty else {
            return
        }
        let waiters = maintenanceDrainWaiters
        maintenanceDrainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForMaintenanceRequestsToDrain() async {
        guard !activeMaintenanceRequestIDs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            if activeMaintenanceRequestIDs.isEmpty {
                continuation.resume()
            } else {
                maintenanceDrainWaiters.append(continuation)
            }
        }
    }

    private func endCacheMaintenance() {
        maintenanceInProgress = false
        let waiting = maintenanceWaiterStates
        maintenanceWaiterStates.removeAll()
        for state in waiting.values {
            guard case .registered(let continuation) = state else { continue }
            continuation.resume()
        }
    }

    private func waitForCacheMaintenanceIfNeeded() async throws {
        guard maintenanceInProgress else { return }
        try Task.checkCancellation()
        let waiterID = UUID()
        maintenanceWaiterStates[waiterID] = .awaitingRegistration
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                registerMaintenanceWaiter(continuation, waiterID: waiterID)
            }
        }, onCancel: {
            Task { await self.cancelMaintenanceWaiter(waiterID) }
        })
        try Task.checkCancellation()
    }

    private func registerMaintenanceWaiter(
        _ continuation: CheckedContinuation<Void, any Error>,
        waiterID: UUID
    ) {
        guard case .awaitingRegistration = maintenanceWaiterStates[waiterID] else {
            continuation.resume(throwing: CancellationError())
            return
        }
        guard maintenanceInProgress else {
            maintenanceWaiterStates[waiterID] = nil
            continuation.resume()
            return
        }
        maintenanceWaiterStates[waiterID] = .registered(continuation)
    }

    private func cancelMaintenanceWaiter(_ waiterID: UUID) {
        guard let state = maintenanceWaiterStates.removeValue(forKey: waiterID) else {
            return
        }
        guard case .registered(let continuation) = state else { return }
        continuation.resume(throwing: CancellationError())
    }

    private static func mimeType(for kind: PreparedWebMediaKind) -> String {
        switch kind {
        case .video: "video/mp4"
        case .audio: "audio/mp4"
        }
    }

    private nonisolated static func run<T: Sendable>(
        before deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw ProjectDeadlineError.timedOut }
        return try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: remaining)
                throw ProjectDeadlineError.timedOut
            }
            guard let first = try await group.next() else {
                throw ProjectDeadlineError.timedOut
            }
            return first
        }
    }
}

/// FIFO permit pool that bounds actual FFmpeg work while allowing every
/// display to enqueue and deduplicate immediately. Jobs wait here before the
/// injected/Core preparer is entered, so a project with the maximum 64 static
/// media references can never launch 64 converter processes at once.
private actor WebMediaRuntimePreparationLimiter {
    private var availablePermits: Int
    private var waiters = [CheckedContinuation<Void, Never>]()

    init(maximumConcurrentPreparations: Int) {
        availablePermits = max(1, maximumConcurrentPreparations)
    }

    func perform<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if availablePermits > 0 {
            availablePermits -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
        do {
            try Task.checkCancellation()
            let result = try await operation()
            releasePermit()
            return result
        } catch {
            releasePermit()
            throw error
        }
    }

    private func releasePermit() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
