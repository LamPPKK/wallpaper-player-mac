import Foundation
import XCTest
@testable import BackgroundEngineApp

final class SceneVideoCacheKeySafetyTests: XCTestCase {
    func testLeadingDotAssetIDProducesVisibleBoundedCacheComponents() {
        let key = makeKey(assetID: ".hidden-workshop-item")

        XCTAssertFalse(key.fileName.hasPrefix("."))
        XCTAssertEqual(key.fileName.utf8.count, 141)
        XCTAssertTrue(key.fileName.utf8.allSatisfy { $0 < 128 })

        let legacyComponent = SceneVideoCache.cachedVideoURL(
            assetId: ".hidden-workshop-item"
        ).lastPathComponent
        XCTAssertFalse(legacyComponent.hasPrefix("."))
    }

    func testVeryLongAssetIDCanInstallAndDiscoverImmutableGeneration() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }

        let key = makeKey(assetID: String(repeating: "very-long-safe-id-", count: 2_000))
        let logicalURL = SceneVideoCache.cachedVideoURL(key: key)
        let sourceSceneURL = root.appending(path: "scene.pkg")
        let sourceVideoURL = root.appending(path: "rendered.mp4")
        try Data([0x50, 0x4B, 0x47, 0x56]).write(to: sourceSceneURL)
        try Data([0, 0, 0, 1]).write(to: sourceVideoURL)

        let generationURL = try SceneVideoCache.install(
            videoAt: sourceVideoURL,
            audioResult: .included,
            at: logicalURL
        )

        XCTAssertEqual(logicalURL.lastPathComponent.utf8.count, 141)
        XCTAssertLessThanOrEqual(generationURL.lastPathComponent.utf8.count, 255)
        XCTAssertLessThanOrEqual(
            SceneVideoCache.metadataURL(for: generationURL).lastPathComponent.utf8.count,
            255
        )
        XCTAssertEqual(SceneVideoCache.metadata(for: generationURL)?.audioResult, .included)
        XCTAssertEqual(
            canonicalPath(
                SceneVideoCache.freshCachedVideoURL(key: key, sourceURL: sourceSceneURL)
            ),
            canonicalPath(generationURL)
        )
    }

    func testDigestBackedDiscoveryRejectsSanitizationAndSafePrefixCollisions() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }
        try FileManager.default.createDirectory(
            at: SceneVideoCache.cacheDirectoryURL(),
            withIntermediateDirectories: true
        )

        let contentHash = "0123456789abcdef-full-revision"
        let victim = makeKey(assetID: "scene", contentHash: contentHash)
        // Under the old sanitized-prefix format this safe ID's filename began
        // with the victim's `scene-h0123456789abcdef-` discovery prefix.
        let safePrefixAttack = makeKey(
            assetID: "scene-h0123456789abcdef-evil",
            contentHash: "attacker-revision"
        )
        let slashID = makeKey(assetID: "scene/a", contentHash: contentHash)
        let questionID = makeKey(assetID: "scene?a", contentHash: contentHash)
        XCTAssertNotEqual(slashID.fileName, questionID.fileName)
        XCTAssertNotEqual(victim.fileName, safePrefixAttack.fileName)

        let sourceURL = root.appending(path: "scene.pkg")
        try Data([0x50, 0x4B, 0x47, 0x56]).write(to: sourceURL)
        let attackerURL = SceneVideoCache.cachedVideoURL(key: safePrefixAttack)
        try Data([0, 0, 0, 1]).write(to: attackerURL)

        XCTAssertNil(
            SceneVideoCache.freshCachedVideoURL(
                assetID: victim.assetID,
                contentHash: victim.contentHash,
                sourceURL: sourceURL
            )
        )

        let sourceVideoURL = root.appending(path: "victim-render.mp4")
        try Data([0, 0, 0, 2]).write(to: sourceVideoURL)
        let victimURL = try SceneVideoCache.install(
            videoAt: sourceVideoURL,
            audioResult: .notRequired,
            at: SceneVideoCache.cachedVideoURL(key: victim)
        )
        XCTAssertEqual(
            canonicalPath(SceneVideoCache.freshCachedVideoURL(
                assetID: victim.assetID,
                contentHash: victim.contentHash,
                sourceURL: sourceURL
            )),
            canonicalPath(victimURL)
        )
    }

    func testGenerationDiscoveryRejectsPrefixOnlyAndMalformedSuffixes() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }
        try FileManager.default.createDirectory(
            at: SceneVideoCache.cacheDirectoryURL(),
            withIntermediateDirectories: true
        )

        let key = makeKey(assetID: "generation-prefix")
        let sourceURL = root.appending(path: "scene.pkg")
        try Data([0x50, 0x4B, 0x47, 0x56]).write(to: sourceURL)
        let logicalURL = SceneVideoCache.cachedVideoURL(key: key)
        let malformedURL = logicalURL.deletingLastPathComponent().appending(
            path: "\(logicalURL.deletingPathExtension().lastPathComponent)-g0000000000000000-\(UUID().uuidString)-extra.mp4"
        )
        try Data([0, 0, 0, 1]).write(to: malformedURL)

        XCTAssertNil(SceneVideoCache.freshCachedVideoURL(key: key, sourceURL: sourceURL))
    }

    private func makeKey(
        assetID: String,
        contentHash: String = "content-revision"
    ) -> SceneVideoCacheKey {
        SceneVideoCacheKey(
            assetID: assetID,
            contentHash: contentHash,
            rendererVersion: "renderer-version",
            mediaBuildID: "media-build",
            engineAssetsFingerprint: "engine-assets",
            width: 1_920,
            height: 1_080,
            quality: .balanced
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SceneVideoCacheKeySafetyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func canonicalPath(_ url: URL?) -> String? {
        url?.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
