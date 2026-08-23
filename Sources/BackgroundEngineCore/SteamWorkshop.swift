@preconcurrency import Foundation
import Darwin

public struct WorkshopItemID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        let candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.allSatisfy(\.isNumber),
              candidate.first != "0",
              UInt64(candidate) != nil else {
            return nil
        }
        self.rawValue = candidate
    }

    public init?(input: String) {
        if let numeric = WorkshopItemID(rawValue: input) {
            self = numeric
            return
        }
        guard let components = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host == "steamcommunity.com" || host == "www.steamcommunity.com",
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              components.fragment == nil,
              Self.isWorkshopDetailsPath(components.path),
              let identifiers = components.queryItems?.filter({ $0.name.lowercased() == "id" }),
              identifiers.count == 1,
              let id = identifiers[0].value,
              let numeric = WorkshopItemID(rawValue: id) else {
            return nil
        }
        self = numeric
    }

    private static func isWorkshopDetailsPath(_ path: String) -> Bool {
        let normalized = path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized == "sharedfiles/filedetails" || normalized == "workshop/filedetails"
    }
}

public struct SteamCMDCommand: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum SteamCMDCommandBuilder {
    public static let wallpaperEngineAppID = "431960"

    public static func download(itemID: WorkshopItemID, runtime: URL) -> SteamCMDCommand {
        SteamCMDCommand(
            executable: runtime.appending(path: "steamcmd.sh"),
            arguments: [
                "+@ShutdownOnFailedCommand", "1",
                "+@NoPromptForPassword", "1",
                "+login", "anonymous",
                "+workshop_download_item", wallpaperEngineAppID, itemID.rawValue,
                "+quit"
            ]
        )
    }
}

public enum WorkshopDownloadPhase: String, Codable, Sendable {
    case idle
    case installingSteamCMD
    case downloading
    case importing
    case completed
    case cancelled
    case failed
}

public struct WorkshopDownloadStatus: Codable, Equatable, Sendable {
    public let itemID: String?
    public let phase: WorkshopDownloadPhase
    public let progress: Double?
    public let message: String

    public init(itemID: String?, phase: WorkshopDownloadPhase, progress: Double?, message: String) {
        self.itemID = itemID
        self.phase = phase
        self.progress = progress
        self.message = message
    }
}

public struct SteamCMDDiagnostics: Codable, Equatable, Sendable {
    public let runtimePath: String
    public let executablePresent: Bool
    public let activeItemID: String?
    public let phase: WorkshopDownloadPhase
    public let recentOutput: [String]

    public init(
        runtimePath: String,
        executablePresent: Bool,
        activeItemID: String?,
        phase: WorkshopDownloadPhase,
        recentOutput: [String]
    ) {
        self.runtimePath = runtimePath
        self.executablePresent = executablePresent
        self.activeItemID = activeItemID
        self.phase = phase
        self.recentOutput = recentOutput
    }
}

public struct SteamCMDRuntimePaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static func applicationSupport() throws -> SteamCMDRuntimePaths {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return SteamCMDRuntimePaths(root: base.appending(path: "Background Engine/SteamCMD"))
    }

    public var executable: URL { root.appending(path: "steamcmd.sh") }
    public var archive: URL { root.appending(path: "steamcmd_osx.tar.gz") }

    public func workshopItem(_ itemID: WorkshopItemID) -> URL {
        root.appending(path: "steamapps/workshop/content/431960/\(itemID.rawValue)")
    }
}

enum SteamCMDRuntimeError: LocalizedError, Equatable {
    case installerArchiveUnsafe
    case installerCommitRollbackFailed
    case processLaunchFailed

    var errorDescription: String? {
        switch self {
        case .installerArchiveUnsafe:
            "The downloaded SteamCMD archive could not be validated or safely unpacked."
        case .installerCommitRollbackFailed:
            "SteamCMD installation failed and the previous runtime could not be fully restored. Export diagnostics before retrying."
        case .processLaunchFailed:
            "SteamCMD could not start its isolated process supervisor."
        }
    }
}

enum SupervisedProcessError: LocalizedError, Equatable {
    case launchFailed

    var errorDescription: String? {
        "The isolated child-process supervisor could not be started."
    }
}

struct InheritedFileDescriptor {
    let fileHandle: FileHandle
    /// Unique placeholder replaced with the collision-free descriptor number
    /// selected for the child. Callers can embed it in an argument such as
    /// `/dev/fd/__BACKGROUND_ENGINE_INPUT__` without guessing which parent
    /// descriptors the supervisor will allocate later.
    let argumentToken: String
}

