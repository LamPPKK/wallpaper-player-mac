import Foundation
import XCTest
@testable import BackgroundEngineCore

final class LibraryStoreTests: XCTestCase {
    func testImportCopiesProjectIntoLibraryAndPersistsManifest() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        try Fixture.project(
            root: sourceRoot,
            id: "777",
            metadata: #"{"title":"Neon","file":"neon.mp4"}"#,
            file: "neon.mp4"
        )
        let asset = try XCTUnwrap(WallpaperScanner().scan(root: sourceRoot).assets.first)
        let store = LibraryStore(root: try Fixture.makeTempDirectory())

        // When
        let imported = try store.importAsset(asset)
        let manifest = try store.load()

        // Then
        XCTAssertEqual(manifest.assets.map(\.id), ["777"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
        let importedVideoPath = URL(filePath: imported.projectDirectory).appending(path: "neon.mp4").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedVideoPath))
        XCTAssertEqual(imported.redistributionAllowed, false)
    }

    func testImportKeepsDistinctStorageForIdsThatNormalizeSimilarly() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        try Fixture.project(
            root: sourceRoot,
            id: "a b",
            metadata: #"{"title":"Space","file":"space.mp4"}"#,
            file: "space.mp4"
        )
        try Fixture.project(
            root: sourceRoot,
            id: "a_b",
            metadata: #"{"title":"Underscore","file":"under.mp4"}"#,
            file: "under.mp4"
        )
        let assets = try WallpaperScanner().scan(root: sourceRoot).assets
        let store = LibraryStore(root: try Fixture.makeTempDirectory())

        // When
        let imported = try assets.map { try store.importAsset($0) }
        let manifest = try store.load()

        // Then
        XCTAssertEqual(manifest.assets.map(\.id), ["a b", "a_b"])
        XCTAssertEqual(Set(imported.map(\.projectDirectory)).count, 2)
        XCTAssertTrue(imported.allSatisfy { FileManager.default.fileExists(atPath: $0.projectDirectory) })
    }

    func testImportRollsBackDirectorySwapWhenManifestSaveFails() throws {
        let root = try Fixture.makeTempDirectory()
        let writer = ControllableManifestWriter()
        let store = LibraryStore(
            root: root,
            trasher: FileManagerAssetTrasher(),
            manifestWriter: writer
        )
        let firstSource = try Fixture.makeTempDirectory()
        let firstFile = firstSource.appending(path: "wallpaper.mp4")
        try Data([1]).write(to: firstFile)
        let first = WallpaperAsset(
            id: "atomic-import",
            title: "First",
            kind: .video,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: firstSource.path,
            entrypoint: firstFile.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .direct),
            redistributionAllowed: false,
            issues: []
        )
        let imported = try store.importAsset(first)
        let secondSource = try Fixture.makeTempDirectory()
        let secondFile = secondSource.appending(path: "wallpaper.mp4")
        try Data([2]).write(to: secondFile)
        let replacement = WallpaperAsset(
            id: first.id,
            title: "Second",
            kind: first.kind,
            supportStatus: first.supportStatus,
            source: first.source,
            projectDirectory: secondSource.path,
            entrypoint: secondFile.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: first.compatibility,
            compatibilityReport: first.compatibilityReport,
            redistributionAllowed: false,
            issues: []
        )
        writer.failNextWrite()

        XCTAssertThrowsError(try store.importAsset(replacement))

        let persisted = try XCTUnwrap(store.load().assets.first)
        XCTAssertEqual(persisted.title, "First")
        XCTAssertEqual(try Data(contentsOf: URL(filePath: try XCTUnwrap(imported.entrypoint))), Data([1]))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Assets").path)
            .filter { $0.contains(".incoming-") || $0.contains(".previous-") || $0.contains(".failed-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testImportVideoFileCopiesOnlySelectedVideoIntoLibrary() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "My Loop.mp4")
        let unrelated = sourceRoot.appending(path: "ignore.txt")
        FileManager.default.createFile(atPath: video.path, contents: Data([1, 2, 3]))
        FileManager.default.createFile(atPath: unrelated.path, contents: Data([4, 5, 6]))
        let store = LibraryStore(root: try Fixture.makeTempDirectory())

        // When
        let imported = try store.importVideoFile(video)
        let manifest = try store.load()

        // Then
        XCTAssertEqual(manifest.assets, [imported])
        XCTAssertEqual(imported.title, "My Loop")
        XCTAssertEqual(imported.kind, .video)
        XCTAssertEqual(imported.supportStatus, .playable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(imported.entrypoint)))
        let copiedIgnorePath = URL(filePath: imported.projectDirectory).appending(path: "ignore.txt").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedIgnorePath))
    }

    func testImportVideoFileRejectsUnsupportedFileType() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let text = sourceRoot.appending(path: "notes.txt")
        FileManager.default.createFile(atPath: text.path, contents: Data([1]))
        let store = LibraryStore(root: try Fixture.makeTempDirectory())

        // When / Then
        XCTAssertThrowsError(try store.importVideoFile(text))
    }

    func testImportVideoFileMarksConvertibleFormats() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "loop.webm")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try Fixture.makeTempDirectory())

        // When
        let imported = try store.importVideoFile(video)

        // Then
        XCTAssertEqual(imported.supportStatus, .needsConversion)
    }

    func testInstallSceneRenderCacheCopiesVideoInsideImportedSceneDirectory() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "scene-cache")
        let scenePackage = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let asset = WallpaperAsset(
            id: "scene-cache",
            title: "Scene Cache",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: scenePackage.path,
            thumbnail: nil,
            workshopId: "scene-cache",
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(asset)
        let sourceVideo = try Fixture.makeTempDirectory().appending(path: "windows-reference.mp4")
        FileManager.default.createFile(atPath: sourceVideo.path, contents: Data([1, 2, 3]))

        // When
        let updated = try store.installSceneRenderCache(assetID: asset.id, videoURL: sourceVideo)

        // Then
        let cacheURL = SceneRenderCache.videoURL(in: project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertEqual(try Data(contentsOf: cacheURL), Data([1, 2, 3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceVideo.path))
        XCTAssertEqual(updated.supportStatus, .playable)
        XCTAssertTrue(updated.issues.contains { $0.code == SceneRenderCache.issueCode })
        XCTAssertTrue(updated.issues.contains {
            $0.message.contains("reference only")
                && $0.message.contains("native renderer")
        })
        XCTAssertEqual(SceneRenderCache.existingVideoURL(in: project)?.path, cacheURL.path)
    }

    func testInstallSceneRenderCacheReplacesStaleCacheCandidates() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "scene-cache-replace")
        let scenePackage = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let asset = WallpaperAsset(
            id: "scene-cache-replace",
            title: "Scene Cache Replace",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: scenePackage.path,
            thumbnail: nil,
            workshopId: "scene-cache-replace",
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(asset)
        let cacheDirectory = SceneRenderCache.cacheDirectory(in: project)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let stalePreferred = SceneRenderCache.videoURL(in: project, fileExtension: "mp4")
        let staleLegacy = project.appending(path: "render-cache.mov")
        let staleRendered = project.appending(path: "rendered.mp4")
        FileManager.default.createFile(atPath: stalePreferred.path, contents: Data([0]))
        FileManager.default.createFile(atPath: staleLegacy.path, contents: Data([1]))
        FileManager.default.createFile(atPath: staleRendered.path, contents: Data([2]))
        let sourceVideo = try Fixture.makeTempDirectory().appending(path: "windows-reference.mov")
        FileManager.default.createFile(atPath: sourceVideo.path, contents: Data([3, 4, 5]))

        // When
        _ = try store.installSceneRenderCache(assetID: asset.id, videoURL: sourceVideo)

        // Then
        let cacheURL = SceneRenderCache.videoURL(in: project, fileExtension: "mov")
        XCTAssertEqual(try Data(contentsOf: cacheURL), Data([3, 4, 5]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stalePreferred.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleLegacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRendered.path))
        XCTAssertEqual(SceneRenderCache.existingVideoURL(in: project)?.path, cacheURL.path)
    }

    func testInstallSceneRenderCacheRestoresKnownGoodCacheWhenManifestSaveFails() throws {
        let root = try Fixture.makeTempDirectory()
        let writer = ControllableManifestWriter()
        let store = LibraryStore(
            root: root,
            trasher: FileManagerAssetTrasher(),
            manifestWriter: writer
        )
        let project = try makeImportedProjectDirectory(in: root, id: "cache-rollback")
        let package = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: package,
            sceneJSON: #"{"objects":[{"text":{"value":"SAFE"},"size":"320 120"}]}"#
        )
        let asset = WallpaperAsset(
            id: "cache-rollback",
            title: "Cache Rollback",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: package.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .cached(reason: "Scene cache"),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .renderedSceneCache),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(asset)
        let oldVideo = try Fixture.makeTempDirectory().appending(path: "old.mp4")
        let newVideo = try Fixture.makeTempDirectory().appending(path: "new.mp4")
        try Data([1]).write(to: oldVideo)
        try Data([2]).write(to: newVideo)
        _ = try store.installSceneRenderCache(assetID: asset.id, videoURL: oldVideo)
        writer.failNextWrite()

        XCTAssertThrowsError(try store.installSceneRenderCache(assetID: asset.id, videoURL: newVideo))

        let cache = try XCTUnwrap(SceneRenderCache.existingVideoURL(in: project))
        XCTAssertEqual(try Data(contentsOf: cache), Data([1]))
    }

    func testInstallSceneRenderCacheRejectsNonSceneAsset() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "loop.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let imported = try store.importVideoFile(video)

        // When / Then
        XCTAssertThrowsError(try store.installSceneRenderCache(assetID: imported.id, videoURL: video)) { error in
            XCTAssertEqual(error as? LibraryStoreError, .assetIsNotScene(imported.id))
        }
    }

    func testInstallSceneRenderCacheRejectsSymlinkedCacheDirectory() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "scene-cache-symlink-dir")
        let scenePackage = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let asset = WallpaperAsset(
            id: "scene-cache-symlink-dir",
            title: "Scene Cache Symlink Dir",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: scenePackage.path,
            thumbnail: nil,
            workshopId: "scene-cache-symlink-dir",
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(asset)
        let outsideDirectory = try Fixture.makeTempDirectory()
        try FileManager.default.createSymbolicLink(
            at: SceneRenderCache.cacheDirectory(in: project),
            withDestinationURL: outsideDirectory
        )
        let sourceVideo = try Fixture.makeTempDirectory().appending(path: "windows-reference.mp4")
        FileManager.default.createFile(atPath: sourceVideo.path, contents: Data([1]))

        // When / Then
        XCTAssertThrowsError(try store.installSceneRenderCache(assetID: asset.id, videoURL: sourceVideo)) { error in
            XCTAssertEqual(error as? LibraryStoreError, .unsafeSceneRenderCacheDirectory(asset.id))
        }
    }

    func testSceneRenderCacheMakesReadableNativeIncompatibleScenePlayable() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "scene-cache-unsupported")
        let scenePackage = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: #"{"objects":[{"image":"models/background.json"}]}"#,
            extraEntries: [
                (path: "models/background.json", data: Data(#"{"material":"materials/background.json"}"#.utf8)),
                (path: "materials/background.json", data: Data(#"{"passes":[{"textures":["background"]}]}"#.utf8)),
                (path: "materials/background.tex", data: Data([1, 2, 3]))
            ]
        )
        let asset = WallpaperAsset(
            id: "scene-cache-unsupported",
            title: "Scene Cache Unsupported",
            kind: .scene,
            supportStatus: .unsupported,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: scenePackage.path,
            thumbnail: nil,
            workshopId: "scene-cache-unsupported",
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(asset)
        let sourceVideo = try Fixture.makeTempDirectory().appending(path: "windows-reference.mp4")
        FileManager.default.createFile(atPath: sourceVideo.path, contents: Data([1, 2, 3]))

        // When
        _ = try store.installSceneRenderCache(assetID: asset.id, videoURL: sourceVideo)
        let repaired = try XCTUnwrap(store.load().assets.first)

        // Then
        XCTAssertEqual(repaired.supportStatus, .playable)
        XCTAssertEqual(repaired.compatibilityReport?.playbackPath, .renderedSceneCache)
        XCTAssertEqual(repaired.compatibility?.label, "Cached")
        XCTAssertEqual(repaired.redistributionAllowed, false)
        XCTAssertTrue(repaired.issues.contains { $0.code == SceneRenderCache.issueCode })
        XCTAssertTrue(repaired.issues.contains { $0.code == "scene_renderer_limited" })
    }

    func testSceneRenderCacheRejectsSymlinkedVideoCache() throws {
        // Given
        let project = try Fixture.makeTempDirectory()
        let cacheDirectory = SceneRenderCache.cacheDirectory(in: project)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let outsideVideo = try Fixture.makeTempDirectory().appending(path: "outside.mp4")
        FileManager.default.createFile(atPath: outsideVideo.path, contents: Data([1]))
        let symlink = SceneRenderCache.videoURL(in: project)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideVideo)

        // Then
        XCTAssertNil(SceneRenderCache.existingVideoURL(in: project))
    }

    func testSceneRenderCacheRejectsVideoThroughSymlinkedCacheDirectory() throws {
        // Given
        let project = try Fixture.makeTempDirectory()
        let outsideDirectory = try Fixture.makeTempDirectory()
        let outsideVideo = SceneRenderCache.videoURL(in: outsideDirectory)
        FileManager.default.createFile(atPath: outsideVideo.path, contents: Data([1]))
        try FileManager.default.createSymbolicLink(
            at: SceneRenderCache.cacheDirectory(in: project),
            withDestinationURL: outsideDirectory
        )

        // Then
        XCTAssertNil(SceneRenderCache.existingVideoURL(in: project))
    }

    func testRemoveAssetDeletesLibraryDirectoryAndManifestEntry() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "remove-me.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let imported = try store.importVideoFile(video)

        // When
        try store.removeAsset(id: imported.id)
        let manifest = try store.load()

        // Then
        XCTAssertTrue(manifest.assets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.projectDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testRemoveAssetUsesTrashRatherThanPermanentDelete() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "trash-me.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let trasher = SpyAssetTrasher()
        let store = LibraryStore(root: try Fixture.makeTempDirectory(), trasher: trasher)
        let imported = try store.importVideoFile(video)

        // When
        try store.removeAsset(id: imported.id)

        // Then
        XCTAssertEqual(trasher.trashedURLs.count, 1)
        XCTAssertTrue(trasher.trashedURLs[0].lastPathComponent.contains(".retired-"))
        XCTAssertTrue(trasher.removedURLs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testRemoveAssetFallsBackToPermanentDeleteWhenTrashFails() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "fallback-me.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let trasher = SpyAssetTrasher()
        trasher.trashItemError = CocoaError(.fileWriteVolumeReadOnly)
        let store = LibraryStore(root: try Fixture.makeTempDirectory(), trasher: trasher)
        let imported = try store.importVideoFile(video)

        // When
        try store.removeAsset(id: imported.id)

        // Then
        XCTAssertEqual(trasher.trashedURLs.count, 1)
        XCTAssertTrue(trasher.trashedURLs[0].lastPathComponent.contains(".retired-"))
        XCTAssertEqual(trasher.removedURLs, trasher.trashedURLs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testRemoveAssetRestoresDirectoryWhenManifestSaveFails() throws {
        let root = try Fixture.makeTempDirectory()
        let writer = ControllableManifestWriter()
        let store = LibraryStore(
            root: root,
            trasher: FileManagerAssetTrasher(),
            manifestWriter: writer
        )
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "keep-on-save-failure.mp4")
        try Data([1]).write(to: video)
        let imported = try store.importVideoFile(video)
        writer.failNextWrite()

        XCTAssertThrowsError(try store.removeAsset(id: imported.id))

        XCTAssertEqual(try store.load().assets, [imported])
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testRemoveAssetRestoresManifestWhenTrashAndDeleteFail() throws {
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "restore-cleanup-failure.mp4")
        try Data([1]).write(to: video)
        let trasher = SpyAssetTrasher()
        trasher.trashItemError = CocoaError(.fileWriteVolumeReadOnly)
        trasher.removeItemError = CocoaError(.fileWriteNoPermission)
        let store = LibraryStore(root: try Fixture.makeTempDirectory(), trasher: trasher)
        let imported = try store.importVideoFile(video)

        XCTAssertThrowsError(try store.removeAsset(id: imported.id))

        XCTAssertEqual(try store.load().assets, [imported])
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testRemoveMissingAssetIsNoOp() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "keep-me.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let imported = try store.importVideoFile(video)

        // When
        try store.removeAsset(id: "missing")
        let manifest = try store.load()

        // Then
        XCTAssertEqual(manifest.assets, [imported])
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testStoresForSameRootSerializeConcurrentManifestMutations() async throws {
        let root = try Fixture.makeTempDirectory()
        let firstStore = LibraryStore(root: root)
        let secondStore = LibraryStore(root: root)
        let assets = (0..<24).map { index in
            WallpaperAsset(
                id: "concurrent-\(index)",
                title: "Concurrent \(index)",
                kind: .video,
                supportStatus: .playable,
                source: .manualFolder,
                projectDirectory: root.appending(path: "project-\(index)").path,
                entrypoint: root.appending(path: "project-\(index)/video.mp4").path,
                thumbnail: nil,
                workshopId: nil,
                compatibility: .live(),
                compatibilityReport: CompatibilityReport(level: .full, playbackPath: .direct),
                redistributionAllowed: false,
                issues: []
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, asset) in assets.enumerated() {
                let store = index.isMultiple(of: 2) ? firstStore : secondStore
                group.addTask {
                    try store.replaceAsset(asset)
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(Set(try firstStore.load().assets.map(\.id)), Set(assets.map(\.id)))
    }

    func testConditionalAssetReplaceDoesNotOverwriteNewerMutation() throws {
        let root = try Fixture.makeTempDirectory()
        let firstStore = LibraryStore(root: root)
        let secondStore = LibraryStore(root: root)
        let original = WallpaperAsset(
            id: "conditional-web",
            title: "Conditional Web",
            kind: .web,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: root.appending(path: "conditional-web").path,
            entrypoint: root.appending(path: "conditional-web/index.html").path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .webLive),
            allowsNetworkAccess: false,
            redistributionAllowed: false,
            issues: []
        )
        try firstStore.replaceAsset(original)
        let expected = try XCTUnwrap(firstStore.load().assets.first)
        _ = try secondStore.setWebNetworkAccess(assetID: original.id, allowed: true)
        let staleProbeResult = expected.replacing(
            compatibility: .limited(reason: "stale probe"),
            compatibilityReport: CompatibilityReport(
                level: .limited,
                playbackPath: .webLive,
                diagnosticCode: "stale_probe"
            )
        )

        let didReplace = try firstStore.replaceAsset(
            staleProbeResult,
            ifUnchangedFrom: expected
        )

        XCTAssertFalse(didReplace)
        let persisted = try XCTUnwrap(firstStore.load().assets.first)
        XCTAssertEqual(persisted.allowsNetworkAccess, true)
        XCTAssertNotEqual(persisted.compatibilityReport?.diagnosticCode, "stale_probe")
    }

    func testRemoveAssetDoesNotDeleteOutsideAssetsRoot() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let outside = try Fixture.makeTempDirectory()
        let outsideFile = outside.appending(path: "original.mp4")
        FileManager.default.createFile(atPath: outsideFile.path, contents: Data([1]))
        let asset = WallpaperAsset(
            id: "outside",
            title: "Outside",
            kind: .video,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: outside.path,
            entrypoint: outsideFile.path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(asset)

        // When
        try store.removeAsset(id: asset.id)
        let manifest = try store.load()

        // Then
        XCTAssertTrue(manifest.assets.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testLoadRepairsLegacyPreviewImageManifestForSceneProject() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "legacy-scene")
        let preview = project.appending(path: "preview.jpg")
        let scenePackage = project.appending(path: "scene.pkg")
        try #"{"title":"Scene","file":"scene.json","preview":"preview.jpg","type":"scene"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: preview.path, contents: Data([1]))
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: #"{"objects":[{"image":"models/background.json"}]}"#
        )
        let legacy = WallpaperAsset(
            id: "legacy-scene",
            title: "Scene",
            kind: .image,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: preview.path,
            thumbnail: preview.path,
            workshopId: "legacy-scene",
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(legacy)

        // When
        let repaired = try XCTUnwrap(store.load().assets.first)

        // Then
        XCTAssertEqual(repaired.id, legacy.id)
        XCTAssertEqual(repaired.kind, .scene)
        XCTAssertEqual(repaired.supportStatus, .playable)
        XCTAssertEqual(repaired.compatibilityReport?.playbackPath, .renderedSceneCache)
        XCTAssertEqual(standardPath(repaired.entrypoint), standardPath(scenePackage.path))
        XCTAssertEqual(repaired.thumbnail, preview.path)
        XCTAssertTrue(repaired.issues.contains { $0.code == "scene_package_detected" })
        XCTAssertTrue(repaired.issues.contains { $0.code == "scene_renderer_limited" })
    }

    func testSceneBackgroundProbeKeepsUnreadableSceneUnsupported() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "unreadable-scene")
        let scenePackage = project.appending(path: "scene.pkg")
        try Data([0, 1, 2, 3]).write(to: scenePackage)
        let asset = WallpaperAsset(
            id: "unreadable-scene",
            title: "Unreadable Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: scenePackage.path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(asset)

        // When
        let pending = try XCTUnwrap(store.load().assets.first)
        let repaired = store.probeSceneCompatibility(for: pending)

        // Then
        XCTAssertTrue(pending.compatibilityReport?.needsProbe == true)
        XCTAssertEqual(pending.compatibilityReport?.diagnosticCode, "scene_probe_pending")
        XCTAssertEqual(repaired.supportStatus, .unsupported)
        XCTAssertEqual(repaired.compatibilityReport?.level, .unsupported)
        XCTAssertEqual(repaired.compatibilityReport?.diagnosticCode, "scene_package_unreadable")
    }

    func testSceneBackgroundProbeResolvesMissingEntrypointAsUnsupported() throws {
        let asset = WallpaperAsset(
            id: "missing-scene",
            title: "Missing Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: "/tmp/missing-scene",
            entrypoint: nil,
            thumbnail: nil,
            workshopId: nil,
            compatibility: CompatibilityReport.pendingSceneProbe().supportMode,
            compatibilityReport: CompatibilityReport.pendingSceneProbe(),
            redistributionAllowed: false,
            issues: []
        )

        let repaired = LibraryStore(root: URL(filePath: "/tmp/library"))
            .probeSceneCompatibility(for: asset)

        XCTAssertEqual(repaired.supportStatus, .unsupported)
        XCTAssertEqual(repaired.compatibilityReport?.diagnosticCode, "scene_package_missing")
        XCTAssertFalse(repaired.compatibilityReport?.needsProbe == true)
        XCTAssertTrue(repaired.issues.contains { $0.code == "scene_package_missing" })
    }

    func testSceneBackgroundProbeRefreshesImportedSceneDiagnostics() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "scene-diagnostics")
        let scenePackage = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: """
            {
              "objects": [
                {"text": {"value": "12:34"}},
                {"image": "models/foam.json", "effects": [{"file": "effects/waterflow/effect.json"}]}
              ]
            }
            """
        )
        let stale = WallpaperAsset(
            id: "scene-diagnostics",
            title: "Scene Diagnostics",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: scenePackage.path,
            thumbnail: nil,
            workshopId: "scene-diagnostics",
            redistributionAllowed: false,
            issues: [
                ScanIssue(code: "scene_package_detected", message: "2D image-layer playback is enabled."),
                ScanIssue(code: "scene_renderer_limited", message: "old limited renderer message")
            ]
        )
        try store.replaceAsset(stale)

        // When
        let pending = try XCTUnwrap(store.load().assets.first)
        let repaired = store.probeSceneCompatibility(for: pending)

        // Then
        XCTAssertTrue(pending.compatibilityReport?.needsProbe == true)
        XCTAssertEqual(repaired.issues.filter { $0.code == "scene_package_detected" }.count, 1)
        XCTAssertTrue(repaired.issues.contains { issue in
            issue.code == "scene_package_detected"
                && issue.message.contains("selected text SceneScript")
                && issue.message.contains("selected effect playback")
        })
        XCTAssertTrue(repaired.issues.contains { issue in
            issue.code == "scene_renderer_limited"
                && issue.message.contains("selected text SceneScript")
                && issue.message.contains("selected effect motion")
        })
    }

    func testSceneBackgroundProbeRefreshesTextOnlySceneSupportStatusToPlayable() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "text-only-scene")
        let scenePackage = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let stale = WallpaperAsset(
            id: "text-only-scene",
            title: "Text Scene",
            kind: .scene,
            supportStatus: .unsupported,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: scenePackage.path,
            thumbnail: nil,
            workshopId: "text-only-scene",
            redistributionAllowed: false,
            issues: [
                ScanIssue(code: "scene_package_detected", message: "old summary"),
                ScanIssue(code: "scene_renderer_limited", message: "old renderer message")
            ]
        )
        try store.replaceAsset(stale)

        // When
        let pending = try XCTUnwrap(store.load().assets.first)
        let repaired = store.probeSceneCompatibility(for: pending)

        // Then
        XCTAssertTrue(pending.compatibilityReport?.needsProbe == true)
        XCTAssertEqual(repaired.supportStatus, .playable)
        XCTAssertTrue(repaired.issues.contains { $0.code == "scene_package_detected" })
        XCTAssertTrue(repaired.issues.contains { $0.code == "scene_renderer_limited" })
    }

    func testSceneBackgroundProbeKeepsReadableScenePlayableForExternalCachedFallback() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "broken-scene")
        let scenePackage = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: #"{"objects":[{"image":"models/background.json"}]}"#,
            extraEntries: [
                (path: "models/background.json", data: Data(#"{"material":"materials/background.json"}"#.utf8)),
                (path: "materials/background.json", data: Data(#"{"passes":[{"textures":["background"]}]}"#.utf8)),
                (path: "materials/background.tex", data: Data([1, 2, 3]))
            ]
        )
        let stale = WallpaperAsset(
            id: "broken-scene",
            title: "Broken Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: scenePackage.path,
            thumbnail: nil,
            workshopId: "broken-scene",
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(stale)

        // When
        let pending = try XCTUnwrap(store.load().assets.first)
        let repaired = store.probeSceneCompatibility(for: pending)

        // Then
        XCTAssertTrue(pending.compatibilityReport?.needsProbe == true)
        XCTAssertEqual(repaired.supportStatus, .playable)
        XCTAssertEqual(repaired.compatibilityReport?.playbackPath, .renderedSceneCache)
        XCTAssertTrue(repaired.issues.contains { $0.code == "scene_package_detected" })
        XCTAssertTrue(repaired.issues.contains { $0.code == "scene_renderer_limited" })
    }

    func testLoadMigratesSchemaV2AndReprobesCompatibilityWithoutChangingFiles() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "legacy-video-v2")
        let video = project.appending(path: "wallpaper.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1, 2, 3]))
        let legacy = WallpaperAsset(
            id: "legacy-video-v2",
            title: "Legacy Video",
            kind: .video,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: video.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            redistributionAllowed: false,
            issues: []
        )
        let manifest = LibraryManifest(
            schemaVersion: 2,
            generatedAt: Date(),
            assets: [legacy]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appending(path: "library.json"), options: [.atomic])

        let migrated = try store.load()

        XCTAssertEqual(migrated.schemaVersion, 3)
        XCTAssertEqual(migrated.assets.first?.compatibilityReport?.level, .full)
        XCTAssertEqual(migrated.assets.first?.compatibilityReport?.playbackPath, .direct)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testLoadRepairsLegacyPreviewImageManifestForVideoProject() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "legacy-video")
        let preview = project.appending(path: "preview.jpg")
        let video = project.appending(path: "wallpaper.mp4")
        try #"{"title":"Video","file":"wallpaper.mp4","preview":"preview.jpg","type":"video"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: preview.path, contents: Data([1]))
        FileManager.default.createFile(atPath: video.path, contents: Data([2]))
        let legacy = WallpaperAsset(
            id: "legacy-video",
            title: "Video",
            kind: .image,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: preview.path,
            thumbnail: preview.path,
            workshopId: "legacy-video",
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(legacy)

        // When
        let repaired = try XCTUnwrap(store.load().assets.first)

        // Then
        XCTAssertEqual(repaired.id, legacy.id)
        XCTAssertEqual(repaired.kind, .video)
        XCTAssertEqual(repaired.supportStatus, .playable)
        XCTAssertEqual(repaired.entrypoint, video.path)
        XCTAssertEqual(repaired.thumbnail, preview.path)
    }

    private func makeImportedProjectDirectory(in root: URL, id: String) throws -> URL {
        let project = root.appending(path: "Assets").appending(path: id)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    private func standardPath(_ path: String?) -> String? {
        path.map { URL(filePath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
    }
}

/// Test double for `AssetTrashing` that records every call so removal tests
/// can assert Trash is preferred, and can simulate a volume that rejects
/// `trashItem` to exercise the permanent-delete fallback.
private final class SpyAssetTrasher: AssetTrashing, @unchecked Sendable {
    private(set) var trashedURLs: [URL] = []
    private(set) var removedURLs: [URL] = []
    var trashItemError: Error?
    var removeItemError: Error?

    func trashItem(at url: URL) throws {
        trashedURLs.append(url)
        if let trashItemError {
            throw trashItemError
        }
        try FileManager.default.removeItem(at: url)
    }

    func removeItem(at url: URL) throws {
        removedURLs.append(url)
        if let removeItemError {
            throw removeItemError
        }
        try FileManager.default.removeItem(at: url)
    }
}

private final class ControllableManifestWriter: LibraryManifestWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFailNextWrite = false

    func failNextWrite() {
        lock.lock()
        shouldFailNextWrite = true
        lock.unlock()
    }

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        let shouldFail = shouldFailNextWrite
        shouldFailNextWrite = false
        lock.unlock()
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: [.atomic])
    }
}
