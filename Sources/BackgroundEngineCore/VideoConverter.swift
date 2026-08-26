import Darwin
import Foundation

/// Bounds container metadata before a conversion process can allocate one
/// decoder per authored track. Wallpaper playback uses one preferred video
/// and at most one preferred audio stream, so unusually broad track layouts
/// are rejected instead of being handed to FFmpeg.
struct LocalMediaStreamCounts: Equatable, Sendable {
    let total: Int
    let video: Int
    let audio: Int
}

enum LocalMediaStreamPolicy {
    static let maximumTotalStreamCount = 64
    static let maximumVideoStreamCount = 8
    static let maximumAudioStreamCount = 16
    static let maximumVideoDimension = 16_384
    static let maximumVideoPixels: UInt64 = 67_108_864
    static let maximumAudioChannelCount = 32
    static let maximumAudioSampleRate = 384_000

    static func counts(in report: MediaProbeReport) -> LocalMediaStreamCounts {
        LocalMediaStreamCounts(
            total: report.streams.count,
            video: report.streams.count(where: { $0.codecType == "video" }),
            audio: report.streams.count(where: { $0.codecType == "audio" })
        )
    }

    static func allows(_ counts: LocalMediaStreamCounts) -> Bool {
        counts.total <= maximumTotalStreamCount
            && counts.video <= maximumVideoStreamCount
            && counts.audio <= maximumAudioStreamCount
    }
}

/// Internal cross-target recovery contract shared by the Swift Package app
/// and the standalone Xcode targets. SPI keeps it out of the supported public
/// Core API while still compiling when Xcode does not supply `-package-name`.
@_spi(FFmpegRecovery)
public enum FFmpegVideoEncoder: Sendable {
    case videoToolboxH264
    case softwareMPEG4

    public func arguments(bitRate: String) -> [String] {
        switch self {
        case .videoToolboxH264:
            return [
                "-c:v", "h264_videotoolbox",
                "-allow_sw", "1",
                "-b:v", bitRate,
                "-pix_fmt", "yuv420p"
            ]
        case .softwareMPEG4:
            return [
                "-c:v", "mpeg4",
                "-tag:v", "mp4v",
                "-b:v", bitRate,
                "-pix_fmt", "yuv420p"
            ]
        }
    }

    /// Returns `true` only for an FFmpeg diagnostic that pairs a known
    /// VideoToolbox session failure with its stable OSStatus value. Keeping
    /// both checks on the same line prevents an unrelated FFmpeg error from
    /// silently changing codecs merely because another log line mentions one
    /// of these numbers.
    public static func shouldUseSoftwareFallback(stderr: String) -> Bool {
        let failurePhrases = [
            "cannot create compression session",
            "cannot prepare encoder",
            "error encoding frame"
        ]
        let stableStatusCodes = [
            "-12903", // kVTInvalidSessionErr
            "-12908", // kVTCouldNotFindVideoEncoderErr
            "-12912", // kVTVideoEncoderMalfunctionErr
            "-12915", // kVTVideoEncoderNotAvailableNowErr
            "-17691"  // kVTVideoEncoderSessionMalfunctionErr
        ]

        return stderr.split(whereSeparator: \.isNewline).contains { rawLine in
            let line = rawLine.lowercased()
            guard failurePhrases.contains(where: line.contains) else { return false }
            return stableStatusCodes.contains { containsStatusCode($0, in: line) }
        }
    }

    private static func containsStatusCode(_ code: String, in line: String) -> Bool {
        var searchStart = line.startIndex
        while searchStart < line.endIndex,
              let range = line.range(
                of: code,
                range: searchStart..<line.endIndex
              ) {
            let isPrefixedByDigit = range.lowerBound > line.startIndex
                && line[line.index(before: range.lowerBound)].isNumber
            let isSuffixedByDigit = range.upperBound < line.endIndex
                && line[range.upperBound].isNumber
            if !isPrefixedByDigit, !isSuffixedByDigit { return true }
            searchStart = range.upperBound
        }
        return false
    }
}

public struct VideoConverter: Sendable {
    public static let defaultTimeout: Duration = .seconds(7_200)
    public static let maximumConvertedBytes: UInt64 = 20 * 1_024 * 1_024 * 1_024
    static let previousConversionRecipeIDs = [
        "video-2-even-dar",
        "video-3-fragmented-mp4-even-dar",
        "video-4-default-stream-fragmented-mp4-even-dar",
        "video-5-videotoolbox-mpeg4-fallback",
        "video-6-self-contained-input-videotoolbox-mpeg4-fallback"
    ]
    public static let conversionRecipeID = "video-7-preferred-audio-self-contained-input-videotoolbox-mpeg4-fallback"
    public static let outdatedRecipeIssueCode = "video_conversion_recipe_outdated"

