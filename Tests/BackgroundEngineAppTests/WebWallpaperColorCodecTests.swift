import XCTest
@testable import BackgroundEngineApp

final class WebWallpaperColorCodecTests: XCTestCase {
    func testDecodesLivelySixAndThreeDigitHexColors() throws {
        XCTAssertEqual(
            try XCTUnwrap(WebWallpaperColorCodec.decode("#337FFF")),
            .init(red: 0x33 / 255, green: 0x7f / 255, blue: 1)
        )
        XCTAssertEqual(
            try XCTUnwrap(WebWallpaperColorCodec.decode("#0f8")),
            .init(red: 0, green: 1, blue: 0x88 / 255)
        )
    }

    func testPreservesLivelyHexShapeWhenEditing() {
        XCTAssertEqual(
            WebWallpaperColorCodec.encode(
                red: 0.2,
                green: 0.5,
                blue: 1,
                preservingFormatOf: "#000000"
            ),
            "#3380FF"
        )
    }

    func testPreservesWallpaperEngineNormalizedRGBShapeWhenEditing() {
        XCTAssertEqual(
            WebWallpaperColorCodec.encode(
                red: 0.2,
                green: 0.5,
                blue: 1,
                preservingFormatOf: "0 0 0"
            ),
            "0.2 0.5 1"
        )
    }
}
