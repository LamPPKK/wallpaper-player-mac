import Foundation
import XCTest
@testable import BackgroundEngineApp
@testable import BackgroundEngineCore

final class SceneVisibilityAndAudioPlaybackTests: XCTestCase {
    func testRuntimeAnalyzerIgnoresInvisibleObjectsAndEffects() {
        let scene: [String: Any] = [
            "objects": [
                [
                    "id": 1,
                    "name": "hidden-sound",
                    "visible": false,
                    "sound": ["sounds/hidden.ogg"],
                    "script": "new Date(); mouse.click(); registerAudioBuffers();"
                ],
                [
                    "id": 2,
                    "name": "hidden-particle",
                    "visible": ["value": false],
                    "particle": "particles/hidden.json"
                ],
                [
                    "id": 3,
                    "name": "visible-image",
                    "visible": true,
                    "image": "models/background.json",
                    "effects": [
                        [
                            "visible": false,
                            "file": "effects/hidden-bool/effect.json",
                            "script": "new Date(); mouse.click(); registerAudioBuffers();",
                            "passes": [[
                                "textures": [NSNull(), "masks/hidden-bool-mask"],
                                "constantshadervalues": ["strength": 1.0]
                            ]]
                        ],
                        [
                            "visible": ["value": false],
                            "file": "effects/hidden-wrapped/effect.json",
                            "script": "Date.now(); input.cursor; AudioBuffers;",
                            "passes": [[
                                "textures": [NSNull(), "masks/hidden-wrapped-mask"],
                                "constantshadervalues": ["speed": 2.0]
                            ]]
                        ]
                    ]
                ]
            ]
        ]
        let emptyPackage = ScenePackage(magic: "PKGV0007", entries: [], data: Data())

        let features = SceneRuntimeFeatureAnalyzer().analyze(package: emptyPackage, scene: scene)

        XCTAssertEqual(features.layers.map(\.name), ["visible-image"])
        XCTAssertEqual(features.layers.first?.effectFiles, [])
        XCTAssertEqual(features.layers.first?.scriptCount, 0)
        XCTAssertEqual(features.layers.first?.constantShaderValueKeys, [])
        XCTAssertFalse(features.requiresSoundRuntime)
        XCTAssertFalse(features.requiresParticleRuntime)
        XCTAssertFalse(features.requiresSceneScriptRuntime)
        XCTAssertFalse(features.requiresAudioAnalysis)
        XCTAssertFalse(features.requiresMaskedEffectComposition)
        XCTAssertFalse(features.requiresClockRuntime)
        XCTAssertFalse(features.requiresInteractionRuntime)
        XCTAssertFalse(features.requiresShaderPipeline)
    }

    func testDynamicFalseVisibilityIsClassifiedButUsesStoredDefaultForApproximation() throws {
        let scene: [String: Any] = [
            "objects": [
                [
                    "id": 1,
                    "name": "user-sound",
                    "visible": ["value": false, "user": "enableSound"],
                    "sound": ["sounds/user.ogg"],
                    "script": "new Date(); mouse.click(); registerAudioBuffers();"
                ],
                [
                    "id": 3,
                    "name": "script-visible-text",
                    "visible": [
                        "value": false,
                        "script": "export function update() { return thisScene.getLayer(1).visible; }"
                    ],
                    "text": "SCRIPT"
                ],
                [
                    "id": 2,
                    "name": "conditional-effect",
                    "image": "models/background.json",
                    "effects": [[
                        "visible": [
                            "value": false,
                            "user": ["name": "enableEffect", "condition": 1]
                        ],
                        "file": "effects/user/effect.json"
                    ]]
                ]
            ]
        ]
        let emptyPackage = ScenePackage(magic: "PKGV0007", entries: [], data: Data())

        let features = SceneRuntimeFeatureAnalyzer().analyze(package: emptyPackage, scene: scene)

        XCTAssertEqual(
            features.layers.map(\.name),
            ["user-sound", "script-visible-text", "conditional-effect"]
        )
        XCTAssertTrue(features.requiresSoundRuntime)
        XCTAssertTrue(features.requiresSceneScriptRuntime)
        XCTAssertTrue(features.requiresAudioAnalysis)
        XCTAssertTrue(features.requiresClockRuntime)
        XCTAssertTrue(features.requiresInteractionRuntime)
        XCTAssertTrue(features.requiresDynamicVisibilityRuntime)
        XCTAssertTrue(features.requiresShaderPipeline)
        XCTAssertEqual(features.layers.last?.effectFiles, ["effects/user/effect.json"])
        XCTAssertTrue(features.runtimeGaps.contains("dynamic-visibility-runtime"))

        let root = FileManager.default.temporaryDirectory
            .appending(path: "scene-user-visibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            entries: [
                (
                    "scene.json",
                    Data(
                        #"{"objects":[{"name":"User text","visible":{"value":false,"user":"showText"},"text":"USER"},{"name":"Script text","visible":{"value":false,"script":"export function update() { return true; }"},"text":"SCRIPT"}]}"#.utf8
                    )
                )
            ]
        )

