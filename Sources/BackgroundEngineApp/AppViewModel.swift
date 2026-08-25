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

enum WebWallpaperPropertyEditorError: LocalizedError, Equatable {
    case libraryBusy
    case staleAsset

    var errorDescription: String? {
        switch self {
        case .libraryBusy:
            "Wait for the current library operation to finish before saving Web properties."
        case .staleAsset:
            "This wallpaper changed while its properties were open. Reopen the editor and try again."
        }
    }
}

private final class NotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit {
        center.removeObserver(token)
    }
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
    func prepareForLibraryAssetReplacement(_ assetID: WallpaperAsset.ID) async
    func finishLibraryAssetReplacement(_ assetID: WallpaperAsset.ID)
    func reconcileLibraryAssets(_ assets: [WallpaperAsset])
    func refreshIfNeeded(afterWebPropertyChangeFor assetID: WallpaperAsset.ID)
}

extension WallpaperPlaying {
    func prepareForLibraryAssetReplacement(_: WallpaperAsset.ID) async {}
    func finishLibraryAssetReplacement(_: WallpaperAsset.ID) {}
    func reconcileLibraryAssets(_: [WallpaperAsset]) {}
    func refreshIfNeeded(afterWebPropertyChangeFor _: WallpaperAsset.ID) {}
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
    @Published private(set) var runtimeHealth = RuntimeHealth(
        sceneRenderer: RuntimeComponentHealth(
            availability: .missing,
            detail: "Scene renderer has not been checked."
        ),
        mediaTools: RuntimeComponentHealth(
            availability: .missing,
            detail: "Media tools have not been checked."
        ),
        engineAssets: RuntimeComponentHealth(
            availability: .missing,
            detail: "Engine assets have not been checked."
        )
    )
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
    private let connectedDisplayProvider: @MainActor () -> [ConnectedDisplay]
    private var isSyncingLaunchAtLogin = false
    private var isSyncingLockScreenAnimation = false
    private var isSyncingRotation = false
    private var rotationTimer: Timer?
    private var workshopDownloadTask: Task<Void, Never>?
    private var workshopStatusPollingTask: Task<Void, Never>?
    private var preparedLibraryReplacementAssetIDs: Set<WallpaperAsset.ID> = []
    private var lockScreenConfiguredAssetID: WallpaperAsset.ID?
    private var pendingWebNetworkAssetRevision: WallpaperAsset?
    private var sceneCompatibilityProbeTasks: [WallpaperAsset.ID: Task<Void, Never>] = [:]
    private var sceneAssetsAccessURL: URL?
    private var rotationQueue: [WallpaperAsset.ID] = []
    private var rotationIndex = 0
    private var screenParametersObservation: NotificationObservation?

    init() {
        userDefaults = .standard
        loginItemController = LoginItemController()
        lockScreenAnimationController = LockScreenAnimationController()
        updateChecker = GitHubReleaseUpdateChecker()
        updateURLOpener = WorkspaceUpdateURLOpener()
        wallpaperPlayer = WallpaperPlayer.shared
        currentVersionProvider = { AppVersionProvider.currentVersion() }
        connectedDisplayProvider = { ConnectedDisplay.current() }
        do {
            store = try LibraryStore.defaultStore()
            configureSceneHandlers()
            restorePreferences()
            loadLibrary()
            playLastWallpaperIfAvailable()
            restoreLockScreenAnimationIfNeeded()
            restoreRotationIfNeeded()
        } catch {
            store = LibraryStore(
                root: FileManager.default.temporaryDirectory.appending(path: "Background Engine")
            )
            configureSceneHandlers()
            status = error.localizedDescription
        }
        syncLaunchAtLoginStatus()
        refreshRuntimeHealth()
        scheduleAutomaticUpdateCheck()
        if !userDefaults.bool(forKey: PreferenceKey.legacyMigrationCompleted) {
            Task { await refreshLegacyMigrationPreview() }
        }
        startScreenParametersObservation()
    }

