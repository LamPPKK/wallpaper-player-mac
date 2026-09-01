import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import BackgroundEngineApp
@testable import BackgroundEngineCore

final class AnimatedImageWallpaperViewTests: XCTestCase {
    @MainActor
    func testDecodesAndCreatesPlaybackViewForSyntheticAPNG() throws {
        let url = try writeFixture(
            base64: Self.twoFrameAPNG,
            extension: "apng"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(ImageWallpaperValidation.isPlayableImage(at: url))
        XCTAssertEqual(ImageWallpaperValidation.animatedFrameCount(at: url), 2)
        let view = try AnimatedImageWallpaperView(
            url: url,
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            displayMode: .fill
        )
        XCTAssertNotNil(view.layer?.contents)
        view.setPlaybackSuspended(true)
        view.prepareForClose()
    }

    @MainActor
    func testDecodesAndCreatesPlaybackViewForSyntheticAnimatedWebP() throws {
        let url = try writeFixture(
            base64: Self.twoFrameAnimatedWebP,
            extension: "webp"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(ImageWallpaperValidation.isPlayableImage(at: url))
        XCTAssertEqual(ImageWallpaperValidation.animatedFrameCount(at: url), 2)
        let view = try AnimatedImageWallpaperView(
            url: url,
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            displayMode: .fit
        )
        XCTAssertNotNil(view.layer?.contents)
        view.setPlaybackSuspended(true)
        view.prepareForClose()
    }

    @MainActor
    func testAnimatedGIFAdvancesToTheSecondFrame() throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "background-engine-animated-image-\(UUID().uuidString).gif"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTwoFrameGIF(to: url)

        XCTAssertTrue(ImageWallpaperValidation.isPlayableImage(at: url))
        XCTAssertEqual(ImageWallpaperValidation.animatedFrameCount(at: url), 2)
        let view = try AnimatedImageWallpaperView(
            url: url,
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            displayMode: .stretch
        )
        defer { view.prepareForClose() }
        let firstFramePixel = try centerPixel(of: XCTUnwrap(view.layer))

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.22))

        let secondFramePixel = try centerPixel(of: XCTUnwrap(view.layer))
        XCTAssertGreaterThan(firstFramePixel.red, firstFramePixel.blue)
        XCTAssertGreaterThan(secondFramePixel.blue, secondFramePixel.red)
    }

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

    private func writeFixture(base64: String, extension pathExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "background-engine-animated-image-\(UUID().uuidString).\(pathExtension)"
        )
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    private func writeTwoFrameGIF(to url: URL) throws {
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.gif.identifier as CFString,
                2,
                nil
            )
        )
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        for pixel in [Data([255, 0, 0, 255]), Data([0, 0, 255, 255])] {
            let provider = try XCTUnwrap(CGDataProvider(data: pixel as CFData))
            let image = try XCTUnwrap(CGImage(
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ))
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFUnclampedDelayTime: 0.15
                ]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func centerPixel(of layer: CALayer) throws -> (red: UInt8, blue: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let rendered = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            guard layer.bounds.width > 0, layer.bounds.height > 0 else { return false }
            context.scaleBy(x: 1 / layer.bounds.width, y: 1 / layer.bounds.height)
            layer.render(in: context)
            return true
        }
        guard rendered else { throw CocoaError(.fileReadCorruptFile) }
        return (pixel[0], pixel[2])
    }

    // Original 4x4 red/blue, two-frame fixtures generated locally with
    // FFmpeg APNG and upstream img2webp. Keeping the tiny bytes inline makes
    // the ImageIO regression deterministic and avoids third-party artwork.
    private static let twoFrameAPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAACXBIWXMAAAABAAAAAQBPJcTWAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAAEAAAABAAAAAAAAAAAAAEAAgAAWWFSWQAAABlJREFUeJxj/MsAAswM/4AkCwMSgHMc0GUAY3gCTNyWkVgAAAAaZmNUTAAAAAEAAAABAAAAAQAAAAAAAAAAAAEAAgAAzx+LvAAAABBmZEFUAAAAAnicY/zLwAAAAv8A/0ORBXIAAAAASUVORK5CYII="

    private static let twoFrameAnimatedWebP =
        "UklGRoQAAABXRUJQVlA4WAoAAAACAAAAAwAAAwAAQU5JTQYAAAD/////AABBTk1GKAAAAAAAAAAAAAMAAAMAAPQBAAJWUDhMDwAAAC8DwAAABxDtj/4HIqL/AQBBTk1GKAAAAAAAAAAAAAMAAAMAAPQBAABWUDhMDwAAAC8DwAAABxBR//4HIqL/AQA="
}
