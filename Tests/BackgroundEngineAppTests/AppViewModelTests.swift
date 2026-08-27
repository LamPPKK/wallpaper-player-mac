import Foundation
import XCTest
@testable import BackgroundEngineApp
@_spi(LivelyCatalog) import BackgroundEngineCore

@MainActor
final class AppViewModelTests: XCTestCase {
    func testBundledLivelyCollectionShipsSixValidatedWebWallpapers() async throws {
        let root = try XCTUnwrap(BundledLivelyWallpaperResources.rootURL())
        let store = LibraryStore(root: try makeTempDirectory())
        let collection = BundledWallpaperCollection(root: root, store: store)

        let catalog = try await collection.catalog()
        let candidates = try await collection.candidates()

        XCTAssertEqual(catalog.sourceRelease, "v2.2.1.0")
        XCTAssertEqual(
            catalog.sourceCommit,
            "6860a4093fc50058c4815908658a4391c4449935"
        )
        XCTAssertEqual(catalog.schemaVersion, 2)
        XCTAssertEqual(candidates.count, 6)
        XCTAssertEqual(Set(candidates.map(\.asset.id)), [
            "lively-the-hill",
            "lively-periodic-table",
            "lively-parallax",
            "lively-music-tv",
            "lively-depth-observatory",
            "lively-chromatic-fluids"
        ])
        XCTAssertTrue(candidates.allSatisfy {
            $0.asset.kind == .web
                && $0.asset.source == .bundledLively
                && $0.asset.supportStatus == .playable
                && $0.asset.redistributionAllowed
        })
        let reports = Dictionary(uniqueKeysWithValues: candidates.map {
            ($0.asset.id, $0.asset.compatibilityReport)
        })
        for id in [
            "lively-periodic-table",
            "lively-parallax"
        ] {
            let report = try XCTUnwrap(reports[id] ?? nil)
            XCTAssertEqual(report.level, .limited, id)
            XCTAssertEqual(report.missingCapabilities, [.interaction], id)
            XCTAssertEqual(report.diagnosticCode, "web_interaction_limited", id)
        }
        let hill = try XCTUnwrap(reports["lively-the-hill"] ?? nil)
        XCTAssertEqual(hill.level, .limited)
        XCTAssertEqual(hill.missingCapabilities, [.interaction])
        XCTAssertEqual(hill.diagnosticCode, "web_interaction_limited")
        let musicTV = try XCTUnwrap(reports["lively-music-tv"] ?? nil)
        XCTAssertEqual(musicTV.level, .limited)
        XCTAssertEqual(
            musicTV.missingCapabilities,
            [.audioReactive, .externalNetwork, .interaction, .mediaIntegration]
        )
        let depth = try XCTUnwrap(reports["lively-depth-observatory"] ?? nil)
        XCTAssertEqual(depth.level, .limited)
        XCTAssertEqual(depth.missingCapabilities, [.externalNetwork, .interaction])
        XCTAssertEqual(depth.diagnosticCode, "web_interaction_limited")
        let depthEntry = try XCTUnwrap(
            catalog.wallpapers.first { $0.id == "lively-depth-observatory" }
        )
        XCTAssertEqual(
            depthEntry.sourceRepository,
            "https://github.com/rocksdanister/depthmap-wallpaper"
        )
        XCTAssertEqual(
            depthEntry.sourceCommit,
            "0a0e64ef5b1f56544899adfb909a335bfe246286"
        )
        let fluids = try XCTUnwrap(reports["lively-chromatic-fluids"] ?? nil)
        XCTAssertEqual(fluids.level, .limited)
        XCTAssertEqual(fluids.missingCapabilities, [.audioReactive, .interaction])
        let fluidsEntry = try XCTUnwrap(
            catalog.wallpapers.first { $0.id == "lively-chromatic-fluids" }
        )
        XCTAssertEqual(fluidsEntry.sourceRelease, "v6")
        XCTAssertEqual(
            fluidsEntry.sourceCommit,
            "bd028c0b4a931c4173e77e52cb953d964e857557"
        )
    }

    func testBundledLivelyDerivativesExposePropertiesAndSuspendTheirRenderLoops() throws {
        let collectionRoot = try XCTUnwrap(BundledLivelyWallpaperResources.rootURL())
        let depthRoot = collectionRoot.appending(path: "lively-depth-observatory")
        let fluidsRoot = collectionRoot.appending(path: "lively-chromatic-fluids")

        let depthProperties = WebWallpaperCompatibilityBridge.editableProperties(
            projectRoot: depthRoot
        )
        XCTAssertEqual(depthProperties.map(\.name), [
            "blur", "fpsLock", "stretch", "xThreshold", "yThreshold"
        ])
        XCTAssertEqual(
            WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: depthRoot)["xThreshold"],
            .number(30)
        )

