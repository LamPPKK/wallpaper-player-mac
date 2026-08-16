import AppKit
import Foundation
import UniformTypeIdentifiers
import BackgroundEngineCore

struct UpdateAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Drives the "Remove" confirmation dialog: holds the assets awaiting the
/// user's confirmation before `AppViewModel.removeSelectedLibraryAssets()`
/// actually moves their library folders to the Trash.
struct PendingLibraryRemoval: Identifiable {
    let id = UUID()
    let assetIds: Set<WallpaperAsset.ID>
    let title: String
}

struct ImportProgress: Equatable {
    let completed: Int
    let total: Int
    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

enum ScannedAssetSortOrder: String, CaseIterable, Identifiable {
    case dateAdded
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dateAdded:
            "Date Added"
        case .name:
            "Name"
        }
    }
}

@MainActor
protocol WallpaperPlaying: AnyObject {
    func play(
        asset: WallpaperAsset,
        autoPauseWhenCovered: Bool,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool?,
        audioVolume: Double?
    ) throws
    func stop()
    func setDisplayMode(_ mode: WallpaperDisplayMode)
    func setAutoPauseWhenCovered(_ enabled: Bool)
}

extension WallpaperPlayer: WallpaperPlaying {}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var sourcePath = ""
    @Published var workshopInput = ""
    @Published var pendingSteamCMDConfirmation = false
    @Published private(set) var workshopDownloadStatus = WorkshopDownloadStatus(
        itemID: nil,
        phase: .idle,
        progress: nil,
        message: "Paste a Workshop URL or numeric item ID."
    )
    @Published var scannedAssets: [WallpaperAsset] = []
    @Published var libraryAssets: [WallpaperAsset] = []
    @Published private(set) var connectedDisplays: [ConnectedDisplay] = []
    @Published private(set) var displayAssignments: [DisplayAssignment] = []
    @Published var selectedDisplayUUID: String?
    @Published private(set) var legacyMigrationCandidates: [LegacyMigrationCandidate] = []
    @Published var pendingLegacyMigrationConfirmation = false
    @Published var pendingWebNetworkAssetID: WallpaperAsset.ID?
    @Published private(set) var selectedScannedAssetIds: Set<WallpaperAsset.ID> = []
    @Published private(set) var selectedLibraryAssetIds: Set<WallpaperAsset.ID> = []
    @Published var status = "Choose a copied Wallpaper Engine Workshop folder to begin."
    @Published var isWorking = false
    @Published private(set) var sceneAssetsDirectory = ""
    /// Bumped whenever a scene's background video render completes. Library
    /// rows read this alongside the asset itself so their body actually
    /// re-evaluates: SwiftUI skips re-invoking a child view's body when its
    /// input properties are structurally unchanged, even if the enclosing
    /// `@ObservedObject` published an unrelated change (e.g. `status`), so
    /// without this the "renders on first play" badge never flips to
    /// "playable" until something else forces the asset itself to change.
    @Published private(set) var sceneVideoRenderRevision = 0
    @Published var pendingLibraryRemoval: PendingLibraryRemoval?
    @Published private(set) var importProgress: ImportProgress?
    @Published var displayMode: WallpaperDisplayMode = .fit {
        didSet {
            wallpaperPlayer.setDisplayMode(displayMode)
            userDefaults.set(displayMode.rawValue, forKey: PreferenceKey.displayMode)
            if lockScreenAnimationEnabled, let asset = selectedLibraryAsset {
                _ = refreshLockScreenAnimationConfiguration(asset: asset)
            }
        }
    }
    @Published var autoPauseWhenCovered = true {
        didSet {
            wallpaperPlayer.setAutoPauseWhenCovered(autoPauseWhenCovered)
            userDefaults.set(autoPauseWhenCovered, forKey: PreferenceKey.autoPauseWhenCovered)
        }
    }
    /// Off by default: the previous behavior was silent playback, so audio
    /// should never turn on for existing users without them opting in.
    @Published var wallpaperAudioEnabled = false {
        didSet {
            WallpaperPlayer.shared.setAudioSettings(enabled: wallpaperAudioEnabled, volume: wallpaperAudioVolume)
            userDefaults.set(wallpaperAudioEnabled, forKey: PreferenceKey.wallpaperAudioEnabled)
        }
    }
    @Published var wallpaperAudioVolume = 0.5 {
        didSet {
            WallpaperPlayer.shared.setAudioSettings(enabled: wallpaperAudioEnabled, volume: wallpaperAudioVolume)
            userDefaults.set(wallpaperAudioVolume, forKey: PreferenceKey.wallpaperAudioVolume)
        }
    }
    @Published private(set) var isPlaybackPaused = false
    @Published var lockScreenAnimationEnabled = false {
        didSet {
            guard !isSyncingLockScreenAnimation, lockScreenAnimationEnabled != oldValue else {
                return
            }
            setLockScreenAnimation(lockScreenAnimationEnabled)
        }
    }
    @Published var automaticallyCheckForUpdates = true {
        didSet {
            guard automaticallyCheckForUpdates != oldValue else {
                return
            }
            userDefaults.set(automaticallyCheckForUpdates, forKey: PreferenceKey.automaticallyCheckForUpdates)
            if automaticallyCheckForUpdates {
                scheduleAutomaticUpdateCheck(force: true)
            }
        }
    }
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var availableUpdate: UpdateRelease?
    @Published var updateAlert: UpdateAlert?
    @Published var launchAtLogin = false {
        didSet {
            guard !isSyncingLaunchAtLogin, launchAtLogin != oldValue else {
                return
            }
            setLaunchAtLogin(launchAtLogin)
        }
    }
    @Published var rotationEnabled = false {
        didSet {
            guard !isSyncingRotation, rotationEnabled != oldValue else {
                return
            }
            if rotationEnabled {
                startRotation()
            } else {
                stopRotationTimer()
                userDefaults.set(false, forKey: PreferenceKey.rotationEnabled)
                status = "Rotation stopped."
            }
        }
    }
    @Published var rotationShuffle = false {
        didSet {
            guard rotationShuffle != oldValue else {
                return
            }
            userDefaults.set(rotationShuffle, forKey: PreferenceKey.rotationShuffle)
            if rotationEnabled {
                buildRotationQueue()
            }
        }
    }
    @Published var rotationInterval: TimeInterval = 300 {
        didSet {
            guard rotationInterval != oldValue else {
                return
            }
            userDefaults.set(rotationInterval, forKey: PreferenceKey.rotationInterval)
            if rotationEnabled {
                restartRotationTimer()
            }
        }
    }
    @Published var scannedSortOrder: ScannedAssetSortOrder = .dateAdded {
        didSet {
            guard scannedSortOrder != oldValue else {
                return
            }
            userDefaults.set(scannedSortOrder.rawValue, forKey: PreferenceKey.scannedSortOrder)
            sortScannedAssets()
        }
    }

    private let scanner = WallpaperScanner()
    private let converter = VideoConverter()
    private let systemWallpaperSetter = SystemWallpaperSetter()
    private let store: LibraryStore
    private let loginItemController: LoginItemManaging
    private let lockScreenAnimationController: LockScreenAnimationManaging
    private let userDefaults: UserDefaults
    private let updateChecker: UpdateChecking
    private let updateURLOpener: UpdateURLOpening
    private let wallpaperPlayer: WallpaperPlaying
    private let currentVersionProvider: () -> String
    private var isSyncingLaunchAtLogin = false
    private var isSyncingLockScreenAnimation = false
    private var isSyncingRotation = false
    private var rotationTimer: Timer?
    private var workshopDownloadTask: Task<Void, Never>?
    private var sceneAssetsAccessURL: URL?
    private var rotationQueue: [WallpaperAsset.ID] = []
    private var rotationIndex = 0

    init() {
        userDefaults = .standard
        loginItemController = LoginItemController()
        lockScreenAnimationController = LockScreenAnimationController()
        updateChecker = GitHubReleaseUpdateChecker()
        updateURLOpener = WorkspaceUpdateURLOpener()
        wallpaperPlayer = WallpaperPlayer.shared
        currentVersionProvider = { AppVersionProvider.currentVersion() }
        do {
            store = try LibraryStore.defaultStore()
            restorePreferences()
            loadLibrary()
            playLastWallpaperIfAvailable()
            restoreLockScreenAnimationIfNeeded()
            restoreRotationIfNeeded()
        } catch {
            store = LibraryStore(
                root: FileManager.default.temporaryDirectory.appending(path: "Background Engine")
            )
            status = error.localizedDescription
        }
        syncLaunchAtLoginStatus()
        scheduleAutomaticUpdateCheck()
        SceneWallpaperContentFactory.statusHandler = { [weak self] message in
            self?.status = message
        }
        SceneWallpaperContentFactory.sceneVideoRenderCompletionHandler = { [weak self] assetId in
            self?.handleSceneVideoRenderCompletion(assetId: assetId)
        }
        if !userDefaults.bool(forKey: PreferenceKey.legacyMigrationCompleted) {
            Task { await refreshLegacyMigrationPreview() }
        }
    }

    init(
        store: LibraryStore,
        loginItemController: LoginItemManaging = LoginItemController(),
        lockScreenAnimationController: LockScreenAnimationManaging = LockScreenAnimationController(),
        updateChecker: UpdateChecking = DisabledUpdateChecker(),
        updateURLOpener: UpdateURLOpening = WorkspaceUpdateURLOpener(),
        wallpaperPlayer: WallpaperPlaying = WallpaperPlayer.shared,
        currentVersionProvider: @escaping () -> String = { "0.0.0" },
        userDefaults: UserDefaults = .standard
    ) {
        self.store = store
        self.loginItemController = loginItemController
        self.lockScreenAnimationController = lockScreenAnimationController
        self.updateChecker = updateChecker
        self.updateURLOpener = updateURLOpener
        self.wallpaperPlayer = wallpaperPlayer
        self.currentVersionProvider = currentVersionProvider
        self.userDefaults = userDefaults
        restorePreferences()
        loadLibrary()
        playLastWallpaperIfAvailable()
        restoreLockScreenAnimationIfNeeded()
        restoreRotationIfNeeded()
        syncLaunchAtLoginStatus()
    }

    var selectedScannedAsset: WallpaperAsset? {
        selectedScannedAssets.first
    }

    var selectedScannedAssetId: WallpaperAsset.ID? {
        get {
            selectedScannedAsset?.id
        }
        set {
            selectedScannedAssetIds = newValue.map { Set([$0]) } ?? []
        }
    }

    var selectedScannedAssetCount: Int {
        selectedScannedAssets.count
    }

    var selectedScannedAssets: [WallpaperAsset] {
        scannedAssets.filter { selectedScannedAssetIds.contains($0.id) }
    }

    var selectedLibraryAsset: WallpaperAsset? {
        libraryAssets.first { selectedLibraryAssetIds.contains($0.id) }
    }

    var selectedLibraryAssetId: WallpaperAsset.ID? {
        get {
            selectedLibraryAsset?.id
        }
        set {
            selectedLibraryAssetIds = newValue.map { Set([$0]) } ?? []
        }
    }

    var selectedLibraryAssetCount: Int {
        selectedLibraryAssets.count
    }

    var selectedLibraryAssets: [WallpaperAsset] {
        libraryAssets.filter { selectedLibraryAssetIds.contains($0.id) }
    }

    var sceneAssetsStatus: String {
        if let envPath = ProcessInfo.processInfo.environment[SceneEngineRendererConfiguration.assetsEnvironmentVariableName],
           !envPath.isEmpty {
            let envURL = URL(filePath: envPath).standardizedFileURL
            return SceneEngineRendererConfiguration.isValidAssetsDirectory(envURL)
                ? "Using BACKGROUND_ENGINE_SCENE_ASSETS_DIR: \(envURL.path)"
                : "BACKGROUND_ENGINE_SCENE_ASSETS_DIR is set, but the assets folder is missing or incomplete."
        }
        guard !sceneAssetsDirectory.isEmpty else {
            return "Not set. The scene renderer will use the default app-support assets folder if it exists."
        }
        let url = URL(filePath: sceneAssetsDirectory).standardizedFileURL
        return SceneEngineRendererConfiguration.isValidAssetsDirectory(url)
            ? "Scene Engine assets ready: \(url.path)"
            : "Scene Engine assets folder is missing or incomplete: \(url.path)"
    }

    func selectLibraryAssets(_ ids: Set<WallpaperAsset.ID>) {
        selectedLibraryAssetIds = ids
        normalizeLibrarySelection(allowEmpty: true)
    }

    func selectScannedAssets(_ ids: Set<WallpaperAsset.ID>) {
        selectedScannedAssetIds = ids
        normalizeScannedSelection(allowEmpty: true)
    }

    func L(_ key: String) -> String {
        Localization.string(key)
    }
}

