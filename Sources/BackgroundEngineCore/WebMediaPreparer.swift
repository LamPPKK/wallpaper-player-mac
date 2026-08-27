import CryptoKit
import Darwin
import Foundation

public enum PreparedWebMediaKind: String, Codable, Hashable, Sendable {
    case video
    case audio

    fileprivate var pathExtension: String {
        switch self {
        case .video: "mp4"
        case .audio: "m4a"
        }
    }
}

/// Stable identity for one WebKit-compatible derived media blob. The recipe
/// describes the complete ordered encoder policy and its H.264-only Web video
/// acceptance rule, so changing any output semantics requires a new recipe
/// identifier.
public struct WebMediaCacheKey: Codable, Equatable, Hashable, Sendable {
    public let sourceContentHash: String
    public let mediaBuildID: String
    public let recipeID: String
    public let kind: PreparedWebMediaKind

    public init(
        sourceContentHash: String,
        mediaBuildID: String = MediaToolResolver.pinnedBuildID,
        recipeID: String = WebMediaPreparer.recipeID,
        kind: PreparedWebMediaKind
    ) {
        self.sourceContentHash = sourceContentHash.lowercased()
        self.mediaBuildID = mediaBuildID
        self.recipeID = recipeID
        self.kind = kind
    }

    /// Hash every identity component before using it as a path. Even a cache
    /// key decoded from untrusted metadata therefore cannot inject separators,
    /// dot components, or an excessively long file name.
    public var fileName: String {
        let identity = [
            "background-engine-web-media-v1",
            sourceContentHash,
            mediaBuildID,
            recipeID,
            kind.rawValue
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "web-media-\(digest).\(kind.pathExtension)"
    }
}

public struct PreparedWebMedia: Equatable, Sendable {
    public let kind: PreparedWebMediaKind
    public let url: URL
    public let sourceContentHash: String
    public let cacheKey: WebMediaCacheKey
    public let probeReport: MediaProbeReport
    public let reusedCachedOutput: Bool

    public init(
        kind: PreparedWebMediaKind,
        url: URL,
        sourceContentHash: String,
        cacheKey: WebMediaCacheKey,
        probeReport: MediaProbeReport,
        reusedCachedOutput: Bool
    ) {
        self.kind = kind
        self.url = url
        self.sourceContentHash = sourceContentHash
        self.cacheKey = cacheKey
        self.probeReport = probeReport
        self.reusedCachedOutput = reusedCachedOutput
    }
}

public enum WebMediaPreparationError: Error, Equatable, LocalizedError, Sendable {
    case unsafeSource(String)
    case sourceTooLarge(UInt64, UInt64)
    case insufficientDiskSpace(required: UInt64, available: UInt64)
    case unsupportedSource
    case unsafeCacheDirectory
    case referencedMediaNotSupported
    case invalidSourceVideoDimensions
    case sourceVideoDimensionsExceeded
    case invalidSourceAudioParameters
    case sourceStreamCountExceeded(total: Int, video: Int, audio: Int)
    case invalidExistingCache(String)
    case invalidConvertedOutput
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unsafeSource(let path):
            "The Web media source is not a safe regular file: \(path)"
        case .sourceTooLarge(let actual, let maximum):
            "The Web media source is too large (\(actual) bytes, limit \(maximum))."
        case .insufficientDiskSpace(let required, let available):
            "Web media preparation needs \(required) bytes of safe free space; only \(available) bytes are available."
        case .unsupportedSource:
            "The Web media source contains no usable video or audio stream."
        case .unsafeCacheDirectory:
            "The Web media cache changed while media was being prepared."
        case .referencedMediaNotSupported:
            "Playlist and externally referenced Web media are not supported."
        case .invalidSourceVideoDimensions:
            "The Web media source has missing or nonpositive video dimensions."
        case .sourceVideoDimensionsExceeded:
            "The Web media source exceeds the safe decoded video dimensions."
        case .invalidSourceAudioParameters:
            "The Web media source has an unsafe channel count or sample rate."
        case .sourceStreamCountExceeded(let total, let video, let audio):
            "The Web media source contains too many streams (total \(total), video \(video), audio \(audio))."
        case .invalidExistingCache(let name):
            "The existing Web media cache entry is invalid: \(name)"
        case .invalidConvertedOutput:
            "FFmpeg did not produce the expected WebKit-compatible media streams."
        case .timedOut:
            "Web media preparation exceeded its time limit."
        }
    }
}

/// Converts statically referenced Web wallpaper media into formats that are
/// consistently playable by WKWebView on the macOS 14 deployment floor.
///
/// The source is copied and hashed through an open descriptor before probing,
/// so classification, conversion, and the cache key always describe identical
/// bytes. Derived files are validated before a no-clobber content-addressed
/// publish; concurrent preparers can safely converge on the same cache entry.
public struct WebMediaPreparer: Sendable {
    public static let defaultTimeout: Duration = VideoConverter.defaultTimeout
    public static let maximumSourceBytes: UInt64 = 20 * 1_024 * 1_024 * 1_024
    public static let maximumVideoBytes: UInt64 = VideoConverter.maximumConvertedBytes
    public static let maximumAudioBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
    public static let maximumVideoDimension = LocalMediaStreamPolicy.maximumVideoDimension
    public static let maximumVideoPixels = LocalMediaStreamPolicy.maximumVideoPixels
    public static let maximumSourceAudioChannels = LocalMediaStreamPolicy.maximumAudioChannelCount
    public static let maximumSourceAudioSampleRate = LocalMediaStreamPolicy.maximumAudioSampleRate
    public static let maximumSourceStreamCount = LocalMediaStreamPolicy.maximumTotalStreamCount
    public static let maximumSourceVideoStreamCount = LocalMediaStreamPolicy.maximumVideoStreamCount
    public static let maximumSourceAudioStreamCount = LocalMediaStreamPolicy.maximumAudioStreamCount
    public static let recipeID =
        "web-media-4-self-contained-h264-only-bounded-\(VideoConverter.conversionRecipeID)-aac-lc-48khz-fmp4"

