import Foundation
import XCTest
@testable import BackgroundEngineApp

@MainActor
final class SceneVideoCacheCancellationTests: XCTestCase {
    func testCancellationDuringFingerprintDoesNotPublishCacheGeneration() throws {
        try assertCancelledInstallPublishesNothing(throwOnCheck: 3)
    }

    func testCancellationImmediatelyBeforeVisibilityPointDoesNotPublishCacheGeneration() throws {
        // For a one-byte source, check 9 runs after the sidecar is staged at
        // its final name and immediately before the MP4's atomic move.
        try assertCancelledInstallPublishesNothing(throwOnCheck: 9)
    }

    func testSuccessfulVisibilityMoveIsNotRolledBackByLateCancellation() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "scene-cache-commit-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(
            path: "SceneVideoCache",
            directoryHint: .isDirectory
        )
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }

        let sourceURL = root.appending(path: "render-output.mp4")
        try Data([0x01]).write(to: sourceURL)
        var checkCount = 0
        let installedURL = try SceneVideoCache.install(
            videoAt: sourceURL,
            audioResult: .notRequired,
            at: SceneVideoCache.cachedVideoURL(assetId: "committed-scene"),
            cancellationCheck: {
                checkCount += 1
                if checkCount == 10 {
                    throw CancellationError()
                }
            }
        )

        XCTAssertEqual(checkCount, 9, "No cancellation check may run after the commit rename.")
        XCTAssertTrue(fileManager.fileExists(atPath: installedURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: SceneVideoCache.metadataURL(for: installedURL).path))
    }

    private func assertCancelledInstallPublishesNothing(throwOnCheck: Int) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "scene-cache-cancel-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        let cacheDirectory = root.appending(path: "SceneVideoCache", directoryHint: .isDirectory)
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }

        let sourceURL = root.appending(path: "render-output.mp4")
        try Data([0x01]).write(to: sourceURL)
        let logicalOutputURL = SceneVideoCache.cachedVideoURL(assetId: "cancelled-scene")
        var checkCount = 0

        XCTAssertThrowsError(
            try SceneVideoCache.install(
                videoAt: sourceURL,
                audioResult: .notRequired,
                at: logicalOutputURL,
                cancellationCheck: {
                    checkCount += 1
                    if checkCount == throwOnCheck {
                        throw CancellationError()
                    }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }

        let publishedFiles = (try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        XCTAssertTrue(
            publishedFiles.isEmpty,
            "A cancelled install must not leave a discoverable MP4 or sidecar: \(publishedFiles)"
        )
    }
}
