import CryptoKit
import Foundation

/// Seam over `FileManager`'s trash/remove operations so tests can verify the
/// library-asset removal path prefers Trash (recoverable) over a permanent
/// delete, and can simulate a volume that doesn't support Trash.
public protocol AssetTrashing: Sendable {
    /// Moves `url` to the Trash. Mirrors `FileManager.trashItem(at:resultingItemURL:)`.
    func trashItem(at url: URL) throws
    /// Permanently deletes `url`. Mirrors `FileManager.removeItem(at:)`.
    func removeItem(at url: URL) throws
}

public struct FileManagerAssetTrasher: AssetTrashing {
    public init() {}

    public func trashItem(at url: URL) throws {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

private struct OpenVideoInput {
    let handle: FileHandle
    let suffix: String
    let expectedFileHash: String?
}

/// Immutable, descriptor-bound source consumed by FFmpeg. The open file and
/// its parent directory remain pinned until conversion ends. Cleanup compares
/// the original inode and unlinks only that exact regular file relative to the
/// pinned directory, never a path replacement supplied later.
public final class PinnedVideoInput: @unchecked Sendable {
    public let url: URL
    public let contentHash: String
    let fileHandle: FileHandle

    private let directoryDescriptor: Int32
    private let fileName: String
    private let device: dev_t
    private let inode: ino_t
    private let lock = NSLock()
    private var isCleaned = false

    fileprivate init(
        url: URL,
        contentHash: String,
        fileHandle: FileHandle,
        directoryDescriptor: Int32,
        fileName: String,
        device: dev_t,
        inode: ino_t
    ) {
        self.url = url
        self.contentHash = contentHash
        self.fileHandle = fileHandle
        self.directoryDescriptor = directoryDescriptor
        self.fileName = fileName
        self.device = device
        self.inode = inode
    }

    deinit {
        cleanup()
    }

    public func cleanup() {
        lock.withLock {
            guard !isCleaned else { return }
            isCleaned = true
            try? fileHandle.close()
            var attributes = stat()
            let status = fileName.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &attributes, AT_SYMLINK_NOFOLLOW)
            }
            if status == 0,
               attributes.st_mode & S_IFMT == S_IFREG,
               attributes.st_dev == device,
               attributes.st_ino == inode {
                _ = fileName.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
            }
            Darwin.close(directoryDescriptor)
        }
    }
}

protocol LibraryManifestWriting: Sendable {
    func write(_ data: Data, to url: URL) throws
}

private struct AtomicLibraryManifestWriter: LibraryManifestWriting {
    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }
}

protocol StandaloneFileCopying: Sendable {
    func copyItem(at source: URL, to destination: URL) throws
}

struct FileManagerStandaloneFileCopier: StandaloneFileCopying {
    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

protocol ProjectDirectoryCopying: Sendable {
    func copyItem(at source: URL, to destination: URL) throws
}

struct FileManagerProjectDirectoryCopier: ProjectDirectoryCopying {
    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

public struct LibraryStore: Sendable {
    public let root: URL
    private let trasher: AssetTrashing
    private let accessLock: LibraryStoreAccessLock
    private let manifestWriter: any LibraryManifestWriting
    private let standaloneFileCopier: any StandaloneFileCopying
    private let projectDirectoryCopier: any ProjectDirectoryCopying
    private let convertedVideoCacheDirectory: URL

    public init(root: URL, trasher: AssetTrashing = FileManagerAssetTrasher()) {
        self.init(
            root: root,
            trasher: trasher,
            manifestWriter: AtomicLibraryManifestWriter(),
            standaloneFileCopier: FileManagerStandaloneFileCopier(),
            projectDirectoryCopier: FileManagerProjectDirectoryCopier(),
            convertedVideoCacheDirectory: VideoConversionCacheLocation.defaultDirectory()
        )
    }

    /// Creates a library whose derived video cache lives at an explicit
    /// location. The production default remains Application Support; this
    /// overload also lets runtime-recovery tests and portable installations
    /// keep manifest commits and bounded cache cleanup on the same root.
    public init(
        root: URL,
        trasher: AssetTrashing = FileManagerAssetTrasher(),
        convertedVideoCacheDirectory: URL
    ) {
        self.init(
            root: root,
            trasher: trasher,
            manifestWriter: AtomicLibraryManifestWriter(),
            standaloneFileCopier: FileManagerStandaloneFileCopier(),
            projectDirectoryCopier: FileManagerProjectDirectoryCopier(),
            convertedVideoCacheDirectory: convertedVideoCacheDirectory
        )
    }

    init(root: URL, projectDirectoryCopier: any ProjectDirectoryCopying) {
        self.init(
            root: root,
            trasher: FileManagerAssetTrasher(),
            manifestWriter: AtomicLibraryManifestWriter(),
            standaloneFileCopier: FileManagerStandaloneFileCopier(),
            projectDirectoryCopier: projectDirectoryCopier,
            convertedVideoCacheDirectory: VideoConversionCacheLocation.defaultDirectory()
        )
    }

    init(
        root: URL,
        trasher: AssetTrashing,
        manifestWriter: any LibraryManifestWriting,
        standaloneFileCopier: any StandaloneFileCopying = FileManagerStandaloneFileCopier(),
        projectDirectoryCopier: any ProjectDirectoryCopying = FileManagerProjectDirectoryCopier(),
        convertedVideoCacheDirectory: URL = VideoConversionCacheLocation.defaultDirectory()
    ) {
        self.root = root
        self.trasher = trasher
        self.manifestWriter = manifestWriter
        self.standaloneFileCopier = standaloneFileCopier
        self.projectDirectoryCopier = projectDirectoryCopier
        self.convertedVideoCacheDirectory = convertedVideoCacheDirectory.standardizedFileURL
        accessLock = LibraryStoreAccessLockRegistry.lock(for: root)
    }

    func usingConvertedVideoCacheDirectory(_ directory: URL) -> LibraryStore {
        LibraryStore(
            root: root,
            trasher: trasher,
            manifestWriter: manifestWriter,
            standaloneFileCopier: standaloneFileCopier,
            projectDirectoryCopier: projectDirectoryCopier,
            convertedVideoCacheDirectory: directory
        )
    }

    public func load() throws -> LibraryManifest {
        try accessLock.withLock {
            let manifestURL = root.appending(path: "library.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                return LibraryManifest(generatedAt: Date(), assets: [])
            }
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder.bridge.decode(LibraryManifest.self, from: data)
            let repaired = repairStoredAssets(in: manifest)
            if repaired != manifest {
                try? save(repaired)
            }
            return repaired
        }
    }

    public func importAsset(_ asset: WallpaperAsset) throws -> WallpaperAsset {
        let source = URL(filePath: asset.projectDirectory)
        return try importAsset(asset) { staging in
            try validateCopiedProjectTree(staging)
            return rewrite(asset: asset, source: source, target: staging).replacing(
                contentHash: try WallpaperContentHasher.hashDirectory(staging)
            )
        }
    }