    private static let inputDescriptorToken = "__BACKGROUND_ENGINE_WEB_MEDIA_INPUT_FD__"
    static let descriptorOutputURL = "pipe:1"
    private static let defaultProbeTimeout: Duration = .seconds(10)
    static let maximumPruneDirectoryEntries = 10_000

    private let resolver: MediaToolResolver
    private let mediaProbe: MediaProbe
    private let videoConverter: VideoConverter
    private let probeTimeout: Duration

    public init(resolver: MediaToolResolver = MediaToolResolver()) {
        self.resolver = resolver
        mediaProbe = MediaProbe(resolver: resolver)
        videoConverter = VideoConverter(resolver: resolver)
        probeTimeout = Self.defaultProbeTimeout
    }

    /// Internal deterministic timeout seam for process-supervision tests. The
    /// production initializer always keeps the bounded ten-second probe cap.
    init(resolver: MediaToolResolver, probeTimeout: Duration) {
        precondition(probeTimeout > .zero)
        self.resolver = resolver
        mediaProbe = MediaProbe(resolver: resolver)
        videoConverter = VideoConverter(resolver: resolver)
        self.probeTimeout = probeTimeout
    }

    /// Removes only unfinished internal snapshot/conversion blobs. The app
    /// calls this once from a detached startup task before the first live
    /// preparation, so app initialization remains free of filesystem I/O and
    /// files left by a crash cannot permanently consume cache space.
    @discardableResult
    public static func pruneOrphanedTemporaryFiles(in cacheDirectory: URL) throws -> Int {
        try pruneOrphanedTemporaryFiles(
            in: cacheDirectory,
            maximumDirectoryEntries: maximumPruneDirectoryEntries
        )
    }

    /// Internal test seam for proving that crash-recovery maintenance remains
    /// bounded without creating thousands of filesystem fixtures.
    @discardableResult
    static func pruneOrphanedTemporaryFiles(
        in cacheDirectory: URL,
        maximumDirectoryEntries: Int
    ) throws -> Int {
        guard FileManager.default.fileExists(atPath: cacheDirectory.path) else { return 0 }
        return try SafeWebMediaCacheDirectory(url: cacheDirectory)
            .removeOrphanedTemporaryFiles(maximumDirectoryEntries: maximumDirectoryEntries)
    }

    public func prepare(
        source: URL,
        cacheDirectory: URL,
        timeout: Duration = Self.defaultTimeout
    ) async throws -> PreparedWebMedia {
        let budget = try PreparationBudget(timeout: timeout)
        let directory = try SafeWebMediaCacheDirectory(url: cacheDirectory)
        let sourceByteCount = try WebMediaDiskReservationManager.regularFileByteCount(
            at: source,
            maximumBytes: Self.maximumSourceBytes
        )
        let diskReservations = WebMediaDiskReservationManager.shared
        let diskReservation = try diskReservations.acquire(
            directory: directory.url,
            bytes: sourceByteCount
        )
        defer { diskReservations.release(diskReservation) }
        let snapshot = try await makeSourceSnapshot(
            source: source,
            directory: directory,
            maximumBytes: sourceByteCount,
            budget: budget
        )
        defer { snapshot.file.cleanup() }

        guard LocalMediaInputPolicy.allowsSelfContainedMedia(
            fileHandle: snapshot.file.fileHandle,
            declaredPathExtension: source.pathExtension
        ) else {
            throw WebMediaPreparationError.referencedMediaNotSupported
        }

        let inputReport = try await inspect(snapshot.file, budget: budget)
        let kind: PreparedWebMediaKind
        if inputReport.preferredVideoStreamIndex != nil {
            kind = .video
        } else if inputReport.preferredAudioStreamIndex != nil {
            kind = .audio
        } else {
            throw WebMediaPreparationError.unsupportedSource
        }
        try validateSource(inputReport, as: kind)
        let requiresAuthoredAudio = kind == .video
            && inputReport.preferredAudioStreamIndex != nil

        let cacheKey = WebMediaCacheKey(
            sourceContentHash: snapshot.contentHash,
            kind: kind
        )
        if let existing = try directory.openExisting(
            named: cacheKey.fileName,
            maximumBytes: maximumBytes(for: kind),
            removeOnCleanup: false
        ) {
            let cachedReport: MediaProbeReport
            let observedPacketStreams: Set<Int>
            do {
                cachedReport = try await inspect(
                    existing,
                    budget: budget
                )
                observedPacketStreams = try await observedPacketStreamIndices(
                    in: existing,
                    report: cachedReport,
                    as: kind,
                    budget: budget
                )
                try validate(
                    cachedReport,
                    as: kind,
                    requiresAuthoredAudio: requiresAuthoredAudio,
                    observedPacketStreams: observedPacketStreams
                )
                try existing.validate(maximumBytes: maximumBytes(for: kind))
            } catch is CancellationError {
                throw CancellationError()
            } catch WebMediaPreparationError.timedOut {
                throw WebMediaPreparationError.timedOut
            } catch {
                throw WebMediaPreparationError.invalidExistingCache(cacheKey.fileName)
            }
            return PreparedWebMedia(
                kind: kind,
                url: existing.url,
                sourceContentHash: snapshot.contentHash,
                cacheKey: cacheKey,
                probeReport: cachedReport,
                reusedCachedOutput: true
            )
        }

        let outputFileLimit: UInt64
        switch kind {
        case .video:
            outputFileLimit = VideoConverter.maximumOutputBytes(for: inputReport)
        case .audio:
            outputFileLimit = Self.maximumAudioOutputBytes(for: inputReport)
        }
        try diskReservations.resize(
            token: diskReservation,
            directory: directory.url,
            bytes: outputFileLimit
        )

        let candidate: PinnedWebMediaCacheFile
        let convertedReport: MediaProbeReport
        switch kind {
        case .video:
            (candidate, convertedReport) = try await prepareVideo(
                snapshot: snapshot.file,
                requiresAuthoredAudio: requiresAuthoredAudio,
                directory: directory,
                budget: budget
            )
        case .audio:
            guard let audioStreamIndex = inputReport.preferredAudioStreamIndex else {
                throw WebMediaPreparationError.unsupportedSource
            }
            let stream = inputReport.streams.first { $0.index == audioStreamIndex }
            (candidate, convertedReport) = try await prepareAudio(
                snapshot: snapshot.file,
                audioStreamIndex: audioStreamIndex,
                sourceChannels: stream?.channels,
                outputFileLimit: outputFileLimit,
                directory: directory,
                budget: budget
            )
        }
        defer { candidate.cleanup() }

        try budget.check()
        let published = try directory.publish(candidate, as: cacheKey.fileName)
        if published.installed {
            return PreparedWebMedia(
                kind: kind,
                url: published.file.url,
                sourceContentHash: snapshot.contentHash,
                cacheKey: cacheKey,
                probeReport: convertedReport,
                reusedCachedOutput: false
            )
        }

        let racedReport: MediaProbeReport
        let racedObservedPacketStreams: Set<Int>
        do {
            racedReport = try await inspect(
                published.file,
                budget: budget
            )
            racedObservedPacketStreams = try await observedPacketStreamIndices(
                in: published.file,
                report: racedReport,
                as: kind,
                budget: budget
            )
            try validate(
                racedReport,
                as: kind,
                requiresAuthoredAudio: requiresAuthoredAudio,
                observedPacketStreams: racedObservedPacketStreams
            )
            try published.file.validate(maximumBytes: maximumBytes(for: kind))
        } catch is CancellationError {
            throw CancellationError()
        } catch WebMediaPreparationError.timedOut {
            throw WebMediaPreparationError.timedOut
        } catch {
            throw WebMediaPreparationError.invalidExistingCache(cacheKey.fileName)
        }
        return PreparedWebMedia(
            kind: kind,
            url: published.file.url,
            sourceContentHash: snapshot.contentHash,
            cacheKey: cacheKey,
            probeReport: racedReport,
            reusedCachedOutput: true
        )
    }