    /// H.264 with a 4:2:0 pixel format requires even encoded dimensions.
    /// Scaling up by at most one pixel per axis keeps the complete frame and
    /// lets FFmpeg adjust sample aspect ratio so display aspect ratio remains
    /// identical. The previous truncating filter cropped the final row/column.
    static let evenDimensionFilter =
        "scale=ceil(iw/2)*2:ceil(ih/2)*2:flags=lanczos"

    private static let inputDescriptorToken = "__BACKGROUND_ENGINE_VIDEO_INPUT_FD__"

    /// Uses FFmpeg's pipe protocol to write through the stdout descriptor that
    /// the supervisor already pins to the pending output file. Opening
    /// `/dev/fd/1` through FFmpeg's file protocol requests create/truncate
    /// semantics that Darwin rejects for a devfs descriptor with `EPERM`.
    static let descriptorOutputURL = "pipe:1"

    private let resolver: MediaToolResolver

    public init(resolver: MediaToolResolver = MediaToolResolver()) {
        self.resolver = resolver
    }

    public func ffmpegPath() -> String? {
        resolver.resolve(.ffmpeg).path
    }

    public func ffprobePath() -> String? {
        resolver.resolve(.ffprobe).path
    }

    public func convertToPlayableVideo(input: URL, output: URL) throws {
        guard let ffmpeg = ffmpegPath() else {
            throw ConversionError.ffmpegNotFound
        }
        let inputFile = try SecureLocalMediaFile.open(input)
        defer { try? inputFile.close() }
        guard LocalMediaInputPolicy.allowsSelfContainedMedia(
            fileHandle: inputFile,
            declaredPathExtension: input.pathExtension
        ) else {
            throw ConversionError.unsafeReferencedInput
        }
        let inputReport = try MediaProbe(resolver: resolver).inspect(inputFile, timeout: 10)
        let selection = try Self.validatedInputSelection(inputReport)
        let outputFileLimit = Self.maximumOutputBytes(for: inputReport)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.defaultTimeout)
        do {
            try performSynchronousAttempt(
                ffmpeg: ffmpeg,
                inputPath: "fd:",
                pinnedInput: inputFile,
                videoStreamIndex: selection.videoStreamIndex,
                audioStreamIndex: selection.audioStreamIndex,
                outputFileLimit: outputFileLimit,
                output: output,
                encoder: .videoToolboxH264,
                deadline: deadline,
                clock: clock
            )
        } catch let primaryError as ConversionError {
            guard Self.shouldRetryWithSoftwareEncoder(after: primaryError) else {
                throw primaryError
            }
            do {
                try performSynchronousAttempt(
                    ffmpeg: ffmpeg,
                    inputPath: "fd:",
                    pinnedInput: inputFile,
                    videoStreamIndex: selection.videoStreamIndex,
                    audioStreamIndex: selection.audioStreamIndex,
                    outputFileLimit: outputFileLimit,
                    output: output,
                    encoder: .softwareMPEG4,
                    deadline: deadline,
                    clock: clock
                )
            } catch let fallbackError as ConversionError {
                throw Self.combiningDiagnostics(
                    primary: primaryError,
                    fallback: fallbackError
                )
            }
        }
    }

    public func convertToPlayableVideo(
        input: URL,
        output: URL,
        timeout: Duration
    ) async throws {
        let inputFile = try SecureLocalMediaFile.open(input)
        defer { try? inputFile.close() }
        guard LocalMediaInputPolicy.allowsSelfContainedMedia(
            fileHandle: inputFile,
            declaredPathExtension: input.pathExtension
        ) else {
            throw ConversionError.unsafeReferencedInput
        }
        try await convertToPlayableVideo(
            inputPath: "fd:",
            pinnedInput: inputFile,
            output: output,
            timeout: timeout
        )
    }

    public func convertToPlayableVideo(
        input: PinnedVideoInput,
        output: URL,
        timeout: Duration
    ) async throws {
        guard LocalMediaInputPolicy.allowsSelfContainedMedia(
            fileHandle: input.fileHandle,
            declaredPathExtension: input.url.pathExtension
        ) else {
            throw ConversionError.unsafeReferencedInput
        }
        try await convertToPlayableVideo(
            inputPath: "fd:",
            pinnedInput: input.fileHandle,
            output: output,
            timeout: timeout
        )
    }

    /// Internal descriptor-bound entry point for other Core pipelines that
    /// already own a verified regular-file snapshot. Keeping the descriptor
    /// open across probe, both encoder attempts, and output validation ensures
    /// a same-user path replacement cannot change the bytes FFmpeg consumes.
    func convertToPlayableVideo(
        input: FileHandle,
        output: URL,
        timeout: Duration
    ) async throws {
        try await convertToPlayableVideo(
            inputPath: "fd:",
            pinnedInput: input,
            output: output,
            timeout: timeout
        )
    }

    private func convertToPlayableVideo(
        inputPath: String,
        pinnedInput: FileHandle?,
        output: URL,
        timeout: Duration
    ) async throws {
        guard let ffmpeg = ffmpegPath() else {
            throw ConversionError.ffmpegNotFound
        }
        try Task.checkCancellation()
        let inputReport: MediaProbeReport
        if let pinnedInput {
            inputReport = try await MediaProbe(resolver: resolver).inspect(
                pinnedInput,
                timeout: .seconds(10)
            )
        } else {
            inputReport = try await MediaProbe(resolver: resolver).inspect(
                URL(filePath: inputPath),
                timeout: .seconds(10)
            )
        }
        let selection = try Self.validatedInputSelection(inputReport)
        let outputFileLimit = Self.maximumOutputBytes(for: inputReport)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        do {
            try await performAsynchronousAttempt(
                ffmpeg: ffmpeg,
                inputPath: inputPath,
                pinnedInput: pinnedInput,
                videoStreamIndex: selection.videoStreamIndex,
                audioStreamIndex: selection.audioStreamIndex,
                outputFileLimit: outputFileLimit,
                output: output,
                encoder: .videoToolboxH264,
                deadline: deadline,
                clock: clock
            )
        } catch let primaryError as ConversionError {
            guard Self.shouldRetryWithSoftwareEncoder(after: primaryError) else {
                throw primaryError
            }
            try Task.checkCancellation()
            do {
                try await performAsynchronousAttempt(
                    ffmpeg: ffmpeg,
                    inputPath: inputPath,
                    pinnedInput: pinnedInput,
                    videoStreamIndex: selection.videoStreamIndex,
                    audioStreamIndex: selection.audioStreamIndex,
                    outputFileLimit: outputFileLimit,
                    output: output,
                    encoder: .softwareMPEG4,
                    deadline: deadline,
                    clock: clock
                )
            } catch let fallbackError as ConversionError {
                throw Self.combiningDiagnostics(
                    primary: primaryError,
                    fallback: fallbackError
                )
            }
        }
    }

    static func validatedInputSelection(
        _ report: MediaProbeReport
    ) throws -> (videoStreamIndex: Int, audioStreamIndex: Int?) {
        let counts = LocalMediaStreamPolicy.counts(in: report)
        guard LocalMediaStreamPolicy.allows(counts) else {
            throw ConversionError.inputStreamCountExceeded(
                total: counts.total,
                video: counts.video,
                audio: counts.audio
            )
        }
        guard let videoStreamIndex = report.preferredVideoStreamIndex,
              let videoStream = report.streams.first(where: { $0.index == videoStreamIndex }) else {
            throw ConversionError.inputHasNoVideo
        }
        guard let width = videoStream.width,
              let height = videoStream.height,
              width > 0,
              height > 0 else {
            throw ConversionError.invalidInputVideoDimensions
        }
        let (pixels, overflow) = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        guard !overflow,
              width <= LocalMediaStreamPolicy.maximumVideoDimension,
              height <= LocalMediaStreamPolicy.maximumVideoDimension,
              pixels <= LocalMediaStreamPolicy.maximumVideoPixels else {
            throw ConversionError.inputVideoDimensionsExceeded
        }

        let audioStreamIndex = report.preferredAudioStreamIndex
        if let audioStreamIndex,
           let audioStream = report.streams.first(where: { $0.index == audioStreamIndex }) {
            guard let channels = audioStream.channels,
                  (1...LocalMediaStreamPolicy.maximumAudioChannelCount).contains(channels),
                  let sampleRate = positiveInteger(audioStream.sampleRate),
                  sampleRate <= LocalMediaStreamPolicy.maximumAudioSampleRate else {
                throw ConversionError.invalidInputAudioParameters
            }
        }
        return (videoStreamIndex, audioStreamIndex)
    }

    private static func positiveInteger(_ value: String?) -> Int? {
        guard let value,
              !value.isEmpty,
              value.allSatisfy(\.isNumber),
              let parsed = Int(value),
              parsed > 0 else {
            return nil
        }
        return parsed
    }

    /// Returns a fail-closed supervisor file limit sized from the longest
    /// declared stream duration, the configured 12 Mbps video rate, optional
    /// 192 kbps audio, and container/headroom overhead. Missing or implausible
    /// duration metadata falls back to the absolute 20 GiB product ceiling.
    public static func maximumOutputBytes(for report: MediaProbeReport) -> UInt64 {
        let durations = [report.format?.duration]
            + report.streams.map(\.duration)
        guard let duration = durations
            .compactMap({ $0.flatMap(Double.init) })
            .filter({ $0.isFinite && $0 > 0 })
            .max() else {
            return maximumConvertedBytes
        }

        let videoBitsPerSecond = 12_000_000.0
        let audioBitsPerSecond = report.preferredAudioStreamIndex == nil ? 0 : 192_000.0
        let payloadBytes = duration * (videoBitsPerSecond + audioBitsPerSecond) / 8
        let estimatedBytes = payloadBytes * 1.25 + Double(16 * 1_024 * 1_024)
        guard estimatedBytes.isFinite,
              estimatedBytes > 0,
              estimatedBytes < Double(maximumConvertedBytes) else {
            return maximumConvertedBytes
        }
        return min(maximumConvertedBytes, UInt64(estimatedBytes.rounded(.up)))
    }

    public static func conversionArguments(input: URL, output: URL) -> [String] {
        conversionArguments(
            inputPath: input.path,
            outputPath: output.path,
            videoMapSpecifier: "0:v:0",
            audioMapSpecifier: "0:a:0?",
            forceMP4Container: false
        )
    }

    static func conversionArguments(
        input: URL,
        output: URL,
        videoStreamIndex: Int,
        encoder: FFmpegVideoEncoder = .videoToolboxH264
    ) -> [String] {
        conversionArguments(
            inputPath: input.path,
            outputPath: output.path,
            videoMapSpecifier: "0:\(videoStreamIndex)",
            audioMapSpecifier: "0:a:0?",
            forceMP4Container: false,
            encoder: encoder
        )
    }

    static func conversionArguments(
        input: URL,
        output: URL,
        videoStreamIndex: Int,
        audioStreamIndex: Int?,
        encoder: FFmpegVideoEncoder = .videoToolboxH264
    ) -> [String] {
        conversionArguments(
            inputPath: input.path,
            outputPath: output.path,
            videoMapSpecifier: "0:\(videoStreamIndex)",
            audioMapSpecifier: audioStreamIndex.map { "0:\($0)" },
            forceMP4Container: false,
            encoder: encoder
        )
    }

    private static func conversionArguments(
        inputPath: String,
        outputPath: String,
        videoMapSpecifier: String,
        audioMapSpecifier: String?,
        forceMP4Container: Bool,
        encoder: FFmpegVideoEncoder = .videoToolboxH264
    ) -> [String] {
        var arguments = [
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
            "-map", videoMapSpecifier
        ])
        if let audioMapSpecifier {
            arguments.append(contentsOf: ["-map", audioMapSpecifier])
        }
        arguments.append(contentsOf: ["-vf", evenDimensionFilter])
        arguments.append(contentsOf: encoder.arguments(bitRate: "12M"))
        if audioMapSpecifier != nil {
            arguments.append(contentsOf: [
                "-c:a", "aac",
                "-b:a", "192k",
                "-ar", "48000",
                "-ac", "2"
            ])
        }
        if forceMP4Container {
            // `pipe:1` is deliberately non-seekable. The MP4 faststart second
            // pass requires seeking, while fragmented MP4 is written
            // sequentially without weakening the descriptor-bound output
            // handoff; the completed output is probed before it is committed.
            arguments.append(contentsOf: [
                "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
                "-f", "mp4"
            ])
        } else {
            arguments.append(contentsOf: ["-movflags", "+faststart"])
        }
        arguments.append(outputPath)
        return arguments
    }

    private func launchFFmpeg(
        at path: String,
        inputPath: String,
        pinnedInput: FileHandle?,
        videoStreamIndex: Int,
        audioStreamIndex: Int?,
        outputFileLimit: UInt64,
        output: PinnedVideoOutput,
        encoder: FFmpegVideoEncoder
    ) throws -> (SupervisedChildProcess, BoundedPipeReader) {
        let errors = Pipe()
        let errorReader = BoundedPipeReader(handle: errors.fileHandleForReading)
        errorReader.start()
        var inherited: [InheritedFileDescriptor] = []
        if let pinnedInput {
            inherited.insert(
                InheritedFileDescriptor(
                    fileHandle: pinnedInput,
                    argumentToken: Self.inputDescriptorToken
                ),
                at: 0
            )
        }
        do {
            let child = try SupervisedChildProcess.spawn(
                executable: URL(filePath: path),
                arguments: Self.conversionArguments(
                    inputPath: inputPath,
                    outputPath: Self.descriptorOutputURL,
                    videoMapSpecifier: "0:\(videoStreamIndex)",
                    audioMapSpecifier: audioStreamIndex.map { "0:\($0)" },
                    forceMP4Container: true,
                    encoder: encoder
                ),
                currentDirectory: URL(filePath: "/"),
                standardOutput: output.fileHandle,
                standardError: errors.fileHandleForWriting,
                outputFileLimit: outputFileLimit,
                inheritedFileDescriptors: inherited
            )
            try? errors.fileHandleForWriting.close()
            return (child, errorReader)
        } catch {
            try? errors.fileHandleForWriting.close()
            _ = errorReader.finish()
            throw ConversionError.ffmpegLaunchFailed
        }
    }

    private func validateFFmpegExit(status: Int32, errorData: Data) throws {
        guard status == 0 else {
            throw ConversionError.ffmpegFailed(
                status,
                String(data: errorData, encoding: .utf8) ?? ""
            )
        }
    }

    private func performSynchronousAttempt(
        ffmpeg: String,
        inputPath: String,
        pinnedInput: FileHandle?,
        videoStreamIndex: Int,
        audioStreamIndex: Int?,
        outputFileLimit: UInt64,
        output: URL,
        encoder: FFmpegVideoEncoder,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) throws {
        let remainingDuration = clock.now.duration(to: deadline)
        guard remainingDuration > .zero else { throw ConversionError.ffmpegTimedOut }
        if let pinnedInput, Darwin.lseek(pinnedInput.fileDescriptor, 0, SEEK_SET) == -1 {
            throw ConversionError.ffmpegLaunchFailed
        }
        let remaining = Self.timeInterval(from: remainingDuration)
        let pendingOutput = try PinnedVideoOutput(output: output)
        defer { pendingOutput.cleanup() }
        let (child, errorReader) = try launchFFmpeg(
            at: ffmpeg,
            inputPath: inputPath,
            pinnedInput: pinnedInput,
            videoStreamIndex: videoStreamIndex,
            audioStreamIndex: audioStreamIndex,
            outputFileLimit: outputFileLimit,
            output: pendingOutput,
            encoder: encoder
        )
        let (terminationStatus, timedOut) = child.waitUntilExit(timeout: remaining)
        let errorData = errorReader.finish()
        if timedOut { throw ConversionError.ffmpegTimedOut }
        try validateFFmpegExit(status: terminationStatus, errorData: errorData)
        try pendingOutput.validateRegularFile()
        try pendingOutput.rewind()
        let probe = MediaProbe(resolver: resolver)
        let report = try probe.inspect(
            pendingOutput.fileHandle,
            timeout: try Self.remainingValidationTimeInterval(deadline: deadline, clock: clock)
        )
        guard let outputVideoIndex = report.preferredVideoStreamIndex,
              let outputVideo = report.streams.first(where: { $0.index == outputVideoIndex }) else {
            throw ConversionError.outputHasNoVideo
        }
        if audioStreamIndex != nil, !Self.outputContainsUsableAudio(report) {
            throw ConversionError.outputHasNoUsableAudio
        }
        guard try probe.hasObservedPacket(
            pendingOutput.fileHandle,
            streamIndex: outputVideoIndex,
            streamStartTime: outputVideo.startTime,
            timeout: try Self.remainingValidationTimeInterval(deadline: deadline, clock: clock)
        ) else {
            throw ConversionError.outputHasNoVideo
        }
        if audioStreamIndex != nil {
            guard let outputAudioIndex = report.preferredAudioStreamIndex,
                  let outputAudio = report.streams.first(where: { $0.index == outputAudioIndex }),
                  try probe.hasObservedPacket(
                      pendingOutput.fileHandle,
                      streamIndex: outputAudioIndex,
                      streamStartTime: outputAudio.startTime,
                      timeout: try Self.remainingValidationTimeInterval(
                          deadline: deadline,
                          clock: clock
                      )
                  ) else {
                throw ConversionError.outputHasNoUsableAudio
            }
        }
        try pendingOutput.commit()
    }

    private func performAsynchronousAttempt(
        ffmpeg: String,
        inputPath: String,
        pinnedInput: FileHandle?,
        videoStreamIndex: Int,
        audioStreamIndex: Int?,
        outputFileLimit: UInt64,
        output: URL,
        encoder: FFmpegVideoEncoder,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async throws {
        try Task.checkCancellation()
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { throw ConversionError.ffmpegTimedOut }
        if let pinnedInput, Darwin.lseek(pinnedInput.fileDescriptor, 0, SEEK_SET) == -1 {
            throw ConversionError.ffmpegLaunchFailed
        }
        let pendingOutput = try PinnedVideoOutput(output: output)
        defer { pendingOutput.cleanup() }
        let (child, errorReader) = try launchFFmpeg(
            at: ffmpeg,
            inputPath: inputPath,
            pinnedInput: pinnedInput,
            videoStreamIndex: videoStreamIndex,
            audioStreamIndex: audioStreamIndex,
            outputFileLimit: outputFileLimit,
            output: pendingOutput,
            encoder: encoder
        )

        let terminationStatus: Int32
        let timedOut: Bool
        do {
            (terminationStatus, timedOut) = try await child.waitUntilExit(timeout: remaining)
        } catch {
            _ = errorReader.finish()
            throw error
        }
        let errorData = errorReader.finish()
        if timedOut { throw ConversionError.ffmpegTimedOut }
        try validateFFmpegExit(status: terminationStatus, errorData: errorData)
        try Task.checkCancellation()
        try pendingOutput.validateRegularFile()
        try pendingOutput.rewind()
        let probe = MediaProbe(resolver: resolver)
        let report = try await probe.inspect(
            pendingOutput.fileHandle,
            timeout: try Self.remainingValidationDuration(deadline: deadline, clock: clock)
        )
        guard let outputVideoIndex = report.preferredVideoStreamIndex,
              let outputVideo = report.streams.first(where: { $0.index == outputVideoIndex }) else {
            throw ConversionError.outputHasNoVideo
        }
        if audioStreamIndex != nil, !Self.outputContainsUsableAudio(report) {
            throw ConversionError.outputHasNoUsableAudio
        }
        guard try await probe.hasObservedPacket(
            pendingOutput.fileHandle,
            streamIndex: outputVideoIndex,
            streamStartTime: outputVideo.startTime,
            timeout: try Self.remainingValidationDuration(deadline: deadline, clock: clock)
        ) else {
            throw ConversionError.outputHasNoVideo
        }
        if audioStreamIndex != nil {
            guard let outputAudioIndex = report.preferredAudioStreamIndex,
                  let outputAudio = report.streams.first(where: { $0.index == outputAudioIndex }),
                  try await probe.hasObservedPacket(
                      pendingOutput.fileHandle,
                      streamIndex: outputAudioIndex,
                      streamStartTime: outputAudio.startTime,
                      timeout: try Self.remainingValidationDuration(
                          deadline: deadline,
                          clock: clock
                      )
                  ) else {
                throw ConversionError.outputHasNoUsableAudio
            }
        }
        try Task.checkCancellation()
        try pendingOutput.commit()
    }

    private static func remainingValidationTimeInterval(
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) throws -> TimeInterval {
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { throw ConversionError.ffmpegTimedOut }
        return min(10, timeInterval(from: remaining))
    }

    private static func remainingValidationDuration(
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) throws -> Duration {
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { throw ConversionError.ffmpegTimedOut }
        return min(.seconds(10), remaining)
    }

    private static func outputContainsUsableAudio(_ report: MediaProbeReport) -> Bool {
        guard let index = report.preferredAudioStreamIndex,
              let stream = report.streams.first(where: { $0.index == index }),
              stream.codecName?.lowercased() == "aac",
              (1...2).contains(stream.channels ?? 0),
              positiveInteger(stream.sampleRate) == 48_000 else {
            return false
        }
        return true
    }

    private static func shouldRetryWithSoftwareEncoder(
        after error: ConversionError
    ) -> Bool {
        guard case .ffmpegFailed(_, let stderr) = error else { return false }
        return FFmpegVideoEncoder.shouldUseSoftwareFallback(stderr: stderr)
    }

    private static func combiningDiagnostics(
        primary: ConversionError,
        fallback: ConversionError
    ) -> ConversionError {
        guard case .ffmpegFailed(let primaryStatus, let primaryDetails) = primary,
              case .ffmpegFailed(let fallbackStatus, let fallbackDetails) = fallback else {
            return fallback
        }
        return .ffmpegFailed(
            fallbackStatus,
            """
            VideoToolbox attempt exited with status \(primaryStatus):
            \(primaryDetails.trimmingCharacters(in: .whitespacesAndNewlines))
            Software MPEG-4 fallback exited with status \(fallbackStatus):
            \(fallbackDetails.trimmingCharacters(in: .whitespacesAndNewlines))
            """
        )
    }

    private static func timeInterval(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// Owns the output file and its directory by descriptor for the complete
/// conversion. FFmpeg and ffprobe receive the already-open file, while commit
/// and cleanup use `renameat`/`unlinkat`. Replacing the cache path with a
/// symlink therefore cannot redirect writes or deletion outside this directory.
private final class PinnedVideoOutput: @unchecked Sendable {
    let fileHandle: FileHandle

    private let directory: URL
    private let directoryDescriptor: Int32
    private let temporaryName: String
    private let finalName: String
    private let directoryDevice: dev_t
    private let directoryInode: ino_t
    private let fileDevice: dev_t
    private let fileInode: ino_t
    private let lock = NSLock()
    private var installed = false
    private var cleaned = false

    init(output: URL) throws {
        let standardized = output.standardizedFileURL
        let directory = standardized.deletingLastPathComponent()
        let finalName = standardized.lastPathComponent
        guard !finalName.isEmpty,
              finalName != ".",
              finalName != "..",
              !finalName.contains("/"),
              !finalName.contains("\0"),
              directory.appending(path: finalName).standardizedFileURL == standardized else {
            throw ConversionError.unsafeOutputPath
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ConversionError.unsafeOutputPath
        }

        let openedDirectory = try Self.openDirectoryWithoutFollowingSymlinks(directory)
        let outputExtension = standardized.pathExtension.isEmpty ? "mp4" : standardized.pathExtension
        let base = standardized.deletingPathExtension().lastPathComponent
        let temporaryName = ".\(base).incoming-\(UUID().uuidString).\(outputExtension)"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                openedDirectory.descriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            Darwin.close(openedDirectory.descriptor)
            throw ConversionError.unsafeOutputPath
        }
        var fileAttributes = stat()
        guard Darwin.fstat(descriptor, &fileAttributes) == 0,
              fileAttributes.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            _ = temporaryName.withCString {
                Darwin.unlinkat(openedDirectory.descriptor, $0, 0)
            }
            Darwin.close(openedDirectory.descriptor)
            throw ConversionError.unsafeOutputPath
        }
        self.directory = directory
        self.directoryDescriptor = openedDirectory.descriptor
        self.temporaryName = temporaryName
        self.finalName = finalName
        self.directoryDevice = openedDirectory.attributes.st_dev
        self.directoryInode = openedDirectory.attributes.st_ino
        self.fileDevice = fileAttributes.st_dev
        self.fileInode = fileAttributes.st_ino
        self.fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit {
        cleanup()
    }

    func rewind() throws {
        guard Darwin.lseek(fileHandle.fileDescriptor, 0, SEEK_SET) != -1 else {
            throw ConversionError.emptyOutput
        }
    }

    func validateRegularFile() throws {
        var attributes = stat()
        guard Darwin.fstat(fileHandle.fileDescriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_dev == fileDevice,
              attributes.st_ino == fileInode,
              attributes.st_size > 0,
              UInt64(attributes.st_size) <= VideoConverter.maximumConvertedBytes else {
            throw ConversionError.emptyOutput
        }
    }

    func commit() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cleaned, !installed,
              pathStillReferencesPinnedDirectory(),
              temporaryNameStillReferencesPinnedFile(),
              Darwin.fsync(fileHandle.fileDescriptor) == 0 else {
            throw ConversionError.unsafeOutputPath
        }
        let result = temporaryName.withCString { temporaryPath in
            finalName.withCString { finalPath in
                Darwin.renameat(
                    directoryDescriptor,
                    temporaryPath,
                    directoryDescriptor,
                    finalPath
                )
            }
        }
        guard result == 0 else {
            throw ConversionError.unsafeOutputPath
        }
        installed = true
        _ = Darwin.fsync(directoryDescriptor)
        guard pathStillReferencesPinnedDirectory() else {
            removeInstalledFileIfItIsOurs()
            installed = false
            throw ConversionError.unsafeOutputPath
        }
    }

    func cleanup() {
        lock.withLock {
            guard !cleaned else { return }
            cleaned = true
            try? fileHandle.close()
            if !installed, temporaryNameStillReferencesPinnedFile() {
                _ = temporaryName.withCString {
                    Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
            }
            Darwin.close(directoryDescriptor)
        }
    }

    private func temporaryNameStillReferencesPinnedFile() -> Bool {
        fileName(temporaryName, referencesDevice: fileDevice, inode: fileInode)
    }

    private func removeInstalledFileIfItIsOurs() {
        guard fileName(finalName, referencesDevice: fileDevice, inode: fileInode) else {
            return
        }
        _ = finalName.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
    }

    private func fileName(_ name: String, referencesDevice device: dev_t, inode: ino_t) -> Bool {
        var attributes = stat()
        let status = name.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &attributes, AT_SYMLINK_NOFOLLOW)
        }
        return status == 0
            && attributes.st_mode & S_IFMT == S_IFREG
            && attributes.st_dev == device
            && attributes.st_ino == inode
    }

    private func pathStillReferencesPinnedDirectory() -> Bool {
        var attributes = stat()
        let status = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &attributes)
        }
        return status == 0
            && attributes.st_mode & S_IFMT == S_IFDIR
            && attributes.st_dev == directoryDevice
            && attributes.st_ino == directoryInode
    }

    private static func openDirectoryWithoutFollowingSymlinks(
        _ directory: URL
    ) throws -> (descriptor: Int32, attributes: stat) {
        // The caller already derives this directory from a standardized output
        // URL. Standardizing the exact Darwin `/private/tmp` directory a second
        // time rewrites it to the `/tmp` symlink, which the fail-closed `lstat`
        // check below correctly rejects before FFmpeg can be supervised.
        let standardized = directory
        var before = stat()
        let inspected = standardized.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &before)
        }
        guard inspected == 0, before.st_mode & S_IFMT == S_IFDIR else {
            throw ConversionError.unsafeOutputPath
        }
        var resolvedBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedPath = standardized.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path, Darwin.realpath(path, &resolvedBuffer) != nil else { return nil }
            return String(
                decoding: resolvedBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
        }
        guard let resolvedPath,
              allowedCanonicalPath(original: standardized.path, resolved: resolvedPath) else {
            throw ConversionError.unsafeOutputPath
        }
        let components = URL(filePath: resolvedPath).pathComponents
        guard components.first == "/" else {
            throw ConversionError.unsafeOutputPath
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ConversionError.unsafeOutputPath }
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
                throw ConversionError.unsafeOutputPath
            }
            Darwin.close(descriptor)
            descriptor = next
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              after.st_mode & S_IFMT == S_IFDIR,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino else {
            Darwin.close(descriptor)
            throw ConversionError.unsafeOutputPath
        }
        return (descriptor, after)
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