    func importAsset(
        _ asset: WallpaperAsset,
        prepareStagedAsset: (URL) throws -> WallpaperAsset
    ) throws -> WallpaperAsset {
        try FileManager.default.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        let directoryName = storageDirectoryName(for: asset.id)
        let replacement = assetsRoot.appending(path: ".\(directoryName).incoming-\(UUID().uuidString)")
        let stagedAsset: WallpaperAsset
        do {
            try projectDirectoryCopier.copyItem(
                at: URL(filePath: asset.projectDirectory),
                to: replacement
            )
            // This directory is owned by Background Engine, not authored
            // wallpaper content. Never import a source-provided copy; a valid
            // previous customization is transferred transactionally below.
            try removeReservedWebPropertyStorage(from: replacement)
            stagedAsset = try prepareStagedAsset(replacement)
        } catch {
            try? FileManager.default.removeItem(at: replacement)
            throw error
        }
        let retiredDirectory: URL?
        var failedDirectory: URL?
        var duplicateAsset: WallpaperAsset?
        var committedAsset: WallpaperAsset?
        do {
            retiredDirectory = try accessLock.withLock {
                var manifest = try load()
                let workshopMatch = stagedAsset.workshopId.flatMap { workshopID in
                    manifest.assets.first { $0.workshopId == workshopID }
                }
                if let duplicate = workshopMatch,
                   duplicate.contentHash == stagedAsset.contentHash {
                    duplicateAsset = duplicate
                    return nil
                }
                if workshopMatch == nil,
                   let contentHash = stagedAsset.contentHash,
                   let duplicate = manifest.assets.first(where: { $0.contentHash == contentHash }) {
                    duplicateAsset = duplicate
                    return nil
                }

                // A Workshop ID identifies one logical wallpaper, but its
                // bytes can legitimately change when the author publishes an
                // update. Keep the stable library ID/display assignments while
                // atomically replacing stale content. Network permission is
                // reset for changed Web code so an update cannot inherit trust
                // that was granted to different bytes.
                let committedID = workshopMatch?.id ?? asset.id
                let committedDirectoryName = storageDirectoryName(for: committedID)
                let target = assetsRoot.appending(path: committedDirectoryName)
                let backup = assetsRoot.appending(
                    path: ".\(committedDirectoryName).previous-\(UUID().uuidString)"
                )
                let rewritten = rewrite(asset: stagedAsset, source: replacement, target: target)
                let imported = workshopMatch.map {
                    preservingWorkshopIdentity(of: $0, with: rewritten)
                } ?? rewritten
                let retired = try replaceDirectory(target: target, replacement: replacement, backup: backup)
                let existingLogicalAsset = workshopMatch
                    ?? manifest.assets.first(where: { $0.id == imported.id })
                var preservedWebProperties = false
                do {
                    preservedWebProperties = try preserveWebPropertyStorageIfNeeded(
                        existing: existingLogicalAsset,
                        updated: imported,
                        retiredProject: retired,
                        installedProject: target
                    )
                    let replacedIDs: Set<WallpaperAsset.ID> = workshopMatch == nil
                        ? [asset.id, imported.id]
                        : [imported.id]
                    manifest = LibraryManifest(
                        generatedAt: Date(),
                        assets: (manifest.assets.filter {
                            !replacedIDs.contains($0.id)
                                && !(stagedAsset.workshopId != nil && $0.workshopId == stagedAsset.workshopId)
                        } + [imported])
                            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
                        displayAssignments: manifest.displayAssignments
                    )
                    try save(manifest)
                } catch let commitError {
                    failedDirectory = try rollbackDirectoryReplacement(
                        target: target,
                        backup: retired
                    )
                    if preservedWebProperties, let failedDirectory {
                        try restoreWebPropertyStorageAfterRollback(
                            from: failedDirectory,
                            to: target
                        )
                    }
                    throw commitError
                }
                removeObsoleteConvertedVideo(
                    from: workshopMatch,
                    unlessReferencedBy: manifest.assets,
                    replacingWith: imported
                )
                committedAsset = imported
                return retired
            }
        } catch {
            try? FileManager.default.removeItem(at: replacement)
            if let failedDirectory {
                try? FileManager.default.removeItem(at: failedDirectory)
            }
            throw error
        }
        if let duplicateAsset {
            try? FileManager.default.removeItem(at: replacement)
            return duplicateAsset
        }
        if let retiredDirectory {
            try? FileManager.default.removeItem(at: retiredDirectory)
        }
        guard let committedAsset else {
            throw LibraryStoreError.missingAsset(asset.id)
        }
        return committedAsset
    }

