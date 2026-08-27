import AppKit
import AVFoundation
import BackgroundEngineCore

@MainActor
final class VideoWallpaperView: NSView,
    PausableWallpaperContent,
    DisplayModeUpdatableContent,
    WallpaperContentLifecycle,
    AudioControllableWallpaperContent {
    private let playbackController: AerialVideoPlaybackController
    private var sceneCacheLease: SceneVideoCachePlaybackLease?
    private let fallbackLayer = CAGradientLayer()
    private var failureLabel: NSTextField?
    // Not private so tests can assert on the configured video gravity
    // (e.g. that scene-rendered wallpaper videos are forced to fill).
    let playerLayer: AVPlayerLayer

    init(
        url: URL,
        fallbackImageURL: URL?,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool = false,
        audioVolume: Double = 0.5,
        sceneCacheLease: SceneVideoCachePlaybackLease? = nil,
        onPlaybackFailure: ((String) -> Void)? = nil
    ) {
        let controller = AerialVideoPlaybackController(
            url: url,
            audioEnabled: audioEnabled,
            audioVolume: audioVolume
        )
        playbackController = controller
        self.sceneCacheLease = sceneCacheLease
        playerLayer = AVPlayerLayer(player: controller.player)
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        configureFallbackLayer(fallbackImageURL: fallbackImageURL, displayMode: displayMode)
        playerLayer.videoGravity = WallpaperContentLayout.videoGravity(for: displayMode)
        playerLayer.isHidden = true
        layer?.addSublayer(fallbackLayer)
        layer?.addSublayer(playerLayer)
        layoutLayers()
        controller.onReady = { [weak self] in
            self?.playerLayer.isHidden = false
            self?.failureLabel?.removeFromSuperview()
            self?.failureLabel = nil
        }
        controller.onFailure = { [weak self] message in
            self?.playerLayer.isHidden = true
            self?.showFailure("This video could not be played: \(message)")
            onPlaybackFailure?(message)
        }
        controller.start(displayLayer: playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    func setPlaybackSuspended(_ suspended: Bool) {
        playbackController.setWallpaperSuspended(suspended)
    }

    func setDisplayMode(_ displayMode: WallpaperDisplayMode) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fallbackLayer.contentsGravity = WallpaperContentLayout.imageContentsGravity(for: displayMode)
        playerLayer.videoGravity = WallpaperContentLayout.videoGravity(for: displayMode)
        CATransaction.commit()
    }

    func setAudioEnabled(_ enabled: Bool, volume: Double) {
        playbackController.setAudioEnabled(enabled, volume: volume)
    }

    func prepareForClose() {
        playbackController.close()
        playerLayer.player = nil
        sceneCacheLease?.release()
        sceneCacheLease = nil
    }

    private func configureFallbackLayer(fallbackImageURL: URL?, displayMode: WallpaperDisplayMode) {
        fallbackLayer.colors = [
            NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.20, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.18, green: 0.12, blue: 0.28, alpha: 1).cgColor
        ]
        fallbackLayer.startPoint = CGPoint(x: 0, y: 0)
        fallbackLayer.endPoint = CGPoint(x: 1, y: 1)
        fallbackLayer.contentsGravity = WallpaperContentLayout.imageContentsGravity(for: displayMode)
        fallbackLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        fallbackLayer.minificationFilter = .linear
        fallbackLayer.magnificationFilter = .linear
        guard let fallbackImageURL,
              let image = NSImage(contentsOf: fallbackImageURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        fallbackLayer.contents = cgImage
    }

    private func layoutLayers() {
        layer?.frame = bounds
        fallbackLayer.frame = bounds
        playerLayer.frame = bounds
    }

    private func showFailure(_ message: String) {
        failureLabel?.removeFromSuperview()
        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.7)
        ])
        failureLabel = label
    }
}
