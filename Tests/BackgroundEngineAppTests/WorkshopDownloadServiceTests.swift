import Darwin
import Foundation
import XCTest
@testable import BackgroundEngineApp
@testable import BackgroundEngineCore

final class WorkshopDownloadServiceTests: XCTestCase {
    func testWillImportCallbackRunsBeforeWorkshopLibraryMutation() async throws {
        let fixtureRoot = try makeDirectory()
        let project = fixtureRoot.appending(path: "123456")
        let library = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: fixtureRoot)
            try? FileManager.default.removeItem(at: library)
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "<!doctype html><title>Workshop</title>".write(
            to: project.appending(path: "index.html"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"title":"Workshop Web","type":"web","file":"index.html"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        let store = LibraryStore(root: library)
        let observation = WorkshopWillImportObservation()
        let service = WorkshopDownloadService(
            importer: WallpaperImporter(store: store),
            steamCMD: FixtureSteamCMD(project: project)
        )

        let imported = try await service.downloadAndImport(input: "123456") { candidate in
            await observation.record(
                candidate: candidate,
                persistedAssetCount: (try? store.load().assets.count) ?? -1
            )
        }

        let captured = await observation.value()
        XCTAssertEqual(captured?.candidate.workshopId, "123456")
        XCTAssertEqual(captured?.persistedAssetCount, 0)
        XCTAssertEqual(imported.kind, .web)
        XCTAssertEqual(try store.load().assets.count, 1)
    }

    func testPublishesImportingThenCompletedWhileWillImportIsSuspended() async throws {
        let fixtureRoot = try makeDirectory()
        let project = fixtureRoot.appending(path: "123456")
        let library = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: fixtureRoot)
            try? FileManager.default.removeItem(at: library)
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "<!doctype html><title>Workshop</title>".write(
            to: project.appending(path: "index.html"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"title":"Workshop Web","type":"web","file":"index.html"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        let gate = WorkshopCancellationGate()
        let service = WorkshopDownloadService(
            importer: WallpaperImporter(store: LibraryStore(root: library)),
            steamCMD: FixtureSteamCMD(project: project)
        )
        let download = Task {
            try await service.downloadAndImport(input: "123456") { _ in
                await gate.wait()
            }
        }
        while !(await gate.hasWaiter()) { await Task.yield() }

        let importing = try await service.status()
        XCTAssertEqual(importing.itemID, "123456")
        XCTAssertEqual(importing.phase, .importing)
        XCTAssertNil(importing.progress)

        await gate.release()
        let imported = try await download.value
        let completed = try await service.status()
        XCTAssertEqual(imported.workshopId, "123456")
        XCTAssertEqual(completed.itemID, "123456")
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.progress, 1)
    }

    func testPublishesFailedWhenDownloadedProjectIsMissing() async throws {
        let emptyProject = try makeDirectory()
        let library = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: emptyProject)
            try? FileManager.default.removeItem(at: library)
        }
        let service = WorkshopDownloadService(
            importer: WallpaperImporter(store: LibraryStore(root: library)),
            steamCMD: FixtureSteamCMD(project: emptyProject)
        )

