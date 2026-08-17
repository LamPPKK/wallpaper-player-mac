import ImageIO
import XCTest
@testable import BackgroundEngineApp

final class AnimatedImageWallpaperViewTests: XCTestCase {
    func testUsesNestedUnclampedFrameDuration() {
        let properties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: NSNumber(value: 0.25)
            ] as [CFString: Any]
        ]

        XCTAssertEqual(AnimatedImageTiming.duration(from: properties), 0.25)
    }

    func testClampsVeryShortFrameDuration() {
        let properties: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [
                "UnclampedDelayTime" as CFString: NSNumber(value: 0.001)
            ] as [CFString: Any]
        ]

        XCTAssertEqual(
            AnimatedImageTiming.duration(from: properties),
            AnimatedImageTiming.minimumFrameDuration
        )
    }

    func testUsesDefaultForMissingFrameDuration() {
        XCTAssertEqual(
            AnimatedImageTiming.duration(from: [:]),
            AnimatedImageTiming.defaultFrameDuration
        )
    }
}