    init(
        store: LibraryStore,
        loginItemController: LoginItemManaging = LoginItemController(),
        lockScreenAnimationController: LockScreenAnimationManaging = LockScreenAnimationController(),
        updateChecker: UpdateChecking = DisabledUpdateChecker(),
        updateURLOpener: UpdateURLOpening = WorkspaceUpdateURLOpener(),
        wallpaperPlayer: WallpaperPlaying = WallpaperPlayer.shared,
        currentVersionProvider: @escaping () -> String = { "0.0.0" },
        connectedDisplayProvider: @escaping @MainActor () -> [ConnectedDisplay] = { ConnectedDisplay.current() },
        userDefaults: UserDefaults = .standard
    ) {
        self.store = store
        self.loginItemController = loginItemController
        self.lockScreenAnimationController = lockScreenAnimationController
        self.updateChecker = updateChecker
        self.updateURLOpener = updateURLOpener
        self.wallpaperPlayer = wallpaperPlayer
        self.currentVersionProvider = currentVersionProvider
        self.connectedDisplayProvider = connectedDisplayProvider
        self.userDefaults = userDefaults
        configureSceneHandlers()
        restorePreferences()
        loadLibrary()
        playLastWallpaperIfAvailable()
        restoreLockScreenAnimationIfNeeded()
        restoreRotationIfNeeded()
        syncLaunchAtLoginStatus()
        refreshRuntimeHealth()
        startScreenParametersObservation()
    }

    private func configureSceneHandlers() {
        SceneWallpaperContentFactory.statusHandler = { [weak self] message in
            self?.status = message
        }
        SceneWallpaperContentFactory.sceneVideoRenderCompletionHandler = { [weak self] assetId in
            self?.handleSceneVideoRenderCompletion(assetId: assetId)
        }
        SceneWallpaperContentFactory.compatibilityReportHandler = { [weak self] asset, report in
            self?.handleSceneCompatibilityReport(asset: asset, report: report)
        }
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

    var selectedWebFileProperties: [WebWallpaperCompatibilityBridge.FileProperty] {
        guard let asset = selectedLibraryAsset, asset.kind == .web else { return [] }
        return WebWallpaperCompatibilityBridge.fileProperties(
            projectRoot: URL(filePath: asset.projectDirectory)
        )
    }

    var selectedWebEditableProperties: [WebWallpaperCompatibilityBridge.EditableProperty] {
        guard let asset = selectedLibraryAsset, asset.kind == .web else { return [] }
        return WebWallpaperCompatibilityBridge.editableProperties(
            projectRoot: URL(filePath: asset.projectDirectory)
        )
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

    func chooseWebProperty(_ property: WebWallpaperCompatibilityBridge.FileProperty) {
        guard !isWorking else {
            status = "Wait for the current library operation to finish before choosing another Web property."
            return
        }
        guard let asset = selectedLibraryAsset, asset.kind == .web else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = property.selectsDirectory
        panel.canChooseFiles = !property.selectsDirectory
        panel.allowsMultipleSelection = false
        panel.message = "Choose a local value for the Web wallpaper property ‘\(property.name)’."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await WebWallpaperUserFileStore.shared.copySelection(
                    source,
                    propertyName: property.name,
                    into: URL(filePath: asset.projectDirectory)
                )
                wallpaperPlayer.refreshIfNeeded(afterWebPropertyChangeFor: asset.id)
                status = "Copied the selected value for ‘\(property.name)’ into the wallpaper sandbox."
            } catch {
                status = "Could not set ‘\(property.name)’: \(error.localizedDescription)"
            }
        }
    }

    func saveWebPropertyOverrides(
        _ values: [String: WebWallpaperPropertyValue],
        for snapshot: WallpaperAsset
    ) async throws {
        guard !isWorking else { throw WebWallpaperPropertyEditorError.libraryBusy }
        guard let current = currentWebAsset(matching: snapshot) else {
            throw WebWallpaperPropertyEditorError.staleAsset
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let properties = WebWallpaperCompatibilityBridge.editableProperties(
                projectRoot: URL(filePath: current.projectDirectory)
            )
            let overrides = WebWallpaperCompatibilityBridge.persistedOverrides(
                values,
                properties: properties
            )
            try await WebWallpaperUserFileStore.shared.saveValueOverrides(
                overrides,
                into: URL(filePath: current.projectDirectory)
            )
            guard currentWebAsset(matching: snapshot) != nil else {
                throw WebWallpaperPropertyEditorError.staleAsset
            }
            wallpaperPlayer.refreshIfNeeded(afterWebPropertyChangeFor: current.id)
            status = overrides.isEmpty
                ? "Restored the Web wallpaper property defaults."
                : "Saved \(overrides.count) custom Web wallpaper propert\(overrides.count == 1 ? "y" : "ies")."
        } catch {
            status = "Could not save Web wallpaper properties: \(error.localizedDescription)"
            throw error
        }
    }

    private func currentWebAsset(matching snapshot: WallpaperAsset) -> WallpaperAsset? {
        libraryAssets.first {
            $0.id == snapshot.id
                && $0.kind == .web
                && $0.projectDirectory == snapshot.projectDirectory
                && $0.contentHash == snapshot.contentHash
        }
    }

