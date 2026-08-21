import Foundation

public struct VideoConverter: Sendable {
    public static let defaultTimeout: Duration = .seconds(7_200)
    public static let maximumConvertedBytes: UInt64 = 20 * 1_024 * 1_024 * 1_024

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
        let temporary = try temporaryOutputURL(for: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let (child, errorReader) = try launchFFmpeg(
            at: ffmpeg,
            input: input,
            temporary: temporary
        )
        let (terminationStatus, timedOut) = child.waitUntilExit(timeout: 7_200)
        let errorData = errorReader.finish()
        if timedOut { throw ConversionError.ffmpegTimedOut }
        try validateFFmpegExit(status: terminationStatus, errorData: errorData)
        try validateRegularOutput(temporary)
        let report = try MediaProbe(resolver: resolver).inspect(temporary)
        guard report.hasVideo else { throw ConversionError.outputHasNoVideo }
        try installAtomically(temporary: temporary, output: output)
    }

    public func convertToPlayableVideo(
        input: URL,
        output: URL,
        timeout: Duration
    ) async throws {
        guard let ffmpeg = ffmpegPath() else {
            throw ConversionError.ffmpegNotFound
        }
        try Task.checkCancellation()
        let temporary = try temporaryOutputURL(for: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let (child, errorReader) = try launchFFmpeg(
            at: ffmpeg,
            input: input,
            temporary: temporary
        )

        let terminationStatus: Int32
        let timedOut: Bool
        do {
            (terminationStatus, timedOut) = try await child.waitUntilExit(timeout: timeout)
        } catch {
            _ = errorReader.finish()
            throw error
        }
        let errorData = errorReader.finish()

        if timedOut { throw ConversionError.ffmpegTimedOut }
        try validateFFmpegExit(status: terminationStatus, errorData: errorData)
        try Task.checkCancellation()
        try validateRegularOutput(temporary)
        let report = try await MediaProbe(resolver: resolver).inspect(
            temporary,
            timeout: .seconds(10)
        )
        guard report.hasVideo else { throw ConversionError.outputHasNoVideo }
        try Task.checkCancellation()
        try installAtomically(temporary: temporary, output: output)
    }

    public static func conversionArguments(input: URL, output: URL) -> [String] {
        [
            "-nostdin",
            "-y",
            "-i", input.path,
            "-map_metadata", "0",
            "-map", "0:v:0",
            "-map", "0:a?",
            "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
            "-c:v", "h264_videotoolbox",
            "-allow_sw", "1",
            "-b:v", "12M",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "+faststart",
            output.path
        ]
    }

    private func installAtomically(temporary: URL, output: URL) throws {
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: output)
        }
    }

    private func temporaryOutputURL(for output: URL) throws -> URL {
        let outputDirectory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let outputExtension = output.pathExtension.isEmpty ? "mp4" : output.pathExtension
        return outputDirectory.appending(
            path: ".\(output.deletingPathExtension().lastPathComponent).incoming-\(UUID().uuidString).\(outputExtension)"
        )
    }

    private func launchFFmpeg(
        at path: String,
        input: URL,
        temporary: URL
    ) throws -> (SupervisedChildProcess, BoundedPipeReader) {
        let nullOutput: FileHandle
        do {
            nullOutput = try FileHandle(forWritingTo: URL(filePath: "/dev/null"))
        } catch {
            throw ConversionError.ffmpegLaunchFailed
        }
        defer { try? nullOutput.close() }
        let errors = Pipe()
        let errorReader = BoundedPipeReader(handle: errors.fileHandleForReading)
        errorReader.start()
        do {
            let child = try SupervisedChildProcess.spawn(
                executable: URL(filePath: path),
                arguments: Self.conversionArguments(input: input, output: temporary),
                currentDirectory: temporary.deletingLastPathComponent(),
                standardOutput: nullOutput,
                standardError: errors.fileHandleForWriting,
                outputFileLimit: Self.maximumConvertedBytes
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

    private func validateRegularOutput(_ output: URL) throws {
        guard let values = try? output.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else {
            throw ConversionError.emptyOutput
        }
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
    case outputHasNoVideo

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
        case .outputHasNoVideo:
            return "The converted output does not contain a video stream."
        }
    }
}
