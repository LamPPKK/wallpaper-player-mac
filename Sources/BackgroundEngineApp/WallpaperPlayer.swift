import AppKit
import BackgroundEngineCore
import CryptoKit
import Darwin

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

    /// Delivers a momentary property action to every live display session that
    /// is still running this exact Web asset revision. Unlike scalar edits this
    /// never reconstructs a window, and a same-ID Workshop replacement cannot
    /// receive an event originating from an editor opened on the old revision.
    func dispatchWebButtonEvent(
        _ event: WebWallpaperButtonEvent,
        for asset: WallpaperAsset
    ) async -> Int {
        guard asset.kind == .web,
              asset.supportStatus == .playable,
              !pendingLibraryReplacementAssetIDs.contains(asset.id) else {
            return 0
        }
        let targetWindows: [WallpaperWindow] = appliedDisplaySessions.compactMap {
            displayUUID, session -> WallpaperWindow? in
            guard WallpaperPlaybackRevisionIdentity.matches(session.asset, asset) else {
                return nil
            }
            return windows[displayUUID]
        }
        let deliveries = targetWindows.map { window in
            Task { @MainActor in
                await window.dispatchWebButtonEvent(event)
            }
        }
        defer { deliveries.forEach { $0.cancel() } }
        var delivered = 0
        for delivery in deliveries {
            if Task.isCancelled { return delivered }
            if await delivery.value { delivered += 1 }
        }
        return delivered
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

    @discardableResult
    func dispatchWebButtonEvent(_ event: WebWallpaperButtonEvent) async -> Bool {
        guard let receiver = content as? WebWallpaperButtonEventReceiving else { return false }
        return await receiver.dispatchWebButtonEvent(event)
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
                rendererVersion: SceneRendererTrustAnchor.cacheIdentity,
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
                rendererVersion: SceneRendererTrustAnchor.cacheIdentity,
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
            let renderLease = SceneDisplayRenderLease()
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
                renderLease: renderLease,
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
                            nativeFallbackPlan: nativePlanTask,
                            renderLease: renderLease
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
            let renderLease = SceneDisplayRenderLease()
            let fallback = fallbackSceneView(
                asset: asset,
                url: url,
                previewURL: previewURL,
                frame: frame,
                displayMode: displayMode,
                activationGate: activationGate,
                retainsNativePlanForBackgroundClassification: true,
                renderLease: renderLease
            )
            performAfterActivation(activationGate) {
                let renderTask = scheduleSceneVideoRender(
                    asset: asset,
                    displayUUID: displayUUID,
                    sceneURL: url,
                    rendererURL: rendererURL,
                    assetsDirectory: assetsDirectory,
                    ffmpegPath: ffmpegPath,
                    recordSize: recordSize,
                    quality: quality,
                    engineAssetsFingerprint: engineAssetsFingerprint,
                    nativeFallbackPlan: fallback.nativePlanTask,
                    lifecycleScope: renderLease.lifecycleScope,
                    callbackGate: renderLease.callbackGate
                )
                renderLease.install(renderTask)
                guard !renderLease.isRetired else { return }
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
        renderLease: SceneDisplayRenderLease? = nil,
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
            renderLease: renderLease,
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
        nativeFallbackPlan: Task<SceneRenderPlan?, Never>,
        renderLease: SceneDisplayRenderLease
    ) {
        guard !renderLease.isRetired else { return }
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
            renderLease.performIfActive {
                WallpaperPlayer.shared.refreshIfNeeded(
                    afterSceneVideoRenderFor: asset.id,
                    displayUUID: displayUUID
                )
            }
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
        let renderTask = scheduleSceneVideoRender(
            asset: asset,
            displayUUID: displayUUID,
            sceneURL: sceneURL,
            rendererURL: rendererURL,
            assetsDirectory: assetsDirectory,
            ffmpegPath: ffmpegPath,
            recordSize: recordSize,
            quality: quality,
            engineAssetsFingerprint: engineAssetsFingerprint,
            nativeFallbackPlan: nativeFallbackPlan,
            lifecycleScope: renderLease.lifecycleScope,
            callbackGate: renderLease.callbackGate
        )
        renderLease.install(renderTask)
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
        nativeFallbackPlan: Task<SceneRenderPlan?, Never>,
        lifecycleScope: PlaybackLifecycleScope,
        callbackGate: SceneDisplayRenderCallbackGate
    ) -> Task<Void, Never> {
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
        return Task {
            defer { nativeFallbackPlan.cancel() }
            do {
                let outcome = try await SceneRenderCoordinator.shared.render(
                    configuration: configuration,
                    ffmpegPath: ffmpegPath,
                    lifecycleScope: lifecycleScope,
                    progressHandler: { progress in
                        let percent = Int((progress * 100).rounded())
                        Task { @MainActor in
                            guard callbackGate.isActive else { return }
                            statusHandler?("Reconstructing Scene cache… \(percent)%")
                        }
                    }
                )
                guard !Task.isCancelled, callbackGate.isActive else { return }
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
                guard callbackGate.isActive else { return }
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
                guard !Task.isCancelled, callbackGate.isActive else { return }
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

enum SceneRendererTrustAnchor {
    static let upstreamSourceRef = "7acc6c92e0175d53e1cb6b2b2dff52f79faf83e0"
    static let sourceFingerprint = "0437b46f4d36a80711703cfdb8dcb19bb14e086c37238022abdaae0aced86805"
    static let sourceFileCount = 10_216

    static var cacheIdentity: String {
        "\(SceneVideoCache.rendererVersion)@\(sourceFingerprint)"
    }

    static var nativeApproximationIdentity: String {
        "native-\(SceneVideoCache.rendererVersion)"
    }
}

struct SceneRendererBuildManifest: Equatable, Sendable {
    enum ValidationError: Error, LocalizedError, Equatable {
        case unreadable
        case malformed

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "Renderer build manifest is missing or unreadable."
            case .malformed:
                "Renderer build manifest is malformed."
            }
        }
    }

    static let fileName = "renderer-build-manifest.tsv"
    private static let expectedKeys = [
        "manifest-version",
        "renderer-version",
        "upstream-source-ref",
        "source-fingerprint",
        "source-file-count",
        "architectures",
        "deployment-target",
        "dependency-lock-sha256",
        "dependency-lock-line-count",
        "macho-slice-digests-sha256",
        "macho-slice-digests-line-count"
    ]

    let rendererVersion: String
    let upstreamSourceRef: String
    let sourceFingerprint: String
    let sourceFileCount: Int
    let architectures: [String]
    let deploymentTarget: String
    let dependencyLockSHA256: String
    let dependencyLockLineCount: Int
    let machoSliceDigestsSHA256: String
    let machoSliceDigestsLineCount: Int

    var embeddedProvenanceMarker: String {
        [
            "background-engine-renderer-provenance-v1",
            rendererVersion,
            upstreamSourceRef,
            sourceFingerprint,
            String(sourceFileCount)
        ].joined(separator: "|")
    }

    var supportsMacOS14: Bool {
        let actual = deploymentTarget.split(separator: ".").compactMap { Int($0) }
        let maximum = [14, 0]
        for index in 0..<max(actual.count, maximum.count) {
            let actualPart = index < actual.count ? actual[index] : 0
            let maximumPart = index < maximum.count ? maximum[index] : 0
            if actualPart != maximumPart {
                return actualPart < maximumPart
            }
        }
        return true
    }

    var encodedDeploymentTarget: UInt32? {
        let components = deploymentTarget.split(separator: ".").compactMap { UInt32($0) }
        guard let major = components.first,
              major <= 0xFFFF,
              components.dropFirst().allSatisfy({ $0 <= 0xFF }) else {
            return nil
        }
        let minor = components.count > 1 ? components[1] : 0
        let patch = components.count > 2 ? components[2] : 0
        return (major << 16) | (minor << 8) | patch
    }

    init(contentsOf url: URL) throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw ValidationError.unreadable
        }
        try self.init(data: data)
    }

    init(data: Data) throws {
        guard let source = String(data: data, encoding: .utf8),
              !source.contains("\r") else {
            throw ValidationError.malformed
        }
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.last?.isEmpty == true else {
            throw ValidationError.malformed
        }
        lines.removeLast()
        guard lines.count == Self.expectedKeys.count else {
            throw ValidationError.malformed
        }

        var values: [String] = []
        for (index, line) in lines.enumerated() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  fields[0] == Substring(Self.expectedKeys[index]),
                  !fields[1].isEmpty else {
                throw ValidationError.malformed
            }
            values.append(String(fields[1]))
        }

        guard values[0] == "2",
              Self.isBuildVersion(values[1]),
              Self.isLowercaseHex(values[2], count: 40),
              Self.isLowercaseHex(values[3], count: 64),
              let sourceFileCount = Self.positiveCanonicalInteger(values[4]),
              let architectures = Self.parseArchitectures(values[5]),
              Self.isDeploymentTarget(values[6]),
              Self.isLowercaseHex(values[7], count: 64),
              let dependencyLockLineCount = Self.positiveCanonicalInteger(values[8]),
              Self.isLowercaseHex(values[9], count: 64),
              let machoSliceDigestsLineCount = Self.positiveCanonicalInteger(values[10]) else {
            throw ValidationError.malformed
        }

        rendererVersion = values[1]
        upstreamSourceRef = values[2]
        sourceFingerprint = values[3]
        self.sourceFileCount = sourceFileCount
        self.architectures = architectures
        deploymentTarget = values[6]
        dependencyLockSHA256 = values[7]
        self.dependencyLockLineCount = dependencyLockLineCount
        machoSliceDigestsSHA256 = values[9]
        self.machoSliceDigestsLineCount = machoSliceDigestsLineCount
    }

    private static func isBuildVersion(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count),
              let first = value.utf8.first,
              isASCIIAlphaNumeric(first) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 46 || $0 == 95 || $0 == 45
        }
    }

    private static func isASCIIAlphaNumeric(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func positiveCanonicalInteger(_ value: String) -> Int? {
        guard let parsed = Int(value), parsed > 0, String(parsed) == value else { return nil }
        return parsed
    }

    private static func parseArchitectures(_ value: String) -> [String]? {
        switch value {
        case "arm64": ["arm64"]
        case "x86_64": ["x86_64"]
        case "arm64,x86_64": ["arm64", "x86_64"]
        default: nil
        }
    }

    private static func isDeploymentTarget(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty, component.allSatisfy(\.isNumber),
                  let parsed = Int(component) else {
                return false
            }
            return String(parsed) == component
        }
    }
}

