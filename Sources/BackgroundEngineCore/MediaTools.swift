import Foundation
import Darwin

/// Input boundary shared by ffprobe and every FFmpeg conversion path. Only
/// self-contained media demuxers are permitted; playlist/reference demuxers
/// such as HLS, DASH, concat, SDP, and image sequences are deliberately absent.
/// Descriptor-bound inputs also exclude the `file` protocol so a demuxer can
/// never follow a secondary path outside the already-open source.
enum FFmpegLocalMediaInputPolicy {
    static let formatWhitelist = [
        "aac", "ac3", "aiff", "amr", "ape", "asf", "au", "av1", "avi",
        "caf", "dnxhd", "dts", "dv", "eac3", "flac", "flv", "gxf", "h264",
        "hevc", "ivf", "m4v", "matroska", "webm", "mjpeg", "mjpeg_2000",
        "mlv", "mov", "mp4", "m4a", "3gp", "3g2", "mj2", "mp3", "mpeg",
        "mpegts", "mpegvideo", "mxf", "nut", "obu", "ogg", "rm", "roq",
        "smk", "sox", "swf", "truehd", "tta", "vc1", "vivo", "vmd", "voc",
        "w64", "wav", "wtv", "wv", "yuv4mpegpipe"
    ].joined(separator: ",")

    static let descriptorProtocolWhitelist = "fd,pipe"
    static let fileProtocolWhitelist = "file,fd,pipe"

    static func arguments(inputPath: String) -> [String] {
        let protocols = inputPath.hasPrefix("fd:")
            ? descriptorProtocolWhitelist
            : fileProtocolWhitelist
        return [
            "-protocol_whitelist", protocols,
            "-format_whitelist", formatWhitelist
        ]
    }
}

enum SecureLocalMediaFile {
    static func open(_ url: URL) throws -> FileHandle {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw ConversionError.unsafeInputPath }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw ConversionError.unsafeInputPath
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

public enum MediaToolKind: String, CaseIterable, Codable, Sendable {
    case ffmpeg
    case ffprobe
}

public enum MediaToolSource: String, Codable, Sendable {
    case bundled
    case developmentOverride
    case unavailable
}

public struct MediaToolResolution: Codable, Equatable, Sendable {
    public let kind: MediaToolKind
    public let path: String?
    public let source: MediaToolSource

    public init(kind: MediaToolKind, path: String?, source: MediaToolSource) {
        self.kind = kind
        self.path = path
        self.source = source
    }
}

/// Resolves the self-contained media runtime shipped inside the application.
/// Homebrew paths are accepted only by debug/development builds so a release
/// can never appear healthy while silently depending on the host machine.
public struct MediaToolResolver: Sendable {
    public static let pinnedBuildID = "ffmpeg-9.0.1-background-engine-1"

    private let bundleResourceURL: URL?
    private let environment: [String: String]
    private let allowDevelopmentFallback: Bool

    public init(
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowDevelopmentFallback: Bool? = nil
    ) {
        self.bundleResourceURL = bundleResourceURL
        self.environment = environment
        #if DEBUG
        self.allowDevelopmentFallback = allowDevelopmentFallback ?? true
        #else
        self.allowDevelopmentFallback = allowDevelopmentFallback ?? false
        #endif
    }

    public func resolve(_ kind: MediaToolKind) -> MediaToolResolution {
        if let bundled = bundledURL(for: kind), isExecutable(bundled) {
            return MediaToolResolution(kind: kind, path: bundled.path, source: .bundled)
        }
        if allowDevelopmentFallback {
            let environmentKey = "BACKGROUND_ENGINE_\(kind.rawValue.uppercased())"
            let candidates = [environment[environmentKey]].compactMap { $0 }.map { URL(filePath: $0) }
                + [
                    URL(filePath: "/opt/homebrew/bin/\(kind.rawValue)"),
                    URL(filePath: "/usr/local/bin/\(kind.rawValue)"),
                    URL(filePath: "/usr/bin/\(kind.rawValue)")
                ]
            if let candidate = candidates.first(where: isExecutable) {
                return MediaToolResolution(kind: kind, path: candidate.path, source: .developmentOverride)
            }
        }
        return MediaToolResolution(kind: kind, path: nil, source: .unavailable)
    }

