import Foundation
import XCTest
@_spi(LivelyCatalog) @testable import BackgroundEngineCore

final class OfficialLivelyWallpaperCatalogTests: XCTestCase {
    func testCatalogPinsOfficialReleaseArchivesWithoutBundlingLicensedContent() throws {
        let wallpapers = OfficialLivelyWallpaperCatalog.wallpapers

        XCTAssertEqual(wallpapers.map(\.id), [
            "rocksdanister-rain-v3",
            "rocksdanister-snow-v1",
            "rocksdanister-clouds-v1",
            "rocksdanister-simple-system-v2.0",
            "rocksdanister-simple-system-3d-v2.0",
            "rocksdanister-weather-demo-v1",
            "rocksdanister-ferrari-458-v1.0.0.1",
            "rocksdanister-music-tunnel-v1.0.0.1",
            "rocksdanister-audiorbits-v1.0.0.0"
        ])
        XCTAssertEqual(
            wallpapers.filter { $0.category == .ambientEffects }.count,
            3
        )
        XCTAssertEqual(
            wallpapers.filter { $0.category == .systemAndWeather }.count,
            3
        )
        XCTAssertEqual(
            wallpapers.filter { $0.category == .musicAndMedia }.count,
            3
        )
        XCTAssertTrue(wallpapers.allSatisfy { !$0.termsNotice.isEmpty })
        XCTAssertTrue(
            wallpapers
                .filter { $0.category == .musicAndMedia }
                .allSatisfy { $0.runtimeNotice.contains("Limited") }
        )
        XCTAssertTrue(wallpapers.allSatisfy {
            $0.downloadURL.scheme == "https"
                && $0.downloadURL.host == "github.com"
                && $0.downloadURL.path.contains("/rocksdanister/")
                && $0.downloadURL.path.contains("/releases/download/")
                && $0.archiveSHA256.count == 64
                && $0.sourceCommit.count == 40
                && $0.archiveByteCount > 0
                && $0.pinnedSourceURL.absoluteString.contains($0.sourceCommit)
                && $0.licenseURL.absoluteString.contains($0.sourceCommit)
        })
        let exactPins: [(
            id: String,
            downloadURL: String,
            byteCount: UInt64,
            sha256: String,
            commit: String,
            licenseURL: String
        )] = [
            (
                "rocksdanister-rain-v3",
                "https://github.com/rocksdanister/rain/releases/download/v3/Rain_v3.zip",
                18_557_264,
                "48bdd9da1bbfecdcffe6479c1d44e6175bddc4e4bf847fdf053ba61cefb06186",
                "215b57378d3fe648d2797aaf8a101a4009128527",
                "https://github.com/rocksdanister/rain/blob/215b57378d3fe648d2797aaf8a101a4009128527/License.txt"
            ),
            (
                "rocksdanister-snow-v1",
                "https://github.com/rocksdanister/snow/releases/download/v1/snow_v1.zip",
                18_481_669,
                "15f8e3b91e0010ae6c6370f1ea280733d3534b43da66854a4fe0e05012c85999",
                "f955c86e1de57ffe06bedac294add36aa4fd1f7a",
                "https://github.com/rocksdanister/snow/blob/f955c86e1de57ffe06bedac294add36aa4fd1f7a/License.txt"
            ),
            (
                "rocksdanister-clouds-v1",
                "https://github.com/rocksdanister/clouds/releases/download/v1.0/clouds.zip",
                1_435_254,
                "2b54637763214505514fd5711e65a6eecf11ec5c9a84586445ff5da095adb7bc",
                "9c112735b34808020d4269750207e2ac89c28a79",
                "https://github.com/rocksdanister/clouds/blob/9c112735b34808020d4269750207e2ac89c28a79/License.txt"
            ),
            (
                "rocksdanister-simple-system-v2.0",
                "https://github.com/rocksdanister/system-stats-wallpaper/releases/download/v2.0/Simple.System.zip",
                1_200_818,
                "edd75a3d7da63061b28b6776029fabf454f765a393adfba2c0c917c943c46ad7",
                "1a75e7100a5b3baf1e1741c8c5733c1c56610320",
                "https://github.com/rocksdanister/system-stats-wallpaper/blob/1a75e7100a5b3baf1e1741c8c5733c1c56610320/src/Simple%20System/license.txt"
            ),
            (
                "rocksdanister-simple-system-3d-v2.0",
                "https://github.com/rocksdanister/system-stats-wallpaper/releases/download/v2.0/Simple.System.3D.zip",
                13_460_519,
                "f5b890ed53c927de6c76b2a9a81898d96f668a4978c71f6d94e865ad7c9321b6",
                "1a75e7100a5b3baf1e1741c8c5733c1c56610320",
                "https://github.com/rocksdanister/system-stats-wallpaper/blob/1a75e7100a5b3baf1e1741c8c5733c1c56610320/src/Simple%20System%203D/license.txt"
            ),
            (
                "rocksdanister-weather-demo-v1",
                "https://github.com/rocksdanister/weather-fetch-wallpaper/releases/download/v1/weather_demo.zip",
                77_763,
                "08f6f27a30f444c20ddbea74d0e7da980e5582cf021c6821dd8401967fb2d1a0",
                "4fbd75b14d8105e4c5f246e1ce4fd27e2ab01172",
                "https://github.com/rocksdanister/weather-fetch-wallpaper/blob/4fbd75b14d8105e4c5f246e1ce4fd27e2ab01172/LICENSE"
            ),
            (
                "rocksdanister-ferrari-458-v1.0.0.1",
                "https://github.com/rocksdanister/audio-visualizer-wallpaper/releases/download/v1.0.0.1/Ferrari.458.Italia.zip",
                4_710_704,
                "52ccbab1f55c1f60121dc765b58aeaf4156ec5de04e61afd985b5fb486087eea",
                "c1b5a523970010638315386a0f8df3eaac2dd56f",
                "https://github.com/rocksdanister/audio-visualizer-wallpaper/blob/c1b5a523970010638315386a0f8df3eaac2dd56f/src/Ferrari%20458/license.txt"
            ),
            (
                "rocksdanister-music-tunnel-v1.0.0.1",
                "https://github.com/rocksdanister/audio-visualizer-wallpaper/releases/download/v1.0.0.1/Music.Tunnel.zip",
                2_421_390,
                "03e1b365332a0640fc55b828fb288619884f1bc2a8b6d13e9fbff03a51a09bbe",
                "ac37e3723dacc2ebcce6eaf823abebae9e9f72e4",
                "https://github.com/rocksdanister/audio-visualizer-wallpaper/blob/ac37e3723dacc2ebcce6eaf823abebae9e9f72e4/src/Music%20Tunnel/License.txt"
            ),
            (
                "rocksdanister-audiorbits-v1.0.0.0",
                "https://github.com/rocksdanister/audiorbits/releases/download/v1.0.0.0/AudiOrbits.zip",
                1_706_251,
                "d832ed8955c47ebea3190794f96697c4527c5ce84ce63b03b9cb9bd23f305ae4",
                "cf1986f052446af0ac6c076a8258b376591a2278",
                "https://github.com/rocksdanister/audiorbits/blob/cf1986f052446af0ac6c076a8258b376591a2278/LICENSE"
            )
        ]
        for pin in exactPins {
            let wallpaper = try XCTUnwrap(wallpapers.first { $0.id == pin.id })
            XCTAssertEqual(wallpaper.downloadURL.absoluteString, pin.downloadURL)
            XCTAssertEqual(wallpaper.archiveByteCount, pin.byteCount)
            XCTAssertEqual(wallpaper.archiveSHA256, pin.sha256)
            XCTAssertEqual(wallpaper.sourceCommit, pin.commit)
            XCTAssertEqual(wallpaper.licenseURL.absoluteString, pin.licenseURL)
        }
    }

