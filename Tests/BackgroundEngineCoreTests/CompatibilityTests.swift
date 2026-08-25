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

    func testWebDependencyValidationRequiresPermissionForRemoteResources() throws {
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

        let blocked = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )
        let allowed = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root,
            networkAccessAllowed: true
        )

        XCTAssertEqual(blocked.level, .unsupported)
        XCTAssertEqual(blocked.missingCapabilities, [.externalNetwork])
        XCTAssertEqual(blocked.diagnosticCode, "web_network_access_required")
        XCTAssertTrue(blocked.warnings.first?.contains("https://example.com/optional.js") == true)
        XCTAssertEqual(allowed.level, .limited)
        XCTAssertEqual(allowed.requiredCapabilities, [.audioReactive, .externalNetwork])
        XCTAssertEqual(allowed.missingCapabilities, [.audioReactive])
        XCTAssertEqual(allowed.diagnosticCode, "web_audio_reactive_limited")
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
        XCTAssertEqual(
            features.remoteDependencies,
            ["//static.example.com/vendor.js", "/scripts/runtime.js"]
        )
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
        let localTarget = root.appending(path: "local-target.js")
        try "export default 2;".write(to: localTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "local-linked.js"),
            withDestinationURL: localTarget
        )
        let entrypoint = root.appending(path: "index.html")
        try """
        <script src="../outside.js"></script>
        <script src="linked.js"></script>
        <script src="local-linked.js"></script>
        """.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            features.missingLocalDependencies,
            ["../outside.js", "linked.js", "local-linked.js"]
        )
    }

    func testTransitiveRemoteJavaScriptModuleRequiresNetworkPermission() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<script type="module" src="main.js"></script><canvas id="wallpaper"></canvas>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try #"import { render } from "https://cdn.example.test/renderer.mjs"; render();"#
            .write(to: root.appending(path: "main.js"), atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let blocked = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )
        let allowed = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root,
            networkAccessAllowed: true
        )

        XCTAssertEqual(features.remoteDependencies, ["https://cdn.example.test/renderer.mjs"])
        XCTAssertEqual(blocked.level, .unsupported)
        XCTAssertEqual(blocked.missingCapabilities, [.externalNetwork])
        XCTAssertEqual(blocked.diagnosticCode, "web_network_access_required")
        XCTAssertEqual(allowed.level, .full)
        XCTAssertEqual(allowed.playbackPath, .webLive)
        XCTAssertEqual(allowed.requiredCapabilities, [.externalNetwork])
    }

    func testTransitiveJavaScriptImportsRejectMissingTraversalAndSymlinkTargets() throws {
        let parent = try Fixture.makeTempDirectory()
        let root = parent.appending(path: "project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = parent.appending(path: "outside.js")
        try "export default 1;".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "linked.js"),
            withDestinationURL: outside
        )
        let localTarget = root.appending(path: "local-target.js")
        try "export default 2;".write(to: localTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "local-linked.js"),
            withDestinationURL: localTarget
        )
        let entrypoint = root.appending(path: "index.html")
        try #"<script type="module" src="main.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try """
        import "./missing.mjs";
        import "../outside.js";
        import "./linked.js";
        import "./local-linked.js";
        """.write(to: root.appending(path: "main.js"), atomically: true, encoding: .utf8)

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
            ["../outside.js", "./linked.js", "./local-linked.js", "./missing.mjs"]
        )
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertEqual(report.diagnosticCode, "web_local_dependency_missing")
    }

    func testWebDependencyAnalysisReadsEntireEntrypointBeyondValidationPrefix() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let padding = "<!--"
            + String(repeating: "x", count: WebWallpaperValidation.maximumProbeBytes + 1)
            + "-->"
        try (padding + #"<script type="module" src="https://cdn.example.test/late.mjs"></script>"#)
            .write(to: entrypoint, atomically: true, encoding: .utf8)

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

        XCTAssertEqual(features.remoteDependencies, ["https://cdn.example.test/late.mjs"])
        XCTAssertFalse(features.dependencyAnalysisLimitExceeded)
        XCTAssertEqual(report.diagnosticCode, "web_network_access_required")
    }

    func testWebDependencyAnalysisFailsClosedAboveAggregateTextLimit() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try Data(
            repeating: 0x20,
            count: WebRuntimeFeatureAnalyzer.maximumDependencyTextBytes + 1
        ).write(to: entrypoint, options: .atomic)

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

        XCTAssertTrue(features.dependencyAnalysisLimitExceeded)
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertEqual(report.diagnosticCode, "web_dependency_probe_limit_exceeded")
    }

    func testInlineExecutableDependenciesRespectNetworkPermissionAndIgnoreRawText() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <!doctype html>
        <template>
          <script type="module">import "https://ignored-template.example.test/module.js";</script>
          <style>@import "https://ignored-template.example.test/theme.css";</style>
        </template>
        <textarea><script>import("https://ignored-raw.example.test/module.js")</script></textarea>
        <script type="application/json">
          {"source":"import('https://ignored-data.example.test/module.js')"}
        </script>
        <script type="module">
          // import "https://ignored-comment.example.test/module.js";
          void import("https://cdn.example.test/inline-module.js");
        </script>
        <style>
          /* @import "https://ignored-comment.example.test/theme.css"; */
          @import url("https://cdn.example.test/inline-theme.css");
        </style>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let blocked = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )
        let allowed = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root,
            networkAccessAllowed: true
        )

        XCTAssertEqual(
            features.remoteDependencies,
            [
                "https://cdn.example.test/inline-module.js",
                "https://cdn.example.test/inline-theme.css"
            ]
        )
        XCTAssertEqual(blocked.diagnosticCode, "web_network_access_required")
        XCTAssertEqual(allowed.level, .full)
        XCTAssertEqual(allowed.playbackPath, .webLive)
    }

    func testExternalScriptsHonorExecutableTypePolicy() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <!doctype html>
        <script type="application/json" src="https://ignored.example.test/data.json"></script>
        <script type="importmap" src="https://ignored.example.test/import-map.json"></script>
        <script type="speculationrules" src="https://ignored.example.test/rules.json"></script>
        <script src="https://cdn.example.test/default.js"></script>
        <script type="module" src="https://cdn.example.test/module.js"></script>
        <script type="text/javascript" src="https://cdn.example.test/classic.js"></script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let blocked = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )
        let allowed = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root,
            networkAccessAllowed: true
        )

        XCTAssertEqual(
            features.remoteDependencies,
            [
                "https://cdn.example.test/classic.js",
                "https://cdn.example.test/default.js",
                "https://cdn.example.test/module.js"
            ]
        )
        XCTAssertEqual(blocked.diagnosticCode, "web_network_access_required")
        XCTAssertEqual(allowed.level, .full)
    }

    func testModuleAndNoModuleFallbackSelectOnlyModuleCapablePath() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <!doctype html>
        <script type="module" src="https://cdn.example.test/modern.js"></script>
        <script nomodule src="https://ignored.example.test/legacy-default.js"></script>
        <script type="text/javascript" nomodule="" src="https://ignored.example.test/legacy-classic.js"></script>
        <script type="module" nomodule src="https://cdn.example.test/module-with-nomodule.js"></script>
        <script nomodule>import("https://ignored.example.test/inline-legacy.js")</script>
        <script type="module" nomodule>
          import("https://cdn.example.test/inline-module-with-nomodule.js")
        </script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            features.remoteDependencies,
            [
                "https://cdn.example.test/inline-module-with-nomodule.js",
                "https://cdn.example.test/modern.js",
                "https://cdn.example.test/module-with-nomodule.js"
            ]
        )
    }

    func testUnclosedExecutableScriptAndStyleAnalyzeRawTextThroughEOF() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let cases = [
            (
                #"<script type="module">void import("https://cdn.example.test/unclosed.js");"#,
                "https://cdn.example.test/unclosed.js"
            ),
            (
                #"<style>@import url("https://cdn.example.test/unclosed.css");"#,
                "https://cdn.example.test/unclosed.css"
            )
        ]

        for (document, expectedDependency) in cases {
            try document.write(to: entrypoint, atomically: true, encoding: .utf8)
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

            XCTAssertEqual(features.remoteDependencies, [expectedDependency])
            XCTAssertEqual(report.diagnosticCode, "web_network_access_required")
        }
    }

    func testUnclosedNonExecutableAndInertRawTextRemainIgnored() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let documents = [
            #"<script type="application/json">{"source":"import('https://ignored.example.test/data.js')"}"#,
            #"<textarea>import("https://ignored.example.test/textarea.js")"#,
            #"<template><script type="module">import("https://ignored.example.test/template.js")"#
        ]

        for document in documents {
            try document.write(to: entrypoint, atomically: true, encoding: .utf8)
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

            XCTAssertTrue(features.remoteDependencies.isEmpty, document)
            XCTAssertTrue(features.missingLocalDependencies.isEmpty, document)
            XCTAssertEqual(report.level, .full, document)
        }
    }

    func testJavaScriptTemplateExpressionsAndNestedExportBodiesRemainReachable() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<script type="module" src="main.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try #"""
        const literalOnly = `import("https://ignored-literal.example.test/module.js")`;
        const executableExpression = `${import("https://cdn.example.test/template-expression.js")}`;
        export default { load: () => import("https://cdn.example.test/export-default.js") };
        export const objectRuntime = {
          load() { return import("https://cdn.example.test/export-object.js"); }
        };
        export class Runtime {
          load() { return import("https://cdn.example.test/export-class.js"); }
        }
        """#.write(to: root.appending(path: "main.js"), atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            features.remoteDependencies,
            [
                "https://cdn.example.test/export-class.js",
                "https://cdn.example.test/export-default.js",
                "https://cdn.example.test/export-object.js",
                "https://cdn.example.test/template-expression.js"
            ]
        )
        XCTAssertFalse(features.dependencyAnalysisLimitExceeded)
    }

    func testJavaScriptRegularExpressionQuotesDoNotHideFollowingImport() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<script type="module" src="main.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try #"""
        const quote = /["']/;
        void import("https://cdn.example.test/after-regexp.js");
        """#.write(to: root.appending(path: "main.js"), atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            features.remoteDependencies,
            ["https://cdn.example.test/after-regexp.js"]
        )
    }

    func testJavaScriptRegularExpressionAfterControlHeadersAndBlocksKeepsLaterImport() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<script type="module" src="main.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try #"""
        if (ok) /["']/;
        if (((ready && check(value)))) {}
        /import\("https:\/\/ignored\.example\/inside-regexp\.js"\)/g;
        void import("https://cdn.example.test/after-control.js");
        """#.write(to: root.appending(path: "main.js"), atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            features.remoteDependencies,
            ["https://cdn.example.test/after-control.js"]
        )
    }

    func testJavaScriptStatementBodyBlocksKeepRegularExpressionsLexicallyIsolated() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<script type="module" src="main.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try #"""
        if (first) {} else if ((second && check(value))) {} else {}
        /import\("https:\/\/ignored\.example\/after-else\.js"\)/;

        try {} catch {}
        /["'{}]/;

        try {} catch (error) {} finally {}
        /import\("https:\/\/ignored\.example\/after-finally\.js"\)/g;

        do { /["']/; } while ((again && check(value)));
        void import("https://cdn.example.test/after-statement-blocks.js");
        """#.write(to: root.appending(path: "main.js"), atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            features.remoteDependencies,
            ["https://cdn.example.test/after-statement-blocks.js"]
        )
        XCTAssertFalse(features.dependencyAnalysisLimitExceeded)
    }

    func testJavaScriptExpressionAndKeywordMemberDivisionKeepLaterImport() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<script type="module" src="main.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try #"""
        const objectRatio = ({}) / divisor;
        const functionRatio = function() {} / divisor;
        const caughtRatio = promise.catch(handler) / divisor;
        const returnedRatio = object.return / divisor;
        void import("https://cdn.example.test/after-expression-division.js");
        """#.write(to: root.appending(path: "main.js"), atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            features.remoteDependencies,
            ["https://cdn.example.test/after-expression-division.js"]
        )
    }

    func testJavaScriptRegularExpressionImportTextCharacterClassesEscapesAndFlagsAreIgnored() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<script type="module" src="main.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try #"""
        const ignored = /import\("https:\/\/ignored\.example\/module\.js"\)/gim;
        const syntax = /[\/"'{}\[\]\\]+/uy;
        """#.write(to: root.appending(path: "main.js"), atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertTrue(features.remoteDependencies.isEmpty)
        XCTAssertTrue(features.missingLocalDependencies.isEmpty)
        XCTAssertFalse(features.dependencyAnalysisLimitExceeded)
    }

    func testJavaScriptDivisionDoesNotSwallowFollowingDynamicImport() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<script type="module" src="main.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try #"""
        const quotient = total / count / scale;
        value /= divisor;
        void import("https://cdn.example.test/after-division.js");
        """#.write(to: root.appending(path: "main.js"), atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            features.remoteDependencies,
            ["https://cdn.example.test/after-division.js"]
        )
    }

    func testDocumentDependencyElementLimitIsBoundedAndFailsClosed() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let boundedDocument = String(
            repeating: "<style></style>",
            count: WebRuntimeFeatureAnalyzer.maximumDocumentDependencyElements
        )
        XCTAssertLessThan(
            boundedDocument.utf8.count,
            WebRuntimeFeatureAnalyzer.maximumDependencyTextBytes
        )
        try boundedDocument.write(to: entrypoint, atomically: true, encoding: .utf8)

        let boundaryFeatures = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let boundaryReport = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )
        XCTAssertFalse(boundaryFeatures.dependencyAnalysisLimitExceeded)
        XCTAssertEqual(boundaryReport.level, .full)

        try (boundedDocument + "<style></style>")
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let exceededFeatures = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let exceededReport = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertTrue(exceededFeatures.dependencyAnalysisLimitExceeded)
        XCTAssertEqual(exceededReport.level, .unsupported)
        XCTAssertEqual(exceededReport.diagnosticCode, "web_dependency_probe_limit_exceeded")
    }

    func testTransitiveJavaScriptGraphSupportsEveryLiteralImportFormAndCycles() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<script type="module" src="a.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try """
        import { value } from "./b.mjs";
        void import("./lazy.js");
        export { value };
        """.write(to: root.appending(path: "a.js"), atomically: true, encoding: .utf8)
        try #"export { value } from "./a.js";"#
            .write(to: root.appending(path: "b.mjs"), atomically: true, encoding: .utf8)
        try #"import "./a.js";"#
            .write(to: root.appending(path: "lazy.js"), atomically: true, encoding: .utf8)

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
        XCTAssertTrue(features.remoteDependencies.isEmpty)
        XCTAssertFalse(features.dependencyAnalysisLimitExceeded)
        XCTAssertEqual(report.level, .full)
    }

    func testTransitiveCSSImportsResolveLocalAndRemoteReferences() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<link rel="stylesheet" href="main.css">"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try """
        @import "./theme.css";
        @import url("https://cdn.example.test/fonts.css");
        """.write(to: root.appending(path: "main.css"), atomically: true, encoding: .utf8)
        try "body { color: white; }".write(
            to: root.appending(path: "theme.css"),
            atomically: true,
            encoding: .utf8
        )

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let blocked = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )
        let allowed = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root,
            networkAccessAllowed: true
        )

        XCTAssertTrue(features.missingLocalDependencies.isEmpty)
        XCTAssertEqual(features.remoteDependencies, ["https://cdn.example.test/fonts.css"])
        XCTAssertEqual(blocked.diagnosticCode, "web_network_access_required")
        XCTAssertEqual(allowed.level, .full)
    }

    func testTransitiveDependencyLexerIgnoresCommentsStringsTemplatesAndOpaqueSpecifiers() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<script type="module" src="main.js"></script><link rel="stylesheet" href="main.css">"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try #"""
        // import "https://comment.example.test/module.js";
        /* export * from "https://block.example.test/module.js"; */
        const ordinary = "import('https://string.example.test/module.js')";
        const template = `export * from "https://template.example.test/module.js"`;
        const loader = { import: () => {} };
        loader /* member access is not dynamic import syntax */
          . import("https://method.example.test/module.js");
        import packageValue from "wallpaper-package";
        import "data:text/javascript,export default 1";
        void import("blob:https://example.test/runtime-id");
        console.log(packageValue, ordinary, template);
        """#.write(to: root.appending(path: "main.js"), atomically: true, encoding: .utf8)
        try #"""
        /* @import "https://comment.example.test/theme.css"; */
        body::after { content: '@import "https://string.example.test/theme.css"'; }
        """#.write(to: root.appending(path: "main.css"), atomically: true, encoding: .utf8)
        try #"import \"https://unused.example.test/module.js\";"#
            .write(to: root.appending(path: "unused.js"), atomically: true, encoding: .utf8)

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
        XCTAssertTrue(features.remoteDependencies.isEmpty)
        XCTAssertFalse(features.dependencyAnalysisLimitExceeded)
        XCTAssertEqual(report.level, .full)
    }

    func testTransitiveDependencyReferenceLimitFailsClosed() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<script type="module" src="main.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let imports = Array(
            repeating: #"void import("./module.js");"#,
            count: WebRuntimeFeatureAnalyzer.maximumReferencesPerFile + 1
        ).joined(separator: "\n")
        try imports.write(to: root.appending(path: "main.js"), atomically: true, encoding: .utf8)
        try "export default 1;".write(
            to: root.appending(path: "module.js"),
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

        XCTAssertTrue(features.dependencyAnalysisLimitExceeded)
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertNil(report.playbackPath)
        XCTAssertEqual(report.diagnosticCode, "web_dependency_probe_limit_exceeded")
        XCTAssertTrue(report.warnings.first?.contains("safe file, text, or reference limit") == true)
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
