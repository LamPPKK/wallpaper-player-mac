import AppKit
import BackgroundEngineCore

enum AssignedDisplayRefreshPlan {
    struct AppliedSession: Equatable {
        let assignment: DisplayAssignment?
        let asset: WallpaperAsset
    }

    struct Application: Equatable {
        let displayUUIDsToClose: Set<String>
        let displayUUIDsToReplace: Set<String>
    }

    static func application(
        appliedSessions: [String: AppliedSession],
        currentAssignments: [DisplayAssignment],
        currentAssets: [WallpaperAsset.ID: WallpaperAsset],
        connectedDisplayUUIDs: Set<String>,
        existingWindowUUIDs: Set<String>,
        topologyChangedDisplayUUIDs: Set<String> = []
    ) -> Application {
        let currentByDisplay = effectiveAssignments(currentAssignments)

        var displayUUIDsToClose = existingWindowUUIDs.subtracting(connectedDisplayUUIDs)
        var displayUUIDsToReplace: Set<String> = []

        for displayUUID in connectedDisplayUUIDs {
            guard let currentAssignment = currentByDisplay[displayUUID],
                  let assetID = currentAssignment.assetID else {
                if existingWindowUUIDs.contains(displayUUID) {
                    displayUUIDsToClose.insert(displayUUID)
                }
                continue
            }
            guard let currentAsset = currentAssets[assetID] else {
                if existingWindowUUIDs.contains(displayUUID) {
                    displayUUIDsToClose.insert(displayUUID)
                }
                displayUUIDsToReplace.insert(displayUUID)
                continue
            }
            guard currentAsset.supportStatus == .playable,
                  currentAsset.entrypoint != nil else {
                if existingWindowUUIDs.contains(displayUUID) {
                    displayUUIDsToClose.insert(displayUUID)
                }
                displayUUIDsToReplace.insert(displayUUID)
                continue
            }

            let assignmentChanged = appliedSessions[displayUUID]?.assignment != currentAssignment
            let assetChanged = appliedSessions[displayUUID]?.asset != currentAsset
            if assignmentChanged
                || assetChanged
                || topologyChangedDisplayUUIDs.contains(displayUUID)
                || !existingWindowUUIDs.contains(displayUUID) {
                displayUUIDsToReplace.insert(displayUUID)
            }
        }

        return Application(
            displayUUIDsToClose: displayUUIDsToClose,
            displayUUIDsToReplace: displayUUIDsToReplace
        )
    }

    static func effectiveAssignments(
        _ assignments: [DisplayAssignment]
    ) -> [String: DisplayAssignment] {
        assignments.reduce(into: [String: DisplayAssignment]()) {
            $0[$1.displayUUID] = $1
        }
    }

    static func displayUUIDs(
        for assetID: WallpaperAsset.ID,
        assignments: [DisplayAssignment]
    ) -> Set<String> {
        let effectiveAssignments = effectiveAssignments(assignments)
        return Set(
            effectiveAssignments.values.lazy
                .filter { $0.assetID == assetID }
                .map(\.displayUUID)
        )
    }

    static func displayUUIDs(
        applying assetID: WallpaperAsset.ID,
        sessions: [String: AppliedSession]
    ) -> Set<String> {
        Set(sessions.compactMap { displayUUID, session in
            session.asset.id == assetID ? displayUUID : nil
        })
    }

    static func fallbackDisplayUUIDs(
        quiescedSessions: [String: AppliedSession],
        desiredAssignments: [DisplayAssignment],
        occupiedDisplayUUIDs: Set<String>
    ) -> Set<String> {
        let desiredByDisplay = effectiveAssignments(desiredAssignments)
        return Set(quiescedSessions.keys.filter { displayUUID in
            !occupiedDisplayUUIDs.contains(displayUUID)
                && desiredByDisplay[displayUUID]?.assetID != nil
        })
    }

    static func capturesCompleteTopology(requestedDisplayUUIDs: Set<String>?) -> Bool {
        requestedDisplayUUIDs == nil
    }

    static func shouldRefreshSingleWallpaper(
        for assetID: WallpaperAsset.ID,
        assignments: [DisplayAssignment],
        activeAssetID: WallpaperAsset.ID?,
        activeAssetKind: WallpaperKind?,
        expectedKind: WallpaperKind
    ) -> Bool {
        assignments.isEmpty && activeAssetID == assetID && activeAssetKind == expectedKind
    }

    static func applyingSuccessfulReplacements<Value>(
        _ replacements: [String: Value],
        to existing: [String: Value]
    ) -> (active: [String: Value], retired: [Value]) {
        var active = existing
        var retired: [Value] = []
        for (displayUUID, replacement) in replacements {
            if let previous = active.updateValue(replacement, forKey: displayUUID) {
                retired.append(previous)
            }
        }
        return (active, retired)
    }

    static func displayUUIDsWithChangedAssets(
        assignments: [DisplayAssignment],
        previousAssets: [WallpaperAsset.ID: WallpaperAsset],
        currentAssets: [WallpaperAsset.ID: WallpaperAsset]
    ) -> Set<String> {
        let effectiveAssignments = effectiveAssignments(assignments)
        return Set(effectiveAssignments.compactMap { displayUUID, assignment in
            guard let assetID = assignment.assetID,
                  previousAssets[assetID] != currentAssets[assetID] else {
                return nil
            }
            return displayUUID
        })
    }

    static func requiresRetiringFailedWebSession(
        previous: WallpaperAsset?,
        current: WallpaperAsset?
    ) -> Bool {
        guard let previous, previous.kind == .web else { return false }
        guard let current else { return true }
        return previous.allowsNetworkAccess == true
            && (current.allowsNetworkAccess != true || current.contentHash != previous.contentHash)
    }

    static func requiresRetiringAppliedSession(
        _ session: AppliedSession?,
        currentAssets: [WallpaperAsset.ID: WallpaperAsset]
    ) -> Bool {
        guard let session else { return false }
        guard let current = currentAssets[session.asset.id],
              current.supportStatus == .playable,
              current.entrypoint != nil,
              current.kind == session.asset.kind,
              current.entrypoint == session.asset.entrypoint,
              current.contentHash == session.asset.contentHash else {
            return true
        }
        return requiresRetiringFailedWebSession(
            previous: session.asset,
            current: current
        )
    }

    static func shouldRestoreSingleWallpaperAfterReplacement(
        assetID: WallpaperAsset.ID,
        activeAssetID: WallpaperAsset.ID?,
        hasDisplayAssignments: Bool
    ) -> Bool {
        !hasDisplayAssignments && activeAssetID == assetID
    }
}

@MainActor
final class WallpaperPlayer {
    static let shared = WallpaperPlayer()

    private var windows: [String: WallpaperWindow] = [:]
    private var activeAsset: WallpaperAsset?
    private var activeDisplayAssignments: [DisplayAssignment] = []
    private var activeAssetsByID: [WallpaperAsset.ID: WallpaperAsset] = [:]
    private var appliedDisplaySessions: [String: AssignedDisplayRefreshPlan.AppliedSession] = [:]
    private var autoPauseWhenCovered = true
    private var displayMode: WallpaperDisplayMode = .fit
    private var audioEnabled = false
    private var audioVolume: Double = 0.5
    private var visibilityTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isSuspended = false
    private var isManuallyPaused = false
    private var lastDisplayTopology: [WallpaperDisplaySnapshot] = []
    private var pendingLibraryReplacementAssetIDs: Set<WallpaperAsset.ID> = []
    private var quiescedAppliedSessionsByAssetID: [
        WallpaperAsset.ID: [String: AssignedDisplayRefreshPlan.AppliedSession]
    ] = [:]
    private var pendingAutoSuspension: DispatchWorkItem?
    private let visibilityMonitor = DesktopVisibilityMonitor()

