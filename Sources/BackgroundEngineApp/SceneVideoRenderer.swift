import Foundation
import BackgroundEngineCore
import Darwin

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Describes one scene->video render job: the external renderer records
/// offscreen PNG frames of the scene, which ffmpeg then encodes into a
/// loopable mp4 that plays through the normal video-wallpaper path.
struct SceneVideoRenderConfiguration: Sendable {
    let assetId: String
    let projectDirectory: URL
    let assetsDirectory: URL
    let rendererURL: URL
    let size: CGSize
    let fps: Int
    let seconds: Int
    // The scene.pkg itself, used only to extract authored sound layers to mux
    // into the cached video as a looping audio track. Optional (defaulting to
    // nil) so existing callers/tests that only care about the video pipeline
    // don't need to supply it; when nil, the render is silent as before.
    let sceneURL: URL?
    let contentHash: String?
    let quality: RenderQuality
    let mediaBuildID: String
    let engineAssetsFingerprint: String

    init(
        assetId: String,
        projectDirectory: URL,
        assetsDirectory: URL,
        rendererURL: URL,
        size: CGSize,
        fps: Int = 30,
        // A longer recorded clip means the (still perceptible) loop point is
        // reached less often, making the seam less jarring for scenes whose
        // motion doesn't tile perfectly. The tradeoff is a longer first
        // render, which the rendering-progress status message covers.
        seconds: Int = 20,
        sceneURL: URL? = nil,
        contentHash: String? = nil,
        quality: RenderQuality = .balanced,
        mediaBuildID: String = MediaToolResolver.pinnedBuildID,
        engineAssetsFingerprint: String = "unfingerprinted"
    ) {
        self.assetId = assetId
        self.projectDirectory = projectDirectory
        self.assetsDirectory = assetsDirectory
        self.rendererURL = rendererURL
        self.size = size
        self.fps = fps
        self.seconds = seconds
        self.sceneURL = sceneURL
        self.contentHash = contentHash
        self.quality = quality
        self.mediaBuildID = mediaBuildID
        self.engineAssetsFingerprint = engineAssetsFingerprint
    }

    var cacheKey: SceneVideoCacheKey? {
        guard let contentHash else { return nil }
        return SceneVideoCacheKey(
            assetID: assetId,
            contentHash: contentHash,
            rendererVersion: SceneVideoCache.rendererVersion,
            mediaBuildID: mediaBuildID,
            engineAssetsFingerprint: engineAssetsFingerprint,
            width: Int(size.width),
            height: Int(size.height),
            quality: quality
        )
    }

    var lowQualityFallback: SceneVideoRenderConfiguration {
        let size = SceneVideoRecordSize.clampedRecordSize(forLogicalSize: size, maxLongEdge: 1_280)
        return SceneVideoRenderConfiguration(
            assetId: assetId,
            projectDirectory: projectDirectory,
            assetsDirectory: assetsDirectory,
            rendererURL: rendererURL,
            size: size,
            fps: fps,
            seconds: seconds,
            sceneURL: sceneURL,
            contentHash: contentHash,
            quality: .low,
            mediaBuildID: mediaBuildID,
            engineAssetsFingerprint: engineAssetsFingerprint
        )
    }
}

struct SceneVideoCacheKey: Codable, Equatable, Sendable {
    let assetID: String
    let contentHash: String
    let rendererVersion: String
    let mediaBuildID: String
    let engineAssetsFingerprint: String
    let width: Int
    let height: Int
    let quality: RenderQuality

    init(
        assetID: String,
        contentHash: String,
        rendererVersion: String,
        mediaBuildID: String = MediaToolResolver.pinnedBuildID,
        engineAssetsFingerprint: String = "unfingerprinted",
        width: Int,
        height: Int,
        quality: RenderQuality
    ) {
        self.assetID = assetID
        self.contentHash = contentHash
        self.rendererVersion = rendererVersion
        self.mediaBuildID = mediaBuildID
        self.engineAssetsFingerprint = engineAssetsFingerprint
        self.width = width
        self.height = height
        self.quality = quality
    }

    var fileName: String {
        let safeAssetID = assetID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let media = mediaBuildID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression
        )
        return "\(safeAssetID)-\(contentHash.prefix(16))-\(rendererVersion)-\(media)-\(engineAssetsFingerprint.prefix(16))-\(width)x\(height)-\(quality.rawValue).mp4"
    }
}

/// Computes a sensible offscreen record size for a scene render, derived
/// from the display's logical (point) size rather than its physical
/// (backing/retina) pixel size. Recording at full physical resolution on a
/// retina display (e.g. 3024x1964, doubled again by an over-eager renderer
/// to 6048x3928) produces multi-hundred-megabyte clips that take minutes to
/// encode; clamping the long edge keeps the cached wallpaper video small and
/// fast to render while remaining crisp.
enum SceneVideoRecordSize {
    /// Wallpapers are viewed from a normal desktop distance, so ~1920px on
    /// the long edge is plenty crisp while keeping render time and cache
    /// size small.
    static let defaultMaxLongEdge: CGFloat = 1920

    /// Clamps `logicalSize` so its longer edge does not exceed `maxLongEdge`,
    /// preserving aspect ratio. Dimensions are rounded to even integers,
    /// which common H.264 encoders (including the VideoToolbox pipeline used
    /// here) require for `yuv420p` output.
    static func clampedRecordSize(
        forLogicalSize logicalSize: CGSize,
        maxLongEdge: CGFloat = defaultMaxLongEdge
    ) -> CGSize {
        guard logicalSize.width > 0, logicalSize.height > 0 else {
            return evenSize(CGSize(width: maxLongEdge, height: maxLongEdge))
        }
        let longEdge = max(logicalSize.width, logicalSize.height)
        guard longEdge > maxLongEdge else {
            return evenSize(logicalSize)
        }
        let scale = maxLongEdge / longEdge
        return evenSize(CGSize(width: logicalSize.width * scale, height: logicalSize.height * scale))
    }

    private static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(width: evenRounded(size.width), height: evenRounded(size.height))
    }

    private static func evenRounded(_ value: CGFloat) -> CGFloat {
        let rounded = value.rounded()
        let isEven = rounded.truncatingRemainder(dividingBy: 2) == 0
        return max(2, isEven ? rounded : rounded - 1)
    }
}

/// Where rendered scene videos are cached, keyed by asset id. Accessed from
/// both the main actor (checking for a fresh cache before playback) and
/// background render tasks (writing the freshly encoded video), so the test
/// override is intentionally not actor-isolated.
enum SceneVideoCache {
    static let rendererVersion = "7acc6c9"
    /// Bump whenever a change to the render pipeline (record size, encoding
    /// settings, loop handling, etc.) would make previously cached videos
    /// undesirable even though the source scene package itself hasn't
    /// changed. Cache entries are stored under a version-numbered
    /// subdirectory, so bumping this invalidates every existing cache entry
    /// at once: old videos are simply never found and a fresh one is
    /// rendered and written under the new version's directory.
    ///
    /// v2: fixed record size to use clamped logical points instead of
    /// doubled physical retina pixels (previously produced oversized
    /// 6048x3928 clips).
    ///
    /// v3: default record duration increased from 10s to 20s so the loop
    /// point is reached less often, making the seam where playback jumps
    /// back to the start less noticeable.
    ///
    /// v4: the encode now crossfades the recorded clip's tail into its head
    /// (see `SceneVideoLoopCrossfade`), so the loop seam itself is blended
    /// away instead of merely being made less frequent.
    ///
    /// v5: recordings pass `--record-exclude-live` so live-data elements
    /// (clock text etc.) are no longer baked into the looping video, and the
    /// renderer restored water sparkles with Windows-matched bloom/tone.
    ///
    /// v6: the scene's authored sound layers (ambience/music) are now muxed
    /// into the cached mp4 as a looping audio track (see
    /// `SceneAudioExtractor`/`SceneAudioMux`). Mute/volume are applied at
    /// playback time (`VideoWallpaperView`), so no further bump is needed
    /// when only the user's audio preference changes.
    ///
    /// v7: the cached video is now stretched - by repeating its own
    /// seamless loop clip (see `SceneVideoLoopExtension`) - to match the
    /// longest authored audio track's duration (capped at
    /// `SceneAudioMasterDuration.maximumSeconds`), and that track plays once
    /// per wallpaper loop instead of being cut off mid-phrase at the video's
    /// own short, arbitrary loop point. Shorter authored layers (ambience
    /// etc.) keep looping underneath it.
    static let cacheVersion = 8

    nonisolated(unsafe) static var overrideCacheDirectoryURL: URL?