    private func validateCopiedProjectTree(_ root: URL) throws {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw WallpaperImportError.unsafeRoot(root.path)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            throw WallpaperImportError.cannotEnumerate(root.path)
        }
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw WallpaperImportError.symbolicLink(url.path)
            }
        }
    }

    private func removeReservedWebPropertyStorage(from project: URL) throws {
        let storage = project.appending(path: WebWallpaperUserFileStore.directoryName)
        var attributes = stat()
        let result = storage.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &attributes)
        }
        if result != 0 {
            if errno == ENOENT { return }
            throw WallpaperImportError.unsafeRoot(storage.path)
        }
        try FileManager.default.removeItem(at: storage)
    }

    private func preserveWebPropertyStorageIfNeeded(
        existing: WallpaperAsset?,
        updated: WallpaperAsset,
        retiredProject: URL?,
        installedProject: URL
    ) throws -> Bool {
        guard existing?.kind == .web,
              updated.kind == .web,
              let retiredProject else {
            return false
        }
        let source = retiredProject.appending(path: WebWallpaperUserFileStore.directoryName)
        var attributes = stat()
        let result = source.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &attributes)
        }
        if result != 0 {
            if errno == ENOENT { return false }
            throw WallpaperImportError.unsafeRoot(source.path)
        }
        guard attributes.st_mode & S_IFMT == S_IFDIR else {
            throw WallpaperImportError.unsafeRoot(source.path)
        }
        try validateCopiedProjectTree(source)
        let destination = installedProject.appending(
            path: WebWallpaperUserFileStore.directoryName
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WallpaperImportError.unsafeRoot(destination.path)
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return true
    }

    private func restoreWebPropertyStorageAfterRollback(from failedProject: URL, to restoredProject: URL) throws {
        let source = failedProject.appending(path: WebWallpaperUserFileStore.directoryName)
        let destination = restoredProject.appending(path: WebWallpaperUserFileStore.directoryName)
        guard FileManager.default.fileExists(atPath: source.path),
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw WallpaperImportError.unsafeRoot(destination.path)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func importVideoFile(_ url: URL) throws -> WallpaperAsset {
        try importStandaloneFile(url, requiredKind: .video, metadataType: "video")
    }

    /// Imports a single user-selected wallpaper file by probing its contents.
    /// Supported standalone inputs are videos, ImageIO-decodable still or
    /// animated images, and Wallpaper Engine PKGV Scene packages.
    public func importMediaFile(_ url: URL) throws -> WallpaperAsset {
        try importStandaloneFile(url, requiredKind: nil, metadataType: nil)
    }

    private func importStandaloneFile(
        _ url: URL,
        requiredKind: WallpaperKind?,
        metadataType: String?
    ) throws -> WallpaperAsset {
        let source = url.standardizedFileURL
        guard isRegularFile(source) else {
            throw LibraryStoreError.notRegularFile(source.path)
        }
        let ext = source.pathExtension.lowercased()
        try FileManager.default.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        let id = "manual-\(UUID().uuidString)"
        let directoryName = storageDirectoryName(for: id)
        let target = assetsRoot.appending(path: directoryName)
        let replacement = assetsRoot.appending(path: ".\(directoryName).incoming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        var stagedEntrypoint = replacement.appending(path: source.lastPathComponent)
        do {
            try standaloneFileCopier.copyItem(at: source, to: stagedEntrypoint)
            guard isRegularFile(stagedEntrypoint) else {
                throw LibraryStoreError.notRegularFile(stagedEntrypoint.path)
            }
        } catch {
            try? FileManager.default.removeItem(at: replacement)
            throw error
        }

        // Probe and hash the immutable library staging copy, never the caller's
        // mutable source path. The stored bytes, classification and content hash
        // therefore describe the same snapshot even if the source changes while
        // the import is running.
        let classification = MediaContentProbe().classify(stagedEntrypoint, metadataType: metadataType)
        let supportsStandaloneImport = classification.kind == .video
            || classification.kind == .image
            || classification.kind == .scene
        guard supportsStandaloneImport,
              requiredKind == nil || classification.kind == requiredKind,
              [.playable, .needsConversion].contains(classification.supportStatus) else {
            try? FileManager.default.removeItem(at: replacement)
            if requiredKind == .video {
                throw LibraryStoreError.unsupportedVideoExtension(ext)
            }
            throw LibraryStoreError.unsupportedMedia(source.lastPathComponent)
        }

        // Scene playback expects a PKGV package path. A valid package selected
        // with a missing or renamed extension is canonicalized inside the
        // private library instead of being classified as playable and failing
        // later in the renderer.
        if classification.kind == .scene, stagedEntrypoint.pathExtension.lowercased() != "pkg" {
            let canonicalEntrypoint = replacement.appending(path: "scene.pkg")
            do {
                try FileManager.default.moveItem(at: stagedEntrypoint, to: canonicalEntrypoint)
                stagedEntrypoint = canonicalEntrypoint
            } catch {
                try? FileManager.default.removeItem(at: replacement)
                throw error
            }
        }

        let entrypoint = target.appending(path: stagedEntrypoint.lastPathComponent)
        let contentHash: String
        do {
            contentHash = try WallpaperContentHasher.hashFile(stagedEntrypoint)
        } catch {
            try? FileManager.default.removeItem(at: replacement)
            throw error
        }
        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: classification.kind,
            status: classification.supportStatus,
            entrypoint: stagedEntrypoint
        )
        let importedSupportStatus = report.level == .unsupported
            ? SupportStatus.unsupported
            : classification.supportStatus
        let imported = WallpaperAsset(
            id: id,
            title: source.deletingPathExtension().lastPathComponent,
            kind: classification.kind,
            supportStatus: importedSupportStatus,
            source: .manualFolder,
            projectDirectory: target.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            contentHash: contentHash,
            compatibility: report.supportMode,
            compatibilityReport: report,
            redistributionAllowed: false,
            issues: classification.supportStatus == .needsConversion
                ? [ScanIssue(code: "needs_conversion", message: "This video needs local conversion before playback.")]
                : []
        )
        let backup = assetsRoot.appending(path: ".\(directoryName).previous-\(UUID().uuidString)")
        let retiredDirectory: URL?
        var failedDirectory: URL?
        var duplicateAsset: WallpaperAsset?
        do {
            retiredDirectory = try accessLock.withLock {
                var manifest = try load()
                if let duplicate = manifest.assets.first(where: { $0.contentHash == contentHash }) {
                    duplicateAsset = duplicate
                    return nil
                }
                let retired = try replaceDirectory(target: target, replacement: replacement, backup: backup)
                manifest = LibraryManifest(
                    generatedAt: Date(),
                    assets: (manifest.assets + [imported])
                        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
                    displayAssignments: manifest.displayAssignments
                )
                do {
                    try save(manifest)
                } catch let commitError {
                    failedDirectory = try rollbackDirectoryReplacement(
                        target: target,
                        backup: retired
                    )
                    throw commitError
                }
                return retired
            }
        } catch {
            try? FileManager.default.removeItem(at: replacement)
            if let failedDirectory {
                try? FileManager.default.removeItem(at: failedDirectory)
            }
            throw error
        }
        if let duplicateAsset {
            try? FileManager.default.removeItem(at: replacement)
            return duplicateAsset
        }
        if let retiredDirectory {
            try? FileManager.default.removeItem(at: retiredDirectory)
        }
        return imported
    }

    public func replaceAsset(_ asset: WallpaperAsset) throws {
        try accessLock.withLock {
            var manifest = try load()
            let existing = manifest.assets.first { $0.id == asset.id }
            manifest = LibraryManifest(
                generatedAt: Date(),
                assets: (manifest.assets.filter { $0.id != asset.id } + [asset])
                    .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
                displayAssignments: manifest.displayAssignments
            )
            try save(manifest)
            removeObsoleteConvertedVideo(
                from: existing,
                unlessReferencedBy: manifest.assets,
                replacingWith: asset
            )
        }
    }

    /// Atomically replaces an asset only if no importer or runtime update has
    /// changed it since the caller took its snapshot.
    @discardableResult
    public func replaceAsset(
        _ asset: WallpaperAsset,
        ifUnchangedFrom expected: WallpaperAsset
    ) throws -> Bool {
        try accessLock.withLock {
            var manifest = try load()
            guard manifest.assets.first(where: { $0.id == expected.id }) == expected else {
                return false
            }
            let existing = manifest.assets.first { $0.id == expected.id }
            manifest = LibraryManifest(
                generatedAt: Date(),
                assets: (manifest.assets.filter { $0.id != asset.id } + [asset])
                    .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
                displayAssignments: manifest.displayAssignments
            )
            try save(manifest)
            removeObsoleteConvertedVideo(
                from: existing,
                unlessReferencedBy: manifest.assets,
                replacingWith: asset
            )
            return true
        }
    }

    /// Copies the original imported video behind an already-converted asset
    /// into an immutable cache snapshot. The source is opened relative to a
    /// pinned, no-follow project-directory descriptor while the library lock
    /// is held, so a concurrent import or symlink swap cannot redirect FFmpeg
    /// to another asset. Standalone imports are recovered by their file hash,
    /// including valid sources named `project.json` or beginning with a dot.
    public func copyVideoConversionSource(
        for expected: WallpaperAsset,
        into directory: URL
    ) throws -> PinnedVideoInput {
        let opened = try accessLock.withLock {
            let manifest = try load()
            guard let current = manifest.assets.first(where: { $0.id == expected.id }),
                  sameVideoRevision(current, expected),
                  current.compatibilityReport?.playbackPath == .convertedVideo else {
                throw WallpaperImportError.assetRemovedDuringPreparation(expected.id)
            }
            let projectRoot = try managedProjectRoot(for: current)
            let rootDescriptor = try openDirectoryWithoutFollowingSymlinks(projectRoot)
            defer { Darwin.close(rootDescriptor) }

            if let relativePath = storedProjectEntrypoint(rootDescriptor: rootDescriptor),
               let sourceDescriptor = try? openRegularFile(
                   relativePath: relativePath,
                   rootDescriptor: rootDescriptor
               ) {
                return OpenVideoInput(
                    handle: FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true),
                    suffix: URL(filePath: relativePath).pathExtension,
                    expectedFileHash: nil
                )
            }

            let relativePath = try soleStandaloneVideoPath(
                in: projectRoot,
                asset: current
            )
            let sourceDescriptor = try openRegularFile(
                relativePath: relativePath,
                rootDescriptor: rootDescriptor
            )
            guard let contentHash = current.contentHash else {
                Darwin.close(sourceDescriptor)
                throw LibraryStoreError.missingVideoConversionSource(current.id)
            }
            return OpenVideoInput(
                handle: FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true),
                suffix: URL(filePath: relativePath).pathExtension,
                expectedFileHash: contentHash
            )
        }
        return try copyOpenedVideoInput(opened, into: directory)
    }

    /// Opens the current library entrypoint while holding the root transaction
    /// lock, then copies through that open descriptor after releasing the
    /// lock. A Workshop update can rename/remove the old project meanwhile,
    /// but the descriptor still identifies the exact bytes described by
    /// `expected` and its content hash.
    public func copyStableVideoInput(
        for expected: WallpaperAsset,
        originalInput: URL,
        into directory: URL
    ) throws -> PinnedVideoInput {
        let opened = try accessLock.withLock {
            let manifest = try load()
            guard let current = manifest.assets.first(where: { $0.id == expected.id }),
                  current.supportStatus == .needsConversion,
                  sameVideoRevision(current, expected),
                  current.entrypoint == originalInput.path else {
                throw WallpaperImportError.assetRemovedDuringPreparation(expected.id)
            }
            let projectRoot = try managedProjectRoot(for: current)
            guard let relativePath = relativePath(of: originalInput, under: URL(filePath: current.projectDirectory)) else {
                throw WallpaperImportError.notRegularFile(originalInput.path)
            }
            let rootDescriptor = try openDirectoryWithoutFollowingSymlinks(projectRoot)
            defer { Darwin.close(rootDescriptor) }
            let sourceDescriptor = try openRegularFile(
                relativePath: relativePath,
                rootDescriptor: rootDescriptor
            )
            return OpenVideoInput(
                handle: FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true),
                suffix: originalInput.pathExtension,
                expectedFileHash: nil
            )
        }
        return try copyOpenedVideoInput(opened, into: directory)
    }

    /// Opens a playable direct-video entrypoint by descriptor while holding
    /// the manifest transaction lock. This is the runtime-recovery equivalent
    /// of `copyStableVideoInput`: AVFoundation may accept a file during import
    /// and still fail to decode it after playback begins, so FFmpeg needs an
    /// immutable snapshot without weakening the revision or symlink checks.
    public func copyStableDirectVideoInput(
        for expected: WallpaperAsset,
        into directory: URL
    ) throws -> PinnedVideoInput {
        let opened = try accessLock.withLock {
            let manifest = try load()
            guard let current = manifest.assets.first(where: { $0.id == expected.id }),
                  current.supportStatus == .playable,
                  current.compatibilityReport?.playbackPath == .direct,
                  sameVideoRevision(current, expected),
                  let entrypoint = current.entrypoint else {
                throw WallpaperImportError.assetRemovedDuringPreparation(expected.id)
            }
            let projectRoot = try managedProjectRoot(for: current)
            let input = URL(filePath: entrypoint)
            guard let relativePath = relativePath(
                of: input,
                under: URL(filePath: current.projectDirectory)
            ) else {
                throw WallpaperImportError.notRegularFile(entrypoint)
            }
            let rootDescriptor = try openDirectoryWithoutFollowingSymlinks(projectRoot)
            defer { Darwin.close(rootDescriptor) }
            let sourceDescriptor = try openRegularFile(
                relativePath: relativePath,
                rootDescriptor: rootDescriptor
            )
            return OpenVideoInput(
                handle: FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true),
                suffix: input.pathExtension,
                expectedFileHash: nil
            )
        }
        return try copyOpenedVideoInput(opened, into: directory)
    }

    /// Removes only the exact derived cache file after a shared conversion has
    /// lost its compare-and-swap to a newer Workshop revision. The manifest
    /// check and deletion share the library lock so a referenced cache cannot
    /// be collected between those two operations.
    public func removeConvertedVideoIfUnreferenced(_ output: URL, contentHash: String) {
        try? accessLock.withLock {
            let manifest = try load()
            guard !manifest.assets.contains(where: { $0.entrypoint == output.path }) else {
                return
            }
            removeConvertedVideoAtExactCachePath(
                output,
                allowedFileNames: [VideoConversionCacheKey(contentHash: contentHash).fileName]
            )
        }
    }

    public func setWebNetworkAccess(assetID: WallpaperAsset.ID, allowed: Bool) throws -> WallpaperAsset {
        try accessLock.withLock {
            let manifest = try load()
            guard let asset = manifest.assets.first(where: { $0.id == assetID }) else {
                throw LibraryStoreError.missingAsset(assetID)
            }
            guard asset.kind == .web else {
                return asset
            }
            let updated = asset.allowingNetworkAccess(allowed)
            try replaceAsset(updated)
            return updated
        }
    }

    public func saveDisplayAssignment(_ assignment: DisplayAssignment) throws {
        try accessLock.withLock {
            let manifest = try load()
            let assignments = (
                manifest.displayAssignments.filter { $0.displayUUID != assignment.displayUUID } + [assignment]
            )
            .sorted { $0.displayUUID < $1.displayUUID }
            try save(
                LibraryManifest(
                    generatedAt: Date(),
                    assets: manifest.assets,
                    displayAssignments: assignments
                )
            )
        }
    }

    public func replaceDisplayAssignments(_ assignments: [DisplayAssignment]) throws {
        try accessLock.withLock {
            let manifest = try load()
            let knownAssetIDs = Set(manifest.assets.map(\.id))
            let normalized = normalizeDisplayAssignments(assignments, knownAssetIDs: knownAssetIDs)
            try save(
                LibraryManifest(
                    generatedAt: Date(),
                    assets: manifest.assets,
                    displayAssignments: normalized
                )
            )
        }
    }

    public func installSceneRenderCache(assetID: WallpaperAsset.ID, videoURL: URL) throws -> WallpaperAsset {
        let source = videoURL.standardizedFileURL
        guard SceneRenderCache.isPlayableVideoFile(source) else {
            if isRegularFile(source) {
                throw LibraryStoreError.unsupportedVideoExtension(source.pathExtension.lowercased())
            }
            throw LibraryStoreError.notRegularFile(source.path)
        }

        let manifest = try load()
        guard let asset = manifest.assets.first(where: { $0.id == assetID }) else {
            throw LibraryStoreError.missingAsset(assetID)
        }
        guard asset.kind == .scene else {
            throw LibraryStoreError.assetIsNotScene(assetID)
        }

        let projectDirectory = URL(filePath: asset.projectDirectory).standardizedFileURL
        guard isInsideAssetsRoot(projectDirectory) else {
            throw LibraryStoreError.assetOutsideLibrary(assetID)
        }

        let cacheDirectory = SceneRenderCache.cacheDirectory(in: projectDirectory)
        guard !isSymbolicLink(cacheDirectory) else {
            throw LibraryStoreError.unsafeSceneRenderCacheDirectory(assetID)
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        guard isInside(cacheDirectory, parent: projectDirectory) else {
            throw LibraryStoreError.unsafeSceneRenderCacheDirectory(assetID)
        }
        let destination = SceneRenderCache.videoURL(
            in: projectDirectory,
            fileExtension: source.pathExtension
        )
        let stagedVideo: URL?
        if source.resolvingSymlinksInPath().path != destination.resolvingSymlinksInPath().path {
            let temporary = cacheDirectory.appending(
                path: ".\(SceneRenderCache.baseFileName)-\(UUID().uuidString).\(source.pathExtension)"
            )
            try FileManager.default.copyItem(at: source, to: temporary)
            stagedVideo = temporary
        } else {
            stagedVideo = nil
        }

        let cacheIssue = ScanIssue(
            code: SceneRenderCache.issueCode,
            message: "A local rendered scene video cache is attached for reference only; desktop scene playback uses the native renderer."
        )
        // Package parsing and full native texture decoding can be expensive;
        // perform them before taking the short manifest transaction lock.
        let probed = probeSceneCompatibility(for: asset)
        let analyzed = probed.compatibilityReport
        var retiredCacheFiles: [URL] = []
        var failedCacheFile: URL?
        let updated: WallpaperAsset
        do {
            updated = try accessLock.withLock {
                let currentManifest = try load()
                guard let current = currentManifest.assets.first(where: { $0.id == assetID }) else {
                    throw LibraryStoreError.missingAsset(assetID)
                }
                guard current.projectDirectory == asset.projectDirectory,
                      current.entrypoint == asset.entrypoint,
                      current.contentHash == asset.contentHash else {
                    throw LibraryStoreError.assetChangedDuringOperation(assetID)
                }
                guard current.kind == .scene else {
                    throw LibraryStoreError.assetIsNotScene(assetID)
                }
                let currentProject = URL(filePath: current.projectDirectory).standardizedFileURL
                let currentCacheDirectory = SceneRenderCache.cacheDirectory(in: currentProject)
                guard isInsideAssetsRoot(currentProject),
                      !isSymbolicLink(currentCacheDirectory),
                      isInside(currentCacheDirectory, parent: currentProject) else {
                    throw LibraryStoreError.unsafeSceneRenderCacheDirectory(assetID)
                }

                var backups: [(original: URL, backup: URL)] = []
                var didInstallStagedVideo = false
                do {
                    if let stagedVideo {
                        for cached in SceneRenderCache.cacheCandidates(in: currentProject)
                            where FileManager.default.fileExists(atPath: cached.path) {
                            let backup = cached.deletingLastPathComponent().appending(
                                path: ".\(cached.lastPathComponent).previous-\(UUID().uuidString)"
                            )
                            try FileManager.default.moveItem(at: cached, to: backup)
                            backups.append((cached, backup))
                        }
                        try FileManager.default.moveItem(at: stagedVideo, to: destination)
                        didInstallStagedVideo = true
                    }

                    let analyzedLevel = analyzed?.level ?? .full
                    let cacheReport = CompatibilityReport(
                        level: analyzedLevel == .unsupported ? .full : analyzedLevel,
                        playbackPath: .renderedSceneCache,
                        requiredCapabilities: analyzed?.requiredCapabilities ?? [],
                        missingCapabilities: analyzed?.missingCapabilities ?? [],
                        warnings: (analyzed?.warnings ?? []) + ["A rendered Scene video cache is installed."],
                        diagnosticCode: analyzedLevel == .unsupported ? nil : analyzed?.diagnosticCode
                    )
                    let result = WallpaperAsset(
                        id: current.id,
                        title: current.title,
                        kind: current.kind,
                        supportStatus: probed.supportStatus,
                        source: current.source,
                        projectDirectory: current.projectDirectory,
                        entrypoint: current.entrypoint,
                        thumbnail: current.thumbnail,
                        workshopId: current.workshopId,
                        dateAdded: current.dateAdded,
                        contentHash: current.contentHash,
                        compatibility: cacheReport.supportMode,
                        compatibilityReport: cacheReport,
                        allowsNetworkAccess: current.allowsNetworkAccess,
                        redistributionAllowed: false,
                        issues: mergedIssues(probed.issues + [cacheIssue])
                    )
                    let updatedManifest = LibraryManifest(
                        generatedAt: Date(),
                        assets: (currentManifest.assets.filter { $0.id != assetID } + [result])
                            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
                        displayAssignments: currentManifest.displayAssignments
                    )
                    try save(updatedManifest)
                    retiredCacheFiles = backups.map(\.backup)
                    return result
                } catch let commitError {
                    if didInstallStagedVideo, FileManager.default.fileExists(atPath: destination.path) {
                        let failed = destination.deletingLastPathComponent().appending(
                            path: ".\(destination.lastPathComponent).failed-\(UUID().uuidString)"
                        )
                        try FileManager.default.moveItem(at: destination, to: failed)
                        failedCacheFile = failed
                    }
                    for pair in backups.reversed()
                        where FileManager.default.fileExists(atPath: pair.backup.path) {
                        try FileManager.default.moveItem(at: pair.backup, to: pair.original)
                    }
                    throw commitError
                }
            }
        } catch {
            if let stagedVideo, FileManager.default.fileExists(atPath: stagedVideo.path) {
                try? FileManager.default.removeItem(at: stagedVideo)
            }
            if let failedCacheFile {
                try? FileManager.default.removeItem(at: failedCacheFile)
            }
            throw error
        }
        for retired in retiredCacheFiles {
            try? FileManager.default.removeItem(at: retired)
        }
        return updated
    }

    public func removeAsset(id: WallpaperAsset.ID) throws {
        let transaction: (
            asset: WallpaperAsset,
            originalDirectory: URL,
            retiredDirectory: URL,
            assignments: [DisplayAssignment]
        )? = try accessLock.withLock {
            let manifest = try load()
            guard let removed = manifest.assets.first(where: { $0.id == id }) else {
                return nil
            }
            let remaining = manifest.assets.filter { $0.id != id }
            let assignments = manifest.displayAssignments.map { assignment in
                guard assignment.assetID == id else { return assignment }
                return DisplayAssignment(
                    displayUUID: assignment.displayUUID,
                    assetID: nil,
                    displayMode: assignment.displayMode,
                    quality: assignment.quality,
                    audioSource: .muted
                )
            }
            let directory = URL(filePath: removed.projectDirectory).standardizedFileURL
            let retired: URL?
            if isInsideAssetsRoot(directory), FileManager.default.fileExists(atPath: directory.path) {
                let candidate = assetsRoot.appending(
                    path: ".\(directory.lastPathComponent).retired-\(UUID().uuidString)"
                )
                try FileManager.default.moveItem(at: directory, to: candidate)
                retired = candidate
            } else {
                retired = nil
            }
            do {
                try save(
                    LibraryManifest(
                        generatedAt: Date(),
                        assets: remaining,
                        displayAssignments: assignments
                    )
                )
            } catch {
                if let retired, FileManager.default.fileExists(atPath: retired.path) {
                    try? FileManager.default.moveItem(at: retired, to: directory)
                }
                throw error
            }
            return retired.map {
                (
                    asset: removed,
                    originalDirectory: directory,
                    retiredDirectory: $0,
                    assignments: manifest.displayAssignments.filter { $0.assetID == id }
                )
            }
        }
        guard let transaction else {
            return
        }
        do {
            try removeLibraryDirectory(at: transaction.retiredDirectory)
        } catch let cleanupError {
            // If both Trash and permanent removal fail, restore the retired
            // directory and manifest entry when no newer import has claimed
            // the same asset id. The content therefore remains usable and
            // recoverable instead of becoming an untracked orphan.
            try? accessLock.withLock {
                var current = try load()
                guard !current.assets.contains(where: { $0.id == id }),
                      !FileManager.default.fileExists(atPath: transaction.originalDirectory.path),
                      FileManager.default.fileExists(atPath: transaction.retiredDirectory.path) else {
                    return
                }
                try FileManager.default.moveItem(
                    at: transaction.retiredDirectory,
                    to: transaction.originalDirectory
                )
                var assignments = current.displayAssignments
                for original in transaction.assignments {
                    if let index = assignments.firstIndex(where: { $0.displayUUID == original.displayUUID }) {
                        if assignments[index].assetID == nil {
                            assignments[index] = original
                        }
                    } else {
                        assignments.append(original)
                    }
                }
                current = LibraryManifest(
                    generatedAt: Date(),
                    assets: (current.assets + [transaction.asset])
                        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
                    displayAssignments: assignments.sorted { $0.displayUUID < $1.displayUUID }
                )
                do {
                    try save(current)
                } catch {
                    try? FileManager.default.moveItem(
                        at: transaction.originalDirectory,
                        to: transaction.retiredDirectory
                    )
                }
            }
            throw cleanupError
        }
    }

    public static func defaultStore() throws -> LibraryStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return LibraryStore(root: base.appending(path: "Background Engine"))
    }

    private var assetsRoot: URL {
        root.appending(path: "Assets")
    }

    private func save(_ manifest: LibraryManifest) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder.bridge.encode(manifest)
        try manifestWriter.write(data, to: root.appending(path: "library.json"))
    }

    /// Moves the asset's imported library directory to the Trash rather than
    /// deleting it outright, so a mistaken removal (or a removal of an asset
    /// whose original Workshop copy is already gone) stays recoverable. Falls
    /// back to a permanent delete only if the volume doesn't support Trash.
    private func removeLibraryDirectory(at directory: URL) throws {
        guard isInsideAssetsRoot(directory) else {
            return
        }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        do {
            try trasher.trashItem(at: directory)
        } catch {
            try trasher.removeItem(at: directory)
        }
    }

    private func isInsideAssetsRoot(_ url: URL) -> Bool {
        let rootComponents = assetsRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let urlComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard urlComponents.count > rootComponents.count else {
            return false
        }
        return zip(rootComponents, urlComponents).allSatisfy { $0 == $1 }
    }

    private func isInside(_ url: URL, parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let urlComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard urlComponents.count > parentComponents.count else {
            return false
        }
        return zip(parentComponents, urlComponents).allSatisfy { $0 == $1 }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func sameVideoRevision(_ current: WallpaperAsset, _ expected: WallpaperAsset) -> Bool {
        current.kind == .video
            && current.contentHash == expected.contentHash
            && current.entrypoint == expected.entrypoint
            && current.projectDirectory == expected.projectDirectory
            && current.workshopId == expected.workshopId
    }

    private func managedProjectRoot(for asset: WallpaperAsset) throws -> URL {
        let expected = assetsRoot
            .appending(path: storageDirectoryName(for: asset.id))
            .standardizedFileURL
        let declared = URL(filePath: asset.projectDirectory).standardizedFileURL
        guard declared == expected else {
            throw LibraryStoreError.missingVideoConversionSource(asset.id)
        }
        return expected
    }

    private func storedProjectEntrypoint(rootDescriptor: Int32) -> String? {
        guard let descriptor = try? openRegularFile(
            relativePath: "project.json",
            rootDescriptor: rootDescriptor
        ) else {
            return nil
        }
        defer { Darwin.close(descriptor) }
        guard let data = try? readBoundedFile(
            descriptor: descriptor,
            maximumByteCount: ProjectMetadata.maximumByteCount
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(ProjectMetadata.self, from: data).file
    }

    private func soleStandaloneVideoPath(
        in projectRoot: URL,
        asset: WallpaperAsset
    ) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw LibraryStoreError.missingVideoConversionSource(asset.id)
        }
        var candidates: [String] = []
        for case let url as URL in enumerator {
            guard candidates.count < 2,
                  let relativePath = relativePath(of: url, under: projectRoot),
                  let values = try? url.resourceValues(
                      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  url.path != asset.thumbnail else {
                continue
            }
            candidates.append(relativePath)
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw LibraryStoreError.missingVideoConversionSource(asset.id)
        }
        return candidate
    }

    private func relativePath(of url: URL, under root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count > rootComponents.count,
              Array(urlComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func openDirectoryWithoutFollowingSymlinks(_ directory: URL) throws -> Int32 {
        let standardized = directory.standardizedFileURL
        var before = stat()
        let inspected = standardized.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &before)
        }
        guard inspected == 0, before.st_mode & S_IFMT == S_IFDIR else {
            throw LibraryStoreError.missingVideoConversionSource(directory.path)
        }
        var resolvedBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedPath = standardized.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path, Darwin.realpath(path, &resolvedBuffer) != nil else { return nil }
            return String(
                decoding: resolvedBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
        }
        guard let resolvedPath else {
            throw LibraryStoreError.missingVideoConversionSource(directory.path)
        }
        guard isAllowedCanonicalPath(original: standardized.path, resolved: resolvedPath) else {
            throw LibraryStoreError.missingVideoConversionSource(directory.path)
        }
        let components = URL(filePath: resolvedPath).pathComponents
        guard components.first == "/" else {
            throw LibraryStoreError.missingVideoConversionSource(directory.path)
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw LibraryStoreError.missingVideoConversionSource(directory.path)
        }
        for component in components.dropFirst() where component != "/" {
            let next = component.withCString {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else {
                Darwin.close(descriptor)
                throw LibraryStoreError.missingVideoConversionSource(directory.path)
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
            throw LibraryStoreError.missingVideoConversionSource(directory.path)
        }
        return descriptor
    }

    private func openRegularFile(relativePath: String, rootDescriptor: Int32) throws -> Int32 {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.contains("\0"),
              !(normalized as NSString).isAbsolutePath,
              normalized.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil,
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LibraryStoreError.missingVideoConversionSource(relativePath)
        }

        var parentDescriptor = Darwin.dup(rootDescriptor)
        guard parentDescriptor >= 0 else {
            throw LibraryStoreError.missingVideoConversionSource(relativePath)
        }
        for component in components.dropLast() {
            let next = component.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard next >= 0 else {
                Darwin.close(parentDescriptor)
                throw LibraryStoreError.missingVideoConversionSource(relativePath)
            }
            Darwin.close(parentDescriptor)
            parentDescriptor = next
        }
        defer { Darwin.close(parentDescriptor) }

        let descriptor = components.last!.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            throw LibraryStoreError.missingVideoConversionSource(relativePath)
        }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw LibraryStoreError.missingVideoConversionSource(relativePath)
        }
        return descriptor
    }

    private func readBoundedFile(descriptor: Int32, maximumByteCount: Int) throws -> Data {
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size >= 0,
              attributes.st_size <= maximumByteCount else {
            throw LibraryStoreError.missingVideoConversionSource("metadata")
        }
        var data = Data()
        data.reserveCapacity(Int(attributes.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw LibraryStoreError.missingVideoConversionSource("metadata")
            }
            guard count <= maximumByteCount - data.count else {
                throw LibraryStoreError.missingVideoConversionSource("metadata")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func copyOpenedVideoInput(
        _ input: OpenVideoInput,
        into directory: URL
    ) throws -> PinnedVideoInput {
        defer { try? input.handle.close() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let directoryDescriptor = try openDirectoryWithoutFollowingSymlinks(directory)

        let suffix = input.suffix.isEmpty ? "bin" : input.suffix
        let fileName = ".video-input-\(UUID().uuidString).\(suffix)"
        let destinationDescriptor = fileName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard destinationDescriptor >= 0 else {
            Darwin.close(directoryDescriptor)
            throw LibraryStoreError.missingVideoConversionSource(fileName)
        }
        let destinationHandle = FileHandle(
            fileDescriptor: destinationDescriptor,
            closeOnDealloc: true
        )
        let snapshot = directory.appending(path: fileName)
        var digest = SHA256()
        do {
            while let chunk = try input.handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                digest.update(data: chunk)
                try destinationHandle.write(contentsOf: chunk)
            }
            guard Darwin.fsync(destinationDescriptor) == 0,
                  Darwin.lseek(destinationDescriptor, 0, SEEK_SET) == 0 else {
                throw LibraryStoreError.missingVideoConversionSource(fileName)
            }
            let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
            if let expectedFileHash = input.expectedFileHash {
                guard actual == expectedFileHash else {
                    throw LibraryStoreError.missingVideoConversionSource(fileName)
                }
            }
            var attributes = stat()
            guard Darwin.fstat(destinationDescriptor, &attributes) == 0,
                  attributes.st_mode & S_IFMT == S_IFREG else {
                throw LibraryStoreError.missingVideoConversionSource(fileName)
            }
            return PinnedVideoInput(
                url: snapshot,
                contentHash: actual,
                fileHandle: destinationHandle,
                directoryDescriptor: directoryDescriptor,
                fileName: fileName,
                device: attributes.st_dev,
                inode: attributes.st_ino
            )
        } catch {
            try? destinationHandle.close()
            _ = fileName.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
            Darwin.close(directoryDescriptor)
            throw error
        }
    }

    private func replaceDirectory(target: URL, replacement: URL, backup: URL) throws -> URL? {
        let exists = FileManager.default.fileExists(atPath: target.path)
        if exists {
            try FileManager.default.moveItem(at: target, to: backup)
        }
        do {
            try FileManager.default.moveItem(at: replacement, to: target)
        } catch {
            if exists, FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.moveItem(at: backup, to: target)
            }
            throw error
        }
        return exists ? backup : nil
    }

    /// Restores the previous target after a manifest commit failure. The new
    /// directory is renamed aside (never recursively deleted while locked)
    /// and returned for cleanup after the transaction releases its lock.
    private func rollbackDirectoryReplacement(target: URL, backup: URL?) throws -> URL? {
        var failedDirectory: URL?
        if FileManager.default.fileExists(atPath: target.path) {
            let failed = target.deletingLastPathComponent().appending(
                path: ".\(target.lastPathComponent).failed-\(UUID().uuidString)"
            )
            try FileManager.default.moveItem(at: target, to: failed)
            failedDirectory = failed
        }
        if let backup, FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.moveItem(at: backup, to: target)
        }
        return failedDirectory
    }

    private func rewrite(asset: WallpaperAsset, source: URL, target: URL) -> WallpaperAsset {
        WallpaperAsset(
            id: asset.id,
            title: asset.title,
            kind: asset.kind,
            supportStatus: asset.supportStatus,
            source: asset.source,
            projectDirectory: target.path,
            entrypoint: rewrite(path: asset.entrypoint, source: source, target: target),
            thumbnail: rewrite(path: asset.thumbnail, source: source, target: target),
            workshopId: asset.workshopId,
            dateAdded: asset.dateAdded,
            contentHash: asset.contentHash,
            compatibility: asset.compatibility,
            compatibilityReport: asset.compatibilityReport,
            allowsNetworkAccess: asset.allowsNetworkAccess,
            redistributionAllowed: false,
            issues: asset.issues
        )
    }

    private func preservingWorkshopIdentity(
        of existing: WallpaperAsset,
        with updated: WallpaperAsset
    ) -> WallpaperAsset {
        WallpaperAsset(
            id: existing.id,
            title: updated.title,
            kind: updated.kind,
            supportStatus: updated.supportStatus,
            source: updated.source,
            projectDirectory: updated.projectDirectory,
            entrypoint: updated.entrypoint,
            thumbnail: updated.thumbnail,
            workshopId: updated.workshopId,
            dateAdded: existing.dateAdded ?? updated.dateAdded,
            contentHash: updated.contentHash,
            compatibility: updated.compatibility,
            compatibilityReport: updated.compatibilityReport,
            allowsNetworkAccess: updated.kind == .web ? false : existing.allowsNetworkAccess,
            redistributionAllowed: false,
            issues: updated.issues
        )
    }

    private func removeObsoleteConvertedVideo(
        from existing: WallpaperAsset?,
        unlessReferencedBy assets: [WallpaperAsset],
        replacingWith updated: WallpaperAsset
    ) {
        guard let existing,
              existing.compatibilityReport?.playbackPath == .convertedVideo,
              existing.entrypoint != updated.entrypoint,
              let entrypoint = existing.entrypoint,
              let contentHash = existing.contentHash,
              !assets.contains(where: { $0.entrypoint == entrypoint }) else {
            return
        }
        let cacheKey = VideoConversionCacheKey(contentHash: contentHash)
        let allowedFileNames = cacheKey.previousRecipeFileNames.union([
            cacheKey.fileName,
            cacheKey.legacyV1FileName
        ])
        removeConvertedVideoAtExactCachePath(
            URL(filePath: entrypoint),
            allowedFileNames: allowedFileNames
        )
    }

    /// Deletes through a pinned directory descriptor after matching an exact
    /// recipe filename. The directory opener rejects every non-system symlink
    /// component, so replacing the cache root or one of its parents can never
    /// redirect cleanup outside the managed cache.
    private func removeConvertedVideoAtExactCachePath(
        _ candidate: URL,
        allowedFileNames: Set<String>
    ) {
        let cacheRoot = convertedVideoCacheDirectory.standardizedFileURL
        let safeCandidate = candidate.standardizedFileURL
        guard allowedFileNames.contains(safeCandidate.lastPathComponent),
              safeCandidate.deletingLastPathComponent() == cacheRoot,
              let directoryDescriptor = try? openDirectoryWithoutFollowingSymlinks(cacheRoot) else {
            return
        }
        defer { Darwin.close(directoryDescriptor) }
        let fileName = safeCandidate.lastPathComponent
        var attributes = stat()
        let status = fileName.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &attributes, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            return
        }
        _ = fileName.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
    }

    private func rewrite(path: String?, source: URL, target: URL) -> String? {
        guard let path else {
            return nil
        }
        let canonicalSource = source.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalPath = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        let sourceComponents = canonicalSource.pathComponents
        let pathComponents = canonicalPath.pathComponents
        guard pathComponents.count > sourceComponents.count,
              Array(pathComponents.prefix(sourceComponents.count)) == sourceComponents else {
            return path
        }
        let relative = pathComponents.dropFirst(sourceComponents.count).joined(separator: "/")
        return target.appending(path: relative).path
    }

    private func repairStoredAssets(in manifest: LibraryManifest) -> LibraryManifest {
        let assets = manifest.assets
            .map(repairLegacyPreviewEntrypoint)
            .map(refreshVideoConversionRecipe)
            .map(refreshCompatibilityReport)
        let assignments = normalizeDisplayAssignments(
            manifest.displayAssignments,
            knownAssetIDs: Set(assets.map(\.id))
        )
        guard assets != manifest.assets
                || assignments != manifest.displayAssignments
                || manifest.schemaVersion != LibraryManifest.currentSchemaVersion else {
            return manifest
        }
        return LibraryManifest(
            generatedAt: Date(),
            assets: assets,
            displayAssignments: assignments
        )
    }

    private func refreshVideoConversionRecipe(_ asset: WallpaperAsset) -> WallpaperAsset {
        guard asset.kind == .video,
              asset.supportStatus == .playable,
              asset.compatibilityReport?.playbackPath == .convertedVideo,
              let contentHash = asset.contentHash,
              let entrypoint = asset.entrypoint else {
            return asset
        }
        let expectedFileName = VideoConversionCacheKey(contentHash: contentHash).fileName
        let candidateFileName = URL(filePath: entrypoint).lastPathComponent
        let withoutRecipeIssue = asset.issues.filter {
            $0.code != VideoConverter.outdatedRecipeIssueCode
        }
        let refreshedIssues: [ScanIssue]
        if candidateFileName == expectedFileName {
            refreshedIssues = withoutRecipeIssue
        } else {
            refreshedIssues = [
                ScanIssue(
                    code: VideoConverter.outdatedRecipeIssueCode,
                    message: "This video uses an older conversion recipe. Choose Convert to rebuild it with corrected dimensions and authored-stream selection."
                )
            ] + withoutRecipeIssue
        }
        guard refreshedIssues != asset.issues else { return asset }
        return WallpaperAsset(
            id: asset.id,
            title: asset.title,
            kind: asset.kind,
            supportStatus: asset.supportStatus,
            source: asset.source,
            projectDirectory: asset.projectDirectory,
            entrypoint: asset.entrypoint,
            thumbnail: asset.thumbnail,
            workshopId: asset.workshopId,
            dateAdded: asset.dateAdded,
            contentHash: asset.contentHash,
            compatibility: asset.compatibility,
            compatibilityReport: asset.compatibilityReport,
            allowsNetworkAccess: asset.allowsNetworkAccess,
            redistributionAllowed: asset.redistributionAllowed,
            issues: refreshedIssues
        )
    }

    private func normalizeDisplayAssignments(
        _ assignments: [DisplayAssignment],
        knownAssetIDs: Set<WallpaperAsset.ID>
    ) -> [DisplayAssignment] {
        let validated = assignments.map { assignment in
            guard let assetID = assignment.assetID, !knownAssetIDs.contains(assetID) else {
                return assignment
            }
            return DisplayAssignment(
                displayUUID: assignment.displayUUID,
                assetID: nil,
                displayMode: assignment.displayMode,
                quality: assignment.quality,
                audioSource: .muted
            )
        }
        return validated.reduce(into: [String: DisplayAssignment]()) {
            $0[$1.displayUUID] = $1
        }.values.sorted { $0.displayUUID < $1.displayUUID }
    }

    private func repairLegacyPreviewEntrypoint(_ asset: WallpaperAsset) -> WallpaperAsset {
        guard asset.kind == .image,
              asset.supportStatus == .playable,
              let entrypoint = asset.entrypoint,
              isImplicitPreview(URL(filePath: entrypoint)),
              let scanned = try? WallpaperScanner()
                .scanForLibraryMigration(root: URL(filePath: asset.projectDirectory))
                .assets
                .first,
              scanned.entrypoint != nil,
              scanned.entrypoint != asset.entrypoint else {
            return asset
        }
        return WallpaperAsset(
            id: asset.id,
            title: asset.title,
            kind: scanned.kind,
            supportStatus: scanned.supportStatus,
            source: asset.source,
            projectDirectory: asset.projectDirectory,
            entrypoint: scanned.entrypoint,
            thumbnail: scanned.thumbnail ?? asset.thumbnail,
            workshopId: asset.workshopId,
            dateAdded: asset.dateAdded ?? scanned.dateAdded,
            contentHash: asset.contentHash,
            compatibility: scanned.compatibility ?? asset.compatibility,
            compatibilityReport: scanned.compatibilityReport ?? asset.compatibilityReport,
            allowsNetworkAccess: asset.allowsNetworkAccess,
            redistributionAllowed: false,
            issues: mergedIssues(asset.issues + scanned.issues)
        )
    }

    /// Performs the full Scene package/texture compatibility probe without
    /// writing the manifest. This method is intentionally synchronous so CLI
    /// callers can use it directly; the macOS app always invokes it from a
    /// detached task and persists the result on the main actor afterward.
    public func probeSceneCompatibility(
        for asset: WallpaperAsset,
        nativePlayable suppliedNativePlayable: Bool? = nil
    ) -> WallpaperAsset {
        guard asset.kind == .scene else {
            return asset
        }
        guard let entrypoint = asset.entrypoint else {
            let report = CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                warnings: ["The Scene package entrypoint is missing."],
                diagnosticCode: "scene_package_missing"
            )
            return WallpaperAsset(
                id: asset.id,
                title: asset.title,
                kind: asset.kind,
                supportStatus: .unsupported,
                source: asset.source,
                projectDirectory: asset.projectDirectory,
                entrypoint: asset.entrypoint,
                thumbnail: asset.thumbnail,
                workshopId: asset.workshopId,
                dateAdded: asset.dateAdded,
                contentHash: asset.contentHash,
                compatibility: report.supportMode,
                compatibilityReport: report,
                allowsNetworkAccess: asset.allowsNetworkAccess,
                redistributionAllowed: asset.redistributionAllowed,
                issues: mergedIssues(asset.issues + [
                    ScanIssue(
                        code: "scene_package_missing",
                        message: "scene.pkg metadata was detected but the package file was not found."
                    )
                ])
            )
        }
        let entrypointURL = URL(filePath: entrypoint)
        let projectRootURL = URL(filePath: asset.projectDirectory)
        guard ScenePackageReader().hasPackageHeader(url: entrypointURL) else {
            let report = WallpaperCompatibilityAnalyzer().analyze(
                kind: .scene,
                status: .unsupported,
                entrypoint: entrypointURL,
                projectRoot: projectRootURL
            )
            let preserved = asset.issues.filter { issue in
                issue.code != "scene_package_detected"
                    && issue.code != "scene_renderer_limited"
                    && issue.code != "scene_package_unreadable"
            }
            return WallpaperAsset(
                id: asset.id,
                title: asset.title,
                kind: asset.kind,
                supportStatus: .unsupported,
                source: asset.source,
                projectDirectory: asset.projectDirectory,
                entrypoint: asset.entrypoint,
                thumbnail: asset.thumbnail,
                workshopId: asset.workshopId,
                dateAdded: asset.dateAdded,
                contentHash: asset.contentHash,
                compatibility: report.supportMode,
                compatibilityReport: report,
                allowsNetworkAccess: asset.allowsNetworkAccess,
                redistributionAllowed: asset.redistributionAllowed,
                issues: mergedIssues(preserved + [
                    ScanIssue(
                        code: "scene_package_unreadable",
                        message: "The declared Scene entrypoint does not contain a readable PKGV package."
                    )
                ])
            )
        }
        let refreshed = currentSceneIssues(
            entrypoint: entrypointURL,
            projectRoot: projectRootURL
        )
        guard !refreshed.isEmpty else {
            return asset
        }
        let hasRenderCache = SceneRenderCache.existingVideoURL(
            in: URL(filePath: asset.projectDirectory)
        ) != nil
        let supportStatus: SupportStatus = (try? ScenePackageAnalyzer().analyze(
            url: entrypointURL,
            projectRoot: projectRootURL
        )) != nil
            ? .playable
            : .unsupported
        let analyzer = WallpaperCompatibilityAnalyzer()
        let analyzed = suppliedNativePlayable.map {
            analyzer.analyzeScene(
                entrypoint: entrypointURL,
                nativePlayable: $0,
                projectRoot: projectRootURL
            )
        } ?? analyzer.analyze(
            kind: .scene,
            status: supportStatus,
            entrypoint: entrypointURL,
            projectRoot: projectRootURL
        )
        let preserved = asset.issues.filter { issue in
            issue.code != "scene_package_detected"
                && issue.code != "scene_renderer_limited"
                && issue.code != "scene_package_unreadable"
                && issue.code != SceneRenderCache.issueCode
        }
        let cacheIssues = hasRenderCache
            ? [
                ScanIssue(
                    code: SceneRenderCache.issueCode,
                    message: "A local rendered scene video cache is attached for reference only; desktop scene playback uses the native renderer."
                )
            ]
            : []
        return WallpaperAsset(
            id: asset.id,
            title: asset.title,
            kind: asset.kind,
            supportStatus: supportStatus,
            source: asset.source,
            projectDirectory: asset.projectDirectory,
            entrypoint: asset.entrypoint,
            thumbnail: asset.thumbnail,
            workshopId: asset.workshopId,
            dateAdded: asset.dateAdded,
            contentHash: asset.contentHash,
            compatibility: hasRenderCache
                ? .cached(reason: "A rendered Scene video cache is installed.")
                : analyzed.supportMode,
            compatibilityReport: hasRenderCache
                ? CompatibilityReport(
                    level: analyzed.level == .unsupported ? .full : analyzed.level,
                    playbackPath: .renderedSceneCache,
                    requiredCapabilities: analyzed.requiredCapabilities,
                    missingCapabilities: analyzed.missingCapabilities,
                    warnings: analyzed.warnings + ["A rendered Scene video cache is installed."],
                    diagnosticCode: analyzed.level == .unsupported ? nil : analyzed.diagnosticCode
                )
                : analyzed,
            allowsNetworkAccess: asset.allowsNetworkAccess,
            redistributionAllowed: hasRenderCache ? false : asset.redistributionAllowed,
            issues: mergedIssues(preserved + refreshed + cacheIssues)
        )
    }

    private func refreshCompatibilityReport(_ asset: WallpaperAsset) -> WallpaperAsset {
        guard asset.compatibilityReport == nil
                || asset.compatibilityReport?.probeVersion != CompatibilityReport.currentProbeVersion
                || asset.compatibilityReport?.needsProbe == true else {
            return asset
        }
        if asset.kind == .scene {
            let report = CompatibilityReport.pendingSceneProbe(
                preserving: asset.compatibilityReport
            )
            return WallpaperAsset(
                id: asset.id,
                title: asset.title,
                kind: asset.kind,
                supportStatus: asset.supportStatus,
                source: asset.source,
                projectDirectory: asset.projectDirectory,
                entrypoint: asset.entrypoint,
                thumbnail: asset.thumbnail,
                workshopId: asset.workshopId,
                dateAdded: asset.dateAdded,
                contentHash: asset.contentHash,
                compatibility: report.supportMode,
                compatibilityReport: report,
                allowsNetworkAccess: asset.allowsNetworkAccess,
                redistributionAllowed: asset.redistributionAllowed,
                issues: asset.issues
            )
        }
        if asset.kind == .web {
            return asset.allowingNetworkAccess(asset.allowsNetworkAccess == true)
        }
        let entrypoint = asset.entrypoint.map { URL(filePath: $0) }
        let report: CompatibilityReport
        if asset.kind == .video,
           asset.supportStatus == .playable,
           let previous = asset.compatibilityReport,
           previous.playbackPath == .convertedVideo {
            // The converted cache is already the authoritative entrypoint.
            // Reclassifying only from `.playable` would incorrectly turn an
            // existing Cached asset into Direct/Live during a probe upgrade.
            report = CompatibilityReport(
                level: previous.level,
                playbackPath: .convertedVideo,
                requiredCapabilities: previous.requiredCapabilities,
                missingCapabilities: previous.missingCapabilities,
                warnings: previous.warnings,
                diagnosticCode: previous.diagnosticCode
            )
        } else {
            report = WallpaperCompatibilityAnalyzer().analyze(
                kind: asset.kind,
                status: asset.supportStatus,
                entrypoint: entrypoint,
                projectRoot: URL(filePath: asset.projectDirectory)
            )
        }
        return WallpaperAsset(
            id: asset.id,
            title: asset.title,
            kind: asset.kind,
            supportStatus: asset.supportStatus,
            source: asset.source,
            projectDirectory: asset.projectDirectory,
            entrypoint: asset.entrypoint,
            thumbnail: asset.thumbnail,
            workshopId: asset.workshopId,
            dateAdded: asset.dateAdded,
            contentHash: asset.contentHash,
            compatibility: report.supportMode,
            compatibilityReport: report,
            allowsNetworkAccess: asset.allowsNetworkAccess,
            redistributionAllowed: asset.redistributionAllowed,
            issues: asset.issues
        )
    }

    private func currentSceneIssues(entrypoint: URL, projectRoot: URL) -> [ScanIssue] {
        do {
            let analysis = try ScenePackageAnalyzer().analyze(
                url: entrypoint,
                projectRoot: projectRoot
            )
            return [
                ScanIssue(code: "scene_package_detected", message: analysis.userFacingSummary),
                ScanIssue(
                    code: "scene_renderer_limited",
                    message: "Scene playback supports 2D image layers, animated sprite textures, text layers, "
                        + "selected text SceneScript, "
                        + "keyframed motion, and selected effect motion; advanced shaders, particles, advanced scripts, audio, "
                        + "and video textures may differ."
                )
            ]
        } catch {
            return [
                ScanIssue(
                    code: "scene_package_unreadable",
                    message: "scene.pkg could not be inspected: \(error.localizedDescription)"
                )
            ]
        }
    }
}