    static func audioConversionArguments(
        inputPath: String,
        audioStreamIndex: Int,
        sourceChannels: Int?,
        outputPath: String = descriptorOutputURL
    ) -> [String] {
        let channelCount = min(2, max(1, sourceChannels ?? 2))
        var arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-y"
        ]
        arguments.append(contentsOf: FFmpegLocalMediaInputPolicy.arguments(inputPath: inputPath))
        if inputPath == "fd:" {
            arguments.append(contentsOf: ["-fd", Self.inputDescriptorToken])
        }
        arguments.append(contentsOf: [
            "-i", inputPath,
            "-map_metadata", "0",
            "-map_chapters", "-1",
            "-map", "0:\(audioStreamIndex)",
            "-vn",
            "-sn",
            "-dn",
            "-c:a", "aac",
            "-profile:a", "aac_low",
            "-b:a", "192k",
            "-ar", "48000",
            "-ac", String(channelCount),
            "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
            "-f", "mp4",
            outputPath
        ])
        return arguments
    }

    /// Enforces the snapshot byte ceiling incrementally. The source descriptor
    /// can keep yielding bytes after its initial `stat` (for example when an
    /// imported file is concurrently appended), so checking only the opening
    /// size would allow the temporary cache copy to grow until disk exhaustion.
    static func validatedSnapshotByteCount(
        current: UInt64,
        adding count: Int,
        maximum: UInt64
    ) throws -> UInt64 {
        guard count >= 0 else {
            throw WebMediaPreparationError.unsafeSource("invalid read length")
        }
        let (total, overflow) = current.addingReportingOverflow(UInt64(count))
        guard !overflow, total <= maximum else {
            throw WebMediaPreparationError.sourceTooLarge(
                overflow ? UInt64.max : total,
                maximum
            )
        }
        return total
    }

    static func maximumAudioOutputBytes(for report: MediaProbeReport) -> UInt64 {
        let selectedStreamDuration = report.preferredAudioStreamIndex.flatMap { index in
            report.streams.first(where: { $0.index == index })?.duration
        }
        guard let duration = [report.format?.duration, selectedStreamDuration]
            .compactMap({ $0.flatMap(Double.init) })
            .filter({ $0.isFinite && $0 > 0 })
            .max() else {
            return maximumAudioBytes
        }
        let payloadBytes = duration * (192_000.0 / 8.0)
        let estimatedBytes = payloadBytes * 1.25 + Double(16 * 1_024 * 1_024)
        guard estimatedBytes.isFinite,
              estimatedBytes > 0,
              estimatedBytes < Double(maximumAudioBytes) else {
            return maximumAudioBytes
        }
        return min(maximumAudioBytes, UInt64(estimatedBytes.rounded(.up)))
    }

    private func prepareVideo(
        snapshot: PinnedWebMediaCacheFile,
        requiresAuthoredAudio: Bool,
        directory: SafeWebMediaCacheDirectory,
        budget: PreparationBudget
    ) async throws -> (PinnedWebMediaCacheFile, MediaProbeReport) {
        try snapshot.validate(maximumBytes: Self.maximumSourceBytes)
        let candidateName = directory.uniqueCandidateName(pathExtension: "mp4")
        let candidateURL = directory.url.appending(path: candidateName)

        let remaining = try budget.remaining()
        let converter = videoConverter
        do {
            try await runBounded(by: remaining) {
                try await converter.convertToPlayableVideo(
                    input: snapshot.fileHandle,
                    output: candidateURL,
                    timeout: remaining
                )
            }
        } catch ConversionError.outputHasNoVideo,
                ConversionError.outputHasNoUsableAudio {
            // The generic converter validates its pending MP4 before commit.
            // Normalize those output-shape failures to this pipeline's stable
            // public error instead of leaking a lower-level implementation
            // detail to Web wallpaper callers.
            throw WebMediaPreparationError.invalidConvertedOutput
        }
        try budget.check()
        try snapshot.validate(maximumBytes: Self.maximumSourceBytes)
        guard let candidate = try directory.openExisting(
            named: candidateName,
            maximumBytes: Self.maximumVideoBytes,
            removeOnCleanup: true
        ) else {
            throw WebMediaPreparationError.invalidConvertedOutput
        }
        do {
            let report = try await inspect(candidate, budget: budget)
            let observedPacketStreams = try await observedPacketStreamIndices(
                in: candidate,
                report: report,
                as: .video,
                budget: budget
            )
            try validate(
                report,
                as: .video,
                requiresAuthoredAudio: requiresAuthoredAudio,
                observedPacketStreams: observedPacketStreams
            )
            try candidate.validate(maximumBytes: Self.maximumVideoBytes)
            return (candidate, report)
        } catch {
            candidate.cleanup()
            throw error
        }
    }

    private func prepareAudio(
        snapshot: PinnedWebMediaCacheFile,
        audioStreamIndex: Int,
        sourceChannels: Int?,
        outputFileLimit: UInt64,
        directory: SafeWebMediaCacheDirectory,
        budget: PreparationBudget
    ) async throws -> (PinnedWebMediaCacheFile, MediaProbeReport) {
        guard let ffmpeg = resolver.resolve(.ffmpeg).path else {
            throw ConversionError.ffmpegNotFound
        }
        try snapshot.rewind()
        let candidate = try directory.createTemporaryFile(
            prefix: ".web-media-audio",
            pathExtension: "m4a"
        )
        do {
            let processTimeout = try budget.remaining()
            let errors = Pipe()
            let errorReader = BoundedPipeReader(handle: errors.fileHandleForReading)
            errorReader.start()
            let child: SupervisedChildProcess
            do {
                child = try SupervisedChildProcess.spawn(
                    executable: URL(filePath: ffmpeg),
                    arguments: Self.audioConversionArguments(
                        inputPath: "fd:",
                        audioStreamIndex: audioStreamIndex,
                        sourceChannels: sourceChannels
                    ),
                    currentDirectory: URL(filePath: "/"),
                    standardOutput: candidate.fileHandle,
                    standardError: errors.fileHandleForWriting,
                    outputFileLimit: outputFileLimit,
                    inheritedFileDescriptors: [InheritedFileDescriptor(
                        fileHandle: snapshot.fileHandle,
                        argumentToken: Self.inputDescriptorToken
                    )]
                )
            } catch {
                try? errors.fileHandleForWriting.close()
                _ = errorReader.finish()
                throw ConversionError.ffmpegLaunchFailed
            }
            try? errors.fileHandleForWriting.close()

            let status: Int32
            let timedOut: Bool
            do {
                (status, timedOut) = try await child.waitUntilExit(
                    timeout: processTimeout
                )
            } catch {
                _ = errorReader.finish()
                throw error
            }
            let errorData = errorReader.finish()
            if timedOut { throw WebMediaPreparationError.timedOut }
            guard status == 0 else {
                throw ConversionError.ffmpegFailed(
                    status,
                    String(data: errorData, encoding: .utf8) ?? ""
                )
            }
            try budget.check()
            try snapshot.validate(maximumBytes: Self.maximumSourceBytes)
            try candidate.validate(maximumBytes: outputFileLimit)
            try candidate.rewind()
            let report = try await inspect(candidate, budget: budget)
            let observedPacketStreams = try await observedPacketStreamIndices(
                in: candidate,
                report: report,
                as: .audio,
                budget: budget
            )
            try validate(
                report,
                as: .audio,
                observedPacketStreams: observedPacketStreams
            )
            try candidate.validate(maximumBytes: outputFileLimit)
            return (candidate, report)
        } catch {
            candidate.cleanup()
            throw error
        }
    }

    private func inspect(
        _ file: PinnedWebMediaCacheFile,
        budget: PreparationBudget
    ) async throws -> MediaProbeReport {
        try file.rewind()
        let timeout = try budget.remaining(cappedAt: probeTimeout)
        do {
            let report = try await mediaProbe.inspect(
                file.fileHandle,
                timeout: timeout
            )
            try budget.check()
            return report
        } catch ConversionError.ffprobeTimedOut {
            throw WebMediaPreparationError.timedOut
        }
    }

    private func observedPacketStreamIndices(
        in file: PinnedWebMediaCacheFile,
        report: MediaProbeReport,
        as kind: PreparedWebMediaKind,
        budget: PreparationBudget
    ) async throws -> Set<Int> {
        guard LocalMediaStreamPolicy.allows(LocalMediaStreamPolicy.counts(in: report)) else {
            throw WebMediaPreparationError.invalidConvertedOutput
        }
        let requiredStreams: [MediaProbeReport.Stream]
        switch kind {
        case .video:
            let preferredVideo = report.preferredVideoStreamIndex.flatMap { index in
                report.streams.first(where: { $0.index == index })
            }
            requiredStreams = [preferredVideo].compactMap { $0 }
                + report.streams.filter { $0.codecType == "audio" }
        case .audio:
            requiredStreams = report.preferredAudioStreamIndex.flatMap { index in
                report.streams.first(where: { $0.index == index })
            }.map { [$0] } ?? []
        }

        var observed = Set<Int>()
        for stream in requiredStreams {
            let timeout = try budget.remaining(cappedAt: probeTimeout)
            do {
                if try await mediaProbe.hasObservedPacket(
                    file.fileHandle,
                    streamIndex: stream.index,
                    streamStartTime: stream.startTime,
                    timeout: timeout
                ) {
                    observed.insert(stream.index)
                }
                try budget.check()
            } catch ConversionError.ffprobeTimedOut {
                throw WebMediaPreparationError.timedOut
            }
        }
        return observed
    }

    private func validateSource(
        _ report: MediaProbeReport,
        as kind: PreparedWebMediaKind
    ) throws {
        let counts = LocalMediaStreamPolicy.counts(in: report)
        guard LocalMediaStreamPolicy.allows(counts) else {
            throw WebMediaPreparationError.sourceStreamCountExceeded(
                total: counts.total,
                video: counts.video,
                audio: counts.audio
            )
        }
        switch kind {
        case .video:
            guard let index = report.preferredVideoStreamIndex,
                  let stream = report.streams.first(where: { $0.index == index }) else {
                throw WebMediaPreparationError.unsupportedSource
            }
            try validateSourceVideoDimensions(stream)

            // VideoConverter preserves only the preferred authored audio
            // stream. Validate exactly that selected decoder; alternate tracks
            // remain inert and the stream-count policy bounds their metadata.
            if let audioStreamIndex = report.preferredAudioStreamIndex,
               let audioStream = report.streams.first(where: { $0.index == audioStreamIndex }) {
                try validateSourceAudioParameters(audioStream)
            }
        case .audio:
            guard let index = report.preferredAudioStreamIndex,
                  let stream = report.streams.first(where: { $0.index == index }) else {
                throw WebMediaPreparationError.unsupportedSource
            }
            try validateSourceAudioParameters(stream)
        }
    }

    private func validateSourceVideoDimensions(
        _ stream: MediaProbeReport.Stream
    ) throws {
        guard let width = stream.width,
              let height = stream.height,
              width > 0,
              height > 0 else {
            throw WebMediaPreparationError.invalidSourceVideoDimensions
        }
        let (pixels, overflow) = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        guard !overflow,
              width <= Self.maximumVideoDimension,
              height <= Self.maximumVideoDimension,
              pixels <= Self.maximumVideoPixels else {
            throw WebMediaPreparationError.sourceVideoDimensionsExceeded
        }
    }

    private func validateSourceAudioParameters(
        _ stream: MediaProbeReport.Stream
    ) throws {
        guard let channels = stream.channels,
              (1...Self.maximumSourceAudioChannels).contains(channels),
              let sampleRate = parsePositiveInteger(stream.sampleRate),
              sampleRate <= Self.maximumSourceAudioSampleRate else {
            throw WebMediaPreparationError.invalidSourceAudioParameters
        }
    }

    private func validate(
        _ report: MediaProbeReport,
        as kind: PreparedWebMediaKind,
        requiresAuthoredAudio: Bool = false,
        observedPacketStreams: Set<Int>
    ) throws {
        guard LocalMediaStreamPolicy.allows(LocalMediaStreamPolicy.counts(in: report)) else {
            throw WebMediaPreparationError.invalidConvertedOutput
        }
        let formatNames = Set(
            (report.format?.formatName ?? "")
                .lowercased()
                .split(separator: ",")
                .map(String.init)
        )
        guard !formatNames.isDisjoint(with: ["mov", "mp4", "m4a", "3gp", "3g2", "mj2"]) else {
            throw WebMediaPreparationError.invalidConvertedOutput
        }
        switch kind {
        case .video:
            guard let index = report.preferredVideoStreamIndex,
                  let stream = report.streams.first(where: { $0.index == index }),
                  stream.codecName?.lowercased() == "h264",
                  outputVideoDimensionsAreUsable(stream),
                  observedPacketStreams.contains(index) else {
                throw WebMediaPreparationError.invalidConvertedOutput
            }
            let audioStreams = report.streams.filter { $0.codecType == "audio" }
            guard (!requiresAuthoredAudio || !audioStreams.isEmpty),
                  audioStreams.allSatisfy({
                      outputVideoAudioIsUsable(
                          $0,
                          observedPacketStreams: observedPacketStreams
                      )
                  }) else {
                throw WebMediaPreparationError.invalidConvertedOutput
            }
        case .audio:
            guard report.preferredVideoStreamIndex == nil,
                  let index = report.preferredAudioStreamIndex,
                  let stream = report.streams.first(where: { $0.index == index }),
                  stream.codecName?.lowercased() == "aac",
                  (1...2).contains(stream.channels ?? 0),
                  parsePositiveInteger(stream.sampleRate) == 48_000,
                  hasPositiveDuration(report: report, stream: stream),
                  observedPacketStreams.contains(index) else {
                throw WebMediaPreparationError.invalidConvertedOutput
            }
        }
    }

    private func outputVideoDimensionsAreUsable(
        _ stream: MediaProbeReport.Stream
    ) -> Bool {
        guard let width = stream.width,
              let height = stream.height,
              width > 0,
              height > 0 else {
            return false
        }
        let (pixels, overflow) = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        return !overflow
            && width <= Self.maximumVideoDimension
            && height <= Self.maximumVideoDimension
            && pixels <= Self.maximumVideoPixels
    }

    private func outputVideoAudioIsUsable(
        _ stream: MediaProbeReport.Stream,
        observedPacketStreams: Set<Int>
    ) -> Bool {
        guard stream.codecName?.lowercased() == "aac",
              let channels = stream.channels,
              (1...8).contains(channels),
              let sampleRate = parsePositiveInteger(stream.sampleRate),
              (8_000...192_000).contains(sampleRate),
              observedPacketStreams.contains(stream.index) else {
            return false
        }
        return true
    }

    private func hasPositiveDuration(
        report: MediaProbeReport,
        stream: MediaProbeReport.Stream
    ) -> Bool {
        [report.format?.duration, stream.duration].contains { value in
            guard let value,
                  let duration = Double(value),
                  duration.isFinite else {
                return false
            }
            return duration > 0
        }
    }

    private func parsePositiveInteger(_ value: String?) -> Int? {
        guard let value,
              let number = Int(value),
              number > 0 else {
            return nil
        }
        return number
    }

    private func makeSourceSnapshot(
        source: URL,
        directory: SafeWebMediaCacheDirectory,
        maximumBytes: UInt64,
        budget: PreparationBudget
    ) async throws -> WebMediaSourceSnapshot {
        let worker = Task.detached(priority: .utility) {
            try WebMediaSourceSnapshot.make(
                source: source,
                directory: directory,
                maximumBytes: maximumBytes,
                budget: budget
            )
        }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    private func maximumBytes(for kind: PreparedWebMediaKind) -> UInt64 {
        switch kind {
        case .video: Self.maximumVideoBytes
        case .audio: Self.maximumAudioBytes
        }
    }

    private func runBounded<T: Sendable>(
        by timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WebMediaPreparationError.timedOut
            }
            guard let first = try await group.next() else {
                throw WebMediaPreparationError.timedOut
            }
            return first
        }
    }
}

