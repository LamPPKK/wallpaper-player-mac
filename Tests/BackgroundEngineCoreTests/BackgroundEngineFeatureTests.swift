import Foundation
import XCTest
@testable import BackgroundEngineCore
import Darwin

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
        XCTAssertNil(WorkshopItemID(input: "https://user@steamcommunity.com/sharedfiles/filedetails/?id=123"))
        XCTAssertNil(WorkshopItemID(input: "https://steamcommunity.com/login/?id=123"))
        XCTAssertNil(
            WorkshopItemID(
                input: "https://steamcommunity.com/sharedfiles/filedetails/?id=123&id=456"
            )
        )
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

    func testSteamCMDRunnerCancellationForceKillsAndReapsActiveDownload() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "steamcmd.sh")
        let pidFile = root.appending(path: "active.pid")
        try """
        #!/bin/sh
        trap '' TERM
        echo $$ > "\(pidFile.path)"
        while :; do :; done
        """.write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let runner = SteamCMDRunner(paths: SteamCMDRuntimePaths(root: root))
        let itemID = try XCTUnwrap(WorkshopItemID(rawValue: "123456"))
        let download = Task { try await runner.download(itemID: itemID) }

        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let downloadingStatus = await runner.currentStatus()
        XCTAssertEqual(downloadingStatus.phase, .downloading)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))
        let cancellation = Task { await runner.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await runner.download(itemID: itemID)
            XCTFail("A new SteamCMD operation must not start until the cancelled child is reaped")
        } catch let error as SteamCMDRunnerError {
            XCTAssertEqual(error, .operationInProgress)
        }
        await cancellation.value

        do {
            _ = try await download.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let cancelledStatus = await runner.currentStatus()
        XCTAssertEqual(cancelledStatus.phase, .cancelled)
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "Cancelled SteamCMD process must be fully reaped")
        XCTAssertEqual(errno, ESRCH)
    }

    func testSteamCMDRunnerPublishesLiveProgressFromBoundedOutputTail() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "steamcmd.sh")
        let itemID = try XCTUnwrap(WorkshopItemID(rawValue: "123456"))
        let downloaded = SteamCMDRuntimePaths(root: root).workshopItem(itemID)
        try """
        #!/bin/sh
        set -eu
        printf '%s\n' ' Update state (0x61) downloading, progress: 42.50 (123 / 456)'
        /bin/sleep 1
        /bin/mkdir -p "\(downloaded.path)"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let runner = SteamCMDRunner(paths: SteamCMDRuntimePaths(root: root))
        let download = Task { try await runner.download(itemID: itemID) }

        var observedProgress: Double?
        for _ in 0..<50 {
            observedProgress = await runner.currentStatus().progress
            if observedProgress != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(try XCTUnwrap(observedProgress), 0.425, accuracy: 0.0001)
        let result = try await download.value
        XCTAssertEqual(result.standardizedFileURL, downloaded.standardizedFileURL)
        let diagnostics = await runner.diagnostics()
        XCTAssertLessThanOrEqual(diagnostics.recentOutput.count, 80)
        XCTAssertTrue(diagnostics.recentOutput.contains { $0.contains("progress: 42.50") })
    }

    func testSteamCMDRunnerRejectsSymlinkedRuntimeExecutableWithoutLaunchingIt() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "steamcmd.sh"),
            withDestinationURL: URL(filePath: "/usr/bin/true")
        )
        let runner = SteamCMDRunner(paths: SteamCMDRuntimePaths(root: root))

        do {
            try await runner.installIfNeeded()
            XCTFail("A symlink must never be launched as the downloaded SteamCMD runtime")
        } catch let error as SteamCMDRunnerError {
            XCTAssertEqual(error, .unsafeRuntimeExecutable)
        }
        let diagnostics = await runner.diagnostics()
        XCTAssertFalse(diagnostics.executablePresent)
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

    func testStandaloneGIFImporterDeduplicatesByContentHash() async throws {
        let source = try makeDirectory().appending(path: "loop.gif")
        try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        ).write(to: source)
        let library = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: library)
        }
        let importer = WallpaperImporter(store: LibraryStore(root: library))

        let first = try await importer.importMediaFile(source)
        let second = try await importer.importMediaFile(source)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.kind, .image)
        XCTAssertNotNil(first.contentHash)
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

    func testDuplicateDisplayAssignmentsAreNormalizedWithoutCrashingPlaybackState() throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let store = LibraryStore(root: library)

        try store.replaceDisplayAssignments([
            DisplayAssignment(displayUUID: "display-1", assetID: nil, displayMode: .fit, quality: .low),
            DisplayAssignment(displayUUID: "display-1", assetID: nil, displayMode: .fill, quality: .high),
            DisplayAssignment(displayUUID: "display-2", assetID: nil, displayMode: .stretch)
        ])

        let assignments = try store.load().displayAssignments
        XCTAssertEqual(assignments.map(\.displayUUID), ["display-1", "display-2"])
        XCTAssertEqual(assignments.first?.displayMode, .fill)
        XCTAssertEqual(assignments.first?.quality, .high)
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
