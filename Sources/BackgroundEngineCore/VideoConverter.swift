import Darwin
import Foundation

public struct VideoConverter: Sendable {
    public static let defaultTimeout: Duration = .seconds(7_200)
    public static let maximumConvertedBytes: UInt64 = 20 * 1_024 * 1_024 * 1_024
    static let previousConversionRecipeIDs = [
        "video-2-even-dar",
        "video-3-fragmented-mp4-even-dar"
    ]
    public static let conversionRecipeID = "video-4-default-stream-fragmented-mp4-even-dar"
    public static let outdatedRecipeIssueCode = "video_conversion_recipe_outdated"

    /// H.264 with a 4:2:0 pixel format requires even encoded dimensions.
    /// Scaling up by at most one pixel per axis keeps the complete frame and
    /// lets FFmpeg adjust sample aspect ratio so display aspect ratio remains
    /// identical. The previous truncating filter cropped the final row/column.
    static let evenDimensionFilter =
        "scale=ceil(iw/2)*2:ceil(ih/2)*2:flags=lanczos"

    private static let inputDescriptorToken = "__BACKGROUND_ENGINE_VIDEO_INPUT_FD__"

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
        let inputReport = try MediaProbe(resolver: resolver).inspect(input, timeout: 10)
        guard let videoStreamIndex = inputReport.preferredVideoStreamIndex else {
            throw ConversionError.inputHasNoVideo
        }
        let pendingOutput = try PinnedVideoOutput(output: output)
        defer { pendingOutput.cleanup() }
        let (child, errorReader) = try launchFFmpeg(
            at: ffmpeg,
            inputPath: input.path,
            pinnedInput: nil,
            videoStreamIndex: videoStreamIndex,
            output: pendingOutput
        )
        let (terminationStatus, timedOut) = child.waitUntilExit(timeout: 7_200)
        let errorData = errorReader.finish()
        if timedOut { throw ConversionError.ffmpegTimedOut }
        try validateFFmpegExit(status: terminationStatus, errorData: errorData)
        try pendingOutput.validateRegularFile()
        try pendingOutput.rewind()
        let report = try MediaProbe(resolver: resolver).inspect(
            pendingOutput.fileHandle,
            timeout: 10
        )
        guard report.hasVideo else { throw ConversionError.outputHasNoVideo }
        try pendingOutput.commit()
    }

    public func convertToPlayableVideo(
        input: URL,
        output: URL,
        timeout: Duration
    ) async throws {
        try await convertToPlayableVideo(
            inputPath: input.path,
            pinnedInput: nil,
            output: output,
            timeout: timeout
        )
    }

    public func convertToPlayableVideo(
        input: PinnedVideoInput,
        output: URL,
        timeout: Duration
    ) async throws {
        try await convertToPlayableVideo(
            inputPath: "/dev/fd/\(Self.inputDescriptorToken)",
            pinnedInput: input.fileHandle,
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
        guard let videoStreamIndex = inputReport.preferredVideoStreamIndex else {
            throw ConversionError.inputHasNoVideo
        }
        try Task.checkCancellation()
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
            output: pendingOutput
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
        try pendingOutput.validateRegularFile()
        try pendingOutput.rewind()
        let report = try await MediaProbe(resolver: resolver).inspect(
            pendingOutput.fileHandle,
            timeout: .seconds(10)
        )
        guard report.hasVideo else { throw ConversionError.outputHasNoVideo }
        try Task.checkCancellation()
        try pendingOutput.commit()
    }

    public static func conversionArguments(input: URL, output: URL) -> [String] {
        conversionArguments(
            inputPath: input.path,
            outputPath: output.path,
            videoMapSpecifier: "0:v:0",
            forceMP4Container: false
        )
    }

    static func conversionArguments(
        input: URL,
        output: URL,
        videoStreamIndex: Int
    ) -> [String] {
        conversionArguments(
            inputPath: input.path,
            outputPath: output.path,
            videoMapSpecifier: "0:\(videoStreamIndex)",
            forceMP4Container: false
        )
    }

    private static func conversionArguments(
        inputPath: String,
        outputPath: String,
        videoMapSpecifier: String,
        forceMP4Container: Bool
    ) -> [String] {
        var arguments = [
            "-nostdin",
            "-y",
            "-i", inputPath,
            "-map_metadata", "0",
            "-map", videoMapSpecifier,
            "-map", "0:a?",
            "-vf", evenDimensionFilter,
            "-c:v", "h264_videotoolbox",
            "-allow_sw", "1",
            "-b:v", "12M",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", "192k"
        ]
        if forceMP4Container {
            // `/dev/fd/1` duplicates the same open file description as stdout.
            // The MP4 faststart second pass needs independent read and write
            // offsets; using it through that descriptor silently corrupts mdat.
            // Fragmented MP4 is written sequentially and remains playable by
            // AVFoundation while keeping the output inode descriptor-bound.
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
        output: PinnedVideoOutput
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
                    outputPath: "/dev/fd/\(STDOUT_FILENO)",
                    videoMapSpecifier: "0:\(videoStreamIndex)",
                    forceMP4Container: true
                ),
                currentDirectory: URL(filePath: "/"),
                standardOutput: output.fileHandle,
                standardError: errors.fileHandleForWriting,
                outputFileLimit: Self.maximumConvertedBytes,
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
        let standardized = directory.standardizedFileURL
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
    case outputHasNoVideo
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
        case .outputHasNoVideo:
            return "The converted output does not contain a video stream."
        case .unsafeOutputPath:
            return "The converted output cache changed during conversion. Retry the operation."
        }
    }
}
