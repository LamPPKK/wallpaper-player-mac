import Foundation
import XCTest
@testable import BackgroundEngineApp

final class ScenePlaybackStrategyTests: XCTestCase {
    private let cached = URL(filePath: "/tmp/background-engine-scene-cache.mp4")

    func testLiveSceneRequiresValidatedNativeReconstruction() {
        let strategy = ScenePlaybackStrategyResolver().resolve(
            prefersValidatedNative: true,
            forcesCachedPlayback: false,
            resources: .init(
                cachedVideoURL: cached,
                hasExternalRenderer: true,
                hasEngineAssets: true,
                hasMediaTools: true
            )
        )

        XCTAssertEqual(strategy, .validatedNative)
    }

    func testFailedLiveSceneCanForceKnownGoodCache() {
        let strategy = ScenePlaybackStrategyResolver().resolve(
            prefersValidatedNative: true,
            forcesCachedPlayback: true,
            resources: .init(
                cachedVideoURL: cached,
                hasExternalRenderer: true,
                hasEngineAssets: true,
                hasMediaTools: true
            )
        )

        XCTAssertEqual(strategy, .cachedVideo(cached))
    }

    func testNonLiveSceneUsesCacheBeforeStartingRenderer() {
        let strategy = ScenePlaybackStrategyResolver().resolve(
            prefersValidatedNative: false,
            forcesCachedPlayback: false,
            resources: .init(
                cachedVideoURL: cached,
                hasExternalRenderer: true,
                hasEngineAssets: true,
                hasMediaTools: true
            )
        )

        XCTAssertEqual(strategy, .cachedVideo(cached))
    }

    func testCompleteRuntimeRendersCacheAndMissingRuntimeUsesApproximation() {
        let resolver = ScenePlaybackStrategyResolver()
        XCTAssertEqual(
            resolver.resolve(
                prefersValidatedNative: false,
                forcesCachedPlayback: false,
                resources: .init(
                    cachedVideoURL: nil,
                    hasExternalRenderer: true,
                    hasEngineAssets: true,
                    hasMediaTools: true
                )
            ),
            .renderCache
        )

        let limited = resolver.resolve(
            prefersValidatedNative: false,
            forcesCachedPlayback: false,
            resources: .init(
                cachedVideoURL: nil,
                hasExternalRenderer: true,
                hasEngineAssets: false,
                hasMediaTools: true
            )
        )
        guard case .nativeApproximation(let reason) = limited else {
            return XCTFail("Expected native approximation")
        }
        XCTAssertTrue(reason.contains("Wallpaper Engine assets folder"))
    }

    func testPreparedSceneCrossfadesAfterFullDecode() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/SceneWallpaperView.swift")

        XCTAssertTrue(source.contains("replacePreparedContent(with:"))
        XCTAssertTrue(source.contains("accessibilityDisplayShouldReduceMotion"))
        XCTAssertTrue(source.contains("context.duration = 0.25"))
    }
}
