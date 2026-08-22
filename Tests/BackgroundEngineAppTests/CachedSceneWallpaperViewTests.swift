import BackgroundEngineCore
import XCTest
@testable import BackgroundEngineApp

final class CachedSceneWallpaperViewTests: XCTestCase {
    func testSelectsOnlyDynamicClockLayersForNativeOverlay() {
        let clock = SceneTextLayer(
            value: "00:00",
            fontPath: nil,
            pointSize: 48,
            color: SceneColor(red: 1, green: 1, blue: 1),
            horizontalAlignment: .center,
            verticalAlignment: .top,
            dynamicText: .clock(SceneClockText(
                uses24HourFormat: true,
                showsSeconds: false,
                delimiter: ":"
            )),
            script: SceneTextScript(source: Self.paddedClockScript)
        )
        let staticText = SceneTextLayer(
            value: "Static",
            fontPath: nil,
            pointSize: 32,
            color: SceneColor(red: 1, green: 1, blue: 1),
            horizontalAlignment: .center,
            verticalAlignment: .center
        )
        let plan = SceneRenderPlan(
            canvasSize: SceneSize(width: 1_920, height: 1_080),
            layers: [
                makeLayer(id: 1, name: "clock", text: clock),
                makeLayer(id: 2, name: "static", text: staticText)
            ],
            textures: [:]
        )

        let overlays = CachedSceneWallpaperView.clockLayerPlans(in: plan)

        XCTAssertEqual(overlays.map(\.name), ["clock"])
    }

    func testMaskedScriptedClockStaysBakedWithoutNativeOverlay() {
        let clock = SceneTextLayer(
            value: "00:00",
            fontPath: nil,
            pointSize: 48,
            color: SceneColor(red: 1, green: 1, blue: 1),
            horizontalAlignment: .center,
            verticalAlignment: .center,
            dynamicText: .clock(SceneClockText(
                uses24HourFormat: true,
                showsSeconds: false,
                delimiter: ":"
            )),
            script: SceneTextScript(source: Self.paddedClockScript)
        )
        let maskedLayer = makeLayer(
            id: 1,
            name: "masked-clock",
            text: clock,
            effectSettings: [SceneLayerEffectSetting(effect: .opacity, usesMask: true)]
        )
        let plan = SceneRenderPlan(
            canvasSize: SceneSize(width: 1_920, height: 1_080),
            layers: [maskedLayer],
            textures: [:]
        )

        XCTAssertEqual(SceneLiveTextRecordingPolicy.policy(for: plan), .bakeAll)
        XCTAssertTrue(CachedSceneWallpaperView.clockLayerPlans(in: plan).isEmpty)
    }

    func testEffectedScriptedClockStaysBakedWithoutNativeOverlay() {
        let clock = SceneTextLayer(
            value: "00:00",
            fontPath: nil,
            pointSize: 48,
            color: SceneColor(red: 1, green: 1, blue: 1),
            horizontalAlignment: .center,
            verticalAlignment: .top,
            dynamicText: .clock(SceneClockText(
                uses24HourFormat: true,
                showsSeconds: false,
                delimiter: ":"
            )),
            script: SceneTextScript(source: Self.paddedClockScript)
        )
        let effectedLayer = makeLayer(
            id: 1,
            name: "faded-clock",
            text: clock,
            effectSettings: [SceneLayerEffectSetting(effect: .opacity, strength: 0.25)]
        )
        let plan = SceneRenderPlan(
            canvasSize: SceneSize(width: 1_920, height: 1_080),
            layers: [effectedLayer],
            textures: [:]
        )

        XCTAssertEqual(SceneLiveTextRecordingPolicy.policy(for: plan), .bakeAll)
        XCTAssertTrue(CachedSceneWallpaperView.clockLayerPlans(in: plan).isEmpty)
    }

    func testLiveTextRecordingPolicyBakesNonClockScriptsInsteadOfDroppingThem() {
        let clock = SceneTextLayer(
            value: "00:00",
            fontPath: nil,
            pointSize: 48,
            color: SceneColor(red: 1, green: 1, blue: 1),
            horizontalAlignment: .center,
            verticalAlignment: .top,
            dynamicText: .clock(SceneClockText(
                uses24HourFormat: true,
                showsSeconds: false,
                delimiter: ":"
            )),
            script: SceneTextScript(source: Self.paddedClockScript)
        )
        let scriptedLabel = SceneTextLayer(
            value: "READY",
            fontPath: nil,
            pointSize: 48,
            color: SceneColor(red: 1, green: 1, blue: 1),
            horizontalAlignment: .center,
            verticalAlignment: .center,
            script: SceneTextScript(source: "export function update() { return 'READY'; }")
        )
        let clockOnly = SceneRenderPlan(
            canvasSize: SceneSize(width: 1_920, height: 1_080),
            layers: [makeLayer(id: 1, name: "clock", text: clock)],
            textures: [:]
        )
        let mixed = SceneRenderPlan(
            canvasSize: clockOnly.canvasSize,
            layers: clockOnly.layers + [makeLayer(id: 2, name: "label", text: scriptedLabel)],
            textures: [:]
        )

        XCTAssertEqual(SceneLiveTextRecordingPolicy.policy(for: clockOnly), .overlayClocks)
        XCTAssertEqual(SceneLiveTextRecordingPolicy.policy(for: mixed), .bakeAll)
    }