/// Runs a trusted executable in an isolated process group and guarantees that
/// descendants cannot outlive either the command or the owning process.
///
/// The launcher intentionally stays internal. XPC callers still select from
/// fixed SteamCMD operations and can never provide an arbitrary command.
final class SupervisedChildProcess: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private enum Phase {
            case running
            case completing
            case exited(Int32)
        }

        private let lock = NSLock()
        private let completion = DispatchGroup()
        private var phase = Phase.running
        private var timedOut = false
        private var continuations: [CheckedContinuation<Int32, Never>] = []

        init() {
            completion.enter()
        }

        var isRunning: Bool {
            lock.withLock {
                if case .exited = phase { return false }
                return true
            }
        }

        var didTimeOut: Bool {
            lock.withLock { timedOut }
        }

        func beginCompleting() {
            lock.withLock {
                if case .running = phase { phase = .completing }
            }
        }

        func complete(status: Int32) {
            let result: (didComplete: Bool, waiting: [CheckedContinuation<Int32, Never>]) = lock.withLock {
                if case .exited = phase { return (false, []) }
                phase = .exited(status)
                let waiting = continuations
                continuations.removeAll(keepingCapacity: false)
                return (true, waiting)
            }
            guard result.didComplete else { return }
            completion.leave()
            result.waiting.forEach { $0.resume(returning: status) }
        }

        func waitUntilExit() async -> Int32 {
            await withCheckedContinuation { continuation in
                let status: Int32? = lock.withLock {
                    if case .exited(let status) = phase { return status }
                    continuations.append(continuation)
                    return nil
                }
                if let status { continuation.resume(returning: status) }
            }
        }

        func waitUntilExit(timeout: DispatchTime) -> Int32? {
            guard completion.wait(timeout: timeout) == .success else { return nil }
            return lock.withLock {
                if case .exited(let status) = phase { return status }
                return nil
            }
        }

        func claimTimeoutAndSignal(processIdentifier: Int32) -> Bool {
            lock.withLock {
                guard case .running = phase, processIdentifier > 1 else { return false }
                timedOut = true
                _ = Darwin.kill(-processIdentifier, SIGTERM)
                return true
            }
        }

        func signalIfRunning(processIdentifier: Int32, signal: Int32) -> Bool {
            lock.withLock {
                guard processIdentifier > 1 else { return false }
                if case .exited = phase { return false }
                _ = Darwin.kill(-processIdentifier, signal)
                return true
            }
        }
    }

    let processIdentifier: Int32
    private let state: State
    private let lifecycleWrite: FileHandle
    private let lifecycleLock = NSLock()
    private var lifecycleIsOpen = true

    var isRunning: Bool { state.isRunning }

    private init(
        processIdentifier: Int32,
        state: State,
        lifecycleWrite: FileHandle
    ) {
        self.processIdentifier = processIdentifier
        self.state = state
        self.lifecycleWrite = lifecycleWrite
    }

    deinit {
        closeLifecycle()
    }

    static func spawn(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        standardOutput: FileHandle,
        standardError: FileHandle,
        outputFileLimit: UInt64?,
        inheritedFileDescriptors: [InheritedFileDescriptor] = []
    ) throws -> SupervisedChildProcess {
        let lifecycle = Pipe()
        let lifecycleRead = lifecycle.fileHandleForReading
        let lifecycleWrite = lifecycle.fileHandleForWriting
        guard Darwin.fcntl(lifecycleWrite.fileDescriptor, F_SETFD, FD_CLOEXEC) != -1 else {
            try? lifecycleRead.close()
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }

        let nullInput = try FileHandle(forReadingFrom: URL(filePath: "/dev/null"))
        defer { try? nullInput.close() }

        // Snapshot every caller-owned source onto a private high descriptor.
        // A caller FD can legally be 0...3 or equal a pipe that a later launch
        // allocates; using it directly would let an earlier spawn action
        // overwrite/close the source before its inherited dup occurs.
        var inheritedSources: [(descriptor: Int32, token: String)] = []
        for binding in inheritedFileDescriptors {
            let descriptor = Darwin.fcntl(
                binding.fileHandle.fileDescriptor,
                F_DUPFD_CLOEXEC,
                128
            )
            guard descriptor >= 0 else {
                inheritedSources.forEach { Darwin.close($0.descriptor) }
                try? lifecycleRead.close()
                try? lifecycleWrite.close()
                throw SupervisedProcessError.launchFailed
            }
            inheritedSources.append((descriptor, binding.argumentToken))
        }
        defer { inheritedSources.forEach { Darwin.close($0.descriptor) } }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            try? lifecycleRead.close()
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            try? lifecycleRead.close()
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let lifecycleFD: Int32 = 3
        var actions = [
            posix_spawn_file_actions_adddup2(&fileActions, nullInput.fileDescriptor, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardOutput.fileDescriptor,
                STDOUT_FILENO
            ),
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardError.fileDescriptor,
                STDERR_FILENO
            ),
            posix_spawn_file_actions_adddup2(&fileActions, lifecycleRead.fileDescriptor, lifecycleFD),
            posix_spawn_file_actions_addclose(&fileActions, lifecycleWrite.fileDescriptor)
        ]
        let reservedDescriptors = Set([
            STDIN_FILENO,
            STDOUT_FILENO,
            STDERR_FILENO,
            lifecycleFD,
            nullInput.fileDescriptor,
            standardOutput.fileDescriptor,
            standardError.fileDescriptor,
            lifecycleRead.fileDescriptor,
            lifecycleWrite.fileDescriptor
        ])
        let sourceDescriptors = inheritedSources.map(\.descriptor)
        let originalSourceDescriptors = inheritedFileDescriptors.map { $0.fileHandle.fileDescriptor }
        let tokens = inheritedSources.map(\.token)
        let unavailableDescriptors = reservedDescriptors.union(originalSourceDescriptors)
        guard Set(tokens).count == tokens.count,
              tokens.allSatisfy({ token in
                  !token.isEmpty && arguments.contains(where: { $0.contains(token) })
              }),
              sourceDescriptors.allSatisfy({ $0 >= 0 }),
              let inheritedTargets = inheritedDescriptorTargets(
                  sourceDescriptors: sourceDescriptors,
                  reservedDescriptors: unavailableDescriptors
              ) else {
            try? lifecycleRead.close()
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }
        actions.append(contentsOf: zip(inheritedSources, inheritedTargets).map { binding, target in
            posix_spawn_file_actions_adddup2(
                &fileActions,
                binding.descriptor,
                target
            )
        })
        guard actions.allSatisfy({ $0 == 0 }) else {
            try? lifecycleRead.close()
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            try? lifecycleRead.close()
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }

        // Explicit self-dup redirections keep these descriptors marked open
        // when `/bin/sh` launches a script interpreter. Native FFmpeg already
        // inherits them directly, while shell-based deterministic test tools
        // otherwise close non-standard descriptors before their shebang shell.
        let inheritedRedirections = inheritedTargets
            .map { "\($0)>&\($0)" }
            .joined(separator: " ")
        let supervisor = """
        working_directory=$1
        file_blocks=$2
        shift 2
        cd "$working_directory" || exit 125
        if [ "$file_blocks" -gt 0 ]; then
            ulimit -f "$file_blocks" || exit 125
        fi
        "$@" \(inheritedRedirections) &
        command_pid=$!
        (
            if IFS= read -r lifecycle_message <&3; then :; fi
            kill -KILL -$$ 2>/dev/null || true
        ) &
        guardian_pid=$!
        wait "$command_pid"
        status=$?
        kill -KILL "$guardian_pid" 2>/dev/null || true
        wait "$guardian_pid" 2>/dev/null || true
        exit "$status"
        """
        let fileBlocks = outputFileLimit.map { max(1, ($0 + 1_023) / 1_024) } ?? 0
        let rewrittenArguments = arguments.map { argument in
            zip(inheritedSources, inheritedTargets).reduce(argument) { value, assignment in
                value.replacingOccurrences(
                    of: assignment.0.token,
                    with: String(assignment.1)
                )
            }
        }
        let stringArguments = [
            "/bin/sh", "-c", supervisor, "background-engine-process-supervisor",
            currentDirectory.path, String(fileBlocks), executable.path
        ] + rewrittenArguments
        let allocatedArguments = stringArguments.map { strdup($0) }
        guard allocatedArguments.allSatisfy({ $0 != nil }) else {
            allocatedArguments.forEach { free($0) }
            try? lifecycleRead.close()
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }
        defer { allocatedArguments.forEach { free($0) } }
        var mutableArguments = allocatedArguments + [nil]
        var pid: pid_t = 0
        let spawnResult = mutableArguments.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(
                &pid,
                "/bin/sh",
                &fileActions,
                &attributes,
                buffer.baseAddress!,
                environ
            )
        }
        try? lifecycleRead.close()
        guard spawnResult == 0, pid > 1 else {
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }

        let childPID = pid
        let state = State()
        Thread.detachNewThread { [childPID, state] in
            autoreleasepool {
                var waitStatus: Int32 = 0
                while Darwin.waitpid(childPID, &waitStatus, 0) == -1 {
                    if errno != EINTR {
                        state.beginCompleting()
                        _ = Darwin.kill(-childPID, SIGKILL)
                        state.complete(status: -1)
                        return
                    }
                }
                // The launcher may exit after forking helpers. Its isolated process group cannot be
                // considered complete until every remaining member is terminated as well.
                state.beginCompleting()
                _ = Darwin.kill(-childPID, SIGKILL)
                waitForProcessGroupExit(childPID, timeout: 5)
                let terminatingSignal = waitStatus & 0x7f
                let status = terminatingSignal == 0
                    ? (waitStatus >> 8) & 0xff
                    : 128 + terminatingSignal
                state.complete(status: status)
            }
        }
        return SupervisedChildProcess(
            processIdentifier: childPID,
            state: state,
            lifecycleWrite: lifecycleWrite
        )
    }

    /// Chooses descriptor targets after every pipe and `/dev/null` handle has
    /// been created. Targets never equal a source or a supervisor-reserved FD,
    /// so `dup2` always creates a new inheritable descriptor and cannot retain
    /// `FD_CLOEXEC` through the source==target edge case.
    static func inheritedDescriptorTargets(
        sourceDescriptors: [Int32],
        reservedDescriptors: Set<Int32>,
        preferredTarget: Int32 = 4
    ) -> [Int32]? {
        guard preferredTarget > 3, sourceDescriptors.allSatisfy({ $0 >= 0 }) else {
            return nil
        }
        var unavailable = reservedDescriptors
        unavailable.formUnion(sourceDescriptors)
        var targets: [Int32] = []
        targets.reserveCapacity(sourceDescriptors.count)
        var candidate = preferredTarget
        for _ in sourceDescriptors {
            while unavailable.contains(candidate) {
                guard candidate < Int32.max else { return nil }
                candidate += 1
            }
            targets.append(candidate)
            unavailable.insert(candidate)
            guard candidate < Int32.max else {
                if targets.count == sourceDescriptors.count { break }
                return nil
            }
            candidate += 1
        }
        return targets
    }

    private static func waitForProcessGroupExit(_ processGroup: pid_t, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            errno = 0
            if Darwin.kill(-processGroup, 0) == -1, errno == ESRCH {
                return
            }
            usleep(10_000)
        }
    }

    func waitUntilExit() async -> Int32 {
        await state.waitUntilExit()
    }

    func waitUntilExit(
        timeout: Duration,
        terminationGrace: Duration = .milliseconds(500)
    ) async throws -> (Int32, Bool) {
        let timeoutTask = Task.detached(priority: .utility) { [self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard state.claimTimeoutAndSignal(processIdentifier: processIdentifier) else { return }
            try? await Task.sleep(for: terminationGrace)
            if state.signalIfRunning(processIdentifier: processIdentifier, signal: SIGKILL) {
                closeLifecycle()
            }
        }
        let terminationStatus = await withTaskCancellationHandler {
            await state.waitUntilExit()
        } onCancel: {
            signal(SIGTERM)
            closeLifecycle()
        }
        timeoutTask.cancel()
        await timeoutTask.value
        try Task.checkCancellation()
        return (terminationStatus, state.didTimeOut)
    }

    /// Blocking bridge for legacy synchronous callers such as content scans.
    /// Timeout always tears down the entire isolated process group, not only
    /// the immediate wrapper PID.
    func waitUntilExit(timeout: TimeInterval, terminationGrace: TimeInterval = 0.5) -> (Int32, Bool) {
        if let status = state.waitUntilExit(timeout: .now() + max(0.1, timeout)) {
            return (status, false)
        }

        guard state.claimTimeoutAndSignal(processIdentifier: processIdentifier) else {
            let status = state.waitUntilExit(timeout: .now() + 2) ?? -1
            return (status, false)
        }
        if state.waitUntilExit(timeout: .now() + max(0, terminationGrace)) == nil {
            _ = state.signalIfRunning(processIdentifier: processIdentifier, signal: SIGKILL)
            closeLifecycle()
        }
        let status = state.waitUntilExit(timeout: .now() + 2) ?? -1
        return (status, true)
    }

    func closeLifecycle() {
        lifecycleLock.withLock {
            guard lifecycleIsOpen else { return }
            lifecycleIsOpen = false
            try? lifecycleWrite.close()
        }
    }

    func signal(_ signal: Int32) {
        _ = state.signalIfRunning(processIdentifier: processIdentifier, signal: signal)
    }
}