    func play(
        asset: WallpaperAsset,
        autoPauseWhenCovered: Bool = true,
        displayMode: WallpaperDisplayMode = .fit,
        audioEnabled: Bool? = nil,
        audioVolume: Double? = nil
    ) throws {
        guard !pendingLibraryReplacementAssetIDs.contains(asset.id) else {
            throw PlaybackError.notPlayable("Workshop update in progress")
        }
        closeWindows()
        isManuallyPaused = false
        activeDisplayAssignments = []
        activeAssetsByID = [:]
        activeAsset = asset
        self.autoPauseWhenCovered = autoPauseWhenCovered
        self.displayMode = displayMode
        if let audioEnabled {
            self.audioEnabled = audioEnabled
        }
        if let audioVolume {
            self.audioVolume = audioVolume
        }
        guard asset.supportStatus == .playable else {
            throw PlaybackError.notPlayable(asset.supportStatus.rawValue)
        }
        guard let entrypoint = asset.entrypoint else {
            throw PlaybackError.missingEntrypoint
        }
        let url = URL(filePath: entrypoint)
        let screens = NSScreen.screens
        windows = try screens.enumerated().reduce(into: [String: WallpaperWindow]()) { result, item in
            let (index, screen) = item
            let frame = WallpaperScreenFrames.wallpaperFrame(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
            result[DisplayIdentity.uuid(for: screen)] = try WallpaperWindow(
                asset: asset,
                url: url,
                frame: frame,
                displayMode: displayMode,
                audioEnabled: self.audioEnabled && index == 0,
                audioVolume: self.audioVolume,
                allowsAudio: index == 0,
                quality: .balanced
            )
        }
        appliedDisplaySessions = windows.keys.reduce(
            into: [String: AssignedDisplayRefreshPlan.AppliedSession]()
        ) { sessions, displayUUID in
            sessions[displayUUID] = .init(assignment: nil, asset: asset)
        }
        lastDisplayTopology = WallpaperDisplayTopology.current(screens: screens)
        applyCurrentSuspensionToWindows()
        windows.values.forEach { $0.show() }
        startLifecycleObservers()
        startVisibilityTimer()
        updateVisibilityState()
    }

    func play(
        assignments: [DisplayAssignment],
        assetsByID: [WallpaperAsset.ID: WallpaperAsset],
        autoPauseWhenCovered: Bool,
        globalAudioEnabled: Bool,
        globalAudioVolume: Double
    ) -> [DisplayPlaybackFailure] {
        let previousAppliedSessions = appliedDisplaySessions
        let screens = NSScreen.screens
        let currentTopology = WallpaperDisplayTopology.current(screens: screens)
        let topologyReconciliation = WallpaperDisplayTopology.reconciliation(
            previous: lastDisplayTopology,
            current: currentTopology
        )
        let application = AssignedDisplayRefreshPlan.application(
            appliedSessions: previousAppliedSessions,
            currentAssignments: assignments,
            currentAssets: assetsByID,
            connectedDisplayUUIDs: Set(currentTopology.map(\.id)),
            existingWindowUUIDs: Set(windows.keys),
            topologyChangedDisplayUUIDs: topologyReconciliation.addedOrChangedDisplayUUIDs
        )

        activeDisplayAssignments = assignments
        activeAssetsByID = assetsByID
        let assignmentsByDisplay = AssignedDisplayRefreshPlan.effectiveAssignments(assignments)
        activeAsset = currentTopology.lazy.compactMap { snapshot -> WallpaperAsset? in
            guard let assetID = assignmentsByDisplay[snapshot.id]?.assetID else { return nil }
            return assetsByID[assetID]
        }.first
        self.autoPauseWhenCovered = autoPauseWhenCovered
        audioEnabled = globalAudioEnabled
        audioVolume = globalAudioVolume

        closeWindows(displayUUIDs: application.displayUUIDsToClose)
        let failures = openAssignedWindows(
            displayUUIDs: application.displayUUIDsToReplace,
            replacingExisting: true
        )
        let securityCriticalFailures = Set(failures.compactMap { failure -> String? in
            guard AssignedDisplayRefreshPlan.requiresRetiringAppliedSession(
                previousAppliedSessions[failure.displayUUID],
                currentAssets: assetsByID
            ) else { return nil }
            return failure.displayUUID
        })
        closeWindows(displayUUIDs: securityCriticalFailures)
        applyAssignedAudioSettings(
            assignmentsByDisplay: assignmentsByDisplay,
            primaryDisplayUUID: currentTopology.first(where: \.isPrimary)?.id
        )
        lastDisplayTopology = WallpaperDisplayTopology.snapshotAfterReconciliation(
            previous: lastDisplayTopology,
            current: currentTopology,
            failedDisplayUUIDs: Set(failures.map(\.displayUUID))
        )
        startLifecycleObservers()
        startVisibilityTimer()
        updateVisibilityState()
        return failures
    }

    /// Refreshes the immutable asset snapshots held by active wallpaper
    /// sessions after a library mutation. This is required for Workshop
    /// updates and Web permission changes: keeping the old snapshot can
    /// reopen a deleted conversion cache after wake or leave a Web process
    /// running with network access that the user just revoked.
    func reconcileLibraryAssets(_ assets: [WallpaperAsset]) {
        let currentAssets = assets.reduce(into: [WallpaperAsset.ID: WallpaperAsset]()) {
            $0[$1.id] = $1
        }
        if !activeDisplayAssignments.isEmpty {
            let previousAppliedSessions = appliedDisplaySessions
            let currentTopology = WallpaperDisplayTopology.current()
            let application = AssignedDisplayRefreshPlan.application(
                appliedSessions: previousAppliedSessions,
                currentAssignments: activeDisplayAssignments,
                currentAssets: currentAssets,
                connectedDisplayUUIDs: Set(currentTopology.map(\.id)),
                existingWindowUUIDs: Set(windows.keys)
            )
            let blockedDisplays = pendingLibraryReplacementAssetIDs.reduce(into: Set<String>()) {
                displays, assetID in
                displays.formUnion(AssignedDisplayRefreshPlan.displayUUIDs(
                    for: assetID,
                    assignments: activeDisplayAssignments
                ))
            }
            activeAsset = activeDisplayAssignments.compactMap(\.assetID).compactMap {
                currentAssets[$0]
            }.first
            let effectiveAssignments = AssignedDisplayRefreshPlan.effectiveAssignments(
                activeDisplayAssignments
            )
            activeAssetsByID = currentAssets
            closeWindows(displayUUIDs: blockedDisplays.union(application.displayUUIDsToClose))
            let refreshableDisplays = application.displayUUIDsToReplace.subtracting(blockedDisplays)
            guard !refreshableDisplays.isEmpty else { return }

            let failures = openAssignedWindows(
                displayUUIDs: refreshableDisplays,
                replacingExisting: true
            )
            let securityCriticalFailures = Set<String>(failures.compactMap { failure -> String? in
                guard AssignedDisplayRefreshPlan.requiresRetiringAppliedSession(
                    previousAppliedSessions[failure.displayUUID],
                    currentAssets: currentAssets
                ) else { return nil }
                return failure.displayUUID
            })
            closeWindows(displayUUIDs: securityCriticalFailures)
            applyAssignedAudioSettings(
                assignmentsByDisplay: effectiveAssignments,
                primaryDisplayUUID: currentTopology.first(where: \.isPrimary)?.id
            )
            updateVisibilityState()
            return
        }

        guard let previous = activeAsset else { return }
        activeAssetsByID = currentAssets
        if pendingLibraryReplacementAssetIDs.contains(previous.id) {
            activeAsset = currentAssets[previous.id]
            closeWindows()
            return
        }
        guard let current = currentAssets[previous.id] else {
            activeAsset = nil
            closeWindows()
            return
        }
        guard current != previous else { return }
        activeAsset = current
        guard current.supportStatus == .playable, current.entrypoint != nil else {
            closeWindows()
            return
        }
        let displayUUIDs = Set(NSScreen.screens.map { DisplayIdentity.uuid(for: $0) })
        let failures = openSingleWallpaperWindows(
            asset: current,
            displayUUIDs: displayUUIDs,
            replacingExisting: true
        )
        if AssignedDisplayRefreshPlan.requiresRetiringFailedWebSession(
            previous: previous,
            current: current
        ) {
            closeWindows(displayUUIDs: Set(failures.map(\.displayUUID)))
        }
        updateVisibilityState()
    }

    /// Stops only sessions that could observe a Workshop directory while it
    /// is atomically replaced. The active assignment/snapshot is retained so
    /// the next manifest reconciliation either opens the new revision or
    /// restores the previous one when staging is cancelled or fails.
    func prepareForLibraryAssetReplacement(_ assetID: WallpaperAsset.ID) async {
        pendingLibraryReplacementAssetIDs.insert(assetID)
        let quiescedSessions = appliedDisplaySessions.filter { _, session in
            session.asset.id == assetID
        }
        if !quiescedSessions.isEmpty,
           quiescedAppliedSessionsByAssetID[assetID] == nil {
            quiescedAppliedSessionsByAssetID[assetID] = quiescedSessions
        }
        let affectedDisplayUUIDs = AssignedDisplayRefreshPlan.displayUUIDs(
            applying: assetID,
            sessions: appliedDisplaySessions
        )
        if !affectedDisplayUUIDs.isEmpty {
            closeWindows(displayUUIDs: affectedDisplayUUIDs)
        } else if activeDisplayAssignments.isEmpty, activeAsset?.id == assetID {
            closeWindows()
        }
        // Scene cache jobs may outlive the window that launched them. Always
        // drain this revision before its stable Workshop directory is swapped,
        // even when the wallpaper is no longer assigned to a display.
        await SceneRenderCoordinator.shared.cancel(assetID: assetID)
    }

    /// Releases the quiescence barrier only after AppViewModel has reloaded
    /// the terminal manifest state for this exact Workshop operation.
    func finishLibraryAssetReplacement(_ assetID: WallpaperAsset.ID) {
        guard pendingLibraryReplacementAssetIDs.remove(assetID) != nil else { return }
        let quiescedSessions = quiescedAppliedSessionsByAssetID.removeValue(forKey: assetID) ?? [:]
        if !activeDisplayAssignments.isEmpty {
            let displayUUIDs = AssignedDisplayRefreshPlan.displayUUIDs(
                for: assetID,
                assignments: activeDisplayAssignments
            )
            _ = openAssignedWindows(displayUUIDs: displayUUIDs, replacingExisting: true)
            let fallbackDisplayUUIDs = AssignedDisplayRefreshPlan.fallbackDisplayUUIDs(
                quiescedSessions: quiescedSessions,
                desiredAssignments: activeDisplayAssignments,
                occupiedDisplayUUIDs: Set(windows.keys)
            )
            if let asset = activeAssetsByID[assetID],
               asset.supportStatus == .playable,
               asset.entrypoint != nil {
                _ = restoreQuiescedFallbackSessions(
                    quiescedSessions,
                    with: asset,
                    displayUUIDs: fallbackDisplayUUIDs
                )
            }
            let topology = WallpaperDisplayTopology.current()
            applyAssignedAudioSettings(
                assignmentsByDisplay: AssignedDisplayRefreshPlan.effectiveAssignments(
                    activeDisplayAssignments
                ),
                primaryDisplayUUID: topology.first(where: \.isPrimary)?.id
            )
            updateVisibilityState()
            return
        }
        guard AssignedDisplayRefreshPlan.shouldRestoreSingleWallpaperAfterReplacement(
                  assetID: assetID,
                  activeAssetID: activeAsset?.id,
                  hasDisplayAssignments: !activeDisplayAssignments.isEmpty
              ),
              let asset = activeAssetsByID[assetID] ?? activeAsset,
              asset.supportStatus == .playable,
              asset.entrypoint != nil else {
            return
        }
        activeAsset = asset
        _ = openSingleWallpaperWindows(
            asset: asset,
            displayUUIDs: Set(NSScreen.screens.map { DisplayIdentity.uuid(for: $0) }),
            replacingExisting: true
        )
        updateVisibilityState()
    }

    /// Applies the wallpaper audio (mute/volume) settings immediately to the
    /// currently playing wallpaper, without recreating any windows or
    /// restarting playback. Also remembered for windows created afterwards
    /// (new plays, auto-reopen after wake/screen changes).
    func setAudioSettings(enabled: Bool, volume: Double) {
        audioEnabled = enabled
        audioVolume = volume
        if !activeDisplayAssignments.isEmpty {
            let topology = WallpaperDisplayTopology.current()
            applyAssignedAudioSettings(
                assignmentsByDisplay: AssignedDisplayRefreshPlan.effectiveAssignments(
                    activeDisplayAssignments
                ),
                primaryDisplayUUID: topology.first(where: \.isPrimary)?.id
            )
            return
        }
        windows.values.forEach { $0.setAudio(enabled: enabled, volume: volume) }
    }

    func setDisplayMode(_ displayMode: WallpaperDisplayMode) {
        self.displayMode = displayMode
        guard activeDisplayAssignments.isEmpty else { return }
        windows.values.forEach {
            $0.setDisplayMode(displayMode)
        }
    }

    func setAutoPauseWhenCovered(_ enabled: Bool) {
        autoPauseWhenCovered = enabled
        if !enabled {
            cancelPendingAutoSuspension()
            setSuspended(false)
        }
        updateVisibilityState()
    }

    func setPlaybackPaused(_ paused: Bool) {
        isManuallyPaused = paused
        if paused {
            cancelPendingAutoSuspension()
            setSuspended(true)
        } else {
            updateVisibilityState()
        }
    }

    /// Called once a scene->video render finishes so the newly cached video
    /// swaps in for the still-live native scene fallback.
    func refreshIfNeeded(afterSceneVideoRenderFor assetId: String) {
        refreshIfNeeded(for: assetId, expectedKind: .scene)
    }

    func refreshIfNeeded(afterWebPropertyChangeFor assetId: String) {
        refreshIfNeeded(for: assetId, expectedKind: .web)
    }

    private func refreshIfNeeded(for assetId: String, expectedKind: WallpaperKind) {
        guard !pendingLibraryReplacementAssetIDs.contains(assetId) else { return }
        let affectedDisplayUUIDs = AssignedDisplayRefreshPlan.displayUUIDs(
            for: assetId,
            assignments: activeDisplayAssignments
        )
        if !affectedDisplayUUIDs.isEmpty {
            _ = openAssignedWindows(
                displayUUIDs: affectedDisplayUUIDs,
                replacingExisting: true
            )
            updateVisibilityState()
            return
        }
        guard AssignedDisplayRefreshPlan.shouldRefreshSingleWallpaper(
            for: assetId,
            assignments: activeDisplayAssignments,
            activeAssetID: activeAsset?.id,
            activeAssetKind: activeAsset?.kind,
            expectedKind: expectedKind
        ), let activeAsset else {
            return
        }
        try? reopen(asset: activeAsset)
    }

    func restoreVisibleWindowsAfterAppWindowChange() {
        updateVisibilityState()
        guard !isSuspended else {
            return
        }
        reassertWallpaperWindowOrder()
    }

    func stop() {
        Task { await SceneRenderCoordinator.shared.cancelAll() }
        activeAsset = nil
        activeDisplayAssignments = []
        activeAssetsByID = [:]
        quiescedAppliedSessionsByAssetID.removeAll(keepingCapacity: false)
        isManuallyPaused = false
        lastDisplayTopology = []
        cancelPendingAutoSuspension()
        stopVisibilityTimer()
        stopLifecycleObservers()
        closeWindows()
    }

    private func closeWindows() {
        windows.values.forEach { $0.close() }
        windows.removeAll(keepingCapacity: false)
        appliedDisplaySessions.removeAll(keepingCapacity: false)
    }

    private func closeWindows(displayUUIDs: Set<String>) {
        for displayUUID in displayUUIDs {
            windows.removeValue(forKey: displayUUID)?.close()
            appliedDisplaySessions.removeValue(forKey: displayUUID)
        }
    }

    private func reopen(asset: WallpaperAsset) throws {
        let failures = openSingleWallpaperWindows(asset: asset, replacingExisting: true)
        if let failure = failures.first {
            throw PlaybackError.notPlayable(failure.message)
        }
        updateVisibilityState()
    }

    private func openSingleWallpaperWindows(
        asset: WallpaperAsset,
        displayUUIDs requestedDisplayUUIDs: Set<String>? = nil,
        replacingExisting: Bool
    ) -> [DisplayPlaybackFailure] {
        let screens = NSScreen.screens
        guard !pendingLibraryReplacementAssetIDs.contains(asset.id) else {
            return screens.compactMap { screen in
                let displayUUID = DisplayIdentity.uuid(for: screen)
                guard requestedDisplayUUIDs?.contains(displayUUID) ?? true else { return nil }
                return DisplayPlaybackFailure(
                    displayUUID: displayUUID,
                    message: "Workshop update in progress."
                )
            }
        }
        guard let entrypoint = asset.entrypoint else {
            return screens.compactMap { screen in
                let displayUUID = DisplayIdentity.uuid(for: screen)
                guard requestedDisplayUUIDs?.contains(displayUUID) ?? true else { return nil }
                return DisplayPlaybackFailure(displayUUID: displayUUID, message: "Missing entrypoint.")
            }
        }
        let url = URL(filePath: entrypoint)
        var opened: [String: WallpaperWindow] = [:]
        var openedSessions: [String: AssignedDisplayRefreshPlan.AppliedSession] = [:]
        var failures: [DisplayPlaybackFailure] = []
        for (index, screen) in screens.enumerated() {
            let displayUUID = DisplayIdentity.uuid(for: screen)
            guard requestedDisplayUUIDs?.contains(displayUUID) ?? true else { continue }
            do {
                opened[displayUUID] = try WallpaperWindow(
                    asset: asset,
                    url: url,
                    frame: WallpaperScreenFrames.wallpaperFrame(
                        screenFrame: screen.frame,
                        visibleFrame: screen.visibleFrame
                    ),
                    displayMode: displayMode,
                    audioEnabled: audioEnabled && index == 0,
                    audioVolume: audioVolume,
                    allowsAudio: index == 0
                )
                openedSessions[displayUUID] = .init(assignment: nil, asset: asset)
            } catch {
                failures.append(
                    DisplayPlaybackFailure(displayUUID: displayUUID, message: error.localizedDescription)
                )
            }
        }
        if replacingExisting {
            if requestedDisplayUUIDs == nil {
                let connectedDisplayUUIDs = Set(screens.map { DisplayIdentity.uuid(for: $0) })
                closeWindows(displayUUIDs: Set(windows.keys).subtracting(connectedDisplayUUIDs))
            }
            for replacement in opened.values {
                replacement.setSuspended(isSuspended)
                replacement.show()
            }
            let replacementResult = AssignedDisplayRefreshPlan.applyingSuccessfulReplacements(
                opened,
                to: windows
            )
            windows = replacementResult.active
            for (displayUUID, session) in openedSessions {
                appliedDisplaySessions[displayUUID] = session
            }
            replacementResult.retired.forEach { $0.close() }
        } else {
            windows = opened
            appliedDisplaySessions = openedSessions
            applyCurrentSuspensionToWindows()
            opened.values.forEach { $0.show() }
        }
        if AssignedDisplayRefreshPlan.capturesCompleteTopology(
            requestedDisplayUUIDs: requestedDisplayUUIDs
        ) {
            lastDisplayTopology = WallpaperDisplayTopology.current(screens: screens)
        }
        return failures
    }

    private func restoreQuiescedFallbackSessions(
        _ sessions: [String: AssignedDisplayRefreshPlan.AppliedSession],
        with asset: WallpaperAsset,
        displayUUIDs: Set<String>
    ) -> [DisplayPlaybackFailure] {
        guard let entrypoint = asset.entrypoint else {
            return displayUUIDs.map {
                DisplayPlaybackFailure(displayUUID: $0, message: "Missing entrypoint.")
            }
        }

        var opened: [String: WallpaperWindow] = [:]
        var openedSessions: [String: AssignedDisplayRefreshPlan.AppliedSession] = [:]
        var failures: [DisplayPlaybackFailure] = []
        for (index, screen) in NSScreen.screens.enumerated() {
            let displayUUID = DisplayIdentity.uuid(for: screen)
            guard displayUUIDs.contains(displayUUID),
                  let previousSession = sessions[displayUUID] else {
                continue
            }
            let assignment = previousSession.assignment
            let allowsAudio = index == 0
                && (assignment?.audioSource ?? .primaryDisplay) == .primaryDisplay
            do {
                let window = try WallpaperWindow(
                    asset: asset,
                    url: URL(filePath: entrypoint),
                    frame: assignment == nil
                        ? WallpaperScreenFrames.wallpaperFrame(
                            screenFrame: screen.frame,
                            visibleFrame: screen.visibleFrame
                        )
                        : screen.frame,
                    displayMode: assignment?.displayMode ?? displayMode,
                    audioEnabled: false,
                    audioVolume: audioVolume,
                    allowsAudio: allowsAudio,
                    quality: assignment?.quality ?? .balanced
                )
                opened[displayUUID] = window
                openedSessions[displayUUID] = .init(
                    assignment: assignment,
                    asset: asset
                )
            } catch {
                failures.append(
                    DisplayPlaybackFailure(
                        displayUUID: displayUUID,
                        message: error.localizedDescription
                    )
                )
            }
        }

        for fallback in opened.values {
            fallback.setSuspended(isSuspended)
            fallback.show()
        }
        let result = AssignedDisplayRefreshPlan.applyingSuccessfulReplacements(opened, to: windows)
        windows = result.active
        for (displayUUID, session) in openedSessions {
            appliedDisplaySessions[displayUUID] = session
        }
        result.retired.forEach { $0.close() }
        return failures
    }

    private func startVisibilityTimer() {
        stopVisibilityTimer()
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateVisibilityState()
            }
        }
        if let visibilityTimer {
            RunLoop.main.add(visibilityTimer, forMode: .common)
        }
    }

    private func stopVisibilityTimer() {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
    }

    private func updateVisibilityState() {
        if isManuallyPaused || ProcessInfo.processInfo.isLowPowerModeEnabled {
            cancelPendingAutoSuspension()
            setSuspended(true)
        } else if autoPauseWhenCovered && !visibilityMonitor.isDesktopVisible() {
            scheduleAutoSuspension()
        } else {
            cancelPendingAutoSuspension()
            setSuspended(false)
        }
    }

    private func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else {
            return
        }
        isSuspended = suspended
        applyCurrentSuspensionToWindows()
    }

    /// Newly constructed windows must inherit the effective state even when
    /// `isSuspended` itself did not change. This covers display hot-plug,
    /// sleep/wake and Scene-cache refresh while manually paused.
    private func applyCurrentSuspensionToWindows() {
        windows.values.forEach { $0.setSuspended(isSuspended) }
    }

    private func scheduleAutoSuspension() {
        guard pendingAutoSuspension == nil, !isSuspended else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.autoPauseWhenCovered, !self.visibilityMonitor.isDesktopVisible() else {
                    return
                }
                self.pendingAutoSuspension = nil
                self.setSuspended(true)
            }
        }
        pendingAutoSuspension = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func cancelPendingAutoSuspension() {
        pendingAutoSuspension?.cancel()
        pendingAutoSuspension = nil
    }

    private func startLifecycleObservers() {
        guard workspaceObservers.isEmpty else {
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setSuspended(true)
                    await SceneRenderCoordinator.shared.cancelAll()
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reopenAfterWake() }
            },
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleWallpaperWindowOrderReassertion() }
            },
            center.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleWallpaperWindowOrderReassertion() }
            },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reopenAfterScreenFrameChange() }
            },
            NotificationCenter.default.addObserver(
                forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.updateVisibilityState() }
            }
        ]
    }

    private func stopLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { observer in
            center.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        workspaceObservers = []
    }

    private func reopenAfterWake() {
        let screens = NSScreen.screens
        let currentTopology = WallpaperDisplayTopology.current(screens: screens)
        let currentDisplayUUIDs = Set(currentTopology.map(\.id))
        closeWindows(displayUUIDs: Set(windows.keys).subtracting(currentDisplayUUIDs))
        let failures: [DisplayPlaybackFailure]
        if !activeDisplayAssignments.isEmpty {
            failures = openAssignedWindows(
                displayUUIDs: currentDisplayUUIDs,
                replacingExisting: true
            )
        } else if let activeAsset {
            failures = openSingleWallpaperWindows(
                asset: activeAsset,
                displayUUIDs: currentDisplayUUIDs,
                replacingExisting: true
            )
        } else {
            return
        }
        lastDisplayTopology = WallpaperDisplayTopology.snapshotAfterReconciliation(
            previous: lastDisplayTopology,
            current: currentTopology,
            failedDisplayUUIDs: Set(failures.map(\.displayUUID))
        )
        updateVisibilityState()
    }

    private func openAssignedWindows(
        displayUUIDs requestedDisplayUUIDs: Set<String>? = nil,
        replacingExisting: Bool = false
    ) -> [DisplayPlaybackFailure] {
        let screens = NSScreen.screens
        let assignmentsByDisplay = AssignedDisplayRefreshPlan.effectiveAssignments(
            activeDisplayAssignments
        )
        var opened: [String: WallpaperWindow] = [:]
        var openedSessions: [String: AssignedDisplayRefreshPlan.AppliedSession] = [:]
        var failures: [DisplayPlaybackFailure] = []

        for (index, screen) in screens.enumerated() {
            let displayUUID = DisplayIdentity.uuid(for: screen)
            guard requestedDisplayUUIDs?.contains(displayUUID) ?? true else {
                continue
            }
            guard let assignment = assignmentsByDisplay[displayUUID],
                  let assetID = assignment.assetID else {
                continue
            }
            guard let asset = activeAssetsByID[assetID] else {
                failures.append(DisplayPlaybackFailure(
                    displayUUID: displayUUID,
                    message: "The assigned wallpaper is no longer in the library."
                ))
                continue
            }
            guard !pendingLibraryReplacementAssetIDs.contains(assetID) else {
                failures.append(DisplayPlaybackFailure(
                    displayUUID: displayUUID,
                    message: "Workshop update in progress."
                ))
                continue
            }
            guard asset.supportStatus == .playable else {
                failures.append(
                    DisplayPlaybackFailure(
                        displayUUID: displayUUID,
                        message: "\(asset.title) is \(asset.supportStatus.rawValue)."
                    )
                )
                continue
            }
            guard let entrypoint = asset.entrypoint else {
                failures.append(DisplayPlaybackFailure(displayUUID: displayUUID, message: "Missing entrypoint."))
                continue
            }
            do {
                let window = try WallpaperWindow(
                    asset: asset,
                    url: URL(filePath: entrypoint),
                    frame: screen.frame,
                    displayMode: assignment.displayMode,
                    audioEnabled: globalAudioForAssignment(assignment, isPrimaryDisplay: index == 0),
                    audioVolume: audioVolume,
                    allowsAudio: index == 0 && assignment.audioSource == .primaryDisplay,
                    quality: assignment.quality
                )
                opened[displayUUID] = window
                openedSessions[displayUUID] = AssignedDisplayRefreshPlan.AppliedSession(
                    assignment: assignment,
                    asset: asset
                )
            } catch {
                failures.append(
                    DisplayPlaybackFailure(displayUUID: displayUUID, message: error.localizedDescription)
                )
            }
        }
        if replacingExisting {
            for replacement in opened.values {
                replacement.setSuspended(isSuspended)
                replacement.show()
            }
            let replacementResult = AssignedDisplayRefreshPlan.applyingSuccessfulReplacements(
                opened,
                to: windows
            )
            windows = replacementResult.active
            for (displayUUID, session) in openedSessions {
                appliedDisplaySessions[displayUUID] = session
            }
            replacementResult.retired.forEach { $0.close() }
        } else {
            windows = opened
            appliedDisplaySessions = openedSessions
            applyCurrentSuspensionToWindows()
            opened.values.forEach { $0.show() }
        }
        if AssignedDisplayRefreshPlan.capturesCompleteTopology(
            requestedDisplayUUIDs: requestedDisplayUUIDs
        ) {
            lastDisplayTopology = WallpaperDisplayTopology.current(screens: screens)
        }
        return failures
    }

    private func globalAudioForAssignment(_ assignment: DisplayAssignment, isPrimaryDisplay: Bool) -> Bool {
        audioEnabled && isPrimaryDisplay && assignment.audioSource == .primaryDisplay
    }

    private func applyAssignedAudioSettings(
        assignmentsByDisplay: [String: DisplayAssignment],
        primaryDisplayUUID: String?
    ) {
        for (displayUUID, window) in windows {
            let assignment = assignmentsByDisplay[displayUUID]
            let enabled = audioEnabled
                && displayUUID == primaryDisplayUUID
                && assignment?.audioSource == .primaryDisplay
            window.setAudio(enabled: enabled, volume: audioVolume)
        }
    }

    private func reopenAfterScreenFrameChange() {
        guard activeAsset != nil || !activeDisplayAssignments.isEmpty else {
            return
        }
        let currentTopology = WallpaperDisplayTopology.current()
        let reconciliation = WallpaperDisplayTopology.reconciliation(
            previous: lastDisplayTopology,
            current: currentTopology
        )
        guard reconciliation.requiresChanges else {
            reassertWallpaperWindowOrder()
            return
        }
        closeWindows(displayUUIDs: reconciliation.removedDisplayUUIDs)
        let failures: [DisplayPlaybackFailure]
        if !activeDisplayAssignments.isEmpty {
            failures = openAssignedWindows(
                displayUUIDs: reconciliation.addedOrChangedDisplayUUIDs,
                replacingExisting: true
            )
        } else if let activeAsset {
            failures = openSingleWallpaperWindows(
                asset: activeAsset,
                displayUUIDs: reconciliation.addedOrChangedDisplayUUIDs,
                replacingExisting: true
            )
        } else {
            return
        }
        lastDisplayTopology = WallpaperDisplayTopology.snapshotAfterReconciliation(
            previous: lastDisplayTopology,
            current: currentTopology,
            failedDisplayUUIDs: Set(failures.map(\.displayUUID))
        )
        updateVisibilityState()
    }

    private func reassertWallpaperWindowOrder() {
        windows.values.forEach { $0.reassertDesktopOrder() }
    }

    private func scheduleWallpaperWindowOrderReassertion() {
        wakeWallpaperForAppTransition()
        reassertWallpaperWindowOrder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            Task { @MainActor in
                self?.updateVisibilityState()
                self?.reassertWallpaperWindowOrder()
            }
        }
    }

    private func wakeWallpaperForAppTransition() {
        guard autoPauseWhenCovered else {
            return
        }
        cancelPendingAutoSuspension()
        setSuspended(false)
        updateVisibilityState()
    }
}