    public func runtimeHealth() -> RuntimeComponentHealth {
        let ffmpeg = resolve(.ffmpeg)
        let ffprobe = resolve(.ffprobe)
        guard ffmpeg.path != nil, ffprobe.path != nil else {
            let missing = [ffmpeg, ffprobe]
                .filter { $0.path == nil }
                .map(\.kind.rawValue)
                .joined(separator: ", ")
            return RuntimeComponentHealth(
                availability: .missing,
                version: Self.pinnedBuildID,
                detail: "Missing bundled media tools: \(missing)."
            )
        }
        let isBundled = ffmpeg.source == .bundled && ffprobe.source == .bundled
        return RuntimeComponentHealth(
            availability: isBundled ? .available : .invalid,
            version: Self.pinnedBuildID,
            detail: isBundled
                ? "Bundled FFmpeg runtime is ready."
                : "Using a development-only media tool override."
        )
    }

    private func bundledURL(for kind: MediaToolKind) -> URL? {
        guard let bundleResourceURL else { return nil }
        return bundleResourceURL
            .appending(path: "MediaTools", directoryHint: .isDirectory)
            .appending(path: kind.rawValue, directoryHint: .notDirectory)
    }

    private func isExecutable(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}

public struct MediaProbeReport: Codable, Equatable, Sendable {
    public struct Stream: Codable, Equatable, Sendable {
        public struct Disposition: Codable, Equatable, Sendable {
            public let attachedPicture: Int?
            public let defaultStream: Int?

            enum CodingKeys: String, CodingKey {
                case attachedPicture = "attached_pic"
                case defaultStream = "default"
            }
        }

        public let index: Int
        public let codecName: String?
        public let profile: String?
        public let codecType: String?
        public let pixelFormat: String?
        public let level: Int?
        public let width: Int?
        public let height: Int?
        public let duration: String?
        public let startTime: String?
        public let sampleRate: String?
        public let channels: Int?
        public let frameCount: String?
        public let readFrameCount: String?
        public let readPacketCount: String?
        public let disposition: Disposition?
        public let tags: [String: String]?

        public var isAttachedPicture: Bool {
            (disposition?.attachedPicture ?? 0) != 0
        }

        public var isDefault: Bool {
            (disposition?.defaultStream ?? 0) != 0
        }

        enum CodingKeys: String, CodingKey {
            case index
            case codecName = "codec_name"
            case profile
            case codecType = "codec_type"
            case pixelFormat = "pix_fmt"
            case level
            case width
            case height
            case duration
            case startTime = "start_time"
            case sampleRate = "sample_rate"
            case channels
            case frameCount = "nb_frames"
            case readFrameCount = "nb_read_frames"
            case readPacketCount = "nb_read_packets"
            case disposition
            case tags
        }
    }

    public struct Format: Codable, Equatable, Sendable {
        public let formatName: String?
        public let duration: String?
        public let size: String?
        public let bitRate: String?

        enum CodingKeys: String, CodingKey {
            case formatName = "format_name"
            case duration
            case size
            case bitRate = "bit_rate"
        }
    }

    public let streams: [Stream]
    public let format: Format?

    public init(streams: [Stream], format: Format?) {
        self.streams = streams
        self.format = format
    }

    /// ffprobe exposes embedded album artwork as a video stream with the
    /// `attached_pic` disposition. It is metadata, not time-varying wallpaper
    /// content, so accepting it would import audio-only files as videos and
    /// feed a single cover frame into the conversion pipeline.
    public var hasVideo: Bool {
        preferredVideoStreamIndex != nil
    }
    public var hasAudio: Bool { preferredAudioStreamIndex != nil }
    public var durationSeconds: Double? { format?.duration.flatMap(Double.init) }