// Preserve the internal name used by the SteamCMD regression suite while the
// same hardened supervisor is shared by the bundled media runtime.
typealias SteamCMDChildProcess = SupervisedChildProcess

public actor SteamCMDRunner {
    typealias InstallerDownloader = @Sendable (URL) async throws -> (URL, URLResponse)

    public static let installerURL = URL(
        string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz"
    )!

    private let paths: SteamCMDRuntimePaths
    private let installerDownloader: InstallerDownloader
    private var process: SteamCMDChildProcess?
    private var installationInProgress = false
    private var activeRunID: UUID?
    private var cancelledRunIDs: Set<UUID> = []
    private var outputLimitExceededRunIDs: Set<UUID> = []
    private var timedOutRunIDs: Set<UUID> = []
    private var status = WorkshopDownloadStatus(itemID: nil, phase: .idle, progress: nil, message: "Ready")
    private var recentOutput: [String] = []
    private var activeLogURL: URL?

    public init(paths: SteamCMDRuntimePaths) {
        self.paths = paths
        self.installerDownloader = { try await URLSession.shared.download(from: $0) }
    }

    init(paths: SteamCMDRuntimePaths, installerDownloader: @escaping InstallerDownloader) {
        self.paths = paths
        self.installerDownloader = installerDownloader
    }

    public func installIfNeeded() async throws {
        try SteamCMDRuntimeCommitter.recoverIfNeeded(runtimeRoot: paths.root)
        if FileManager.default.fileExists(atPath: paths.executable.path) {
            guard Self.isRegularExecutable(paths.executable) else {
                throw SteamCMDRunnerError.unsafeRuntimeExecutable
            }
            return
        }
        guard !installationInProgress else {
            throw SteamCMDRunnerError.operationInProgress
        }
        installationInProgress = true
        defer { installationInProgress = false }
        status = WorkshopDownloadStatus(
            itemID: nil,
            phase: .installingSteamCMD,
            progress: nil,
            message: "Installing the Valve SteamCMD runtime…"
        )
        let fileManager = FileManager.default
        let parent = paths.root.deletingLastPathComponent()
        let installationDirectory = parent.appending(
            path: ".background-engine-steamcmd-install-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: installationDirectory, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: installationDirectory) }

            let (temporaryURL, response) = try await installerDownloader(Self.installerURL)
            defer { try? fileManager.removeItem(at: temporaryURL) }
            guard let http = response as? HTTPURLResponse,
                  Self.isTrustedInstallerResponse(http) else {
                throw SteamCMDRunnerError.installerDownloadFailed
            }
            try SteamCMDArchiveValidator.validateDownloadedArchive(at: temporaryURL)

            let archive = installationDirectory.appending(path: "steamcmd_osx.tar.gz")
            let listing = installationDirectory.appending(path: "archive-entries.txt")
            let verboseListing = installationDirectory.appending(path: "archive-metadata.txt")
            let stagedRuntime = installationDirectory.appending(path: "runtime", directoryHint: .isDirectory)
            try fileManager.moveItem(at: temporaryURL, to: archive)
            try fileManager.createDirectory(at: stagedRuntime, withIntermediateDirectories: false)

            do {
                try await run(
                    executable: URL(filePath: "/usr/bin/tar"),
                    arguments: ["-tzf", archive.path],
                    itemID: nil,
                    currentDirectory: installationDirectory,
                    capturedOutput: listing,
                    capturedOutputLimit: SteamCMDArchiveValidator.maximumListingBytes,
                    timeout: .seconds(30)
                )
                _ = try SteamCMDArchiveValidator.validateListing(at: listing)
                try await run(
                    executable: URL(filePath: "/usr/bin/tar"),
                    arguments: ["-tzvf", archive.path, "--numeric-owner"],
                    itemID: nil,
                    currentDirectory: installationDirectory,
                    capturedOutput: verboseListing,
                    capturedOutputLimit: SteamCMDArchiveValidator.maximumListingBytes,
                    timeout: .seconds(30)
                )
                try SteamCMDArchiveValidator.validateVerboseListing(at: verboseListing)
                try await run(
                    executable: URL(filePath: "/usr/bin/tar"),
                    arguments: ["-xzf", archive.path, "-C", stagedRuntime.path, "--no-same-owner"],
                    itemID: nil,
                    currentDirectory: installationDirectory,
                    timeout: .seconds(60)
                )
                try SteamCMDArchiveValidator.validateExtractedTree(at: stagedRuntime)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SteamCMDRunnerError.installerArchiveUnsafe
            }

            let stagedExecutable = stagedRuntime.appending(path: "steamcmd.sh")
            guard Self.isRegularFile(stagedExecutable) else {
                throw SteamCMDRunnerError.installerMissingExecutable
            }
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedExecutable.path)
            try SteamCMDRuntimeCommitter.commit(stagedRoot: stagedRuntime, runtimeRoot: paths.root)
            guard Self.isRegularExecutable(paths.executable) else {
                throw SteamCMDRunnerError.unsafeRuntimeExecutable
            }
            status = WorkshopDownloadStatus(itemID: nil, phase: .idle, progress: nil, message: "SteamCMD is ready")
        } catch is CancellationError {
            status = WorkshopDownloadStatus(
                itemID: nil,
                phase: .cancelled,
                progress: nil,
                message: "SteamCMD installation cancelled"
            )
            throw CancellationError()
        } catch {
            status = WorkshopDownloadStatus(
                itemID: nil,
                phase: .failed,
                progress: nil,
                message: error.localizedDescription
            )
            throw error
        }
    }

    public func download(itemID: WorkshopItemID) async throws -> URL {
        try await installIfNeeded()
        status = WorkshopDownloadStatus(
            itemID: itemID.rawValue,
            phase: .downloading,
            progress: nil,
            message: "Downloading Workshop item \(itemID.rawValue)…"
        )
        let command = SteamCMDCommandBuilder.download(itemID: itemID, runtime: paths.root)
        do {
            try await run(executable: command.executable, arguments: command.arguments, itemID: itemID)
        } catch is CancellationError {
            status = WorkshopDownloadStatus(
                itemID: itemID.rawValue,
                phase: .cancelled,
                progress: nil,
                message: "Download cancelled"
            )
            throw CancellationError()
        } catch {
            status = WorkshopDownloadStatus(
                itemID: itemID.rawValue,
                phase: .failed,
                progress: nil,
                message: error.localizedDescription
            )
            throw error
        }
        let result = paths.workshopItem(itemID)
        guard FileManager.default.fileExists(atPath: result.path) else {
            if recentOutput.joined(separator: "\n").localizedCaseInsensitiveContains("failed") {
                throw SteamCMDRunnerError.anonymousDownloadUnavailable(itemID.rawValue)
            }
            throw SteamCMDRunnerError.downloadMissing(itemID.rawValue)
        }
        status = WorkshopDownloadStatus(
            itemID: itemID.rawValue,
            phase: .completed,
            progress: 1,
            message: "Workshop item downloaded"
        )
        return result
    }

    public func cancel() async {
        if let activeRunID {
            cancelledRunIDs.insert(activeRunID)
        }
        if let child = process {
            if child.isRunning {
                child.signal(SIGTERM)
                for _ in 0..<10 where child.isRunning {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            if child.isRunning {
                child.signal(SIGKILL)
            }
            // `waitUntilExit` completes only after the supervisor is reaped
            // and its isolated process group has disappeared. Do not expose a
            // Cancelled state while a TERM-resistant wrapper/helper is still
            // visible to the system.
            _ = await child.waitUntilExit()
        }
        status = WorkshopDownloadStatus(
            itemID: status.itemID,
            phase: .cancelled,
            progress: nil,
            message: "Download cancelled"
        )
    }

    public func currentStatus() -> WorkshopDownloadStatus {
        // Do not make visible progress depend solely on the 200 ms monitor
        // task receiving executor time. Under a loaded test runner (or a busy
        // desktop), callers can poll before that task is scheduled even though
        // SteamCMD has already flushed a progress line to the bounded log.
        if let activeLogURL,
           status.phase == .downloading,
           let rawItemID = status.itemID,
           let itemID = WorkshopItemID(rawValue: rawItemID) {
            refreshDownloadProgress(from: activeLogURL, itemID: itemID)
        }
        return status
    }

    public func diagnostics() -> SteamCMDDiagnostics {
        SteamCMDDiagnostics(
            runtimePath: paths.root.path,
            executablePresent: Self.isRegularExecutable(paths.executable),
            activeItemID: status.itemID,
            phase: status.phase,
            recentOutput: recentOutput
        )
    }

    private func run(
        executable: URL,
        arguments: [String],
        itemID: WorkshopItemID?,
        currentDirectory: URL? = nil,
        capturedOutput: URL? = nil,
        capturedOutputLimit: UInt64? = nil,
        timeout: Duration? = nil
    ) async throws {
        guard process == nil, activeRunID == nil else { throw SteamCMDRunnerError.operationInProgress }
        let runID = UUID()
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "background-engine-steamcmd-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        var outputHandle: FileHandle?
        do {
            if let capturedOutput {
                FileManager.default.createFile(atPath: capturedOutput.path, contents: nil)
                outputHandle = try FileHandle(forWritingTo: capturedOutput)
            }
        } catch {
            try? logHandle.close()
            try? FileManager.default.removeItem(at: logURL)
            throw error
        }
        let child: SteamCMDChildProcess
        do {
            child = try SteamCMDChildProcess.spawn(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory ?? paths.root,
                standardOutput: outputHandle ?? logHandle,
                standardError: logHandle,
                outputFileLimit: capturedOutputLimit
            )
        } catch {
            try? outputHandle?.close()
            try? logHandle.close()
            try? FileManager.default.removeItem(at: logURL)
            throw error
        }
        var outputMonitor: Task<Void, Never>?
        let deadline = timeout.map { ContinuousClock.now.advanced(by: $0) }
        activeRunID = runID
        activeLogURL = logURL
        process = child

        defer {
            outputMonitor?.cancel()
            try? outputHandle?.close()
            try? logHandle.close()
            if process === child {
                process = nil
            }
            if activeRunID == runID {
                activeLogURL = nil
                activeRunID = nil
            }
            cancelledRunIDs.remove(runID)
            outputLimitExceededRunIDs.remove(runID)
            timedOutRunIDs.remove(runID)
            loadRecentOutput(from: logURL)
            try? FileManager.default.removeItem(at: logURL)
        }

        do {
            outputMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    await self?.refreshProcessOutput(
                        from: logURL,
                        itemID: itemID,
                        capturedOutput: capturedOutput,
                        capturedOutputLimit: capturedOutputLimit,
                        runID: runID,
                        deadline: deadline
                    )
                }
            }
            let terminationStatus = await withTaskCancellationHandler {
                await child.waitUntilExit()
            } onCancel: {
                child.signal(SIGTERM)
                Task { [weak self] in
                    await self?.forceKillRunAfterCancellation(
                        runID: runID,
                        processIdentifier: child.processIdentifier
                    )
                }
            }
            guard terminationStatus == 0 else {
                throw SteamCMDRunnerError.processFailed(terminationStatus)
            }
            if cancelledRunIDs.contains(runID) || Task.isCancelled {
                throw CancellationError()
            }
            if let capturedOutput,
               let capturedOutputLimit,
               Self.fileSize(at: capturedOutput) > capturedOutputLimit {
                throw SteamCMDRunnerError.installerArchiveUnsafe
            }
        } catch {
            let wasCancelled = cancelledRunIDs.contains(runID) || Task.isCancelled
            if wasCancelled {
                child.signal(SIGKILL)
                throw CancellationError()
            }
            if outputLimitExceededRunIDs.contains(runID) {
                throw SteamCMDRunnerError.installerArchiveUnsafe
            }
            if timedOutRunIDs.contains(runID) {
                throw SteamCMDRunnerError.installerArchiveUnsafe
            }
            throw error
        }
    }

    private func loadRecentOutput(from url: URL) {
        recentOutput = recentOutputLines(from: url)
    }

    private func refreshProcessOutput(
        from url: URL,
        itemID: WorkshopItemID?,
        capturedOutput: URL?,
        capturedOutputLimit: UInt64?,
        runID: UUID,
        deadline: ContinuousClock.Instant?
    ) {
        if let deadline, ContinuousClock.now >= deadline, activeRunID == runID {
            timedOutRunIDs.insert(runID)
            if let process, process.isRunning {
                process.signal(SIGKILL)
            }
            return
        }
        if let capturedOutput,
           let capturedOutputLimit,
           Self.fileSize(at: capturedOutput) > capturedOutputLimit,
           activeRunID == runID {
            outputLimitExceededRunIDs.insert(runID)
            if let process, process.isRunning {
                process.signal(SIGKILL)
            }
            return
        }
        let lines = recentOutputLines(from: url)
        recentOutput = lines
        if let itemID {
            refreshDownloadProgress(from: lines, itemID: itemID)
        }
    }

    private func refreshDownloadProgress(from url: URL, itemID: WorkshopItemID) {
        let lines = recentOutputLines(from: url)
        recentOutput = lines
        refreshDownloadProgress(from: lines, itemID: itemID)
    }

    private func refreshDownloadProgress(from lines: [String], itemID: WorkshopItemID) {
        guard status.phase == .downloading,
              status.itemID == itemID.rawValue,
              let progress = lines.reversed().compactMap(Self.downloadProgress).first else {
            return
        }
        status = WorkshopDownloadStatus(
            itemID: itemID.rawValue,
            phase: .downloading,
            progress: progress,
            message: "Downloading Workshop item \(itemID.rawValue)… \(Int((progress * 100).rounded()))%"
        )
    }

    private func recentOutputLines(from url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let maximumBytes: UInt64 = 256 * 1_024
        guard let length = try? handle.seekToEnd() else { return [] }
        try? handle.seek(toOffset: length > maximumBytes ? length - maximumBytes : 0)
        let output = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return Array(output.split(separator: "\n").suffix(80).map(String.init))
    }

    private static func downloadProgress(from line: String) -> Double? {
        let lowercased = line.lowercased()
        guard let marker = lowercased.range(of: "progress:") else { return nil }
        let suffix = lowercased[marker.upperBound...].drop { $0.isWhitespace }
        let number = suffix.prefix { $0.isNumber || $0 == "." }
        guard !number.isEmpty, let percentage = Double(number), percentage.isFinite else {
            return nil
        }
        return min(max(percentage / 100, 0), 1)
    }

    private static func isRegularExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path) && isRegularFile(url)
    }

    private static func isTrustedInstallerResponse(_ response: HTTPURLResponse) -> Bool {
        guard response.statusCode == 200,
              let url = response.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == installerURL.host?.lowercased()
            && components.user == nil
            && components.password == nil
            && (components.port == nil || components.port == 443)
    }

    private static func fileSize(at url: URL) -> UInt64 {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return UInt64(max(0, size ?? 0))
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func forceKillRunAfterCancellation(runID: UUID, processIdentifier: Int32) async {
        try? await Task.sleep(for: .milliseconds(500))
        guard activeRunID == runID else { return }
        if let process, process.processIdentifier == processIdentifier {
            process.signal(SIGKILL)
        }
    }
}