        XCTAssertThrowsError(try SceneRenderPlanBuilder().buildLayout(url: packageURL)) { error in
            XCTAssertEqual(error as? SceneRenderPlanError, .noRenderableLayers)
        }
        XCTAssertTrue(SceneAudioExtractor.audioTracks(scene: scene).isEmpty)

        let packageFeatures = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
        let report = WallpaperCompatibilityAnalyzer().analyzeScene(
            entrypoint: packageURL,
            nativePlayable: false
        )
        XCTAssertEqual(packageFeatures.layers.map(\.name), ["User text", "Script text"])
        XCTAssertTrue(packageFeatures.requiresDynamicVisibilityRuntime)
        XCTAssertTrue(packageFeatures.requiresSceneScriptRuntime)
        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
        XCTAssertTrue(report.requiredCapabilities.contains(.interaction))
        XCTAssertTrue(report.missingCapabilities.contains(.interaction))
        XCTAssertTrue(report.missingCapabilities.contains(.sceneScript))
        XCTAssertEqual(report.diagnosticCode, "scene_dynamic_visibility_limited")
    }

    func testAudioExtractorIgnoresInvisibleLayersAndPreservesPlaybackMode() {
        let scene: [String: Any] = [
            "objects": [
                [
                    "visible": false,
                    "sound": ["sounds/hidden-bool.ogg"],
                    "playbackmode": "loop"
                ],
                [
                    "visible": ["value": false],
                    "sound": ["sounds/hidden-wrapped.ogg"],
                    "playbackmode": ["value": "loop"]
                ],
                [
                    "visible": true,
                    "sound": ["sounds/one-shot.ogg"],
                    "playbackmode": "oneshot"
                ],
                [
                    "visible": ["value": true],
                    "sound": ["sounds/loop.ogg"],
                    "playbackmode": "loop"
                ],
                [
                    "sound": ["sounds/not-loop-uppercase.ogg"],
                    "playbackmode": " LOOP "
                ],
                [
                    "sound": ["sounds/not-loop-wrapped.ogg"],
                    "playbackmode": ["value": "loop"]
                ],
                [
                    "sound": ["sounds/default.ogg"]
                ]
            ]
        ]

        XCTAssertEqual(SceneAudioExtractor.audioTracks(scene: scene), [
            SceneAudioTrack(path: "sounds/one-shot.ogg", volume: 1, loops: false),
            SceneAudioTrack(path: "sounds/loop.ogg", volume: 1, loops: true),
            SceneAudioTrack(path: "sounds/not-loop-uppercase.ogg", volume: 1, loops: false),
            SceneAudioTrack(path: "sounds/default.ogg", volume: 1, loops: false)
        ])
        XCTAssertTrue(SceneAudioExtractor.declaresVisibleSoundLayer(scene: scene))
        XCTAssertTrue(SceneAudioExtractor.hasInvalidVisiblePlaybackMode(scene: scene))

        let hiddenOnlyScene: [String: Any] = [
            "objects": [
                ["visible": false, "sound": ["sounds/hidden-bool.ogg"]],
                ["visible": ["value": false], "sound": ["sounds/hidden-wrapped.ogg"]]
            ]
        ]
        XCTAssertFalse(SceneAudioExtractor.declaresVisibleSoundLayer(scene: hiddenOnlyScene))
        XCTAssertFalse(SceneAudioExtractor.hasInvalidVisiblePlaybackMode(scene: hiddenOnlyScene))
    }

    func testAudioTrackLoopRepeatsOnlyAuthoredLoopMode() {
        XCTAssertEqual(
            SceneAudioTrackLoop.streamLoopValue(
                trackDurationSeconds: 5,
                totalDurationSeconds: 20,
                loops: false
            ),
            0
        )
        XCTAssertEqual(
            SceneAudioTrackLoop.streamLoopValue(
                trackDurationSeconds: 5,
                totalDurationSeconds: 20,
                loops: true
            ),
            3
        )
    }

    func testSceneAudioMuxOrchestratesMixedModesAndDegradesInvalidMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scene-mixed-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            entries: [
                (
                    "scene.json",
                    Data(
                        #"{"objects":[{"sound":["sounds/intro.wav"],"playbackmode":"oneshot"},{"sound":["sounds/ambience.wav"],"playbackmode":"loop"},{"sound":["sounds/invalid.wav"],"playbackmode":{"value":"loop"}}]}"#.utf8
                    )
                ),
                ("sounds/intro.wav", Data([0, 1, 2, 3])),
                ("sounds/ambience.wav", Data([4, 5, 6, 7]))
            ]
        )
        let silentVideoURL = root.appending(path: "silent.mp4")
        try Data([8, 9, 10, 11]).write(to: silentVideoURL)
        let previousProbe = SceneAudioDurationProbe.ffmpegProbeOutput
        let previousRunner = SceneVideoRenderer.runProcess
        var capturedArguments: [[String]] = []
        SceneAudioDurationProbe.ffmpegProbeOutput = { _, _, _ in
            "Duration: 00:00:05.00, start: 0.000000, bitrate: 128 kb/s"
        }
        SceneVideoRenderer.runProcess = { _, arguments, _ in
            capturedArguments.append(arguments)
        }
        defer {
            SceneAudioDurationProbe.ffmpegProbeOutput = previousProbe
            SceneVideoRenderer.runProcess = previousRunner
        }

        let result = try SceneVideoRenderer.muxSceneAudioIfAvailable(
            sceneURL: packageURL,
            silentVideoURL: silentVideoURL,
            tempDirectory: root,
            ffmpegPath: "/fake/ffmpeg",
            loopSeconds: 20,
            assetID: "mixed-audio"
        )

        XCTAssertEqual(result.audioResult.state, .degraded)
        XCTAssertTrue(result.audioResult.warning?.contains("invalid non-string playbackmode") == true)
        XCTAssertEqual(capturedArguments.count, 1)
        let arguments = try XCTUnwrap(capturedArguments.first)
        let streamLoopValues = arguments.indices.compactMap { index -> String? in
            guard arguments[index] == "-stream_loop", arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }
        XCTAssertEqual(streamLoopValues, ["0", "3"])
        XCTAssertTrue(arguments.contains { $0.hasSuffix("scene-audio/audio-0.wav") })
        XCTAssertTrue(arguments.contains { $0.hasSuffix("scene-audio/audio-1.wav") })
    }

    private static func writeScenePackage(to url: URL, entries: [(String, Data)]) throws {
        var data = Data()
        data.appendLengthPrefixedSceneString("PKGV0007")
        data.appendSceneInt32(entries.count)
        var offset = 0
        for (path, contents) in entries {
            data.appendLengthPrefixedSceneString(path)
            data.appendSceneInt32(offset)
            data.appendSceneInt32(contents.count)
            offset += contents.count
        }
        for (_, contents) in entries {
            data.append(contents)
        }
        try data.write(to: url, options: [.atomic])
    }
}

private extension Data {
    mutating func appendSceneInt32(_ value: Int) {
        var littleEndian = Int32(value).littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLengthPrefixedSceneString(_ string: String) {
        let bytes = Data(string.utf8)
        appendSceneInt32(bytes.count)
        append(bytes)
    }
}