    /// Conservative macOS 14 baseline used by the synchronous importer. This
    /// avoids blocking a recursive scan on asynchronous AVFoundation metadata
    /// loads while preserving direct playback for the common QuickTime/MP4
    /// codecs available on both Intel and Apple Silicon. Everything else is
    /// normalized through the bounded FFmpeg cache.
    public var isBaselineAVFoundationPlayableVideo: Bool {
        guard let formatName = format?.formatName?.lowercased() else { return false }
        let formats = Set(formatName.split(separator: ",").map(String.init))
        let playableVideos = streams.filter {
            $0.codecType == "video" && !$0.isAttachedPicture && $0.index >= 0
        }
        let playableAudio = streams.filter { $0.codecType == "audio" && $0.index >= 0 }
        let streamCounts = LocalMediaStreamPolicy.counts(in: self)
        guard LocalMediaStreamPolicy.allows(streamCounts),
              streamCounts.total == streamCounts.video + streamCounts.audio,
              streamCounts.video == 1,
              playableVideos.count == 1,
              playableAudio.count <= 1,
              !formats.isDisjoint(with: ["mov", "mp4", "m4a", "3gp", "3g2", "mj2"]),
              let videoIndex = preferredVideoStreamIndex,
              let video = streams.first(where: { $0.index == videoIndex }),
              video.codecName?.lowercased() == "h264",
              ["constrained baseline", "baseline", "main", "high"]
                .contains(video.profile?.lowercased() ?? ""),
              ["yuv420p", "yuvj420p"].contains(video.pixelFormat?.lowercased() ?? ""),
              let level = video.level,
              (10...52).contains(level),
              let width = video.width,
              let height = video.height,
              width > 0,
              height > 0,
              width <= LocalMediaStreamPolicy.maximumVideoDimension,
              height <= LocalMediaStreamPolicy.maximumVideoDimension else {
            return false
        }
        let (pixels, overflow) = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        guard !overflow, pixels <= LocalMediaStreamPolicy.maximumVideoPixels else { return false }
        guard let audioIndex = preferredAudioStreamIndex else { return true }
        guard let audio = streams.first(where: { $0.index == audioIndex }),
              let audioCodec = audio.codecName?.lowercased(),
              ["aac", "ac3", "alac", "eac3", "mp3"].contains(audioCodec),
              let channels = audio.channels,
              (1...8).contains(channels),
              let sampleRateText = audio.sampleRate,
              sampleRateText.allSatisfy(\.isNumber),
              let sampleRate = Int(sampleRateText),
              (8_000...192_000).contains(sampleRate) else {
            return false
        }
        return true
    }

    /// Returns the absolute ffprobe stream index that should be mapped into a
    /// single-stream wallpaper cache. Wallpaper containers can put a cover,
    /// preview, alternate angle, or black placeholder before the authored
    /// default stream, so `0:v:0` is not a safe playback choice.
    public var preferredVideoStreamIndex: Int? {
        streams
            .filter { $0.codecType == "video" && !$0.isAttachedPicture && $0.index >= 0 }
            .sorted(by: Self.isPreferredVideoStream)
            .first?
            .index
    }

    /// Returns the absolute ffprobe index of the authored audio stream that a
    /// single-output cache should preserve. Default disposition wins, followed
    /// by channel count and sample rate. The stable index tie-breaker prevents
    /// a container reordering from selecting an arbitrary alternate track.
    public var preferredAudioStreamIndex: Int? {
        streams
            .filter { $0.codecType == "audio" && $0.index >= 0 }
            .sorted(by: Self.isPreferredAudioStream)
            .first?
            .index
    }

    private static func isPreferredVideoStream(_ lhs: Stream, _ rhs: Stream) -> Bool {
        if lhs.isDefault != rhs.isDefault {
            return lhs.isDefault
        }
        let lhsArea = pixelArea(width: lhs.width, height: lhs.height)
        let rhsArea = pixelArea(width: rhs.width, height: rhs.height)
        if lhsArea != rhsArea {
            return lhsArea > rhsArea
        }
        return lhs.index < rhs.index
    }