    func testSampleProjectDiscoveryURLIsCanonicalAndNeverCatalogData() throws {
        let url = OfficialLivelyWallpaperCatalog.sampleProjectsURL
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "github.com")
        XCTAssertNil(components.port)
        XCTAssertNil(components.user)
        XCTAssertNil(components.password)
        XCTAssertNil(components.query)
        XCTAssertNil(components.fragment)
        XCTAssertEqual(
            components.path,
            "/rocksdanister/lively/wiki/Sample-Wallpaper-Projects"
        )
        XCTAssertFalse(
            OfficialLivelyWallpaperCatalog.wallpapers.contains {
                $0.downloadURL == url
            }
        )
    }

    func testVerifiedOfficialArchiveImportsThroughLivelyPackagePipeline() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = LibraryStore(root: fixture.library)
        let service = OfficialLivelyWallpaperDownloadService(
            store: store,
            catalog: [fixture.wallpaper],
            downloader: { _ in (fixture.archive, fixture.response) }
        )

        let asset = try await service.downloadAndImport(fixture.wallpaper)

        XCTAssertEqual(asset.title, "Official Fixture")
        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(asset.source, .manualFolder)
        XCTAssertFalse(asset.redistributionAllowed)
        let stored = try XCTUnwrap(store.load().assets.first)
        XCTAssertEqual(stored.id, asset.id)
        XCTAssertEqual(stored.contentHash, asset.contentHash)
        XCTAssertEqual(stored.entrypoint, asset.entrypoint)
        XCTAssertEqual(stored.compatibilityReport, asset.compatibilityReport)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.archive.path),
            "The URLSession temporary download must be removed after its verified snapshot is imported."
        )
    }

    /// Local release-corpus coverage without adding third-party wallpaper
    /// bytes to Git. CI exercises the deterministic ZIP fixture above; a
    /// maintainer can additionally point this test at the audited official
    /// archives before changing their size/hash pins.
    func testConfiguredOfficialReleaseCorpusImportsEveryCatalogWallpaper() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let corpusPath = environment["BACKGROUND_ENGINE_OFFICIAL_LIVELY_ARCHIVE_DIR"],
              !corpusPath.isEmpty else {
            let message = "External official Lively archive corpus is not configured; "
                + "set BACKGROUND_ENGINE_OFFICIAL_LIVELY_ARCHIVE_DIR to verify all nine releases."
            if environment["BACKGROUND_ENGINE_REQUIRE_OFFICIAL_LIVELY_ARCHIVES"] == "1" {
                XCTFail(message)
            } else {
                FileHandle.standardError.write(Data("note: \(message)\n".utf8))
            }
            return
        }

        let corpusRoot = URL(filePath: corpusPath, directoryHint: .isDirectory)
        let wallpapers = OfficialLivelyWallpaperCatalog.wallpapers
        XCTAssertEqual(wallpapers.count, 9)
        let expectedMissingCapabilities: [String: [WallpaperCapability]] = [
            "rocksdanister-simple-system-v2.0": [
                .interaction, .mediaIntegration,
            ],
            "rocksdanister-simple-system-3d-v2.0": [
                .audioReactive, .externalNetwork, .interaction, .mediaIntegration,
            ],
            "rocksdanister-weather-demo-v1": [
                .externalNetwork,
            ],
            "rocksdanister-ferrari-458-v1.0.0.1": [
                .audioReactive, .externalNetwork, .interaction,
            ],
            "rocksdanister-music-tunnel-v1.0.0.1": [
                .externalNetwork, .interaction, .mediaIntegration,
            ],
            "rocksdanister-audiorbits-v1.0.0.0": [
                .audioReactive, .externalNetwork, .interaction,
            ],
        ]

        for wallpaper in wallpapers {
            let root = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let downloadedArchive = root.appending(path: "download.zip")
            try FileManager.default.copyItem(
                at: corpusRoot.appending(path: wallpaper.archiveFileName),
                to: downloadedArchive
            )
            let response = try XCTUnwrap(HTTPURLResponse(
                url: wallpaper.downloadURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(wallpaper.archiveByteCount)]
            ))
            let store = LibraryStore(root: root.appending(path: "Library"))
            let service = OfficialLivelyWallpaperDownloadService(
                store: store,
                catalog: [wallpaper],
                downloader: { _ in (downloadedArchive, response) }
            )

            let asset = try await service.downloadAndImport(wallpaper)

            XCTAssertEqual(asset.title, wallpaper.title)
            XCTAssertEqual(asset.kind, .web)
            XCTAssertEqual(
                asset.supportStatus,
                .playable,
                "\(wallpaper.id): \(String(describing: asset.compatibilityReport))"
            )
            XCTAssertNotEqual(
                asset.compatibilityReport?.level,
                .unsupported,
                "\(wallpaper.id): \(String(describing: asset.compatibilityReport))"
            )
            if let expectedMissing = expectedMissingCapabilities[wallpaper.id] {
                XCTAssertEqual(
                    asset.compatibilityReport?.level,
                    .limited,
                    "\(wallpaper.id): \(String(describing: asset.compatibilityReport))"
                )
                XCTAssertEqual(
                    asset.compatibilityReport?.missingCapabilities,
                    expectedMissing.sorted(),
                    "\(wallpaper.id): \(String(describing: asset.compatibilityReport))"
                )
            }
            XCTAssertFalse(asset.redistributionAllowed)
        }
    }

    func testHashMismatchIsRejectedBeforeImporterCanCommit() async throws {
        let fixture = try makeFixture(archiveSHA256: String(repeating: "0", count: 64))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = LibraryStore(root: fixture.library)
        let service = OfficialLivelyWallpaperDownloadService(
            store: store,
            catalog: [fixture.wallpaper],
            downloader: { _ in (fixture.archive, fixture.response) }
        )

        do {
            _ = try await service.downloadAndImport(fixture.wallpaper)
            XCTFail("Expected a checksum mismatch")
        } catch let error as OfficialLivelyWallpaperDownloadError {
            XCTAssertEqual(error, .archiveHashMismatch)
        }
        XCTAssertTrue(try store.load().assets.isEmpty)
    }

    func testUntrustedRedirectTargetIsRejected() async throws {
        let fixture = try makeFixture(responseURL: URL(string: "https://example.com/file.zip")!)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = LibraryStore(root: fixture.library)
        let service = OfficialLivelyWallpaperDownloadService(
            store: store,
            catalog: [fixture.wallpaper],
            downloader: { _ in (fixture.archive, fixture.response) }
        )

        do {
            _ = try await service.downloadAndImport(fixture.wallpaper)
            XCTFail("Expected an untrusted response")
        } catch let error as OfficialLivelyWallpaperDownloadError {
            XCTAssertEqual(error, .untrustedResponse)
        }
        XCTAssertTrue(try store.load().assets.isEmpty)
    }

    func testUserControlledGitHubContentHostIsNotTrustedAsAReleaseAsset() async throws {
        let fixture = try makeFixture(
            responseURL: URL(
                string: "https://raw.githubusercontent.com/rocksdanister/fixture/main/fixture.zip"
            )!
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = LibraryStore(root: fixture.library)
        let service = OfficialLivelyWallpaperDownloadService(
            store: store,
            catalog: [fixture.wallpaper],
            downloader: { _ in (fixture.archive, fixture.response) }
        )

        do {
            _ = try await service.downloadAndImport(fixture.wallpaper)
            XCTFail("Expected user-controlled GitHub content to be rejected")
        } catch let error as OfficialLivelyWallpaperDownloadError {
            XCTAssertEqual(error, .untrustedResponse)
        }
        XCTAssertTrue(try store.load().assets.isEmpty)
    }

    func testPinnedArchiveFromGitHubReleaseAssetCDNIsAccepted() async throws {
        let fixture = try makeFixture(
            responseURL: URL(
                string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/fixture.zip?token=signed"
            )!
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = LibraryStore(root: fixture.library)
        let service = OfficialLivelyWallpaperDownloadService(
            store: store,
            catalog: [fixture.wallpaper],
            downloader: { _ in (fixture.archive, fixture.response) }
        )

        let asset = try await service.downloadAndImport(fixture.wallpaper)

        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(asset.title, fixture.wallpaper.title)
    }

    func testActualArchiveSizeMismatchIsRejectedBeforeHashingOrImport() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oversizedDownload = fixture.root.appending(path: "oversized-download.zip")
        var data = try Data(contentsOf: fixture.archive)
        data.append(0)
        try data.write(to: oversizedDownload)
        let store = LibraryStore(root: fixture.library)
        let service = OfficialLivelyWallpaperDownloadService(
            store: store,
            catalog: [fixture.wallpaper],
            downloader: { _ in (oversizedDownload, fixture.response) }
        )

        do {
            _ = try await service.downloadAndImport(fixture.wallpaper)
            XCTFail("Expected an archive size mismatch")
        } catch let error as OfficialLivelyWallpaperDownloadError {
            XCTAssertEqual(
                error,
                .unexpectedArchiveSize(
                    expected: fixture.wallpaper.archiveByteCount,
                    actual: fixture.wallpaper.archiveByteCount + 1
                )
            )
        }
        XCTAssertTrue(try store.load().assets.isEmpty)
    }

    func testDownloadedSymlinkIsRejectedWithoutDeletingItsTarget() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let symlink = fixture.root.appending(path: "download-link.zip")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.archive)
        let store = LibraryStore(root: fixture.library)
        let service = OfficialLivelyWallpaperDownloadService(
            store: store,
            catalog: [fixture.wallpaper],
            downloader: { _ in (symlink, fixture.response) }
        )

        do {
            _ = try await service.downloadAndImport(fixture.wallpaper)
            XCTFail("Expected a no-follow downloaded-file rejection")
        } catch let error as OfficialLivelyWallpaperDownloadError {
            XCTAssertEqual(error, .unsafeDownloadedFile)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.archive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: symlink.path))
        XCTAssertTrue(try store.load().assets.isEmpty)
    }

    func testEntryOutsideInjectedCatalogCannotTurnDownloaderIntoArbitraryFetch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = LibraryStore(root: fixture.library)
        let service = OfficialLivelyWallpaperDownloadService(
            store: store,
            catalog: [],
            downloader: { _ in
                XCTFail("Unknown entries must be rejected before network access")
                return (fixture.archive, fixture.response)
            }
        )

        do {
            _ = try await service.downloadAndImport(fixture.wallpaper)
            XCTFail("Expected an unknown catalog entry")
        } catch let error as OfficialLivelyWallpaperDownloadError {
            XCTAssertEqual(error, .unknownWallpaper)
        }
    }

    func testURLSessionStyleCancellationIsNotReportedAsDownloadFailure() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = OfficialLivelyWallpaperDownloadService(
            store: LibraryStore(root: fixture.library),
            catalog: [fixture.wallpaper],
            downloader: { _ in
                await Task.yield()
                while !Task.isCancelled {
                    await Task.yield()
                }
                throw URLError(.cancelled)
            }
        )
        let task = Task {
            try await service.downloadAndImport(fixture.wallpaper)
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: the UI can report a cancellation instead of a failed download.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    func testProgressDownloadPublishesBytesThenVerificationAndImportPhases() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = OfficialLivelyProgressRecorder()
        let expectedBytes = fixture.wallpaper.archiveByteCount
        let service = OfficialLivelyWallpaperDownloadService(
            store: LibraryStore(root: fixture.library),
            catalog: [fixture.wallpaper],
            downloader: { _ in (fixture.archive, fixture.response) },
            progressDownloader: { _, passedExpectedBytes, progress in
                XCTAssertEqual(passedExpectedBytes, expectedBytes)
                progress(.downloading(
                    receivedBytes: expectedBytes / 2,
                    totalBytes: expectedBytes
                ))
                progress(.downloading(
                    receivedBytes: expectedBytes,
                    totalBytes: expectedBytes
                ))
                return (fixture.archive, fixture.response)
            }
        )

        _ = try await service.downloadAndImport(fixture.wallpaper) {
            recorder.append($0)
        }

        XCTAssertEqual(recorder.snapshot(), [
            .downloading(receivedBytes: 0, totalBytes: expectedBytes),
            .downloading(receivedBytes: expectedBytes / 2, totalBytes: expectedBytes),
            .downloading(receivedBytes: expectedBytes, totalBytes: expectedBytes),
            .verifying,
            .importing
        ])
    }

    func testBoundedDownloaderIsUsedEvenWhenCallerOmitsProgress() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = OfficialLivelyBoundedDownloadRecorder()
        let service = OfficialLivelyWallpaperDownloadService(
            store: LibraryStore(root: fixture.library),
            catalog: [fixture.wallpaper],
            downloader: { _ in
                XCTFail("The unbounded fallback must not run when a bounded downloader is configured")
                return (fixture.archive, fixture.response)
            },
            progressDownloader: { _, expectedBytes, _ in
                recorder.record(expectedBytes)
                return (fixture.archive, fixture.response)
            }
        )

        _ = try await service.downloadAndImport(fixture.wallpaper)

        XCTAssertEqual(recorder.snapshot(), [fixture.wallpaper.archiveByteCount])
    }

    func testBoundedDownloaderSizeDiagnosticIsPreservedByService() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let actualBytes = fixture.wallpaper.archiveByteCount + 1
        let service = OfficialLivelyWallpaperDownloadService(
            store: LibraryStore(root: fixture.library),
            catalog: [fixture.wallpaper],
            downloader: { _ in
                XCTFail("The unbounded fallback must not run")
                return (fixture.archive, fixture.response)
            },
            progressDownloader: { _, expectedBytes, _ in
                throw OfficialLivelyWallpaperDownloadError.unexpectedArchiveSize(
                    expected: expectedBytes,
                    actual: actualBytes
                )
            }
        )

        do {
            _ = try await service.downloadAndImport(fixture.wallpaper)
            XCTFail("Expected the bounded download size diagnostic")
        } catch let error as OfficialLivelyWallpaperDownloadError {
            XCTAssertEqual(
                error,
                .unexpectedArchiveSize(
                    expected: fixture.wallpaper.archiveByteCount,
                    actual: actualBytes
                )
            )
        }
    }

    func testProductionDownloadClientCompletesDelegateLifecycle() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("production-client-fixture".utf8)
        let url = URL(string: "https://github.com/rocksdanister/fixture/releases/download/v1/client.zip")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfficialLivelyURLProtocol.self]
        OfficialLivelyURLProtocol.install(payload: payload, for: url)
        defer { OfficialLivelyURLProtocol.reset() }
        let recorder = OfficialLivelyProgressRecorder()
        let client = OfficialLivelyWallpaperURLSessionDownloadClient(
            expectedByteCount: UInt64(payload.count),
            configuration: configuration,
            temporaryDirectory: root,
            progress: recorder.append
        )

        let (downloadedURL, response) = try await client.download(from: url)
        defer { try? FileManager.default.removeItem(at: downloadedURL) }

        XCTAssertEqual(try Data(contentsOf: downloadedURL), payload)
        XCTAssertEqual(response.url, url)
        XCTAssertTrue(recorder.snapshot().contains {
            if case .downloading(let received, _) = $0 {
                return received > 0 && received <= UInt64(payload.count)
            }
            return false
        })
    }

    func testProductionDownloadClientCancelsDeclaredOversizeBeforePublishingFile() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 0x41, count: 256 * 1_024)
        let expectedBytes: UInt64 = 16
        let url = URL(string: "https://github.com/rocksdanister/fixture/releases/download/v1/oversize.zip")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfficialLivelyURLProtocol.self]
        OfficialLivelyURLProtocol.install(payload: payload, for: url)
        defer { OfficialLivelyURLProtocol.reset() }
        let client = OfficialLivelyWallpaperURLSessionDownloadClient(
            expectedByteCount: expectedBytes,
            configuration: configuration,
            temporaryDirectory: root,
            progress: { _ in }
        )

        do {
            _ = try await client.download(from: url)
            XCTFail("Expected the oversized response to be cancelled")
        } catch let error as OfficialLivelyWallpaperDownloadError {
            XCTAssertEqual(
                error,
                .unexpectedArchiveSize(
                    expected: expectedBytes,
                    actual: UInt64(payload.count)
                )
            )
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private struct Fixture {
        let root: URL
        let library: URL
        let archive: URL
        let wallpaper: OfficialLivelyWallpaper
        let response: HTTPURLResponse
    }

    private func makeFixture(
        archiveSHA256: String? = nil,
        responseURL: URL? = nil
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "official-lively-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let library = root.appending(path: "Library", directoryHint: .isDirectory)
        let archive = root.appending(path: "download.zip")
        let archiveData = TinyZIP(entries: [
            ("LivelyInfo.json", Data(#"{"Title":"Official Fixture","Type":1,"FileName":"index.html","IsAbsolutePath":false}"#.utf8)),
            ("index.html", Data("<!doctype html><title>Official Fixture</title>".utf8)),
            ("License.txt", Data("Fixture license".utf8))
        ]).data()
        try archiveData.write(to: archive)
        let requestURL = URL(
            string: "https://github.com/rocksdanister/fixture/releases/download/v1/fixture.zip"
        )!
        let actualHash = try WallpaperContentHasher.hashFile(archive)
        let wallpaper = OfficialLivelyWallpaper(
            id: "rocksdanister-fixture-v1",
            title: "Official Fixture",
            summary: "Fixture",
            repositoryURL: URL(string: "https://github.com/rocksdanister/fixture")!,
            releaseURL: URL(string: "https://github.com/rocksdanister/fixture/releases/tag/v1")!,
            releaseTag: "v1",
            sourceCommit: String(repeating: "a", count: 40),
            downloadURL: requestURL,
            archiveFileName: "fixture.zip",
            archiveByteCount: UInt64(archiveData.count),
            archiveSHA256: archiveSHA256 ?? actualHash,
            licenseName: "MIT",
            licenseURL: URL(string: "https://github.com/rocksdanister/fixture/blob/v1/LICENSE")!
        )
        let response = try XCTUnwrap(HTTPURLResponse(
            url: responseURL ?? requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(archiveData.count)]
        ))
        return Fixture(
            root: root,
            library: library,
            archive: archive,
            wallpaper: wallpaper,
            response: response
        )
    }

    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "official-lively-client-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}

private final class OfficialLivelyURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Fixture {
        let url: URL
        let payload: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture: Fixture?

    static func install(payload: Data, for url: URL) {
        lock.withLock {
            fixture = Fixture(url: url, payload: payload)
        }
    }

    static func reset() {
        lock.withLock {
            fixture = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { request.url == fixture?.url }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let fixture = Self.lock.withLock { Self.fixture }
        guard let fixture,
              let response = HTTPURLResponse(
                url: fixture.url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(fixture.payload.count)]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class OfficialLivelyProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [OfficialLivelyWallpaperInstallProgress]()

    func append(_ value: OfficialLivelyWallpaperInstallProgress) {
        lock.withLock {
            values.append(value)
        }
    }

    func snapshot() -> [OfficialLivelyWallpaperInstallProgress] {
        lock.withLock { values }
    }
}

private final class OfficialLivelyBoundedDownloadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var expectedByteCounts = [UInt64]()

    func record(_ expectedByteCount: UInt64) {
        lock.withLock {
            expectedByteCounts.append(expectedByteCount)
        }
    }

    func snapshot() -> [UInt64] {
        lock.withLock { expectedByteCounts }
    }
}

private struct TinyZIP {
    let entries: [(name: String, data: Data)]

    init(entries: [(String, Data)]) {
        self.entries = entries.map { (name: $0.0, data: $0.1) }
    }

    func data() -> Data {
        var archive = Data()
        var central: [(name: Data, data: Data, crc: UInt32, offset: UInt32)] = []
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = Self.crc32(entry.data)
            let offset = UInt32(archive.count)
            archive.appendLE(UInt32(0x0403_4b50))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0x0800))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(crc)
            archive.appendLE(UInt32(entry.data.count))
            archive.appendLE(UInt32(entry.data.count))
            archive.appendLE(UInt16(name.count))
            archive.appendLE(UInt16(0))
            archive.append(name)
            archive.append(entry.data)
            central.append((name, entry.data, crc, offset))
        }
        let centralOffset = UInt32(archive.count)
        for entry in central {
            archive.appendLE(UInt32(0x0201_4b50))
            archive.appendLE(UInt16((3 << 8) | 20))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0x0800))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(entry.crc)
            archive.appendLE(UInt32(entry.data.count))
            archive.appendLE(UInt32(entry.data.count))
            archive.appendLE(UInt16(entry.name.count))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt32(S_IFREG | 0o644) << 16)
            archive.appendLE(entry.offset)
            archive.append(entry.name)
        }
        let centralSize = UInt32(archive.count) - centralOffset
        archive.appendLE(UInt32(0x0605_4b50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(centralSize)
        archive.appendLE(centralOffset)
        archive.appendLE(UInt16(0))
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        appendLE(UInt16(truncatingIfNeeded: value))
        appendLE(UInt16(truncatingIfNeeded: value >> 16))
    }
}
