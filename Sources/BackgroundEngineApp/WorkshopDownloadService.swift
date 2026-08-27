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
        _ = try await request(cancellable: true) { proxy, reply in proxy.install(reply: reply) }
        try Task.checkCancellation()
    }

    func download(itemID: WorkshopItemID) async throws -> URL {
        let payload = try await request(cancellable: true) { proxy, reply in
            proxy.download(itemID: itemID.rawValue, reply: reply)
        }
        try Task.checkCancellation()
        let path = try SteamCMDXPCPayload.decode(String.self, from: payload)
        return URL(filePath: path)
    }

    func cancel() async {
        // Cancellation is itself cleanup and must still reach the XPC runner
        // when invoked from a task whose cancellation bit is already set.
        await Task.detached { [self] in
            _ = try? await request { proxy, reply in proxy.cancel(reply: reply) }
        }.value
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
        cancellable: Bool = false,
        _ operation: @escaping @Sendable (
            SteamCMDRunnerXPCProtocol,
            @escaping @Sendable (NSDictionary) -> Void
        ) -> Void
    ) async throws -> NSDictionary {
        let cancellation = XPCRequestCancellationState()
        let box: XPCPayloadBox = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let connection = NSXPCConnection(serviceName: Self.serviceName)
                connection.remoteObjectInterface = NSXPCInterface(with: SteamCMDRunnerXPCProtocol.self)
                connection.resume()

                let state = XPCRequestState(connection: connection)
                let finish: @Sendable (XPCPayloadBox?, (any Error)?) -> Void = { box, error in
                    guard state.claimCompletion() else { return }
                    cancellation.finish()
                    state.connection.invalidate()
                    if let box {
                        continuation.resume(returning: box)
                    } else {
                        continuation.resume(throwing: error ?? SteamCMDXPCClientError.remoteFailure("Unknown XPC error"))
                    }
                }
                connection.interruptionHandler = { finish(nil, SteamCMDXPCClientError.unavailable) }
                connection.invalidationHandler = nil
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    finish(nil, SteamCMDXPCClientError.remoteFailure(error.localizedDescription))
                }) as? SteamCMDRunnerXPCProtocol else {
                    finish(nil, SteamCMDXPCClientError.unavailable)
                    return
                }
                let proxyBox = XPCProxyBox(proxy)
                let dispatch = { operation(proxy) { payload in finish(XPCPayloadBox(payload), nil) } }
                guard cancellable else {
                    dispatch()
                    return
                }
                let dispatched = cancellation.dispatch(
                    operation: dispatch,
                    cancel: { proxyBox.proxy.cancel { _ in } }
                )
                if !dispatched {
                    finish(nil, CancellationError())
                }
            }
        }, onCancel: {
            cancellation.cancel()
        })
        return box.payload
    }
}

/// Serializes a cancellable XPC operation's first dispatch with its remote
/// cancel message. The operation is always sent before cancel on the same
/// connection, or is not sent at all when cancellation won the race.
private final class XPCRequestCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var isFinished = false
    private var cancelRemote: (@Sendable () -> Void)?

    func dispatch(
        operation: () -> Void,
        cancel: @escaping @Sendable () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, !isFinished else { return false }
        cancelRemote = cancel
        operation()
        return true
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let action = isFinished ? nil : cancelRemote
        lock.unlock()
        action?()
    }

    func finish() {
        lock.lock()
        isFinished = true
        cancelRemote = nil
        lock.unlock()
    }
}

private final class XPCProxyBox: @unchecked Sendable {
    let proxy: SteamCMDRunnerXPCProtocol

    init(_ proxy: SteamCMDRunnerXPCProtocol) {
        self.proxy = proxy
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
    private var publishedStatus: WorkshopDownloadStatus?
    private var activeOperationID: UUID?

    init(store: LibraryStore, steamCMD: any SteamCMDServicing = SteamCMDXPCClient()) {
        self.steamCMD = steamCMD
        importer = WallpaperImporter(store: store)
    }

    init(importer: WallpaperImporter, steamCMD: any SteamCMDServicing) {
        self.steamCMD = steamCMD
        self.importer = importer
    }

    func downloadAndImport(
        input: String,
        willImport: (@Sendable (WallpaperAsset) async -> Void)? = nil
    ) async throws -> WallpaperAsset {
        guard activeOperationID == nil else {
            throw WorkshopDownloadServiceError.operationInProgress
        }
        let operationID = UUID()
        activeOperationID = operationID
        defer {
            if activeOperationID == operationID {
                activeOperationID = nil
            }
        }
        guard let itemID = WorkshopItemID(input: input) else {
            let error = SteamCMDRunnerError.invalidItemID
            publishedStatus = WorkshopDownloadStatus(
                itemID: nil,
                phase: .failed,
                progress: nil,
                message: error.localizedDescription
            )
            throw error
        }
        publishedStatus = nil
        do {
            try Task.checkCancellation()
            try await steamCMD.install()
            try Task.checkCancellation()
            let workshopFolder = try await steamCMD.download(itemID: itemID)
            try Task.checkCancellation()
            publishedStatus = WorkshopDownloadStatus(
                itemID: itemID.rawValue,
                phase: .importing,
                progress: nil,
                message: "Importing Workshop item \(itemID.rawValue)…"
            )
            let result = try await importer.scan(root: workshopFolder)
            try Task.checkCancellation()
            guard let scanned = result.assets.first else {
                throw WorkshopDownloadServiceError.downloadedProjectMissing(itemID.rawValue)
            }
            let candidate = scanned.replacing(source: .steamCMD)
            if let willImport {
                await willImport(candidate)
                try Task.checkCancellation()
            }
            let imported = try await importer.importAndPrepareAsset(candidate)
            if Task.isCancelled {
                throw WorkshopDownloadServiceError.cancelledAfterImport(imported)
            }
            publishedStatus = WorkshopDownloadStatus(
                itemID: itemID.rawValue,
                phase: .completed,
                progress: 1,
                message: "Workshop item imported"
            )
            return imported
        } catch {
            let phase: WorkshopDownloadPhase
            let progress: Double?
            let message: String
            if error is CancellationError {
                phase = .cancelled
                progress = nil
                message = "Workshop download cancelled"
            } else if let serviceError = error as? WorkshopDownloadServiceError,
                      case .cancelledAfterImport = serviceError {
                phase = .cancelled
                progress = 1
                message = serviceError.localizedDescription
            } else {
                phase = .failed
                progress = nil
                message = error.localizedDescription
            }
            publishedStatus = WorkshopDownloadStatus(
                itemID: itemID.rawValue,
                phase: phase,
                progress: progress,
                message: message
            )
            throw error
        }
    }

    func cancel() async { await steamCMD.cancel() }
    func status() async throws -> WorkshopDownloadStatus {
        if let publishedStatus { return publishedStatus }
        return try await steamCMD.status()
    }
    func diagnostics() async throws -> SteamCMDDiagnostics { try await steamCMD.diagnostics() }
}

enum WorkshopDownloadServiceError: LocalizedError {
    case operationInProgress
    case downloadedProjectMissing(String)
    case cancelledAfterImport(WallpaperAsset)

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            "Another Workshop download is still running. Wait for it to finish or cancel it first."
        case .downloadedProjectMissing(let id):
            "Workshop item \(id) was downloaded, but no valid Wallpaper Engine project was found."
        case .cancelledAfterImport(let asset):
            "The download was cancelled after \(asset.title) had already been imported; the wallpaper was kept."
        }
    }
}
