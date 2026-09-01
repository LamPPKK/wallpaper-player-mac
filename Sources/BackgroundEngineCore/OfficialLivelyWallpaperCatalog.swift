import CryptoKit
import Darwin
import Foundation

/// A wallpaper published by the Lively maintainer as a separate GitHub
/// release. These archives are intentionally not embedded in Background
/// Engine: their content licenses remain separate and the user downloads each
/// item directly from its official release page.
@_spi(LivelyCatalog)
public enum OfficialLivelyWallpaperCategory: String, CaseIterable, Hashable, Sendable {
    case ambientEffects
    case musicAndMedia
}

@_spi(LivelyCatalog)
public struct OfficialLivelyWallpaper: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let repositoryURL: URL
    public let releaseURL: URL
    public let releaseTag: String
    public let sourceCommit: String
    public let downloadURL: URL
    public let archiveFileName: String
    public let archiveByteCount: UInt64
    public let archiveSHA256: String
    public let licenseName: String
    public let licenseURL: URL
    public let category: OfficialLivelyWallpaperCategory
    public let termsNotice: String
    public let runtimeNotice: String

    public init(
        id: String,
        title: String,
        summary: String,
        repositoryURL: URL,
        releaseURL: URL,
        releaseTag: String,
        sourceCommit: String,
        downloadURL: URL,
        archiveFileName: String,
        archiveByteCount: UInt64,
        archiveSHA256: String,
        licenseName: String,
        licenseURL: URL,
        category: OfficialLivelyWallpaperCategory = .ambientEffects,
        termsNotice: String = "Review the linked license and retained package notices before downloading.",
        runtimeNotice: String = ""
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.repositoryURL = repositoryURL
        self.releaseURL = releaseURL
        self.releaseTag = releaseTag
        self.sourceCommit = sourceCommit
        self.downloadURL = downloadURL
        self.archiveFileName = archiveFileName
        self.archiveByteCount = archiveByteCount
        self.archiveSHA256 = archiveSHA256
        self.licenseName = licenseName
        self.licenseURL = licenseURL
        self.category = category
        self.termsNotice = termsNotice
        self.runtimeNotice = runtimeNotice
    }

    /// Immutable source view matching the commit used to pin this catalog
    /// entry. The app never sends users to a mutable default branch when it
    /// presents the source behind a verified archive.
    public var pinnedSourceURL: URL {
        repositoryURL
            .appending(path: "tree", directoryHint: .isDirectory)
            .appending(path: sourceCommit, directoryHint: .isDirectory)
    }
}

@_spi(LivelyCatalog)
public enum OfficialLivelyWallpaperCatalog {
    /// Lively's upstream-maintained discovery page. It is deliberately kept
    /// separate from ``wallpapers`` because it includes community projects,
    /// varying licenses and a Windows Application example. Background Engine
    /// opens this page in the user's browser and never treats it as executable
    /// remote catalog data.
    public static let sampleProjectsURL = URL(
        string: "https://github.com/rocksdanister/lively/wiki/Sample-Wallpaper-Projects"
    )!

