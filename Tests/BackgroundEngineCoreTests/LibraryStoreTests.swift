import Foundation
import XCTest
@_spi(FFmpegRecovery) @testable import BackgroundEngineCore

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

    func testChangedWorkshopItemAtomicallyReplacesStaleUnsupportedCopy() throws {
        let source = try Fixture.makeTempDirectory().appending(path: "456")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let metadata = source.appending(path: "project.json")
        let entrypoint = source.appending(path: "index.html")
        try #"{"title":"Broken Version","type":"web","file":"index.html"}"#.write(
            to: metadata,
            atomically: true,
            encoding: .utf8
        )
        try Data([0, 10]).write(to: entrypoint)
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let stale = try XCTUnwrap(WallpaperScanner().scan(root: source).assets.first)
        let firstImport = try store.importAsset(stale)
        let originalDateAdded = try XCTUnwrap(store.load().assets.first).dateAdded
        try store.saveDisplayAssignment(DisplayAssignment(
            displayUUID: "external-display",
            assetID: firstImport.id,
            displayMode: .fit,
            quality: .high,
            audioSource: .primaryDisplay
        ))
        XCTAssertEqual(firstImport.workshopId, "456")
        XCTAssertEqual(firstImport.supportStatus, .unsupported)

        try #"{"title":"Fixed Version","type":"web","file":"index.html"}"#.write(
            to: metadata,
            atomically: true,
            encoding: .utf8
        )
        let fixedHTML = Data("<!doctype html><title>Fixed</title>".utf8)
        try fixedHTML.write(to: entrypoint)
        let repaired = try XCTUnwrap(WallpaperScanner().scan(root: source).assets.first)
        let updated = try store.importAsset(repaired)
        let manifest = try store.load()

        XCTAssertEqual(manifest.assets.count, 1)
        XCTAssertEqual(updated.id, firstImport.id)
        XCTAssertEqual(updated.title, "Fixed Version")
        XCTAssertEqual(updated.kind, .web)
        XCTAssertEqual(updated.supportStatus, .playable)
        XCTAssertNotEqual(updated.contentHash, firstImport.contentHash)
        XCTAssertEqual(updated.dateAdded, originalDateAdded)
        XCTAssertEqual(
            try Data(contentsOf: URL(filePath: try XCTUnwrap(updated.entrypoint))),
            fixedHTML
        )
        XCTAssertEqual(manifest.displayAssignments.first?.assetID, updated.id)
        XCTAssertEqual(manifest.displayAssignments.first?.displayUUID, "external-display")
    }

    func testWorkshopWebUpdateResetsNetworkTrustOnlyWhenContentChanges() throws {
        let source = try Fixture.makeTempDirectory().appending(path: "789")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try #"{"title":"Web Item","type":"web","file":"index.html"}"#.write(
            to: source.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        let entrypoint = source.appending(path: "index.html")
        try "<!doctype html><title>One</title>".write(
            to: entrypoint,
            atomically: true,
            encoding: .utf8
        )
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let scanned = try XCTUnwrap(WallpaperScanner().scan(root: source).assets.first)
        let imported = try store.importAsset(scanned)
        _ = try store.setWebNetworkAccess(assetID: imported.id, allowed: true)

        let unchanged = try store.importAsset(scanned)
        XCTAssertEqual(unchanged.allowsNetworkAccess, true)

        try "<!doctype html><title>Two</title>".write(
            to: entrypoint,
            atomically: true,
            encoding: .utf8
        )
        let updatedScan = try XCTUnwrap(WallpaperScanner().scan(root: source).assets.first)
        let updated = try store.importAsset(updatedScan)

        XCTAssertEqual(updated.id, imported.id)
        XCTAssertEqual(updated.allowsNetworkAccess, false)
        XCTAssertNotEqual(updated.contentHash, unchanged.contentHash)
    }

    func testWorkshopImportDoesNotAliasManualAssetWithMatchingContentHash() throws {
        let storeRoot = try Fixture.makeTempDirectory()
        let manual = try makeVideoImportFixture(
            id: "manual-existing",
            source: .manualFolder,
            workshopID: nil
        )
        let workshop = try makeVideoImportFixture(
            id: "1001",
            source: .steamCMD,
            workshopID: "1001"
        )
        defer {
            for url in [storeRoot, manual.root, workshop.root] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let store = LibraryStore(root: storeRoot)

        let importedManual = try store.importAsset(manual.asset)
        let importedWorkshop = try store.importAsset(workshop.asset)
        let manifest = try store.load()

        XCTAssertEqual(importedManual.contentHash, importedWorkshop.contentHash)
        XCTAssertEqual(importedManual.id, "manual-existing")
        XCTAssertNil(importedManual.workshopId)
        XCTAssertEqual(importedWorkshop.id, "1001")
        XCTAssertEqual(importedWorkshop.workshopId, "1001")
        XCTAssertEqual(Set(manifest.assets.map(\.id)), ["manual-existing", "1001"])
    }

    func testManualImportDoesNotAliasWorkshopAssetWithMatchingContentHash() throws {
        let storeRoot = try Fixture.makeTempDirectory()
        let workshop = try makeVideoImportFixture(
            id: "1001",
            source: .steamCMD,
            workshopID: "1001"
        )
        let manual = try makeVideoImportFixture(
            id: "manual-later",
            source: .manualFolder,
            workshopID: nil
        )
        defer {
            for url in [storeRoot, workshop.root, manual.root] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let store = LibraryStore(root: storeRoot)

        let importedWorkshop = try store.importAsset(workshop.asset)
        let importedManual = try store.importAsset(manual.asset)
        let manifest = try store.load()

        XCTAssertEqual(importedWorkshop.contentHash, importedManual.contentHash)
        XCTAssertEqual(importedWorkshop.id, "1001")
        XCTAssertEqual(importedWorkshop.workshopId, "1001")
        XCTAssertEqual(importedManual.id, "manual-later")
        XCTAssertNil(importedManual.workshopId)
        XCTAssertEqual(Set(manifest.assets.map(\.id)), ["1001", "manual-later"])
    }

    func testWorkshopAndManualImportsWithSameNumericIDReceiveDistinctStorageIdentities() throws {
        let storeRoot = try Fixture.makeTempDirectory()
        let manual = try makeVideoImportFixture(
            id: "1001",
            source: .manualFolder,
            workshopID: nil
        )
        let workshop = try makeVideoImportFixture(
            id: "1001",
            source: .steamCMD,
            workshopID: "1001"
        )
        defer {
            for url in [storeRoot, manual.root, workshop.root] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let store = LibraryStore(root: storeRoot)

        let importedManual = try store.importAsset(manual.asset)
        try store.saveDisplayAssignment(
            DisplayAssignment(displayUUID: "main-display", assetID: importedManual.id)
        )
        let importedWorkshop = try store.importAsset(workshop.asset)
        let manifest = try store.load()

        XCTAssertEqual(importedManual.id, "1001")
        XCTAssertEqual(importedWorkshop.id, "workshop-1001")
        XCTAssertNotEqual(importedManual.projectDirectory, importedWorkshop.projectDirectory)
        XCTAssertEqual(Set(manifest.assets.map(\.id)), ["1001", "workshop-1001"])
        XCTAssertEqual(Set(manifest.assets.compactMap(\.workshopId)), ["1001"])
        XCTAssertEqual(manifest.displayAssignments.first?.assetID, importedManual.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedManual.projectDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedWorkshop.projectDirectory))
    }

    func testManualNumericIDCollisionAfterWorkshopGetsDistinctIdentity() throws {
        let storeRoot = try Fixture.makeTempDirectory()
        let workshop = try makeVideoImportFixture(
            id: "1001",
            source: .steamCMD,
            workshopID: "1001"
        )
        let manual = try makeVideoImportFixture(
            id: "1001",
            source: .manualFolder,
            workshopID: nil
        )
        defer {
            for url in [storeRoot, workshop.root, manual.root] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let store = LibraryStore(root: storeRoot)

        let importedWorkshop = try store.importAsset(workshop.asset)
        let importedManual = try store.importAsset(manual.asset)
        let manifest = try store.load()

        XCTAssertEqual(importedWorkshop.id, "1001")
        XCTAssertEqual(importedWorkshop.workshopId, "1001")
        XCTAssertEqual(importedManual.id, "manual-1001")
        XCTAssertNil(importedManual.workshopId)
        XCTAssertNotEqual(importedWorkshop.projectDirectory, importedManual.projectDirectory)
        XCTAssertEqual(Set(manifest.assets.map(\.id)), ["1001", "manual-1001"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedWorkshop.projectDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedManual.projectDirectory))
    }

    func testWorkshopReimportKeepsCollisionResolvedIdentityAndManualAsset() throws {
        let storeRoot = try Fixture.makeTempDirectory()
        let manual = try makeVideoImportFixture(
            id: "1001",
            source: .manualFolder,
            workshopID: nil
        )
        let workshop = try makeVideoImportFixture(
            id: "1001",
            source: .steamCMD,
            workshopID: "1001"
        )
        defer {
            for url in [storeRoot, manual.root, workshop.root] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let store = LibraryStore(root: storeRoot)
        let importedManual = try store.importAsset(manual.asset)
        let firstWorkshopImport = try store.importAsset(workshop.asset)
        try Data([9, 8, 7, 6]).write(
            to: workshop.root.appending(path: "wallpaper.mp4")
        )

        let updatedWorkshop = try store.importAsset(workshop.asset)
        let manifest = try store.load()

        XCTAssertEqual(firstWorkshopImport.id, "workshop-1001")
        XCTAssertEqual(updatedWorkshop.id, firstWorkshopImport.id)
        XCTAssertEqual(updatedWorkshop.workshopId, "1001")
        XCTAssertNotEqual(updatedWorkshop.contentHash, firstWorkshopImport.contentHash)
        XCTAssertEqual(manifest.assets.count, 2)
        XCTAssertTrue(manifest.assets.contains { $0 == importedManual })
        XCTAssertEqual(manifest.assets.first(where: { $0.workshopId == "1001" }), updatedWorkshop)
    }

    func testDifferentWorkshopIDsRemainDistinctWhenContentHashesMatch() throws {
        let storeRoot = try Fixture.makeTempDirectory()
        let first = try makeVideoImportFixture(
            id: "1001",
            source: .steamCMD,
            workshopID: "1001"
        )
        let second = try makeVideoImportFixture(
            id: "2002",
            source: .steamCMD,
            workshopID: "2002"
        )
        defer {
            for url in [storeRoot, first.root, second.root] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let store = LibraryStore(root: storeRoot)

        let importedFirst = try store.importAsset(first.asset)
        let importedSecond = try store.importAsset(second.asset)
        let manifest = try store.load()

        XCTAssertEqual(importedFirst.contentHash, importedSecond.contentHash)
        XCTAssertEqual(importedFirst.workshopId, "1001")
        XCTAssertEqual(importedSecond.workshopId, "2002")
        XCTAssertEqual(Set(manifest.assets.compactMap(\.workshopId)), ["1001", "2002"])
        XCTAssertEqual(manifest.assets.count, 2)
    }

    func testWebNetworkPermissionReclassifiesRequiredRemoteDependencies() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "remote-web")
        let entrypoint = project.appending(path: "index.html")
        try #"<!doctype html><canvas></canvas><script src="https://cdn.example/render.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let blockedReport = WallpaperCompatibilityAnalyzer().analyze(
            kind: .web,
            status: .playable,
            entrypoint: entrypoint,
            projectRoot: project
        )
        let asset = WallpaperAsset(
            id: "remote-web",
            title: "Remote Web",
            kind: .web,
            supportStatus: .unsupported,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: blockedReport.supportMode,
            compatibilityReport: blockedReport,
            allowsNetworkAccess: false,
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(asset)

        let allowed = try store.setWebNetworkAccess(assetID: asset.id, allowed: true)

        XCTAssertEqual(allowed.supportStatus, .playable)
        XCTAssertEqual(allowed.compatibilityReport?.level, .full)
        XCTAssertEqual(allowed.compatibilityReport?.playbackPath, .webLive)
        XCTAssertEqual(allowed.compatibilityReport?.requiredCapabilities, [.externalNetwork])
        XCTAssertTrue(allowed.compatibilityReport?.missingCapabilities.isEmpty == true)
        XCTAssertEqual(allowed.allowsNetworkAccess, true)
        let persistedAllowed = try XCTUnwrap(store.load().assets.first)
        XCTAssertEqual(persistedAllowed, allowed)

        let blockedAgain = try store.setWebNetworkAccess(assetID: asset.id, allowed: false)

        XCTAssertEqual(blockedAgain.supportStatus, .unsupported)
        XCTAssertEqual(blockedAgain.compatibilityReport?.level, .unsupported)
        XCTAssertEqual(blockedAgain.compatibilityReport?.missingCapabilities, [.externalNetwork])
        XCTAssertEqual(blockedAgain.compatibilityReport?.diagnosticCode, "web_network_access_required")
        XCTAssertEqual(blockedAgain.allowsNetworkAccess, false)
    }

    func testWorkshopWebUpdatePreservesValidatedUserPropertyCustomizations() async throws {
        let source = try Fixture.makeTempDirectory().appending(path: "790")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let metadata = source.appending(path: "project.json")
        let entrypoint = source.appending(path: "index.html")
        try #"{"title":"Web Item","type":"web","file":"index.html","general":{"properties":{"enabled":{"type":"bool","value":true},"photo":{"type":"file","value":""}}}}"#
            .write(to: metadata, atomically: true, encoding: .utf8)
        try "<!doctype html><title>One</title>".write(
            to: entrypoint,
            atomically: true,
            encoding: .utf8
        )
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let imported = try store.importAsset(
            try XCTUnwrap(WallpaperScanner().scan(root: source).assets.first)
        )
        let selected = try Fixture.makeTempDirectory().appending(path: "selected.png")
        let selectedBytes = Data([1, 3, 3, 7])
        try selectedBytes.write(to: selected)
        let propertyStore = WebWallpaperUserFileStore()
        let copied = try await propertyStore.copySelection(
            selected,
            propertyName: "photo",
            into: URL(filePath: imported.projectDirectory)
        )
        try await propertyStore.saveValueOverrides(
            ["enabled": .bool(false)],
            into: URL(filePath: imported.projectDirectory)
        )

        try "<!doctype html><title>Two</title>".write(
            to: entrypoint,
            atomically: true,
            encoding: .utf8
        )
        let updated = try store.importAsset(
            try XCTUnwrap(WallpaperScanner().scan(root: source).assets.first)
        )
        let updatedRoot = URL(filePath: updated.projectDirectory)

        XCTAssertNotEqual(updated.contentHash, imported.contentHash)
        let scalarOverrides = try await propertyStore.loadValueOverrides(from: updatedRoot)
        XCTAssertEqual(scalarOverrides, ["enabled": .bool(false)])
        let copiedAfterUpdate = updatedRoot
            .appending(path: WebWallpaperUserFileStore.directoryName)
            .appending(path: copied.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: copiedAfterUpdate), selectedBytes)
        let fileOverridesURL = updatedRoot
            .appending(path: WebWallpaperUserFileStore.directoryName)
            .appending(path: WebWallpaperUserFileStore.overridesFileName)
        let fileOverrides = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: fileOverridesURL)
        )
        XCTAssertEqual(
            fileOverrides["photo"],
            "\(WebWallpaperUserFileStore.directoryName)/\(copied.lastPathComponent)"
        )
    }

    func testWorkshopUpdateKeepsConvertedCacheOnRollbackThenRemovesItAfterCommit() throws {
        let root = try Fixture.makeTempDirectory()
        let cache = try Fixture.makeTempDirectory()
        let source = try Fixture.makeTempDirectory()
        let sourceVideo = source.appending(path: "wallpaper.mkv")
        try Data([1]).write(to: sourceVideo)
        let writer = ControllableManifestWriter()
        let store = LibraryStore(
            root: root,
            trasher: FileManagerAssetTrasher(),
            manifestWriter: writer,
            convertedVideoCacheDirectory: cache
        )
        let original = WallpaperAsset(
            id: "converted-update",
            title: "Original",
            kind: .video,
            supportStatus: .needsConversion,
            source: .steamCMD,
            projectDirectory: source.path,
            entrypoint: sourceVideo.path,
            thumbnail: nil,
            workshopId: "9001",
            compatibility: .cached(reason: "Conversion required."),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .convertedVideo),
            redistributionAllowed: false,
            issues: []
        )
        let imported = try store.importAsset(original)
        let oldHash = try XCTUnwrap(imported.contentHash)
        let oldCache = cache.appending(path: VideoConversionCacheKey(contentHash: oldHash).fileName)
        try Data([7, 8, 9]).write(to: oldCache)
        let converted = WallpaperAsset(
            id: imported.id,
            title: imported.title,
            kind: .video,
            supportStatus: .playable,
            source: imported.source,
            projectDirectory: imported.projectDirectory,
            entrypoint: oldCache.path,
            thumbnail: imported.thumbnail,
            workshopId: imported.workshopId,
            dateAdded: imported.dateAdded,
            contentHash: imported.contentHash,
            compatibility: .cached(reason: "Converted for AVFoundation playback."),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .convertedVideo),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(converted)
        try Data([2]).write(to: sourceVideo)
        let changed = WallpaperAsset(
            id: original.id,
            title: "Updated",
            kind: .video,
            supportStatus: .needsConversion,
            source: original.source,
            projectDirectory: source.path,
            entrypoint: sourceVideo.path,
            thumbnail: nil,
            workshopId: original.workshopId,
            compatibility: .limited(reason: "Conversion pending."),
            compatibilityReport: CompatibilityReport(level: .limited, playbackPath: nil),
            redistributionAllowed: false,
            issues: []
        )
        writer.failNextWrite()

        XCTAssertThrowsError(try store.importAsset(changed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldCache.path))
        XCTAssertEqual(try store.load().assets.first?.entrypoint, oldCache.path)

        let updated = try store.importAsset(changed)

        XCTAssertEqual(updated.title, "Updated")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldCache.path))
    }

    func testLegacyConvertedVideoIsFlaggedRebuiltFromSourceAndCleanedAfterCommit() throws {
        let root = try Fixture.makeTempDirectory()
        let cache = try Fixture.makeTempDirectory()
        let source = try Fixture.makeTempDirectory().appending(path: "legacy-video")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let sourceVideo = source.appending(path: "nested/wallpaper.mkv")
        try FileManager.default.createDirectory(
            at: sourceVideo.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sourceBytes = Data([9, 8, 7, 6])
        try sourceBytes.write(to: sourceVideo)
        try #"{"title":"Legacy","type":"video","file":"nested\\wallpaper.mkv"}"#.write(
            to: source.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        let store = LibraryStore(
            root: root,
            trasher: FileManagerAssetTrasher(),
            manifestWriter: ControllableManifestWriter(),
            convertedVideoCacheDirectory: cache
        )
        let pending = try store.importAsset(WallpaperAsset(
            id: "legacy-video",
            title: "Legacy",
            kind: .video,
            supportStatus: .needsConversion,
            source: .manualFolder,
            projectDirectory: source.path,
            entrypoint: sourceVideo.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .limited(reason: "Conversion required."),
            compatibilityReport: CompatibilityReport(level: .limited, playbackPath: nil),
            redistributionAllowed: false,
            issues: []
        ))
        let hash = try XCTUnwrap(pending.contentHash)
        let cacheKey = VideoConversionCacheKey(contentHash: hash)
        let legacyCache = cache.appending(path: cacheKey.legacyV1FileName)
        try Data([1, 2, 3]).write(to: legacyCache)
        try store.replaceAsset(WallpaperAsset(
            id: pending.id,
            title: pending.title,
            kind: .video,
            supportStatus: .playable,
            source: pending.source,
            projectDirectory: pending.projectDirectory,
            entrypoint: legacyCache.path,
            thumbnail: pending.thumbnail,
            workshopId: pending.workshopId,
            dateAdded: pending.dateAdded,
            contentHash: pending.contentHash,
            compatibility: .cached(reason: "Converted for AVFoundation playback."),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .convertedVideo),
            redistributionAllowed: false,
            issues: []
        ))

        let migrated = try XCTUnwrap(store.load().assets.first)
        XCTAssertTrue(migrated.videoConversionActionAvailable)
        XCTAssertEqual(migrated.issues.first?.code, VideoConverter.outdatedRecipeIssueCode)
        let recoveredSource = try store.copyVideoConversionSource(for: migrated, into: cache)
        defer { recoveredSource.cleanup() }
        XCTAssertEqual(try Data(contentsOf: recoveredSource.url), sourceBytes)
        XCTAssertEqual(recoveredSource.url.pathExtension, "mkv")

        let currentCache = cache.appending(
            path: cacheKey.fileName(forAssetID: migrated.id)
        )
        try Data([4, 5, 6]).write(to: currentCache)
        try store.replaceAsset(WallpaperAsset(
            id: migrated.id,
            title: migrated.title,
            kind: migrated.kind,
            supportStatus: migrated.supportStatus,
            source: migrated.source,
            projectDirectory: migrated.projectDirectory,
            entrypoint: currentCache.path,
            thumbnail: migrated.thumbnail,
            workshopId: migrated.workshopId,
            dateAdded: migrated.dateAdded,
            contentHash: migrated.contentHash,
            compatibility: migrated.compatibility,
            compatibilityReport: migrated.compatibilityReport,
            redistributionAllowed: false,
            issues: migrated.issues.filter { $0.code != VideoConverter.outdatedRecipeIssueCode }
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyCache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentCache.path))
        XCTAssertFalse(try XCTUnwrap(store.load().assets.first).videoConversionActionAvailable)
        XCTAssertFalse(
            try XCTUnwrap(LibraryStore(root: root).load().assets.first)
                .videoConversionActionAvailable,
            "Recipe identity must not depend on an injected cache root."
        )
    }

    func testKnownPreviousRecipeConvertedVideosAreCleanedAfterCurrentRecipeCommit() throws {
        for (index, recipeID) in VideoConverter.previousConversionRecipeIDs.enumerated() {
            let root = try Fixture.makeTempDirectory()
            let cache = try Fixture.makeTempDirectory()
            let store = LibraryStore(
                root: root,
                trasher: FileManagerAssetTrasher(),
                manifestWriter: ControllableManifestWriter(),
                convertedVideoCacheDirectory: cache
            )
            let hash = String(repeating: String(index + 1), count: 64)
            let key = VideoConversionCacheKey(contentHash: hash)
            let previousCache = cache.appending(
                path: VideoConversionCacheKey(contentHash: hash, recipeID: recipeID).fileName
            )
            let assetID = "previous-recipe-\(index)"
            let currentCache = cache.appending(path: key.fileName(forAssetID: assetID))
            try Data([1, 2, 3]).write(to: previousCache)
            try Data([4, 5, 6]).write(to: currentCache)
            let existing = WallpaperAsset(
                id: assetID,
                title: "Previous Recipe",
                kind: .video,
                supportStatus: .playable,
                source: .manualFolder,
                projectDirectory: root.appending(path: "Assets/id-previous-recipe-\(index)").path,
                entrypoint: previousCache.path,
                thumbnail: nil,
                workshopId: nil,
                contentHash: hash,
                compatibility: .cached(reason: "Converted."),
                compatibilityReport: CompatibilityReport(level: .full, playbackPath: .convertedVideo),
                redistributionAllowed: false,
                issues: []
            )
            try store.replaceAsset(existing)

            try store.replaceAsset(WallpaperAsset(
                id: existing.id,
                title: existing.title,
                kind: existing.kind,
                supportStatus: existing.supportStatus,
                source: existing.source,
                projectDirectory: existing.projectDirectory,
                entrypoint: currentCache.path,
                thumbnail: existing.thumbnail,
                workshopId: existing.workshopId,
                dateAdded: existing.dateAdded,
                contentHash: existing.contentHash,
                compatibility: existing.compatibility,
                compatibilityReport: existing.compatibilityReport,
                redistributionAllowed: false,
                issues: []
            ))

            XCTAssertFalse(FileManager.default.fileExists(atPath: previousCache.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: currentCache.path))
        }
    }

    func testLegacyConvertedStandaloneVideoRecoversHiddenAndProjectJSONSources() throws {
        for (index, fileName) in [".wallpaper", "project.json"].enumerated() {
            let root = try Fixture.makeTempDirectory()
            let cache = try Fixture.makeTempDirectory()
            let source = try Fixture.makeTempDirectory().appending(path: "source-\(index)")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let sourceFile = source.appending(path: fileName)
            let sourceBytes = Data("standalone-video-\(index)".utf8)
            try sourceBytes.write(to: sourceFile)
            let store = LibraryStore(
                root: root,
                trasher: FileManagerAssetTrasher(),
                manifestWriter: ControllableManifestWriter(),
                convertedVideoCacheDirectory: cache
            )
            let imported = try store.importAsset(WallpaperAsset(
                id: "standalone-\(index)",
                title: "Standalone",
                kind: .video,
                supportStatus: .needsConversion,
                source: .manualFolder,
                projectDirectory: source.path,
                entrypoint: sourceFile.path,
                thumbnail: nil,
                workshopId: nil,
                compatibility: .limited(reason: "Conversion required."),
                compatibilityReport: CompatibilityReport(level: .limited, playbackPath: nil),
                redistributionAllowed: false,
                issues: []
            ))
            let copiedSource = URL(filePath: try XCTUnwrap(imported.entrypoint))
            let fileHash = try WallpaperContentHasher.hashFile(copiedSource)
            let oldCache = cache.appending(
                path: VideoConversionCacheKey(contentHash: fileHash).legacyV1FileName
            )
            try Data([1]).write(to: oldCache)
            try store.replaceAsset(WallpaperAsset(
                id: imported.id,
                title: imported.title,
                kind: .video,
                supportStatus: .playable,
                source: imported.source,
                projectDirectory: imported.projectDirectory,
                entrypoint: oldCache.path,
                thumbnail: nil,
                workshopId: nil,
                dateAdded: imported.dateAdded,
                contentHash: fileHash,
                compatibility: .cached(reason: "Converted."),
                compatibilityReport: CompatibilityReport(level: .full, playbackPath: .convertedVideo),
                redistributionAllowed: false,
                issues: []
            ))

            let converted = try XCTUnwrap(store.load().assets.first)
            let snapshot = try store.copyVideoConversionSource(for: converted, into: cache)
            XCTAssertEqual(try Data(contentsOf: snapshot.url), sourceBytes)
            snapshot.cleanup()
        }
    }

    func testLegacyConversionSourceRejectsSymlinkedAssetDirectory() throws {
        let root = try Fixture.makeTempDirectory()
        let cache = try Fixture.makeTempDirectory()
        let source = try Fixture.makeTempDirectory().appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let sourceVideo = source.appending(path: "wallpaper.mkv")
        try Data([1, 2, 3]).write(to: sourceVideo)
        try #"{"type":"video","file":"wallpaper.mkv"}"#.write(
            to: source.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        let store = LibraryStore(
            root: root,
            trasher: FileManagerAssetTrasher(),
            manifestWriter: ControllableManifestWriter(),
            convertedVideoCacheDirectory: cache
        )
        let imported = try store.importAsset(WallpaperAsset(
            id: "symlinked-source",
            title: "Symlinked",
            kind: .video,
            supportStatus: .needsConversion,
            source: .manualFolder,
            projectDirectory: source.path,
            entrypoint: sourceVideo.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .limited(reason: "Conversion required."),
            compatibilityReport: CompatibilityReport(level: .limited, playbackPath: nil),
            redistributionAllowed: false,
            issues: []
        ))
        let oldCache = cache.appending(
            path: VideoConversionCacheKey(contentHash: try XCTUnwrap(imported.contentHash)).legacyV1FileName
        )
        try Data([4]).write(to: oldCache)
        try store.replaceAsset(WallpaperAsset(
            id: imported.id,
            title: imported.title,
            kind: .video,
            supportStatus: .playable,
            source: imported.source,
            projectDirectory: imported.projectDirectory,
            entrypoint: oldCache.path,
            thumbnail: nil,
            workshopId: nil,
            dateAdded: imported.dateAdded,
            contentHash: imported.contentHash,
            compatibility: .cached(reason: "Converted."),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .convertedVideo),
            redistributionAllowed: false,
            issues: []
        ))
        let sibling = URL(filePath: imported.projectDirectory)
            .deletingLastPathComponent()
            .appending(path: "sibling-project")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data([9, 9, 9]).write(to: sibling.appending(path: "wallpaper.mkv"))
        try FileManager.default.removeItem(at: URL(filePath: imported.projectDirectory))
        try FileManager.default.createSymbolicLink(
            at: URL(filePath: imported.projectDirectory),
            withDestinationURL: sibling
        )

        let converted = try XCTUnwrap(store.load().assets.first)
        XCTAssertThrowsError(try store.copyVideoConversionSource(for: converted, into: cache))
    }

    func testConvertedVideoCleanupRejectsSymlinkedCacheRoot() throws {
        let root = try Fixture.makeTempDirectory()
        let cacheParent = try Fixture.makeTempDirectory()
        let cache = cacheParent.appending(path: "Video")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = LibraryStore(
            root: root,
            trasher: FileManagerAssetTrasher(),
            manifestWriter: ControllableManifestWriter(),
            convertedVideoCacheDirectory: cache
        )
        let hash = String(repeating: "a", count: 64)
        let key = VideoConversionCacheKey(contentHash: hash)
        let oldCache = cache.appending(path: key.legacyV1FileName)
        try Data([1]).write(to: oldCache)
        let existing = WallpaperAsset(
            id: "cache-symlink",
            title: "Cache",
            kind: .video,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: root.appending(path: "Assets/id-cache").path,
            entrypoint: oldCache.path,
            thumbnail: nil,
            workshopId: nil,
            contentHash: hash,
            compatibility: .cached(reason: "Converted."),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .convertedVideo),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(existing)

        let external = try Fixture.makeTempDirectory()
        let externalFile = external.appending(path: key.legacyV1FileName)
        try Data([7, 7, 7]).write(to: externalFile)
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: external)
        try store.replaceAsset(WallpaperAsset(
            id: existing.id,
            title: existing.title,
            kind: existing.kind,
            supportStatus: .playable,
            source: existing.source,
            projectDirectory: existing.projectDirectory,
            entrypoint: root.appending(path: "replacement.mp4").path,
            thumbnail: nil,
            workshopId: nil,
            contentHash: hash,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .direct),
            redistributionAllowed: false,
            issues: []
        ))

        XCTAssertEqual(try Data(contentsOf: externalFile), Data([7, 7, 7]))
    }

    func testPinnedVideoInputSurvivesCacheRootSwapAndCleanupPreservesReplacement() async throws {
        let root = try Fixture.makeTempDirectory()
        let cacheParent = try Fixture.makeTempDirectory()
        let cache = cacheParent.appending(path: "Video")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let source = try Fixture.makeTempDirectory().appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let sourceVideo = source.appending(path: "wallpaper.mkv")
        let originalBytes = Data("descriptor-bound-video".utf8)
        try originalBytes.write(to: sourceVideo)
        let store = LibraryStore(
            root: root,
            trasher: FileManagerAssetTrasher(),
            manifestWriter: ControllableManifestWriter(),
            convertedVideoCacheDirectory: cache
        )
        let pending = try store.importAsset(WallpaperAsset(
            id: "pinned-input",
            title: "Pinned",
            kind: .video,
            supportStatus: .needsConversion,
            source: .manualFolder,
            projectDirectory: source.path,
            entrypoint: sourceVideo.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .limited(reason: "Conversion required."),
            compatibilityReport: CompatibilityReport(level: .limited, playbackPath: nil),
            redistributionAllowed: false,
            issues: []
        ))
        let pinned = try store.copyStableVideoInput(
            for: pending,
            originalInput: URL(filePath: try XCTUnwrap(pending.entrypoint)),
            into: cache
        )
        defer { pinned.cleanup() }

        let retiredCache = cacheParent.appending(path: "Retired")
        try FileManager.default.moveItem(at: cache, to: retiredCache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let replacementDirectory = cache.appending(path: pinned.url.lastPathComponent)
        try FileManager.default.createDirectory(at: replacementDirectory, withIntermediateDirectories: true)
        let marker = replacementDirectory.appending(path: "do-not-delete")
        try Data([9]).write(to: marker)

        let mediaTools = root.appending(path: "MediaTools")
        try FileManager.default.createDirectory(at: mediaTools, withIntermediateDirectories: true)
        let ffmpeg = mediaTools.appending(path: "ffmpeg")
        let ffprobe = mediaTools.appending(path: "ffprobe")
        let invocationLog = root.appending(path: "ffmpeg-invocations")
        try Data(#"""
        #!/bin/sh
        previous=
        input=
        input_fd=
        encoder=unknown
        for argument do
            if [ "$previous" = "-i" ]; then input=$argument; fi
            if [ "$previous" = "-fd" ]; then input_fd=$argument; fi
            if [ "$argument" = "h264_videotoolbox" ]; then encoder=videotoolbox; fi
            if [ "$argument" = "mpeg4" ]; then encoder=mpeg4; fi
            previous=$argument
            output=$argument
        done
        if [ "$input" = "fd:" ]; then input=/dev/fd/$input_fd; fi
        printf '%s\n' "$encoder" >> "\#(invocationLog.path)"
        if [ "$encoder" = "videotoolbox" ]; then
            /bin/cat "$input" >/dev/null
            printf '%s\n' 'Cannot create compression session: -12903' >&2
            exit 1
        fi
        /bin/cat "$input"
        """#.utf8).write(to: ffmpeg)
        try Data(#"""
        #!/bin/sh
        case " $* " in
          *" -count_packets "*)
            printf '%s' '{"streams":[{"index":0,"codec_type":"video","nb_read_packets":"1"}]}'
            ;;
          *)
            printf '%s' '{"streams":[{"index":0,"codec_type":"video","width":32,"height":32}],"format":{"format_name":"mov,mp4","size":"22"}}'
            ;;
        esac
        """#.utf8).write(to: ffprobe)
        for executable in [ffmpeg, ffprobe] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        let converter = VideoConverter(resolver: MediaToolResolver(
            bundleResourceURL: root,
            environment: [:],
            allowDevelopmentFallback: false
        ))
        let output = cache.appending(path: "output.mp4")

        try await converter.convertToPlayableVideo(
            input: pinned,
            output: output,
            timeout: .seconds(5)
        )
        pinned.cleanup()

        XCTAssertEqual(try Data(contentsOf: output), originalBytes)
        XCTAssertEqual(
            try String(contentsOf: invocationLog, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .map(String.init),
            ["videotoolbox", "mpeg4"],
            "The pinned input descriptor must rewind before the fallback attempt."
        )
        XCTAssertEqual(try Data(contentsOf: marker), Data([9]))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: retiredCache.appending(path: pinned.url.lastPathComponent).path
            )
        )
    }

    func testPlayableDirectVideoCanBePinnedForRuntimeFallbackButStaleRevisionIsRejected() throws {
        let root = try Fixture.makeTempDirectory()
        let cache = try Fixture.makeTempDirectory()
        let source = try Fixture.makeTempDirectory()
        let sourceVideo = source.appending(path: "runtime-direct.mkv")
        let sourceBytes = Data("runtime-direct-video".utf8)
        try sourceBytes.write(to: sourceVideo)
        let store = LibraryStore(
            root: root,
            trasher: FileManagerAssetTrasher(),
            manifestWriter: ControllableManifestWriter(),
            convertedVideoCacheDirectory: cache
        )
        let imported = try store.importAsset(WallpaperAsset(
            id: "runtime-direct",
            title: "Runtime Direct",
            kind: .video,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: source.path,
            entrypoint: sourceVideo.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .direct),
            redistributionAllowed: false,
            issues: []
        ))

        XCTAssertTrue(imported.videoConversionActionAvailable)
        let pinned = try store.copyStableDirectVideoInput(for: imported, into: cache)
        defer { pinned.cleanup() }
        XCTAssertEqual(try Data(contentsOf: pinned.url), sourceBytes)

        try store.replaceAsset(WallpaperAsset(
            id: imported.id,
            title: imported.title,
            kind: imported.kind,
            supportStatus: imported.supportStatus,
            source: imported.source,
            projectDirectory: imported.projectDirectory,
            entrypoint: imported.entrypoint,
            thumbnail: imported.thumbnail,
            workshopId: imported.workshopId,
            dateAdded: imported.dateAdded,
            contentHash: "new-revision-hash",
            compatibility: imported.compatibility,
            compatibilityReport: imported.compatibilityReport,
            allowsNetworkAccess: imported.allowsNetworkAccess,
            redistributionAllowed: false,
            issues: imported.issues
        ))

        XCTAssertThrowsError(
            try store.copyStableDirectVideoInput(for: imported, into: cache)
        ) { error in
            XCTAssertEqual(
                error as? WallpaperImportError,
                .assetRemovedDuringPreparation(imported.id)
            )
        }
    }

    func testRejectedStandaloneRecoveryLeavesNoPinnedSnapshot() throws {
        let root = try Fixture.makeTempDirectory()
        let cache = try Fixture.makeTempDirectory()
        let source = try Fixture.makeTempDirectory().appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let sourceVideo = source.appending(path: ".wallpaper")
        try Data("original".utf8).write(to: sourceVideo)
        let store = LibraryStore(
            root: root,
            trasher: FileManagerAssetTrasher(),
            manifestWriter: ControllableManifestWriter(),
            convertedVideoCacheDirectory: cache
        )
        let imported = try store.importAsset(WallpaperAsset(
            id: "hash-mismatch",
            title: "Mismatch",
            kind: .video,
            supportStatus: .needsConversion,
            source: .manualFolder,
            projectDirectory: source.path,
            entrypoint: sourceVideo.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .limited(reason: "Conversion required."),
            compatibilityReport: CompatibilityReport(level: .limited, playbackPath: nil),
            redistributionAllowed: false,
            issues: []
        ))
        let oldCache = cache.appending(path: "legacy.mp4")
        try Data([1]).write(to: oldCache)
        try store.replaceAsset(WallpaperAsset(
            id: imported.id,
            title: imported.title,
            kind: .video,
            supportStatus: .playable,
            source: imported.source,
            projectDirectory: imported.projectDirectory,
            entrypoint: oldCache.path,
            thumbnail: nil,
            workshopId: nil,
            dateAdded: imported.dateAdded,
            contentHash: String(repeating: "0", count: 64),
            compatibility: .cached(reason: "Converted."),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .convertedVideo),
            redistributionAllowed: false,
            issues: []
        ))

        let converted = try XCTUnwrap(store.load().assets.first)
        XCTAssertThrowsError(try store.copyVideoConversionSource(for: converted, into: cache))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: cache.path)
                .filter { $0.hasPrefix(".video-input-") }
                .isEmpty
        )
    }

    func testWorkshopUpdateWithPreservedLegacyIDDoesNotRemoveUnrelatedIncomingID() throws {
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let unrelatedSource = try Fixture.makeTempDirectory()
        let unrelatedFile = unrelatedSource.appending(path: "unrelated.mp4")
        try Data([1]).write(to: unrelatedFile)
        let unrelated = try store.importAsset(WallpaperAsset(
            id: "123",
            title: "Unrelated",
            kind: .video,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: unrelatedSource.path,
            entrypoint: unrelatedFile.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .direct),
            redistributionAllowed: false,
            issues: []
        ))
        try store.saveDisplayAssignment(DisplayAssignment(displayUUID: "main", assetID: unrelated.id))

        let legacySource = try Fixture.makeTempDirectory()
        let legacyFile = legacySource.appending(path: "legacy.mp4")
        try Data([2]).write(to: legacyFile)
        _ = try store.importAsset(WallpaperAsset(
            id: "legacy-123",
            title: "Legacy Workshop",
            kind: .video,
            supportStatus: .playable,
            source: .localSteamWorkshop,
            projectDirectory: legacySource.path,
            entrypoint: legacyFile.path,
            thumbnail: nil,
            workshopId: "123",
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .direct),
            redistributionAllowed: false,
            issues: []
        ))

        let updateSource = try Fixture.makeTempDirectory()
        let updateFile = updateSource.appending(path: "updated.mp4")
        try Data([3]).write(to: updateFile)
        let updated = try store.importAsset(WallpaperAsset(
            id: "123",
            title: "Updated Workshop",
            kind: .video,
            supportStatus: .playable,
            source: .steamCMD,
            projectDirectory: updateSource.path,
            entrypoint: updateFile.path,
            thumbnail: nil,
            workshopId: "123",
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .direct),
            redistributionAllowed: false,
            issues: []
        ))
        let manifest = try store.load()

        XCTAssertEqual(updated.id, "legacy-123")
        XCTAssertEqual(Set(manifest.assets.map(\.id)), Set(["123", "legacy-123"]))
        XCTAssertEqual(manifest.assets.first(where: { $0.id == "123" })?.title, "Unrelated")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(unrelated.entrypoint)))
        XCTAssertEqual(manifest.displayAssignments.first?.assetID, "123")
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
        try writeValidMP4(to: video)
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
        try writeValidWebM(to: video)
        let store = LibraryStore(root: try Fixture.makeTempDirectory())

        // When
        let imported = try store.importVideoFile(video)

        // Then
        XCTAssertEqual(imported.supportStatus, .needsConversion)
    }

    func testImportMediaFileAcceptsImageIOGIFAndCopiesItIntoLibrary() throws {
        let sourceRoot = try Fixture.makeTempDirectory()
        let gif = sourceRoot.appending(path: "animated.gif")
        let onePixelGIF = try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        )
        try onePixelGIF.write(to: gif)
        let store = LibraryStore(root: try Fixture.makeTempDirectory())

        let imported = try store.importMediaFile(gif)

        XCTAssertEqual(imported.kind, .image)
        XCTAssertEqual(imported.supportStatus, .playable)
        XCTAssertEqual(imported.compatibilityReport?.playbackPath, .direct)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(imported.entrypoint)))
        XCTAssertNotEqual(imported.entrypoint, gif.path)
        XCTAssertEqual(
            imported.contentHash,
            try WallpaperContentHasher.hashFile(URL(filePath: try XCTUnwrap(imported.entrypoint)))
        )
    }

    func testStandaloneImportRollsBackFilesAndManifestWhenTheSingleCommitFails() throws {
        let sourceRoot = try Fixture.makeTempDirectory()
        let gif = sourceRoot.appending(path: "atomic.gif")
        try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        ).write(to: gif)
        let root = try Fixture.makeTempDirectory()
        let writer = ControllableManifestWriter()
        let store = LibraryStore(
            root: root,
            trasher: FileManagerAssetTrasher(),
            manifestWriter: writer
        )
        writer.failNextWrite()

        XCTAssertThrowsError(try store.importMediaFile(gif))

        XCTAssertTrue(try store.load().assets.isEmpty)
        let assetsRoot = root.appending(path: "Assets")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: assetsRoot.path)
        XCTAssertTrue(leftovers.isEmpty, "A failed standalone import must not leave staged or committed files.")
    }

    func testStandaloneImportRejectsASymlinkProducedDuringTheStagingCopy() throws {
        let sourceRoot = try Fixture.makeTempDirectory()
        let gif = sourceRoot.appending(path: "race.gif")
        try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        ).write(to: gif)
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(
            root: root,
            trasher: FileManagerAssetTrasher(),
            manifestWriter: ControllableManifestWriter(),
            standaloneFileCopier: SymlinkProducingStandaloneFileCopier()
        )

        XCTAssertThrowsError(try store.importMediaFile(gif)) { error in
            guard case LibraryStoreError.notRegularFile = error else {
                return XCTFail("Expected staged symlink rejection, got \(error)")
            }
        }

        XCTAssertTrue(try store.load().assets.isEmpty)
        let assetsRoot = root.appending(path: "Assets")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: assetsRoot.path).isEmpty)
    }

    func testImportMediaFileAcceptsWallpaperEngineScenePackageButRejectsInstallerPackage() throws {
        let sourceRoot = try Fixture.makeTempDirectory()
        let scene = sourceRoot.appending(path: "standalone.pkg")
        try Fixture.writeScenePackage(to: scene, sceneJSON: #"{"objects":[]}"#)
        let installer = sourceRoot.appending(path: "installer.pkg")
        try Data("xar!not-a-wallpaper".utf8).write(to: installer)
        let store = LibraryStore(root: try Fixture.makeTempDirectory())

        let imported = try store.importMediaFile(scene)

        XCTAssertEqual(imported.kind, .scene)
        XCTAssertEqual(imported.supportStatus, .playable)
        XCTAssertTrue(try XCTUnwrap(imported.entrypoint).hasSuffix("standalone.pkg"))
        XCTAssertThrowsError(try store.importMediaFile(installer)) { error in
            guard case LibraryStoreError.unsupportedMedia = error else {
                return XCTFail("Expected unsupportedMedia, got \(error)")
            }
        }
    }

    func testImportMediaFileCanonicalizesRenamedPKGVSceneForPlayback() throws {
        let sourceRoot = try Fixture.makeTempDirectory()
        let renamedScene = sourceRoot.appending(path: "renamed-scene.data")
        try Fixture.writeScenePackage(to: renamedScene, sceneJSON: #"{"objects":[]}"#)
        let store = LibraryStore(root: try Fixture.makeTempDirectory())

        let imported = try store.importMediaFile(renamedScene)
        let entrypoint = URL(filePath: try XCTUnwrap(imported.entrypoint))

        XCTAssertEqual(imported.kind, .scene)
        XCTAssertEqual(entrypoint.pathExtension.lowercased(), "pkg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: entrypoint.path))
        XCTAssertEqual(imported.contentHash, try WallpaperContentHasher.hashFile(entrypoint))
    }

    func testImageValidationRejectsSourceBeyondSharedPlayerLimit() throws {
        let root = try Fixture.makeTempDirectory()
        let oversized = root.appending(path: "oversized.gif")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(ImageWallpaperValidation.maximumSourceBytes) + 1)
        try handle.close()

        XCTAssertFalse(ImageWallpaperValidation.isPlayableImage(at: oversized))
        XCTAssertEqual(MediaContentProbe().classify(oversized).kind, .unknown)
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

    func testInstallSceneRenderCachePreservesLimitedEngineLayerClassification() throws {
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "scene-cache-engine-layer")
        let scenePackage = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: #"{"objects":[{"text":{"value":"VISIBLE"}},{"light":"lights/key.json"}]}"#
        )
        let asset = WallpaperAsset(
            id: "scene-cache-engine-layer",
            title: "Engine Layer",
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
        let sourceVideo = try Fixture.makeTempDirectory().appending(path: "cache.mp4")
        try Data([1, 2, 3]).write(to: sourceVideo)

        let updated = try store.installSceneRenderCache(assetID: asset.id, videoURL: sourceVideo)

        XCTAssertEqual(updated.compatibility?.label, "Limited")
        XCTAssertEqual(updated.compatibilityReport?.level, .limited)
        XCTAssertEqual(updated.compatibilityReport?.playbackPath, .renderedSceneCache)
        XCTAssertTrue(updated.compatibilityReport?.missingCapabilities.contains(.engineLayer) == true)
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
        try writeValidMP4(to: video)
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
        try writeValidMP4(to: video)
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
        try writeValidMP4(to: video)
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
        try writeValidMP4(to: video)
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
        try writeValidMP4(to: video)
        let imported = try store.importVideoFile(video)
        writer.failNextWrite()

        XCTAssertThrowsError(try store.removeAsset(id: imported.id))

        XCTAssertEqual(try store.load().assets, [imported])
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testRemoveAssetRestoresManifestWhenTrashAndDeleteFail() throws {
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "restore-cleanup-failure.mp4")
        try writeValidMP4(to: video)
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
        try writeValidMP4(to: video)
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
                (path: "materials/background.tex", data: Data("FUTURE0001\u{0}".utf8))
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

    func testLoadReprobesExistingWebReportAgainstWholeProjectRoot() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "legacy-nested-web")
        let pages = project.appending(path: "pages")
        let scripts = project.appending(path: "scripts")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let entrypoint = pages.appending(path: "index.html")
        try #"<script src="../scripts/wallpaper.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try "window.wallpaperRegisterAudioListener((levels) => draw(levels));"
            .write(to: scripts.appending(path: "wallpaper.js"), atomically: true, encoding: .utf8)
        let stale = WallpaperAsset(
            id: "legacy-nested-web",
            title: "Legacy Nested Web",
            kind: .web,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(
                level: .full,
                playbackPath: .webLive,
                probeVersion: 2
            ),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(stale)

        let refreshed = try XCTUnwrap(store.load().assets.first)

        XCTAssertEqual(refreshed.compatibilityReport?.probeVersion, CompatibilityReport.currentProbeVersion)
        XCTAssertEqual(refreshed.compatibilityReport?.level, .limited)
        XCTAssertEqual(refreshed.compatibilityReport?.missingCapabilities, [.audioReactive])
        XCTAssertEqual(refreshed.compatibility?.label, "Limited")
    }

    func testCurrentProbeReprobesVersionFifteenWebInteractionReport() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "probe-fifteen-web")
        let entrypoint = project.appending(path: "index.html")
        try #"<script>window["onclick"] = chooseWallpaper;</script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let stale = WallpaperAsset(
            id: "probe-fifteen-web",
            title: "Probe Fifteen Web",
            kind: .web,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(
                level: .full,
                playbackPath: .webLive,
                probeVersion: 15
            ),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(stale)

        let refreshed = try XCTUnwrap(store.load().assets.first)

        XCTAssertEqual(CompatibilityReport.currentProbeVersion, 19)
        XCTAssertEqual(refreshed.compatibilityReport?.probeVersion, 19)
        XCTAssertEqual(refreshed.compatibilityReport?.level, .limited)
        XCTAssertEqual(refreshed.compatibilityReport?.missingCapabilities, [.interaction])
        XCTAssertEqual(refreshed.compatibilityReport?.diagnosticCode, "web_interaction_limited")
    }

    func testProbeVersionEighteenRechecksVersionSeventeenDynamicWebMediaReport() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "probe-seventeen-dynamic-web")
        let entrypoint = project.appending(path: "index.html")
        try #"""
        <video src="{{ selectedVideo }}"></video>
        <script>player.src = chooseVideo();</script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)
        let stale = WallpaperAsset(
            id: "probe-seventeen-dynamic-web",
            title: "Probe Seventeen Dynamic Web",
            kind: .web,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(
                level: .full,
                playbackPath: .webLive,
                probeVersion: 17
            ),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(stale)

        let refreshed = try XCTUnwrap(store.load().assets.first)

        XCTAssertEqual(refreshed.compatibilityReport?.probeVersion, 19)
        XCTAssertEqual(refreshed.compatibilityReport?.level, .limited)
        XCTAssertEqual(
            refreshed.compatibilityReport?.diagnosticCode,
            "web_dynamic_media_runtime_pending"
        )
        XCTAssertEqual(refreshed.compatibility?.label, "Limited")
    }

    func testProbeUpgradePreservesBundledInteractionLimitation() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "bundled-interactive-web")
        let entrypoint = project.appending(path: "index.html")
        try "<!doctype html><canvas></canvas>"
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let stale = WallpaperAsset(
            id: "bundled-interactive-web",
            title: "Bundled Interactive Web",
            kind: .web,
            supportStatus: .playable,
            source: .bundledLively,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .limited(reason: "Pointer interaction is unavailable."),
            compatibilityReport: CompatibilityReport(
                level: .limited,
                playbackPath: .webLive,
                requiredCapabilities: [.interaction],
                missingCapabilities: [.interaction],
                warnings: [
                    "Pointer interaction is unavailable while the desktop wallpaper window ignores input."
                ],
                diagnosticCode: "web_interaction_limited",
                probeVersion: 1
            ),
            redistributionAllowed: true,
            issues: []
        )
        try store.replaceAsset(stale)

        let refreshed = try XCTUnwrap(store.load().assets.first)

        XCTAssertEqual(refreshed.compatibilityReport?.probeVersion, CompatibilityReport.currentProbeVersion)
        XCTAssertEqual(refreshed.compatibilityReport?.level, .limited)
        XCTAssertEqual(refreshed.compatibilityReport?.requiredCapabilities, [.interaction])
        XCTAssertEqual(refreshed.compatibilityReport?.missingCapabilities, [.interaction])
        XCTAssertEqual(refreshed.compatibilityReport?.diagnosticCode, "web_interaction_limited")
    }

    func testProbeUpgradeReclassifiesExistingWebMediaIntegration() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "legacy-media-web")
        let entrypoint = project.appending(path: "index.html")
        try "<script>wallpaperRegisterMediaPlaybackListener(updatePlayback)</script>"
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let stale = WallpaperAsset(
            id: "legacy-media-web",
            title: "Legacy Media Web",
            kind: .web,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(
                level: .full,
                playbackPath: .webLive,
                probeVersion: 4
            ),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(stale)

        let refreshed = try XCTUnwrap(store.load().assets.first)

        XCTAssertEqual(refreshed.compatibilityReport?.probeVersion, CompatibilityReport.currentProbeVersion)
        XCTAssertEqual(refreshed.compatibilityReport?.level, .limited)
        XCTAssertEqual(refreshed.compatibilityReport?.missingCapabilities, [.mediaIntegration])
        XCTAssertEqual(refreshed.compatibilityReport?.diagnosticCode, "web_media_integration_limited")
        XCTAssertEqual(refreshed.compatibility?.label, "Limited")
    }

    func testProbeUpgradeReclassifiesWebAssetWithUnplayableStaticMedia() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "legacy-static-web-media")
        let entrypoint = project.appending(path: "index.html")
        try #"<video autoplay loop src="loop.ogv"></video>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try Data([0x4f, 0x67, 0x67, 0x53]).write(to: project.appending(path: "loop.ogv"))
        let stale = WallpaperAsset(
            id: "legacy-static-web-media",
            title: "Legacy Static Web Media",
            kind: .web,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(
                level: .full,
                playbackPath: .webLive,
                probeVersion: 8
            ),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(stale)

        let refreshed = try XCTUnwrap(store.load().assets.first)

        XCTAssertEqual(
            refreshed.compatibilityReport?.probeVersion,
            CompatibilityReport.currentProbeVersion
        )
        XCTAssertEqual(refreshed.compatibilityReport?.level, .full)
        XCTAssertEqual(
            refreshed.compatibilityReport?.diagnosticCode,
            "web_static_media_needs_preparation"
        )
        XCTAssertEqual(refreshed.compatibility?.label, "Live")
    }

    func testProbeUpgradeStopsExistingWebAssetWhoseRequiredScriptIsMissing() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "legacy-missing-web-script")
        let entrypoint = project.appending(path: "index.html")
        try #"<!doctype html><canvas></canvas><script src="missing-runtime.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let stale = WallpaperAsset(
            id: "legacy-missing-web-script",
            title: "Legacy Missing Web Script",
            kind: .web,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(
                level: .full,
                playbackPath: .webLive,
                probeVersion: 5
            ),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(stale)

        let refreshed = try XCTUnwrap(store.load().assets.first)

        XCTAssertEqual(refreshed.supportStatus, .unsupported)
        XCTAssertEqual(
            refreshed.compatibilityReport?.probeVersion,
            CompatibilityReport.currentProbeVersion
        )
        XCTAssertEqual(refreshed.compatibilityReport?.level, .unsupported)
        XCTAssertEqual(
            refreshed.compatibilityReport?.diagnosticCode,
            "web_local_dependency_missing"
        )
        XCTAssertEqual(refreshed.compatibility?.label, "Unsupported")
    }

    func testProbeUpgradeStopsExistingWebAssetWhoseRequiredRemoteScriptIsBlocked() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "legacy-remote-web-script")
        let entrypoint = project.appending(path: "index.html")
        try #"<!doctype html><canvas></canvas><script src="https://cdn.example/render.js"></script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let stale = WallpaperAsset(
            id: "legacy-remote-web-script",
            title: "Legacy Remote Web Script",
            kind: .web,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(
                level: .full,
                playbackPath: .webLive,
                probeVersion: 6
            ),
            allowsNetworkAccess: false,
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(stale)

        let refreshed = try XCTUnwrap(store.load().assets.first)

        XCTAssertEqual(refreshed.supportStatus, .unsupported)
        XCTAssertEqual(refreshed.compatibilityReport?.probeVersion, CompatibilityReport.currentProbeVersion)
        XCTAssertEqual(refreshed.compatibilityReport?.missingCapabilities, [.externalNetwork])
        XCTAssertEqual(
            refreshed.compatibilityReport?.diagnosticCode,
            "web_network_access_required"
        )
        XCTAssertEqual(refreshed.compatibility?.label, "Unsupported")
    }

    func testProbeUpgradeStopsLegacyRemoteWebsiteConfigurationWhenNetworkIsBlocked() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "legacy-remote-website")
        let entrypoint = project.appending(path: "index.html")
        try "<!doctype html><p>Background Engine website placeholder</p>"
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        let configuration = try RemoteWebWallpaperConfiguration(
            targetURL: URL(string: "https://example.com/wallpaper")!
        )
        try JSONEncoder().encode(configuration).write(
            to: project.appending(path: RemoteWebWallpaperConfiguration.fileName),
            options: [.atomic]
        )
        let stale = WallpaperAsset(
            id: "legacy-remote-website",
            title: "Legacy Remote Website",
            kind: .web,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(
                level: .full,
                playbackPath: .webLive,
                probeVersion: 6
            ),
            allowsNetworkAccess: false,
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(stale)

        let refreshed = try XCTUnwrap(store.load().assets.first)

        XCTAssertEqual(refreshed.supportStatus, .unsupported)
        XCTAssertEqual(refreshed.compatibilityReport?.probeVersion, CompatibilityReport.currentProbeVersion)
        XCTAssertEqual(refreshed.compatibilityReport?.missingCapabilities, [.externalNetwork])
        XCTAssertEqual(refreshed.compatibilityReport?.diagnosticCode, "web_network_access_required")
    }

    func testProbeUpgradeStopsExistingWebAssetWhoseEntrypointWasDeleted() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "legacy-deleted-web-entry")
        let entrypoint = project.appending(path: "index.html")
        try "<!doctype html>".write(to: entrypoint, atomically: true, encoding: .utf8)
        let stale = WallpaperAsset(
            id: "legacy-deleted-web-entry",
            title: "Legacy Deleted Web Entry",
            kind: .web,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(
                level: .full,
                playbackPath: .webLive,
                probeVersion: 5
            ),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(stale)
        try FileManager.default.removeItem(at: entrypoint)

        let refreshed = try XCTUnwrap(store.load().assets.first)

        XCTAssertEqual(refreshed.supportStatus, .unsupported)
        XCTAssertEqual(
            refreshed.compatibilityReport?.probeVersion,
            CompatibilityReport.currentProbeVersion
        )
        XCTAssertEqual(refreshed.compatibilityReport?.level, .unsupported)
        XCTAssertEqual(
            refreshed.compatibilityReport?.diagnosticCode,
            "web_entrypoint_unavailable"
        )
        XCTAssertEqual(refreshed.compatibility?.label, "Unsupported")
    }

    func testProbeUpgradePreservesConvertedVideoPlaybackPath() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "legacy-converted-video")
        let convertedVideo = project.appending(path: "converted.mp4")
        try Data([1, 2, 3]).write(to: convertedVideo)
        let stale = WallpaperAsset(
            id: "legacy-converted-video",
            title: "Legacy Converted Video",
            kind: .video,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: convertedVideo.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .cached(reason: "Converted for AVFoundation playback."),
            compatibilityReport: CompatibilityReport(
                level: .full,
                playbackPath: .convertedVideo,
                probeVersion: 2
            ),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(stale)

        let refreshed = try XCTUnwrap(store.load().assets.first)

        XCTAssertEqual(refreshed.compatibilityReport?.probeVersion, CompatibilityReport.currentProbeVersion)
        XCTAssertEqual(refreshed.compatibilityReport?.playbackPath, .convertedVideo)
        XCTAssertEqual(refreshed.compatibility?.label, "Cached")
    }

    func testProbeVersion14RechecksVersion13SceneForEmbeddedVideoTexture() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "legacy-video-texture")
        let packageURL = project.appending(path: "scene.pkg")
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
            sceneJSON: #"{"objects":[{"id":1,"text":{"value":"VISIBLE"}},{"id":2,"image":"models/video.json"}]}"#,
            extraEntries: [
                (path: "models/video.json", data: Data(#"{"material":"materials/video.json"}"#.utf8)),
                (path: "materials/video.json", data: Data(#"{"passes":[{"textures":["video"]}]}"#.utf8)),
                (path: "materials/video.tex", data: embeddedVideoTexture)
            ]
        )
        let stale = WallpaperAsset(
            id: "legacy-video-texture",
            title: "Legacy Video Texture",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: packageURL.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(
                level: .full,
                playbackPath: .nativeScene,
                probeVersion: 13
            ),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(stale)

        let pending = try XCTUnwrap(store.load().assets.first)
        XCTAssertEqual(pending.compatibilityReport?.probeVersion, CompatibilityReport.currentProbeVersion)
        XCTAssertTrue(pending.compatibilityReport?.needsProbe == true)

        let refreshed = store.probeSceneCompatibility(for: pending)
        XCTAssertEqual(refreshed.compatibilityReport?.playbackPath, .renderedSceneCache)
        XCTAssertTrue(refreshed.compatibilityReport?.requiredCapabilities.contains(.videoTexture) == true)
    }

    func testProbeVersion17RechecksVersion16SceneReport() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "probe-sixteen-scene")
        let packageURL = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(to: packageURL, sceneJSON: #"{"objects":[]}"#)
        let stale = WallpaperAsset(
            id: "probe-sixteen-scene",
            title: "Probe Sixteen Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: packageURL.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(
                level: .full,
                playbackPath: .nativeScene,
                probeVersion: 16
            ),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(stale)

        let pending = try XCTUnwrap(store.load().assets.first)
        XCTAssertEqual(pending.compatibilityReport?.probeVersion, 19)
        XCTAssertTrue(pending.compatibilityReport?.needsProbe == true)

        let refreshed = store.probeSceneCompatibility(for: pending)
        XCTAssertEqual(refreshed.compatibilityReport?.probeVersion, 19)
        XCTAssertFalse(refreshed.compatibilityReport?.needsProbe == true)
        XCTAssertNotEqual(refreshed.compatibilityReport?.level, .unsupported)
    }

    func testProbeVersion14RechecksVersion13NestedSceneProjectAudioMetadata() throws {
        let root = try Fixture.makeTempDirectory()
        let store = LibraryStore(root: root)
        let project = try makeImportedProjectDirectory(in: root, id: "legacy-nested-audio")
        let content = project.appending(path: "content", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        let packageURL = content.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"id":1,"text":{"value":"VISIBLE"}}]}"#
        )
        try #"{"title":"Nested audio","type":"scene","file":"content/scene.pkg","general":{"supportsaudioprocessing":true}}"#
            .write(
                to: project.appending(path: "project.json"),
                atomically: true,
                encoding: .utf8
            )
        let stale = WallpaperAsset(
            id: "legacy-nested-audio",
            title: "Legacy Nested Audio",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: packageURL.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(
                level: .full,
                playbackPath: .nativeScene,
                probeVersion: 13
            ),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(stale)

        let pending = try XCTUnwrap(store.load().assets.first)
        XCTAssertTrue(pending.compatibilityReport?.needsProbe == true)

        let refreshed = store.probeSceneCompatibility(for: pending)
        XCTAssertEqual(
            refreshed.compatibilityReport?.probeVersion,
            CompatibilityReport.currentProbeVersion
        )
        XCTAssertEqual(refreshed.compatibilityReport?.level, .limited)
        XCTAssertEqual(refreshed.compatibilityReport?.playbackPath, .renderedSceneCache)
        XCTAssertTrue(refreshed.compatibilityReport?.requiredCapabilities.contains(.audioReactive) == true)
        XCTAssertTrue(refreshed.compatibilityReport?.missingCapabilities.contains(.audioReactive) == true)
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
        try writeValidMP4(to: video)
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

    /// A one-frame 16x16 H.264 stream in an MP4 container. Keeping this
    /// real probeable media in the test source makes the LibraryStore suite
    /// behave identically with CI's bundled FFprobe and without a system
    /// media tool at runtime.
    private func writeValidMP4(to url: URL) throws {
        let encoded = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAAIZnJlZQAAAs1tZGF0AAACrQYF//+p
        3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBF
        Ry00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4u
        b3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTMgZGVibG9jaz0xOjA6MCBhbmFs
        eXNlPTB4MzoweDExMyBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVk
        X3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MSBjcW09MCBk
        ZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTEg
        bG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRl
        cmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0zIGJf
        cHlyYW1pZD0yIGJfYWRhcHQ9MSBiX2JpYXM9MCBkaXJlY3Q9MSB3ZWlnaHRiPTEgb3Blbl9nb3A9
        MCB3ZWlnaHRwPTIga2V5aW50PTI1MCBrZXlpbnRfbWluPTEgc2NlbmVjdXQ9NDAgaW50cmFfcmVm
        cmVzaD0wIHJjX2xvb2thaGVhZD00MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42
        MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAAQ
        ZYiEABX//vfJ78Cm69vfgQAAAwNtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAD6AABAAAB
        AAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAACAAACLnRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAD
        6AAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAEAAA
        ABAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAA+gAAAAAAAEAAAAAAaZtZGlhAAAAIG1kaGQA
        AAAAAAAAAAAAAAAAAEAAAABAAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZp
        ZGVvSGFuZGxlcgAAAAFRbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAA
        AAAAAAABAAAADHVybCAAAAABAAABEXN0YmwAAACtc3RzZAAAAAAAAAABAAAAnWF2YzEAAAAAAAAA
        AQAAAAAAAAAAAAAAAAAAAAAAEAAQAEgAAABIAAAAAAAAAAEUTGF2YzYzLjEuMTAxIGxpYngyNjQA
        AAAAAAAAAAAAAAAY//8AAAAzYXZjQwFkAAr/4QAWZ2QACqzZXoQAAAMABAAAAwAIPEiWWAEABmjr
        48siwP34+AAAAAAUYnRydAAAAAAAABYoAAAAAAAAABhzdHRzAAAAAAAAAAEAAAABAABAAAAAABxz
        dHNjAAAAAAAAAAEAAAABAAAAAQAAAAEAAAAUc3RzegAAAAAAAALFAAAAAQAAABRzdGNvAAAAAAAA
        AAEAAAAwAAAAYXVkdGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAA
        AAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2My4xLjEwMQ==
        """
        let data = try XCTUnwrap(
            Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        )
        try data.write(to: url)
    }

    /// A one-frame 2x2 VP8 stream in a WebM container for the conversion-path
    /// import test. It is content-probeable even when the filename extension
    /// allowlist is deliberately ignored.
    private func writeValidWebM(to url: URL) throws {
        let encoded = """
        GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAHzEU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZUrmtTrIHWTbuMU6uEElTDZ1OsggEyTbuMU6uEHFO7a1OsggHd7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsCrXsYMPQkBNgIxMYXZmNjMuMS4xMDFXQYxMYXZmNjMuMS4xMDFEiYhAj0AAAAAAABZUrmvXrgEAAAAAAABO14EBc8WI7oZU9p64iM+cgQAitZyDdW5kiIEAhoVWX1ZQOIOBASPjg4Q7msoA4JCwgQK6gQKagQJVsIRVuYEBVe6BAOwBAAAAAAAAAgAAElTDZ/pzc59jwIBnyJlFo4dFTkNPREVSRIeMTGF2ZjYzLjEuMTAxc3PVY8CLY8WI7oZU9p64iM9nyKBFo4dFTkNPREVSRIeTTGF2YzYzLjEuMTAxIGxpYnZweGfIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDEuMDAwMDAwMDAwAB9DtnWn54EAo6KBAACAEAIAnQEqAgACAAvHCIWFiJmEiD+CAAwNYAD+5rUAHFO7a5G7j7OBALeK94EB8YIBsfCBAw==
        """
        let data = try XCTUnwrap(
            Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        )
        try data.write(to: url)
    }

    private func makeImportedProjectDirectory(in root: URL, id: String) throws -> URL {
        let project = root.appending(path: "Assets").appending(path: id)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    private func makeVideoImportFixture(
        id: String,
        source: SourceKind,
        workshopID: String?
    ) throws -> (asset: WallpaperAsset, root: URL) {
        let root = try Fixture.makeTempDirectory()
        let video = root.appending(path: "wallpaper.mp4")
        try Data([1, 2, 3, 4]).write(to: video)
        return (
            WallpaperAsset(
                id: id,
                title: id,
                kind: .video,
                supportStatus: .playable,
                source: source,
                projectDirectory: root.path,
                entrypoint: video.path,
                thumbnail: nil,
                workshopId: workshopID,
                compatibility: .live(),
                compatibilityReport: CompatibilityReport(level: .full, playbackPath: .direct),
                redistributionAllowed: false,
                issues: []
            ),
            root
        )
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

private struct SymlinkProducingStandaloneFileCopier: StandaloneFileCopying {
    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
    }
}
