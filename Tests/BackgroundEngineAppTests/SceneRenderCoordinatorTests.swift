import Foundation
import XCTest
@testable import BackgroundEngineApp
import BackgroundEngineCore

final class SceneRenderCoordinatorTests: XCTestCase {
    func testDuplicateRequestsShareOneRenderOperation() async throws {
        let counter = LockedCounter()
        let output = URL(filePath: "/tmp/scene-coordinator-output.mp4")
        let coordinator = SceneRenderCoordinator { _, _, progress in
            counter.increment()
            progress?(0.5)
            Thread.sleep(forTimeInterval: 0.05)
            return output
        }
        let configuration = makeConfiguration(assetID: "shared")

        async let first = coordinator.render(configuration: configuration, ffmpegPath: "/tmp/ffmpeg")
        async let second = coordinator.render(configuration: configuration, ffmpegPath: "/tmp/ffmpeg")
        let values = try await [first, second]
        let state = await coordinator.state(for: configuration)

        XCTAssertEqual(values, [output, output])
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(state, .completed(output))
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
