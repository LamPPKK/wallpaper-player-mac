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
                "+workshop_download_item", wallpaperEngineAppID, itemID.rawValue, "validate",
                "+quit"
            ]
        )
    }
}

enum SteamCMDOutputClassifier {
    /// SteamCMD reports an anonymous Workshop entitlement denial as an
    /// item-scoped error. Requiring both the item-download context and one of
    /// the known denial reasons prevents unrelated network, disk, or update
    /// failures from being presented as an ownership problem.
    static func indicatesAnonymousWorkshopDenial(
        _ output: [String],
        itemID: WorkshopItemID
    ) -> Bool {
        output.contains { line in
            let normalized = line.lowercased()
            guard isWorkshopItemFailureLine(normalized, itemID: itemID) else {
                return false
            }
            return anonymousDenialMarkers.contains { normalized.contains($0) }
        }
    }

    /// SteamCMD has been observed to print item-specific failures while still
    /// exiting with status zero. Match only the requested item so an unrelated
    /// diagnostic cannot make a valid cached download fail closed.
    static func indicatesWorkshopItemFailure(
        _ output: [String],
        itemID: WorkshopItemID
    ) -> Bool {
        output.contains { line in
            isWorkshopItemFailureLine(line.lowercased(), itemID: itemID)
        }
    }

    /// A Workshop directory is not proof that the current command downloaded
    /// (or even validated) the requested item. SteamCMD can exit with status
    /// zero after an item-scoped failure and may leave either stale or partial
    /// content behind. Require its item-specific success receipt before any
    /// directory may be accepted as the result of the request.
    static func indicatesWorkshopItemSuccess(
        _ output: [String],
        itemID: WorkshopItemID
    ) -> Bool {
        output.contains { line in
            let normalized = line
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let marker = "success. downloaded item "
            guard normalized.hasPrefix(marker) else {
                return false
            }
            let suffix = normalized.dropFirst(marker.count)
            guard suffix.hasPrefix(itemID.rawValue) else { return false }
            let remainder = suffix.dropFirst(itemID.rawValue.count)
            guard let boundary = remainder.first else { return true }
            if boundary.isWhitespace { return true }
            return boundary == "."
                && remainder.dropFirst().allSatisfy(\.isWhitespace)
        }
    }

    private static func isWorkshopItemFailureLine(
        _ normalizedLine: String,
        itemID: WorkshopItemID
    ) -> Bool {
        normalizedLine.contains("error! download item \(itemID.rawValue) failed")
    }

    private static let anonymousDenialMarkers = [
        "failed (access denied)",
        "failed (no subscription)",
        "failed (permission denied)"
    ]
}

struct SteamCMDOutputEvidence: Equatable, Sendable {
    var indicatesAnonymousWorkshopDenial = false
    var indicatesWorkshopItemFailure = false
    var indicatesWorkshopItemSuccess = false
}

/// Collects authorization/error evidence from the complete bounded SteamCMD
/// stream. The UI-facing diagnostics deliberately retain only a short tail,
/// which must not decide whether a Workshop result is trusted.
final class SteamCMDOutputEvidenceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let itemID: WorkshopItemID
    private var pendingBytes = Data()
    private var evidence = SteamCMDOutputEvidence()
    private var isFinished = false

    init(itemID: WorkshopItemID) {
        self.itemID = itemID
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            guard !isFinished else { return }
            pendingBytes.append(data)
            classifyCompleteLines()
        }
    }

    func finish() -> SteamCMDOutputEvidence {
        lock.withLock {
            guard !isFinished else { return evidence }
            if !pendingBytes.isEmpty {
                classify(pendingBytes)
                pendingBytes.removeAll(keepingCapacity: false)
            }
            isFinished = true
            return evidence
        }
    }

    private func classifyCompleteLines() {
        var lineStart = pendingBytes.startIndex
        while lineStart < pendingBytes.endIndex,
              let newline = pendingBytes[lineStart...].firstIndex(of: 0x0A) {
            classify(pendingBytes[lineStart..<newline])
            lineStart = pendingBytes.index(after: newline)
        }
        if lineStart > pendingBytes.startIndex {
            pendingBytes.removeSubrange(pendingBytes.startIndex..<lineStart)
        }
    }

    private func classify<Bytes: Collection>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        let line = String(decoding: bytes, as: UTF8.self)
        if !evidence.indicatesAnonymousWorkshopDenial {
            evidence.indicatesAnonymousWorkshopDenial =
                SteamCMDOutputClassifier.indicatesAnonymousWorkshopDenial([line], itemID: itemID)
        }
        if !evidence.indicatesWorkshopItemFailure {
            evidence.indicatesWorkshopItemFailure =
                SteamCMDOutputClassifier.indicatesWorkshopItemFailure([line], itemID: itemID)
        }
        if !evidence.indicatesWorkshopItemSuccess {
            evidence.indicatesWorkshopItemSuccess =
                SteamCMDOutputClassifier.indicatesWorkshopItemSuccess([line], itemID: itemID)
        }
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
    /// selected for the child. Callers can embed it in an argument such as the
    /// value of FFmpeg's `-fd __BACKGROUND_ENGINE_INPUT__` option without
    /// guessing which parent descriptors the supervisor will allocate later.
    let argumentToken: String
}

/// Runs a trusted executable in an isolated process group and guarantees that
/// descendants cannot outlive either the command or the owning process.
///
/// The launcher intentionally stays internal. XPC callers still select from
/// fixed SteamCMD operations and can never provide an arbitrary command.
final class SupervisedChildProcess: @unchecked Sendable {
    /// A PID is not a stable identity after a process exits. Pair it with the
    /// kernel-reported start time before retaining or signalling it so a busy
    /// system cannot turn descendant cleanup into a signal for a reused PID.
    private struct ProcessIdentity: Hashable, Sendable {
        let processIdentifier: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let userIdentifier: uid_t
    }

    /// Process groups cover the normal SteamCMD tree, but `setsid()` and
    /// `setpgid()` deliberately detach a helper from that group. macOS does
    /// not expose a public job-object equivalent. A dedicated inherited pipe
    /// therefore acts as a kernel ownership token: cleanup finds every
    /// same-user process holding that exact pipe endpoint even after its
    /// ancestry and process group have changed. An ancestry inventory remains
    /// as defense in depth for ordinary helpers.
    private final class DescendantContainment: @unchecked Sendable {
        private let root: ProcessIdentity
        private let owner: ProcessIdentity
        private let ownerProcessGroup: pid_t
        private let containmentPipeHandle: UInt64
        private let ancestryPollingIntervalMicroseconds: useconds_t?
        private let lock = NSLock()
        private var tracked: Set<ProcessIdentity>
        private var stopped = false

        init?(
            rootProcessIdentifier: pid_t,
            ownerProcessIdentifier: pid_t,
            ownerProcessGroup: pid_t,
            containmentPipeHandle: UInt64,
            ancestryPollingIntervalMicroseconds: useconds_t?
        ) {
            guard containmentPipeHandle != 0,
                  ownerProcessGroup > 1,
                  let root = Self.identity(for: rootProcessIdentifier),
                  let owner = Self.identity(for: ownerProcessIdentifier),
                  root != owner else {
                return nil
            }
            self.root = root
            self.owner = owner
            self.ownerProcessGroup = ownerProcessGroup
            self.containmentPipeHandle = containmentPipeHandle
            self.ancestryPollingIntervalMicroseconds = ancestryPollingIntervalMicroseconds
            self.tracked = [root]
        }

        func startTracking() {
            captureDescendants()
            guard let ancestryPollingIntervalMicroseconds else { return }
            Thread.detachNewThread { [self] in
                autoreleasepool {
                    while lock.withLock({ !stopped }) {
                        captureDescendants()
                        usleep(ancestryPollingIntervalMicroseconds)
                    }
                }
            }
        }

        func stopTracking() {
            lock.withLock { stopped = true }
        }