enum SteamCMDArchiveValidator {
    static let maximumArchiveBytes: UInt64 = 64 * 1_024 * 1_024
    static let maximumListingBytes: UInt64 = 4 * 1_024 * 1_024
    static let maximumEntries = 10_000
    static let maximumExpandedBytes: UInt64 = 512 * 1_024 * 1_024

    private static let protectedTopLevelNames: Set<String> = [
        "config", "logs", "package", "steamapps", "userdata", "steamcmd_osx.tar.gz"
    ]

    static func validateDownloadedArchive(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              UInt64(size) <= maximumArchiveBytes else {
            throw SteamCMDRunnerError.installerArchiveUnsafe
        }
    }

    @discardableResult
    static func validateListing(at url: URL) throws -> Set<String> {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard UInt64(data.count) <= maximumListingBytes,
              let listing = String(data: data, encoding: .utf8) else {
            throw SteamCMDRunnerError.installerArchiveUnsafe
        }
        return try validateListedPaths(listing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    }

    @discardableResult
    static func validateListedPaths(_ paths: [String]) throws -> Set<String> {
        guard paths.count <= maximumEntries else {
            throw SteamCMDRunnerError.installerArchiveUnsafe
        }
        var normalizedPaths: Set<String> = []
        for rawPath in paths {
            let normalized = try normalize(rawPath)
            guard let normalized else { continue }
            guard normalizedPaths.insert(normalized).inserted else {
                throw SteamCMDRunnerError.installerArchiveUnsafe
            }
        }
        guard normalizedPaths.contains("steamcmd.sh"),
              normalizedPaths.contains("steamcmd") else {
            throw SteamCMDRunnerError.installerMissingExecutable
        }
        return normalizedPaths
    }

    static func validateVerboseListing(at url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard UInt64(data.count) <= maximumListingBytes,
              let listing = String(data: data, encoding: .utf8) else {
            throw SteamCMDRunnerError.installerArchiveUnsafe
        }
        let lines = listing.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty, lines.count <= maximumEntries else {
            throw SteamCMDRunnerError.installerArchiveUnsafe
        }
        var expandedBytes: UInt64 = 0
        for line in lines {
            guard let type = line.first, type == "-" || type == "d" || type == "l" else {
                throw SteamCMDRunnerError.installerArchiveUnsafe
            }
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 9, let declaredSize = UInt64(fields[4]) else {
                throw SteamCMDRunnerError.installerArchiveUnsafe
            }
            let addition = expandedBytes.addingReportingOverflow(declaredSize)
            guard !addition.overflow, addition.partialValue <= maximumExpandedBytes else {
                throw SteamCMDRunnerError.installerArchiveUnsafe
            }
            expandedBytes = addition.partialValue
        }
    }

    static func validateExtractedTree(at root: URL) throws {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
                ],
                options: []
              ) else {
            throw SteamCMDRunnerError.installerArchiveUnsafe
        }