    func testLiveTextRecordingPolicyBakesClockKeywordFalsePositive() {
        let misleadingScript = """
        export function update(value) {
            const time = new Date();
            const ignoredHours = time.getHours();
            const ignoredMinutes = time.getMinutes();
            return 'NOT A CLOCK';
        }
        """
        let text = SceneTextLayer(
            value: "00:00",
            fontPath: nil,
            pointSize: 48,
            color: SceneColor(red: 1, green: 1, blue: 1),
            horizontalAlignment: .center,
            verticalAlignment: .center,
            dynamicText: .clock(SceneClockText(
                uses24HourFormat: true,
                showsSeconds: false,
                delimiter: ":"
            )),
            script: SceneTextScript(source: misleadingScript)
        )
        let plan = SceneRenderPlan(
            canvasSize: SceneSize(width: 1_920, height: 1_080),
            layers: [makeLayer(id: 1, name: "not-clock", text: text)],
            textures: [:]
        )

        XCTAssertEqual(SceneLiveTextRecordingPolicy.policy(for: plan), .bakeAll)
    }

    func testLiveTextRecordingPolicyBakesConditionallyDifferentClockScript() {
        let conditionalScript = """
        export function update(value) {
            const time = new Date();
            let hours = time.getHours();
            let minutes = time.getMinutes();
            if (hours < 10) { hours = '0' + hours; }
            if (minutes < 10) { minutes = '0' + minutes; }
            if (hours == 8) { return 'ALARM ' + hours + ':' + minutes; }
            return hours + ':' + minutes;
        }
        """
        let text = SceneTextLayer(
            value: "00:00",
            fontPath: nil,
            pointSize: 48,
            color: SceneColor(red: 1, green: 1, blue: 1),
            horizontalAlignment: .center,
            verticalAlignment: .center,
            dynamicText: .clock(SceneClockText(
                uses24HourFormat: true,
                showsSeconds: false,
                delimiter: ":"
            )),
            script: SceneTextScript(source: conditionalScript)
        )
        let plan = SceneRenderPlan(
            canvasSize: SceneSize(width: 1_920, height: 1_080),
            layers: [makeLayer(id: 1, name: "conditional-clock", text: text)],
            textures: [:]
        )

        XCTAssertEqual(SceneLiveTextRecordingPolicy.policy(for: plan), .bakeAll)
    }

    func testLiveTextRecordingPolicyPreservesWhitespaceInsideScriptStrings() {
        let differentDelimiterScript = Self.paddedClockScript.replacingOccurrences(
            of: "return hours + ':' + minutes;",
            with: "return hours + ': ' + minutes;"
        )
        let text = SceneTextLayer(
            value: "00:00",
            fontPath: nil,
            pointSize: 48,
            color: SceneColor(red: 1, green: 1, blue: 1),
            horizontalAlignment: .center,
            verticalAlignment: .center,
            dynamicText: .clock(SceneClockText(
                uses24HourFormat: true,
                showsSeconds: false,
                delimiter: ":"
            )),
            script: SceneTextScript(source: differentDelimiterScript)
        )
        let plan = SceneRenderPlan(
            canvasSize: SceneSize(width: 1_920, height: 1_080),
            layers: [makeLayer(id: 1, name: "spaced-clock", text: text)],
            textures: [:]
        )

        XCTAssertEqual(SceneLiveTextRecordingPolicy.policy(for: plan), .bakeAll)
    }

    func testForcedSceneCacheRevisionKeyChangesWhenWorkshopContentChanges() {
        let original = makeAsset(contentHash: "revision-a")
        let updated = makeAsset(contentHash: "revision-b")

        XCTAssertNotEqual(
            SceneWallpaperContentFactory.revisionKey(for: original),
            SceneWallpaperContentFactory.revisionKey(for: updated)
        )
    }

    private static let paddedClockScript = """
    export function update(value) {
        const time = new Date();
        let hours = time.getHours();
        let minutes = time.getMinutes();
        if (hours < 10) { hours = '0' + hours; }
        if (minutes < 10) { minutes = '0' + minutes; }
        return hours + ':' + minutes;
    }
    """

    private func makeAsset(contentHash: String) -> WallpaperAsset {
        WallpaperAsset(
            id: "same-scene",
            title: "Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: "/tmp/same-scene",
            entrypoint: "/tmp/same-scene/scene.pkg",
            thumbnail: nil,
            workshopId: "123",
            contentHash: contentHash,
            redistributionAllowed: false,
            issues: []
        )
    }

    private func makeLayer(
        id: Int,
        name: String,
        text: SceneTextLayer,
        effectSettings: [SceneLayerEffectSetting] = []
    ) -> SceneLayer {
        SceneLayer(
            id: id,
            name: name,
            texturePath: "",
            text: text,
            effectSettings: effectSettings,
            origin: SceneVector3(x: 960, y: 540, z: Double(id)),
            size: SceneSize(width: 480, height: 120),
            scale: SceneVector3(x: 1, y: 1, z: 1),
            alpha: 1,
            originAnimation: nil
        )
    }
}
