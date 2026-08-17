import AppKit
import BackgroundEngineCore

/// Plays an externally rendered Scene loop while keeping live clock layers on
/// the Mac. The external renderer is invoked with `--record-exclude-live`, so
/// drawing these layers here does not duplicate text already present in the
/// cached video.
@MainActor
final class CachedSceneWallpaperView: NSView,
    PausableWallpaperContent,
    DisplayModeUpdatableContent,
    WallpaperContentLifecycle,
    AudioControllableWallpaperContent {
    private struct ClockOverlay {
        let layer: CATextLayer
        let clock: SceneClockText
    }

    private let videoView: VideoWallpaperView
    private let overlaySceneLayer = CALayer()
    private let canvasSize: CGSize
    private var clockOverlays: [ClockOverlay] = []
    private var refreshTimer: Timer?
    private var isSuspended = false
    private var isClosed = false

    init(
        sceneURL: URL,
        videoURL: URL,
        fallbackImageURL: URL?,
        frame: CGRect,
        audioEnabled: Bool,
        audioVolume: Double
    ) throws {
        let plan = try SceneRenderPlanBuilder().buildLayout(url: sceneURL)
        canvasSize = CGSize(width: plan.canvasSize.width, height: plan.canvasSize.height)
        videoView = VideoWallpaperView(
            url: videoURL,
            fallbackImageURL: fallbackImageURL,
            frame: CGRect(origin: .zero, size: frame.size),
            displayMode: .fill,
            audioEnabled: audioEnabled,
            audioVolume: audioVolume
        )
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(videoView)
        overlaySceneLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        overlaySceneLayer.bounds = CGRect(origin: .zero, size: canvasSize)
        layer?.addSublayer(overlaySceneLayer)
        buildClockOverlays(from: plan)
        layoutContent()
        startRefreshTimerIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    func setPlaybackSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        videoView.setPlaybackSuspended(suspended)
        if suspended {
            refreshTimer?.invalidate()
            refreshTimer = nil
        } else {
            refreshClockOverlays()
            startRefreshTimerIfNeeded()
        }
    }

    func setDisplayMode(_: WallpaperDisplayMode) {
        // Rendered Scene loops intentionally stay aspect-fill so their native
        // overlay coordinate system matches the recording on every display.
        videoView.setDisplayMode(.fill)
        layoutContent()
    }

    func setAudioEnabled(_ enabled: Bool, volume: Double) {
        videoView.setAudioEnabled(enabled, volume: volume)
    }

    func prepareForClose() {
        guard !isClosed else { return }
        isClosed = true
        refreshTimer?.invalidate()
        refreshTimer = nil
        videoView.prepareForClose()
        clockOverlays.forEach { $0.layer.removeFromSuperlayer() }
        clockOverlays = []
    }

    private func buildClockOverlays(from plan: SceneRenderPlan) {
        for layerPlan in Self.clockLayerPlans(in: plan) {
            guard let text = layerPlan.text,
                  case .clock(let clock) = text.dynamicText else {
                continue
            }
            let textLayer = CATextLayer()
            textLayer.string = clock.string(for: Date())
            textLayer.fontSize = text.pointSize
            textLayer.foregroundColor = Self.color(from: text.color)
            textLayer.alignmentMode = Self.alignment(for: text.horizontalAlignment)
            textLayer.isWrapped = true
            textLayer.truncationMode = .none
            textLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            textLayer.name = layerPlan.name
            textLayer.opacity = Float(max(0, min(layerPlan.alpha, 1)))
            textLayer.bounds = CGRect(
                x: 0,
                y: 0,
                width: max(1, abs(layerPlan.size.width)),
                height: max(1, abs(layerPlan.size.height))
            )
            textLayer.position = CGPoint(x: layerPlan.origin.x, y: layerPlan.origin.y)
            textLayer.zPosition = layerPlan.origin.z
            let scaled = CATransform3DMakeScale(layerPlan.scale.x, layerPlan.scale.y, 1)
            textLayer.transform = CATransform3DRotate(
                scaled,
                layerPlan.angles.z * .pi / 180,
                0,
                0,
                1
            )
            overlaySceneLayer.addSublayer(textLayer)
            clockOverlays.append(ClockOverlay(layer: textLayer, clock: clock))
        }
    }

    nonisolated static func clockLayerPlans(in plan: SceneRenderPlan) -> [SceneLayer] {
        plan.layers.filter { layer in
            guard let text = layer.text else { return false }
            if case .clock = text.dynamicText { return true }
            return false
        }
    }

    nonisolated static func hasClockOverlay(sceneURL: URL) -> Bool {
        guard let plan = try? SceneRenderPlanBuilder().buildLayout(url: sceneURL) else {
            return false
        }
        return !clockLayerPlans(in: plan).isEmpty
    }

    private func layoutContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoView.frame = bounds
        layer?.frame = bounds
        let sceneFrame = WallpaperContentLayout.scaledContentFrame(
            for: canvasSize,
            in: bounds,
            displayMode: .fill
        )
        overlaySceneLayer.position = CGPoint(x: sceneFrame.midX, y: sceneFrame.midY)
        overlaySceneLayer.bounds = CGRect(origin: .zero, size: canvasSize)
        overlaySceneLayer.setAffineTransform(CGAffineTransform(
            scaleX: sceneFrame.width / max(canvasSize.width, 1),
            y: sceneFrame.height / max(canvasSize.height, 1)
        ))
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        clockOverlays.forEach { $0.layer.contentsScale = scale }
        CATransaction.commit()
    }

    private func startRefreshTimerIfNeeded() {
        guard !isClosed, !isSuspended, !clockOverlays.isEmpty, refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshClockOverlays() }
        }
    }

    private func refreshClockOverlays(date: Date = Date()) {
        guard !isClosed else { return }
        clockOverlays.forEach { $0.layer.string = $0.clock.string(for: date) }
    }

    private static func color(from color: SceneColor) -> CGColor {
        CGColor(
            red: max(0, min(color.red, 1)),
            green: max(0, min(color.green, 1)),
            blue: max(0, min(color.blue, 1)),
            alpha: max(0, min(color.alpha, 1))
        )
    }

    private static func alignment(
        for alignment: SceneTextHorizontalAlignment
    ) -> CATextLayerAlignmentMode {
        switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }
}