        var entryCount = 0
        var expandedBytes: UInt64 = 0
        for case let item as URL in enumerator {
            entryCount += 1
            let relativeComponents = item.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count)
            _ = try normalize(relativeComponents.joined(separator: "/"))
            guard entryCount <= maximumEntries,
                  isInside(item.standardizedFileURL, root: root.standardizedFileURL) else {
                throw SteamCMDRunnerError.installerArchiveUnsafe
            }
            let values = try item.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            if values.isSymbolicLink == true {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: item.path)
                guard !(destination as NSString).isAbsolutePath else {
                    throw SteamCMDRunnerError.installerArchiveUnsafe
                }
                let resolved = item.deletingLastPathComponent()
                    .appending(path: destination)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                guard isInsideOrEqual(resolved, root: canonicalRoot),
                      FileManager.default.fileExists(atPath: item.path) else {
                    throw SteamCMDRunnerError.installerArchiveUnsafe
                }
            } else if values.isRegularFile == true {
                guard let fileSize = values.fileSize, fileSize >= 0 else {
                    throw SteamCMDRunnerError.installerArchiveUnsafe
                }
                let addition = expandedBytes.addingReportingOverflow(UInt64(fileSize))
                guard !addition.overflow, addition.partialValue <= maximumExpandedBytes else {
                    throw SteamCMDRunnerError.installerArchiveUnsafe
                }
                expandedBytes = addition.partialValue
            } else if values.isDirectory != true {
                throw SteamCMDRunnerError.installerArchiveUnsafe
            }
        }

        guard isRegularFile(root.appending(path: "steamcmd.sh")),
              isRegularFile(root.appending(path: "steamcmd")) else {
            throw SteamCMDRunnerError.installerMissingExecutable
        }
    }

    private static func normalize(_ untrustedPath: String) throws -> String? {
        var path = untrustedPath
        if path.hasSuffix("\r") { path.removeLast() }
        guard path.utf8.count <= 2_048,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.contains("\\"),
              !(path as NSString).isAbsolutePath else {
            throw SteamCMDRunnerError.installerArchiveUnsafe
        }
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty || path == "." { return nil }

        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count <= 64,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let topLevel = components.first,
              !topLevel.hasPrefix("."),
              !protectedTopLevelNames.contains(topLevel.lowercased()) else {
            throw SteamCMDRunnerError.installerArchiveUnsafe
        }
        return components.joined(separator: "/")
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let urlComponents = url.pathComponents
        return urlComponents.count > rootComponents.count
            && Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func isInsideOrEqual(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let urlComponents = url.pathComponents
        return urlComponents.count >= rootComponents.count
            && Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }
}

