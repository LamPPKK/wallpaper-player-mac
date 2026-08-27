import Foundation
import CryptoKit
@_spi(FFmpegRecovery) import BackgroundEngineCore
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
    // The selected PKGV package. Besides extracting authored sound layers,
    // this is passed explicitly to the bundled renderer so packages renamed
    // by Workshop authors (or stored without a .pkg extension) are mounted
    // instead of silently falling back to projectDirectory/scene.pkg.
    // Optional so synthetic video-pipeline tests can remain package-free.
    let sceneURL: URL?
    let contentHash: String?
    let quality: RenderQuality
    let mediaBuildID: String
    let engineAssetsFingerprint: String
    /// Registry key used only to own/cancel child processes. Coordinated
    /// renders replace the default asset-wide value with their complete
    /// cache job key so one display timeout cannot kill another display's
    /// independent render of the same Scene.
    let processScopeID: String

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
        engineAssetsFingerprint: String = "unfingerprinted",
        processScopeID: String? = nil
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
        self.processScopeID = processScopeID ?? assetId
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
            engineAssetsFingerprint: engineAssetsFingerprint,
            processScopeID: processScopeID
        )
    }

    func scopedForProcesses(_ scopeID: String) -> SceneVideoRenderConfiguration {
        SceneVideoRenderConfiguration(
            assetId: assetId,
            projectDirectory: projectDirectory,
            assetsDirectory: assetsDirectory,
            rendererURL: rendererURL,
            size: size,
            fps: fps,
            seconds: seconds,
            sceneURL: sceneURL,
            contentHash: contentHash,
            quality: quality,
            mediaBuildID: mediaBuildID,
            engineAssetsFingerprint: engineAssetsFingerprint,
            processScopeID: scopeID
        )
    }
}

enum SceneRenderAudioState: String, Codable, Equatable, Sendable {
    case notRequired
    case included
    case degraded
}

/// Per-render authored-audio result. This travels with the cache URL instead
/// of using process-global mutable diagnostic state, so concurrent displays
/// and deduplicated render callers always observe the result for their own
/// Scene job.
struct SceneRenderAudioResult: Codable, Equatable, Sendable {
    let state: SceneRenderAudioState
    let diagnosticCode: String?
    let warning: String?

    static let notRequired = SceneRenderAudioResult(
        state: .notRequired,
        diagnosticCode: nil,
        warning: nil
    )
    static let included = SceneRenderAudioResult(
        state: .included,
        diagnosticCode: nil,
        warning: nil
    )

    static func degraded(_ warning: String) -> SceneRenderAudioResult {
        SceneRenderAudioResult(
            state: .degraded,
            diagnosticCode: "scene_authored_audio_unavailable",
            warning: warning
        )
    }
}

struct SceneVideoRenderOutcome: Equatable, Sendable {
    let cacheURL: URL
    let audioResult: SceneRenderAudioResult
}

struct SceneAudioMuxResult: Equatable, Sendable {
    let outputURL: URL
    let audioResult: SceneRenderAudioResult
}

struct SceneAudioExtractionBudget: Sendable {
    let maximumEntryBytes: UInt64
    private(set) var remainingBytes: UInt64

    init(maximumEntryBytes: UInt64, aggregateBytes: UInt64) {
        self.maximumEntryBytes = maximumEntryBytes
        remainingBytes = aggregateBytes
    }

    mutating func reserve(_ bytes: UInt64) -> Bool {
        guard bytes <= maximumEntryBytes, bytes <= remainingBytes else {
            return false
        }
        remainingBytes -= bytes
        return true
    }
}

struct SceneVideoCacheMetadata: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let audioResult: SceneRenderAudioResult
    let videoFileSize: UInt64
    let videoSHA256: String

    init(
        schemaVersion: Int = SceneVideoCacheMetadata.currentSchemaVersion,
        audioResult: SceneRenderAudioResult,
        videoFileSize: UInt64,
        videoSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.audioResult = audioResult
        self.videoFileSize = videoFileSize
        self.videoSHA256 = videoSHA256
    }
}

private struct SceneVideoCacheFingerprint: Equatable {
    let fileSize: UInt64
    let sha256: String
}

private enum SceneVideoCacheMetadataError: Error {
    case invalidFile
}

/// Coalesces full-file SHA verification for displays that open the same
/// immutable Scene cache generation together. The hashing task is detached
/// from the main actor; completed values are not retained indefinitely, so a
/// legacy mutable pathname is never trusted from an old in-memory result.
actor SceneVideoCacheMetadataVerifier {
    typealias VerificationOperation = @Sendable (URL) -> SceneVideoCacheMetadata?

    static let shared = SceneVideoCacheMetadataVerifier()

    private let operation: VerificationOperation
    private var tasks: [URL: Task<SceneVideoCacheMetadata?, Never>] = [:]

    init(operation: @escaping VerificationOperation = { SceneVideoCache.metadata(for: $0) }) {
        self.operation = operation
    }

    func metadata(for videoURL: URL) async -> SceneVideoCacheMetadata? {
        let canonicalURL = videoURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .appending(path: videoURL.lastPathComponent)
        if let existing = tasks[canonicalURL] {
            return await existing.value
        }
        let operation = operation
        let task = Task.detached(priority: .utility) {
            operation(canonicalURL)
        }
        tasks[canonicalURL] = task
        let result = await task.value
        tasks[canonicalURL] = nil
        return result
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
        SceneVideoCacheFileName.fileName(for: self)
    }
}

/// A bounded, domain-separated file-name representation of a Scene cache
/// key. Raw identifiers are deliberately never used as path components:
/// replacing unsafe characters is not injective (`a/b` and `a?b` collapse),
/// leading dots create hidden files, and a long Workshop title can exceed
/// `NAME_MAX` once the immutable-generation suffix is appended.
///
/// The two full SHA-256 values keep broad asset/revision discovery possible
/// without a variable-length prefix. The resulting logical name is always
/// 141 ASCII bytes, leaving ample room for the generation, metadata, and
/// incoming-file suffixes used by `SceneVideoCache.install`.
private enum SceneVideoCacheFileName {
    private static let prefix = "scene-p"
    private static let keyMarker = "-k"
    static let digestHexCount = 64

    static func fileName(for key: SceneVideoCacheKey) -> String {
        let keyDigest = digest(
            domain: "background-engine.scene-video-cache.key.v1",
            components: [
                key.assetID,
                key.contentHash,
                key.rendererVersion,
                key.mediaBuildID,
                key.engineAssetsFingerprint,
                String(key.width),
                String(key.height),
                key.quality.rawValue
            ]
        )
        return discoveryPrefix(assetID: key.assetID, contentHash: key.contentHash)
            + keyDigest
            + ".mp4"
    }

    static func discoveryPrefix(assetID: String, contentHash: String) -> String {
        let revisionDigest = digest(
            domain: "background-engine.scene-video-cache.asset-revision.v1",
            components: [assetID, contentHash]
        )
        return prefix + revisionDigest + keyMarker
    }

