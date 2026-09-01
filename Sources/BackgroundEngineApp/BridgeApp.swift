import AppKit
import Darwin
import SwiftUI

@MainActor
private enum ApplicationModel {
    static let shared = AppViewModel()
}

@main
struct BackgroundEngineApplication: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var model = ApplicationModel.shared

    var body: some Scene {
        Window("Background Engine", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 640)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            StatusMenu(model: model)
        } label: {
            MenuBarIcon(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock = AppInstanceLock()
    private var terminationDrainTask: Task<Void, Never>?
    private var hasCompletedTerminationDrain = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard instanceLock.acquire() else {
            NSApp.terminate(nil)
            return
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { [weak self] in
            self?.recoverDisconnectedDisplayWindows()
        }
    }

    func applicationDidUpdate(_ notification: Notification) {
        recoverDisconnectedDisplayWindows()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        recoverDisconnectedDisplayWindows()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationDrainTask == nil else {
            return .terminateLater
        }

        // Close every admission gate before the main actor suspends. Window
        // teardown can enqueue late Web/Scene callbacks, but they can no
        // longer create a replacement job once termination has begun.
        WebMediaRuntimeCoordinator.shared.beginShutdown()
        SceneRenderCoordinator.shared.beginShutdown()
        WallpaperPlayer.shared.beginApplicationTermination()

        terminationDrainTask = Task { @MainActor in
            await ApplicationModel.shared.cancelAndWaitForApplicationJobs()
            // Library/Workshop work can hold references to the previous
            // wallpaper assets. Drain it before taking the final runtime
            // snapshots; the admission gates above already prevent retries.
            async let webRuntimeDrain: Void = WebMediaRuntimeCoordinator.shared.shutdownAndWait()
            async let sceneRuntimeDrain: Void = SceneRenderCoordinator.shared.shutdownAndWait()
            await webRuntimeDrain
            await sceneRuntimeDrain
            // The coordinators have drained every supervised task. Sweep the
            // process registry once more before replying as a fail-closed last
            // line of defence against a child launched during teardown.
            SceneVideoRenderer.cancelAllActiveProcesses()
            hasCompletedTerminationDrain = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Idempotent fallback for nonstandard termination paths that skip the
        // normal terminate-later handshake.
        guard !hasCompletedTerminationDrain else { return }
        WebMediaRuntimeCoordinator.shared.beginShutdown()
        SceneRenderCoordinator.shared.beginShutdown()
        WallpaperPlayer.shared.beginApplicationTermination()
        ApplicationModel.shared.cancelApplicationJobs()
        SceneVideoRenderer.cancelAllActiveProcesses()
    }

    func applicationDidHide(_ notification: Notification) {
        restoreWallpaperWindows()
    }

    func applicationDidUnhide(_ notification: Notification) {
        restoreWallpaperWindows()
    }

    private func restoreWallpaperWindows() {
        Task { @MainActor in
            WallpaperPlayer.shared.restoreVisibleWindowsAfterAppWindowChange()
        }
    }

    private func recoverDisconnectedDisplayWindows() {
        NSApp.windows.forEach(recoverWindowIfNeeded)
    }

    private func recoverWindowIfNeeded(_ window: NSWindow) {
        guard window.styleMask.contains(.titled),
              !window.styleMask.contains(.fullScreen),
              !window.isMiniaturized,
              window.level == .normal,
              let fallback = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame,
              let frame = SettingsWindowPlacement.recoveredFrame(
                  windowFrame: window.frame,
                  screenFrames: NSScreen.screens.map(\.visibleFrame),
                  fallback: fallback
              ) else {
            return
        }
        window.setFrame(frame, display: true, animate: false)
    }
}

final class AppInstanceLock {
    private let lockPath: String
    private var fileDescriptor: Int32 = -1

    init(
        lockPath: String = URL(filePath: NSTemporaryDirectory())
            .appending(path: "com.lamppkk.backgroundengine.app.lock")
            .path
    ) {
        self.lockPath = lockPath
    }

    func acquire() -> Bool {
        guard fileDescriptor < 0 else {
            return true
        }
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return false
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        fileDescriptor = descriptor
        return true
    }

    deinit {
        guard fileDescriptor >= 0 else {
            return
        }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        Image(systemName: "photo.on.rectangle.angled")
            .accessibilityLabel("Background Engine")
    }
}
