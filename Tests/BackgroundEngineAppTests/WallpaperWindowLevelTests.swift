import AppKit
import XCTest
@testable import BackgroundEngineApp

final class WallpaperWindowLevelTests: XCTestCase {
    func testWallpaperWindowLevelSitsAboveSystemWallpaperAndBelowDesktopIcons() {
        // Given
        let level = WallpaperWindowLevel.desktopWallpaper.rawValue
        let systemWallpaperLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))

        // Then
        XCTAssertGreaterThan(level, systemWallpaperLevel)
        XCTAssertLessThan(level, desktopIconLevel)
    }
}