    static func cacheDirectoryURL() -> URL {
        if let overrideCacheDirectoryURL {
            return overrideCacheDirectoryURL
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Background Engine")
            .appending(path: "SceneVideoCache")
            .appending(path: "v\(cacheVersion)")
    }

    static func cachedVideoURL(assetId: String) -> URL {
        cacheDirectoryURL().appending(path: "\(assetId).mp4")
    }

    static func cachedVideoURL(key: SceneVideoCacheKey) -> URL {
        cacheDirectoryURL().appending(path: key.fileName)
    }

    /// A cache entry is fresh when it exists and was written on or after the
    /// scene package it was rendered from was last modified. Modification
    /// dates are read via `FileManager` rather than `URL.resourceValues`
    /// because the latter caches values per `URL` instance, which would
    /// return stale results after the source file is touched again.
    static func isFresh(cacheURL: URL, sourceURL: URL) -> Bool {
        let fileManager = FileManager.default
        guard let cacheModified = modificationDate(of: cacheURL, fileManager: fileManager),
              let sourceModified = modificationDate(of: sourceURL, fileManager: fileManager) else {
            return false
        }
        return cacheModified >= sourceModified
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) -> Date? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    static func freshCachedVideoURL(assetId: String, sourceURL: URL) -> URL? {
        let url = cachedVideoURL(assetId: assetId)
        return isFresh(cacheURL: url, sourceURL: sourceURL) ? url : nil
    }

    static func freshCachedVideoURL(key: SceneVideoCacheKey, sourceURL: URL) -> URL? {
        let url = cachedVideoURL(key: key)
        return isFresh(cacheURL: url, sourceURL: sourceURL) ? url : nil
    }

    static func freshCachedVideoURL(assetID: String, contentHash: String?, sourceURL: URL) -> URL? {
        guard let contentHash else {
            return freshCachedVideoURL(assetId: assetID, sourceURL: sourceURL)
        }
        let safeAssetID = assetID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let prefix = "\(safeAssetID)-\(contentHash.prefix(16))-"
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectoryURL(),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return candidates.first { url in
            url.lastPathComponent.hasPrefix(prefix) && isFresh(cacheURL: url, sourceURL: sourceURL)
        }
    }
}

/// The status a library row should display for an asset. This is purely
/// presentational: it never touches `WallpaperAsset.supportStatus`, which
/// stays scan-derived and is what's persisted to `library.json`. Scenes are
/// special-cased because playing one for the first time renders an offscreen
/// video (see `SceneWallpaperContentFactory`), which takes about a minute -
/// showing the same "playable" badge a video/image asset gets would make
/// that first play look broken while it renders.
enum LibraryRowDisplayStatus: Equatable {
    case live
    case cached
    case limited([WallpaperCapability])
    case unsupported(SupportStatus)

    var label: String {
        switch self {
        case .live: return "Full Live"
        case .cached: return "Full Cached"
        case .limited: return "Limited"
        case .unsupported: return "Unsupported"
        }
    }

    var isPositive: Bool {
        switch self {
        case .live, .cached, .limited: true
        case .unsupported: false
        }
    }
}

enum LibraryRowStatusResolver {
    /// Derives the display status fresh from disk state every call rather
    /// than caching it, so the row picks up a completed render simply by
    /// re-evaluating on the next SwiftUI re-render (e.g. once the app's
    /// status message flips to "Playing" after the background render task
    /// finishes).
    static func status(for asset: WallpaperAsset) -> LibraryRowDisplayStatus {
        guard asset.supportStatus == .playable else {
            return .unsupported(asset.supportStatus)
        }
        if let report = asset.compatibilityReport {
            switch report.level {
            case .limited:
                return .limited(report.missingCapabilities)
            case .unsupported:
                return .unsupported(asset.supportStatus)
            case .full:
                if report.playbackPath == .convertedVideo || report.playbackPath == .renderedSceneCache {
                    return .cached
                }
                return .live
            }
        }
        guard asset.kind == .scene, let entrypoint = asset.entrypoint else {
            return .live
        }
        let sourceURL = URL(filePath: entrypoint)
        let hasFreshCache = SceneVideoCache.freshCachedVideoURL(
            assetID: asset.id,
            contentHash: asset.contentHash,
            sourceURL: sourceURL
        ) != nil
        return hasFreshCache ? .cached : .live
    }
}

/// Pure math for turning a recorded (non-tiling) clip into a seamlessly
/// looping one by crossfading its tail into its head at encode time,
/// factored out of `SceneVideoRenderer.ffmpegArguments` so the frame/offset
/// arithmetic can be unit tested without invoking ffmpeg.
///
/// Given a recorded clip of `totalFrameCount` frames at `fps`, the output is
/// built from two views of the same frame sequence:
/// - `main` = frames `[crossfadeFrameCount, totalFrameCount)`, i.e. the clip
///   with its first `crossfadeFrameCount` frames trimmed off, re-based to
///   start at t=0.
/// - `head` = frames `[0, crossfadeFrameCount)`, i.e. just the clip's head.
///
/// ffmpeg's `xfade` filter is applied as `xfade(main, head)`: it plays
/// `main` unblended for `offsetSeconds`, then blends `main`'s next
/// `crossfadeSeconds` (which is exactly the *original* clip's tail, since
/// `main` is `main`'s local time + the trimmed head duration) with `head`'s
/// full duration (the *original* clip's head). Because `xfade`'s total output
/// duration is `offset + duration(head)`, and `duration(head) ==
/// crossfadeSeconds`, the result is exactly `totalSeconds - crossfadeSeconds`
/// long, with the seam itself replaced by a blend of the original tail and
/// head instead of a hard cut between them.
enum SceneVideoLoopCrossfade {
    /// The recommended crossfade window: long enough to hide a swimming/
    /// drifting scene's seam, short enough not to noticeably shorten the
    /// loop or blur fast motion.
    static let defaultSeconds: Double = 1.2

    /// How many frames the crossfade should span, clamped so recordings that
    /// are too short to crossfade (mainly small fixtures in tests) fall back
    /// to a plain (non-crossfaded) encode rather than producing invalid
    /// ffmpeg filter arguments.
    ///
    /// Crossfading requires an unblended `main` body of positive length
    /// before the transition starts, i.e. `totalFrameCount > 2 *
    /// crossfadeFrameCount`; when the recording is too short for that
    /// (mainly small fixtures in tests), this returns 0 to signal "disable
    /// crossfading".
    static func frameCount(totalFrameCount: Int, fps: Int, seconds: Double = defaultSeconds) -> Int {
        guard totalFrameCount > 0, fps > 0 else {
            return 0
        }
        let desired = max(1, Int((seconds * Double(fps)).rounded()))
        guard totalFrameCount > desired * 2 else {
            return 0
        }
        return desired
    }

    /// Seconds of unblended `main` playback before the crossfade transition
    /// begins. This is also the `offset` argument to ffmpeg's `xfade` filter.
    static func offsetSeconds(totalFrameCount: Int, crossfadeFrameCount: Int, fps: Int) -> Double {
        guard fps > 0 else {
            return 0
        }
        return Double(totalFrameCount - 2 * crossfadeFrameCount) / Double(fps)
    }

    /// The final output duration: the recorded clip's length minus one
    /// crossfade window.
    static func outputSeconds(totalFrameCount: Int, crossfadeFrameCount: Int, fps: Int) -> Double {
        guard fps > 0 else {
            return 0
        }
        return Double(totalFrameCount - crossfadeFrameCount) / Double(fps)
    }
}

/// One authored sound layer extracted from a scene package's `scene.json`
/// (an object with a `sound` array), factored out so it can be tested without
/// reading an actual `.pkg` file.
struct SceneAudioTrack: Equatable, Sendable {
    /// The package-relative path to the audio file (e.g. `sounds/x.mp3`).
    let path: String
    /// The layer's authored volume (`volume.value` in scene.json), used as
    /// the mix weight so louder/quieter authored layers stay proportionate
    /// to one another. Defaults to 1.0 when the layer doesn't specify one.
    let volume: Double
}

/// Reads the sound layers a scene author configured (ambience, background
/// music, etc.) out of a parsed `scene.json`, factored out of
/// `SceneVideoRenderer` so the JSON-shape logic can be unit tested without
/// touching the filesystem.
enum SceneAudioExtractor {
    static func audioTracks(scene: [String: Any]) -> [SceneAudioTrack] {
        let objects = scene["objects"] as? [[String: Any]] ?? []
        var tracks: [SceneAudioTrack] = []
        for object in objects {
            guard let soundPaths = object["sound"] as? [Any] else {
                continue
            }
            let volume = volumeValue(object["volume"]) ?? 1.0
            for case let path as String in soundPaths {
                tracks.append(SceneAudioTrack(path: path, volume: volume))
            }
        }
        return tracks
    }