    private static func digest(domain: String, components: [String]) -> String {
        var hasher = SHA256()
        append(domain, to: &hasher)
        for component in components {
            append(component, to: &hasher)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Length-prefixing makes the hashed serialization unambiguous; without
    /// it, components ["ab", "c"] and ["a", "bc"] would have the same byte
    /// stream before hashing.
    private static func append(_ value: String, to hasher: inout SHA256) {
        let data = Data(value.utf8)
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            hasher.update(data: Data(bytes))
        }
        hasher.update(data: data)
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

    /// Uses the Scene canvas aspect ratio while capping resolution according
    /// to the assigned display. The rendered cache then retains the complete
    /// canvas; the per-display video/overlay layout can safely apply Fit,
    /// Fill, or Stretch without a crop already being baked into the video.
    static func clampedRecordSize(
        forSceneCanvas sceneCanvas: CGSize?,
        displayLogicalSize: CGSize,
        maxLongEdge: CGFloat = defaultMaxLongEdge
    ) -> CGSize {
        guard let sceneCanvas,
              sceneCanvas.width.isFinite,
              sceneCanvas.height.isFinite,
              sceneCanvas.width > 0,
              sceneCanvas.height > 0,
              displayLogicalSize.width.isFinite,
              displayLogicalSize.height.isFinite,
              displayLogicalSize.width > 0,
              displayLogicalSize.height > 0 else {
            return clampedRecordSize(forLogicalSize: displayLogicalSize, maxLongEdge: maxLongEdge)
        }
        let displayLongEdge = max(displayLogicalSize.width, displayLogicalSize.height)
        let targetLongEdge = min(displayLongEdge, maxLongEdge)
        let canvasLongEdge = max(sceneCanvas.width, sceneCanvas.height)
        let scale = targetLongEdge / canvasLongEdge
        return evenSize(CGSize(width: sceneCanvas.width * scale, height: sceneCanvas.height * scale))
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
    static let rendererVersion = "7acc6c9-be4"
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
    /// into the cached mp4 (see
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
    /// etc.) repeat underneath it when their playback mode is `loop`.
    ///
    /// v9: the selected PKGV path is mounted explicitly, allowing valid
    /// renamed or extensionless Scene packages to reach the renderer.
    ///
    /// v10: scripted text is excluded only when every scripted text layer is
    /// a clock that Background Engine can reproduce as a native overlay.
    /// Other scripts stay baked into the cache instead of disappearing.
    ///
    /// v11: cache frames preserve the Scene canvas aspect ratio so each
    /// display can apply its own Fit, Fill, or Stretch mode after rendering.
    ///
    /// v12: the bundled renderer resolves Wallpaper Engine system-font text
    /// through CoreText on macOS instead of silently dropping those layers.
    ///
    /// v13: every rendered cache records an authored-audio result in a
    /// sidecar bound to the exact MP4 bytes. Older caches could silently lose
    /// a required sound layer while still being classified Full Cached, so
    /// they must be regenerated. Content-addressed filenames also move to a
    /// bounded SHA-256 representation; v12 caches remain isolated in their
    /// previous version directory instead of being matched by unsafe legacy
    /// prefixes.
    ///
    /// v14: incomplete renderer output is rejected before crossfade and
    /// cache installation. Older versions could install a valid-looking MP4
    /// made from only the first few frames after a renderer crash.
    ///
    /// v15: authored sound layers with valid string metadata honor
    /// `playbackmode`: only exact lowercase `loop` repeats. Non-string modes
    /// are rejected as degraded metadata rather than guessed. Older caches
    /// may contain incorrectly repeated or guessed audio and must be regenerated.
    static let cacheVersion = 15

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
        cacheDirectoryURL().appending(path: "\(safeLegacyAssetComponent(assetId)).mp4")
    }

    static func cachedVideoURL(key: SceneVideoCacheKey) -> URL {
        cacheDirectoryURL().appending(path: key.fileName)
    }

    static func metadataURL(for videoURL: URL) -> URL {
        videoURL.appendingPathExtension("metadata.json")
    }

    static func metadata(for videoURL: URL) -> SceneVideoCacheMetadata? {
        guard let data = try? boundedRegularFileData(
            at: metadataURL(for: videoURL),
            maximumByteCount: 64 * 1_024
        ),
              let metadata = try? JSONDecoder().decode(SceneVideoCacheMetadata.self, from: data),
              metadata.schemaVersion == SceneVideoCacheMetadata.currentSchemaVersion,
              let fingerprint = try? fingerprint(for: videoURL),
              metadata.videoFileSize == fingerprint.fileSize,
              metadata.videoSHA256 == fingerprint.sha256 else {
            return nil
        }
        return metadata
    }

    static func encodedMetadata(
        audioResult: SceneRenderAudioResult,
        videoURL: URL
    ) throws -> Data {
        let fingerprint = try fingerprint(for: videoURL)
        return try encodedMetadata(audioResult: audioResult, fingerprint: fingerprint)
    }

    private static func encodedMetadata(
        audioResult: SceneRenderAudioResult,
        fingerprint: SceneVideoCacheFingerprint
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            SceneVideoCacheMetadata(
                audioResult: audioResult,
                videoFileSize: fingerprint.fileSize,
                videoSHA256: fingerprint.sha256
            )
        )
    }

    /// Publishes the MP4 under a unique immutable generation name. Metadata
    /// is moved into place first while no discoverable MP4 exists; publishing
    /// the video is then the single atomic visibility point. Existing cache
    /// generations are never renamed or overwritten, so a URL whose sidecar
    /// was verified cannot change to different bytes before AVPlayer opens it.
    static func install(
        videoAt sourceVideoURL: URL,
        audioResult: SceneRenderAudioResult,
        at logicalOutputURL: URL,
        cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> URL {
        try cancellationCheck()
        let fileManager = FileManager.default
        let cacheDirectory = logicalOutputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let expectedCacheDirectory = cacheDirectoryURL().standardizedFileURL.resolvingSymlinksInPath()
        guard cacheDirectory.standardizedFileURL.resolvingSymlinksInPath() == expectedCacheDirectory else {
            throw SceneVideoCacheMetadataError.invalidFile
        }

        let fingerprint = try fingerprint(
            for: sourceVideoURL,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        let nonce = UUID().uuidString
        let stem = logicalOutputURL.deletingPathExtension().lastPathComponent
        let generationURL = cacheDirectory.appending(
            path: "\(stem)-g\(fingerprint.sha256.prefix(16))-\(nonce).mp4"
        )
        let generationMetadataURL = metadataURL(for: generationURL)
        let incomingVideoURL = cacheDirectory.appending(
            path: ".\(generationURL.lastPathComponent).incoming"
        )
        let incomingMetadataURL = cacheDirectory.appending(
            path: ".\(generationMetadataURL.lastPathComponent).incoming"
        )

        defer {
            try? fileManager.removeItem(at: incomingVideoURL)
            try? fileManager.removeItem(at: incomingMetadataURL)
        }
        do {
            let metadataData = try encodedMetadata(
                audioResult: audioResult,
                fingerprint: fingerprint
            )
            try metadataData.write(to: incomingMetadataURL, options: .atomic)
            try cancellationCheck()
            try fileManager.moveItem(at: sourceVideoURL, to: incomingVideoURL)
            try cancellationCheck()
            try fileManager.moveItem(at: incomingMetadataURL, to: generationMetadataURL)
            // The MP4 move below is the atomic visibility point. A cancelled
            // render must not publish a generation merely because its child
            // processes have already exited.
            try cancellationCheck()
            try fileManager.moveItem(at: incomingVideoURL, to: generationURL)
            // The successful rename is the irrevocable commit point. Do not
            // inspect cancellation after it: another display may already
            // have discovered this immutable generation.
            return generationURL
        } catch {
            try? fileManager.removeItem(at: generationURL)
            try? fileManager.removeItem(at: generationMetadataURL)
            throw error
        }
    }

    private static func fingerprint(
        for videoURL: URL,
        cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> SceneVideoCacheFingerprint {
        try cancellationCheck()
        var pathInfo = stat()
        guard lstat(videoURL.path, &pathInfo) == 0,
              pathInfo.st_mode & S_IFMT == S_IFREG else {
            throw SceneVideoCacheMetadataError.invalidFile
        }
        let descriptor = Darwin.open(videoURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SceneVideoCacheMetadataError.invalidFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var openedInfo = stat()
        guard Darwin.fstat(descriptor, &openedInfo) == 0,
              openedInfo.st_mode & S_IFMT == S_IFREG,
              openedInfo.st_dev == pathInfo.st_dev,
              openedInfo.st_ino == pathInfo.st_ino,
              openedInfo.st_size > 0 else {
            throw SceneVideoCacheMetadataError.invalidFile
        }

        var digest = SHA256()
        while true {
            try cancellationCheck()
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else {
                break
            }
            digest.update(data: chunk)
        }
        try cancellationCheck()
        var finalInfo = stat()
        var finalPathInfo = stat()
        guard Darwin.fstat(descriptor, &finalInfo) == 0,
              finalInfo.st_dev == openedInfo.st_dev,
              finalInfo.st_ino == openedInfo.st_ino,
              finalInfo.st_size == openedInfo.st_size,
              lstat(videoURL.path, &finalPathInfo) == 0,
              finalPathInfo.st_mode & S_IFMT == S_IFREG,
              finalPathInfo.st_dev == finalInfo.st_dev,
              finalPathInfo.st_ino == finalInfo.st_ino else {
            throw SceneVideoCacheMetadataError.invalidFile
        }
        return SceneVideoCacheFingerprint(
            fileSize: UInt64(finalInfo.st_size),
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func boundedRegularFileData(
        at url: URL,
        maximumByteCount: Int
    ) throws -> Data {
        var pathInfo = stat()
        guard lstat(url.path, &pathInfo) == 0,
              pathInfo.st_mode & S_IFMT == S_IFREG,
              pathInfo.st_size >= 0,
              pathInfo.st_size <= maximumByteCount else {
            throw SceneVideoCacheMetadataError.invalidFile
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SceneVideoCacheMetadataError.invalidFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var openedInfo = stat()
        guard Darwin.fstat(descriptor, &openedInfo) == 0,
              openedInfo.st_mode & S_IFMT == S_IFREG,
              openedInfo.st_dev == pathInfo.st_dev,
              openedInfo.st_ino == pathInfo.st_ino,
              openedInfo.st_size >= 0,
              openedInfo.st_size <= maximumByteCount else {
            throw SceneVideoCacheMetadataError.invalidFile
        }
        var data = Data()
        while data.count <= maximumByteCount,
              let chunk = try handle.read(
                upToCount: min(4_096, maximumByteCount + 1 - data.count)
              ),
              !chunk.isEmpty {
            data.append(chunk)
        }
        var finalInfo = stat()
        guard data.count <= maximumByteCount,
              Darwin.fstat(descriptor, &finalInfo) == 0,
              finalInfo.st_dev == openedInfo.st_dev,
              finalInfo.st_ino == openedInfo.st_ino,
              finalInfo.st_size == openedInfo.st_size else {
            throw SceneVideoCacheMetadataError.invalidFile
        }
        return data
    }

    /// A cache entry is fresh when it exists and was written on or after the
    /// scene package it was rendered from was last modified. Modification
    /// dates are read via `FileManager` rather than `URL.resourceValues`
    /// because the latter caches values per `URL` instance, which would
    /// return stale results after the source file is touched again.
    static func isFresh(cacheURL: URL, sourceURL: URL) -> Bool {
        let fileManager = FileManager.default
        guard isRegularFileWithoutFollowingSymlinks(cacheURL),
              let cacheModified = modificationDate(of: cacheURL, fileManager: fileManager),
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

    private static func isRegularFileWithoutFollowingSymlinks(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    private static func safeLegacyAssetComponent(_ assetID: String) -> String {
        let sanitized = assetID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        if sanitized == assetID,
           sanitized != ".",
           sanitized != "..",
           !sanitized.hasPrefix("."),
           !sanitized.isEmpty,
           sanitized.utf8.count <= 96 {
            return sanitized
        }
        let readable = String(sanitized.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let digest = SHA256.hash(data: Data(assetID.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(readable.isEmpty ? "asset" : readable)-\(digest)"
    }

    static func freshCachedVideoURL(assetId: String, sourceURL: URL) -> URL? {
        newestFreshVideo(
            logicalURL: cachedVideoURL(assetId: assetId),
            sourceURL: sourceURL
        )
    }

    static func freshCachedVideoURL(key: SceneVideoCacheKey, sourceURL: URL) -> URL? {
        newestFreshVideo(logicalURL: cachedVideoURL(key: key), sourceURL: sourceURL)
    }

    private static func newestFreshVideo(logicalURL: URL, sourceURL: URL) -> URL? {
        let fileManager = FileManager.default
        var candidates = (try? fileManager.contentsOfDirectory(
            at: logicalURL.deletingLastPathComponent(),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        candidates = candidates.filter { candidate in
            candidate.pathExtension.lowercased() == "mp4"
                && isLogicalOrGenerationCandidate(candidate, for: logicalURL)
                && isFresh(cacheURL: candidate, sourceURL: sourceURL)
        }
        return candidates.max { lhs, rhs in
            let leftDate = modificationDate(of: lhs, fileManager: fileManager) ?? .distantPast
            let rightDate = modificationDate(of: rhs, fileManager: fileManager) ?? .distantPast
            if leftDate == rightDate {
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            return leftDate < rightDate
        }
    }

    static func freshPlaybackCacheURL(
        preferredKeys: [SceneVideoCacheKey],
        assetID: String,
        contentHash: String?,
        sourceURL: URL
    ) -> URL? {
        for key in preferredKeys {
            if let url = freshCachedVideoURL(key: key, sourceURL: sourceURL) {
                return url
            }
        }
        // The ID-only filename predates content-addressed cache keys. It is
        // safe only for legacy manifests that do not have a content hash;
        // otherwise a Workshop update can inherit a fresh-looking render of
        // the previous revision when copied files preserve their timestamps.
        guard contentHash == nil else {
            return nil
        }
        return freshCachedVideoURL(assetId: assetID, sourceURL: sourceURL)
    }

    static func isCurrentPlaybackCacheURL(
        _ cacheURL: URL,
        preferredKeys: [SceneVideoCacheKey],
        assetID: String,
        contentHash: String?,
        sourceURL: URL
    ) -> Bool {
        guard let current = freshPlaybackCacheURL(
            preferredKeys: preferredKeys,
            assetID: assetID,
            contentHash: contentHash,
            sourceURL: sourceURL
        ) else {
            return false
        }
        return current.standardizedFileURL.resolvingSymlinksInPath().path
            == cacheURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func freshCachedVideoURL(assetID: String, contentHash: String?, sourceURL: URL) -> URL? {
        guard let contentHash else {
            return freshCachedVideoURL(assetId: assetID, sourceURL: sourceURL)
        }
        let prefix = SceneVideoCacheFileName.discoveryPrefix(
            assetID: assetID,
            contentHash: contentHash
        )
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectoryURL(),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return candidates.filter { url in
            url.pathExtension.lowercased() == "mp4"
                && isContentAddressedCandidate(url, discoveryPrefix: prefix)
                && isFresh(cacheURL: url, sourceURL: sourceURL)
        }.max { lhs, rhs in
            let leftDate = modificationDate(of: lhs, fileManager: .default) ?? .distantPast
            let rightDate = modificationDate(of: rhs, fileManager: .default) ?? .distantPast
            if leftDate == rightDate {
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            return leftDate < rightDate
        }
    }

    private static func isLogicalOrGenerationCandidate(
        _ candidateURL: URL,
        for logicalURL: URL
    ) -> Bool {
        if candidateURL.lastPathComponent == logicalURL.lastPathComponent {
            return true
        }
        let logicalStem = logicalURL.deletingPathExtension().lastPathComponent
        let candidateStem = candidateURL.deletingPathExtension().lastPathComponent
        guard candidateStem.hasPrefix(logicalStem) else {
            return false
        }
        return isValidGenerationSuffix(candidateStem.dropFirst(logicalStem.count))
    }

    /// Validates the complete content-addressed grammar rather than accepting
    /// an arbitrary filename that happens to share a sanitized prefix.
    private static func isContentAddressedCandidate(
        _ candidateURL: URL,
        discoveryPrefix: String
    ) -> Bool {
        let stem = candidateURL.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix(discoveryPrefix) else {
            return false
        }
        let remainder = Array(stem.dropFirst(discoveryPrefix.count).utf8)
        guard remainder.count >= SceneVideoCacheFileName.digestHexCount,
              remainder.prefix(SceneVideoCacheFileName.digestHexCount)
                .allSatisfy(isLowercaseHexByte) else {
            return false
        }
        return isValidGenerationSuffix(
            Array(remainder.dropFirst(SceneVideoCacheFileName.digestHexCount))
        )
    }

    /// Empty means the logical filename. An immutable generation is exactly
    /// `-g<16 lowercase SHA hex>-<UUID>`; extra text and prefix collisions are
    /// rejected.
    private static func isValidGenerationSuffix(_ suffix: Substring) -> Bool {
        isValidGenerationSuffix(Array(suffix.utf8))
    }

    private static func isValidGenerationSuffix(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else {
            return true
        }
        let fingerprintHexCount = 16
        let uuidByteCount = 36
        guard bytes.count == 2 + fingerprintHexCount + 1 + uuidByteCount,
              bytes[0] == 45,
              bytes[1] == 103,
              bytes[2..<(2 + fingerprintHexCount)].allSatisfy(isLowercaseHexByte),
              bytes[2 + fingerprintHexCount] == 45 else {
            return false
        }
        let uuidBytes = bytes[(3 + fingerprintHexCount)...]
        guard let uuidString = String(bytes: uuidBytes, encoding: .utf8) else {
            return false
        }
        return UUID(uuidString: uuidString) != nil
    }

    private static func isLowercaseHexByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
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
    /// Wallpaper Engine repeats a sound only when a valid string playback
    /// mode is explicitly `loop`; missing and other valid strings are
    /// one-shot. Invalid non-string metadata is excluded before this model.
    let loops: Bool

    init(path: String, volume: Double, loops: Bool = false) {
        self.path = path
        self.volume = volume
        self.loops = loops
    }
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
            guard isVisible(object["visible"]),
                  let soundPaths = object["sound"] as? [Any] else {
                continue
            }
            if let playbackMode = object["playbackmode"],
               !(playbackMode is NSNull),
               !(playbackMode is String) {
                continue
            }
            let volume = volumeValue(object["volume"]) ?? 1.0
            // Match the bundled renderer exactly: ObjectParser reads a plain
            // string and CSound repeats only when it equals lowercase `loop`.
            let loops = object["playbackmode"] as? String == "loop"
            for case let path as String in soundPaths {
                tracks.append(SceneAudioTrack(path: path, volume: volume, loops: loops))
            }
        }
        return tracks
    }

    static func declaresVisibleSoundLayer(scene: [String: Any]) -> Bool {
        let objects = scene["objects"] as? [[String: Any]] ?? []
        return objects.contains {
            isVisible($0["visible"]) && $0["sound"] != nil
        }
    }

    static func hasInvalidVisiblePlaybackMode(scene: [String: Any]) -> Bool {
        let objects = scene["objects"] as? [[String: Any]] ?? []
        return objects.contains { object in
            guard isVisible(object["visible"]),
                  object["sound"] != nil,
                  let playbackMode = object["playbackmode"],
                  !(playbackMode is NSNull) else {
                return false
            }
            return !(playbackMode is String)
        }
    }

    private static func isVisible(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        guard let dictionary = value as? [String: Any] else {
            return true
        }
        return dictionary["value"] as? Bool ?? true
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
/// `-stream_loop` value). One-shot tracks always return zero; loop tracks fit
/// some whole number of complete playthroughs inside `totalDurationSeconds`
/// without ever being cut off
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
    static func streamLoopValue(
        trackDurationSeconds: Double,
        totalDurationSeconds: Double,
        loops: Bool
    ) -> Int {
        guard loops else {
            return 0
        }
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
    /// Authored sound is optional enrichment for a rendered Scene cache. A
    /// package entry can be close to UInt32.max even though the package is
    /// memory-mapped, so never materialize an unbounded sound payload merely
    /// to hand it to FFmpeg. Four minutes of ordinary lossless audio remains
    /// well below the per-track ceiling.
    static let maximumAuthoredAudioEntryBytes: UInt64 = 128 * 1_024 * 1_024
    static let maximumAuthoredAudioAggregateBytes: UInt64 = 512 * 1_024 * 1_024

    private static let processRegistry = SceneRenderProcessRegistry()

    static func cancelActiveProcesses(scopeID: String) {
        processRegistry.cancel(scopeID: scopeID)
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
        timeout: TimeInterval = 15,
        didLaunch: ((Int32) -> Void)? = nil
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
            sceneURL: configuration.sceneURL,
            contentHash: nil,
            quality: .low,
            mediaBuildID: configuration.mediaBuildID,
            engineAssetsFingerprint: configuration.engineAssetsFingerprint,
            processScopeID: configuration.processScopeID
        )
        let process = Process()
        process.executableURL = configuration.rendererURL
        process.arguments = recordingArguments(recordDirectory: directory, configuration: probe)
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try processRegistry.launch(process, scopeID: configuration.processScopeID)
            didLaunch?(process.processIdentifier)
            if Task.isCancelled {
                _ = processRegistry.terminateAndWait(process)
                throw CancellationError()
            }
        } catch {
            if !process.isRunning {
                processRegistry.unregister(process, scopeID: configuration.processScopeID)
            }
            throw error
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            _ = processRegistry.terminateAndWait(process)
            if !process.isRunning {
                processRegistry.unregister(process, scopeID: configuration.processScopeID)
            }
            throw SceneVideoRenderError.preflightTimedOut
        }
        processRegistry.unregister(process, scopeID: configuration.processScopeID)
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw SceneVideoRenderError.processFailed(
                configuration.rendererURL.lastPathComponent,
                process.terminationStatus
            )
        }
        let frameNames = try fileManager.contentsOfDirectory(atPath: directory.path)
        let frameCount = try SceneRecordedFrameSequence.contiguousPNGFrameCount(
            fileNames: frameNames
        )
        guard frameCount > 0 else { throw SceneVideoRenderError.noFramesRecorded }
    }

    /// Injectable so tests can capture the ffmpeg invocation instead of
    /// actually spawning a process. Rendering runs off the main actor (see
    /// `render(configuration:ffmpegPath:)`), so this is intentionally not
    /// actor-isolated.
    nonisolated(unsafe) static var runProcess: (URL, [String], String) throws -> Void = {
        executableURL, arguments, assetID in
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardError = stderrPipe
        let stderrReader = SceneBoundedPipeReader(handle: stderrPipe.fileHandleForReading)
        stderrReader.start()
        do {
            try processRegistry.launch(process, scopeID: assetID)
            // The child owns its duplicated descriptor after launch. Closing
            // the parent's copy lets the bounded reader observe EOF as soon
            // as the child exits, including on encoder initialization errors.
            try? stderrPipe.fileHandleForWriting.close()
            if Task.isCancelled {
                _ = processRegistry.terminateAndWait(process)
                throw CancellationError()
            }
        } catch {
            try? stderrPipe.fileHandleForWriting.close()
            _ = stderrReader.finish()
            if !process.isRunning { processRegistry.unregister(process, scopeID: assetID) }
            throw error
        }
        process.waitUntilExit()
        processRegistry.unregister(process, scopeID: assetID)
        let stderr = String(decoding: stderrReader.finish(), as: UTF8.self)
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw SceneProcessFailure(
                name: executableURL.lastPathComponent,
                status: process.terminationStatus,
                stderr: stderr
            )
        }
    }

    /// Runs one H.264 VideoToolbox encode, then retries the same operation at
    /// most once with FFmpeg's native MPEG-4 Part 2 encoder when stderr proves
    /// that VideoToolbox itself failed. Cancellation, timeouts, renderer
    /// failures, and arbitrary FFmpeg errors are never converted into a
    /// software retry.
    static func withVideoEncoderFallback<Output>(
        _ operation: (FFmpegVideoEncoder) throws -> Output
    ) throws -> Output {
        do {
            return try operation(.videoToolboxH264)
        } catch is CancellationError {
            throw CancellationError()
        } catch let primaryFailure as SceneProcessFailure {
            guard FFmpegVideoEncoder.shouldUseSoftwareFallback(stderr: primaryFailure.stderr) else {
                throw primaryFailure
            }
            try Task.checkCancellation()
            do {
                return try operation(.softwareMPEG4)
            } catch is CancellationError {
                throw CancellationError()
            } catch SceneVideoRenderError.rawPipeStalled {
                // Preserve the established raw-pipe -> PNG recovery path if
                // the software retry itself stalls after a classified VT
                // initialization failure.
                throw SceneVideoRenderError.rawPipeStalled
            } catch {
                throw SceneVideoEncoderFallbackError(
                    primaryDiagnostic: primaryFailure.localizedDescription,
                    fallbackDiagnostic: error.localizedDescription
                )
            }
        }
    }

    private static func runVideoEncodingProcess(
        ffmpegURL: URL,
        assetID: String,
        arguments: (FFmpegVideoEncoder) -> [String]
    ) throws {
        try withVideoEncoderFallback { encoder in
            try runProcess(ffmpegURL, arguments(encoder), assetID)
        }
    }

    static func canRender(rendererURL: URL?, assetsDirectory: URL?, ffmpegPath: String?) -> Bool {
        rendererURL != nil && assetsDirectory != nil && ffmpegPath != nil
    }

    static func recordingArguments(
        recordDirectory: URL,
        configuration: SceneVideoRenderConfiguration
    ) -> [String] {
        var arguments = [
            "--window", windowArgument(for: configuration.size),
            "--silent",
            "--noautomute",
            "--no-audio-processing",
            "--disable-mouse",
            "--record-dir", recordDirectory.path,
            "--record-seconds", String(configuration.seconds),
            "--record-fps", String(configuration.fps),
            "--assets-dir", configuration.assetsDirectory.path
        ]
        insertLiveTextRecordingArgument(into: &arguments, configuration: configuration)
        if let sceneURL = configuration.sceneURL {
            arguments.append(contentsOf: ["--scene-package", sceneURL.standardizedFileURL.path])
        }
        arguments.append(configuration.projectDirectory.path)
        return arguments
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
        outputURL: URL,
        encoder: FFmpegVideoEncoder = .videoToolboxH264
    ) -> [String] {
        let framePattern = framesDirectory.appending(path: "frame_%05d.png").path
        let crossfadeFrameCount = SceneVideoLoopCrossfade.frameCount(totalFrameCount: recordedFrameCount, fps: fps)
        guard crossfadeFrameCount > 0 else {
            return [
                "-y",
                "-framerate", String(fps),
                "-i", framePattern
            ] + encoder.arguments(bitRate: "12M") + [
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
            "-map", "[out]"
        ] + encoder.arguments(bitRate: "12M") + [
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
        var arguments = [
            "--window", windowArgument(for: configuration.size),
            "--silent",
            "--noautomute",
            "--no-audio-processing",
            "--disable-mouse",
            "--record-raw", fifoURL.path,
            "--record-seconds", String(configuration.seconds),
            "--record-fps", String(configuration.fps),
            "--assets-dir", configuration.assetsDirectory.path
        ]
        insertLiveTextRecordingArgument(into: &arguments, configuration: configuration)
        if let sceneURL = configuration.sceneURL {
            arguments.append(contentsOf: ["--scene-package", sceneURL.standardizedFileURL.path])
        }
        arguments.append(configuration.projectDirectory.path)
        return arguments
    }

    private static func insertLiveTextRecordingArgument(
        into arguments: inout [String],
        configuration: SceneVideoRenderConfiguration
    ) {
        guard let sceneURL = configuration.sceneURL,
              SceneLiveTextRecordingPolicy.policy(sceneURL: sceneURL) == .overlayClocks,
              let assetsIndex = arguments.firstIndex(of: "--assets-dir") else {
            return
        }
        arguments.insert("--record-exclude-live", at: assetsIndex)
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
        outputURL: URL,
        encoder: FFmpegVideoEncoder = .videoToolboxH264
    ) -> [String] {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        return [
            "-y",
            "-f", "rawvideo",
            "-pix_fmt", "rgba",
            "-s", "\(width)x\(height)",
            "-r", String(fps),
            "-i", fifoURL.path
        ] + encoder.arguments(bitRate: "40M") + [
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
        outputURL: URL,
        encoder: FFmpegVideoEncoder = .videoToolboxH264
    ) -> [String] {
        let crossfadeFrameCount = SceneVideoLoopCrossfade.frameCount(totalFrameCount: recordedFrameCount, fps: fps)
        guard crossfadeFrameCount > 0 else {
            return [
                "-y",
                "-i", videoURL.path
            ] + encoder.arguments(bitRate: "12M") + [
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
            "-map", "[out]"
        ] + encoder.arguments(bitRate: "12M") + [
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
        progressHandler: (@Sendable (Double) -> Void)?,
        encoder: FFmpegVideoEncoder
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
                outputURL: intermediateOutputURL,
                encoder: encoder
            ),
            stderrPipe
        )
        do {
            try processRegistry.launch(ffmpegProcess, scopeID: configuration.processScopeID)
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
        defer { processRegistry.unregister(ffmpegProcess, scopeID: configuration.processScopeID) }

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
            let ffmpegExited = !ffmpegProcess.isRunning
            _ = processRegistry.terminateAndWait(ffmpegProcess)
            let progressCapture = progressMonitor.stop()
            if error is CancellationError {
                throw CancellationError()
            }
            if ffmpegExited, ffmpegProcess.terminationStatus != 0 {
                throw SceneProcessFailure(
                    name: "ffmpeg",
                    status: ffmpegProcess.terminationStatus,
                    stderr: progressCapture.stderr
                )
            }
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

        let rendererStderrPipe = Pipe()
        let rendererStderrReader = SceneBoundedPipeReader(
            handle: rendererStderrPipe.fileHandleForReading
        )
        rendererStderrReader.start()
        let rendererProcess = makeProcess(
            configuration.rendererURL,
            rawRecordingArguments(fifoURL: fifoURL, configuration: configuration),
            rendererStderrPipe
        )
        do {
            try processRegistry.launch(rendererProcess, scopeID: configuration.processScopeID)
            try? rendererStderrPipe.fileHandleForWriting.close()
        } catch {
            try? rendererStderrPipe.fileHandleForWriting.close()
            _ = rendererStderrReader.finish()
            closeWriterGuard()
            _ = processRegistry.terminateAndWait(ffmpegProcess)
            _ = progressMonitor.stop()
            throw error
        }
        defer { processRegistry.unregister(rendererProcess, scopeID: configuration.processScopeID) }

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

        rendererProcess.waitUntilExit()
        let rendererStatus = rendererProcess.terminationStatus
        let rendererStderr = String(
            decoding: rendererStderrReader.finish(),
            as: UTF8.self
        )

        // The encoder was confirmed as a real reader before the renderer was
        // launched. Once the renderer has finished, release the guard so the
        // encoder sees EOF after the renderer's own writer closes.
        closeWriterGuard()

        ffmpegProcess.waitUntilExit()
        watchdogWorkItem.cancel()

        let progressCapture = progressMonitor.stop()
        let recordedFrameCount = progressCapture.recordedFrameCount

        if watchdogState.hasFired {
            throw SceneVideoRenderError.rawPipeStalled
        }
        if let processFailure = SceneRawPipelineFailureSelection.failure(
            rendererName: configuration.rendererURL.lastPathComponent,
            rendererStatus: rendererStatus,
            rendererStderr: rendererStderr,
            recordedFrameCount: recordedFrameCount,
            targetFrameCount: targetFrameCount,
            ffmpegStatus: ffmpegProcess.terminationStatus,
            ffmpegStderr: progressCapture.stderr
        ) {
            throw processFailure
        }
        try SceneRecordedFrameSequence.validateRendererCompletion(
            rendererName: configuration.rendererURL.lastPathComponent,
            status: rendererStatus,
            stderr: rendererStderr,
            recordedFrameCount: recordedFrameCount,
            targetFrameCount: targetFrameCount
        )
        progressHandler?(1.0)

        let temporaryOutputURL = tempDirectory.appending(path: "scene-render-output.mp4")
        let ffmpegURL = URL(filePath: ffmpegPath)
        switch encoder {
        case .videoToolboxH264:
            try runVideoEncodingProcess(
                ffmpegURL: ffmpegURL,
                assetID: configuration.processScopeID
            ) { crossfadeEncoder in
                videoCrossfadeFfmpegArguments(
                    videoURL: intermediateOutputURL,
                    fps: configuration.fps,
                    recordedFrameCount: recordedFrameCount,
                    outputURL: temporaryOutputURL,
                    encoder: crossfadeEncoder
                )
            }
        case .softwareMPEG4:
            // This is already the one classified recovery attempt for the
            // raw pipeline. Keep its second pass on the same software codec
            // instead of probing the known-bad VideoToolbox session again.
            try runProcess(
                ffmpegURL,
                videoCrossfadeFfmpegArguments(
                    videoURL: intermediateOutputURL,
                    fps: configuration.fps,
                    recordedFrameCount: recordedFrameCount,
                    outputURL: temporaryOutputURL,
                    encoder: .softwareMPEG4
                ),
                configuration.processScopeID
            )
        }
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
        let targetFrameCount = configuration.fps * configuration.seconds
        let progressMonitor = progressHandler.map {
            SceneVideoRenderProgressMonitor(
                directory: tempDirectory,
                targetFrameCount: targetFrameCount,
                handler: $0
            )
        }
        progressMonitor?.start()
        let rendererStderrPipe = Pipe()
        let rendererStderrReader = SceneBoundedPipeReader(
            handle: rendererStderrPipe.fileHandleForReading
        )
        rendererStderrReader.start()
        let rendererProcess = makeProcess(
            configuration.rendererURL,
            recordingArguments(recordDirectory: tempDirectory, configuration: configuration),
            rendererStderrPipe
        )
        do {
            try processRegistry.launch(rendererProcess, scopeID: configuration.processScopeID)
            try? rendererStderrPipe.fileHandleForWriting.close()
        } catch {
            try? rendererStderrPipe.fileHandleForWriting.close()
            _ = rendererStderrReader.finish()
            progressMonitor?.stop()
            throw error
        }
        rendererProcess.waitUntilExit()
        let rendererStatus = rendererProcess.terminationStatus
        processRegistry.unregister(rendererProcess, scopeID: configuration.processScopeID)
        progressMonitor?.stop()
        let rendererStderr = String(
            decoding: rendererStderrReader.finish(),
            as: UTF8.self
        )
        let frameNames = try fileManager.contentsOfDirectory(atPath: tempDirectory.path)
        let recordedFrameCount: Int
        do {
            recordedFrameCount = try SceneRecordedFrameSequence.contiguousPNGFrameCount(
                fileNames: frameNames
            )
        } catch {
            guard rendererStatus == 0 else {
                throw SceneProcessFailure(
                    name: configuration.rendererURL.lastPathComponent,
                    status: rendererStatus,
                    stderr: rendererStderr
                )
            }
            throw error
        }
        try SceneRecordedFrameSequence.validateRendererCompletion(
            rendererName: configuration.rendererURL.lastPathComponent,
            status: rendererStatus,
            stderr: rendererStderr,
            recordedFrameCount: recordedFrameCount,
            targetFrameCount: targetFrameCount
        )
        progressHandler?(1.0)

        let temporaryOutputURL = tempDirectory.appending(path: "scene-render-output.mp4")
        try runVideoEncodingProcess(
            ffmpegURL: URL(filePath: ffmpegPath),
            assetID: configuration.processScopeID
        ) { encoder in
            ffmpegArguments(
                framesDirectory: tempDirectory,
                fps: configuration.fps,
                recordedFrameCount: recordedFrameCount,
                outputURL: temporaryOutputURL,
                encoder: encoder
            )
        }
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
        try renderWithOutcome(
            configuration: configuration,
            ffmpegPath: ffmpegPath,
            progressHandler: progressHandler
        ).cacheURL
    }

    static func renderWithOutcome(
        configuration: SceneVideoRenderConfiguration,
        ffmpegPath: String,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) throws -> SceneVideoRenderOutcome {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appending(path: "wwb-scene-render-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let temporaryOutputURL: URL
        let recordedFrameCount: Int
        if supportsRecordRaw(
            rendererURL: configuration.rendererURL,
            assetID: configuration.processScopeID
        ) {
            do {
                (temporaryOutputURL, recordedFrameCount) = try withVideoEncoderFallback { encoder in
                    try renderUsingRawPipe(
                        configuration: configuration,
                        ffmpegPath: ffmpegPath,
                        tempDirectory: tempDirectory,
                        progressHandler: progressHandler,
                        encoder: encoder
                    )
                }
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

        let muxResult = try configuration.sceneURL.map {
            try muxSceneAudioIfAvailable(
                sceneURL: $0,
                silentVideoURL: temporaryOutputURL,
                tempDirectory: tempDirectory,
                ffmpegPath: ffmpegPath,
                loopSeconds: loopSeconds,
                assetID: configuration.processScopeID
            )
        } ?? SceneAudioMuxResult(
            outputURL: temporaryOutputURL,
            audioResult: .notRequired
        )

        let audioResult = try validatedAudioResult(
            for: muxResult,
            ffmpegPath: ffmpegPath,
            assetID: configuration.processScopeID
        )

        let cacheDirectory = SceneVideoCache.cacheDirectoryURL()
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let outputURL = configuration.cacheKey.map(SceneVideoCache.cachedVideoURL(key:))
            ?? SceneVideoCache.cachedVideoURL(assetId: configuration.assetId)
        let installedURL = try SceneVideoCache.install(
            videoAt: muxResult.outputURL,
            audioResult: audioResult,
            at: outputURL
        )
        return SceneVideoRenderOutcome(cacheURL: installedURL, audioResult: audioResult)
    }

    /// Probes the concrete output selected by the mux operation before its
    /// metadata is persisted. A successful mux command is not sufficient:
    /// the final MP4 must actually expose an audio stream before the cache can
    /// be classified as containing authored sound.
    static func validatedAudioResult(
        for muxResult: SceneAudioMuxResult,
        ffmpegPath: String,
        assetID: String
    ) throws -> SceneRenderAudioResult {
        let hasAudioStream = try validateOutput(
            muxResult.outputURL,
            ffmpegPath: ffmpegPath,
            assetID: assetID
        )
        guard muxResult.audioResult.state == .included, !hasAudioStream else {
            return muxResult.audioResult
        }
        return .degraded(
            "The rendered Scene cache does not contain the expected authored audio stream."
        )
    }

    /// Validates the required video stream and reports whether the same file
    /// also contains audio. Authored-audio jobs use the latter to prevent a
    /// successful ffmpeg exit with a missing `a:0` stream from being labeled
    /// Full Cached.
    private static func validateOutput(_ url: URL, ffmpegPath: String, assetID: String) throws -> Bool {
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
        return streams.contains(where: { $0["codec_type"] as? String == "audio" })
    }

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
    /// given a mode-aware, non-truncating repeat count (see
    /// `SceneAudioTrackLoop`): one-shot audio plays once, while authored loop
    /// audio repeats only as many complete times as fit in the stretched video.
    static func muxSceneAudioIfAvailable(
        sceneURL: URL,
        silentVideoURL: URL,
        tempDirectory: URL,
        ffmpegPath: String,
        loopSeconds: Double,
        assetID: String
    ) throws -> SceneAudioMuxResult {
        do {
            guard let sceneData = try ScenePackageReader().readEntryData(
                url: sceneURL,
                path: "scene.json"
            ),
                  let scene = try JSONSerialization.jsonObject(with: sceneData) as? [String: Any] else {
                return SceneAudioMuxResult(
                    outputURL: silentVideoURL,
                    audioResult: .degraded(
                        "The Scene audio metadata could not be decoded from the rendered package."
                    )
                )
            }
            let declaresSoundLayer = SceneAudioExtractor.declaresVisibleSoundLayer(scene: scene)
            let hasInvalidPlaybackMode = SceneAudioExtractor.hasInvalidVisiblePlaybackMode(scene: scene)
            let tracks = SceneAudioExtractor.audioTracks(scene: scene)
            guard !tracks.isEmpty else {
                return SceneAudioMuxResult(
                    outputURL: silentVideoURL,
                    audioResult: declaresSoundLayer
                        ? .degraded(
                            hasInvalidPlaybackMode
                                ? "A visible Scene sound layer has an invalid non-string playbackmode; "
                                    + "its loop behavior was not guessed."
                                : "The Scene declares authored audio, but no playable sound track was found."
                        )
                        : .notRequired
                )
            }

            let package = try ScenePackageReader().read(url: sceneURL)
            let audioDirectory = tempDirectory.appending(path: "scene-audio")
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            var writtenTracks: [(url: URL, weight: Double, loops: Bool)] = []
            var extractedAudioURLs: [String: URL] = [:]
            var audioResult = hasInvalidPlaybackMode
                ? SceneRenderAudioResult.degraded(
                    "A visible Scene sound layer has an invalid non-string playbackmode; "
                        + "its loop behavior was not guessed."
                )
                : .included
            var audioBudget = SceneAudioExtractionBudget(
                maximumEntryBytes: maximumAuthoredAudioEntryBytes,
                aggregateBytes: maximumAuthoredAudioAggregateBytes
            )
            for (index, track) in tracks.enumerated() {
                if let existingURL = extractedAudioURLs[track.path] {
                    writtenTracks.append((url: existingURL, weight: track.volume, loops: track.loops))
                    continue
                }
                guard let entry = package.entry(named: track.path) else {
                    audioResult = .degraded(
                        "One or more authored Scene audio files are missing from the package."
                    )
                    continue
                }
                let entryBytes = UInt64(entry.length)
                guard audioBudget.reserve(entryBytes) else {
                    audioResult = .degraded(
                        "One or more authored Scene audio files exceed the safe extraction budget."
                    )
                    continue
                }
                let data = package.data(for: entry)
                let fileExtension = URL(filePath: track.path).pathExtension
                let fileURL = audioDirectory.appending(path: "audio-\(index).\(fileExtension)")
                try data.write(to: fileURL)
                extractedAudioURLs[track.path] = fileURL
                writtenTracks.append((url: fileURL, weight: track.volume, loops: track.loops))
            }
            guard !writtenTracks.isEmpty else {
                return SceneAudioMuxResult(
                    outputURL: silentVideoURL,
                    audioResult: audioResult.state == .degraded
                        ? audioResult
                        : .degraded("The authored Scene audio files are missing from the package.")
                )
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
            // single-pass video (no stretching), preserving each authored
            // playback mode, rather than risk a partially-correct stretch.
            let allDurationsKnown = durations.allSatisfy { $0 != nil }
            if !allDurationsKnown {
                audioResult = .degraded(
                    "One or more authored Scene audio tracks could not be timed exactly."
                )
            }
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
                    // A missing duration falls back to an unbounded repeat
                    // only when the author requested a loop. One-shot audio
                    // must never be repeated merely because timing failed.
                    return (track.url, track.weight, track.loops ? -1 : 0)
                }
                return (
                    track.url,
                    track.weight,
                    SceneAudioTrackLoop.streamLoopValue(
                        trackDurationSeconds: duration,
                        totalDurationSeconds: totalDurationSeconds,
                        loops: track.loops
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
            return SceneAudioMuxResult(outputURL: mixedOutputURL, audioResult: audioResult)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return SceneAudioMuxResult(
                outputURL: silentVideoURL,
                audioResult: .degraded(
                    "Authored Scene audio could not be added to the rendered cache."
                )
            )
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
            try processRegistry.launch(process, scopeID: assetID)
        } catch {
            _ = finishReaders()
            throw error
        }

        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while process.isRunning {
            if Task.isCancelled {
                _ = processRegistry.terminateAndWait(process)
                processRegistry.unregister(process, scopeID: assetID)
                _ = finishReaders()
                throw CancellationError()
            }
            if Date() >= deadline {
                _ = processRegistry.terminateAndWait(process)
                processRegistry.unregister(process, scopeID: assetID)
                _ = finishReaders()
                throw SceneVideoRenderError.processTimedOut(executableURL.lastPathComponent)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        processRegistry.unregister(process, scopeID: assetID)
        let (stdout, stderr) = finishReaders()
        return SceneProcessCapture(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }

    private static func windowArgument(for size: CGSize) -> String {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        return "0x0x\(width)x\(height)"
    }
}

/// Chooses the causal process failure for the concurrent raw FIFO pipeline.
/// A classified VideoToolbox initialization failure can close the FIFO and
/// make the renderer die second with SIGPIPE or EPIPE; preserve the FFmpeg
/// diagnostic in that case so the existing MPEG-4 recovery runs. For generic
/// dual failures, an incomplete nonzero renderer remains the primary error.
enum SceneRawPipelineFailureSelection {
    static func failure(
        rendererName: String,
        rendererStatus: Int32,
        rendererStderr: String,
        recordedFrameCount: Int,
        targetFrameCount: Int,
        ffmpegStatus: Int32,
        ffmpegStderr: String
    ) -> SceneProcessFailure? {
        let ffmpegFailure = ffmpegStatus == 0 ? nil : SceneProcessFailure(
            name: "ffmpeg",
            status: ffmpegStatus,
            stderr: ffmpegStderr
        )
        if let ffmpegFailure,
           FFmpegVideoEncoder.shouldUseSoftwareFallback(stderr: ffmpegStderr) {
            return ffmpegFailure
        }

        let minimumFrameCount = SceneRecordedFrameSequence.minimumCompleteFrameCount(
            targetFrameCount: targetFrameCount
        )
        if rendererStatus != 0, recordedFrameCount < minimumFrameCount {
            return SceneProcessFailure(
                name: rendererName,
                status: rendererStatus,
                stderr: rendererStderr
            )
        }
        return ffmpegFailure
    }
}

/// Fail-closed validation shared by the raw and PNG Scene recording paths.
/// The external renderer normally emits exactly `fps * seconds` frames. One
/// missing final frame is tolerated because an end-of-stream flush can race
/// renderer shutdown, but a shorter prefix must never be crossfaded and
/// installed as a valid cache generation.
enum SceneRecordedFrameSequence {
    static let maximumMissingFrameCount = 1

    static func minimumCompleteFrameCount(targetFrameCount: Int) -> Int {
        // One missing tail frame is negligible only for a realistically long
        // recording. Never let that absolute tolerance turn a short probe or
        // test clip into a 50% "complete" sequence.
        let toleratedMissingFrames = targetFrameCount >= 100
            ? maximumMissingFrameCount
            : 0
        return max(1, targetFrameCount - toleratedMissingFrames)
    }

    /// Validates frame completeness and the renderer's termination together.
    /// A small set of renderer builds crash in shutdown-time cleanup after
    /// delivering the complete stream. Preserve that compatibility only once
    /// the frame count independently proves completion; every earlier nonzero
    /// exit remains a process failure with bounded stderr attached.
    static func validateRendererCompletion(
        rendererName: String,
        status: Int32,
        stderr: String,
        recordedFrameCount: Int,
        targetFrameCount: Int
    ) throws {
        if recordedFrameCount == 0 {
            guard status == 0 else {
                throw SceneProcessFailure(name: rendererName, status: status, stderr: stderr)
            }
            throw SceneVideoRenderError.noFramesRecorded
        }

        let minimumFrameCount = minimumCompleteFrameCount(targetFrameCount: targetFrameCount)
        guard recordedFrameCount >= minimumFrameCount else {
            guard status == 0 else {
                throw SceneProcessFailure(name: rendererName, status: status, stderr: stderr)
            }
            throw SceneVideoRenderError.incompleteFrameSequence(
                expectedAtLeast: minimumFrameCount,
                actual: recordedFrameCount
            )
        }
    }

    /// Returns the number of frames only when the renderer's exact naming
    /// contract (`frame_00001.png`, `frame_00002.png`, ...) is contiguous.
    /// Merely counting files with a `frame_` prefix can make a sequence with a
    /// missing middle frame appear complete and lets ffmpeg silently stop at
    /// the gap.
    static func contiguousPNGFrameCount(fileNames: [String]) throws -> Int {
        let frameFileNames = fileNames
            .filter { $0.hasPrefix("frame_") }
            .sorted()

        for (offset, fileName) in frameFileNames.enumerated() {
            let expectedName = String(format: "frame_%05d.png", offset + 1)
            guard fileName == expectedName else {
                throw SceneVideoRenderError.nonContiguousFrameSequence(
                    expected: expectedName,
                    found: fileName
                )
            }
        }
        return frameFileNames.count
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

    /// Re-parses the complete bounded stderr transcript after EOF. A
    /// readability callback can split `frame=` and its digits across two Data
    /// chunks, so parsing each callback independently is not sufficient for
    /// the fail-closed final frame-count check.
    static func maximumFrameCount(fromTranscript transcript: String) -> Int? {
        transcript
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .compactMap { frameCount(fromLine: String($0)) }
            .max()
    }
}

/// Incremental line parser for FFmpeg's carriage-return progress stream.
/// The diagnostic transcript has a separate memory cap; this tiny carry is
/// retained even after that cap is reached so a final `frame=` token split
/// across arbitrary pipe reads is still observed correctly.
struct FfmpegProgressLineAccumulator {
    private static let maximumPendingLineBytes = 16_384
    private var pending = Data()

    mutating func consume(_ data: Data, flushPending: Bool = false) -> Int? {
        if !data.isEmpty {
            pending.append(data)
        }
        var maximumFrameCount: Int?

        while let delimiter = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: pending[..<delimiter], as: UTF8.self)
            if let frameCount = FfmpegProgressParsing.frameCount(fromLine: line) {
                maximumFrameCount = max(maximumFrameCount ?? frameCount, frameCount)
            }
            pending.removeSubrange(...delimiter)
        }

        if flushPending, !pending.isEmpty {
            let line = String(decoding: pending, as: UTF8.self)
            if let frameCount = FfmpegProgressParsing.frameCount(fromLine: line) {
                maximumFrameCount = max(maximumFrameCount ?? frameCount, frameCount)
            }
            pending.removeAll(keepingCapacity: true)
        } else if pending.count > Self.maximumPendingLineBytes {
            pending = Data(pending.suffix(Self.maximumPendingLineBytes))
        }

        return maximumFrameCount
    }
}

/// Watches an ffmpeg process's stderr pipe while it encodes, parsing the
/// `frame=` progress lines it periodically writes there to report render
/// progress and to recover the final encoded frame count once the process
/// exits (used as `recordedFrameCount` for the crossfade-loop pass in the
/// raw-pipe pipeline).
private struct FfmpegProgressCapture: Sendable {
    let recordedFrameCount: Int
    let stderr: String
}

private final class FfmpegStderrProgressMonitor: @unchecked Sendable {
    private static let stderrByteLimit = 1_048_576
    private let pipe: Pipe
    private let targetFrameCount: Int
    private let handler: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var lastFrameCount = 0
    private var stderrData = Data()
    private var progressLines = FfmpegProgressLineAccumulator()

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

    /// Stops watching and returns both the last observed frame count and a
    /// bounded stderr capture. The diagnostic is needed to distinguish a
    /// VideoToolbox session failure from unrelated FFmpeg errors without
    /// allowing a noisy child process to grow memory without bound.
    func stop() -> FfmpegProgressCapture {
        pipe.fileHandleForReading.readabilityHandler = nil
        // A short encode can exit before Dispatch delivers the readability
        // callback for ffmpeg's final carriage-return progress line. Drain
        // whatever remains after the process has closed its write end so the
        // final frame count does not depend on a run-loop scheduling race.
        consume(pipe.fileHandleForReading.readDataToEndOfFile())
        lock.lock()
        defer { lock.unlock() }
        if let trailingFrameCount = progressLines.consume(Data(), flushPending: true) {
            lastFrameCount = max(lastFrameCount, trailingFrameCount)
        }
        let transcript = String(decoding: stderrData, as: UTF8.self)
        let transcriptFrameCount = FfmpegProgressParsing.maximumFrameCount(
            fromTranscript: transcript
        ) ?? 0
        return FfmpegProgressCapture(
            recordedFrameCount: max(lastFrameCount, transcriptFrameCount),
            stderr: transcript
        )
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        lock.lock()
        let remaining = max(0, Self.stderrByteLimit - stderrData.count)
        if remaining > 0 {
            stderrData.append(data.prefix(remaining))
        }
        let latestFrameCount = progressLines.consume(data)
        if let latestFrameCount {
            lastFrameCount = max(lastFrameCount, latestFrameCount)
        }
        lock.unlock()
        guard let latestFrameCount else {
            return
        }
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
            let frameNames = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            let recordedFrameCount = (try? SceneRecordedFrameSequence.contiguousPNGFrameCount(
                fileNames: frameNames ?? []
            )) ?? 0
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
    case incompleteFrameSequence(expectedAtLeast: Int, actual: Int)
    case nonContiguousFrameSequence(expected: String, found: String)
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
        case .incompleteFrameSequence(let expectedAtLeast, let actual):
            return "The scene renderer produced only \(actual) frames; at least \(expectedAtLeast) are required."
        case .nonContiguousFrameSequence(let expected, let found):
            return "The Scene PNG sequence is not contiguous (expected \(expected), found \(found))."
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

/// A non-zero child-process exit that retains bounded stderr. Keeping this
/// separate from the renderer's status-only errors makes the software retry
/// fail closed: only an FFmpeg invocation that produced a recognized
/// VideoToolbox diagnostic is eligible.
struct SceneProcessFailure: Error, LocalizedError, Equatable {
    let name: String
    let status: Int32
    let stderr: String

    var errorDescription: String? {
        let diagnostic = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !diagnostic.isEmpty else {
            return "\(name) exited with status \(status)."
        }
        return "\(name) exited with status \(status): \(diagnostic)"
    }
}

/// Reports both attempts when a classified VideoToolbox failure is followed
/// by a failed software encode. The caller gets enough evidence to diagnose
/// the failure while the cache remains uncommitted by `render()`.
struct SceneVideoEncoderFallbackError: Error, LocalizedError, Equatable {
    let primaryDiagnostic: String
    let fallbackDiagnostic: String

    var errorDescription: String? {
        "VideoToolbox encode failed (\(primaryDiagnostic)); "
            + "software MPEG-4 recovery also failed (\(fallbackDiagnostic))."
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
    func launch(_ process: Process, scopeID: String) throws {
        lock.lock()
        do {
            try Task.checkCancellation()
            processes[scopeID, default: [:]][ObjectIdentifier(process)] = process
            try process.run()
            lock.unlock()
        } catch {
            processes[scopeID]?[ObjectIdentifier(process)] = nil
            if processes[scopeID]?.isEmpty == true { processes[scopeID] = nil }
            lock.unlock()
            if process.isRunning { _ = terminateAndWait(process) }
            throw error
        }
    }

    func unregister(_ process: Process, scopeID: String) {
        lock.lock()
        processes[scopeID]?[ObjectIdentifier(process)] = nil
        if processes[scopeID]?.isEmpty == true { processes[scopeID] = nil }
        lock.unlock()
    }

    func cancel(scopeID: String) {
        snapshot(scopeID: scopeID).forEach(terminate)
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

    private func snapshot(scopeID: String) -> [Process] {
        lock.lock()
        defer { lock.unlock() }
        return processes[scopeID].map { Array($0.values) } ?? []
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
