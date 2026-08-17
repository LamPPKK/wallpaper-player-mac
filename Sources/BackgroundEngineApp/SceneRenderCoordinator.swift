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
    ) throws -> URL

    static let shared = SceneRenderCoordinator()

    private struct Job {
        let assetID: String
        let task: Task<URL, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let renderOperation: RenderOperation
    private var jobs: [String: Job] = [:]
    private var states: [String: SceneRenderJobState] = [:]
    private var progressHandlers: [String: [UUID: @Sendable (Double) -> Void]] = [:]

    init(renderOperation: @escaping RenderOperation = { configuration, ffmpegPath, progress in
        try SceneVideoRenderer.preflight(configuration: configuration)
        do {
            return try SceneVideoRenderer.render(
                configuration: configuration,
                ffmpegPath: ffmpegPath,
                progressHandler: progress
            )
        } catch {
            try Task.checkCancellation()
            guard configuration.quality != .low else { throw error }
            return try SceneVideoRenderer.render(
                configuration: configuration.lowQualityFallback,
                ffmpegPath: ffmpegPath,
                progressHandler: progress
            )
        }
    }) {
        self.renderOperation = renderOperation
    }

    func render(
        configuration: SceneVideoRenderConfiguration,
        ffmpegPath: String,
        timeout: Duration = .seconds(180),
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let key = jobKey(for: configuration)
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
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let output = try operation(configuration, ffmpegPath) { progress in
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
        jobs[key] = Job(assetID: configuration.assetId, task: task, timeoutTask: timeoutTask)
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
            SceneVideoRenderer.cancelActiveProcesses(assetID: assetID)
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
        SceneVideoRenderer.cancelActiveProcesses(assetID: job.assetID)
    }

    private func finishJob(key: String) {
        jobs[key]?.timeoutTask.cancel()
        jobs[key] = nil
        progressHandlers[key] = nil
    }

    /// Every caller sharing a deduplicated task must observe the same
    /// coordinator-level result. In particular, `Task.cancel()` is how both
    /// explicit cancellation and a timeout interrupt the underlying render,
    /// so raw `CancellationError` must be translated using the terminal job
    /// state rather than leaking to secondary display sessions.
    private func awaitResult(for key: String, task: Task<URL, Error>) async throws -> URL {
        do {
            let output = try await task.value
            switch states[key] {
            case .queued, .running:
                states[key] = .completed(output)
                finishJob(key: key)
                return output
            case .completed(let existingOutput):
                return existingOutput
            case .failed(let code, _) where code == SceneRenderCoordinatorError.timedOut.diagnosticCode:
                finishJob(key: key)
                throw SceneRenderCoordinatorError.timedOut
            case .cancelled, .failed, .none:
                finishJob(key: key)
                throw SceneRenderCoordinatorError.cancelled
            }
        } catch {
            if case .failed(let code, _) = states[key],
               code == SceneRenderCoordinatorError.timedOut.diagnosticCode {
                finishJob(key: key)
                throw SceneRenderCoordinatorError.timedOut
            }
            if case .cancelled = states[key] {
                finishJob(key: key)
                throw SceneRenderCoordinatorError.cancelled
            }
            if error is CancellationError {
                states[key] = .cancelled
                finishJob(key: key)
                throw SceneRenderCoordinatorError.cancelled
            }
            states[key] = .failed(code: "scene_render_failed", message: error.localizedDescription)
            finishJob(key: key)
            throw error
        }
    }

    private func jobKey(for configuration: SceneVideoRenderConfiguration) -> String {
        configuration.cacheKey?.fileName
            ?? "\(configuration.assetId)-\(Int(configuration.size.width))x\(Int(configuration.size.height))-\(configuration.quality.rawValue)"
    }
}