    /// Small, self-contained Web wallpapers maintained by rocksdanister. Rain,
    /// Snow and Clouds are CC BY-NC-SA works. The music wallpapers are pinned
    /// releases from the maintainer's Lively sample repository and retain
    /// their package-specific notices. Only metadata and exact official
    /// download coordinates are shipped with the app.
    public static let wallpapers: [OfficialLivelyWallpaper] = [
        OfficialLivelyWallpaper(
            id: "rocksdanister-rain-v3",
            title: "Rain",
            summary: "Customisable rainy-window shader with image or video backgrounds.",
            repositoryURL: URL(string: "https://github.com/rocksdanister/rain")!,
            releaseURL: URL(string: "https://github.com/rocksdanister/rain/releases/tag/v3")!,
            releaseTag: "v3",
            sourceCommit: "215b57378d3fe648d2797aaf8a101a4009128527",
            downloadURL: URL(
                string: "https://github.com/rocksdanister/rain/releases/download/v3/Rain_v3.zip"
            )!,
            archiveFileName: "Rain_v3.zip",
            archiveByteCount: 18_557_264,
            archiveSHA256: "48bdd9da1bbfecdcffe6479c1d44e6175bddc4e4bf847fdf053ba61cefb06186",
            licenseName: "CC BY-NC-SA 3.0",
            licenseURL: URL(
                string: "https://github.com/rocksdanister/rain/blob/215b57378d3fe648d2797aaf8a101a4009128527/License.txt"
            )!,
            termsNotice: "Attribution, non-commercial and share-alike restrictions apply."
        ),
        OfficialLivelyWallpaper(
            id: "rocksdanister-snow-v1",
            title: "Snow",
            summary: "Customisable snow shader with image or video backgrounds.",
            repositoryURL: URL(string: "https://github.com/rocksdanister/snow")!,
            releaseURL: URL(string: "https://github.com/rocksdanister/snow/releases/tag/v1")!,
            releaseTag: "v1",
            sourceCommit: "f955c86e1de57ffe06bedac294add36aa4fd1f7a",
            downloadURL: URL(
                string: "https://github.com/rocksdanister/snow/releases/download/v1/snow_v1.zip"
            )!,
            archiveFileName: "snow_v1.zip",
            archiveByteCount: 18_481_669,
            archiveSHA256: "15f8e3b91e0010ae6c6370f1ea280733d3534b43da66854a4fe0e05012c85999",
            licenseName: "CC BY-NC-SA 3.0",
            licenseURL: URL(
                string: "https://github.com/rocksdanister/snow/blob/f955c86e1de57ffe06bedac294add36aa4fd1f7a/License.txt"
            )!,
            termsNotice: "Attribution, non-commercial and share-alike restrictions apply."
        ),
        OfficialLivelyWallpaper(
            id: "rocksdanister-clouds-v1",
            title: "Clouds",
            summary: "Customisable volumetric-cloud shader with fog and performance controls.",
            repositoryURL: URL(string: "https://github.com/rocksdanister/clouds")!,
            releaseURL: URL(string: "https://github.com/rocksdanister/clouds/releases/tag/v1.0")!,
            releaseTag: "v1.0",
            sourceCommit: "9c112735b34808020d4269750207e2ac89c28a79",
            downloadURL: URL(
                string: "https://github.com/rocksdanister/clouds/releases/download/v1.0/clouds.zip"
            )!,
            archiveFileName: "clouds.zip",
            archiveByteCount: 1_435_254,
            archiveSHA256: "2b54637763214505514fd5711e65a6eecf11ec5c9a84586445ff5da095adb7bc",
            licenseName: "CC BY-NC-SA 3.0",
            licenseURL: URL(
                string: "https://github.com/rocksdanister/clouds/blob/9c112735b34808020d4269750207e2ac89c28a79/License.txt"
            )!,
            termsNotice: "Attribution, non-commercial and share-alike restrictions apply."
        ),
        OfficialLivelyWallpaper(
            id: "rocksdanister-ferrari-458-v1.0.0.1",
            title: "Ferrari 458 Italia",
            summary: "Three-dimensional sports car scene with audio-reactive lighting.",
            repositoryURL: URL(
                string: "https://github.com/rocksdanister/audio-visualizer-wallpaper"
            )!,
            releaseURL: URL(
                string: "https://github.com/rocksdanister/audio-visualizer-wallpaper/releases/tag/v1.0.0.1"
            )!,
            releaseTag: "v1.0.0.1",
            sourceCommit: "c1b5a523970010638315386a0f8df3eaac2dd56f",
            downloadURL: URL(
                string: "https://github.com/rocksdanister/audio-visualizer-wallpaper/releases/download/v1.0.0.1/Ferrari.458.Italia.zip"
            )!,
            archiveFileName: "Ferrari.458.Italia.zip",
            archiveByteCount: 4_710_704,
            archiveSHA256: "52ccbab1f55c1f60121dc765b58aeaf4156ec5de04e61afd985b5fb486087eea",
            licenseName: "MIT with retained model and HDRI attribution notice",
            licenseURL: URL(
                string: "https://github.com/rocksdanister/audio-visualizer-wallpaper/blob/c1b5a523970010638315386a0f8df3eaac2dd56f/src/Ferrari%20458/license.txt"
            )!,
            category: .musicAndMedia,
            termsNotice: "The downloaded ZIP retains its Ferrari model and Poly Haven HDRI source and attribution links.",
            runtimeNotice: "System-audio capture and pointer/orbit interaction are unavailable, while dynamically constructed requests stay under the per-wallpaper network permission. The car remains visible, but audio-reactive lighting receives neutral data and free camera control is reported Limited."
        ),
        OfficialLivelyWallpaper(
            id: "rocksdanister-music-tunnel-v1.0.0.1",
            title: "Music Tunnel",
            summary: "Continuously animated shader tunnel with media-driven colour styling.",
            repositoryURL: URL(
                string: "https://github.com/rocksdanister/audio-visualizer-wallpaper"
            )!,
            releaseURL: URL(
                string: "https://github.com/rocksdanister/audio-visualizer-wallpaper/releases/tag/v1.0.0.1"
            )!,
            releaseTag: "v1.0.0.1",
            sourceCommit: "ac37e3723dacc2ebcce6eaf823abebae9e9f72e4",
            downloadURL: URL(
                string: "https://github.com/rocksdanister/audio-visualizer-wallpaper/releases/download/v1.0.0.1/Music.Tunnel.zip"
            )!,
            archiveFileName: "Music.Tunnel.zip",
            archiveByteCount: 2_421_390,
            archiveSHA256: "03e1b365332a0640fc55b828fb288619884f1bc2a8b6d13e9fbff03a51a09bbe",
            licenseName: "MIT, SIL Open Font License 1.1 and retained media attribution notice",
            licenseURL: URL(
                string: "https://github.com/rocksdanister/audio-visualizer-wallpaper/blob/ac37e3723dacc2ebcce6eaf823abebae9e9f72e4/src/Music%20Tunnel/License.txt"
            )!,
            category: .musicAndMedia,
            termsNotice: "The downloaded ZIP retains the shader, font and Pexels background attribution notices.",
            runtimeNotice: "The tunnel animation runs continuously; Windows Now Playing colour updates and pointer interaction are unavailable, while dynamically constructed requests stay under the per-wallpaper network permission. These missing capabilities are reported Limited."
        )
    ]
}

