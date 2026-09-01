import Foundation
import XCTest
@testable import BackgroundEngineApp
import BackgroundEngineCore

final class SceneRenderCoordinatorTests: XCTestCase {
    func testDuplicateRequestsShareOneRenderOperation() async throws {
        let counter = LockedCounter()
        let output = URL(filePath: "/tmp/scene-coordinator-output.mp4")
        let expected = SceneVideoRenderOutcome(
            cacheURL: output,
            audioResult: .notRequired
        )
        let coordinator = SceneRenderCoordinator { _, _, progress in
            counter.increment()
            progress?(0.5)
            Thread.sleep(forTimeInterval: 0.05)
            return expected
        }
        let configuration = makeConfiguration(assetID: "shared")

        async let first = coordinator.render(configuration: configuration, ffmpegPath: "/tmp/ffmpeg")
        async let second = coordinator.render(configuration: configuration, ffmpegPath: "/tmp/ffmpeg")
        let values = try await [first, second]
        let state = await coordinator.state(for: configuration)

        XCTAssertEqual(values, [expected, expected])
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(state, .completed(output))
    }

    func testDuplicateRequestsShareTheSameDegradedAudioOutcome() async throws {
        let counter = LockedCounter()
        let output = URL(filePath: "/tmp/scene-coordinator-degraded.mp4")
        let expected = SceneVideoRenderOutcome(
            cacheURL: output,
            audioResult: .degraded("Authored Scene audio could not be added to the rendered cache.")
        )
        let coordinator = SceneRenderCoordinator { _, _, _ in
            counter.increment()
            Thread.sleep(forTimeInterval: 0.05)
            return expected
        }
        let configuration = makeConfiguration(assetID: "shared-degraded")

        async let first = coordinator.render(configuration: configuration, ffmpegPath: "/tmp/ffmpeg")
        async let second = coordinator.render(configuration: configuration, ffmpegPath: "/tmp/ffmpeg")
        let values = try await [first, second]
        let state = await coordinator.state(for: configuration)

        XCTAssertEqual(values, [expected, expected])
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(state, .completed(output))
    }

    func testDistinctExternalRendersRespectConfiguredConcurrencyLimit() async throws {
        let concurrency = LockedConcurrencyCounter()
        let invocationCount = LockedCounter()
        let releaseRenders = LockedFlag()
        let coordinator = SceneRenderCoordinator(maximumConcurrentRenders: 2) { configuration, _, _ in
            invocationCount.increment()
            concurrency.begin()
            defer { concurrency.end() }
            while !releaseRenders.value {
                if Task.isCancelled { throw CancellationError() }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return SceneVideoRenderOutcome(
                cacheURL: URL(filePath: "/tmp/\(configuration.assetId).mp4"),
                audioResult: .notRequired
            )
        }
        let configurations = (0..<6).map { index in
            makeConfiguration(assetID: "bounded-\(index)")
        }
        let tasks = configurations.map { configuration in
            Task {
                try await coordinator.render(
                    configuration: configuration,
                    ffmpegPath: "/tmp/ffmpeg"
                )
            }
        }

        XCTAssertTrue(waitUntil { concurrency.maximumActive == 2 })
        XCTAssertEqual(invocationCount.value, 2)
        releaseRenders.set()

        for task in tasks {
            _ = try await task.value
        }
        XCTAssertEqual(invocationCount.value, 6)
        XCTAssertEqual(concurrency.completed, 6)
        XCTAssertEqual(concurrency.maximumActive, 2)
    }

    func testDistinctExternalRenderQueueStartsInFIFOOrder() async throws {
        let startOrder = LockedStringArray()
        let operationStarted = DispatchSemaphore(value: 0)
        let releaseOperation = DispatchSemaphore(value: 0)
        let coordinator = SceneRenderCoordinator(maximumConcurrentRenders: 1) { configuration, _, _ in
            startOrder.append(configuration.assetId)
            operationStarted.signal()
            _ = releaseOperation.wait(timeout: .now() + 2)
            return SceneVideoRenderOutcome(
                cacheURL: URL(filePath: "/tmp/\(configuration.assetId).mp4"),
                audioResult: .notRequired
            )
        }
        let firstConfiguration = makeConfiguration(assetID: "fifo-first")
        let secondConfiguration = makeConfiguration(assetID: "fifo-second")
        let thirdConfiguration = makeConfiguration(assetID: "fifo-third")
        let first = Task {
            try await coordinator.render(
                configuration: firstConfiguration,
                ffmpegPath: "/tmp/ffmpeg"
            )
        }
        XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)

        let second = Task {
            try await coordinator.render(
                configuration: secondConfiguration,
                ffmpegPath: "/tmp/ffmpeg"
            )
        }
        let secondQueued = await waitUntilAsync {
            await coordinator.state(for: secondConfiguration) == .queued
        }
        XCTAssertTrue(secondQueued)
        let third = Task {
            try await coordinator.render(
                configuration: thirdConfiguration,
                ffmpegPath: "/tmp/ffmpeg"
            )
        }
        let thirdQueued = await waitUntilAsync {
            await coordinator.state(for: thirdConfiguration) == .queued
        }
        XCTAssertTrue(thirdQueued)

        releaseOperation.signal()
        XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(startOrder.values, ["fifo-first", "fifo-second"])
        releaseOperation.signal()
        XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(startOrder.values, ["fifo-first", "fifo-second", "fifo-third"])
        releaseOperation.signal()

        _ = try await first.value
        _ = try await second.value
        _ = try await third.value
    }

