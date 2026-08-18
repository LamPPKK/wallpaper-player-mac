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
        XCTAssertTrue(coordinator.contains("AerialVideoPauseReasons"))
        XCTAssertTrue(coordinator.contains("AVPlayerItemPlaybackStalled"))
        XCTAssertTrue(coordinator.contains("AVPlayerLooper"))
        XCTAssertTrue(coordinator.contains("setReason(.failed, active: true)"))
    }
}