    private static func isPreferredAudioStream(_ lhs: Stream, _ rhs: Stream) -> Bool {
        if lhs.isDefault != rhs.isDefault {
            return lhs.isDefault
        }
        let lhsChannels = max(0, lhs.channels ?? 0)
        let rhsChannels = max(0, rhs.channels ?? 0)
        if lhsChannels != rhsChannels {
            return lhsChannels > rhsChannels
        }
        let lhsSampleRate = Int(lhs.sampleRate ?? "") ?? 0
        let rhsSampleRate = Int(rhs.sampleRate ?? "") ?? 0
        if lhsSampleRate != rhsSampleRate {
            return lhsSampleRate > rhsSampleRate
        }
        return lhs.index < rhs.index
    }

    private static func pixelArea(width: Int?, height: Int?) -> UInt64 {
        guard let width, let height, width > 0, height > 0 else { return 0 }
        let (area, overflow) = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        return overflow ? .max : area
    }
}

public struct MediaProbe: Sendable {
    private static let inputDescriptorToken = "__BACKGROUND_ENGINE_MEDIA_PROBE_FD__"
    private let resolver: MediaToolResolver

    public init(resolver: MediaToolResolver = MediaToolResolver()) {
        self.resolver = resolver
    }

    public func inspect(_ input: URL, timeout: TimeInterval = 10) throws -> MediaProbeReport {
        let file = try SecureLocalMediaFile.open(input)
        defer { try? file.close() }
        guard LocalMediaInputPolicy.allowsSelfContainedMedia(
            fileHandle: file,
            declaredPathExtension: input.pathExtension
        ) else {
            throw ConversionError.unsafeReferencedInput
        }
        return try inspect(file, timeout: timeout)
    }

    func inspect(_ input: FileHandle, timeout: TimeInterval = 10) throws -> MediaProbeReport {
        try inspect(
            input,
            timeout: timeout,
            arguments: Self.probeArguments(inputPath: "fd:")
        )
    }

    func hasObservedPacket(
        _ input: FileHandle,
        streamIndex: Int,
        streamStartTime: String?,
        timeout: TimeInterval
    ) throws -> Bool {
        guard streamIndex >= 0 else { return false }
        let report = try inspect(
            input,
            timeout: timeout,
            arguments: Self.boundedPacketProbeArguments(
                inputPath: "fd:",
                streamIndex: streamIndex,
                streamStartTime: streamStartTime
            )
        )
        guard let stream = report.streams.first(where: { $0.index == streamIndex }),
              let packetCount = stream.readPacketCount,
              let parsedCount = Int(packetCount) else {
            return false
        }
        return parsedCount > 0
    }

    private func inspect(
        _ input: FileHandle,
        timeout: TimeInterval,
        arguments: [String]
    ) throws -> MediaProbeReport {
        guard let path = resolver.resolve(.ffprobe).path else {
            throw ConversionError.ffprobeNotFound
        }
        guard Darwin.lseek(input.fileDescriptor, 0, SEEK_SET) != -1 else {
            throw ConversionError.invalidProbeOutput
        }
        let output = Pipe()
        let errors = Pipe()
        let outputReader = BoundedPipeReader(handle: output.fileHandleForReading)
        let errorReader = BoundedPipeReader(handle: errors.fileHandleForReading)
        outputReader.start()
        errorReader.start()
        let child: SupervisedChildProcess
        do {
            child = try SupervisedChildProcess.spawn(
                executable: URL(filePath: path),
                arguments: arguments,
                currentDirectory: URL(filePath: "/"),
                standardOutput: output.fileHandleForWriting,
                standardError: errors.fileHandleForWriting,
                outputFileLimit: nil,
                inheritedFileDescriptors: [InheritedFileDescriptor(
                    fileHandle: input,
                    argumentToken: Self.inputDescriptorToken
                )]
            )
        } catch {
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            _ = outputReader.finish()
            _ = errorReader.finish()
            throw ConversionError.ffprobeLaunchFailed
        }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let (terminationStatus, timedOut) = child.waitUntilExit(timeout: timeout)
        let data = outputReader.finish()
        let errorData = errorReader.finish()
        if timedOut { throw ConversionError.ffprobeTimedOut }
        return try decodeReport(data, errorData: errorData, terminationStatus: terminationStatus)
    }

