import AppKit
import BackgroundEngineCore
import ImageIO

struct AnimatedImageTiming: Equatable, Sendable {
    static let minimumFrameDuration = 1.0 / 60.0
    static let defaultFrameDuration = 0.1

    static func duration(from properties: [CFString: Any]) -> TimeInterval {
        let candidates = ["UnclampedDelayTime", "DelayTime", "FrameDelay"]
        for candidate in candidates {
            if let value = firstNumber(in: properties, matching: candidate), value > 0 {
                return max(minimumFrameDuration, value)
            }
        }
        return defaultFrameDuration
    }

    private static func firstNumber(in dictionary: [CFString: Any], matching keySuffix: String) -> Double? {
        for (key, value) in dictionary {
            let keyName = String(describing: key)
            if keyName.hasSuffix(keySuffix), let number = value as? NSNumber {
                return number.doubleValue
            }
            if let nested = value as? [CFString: Any],
               let number = firstNumber(in: nested, matching: keySuffix) {
                return number
            }
            if let nested = value as? [String: Any] {
                let converted = Dictionary(uniqueKeysWithValues: nested.map { ($0.key as CFString, $0.value) })
                if let number = firstNumber(in: converted, matching: keySuffix) {
                    return number
                }
            }
        }
        return nil
    }
}

enum AnimatedImageError: Error, LocalizedError {
    case unreadable
    case tooLarge
    case tooManyFrames
    case invalidFrame

    var errorDescription: String? {
        switch self {
        case .unreadable: "The image could not be decoded by ImageIO."
        case .tooLarge: "The image exceeds the safe decode memory limit."
        case .tooManyFrames: "The image contains too many animation frames."
        case .invalidFrame: "An image animation frame could not be decoded."
        }
    }
}

/// ImageIO-backed wallpaper view for still images, GIF, APNG and animated
/// WebP. Frames are decoded on demand instead of retained as NSImage objects,
/// which keeps large animations under a predictable memory ceiling.
@MainActor
final class AnimatedImageWallpaperView: NSView, DisplayModeUpdatableContent, PausableWallpaperContent,
    WallpaperContentLifecycle {
    static let maximumSourceBytes = ImageWallpaperValidation.maximumSourceBytes
    static let maximumFrameCount = ImageWallpaperValidation.maximumFrameCount
    static let maximumDecodedFrameBytes = ImageWallpaperValidation.maximumDecodedFrameBytes

    private let source: CGImageSource
    private let frameCount: Int
    private var frameIndex = 0
    private var timer: Timer?
    private var isSuspended = false
    private var displayMode: WallpaperDisplayMode

    init(url: URL, frame: CGRect, displayMode: WallpaperDisplayMode) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AnimatedImageError.unreadable
        }
        guard Int64(values.fileSize ?? 0) <= Self.maximumSourceBytes else {
            throw AnimatedImageError.tooLarge
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            throw AnimatedImageError.unreadable
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw AnimatedImageError.unreadable }
        guard count <= Self.maximumFrameCount else { throw AnimatedImageError.tooManyFrames }
        self.source = source
        self.frameCount = count
        self.displayMode = displayMode
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        try displayFrame(at: 0)
        scheduleNextFrameIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        configureLayer()
    }

    func setDisplayMode(_ displayMode: WallpaperDisplayMode) {
        self.displayMode = displayMode
        configureLayer()
    }

    func setPlaybackSuspended(_ suspended: Bool) {
        isSuspended = suspended
        timer?.invalidate()
        timer = nil
        if !suspended { scheduleNextFrameIfNeeded() }
    }

    func prepareForClose() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func advanceFrame() {
        timer = nil
        guard !isSuspended, frameCount > 1 else { return }
        frameIndex = (frameIndex + 1) % frameCount
        do {
            try displayFrame(at: frameIndex)
            scheduleNextFrameIfNeeded()
        } catch {
            isSuspended = true
        }
    }

    private func displayFrame(at index: Int) throws {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw AnimatedImageError.invalidFrame
        }
        guard let decodedBytes = ImageWallpaperValidation.decodedByteCount(
            width: width.intValue,
            height: height.intValue
        ) else {
            throw AnimatedImageError.invalidFrame
        }
        guard decodedBytes <= Self.maximumDecodedFrameBytes else { throw AnimatedImageError.tooLarge }
        guard let image = ImageWallpaperValidation.createPlaybackFrame(from: source, at: index) else {
            throw AnimatedImageError.invalidFrame
        }
        configureLayer()
        layer?.contents = image
    }

    private func scheduleNextFrameIfNeeded() {
        guard !isSuspended, frameCount > 1 else { return }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, frameIndex, nil) as? [CFString: Any] ?? [:]
        timer = Timer.scheduledTimer(
            timeInterval: AnimatedImageTiming.duration(from: properties),
            target: self,
            selector: #selector(advanceFrame),
            userInfo: nil,
            repeats: false
        )
    }

    private func configureLayer() {
        guard let layer else { return }
        layer.frame = bounds
        layer.backgroundColor = NSColor.black.cgColor
        layer.contentsGravity = WallpaperContentLayout.imageContentsGravity(for: displayMode)
        layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer.minificationFilter = .linear
        layer.magnificationFilter = .linear
    }
}