extension AppViewModel {
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
            scanSource()
        }
    }

    func chooseSceneAssetsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Wallpaper Engine assets folder contents."
        if panel.runModal() == .OK, let url = panel.url {
            setSceneAssetsFolder(url)
        }
    }

    func setSceneAssetsFolder(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        guard SceneEngineRendererConfiguration.isValidAssetsDirectory(standardizedURL) else {
            status = "This does not look like a Wallpaper Engine assets folder. It must contain materials/ "
                + "and shaders/. Copy the contents of steamapps/common/wallpaper_engine/assets, not the parent folder."
            return
        }
        do {
            try SecurityScopedBookmarkStore(defaults: userDefaults).save(
                standardizedURL,
                key: PreferenceKey.sceneEngineAssetsBookmark
            )
        } catch {
            status = "Could not save access to the Scene Engine assets folder: \(error.localizedDescription)"
            return
        }
        sceneAssetsAccessURL?.stopAccessingSecurityScopedResource()
        _ = standardizedURL.startAccessingSecurityScopedResource()
        sceneAssetsAccessURL = standardizedURL
        sceneAssetsDirectory = standardizedURL.path
        userDefaults.set(sceneAssetsDirectory, forKey: PreferenceKey.sceneEngineAssetsDirectory)
        SceneEngineRendererConfiguration.overrideAssetsPath = sceneAssetsDirectory
        status = "Scene Engine assets folder access saved. The original folder is never modified."
    }

    func clearSceneAssetsFolder() {
        sceneAssetsAccessURL?.stopAccessingSecurityScopedResource()
        sceneAssetsAccessURL = nil
        sceneAssetsDirectory = ""
        userDefaults.removeObject(forKey: PreferenceKey.sceneEngineAssetsDirectory)
        SecurityScopedBookmarkStore(defaults: userDefaults).remove(key: PreferenceKey.sceneEngineAssetsBookmark)
        SceneEngineRendererConfiguration.overrideAssetsPath = nil
        status = "Scene Engine assets folder reset to the default path."
    }

    func scanSource() {
        guard !sourcePath.isEmpty else {
            status = "Choose a folder first."
            return
        }
        do {
            let result = try scanner.scan(root: URL(filePath: sourcePath))
            scannedAssets = sortedScannedAssets(result.assets)
            selectedScannedAssetIds = scannedAssets.first.map { Set([$0.id]) } ?? []
            status = "Found \(result.assets.count) project(s)."
        } catch {
            status = error.localizedDescription
        }
    }

    func requestWorkshopDownload() {
        guard WorkshopItemID(input: workshopInput) != nil else {
            status = SteamCMDRunnerError.invalidItemID.localizedDescription
            return
        }
        pendingSteamCMDConfirmation = true
    }

    func confirmWorkshopDownload() {
        guard !isWorking else { return }
        pendingSteamCMDConfirmation = false
        let service = WorkshopDownloadService(store: store)
        let input = workshopInput
        let itemID = WorkshopItemID(input: input)?.rawValue
        isWorking = true
        workshopDownloadStatus = WorkshopDownloadStatus(
            itemID: itemID,
            phase: .installingSteamCMD,
            progress: nil,
            message: "Preparing Valve SteamCMD…"
        )
        workshopDownloadTask = Task {
            defer {
                isWorking = false
                workshopDownloadTask = nil
            }
            do {
                workshopDownloadStatus = WorkshopDownloadStatus(
                    itemID: itemID,
                    phase: .downloading,
                    progress: nil,
                    message: "Downloading anonymously through SteamCMD…"
                )
                let imported = try await service.downloadAndImport(input: input)
                loadLibrary()
                selectedLibraryAssetId = imported.id
                workshopDownloadStatus = WorkshopDownloadStatus(
                    itemID: imported.workshopId,
                    phase: .completed,
                    progress: 1,
                    message: "Imported \(imported.title)."
                )
                status = "Downloaded and imported \(imported.title)."
            } catch is CancellationError {
                workshopDownloadStatus = WorkshopDownloadStatus(
                    itemID: itemID,
                    phase: .cancelled,
                    progress: nil,
                    message: "Download cancelled."
                )
                status = "Workshop download cancelled."
            } catch {
                workshopDownloadStatus = WorkshopDownloadStatus(
                    itemID: itemID,
                    phase: .failed,
                    progress: nil,
                    message: error.localizedDescription
                )
                status = error.localizedDescription
            }
        }
    }

    func cancelWorkshopDownload() {
        workshopDownloadTask?.cancel()
        workshopDownloadTask = nil
        Task {
            await WorkshopDownloadService(store: store).cancel()
        }
    }

    func refreshLegacyMigrationPreview() async {
        legacyMigrationCandidates = await LegacyLibraryMigrator(destination: store).preview()
    }

    func requestLegacyMigration() {
        guard !legacyMigrationCandidates.isEmpty else {
            status = "No compatible legacy wallpapers were found."
            return
        }
        pendingLegacyMigrationConfirmation = true
    }

    func confirmLegacyMigration() {
        pendingLegacyMigrationConfirmation = false
        let candidates = legacyMigrationCandidates
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let imported = try await LegacyLibraryMigrator(destination: store).migrate(candidates)
                migrateLegacyPreferences()
                userDefaults.set(true, forKey: PreferenceKey.legacyMigrationCompleted)
                legacyMigrationCandidates = []
                loadLibrary()
                status = "Imported \(imported.count) legacy wallpaper(s). Original data was not changed."
            } catch {
                status = "Legacy migration failed: \(error.localizedDescription)"
            }
        }
    }

    private func migrateLegacyPreferences() {
        let domains = [
            "com.haren724.open-wallpaper-engine",
            "dev.3xhaust.WorkshopWallpaperBridge"
        ]
        for domain in domains {
            guard let values = userDefaults.persistentDomain(forName: domain) else { continue }
            if userDefaults.object(forKey: PreferenceKey.autoPauseWhenCovered) == nil,
               let value = values[PreferenceKey.autoPauseWhenCovered] as? Bool {
                autoPauseWhenCovered = value
            }
            if userDefaults.object(forKey: PreferenceKey.wallpaperAudioEnabled) == nil,
               let value = values[PreferenceKey.wallpaperAudioEnabled] as? Bool {
                wallpaperAudioEnabled = value
            }
            if let rawMode = values[PreferenceKey.displayMode] as? String,
               let mode = WallpaperDisplayMode(rawValue: rawMode) {
                displayMode = mode
            }
        }
    }

    @discardableResult
    func importSelected() -> Task<Void, Never> {
        guard !isWorking else {
            status = "Finish the current library operation first."
            return Task {}
        }
        let assets = selectedScannedAssets
        guard !assets.isEmpty else {
            status = "Select a scanned project first."
            return Task {}
        }
        // Copy files off the main thread so the UI stays responsive, and report
        // per-item progress so a large multi-import never looks frozen.
        isWorking = true
        importProgress = ImportProgress(completed: 0, total: assets.count)
        status = "Importing 0/\(assets.count)..."
        let importer = WallpaperImporter(store: store)
        return Task {
            defer {
                importProgress = nil
                isWorking = false
            }
            var importedAssets: [WallpaperAsset] = []
            do {
                for asset in assets {
                    let imported = try await importer.importAsset(asset)
                    importedAssets.append(imported)
                    importProgress = ImportProgress(completed: importedAssets.count, total: assets.count)
                    status = "Importing \(importedAssets.count)/\(assets.count)..."
                }
                userDefaults.set(Date(), forKey: PreferenceKey.lastImportAt)
                loadLibrary()
                selectLibraryAssets(Set(importedAssets.map(\.id)))
                if importedAssets.count == 1, let imported = importedAssets.first {
                    status = "Imported \(imported.title)."
                } else {
                    status = "Imported \(importedAssets.count) projects."
                }
            } catch {
                loadLibrary()
                if importedAssets.isEmpty {
                    status = error.localizedDescription
                } else {
                    status = "Imported \(importedAssets.count) project(s), then failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func chooseVideoFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.videoContentTypes
        panel.message = "Choose a local video file to add to your wallpaper library."
        if panel.runModal() == .OK, let url = panel.url {
            importVideoFile(url)
        }
    }

    @discardableResult
    func importVideoFile(_ url: URL) -> Task<Void, Never> {
        guard !isWorking else {
            status = "Finish the current library operation first."
            return Task {}
        }
        isWorking = true
        status = "Adding \(url.lastPathComponent)..."
        let importer = WallpaperImporter(store: store)
        return Task {
            defer {
                isWorking = false
            }
            do {
                let imported = try await importer.importVideoFile(url)
                loadLibrary()
                selectedLibraryAssetId = imported.id
                status = imported.supportStatus == .needsConversion
                    ? "Added \(imported.title). Convert it before playing."
                    : "Added \(imported.title)."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func playSelected() {
        guard let asset = selectedLibraryAsset else {
            status = "Select a library project first."
            return
        }
        if rotationEnabled {
            disableRotation()
        }
        do {
            try play(asset: asset, remember: true)
        } catch {
            status = error.localizedDescription
        }
    }

    func setStillWallpaper() {
        guard let asset = selectedLibraryAsset else {
            status = "Select a library project first."
            return
        }
        do {
            let result = try systemWallpaperSetter.setStillWallpaper(from: asset)
            if result.lockScreenCacheURL != nil {
                status = "Set desktop wallpaper and wrote Lock Screen still image from "
                    + "\(result.imageURL.lastPathComponent). Lock the Mac once to refresh the visible screen."
            } else {
                status = "Set desktop still wallpaper from \(result.imageURL.lastPathComponent), "
                    + "but Lock Screen failed: \(result.lockScreenErrorDescription ?? "unknown error")."
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func removeSelectedLibraryAsset() {
        removeSelectedLibraryAssets()
    }

    /// Prepares the confirmation dialog state for the currently selected
    /// library asset(s). The view presents `.confirmationDialog` bound to
    /// `pendingLibraryRemoval`; only its destructive action actually calls
    /// `removeSelectedLibraryAssets()`.
    func requestRemoveSelectedLibraryAssets() {
        let assets = selectedLibraryAssets
        guard !assets.isEmpty else {
            status = "Select a library project first."
            return
        }
        let title = assets.count == 1
            ? assets[0].title
            : "\(assets.count) items"
        pendingLibraryRemoval = PendingLibraryRemoval(assetIds: Set(assets.map(\.id)), title: title)
    }

    func cancelPendingLibraryRemoval() {
        pendingLibraryRemoval = nil
    }

    func removeSelectedLibraryAssets() {
        guard !isWorking else {
            status = "Finish the current library operation first."
            return
        }
        let assets = selectedLibraryAssets
        pendingLibraryRemoval = nil
        guard !assets.isEmpty else {
            status = "Select a library project first."
            return
        }
        let wasRotating = rotationEnabled
        do {
            for asset in assets {
                try store.removeAsset(id: asset.id)
            }
            loadLibrary()
            if wasRotating, !rotationEnabled {
                if assets.count == 1, let asset = assets.first {
                    status = "Moved \(asset.title) to the Trash. Rotation stopped — no playable wallpapers left."
                } else {
                    status = "Moved \(assets.count) items to the Trash. Rotation stopped — no playable wallpapers left."
                }
            } else if assets.count == 1, let asset = assets.first {
                status = "Moved \(asset.title) to the Trash. The original copied folder was not touched."
            } else {
                status = "Moved \(assets.count) items to the Trash. The original copied folders were not touched."
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func convertSelected() {
        guard !isWorking else {
            status = "Finish the current library operation first."
            return
        }
        guard let asset = selectedLibraryAsset, let entrypoint = asset.entrypoint else {
            status = "Select a library video first."
            return
        }
        let output = URL(filePath: asset.projectDirectory).appending(path: "wwb-converted.mp4")
        isWorking = true
        status = "Converting \(asset.title)..."
        let converter = self.converter
        Task {
            do {
                try await Task.detached {
                    try converter.convertToPlayableVideo(input: URL(filePath: entrypoint), output: output)
                }.value
                let converted = convertedAsset(asset, output: output)
                try store.replaceAsset(converted)
                loadLibrary()
                selectedLibraryAssetId = converted.id
                status = "Converted \(asset.title)."
            } catch {
                status = error.localizedDescription
            }
            isWorking = false
        }
    }

    func stopPlayback() {
        if rotationEnabled {
            disableRotation()
        }
        wallpaperPlayer.stop()
        userDefaults.removeObject(forKey: PreferenceKey.lastPlayedAssetId)
        status = "Playback stopped."
        isPlaybackPaused = false
    }

    func togglePlaybackPause() {
        isPlaybackPaused.toggle()
        WallpaperPlayer.shared.setPlaybackPaused(isPlaybackPaused)
        status = isPlaybackPaused ? "Playback paused." : "Playback resumed."
    }

    func playNextLibraryWallpaper() {
        let playable = playableLibraryAssets
        guard !playable.isEmpty else {
            status = "Import a playable wallpaper first."
            return
        }
        let currentID = selectedLibraryAsset?.id
        let index = currentID.flatMap { id in playable.firstIndex(where: { $0.id == id }) } ?? -1
        let next = playable[(index + 1) % playable.count]
        selectedLibraryAssetId = next.id
        do {
            try play(asset: next, remember: true)
        } catch {
            status = error.localizedDescription
        }
    }

    func openLoginItemsSettings() {
        loginItemController.openSystemSettings()
    }

    func openScreenSaverSettings() {
        do {
            try lockScreenAnimationController.openScreenSaverSettings()
            status = "Installed and selected Background Engine Screen Saver."
        } catch {
            status = "Screen Saver settings could not be opened: \(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        Task {
            await checkForUpdatesNow(userInitiated: true)
        }
    }

    func checkForUpdatesNow(userInitiated: Bool = true) async {
        guard !isCheckingForUpdates else {
            return
        }
        isCheckingForUpdates = true
        defer {
            isCheckingForUpdates = false
        }
        if userInitiated {
            status = "Checking for updates..."
        }
        do {
            let result = try await updateChecker.checkForUpdates(currentVersion: currentVersionProvider())
            userDefaults.set(Date(), forKey: PreferenceKey.lastUpdateCheckAt)
            applyUpdateCheckResult(result, userInitiated: userInitiated)
        } catch {
            if userInitiated {
                let message = error.localizedDescription
                status = "Update check failed: \(message)"
                updateAlert = UpdateAlert(
                    title: "Update Check Failed",
                    message: message
                )
            }
        }
    }

    func performAutomaticUpdateCheckIfNeeded(force: Bool = false, now: Date = Date()) async {
        guard automaticallyCheckForUpdates else {
            return
        }
        if !force,
           let lastCheck = userDefaults.object(forKey: PreferenceKey.lastUpdateCheckAt) as? Date,
           now.timeIntervalSince(lastCheck) < Self.automaticUpdateCheckInterval {
            return
        }
        await checkForUpdatesNow(userInitiated: false)
    }

    func openAvailableUpdate() {
        guard let update = availableUpdate else {
            status = "No update is available."
            return
        }
        let url = update.downloadURL ?? update.releaseURL
        if updateURLOpener.open(url) {
            status = "Opened Background Engine \(update.version) update."
        } else {
            status = "Could not open the update download page."
        }
    }

    func loadLibrary() {
        do {
            let manifest = try store.load()
            libraryAssets = manifest.assets
            displayAssignments = manifest.displayAssignments
            refreshConnectedDisplays()
            normalizeLibrarySelection(allowEmpty: false)
            if rotationEnabled {
                if playableLibraryAssets.isEmpty {
                    // The last playable item was removed while rotating: shut
                    // rotation down cleanly instead of leaving a stale enabled
                    // flag that would resurrect on the next launch.
                    disableRotation(status: "Rotation stopped — no playable wallpapers left.")
                } else {
                    buildRotationQueue()
                }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func refreshConnectedDisplays() {
        connectedDisplays = ConnectedDisplay.current()
        selectedDisplayUUID = selectedDisplayUUID.flatMap { selected in
            connectedDisplays.contains(where: { $0.id == selected }) ? selected : nil
        } ?? connectedDisplays.first?.id
        var changed = false
        for display in connectedDisplays where !displayAssignments.contains(where: { $0.displayUUID == display.id }) {
            displayAssignments.append(DisplayAssignment(displayUUID: display.id, assetID: nil))
            changed = true
        }
        if changed {
            try? store.replaceDisplayAssignments(displayAssignments)
        }
    }

    func displayAssignment(for displayUUID: String) -> DisplayAssignment {
        displayAssignments.first(where: { $0.displayUUID == displayUUID })
            ?? DisplayAssignment(displayUUID: displayUUID, assetID: nil)
    }

    func updateDisplayAssignment(
        displayUUID: String,
        assetID: WallpaperAsset.ID? = nil,
        displayMode: WallpaperDisplayMode? = nil,
        quality: RenderQuality? = nil,
        audioSource: AudioSource? = nil,
        clearAsset: Bool = false
    ) {
        let current = displayAssignment(for: displayUUID)
        let isPrimary = connectedDisplays.first(where: { $0.id == displayUUID })?.isPrimary == true
        let updated = DisplayAssignment(
            displayUUID: displayUUID,
            assetID: clearAsset ? nil : (assetID ?? current.assetID),
            displayMode: displayMode ?? current.displayMode,
            quality: quality ?? current.quality,
            audioSource: isPrimary ? (audioSource ?? current.audioSource) : .muted
        )
        displayAssignments.removeAll { $0.displayUUID == displayUUID }
        displayAssignments.append(updated)
        displayAssignments.sort { $0.displayUUID < $1.displayUUID }
        do {
            try store.saveDisplayAssignment(updated)
            status = "Updated \(connectedDisplays.first(where: { $0.id == displayUUID })?.name ?? "display") assignment."
        } catch {
            status = error.localizedDescription
        }
    }

    func assignSelectedWallpaperToDisplay(_ displayUUID: String) {
        guard let asset = selectedLibraryAsset else {
            status = "Select a wallpaper first."
            return
        }
        updateDisplayAssignment(displayUUID: displayUUID, assetID: asset.id)
    }

    func requestWebNetworkAccessChange(for asset: WallpaperAsset) {
        guard asset.kind == .web else { return }
        if asset.allowsNetworkAccess == true {
            setWebNetworkAccess(assetID: asset.id, allowed: false)
        } else {
            pendingWebNetworkAssetID = asset.id
        }
    }

    func confirmWebNetworkAccess() {
        guard let assetID = pendingWebNetworkAssetID else { return }
        pendingWebNetworkAssetID = nil
        setWebNetworkAccess(assetID: assetID, allowed: true)
    }

    func cancelWebNetworkAccessChange() {
        pendingWebNetworkAssetID = nil
    }

    private func setWebNetworkAccess(assetID: WallpaperAsset.ID, allowed: Bool) {
        do {
            let updated = try store.setWebNetworkAccess(assetID: assetID, allowed: allowed)
            loadLibrary()
            selectedLibraryAssetId = updated.id
            status = allowed
                ? "External network access enabled for \(updated.title)."
                : "External network access blocked for \(updated.title)."
        } catch {
            status = error.localizedDescription
        }
    }

    func applyDisplayAssignments() {
        let failures = DisplaySessionCoordinator.shared.apply(
            assignments: displayAssignments,
            assets: libraryAssets,
            autoPauseWhenCovered: autoPauseWhenCovered,
            globalAudioEnabled: wallpaperAudioEnabled,
            globalAudioVolume: wallpaperAudioVolume
        )
        if failures.isEmpty {
            status = "Playing independent wallpaper sessions on assigned displays."
        } else {
            status = "Started other displays; \(failures.count) display(s) failed: "
                + failures.map(\.message).joined(separator: " · ")
        }
    }

    private func normalizeLibrarySelection(allowEmpty: Bool) {
        let validIds = Set(libraryAssets.map(\.id))
        selectedLibraryAssetIds = selectedLibraryAssetIds.intersection(validIds)
        if selectedLibraryAssetIds.isEmpty, !allowEmpty, let firstId = libraryAssets.first?.id {
            selectedLibraryAssetIds = [firstId]
        }
    }

    private func normalizeScannedSelection(allowEmpty: Bool) {
        let validIds = Set(scannedAssets.map(\.id))
        selectedScannedAssetIds = selectedScannedAssetIds.intersection(validIds)
        if selectedScannedAssetIds.isEmpty, !allowEmpty, let firstId = scannedAssets.first?.id {
            selectedScannedAssetIds = [firstId]
        }
    }

    private func syncLaunchAtLoginStatus() {
        isSyncingLaunchAtLogin = true
        launchAtLogin = loginItemController.isEnabled
        isSyncingLaunchAtLogin = false
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItemController.setEnabled(enabled)
            syncLaunchAtLoginStatus()
            status = enabled ? "Background Engine will open at login." : "Open at login is off."
        } catch {
            syncLaunchAtLoginStatus()
            status = "Open at login could not be changed: \(error.localizedDescription)"
        }
    }

    private func setLockScreenAnimation(_ enabled: Bool) {
        do {
            try lockScreenAnimationController.setEnabled(
                enabled,
                activeAsset: selectedLibraryAsset,
                displayMode: displayMode
            )
            userDefaults.set(enabled, forKey: PreferenceKey.lockScreenAnimationEnabled)
            status = enabled
                ? "Installed and selected Background Engine Screen Saver."
                : "Screen Saver animation is off."
        } catch {
            isSyncingLockScreenAnimation = true
            lockScreenAnimationEnabled = oldLockScreenAnimationPreference()
            isSyncingLockScreenAnimation = false
            status = "Screen Saver animation could not be changed: \(error.localizedDescription)"
        }
    }

    private func restorePreferences() {
        if let rawDisplayMode = userDefaults.string(forKey: PreferenceKey.displayMode),
           let storedDisplayMode = WallpaperDisplayMode(rawValue: rawDisplayMode) {
            displayMode = storedDisplayMode
        }
        if userDefaults.object(forKey: PreferenceKey.autoPauseWhenCovered) != nil {
            autoPauseWhenCovered = userDefaults.bool(forKey: PreferenceKey.autoPauseWhenCovered)
        }
        if userDefaults.object(forKey: PreferenceKey.wallpaperAudioEnabled) != nil {
            wallpaperAudioEnabled = userDefaults.bool(forKey: PreferenceKey.wallpaperAudioEnabled)
        }
        if userDefaults.object(forKey: PreferenceKey.wallpaperAudioVolume) != nil {
            wallpaperAudioVolume = userDefaults.double(forKey: PreferenceKey.wallpaperAudioVolume)
        }
        if userDefaults.object(forKey: PreferenceKey.lockScreenAnimationEnabled) != nil {
            isSyncingLockScreenAnimation = true
            lockScreenAnimationEnabled = userDefaults.bool(forKey: PreferenceKey.lockScreenAnimationEnabled)
            isSyncingLockScreenAnimation = false
        }
        if userDefaults.object(forKey: PreferenceKey.automaticallyCheckForUpdates) != nil {
            automaticallyCheckForUpdates = userDefaults.bool(forKey: PreferenceKey.automaticallyCheckForUpdates)
        }
        sceneAssetsDirectory = restoredSceneAssetsDirectory()
        SceneEngineRendererConfiguration.overrideAssetsPath = sceneAssetsDirectory.isEmpty ? nil : sceneAssetsDirectory
        if userDefaults.object(forKey: PreferenceKey.rotationShuffle) != nil {
            rotationShuffle = userDefaults.bool(forKey: PreferenceKey.rotationShuffle)
        }
        if let rawScannedSortOrder = userDefaults.string(forKey: PreferenceKey.scannedSortOrder),
           let storedScannedSortOrder = ScannedAssetSortOrder(rawValue: rawScannedSortOrder) {
            scannedSortOrder = storedScannedSortOrder
        }
        let storedRotationInterval = userDefaults.double(forKey: PreferenceKey.rotationInterval)
        if storedRotationInterval > 0 {
            rotationInterval = storedRotationInterval
        }
    }

    private func restoredSceneAssetsDirectory() -> String {
        if let bookmarkedURL = try? SecurityScopedBookmarkStore(defaults: userDefaults)
            .resolve(key: PreferenceKey.sceneEngineAssetsBookmark),
           SceneEngineRendererConfiguration.isValidAssetsDirectory(bookmarkedURL) {
            _ = bookmarkedURL.startAccessingSecurityScopedResource()
            sceneAssetsAccessURL = bookmarkedURL
            return bookmarkedURL.path
        }
        guard let storedPath = userDefaults.string(forKey: PreferenceKey.sceneEngineAssetsDirectory),
              !storedPath.isEmpty else {
            return ""
        }
        let storedURL = URL(filePath: storedPath).standardizedFileURL
        guard SceneEngineRendererConfiguration.isValidAssetsDirectory(storedURL) else {
            return storedPath
        }
        try? SecurityScopedBookmarkStore(defaults: userDefaults).save(
            storedURL,
            key: PreferenceKey.sceneEngineAssetsBookmark
        )
        _ = storedURL.startAccessingSecurityScopedResource()
        sceneAssetsAccessURL = storedURL
        return storedPath
    }

    private func sortScannedAssets() {
        scannedAssets = sortedScannedAssets(scannedAssets)
        normalizeScannedSelection(allowEmpty: true)
    }

    private func sortedScannedAssets(_ assets: [WallpaperAsset]) -> [WallpaperAsset] {
        switch scannedSortOrder {
        case .dateAdded:
            assets.sorted(by: dateAddedSort)
        case .name:
            assets.sorted { lhs, rhs in
                let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
        }
    }

    private func playLastWallpaperIfAvailable() {
        // If rotation was on, let restoreRotationIfNeeded() own the initial play
        // to avoid playing a wallpaper twice on launch (double play / flicker).
        guard !userDefaults.bool(forKey: PreferenceKey.rotationEnabled) else {
            return
        }
        if displayAssignments.contains(where: { assignment in
            guard let assetID = assignment.assetID else { return false }
            return libraryAssets.contains(where: { $0.id == assetID && $0.supportStatus == .playable })
        }) {
            applyDisplayAssignments()
            status = "Restored independent display sessions."
            return
        }
        guard let id = userDefaults.string(forKey: PreferenceKey.lastPlayedAssetId),
              let asset = libraryAssets.first(where: { $0.id == id }),
              asset.supportStatus == .playable else {
            return
        }
        selectedLibraryAssetId = id
        do {
            try play(asset: asset, remember: false)
            status = "Restored \(asset.title) on the desktop."
        } catch {
            userDefaults.removeObject(forKey: PreferenceKey.lastPlayedAssetId)
            status = "Could not restore \(asset.title): \(error.localizedDescription)"
        }
    }

    private func restoreLockScreenAnimationIfNeeded() {
        guard lockScreenAnimationEnabled else {
            return
        }
        do {
            try lockScreenAnimationController.setEnabled(
                true,
                activeAsset: selectedLibraryAsset,
                displayMode: displayMode
            )
        } catch {
            status = "Screen Saver animation could not be restored: \(error.localizedDescription)"
        }
    }

    private func play(asset: WallpaperAsset, remember: Bool) throws {
        try wallpaperPlayer.play(
            asset: asset,
            autoPauseWhenCovered: autoPauseWhenCovered,
            displayMode: displayMode,
            audioEnabled: wallpaperAudioEnabled,
            audioVolume: wallpaperAudioVolume
        )
        if remember {
            userDefaults.set(asset.id, forKey: PreferenceKey.lastPlayedAssetId)
        }
        let lockScreenError = refreshLockScreenAnimationConfiguration(asset: asset)
        let playbackStatus = autoPauseWhenCovered
            ? "Playing on the desktop layer. You can minimize this app; playback pauses only behind other apps."
            : "Playing continuously on the desktop layer. You can minimize this app."
        status = lockScreenError.map {
            "\(playbackStatus) Screen Saver update failed: \($0)"
        } ?? playbackStatus
    }

    /// Fires once a scene's background video render finishes. Bumps
    /// `sceneVideoRenderRevision` so the library list's "renders on first
    /// play" badge flips to "playable" immediately (see the doc comment on
    /// that property for why the plain `libraryAssets`/`status` publishes
    /// aren't enough), then refreshes the lock screen animation config.
    func handleSceneVideoRenderCompletion(assetId: String) {
        sceneVideoRenderRevision += 1
        refreshLockScreenAnimationConfigurationAfterSceneVideoRender(assetId: assetId)
    }

    /// A scene's first render is asynchronous: `refreshLockScreenAnimationConfiguration`
    /// only ever sees the fresh cached video if it's called again once the
    /// render completes. Without this, the lock screen config would stay
    /// pinned to the scene's still image (written on the initial play) until
    /// the user replayed the wallpaper.
    private func refreshLockScreenAnimationConfigurationAfterSceneVideoRender(assetId: String) {
        guard let asset = libraryAssets.first(where: { $0.id == assetId }) else {
            return
        }
        _ = refreshLockScreenAnimationConfiguration(asset: asset)
    }

    private func refreshLockScreenAnimationConfiguration(asset: WallpaperAsset) -> String? {
        guard lockScreenAnimationEnabled else {
            return nil
        }
        do {
            try lockScreenAnimationController.updateActiveAsset(asset, displayMode: displayMode)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func oldLockScreenAnimationPreference() -> Bool {
        guard userDefaults.object(forKey: PreferenceKey.lockScreenAnimationEnabled) != nil else {
            return false
        }
        return userDefaults.bool(forKey: PreferenceKey.lockScreenAnimationEnabled)
    }

    private func convertedAsset(_ asset: WallpaperAsset, output: URL) -> WallpaperAsset {
        WallpaperAsset(
            id: asset.id,
            title: asset.title,
            kind: .video,
            supportStatus: .playable,
            source: asset.source,
            projectDirectory: asset.projectDirectory,
            entrypoint: output.path,
            thumbnail: asset.thumbnail,
            workshopId: asset.workshopId,
            dateAdded: asset.dateAdded,
            contentHash: asset.contentHash,
            compatibility: .live(reason: "Converted for AVFoundation playback."),
            allowsNetworkAccess: asset.allowsNetworkAccess,
            redistributionAllowed: false,
            issues: asset.issues.filter { $0.code != "needs_conversion" }
        )
    }

    func isNewScannedAsset(_ asset: WallpaperAsset) -> Bool {
        guard let lastImportAt = userDefaults.object(forKey: PreferenceKey.lastImportAt) as? Date,
              let dateAdded = asset.dateAdded else {
            return false
        }
        return dateAdded > lastImportAt
    }

    private func scheduleAutomaticUpdateCheck(force: Bool = false) {
        Task {
            await performAutomaticUpdateCheckIfNeeded(force: force)
        }
    }

    private func applyUpdateCheckResult(_ result: UpdateCheckResult, userInitiated: Bool) {
        switch result {
        case .upToDate(_, let latestVersion):
            availableUpdate = nil
            if userInitiated {
                status = "Background Engine is up to date (\(latestVersion))."
                updateAlert = UpdateAlert(
                    title: "Already Up to Date",
                    message: "Background Engine \(latestVersion) is already the latest version."
                )
            }
        case .updateAvailable(let update):
            availableUpdate = update
            status = "Background Engine \(update.version) is available."
            if userInitiated {
                updateAlert = UpdateAlert(
                    title: "Update Available",
                    message: "Background Engine \(update.version) is available. Click Download Update to download the latest DMG."
                )
            }
        }
    }

    private static let videoContentTypes: [UTType] = [
        .movie,
        .mpeg4Movie,
        .quickTimeMovie
    ] + ["m4v", "webm", "mkv", "avi"].compactMap { UTType(filenameExtension: $0) }

    private static let automaticUpdateCheckInterval: TimeInterval = 12 * 60 * 60
}

extension AppViewModel {
    static let rotationIntervalOptions: [(label: String, seconds: TimeInterval)] = [
        ("30 sec", 30),
        ("1 min", 60),
        ("5 min", 300),
        ("15 min", 900),
        ("30 min", 1800),
        ("1 hour", 3600)
    ]

    var playableLibraryAssets: [WallpaperAsset] {
        libraryAssets.filter { $0.supportStatus == .playable }
    }

    func nextWallpaper() {
        guard rotationEnabled else {
            return
        }
        restartRotationTimer()
        advanceRotation()
    }

    func restoreRotationIfNeeded() {
        guard userDefaults.bool(forKey: PreferenceKey.rotationEnabled) else {
            return
        }
        setRotationEnabledSilently(true)
        startRotation()
    }

    func startRotation() {
        guard !playableLibraryAssets.isEmpty else {
            disableRotation(status: "Import or add a playable wallpaper before starting rotation.")
            return
        }
        userDefaults.set(true, forKey: PreferenceKey.rotationEnabled)
        buildRotationQueue()
        restartRotationTimer()
        advanceRotation(initial: true)
    }

    func setRotationEnabledSilently(_ value: Bool) {
        isSyncingRotation = true
        rotationEnabled = value
        isSyncingRotation = false
    }

    /// Single exit point for turning rotation off: stop the timer, flip the
    /// published flag without side effects, and clear the persisted preference
    /// so a stale "enabled" value is never restored on the next launch.
    func disableRotation(status message: String? = nil) {
        stopRotationTimer()
        setRotationEnabledSilently(false)
        userDefaults.set(false, forKey: PreferenceKey.rotationEnabled)
        if let message {
            status = message
        }
    }

    func buildRotationQueue() {
        var ids = playableLibraryAssets.map(\.id)
        if rotationShuffle {
            ids.shuffle()
        }
        rotationQueue = ids
        if let selected = selectedLibraryAsset?.id,
           let index = rotationQueue.firstIndex(of: selected) {
            rotationIndex = index
        } else {
            rotationIndex = 0
        }
    }

    func advanceRotation(initial: Bool = false) {
        guard !rotationQueue.isEmpty else {
            disableRotation()
            return
        }
        if !initial {
            rotationIndex = (rotationIndex + 1) % rotationQueue.count
        }
        var attempts = 0
        var lastPlaybackError: String?
        while attempts < rotationQueue.count {
            let id = rotationQueue[rotationIndex]
            if let asset = libraryAssets.first(where: { $0.id == id && $0.supportStatus == .playable }) {
                selectedLibraryAssetId = id
                do {
                    try play(asset: asset, remember: true)
                    status = "Rotating \(rotationIndex + 1)/\(rotationQueue.count): \(asset.title)"
                } catch {
                    lastPlaybackError = error.localizedDescription
                    rotationIndex = (rotationIndex + 1) % rotationQueue.count
                    attempts += 1
                    continue
                }
                return
            }
            rotationIndex = (rotationIndex + 1) % rotationQueue.count
            attempts += 1
        }
        if let lastPlaybackError {
            disableRotation(status: "Rotation stopped: \(lastPlaybackError)")
            return
        }
        disableRotation(status: "No playable wallpapers left to rotate.")
    }

    func restartRotationTimer() {
        stopRotationTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: rotationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceRotation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    func stopRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = nil
    }
}

private enum PreferenceKey {
    static let displayMode = "displayMode"
    static let autoPauseWhenCovered = "autoPauseWhenCovered"
    static let lockScreenAnimationEnabled = "lockScreenAnimationEnabled"
    static let lastPlayedAssetId = "lastPlayedAssetId"
    static let automaticallyCheckForUpdates = "automaticallyCheckForUpdates"
    static let lastUpdateCheckAt = "lastUpdateCheckAt"
    static let sceneEngineAssetsDirectory = "sceneEngineAssetsDirectory"
    static let sceneEngineAssetsBookmark = "sceneEngineAssetsBookmark.v1"
    static let wallpaperAudioEnabled = "wallpaperAudioEnabled"
    static let wallpaperAudioVolume = "wallpaperAudioVolume"
    static let rotationEnabled = "rotationEnabled"
    static let rotationShuffle = "rotationShuffle"
    static let rotationInterval = "rotationInterval"
    static let scannedSortOrder = "scannedSortOrder"
    static let lastImportAt = "lastImportAt"
    static let legacyMigrationCompleted = "legacyMigrationCompleted.v1"
}

private func dateAddedSort(_ lhs: WallpaperAsset, _ rhs: WallpaperAsset) -> Bool {
    switch (lhs.dateAdded, rhs.dateAdded) {
    case let (left?, right?) where left != right:
        return left > right
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    default:
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }
}