    private static func volumeValue(_ value: Any?) -> Double? {
        if let dict = value as? [String: Any] {
            return volumeValue(dict["value"])
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let double = value as? Double {
            return double
        }
        return nil
    }
}

/// Parses ffmpeg's own `Duration: HH:MM:SS.ss` line - printed to stderr while
/// probing any input file, even when no output is given - so a track's
/// length can be discovered without adding a dependency on a separate
/// `ffprobe` binary. Factored out so the text parsing can be unit tested
/// without invoking a process.
enum SceneAudioDurationProbe {
    static func durationSeconds(fromFfmpegOutput text: String) -> Double? {
        guard let range = text.range(of: "Duration: ") else {
            return nil
        }
        let afterLabel = text[range.upperBound...]
        guard let commaIndex = afterLabel.firstIndex(of: ",") else {
            return nil
        }
        let timeComponents = afterLabel[afterLabel.startIndex..<commaIndex].split(separator: ":")
        guard timeComponents.count == 3,
              let hours = Double(timeComponents[0]),
              let minutes = Double(timeComponents[1]),
              let seconds = Double(timeComponents[2]) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// Injectable so tests can stub the ffmpeg invocation. Runs ffmpeg with
    /// only an input (no output file); ffmpeg still prints the input's
    /// metadata, including its `Duration:` line, to stderr before erroring
    /// out for lack of an output - the error itself is irrelevant here since
    /// only stderr's text is inspected.
    nonisolated(unsafe) static var ffmpegProbeOutput: (String, URL, String) throws -> String = {
        ffmpegPath, url, assetID in
        let capture = try SceneVideoRenderer.captureProcessOutput(
            executableURL: URL(filePath: ffmpegPath),
            arguments: ["-i", url.path],
            assetID: assetID,
            timeout: 10
        )
        return String(data: capture.stderr, encoding: .utf8) ?? ""
    }

    static func durationSeconds(ffmpegPath: String, url: URL, assetID: String) throws -> Double? {
        durationSeconds(fromFfmpegOutput: try ffmpegProbeOutput(ffmpegPath, url, assetID))
    }
}

/// Derives the "master" duration a scene's cached wallpaper video is
/// stretched to match: the longest authored audio track's own length, so
/// that track (typically the background music) always plays all the way
/// through once per wallpaper loop instead of being cut off mid-phrase at a
/// short, arbitrary video loop point.
enum SceneAudioMasterDuration {
    /// Caps how far a scene's video is stretched to match its soundtrack.
    /// Without a cap, an unusually long authored track (an entire album,
    /// say) would blow up the cached mp4's size and first-render encode
    /// time; 4 minutes comfortably covers ordinary wallpaper background
    /// music/ambience loops while keeping both bounded.
    static let maximumSeconds: Double = 240

    static func masterDurationSeconds(trackDurationsSeconds: [Double]) -> Double? {
        guard let longest = trackDurationsSeconds.max(), longest > 0 else {
            return nil
        }
        return min(longest, maximumSeconds)
    }
}

/// Pure math (plus the one ffmpeg invocation) for stretching an already
/// seamlessly-looping video clip to cover a longer authored soundtrack by
/// repeating the clip itself, factored out of `SceneVideoRenderer` so the
/// repeat-count arithmetic can be unit tested without invoking ffmpeg.
enum SceneVideoLoopExtension {
    /// How many times the seamless `loopSeconds`-long clip needs to repeat to
    /// reach (or just exceed) `masterDurationSeconds`. Returns 1 (no
    /// stretching) when the clip is already at least as long as the
    /// soundtrack, so short authored tracks never shrink the video.
    static func repeatCount(loopSeconds: Double, masterDurationSeconds: Double) -> Int {
        guard loopSeconds > 0, masterDurationSeconds > loopSeconds else {
            return 1
        }
        return Int((masterDurationSeconds / loopSeconds).rounded(.up))
    }

    static func totalSeconds(loopSeconds: Double, repeatCount: Int) -> Double {
        loopSeconds * Double(max(1, repeatCount))
    }

    /// Repeats `loopableVideoURL` (itself already a seamlessly-looping clip)
    /// `repeatCount` times using `-stream_loop` with a stream copy (`-c
    /// copy`), rather than re-encoding N concatenated copies: since every
    /// repeat is byte-identical to the one seamless clip, a copy remux costs
    /// no quality or time beyond the original encode, and the internal seams
    /// between repeats are exactly the same (already-verified) loop point as
    /// the outer wallpaper loop. `-t` guards against sub-frame float drift in
    /// the repeated stream so the output is exactly `repeatCount *
    /// loopSeconds` long.
    static func ffmpegArguments(
        loopableVideoURL: URL,
        repeatCount: Int,
        totalSeconds: Double,
        outputURL: URL
    ) -> [String] {
        [
            "-y",
            "-stream_loop", String(max(0, repeatCount - 1)),
            "-i", loopableVideoURL.path,
            "-c", "copy",
            "-t", formatSeconds(totalSeconds),
            "-movflags", "+faststart",
            outputURL.path
        ]
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

/// Chooses how many times one authored track should repeat (ffmpeg's
/// `-stream_loop` value) so it fits some whole number of complete
/// playthroughs inside `totalDurationSeconds` without ever being cut off
/// mid-play - unlike an unconditional `-stream_loop -1`, which tiles the
/// track exactly but then truncates whatever repeat is in progress the
/// instant `totalDurationSeconds` is reached, which can chop a musical phrase
/// off mid-way if the track's own duration doesn't happen to divide evenly
/// into the total. Factored out of `SceneAudioMux` so the arithmetic can be
/// unit tested without invoking ffmpeg.
enum SceneAudioTrackLoop {
    /// The literal value to pass to ffmpeg's `-stream_loop` flag: `-1` means
    /// loop forever, `0` means play once, `N` means play `N + 1` times total.
    /// Here it's always >= 0 (never `-1`) so every track completes cleanly;
    /// any remaining time before `totalDurationSeconds` is silence, added by
    /// `SceneAudioMux`'s `apad`.
    static func streamLoopValue(trackDurationSeconds: Double, totalDurationSeconds: Double) -> Int {
        guard trackDurationSeconds > 0, totalDurationSeconds > 0 else {
            return 0
        }
        let wholePlaythroughs = max(1, Int((totalDurationSeconds / trackDurationSeconds).rounded(.down)))
        return wholePlaythroughs - 1
    }
}

/// Builds the ffmpeg invocation that muxes one or more authored audio tracks
/// onto an already-encoded (silent) scene video, factored out so the
/// argument construction can be unit tested without invoking ffmpeg.
///
/// Each track carries its own `-stream_loop` value (see
/// `SceneAudioTrackLoop`): rather than singling out one "master" track to
/// play once while every other track loops forever (which would still cut a
/// shorter, non-master track off mid-phrase the instant the video's
/// stretched duration is reached - exactly the bug this design avoids), every
/// track is given an exact whole-number repeat count that fits inside the
/// video's total duration, so no authored track is ever truncated mid-play.
/// The mixed bed is padded with silence (`apad`) up to the video's exact
/// duration - covering the (typically short) remainder after every track's
/// last complete playthrough - then trimmed with an explicit `-t` (rather
/// than `-shortest`) so `AVPlayerLooper` sees matching track lengths and
/// never introduces a silent/black gap at the loop point.
enum SceneAudioMux {
    static func ffmpegArguments(
        videoURL: URL,
        audioTracks: [(url: URL, weight: Double, streamLoopValue: Int)],
        outputURL: URL,
        totalDurationSeconds: Double
    ) -> [String] {
        guard !audioTracks.isEmpty else {
            return []
        }

        var arguments = ["-y", "-i", videoURL.path]
        for track in audioTracks {
            arguments += ["-stream_loop", String(track.streamLoopValue), "-i", track.url.path]
        }

        var filters: [String] = []
        if audioTracks.count == 1 {
            filters.append("[1:a]volume=\(formatWeight(audioTracks[0].weight))[mix]")
        } else {
            var mixLabels: [String] = []
            for (index, track) in audioTracks.enumerated() {
                let inputIndex = index + 1
                let label = "a\(index)"
                filters.append("[\(inputIndex):a]volume=\(formatWeight(track.weight))[\(label)]")
                mixLabels.append("[\(label)]")
            }
            filters.append("\(mixLabels.joined())amix=inputs=\(audioTracks.count):duration=longest:normalize=0[mix]")
        }
        filters.append("[mix]apad=whole_dur=\(formatSeconds(totalDurationSeconds))[a]")

        arguments += [
            "-filter_complex", filters.joined(separator: ";"),
            "-map", "0:v",
            "-map", "[a]",
            "-c:v", "copy",
            "-c:a", "aac",
            "-t", formatSeconds(totalDurationSeconds),
            "-movflags", "+faststart",
            outputURL.path
        ]
        return arguments
    }

    private static func formatWeight(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

enum SceneVideoRenderer {
    private static let processRegistry = SceneRenderProcessRegistry()

    static func cancelActiveProcesses(assetID: String) {
        processRegistry.cancel(assetID: assetID)
    }

    static func cancelAllActiveProcesses() {
        processRegistry.cancelAll()
    }

    /// Small offscreen probe used before a full cache render. Only process
    /// failure, timeout, or zero frames are hard failures; pixel brightness
    /// and motion are deliberately not judged because valid wallpapers can
    /// be intentionally dark or static.
    static func preflight(
        configuration: SceneVideoRenderConfiguration,
        timeout: TimeInterval = 15
    ) throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appending(path: "background-engine-scene-preflight-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let probe = SceneVideoRenderConfiguration(
            assetId: configuration.assetId,
            projectDirectory: configuration.projectDirectory,
            assetsDirectory: configuration.assetsDirectory,
            rendererURL: configuration.rendererURL,
            size: CGSize(width: 320, height: 180),
            fps: 2,
            seconds: 1,
            sceneURL: nil,
            contentHash: nil,
            quality: .low,
            mediaBuildID: configuration.mediaBuildID,
            engineAssetsFingerprint: configuration.engineAssetsFingerprint
        )
        let process = Process()
        process.executableURL = configuration.rendererURL
        process.arguments = recordingArguments(recordDirectory: directory, configuration: probe)
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try processRegistry.launch(process, assetID: configuration.assetId)
            if Task.isCancelled {
                _ = processRegistry.terminateAndWait(process)
                throw CancellationError()
            }
        } catch {
            if !process.isRunning {
                processRegistry.unregister(process, assetID: configuration.assetId)
            }
            throw error
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            _ = processRegistry.terminateAndWait(process)
            if !process.isRunning {
                processRegistry.unregister(process, assetID: configuration.assetId)
            }
            throw SceneVideoRenderError.preflightTimedOut
        }
        processRegistry.unregister(process, assetID: configuration.assetId)
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw SceneVideoRenderError.processFailed(
                configuration.rendererURL.lastPathComponent,
                process.terminationStatus
            )
        }
        let frameCount = (try? fileManager.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix("frame_") }
            .count ?? 0
        guard frameCount > 0 else { throw SceneVideoRenderError.noFramesRecorded }
    }

    /// Injectable so tests can capture the ffmpeg invocation instead of
    /// actually spawning a process. Rendering runs off the main actor (see
    /// `render(configuration:ffmpegPath:)`), so this is intentionally not
    /// actor-isolated.
    nonisolated(unsafe) static var runProcess: (URL, [String], String) throws -> Void = {
        executableURL, arguments, assetID in
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        do {
            try processRegistry.launch(process, assetID: assetID)
            if Task.isCancelled {
                _ = processRegistry.terminateAndWait(process)
                throw CancellationError()
            }
        } catch {
            if !process.isRunning { processRegistry.unregister(process, assetID: assetID) }
            throw error
        }
        process.waitUntilExit()
        processRegistry.unregister(process, assetID: assetID)
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw SceneVideoRenderError.processFailed(executableURL.lastPathComponent, process.terminationStatus)
        }
    }

