import XCTest

final class BackgroundEngineUITests: XCTestCase {
    func testMainNavigationIsAvailable() {
        let app = XCUIApplication()
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        for destination in ["library", "downloads", "displays", "settings"] {
            let element = app.descendants(matching: .any)["sidebar.\(destination)"]
            XCTAssertTrue(
                element.waitForExistence(timeout: 2),
                "Missing sidebar destination: \(destination)"
            )
        }
    }
}