        do {
            _ = try await service.downloadAndImport(input: "123456")
            XCTFail("An empty Workshop directory must fail import")
        } catch let error as WorkshopDownloadServiceError {
            guard case .downloadedProjectMissing("123456") = error else {
                return XCTFail("Unexpected service error: \(error)")
            }
        }
        let failed = try await service.status()
        XCTAssertEqual(failed.itemID, "123456")
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertNil(failed.progress)
        XCTAssertTrue(failed.message.contains("no valid Wallpaper Engine project"))
    }

    func testPublishesCancelledWhenImportIsCancelledAtWillImportGate() async throws {
        let fixtureRoot = try makeDirectory()
        let project = fixtureRoot.appending(path: "123456")
        let library = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: fixtureRoot)
            try? FileManager.default.removeItem(at: library)
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "<!doctype html><title>Workshop</title>".write(
            to: project.appending(path: "index.html"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"title":"Workshop Web","type":"web","file":"index.html"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        let gate = WorkshopCancellationGate()
        let service = WorkshopDownloadService(
            importer: WallpaperImporter(store: LibraryStore(root: library)),
            steamCMD: FixtureSteamCMD(project: project)
        )
        let download = Task {
            try await service.downloadAndImport(input: "123456") { _ in
                await gate.wait()
            }
        }
        while !(await gate.hasWaiter()) { await Task.yield() }

        download.cancel()
        await gate.release()
        await XCTAssertThrowsCancellation(download)

        let cancelled = try await service.status()
        XCTAssertEqual(cancelled.itemID, "123456")
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertNil(cancelled.progress)
        XCTAssertEqual(try LibraryStore(root: library).load().assets.count, 0)
    }

    func testCancelledOperationKeepsExclusiveOwnershipUntilItUnwinds() async throws {
        let fixtureRoot = try makeDirectory()
        let project = fixtureRoot.appending(path: "123456")
        let library = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: fixtureRoot)
            try? FileManager.default.removeItem(at: library)
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "<!doctype html><title>Workshop</title>".write(
            to: project.appending(path: "index.html"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"title":"Workshop Web","type":"web","file":"index.html"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        let gate = WorkshopCancellationGate()
        let steamCMD = RecordingSteamCMD(project: project)
        let service = WorkshopDownloadService(
            importer: WallpaperImporter(store: LibraryStore(root: library)),
            steamCMD: steamCMD
        )
        let first = Task {
            try await service.downloadAndImport(input: "123456") { _ in
                await gate.wait()
            }
        }
        while !(await gate.hasWaiter()) { await Task.yield() }

        first.cancel()
        do {
            _ = try await service.downloadAndImport(input: "123456")
            XCTFail("A replacement download must wait for the cancelled operation to unwind")
        } catch WorkshopDownloadServiceError.operationInProgress {
        } catch {
            XCTFail("Expected operationInProgress, got \(error)")
        }
        let callsBeforeUnwind = await steamCMD.installCallCount()
        XCTAssertEqual(callsBeforeUnwind, 1)
        let statusBeforeUnwind = try await service.status()
        XCTAssertEqual(statusBeforeUnwind.itemID, "123456")
        XCTAssertEqual(statusBeforeUnwind.phase, .importing)

        await gate.release()
        await XCTAssertThrowsCancellation(first)
        let restarted = try await service.downloadAndImport(input: "123456")

        XCTAssertEqual(restarted.workshopId, "123456")
        let installCalls = await steamCMD.installCallCount()
        let downloadCalls = await steamCMD.downloadCallCount()
        XCTAssertEqual(installCalls, 2)
        XCTAssertEqual(downloadCalls, 2)
        let completed = try await service.status()
        XCTAssertEqual(completed.itemID, "123456")
        XCTAssertEqual(completed.phase, .completed)
    }

    func testExactSteamCMDReceiptAutomaticallyImportsFreshProject() async throws {
        let runtime = try makeDirectory()
        let library = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(at: library)
        }
        let itemID = try XCTUnwrap(WorkshopItemID(rawValue: "123456"))
        let paths = SteamCMDRuntimePaths(root: runtime)
        let project = paths.workshopItem(itemID)
        let executable = paths.executable
        try """
        #!/bin/sh
        /bin/mkdir -p "\(project.path)"
        /usr/bin/printf '%s' '{"title":"Receipt Project","type":"web","file":"index.html"}' > "\(project.appending(path: "project.json").path)"
        /usr/bin/printf '%s' '<!doctype html><title>Receipt Project</title>' > "\(project.appending(path: "index.html").path)"
        /usr/bin/printf '%s\n' 'Success. Downloaded item \(itemID.rawValue).'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let store = LibraryStore(root: library)
        let service = WorkshopDownloadService(
            importer: WallpaperImporter(store: store),
            steamCMD: RunnerBackedSteamCMD(runner: SteamCMDRunner(paths: paths))
        )

        let imported = try await service.downloadAndImport(input: itemID.rawValue)

        XCTAssertEqual(imported.id, itemID.rawValue)
        XCTAssertEqual(imported.workshopId, itemID.rawValue)
        XCTAssertEqual(imported.source, .steamCMD)
        XCTAssertEqual(imported.kind, .web)
        let stored = try XCTUnwrap(store.load().assets.first)
        XCTAssertEqual(stored.id, imported.id)
        XCTAssertEqual(stored.workshopId, imported.workshopId)
        XCTAssertEqual(stored.contentHash, imported.contentHash)
        XCTAssertEqual(stored.projectDirectory, imported.projectDirectory)
    }

    func testCancellationBeforeServiceDispatchDoesNotInstallSteamCMD() async throws {
        let project = try makeDirectory()
        let library = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: library)
        }
        let steamCMD = RecordingSteamCMD(project: project)
        let service = WorkshopDownloadService(
            importer: WallpaperImporter(store: LibraryStore(root: library)),
            steamCMD: steamCMD
        )
        let gate = WorkshopCancellationGate()
        let task = Task {
            await gate.wait()
            return try await service.downloadAndImport(input: "123456")
        }
        while !(await gate.hasWaiter()) { await Task.yield() }

        task.cancel()
        await gate.release()

        await XCTAssertThrowsCancellation(task)
        let installCalls = await steamCMD.installCallCount()
        let downloadCalls = await steamCMD.downloadCallCount()
        XCTAssertEqual(installCalls, 0)
        XCTAssertEqual(downloadCalls, 0)
    }

    func testCancellationAfterDurableImportIsReportedWithoutCompletedState() async throws {
        let fixtureRoot = try makeDirectory()
        let project = fixtureRoot.appending(path: "123456")
        let library = try makeDirectory()
        let runtimeRoot = try makeDirectory()
        let cache = try makeDirectory()
        let control = try makeDirectory()
        defer {
            for url in [fixtureRoot, library, runtimeRoot, cache, control] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: project.appending(path: "wallpaper.mkv"))
        try #"{"title":"Workshop Fixture","type":"video","file":"wallpaper.mkv"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        let started = control.appending(path: "started")
        let pidFile = control.appending(path: "pid")
        let runtime = try makeHangingMediaRuntime(
            in: runtimeRoot,
            started: started,
            pidFile: pidFile
        )
        let mediaToolResolver = MediaToolResolver(
            bundleResourceURL: runtime,
            environment: [:],
            allowDevelopmentFallback: false
        )
        let importer = WallpaperImporter(
            store: LibraryStore(root: library),
            scanner: WallpaperScanner(contentProbe: MediaContentProbe(
                mediaProbe: MediaProbe(resolver: mediaToolResolver)
            )),
            videoConverter: VideoConverter(resolver: mediaToolResolver),
            convertedVideoCacheDirectory: cache
        )
        let service = WorkshopDownloadService(
            importer: importer,
            steamCMD: FixtureSteamCMD(project: project)
        )
        let download = Task { try await service.downloadAndImport(input: "123456") }
        do {
            try await waitForFile(started)
        } catch {
            download.cancel()
            _ = try? await download.value
            throw error
        }
        let pid = try XCTUnwrap(
            Int32(try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )

        download.cancel()
        let preserved: WallpaperAsset
        do {
            _ = try await download.value
            return XCTFail("A cancelled outer Workshop task must not report Completed")
        } catch WorkshopDownloadServiceError.cancelledAfterImport(let imported) {
            preserved = imported
        }

        XCTAssertEqual(preserved.id, "123456")
        XCTAssertEqual(preserved.source, .steamCMD)
        XCTAssertEqual(preserved.issues.first?.code, "automatic_conversion_cancelled")
        XCTAssertEqual(try LibraryStore(root: library).load().assets.first, preserved)
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "Cancelled FFmpeg must be reaped before service returns")
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "background-engine-workshop-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(url.lastPathComponent)")
        throw CocoaError(.fileNoSuchFile)
    }

    private func makeHangingMediaRuntime(
        in root: URL,
        started: URL,
        pidFile: URL
    ) throws -> URL {
        let tools = root.appending(path: "MediaTools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let ffmpeg = tools.appending(path: "ffmpeg")
        let ffprobe = tools.appending(path: "ffprobe")
        try """
        #!/bin/sh
        trap '' TERM
        printf '%s' "$$" > "\(pidFile.path)"
        : > "\(started.path)"
        while :; do sleep 1; done
        """.write(to: ffmpeg, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf '%s' '{"streams":[{"index":0,"codec_type":"video","width":32,"height":32}],"format":{"format_name":"matroska","size":"5"}}'
        """.write(to: ffprobe, atomically: true, encoding: .utf8)
        for executable in [ffmpeg, ffprobe] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        return root
    }
}