    func testQueuedRenderTimeoutStartsOnlyAfterPermitIsGranted() async throws {
        let operationStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let invocations = LockedStringArray()
        let coordinator = SceneRenderCoordinator(maximumConcurrentRenders: 1) {
            configuration, _, _ in
            invocations.append(configuration.assetId)
            operationStarted.signal()
            if configuration.assetId == "queue-timeout-first" {
                _ = releaseFirst.wait(timeout: .now() + 2)
            }
            return SceneVideoRenderOutcome(
                cacheURL: URL(filePath: "/tmp/\(configuration.assetId).mp4"),
                audioResult: .notRequired
            )
        }
        let firstConfiguration = makeConfiguration(assetID: "queue-timeout-first")
        let secondConfiguration = makeConfiguration(assetID: "queue-timeout-second")
        let first = Task {
            try await coordinator.render(
                configuration: firstConfiguration,
                ffmpegPath: "/tmp/ffmpeg",
                timeout: .seconds(1)
            )
        }
        XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)
        let second = Task {
            try await coordinator.render(
                configuration: secondConfiguration,
                ffmpegPath: "/tmp/ffmpeg",
                timeout: .milliseconds(20)
            )
        }
        let secondQueued = await waitUntilAsync {
            await coordinator.state(for: secondConfiguration) == .queued
        }
        XCTAssertTrue(secondQueued)

