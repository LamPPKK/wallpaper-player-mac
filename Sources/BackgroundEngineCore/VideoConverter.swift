import Foundation

public struct VideoConverter: Sendable {
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
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let outputDirectory = output.deletingLastPathComponent()
        let outputExtension = output.pathExtension.isEmpty ? "mp4" : output.pathExtension
        let temporary = outputDirectory.appending(
            path: ".\(output.deletingPathExtension().lastPathComponent).incoming-\(UUID().uuidString).\(outputExtension)"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = URL(filePath: ffmpeg)
        process.arguments = Self.conversionArguments(input: input, output: temporary)
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConversionError.ffmpegFailed(
                process.terminationStatus,
                String(data: errorData, encoding: .utf8) ?? ""
            )
        }
        guard let values = try? temporary.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else {
            throw ConversionError.emptyOutput
        }
        let report = try MediaProbe(resolver: resolver).inspect(temporary)
        guard report.hasVideo else { throw ConversionError.outputHasNoVideo }
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
}

public enum ConversionError: Error, LocalizedError, Sendable {
    case ffmpegNotFound
    case ffprobeNotFound
    case ffmpegFailed(Int32, String)
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
        case .ffmpegFailed(let code, let details):
            return "FFmpeg exited with status \(code). \(details.trimmingCharacters(in: .whitespacesAndNewlines))"
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