        func signal(processGroup: pid_t, signal: Int32) {
            captureDescendants(includeContainmentTokenOwners: true)
            // Keep the supervisor alive long enough to reap its direct
            // command. Killing the group leader first can leave a detached
            // session leader as a zombie owned by launchd, making cleanup
            // completion nondeterministic.
            signalTrackedProcesses(signal, excludingRoot: true)
            // Catch helpers forked concurrently with the first snapshot. The
            // already-detached parent remains a tracked traversal root.
            captureDescendants(includeContainmentTokenOwners: true)
            signalTrackedProcesses(signal, excludingRoot: true)

            guard signal == SIGKILL else { return }

            // A direct escaped child is still waitable by the supervisor.
            // Give the shell a short opportunity to reap it and its guardian
            // before the final process-group escalation.
            let reapingDeadline = Date().addingTimeInterval(0.5)
            while Self.isCurrentIdentity(root),
                  hasLiveTrackedProcess(excludingRoot: true),
                  Date() < reapingDeadline {
                usleep(10_000)
                captureDescendants(includeContainmentTokenOwners: true)
                signalTrackedProcesses(SIGKILL, excludingRoot: true)
            }

            if canSignalProcessGroup(processGroup) {
                _ = Darwin.kill(-processGroup, SIGKILL)
            }
            if isSafeToSignal(root) {
                _ = Darwin.kill(root.processIdentifier, SIGKILL)
            }
        }

        func terminateAndWait(processGroup: pid_t, timeout: TimeInterval) {
            let deadline = Date().addingTimeInterval(max(0, timeout))
            var consecutiveEmptyTokenScans = 0
            repeat {
                signal(processGroup: processGroup, signal: SIGKILL)
                usleep(10_000)
                // Scan after the known holders have received SIGKILL. A
                // process can fork in the final instant before signal
                // delivery; its child inherits the token and appears here
                // even though the original tracked identity is already gone.
                captureDescendants(includeContainmentTokenOwners: true)
                if hasLiveTrackedProcess() {
                    consecutiveEmptyTokenScans = 0
                } else {
                    consecutiveEmptyTokenScans += 1
                    if consecutiveEmptyTokenScans >= 2 { return }
                }
            } while Date() < deadline

            // Make the final state deterministic even when the timeout is
            // reached: perform one last rescan and KILL pass before waiters
            // are released.
            captureDescendants(includeContainmentTokenOwners: true)
            signal(processGroup: processGroup, signal: SIGKILL)
        }

        private func captureDescendants(includeContainmentTokenOwners: Bool = false) {
            let seeds = lock.withLock { tracked.filter(Self.isCurrentIdentity) }
            var discovered = Set(seeds)
            var queue = Array(seeds)
            var nextIndex = 0

            if includeContainmentTokenOwners {
                for identity in Self.processIdentitiesHoldingPipe(
                    containmentPipeHandle,
                    userIdentifier: root.userIdentifier
                ) where !isProtectedOwner(identity) && discovered.insert(identity).inserted {
                    queue.append(identity)
                }
            }

            // Group enumeration closes the small gap between a fork and the
            // recursive parent scan. Only enumerate while a retained identity
            // still proves that this PGID belongs to the supervised launch.
            if seeds.contains(where: {
                Self.processGroupIdentifier(for: $0) == root.processIdentifier
            }) {
                for processIdentifier in Self.processIdentifiers(
                    inProcessGroup: root.processIdentifier
                ) {
                    if let identity = Self.identity(for: processIdentifier),
                       Self.processGroupIdentifier(for: identity) == root.processIdentifier,
                       !isProtectedOwner(identity),
                       discovered.insert(identity).inserted {
                        queue.append(identity)
                    }
                }
            }

            while nextIndex < queue.count {
                let parent = queue[nextIndex]
                nextIndex += 1
                for childPID in Self.childProcessIdentifiers(of: parent.processIdentifier) {
                    guard let child = Self.identity(for: childPID),
                          Self.parentProcessIdentifier(for: child) == parent.processIdentifier,
                          !isProtectedOwner(child),
                          !discovered.contains(child) else {
                        continue
                    }
                    discovered.insert(child)
                    queue.append(child)
                }
            }

            lock.withLock {
                tracked.formUnion(discovered)
                tracked = Set(tracked.filter {
                    Self.isCurrentIdentity($0) && !isProtectedOwner($0)
                })
            }
        }

        private func signalTrackedProcesses(_ signal: Int32, excludingRoot: Bool) {
            let identities = lock.withLock { tracked }
            for identity in identities.sorted(by: {
                $0.processIdentifier > $1.processIdentifier
            }) where (!excludingRoot || identity != root) && isSafeToSignal(identity) {
                _ = Darwin.kill(identity.processIdentifier, signal)
            }
        }

        private func hasLiveTrackedProcess(excludingRoot: Bool = false) -> Bool {
            lock.withLock {
                tracked.contains { identity in
                    (!excludingRoot || identity != root) && isSafeToSignal(identity)
                }
            }
        }

        private func hasTrackedProcess(inProcessGroup processGroup: pid_t) -> Bool {
            lock.withLock {
                tracked.contains { identity in
                    isSafeToSignal(identity)
                        && Self.processGroupIdentifier(for: identity) == processGroup
                }
            }
        }

        /// The owner can legitimately hold other launch/lifecycle descriptors.
        /// It must never become a cleanup target even if a kernel descriptor
        /// query or a future setup regression associates it with this token.
        private func isProtectedOwner(_ identity: ProcessIdentity) -> Bool {
            identity == owner || identity.processIdentifier == getpid()
        }

        private func isSafeToSignal(_ identity: ProcessIdentity) -> Bool {
            identity.processIdentifier > 1
                && !isProtectedOwner(identity)
                && Self.isCurrentIdentity(identity)
        }

        private func canSignalProcessGroup(_ processGroup: pid_t) -> Bool {
            processGroup > 1
                && processGroup == root.processIdentifier
                && processGroup != ownerProcessGroup
                && processGroup != Darwin.getpgrp()
                && hasTrackedProcess(inProcessGroup: processGroup)
        }

        static func containmentPipeHandle(fileDescriptor: Int32) -> UInt64? {
            guard fileDescriptor >= 0 else { return nil }
            var info = pipe_fdinfo()
            let expectedSize = Int32(MemoryLayout<pipe_fdinfo>.size)
            let result = proc_pidfdinfo(
                getpid(),
                fileDescriptor,
                PROC_PIDFDPIPEINFO,
                &info,
                expectedSize
            )
            guard result == expectedSize, info.pipeinfo.pipe_handle != 0 else {
                return nil
            }
            return info.pipeinfo.pipe_handle
        }

        /// Establishes the launch invariant before any cleanup object capable
        /// of signalling descendants is created: the isolated child owns the
        /// token and the caller does not. The all-process scan also proves the
        /// public libproc enumeration path is usable for this launch.
        static func isContainmentEstablished(
            rootProcessIdentifier: pid_t,
            ownerProcessIdentifier: pid_t,
            pipeHandle: UInt64
        ) -> Bool {
            guard let root = identity(for: rootProcessIdentifier),
                  let owner = identity(for: ownerProcessIdentifier),
                  root != owner,
                  processHoldsPipe(root, pipeHandle: pipeHandle),
                  !processHoldsPipe(owner, pipeHandle: pipeHandle) else {
                return false
            }
            let holders = processIdentitiesHoldingPipe(
                pipeHandle,
                userIdentifier: root.userIdentifier
            )
            return holders.contains(root) && !holders.contains(owner)
        }

        private static func processIdentitiesHoldingPipe(
            _ pipeHandle: UInt64,
            userIdentifier: uid_t
        ) -> Set<ProcessIdentity> {
            var matches: Set<ProcessIdentity> = []
            for processIdentifier in allProcessIdentifiers() {
                guard let identity = identity(for: processIdentifier),
                      identity.userIdentifier == userIdentifier,
                      processHoldsPipe(identity, pipeHandle: pipeHandle) else {
                    continue
                }
                matches.insert(identity)
            }
            return matches
        }