        try await Task.sleep(for: .milliseconds(60))
        let stateAfterQueueDelay = await coordinator.state(for: secondConfiguration)
        XCTAssertEqual(stateAfterQueueDelay, .queued)
        releaseFirst.signal()

        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(invocations.values, ["queue-timeout-first", "queue-timeout-second"])
    }

    func testExplicitCancellationRemovesQueuedRenderBeforeInvocation() async throws {
        let startOrder = LockedStringArray()
        let operationStarted = DispatchSemaphore(value: 0)
        let releaseOperation = DispatchSemaphore(value: 0)
        let coordinator = SceneRenderCoordinator(maximumConcurrentRenders: 1) { configuration, _, _ in
            startOrder.append(configuration.assetId)
            operationStarted.signal()
            _ = releaseOperation.wait(timeout: .now() + 2)
            return SceneVideoRenderOutcome(
                cacheURL: URL(filePath: "/tmp/\(configuration.assetId).mp4"),
                audioResult: .notRequired
            )
        }
        let activeConfiguration = makeConfiguration(assetID: "cancel-active")
        let cancelledConfiguration = makeConfiguration(assetID: "cancel-queued")
        let survivorConfiguration = makeConfiguration(assetID: "cancel-survivor")
        let active = Task {
            try await coordinator.render(
                configuration: activeConfiguration,
                ffmpegPath: "/tmp/ffmpeg"
            )
        }
        XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)

        let cancelled = Task {
            try await coordinator.render(
                configuration: cancelledConfiguration,
                ffmpegPath: "/tmp/ffmpeg"
            )
        }
        let cancelledQueued = await waitUntilAsync {
            await coordinator.state(for: cancelledConfiguration) == .queued
        }
        XCTAssertTrue(cancelledQueued)
        let survivor = Task {
            try await coordinator.render(
                configuration: survivorConfiguration,
                ffmpegPath: "/tmp/ffmpeg"
            )
        }
        let survivorQueued = await waitUntilAsync {
            await coordinator.state(for: survivorConfiguration) == .queued
        }
        XCTAssertTrue(survivorQueued)

        await coordinator.cancel(assetID: cancelledConfiguration.assetId)
        do {
            _ = try await cancelled.value
            XCTFail("Expected queued render cancellation.")
        } catch {
            XCTAssertEqual(error as? SceneRenderCoordinatorError, .cancelled)
        }
        let cancelledState = await coordinator.state(for: cancelledConfiguration)
        XCTAssertEqual(cancelledState, .cancelled)
        XCTAssertEqual(startOrder.values, ["cancel-active"])

        releaseOperation.signal()
        XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(startOrder.values, ["cancel-active", "cancel-survivor"])
        releaseOperation.signal()
        _ = try await active.value
        _ = try await survivor.value
    }

    func testCancelledActiveRenderRetainsPermitUntilOperationActuallyUnwinds() async throws {
        let events = LockedStringArray()
        let activeStarted = LockedFlag()
        let cancellationObserved = LockedFlag()
        let allowActiveToExit = LockedFlag()
        let queuedStarted = LockedFlag()
        let activeConfiguration = makeConfiguration(assetID: "cancelled-active-permit")
        let queuedConfiguration = makeConfiguration(assetID: "queued-behind-cancelled-active")
        let coordinator = SceneRenderCoordinator(maximumConcurrentRenders: 1) {
            configuration, _, _ in
            if configuration.assetId == activeConfiguration.assetId {
                events.append("active-start")
                activeStarted.set()
                while !Task.isCancelled {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                cancellationObserved.set()
                while !allowActiveToExit.value {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                events.append("active-exit")
                throw CancellationError()
            }

            events.append("queued-start")
            queuedStarted.set()
            return SceneVideoRenderOutcome(
                cacheURL: URL(filePath: "/tmp/\(configuration.assetId).mp4"),
                audioResult: .notRequired
            )
        }
        let active = Task {
            try await coordinator.render(
                configuration: activeConfiguration,
                ffmpegPath: "/tmp/ffmpeg"
            )
        }
        XCTAssertTrue(waitUntil { activeStarted.value })
        let queued = Task {
            try await coordinator.render(
                configuration: queuedConfiguration,
                ffmpegPath: "/tmp/ffmpeg"
            )
        }
        let isQueued = await waitUntilAsync {
            await coordinator.state(for: queuedConfiguration) == .queued
        }
        XCTAssertTrue(isQueued)

        let cancellation = Task {
            await coordinator.cancel(assetID: activeConfiguration.assetId)
        }
        XCTAssertTrue(waitUntil { cancellationObserved.value })

        // Cancellation retires the job from lookup immediately, but the
        // external operation is intentionally still unwinding. The permit and
        // FIFO state must not advance until that synchronous work exits.
        let queuedStateWhileActiveUnwinds = await coordinator.state(for: queuedConfiguration)
        XCTAssertEqual(queuedStateWhileActiveUnwinds, .queued)
        XCTAssertFalse(queuedStarted.value)
        XCTAssertEqual(events.values, ["active-start"])

        allowActiveToExit.set()
        XCTAssertTrue(waitUntil { queuedStarted.value })
        await cancellation.value
        guard case .failure(let activeError) = await active.result else {
            return XCTFail("Expected the cancelled active render to fail.")
        }
        XCTAssertEqual(activeError as? SceneRenderCoordinatorError, .cancelled)
        _ = try await queued.value
        XCTAssertEqual(events.values, ["active-start", "active-exit", "queued-start"])
    }

    func testLifecycleCheckpointCancelsQueuedRenderWithoutLaunchingIt() async throws {
        let startOrder = LockedStringArray()
        let activeStarted = DispatchSemaphore(value: 0)
        let releaseActive = DispatchSemaphore(value: 0)
        let coordinator = SceneRenderCoordinator(maximumConcurrentRenders: 1) { configuration, _, _ in
            startOrder.append(configuration.assetId)
            activeStarted.signal()
            _ = releaseActive.wait(timeout: .now() + 2)
            return SceneVideoRenderOutcome(
                cacheURL: URL(filePath: "/tmp/\(configuration.assetId).mp4"),
                audioResult: .notRequired
            )
        }
        let queuedScope = coordinator.makeRenderScope()
        let checkpoint = coordinator.cancellationCheckpoint()
        let activeScope = coordinator.makeRenderScope()
        let activeConfiguration = makeConfiguration(assetID: "lifecycle-active")
        let queuedConfiguration = makeConfiguration(assetID: "lifecycle-queued")
        let active = Task {
            try await coordinator.render(
                configuration: activeConfiguration,
                ffmpegPath: "/tmp/ffmpeg",
                lifecycleScope: activeScope
            )
        }
        XCTAssertEqual(activeStarted.wait(timeout: .now() + 1), .success)
        let queued = Task {
            try await coordinator.render(
                configuration: queuedConfiguration,
                ffmpegPath: "/tmp/ffmpeg",
                lifecycleScope: queuedScope
            )
        }
        let lifecycleJobQueued = await waitUntilAsync {
            await coordinator.state(for: queuedConfiguration) == .queued
        }
        XCTAssertTrue(lifecycleJobQueued)

        await coordinator.cancelAll(upTo: checkpoint)
        do {
            _ = try await queued.value
            XCTFail("Expected lifecycle cancellation for the queued render.")
        } catch {
            XCTAssertEqual(error as? SceneRenderCoordinatorError, .cancelled)
        }
        XCTAssertEqual(startOrder.values, ["lifecycle-active"])

        releaseActive.signal()
        _ = try await active.value
        XCTAssertEqual(startOrder.values, ["lifecycle-active"])
    }

    func testShutdownDrainsQueuedRendersWithoutLaunchingThem() async throws {
        let startOrder = LockedStringArray()
        let activeStarted = DispatchSemaphore(value: 0)
        let releaseActive = DispatchSemaphore(value: 0)
        let shutdownFinished = LockedFlag()
        let coordinator = SceneRenderCoordinator(maximumConcurrentRenders: 1) { configuration, _, _ in
            startOrder.append(configuration.assetId)
            activeStarted.signal()
            _ = releaseActive.wait(timeout: .now() + 2)
            return SceneVideoRenderOutcome(
                cacheURL: URL(filePath: "/tmp/\(configuration.assetId).mp4"),
                audioResult: .notRequired
            )
        }
        let activeConfiguration = makeConfiguration(assetID: "shutdown-active")
        let queuedConfigurations = [
            makeConfiguration(assetID: "shutdown-queued-one"),
            makeConfiguration(assetID: "shutdown-queued-two")
        ]
        let active = Task {
            try await coordinator.render(
                configuration: activeConfiguration,
                ffmpegPath: "/tmp/ffmpeg"
            )
        }
        XCTAssertEqual(activeStarted.wait(timeout: .now() + 1), .success)
        let queued = queuedConfigurations.map { configuration in
            Task {
                try await coordinator.render(
                    configuration: configuration,
                    ffmpegPath: "/tmp/ffmpeg"
                )
            }
        }
        for configuration in queuedConfigurations {
            let isQueued = await waitUntilAsync {
                await coordinator.state(for: configuration) == .queued
            }
            XCTAssertTrue(isQueued)
        }

        let shutdown = Task {
            await coordinator.shutdownAndWait()
            shutdownFinished.set()
        }
        let queuedJobsCancelled = await waitUntilAsync {
            for configuration in queuedConfigurations {
                if await coordinator.state(for: configuration) != .cancelled {
                    return false
                }
            }
            return true
        }
        XCTAssertTrue(queuedJobsCancelled)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(shutdownFinished.value)
        XCTAssertEqual(startOrder.values, ["shutdown-active"])

        releaseActive.signal()
        await shutdown.value
        _ = await active.result
        for task in queued {
            guard case .failure(let error) = await task.result else {
                return XCTFail("Expected queued render to be cancelled during shutdown.")
            }
            XCTAssertEqual(error as? SceneRenderCoordinatorError, .cancelled)
        }
        XCTAssertTrue(shutdownFinished.value)
        XCTAssertEqual(startOrder.values, ["shutdown-active"])
    }

    func testDifferentDisplayJobsShareConvergedLowQualityFallback() async throws {
        let primaryCounter = LockedCounter()
        let fallbackCounter = LockedCounter()
        let processScopes = LockedStringSet()
        let output = URL(filePath: "/tmp/scene-coordinator-low-fallback.mp4")
        let expected = SceneVideoRenderOutcome(
            cacheURL: output,
            audioResult: .degraded("Authored Scene audio is unavailable in the fallback cache.")
        )
        let coordinator = SceneRenderCoordinator { configuration, _, _ in
            processScopes.insert(configuration.processScopeID)
            if configuration.quality == .low {
                fallbackCounter.increment()
                Thread.sleep(forTimeInterval: 0.02)
                return expected
            }
            primaryCounter.increment()
            // Ensure both parent demands are registered, then make the first
            // fallback finish before the second primary fails. Without
            // demand-scoped result retention this deterministically executes
            // the same low-quality cache job twice.
            let rendezvousDeadline = Date().addingTimeInterval(1)
            while primaryCounter.value < 2, Date() < rendezvousDeadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            if configuration.size.width > 2_000 {
                Thread.sleep(forTimeInterval: 0.10)
            }
            throw SceneRenderCoordinatorTestError.primaryRenderFailed
        }
        let firstConfiguration = makeBalancedConfiguration(
            assetID: "shared-fallback",
            size: CGSize(width: 1920, height: 1080)
        )
        let secondConfiguration = makeBalancedConfiguration(
            assetID: "shared-fallback",
            size: CGSize(width: 2560, height: 1440)
        )
        XCTAssertEqual(
            firstConfiguration.lowQualityFallback.cacheKey,
            secondConfiguration.lowQualityFallback.cacheKey
        )

        async let first = coordinator.render(
            configuration: firstConfiguration,
            ffmpegPath: "/tmp/ffmpeg"
        )
        async let second = coordinator.render(
            configuration: secondConfiguration,
            ffmpegPath: "/tmp/ffmpeg"
        )
        let values = try await [first, second]
        let firstState = await coordinator.state(for: firstConfiguration)
        let secondState = await coordinator.state(for: secondConfiguration)

        XCTAssertEqual(values, [expected, expected])
        XCTAssertEqual(primaryCounter.value, 2)
        XCTAssertEqual(fallbackCounter.value, 1)
        XCTAssertEqual(
            processScopes.values,
            Set([
                firstConfiguration.cacheKey!.fileName,
                secondConfiguration.cacheKey!.fileName,
                firstConfiguration.lowQualityFallback.cacheKey!.fileName
            ])
        )
        XCTAssertEqual(firstState, .completed(output))
        XCTAssertEqual(secondState, .completed(output))
    }

    func testMetadataVerifierSharesOneHashAcrossDisplays() async {
        let counter = LockedCounter()
        let verifier = SceneVideoCacheMetadataVerifier { _ in
            counter.increment()
            Thread.sleep(forTimeInterval: 0.05)
            return nil
        }
        let generationURL = URL(filePath: "/tmp/scene-g0123456789abcdef-generation.mp4")

        async let first = verifier.metadata(for: generationURL)
        async let second = verifier.metadata(for: generationURL)
        async let third = verifier.metadata(for: generationURL)
        let values = await [first, second, third]

        XCTAssertTrue(values.allSatisfy { $0 == nil })
        XCTAssertEqual(counter.value, 1)
    }

    func testTimeoutCancelsRenderAndUsesStableDiagnosticCode() async {
        let coordinator = SceneRenderCoordinator { _, _, _ in
            while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
            throw CancellationError()
        }
        let configuration = makeConfiguration(assetID: "timeout")

        do {
            _ = try await coordinator.render(
                configuration: configuration,
                ffmpegPath: "/tmp/ffmpeg",
                timeout: .milliseconds(20)
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? SceneRenderCoordinatorError, .timedOut)
            guard case .failed(let code, _) = await coordinator.state(for: configuration) else {
                return XCTFail("Expected failed state")
            }
            XCTAssertEqual(code, "scene_render_timeout")
        }
    }

    func testBalancedTimeoutRetriesOnceAtLowQuality() async throws {
        let invocations = LockedStringArray()
        let expected = SceneVideoRenderOutcome(
            cacheURL: URL(filePath: "/tmp/scene-timeout-low-quality.mp4"),
            audioResult: .notRequired
        )
        let coordinator = SceneRenderCoordinator { configuration, _, _ in
            invocations.append(configuration.quality.rawValue)
            if configuration.quality == .low {
                return expected
            }
            while !Task.isCancelled {
                Thread.sleep(forTimeInterval: 0.001)
            }
            throw CancellationError()
        }
        let configuration = makeBalancedConfiguration(
            assetID: "timeout-low-retry",
            size: CGSize(width: 1_920, height: 1_080)
        )

        let outcome = try await coordinator.render(
            configuration: configuration,
            ffmpegPath: "/tmp/ffmpeg",
            timeout: .milliseconds(20)
        )

        XCTAssertEqual(outcome, expected)
        XCTAssertEqual(invocations.values, [RenderQuality.balanced.rawValue, RenderQuality.low.rawValue])
        let finalState = await coordinator.state(for: configuration)
        XCTAssertEqual(finalState, .completed(expected.cacheURL))
    }

    func testAllDeduplicatedWaitersReceiveStableTimeoutError() async {
        let coordinator = SceneRenderCoordinator { _, _, progress in
            while !Task.isCancelled {
                progress?(0.25)
                Thread.sleep(forTimeInterval: 0.002)
            }
            // Exercise the late-progress race after timeout has already
            // written its terminal state.
            progress?(0.9)
            throw CancellationError()
        }
        let configuration = makeConfiguration(assetID: "shared-timeout")

        let first = Task { () -> SceneRenderCoordinatorError? in
            do {
                _ = try await coordinator.render(
                    configuration: configuration,
                    ffmpegPath: "/tmp/ffmpeg",
                    timeout: .milliseconds(20)
                )
                return nil
            } catch {
                return error as? SceneRenderCoordinatorError
            }
        }
        let second = Task { () -> SceneRenderCoordinatorError? in
            do {
                _ = try await coordinator.render(
                    configuration: configuration,
                    ffmpegPath: "/tmp/ffmpeg",
                    timeout: .milliseconds(20)
                )
                return nil
            } catch {
                return error as? SceneRenderCoordinatorError
            }
        }
        let results = await [first.value, second.value]

        for error in results {
            XCTAssertEqual(error, .timedOut)
        }
        guard case .failed(let code, _) = await coordinator.state(for: configuration) else {
            return XCTFail("Expected timeout state to remain terminal")
        }
        XCTAssertEqual(code, "scene_render_timeout")
    }

    func testExplicitCancellationStopsOnlyMatchingAsset() async {
        let coordinator = SceneRenderCoordinator { _, _, _ in
            while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
            throw CancellationError()
        }
        let configuration = makeConfiguration(assetID: "cancel-me")
        let task = Task {
            try await coordinator.render(configuration: configuration, ffmpegPath: "/tmp/ffmpeg")
        }
        try? await Task.sleep(for: .milliseconds(20))

        await coordinator.cancel(assetID: "cancel-me")

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? SceneRenderCoordinatorError, .cancelled)
            let state = await coordinator.state(for: configuration)
            XCTAssertEqual(state, .cancelled)
        }
    }

    func testCancellingSoleWaiterStopsUnderlyingRender() async {
        let started = DispatchSemaphore(value: 0)
        let observedCancellation = LockedFlag()
        let coordinator = SceneRenderCoordinator { _, _, _ in
            started.signal()
            while !Task.isCancelled {
                Thread.sleep(forTimeInterval: 0.001)
            }
            observedCancellation.set()
            throw CancellationError()
        }
        let configuration = makeConfiguration(assetID: "cancel-sole-waiter")
        let lifecycleScope = coordinator.makeRenderScope()
        let waiter = Task { () -> SceneRenderCoordinatorError? in
            do {
                _ = try await coordinator.render(
                    configuration: configuration,
                    ffmpegPath: "/tmp/ffmpeg",
                    lifecycleScope: lifecycleScope
                )
                return nil
            } catch {
                return error as? SceneRenderCoordinatorError
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)

        waiter.cancel()

        let waiterError = await waiter.value
        let finalState = await coordinator.state(for: configuration)
        let activeScopes = await coordinator.activeLifecycleScopes(for: configuration)
        XCTAssertEqual(waiterError, .cancelled)
        XCTAssertTrue(waitUntil { observedCancellation.value })
        XCTAssertEqual(finalState, .cancelled)
        XCTAssertTrue(activeScopes.isEmpty)
    }

    func testCancellingOneSharedWaiterPreservesUnderlyingRenderForSurvivor() async throws {
        let started = DispatchSemaphore(value: 0)
        let releaseRender = LockedFlag()
        let observedCancellation = LockedFlag()
        let invocationCount = LockedCounter()
        let expected = SceneVideoRenderOutcome(
            cacheURL: URL(filePath: "/tmp/scene-shared-waiter-survivor.mp4"),
            audioResult: .notRequired
        )
        let coordinator = SceneRenderCoordinator { _, _, _ in
            invocationCount.increment()
            started.signal()
            while !releaseRender.value {
                if Task.isCancelled {
                    observedCancellation.set()
                    throw CancellationError()
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return expected
        }
        let configuration = makeConfiguration(assetID: "cancel-shared-waiter")
        let cancelledScope = coordinator.makeRenderScope()
        let survivorScope = coordinator.makeRenderScope()
        let cancelledWaiter = Task { () -> SceneRenderCoordinatorError? in
            do {
                _ = try await coordinator.render(
                    configuration: configuration,
                    ffmpegPath: "/tmp/ffmpeg",
                    lifecycleScope: cancelledScope
                )
                return nil
            } catch {
                return error as? SceneRenderCoordinatorError
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        let survivor = Task {
            try await coordinator.render(
                configuration: configuration,
                ffmpegPath: "/tmp/ffmpeg",
                lifecycleScope: survivorScope
            )
        }
        let bothWaitersRegistered = await waitUntilAsync {
            await coordinator.activeLifecycleScopes(for: configuration)
                == Set([cancelledScope, survivorScope])
        }
        XCTAssertTrue(bothWaitersRegistered)

        cancelledWaiter.cancel()

        let cancelledWaiterError = await cancelledWaiter.value
        XCTAssertEqual(cancelledWaiterError, .cancelled)
        let survivorRemains = await waitUntilAsync {
            await coordinator.activeLifecycleScopes(for: configuration) == Set([survivorScope])
        }
        XCTAssertTrue(survivorRemains)
        XCTAssertFalse(observedCancellation.value)
        releaseRender.set()

        let survivorValue = try await survivor.value
        XCTAssertEqual(survivorValue, expected)
        XCTAssertEqual(invocationCount.value, 1)
        XCTAssertFalse(observedCancellation.value)
    }

    func testShutdownRejectsNewRendersAndWaitsForRetiredTaskToUnwind() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let operationCount = LockedCounter()
        let operationFinished = LockedFlag()
        let shutdownFinished = LockedFlag()
        let output = SceneVideoRenderOutcome(
            cacheURL: URL(filePath: "/tmp/scene-shutdown-drain.mp4"),
            audioResult: .notRequired
        )
        let coordinator = SceneRenderCoordinator { _, _, _ in
            operationCount.increment()
            started.signal()
            release.wait()
            operationFinished.set()
            return output
        }
        let configuration = makeConfiguration(assetID: "shutdown-drain")
        let renderTask = Task {
            try? await coordinator.render(
                configuration: configuration,
                ffmpegPath: "/tmp/ffmpeg"
            )
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)

        // Scoped cancellation retires the keyed job immediately. The final
        // shutdown must still discover its uncooperative underlying task.
        let scopedCancellation = Task { await coordinator.cancelAll() }
        for _ in 0..<100 {
            if await coordinator.state(for: configuration) == .cancelled { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let cancelledState = await coordinator.state(for: configuration)
        XCTAssertEqual(cancelledState, .cancelled)

        coordinator.beginShutdown()
        let shutdown = Task {
            await coordinator.shutdownAndWait()
            shutdownFinished.set()
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(shutdownFinished.value)

        do {
            _ = try await coordinator.render(
                configuration: makeConfiguration(assetID: "late-render"),
                ffmpegPath: "/tmp/ffmpeg"
            )
            XCTFail("Expected the shutdown admission gate to reject new work")
        } catch {
            XCTAssertEqual(error as? SceneRenderCoordinatorError, .cancelled)
        }
        XCTAssertEqual(operationCount.value, 1)

        release.signal()
        await shutdown.value
        await scopedCancellation.value
        _ = await renderTask.value
        XCTAssertTrue(operationFinished.value)
        XCTAssertTrue(shutdownFinished.value)
    }

    func testLifecycleCheckpointPreservesSharedJobOwnedByNewerWaiter() async throws {
        let invocationCount = LockedCounter()
        let releaseRender = LockedFlag()
        let observedCancellation = LockedFlag()
        let output = SceneVideoRenderOutcome(
            cacheURL: URL(filePath: "/tmp/scene-lifecycle-shared.mp4"),
            audioResult: .notRequired
        )
        let coordinator = SceneRenderCoordinator { _, _, _ in
            invocationCount.increment()
            while !releaseRender.value {
                if Task.isCancelled {
                    observedCancellation.set()
                    throw CancellationError()
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return output
        }
        let configuration = makeConfiguration(assetID: "lifecycle-shared")
        let oldScope = coordinator.makeRenderScope()
        let oldTask = Task {
            try await coordinator.render(
                configuration: configuration,
                ffmpegPath: "/tmp/ffmpeg",
                lifecycleScope: oldScope
            )
        }
        XCTAssertTrue(waitUntil { invocationCount.value == 1 })
        let checkpoint = coordinator.cancellationCheckpoint()

        let newScope = coordinator.makeRenderScope()
        let newTask = Task {
            try await coordinator.render(
                configuration: configuration,
                ffmpegPath: "/tmp/ffmpeg",
                lifecycleScope: newScope
            )
        }
        let joinedDeadline = Date().addingTimeInterval(1)
        while (await coordinator.activeLifecycleScopes(for: configuration)).count < 2,
              Date() < joinedDeadline {
            await Task.yield()
        }
        let activeScopes = await coordinator.activeLifecycleScopes(for: configuration)
        XCTAssertEqual(activeScopes, Set([oldScope, newScope]))

        await coordinator.cancelAll(upTo: checkpoint)
        releaseRender.set()

        do {
            _ = try await oldTask.value
            XCTFail("The waiter owned by the cancelled lifecycle should stop.")
        } catch {
            XCTAssertEqual(error as? SceneRenderCoordinatorError, .cancelled)
        }
        let newValue = try await newTask.value
        XCTAssertEqual(newValue, output)
        XCTAssertEqual(invocationCount.value, 1)
        XCTAssertFalse(observedCancellation.value)
    }

    func testRenderTaskStartingAfterItsLifecycleCheckpointWasCancelledNeverLaunches() async {
        let invocationCount = LockedCounter()
        let coordinator = SceneRenderCoordinator { _, _, _ in
            invocationCount.increment()
            return SceneVideoRenderOutcome(
                cacheURL: URL(filePath: "/tmp/scene-stale-lifecycle.mp4"),
                audioResult: .notRequired
            )
        }
        let configuration = makeConfiguration(assetID: "stale-lifecycle")
        let staleScope = coordinator.makeRenderScope()
        let checkpoint = coordinator.cancellationCheckpoint()

        await coordinator.cancelAll(upTo: checkpoint)

        do {
            _ = try await coordinator.render(
                configuration: configuration,
                ffmpegPath: "/tmp/ffmpeg",
                lifecycleScope: staleScope
            )
            XCTFail("A delayed render from the cancelled lifecycle must not launch.")
        } catch {
            XCTAssertEqual(error as? SceneRenderCoordinatorError, .cancelled)
        }
        XCTAssertEqual(invocationCount.value, 0)
    }

    func testDelayedLifecycleCancellationCannotCancelReplacementJob() async throws {
        let invocationCount = LockedCounter()
        let oldRenderObservedCancellation = LockedFlag()
        let allowOldRenderToExit = LockedFlag()
        let allowReplacementToFinish = LockedFlag()
        let replacementObservedCancellation = LockedFlag()
        let output = SceneVideoRenderOutcome(
            cacheURL: URL(filePath: "/tmp/scene-lifecycle-replacement.mp4"),
            audioResult: .notRequired
        )
        let coordinator = SceneRenderCoordinator { _, _, _ in
            let invocation = invocationCount.incrementAndReturn()
            if invocation == 1 {
                while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
                oldRenderObservedCancellation.set()
                while !allowOldRenderToExit.value { Thread.sleep(forTimeInterval: 0.001) }
                throw CancellationError()
            }
            while !allowReplacementToFinish.value {
                if Task.isCancelled {
                    replacementObservedCancellation.set()
                    throw CancellationError()
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return output
        }
        let configuration = makeConfiguration(assetID: "lifecycle-replacement")
        let oldScope = coordinator.makeRenderScope()
        let oldTask = Task {
            try await coordinator.render(
                configuration: configuration,
                ffmpegPath: "/tmp/ffmpeg",
                lifecycleScope: oldScope
            )
        }
        XCTAssertTrue(waitUntil { invocationCount.value == 1 })
        let checkpoint = coordinator.cancellationCheckpoint()

        let cancellationTask = Task {
            await coordinator.cancelAll(upTo: checkpoint)
        }
        XCTAssertTrue(waitUntil { oldRenderObservedCancellation.value })

        let replacementScope = coordinator.makeRenderScope()
        let replacementTask = Task {
            try await coordinator.render(
                configuration: configuration,
                ffmpegPath: "/tmp/ffmpeg",
                lifecycleScope: replacementScope
            )
        }
        XCTAssertTrue(waitUntil { invocationCount.value == 2 })

        allowOldRenderToExit.set()
        await cancellationTask.value
        allowReplacementToFinish.set()

        do {
            _ = try await oldTask.value
            XCTFail("Expected the old render to be cancelled.")
        } catch {
            XCTAssertEqual(error as? SceneRenderCoordinatorError, .cancelled)
        }
        let replacementValue = try await replacementTask.value
        XCTAssertEqual(replacementValue, output)
        XCTAssertFalse(replacementObservedCancellation.value)
        let state = await coordinator.state(for: configuration)
        XCTAssertEqual(state, .completed(output.cacheURL))
    }

    func testCancelledFallbackDoesNotPoisonNewerFallbackDemand() async throws {
        let primaryInvocationCount = LockedCounter()
        let fallbackInvocationCount = LockedCounter()
        let oldFallbackObservedCancellation = LockedFlag()
        let allowOldFallbackToExit = LockedFlag()
        let allowNewPrimaryToFail = LockedFlag()
        let output = SceneVideoRenderOutcome(
            cacheURL: URL(filePath: "/tmp/scene-lifecycle-fallback.mp4"),
            audioResult: .notRequired
        )
        let coordinator = SceneRenderCoordinator { configuration, _, _ in
            if configuration.quality != .low {
                let invocation = primaryInvocationCount.incrementAndReturn()
                if invocation > 1 {
                    while !allowNewPrimaryToFail.value {
                        if Task.isCancelled { throw CancellationError() }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                }
                throw SceneRenderCoordinatorTestError.primaryRenderFailed
            }

            let invocation = fallbackInvocationCount.incrementAndReturn()
            if invocation == 1 {
                while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
                oldFallbackObservedCancellation.set()
                while !allowOldFallbackToExit.value { Thread.sleep(forTimeInterval: 0.001) }
                throw CancellationError()
            }
            return output
        }
        let configuration = makeBalancedConfiguration(
            assetID: "lifecycle-fallback",
            size: CGSize(width: 1_920, height: 1_080)
        )
        let oldScope = coordinator.makeRenderScope()
        let checkpoint = coordinator.cancellationCheckpoint()
        let oldTask = Task {
            try await coordinator.render(
                configuration: configuration,
                ffmpegPath: "/tmp/ffmpeg",
                lifecycleScope: oldScope
            )
        }
        XCTAssertTrue(waitUntil { fallbackInvocationCount.value == 1 })

        let cancellationTask = Task { await coordinator.cancelAll(upTo: checkpoint) }
        XCTAssertTrue(waitUntil { oldFallbackObservedCancellation.value })

        let newScope = coordinator.makeRenderScope()
        let newTask = Task {
            try await coordinator.render(
                configuration: configuration,
                ffmpegPath: "/tmp/ffmpeg",
                lifecycleScope: newScope
            )
        }
        XCTAssertTrue(waitUntil { primaryInvocationCount.value == 2 })

        allowOldFallbackToExit.set()
        await cancellationTask.value
        do {
            _ = try await oldTask.value
            XCTFail("Expected the old fallback to be cancelled.")
        } catch {
            XCTAssertEqual(error as? SceneRenderCoordinatorError, .cancelled)
        }

        allowNewPrimaryToFail.set()
        let newValue = try await newTask.value
        XCTAssertEqual(newValue, output)
        XCTAssertEqual(fallbackInvocationCount.value, 2)
    }

    func testOlderFallbackCompletionCannotOverwriteNewerPrimaryState() async throws {
        let primaryInvocationCount = LockedCounter()
        let fallbackInvocationCount = LockedCounter()
        let allowOldFallbackToFinish = LockedFlag()
        let allowNewPrimaryToFinish = LockedFlag()
        let fallbackOutcome = SceneVideoRenderOutcome(
            cacheURL: URL(filePath: "/tmp/scene-older-fallback.mp4"),
            audioResult: .notRequired
        )
        let primaryOutcome = SceneVideoRenderOutcome(
            cacheURL: URL(filePath: "/tmp/scene-newer-primary.mp4"),
            audioResult: .notRequired
        )
        let coordinator = SceneRenderCoordinator { configuration, _, _ in
            if configuration.quality == .low {
                fallbackInvocationCount.increment()
                while !allowOldFallbackToFinish.value {
                    if Task.isCancelled { throw CancellationError() }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return fallbackOutcome
            }

            let invocation = primaryInvocationCount.incrementAndReturn()
            if invocation == 1 {
                throw SceneRenderCoordinatorTestError.primaryRenderFailed
            }
            while !allowNewPrimaryToFinish.value {
                if Task.isCancelled { throw CancellationError() }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return primaryOutcome
        }
        let configuration = makeBalancedConfiguration(
            assetID: "fallback-state-generation",
            size: CGSize(width: 1_920, height: 1_080)
        )
        let oldScope = coordinator.makeRenderScope()
        let oldTask = Task {
            try await coordinator.render(
                configuration: configuration,
                ffmpegPath: "/tmp/ffmpeg",
                lifecycleScope: oldScope
            )
        }
        XCTAssertTrue(waitUntil { fallbackInvocationCount.value == 1 })

        let newScope = coordinator.makeRenderScope()
        let newTask = Task {
            try await coordinator.render(
                configuration: configuration,
                ffmpegPath: "/tmp/ffmpeg",
                lifecycleScope: newScope
            )
        }
        XCTAssertTrue(waitUntil { primaryInvocationCount.value == 2 })

        allowOldFallbackToFinish.set()
        let oldValue = try await oldTask.value
        XCTAssertEqual(oldValue, fallbackOutcome)
        let stateWhileNewerPrimaryRuns = await coordinator.state(for: configuration)
        if case .running = stateWhileNewerPrimaryRuns {
            // Expected: the older fallback cannot publish over this state.
        } else {
            XCTFail("The newer primary job must retain ownership of its running state.")
        }

        allowNewPrimaryToFinish.set()
        let newValue = try await newTask.value
        XCTAssertEqual(newValue, primaryOutcome)
        let finalState = await coordinator.state(for: configuration)
        XCTAssertEqual(finalState, .completed(primaryOutcome.cacheURL))
    }

    func testNativeReadinessDeduplicatesFullDecodeByContentKey() async {
        let counter = LockedCounter()
        let coordinator = SceneNativeReadinessCoordinator { _ in
            counter.increment()
            Thread.sleep(forTimeInterval: 0.05)
            return nil
        }
        let url = URL(filePath: "/tmp/shared-scene.pkg")

        async let first = coordinator.renderablePlan(for: url, cacheKey: "same-content")
        async let second = coordinator.renderablePlan(for: url, cacheKey: "same-content")
        async let third = coordinator.renderablePlan(for: url, cacheKey: "same-content")
        _ = await [first, second, third]

        XCTAssertEqual(counter.value, 1)
    }

    func testNativeReadinessLimitsConcurrentFullDecodes() async {
        let concurrency = LockedConcurrencyCounter()
        let coordinator = SceneNativeReadinessCoordinator(maximumConcurrentBuilds: 2) { _ in
            concurrency.begin()
            Thread.sleep(forTimeInterval: 0.04)
            concurrency.end()
            return nil
        }

        await withTaskGroup(of: SceneRenderPlan?.self) { group in
            for index in 0..<8 {
                group.addTask {
                    await coordinator.renderablePlan(
                        for: URL(filePath: "/tmp/scene-\(index).pkg"),
                        cacheKey: "content-\(index)"
                    )
                }
            }
            for await _ in group {}
        }

        XCTAssertEqual(concurrency.completed, 8)
        XCTAssertLessThanOrEqual(concurrency.maximumActive, 2)
    }

    func testNativeReadinessCancellationDropsQueuedDecodeBeforePermit() async {
        let invocationCount = LockedCounter()
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let coordinator = SceneNativeReadinessCoordinator(maximumConcurrentBuilds: 1) { _ in
            let invocation = invocationCount.incrementAndReturn()
            if invocation == 1 {
                firstStarted.signal()
                _ = releaseFirst.wait(timeout: .now() + 2)
            }
            return nil
        }

        let first = Task {
            await coordinator.renderablePlan(
                for: URL(filePath: "/tmp/active-scene.pkg"),
                cacheKey: "active-content"
            )
        }
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 1), .success)

        let queued = Task {
            await coordinator.renderablePlan(
                for: URL(filePath: "/tmp/cancelled-scene.pkg"),
                cacheKey: "cancelled-content"
            )
        }
        let queuedWaiterRegistered = await waitUntilAsync {
            await coordinator.waiterCount(for: "cancelled-content") == 1
        }
        XCTAssertTrue(queuedWaiterRegistered)

        queued.cancel()
        let queuedWaiterRemoved = await waitUntilAsync {
            await coordinator.waiterCount(for: "cancelled-content") == 0
        }
        XCTAssertTrue(queuedWaiterRemoved)
        releaseFirst.signal()

        _ = await first.value
        _ = await queued.value
        XCTAssertEqual(invocationCount.value, 1)
    }

    func testNativeReadinessCancellationPreservesAnotherWaiterForSameDecode() async {
        let invocationCount = LockedCounter()
        let buildStarted = DispatchSemaphore(value: 0)
        let releaseBuild = DispatchSemaphore(value: 0)
        let coordinator = SceneNativeReadinessCoordinator { _ in
            invocationCount.increment()
            buildStarted.signal()
            _ = releaseBuild.wait(timeout: .now() + 2)
            return nil
        }
        let url = URL(filePath: "/tmp/shared-native-scene.pkg")

        let viewWaiter = Task {
            await coordinator.renderablePlan(for: url, cacheKey: "shared-native-content")
        }
        XCTAssertEqual(buildStarted.wait(timeout: .now() + 1), .success)
        let classifierWaiter = Task {
            await coordinator.renderablePlan(for: url, cacheKey: "shared-native-content")
        }
        let bothWaitersRegistered = await waitUntilAsync {
            await coordinator.waiterCount(for: "shared-native-content") == 2
        }
        XCTAssertTrue(bothWaitersRegistered)

        viewWaiter.cancel()
        let classifierStillRegistered = await waitUntilAsync {
            await coordinator.waiterCount(for: "shared-native-content") == 1
        }
        XCTAssertTrue(classifierStillRegistered)
        releaseBuild.signal()

        _ = await viewWaiter.value
        _ = await classifierWaiter.value
        let remainingWaiters = await coordinator.waiterCount(for: "shared-native-content")
        XCTAssertEqual(invocationCount.value, 1)
        XCTAssertEqual(remainingWaiters, 0)
    }

    private func makeConfiguration(assetID: String) -> SceneVideoRenderConfiguration {
        SceneVideoRenderConfiguration(
            assetId: assetID,
            projectDirectory: URL(filePath: "/tmp/project"),
            assetsDirectory: URL(filePath: "/tmp/assets"),
            rendererURL: URL(filePath: "/tmp/renderer"),
            size: CGSize(width: 1280, height: 720),
            seconds: 1,
            contentHash: "0123456789abcdef",
            quality: .low,
            engineAssetsFingerprint: "assets-test"
        )
    }

    private func makeBalancedConfiguration(
        assetID: String,
        size: CGSize
    ) -> SceneVideoRenderConfiguration {
        SceneVideoRenderConfiguration(
            assetId: assetID,
            projectDirectory: URL(filePath: "/tmp/project"),
            assetsDirectory: URL(filePath: "/tmp/assets"),
            rendererURL: URL(filePath: "/tmp/renderer"),
            size: size,
            seconds: 1,
            contentHash: "0123456789abcdef",
            quality: .balanced,
            engineAssetsFingerprint: "assets-test"
        )
    }
}

private enum SceneRenderCoordinatorTestError: Error {
    case primaryRenderFailed
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    @discardableResult
    func incrementAndReturn() -> Int {
        lock.lock()
        storage += 1
        let value = storage
        lock.unlock()
        return value
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

private func waitUntil(
    timeout: TimeInterval = 1,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.001)
    }
    return condition()
}

private func waitUntilAsync(
    timeout: Duration = .seconds(1),
    condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()), clock.now < deadline {
        await Task.yield()
    }
    return await condition()
}

private final class LockedStringSet: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Set<String> = []

    var values: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func insert(_ value: String) {
        lock.lock()
        storage.insert(value)
        lock.unlock()
    }
}

private final class LockedStringArray: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class LockedConcurrencyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var activeStorage = 0
    private var completedStorage = 0
    private var maximumActiveStorage = 0

    var completed: Int {
        lock.lock()
        defer { lock.unlock() }
        return completedStorage
    }

    var maximumActive: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveStorage
    }

    func begin() {
        lock.lock()
        activeStorage += 1
        maximumActiveStorage = max(maximumActiveStorage, activeStorage)
        lock.unlock()
    }

    func end() {
        lock.lock()
        activeStorage -= 1
        completedStorage += 1
        lock.unlock()
    }
}
