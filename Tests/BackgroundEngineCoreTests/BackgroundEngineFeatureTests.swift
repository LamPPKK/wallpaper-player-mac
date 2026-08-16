import Foundation
import XCTest
@testable import BackgroundEngineCore

final class BackgroundEngineFeatureTests: XCTestCase {
    func testWorkshopItemParserAcceptsNumericIDAndOfficialURL() {
        XCTAssertEqual(WorkshopItemID(input: "123456789")?.rawValue, "123456789")
        XCTAssertEqual(
            WorkshopItemID(input: "https://steamcommunity.com/sharedfiles/filedetails/?id=987654321")?.rawValue,
            "987654321"
        )
    }

    func testWorkshopItemParserRejectsCommandsAndUntrustedHosts() {
        XCTAssertNil(WorkshopItemID(input: "123; rm -rf /"))
        XCTAssertNil(WorkshopItemID(input: "https://example.com/?id=123"))
        XCTAssertNil(WorkshopItemID(input: "https://steamcommunity.com/?id=0"))
    }

    func testSteamCMDCommandIsAnonymousAndCannotContainShellCommands() throws {
        let itemID = try XCTUnwrap(WorkshopItemID(rawValue: "123456"))
        let command = SteamCMDCommandBuilder.download(
            itemID: itemID,
            runtime: URL(filePath: "/tmp/Background Engine/SteamCMD")
        )
        XCTAssertEqual(Array(command.arguments.suffix(4)), ["+workshop_download_item", "431960", "123456", "+quit"])
        XCTAssertTrue(command.arguments.contains("anonymous"))
        XCTAssertFalse(command.arguments.contains(where: { $0.contains(";") || $0.contains("|") }))
    }

    func testSteamCMDRunnerCancellationTerminatesActiveDownload() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "steamcmd.sh")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let runner = SteamCMDRunner(paths: SteamCMDRuntimePaths(root: root))
        let itemID = try XCTUnwrap(WorkshopItemID(rawValue: "123456"))
        let download = Task { try await runner.download(itemID: itemID) }

        for _ in 0..<100 {
            if await runner.currentStatus().phase == .downloading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let downloadingStatus = await runner.currentStatus()
        XCTAssertEqual(downloadingStatus.phase, .downloading)
        await runner.cancel()

        do {
            _ = try await download.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let cancelledStatus = await runner.currentStatus()
        XCTAssertEqual(cancelledStatus.phase, .cancelled)
    }

    func testApplicationWallpaperIsRecognizedAsUnsupported() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"title":"Windows App","type":"application","file":"wallpaper.exe"}"#.write(
            to: root.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        try Data([0x4d, 0x5a]).write(to: root.appending(path: "wallpaper.exe"))

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)
        XCTAssertEqual(asset.kind, .application)
        XCTAssertEqual(asset.supportStatus, .unsupported)
        XCTAssertEqual(asset.compatibility?.label, "Unsupported")
        XCTAssertTrue(asset.issues.contains(where: { $0.code == "windows_application_unsupported" }))
    }

    func testVersionOneManifestMigratesWithoutLosingAssets() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let json = #"{"generatedAt":"2026-01-01T00:00:00Z","assets":[]}"#
        try json.write(to: root.appending(path: "library.json"), atomically: true, encoding: .utf8)

        let manifest = try LibraryStore(root: root).load()
        XCTAssertEqual(manifest.schemaVersion, LibraryManifest.currentSchemaVersion)
        XCTAssertEqual(manifest.assets, [])
        XCTAssertEqual(manifest.displayAssignments, [])
    }

    func testImporterRejectsSymbolicLinks() async throws {
        let source = try makeDirectory()
        let destination = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try "{}".write(to: source.appending(path: "project.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: source.appending(path: "escape"),
            withDestinationURL: URL(filePath: "/tmp")
        )
        let importer = WallpaperImporter(store: LibraryStore(root: destination))

        do {
            _ = try await importer.scan(root: source)
            XCTFail("Expected a symbolic-link rejection")
        } catch let error as WallpaperImportError {
            guard case .symbolicLink = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testImporterDeduplicatesIdenticalContentHash() async throws {
        let sourceA = try makeVideoProject(id: "one")
        let sourceB = try makeVideoProject(id: "two")
        let library = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceA)
            try? FileManager.default.removeItem(at: sourceB)
            try? FileManager.default.removeItem(at: library)
        }
        let importer = WallpaperImporter(store: LibraryStore(root: library))
        let scanA = try await importer.scan(root: sourceA)
        let scanB = try await importer.scan(root: sourceB)
        let assetA = try XCTUnwrap(scanA.assets.first)
        let assetB = try XCTUnwrap(scanB.assets.first)

        let importedA = try await importer.importAsset(assetA)
        let importedB = try await importer.importAsset(assetB)
        XCTAssertEqual(importedB.id, importedA.id)
        XCTAssertNotNil(importedA.contentHash)
        XCTAssertEqual(try LibraryStore(root: library).load().assets.count, 1)
    }

    func testDisplayAssignmentPersistsAndClearsWhenAssetIsRemoved() async throws {
        let source = try makeVideoProject(id: "assigned")
        let library = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }
        let importer = WallpaperImporter(store: LibraryStore(root: library))
        let scan = try await importer.scan(root: source)
        let scanned = try XCTUnwrap(scan.assets.first)
        let asset = try await importer.importAsset(scanned)
        let store = LibraryStore(root: library)
        try store.saveDisplayAssignment(
            DisplayAssignment(
                displayUUID: "display-1",
                assetID: asset.id,
                displayMode: .fill,
                quality: .high,
                audioSource: .primaryDisplay
            )
        )
        XCTAssertEqual(try store.load().displayAssignments.first?.assetID, asset.id)

        try store.removeAsset(id: asset.id)
        let cleared = try XCTUnwrap(try store.load().displayAssignments.first)
        XCTAssertNil(cleared.assetID)
        XCTAssertEqual(cleared.audioSource, .muted)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "background-engine-feature-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeVideoProject(id: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "background-engine-\(id)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"title":"Duplicate","type":"video","file":"video.mp4"}"#.write(
            to: root.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        try Data([0, 1, 2, 3, 4]).write(to: root.appending(path: "video.mp4"))
        return root
    }
}
