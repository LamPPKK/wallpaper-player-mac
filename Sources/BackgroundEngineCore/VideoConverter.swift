import Foundation

public struct VideoConverter: Sendable {
    public init() {}

    public func ffmpegPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func convertToPlayableVideo(input: URL, output: URL) throws {
        guard let ffmpeg = ffmpegPath() else {
            throw ConversionError.ffmpegNotFound
        }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(filePath: ffmpeg)
        process.arguments = [
            "-y",
            "-i", input.path,
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
            "-c:a", "aac",
            output.path
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConversionError.ffmpegFailed(process.terminationStatus)
        }
    }
}

public enum ConversionError: Error, LocalizedError, Sendable {
    case ffmpegNotFound
    case ffmpegFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "ffmpeg was not found. Install it with Homebrew: brew install ffmpeg"
        case .ffmpegFailed(let code):
            return "ffmpeg exited with status \(code)."
        }
    }
}