enum WallpaperScreenFrames {
    static func wallpaperFrames(for screens: [NSScreen]) -> [CGRect] {
        screens.map { wallpaperFrame(screenFrame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    static func wallpaperFrame(screenFrame: CGRect, visibleFrame _: CGRect) -> CGRect {
        screenFrame
    }

    static func shouldReopenWindows(previous: [CGRect], current: [CGRect]) -> Bool {
        normalized(previous) != normalized(current)
    }

    private static func normalized(_ frames: [CGRect]) -> [CGRect] {
        frames.sorted { lhs, rhs in
            if lhs.minX != rhs.minX {
                return lhs.minX < rhs.minX
            }
            if lhs.minY != rhs.minY {
                return lhs.minY < rhs.minY
            }
            if lhs.width != rhs.width {
                return lhs.width < rhs.width
            }
            return lhs.height < rhs.height
        }
    }
}

@MainActor
private final class WallpaperWindow {
    private let window: NSWindow
    private let content: NSView
    private let allowsAudio: Bool

    init(asset: WallpaperAsset,
        url: URL,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool = false,
        audioVolume: Double = 0.5,
        allowsAudio: Bool = true,
        quality: RenderQuality = .balanced
    ) throws {
        self.allowsAudio = allowsAudio
        content = try Self.makeContentView(
            asset: asset,
            url: url,
            frame: frame,
            displayMode: displayMode,
            audioEnabled: audioEnabled,
            audioVolume: audioVolume,
            quality: quality
        )
        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = WallpaperWindowLevel.desktopWallpaper
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.isExcludedFromWindowsMenu = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = content
    }

    func show() {
        guard !window.isVisible else {
            return
        }
        window.orderFrontRegardless()
    }

    func reassertDesktopOrder() {
        window.orderFrontRegardless()
    }

    func close() {
        (content as? WallpaperContentLifecycle)?.prepareForClose()
        window.contentView = nil
        window.close()
    }

    func setSuspended(_ suspended: Bool) {
        (content as? PausableWallpaperContent)?.setPlaybackSuspended(suspended)
    }

    func setDisplayMode(_ displayMode: WallpaperDisplayMode) {
        (content as? DisplayModeUpdatableContent)?.setDisplayMode(displayMode)
    }

    func setAudio(enabled: Bool, volume: Double) {
        (content as? AudioControllableWallpaperContent)?.setAudioEnabled(
            enabled && allowsAudio,
            volume: volume
        )
    }

    private static func makeContentView(
        asset: WallpaperAsset,
        url: URL,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool = false,
        audioVolume: Double = 0.5,
        quality: RenderQuality = .balanced
    ) throws -> NSView {
        let contentFrame = WallpaperContentLayout.contentFrame(for: frame)
        switch asset.kind {
        case .video:
            let fallbackImageURL = try? StillWallpaperImageProvider().stillImageURL(for: asset)
            return VideoWallpaperView(
                url: url,
                fallbackImageURL: fallbackImageURL,
                frame: contentFrame,
                displayMode: displayMode,
                audioEnabled: audioEnabled,
                audioVolume: audioVolume
            )
        case .web:
            return RestrictedWebWallpaperView(
                url: url,
                readAccessURL: URL(filePath: asset.projectDirectory),
                frame: contentFrame,
                networkAccessAllowed: asset.allowsNetworkAccess == true
            )
        case .image:
            return try AnimatedImageWallpaperView(url: url, frame: contentFrame, displayMode: displayMode)
        case .scene:
            let previewURL = asset.thumbnail.map { URL(filePath: $0) }
            return try SceneWallpaperContentFactory.makeSceneContentView(
                asset: asset,
                url: url,
                previewURL: previewURL,
                frame: contentFrame,
                displayMode: displayMode,
                audioEnabled: audioEnabled,
                audioVolume: audioVolume,
                quality: quality
            )
        case .application, .unknown:
            throw PlaybackError.notPlayable(asset.kind.rawValue)
        }
    }
}

@MainActor
enum SceneWallpaperContentFactory {
    static var lastDiagnostic: String?
    static var statusHandler: ((String) -> Void)?
    static var compatibilityReportHandler: ((WallpaperAsset, CompatibilityReport) -> Void)?
    private static var forcedCachedAssetRevisions: Set<String> = []
    /// Invoked with the asset id once a scene's video render finishes
    /// (successfully), after `WallpaperPlayer` has already swapped the
    /// desktop wallpaper over to the freshly cached video. Lets callers also
    /// refresh anything else derived from "does this scene have a cached
    /// video yet" (the lock screen animation configuration) without this
    /// factory needing to know about that dependency directly.
    static var sceneVideoRenderCompletionHandler: ((String) -> Void)?

    static func makeSceneContentView(
        asset: WallpaperAsset,
        url: URL,
        previewURL: URL? = nil,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool = false,
        audioVolume: Double = 0.5,
        quality: RenderQuality = .balanced
    ) throws -> NSView {
        lastDiagnostic = nil
        guard SceneEngineRendererConfiguration.isScenePackage(url, inside: asset.projectDirectory) else {
            return try SceneWallpaperView(
                url: url,
                previewURL: previewURL,
                frame: frame,
                displayMode: displayMode
            )
        }
        let sceneCanvas = try? SceneRenderPlanBuilder().canvasSize(url: url)
        let recordSize = SceneVideoRecordSize.clampedRecordSize(
            forSceneCanvas: sceneCanvas.map { CGSize(width: $0.width, height: $0.height) },
            displayLogicalSize: frame.size,
            maxLongEdge: quality.maximumSceneLongEdge
        )
        let engineAssetsFingerprint = SceneEngineRendererConfiguration.assetsDirectoryURL().flatMap {
            RuntimeFingerprint.engineAssets(
                at: $0,
                requiredPaths: SceneEngineRendererConfiguration.requiredAssetPaths
            )
        } ?? "unavailable"
        let cacheKey = asset.contentHash.map {
            SceneVideoCacheKey(
                assetID: asset.id,
                contentHash: $0,
                rendererVersion: SceneVideoCache.rendererVersion,
                mediaBuildID: MediaToolResolver.pinnedBuildID,
                engineAssetsFingerprint: engineAssetsFingerprint,
                width: Int(recordSize.width),
                height: Int(recordSize.height),
                quality: quality
            )
        }
        let lowQualityCacheKey = asset.contentHash.map {
            let lowSize = SceneVideoRecordSize.clampedRecordSize(
                forLogicalSize: recordSize,
                maxLongEdge: RenderQuality.low.maximumSceneLongEdge
            )
            return SceneVideoCacheKey(
                assetID: asset.id,
                contentHash: $0,
                rendererVersion: SceneVideoCache.rendererVersion,
                mediaBuildID: MediaToolResolver.pinnedBuildID,
                engineAssetsFingerprint: engineAssetsFingerprint,
                width: Int(lowSize.width),
                height: Int(lowSize.height),
                quality: .low
            )
        }
        let cachedVideoURL = SceneVideoCache.freshPlaybackCacheURL(
            preferredKeys: [cacheKey, lowQualityCacheKey].compactMap { $0 },
            assetID: asset.id,
            contentHash: asset.contentHash,
            sourceURL: url
        )
        let rendererURL = SceneEngineRendererConfiguration.executableURL()
        let assetsDirectory = SceneEngineRendererConfiguration.assetsDirectoryURL()
        let ffmpegPath = VideoConverter().ffmpegPath()
        let resources = ScenePlaybackResources(
            cachedVideoURL: cachedVideoURL,
            hasExternalRenderer: rendererURL != nil,
            hasEngineAssets: assetsDirectory != nil,
            hasMediaTools: ffmpegPath != nil
        )
        let prefersValidatedNative: Bool
        if case .live = asset.compatibility {
            prefersValidatedNative = true
        } else {
            prefersValidatedNative = false
        }
        let strategy = ScenePlaybackStrategyResolver().resolve(
            prefersValidatedNative: prefersValidatedNative,
            forcesCachedPlayback: forcedCachedAssetRevisions.contains(revisionKey(for: asset)),
            resources: resources
        )

        switch strategy {
        case .validatedNative:
            let nativePlanTask = fallbackNativePlanTask(asset: asset, url: url)
            let view = PreparingSceneWallpaperView(
                sceneURL: url,
                previewURL: previewURL,
                frame: frame,
                displayMode: displayMode,
                nativePlanTask: nativePlanTask,
                readinessHandler: { ready in
                    guard !ready else { return }
                    recoverFailedNativeScene(
                        asset: asset,
                        sceneURL: url,
                        previewURL: previewURL,
                        cachedVideoURL: cachedVideoURL,
                        rendererURL: rendererURL,
                        assetsDirectory: assetsDirectory,
                        ffmpegPath: ffmpegPath,
                        recordSize: recordSize,
                        quality: quality,
                        nativeFallbackPlan: nativePlanTask
                    )
                }
            )
            return view

        case .cachedVideo(let cachedVideoURL):
            return cachedSceneView(
                sceneURL: url,
                cachedVideoURL: cachedVideoURL,
                previewURL: previewURL,
                frame: frame,
                displayMode: displayMode,
                audioEnabled: audioEnabled,
                audioVolume: audioVolume
            )

        case .renderCache:
            guard let rendererURL, let assetsDirectory, let ffmpegPath else {
                preconditionFailure("Scene playback resolver returned renderCache without a complete runtime.")
            }
            let fallback = fallbackSceneView(
                asset: asset,
                url: url,
                previewURL: previewURL,
                frame: frame,
                displayMode: displayMode
            )
            scheduleSceneVideoRender(
                asset: asset,
                sceneURL: url,
                rendererURL: rendererURL,
                assetsDirectory: assetsDirectory,
                ffmpegPath: ffmpegPath,
                recordSize: recordSize,
                quality: quality,
                nativeFallbackPlan: fallback.nativePlanTask
            )
            lastDiagnostic = "scene video rendering in progress"
            statusHandler?("Reconstructing Scene cache… 0%")
            return fallback.view

        case .nativeApproximation(let reason):
            lastDiagnostic = reason
            let fallback = fallbackSceneView(
                asset: asset,
                url: url,
                previewURL: previewURL,
                frame: frame,
                displayMode: displayMode,
                readinessHandler: { ready in
                    compatibilityReportHandler?(
                        asset,
                        ready
                            ? limitedNativeReport(for: asset, warning: reason)
                            : unsupportedReport(
                                for: asset,
                                warning: reason,
                                diagnosticCode: "scene_no_playback_renderer"
                            )
                    )
                }
            )
            return fallback.view
        }
    }

    private struct SceneFallback {
        let view: NSView
        let nativePlanTask: Task<SceneRenderPlan?, Never>
    }

    private static func fallbackNativePlanTask(
        asset: WallpaperAsset,
        url: URL
    ) -> Task<SceneRenderPlan?, Never> {
        let probeKey = SceneNativeReadinessCoordinator.cacheKey(
            contentHash: asset.contentHash,
            url: url
        )
        return Task<SceneRenderPlan?, Never> {
            await SceneNativeReadinessCoordinator.shared.renderablePlan(
                for: url,
                cacheKey: probeKey
            )
        }
    }

    private static func fallbackSceneView(
        asset: WallpaperAsset,
        url: URL,
        previewURL: URL?,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        readinessHandler: @escaping (Bool) -> Void = { _ in }
    ) -> SceneFallback {
        let nativePlanTask = fallbackNativePlanTask(asset: asset, url: url)
        let view = PreparingSceneWallpaperView(
            sceneURL: url,
            previewURL: previewURL,
            frame: frame,
            displayMode: displayMode,
            nativePlanTask: nativePlanTask,
            readinessHandler: readinessHandler
        )
        return SceneFallback(view: view, nativePlanTask: nativePlanTask)
    }

    private static func cachedSceneView(
        sceneURL: URL,
        cachedVideoURL: URL,
        previewURL: URL?,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool,
        audioVolume: Double
    ) -> NSView {
        if CachedSceneWallpaperView.hasClockOverlay(sceneURL: sceneURL),
           let cachedScene = try? CachedSceneWallpaperView(
            sceneURL: sceneURL,
            videoURL: cachedVideoURL,
            fallbackImageURL: previewURL,
            frame: frame,
            displayMode: displayMode,
            audioEnabled: audioEnabled,
            audioVolume: audioVolume
        ) {
            return cachedScene
        }
        return VideoWallpaperView(
            url: cachedVideoURL,
            fallbackImageURL: previewURL,
            frame: frame,
            displayMode: displayMode,
            audioEnabled: audioEnabled,
            audioVolume: audioVolume
        )
    }

    private static func recoverFailedNativeScene(
        asset: WallpaperAsset,
        sceneURL: URL,
        previewURL _: URL?,
        cachedVideoURL: URL?,
        rendererURL: URL?,
        assetsDirectory: URL?,
        ffmpegPath: String?,
        recordSize: CGSize,
        quality: RenderQuality,
        nativeFallbackPlan: Task<SceneRenderPlan?, Never>
    ) {
        let warning = "Native Scene reconstruction failed; using a rendered fallback."
        lastDiagnostic = warning
        if cachedVideoURL != nil {
            forcedCachedAssetRevisions.insert(revisionKey(for: asset))
            compatibilityReportHandler?(asset, cachedReport(for: asset, sceneURL: sceneURL, warning: warning))
            WallpaperPlayer.shared.refreshIfNeeded(afterSceneVideoRenderFor: asset.id)
            return
        }
        guard let rendererURL, let assetsDirectory, let ffmpegPath else {
            let reason = "\(warning) Scene cache unavailable: \(missingRenderingComponentDescription())."
            lastDiagnostic = reason
            compatibilityReportHandler?(
                asset,
                unsupportedReport(
                    for: asset,
                    warning: reason,
                    diagnosticCode: "scene_no_playback_renderer"
                )
            )
            statusHandler?("Scene reconstruction failed.")
            return
        }
        statusHandler?("Reconstructing Scene cache… 0%")
        scheduleSceneVideoRender(
            asset: asset,
            sceneURL: sceneURL,
            rendererURL: rendererURL,
            assetsDirectory: assetsDirectory,
            ffmpegPath: ffmpegPath,
            recordSize: recordSize,
            quality: quality,
            nativeFallbackPlan: nativeFallbackPlan
        )
    }

    private static func cachedReport(
        for asset: WallpaperAsset,
        sceneURL: URL,
        warning: String? = nil
    ) -> CompatibilityReport {
        let analyzed = WallpaperCompatibilityAnalyzer().analyze(
            kind: .scene,
            status: .playable,
            entrypoint: sceneURL
        )
        return CompatibilityReport(
            level: analyzed.level,
            playbackPath: .renderedSceneCache,
            requiredCapabilities: analyzed.requiredCapabilities,
            missingCapabilities: analyzed.missingCapabilities,
            warnings: analyzed.warnings + (warning.map { [$0] } ?? []),
            diagnosticCode: analyzed.diagnosticCode
        )
    }

    private static func missingRenderingComponentDescription() -> String {
        var missing: [String] = []
        if SceneEngineRendererConfiguration.executableURL() == nil {
            missing.append("scene renderer binary")
        }
        if SceneEngineRendererConfiguration.assetsDirectoryURL() == nil {
            missing.append("Wallpaper Engine assets folder")
        }
        if VideoConverter().ffmpegPath() == nil {
            missing.append("ffmpeg")
        }
        return missing.isEmpty ? "unknown reason" : missing.joined(separator: ", ")
    }

    private static func limitedNativeReport(
        for asset: WallpaperAsset,
        warning: String,
        diagnosticCode: String = "scene_native_approximation"
    ) -> CompatibilityReport {
        let required = asset.compatibilityReport?.requiredCapabilities ?? []
        let exactNative: Set<WallpaperCapability> = [.clock]
        let missing = Set(required).subtracting(exactNative)
            .union(asset.compatibilityReport?.missingCapabilities ?? [])
            .sorted()
        return CompatibilityReport(
            level: .limited,
            playbackPath: .nativeScene,
            requiredCapabilities: required,
            missingCapabilities: missing,
            warnings: [warning],
            diagnosticCode: diagnosticCode
        )
    }

    private static func unsupportedReport(
        for asset: WallpaperAsset,
        warning: String,
        diagnosticCode: String
    ) -> CompatibilityReport {
        let required = asset.compatibilityReport?.requiredCapabilities ?? []
        return CompatibilityReport(
            level: .unsupported,
            playbackPath: nil,
            requiredCapabilities: required,
            missingCapabilities: required,
            warnings: [warning],
            diagnosticCode: diagnosticCode
        )
    }

    private static func statusView(frame: CGRect, message: String) -> NSView {
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7)
        ])
        return view
    }

