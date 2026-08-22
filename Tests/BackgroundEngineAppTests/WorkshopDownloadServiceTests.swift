import Darwin
import Foundation
import XCTest
@testable import BackgroundEngineApp
import BackgroundEngineCore

final class WorkshopDownloadServiceTests: XCTestCase {
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
        let importer = WallpaperImporter(
            store: LibraryStore(root: library),
            videoConverter: VideoConverter(resolver: MediaToolResolver(
                bundleResourceURL: runtime,
                environment: [:],
                allowDevelopmentFallback: false
            )),
            convertedVideoCacheDirectory: cache
        )
        let service = WorkshopDownloadService(
            importer: importer,
            steamCMD: FixtureSteamCMD(project: project)
        )
        let download = Task { try await service.downloadAndImport(input: "123456") }
        try await waitForFile(started)
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
        printf '%s' '{"streams":[{"index":0,"codec_type":"video"}],"format":{"format_name":"matroska","size":"5"}}'
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
