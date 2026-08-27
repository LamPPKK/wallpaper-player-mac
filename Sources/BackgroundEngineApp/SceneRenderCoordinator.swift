import Foundation

/// A monotonically increasing identifier captured synchronously when a
/// playback session starts. Lifecycle cleanup uses a checkpoint instead of a
/// process-wide sweep so a delayed stop/sleep task cannot cancel work that a
/// newer playback session has already started.
struct PlaybackLifecycleScope: Hashable, Comparable, Sendable {
    let rawValue: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Thread-safe because playback scopes must be allocated before hopping into
/// an unstructured task or actor. Each renderer owns its own counter.
final class PlaybackLifecycleScopeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var currentValue: UInt64 = 0

    func makeScope() -> PlaybackLifecycleScope {
        lock.lock()
        defer { lock.unlock() }
        precondition(currentValue < UInt64.max, "Playback lifecycle scope exhausted.")
        currentValue += 1
        return PlaybackLifecycleScope(rawValue: currentValue)
    }

    func checkpoint() -> PlaybackLifecycleScope {
        lock.lock()
        defer { lock.unlock() }
        return PlaybackLifecycleScope(rawValue: currentValue)
    }
}

/// A synchronous, process-lifetime gate used by the application termination
/// handshake. It must be closable before the main actor suspends so callbacks
/// already queued by a wallpaper window cannot start replacement work while
/// the quit barrier is draining existing jobs.
final class RuntimeShutdownGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isClosed = false

    func close() {
        lock.withLock { isClosed = true }
    }

    var acceptsWork: Bool {
        lock.withLock { !isClosed }
    }
}

enum SceneRenderJobState: Equatable, Sendable {
    case queued
    case running(progress: Double)
    case completed(URL)
    case failed(code: String, message: String)
    case cancelled
}

enum SceneRenderCoordinatorError: Error, LocalizedError, Equatable {
    case cancelled
    case timedOut

    var errorDescription: String? {
        switch self {
        case .cancelled: "The Scene render was cancelled."
        case .timedOut: "The Scene render exceeded its time limit."
        }
    }

    var diagnosticCode: String {
        switch self {
        case .cancelled: "scene_render_cancelled"
        case .timedOut: "scene_render_timeout"
        }
    }
}