public enum ConversionError: Error, LocalizedError, Sendable {
    case ffmpegNotFound
    case ffprobeNotFound
    case ffmpegLaunchFailed
    case ffprobeLaunchFailed
    case ffmpegFailed(Int32, String)
    case ffmpegTimedOut
    case ffprobeFailed(Int32, String)
    case ffprobeTimedOut
    case invalidProbeOutput
    case emptyOutput
    case inputHasNoVideo
    case inputStreamCountExceeded(total: Int, video: Int, audio: Int)
    case invalidInputVideoDimensions
    case inputVideoDimensionsExceeded
    case invalidInputAudioParameters
    case outputHasNoVideo
    case outputHasNoUsableAudio
    case unsafeInputPath
    case unsafeReferencedInput
    case unsafeOutputPath

    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "The bundled FFmpeg runtime is unavailable."
        case .ffprobeNotFound:
            return "The bundled ffprobe runtime is unavailable."
        case .ffmpegLaunchFailed:
            return "The bundled FFmpeg process could not be started safely."
        case .ffprobeLaunchFailed:
            return "The bundled ffprobe process could not be started safely."
        case .ffmpegFailed(let code, let details):
            return "FFmpeg exited with status \(code). \(details.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .ffmpegTimedOut:
            return "FFmpeg exceeded the video conversion time limit."
        case .ffprobeFailed(let code, let details):
            return "ffprobe exited with status \(code). \(details.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .ffprobeTimedOut:
            return "ffprobe exceeded its inspection time limit."
        case .invalidProbeOutput:
            return "ffprobe returned invalid media metadata."
        case .emptyOutput:
            return "FFmpeg did not produce a usable output file."
        case .inputHasNoVideo:
            return "The source does not contain a playable video stream."
        case .inputStreamCountExceeded(let total, let video, let audio):
            return "The source contains too many media streams (total \(total), video \(video), audio \(audio))."
        case .invalidInputVideoDimensions:
            return "The source video has missing or nonpositive dimensions."
        case .inputVideoDimensionsExceeded:
            return "The source video exceeds the safe decoded dimension limit."
        case .invalidInputAudioParameters:
            return "The preferred source audio stream has an unsafe channel count or sample rate."
        case .outputHasNoVideo:
            return "The converted output does not contain a video stream."
        case .outputHasNoUsableAudio:
            return "The converted output did not preserve the preferred authored audio stream."
        case .unsafeInputPath:
            return "The media input is not a safe regular file."
        case .unsafeReferencedInput:
            return "Playlist and externally referenced media inputs are not supported."
        case .unsafeOutputPath:
            return "The converted output cache changed during conversion. Retry the operation."
        }
    }
}
