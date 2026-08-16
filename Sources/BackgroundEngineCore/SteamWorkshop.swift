@preconcurrency import Foundation

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
              host == "steamcommunity.com" || host.hasSuffix(".steamcommunity.com"),
              let id = components.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value,
              let numeric = WorkshopItemID(rawValue: id) else {
            return nil
        }
        self = numeric
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
    private var status = WorkshopDownloadStatus(itemID: nil, phase: .idle, progress: nil, message: "Ready")
    private var recentOutput: [String] = []

    public init(paths: SteamCMDRuntimePaths) {
        self.paths = paths
    }

    public func installIfNeeded() async throws {
        if FileManager.default.isExecutableFile(atPath: paths.executable.path) { return }
        status = WorkshopDownloadStatus(
            itemID: nil,
            phase: .installingSteamCMD,
            progress: nil,
            message: "Installing the Valve SteamCMD runtime…"
        )
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
        guard FileManager.default.fileExists(atPath: paths.executable.path) else {
            throw SteamCMDRunnerError.installerMissingExecutable
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.executable.path)
        status = WorkshopDownloadStatus(itemID: nil, phase: .idle, progress: nil, message: "SteamCMD is ready")
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

    public func cancel() {
        process?.terminate()
        process = nil
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
            executablePresent: FileManager.default.isExecutableFile(atPath: paths.executable.path),
            activeItemID: status.itemID,
            phase: status.phase,
            recentOutput: recentOutput
        )
    }

    private func run(executable: URL, arguments: [String], itemID: WorkshopItemID?) async throws {
        guard process == nil else { throw SteamCMDRunnerError.operationInProgress }
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

        do {
            try child.run()
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
        } catch {
            try? logHandle.close()
            process = nil
            loadRecentOutput(from: logURL)
            try? FileManager.default.removeItem(at: logURL)
            if child.terminationReason == .uncaughtSignal || Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
        try? logHandle.close()
        process = nil
        loadRecentOutput(from: logURL)
        try? FileManager.default.removeItem(at: logURL)
    }

    private func loadRecentOutput(from url: URL) {
        let output = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        recentOutput = Array(output.split(separator: "\n").suffix(80).map(String.init))
    }
}

public enum SteamCMDRunnerError: LocalizedError, Equatable {
    case invalidItemID
    case operationInProgress
    case installerDownloadFailed
    case installerMissingExecutable
    case processFailed(Int32)
    case downloadMissing(String)
    case anonymousDownloadUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidItemID: "Enter a numeric Workshop item ID or a valid Steam Workshop URL."
        case .operationInProgress: "Another SteamCMD operation is already running."
        case .installerDownloadFailed: "SteamCMD could not be downloaded from Valve."
        case .installerMissingExecutable: "The SteamCMD archive did not contain steamcmd.sh."
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
