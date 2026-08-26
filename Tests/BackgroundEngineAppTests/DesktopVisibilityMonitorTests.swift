import CoreGraphics
import XCTest
@testable import BackgroundEngineApp

final class DesktopVisibilityMonitorTests: XCTestCase {
    func testFinderDesktopHostDoesNotPausePlayback() {
        // Given
        let screenFrame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Finder",
                windowName: "Desktop",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 0, y: 33, width: 1470, height: 923)
            )
        ]

        // When
        let visible = DesktopVisibilityMonitor.isDesktopVisible(
            windows: windows,
            currentProcessId: 200,
            screenFrames: [screenFrame]
        )

        // Then
        XCTAssertTrue(visible)
    }

    func testFullscreenFinderWindowStillPausesItsDisplay() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Finder",
                windowName: "Downloads",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: screenFrame
            )
        ]

        let visibility = DesktopVisibilityMonitor.desktopVisibility(
            windows: windows,
            currentProcessId: 200,
            screenFrames: [screenFrame]
        )

        XCTAssertEqual(visibility, [false])
    }

    func testUnnamedTiledFinderWindowContributesToCoveredDisplay() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Finder",
                windowName: nil,
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 0, y: 0, width: 600, height: 800)
            ),
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Browser",
                processId: 101,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 600, y: 0, width: 600, height: 800)
            )
        ]

        let visibility = DesktopVisibilityMonitor.desktopVisibility(
            windows: windows,
            currentProcessId: 200,
            screenFrames: [screenFrame]
        )

        XCTAssertEqual(visibility, [false])
    }

    func testUnnamedFullscreenFinderWindowFailsSafeAsUserContent() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Finder",
                windowName: nil,
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: screenFrame
            )
        ]

        let visibility = DesktopVisibilityMonitor.desktopVisibility(
            windows: windows,
            currentProcessId: 200,
            screenFrames: [screenFrame]
        )

        XCTAssertEqual(visibility, [false])
    }

    func testWindowSnapshotReadsFinderWindowNameFromWindowServerMetadata() {
        let snapshot = DesktopVisibilityMonitor.WindowSnapshot([
            kCGWindowOwnerName as String: "Finder",
            kCGWindowName as String: "Downloads",
            kCGWindowOwnerPID as String: 100,
            kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1.0,
            kCGWindowBounds as String: [
                "X": 0.0,
                "Y": 0.0,
                "Width": 1470.0,
                "Height": 956.0
            ]
        ])

        XCTAssertEqual(snapshot.windowName, "Downloads")
    }

    func testStageManagerShelfDoesNotPausePlayback() {
        // Given
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "WindowManager",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 15, y: 420, width: 144, height: 149)
            )
        ]

        // When
        let visible = DesktopVisibilityMonitor.isDesktopVisible(windows: windows, currentProcessId: 200)

        // Then
        XCTAssertTrue(visible)
    }

    func testStageManagerAppThumbnailDoesNotPausePlayback() {
        // Given
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Code",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 15, y: 420, width: 127, height: 149)
            )
        ]

        // When
        let visible = DesktopVisibilityMonitor.isDesktopVisible(
            windows: windows,
            currentProcessId: 200,
            screenFrames: [CGRect(x: 0, y: 0, width: 1470, height: 956)]
        )

        // Then
        XCTAssertTrue(visible)
    }

    func testSmallCenteredUserWindowKeepsDesktopPlaybackRunning() {
        // Given
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Code",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 520, y: 320, width: 220, height: 220)
            )
        ]

        // When
        let visible = DesktopVisibilityMonitor.isDesktopVisible(
            windows: windows,
            currentProcessId: 200,
            screenFrames: [CGRect(x: 0, y: 0, width: 1470, height: 956)]
        )

        // Then
        XCTAssertTrue(visible)
    }

    func testContinuityAndHandoffSystemWindowsDoNotPausePlayback() {
        // Given
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "ContinuityCaptureAgent",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            ),
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Handoff",
                processId: 101,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
        ]

        // When
        let visible = DesktopVisibilityMonitor.isDesktopVisible(windows: windows, currentProcessId: 200)

        // Then
        XCTAssertTrue(
            visible,
            "Continuity and Handoff system windows should not pause desktop wallpaper playback."
        )
    }

    func testAdditionalContinuitySystemWindowsDoNotPausePlayback() {
        let ownerNames = [
            "AirPlayUIAgent",
            "Continuity",
            "Continuity Camera",
            "ControlCenter"
        ]

        for ownerName in ownerNames {
            let windows = [
                DesktopVisibilityMonitor.WindowSnapshot(
                    ownerName: ownerName,
                    processId: 100,
                    layer: 0,
                    alpha: 1,
                    bounds: CGRect(x: 0, y: 0, width: 390, height: 844)
                )
            ]

            let visible = DesktopVisibilityMonitor.isDesktopVisible(windows: windows, currentProcessId: 200)

            XCTAssertTrue(visible, "\(ownerName) should not pause desktop wallpaper playback.")
        }
    }

    func testUserWindowsWithContinuityLikeNamesStillPausePlayback() {
        let ownerNames = [
            "Continuity Studio",
            "Handoff Notes",
            "iPhone Hotspot Preview"
        ]

        for ownerName in ownerNames {
            let windows = [
                DesktopVisibilityMonitor.WindowSnapshot(
                    ownerName: ownerName,
                    processId: 100,
                    layer: 0,
                    alpha: 1,
                    bounds: CGRect(x: 0, y: 0, width: 900, height: 700)
                )
            ]

            let visible = DesktopVisibilityMonitor.isDesktopVisible(windows: windows, currentProcessId: 200)

            XCTAssertFalse(visible, "\(ownerName) should still pause desktop wallpaper playback.")
        }
    }

    func testLargePartialUserAppWindowKeepsDesktopPlaybackRunning() {
        // Given
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Code",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 100, y: 100, width: 900, height: 700)
            )
        ]

        // When
        let visible = DesktopVisibilityMonitor.isDesktopVisible(
            windows: windows,
            currentProcessId: 200,
            screenFrames: [CGRect(x: 0, y: 0, width: 1470, height: 956)]
        )

        // Then
        XCTAssertTrue(visible)
    }

    func testFullscreenWindowPausesOnlyItsOwnDisplay() {
        let primary = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let secondary = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Game",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: primary
            )
        ]

        let visibility = DesktopVisibilityMonitor.desktopVisibility(
            windows: windows,
            currentProcessId: 200,
            screenFrames: [primary, secondary]
        )

        XCTAssertEqual(visibility, [false, true])
    }

    func testTiledWindowsCollectivelyCoverOneDisplayWithoutDoubleCountingOverlap() {
        let primary = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let secondary = CGRect(x: -1000, y: 0, width: 1000, height: 700)
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Editor",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 0, y: 0, width: 650, height: 800)
            ),
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Browser",
                processId: 101,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 550, y: 0, width: 650, height: 800)
            )
        ]

        let visibility = DesktopVisibilityMonitor.desktopVisibility(
            windows: windows,
            currentProcessId: 200,
            screenFrames: [primary, secondary]
        )

        XCTAssertEqual(visibility, [false, true])
    }

    func testMissingWindowServerDisplayGeometryFailsOpenWithoutMixingCoordinates() {
        let primary = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Game",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: primary
            )
        ]
        let screenFrames: [CGRect?] = [primary, nil]

        let visibility = DesktopVisibilityMonitor.desktopVisibility(
            windows: windows,
            currentProcessId: 200,
            screenFrames: screenFrames
        )

        XCTAssertEqual(visibility, [false, true])
    }

    func testTranslucentFullscreenOverlayDoesNotCountAsCoveredDesktop() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Overlay",
                processId: 100,
                layer: 0,
                alpha: 0.5,
                bounds: screen
            )
        ]

        let visibility = DesktopVisibilityMonitor.desktopVisibility(
            windows: windows,
            currentProcessId: 200,
            screenFrames: [screen]
        )

        XCTAssertEqual(visibility, [true])
    }

    func testDisplaySuspensionPolicyKeepsUncoveredDisplayIndependent() {
        let autoSuspended: Set<String> = ["primary"]

        XCTAssertTrue(DisplaySuspensionPolicy.isSuspended(
            displayUUID: "primary",
            globallySuspended: false,
            autoSuspendedDisplayUUIDs: autoSuspended
        ))
        XCTAssertFalse(DisplaySuspensionPolicy.isSuspended(
            displayUUID: "secondary",
            globallySuspended: false,
            autoSuspendedDisplayUUIDs: autoSuspended
        ))
        XCTAssertTrue(DisplaySuspensionPolicy.isSuspended(
            displayUUID: "secondary",
            globallySuspended: true,
            autoSuspendedDisplayUUIDs: autoSuspended
        ))
    }

    func testDisplaySuspensionPolicyImmediatelyDropsNoLongerCoveredDisplays() {
        XCTAssertEqual(
            DisplaySuspensionPolicy.retainingCoveredDisplays(
                ["primary", "secondary"],
                coveredDisplayUUIDs: ["secondary", "tertiary"]
            ),
            ["secondary"]
        )
    }

    func testCurrentAppSettingsWindowDoesNotPausePlayback() {
        // Given
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Background Engine",
                processId: 200,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 100, y: 100, width: 980, height: 640)
            )
        ]

        // When
        let visible = DesktopVisibilityMonitor.isDesktopVisible(windows: windows, currentProcessId: 200)

        // Then
        XCTAssertTrue(visible)
    }
}