@_spi(LivelyCatalog)
public enum OfficialLivelyWallpaperDownloadError: LocalizedError, Equatable {
    case unknownWallpaper
    case downloadFailed
    case untrustedResponse
    case unexpectedArchiveSize(expected: UInt64, actual: UInt64)
    case archiveHashMismatch
    case unsafeDownloadedFile
    case cannotCreateStaging

    public var errorDescription: String? {
        switch self {
        case .unknownWallpaper:
            "This wallpaper is not in the pinned official Lively catalog."
        case .downloadFailed:
            "The official Lively wallpaper download failed."
        case .untrustedResponse:
            "The wallpaper download did not come from a trusted GitHub release endpoint."
        case .unexpectedArchiveSize(let expected, let actual):
            "The downloaded wallpaper archive has an unexpected size (expected \(expected) bytes, received \(actual))."
        case .archiveHashMismatch:
            "The downloaded wallpaper archive does not match its pinned SHA-256 checksum."
        case .unsafeDownloadedFile:
            "The downloaded wallpaper archive is not a stable regular file."
        case .cannotCreateStaging:
            "Background Engine could not create private staging for the wallpaper download."
        }
    }
}

/// Monotonic progress emitted while a pinned official Lively release moves
/// through download, archive verification and the hostile-package importer.
/// Byte totals can be unavailable until GitHub's release CDN supplies them.
@_spi(LivelyCatalog)
public enum OfficialLivelyWallpaperInstallProgress: Equatable, Sendable {
    case downloading(receivedBytes: UInt64, totalBytes: UInt64?)
    case verifying
    case importing