    public func inspect(_ input: URL, timeout: Duration) async throws -> MediaProbeReport {
        let file = try SecureLocalMediaFile.open(input)
        defer { try? file.close() }
        guard LocalMediaInputPolicy.allowsSelfContainedMedia(
            fileHandle: file,
            declaredPathExtension: input.pathExtension
        ) else {
            throw ConversionError.unsafeReferencedInput
        }
        return try await inspect(file, timeout: timeout)
    }

    func inspect(
        _ input: FileHandle,
        timeout: Duration
    ) async throws -> MediaProbeReport {
        try await inspect(
            input,
            timeout: timeout,
            arguments: Self.probeArguments(inputPath: "fd:")
        )
    }

    /// Reads at most one packet from one absolute stream index. Starting at the
    /// stream's declared timestamp avoids scanning a long leading gap, while
    /// `+#1` prevents output validation from traversing an entire multi-hour
    /// wallpaper merely to prove that the stream contains authored data.
    func hasObservedPacket(
        _ input: FileHandle,
        streamIndex: Int,
        streamStartTime: String?,
        timeout: Duration
    ) async throws -> Bool {
        guard streamIndex >= 0 else { return false }
        let report = try await inspect(
            input,
            timeout: timeout,
            arguments: Self.boundedPacketProbeArguments(
                inputPath: "fd:",
                streamIndex: streamIndex,
                streamStartTime: streamStartTime
            )
        )
        guard let stream = report.streams.first(where: { $0.index == streamIndex }),
              let packetCount = stream.readPacketCount,
              let parsedCount = Int(packetCount) else {
            return false
        }
        return parsedCount > 0
    }

    static func boundedPacketProbeArguments(
        inputPath: String,
        streamIndex: Int,
        streamStartTime: String?
    ) -> [String] {
        let start: Double
        if let streamStartTime,
           let value = Double(streamStartTime),
           value.isFinite {
            start = max(0, value)
        } else {
            start = 0
        }
        return ["-v", "error"]
            + FFmpegLocalMediaInputPolicy.arguments(inputPath: inputPath)
            + inputDescriptorArguments(inputPath: inputPath)
            + [
            "-select_streams", String(streamIndex),
            "-read_intervals", "\(start)%+#1",
            "-count_packets",
            "-show_entries", "stream=index,nb_read_packets",
            "-print_format", "json",
            inputPath
            ]
    }

    private func inspect(
        _ input: FileHandle,
        timeout: Duration,
        arguments: [String]
    ) async throws -> MediaProbeReport {
        guard let path = resolver.resolve(.ffprobe).path else {
            throw ConversionError.ffprobeNotFound
        }
        try Task.checkCancellation()
        guard Darwin.lseek(input.fileDescriptor, 0, SEEK_SET) != -1 else {
            throw ConversionError.invalidProbeOutput
        }
        let output = Pipe()
        let errors = Pipe()
        let outputReader = BoundedPipeReader(handle: output.fileHandleForReading)
        let errorReader = BoundedPipeReader(handle: errors.fileHandleForReading)
        outputReader.start()
        errorReader.start()
        let child: SupervisedChildProcess
        do {
            child = try SupervisedChildProcess.spawn(
                executable: URL(filePath: path),
                arguments: arguments,
                currentDirectory: URL(filePath: "/"),
                standardOutput: output.fileHandleForWriting,
                standardError: errors.fileHandleForWriting,
                outputFileLimit: nil,
                inheritedFileDescriptors: [InheritedFileDescriptor(
                    fileHandle: input,
                    argumentToken: Self.inputDescriptorToken
                )]
            )
        } catch {
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            _ = outputReader.finish()
            _ = errorReader.finish()
            throw ConversionError.ffprobeLaunchFailed
        }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()

        let terminationStatus: Int32
        let timedOut: Bool
        do {
            (terminationStatus, timedOut) = try await child.waitUntilExit(timeout: timeout)
        } catch {
            _ = outputReader.finish()
            _ = errorReader.finish()
            throw error
        }
        let data = outputReader.finish()
        let errorData = errorReader.finish()
        if timedOut { throw ConversionError.ffprobeTimedOut }
        return try decodeReport(data, errorData: errorData, terminationStatus: terminationStatus)
    }