    static func canRender(rendererURL: URL?, assetsDirectory: URL?, ffmpegPath: String?) -> Bool {
        rendererURL != nil && assetsDirectory != nil && ffmpegPath != nil
    }

    static func recordingArguments(
        recordDirectory: URL,
        configuration: SceneVideoRenderConfiguration
    ) -> [String] {
        [
            "--window", windowArgument(for: configuration.size),
            "--silent",
            "--noautomute",
            "--no-audio-processing",
            "--disable-mouse",
            "--record-dir", recordDirectory.path,
            "--record-seconds", String(configuration.seconds),
            "--record-fps", String(configuration.fps),
            "--record-exclude-live",
            "--assets-dir", configuration.assetsDirectory.path,
            configuration.projectDirectory.path
        ]
    }

    /// Builds the ffmpeg invocation that encodes the recorded frame sequence
    /// into the cached mp4. `recordedFrameCount` is the number of frames
    /// actually written by the renderer (not the requested `fps * seconds`
    /// target, which the renderer may fall short of or exceed slightly).
    ///
    /// When there are enough frames, the clip's tail is crossfaded into its
    /// head (see `SceneVideoLoopCrossfade`) so the encoded video loops
    /// seamlessly instead of jump-cutting back to frame 0. Short recordings
    /// (mainly test fixtures) fall back to a plain single-pass encode.
    static func ffmpegArguments(
        framesDirectory: URL,
        fps: Int,
        recordedFrameCount: Int,
        outputURL: URL
    ) -> [String] {
        let framePattern = framesDirectory.appending(path: "frame_%05d.png").path
        let crossfadeFrameCount = SceneVideoLoopCrossfade.frameCount(totalFrameCount: recordedFrameCount, fps: fps)
        guard crossfadeFrameCount > 0 else {
            return [
                "-y",
                "-framerate", String(fps),
                "-i", framePattern,
                "-c:v", "h264_videotoolbox",
                "-allow_sw", "1",
                "-b:v", "12M",
                "-pix_fmt", "yuv420p",
                "-movflags", "+faststart",
                outputURL.path
            ]
        }

        let offsetSeconds = SceneVideoLoopCrossfade.offsetSeconds(
            totalFrameCount: recordedFrameCount,
            crossfadeFrameCount: crossfadeFrameCount,
            fps: fps
        )
        let crossfadeSeconds = Double(crossfadeFrameCount) / Double(fps)
        let filterComplex = "[0:v]trim=start_frame=\(crossfadeFrameCount),setpts=PTS-STARTPTS[main];"
            + "[1:v]trim=end_frame=\(crossfadeFrameCount),setpts=PTS-STARTPTS[head];"
            + "[main][head]xfade=transition=fade:duration=\(formatSeconds(crossfadeSeconds)):offset=\(formatSeconds(offsetSeconds))[out]"

        return [
            "-y",
            "-framerate", String(fps),
            "-i", framePattern,
            "-framerate", String(fps),
            "-i", framePattern,
            "-filter_complex", filterComplex,
            "-map", "[out]",
            "-c:v", "h264_videotoolbox",
            "-allow_sw", "1",
            "-b:v", "12M",
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
            outputURL.path
        ]
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    // MARK: - Raw-pipe pipeline (renderer --record-raw + concurrent ffmpeg)

    /// Injectable seam for probing whether `rendererURL` supports
    /// `--record-raw` (streaming RGBA frames to a FIFO) by inspecting its
    /// `--help` output, so tests can stub the probe without running a real
    /// binary. Failures (missing binary, non-zero exit, etc.) resolve to an
    /// empty string, which `supportsRecordRaw` treats as "not supported" so
    /// the caller falls back to the PNG-sequence pipeline.
    nonisolated(unsafe) static var rendererHelpOutput: (URL, String) -> String = { rendererURL, assetID in
        guard let capture = try? captureProcessOutput(
            executableURL: rendererURL,
            arguments: ["--help"],
            assetID: assetID,
            timeout: 10
        ) else {
            return ""
        }
        return String(data: capture.stdout, encoding: .utf8) ?? ""
    }

    /// Pure check factored out of `rendererHelpOutput` so the detection logic
    /// can be unit tested against sample `--help` text without invoking a
    /// process.
    static func supportsRecordRaw(helpOutput: String) -> Bool {
        helpOutput.contains("record-raw")
    }

    static func supportsRecordRaw(rendererURL: URL, assetID: String) -> Bool {
        supportsRecordRaw(helpOutput: rendererHelpOutput(rendererURL, assetID))
    }

    /// Builds the renderer invocation for the raw-pipe pipeline: identical to
    /// `recordingArguments` except frames stream to `fifoURL` (a FIFO or
    /// regular file) via `--record-raw` instead of being written as a PNG
    /// sequence via `--record-dir`.
    static func rawRecordingArguments(
        fifoURL: URL,
        configuration: SceneVideoRenderConfiguration
    ) -> [String] {
        [
            "--window", windowArgument(for: configuration.size),
            "--silent",
            "--noautomute",
            "--no-audio-processing",
            "--disable-mouse",
            "--record-raw", fifoURL.path,
            "--record-seconds", String(configuration.seconds),
            "--record-fps", String(configuration.fps),
            "--record-exclude-live",
            "--assets-dir", configuration.assetsDirectory.path,
            configuration.projectDirectory.path
        ]
    }

    /// Builds the ffmpeg invocation that reads raw RGBA frames from
    /// `fifoURL` as they're streamed by the renderer and encodes them into a
    /// fast, near-lossless intermediate mp4. Encoding overlaps the renderer's
    /// frame production (rather than waiting for it to finish, as the PNG
    /// pipeline does), which is the whole point of the raw-pipe pipeline.
    ///
    /// The crossfade loop filter (`SceneVideoLoopCrossfade`) needs to read
    /// the same clip twice (once for its head, once for its tail), which a
    /// single-consumer FIFO can't provide - so this stage only transcodes the
    /// raw stream to a seekable intermediate file; `videoCrossfadeFfmpegArguments`
    /// then runs the crossfade pass on that file as a second, much shorter
    /// (real-time-fast) step.
    static func rawEncodeFfmpegArguments(
        fifoURL: URL,
        size: CGSize,
        fps: Int,
        outputURL: URL
    ) -> [String] {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        return [
            "-y",
            "-f", "rawvideo",
            "-pix_fmt", "rgba",
            "-s", "\(width)x\(height)",
            "-r", String(fps),
            "-i", fifoURL.path,
            "-c:v", "h264_videotoolbox",
            "-allow_sw", "1",
            "-b:v", "40M",
            "-pix_fmt", "yuv420p",
            outputURL.path
        ]
    }

    /// Same crossfade-loop math as `ffmpegArguments`, but reading from an
    /// already-encoded video file (the raw-pipe pipeline's intermediate mp4)
    /// instead of a PNG frame sequence.
    static func videoCrossfadeFfmpegArguments(
        videoURL: URL,
        fps: Int,
        recordedFrameCount: Int,
        outputURL: URL
    ) -> [String] {
        let crossfadeFrameCount = SceneVideoLoopCrossfade.frameCount(totalFrameCount: recordedFrameCount, fps: fps)
        guard crossfadeFrameCount > 0 else {
            return [
                "-y",
                "-i", videoURL.path,
                "-c:v", "h264_videotoolbox",
                "-allow_sw", "1",
                "-b:v", "12M",
                "-pix_fmt", "yuv420p",
                "-movflags", "+faststart",
                outputURL.path
            ]
        }

        let offsetSeconds = SceneVideoLoopCrossfade.offsetSeconds(
            totalFrameCount: recordedFrameCount,
            crossfadeFrameCount: crossfadeFrameCount,
            fps: fps
        )
        let crossfadeSeconds = Double(crossfadeFrameCount) / Double(fps)
        let filterComplex = "[0:v]trim=start_frame=\(crossfadeFrameCount),setpts=PTS-STARTPTS[main];"
            + "[1:v]trim=end_frame=\(crossfadeFrameCount),setpts=PTS-STARTPTS[head];"
            + "[main][head]xfade=transition=fade:duration=\(formatSeconds(crossfadeSeconds)):offset=\(formatSeconds(offsetSeconds))[out]"

        return [
            "-y",
            "-i", videoURL.path,
            "-i", videoURL.path,
            "-filter_complex", filterComplex,
            "-map", "[out]",
            "-c:v", "h264_videotoolbox",
            "-allow_sw", "1",
            "-b:v", "12M",
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
            outputURL.path
        ]
    }

    /// Injectable seam for constructing (but deliberately not launching) a
    /// process. The registry performs registration and launch while holding
    /// one lock, so cancellation cannot slip through a launch/register gap.
    nonisolated(unsafe) static var makeProcess: (URL, [String], Pipe?) -> Process = { executableURL, arguments, stderrPipe in
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let stderrPipe {
            process.standardError = stderrPipe
        }
        return process
    }

    /// How long the raw-pipe pipeline is allowed to run before it's treated
    /// as stalled (renderer hung mid-scene, ffmpeg stopped reading, etc.) and
    /// both child processes are killed so `render()` can fall back to the
    /// PNG-sequence pipeline instead of hanging the caller forever.
    /// Injectable so tests can exercise the stall path without waiting on a
    /// realistic timeout. Defaults to twice the requested record duration
    /// with a floor, since the raw-pipe pipeline overlaps recording and
    /// encoding but the final crossfade pass still needs a little headroom
    /// beyond that.
    nonisolated(unsafe) static var rawPipeWatchdogTimeout: (SceneVideoRenderConfiguration) -> TimeInterval = { configuration in
        max(30, Double(configuration.seconds) * 2)
    }

    /// Runs the concurrent raw-pipe pipeline: a FIFO is created, ffmpeg is
    /// started reading raw RGBA frames from it (encoding them to a fast
    /// intermediate file as they arrive), then the renderer is started
    /// writing frames into the same FIFO via `--record-raw`. Once both have
    /// finished, the intermediate file is passed through the existing
    /// crossfade-loop encode to produce the final silent video.
    ///
    /// Race fix: start ffmpeg first, then open a nonblocking, write-only guard
    /// descriptor from this process. That open succeeds only after ffmpeg has
    /// reached its real FIFO read-open, so the renderer cannot fill the FIFO
    /// before the encoder is ready. The guard remains open while the renderer
    /// runs, preventing an early EOF in the small gap before the renderer
    /// opens its own writer, and is closed as soon as the renderer exits so
    /// ffmpeg observes the correct end of stream. An `O_RDWR` anchor is not
    /// used here: because it also counts as a reader it can let a fast
    /// renderer fill the FIFO while ffmpeg is still loading, causing a false
    /// watchdog stall under load.
    ///
    /// Belt-and-braces: an overall watchdog (`rawPipeWatchdogTimeout`) kills
    /// both processes and signals a stall if the pipeline runs far longer
    /// than expected, and every error path below explicitly terminates and
    /// reaps any process it already started so no ffmpeg/renderer instance
    /// is left running past this function returning.
    private static func renderUsingRawPipe(
        configuration: SceneVideoRenderConfiguration,
        ffmpegPath: String,
        tempDirectory: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) throws -> (url: URL, recordedFrameCount: Int) {
        let fileManager = FileManager.default
        let fifoURL = tempDirectory.appending(path: "scene-raw.fifo")
        guard mkfifo(fifoURL.path, 0o600) == 0 else {
            throw SceneVideoRenderError.fifoCreationFailed(errno)
        }
        defer { try? fileManager.removeItem(at: fifoURL) }

        let intermediateOutputURL = tempDirectory.appending(path: "scene-render-raw.mp4")
        let stderrPipe = Pipe()
        let ffmpegProcess = makeProcess(
            URL(filePath: ffmpegPath),
            rawEncodeFfmpegArguments(
                fifoURL: fifoURL,
                size: configuration.size,
                fps: configuration.fps,
                outputURL: intermediateOutputURL
            ),
            stderrPipe
        )
        do {
            try processRegistry.launch(ffmpegProcess, assetID: configuration.assetId)
            // The child has duplicated its stderr descriptor. Close the
            // parent's write end so the final synchronous drain always sees
            // EOF, including for very short encodes whose readability callback
            // has not yet run.
            try? stderrPipe.fileHandleForWriting.close()
        } catch {
            try? stderrPipe.fileHandleForWriting.close()
            try? fileManager.removeItem(at: fifoURL)
            throw error
        }
        defer { processRegistry.unregister(ffmpegProcess, assetID: configuration.assetId) }

        let targetFrameCount = configuration.fps * configuration.seconds
        let progressMonitor = FfmpegStderrProgressMonitor(
            pipe: stderrPipe,
            targetFrameCount: targetFrameCount,
            handler: progressHandler ?? { _ in }
        )
        progressMonitor.start()

        let writerGuardFD: Int32
        do {
            writerGuardFD = try openFIFOWriterGuard(
                at: fifoURL,
                readerProcess: ffmpegProcess,
                timeout: min(10, rawPipeWatchdogTimeout(configuration))
            )
        } catch {
            _ = processRegistry.terminateAndWait(ffmpegProcess)
            _ = progressMonitor.stop()
            throw error
        }
        var writerGuardClosed = false
        func closeWriterGuard() {
            guard !writerGuardClosed else {
                return
            }
            close(writerGuardFD)
            writerGuardClosed = true
        }
        defer { closeWriterGuard() }

        let rendererProcess = makeProcess(
            configuration.rendererURL,
            rawRecordingArguments(fifoURL: fifoURL, configuration: configuration),
            nil
        )
        do {
            try processRegistry.launch(rendererProcess, assetID: configuration.assetId)
        } catch {
            closeWriterGuard()
            _ = processRegistry.terminateAndWait(ffmpegProcess)
            _ = progressMonitor.stop()
            throw error
        }
        defer { processRegistry.unregister(rendererProcess, assetID: configuration.assetId) }

        let watchdogState = RawPipeWatchdogState()
        let watchdogWorkItem = DispatchWorkItem {
            watchdogState.markFired()
            _ = processRegistry.terminateAndWait(rendererProcess)
            _ = processRegistry.terminateAndWait(ffmpegProcess)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + rawPipeWatchdogTimeout(configuration),
            execute: watchdogWorkItem
        )

        // The renderer's own exit status isn't a reliable success signal
        // (some builds crash during their own shutdown-time cleanup even
        // after successfully streaming every frame), so it's ignored here
        // just like the PNG-sequence pipeline's `runRendererProcess` ignores
        // it.
        rendererProcess.waitUntilExit()

        // The encoder was confirmed as a real reader before the renderer was
        // launched. Once the renderer has finished, release the guard so the
        // encoder sees EOF after the renderer's own writer closes.
        closeWriterGuard()

        ffmpegProcess.waitUntilExit()
        watchdogWorkItem.cancel()

        let recordedFrameCount = progressMonitor.stop()

        if watchdogState.hasFired {
            throw SceneVideoRenderError.rawPipeStalled
        }
        guard ffmpegProcess.terminationStatus == 0 else {
            throw SceneVideoRenderError.processFailed("ffmpeg", ffmpegProcess.terminationStatus)
        }
        guard recordedFrameCount > 0 else {
            throw SceneVideoRenderError.noFramesRecorded
        }
        progressHandler?(1.0)

        let temporaryOutputURL = tempDirectory.appending(path: "scene-render-output.mp4")
        try runProcess(
            URL(filePath: ffmpegPath),
            videoCrossfadeFfmpegArguments(
                videoURL: intermediateOutputURL,
                fps: configuration.fps,
                recordedFrameCount: recordedFrameCount,
                outputURL: temporaryOutputURL
            ),
            configuration.assetId
        )
        return (temporaryOutputURL, recordedFrameCount)
    }

    /// Waits until the ffmpeg child has opened the FIFO for reading, then
    /// returns a parent-owned writer that keeps that read end alive until the
    /// renderer starts. `O_NONBLOCK` is important: ENXIO means there is not
    /// yet a real reader, so it can be retried without hanging this process.
    private static func openFIFOWriterGuard(
        at fifoURL: URL,
        readerProcess: Process,
        timeout: TimeInterval
    ) throws -> Int32 {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(max(0.1, timeout))
        var observedRunning = readerProcess.isRunning
        while Date() < deadline {
            try Task.checkCancellation()
            let descriptor = open(fifoURL.path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 {
                guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else {
                    let closeOnExecErrno = errno
                    close(descriptor)
                    throw SceneVideoRenderError.fifoCreationFailed(closeOnExecErrno)
                }
                return descriptor
            }

            let openErrno = errno
            if openErrno != ENXIO && openErrno != EINTR {
                throw SceneVideoRenderError.fifoCreationFailed(openErrno)
            }

            // `Process.run()` can briefly report `isRunning == false` while
            // Foundation finishes publishing the launched state. Do not
            // mistake that handoff for an immediate child failure, but once
            // running has been observed (or the short launch grace expires),
            // fail promptly instead of consuming the full handshake timeout.
            if readerProcess.isRunning {
                observedRunning = true
            } else if observedRunning || Date().timeIntervalSince(startedAt) >= 0.25 {
                readerProcess.waitUntilExit()
                throw SceneVideoRenderError.processFailed("ffmpeg", readerProcess.terminationStatus)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try Task.checkCancellation()
        if !readerProcess.isRunning {
            readerProcess.waitUntilExit()
            throw SceneVideoRenderError.processFailed("ffmpeg", readerProcess.terminationStatus)
        }
        throw SceneVideoRenderError.rawPipeStalled
    }

    /// Runs the original serial pipeline: the renderer writes a PNG frame
    /// sequence to a temp directory (recording finishes before encoding
    /// starts), then ffmpeg encodes the sequence. Used when the renderer
    /// binary doesn't support `--record-raw` yet.
    private static func renderUsingPNGSequence(
        configuration: SceneVideoRenderConfiguration,
        ffmpegPath: String,
        tempDirectory: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) throws -> (url: URL, recordedFrameCount: Int) {
        let fileManager = FileManager.default
        let progressMonitor = progressHandler.map {
            SceneVideoRenderProgressMonitor(
                directory: tempDirectory,
                targetFrameCount: configuration.fps * configuration.seconds,
                handler: $0
            )
        }
        progressMonitor?.start()
        let rendererProcess = makeProcess(
            configuration.rendererURL,
            recordingArguments(recordDirectory: tempDirectory, configuration: configuration),
            nil
        )
        try processRegistry.launch(rendererProcess, assetID: configuration.assetId)
        rendererProcess.waitUntilExit()
        processRegistry.unregister(rendererProcess, assetID: configuration.assetId)
        progressMonitor?.stop()
        let recordedFrameCount = (try? fileManager.contentsOfDirectory(atPath: tempDirectory.path))?
            .filter { $0.hasPrefix("frame_") }
            .count ?? 0
        guard recordedFrameCount > 0 else {
            throw SceneVideoRenderError.noFramesRecorded
        }
        progressHandler?(1.0)

        let temporaryOutputURL = tempDirectory.appending(path: "scene-render-output.mp4")
        try runProcess(
            URL(filePath: ffmpegPath),
            ffmpegArguments(
                framesDirectory: tempDirectory,
                fps: configuration.fps,
                recordedFrameCount: recordedFrameCount,
                outputURL: temporaryOutputURL
            ),
            configuration.assetId
        )
        return (temporaryOutputURL, recordedFrameCount)
    }

    /// Runs the renderer to capture offscreen frames, encodes them with
    /// ffmpeg, and moves the result into the per-asset cache. Blocks the
    /// calling thread, so callers should invoke this off the main actor
    /// (e.g. from `Task.detached`).
    ///
    /// When the renderer binary supports `--record-raw` (probed via its
    /// `--help` output), rendering and encoding run concurrently through a
    /// FIFO instead of the renderer writing a complete PNG sequence before
    /// ffmpeg starts - the first-play render is significantly faster since
    /// encoding overlaps frame production instead of following it. Older
    /// renderer binaries without that flag fall back to the original
    /// serial PNG-sequence pipeline.
    ///
    /// `progressHandler`, when provided, is invoked periodically from a
    /// background queue (never the calling thread) with the fraction of the
    /// target frame count (`fps * seconds`) recorded so far, so callers can
    /// surface render progress to the user during the tens-of-seconds first
    /// render.
    static func render(
        configuration: SceneVideoRenderConfiguration,
        ffmpegPath: String,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appending(path: "wwb-scene-render-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let temporaryOutputURL: URL
        let recordedFrameCount: Int
        if supportsRecordRaw(rendererURL: configuration.rendererURL, assetID: configuration.assetId) {
            do {
                (temporaryOutputURL, recordedFrameCount) = try renderUsingRawPipe(
                    configuration: configuration,
                    ffmpegPath: ffmpegPath,
                    tempDirectory: tempDirectory,
                    progressHandler: progressHandler
                )
            } catch SceneVideoRenderError.rawPipeStalled {
                // The concurrent pipeline stalled past its watchdog timeout;
                // both processes were already killed, so fall back to the
                // original serial PNG-sequence pipeline rather than failing
                // the render outright.
                (temporaryOutputURL, recordedFrameCount) = try renderUsingPNGSequence(
                    configuration: configuration,
                    ffmpegPath: ffmpegPath,
                    tempDirectory: tempDirectory,
                    progressHandler: progressHandler
                )
            }
        } else {
            (temporaryOutputURL, recordedFrameCount) = try renderUsingPNGSequence(
                configuration: configuration,
                ffmpegPath: ffmpegPath,
                tempDirectory: tempDirectory,
                progressHandler: progressHandler
            )
        }

        // The video's own final (post-crossfade) loop duration, i.e. the
        // length of one seamless playthrough of `temporaryOutputURL`, so the
        // audio mux can decide how many times to repeat it to cover a longer
        // authored soundtrack (see `muxSceneAudioIfAvailable`).
        let crossfadeFrameCount = SceneVideoLoopCrossfade.frameCount(
            totalFrameCount: recordedFrameCount,
            fps: configuration.fps
        )
        let loopSeconds = crossfadeFrameCount > 0
            ? SceneVideoLoopCrossfade.outputSeconds(
                totalFrameCount: recordedFrameCount,
                crossfadeFrameCount: crossfadeFrameCount,
                fps: configuration.fps
            )
            : Double(recordedFrameCount) / Double(configuration.fps)

        let finalOutputURL = try configuration.sceneURL.map {
            try muxSceneAudioIfAvailable(
                sceneURL: $0,
                silentVideoURL: temporaryOutputURL,
                tempDirectory: tempDirectory,
                ffmpegPath: ffmpegPath,
                loopSeconds: loopSeconds,
                assetID: configuration.assetId
            )
        } ?? temporaryOutputURL

        try validateOutput(
            finalOutputURL,
            ffmpegPath: ffmpegPath,
            assetID: configuration.assetId
        )

        let cacheDirectory = SceneVideoCache.cacheDirectoryURL()
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let outputURL = configuration.cacheKey.map(SceneVideoCache.cachedVideoURL(key:))
            ?? SceneVideoCache.cachedVideoURL(assetId: configuration.assetId)
        let incomingURL = cacheDirectory.appending(
            path: ".\(outputURL.lastPathComponent).incoming-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: incomingURL) }
        try fileManager.moveItem(at: finalOutputURL, to: incomingURL)
        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: incomingURL)
        } else {
            try fileManager.moveItem(at: incomingURL, to: outputURL)
        }
        return outputURL
    }

    private static func validateOutput(_ url: URL, ffmpegPath: String, assetID: String) throws {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else {
            throw SceneVideoRenderError.invalidOutput
        }
        let ffprobeURL = URL(filePath: ffmpegPath)
            .deletingLastPathComponent()
            .appending(path: "ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobeURL.path) else {
            throw SceneVideoRenderError.ffprobeUnavailable
        }
        let capture = try captureProcessOutput(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=codec_type",
                "-of", "json",
                url.path
            ],
            assetID: assetID,
            timeout: 10
        )
        guard capture.status == 0,
              let object = try? JSONSerialization.jsonObject(with: capture.stdout) as? [String: Any],
              let streams = object["streams"] as? [[String: Any]],
              streams.contains(where: { $0["codec_type"] as? String == "video" }) else {
            throw SceneVideoRenderError.invalidOutput
        }
    }

    /// Records why the most recent render's audio mux step didn't produce a
    /// track with audio (either there was nothing to mux, or muxing failed).
    /// `nil` after a render that successfully baked audio in. Never causes
    /// the render itself to fail: any audio-extraction/mux problem falls back
    /// to the plain silent video.
    nonisolated(unsafe) static var lastAudioDiagnostic: String?

    /// Extracts the scene's authored sound layers (if any) from `sceneURL`
    /// and muxes them into `silentVideoURL` (a `loopSeconds`-long seamlessly
    /// looping clip). Falls back to returning `silentVideoURL` unchanged
    /// (silent) if the scene has no sound layers, or if anything about
    /// extraction/muxing fails - audio is a nice-to-have on top of the video
    /// render, never a reason to fail it.
    ///
    /// The video is stretched - by repeating its own seamless loop via
    /// `SceneVideoLoopExtension` - to match the longest authored track's
    /// duration (capped, see `SceneAudioMasterDuration`), so that track
    /// (typically background music) always plays through in full once per
    /// wallpaper loop instead of being cut off mid-phrase at the short,
    /// arbitrary video loop point. Every track (not just the longest) is then
    /// given its own exact, non-truncating repeat count (see
    /// `SceneAudioTrackLoop`) rather than singling out one "master" track to
    /// play once while the rest loop forever - a shorter authored track whose
    /// duration doesn't evenly divide the stretched total would otherwise
    /// still be cut off mid-phrase right at that boundary.
    private static func muxSceneAudioIfAvailable(
        sceneURL: URL,
        silentVideoURL: URL,
        tempDirectory: URL,
        ffmpegPath: String,
        loopSeconds: Double,
        assetID: String
    ) throws -> URL {
        lastAudioDiagnostic = nil
        do {
            let package = try ScenePackageReader().read(url: sceneURL)
            guard let sceneData = package.data(forPath: "scene.json"),
                  let scene = try JSONSerialization.jsonObject(with: sceneData) as? [String: Any] else {
                return silentVideoURL
            }
            let tracks = SceneAudioExtractor.audioTracks(scene: scene)
            guard !tracks.isEmpty else {
                return silentVideoURL
            }

            let audioDirectory = tempDirectory.appending(path: "scene-audio")
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            var writtenTracks: [(url: URL, weight: Double)] = []
            for (index, track) in tracks.enumerated() {
                guard let data = package.data(forPath: track.path) else {
                    continue
                }
                let fileExtension = URL(filePath: track.path).pathExtension
                let fileURL = audioDirectory.appending(path: "audio-\(index).\(fileExtension)")
                try data.write(to: fileURL)
                writtenTracks.append((url: fileURL, weight: track.volume))
            }
            guard !writtenTracks.isEmpty else {
                return silentVideoURL
            }

            let durations = try writtenTracks.map {
                try SceneAudioDurationProbe.durationSeconds(
                    ffmpegPath: ffmpegPath,
                    url: $0.url,
                    assetID: assetID
                )
            }
            // Every track's duration needs to be known to compute an exact,
            // non-truncating repeat count for it (see `SceneAudioTrackLoop`);
            // if even one probe fails, fall back entirely to the plain
            // single-pass loop (no stretching, every track loops forever)
            // rather than risk a partially-correct stretch.
            let allDurationsKnown = durations.allSatisfy { $0 != nil }
            let masterDurationSeconds = allDurationsKnown
                ? SceneAudioMasterDuration.masterDurationSeconds(trackDurationsSeconds: durations.compactMap { $0 })
                : nil

            let repeatCount: Int
            let totalDurationSeconds: Double
            if let masterDurationSeconds {
                repeatCount = SceneVideoLoopExtension.repeatCount(
                    loopSeconds: loopSeconds,
                    masterDurationSeconds: masterDurationSeconds
                )
                totalDurationSeconds = SceneVideoLoopExtension.totalSeconds(
                    loopSeconds: loopSeconds,
                    repeatCount: repeatCount
                )
            } else {
                repeatCount = 1
                totalDurationSeconds = loopSeconds
            }

            let extendedVideoURL: URL
            if repeatCount > 1 {
                extendedVideoURL = tempDirectory.appending(path: "scene-render-extended.mp4")
                try runProcess(
                    URL(filePath: ffmpegPath),
                    SceneVideoLoopExtension.ffmpegArguments(
                        loopableVideoURL: silentVideoURL,
                        repeatCount: repeatCount,
                        totalSeconds: totalDurationSeconds,
                        outputURL: extendedVideoURL
                    ),
                    assetID
                )
            } else {
                extendedVideoURL = silentVideoURL
            }

            let audioTracksWithLoopValue = writtenTracks.enumerated().map { index, track -> (url: URL, weight: Double, streamLoopValue: Int) in
                guard allDurationsKnown, let duration = durations[index] else {
                    // Shouldn't happen (guarded above), but loop forever
                    // rather than produce a broken/zero-length track.
                    return (track.url, track.weight, -1)
                }
                return (
                    track.url,
                    track.weight,
                    SceneAudioTrackLoop.streamLoopValue(
                        trackDurationSeconds: duration,
                        totalDurationSeconds: totalDurationSeconds
                    )
                )
            }

            let mixedOutputURL = tempDirectory.appending(path: "scene-render-with-audio.mp4")
            try runProcess(
                URL(filePath: ffmpegPath),
                SceneAudioMux.ffmpegArguments(
                    videoURL: extendedVideoURL,
                    audioTracks: audioTracksWithLoopValue,
                    outputURL: mixedOutputURL,
                    totalDurationSeconds: totalDurationSeconds
                ),
                assetID
            )
            return mixedOutputURL
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastAudioDiagnostic = "scene audio mux failed: \(error.localizedDescription)"
            return silentVideoURL
        }
    }

    /// Runs a short metadata/capability probe through the same cancellable
    /// process registry as full renders. Both pipes are drained concurrently
    /// with bounded memory, and a TERM-resistant child is force-killed and
    /// reaped before this method returns.
    static func captureProcessOutput(
        executableURL: URL,
        arguments: [String],
        assetID: String,
        timeout: TimeInterval
    ) throws -> SceneProcessCapture {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutReader = SceneBoundedPipeReader(handle: stdoutPipe.fileHandleForReading)
        let stderrReader = SceneBoundedPipeReader(handle: stderrPipe.fileHandleForReading)
        stdoutReader.start()
        stderrReader.start()

        func finishReaders() -> (Data, Data) {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            return (stdoutReader.finish(), stderrReader.finish())
        }

        do {
            try processRegistry.launch(process, assetID: assetID)
        } catch {
            _ = finishReaders()
            throw error
        }

        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while process.isRunning {
            if Task.isCancelled {
                _ = processRegistry.terminateAndWait(process)
                processRegistry.unregister(process, assetID: assetID)
                _ = finishReaders()
                throw CancellationError()
            }
            if Date() >= deadline {
                _ = processRegistry.terminateAndWait(process)
                processRegistry.unregister(process, assetID: assetID)
                _ = finishReaders()
                throw SceneVideoRenderError.processTimedOut(executableURL.lastPathComponent)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        processRegistry.unregister(process, assetID: assetID)
        let (stdout, stderr) = finishReaders()
        return SceneProcessCapture(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }

    private static func windowArgument(for size: CGSize) -> String {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        return "0x0x\(width)x\(height)"
    }
}

/// Pure fraction-of-target computation, factored out of the polling monitor
/// below so it can be unit tested without any concurrency or file-system
/// timing involved.
enum SceneVideoRenderProgress {
    static func fraction(recordedFrameCount: Int, targetFrameCount: Int) -> Double {
        guard targetFrameCount > 0 else {
            return 0
        }
        return min(1, max(0, Double(recordedFrameCount) / Double(targetFrameCount)))
    }
}

/// Parses ffmpeg's periodic `frame=  123 fps=... ` progress lines (written to
/// stderr, updated in place with carriage returns), factored out so the
/// regex-like extraction can be unit tested against sample lines without any
/// process or pipe involved.
enum FfmpegProgressParsing {
    static func frameCount(fromLine line: String) -> Int? {
        guard let range = line.range(of: "frame=") else {
            return nil
        }
        let afterFrame = line[range.upperBound...].drop { $0 == " " }
        let digits = afterFrame.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}

/// Watches an ffmpeg process's stderr pipe while it encodes, parsing the
/// `frame=` progress lines it periodically writes there to report render
/// progress and to recover the final encoded frame count once the process
/// exits (used as `recordedFrameCount` for the crossfade-loop pass in the
/// raw-pipe pipeline).
private final class FfmpegStderrProgressMonitor: @unchecked Sendable {
    private let pipe: Pipe
    private let targetFrameCount: Int
    private let handler: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var lastFrameCount = 0

    init(pipe: Pipe, targetFrameCount: Int, handler: @escaping @Sendable (Double) -> Void) {
        self.pipe = pipe
        self.targetFrameCount = targetFrameCount
        self.handler = handler
    }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            guard let self else {
                return
            }
            self.consume(fileHandle.availableData)
        }
    }

    /// Stops watching and returns the last frame count observed in a
    /// `frame=` line, which - once the encoder process has exited - is its
    /// final encoded frame count.
    func stop() -> Int {
        pipe.fileHandleForReading.readabilityHandler = nil
        // A short encode can exit before Dispatch delivers the readability
        // callback for ffmpeg's final carriage-return progress line. Drain
        // whatever remains after the process has closed its write end so the
        // final frame count does not depend on a run-loop scheduling race.
        consume(pipe.fileHandleForReading.readDataToEndOfFile())
        lock.lock()
        defer { lock.unlock() }
        return lastFrameCount
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return
        }
        var latestFrameCount: Int?
        for line in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            if let frameCount = FfmpegProgressParsing.frameCount(fromLine: String(line)) {
                latestFrameCount = frameCount
            }
        }
        guard let latestFrameCount else {
            return
        }
        lock.lock()
        lastFrameCount = max(lastFrameCount, latestFrameCount)
        lock.unlock()
        handler(SceneVideoRenderProgress.fraction(
            recordedFrameCount: latestFrameCount,
            targetFrameCount: targetFrameCount
        ))
    }
}

/// Polls the renderer's frame output directory on a background queue while
/// the (synchronous, blocking) renderer process runs, reporting progress as
/// `frames written / (fps * seconds)`. The renderer process itself has no
/// progress-reporting protocol of its own, so counting frame files on disk is
/// the only available signal.
private final class SceneVideoRenderProgressMonitor: @unchecked Sendable {
    private let directory: URL
    private let targetFrameCount: Int
    private let handler: @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "com.lamppkk.backgroundengine.scene-video-render-progress")
    private var timer: DispatchSourceTimer?

    init(directory: URL, targetFrameCount: Int, handler: @escaping @Sendable (Double) -> Void) {
        self.directory = directory
        self.targetFrameCount = targetFrameCount
        self.handler = handler
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [directory, targetFrameCount, handler] in
            let recordedFrameCount = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
                .filter { $0.hasPrefix("frame_") }
                .count ?? 0
            handler(SceneVideoRenderProgress.fraction(
                recordedFrameCount: recordedFrameCount,
                targetFrameCount: targetFrameCount
            ))
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

enum SceneVideoRenderError: Error, LocalizedError, Equatable {
    case processFailed(String, Int32)
    case processTimedOut(String)
    case noFramesRecorded
    case fifoCreationFailed(Int32)
    case rawPipeStalled
    case preflightTimedOut
    case ffprobeUnavailable
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .processFailed(let name, let status):
            return "\(name) exited with status \(status)."
        case .processTimedOut(let name):
            return "\(name) exceeded its time limit."
        case .noFramesRecorded:
            return "The scene renderer did not produce any recorded frames."
        case .fifoCreationFailed(let errnoValue):
            return "Could not create the recording FIFO (errno \(errnoValue))."
        case .rawPipeStalled:
            return "The concurrent scene render pipeline stalled and was aborted."
        case .preflightTimedOut:
            return "The Scene renderer preflight timed out."
        case .ffprobeUnavailable:
            return "The bundled ffprobe runtime is unavailable for Scene output validation."
        case .invalidOutput:
            return "The Scene renderer did not produce a valid video stream."
        }
    }
}

struct SceneProcessCapture: Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

private final class SceneBoundedPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let byteLimit: Int
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var data = Data()

    init(handle: FileHandle, byteLimit: Int = 1_048_576) {
        self.handle = handle
        self.byteLimit = byteLimit
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { finished.signal() }
            while true {
                let chunk: Data
                do {
                    guard let value = try handle.read(upToCount: 16_384), !value.isEmpty else {
                        return
                    }
                    chunk = value
                } catch {
                    return
                }
                lock.lock()
                let remaining = max(0, byteLimit - data.count)
                if remaining > 0 { data.append(chunk.prefix(remaining)) }
                lock.unlock()
            }
        }
    }