/// All `LibraryStore` values targeting the same root share this recursive
/// lock. This makes manifest read-modify-write transactions atomic across the
/// app's importer, compatibility probes, display updates, and UI actions.
private final class LibraryStoreAccessLock: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private final class WeakLibraryStoreAccessLock: @unchecked Sendable {
    weak var value: LibraryStoreAccessLock?

    init(_ value: LibraryStoreAccessLock) {
        self.value = value
    }
}

private enum LibraryStoreAccessLockRegistry {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var locks: [String: WeakLibraryStoreAccessLock] = [:]

    static func lock(for root: URL) -> LibraryStoreAccessLock {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[key]?.value {
            return existing
        }
        let created = LibraryStoreAccessLock()
        locks[key] = WeakLibraryStoreAccessLock(created)
        return created
    }
}

public enum LibraryStoreError: Error, LocalizedError, Equatable {
    case notRegularFile(String)
    case unsupportedVideoExtension(String)
    case unsupportedMedia(String)
    case missingAsset(String)
    case assetIsNotScene(String)
    case assetChangedDuringOperation(String)
    case assetOutsideLibrary(String)
    case unsafeSceneRenderCacheDirectory(String)
    case missingVideoConversionSource(String)

    public var errorDescription: String? {
        switch self {
        case .notRegularFile(let path):
            return "\(path) is not a regular wallpaper file."
        case .unsupportedVideoExtension(let ext):
            return ext.isEmpty
                ? "This file has no supported video extension."
                : ".\(ext) is not supported for manual video import."
        case .unsupportedMedia(let name):
            return "\(name) is not a supported video, image, GIF, APNG, WebP, or Wallpaper Engine Scene package."
        case .missingAsset(let id):
            return "No library asset exists for id \(id)."
        case .assetIsNotScene(let id):
            return "Asset \(id) is not a scene wallpaper."
        case .assetChangedDuringOperation(let id):
            return "Asset \(id) changed while the operation was being prepared. Retry the operation."
        case .assetOutsideLibrary(let id):
            return "Asset \(id) is outside the managed library."
        case .unsafeSceneRenderCacheDirectory(let id):
            return "Scene render cache directory for asset \(id) is unsafe."
        case .missingVideoConversionSource(let id):
            return "The original copied video for \(id) could not be resolved safely. Re-import the source wallpaper."
        }
    }
}