    static func probeArguments(inputPath: String) -> [String] {
        ["-v", "error"]
            + FFmpegLocalMediaInputPolicy.arguments(inputPath: inputPath)
            + inputDescriptorArguments(inputPath: inputPath)
            + [
            "-show_streams",
            "-show_format",
            "-print_format", "json",
            inputPath
            ]
    }

    private static func inputDescriptorArguments(inputPath: String) -> [String] {
        inputPath == "fd:" ? ["-fd", inputDescriptorToken] : []
    }

    private func decodeReport(
        _ data: Data,
        errorData: Data,
        terminationStatus: Int32
    ) throws -> MediaProbeReport {
        guard terminationStatus == 0 else {
            throw ConversionError.ffprobeFailed(
                terminationStatus,
                String(data: errorData, encoding: .utf8) ?? ""
            )
        }
        do {
            return try JSONDecoder().decode(MediaProbeReport.self, from: data)
        } catch {
            throw ConversionError.invalidProbeOutput
        }
    }
}

/// Drains a child-process pipe concurrently while retaining only a bounded
/// prefix. Draining prevents a noisy child from blocking on a full pipe; the
/// cap prevents malformed input from growing the app's memory without bound.
final class BoundedPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let byteLimit: Int
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var buffer = Data()

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
                let remaining = max(0, byteLimit - buffer.count)
                if remaining > 0 { buffer.append(chunk.prefix(remaining)) }
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
        return buffer
    }
}

public struct VideoConversionCacheKey: Codable, Equatable, Sendable {
    public let contentHash: String
    public let mediaBuildID: String
    public let recipeID: String
    public let width: Int?
    public let height: Int?

    public init(
        contentHash: String,
        mediaBuildID: String = MediaToolResolver.pinnedBuildID,
        recipeID: String = VideoConverter.conversionRecipeID,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.contentHash = contentHash
        self.mediaBuildID = mediaBuildID
        self.recipeID = recipeID
        self.width = width
        self.height = height
    }

    public var fileName: String {
        fileName(recipeID: recipeID)
    }

    var previousRecipeFileNames: Set<String> {
        Set(VideoConverter.previousConversionRecipeIDs.map(fileName(recipeID:)))
    }

    private func fileName(recipeID: String) -> String {
        let size = width.flatMap { width in height.map { "-\(width)x\($0)" } } ?? ""
        return "\(contentHash.prefix(24))-\(mediaBuildID)-\(recipeID)\(size).mp4"
    }

    /// v0.2 build 3 keyed conversion output only by the FFmpeg binary build.
    /// Keep the exact spelling for bounded cleanup and one-time migration;
    /// new conversions must never write this legacy name.
    var legacyV1FileName: String {
        let size = width.flatMap { width in height.map { "-\(width)x\($0)" } } ?? ""
        return "\(contentHash.prefix(24))-\(mediaBuildID)\(size).mp4"
    }
}

enum VideoConversionCacheLocation {
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "Background Engine")
            .appending(path: "ConvertedVideoCache")
            .appending(path: MediaToolResolver.pinnedBuildID)
    }
}
