import XCTest
@testable import BackgroundEngineApp

final class SettingsWindowPlacementTests: XCTestCase {
    func testSettingsWindowCentersOnMainScreenWhenCreated() {
        // Given
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let windowSize = CGSize(width: 980, height: 640)

        // When
        let frame = SettingsWindowPlacement.centeredFrame(windowSize: windowSize, screenFrame: screenFrame)

        // Then
        XCTAssertEqual(frame.origin.x, 230)
        XCTAssertEqual(frame.origin.y, 130)
        XCTAssertEqual(frame.size.width, 980)
        XCTAssertEqual(frame.size.height, 640)
    }

    func testSettingsWindowCentersUsingMinimumSizeWhenCurrentFrameIsZero() {
        // Given
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // When
        let frame = SettingsWindowPlacement.centeredFrame(
            windowSize: .zero,
            minimumWindowSize: CGSize(width: 980, height: 640),
            screenFrame: screenFrame
        )

        // Then
        XCTAssertEqual(frame.origin.x, 230)
        XCTAssertEqual(frame.origin.y, 130)
        XCTAssertEqual(frame.size.width, 980)
        XCTAssertEqual(frame.size.height, 640)
    }

    func testPreferredScreenUsesMouseLocationScreen() {
        // Given
        let left = CGRect(x: -1470, y: 0, width: 1470, height: 956)
        let right = CGRect(x: 0, y: 0, width: 1470, height: 956)

        // When
        let selected = SettingsWindowPlacement.preferredScreenFrame(
            mouseLocation: CGPoint(x: -200, y: 500),
            screenFrames: [right, left],
            fallback: right
        )

        // Then
        XCTAssertEqual(selected, left)
    }

    func testWindowRestoredOnDisconnectedDisplayMovesToMainScreen() throws {
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1040)
        let staleWindow = CGRect(x: 2390, y: 207, width: 980, height: 692)

        let recovered = try XCTUnwrap(SettingsWindowPlacement.recoveredFrame(
            windowFrame: staleWindow,
            screenFrames: [main],
            fallback: main
        ))

        XCTAssertEqual(recovered, CGRect(x: 470, y: 174, width: 980, height: 692))
    }

    func testWindowOnConnectedSecondaryDisplayKeepsItsPosition() {
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1040)
        let secondary = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let window = CGRect(x: 2390, y: 207, width: 980, height: 692)

        XCTAssertNil(SettingsWindowPlacement.recoveredFrame(
            windowFrame: window,
            screenFrames: [main, secondary],
            fallback: main
        ))
    }

    func testWindowWithReachableTitleBarIsNotMoved() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1040)
        let partlyVisible = CGRect(x: 1750, y: 300, width: 980, height: 692)

        XCTAssertNil(SettingsWindowPlacement.recoveredFrame(
            windowFrame: partlyVisible,
            screenFrames: [screen],
            fallback: screen
        ))
    }

    func testWindowBodyWithoutReachableTitleBarIsRecovered() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1040)
        let titleBarAboveScreen = CGRect(x: 200, y: 1020, width: 980, height: 692)

        XCTAssertNotNil(SettingsWindowPlacement.recoveredFrame(
            windowFrame: titleBarAboveScreen,
            screenFrames: [screen],
            fallback: screen
        ))
    }

    func testSettingsWindowDisablesAppKitWindowAnimations() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/SettingsWindowCoordinator.swift")

        // Then
        XCTAssertTrue(source.contains("window.animationBehavior = .none"))
        XCTAssertTrue(source.contains("setFrame(frame, display: true, animate: false)"))
    }

    func testDisconnectedDisplayRecoveryNeverMovesFullScreenWindows() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/BridgeApp.swift")

        XCTAssertTrue(source.contains("!window.styleMask.contains(.fullScreen)"))
    }
}
