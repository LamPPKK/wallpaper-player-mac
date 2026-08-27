import Foundation
import XCTest
import BackgroundEngineCore
@testable import BackgroundEngineApp

final class LibraryRowStatusResolverTests: XCTestCase {
    func testSceneWithoutCachedVideoNeedsFirstRender() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appending(path: "scene.pkg")
        try "scene-package".write(to: sourceURL, atomically: true, encoding: .utf8)
        let asset = Self.sceneAsset(root: root, entrypoint: sourceURL)

        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }

        // When
        let status = LibraryRowStatusResolver.status(for: asset)

        // Then
        XCTAssertEqual(status, .live)
        XCTAssertEqual(status.label, "Full Live")
        XCTAssertTrue(status.isPositive)
    }

    func testSceneWithFreshCachedVideoIsPlayable() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appending(path: "scene.pkg")
        try "scene-package".write(to: sourceURL, atomically: true, encoding: .utf8)
        let asset = Self.sceneAsset(root: root, entrypoint: sourceURL)

        let cacheDirectory = root.appending(path: "SceneVideoCache")
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }
        let renderedVideoURL = root.appending(path: "rendered.mp4")
        try "fake-cached-video".write(
            to: renderedVideoURL,
            atomically: true,
            encoding: .utf8
        )
        _ = try SceneVideoCache.install(
            videoAt: renderedVideoURL,
            audioResult: .notRequired,
            at: SceneVideoCache.cachedVideoURL(assetId: asset.id)
        )

        // When
        let status = LibraryRowStatusResolver.status(for: asset)

        // Then
        XCTAssertEqual(status, .cached)
        XCTAssertEqual(status.label, "Full Cached")
        XCTAssertTrue(status.isPositive)
    }

    func testNonSceneAssetIsUnaffected() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = WallpaperAsset(
            id: root.lastPathComponent,
            title: "Video",
            kind: .video,
            supportStatus: .playable,
            source: .localSteamWorkshop,
            projectDirectory: root.path,
            entrypoint: root.appending(path: "video.mp4").path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )

        // When
        let status = LibraryRowStatusResolver.status(for: asset)

        // Then
        XCTAssertEqual(status, .live)
        XCTAssertEqual(status.label, "Full Live")
        XCTAssertTrue(status.isPositive)
    }

    func testCompatibilityReportTakesPriorityAndShowsLimitedCapabilities() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = WallpaperAsset(
            id: "limited-web",
            title: "Limited Web",
            kind: .web,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: root.path,
            entrypoint: root.appending(path: "index.html").path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .limited(reason: "Neutral audio data."),
            compatibilityReport: CompatibilityReport(
                level: .limited,
                playbackPath: .webLive,
                requiredCapabilities: [.audioReactive],
                missingCapabilities: [.audioReactive]
            ),
            redistributionAllowed: false,
            issues: []
        )

        let status = LibraryRowStatusResolver.status(for: asset)

        XCTAssertEqual(status, .limited([.audioReactive]))
        XCTAssertEqual(status.label, "Limited")
        XCTAssertTrue(status.isPositive)
    }

    func testNonPlayableAssetKeepsExistingSupportStatusLabel() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = WallpaperAsset(
            id: root.lastPathComponent,
            title: "Legacy Video",
            kind: .video,
            supportStatus: .needsConversion,
            source: .localSteamWorkshop,
            projectDirectory: root.path,
            entrypoint: root.appending(path: "video.avi").path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )

        // When
        let status = LibraryRowStatusResolver.status(for: asset)

        // Then
        XCTAssertEqual(status, .unsupported(.needsConversion))
        XCTAssertEqual(status.label, "Unsupported")
        XCTAssertFalse(status.isPositive)
    }

    private static func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wwb-libraryrow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func sceneAsset(root: URL, entrypoint: URL) -> WallpaperAsset {
        WallpaperAsset(
            id: root.lastPathComponent,
            title: "Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .localSteamWorkshop,
            projectDirectory: root.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
    }
}