private struct PreparationBudget: Sendable {
    private let deadline: ContinuousClock.Instant

    init(timeout: Duration) throws {
        guard timeout > .zero else { throw WebMediaPreparationError.timedOut }
        deadline = ContinuousClock.now.advanced(by: timeout)
    }

    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw WebMediaPreparationError.timedOut
        }
    }

    func remaining(cappedAt cap: Duration? = nil) throws -> Duration {
        try check()
        let value = ContinuousClock.now.duration(to: deadline)
        guard value > .zero else { throw WebMediaPreparationError.timedOut }
        if let cap { return min(value, cap) }
        return value
    }
}

private struct WebMediaSourceSnapshot: Sendable {
    let file: PinnedWebMediaCacheFile
    let contentHash: String

    static func make(
        source: URL,
        directory: SafeWebMediaCacheDirectory,
        maximumBytes: UInt64,
        budget: PreparationBudget
    ) throws -> WebMediaSourceSnapshot {
        let openedSource = try SafeWebMediaPath.openRegularFile(
            at: source,
            maximumBytes: maximumBytes
        )
        defer { Darwin.close(openedSource.descriptor) }
        let pathExtension = SafeWebMediaPath.safePathExtension(source.pathExtension)
        let snapshot = try directory.createTemporaryFile(
            prefix: ".web-media-source",
            pathExtension: pathExtension
        )
        do {
            var digest = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            var copiedBytes: UInt64 = 0
            while true {
                try budget.check()
                let count = Darwin.read(openedSource.descriptor, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw WebMediaPreparationError.unsafeSource(source.path)
                }
                copiedBytes = try WebMediaPreparer.validatedSnapshotByteCount(
                    current: copiedBytes,
                    adding: count,
                    maximum: maximumBytes
                )
                digest.update(data: Data(buffer.prefix(count)))
                try snapshot.fileHandle.write(contentsOf: buffer.prefix(count))
            }
            var after = stat()
            guard Darwin.fstat(openedSource.descriptor, &after) == 0,
                  SafeWebMediaPath.sameRevision(openedSource.attributes, after) else {
                throw WebMediaPreparationError.unsafeSource(source.path)
            }
            guard Darwin.fsync(snapshot.fileHandle.fileDescriptor) == 0 else {
                throw WebMediaPreparationError.unsafeCacheDirectory
            }
            try snapshot.validate(maximumBytes: maximumBytes)
            try snapshot.rewind()
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            return WebMediaSourceSnapshot(file: snapshot, contentHash: hash)
        } catch {
            snapshot.cleanup()
            throw error
        }
    }
}

