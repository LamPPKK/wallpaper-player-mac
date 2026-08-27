import AppKit
import BackgroundEngineCore

struct VideoPlaybackFailure: Equatable, Sendable {
    let asset: WallpaperAsset
    let displayUUID: String
    let message: String
}

enum WallpaperPlaybackRevisionIdentity {
    /// Fields that can change what bytes/code a live wallpaper session reads
    /// or whether that session is allowed to run. Compatibility, warnings,
    /// title and other library metadata are intentionally excluded.
    static func matches(_ lhs: WallpaperAsset, _ rhs: WallpaperAsset) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.supportStatus == rhs.supportStatus
            && lhs.projectDirectory == rhs.projectDirectory
            && lhs.entrypoint == rhs.entrypoint
            && lhs.thumbnail == rhs.thumbnail
            && lhs.contentHash == rhs.contentHash
            && lhs.allowsNetworkAccess == rhs.allowsNetworkAccess
    }
}

struct DisplaySuspensionPolicy {
    struct Reconciliation: Equatable {
        let retainedSuspendedDisplayUUIDs: Set<String>
        let pendingDisplayUUIDsToCancel: Set<String>
        let displayUUIDsToSchedule: Set<String>
    }

    static func isSuspended(
        displayUUID: String,
        globallySuspended: Bool,
        autoSuspendedDisplayUUIDs: Set<String>
    ) -> Bool {
        globallySuspended || autoSuspendedDisplayUUIDs.contains(displayUUID)
    }

    static func isGloballySuspended(
        manuallyPaused: Bool,
        lowPowerModeEnabled: Bool,
        systemSleeping: Bool
    ) -> Bool {
        manuallyPaused || lowPowerModeEnabled || systemSleeping
    }

    static func retainingCoveredDisplays(
        _ current: Set<String>,
        coveredDisplayUUIDs: Set<String>
    ) -> Set<String> {
        current.intersection(coveredDisplayUUIDs)
    }

    static func reconciliation(
        coveredDisplayUUIDs: Set<String>,
        suspendedDisplayUUIDs: Set<String>,
        pendingDisplayUUIDs: Set<String>
    ) -> Reconciliation {
        let retained = retainingCoveredDisplays(
            suspendedDisplayUUIDs,
            coveredDisplayUUIDs: coveredDisplayUUIDs
        )
        return Reconciliation(
            retainedSuspendedDisplayUUIDs: retained,
            pendingDisplayUUIDsToCancel: pendingDisplayUUIDs.subtracting(coveredDisplayUUIDs),
            displayUUIDsToSchedule: coveredDisplayUUIDs
                .subtracting(retained)
                .subtracting(pendingDisplayUUIDs)
        )
    }

    static func applyingDebouncedAutoSuspension(
        displayUUID: String,
        to suspendedDisplayUUIDs: Set<String>,
        coveredDisplayUUIDs: Set<String>
    ) -> Set<String> {
        guard coveredDisplayUUIDs.contains(displayUUID) else {
            return suspendedDisplayUUIDs
        }
        return suspendedDisplayUUIDs.union([displayUUID])
    }
}

struct WallpaperLifecyclePolicy {
    /// Display changes may be delivered after `willSleep`. Deferring topology
    /// reconciliation until `didWake` prevents those notifications from
    /// creating a new wallpaper runtime after the sleep cancellation barrier.
    static func shouldReconcileScreenParameters(
        isSystemSleeping: Bool,
        isApplicationTerminating: Bool
    ) -> Bool {
        !isSystemSleeping && !isApplicationTerminating
    }
}

