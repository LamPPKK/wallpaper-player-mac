import Foundation
import XCTest
@testable import BackgroundEngineApp

final class AppInstanceLockTests: XCTestCase {
    func testSecondInstanceCannotAcquireHeldLock() {
        // Given
        let lockPath = temporaryLockPath()
        let first = AppInstanceLock(lockPath: lockPath)
        let second = AppInstanceLock(lockPath: lockPath)

        // Then
        XCTAssertTrue(first.acquire())
        XCTAssertFalse(second.acquire())
    }

    func testLockCanBeAcquiredAfterFirstInstanceReleasesIt() {
        // Given
        let lockPath = temporaryLockPath()
        var first: AppInstanceLock? = AppInstanceLock(lockPath: lockPath)

        // When
        XCTAssertTrue(first?.acquire() ?? false)
        first = nil
        let second = AppInstanceLock(lockPath: lockPath)

        // Then
        XCTAssertTrue(second.acquire())
    }

    func testOpenFailureDoesNotAcquireLock() {
        // Given
        let lock = AppInstanceLock(lockPath: NSTemporaryDirectory())

        // Then
        XCTAssertFalse(lock.acquire())
    }

    func testNormalQuitGatesSessionsAndDrainsEveryRuntimeBeforeReplying() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/BridgeApp.swift")
        let start = try XCTUnwrap(source.range(of: "func applicationShouldTerminate("))
        let end = try XCTUnwrap(
            source.range(of: "func applicationWillTerminate(", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])
        let webGate = try XCTUnwrap(body.range(of: "WebMediaRuntimeCoordinator.shared.beginShutdown()"))
        let sceneGate = try XCTUnwrap(body.range(of: "SceneRenderCoordinator.shared.beginShutdown()"))
        let sessionQuiescence = try XCTUnwrap(
            body.range(of: "WallpaperPlayer.shared.beginApplicationTermination()")
        )
        let taskStart = try XCTUnwrap(body.range(of: "terminationDrainTask = Task"))
        let drain = try XCTUnwrap(body.range(of: "await ApplicationModel.shared.cancelAndWaitForApplicationJobs()"))
        let runtimeSnapshot = try XCTUnwrap(
            body.range(of: "async let webRuntimeDrain")
        )
        let webDrain = try XCTUnwrap(body.range(of: "await webRuntimeDrain"))
        let sceneDrain = try XCTUnwrap(body.range(of: "await sceneRuntimeDrain"))
        let sceneCancel = try XCTUnwrap(body.range(of: "SceneVideoRenderer.cancelAllActiveProcesses()"))
        let reply = try XCTUnwrap(body.range(of: "sender.reply(toApplicationShouldTerminate: true)"))

        XCTAssertTrue(body.contains("return .terminateLater"))
        XCTAssertLessThan(webGate.lowerBound, taskStart.lowerBound)
        XCTAssertLessThan(sceneGate.lowerBound, taskStart.lowerBound)
        XCTAssertLessThan(sessionQuiescence.lowerBound, taskStart.lowerBound)
        XCTAssertLessThan(drain.lowerBound, runtimeSnapshot.lowerBound)
        XCTAssertLessThan(drain.lowerBound, webDrain.lowerBound)
        XCTAssertLessThan(webDrain.lowerBound, sceneDrain.lowerBound)
        XCTAssertLessThan(drain.lowerBound, sceneCancel.lowerBound)
        XCTAssertLessThan(sceneDrain.lowerBound, sceneCancel.lowerBound)
        XCTAssertLessThan(sceneCancel.lowerBound, reply.lowerBound)

        let playerSource = try String(
            repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift"
        )
        let quiescenceStart = try XCTUnwrap(
            playerSource.range(of: "func beginApplicationTermination()")
        )
        let quiescenceEnd = try XCTUnwrap(
            playerSource.range(
                of: "private func quiescePlaybackSessions()",
                range: quiescenceStart.lowerBound..<playerSource.endIndex
            )
        )
        let gateBody = String(
            playerSource[quiescenceStart.lowerBound..<quiescenceEnd.lowerBound]
        )
        XCTAssertTrue(gateBody.contains("isApplicationTerminating = true"))
        XCTAssertTrue(gateBody.contains("videoRuntimeFailureHandler = nil"))
        XCTAssertTrue(gateBody.contains("quiescePlaybackSessions()"))
        XCTAssertFalse(gateBody.contains("Task {"))

        let closeStart = quiescenceEnd
        let closeEnd = try XCTUnwrap(
            playerSource.range(
                of: "private func closeWindows()",
                range: closeStart.lowerBound..<playerSource.endIndex
            )
        )
        let closeBody = String(playerSource[closeStart.lowerBound..<closeEnd.lowerBound])
        XCTAssertTrue(closeBody.contains("stopVisibilityTimer()"))
        XCTAssertTrue(closeBody.contains("stopLifecycleObservers()"))
        XCTAssertTrue(closeBody.contains("closeWindows()"))
    }

    private func temporaryLockPath() -> String {
        let filename = "wwb-\(UUID().uuidString).lock"
        return URL(filePath: NSTemporaryDirectory())
            .appending(path: filename)
            .path
    }
}