enum SteamCMDRuntimeCommitter {
    struct TransactionPaths {
        let marker: URL
        let candidate: URL
        let backup: URL
        let retired: URL
    }

    private struct TransactionRecord: Codable {
        let version: Int
        let incomingNames: [String]
    }

    static func commit(
        stagedRoot: URL,
        runtimeRoot: URL,
        afterInstallingEntry: ((String) throws -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        let stagedValues = try stagedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard stagedValues.isDirectory == true, stagedValues.isSymbolicLink != true else {
            throw SteamCMDRunnerError.installerArchiveUnsafe
        }
        let parent = runtimeRoot.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try recoverIfNeeded(runtimeRoot: runtimeRoot)

        if !itemExists(at: runtimeRoot) {
            try fileManager.moveItem(at: stagedRoot, to: runtimeRoot)
            return
        }
        let runtimeValues = try runtimeRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard runtimeValues.isDirectory == true, runtimeValues.isSymbolicLink != true else {
            throw SteamCMDRunnerError.unsafeRuntimeExecutable
        }

        let entries = try fileManager.contentsOfDirectory(
            at: stagedRoot,
            includingPropertiesForKeys: nil,
            options: []
        )
        let incomingNames = entries.map(\.lastPathComponent).sorted {
            if $0 == "steamcmd.sh" { return false }
            if $1 == "steamcmd.sh" { return true }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
        guard incomingNames.contains("steamcmd.sh") else {
            throw SteamCMDRunnerError.installerMissingExecutable
        }

        let transaction = transactionPaths(for: runtimeRoot)
        guard !itemExists(at: transaction.marker),
              !itemExists(at: transaction.candidate),
              !itemExists(at: transaction.backup),
              !itemExists(at: transaction.retired) else {
            throw SteamCMDRunnerError.installerCommitRollbackFailed
        }
        let record = TransactionRecord(version: 1, incomingNames: incomingNames)
        try JSONEncoder().encode(record).write(
            to: transaction.marker,
            options: .atomic
        )

        do {
            try fileManager.moveItem(at: stagedRoot, to: transaction.candidate)
            try fileManager.moveItem(at: runtimeRoot, to: transaction.backup)
            try fileManager.moveItem(at: transaction.candidate, to: runtimeRoot)
            for name in incomingNames {
                try afterInstallingEntry?(name)
            }
            try preserveUnmatchedEntries(
                from: transaction.backup,
                to: runtimeRoot,
                incomingNames: Set(incomingNames)
            )
            try fileManager.moveItem(at: transaction.backup, to: transaction.retired)
            try fileManager.removeItem(at: transaction.marker)
            try? fileManager.removeItem(at: transaction.retired)
        } catch {
            do {
                try recoverTransaction(
                    runtimeRoot: runtimeRoot,
                    record: record,
                    transaction: transaction,
                    restoredCandidate: stagedRoot
                )
            } catch {
                throw SteamCMDRunnerError.installerCommitRollbackFailed
            }
            throw error
        }
    }

    static func recoverIfNeeded(runtimeRoot: URL) throws {
        let fileManager = FileManager.default
        let transaction = transactionPaths(for: runtimeRoot)
        guard itemExists(at: transaction.marker) else {
            if itemExists(at: transaction.retired) {
                try? fileManager.removeItem(at: transaction.retired)
            }
            return
        }
        do {
            let data = try Data(contentsOf: transaction.marker)
            let record = try JSONDecoder().decode(TransactionRecord.self, from: data)
            guard record.version == 1,
                  !record.incomingNames.isEmpty,
                  Set(record.incomingNames).count == record.incomingNames.count else {
                throw SteamCMDRunnerError.installerCommitRollbackFailed
            }
            try recoverTransaction(
                runtimeRoot: runtimeRoot,
                record: record,
                transaction: transaction,
                restoredCandidate: nil
            )
        } catch let error as SteamCMDRunnerError {
            throw error
        } catch {
            if itemExists(at: runtimeRoot),
               !itemExists(at: transaction.candidate),
               !itemExists(at: transaction.backup),
               !itemExists(at: transaction.retired) {
                try fileManager.removeItem(at: transaction.marker)
                return
            }
            throw SteamCMDRunnerError.installerCommitRollbackFailed
        }
    }

    static func transactionPaths(for runtimeRoot: URL) -> TransactionPaths {
        let parent = runtimeRoot.deletingLastPathComponent()
        let prefix = ".\(runtimeRoot.lastPathComponent)-runtime-transaction"
        return TransactionPaths(
            marker: parent.appending(path: "\(prefix).json"),
            candidate: parent.appending(path: "\(prefix)-candidate", directoryHint: .isDirectory),
            backup: parent.appending(path: "\(prefix)-backup", directoryHint: .isDirectory),
            retired: parent.appending(path: "\(prefix)-retired", directoryHint: .isDirectory)
        )
    }

    private static func recoverTransaction(
        runtimeRoot: URL,
        record: TransactionRecord,
        transaction: TransactionPaths,
        restoredCandidate: URL?
    ) throws {
        let fileManager = FileManager.default
        let backupExists = itemExists(at: transaction.backup)
        let retiredExists = itemExists(at: transaction.retired)
        guard !(backupExists && retiredExists) else {
            throw SteamCMDRunnerError.installerCommitRollbackFailed
        }
        let previousRuntime = backupExists ? transaction.backup : (retiredExists ? transaction.retired : nil)

        if let previousRuntime {
            if itemExists(at: runtimeRoot) {
                guard !itemExists(at: transaction.candidate) else {
                    throw SteamCMDRunnerError.installerCommitRollbackFailed
                }
                try fileManager.moveItem(at: runtimeRoot, to: transaction.candidate)
            }
            guard itemExists(at: transaction.candidate), !itemExists(at: runtimeRoot) else {
                throw SteamCMDRunnerError.installerCommitRollbackFailed
            }
            try restorePreservedEntries(
                from: transaction.candidate,
                to: previousRuntime,
                incomingNames: Set(record.incomingNames)
            )
            try fileManager.moveItem(at: previousRuntime, to: runtimeRoot)
        } else if !itemExists(at: runtimeRoot) {
            throw SteamCMDRunnerError.installerCommitRollbackFailed
        }

        if itemExists(at: transaction.candidate) {
            if let restoredCandidate, !itemExists(at: restoredCandidate) {
                try fileManager.moveItem(at: transaction.candidate, to: restoredCandidate)
            } else {
                try fileManager.removeItem(at: transaction.candidate)
            }
        }
        try fileManager.removeItem(at: transaction.marker)
    }

    private static func preserveUnmatchedEntries(
        from previousRuntime: URL,
        to newRuntime: URL,
        incomingNames: Set<String>
    ) throws {
        let fileManager = FileManager.default
        for source in try fileManager.contentsOfDirectory(
            at: previousRuntime,
            includingPropertiesForKeys: nil,
            options: []
        ) where !incomingNames.contains(source.lastPathComponent) {
            let destination = newRuntime.appending(path: source.lastPathComponent)
            guard !itemExists(at: destination) else {
                throw SteamCMDRunnerError.installerCommitRollbackFailed
            }
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    private static func restorePreservedEntries(
        from candidate: URL,
        to previousRuntime: URL,
        incomingNames: Set<String>
    ) throws {
        let fileManager = FileManager.default
        for source in try fileManager.contentsOfDirectory(
            at: candidate,
            includingPropertiesForKeys: nil,
            options: []
        ) where !incomingNames.contains(source.lastPathComponent) {
            let destination = previousRuntime.appending(path: source.lastPathComponent)
            guard !itemExists(at: destination) else {
                throw SteamCMDRunnerError.installerCommitRollbackFailed
            }
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    private static func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

public enum SteamCMDRunnerError: LocalizedError, Equatable {
    case invalidItemID
    case operationInProgress
    case installerDownloadFailed
    case installerMissingExecutable
    case unsafeRuntimeExecutable
    case processFailed(Int32)
    case downloadMissing(String)
    case anonymousDownloadUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidItemID: "Enter a numeric Workshop item ID or a valid Steam Workshop URL."
        case .operationInProgress: "Another SteamCMD operation is already running."
        case .installerDownloadFailed: "SteamCMD could not be downloaded from Valve."
        case .installerMissingExecutable: "The SteamCMD archive did not contain steamcmd.sh."
        case .unsafeRuntimeExecutable: "The SteamCMD runtime contains an unsafe or non-regular steamcmd.sh. Remove the local SteamCMD runtime and retry."
        case .processFailed(let status): "SteamCMD exited with status \(status)."
        case .downloadMissing(let id): "SteamCMD finished without installing Workshop item \(id)."
        case .anonymousDownloadUnavailable(let id):
            "Valve did not allow anonymous download of item \(id). Open it in Steam on a licensed Windows installation, then copy and import its folder."
        }
    }
}

extension SteamCMDRunnerError {
    static var installerArchiveUnsafe: SteamCMDRuntimeError { .installerArchiveUnsafe }
    static var installerCommitRollbackFailed: SteamCMDRuntimeError { .installerCommitRollbackFailed }
    static var processLaunchFailed: SteamCMDRuntimeError { .processLaunchFailed }
}

@objc(BackgroundEngineSteamCMDRunnerXPCProtocol)
public protocol SteamCMDRunnerXPCProtocol {
    func install(reply: @escaping @Sendable (NSDictionary) -> Void)
    func download(itemID: String, reply: @escaping @Sendable (NSDictionary) -> Void)
    func cancel(reply: @escaping @Sendable (NSDictionary) -> Void)
    func status(reply: @escaping @Sendable (NSDictionary) -> Void)
    func diagnostics(reply: @escaping @Sendable (NSDictionary) -> Void)
}

public enum SteamCMDXPCPayload {
    public static func success<T: Encodable>(_ value: T) -> NSDictionary {
        do {
            let data = try JSONEncoder().encode(value)
            return ["ok": true, "data": data]
        } catch {
            return failure(error)
        }
    }

    public static func success() -> NSDictionary { ["ok": true] }

    public static func failure(_ error: any Error) -> NSDictionary {
        ["ok": false, "error": error.localizedDescription]
    }

    public static func decode<T: Decodable>(_ type: T.Type, from payload: NSDictionary) throws -> T {
        guard payload["ok"] as? Bool == true else {
            throw SteamCMDXPCClientError.remoteFailure(payload["error"] as? String ?? "Unknown XPC error")
        }
        guard let data = payload["data"] as? Data else {
            throw SteamCMDXPCClientError.invalidResponse
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

public enum SteamCMDXPCClientError: LocalizedError, Sendable {
    case invalidResponse
    case remoteFailure(String)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "SteamCMD XPC returned an invalid response."
        case .remoteFailure(let message): message
        case .unavailable: "The SteamCMD XPC service is unavailable."
        }
    }
}