    func setSceneAssetsFolder(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        guard SceneEngineRendererConfiguration.isValidAssetsDirectory(standardizedURL) else {
            status = "This Wallpaper Engine assets folder is incomplete. Copy the full contents of "
                + "steamapps/common/wallpaper_engine/assets, not the parent folder."
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
        refreshRuntimeHealth()
        status = "Scene Engine assets folder access saved. The original folder is never modified."
    }

    func clearSceneAssetsFolder() {
        sceneAssetsAccessURL?.stopAccessingSecurityScopedResource()
        sceneAssetsAccessURL = nil
        sceneAssetsDirectory = ""
        userDefaults.removeObject(forKey: PreferenceKey.sceneEngineAssetsDirectory)
        SecurityScopedBookmarkStore(defaults: userDefaults).remove(key: PreferenceKey.sceneEngineAssetsBookmark)
        SceneEngineRendererConfiguration.overrideAssetsPath = nil
        refreshRuntimeHealth()
        status = "Scene Engine assets folder reset to the default path."
    }

    func refreshRuntimeHealth() {
        let renderer = SceneEngineRendererConfiguration.executableURL().map {
            RuntimeComponentHealth(
                availability: .available,
                version: SceneVideoCache.rendererVersion,
                detail: "Bundled Universal Scene renderer is ready: \($0.lastPathComponent)"
            )
        } ?? RuntimeComponentHealth(
            availability: .missing,
            version: SceneVideoCache.rendererVersion,
            detail: "Bundled Scene renderer is missing or not executable."
        )
        let assets: RuntimeComponentHealth
        if let directory = SceneEngineRendererConfiguration.assetsDirectoryURL(),
           let fingerprint = RuntimeFingerprint.engineAssets(
            at: directory,
            requiredPaths: SceneEngineRendererConfiguration.requiredAssetPaths
           ) {
            assets = RuntimeComponentHealth(
                availability: .available,
                version: String(fingerprint.prefix(16)),
                detail: "Wallpaper Engine assets are complete."
            )
        } else if sceneAssetsDirectory.isEmpty {
            assets = RuntimeComponentHealth(
                availability: .missing,
                detail: "Choose the wallpaper_engine/assets folder before rendering Scene caches."
            )
        } else {
            assets = RuntimeComponentHealth(
                availability: .invalid,
                detail: "The selected Wallpaper Engine assets folder is incomplete."
            )
        }
        runtimeHealth = RuntimeHealth(
            sceneRenderer: renderer,
            mediaTools: MediaToolResolver().runtimeHealth(),
            engineAssets: assets
        )
    }

    func clearSceneCache() {
        status = "Cancelling active Scene renders…"
        Task {
            await SceneRenderCoordinator.shared.cancelAll()
            let cache = SceneVideoCache.cacheDirectoryURL()
            do {
                if FileManager.default.fileExists(atPath: cache.path) {
                    try FileManager.default.removeItem(at: cache)
                }
                sceneVideoRenderRevision += 1
                status = "Scene cache cleared. It will be rebuilt when needed."
            } catch {
                status = "Could not clear the Scene cache: \(error.localizedDescription)"
            }
        }
    }

    func clearWebMediaCache() {
        status = "Cancelling active Web media conversions…"
        Task {
            do {
                try await WebMediaRuntimeCoordinator.shared.clearCache()
                for asset in libraryAssets where asset.kind == .web {
                    wallpaperPlayer.refreshIfNeeded(afterWebPropertyChangeFor: asset.id)
                }
                status = "Web media cache cleared. It will be rebuilt when needed."
            } catch {
                status = "Could not clear the Web media cache: \(error.localizedDescription)"
            }
        }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Background-Engine-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data = try DiagnosticsExporter.data(
                appVersion: currentVersionProvider(),
                runtime: runtimeHealth,
                assets: libraryAssets,
                log: [status, SceneWallpaperContentFactory.lastDiagnostic].compactMap { $0 }
            )
            try data.write(to: destination, options: [.atomic])
            status = "Diagnostics exported without wallpaper files, Steam data, or unfiltered paths."
        } catch {
            status = "Could not export diagnostics: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func scanSource() -> Task<Void, Never> {
        guard !sourcePath.isEmpty else {
            status = "Choose a folder first."
            return Task {}
        }
        guard !isWorking else {
            status = "Wait for the current library operation to finish."
            return Task {}
        }
        let scanner = self.scanner
        let root = URL(filePath: sourcePath)
        isWorking = true
        status = "Scanning wallpaper contents…"
        return Task {
            defer { isWorking = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try scanner.scan(root: root)
                }.value
                scannedAssets = sortedScannedAssets(result.assets)
                selectedScannedAssetIds = scannedAssets.first.map { Set([$0.id]) } ?? []
                status = "Found \(result.assets.count) project(s)."
            } catch {
                status = error.localizedDescription
            }
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
            do {
                try Task.checkCancellation()
            } catch {
                workshopDownloadStatus = WorkshopDownloadStatus(
                    itemID: itemID,
                    phase: .cancelled,
                    progress: nil,
                    message: "Download cancelled."
                )
                status = "Workshop download cancelled."
                isWorking = false
                workshopDownloadTask = nil
                return
            }
            let statusPollingTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled,
                          let remoteStatus = try? await service.status(),
                          !Task.isCancelled,
                          remoteStatus.phase == .installingSteamCMD
                            || remoteStatus.phase == .downloading else {
                        continue
                    }
                    workshopDownloadStatus = remoteStatus
                }
            }
            installWorkshopStatusPollingTask(statusPollingTask)
            defer {
                statusPollingTask.cancel()
                workshopStatusPollingTask = nil
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
                let imported = try await service.downloadAndImport(input: input) { [weak self] candidate in
                    await self?.prepareForLibraryReplacement(candidate)
                }
                try commitWorkshopDownloadCompletion(imported)
            } catch WorkshopDownloadServiceError.cancelledAfterImport(let imported) {
                loadLibrary()
                finishPreparedLibraryReplacements()
                selectedLibraryAssetId = imported.id
                let conversionWarning = automaticConversionWarning(for: imported)
                let detail = conversionWarning ?? "The imported wallpaper was kept."
                workshopDownloadStatus = WorkshopDownloadStatus(
                    itemID: imported.workshopId,
                    phase: .cancelled,
                    progress: 1,
                    message: "Cancelled after import. \(detail)"
                )
                status = "Workshop download cancelled after importing \(imported.title). \(detail)"
            } catch is CancellationError {
                loadLibrary()
                finishPreparedLibraryReplacements()
                workshopDownloadStatus = WorkshopDownloadStatus(
                    itemID: itemID,
                    phase: .cancelled,
                    progress: nil,
                    message: "Download cancelled."
                )
                status = "Workshop download cancelled."
            } catch {
                // A pre-import replacement quiesces only the affected live
                // sessions. Reloading here restores them when staging/import
                // fails before any new revision is committed.
                loadLibrary()
                finishPreparedLibraryReplacements()
                if Task.isCancelled {
                    workshopDownloadStatus = WorkshopDownloadStatus(
                        itemID: itemID,
                        phase: .cancelled,
                        progress: nil,
                        message: "Download cancelled."
                    )
                    status = "Workshop download cancelled."
                } else {
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
    }

    /// The service checks cancellation before returning, but cancellation can
    /// still arrive while its actor hop is resuming this MainActor task. Keep
    /// this check in the same synchronous MainActor turn as the visible state
    /// commit so a Cancelled download can never be overwritten by Completed.
    func commitWorkshopDownloadCompletion(_ imported: WallpaperAsset) throws {
        guard !Task.isCancelled else {
            throw WorkshopDownloadServiceError.cancelledAfterImport(imported)
        }
        loadLibrary()
        finishPreparedLibraryReplacements()
        selectedLibraryAssetId = imported.id
        let conversionWarning = automaticConversionWarning(for: imported)
        workshopDownloadStatus = WorkshopDownloadStatus(
            itemID: imported.workshopId,
            phase: .completed,
            progress: 1,
            message: conversionWarning.map {
                "Imported \(imported.title), but \($0)"
            } ?? "Imported \(imported.title)."
        )
        status = conversionWarning.map {
            "Downloaded and imported \(imported.title), but \($0)"
        } ?? "Downloaded and imported \(imported.title)."
    }

    func cancelWorkshopDownload() {
        workshopStatusPollingTask?.cancel()
        workshopStatusPollingTask = nil
        workshopDownloadTask?.cancel()
        workshopDownloadTask = nil
        workshopDownloadStatus = WorkshopDownloadStatus(
            itemID: workshopDownloadStatus.itemID,
            phase: .cancelled,
            progress: nil,
            message: "Download cancelled."
        )
        status = "Workshop download cancelled."
        Task {
            await WorkshopDownloadService(store: store).cancel()
        }
    }

    func installWorkshopStatusPollingTask(_ task: Task<Void, Never>) {
        workshopStatusPollingTask?.cancel()
        workshopStatusPollingTask = task
    }

    private func prepareForLibraryReplacement(_ candidate: WallpaperAsset) async {
        let existing = candidate.workshopId.flatMap { workshopID in
            libraryAssets.first { $0.workshopId == workshopID }
        } ?? libraryAssets.first { $0.id == candidate.id }
        guard let existing else {
            return
        }
        guard preparedLibraryReplacementAssetIDs.insert(existing.id).inserted else {
            return
        }
        await wallpaperPlayer.prepareForLibraryAssetReplacement(existing.id)
        status = "Installing the updated wallpaper…"
    }

    private func finishPreparedLibraryReplacements() {
        let preparedAssetIDs = preparedLibraryReplacementAssetIDs
        preparedLibraryReplacementAssetIDs.removeAll()
        for assetID in preparedAssetIDs.sorted() {
            wallpaperPlayer.finishLibraryAssetReplacement(assetID)
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
        guard !isWorking else {
            status = "Finish the current library operation first."
            return
        }
        let candidates = legacyMigrationCandidates
        guard !candidates.isEmpty else {
            status = "No compatible legacy wallpapers were found."
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                for candidate in candidates {
                    await prepareForLibraryReplacement(candidate.asset)
                    try Task.checkCancellation()
                }
                let imported = try await LegacyLibraryMigrator(destination: store).migrate(candidates)
                migrateLegacyPreferences()
                userDefaults.set(true, forKey: PreferenceKey.legacyMigrationCompleted)
                legacyMigrationCandidates = []
                loadLibrary()
                finishPreparedLibraryReplacements()
                status = "Imported \(imported.count) legacy wallpaper(s). Original data was not changed."
            } catch {
                loadLibrary()
                finishPreparedLibraryReplacements()
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
                    try Task.checkCancellation()
                    await prepareForLibraryReplacement(asset)
                    try Task.checkCancellation()
                    let imported = try await importer.importAndPrepareAsset(asset)
                    importedAssets.append(imported)
                    importProgress = ImportProgress(completed: importedAssets.count, total: assets.count)
                    status = "Importing \(importedAssets.count)/\(assets.count)..."
                    try Task.checkCancellation()
                }
                userDefaults.set(Date(), forKey: PreferenceKey.lastImportAt)
                loadLibrary()
                finishPreparedLibraryReplacements()
                selectLibraryAssets(Set(importedAssets.map(\.id)))
                let conversionFailures = importedAssets.compactMap {
                    automaticConversionWarning(for: $0)
                }
                if importedAssets.count == 1, let imported = importedAssets.first,
                   let warning = conversionFailures.first {
                    status = "Imported \(imported.title), but \(warning)"
                } else if importedAssets.count == 1, let imported = importedAssets.first {
                    status = "Imported \(imported.title)."
                } else if !conversionFailures.isEmpty {
                    status = "Imported \(importedAssets.count) projects; automatic conversion failed for "
                        + "\(conversionFailures.count) video(s)."
                } else {
                    status = "Imported \(importedAssets.count) projects."
                }
            } catch is CancellationError {
                if !importedAssets.isEmpty {
                    userDefaults.set(Date(), forKey: PreferenceKey.lastImportAt)
                }
                loadLibrary()
                finishPreparedLibraryReplacements()
                selectLibraryAssets(Set(importedAssets.map(\.id)))
                status = importedAssets.isEmpty
                    ? "Import cancelled."
                    : "Imported \(importedAssets.count) project(s); remaining imports cancelled."
            } catch {
                loadLibrary()
                finishPreparedLibraryReplacements()
                if importedAssets.isEmpty {
                    status = error.localizedDescription
                } else {
                    status = "Imported \(importedAssets.count) project(s), then failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func chooseWallpaperFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        // Selection is deliberately broad because support is determined from
        // file contents, not a fragile extension allowlist.
        panel.allowedContentTypes = [.item]
        panel.message = "Choose a video, GIF/APNG/WebP image, still image, or Wallpaper Engine Scene .pkg file."
        if panel.runModal() == .OK, let url = panel.url {
            importWallpaperFile(url)
        }
    }

    func chooseVideoFile() {
        chooseWallpaperFile()
    }

    func chooseWebsite() {
        let alert = NSAlert()
        alert.messageText = "Add Website Wallpaper"
        alert.informativeText = "Enter an HTTPS URL. The website gets network access, but downloads, persistent cookies, native commands, and navigation to other origins remain blocked."
        alert.addButton(withTitle: "Add Website")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "https://example.com"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        importWebsite(field.stringValue)
    }

    @discardableResult
    func importWebsite(_ input: String) -> Task<Void, Never> {
        guard !isWorking else {
            status = "Finish the current library operation first."
            return Task {}
        }
        isWorking = true
        status = "Adding website wallpaper..."
        let importer = WebsiteWallpaperImporter(store: store)
        return Task {
            defer { isWorking = false }
            do {
                let imported = try await importer.importWebsite(input)
                loadLibrary()
                selectedLibraryAssetId = imported.id
                status = "Added \(imported.title). External network access is enabled for this website only."
            } catch {
                status = error.localizedDescription
            }
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
                let imported = try await importer.importAndPrepareVideoFile(url)
                loadLibrary()
                selectedLibraryAssetId = imported.id
                status = automaticConversionWarning(for: imported).map {
                    "Added \(imported.title), but \($0)"
                } ?? "Added \(imported.title)."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    @discardableResult
    func importWallpaperFile(_ url: URL) -> Task<Void, Never> {
        guard !isWorking else {
            status = "Finish the current library operation first."
            return Task {}
        }
        isWorking = true
        status = "Adding \(url.lastPathComponent)..."
        let importer = WallpaperImporter(store: store)
        return Task {
            defer { isWorking = false }
            do {
                let imported = try await importer.importAndPrepareMediaFile(url)
                loadLibrary()
                selectedLibraryAssetId = imported.id
                status = automaticConversionWarning(for: imported).map {
                    "Added \(imported.title), but \($0)"
                } ?? "Added \(imported.title)."
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

    @discardableResult
    func removeSelectedLibraryAsset() -> Task<Void, Never> {
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

    @discardableResult
    func removeSelectedLibraryAssets() -> Task<Void, Never> {
        guard !isWorking else {
            status = "Finish the current library operation first."
            return Task {}
        }
        let assets = selectedLibraryAssets
        pendingLibraryRemoval = nil
        guard !assets.isEmpty else {
            status = "Select a library project first."
            return Task {}
        }
        let wasRotating = rotationEnabled
        let store = self.store
        let wallpaperPlayer = self.wallpaperPlayer
        isWorking = true
        status = assets.count == 1 ? "Removing wallpaper…" : "Removing \(assets.count) wallpapers…"
        return Task { [weak self] in
            // Close only sessions that can still read these project roots and
            // synchronously drain any Scene renderer/FFmpeg job before the
            // store performs its first same-volume rename. The replacement
            // barrier is also useful here: if Trash cleanup rolls back, the
            // terminal manifest reload can safely restore the prior session.
            for asset in assets {
                await wallpaperPlayer.prepareForLibraryAssetReplacement(asset.id)
            }
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do {
                    for asset in assets {
                        try store.removeAsset(id: asset.id)
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            self?.loadLibrary()
            for asset in assets {
                wallpaperPlayer.finishLibraryAssetReplacement(asset.id)
            }
            guard let self else { return }
            self.isWorking = false
            if let failure {
                self.status = failure
            } else if wasRotating, !self.rotationEnabled {
                if assets.count == 1, let asset = assets.first {
                    self.status = "Moved \(asset.title) to the Trash. Rotation stopped — no playable wallpapers left."
                } else {
                    self.status = "Moved \(assets.count) items to the Trash. Rotation stopped — no playable wallpapers left."
                }
            } else if assets.count == 1, let asset = assets.first {
                self.status = "Moved \(asset.title) to the Trash. The original copied folder was not touched."
            } else {
                self.status = "Moved \(assets.count) items to the Trash. The original copied folders were not touched."
            }
        }
    }

    func convertSelected() {
        guard !isWorking else {
            status = "Finish the current library operation first."
            return
        }
        guard let asset = selectedLibraryAsset,
              asset.videoConversionActionAvailable,
              asset.entrypoint != nil else {
            status = "Select a library video first."
            return
        }
        isWorking = true
        status = "Converting \(asset.title)..."
        Task {
            do {
                let converted = try await convertAsset(asset)
                selectedLibraryAssetId = converted.id
                status = "Converted \(asset.title)."
            } catch {
                status = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func convertAsset(_ asset: WallpaperAsset) async throws -> WallpaperAsset {
        let store = self.store
        let preparation = try await Task.detached { () -> (PinnedVideoInput, URL) in
            let cacheDirectory = Self.videoConversionCacheDirectory()
            let input: PinnedVideoInput
            if asset.compatibilityReport?.playbackPath == .convertedVideo {
                input = try store.copyVideoConversionSource(
                    for: asset,
                    into: cacheDirectory
                )
            } else if let entrypoint = asset.entrypoint {
                input = try store.copyStableVideoInput(
                    for: asset,
                    originalInput: URL(filePath: entrypoint),
                    into: cacheDirectory
                )
            } else {
                throw LibraryStoreError.missingVideoConversionSource(asset.id)
            }
            let contentHash = asset.contentHash ?? input.contentHash
            let cacheKey = VideoConversionCacheKey(contentHash: contentHash)
            let output = cacheDirectory.appending(path: cacheKey.fileName)
            return (input, output)
        }.value
        defer { preparation.0.cleanup() }
        try await converter.convertToPlayableVideo(
            input: preparation.0,
            output: preparation.1,
            timeout: VideoConverter.defaultTimeout
        )
        let converted = convertedAsset(asset, output: preparation.1)
        await wallpaperPlayer.prepareForLibraryAssetReplacement(asset.id)
        do {
            try store.replaceAsset(converted)
            loadLibrary()
            wallpaperPlayer.finishLibraryAssetReplacement(asset.id)
            return converted
        } catch {
            wallpaperPlayer.finishLibraryAssetReplacement(asset.id)
            throw error
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
            wallpaperPlayer.reconcileLibraryAssets(manifest.assets)
            scheduleSceneCompatibilityProbes(for: manifest.assets)
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

    /// Schedules only stale/pending Scene reports. The expensive render-plan
    /// construction runs away from the main actor; results are merged back
    /// only when the asset still points at the same content that was probed.
    private func scheduleSceneCompatibilityProbes(for assets: [WallpaperAsset]) {
        for asset in assets where asset.kind == .scene {
            let report = asset.compatibilityReport
            guard report == nil
                    || report?.probeVersion != CompatibilityReport.currentProbeVersion
                    || report?.needsProbe == true else {
                continue
            }
            guard sceneCompatibilityProbeTasks[asset.id] == nil else {
                continue
            }
            let store = self.store
            sceneCompatibilityProbeTasks[asset.id] = Task { [weak self] in
                let nativePlayable: Bool?
                if let entrypoint = asset.entrypoint.map({ URL(filePath: $0) }) {
                    let cacheKey = SceneNativeReadinessCoordinator.cacheKey(
                        contentHash: asset.contentHash,
                        url: entrypoint
                    )
                    nativePlayable = await SceneNativeReadinessCoordinator.shared
                        .renderablePlan(for: entrypoint, cacheKey: cacheKey) != nil
                } else {
                    nativePlayable = nil
                }
                let probed = await Task.detached(priority: .utility) {
                    store.probeSceneCompatibility(
                        for: asset,
                        nativePlayable: nativePlayable
                    )
                }.value
                guard !Task.isCancelled, let self else {
                    return
                }
                self.finishSceneCompatibilityProbe(probed, original: asset)
            }
        }
    }

    private func finishSceneCompatibilityProbe(
        _ probed: WallpaperAsset,
        original: WallpaperAsset
    ) {
        guard let index = libraryAssets.firstIndex(where: { $0.id == original.id }) else {
            sceneCompatibilityProbeTasks[original.id] = nil
            return
        }
        let current = libraryAssets[index]
        let currentReport = current.compatibilityReport
        guard currentReport == nil
                || currentReport?.probeVersion != CompatibilityReport.currentProbeVersion
                || currentReport?.needsProbe == true else {
            // Playback may already have produced a more authoritative runtime
            // report while the static probe was running. Never overwrite it
            // with the older background result.
            sceneCompatibilityProbeTasks[original.id] = nil
            return
        }
        guard current.entrypoint == original.entrypoint,
              current.contentHash == original.contentHash else {
            sceneCompatibilityProbeTasks[original.id] = nil
            scheduleSceneCompatibilityProbes(for: [current])
            return
        }
        let updated = WallpaperAsset(
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
            compatibility: probed.compatibility,
            compatibilityReport: probed.compatibilityReport,
            allowsNetworkAccess: current.allowsNetworkAccess,
            redistributionAllowed: probed.redistributionAllowed,
            issues: probed.issues
        )
        do {
            if try store.replaceAsset(updated, ifUnchangedFrom: current) {
                libraryAssets[index] = updated
            } else {
                // An import or runtime report won the race. Reload its state
                // and schedule a fresh probe only if it is still pending.
                sceneCompatibilityProbeTasks[original.id] = nil
                loadLibrary()
                return
            }
        } catch {
            status = "Could not save Scene compatibility: \(error.localizedDescription)"
        }
        sceneCompatibilityProbeTasks[original.id] = nil
    }

    /// Test/CLI seam that waits for the currently scheduled background probes
    /// without exposing task implementation details to the UI.
    func waitForSceneCompatibilityProbes() async {
        while let task = sceneCompatibilityProbeTasks.values.first {
            await task.value
        }
    }

    func refreshConnectedDisplays() {
        connectedDisplays = connectedDisplayProvider()
        selectedDisplayUUID = selectedDisplayUUID.flatMap { selected in
            connectedDisplays.contains(where: { $0.id == selected }) ? selected : nil
        } ?? connectedDisplays.first?.id
        var changed = false
        for display in connectedDisplays where !displayAssignments.contains(where: { $0.displayUUID == display.id }) {
            displayAssignments.append(DisplayAssignment(displayUUID: display.id, assetID: nil))
            changed = true
        }
        if changed {
            do {
                try store.replaceDisplayAssignments(displayAssignments)
            } catch {
                status = "Could not save display sessions: \(error.localizedDescription)"
            }
        }
    }

    func handleDisplayTopologyChange() {
        refreshConnectedDisplays()
    }

    private func startScreenParametersObservation() {
        guard screenParametersObservation == nil else { return }
        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDisplayTopologyChange()
            }
        }
        screenParametersObservation = NotificationObservation(center: center, token: token)
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
        guard !isWorking else {
            status = "Finish the current library operation first."
            return
        }
        if asset.allowsNetworkAccess == true {
            setWebNetworkAccess(expectedAsset: asset, allowed: false)
        } else {
            pendingWebNetworkAssetID = asset.id
            pendingWebNetworkAssetRevision = asset
        }
    }

    func confirmWebNetworkAccess() {
        guard let expectedAsset = pendingWebNetworkAssetRevision,
              pendingWebNetworkAssetID == expectedAsset.id else { return }
        pendingWebNetworkAssetID = nil
        pendingWebNetworkAssetRevision = nil
        guard !isWorking else {
            status = "Finish the current library operation first."
            return
        }
        setWebNetworkAccess(expectedAsset: expectedAsset, allowed: true)
    }

    func cancelWebNetworkAccessChange() {
        pendingWebNetworkAssetID = nil
        pendingWebNetworkAssetRevision = nil
    }

    private func setWebNetworkAccess(expectedAsset: WallpaperAsset, allowed: Bool) {
        do {
            let updated = expectedAsset.allowingNetworkAccess(allowed)
            guard try store.replaceAsset(updated, ifUnchangedFrom: expectedAsset) else {
                loadLibrary()
                status = "This Web wallpaper changed. Review its network access again."
                return
            }
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
            lockScreenConfiguredAssetID = enabled ? selectedLibraryAsset?.id : nil
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
            lockScreenConfiguredAssetID = selectedLibraryAsset?.id
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

    func handleSceneCompatibilityReport(asset reportedAsset: WallpaperAsset, report: CompatibilityReport) {
        guard let current = libraryAssets.first(where: { $0.id == reportedAsset.id }),
              current.contentHash == reportedAsset.contentHash,
              current.entrypoint == reportedAsset.entrypoint else {
            return
        }
        let updated = current.replacing(
            compatibility: report.supportMode,
            compatibilityReport: report
        )
        do {
            guard try store.replaceAsset(updated, ifUnchangedFrom: current) else {
                // A Workshop update or another compatibility probe replaced
                // this revision while the renderer callback was in flight.
                // Reload the winner instead of restoring stale paths/hash.
                loadLibrary()
                return
            }
            loadLibrary()
        } catch {
            status = "Could not save Scene compatibility: \(error.localizedDescription)"
        }
    }

    /// A scene's first render is asynchronous: `refreshLockScreenAnimationConfiguration`
    /// only ever sees the fresh cached video if it's called again once the
    /// render completes. Without this, the lock screen config would stay
    /// pinned to the scene's still image (written on the initial play) until
    /// the user replayed the wallpaper.
    private func refreshLockScreenAnimationConfigurationAfterSceneVideoRender(assetId: String) {
        guard lockScreenConfiguredAssetID == assetId,
              let asset = libraryAssets.first(where: { $0.id == assetId }) else {
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
            lockScreenConfiguredAssetID = asset.id
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
            compatibility: .cached(reason: "Converted for AVFoundation playback."),
            compatibilityReport: CompatibilityReport(level: .full, playbackPath: .convertedVideo),
            allowsNetworkAccess: asset.allowsNetworkAccess,
            redistributionAllowed: false,
            issues: asset.issues.filter {
                $0.code != "needs_conversion"
                    && $0.code != "automatic_conversion_failed"
                    && $0.code != "automatic_conversion_cancelled"
                    && $0.code != VideoConverter.outdatedRecipeIssueCode
            }
        )
    }

    private func automaticConversionWarning(for asset: WallpaperAsset) -> String? {
        asset.issues.first {
            $0.code == "automatic_conversion_failed"
                || $0.code == "automatic_conversion_cancelled"
        }?.message
    }

    nonisolated private static func videoConversionCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "Background Engine")
            .appending(path: "ConvertedVideoCache")
            .appending(path: MediaToolResolver.pinnedBuildID)
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