        private static func processHoldsPipe(
            _ identity: ProcessIdentity,
            pipeHandle: UInt64
        ) -> Bool {
            guard isCurrentIdentity(identity) else { return false }
            let descriptorSize = MemoryLayout<proc_fdinfo>.size
            let suggestedBytes = proc_pidinfo(
                identity.processIdentifier,
                PROC_PIDLISTFDS,
                0,
                nil,
                0
            )
            guard suggestedBytes > 0 else { return false }

            var capacity = max(16, Int(suggestedBytes) / descriptorSize + 8)
            while capacity <= 65_536 {
                var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
                let returnedBytes = descriptors.withUnsafeMutableBytes { bytes in
                    proc_pidinfo(
                        identity.processIdentifier,
                        PROC_PIDLISTFDS,
                        0,
                        bytes.baseAddress,
                        Int32(bytes.count)
                    )
                }
                guard returnedBytes > 0 else { return false }
                let descriptorCount = min(
                    capacity,
                    Int(returnedBytes) / descriptorSize
                )
                for descriptor in descriptors.prefix(descriptorCount)
                    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_PIPE) {
                    var pipeInfo = pipe_fdinfo()
                    let expectedSize = Int32(MemoryLayout<pipe_fdinfo>.size)
                    let result = proc_pidfdinfo(
                        identity.processIdentifier,
                        descriptor.proc_fd,
                        PROC_PIDFDPIPEINFO,
                        &pipeInfo,
                        expectedSize
                    )
                    if result == expectedSize,
                       pipeInfo.pipeinfo.pipe_handle == pipeHandle,
                       isCurrentIdentity(identity) {
                        return true
                    }
                }
                if Int(returnedBytes) < capacity * descriptorSize {
                    return false
                }
                capacity *= 2
            }
            return false
        }

        private static func allProcessIdentifiers() -> [pid_t] {
            let suggestedCount = max(0, Int(proc_listallpids(nil, 0)))
            var capacity = max(1_024, suggestedCount + 64)
            while capacity <= 131_072 {
                var processes = [pid_t](repeating: 0, count: capacity)
                let count = processes.withUnsafeMutableBytes { bytes in
                    proc_listallpids(bytes.baseAddress, Int32(bytes.count))
                }
                guard count >= 0 else { return [] }
                if count < capacity {
                    return Array(processes.prefix(Int(count))).filter { $0 > 1 }
                }
                capacity *= 2
            }
            return []
        }

