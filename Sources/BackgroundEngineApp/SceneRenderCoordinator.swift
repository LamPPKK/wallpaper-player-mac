import Foundation

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
        let assetID: String
        let processScopeID: String
        let task: Task<SceneVideoRenderOutcome, Error>
        let timeoutTask: Task<Void, Never>
    }

    private enum RetainedResult {
        case success(SceneVideoRenderOutcome)
        case failure(any Error)
    }

    private let renderOperation: RenderOperation
    private var jobs: [String: Job] = [:]
    private var states: [String: SceneRenderJobState] = [:]
    private var progressHandlers: [String: [UUID: @Sendable (Double) -> Void]] = [:]
    private var fallbackDemandCounts: [String: Int] = [:]
    private var retainedFallbackResults: [String: RetainedResult] = [:]

    init(renderOperation: @escaping RenderOperation = { configuration, ffmpegPath, progress in
        try SceneVideoRenderer.preflight(configuration: configuration)
        return try SceneVideoRenderer.renderWithOutcome(
            configuration: configuration,
            ffmpegPath: ffmpegPath,
            progressHandler: progress
        )
    }) {
        self.renderOperation = renderOperation
    }

    func render(
        configuration: SceneVideoRenderConfiguration,
        ffmpegPath: String,
        timeout: Duration = .seconds(180),
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> SceneVideoRenderOutcome {
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
                    timeout: timeout,
                    progressHandler: progressHandler
                )
                states[originalKey] = .completed(outcome.cacheURL)
                return outcome
            } catch {
                if let fallbackState = states[jobKey(for: fallback)] {
                    states[originalKey] = fallbackState
                }
                throw error
            }
        }
    }

    private func renderSingle(
        configuration: SceneVideoRenderConfiguration,
        ffmpegPath: String,
        timeout: Duration,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> SceneVideoRenderOutcome {
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

        if let existing = jobs[key] {
            return try await awaitResult(for: key, task: existing.task)
        }

        states[key] = .queued
        let operation = renderOperation
        let coordinator = self
        let scopedConfiguration = configuration.scopedForProcesses(key)
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let output = try operation(scopedConfiguration, ffmpegPath) { progress in
                Task { await coordinator.recordProgress(progress, for: key) }
            }
            try Task.checkCancellation()
            return output
        }
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                await self?.timeoutJob(key: key)
            } catch {
                // Normal completion cancels this sleeper.
            }
        }
        jobs[key] = Job(
            assetID: configuration.assetId,
            processScopeID: key,
            task: task,
            timeoutTask: timeoutTask
        )
        states[key] = .running(progress: 0)

        return try await awaitResult(for: key, task: task)
    }

    func state(for configuration: SceneVideoRenderConfiguration) -> SceneRenderJobState? {
        states[jobKey(for: configuration)]
    }

    func cancel(assetID: String) async {
        let matching = jobs.filter { $0.value.assetID == assetID }
        for (key, job) in matching {
            job.task.cancel()
            job.timeoutTask.cancel()
            SceneVideoRenderer.cancelActiveProcesses(scopeID: job.processScopeID)
            states[key] = .cancelled
        }
        for (_, job) in matching { _ = try? await job.task.value }
    }

    func cancelAll() async {
        let active = jobs
        for (_, job) in active {
            job.task.cancel()
            job.timeoutTask.cancel()
        }
        SceneVideoRenderer.cancelAllActiveProcesses()
        for key in active.keys { states[key] = .cancelled }
        for (_, job) in active { _ = try? await job.task.value }
    }

    private func recordProgress(_ progress: Double, for key: String) {
        guard jobs[key] != nil else { return }
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

    private func timeoutJob(key: String) {
        guard let job = jobs[key] else { return }
        states[key] = .failed(
            code: SceneRenderCoordinatorError.timedOut.diagnosticCode,
            message: SceneRenderCoordinatorError.timedOut.localizedDescription
        )
        job.task.cancel()
        SceneVideoRenderer.cancelActiveProcesses(scopeID: job.processScopeID)
    }

    private func finishJob(key: String) {
        jobs[key]?.timeoutTask.cancel()
        jobs[key] = nil
        progressHandlers[key] = nil
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
        task: Task<SceneVideoRenderOutcome, Error>
    ) async throws -> SceneVideoRenderOutcome {
        do {
            let output = try await task.value
            switch states[key] {
            case .queued, .running:
                states[key] = .completed(output.cacheURL)
                retainFallbackResult(.success(output), for: key)
                finishJob(key: key)
                return output
            case .completed:
                retainFallbackResult(.success(output), for: key)
                return output
            case .failed(let code, _) where code == SceneRenderCoordinatorError.timedOut.diagnosticCode:
                retainFallbackResult(.failure(SceneRenderCoordinatorError.timedOut), for: key)
                finishJob(key: key)
                throw SceneRenderCoordinatorError.timedOut
            case .cancelled, .failed, .none:
                retainFallbackResult(.failure(SceneRenderCoordinatorError.cancelled), for: key)
                finishJob(key: key)
                throw SceneRenderCoordinatorError.cancelled
            }
        } catch {
            if case .failed(let code, _) = states[key],
               code == SceneRenderCoordinatorError.timedOut.diagnosticCode {
                retainFallbackResult(.failure(SceneRenderCoordinatorError.timedOut), for: key)
                finishJob(key: key)
                throw SceneRenderCoordinatorError.timedOut
            }
            if case .cancelled = states[key] {
                retainFallbackResult(.failure(SceneRenderCoordinatorError.cancelled), for: key)
                finishJob(key: key)
                throw SceneRenderCoordinatorError.cancelled
            }
            if error is CancellationError {
                states[key] = .cancelled
                retainFallbackResult(.failure(SceneRenderCoordinatorError.cancelled), for: key)
                finishJob(key: key)
                throw SceneRenderCoordinatorError.cancelled
            }
            states[key] = .failed(code: "scene_render_failed", message: error.localizedDescription)
            retainFallbackResult(.failure(error), for: key)
            finishJob(key: key)
            throw error
        }
    }

    private func jobKey(for configuration: SceneVideoRenderConfiguration) -> String {
        configuration.cacheKey?.fileName
            ?? "\(configuration.assetId)-\(Int(configuration.size.width))x\(Int(configuration.size.height))-\(configuration.quality.rawValue)"
    }
}
