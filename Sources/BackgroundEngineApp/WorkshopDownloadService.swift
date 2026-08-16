@preconcurrency import BackgroundEngineCore
@preconcurrency import Foundation

protocol SteamCMDServicing: Sendable {
    func install() async throws
    func download(itemID: WorkshopItemID) async throws -> URL
    func cancel() async
    func status() async throws -> WorkshopDownloadStatus
    func diagnostics() async throws -> SteamCMDDiagnostics
}

final class SteamCMDXPCClient: SteamCMDServicing, @unchecked Sendable {
    static let serviceName = "com.lamppkk.backgroundengine.steamcmd-runner"

    func install() async throws {
        _ = try await request { proxy, reply in proxy.install(reply: reply) }
    }

    func download(itemID: WorkshopItemID) async throws -> URL {
        let payload = try await request { proxy, reply in
            proxy.download(itemID: itemID.rawValue, reply: reply)
        }
        let path = try SteamCMDXPCPayload.decode(String.self, from: payload)
        return URL(filePath: path)
    }

    func cancel() async {
        _ = try? await request { proxy, reply in proxy.cancel(reply: reply) }
    }

    func status() async throws -> WorkshopDownloadStatus {
        let payload = try await request { proxy, reply in proxy.status(reply: reply) }
        return try SteamCMDXPCPayload.decode(WorkshopDownloadStatus.self, from: payload)
    }

    func diagnostics() async throws -> SteamCMDDiagnostics {
        let payload = try await request { proxy, reply in proxy.diagnostics(reply: reply) }
        return try SteamCMDXPCPayload.decode(SteamCMDDiagnostics.self, from: payload)
    }

    private func request(
        _ operation: @escaping @Sendable (
            SteamCMDRunnerXPCProtocol,
            @escaping @Sendable (NSDictionary) -> Void
        ) -> Void
    ) async throws -> NSDictionary {
        let box: XPCPayloadBox = try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(serviceName: Self.serviceName)
            connection.remoteObjectInterface = NSXPCInterface(with: SteamCMDRunnerXPCProtocol.self)
            connection.resume()

            let state = XPCRequestState(connection: connection)
            let finish: @Sendable (XPCPayloadBox?, String?) -> Void = { box, errorMessage in
                guard state.claimCompletion() else { return }
                state.connection.invalidate()
                if let box {
                    continuation.resume(returning: box)
                } else {
                    continuation.resume(
                        throwing: SteamCMDXPCClientError.remoteFailure(errorMessage ?? "Unknown XPC error")
                    )
                }
            }
            connection.interruptionHandler = { finish(nil, SteamCMDXPCClientError.unavailable.localizedDescription) }
            connection.invalidationHandler = nil
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                finish(nil, error.localizedDescription)
            }) as? SteamCMDRunnerXPCProtocol else {
                finish(nil, SteamCMDXPCClientError.unavailable.localizedDescription)
                return
            }
            operation(proxy) { payload in finish(XPCPayloadBox(payload), nil) }
        }
        return box.payload
    }
}

private final class XPCPayloadBox: @unchecked Sendable {
    let payload: NSDictionary

    init(_ payload: NSDictionary) {
        self.payload = payload
    }
}

private final class XPCRequestState: @unchecked Sendable {
    let connection: NSXPCConnection
    private let lock = NSLock()
    private var didFinish = false

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func claimCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return false }
        didFinish = true
        return true
    }
}

actor WorkshopDownloadService {
    private let steamCMD: any SteamCMDServicing
    private let importer: WallpaperImporter

    init(store: LibraryStore, steamCMD: any SteamCMDServicing = SteamCMDXPCClient()) {
        self.steamCMD = steamCMD
        importer = WallpaperImporter(store: store)
    }

    func downloadAndImport(input: String) async throws -> WallpaperAsset {
        guard let itemID = WorkshopItemID(input: input) else {
            throw SteamCMDRunnerError.invalidItemID
        }
        try await steamCMD.install()
        let workshopFolder = try await steamCMD.download(itemID: itemID)
        let result = try await importer.scan(root: workshopFolder)
        guard let scanned = result.assets.first else {
            throw WorkshopDownloadServiceError.downloadedProjectMissing(itemID.rawValue)
        }
        return try await importer.importAsset(scanned.replacing(source: .steamCMD))
    }

    func cancel() async { await steamCMD.cancel() }
    func status() async throws -> WorkshopDownloadStatus { try await steamCMD.status() }
    func diagnostics() async throws -> SteamCMDDiagnostics { try await steamCMD.diagnostics() }
}

enum WorkshopDownloadServiceError: LocalizedError {
    case downloadedProjectMissing(String)

    var errorDescription: String? {
        switch self {
        case .downloadedProjectMissing(let id):
            "Workshop item \(id) was downloaded, but no valid Wallpaper Engine project was found."
        }
    }
}
