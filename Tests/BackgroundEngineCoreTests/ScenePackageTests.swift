import Foundation
import XCTest
@testable import BackgroundEngineCore

final class ScenePackageTests: XCTestCase {
    func testBoundedHeaderProbeRecognizesRenamedPKGVPackage() throws {
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "scene.payload")
        try Fixture.writeScenePackage(to: packageURL, sceneJSON: #"{"objects":[]}"#)

        XCTAssertTrue(ScenePackageReader().hasPackageHeader(url: packageURL))

        let unrelated = root.appending(path: "installer.pkg")
        try Data("not a scene package".utf8).write(to: unrelated)
        XCTAssertFalse(ScenePackageReader().hasPackageHeader(url: unrelated))
    }

    func testReaderParsesPackageEntriesAndSceneData() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "scene.pkg")
        let sceneJSON = #"{"objects":[{"image":"models/background.json"}]}"#
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [(path: "materials/background.tex", data: Data([1, 2, 3]))]
        )

        // When
        let package = try ScenePackageReader().read(url: packageURL)

        // Then
        XCTAssertEqual(package.magic, "PKGV0007")
        XCTAssertEqual(package.entries.map(\.path), ["scene.json", "materials/background.tex"])
        let sceneEntry = try XCTUnwrap(package.entry(named: "scene.json"))
        XCTAssertEqual(String(data: package.data(for: sceneEntry), encoding: .utf8), sceneJSON)
    }

    func testReaderRejectsPathEscapingEntries() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "scene.pkg")
        let data = Fixture.scenePackageData(entries: [(path: "../escape.json", data: Data())])
        try data.write(to: packageURL, options: [.atomic])

        // Then
        XCTAssertThrowsError(try ScenePackageReader().read(url: packageURL)) { error in
            XCTAssertEqual(error as? ScenePackageError, .unsafeEntryPath("../escape.json"))
        }
    }

    func testReaderRejectsAbsoluteEntries() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "scene.pkg")
        let data = Fixture.scenePackageData(entries: [(path: "/tmp/escape.json", data: Data())])
        try data.write(to: packageURL, options: [.atomic])

        // Then
        XCTAssertThrowsError(try ScenePackageReader().read(url: packageURL)) { error in
            XCTAssertEqual(error as? ScenePackageError, .unsafeEntryPath("/tmp/escape.json"))
        }
    }

    func testReaderRejectsInvalidEntryRanges() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "scene.pkg")
        var data = Fixture.scenePackageData(entries: [(path: "scene.json", data: Data("{}".utf8))])
        data.replaceSubrange(34..<38, with: littleEndianInt32Bytes(2_000_000_000))
        try data.write(to: packageURL, options: [.atomic])

        // Then
        XCTAssertThrowsError(try ScenePackageReader().read(url: packageURL)) { error in
            XCTAssertEqual(error as? ScenePackageError, .invalidEntryRange("scene.json"))
        }
    }

    func testReaderRejectsPackagesAboveConfiguredSizeLimit() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "scene.pkg")
        FileManager.default.createFile(atPath: packageURL.path, contents: Data())
        let handle = try FileHandle(forWritingTo: packageURL)
        try handle.truncate(atOffset: 128)
        try handle.close()

        // Then
        XCTAssertThrowsError(try ScenePackageReader(maximumPackageBytes: 64).read(url: packageURL)) { error in
            XCTAssertEqual(error as? ScenePackageError, .packageTooLarge(128, 64))
        }
    }

    func testAnalyzerSummarizesSceneFeatures() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "scene.pkg")
        let sceneJSON = """
        {
          "objects": [
            {
              "image": "models/background.json",
              "origin": {
                "value": "0 0 0",
                "animation": {
                  "options": { "fps": 30, "length": 30 },
                  "c0": [ { "frame": 0, "value": 0 }, { "frame": 30, "value": 100 } ]
                }
              }
            },
            {"particle": "particles/leaves.json"},
            {
              "text": "SALE",
              "alpha": {
                "value": 1,
                "animation": {
                  "options": { "fps": 30, "length": 30 },
                  "c0": [ { "frame": 0, "value": 1 }, { "frame": 30, "value": 0 } ]
                }
              }
            }
          ]
        }
        """
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [
                (path: "materials/background.tex", data: Data([1])),
                (path: "effects/pulse/effect.json", data: Data([2])),
                (path: "shaders/effects/pulse.frag", data: Data([3])),
                (path: "fonts/title.ttf", data: Data([4])),
                (path: "sounds/loop.mp3", data: Data([5]))
            ]
        )

        // When
        let analysis = try ScenePackageAnalyzer().analyze(url: packageURL)

        // Then
        XCTAssertEqual(analysis.objectCount, 3)
        XCTAssertEqual(analysis.imageObjectCount, 1)
        XCTAssertEqual(analysis.particleObjectCount, 1)
        XCTAssertEqual(analysis.textObjectCount, 1)
        XCTAssertEqual(analysis.animatedObjectCount, 2)
        XCTAssertEqual(analysis.originAnimationCount, 1)
        XCTAssertEqual(analysis.alphaAnimationCount, 1)
        XCTAssertEqual(analysis.textureEntryCount, 1)
        XCTAssertEqual(analysis.effectEntryCount, 1)
        XCTAssertEqual(analysis.shaderEntryCount, 1)
        XCTAssertEqual(analysis.fontEntryCount, 1)
        XCTAssertEqual(analysis.audioEntryCount, 1)
        XCTAssertTrue(analysis.requiresFullRenderer)
        XCTAssertTrue(analysis.userFacingSummary.contains("1 image layer"))
        XCTAssertTrue(analysis.userFacingSummary.contains("1 particle system"))
        XCTAssertTrue(analysis.userFacingSummary.contains("2 animated object(s)"))
        XCTAssertTrue(analysis.userFacingSummary.contains("selected text SceneScript"))
        XCTAssertTrue(analysis.userFacingSummary.contains("selected effect playback"))
        XCTAssertTrue(analysis.userFacingSummary.contains("engine rendering features"))
    }

    func testRuntimeFeatureAnalyzerPreservesEngineRendererRequirements() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "engine-scene.pkg")
        let sceneJSON = """
        {
          "objects": [
            {
              "id": 1,
              "name": "Water",
              "image": "models/water.json",
              "effects": [
                {
                  "file": "effects/waterflow/effect.json",
                  "passes": [
                    {
                      "constantshadervalues": {
                        "speed": 0.45,
                        "strength": 0.47
                      }
                    }
                  ]
                }
              ]
            },
            {
              "id": 2,
              "name": "Clock",
              "text": {
                "value": "12:34",
                "script": "export function update() { const time = new Date(); return time.getHours(); }"
              }
            },
            { "id": 3, "name": "Foam", "particle": "particles/foam.json" },
            { "id": 4, "name": "Sea audio", "sound": "sounds/sea.ogg" }
          ]
        }
        """
        let embeddedVideoTexture = Fixture.animatedTexData(
            textureWidth: 4,
            textureHeight: 2,
            container: "TEXB0004",
            isVideoMP4: true,
            mipmaps: [(width: 4, height: 2, data: Data(repeating: 0, count: 32))],
            frameContainer: nil
        )
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [
                (path: "models/water.json", data: Data(#"{"material":"materials/water.json"}"#.utf8)),
                (
                    path: "materials/water.json",
                    data: Data(#"{"passes":[{"shader":"genericimage","textures":["water"]}]}"#.utf8)
                ),
                (path: "materials/water.tex", data: Data([1])),
                (
                    path: "effects/waterflow/effect.json",
                    data: Data(#"{"passes":[{"material":"materials/waterflow-effect.json"}]}"#.utf8)
                ),
                (
                    path: "materials/waterflow-effect.json",
                    data: Data(#"{"passes":[{"shader":"effects/waterflow","textures":["ripple"]}]}"#.utf8)
                ),
                (
                    path: "shaders/effects/waterflow.frag",
                    data: Data("float t = g_Time + g_AudioSpectrum16Left[0];".utf8)
                ),
                (path: "sounds/sea.ogg", data: Data([3])),
                (path: "materials/ripple.tex", data: embeddedVideoTexture)
            ]
        )

        // When
        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)

        // Then
        XCTAssertTrue(features.requiresEngineRenderer)
        XCTAssertTrue(features.requiresShaderPipeline)
        XCTAssertTrue(features.requiresSceneScriptRuntime)
        XCTAssertTrue(features.requiresParticleRuntime)
        XCTAssertTrue(features.requiresSoundRuntime)
        XCTAssertFalse(features.requiresModelRuntime)
        XCTAssertTrue(features.requiresAudioAnalysis)
        XCTAssertTrue(features.requiresVideoTextureRuntime)
        XCTAssertEqual(features.materialFiles, ["materials/water.json", "materials/waterflow-effect.json"])
        XCTAssertEqual(features.effectFiles, ["effects/waterflow/effect.json"])
        XCTAssertEqual(features.shaderFiles, ["shaders/effects/waterflow.frag"])
        XCTAssertEqual(features.audioFiles, ["sounds/sea.ogg"])
        XCTAssertEqual(features.videoFiles, ["materials/ripple.tex"])
        XCTAssertEqual(features.shaderUniforms, ["g_AudioSpectrum16Left", "g_Time"])
        XCTAssertEqual(features.layers.first?.constantShaderValueKeys, ["speed", "strength"])
        XCTAssertEqual(features.layers.first { $0.name == "Clock" }?.scriptCount, 1)
        XCTAssertTrue(features.runtimeGaps.contains("metal-shader-effect-pipeline"))
        XCTAssertTrue(features.runtimeGaps.contains("audio-analysis-uniforms"))
    }

    func testRuntimeFeatureAnalyzerDoesNotPromoteStaticallyHiddenPackageDependencies() throws {
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "hidden-dependencies.pkg")
        let hiddenVideoTexture = Fixture.animatedTexData(
            textureWidth: 4,
            textureHeight: 2,
            container: "TEXB0004",
            isVideoMP4: true,
            mipmaps: [(width: 4, height: 2, data: Data(repeating: 0, count: 32))],
            frameContainer: nil
        )
        let sceneJSON = """
        {
          "objects": [
            { "id": 1, "name": "Visible title", "text": "VISIBLE" },
            {
              "id": 2,
              "name": "Disabled variant",
              "visible": false,
              "image": "models/hidden.json",
              "effects": [
                { "file": "effects/hidden/effect.json" }
              ]
            }
          ]
        }
        """
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [
                (
                    path: "models/hidden.json",
                    data: Data(#"{"material":"materials/hidden.json"}"#.utf8)
                ),
                (
                    path: "materials/hidden.json",
                    data: Data(#"{"passes":[{"shader":"hidden/image","textures":["hidden-video"]}]}"#.utf8)
                ),
                (
                    path: "effects/hidden/effect.json",
                    data: Data(#"{"passes":[{"material":"materials/hidden-effect.json"}]}"#.utf8)
                ),
                (
                    path: "materials/hidden-effect.json",
                    data: Data(#"{"passes":[{"shader":"hidden/effect"}]}"#.utf8)
                ),
                (
                    path: "shaders/hidden/image.frag",
                    data: Data("float x = g_AudioSpectrum16Left[0];".utf8)
                ),
                (
                    path: "shaders/hidden/effect.frag",
                    data: Data("float x = g_AudioPower;".utf8)
                ),
                (path: "materials/hidden-video.tex", data: hiddenVideoTexture)
            ]
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)

        XCTAssertEqual(features.layers.map(\.name), ["Visible title"])
        XCTAssertEqual(
            features.shaderFiles,
            ["shaders/hidden/effect.frag", "shaders/hidden/image.frag"]
        )
        XCTAssertEqual(features.shaderUniforms, ["g_AudioPower", "g_AudioSpectrum16Left"])
        XCTAssertEqual(features.videoFiles, ["materials/hidden-video.tex"])
        XCTAssertFalse(features.requiresShaderPipeline)
        XCTAssertFalse(features.requiresAudioAnalysis)
        XCTAssertFalse(features.requiresVideoTextureRuntime)
        XCTAssertFalse(features.requiresEngineRenderer)

        let package = try ScenePackageReader().read(url: packageURL)
        let dynamicallyVisibleScene: [String: Any] = [
            "objects": [[
                "id": 2,
                "name": "User-selectable variant",
                "visible": ["value": false, "user": "showVariant"],
                "image": "models/hidden.json",
                "effects": [["file": "effects/hidden/effect.json"]]
            ]]
        ]
        let dynamicFeatures = SceneRuntimeFeatureAnalyzer().analyze(
            package: package,
            scene: dynamicallyVisibleScene
        )
        XCTAssertEqual(dynamicFeatures.layers.map(\.name), ["User-selectable variant"])
        XCTAssertTrue(dynamicFeatures.requiresShaderPipeline)
        XCTAssertTrue(dynamicFeatures.requiresAudioAnalysis)
        XCTAssertTrue(dynamicFeatures.requiresVideoTextureRuntime)
        XCTAssertTrue(dynamicFeatures.requiresEngineRenderer)
    }

    func testRuntimeFeatureAnalyzerLexicallyNormalizesSafeDotReferences() throws {
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "normalized-references.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"name":"Normalized","image":"./models/variant/../visible.json"}]}"#,
            extraEntries: [
                (
                    path: "models/visible.json",
                    data: Data(#"{"material":"./materials/variant/../visible.json"}"#.utf8)
                ),
                (
                    path: "materials/visible.json",
                    data: Data(
                        #"{"passes":[{"shader":"./local/../basic","textures":["./variant/../visible"]}]}"#.utf8
                    )
                ),
                (path: "materials/visible.tex", data: Data([1, 2, 3])),
                (
                    path: "shaders/basic.vert",
                    data: Data("void main() {}".utf8)
                ),
                (
                    path: "shaders/basic.frag",
                    data: Data("#include \"./headers/../audio\"\nvoid main() {}".utf8)
                ),
                (
                    path: "shaders/audio.h",
                    data: Data("float level = g_AudioPower;".utf8)
                )
            ]
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)

        XCTAssertTrue(features.unresolvedRequiredAssetFiles.isEmpty)
        XCTAssertFalse(features.requiresExternalAssetRuntime)
        XCTAssertFalse(features.hasDependencyAnalysisUncertainty)
        XCTAssertFalse(features.hasAudioDependencyUncertainty)
        XCTAssertTrue(features.requiresShaderPipeline)
        XCTAssertTrue(features.requiresAudioAnalysis)
    }

    func testRuntimeFeatureAnalyzerFlagsStockExternalAndRootEscapingReferences() throws {
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "external-references.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"name":"Fallback","text":"VISIBLE"},{"name":"Stock","image":"models/util/composelayer.json"},{"name":"Escaped","image":"../models/outside.json"}]}"#
        )

        XCTAssertTrue(SceneRenderPlanBuilder().canBuild(url: packageURL))
        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
        let report = WallpaperCompatibilityAnalyzer().analyzeScene(
            entrypoint: packageURL,
            nativePlayable: true
        )

        XCTAssertEqual(
            features.unresolvedRequiredAssetFiles,
            ["../models/outside.json", "models/util/composelayer.json"]
        )
        XCTAssertTrue(features.requiresExternalAssetRuntime)
        XCTAssertTrue(features.hasDependencyAnalysisUncertainty)
        XCTAssertTrue(features.hasAudioDependencyUncertainty)
        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
        XCTAssertTrue(report.missingCapabilities.contains(.engineLayer))
        XCTAssertTrue(report.missingCapabilities.contains(.audioReactive))
        XCTAssertEqual(report.diagnosticCode, "scene_dependency_analysis_limited")
    }

    func testRuntimeFeatureAnalyzerFailsClosedForMalformedReachableJSON() throws {
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "malformed-reachable.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"name":"Fallback","text":"VISIBLE"},{"name":"Broken","image":"models/broken.json"}]}"#,
            extraEntries: [(path: "models/broken.json", data: Data("{not-json".utf8))]
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
        let report = WallpaperCompatibilityAnalyzer().analyzeScene(
            entrypoint: packageURL,
            nativePlayable: true
        )

        XCTAssertTrue(features.hasDependencyAnalysisUncertainty)
        XCTAssertTrue(features.hasAudioDependencyUncertainty)
        XCTAssertTrue(features.unresolvedRequiredAssetFiles.isEmpty)
        XCTAssertEqual(report.level, .limited)
        XCTAssertTrue(report.missingCapabilities.contains(.engineLayer))
        XCTAssertTrue(report.missingCapabilities.contains(.audioReactive))
    }

    func testRuntimeFeatureAnalyzerRejectsMalformedRendererRequiredModelAndMaterialFields() throws {
        struct SchemaCase {
            let name: String
            let modelJSON: String
            let materialJSON: String?
            let expectedMarker: String
        }

        let cases = [
            SchemaCase(
                name: "empty model",
                modelJSON: "{}",
                materialJSON: nil,
                expectedMarker: "models/broken.json#material"
            ),
            SchemaCase(
                name: "wrapped model material",
                modelJSON: #"{"material":{"value":"materials/broken.json"}}"#,
                materialJSON: nil,
                expectedMarker: "models/broken.json#material"
            ),
            SchemaCase(
                name: "numeric model material",
                modelJSON: #"{"material":42}"#,
                materialJSON: nil,
                expectedMarker: "models/broken.json#material"
            ),
            SchemaCase(
                name: "missing material passes",
                modelJSON: #"{"material":"materials/broken.json"}"#,
                materialJSON: "{}",
                expectedMarker: "materials/broken.json#passes"
            ),
            SchemaCase(
                name: "null material passes",
                modelJSON: #"{"material":"materials/broken.json"}"#,
                materialJSON: #"{"passes":null}"#,
                expectedMarker: "materials/broken.json#passes"
            ),
            SchemaCase(
                name: "non-array material passes",
                modelJSON: #"{"material":"materials/broken.json"}"#,
                materialJSON: #"{"passes":{}}"#,
                expectedMarker: "materials/broken.json#passes"
            ),
            SchemaCase(
                name: "empty material passes",
                modelJSON: #"{"material":"materials/broken.json"}"#,
                materialJSON: #"{"passes":[]}"#,
                expectedMarker: "materials/broken.json#passes"
            ),
            SchemaCase(
                name: "scalar material pass",
                modelJSON: #"{"material":"materials/broken.json"}"#,
                materialJSON: #"{"passes":[42]}"#,
                expectedMarker: "materials/broken.json#passes[0]#object"
            ),
            SchemaCase(
                name: "missing material shader",
                modelJSON: #"{"material":"materials/broken.json"}"#,
                materialJSON: #"{"passes":[{}]}"#,
                expectedMarker: "materials/broken.json#passes[0]#shader"
            ),
            SchemaCase(
                name: "wrapped material shader",
                modelJSON: #"{"material":"materials/broken.json"}"#,
                materialJSON: #"{"passes":[{"shader":{"value":"basic"}}]}"#,
                expectedMarker: "materials/broken.json#passes[0]#shader"
            ),
            SchemaCase(
                name: "material shader path has surrounding whitespace",
                modelJSON: #"{"material":"materials/broken.json"}"#,
                materialJSON: #"{"passes":[{"shader":" basic "}]}"#,
                expectedMarker: "materials/broken.json#passes[0]#shader"
            )
        ]

        for (index, testCase) in cases.enumerated() {
            let root = try Fixture.makeTempDirectory()
            let packageURL = root.appending(path: "required-schema-\(index).pkg")
            var entries = [
                (path: "models/broken.json", data: Data(testCase.modelJSON.utf8))
            ]
            if let materialJSON = testCase.materialJSON {
                entries.append(
                    (path: "materials/broken.json", data: Data(materialJSON.utf8))
                )
            }
            try Fixture.writeScenePackage(
                to: packageURL,
                sceneJSON: #"{"objects":[{"name":"Fallback","text":"VISIBLE"},{"name":"Broken","image":"models/broken.json"}]}"#,
                extraEntries: entries
            )

            let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
            let report = WallpaperCompatibilityAnalyzer().analyzeScene(
                entrypoint: packageURL,
                nativePlayable: true
            )

            XCTAssertTrue(
                features.unresolvedRequiredAssetFiles.contains(testCase.expectedMarker),
                testCase.name
            )
            XCTAssertTrue(features.hasDependencyAnalysisUncertainty, testCase.name)
            XCTAssertTrue(features.hasAudioDependencyUncertainty, testCase.name)
            XCTAssertEqual(report.level, .limited, testCase.name)
            XCTAssertEqual(report.playbackPath, .renderedSceneCache, testCase.name)
            XCTAssertTrue(report.missingCapabilities.contains(.engineLayer), testCase.name)
            XCTAssertTrue(report.missingCapabilities.contains(.audioReactive), testCase.name)
            XCTAssertEqual(
                report.diagnosticCode,
                "scene_dependency_analysis_limited",
                testCase.name
            )
        }
    }

    func testRuntimeFeatureAnalyzerRejectsMalformedRendererRequiredEffectFields() throws {
        struct EffectCase {
            let name: String
            let effectJSON: String
            let expectedMarker: String
        }

        let cases = [
            EffectCase(
                name: "missing effect passes",
                effectJSON: "{}",
                expectedMarker: "effects/broken.json#passes"
            ),
            EffectCase(
                name: "null effect passes",
                effectJSON: #"{"passes":null}"#,
                expectedMarker: "effects/broken.json#passes"
            ),
            EffectCase(
                name: "non-array effect passes",
                effectJSON: #"{"passes":{}}"#,
                expectedMarker: "effects/broken.json#passes"
            ),
            EffectCase(
                name: "empty effect passes",
                effectJSON: #"{"passes":[]}"#,
                expectedMarker: "effects/broken.json#passes"
            ),
            EffectCase(
                name: "inert effect pass",
                effectJSON: #"{"passes":[{}]}"#,
                expectedMarker: "effects/broken.json#passes[0]#material-or-copy-command"
            ),
            EffectCase(
                name: "unsupported command-only swap",
                effectJSON: #"{"passes":[{"command":"swap","source":"input","target":"result"}]}"#,
                expectedMarker: "effects/broken.json#passes[0]#command"
            ),
            EffectCase(
                name: "wrapped effect material",
                effectJSON: #"{"passes":[{"material":{"value":"materials/effect.json"}}]}"#,
                expectedMarker: "effects/broken.json#passes[0]#material"
            ),
            EffectCase(
                name: "command missing source",
                effectJSON: #"{"passes":[{"command":"copy","target":"result"}]}"#,
                expectedMarker: "effects/broken.json#passes[0]#source"
            ),
            EffectCase(
                name: "command wrapped target",
                effectJSON: #"{"passes":[{"command":"copy","source":"input","target":{"value":"result"}}]}"#,
                expectedMarker: "effects/broken.json#passes[0]#target"
            ),
            EffectCase(
                name: "optional wrapped source",
                effectJSON: #"{"passes":[{"source":{"value":"input"}}]}"#,
                expectedMarker: "effects/broken.json#passes[0]#source"
            ),
            EffectCase(
                name: "optional numeric target",
                effectJSON: #"{"passes":[{"target":42}]}"#,
                expectedMarker: "effects/broken.json#passes[0]#target"
            ),
            EffectCase(
                name: "bind missing required index",
                effectJSON: #"{"passes":[{"command":"copy","source":"input","target":"result","bind":[{"name":"previous"}]}]}"#,
                expectedMarker: "effects/broken.json#passes[0]#bind[0]#index"
            ),
            EffectCase(
                name: "bind name has wrong type",
                effectJSON: #"{"passes":[{"command":"copy","source":"input","target":"result","bind":[{"index":0,"name":42}]}]}"#,
                expectedMarker: "effects/broken.json#passes[0]#bind[0]#name"
            ),
            EffectCase(
                name: "bind collection has wrong type",
                effectJSON: #"{"passes":[{"material":"materials/basic.json","bind":{}}]}"#,
                expectedMarker: "effects/broken.json#passes[0]#bind"
            ),
            EffectCase(
                name: "material bind names an unresolved FBO",
                effectJSON: #"{"passes":[{"material":"materials/basic.json","bind":[{"index":0,"name":"missing-target"}]}]}"#,
                expectedMarker: "effects/broken.json#passes[0]#bind[0]#name-unresolved"
            ),
            EffectCase(
                name: "FBO missing required name",
                effectJSON: #"{"passes":[],"fbos":[{}]}"#,
                expectedMarker: "effects/broken.json#fbos[0]#name"
            ),
            EffectCase(
                name: "FBO collection has wrong type",
                effectJSON: #"{"passes":[{"material":"materials/basic.json"}],"fbos":{}}"#,
                expectedMarker: "effects/broken.json#fbos"
            ),
            EffectCase(
                name: "FBO scale cannot be zero",
                effectJSON: #"{"passes":[],"fbos":[{"name":"target","scale":0}]}"#,
                expectedMarker: "effects/broken.json#fbos[0]#scale"
            ),
            EffectCase(
                name: "FBO format has wrong type",
                effectJSON: #"{"passes":[],"fbos":[{"name":"target","format":{"value":"rgba8888"}}]}"#,
                expectedMarker: "effects/broken.json#fbos[0]#format"
            ),
            EffectCase(
                name: "FBO unique has wrong type",
                effectJSON: #"{"passes":[],"fbos":[{"name":"target","unique":1}]}"#,
                expectedMarker: "effects/broken.json#fbos[0]#unique"
            )
        ]

        for (index, testCase) in cases.enumerated() {
            let root = try Fixture.makeTempDirectory()
            let packageURL = root.appending(path: "effect-schema-\(index).pkg")
            try Fixture.writeScenePackage(
                to: packageURL,
                sceneJSON: #"{"objects":[{"name":"Fallback","text":"VISIBLE"},{"name":"Effect","image":"models/basic.json","effects":[{"file":"effects/broken.json"}]}]}"#,
                extraEntries: [
                    (
                        path: "models/basic.json",
                        data: Data(#"{"material":"materials/basic.json"}"#.utf8)
                    ),
                    (
                        path: "materials/basic.json",
                        data: Data(#"{"passes":[{"shader":"basic"}]}"#.utf8)
                    ),
                    (path: "shaders/basic.vert", data: Data("void main() {}".utf8)),
                    (path: "shaders/basic.frag", data: Data("void main() {}".utf8)),
                    (path: "effects/broken.json", data: Data(testCase.effectJSON.utf8))
                ]
            )

            let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
            let report = WallpaperCompatibilityAnalyzer().analyzeScene(
                entrypoint: packageURL,
                nativePlayable: true
            )

            XCTAssertTrue(
                features.unresolvedRequiredAssetFiles.contains(testCase.expectedMarker),
                testCase.name
            )
            XCTAssertTrue(features.hasDependencyAnalysisUncertainty, testCase.name)
            XCTAssertTrue(features.hasAudioDependencyUncertainty, testCase.name)
            XCTAssertEqual(report.level, .limited, testCase.name)
            XCTAssertEqual(report.playbackPath, .renderedSceneCache, testCase.name)
        }
    }

    func testRuntimeFeatureAnalyzerKeepsCompleteBasicImageSchemaFull() throws {
        let png = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lz8KWwAAAABJRU5ErkJggg=="
            )
        )
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "complete-basic-image.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"name":"Title","text":"VISIBLE"},{"name":"Image","image":"models/basic.json"}]}"#,
            extraEntries: [
                (
                    path: "models/basic.json",
                    data: Data(#"{"material":"materials/basic.json"}"#.utf8)
                ),
                (
                    path: "materials/basic.json",
                    data: Data(#"{"passes":[{"shader":"basic","textures":["background"]}]}"#.utf8)
                ),
                (path: "materials/background.tex", data: Fixture.texData(width: 1, height: 1, imageData: png)),
                (path: "shaders/basic.vert", data: Data("void main() {}".utf8)),
                (path: "shaders/basic.frag", data: Data("void main() {}".utf8))
            ]
        )

        XCTAssertTrue(SceneRenderPlanBuilder().canBuild(url: packageURL))
        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .scene,
            status: .playable,
            entrypoint: packageURL
        )

        XCTAssertTrue(features.unresolvedRequiredAssetFiles.isEmpty)
        XCTAssertFalse(features.hasDependencyAnalysisUncertainty)
        XCTAssertFalse(features.hasAudioDependencyUncertainty)
        XCTAssertTrue(features.requiresShaderPipeline)
        XCTAssertEqual(report.level, .full)
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
    }

    func testRuntimeFeatureAnalyzerScansExtensionlessRendererDefinitions() throws {
        let png = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lz8KWwAAAABJRU5ErkJggg=="
            )
        )
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "extensionless-definitions.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"name":"Image","image":"models/basic","effects":[{"file":"effects/audio"}]}]}"#,
            extraEntries: [
                (path: "models/basic", data: Data(#"{"material":"materials/basic"}"#.utf8)),
                (
                    path: "materials/basic",
                    data: Data(#"{"passes":[{"shader":"basic","textures":["background"]}]}"#.utf8)
                ),
                (
                    path: "effects/audio",
                    data: Data(#"{"passes":[{"material":"materials/audio"}]}"#.utf8)
                ),
                (
                    path: "materials/audio",
                    data: Data(#"{"passes":[{"shader":"audio"}]}"#.utf8)
                ),
                (path: "materials/background.tex", data: Fixture.texData(width: 1, height: 1, imageData: png)),
                (path: "shaders/basic.vert", data: Data("void main() {}".utf8)),
                (path: "shaders/basic.frag", data: Data("void main() {}".utf8)),
                (path: "shaders/audio.vert", data: Data("void main() {}".utf8)),
                (
                    path: "shaders/audio.frag",
                    data: Data("float level = g_AudioPower;\nvoid main() {}".utf8)
                )
            ]
        )

        XCTAssertTrue(SceneRenderPlanBuilder().canBuild(url: packageURL))
        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .scene,
            status: .playable,
            entrypoint: packageURL
        )

        XCTAssertTrue(features.unresolvedRequiredAssetFiles.isEmpty)
        XCTAssertFalse(features.hasDependencyAnalysisUncertainty)
        XCTAssertFalse(features.hasAudioDependencyUncertainty)
        XCTAssertTrue(features.requiresShaderPipeline)
        XCTAssertTrue(features.requiresAudioAnalysis)
        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
        XCTAssertTrue(report.requiredCapabilities.contains(.audioReactive))
        XCTAssertTrue(report.missingCapabilities.contains(.audioReactive))
    }

    func testRuntimeFeatureAnalyzerMirrorsRendererSafeOptionalTextureMaps() throws {
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "safe-empty-maps.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"name":"Fallback","text":"VISIBLE"},{"name":"Effect","image":"models/basic.json","effects":[{"file":"effects/valid.json"}]}]}"#,
            extraEntries: [
                (
                    path: "models/basic.json",
                    data: Data(#"{"material":"materials/basic.json"}"#.utf8)
                ),
                (
                    path: "materials/basic.json",
                    data: Data(#"{"passes":[{"shader":"basic","textures":{"ignored":true},"usertextures":[null,42,{}]}]}"#.utf8)
                ),
                (path: "shaders/basic.vert", data: Data("void main() {}".utf8)),
                (path: "shaders/basic.frag", data: Data("void main() {}".utf8)),
                (
                    path: "effects/valid.json",
                    data: Data(
                        #"{"passes":[{"material":"materials/effect.json","bind":[{"index":0,"name":"effectInput"}]}],"fbos":[{"name":"effectInput","format":"rgba8888","scale":1,"unique":false}]}"#.utf8
                    )
                ),
                (
                    path: "materials/effect.json",
                    data: Data(#"{"passes":[{"shader":"effect"}]}"#.utf8)
                ),
                (path: "shaders/effect.vert", data: Data("void main() {}".utf8)),
                (path: "shaders/effect.frag", data: Data("void main() {}".utf8))
            ]
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
        let report = WallpaperCompatibilityAnalyzer().analyzeScene(
            entrypoint: packageURL,
            nativePlayable: true
        )

        XCTAssertTrue(features.unresolvedRequiredAssetFiles.isEmpty)
        XCTAssertFalse(features.hasDependencyAnalysisUncertainty)
        XCTAssertFalse(features.hasAudioDependencyUncertainty)
        XCTAssertEqual(report.level, .full)
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
    }

    func testRuntimeFeatureAnalyzerFailsClosedForUnresolvedShaderInclude() throws {
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "missing-shader-include.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"name":"Fallback","text":"VISIBLE"},{"name":"Shader","image":"models/shader.json"}]}"#,
            extraEntries: [
                (path: "models/shader.json", data: Data(#"{"material":"materials/shader.json"}"#.utf8)),
                (
                    path: "materials/shader.json",
                    data: Data(#"{"passes":[{"shader":"custom"}]}"#.utf8)
                ),
                (path: "shaders/custom.vert", data: Data("void main() {}".utf8)),
                (
                    path: "shaders/custom.frag",
                    data: Data("#include \"missing_audio.h\"\nvoid main() {}".utf8)
                )
            ]
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
        let report = WallpaperCompatibilityAnalyzer().analyzeScene(
            entrypoint: packageURL,
            nativePlayable: true
        )

        XCTAssertEqual(features.unresolvedRequiredAssetFiles, ["shaders/missing_audio.h"])
        XCTAssertTrue(features.hasDependencyAnalysisUncertainty)
        XCTAssertTrue(features.hasAudioDependencyUncertainty)
        XCTAssertEqual(report.level, .limited)
        XCTAssertTrue(report.requiredCapabilities.contains(.audioReactive))
        XCTAssertTrue(report.missingCapabilities.contains(.audioReactive))
    }

    func testInvalidSoundPlaybackModeIsLimitedInsteadOfGuessedOneShot() throws {
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "invalid-playback-mode.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"name":"Fallback","text":"VISIBLE"},{"name":"Audio","sound":["sounds/theme.ogg"],"playbackmode":{"value":"loop"}}]}"#,
            extraEntries: [(path: "sounds/theme.ogg", data: Data([1, 2, 3]))]
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
        let report = WallpaperCompatibilityAnalyzer().analyzeScene(
            entrypoint: packageURL,
            nativePlayable: true
        )

        XCTAssertTrue(features.hasInvalidSoundPlaybackMode)
        XCTAssertTrue(features.runtimeGaps.contains("invalid-sound-playback-mode"))
        XCTAssertEqual(report.level, .limited)
        XCTAssertTrue(report.missingCapabilities.contains(.sound))
        XCTAssertEqual(report.diagnosticCode, "scene_invalid_playback_mode_limited")
    }

    func testRuntimeFeatureAnalyzerReportsMaskedEffectComposition() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "masked-composition.pkg")
        let sceneJSON = """
        {
          "objects": [
            {
              "id": 1,
              "name": "Masked layer",
              "image": "models/fish.json",
              "effects": [
                {
                  "file": "effects/opacity/effect.json",
                  "passes": [
                    { "textures": [null, "masks/fish-mask"] }
                  ]
                }
              ]
            }
          ]
        }
        """
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [
                (path: "models/fish.json", data: Data(#"{"material":"materials/fish.json"}"#.utf8)),
                (path: "materials/fish.json", data: Data(#"{"passes":[{"textures":["fish"]}]}"#.utf8)),
                (path: "materials/fish.tex", data: Data([1])),
                (path: "masks/fish-mask.tex", data: Data([2]))
            ]
        )

        // When
        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)

        // Then
        XCTAssertTrue(features.requiresMaskedEffectComposition)
        XCTAssertTrue(features.requiresEngineRenderer)
        XCTAssertTrue(features.runtimeGaps.contains("masked-effect-composition"))
    }

    func testRuntimeFeatureAnalyzerIgnoresMaskTextOutsideEffectMaskReferences() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "mask-name-only.pkg")
        let sceneJSON = """
        {
          "objects": [
            {
              "id": 1,
              "name": "Masked layer but no effect mask",
              "image": "models/fish.json"
            }
          ]
        }
        """
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [
                (path: "models/fish.json", data: Data(#"{"material":"materials/fish.json"}"#.utf8)),
                (path: "materials/fish.json", data: Data(#"{"passes":[{"textures":["fish"]}]}"#.utf8)),
                (path: "materials/fish.tex", data: Data([1]))
            ]
        )

        // When
        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)

        // Then
        XCTAssertFalse(features.requiresMaskedEffectComposition)
        XCTAssertFalse(features.runtimeGaps.contains("masked-effect-composition"))
    }

    func testRuntimeFeatureAnalyzerMarksModelOnlySceneAsEngineRendererRequirement() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "model-only.pkg")
        let sceneJSON = """
        {
          "objects": [
            { "id": 1, "name": "Ship mesh", "model": "models/ship.json" }
          ]
        }
        """
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [(path: "models/ship.json", data: Data([1]))]
        )

        // When
        let analysis = try ScenePackageAnalyzer().analyze(url: packageURL)

        // Then
        XCTAssertEqual(analysis.modelObjectCount, 1)
        XCTAssertTrue(analysis.requiresFullRenderer)
        XCTAssertTrue(analysis.runtimeFeatures.requiresModelRuntime)
        XCTAssertTrue(analysis.runtimeFeatures.runtimeGaps.contains("model-layer-runtime"))
        XCTAssertTrue(analysis.runtimeFeatures.runtimeGaps.contains("scene-dependency-analysis-uncertain"))
        XCTAssertTrue(analysis.runtimeFeatures.runtimeGaps.contains("audio-dependency-analysis-uncertain"))
    }

    func testRuntimeFeatureAnalyzerDetectsPuppetReferencedByImageModel() throws {
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "puppet-image.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"id":1,"name":"Puppet","image":"models/puppet.json"}]}"#,
            extraEntries: [
                (
                    path: "models/puppet.json",
                    data: Data(#"{"material":"materials/puppet.json","puppet":"puppets/character.pup"}"#.utf8)
                )
            ]
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
        let report = WallpaperCompatibilityAnalyzer().analyzeScene(
            entrypoint: packageURL,
            nativePlayable: true
        )

        XCTAssertTrue(features.requiresModelRuntime)
        XCTAssertTrue(features.requiresEngineRenderer)
        XCTAssertTrue(features.runtimeGaps.contains("model-layer-runtime"))
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
        XCTAssertTrue(report.requiredCapabilities.contains(.puppet))
    }

    func testRuntimeFeaturesDecodeLegacyUnknownLayerAsEngineRequirement() throws {
        let payload = Data(
            #"{"layers":[{"id":1,"name":"Light","kind":"unknown","effectFiles":[],"scriptCount":0,"constantShaderValueKeys":[]}],"materialFiles":[],"effectFiles":[],"shaderFiles":[],"textureFiles":[],"audioFiles":[],"videoFiles":[],"shaderUniforms":[],"requiresSceneScriptRuntime":false,"requiresParticleRuntime":false,"requiresSoundRuntime":false,"requiresModelRuntime":false,"requiresVideoTextureRuntime":false,"requiresShaderPipeline":false,"requiresAudioAnalysis":false,"requiresMaskedEffectComposition":false,"requiresClockRuntime":false,"requiresInteractionRuntime":false}"#.utf8
        )

        let features = try JSONDecoder().decode(SceneRuntimeFeatures.self, from: payload)

        XCTAssertTrue(features.unreadableRequiredAssetFiles.isEmpty)
        XCTAssertTrue(features.requiresUnrecognizedLayerRuntime)
        XCTAssertTrue(features.requiresEngineRenderer)
        XCTAssertEqual(features.runtimeGaps, ["unrecognized-layer-runtime"])
    }

    func testOversizedImageModelIsConservativelyRoutedToEngineRenderer() throws {
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "oversized-image-model.pkg")
        let oversizedModel = Data(
            (#"{"material":"materials/basic.json","padding":""#
                + String(repeating: "x", count: 8 * 1_024 * 1_024)
                + #""}"#).utf8
        )
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"id":1,"name":"Large model","image":"models/large.json"}]}"#,
            extraEntries: [(path: "models/large.json", data: oversizedModel)]
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
        let report = WallpaperCompatibilityAnalyzer().analyzeScene(
            entrypoint: packageURL,
            nativePlayable: true
        )

        XCTAssertTrue(features.requiresModelRuntime)
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
        XCTAssertTrue(report.requiredCapabilities.contains(.puppet))
    }

    func testEmbeddedMP4TextureRoutesMixedSceneToRenderedCache() throws {
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "embedded-video-texture.pkg")
        let embeddedVideoTexture = Fixture.animatedTexData(
            textureWidth: 4,
            textureHeight: 2,
            container: "TEXB0004",
            isVideoMP4: true,
            mipmaps: [(width: 4, height: 2, data: Data(repeating: 0, count: 32))],
            frameContainer: nil
        )
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"id":1,"name":"Fallback text","text":{"value":"VISIBLE"}},{"id":2,"name":"Video","image":"models/video.json"}]}"#,
            extraEntries: [
                (path: "models/video.json", data: Data(#"{"material":"materials/video.json"}"#.utf8)),
                (path: "materials/video.json", data: Data(#"{"passes":[{"textures":["video"]}]}"#.utf8)),
                (path: "materials/video.tex", data: embeddedVideoTexture)
            ]
        )

        XCTAssertTrue(SceneRenderPlanBuilder().canBuild(url: packageURL))
        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .scene,
            status: .playable,
            entrypoint: packageURL
        )

        XCTAssertTrue(features.requiresVideoTextureRuntime)
        XCTAssertEqual(features.videoFiles, ["materials/video.tex"])
        XCTAssertEqual(try ScenePackageAnalyzer().analyze(url: packageURL).videoEntryCount, 1)
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
        XCTAssertTrue(report.requiredCapabilities.contains(.videoTexture))
    }

    func testSceneBeyondNativeLayerLimitRoutesToRenderedCacheWithoutTruncation() throws {
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "many-layers.pkg")
        let objects = (1...25).map { index in
            #"{"id":\#(index),"name":"Layer \#(index)","text":{"value":"\#(index)"}}"#
        }.joined(separator: ",")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: "{\"objects\":[\(objects)]}"
        )

        XCTAssertThrowsError(try SceneRenderPlanBuilder().build(url: packageURL)) { error in
            XCTAssertEqual(error as? SceneRenderPlanError, .tooManyLayers(maximum: 24))
        }
        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .scene,
            status: .playable,
            entrypoint: packageURL
        )
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
        XCTAssertNotEqual(report.playbackPath, .nativeScene)
    }

    func testProjectAudioProcessingFlagMakesOtherwiseNativeSceneLimited() throws {
        let root = try Fixture.makeTempDirectory()
        let content = root.appending(path: "content", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        let packageURL = content.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"id":1,"name":"Title","text":{"value":"VISIBLE"}}]}"#
        )
        try #"{"title":"Audio Scene","type":"scene","file":"content/scene.pkg","general":{"supportsaudioprocessing":true}}"#
            .write(
                to: root.appending(path: "project.json"),
                atomically: true,
                encoding: .utf8
            )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(
            url: packageURL,
            projectRoot: root
        )
        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .scene,
            status: .playable,
            entrypoint: packageURL,
            projectRoot: root
        )
        let packageAnalysis = try ScenePackageAnalyzer().analyze(
            url: packageURL,
            projectRoot: root
        )

        XCTAssertTrue(features.requiresAudioAnalysis)
        XCTAssertTrue(packageAnalysis.runtimeFeatures.requiresAudioAnalysis)
        XCTAssertFalse(features.hasAudioDependencyUncertainty)
        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
        XCTAssertTrue(report.requiredCapabilities.contains(.audioReactive))
        XCTAssertTrue(report.missingCapabilities.contains(.audioReactive))
    }

    func testReachableParticleAudioModeIsDetectedButHiddenAndLiteralZeroAreNot() {
        let package = ScenePackage(magic: "PKGV0004", entries: [], data: Data())
        let reactiveScene: [String: Any] = [
            "objects": [
                [
                    "name": "Reactive",
                    "particle": [
                        "emitters": [["audioprocessingmode": 1]],
                        "operators": [
                            [
                                "name": "vortex",
                                "audioprocessingmode": ["value": 0, "user": "audio_mode"]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let neutralScene: [String: Any] = [
            "objects": [
                [
                    "name": "Hidden reactive",
                    "visible": false,
                    "particle": ["emitters": [["audioprocessingmode": 2]]]
                ],
                [
                    "name": "Visible neutral",
                    "particle": ["emitters": [["audioprocessingmode": 0]]]
                ]
            ]
        ]

        let reactive = SceneRuntimeFeatureAnalyzer().analyze(
            package: package,
            scene: reactiveScene
        )
        let neutral = SceneRuntimeFeatureAnalyzer().analyze(
            package: package,
            scene: neutralScene
        )

        XCTAssertTrue(reactive.requiresAudioAnalysis)
        XCTAssertFalse(reactive.hasAudioDependencyUncertainty)
        XCTAssertFalse(neutral.requiresAudioAnalysis)
        XCTAssertFalse(neutral.hasAudioDependencyUncertainty)
    }

    func testReachableAudioSpectrum64ShaderUniformIsDetected() throws {
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "audio-spectrum-64.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"name":"Audio shader","image":"models/audio.json"}]}"#,
            extraEntries: [
                (
                    path: "models/audio.json",
                    data: Data(#"{"material":"materials/audio.json"}"#.utf8)
                ),
                (
                    path: "materials/audio.json",
                    data: Data(#"{"passes":[{"shader":"audio"}]}"#.utf8)
                ),
                (path: "shaders/audio.vert", data: Data("void main() {}".utf8)),
                (
                    path: "shaders/audio.frag",
                    data: Data("float level = g_AudioSpectrum64Right[3];\nvoid main() {}".utf8)
                )
            ]
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .scene,
            status: .playable,
            entrypoint: packageURL
        )

        XCTAssertTrue(features.shaderUniforms.contains("g_AudioSpectrum64Right"))
        XCTAssertTrue(features.requiresAudioAnalysis)
        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
        XCTAssertTrue(report.requiredCapabilities.contains(.audioReactive))
        XCTAssertTrue(report.missingCapabilities.contains(.audioReactive))
    }

    func testAudioShaderIdentifiersInsideCommentsDoNotMakeSceneLimited() throws {
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "commented-audio-uniform.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"name":"Static shader","image":"models/static.json"}]}"#,
            extraEntries: [
                (
                    path: "models/static.json",
                    data: Data(#"{"material":"materials/static.json"}"#.utf8)
                ),
                (
                    path: "materials/static.json",
                    data: Data(#"{"passes":[{"shader":"static"}]}"#.utf8)
                ),
                (path: "shaders/static.vert", data: Data("void main() {}".utf8)),
                (
                    path: "shaders/static.frag",
                    data: Data(
                        """
                        // g_AudioSpectrum64Right is intentionally not used.
                        /* g_AudioPower
                           g_AudioSpectrum32Left */
                        float level = 1.0;
                        void main() {}
                        """.utf8
                    )
                )
            ]
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: .scene,
            status: .playable,
            entrypoint: packageURL
        )

        XCTAssertFalse(features.shaderUniforms.contains { $0.hasPrefix("g_Audio") })
        XCTAssertFalse(features.requiresAudioAnalysis)
        XCTAssertFalse(report.requiredCapabilities.contains(.audioReactive))
        XCTAssertFalse(report.missingCapabilities.contains(.audioReactive))
        XCTAssertEqual(report.level, .full)
    }

    func testReachablePackagedParticleAudioModeIsDetected() throws {
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "packaged-audio-particle.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"name":"Reactive particle","particle":"particles/reactive.json"}]}"#,
            extraEntries: [
                (
                    path: "particles/reactive.json",
                    data: Data(#"{"emitters":[{"name":"box","audioprocessingmode":1}]}"#.utf8)
                )
            ]
        )

        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)

        XCTAssertTrue(features.requiresAudioAnalysis)
        XCTAssertFalse(features.hasAudioDependencyUncertainty)
    }
}

private func littleEndianInt32Bytes(_ value: Int) -> Data {
    var raw = Int32(value).littleEndian
    return Swift.withUnsafeBytes(of: &raw) { Data($0) }
}
