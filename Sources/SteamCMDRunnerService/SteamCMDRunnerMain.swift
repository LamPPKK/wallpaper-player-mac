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

    func current(where predicate: (Operation) -> Bool) -> Operation? {
        lock.withLock {
            guard let activeOperation, predicate(activeOperation) else { return nil }
            return activeOperation
        }
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

final class SteamCMDRunnerService: NSObject, @unchecked Sendable {
    private let runner: SteamCMDRunner
    private let operationSlot = SteamCMDOperationSlot<SteamCMDServiceOperation>()

    override init() {
        let paths = (try? SteamCMDRuntimePaths.applicationSupport())
            ?? SteamCMDRuntimePaths(root: FileManager.default.temporaryDirectory.appending(path: "Background Engine/SteamCMD"))
        runner = SteamCMDRunner(paths: paths)
        super.init()
    }

    func install(ownerID: UUID, reply: @escaping @Sendable (NSDictionary) -> Void) {
        let operation = SteamCMDServiceOperation(ownerID: ownerID)
        guard register(operation) else {
            reply(SteamCMDXPCPayload.failure(SteamCMDRunnerError.operationInProgress))
            return
        }
        let task = Task { [runner] in
            defer {
                self.operationSlot.clear(operation)
                operation.finish()
            }
            let payload: NSDictionary
            do {
                try await runner.installIfNeeded()
                payload = SteamCMDXPCPayload.success()
            } catch {
                payload = SteamCMDXPCPayload.failure(error)
            }
            self.operationSlot.finish(operation) {
                operation.finish()
                reply(payload)
            }
        }
        operation.install(task)
    }

    func download(
        ownerID: UUID,
        itemID: String,
        reply: @escaping @Sendable (NSDictionary) -> Void
    ) {
        guard let itemID = WorkshopItemID(rawValue: itemID) else {
            reply(SteamCMDXPCPayload.failure(SteamCMDRunnerError.invalidItemID))
            return
        }
        let operation = SteamCMDServiceOperation(ownerID: ownerID)
        guard register(operation) else {
            reply(SteamCMDXPCPayload.failure(SteamCMDRunnerError.operationInProgress))
            return
        }
        let task = Task { [runner] in
            defer {
                self.operationSlot.clear(operation)
                operation.finish()
            }
            let payload: NSDictionary
            do {
                let url = try await runner.download(itemID: itemID)
                payload = SteamCMDXPCPayload.success(url.path)
            } catch {
                payload = SteamCMDXPCPayload.failure(error)
            }
            self.operationSlot.finish(operation) {
                operation.finish()
                reply(payload)
            }
        }
        operation.install(task)
    }

    func cancel(reply: @escaping @Sendable (NSDictionary) -> Void) {
        guard let operation = operationSlot.current() else {
            reply(SteamCMDXPCPayload.success())
            return
        }
        // Capture one identity-stable operation before crossing an async
        // boundary. A completed operation may release the slot and a new
        // client may start before this task runs; cancellation must never
        // consult the shared runner again and accidentally terminate that
        // replacement. Cancelling the selected task propagates into the
        // supervised child-process cancellation handler. Wait for the same
        // operation to finish so the reply still means its process tree was
        // reaped and its slot released.
        Task {
            await operation.cancelAndWait()
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

    /// An XPC interruption belongs to exactly one request connection. Cancel
    /// only the operation registered by that connection; status/diagnostic
    /// clients use short-lived connections and must never cancel a download
    /// owned by a different client. The returned operation is an identity-
    /// stable strong reference: if it completes and another client fills the
    /// slot before `cancel()` runs, only the old operation is cancelled.
    /// Deliberately do not call the shared runner's global `cancel()` here:
    /// scheduling that actor call after slot turnover could terminate the
    /// replacement client's process. Task cancellation propagates through the
    /// selected operation's supervised child-process lifecycle instead.
    func connectionDidClose(ownerID: UUID) {
        operationSlot.current(where: { $0.ownerID == ownerID })?.cancel()
    }

    func register(_ operation: SteamCMDServiceOperation) -> Bool {
        operationSlot.register(operation)
    }
}

final class SteamCMDServiceOperation: @unchecked Sendable {
    let ownerID: UUID
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancellationRequested = false
    private var isFinished = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(ownerID: UUID) {
        self.ownerID = ownerID
    }

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

    func cancelAndWait() async {
        cancel()
        await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.resume()
            } else {
                finishWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        task = nil
        let waiters = finishWaiters
        finishWaiters.removeAll(keepingCapacity: false)
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}

/// Per-connection exported facade. The shared service retains the global
/// operation slot and SteamCMD runner, while this object contributes the
/// connection identity required to bind unexpected client loss to only its
/// own install/download task.
final class SteamCMDRunnerConnectionService: NSObject, SteamCMDRunnerXPCProtocol, @unchecked Sendable {
    let ownerID = UUID()
    private let service: SteamCMDRunnerService

    init(service: SteamCMDRunnerService) {
        self.service = service
        super.init()
    }

    func install(reply: @escaping @Sendable (NSDictionary) -> Void) {
        service.install(ownerID: ownerID, reply: reply)
    }

    func download(itemID: String, reply: @escaping @Sendable (NSDictionary) -> Void) {
        service.download(ownerID: ownerID, itemID: itemID, reply: reply)
    }

    func cancel(reply: @escaping @Sendable (NSDictionary) -> Void) {
        service.cancel(reply: reply)
    }

    func status(reply: @escaping @Sendable (NSDictionary) -> Void) {
        service.status(reply: reply)
    }

    func diagnostics(reply: @escaping @Sendable (NSDictionary) -> Void) {
        service.diagnostics(reply: reply)
    }

    func connectionDidClose() {
        service.connectionDidClose(ownerID: ownerID)
    }
}

final class SteamCMDRunnerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = SteamCMDRunnerService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let connectionService = SteamCMDRunnerConnectionService(service: service)
        connection.exportedInterface = NSXPCInterface(with: SteamCMDRunnerXPCProtocol.self)
        connection.exportedObject = connectionService
        connection.interruptionHandler = { [connectionService] in
            connectionService.connectionDidClose()
        }
        connection.invalidationHandler = { [connectionService] in
            connectionService.connectionDidClose()
        }
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