    private static func scheduleSceneVideoRender(
        asset: WallpaperAsset,
        sceneURL: URL,
        rendererURL: URL,
        assetsDirectory: URL,
        ffmpegPath: String,
        recordSize: CGSize,
        quality: RenderQuality,
        nativeFallbackPlan: Task<SceneRenderPlan?, Never>
    ) {
        // Record at a clamped size derived from the display's logical
        // (point) size, not its physical/backing pixel size: recording at
        // full retina resolution produces multi-hundred-megabyte clips that
        // take minutes to render for no visible benefit on a wallpaper
        // viewed from normal desktop distance.
        let configuration = SceneVideoRenderConfiguration(
            assetId: asset.id,
            projectDirectory: URL(filePath: asset.projectDirectory).standardizedFileURL,
            assetsDirectory: assetsDirectory,
            rendererURL: rendererURL,
            size: recordSize,
            sceneURL: sceneURL,
            contentHash: asset.contentHash,
            quality: quality,
            mediaBuildID: MediaToolResolver.pinnedBuildID,
            engineAssetsFingerprint: RuntimeFingerprint.engineAssets(
                at: assetsDirectory,
                requiredPaths: SceneEngineRendererConfiguration.requiredAssetPaths
            ) ?? "unavailable"
        )
        let assetId = asset.id
        Task {
            do {
                _ = try await SceneRenderCoordinator.shared.render(
                    configuration: configuration,
                    ffmpegPath: ffmpegPath,
                    progressHandler: { progress in
                        let percent = Int((progress * 100).rounded())
                        Task { @MainActor in
                            statusHandler?("Reconstructing Scene cache… \(percent)%")
                        }
                    }
                )
                statusHandler?("Playing")
                forcedCachedAssetRevisions.insert(revisionKey(for: asset))
                compatibilityReportHandler?(asset, cachedReport(for: asset, sceneURL: sceneURL))
                WallpaperPlayer.shared.refreshIfNeeded(afterSceneVideoRenderFor: assetId)
                sceneVideoRenderCompletionHandler?(assetId)
            } catch {
                if let coordinatorError = error as? SceneRenderCoordinatorError,
                   coordinatorError == .cancelled {
                    lastDiagnostic = coordinatorError.localizedDescription
                    statusHandler?("Scene video render cancelled.")
                    return
                }
                lastDiagnostic = "scene video render failed: \(error.localizedDescription)"
                let diagnosticCode = (error as? SceneRenderCoordinatorError)?.diagnosticCode
                    ?? "scene_cache_render_failed"
                let nativeFallbackAvailable = await nativeFallbackPlan.value != nil
                compatibilityReportHandler?(
                    asset,
                    nativeFallbackAvailable
                        ? limitedNativeReport(
                            for: asset,
                            warning: "Scene cache rendering failed; using the native approximation.",
                            diagnosticCode: diagnosticCode
                        )
                        : unsupportedReport(
                            for: asset,
                            warning: "Scene cache rendering failed and no native animation path is available.",
                            diagnosticCode: diagnosticCode
                        )
                )
                statusHandler?("Scene video render failed: \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func revisionKey(for asset: WallpaperAsset) -> String {
        asset.id + "\u{0}" + (asset.contentHash ?? asset.entrypoint ?? "unversioned")
    }
}

private extension RenderQuality {
    var maximumSceneLongEdge: CGFloat {
        switch self {
        case .low: 1_280
        case .balanced: 1_920
        case .high: 2_560
        }
    }
}

@MainActor
enum SceneEngineRendererConfiguration {
    static let environmentVariableName = "BACKGROUND_ENGINE_SCENE_RENDERER"
    static let assetsEnvironmentVariableName = "BACKGROUND_ENGINE_SCENE_ASSETS_DIR"
    static var overrideExecutablePath: String?
    static var overrideAssetsPath: String?
    static var overrideResourceURL: URL?
    static var overrideDefaultAssetsDirectoryURL: URL?

    nonisolated static let requiredAssetPaths = [
        "models/util/composelayer.json",
        "materials/util/composelayer.json",
        "materials/util/effectpassthrough.json",
        "materials/util/downsample_quarter_bloom.json",
        "materials/util/downsample_eighth_blur_v.json",
        "materials/util/blur_h_bloom.json",
        "materials/util/combine.json",
        "shaders/genericimage2.frag",
        "shaders/genericimage2.vert",
        "shaders/common_blur.h",
        "shaders/genericparticle.vert",
        "shaders/genericparticle.frag"
    ]

    static func executableURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        #if DEBUG
        if let path = overrideExecutablePath ?? environment[environmentVariableName],
           !path.isEmpty {
            let url = URL(filePath: path).standardizedFileURL
            if isRegularExecutable(url) {
                return url
            }
        }
        #endif
        guard let bundledURL = (overrideResourceURL ?? Bundle.main.resourceURL)?
            .appending(path: "Renderers")
            .appending(path: "background-engine-scene-renderer")
            .standardizedFileURL,
            isRegularExecutable(bundledURL) else {
                return nil
        }
        return bundledURL
    }

    static func assetsDirectoryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let path = environment[assetsEnvironmentVariableName] ?? overrideAssetsPath,
           !path.isEmpty {
            let url = URL(filePath: path).standardizedFileURL
            return isValidAssetsDirectory(url) ? url : nil
        }
        guard let url = defaultAssetsDirectoryURL() else {
            return nil
        }
        return isValidAssetsDirectory(url) ? url : nil
    }

    static func isScenePackage(_ url: URL, inside projectDirectory: String) -> Bool {
        let project = URL(filePath: projectDirectory).standardizedFileURL.resolvingSymlinksInPath()
        let scene = url.standardizedFileURL.resolvingSymlinksInPath()
        let projectComponents = project.pathComponents
        let sceneComponents = scene.pathComponents
        guard sceneComponents.count > projectComponents.count else {
            return false
        }
        guard Array(sceneComponents.prefix(projectComponents.count)) == projectComponents else {
            return false
        }
        if url.pathExtension.lowercased() == "pkg" {
            return true
        }
        // Folder and Workshop imports are content-probed, so a valid PKGV
        // package may retain a missing or non-standard extension. Keep it on
        // the external-render/cache path instead of silently downgrading it to
        // native-only playback. Standalone imports are canonicalized earlier.
        return ScenePackageReader().hasPackageHeader(url: url)
    }

    static func defaultAssetsDirectoryURL() -> URL? {
        if let overrideDefaultAssetsDirectoryURL {
            return overrideDefaultAssetsDirectoryURL.standardizedFileURL
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Background Engine")
            .appending(path: "wallpaper-engine-assets")
            .standardizedFileURL
    }

    static func isValidAssetsDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            return false
        }
        return requiredAssetPaths.allSatisfy { relativePath in
            hasRegularFile(url.appending(path: relativePath))
        }
    }

    private static func hasRegularFile(_ url: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func hasDirectory(_ url: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isRegularExecutable(_ url: URL) -> Bool {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return false
        }
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}

private enum PlaybackError: Error, LocalizedError {
    case missingEntrypoint
    case invalidImage
    case notPlayable(String)

    var errorDescription: String? {
        switch self {
        case .missingEntrypoint:
            return "The selected project has no playable entrypoint."
        case .invalidImage:
            return "The selected image could not be opened."
        case .notPlayable(let reason):
            return "This project is not playable on macOS: \(reason)."
        }
    }
}
