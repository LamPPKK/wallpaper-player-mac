@preconcurrency import BackgroundEngineCore
@preconcurrency import Foundation

final class SteamCMDRunnerService: NSObject, SteamCMDRunnerXPCProtocol, @unchecked Sendable {
    private let runner: SteamCMDRunner
    private let operationLock = NSLock()
    private var activeOperation: SteamCMDServiceOperation?

    override init() {
        let paths = (try? SteamCMDRuntimePaths.applicationSupport())
            ?? SteamCMDRuntimePaths(root: FileManager.default.temporaryDirectory.appending(path: "Background Engine/SteamCMD"))
        runner = SteamCMDRunner(paths: paths)
        super.init()
    }

    func install(reply: @escaping @Sendable (NSDictionary) -> Void) {
        let operation = SteamCMDServiceOperation()
        guard register(operation) else {
            reply(SteamCMDXPCPayload.failure(SteamCMDRunnerError.operationInProgress))
            return
        }
        let task = Task { [runner] in
            defer { self.clear(operation) }
            do {
                try await runner.installIfNeeded()
                reply(SteamCMDXPCPayload.success())
            } catch {
                reply(SteamCMDXPCPayload.failure(error))
            }
        }
        operation.install(task)
    }

    func download(itemID: String, reply: @escaping @Sendable (NSDictionary) -> Void) {
        guard let itemID = WorkshopItemID(rawValue: itemID) else {
            reply(SteamCMDXPCPayload.failure(SteamCMDRunnerError.invalidItemID))
            return
        }
        let operation = SteamCMDServiceOperation()
        guard register(operation) else {
            reply(SteamCMDXPCPayload.failure(SteamCMDRunnerError.operationInProgress))
            return
        }
        let task = Task { [runner] in
            defer { self.clear(operation) }
            do {
                let url = try await runner.download(itemID: itemID)
                reply(SteamCMDXPCPayload.success(url.path))
            } catch {
                reply(SteamCMDXPCPayload.failure(error))
            }
        }
        operation.install(task)
    }

    func cancel(reply: @escaping @Sendable (NSDictionary) -> Void) {
        currentOperation()?.cancel()
        Task {
            await runner.cancel()
            reply(SteamCMDXPCPayload.success())
        }
    }

    func status(reply: @escaping @Sendable (NSDictionary) -> Void) {
        Task {
            reply(SteamCMDXPCPayload.success(await runner.currentStatus()))
        }
    }

    func diagnostics(reply: @escaping @Sendable (NSDictionary) -> Void) {
        Task {
            reply(SteamCMDXPCPayload.success(await runner.diagnostics()))
        }
    }

    private func register(_ operation: SteamCMDServiceOperation) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard activeOperation == nil else { return false }
        activeOperation = operation
        return true
    }

    private func currentOperation() -> SteamCMDServiceOperation? {
        operationLock.lock()
        defer { operationLock.unlock() }
        return activeOperation
    }

    private func clear(_ operation: SteamCMDServiceOperation) {
        operationLock.lock()
        defer { operationLock.unlock() }
        if activeOperation === operation {
            activeOperation = nil
        }
    }
}

private final class SteamCMDServiceOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancellationRequested = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

final class SteamCMDRunnerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = SteamCMDRunnerService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SteamCMDRunnerXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

@main
enum SteamCMDRunnerServiceMain {
    static func main() {
        let delegate = SteamCMDRunnerDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