    public var fractionCompleted: Double? {
        guard case .downloading(let receivedBytes, let totalBytes) = self,
              let totalBytes,
              totalBytes > 0 else {
            return nil
        }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
}

final class OfficialLivelyWallpaperURLSessionDownloadClient:
    NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let expectedByteCount: UInt64
    private let configuration: URLSessionConfiguration
    private let temporaryDirectory: URL
    private let progress: @Sendable (OfficialLivelyWallpaperInstallProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), any Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var downloadedURL: URL?
    private var response: URLResponse?
    private var terminalError: (any Error)?
    private var cancellationRequested = false

    init(
        expectedByteCount: UInt64,
        configuration: URLSessionConfiguration = .ephemeral,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        progress: @escaping @Sendable (OfficialLivelyWallpaperInstallProgress) -> Void
    ) {
        self.expectedByteCount = expectedByteCount
        self.configuration = configuration
        self.temporaryDirectory = temporaryDirectory
        self.progress = progress
    }

    func download(from url: URL) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var taskToResume: URLSessionDownloadTask?
                let shouldCancel = lock.withLock {
                    if cancellationRequested {
                        return true
                    }
                    self.continuation = continuation
                    configuration.waitsForConnectivity = false
                    let session = URLSession(
                        configuration: configuration,
                        delegate: self,
                        delegateQueue: nil
                    )
                    let task = session.downloadTask(with: URLRequest(url: url))
                    self.session = session
                    self.task = task
                    taskToResume = task
                    return false
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                } else {
                    taskToResume?.resume()
                }
            }
        } onCancel: {
            let task = self.lock.withLock {
                self.cancellationRequested = true
                return self.task
            }
            task?.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard lock.withLock({ terminalError == nil }) else { return }
        do {
            let destination = temporaryDirectory.appending(
                path: "background-engine-lively-download-\(UUID().uuidString).zip"
            )
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock {
                downloadedURL = destination
                response = downloadTask.response
            }
        } catch {
            lock.withLock {
                terminalError = error
            }
        }
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let receivedBytes = UInt64(max(0, totalBytesWritten))
        let declaredBytes = totalBytesExpectedToWrite > 0
            ? UInt64(totalBytesExpectedToWrite)
            : nil
        let overflowActual: UInt64?
        if let declaredBytes, declaredBytes > expectedByteCount {
            overflowActual = declaredBytes
        } else if receivedBytes > expectedByteCount {
            overflowActual = receivedBytes
        } else {
            overflowActual = nil
        }
        if let overflowActual {
            let shouldCancel = lock.withLock {
                guard terminalError == nil else { return false }
                terminalError = OfficialLivelyWallpaperDownloadError.unexpectedArchiveSize(
                    expected: expectedByteCount,
                    actual: overflowActual
                )
                return true
            }
            if shouldCancel {
                downloadTask.cancel()
            }
            return
        }
        progress(.downloading(
            receivedBytes: receivedBytes,
            totalBytes: declaredBytes
        ))
    }

    func urlSession(
        _ session: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let completion: (
            CheckedContinuation<(URL, URLResponse), any Error>?,
            Result<(URL, URLResponse), any Error>,
            URL?
        ) = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            self.task = nil
            self.session = nil
            let downloadedURL = self.downloadedURL
            let response = self.response
            let terminalError = self.terminalError
            self.downloadedURL = nil
            self.response = nil
            self.terminalError = nil
            if let terminalError {
                return (continuation, .failure(terminalError), downloadedURL)
            }
            if let error {
                return (continuation, .failure(error), downloadedURL)
            }
            guard let downloadedURL, let response else {
                return (
                    continuation,
                    .failure(OfficialLivelyWallpaperDownloadError.downloadFailed),
                    downloadedURL
                )
            }
            return (continuation, .success((downloadedURL, response)), nil)
        }
        session.finishTasksAndInvalidate()
        if let cleanupURL = completion.2 {
            try? FileManager.default.removeItem(at: cleanupURL)
        }
        guard let continuation = completion.0 else { return }
        continuation.resume(with: completion.1)
    }
}

