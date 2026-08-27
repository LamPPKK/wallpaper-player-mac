@preconcurrency import BackgroundEngineCore
@preconcurrency import Foundation

/// Serializes the operation selected by this XPC service. Completion clears
/// by object identity before invoking the reply: a reply may synchronously
/// start the next request, and deferred cleanup from the previous request must
/// never clear that replacement.
final class SteamCMDOperationSlot<Operation: AnyObject & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var activeOperation: Operation?

    func register(_ operation: Operation) -> Bool {
        lock.withLock {
            guard activeOperation == nil else { return false }
            activeOperation = operation
            return true
        }
    }

    func current() -> Operation? {
        lock.withLock { activeOperation }
    }

    @discardableResult
    func clear(_ operation: Operation) -> Bool {
        lock.withLock {
            guard activeOperation === operation else { return false }
            activeOperation = nil
            return true
        }
    }

    func finish(_ operation: Operation, reply: () -> Void) {
        clear(operation)
        reply()
    }
}

final class SteamCMDRunnerService: NSObject, SteamCMDRunnerXPCProtocol, @unchecked Sendable {
    private let runner: SteamCMDRunner
    private let operationSlot = SteamCMDOperationSlot<SteamCMDServiceOperation>()

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
            defer { self.operationSlot.clear(operation) }
            let payload: NSDictionary
            do {
                try await runner.installIfNeeded()
                payload = SteamCMDXPCPayload.success()
            } catch {
                payload = SteamCMDXPCPayload.failure(error)
            }
            self.operationSlot.finish(operation) {
                reply(payload)
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
            defer { self.operationSlot.clear(operation) }
            let payload: NSDictionary
            do {
                let url = try await runner.download(itemID: itemID)
                payload = SteamCMDXPCPayload.success(url.path)
            } catch {
                payload = SteamCMDXPCPayload.failure(error)
            }
            self.operationSlot.finish(operation) {
                reply(payload)
            }
        }
        operation.install(task)
    }

    func cancel(reply: @escaping @Sendable (NSDictionary) -> Void) {
        operationSlot.current()?.cancel()
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
        operationSlot.register(operation)
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
