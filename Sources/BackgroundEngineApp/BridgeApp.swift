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

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock = AppInstanceLock()

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard instanceLock.acquire() else {
            NSApp.terminate(nil)
            return
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
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
