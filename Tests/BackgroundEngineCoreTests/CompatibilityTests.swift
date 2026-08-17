import Foundation
import XCTest
@testable import BackgroundEngineCore

final class CompatibilityTests: XCTestCase {
    func testLimitedSupportModeRoundTrips() throws {
        let value = SupportMode.limited(reason: "Audio response is unavailable.")
        let data = try JSONEncoder().encode(value)

        XCTAssertEqual(try JSONDecoder().decode(SupportMode.self, from: data), value)
        XCTAssertEqual(value.label, "Limited")
    }

    func testWebAudioListenerIsClassifiedLimited() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try "<script>wallpaperRegisterAudioListener(() => {})</script>".write(
            to: entrypoint,
            atomically: true,
            encoding: .utf8
        )

        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint
        )

        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .webLive)
        XCTAssertEqual(report.missingCapabilities, [.audioReactive])
        XCTAssertEqual(report.supportMode.label, "Limited")
    }

    func testWebAudioListenerInReferencedScriptIsClassifiedLimited() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<script src="wallpaper.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try "window.wallpaperRegisterAudioListener((levels) => draw(levels));"
            .write(to: root.appending(path: "wallpaper.js"), atomically: true, encoding: .utf8)

        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint
        )

        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.missingCapabilities, [.audioReactive])
    }

    func testSceneFeatureAnalyzerDetectsClockAndInteractionScripts() throws {
        let root = try Fixture.makeTempDirectory()
        let package = root.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: package,
            sceneJSON: #"{"objects":[{"text":{"value":"CLOCK","script":"export function update(value) { return new Date().getHours() + input.cursorX; }"}}]}"#
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: package)
        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .scene,
            status: .playable,
            entrypoint: package
        )

        XCTAssertTrue(features.requiresClockRuntime)
        XCTAssertTrue(features.requiresInteractionRuntime)
        XCTAssertEqual(report.level, .limited)
        XCTAssertTrue(report.requiredCapabilities.contains(.clock))
        XCTAssertTrue(report.missingCapabilities.contains(.interaction))
        XCTAssertTrue(report.missingCapabilities.contains(.sceneScript))
    }

    func testFullRenderedSceneUsesCachedSupportMode() {
        let report = CompatibilityReport(
            level: .full,
            playbackPath: .renderedSceneCache,
            requiredCapabilities: [.shader]
        )

        XCTAssertEqual(report.supportMode.label, "Cached")
    }
}
