import AppKit
import BackgroundEngineCore

enum SceneLiveTextRecordingPolicy: Equatable {
    case bakeAll
    case overlayClocks

    static func policy(for plan: SceneRenderPlan) -> Self {
        let scriptedLayers = plan.layers.filter { $0.text?.script != nil }
        guard !scriptedLayers.isEmpty,
              scriptedLayers.allSatisfy(isExactlyReproducibleClockLayer) else {
            return .bakeAll
        }
        return .overlayClocks
    }

    private static func isExactlyReproducibleClockLayer(_ layer: SceneLayer) -> Bool {
        guard layer.effects.isEmpty,
              layer.effectSettings.isEmpty,
              !layer.hasAnimation,
              layer.angles.x == 0,
              layer.angles.y == 0,
              let text = layer.text,
              text.fontPath == nil,
              text.verticalAlignment == .top,
              case .clock(let clock) = text.dynamicText,
              clock == SceneClockText(
                  uses24HourFormat: true,
                  showsSeconds: false,
                  delimiter: ":"
              ),
              let script = text.script,
              compacted(script.source) == compacted(knownPadded24HourClockScript) else {
            return false
        }
        let evaluator = SceneScriptTextEvaluator(script: script)
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let samples = [
            DateComponents(year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 5),
            DateComponents(year: 2024, month: 7, day: 31, hour: 12, minute: 34, second: 56),
            DateComponents(year: 2024, month: 12, day: 30, hour: 23, minute: 58, second: 59)
        ]
        return samples.allSatisfy { components in
            guard let date = calendar.date(from: components) else { return false }
            let actual = evaluator.string(
                currentValue: text.value,
                date: date,
                runtime: SceneScriptRuntime(time: 0, frameTime: 1 / 30)
            )
            return actual == clock.string(for: date, calendar: calendar)
        }
    }

    /// This narrow template is intentionally fail-closed. Arbitrary
    /// SceneScript cannot be proven equivalent to a native clock by sampling:
    /// it may add other text only on an unsampled date or runtime condition.
    /// Unknown variants remain baked into the cache instead of being dropped.
    private static let knownPadded24HourClockScript = """
    export function update(value) {
        const time = new Date();
        let hours = time.getHours();
        let minutes = time.getMinutes();
        if (hours < 10) { hours = '0' + hours; }
        if (minutes < 10) { minutes = '0' + minutes; }
        return hours + ':' + minutes;
    }
    """

    private static func compacted(_ source: String) -> String {
        var result = ""
        var quote: Character?
        var isEscaped = false
        for character in source {
            if let activeQuote = quote {
                result.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "'" || character == "\"" {
                quote = character
                result.append(character)
            } else if !character.isWhitespace {
                result.append(character)
            }
        }
        return result
    }

    static func policy(sceneURL: URL) -> Self {
        guard let plan = try? SceneRenderPlanBuilder().buildLayout(url: sceneURL) else {
            // Preserving renderer output is the fail-safe choice. Excluding
            // unknown scripted text can turn a valid text-only scene black.
            return .bakeAll
        }
        return policy(for: plan)
    }
}

/// Keeps the cached video and native overlay in the same per-display layout.
/// A cached Scene is still ordinary wallpaper content: Fit, Fill, and Stretch
/// must remain independent for every assigned display.
struct CachedSceneContentLayout: Equatable {
    let videoDisplayMode: WallpaperDisplayMode
    let overlayFrame: CGRect

    static func resolve(
        canvasSize: CGSize,
        bounds: CGRect,
        displayMode: WallpaperDisplayMode
    ) -> Self {
        Self(
            videoDisplayMode: displayMode,
            overlayFrame: WallpaperContentLayout.scaledContentFrame(
                for: canvasSize,
                in: bounds,
                displayMode: displayMode
            )
        )
    }
}

/// Plays an externally rendered Scene loop while keeping supported live clock
/// layers on the Mac. The external renderer excludes scripted text only when
/// every such layer is a clock represented here, so unsupported scripted text
/// remains visible in the cached video instead of being dropped.
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
    private var displayMode: WallpaperDisplayMode

    init(
        sceneURL: URL,
        videoURL: URL,
        fallbackImageURL: URL?,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool,
        audioVolume: Double
    ) throws {
        let plan = try SceneRenderPlanBuilder().buildLayout(url: sceneURL)
        canvasSize = CGSize(width: plan.canvasSize.width, height: plan.canvasSize.height)
        self.displayMode = displayMode
        videoView = VideoWallpaperView(
            url: videoURL,
            fallbackImageURL: fallbackImageURL,
            frame: CGRect(origin: .zero, size: frame.size),
            displayMode: displayMode,
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

    func setDisplayMode(_ displayMode: WallpaperDisplayMode) {
        self.displayMode = displayMode
        videoView.setDisplayMode(displayMode)
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
        guard SceneLiveTextRecordingPolicy.policy(for: plan) == .overlayClocks else {
            return []
        }
        return plan.layers.filter { layer in
            guard let text = layer.text else { return false }
            if case .clock = text.dynamicText { return true }
            return false
        }
    }

    nonisolated static func hasClockOverlay(sceneURL: URL) -> Bool {
        guard let plan = try? SceneRenderPlanBuilder().buildLayout(url: sceneURL) else {
            return false
        }
        return SceneLiveTextRecordingPolicy.policy(for: plan) == .overlayClocks
    }

    private func layoutContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoView.frame = bounds
        layer?.frame = bounds
        let contentLayout = CachedSceneContentLayout.resolve(
            canvasSize: canvasSize,
            bounds: bounds,
            displayMode: displayMode
        )
        videoView.setDisplayMode(contentLayout.videoDisplayMode)
        let sceneFrame = contentLayout.overlayFrame
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