private final class SafeWebMediaCacheDirectory: @unchecked Sendable {
    let url: URL
    let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t

    init(url: URL) throws {
        let standardized = url.standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: standardized,
                withIntermediateDirectories: true
            )
        } catch {
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        let opened = try SafeWebMediaPath.openDirectory(at: standardized)
        self.url = standardized
        descriptor = opened.descriptor
        device = opened.attributes.st_dev
        inode = opened.attributes.st_ino
    }

    deinit {
        Darwin.close(descriptor)
    }

    func uniqueCandidateName(pathExtension: String) -> String {
        ".web-media-video-\(UUID().uuidString).\(pathExtension)"
    }

    func removeOrphanedTemporaryFiles(maximumDirectoryEntries: Int) throws -> Int {
        guard maximumDirectoryEntries > 0, pathStillReferencesPinnedDirectory() else {
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        let internalPrefixes = [
            ".web-media-source-",
            ".web-media-video-",
            ".web-media-audio-"
        ]
        let duplicatedDescriptor = Darwin.dup(descriptor)
        guard duplicatedDescriptor >= 0 else {
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        guard let directoryStream = Darwin.fdopendir(duplicatedDescriptor) else {
            Darwin.close(duplicatedDescriptor)
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        defer { Darwin.closedir(directoryStream) }

        var removed = 0
        var examinedEntries = 0
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directoryStream) else {
                guard errno == 0 else {
                    throw WebMediaPreparationError.unsafeCacheDirectory
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { tuplePointer in
                tuplePointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
                ) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            examinedEntries += 1
            guard examinedEntries <= maximumDirectoryEntries else {
                throw WebMediaPreparationError.unsafeCacheDirectory
            }
            guard internalPrefixes.contains(where: name.hasPrefix) else { continue }
            guard SafeWebMediaPath.isSafeFileName(name) else { continue }
            var attributes = stat()
            let status = name.withCString {
                Darwin.fstatat(descriptor, $0, &attributes, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0, attributes.st_mode & S_IFMT == S_IFREG else { continue }
            if removeIfPresent(
                named: name,
                matching: (attributes.st_dev, attributes.st_ino)
            ) {
                removed += 1
            }
        }
        return removed
    }

    func createTemporaryFile(
        prefix: String,
        pathExtension: String
    ) throws -> PinnedWebMediaCacheFile {
        guard pathStillReferencesPinnedDirectory() else {
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        let safeExtension = SafeWebMediaPath.safePathExtension(pathExtension)
        let name = "\(prefix)-\(UUID().uuidString).\(safeExtension)"
        let fileDescriptor = name.withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard fileDescriptor >= 0 else {
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        do {
            return try makePinnedFile(
                descriptor: fileDescriptor,
                name: name,
                maximumBytes: 0,
                permitsEmpty: true,
                removeOnCleanup: true
            )
        } catch {
            var attributes = stat()
            let identity: (device: dev_t, inode: ino_t)?
            if Darwin.fstat(fileDescriptor, &attributes) == 0,
               attributes.st_mode & S_IFMT == S_IFREG {
                identity = (attributes.st_dev, attributes.st_ino)
            } else {
                identity = nil
            }
            Darwin.close(fileDescriptor)
            if let identity {
                removeIfPresent(named: name, matching: identity)
            }
            throw error
        }
    }

    func openExisting(
        named name: String,
        maximumBytes: UInt64,
        removeOnCleanup: Bool
    ) throws -> PinnedWebMediaCacheFile? {
        guard SafeWebMediaPath.isSafeFileName(name), pathStillReferencesPinnedDirectory() else {
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        let fileDescriptor = name.withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        if fileDescriptor < 0, errno == ENOENT { return nil }
        guard fileDescriptor >= 0 else {
            throw WebMediaPreparationError.invalidExistingCache(name)
        }
        do {
            return try makePinnedFile(
                descriptor: fileDescriptor,
                name: name,
                maximumBytes: maximumBytes,
                permitsEmpty: false,
                removeOnCleanup: removeOnCleanup
            )
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    func publish(
        _ candidate: PinnedWebMediaCacheFile,
        as finalName: String
    ) throws -> (file: PinnedWebMediaCacheFile, installed: Bool) {
        guard candidate.belongs(to: self),
              SafeWebMediaPath.isSafeFileName(finalName),
              pathStillReferencesPinnedDirectory(),
              candidate.stillReferencesPinnedFile(),
              Darwin.fsync(candidate.fileHandle.fileDescriptor) == 0 else {
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        let status = candidate.name.withCString { sourceName in
            finalName.withCString { destinationName in
                Darwin.linkat(descriptor, sourceName, descriptor, destinationName, 0)
            }
        }
        if status == 0 {
            _ = Darwin.fsync(descriptor)
            guard pathStillReferencesPinnedDirectory(),
                  let installed = try openExisting(
                    named: finalName,
                    maximumBytes: candidate.byteSize,
                    removeOnCleanup: false
                  ), installed.device == candidate.device,
                  installed.inode == candidate.inode else {
                removeIfPresent(
                    named: finalName,
                    matching: (candidate.device, candidate.inode)
                )
                throw WebMediaPreparationError.unsafeCacheDirectory
            }
            return (installed, true)
        }
        guard errno == EEXIST,
              let existing = try openExisting(
                named: finalName,
                maximumBytes: max(
                    WebMediaPreparer.maximumVideoBytes,
                    WebMediaPreparer.maximumAudioBytes
                ),
                removeOnCleanup: false
              ) else {
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        return (existing, false)
    }

    @discardableResult
    func removeIfPresent(
        named name: String,
        matching identity: (device: dev_t, inode: ino_t)?
    ) -> Bool {
        guard SafeWebMediaPath.isSafeFileName(name) else { return false }
        var attributes = stat()
        let status = name.withCString {
            Darwin.fstatat(descriptor, $0, &attributes, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              identity.map({ attributes.st_dev == $0.device && attributes.st_ino == $0.inode }) ?? true else {
            return false
        }
        return name.withCString { Darwin.unlinkat(descriptor, $0, 0) } == 0
    }

    func pathStillReferencesPinnedDirectory() -> Bool {
        var attributes = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &attributes)
        }
        return status == 0
            && attributes.st_mode & S_IFMT == S_IFDIR
            && attributes.st_dev == device
            && attributes.st_ino == inode
    }

    private func makePinnedFile(
        descriptor fileDescriptor: Int32,
        name: String,
        maximumBytes: UInt64,
        permitsEmpty: Bool,
        removeOnCleanup: Bool
    ) throws -> PinnedWebMediaCacheFile {
        var attributes = stat()
        guard Darwin.fstat(fileDescriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size >= 0,
              (permitsEmpty || attributes.st_size > 0),
              maximumBytes == 0 || UInt64(attributes.st_size) <= maximumBytes,
              pathStillReferencesPinnedDirectory() else {
            throw WebMediaPreparationError.invalidExistingCache(name)
        }
        return PinnedWebMediaCacheFile(
            directory: self,
            name: name,
            fileHandle: FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true),
            device: attributes.st_dev,
            inode: attributes.st_ino,
            removeOnCleanup: removeOnCleanup
        )
    }
}

private final class PinnedWebMediaCacheFile: @unchecked Sendable {
    let fileHandle: FileHandle
    let name: String
    let device: dev_t
    let inode: ino_t
    private let directory: SafeWebMediaCacheDirectory
    private let removeOnCleanup: Bool
    private let lock = NSLock()
    private var cleaned = false

    init(
        directory: SafeWebMediaCacheDirectory,
        name: String,
        fileHandle: FileHandle,
        device: dev_t,
        inode: ino_t,
        removeOnCleanup: Bool
    ) {
        self.directory = directory
        self.name = name
        self.fileHandle = fileHandle
        self.device = device
        self.inode = inode
        self.removeOnCleanup = removeOnCleanup
    }

    deinit {
        cleanup()
    }

    var url: URL { directory.url.appending(path: name) }

    var byteSize: UInt64 {
        var attributes = stat()
        guard Darwin.fstat(fileHandle.fileDescriptor, &attributes) == 0,
              attributes.st_size >= 0 else { return 0 }
        return UInt64(attributes.st_size)
    }

    func belongs(to directory: SafeWebMediaCacheDirectory) -> Bool {
        self.directory === directory
    }

    func rewind() throws {
        guard Darwin.lseek(fileHandle.fileDescriptor, 0, SEEK_SET) != -1 else {
            throw WebMediaPreparationError.invalidConvertedOutput
        }
    }

    func validate(maximumBytes: UInt64) throws {
        var attributes = stat()
        guard Darwin.fstat(fileHandle.fileDescriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_dev == device,
              attributes.st_ino == inode,
              attributes.st_size > 0,
              UInt64(attributes.st_size) <= maximumBytes,
              stillReferencesPinnedFile() else {
            throw WebMediaPreparationError.invalidConvertedOutput
        }
    }

    func stillReferencesPinnedFile() -> Bool {
        guard directory.pathStillReferencesPinnedDirectory() else { return false }
        var attributes = stat()
        let status = name.withCString {
            Darwin.fstatat(directory.descriptor, $0, &attributes, AT_SYMLINK_NOFOLLOW)
        }
        return status == 0
            && attributes.st_mode & S_IFMT == S_IFREG
            && attributes.st_dev == device
            && attributes.st_ino == inode
    }

    func cleanup() {
        lock.withLock {
            guard !cleaned else { return }
            cleaned = true
            try? fileHandle.close()
            if removeOnCleanup {
                directory.removeIfPresent(
                    named: name,
                    matching: (device, inode)
                )
            }
        }
    }
}

private enum SafeWebMediaPath {
    struct OpenedFile {
        let descriptor: Int32
        let attributes: stat
    }

    static func openRegularFile(at url: URL, maximumBytes: UInt64) throws -> OpenedFile {
        let standardized = url.standardizedFileURL
        var before = stat()
        let inspected = standardized.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &before)
        }
        guard inspected == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0 else {
            throw WebMediaPreparationError.unsafeSource(standardized.path)
        }
        guard UInt64(before.st_size) <= maximumBytes else {
            throw WebMediaPreparationError.sourceTooLarge(
                UInt64(before.st_size),
                maximumBytes
            )
        }
        let resolved = try canonicalPath(for: standardized, sourceErrorPath: standardized.path)
        let resolvedURL = URL(filePath: resolved)
        let parent = try openCanonicalDirectory(resolvedURL.deletingLastPathComponent())
        defer { Darwin.close(parent.descriptor) }
        let name = resolvedURL.lastPathComponent
        guard isSafeFileName(name) else {
            throw WebMediaPreparationError.unsafeSource(standardized.path)
        }
        let descriptor = name.withCString {
            Darwin.openat(
                parent.descriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            throw WebMediaPreparationError.unsafeSource(standardized.path)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              after.st_mode & S_IFMT == S_IFREG,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_size == before.st_size else {
            Darwin.close(descriptor)
            throw WebMediaPreparationError.unsafeSource(standardized.path)
        }
        return OpenedFile(descriptor: descriptor, attributes: after)
    }

    static func openDirectory(at url: URL) throws -> OpenedFile {
        let standardized = url.standardizedFileURL
        var before = stat()
        let inspected = standardized.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &before)
        }
        guard inspected == 0, before.st_mode & S_IFMT == S_IFDIR else {
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        let resolved = try canonicalPath(for: standardized, sourceErrorPath: nil)
        let opened = try openCanonicalDirectory(URL(filePath: resolved))
        guard opened.attributes.st_dev == before.st_dev,
              opened.attributes.st_ino == before.st_ino else {
            Darwin.close(opened.descriptor)
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        return opened
    }

    static func sameRevision(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    static func safePathExtension(_ value: String) -> String {
        let lowered = value.lowercased()
        guard !lowered.isEmpty,
              lowered.utf8.count <= 16,
              lowered.unicodeScalars.allSatisfy({
                $0.isASCII && CharacterSet.alphanumerics.contains($0)
              }) else {
            return "bin"
        }
        return lowered
    }

    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\u{0}")
    }

    private static func canonicalPath(
        for url: URL,
        sourceErrorPath: String?
    ) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path, Darwin.realpath(path, &buffer) != nil else { return nil }
            return String(
                decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
        }
        guard let resolved,
              allowedCanonicalPath(original: url.path, resolved: resolved) else {
            if let sourceErrorPath {
                throw WebMediaPreparationError.unsafeSource(sourceErrorPath)
            }
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        return resolved
    }

    private static func openCanonicalDirectory(_ url: URL) throws -> OpenedFile {
        let components = url.pathComponents
        guard components.first == "/" else {
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        for component in components.dropFirst() where component != "/" {
            let next = component.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard next >= 0 else {
                Darwin.close(descriptor)
                throw WebMediaPreparationError.unsafeCacheDirectory
            }
            Darwin.close(descriptor)
            descriptor = next
        }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(descriptor)
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        return OpenedFile(descriptor: descriptor, attributes: attributes)
    }

    private static func allowedCanonicalPath(original: String, resolved: String) -> Bool {
        if original == resolved { return true }
        for alias in ["/var", "/tmp", "/etc"]
        where original == alias || original.hasPrefix(alias + "/") {
            if resolved == "/private" + original { return true }
        }
        return false
    }
}