/// Owns all external Scene render work. Jobs are keyed by the complete cache
/// key, so multiple displays requesting the same output share one process
/// while different resolutions/quality settings remain independent.
actor SceneRenderCoordinator {
    typealias RenderOperation = @Sendable (
        SceneVideoRenderConfiguration,
        String,
        (@Sendable (Double) -> Void)?
    ) throws -> SceneVideoRenderOutcome

    static let shared = SceneRenderCoordinator()

    private struct Job {
        let id: UUID
        let assetID: String
        let processScopeID: String
        let task: Task<SceneVideoRenderOutcome, Error>
        let timeoutTask: Task<Void, Never>
        var lifecycleScopes: [PlaybackLifecycleScope: Int]
    }

    private struct QueuedExecution {
        let key: String
        let jobID: UUID
        var continuation: CheckedContinuation<Void, any Error>?
    }

    private enum RetainedResult {
        case success(SceneVideoRenderOutcome)
        case failure(any Error)
    }

    private let renderOperation: RenderOperation
    private let maximumConcurrentRenders: Int
    private nonisolated let lifecycleScopeCounter = PlaybackLifecycleScopeCounter()
    private nonisolated let shutdownGate = RuntimeShutdownGate()
    private var jobs: [String: Job] = [:]
    /// Distinct cache keys share a small renderer budget. A job is counted as
    /// active from permit grant until its synchronous renderer/FFmpeg operation
    /// has actually unwound, including cancellation cleanup.
    private var activeRenderJobIDs: Set<UUID> = []
    /// Checked continuations make cancellation an actor-owned queue mutation:
    /// removing a queued job and resuming it with an error is atomic with
    /// choosing the next FIFO entry, so cancelled work can never be launched.
    private var queuedExecutions: [QueuedExecution] = []
    /// A cancelled or timed-out job is removed from `jobs` immediately so a
    /// newer playback session may reuse its cache key. Keep its underlying
    /// task here until it has actually unwound; application termination must
    /// wait for those retired tasks as well as currently addressable jobs.
    private var trackedRenderTasks: [UUID: Task<SceneVideoRenderOutcome, Error>] = [:]
    private var states: [String: SceneRenderJobState] = [:]
    private var progressHandlers: [String: [UUID: @Sendable (Double) -> Void]] = [:]
    private var fallbackDemandCounts: [String: Int] = [:]
    private var retainedFallbackResults: [String: RetainedResult] = [:]
    private var waiterCountsByJobID: [UUID: Int] = [:]
    private var cancelledJobIDs: Set<UUID> = []
    private var timedOutJobIDs: Set<UUID> = []
    private var latestCancelledLifecycleScope = PlaybackLifecycleScope(rawValue: 0)
    private var latestStartedLifecycleScopeByKey: [String: PlaybackLifecycleScope] = [:]

    init(
        maximumConcurrentRenders: Int = 2,
        renderOperation: @escaping RenderOperation = { configuration, ffmpegPath, progress in
            try SceneVideoRenderer.preflight(configuration: configuration)
            return try SceneVideoRenderer.renderWithOutcome(
                configuration: configuration,
                ffmpegPath: ffmpegPath,
                progressHandler: progress
            )
        }
    ) {
        precondition(maximumConcurrentRenders > 0, "Scene render concurrency must be positive.")
        self.maximumConcurrentRenders = maximumConcurrentRenders
        self.renderOperation = renderOperation
    }

    nonisolated func makeRenderScope() -> PlaybackLifecycleScope {
        lifecycleScopeCounter.makeScope()
    }

    nonisolated func cancellationCheckpoint() -> PlaybackLifecycleScope {
        lifecycleScopeCounter.checkpoint()
    }

    /// Closes the admission gate synchronously. This intentionally has no
    /// reset: the shared coordinator is process-scoped and shutdown is final.
    nonisolated func beginShutdown() {
        shutdownGate.close()
    }

    func render(
        configuration: SceneVideoRenderConfiguration,
        ffmpegPath: String,
        lifecycleScope providedLifecycleScope: PlaybackLifecycleScope? = nil,
        timeout: Duration = .seconds(180),
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> SceneVideoRenderOutcome {
        let lifecycleScope = providedLifecycleScope ?? makeRenderScope()
        try ensureLifecycleScopeIsActive(lifecycleScope)
        let originalKey = jobKey(for: configuration)
        let demandedFallbackKey: String?
        if configuration.quality == .low {
            demandedFallbackKey = nil
        } else {
            let key = jobKey(for: configuration.lowQualityFallback)
            fallbackDemandCounts[key, default: 0] += 1
            demandedFallbackKey = key
        }
        defer {
            if let demandedFallbackKey {
                releaseFallbackDemand(for: demandedFallbackKey)
            }
        }
        do {
            return try await renderSingle(
                configuration: configuration,
                ffmpegPath: ffmpegPath,
                lifecycleScope: lifecycleScope,
                timeout: timeout,
                progressHandler: progressHandler
            )
        } catch {
            try Task.checkCancellation()
            guard configuration.quality != .low,
                  !(error is SceneRenderCoordinatorError),
                  !(error is CancellationError) else {
                throw error
            }

            // Retry through the coordinator using the fallback's actual
            // cache key. Two different display sizes can clamp to the same
            // low-quality output; routing the retry here ensures they share
            // one process and one SceneVideoRenderOutcome instead of racing
            // to replace the same MP4/metadata pair.
            let fallback = configuration.lowQualityFallback
            do {
                let outcome = try await renderSingle(
                    configuration: fallback,
                    ffmpegPath: ffmpegPath,
                    lifecycleScope: lifecycleScope,
                    timeout: timeout,
                    progressHandler: progressHandler
                )
                updateStateFromFallback(
                    .completed(outcome.cacheURL),
                    originalKey: originalKey,
                    lifecycleScope: lifecycleScope
                )
                return outcome
            } catch {
                try ensureLifecycleScopeIsActive(lifecycleScope)
                if let fallbackState = states[jobKey(for: fallback)] {
                    updateStateFromFallback(
                        fallbackState,
                        originalKey: originalKey,
                        lifecycleScope: lifecycleScope
                    )
                }
                throw error
            }
        }
    }

    private func renderSingle(
        configuration: SceneVideoRenderConfiguration,
        ffmpegPath: String,
        lifecycleScope: PlaybackLifecycleScope,
        timeout: Duration,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> SceneVideoRenderOutcome {
        try ensureLifecycleScopeIsActive(lifecycleScope)
        let key = jobKey(for: configuration)
        if let retained = retainedFallbackResults[key] {
            switch retained {
            case .success(let outcome):
                return outcome
            case .failure(let error):
                throw error
            }
        }
        let observerID = UUID()
        if let progressHandler {
            progressHandlers[key, default: [:]][observerID] = progressHandler
        }
        defer { progressHandlers[key]?[observerID] = nil }

        if var existing = jobs[key] {
            existing.lifecycleScopes[lifecycleScope, default: 0] += 1
            jobs[key] = existing
            recordStartedLifecycleScope(lifecycleScope, for: key)
            waiterCountsByJobID[existing.id, default: 0] += 1
            defer {
                unregisterWaiter(
                    for: key,
                    jobID: existing.id,
                    lifecycleScope: lifecycleScope
                )
            }
            let output = try await awaitResult(for: key, jobID: existing.id, task: existing.task)
            try ensureLifecycleScopeIsActive(lifecycleScope)
            return output
        }

        states[key] = .queued
        let operation = renderOperation
        let coordinator = self
        let scopedConfiguration = configuration.scopedForProcesses(key)
        let jobID = UUID()
        // Register the request while still actor-isolated. Detached tasks are
        // free to reach `acquireRenderPermit` in any order, so enqueueing from
        // inside those tasks would make FIFO order depend on scheduler timing.
        queuedExecutions.append(
            QueuedExecution(key: key, jobID: jobID, continuation: nil)
        )
        let task = Task.detached(priority: .utility) {
            try await coordinator.acquireRenderPermit(for: key, jobID: jobID)
            do {
                try Task.checkCancellation()
                let output = try operation(scopedConfiguration, ffmpegPath) { progress in
                    Task { await coordinator.recordProgress(progress, for: key, jobID: jobID) }
                }
                try Task.checkCancellation()
                await coordinator.releaseRenderPermit(jobID: jobID)
                return output
            } catch {
                await coordinator.releaseRenderPermit(jobID: jobID)
                throw error
            }
        }
        trackedRenderTasks[jobID] = task
        Task.detached { [weak self] in
            _ = try? await task.value
            await self?.forgetTrackedRenderTask(jobID)
        }
        // The timeout is the total request SLA. It starts when the request is
        // admitted and therefore includes time spent waiting in the FIFO queue,
        // not only time inside the external renderer/FFmpeg operation.
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                await self?.timeoutJob(key: key, jobID: jobID)
            } catch {
                // Normal completion cancels this sleeper.
            }
        }
        jobs[key] = Job(
            id: jobID,
            assetID: configuration.assetId,
            processScopeID: key,
            task: task,
            timeoutTask: timeoutTask,
            lifecycleScopes: [lifecycleScope: 1]
        )
        waiterCountsByJobID[jobID] = 1
        recordStartedLifecycleScope(lifecycleScope, for: key)

        defer {
            unregisterWaiter(for: key, jobID: jobID, lifecycleScope: lifecycleScope)
        }
        let output = try await awaitResult(for: key, jobID: jobID, task: task)
        try ensureLifecycleScopeIsActive(lifecycleScope)
        return output
    }

    func state(for configuration: SceneVideoRenderConfiguration) -> SceneRenderJobState? {
        states[jobKey(for: configuration)]
    }

    /// Exposes the lifecycle ownership of a deduplicated job to focused
    /// coordinator tests without exposing mutable job state.
    func activeLifecycleScopes(
        for configuration: SceneVideoRenderConfiguration
    ) -> Set<PlaybackLifecycleScope> {
        guard let scopes = jobs[jobKey(for: configuration)]?.lifecycleScopes else {
            return []
        }
        return Set(scopes.keys)
    }

    func cancel(assetID: String) async {
        let matching = jobs.filter { $0.value.assetID == assetID }
        for (key, job) in matching {
            retireJobAsCancelled(job, for: key)
        }
        for (_, job) in matching { _ = try? await job.task.value }
    }

    func cancelAll() async {
        await cancelAll(upTo: cancellationCheckpoint())
    }

    /// Cancels only render sessions that existed when the caller captured its
    /// checkpoint. A shared job survives when any waiter belongs to a newer
    /// playback session. Selected jobs are detached from the key before this
    /// method suspends, allowing a replacement job to start safely while an
    /// uncooperative old process is still draining.
    func cancelAll(upTo checkpoint: PlaybackLifecycleScope) async {
        latestCancelledLifecycleScope = max(latestCancelledLifecycleScope, checkpoint)
        let matching = jobs.filter { _, job in
            !job.lifecycleScopes.isEmpty
                && job.lifecycleScopes.keys.allSatisfy { $0 <= checkpoint }
        }
        for (key, job) in matching {
            retireJobAsCancelled(job, for: key)
        }
        for (_, job) in matching { _ = try? await job.task.value }
    }

    /// Final process-lifetime drain. Unlike scoped playback cancellation this
    /// also owns tasks already retired from `jobs`, which may still be
    /// unwinding a renderer or FFmpeg process after timeout/cancellation.
    func shutdownAndWait() async {
        beginShutdown()
        latestCancelledLifecycleScope = max(
            latestCancelledLifecycleScope,
            cancellationCheckpoint()
        )

        let activeJobs = Array(jobs)
        for (key, job) in activeJobs {
            retireJobAsCancelled(job, for: key)
        }

        let tasks = Array(trackedRenderTasks.values)
        tasks.forEach { $0.cancel() }
        // Task cancellation alone cannot interrupt synchronous Process waits.
        // The registry sweep makes every tracked task able to unwind.
        SceneVideoRenderer.cancelAllActiveProcesses()
        for task in tasks {
            _ = try? await task.value
        }
    }

    private func forgetTrackedRenderTask(_ jobID: UUID) {
        trackedRenderTasks[jobID] = nil
    }

    private func acquireRenderPermit(for key: String, jobID: UUID) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard canExecuteJob(key: key, jobID: jobID) else {
                    continuation.resume(throwing: SceneRenderCoordinatorError.cancelled)
                    return
                }
                guard let index = queuedExecutions.firstIndex(where: { $0.jobID == jobID }) else {
                    continuation.resume(throwing: SceneRenderCoordinatorError.cancelled)
                    return
                }
                queuedExecutions[index].continuation = continuation
                startQueuedExecutionsIfPossible()
            }
        } onCancel: {
            Task { await self.cancelQueuedExecution(jobID: jobID) }
        }
    }

    private func releaseRenderPermit(jobID: UUID) {
        guard activeRenderJobIDs.remove(jobID) != nil else { return }
        startQueuedExecutionsIfPossible()
    }

    private func cancelQueuedExecution(jobID: UUID) {
        guard let index = queuedExecutions.firstIndex(where: { $0.jobID == jobID }) else {
            return
        }
        let queued = queuedExecutions.remove(at: index)
        queued.continuation?.resume(throwing: CancellationError())
        startQueuedExecutionsIfPossible()
    }

    private func startQueuedExecutionsIfPossible() {
        while activeRenderJobIDs.count < maximumConcurrentRenders,
              !queuedExecutions.isEmpty {
            let queued = queuedExecutions[0]
            guard canExecuteJob(key: queued.key, jobID: queued.jobID) else {
                queuedExecutions.removeFirst()
                queued.continuation?.resume(throwing: SceneRenderCoordinatorError.cancelled)
                continue
            }
            // Do not allow a later request to overtake an earlier request
            // whose detached task has not attached its continuation yet.
            guard let continuation = queued.continuation else { return }
            queuedExecutions.removeFirst()
            activateExecution(
                key: queued.key,
                jobID: queued.jobID,
                continuation: continuation
            )
        }
    }

    private func activateExecution(
        key: String,
        jobID: UUID,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        activeRenderJobIDs.insert(jobID)
        states[key] = .running(progress: 0)
        continuation.resume()
    }

    private func canExecuteJob(key: String, jobID: UUID) -> Bool {
        shutdownGate.acceptsWork
            && jobs[key]?.id == jobID
            && !cancelledJobIDs.contains(jobID)
            && !timedOutJobIDs.contains(jobID)
    }

    private func recordProgress(_ progress: Double, for key: String, jobID: UUID) {
        guard jobs[key]?.id == jobID else { return }
        switch states[key] {
        case .queued, .running:
            break
        case .completed, .failed, .cancelled, .none:
            return
        }
        let value = min(1, max(0, progress))
        states[key] = .running(progress: value)
        for handler in progressHandlers[key, default: [:]].values { handler(value) }
    }

    private func timeoutJob(key: String, jobID: UUID) {
        guard let job = jobs[key], job.id == jobID else { return }
        states[key] = .failed(
            code: SceneRenderCoordinatorError.timedOut.diagnosticCode,
            message: SceneRenderCoordinatorError.timedOut.localizedDescription
        )
        timedOutJobIDs.insert(job.id)
        job.task.cancel()
        job.timeoutTask.cancel()
        cancelQueuedExecution(jobID: job.id)
        SceneVideoRenderer.cancelActiveProcesses(scopeID: job.processScopeID)
        jobs[key] = nil
        progressHandlers[key] = nil
    }

    private func finishJob(key: String, jobID: UUID) {
        guard let job = jobs[key], job.id == jobID else { return }
        job.timeoutTask.cancel()
        jobs[key] = nil
        progressHandlers[key] = nil
    }

    private func retireJobAsCancelled(_ job: Job, for key: String) {
        guard jobs[key]?.id == job.id else { return }
        cancelledJobIDs.insert(job.id)
        job.task.cancel()
        job.timeoutTask.cancel()
        cancelQueuedExecution(jobID: job.id)
        SceneVideoRenderer.cancelActiveProcesses(scopeID: job.processScopeID)
        states[key] = .cancelled
        jobs[key] = nil
        progressHandlers[key] = nil
    }

    private func unregisterWaiter(
        for key: String,
        jobID: UUID,
        lifecycleScope: PlaybackLifecycleScope
    ) {
        if var job = jobs[key], job.id == jobID {
            let remainingForScope = job.lifecycleScopes[lifecycleScope, default: 0] - 1
            if remainingForScope > 0 {
                job.lifecycleScopes[lifecycleScope] = remainingForScope
            } else {
                job.lifecycleScopes[lifecycleScope] = nil
            }
            jobs[key] = job
        }

        let remainingWaiters = waiterCountsByJobID[jobID, default: 0] - 1
        if remainingWaiters > 0 {
            waiterCountsByJobID[jobID] = remainingWaiters
        } else {
            waiterCountsByJobID[jobID] = nil
            cancelledJobIDs.remove(jobID)
            timedOutJobIDs.remove(jobID)
        }
    }

    private func ensureLifecycleScopeIsActive(_ lifecycleScope: PlaybackLifecycleScope) throws {
        guard shutdownGate.acceptsWork,
              lifecycleScope > latestCancelledLifecycleScope else {
            throw SceneRenderCoordinatorError.cancelled
        }
    }

    private func recordStartedLifecycleScope(
        _ lifecycleScope: PlaybackLifecycleScope,
        for key: String
    ) {
        latestStartedLifecycleScopeByKey[key] = max(
            latestStartedLifecycleScopeByKey[key] ?? lifecycleScope,
            lifecycleScope
        )
    }

    private func updateStateFromFallback(
        _ state: SceneRenderJobState,
        originalKey: String,
        lifecycleScope: PlaybackLifecycleScope
    ) {
        let latestStartedScope = latestStartedLifecycleScopeByKey[
            originalKey,
            default: lifecycleScope
        ]
        guard latestStartedScope <= lifecycleScope else {
            return
        }
        states[originalKey] = state
    }

    private func retainFallbackResult(_ result: RetainedResult, for key: String) {
        guard fallbackDemandCounts[key, default: 0] > 0 else { return }
        retainedFallbackResults[key] = result
    }

    private func releaseFallbackDemand(for key: String) {
        let remaining = fallbackDemandCounts[key, default: 0] - 1
        if remaining > 0 {
            fallbackDemandCounts[key] = remaining
        } else {
            fallbackDemandCounts[key] = nil
            retainedFallbackResults[key] = nil
        }
    }

    /// Every caller sharing a deduplicated task must observe the same
    /// coordinator-level result. In particular, `Task.cancel()` is how both
    /// explicit cancellation and a timeout interrupt the underlying render,
    /// so raw `CancellationError` must be translated using the terminal job
    /// state rather than leaking to secondary display sessions.
    private func awaitResult(
        for key: String,
        jobID: UUID,
        task: Task<SceneVideoRenderOutcome, Error>
    ) async throws -> SceneVideoRenderOutcome {
        do {
            let output = try await task.value
            if timedOutJobIDs.contains(jobID) {
                throw SceneRenderCoordinatorError.timedOut
            }
            if cancelledJobIDs.contains(jobID) {
                throw SceneRenderCoordinatorError.cancelled
            }
            guard jobs[key]?.id == jobID else {
                return output
            }
            switch states[key] {
            case .queued, .running:
                states[key] = .completed(output.cacheURL)
                retainFallbackResult(.success(output), for: key)
                finishJob(key: key, jobID: jobID)
                return output
            case .completed:
                retainFallbackResult(.success(output), for: key)
                return output
            case .failed(let code, _) where code == SceneRenderCoordinatorError.timedOut.diagnosticCode:
                finishJob(key: key, jobID: jobID)
                throw SceneRenderCoordinatorError.timedOut
            case .cancelled, .failed, .none:
                finishJob(key: key, jobID: jobID)
                throw SceneRenderCoordinatorError.cancelled
            }
        } catch {
            if timedOutJobIDs.contains(jobID) {
                finishJob(key: key, jobID: jobID)
                throw SceneRenderCoordinatorError.timedOut
            }
            if cancelledJobIDs.contains(jobID) {
                finishJob(key: key, jobID: jobID)
                throw SceneRenderCoordinatorError.cancelled
            }
            guard jobs[key]?.id == jobID else {
                if let coordinatorError = error as? SceneRenderCoordinatorError {
                    throw coordinatorError
                }
                if error is CancellationError {
                    throw SceneRenderCoordinatorError.cancelled
                }
                throw error
            }
            if case .failed(let code, _) = states[key],
               code == SceneRenderCoordinatorError.timedOut.diagnosticCode {
                finishJob(key: key, jobID: jobID)
                throw SceneRenderCoordinatorError.timedOut
            }
            if case .cancelled = states[key] {
                finishJob(key: key, jobID: jobID)
                throw SceneRenderCoordinatorError.cancelled
            }
            if error is CancellationError {
                states[key] = .cancelled
                finishJob(key: key, jobID: jobID)
                throw SceneRenderCoordinatorError.cancelled
            }
            states[key] = .failed(code: "scene_render_failed", message: error.localizedDescription)
            retainFallbackResult(.failure(error), for: key)
            finishJob(key: key, jobID: jobID)
            throw error
        }
    }

    private func jobKey(for configuration: SceneVideoRenderConfiguration) -> String {
        configuration.cacheKey?.fileName
            ?? "\(configuration.assetId)-\(Int(configuration.size.width))x\(Int(configuration.size.height))-\(configuration.quality.rawValue)"
    }
}
