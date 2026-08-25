import AVFoundation
import BackgroundEngineCore
import Foundation

/// Independent reasons are unioned before touching the physical player. This
/// follows Aerial's proven playback-coordinator pattern: clearing a transient
/// stall must never override a user/visibility pause or a close in progress.
struct AerialVideoPauseReasons: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let wallpaperSuspended = Self(rawValue: 1 << 0)
    static let recoveringFromStall = Self(rawValue: 1 << 1)
    static let closed = Self(rawValue: 1 << 2)
    static let failed = Self(rawValue: 1 << 3)
}

@MainActor
final class AerialVideoPlaybackController {
    let player = AVQueuePlayer()
    private let url: URL
    private var looper: AVPlayerLooper?
    private var currentItemObservation: NSKeyValueObservation?
    private var currentItemStatusObservation: NSKeyValueObservation?
    private var stalledObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var recoveryTask: Task<Void, Never>?
    private(set) var pauseReasons: AerialVideoPauseReasons = []
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(url: URL, audioEnabled: Bool, audioVolume: Double) {
        self.url = url
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        setAudioEnabled(audioEnabled, volume: audioVolume)
    }

    func start() {
        guard !pauseReasons.contains(.closed), looper == nil else { return }
        let item = AVPlayerItem(asset: LocalMediaAVAssetPolicy.asset(at: url))
        item.preferredForwardBufferDuration = 2
        looper = AVPlayerLooper(player: player, templateItem: item)
        installObservers()
        convergePlaybackState()
    }

    func setWallpaperSuspended(_ suspended: Bool) {
        setReason(.wallpaperSuspended, active: suspended)
    }

    func setAudioEnabled(_ enabled: Bool, volume: Double) {
        player.isMuted = !enabled
        player.volume = Float(min(1, max(0, volume)))
    }

    func close() {
        guard !pauseReasons.contains(.closed) else { return }
        setReason(.closed, active: true)
        recoveryTask?.cancel()
        recoveryTask = nil
        removeObservers()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }

    private func setReason(_ reason: AerialVideoPauseReasons, active: Bool) {
        if active {
            pauseReasons.insert(reason)
        } else {
            pauseReasons.remove(reason)
        }
        convergePlaybackState()
    }

    private func convergePlaybackState() {
        if pauseReasons.isEmpty {
            player.play()
        } else {
            player.pause()
        }
    }

    private func installObservers() {
        removeObservers()
        currentItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, change in
            guard let item = change.newValue ?? nil else { return }
            Task { @MainActor [weak self] in self?.observeStatus(of: item) }
        }
        stalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let itemID = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                guard let self,
                      let currentItem = self.player.currentItem,
                      itemID == ObjectIdentifier(currentItem) else { return }
                self.recoverFromStall()
            }
        }
        failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let itemID = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription
            Task { @MainActor [weak self] in
                guard let self,
                      let currentItem = self.player.currentItem,
                      itemID == ObjectIdentifier(currentItem) else { return }
                self.reportFailure(message ?? "The video stopped before reaching its end.")
            }
        }
    }

    private func observeStatus(of item: AVPlayerItem) {
        currentItemStatusObservation?.invalidate()
        currentItemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem else { return }
                switch item.status {
                case .readyToPlay:
                    self.setReason(.failed, active: false)
                    self.onReady?()
                case .failed:
                    self.reportFailure(item.error?.localizedDescription ?? "The video could not be decoded.")
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func recoverFromStall() {
        guard !pauseReasons.contains(.closed) else { return }
        setReason(.recoveringFromStall, active: true)
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.pauseReasons.contains(.closed) else { return }
            let time = self.player.currentTime()
            await self.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            self.setReason(.recoveringFromStall, active: false)
        }
    }

    private func reportFailure(_ message: String) {
        setReason(.failed, active: true)
        onFailure?(message)
    }

    private func removeObservers() {
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        currentItemStatusObservation?.invalidate()
        currentItemStatusObservation = nil
        if let stalledObserver { NotificationCenter.default.removeObserver(stalledObserver) }
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        stalledObserver = nil
        failedObserver = nil
    }
}