private struct PendingDisplayAutoSuspension {
    let token: UUID
    let workItem: DispatchWorkItem
}

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
              current.contentHash == session.asset.contentHash,
              current.projectDirectory == session.asset.projectDirectory else {
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

/// Builds a complete replacement set without exposing partially constructed
/// wallpaper windows to the active session. Callers commit the returned set
/// only after every display succeeds; a failure closes every staged value and
/// leaves the existing session dictionary untouched.
enum TransactionalWallpaperWindowStager {
    static func stage<Input, Key: Hashable, Value>(
        _ inputs: [Input],
        key: (Input) -> Key,
        make: (Input) throws -> Value,
        discard: (Value) -> Void
    ) throws -> [Key: Value] {
        var staged: [Key: Value] = [:]
        do {
            for input in inputs {
                let value = try make(input)
                if let replaced = staged.updateValue(value, forKey: key(input)) {
                    discard(replaced)
                }
            }
            return staged
        } catch {
            staged.values.forEach(discard)
            throw error
        }
    }
}

/// Holds side effects that must not begin until a complete multi-display
/// replacement has committed. Cancelling a staged window drops its queued
/// work, while activation runs each operation exactly once.
@MainActor
final class DeferredWallpaperActivationGate {
    private var pendingOperations: [() -> Void] = []
    private var cancellationOperations: [() -> Void] = []
    private(set) var isActivated = false
    private(set) var isCancelled = false

    func performOnActivation(_ operation: @escaping () -> Void) {
        guard !isCancelled else { return }
        if isActivated {
            operation()
        } else {
            pendingOperations.append(operation)
        }
    }

    func performOnCancellation(_ operation: @escaping () -> Void) {
        if isCancelled {
            operation()
        } else if !isActivated {
            cancellationOperations.append(operation)
        }
    }

    func activate() {
        guard !isActivated, !isCancelled else { return }
        isActivated = true
        let operations = pendingOperations
        pendingOperations.removeAll(keepingCapacity: false)
        cancellationOperations.removeAll(keepingCapacity: false)
        operations.forEach { $0() }
    }

    func cancel() {
        guard !isActivated else { return }
        isCancelled = true
        let operations = cancellationOperations
        pendingOperations.removeAll(keepingCapacity: false)
        cancellationOperations.removeAll(keepingCapacity: false)
        operations.forEach { $0() }
    }
}

@MainActor
enum DeferredWallpaperTask {
    static func make<Value: Sendable>(
        activationGate: DeferredWallpaperActivationGate?,
        cancelledValue: Value,
        operation: @escaping @Sendable () async -> Value
    ) -> Task<Value, Never> {
        guard let activationGate else {
            return Task {
                guard !Task.isCancelled else { return cancelledValue }
                return await operation()
            }
        }
        let activationStream = AsyncStream<Bool> { continuation in
            activationGate.performOnActivation {
                continuation.yield(true)
                continuation.finish()
            }
            activationGate.performOnCancellation {
                continuation.yield(false)
                continuation.finish()
            }
        }
        return Task {
            var iterator = activationStream.makeAsyncIterator()
            guard await iterator.next() == true, !Task.isCancelled else {
                return cancelledValue
            }
            return await operation()
        }
    }
}

struct SingleWallpaperDisplayTarget {
    let index: Int
    let displayUUID: String
    let screenFrame: CGRect
    let visibleFrame: CGRect
}

@MainActor
final class WallpaperPlayer {
    static let shared = WallpaperPlayer()

    typealias SingleWallpaperDisplayTargetProvider = @MainActor () -> [SingleWallpaperDisplayTarget]
    typealias SingleWallpaperConstructionFailure = @MainActor (String) -> Error?

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
    private var autoSuspendedDisplayUUIDs: Set<String> = []
    private var isManuallyPaused = false
    private var isSystemSleeping = false
    private var lastDisplayTopology: [WallpaperDisplaySnapshot] = []
    private var pendingLibraryReplacementAssetIDs: Set<WallpaperAsset.ID> = []
    private var quiescedAppliedSessionsByAssetID: [
        WallpaperAsset.ID: [String: AssignedDisplayRefreshPlan.AppliedSession]
    ] = [:]
    private var pendingAutoSuspensions: [String: PendingDisplayAutoSuspension] = [:]
    private let visibilityMonitor = DesktopVisibilityMonitor()
    private var videoRuntimeFailureHandler: ((VideoPlaybackFailure) -> Void)?
    private let singleWallpaperDisplayTargetProvider: SingleWallpaperDisplayTargetProvider
    private let singleWallpaperConstructionFailure: SingleWallpaperConstructionFailure

    init(
        singleWallpaperDisplayTargetProvider: @escaping SingleWallpaperDisplayTargetProvider = {
            NSScreen.screens.enumerated().map { index, screen in
                SingleWallpaperDisplayTarget(
                    index: index,
                    displayUUID: DisplayIdentity.uuid(for: screen),
                    screenFrame: screen.frame,
                    visibleFrame: screen.visibleFrame
                )
            }
        },
        singleWallpaperConstructionFailure: @escaping SingleWallpaperConstructionFailure = { _ in nil }
    ) {
        self.singleWallpaperDisplayTargetProvider = singleWallpaperDisplayTargetProvider
        self.singleWallpaperConstructionFailure = singleWallpaperConstructionFailure
    }
    private var isApplicationTerminating = false

    var hasActiveDisplayAssignments: Bool {
        !activeDisplayAssignments.isEmpty
    }

    /// Internal runtime state exposed to app-hosted regression tests. Keeping
    /// this read-only also makes it impossible for tests or UI code to mutate
    /// the live window/session dictionaries behind the coordinator.
    var activeWindowDisplayUUIDs: Set<String> {
        Set(windows.keys)
    }

    var activeAssetID: WallpaperAsset.ID? {
        activeAsset?.id
    }

    var activeWindowIdentities: [String: ObjectIdentifier] {
        windows.mapValues(ObjectIdentifier.init)
    }

    var activeWindowVisibility: [String: Bool] {
        windows.mapValues(\.isVisible)
    }

    var activeAppliedDisplaySessions: [String: AssignedDisplayRefreshPlan.AppliedSession] {
        appliedDisplaySessions
    }

    func setVideoRuntimeFailureHandler(
        _ handler: ((VideoPlaybackFailure) -> Void)?
    ) {
        videoRuntimeFailureHandler = handler
    }

    private func videoFailureHandler(
        asset: WallpaperAsset,
        displayUUID: String
    ) -> ((String) -> Void)? {
        guard asset.kind == .video else { return nil }
        return { [weak self] message in
            self?.videoRuntimeFailureHandler?(
                VideoPlaybackFailure(
                    asset: asset,
                    displayUUID: displayUUID,
                    message: message
                )
            )
        }
    }

    func play(
        asset: WallpaperAsset,
        autoPauseWhenCovered: Bool = true,
        displayMode: WallpaperDisplayMode = .fit,
        audioEnabled: Bool? = nil,
        audioVolume: Double? = nil
    ) throws {
        guard !isApplicationTerminating else {
            throw PlaybackError.notPlayable("Application termination is in progress")
        }
        guard !pendingLibraryReplacementAssetIDs.contains(asset.id) else {
            throw PlaybackError.notPlayable("Workshop update in progress")
        }
        guard asset.supportStatus == .playable else {
            throw PlaybackError.notPlayable(asset.supportStatus.rawValue)
        }
        guard let entrypoint = asset.entrypoint else {
            throw PlaybackError.missingEntrypoint
        }
        let url = URL(filePath: entrypoint)
        let displayTargets = singleWallpaperDisplayTargetProvider()
        guard !displayTargets.isEmpty else {
            throw PlaybackError.notPlayable("No connected displays are available")
        }
        let resolvedAudioEnabled = audioEnabled ?? self.audioEnabled
        let resolvedAudioVolume = audioVolume ?? self.audioVolume
        let stagedWindows = try TransactionalWallpaperWindowStager.stage(
            displayTargets,
            key: { $0.displayUUID },
            make: { target in
                if let failure = self.singleWallpaperConstructionFailure(target.displayUUID) {
                    throw failure
                }
                return try WallpaperWindow(
                    asset: asset,
                    displayUUID: target.displayUUID,
                    url: url,
                    frame: WallpaperScreenFrames.wallpaperFrame(
                        screenFrame: target.screenFrame,
                        visibleFrame: target.visibleFrame
                    ),
                    displayMode: displayMode,
                    audioEnabled: false,
                    audioVolume: resolvedAudioVolume,
                    allowsAudio: target.index == 0,
                    quality: .balanced,
                    deferredActivation: true,
                    videoFailureHandler: self.videoFailureHandler(
                        asset: asset,
                        displayUUID: target.displayUUID
                    )
                )
            },
            discard: { $0.close() }
        )
        let stagedSessions = stagedWindows.keys.reduce(
            into: [String: AssignedDisplayRefreshPlan.AppliedSession]()
        ) { sessions, displayUUID in
            sessions[displayUUID] = .init(assignment: nil, asset: asset)
        }

        // No throwing work remains below this point. Present the complete new
        // set before retiring the old set so a failed replacement can never
        // leave one or every display blank.
        let retiredWindows = windows
        cancelPendingAutoSuspension()
        autoSuspendedDisplayUUIDs.removeAll(keepingCapacity: false)
        isManuallyPaused = false
        activeDisplayAssignments = []
        activeAssetsByID = [:]
        activeAsset = asset
        self.autoPauseWhenCovered = autoPauseWhenCovered
        self.displayMode = displayMode
        self.audioEnabled = resolvedAudioEnabled
        self.audioVolume = resolvedAudioVolume
        windows = stagedWindows
        appliedDisplaySessions = stagedSessions
        lastDisplayTopology = WallpaperDisplayTopology.current()
        windows.values.forEach { $0.show() }
        retiredWindows.values.forEach { $0.close() }
        for target in displayTargets {
            windows[target.displayUUID]?.activate(
                suspended: isEffectivelySuspended(displayUUID: target.displayUUID),
                audioEnabled: resolvedAudioEnabled && target.index == 0,
                audioVolume: resolvedAudioVolume
            )
        }
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
        guard !isApplicationTerminating else { return [] }
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

    /// Applies UI/diagnostic metadata to immutable session snapshots without
    /// replacing a wallpaper window. Runtime Scene reports are followed by a
    /// display-targeted refresh when playback actually needs to change; other
    /// displays must retain their current player and cache lease.
    func updateLibraryAssetMetadataWithoutReopening(_ asset: WallpaperAsset) {
        if let existing = activeAssetsByID[asset.id],
           WallpaperPlaybackRevisionIdentity.matches(existing, asset) {
            activeAssetsByID[asset.id] = asset
        }
        if let current = activeAsset,
           WallpaperPlaybackRevisionIdentity.matches(current, asset) {
            activeAsset = asset
        }
        appliedDisplaySessions = appliedDisplaySessions.mapValues { session in
            guard WallpaperPlaybackRevisionIdentity.matches(session.asset, asset) else {
                return session
            }
            return .init(assignment: session.assignment, asset: asset)
        }
        if let quiesced = quiescedAppliedSessionsByAssetID[asset.id] {
            quiescedAppliedSessionsByAssetID[asset.id] = quiesced.mapValues { session in
                guard WallpaperPlaybackRevisionIdentity.matches(session.asset, asset) else {
                    return session
                }
                return .init(assignment: session.assignment, asset: asset)
            }
        }
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
            setAutoSuspendedDisplayUUIDs([])
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

    /// Swaps a completed Scene cache into only the display that requested the
    /// render. Scene render jobs are deduplicated by cache key, but every
    /// awaiting display receives its own completion and keeps unrelated
    /// wallpaper sessions intact.
    func refreshIfNeeded(
        afterSceneVideoRenderFor assetId: String,
        displayUUID: String
    ) {
        refreshSceneDisplayIfNeeded(assetId: assetId, displayUUID: displayUUID)
    }

    /// Rebuilds only the display whose AVPlayer rejected a verified Scene
    /// generation. Other displays retain their current playback lease and are
    /// refreshed only if they independently report a failure.
    func refreshIfNeeded(
        afterSceneCachePlaybackFailureFor assetId: String,
        displayUUID: String
    ) {
        refreshSceneDisplayIfNeeded(assetId: assetId, displayUUID: displayUUID)
    }

    private func refreshSceneDisplayIfNeeded(
        assetId: String,
        displayUUID: String
    ) {
        guard !pendingLibraryReplacementAssetIDs.contains(assetId) else { return }
        if !activeDisplayAssignments.isEmpty {
            let assignments = AssignedDisplayRefreshPlan.effectiveAssignments(
                activeDisplayAssignments
            )
            guard assignments[displayUUID]?.assetID == assetId else { return }
            _ = openAssignedWindows(
                displayUUIDs: [displayUUID],
                replacingExisting: true
            )
            updateVisibilityState()
            return
        }
        guard windows[displayUUID] != nil,
              let activeAsset,
              activeAsset.id == assetId,
              activeAsset.kind == .scene else {
            return
        }
        _ = openSingleWallpaperWindows(
            asset: activeAsset,
            displayUUIDs: [displayUUID],
            replacingExisting: true
        )
        updateVisibilityState()
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
        let webCancellationCheckpoint = WebMediaRuntimeCoordinator.shared.cancellationCheckpoint()
        let sceneCancellationCheckpoint = SceneRenderCoordinator.shared.cancellationCheckpoint()
        Task {
            await WebMediaRuntimeCoordinator.shared.cancelAll(upTo: webCancellationCheckpoint)
            await SceneRenderCoordinator.shared.cancelAll(upTo: sceneCancellationCheckpoint)
        }
        quiescePlaybackSessions()
    }

    /// Synchronous half of the application quit barrier. Runtime coordinator
    /// gates are closed by the lifecycle delegate before this is called, then
    /// every window and observer is released without spawning another cleanup
    /// task that the termination handshake would have to discover indirectly.
    func beginApplicationTermination() {
        isApplicationTerminating = true
        videoRuntimeFailureHandler = nil
        quiescePlaybackSessions()
    }

    private func quiescePlaybackSessions() {
        activeAsset = nil
        activeDisplayAssignments = []
        activeAssetsByID = [:]
        quiescedAppliedSessionsByAssetID.removeAll(keepingCapacity: false)
        isManuallyPaused = false
        isSystemSleeping = false
        isSuspended = false
        autoSuspendedDisplayUUIDs.removeAll(keepingCapacity: false)
        lastDisplayTopology = []
        cancelPendingAutoSuspension()
        stopVisibilityTimer()
        stopLifecycleObservers()
        closeWindows()
    }

    private func closeWindows() {
        cancelPendingAutoSuspension()
        autoSuspendedDisplayUUIDs.removeAll(keepingCapacity: false)
        windows.values.forEach { $0.close() }
        windows.removeAll(keepingCapacity: false)
        appliedDisplaySessions.removeAll(keepingCapacity: false)
    }

    private func closeWindows(displayUUIDs: Set<String>) {
        cancelPendingAutoSuspension(displayUUIDs: displayUUIDs)
        for displayUUID in displayUUIDs {
            windows.removeValue(forKey: displayUUID)?.close()
            appliedDisplaySessions.removeValue(forKey: displayUUID)
        }
        autoSuspendedDisplayUUIDs.subtract(displayUUIDs)
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
        guard !isApplicationTerminating else { return [] }
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
                    displayUUID: displayUUID,
                    url: url,
                    frame: WallpaperScreenFrames.wallpaperFrame(
                        screenFrame: screen.frame,
                        visibleFrame: screen.visibleFrame
                    ),
                    displayMode: displayMode,
                    audioEnabled: audioEnabled && index == 0,
                    audioVolume: audioVolume,
                    allowsAudio: index == 0,
                    videoFailureHandler: videoFailureHandler(
                        asset: asset,
                        displayUUID: displayUUID
                    )
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
            for (displayUUID, replacement) in opened {
                replacement.setSuspended(isEffectivelySuspended(displayUUID: displayUUID))
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
        guard !isApplicationTerminating else { return [] }
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
                    displayUUID: displayUUID,
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
                    quality: assignment?.quality ?? .balanced,
                    videoFailureHandler: videoFailureHandler(
                        asset: asset,
                        displayUUID: displayUUID
                    )
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

        for (displayUUID, fallback) in opened {
            fallback.setSuspended(isEffectivelySuspended(displayUUID: displayUUID))
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
        if DisplaySuspensionPolicy.isGloballySuspended(
            manuallyPaused: isManuallyPaused,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            systemSleeping: isSystemSleeping
        ) {
            cancelPendingAutoSuspension()
            setSuspended(true)
            return
        }

        setSuspended(false)
        guard autoPauseWhenCovered else {
            cancelPendingAutoSuspension()
            setAutoSuspendedDisplayUUIDs([])
            return
        }

        let coveredDisplayUUIDs = currentlyCoveredDisplayUUIDs()
        let reconciliation = DisplaySuspensionPolicy.reconciliation(
            coveredDisplayUUIDs: coveredDisplayUUIDs,
            suspendedDisplayUUIDs: autoSuspendedDisplayUUIDs,
            pendingDisplayUUIDs: Set(pendingAutoSuspensions.keys)
        )
        setAutoSuspendedDisplayUUIDs(reconciliation.retainedSuspendedDisplayUUIDs)
        cancelPendingAutoSuspension(
            displayUUIDs: reconciliation.pendingDisplayUUIDsToCancel
        )
        scheduleAutoSuspension(displayUUIDs: reconciliation.displayUUIDsToSchedule)
    }

    private func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else {
            return
        }
        isSuspended = suspended
        applyCurrentSuspensionToWindows()
    }

    private func setAutoSuspendedDisplayUUIDs(_ displayUUIDs: Set<String>) {
        let normalized = displayUUIDs.intersection(windows.keys)
        guard normalized != autoSuspendedDisplayUUIDs else { return }
        let changed = normalized.symmetricDifference(autoSuspendedDisplayUUIDs)
        autoSuspendedDisplayUUIDs = normalized
        for displayUUID in changed {
            windows[displayUUID]?.setSuspended(
                isEffectivelySuspended(displayUUID: displayUUID)
            )
        }
    }

    private func isEffectivelySuspended(displayUUID: String) -> Bool {
        DisplaySuspensionPolicy.isSuspended(
            displayUUID: displayUUID,
            globallySuspended: isSuspended,
            autoSuspendedDisplayUUIDs: autoSuspendedDisplayUUIDs
        )
    }

    /// Newly constructed windows must inherit the effective state even when
    /// `isSuspended` itself did not change. This covers display hot-plug,
    /// sleep/wake and Scene-cache refresh while manually paused.
    private func applyCurrentSuspensionToWindows() {
        for (displayUUID, window) in windows {
            window.setSuspended(isEffectivelySuspended(displayUUID: displayUUID))
        }
    }

    private func currentlyCoveredDisplayUUIDs() -> Set<String> {
        let screens = NSScreen.screens
        let visibility = visibilityMonitor.desktopVisibility(for: screens)
        guard visibility.count == screens.count else { return [] }
        return Set(zip(screens, visibility).compactMap { screen, desktopIsVisible in
            guard !desktopIsVisible else { return nil }
            return DisplayIdentity.uuid(for: screen)
        }).intersection(windows.keys)
    }

    private func scheduleAutoSuspension(displayUUIDs: Set<String>) {
        guard !displayUUIDs.isEmpty, !isSuspended else {
            return
        }
        for displayUUID in displayUUIDs where pendingAutoSuspensions[displayUUID] == nil {
            guard windows[displayUUID] != nil else { continue }
            let token = UUID()
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self,
                          self.pendingAutoSuspensions[displayUUID]?.token == token else {
                        return
                    }
                    self.pendingAutoSuspensions.removeValue(forKey: displayUUID)
                    guard self.autoPauseWhenCovered,
                          !self.isManuallyPaused,
                          !self.isSystemSleeping,
                          !ProcessInfo.processInfo.isLowPowerModeEnabled else {
                        return
                    }
                    let coveredDisplayUUIDs = self.currentlyCoveredDisplayUUIDs()
                    let updatedSuspendedDisplayUUIDs = DisplaySuspensionPolicy.applyingDebouncedAutoSuspension(
                        displayUUID: displayUUID,
                        to: self.autoSuspendedDisplayUUIDs,
                        coveredDisplayUUIDs: coveredDisplayUUIDs
                    )
                    guard updatedSuspendedDisplayUUIDs != self.autoSuspendedDisplayUUIDs else {
                        return
                    }
                    self.setAutoSuspendedDisplayUUIDs(updatedSuspendedDisplayUUIDs)
                }
            }
            pendingAutoSuspensions[displayUUID] = PendingDisplayAutoSuspension(
                token: token,
                workItem: workItem
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
        }
    }

    private func cancelPendingAutoSuspension() {
        cancelPendingAutoSuspension(displayUUIDs: Set(pendingAutoSuspensions.keys))
    }

    private func cancelPendingAutoSuspension(displayUUIDs: Set<String>) {
        for displayUUID in displayUUIDs {
            pendingAutoSuspensions.removeValue(forKey: displayUUID)?.workItem.cancel()
        }
    }

    private func startLifecycleObservers() {
        guard !isApplicationTerminating, workspaceObservers.isEmpty else {
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let webCancellationCheckpoint = WebMediaRuntimeCoordinator.shared.cancellationCheckpoint()
                    let sceneCancellationCheckpoint = SceneRenderCoordinator.shared.cancellationCheckpoint()
                    self.isSystemSleeping = true
                    self.stopVisibilityTimer()
                    self.cancelPendingAutoSuspension()
                    self.setSuspended(true)
                    Task {
                        await WebMediaRuntimeCoordinator.shared.cancelAll(upTo: webCancellationCheckpoint)
                        await SceneRenderCoordinator.shared.cancelAll(upTo: sceneCancellationCheckpoint)
                    }
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reopenAfterWake() }
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
                MainActor.assumeIsolated { self?.reopenAfterScreenFrameChange() }
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
        guard !isApplicationTerminating else { return }
        isSystemSleeping = false
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
        startVisibilityTimer()
        updateVisibilityState()
    }

    private func openAssignedWindows(
        displayUUIDs requestedDisplayUUIDs: Set<String>? = nil,
        replacingExisting: Bool = false
    ) -> [DisplayPlaybackFailure] {
        guard !isApplicationTerminating else { return [] }
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
                    displayUUID: displayUUID,
                    url: URL(filePath: entrypoint),
                    frame: screen.frame,
                    displayMode: assignment.displayMode,
                    audioEnabled: globalAudioForAssignment(assignment, isPrimaryDisplay: index == 0),
                    audioVolume: audioVolume,
                    allowsAudio: index == 0 && assignment.audioSource == .primaryDisplay,
                    quality: assignment.quality,
                    videoFailureHandler: videoFailureHandler(
                        asset: asset,
                        displayUUID: displayUUID
                    )
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
            for (displayUUID, replacement) in opened {
                replacement.setSuspended(isEffectivelySuspended(displayUUID: displayUUID))
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
        guard WallpaperLifecyclePolicy.shouldReconcileScreenParameters(
                  isSystemSleeping: isSystemSleeping,
                  isApplicationTerminating: isApplicationTerminating
              ),
              activeAsset != nil || !activeDisplayAssignments.isEmpty else {
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
    private let activationGate: DeferredWallpaperActivationGate?

    var isVisible: Bool {
        window.isVisible
    }

    init(asset: WallpaperAsset,
        displayUUID: String,
        url: URL,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool = false,
        audioVolume: Double = 0.5,
        allowsAudio: Bool = true,
        quality: RenderQuality = .balanced,
        deferredActivation: Bool = false,
        videoFailureHandler: ((String) -> Void)? = nil
    ) throws {
        self.allowsAudio = allowsAudio
        let activationGate = deferredActivation ? DeferredWallpaperActivationGate() : nil
        self.activationGate = activationGate
        content = try Self.makeContentView(
            asset: asset,
            displayUUID: displayUUID,
            url: url,
            frame: frame,
            displayMode: displayMode,
            audioEnabled: audioEnabled,
            audioVolume: audioVolume,
            quality: quality,
            activationGate: activationGate,
            videoFailureHandler: videoFailureHandler
        )
        if deferredActivation {
            (content as? PausableWallpaperContent)?.setPlaybackSuspended(true)
        }
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
        activationGate?.cancel()
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

    func activate(suspended: Bool, audioEnabled: Bool, audioVolume: Double) {
        activationGate?.activate()
        setSuspended(suspended)
        setAudio(enabled: audioEnabled, volume: audioVolume)
    }

    private static func makeContentView(
        asset: WallpaperAsset,
        displayUUID: String,
        url: URL,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool = false,
        audioVolume: Double = 0.5,
        quality: RenderQuality = .balanced,
        activationGate: DeferredWallpaperActivationGate? = nil,
        videoFailureHandler: ((String) -> Void)? = nil
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
                audioVolume: audioVolume,
                onPlaybackFailure: videoFailureHandler
            )
        case .web:
            return RestrictedWebWallpaperView(
                url: url,
                readAccessURL: URL(filePath: asset.projectDirectory),
                frame: contentFrame,
                networkAccessAllowed: asset.allowsNetworkAccess == true,
                audioEnabled: audioEnabled,
                audioVolume: audioVolume
            )
        case .image:
            return try AnimatedImageWallpaperView(url: url, frame: contentFrame, displayMode: displayMode)
        case .scene:
            let previewURL = asset.thumbnail.map { URL(filePath: $0) }
            return try SceneWallpaperContentFactory.makeSceneContentView(
                asset: asset,
                displayUUID: displayUUID,
                url: url,
                previewURL: previewURL,
                frame: contentFrame,
                displayMode: displayMode,
                audioEnabled: audioEnabled,
                audioVolume: audioVolume,
                quality: quality,
                activationGate: activationGate
            )
        case .application, .unknown:
            throw PlaybackError.notPlayable(asset.kind.rawValue)
        }
    }
}

struct SceneCachedReportValidationDependencies: Sendable {
    let analyzeScene: @Sendable (URL, URL) -> CompatibilityReport
    let cachedAudioResult: @Sendable (URL) async -> SceneRenderAudioResult?

    static let live = SceneCachedReportValidationDependencies(
        analyzeScene: { sceneURL, projectRoot in
            WallpaperCompatibilityAnalyzer().analyze(
                kind: .scene,
                status: .playable,
                entrypoint: sceneURL,
                projectRoot: projectRoot
            )
        },
        cachedAudioResult: { cacheURL in
            await SceneVideoCacheMetadataVerifier.shared
                .metadata(for: cacheURL)?
                .audioResult
        }
    )
}

/// Keeps the cache-admission table bounded without evicting work that already
/// has a deferred activation callback or a running verifier. The limit is
/// intentionally soft: pending/running entries own display progress, so only
/// rejected or otherwise missing entries are safe to retire.
struct PlaybackCacheAdmissionCapacityLimiter {
    static func evictionKeys<Entry>(
        orderedKeys: [String],
        entries: [String: Entry],
        limit: Int,
        isProtected: (Entry) -> Bool
    ) -> [String] {
        guard limit >= 0, orderedKeys.count > limit else { return [] }
        var retainedCount = orderedKeys.count
        var evictions: [String] = []
        for key in orderedKeys where retainedCount > limit {
            if let entry = entries[key], isProtected(entry) {
                continue
            }
            evictions.append(key)
            retainedCount -= 1
        }
        return evictions
    }
}

@MainActor
enum SceneWallpaperContentFactory {
    static var lastDiagnostic: String?
    static var statusHandler: ((String) -> Void)?
    static var compatibilityReportHandler: ((WallpaperAsset, CompatibilityReport) -> Void)?
    /// Injectable only so regression tests can prove that the synchronous
    /// MainActor playback path does not analyze a Scene package or hash a
    /// potentially large cache video. Production work snapshots `.live`
    /// before moving validation to a detached utility task.
    static var cachedReportValidationDependencies = SceneCachedReportValidationDependencies.live
    private static var forcedCachedAssetRevisions: Set<String> = []
    /// A Scene package is immutable for a content-hash revision. Keep only a
    /// tiny playback cache so creating one wallpaper view per display does
    /// not synchronously map and decode the same package on MainActor for
    /// every monitor.
    private static var playbackMetadataCache: [String: ScenePackagePlaybackMetadata] = [:]
    private static var playbackMetadataOrder: [String] = []
    private static let playbackMetadataCacheLimit = 2
    private struct CachedReportValidationRegistration {
        let token: UUID
        let persistedReport: CompatibilityReport?
        let explicitAudioResult: SceneRenderAudioResult?
        let provisionalReport: CompatibilityReport
        let warning: String?

        func matches(
            persistedReport: CompatibilityReport?,
            explicitAudioResult: SceneRenderAudioResult?,
            provisionalReport: CompatibilityReport,
            warning: String?
        ) -> Bool {
            self.persistedReport == persistedReport
                && self.explicitAudioResult == explicitAudioResult
                && self.provisionalReport == provisionalReport
                && self.warning == warning
        }
    }
    private static var cachedReportValidations: [URL: CachedReportValidationRegistration] = [:]
    private enum PlaybackCacheAdmissionPhase {
        case pending(candidates: [URL])
        case running(token: UUID)
        case rejected
    }
    private struct PlaybackCacheAdmissionRegistration {
        let signature: String
        var phase: PlaybackCacheAdmissionPhase
        var waitingDisplayUUIDs: Set<String>
    }
    private enum PlaybackCacheAdmission {
        case none
        case verifying(key: String)
        case accepted(URL)
        case rejected
    }
    private static var playbackCacheAdmissions: [String: PlaybackCacheAdmissionRegistration] = [:]
    private static var playbackCacheAdmissionOrder: [String] = []
    private static let playbackCacheAdmissionLimit = 32
    private static var failedPlaybackCacheGenerations: Set<String> = []
    /// Invoked with the asset id once a Scene cache render finishes or an
    /// existing immutable generation is admitted after relaunch. Lets callers
    /// refresh anything else derived from "does this scene have a trusted
    /// cached video yet" (the lock screen animation configuration) without
    /// this factory needing to know about that dependency directly.
    static var sceneVideoRenderCompletionHandler: ((String) -> Void)?

    /// Admission is scoped to the exact candidate set, not just the asset
    /// revision. Different displays can legitimately use different Scene
    /// cache keys because their record size or quality differs. A revision-only
    /// key lets one display's accepted generation erase another display's
    /// pending verifier and leave that screen on its preview forever.
    static func playbackCacheAdmissionKey(
        for asset: WallpaperAsset,
        candidates: [URL]
    ) -> String {
        let signature = candidates.map {
            $0.standardizedFileURL.path
        }.joined(separator: "\u{0}")
        return revisionKey(for: asset) + "\u{0}candidates\u{0}" + signature
    }

    static func eligiblePlaybackCacheCandidates(_ candidates: [URL]) -> [URL] {
        candidates.filter {
            !failedPlaybackCacheGenerations.contains($0.standardizedFileURL.path)
        }
    }

    private static func playbackCacheAdmission(
        for asset: WallpaperAsset,
        candidates: [URL]
    ) -> PlaybackCacheAdmission {
        guard !candidates.isEmpty else {
            return .none
        }
        let key = playbackCacheAdmissionKey(for: asset, candidates: candidates)
        if let accepted = candidates.first(where: {
            SceneVideoCacheVerifiedGenerationRegistry.shared.contains($0)
        }) {
            // A verifier registers the generation immediately before it
            // resumes on MainActor. Keep a running registration alive until
            // that task delivers completion to every display already waiting
            // on the same candidate set. New displays can open `accepted`
            // directly and do not need to join the waiter list.
            if case .running = playbackCacheAdmissions[key]?.phase {
                return .accepted(accepted)
            }
            playbackCacheAdmissions[key] = nil
            playbackCacheAdmissionOrder.removeAll { $0 == key }
            return .accepted(accepted)
        }

        let signature = candidates.map { $0.standardizedFileURL.path }.joined(separator: "\u{0}")
        if let existing = playbackCacheAdmissions[key], existing.signature == signature {
            switch existing.phase {
            case .pending, .running:
                return .verifying(key: key)
            case .rejected:
                return .rejected
            }
        }
        playbackCacheAdmissions[key] = PlaybackCacheAdmissionRegistration(
            signature: signature,
            phase: .pending(candidates: candidates),
            waitingDisplayUUIDs: []
        )
        playbackCacheAdmissionOrder.removeAll { $0 == key }
        playbackCacheAdmissionOrder.append(key)
        let evictedKeys = PlaybackCacheAdmissionCapacityLimiter.evictionKeys(
            orderedKeys: playbackCacheAdmissionOrder,
            entries: playbackCacheAdmissions,
            limit: playbackCacheAdmissionLimit
        ) { registration in
            switch registration.phase {
            case .pending, .running:
                true
            case .rejected:
                false
            }
        }
        if !evictedKeys.isEmpty {
            let evictedSet = Set(evictedKeys)
            playbackCacheAdmissionOrder.removeAll { evictedSet.contains($0) }
        }
        for evicted in evictedKeys {
            playbackCacheAdmissions[evicted] = nil
        }
        return .verifying(key: key)
    }

    private static func beginPlaybackCacheAdmission(
        key: String,
        asset: WallpaperAsset,
        displayUUID: String
    ) {
        guard var registration = playbackCacheAdmissions[key] else {
            return
        }
        registration.waitingDisplayUUIDs.insert(displayUUID)
        guard case .pending(let candidates) = registration.phase else {
            playbackCacheAdmissions[key] = registration
            return
        }
        let token = UUID()
        registration.phase = .running(token: token)
        playbackCacheAdmissions[key] = registration
        Task {
            var accepted: URL?
            for candidate in candidates {
                if await SceneVideoCacheMetadataVerifier.shared.metadata(for: candidate) != nil,
                   eligiblePlaybackCacheCandidates([candidate]).count == 1,
                   SceneVideoCacheVerifiedGenerationRegistry.shared.contains(candidate) {
                    accepted = candidate
                    break
                }
            }
            guard var current = playbackCacheAdmissions[key],
                  current.signature == registration.signature,
                  case .running(let currentToken) = current.phase,
                  currentToken == token else {
                // A terminal verifier result must never strand the displays
                // that launched it on their preview. Running registrations
                // are normally preserved until this point; this fallback also
                // closes the loop if future lifecycle code retires one early.
                for displayUUID in registration.waitingDisplayUUIDs {
                    WallpaperPlayer.shared.refreshIfNeeded(
                        afterSceneVideoRenderFor: asset.id,
                        displayUUID: displayUUID
                    )
                }
                if accepted != nil {
                    sceneVideoRenderCompletionHandler?(asset.id)
                }
                return
            }
            let waitingDisplayUUIDs = current.waitingDisplayUUIDs
            if accepted == nil {
                current.phase = .rejected
                playbackCacheAdmissions[key] = current
                lastDiagnostic = "Scene cache verification failed; rebuilding from the source Scene."
            } else {
                playbackCacheAdmissions[key] = nil
                playbackCacheAdmissionOrder.removeAll { $0 == key }
            }
            for displayUUID in waitingDisplayUUIDs {
                WallpaperPlayer.shared.refreshIfNeeded(
                    afterSceneVideoRenderFor: asset.id,
                    displayUUID: displayUUID
                )
            }
            if accepted != nil {
                sceneVideoRenderCompletionHandler?(asset.id)
            }
        }
    }

    private static func playbackMetadata(
        for asset: WallpaperAsset,
        sceneURL: URL
    ) throws -> ScenePackagePlaybackMetadata {
        guard asset.contentHash != nil else {
            return try ScenePackagePlaybackMetadata.load(sceneURL: sceneURL)
        }
        let key = revisionKey(for: asset)
            + "\u{0}"
            + sceneURL.standardizedFileURL.path
        if let cached = playbackMetadataCache[key] {
            playbackMetadataOrder.removeAll { $0 == key }
            playbackMetadataOrder.append(key)
            return cached
        }

        let loaded = try ScenePackagePlaybackMetadata.load(sceneURL: sceneURL)
        playbackMetadataCache[key] = loaded
        playbackMetadataOrder.append(key)
        while playbackMetadataOrder.count > playbackMetadataCacheLimit {
            let evicted = playbackMetadataOrder.removeFirst()
            playbackMetadataCache[evicted] = nil
        }
        return loaded
    }

    static func makeSceneContentView(
        asset: WallpaperAsset,
        displayUUID: String = "unassigned-display",
        url: URL,
        previewURL: URL? = nil,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool = false,
        audioVolume: Double = 0.5,
        quality: RenderQuality = .balanced,
        activationGate: DeferredWallpaperActivationGate? = nil
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
        let playbackMetadata = try? playbackMetadata(for: asset, sceneURL: url)
        let sceneCanvas = playbackMetadata?.canvasSize
        let recordSize = SceneVideoRecordSize.clampedRecordSize(
            forSceneCanvas: sceneCanvas.map { CGSize(width: $0.width, height: $0.height) },
            displayLogicalSize: frame.size,
            maxLongEdge: quality.maximumSceneLongEdge
        )
        let assetsDirectory = SceneEngineRendererConfiguration.assetsDirectoryURL()
        let engineAssetsFingerprint = try assetsDirectory.map {
            try SceneCacheDependencyFingerprint.engineAssets(
                metadata: playbackMetadata,
                projectDirectory: URL(filePath: asset.projectDirectory),
                assetsDirectory: $0,
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
        let preferredCacheKeys = [cacheKey, lowQualityCacheKey].compactMap { $0 }
        let prefersValidatedNative: Bool
        if case .live = asset.compatibility {
            prefersValidatedNative = true
        } else {
            prefersValidatedNative = false
        }
        let forcesCachedPlayback = forcedCachedAssetRevisions.contains(revisionKey(for: asset))
        let cacheCandidates = eligiblePlaybackCacheCandidates(
            SceneVideoCache.freshPlaybackCacheCandidates(
                preferredKeys: preferredCacheKeys,
                assetID: asset.id,
                contentHash: asset.contentHash,
                sourceURL: url
            )
        )
        let admission = playbackCacheAdmission(for: asset, candidates: cacheCandidates)
        let cachedVideoURL: URL?
        var backgroundAdmissionKey: String?
        switch admission {
        case .accepted(let url):
            cachedVideoURL = url
        case .none, .rejected:
            cachedVideoURL = nil
        case .verifying(let key):
            cachedVideoURL = nil
            if prefersValidatedNative, !forcesCachedPlayback {
                // Native playback does not wait for a cache it may never need,
                // but verification still runs in the background so a later
                // native failure can switch to a trusted generation.
                backgroundAdmissionKey = key
            } else {
                let fallback = fallbackSceneView(
                    asset: asset,
                    url: url,
                    previewURL: previewURL,
                    frame: frame,
                    displayMode: displayMode,
                    activationGate: activationGate,
                    retainsNativePlanForBackgroundClassification: true
                )
                performAfterActivation(activationGate) {
                    beginPlaybackCacheAdmission(
                        key: key,
                        asset: asset,
                        displayUUID: displayUUID
                    )
                    lastDiagnostic = "Scene cache verification in progress"
                    statusHandler?("Verifying Scene cache…")
                }
                return fallback.view
            }
        }
        let rendererURL = SceneEngineRendererConfiguration.executableURL()
        let ffmpegPath = VideoConverter().ffmpegPath()
        let resources = ScenePlaybackResources(
            cachedVideoURL: cachedVideoURL,
            hasExternalRenderer: rendererURL != nil,
            hasEngineAssets: assetsDirectory != nil,
            hasMediaTools: ffmpegPath != nil
        )
        let strategy = ScenePlaybackStrategyResolver().resolve(
            prefersValidatedNative: prefersValidatedNative,
            forcesCachedPlayback: forcesCachedPlayback,
            resources: resources
        )

        if let backgroundAdmissionKey {
            performAfterActivation(activationGate) {
                beginPlaybackCacheAdmission(
                    key: backgroundAdmissionKey,
                    asset: asset,
                    displayUUID: displayUUID
                )
            }
        }

        switch strategy {
        case .validatedNative:
            let nativePlanTask = fallbackNativePlanTask(
                asset: asset,
                url: url,
                activationGate: activationGate
            )
            let view = PreparingSceneWallpaperView(
                sceneURL: url,
                previewURL: previewURL,
                frame: frame,
                displayMode: displayMode,
                nativePlanTask: nativePlanTask,
                readinessHandler: { ready in
                    guard !ready else { return }
                    performAfterActivation(activationGate) {
                        recoverFailedNativeScene(
                            asset: asset,
                            displayUUID: displayUUID,
                            sceneURL: url,
                            previewURL: previewURL,
                            cachedVideoURL: cachedVideoURL,
                            preferredCacheKeys: preferredCacheKeys,
                            rendererURL: rendererURL,
                            assetsDirectory: assetsDirectory,
                            ffmpegPath: ffmpegPath,
                            recordSize: recordSize,
                            quality: quality,
                            engineAssetsFingerprint: engineAssetsFingerprint,
                            nativeFallbackPlan: nativePlanTask
                        )
                    }
                }
            )
            return view

        case .cachedVideo(let cachedVideoURL):
            // This provisional report is derived exclusively from persisted
            // manifest data. Package analysis and the content-bound MP4 hash
            // both stay off the main actor, especially when multiple large
            // Scene caches open together.
            performAfterActivation(activationGate) {
                publishProvisionalCachedReport(
                    for: asset,
                    sceneURL: url,
                    cacheURL: cachedVideoURL,
                    preferredCacheKeys: preferredCacheKeys
                )
            }
            return try cachedSceneView(
                asset: asset,
                displayUUID: displayUUID,
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
                displayMode: displayMode,
                activationGate: activationGate,
                retainsNativePlanForBackgroundClassification: true
            )
            performAfterActivation(activationGate) {
                scheduleSceneVideoRender(
                    asset: asset,
                    displayUUID: displayUUID,
                    sceneURL: url,
                    rendererURL: rendererURL,
                    assetsDirectory: assetsDirectory,
                    ffmpegPath: ffmpegPath,
                    recordSize: recordSize,
                    quality: quality,
                    engineAssetsFingerprint: engineAssetsFingerprint,
                    nativeFallbackPlan: fallback.nativePlanTask
                )
                lastDiagnostic = "scene video rendering in progress"
                statusHandler?("Reconstructing Scene cache… 0%")
            }
            return fallback.view

        case .nativeApproximation(let reason):
            lastDiagnostic = reason
            let fallback = fallbackSceneView(
                asset: asset,
                url: url,
                previewURL: previewURL,
                frame: frame,
                displayMode: displayMode,
                activationGate: activationGate,
                readinessHandler: { ready in
                    performAfterActivation(activationGate) {
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
                }
            )
            return fallback.view
        }
    }

    private static func performAfterActivation(
        _ activationGate: DeferredWallpaperActivationGate?,
        operation: @escaping () -> Void
    ) {
        if let activationGate {
            activationGate.performOnActivation(operation)
        } else {
            operation()
        }
    }

    private struct SceneFallback {
        let view: NSView
        let nativePlanTask: Task<SceneRenderPlan?, Never>
    }

    private static func fallbackNativePlanTask(
        asset: WallpaperAsset,
        url: URL,
        activationGate: DeferredWallpaperActivationGate? = nil
    ) -> Task<SceneRenderPlan?, Never> {
        let probeKey = SceneNativeReadinessCoordinator.cacheKey(
            contentHash: asset.contentHash,
            url: url
        )
        let buildPlan: @Sendable () async -> SceneRenderPlan? = {
            guard !Task.isCancelled else { return nil }
            let plan = await SceneNativeReadinessCoordinator.shared.renderablePlan(
                for: url,
                cacheKey: probeKey
            )
            guard !Task.isCancelled else { return nil }
            return plan
        }
        return DeferredWallpaperTask.make(
            activationGate: activationGate,
            cancelledValue: nil,
            operation: buildPlan
        )
    }

    private static func fallbackSceneView(
        asset: WallpaperAsset,
        url: URL,
        previewURL: URL?,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        activationGate: DeferredWallpaperActivationGate? = nil,
        retainsNativePlanForBackgroundClassification: Bool = false,
        readinessHandler: @escaping (Bool) -> Void = { _ in }
    ) -> SceneFallback {
        let viewNativePlanTask = fallbackNativePlanTask(
            asset: asset,
            url: url,
            activationGate: activationGate
        )
        let backgroundNativePlanTask = retainsNativePlanForBackgroundClassification
            ? fallbackNativePlanTask(
                asset: asset,
                url: url,
                activationGate: activationGate
            )
            : viewNativePlanTask
        let view = PreparingSceneWallpaperView(
            sceneURL: url,
            previewURL: previewURL,
            frame: frame,
            displayMode: displayMode,
            nativePlanTask: viewNativePlanTask,
            readinessHandler: readinessHandler
        )
        return SceneFallback(view: view, nativePlanTask: backgroundNativePlanTask)
    }

    private static func cachedSceneView(
        asset: WallpaperAsset,
        displayUUID: String,
        sceneURL: URL,
        cachedVideoURL: URL,
        previewURL: URL?,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool,
        audioVolume: Double
    ) throws -> NSView {
        guard let sceneCacheLease = SceneVideoCacheVerifiedGenerationRegistry.shared
            .acquirePlaybackLease(cachedVideoURL) else {
            throw PlaybackError.notPlayable(
                "The verified Scene cache changed before this display could open it."
            )
        }
        let playbackFailure: (String) -> Void = { message in
            recoverFailedCachedScenePlayback(
                asset: asset,
                cacheURL: cachedVideoURL,
                displayUUID: displayUUID,
                message: message
            )
        }
        if CachedSceneWallpaperView.hasClockOverlay(sceneURL: sceneURL),
           let cachedScene = try? CachedSceneWallpaperView(
            sceneURL: sceneURL,
            videoURL: cachedVideoURL,
            fallbackImageURL: previewURL,
            frame: frame,
            displayMode: displayMode,
            audioEnabled: audioEnabled,
            audioVolume: audioVolume,
            sceneCacheLease: sceneCacheLease,
            onPlaybackFailure: playbackFailure
        ) {
            return cachedScene
        }
        return VideoWallpaperView(
            url: cachedVideoURL,
            fallbackImageURL: previewURL,
            frame: frame,
            displayMode: displayMode,
            audioEnabled: audioEnabled,
            audioVolume: audioVolume,
            sceneCacheLease: sceneCacheLease,
            onPlaybackFailure: playbackFailure
        )
    }

    static func recoverFailedCachedScenePlayback(
        asset: WallpaperAsset,
        cacheURL: URL,
        displayUUID: String,
        message: String,
        refreshDisplay: ((String, String) -> Void)? = nil
    ) {
        let path = cacheURL.standardizedFileURL.path
        let isFirstFailure = failedPlaybackCacheGenerations.insert(path).inserted
        if isFirstFailure {
            // Keep every failed pathname tombstoned for this process lifetime.
            // Registry rejection prevents an in-flight SHA verifier from
            // registering it again; active display leases defer unlinking.
            // Do not clear admissions for the whole asset revision here:
            // another display may be verifying a different size/quality key,
            // while an admission containing this generation can skip its
            // tombstoned path and still admit an older verified generation.
            _ = SceneVideoCache.invalidateGeneration(cacheURL)
            let warning = "Cached Scene playback failed; trying an older verified cache or rebuilding it."
            lastDiagnostic = "\(warning) \(message)"
            statusHandler?(warning)
            if let report = asset.compatibilityReport {
                compatibilityReportHandler?(
                    asset,
                    CompatibilityReport(
                        level: .limited,
                        playbackPath: .renderedSceneCache,
                        requiredCapabilities: report.requiredCapabilities,
                        missingCapabilities: report.missingCapabilities,
                        warnings: report.warnings + [warning],
                        diagnosticCode: "scene_cache_playback_failed",
                        probeVersion: report.probeVersion,
                        needsProbe: report.needsProbe
                    )
                )
            }
        }
        if let refreshDisplay {
            refreshDisplay(asset.id, displayUUID)
        } else {
            WallpaperPlayer.shared.refreshIfNeeded(
                afterSceneCachePlaybackFailureFor: asset.id,
                displayUUID: displayUUID
            )
        }
    }

    private static func recoverFailedNativeScene(
        asset: WallpaperAsset,
        displayUUID: String,
        sceneURL: URL,
        previewURL _: URL?,
        cachedVideoURL: URL?,
        preferredCacheKeys: [SceneVideoCacheKey],
        rendererURL: URL?,
        assetsDirectory: URL?,
        ffmpegPath: String?,
        recordSize: CGSize,
        quality: RenderQuality,
        engineAssetsFingerprint: String,
        nativeFallbackPlan: Task<SceneRenderPlan?, Never>
    ) {
        let warning = "Native Scene reconstruction failed; using a rendered fallback."
        lastDiagnostic = warning
        if let cachedVideoURL {
            forcedCachedAssetRevisions.insert(revisionKey(for: asset))
            publishProvisionalCachedReport(
                for: asset,
                sceneURL: sceneURL,
                cacheURL: cachedVideoURL,
                preferredCacheKeys: preferredCacheKeys,
                warning: warning
            )
            WallpaperPlayer.shared.refreshIfNeeded(
                afterSceneVideoRenderFor: asset.id,
                displayUUID: displayUUID
            )
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
            displayUUID: displayUUID,
            sceneURL: sceneURL,
            rendererURL: rendererURL,
            assetsDirectory: assetsDirectory,
            ffmpegPath: ffmpegPath,
            recordSize: recordSize,
            quality: quality,
            engineAssetsFingerprint: engineAssetsFingerprint,
            nativeFallbackPlan: nativeFallbackPlan
        )
    }

    nonisolated static func cachedReport(
        for asset: WallpaperAsset,
        sceneURL: URL,
        cacheURL: URL? = nil,
        audioResult explicitAudioResult: SceneRenderAudioResult? = nil,
        warning: String? = nil
    ) -> CompatibilityReport {
        let analyzed = WallpaperCompatibilityAnalyzer().analyze(
            kind: .scene,
            status: .playable,
            entrypoint: sceneURL,
            projectRoot: URL(filePath: asset.projectDirectory)
        )
        let audioResult = explicitAudioResult
            ?? cacheURL.flatMap { SceneVideoCache.metadata(for: $0)?.audioResult }
        return cachedReport(
            basedOn: analyzed,
            audioResult: audioResult,
            warning: warning
        )
    }

    /// Produces the immediate playback report without touching the Scene
    /// package, cache video, metadata sidecar, or filesystem. A current probe
    /// in the manifest is the persisted feature fingerprint; otherwise the
    /// result deliberately remains Limited until background validation ends.
    nonisolated static func provisionalCachedReport(
        for asset: WallpaperAsset,
        audioResult: SceneRenderAudioResult? = nil,
        warning: String? = nil
    ) -> CompatibilityReport {
        let analyzed = persistedManifestReport(for: asset) ?? CompatibilityReport(
            level: .limited,
            playbackPath: .renderedSceneCache,
            warnings: ["Scene compatibility is being verified in the background."],
            diagnosticCode: "scene_cache_compatibility_pending",
            needsProbe: true
        )
        return cachedReport(
            basedOn: analyzed,
            audioResult: audioResult,
            warning: warning
        )
    }

    nonisolated private static func persistedManifestReport(
        for asset: WallpaperAsset
    ) -> CompatibilityReport? {
        guard let report = asset.compatibilityReport,
              report.probeVersion == CompatibilityReport.currentProbeVersion,
              !report.needsProbe else {
            return nil
        }
        return report
    }

    /// Cache-authored audio diagnostics are runtime overlays, not a static
    /// Scene feature fingerprint. Reusing one as the analysis base would keep
    /// `.sound` missing forever after a later successful rerender, so those
    /// reports must be rebuilt from the package on the utility executor.
    nonisolated private static func persistedStaticSceneReport(
        for asset: WallpaperAsset
    ) -> CompatibilityReport? {
        guard let report = persistedManifestReport(for: asset),
              report.diagnosticCode != "scene_authored_audio_unavailable",
              report.diagnosticCode != "scene_cache_playback_failed",
              !report.missingCapabilities.contains(.sound) else {
            return nil
        }
        return report
    }

    nonisolated private static func cachedReport(
        basedOn analyzed: CompatibilityReport,
        audioResult: SceneRenderAudioResult?,
        warning: String?
    ) -> CompatibilityReport {
        var missingCapabilities = Set(analyzed.missingCapabilities)
        var warnings = analyzed.warnings
        if let warning {
            warnings.append(warning)
        }
        var diagnosticCode = analyzed.diagnosticCode
        let requiresAuthoredAudio = analyzed.requiredCapabilities.contains(.sound)
        if requiresAuthoredAudio {
            switch audioResult?.state {
            case .included:
                break
            case .degraded:
                missingCapabilities.insert(.sound)
                warnings.append(
                    audioResult?.warning
                        ?? "Authored Scene audio is unavailable in the rendered cache."
                )
                diagnosticCode = audioResult?.diagnosticCode
                    ?? "scene_authored_audio_unavailable"
            case .notRequired, .none:
                // Cache version 13+ always writes a sidecar. Missing or
                // contradictory metadata is therefore a fail-closed audio
                // result, not permission to claim Full Cached after relaunch.
                missingCapabilities.insert(.sound)
                warnings.append(
                    "Authored Scene audio could not be verified in the rendered cache."
                )
                diagnosticCode = "scene_authored_audio_unavailable"
            }
        }
        let level: CompatibilityLevel
        if analyzed.level == .unsupported {
            level = .unsupported
        } else if analyzed.level == .limited || !missingCapabilities.isEmpty {
            level = .limited
        } else {
            level = .full
        }
        return CompatibilityReport(
            level: level,
            playbackPath: .renderedSceneCache,
            requiredCapabilities: analyzed.requiredCapabilities,
            missingCapabilities: missingCapabilities.sorted(),
            warnings: warnings,
            diagnosticCode: diagnosticCode,
            probeVersion: analyzed.probeVersion,
            needsProbe: analyzed.needsProbe
        )
    }

    static func publishProvisionalCachedReport(
        for asset: WallpaperAsset,
        sceneURL: URL,
        cacheURL: URL,
        preferredCacheKeys: [SceneVideoCacheKey],
        audioResult: SceneRenderAudioResult? = nil,
        warning: String? = nil
    ) {
        let provisionalReport = provisionalCachedReport(
            for: asset,
            audioResult: audioResult,
            warning: warning
        )
        if provisionalReport != asset.compatibilityReport {
            compatibilityReportHandler?(asset, provisionalReport)
        }

        let persistedReport = persistedStaticSceneReport(for: asset)
        let requiresPackageAnalysis = persistedReport == nil
        let requiresMetadataVerification = audioResult == nil
            && provisionalReport.requiredCapabilities.contains(.sound)
        guard requiresPackageAnalysis || requiresMetadataVerification else {
            // A newer complete outcome makes any older verifier for this URL
            // stale even though there is no replacement task to register.
            cachedReportValidations[cacheURL] = nil
            return
        }
        if cachedReportValidations[cacheURL]?.matches(
            persistedReport: persistedReport,
            explicitAudioResult: audioResult,
            provisionalReport: provisionalReport,
            warning: warning
        ) == true {
            return
        }
        let registration = CachedReportValidationRegistration(
            token: UUID(),
            persistedReport: persistedReport,
            explicitAudioResult: audioResult,
            provisionalReport: provisionalReport,
            warning: warning
        )
        cachedReportValidations[cacheURL] = registration
        let dependencies = cachedReportValidationDependencies
        validateCachedReportInBackground(
            for: asset,
            sceneURL: sceneURL,
            cacheURL: cacheURL,
            preferredCacheKeys: preferredCacheKeys,
            persistedReport: persistedReport,
            explicitAudioResult: audioResult,
            provisionalReport: provisionalReport,
            warning: warning,
            dependencies: dependencies,
            validationToken: registration.token
        )
    }

    private static func validateCachedReportInBackground(
        for asset: WallpaperAsset,
        sceneURL: URL,
        cacheURL: URL,
        preferredCacheKeys: [SceneVideoCacheKey],
        persistedReport: CompatibilityReport?,
        explicitAudioResult: SceneRenderAudioResult?,
        provisionalReport: CompatibilityReport,
        warning: String?,
        dependencies: SceneCachedReportValidationDependencies,
        validationToken: UUID
    ) {
        Task.detached(priority: .utility) {
            let analyzed = persistedReport ?? dependencies.analyzeScene(
                sceneURL,
                URL(filePath: asset.projectDirectory)
            )
            let audioResult: SceneRenderAudioResult?
            if let explicitAudioResult {
                audioResult = explicitAudioResult
            } else if analyzed.requiredCapabilities.contains(.sound) {
                audioResult = await dependencies.cachedAudioResult(cacheURL)
            } else {
                audioResult = nil
            }
            let report = cachedReport(
                basedOn: analyzed,
                audioResult: audioResult,
                warning: warning
            )
            let isCurrent = SceneVideoCache.isCurrentPlaybackCacheURL(
                cacheURL,
                preferredKeys: preferredCacheKeys,
                assetID: asset.id,
                contentHash: asset.contentHash,
                sourceURL: sceneURL
            )
            await MainActor.run {
                guard cachedReportValidations[cacheURL]?.token == validationToken else {
                    return
                }
                defer {
                    if cachedReportValidations[cacheURL]?.token == validationToken {
                        cachedReportValidations[cacheURL] = nil
                    }
                }
                guard isCurrent,
                      SceneVideoCache.isCurrentAdmittedPlaybackCacheURL(
                        cacheURL,
                        preferredKeys: preferredCacheKeys,
                        assetID: asset.id,
                        contentHash: asset.contentHash,
                        sourceURL: sceneURL
                      ) else {
                    return
                }
                // The immediate fail-closed report may already have changed
                // the manifest after `asset` was captured. Deliver any
                // different verified result so a valid sidecar upgrades
                // Limited back to Full Cached without a redundant write when
                // missing/corrupt metadata confirms the provisional report.
                if report != provisionalReport {
                    compatibilityReportHandler?(asset, report)
                }
            }
        }
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
        displayUUID: String,
        sceneURL: URL,
        rendererURL: URL,
        assetsDirectory: URL,
        ffmpegPath: String,
        recordSize: CGSize,
        quality: RenderQuality,
        engineAssetsFingerprint: String,
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
            engineAssetsFingerprint: engineAssetsFingerprint
        )
        let assetId = asset.id
        let lifecycleScope = SceneRenderCoordinator.shared.makeRenderScope()
        Task {
            defer { nativeFallbackPlan.cancel() }
            do {
                let outcome = try await SceneRenderCoordinator.shared.render(
                    configuration: configuration,
                    ffmpegPath: ffmpegPath,
                    lifecycleScope: lifecycleScope,
                    progressHandler: { progress in
                        let percent = Int((progress * 100).rounded())
                        Task { @MainActor in
                            statusHandler?("Reconstructing Scene cache… \(percent)%")
                        }
                    }
                )
                statusHandler?("Playing")
                forcedCachedAssetRevisions.insert(revisionKey(for: asset))
                publishProvisionalCachedReport(
                    for: asset,
                    sceneURL: sceneURL,
                    cacheURL: outcome.cacheURL,
                    preferredCacheKeys: [
                        configuration.cacheKey,
                        configuration.lowQualityFallback.cacheKey
                    ].compactMap { $0 },
                    audioResult: outcome.audioResult
                )
                WallpaperPlayer.shared.refreshIfNeeded(
                    afterSceneVideoRenderFor: assetId,
                    displayUUID: displayUUID
                )
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
