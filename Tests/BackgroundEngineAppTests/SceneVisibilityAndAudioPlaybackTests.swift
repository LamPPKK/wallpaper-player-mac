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

    func testAudioExtractorStopsAtSafetyLimitWithoutMaterializingTheRemainder() {
        let scene: [String: Any] = [
            "objects": [[
                "sound": (0..<1_000).map { "sounds/\($0).ogg" },
                "playbackmode": "loop"
            ]]
        ]

        let result = SceneAudioExtractor.boundedAudioTracks(
            scene: scene,
            maximumCount: 3
        )

        XCTAssertEqual(result.tracks.map(\.path), [
            "sounds/0.ogg", "sounds/1.ogg", "sounds/2.ogg"
        ])
        XCTAssertTrue(result.exceededLimit)
    }

    func testAudioExtractorRejectsOversizedReferencesButKeepsValidTracks() {
        let oversized = String(
            repeating: "a",
            count: SceneAudioExtractor.maximumReferenceUTF8Bytes + 1
        )
        let scene: [String: Any] = [
            "objects": [["sound": [oversized, "sounds/valid.ogg"]]]
        ]

        let result = SceneAudioExtractor.boundedAudioTracks(
            scene: scene,
            maximumCount: 3
        )

        XCTAssertEqual(result.tracks.map(\.path), ["sounds/valid.ogg"])
        XCTAssertFalse(result.exceededLimit)
        XCTAssertTrue(result.rejectedOversizedReference)
    }

    func testPlaybackMetadataUsesFirstDuplicatePackageAudioEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scene-duplicate-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            entries: [
                (
                    "scene.json",
                    Data(#"{"objects":[{"sound":["sounds/shared.ogg"]}]}"#.utf8)
                ),
                ("sounds/shared.ogg", Data([1])),
                ("sounds/shared.ogg", Data(repeating: 2, count: 64))
            ]
        )

        let metadata = try ScenePackagePlaybackMetadata.load(sceneURL: packageURL)

        XCTAssertEqual(metadata.packagedAudioEntryLengths["sounds/shared.ogg"], 1)
    }

    func testTemporarySceneAudioExtensionIsBoundedAndSanitized() {
        XCTAssertEqual(
            SceneVideoRenderer.safeTemporaryAudioFileExtension(for: "sounds/AUDIO.M4A"),
            "m4a"
        )
        XCTAssertEqual(
            SceneVideoRenderer.safeTemporaryAudioFileExtension(
                for: "sounds/audio." + String(repeating: "a", count: 1_000)
            ),
            "bin"
        )
        XCTAssertEqual(
            SceneVideoRenderer.safeTemporaryAudioFileExtension(for: "sounds/audio.bad-ext"),
            "bin"
        )
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

    func testSceneAudioMuxResolvesUnpackedProjectSound() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scene-project-audio-\(UUID().uuidString)")
        let sounds = root.appending(path: "sounds")
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            entries: [
                (
                    "scene.json",
                    Data(#"{"objects":[{"sound":["sounds/project.wav"]}]}"#.utf8)
                )
            ]
        )
        let expectedAudio = Data("project-audio".utf8)
        try expectedAudio.write(to: sounds.appending(path: "project.wav"))
        let silentVideoURL = root.appending(path: "silent.mp4")
        try Data("silent-video".utf8).write(to: silentVideoURL)
        let previousProbe = SceneAudioDurationProbe.ffmpegProbeOutput
        let previousRunner = SceneVideoRenderer.runProcess
        var probedAudio: Data?
        SceneAudioDurationProbe.ffmpegProbeOutput = { _, url, _ in
            probedAudio = try Data(contentsOf: url)
            return "Duration: 00:00:05.00, start: 0.000000, bitrate: 128 kb/s"
        }
        SceneVideoRenderer.runProcess = { _, _, _ in }
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
            assetID: "project-audio",
            projectDirectory: root,
            assetsDirectory: nil
        )

        XCTAssertEqual(result.audioResult, .included)
        XCTAssertEqual(probedAudio, expectedAudio)
    }

    func testUnsafeExternalSoundDoesNotDiscardValidAuthoredTrack() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scene-partial-external-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            entries: [
                (
                    "scene.json",
                    Data(
                        #"{"objects":[{"sound":["sounds/valid.wav","../escape.wav"]}]}"#.utf8
                    )
                ),
                ("sounds/valid.wav", Data("valid-audio".utf8))
            ]
        )
        let silentVideoURL = root.appending(path: "silent.mp4")
        try Data("silent-video".utf8).write(to: silentVideoURL)
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
            assetID: "partial-external-audio",
            projectDirectory: root,
            assetsDirectory: nil
        )

        XCTAssertEqual(result.audioResult.state, .degraded)
        XCTAssertTrue(result.audioResult.warning?.contains("could not be read safely") == true)
        XCTAssertEqual(capturedArguments.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(capturedArguments.first).contains {
                $0.hasSuffix("scene-audio/audio-0.wav")
            }
        )
    }

    func testSceneCacheDependencyFingerprintChangesWithExternalEngineAudio() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scene-external-audio-fingerprint-\(UUID().uuidString)")
        let assets = root.appending(path: "assets")
        try FileManager.default.createDirectory(
            at: assets.appending(path: "models"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: assets.appending(path: "sounds"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("renderer-model".utf8).write(
            to: assets.appending(path: "models/core.json")
        )
        let soundURL = assets.appending(path: "sounds/stock.ogg")
        try Data("stock-audio-v1".utf8).write(to: soundURL)
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            entries: [
                (
                    "scene.json",
                    Data(#"{"objects":[{"sound":["sounds/stock.ogg"]}]}"#.utf8)
                )
            ]
        )

        let first = try SceneCacheDependencyFingerprint.engineAssets(
            sceneURL: packageURL,
            assetsDirectory: assets,
            requiredPaths: ["models/core.json"]
        )
        try Data("stock-audio-v2".utf8).write(to: soundURL, options: .atomic)
        let second = try SceneCacheDependencyFingerprint.engineAssets(
            sceneURL: packageURL,
            assetsDirectory: assets,
            requiredPaths: ["models/core.json"]
        )

        XCTAssertNotEqual(first, second)
    }

    func testSceneCacheDependencyFingerprintFollowsAuthoredBudgetOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scene-audio-fingerprint-order-\(UUID().uuidString)")
        let assets = root.appending(path: "assets")
        try FileManager.default.createDirectory(
            at: assets.appending(path: "models"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: assets.appending(path: "sounds"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("renderer-model".utf8).write(
            to: assets.appending(path: "models/core.json")
        )
        let usedSound = assets.appending(path: "sounds/z-used.ogg")
        try Data("used-v1".utf8).write(to: usedSound)
        for index in 1...4 {
            let url = assets.appending(path: "sounds/a\(index).ogg")
            FileManager.default.createFile(atPath: url.path, contents: Data())
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 128 * 1_024 * 1_024)
            try handle.close()
        }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            entries: [
                (
                    "scene.json",
                    Data(
                        #"{"objects":[{"sound":["sounds/z-used.ogg","sounds/a1.ogg","sounds/a2.ogg","sounds/a3.ogg","sounds/a4.ogg"]}]}"#.utf8
                    )
                )
            ]
        )

        let first = try SceneCacheDependencyFingerprint.engineAssets(
            sceneURL: packageURL,
            assetsDirectory: assets,
            requiredPaths: ["models/core.json"]
        )
        try Data("used-v2".utf8).write(to: usedSound, options: .atomic)
        let second = try SceneCacheDependencyFingerprint.engineAssets(
            sceneURL: packageURL,
            assetsDirectory: assets,
            requiredPaths: ["models/core.json"]
        )

        XCTAssertNotEqual(first, second)
    }

    func testSceneCacheDependencyFingerprintHonorsProjectAudioPrecedence() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scene-audio-fingerprint-precedence-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        let assets = root.appending(path: "assets")
        for base in [project, assets] {
            try FileManager.default.createDirectory(
                at: base.appending(path: "sounds"),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: assets.appending(path: "models"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("renderer-model".utf8).write(
            to: assets.appending(path: "models/core.json")
        )
        try Data("project-wins".utf8).write(
            to: project.appending(path: "sounds/shared.ogg")
        )
        let engineSound = assets.appending(path: "sounds/shared.ogg")
        try Data("engine-v1".utf8).write(to: engineSound)
        let packageURL = project.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            entries: [
                (
                    "scene.json",
                    Data(#"{"objects":[{"sound":["sounds/shared.ogg"]}]}"#.utf8)
                )
            ]
        )

        let first = try SceneCacheDependencyFingerprint.engineAssets(
            sceneURL: packageURL,
            projectDirectory: project,
            assetsDirectory: assets,
            requiredPaths: ["models/core.json"]
        )
        try Data("engine-v2".utf8).write(to: engineSound, options: .atomic)
        let second = try SceneCacheDependencyFingerprint.engineAssets(
            sceneURL: packageURL,
            projectDirectory: project,
            assetsDirectory: assets,
            requiredPaths: ["models/core.json"]
        )

        XCTAssertEqual(first, second)
    }

    func testSceneAudioResolverHonorsTaskCancellationBeforeReading() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scene-audio-cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 1_024).write(to: root.appending(path: "sound.wav"))

        let gate = SceneAudioCancellationGate()
        let task = Task.detached {
            await gate.wait()
            return try SceneAuthoredAudioResolver.directoryData(
                reference: "sound.wav",
                roots: [root],
                maximumBytes: 2_048
            )
        }
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before reading external Scene audio.")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testSceneAudioResolverUsesProjectBeforeEngineAssetsAndRejectsEscapes() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scene-audio-resolution-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        let assets = root.appending(path: "assets")
        let outside = root.appending(path: "outside.wav")
        try FileManager.default.createDirectory(
            at: project.appending(path: "sounds"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: assets.appending(path: "sounds"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let projectAudio = Data("project-wins".utf8)
        let assetAudio = Data("asset-fallback".utf8)
        try projectAudio.write(to: project.appending(path: "sounds/shared.ogg"))
        try assetAudio.write(to: assets.appending(path: "sounds/shared.ogg"))
        try assetAudio.write(to: assets.appending(path: "sounds/stock.ogg"))
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: project.appending(path: "sounds/escape.wav"),
            withDestinationURL: outside
        )

        XCTAssertEqual(
            try SceneAuthoredAudioResolver.directoryData(
                reference: "sounds/shared.ogg",
                roots: [project, assets],
                maximumBytes: 1_024
            ),
            projectAudio
        )
        XCTAssertEqual(
            try SceneAuthoredAudioResolver.directoryData(
                reference: "sounds/stock.ogg",
                roots: [project, assets],
                maximumBytes: 1_024
            ),
            assetAudio
        )
        XCTAssertThrowsError(
            try SceneAuthoredAudioResolver.directoryData(
                reference: "../outside.wav",
                roots: [project],
                maximumBytes: 1_024
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneAuthoredAudioResolverError,
                .unsafeReference("../outside.wav")
            )
        }
        XCTAssertThrowsError(
            try SceneAuthoredAudioResolver.directoryData(
                reference: "sounds/escape.wav",
                roots: [project],
                maximumBytes: 1_024
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneAuthoredAudioResolverError,
                .unsafeSource("sounds/escape.wav")
            )
        }
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

private actor SceneAudioCancellationGate {
    private var isReleased = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
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