private func XCTAssertThrowsCancellation<T: Sendable>(
    _ task: Task<T, any Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await task.value
        XCTFail("Expected cancellation", file: file, line: line)
    } catch is CancellationError {
    } catch {
        XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
    }
}

private actor WorkshopCancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func hasWaiter() -> Bool { continuation != nil }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor WorkshopWillImportObservation {
    struct Value: Sendable {
        let candidate: WallpaperAsset
        let persistedAssetCount: Int
    }

    private var captured: Value?

    func record(candidate: WallpaperAsset, persistedAssetCount: Int) {
        captured = Value(candidate: candidate, persistedAssetCount: persistedAssetCount)
    }

    func value() -> Value? { captured }
}

private actor RecordingSteamCMD: SteamCMDServicing {
    private let project: URL
    private var installs = 0
    private var downloads = 0

    init(project: URL) { self.project = project }

    func install() async throws { installs += 1 }
    func download(itemID: WorkshopItemID) async throws -> URL {
        downloads += 1
        return project
    }
    func cancel() async {}
    func status() async throws -> WorkshopDownloadStatus {
        WorkshopDownloadStatus(itemID: nil, phase: .idle, progress: nil, message: "Idle")
    }
    func diagnostics() async throws -> SteamCMDDiagnostics {
        SteamCMDDiagnostics(
            runtimePath: project.path,
            executablePresent: true,
            activeItemID: nil,
            phase: .idle,
            recentOutput: []
        )
    }
    func installCallCount() -> Int { installs }
    func downloadCallCount() -> Int { downloads }
}

