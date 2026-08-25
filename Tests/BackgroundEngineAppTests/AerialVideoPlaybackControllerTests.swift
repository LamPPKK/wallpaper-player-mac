import Foundation
import XCTest
@testable import BackgroundEngineApp

final class AerialVideoPlaybackControllerTests: XCTestCase {
    @MainActor
    func testIndependentPauseReasonsCannotResumeClosedOrSuspendedPlayer() {
        let controller = AerialVideoPlaybackController(
            url: URL(filePath: "/tmp/nonexistent-background-engine-video.mp4"),
            audioEnabled: false,
            audioVolume: 0.5
        )

        controller.setWallpaperSuspended(true)
        XCTAssertTrue(controller.pauseReasons.contains(.wallpaperSuspended))
        controller.close()
        XCTAssertTrue(controller.pauseReasons.contains(.wallpaperSuspended))
        XCTAssertTrue(controller.pauseReasons.contains(.closed))

        controller.setWallpaperSuspended(false)
        XCTAssertFalse(controller.pauseReasons.contains(.wallpaperSuspended))
        XCTAssertTrue(controller.pauseReasons.contains(.closed))
        XCTAssertEqual(controller.player.rate, 0)
    }

    func testVideoViewUsesAerialStyleCoordinatorAndFailureFallback() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/VideoWallpaperView.swift")
        let coordinator = try String(
            repositoryFile: "Sources/BackgroundEngineApp/AerialVideoPlaybackController.swift"
        )

        XCTAssertTrue(source.contains("AerialVideoPlaybackController"))
        XCTAssertTrue(source.contains("playerLayer.isHidden = true"))
        XCTAssertTrue(coordinator.contains("\\.isReadyForDisplay"))
        XCTAssertTrue(coordinator.contains("AerialVideoPauseReasons"))
        XCTAssertTrue(coordinator.contains("AVPlayerItemPlaybackStalled"))
        XCTAssertTrue(coordinator.contains("AVPlayerLooper"))
        XCTAssertTrue(coordinator.contains("setReason(.failed, active: true)"))
    }

    @MainActor
    func testVideoViewKeepsPlayerLayerHiddenUntilAFrameIsDisplayable() {
        let view = VideoWallpaperView(
            url: URL(filePath: "/tmp/nonexistent-background-engine-video.mp4"),
            fallbackImageURL: nil,
            frame: CGRect(x: 0, y: 0, width: 320, height: 180),
            displayMode: .fill
        )
        defer { view.prepareForClose() }

        XCTAssertTrue(view.playerLayer.isHidden)
    }

    @MainActor
    func testFirstDisplayableFrameCancelsWatchdogAndReportsReadyOnce() {
        let controller = AerialVideoPlaybackController(
            url: URL(filePath: "/tmp/nonexistent-background-engine-video.mp4"),
            audioEnabled: false,
            audioVolume: 0.5,
            startupSleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )
        var readyCount = 0
        controller.onReady = { readyCount += 1 }

        controller.beginStartupWatchdog()
        XCTAssertTrue(controller.hasPendingStartupWatchdog)

        controller.markFirstFrameReady()
        controller.markFirstFrameReady()

        XCTAssertFalse(controller.hasPendingStartupWatchdog)
        XCTAssertEqual(readyCount, 1)
        controller.close()
    }

    @MainActor
    func testStartupWatchdogReportsFailureWhenNoFrameBecomesReady() async {
        let failed = expectation(description: "startup watchdog failed")
        let controller = AerialVideoPlaybackController(
            url: URL(filePath: "/tmp/nonexistent-background-engine-video.mp4"),
            audioEnabled: false,
            audioVolume: 0.5,
            startupTimeout: .zero,
            startupSleep: { _ in }
        )
        controller.onFailure = { message in
            XCTAssertTrue(message.contains("No decoded video frame"))
            failed.fulfill()
        }

        controller.beginStartupWatchdog()
        await fulfillment(of: [failed], timeout: 1)

        XCTAssertTrue(controller.pauseReasons.contains(.failed))
        XCTAssertFalse(controller.hasPendingStartupWatchdog)
        controller.close()
    }

    @MainActor
    func testCloseCancelsPendingStartupWatchdog() {
        let controller = AerialVideoPlaybackController(
            url: URL(filePath: "/tmp/nonexistent-background-engine-video.mp4"),
            audioEnabled: false,
            audioVolume: 0.5,
            startupSleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )

        controller.beginStartupWatchdog()
        XCTAssertTrue(controller.hasPendingStartupWatchdog)

        controller.close()

        XCTAssertFalse(controller.hasPendingStartupWatchdog)
        XCTAssertTrue(controller.pauseReasons.contains(.closed))
    }

    @MainActor
    func testSuspensionPausesStartupDeadlineUntilPlaybackResumes() {
        let controller = AerialVideoPlaybackController(
            url: URL(filePath: "/tmp/nonexistent-background-engine-video.mp4"),
            audioEnabled: false,
            audioVolume: 0.5,
            startupSleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )

        controller.beginStartupWatchdog()
        XCTAssertTrue(controller.hasPendingStartupWatchdog)

        controller.setWallpaperSuspended(true)
        XCTAssertFalse(controller.hasPendingStartupWatchdog)

        controller.setWallpaperSuspended(false)
        XCTAssertTrue(controller.hasPendingStartupWatchdog)

        controller.close()
        XCTAssertFalse(controller.hasPendingStartupWatchdog)
    }
}