/// Downloads one exact catalog archive, snapshots it through a no-follow file
/// descriptor, verifies its size and SHA-256, then passes that immutable copy
/// through the regular hostile-ZIP Lively importer.
@_spi(LivelyCatalog)
public actor OfficialLivelyWallpaperDownloadService {
    typealias Downloader = @Sendable (URL) async throws -> (URL, URLResponse)
    typealias ProgressDownloader = @Sendable (
        URL,
        UInt64,
        @escaping @Sendable (OfficialLivelyWallpaperInstallProgress) -> Void
    ) async throws -> (URL, URLResponse)

    private static let maximumArchiveBytes: UInt64 = 64 * 1_024 * 1_024

    private let importer: LivelyWallpaperPackageImporter
    private let downloader: Downloader
    private let progressDownloader: ProgressDownloader?
    private let catalog: [OfficialLivelyWallpaper]

    public init(store: LibraryStore) {
        importer = LivelyWallpaperPackageImporter(store: store)
        downloader = { try await URLSession.shared.download(from: $0) }
        progressDownloader = { url, expectedByteCount, progress in
            try await OfficialLivelyWallpaperURLSessionDownloadClient(
                expectedByteCount: expectedByteCount,
                progress: progress
            ).download(from: url)
        }
        catalog = OfficialLivelyWallpaperCatalog.wallpapers
    }

    init(
        store: LibraryStore,
        catalog: [OfficialLivelyWallpaper],
        downloader: @escaping Downloader,
        progressDownloader: ProgressDownloader? = nil
    ) {
        importer = LivelyWallpaperPackageImporter(store: store)
        self.catalog = catalog
        self.downloader = downloader
        self.progressDownloader = progressDownloader
    }

    public func downloadAndImport(
        _ wallpaper: OfficialLivelyWallpaper,
        progress: (@Sendable (OfficialLivelyWallpaperInstallProgress) -> Void)? = nil
    ) async throws -> WallpaperAsset {
        guard catalog.contains(wallpaper),
              Self.isTrustedCatalogURL(wallpaper.downloadURL),
              wallpaper.archiveByteCount > 0,
              wallpaper.archiveByteCount <= Self.maximumArchiveBytes,
              Self.isSHA256(wallpaper.archiveSHA256) else {
            throw OfficialLivelyWallpaperDownloadError.unknownWallpaper
        }

        let downloadedURL: URL
        let response: URLResponse
        do {
            progress?(.downloading(receivedBytes: 0, totalBytes: wallpaper.archiveByteCount))
            if let progressDownloader {
                (downloadedURL, response) = try await progressDownloader(
                    wallpaper.downloadURL,
                    wallpaper.archiveByteCount,
                    progress ?? { _ in }
                )
            } else {
                (downloadedURL, response) = try await downloader(wallpaper.downloadURL)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OfficialLivelyWallpaperDownloadError {
            throw error
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw OfficialLivelyWallpaperDownloadError.downloadFailed
        }
        defer { try? FileManager.default.removeItem(at: downloadedURL) }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              Self.isTrustedResponseURL(http.url, requestedURL: wallpaper.downloadURL) else {
            throw OfficialLivelyWallpaperDownloadError.untrustedResponse
        }
        if http.expectedContentLength >= 0,
           UInt64(http.expectedContentLength) != wallpaper.archiveByteCount {
            throw OfficialLivelyWallpaperDownloadError.unexpectedArchiveSize(
                expected: wallpaper.archiveByteCount,
                actual: UInt64(http.expectedContentLength)
            )
        }

        let workspace = FileManager.default.temporaryDirectory.appending(
            path: "background-engine-official-lively-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw OfficialLivelyWallpaperDownloadError.cannotCreateStaging
        }
        defer { try? FileManager.default.removeItem(at: workspace) }

        let archive = workspace.appending(path: "wallpaper.zip")
        progress?(.verifying)
        try Self.snapshotAndVerify(
            downloadedURL,
            to: archive,
            expectedBytes: wallpaper.archiveByteCount,
            expectedSHA256: wallpaper.archiveSHA256
        )
        try Task.checkCancellation()
        progress?(.importing)
        return try await importer.importAndPrepare(archive)
    }

    private static func snapshotAndVerify(
        _ source: URL,
        to destination: URL,
        expectedBytes: UInt64,
        expectedSHA256: String
    ) throws {
        let sourceDescriptor = source.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard sourceDescriptor >= 0 else {
            throw OfficialLivelyWallpaperDownloadError.unsafeDownloadedFile
        }
        defer { Darwin.close(sourceDescriptor) }

        var opened = stat()
        guard Darwin.fstat(sourceDescriptor, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_size >= 0 else {
            throw OfficialLivelyWallpaperDownloadError.unsafeDownloadedFile
        }
        let openedBytes = UInt64(opened.st_size)
        guard openedBytes == expectedBytes else {
            throw OfficialLivelyWallpaperDownloadError.unexpectedArchiveSize(
                expected: expectedBytes,
                actual: openedBytes
            )
        }

        let destinationDescriptor = destination.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard destinationDescriptor >= 0 else {
            throw OfficialLivelyWallpaperDownloadError.cannotCreateStaging
        }
        var keepDestination = false
        defer {
            Darwin.close(destinationDescriptor)
            if !keepDestination {
                _ = destination.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return Int32(-1) }
                    return Darwin.unlink(path)
                }
            }
        }

        var digest = SHA256()
        var copiedBytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let amount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(sourceDescriptor, bytes.baseAddress, bytes.count)
            }
            if amount == 0 { break }
            if amount < 0 {
                if errno == EINTR { continue }
                throw OfficialLivelyWallpaperDownloadError.unsafeDownloadedFile
            }
            let (next, overflow) = copiedBytes.addingReportingOverflow(UInt64(amount))
            guard !overflow, next <= expectedBytes else {
                throw OfficialLivelyWallpaperDownloadError.unexpectedArchiveSize(
                    expected: expectedBytes,
                    actual: overflow ? UInt64.max : next
                )
            }
            digest.update(data: Data(buffer.prefix(amount)))
            try writeAll(
                descriptor: destinationDescriptor,
                buffer: buffer,
                count: amount
            )
            copiedBytes = next
        }
        guard copiedBytes == expectedBytes else {
            throw OfficialLivelyWallpaperDownloadError.unexpectedArchiveSize(
                expected: expectedBytes,
                actual: copiedBytes
            )
        }

        var finalDescriptorState = stat()
        var finalPathState = stat()
        let pathStatus = source.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &finalPathState)
        }
        guard Darwin.fstat(sourceDescriptor, &finalDescriptorState) == 0,
              pathStatus == 0,
              sameFile(opened, finalDescriptorState),
              sameFile(opened, finalPathState) else {
            throw OfficialLivelyWallpaperDownloadError.unsafeDownloadedFile
        }
        let actualHash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualHash == expectedSHA256.lowercased() else {
            throw OfficialLivelyWallpaperDownloadError.archiveHashMismatch
        }
        guard Darwin.fsync(destinationDescriptor) == 0 else {
            throw OfficialLivelyWallpaperDownloadError.cannotCreateStaging
        }
        keepDestination = true
    }

    private static func writeAll(
        descriptor: Int32,
        buffer: [UInt8],
        count: Int
    ) throws {
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes { bytes in
                Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    count - offset
                )
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw OfficialLivelyWallpaperDownloadError.cannotCreateStaging
            }
            guard written > 0 else {
                throw OfficialLivelyWallpaperDownloadError.cannotCreateStaging
            }
            offset += written
        }
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
            && rhs.st_mode & S_IFMT == S_IFREG
    }

    private static func isTrustedCatalogURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host?.lowercased() == "github.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        let path = components.percentEncodedPath
        return path.hasPrefix("/rocksdanister/")
            && path.contains("/releases/download/")
            && path.hasSuffix(".zip")
    }

    private static func isTrustedResponseURL(_ url: URL?, requestedURL: URL) -> Bool {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased() else {
            return false
        }
        if host == "github.com" {
            return components.path == requestedURL.path
                && components.query == nil
                && components.fragment == nil
        }
        return (host == "objects.githubusercontent.com"
                || host == "release-assets.githubusercontent.com")
            && components.fragment == nil
    }

    private static func isSHA256(_ value: String) -> Bool {
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        return value.utf8.count == 64
            && value.lowercased().unicodeScalars.allSatisfy(hexadecimal.contains)
    }
}
