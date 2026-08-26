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
    static let defaultStartupTimeout: Duration = .seconds(15)
    static let defaultStallRecoveryDelay: Duration = .milliseconds(750)
    static let defaultStallProgressTimeout: Duration = .seconds(5)

    let player = AVQueuePlayer()
    private let url: URL
    private let startupTimeout: Duration
    private let startupSleep: @Sendable (Duration) async throws -> Void
    private let stallRecoveryDelay: Duration
    private let stallProgressTimeout: Duration
    private let stallSleep: @Sendable (Duration) async throws -> Void
    private let playbackTimeProvider: (@MainActor @Sendable () -> CMTime)?
    private let seekHandler: (@MainActor @Sendable (CMTime) async -> Void)?
    private var looper: AVPlayerLooper?
    private var currentItemObservation: NSKeyValueObservation?
    private var currentItemStatusObservation: NSKeyValueObservation?
    private var readyForDisplayObservation: NSKeyValueObservation?
    private var playbackTimeObserver: Any?
    private var stalledObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var recoveryTask: Task<Void, Never>?
    private var startupWatchdogTask: Task<Void, Never>?
    private var stallRecoveryGeneration = 0
    private var resumeStallRecoveryAfterSuspension = false
    private var stallProgressReferenceTime: CMTime?
    private var stallProgressEvidenceCounter: UInt64 = 0
    private var hasPresentedFirstFrame = false
    private(set) var pauseReasons: AerialVideoPauseReasons = []
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(
        url: URL,
        audioEnabled: Bool,
        audioVolume: Double,
        startupTimeout: Duration = AerialVideoPlaybackController.defaultStartupTimeout,
        startupSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        stallRecoveryDelay: Duration = AerialVideoPlaybackController.defaultStallRecoveryDelay,
        stallProgressTimeout: Duration = AerialVideoPlaybackController.defaultStallProgressTimeout,
        stallSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        playbackTimeProvider: (@MainActor @Sendable () -> CMTime)? = nil,
        seekHandler: (@MainActor @Sendable (CMTime) async -> Void)? = nil
    ) {
        self.url = url
        self.startupTimeout = startupTimeout
        self.startupSleep = startupSleep
        self.stallRecoveryDelay = stallRecoveryDelay
        self.stallProgressTimeout = stallProgressTimeout
        self.stallSleep = stallSleep
        self.playbackTimeProvider = playbackTimeProvider
        self.seekHandler = seekHandler
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        setAudioEnabled(audioEnabled, volume: audioVolume)
    }

    func start(displayLayer: AVPlayerLayer) {
        guard !pauseReasons.contains(.closed), looper == nil else { return }
        observeReadyForDisplay(on: displayLayer)
        installPlaybackProgressObserver()
        let item = AVPlayerItem(asset: LocalMediaAVAssetPolicy.asset(at: url))
        item.preferredForwardBufferDuration = 2
        looper = AVPlayerLooper(player: player, templateItem: item)
        installObservers()
        beginStartupWatchdog()
        convergePlaybackState()
    }

    func setWallpaperSuspended(_ suspended: Bool) {
        let stateChanged = pauseReasons.contains(.wallpaperSuspended) != suspended
        let hadStallRecovery = recoveryTask != nil
        setReason(.wallpaperSuspended, active: suspended)
        if suspended, hadStallRecovery {
            resumeStallRecoveryAfterSuspension = true
            recoveryTask?.cancel()
            recoveryTask = nil
            stallRecoveryGeneration += 1
            stallProgressReferenceTime = nil
            setReason(.recoveringFromStall, active: false)
        }
        guard stateChanged else { return }
        if !hasPresentedFirstFrame {
            if suspended {
                cancelStartupWatchdog()
            } else {
                beginStartupWatchdog()
            }
        }
        if !suspended, resumeStallRecoveryAfterSuspension {
            resumeStallRecoveryAfterSuspension = false
            recoverFromStall()
        }
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
        stallRecoveryGeneration += 1
        resumeStallRecoveryAfterSuspension = false
        stallProgressReferenceTime = nil
        cancelStartupWatchdog()
        readyForDisplayObservation?.invalidate()
        readyForDisplayObservation = nil
        removePlaybackProgressObserver()
        removeObservers()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }

    /// Starts the bounded handoff deadline. Internal visibility keeps the
    /// timeout deterministic in tests without constructing or waiting on an
    /// AVFoundation decoder.
    func beginStartupWatchdog() {
        guard !pauseReasons.contains(.closed),
              !pauseReasons.contains(.failed),
              !hasPresentedFirstFrame else { return }
        cancelStartupWatchdog()
        let timeout = startupTimeout
        let sleep = startupSleep
        startupWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await sleep(timeout)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.startupWatchdogTask = nil
            self.reportFailure("No decoded video frame became ready before the startup deadline.")
        }
    }

    /// Completes the handoff only after AVPlayerLayer has an actual decoded
    /// frame. AVPlayerItem.readyToPlay alone can precede visible output.
    func markFirstFrameReady() {
        guard !pauseReasons.contains(.closed),
              !pauseReasons.contains(.failed),
              !hasPresentedFirstFrame else { return }
        hasPresentedFirstFrame = true
        cancelStartupWatchdog()
        onReady?()
    }

    var hasPendingStartupWatchdog: Bool {
        startupWatchdogTask != nil
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
                    break
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

    private func observeReadyForDisplay(on displayLayer: AVPlayerLayer) {
        readyForDisplayObservation?.invalidate()
        readyForDisplayObservation = displayLayer.observe(
            \.isReadyForDisplay,
            options: [.initial, .new]
        ) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor [weak self] in
                self?.markFirstFrameReady()
            }
        }
    }

    func recoverFromStall() {
        guard !pauseReasons.contains(.closed),
              !pauseReasons.contains(.failed) else { return }
        if pauseReasons.contains(.wallpaperSuspended) {
            resumeStallRecoveryAfterSuspension = true
            return
        }
        stallRecoveryGeneration += 1
        let generation = stallRecoveryGeneration
        stallProgressReferenceTime = nil
        let recoveryDelay = stallRecoveryDelay
        let progressTimeout = stallProgressTimeout
        let sleep = stallSleep
        let startingTime = currentPlaybackTime()
        setReason(.recoveringFromStall, active: true)
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            defer {
                if let self, self.stallRecoveryGeneration == generation {
                    self.recoveryTask = nil
                    self.stallProgressReferenceTime = nil
                }
            }
            do {
                try await sleep(recoveryDelay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.pauseReasons.contains(.closed) else { return }
            await self.seek(to: startingTime)
            self.stallProgressReferenceTime = startingTime
            let progressBaseline = self.stallProgressEvidenceCounter
            self.setReason(.recoveringFromStall, active: false)
            do {
                try await sleep(progressTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  !self.pauseReasons.contains(.closed),
                  !self.pauseReasons.contains(.failed) else { return }
            if self.pauseReasons.contains(.wallpaperSuspended) {
                self.resumeStallRecoveryAfterSuspension = true
                return
            }
            let endingTime = self.currentPlaybackTime()
            guard self.stallProgressEvidenceCounter == progressBaseline,
                  !Self.didPlaybackAdvance(from: startingTime, to: endingTime) else { return }
            self.reportFailure("Video playback remained stalled after a bounded recovery attempt.")
        }
    }

    private func installPlaybackProgressObserver() {
        removePlaybackProgressObserver()
        playbackTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self,
                      let reference = self.stallProgressReferenceTime,
                      Self.didPlaybackAdvance(from: reference, to: time) else {
                    return
                }
                self.stallProgressEvidenceCounter &+= 1
            }
        }
    }

    private func removePlaybackProgressObserver() {
        guard let playbackTimeObserver else { return }
        player.removeTimeObserver(playbackTimeObserver)
        self.playbackTimeObserver = nil
    }

    nonisolated static func didPlaybackAdvance(from start: CMTime, to end: CMTime) -> Bool {
        let startSeconds = start.seconds
        let endSeconds = end.seconds
        guard startSeconds.isFinite, endSeconds.isFinite else { return false }
        // A loop restart is progress too. Treat only a nearly identical clock
        // as a terminal stall; dark or visually static content is not judged.
        return abs(endSeconds - startSeconds) >= 0.1
    }

    private func currentPlaybackTime() -> CMTime {
        playbackTimeProvider?() ?? player.currentTime()
    }

    private func seek(to time: CMTime) async {
        if let seekHandler {
            await seekHandler(time)
        } else {
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func reportFailure(_ message: String) {
        guard !pauseReasons.contains(.closed), !pauseReasons.contains(.failed) else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        stallRecoveryGeneration += 1
        resumeStallRecoveryAfterSuspension = false
        stallProgressReferenceTime = nil
        cancelStartupWatchdog()
        setReason(.failed, active: true)
        onFailure?(message)
    }

    private func cancelStartupWatchdog() {
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
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
