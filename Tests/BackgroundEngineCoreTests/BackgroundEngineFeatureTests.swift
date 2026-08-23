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

        var observedPID: Int32?
        for _ in 0..<100 {
            if let value = try? String(contentsOf: pidFile, encoding: .utf8),
               let parsed = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                observedPID = parsed
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let downloadingStatus = await runner.currentStatus()
        XCTAssertEqual(downloadingStatus.phase, .downloading)
        let pid = try XCTUnwrap(observedPID)
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

    func testSteamCMDTaskCancellationKillsWrapperAndTermResistantChild() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "steamcmd.sh")
        let parentPIDFile = root.appending(path: "parent.pid")
        let childPIDFile = root.appending(path: "child.pid")
        try """
        #!/bin/sh
        trap '' TERM
        echo $$ > "\(parentPIDFile.path)"
        /bin/sh -c 'trap "" TERM; echo $$ > "$1"; while :; do /bin/sleep 1; done' child "\(childPIDFile.path)"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let runner = SteamCMDRunner(paths: SteamCMDRuntimePaths(root: root))
        let itemID = try XCTUnwrap(WorkshopItemID(rawValue: "123456"))
        let download = Task { try await runner.download(itemID: itemID) }
        defer { download.cancel() }

        let parentPID = try await waitForProcessIdentifier(at: parentPIDFile)
        let childPID = try await waitForProcessIdentifier(at: childPIDFile)
        let parentProcessGroup = Darwin.getpgid(parentPID)
        XCTAssertGreaterThan(parentProcessGroup, 1)
        XCTAssertEqual(Darwin.getpgid(childPID), parentProcessGroup)
        XCTAssertNotEqual(parentProcessGroup, Darwin.getpgrp(), "SteamCMD must not share the test runner's group")

        download.cancel()
        do {
            _ = try await download.value
            XCTFail("Expected task cancellation")
        } catch is CancellationError {
            // Expected.
        }
        for _ in 0..<50 where Darwin.kill(childPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(Darwin.kill(parentPID, 0), -1, "The SteamCMD wrapper must be reaped")
        XCTAssertEqual(Darwin.kill(childPID, 0), -1, "The SteamCMD child must not be orphaned")
    }

    func testSteamCMDProcessSupervisorKillsGroupWhenParentLifecycleCloses() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "steamcmd.sh")
        let parentPIDFile = root.appending(path: "parent.pid")
        let childPIDFile = root.appending(path: "child.pid")
        let log = root.appending(path: "supervisor.log")
        try """
        #!/bin/sh
        trap '' TERM
        echo $$ > "\(parentPIDFile.path)"
        /bin/sh -c 'trap "" TERM; echo $$ > "$1"; while :; do /bin/sleep 1; done' child "\(childPIDFile.path)"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        let supervisor = try SteamCMDChildProcess.spawn(
            executable: executable,
            arguments: [],
            currentDirectory: root,
            standardOutput: logHandle,
            standardError: logHandle,
            outputFileLimit: nil
        )
        defer { supervisor.closeLifecycle() }

        let parentPID = try await waitForProcessIdentifier(at: parentPIDFile)
        let childPID = try await waitForProcessIdentifier(at: childPIDFile)
        XCTAssertEqual(Darwin.getpgid(supervisor.processIdentifier), supervisor.processIdentifier)
        XCTAssertEqual(Darwin.getpgid(parentPID), supervisor.processIdentifier)
        XCTAssertEqual(Darwin.getpgid(childPID), supervisor.processIdentifier)

        supervisor.closeLifecycle()
        let terminationStatus = await supervisor.waitUntilExit()
        XCTAssertEqual(terminationStatus, 128 + SIGKILL)
        for _ in 0..<50 where Darwin.kill(childPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(Darwin.kill(parentPID, 0), -1)
        XCTAssertEqual(Darwin.kill(childPID, 0), -1)
    }

    func testSteamCMDProcessSupervisorClosesUnrelatedFileDescriptors() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "steamcmd.sh")
        let log = root.appending(path: "descriptor.log")
        let unrelatedPipe = Pipe()
        defer {
            try? unrelatedPipe.fileHandleForReading.close()
            try? unrelatedPipe.fileHandleForWriting.close()
        }
        let unrelatedFD = unrelatedPipe.fileHandleForWriting.fileDescriptor
        XCTAssertEqual(Darwin.fcntl(unrelatedFD, F_SETFD, 0), 0)
        try """
        #!/bin/sh
        eval "printf inherited >&$1" 2>/dev/null || true
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }

        let supervisor = try SteamCMDChildProcess.spawn(
            executable: executable,
            arguments: [String(unrelatedFD)],
            currentDirectory: root,
            standardOutput: logHandle,
            standardError: logHandle,
            outputFileLimit: nil
        )

        let terminationStatus = await supervisor.waitUntilExit()
        XCTAssertEqual(terminationStatus, 0)
        try unrelatedPipe.fileHandleForWriting.close()
        XCTAssertTrue(unrelatedPipe.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    func testSteamCMDProcessSupervisorKillsBackgroundHelperAfterNormalExit() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "steamcmd.sh")
        let helperPIDFile = root.appending(path: "helper.pid")
        let log = root.appending(path: "helper.log")
        try """
        #!/bin/sh
        /bin/sh -c 'trap "" TERM; echo $$ > "$1"; while :; do /bin/sleep 1; done' helper "\(helperPIDFile.path)" &
        while [ ! -s "\(helperPIDFile.path)" ]; do /bin/sleep 0.01; done
        exit 0
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }

        let supervisor = try SteamCMDChildProcess.spawn(
            executable: executable,
            arguments: [],
            currentDirectory: root,
            standardOutput: logHandle,
            standardError: logHandle,
            outputFileLimit: nil
        )

        let terminationStatus = await supervisor.waitUntilExit()
        XCTAssertEqual(terminationStatus, 0)
        let helperPID = try XCTUnwrap(
            Int32(try String(contentsOf: helperPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        for _ in 0..<50 where Darwin.kill(helperPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(Darwin.kill(helperPID, 0), -1, "A helper must not outlive a completed SteamCMD run")
        XCTAssertEqual(errno, ESRCH)
    }

    func testProcessSupervisorDoesNotReportTimeoutAfterWaiterRecordedExit() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = try spawnImmediateExitSupervisor(in: root)

        for _ in 0..<100 where supervisor.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(supervisor.isRunning)

        let (asyncStatus, asyncTimedOut) = try await supervisor.waitUntilExit(
            timeout: .milliseconds(1)
        )
        XCTAssertEqual(asyncStatus, 0)
        XCTAssertFalse(asyncTimedOut)

        let (blockingStatus, blockingTimedOut) = supervisor.waitUntilExit(timeout: 0.001)
        XCTAssertEqual(blockingStatus, 0)
        XCTAssertFalse(blockingTimedOut)
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

    func testSteamCMDArchiveListingRejectsTraversalDuplicatesAndRuntimeDataCollisions() throws {
        let valid = [
            "./Frameworks/",
            "./Frameworks/Breakpad.framework/",
            "./steamcmd",
            "./steamcmd.sh"
        ]
        XCTAssertEqual(
            try SteamCMDArchiveValidator.validateListedPaths(valid),
            ["Frameworks", "Frameworks/Breakpad.framework", "steamcmd", "steamcmd.sh"]
        )

        for unsafe in [
            ["./steamcmd", "./steamcmd.sh", "../escape"],
            ["./steamcmd", "./steamcmd.sh", "/tmp/escape"],
            ["./steamcmd", "./steamcmd.sh", "steamapps/workshop/content"],
            ["./steamcmd", "./steamcmd.sh", "Frameworks", "./Frameworks/"]
        ] {
            XCTAssertThrowsError(try SteamCMDArchiveValidator.validateListedPaths(unsafe)) { error in
                XCTAssertEqual(error as? SteamCMDRuntimeError, .installerArchiveUnsafe)
            }
        }
    }

    func testSteamCMDExtractedTreeAllowsInternalFrameworkLinksAndRejectsEscapes() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("#!/bin/sh\n".utf8).write(to: root.appending(path: "steamcmd.sh"))
        try Data("Mach-O placeholder".utf8).write(to: root.appending(path: "steamcmd"))
        let versions = root.appending(path: "Frameworks/Breakpad.framework/Versions")
        try FileManager.default.createDirectory(
            at: versions.appending(path: "A/Resources"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: versions.appending(path: "Current").path,
            withDestinationPath: "A"
        )

        XCTAssertNoThrow(try SteamCMDArchiveValidator.validateExtractedTree(at: root))

        try FileManager.default.createSymbolicLink(
            atPath: root.appending(path: "escape").path,
            withDestinationPath: "/tmp"
        )
        XCTAssertThrowsError(try SteamCMDArchiveValidator.validateExtractedTree(at: root)) { error in
            XCTAssertEqual(error as? SteamCMDRuntimeError, .installerArchiveUnsafe)
        }
    }

    func testSteamCMDVerboseArchiveListingRejectsUnsupportedNodesAndExpansionBombs() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = root.appending(path: "metadata.txt")
        try """
        drwxr-xr-x  0 501  80  0 Apr 3 2020 ./Frameworks/
        lrwxr-xr-x  0 501  80  0 Apr 3 2020 ./Frameworks/Current -> Versions/A
        -rwxr-xr-x  0 501  80  4638880 Apr 3 2020 ./steamcmd
        -rwxr-xr-x  0 501  80  1166 Apr 3 2020 ./steamcmd.sh
        """.write(to: listing, atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try SteamCMDArchiveValidator.validateVerboseListing(at: listing))

        try "prw-r--r--  0 501  80  0 Apr 3 2020 ./command-pipe\n"
            .write(to: listing, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SteamCMDArchiveValidator.validateVerboseListing(at: listing)) { error in
            XCTAssertEqual(error as? SteamCMDRuntimeError, .installerArchiveUnsafe)
        }

        try "-rw-r--r--  0 501  80  \(SteamCMDArchiveValidator.maximumExpandedBytes + 1) Apr 3 2020 ./bomb\n"
            .write(to: listing, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SteamCMDArchiveValidator.validateVerboseListing(at: listing)) { error in
            XCTAssertEqual(error as? SteamCMDRuntimeError, .installerArchiveUnsafe)
        }
    }

    func testSteamCMDInstallerStagesFrameworkLinksAndPreservesWorkshopData() async throws {
        let container = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let source = container.appending(path: "archive-source")
        let archive = container.appending(path: "steamcmd-fixture.tar.gz")
        let runtime = container.appending(path: "SteamCMD")
        try makeStagedSteamCMDRuntime(at: source)
        let versions = source.appending(path: "Frameworks/Breakpad.framework/Versions")
        try FileManager.default.createDirectory(at: versions.appending(path: "A"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: versions.appending(path: "Current").path,
            withDestinationPath: "A"
        )
        try makeTarArchive(source: source, destination: archive)
        let archiveToInstall = ProcessInfo.processInfo.environment["BACKGROUND_ENGINE_STEAMCMD_ARCHIVE"]
            .map { URL(filePath: $0) } ?? archive
        try FileManager.default.createDirectory(
            at: runtime.appending(path: "steamapps/workshop/content/431960/123"),
            withIntermediateDirectories: true
        )
        try Data("owned workshop data".utf8).write(
            to: runtime.appending(path: "steamapps/workshop/content/431960/123/project.json")
        )
        let runner = SteamCMDRunner(
            paths: SteamCMDRuntimePaths(root: runtime),
            installerDownloader: Self.fixtureDownloader(archive: archiveToInstall)
        )

        try await runner.installIfNeeded()

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: runtime.appending(path: "steamcmd.sh").path))
        XCTAssertEqual(
            try String(
                contentsOf: runtime.appending(path: "steamapps/workshop/content/431960/123/project.json"),
                encoding: .utf8
            ),
            "owned workshop data"
        )
        let linkedVersion = runtime.appending(path: "Frameworks/Breakpad.framework/Versions/Current")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkedVersion.path), "A")
    }

    func testSteamCMDInstallerRejectsEscapingArchiveLinkWithoutTouchingRuntime() async throws {
        let container = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let source = container.appending(path: "archive-source")
        let archive = container.appending(path: "steamcmd-unsafe.tar.gz")
        let runtime = container.appending(path: "SteamCMD")
        try makeStagedSteamCMDRuntime(at: source)
        try FileManager.default.createSymbolicLink(
            atPath: source.appending(path: "escape").path,
            withDestinationPath: "/tmp"
        )
        try makeTarArchive(source: source, destination: archive)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: runtime.appending(path: "existing-data"))
        let runner = SteamCMDRunner(
            paths: SteamCMDRuntimePaths(root: runtime),
            installerDownloader: Self.fixtureDownloader(archive: archive)
        )

        do {
            try await runner.installIfNeeded()
            XCTFail("An archive symlink that escapes staging must be rejected")
        } catch let error as SteamCMDRuntimeError {
            XCTAssertEqual(error, .installerArchiveUnsafe)
        }

        XCTAssertEqual(
            try String(contentsOf: runtime.appending(path: "existing-data"), encoding: .utf8),
            "keep me"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.appending(path: "steamcmd.sh").path))
    }

    func testSteamCMDInstallerRejectsRedirectedDownloadHost() async throws {
        let container = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let archive = container.appending(path: "untrusted-response.tar.gz")
        let runtime = container.appending(path: "SteamCMD")
        try Data("not inspected because the response is untrusted".utf8).write(to: archive)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: runtime.appending(path: "existing-data"))
        let runner = SteamCMDRunner(
            paths: SteamCMDRuntimePaths(root: runtime),
            installerDownloader: Self.fixtureDownloader(
                archive: archive,
                responseURL: URL(string: "https://example.com/steamcmd_osx.tar.gz")!
            )
        )

        do {
            try await runner.installIfNeeded()
            XCTFail("A redirected installer response from another host must be rejected")
        } catch let error as SteamCMDRunnerError {
            XCTAssertEqual(error, .installerDownloadFailed)
        }
        XCTAssertEqual(
            try String(contentsOf: runtime.appending(path: "existing-data"), encoding: .utf8),
            "keep me"
        )
    }

    func testSteamCMDInstallerRejectsConcurrentInstallationDuringArchiveDownload() async throws {
        let container = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let source = container.appending(path: "archive-source")
        let archive = container.appending(path: "steamcmd-fixture.tar.gz")
        let runtime = container.appending(path: "SteamCMD")
        try makeStagedSteamCMDRuntime(at: source)
        try makeTarArchive(source: source, destination: archive)
        let baseDownloader = Self.fixtureDownloader(archive: archive)
        let runner = SteamCMDRunner(
            paths: SteamCMDRuntimePaths(root: runtime),
            installerDownloader: { requestedURL in
                try await Task.sleep(for: .milliseconds(250))
                return try await baseDownloader(requestedURL)
            }
        )
        let firstInstall = Task { try await runner.installIfNeeded() }

        for _ in 0..<50 {
            if await runner.currentStatus().phase == .installingSteamCMD { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        do {
            try await runner.installIfNeeded()
            XCTFail("A second install must not enter while the installer archive is downloading")
        } catch let error as SteamCMDRunnerError {
            XCTAssertEqual(error, .operationInProgress)
        }

        try await firstInstall.value
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: runtime.appending(path: "steamcmd.sh").path))
    }

    func testSteamCMDRuntimeCommitPreservesWorkshopData() throws {
        let container = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let runtime = container.appending(path: "SteamCMD")
        let staged = container.appending(path: "staged")
        try FileManager.default.createDirectory(
            at: runtime.appending(path: "steamapps/workshop/content/431960/123"),
            withIntermediateDirectories: true
        )
        try Data("owned workshop data".utf8).write(
            to: runtime.appending(path: "steamapps/workshop/content/431960/123/project.json")
        )
        try makeStagedSteamCMDRuntime(at: staged)

        try SteamCMDRuntimeCommitter.commit(stagedRoot: staged, runtimeRoot: runtime)

        XCTAssertEqual(
            try String(
                contentsOf: runtime.appending(path: "steamapps/workshop/content/431960/123/project.json"),
                encoding: .utf8
            ),
            "owned workshop data"
        )
        XCTAssertEqual(
            try String(contentsOf: runtime.appending(path: "steamcmd.sh"), encoding: .utf8),
            "new launcher"
        )
    }

    func testSteamCMDRuntimeCommitRollsBackEveryEntryAfterInjectedFailure() throws {
        enum InjectedFailure: Error { case stop }

        let container = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let runtime = container.appending(path: "SteamCMD")
        let staged = container.appending(path: "staged")
        try FileManager.default.createDirectory(
            at: runtime.appending(path: "steamapps/workshop/content/431960/123"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: runtime.appending(path: "Frameworks"), withIntermediateDirectories: true)
        try Data("owned workshop data".utf8).write(
            to: runtime.appending(path: "steamapps/workshop/content/431960/123/project.json")
        )
        try Data("old framework".utf8).write(to: runtime.appending(path: "Frameworks/version.txt"))
        try makeStagedSteamCMDRuntime(at: staged)

        XCTAssertThrowsError(
            try SteamCMDRuntimeCommitter.commit(
                stagedRoot: staged,
                runtimeRoot: runtime,
                afterInstallingEntry: { name in
                    if name == "steamcmd.sh" { throw InjectedFailure.stop }
                }
            )
        ) { error in
            XCTAssertTrue(error is InjectedFailure)
        }

        XCTAssertEqual(
            try String(contentsOf: runtime.appending(path: "Frameworks/version.txt"), encoding: .utf8),
            "old framework"
        )
        XCTAssertEqual(
            try String(
                contentsOf: runtime.appending(path: "steamapps/workshop/content/431960/123/project.json"),
                encoding: .utf8
            ),
            "owned workshop data"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.appending(path: "steamcmd.sh").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appending(path: "steamcmd.sh").path))
    }

    func testSteamCMDRuntimeRecoveryRestoresCrashInterruptedSwapAndWorkshopData() throws {
        let container = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let runtime = container.appending(path: "SteamCMD")
        let staged = container.appending(path: "staged")
        try FileManager.default.createDirectory(
            at: runtime.appending(path: "Frameworks"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: runtime.appending(path: "steamapps/workshop/content/431960/123"),
            withIntermediateDirectories: true
        )
        try Data("old framework".utf8).write(to: runtime.appending(path: "Frameworks/version.txt"))
        try Data("old binary".utf8).write(to: runtime.appending(path: "steamcmd"))
        try Data("old launcher".utf8).write(to: runtime.appending(path: "steamcmd.sh"))
        try Data("owned workshop data".utf8).write(
            to: runtime.appending(path: "steamapps/workshop/content/431960/123/project.json")
        )
        try makeStagedSteamCMDRuntime(at: staged)

        let transaction = SteamCMDRuntimeCommitter.transactionPaths(for: runtime)
        try #"{"version":1,"incomingNames":["Frameworks","steamcmd","steamcmd.sh"]}"#
            .write(to: transaction.marker, atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: staged, to: transaction.candidate)
        try FileManager.default.moveItem(at: runtime, to: transaction.backup)
        try FileManager.default.moveItem(at: transaction.candidate, to: runtime)
        try FileManager.default.moveItem(
            at: transaction.backup.appending(path: "steamapps"),
            to: runtime.appending(path: "steamapps")
        )

        try SteamCMDRuntimeCommitter.recoverIfNeeded(runtimeRoot: runtime)

        XCTAssertEqual(
            try String(contentsOf: runtime.appending(path: "Frameworks/version.txt"), encoding: .utf8),
            "old framework"
        )
        XCTAssertEqual(
            try String(
                contentsOf: runtime.appending(path: "steamapps/workshop/content/431960/123/project.json"),
                encoding: .utf8
            ),
            "owned workshop data"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.candidate.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.retired.path))
    }

    func testSteamCMDRuntimeRecoveryClearsPartialMarkerBeforeRuntimeMutation() throws {
        let container = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let runtime = container.appending(path: "SteamCMD")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("old launcher".utf8).write(to: runtime.appending(path: "steamcmd.sh"))
        let transaction = SteamCMDRuntimeCommitter.transactionPaths(for: runtime)
        try Data(#"{"version":1,"incomingNames":["#.utf8).write(to: transaction.marker)

        try SteamCMDRuntimeCommitter.recoverIfNeeded(runtimeRoot: runtime)

        XCTAssertEqual(
            try String(contentsOf: runtime.appending(path: "steamcmd.sh"), encoding: .utf8),
            "old launcher"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.marker.path))
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

    func testProjectImporterAutomaticallyConvertsVideoThatNeedsConversion() async throws {
        let source = try makeDirectory()
        let library = try makeDirectory()
        let mediaRuntime = try makeFakeMediaRuntime(in: try makeDirectory())
        let conversionCache = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
            try? FileManager.default.removeItem(at: mediaRuntime)
            try? FileManager.default.removeItem(at: conversionCache)
        }
        let video = source.appending(path: "wallpaper.mkv")
        try Data("source-video".utf8).write(to: video)
        let scanned = WallpaperAsset(
            id: "converted-project",
            title: "Converted Project",
            kind: .video,
            supportStatus: .needsConversion,
            source: .localSteamWorkshop,
            projectDirectory: source.path,
            entrypoint: video.path,
            thumbnail: nil,
            workshopId: nil,
            dateAdded: Date(timeIntervalSince1970: 1_787_335_123.456_789),
            compatibility: .cached(reason: "Conversion required."),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .convertedVideo),
            redistributionAllowed: false,
            issues: [ScanIssue(code: "needs_conversion", message: "Conversion required.")]
        )
        let store = LibraryStore(root: library)
        let importer = WallpaperImporter(
            store: store,
            videoConverter: VideoConverter(resolver: MediaToolResolver(
                bundleResourceURL: mediaRuntime,
                environment: [:],
                allowDevelopmentFallback: false
            )),
            convertedVideoCacheDirectory: conversionCache
        )

        let imported = try await importer.importAndPrepareAsset(scanned)

        XCTAssertEqual(imported.supportStatus, .playable)
        XCTAssertEqual(imported.compatibilityReport?.playbackPath, .convertedVideo)
        XCTAssertFalse(imported.issues.contains(where: { $0.code == "needs_conversion" }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(imported.entrypoint)))
        XCTAssertEqual(try store.load().assets.first, imported)
    }

    func testProjectImporterPreservesImportedVideoWhenAutomaticConversionFails() async throws {
        let source = try makeDirectory()
        let library = try makeDirectory()
        let mediaRuntime = try makeFakeMediaRuntime(in: try makeDirectory(), ffmpegExitStatus: 17)
        let conversionCache = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
            try? FileManager.default.removeItem(at: mediaRuntime)
            try? FileManager.default.removeItem(at: conversionCache)
        }
        let video = source.appending(path: "wallpaper.avi")
        try Data("source-video".utf8).write(to: video)
        let scanned = WallpaperAsset(
            id: "failed-conversion-project",
            title: "Failed Conversion Project",
            kind: .video,
            supportStatus: .needsConversion,
            source: .steamCMD,
            projectDirectory: source.path,
            entrypoint: video.path,
            thumbnail: nil,
            workshopId: "123456",
            redistributionAllowed: false,
            issues: [ScanIssue(code: "needs_conversion", message: "Conversion required.")]
        )
        let store = LibraryStore(root: library)
        let importer = WallpaperImporter(
            store: store,
            videoConverter: VideoConverter(resolver: MediaToolResolver(
                bundleResourceURL: mediaRuntime,
                environment: [:],
                allowDevelopmentFallback: false
            )),
            convertedVideoCacheDirectory: conversionCache
        )

        let imported = try await importer.importAndPrepareAsset(scanned)

        XCTAssertEqual(imported.supportStatus, .needsConversion)
        XCTAssertEqual(imported.issues.first?.code, "automatic_conversion_failed")
        XCTAssertEqual(
            imported.issues.first?.message,
            "Automatic video conversion failed: FFmpeg exited with status 17."
        )
        XCTAssertTrue(imported.issues.contains(where: { $0.code == "automatic_conversion_failed" }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(imported.entrypoint)))
        XCTAssertEqual(try store.load().assets.first, imported)
    }

    func testProjectImportDeduplicatesInsideSharedLibraryTransaction() async throws {
        let source = try makeDirectory()
        let library = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }
        try Data("same-project-content".utf8).write(to: source.appending(path: "wallpaper.mp4"))
        let first = pendingVideoAsset(id: "dedup-a", source: source)
        let second = pendingVideoAsset(id: "dedup-b", source: source)
        let copier = BarrierProjectDirectoryCopier(participants: 2)
        let firstImporter = WallpaperImporter(
            store: LibraryStore(root: library, projectDirectoryCopier: copier)
        )
        let secondImporter = WallpaperImporter(
            store: LibraryStore(root: library, projectDirectoryCopier: copier)
        )

        async let importedA = firstImporter.importAsset(first)
        async let importedB = secondImporter.importAsset(second)
        let results = try await [importedA, importedB]

        XCTAssertEqual(results[0].id, results[1].id)
        XCTAssertEqual(try LibraryStore(root: library).load().assets.count, 1)
    }

    func testProjectImportHashesTheValidatedStagingSnapshot() async throws {
        let source = try makeDirectory()
        let library = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }
        let video = source.appending(path: "wallpaper.mkv")
        try Data("before-copy".utf8).write(to: video)
        let sourceHashBeforeCopy = try WallpaperContentHasher.hashDirectory(source)
        let importer = WallpaperImporter(
            store: LibraryStore(
                root: library,
                projectDirectoryCopier: MutatingProjectDirectoryCopier(
                    relativePath: "wallpaper.mkv",
                    replacementData: Data("after-copy".utf8)
                )
            )
        )

        let imported = try await importer.importAsset(
            pendingVideoAsset(id: "staging-hash", source: source)
        )
        let storedHash = try WallpaperContentHasher.hashDirectory(
            URL(filePath: imported.projectDirectory)
        )

        XCTAssertNotEqual(imported.contentHash, sourceHashBeforeCopy)
        XCTAssertEqual(imported.contentHash, storedHash)
        XCTAssertEqual(
            try Data(contentsOf: URL(filePath: try XCTUnwrap(imported.entrypoint))),
            Data("after-copy".utf8)
        )
    }

    func testProjectImportRejectsSymlinkInjectedIntoStagingCopy() async throws {
        let source = try makeDirectory()
        let library = try makeDirectory()
        let outside = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("video".utf8).write(to: source.appending(path: "wallpaper.mkv"))
        let externalFile = outside.appending(path: "outside.txt")
        try Data("outside".utf8).write(to: externalFile)
        let importer = WallpaperImporter(
            store: LibraryStore(
                root: library,
                projectDirectoryCopier: SymlinkInjectingProjectDirectoryCopier(
                    target: externalFile
                )
            )
        )

        do {
            _ = try await importer.importAsset(
                pendingVideoAsset(id: "staging-symlink", source: source)
            )
            XCTFail("A symlink introduced during copy must be rejected")
        } catch let error as WallpaperImportError {
            guard case .symbolicLink = error else {
                return XCTFail("Expected symbolicLink, got \(error)")
            }
        }
        XCTAssertTrue(try LibraryStore(root: library).load().assets.isEmpty)
    }

    func testProjectImportReprobesEntrypointRemovedFromStagingCopy() async throws {
        let source = try makeDirectory()
        let library = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }
        try Data("video".utf8).write(to: source.appending(path: "wallpaper.mkv"))
        try #"{"title":"Mutable","type":"video","file":"wallpaper.mkv"}"#.write(
            to: source.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        let importer = WallpaperImporter(
            store: LibraryStore(
                root: library,
                projectDirectoryCopier: RemovingStagedEntrypointProjectDirectoryCopier(
                    relativePath: "wallpaper.mkv"
                )
            )
        )

        let imported = try await importer.importAsset(
            pendingVideoAsset(id: "staging-entrypoint-removed", source: source)
        )

        XCTAssertEqual(imported.kind, .unknown)
        XCTAssertEqual(imported.supportStatus, .unsupported)
        XCTAssertNil(imported.entrypoint)
        XCTAssertTrue(imported.issues.contains(where: { $0.code == "no_supported_entrypoint" }))
        XCTAssertEqual(try LibraryStore(root: library).load().assets.first, imported)
    }

    func testAutomaticVideoConversionDeduplicatesSharedCacheProcess() async throws {
        let source = try makeDirectory()
        let library = try makeDirectory()
        let runtimeRoot = try makeDirectory()
        let conversionCache = try makeDirectory()
        let control = try makeDirectory()
        defer {
            for url in [source, library, runtimeRoot, conversionCache, control] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try Data("shared-video".utf8).write(to: source.appending(path: "wallpaper.mkv"))
        let started = control.appending(path: "started")
        let invocations = control.appending(path: "invocations")
        let release = control.appending(path: "release")
        let mediaRuntime = try makeControlledMediaRuntime(
            in: runtimeRoot,
            started: started,
            invocations: invocations,
            release: release
        )
        let resolver = MediaToolResolver(
            bundleResourceURL: mediaRuntime,
            environment: [:],
            allowDevelopmentFallback: false
        )
        let firstImporter = WallpaperImporter(
            store: LibraryStore(root: library),
            videoConverter: VideoConverter(resolver: resolver),
            convertedVideoCacheDirectory: conversionCache
        )
        let secondImporter = WallpaperImporter(
            store: LibraryStore(root: library),
            videoConverter: VideoConverter(resolver: resolver),
            convertedVideoCacheDirectory: conversionCache
        )
        let firstAsset = pendingVideoAsset(id: "shared-a", source: source)
        let secondAsset = pendingVideoAsset(id: "shared-b", source: source)
        let firstTask = Task {
            try await firstImporter.importAndPrepareAsset(firstAsset)
        }
        try await waitForFile(started)
        let secondTask = Task {
            try await secondImporter.importAndPrepareAsset(secondAsset)
        }
        try await Task.sleep(for: .milliseconds(100))
        try Data().write(to: release)

        let first = try await firstTask.value
        let second = try await secondTask.value
        let launchCount = try String(contentsOf: invocations, encoding: .utf8)
            .split(whereSeparator: \.isNewline).count
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.supportStatus, .playable)
        XCTAssertEqual(second.supportStatus, .playable)
        XCTAssertEqual(try LibraryStore(root: library).load().assets.count, 1)
    }

    func testCancellingOneSharedConversionWaiterDoesNotCancelAnother() async throws {
        let source = try makeDirectory()
        let library = try makeDirectory()
        let runtimeRoot = try makeDirectory()
        let conversionCache = try makeDirectory()
        let control = try makeDirectory()
        defer {
            for url in [source, library, runtimeRoot, conversionCache, control] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try Data("shared-cancellation-video".utf8).write(
            to: source.appending(path: "wallpaper.mkv")
        )
        let started = control.appending(path: "started")
        let invocations = control.appending(path: "invocations")
        let release = control.appending(path: "release")
        let mediaRuntime = try makeControlledMediaRuntime(
            in: runtimeRoot,
            started: started,
            invocations: invocations,
            release: release
        )
        let resolver = MediaToolResolver(
            bundleResourceURL: mediaRuntime,
            environment: [:],
            allowDevelopmentFallback: false
        )
        let firstImporter = WallpaperImporter(
            store: LibraryStore(root: library),
            videoConverter: VideoConverter(resolver: resolver),
            convertedVideoCacheDirectory: conversionCache
        )
        let secondImporter = WallpaperImporter(
            store: LibraryStore(root: library),
            videoConverter: VideoConverter(resolver: resolver),
            convertedVideoCacheDirectory: conversionCache
        )
        let firstAsset = pendingVideoAsset(id: "waiter-a", source: source)
        let secondAsset = pendingVideoAsset(id: "waiter-b", source: source)
        let contentHash = try WallpaperContentHasher.hashDirectory(source)
        let conversionOutput = conversionCache.appending(
            path: VideoConversionCacheKey(contentHash: contentHash).fileName
        ).standardizedFileURL.path
        let conversionKey = firstAsset.id + "\u{0}" + conversionOutput
        let cancelledTask = Task {
            try await firstImporter.importAndPrepareAsset(firstAsset)
        }
        try await waitForFile(started)
        let completingTask = Task {
            try await secondImporter.importAndPrepareAsset(secondAsset)
        }
        for _ in 0..<500 {
            if await ImportedVideoConversionCoordinator.shared
                .registeredWaiterCount(for: conversionKey) == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sharedWaiterCount = await ImportedVideoConversionCoordinator.shared
            .registeredWaiterCount(for: conversionKey)
        XCTAssertEqual(
            sharedWaiterCount,
            2,
            "The cancellation assertion requires both waiters to share the active conversion"
        )

        cancelledTask.cancel()
        let cancelled = try await cancelledTask.value
        XCTAssertEqual(cancelled.issues.first?.code, "automatic_conversion_cancelled")
        try Data().write(to: release)
        let completed = try await completingTask.value

        let launchCount = try String(contentsOf: invocations, encoding: .utf8)
            .split(whereSeparator: \.isNewline).count
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(completed.supportStatus, .playable)
        XCTAssertEqual(try LibraryStore(root: library).load().assets.first, completed)
    }

    func testWorkshopUpdateOvertakingConversionUsesSnapshotAndCollectsStaleOutput() async throws {
        let source = try makeDirectory()
        let library = try makeDirectory()
        let runtimeRoot = try makeDirectory()
        let conversionCache = try makeDirectory()
        let control = try makeDirectory()
        defer {
            for url in [source, library, runtimeRoot, conversionCache, control] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let sourceVideo = source.appending(path: "wallpaper.mkv")
        let originalBytes = Data("workshop-v1".utf8)
        let updatedBytes = Data("workshop-v2".utf8)
        try originalBytes.write(to: sourceVideo)
        let originalHash = try WallpaperContentHasher.hashDirectory(source)
        let started = control.appending(path: "started")
        let invocations = control.appending(path: "invocations")
        let release = control.appending(path: "release")
        let capturedInput = control.appending(path: "captured-input")
        let mediaRuntime = try makeControlledMediaRuntime(
            in: runtimeRoot,
            started: started,
            invocations: invocations,
            release: release,
            capturedInput: capturedInput
        )
        let resolver = MediaToolResolver(
            bundleResourceURL: mediaRuntime,
            environment: [:],
            allowDevelopmentFallback: false
        )
        let store = LibraryStore(root: library)
        let convertingImporter = WallpaperImporter(
            store: store,
            videoConverter: VideoConverter(resolver: resolver),
            convertedVideoCacheDirectory: conversionCache
        )
        let updatingImporter = WallpaperImporter(
            store: store,
            videoConverter: VideoConverter(resolver: resolver),
            convertedVideoCacheDirectory: conversionCache
        )
        let original = pendingVideoAsset(
            id: "workshop-race",
            source: source,
            workshopID: "555"
        )
        let conversion = Task {
            try await convertingImporter.importAndPrepareAsset(original)
        }
        try await waitForFile(started)

        try updatedBytes.write(to: sourceVideo)
        let updated = try await updatingImporter.importAsset(
            pendingVideoAsset(id: original.id, source: source, workshopID: "555")
        )
        XCTAssertNotEqual(updated.contentHash, originalHash)
        try Data().write(to: release)
        let staleResult = try await conversion.value

        let staleOutput = conversionCache.appending(
            path: VideoConversionCacheKey(contentHash: originalHash).fileName
        )
        XCTAssertEqual(staleResult, updated)
        XCTAssertEqual(try store.load().assets.first, updated)
        XCTAssertEqual(try Data(contentsOf: capturedInput), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleOutput.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: conversionCache.path)
                .contains(where: { $0.hasPrefix(".video-input-") })
        )
    }

    func testRetryWaitsForCancelledConversionToDrainBeforeReusingCacheKey() async throws {
        let source = try makeDirectory()
        let library = try makeDirectory()
        let runtimeRoot = try makeDirectory()
        let conversionCache = try makeDirectory()
        let control = try makeDirectory()
        defer {
            for url in [source, library, runtimeRoot, conversionCache, control] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try Data("retry-video".utf8).write(to: source.appending(path: "wallpaper.mkv"))
        let started = control.appending(path: "started")
        let invocations = control.appending(path: "invocations")
        let pidFile = control.appending(path: "pid")
        let mediaRuntime = try makeRetryMediaRuntime(
            in: runtimeRoot,
            started: started,
            invocations: invocations,
            pidFile: pidFile
        )
        let resolver = MediaToolResolver(
            bundleResourceURL: mediaRuntime,
            environment: [:],
            allowDevelopmentFallback: false
        )
        let firstImporter = WallpaperImporter(
            store: LibraryStore(root: library),
            videoConverter: VideoConverter(resolver: resolver),
            convertedVideoCacheDirectory: conversionCache
        )
        let retryImporter = WallpaperImporter(
            store: LibraryStore(root: library),
            videoConverter: VideoConverter(resolver: resolver),
            convertedVideoCacheDirectory: conversionCache
        )
        let firstAsset = pendingVideoAsset(id: "retry-first", source: source)
        let retryAsset = pendingVideoAsset(id: "retry-second", source: source)
        let firstTask = Task { try await firstImporter.importAndPrepareAsset(firstAsset) }
        try await waitForFile(started)
        let firstPID = try XCTUnwrap(
            Int32(try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )

        firstTask.cancel()
        let retryTask = Task { try await retryImporter.importAndPrepareAsset(retryAsset) }
        let cancelled = try await firstTask.value
        let retried = try await retryTask.value

        XCTAssertEqual(cancelled.issues.first?.code, "automatic_conversion_cancelled")
        XCTAssertEqual(retried.supportStatus, .playable)
        XCTAssertEqual(
            try String(contentsOf: invocations, encoding: .utf8)
                .split(whereSeparator: \.isNewline).count,
            2
        )
        XCTAssertEqual(Darwin.kill(firstPID, 0), -1, "The cancelled process must be reaped before retry returns")
    }

    func testCancellingAutomaticConversionKeepsDurableWorkshopImport() async throws {
        let source = try makeDirectory()
        let library = try makeDirectory()
        let runtimeRoot = try makeDirectory()
        let conversionCache = try makeDirectory()
        let control = try makeDirectory()
        defer {
            for url in [source, library, runtimeRoot, conversionCache, control] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try Data("cancel-video".utf8).write(to: source.appending(path: "wallpaper.mkv"))
        let started = control.appending(path: "started")
        let invocations = control.appending(path: "invocations")
        let pidFile = control.appending(path: "pid")
        let mediaRuntime = try makeControlledMediaRuntime(
            in: runtimeRoot,
            started: started,
            invocations: invocations,
            pidFile: pidFile,
            ignoreTermination: true
        )
        let importer = WallpaperImporter(
            store: LibraryStore(root: library),
            videoConverter: VideoConverter(resolver: MediaToolResolver(
                bundleResourceURL: mediaRuntime,
                environment: [:],
                allowDevelopmentFallback: false
            )),
            convertedVideoCacheDirectory: conversionCache
        )
        let pending = pendingVideoAsset(
            id: "cancelled-workshop",
            source: source,
            workshopID: "123456"
        )
        let task = Task { try await importer.importAndPrepareAsset(pending) }
        try await waitForFile(started)
        let pid = try XCTUnwrap(
            Int32(try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        task.cancel()
        let imported = try await task.value

        XCTAssertEqual(imported.source, .steamCMD)
        XCTAssertEqual(imported.supportStatus, .needsConversion)
        XCTAssertEqual(imported.issues.first?.code, "automatic_conversion_cancelled")
        XCTAssertEqual(try LibraryStore(root: library).load().assets.first, imported)
        for _ in 0..<100 where Darwin.kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "Cancelled FFmpeg must be killed and reaped")
    }

    func testLegacyMigrationCancellationStopsBeforeNextCandidate() async throws {
        let firstSource = try makeDirectory()
        let secondSource = try makeDirectory()
        let library = try makeDirectory()
        let runtimeRoot = try makeDirectory()
        let conversionCache = try makeDirectory()
        let control = try makeDirectory()
        defer {
            for url in [firstSource, secondSource, library, runtimeRoot, conversionCache, control] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try Data("first-video".utf8).write(to: firstSource.appending(path: "wallpaper.mkv"))
        try Data("second-video".utf8).write(to: secondSource.appending(path: "wallpaper.mkv"))
        let started = control.appending(path: "started")
        let invocations = control.appending(path: "invocations")
        let pidFile = control.appending(path: "pid")
        let mediaRuntime = try makeControlledMediaRuntime(
            in: runtimeRoot,
            started: started,
            invocations: invocations,
            pidFile: pidFile,
            ignoreTermination: true
        )
        let importer = WallpaperImporter(
            store: LibraryStore(root: library),
            videoConverter: VideoConverter(resolver: MediaToolResolver(
                bundleResourceURL: mediaRuntime,
                environment: [:],
                allowDevelopmentFallback: false
            )),
            convertedVideoCacheDirectory: conversionCache
        )
        let migrator = LegacyLibraryMigrator(importer: importer)
        let candidates = [
            LegacyMigrationCandidate(
                asset: pendingVideoAsset(id: "legacy-first", source: firstSource),
                sourceApplication: "Fixture"
            ),
            LegacyMigrationCandidate(
                asset: pendingVideoAsset(id: "legacy-second", source: secondSource),
                sourceApplication: "Fixture"
            )
        ]
        let migration = Task { try await migrator.migrate(candidates) }
        try await waitForFile(started)
        migration.cancel()

        do {
            _ = try await migration.value
            XCTFail("Cancellation after a durable import must stop the remaining batch")
        } catch is CancellationError {
            // Expected after the first preserved asset is returned by the importer.
        }
        let assets = try LibraryStore(root: library).load().assets
        XCTAssertEqual(assets.map(\.id), ["legacy-first"])
        XCTAssertEqual(assets.first?.issues.first?.code, "automatic_conversion_cancelled")
        XCTAssertEqual(
            try String(contentsOf: invocations, encoding: .utf8)
                .split(whereSeparator: \.isNewline).count,
            1
        )
    }

    func testDeletedAssetCannotReportAutomaticConversionSuccess() async throws {
        let source = try makeDirectory()
        let library = try makeDirectory()
        let runtimeRoot = try makeDirectory()
        let conversionCache = try makeDirectory()
        let control = try makeDirectory()
        defer {
            for url in [source, library, runtimeRoot, conversionCache, control] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try Data("removed-video".utf8).write(to: source.appending(path: "wallpaper.mkv"))
        let started = control.appending(path: "started")
        let invocations = control.appending(path: "invocations")
        let release = control.appending(path: "release")
        let mediaRuntime = try makeControlledMediaRuntime(
            in: runtimeRoot,
            started: started,
            invocations: invocations,
            release: release
        )
        let store = LibraryStore(root: library)
        let importer = WallpaperImporter(
            store: store,
            videoConverter: VideoConverter(resolver: MediaToolResolver(
                bundleResourceURL: mediaRuntime,
                environment: [:],
                allowDevelopmentFallback: false
            )),
            convertedVideoCacheDirectory: conversionCache
        )
        let asset = pendingVideoAsset(id: "removed-during-conversion", source: source)
        let task = Task { try await importer.importAndPrepareAsset(asset) }
        try await waitForFile(started)
        try store.removeAsset(id: asset.id)
        try Data().write(to: release)

        do {
            _ = try await task.value
            XCTFail("A removed asset must not be returned as a successful import")
        } catch let error as WallpaperImportError {
            XCTAssertEqual(error, .assetRemovedDuringPreparation(asset.id))
        }
        XCTAssertTrue(try store.load().assets.isEmpty)
        let staleOutput = conversionCache.appending(
            path: VideoConversionCacheKey(
                contentHash: try WallpaperContentHasher.hashDirectory(source)
            ).fileName
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleOutput.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: conversionCache.path)
                .contains(where: { $0.hasPrefix(".video-input-") })
        )
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

    private func spawnImmediateExitSupervisor(in root: URL) throws -> SupervisedChildProcess {
        let executable = root.appending(path: "immediate-exit.sh")
        let log = root.appending(path: "immediate-exit.log")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        return try SupervisedChildProcess.spawn(
            executable: executable,
            arguments: [],
            currentDirectory: root,
            standardOutput: logHandle,
            standardError: logHandle,
            outputFileLimit: nil
        )
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

    private func pendingVideoAsset(
        id: String,
        source: URL,
        workshopID: String? = nil
    ) -> WallpaperAsset {
        WallpaperAsset(
            id: id,
            title: id,
            kind: .video,
            supportStatus: .needsConversion,
            source: workshopID == nil ? .manualFolder : .steamCMD,
            projectDirectory: source.path,
            entrypoint: source.appending(path: "wallpaper.mkv").path,
            thumbnail: nil,
            workshopId: workshopID,
            redistributionAllowed: false,
            issues: [ScanIssue(code: "needs_conversion", message: "Conversion required.")]
        )
    }

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(url.lastPathComponent)")
        throw CocoaError(.fileNoSuchFile)
    }

    private func waitForProcessIdentifier(at url: URL) async throws -> Int32 {
        for _ in 0..<1_000 {
            if let source = try? String(contentsOf: url, encoding: .utf8),
               let processIdentifier = Int32(
                source.trimmingCharacters(in: .whitespacesAndNewlines)
               ),
               processIdentifier > 1 {
                return processIdentifier
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for a valid process identifier in \(url.lastPathComponent)")
        throw CocoaError(.fileReadUnknown)
    }

    private func makeControlledMediaRuntime(
        in root: URL,
        started: URL,
        invocations: URL,
        release: URL? = nil,
        pidFile: URL? = nil,
        ignoreTermination: Bool = false,
        capturedInput: URL? = nil
    ) throws -> URL {
        let mediaTools = root.appending(path: "MediaTools")
        try FileManager.default.createDirectory(at: mediaTools, withIntermediateDirectories: true)
        let ffmpeg = mediaTools.appending(path: "ffmpeg")
        let ffprobe = mediaTools.appending(path: "ffprobe")
        let releaseLoop = release.map {
            "while [ ! -f \"\($0.path)\" ]; do sleep 0.01; done"
        } ?? "while :; do sleep 1; done"
        let trapLine = ignoreTermination ? "trap '' TERM" : ""
        let pidLine = pidFile.map { "printf '%s' \"$$\" > \"\($0.path)\"" } ?? ""
        let captureLine = capturedInput.map {
            "if [ \"$previous\" = '-i' ]; then /bin/cat \"$argument\" > \"\($0.path)\"; fi"
        } ?? ""
        try """
        #!/bin/sh
        \(trapLine)
        printf '%s\\n' "launch" >> "\(invocations.path)"
        \(pidLine)
        : > "\(started.path)"
        \(releaseLoop)
        output=''
        previous=''
        for argument in "$@"; do
            \(captureLine)
            previous="$argument"
            output="$argument"
        done
        printf '%s' 'converted-video' > "$output"
        """.write(to: ffmpeg, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf '%s' '{"streams":[{"index":0,"codec_type":"video"}],"format":{"format_name":"mov,mp4","size":"15"}}'
        """.write(to: ffprobe, atomically: true, encoding: .utf8)
        for executable in [ffmpeg, ffprobe] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        return root
    }

    private func makeRetryMediaRuntime(
        in root: URL,
        started: URL,
        invocations: URL,
        pidFile: URL
    ) throws -> URL {
        let mediaTools = root.appending(path: "MediaTools")
        try FileManager.default.createDirectory(at: mediaTools, withIntermediateDirectories: true)
        let ffmpeg = mediaTools.appending(path: "ffmpeg")
        let ffprobe = mediaTools.appending(path: "ffprobe")
        try """
        #!/bin/sh
        launch_count=0
        if [ -f "\(invocations.path)" ]; then
            launch_count=$(/usr/bin/wc -l < "\(invocations.path)" | /usr/bin/tr -d ' ')
        fi
        printf '%s\\n' "launch" >> "\(invocations.path)"
        if [ "$launch_count" -eq 0 ]; then
            trap '' TERM
            printf '%s' "$$" > "\(pidFile.path)"
            : > "\(started.path)"
            while :; do sleep 1; done
        fi
        output=''
        for argument in "$@"; do output="$argument"; done
        printf '%s' 'converted-video' > "$output"
        """.write(to: ffmpeg, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf '%s' '{"streams":[{"index":0,"codec_type":"video"}],"format":{"format_name":"mov,mp4","size":"15"}}'
        """.write(to: ffprobe, atomically: true, encoding: .utf8)
        for executable in [ffmpeg, ffprobe] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        return root
    }

    private func makeFakeMediaRuntime(in root: URL, ffmpegExitStatus: Int = 0) throws -> URL {
        let mediaTools = root.appending(path: "MediaTools")
        try FileManager.default.createDirectory(at: mediaTools, withIntermediateDirectories: true)
        let ffmpeg = mediaTools.appending(path: "ffmpeg")
        let ffprobe = mediaTools.appending(path: "ffprobe")
        try """
        #!/bin/sh
        output=''
        for argument in "$@"; do output="$argument"; done
        if [ \(ffmpegExitStatus) -ne 0 ]; then exit \(ffmpegExitStatus); fi
        printf '%s' 'converted-video' > "$output"
        """.write(to: ffmpeg, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf '%s' '{"streams":[{"index":0,"codec_type":"video"}],"format":{"format_name":"mov,mp4","size":"15"}}'
        """.write(to: ffprobe, atomically: true, encoding: .utf8)
        for executable in [ffmpeg, ffprobe] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        return root
    }

    private func makeStagedSteamCMDRuntime(at root: URL) throws {
        try FileManager.default.createDirectory(at: root.appending(path: "Frameworks"), withIntermediateDirectories: true)
        try Data("new framework".utf8).write(to: root.appending(path: "Frameworks/version.txt"))
        try Data("new binary".utf8).write(to: root.appending(path: "steamcmd"))
        try Data("new launcher".utf8).write(to: root.appending(path: "steamcmd.sh"))
    }

    private func makeTarArchive(source: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = ["-czf", destination.path, "-C", source.path, "."]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(
                domain: "BackgroundEngineFeatureTests.tar",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private static func fixtureDownloader(
        archive: URL,
        responseURL: URL? = nil
    ) -> SteamCMDRunner.InstallerDownloader {
        { requestedURL in
            let temporary = FileManager.default.temporaryDirectory
                .appending(path: "background-engine-steamcmd-fixture-\(UUID().uuidString).tar.gz")
            try FileManager.default.copyItem(at: archive, to: temporary)
            let response = HTTPURLResponse(
                url: responseURL ?? requestedURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/gzip"]
            )!
            return (temporary, response)
        }
    }
}

private final class BarrierProjectDirectoryCopier: ProjectDirectoryCopying, @unchecked Sendable {
    private let condition = NSCondition()
    private let participants: Int
    private var arrived = 0

    init(participants: Int) {
        self.participants = participants
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
        condition.lock()
        arrived += 1
        if arrived == participants {
            condition.broadcast()
        } else {
            let deadline = Date().addingTimeInterval(5)
            while arrived < participants, condition.wait(until: deadline) {}
        }
        condition.unlock()
    }
}

private struct MutatingProjectDirectoryCopier: ProjectDirectoryCopying {
    let relativePath: String
    let replacementData: Data

    func copyItem(at source: URL, to destination: URL) throws {
        try replacementData.write(to: source.appending(path: relativePath))
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

private struct SymlinkInjectingProjectDirectoryCopier: ProjectDirectoryCopying {
    let target: URL

    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.createSymbolicLink(
            at: destination.appending(path: ".injected-link"),
            withDestinationURL: target
        )
    }
}

private struct RemovingStagedEntrypointProjectDirectoryCopier: ProjectDirectoryCopying {
    let relativePath: String

    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.removeItem(at: destination.appending(path: relativePath))
    }
}
