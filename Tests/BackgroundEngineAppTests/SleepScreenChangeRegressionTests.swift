import XCTest
@testable import BackgroundEngineApp

final class SleepScreenChangeRegressionTests: XCTestCase {
    func testScreenParameterReconciliationIsAllowedOnlyWhileAwakeAndRunning() {
        XCTAssertTrue(WallpaperLifecyclePolicy.shouldReconcileScreenParameters(
            isSystemSleeping: false,
            isApplicationTerminating: false
        ))
        XCTAssertFalse(WallpaperLifecyclePolicy.shouldReconcileScreenParameters(
            isSystemSleeping: true,
            isApplicationTerminating: false
        ))
        XCTAssertFalse(WallpaperLifecyclePolicy.shouldReconcileScreenParameters(
            isSystemSleeping: false,
            isApplicationTerminating: true
        ))
        XCTAssertFalse(WallpaperLifecyclePolicy.shouldReconcileScreenParameters(
            isSystemSleeping: true,
            isApplicationTerminating: true
        ))
    }

    func testScreenParameterNotificationReconcilesSynchronouslyOnMainActor() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(
            source.range(of: "forName: NSApplication.didChangeScreenParametersNotification")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "forName: Notification.Name.NSProcessInfoPowerStateDidChange",
                range: start.lowerBound..<source.endIndex
            )
        )
        let observer = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(observer.contains(
            "MainActor.assumeIsolated { self?.reopenAfterScreenFrameChange() }"
        ))
        XCTAssertFalse(observer.contains("Task { @MainActor"))
    }

    func testScreenParameterReopenUsesSleepAndTerminationGate() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "private func reopenAfterScreenFrameChange()"))
        let end = try XCTUnwrap(
            source.range(of: "private func reassertWallpaperWindowOrder()", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("WallpaperLifecyclePolicy.shouldReconcileScreenParameters("))
        XCTAssertTrue(body.contains("isSystemSleeping: isSystemSleeping"))
        XCTAssertTrue(body.contains("isApplicationTerminating: isApplicationTerminating"))
    }
}
