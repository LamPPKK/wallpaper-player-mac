@preconcurrency import BackgroundEngineCore
@preconcurrency import Foundation

final class SteamCMDRunnerService: NSObject, SteamCMDRunnerXPCProtocol, @unchecked Sendable {
    private let runner: SteamCMDRunner

    override init() {
        let paths = (try? SteamCMDRuntimePaths.applicationSupport())
            ?? SteamCMDRuntimePaths(root: FileManager.default.temporaryDirectory.appending(path: "Background Engine/SteamCMD"))
        runner = SteamCMDRunner(paths: paths)
        super.init()
    }

    func install(reply: @escaping @Sendable (NSDictionary) -> Void) {
        Task {
            do {
                try await runner.installIfNeeded()
                reply(SteamCMDXPCPayload.success())
            } catch {
                reply(SteamCMDXPCPayload.failure(error))
            }
        }
    }

    func download(itemID: String, reply: @escaping @Sendable (NSDictionary) -> Void) {
        Task {
            guard let itemID = WorkshopItemID(rawValue: itemID) else {
                reply(SteamCMDXPCPayload.failure(SteamCMDRunnerError.invalidItemID))
                return
            }
            do {
                let url = try await runner.download(itemID: itemID)
                reply(SteamCMDXPCPayload.success(url.path))
            } catch {
                reply(SteamCMDXPCPayload.failure(error))
            }
        }
    }

    func cancel(reply: @escaping @Sendable (NSDictionary) -> Void) {
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