struct SceneRendererMachOSliceDigestInventory: Equatable, Sendable {
    struct Entry: Equatable, Hashable, Sendable {
        let relativePath: String
        let architecture: String
        let sha256: String
    }

    enum ValidationError: Error, Equatable {
        case unreadable
        case malformed
    }

    static let fileName = "macho-slice-digests.tsv"
    private static let maximumEntryCount = 4_096
    private static let maximumByteCount = 1_048_576

    let entries: [Entry]

    init(contentsOf url: URL) throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              (1...Self.maximumByteCount).contains(fileSize),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              !data.isEmpty else {
            throw ValidationError.unreadable
        }
        try self.init(data: data)
    }

    init(data: Data) throws {
        guard (1...Self.maximumByteCount).contains(data.count),
              let source = String(data: data, encoding: .utf8),
              !source.contains("\r") else {
            throw ValidationError.malformed
        }
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.last?.isEmpty == true else { throw ValidationError.malformed }
        lines.removeLast()
        guard (1...Self.maximumEntryCount).contains(lines.count) else {
            throw ValidationError.malformed
        }

        var parsed: [Entry] = []
        parsed.reserveCapacity(lines.count)
        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3 else { throw ValidationError.malformed }
            let entry = Entry(
                relativePath: String(fields[0]),
                architecture: String(fields[1]),
                sha256: String(fields[2])
            )
            guard Self.isCanonicalRuntimePath(entry.relativePath),
                  entry.architecture == "arm64" || entry.architecture == "x86_64",
                  Self.isLowercaseSHA256(entry.sha256) else {
                throw ValidationError.malformed
            }
            if let previous = parsed.last,
               !Self.canonicalOrder(previous, entry) {
                throw ValidationError.malformed
            }
            parsed.append(entry)
        }
        entries = parsed
    }

    var entriesByPath: [String: [Entry]] {
        Dictionary(grouping: entries, by: \.relativePath)
    }

    private static func canonicalOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.relativePath != rhs.relativePath {
            return lhs.relativePath.utf8.lexicographicallyPrecedes(rhs.relativePath.utf8)
        }
        let lhsRank = lhs.architecture == "arm64" ? 0 : 1
        let rhsRank = rhs.architecture == "arm64" ? 0 : 1
        return lhsRank < rhsRank
    }

    static func isCanonicalRuntimePath(_ path: String) -> Bool {
        if path == "background-engine-scene-renderer" { return true }
        guard path.hasPrefix("lib/"),
              path.dropFirst(4).allSatisfy({ $0 != "/" }) else {
            return false
        }
        let basename = String(path.dropFirst(4))
        guard (1...255).contains(basename.utf8.count),
              basename.hasSuffix(".dylib"),
              let first = basename.utf8.first,
              isASCIIAlphaNumeric(first) else {
            return false
        }
        return basename.utf8.allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 46 || $0 == 95 || $0 == 43 || $0 == 45
        }
    }

    private static func isASCIIAlphaNumeric(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

struct SceneRendererMachOSliceDigests: Equatable, Sendable {
    enum ValidationError: Error, Equatable {
        case malformed
    }

    private static let machOMagic64: UInt32 = 0xFEED_FACF
    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatMagic64: UInt32 = 0xCAFE_BABF
    private static let executableFileType: UInt32 = 0x2
    private static let dynamicLibraryFileType: UInt32 = 0x6
    private static let x86_64CPUType: UInt32 = 0x0100_0007
    private static let arm64CPUType: UInt32 = 0x0100_000C
    private static let machOHeader64Size = 32

    let digestsByArchitecture: [String: String]

    init(data: Data) throws {
        guard data.count >= Self.machOHeader64Size else {
            throw ValidationError.malformed
        }
        if try Self.readUInt32LittleEndian(data, at: 0) == Self.machOMagic64 {
            let architecture = try Self.validateThinSlice(
                data,
                range: 0..<data.count,
                expectedArchitecture: nil
            )
            digestsByArchitecture = [architecture: Self.sha256(data)]
            return
        }

        let fatHeaderMagic = try Self.readUInt32BigEndian(data, at: 0)
        let entrySize: Int
        switch fatHeaderMagic {
        case Self.fatMagic:
            entrySize = 20
        case Self.fatMagic64:
            entrySize = 32
        default:
            throw ValidationError.malformed
        }
        let sliceCount = Int(try Self.readUInt32BigEndian(data, at: 4))
        guard (1...2).contains(sliceCount),
              entrySize <= (data.count - 8) / sliceCount else {
            throw ValidationError.malformed
        }
        let tableEnd = 8 + (sliceCount * entrySize)
        var slices: [(architecture: String, range: Range<Int>)] = []
        var architectures = Set<String>()
        for index in 0..<sliceCount {
            let entryOffset = 8 + (index * entrySize)
            guard let architecture = Self.architecture(
                for: try Self.readUInt32BigEndian(data, at: entryOffset)
            ), architectures.insert(architecture).inserted else {
                throw ValidationError.malformed
            }
            let sliceOffset: Int
            let sliceSize: Int
            let alignmentPower: UInt32
            if entrySize == 20 {
                sliceOffset = Int(try Self.readUInt32BigEndian(data, at: entryOffset + 8))
                sliceSize = Int(try Self.readUInt32BigEndian(data, at: entryOffset + 12))
                alignmentPower = try Self.readUInt32BigEndian(data, at: entryOffset + 16)
            } else {
                sliceOffset = try Self.int(
                    try Self.readUInt64BigEndian(data, at: entryOffset + 8)
                )
                sliceSize = try Self.int(
                    try Self.readUInt64BigEndian(data, at: entryOffset + 16)
                )
                alignmentPower = try Self.readUInt32BigEndian(data, at: entryOffset + 24)
            }
            guard alignmentPower <= 31 else { throw ValidationError.malformed }
            let alignment = 1 << Int(alignmentPower)
            guard sliceOffset >= tableEnd,
                  sliceOffset.isMultiple(of: alignment),
                  sliceSize >= Self.machOHeader64Size else {
                throw ValidationError.malformed
            }
            let range = try Self.checkedRange(
                offset: sliceOffset,
                length: sliceSize,
                upperBound: data.count
            )
            slices.append((architecture, range))
        }

        let ordered = slices.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for index in 1..<ordered.count {
            guard ordered[index - 1].range.upperBound <= ordered[index].range.lowerBound else {
                throw ValidationError.malformed
            }
        }
        var parsed: [String: String] = [:]
        for slice in slices {
            let architecture = try Self.validateThinSlice(
                data,
                range: slice.range,
                expectedArchitecture: slice.architecture
            )
            let bytes = data.subdata(in: slice.range)
            guard parsed.updateValue(Self.sha256(bytes), forKey: architecture) == nil else {
                throw ValidationError.malformed
            }
        }
        guard parsed.count == sliceCount else { throw ValidationError.malformed }
        digestsByArchitecture = parsed
    }

    private static func validateThinSlice(
        _ data: Data,
        range: Range<Int>,
        expectedArchitecture: String?
    ) throws -> String {
        guard range.count >= machOHeader64Size,
              try readUInt32LittleEndian(data, at: range.lowerBound) == machOMagic64,
              let architecture = architecture(
                  for: try readUInt32LittleEndian(data, at: range.lowerBound + 4)
              ),
              expectedArchitecture == nil || expectedArchitecture == architecture else {
            throw ValidationError.malformed
        }
        let fileType = try readUInt32LittleEndian(data, at: range.lowerBound + 12)
        guard fileType == executableFileType || fileType == dynamicLibraryFileType else {
            throw ValidationError.malformed
        }
        return architecture
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func architecture(for cpuType: UInt32) -> String? {
        switch cpuType {
        case arm64CPUType: "arm64"
        case x86_64CPUType: "x86_64"
        default: nil
        }
    }

    private static func checkedRange(
        offset: Int,
        length: Int,
        upperBound: Int
    ) throws -> Range<Int> {
        guard offset >= 0,
              length >= 0,
              offset <= upperBound,
              length <= upperBound - offset else {
            throw ValidationError.malformed
        }
        return offset..<(offset + length)
    }

    private static func int(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else { throw ValidationError.malformed }
        return Int(value)
    }

    private static func readUInt32LittleEndian(_ data: Data, at offset: Int) throws -> UInt32 {
        let range = try checkedRange(offset: offset, length: 4, upperBound: data.count)
        return data[range].enumerated().reduce(into: UInt32(0)) { value, element in
            value |= UInt32(element.element) << UInt32(element.offset * 8)
        }
    }

    private static func readUInt32BigEndian(_ data: Data, at offset: Int) throws -> UInt32 {
        let range = try checkedRange(offset: offset, length: 4, upperBound: data.count)
        return data[range].reduce(into: UInt32(0)) { value, byte in
            value = (value << 8) | UInt32(byte)
        }
    }

    private static func readUInt64BigEndian(_ data: Data, at offset: Int) throws -> UInt64 {
        let range = try checkedRange(offset: offset, length: 8, upperBound: data.count)
        return data[range].reduce(into: UInt64(0)) { value, byte in
            value = (value << 8) | UInt64(byte)
        }
    }
}

struct SceneRendererMachOProvenance: Equatable, Sendable {
    enum ValidationError: Error, Equatable {
        case malformed
    }

    private static let machOMagic64: UInt32 = 0xFEED_FACF
    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatMagic64: UInt32 = 0xCAFE_BABF
    private static let segment64Command: UInt32 = 0x19
    private static let versionMinMacOSCommand: UInt32 = 0x24
    private static let buildVersionCommand: UInt32 = 0x32
    private static let macOSPlatform: UInt32 = 1
    private static let executableFileType: UInt32 = 0x2
    private static let x86_64CPUType: UInt32 = 0x0100_0007
    private static let arm64CPUType: UInt32 = 0x0100_000C
    private static let machOHeader64Size = 32
    private static let segmentCommand64Size = 72
    private static let section64Size = 80
    private static let maximumLoadCommandCount = 4_096
    private static let maximumMarkerSize = 512

    let markersByArchitecture: [String: String]
    let minimumMacOSByArchitecture: [String: UInt32]

    init(data: Data) throws {
        guard data.count >= 4 else { throw ValidationError.malformed }
        if try Self.readUInt32LittleEndian(data, at: 0) == Self.machOMagic64 {
            let slice = try Self.parseSlice(
                data,
                offset: 0,
                size: data.count,
                expectedArchitecture: nil
            )
            markersByArchitecture = [slice.architecture: slice.marker]
            minimumMacOSByArchitecture = [slice.architecture: slice.minimumMacOS]
            return
        }

        let fatHeaderMagic = try Self.readUInt32BigEndian(data, at: 0)
        let entrySize: Int
        switch fatHeaderMagic {
        case Self.fatMagic:
            entrySize = 20
        case Self.fatMagic64:
            entrySize = 32
        default:
            throw ValidationError.malformed
        }

        let sliceCount = Int(try Self.readUInt32BigEndian(data, at: 4))
        guard (1...2).contains(sliceCount),
              entrySize <= (data.count - 8) / sliceCount else {
            throw ValidationError.malformed
        }
        let tableEnd = 8 + (sliceCount * entrySize)
        var slices: [(architecture: String, offset: Int, size: Int)] = []
        var declaredArchitectures = Set<String>()
        for index in 0..<sliceCount {
            let entryOffset = 8 + (index * entrySize)
            let cpuType = try Self.readUInt32BigEndian(data, at: entryOffset)
            guard let architecture = Self.architecture(for: cpuType),
                  declaredArchitectures.insert(architecture).inserted else {
                throw ValidationError.malformed
            }

            let sliceOffset: Int
            let sliceSize: Int
            let alignmentPower: UInt32
            if entrySize == 20 {
                sliceOffset = Int(try Self.readUInt32BigEndian(data, at: entryOffset + 8))
                sliceSize = Int(try Self.readUInt32BigEndian(data, at: entryOffset + 12))
                alignmentPower = try Self.readUInt32BigEndian(data, at: entryOffset + 16)
            } else {
                sliceOffset = try Self.int(
                    try Self.readUInt64BigEndian(data, at: entryOffset + 8)
                )
                sliceSize = try Self.int(
                    try Self.readUInt64BigEndian(data, at: entryOffset + 16)
                )
                alignmentPower = try Self.readUInt32BigEndian(data, at: entryOffset + 24)
            }
            guard alignmentPower <= 31 else { throw ValidationError.malformed }
            let alignment = 1 << Int(alignmentPower)
            guard sliceOffset >= tableEnd,
                  sliceOffset.isMultiple(of: alignment),
                  sliceSize >= Self.machOHeader64Size else {
                throw ValidationError.malformed
            }
            _ = try Self.checkedRange(
                offset: sliceOffset,
                length: sliceSize,
                upperBound: data.count
            )
            slices.append((architecture, sliceOffset, sliceSize))
        }

        let orderedSlices = slices.sorted { $0.offset < $1.offset }
        for index in 1..<orderedSlices.count {
            let previous = orderedSlices[index - 1]
            guard previous.size <= orderedSlices[index].offset - previous.offset else {
                throw ValidationError.malformed
            }
        }

        var parsedMarkers: [String: String] = [:]
        var parsedMinimumMacOS: [String: UInt32] = [:]
        for slice in slices {
            let parsed = try Self.parseSlice(
                data,
                offset: slice.offset,
                size: slice.size,
                expectedArchitecture: slice.architecture
            )
            guard parsedMarkers.updateValue(parsed.marker, forKey: parsed.architecture) == nil else {
                throw ValidationError.malformed
            }
            guard parsedMinimumMacOS.updateValue(
                parsed.minimumMacOS,
                forKey: parsed.architecture
            ) == nil else {
                throw ValidationError.malformed
            }
        }
        guard parsedMarkers.count == sliceCount else { throw ValidationError.malformed }
        markersByArchitecture = parsedMarkers
        minimumMacOSByArchitecture = parsedMinimumMacOS
    }

    private static func parseSlice(
        _ data: Data,
        offset sliceOffset: Int,
        size sliceSize: Int,
        expectedArchitecture: String?
    ) throws -> (architecture: String, marker: String, minimumMacOS: UInt32) {
        let sliceRange = try checkedRange(
            offset: sliceOffset,
            length: sliceSize,
            upperBound: data.count
        )
        guard sliceSize >= machOHeader64Size,
              try readUInt32LittleEndian(data, at: sliceOffset) == machOMagic64,
              try readUInt32LittleEndian(data, at: sliceOffset + 12) == executableFileType,
              let architecture = architecture(
                  for: try readUInt32LittleEndian(data, at: sliceOffset + 4)
              ),
              expectedArchitecture == nil || expectedArchitecture == architecture else {
            throw ValidationError.malformed
        }

        let loadCommandCount = Int(try readUInt32LittleEndian(data, at: sliceOffset + 16))
        let loadCommandBytes = Int(try readUInt32LittleEndian(data, at: sliceOffset + 20))
        let loadCommandsOffset = sliceOffset + machOHeader64Size
        guard (1...maximumLoadCommandCount).contains(loadCommandCount),
              loadCommandCount <= loadCommandBytes / 8,
              loadCommandBytes <= sliceRange.upperBound - loadCommandsOffset else {
            throw ValidationError.malformed
        }
        let loadCommandsEnd = loadCommandsOffset + loadCommandBytes
        var cursor = loadCommandsOffset
        var marker: String?
        var minimumMacOS: UInt32?

        for _ in 0..<loadCommandCount {
            guard cursor <= loadCommandsEnd - 8 else { throw ValidationError.malformed }
            let command = try readUInt32LittleEndian(data, at: cursor)
            let commandSize = Int(try readUInt32LittleEndian(data, at: cursor + 4))
            guard commandSize >= 8,
                  commandSize <= loadCommandsEnd - cursor else {
                throw ValidationError.malformed
            }

            if command == segment64Command {
                guard commandSize >= segmentCommand64Size else {
                    throw ValidationError.malformed
                }
                let sectionCount = Int(try readUInt32LittleEndian(data, at: cursor + 64))
                guard sectionCount <= (commandSize - segmentCommand64Size) / section64Size,
                      commandSize == segmentCommand64Size + (sectionCount * section64Size) else {
                    throw ValidationError.malformed
                }
                let segmentName = try fixedCString(data, at: cursor + 8, count: 16)
                for sectionIndex in 0..<sectionCount {
                    let sectionOffset = cursor + segmentCommand64Size
                        + (sectionIndex * section64Size)
                    let sectionName = try fixedCString(data, at: sectionOffset, count: 16)
                    guard sectionName == "__be_provenance" else { continue }
                    guard marker == nil,
                          segmentName == "__TEXT",
                          try fixedCString(data, at: sectionOffset + 16, count: 16) == "__TEXT" else {
                        throw ValidationError.malformed
                    }
                    let markerSize = try int(
                        try readUInt64LittleEndian(data, at: sectionOffset + 40)
                    )
                    let markerOffset = Int(
                        try readUInt32LittleEndian(data, at: sectionOffset + 48)
                    )
                    guard (1...maximumMarkerSize).contains(markerSize),
                          markerOffset >= machOHeader64Size + loadCommandBytes else {
                        throw ValidationError.malformed
                    }
                    let markerRangeInSlice = try checkedRange(
                        offset: markerOffset,
                        length: markerSize,
                        upperBound: sliceSize
                    )
                    let absoluteMarkerRange = (sliceOffset + markerRangeInSlice.lowerBound)..<(
                        sliceOffset + markerRangeInSlice.upperBound
                    )
                    marker = try decodeMarker(data.subdata(in: absoluteMarkerRange))
                }
            } else if command == buildVersionCommand {
                guard minimumMacOS == nil,
                      commandSize >= 24,
                      try readUInt32LittleEndian(data, at: cursor + 8) == macOSPlatform else {
                    throw ValidationError.malformed
                }
                let toolCount = Int(try readUInt32LittleEndian(data, at: cursor + 20))
                guard toolCount <= (commandSize - 24) / 8,
                      commandSize == 24 + (toolCount * 8) else {
                    throw ValidationError.malformed
                }
                minimumMacOS = try readUInt32LittleEndian(data, at: cursor + 12)
            } else if command == versionMinMacOSCommand {
                guard minimumMacOS == nil, commandSize == 16 else {
                    throw ValidationError.malformed
                }
                minimumMacOS = try readUInt32LittleEndian(data, at: cursor + 8)
            }
            cursor += commandSize
        }

        guard cursor == loadCommandsEnd, let marker, let minimumMacOS else {
            throw ValidationError.malformed
        }
        return (architecture, marker, minimumMacOS)
    }

    private static func decodeMarker(_ data: Data) throws -> String {
        guard let terminator = data.firstIndex(of: 0),
              terminator > data.startIndex,
              data[data.index(after: terminator)...].allSatisfy({ $0 == 0 }) else {
            throw ValidationError.malformed
        }
        let bytes = data[..<terminator]
        guard bytes.allSatisfy({ (32...126).contains($0) }),
              let marker = String(data: bytes, encoding: .utf8) else {
            throw ValidationError.malformed
        }
        return marker
    }

    private static func fixedCString(_ data: Data, at offset: Int, count: Int) throws -> String {
        let range = try checkedRange(offset: offset, length: count, upperBound: data.count)
        let bytes = data.subdata(in: range)
        let terminator = bytes.firstIndex(of: 0) ?? bytes.endIndex
        guard bytes[terminator...].allSatisfy({ $0 == 0 }),
              bytes[..<terminator].allSatisfy({ (32...126).contains($0) }),
              let value = String(data: bytes[..<terminator], encoding: .utf8) else {
            throw ValidationError.malformed
        }
        return value
    }

    private static func architecture(for cpuType: UInt32) -> String? {
        switch cpuType {
        case arm64CPUType: "arm64"
        case x86_64CPUType: "x86_64"
        default: nil
        }
    }

    private static func checkedRange(
        offset: Int,
        length: Int,
        upperBound: Int
    ) throws -> Range<Int> {
        guard offset >= 0,
              length >= 0,
              offset <= upperBound,
              length <= upperBound - offset else {
            throw ValidationError.malformed
        }
        return offset..<(offset + length)
    }

    private static func int(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else { throw ValidationError.malformed }
        return Int(value)
    }

    private static func readUInt32LittleEndian(_ data: Data, at offset: Int) throws -> UInt32 {
        let range = try checkedRange(offset: offset, length: 4, upperBound: data.count)
        return data[range].enumerated().reduce(into: UInt32(0)) { value, element in
            value |= UInt32(element.element) << UInt32(element.offset * 8)
        }
    }

    private static func readUInt32BigEndian(_ data: Data, at offset: Int) throws -> UInt32 {
        let range = try checkedRange(offset: offset, length: 4, upperBound: data.count)
        return data[range].reduce(into: UInt32(0)) { value, byte in
            value = (value << 8) | UInt32(byte)
        }
    }

    private static func readUInt64LittleEndian(_ data: Data, at offset: Int) throws -> UInt64 {
        let range = try checkedRange(offset: offset, length: 8, upperBound: data.count)
        return data[range].enumerated().reduce(into: UInt64(0)) { value, element in
            value |= UInt64(element.element) << UInt64(element.offset * 8)
        }
    }

    private static func readUInt64BigEndian(_ data: Data, at offset: Int) throws -> UInt64 {
        let range = try checkedRange(offset: offset, length: 8, upperBound: data.count)
        return data[range].reduce(into: UInt64(0)) { value, byte in
            value = (value << 8) | UInt64(byte)
        }
    }
}

/// A fresh, content-free identity of the exact tree accepted by the renderer
/// inventory gate. URL resource values may be cached, and size/mtime alone miss
/// in-place writes that restore mtime, so inspect each path with lstat including
/// nanosecond ctime. Aliases are recorded without following them.
struct SceneRendererRuntimeFileSystemSnapshot: Equatable {
    private struct Metadata: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let owner: uid_t
        let group: gid_t
        let linkCount: nlink_t
        let size: off_t
        let flags: UInt32
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        var isDirectory: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
        var isRegularFile: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
        var isSymbolicLink: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFLNK) }

        init?(url: URL) {
            var info = stat()
            guard url.withUnsafeFileSystemRepresentation({ path in
                guard let path else { return false }
                return Darwin.lstat(path, &info) == 0
            }) else { return nil }
            device = info.st_dev
            inode = info.st_ino
            mode = info.st_mode
            owner = info.st_uid
            group = info.st_gid
            linkCount = info.st_nlink
            size = info.st_size
            flags = info.st_flags
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    private struct Entry: Equatable {
        let metadata: Metadata
        let symbolicLinkDestination: String?

        init?(url: URL) {
            guard let metadata = Metadata(url: url) else { return nil }
            self.metadata = metadata
            if metadata.isSymbolicLink {
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(
                    atPath: url.path
                ), Metadata(url: url) == metadata else { return nil }
                symbolicLinkDestination = destination
            } else {
                symbolicLinkDestination = nil
            }
        }
    }

    private let entries: [String: Entry]

    static func capture(executableURL: URL) -> Self? {
        let runtimeDirectory = executableURL.deletingLastPathComponent().standardizedFileURL
        guard let root = Entry(url: runtimeDirectory), root.metadata.isDirectory,
              let topLevelNames = try? FileManager.default.contentsOfDirectory(
                atPath: runtimeDirectory.path
              ) else { return nil }
        var entries: [String: Entry] = [".": root]
        for name in topLevelNames {
            guard let entry = Entry(url: runtimeDirectory.appending(path: name)) else {
                return nil
            }
            if name == "lib" {
                guard entry.metadata.isDirectory else { return nil }
            } else {
                guard entry.metadata.isRegularFile || entry.metadata.isSymbolicLink else {
                    return nil
                }
            }
            entries[name] = entry
        }

        let libraryDirectory = runtimeDirectory.appending(path: "lib", directoryHint: .isDirectory)
        guard let libraryRoot = entries["lib"], libraryRoot.metadata.isDirectory,
              let libraryNames = try? FileManager.default.contentsOfDirectory(
                atPath: libraryDirectory.path
              ) else { return nil }
        for name in libraryNames {
            guard let entry = Entry(url: libraryDirectory.appending(path: name)),
                  entry.metadata.isRegularFile || entry.metadata.isSymbolicLink else {
                return nil
            }
            entries["lib/\(name)"] = entry
        }
        // Adding, removing, or replacing entries during enumeration must not
        // produce a reusable mixed snapshot of the old and new directories.
        guard Metadata(url: runtimeDirectory) == root.metadata,
              Metadata(url: libraryDirectory) == libraryRoot.metadata else { return nil }
        return Self(entries: entries)
    }
}

/// Keeps the expensive inventory/hash/provenance gate off repeated health
/// queries only while every observed filesystem identity is unchanged.
struct SceneRendererRuntimeValidationCache<Value> {
    private var entry: (
        executableURL: URL,
        snapshot: SceneRendererRuntimeFileSystemSnapshot,
        value: Value
    )?

    mutating func resolve(
        executableURL: URL,
        validate: () throws -> Value,
        isSuccessful: (Value) -> Bool
    ) rethrows -> Value {
        let executableURL = executableURL.standardizedFileURL
        let before = SceneRendererRuntimeFileSystemSnapshot.capture(executableURL: executableURL)
        if let before, let entry,
           entry.executableURL == executableURL, entry.snapshot == before {
            return entry.value
        }
        entry = nil
        let value = try validate()
        if isSuccessful(value), let before,
           let after = SceneRendererRuntimeFileSystemSnapshot.capture(executableURL: executableURL),
           before == after {
            entry = (executableURL, after, value)
        }
        return value
    }
}

@MainActor
enum SceneEngineRendererConfiguration {
    private enum Resolution {
        case available(URL, SceneRendererBuildManifest?)
        case missing(String)
        case invalid(String)

        var executableURL: URL? {
            guard case .available(let url, _) = self else { return nil }
            return url
        }

        var health: RuntimeComponentHealth {
            switch self {
            case .available(let url, let manifest):
                return RuntimeComponentHealth(
                    availability: .available,
                    version: manifest?.rendererVersion ?? SceneVideoCache.rendererVersion,
                    detail: manifest == nil
                        ? "Explicit DEBUG Scene renderer override is ready: \(url.lastPathComponent)"
                        : "Bundled Universal Scene renderer is ready: \(url.lastPathComponent)"
                )
            case .missing(let detail):
                return RuntimeComponentHealth(
                    availability: .missing,
                    version: SceneVideoCache.rendererVersion,
                    detail: detail
                )
            case .invalid(let detail):
                return RuntimeComponentHealth(
                    availability: .invalid,
                    version: SceneVideoCache.rendererVersion,
                    detail: detail
                )
            }
        }
    }

    static let environmentVariableName = "BACKGROUND_ENGINE_SCENE_RENDERER"
    static let assetsEnvironmentVariableName = "BACKGROUND_ENGINE_SCENE_ASSETS_DIR"
    static var overrideExecutablePath: String?
    static var overrideAssetsPath: String?
    static var overrideResourceURL: URL?
    static var overrideDefaultAssetsDirectoryURL: URL?
    // Build/embed/install tools can change Bundle.main in place. Reuse successful
    // validation only while its exact runtime tree has the same fresh filesystem
    // identities. Configured and test runtimes still run the full gate each time.
    private static var validatedBundledRuntimeCache = SceneRendererRuntimeValidationCache<Resolution>()

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
        resolve(environment: environment).executableURL
    }

    static func runtimeHealth(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RuntimeComponentHealth {
        resolve(environment: environment).health
    }

    private static func resolve(environment: [String: String]) -> Resolution {
        #if DEBUG
        if let path = overrideExecutablePath, !path.isEmpty {
            let url = URL(filePath: path).standardizedFileURL
            if isRegularExecutable(url) {
                return .available(url, nil)
            }
        }
        if let path = environment[environmentVariableName], !path.isEmpty {
            let url = URL(filePath: path).standardizedFileURL
            if isRegularExecutable(url) {
                return validatedRuntime(
                    executableURL: url,
                    origin: "Configured Scene renderer",
                    requiresUniversalBinary: false
                )
            }
        }
        #endif
        let rendererResourceURL: URL
        let permitsSuccessfulValidationCache: Bool
        if let overrideResourceURL {
            rendererResourceURL = overrideResourceURL
            permitsSuccessfulValidationCache = false
        } else {
            guard let resourceURL = Bundle.main.resourceURL else {
                return .missing("Bundled Scene renderer resources are unavailable.")
            }
            rendererResourceURL = resourceURL
            permitsSuccessfulValidationCache = true
        }
        let bundledURL = rendererResourceURL
            .appending(path: "Renderers")
            .appending(path: "background-engine-scene-renderer")
            .standardizedFileURL
        if permitsSuccessfulValidationCache {
            return validatedBundledRuntimeCache.resolve(
                executableURL: bundledURL,
                validate: { validatedBundledRuntime(executableURL: bundledURL) },
                isSuccessful: { $0.executableURL != nil }
            )
        }
        return validatedBundledRuntime(executableURL: bundledURL)
    }

    private static func validatedBundledRuntime(executableURL: URL) -> Resolution {
        guard isRegularExecutable(executableURL) else {
            return .missing("Bundled Scene renderer is missing or not executable.")
        }
        return validatedRuntime(
            executableURL: executableURL,
            origin: "Bundled Scene renderer",
            requiresUniversalBinary: true
        )
    }

    private static func validatedRuntime(
        executableURL: URL,
        origin: String,
        requiresUniversalBinary: Bool
    ) -> Resolution {
        let manifestURL = executableURL.deletingLastPathComponent()
            .appending(path: SceneRendererBuildManifest.fileName)
        let manifest: SceneRendererBuildManifest
        do {
            manifest = try SceneRendererBuildManifest(contentsOf: manifestURL)
        } catch {
            return .invalid("\(origin) build manifest is missing or malformed.")
        }
        guard manifest.rendererVersion == SceneVideoCache.rendererVersion else {
            return .invalid(
                "\(origin) version \(manifest.rendererVersion) does not match required version "
                    + "\(SceneVideoCache.rendererVersion)."
            )
        }
        guard manifest.upstreamSourceRef == SceneRendererTrustAnchor.upstreamSourceRef,
              manifest.sourceFingerprint == SceneRendererTrustAnchor.sourceFingerprint,
              manifest.sourceFileCount == SceneRendererTrustAnchor.sourceFileCount else {
            return .invalid("\(origin) source provenance does not match this app build.")
        }
        guard manifest.architectures.contains(currentArchitecture) else {
            return .invalid(
                "\(origin) build manifest does not include the current \(currentArchitecture) architecture."
            )
        }
        if requiresUniversalBinary,
           manifest.architectures != ["arm64", "x86_64"] {
            return .invalid("\(origin) build manifest is not Universal arm64/x86_64.")
        }
        guard manifest.supportsMacOS14 else {
            return .invalid(
                "\(origin) requires macOS \(manifest.deploymentTarget), above the supported macOS 14 target."
            )
        }
        let dependencyLockURL = executableURL.deletingLastPathComponent()
            .appending(path: "dependencies.lock.tsv")
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: dependencyLockURL.path)) == nil,
              let lockValues = try? dependencyLockURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              lockValues.isRegularFile == true,
              lockValues.isSymbolicLink != true,
              let dependencyLock = try? Data(contentsOf: dependencyLockURL, options: [.mappedIfSafe]),
              !dependencyLock.isEmpty else {
            return .invalid("\(origin) dependency lock is missing or unsafe.")
        }
        let dependencyLockDigest = SHA256.hash(data: dependencyLock)
            .map { String(format: "%02x", $0) }
            .joined()
        let newlineCount = dependencyLock.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        let dependencyLockLineCount = newlineCount + (dependencyLock.last == 0x0A ? 0 : 1)
        guard dependencyLockDigest == manifest.dependencyLockSHA256,
              dependencyLockLineCount == manifest.dependencyLockLineCount else {
            return .invalid("\(origin) dependency lock does not match its build manifest.")
        }
        if let digestInventoryError = validateMachODigestInventory(
            executableURL: executableURL,
            manifest: manifest,
            origin: origin
        ) {
            return .invalid(digestInventoryError)
        }
        let executableData: Data
        let executableProvenance: SceneRendererMachOProvenance
        do {
            executableData = try Data(contentsOf: executableURL, options: [.mappedIfSafe])
            executableProvenance = try SceneRendererMachOProvenance(data: executableData)
        } catch {
            return .invalid("\(origin) is not a valid provenance-bound Mach-O executable.")
        }
        guard Set(executableProvenance.markersByArchitecture.keys) == Set(manifest.architectures),
              executableProvenance.markersByArchitecture.values.allSatisfy({
                  $0 == manifest.embeddedProvenanceMarker
              }) else {
            return .invalid("\(origin) embedded provenance does not match its build manifest.")
        }
        guard let encodedDeploymentTarget = manifest.encodedDeploymentTarget,
              Set(executableProvenance.minimumMacOSByArchitecture.keys)
                == Set(manifest.architectures),
              executableProvenance.minimumMacOSByArchitecture.values.allSatisfy({
                  $0 == encodedDeploymentTarget && $0 <= 0x000E_0000
              }) else {
            return .invalid("\(origin) Mach-O minimum macOS does not match its build manifest.")
        }
        return .available(executableURL, manifest)
    }

    private static func validateMachODigestInventory(
        executableURL: URL,
        manifest: SceneRendererBuildManifest,
        origin: String
    ) -> String? {
        let runtimeDirectory = executableURL.deletingLastPathComponent()
        let inventoryURL = runtimeDirectory.appending(
            path: SceneRendererMachOSliceDigestInventory.fileName
        )
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: inventoryURL.path)) == nil,
              let inventoryValues = try? inventoryURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              inventoryValues.isRegularFile == true,
              inventoryValues.isSymbolicLink != true,
              let inventoryFileSize = inventoryValues.fileSize,
              (1...1_048_576).contains(inventoryFileSize),
              let inventoryData = try? Data(contentsOf: inventoryURL, options: [.mappedIfSafe]),
              !inventoryData.isEmpty else {
            return "\(origin) Mach-O slice digest inventory is missing or unsafe."
        }
        let inventoryDigest = SHA256.hash(data: inventoryData)
            .map { String(format: "%02x", $0) }
            .joined()
        let newlineCount = inventoryData.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        guard inventoryData.last == 0x0A,
              inventoryDigest == manifest.machoSliceDigestsSHA256,
              newlineCount == manifest.machoSliceDigestsLineCount else {
            return "\(origin) Mach-O slice digest inventory does not match its build manifest."
        }

        let inventory: SceneRendererMachOSliceDigestInventory
        do {
            inventory = try SceneRendererMachOSliceDigestInventory(data: inventoryData)
        } catch {
            return "\(origin) Mach-O slice digest inventory is malformed."
        }
        let entriesByPath = inventory.entriesByPath
        let expectedTopLevelNames: Set<String> = [
            "background-engine-scene-renderer",
            "dependencies.lock.tsv",
            SceneRendererBuildManifest.fileName,
            SceneRendererMachOSliceDigestInventory.fileName,
            "lib"
        ]
        guard let topLevelContents = try? FileManager.default.contentsOfDirectory(
            at: runtimeDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isDirectoryKey
            ]
        ), Set(topLevelContents.map(\.lastPathComponent)) == expectedTopLevelNames else {
            return "\(origin) runtime contains an unexpected or missing top-level entry."
        }
        for candidate in topLevelContents {
            guard let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
            ), values.isSymbolicLink != true else {
                return "\(origin) runtime contains an unsafe top-level entry."
            }
            if candidate.lastPathComponent == "lib" {
                guard values.isDirectory == true else {
                    return "\(origin) Mach-O library directory is missing or unsafe."
                }
            } else if values.isRegularFile != true {
                return "\(origin) runtime metadata contains a non-regular top-level entry."
            }
        }

        var physicalPaths: Set<String> = ["background-engine-scene-renderer"]
        let libraryDirectory = runtimeDirectory.appending(path: "lib", directoryHint: .isDirectory)
        var libraryDirectoryIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: libraryDirectory.path,
            isDirectory: &libraryDirectoryIsDirectory
        ), libraryDirectoryIsDirectory.boolValue,
              (try? FileManager.default.destinationOfSymbolicLink(
                atPath: libraryDirectory.path
              )) == nil,
              let libraryValues = try? libraryDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              libraryValues.isDirectory == true,
              libraryValues.isSymbolicLink != true,
              let libraryContents = try? FileManager.default.contentsOfDirectory(
                at: libraryDirectory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .isDirectoryKey
                ]
              ) else {
            return "\(origin) Mach-O library directory is missing or unsafe."
        }
        for candidate in libraryContents {
            guard let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
            ) else {
                return "\(origin) Mach-O library inventory cannot inspect a runtime entry."
            }
            let candidateRelativePath = "lib/\(candidate.lastPathComponent)"
            if values.isSymbolicLink == true {
                guard SceneRendererMachOSliceDigestInventory.isCanonicalRuntimePath(
                    candidateRelativePath
                ),
                      let destination = try? FileManager.default.destinationOfSymbolicLink(
                        atPath: candidate.path
                      ),
                      !destination.contains("/"),
                      SceneRendererMachOSliceDigestInventory.isCanonicalRuntimePath(
                        "lib/\(destination)"
                      ),
                      entriesByPath["lib/\(destination)"] != nil else {
                    return "\(origin) Mach-O library directory contains an unsafe alias."
                }
                let destinationURL = libraryDirectory.appending(path: destination)
                guard (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: destinationURL.path
                )) == nil,
                      let destinationValues = try? destinationURL.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                      ),
                      destinationValues.isRegularFile == true,
                      destinationValues.isSymbolicLink != true else {
                    return "\(origin) Mach-O library alias target is missing or unsafe."
                }
                continue
            }
            guard values.isRegularFile == true,
                  values.isDirectory != true else {
                return "\(origin) Mach-O library directory contains an unexpected entry."
            }
            physicalPaths.insert(candidateRelativePath)
        }
        guard Set(entriesByPath.keys) == physicalPaths else {
            return "\(origin) Mach-O slice digest inventory does not cover the exact runtime file set."
        }

        for relativePath in physicalPaths {
            guard let entries = entriesByPath[relativePath],
                  entries.map(\.architecture) == manifest.architectures else {
                return "\(origin) Mach-O slice digest inventory architecture set is incomplete."
            }
            let fileURL = runtimeDirectory.appending(path: relativePath)
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)) == nil,
                  let fileValues = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  fileValues.isRegularFile == true,
                  fileValues.isSymbolicLink != true,
                  let fileData = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
                  !fileData.isEmpty,
                  let sliceDigests = try? SceneRendererMachOSliceDigests(data: fileData) else {
                return "\(origin) Mach-O runtime contains a missing, unsafe, or malformed file."
            }
            let expectedDigests = Dictionary(
                uniqueKeysWithValues: entries.map { ($0.architecture, $0.sha256) }
            )
            guard sliceDigests.digestsByArchitecture == expectedDigests else {
                return "\(origin) Mach-O runtime bytes do not match the canonical slice digests."
            }
        }
        return nil
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unsupported"
        #endif
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