private func storageDirectoryName(for id: String) -> String {
    let encoded = Data(id.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "id-\(encoded)"
}

/// macOS exposes `/var`, `/tmp`, and `/etc` as fixed aliases into `/private`.
/// Permit only those platform aliases. Any other `realpath` change means a
/// user-controlled component redirected the managed cache/library elsewhere.
private func isAllowedCanonicalPath(original: String, resolved: String) -> Bool {
    if original == resolved { return true }
    for alias in ["/var", "/tmp", "/etc"]
    where original == alias || original.hasPrefix(alias + "/") {
        if resolved == "/private" + original {
            return true
        }
    }
    return false
}

private let implicitPreviewNames = ["preview", "thumbnail", "thumb", "cover"]

private func isRegularFile(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
        return false
    }
    return values.isRegularFile == true && values.isSymbolicLink != true
}

private func isImplicitPreview(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    let name = url.deletingPathExtension().lastPathComponent.lowercased()
    return ["jpg", "jpeg", "png", "gif", "heic"].contains(ext) && implicitPreviewNames.contains(name)
}

private func mergedIssues(_ issues: [ScanIssue]) -> [ScanIssue] {
    var seen: Set<String> = []
    return issues.filter { issue in
        let key = "\(issue.code)\u{0}\(issue.message)"
        guard !seen.contains(key) else {
            return false
        }
        seen.insert(key)
        return true
    }
}

private extension JSONEncoder {
    static var bridge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var bridge: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