private actor FixtureSteamCMD: SteamCMDServicing {
    let project: URL

    init(project: URL) {
        self.project = project
    }

    func install() async throws {}

    func download(itemID: WorkshopItemID) async throws -> URL {
        project
    }

    func cancel() async {}

    func status() async throws -> WorkshopDownloadStatus {
        WorkshopDownloadStatus(itemID: nil, phase: .idle, progress: nil, message: "Idle")
    }

    func diagnostics() async throws -> SteamCMDDiagnostics {
        SteamCMDDiagnostics(
            runtimePath: project.path,
            executablePresent: true,
            activeItemID: nil,
            phase: .idle,
            recentOutput: []
        )
    }
}

private actor RunnerBackedSteamCMD: SteamCMDServicing {
    let runner: SteamCMDRunner

    init(runner: SteamCMDRunner) {
        self.runner = runner
    }

    func install() async throws {
        try await runner.installIfNeeded()
    }

    func download(itemID: WorkshopItemID) async throws -> URL {
        try await runner.download(itemID: itemID)
    }

    func cancel() async {
        await runner.cancel()
    }

    func status() async throws -> WorkshopDownloadStatus {
        await runner.currentStatus()
    }

    func diagnostics() async throws -> SteamCMDDiagnostics {
        await runner.diagnostics()
    }
}
