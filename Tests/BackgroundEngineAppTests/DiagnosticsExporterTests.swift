import BackgroundEngineCore
import Foundation
import XCTest
@testable import BackgroundEngineApp

final class DiagnosticsExporterTests: XCTestCase {
    func testExportContainsFeatureFingerprintButNoPathsOrSteamIDs() throws {
        let health = RuntimeHealth(
            sceneRenderer: .init(availability: .available, version: "renderer", detail: "ready"),
            mediaTools: .init(availability: .available, version: "ffmpeg", detail: "ready"),
            engineAssets: .init(availability: .available, version: "fingerprint", detail: "ready")
        )
        let asset = WallpaperAsset(
            id: "1234567890",
            title: "Private title",
            kind: .scene,
            supportStatus: .playable,
            source: .localSteamWorkshop,
            projectDirectory: "/Users/alice/steamapps/workshop/content/431960/1234567890",
            entrypoint: "/Users/alice/steamapps/workshop/content/431960/1234567890/scene.pkg",
            thumbnail: nil,
            workshopId: "1234567890",
            compatibility: .limited(reason: "Interaction unavailable."),
            compatibilityReport: CompatibilityReport(
                level: .limited,
                playbackPath: .renderedSceneCache,
                requiredCapabilities: [.interaction, .shader],
                missingCapabilities: [.interaction],
                diagnosticCode: "scene_live_capabilities_limited"
            ),
            redistributionAllowed: false,
            issues: []
        )

        let data = try DiagnosticsExporter.data(
            appVersion: "0.2.0-alpha.1",
            runtime: health,
            assets: [asset],
            log: ["Failed at /Users/alice/steamapps/workshop/content/431960/1234567890/scene.pkg"],
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("scene_live_capabilities_limited"))
        XCTAssertTrue(json.contains("interaction"))
        XCTAssertFalse(json.contains("Private title"))
        XCTAssertFalse(json.contains("/Users/alice"))
        XCTAssertFalse(json.contains("1234567890"))
    }

    func testSanitizerRedactsPathsContainingSpaces() {
        let sanitized = DiagnosticsExporter.sanitize(
            "renderer failed at /Users/alice/My Secret Wallpapers/scene.pkg, retrying"
        )

        XCTAssertEqual(sanitized, "renderer failed at <redacted>, retrying")
        XCTAssertFalse(sanitized.contains("Secret Wallpapers"))
    }
}
