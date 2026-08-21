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

public actor SteamCMDRunner {
    public static let installerURL = URL(
        string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz"
    )!

    private let paths: SteamCMDRuntimePaths
    private var process: Process?
    private var activeRunID: UUID?
    private var cancelledRunIDs: Set<UUID> = []
    private var status = WorkshopDownloadStatus(itemID: nil, phase: .idle, progress: nil, message: "Ready")
    private var recentOutput: [String] = []

    public init(paths: SteamCMDRuntimePaths) {
        self.paths = paths
    }

    public func installIfNeeded() async throws {
        if FileManager.default.fileExists(atPath: paths.executable.path) {
            guard Self.isRegularExecutable(paths.executable) else {
                throw SteamCMDRunnerError.unsafeRuntimeExecutable
            }
            return
        }
        status = WorkshopDownloadStatus(
            itemID: nil,
            phase: .installingSteamCMD,
            progress: nil,
            message: "Installing the Valve SteamCMD runtime…"
        )
        do {
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            let (temporaryURL, response) = try await URLSession.shared.download(from: Self.installerURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw SteamCMDRunnerError.installerDownloadFailed
            }
            if FileManager.default.fileExists(atPath: paths.archive.path) {
                try FileManager.default.removeItem(at: paths.archive)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: paths.archive)
            try await run(
                executable: URL(filePath: "/usr/bin/tar"),
                arguments: ["-xzf", paths.archive.path, "-C", paths.root.path],
                itemID: nil
            )
            guard Self.isRegularFile(paths.executable) else {
                throw SteamCMDRunnerError.installerMissingExecutable
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.executable.path)
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
        if let child = process, child.isRunning {
            child.terminate()
            for _ in 0..<10 where child.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if child.isRunning {
                Darwin.kill(child.processIdentifier, SIGKILL)
            }
            for _ in 0..<20 where child.isRunning {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        status = WorkshopDownloadStatus(
            itemID: status.itemID,
            phase: .cancelled,
            progress: nil,
            message: "Download cancelled"
        )
    }

    public func currentStatus() -> WorkshopDownloadStatus { status }

    public func diagnostics() -> SteamCMDDiagnostics {
        SteamCMDDiagnostics(
            runtimePath: paths.root.path,
            executablePresent: Self.isRegularExecutable(paths.executable),
            activeItemID: status.itemID,
            phase: status.phase,
            recentOutput: recentOutput
        )
    }

    private func run(executable: URL, arguments: [String], itemID: WorkshopItemID?) async throws {
        guard process == nil, activeRunID == nil else { throw SteamCMDRunnerError.operationInProgress }
        let runID = UUID()
        activeRunID = runID
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "background-engine-steamcmd-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = paths.root
        child.standardOutput = logHandle
        child.standardError = logHandle
        process = child
        var outputMonitor: Task<Void, Never>?

        defer {
            outputMonitor?.cancel()
            try? logHandle.close()
            if process === child {
                process = nil
            }
            if activeRunID == runID {
                activeRunID = nil
            }
            cancelledRunIDs.remove(runID)
            loadRecentOutput(from: logURL)
            try? FileManager.default.removeItem(at: logURL)
        }

        do {
            try child.run()
            outputMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    await self?.refreshProcessOutput(from: logURL, itemID: itemID)
                }
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    child.terminationHandler = { process in
                        if process.terminationStatus == 0 {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: SteamCMDRunnerError.processFailed(process.terminationStatus))
                        }
                    }
                }
            } onCancel: {
                child.terminate()
            }
            if cancelledRunIDs.contains(runID) || Task.isCancelled {
                throw CancellationError()
            }
        } catch {
            let wasCancelled = cancelledRunIDs.contains(runID) || Task.isCancelled
            if wasCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func loadRecentOutput(from url: URL) {
        recentOutput = recentOutputLines(from: url)
    }

    private func refreshProcessOutput(from url: URL, itemID: WorkshopItemID?) {
        let lines = recentOutputLines(from: url)
        recentOutput = lines
        guard let itemID,
              status.phase == .downloading,
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

    private static func isRegularFile(_ url: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
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