        let fluidProperties = WebWallpaperCompatibilityBridge.editableProperties(
            projectRoot: fluidsRoot
        )
        XCTAssertEqual(fluidProperties.count, 16)
        let fluidDefaults = WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: fluidsRoot)
        XCTAssertEqual(fluidDefaults["quality"], .text("1"))
        XCTAssertEqual(fluidDefaults["simResolution"], .text("2"))
        XCTAssertEqual(fluidDefaults["randomSplats"], .bool(true))
        let livelyValues = WebWallpaperCompatibilityBridge.livelyCallbackProperties(
            projectRoot: fluidsRoot,
            mappedValues: fluidDefaults
        )
        XCTAssertEqual(livelyValues["quality"] as? Int, 1)
        XCTAssertEqual(livelyValues["simResolution"] as? Int, 2)

        let depthScript = try String(
            contentsOf: depthRoot.appending(path: "js/script.js"),
            encoding: .utf8
        )
        XCTAssertTrue(depthScript.contains("cancelAnimationFrame(renderFrameRequest)"))
        XCTAssertTrue(depthScript.contains("if (isPaused) return;"))

        let fluidsScript = try String(
            contentsOf: fluidsRoot.appending(path: "js/script.js"),
            encoding: .utf8
        )
        XCTAssertTrue(fluidsScript.contains("createTextureAsync(\"js/LDR_LLL1_0.png\")"))
        XCTAssertTrue(fluidsScript.contains("cancelAnimationFrame(updateFrameRequest)"))
        XCTAssertTrue(fluidsScript.contains("clearTimeout(randomSplatTimer)"))
        XCTAssertFalse(fluidsScript.contains("setInterval(randomSplat"))
        XCTAssertFalse(fluidsScript.contains("if (!config.PAUSED) step(dt)"))
    }

    func testInstallingBundledLivelyCollectionIsExplicitAndIdempotent() async throws {
        let source = try XCTUnwrap(BundledLivelyWallpaperResources.rootURL())
        let store = LibraryStore(root: try makeTempDirectory())
        let player = AssetReconcilingWallpaperPlayer()
        let model = AppViewModel(
            store: store,
            wallpaperPlayer: player,
            bundledLivelyWallpaperRootProvider: { source },
            userDefaults: try makeUserDefaults()
        )

        XCTAssertTrue(try store.load().assets.isEmpty, "Bundled content must not auto-install.")
        await model.installBundledLivelyWallpapers().value

        let firstInstall = try store.load().assets
        XCTAssertEqual(firstInstall.count, 6)
        XCTAssertTrue(firstInstall.allSatisfy {
            $0.source == .bundledLively && $0.redistributionAllowed
        })
        XCTAssertEqual(
            firstInstall.first { $0.id == "lively-parallax" }?
                .compatibilityReport?.missingCapabilities,
            [.interaction]
        )
        XCTAssertEqual(model.selectedLibraryAssetIds, Set(firstInstall.map(\.id)))
        XCTAssertEqual(model.status, "Installed 6 curated Lively wallpapers.")
        XCTAssertTrue(player.preparedReplacementAssetIDs.isEmpty)

        await model.installBundledLivelyWallpapers().value

        XCTAssertEqual(try store.load().assets.count, 6)
        XCTAssertEqual(model.status, "Installed 6 curated Lively wallpapers.")
        XCTAssertEqual(Set(player.preparedReplacementAssetIDs), Set(firstInstall.map(\.id)))
        XCTAssertEqual(
            player.finishedReplacementAssetIDs.sorted(),
            player.preparedReplacementAssetIDs.sorted()
        )
    }

    func testImportingUserSuppliedLivelyFolderSelectsWebAssetWithoutEditingSource() async throws {
        let source = try makeTempDirectory()
        let infoURL = source.appending(path: "LivelyInfo.json")
        let entrypointURL = source.appending(path: "index.html")
        let info = Data(
            """
            {
              "AppVersion": "2.2.1.0",
              "Title": "User Supplied Lively",
              "Type": 1,
              "FileName": "index.html",
              "IsAbsolutePath": false
            }
            """.utf8
        )
        let entrypoint = Data(
            """
            <!doctype html>
            <html><body><h1>User package</h1></body></html>
            """.utf8
        )
        try info.write(to: infoURL)
        try entrypoint.write(to: entrypointURL)
        let originalDirectoryEntries = try FileManager.default.contentsOfDirectory(
            atPath: source.path
        ).sorted()

        let store = LibraryStore(root: try makeTempDirectory())
        let model = AppViewModel(
            store: store,
            wallpaperPlayer: AssetReconcilingWallpaperPlayer(),
            userDefaults: try makeUserDefaults()
        )

        await model.importLivelyWallpaperPackage(source).value

        let imported = try XCTUnwrap(store.load().assets.first, model.status)
        XCTAssertEqual(imported.title, "User Supplied Lively")
        XCTAssertEqual(imported.kind, .web)
        XCTAssertEqual(imported.source, .manualFolder)
        XCTAssertFalse(imported.redistributionAllowed)
        XCTAssertEqual(model.selectedLibraryAssetId, imported.id)
        XCTAssertEqual(model.selectedLibraryAsset?.id, imported.id)
        XCTAssertEqual(model.status, "Added User Supplied Lively from Lively.")
        XCTAssertNotEqual(imported.projectDirectory, source.path)

        XCTAssertEqual(try Data(contentsOf: infoURL), info)
        XCTAssertEqual(try Data(contentsOf: entrypointURL), entrypoint)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: source.path).sorted(),
            originalDirectoryEntries
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source.appending(path: "project.json").path),
            "Normalization must happen on isolated staging, not in the selected source folder."
        )
    }

    func testConvertedVideoCacheCommitQuiescesPlaybackUntilLibraryReloads() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/AppViewModel.swift")
        let start = try XCTUnwrap(source.range(of: "private func convertAsset("))
        let end = try XCTUnwrap(
            source.range(of: "func stopPlayback()", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])
        let prepare = try XCTUnwrap(body.range(of: "await wallpaperPlayer.prepareForLibraryAssetReplacement(asset.id)"))
        let replace = try XCTUnwrap(
            body.range(of: "guard try store.replaceAsset(converted, ifUnchangedFrom: asset)")
        )
        let reload = try XCTUnwrap(body.range(of: "loadLibrary()"))
        let finish = try XCTUnwrap(body.range(of: "wallpaperPlayer.finishLibraryAssetReplacement(asset.id)"))

        XCTAssertLessThan(prepare.lowerBound, replace.lowerBound)
        XCTAssertLessThan(replace.lowerBound, reload.lowerBound)
        XCTAssertLessThan(reload.lowerBound, finish.lowerBound)
        XCTAssertTrue(body.contains("(PinnedVideoInput, URL, String)"))
        XCTAssertTrue(body.contains("defer { preparation.0.cleanup() }"))
        XCTAssertFalse(body.contains("FileManager.default.removeItem(at: preparation.0)"))
    }

    func testDirectVideoRuntimeFailureConvertsOnceAndCommitsCachedRevision() async throws {
        let root = try makeTempDirectory()
        let cache = try makeTempDirectory()
        let source = try makeTempDirectory()
        let sourceVideo = source.appending(path: "runtime-direct.mkv")
        try Data("runtime-direct-video".utf8).write(to: sourceVideo)
        let store = LibraryStore(
            root: root,
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
        let invocationLog = root.appending(path: "ffmpeg-invocations")
        let converter = try makeRuntimeFallbackVideoConverter(
            in: root,
            invocationLog: invocationLog
        )
        let player = AssetReconcilingWallpaperPlayer()
        let lockScreen = MockLockScreenAnimationController()
        let model = AppViewModel(
            store: store,
            lockScreenAnimationController: lockScreen,
            videoConverter: converter,
            videoConversionCacheDirectory: cache,
            wallpaperPlayer: player,
            userDefaults: try makeUserDefaults()
        )
        model.lockScreenAnimationEnabled = true
        model.playSelected()
        let failure = VideoPlaybackFailure(
            asset: imported,
            displayUUID: "primary-display",
            message: "The video could not be decoded."
        )

        player.videoRuntimeFailureHandler?(failure)
        player.videoRuntimeFailureHandler?(VideoPlaybackFailure(
            asset: imported,
            displayUUID: "secondary-display",
            message: "No decoded frame became ready."
        ))
        await model.waitForVideoRuntimeRecoveries()

        let converted = try XCTUnwrap(store.load().assets.first)
        XCTAssertEqual(converted.compatibilityReport?.playbackPath, .convertedVideo)
        XCTAssertEqual(converted.compatibilityReport?.diagnosticCode, "video_runtime_fallback")
        XCTAssertEqual(converted.supportStatus, .playable)
        XCTAssertNotEqual(converted.entrypoint, imported.entrypoint)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(converted.entrypoint)))
        let invocations = (try String(contentsOf: invocationLog, encoding: .utf8))
            .split(whereSeparator: \.isNewline)
        XCTAssertEqual(invocations.count, 1, "Two displays must share one recovery conversion.")
        XCTAssertTrue(player.preparedReplacementAssetIDs.isEmpty)
        XCTAssertEqual(player.reconciledAssets.last?.first, converted)
        XCTAssertTrue(model.status.contains("converted fallback"))
        XCTAssertEqual(lockScreen.updatedEntrypoints.last, converted.entrypoint)
    }

    func testStopCancelsAndDrainsRuntimeVideoRecoveryWithoutBlockingReplay() async throws {
        let root = try makeTempDirectory()
        let cache = try makeTempDirectory()
        let source = try makeTempDirectory()
        let sourceVideo = source.appending(path: "runtime-stop.mkv")
        try Data("runtime-stop-video".utf8).write(to: sourceVideo)
        let store = LibraryStore(root: root, convertedVideoCacheDirectory: cache)
        let imported = try store.importAsset(WallpaperAsset(
            id: "runtime-stop",
            title: "Runtime Stop",
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
        let invocationLog = root.appending(path: "ffmpeg-stop-invocations")
        let blockFile = root.appending(path: "block-ffmpeg")
        try Data().write(to: blockFile)
        let converter = try makeRuntimeFallbackVideoConverter(
            in: root,
            invocationLog: invocationLog,
            blockFile: blockFile
        )
        let player = AssetReconcilingWallpaperPlayer()
        let model = AppViewModel(
            store: store,
            videoConverter: converter,
            videoConversionCacheDirectory: cache,
            wallpaperPlayer: player,
            userDefaults: try makeUserDefaults()
        )
        let failure = VideoPlaybackFailure(
            asset: imported,
            displayUUID: "primary-display",
            message: "The video could not be decoded."
        )

        player.videoRuntimeFailureHandler?(failure)
        try await waitForFile(invocationLog)
        model.stopPlayback()

        XCTAssertEqual(model.status, "Playback stopped.")
        XCTAssertEqual(try store.load().assets.first?.compatibilityReport?.playbackPath, .direct)
        player.videoRuntimeFailureHandler?(failure)
        XCTAssertEqual(
            try String(contentsOf: invocationLog, encoding: .utf8)
                .split(whereSeparator: \.isNewline).count,
            1,
            "A late decoder callback after Stop must not start new work."
        )

        try FileManager.default.removeItem(at: blockFile)
        model.playSelected()
        player.videoRuntimeFailureHandler?(failure)
        await model.waitForVideoRuntimeRecoveries()

        XCTAssertEqual(try store.load().assets.first?.compatibilityReport?.playbackPath, .convertedVideo)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: cache.path).contains {
            $0.hasPrefix(".video-input-") || $0.contains(".incoming-")
        })
        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        XCTAssertEqual(invocations.count, 2, "A cancelled revision must be eligible for replay.")
    }

    func testQuitBarrierCancelsAndDrainsManualVideoConversion() async throws {
        let root = try makeTempDirectory()
        let cache = try makeTempDirectory()
        let source = try makeTempDirectory()
        let sourceVideo = source.appending(path: "manual-quit.mkv")
        try Data("manual-quit-video".utf8).write(to: sourceVideo)
        let store = LibraryStore(root: root, convertedVideoCacheDirectory: cache)
        let imported = try store.importAsset(WallpaperAsset(
            id: "manual-quit",
            title: "Manual Quit",
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
        let invocationLog = root.appending(path: "manual-quit-invocations")
        let blockFile = root.appending(path: "block-manual-ffmpeg")
        try Data().write(to: blockFile)
        let model = AppViewModel(
            store: store,
            videoConverter: try makeRuntimeFallbackVideoConverter(
                in: root,
                invocationLog: invocationLog,
                blockFile: blockFile
            ),
            videoConversionCacheDirectory: cache,
            wallpaperPlayer: AssetReconcilingWallpaperPlayer(),
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = imported.id

        model.convertSelected()
        try await waitForFile(invocationLog)
        await model.cancelAndWaitForVideoConversionJobs()

        XCTAssertEqual(try store.load().assets.first?.compatibilityReport?.playbackPath, .direct)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: cache.path).contains {
            $0.hasPrefix(".video-input-") || $0.contains(".incoming-")
        })
    }

    func testQuitBarrierCancelsAndDrainsTrackedLibraryOperations() async throws {
        let root = try makeTempDirectory()
        let cleanupMarker = root.appending(path: "library-operation-cleaned")
        let model = AppViewModel(
            store: LibraryStore(root: root),
            wallpaperPlayer: AssetReconcilingWallpaperPlayer(),
            userDefaults: try makeUserDefaults()
        )
        let operation = Task<Void, Never> {
            defer { try? Data("clean".utf8).write(to: cleanupMarker) }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                // The defer is the cleanup work the quit barrier must await.
            }
        }
        model.installActiveLibraryOperationTask(operation)

        await model.cancelAndWaitForApplicationJobs()

        XCTAssertTrue(operation.isCancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanupMarker.path))
    }

    func testQuitBarrierPropagatesCancellationIntoScanWorker() async throws {
        let root = try makeTempDirectory()
        let source = try makeTempDirectory()
        let probe = CancellationObservingScanWorker()
        let model = AppViewModel(
            store: LibraryStore(root: root),
            wallpaperPlayer: AssetReconcilingWallpaperPlayer(),
            scanWallpaperSource: { root in
                try probe.scan(root: root)
            },
            userDefaults: try makeUserDefaults()
        )
        model.sourcePath = source.path
        let scan = model.scanSource()
        defer { probe.release() }

        for _ in 0..<200 {
            if probe.isStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(probe.isStarted)
        await model.cancelAndWaitForApplicationJobs()

        XCTAssertTrue(scan.isCancelled)
        XCTAssertTrue(probe.observedCancellation)
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.status, "Scan cancelled.")
    }

    func testRuntimeOutputLeaseRegistryAuthorizesCleanupOnlyAfterFinalRelease() {
        let output = URL(filePath: "/tmp/background-engine/shared-runtime-cache.mp4")
        var registry = VideoRuntimeOutputLeaseRegistry()
        let first = registry.acquire(output)
        let second = registry.acquire(output)

        XCTAssertEqual(first, second)
        XCTAssertFalse(registry.release(first))
        XCTAssertEqual(registry.counts[second], 1)
        XCTAssertTrue(registry.release(second))
        XCTAssertNil(registry.counts[second])
        XCTAssertFalse(registry.release(second), "A repeated release must fail closed.")
    }

    func testBlockingWebNetworkAccessReconcilesTheActivePlayerSnapshot() throws {
        let store = LibraryStore(root: try makeTempDirectory())
        let defaults = try makeUserDefaults()
        let player = AssetReconcilingWallpaperPlayer()
        let web = WallpaperAsset(
            id: "web-network",
            title: "Web",
            kind: .web,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: "/library/web-network",
            entrypoint: "/library/web-network/index.html",
            thumbnail: nil,
            workshopId: nil,
            contentHash: "web-hash",
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .webLive),
            allowsNetworkAccess: true,
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(web)
        let model = AppViewModel(
            store: store,
            wallpaperPlayer: player,
            userDefaults: defaults
        )

        model.requestWebNetworkAccessChange(for: web)

        XCTAssertEqual(try store.load().assets.first?.allowsNetworkAccess, false)
        XCTAssertEqual(player.reconciledAssets.last?.first?.allowsNetworkAccess, false)
    }

    func testStaleWebNetworkConfirmationCannotGrantTrustToNewRevision() throws {
        let store = LibraryStore(root: try makeTempDirectory())
        let old = WallpaperAsset(
            id: "web-network",
            title: "Old Web",
            kind: .web,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: "/library/web-network",
            entrypoint: "/library/web-network/index.html",
            thumbnail: nil,
            workshopId: nil,
            contentHash: "old-hash",
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .webLive),
            allowsNetworkAccess: false,
            redistributionAllowed: false,
            issues: []
        )
        let updated = WallpaperAsset(
            id: old.id,
            title: "Updated Web",
            kind: old.kind,
            supportStatus: old.supportStatus,
            source: old.source,
            projectDirectory: old.projectDirectory,
            entrypoint: old.entrypoint,
            thumbnail: nil,
            workshopId: nil,
            contentHash: "new-hash",
            compatibility: old.compatibility,
            compatibilityReport: old.compatibilityReport,
            allowsNetworkAccess: false,
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(old)
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            wallpaperPlayer: AssetReconcilingWallpaperPlayer(),
            userDefaults: try makeUserDefaults()
        )
        model.requestWebNetworkAccessChange(for: old)
        try store.replaceAsset(updated)

        model.confirmWebNetworkAccess()

        XCTAssertEqual(try store.load().assets.first?.contentHash, "new-hash")
        XCTAssertNotEqual(try store.load().assets.first?.allowsNetworkAccess, true)
        XCTAssertEqual(model.status, "This Web wallpaper changed. Review its network access again.")
    }

    func testSavingWebScalarPropertiesPersistsTypedValuesForTheCurrentRevision() async throws {
        let root = try makeTempDirectory()
        let project = root.appending(path: "web-properties")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let entrypoint = project.appending(path: "index.html")
        try "<html></html>".write(to: entrypoint, atomically: true, encoding: .utf8)
        try #"{"general":{"properties":{"enabled":{"type":"bool","value":true},"speed":{"type":"slider","value":1},"caption":{"type":"textinput","value":"Default"}}}}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        let asset = WallpaperAsset(
            id: "web-properties",
            title: "Web Properties",
            kind: .web,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            contentHash: "revision-a",
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .webLive),
            redistributionAllowed: false,
            issues: []
        )
        let store = LibraryStore(root: try makeTempDirectory())
        try store.replaceAsset(asset)
        let player = AssetReconcilingWallpaperPlayer()
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            wallpaperPlayer: player,
            userDefaults: try makeUserDefaults()
        )

        try await model.saveWebPropertyOverrides(
            [
                "enabled": .bool(false),
                "speed": .number(2.5),
                "caption": .text("Customized")
            ],
            for: asset
        )

        XCTAssertEqual(
            WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: project),
            [
                "enabled": .bool(false),
                "speed": .number(2.5),
                "caption": .text("Customized")
            ]
        )
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.status, "Saved 3 custom Web wallpaper properties.")
        XCTAssertEqual(player.webPropertyRefreshAssetIDs, [asset.id])

        try await model.saveWebPropertyOverrides(
            [
                "enabled": .bool(true),
                "speed": .number(1),
                "caption": .text("Default")
            ],
            for: asset
        )

        let resetOverrides = try await WebWallpaperUserFileStore.shared.loadValueOverrides(
            from: project
        )
        XCTAssertEqual(resetOverrides, [:])
        XCTAssertEqual(model.status, "Restored the Web wallpaper property defaults.")
        XCTAssertEqual(player.webPropertyRefreshAssetIDs, [asset.id, asset.id])
    }

    func testSavingWebScalarPropertiesRejectsAStaleAssetRevision() async throws {
        let project = try makeTempDirectory()
        let entrypoint = project.appending(path: "index.html")
        try "<html></html>".write(to: entrypoint, atomically: true, encoding: .utf8)
        let current = WallpaperAsset(
            id: "web-properties",
            title: "Current Web",
            kind: .web,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            contentHash: "current-revision",
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .webLive),
            redistributionAllowed: false,
            issues: []
        )
        let stale = WallpaperAsset(
            id: current.id,
            title: "Stale Web",
            kind: current.kind,
            supportStatus: current.supportStatus,
            source: current.source,
            projectDirectory: current.projectDirectory,
            entrypoint: current.entrypoint,
            thumbnail: nil,
            workshopId: nil,
            contentHash: "stale-revision",
            compatibility: current.compatibility,
            compatibilityReport: current.compatibilityReport,
            redistributionAllowed: false,
            issues: []
        )
        let store = LibraryStore(root: try makeTempDirectory())
        try store.replaceAsset(current)
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )

        do {
            try await model.saveWebPropertyOverrides(["enabled": .bool(false)], for: stale)
            XCTFail("Expected stale Web property editor rejection")
        } catch let error as WebWallpaperPropertyEditorError {
            XCTAssertEqual(error, .staleAsset)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: project
                    .appending(path: WebWallpaperUserFileStore.directoryName)
                    .appending(path: WebWallpaperUserFileStore.valueOverridesFileName)
                    .path
            )
        )
    }

    func testWorkshopUpdateQuiescesExistingRuntimeBeforeImporterMutation() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/AppViewModel.swift")
        let start = try XCTUnwrap(source.range(of: "func confirmWorkshopDownload()"))
        let end = try XCTUnwrap(
            source.range(of: "func commitWorkshopDownloadCompletion", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("downloadAndImport(input: input) {"))
        XCTAssertTrue(body.contains("prepareForLibraryReplacement(candidate)"))
        XCTAssertTrue(source.contains("await wallpaperPlayer.prepareForLibraryAssetReplacement(existing.id)"))
        XCTAssertTrue(source.contains("wallpaperPlayer.finishLibraryAssetReplacement(assetID)"))
        XCTAssertTrue(source.contains("await prepareForLibraryReplacement(asset)"))
        XCTAssertTrue(body.contains("catch is CancellationError"))
        XCTAssertGreaterThanOrEqual(body.components(separatedBy: "loadLibrary()").count - 1, 2)
    }

    func testStaleRuntimeSceneReportCannotOverwriteNewerWorkshopRevision() throws {
        let store = LibraryStore(root: try makeTempDirectory())
        let defaults = try makeUserDefaults()
        let old = WallpaperAsset(
            id: "scene-update",
            title: "Old Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .steamCMD,
            projectDirectory: "/library/scene-update",
            entrypoint: "/library/scene-update/old.pkg",
            thumbnail: nil,
            workshopId: "123",
            contentHash: "old-hash",
            compatibility: .live(),
            compatibilityReport: CompatibilityReport(
                level: .full,
                playbackPath: .nativeScene
            ),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(old)
        let model = AppViewModel(store: store, userDefaults: defaults)
        let newer = WallpaperAsset(
            id: old.id,
            title: "New Scene",
            kind: .scene,
            supportStatus: .playable,
            source: old.source,
            projectDirectory: old.projectDirectory,
            entrypoint: "/library/scene-update/new.payload",
            thumbnail: nil,
            workshopId: old.workshopId,
            dateAdded: old.dateAdded,
            contentHash: "new-hash",
            compatibility: .cached(reason: "Updated revision."),
            compatibilityReport: CompatibilityReport(
                level: .full,
                playbackPath: .renderedSceneCache
            ),
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(newer)

        model.handleSceneCompatibilityReport(
            asset: old,
            report: CompatibilityReport(level: .limited, playbackPath: .renderedSceneCache)
        )

        XCTAssertEqual(try store.load().assets.first, newer)
        XCTAssertEqual(model.libraryAssets.first, newer)

        // The old renderer callback may arrive again after the model has
        // already loaded the new revision. Its revision identity must still
        // be rejected before any manifest write.
        model.handleSceneCompatibilityReport(
            asset: old,
            report: CompatibilityReport(level: .unsupported, playbackPath: nil)
        )
        XCTAssertEqual(try store.load().assets.first, newer)
    }

    func testRuntimeSceneReportUpdatesSessionMetadataWithoutReconcilingEveryDisplay() throws {
        let store = LibraryStore(root: try makeTempDirectory())
        let report = CompatibilityReport(level: .full, playbackPath: .nativeScene)
        let asset = WallpaperAsset(
            id: "scene-report-isolation",
            title: "Scene Report Isolation",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: "/library/scene-report-isolation",
            entrypoint: "/library/scene-report-isolation/scene.pkg",
            thumbnail: nil,
            workshopId: nil,
            contentHash: "scene-report-revision",
            compatibility: report.supportMode,
            compatibilityReport: report,
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(asset)
        let player = AssetReconcilingWallpaperPlayer(
            singleDisplayUUIDs: ["primary", "secondary"]
        )
        let model = AppViewModel(
            store: store,
            wallpaperPlayer: player,
            userDefaults: try makeUserDefaults()
        )
        try player.play(
            asset: asset,
            autoPauseWhenCovered: true,
            displayMode: .fill,
            audioEnabled: false,
            audioVolume: 0
        )
        let reconcileCount = player.reconciledAssets.count
        let degraded = CompatibilityReport(
            level: .limited,
            playbackPath: .renderedSceneCache,
            missingCapabilities: [.sound],
            diagnosticCode: "scene_cache_playback_failed"
        )

        model.handleSceneCompatibilityReport(asset: asset, report: degraded)

        XCTAssertEqual(player.reconciledAssets.count, reconcileCount)
        XCTAssertEqual(player.metadataUpdatedAssetIDs.last, asset.id)
        XCTAssertEqual(Set(player.activeAppliedDisplaySessions.keys), ["primary", "secondary"])
        XCTAssertTrue(player.activeAppliedDisplaySessions.values.allSatisfy {
            $0.asset.compatibilityReport == degraded
        })
        XCTAssertEqual(try store.load().assets.first?.compatibilityReport, degraded)
        XCTAssertEqual(model.libraryAssets.first?.compatibilityReport, degraded)
    }

    func testCancelWorkshopDownloadUpdatesVisibleStateImmediately() throws {
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )

        model.cancelWorkshopDownload()

        XCTAssertEqual(model.workshopDownloadStatus.phase, .cancelled)
        XCTAssertEqual(model.workshopDownloadStatus.message, "Download cancelled.")
        XCTAssertEqual(model.status, "Workshop download cancelled.")
    }

    func testCancelWorkshopDownloadSynchronouslyCancelsStatusPolling() throws {
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        let polling = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(60))
        }
        model.installWorkshopStatusPollingTask(polling)

        model.cancelWorkshopDownload()

        XCTAssertTrue(polling.isCancelled)
        XCTAssertEqual(model.workshopDownloadStatus.phase, .cancelled)
    }

    func testCancelWorkshopDownloadDoesNotDispatchAnUnscopedLateXPCCancel() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/AppViewModel.swift")
        let start = try XCTUnwrap(source.range(of: "func cancelWorkshopDownload()"))
        let end = try XCTUnwrap(
            source.range(
                of: "func installWorkshopStatusPollingTask",
                range: start.lowerBound..<source.endIndex
            )
        )
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("workshopDownloadTask?.cancel()"))
        XCTAssertFalse(body.contains("WorkshopDownloadService(store: store)"))
        XCTAssertFalse(body.contains("Task {"))
    }

    func testCancelledMainActorTaskCannotCommitWorkshopCompletedState() async throws {
        let sourceRoot = try makeTempDirectory()
        let source = try makeScannedProject(
            root: sourceRoot,
            id: "cancelled-workshop-completion",
            title: "Cancelled Workshop"
        )
        let store = LibraryStore(root: try makeTempDirectory())
        let imported = try store.importAsset(source)
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.cancelWorkshopDownload()
        let gate = CancellationRaceGate()
        let completion = Task { @MainActor () -> Error? in
            await gate.wait()
            do {
                try model.commitWorkshopDownloadCompletion(imported)
                return nil
            } catch {
                return error
            }
        }
        while !(await gate.hasWaiter()) {
            await Task.yield()
        }

        completion.cancel()
        await gate.release()
        let error = await completion.value

        guard case WorkshopDownloadServiceError.cancelledAfterImport(let preserved)? = error else {
            return XCTFail("A post-service cancellation must prevent the Completed state")
        }
        XCTAssertEqual(preserved.id, imported.id)
        XCTAssertEqual(model.workshopDownloadStatus.phase, .cancelled)
        XCTAssertNotEqual(model.workshopDownloadStatus.phase, .completed)
    }

    func testImportSelectedImportsMultipleScannedAssets() async throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let first = try makeScannedProject(root: sourceRoot, id: "first", title: "First Loop")
        let second = try makeScannedProject(root: sourceRoot, id: "second", title: "Second Loop")
        let store = LibraryStore(root: try makeTempDirectory())
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.scannedAssets = [first, second]
        model.selectScannedAssets([first.id, second.id])

        // When (import runs off the main thread; await its completion)
        await model.importSelected().value
        let manifest = try store.load()

        // Then the working/progress state is cleared once the import finishes.
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.importProgress)

        // Then
        XCTAssertEqual(Set(manifest.assets.map(\.id)), [first.id, second.id])
        XCTAssertEqual(model.selectedLibraryAssetIds, [first.id, second.id])
        XCTAssertEqual(model.status, "Imported 2 projects.")
        for asset in manifest.assets {
            XCTAssertTrue(FileManager.default.fileExists(atPath: asset.projectDirectory))
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(asset.entrypoint)))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.projectDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.projectDirectory))
    }

    func testScannedWorkshopUpdateQuiescesRuntimeBeforeReplacingLibraryCopy() async throws {
        let store = LibraryStore(root: try makeTempDirectory())
        let oldSourceRoot = try makeTempDirectory()
        let oldCandidate = try makeScannedProject(
            root: oldSourceRoot,
            id: "123456",
            title: "Old Workshop"
        )
        let existing = try store.importAsset(oldCandidate)
        let newSourceRoot = try makeTempDirectory()
        let newCandidate = try makeScannedProject(
            root: newSourceRoot,
            id: "123456",
            title: "Updated Workshop"
        )
        try Data([2]).write(to: URL(filePath: try XCTUnwrap(newCandidate.entrypoint)))
        let player = AssetReconcilingWallpaperPlayer()
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            wallpaperPlayer: player,
            userDefaults: try makeUserDefaults()
        )
        model.scannedAssets = [newCandidate]
        model.selectedScannedAssetId = newCandidate.id

        await model.importSelected().value

        XCTAssertEqual(player.preparedReplacementAssetIDs, [existing.id])
        XCTAssertEqual(player.finishedReplacementAssetIDs, [existing.id])
        XCTAssertEqual(try store.load().assets.first?.title, "Updated Workshop")
    }

    func testScannedManualSameIDUpdateAlsoQuiescesRuntimeBeforeReplacement() async throws {
        let store = LibraryStore(root: try makeTempDirectory())
        let oldCandidate = try makeScannedProject(
            root: try makeTempDirectory(),
            id: "manual-scene",
            title: "Old Manual Asset"
        )
        let existing = try store.importAsset(oldCandidate)
        let newCandidate = try makeScannedProject(
            root: try makeTempDirectory(),
            id: "manual-scene",
            title: "Updated Manual Asset"
        )
        try Data([3]).write(to: URL(filePath: try XCTUnwrap(newCandidate.entrypoint)))
        let player = AssetReconcilingWallpaperPlayer()
        let lockScreen = MockLockScreenAnimationController()
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            wallpaperPlayer: player,
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = existing.id
        model.lockScreenAnimationEnabled = true
        model.playSelected()
        model.scannedAssets = [newCandidate]
        model.selectedScannedAssetId = newCandidate.id
        player.prepareHandler = { assetID in
            XCTAssertEqual(assetID, existing.id)
            XCTAssertNil(
                lockScreen.updatedAssetIds.last ?? nil,
                "The saver must release the old project before its directory is replaced."
            )
        }

        await model.importSelected().value

        XCTAssertNil(newCandidate.workshopId)
        XCTAssertEqual(player.preparedReplacementAssetIDs, [existing.id])
        XCTAssertEqual(player.finishedReplacementAssetIDs, [existing.id])
        XCTAssertEqual(try store.load().assets.first?.title, "Updated Manual Asset")
        XCTAssertEqual(lockScreen.updatedAssetIds.last, existing.id)
    }

    func testStoppedWallpaperSaverIsClearedBeforeSameIDLibraryReplacement() async throws {
        let store = LibraryStore(root: try makeTempDirectory())
        let oldCandidate = try makeScannedProject(
            root: try makeTempDirectory(),
            id: "stopped-replacement",
            title: "Stopped Old Revision"
        )
        let existing = try store.importAsset(oldCandidate)
        let newCandidate = try makeScannedProject(
            root: try makeTempDirectory(),
            id: existing.id,
            title: "Stopped New Revision"
        )
        let player = AssetReconcilingWallpaperPlayer()
        let lockScreen = MockLockScreenAnimationController()
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            wallpaperPlayer: player,
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = existing.id
        model.lockScreenAnimationEnabled = true
        model.playSelected()
        model.stopPlayback()
        XCTAssertEqual(lockScreen.updatedAssetIds.last, existing.id)
        player.prepareHandler = { _ in
            XCTAssertNil(lockScreen.updatedAssetIds.last ?? nil)
        }
        model.scannedAssets = [newCandidate]
        model.selectedScannedAssetId = newCandidate.id

        await model.importSelected().value

        XCTAssertNil(lockScreen.updatedAssetIds.last ?? nil)
        XCTAssertEqual(try store.load().assets.first?.title, "Stopped New Revision")
    }

    func testImportingUnrelatedWallpaperPreservesStoppedWallpaperSaver() async throws {
        let store = LibraryStore(root: try makeTempDirectory())
        let stopped = try store.importAsset(makeScannedProject(
            root: try makeTempDirectory(),
            id: "stopped-saver",
            title: "Stopped Saver"
        ))
        let unrelated = try makeScannedProject(
            root: try makeTempDirectory(),
            id: "unrelated-import",
            title: "Unrelated Import"
        )
        let lockScreen = MockLockScreenAnimationController()
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            wallpaperPlayer: AssetReconcilingWallpaperPlayer(),
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = stopped.id
        model.lockScreenAnimationEnabled = true
        model.playSelected()
        model.stopPlayback()
        let updateCount = lockScreen.updatedAssetIds.count
        model.scannedAssets = [unrelated]
        model.selectedScannedAssetId = unrelated.id

        await model.importSelected().value

        XCTAssertEqual(lockScreen.updatedAssetIds.count, updateCount)
        XCTAssertEqual(lockScreen.updatedAssetIds.last, stopped.id)
    }

    func testReplacingUnrelatedWallpaperPreservesStoppedWallpaperSaver() async throws {
        let store = LibraryStore(root: try makeTempDirectory())
        let stopped = try store.importAsset(makeScannedProject(
            root: try makeTempDirectory(),
            id: "stopped-saver",
            title: "Stopped Saver"
        ))
        let existing = try store.importAsset(makeScannedProject(
            root: try makeTempDirectory(),
            id: "unrelated-replacement",
            title: "Old Unrelated"
        ))
        let replacement = try makeScannedProject(
            root: try makeTempDirectory(),
            id: existing.id,
            title: "New Unrelated"
        )
        let lockScreen = MockLockScreenAnimationController()
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            wallpaperPlayer: AssetReconcilingWallpaperPlayer(),
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = stopped.id
        model.lockScreenAnimationEnabled = true
        model.playSelected()
        model.stopPlayback()
        let updateCount = lockScreen.updatedAssetIds.count
        model.scannedAssets = [replacement]
        model.selectedScannedAssetId = replacement.id

        await model.importSelected().value

        XCTAssertEqual(lockScreen.updatedAssetIds.count, updateCount)
        XCTAssertEqual(lockScreen.updatedAssetIds.last, stopped.id)
        XCTAssertEqual(try store.load().assets.first(where: { $0.id == existing.id })?.title, "New Unrelated")
    }

    func testSceneVideoRenderCompletionBumpsRevisionSoLibraryRowsRefresh() throws {
        // Given
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        let sceneRoot = try makeTempDirectory()
        let entrypoint = sceneRoot.appending(path: "scene.pkg")
        try Data([1]).write(to: entrypoint)
        let scene = WallpaperAsset(
            id: "scene-1",
            title: "Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .localSteamWorkshop,
            projectDirectory: sceneRoot.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
        model.libraryAssets = [scene]

        // Then (before any render, the row shows the "renders on first play"
        // badge because there's no cached video yet)
        XCTAssertEqual(LibraryRowStatusResolver.status(for: scene), .live)
        let revisionBeforeRender = model.sceneVideoRenderRevision

        // When a render completes and lands a fresh cache entry
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        let cacheDirectory = sceneRoot.appending(path: "SceneVideoCache")
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        addTeardownBlock {
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }
        let renderedVideo = sceneRoot.appending(path: "rendered.mp4")
        try Data([1]).write(to: renderedVideo)
        _ = try SceneVideoCache.install(
            videoAt: renderedVideo,
            audioResult: .notRequired,
            at: SceneVideoCache.cachedVideoURL(assetId: scene.id)
        )
        model.handleSceneVideoRenderCompletion(assetId: scene.id)

        // Then
        XCTAssertEqual(model.sceneVideoRenderRevision, revisionBeforeRender + 1)
        XCTAssertEqual(LibraryRowStatusResolver.status(for: scene), .cached)
    }

    func testClearingSceneCacheRefreshesEnabledScreenSaverConfiguration() async throws {
        let sceneRoot = try makeTempDirectory()
        let entrypoint = sceneRoot.appending(path: "scene.pkg")
        try Data([1]).write(to: entrypoint)
        let scene = WallpaperAsset(
            id: "scene-cache-clear",
            title: "Scene Cache Clear",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: sceneRoot.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            contentHash: "scene-cache-clear-hash",
            redistributionAllowed: false,
            issues: []
        )
        let store = LibraryStore(root: try makeTempDirectory())
        try store.replaceAsset(scene)
        let lockScreen = MockLockScreenAnimationController()
        let player = AssetReconcilingWallpaperPlayer()
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            wallpaperPlayer: player,
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = scene.id
        model.lockScreenAnimationEnabled = true
        model.playSelected()
        let updateCount = lockScreen.updatedAssetIds.count

        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        let cacheDirectory = sceneRoot.appending(path: "SceneVideoCache")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: cacheDirectory.appending(path: "cached.mp4"))
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }

        let firstClear = model.clearSceneCache()
        let overlappingClear = model.clearSceneCache()
        await firstClear.value
        await overlappingClear.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDirectory.path))
        XCTAssertEqual(player.preparedReplacementAssetIDs, [scene.id])
        XCTAssertEqual(player.finishedReplacementAssetIDs, [scene.id])
        XCTAssertEqual(lockScreen.updatedAssetIds.count, updateCount + 1)
        XCTAssertEqual(lockScreen.updatedAssetIds.last, scene.id)
        XCTAssertFalse(model.isWorking)
    }

    func testStaleSceneRenderCompletionDoesNotReplaceNewerLockScreenAsset() throws {
        let store = LibraryStore(root: try makeTempDirectory())
        let firstRoot = try makeTempDirectory()
        let secondRoot = try makeTempDirectory()
        let firstEntry = firstRoot.appending(path: "scene.pkg")
        let secondEntry = secondRoot.appending(path: "scene.pkg")
        try Data([1]).write(to: firstEntry)
        try Data([2]).write(to: secondEntry)
        let first = WallpaperAsset(
            id: "scene-a",
            title: "Scene A",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: firstRoot.path,
            entrypoint: firstEntry.path,
            thumbnail: nil,
            workshopId: nil,
            contentHash: "hash-a",
            redistributionAllowed: false,
            issues: []
        )
        let second = WallpaperAsset(
            id: "scene-b",
            title: "Scene B",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: secondRoot.path,
            entrypoint: secondEntry.path,
            thumbnail: nil,
            workshopId: nil,
            contentHash: "hash-b",
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(first)
        try store.replaceAsset(second)
        let lockScreen = MockLockScreenAnimationController()
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            wallpaperPlayer: AssetReconcilingWallpaperPlayer(),
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = first.id
        model.lockScreenAnimationEnabled = true
        model.playSelected()
        model.selectedLibraryAssetId = second.id
        model.playSelected()
        let updateCountAfterPlayingSecond = lockScreen.updatedAssetIds.count

        model.handleSceneVideoRenderCompletion(assetId: first.id)

        XCTAssertEqual(lockScreen.updatedAssetIds.count, updateCountAfterPlayingSecond)
        XCTAssertEqual(lockScreen.updatedAssetIds.last, second.id)
    }

    func testApplyingDisplayAssignmentsUpdatesScreenSaverFromPrimaryDisplay() throws {
        let sourceRoot = try makeTempDirectory()
        let primaryAsset = try makeScannedProject(
            root: sourceRoot,
            id: "primary-wallpaper",
            title: "Primary Wallpaper"
        )
        let selectedAsset = try makeScannedProject(
            root: sourceRoot,
            id: "selected-wallpaper",
            title: "Selected Wallpaper"
        )
        let store = LibraryStore(root: try makeTempDirectory())
        try store.replaceAsset(primaryAsset)
        try store.replaceAsset(selectedAsset)
        let lockScreen = MockLockScreenAnimationController()
        let displaySessions = MockDisplaySessionCoordinator()
        let player = AssetReconcilingWallpaperPlayer()
        let displays = [
            ConnectedDisplay(
                id: "primary-display",
                name: "Primary Display",
                resolution: CGSize(width: 2_560, height: 1_440),
                isPrimary: true
            ),
            ConnectedDisplay(
                id: "secondary-display",
                name: "Secondary Display",
                resolution: CGSize(width: 1_920, height: 1_080),
                isPrimary: false
            )
        ]
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            wallpaperPlayer: player,
            displaySessionCoordinator: displaySessions,
            connectedDisplayProvider: { displays },
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = selectedAsset.id
        model.displayMode = .fill
        model.lockScreenAnimationEnabled = true
        model.updateDisplayAssignment(
            displayUUID: displays[0].id,
            assetID: primaryAsset.id,
            displayMode: .fit
        )
        model.updateDisplayAssignment(
            displayUUID: displays[1].id,
            assetID: selectedAsset.id,
            displayMode: .stretch
        )
        player.activeAppliedDisplaySessions[displays[0].id] = .init(
            assignment: DisplayAssignment(
                displayUUID: displays[0].id,
                assetID: primaryAsset.id,
                displayMode: .fit
            ),
            asset: primaryAsset
        )
        player.activeAppliedDisplaySessions[displays[1].id] = .init(
            assignment: DisplayAssignment(
                displayUUID: displays[1].id,
                assetID: selectedAsset.id,
                displayMode: .stretch
            ),
            asset: selectedAsset
        )

        model.applyDisplayAssignments()

        XCTAssertEqual(displaySessions.applyCallCount, 1)
        XCTAssertEqual(lockScreen.updatedAssetIds, [nil, primaryAsset.id])
        XCTAssertEqual(lockScreen.updatedDisplayModes, [.fill, .fit])
    }

    func testFailedPrimaryDisplayReplacementKeepsScreenSaverOnAppliedFallback() throws {
        let sourceRoot = try makeTempDirectory()
        let appliedAsset = try makeScannedProject(
            root: sourceRoot,
            id: "applied-wallpaper",
            title: "Applied Wallpaper"
        )
        let desiredAsset = try makeScannedProject(
            root: sourceRoot,
            id: "desired-wallpaper",
            title: "Desired Wallpaper"
        )
        let store = LibraryStore(root: try makeTempDirectory())
        try store.replaceAsset(appliedAsset)
        try store.replaceAsset(desiredAsset)
        let lockScreen = MockLockScreenAnimationController()
        let displaySessions = MockDisplaySessionCoordinator(
            failures: [DisplayPlaybackFailure(
                displayUUID: "primary-display",
                message: "Replacement failed."
            )]
        )
        let player = AssetReconcilingWallpaperPlayer()
        let appliedAssignment = DisplayAssignment(
            displayUUID: "primary-display",
            assetID: appliedAsset.id,
            displayMode: .fit
        )
        player.activeAppliedDisplaySessions["primary-display"] = .init(
            assignment: appliedAssignment,
            asset: appliedAsset
        )
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            wallpaperPlayer: player,
            displaySessionCoordinator: displaySessions,
            connectedDisplayProvider: {
                [ConnectedDisplay(
                    id: "primary-display",
                    name: "Primary Display",
                    resolution: CGSize(width: 2_560, height: 1_440),
                    isPrimary: true
                )]
            },
            userDefaults: try makeUserDefaults()
        )
        model.lockScreenAnimationEnabled = true
        model.updateDisplayAssignment(
            displayUUID: "primary-display",
            assetID: desiredAsset.id,
            displayMode: .stretch
        )

        model.applyDisplayAssignments()

        XCTAssertEqual(lockScreen.updatedAssetIds.last, appliedAsset.id)
        XCTAssertEqual(lockScreen.updatedDisplayModes.last, .fit)
        XCTAssertTrue(model.status.contains("1 display(s) failed"))
    }

    func testFailedSameIDDisplayReplacementRejectsStaleAppliedSaverRevision() throws {
        let oldAsset = try makeScannedProject(
            root: try makeTempDirectory(),
            id: "shared-wallpaper-id",
            title: "Old Applied Revision"
        )
        let newAsset = try makeScannedProject(
            root: try makeTempDirectory(),
            id: oldAsset.id,
            title: "New Desired Revision"
        )
        let store = LibraryStore(root: try makeTempDirectory())
        try store.replaceAsset(newAsset)
        let lockScreen = MockLockScreenAnimationController()
        let player = AssetReconcilingWallpaperPlayer()
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            wallpaperPlayer: player,
            displaySessionCoordinator: MockDisplaySessionCoordinator(
                failures: [DisplayPlaybackFailure(
                    displayUUID: "primary-display",
                    message: "New revision failed."
                )]
            ),
            connectedDisplayProvider: {
                [ConnectedDisplay(
                    id: "primary-display",
                    name: "Primary Display",
                    resolution: CGSize(width: 2_560, height: 1_440),
                    isPrimary: true
                )]
            },
            userDefaults: try makeUserDefaults()
        )
        player.activeAppliedDisplaySessions["primary-display"] = .init(
            assignment: DisplayAssignment(
                displayUUID: "primary-display",
                assetID: oldAsset.id,
                displayMode: .fit
            ),
            asset: oldAsset
        )
        model.lockScreenAnimationEnabled = true
        model.updateDisplayAssignment(
            displayUUID: "primary-display",
            assetID: newAsset.id,
            displayMode: .stretch
        )

        model.applyDisplayAssignments()

        XCTAssertNil(lockScreen.updatedAssetIds.last ?? nil)
        XCTAssertNil(lockScreen.updatedEntrypoints.last ?? nil)
    }

    func testFailedSingleReplacementKeepsSaverOnAppliedPrimarySession() throws {
        let sourceRoot = try makeTempDirectory()
        let oldAsset = try makeScannedProject(
            root: sourceRoot,
            id: "old-single-wallpaper",
            title: "Old Single Wallpaper"
        )
        let newAsset = try makeScannedProject(
            root: sourceRoot,
            id: "new-single-wallpaper",
            title: "New Single Wallpaper"
        )
        let store = LibraryStore(root: try makeTempDirectory())
        try store.replaceAsset(oldAsset)
        try store.replaceAsset(newAsset)
        let lockScreen = MockLockScreenAnimationController()
        let player = AssetReconcilingWallpaperPlayer(singleDisplayUUIDs: ["primary-display"])
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            wallpaperPlayer: player,
            connectedDisplayProvider: {
                [ConnectedDisplay(
                    id: "primary-display",
                    name: "Primary Display",
                    resolution: CGSize(width: 2_560, height: 1_440),
                    isPrimary: true
                )]
            },
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = oldAsset.id
        model.lockScreenAnimationEnabled = true
        model.playSelected()
        XCTAssertEqual(lockScreen.updatedEntrypoints.last, oldAsset.entrypoint)

        player.playError = TestError.expected
        model.selectedLibraryAssetId = newAsset.id
        model.playSelected()

        XCTAssertEqual(lockScreen.updatedAssetIds.last, oldAsset.id)
        XCTAssertEqual(lockScreen.updatedEntrypoints.last, oldAsset.entrypoint)

        model.displayMode = .stretch

        XCTAssertEqual(lockScreen.updatedAssetIds.last, oldAsset.id)
        XCTAssertEqual(lockScreen.updatedEntrypoints.last, oldAsset.entrypoint)
        XCTAssertEqual(lockScreen.updatedDisplayModes.last, .stretch)
    }

    func testLibrarySelectionCannotReplaceTheActiveSingleWallpaperScreenSaver() throws {
        let sourceRoot = try makeTempDirectory()
        let playing = try makeScannedProject(
            root: sourceRoot,
            id: "playing-wallpaper",
            title: "Playing Wallpaper"
        )
        let selected = try makeScannedProject(
            root: sourceRoot,
            id: "selected-only-wallpaper",
            title: "Selected Only Wallpaper"
        )
        let store = LibraryStore(root: try makeTempDirectory())
        try store.replaceAsset(playing)
        try store.replaceAsset(selected)
        let lockScreen = MockLockScreenAnimationController()
        let model = AppViewModel(
            store: store,
            lockScreenAnimationController: lockScreen,
            wallpaperPlayer: AssetReconcilingWallpaperPlayer(),
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = playing.id
        model.lockScreenAnimationEnabled = true
        model.playSelected()

        model.selectedLibraryAssetId = selected.id
        model.displayMode = .fill
        model.lockScreenAnimationEnabled = false
        model.lockScreenAnimationEnabled = true

        XCTAssertEqual(
            Array(lockScreen.updatedAssetIds.suffix(3)),
            [playing.id, playing.id, playing.id] as [String?]
        )
        XCTAssertFalse(lockScreen.updatedAssetIds.suffix(3).contains(selected.id))
    }

    func testFailedSinglePlaybackUsesThePlaybackOwnersSurvivingAssignmentState() throws {
        let sourceRoot = try makeTempDirectory()
        let primaryAsset = try makeScannedProject(
            root: sourceRoot,
            id: "primary-wallpaper",
            title: "Primary Wallpaper"
        )
        let selectedAsset = try makeScannedProject(
            root: sourceRoot,
            id: "selected-wallpaper",
            title: "Selected Wallpaper"
        )
        let store = LibraryStore(root: try makeTempDirectory())
        try store.replaceAsset(primaryAsset)
        try store.replaceAsset(selectedAsset)
        let lockScreen = MockLockScreenAnimationController()
        let player = FailingWallpaperPlayer()
        let displaySessions = MockDisplaySessionCoordinator()
        let displays = [
            ConnectedDisplay(
                id: "primary-display",
                name: "Primary Display",
                resolution: CGSize(width: 2_560, height: 1_440),
                isPrimary: true
            )
        ]
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            wallpaperPlayer: player,
            displaySessionCoordinator: displaySessions,
            connectedDisplayProvider: { displays },
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = selectedAsset.id
        model.lockScreenAnimationEnabled = true
        model.updateDisplayAssignment(
            displayUUID: displays[0].id,
            assetID: primaryAsset.id,
            displayMode: .fit
        )
        player.activeAppliedDisplaySessions[displays[0].id] = .init(
            assignment: DisplayAssignment(
                displayUUID: displays[0].id,
                assetID: primaryAsset.id,
                displayMode: .fit
            ),
            asset: primaryAsset
        )
        model.applyDisplayAssignments()
        XCTAssertEqual(lockScreen.updatedAssetIds.last, primaryAsset.id)

        player.hasActiveDisplayAssignments = true
        model.playSelected()
        XCTAssertEqual(model.status, "playback failed")
        model.displayMode = .stretch

        XCTAssertEqual(lockScreen.updatedAssetIds.last, primaryAsset.id)
        XCTAssertEqual(lockScreen.updatedDisplayModes.last, .fit)

        player.hasActiveDisplayAssignments = false
        player.activeAppliedDisplaySessions = [:]
        model.playSelected()
        XCTAssertEqual(model.status, "playback failed")
        model.displayMode = .fill

        XCTAssertTrue(lockScreen.updatedAssetIds.last == .some(nil))
        XCTAssertEqual(lockScreen.updatedDisplayModes.last, .fill)
    }

    func testSelectScannedAssetsIgnoresMissingIds() throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let asset = try makeScannedProject(root: sourceRoot, id: "one", title: "One")
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.scannedAssets = [asset]

        // When
        model.selectScannedAssets([asset.id, "missing"])

        // Then
        XCTAssertEqual(model.selectedScannedAssetIds, [asset.id])
        XCTAssertEqual(model.selectedScannedAssetId, asset.id)
    }

    func testImportSelectedDoesNotStartWhileLibraryOperationIsRunning() async throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let asset = try makeScannedProject(root: sourceRoot, id: "one", title: "One")
        let store = LibraryStore(root: try makeTempDirectory())
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.scannedAssets = [asset]
        model.selectScannedAssets([asset.id])
        model.isWorking = true

        // When
        await model.importSelected().value
        let manifest = try store.load()

        // Then
        XCTAssertTrue(manifest.assets.isEmpty)
        XCTAssertEqual(model.status, "Finish the current library operation first.")
        XCTAssertNil(model.importProgress)
    }

    func testScanSourceSortsByDateAddedByDefaultAndCanSortByName() async throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let older = try makeScannedProject(root: sourceRoot, id: "100", title: "Alpha")
        let newer = try makeScannedProject(root: sourceRoot, id: "200", title: "Beta")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: older.projectDirectory
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_086_400)],
            ofItemAtPath: newer.projectDirectory
        )
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.sourcePath = sourceRoot.path

        // When
        await model.scanSource().value

        // Then
        XCTAssertEqual(model.scannedAssets.map(\.id), ["200", "100"])
        XCTAssertEqual(model.selectedScannedAssetId, "200")

        // When
        model.scannedSortOrder = .name

        // Then
        XCTAssertEqual(model.scannedAssets.map(\.id), ["100", "200"])
    }

    func testNewScannedAssetUsesLastImportBaseline() throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let old = try makeScannedProject(
            root: sourceRoot,
            id: "old",
            title: "Old",
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let fresh = try makeScannedProject(
            root: sourceRoot,
            id: "fresh",
            title: "Fresh",
            dateAdded: Date(timeIntervalSince1970: 1_700_010_000)
        )
        let defaults = try makeUserDefaults()
        defaults.set(Date(timeIntervalSince1970: 1_700_005_000), forKey: "lastImportAt")
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // Then
        XCTAssertFalse(model.isNewScannedAsset(old))
        XCTAssertTrue(model.isNewScannedAsset(fresh))
    }

    func testInitSelectsFirstLibraryAssetWhenAvailable() throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let video = sourceRoot.appending(path: "clip.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try makeTempDirectory())
        let imported = try store.importVideoFile(video)

        // When
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )

        // Then
        XCTAssertEqual(model.selectedLibraryAssetId, imported.id)
        XCTAssertEqual(model.selectedLibraryAsset, imported)
    }

    func testImportVideoFileDoesNotStartWhileLibraryOperationIsRunning() async throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let video = sourceRoot.appending(path: "clip.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try makeTempDirectory())
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.isWorking = true

        // When
        await model.importVideoFile(video).value
        let manifest = try store.load()

        // Then
        XCTAssertTrue(manifest.assets.isEmpty)
        XCTAssertEqual(model.status, "Finish the current library operation first.")
    }

    func testLegacyMigrationDoesNotStartWhileLibraryOperationIsRunning() throws {
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.isWorking = true

        model.confirmLegacyMigration()

        XCTAssertTrue(model.isWorking)
        XCTAssertEqual(model.status, "Finish the current library operation first.")
    }

    func testImportWallpaperFileAddsGIFThroughContentBasedPickerPath() async throws {
        let sourceRoot = try makeTempDirectory()
        let gif = sourceRoot.appending(path: "loop.gif")
        try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        ).write(to: gif)
        let store = LibraryStore(root: try makeTempDirectory())
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )

        await model.importWallpaperFile(gif).value

        let imported = try XCTUnwrap(try store.load().assets.first)
        XCTAssertEqual(imported.kind, .image)
        XCTAssertEqual(imported.supportStatus, .playable)
        XCTAssertEqual(model.selectedLibraryAssetId, imported.id)
        XCTAssertEqual(model.status, "Added loop.")
    }

    func testWallpaperFilePickerUsesContentProbeInsteadOfExtensionAllowlist() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/AppViewModel.swift")

        XCTAssertTrue(source.contains("panel.allowedContentTypes = [.item]"))
        XCTAssertTrue(source.contains("importWallpaperFile(url)"))
        XCTAssertFalse(source.contains("private static let videoContentTypes"))
    }

    func testDisplayTopologyChangeRefreshesConnectedDisplaysAndPersistsNewSession() throws {
        let primary = ConnectedDisplay(
            id: "primary",
            name: "Primary",
            resolution: CGSize(width: 2560, height: 1440),
            isPrimary: true
        )
        let secondary = ConnectedDisplay(
            id: "secondary",
            name: "Secondary",
            resolution: CGSize(width: 1920, height: 1080),
            isPrimary: false
        )
        let provider = MutableDisplayProvider(displays: [primary])
        let store = LibraryStore(root: try makeTempDirectory())
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            connectedDisplayProvider: { provider.displays },
            userDefaults: try makeUserDefaults()
        )
        XCTAssertEqual(model.connectedDisplays.map(\.id), ["primary"])

        provider.displays = [primary, secondary]
        model.handleDisplayTopologyChange()

        XCTAssertEqual(model.connectedDisplays.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(try store.load().displayAssignments.map(\.displayUUID), ["primary", "secondary"])
    }

    func testRemoveSelectedLibraryAssetDeletesImportedCopy() async throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let video = sourceRoot.appending(path: "clip.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try makeTempDirectory())
        let imported = try store.importVideoFile(video)
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = imported.id

        // When
        await model.removeSelectedLibraryAsset().value
        let manifest = try store.load()

        // Then
        XCTAssertTrue(model.libraryAssets.isEmpty)
        XCTAssertNil(model.selectedLibraryAssetId)
        XCTAssertTrue(manifest.assets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.projectDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testRemoveSelectedLibraryAssetDoesNotRunWhileLibraryOperationIsRunning() async throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let video = sourceRoot.appending(path: "clip.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try makeTempDirectory())
        let imported = try store.importVideoFile(video)
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = imported.id
        model.isWorking = true

        // When
        await model.removeSelectedLibraryAsset().value
        let manifest = try store.load()

        // Then
        XCTAssertEqual(manifest.assets, [imported])
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
        XCTAssertEqual(model.status, "Finish the current library operation first.")
    }

    func testRemoveSelectedLibraryAssetQuiescesRuntimeBeforeStoreMutationAndFinishesAfterReload() async throws {
        let sourceRoot = try makeTempDirectory()
        let video = sourceRoot.appending(path: "active-removal.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try makeTempDirectory())
        let imported = try store.importVideoFile(video)
        let player = AssetReconcilingWallpaperPlayer()
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            wallpaperPlayer: player,
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = imported.id

        var events: [String] = []
        player.prepareHandler = { assetID in
            XCTAssertEqual(assetID, imported.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
            events.append("prepare")
        }
        player.reconcileHandler = { assets in
            guard assets.isEmpty else { return }
            XCTAssertFalse(FileManager.default.fileExists(atPath: imported.projectDirectory))
            events.append("reload")
        }
        player.finishHandler = { assetID in
            XCTAssertEqual(assetID, imported.id)
            events.append("finish")
        }

        await model.removeSelectedLibraryAsset().value

        XCTAssertEqual(events, ["prepare", "reload", "finish"])
        XCTAssertEqual(player.preparedReplacementAssetIDs, [imported.id])
        XCTAssertEqual(player.finishedReplacementAssetIDs, [imported.id])
        XCTAssertTrue(try store.load().assets.isEmpty)
    }

    func testRemovingActiveWallpaperClearsSaverAndSameIDCannotResurrectIt() async throws {
        let sourceRoot = try makeTempDirectory()
        let video = sourceRoot.appending(path: "active-removal.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try makeTempDirectory())
        let imported = try store.importVideoFile(video)
        let player = AssetReconcilingWallpaperPlayer()
        let lockScreen = MockLockScreenAnimationController()
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            wallpaperPlayer: player,
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = imported.id
        model.lockScreenAnimationEnabled = true
        model.playSelected()
        XCTAssertEqual(lockScreen.updatedAssetIds.last, imported.id)

        await model.removeSelectedLibraryAsset().value

        XCTAssertNil(lockScreen.updatedAssetIds.last ?? nil)
        XCTAssertNil(player.activeAssetID)
        let updateCountAfterRemoval = lockScreen.updatedAssetIds.count

        let replacement = try makeScannedProject(
            root: try makeTempDirectory(),
            id: imported.id,
            title: "Replacement With Reused ID"
        )
        try store.replaceAsset(replacement)
        model.loadLibrary()
        model.handleSceneVideoRenderCompletion(assetId: replacement.id)

        XCTAssertEqual(lockScreen.updatedAssetIds.count, updateCountAfterRemoval)
        XCTAssertNil(lockScreen.updatedAssetIds.last ?? nil)
    }

    func testRemovingStoppedWallpaperClearsPersistedSaverBeforeStoreMutation() async throws {
        let sourceRoot = try makeTempDirectory()
        let video = sourceRoot.appending(path: "stopped-removal.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try makeTempDirectory())
        let imported = try store.importVideoFile(video)
        let player = AssetReconcilingWallpaperPlayer()
        let lockScreen = MockLockScreenAnimationController()
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            wallpaperPlayer: player,
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = imported.id
        model.lockScreenAnimationEnabled = true
        model.playSelected()
        model.stopPlayback()
        XCTAssertEqual(lockScreen.updatedAssetIds.last, imported.id)
        player.prepareHandler = { _ in
            XCTAssertNil(lockScreen.updatedAssetIds.last ?? nil)
        }

        await model.removeSelectedLibraryAsset().value

        XCTAssertNil(lockScreen.updatedAssetIds.last ?? nil)
        XCTAssertTrue(try store.load().assets.isEmpty)
    }

    func testPartialMultiRemovalReconcilesSaverAfterActiveFirstAssetWasRemoved() async throws {
        let trasher = SelectiveFailingAssetTrasher()
        let store = LibraryStore(root: try makeTempDirectory(), trasher: trasher)
        let active = try store.importAsset(makeScannedProject(
            root: try makeTempDirectory(),
            id: "a-active-removal",
            title: "Active Removal"
        ))
        let failing = try store.importAsset(makeScannedProject(
            root: try makeTempDirectory(),
            id: "z-failing-removal",
            title: "Failing Removal"
        ))
        trasher.fail(directoryNamed: URL(filePath: failing.projectDirectory).lastPathComponent)
        let player = AssetReconcilingWallpaperPlayer()
        let lockScreen = MockLockScreenAnimationController()
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            wallpaperPlayer: player,
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = active.id
        model.lockScreenAnimationEnabled = true
        model.playSelected()
        model.selectLibraryAssets([active.id, failing.id])

        await model.removeSelectedLibraryAssets().value

        XCTAssertEqual(try store.load().assets.map(\.id), [failing.id])
        XCTAssertNil(player.activeAssetID)
        XCTAssertNil(lockScreen.updatedAssetIds.last ?? nil)
        XCTAssertTrue(model.status.lowercased().contains("permission"))
    }

    func testRemoveSelectedLibraryAssetsDeletesMultipleImportedCopies() async throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let firstVideo = sourceRoot.appending(path: "first.mp4")
        let secondVideo = sourceRoot.appending(path: "second.mp4")
        FileManager.default.createFile(atPath: firstVideo.path, contents: Data([1]))
        FileManager.default.createFile(atPath: secondVideo.path, contents: Data([2]))
        let store = LibraryStore(root: try makeTempDirectory())
        let first = try store.importVideoFile(firstVideo)
        let second = try store.importVideoFile(secondVideo)
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.selectLibraryAssets([first.id, second.id])

        // When
        await model.removeSelectedLibraryAssets().value
        let manifest = try store.load()

        // Then
        XCTAssertTrue(model.libraryAssets.isEmpty)
        XCTAssertTrue(model.selectedLibraryAssetIds.isEmpty)
        XCTAssertTrue(manifest.assets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.projectDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.projectDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstVideo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondVideo.path))
    }

    func testRequestRemoveSelectedLibraryAssetsSetsPendingConfirmationWithoutDeleting() throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let video = sourceRoot.appending(path: "keep-until-confirmed.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try makeTempDirectory())
        let imported = try store.importVideoFile(video)
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = imported.id

        // When
        model.requestRemoveSelectedLibraryAssets()

        // Then
        XCTAssertEqual(model.pendingLibraryRemoval?.assetIds, [imported.id])
        XCTAssertEqual(model.pendingLibraryRemoval?.title, imported.title)
        XCTAssertFalse(model.libraryAssets.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testCancelPendingLibraryRemovalClearsConfirmationWithoutDeleting() throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let video = sourceRoot.appending(path: "cancel-me.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try makeTempDirectory())
        let imported = try store.importVideoFile(video)
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = imported.id
        model.requestRemoveSelectedLibraryAssets()

        // When
        model.cancelPendingLibraryRemoval()

        // Then
        XCTAssertNil(model.pendingLibraryRemoval)
        XCTAssertFalse(model.libraryAssets.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testRequestRemoveSelectedLibraryAssetsWithNoSelectionReportsStatus() throws {
        // Given
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )

        // When
        model.requestRemoveSelectedLibraryAssets()

        // Then
        XCTAssertNil(model.pendingLibraryRemoval)
        XCTAssertEqual(model.status, "Select a library project first.")
    }

    func testLaunchAtLoginToggleRegistersLoginItem() throws {
        // Given
        let loginItems = MockLoginItemController()
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: loginItems,
            userDefaults: try makeUserDefaults()
        )

        // When
        model.launchAtLogin = true

        // Then
        XCTAssertTrue(loginItems.isEnabled)
        XCTAssertEqual(loginItems.requestedValues, [true])
        XCTAssertEqual(model.status, "Background Engine will open at login.")
    }

    func testLaunchAtLoginToggleRevertsWhenControllerThrows() throws {
        // Given
        let loginItems = MockLoginItemController()
        loginItems.error = TestError.expected
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: loginItems,
            userDefaults: try makeUserDefaults()
        )

        // When
        model.launchAtLogin = true

        // Then
        XCTAssertFalse(model.launchAtLogin)
        XCTAssertFalse(loginItems.isEnabled)
        XCTAssertEqual(loginItems.requestedValues, [true])
        XCTAssertTrue(model.status.contains("Open at login could not be changed"))
    }

    func testInitRestoresDisplayPreferences() throws {
        // Given
        let defaults = try makeUserDefaults()
        defaults.set("fill", forKey: "displayMode")
        defaults.set(false, forKey: "autoPauseWhenCovered")

        // When
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // Then
        XCTAssertEqual(model.displayMode, .fill)
        XCTAssertFalse(model.autoPauseWhenCovered)
    }

    func testSceneAssetsFolderPersistsAndFeedsRendererResolution() throws {
        // Given
        let defaults = try makeUserDefaults()
        let root = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let assetsDirectory = try makeSceneEngineAssetsFixture(in: root.appending(path: "source"))
        let appSupportAssetsDirectory = root.appending(path: "app-support-assets")
        let previousDefaultAssetsDirectory = SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL
        SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = appSupportAssetsDirectory
        defer {
            SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = previousDefaultAssetsDirectory
        }
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // When
        model.setSceneAssetsFolder(assetsDirectory)

        // Then
        XCTAssertEqual(model.sceneAssetsDirectory, assetsDirectory.path)
        XCTAssertEqual(defaults.string(forKey: "sceneEngineAssetsDirectory"), assetsDirectory.path)
        XCTAssertEqual(SceneEngineRendererConfiguration.assetsDirectoryURL(environment: [:])?.path, assetsDirectory.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: assetsDirectory.appending(path: "materials/util/composelayer.json").path
        ))
        XCTAssertTrue(model.sceneAssetsStatus.contains("ready"))
    }

    func testInvalidSceneAssetsFolderIsRejectedWithoutChangingPersistedValue() throws {
        // Given
        let defaults = try makeUserDefaults()
        let root = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let validAssetsDirectory = try makeSceneEngineAssetsFixture(in: root.appending(path: "stored"))
        let invalidDirectory = root.appending(path: "invalid")
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        let appSupportAssetsDirectory = root.appending(path: "app-support-assets")
        defaults.set(validAssetsDirectory.path, forKey: "sceneEngineAssetsDirectory")
        let previousDefaultAssetsDirectory = SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL
        SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = appSupportAssetsDirectory
        defer {
            SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = previousDefaultAssetsDirectory
        }
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // When
        model.setSceneAssetsFolder(invalidDirectory)

        // Then
        XCTAssertEqual(model.sceneAssetsDirectory, validAssetsDirectory.path)
        XCTAssertEqual(defaults.string(forKey: "sceneEngineAssetsDirectory"), validAssetsDirectory.path)
        XCTAssertEqual(SceneEngineRendererConfiguration.assetsDirectoryURL(environment: [:])?.path, validAssetsDirectory.path)
        XCTAssertTrue(model.status.contains("assets folder is incomplete"))
        XCTAssertTrue(model.status.contains("full contents"))
    }

    func testStoredSceneAssetsFolderMigratesToSecurityScopedBookmarkWithoutCopying() throws {
        // Given
        let defaults = try makeUserDefaults()
        let root = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let storedAssetsDirectory = try makeSceneEngineAssetsFixture(in: root.appending(path: "stored"))
        let appSupportAssetsDirectory = root.appending(path: "app-support-assets")
        defaults.set(storedAssetsDirectory.path, forKey: "sceneEngineAssetsDirectory")
        let previousDefaultAssetsDirectory = SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL
        SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = appSupportAssetsDirectory
        defer {
            SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = previousDefaultAssetsDirectory
        }

        // When
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // Then
        XCTAssertEqual(model.sceneAssetsDirectory, storedAssetsDirectory.path)
        XCTAssertEqual(defaults.string(forKey: "sceneEngineAssetsDirectory"), storedAssetsDirectory.path)
        XCTAssertEqual(SceneEngineRendererConfiguration.assetsDirectoryURL(environment: [:])?.path, storedAssetsDirectory.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: storedAssetsDirectory.appending(path: "materials/util/composelayer.json").path
        ))
    }

    func testSceneAssetsFolderCanBeClearedToDefaultResolution() throws {
        // Given
        let defaults = try makeUserDefaults()
        let root = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let assetsDirectory = try makeSceneEngineAssetsFixture(in: root.appending(path: "stored"))
        let appSupportAssetsDirectory = root.appending(path: "app-support-assets")
        defaults.set(assetsDirectory.path, forKey: "sceneEngineAssetsDirectory")
        let previousDefaultAssetsDirectory = SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL
        SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = appSupportAssetsDirectory
        defer {
            SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = previousDefaultAssetsDirectory
        }
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // When
        model.clearSceneAssetsFolder()

        // Then
        XCTAssertEqual(model.sceneAssetsDirectory, "")
        XCTAssertNil(defaults.string(forKey: "sceneEngineAssetsDirectory"))
        XCTAssertNil(SceneEngineRendererConfiguration.overrideAssetsPath)
        XCTAssertTrue(model.sceneAssetsStatus.contains("Not set"))
    }

    func testSceneAssetsEnvironmentOverrideWinsOverUserPreference() throws {
        // Given
        let defaults = try makeUserDefaults()
        let root = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let userAssetsDirectory = try makeSceneEngineAssetsFixture(in: root.appending(path: "stored"))
        let envAssetsDirectory = try makeSceneEngineAssetsFixture(in: root.appending(path: "env"))
        let appSupportAssetsDirectory = root.appending(path: "app-support-assets")
        defaults.set(userAssetsDirectory.path, forKey: "sceneEngineAssetsDirectory")
        let previousDefaultAssetsDirectory = SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL
        SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = appSupportAssetsDirectory
        defer {
            SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = previousDefaultAssetsDirectory
        }
        _ = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // When
        let resolved = SceneEngineRendererConfiguration.assetsDirectoryURL(
            environment: [
                SceneEngineRendererConfiguration.assetsEnvironmentVariableName: envAssetsDirectory.path
            ]
        )

        // Then
        XCTAssertEqual(resolved?.path, envAssetsDirectory.path)
    }

    func testInitDefaultsToContinuousPlayback() throws {
        // Given
        let defaults = try makeUserDefaults()

        // When
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // Then
        XCTAssertTrue(model.autoPauseWhenCovered)
    }

    func testInitDefaultsToDisabledWallpaperAudioAtHalfVolume() throws {
        // Given
        let defaults = try makeUserDefaults()

        // When
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // Then: audio defaults off so existing users aren't surprised by
        // wallpapers suddenly making sound.
        XCTAssertFalse(model.wallpaperAudioEnabled)
        XCTAssertEqual(model.wallpaperAudioVolume, 0.5, accuracy: 0.0001)
    }

    func testWallpaperAudioPreferencesPersistAcrossRestarts() throws {
        // Given
        let defaults = try makeUserDefaults()
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // When
        model.wallpaperAudioEnabled = true
        model.wallpaperAudioVolume = 0.85

        // Then
        XCTAssertTrue(defaults.bool(forKey: "wallpaperAudioEnabled"))
        XCTAssertEqual(defaults.double(forKey: "wallpaperAudioVolume"), 0.85, accuracy: 0.0001)

        // And: a freshly constructed view model restores them.
        let restored = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )
        XCTAssertTrue(restored.wallpaperAudioEnabled)
        XCTAssertEqual(restored.wallpaperAudioVolume, 0.85, accuracy: 0.0001)
    }

    func testV1IgnoresLegacyLanguagePreferenceAndUsesEnglish() throws {
        // Given
        let defaults = try makeUserDefaults()
        defaults.set("ko", forKey: "language")
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )
        XCTAssertEqual(model.L("tab.library"), "Library")
        XCTAssertEqual(defaults.string(forKey: "language"), "ko")
    }

    func testLocalizedStringsResolveFromEnglishBundle() throws {
        // Given
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )

        XCTAssertEqual(model.L("tab.library"), "Library")
        XCTAssertEqual(model.L("tab.settings"), "Settings")
    }

    func testInitRestoresLockScreenAnimationPreferenceWithoutInstalling() throws {
        // Given
        let defaults = try makeUserDefaults()
        defaults.set(true, forKey: "lockScreenAnimationEnabled")
        let lockScreen = MockLockScreenAnimationController()

        // When
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            userDefaults: defaults
        )

        // Then
        XCTAssertTrue(model.lockScreenAnimationEnabled)
        XCTAssertEqual(lockScreen.enabledRequests, [true])
    }

    func testLockScreenAnimationToggleInstallsScreenSaverAndPersistsPreference() throws {
        // Given
        let defaults = try makeUserDefaults()
        let lockScreen = MockLockScreenAnimationController()
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            userDefaults: defaults
        )

        // When
        model.lockScreenAnimationEnabled = true

        // Then
        XCTAssertEqual(lockScreen.enabledRequests, [true])
        XCTAssertTrue(defaults.bool(forKey: "lockScreenAnimationEnabled"))
        XCTAssertTrue(model.status.contains("Installed and selected"))
    }

    func testInitRestoresAutomaticUpdatePreference() throws {
        // Given
        let defaults = try makeUserDefaults()
        defaults.set(false, forKey: "automaticallyCheckForUpdates")

        // When
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // Then
        XCTAssertFalse(model.automaticallyCheckForUpdates)
    }

    func testManualUpdateCheckReportsAvailableUpdate() async throws {
        // Given
        let update = UpdateRelease(
            version: "1.2.0",
            tagName: "v1.2.0",
            releaseURL: URL(string: "https://example.com/release")!,
            downloadURL: URL(string: "https://example.com/app.dmg")!
        )
        let checker = MockUpdateChecker(result: .updateAvailable(update))
        let opener = MockUpdateURLOpener()
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            updateChecker: checker,
            updateURLOpener: opener,
            currentVersionProvider: { "1.1.0" },
            userDefaults: try makeUserDefaults()
        )

        // When
        await model.checkForUpdatesNow()
        model.openAvailableUpdate()

        // Then
        XCTAssertEqual(checker.requestedVersions, ["1.1.0"])
        XCTAssertEqual(model.availableUpdate, update)
        XCTAssertEqual(model.updateAlert?.title, "Update Available")
        XCTAssertEqual(
            model.updateAlert?.message,
            "Background Engine 1.2.0 is available. Click Download Update to download the latest DMG."
        )
        XCTAssertEqual(opener.openedURLs, [try XCTUnwrap(update.downloadURL)])
        XCTAssertEqual(model.status, "Opened Background Engine 1.2.0 update.")
    }

    func testManualUpdateCheckReportsUpToDateAndClearsAvailableUpdate() async throws {
        // Given
        let checker = MockUpdateChecker(result: .upToDate(currentVersion: "1.1.0", latestVersion: "1.1.0"))
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            updateChecker: checker,
            currentVersionProvider: { "1.1.0" },
            userDefaults: try makeUserDefaults()
        )

        // When
        await model.checkForUpdatesNow()

        // Then
        XCTAssertNil(model.availableUpdate)
        XCTAssertEqual(model.status, "Background Engine is up to date (1.1.0).")
        XCTAssertEqual(model.updateAlert?.title, "Already Up to Date")
        XCTAssertEqual(
            model.updateAlert?.message,
            "Background Engine 1.1.0 is already the latest version."
        )
    }

    func testManualUpdateCheckReportsFailureInAlert() async throws {
        // Given
        let checker = MockUpdateChecker(error: LocalizedTestError.expected)
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            updateChecker: checker,
            currentVersionProvider: { "1.1.0" },
            userDefaults: try makeUserDefaults()
        )

        // When
        await model.checkForUpdatesNow()

        // Then
        XCTAssertEqual(model.status, "Update check failed: Expected update error.")
        XCTAssertEqual(model.updateAlert?.title, "Update Check Failed")
        XCTAssertEqual(model.updateAlert?.message, "Expected update error.")
    }

    func testAutomaticUpdateCheckHonorsPreferenceAndInterval() async throws {
        // Given
        let defaults = try makeUserDefaults()
        let now = Date(timeIntervalSince1970: 100)
        defaults.set(now, forKey: "lastUpdateCheckAt")
        let checker = MockUpdateChecker(
            result: .upToDate(currentVersion: "1.1.0", latestVersion: "1.1.0")
        )
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            updateChecker: checker,
            currentVersionProvider: { "1.1.0" },
            userDefaults: defaults
        )

        // When
        await model.performAutomaticUpdateCheckIfNeeded(now: now.addingTimeInterval(60))
        await model.performAutomaticUpdateCheckIfNeeded(force: true, now: now.addingTimeInterval(60))

        // Then
        XCTAssertEqual(checker.requestedVersions, ["1.1.0"])
    }

    func testAutomaticUpdateCheckCanBeDisabled() async throws {
        // Given
        let defaults = try makeUserDefaults()
        defaults.set(false, forKey: "automaticallyCheckForUpdates")
        let checker = MockUpdateChecker(
            result: .upToDate(currentVersion: "1.1.0", latestVersion: "1.1.0")
        )
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            updateChecker: checker,
            currentVersionProvider: { "1.1.0" },
            userDefaults: defaults
        )

        // When
        await model.performAutomaticUpdateCheckIfNeeded(force: true)

        // Then
        XCTAssertTrue(checker.requestedVersions.isEmpty)
    }

    func testStopPlaybackClearsLastPlayedWallpaperPreference() throws {
        // Given
        let defaults = try makeUserDefaults()
        defaults.set("last-wallpaper", forKey: "lastPlayedAssetId")
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // When
        model.stopPlayback()

        // Then
        XCTAssertNil(defaults.string(forKey: "lastPlayedAssetId"))
    }

    func testStartupPlaybackPersistsSynchronousCompatibilityReport() throws {
        let store = LibraryStore(root: try makeTempDirectory())
        let asset = try makeScannedProject(root: try makeTempDirectory(), id: "restored", title: "Restored")
        try store.replaceAsset(asset)
        let defaults = try makeUserDefaults()
        defaults.set(asset.id, forKey: "lastPlayedAssetId")
        let report = CompatibilityReport(
            level: .limited,
            playbackPath: .nativeScene,
            missingCapabilities: [.particle],
            diagnosticCode: "startup_runtime_fallback"
        )

        _ = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            wallpaperPlayer: StartupReportingWallpaperPlayer(report: report),
            userDefaults: defaults
        )

        XCTAssertEqual(try store.load().assets.first?.compatibilityReport, report)
    }

    func testStartupSceneCompatibilityProbeIsDeferredAndPersistsResult() async throws {
        let store = LibraryStore(root: try makeTempDirectory())
        let project = try makeTempDirectory()
        let package = project.appending(path: "scene.pkg")
        try Data([0, 1, 2, 3]).write(to: package)
        let asset = WallpaperAsset(
            id: "deferred-scene",
            title: "Deferred Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: package.path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(asset)

        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )

        // Initial construction never waits for package/texture decoding.
        XCTAssertTrue(model.libraryAssets.first?.compatibilityReport?.needsProbe == true)
        XCTAssertEqual(
            model.libraryAssets.first?.compatibilityReport?.diagnosticCode,
            "scene_probe_pending"
        )

        await model.waitForSceneCompatibilityProbes()

        let updated = try XCTUnwrap(model.libraryAssets.first)
        XCTAssertEqual(updated.supportStatus, .unsupported)
        XCTAssertEqual(updated.compatibilityReport?.level, .unsupported)
        XCTAssertEqual(updated.compatibilityReport?.diagnosticCode, "scene_package_unreadable")
        XCTAssertFalse(updated.compatibilityReport?.needsProbe == true)
        XCTAssertEqual(try store.load().assets.first, updated)
    }

    private func makeRuntimeFallbackVideoConverter(
        in root: URL,
        invocationLog: URL,
        blockFile: URL? = nil
    ) throws -> VideoConverter {
        let tools = root.appending(path: "runtime-video-tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let ffmpeg = tools.appending(path: "ffmpeg")
        let ffprobe = tools.appending(path: "ffprobe")
        try #"""
        #!/bin/sh
        previous=
        input=
        input_fd=
        for argument do
            if [ "$previous" = "-i" ]; then input=$argument; fi
            if [ "$previous" = "-fd" ]; then input_fd=$argument; fi
            previous=$argument
        done
        printf '%s\n' invocation >> "\#(invocationLog.path)"
        \#(blockFile.map { block in
            "while [ -e \"\(block.path)\" ]; do /bin/sleep 0.05; done"
        } ?? ":")
        if [ "$input" = "fd:" ]; then
            /bin/cat "/dev/fd/$input_fd"
        else
            /bin/cat "$input"
        fi
        """#.write(to: ffmpeg, atomically: true, encoding: .utf8)
        try #"""
        #!/bin/sh
        case " $* " in
          *" -count_packets "*)
            printf '%s' '{"streams":[{"index":0,"codec_type":"video","nb_read_packets":"1"}]}'
            ;;
          *)
            printf '%s' '{"streams":[{"index":0,"codec_type":"video","codec_name":"mpeg4","width":32,"height":32,"duration":"1.0","start_time":"0"}],"format":{"format_name":"mov,mp4","duration":"1.0","size":"20"}}'
            ;;
        esac
        """#.write(to: ffprobe, atomically: true, encoding: .utf8)
        for executable in [ffmpeg, ffprobe] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        return VideoConverter(resolver: MediaToolResolver(
            bundleResourceURL: nil,
            environment: [
                "BACKGROUND_ENGINE_FFMPEG": ffmpeg.path,
                "BACKGROUND_ENGINE_FFPROBE": ffprobe.path
            ],
            allowDevelopmentFallback: true
        ))
    }

    private func waitForFile(_ url: URL) async throws {
        // Process launch can be briefly delayed when the full test bundle is
        // also exercising WebKit/AVFoundation. Keep this synchronization
        // bounded but avoid a false timeout under normal CI contention.
        for _ in 0..<1_000 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(url.lastPathComponent)")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeUserDefaults() throws -> UserDefaults {
        let suiteName = "Background EngineTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func makeScannedProject(
        root: URL,
        id: String,
        title: String,
        dateAdded: Date? = nil
    ) throws -> WallpaperAsset {
        let project = root.appending(path: id)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let entrypoint = project.appending(path: "loop.mp4")
        try Data([1]).write(to: entrypoint)
        try #"{"title":"\#(title)","file":"loop.mp4"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        return WallpaperAsset(
            id: id,
            title: title,
            kind: .video,
            supportStatus: .playable,
            source: .localSteamWorkshop,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: id.allSatisfy(\.isNumber) ? id : nil,
            dateAdded: dateAdded,
            redistributionAllowed: false,
            issues: []
        )
    }

    private func makeSceneEngineAssetsFixture(in root: URL) throws -> URL {
        let assetsDirectory = root.appending(path: "wallpaper-engine-assets")
        for relativePath in SceneEngineRendererConfiguration.requiredAssetPaths {
            let fileURL = assetsDirectory.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "{}\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return assetsDirectory
    }
}

@MainActor
private final class MockLoginItemController: LoginItemManaging {
    var isEnabled = false
    var requestedValues: [Bool] = []
    var error: Error?

    func setEnabled(_ enabled: Bool) throws {
        requestedValues.append(enabled)
        if let error {
            throw error
        }
        isEnabled = enabled
    }

    func openSystemSettings() {}
}

@MainActor
private final class MockLockScreenAnimationController: LockScreenAnimationManaging {
    var enabledRequests: [Bool] = []
    var updatedAssetIds: [String?] = []
    var updatedEntrypoints: [String?] = []
    var updatedDisplayModes: [WallpaperDisplayMode] = []
    var didOpenSettings = false
    var error: Error?

    func setEnabled(_ enabled: Bool, activeAsset: WallpaperAsset?, displayMode: WallpaperDisplayMode) throws {
        if let error {
            throw error
        }
        enabledRequests.append(enabled)
        updatedAssetIds.append(activeAsset?.id)
        updatedEntrypoints.append(activeAsset?.entrypoint)
        updatedDisplayModes.append(displayMode)
    }

    func updateActiveAsset(_ asset: WallpaperAsset?, displayMode: WallpaperDisplayMode) throws {
        if let error {
            throw error
        }
        updatedAssetIds.append(asset?.id)
        updatedEntrypoints.append(asset?.entrypoint)
        updatedDisplayModes.append(displayMode)
    }

    func openScreenSaverSettings() throws {
        didOpenSettings = true
    }
}

@MainActor
private final class MockDisplaySessionCoordinator: DisplaySessionApplying {
    private(set) var applyCallCount = 0
    var failures: [DisplayPlaybackFailure]

    init(failures: [DisplayPlaybackFailure] = []) {
        self.failures = failures
    }

    func apply(
        assignments: [DisplayAssignment],
        assets: [WallpaperAsset],
        autoPauseWhenCovered: Bool,
        globalAudioEnabled: Bool,
        globalAudioVolume: Double
    ) -> [DisplayPlaybackFailure] {
        applyCallCount += 1
        return failures
    }
}

@MainActor
private final class FailingWallpaperPlayer: WallpaperPlaying {
    var hasActiveDisplayAssignments = false
    var activeAppliedDisplaySessions: [String: AssignedDisplayRefreshPlan.AppliedSession] = [:]

    func play(
        asset: WallpaperAsset,
        autoPauseWhenCovered: Bool,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool?,
        audioVolume: Double?
    ) throws {
        throw FailingWallpaperPlayerError.failure
    }

    func stop() {}
    func setDisplayMode(_: WallpaperDisplayMode) {}
    func setAutoPauseWhenCovered(_: Bool) {}
}

private enum FailingWallpaperPlayerError: LocalizedError {
    case failure

    var errorDescription: String? { "playback failed" }
}

private final class MockUpdateChecker: UpdateChecking {
    let result: UpdateCheckResult?
    let error: Error?
    var requestedVersions: [String] = []

    init(result: UpdateCheckResult) {
        self.result = result
        error = nil
    }

    init(error: Error) {
        result = nil
        self.error = error
    }

    func checkForUpdates(currentVersion: String) async throws -> UpdateCheckResult {
        requestedVersions.append(currentVersion)
        if let error {
            throw error
        }
        return try XCTUnwrap(result)
    }
}

@MainActor
private final class StartupReportingWallpaperPlayer: WallpaperPlaying {
    let report: CompatibilityReport

    init(report: CompatibilityReport) {
        self.report = report
    }

    func play(
        asset: WallpaperAsset,
        autoPauseWhenCovered: Bool,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool?,
        audioVolume: Double?
    ) throws {
        SceneWallpaperContentFactory.compatibilityReportHandler?(asset, report)
    }

    func stop() {}
    func setDisplayMode(_ mode: WallpaperDisplayMode) {}
    func setAutoPauseWhenCovered(_ enabled: Bool) {}
}

@MainActor
private final class AssetReconcilingWallpaperPlayer: WallpaperPlaying {
    private(set) var reconciledAssets: [[WallpaperAsset]] = []
    private(set) var preparedReplacementAssetIDs: [WallpaperAsset.ID] = []
    private(set) var finishedReplacementAssetIDs: [WallpaperAsset.ID] = []
    private(set) var webPropertyRefreshAssetIDs: [WallpaperAsset.ID] = []
    private(set) var metadataUpdatedAssetIDs: [WallpaperAsset.ID] = []
    var videoRuntimeFailureHandler: ((VideoPlaybackFailure) -> Void)?
    var prepareHandler: ((WallpaperAsset.ID) -> Void)?
    var finishHandler: ((WallpaperAsset.ID) -> Void)?
    var reconcileHandler: (([WallpaperAsset]) -> Void)?
    var activeAssetID: WallpaperAsset.ID?
    var activeAppliedDisplaySessions: [String: AssignedDisplayRefreshPlan.AppliedSession] = [:]
    var playError: Error?
    private let singleDisplayUUIDs: [String]?

    init(singleDisplayUUIDs: [String]? = nil) {
        self.singleDisplayUUIDs = singleDisplayUUIDs
    }

    func play(
        asset: WallpaperAsset,
        autoPauseWhenCovered: Bool,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool?,
        audioVolume: Double?
    ) throws {
        if let playError {
            throw playError
        }
        activeAssetID = asset.id
        let displayUUIDs = singleDisplayUUIDs
            ?? WallpaperDisplayTopology.current().map(\.id)
        activeAppliedDisplaySessions = displayUUIDs.reduce(into: [:]) {
            sessions, displayUUID in
            sessions[displayUUID] = .init(assignment: nil, asset: asset)
        }
    }

    func stop() {
        activeAssetID = nil
        activeAppliedDisplaySessions = [:]
    }
    func setDisplayMode(_: WallpaperDisplayMode) {}
    func setAutoPauseWhenCovered(_: Bool) {}
    func prepareForLibraryAssetReplacement(_ assetID: WallpaperAsset.ID) async {
        preparedReplacementAssetIDs.append(assetID)
        prepareHandler?(assetID)
    }
    func finishLibraryAssetReplacement(_ assetID: WallpaperAsset.ID) {
        finishedReplacementAssetIDs.append(assetID)
        finishHandler?(assetID)
    }
    func reconcileLibraryAssets(_ assets: [WallpaperAsset]) {
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        if let activeAssetID, assetsByID[activeAssetID] == nil {
            self.activeAssetID = nil
        }
        activeAppliedDisplaySessions = activeAppliedDisplaySessions.compactMapValues { session in
            guard let asset = assetsByID[session.asset.id] else { return nil }
            return .init(assignment: session.assignment, asset: asset)
        }
        reconciledAssets.append(assets)
        reconcileHandler?(assets)
    }
    func updateLibraryAssetMetadataWithoutReopening(_ asset: WallpaperAsset) {
        metadataUpdatedAssetIDs.append(asset.id)
        activeAppliedDisplaySessions = activeAppliedDisplaySessions.mapValues { session in
            guard WallpaperPlaybackRevisionIdentity.matches(session.asset, asset) else {
                return session
            }
            return .init(assignment: session.assignment, asset: asset)
        }
    }
    func refreshIfNeeded(afterWebPropertyChangeFor assetID: WallpaperAsset.ID) {
        webPropertyRefreshAssetIDs.append(assetID)
    }
    func setVideoRuntimeFailureHandler(
        _ handler: ((VideoPlaybackFailure) -> Void)?
    ) {
        videoRuntimeFailureHandler = handler
    }
}

private final class MockUpdateURLOpener: UpdateURLOpening {
    var openedURLs: [URL] = []

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

private final class SelectiveFailingAssetTrasher: AssetTrashing, @unchecked Sendable {
    private let lock = NSLock()
    private var failingDirectoryName: String?

    func fail(directoryNamed directoryName: String) {
        lock.withLock {
            failingDirectoryName = directoryName
        }
    }

    func trashItem(at url: URL) throws {
        try removeUnlessSelectedFailure(url)
    }

    func removeItem(at url: URL) throws {
        try removeUnlessSelectedFailure(url)
    }

    private func removeUnlessSelectedFailure(_ url: URL) throws {
        let shouldFail = lock.withLock {
            failingDirectoryName.map {
                url.lastPathComponent.hasPrefix(".\($0).retired-")
            } ?? false
        }
        if shouldFail {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
    }
}

private enum TestError: Error {
    case expected
}

private enum LocalizedTestError: LocalizedError {
    case expected

    var errorDescription: String? {
        "Expected update error."
    }
}

private actor CancellationRaceGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasWaiter() -> Bool {
        continuation != nil
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class CancellationObservingScanWorker: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var forceReleased = false
    private var didObserveCancellation = false

    var observedCancellation: Bool {
        condition.withLock { didObserveCancellation }
    }

    var isStarted: Bool {
        condition.withLock { started }
    }

    func scan(root: URL) throws -> ScanResult {
        condition.lock()
        started = true
        condition.broadcast()
        while !Task.isCancelled, !forceReleased {
            _ = condition.wait(until: Date().addingTimeInterval(0.01))
        }
        didObserveCancellation = Task.isCancelled
        condition.unlock()
        try Task.checkCancellation()
        return ScanResult(root: root.path, generatedAt: Date(), assets: [])
    }

    func release() {
        condition.lock()
        forceReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
private final class MutableDisplayProvider {
    var displays: [ConnectedDisplay]

    init(displays: [ConnectedDisplay]) {
        self.displays = displays
    }
}
