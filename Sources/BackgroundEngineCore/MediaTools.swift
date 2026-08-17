import Foundation
import Darwin

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
        public let index: Int
        public let codecName: String?
        public let codecType: String?
        public let width: Int?
        public let height: Int?
        public let sampleRate: String?
        public let channels: Int?
        public let tags: [String: String]?

        enum CodingKeys: String, CodingKey {
            case index
            case codecName = "codec_name"
            case codecType = "codec_type"
            case width
            case height
            case sampleRate = "sample_rate"
            case channels
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

    public var hasVideo: Bool { streams.contains { $0.codecType == "video" } }
    public var hasAudio: Bool { streams.contains { $0.codecType == "audio" } }
    public var durationSeconds: Double? { format?.duration.flatMap(Double.init) }
}

public struct MediaProbe: Sendable {
    private let resolver: MediaToolResolver

    public init(resolver: MediaToolResolver = MediaToolResolver()) {
        self.resolver = resolver
    }

    public func inspect(_ input: URL, timeout: TimeInterval = 10) throws -> MediaProbeReport {
        guard let path = resolver.resolve(.ffprobe).path else {
            throw ConversionError.ffprobeNotFound
        }
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = [
            "-v", "error",
            "-show_streams",
            "-show_format",
            "-print_format", "json",
            input.path
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let outputReader = BoundedPipeReader(handle: output.fileHandleForReading)
        let errorReader = BoundedPipeReader(handle: errors.fileHandleForReading)
        outputReader.start()
        errorReader.start()
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            _ = outputReader.finish()
            _ = errorReader.finish()
            throw error
        }
        if finished.wait(timeout: .now() + max(0.1, timeout)) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            _ = outputReader.finish()
            _ = errorReader.finish()
            throw ConversionError.ffprobeTimedOut
        }
        process.waitUntilExit()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let data = outputReader.finish()
        let errorData = errorReader.finish()
        guard process.terminationStatus == 0 else {
            throw ConversionError.ffprobeFailed(
                process.terminationStatus,
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
private final class BoundedPipeReader: @unchecked Sendable {
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
    public let width: Int?
    public let height: Int?

    public init(
        contentHash: String,
        mediaBuildID: String = MediaToolResolver.pinnedBuildID,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.contentHash = contentHash
        self.mediaBuildID = mediaBuildID
        self.width = width
        self.height = height
    }

    public var fileName: String {
        let size = width.flatMap { width in height.map { "-\(width)x\($0)" } } ?? ""
        return "\(contentHash.prefix(24))-\(mediaBuildID)\(size).mp4"
    }
}
