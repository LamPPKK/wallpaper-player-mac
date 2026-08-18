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

public struct LibraryStore: Sendable {
    public let root: URL
    private let trasher: AssetTrashing
    private let accessLock: LibraryStoreAccessLock
    private let manifestWriter: any LibraryManifestWriting
    private let standaloneFileCopier: any StandaloneFileCopying

    public init(root: URL, trasher: AssetTrashing = FileManagerAssetTrasher()) {
        self.init(
            root: root,
            trasher: trasher,
            manifestWriter: AtomicLibraryManifestWriter(),
            standaloneFileCopier: FileManagerStandaloneFileCopier()
        )
    }

    init(
        root: URL,
        trasher: AssetTrashing,
        manifestWriter: any LibraryManifestWriting,
        standaloneFileCopier: any StandaloneFileCopying = FileManagerStandaloneFileCopier()
    ) {
        self.root = root
        self.trasher = trasher
        self.manifestWriter = manifestWriter
        self.standaloneFileCopier = standaloneFileCopier
        accessLock = LibraryStoreAccessLockRegistry.lock(for: root)
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
        try FileManager.default.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        let directoryName = storageDirectoryName(for: asset.id)
        let target = assetsRoot.appending(path: directoryName)
        let replacement = assetsRoot.appending(path: ".\(directoryName).incoming-\(UUID().uuidString)")
        let backup = assetsRoot.appending(path: ".\(directoryName).previous-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: URL(filePath: asset.projectDirectory), to: replacement)
        } catch {
            try? FileManager.default.removeItem(at: replacement)
            throw error
        }
        let imported = rewrite(asset: asset, source: URL(filePath: asset.projectDirectory), target: target)
        let retiredDirectory: URL?
        var failedDirectory: URL?
        do {
            retiredDirectory = try accessLock.withLock {
                var manifest = try load()
                let retired = try replaceDirectory(target: target, replacement: replacement, backup: backup)
                manifest = LibraryManifest(
                    generatedAt: Date(),
                    assets: (manifest.assets.filter { $0.id != asset.id } + [imported])
                        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
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
        if let retiredDirectory {
            try? FileManager.default.removeItem(at: retiredDirectory)
        }
        return imported
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
        let imported = WallpaperAsset(
            id: id,
            title: source.deletingPathExtension().lastPathComponent,
            kind: classification.kind,
            supportStatus: classification.supportStatus,
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
            manifest = LibraryManifest(
                generatedAt: Date(),
                assets: (manifest.assets.filter { $0.id != asset.id } + [asset])
                    .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
                displayAssignments: manifest.displayAssignments
            )
            try save(manifest)
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
            manifest = LibraryManifest(
                generatedAt: Date(),
                assets: (manifest.assets.filter { $0.id != asset.id } + [asset])
                    .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
                displayAssignments: manifest.displayAssignments
            )
            try save(manifest)
            return true
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
                        compatibility: .cached(reason: "A rendered Scene video cache is installed."),
                        compatibilityReport: CompatibilityReport(
                            level: analyzed?.level ?? .full,
                            playbackPath: .renderedSceneCache,
                            requiredCapabilities: analyzed?.requiredCapabilities ?? [],
                            missingCapabilities: analyzed?.missingCapabilities ?? [],
                            warnings: ["A rendered Scene video cache is installed."],
                            diagnosticCode: analyzed?.diagnosticCode
                        ),
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

    private func rewrite(path: String?, source: URL, target: URL) -> String? {
        guard let path else {
            return nil
        }
        let prefix = source.path.hasSuffix("/") ? source.path : "\(source.path)/"
        guard path.hasPrefix(prefix) else {
            return path
        }
        let relative = String(path.dropFirst(prefix.count))
        return target.appending(path: relative).path
    }

    private func repairStoredAssets(in manifest: LibraryManifest) -> LibraryManifest {
        let assets = manifest.assets
            .map(repairLegacyPreviewEntrypoint)
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
        let refreshed = currentSceneIssues(entrypoint: entrypointURL)
        guard !refreshed.isEmpty else {
            return asset
        }
        let hasRenderCache = SceneRenderCache.existingVideoURL(
            in: URL(filePath: asset.projectDirectory)
        ) != nil
        let supportStatus: SupportStatus = (try? ScenePackageAnalyzer().analyze(url: entrypointURL)) != nil
            ? .playable
            : .unsupported
        let analyzer = WallpaperCompatibilityAnalyzer()
        let analyzed = suppliedNativePlayable.map {
            analyzer.analyzeScene(entrypoint: entrypointURL, nativePlayable: $0)
        } ?? analyzer.analyze(kind: .scene, status: supportStatus, entrypoint: entrypointURL)
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
                    level: analyzed.level,
                    playbackPath: .renderedSceneCache,
                    requiredCapabilities: analyzed.requiredCapabilities,
                    missingCapabilities: analyzed.missingCapabilities,
                    warnings: ["A rendered Scene video cache is installed."],
                    diagnosticCode: analyzed.diagnosticCode
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
        let entrypoint = asset.entrypoint.map { URL(filePath: $0) }
        let report = WallpaperCompatibilityAnalyzer().analyze(
            kind: asset.kind,
            status: asset.supportStatus,
            entrypoint: entrypoint
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

    private func currentSceneIssues(entrypoint: URL) -> [ScanIssue] {
        do {
            let analysis = try ScenePackageAnalyzer().analyze(url: entrypoint)
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
