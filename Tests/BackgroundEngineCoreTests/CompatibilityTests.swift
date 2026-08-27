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

    func testLivelyAudioListenerIsClassifiedLimited() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try "<script>function livelyAudioListener(levels) { draw(levels); }</script>".write(
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
        XCTAssertEqual(report.requiredCapabilities, [.audioReactive])
        XCTAssertEqual(report.missingCapabilities, [.audioReactive])
        XCTAssertEqual(report.diagnosticCode, "web_audio_reactive_limited")
    }

    func testLivelyTrackAndSystemCallbacksAreClassifiedMediaIntegrationLimited() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try """
        <script>
        function livelyCurrentTrack(data) { renderTrack(JSON.parse(data)); }
        function livelySystemInformation(data) { renderStats(JSON.parse(data)); }
        </script>
        """.write(to: entrypoint, atomically: true, encoding: .utf8)

        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint
        )

        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .webLive)
        XCTAssertEqual(report.requiredCapabilities, [.mediaIntegration])
        XCTAssertEqual(report.missingCapabilities, [.mediaIntegration])
        XCTAssertEqual(report.diagnosticCode, "web_media_integration_limited")
    }

    func testSupportedLivelyPropertyAndPauseCallbacksRemainFullLive() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try """
        <script>
        function livelyPropertyListener(name, value) { applySetting(name, value); }
        function livelyWallpaperPlaybackChanged(data) { setPaused(JSON.parse(data).IsPaused); }
        </script>
        """.write(to: entrypoint, atomically: true, encoding: .utf8)

        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint
        )

        XCTAssertEqual(report.level, .full)
        XCTAssertEqual(report.playbackPath, .webLive)
        XCTAssertTrue(report.requiredCapabilities.isEmpty)
        XCTAssertTrue(report.missingCapabilities.isEmpty)
    }

    func testLegacyButtonLimitationMetadataNoLongerDowngradesCompatibleWebWallpaper() throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"backgroundEngineLivelyPropertyLimitations":["button"]}"#
            .write(to: root.appending(path: "project.json"), atomically: true, encoding: .utf8)
        let fullReport = CompatibilityReport(level: .full, playbackPath: .webLive)

        let report = LivelyPropertyCompatibility.apply(to: fullReport, projectRoot: root)

        XCTAssertEqual(report, fullReport)
        XCTAssertTrue(report.missingCapabilities.isEmpty)
        XCTAssertFalse(report.warnings.contains { $0.localizedCaseInsensitiveContains("button") })
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

    func testInvalidLegacyRemoteMetadataIsUnsupportedInsteadOfLoadingPlaceholder() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try "<p>generated placeholder</p>".write(
            to: entrypoint,
            atomically: true,
            encoding: .utf8
        )
        try #"{"schemaVersion":1,"targetURL":"http://legacy.example.test/live"}"#
            .write(
                to: root.appending(path: RemoteWebWallpaperConfiguration.fileName),
                atomically: true,
                encoding: .utf8
            )

        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root,
            networkAccessAllowed: true
        )

        XCTAssertEqual(report.level, .unsupported)
        XCTAssertNil(report.playbackPath)
        XCTAssertEqual(report.diagnosticCode, "web_remote_configuration_invalid")
        XCTAssertTrue(report.warnings.first?.contains("Re-import") == true)
    }

    func testPermittedRemoteWebsiteIsLimitedBecauseRuntimeParityCannotBePreflighted() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try "<!doctype html><p>Background Engine website placeholder</p>"
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let configuration = try RemoteWebWallpaperConfiguration(
            targetURL: URL(string: "https://example.com/wallpaper")!
        )
        try JSONEncoder().encode(configuration).write(
            to: root.appending(path: RemoteWebWallpaperConfiguration.fileName),
            options: [.atomic]
        )

        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root,
            networkAccessAllowed: true
        )

        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .webLive)
        XCTAssertEqual(report.requiredCapabilities, [.externalNetwork])
        XCTAssertTrue(report.missingCapabilities.isEmpty)
        XCTAssertEqual(report.diagnosticCode, "web_remote_runtime_unverified")
        XCTAssertTrue(report.warnings.first?.contains("cannot be verified") == true)
    }

    func testWebStaticMediaDiscoveryHonorsBaseAndElementKinds() throws {
        let root = try Fixture.makeTempDirectory()
        let pages = root.appending(path: "pages")
        let media = root.appending(path: "media")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let entrypoint = pages.appending(path: "index.html")
        for name in ["movie.ogv", "sound.ogg", "fallback.webm"] {
            try Data([1, 2, 3]).write(to: media.appending(path: name))
        }
        try """
        <!doctype html>
        <base href="../media/">
        <video src="movie.ogv?loop=1#start"></video>
        <audio src="sound.ogg"></audio>
        <video><source src="fallback.webm" type="video/webm"></video>
        """.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            features.localMediaReferences.map(\.elementKind),
            [.video, .video, .audio]
        )
        XCTAssertEqual(
            Set(features.localMediaReferences.map { $0.sourceURL.lastPathComponent }),
            ["fallback.webm", "movie.ogv", "sound.ogg"]
        )
        XCTAssertEqual(
            Set(features.localMediaReferences.map(\.rawReference)),
            ["fallback.webm", "movie.ogv?loop=1#start", "sound.ogg"]
        )
        XCTAssertTrue(features.missingLocalMediaReferences.isEmpty)
        XCTAssertTrue(features.remoteMediaReferences.isEmpty)
        XCTAssertFalse(features.mediaAnalysisLimitExceeded)
    }

    func testHTMLCharacterReferencesResolveRequiredDependenciesAndMedia() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try "window.ready = true;".write(
            to: root.appending(path: "runtime.js"),
            atomically: true,
            encoding: .utf8
        )
        try Data([1, 2, 3]).write(to: root.appending(path: "loop.ogv"))
        try #"""
        <script src="runtime&#46;js?mode=dark&amp;quality=high"></script>
        <video src="loop&#x2E;ogv"></video>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertTrue(features.missingLocalDependencies.isEmpty)
        XCTAssertTrue(features.missingLocalMediaReferences.isEmpty)
        XCTAssertEqual(features.localMediaReferences.count, 1)
        XCTAssertEqual(features.localMediaReferences.first?.sourceURL.lastPathComponent, "loop.ogv")
        XCTAssertEqual(features.localMediaReferences.first?.rawReference, "loop.ogv")
    }

    func testHTMLCharacterReferenceDecoderBoundsMalformedEntityScanning() throws {
        let implementation = try String(
            repositoryFile: "Sources/BackgroundEngineCore/Compatibility.swift"
        )
        XCTAssertFalse(implementation.contains("bytes[index...].firstIndex(of: 0x3B)"))
        XCTAssertTrue(implementation.contains("let maximumEntityEnd = min(bytes.count - 1, index + 12)"))

        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let malformedName = String(repeating: "&", count: 24) + ";.ogv"
        try Data([1, 2, 3]).write(to: root.appending(path: malformedName))
        try #"<video src="\#(malformedName)"></video>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertTrue(features.missingLocalMediaReferences.isEmpty)
        XCTAssertEqual(features.localMediaReferences.first?.rawReference, malformedName)
    }

    func testWebStaticMediaDiscoveryTraversesNestedLocalIframes() throws {
        let root = try Fixture.makeTempDirectory()
        let frames = root.appending(path: "frames")
        let nested = frames.appending(path: "nested")
        let media = root.appending(path: "media")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for name in ["frame-video.ogv", "frame-audio.ogg"] {
            try Data([1, 2, 3]).write(to: media.appending(path: name))
        }
        let entrypoint = root.appending(path: "index.html")
        try #"<iframe src="frames/first.html"></iframe>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try """
        <video src="../media/frame-video.ogv"></video>
        <iframe src="nested/second.html"></iframe>
        """.write(
            to: frames.appending(path: "first.html"),
            atomically: true,
            encoding: .utf8
        )
        try """
        <base href="../../media/">
        <audio><source src="frame-audio.ogg" type="audio/ogg"></audio>
        """.write(
            to: nested.appending(path: "second.html"),
            atomically: true,
            encoding: .utf8
        )

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let kinds = Dictionary(
            uniqueKeysWithValues: features.localMediaReferences.map {
                ($0.sourceURL.lastPathComponent, $0.elementKind)
            }
        )

        XCTAssertEqual(kinds["frame-video.ogv"], .video)
        XCTAssertEqual(kinds["frame-audio.ogg"], .audio)
        XCTAssertTrue(features.missingLocalDependencies.isEmpty)
        XCTAssertTrue(features.remoteDependencies.isEmpty)
        XCTAssertFalse(features.dependencyAnalysisLimitExceeded)
    }

    func testWebStaticMediaDiscoveryTraversesBoundedIframeSourceDocuments() throws {
        let root = try Fixture.makeTempDirectory()
        let media = root.appending(path: "media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: media.appending(path: "inline.ogv"))
        try Data([4, 5, 6]).write(to: media.appending(path: "script.ogg"))
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <iframe src="ignored-fallback.html" srcdoc="&lt;base href=&quot;media/&quot;&gt;&lt;video src=&quot;inline.ogv&quot;&gt;&lt;/video&gt;&lt;script&gt;new Audio(&#39;script.ogg&#39;)&lt;/script&gt;"></iframe>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            Set(features.localMediaReferences.map { $0.sourceURL.lastPathComponent }),
            ["inline.ogv", "script.ogg"]
        )
        XCTAssertTrue(features.missingLocalDependencies.isEmpty)
        XCTAssertFalse(features.dependencyAnalysisLimitExceeded)
        XCTAssertFalse(features.hasOpaqueOrDynamicMediaReferences)
    }

    func testWebJavaScriptLiteralMediaDiscoveryCoversInlineAndExternalScripts() throws {
        let root = try Fixture.makeTempDirectory()
        let assets = root.appending(path: "assets")
        let scripts = root.appending(path: "scripts")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        for name in ["audio.ogg", "video.ogv", "fallback.webm", "external.ogv"] {
            try Data([1, 2, 3]).write(to: assets.appending(path: name))
        }
        try #"widget.src = 'external.ogv';"#.write(
            to: scripts.appending(path: "runtime.js"),
            atomically: true,
            encoding: .utf8
        )
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <base href="assets/">
        <script>
          const soundtrack = new Audio('audio.ogg');
          player.src = "video.ogv";
          player.setAttribute('src', 'fallback.webm');
          previewImage.src = 'poster.webp';
          scriptLoader.setAttribute('src', 'runtime.js');
        </script>
        <script src="../scripts/runtime.js"></script>
        <script type="application/json">{"example":"player.src = 'ignored.ogv'"}</script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let kinds = Dictionary(
            grouping: features.localMediaReferences,
            by: { $0.elementKind }
        ).mapValues { Set($0.map { $0.sourceURL.lastPathComponent }) }

        XCTAssertEqual(kinds[.audio], ["audio.ogg"])
        XCTAssertEqual(
            kinds[.source],
            ["external.ogv", "fallback.webm", "video.ogv"]
        )
        XCTAssertFalse(features.hasOpaqueOrDynamicMediaReferences)
        XCTAssertTrue(features.missingLocalMediaReferences.isEmpty)
    }

    func testGenericJavaScriptSourceAssignmentsTrackImagesAndScriptsAsResources() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <script>
          image.src = 'wallpaper.png';
          image.setAttribute('src', 'fallback.webp');
          loader.src = 'runtime.js';
          frame.setAttribute('src', 'content.html');
        </script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

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

        XCTAssertTrue(features.localMediaReferences.isEmpty)
        XCTAssertTrue(features.missingLocalMediaReferences.isEmpty)
        XCTAssertFalse(features.hasOpaqueOrDynamicMediaReferences)
        XCTAssertEqual(
            features.missingLocalDependencies,
            ["content.html", "fallback.webp", "runtime.js", "wallpaper.png"]
        )
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertEqual(report.diagnosticCode, "web_local_dependency_missing")
    }

    func testGenericJavaScriptSourceAssignmentsContentProbeExtensionlessLocalMedia() throws {
        let implementation = try String(
            repositoryFile: "Sources/BackgroundEngineCore/Compatibility.swift"
        )
        XCTAssertFalse(
            implementation.contains("ImageWallpaperValidation.isPlayableImage"),
            "Web dependency analysis must never fully decode an image."
        )
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try Data("OggS\0synthetic".utf8).write(to: root.appending(path: "stream"))
        try Data("OggS\0encoded".utf8).write(to: root.appending(path: "clip.ogg"))
        let png = try XCTUnwrap(
            Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        )
        try png.write(to: root.appending(path: "poster"))
        try "window.ready = true;".write(
            to: root.appending(path: "runtime"),
            atomically: true,
            encoding: .utf8
        )
        try #"""
        <script>
          player.src = 'stream';
          fallback.src = 'clip%2Eogg';
          image.src = 'poster';
          loader.src = 'runtime';
        </script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            Set(features.localMediaReferences.map { $0.sourceURL.lastPathComponent }),
            ["clip.ogg", "stream"]
        )
        XCTAssertFalse(features.hasOpaqueOrDynamicMediaReferences)
        XCTAssertTrue(features.missingLocalMediaReferences.isEmpty)
    }

    func testOpaqueOrDynamicJavaScriptMediaIsLimitedWhileRuntimeDiscoveryIsPending() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <video src="{{ selectedVideo }}"></video>
        <script>
          new Audio(selectSoundtrack());
          player.src = selectedVideo;
          player.setAttribute('src', selectFallback());
        </script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

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

        XCTAssertTrue(features.hasOpaqueOrDynamicMediaReferences)
        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .webLive)
        XCTAssertEqual(report.diagnosticCode, "web_dynamic_media_runtime_pending")
        XCTAssertTrue(report.warnings.contains { $0.contains("runtime safety limits") })
        XCTAssertTrue(report.missingCapabilities.isEmpty)
    }

    func testBracketJQueryAndObjectSourceShapesTriggerDynamicMediaDiscovery() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <script>
          video["src"] = selectedVideo;
          $(audio).attr("src", selectedTrack);
          const options = { src: selectedFallback };
          const quoted = { "src": selectAnotherFallback() };
        </script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertTrue(features.localMediaReferences.isEmpty)
        XCTAssertTrue(features.hasOpaqueOrDynamicMediaReferences)
    }

    func testBracketJQueryAndObjectLiteralSourcesAreDiscoveredStatically() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        for name in ["bracket.webm", "jquery.ogg", "object.mkv", "quoted.avi"] {
            try Data("media".utf8).write(to: root.appending(path: name))
        }
        try #"""
        <script>
          video["src"] = "bracket.webm";
          $(audio).attr("src", "jquery.ogg");
          const options = { src: "object.mkv", "src": "quoted.avi" };
        </script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            Set(features.localMediaReferences.map { $0.sourceURL.lastPathComponent }),
            ["bracket.webm", "jquery.ogg", "object.mkv", "quoted.avi"]
        )
        XCTAssertFalse(features.hasOpaqueOrDynamicMediaReferences)
    }

    func testJavaScriptMediaShapesInsideCommentsStringsAndRegexpsRemainInert() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <script>
          // new Audio('comment.ogg'); player.src = dynamicValue;
          const example = "player.setAttribute('src', dynamicValue)";
          // video["src"] = selectedVideo; $(audio).attr("src", selectedTrack);
          const objectExample = "const options = { src: selectedFallback };";
          const pattern = /new Audio\(selectedTrack\)/;
        </script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

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

        XCTAssertTrue(features.localMediaReferences.isEmpty)
        XCTAssertFalse(features.hasOpaqueOrDynamicMediaReferences)
        XCTAssertEqual(report.level, .full)
    }

    func testWebIframeDependenciesReportRemoteMissingTraversalAndSymlinkEscape() throws {
        let parent = try Fixture.makeTempDirectory()
        let root = parent.appending(path: "project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = parent.appending(path: "outside-frame.html")
        try "<!doctype html>".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "linked-frame.html"),
            withDestinationURL: outside
        )
        let entrypoint = root.appending(path: "index.html")
        try """
        <iframe src="missing-frame.html"></iframe>
        <iframe src="../outside-frame.html"></iframe>
        <iframe src="linked-frame.html"></iframe>
        <iframe src="https://frames.example.test/live.html"></iframe>
        <iframe src="about:blank"></iframe>
        """.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            features.missingLocalDependencies,
            ["../outside-frame.html", "linked-frame.html", "missing-frame.html"]
        )
        XCTAssertEqual(
            features.remoteDependencies,
            ["https://frames.example.test/live.html"]
        )
        XCTAssertFalse(features.dependencyAnalysisLimitExceeded)
    }

    func testWebIframeRecursionDepthIsBoundedAndFailsClosed() throws {
        let root = try Fixture.makeTempDirectory()
        let frames = root.appending(path: "frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let frameCount = WebRuntimeFeatureAnalyzer.maximumHTMLNestingDepth + 1
        for index in 0..<frameCount {
            let source = index + 1 < frameCount
                ? #"<iframe src="frame-\#(index + 1).html"></iframe>"#
                : "<!doctype html>"
            try source.write(
                to: frames.appending(path: "frame-\(index).html"),
                atomically: true,
                encoding: .utf8
            )
        }
        let entrypoint = root.appending(path: "index.html")
        try #"<iframe src="frames/frame-0.html"></iframe>"#
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

        XCTAssertTrue(features.dependencyAnalysisLimitExceeded)
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertEqual(report.diagnosticCode, "web_dependency_probe_limit_exceeded")
    }

    func testWebIframeDocumentCountIsBoundedAtConfiguredLimit() throws {
        let root = try Fixture.makeTempDirectory()
        let frames = root.appending(path: "frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for index in 0..<WebRuntimeFeatureAnalyzer.maximumHTMLDocuments {
            try "<!doctype html>".write(
                to: frames.appending(path: "frame-\(index).html"),
                atomically: true,
                encoding: .utf8
            )
        }
        let entrypoint = root.appending(path: "index.html")
        let references = (0..<WebRuntimeFeatureAnalyzer.maximumHTMLDocuments).map {
            #"<iframe src="frames/frame-\#($0).html"></iframe>"#
        }
        try references.dropLast().joined(separator: "\n")
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let boundary = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        XCTAssertFalse(boundary.dependencyAnalysisLimitExceeded)

        try references.joined(separator: "\n")
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let exceeded = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        XCTAssertTrue(exceeded.dependencyAnalysisLimitExceeded)
    }

    func testWebIframeDocumentsShareAggregateTextByteBudget() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<iframe src="large-frame.html"></iframe>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try Data(
            repeating: 0x20,
            count: WebRuntimeFeatureAnalyzer.maximumDependencyTextBytes
        ).write(to: root.appending(path: "large-frame.html"), options: .atomic)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertTrue(features.dependencyAnalysisLimitExceeded)
    }

    func testNestedMediaSourcesInheritContainerAndIgnorePictureOrOrphanSources() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        for name in ["audio-only.ogg", "orphan.ogg", "picture.webp", "video.ogv"] {
            try Data([1]).write(to: root.appending(path: name))
        }
        try """
        <video><source src="video.ogv"></video>
        <audio><source src="audio-only.ogg"></audio>
        <picture><source src="picture.webp" type="image/webp"></picture>
        <source src="orphan.ogg">
        """.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let kinds = Dictionary(
            uniqueKeysWithValues: features.localMediaReferences.map {
                ($0.sourceURL.lastPathComponent, $0.elementKind)
            }
        )

        XCTAssertEqual(kinds["video.ogv"], .video)
        XCTAssertEqual(kinds["audio-only.ogg"], .audio)
        XCTAssertNil(kinds["picture.webp"])
        XCTAssertNil(kinds["orphan.ogg"])
    }

    func testAudioOnlySourceInsideVideoIsNotAcceptedAsDirectVideo() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try Data([1]).write(to: root.appending(path: "audio-only.ogg"))
        try #"<video><source src="audio-only.ogg"></video>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let analyzer = WallpaperCompatibilityAnalyzer(
            webMediaPlaybackProbe: WebMediaPlaybackProbe { reference in
                reference.elementKind == .audio
            }
        )

        let report = analyzer.analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(report.level, .full)
        XCTAssertEqual(report.diagnosticCode, "web_static_media_needs_preparation")
    }

    func testWebStaticMediaDiscoveryIgnoresInertMarkupAndInlineSources() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try """
        <!doctype html>
        <!-- <video src="comment.ogv"></video> -->
        <template><audio src="template.ogg"></audio></template>
        <noscript><video src="noscript.ogv"></video></noscript>
        <textarea><source src="textarea.webm"></textarea>
        <video src="data:video/mp4;base64,AAAA"></video>
        <audio src="blob:https://example.test/runtime"></audio>
        """.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertTrue(features.localMediaReferences.isEmpty)
        XCTAssertTrue(features.missingLocalMediaReferences.isEmpty)
        XCTAssertTrue(features.remoteMediaReferences.isEmpty)
    }

    func testWebStaticMediaRejectsMissingTraversalAndSymlinkEscape() throws {
        let parent = try Fixture.makeTempDirectory()
        let root = parent.appending(path: "project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = parent.appending(path: "outside.ogv")
        try Data([1, 2, 3]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "linked.ogv"),
            withDestinationURL: outside
        )
        let entrypoint = root.appending(path: "index.html")
        try """
        <video src="../outside.ogv"></video>
        <audio src="missing.ogg"></audio>
        <video><source src="linked.ogv"></video>
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

        XCTAssertTrue(features.localMediaReferences.isEmpty)
        XCTAssertEqual(
            features.missingLocalMediaReferences,
            ["../outside.ogv", "linked.ogv", "missing.ogg"]
        )
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertNil(report.playbackPath)
        XCTAssertEqual(report.diagnosticCode, "web_static_media_missing")
    }

    func testMissingStaticMediaWithKnownLocalFallbackIsLimitedInsteadOfUnsupported() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let fallback = root.appending(path: "fallback.mp4")
        try Data([1, 2, 3]).write(to: fallback)
        try #"<video><source src="missing.webm"><source src="fallback.mp4"></video>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let analyzer = WallpaperCompatibilityAnalyzer(
            webMediaPlaybackProbe: WebMediaPlaybackProbe { $0.sourceURL == fallback }
        )
        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        let report = analyzer.analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertTrue(features.missingLocalMediaHasProvenFallback)
        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .webLive)
        XCTAssertEqual(report.diagnosticCode, "web_static_media_missing")
        XCTAssertTrue(report.warnings.contains { $0.contains("remains available") })
    }

    func testConditionalLocalSourceDoesNotProveFallbackForMissingSibling() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let conditional = root.appending(path: "conditional.mp4")
        try Data([1, 2, 3]).write(to: conditional)
        try #"<video><source src="missing.webm"><source media="(min-width: 99999px)" src="conditional.mp4"></video>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let report = WallpaperCompatibilityAnalyzer(
            webMediaPlaybackProbe: WebMediaPlaybackProbe { $0.sourceURL == conditional }
        ).analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(features.localMediaReferences.map(\.rawReference), ["conditional.mp4"])
        XCTAssertFalse(features.missingLocalMediaHasProvenFallback)
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertNil(report.playbackPath)
        XCTAssertEqual(report.diagnosticCode, "web_static_media_missing")
    }

    func testConditionalMissingSourceDoesNotBlockUnconditionalLocalFallback() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let fallback = root.appending(path: "fallback.mp4")
        try Data([1, 2, 3]).write(to: fallback)
        try #"<video><source media="(min-width: 99999px)" src="missing.webm"><source src="fallback.mp4"></video>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let report = WallpaperCompatibilityAnalyzer(
            webMediaPlaybackProbe: WebMediaPlaybackProbe { $0.sourceURL == fallback }
        ).analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertTrue(features.missingLocalMediaHasProvenFallback)
        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .webLive)
        XCTAssertEqual(report.diagnosticCode, "web_static_media_missing")
    }

    func testUnconditionalDuplicateCanProveFallbackAfterConditionalSource() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let fallback = root.appending(path: "fallback.mp4")
        try Data([1, 2, 3]).write(to: fallback)
        try #"<video><source src="missing.webm"><source media="(min-width: 99999px)" src="fallback.mp4"><source src="fallback.mp4"></video>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let report = WallpaperCompatibilityAnalyzer(
            webMediaPlaybackProbe: WebMediaPlaybackProbe { $0.sourceURL == fallback }
        ).analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(features.localMediaReferences.count, 1)
        XCTAssertTrue(features.missingLocalMediaHasProvenFallback)
        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .webLive)
    }

    func testAuthoredVideoSourceMakesChildLocalSourceInert() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try Data([1, 2, 3]).write(to: root.appending(path: "ignored-fallback.mp4"))
        try #"<video src="missing.webm"><source src="ignored-fallback.mp4"></video>"#
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

        XCTAssertTrue(features.localMediaReferences.isEmpty)
        XCTAssertFalse(features.missingLocalMediaHasProvenFallback)
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertNil(report.playbackPath)
        XCTAssertEqual(report.diagnosticCode, "web_static_media_missing")
    }

    func testUnrelatedLocalAudioDoesNotMaskMissingVideo() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let soundtrack = root.appending(path: "soundtrack.mp3")
        try Data([1, 2, 3]).write(to: soundtrack)
        try #"<video src="missing.webm"></video><audio src="soundtrack.mp3"></audio>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let analyzer = WallpaperCompatibilityAnalyzer(
            webMediaPlaybackProbe: WebMediaPlaybackProbe { $0.sourceURL == soundtrack }
        )

        let report = analyzer.analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertFalse(features.missingLocalMediaHasProvenFallback)
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertNil(report.playbackPath)
        XCTAssertEqual(report.diagnosticCode, "web_static_media_missing")
    }

    func testUnrelatedHTMLMediaDoesNotMaskUngroupedJavaScriptMissingSource() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try Data([1, 2, 3]).write(to: root.appending(path: "soundtrack.mp3"))
        try #"<audio src="soundtrack.mp3"></audio><script>player.src = 'missing.webm';</script>"#
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

        XCTAssertFalse(features.missingLocalMediaHasProvenFallback)
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertEqual(report.diagnosticCode, "web_static_media_missing")
    }

    func testWebStaticMediaClassificationUsesInjectedPlaybackProbe() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        for name in ["direct.mp4", "convert.ogv"] {
            try Data([1, 2, 3]).write(to: root.appending(path: name))
        }
        try #"<video src="direct.mp4"></video><video src="convert.ogv"></video>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)

        let analyzer = WallpaperCompatibilityAnalyzer(
            webMediaPlaybackProbe: WebMediaPlaybackProbe { reference in
                reference.sourceURL.pathExtension == "mp4"
            }
        )
        let report = analyzer.analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(report.level, .full)
        XCTAssertEqual(report.playbackPath, .webLive)
        XCTAssertEqual(report.diagnosticCode, "web_static_media_needs_preparation")
        XCTAssertTrue(report.warnings.contains { $0.contains("converted") })
    }

    func testDirectlyPlayableWebStaticMediaRemainsFullLive() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try Data([1, 2, 3]).write(to: root.appending(path: "loop.mp4"))
        try #"<video src="loop.mp4"></video>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)

        let analyzer = WallpaperCompatibilityAnalyzer(
            webMediaPlaybackProbe: WebMediaPlaybackProbe { _ in true }
        )
        let report = analyzer.analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(report.level, .full)
        XCTAssertEqual(report.playbackPath, .webLive)
        XCTAssertTrue(report.requiredCapabilities.isEmpty)
        XCTAssertTrue(report.missingCapabilities.isEmpty)
        XCTAssertNil(report.diagnosticCode)
    }

    func testWebRemoteStaticMediaRequiresNetworkInsteadOfClaimingLimitedPlayback() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<video src="https://media.example.test/loop.webm"></video>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)

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
        XCTAssertNil(blocked.playbackPath)
        XCTAssertEqual(blocked.requiredCapabilities, [.externalNetwork])
        XCTAssertEqual(blocked.missingCapabilities, [.externalNetwork])
        XCTAssertEqual(blocked.diagnosticCode, "web_network_access_required")
        XCTAssertEqual(allowed.level, .full)
        XCTAssertEqual(allowed.requiredCapabilities, [.externalNetwork])
        XCTAssertEqual(allowed.missingCapabilities, [])
        XCTAssertNil(allowed.diagnosticCode)
    }

    func testRemoteStaticMediaWithKnownLocalFallbackIsLimitedWhileNetworkIsBlocked() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let fallback = root.appending(path: "fallback.mp4")
        try Data([1, 2, 3]).write(to: fallback)
        try #"<video><source src="https://media.example.test/loop.webm"><source src="fallback.mp4"></video>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let analyzer = WallpaperCompatibilityAnalyzer(
            webMediaPlaybackProbe: WebMediaPlaybackProbe { $0.sourceURL == fallback }
        )
        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        let report = analyzer.analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertTrue(features.remoteMediaHasProvenFallback)
        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .webLive)
        XCTAssertEqual(report.requiredCapabilities, [.externalNetwork])
        XCTAssertEqual(report.missingCapabilities, [.externalNetwork])
        XCTAssertEqual(report.diagnosticCode, "web_static_media_network_limited")
    }

    func testAuthoredRemoteVideoSourceMakesChildLocalSourceInert() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try Data([1, 2, 3]).write(to: root.appending(path: "ignored-fallback.mp4"))
        try #"<video src="https://media.example.test/loop.webm"><source src="ignored-fallback.mp4"></video>"#
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

        XCTAssertTrue(features.localMediaReferences.isEmpty)
        XCTAssertFalse(features.remoteMediaHasProvenFallback)
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertNil(report.playbackPath)
        XCTAssertEqual(report.diagnosticCode, "web_network_access_required")
    }

    func testUnrelatedLocalAudioDoesNotMaskBlockedRemoteVideo() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let soundtrack = root.appending(path: "soundtrack.mp3")
        try Data([1, 2, 3]).write(to: soundtrack)
        try #"<video src="https://media.example.test/loop.webm"></video><audio src="soundtrack.mp3"></audio>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let analyzer = WallpaperCompatibilityAnalyzer(
            webMediaPlaybackProbe: WebMediaPlaybackProbe { $0.sourceURL == soundtrack }
        )

        let report = analyzer.analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertFalse(features.remoteMediaHasProvenFallback)
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertNil(report.playbackPath)
        XCTAssertEqual(report.diagnosticCode, "web_network_access_required")
    }

    func testUnrelatedHTMLMediaDoesNotMaskUngroupedJavaScriptRemoteSource() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try Data([1, 2, 3]).write(to: root.appending(path: "soundtrack.mp3"))
        try #"<audio src="soundtrack.mp3"></audio><script>player.src = 'https://media.example.test/loop.webm';</script>"#
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

        XCTAssertFalse(features.remoteMediaHasProvenFallback)
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertEqual(report.diagnosticCode, "web_network_access_required")
    }

    func testProtocolRelativeDependenciesAndMediaRequireExternalNetwork() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <script src="//cdn.example.test/runtime.js"></script>
        <video src="//media.example.test/loop.webm"></video>
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

        XCTAssertEqual(features.remoteDependencies, ["//cdn.example.test/runtime.js"])
        XCTAssertEqual(features.remoteMediaReferences, ["//media.example.test/loop.webm"])
        XCTAssertTrue(features.missingLocalDependencies.isEmpty)
        XCTAssertTrue(features.missingLocalMediaReferences.isEmpty)
        XCTAssertEqual(blocked.level, .unsupported)
        XCTAssertEqual(blocked.diagnosticCode, "web_network_access_required")
        XCTAssertEqual(allowed.level, .full)
        XCTAssertEqual(allowed.requiredCapabilities, [.externalNetwork])
    }

    func testWebStaticMediaLimitDoesNotHideLaterRequiredDependencyFailure() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let mediaElements = (0...WebRuntimeFeatureAnalyzer.maximumStaticMediaReferences)
            .map { #"<video src="missing-\#($0).ogv"></video>"# }
            .joined(separator: "\n")
        try (mediaElements + #"<script src="missing-runtime.js"></script>"#)
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

        XCTAssertTrue(features.mediaAnalysisLimitExceeded)
        XCTAssertEqual(features.missingLocalDependencies, ["missing-runtime.js"])
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertEqual(report.diagnosticCode, "web_local_dependency_missing")
    }

    func testWebStaticMediaLimitFailsClosedForMoreThanSixtyFourUniqueCanonicalSources() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        var elements = [String]()
        for index in 0...WebRuntimeFeatureAnalyzer.maximumStaticMediaReferences {
            let name = "clip-\(index).ogv"
            try Data([UInt8(index % 255)]).write(to: root.appending(path: name))
            elements.append(#"<video src="\#(name)"></video>"#)
        }
        try elements.joined(separator: "\n")
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

        XCTAssertTrue(features.mediaAnalysisLimitExceeded)
        XCTAssertEqual(
            features.localMediaReferences.count,
            WebRuntimeFeatureAnalyzer.maximumStaticMediaReferences
        )
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertNil(report.playbackPath)
        XCTAssertEqual(report.diagnosticCode, "web_static_media_probe_limit_exceeded")
    }

    func testWebStaticMediaLimitDeduplicatesAliasesOfTheSameCanonicalSource() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try Data([1, 2, 3]).write(to: root.appending(path: "loop.ogv"))
        let elements = (0...WebRuntimeFeatureAnalyzer.maximumStaticMediaReferences).map {
            let reference = String(repeating: "./", count: $0 + 1) + "loop.ogv"
            return #"<video src="\#(reference)"></video>"#
        }
        try elements.joined(separator: "\n")
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let analyzer = WallpaperCompatibilityAnalyzer(
            webMediaPlaybackProbe: WebMediaPlaybackProbe { _ in true }
        )

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let report = analyzer.analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertFalse(features.mediaAnalysisLimitExceeded)
        XCTAssertEqual(features.localMediaReferences.count, 1)
        XCTAssertEqual(
            Set(features.localMediaReferences.map { $0.sourceURL.path }).count,
            1
        )
        XCTAssertEqual(report.level, .full)
    }

    func testWebMediaReferenceSortUsesRawReferenceAsDeterministicTieBreak() {
        let source = URL(filePath: "/tmp/deterministic-media.ogv")
        let features = WebRuntimeFeatures(
            localMediaReferences: [
                WebLocalMediaReference(
                    elementKind: .video,
                    rawReference: "z.ogv",
                    sourceURL: source
                ),
                WebLocalMediaReference(
                    elementKind: .video,
                    rawReference: "a.ogv",
                    sourceURL: source
                )
            ]
        )

        XCTAssertEqual(features.localMediaReferences.map(\.rawReference), ["a.ogv", "z.ogv"])
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
            ["/scripts/local.js"]
        )
        XCTAssertEqual(features.remoteDependencies, ["//cdn.example.com/runtime.js"])
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

    func testInlineImportMapResolvesLivelyMusicTVStyleLocalModulesTransitively() throws {
        let root = try Fixture.makeTempDirectory()
        let modules = root.appending(path: "js/threejs/jsm/controls")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try "export const Scene = {};".write(
            to: root.appending(path: "js/threejs/three.module.js"),
            atomically: true,
            encoding: .utf8
        )
        try #"import { Scene } from "three"; export const controls = Scene;"#.write(
            to: modules.appending(path: "OrbitControls.js"),
            atomically: true,
            encoding: .utf8
        )
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <script type="importmap">
        {"imports":{"three":"./js/threejs/three.module.js","three/addons/":"./js/threejs/jsm/"}}
        </script>
        <script type="module">
        import * as THREE from "three";
        import { controls } from "three/addons/controls/OrbitControls.js";
        console.log(THREE, controls);
        </script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

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
        XCTAssertTrue(features.unmappedBareModuleSpecifiers.isEmpty)
        XCTAssertNil(features.importMapDiagnosticCode)
        XCTAssertEqual(report.level, .full)
        XCTAssertEqual(report.playbackPath, .webLive)
    }

    func testImportMapMissingLocalTargetFailsClosed() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <script type="importmap">{"imports":{"wallpaper-runtime":"./js/missing.js"}}</script>
        <script type="module">import "wallpaper-runtime";</script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

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

        XCTAssertEqual(features.missingLocalDependencies, ["./js/missing.js"])
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertEqual(report.diagnosticCode, "web_local_dependency_missing")
    }

    func testImportMapRemoteTargetRequiresPerWallpaperNetworkOptIn() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <script type="importmap">
        {"imports":{"wallpaper-runtime":"https://cdn.example.test/runtime.mjs"}}
        </script>
        <script type="module">import "wallpaper-runtime";</script>
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

        XCTAssertEqual(features.remoteDependencies, ["https://cdn.example.test/runtime.mjs"])
        XCTAssertEqual(blocked.level, .unsupported)
        XCTAssertEqual(blocked.diagnosticCode, "web_network_access_required")
        XCTAssertEqual(allowed.level, .full)
        XCTAssertEqual(allowed.requiredCapabilities, [.externalNetwork])
    }

    func testImportMapPrefixUsesLongestMatchingTrailingSlashMapping() throws {
        let root = try Fixture.makeTempDirectory()
        try FileManager.default.createDirectory(
            at: root.appending(path: "specific/tools"),
            withIntermediateDirectories: true
        )
        try "export const render = () => {};".write(
            to: root.appending(path: "specific/tools/render.js"),
            atomically: true,
            encoding: .utf8
        )
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <script type="importmap">
        {"imports":{"vendor/":"./generic/","vendor/tools/":"./specific/tools/"}}
        </script>
        <script type="module">export { render } from "vendor/tools/render.js";</script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertTrue(features.missingLocalDependencies.isEmpty)
        XCTAssertTrue(features.unmappedBareModuleSpecifiers.isEmpty)
        XCTAssertNil(features.importMapDiagnosticCode)
    }

    func testImportMapRejectsBareRelativeAddressAndPrefixBacktracking() throws {
        let cases: [(name: String, map: String, module: String, files: [String])] = [
            (
                "bare relative address",
                #"{"imports":{"runtime":"js/runtime.js"}}"#,
                #"import "runtime";"#,
                ["js/runtime.js"]
            ),
            (
                "prefix backtracking",
                #"{"imports":{"pkg/":"./vendor/pkg/"}}"#,
                #"import "pkg/../safe.js";"#,
                ["vendor/safe.js"]
            )
        ]

        for item in cases {
            let root = try Fixture.makeTempDirectory()
            for relativePath in item.files {
                let file = root.appending(path: relativePath)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try "export default {};".write(to: file, atomically: true, encoding: .utf8)
            }
            let entrypoint = root.appending(path: "index.html")
            try (
                "<script type=\"importmap\">\(item.map)</script>"
                    + "<script type=\"module\">\(item.module)</script>"
            ).write(to: entrypoint, atomically: true, encoding: .utf8)

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

            XCTAssertEqual(features.importMapDiagnosticCode, "web_import_map_unsafe", item.name)
            XCTAssertEqual(report.level, .unsupported, item.name)
            XCTAssertEqual(report.diagnosticCode, "web_import_map_unsafe", item.name)
        }
    }

    func testMacOSFourteenImportMapBaselineFailsClosedForMultipleOrLateMaps() throws {
        let cases: [(name: String, body: String)] = [
            (
                "multiple maps",
                #"<script type="importmap">{"imports":{"one":"./one.js"}}</script><script type="importmap">{"imports":{"two":"./two.js"}}</script>"#
            ),
            (
                "map after module",
                #"<script type="module">console.log("started")</script><script type="importmap">{"imports":{"runtime":"./runtime.js"}}</script>"#
            )
        ]

        for item in cases {
            let root = try Fixture.makeTempDirectory()
            let entrypoint = root.appending(path: "index.html")
            try item.body.write(to: entrypoint, atomically: true, encoding: .utf8)

            let report = WallpaperCompatibilityAnalyzer().analyze(
                kind: .web,
                status: .playable,
                entrypoint: entrypoint,
                projectRoot: root
            )

            XCTAssertEqual(report.level, .unsupported, item.name)
            XCTAssertEqual(report.diagnosticCode, "web_import_map_unsafe", item.name)
        }
    }

    func testImportMapSupportsURLLikeKeysAndLongestMatchingScope() throws {
        let root = try Fixture.makeTempDirectory()
        let feature = root.appending(path: "feature")
        try FileManager.default.createDirectory(at: feature, withIntermediateDirectories: true)
        try "export const replacement = true;".write(
            to: root.appending(path: "replacement.js"),
            atomically: true,
            encoding: .utf8
        )
        try "export const globalRuntime = true;".write(
            to: root.appending(path: "global.js"),
            atomically: true,
            encoding: .utf8
        )
        try "export const scopedRuntime = true;".write(
            to: root.appending(path: "scoped.js"),
            atomically: true,
            encoding: .utf8
        )
        try #"import "runtime"; export const consumer = true;"#.write(
            to: feature.appending(path: "consumer.js"),
            atomically: true,
            encoding: .utf8
        )
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <script type="importmap">
        {
          "imports": {
            "./runtime.js": "./replacement.js",
            "runtime": "./global.js"
          },
          "scopes": {
            "./feature/": { "runtime": "./scoped.js" }
          }
        }
        </script>
        <script type="module">
        import "./runtime.js";
        import "./feature/consumer.js";
        </script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

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
        XCTAssertTrue(features.unmappedBareModuleSpecifiers.isEmpty)
        XCTAssertNil(features.importMapDiagnosticCode)
        XCTAssertEqual(report.level, .full)
        XCTAssertEqual(report.playbackPath, .webLive)
    }

    func testInlineImportMapURLLikeKeyUsesEffectiveDocumentBase() throws {
        let root = try Fixture.makeTempDirectory()
        let app = root.appending(path: "app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "export const replacement = true;".write(
            to: app.appending(path: "replacement.js"),
            atomically: true,
            encoding: .utf8
        )
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <base href="./app/">
        <script type="importmap">
        { "imports": { "./runtime.js": "./replacement.js" } }
        </script>
        <script type="module">import "./runtime.js";</script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

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
        XCTAssertTrue(features.unmappedBareModuleSpecifiers.isEmpty)
        XCTAssertNil(features.importMapDiagnosticCode)
        XCTAssertEqual(report.level, .full)
        XCTAssertEqual(report.playbackPath, .webLive)
    }

    func testUnusedNullImportMapEntryDoesNotRejectPageButReferencedEntryDoes() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<script type="importmap">{"imports":{"blocked":null}}</script><script type="module">console.log("ready")</script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)

        let unused = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )
        XCTAssertEqual(unused.level, .full)

        try #"<script type="importmap">{"imports":{"blocked":null}}</script><script type="module">import "blocked";</script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let referenced = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )
        XCTAssertEqual(referenced.level, .unsupported)
        XCTAssertEqual(referenced.diagnosticCode, "web_import_map_unsafe")
    }

    func testBlockedExternalHostsNeverBecomeFullAfterNetworkOptIn() throws {
        let blockedTargets = [
            "http://localhost:8080/runtime.js",
            "https://device.local/runtime.js",
            "https://10.0.0.1/runtime.js",
            "https://100.64.1.2/runtime.js",
            "https://169.254.2.3/runtime.js",
            "https://192.168.1.5/runtime.js",
            "http://0x7f000001/runtime.js",
            "http://0x7f.0.0.1/runtime.js",
            "https://[fd00::1]/runtime.js",
            "https://[::ffff:8.8.8.8]/runtime.js"
        ]

        for target in blockedTargets {
            let root = try Fixture.makeTempDirectory()
            let entrypoint = root.appending(path: "index.html")
            try #"<script type="importmap">{"imports":{"runtime":"TARGET"}}</script><script type="module">import "runtime";</script>"#
                .replacingOccurrences(of: "TARGET", with: target)
                .write(to: entrypoint, atomically: true, encoding: .utf8)

            let report = WallpaperCompatibilityAnalyzer().analyze(
                kind: .web,
                status: .playable,
                entrypoint: entrypoint,
                projectRoot: root,
                networkAccessAllowed: true
            )

            XCTAssertEqual(report.level, .unsupported, target)
            XCTAssertEqual(report.diagnosticCode, "web_private_network_blocked", target)
        }

        let publicRoot = try Fixture.makeTempDirectory()
        let publicEntrypoint = publicRoot.appending(path: "index.html")
        try #"<script type="module" src="https://8.8.8.8/runtime.js"></script>"#
            .write(to: publicEntrypoint, atomically: true, encoding: .utf8)
        let publicReport = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: publicEntrypoint,
            projectRoot: publicRoot,
            networkAccessAllowed: true
        )
        XCTAssertEqual(publicReport.level, .full)
        XCTAssertEqual(publicReport.playbackPath, .webLive)

        for host in [
            "0x.org",
            "api.0xprotocol.example",
            "0xdead.beef",
            "1.0xdead.beef"
        ] {
            let root = try Fixture.makeTempDirectory()
            let entrypoint = root.appending(path: "index.html")
            try "<script src=\"https://\(host)/runtime.js\"></script>"
                .write(to: entrypoint, atomically: true, encoding: .utf8)
            let report = WallpaperCompatibilityAnalyzer().analyze(
                kind: .web,
                status: .playable,
                entrypoint: entrypoint,
                projectRoot: root,
                networkAccessAllowed: true
            )
            XCTAssertEqual(report.level, .full, host)
            XCTAssertEqual(report.playbackPath, .webLive, host)
        }
    }

    func testProtocolRelativeDocumentBaseUsesRuntimeHTTPSOrigin() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try """
        <!doctype html>
        <base href="//cdn.example.test/wallpaper/">
        <script src="runtime.js"></script>
        """.write(to: entrypoint, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )
        let offline = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )
        let optedIn = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root,
            networkAccessAllowed: true
        )

        XCTAssertTrue(features.missingLocalDependencies.isEmpty)
        XCTAssertEqual(features.remoteDependencies, ["runtime.js"])
        XCTAssertEqual(offline.level, .unsupported)
        XCTAssertEqual(offline.diagnosticCode, "web_network_access_required")
        XCTAssertEqual(optedIn.level, .full)
        XCTAssertEqual(optedIn.playbackPath, .webLive)
    }

    func testLiteralFetchXHRWebSocketAndEventSourceFollowNetworkPolicy() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <script>
        fetch("https://fetch.example.test/data.json");
        const request = new XMLHttpRequest();
        request.open("GET", "https://xhr.example.test/data.json");
        new WebSocket("wss://socket.example.test/live");
        new EventSource("https://events.example.test/live");
        </script>
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
                "https://events.example.test/live",
                "https://fetch.example.test/data.json",
                "https://xhr.example.test/data.json",
                "wss://socket.example.test/live"
            ]
        )
        XCTAssertEqual(blocked.level, .unsupported)
        XCTAssertEqual(blocked.diagnosticCode, "web_network_access_required")
        XCTAssertEqual(allowed.level, .full)
        XCTAssertEqual(allowed.requiredCapabilities, [.externalNetwork])
    }

    func testLiteralPrivateAndDynamicNetworkRequestsNeverClaimFull() throws {
        let privateRoot = try Fixture.makeTempDirectory()
        let privateEntrypoint = privateRoot.appending(path: "index.html")
        try #"<script>fetch("http://127.0.0.1:8080/private");</script>"#
            .write(to: privateEntrypoint, atomically: true, encoding: .utf8)
        let privateReport = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: privateEntrypoint,
            projectRoot: privateRoot,
            networkAccessAllowed: true
        )
        XCTAssertEqual(privateReport.level, .unsupported)
        XCTAssertEqual(privateReport.diagnosticCode, "web_private_network_blocked")

        let dynamicRoot = try Fixture.makeTempDirectory()
        let dynamicEntrypoint = dynamicRoot.appending(path: "index.html")
        try #"<script>fetch(runtimeURL);</script>"#
            .write(to: dynamicEntrypoint, atomically: true, encoding: .utf8)
        let dynamicBlocked = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: dynamicEntrypoint,
            projectRoot: dynamicRoot
        )
        let dynamicAllowed = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: dynamicEntrypoint,
            projectRoot: dynamicRoot,
            networkAccessAllowed: true
        )
        XCTAssertEqual(dynamicBlocked.level, .limited)
        XCTAssertEqual(dynamicBlocked.missingCapabilities, [.externalNetwork])
        XCTAssertEqual(dynamicBlocked.diagnosticCode, "web_dynamic_network_runtime_pending")
        XCTAssertEqual(dynamicAllowed.level, .limited)
        XCTAssertTrue(dynamicAllowed.missingCapabilities.isEmpty)
        XCTAssertEqual(dynamicAllowed.diagnosticCode, "web_dynamic_network_runtime_pending")
    }

    func testLiteralLocalFetchMustRemainInsideProjectAndExist() throws {
        let root = try Fixture.makeTempDirectory()
        try #"{"ready":true}"#.write(
            to: root.appending(path: "data.json"),
            atomically: true,
            encoding: .utf8
        )
        let entrypoint = root.appending(path: "index.html")
        try #"<script>fetch("./data.json");</script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let available = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )
        XCTAssertEqual(available.level, .full)

        try #"<script>fetch("./missing.json");</script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let missing = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )
        XCTAssertEqual(missing.level, .unsupported)
        XCTAssertEqual(missing.diagnosticCode, "web_local_dependency_missing")
    }

    func testImageAndPictureCandidatesRemainRequiredAcrossDisplayScaleAndBlockPrivateTargets() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appending(path: "fallback.png"))
        try #"<img src="./missing.png">"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)

        let missing = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )
        XCTAssertEqual(missing.level, .unsupported)
        XCTAssertEqual(missing.diagnosticCode, "web_local_dependency_missing")

        try #"""
        <picture>
          <source srcset="./missing-wide.png 2x">
          <img src="./fallback.png" srcset="./fallback.png 1x, ./missing-retina.png 2x">
        </picture>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)
        let fallback = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )
        XCTAssertEqual(fallback.level, .unsupported)
        XCTAssertEqual(fallback.diagnosticCode, "web_local_dependency_missing")

        try #"""
        <picture>
          <source srcset="http://192.168.1.20/wide.png 2x">
          <img src="./fallback.png">
        </picture>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)
        let privateCandidate = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root,
            networkAccessAllowed: true
        )
        XCTAssertEqual(privateCandidate.level, .unsupported)
        XCTAssertEqual(privateCandidate.diagnosticCode, "web_private_network_blocked")
    }

    func testPublicImageRequiresNetworkPermissionAndCSSURLRecursesFromLinkedStylesheet() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<img src="https://images.example.test/background.png">"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)

        let offline = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )
        let optedIn = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root,
            networkAccessAllowed: true
        )
        XCTAssertEqual(offline.level, .unsupported)
        XCTAssertEqual(offline.diagnosticCode, "web_network_access_required")
        XCTAssertEqual(optedIn.level, .full)

        try #"<link rel="stylesheet" href="styles/main.css">"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let styles = root.appending(path: "styles")
        try FileManager.default.createDirectory(at: styles, withIntermediateDirectories: true)
        try #"body { background-image: url('../missing/background.png'); }"#
            .write(to: styles.appending(path: "main.css"), atomically: true, encoding: .utf8)
        let missingCSSResource = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: root
        )
        XCTAssertEqual(missingCSSResource.level, .unsupported)
        XCTAssertEqual(missingCSSResource.diagnosticCode, "web_local_dependency_missing")
    }

    func testInlineAndStyleAttributeCSSURLsUseSharedResourcePolicy() throws {
        for body in [
            #"<style>body { background: url('./missing-inline.png') }</style>"#,
            #"<main style="background: url('./missing-attribute.png')"></main>"#
        ] {
            let root = try Fixture.makeTempDirectory()
            let entrypoint = root.appending(path: "index.html")
            try body.write(to: entrypoint, atomically: true, encoding: .utf8)
            let report = WallpaperCompatibilityAnalyzer().analyze(
                kind: .web,
                status: .playable,
                entrypoint: entrypoint,
                projectRoot: root
            )
            XCTAssertEqual(report.level, .unsupported, body)
            XCTAssertEqual(report.diagnosticCode, "web_local_dependency_missing", body)
        }
    }

    func testXHRMethodShapesQualifiedWebSocketAndDynamicImportNeverClaimFull() throws {
        let cases: [(source: String, networkAllowed: Bool, level: CompatibilityLevel, code: String)] = [
            (
                #"const request = new XMLHttpRequest(); request.open("PROPFIND", "http://127.0.0.1/private");"#,
                true,
                .unsupported,
                "web_private_network_blocked"
            ),
            (
                #"const request = new window.XMLHttpRequest(); request.open(method, "https://xhr.example.test/data");"#,
                false,
                .unsupported,
                "web_network_access_required"
            ),
            (
                #"const request = new XMLHttpRequest(); request.open("GET", runtimeURL);"#,
                true,
                .limited,
                "web_dynamic_network_runtime_pending"
            ),
            (
                #"window.fetch("http://127.0.0.1/private");"#,
                true,
                .unsupported,
                "web_private_network_blocked"
            ),
            (
                #"navigator.sendBeacon("http://127.0.0.1/private", payload);"#,
                true,
                .unsupported,
                "web_private_network_blocked"
            ),
            (
                #"new window.WebSocket("ws://127.0.0.1/private");"#,
                true,
                .unsupported,
                "web_private_network_blocked"
            ),
            (
                #"import(packageURL);"#,
                true,
                .limited,
                "web_dynamic_network_runtime_pending"
            )
        ]
        for item in cases {
            let root = try Fixture.makeTempDirectory()
            let entrypoint = root.appending(path: "index.html")
            try "<script>\(item.source)</script>"
                .write(to: entrypoint, atomically: true, encoding: .utf8)
            let report = WallpaperCompatibilityAnalyzer().analyze(
                kind: .web,
                status: .playable,
                entrypoint: entrypoint,
                projectRoot: root,
                networkAccessAllowed: item.networkAllowed
            )
            XCTAssertEqual(report.level, item.level, item.source)
            XCTAssertEqual(report.diagnosticCode, item.code, item.source)
        }
    }

    func testWindowAndGenericOpenAreNotMisclassifiedAsXHR() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <script>
        window.open("https://example.test/help", "_blank");
        dialog.open(mode, "panel-name");
        database.open("READ", "record-name");
        dialog.open("GET", "panel.html");
        archive.open("POST", "./record.json");
        store.fetch("theme.json");
        metrics.sendBeacon("events.json", payload);
        </script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

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
        XCTAssertFalse(features.hasOpaqueOrDynamicNetworkReferences)
        XCTAssertEqual(report.level, .full)
        XCTAssertEqual(report.playbackPath, .webLive)
    }

    func testLocalWorkerEntrypointIsRuntimePendingInsteadOfFalseFull() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try "self.onmessage = () => {};".write(
            to: root.appending(path: "worker.js"),
            atomically: true,
            encoding: .utf8
        )
        try #"<script>new Worker("./worker.js");</script>"#
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

        XCTAssertTrue(features.missingLocalDependencies.isEmpty)
        XCTAssertTrue(features.hasOpaqueOrDynamicNetworkReferences)
        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .webLive)
        XCTAssertEqual(report.diagnosticCode, "web_dynamic_network_runtime_pending")
    }

    func testMalformedOversizedAndUnsafeImportMapsHaveStableDiagnostics() throws {
        let cases: [(body: String, module: String, code: String)] = [
            (#"{"imports":{"runtime":"./runtime.js",}}"#, "", "web_import_map_malformed"),
            (
                "{\"imports\":{},\"padding\":\""
                    + String(repeating: "x", count: WebRuntimeFeatureAnalyzer.maximumImportMapBytes)
                    + "\"}",
                "",
                "web_import_map_too_large"
            ),
            (
                #"{"imports":{"runtime":"../../outside.js"}}"#,
                #"<script type="module">import "runtime";</script>"#,
                "web_import_map_unsafe"
            )
        ]

        for item in cases {
            let root = try Fixture.makeTempDirectory()
            let entrypoint = root.appending(path: "index.html")
            try ("<script type=\"importmap\">\(item.body)</script>" + item.module)
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

            XCTAssertEqual(features.importMapDiagnosticCode, item.code)
            XCTAssertEqual(report.level, .unsupported)
            XCTAssertNil(report.playbackPath)
            XCTAssertEqual(report.diagnosticCode, item.code)
        }
    }

    func testBareModuleSpecifierWithoutImportMapFailsClosed() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"<script type="module">import "wallpaper-package";</script>"#
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

        XCTAssertEqual(features.unmappedBareModuleSpecifiers, ["wallpaper-package"])
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertEqual(report.diagnosticCode, "web_import_map_specifier_unmapped")
    }

    func testExecutableMousePointerTouchAndClickHandlersAreInteractionLimited() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <button onclick="chooseWallpaper()">Choose</button>
        <script>
        canvas.addEventListener("mousemove", updateParallax);
        addEventListener("wheel", zoomWallpaper);
        controls.on("pointerdown.controls", beginDrag);
        window.ontouchstart = beginTouch;
        </script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

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

        XCTAssertTrue(features.usesInteraction)
        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.requiredCapabilities, [.interaction])
        XCTAssertEqual(report.missingCapabilities, [.interaction])
        XCTAssertEqual(report.diagnosticCode, "web_interaction_limited")
    }

    func testComputedTemplateJQueryAndCSSInteractionShapesAreLimited() throws {
        let cases: [(name: String, source: String)] = [
            (
                "computed event property",
                #"<script>window["onclick"] = chooseWallpaper;</script>"#
            ),
            (
                "template literal event",
                #"<script>canvas.addEventListener(`pointermove`, updateParallax);</script>"#
            ),
            (
                "jQuery shorthand",
                #"<script>$(canvas).mousemove(updateParallax);</script>"#
            ),
            (
                "jQuery object on",
                #"<script>$(canvas).on({ pointerdown: beginDrag, wheel: zoom });</script>"#
            ),
            (
                "CSS interaction pseudo classes",
                #"<style>canvas:hover, button:active { opacity: 0.5; }</style>"#
            )
        ]

        for item in cases {
            let root = try Fixture.makeTempDirectory()
            let entrypoint = root.appending(path: "index.html")
            try item.source.write(to: entrypoint, atomically: true, encoding: .utf8)

            let report = WallpaperCompatibilityAnalyzer().analyze(
                kind: .web,
                status: .playable,
                entrypoint: entrypoint,
                projectRoot: root
            )

            XCTAssertEqual(report.level, .limited, item.name)
            XCTAssertEqual(report.missingCapabilities, [.interaction], item.name)
            XCTAssertEqual(report.diagnosticCode, "web_interaction_limited", item.name)
        }
    }

    func testProgrammaticNoArgumentClickAndNamedLibraryMethodsAreNotInteraction() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <script>
        button.click();
        renderer.mousemove();
        timeline.pointerdown();
        </script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

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

        XCTAssertFalse(features.usesInteraction)
        XCTAssertEqual(report.level, .full)
        XCTAssertTrue(report.missingCapabilities.isEmpty)
    }

    func testInteractionDetectorIgnoresCommentsStringsTemplatesAndDataScripts() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <!-- <button onclick="ignored()"> -->
        <template><button onpointerdown="ignored()">Ignored</button></template>
        <script type="application/json">
        {"code":"window.addEventListener('click', ignored)"}
        </script>
        <script>
        // window.addEventListener("mousemove", ignored);
        /* controls.on("touchstart", ignored); */
        const quoted = "document.addEventListener('pointermove', ignored)";
        const templateText = `element.onclick = ignored`;
        const data = { onclick: "metadata only" };
        const clickMethod = widget.click;
        widget.on({ ready: start });
        window.addEventListener(`resize`, resizeWallpaper);
        </script>
        <style>
        /* canvas:hover { opacity: 0; } */
        .label::before { content: ":active"; }
        </style>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

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

        XCTAssertFalse(features.usesInteraction)
        XCTAssertEqual(report.level, .full)
        XCTAssertTrue(report.missingCapabilities.isEmpty)
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

    func testDependencyDedupeScansSameCanonicalFileInHTMLJavaScriptAndCSSContexts() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let shared = root.appending(path: "shared.runtime")
        try #"""
        <iframe src="shared.runtime"></iframe>
        <script src="shared.runtime"></script>
        <link rel="stylesheet" href="shared.runtime">
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)
        try #"""
        <script src="missing-from-html.js"></script>
        import "./missing-from-javascript.js";
        @import "./missing-from-stylesheet.css";
        """#.write(to: shared, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: root
        )

        XCTAssertEqual(
            features.missingLocalDependencies,
            [
                "./missing-from-javascript.js",
                "./missing-from-stylesheet.css",
                "missing-from-html.js"
            ]
        )
        XCTAssertFalse(features.dependencyAnalysisLimitExceeded)
    }

    func testTransitiveDependencyLexerIgnoresCommentsStringsTemplatesAndOpaqueSpecifiers() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <script type="importmap">{"imports":{"wallpaper-package":"./package.js"}}</script>
        <script type="module" src="main.js"></script><link rel="stylesheet" href="main.css">
        """#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try "export default {};".write(
            to: root.appending(path: "package.js"),
            atomically: true,
            encoding: .utf8
        )
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

    func testSceneWithCorruptRequiredPackagedModelIsUnsupportedBeforeCacheRender() throws {
        let root = try Fixture.makeTempDirectory()
        let package = root.appending(path: "corrupt-model.pkg")
        try Fixture.writeScenePackage(
            to: package,
            sceneJSON: #"{"objects":[{"id":1,"name":"Broken image","image":"models/broken.json"}]}"#,
            extraEntries: [
                (path: "models/broken.json", data: Data("not json".utf8))
            ]
        )

        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .scene,
            status: .playable,
            entrypoint: package
        )

        XCTAssertEqual(report.level, .unsupported)
        XCTAssertNil(report.playbackPath)
        XCTAssertEqual(report.diagnosticCode, "scene_required_asset_unreadable")
        XCTAssertTrue(report.warnings.first?.contains("models/broken.json") == true)
    }

    func testSceneWithCorruptRequiredPackagedTextureIsUnsupportedBeforeCacheRender() throws {
        let root = try Fixture.makeTempDirectory()
        let package = root.appending(path: "corrupt-texture.pkg")
        try Fixture.writeScenePackage(
            to: package,
            sceneJSON: #"{"objects":[{"id":1,"name":"Broken image","image":"models/broken.json"}]}"#,
            extraEntries: [
                (
                    path: "models/broken.json",
                    data: Data(#"{"material":"materials/broken.json"}"#.utf8)
                ),
                (
                    path: "materials/broken.json",
                    data: Data(#"{"passes":[{"textures":["broken"]}]}"#.utf8)
                ),
                (path: "materials/broken.tex", data: Data([1, 2, 3]))
            ]
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: package)
        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .scene,
            status: .playable,
            entrypoint: package
        )

        XCTAssertEqual(features.unreadableRequiredAssetFiles, ["materials/broken.tex"])
        XCTAssertEqual(report.level, .unsupported)
        XCTAssertNil(report.playbackPath)
        XCTAssertEqual(report.diagnosticCode, "scene_required_asset_unreadable")
        XCTAssertTrue(report.warnings.first?.contains("materials/broken.tex") == true)
    }

    func testSceneWithUnknownPackagedTextureMagicRemainsRendererCandidate() throws {
        let root = try Fixture.makeTempDirectory()
        let package = root.appending(path: "unknown-texture-magic.pkg")
        try Fixture.writeScenePackage(
            to: package,
            sceneJSON: #"{"objects":[{"id":1,"name":"Renderer image","image":"models/future.json"}]}"#,
            extraEntries: [
                (
                    path: "models/future.json",
                    data: Data(#"{"material":"materials/future.json"}"#.utf8)
                ),
                (
                    path: "materials/future.json",
                    data: Data(#"{"passes":[{"shader":"basic","textures":["future"]}]}"#.utf8)
                ),
                (path: "materials/future.tex", data: Data("FUTURE0001\u{0}".utf8)),
                (path: "shaders/basic.vert", data: Data("void main() {}".utf8)),
                (path: "shaders/basic.frag", data: Data("void main() {}".utf8))
            ]
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: package)
        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .scene,
            status: .playable,
            entrypoint: package
        )

        XCTAssertTrue(features.unreadableRequiredAssetFiles.isEmpty)
        XCTAssertFalse(features.hasDependencyAnalysisUncertainty)
        XCTAssertFalse(features.hasAudioDependencyUncertainty)
        XCTAssertTrue(features.unresolvedRequiredAssetFiles.isEmpty)
        XCTAssertEqual(report.level, .full)
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
    }

    func testSceneWithMissingRequiredShaderIsLimitedRendererCandidate() throws {
        let root = try Fixture.makeTempDirectory()
        let package = root.appending(path: "missing-required-shader.pkg")
        try Fixture.writeScenePackage(
            to: package,
            sceneJSON: #"{"objects":[{"id":1,"name":"Renderer image","image":"models/future.json"}]}"#,
            extraEntries: [
                (
                    path: "models/future.json",
                    data: Data(#"{"material":"materials/future.json"}"#.utf8)
                ),
                (
                    path: "materials/future.json",
                    data: Data(#"{"passes":[{"textures":["future"]}]}"#.utf8)
                ),
                (path: "materials/future.tex", data: Data("FUTURE0001\u{0}".utf8))
            ]
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: package)
        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .scene,
            status: .playable,
            entrypoint: package
        )

        XCTAssertTrue(features.unreadableRequiredAssetFiles.isEmpty)
        XCTAssertTrue(features.hasDependencyAnalysisUncertainty)
        XCTAssertTrue(features.hasAudioDependencyUncertainty)
        XCTAssertTrue(
            features.unresolvedRequiredAssetFiles.contains(
                "materials/future.json#passes[0]#shader"
            )
        )
        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
        XCTAssertTrue(report.missingCapabilities.contains(.engineLayer))
        XCTAssertTrue(report.missingCapabilities.contains(.audioReactive))
        XCTAssertEqual(report.diagnosticCode, "scene_dependency_analysis_limited")
    }

    func testSceneWithCorruptRequiredPackagedMaterialIsUnsupportedBeforeCacheRender() throws {
        let root = try Fixture.makeTempDirectory()
        let package = root.appending(path: "corrupt-material.pkg")
        try Fixture.writeScenePackage(
            to: package,
            sceneJSON: #"{"objects":[{"id":1,"name":"Broken image","image":"models/broken.json"}]}"#,
            extraEntries: [
                (
                    path: "models/broken.json",
                    data: Data(#"{"material":"materials/broken.json"}"#.utf8)
                ),
                (path: "materials/broken.json", data: Data("not json".utf8))
            ]
        )

        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .scene,
            status: .playable,
            entrypoint: package
        )

        XCTAssertEqual(report.level, .unsupported)
        XCTAssertNil(report.playbackPath)
        XCTAssertEqual(report.diagnosticCode, "scene_required_asset_unreadable")
        XCTAssertTrue(report.warnings.first?.contains("materials/broken.json") == true)
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
        XCTAssertTrue(features.unreadableRequiredAssetFiles.isEmpty)
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
