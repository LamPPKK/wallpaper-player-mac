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
            verticalAlignment: .center,
            dynamicText: .clock(SceneClockText(
                uses24HourFormat: true,
                showsSeconds: true,
                delimiter: ":"
            ))
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

    private func makeLayer(id: Int, name: String, text: SceneTextLayer) -> SceneLayer {
        SceneLayer(
            id: id,
            name: name,
            texturePath: "",
            text: text,
            origin: SceneVector3(x: 960, y: 540, z: Double(id)),
            size: SceneSize(width: 480, height: 120),
            scale: SceneVector3(x: 1, y: 1, z: 1),
            alpha: 1,
            originAnimation: nil
        )
    }
}
