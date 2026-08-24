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

    func testWebAudioListenerOutsideEntrypointDirectoryUsesProjectRoot() throws {
        let root = try Fixture.makeTempDirectory()
        let pages = root.appending(path: "pages")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        let entrypoint = pages.appending(path: "index.html")
        try #"<script src="../scripts/wallpaper.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let scripts = root.appending(path: "scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try "window.wallpaperRegisterAudioListener((levels) => draw(levels));"
            .write(to: scripts.appending(path: "wallpaper.js"), atomically: true, encoding: .utf8)

        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.missingCapabilities, [.audioReactive])
    }

    func testUTF16WebAudioListenerIsClassifiedLimited() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        var data = Data([0xFF, 0xFE])
        data.append(try XCTUnwrap(
            "<script>wallpaperRegisterAudioListener(() => {})</script>"
                .data(using: .utf16LittleEndian)
        ))
        try data.write(to: entrypoint)

        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.missingCapabilities, [.audioReactive])
    }

    func testWebMediaIntegrationListenerIsClassifiedLimited() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<script src="scripts/player.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let scripts = root.appending(path: "scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try "window.wallpaperRegisterMediaPlaybackListener(updatePlayback);"
            .write(to: scripts.appending(path: "player.js"), atomically: true, encoding: .utf8)

        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .webLive)
        XCTAssertEqual(report.requiredCapabilities, [.mediaIntegration])
        XCTAssertEqual(report.missingCapabilities, [.mediaIntegration])
        XCTAssertEqual(report.diagnosticCode, "web_media_integration_limited")
    }

    func testWebAudioAndMediaIntegrationReportEveryMissingCapability() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try """
        <script>
        wallpaperRegisterAudioListener(drawSpectrum);
        wallpaperRegisterMediaPropertiesListener(showTrack);
        </script>
        """.write(to: entrypoint, atomically: true, encoding: .utf8)

        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.missingCapabilities, [.audioReactive, .mediaIntegration])
        XCTAssertEqual(report.warnings.count, 2)
        XCTAssertEqual(report.diagnosticCode, "web_realtime_integration_limited")
    }

    func testWebMissingLocalScriptAndStylesheetAreUnsupportedInsteadOfBlankFullLive() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try """
        <!doctype html>
        <link href="styles/missing.css?theme=dark" rel="stylesheet">
        <script type="module" src="scripts/missing.js#main"></script>
        """.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            features.missingLocalDependencies,
            ["scripts/missing.js#main", "styles/missing.css?theme=dark"]
        )
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertNil(report.playbackPath)
        XCTAssertEqual(report.diagnosticCode, "web_local_dependency_missing")
        XCTAssertTrue(report.warnings.first?.contains("scripts/missing.js") == true)
    }

    func testWebMissingOutsideAndSymlinkEntrypointsAreUnsupported() throws {
        let parent = try Fixture.makeTempDirectory()
        let root = parent.appending(path: "project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = parent.appending(path: "outside.html")
        try "<!doctype html>".write(to: outside, atomically: true, encoding: .utf8)
        let symlink = root.appending(path: "linked.html")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

        let missing = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: nil,
            projectRoot: root
        )
        let escaped = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: outside,
            projectRoot: root
        )
        let linked = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: symlink,
            projectRoot: root
        )

        for report in [missing, escaped, linked] {
            XCTAssertEqual(report.level, .unsupported)
            XCTAssertNil(report.playbackPath)
            XCTAssertEqual(report.diagnosticCode, "web_entrypoint_unavailable")
        }
    }

    func testWebDependencyValidationAllowsExistingRelativeAndRemoteResources() throws {
        let root = try Fixture.makeTempDirectory()
        let pages = root.appending(path: "pages")
        let scripts = root.appending(path: "scripts")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let entrypoint = pages.appending(path: "index.html")
        try """
        <!doctype html>
        <script src="../scripts/local%20wallpaper.js?v=2"></script>
        <script src="https://example.com/optional.js"></script>
        <link rel="stylesheet" href="data:text/css,body{}">
        """.write(to: entrypoint, atomically: true, encoding: .utf8)
        try "window.wallpaperRegisterAudioListener(draw);".write(
            to: scripts.appending(path: "local wallpaper.js"),
            atomically: true,
            encoding: .utf8
        )

        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.missingCapabilities, [.audioReactive])
        XCTAssertEqual(report.diagnosticCode, "web_audio_reactive_limited")
    }

    func testWebDependencyValidationUsesFileURLSemanticsForLeadingSlashReferences() throws {
        let root = try Fixture.makeTempDirectory()
        let scripts = root.appending(path: "scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try "draw();".write(
            to: scripts.appending(path: "local.js"),
            atomically: true,
            encoding: .utf8
        )
        let entrypoint = root.appending(path: "index.html")
        try """
        <!doctype html>
        <script src="/scripts/local.js"></script>
        <script src="//cdn.example.com/runtime.js"></script>
        """.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            features.missingLocalDependencies,
            ["//cdn.example.com/runtime.js", "/scripts/local.js"]
        )
    }

    func testWebDependencyValidationAllowsLeadingSlashReferencesWithRemoteBase() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try """
        <!doctype html>
        <base href="https://cdn.example.com/wallpaper/">
        <script src="/scripts/runtime.js"></script>
        <script src="//static.example.com/vendor.js"></script>
        """.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertTrue(features.missingLocalDependencies.isEmpty)
    }

    func testWebDependencyValidationIgnoresCommentsAndHonorsLocalBaseHref() throws {
        let root = try Fixture.makeTempDirectory()
        let pages = root.appending(path: "pages")
        let runtime = root.appending(path: "runtime")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let entrypoint = pages.appending(path: "index.html")
        try """
        <!doctype html>
        <!-- <script src="missing-example.js"></script> -->
        <style>.example::after { content: '<link rel="stylesheet" href="missing.css">'; }</style>
        <template><script src="missing-template.js"></script></template>
        <script>const example = '<script src="missing-string.js">';</script>
        <textarea><script src="missing-textarea.js"></script></textarea>
        <title><script src="missing-title.js"></script></title>
        <div data-template="<script src='missing-attribute.js'></script>"></div>
        <base target="_blank">
        <base href="../runtime/">
        <script src="main.js"></script>
        """.write(to: entrypoint, atomically: true, encoding: .utf8)
        try "draw();".write(
            to: runtime.appending(path: "main.js"),
            atomically: true,
            encoding: .utf8
        )

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertTrue(features.missingLocalDependencies.isEmpty)
        XCTAssertEqual(report.level, .full)
        XCTAssertEqual(report.playbackPath, .webLive)
    }

    func testWebDependencyValidationUsesURLSemanticsForDotSegmentBaseHref() throws {
        let root = try Fixture.makeTempDirectory()
        let pages = root.appending(path: "pages")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        let entrypoint = pages.appending(path: "index.html")
        try "draw();".write(
            to: pages.appending(path: "page.js"),
            atomically: true,
            encoding: .utf8
        )
        try "draw();".write(
            to: root.appending(path: "root.js"),
            atomically: true,
            encoding: .utf8
        )

        try #"<base href="."><script src="page.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        XCTAssertTrue(
            WebRuntimeFeatureAnalyzer().analyze(
                entrypoint: entrypoint,
                projectRoot: root
            ).missingLocalDependencies.isEmpty
        )

        try #"<base href=".."><script src="root.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        XCTAssertTrue(
            WebRuntimeFeatureAnalyzer().analyze(
                entrypoint: entrypoint,
                projectRoot: root
            ).missingLocalDependencies.isEmpty
        )
    }

    func testWebDependencyValidationRejectsFileURLAndEscapingBaseHref() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try """
        <!doctype html>
        <base href="../../outside/">
        <script src="runtime.js"></script>
        <script src="file:///tmp/injected.js"></script>
        """.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            features.missingLocalDependencies,
            ["file:///tmp/injected.js", "runtime.js"]
        )
    }

    func testWebDependencyValidationRejectsProjectTraversalAndSymlinkEscape() throws {
        let parent = try Fixture.makeTempDirectory()
        let root = parent.appending(path: "project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = parent.appending(path: "outside.js")
        try "draw();".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "linked.js"),
            withDestinationURL: outside
        )
        let entrypoint = root.appending(path: "index.html")
        try """
        <script src="../outside.js"></script>
        <script src="linked.js"></script>
        """.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(features.missingLocalDependencies, ["../outside.js", "linked.js"])
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

    func testUnrecognizedSceneLayerForcesRenderedCacheInsteadOfFullNative() throws {
        let root = try Fixture.makeTempDirectory()
        let package = root.appending(path: "engine-only-layer.pkg")
        try Fixture.writeScenePackage(
            to: package,
            sceneJSON: """
            {
              "objects": [
                { "id": 1, "name": "Background", "image": "models/background.json" },
                { "id": 2, "name": "Engine-only light", "light": "lights/key.json" }
              ]
            }
            """,
            extraEntries: [
                (path: "models/background.json", data: Data(#"{"material":"materials/background.json"}"#.utf8))
            ]
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: package)
        let report = WallpaperCompatibilityAnalyzer().analyzeScene(
            entrypoint: package,
            nativePlayable: true
        )

        XCTAssertTrue(features.requiresEngineRenderer)
        XCTAssertTrue(features.runtimeGaps.contains("unrecognized-layer-runtime"))
        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
        XCTAssertTrue(report.requiredCapabilities.contains(.engineLayer))
        XCTAssertTrue(report.missingCapabilities.contains(.engineLayer))
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
