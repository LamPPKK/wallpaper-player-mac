import Foundation
import XCTest
@_spi(LivelyCatalog) @testable import BackgroundEngineCore

final class OfficialLivelyWallpaperCatalogTests: XCTestCase {
    func testCatalogPinsOfficialReleaseArchivesWithoutBundlingLicensedContent() throws {
        let wallpapers = OfficialLivelyWallpaperCatalog.wallpapers

        XCTAssertEqual(wallpapers.map(\.id), [
            "rocksdanister-rain-v3",
            "rocksdanister-snow-v1",
            "rocksdanister-clouds-v1"
        ])
        XCTAssertEqual(Set(wallpapers.map(\.licenseName)), ["CC BY-NC-SA 3.0"])
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