    func finish() -> Data {
        if finished.wait(timeout: .now() + 2) == .timedOut {
            try? handle.close()
            _ = finished.wait(timeout: .now() + 1)
        }
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class SceneRenderProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [String: [ObjectIdentifier: Process]] = [:]

    /// Registration and launch are one critical section. Cancellation also
    /// takes this lock before it snapshots active children, so it either sees
    /// an already-running process or the launch observes task cancellation;
    /// there is no unregistered child window.
    func launch(_ process: Process, assetID: String) throws {
        lock.lock()
        do {
            try Task.checkCancellation()
            processes[assetID, default: [:]][ObjectIdentifier(process)] = process
            try process.run()
            lock.unlock()
        } catch {
            processes[assetID]?[ObjectIdentifier(process)] = nil
            if processes[assetID]?.isEmpty == true { processes[assetID] = nil }
            lock.unlock()
            if process.isRunning { _ = terminateAndWait(process) }
            throw error
        }
    }

    func unregister(_ process: Process, assetID: String) {
        lock.lock()
        processes[assetID]?[ObjectIdentifier(process)] = nil
        if processes[assetID]?.isEmpty == true { processes[assetID] = nil }
        lock.unlock()
    }

    func cancel(assetID: String) {
        snapshot(assetID: assetID).forEach(terminate)
    }

    func cancelAll() {
        lock.lock()
        let active = processes.values.flatMap(\.values)
        lock.unlock()
        active.forEach(terminate)
    }

    @discardableResult
    func terminateAndWait(_ process: Process, gracePeriod: TimeInterval = 0.5) -> Bool {
        guard process.isRunning else {
            process.waitUntilExit()
            return true
        }
        process.terminate()
        if !waitForExit(process, timeout: gracePeriod), process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = waitForExit(process, timeout: 2)
        }
        let exited = !process.isRunning
        if exited { process.waitUntilExit() }
        return exited
    }

    private func terminate(_ process: Process) {
        _ = terminateAndWait(process)
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }

    private func snapshot(assetID: String) -> [Process] {
        lock.lock()
        defer { lock.unlock() }
        return processes[assetID].map { Array($0.values) } ?? []
    }
}

/// Thread-safe latch set by the raw-pipe pipeline's watchdog timer when it
/// kills both child processes after the pipeline runs longer than
/// `SceneVideoRenderer.rawPipeWatchdogTimeout` allows, so the code that
/// awaited the (now-terminated) processes can tell a genuine stall apart
/// from normal completion or a real process failure.
private final class RawPipeWatchdogState: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func markFired() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    var hasFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}
