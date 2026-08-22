import ImageIO
import XCTest
@testable import BackgroundEngineApp
@testable import BackgroundEngineCore

final class AnimatedImageWallpaperViewTests: XCTestCase {
    func testUsesNestedUnclampedFrameDuration() {
        let properties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: NSNumber(value: 0.25)
            ] as [CFString: Any]
        ]

        XCTAssertEqual(AnimatedImageTiming.duration(from: properties), 0.25)
    }

    func testUnclampedFrameDurationTakesPriorityOverClampedDelay() {
        let properties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: NSNumber(value: 0.1),
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

    func testDecodeBudgetRejectsInvalidOrOverflowingDimensions() {
        XCTAssertNil(ImageWallpaperValidation.decodedByteCount(width: 0, height: 100))
        XCTAssertNil(ImageWallpaperValidation.decodedByteCount(width: -1, height: 100))
        XCTAssertNil(ImageWallpaperValidation.decodedByteCount(width: Int.max, height: Int.max))
        XCTAssertEqual(ImageWallpaperValidation.decodedByteCount(width: 1920, height: 1080), 33_177_600)
    }

    func testDecodeBudgetUsesActualImageStrideForHighBitDepthFrames() throws {
        let data = Data(repeating: 0, count: 16)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 2,
            height: 1,
            bitsPerComponent: 16,
            bitsPerPixel: 64,
            bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))

        XCTAssertEqual(ImageWallpaperValidation.decodedByteCount(for: image), 16)
    }
}