        private static func identity(for processIdentifier: pid_t) -> ProcessIdentity? {
            guard processIdentifier > 1 else { return nil }
            var info = proc_bsdinfo()
            let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let result = proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                &info,
                expectedSize
            )
            guard result == expectedSize,
                  info.pbi_pid == UInt32(processIdentifier) else {
                return nil
            }
            return ProcessIdentity(
                processIdentifier: processIdentifier,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec,
                userIdentifier: info.pbi_uid
            )
        }

        private static func isCurrentIdentity(_ identity: ProcessIdentity) -> Bool {
            Self.identity(for: identity.processIdentifier) == identity
        }

        private static func processGroupIdentifier(for identity: ProcessIdentity) -> pid_t? {
            guard Self.isCurrentIdentity(identity) else { return nil }
            let processGroup = Darwin.getpgid(identity.processIdentifier)
            return processGroup > 1 ? processGroup : nil
        }

        private static func parentProcessIdentifier(for identity: ProcessIdentity) -> pid_t? {
            var info = proc_bsdinfo()
            let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let result = proc_pidinfo(
                identity.processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                &info,
                expectedSize
            )
            guard result == expectedSize,
                  info.pbi_pid == UInt32(identity.processIdentifier),
                  info.pbi_start_tvsec == identity.startSeconds,
                  info.pbi_start_tvusec == identity.startMicroseconds,
                  info.pbi_uid == identity.userIdentifier else {
                return nil
            }
            return pid_t(info.pbi_ppid)
        }

        private static func childProcessIdentifiers(of parent: pid_t) -> [pid_t] {
            var capacity = 32
            while capacity <= 16_384 {
                var buffer = [pid_t](repeating: 0, count: capacity)
                let count = buffer.withUnsafeMutableBytes { bytes in
                    proc_listchildpids(parent, bytes.baseAddress, Int32(bytes.count))
                }
                guard count >= 0 else { return [] }
                if count < capacity {
                    return Array(buffer.prefix(Int(count))).filter { $0 > 1 }
                }
                capacity *= 2
            }
            return []
        }

        private static func processIdentifiers(inProcessGroup processGroup: pid_t) -> [pid_t] {
            var capacity = 32
            while capacity <= 16_384 {
                var buffer = [pid_t](repeating: 0, count: capacity)
                let count = buffer.withUnsafeMutableBytes { bytes in
                    proc_listpgrppids(processGroup, bytes.baseAddress, Int32(bytes.count))
                }
                guard count >= 0 else { return [] }
                if count < capacity {
                    return Array(buffer.prefix(Int(count))).filter { $0 > 1 }
                }
                capacity *= 2
            }
            return []
        }
    }

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
        private let containment: DescendantContainment

        init?(
            rootProcessIdentifier: pid_t,
            ownerProcessIdentifier: pid_t,
            ownerProcessGroup: pid_t,
            containmentPipeHandle: UInt64,
            ancestryPollingIntervalMicroseconds: useconds_t?
        ) {
            guard let containment = DescendantContainment(
                rootProcessIdentifier: rootProcessIdentifier,
                ownerProcessIdentifier: ownerProcessIdentifier,
                ownerProcessGroup: ownerProcessGroup,
                containmentPipeHandle: containmentPipeHandle,
                ancestryPollingIntervalMicroseconds: ancestryPollingIntervalMicroseconds
            ) else {
                return nil
            }
            self.containment = containment
            completion.enter()
            containment.startTracking()
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
            containment.stopTracking()
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
            let claimed = lock.withLock {
                guard case .running = phase, processIdentifier > 1 else { return false }
                timedOut = true
                return true
            }
            if claimed {
                containment.signal(processGroup: processIdentifier, signal: SIGTERM)
            }
            return claimed
        }

        func signalIfRunning(processIdentifier: Int32, signal: Int32) -> Bool {
            let shouldSignal = lock.withLock {
                guard processIdentifier > 1 else { return false }
                if case .exited = phase { return false }
                return true
            }
            if shouldSignal {
                containment.signal(processGroup: processIdentifier, signal: signal)
            }
            return shouldSignal
        }

        func terminateDescendantsAndWait(processIdentifier: Int32, timeout: TimeInterval) {
            containment.terminateAndWait(
                processGroup: processIdentifier,
                timeout: timeout
            )
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
        inheritedFileDescriptors: [InheritedFileDescriptor] = [],
        ancestryPollingIntervalMicroseconds: useconds_t? = 20_000,
        isolateProcessGroup: Bool = true,
        retainContainmentTokenInParent: Bool = false,
        postCleanupHandoffReadyFile: URL? = nil,
        postCleanupHandoffReleaseFile: URL? = nil
    ) throws -> SupervisedChildProcess {
        let ownerProcessIdentifier = getpid()
        let ownerProcessGroup = Darwin.getpgrp()
        guard ownerProcessIdentifier > 1,
              ownerProcessGroup > 1,
              (postCleanupHandoffReadyFile == nil) ==
                (postCleanupHandoffReleaseFile == nil) else {
            throw SupervisedProcessError.launchFailed
        }

        let lifecycle = Pipe()
        let lifecycleRead = lifecycle.fileHandleForReading
        let lifecycleWrite = lifecycle.fileHandleForWriting
        let containmentToken = Pipe()
        let containmentRead = containmentToken.fileHandleForReading
        let containmentWrite = containmentToken.fileHandleForWriting
        let guardianReadiness = Pipe()
        let guardianReadinessRead = guardianReadiness.fileHandleForReading
        let guardianReadinessWrite = guardianReadiness.fileHandleForWriting
        defer {
            try? lifecycleRead.close()
            try? containmentRead.close()
            try? containmentWrite.close()
            try? guardianReadinessRead.close()
            try? guardianReadinessWrite.close()
        }
        guard let containmentPipeHandle = DescendantContainment.containmentPipeHandle(
            fileDescriptor: containmentRead.fileDescriptor
        ),
              configureLifecycleWriteDescriptor(lifecycleWrite.fileDescriptor),
              Darwin.fcntl(containmentRead.fileDescriptor, F_SETFD, FD_CLOEXEC) != -1,
              Darwin.fcntl(containmentWrite.fileDescriptor, F_SETFD, FD_CLOEXEC) != -1,
              Darwin.fcntl(guardianReadinessRead.fileDescriptor, F_SETFD, FD_CLOEXEC) != -1,
              Darwin.fcntl(guardianReadinessWrite.fileDescriptor, F_SETFD, FD_CLOEXEC) != -1 else {
            try? lifecycleRead.close()
            try? lifecycleWrite.close()
            try? containmentRead.close()
            try? containmentWrite.close()
            try? guardianReadinessRead.close()
            try? guardianReadinessWrite.close()
            throw SupervisedProcessError.launchFailed
        }

        // Snapshot child endpoints above the standard range so one dup2
        // action cannot overwrite a source needed by a later action when the
        // caller has an unusual descriptor layout.
        let lifecycleSpawnDescriptor = Darwin.fcntl(
            lifecycleRead.fileDescriptor,
            F_DUPFD_CLOEXEC,
            64
        )
        guard lifecycleSpawnDescriptor >= 0 else {
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }
        let lifecycleSpawnRead = FileHandle(
            fileDescriptor: lifecycleSpawnDescriptor,
            closeOnDealloc: true
        )
        defer { try? lifecycleSpawnRead.close() }

        let containmentSpawnDescriptor = Darwin.fcntl(
            containmentRead.fileDescriptor,
            F_DUPFD_CLOEXEC,
            64
        )
        guard containmentSpawnDescriptor >= 0 else {
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }
        let containmentSpawnRead = FileHandle(
            fileDescriptor: containmentSpawnDescriptor,
            closeOnDealloc: true
        )
        defer { try? containmentSpawnRead.close() }

        // The owner-death guardian keeps the peer endpoint open. Without a
        // peer, lsof reports an empty name for anonymous pipe descriptors and
        // cannot correlate escaped holders after the Swift owner is gone.
        let containmentSpawnWriteDescriptor = Darwin.fcntl(
            containmentWrite.fileDescriptor,
            F_DUPFD_CLOEXEC,
            64
        )
        guard containmentSpawnWriteDescriptor >= 0 else {
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }
        let containmentSpawnWrite = FileHandle(
            fileDescriptor: containmentSpawnWriteDescriptor,
            closeOnDealloc: true
        )
        defer { try? containmentSpawnWrite.close() }

        let guardianReadinessSpawnReadDescriptor = Darwin.fcntl(
            guardianReadinessRead.fileDescriptor,
            F_DUPFD_CLOEXEC,
            64
        )
        guard guardianReadinessSpawnReadDescriptor >= 0 else {
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }
        let guardianReadinessSpawnRead = FileHandle(
            fileDescriptor: guardianReadinessSpawnReadDescriptor,
            closeOnDealloc: true
        )
        defer { try? guardianReadinessSpawnRead.close() }

        let guardianReadinessSpawnWriteDescriptor = Darwin.fcntl(
            guardianReadinessWrite.fileDescriptor,
            F_DUPFD_CLOEXEC,
            64
        )
        guard guardianReadinessSpawnWriteDescriptor >= 0 else {
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }
        let guardianReadinessSpawnWrite = FileHandle(
            fileDescriptor: guardianReadinessSpawnWriteDescriptor,
            closeOnDealloc: true
        )
        defer { try? guardianReadinessSpawnWrite.close() }

        let retainedContainmentDescriptor: Int32
        if retainContainmentTokenInParent {
            retainedContainmentDescriptor = Darwin.fcntl(
                containmentRead.fileDescriptor,
                F_DUPFD_CLOEXEC,
                128
            )
            guard retainedContainmentDescriptor >= 0 else {
                try? lifecycleRead.close()
                try? lifecycleWrite.close()
                try? containmentRead.close()
                try? containmentWrite.close()
                throw SupervisedProcessError.launchFailed
            }
        } else {
            retainedContainmentDescriptor = -1
        }
        defer {
            if retainedContainmentDescriptor >= 0 {
                Darwin.close(retainedContainmentDescriptor)
            }
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
        let containmentFD: Int32 = 4
        let guardianReadinessReadFD: Int32 = 5
        let guardianReadinessWriteFD: Int32 = 6
        let containmentPeerFD: Int32 = 7
        var actions = [
            // Close original endpoints before assigning fixed targets; a pipe
            // endpoint may itself have been allocated as one of these FDs.
            posix_spawn_file_actions_addclose(&fileActions, lifecycleWrite.fileDescriptor),
            posix_spawn_file_actions_addclose(&fileActions, containmentWrite.fileDescriptor),
            posix_spawn_file_actions_addclose(
                &fileActions,
                guardianReadinessRead.fileDescriptor
            ),
            posix_spawn_file_actions_addclose(
                &fileActions,
                guardianReadinessWrite.fileDescriptor
            ),
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
            posix_spawn_file_actions_adddup2(
                &fileActions,
                lifecycleSpawnRead.fileDescriptor,
                lifecycleFD
            ),
            posix_spawn_file_actions_adddup2(
                &fileActions,
                containmentSpawnRead.fileDescriptor,
                containmentFD
            ),
            posix_spawn_file_actions_adddup2(
                &fileActions,
                guardianReadinessSpawnRead.fileDescriptor,
                guardianReadinessReadFD
            ),
            posix_spawn_file_actions_adddup2(
                &fileActions,
                guardianReadinessSpawnWrite.fileDescriptor,
                guardianReadinessWriteFD
            ),
            posix_spawn_file_actions_adddup2(
                &fileActions,
                containmentSpawnWrite.fileDescriptor,
                containmentPeerFD
            )
        ]
        let reservedDescriptors = Set([
            STDIN_FILENO,
            STDOUT_FILENO,
            STDERR_FILENO,
            lifecycleFD,
            containmentFD,
            guardianReadinessReadFD,
            guardianReadinessWriteFD,
            containmentPeerFD,
            nullInput.fileDescriptor,
            standardOutput.fileDescriptor,
            standardError.fileDescriptor,
            lifecycleRead.fileDescriptor,
            lifecycleWrite.fileDescriptor,
            containmentRead.fileDescriptor,
            containmentWrite.fileDescriptor,
            lifecycleSpawnRead.fileDescriptor,
            containmentSpawnRead.fileDescriptor,
            containmentSpawnWrite.fileDescriptor,
            guardianReadinessRead.fileDescriptor,
            guardianReadinessWrite.fileDescriptor,
            guardianReadinessSpawnRead.fileDescriptor,
            guardianReadinessSpawnWrite.fileDescriptor
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

        var flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        if isolateProcessGroup {
            flags |= Int16(POSIX_SPAWN_SETPGROUP)
        }
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              (!isolateProcessGroup || posix_spawnattr_setpgroup(&attributes, 0) == 0) else {
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
        let inheritedClosures = inheritedTargets
            .map { "\($0)>&-" }
            .joined(separator: " ")
        let containmentTokenCleanup = """
        owner_uid=$1
        protected_pid_one=$2
        protected_pid_two=$3
        self_pid=$$
        cleanup_fail() {
            printf 'Background Engine containment cleanup failed: %s\n' "$1" >&2
            exit 125
        }
        case "$owner_uid:$protected_pid_one:$protected_pid_two:$self_pid" in
            *[!0-9:]*|:*|*::*|*:) cleanup_fail invalid_identity ;;
        esac
        [ "$protected_pid_one" -gt 1 ] && \
            [ "$protected_pid_two" -gt 1 ] && \
            [ "$self_pid" -gt 1 ] || cleanup_fail unsafe_identity
        [ -x /usr/sbin/lsof ] || cleanup_fail missing_lsof
        trap '' HUP TERM PIPE

        # The direct command may have double-forked, reparented to launchd,
        # and created a new session. Its inherited FD 4 remains a kernel token
        # even after both ancestry and process-group relationships disappear.
        # Require two clean snapshots so a final concurrent fork cannot escape.
        empty_scans=0
        attempts=0
        while [ "$attempts" -lt 128 ] && [ "$empty_scans" -lt 2 ]; do
            attempts=$((attempts + 1))
            token_snapshot=$(
                # Close the token on the command-substitution shell itself,
                # not only on lsof. Otherwise that waiting helper appears as
                # a fresh victim in every snapshot and cleanup never settles.
                exec 3<&- 4<&- 5<&- 6>&- 7>&-
                /usr/sbin/lsof -nP -X -a -u "$owner_uid" -d 4 -F pftn \
                    2>/dev/null
            ) || token_snapshot=

            current_pid=
            current_fd=
            current_type=
            self_token=
            while IFS= read -r field; do
                case "$field" in
                    p*) current_pid=${field#p}; current_fd=; current_type= ;;
                    f*) current_fd=${field#f}; current_type= ;;
                    t*) current_type=${field#t} ;;
                    n*)
                        if [ "$current_pid" = "$self_pid" ] && \
                           [ "$current_fd" = 4 ] && [ "$current_type" = PIPE ]; then
                            self_token=${field#n}
                        fi
                        ;;
                esac
            done <<BACKGROUND_ENGINE_TOKEN_IDENTITY
        $token_snapshot
        BACKGROUND_ENGINE_TOKEN_IDENTITY

            if [ -z "$self_token" ]; then
                empty_scans=0
                /bin/sleep 0.02 3<&- 4<&- 5<&- 6>&- 7>&-
                continue
            fi

            victims=0
            current_pid=
            current_fd=
            current_type=
            while IFS= read -r field; do
                case "$field" in
                    p*) current_pid=${field#p}; current_fd=; current_type= ;;
                    f*) current_fd=${field#f}; current_type= ;;
                    t*) current_type=${field#t} ;;
                    n*)
                        if [ "$current_type" = PIPE ] && [ "${field#n}" = "$self_token" ]; then
                            case "$current_pid" in
                                ''|*[!0-9]*) ;;
                                "$self_pid"|"$protected_pid_one"|"$protected_pid_two") ;;
                                *)
                                    if [ "$current_pid" -gt 1 ]; then
                                        kill -KILL "$current_pid" 2>/dev/null || true
                                        victims=$((victims + 1))
                                    fi
                                    ;;
                            esac
                        fi
                        ;;
                esac
            done <<BACKGROUND_ENGINE_TOKEN_HOLDERS
        $token_snapshot
        BACKGROUND_ENGINE_TOKEN_HOLDERS

            if [ "$victims" -eq 0 ]; then
                empty_scans=$((empty_scans + 1))
            else
                empty_scans=0
            fi
            /bin/sleep 0.02 3<&- 4<&- 5<&- 6>&- 7>&-
        done
        [ "$empty_scans" -ge 2 ] || cleanup_fail timeout
        """
        let ownerDeathGuardian = """
        root_pid=$1
        owner_uid=$2
        cleanup_script=$3
        self_pid=$$
        guardian_fail() {
            printf 'Background Engine owner-death guardian failed: %s\n' "$1" >&2
            exit 125
        }
        case "$root_pid:$owner_uid:$self_pid" in
            *[!0-9:]*|:*|*::*|*:) guardian_fail invalid_identity ;;
        esac
        [ "$root_pid" -gt 1 ] && [ "$self_pid" -gt 1 ] || guardian_fail unsafe_identity
        [ -x /usr/sbin/lsof ] || guardian_fail missing_lsof
        trap '' HUP TERM PIPE

        # Validate both the exact inherited pipe endpoint and this guardian's
        # separate process group before the trusted command is allowed to run.
        readiness_snapshot=$(
            /usr/sbin/lsof -nP -X -a -p "$root_pid,$self_pid" -d 4 -F pgftn \
                3<&- 4<&- 5<&- 6>&- 7>&- 2>/dev/null
        ) || guardian_fail readiness_scan
        current_pid=
        current_fd=
        current_type=
        root_group=
        self_group=
        root_token=
        self_token=
        while IFS= read -r field; do
            case "$field" in
                p*) current_pid=${field#p}; current_fd=; current_type= ;;
                g*)
                    if [ "$current_pid" = "$root_pid" ]; then root_group=${field#g}; fi
                    if [ "$current_pid" = "$self_pid" ]; then self_group=${field#g}; fi
                    ;;
                f*) current_fd=${field#f}; current_type= ;;
                t*) current_type=${field#t} ;;
                n*)
                    if [ "$current_fd" = 4 ] && [ "$current_type" = PIPE ]; then
                        if [ "$current_pid" = "$root_pid" ]; then root_token=${field#n}; fi
                        if [ "$current_pid" = "$self_pid" ]; then self_token=${field#n}; fi
                    fi
                    ;;
            esac
        done <<BACKGROUND_ENGINE_READINESS_SNAPSHOT
        $readiness_snapshot
        BACKGROUND_ENGINE_READINESS_SNAPSHOT
        [ "$root_group" = "$root_pid" ] || guardian_fail root_group
        [ "$self_group" = "$self_pid" ] || guardian_fail guardian_group
        [ -n "$root_token" ] || guardian_fail root_token
        [ -n "$self_token" ] || guardian_fail guardian_token
        [ "$root_token" = "$self_token" ] || guardian_fail token_mismatch
        printf '%s\n' ready >&6 || guardian_fail readiness_write
        exec 6>&-

        # FD 3 reaches EOF when the owning app/XPC process closes normally or
        # is killed. Ignore unexpected data and wait for the actual close.
        while IFS= read -r lifecycle_message <&3; do :; done

        # Stop the verified supervisor group first so it cannot fork between
        # token snapshots. Revalidate both PGID and exact token immediately
        # before the negative-PID signal; the root may have exited while the
        # guardian was waiting, and an unrelated reused PGID is never a target.
        shutdown_snapshot=$(
            /usr/sbin/lsof -nP -X -a -p "$root_pid,$self_pid" -d 4 -F pgftn \
                3<&- 4<&- 5<&- 6>&- 7>&- 2>/dev/null
        ) || shutdown_snapshot=
        current_pid=
        current_fd=
        current_type=
        root_group=
        root_token=
        self_token=
        while IFS= read -r field; do
            case "$field" in
                p*) current_pid=${field#p}; current_fd=; current_type= ;;
                g*)
                    if [ "$current_pid" = "$root_pid" ]; then root_group=${field#g}; fi
                    ;;
                f*) current_fd=${field#f}; current_type= ;;
                t*) current_type=${field#t} ;;
                n*)
                    if [ "$current_fd" = 4 ] && [ "$current_type" = PIPE ]; then
                        if [ "$current_pid" = "$root_pid" ]; then root_token=${field#n}; fi
                        if [ "$current_pid" = "$self_pid" ]; then self_token=${field#n}; fi
                    fi
                    ;;
            esac
        done <<BACKGROUND_ENGINE_SHUTDOWN_SNAPSHOT
        $shutdown_snapshot
        BACKGROUND_ENGINE_SHUTDOWN_SNAPSHOT
        if [ "$root_group" = "$root_pid" ] && \
           [ -n "$root_token" ] && [ "$root_token" = "$self_token" ]; then
            kill -KILL -"$root_pid" 2>/dev/null || true
        fi

        # A transient lsof failure or a continuously-forking holder must not
        # disarm owner-death protection. Retry until the exact token is clean.
        while ! /bin/sh -c "$cleanup_script" background-engine-owner-death-cleanup \
            "$owner_uid" "$root_pid" "$self_pid" \
            3<&- 4<&4 5<&- 6>&- 7>&7; do
            /bin/sleep 0.1 3<&- 4<&- 5<&- 6>&- 7>&-
        done
        """
        let supervisor = """
        working_directory=$1
        file_blocks=$2
        guardian_script=$3
        cleanup_script=$4
        owner_uid=$5
        handoff_ready=$6
        handoff_release=$7
        shift 7
        cd "$working_directory" || exit 125
        if [ "$file_blocks" -gt 0 ]; then
            ulimit -f "$file_blocks" || exit 125
        fi
        # Do not launch the trusted command until the owning process has
        # validated process-group isolation and installed its descendant
        # tracker. FD 4 is an otherwise-unused ownership token inherited by
        # the command and every descendant that does not explicitly close it.
        IFS= read -r launch_message <&3 || exit 125
        set -m || exit 125
        /bin/sh -c "$guardian_script" background-engine-owner-death-guardian \
            "$$" "$owner_uid" "$cleanup_script" \
            3<&3 4<&4 5<&- 6>&6 7>&7 \(inheritedClosures) &
        guardian_pid=$!
        set +m || {
            kill -KILL "$guardian_pid" 2>/dev/null || true
            wait "$guardian_pid" 2>/dev/null || true
            exit 125
        }
        exec 6>&-
        exec 7>&-
        IFS= read -r guardian_message <&5
        guardian_status=$?
        exec 5<&-
        if [ "$guardian_status" -ne 0 ] || [ "$guardian_message" != ready ]; then
            kill -KILL "$guardian_pid" 2>/dev/null || true
            wait "$guardian_pid" 2>/dev/null || true
            exit 125
        fi
        "$@" 4<&4 \(inheritedRedirections) &
        command_pid=$!
        wait "$command_pid"
        status=$?

        # Keep the owner-death guardian armed while normal completion performs
        # the same exact-token cleanup. If the app/XPC dies during this handoff,
        # the guardian kills this group and independently finishes the scan.
        while ! /bin/sh -c "$cleanup_script" background-engine-normal-cleanup \
            "$owner_uid" "$$" "$guardian_pid" \
            3<&- 4<&4 5<&- 6>&- 7>&- \(inheritedClosures); do
            # Fail closed: retain both root identity and the armed guardian.
            # Cancellation or owner death closes lifecycle FD 3 and lets the
            # guardian take over instead of creating another cleanup gap.
            /bin/sleep 0.1 3<&- 4<&- 5<&- 6>&- 7>&- \(inheritedClosures)
        done
        kill -KILL "$guardian_pid" 2>/dev/null || true
        wait "$guardian_pid" 2>/dev/null || true
        exec 3<&-
        exec 4<&-

        # Internal deterministic regression hook. It runs only when both
        # absolute test paths are supplied, after token cleanup and guardian
        # disarm but before supervisor exit.
        if [ "$handoff_ready" != - ] || [ "$handoff_release" != - ]; then
            [ "$handoff_ready" != - ] && [ "$handoff_release" != - ] || exit 125
            /usr/bin/touch "$handoff_ready" \
                3<&- 4<&- 5<&- 6>&- 7>&- \(inheritedClosures) || exit 125
            while [ ! -e "$handoff_release" ]; do
                /bin/sleep 0.01 3<&- 4<&- 5<&- 6>&- 7>&- \(inheritedClosures)
            done
        fi
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
            currentDirectory.path, String(fileBlocks), ownerDeathGuardian,
            containmentTokenCleanup, String(getuid()),
            postCleanupHandoffReadyFile?.standardizedFileURL.path ?? "-",
            postCleanupHandoffReleaseFile?.standardizedFileURL.path ?? "-",
            executable.path
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
        guard spawnResult == 0, pid > 1 else {
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }

        let childPID = pid
        do {
            // A best-effort close is unsafe here. Retaining either parent
            // token endpoint makes the caller indistinguishable from a marked
            // descendant; retaining the lifecycle reader also prevents the
            // child from observing owner death. Do not arm any signalling
            // state unless every parent-side read/token close reports success.
            try lifecycleRead.close()
            try lifecycleSpawnRead.close()
            try containmentRead.close()
            try containmentSpawnRead.close()
            try containmentWrite.close()
            try containmentSpawnWrite.close()
            try guardianReadinessRead.close()
            try guardianReadinessSpawnRead.close()
            try guardianReadinessWrite.close()
            try guardianReadinessSpawnWrite.close()
        } catch {
            terminateUnverifiedChild(childPID)
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }

        // POSIX_SPAWN_SETPGROUP is a requested attribute, not an invariant we
        // may assume before sending a negative-PID signal. Verify it while the
        // child is blocked on the launch handshake. A failed verification is
        // cleaned up with the positive child PID only.
        guard childPID != ownerProcessIdentifier,
              childPID != ownerProcessGroup,
              Darwin.getpgid(childPID) == childPID,
              DescendantContainment.isContainmentEstablished(
                  rootProcessIdentifier: childPID,
                  ownerProcessIdentifier: ownerProcessIdentifier,
                  pipeHandle: containmentPipeHandle
              ) else {
            terminateUnverifiedChild(childPID)
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }

        guard let state = State(
            rootProcessIdentifier: childPID,
            ownerProcessIdentifier: ownerProcessIdentifier,
            ownerProcessGroup: ownerProcessGroup,
            containmentPipeHandle: containmentPipeHandle,
            ancestryPollingIntervalMicroseconds: ancestryPollingIntervalMicroseconds
        ) else {
            terminateUnverifiedChild(childPID)
            try? lifecycleWrite.close()
            throw SupervisedProcessError.launchFailed
        }
        Thread.detachNewThread { [childPID, state] in
            autoreleasepool {
                var waitStatus: Int32 = 0
                while Darwin.waitpid(childPID, &waitStatus, 0) == -1 {
                    if errno != EINTR {
                        state.beginCompleting()
                        state.terminateDescendantsAndWait(
                            processIdentifier: childPID,
                            timeout: 5
                        )
                        state.complete(status: -1)
                        return
                    }
                }
                // The launcher may exit after forking helpers. Completion is
                // withheld until both the original process group and tracked
                // descendants that escaped it have been terminated.
                state.beginCompleting()
                state.terminateDescendantsAndWait(
                    processIdentifier: childPID,
                    timeout: 5
                )
                let terminatingSignal = waitStatus & 0x7f
                let status = terminatingSignal == 0
                    ? (waitStatus >> 8) & 0xff
                    : 128 + terminatingSignal
                state.complete(status: status)
            }
        }
        do {
            try lifecycleWrite.write(contentsOf: Data([0x0a]))
        } catch {
            state.beginCompleting()
            state.terminateDescendantsAndWait(processIdentifier: childPID, timeout: 5)
            try? lifecycleWrite.close()
            _ = state.waitUntilExit(timeout: .now() + 5)
            throw SupervisedProcessError.launchFailed
        }
        return SupervisedChildProcess(
            processIdentifier: childPID,
            state: state,
            lifecycleWrite: lifecycleWrite
        )
    }

    /// The supervised child can exit between `posix_spawn` and the lifecycle
    /// handshake. Suppressing SIGPIPE on this descriptor lets the write report
    /// EPIPE so launch cleanup can run instead of terminating the host process.
    static func configureLifecycleWriteDescriptor(_ fileDescriptor: Int32) -> Bool {
        guard fileDescriptor >= 0 else { return false }
        return Darwin.fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC) != -1
            && Darwin.fcntl(fileDescriptor, F_SETNOSIGPIPE, 1) != -1
    }

    /// Cleanup before containment is armed must never use a process-group
    /// signal. At this point the only trustworthy relationship is that the
    /// positive PID returned by `posix_spawn` is our direct, waitable child.
    private static func terminateUnverifiedChild(_ processIdentifier: pid_t) {
        guard processIdentifier > 1, processIdentifier != getpid() else { return }
        _ = Darwin.kill(processIdentifier, SIGKILL)
        var waitStatus: Int32 = 0
        while true {
            let result = Darwin.waitpid(processIdentifier, &waitStatus, 0)
            if result == processIdentifier || (result == -1 && errno != EINTR) {
                return
            }
        }
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
                closeLifecyclePipe()
            }
        }
        let terminationStatus = await withTaskCancellationHandler {
            await state.waitUntilExit()
        } onCancel: {
            signal(SIGTERM)
            signal(SIGKILL)
            closeLifecyclePipe()
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
            closeLifecyclePipe()
        }
        let status = state.waitUntilExit(timeout: .now() + 2) ?? -1
        return (status, true)
    }

    func closeLifecycle() {
        _ = state.signalIfRunning(processIdentifier: processIdentifier, signal: SIGKILL)
        closeLifecyclePipe()
    }

    private func closeLifecyclePipe() {
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

    enum BoundedOutputResult: Equatable, Sendable {
        case completed
        case limitExceeded
        case captureFailed
        case joinTimedOut
    }

    /// Poll and drain each pipe on a dedicated thread instead of Swift's
    /// cooperative executor so a quiet child cannot starve actor calls that
    /// publish live download progress.
    final class BoundedOutputDrain: @unchecked Sendable {
        typealias FailureHandler = @Sendable () -> Void
        typealias ChunkHandler = @Sendable (Data) -> Void

        private let lock = NSLock()
        private let source: FileHandle
        private let destination: FileHandle?
        private let limit: UInt64
        private let failureHandler: FailureHandler
        private let chunkHandler: ChunkHandler?
        private var result: BoundedOutputResult?
        private var waiters: [CheckedContinuation<BoundedOutputResult, Never>] = []

        init(
            source: FileHandle,
            destination: FileHandle,
            limit: UInt64,
            failureHandler: @escaping FailureHandler,
            chunkHandler: ChunkHandler? = nil
        ) {
            self.source = source
            self.limit = limit
            self.failureHandler = failureHandler
            self.chunkHandler = chunkHandler
            let destinationDescriptor = Darwin.fcntl(
                destination.fileDescriptor,
                F_DUPFD_CLOEXEC,
                64
            )
            self.destination = destinationDescriptor >= 0
                ? FileHandle(fileDescriptor: destinationDescriptor, closeOnDealloc: true)
                : nil
            Thread.detachNewThread { [self] in
                autoreleasepool {
                    complete(with: drainBoundedOutput())
                }
            }
        }

        /// After the supervised process has exited, every legitimate writer
        /// should close promptly. A detached helper can still retain a copied
        /// stdout/stderr descriptor, so joining the drain must itself be
        /// bounded instead of trusting EOF to arrive eventually.
        func finish(within timeout: Duration) async -> BoundedOutputResult {
            await withCheckedContinuation { continuation in
                let registration = lock.withLock { () -> (BoundedOutputResult?, Bool) in
                    if let result { return (result, false) }
                    waiters.append(continuation)
                    return (nil, true)
                }
                if let completedResult = registration.0 {
                    continuation.resume(returning: completedResult)
                    return
                }
                guard registration.1 else { return }
                let boundedTimeout = timeout > .zero ? timeout : .milliseconds(1)
                Task.detached(priority: .utility) { [weak self] in
                    do {
                        try await Task.sleep(for: boundedTimeout)
                    } catch {
                        return
                    }
                    self?.complete(with: .joinTimedOut)
                }
            }
        }

        private func complete(with result: BoundedOutputResult) {
            let completion: (Bool, [CheckedContinuation<BoundedOutputResult, Never>]) = lock.withLock {
                guard self.result == nil else { return (false, []) }
                self.result = result
                let waiting = waiters
                waiters.removeAll(keepingCapacity: false)
                return (true, waiting)
            }
            guard completion.0 else { return }
            if result == .limitExceeded || result == .captureFailed {
                failureHandler()
            }
            completion.1.forEach { $0.resume(returning: result) }
        }

        private var shouldStop: Bool {
            lock.withLock { result == .joinTimedOut }
        }

        private func drainBoundedOutput() -> BoundedOutputResult {
            defer { try? source.close() }
            defer { try? destination?.close() }
            guard let destination else { return .captureFailed }

            let descriptor = source.fileDescriptor
            let existingFlags = Darwin.fcntl(descriptor, F_GETFL)
            guard existingFlags >= 0,
                  Darwin.fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK) == 0 else {
                return .captureFailed
            }

            var written: UInt64 = 0
            var storage = [UInt8](repeating: 0, count: 64 * 1_024)
            while !shouldStop {
                var monitored = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN) | Int16(POLLHUP) | Int16(POLLERR),
                    revents: 0
                )
                let pollResult = Darwin.poll(&monitored, 1, 100)
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    return .captureFailed
                }
                if pollResult == 0 { continue }
                if monitored.revents & Int16(POLLNVAL) != 0 {
                    return .captureFailed
                }

                while !shouldStop {
                    let count = storage.withUnsafeMutableBytes { bytes in
                        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                    }
                    if count > 0 {
                        let data = Data(storage.prefix(count))
                        let remaining = limit > written ? limit - written : 0
                        guard UInt64(data.count) <= remaining else {
                            if remaining > 0 {
                                do {
                                    try destination.write(
                                        contentsOf: Data(data.prefix(Int(remaining)))
                                    )
                                } catch {
                                    return .captureFailed
                                }
                            }
                            return .limitExceeded
                        }
                        do {
                            try destination.write(contentsOf: data)
                        } catch {
                            return .captureFailed
                        }
                        written += UInt64(data.count)
                        chunkHandler?(data)
                        continue
                    }
                    if count == 0 { return .completed }
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    return .captureFailed
                }
            }
            return .joinTimedOut
        }
    }

    static let defaultDownloadTimeout: Duration = .seconds(2 * 60 * 60)
    static let defaultLogOutputLimit: UInt64 = 8 * 1_024 * 1_024
    static let defaultOutputDrainJoinTimeout: Duration = .seconds(5)

    public static let installerURL = URL(
        string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz"
    )!

    private let paths: SteamCMDRuntimePaths
    private let installerDownloader: InstallerDownloader
    private let downloadTimeout: Duration
    private let logOutputLimit: UInt64
    private var process: SteamCMDChildProcess?
    private var installationInProgress = false
    private var activeRunID: UUID?
    private var cancelledRunIDs: Set<UUID> = []
    private var status = WorkshopDownloadStatus(itemID: nil, phase: .idle, progress: nil, message: "Ready")
    private var recentOutput: [String] = []
    private var recentEvidence = SteamCMDOutputEvidence()
    private var activeLogURL: URL?

    public init(paths: SteamCMDRuntimePaths) {
        self.paths = paths
        self.installerDownloader = { try await URLSession.shared.download(from: $0) }
        self.downloadTimeout = Self.defaultDownloadTimeout
        self.logOutputLimit = Self.defaultLogOutputLimit
    }

    init(
        paths: SteamCMDRuntimePaths,
        installerDownloader: @escaping InstallerDownloader,
        downloadTimeout: Duration = SteamCMDRunner.defaultDownloadTimeout,
        logOutputLimit: UInt64 = SteamCMDRunner.defaultLogOutputLimit
    ) {
        self.paths = paths
        self.installerDownloader = installerDownloader
        self.downloadTimeout = downloadTimeout
        self.logOutputLimit = logOutputLimit
    }

    init(
        paths: SteamCMDRuntimePaths,
        downloadTimeout: Duration,
        logOutputLimit: UInt64 = SteamCMDRunner.defaultLogOutputLimit
    ) {
        self.paths = paths
        self.installerDownloader = { try await URLSession.shared.download(from: $0) }
        self.downloadTimeout = downloadTimeout
        self.logOutputLimit = logOutputLimit
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
        let result = paths.workshopItem(itemID)
        status = WorkshopDownloadStatus(
            itemID: itemID.rawValue,
            phase: .downloading,
            progress: nil,
            message: "Downloading Workshop item \(itemID.rawValue)…"
        )
        let command = SteamCMDCommandBuilder.download(itemID: itemID, runtime: paths.root)
        do {
            try await run(
                executable: command.executable,
                arguments: command.arguments,
                itemID: itemID,
                timeout: downloadTimeout
            )
        } catch is CancellationError {
            status = WorkshopDownloadStatus(
                itemID: itemID.rawValue,
                phase: .cancelled,
                progress: nil,
                message: "Download cancelled"
            )
            throw CancellationError()
        } catch {
            let reportedError: any Error
            if let runnerError = error as? SteamCMDRunnerError,
               case .processFailed = runnerError,
               recentEvidence.indicatesAnonymousWorkshopDenial {
                reportedError = SteamCMDRunnerError.anonymousDownloadUnavailable(itemID.rawValue)
            } else {
                reportedError = error
            }
            status = WorkshopDownloadStatus(
                itemID: itemID.rawValue,
                phase: .failed,
                progress: nil,
                message: reportedError.localizedDescription
            )
            throw reportedError
        }
        if recentEvidence.indicatesAnonymousWorkshopDenial {
            let error = SteamCMDRunnerError.anonymousDownloadUnavailable(itemID.rawValue)
            status = WorkshopDownloadStatus(
                itemID: itemID.rawValue,
                phase: .failed,
                progress: nil,
                message: error.localizedDescription
            )
            throw error
        }
        if recentEvidence.indicatesWorkshopItemFailure {
            let error = SteamCMDRunnerError.downloadMissing(itemID.rawValue)
            status = WorkshopDownloadStatus(
                itemID: itemID.rawValue,
                phase: .failed,
                progress: nil,
                message: error.localizedDescription
            )
            throw error
        }
        if !recentEvidence.indicatesWorkshopItemSuccess {
            let error = SteamCMDRunnerError.downloadMissing(itemID.rawValue)
            status = WorkshopDownloadStatus(
                itemID: itemID.rawValue,
                phase: .failed,
                progress: nil,
                message: error.localizedDescription
            )
            throw error
        }
        var resultAttributes = stat()
        guard Darwin.lstat(result.path, &resultAttributes) == 0,
              resultAttributes.st_mode & S_IFMT == S_IFDIR else {
            let error = SteamCMDRunnerError.downloadMissing(itemID.rawValue)
            status = WorkshopDownloadStatus(
                itemID: itemID.rawValue,
                phase: .failed,
                progress: nil,
                message: error.localizedDescription
            )
            throw error
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
        recentEvidence = SteamCMDOutputEvidence()
        let evidenceTracker = itemID.map(SteamCMDOutputEvidenceTracker.init)
        let runID = UUID()
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "background-engine-steamcmd-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        var outputHandle: FileHandle?
        let logPipe = Pipe()
        var capturedOutputPipe: Pipe?
        do {
            if let capturedOutput {
                FileManager.default.createFile(atPath: capturedOutput.path, contents: nil)
                outputHandle = try FileHandle(forWritingTo: capturedOutput)
                capturedOutputPipe = Pipe()
            }
        } catch {
            try? logPipe.fileHandleForReading.close()
            try? logPipe.fileHandleForWriting.close()
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
                standardOutput: capturedOutputPipe?.fileHandleForWriting
                    ?? logPipe.fileHandleForWriting,
                standardError: logPipe.fileHandleForWriting,
                // RLIMIT_FSIZE applies to every file the child writes, not
                // only its redirected output. Applying the log cap here would
                // corrupt otherwise-valid Workshop items larger than the cap.
                // Dedicated pipe drains below enforce per-stream limits.
                outputFileLimit: nil
            )
        } catch {
            try? capturedOutputPipe?.fileHandleForReading.close()
            try? capturedOutputPipe?.fileHandleForWriting.close()
            try? logPipe.fileHandleForReading.close()
            try? logPipe.fileHandleForWriting.close()
            try? outputHandle?.close()
            try? logHandle.close()
            try? FileManager.default.removeItem(at: logURL)
            throw error
        }
        try? capturedOutputPipe?.fileHandleForWriting.close()
        try? logPipe.fileHandleForWriting.close()

        let logDrain = BoundedOutputDrain(
            source: logPipe.fileHandleForReading,
            destination: logHandle,
            limit: logOutputLimit,
            failureHandler: { child.signal(SIGKILL) },
            chunkHandler: { data in evidenceTracker?.consume(data) }
        )
        let capturedOutputDrain: BoundedOutputDrain?
        if let capturedOutputPipe, let outputHandle {
            capturedOutputDrain = BoundedOutputDrain(
                source: capturedOutputPipe.fileHandleForReading,
                destination: outputHandle,
                limit: capturedOutputLimit ?? UInt64.max,
                failureHandler: { child.signal(SIGKILL) }
            )
        } else {
            capturedOutputDrain = nil
        }
        var outputMonitor: Task<Void, Never>?
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
            recentEvidence = evidenceTracker?.finish() ?? SteamCMDOutputEvidence()
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
                        runID: runID
                    )
                }
            }
            var terminationStatus: Int32 = -1
            var didTimeOut = false
            var waitError: (any Error)?
            do {
                if let timeout {
                    (terminationStatus, didTimeOut) = try await child.waitUntilExit(
                        timeout: timeout
                    )
                } else {
                    terminationStatus = await withTaskCancellationHandler {
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
                }
            } catch {
                waitError = error
            }

            async let pendingLogDrainResult = logDrain.finish(
                within: Self.defaultOutputDrainJoinTimeout
            )
            async let pendingCapturedOutputDrainResult = capturedOutputDrain?.finish(
                within: Self.defaultOutputDrainJoinTimeout
            )
            let (logDrainResult, capturedOutputDrainResult) = await (
                pendingLogDrainResult,
                pendingCapturedOutputDrainResult
            )
            outputMonitor?.cancel()
            if let outputMonitor {
                await outputMonitor.value
            }
            outputMonitor = nil

            if cancelledRunIDs.contains(runID) || Task.isCancelled {
                throw CancellationError()
            }
            if logDrainResult == .limitExceeded {
                if let itemID {
                    throw SteamCMDOperationError.outputLimitExceeded(itemID.rawValue)
                }
                throw SteamCMDRunnerError.installerArchiveUnsafe
            }
            if capturedOutputDrainResult == .limitExceeded {
                throw SteamCMDRunnerError.installerArchiveUnsafe
            }
            if didTimeOut {
                if let itemID {
                    throw SteamCMDOperationError.downloadTimedOut(itemID.rawValue)
                }
                throw SteamCMDRunnerError.installerArchiveUnsafe
            }
            let outputCaptureFailed = logDrainResult == .captureFailed
                || capturedOutputDrainResult == .captureFailed
                || logDrainResult == .joinTimedOut
                || capturedOutputDrainResult == .joinTimedOut
            if outputCaptureFailed {
                if let itemID {
                    throw SteamCMDOperationError.outputCaptureFailed(itemID.rawValue)
                }
                throw SteamCMDRunnerError.installerArchiveUnsafe
            }
            if let waitError {
                throw waitError
            }
            guard terminationStatus == 0 else {
                throw SteamCMDRunnerError.processFailed(terminationStatus)
            }
        } catch {
            if cancelledRunIDs.contains(runID) || Task.isCancelled {
                child.signal(SIGKILL)
                throw CancellationError()
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
        runID: UUID
    ) {
        guard activeRunID == runID else { return }
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
        case .downloadMissing(let id):
            "SteamCMD finished without installing Workshop item \(id). Retry, or install it through Steam on a licensed Windows system and import its folder."
        case .anonymousDownloadUnavailable(let id):
            "Valve did not allow anonymous download of item \(id). Open it in Steam on a licensed Windows installation, then copy and import its folder."
        }
    }
}

private enum SteamCMDOperationError: LocalizedError {
    case downloadTimedOut(String)
    case outputLimitExceeded(String)
    case outputCaptureFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadTimedOut(let id):
            "SteamCMD timed out while downloading Workshop item \(id). Retry the item or import a legally obtained local copy."
        case .outputLimitExceeded(let id):
            "SteamCMD produced too much output while downloading Workshop item \(id) and was stopped. Export diagnostics before retrying."
        case .outputCaptureFailed(let id):
            "SteamCMD output could not be captured while downloading Workshop item \(id). Export diagnostics before retrying."
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
