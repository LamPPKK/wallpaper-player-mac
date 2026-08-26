import AppKit
import Foundation
import Darwin
import XCTest
@_spi(FFmpegRecovery) import BackgroundEngineCore
@testable import BackgroundEngineApp

final class WallpaperPlayerSuspensionTests: XCTestCase {
    func testNoopScreenParameterNotificationDoesNotNeedWindowReopen() {
        // Given
        let frames = [
            CGRect(x: 0, y: 0, width: 1470, height: 956),
            CGRect(x: -1440, y: 0, width: 1440, height: 900)
        ]

        // Then
        XCTAssertFalse(WallpaperScreenFrames.shouldReopenWindows(previous: frames, current: frames))
    }

    func testNoopScreenParameterNotificationReassertsDesktopWindowOrder() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "private func reopenAfterScreenFrameChange()"))
        let end = try XCTUnwrap(source.range(of: "enum WallpaperScreenFrames", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("reassertWallpaperWindowOrder()"))
        XCTAssertFalse(body.contains("try play("))
        XCTAssertFalse(body.contains("closeWindows()"))
        XCTAssertFalse(body.contains("reopenAfterWake()"))
        XCTAssertTrue(body.contains("reconciliation.addedOrChangedDisplayUUIDs"))
    }

    func testActiveApplicationChangesReassertDesktopWindowOrder() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "private func startLifecycleObservers()"))
        let end = try XCTUnwrap(source.range(of: "private func stopLifecycleObservers()", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("NSWorkspace.didActivateApplicationNotification"))
        XCTAssertTrue(body.contains("scheduleWallpaperWindowOrderReassertion()"))
    }

    func testActiveSpaceChangesReassertDesktopWindowOrder() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "private func startLifecycleObservers()"))
        let end = try XCTUnwrap(source.range(of: "private func stopLifecycleObservers()", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("NSWorkspace.activeSpaceDidChangeNotification"))
        XCTAssertTrue(body.contains("scheduleWallpaperWindowOrderReassertion()"))
    }

    func testAutoPauseUsesDelayedSuspensionToAvoidDockSwitchFlicker() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")

        // Then
        XCTAssertTrue(source.contains("private var pendingAutoSuspension"))
        XCTAssertTrue(source.contains("scheduleAutoSuspension()"))
        XCTAssertTrue(source.contains("cancelPendingAutoSuspension()"))
        XCTAssertTrue(source.contains(".now() + 1.5"))
    }

    func testActiveApplicationChangesReevaluateVisibilityBeforeReassertingOrder() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "private func scheduleWallpaperWindowOrderReassertion()"))
        let end = try XCTUnwrap(source.range(of: "enum WallpaperScreenFrames", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("updateVisibilityState()"))
        XCTAssertTrue(body.contains("reassertWallpaperWindowOrder()"))
    }

    func testActiveApplicationChangesWakeSuspendedWallpaperBeforeDelayedPause() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "private func wakeWallpaperForAppTransition()"))
        let end = try XCTUnwrap(source.range(of: "enum WallpaperScreenFrames", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("cancelPendingAutoSuspension()"))
        XCTAssertTrue(body.contains("setSuspended(false)"))
        XCTAssertTrue(body.contains("updateVisibilityState()"))
    }

    func testWallpaperWindowsJoinFullscreenAppSpaces() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")

        // Then
        XCTAssertTrue(source.contains(".canJoinAllSpaces"))
        XCTAssertTrue(source.contains(".fullScreenAuxiliary"))
    }

    func testRealScreenFrameChangeStillReopensWallpaperWindows() {
        // Given
        let previous = [
            CGRect(x: 0, y: 0, width: 1470, height: 956)
        ]
        let current = [
            CGRect(x: 0, y: 0, width: 1728, height: 1117)
        ]

        // Then
        XCTAssertTrue(WallpaperScreenFrames.shouldReopenWindows(previous: previous, current: current))
    }

    func testReorderedScreenFramesDoNotReopenWallpaperWindows() {
        // Given
        let previous = [
            CGRect(x: 0, y: 0, width: 1470, height: 956),
            CGRect(x: -1440, y: 0, width: 1440, height: 900)
        ]
        let current = Array(previous.reversed())

        // Then
        XCTAssertFalse(WallpaperScreenFrames.shouldReopenWindows(previous: previous, current: current))
    }

    func testScreenCountChangeReopensWallpaperWindows() {
        // Given
        let previous = [
            CGRect(x: 0, y: 0, width: 1470, height: 956),
            CGRect(x: -1440, y: 0, width: 1440, height: 900)
        ]
        let current = [
            CGRect(x: 0, y: 0, width: 1470, height: 956)
        ]

        // Then
        XCTAssertTrue(WallpaperScreenFrames.shouldReopenWindows(previous: previous, current: current))
    }

    func testReplacingDisplayAtSameGeometryReopensWallpaperWindows() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let previous = [
            WallpaperDisplaySnapshot(id: "display-a", frame: frame, backingScaleFactor: 2, isPrimary: true)
        ]
        let current = [
            WallpaperDisplaySnapshot(id: "display-b", frame: frame, backingScaleFactor: 2, isPrimary: true)
        ]

        XCTAssertTrue(WallpaperDisplayTopology.shouldReopenWindows(previous: previous, current: current))
    }

    func testPrimaryDisplayOrBackingScaleChangeReopensWallpaperWindows() {
        let left = WallpaperDisplaySnapshot(
            id: "left",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            backingScaleFactor: 1,
            isPrimary: true
        )
        let right = WallpaperDisplaySnapshot(
            id: "right",
            frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            backingScaleFactor: 2,
            isPrimary: false
        )

        XCTAssertTrue(
            WallpaperDisplayTopology.shouldReopenWindows(
                previous: [left, right],
                current: [
                    WallpaperDisplaySnapshot(
                        id: left.id,
                        frame: left.frame,
                        backingScaleFactor: left.backingScaleFactor,
                        isPrimary: false
                    ),
                    WallpaperDisplaySnapshot(
                        id: right.id,
                        frame: right.frame,
                        backingScaleFactor: right.backingScaleFactor,
                        isPrimary: true
                    )
                ]
            )
        )
        XCTAssertTrue(
            WallpaperDisplayTopology.shouldReopenWindows(
                previous: [left, right],
                current: [
                    WallpaperDisplaySnapshot(
                        id: left.id,
                        frame: left.frame,
                        backingScaleFactor: 2,
                        isPrimary: left.isPrimary
                    ),
                    right
                ]
            )
        )
    }

    func testReorderedEquivalentDisplayTopologyDoesNotReopenWallpaperWindows() {
        let snapshots = [
            WallpaperDisplaySnapshot(
                id: "left",
                frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                backingScaleFactor: 1,
                isPrimary: false
            ),
            WallpaperDisplaySnapshot(
                id: "primary",
                frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                backingScaleFactor: 2,
                isPrimary: true
            )
        ]

        XCTAssertFalse(
            WallpaperDisplayTopology.shouldReopenWindows(
                previous: snapshots,
                current: Array(snapshots.reversed())
            )
        )
    }

    func testDisplayTopologyReconciliationTargetsOnlyChangedOrRemovedDisplays() {
        let primary = WallpaperDisplaySnapshot(
            id: "primary",
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            backingScaleFactor: 2,
            isPrimary: true
        )
        let secondary = WallpaperDisplaySnapshot(
            id: "secondary",
            frame: CGRect(x: 2560, y: 0, width: 1920, height: 1080),
            backingScaleFactor: 1,
            isPrimary: false
        )
        let resizedSecondary = WallpaperDisplaySnapshot(
            id: secondary.id,
            frame: CGRect(x: 2560, y: 0, width: 1680, height: 1050),
            backingScaleFactor: secondary.backingScaleFactor,
            isPrimary: secondary.isPrimary
        )

        XCTAssertEqual(
            WallpaperDisplayTopology.reconciliation(
                previous: [primary, secondary],
                current: [primary, resizedSecondary]
            ),
            WallpaperDisplayReconciliation(
                removedDisplayUUIDs: [],
                addedOrChangedDisplayUUIDs: [secondary.id]
            )
        )
        XCTAssertEqual(
            WallpaperDisplayTopology.reconciliation(
                previous: [primary, secondary],
                current: [primary]
            ),
            WallpaperDisplayReconciliation(
                removedDisplayUUIDs: [secondary.id],
                addedOrChangedDisplayUUIDs: []
            )
        )
    }

    func testFailedTopologyReplacementRetainsOnlyFailedPreviousSnapshotForRetry() {
        let previous = [
            WallpaperDisplaySnapshot(
                id: "primary",
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                backingScaleFactor: 2,
                isPrimary: true
            )
        ]
        let current = [
            WallpaperDisplaySnapshot(
                id: "primary",
                frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                backingScaleFactor: 2,
                isPrimary: true
            ),
            WallpaperDisplaySnapshot(
                id: "secondary",
                frame: CGRect(x: 2560, y: 0, width: 1920, height: 1080),
                backingScaleFactor: 1,
                isPrimary: false
            )
        ]

        let captured = WallpaperDisplayTopology.snapshotAfterReconciliation(
            previous: previous,
            current: current,
            failedDisplayUUIDs: ["primary"]
        )

        XCTAssertEqual(captured.first(where: { $0.id == "primary" }), previous[0])
        XCTAssertEqual(captured.first(where: { $0.id == "secondary" }), current[1])
    }

    func testLibraryAssetReconciliationTargetsEffectiveAssignedDisplaysAndRevokesWebTrust() {
        let oldWeb = makePlaybackAsset(
            id: "web",
            kind: .web,
            entrypoint: "/tmp/web/index.html",
            contentHash: "old",
            allowsNetworkAccess: true
        )
        let newWeb = makePlaybackAsset(
            id: oldWeb.id,
            kind: .web,
            entrypoint: oldWeb.entrypoint!,
            contentHash: "new",
            allowsNetworkAccess: false
        )
        let assignments = [
            DisplayAssignment(displayUUID: "primary", assetID: oldWeb.id),
            DisplayAssignment(displayUUID: "secondary", assetID: "unchanged")
        ]

        XCTAssertEqual(
            AssignedDisplayRefreshPlan.displayUUIDsWithChangedAssets(
                assignments: assignments,
                previousAssets: [oldWeb.id: oldWeb],
                currentAssets: [oldWeb.id: newWeb]
            ),
            ["primary"]
        )
        XCTAssertTrue(
            AssignedDisplayRefreshPlan.requiresRetiringFailedWebSession(
                previous: oldWeb,
                current: newWeb
            )
        )
    }

    func testConvertedVideoRefreshIsIsolatedToEveryDisplayUsingThatAsset() {
        let directVideo = makePlaybackAsset(
            id: "video",
            kind: .video,
            entrypoint: "/tmp/video/original.mkv",
            contentHash: "video-v1",
            allowsNetworkAccess: false
        )
        let convertedVideo = makePlaybackAsset(
            id: directVideo.id,
            kind: .video,
            entrypoint: "/tmp/video/converted.mp4",
            contentHash: "video-v1",
            allowsNetworkAccess: false
        )
        let unrelatedWeb = makePlaybackAsset(
            id: "web",
            kind: .web,
            entrypoint: "/tmp/web/index.html",
            contentHash: "web-v1",
            allowsNetworkAccess: false
        )
        let assignments = [
            DisplayAssignment(displayUUID: "primary", assetID: directVideo.id),
            DisplayAssignment(displayUUID: "secondary", assetID: directVideo.id),
            DisplayAssignment(displayUUID: "projector", assetID: unrelatedWeb.id)
        ]
        let previousAssets = [directVideo.id: directVideo, unrelatedWeb.id: unrelatedWeb]
        let currentAssets = [convertedVideo.id: convertedVideo, unrelatedWeb.id: unrelatedWeb]

        XCTAssertEqual(
            AssignedDisplayRefreshPlan.displayUUIDsWithChangedAssets(
                assignments: assignments,
                previousAssets: previousAssets,
                currentAssets: currentAssets
            ),
            ["primary", "secondary"]
        )

        let application = AssignedDisplayRefreshPlan.application(
            appliedSessions: [
                "primary": .init(assignment: assignments[0], asset: directVideo),
                "secondary": .init(assignment: assignments[1], asset: directVideo),
                "projector": .init(assignment: assignments[2], asset: unrelatedWeb)
            ],
            currentAssignments: assignments,
            currentAssets: currentAssets,
            connectedDisplayUUIDs: ["primary", "secondary", "projector"],
            existingWindowUUIDs: ["primary", "secondary", "projector"]
        )

        XCTAssertEqual(application.displayUUIDsToReplace, ["primary", "secondary"])
        XCTAssertTrue(application.displayUUIDsToClose.isEmpty)
    }

    func testApplyingDisplayAssignmentsReplacesOnlyChangedSessions() {
        let web = makePlaybackAsset(
            id: "web",
            kind: .web,
            entrypoint: "/tmp/web/index.html",
            contentHash: "web-v1",
            allowsNetworkAccess: false
        )
        let video = makePlaybackAsset(
            id: "video",
            kind: .video,
            entrypoint: "/tmp/video/main.mp4",
            contentHash: "video-v1",
            allowsNetworkAccess: false
        )
        let previous = [
            DisplayAssignment(displayUUID: "primary", assetID: web.id),
            DisplayAssignment(displayUUID: "secondary", assetID: video.id)
        ]
        let current = [
            DisplayAssignment(displayUUID: "primary", assetID: video.id),
            DisplayAssignment(displayUUID: "secondary", assetID: video.id)
        ]

        let application = AssignedDisplayRefreshPlan.application(
            appliedSessions: [
                "primary": .init(assignment: previous[0], asset: web),
                "secondary": .init(assignment: previous[1], asset: video)
            ],
            currentAssignments: current,
            currentAssets: [web.id: web, video.id: video],
            connectedDisplayUUIDs: ["primary", "secondary"],
            existingWindowUUIDs: ["primary", "secondary"]
        )

        XCTAssertEqual(application.displayUUIDsToReplace, ["primary"])
        XCTAssertTrue(application.displayUUIDsToClose.isEmpty)
    }

    func testApplyingDisplayAssignmentsClosesClearedAndDisconnectedSessions() {
        let video = makePlaybackAsset(
            id: "video",
            kind: .video,
            entrypoint: "/tmp/video/main.mp4",
            contentHash: "video-v1",
            allowsNetworkAccess: false
        )
        let application = AssignedDisplayRefreshPlan.application(
            appliedSessions: [
                "primary": .init(
                    assignment: DisplayAssignment(displayUUID: "primary", assetID: video.id),
                    asset: video
                ),
                "secondary": .init(
                    assignment: DisplayAssignment(displayUUID: "secondary", assetID: video.id),
                    asset: video
                ),
                "projector": .init(
                    assignment: DisplayAssignment(displayUUID: "projector", assetID: video.id),
                    asset: video
                )
            ],
            currentAssignments: [
                DisplayAssignment(displayUUID: "primary", assetID: video.id),
                DisplayAssignment(displayUUID: "secondary", assetID: nil)
            ],
            currentAssets: [video.id: video],
            connectedDisplayUUIDs: ["primary", "secondary"],
            existingWindowUUIDs: ["primary", "secondary", "projector"]
        )

        XCTAssertEqual(application.displayUUIDsToClose, ["secondary", "projector"])
        XCTAssertTrue(application.displayUUIDsToReplace.isEmpty)
    }

    func testApplyingMissingAssignedAssetClosesOldSessionAndReportsFailurePath() {
        let oldVideo = makePlaybackAsset(
            id: "old-video",
            kind: .video,
            entrypoint: "/tmp/video/main.mp4",
            contentHash: "video-v1",
            allowsNetworkAccess: false
        )
        let application = AssignedDisplayRefreshPlan.application(
            appliedSessions: [
                "primary": .init(
                    assignment: DisplayAssignment(displayUUID: "primary", assetID: oldVideo.id),
                    asset: oldVideo
                )
            ],
            currentAssignments: [DisplayAssignment(displayUUID: "primary", assetID: "missing")],
            currentAssets: [:],
            connectedDisplayUUIDs: ["primary"],
            existingWindowUUIDs: ["primary"]
        )

        XCTAssertEqual(application.displayUUIDsToClose, ["primary"])
        XCTAssertEqual(application.displayUUIDsToReplace, ["primary"])
    }

    func testApplyingDisplayAssignmentsRetriesMissingSessionAndChangedAssetRevision() {
        let oldVideo = makePlaybackAsset(
            id: "video",
            kind: .video,
            entrypoint: "/tmp/video/main.mp4",
            contentHash: "video-v1",
            allowsNetworkAccess: false
        )
        let newVideo = makePlaybackAsset(
            id: oldVideo.id,
            kind: .video,
            entrypoint: oldVideo.entrypoint!,
            contentHash: "video-v2",
            allowsNetworkAccess: false
        )
        let assignments = [
            DisplayAssignment(displayUUID: "primary", assetID: oldVideo.id),
            DisplayAssignment(displayUUID: "secondary", assetID: oldVideo.id)
        ]

        let application = AssignedDisplayRefreshPlan.application(
            appliedSessions: [
                "primary": .init(assignment: assignments[0], asset: oldVideo)
            ],
            currentAssignments: assignments,
            currentAssets: [newVideo.id: newVideo],
            connectedDisplayUUIDs: ["primary", "secondary"],
            existingWindowUUIDs: ["primary"]
        )

        XCTAssertEqual(application.displayUUIDsToReplace, ["primary", "secondary"])
        XCTAssertTrue(application.displayUUIDsToClose.isEmpty)
    }

    func testApplyingDisplayAssignmentsReplacesOnlyDisplaysWhoseTopologyChanged() {
        let video = makePlaybackAsset(
            id: "video",
            kind: .video,
            entrypoint: "/tmp/video/main.mp4",
            contentHash: "video-v1",
            allowsNetworkAccess: false
        )
        let assignments = [
            DisplayAssignment(displayUUID: "primary", assetID: video.id),
            DisplayAssignment(displayUUID: "secondary", assetID: video.id)
        ]

        let application = AssignedDisplayRefreshPlan.application(
            appliedSessions: [
                "primary": .init(assignment: assignments[0], asset: video),
                "secondary": .init(assignment: assignments[1], asset: video)
            ],
            currentAssignments: assignments,
            currentAssets: [video.id: video],
            connectedDisplayUUIDs: ["primary", "secondary"],
            existingWindowUUIDs: ["primary", "secondary"],
            topologyChangedDisplayUUIDs: ["secondary"]
        )

        XCTAssertEqual(application.displayUUIDsToReplace, ["secondary"])
        XCTAssertTrue(application.displayUUIDsToClose.isEmpty)
    }

    func testFailedDisplayReplacementRetriesAgainstActuallyAppliedSession() {
        let oldWeb = makePlaybackAsset(
            id: "old-web",
            kind: .web,
            entrypoint: "/tmp/web/index.html",
            contentHash: "web-v1",
            allowsNetworkAccess: true
        )
        let newVideo = makePlaybackAsset(
            id: "new-video",
            kind: .video,
            entrypoint: "/tmp/video/main.mp4",
            contentHash: "video-v1",
            allowsNetworkAccess: false
        )
        let oldAssignment = DisplayAssignment(
            displayUUID: "primary",
            assetID: oldWeb.id,
            audioSource: .primaryDisplay
        )
        let desiredAssignment = DisplayAssignment(
            displayUUID: "primary",
            assetID: newVideo.id,
            audioSource: .muted
        )
        let retainedFallback = [
            "primary": AssignedDisplayRefreshPlan.AppliedSession(
                assignment: oldAssignment,
                asset: oldWeb
            )
        ]

        for _ in 0..<2 {
            let application = AssignedDisplayRefreshPlan.application(
                appliedSessions: retainedFallback,
                currentAssignments: [desiredAssignment],
                currentAssets: [oldWeb.id: oldWeb, newVideo.id: newVideo],
                connectedDisplayUUIDs: ["primary"],
                existingWindowUUIDs: ["primary"]
            )
            XCTAssertEqual(application.displayUUIDsToReplace, ["primary"])
        }
    }

    func testAppliedWebSecurityTracksActualFallbackRevisionInsteadOfDesiredAsset() {
        let oldWeb = makePlaybackAsset(
            id: "old-web",
            kind: .web,
            entrypoint: "/tmp/web/index.html",
            contentHash: "web-v1",
            allowsNetworkAccess: true
        )
        let revokedWeb = makePlaybackAsset(
            id: oldWeb.id,
            kind: .web,
            entrypoint: oldWeb.entrypoint!,
            contentHash: oldWeb.contentHash!,
            allowsNetworkAccess: false
        )
        let desiredVideo = makePlaybackAsset(
            id: "desired-video",
            kind: .video,
            entrypoint: "/tmp/video/main.mp4",
            contentHash: "video-v1",
            allowsNetworkAccess: false
        )
        let session = AssignedDisplayRefreshPlan.AppliedSession(
            assignment: nil,
            asset: oldWeb
        )

        XCTAssertFalse(AssignedDisplayRefreshPlan.requiresRetiringAppliedSession(
            session,
            currentAssets: [oldWeb.id: oldWeb, desiredVideo.id: desiredVideo]
        ))
        XCTAssertTrue(AssignedDisplayRefreshPlan.requiresRetiringAppliedSession(
            session,
            currentAssets: [oldWeb.id: revokedWeb, desiredVideo.id: desiredVideo]
        ))
        XCTAssertTrue(AssignedDisplayRefreshPlan.requiresRetiringAppliedSession(
            session,
            currentAssets: [desiredVideo.id: desiredVideo]
        ))
    }

    func testReplacementBarrierTargetsActuallyAppliedFallbackSessions() {
        let actual = makePlaybackAsset(
            id: "actual-web",
            kind: .web,
            entrypoint: "/tmp/web/index.html",
            contentHash: "web-v1",
            allowsNetworkAccess: false
        )
        let desired = makePlaybackAsset(
            id: "desired-video",
            kind: .video,
            entrypoint: "/tmp/video/main.mp4",
            contentHash: "video-v1",
            allowsNetworkAccess: false
        )
        let sessions = [
            "primary": AssignedDisplayRefreshPlan.AppliedSession(assignment: nil, asset: actual),
            "secondary": AssignedDisplayRefreshPlan.AppliedSession(
                assignment: DisplayAssignment(displayUUID: "secondary", assetID: desired.id),
                asset: desired
            )
        ]

        XCTAssertEqual(
            AssignedDisplayRefreshPlan.displayUUIDs(applying: actual.id, sessions: sessions),
            ["primary"]
        )
        XCTAssertEqual(
            AssignedDisplayRefreshPlan.displayUUIDs(applying: desired.id, sessions: sessions),
            ["secondary"]
        )
    }

    func testFailedReplacementRestoresQuiescedFallbackOnlyWhenDesiredWindowIsStillMissing() {
        let fallback = makePlaybackAsset(
            id: "fallback-web",
            kind: .web,
            entrypoint: "/tmp/web/index.html",
            contentHash: "web-v1",
            allowsNetworkAccess: false
        )
        let desired = DisplayAssignment(displayUUID: "primary", assetID: "desired-video")
        let quiesced = [
            "primary": AssignedDisplayRefreshPlan.AppliedSession(
                assignment: nil,
                asset: fallback
            )
        ]

        XCTAssertEqual(
            AssignedDisplayRefreshPlan.fallbackDisplayUUIDs(
                quiescedSessions: quiesced,
                desiredAssignments: [desired],
                occupiedDisplayUUIDs: []
            ),
            ["primary"]
        )
        XCTAssertTrue(AssignedDisplayRefreshPlan.fallbackDisplayUUIDs(
            quiescedSessions: quiesced,
            desiredAssignments: [desired],
            occupiedDisplayUUIDs: ["primary"]
        ).isEmpty)
        XCTAssertTrue(AssignedDisplayRefreshPlan.fallbackDisplayUUIDs(
            quiescedSessions: quiesced,
            desiredAssignments: [DisplayAssignment(displayUUID: "primary", assetID: nil)],
            occupiedDisplayUUIDs: []
        ).isEmpty)
    }

    func testReplacementFinishRetainsQuiescedFallbackUntilTerminalRestore() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let prepareStart = try XCTUnwrap(source.range(of: "func prepareForLibraryAssetReplacement("))
        let finishStart = try XCTUnwrap(
            source.range(of: "func finishLibraryAssetReplacement(", range: prepareStart.lowerBound..<source.endIndex)
        )
        let finishEnd = try XCTUnwrap(
            source.range(of: "/// Applies the wallpaper audio", range: finishStart.lowerBound..<source.endIndex)
        )
        let prepareBody = String(source[prepareStart.lowerBound..<finishStart.lowerBound])
        let finishBody = String(source[finishStart.lowerBound..<finishEnd.lowerBound])

        XCTAssertTrue(prepareBody.contains("quiescedAppliedSessionsByAssetID[assetID] = quiescedSessions"))
        XCTAssertTrue(finishBody.contains("quiescedAppliedSessionsByAssetID.removeValue(forKey: assetID)"))
        XCTAssertTrue(finishBody.contains("fallbackDisplayUUIDs("))
        XCTAssertTrue(finishBody.contains("restoreQuiescedFallbackSessions("))
        XCTAssertTrue(finishBody.contains("activeAssetsByID[assetID] ?? activeAsset"))
    }

    func testSingleWallpaperWindowsRecordActualAppliedAssetSnapshot() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "private func openSingleWallpaperWindows("))
        let end = try XCTUnwrap(
            source.range(of: "private func startVisibilityTimer()", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("openedSessions[displayUUID] = .init(assignment: nil, asset: asset)"))
        XCTAssertTrue(body.contains("appliedDisplaySessions[displayUUID] = session"))
    }

    func testDisplayAssignmentApplyUsesDesiredPerDisplayAudioForRetainedFallback() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "private func applyAssignedAudioSettings("))
        let end = try XCTUnwrap(
            source.range(of: "private func reopenAfterScreenFrameChange()", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("assignment?.audioSource == .primaryDisplay"))
        XCTAssertTrue(body.contains("displayUUID == primaryDisplayUUID"))
        XCTAssertTrue(body.contains("window.setAudio(enabled: enabled"))
    }

    func testApplyingDisplayAssignmentsPreservesPauseAndAvoidsGlobalTeardown() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "func play(\n        assignments:"))
        let end = try XCTUnwrap(
            source.range(of: "/// Refreshes the immutable asset snapshots", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("AssignedDisplayRefreshPlan.application("))
        XCTAssertTrue(body.contains("replacingExisting: true"))
        XCTAssertTrue(body.contains("closeWindows(displayUUIDs:"))
        XCTAssertFalse(body.contains("closeWindows()"))
        XCTAssertFalse(body.contains("isManuallyPaused = false"))
    }

    func testWorkshopReplacementQuiescesOnlyAffectedSessionsAndKeepsStateForRestore() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "func prepareForLibraryAssetReplacement("))
        let end = try XCTUnwrap(
            source.range(of: "/// Applies the wallpaper audio", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("AssignedDisplayRefreshPlan.displayUUIDs("))
        XCTAssertTrue(body.contains("applying: assetID"))
        XCTAssertTrue(body.contains("sessions: appliedDisplaySessions"))
        XCTAssertTrue(body.contains("closeWindows(displayUUIDs: affectedDisplayUUIDs)"))
        XCTAssertTrue(body.contains("pendingLibraryReplacementAssetIDs.insert(assetID)"))
        XCTAssertTrue(body.contains("await SceneRenderCoordinator.shared.cancel(assetID: assetID)"))
        XCTAssertFalse(body.contains("activeAsset = nil"))
        XCTAssertFalse(body.contains("activeDisplayAssignments = []"))
    }

    func testWorkshopReplacementDoesNotOverrideNewerSingleWallpaperSelection() {
        XCTAssertTrue(AssignedDisplayRefreshPlan.shouldRestoreSingleWallpaperAfterReplacement(
            assetID: "updating-a",
            activeAssetID: "updating-a",
            hasDisplayAssignments: false
        ))
        XCTAssertFalse(AssignedDisplayRefreshPlan.shouldRestoreSingleWallpaperAfterReplacement(
            assetID: "updating-a",
            activeAssetID: "user-selected-b",
            hasDisplayAssignments: false
        ))
        XCTAssertFalse(AssignedDisplayRefreshPlan.shouldRestoreSingleWallpaperAfterReplacement(
            assetID: "updating-a",
            activeAssetID: nil,
            hasDisplayAssignments: false
        ))
        XCTAssertFalse(AssignedDisplayRefreshPlan.shouldRestoreSingleWallpaperAfterReplacement(
            assetID: "updating-a",
            activeAssetID: "updating-a",
            hasDisplayAssignments: true
        ))
    }

    func testStopAllDoesNotReleaseWorkshopReplacementBarrier() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "func stop()"))
        let end = try XCTUnwrap(
            source.range(of: "func closeWindows()", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(body.contains("pendingLibraryReplacementAssetIDs = []"))
        XCTAssertFalse(body.contains("pendingLibraryReplacementAssetIDs.remove"))
    }

    func testSingleWallpaperAudioIsRestrictedToPrimaryDisplayAndAssignmentsAreDeduplicated() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")

        XCTAssertTrue(source.contains("audioEnabled: self.audioEnabled && index == 0"))
        XCTAssertTrue(source.contains("audioEnabled: audioEnabled && index == 0"))
        XCTAssertTrue(source.contains("allowsAudio: index == 0"))
        XCTAssertTrue(source.contains("reduce(into: [String: DisplayAssignment]())"))
        XCTAssertTrue(source.contains("guard activeDisplayAssignments.isEmpty else { return }"))

        let coordinator = try String(repositoryFile: "Sources/BackgroundEngineApp/DisplaySessionCoordinator.swift")
        XCTAssertTrue(coordinator.contains("assets.reduce(into: [WallpaperAsset.ID: WallpaperAsset]())"))
        XCTAssertFalse(coordinator.contains("Dictionary(uniqueKeysWithValues:"))
    }

    func testSceneCacheRefreshTargetsOnlyDisplaysAssignedToCompletedAsset() {
        let assignments = [
            DisplayAssignment(displayUUID: "primary", assetID: "scene-a"),
            DisplayAssignment(displayUUID: "secondary", assetID: "video-b"),
            DisplayAssignment(displayUUID: "projector", assetID: "scene-a"),
            DisplayAssignment(displayUUID: "unassigned", assetID: nil)
        ]

        XCTAssertEqual(
            AssignedDisplayRefreshPlan.displayUUIDs(
                for: "scene-a",
                assignments: assignments
            ),
            Set(["primary", "projector"])
        )
        XCTAssertEqual(
            AssignedDisplayRefreshPlan.displayUUIDs(
                for: "video-b",
                assignments: assignments
            ),
            Set(["secondary"])
        )
        XCTAssertTrue(
            AssignedDisplayRefreshPlan.displayUUIDs(
                for: "missing",
                assignments: assignments
            ).isEmpty
        )
        XCTAssertTrue(
            AssignedDisplayRefreshPlan.capturesCompleteTopology(requestedDisplayUUIDs: nil)
        )
        XCTAssertFalse(
            AssignedDisplayRefreshPlan.capturesCompleteTopology(
                requestedDisplayUUIDs: Set(["primary"])
            )
        )

        let duplicateAssignments = assignments + [
            DisplayAssignment(displayUUID: "primary", assetID: "video-b")
        ]
        XCTAssertEqual(
            AssignedDisplayRefreshPlan.displayUUIDs(
                for: "scene-a",
                assignments: duplicateAssignments
            ),
            Set(["projector"])
        )
        XCTAssertEqual(
            AssignedDisplayRefreshPlan.displayUUIDs(
                for: "video-b",
                assignments: duplicateAssignments
            ),
            Set(["primary", "secondary"])
        )
        XCTAssertFalse(
            AssignedDisplayRefreshPlan.shouldRefreshSingleWallpaper(
                for: "scene-a",
                assignments: duplicateAssignments,
                activeAssetID: "scene-a",
                activeAssetKind: .scene,
                expectedKind: .scene
            )
        )
        XCTAssertTrue(
            AssignedDisplayRefreshPlan.shouldRefreshSingleWallpaper(
                for: "scene-a",
                assignments: [],
                activeAssetID: "scene-a",
                activeAssetKind: .scene,
                expectedKind: .scene
            )
        )
        XCTAssertTrue(
            AssignedDisplayRefreshPlan.shouldRefreshSingleWallpaper(
                for: "web-a",
                assignments: [],
                activeAssetID: "web-a",
                activeAssetKind: .web,
                expectedKind: .web
            )
        )
        XCTAssertFalse(
            AssignedDisplayRefreshPlan.shouldRefreshSingleWallpaper(
                for: "web-a",
                assignments: duplicateAssignments,
                activeAssetID: "web-a",
                activeAssetKind: .web,
                expectedKind: .web
            )
        )
    }

    func testWebPropertyRefreshUsesTargetedDisplayReplacement() throws {
        let player = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        XCTAssertTrue(player.contains("func refreshIfNeeded(afterWebPropertyChangeFor assetId: String)"))
        XCTAssertTrue(player.contains("expectedKind: .web"))

        let model = try String(repositoryFile: "Sources/BackgroundEngineApp/AppViewModel.swift")
        let start = try XCTUnwrap(model.range(of: "func chooseWebProperty("))
        let end = try XCTUnwrap(model.range(of: "func setSceneAssetsFolder(", range: start.lowerBound..<model.endIndex))
        let body = String(model[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("guard !isWorking else"))
        XCTAssertTrue(body.contains("WebWallpaperUserFileStore.shared.copySelection"))
        XCTAssertTrue(body.contains("refreshIfNeeded(afterWebPropertyChangeFor: asset.id)"))
    }

    func testSceneCacheRefreshDoesNotCloseUnrelatedDisplayWindows() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(
            source.range(of: "func refreshIfNeeded(afterSceneVideoRenderFor assetId: String)")
        )
        let end = try XCTUnwrap(
            source.range(of: "func restoreVisibleWindowsAfterAppWindowChange()", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("AssignedDisplayRefreshPlan.displayUUIDs"))
        XCTAssertTrue(body.contains("replacingExisting: true"))
        XCTAssertFalse(body.contains("closeWindows()"))
    }

    func testSceneCacheRefreshKeepsUnrelatedAndFailedReplacementSessions() {
        let existing = [
            "primary": "primary-old",
            "secondary": "secondary-old",
            "projector": "projector-old"
        ]
        let successfullyOpened = [
            "primary": "primary-new"
        ]

        let result = AssignedDisplayRefreshPlan.applyingSuccessfulReplacements(
            successfullyOpened,
            to: existing
        )

        XCTAssertEqual(result.active["primary"], "primary-new")
        XCTAssertEqual(result.active["secondary"], "secondary-old")
        XCTAssertEqual(result.active["projector"], "projector-old")
        XCTAssertEqual(result.retired, ["primary-old"])
    }

    func testRecreatedDisplayWindowsInheritPauseWithoutClearingManualState() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let wakeStart = try XCTUnwrap(source.range(of: "private func reopenAfterWake()"))
        let wakeEnd = try XCTUnwrap(
            source.range(of: "private func openAssignedWindows(", range: wakeStart.lowerBound..<source.endIndex)
        )
        let wakeBody = String(source[wakeStart.lowerBound..<wakeEnd.lowerBound])

        XCTAssertTrue(source.contains("private func applyCurrentSuspensionToWindows()"))
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "applyCurrentSuspensionToWindows()").count - 1, 4)
        XCTAssertTrue(wakeBody.contains("openAssignedWindows("))
        XCTAssertTrue(wakeBody.contains("openSingleWallpaperWindows("))
        XCTAssertTrue(wakeBody.contains("replacingExisting: true"))
        XCTAssertFalse(wakeBody.contains("closeWindows()"))
        XCTAssertFalse(wakeBody.contains("isManuallyPaused = false"))
    }

    func testWallpaperWindowFrameExtendsBehindMenuBarAndDockForContinuousBackdrop() {
        // Given
        let screenFrame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let visibleFrame = CGRect(x: 0, y: 80, width: 1470, height: 846)

        // When
        let frame = WallpaperScreenFrames.wallpaperFrame(screenFrame: screenFrame, visibleFrame: visibleFrame)

        // Then
        XCTAssertEqual(frame, screenFrame)
    }

    func testWallpaperWindowDoesNotInjectSyntheticBackgroundColorIntoMenuBarBackdrop() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let windowStart = try XCTUnwrap(source.range(of: "private final class WallpaperWindow"))
        let initStart = try XCTUnwrap(source.range(of: "init(asset:", range: windowStart.lowerBound..<source.endIndex))
        let initEnd = try XCTUnwrap(source.range(of: "func show()", range: initStart.lowerBound..<source.endIndex))
        let body = String(source[initStart.lowerBound..<initEnd.lowerBound])

        // Then
        XCTAssertTrue(body.contains("window.isOpaque = false"))
        XCTAssertTrue(body.contains("window.backgroundColor = .clear"))
        XCTAssertFalse(body.contains("window.backgroundColor = .black"))
    }

    func testAutoPauseDoesNotHideWallpaperWindow() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")

        // Then
        XCTAssertFalse(
            source.contains("window.orderOut(nil)"),
            "Auto-pause should pause wallpaper media, not hide the desktop-layer wallpaper window."
        )
    }

    func testDisplayModeChangeDoesNotRecreateWallpaperWindows() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "func setDisplayMode"))
        let end = try XCTUnwrap(source.range(of: "func setAutoPauseWhenCovered"))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertFalse(body.contains("reopen("))
        XCTAssertFalse(body.contains("closeWindows("))
    }

    func testWindowClosePreparesWallpaperContentBeforeClosing() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let windowStart = try XCTUnwrap(source.range(of: "private final class WallpaperWindow"))
        let start = try XCTUnwrap(source.range(of: "func close()", range: windowStart.lowerBound..<source.endIndex))
        let end = try XCTUnwrap(source.range(of: "func setSuspended", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("prepareForClose()"))
        XCTAssertTrue(body.contains("window.contentView = nil"))
    }

    func testSleepCancelsSceneAndWebMediaPreparationBeforeWakeReopensDisplays() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "private func startLifecycleObservers()"))
        let end = try XCTUnwrap(
            source.range(of: "private func stopLifecycleObservers()", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("NSWorkspace.willSleepNotification"))
        XCTAssertTrue(body.contains("WebMediaRuntimeCoordinator.shared.cancellationCheckpoint()"))
        XCTAssertTrue(body.contains("SceneRenderCoordinator.shared.cancellationCheckpoint()"))
        XCTAssertTrue(body.contains("await WebMediaRuntimeCoordinator.shared.cancelAll(upTo:"))
        XCTAssertTrue(body.contains("await SceneRenderCoordinator.shared.cancelAll(upTo:"))
        XCTAssertTrue(body.contains("self?.reopenAfterWake()"))
    }

    func testStopCapturesScopedWebAndSceneCancellationBeforeCleanupTask() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "func stop()"))
        let end = try XCTUnwrap(
            source.range(of: "private func closeWindows()", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("WebMediaRuntimeCoordinator.shared.cancellationCheckpoint()"))
        XCTAssertTrue(body.contains("SceneRenderCoordinator.shared.cancellationCheckpoint()"))
        XCTAssertTrue(body.contains("await WebMediaRuntimeCoordinator.shared.cancelAll(upTo:"))
        XCTAssertTrue(body.contains("await SceneRenderCoordinator.shared.cancelAll(upTo:"))
    }

    func testWallpaperWindowsDisableAppKitWindowAnimations() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")

        // Then
        XCTAssertTrue(source.contains("window.animationBehavior = .none"))
    }

    func testWallpaperWindowsAreNotReleasedByAppKitWhenClosed() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")

        // Then
        XCTAssertTrue(source.contains("window.isReleasedWhenClosed = false"))
    }

    func testWallpaperWindowCanReassertOrderWithoutRecreatingContent() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let windowStart = try XCTUnwrap(source.range(of: "private final class WallpaperWindow"))
        let start = try XCTUnwrap(source.range(of: "func reassertDesktopOrder()", range: windowStart.lowerBound..<source.endIndex))
        let end = try XCTUnwrap(source.range(of: "func close()", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("window.orderFrontRegardless()"))
        XCTAssertFalse(body.contains("makeContentView"))
        XCTAssertFalse(body.contains("close()"))
    }

    func testSceneWallpaperReceivesPreviewFallback() throws {
        // Given
        let playerSource = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let sceneSource = try String(repositoryFile: "Sources/BackgroundEngineApp/SceneWallpaperView.swift")

        // Then
        XCTAssertTrue(playerSource.contains("let previewURL = asset.thumbnail.map { URL(filePath: $0) }"))
        XCTAssertTrue(playerSource.contains("previewURL: previewURL"))
        XCTAssertTrue(sceneSource.contains("private let previewLayer = CALayer()"))
        XCTAssertTrue(sceneSource.contains("sceneLayer.backgroundColor = nil"))
    }

    func testScenePlaybackPrefersNativeRendererOverRenderCache() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let sceneStart = try XCTUnwrap(source.range(of: "case .scene:"))
        let sceneEnd = try XCTUnwrap(
            source.range(of: "case .application, .unknown:", range: sceneStart.lowerBound..<source.endIndex)
        )
        let sceneBody = String(source[sceneStart.lowerBound..<sceneEnd.lowerBound])

        // Then
        XCTAssertTrue(sceneBody.contains("SceneWallpaperContentFactory.makeSceneContentView"))
        XCTAssertFalse(sceneBody.contains("SceneRenderCache.existingVideoURL"))
        XCTAssertFalse(sceneBody.contains("return VideoWallpaperView("))
    }

    func testScenePlaybackRealtimeRendererWindowCodeHasBeenRemoved() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")

        // Then
        XCTAssertFalse(source.contains("ExternalSceneRendererView"))
        XCTAssertFalse(source.contains("SceneEngineProcessController"))
        XCTAssertFalse(source.contains("--macos-wallpaper-window"))
    }

    @MainActor
    func testScenePlaybackUsesFreshCachedVideoWhenAvailable() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)
        let cacheDirectory = root.appending(path: "SceneVideoCache")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cachedVideoURL = cacheDirectory.appending(path: "\(asset.id).mp4")
        try "fake-cached-video".write(to: cachedVideoURL, atomically: true, encoding: .utf8)
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer {
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }

        // When
        let view = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )
        (view as? WallpaperContentLifecycle)?.prepareForClose()

        // Then
        XCTAssertTrue(view is VideoWallpaperView)
        XCTAssertNil(SceneWallpaperContentFactory.lastDiagnostic)
    }

    @MainActor
    func testRenamedPKGVSceneStillUsesFreshCachedVideo() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.payload")
        try Self.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)
        let cacheDirectory = root.appending(path: "SceneVideoCache")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try "fake-cached-video".write(
            to: cacheDirectory.appending(path: "\(asset.id).mp4"),
            atomically: true,
            encoding: .utf8
        )
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }

        let view = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fill
        )
        defer { (view as? WallpaperContentLifecycle)?.prepareForClose() }

        XCTAssertTrue(view is VideoWallpaperView)
    }

    /// A rendered Scene cache must keep the assignment's display mode just
    /// like Video, Image, and native Scene playback. The cache itself now
    /// preserves the Scene canvas aspect ratio, so Fit can letterbox without
    /// desynchronizing any native live-text overlay.
    @MainActor
    func testScenePlaybackHonorsPerDisplayModeForCachedVideo() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)
        let cacheDirectory = root.appending(path: "SceneVideoCache")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cachedVideoURL = cacheDirectory.appending(path: "\(asset.id).mp4")
        try "fake-cached-video".write(to: cachedVideoURL, atomically: true, encoding: .utf8)
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer {
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }

        // When
        let view = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )
        defer {
            (view as? WallpaperContentLifecycle)?.prepareForClose()
        }

        // Then
        let videoView = try XCTUnwrap(view as? VideoWallpaperView)
        XCTAssertEqual(videoView.playerLayer.videoGravity, .resizeAspect)
    }

    @MainActor
    func testScenePlaybackFallsBackToNativeWhenSceneEngineAssetsAreMissing() async throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let rendererURL = root.appending(path: "scene-engine-renderer")
        try "#!/bin/sh\nexit 0\n".write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rendererURL.path)
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)
        let previousRendererPath = SceneEngineRendererConfiguration.overrideExecutablePath
        let previousAssetsPath = SceneEngineRendererConfiguration.overrideAssetsPath
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneEngineRendererConfiguration.overrideExecutablePath = rendererURL.path
        SceneEngineRendererConfiguration.overrideAssetsPath = root.appending(path: "missing-assets").path
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer {
            SceneEngineRendererConfiguration.overrideExecutablePath = previousRendererPath
            SceneEngineRendererConfiguration.overrideAssetsPath = previousAssetsPath
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }

        // When
        let view = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )
        let preparingView = try XCTUnwrap(view as? PreparingSceneWallpaperView)
        let isNativeReady = await preparingView.waitUntilNativeReadiness()
        XCTAssertTrue(isNativeReady)
        preparingView.prepareForClose()

        // Then
        // The diagnostic enumerates every missing component; ffmpeg availability
        // depends on the host (absent on CI runners), so assert on the part this
        // test controls instead of exact equality.
        let diagnostic = try XCTUnwrap(SceneWallpaperContentFactory.lastDiagnostic)
        XCTAssertTrue(diagnostic.hasPrefix("Scene cache unavailable: "))
        XCTAssertTrue(diagnostic.contains("Wallpaper Engine assets folder"))
    }

    @MainActor
    func testParticleOnlySceneFallsBackToLimitedNativePlayback() async throws {
        // Given: the external cache runtime is incomplete, but the native Scene
        // view can still animate the supported particle layer with a soft sprite.
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        let sceneJSON = """
        {
          "general": { "orthogonalprojection": { "width": 1920, "height": 1080 } },
          "objects": [
            {
              "name": "dust",
              "visible": true,
              "particle": "particles/dust.json",
              "origin": "960 540 0"
            }
          ]
        }
        """
        let particleJSON = """
        {
          "emitter": [ { "name": "sphererandom", "rate": 25 } ],
          "initializer": [ { "name": "lifetimerandom", "min": 1, "max": 2 } ],
          "renderer": [ { "name": "sprite" } ],
          "maxcount": 100
        }
        """
        try Self.writeScenePackage(
            to: packageURL,
            entries: [
                ("scene.json", Data(sceneJSON.utf8)),
                ("particles/dust.json", Data(particleJSON.utf8))
            ]
        )
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)
        let previousExecutablePath = SceneEngineRendererConfiguration.overrideExecutablePath
        let previousResourceURL = SceneEngineRendererConfiguration.overrideResourceURL
        let previousHandler = SceneWallpaperContentFactory.compatibilityReportHandler
        SceneEngineRendererConfiguration.overrideExecutablePath = root
            .appending(path: "missing-renderer")
            .path
        SceneEngineRendererConfiguration.overrideResourceURL = root.appending(path: "missing-runtime")
        var reported: CompatibilityReport?
        SceneWallpaperContentFactory.compatibilityReportHandler = { _, report in reported = report }
        defer {
            SceneEngineRendererConfiguration.overrideExecutablePath = previousExecutablePath
            SceneEngineRendererConfiguration.overrideResourceURL = previousResourceURL
            SceneWallpaperContentFactory.compatibilityReportHandler = previousHandler
        }

        // When
        let view = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )
        let preparingView = try XCTUnwrap(view as? PreparingSceneWallpaperView)
        XCTAssertNil(reported, "Compatibility must wait for the asynchronous native probe.")
        let isNativeReady = await preparingView.waitUntilNativeReadiness()
        preparingView.prepareForClose()

        // Then
        XCTAssertTrue(isNativeReady)
        XCTAssertEqual(reported?.level, .limited)
        XCTAssertEqual(reported?.playbackPath, .nativeScene)
        XCTAssertEqual(reported?.diagnosticCode, "scene_native_approximation")
    }

    @MainActor
    func testInlineRopeParticleSceneFallsBackToLimitedNativePlayback() async throws {
        // Given: inline ropetrail JSON is a valid Wallpaper Engine particle
        // definition, but the native path remains an explicit approximation.
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        let sceneJSON = """
        {
          "general": { "orthogonalprojection": { "width": 1920, "height": 1080 } },
          "objects": [
            {
              "name": "energy trail",
              "visible": true,
              "origin": "960 540 0",
              "particle": {
                "emitter": [ { "name": "sphererandom", "rate": 18 } ],
                "initializer": [ { "name": "lifetimerandom", "min": 1, "max": 2 } ],
                "renderer": [ { "name": "ropetrail" } ],
                "maxcount": 100
              }
            }
          ]
        }
        """
        try Self.writeScenePackage(to: packageURL, sceneJSON: sceneJSON)
        let asset = WallpaperAsset(
            id: root.lastPathComponent,
            title: "Inline rope Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .localSteamWorkshop,
            projectDirectory: root.path,
            entrypoint: packageURL.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .limited(reason: "Particle approximation"),
            compatibilityReport: CompatibilityReport(
                level: .limited,
                playbackPath: .renderedSceneCache,
                requiredCapabilities: [.particle]
            ),
            redistributionAllowed: false,
            issues: []
        )
        let previousExecutablePath = SceneEngineRendererConfiguration.overrideExecutablePath
        let previousResourceURL = SceneEngineRendererConfiguration.overrideResourceURL
        let previousHandler = SceneWallpaperContentFactory.compatibilityReportHandler
        SceneEngineRendererConfiguration.overrideExecutablePath = root
            .appending(path: "missing-renderer")
            .path
        SceneEngineRendererConfiguration.overrideResourceURL = root.appending(path: "missing-runtime")
        var reported: CompatibilityReport?
        SceneWallpaperContentFactory.compatibilityReportHandler = { _, report in reported = report }
        defer {
            SceneEngineRendererConfiguration.overrideExecutablePath = previousExecutablePath
            SceneEngineRendererConfiguration.overrideResourceURL = previousResourceURL
            SceneWallpaperContentFactory.compatibilityReportHandler = previousHandler
        }

        // When
        let view = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )
        let preparingView = try XCTUnwrap(view as? PreparingSceneWallpaperView)
        let isNativeReady = await preparingView.waitUntilNativeReadiness()
        preparingView.prepareForClose()

        // Then
        XCTAssertTrue(isNativeReady)
        XCTAssertEqual(reported?.level, .limited)
        XCTAssertEqual(reported?.playbackPath, .nativeScene)
        XCTAssertEqual(reported?.missingCapabilities, [.particle])
        XCTAssertEqual(reported?.diagnosticCode, "scene_native_approximation")
    }

    @MainActor
    func testScenePreviewFallbackIsReportedUnsupportedWhenNativeParsingFails() async throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        try Data([0, 1, 2, 3]).write(to: packageURL)
        let previewURL = root.appending(path: "preview.png")
        try Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lz8KWwAAAABJRU5ErkJggg=="
        )!.write(to: previewURL)
        let asset = WallpaperAsset(
            id: root.lastPathComponent,
            title: "Broken Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: root.path,
            entrypoint: packageURL.path,
            thumbnail: previewURL.path,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
        let previousResourceURL = SceneEngineRendererConfiguration.overrideResourceURL
        let previousHandler = SceneWallpaperContentFactory.compatibilityReportHandler
        SceneEngineRendererConfiguration.overrideResourceURL = root.appending(path: "missing-runtime")
        var reported: CompatibilityReport?
        SceneWallpaperContentFactory.compatibilityReportHandler = { _, report in reported = report }
        defer {
            SceneEngineRendererConfiguration.overrideResourceURL = previousResourceURL
            SceneWallpaperContentFactory.compatibilityReportHandler = previousHandler
        }

        let view = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            previewURL: previewURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )

        let preparingView = try XCTUnwrap(view as? PreparingSceneWallpaperView)
        XCTAssertNil(reported, "Compatibility must wait for the asynchronous native probe.")
        let isNativeReady = await preparingView.waitUntilNativeReadiness()
        XCTAssertFalse(isNativeReady)
        preparingView.prepareForClose()
        XCTAssertEqual(reported?.level, .unsupported)
        XCTAssertNil(reported?.playbackPath)
        XCTAssertEqual(reported?.diagnosticCode, "scene_no_playback_renderer")
    }

    @MainActor
    func testSceneWithUndecodableTextureDoesNotClaimNativeFallback() async throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            entries: [
                ("scene.json", Data(#"{"objects":[{"image":"models/layer.json","size":"320 180"}]}"#.utf8)),
                ("models/layer.json", Data(#"{"material":"materials/layer.json"}"#.utf8)),
                ("materials/layer.json", Data(#"{"textures":["textures/layer.tex"]}"#.utf8)),
                ("textures/layer.tex", Data([0, 1, 2, 3]))
            ]
        )
        let previewURL = root.appending(path: "preview.png")
        try Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lz8KWwAAAABJRU5ErkJggg=="
        )!.write(to: previewURL)
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)
        let previousResourceURL = SceneEngineRendererConfiguration.overrideResourceURL
        let previousHandler = SceneWallpaperContentFactory.compatibilityReportHandler
        SceneEngineRendererConfiguration.overrideResourceURL = root.appending(path: "missing-runtime")
        var reported: CompatibilityReport?
        SceneWallpaperContentFactory.compatibilityReportHandler = { _, report in reported = report }
        defer {
            SceneEngineRendererConfiguration.overrideResourceURL = previousResourceURL
            SceneWallpaperContentFactory.compatibilityReportHandler = previousHandler
        }

        let view = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            previewURL: previewURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )

        let preparingView = try XCTUnwrap(view as? PreparingSceneWallpaperView)
        XCTAssertNil(reported, "Compatibility must wait for full texture decoding.")
        let isNativeReady = await preparingView.waitUntilNativeReadiness()
        XCTAssertFalse(isNativeReady)
        preparingView.prepareForClose()
        XCTAssertEqual(reported?.level, .unsupported)
        XCTAssertNil(reported?.playbackPath)
        XCTAssertEqual(reported?.diagnosticCode, "scene_no_playback_renderer")
    }

    func testScenePreflightForceKillsAndReapsTimedOutRenderer() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidURL = root.appending(path: "renderer.pid")
        let rendererURL = root.appending(path: "renderer.sh")
        try "#!/bin/sh\ntrap '' TERM\necho $$ > '\(pidURL.path)'\nwhile :; do :; done\n"
            .write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rendererURL.path)
        let configuration = SceneVideoRenderConfiguration(
            assetId: "preflight-timeout",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 320, height: 180),
            fps: 2,
            seconds: 1
        )

        var launchedPID: Int32?
        var rendererBecameReady = false
        XCTAssertThrowsError(try SceneVideoRenderer.preflight(
            configuration: configuration,
            timeout: 0.1,
            didLaunch: { pid in
                launchedPID = pid
                // Process.run() can return before /bin/sh has executed the
                // fixture. Start the timeout only after the script records its
                // PID and installs the TERM trap, so this test deterministically
                // exercises SIGKILL + reap even on a loaded CI runner.
                let deadline = Date().addingTimeInterval(30)
                while !FileManager.default.fileExists(atPath: pidURL.path), Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                rendererBecameReady = FileManager.default.fileExists(atPath: pidURL.path)
            }
        )) {
            XCTAssertEqual($0 as? SceneVideoRenderError, .preflightTimedOut)
        }
        XCTAssertTrue(rendererBecameReady, "Renderer fixture did not install its TERM trap")
        let pid = try XCTUnwrap(launchedPID)
        let recordedPID = try XCTUnwrap(Int32(try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(pid, recordedPID)
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "Timed-out renderer must no longer exist")
    }

    func testCancellingOneSceneProcessScopeDoesNotTerminateSiblingDisplayRender() async throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPIDURL = root.appending(path: "first.pid")
        let secondPIDURL = root.appending(path: "second.pid")
        let firstRendererURL = root.appending(path: "first-renderer.sh")
        let secondRendererURL = root.appending(path: "second-renderer.sh")
        try "#!/bin/sh\necho $$ > '\(firstPIDURL.path)'\nwhile :; do :; done\n"
            .write(to: firstRendererURL, atomically: true, encoding: .utf8)
        let secondScript = """
        #!/bin/sh
        set -e
        record_dir=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--record-dir" ]; then
            record_dir="$2"
          fi
          shift
        done
        echo $$ > "\(secondPIDURL.path)"
        : > "$record_dir/frame_00001.png"
        """
        try secondScript.write(to: secondRendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: firstRendererURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: secondRendererURL.path
        )
        let firstScope = "same-asset-1920x1080-balanced"
        let secondScope = "same-asset-2560x1440-balanced"
        defer {
            SceneVideoRenderer.cancelActiveProcesses(scopeID: firstScope)
            SceneVideoRenderer.cancelActiveProcesses(scopeID: secondScope)
        }
        let firstConfiguration = SceneVideoRenderConfiguration(
            assetId: "same-asset",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: firstRendererURL,
            size: CGSize(width: 320, height: 180),
            seconds: 1,
            processScopeID: firstScope
        )
        let secondConfiguration = SceneVideoRenderConfiguration(
            assetId: "same-asset",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: secondRendererURL,
            size: CGSize(width: 320, height: 180),
            seconds: 1,
            processScopeID: secondScope
        )

        let first = Task.detached {
            do {
                try SceneVideoRenderer.preflight(configuration: firstConfiguration, timeout: 2)
                return true
            } catch {
                return false
            }
        }
        let second = Task.detached {
            do {
                try SceneVideoRenderer.preflight(configuration: secondConfiguration, timeout: 2)
                return true
            } catch {
                return false
            }
        }
        let launchDeadline = Date().addingTimeInterval(1)
        while Date() < launchDeadline,
              (!FileManager.default.fileExists(atPath: firstPIDURL.path)
                || !FileManager.default.fileExists(atPath: secondPIDURL.path)) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPIDURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPIDURL.path))

        SceneVideoRenderer.cancelActiveProcesses(scopeID: firstScope)
        let firstSucceeded = await first.value
        let secondSucceeded = await second.value

        XCTAssertFalse(firstSucceeded)
        XCTAssertTrue(secondSucceeded)
    }

    func testScenePreflightPassesExplicitRenamedPackageToRenderer() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = root.appending(path: "renderer.sh")
        let package = root.appending(path: "scene.payload")
        let captured = root.appending(path: "captured-package.txt")
        try Data("fixture".utf8).write(to: package)
        try """
        #!/bin/sh
        set -eu
        record_dir=''
        scene_package=''
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --record-dir) record_dir="$2"; shift 2 ;;
            --scene-package) scene_package="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        printf '%s' "$scene_package" > "\(captured.path)"
        : > "$record_dir/frame_00001.png"
        """.write(to: renderer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: renderer.path
        )
        let configuration = SceneVideoRenderConfiguration(
            assetId: "renamed-preflight",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: renderer,
            size: CGSize(width: 320, height: 180),
            fps: 2,
            seconds: 1,
            sceneURL: package
        )

        try SceneVideoRenderer.preflight(configuration: configuration, timeout: 2)

        XCTAssertEqual(try String(contentsOf: captured, encoding: .utf8), package.path)
    }

    func testSceneProbeForceKillsReapsAndDrainsNoisyChild() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidURL = root.appending(path: "probe.pid")
        let probeURL = root.appending(path: "probe.sh")
        try "#!/bin/sh\necho $$ > '\(pidURL.path)'\ntrap '' TERM\nwhile :; do echo 0123456789abcdef; echo fedcba9876543210 >&2; done\n"
            .write(to: probeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probeURL.path)

        XCTAssertThrowsError(
            try SceneVideoRenderer.captureProcessOutput(
                executableURL: probeURL,
                arguments: [],
                assetID: "noisy-probe",
                timeout: 0.1
            )
        ) {
            XCTAssertEqual($0 as? SceneVideoRenderError, .processTimedOut("probe.sh"))
        }
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "Timed-out probe must be reaped")
    }

    @MainActor
    func testScenePlaybackFallsBackToNativeWhenRendererIsMissingOrNotExecutable() async throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let missingRendererURL = root.appending(path: "missing-renderer")
        let rendererURL = root.appending(path: "scene-engine-renderer")
        try "#!/bin/sh\nexit 0\n".write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rendererURL.path)
        let assetsDirectory = try Self.writeSceneEngineAssetsFixture(in: root)
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)
        let previousRendererPath = SceneEngineRendererConfiguration.overrideExecutablePath
        let previousAssetsPath = SceneEngineRendererConfiguration.overrideAssetsPath
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneEngineRendererConfiguration.overrideAssetsPath = assetsDirectory.path
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer {
            SceneEngineRendererConfiguration.overrideExecutablePath = previousRendererPath
            SceneEngineRendererConfiguration.overrideAssetsPath = previousAssetsPath
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }

        // When
        SceneEngineRendererConfiguration.overrideExecutablePath = missingRendererURL.path
        let missingView = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )
        let missingPreparingView = try XCTUnwrap(missingView as? PreparingSceneWallpaperView)
        let missingReady = await missingPreparingView.waitUntilNativeReadiness()
        XCTAssertTrue(missingReady)
        missingPreparingView.prepareForClose()
        SceneEngineRendererConfiguration.overrideExecutablePath = rendererURL.path
        let nonExecutableView = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )
        let nonExecutablePreparingView = try XCTUnwrap(nonExecutableView as? PreparingSceneWallpaperView)
        let nonExecutableReady = await nonExecutablePreparingView.waitUntilNativeReadiness()
        XCTAssertTrue(nonExecutableReady)
        nonExecutablePreparingView.prepareForClose()

        // Then
        XCTAssertEqual(missingPreparingView.readinessResult, true)
        XCTAssertEqual(nonExecutablePreparingView.readinessResult, true)
    }

    @MainActor
    func testVideoWallpaperViewAppliesAudioSettingsAtInitAndLive() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let videoURL = root.appending(path: "video.mp4")
        try "fake-video".write(to: videoURL, atomically: true, encoding: .utf8)

        // When: created with audio enabled at a non-default volume.
        let view = VideoWallpaperView(
            url: videoURL,
            fallbackImageURL: nil,
            frame: CGRect(x: 0, y: 0, width: 320, height: 200),
            displayMode: .fit,
            audioEnabled: true,
            audioVolume: 0.75
        )
        defer {
            view.prepareForClose()
        }

        // Then
        XCTAssertEqual(view.playerLayer.player?.isMuted, false)
        XCTAssertEqual(Double(try XCTUnwrap(view.playerLayer.player?.volume)), 0.75, accuracy: 0.0001)

        // When: the live setting changes without recreating the view.
        view.setAudioEnabled(false, volume: 0.2)

        // Then
        XCTAssertEqual(view.playerLayer.player?.isMuted, true)
        XCTAssertEqual(Double(try XCTUnwrap(view.playerLayer.player?.volume)), 0.2, accuracy: 0.0001)
    }

    @MainActor
    func testVideoWallpaperViewDefaultsToMutedForBackwardCompatibility() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let videoURL = root.appending(path: "video.mp4")
        try "fake-video".write(to: videoURL, atomically: true, encoding: .utf8)

        // When: created without specifying audio settings (existing call sites).
        let view = VideoWallpaperView(
            url: videoURL,
            fallbackImageURL: nil,
            frame: CGRect(x: 0, y: 0, width: 320, height: 200),
            displayMode: .fit
        )
        defer {
            view.prepareForClose()
        }

        // Then: playback stays silent, matching the previous hard-muted behavior.
        XCTAssertEqual(view.playerLayer.player?.isMuted, true)
    }

    func testSceneAudioExtractorReadsSoundLayersWithAuthoredVolume() {
        // Given: shaped like the real Dj CUTMAN / wave-ambience test scene.
        let scene: [String: Any] = [
            "objects": [
                [
                    "name": "Dj CUTMAN - Wigeon (feat. Bird Boy).mp3",
                    "sound": ["sounds/Dj CUTMAN - Wigeon (feat. Bird Boy).mp3"],
                    "volume": ["user": "musicvolume", "value": 0.8]
                ],
                [
                    "name": "waves.wav",
                    "sound": ["sounds/waves.wav"],
                    "volume": ["user": "wavesvolume", "value": 1.0]
                ],
                [
                    "name": "image-only-layer",
                    "image": "materials/bg.json"
                ]
            ]
        ]

        // When
        let tracks = SceneAudioExtractor.audioTracks(scene: scene)

        // Then
        XCTAssertEqual(tracks, [
            SceneAudioTrack(path: "sounds/Dj CUTMAN - Wigeon (feat. Bird Boy).mp3", volume: 0.8),
            SceneAudioTrack(path: "sounds/waves.wav", volume: 1.0)
        ])
    }

    func testSceneAudioExtractorDefaultsVolumeToOneWhenMissing() {
        // Given
        let scene: [String: Any] = [
            "objects": [
                ["sound": ["sounds/ambience.ogg"]]
            ]
        ]

        // When
        let tracks = SceneAudioExtractor.audioTracks(scene: scene)

        // Then
        XCTAssertEqual(tracks, [SceneAudioTrack(path: "sounds/ambience.ogg", volume: 1.0)])
    }

    func testSceneAudioExtractorReturnsEmptyWhenNoSoundLayers() {
        // Given
        let scene: [String: Any] = [
            "objects": [
                ["image": "materials/bg.json"]
            ]
        ]

        // Then
        XCTAssertTrue(SceneAudioExtractor.audioTracks(scene: scene).isEmpty)
    }

    func testSceneAudioMuxReportsMissingAuthoredTrackAsDegraded() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"sound":["sounds/missing.mp3"]}]}"#
        )
        let silentVideoURL = root.appending(path: "silent.mp4")
        try Data([0, 1, 2, 3]).write(to: silentVideoURL)

        let result = try SceneVideoRenderer.muxSceneAudioIfAvailable(
            sceneURL: packageURL,
            silentVideoURL: silentVideoURL,
            tempDirectory: root,
            ffmpegPath: "/missing/ffmpeg",
            loopSeconds: 20,
            assetID: "missing-audio"
        )

        XCTAssertEqual(result.outputURL, silentVideoURL)
        XCTAssertEqual(result.audioResult.state, .degraded)
        XCTAssertEqual(result.audioResult.diagnosticCode, "scene_authored_audio_unavailable")
        XCTAssertTrue(result.audioResult.warning?.contains("missing") == true)
    }

    func testSceneAudioMuxFailureReturnsVisualCacheWithDegradedAudioResult() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            entries: [
                (
                    "scene.json",
                    Data(#"{"objects":[{"sound":["sounds/music.mp3"]}]}"#.utf8)
                ),
                ("sounds/music.mp3", Data([0, 1, 2, 3]))
            ]
        )
        let silentVideoURL = root.appending(path: "silent.mp4")
        try Data([0, 1, 2, 3]).write(to: silentVideoURL)
        let previousProbe = SceneAudioDurationProbe.ffmpegProbeOutput
        let previousRunner = SceneVideoRenderer.runProcess
        SceneAudioDurationProbe.ffmpegProbeOutput = { _, _, _ in
            "Duration: 00:00:01.00, start: 0.000000, bitrate: 128 kb/s"
        }
        SceneVideoRenderer.runProcess = { _, _, _ in
            throw NSError(domain: "SceneAudioMuxFailure", code: 1)
        }
        defer {
            SceneAudioDurationProbe.ffmpegProbeOutput = previousProbe
            SceneVideoRenderer.runProcess = previousRunner
        }

        let result = try SceneVideoRenderer.muxSceneAudioIfAvailable(
            sceneURL: packageURL,
            silentVideoURL: silentVideoURL,
            tempDirectory: root,
            ffmpegPath: "/fake/ffmpeg",
            loopSeconds: 20,
            assetID: "failed-audio"
        )

        XCTAssertEqual(result.outputURL, silentVideoURL)
        XCTAssertEqual(result.audioResult.state, .degraded)
        XCTAssertEqual(result.audioResult.diagnosticCode, "scene_authored_audio_unavailable")
    }

    func testSceneVideoCacheMetadataRoundTripsAudioResult() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appending(path: "scene.mp4")
        try Data([0, 1, 2, 3]).write(to: videoURL)
        let expected = SceneRenderAudioResult.degraded(
            "Authored Scene audio could not be added to the rendered cache."
        )
        try SceneVideoCache.encodedMetadata(
            audioResult: expected,
            videoURL: videoURL
        ).write(
            to: SceneVideoCache.metadataURL(for: videoURL),
            options: .atomic
        )

        XCTAssertEqual(SceneVideoCache.metadata(for: videoURL)?.audioResult, expected)
    }

    func testSceneVideoCacheRejectsSidecarBoundToDifferentVideoBytes() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appending(path: "scene.mp4")
        try Data([0, 1, 2, 3]).write(to: videoURL)
        try SceneVideoCache.encodedMetadata(
            audioResult: .included,
            videoURL: videoURL
        ).write(
            to: SceneVideoCache.metadataURL(for: videoURL),
            options: .atomic
        )

        // Preserve the byte count so the SHA-256 binding, rather than only
        // the size check, is what rejects stale `included` metadata.
        try Data([3, 2, 1, 0]).write(to: videoURL, options: .atomic)

        XCTAssertNil(SceneVideoCache.metadata(for: videoURL))
    }

    func testSceneVideoCachePublishesImmutableGenerationsAndSelectsNewest() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }

        let sourceSceneURL = root.appending(path: "scene.pkg")
        try Data([0x50, 0x4B, 0x47, 0x56]).write(to: sourceSceneURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)],
            ofItemAtPath: sourceSceneURL.path
        )
        let logicalURL = SceneVideoCache.cachedVideoURL(assetId: "immutable-scene")
        let firstInput = root.appending(path: "first.mp4")
        try Data([0, 1, 2, 3]).write(to: firstInput)
        let firstGeneration = try SceneVideoCache.install(
            videoAt: firstInput,
            audioResult: .included,
            at: logicalURL
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60)],
            ofItemAtPath: firstGeneration.path
        )

        let secondInput = root.appending(path: "second.mp4")
        try Data([3, 2, 1, 0]).write(to: secondInput)
        let degraded = SceneRenderAudioResult.degraded(
            "Authored Scene audio is unavailable in the new generation."
        )
        let secondGeneration = try SceneVideoCache.install(
            videoAt: secondInput,
            audioResult: degraded,
            at: logicalURL
        )

        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertEqual(try Data(contentsOf: firstGeneration), Data([0, 1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: secondGeneration), Data([3, 2, 1, 0]))
        XCTAssertEqual(SceneVideoCache.metadata(for: firstGeneration)?.audioResult, .included)
        XCTAssertEqual(SceneVideoCache.metadata(for: secondGeneration)?.audioResult, degraded)
        let discovered = SceneVideoCache.freshCachedVideoURL(
            assetId: "immutable-scene",
            sourceURL: sourceSceneURL
        )
        XCTAssertEqual(
            discovered?.standardizedFileURL.resolvingSymlinksInPath().path,
            secondGeneration.standardizedFileURL.resolvingSymlinksInPath().path
        )
        XCTAssertFalse(
            SceneVideoCache.isCurrentPlaybackCacheURL(
                firstGeneration,
                preferredKeys: [],
                assetID: "immutable-scene",
                contentHash: nil,
                sourceURL: sourceSceneURL
            )
        )
        XCTAssertTrue(
            SceneVideoCache.isCurrentPlaybackCacheURL(
                secondGeneration,
                preferredKeys: [],
                assetID: "immutable-scene",
                contentHash: nil,
                sourceURL: sourceSceneURL
            )
        )
        try FileManager.default.removeItem(at: SceneVideoCache.cacheDirectoryURL())
        XCTAssertFalse(
            SceneVideoCache.isCurrentPlaybackCacheURL(
                secondGeneration,
                preferredKeys: [],
                assetID: "immutable-scene",
                contentHash: nil,
                sourceURL: sourceSceneURL
            )
        )
    }

    func testSceneVideoCacheContainsTraversalAssetIDInsideCacheDirectory() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        let cacheDirectory = root.appending(path: "SceneVideoCache")
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }

        let logicalURL = SceneVideoCache.cachedVideoURL(assetId: "../../outside")
        XCTAssertEqual(
            logicalURL.deletingLastPathComponent().standardizedFileURL.path,
            cacheDirectory.standardizedFileURL.path
        )
        XCTAssertFalse(logicalURL.lastPathComponent.contains("/"))
        XCTAssertNotEqual(logicalURL.lastPathComponent, "..")

        let inputURL = root.appending(path: "input.mp4")
        try Data([0, 1, 2, 3]).write(to: inputURL)
        let installedURL = try SceneVideoCache.install(
            videoAt: inputURL,
            audioResult: .notRequired,
            at: logicalURL
        )
        XCTAssertEqual(
            installedURL.deletingLastPathComponent().standardizedFileURL.path,
            cacheDirectory.standardizedFileURL.path
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "outside.mp4").path))
    }

    @MainActor
    func testCachedSceneReportIsLimitedWhenRequiredAudioIsDegraded() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            entries: [
                (
                    "scene.json",
                    Data(#"{"objects":[{"sound":["sounds/music.mp3"]}]}"#.utf8)
                ),
                ("sounds/music.mp3", Data([0, 1, 2, 3]))
            ]
        )
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)

        let report = SceneWallpaperContentFactory.cachedReport(
            for: asset,
            sceneURL: packageURL,
            audioResult: .degraded(
                "Authored Scene audio could not be added to the rendered cache."
            )
        )

        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
        XCTAssertTrue(report.requiredCapabilities.contains(.sound))
        XCTAssertTrue(report.missingCapabilities.contains(.sound))
        XCTAssertEqual(report.diagnosticCode, "scene_authored_audio_unavailable")
    }

    @MainActor
    func testCachedSceneReportIsFullWhenRequiredAudioIsIncluded() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            entries: [
                (
                    "scene.json",
                    Data(#"{"objects":[{"sound":["sounds/music.mp3"]}]}"#.utf8)
                ),
                ("sounds/music.mp3", Data([0, 1, 2, 3]))
            ]
        )
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)

        let report = SceneWallpaperContentFactory.cachedReport(
            for: asset,
            sceneURL: packageURL,
            audioResult: .included
        )

        XCTAssertEqual(report.level, .full)
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
        XCTAssertTrue(report.requiredCapabilities.contains(.sound))
        XCTAssertFalse(report.missingCapabilities.contains(.sound))
        XCTAssertNil(report.diagnosticCode)
    }

    @MainActor
    func testCachedSceneReportFailsClosedForMissingCorruptOrStaleSidecar() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            entries: [
                (
                    "scene.json",
                    Data(#"{"objects":[{"sound":["sounds/music.mp3"]}]}"#.utf8)
                ),
                ("sounds/music.mp3", Data([0, 1, 2, 3]))
            ]
        )
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)
        let cacheURL = root.appending(path: "scene.mp4")
        try Data([0, 1, 2, 3]).write(to: cacheURL)

        let missingReport = SceneWallpaperContentFactory.cachedReport(
            for: asset,
            sceneURL: packageURL,
            cacheURL: cacheURL
        )
        XCTAssertEqual(missingReport.level, .limited)
        XCTAssertTrue(missingReport.missingCapabilities.contains(.sound))
        XCTAssertEqual(missingReport.diagnosticCode, "scene_authored_audio_unavailable")

        try Data(#"{"broken":true}"#.utf8).write(
            to: SceneVideoCache.metadataURL(for: cacheURL)
        )
        let corruptReport = SceneWallpaperContentFactory.cachedReport(
            for: asset,
            sceneURL: packageURL,
            cacheURL: cacheURL
        )
        XCTAssertEqual(corruptReport.level, .limited)
        XCTAssertTrue(corruptReport.missingCapabilities.contains(.sound))

        try SceneVideoCache.encodedMetadata(
            audioResult: .included,
            videoURL: cacheURL
        ).write(
            to: SceneVideoCache.metadataURL(for: cacheURL),
            options: .atomic
        )
        try Data([3, 2, 1, 0]).write(to: cacheURL, options: .atomic)
        let staleReport = SceneWallpaperContentFactory.cachedReport(
            for: asset,
            sceneURL: packageURL,
            cacheURL: cacheURL
        )
        XCTAssertEqual(staleReport.level, .limited)
        XCTAssertTrue(staleReport.missingCapabilities.contains(.sound))
        XCTAssertEqual(staleReport.diagnosticCode, "scene_authored_audio_unavailable")
    }

    func testSceneAudioMuxBuildsSingleTrackFfmpegArgumentsWithExactRepeatCount() {
        // When: a single track whose own exact repeat count within the
        // stretched total is 1 playthrough (streamLoopValue 0, i.e. no
        // -stream_loop needed beyond the default single play).
        let arguments = SceneAudioMux.ffmpegArguments(
            videoURL: URL(filePath: "/tmp/scene-record/scene-render-output.mp4"),
            audioTracks: [(url: URL(filePath: "/tmp/scene-audio/audio-0.mp3"), weight: 0.8, streamLoopValue: 0)],
            outputURL: URL(filePath: "/tmp/scene-record/scene-render-with-audio.mp4"),
            totalDurationSeconds: 150.4
        )

        // Then
        XCTAssertEqual(arguments, [
            "-y",
            "-i",
            "/tmp/scene-record/scene-render-output.mp4",
            "-stream_loop",
            "0",
            "-i",
            "/tmp/scene-audio/audio-0.mp3",
            "-filter_complex",
            "[1:a]volume=0.800[mix];[mix]apad=whole_dur=150.400[a]",
            "-map",
            "0:v",
            "-map",
            "[a]",
            "-c:v",
            "copy",
            "-c:a",
            "aac",
            "-t",
            "150.400",
            "-movflags",
            "+faststart",
            "/tmp/scene-record/scene-render-with-audio.mp4"
        ])
    }

    /// Mirrors muxing the real 2-audio-file test scene (music.mp3 + waves.wav)
    /// referenced in the feature's diagnostics/report: both authored volumes
    /// (musicvolume 1.0, wavesvolume 1.0 in that fixture) are preserved as
    /// `amix` weights, and each track carries its own exact repeat count
    /// rather than one arbitrarily being singled out to loop forever.
    func testSceneAudioMuxBuildsMultiTrackAmixFfmpegArgumentsWithPerTrackRepeatCounts() {
        // When
        let arguments = SceneAudioMux.ffmpegArguments(
            videoURL: URL(filePath: "/tmp/scene-record/scene-render-output.mp4"),
            audioTracks: [
                (url: URL(filePath: "/tmp/scene-audio/audio-0.mp3"), weight: 1.0, streamLoopValue: 0),
                (url: URL(filePath: "/tmp/scene-audio/audio-1.wav"), weight: 1.0, streamLoopValue: 29)
            ],
            outputURL: URL(filePath: "/tmp/scene-record/scene-render-with-audio.mp4"),
            totalDurationSeconds: 150.4
        )

        // Then
        XCTAssertEqual(arguments, [
            "-y",
            "-i",
            "/tmp/scene-record/scene-render-output.mp4",
            "-stream_loop",
            "0",
            "-i",
            "/tmp/scene-audio/audio-0.mp3",
            "-stream_loop",
            "29",
            "-i",
            "/tmp/scene-audio/audio-1.wav",
            "-filter_complex",
            "[1:a]volume=1.000[a0];[2:a]volume=1.000[a1];[a0][a1]amix=inputs=2:duration=longest:normalize=0[mix];[mix]apad=whole_dur=150.400[a]",
            "-map",
            "0:v",
            "-map",
            "[a]",
            "-c:v",
            "copy",
            "-c:a",
            "aac",
            "-t",
            "150.400",
            "-movflags",
            "+faststart",
            "/tmp/scene-record/scene-render-with-audio.mp4"
        ])
    }

    func testSceneAudioMuxReturnsNoArgumentsWhenThereAreNoTracks() {
        // Then: render() never invokes ffmpeg for audio when there's nothing
        // to mux, leaving the cached video silent as before.
        XCTAssertTrue(SceneAudioMux.ffmpegArguments(
            videoURL: URL(filePath: "/tmp/video.mp4"),
            audioTracks: [],
            outputURL: URL(filePath: "/tmp/output.mp4"),
            totalDurationSeconds: 18.8
        ).isEmpty)
    }

    func testSceneAudioTrackLoopComputesExactRepeatCountWithoutMidPhraseCut() {
        // A 143.57s music track inside a 150.32s total plays exactly once
        // (150.32/143.57 rounds down to 1 playthrough), leaving the tail as
        // silence rather than looping and being cut off ~6.75s into a second
        // playthrough.
        XCTAssertEqual(
            SceneAudioTrackLoop.streamLoopValue(trackDurationSeconds: 143.57, totalDurationSeconds: 150.32),
            0
        )
        // A short 5s ambience loop inside the same total fits exactly 30
        // whole playthroughs (150.32/5 = 30.06, rounds down to 30), so
        // streamLoopValue is 29 (30 total plays = 29 extra loops).
        XCTAssertEqual(
            SceneAudioTrackLoop.streamLoopValue(trackDurationSeconds: 5.0, totalDurationSeconds: 150.32),
            29
        )
        // A track exactly as long as the total plays once.
        XCTAssertEqual(
            SceneAudioTrackLoop.streamLoopValue(trackDurationSeconds: 150.32, totalDurationSeconds: 150.32),
            0
        )
    }

    func testSceneAudioDurationProbeParsesFfmpegDurationLine() {
        // Given: a representative slice of real ffmpeg -i stderr output.
        let output = """
        Input #0, mp3, from '/tmp/audio-0.mp3':
          Duration: 00:02:23.57, start: 0.025056, bitrate: 257 kb/s
        """

        // Then
        XCTAssertEqual(SceneAudioDurationProbe.durationSeconds(fromFfmpegOutput: output) ?? 0, 143.57, accuracy: 0.001)
    }

    func testSceneAudioDurationProbeReturnsNilWhenNoDurationLinePresent() {
        XCTAssertNil(SceneAudioDurationProbe.durationSeconds(fromFfmpegOutput: "some unrelated ffmpeg error output"))
    }

    func testSceneAudioMasterDurationPicksLongestTrackCappedAtMaximum() {
        // Given/Then: ordinary case picks the longest track untouched.
        XCTAssertEqual(
            SceneAudioMasterDuration.masterDurationSeconds(trackDurationsSeconds: [143.57, 150.0]),
            150.0
        )
        // An unusually long authored track is capped rather than stretching
        // the cached video/render time unbounded.
        XCTAssertEqual(
            SceneAudioMasterDuration.masterDurationSeconds(trackDurationsSeconds: [1000]),
            SceneAudioMasterDuration.maximumSeconds
        )
        // No usable durations (e.g. every probe failed) yields nil so the
        // caller can fall back to the plain non-stretched loop.
        XCTAssertNil(SceneAudioMasterDuration.masterDurationSeconds(trackDurationsSeconds: []))
    }

    func testSceneVideoLoopExtensionComputesRepeatCountToCoverMasterDuration() {
        // A ~18.8s loop covering a ~150s soundtrack needs 8 repeats (150/18.8
        // rounds up to 8), for a total of 150.4s.
        let repeatCount = SceneVideoLoopExtension.repeatCount(loopSeconds: 18.8, masterDurationSeconds: 150.0)
        XCTAssertEqual(repeatCount, 8)
        XCTAssertEqual(
            SceneVideoLoopExtension.totalSeconds(loopSeconds: 18.8, repeatCount: repeatCount),
            150.4,
            accuracy: 0.001
        )
    }

    func testSceneVideoLoopExtensionSkipsStretchingWhenTrackIsShorterThanTheLoop() {
        // A soundtrack shorter than the video's own seamless loop should
        // never shrink the video - it just plays once within that loop.
        XCTAssertEqual(SceneVideoLoopExtension.repeatCount(loopSeconds: 18.8, masterDurationSeconds: 5.0), 1)
        XCTAssertEqual(SceneVideoLoopExtension.totalSeconds(loopSeconds: 18.8, repeatCount: 1), 18.8, accuracy: 0.001)
    }

    func testSceneVideoLoopExtensionBuildsStreamLoopCopyFfmpegArguments() {
        let arguments = SceneVideoLoopExtension.ffmpegArguments(
            loopableVideoURL: URL(filePath: "/tmp/scene-record/scene-render-output.mp4"),
            repeatCount: 8,
            totalSeconds: 150.4,
            outputURL: URL(filePath: "/tmp/scene-record/scene-render-extended.mp4")
        )
        XCTAssertEqual(arguments, [
            "-y",
            "-stream_loop",
            "7",
            "-i",
            "/tmp/scene-record/scene-render-output.mp4",
            "-c",
            "copy",
            "-t",
            "150.400",
            "-movflags",
            "+faststart",
            "/tmp/scene-record/scene-render-extended.mp4"
        ])
    }

    func testSceneVideoRendererBuildsRecordingAndFfmpegArguments() {
        // Given
        let configuration = SceneVideoRenderConfiguration(
            assetId: "MjQ2ODQ4OTIyMw",
            projectDirectory: URL(filePath: "/tmp/scene-project"),
            assetsDirectory: URL(filePath: "/tmp/wallpaper-engine-assets"),
            rendererURL: URL(filePath: "/tmp/background-engine-scene-renderer"),
            size: CGSize(width: 1920, height: 1080),
            fps: 30,
            seconds: 10
        )
        let recordDirectory = URL(filePath: "/tmp/scene-record")

        // When
        let recordingArguments = SceneVideoRenderer.recordingArguments(
            recordDirectory: recordDirectory,
            configuration: configuration
        )
        // 10s @ 30fps = 300 frames, comfortably more than the 2*36 = 72
        // frames the default 1.2s crossfade needs, so this exercises the
        // crossfade branch.
        let ffmpegArguments = SceneVideoRenderer.ffmpegArguments(
            framesDirectory: recordDirectory,
            fps: configuration.fps,
            recordedFrameCount: 300,
            outputURL: URL(filePath: "/tmp/scene-record/output.mp4")
        )

        // Then
        XCTAssertEqual(recordingArguments, [
            "--window",
            "0x0x1920x1080",
            "--silent",
            "--noautomute",
            "--no-audio-processing",
            "--disable-mouse",
            "--record-dir",
            "/tmp/scene-record",
            "--record-seconds",
            "10",
            "--record-fps",
            "30",
            "--assets-dir",
            "/tmp/wallpaper-engine-assets",
            "/tmp/scene-project"
        ])
        // K = round(1.2 * 30) = 36 crossfade frames.
        // offset = (300 - 2*36) / 30 = 228 / 30 = 7.6s.
        // duration = 36 / 30 = 1.2s.
        // output length = offset + duration = 8.8s = (300 - 36) / 30. ✓
        XCTAssertEqual(ffmpegArguments, [
            "-y",
            "-framerate",
            "30",
            "-i",
            "/tmp/scene-record/frame_%05d.png",
            "-framerate",
            "30",
            "-i",
            "/tmp/scene-record/frame_%05d.png",
            "-filter_complex",
            "[0:v]trim=start_frame=36,setpts=PTS-STARTPTS[main];"
                + "[1:v]trim=end_frame=36,setpts=PTS-STARTPTS[head];"
                + "[main][head]xfade=transition=fade:duration=1.200:offset=7.600[out]",
            "-map",
            "[out]",
            "-c:v",
            "h264_videotoolbox",
            "-allow_sw",
            "1",
            "-b:v",
            "12M",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            "/tmp/scene-record/output.mp4"
        ])
    }

    func testSceneVideoFfmpegArgumentsFallsBackToPlainEncodeWhenTooShortToCrossfade() {
        // Given: only 4 recorded frames, far too few for the default 1.2s
        // (36-frame @ 30fps) crossfade window to fit twice over.
        let ffmpegArguments = SceneVideoRenderer.ffmpegArguments(
            framesDirectory: URL(filePath: "/tmp/scene-record"),
            fps: 30,
            recordedFrameCount: 4,
            outputURL: URL(filePath: "/tmp/scene-record/output.mp4")
        )

        // Then: falls back to a single-input, filter-free encode rather than
        // building an invalid (negative-offset) xfade graph.
        XCTAssertEqual(ffmpegArguments, [
            "-y",
            "-framerate",
            "30",
            "-i",
            "/tmp/scene-record/frame_%05d.png",
            "-c:v",
            "h264_videotoolbox",
            "-allow_sw",
            "1",
            "-b:v",
            "12M",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            "/tmp/scene-record/output.mp4"
        ])
    }

    func testSceneVideoEncodingArgumentsUseNativeMPEG4ForSoftwareRecovery() {
        let outputURL = URL(filePath: "/tmp/scene-record/output.mp4")
        let pngArguments = SceneVideoRenderer.ffmpegArguments(
            framesDirectory: URL(filePath: "/tmp/scene-record"),
            fps: 30,
            recordedFrameCount: 4,
            outputURL: outputURL,
            encoder: .softwareMPEG4
        )
        let rawArguments = SceneVideoRenderer.rawEncodeFfmpegArguments(
            fifoURL: URL(filePath: "/tmp/scene-record/scene-raw.fifo"),
            size: CGSize(width: 320, height: 180),
            fps: 30,
            outputURL: outputURL,
            encoder: .softwareMPEG4
        )
        let crossfadeArguments = SceneVideoRenderer.videoCrossfadeFfmpegArguments(
            videoURL: URL(filePath: "/tmp/scene-record/intermediate.mp4"),
            fps: 30,
            recordedFrameCount: 300,
            outputURL: outputURL,
            encoder: .softwareMPEG4
        )

        for arguments in [pngArguments, rawArguments, crossfadeArguments] {
            XCTAssertTrue(arguments.contains("mpeg4"))
            XCTAssertTrue(arguments.contains("mp4v"))
            XCTAssertFalse(arguments.contains("h264_videotoolbox"))
            XCTAssertFalse(arguments.contains("-allow_sw"))
            XCTAssertEqual(arguments.last, outputURL.path)
        }
    }

    func testSceneVideoEncodingRetriesExactlyOnceAfterClassifiedVideoToolboxFailure() throws {
        var invocations: [[String]] = []

        let result = try SceneVideoRenderer.withVideoEncoderFallback { encoder -> String in
            invocations.append(encoder.arguments(bitRate: "12M"))
            if invocations.count == 1 {
                throw SceneProcessFailure(
                    name: "ffmpeg",
                    status: 1,
                    stderr: "[h264_videotoolbox] Cannot create compression session: -12903"
                )
            }
            return "recovered"
        }

        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(invocations.count, 2)
        XCTAssertTrue(invocations[0].contains("h264_videotoolbox"))
        XCTAssertTrue(invocations[1].contains("mpeg4"))
        XCTAssertTrue(invocations[1].contains("mp4v"))
    }

    func testSceneVideoEncodingDoesNotRetryArbitraryFfmpegFailure() {
        var invocationCount = 0
        let expected = SceneProcessFailure(
            name: "ffmpeg",
            status: 1,
            stderr: "No such filter: xfade"
        )

        XCTAssertThrowsError(
            try SceneVideoRenderer.withVideoEncoderFallback { _ -> Void in
                invocationCount += 1
                throw expected
            }
        ) { error in
            XCTAssertEqual(error as? SceneProcessFailure, expected)
        }
        XCTAssertEqual(invocationCount, 1)
    }

    func testSceneVideoEncodingDoesNotRetryCancellation() {
        var invocationCount = 0

        XCTAssertThrowsError(
            try SceneVideoRenderer.withVideoEncoderFallback { _ -> Void in
                invocationCount += 1
                throw CancellationError()
            }
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(invocationCount, 1)
    }

    func testSceneVideoEncodingFailureIncludesBothEncoderDiagnostics() {
        var invocationCount = 0

        XCTAssertThrowsError(
            try SceneVideoRenderer.withVideoEncoderFallback { _ -> Void in
                invocationCount += 1
                if invocationCount == 1 {
                    throw SceneProcessFailure(
                        name: "ffmpeg",
                        status: 1,
                        stderr: "Cannot prepare encoder: -12915"
                    )
                }
                throw SceneProcessFailure(
                    name: "ffmpeg",
                    status: 2,
                    stderr: "software encoder rejected the frame"
                )
            }
        ) { error in
            let fallbackError = error as? SceneVideoEncoderFallbackError
            XCTAssertNotNil(fallbackError)
            XCTAssertTrue(fallbackError?.localizedDescription.contains("-12915") == true)
            XCTAssertTrue(fallbackError?.localizedDescription.contains("software encoder rejected the frame") == true)
        }
        XCTAssertEqual(invocationCount, 2)
    }

    func testSceneVideoEncodingPreservesRawPipeStallRecoveryAfterSoftwareRetry() {
        var invocationCount = 0

        XCTAssertThrowsError(
            try SceneVideoRenderer.withVideoEncoderFallback { _ -> Void in
                invocationCount += 1
                if invocationCount == 1 {
                    throw SceneProcessFailure(
                        name: "ffmpeg",
                        status: 1,
                        stderr: "Cannot create compression session: -12903"
                    )
                }
                throw SceneVideoRenderError.rawPipeStalled
            }
        ) { error in
            XCTAssertEqual(error as? SceneVideoRenderError, .rawPipeStalled)
        }
        XCTAssertEqual(invocationCount, 2)
    }

    func testSceneRunProcessCapturesBoundedStderrOnFailure() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executableURL = root.appending(path: "failing-ffmpeg")
        try "#!/bin/sh\necho 'Cannot create compression session: -12903' >&2\nexit 7\n".write(
            to: executableURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        XCTAssertThrowsError(
            try SceneVideoRenderer.runProcess(executableURL, [], "stderr-capture")
        ) { error in
            let failure = error as? SceneProcessFailure
            XCTAssertEqual(failure?.status, 7)
            XCTAssertTrue(failure?.stderr.contains("Cannot create compression session: -12903") == true)
        }
    }

    func testSupportsRecordRawDetectsFlagInHelpOutput() {
        // Given: the real usage line contains "--record-raw" among many
        // other flags; a plain substring check is sufficient and doesn't
        // need to parse the whole usage grammar.
        let helpWithRecordRaw = """
        Usage: linux-wallpaperengine [--help] [--record-dir VAR] [--record-raw VAR] [--record-seconds VAR] background id
        """
        let helpWithoutRecordRaw = """
        Usage: linux-wallpaperengine [--help] [--record-dir VAR] [--record-seconds VAR] background id
        """

        // Then
        XCTAssertTrue(SceneVideoRenderer.supportsRecordRaw(helpOutput: helpWithRecordRaw))
        XCTAssertFalse(SceneVideoRenderer.supportsRecordRaw(helpOutput: helpWithoutRecordRaw))
        XCTAssertFalse(SceneVideoRenderer.supportsRecordRaw(helpOutput: ""))
    }

    func testRawRecordingArgumentsUseRecordRawInsteadOfRecordDir() {
        // Given
        let configuration = SceneVideoRenderConfiguration(
            assetId: "MjQ2ODQ4OTIyMw",
            projectDirectory: URL(filePath: "/tmp/scene-project"),
            assetsDirectory: URL(filePath: "/tmp/wallpaper-engine-assets"),
            rendererURL: URL(filePath: "/tmp/background-engine-scene-renderer"),
            size: CGSize(width: 1920, height: 1080),
            fps: 30,
            seconds: 10
        )
        let fifoURL = URL(filePath: "/tmp/scene-record/scene-raw.fifo")

        // When
        let arguments = SceneVideoRenderer.rawRecordingArguments(fifoURL: fifoURL, configuration: configuration)

        // Then
        XCTAssertEqual(arguments, [
            "--window",
            "0x0x1920x1080",
            "--silent",
            "--noautomute",
            "--no-audio-processing",
            "--disable-mouse",
            "--record-raw",
            "/tmp/scene-record/scene-raw.fifo",
            "--record-seconds",
            "10",
            "--record-fps",
            "30",
            "--assets-dir",
            "/tmp/wallpaper-engine-assets",
            "/tmp/scene-project"
        ])
    }

    func testSceneRecordingExcludesOnlyClockScriptsThatHaveNativeOverlays() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "background-engine-live-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clockPackage = root.appending(path: "clock.pkg")
        let labelPackage = root.appending(path: "label.pkg")
        try Self.writeScenePackage(
            to: clockPackage,
            sceneJSON: #"{"objects":[{"verticalalign":"top","text":{"value":"00:00","script":"export function update(value) { const time = new Date(); let hours = time.getHours(); let minutes = time.getMinutes(); if (hours < 10) { hours = '0' + hours; } if (minutes < 10) { minutes = '0' + minutes; } return hours + ':' + minutes; }"}}]}"#
        )
        try Self.writeScenePackage(
            to: labelPackage,
            sceneJSON: #"{"objects":[{"text":{"value":"READY","script":"export function update(value) { return 'READY'; }"}}]}"#
        )

        func arguments(for sceneURL: URL) -> [String] {
            SceneVideoRenderer.recordingArguments(
                recordDirectory: root,
                configuration: SceneVideoRenderConfiguration(
                    assetId: "live-text",
                    projectDirectory: root,
                    assetsDirectory: root,
                    rendererURL: root.appending(path: "renderer"),
                    size: CGSize(width: 320, height: 180),
                    fps: 2,
                    seconds: 1,
                    sceneURL: sceneURL
                )
            )
        }

        XCTAssertTrue(arguments(for: clockPackage).contains("--record-exclude-live"))
        XCTAssertFalse(arguments(for: labelPackage).contains("--record-exclude-live"))
    }

    func testSceneRendererArgumentsMountExplicitRenamedPackage() {
        let configuration = SceneVideoRenderConfiguration(
            assetId: "renamed-scene",
            projectDirectory: URL(filePath: "/tmp/scene-project"),
            assetsDirectory: URL(filePath: "/tmp/wallpaper-engine-assets"),
            rendererURL: URL(filePath: "/tmp/background-engine-scene-renderer"),
            size: CGSize(width: 320, height: 180),
            fps: 2,
            seconds: 1,
            sceneURL: URL(filePath: "/tmp/scene-project/nested/scene.payload")
        )

        let pngArguments = SceneVideoRenderer.recordingArguments(
            recordDirectory: URL(filePath: "/tmp/frames"),
            configuration: configuration
        )
        let rawArguments = SceneVideoRenderer.rawRecordingArguments(
            fifoURL: URL(filePath: "/tmp/frames.raw"),
            configuration: configuration
        )

        for arguments in [pngArguments, rawArguments] {
            let packageFlag = try? XCTUnwrap(arguments.firstIndex(of: "--scene-package"))
            XCTAssertEqual(packageFlag.map { arguments[$0 + 1] }, "/tmp/scene-project/nested/scene.payload")
            XCTAssertEqual(arguments.last, "/tmp/scene-project")
        }
    }

    func testRawEncodeFfmpegArgumentsReadRawRGBAFromFifo() {
        // When
        let arguments = SceneVideoRenderer.rawEncodeFfmpegArguments(
            fifoURL: URL(filePath: "/tmp/scene-record/scene-raw.fifo"),
            size: CGSize(width: 1920, height: 1080),
            fps: 30,
            outputURL: URL(filePath: "/tmp/scene-record/scene-render-raw.mp4")
        )

        // Then
        XCTAssertEqual(arguments, [
            "-y",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgba",
            "-s",
            "1920x1080",
            "-r",
            "30",
            "-i",
            "/tmp/scene-record/scene-raw.fifo",
            "-c:v",
            "h264_videotoolbox",
            "-allow_sw",
            "1",
            "-b:v",
            "40M",
            "-pix_fmt",
            "yuv420p",
            "/tmp/scene-record/scene-render-raw.mp4"
        ])
    }

    func testVideoCrossfadeFfmpegArgumentsMatchPNGSequenceCrossfadeMath() {
        // Given: identical frame/fps inputs to
        // testSceneVideoRendererBuildsRecordingAndFfmpegArguments, so the
        // crossfade filter string (offset/duration) should match exactly -
        // only the `-i` inputs differ (a video file read twice instead of a
        // PNG pattern read twice).
        let arguments = SceneVideoRenderer.videoCrossfadeFfmpegArguments(
            videoURL: URL(filePath: "/tmp/scene-record/scene-render-raw.mp4"),
            fps: 30,
            recordedFrameCount: 300,
            outputURL: URL(filePath: "/tmp/scene-record/output.mp4")
        )

        // Then
        XCTAssertEqual(arguments, [
            "-y",
            "-i",
            "/tmp/scene-record/scene-render-raw.mp4",
            "-i",
            "/tmp/scene-record/scene-render-raw.mp4",
            "-filter_complex",
            "[0:v]trim=start_frame=36,setpts=PTS-STARTPTS[main];"
                + "[1:v]trim=end_frame=36,setpts=PTS-STARTPTS[head];"
                + "[main][head]xfade=transition=fade:duration=1.200:offset=7.600[out]",
            "-map",
            "[out]",
            "-c:v",
            "h264_videotoolbox",
            "-allow_sw",
            "1",
            "-b:v",
            "12M",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            "/tmp/scene-record/output.mp4"
        ])
    }

    func testVideoCrossfadeFfmpegArgumentsFallsBackToPlainEncodeWhenTooShortToCrossfade() {
        // Given: only 4 recorded frames, far too few for the default 1.2s
        // crossfade window to fit twice over.
        let arguments = SceneVideoRenderer.videoCrossfadeFfmpegArguments(
            videoURL: URL(filePath: "/tmp/scene-record/scene-render-raw.mp4"),
            fps: 30,
            recordedFrameCount: 4,
            outputURL: URL(filePath: "/tmp/scene-record/output.mp4")
        )

        // Then
        XCTAssertEqual(arguments, [
            "-y",
            "-i",
            "/tmp/scene-record/scene-render-raw.mp4",
            "-c:v",
            "h264_videotoolbox",
            "-allow_sw",
            "1",
            "-b:v",
            "12M",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            "/tmp/scene-record/output.mp4"
        ])
    }

    func testFfmpegProgressParsingExtractsFrameCountFromSampleStderrLines() {
        // Real ffmpeg progress lines look like this (updated in place via
        // carriage returns, with trailing stats after the frame count).
        XCTAssertEqual(FfmpegProgressParsing.frameCount(fromLine: "frame=   45 fps=0.0 q=-1.0 Lsize=N/A"), 45)
        XCTAssertEqual(FfmpegProgressParsing.frameCount(fromLine: "frame=123"), 123)
        XCTAssertEqual(FfmpegProgressParsing.frameCount(fromLine: "frame=  600 fps=298 q=28.0 size=    2048kB time=00:00:20.00 bitrate= 838.9kbits/s speed=  10x"), 600)
        // Lines without a frame= token (e.g. other ffmpeg log chatter) yield
        // no progress update rather than a false reading.
        XCTAssertNil(FfmpegProgressParsing.frameCount(fromLine: "Output #0, mp4, to 'output.mp4':"))
        XCTAssertNil(FfmpegProgressParsing.frameCount(fromLine: ""))
    }

    func testFfmpegProgressParsingRecoversFinalCountSplitAcrossPipeReads() {
        var accumulator = FfmpegProgressLineAccumulator()
        let firstRead = Data("frame=   45 fps=2.0\rframe=".utf8)
        let secondRead = Data("  600 fps=30.0 time=00:00:20.00\r".utf8)

        XCTAssertEqual(accumulator.consume(firstRead), 45)
        XCTAssertEqual(accumulator.consume(secondRead), 600)
    }

    func testSceneVideoLoopCrossfadeMathProducesSeamlessLoopDuration() {
        // Given: a 20s @ 30fps recording (the app's default configuration).
        let fps = 30
        let totalFrameCount = 600

        // When
        let crossfadeFrameCount = SceneVideoLoopCrossfade.frameCount(totalFrameCount: totalFrameCount, fps: fps)
        let offsetSeconds = SceneVideoLoopCrossfade.offsetSeconds(
            totalFrameCount: totalFrameCount,
            crossfadeFrameCount: crossfadeFrameCount,
            fps: fps
        )
        let outputSeconds = SceneVideoLoopCrossfade.outputSeconds(
            totalFrameCount: totalFrameCount,
            crossfadeFrameCount: crossfadeFrameCount,
            fps: fps
        )

        // Then
        XCTAssertEqual(crossfadeFrameCount, 36) // round(1.2 * 30)
        XCTAssertEqual(offsetSeconds, (600.0 - 72.0) / 30.0, accuracy: 0.0001)
        // The crossfade's own output duration formula (offset + duration of
        // the transition) must equal totalSeconds - crossfadeSeconds, i.e.
        // the recorded clip minus exactly one crossfade window.
        let crossfadeSeconds = Double(crossfadeFrameCount) / Double(fps)
        XCTAssertEqual(offsetSeconds + crossfadeSeconds, outputSeconds, accuracy: 0.0001)
        XCTAssertEqual(outputSeconds, 20.0 - 1.2, accuracy: 0.0001)

        // Too-short recordings disable crossfading rather than producing a
        // negative offset.
        XCTAssertEqual(SceneVideoLoopCrossfade.frameCount(totalFrameCount: 2, fps: 2), 0)
        XCTAssertEqual(SceneVideoLoopCrossfade.frameCount(totalFrameCount: 0, fps: 30), 0)
    }

    func testSceneVideoRenderConfigurationDefaultsToTwentySecondsForLessFrequentLoopSeam() {
        // Given
        let configuration = SceneVideoRenderConfiguration(
            assetId: "asset",
            projectDirectory: URL(filePath: "/tmp/scene-project"),
            assetsDirectory: URL(filePath: "/tmp/wallpaper-engine-assets"),
            rendererURL: URL(filePath: "/tmp/background-engine-scene-renderer"),
            size: CGSize(width: 1920, height: 1080)
        )

        // Then
        XCTAssertEqual(configuration.seconds, 20)
        XCTAssertEqual(configuration.fps, 30)
    }

    func testSceneVideoRenderProgressFractionComputesFramesWrittenOverTarget() {
        // Then
        XCTAssertEqual(SceneVideoRenderProgress.fraction(recordedFrameCount: 0, targetFrameCount: 600), 0)
        XCTAssertEqual(SceneVideoRenderProgress.fraction(recordedFrameCount: 300, targetFrameCount: 600), 0.5)
        XCTAssertEqual(SceneVideoRenderProgress.fraction(recordedFrameCount: 600, targetFrameCount: 600), 1.0)
        // Overshoot (renderer produced extra frames) is clamped rather than exceeding 1.
        XCTAssertEqual(SceneVideoRenderProgress.fraction(recordedFrameCount: 900, targetFrameCount: 600), 1.0)
        // A zero/unknown target is treated as no progress rather than dividing by zero.
        XCTAssertEqual(SceneVideoRenderProgress.fraction(recordedFrameCount: 10, targetFrameCount: 0), 0)
    }

    func testSceneRecordedFrameSequenceRejectsOneFrameAndTruncatedOutput() {
        XCTAssertThrowsError(
            try SceneRecordedFrameSequence.validateRendererCompletion(
                rendererName: "scene-renderer",
                status: 0,
                stderr: "",
                recordedFrameCount: 1,
                targetFrameCount: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneVideoRenderError,
                .incompleteFrameSequence(expectedAtLeast: 2, actual: 1)
            )
        }

        XCTAssertThrowsError(
            try SceneRecordedFrameSequence.validateRendererCompletion(
                rendererName: "scene-renderer",
                status: 0,
                stderr: "",
                recordedFrameCount: 1,
                targetFrameCount: 600
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneVideoRenderError,
                .incompleteFrameSequence(expectedAtLeast: 599, actual: 1)
            )
        }

        XCTAssertThrowsError(
            try SceneRecordedFrameSequence.validateRendererCompletion(
                rendererName: "scene-renderer",
                status: 0,
                stderr: "",
                recordedFrameCount: 598,
                targetFrameCount: 600
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneVideoRenderError,
                .incompleteFrameSequence(expectedAtLeast: 599, actual: 598)
            )
        }
    }

    func testSceneRecordedFrameSequenceAllowsOnlyCompleteNonzeroRendererExit() {
        XCTAssertNoThrow(
            try SceneRecordedFrameSequence.validateRendererCompletion(
                rendererName: "scene-renderer",
                status: 9,
                stderr: "shutdown cleanup crashed",
                recordedFrameCount: 599,
                targetFrameCount: 600
            )
        )

        XCTAssertThrowsError(
            try SceneRecordedFrameSequence.validateRendererCompletion(
                rendererName: "scene-renderer",
                status: 9,
                stderr: "render stopped early",
                recordedFrameCount: 598,
                targetFrameCount: 600
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneProcessFailure,
                SceneProcessFailure(
                    name: "scene-renderer",
                    status: 9,
                    stderr: "render stopped early"
                )
            )
        }
    }

    func testSceneRecordedPNGFramesMustBeExactlyContiguous() throws {
        XCTAssertEqual(
            try SceneRecordedFrameSequence.contiguousPNGFrameCount(
                fileNames: [
                    "unrelated.log",
                    "frame_00003.png",
                    "frame_00001.png",
                    "frame_00002.png"
                ]
            ),
            3
        )

        XCTAssertThrowsError(
            try SceneRecordedFrameSequence.contiguousPNGFrameCount(
                fileNames: ["frame_00001.png", "frame_00003.png"]
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneVideoRenderError,
                .nonContiguousFrameSequence(
                    expected: "frame_00002.png",
                    found: "frame_00003.png"
                )
            )
        }

        XCTAssertThrowsError(
            try SceneRecordedFrameSequence.contiguousPNGFrameCount(
                fileNames: ["frame_00001.png", "frame_preview.png"]
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneVideoRenderError,
                .nonContiguousFrameSequence(
                    expected: "frame_00002.png",
                    found: "frame_preview.png"
                )
            )
        }
    }

    func testPNGSceneRenderRejectsTruncatedSequenceBeforeEncoding() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rendererURL = root.appending(path: "truncated-png-renderer")
        let rendererScript = """
        #!/bin/sh
        record_dir=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--record-dir" ]; then
            record_dir="$2"
          fi
          shift
        done
        : > "$record_dir/frame_00001.png"
        """
        try rendererScript.write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: rendererURL.path
        )
        let previousHelpOutput = SceneVideoRenderer.rendererHelpOutput
        SceneVideoRenderer.rendererHelpOutput = { _, _ in "" }
        defer { SceneVideoRenderer.rendererHelpOutput = previousHelpOutput }
        let configuration = SceneVideoRenderConfiguration(
            assetId: "truncated-png",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 32, height: 32),
            fps: 30,
            seconds: 1
        )

        XCTAssertThrowsError(
            try SceneVideoRenderer.render(
                configuration: configuration,
                ffmpegPath: "/usr/bin/false"
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneVideoRenderError,
                .incompleteFrameSequence(expectedAtLeast: 30, actual: 1)
            )
        }
    }

    func testPNGSceneRenderCapturesRendererStderrForEarlyNonzeroExit() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rendererURL = root.appending(path: "failed-png-renderer")
        let rendererScript = """
        #!/bin/sh
        record_dir=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--record-dir" ]; then
            record_dir="$2"
          fi
          shift
        done
        : > "$record_dir/frame_00001.png"
        echo 'renderer stopped at frame one' >&2
        exit 7
        """
        try rendererScript.write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: rendererURL.path
        )
        let previousHelpOutput = SceneVideoRenderer.rendererHelpOutput
        SceneVideoRenderer.rendererHelpOutput = { _, _ in "" }
        defer { SceneVideoRenderer.rendererHelpOutput = previousHelpOutput }
        let configuration = SceneVideoRenderConfiguration(
            assetId: "failed-png",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 32, height: 32),
            fps: 30,
            seconds: 1
        )

        XCTAssertThrowsError(
            try SceneVideoRenderer.render(
                configuration: configuration,
                ffmpegPath: "/usr/bin/false"
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneProcessFailure,
                SceneProcessFailure(
                    name: rendererURL.lastPathComponent,
                    status: 7,
                    stderr: "renderer stopped at frame one\n"
                )
            )
        }
    }

    func testPNGSceneRenderAllowsNonzeroShutdownOnlyAfterCompleteFrames() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rendererURL = root.appending(path: "complete-then-crash-renderer")
        let rendererScript = """
        #!/bin/sh
        record_dir=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--record-dir" ]; then
            record_dir="$2"
          fi
          shift
        done
        : > "$record_dir/frame_00001.png"
        : > "$record_dir/frame_00002.png"
        echo 'shutdown cleanup crashed' >&2
        exit 9
        """
        try rendererScript.write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: rendererURL.path
        )
        let previousHelpOutput = SceneVideoRenderer.rendererHelpOutput
        let previousRunProcess = SceneVideoRenderer.runProcess
        SceneVideoRenderer.rendererHelpOutput = { _, _ in "" }
        SceneVideoRenderer.runProcess = { _, _, _ in
            throw SceneProcessFailure(
                name: "encoding-probe",
                status: 55,
                stderr: "complete recording reached the encoder"
            )
        }
        defer {
            SceneVideoRenderer.rendererHelpOutput = previousHelpOutput
            SceneVideoRenderer.runProcess = previousRunProcess
        }
        let configuration = SceneVideoRenderConfiguration(
            assetId: "complete-then-crash",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 32, height: 32),
            fps: 2,
            seconds: 1
        )

        XCTAssertThrowsError(
            try SceneVideoRenderer.render(
                configuration: configuration,
                ffmpegPath: "/usr/bin/false"
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneProcessFailure,
                SceneProcessFailure(
                    name: "encoding-probe",
                    status: 55,
                    stderr: "complete recording reached the encoder"
                ),
                "A tolerated shutdown crash must proceed to encoding only after the complete frame sequence exists."
            )
        }
    }

    func testRawSceneRenderRejectsTruncatedSequenceBeforeCrossfade() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rendererURL = root.appending(path: "truncated-raw-renderer")
        let rendererScript = """
        #!/bin/sh
        if [ "$1" = "--help" ]; then
          echo "Usage: renderer [--record-raw]"
          exit 0
        fi
        fifo=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--record-raw" ]; then
            fifo="$2"
          fi
          shift
        done
        printf 'one-frame' > "$fifo"
        """
        try rendererScript.write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: rendererURL.path
        )
        let fakeFFmpegURL = root.appending(path: "counting-ffmpeg")
        let fakeFFmpegScript = """
        #!/bin/sh
        fifo=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-i" ]; then
            fifo="$2"
            break
          fi
          shift
        done
        /bin/cat "$fifo" >/dev/null
        echo 'frame=    1 fps=1.0' >&2
        """
        try fakeFFmpegScript.write(to: fakeFFmpegURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeFFmpegURL.path
        )
        let configuration = SceneVideoRenderConfiguration(
            assetId: "truncated-raw",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 32, height: 32),
            fps: 30,
            seconds: 1
        )

        XCTAssertThrowsError(
            try SceneVideoRenderer.render(
                configuration: configuration,
                ffmpegPath: fakeFFmpegURL.path
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneVideoRenderError,
                .incompleteFrameSequence(expectedAtLeast: 30, actual: 1)
            )
        }
    }

    func testRawSceneRenderReportsEarlyRendererFailureWhenEncoderAlsoFails() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rendererURL = root.appending(path: "failed-raw-renderer")
        let rendererScript = """
        #!/bin/sh
        if [ "$1" = "--help" ]; then
          echo "Usage: renderer [--record-raw]"
          exit 0
        fi
        fifo=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--record-raw" ]; then
            fifo="$2"
          fi
          shift
        done
        printf 'one-frame' > "$fifo"
        echo 'renderer stopped before completing the stream' >&2
        exit 9
        """
        try rendererScript.write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: rendererURL.path
        )
        let fakeFFmpegURL = root.appending(path: "failed-counting-ffmpeg")
        let fakeFFmpegScript = """
        #!/bin/sh
        fifo=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-i" ]; then
            fifo="$2"
            break
          fi
          shift
        done
        /bin/cat "$fifo" >/dev/null
        echo 'frame=    1 fps=1.0' >&2
        echo 'encoder rejected truncated input' >&2
        exit 7
        """
        try fakeFFmpegScript.write(to: fakeFFmpegURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeFFmpegURL.path
        )
        let configuration = SceneVideoRenderConfiguration(
            assetId: "failed-truncated-raw",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 32, height: 32),
            fps: 30,
            seconds: 1
        )

        XCTAssertThrowsError(
            try SceneVideoRenderer.render(
                configuration: configuration,
                ffmpegPath: fakeFFmpegURL.path
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneProcessFailure,
                SceneProcessFailure(
                    name: rendererURL.lastPathComponent,
                    status: 9,
                    stderr: "renderer stopped before completing the stream\n"
                )
            )
        }
    }

    func testRawPipelineKeepsClassifiedVideoToolboxFailureWhenRendererDiesAfterFIFOCloses() {
        let failure = SceneRawPipelineFailureSelection.failure(
            rendererName: "background-engine-scene-renderer",
            rendererStatus: SIGPIPE,
            rendererStderr: "",
            recordedFrameCount: 1,
            targetFrameCount: 600,
            ffmpegStatus: 1,
            ffmpegStderr: "[h264_videotoolbox] Cannot create compression session: -12903"
        )

        XCTAssertEqual(
            failure,
            SceneProcessFailure(
                name: "ffmpeg",
                status: 1,
                stderr: "[h264_videotoolbox] Cannot create compression session: -12903"
            ),
            "A VideoToolbox failure that closes the FIFO must still reach the software encoder fallback."
        )
    }

    func testSceneVideoRendererReportsProgressWhileRecordingAndCompletesAtFullProgress() throws {
        guard let ffmpegPath = Self.ffmpegPathForIntegrationTests() else {
            throw XCTSkip("ffmpeg is required to encode the scene render fixture.")
        }

        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        let cacheDirectory = root.appending(path: "SceneVideoCache")
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer {
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }

        // A fake renderer that trickles frames out with a short pause between
        // each one, so the progress monitor's polling has a chance to observe
        // partial progress before the process exits.
        let rendererURL = root.appending(path: "fake-scene-renderer")
        let frameImageURL = try Self.writeSolidColorPNG(size: CGSize(width: 32, height: 32))
        let rendererScript = """
        #!/bin/sh
        set -e
        record_dir=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--record-dir" ]; then
            record_dir="$2"
          fi
          shift
        done
        cp "\(frameImageURL.path)" "$record_dir/frame_00001.png"
        sleep 0.4
        cp "\(frameImageURL.path)" "$record_dir/frame_00002.png"
        """
        try rendererScript.write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rendererURL.path)

        let configuration = SceneVideoRenderConfiguration(
            assetId: "MjQ2ODQ4OTIyMw",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 32, height: 32),
            fps: 2,
            seconds: 1
        )

        // When
        let reportedProgress = ProgressRecorder()
        let outputURL = try SceneVideoRenderer.render(
            configuration: configuration,
            ffmpegPath: ffmpegPath,
            progressHandler: { progress in
                reportedProgress.record(progress)
            }
        )

        // Then
        XCTAssertEqual(
            outputURL.deletingLastPathComponent().standardizedFileURL.path,
            SceneVideoCache.cacheDirectoryURL().standardizedFileURL.path
        )
        XCTAssertTrue(outputURL.lastPathComponent.hasPrefix("\(configuration.assetId)-g"))
        let values = reportedProgress.values
        XCTAssertFalse(values.isEmpty, "Expected the progress handler to be invoked at least once.")
        XCTAssertEqual(values.last, 1.0, "Rendering should always finish by reporting full progress.")
        XCTAssertTrue(values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testSceneVideoRecordSizeClampsLongEdgeAndPreservesAspectRatio() {
        // A logical size below the cap is used as-is (already even).
        XCTAssertEqual(
            SceneVideoRecordSize.clampedRecordSize(forLogicalSize: CGSize(width: 1512, height: 982)),
            CGSize(width: 1512, height: 982)
        )

        // A retina display's *physical* pixel size (e.g. doubled 3024x1964)
        // is exactly the case this guards against: it must be clamped down,
        // not recorded at full size.
        let clampedRetina = SceneVideoRecordSize.clampedRecordSize(forLogicalSize: CGSize(width: 3024, height: 1964))
        XCTAssertLessThanOrEqual(max(clampedRetina.width, clampedRetina.height), SceneVideoRecordSize.defaultMaxLongEdge)
        XCTAssertEqual(clampedRetina.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(clampedRetina.height.truncatingRemainder(dividingBy: 2), 0)
        // Aspect ratio should be preserved (within rounding to even pixels).
        XCTAssertEqual(clampedRetina.width / clampedRetina.height, 3024.0 / 1964.0, accuracy: 0.01)

        // A custom cap is honored.
        let clampedCustom = SceneVideoRecordSize.clampedRecordSize(
            forLogicalSize: CGSize(width: 2560, height: 1440),
            maxLongEdge: 1920
        )
        XCTAssertEqual(clampedCustom, CGSize(width: 1920, height: 1080))

        // Degenerate input falls back to a square using the cap.
        XCTAssertEqual(
            SceneVideoRecordSize.clampedRecordSize(forLogicalSize: .zero),
            CGSize(width: SceneVideoRecordSize.defaultMaxLongEdge, height: SceneVideoRecordSize.defaultMaxLongEdge)
        )
    }

    func testSceneVideoRecordSizePreservesCanvasAspectForPerDisplayLayout() {
        let wideCanvas = CGSize(width: 2_560, height: 1_080)
        let squareDisplay = CGSize(width: 1_000, height: 1_000)

        let size = SceneVideoRecordSize.clampedRecordSize(
            forSceneCanvas: wideCanvas,
            displayLogicalSize: squareDisplay
        )

        XCTAssertEqual(size, CGSize(width: 1_000, height: 422))
        XCTAssertEqual(size.width / size.height, wideCanvas.width / wideCanvas.height, accuracy: 0.01)
    }

    func testSceneVideoCacheDirectoryIsVersionedToInvalidateStaleRenders() {
        // Given
        let previousOverride = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = nil
        defer {
            SceneVideoCache.overrideCacheDirectoryURL = previousOverride
        }

        // When
        let cacheDirectory = SceneVideoCache.cacheDirectoryURL()

        // Then: the cache lives under a version-numbered subdirectory, so
        // bumping `cacheVersion` (done when the render pipeline changes in a
        // way that invalidates old clips, e.g. the record-size fix) causes
        // every previously cached video to simply never be found again.
        XCTAssertEqual(cacheDirectory.lastPathComponent, "v\(SceneVideoCache.cacheVersion)")
        XCTAssertGreaterThanOrEqual(SceneVideoCache.cacheVersion, 14)
    }

    func testSceneVideoCacheFreshnessComparesModificationDates() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let sourceURL = root.appending(path: "scene.pkg")
        try "scene".write(to: sourceURL, atomically: true, encoding: .utf8)
        let cacheURL = root.appending(path: "cached.mp4")

        // Then
        XCTAssertNil(SceneVideoCache.freshCachedVideoURL(assetId: "missing", sourceURL: sourceURL))

        // When the cache is written after the source, it is fresh.
        try "video".write(to: cacheURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(SceneVideoCache.isFresh(cacheURL: cacheURL, sourceURL: sourceURL))

        // When the source is modified after the cache, it is stale.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)],
            ofItemAtPath: sourceURL.path
        )
        XCTAssertFalse(SceneVideoCache.isFresh(cacheURL: cacheURL, sourceURL: sourceURL))
    }

    func testHashedSceneRevisionNeverFallsBackToLegacyIDOnlyCache() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }
        try FileManager.default.createDirectory(
            at: SceneVideoCache.cacheDirectoryURL(),
            withIntermediateDirectories: true
        )
        let sourceURL = root.appending(path: "renamed-scene.payload")
        try Data([0x50, 0x4B, 0x47, 0x56]).write(to: sourceURL)
        let legacyCacheURL = SceneVideoCache.cachedVideoURL(assetId: "updated-scene")
        try Data([0, 0, 0, 1]).write(to: legacyCacheURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3_600)],
            ofItemAtPath: legacyCacheURL.path
        )

        XCTAssertNil(
            SceneVideoCache.freshPlaybackCacheURL(
                preferredKeys: [],
                assetID: "updated-scene",
                contentHash: "new-content-hash",
                sourceURL: sourceURL
            )
        )
        let discoveredLegacyCacheURL = SceneVideoCache.freshPlaybackCacheURL(
                preferredKeys: [],
                assetID: "updated-scene",
                contentHash: nil,
                sourceURL: sourceURL
        )
        XCTAssertEqual(
            discoveredLegacyCacheURL?.resolvingSymlinksInPath().path,
            legacyCacheURL.resolvingSymlinksInPath().path
        )
    }

    func testHashedSceneCacheDiscoveryNeverReturnsMetadataSidecar() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }
        try FileManager.default.createDirectory(
            at: SceneVideoCache.cacheDirectoryURL(),
            withIntermediateDirectories: true
        )
        let sourceURL = root.appending(path: "scene.pkg")
        try Data([0x50, 0x4B, 0x47, 0x56]).write(to: sourceURL)
        let key = SceneVideoCacheKey(
            assetID: "scene",
            contentHash: "0123456789abcdef",
            rendererVersion: SceneVideoCache.rendererVersion,
            width: 1280,
            height: 720,
            quality: .low
        )
        let videoURL = SceneVideoCache.cachedVideoURL(key: key)
        let sidecarURL = SceneVideoCache.metadataURL(for: videoURL)
        try Data(#"{"sidecarOnly":true}"#.utf8).write(to: sidecarURL)

        XCTAssertNil(
            SceneVideoCache.freshCachedVideoURL(
                assetID: key.assetID,
                contentHash: key.contentHash,
                sourceURL: sourceURL
            )
        )

        try Data([0, 0, 0, 1]).write(to: videoURL)
        try SceneVideoCache.encodedMetadata(
            audioResult: .included,
            videoURL: videoURL
        ).write(
            to: sidecarURL
        )

        let discovered = SceneVideoCache.freshCachedVideoURL(
            assetID: key.assetID,
            contentHash: key.contentHash,
            sourceURL: sourceURL
        )

        XCTAssertEqual(
            discovered?.standardizedFileURL.resolvingSymlinksInPath().path,
            videoURL.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    func testSceneCacheDiscoveryRejectsSymlinkedVideoCandidate() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }
        try FileManager.default.createDirectory(
            at: SceneVideoCache.cacheDirectoryURL(),
            withIntermediateDirectories: true
        )
        let sourceURL = root.appending(path: "scene.pkg")
        try Data([0x50, 0x4B, 0x47, 0x56]).write(to: sourceURL)
        let outsideVideoURL = root.appending(path: "outside.mp4")
        try Data([0, 1, 2, 3]).write(to: outsideVideoURL)
        let candidateURL = SceneVideoCache.cachedVideoURL(assetId: "symlink-scene")
        try FileManager.default.createSymbolicLink(
            at: candidateURL,
            withDestinationURL: outsideVideoURL
        )

        XCTAssertNil(
            SceneVideoCache.freshCachedVideoURL(
                assetId: "symlink-scene",
                sourceURL: sourceURL
            )
        )
    }

    func testSceneVideoRendererEncodesRecordedFramesIntoCachedMp4() throws {
        guard let ffmpegPath = Self.ffmpegPathForIntegrationTests() else {
            throw XCTSkip("ffmpeg is required to encode the scene render fixture.")
        }

        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        let cacheDirectory = root.appending(path: "SceneVideoCache")
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer {
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }

        // A fake renderer script that drops two solid-color PNG frames into
        // the --record-dir it is given, standing in for the real
        // background-engine-scene-renderer binary.
        let rendererURL = root.appending(path: "fake-scene-renderer")
        let frameImageURL = try Self.writeSolidColorPNG(size: CGSize(width: 32, height: 32))
        let rendererScript = """
        #!/bin/sh
        set -e
        record_dir=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--record-dir" ]; then
            record_dir="$2"
          fi
          shift
        done
        cp "\(frameImageURL.path)" "$record_dir/frame_00001.png"
        cp "\(frameImageURL.path)" "$record_dir/frame_00002.png"
        """
        try rendererScript.write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rendererURL.path)

        let configuration = SceneVideoRenderConfiguration(
            assetId: "MjQ2ODQ4OTIyMw",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 32, height: 32),
            fps: 2,
            seconds: 1
        )

        // When
        let outputURL = try SceneVideoRenderer.render(configuration: configuration, ffmpegPath: ffmpegPath)

        // Then
        XCTAssertEqual(
            outputURL.deletingLastPathComponent().standardizedFileURL.path,
            SceneVideoCache.cacheDirectoryURL().standardizedFileURL.path
        )
        XCTAssertTrue(outputURL.lastPathComponent.hasPrefix("\(configuration.assetId)-g"))
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertGreaterThan((attributes[.size] as? Int) ?? 0, 0)
        let validatedAudio = try SceneVideoRenderer.validatedAudioResult(
            for: SceneAudioMuxResult(outputURL: outputURL, audioResult: .included),
            ffmpegPath: ffmpegPath,
            assetID: configuration.assetId
        )
        XCTAssertEqual(validatedAudio.state, .degraded)
        XCTAssertEqual(validatedAudio.diagnosticCode, "scene_authored_audio_unavailable")
    }

    @MainActor
    func testSceneVideoRendererPersistsIncludedAuthoredAudioOutcome() throws {
        guard let ffmpegPath = Self.ffmpegPathForIntegrationTests() else {
            throw XCTSkip("ffmpeg is required to verify authored Scene audio muxing.")
        }

        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }

        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            entries: [
                (
                    "scene.json",
                    Data(#"{"objects":[{"sound":["sounds/tone.wav"],"volume":{"value":0.5}}]}"#.utf8)
                ),
                ("sounds/tone.wav", Self.silentPCM16WAV())
            ]
        )
        let rendererURL = root.appending(path: "fake-scene-renderer")
        let frameImageURL = try Self.writeSolidColorPNG(size: CGSize(width: 32, height: 32))
        defer { try? FileManager.default.removeItem(at: frameImageURL) }
        let rendererScript = """
        #!/bin/sh
        set -e
        record_dir=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--record-dir" ]; then
            record_dir="$2"
          fi
          shift
        done
        cp "\(frameImageURL.path)" "$record_dir/frame_00001.png"
        cp "\(frameImageURL.path)" "$record_dir/frame_00002.png"
        """
        try rendererScript.write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: rendererURL.path
        )
        let configuration = SceneVideoRenderConfiguration(
            assetId: "scene-with-audio",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 32, height: 32),
            fps: 2,
            seconds: 1,
            sceneURL: packageURL,
            contentHash: "audio-content-hash",
            quality: .low,
            engineAssetsFingerprint: "audio-assets"
        )

        let outcome = try SceneVideoRenderer.renderWithOutcome(
            configuration: configuration,
            ffmpegPath: ffmpegPath
        )

        XCTAssertEqual(outcome.audioResult, .included)
        XCTAssertEqual(
            SceneVideoCache.metadata(for: outcome.cacheURL)?.audioResult,
            .included
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.cacheURL.path))
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)
        let report = SceneWallpaperContentFactory.cachedReport(
            for: asset,
            sceneURL: packageURL,
            cacheURL: outcome.cacheURL
        )
        XCTAssertEqual(report.level, .full)
        XCTAssertFalse(report.missingCapabilities.contains(.sound))
        XCTAssertNil(report.diagnosticCode)
    }

    @MainActor
    func testSceneVideoRendererPersistsDegradedAudioAndRelaunchReportReadsSidecar() throws {
        guard let ffmpegPath = Self.ffmpegPathForIntegrationTests() else {
            throw XCTSkip("ffmpeg is required to verify degraded Scene audio metadata.")
        }

        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }

        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"sound":["sounds/missing.wav"]}]}"#
        )
        let rendererURL = root.appending(path: "fake-scene-renderer")
        let frameImageURL = try Self.writeSolidColorPNG(size: CGSize(width: 32, height: 32))
        defer { try? FileManager.default.removeItem(at: frameImageURL) }
        let rendererScript = """
        #!/bin/sh
        set -e
        record_dir=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--record-dir" ]; then
            record_dir="$2"
          fi
          shift
        done
        cp "\(frameImageURL.path)" "$record_dir/frame_00001.png"
        cp "\(frameImageURL.path)" "$record_dir/frame_00002.png"
        """
        try rendererScript.write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: rendererURL.path
        )
        let configuration = SceneVideoRenderConfiguration(
            assetId: "scene-with-missing-audio",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 32, height: 32),
            fps: 2,
            seconds: 1,
            sceneURL: packageURL,
            contentHash: "missing-audio-content-hash",
            quality: .low,
            engineAssetsFingerprint: "audio-assets"
        )

        let outcome = try SceneVideoRenderer.renderWithOutcome(
            configuration: configuration,
            ffmpegPath: ffmpegPath
        )

        XCTAssertEqual(outcome.audioResult.state, .degraded)
        XCTAssertEqual(
            SceneVideoCache.metadata(for: outcome.cacheURL)?.audioResult,
            outcome.audioResult
        )
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)
        let reportAfterRelaunch = SceneWallpaperContentFactory.cachedReport(
            for: asset,
            sceneURL: packageURL,
            cacheURL: outcome.cacheURL
        )
        XCTAssertEqual(reportAfterRelaunch.level, .limited)
        XCTAssertTrue(reportAfterRelaunch.missingCapabilities.contains(.sound))
        XCTAssertEqual(
            reportAfterRelaunch.diagnosticCode,
            "scene_authored_audio_unavailable"
        )
    }

    /// End-to-end coverage of the concurrent raw-pipe pipeline: a fake
    /// renderer script that (a) advertises `--record-raw` in its `--help`
    /// output, so `render()` selects the raw-pipe path over the PNG-sequence
    /// fallback, and (b) writes raw RGBA bytes into the FIFO it's given via
    /// `--record-raw`, standing in for the real background-engine-scene-renderer binary
    /// until that binary's `--record-raw` support lands.
    func testSceneVideoRendererUsesRawPipeWhenRendererAdvertisesRecordRaw() throws {
        guard let ffmpegPath = Self.ffmpegPathForIntegrationTests() else {
            throw XCTSkip("ffmpeg is required to encode the scene render fixture.")
        }

        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        let cacheDirectory = root.appending(path: "SceneVideoCache")
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer {
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }

        // 32x32 RGBA frames = 32*32*4 = 4096 bytes/frame; write exactly 2
        // (matching fps=2, seconds=1 below) as all-zero (transparent black)
        // pixels straight into the FIFO the renderer is told to use.
        let rendererURL = root.appending(path: "fake-raw-scene-renderer")
        let rendererScript = """
        #!/bin/sh
        if [ "$1" = "--help" ]; then
          echo "Usage: linux-wallpaperengine [--help] [--record-dir VAR] [--record-raw VAR] [--record-seconds VAR] background id"
          exit 0
        fi
        set -e
        fifo=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--record-raw" ]; then
            fifo="$2"
          fi
          shift
        done
        dd if=/dev/zero bs=4096 count=2 of="$fifo" >/dev/null 2>&1
        """
        try rendererScript.write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rendererURL.path)

        let configuration = SceneVideoRenderConfiguration(
            assetId: "MjQ2ODQ4OTIyMw",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 32, height: 32),
            fps: 2,
            seconds: 1
        )

        // When
        let reportedProgress = ProgressRecorder()
        let outputURL = try SceneVideoRenderer.render(
            configuration: configuration,
            ffmpegPath: ffmpegPath,
            progressHandler: { progress in
                reportedProgress.record(progress)
            }
        )

        // Then: the raw-pipe path was taken (the fake renderer never writes
        // PNG files, so a successful render here can only have gone through
        // `--record-raw`), producing a valid non-empty cached mp4.
        XCTAssertEqual(
            outputURL.deletingLastPathComponent().standardizedFileURL.path,
            SceneVideoCache.cacheDirectoryURL().standardizedFileURL.path
        )
        XCTAssertTrue(outputURL.lastPathComponent.hasPrefix("\(configuration.assetId)-g"))
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertGreaterThan((attributes[.size] as? Int) ?? 0, 0)
        let values = reportedProgress.values
        XCTAssertFalse(values.isEmpty, "Expected the progress handler to be invoked at least once.")
        XCTAssertEqual(values.last, 1.0, "Rendering should always finish by reporting full progress.")
    }

    /// Regression coverage for the FIFO handshake race: a renderer that
    /// advertises `--record-raw` but then hangs instead of writing anything
    /// into the FIFO (simulating a stalled/crashed render) must not hang
    /// `render()` forever. With the watchdog timeout overridden to a short
    /// interval, both the hung renderer and the ffmpeg process blocked
    /// reading the empty FIFO must be killed, and `render()` must fall back
    /// to the PNG-sequence pipeline (which also fails here, since the fake
    /// renderer doesn't handle `--record-dir` either) and return promptly
    /// rather than hanging the test suite.
    func testSceneVideoRendererDoesNotHangWhenRawPipeStalls() throws {
        guard let ffmpegPath = Self.ffmpegPathForIntegrationTests() else {
            throw XCTSkip("ffmpeg is required to encode the scene render fixture.")
        }

        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        let cacheDirectory = root.appending(path: "SceneVideoCache")
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer {
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }
        let previousWatchdogTimeout = SceneVideoRenderer.rawPipeWatchdogTimeout
        SceneVideoRenderer.rawPipeWatchdogTimeout = { _ in 0.3 }
        defer {
            SceneVideoRenderer.rawPipeWatchdogTimeout = previousWatchdogTimeout
        }

        // A renderer that advertises --record-raw support but, once invoked
        // with it, simply hangs (sleeps far longer than the watchdog) instead
        // of writing any frames - standing in for a crashed/stuck real
        // renderer. It does nothing useful for --record-dir either, so the
        // PNG-sequence fallback this triggers is expected to fail fast with
        // "no frames recorded" rather than itself hanging.
        let rendererURL = root.appending(path: "fake-hanging-scene-renderer")
        let rendererScript = """
        #!/bin/sh
        if [ "$1" = "--help" ]; then
          echo "Usage: linux-wallpaperengine [--help] [--record-dir VAR] [--record-raw VAR] [--record-seconds VAR] background id"
          exit 0
        fi
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--record-raw" ]; then
            sleep 30
            exit 0
          fi
          shift
        done
        exit 1
        """
        try rendererScript.write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rendererURL.path)

        let configuration = SceneVideoRenderConfiguration(
            assetId: "MjQ2ODQ4OTIyMw",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 32, height: 32),
            fps: 2,
            seconds: 1
        )

        // When
        let start = Date()
        XCTAssertThrowsError(
            try SceneVideoRenderer.render(configuration: configuration, ffmpegPath: ffmpegPath)
        ) { error in
            let failure = error as? SceneProcessFailure
            XCTAssertEqual(failure?.name, rendererURL.lastPathComponent)
            XCTAssertEqual(failure?.status, 1)
        }
        let elapsed = Date().timeIntervalSince(start)

        // Then: the render call returned in roughly one watchdog interval,
        // not after waiting out the renderer's 30s sleep (proving the stall
        // was detected and both processes were killed rather than leaving
        // `render()` blocked forever).
        XCTAssertLessThan(elapsed, 10, "render() should abort a stalled raw-pipe pipeline via the watchdog, not hang.")
    }

    func testRawPipeRendererLaunchFailureTerminatesFfmpegBeforeDrainingStderr() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rendererURL = root.appending(path: "advertises-raw-renderer")
        try "#!/bin/sh\necho '[--record-raw]'\n".write(
            to: rendererURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rendererURL.path)

        // A faithful stand-in for ffmpeg's FIFO lifecycle: open the input
        // named after `-i`, then remain alive while holding stderr open. This
        // lets the production handshake confirm a real reader before the
        // deliberately missing renderer launch fails. `exec` ensures the
        // process registered by SceneVideoRenderer is also the process that
        // owns the descriptors, so terminating it closes stderr immediately.
        let fakeFFmpegURL = root.appending(path: "fake-ffmpeg-reader")
        let fakeFFmpegScript = """
        #!/bin/sh
        fifo=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-i" ]; then
            fifo="$2"
            break
          fi
          shift
        done
        exec 3<"$fifo"
        exec /bin/sleep 30
        """
        try fakeFFmpegScript.write(to: fakeFFmpegURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFFmpegURL.path)

        let previousMakeProcess = SceneVideoRenderer.makeProcess
        SceneVideoRenderer.makeProcess = { executableURL, arguments, stderrPipe in
            let process = Process()
            if executableURL == rendererURL, arguments.contains("--record-raw") {
                process.executableURL = root.appending(path: "missing-renderer")
            } else {
                process.executableURL = fakeFFmpegURL
                process.arguments = arguments
                process.standardError = stderrPipe
            }
            return process
        }
        defer { SceneVideoRenderer.makeProcess = previousMakeProcess }

        let configuration = SceneVideoRenderConfiguration(
            assetId: "raw-launch-failure",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 32, height: 32),
            fps: 2,
            seconds: 1
        )

        let start = Date()
        XCTAssertThrowsError(
            try SceneVideoRenderer.render(configuration: configuration, ffmpegPath: "/bin/sleep")
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            5,
            "A renderer launch failure must terminate ffmpeg before synchronously draining stderr."
        )
    }

    func testRawPipeReaderHandshakeRespondsToTaskCancellation() async throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rendererURL = root.appending(path: "advertises-raw-renderer")
        try "#!/bin/sh\necho '[--record-raw]'\n".write(
            to: rendererURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rendererURL.path)

        // Stand in for an ffmpeg process that launched but never reached its
        // FIFO read-open. Cancellation must interrupt the handshake loop and
        // terminate this process rather than waiting for the ten-second
        // reader timeout.
        let previousMakeProcess = SceneVideoRenderer.makeProcess
        SceneVideoRenderer.makeProcess = { _, _, stderrPipe in
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sleep")
            process.arguments = ["30"]
            process.standardError = stderrPipe
            return process
        }
        defer { SceneVideoRenderer.makeProcess = previousMakeProcess }

        let configuration = SceneVideoRenderConfiguration(
            assetId: "raw-handshake-cancellation",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 32, height: 32),
            fps: 2,
            seconds: 1
        )
        let renderTask = Task.detached {
            try SceneVideoRenderer.render(configuration: configuration, ffmpegPath: "/bin/sleep")
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let cancellationStartedAt = Date()
        renderTask.cancel()
        do {
            _ = try await renderTask.value
            XCTFail("Expected the raw-pipe reader handshake to be cancelled.")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(cancellationStartedAt),
            2,
            "Cancellation must not wait for the FIFO reader timeout."
        )
    }

    @MainActor
    func testSceneEngineRendererFallsBackToBundledExecutablePath() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let rendererDirectory = root.appending(path: "Renderers")
        try FileManager.default.createDirectory(at: rendererDirectory, withIntermediateDirectories: true)
        let bundledRendererURL = rendererDirectory.appending(path: "background-engine-scene-renderer")
        try "#!/bin/sh\nexit 0\n".write(to: bundledRendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledRendererURL.path)
        let previousRendererPath = SceneEngineRendererConfiguration.overrideExecutablePath
        let previousResourceURL = SceneEngineRendererConfiguration.overrideResourceURL
        SceneEngineRendererConfiguration.overrideExecutablePath = nil
        SceneEngineRendererConfiguration.overrideResourceURL = root
        defer {
            SceneEngineRendererConfiguration.overrideExecutablePath = previousRendererPath
            SceneEngineRendererConfiguration.overrideResourceURL = previousResourceURL
        }

        // When
        let resolved = SceneEngineRendererConfiguration.executableURL(environment: [:])

        // Then
        XCTAssertEqual(resolved?.path, bundledRendererURL.path)
    }

    @MainActor
    func testSceneWallpaperInitializesTextOnlySceneWithoutPreviewOrTextures() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let packageURL = root.appending(path: "text-only.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )

        // When
        let view = try SceneWallpaperView(
            url: packageURL,
            previewURL: nil,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )
        view.prepareForClose()

        // Then
        XCTAssertEqual(view.frame.size, CGSize(width: 640, height: 360))
    }

    func testVideoWallpaperKeepsStillFallbackBehindPlayerLayer() throws {
        // Given
        let playerSource = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let videoSource = try String(repositoryFile: "Sources/BackgroundEngineApp/VideoWallpaperView.swift")

        // Then
        XCTAssertTrue(playerSource.contains("let fallbackImageURL = try? StillWallpaperImageProvider().stillImageURL(for: asset)"))
        XCTAssertTrue(playerSource.contains("fallbackImageURL: fallbackImageURL"))
        XCTAssertTrue(videoSource.contains("private let fallbackLayer = CAGradientLayer()"))
        XCTAssertTrue(videoSource.contains("layer?.addSublayer(fallbackLayer)"))
        XCTAssertTrue(videoSource.contains("layer?.addSublayer(playerLayer)"))
    }

    func testSceneWallpaperAppliesTransformAndOpacityAnimationChannels() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/SceneWallpaperView.swift")

        // Then
        XCTAssertTrue(source.contains(#"CAKeyframeAnimation(keyPath: "position")"#))
        XCTAssertTrue(source.contains(#"CAKeyframeAnimation(keyPath: "transform.scale.x")"#))
        XCTAssertTrue(source.contains(#"CAKeyframeAnimation(keyPath: "transform.scale.y")"#))
        XCTAssertTrue(source.contains(#"CAKeyframeAnimation(keyPath: "transform.rotation.z")"#))
        XCTAssertTrue(source.contains(#"CAKeyframeAnimation(keyPath: "opacity")"#))
    }

    func testSceneWallpaperUsesSharedDisplayLayoutAndLayerDepth() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/SceneWallpaperView.swift")

        // Then
        XCTAssertTrue(source.contains("WallpaperContentLayout.scaledContentFrame"))
        XCTAssertTrue(source.contains("layer.zPosition = plan.origin.z"))
    }

    func testSceneWallpaperRendersTextLayersAndKnownWaterEffects() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/SceneWallpaperView.swift")

        // Then
        XCTAssertTrue(source.contains("CATextLayer()"))
        XCTAssertTrue(source.contains("dynamicTextLayers.append"))
        XCTAssertTrue(source.contains("Timer.scheduledTimer"))
        XCTAssertTrue(source.contains("includeScripted: false"))
        XCTAssertTrue(source.contains("plan.effectSettings"))
        XCTAssertTrue(source.contains("opacityMultiplier(for: layerPlan)"))
        XCTAssertTrue(source.contains("opacityMultiplier(for: plan)"))
    }

    func testSceneWallpaperUsesShaderDerivedWaterWaveRenderingInsteadOfLayerDrift() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/SceneWallpaperView.swift")

        // Then
        XCTAssertTrue(source.contains("CIKernel"))
        XCTAssertTrue(source.contains("weWaterWaves"))
        XCTAssertTrue(source.contains("shaderEffectLayers.append"))
        XCTAssertTrue(source.contains("startSceneTickSourceIfNeeded"))
        XCTAssertFalse(source.contains(#"CAKeyframeAnimation(keyPath: "transform.translation.y")"#))
        XCTAssertFalse(source.contains(#"CAKeyframeAnimation(keyPath: "transform.translation.x")"#))
        XCTAssertFalse(source.contains(#"layer.add(animation, forKey: "\(keyPrefix)-effect-rotation")"#))
    }

    func testSceneWallpaperRendersParsedWaterShaderEffects() {
        // Given
        let effects = [
            SceneLayerEffectSetting(effect: .waterFlow),
            SceneLayerEffectSetting(effect: .waterWaves),
            SceneLayerEffectSetting(effect: .waterRipple),
            SceneLayerEffectSetting(effect: .scroll),
            SceneLayerEffectSetting(effect: .bloom),
            SceneLayerEffectSetting(effect: .blur),
            SceneLayerEffectSetting(effect: .chromaticAberration),
            SceneLayerEffectSetting(effect: .clouds),
            SceneLayerEffectSetting(effect: .godRays),
            SceneLayerEffectSetting(effect: .localContrast),
            SceneLayerEffectSetting(effect: .materialColor),
            SceneLayerEffectSetting(effect: .shake),
            SceneLayerEffectSetting(effect: .spin),
            SceneLayerEffectSetting(effect: .shine),
            SceneLayerEffectSetting(effect: .opacity),
            SceneLayerEffectSetting(effect: .pulse)
        ]

        // When
        let rendered = SceneWallpaperView.shaderRenderableEffects(from: effects).map(\.effect)

        // Then
        XCTAssertEqual(rendered, [
            .waterFlow,
            .waterWaves,
            .waterRipple,
            .scroll,
            .bloom,
            .blur,
            .chromaticAberration,
            .godRays,
            .localContrast,
            .materialColor,
            .spin
        ])
    }

    func testSceneWallpaperRefreshesSceneScriptTextLayers() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/SceneWallpaperView.swift")

        // Then
        XCTAssertTrue(source.contains("SceneScriptTextEvaluator(script:"))
        XCTAssertTrue(source.contains("text.script != nil"))
        XCTAssertTrue(source.contains("SceneScriptRuntime("))
        XCTAssertTrue(source.contains("refreshSceneTickDrivenLayers"))
        XCTAssertTrue(source.contains("tick.frameTime"))
        XCTAssertFalse(source.contains("1.0 / 24.0"))
    }

    func testSceneWallpaperSuspensionPausesAndResumesSceneTickSource() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/SceneWallpaperView.swift")
        let start = try XCTUnwrap(source.range(of: "func setPlaybackSuspended"))
        let end = try XCTUnwrap(source.range(of: "func setDisplayMode", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("sceneTickSource.suspend()"))
        XCTAssertTrue(body.contains("sceneTickSource.resume()"))
        XCTAssertTrue(body.contains("startSceneTickSourceIfNeeded()"))
    }

    func testSceneWallpaperCloseInvalidatesSceneTickSource() throws {
        // Given
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/SceneWallpaperView.swift")
        let start = try XCTUnwrap(source.range(of: "func prepareForClose()"))
        let end = try XCTUnwrap(source.range(of: "private func configureSceneLayer", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("sceneTickSource.invalidate()"))
        XCTAssertFalse(body.contains("shaderEffectTimer"))
    }

    func testSceneWallpaperAnimatesParsedLayerEffects() {
        // Given
        let effects = [
            SceneLayerEffectSetting(effect: .shake),
            SceneLayerEffectSetting(effect: .spin),
            SceneLayerEffectSetting(effect: .shine),
            SceneLayerEffectSetting(effect: .pulse),
            SceneLayerEffectSetting(effect: .waterFlow),
            SceneLayerEffectSetting(effect: .waterRipple),
            SceneLayerEffectSetting(effect: .bloom),
            SceneLayerEffectSetting(effect: .opacity)
        ]

        // When
        let animated = effects.map { SceneWallpaperView.isLayerAnimatedEffect($0.effect) }

        // Then
        XCTAssertEqual(animated, [true, true, true, true, false, false, false, false])
    }

    func testSceneWallpaperSkipsEffectAnimationsThatConflictWithSceneKeyframes() {
        // Then
        XCTAssertFalse(SceneWallpaperView.shouldAnimateLayerEffect(.spin, hasAngleAnimation: true, hasAlphaAnimation: false))
        XCTAssertFalse(SceneWallpaperView.shouldAnimateLayerEffect(.shine, hasAngleAnimation: false, hasAlphaAnimation: true))
        XCTAssertFalse(SceneWallpaperView.shouldAnimateLayerEffect(.pulse, hasAngleAnimation: false, hasAlphaAnimation: true))
        XCTAssertTrue(SceneWallpaperView.shouldAnimateLayerEffect(.shake, hasAngleAnimation: true, hasAlphaAnimation: true))
        XCTAssertTrue(SceneWallpaperView.shouldAnimateLayerEffect(.spin, hasAngleAnimation: false, hasAlphaAnimation: false))
        XCTAssertTrue(SceneWallpaperView.shouldAnimateLayerEffect(.shine, hasAngleAnimation: false, hasAlphaAnimation: false))
        XCTAssertTrue(SceneWallpaperView.shouldAnimateLayerEffect(.pulse, hasAngleAnimation: false, hasAlphaAnimation: false))
    }

    func testSceneWallpaperDerivesEffectAnimationTimingFromShaderSpeed() {
        // Given
        let fastSpin = SceneLayerEffectSetting(effect: .spin, speed: 2)
        let staticShake = SceneLayerEffectSetting(effect: .shake, speed: 0, strength: 0.2)
        let strongShake = SceneLayerEffectSetting(
            effect: .shake,
            speed: 1,
            strength: 0.4,
            direction: SceneVector3(x: 1, y: 0, z: 0)
        )

        // When
        let spinDuration = SceneWallpaperView.layerEffectDuration(for: fastSpin, defaultDuration: 8)
        let staticDuration = SceneWallpaperView.layerEffectDuration(for: staticShake, defaultDuration: 1)
        let shakeOffsets = SceneWallpaperView.shakeOffsets(for: strongShake, layerSize: CGSize(width: 200, height: 100))

        // Then
        XCTAssertEqual(spinDuration, 4, accuracy: 0.000_001)
        XCTAssertEqual(staticDuration, 1, accuracy: 0.000_001)
        XCTAssertEqual(shakeOffsets.count, 5)
        XCTAssertEqual(shakeOffsets[1].x, 0, accuracy: 0.000_001)
        XCTAssertEqual(shakeOffsets[1].y, -8, accuracy: 0.000_001)
    }

    func testSceneWallpaperScrollUsesSpeedDirectionWhenAxisSpeedsAreMissing() {
        // Given
        let directionalScroll = SceneLayerEffectSetting(
            effect: .scroll,
            speed: 0.4,
            direction: SceneVector3(x: 0, y: -2, z: 0)
        )
        let explicitAxisScroll = SceneLayerEffectSetting(
            effect: .scroll,
            speed: 0.4,
            speedX: 0,
            speedY: -0.35,
            direction: SceneVector3(x: 1, y: 0, z: 0)
        )

        // When
        let directional = SceneWallpaperView.scrollAxisSpeeds(for: directionalScroll)
        let explicit = SceneWallpaperView.scrollAxisSpeeds(for: explicitAxisScroll)

        // Then
        XCTAssertEqual(directional.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(directional.y, -0.4, accuracy: 0.000_001)
        XCTAssertEqual(explicit.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(explicit.y, -0.35, accuracy: 0.000_001)
    }

    func testSceneTickClockStopsWhileSuspended() throws {
        // Given
        var clock = SceneTickClock()

        // When
        let firstTick = clock.advance(by: 0.25)
        clock.suspend()
        let suspendedTick = clock.advance(by: 10)
        clock.resume()
        let resumedTick = clock.advance(by: 0.5)

        // Then
        XCTAssertEqual(try XCTUnwrap(firstTick).elapsedTime, 0.25, accuracy: 0.000_001)
        XCTAssertNil(suspendedTick)
        XCTAssertEqual(try XCTUnwrap(resumedTick).elapsedTime, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(clock.elapsedTime, 0.75, accuracy: 0.000_001)
    }

    @MainActor
    func testSceneTickClockInvalidatesOnClose() throws {
        // Given
        let root = try Self.makeTempDirectory()
        let packageURL = root.appending(path: "text-only.pkg")
        let tickSource = TestSceneTickSource()
        try Self.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let view = try SceneWallpaperView(
            url: packageURL,
            previewURL: nil,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit,
            sceneTickSource: tickSource
        )

        // When
        view.prepareForClose()

        // Then
        XCTAssertTrue(tickSource.didInvalidate)
        XCTAssertFalse(tickSource.isRunning)
    }

    func testSceneShaderEffectClockDoesNotAdvanceWhileSuspended() throws {
        // When
        var clock = SceneTickClock()
        _ = clock.advance(by: 4.5)
        clock.suspend()
        let suspendedTick = clock.advance(by: 60)
        let suspendedTime = clock.elapsedTime
        clock.resume()
        let runningTick = clock.advance(by: 3.25)

        // Then
        XCTAssertNil(suspendedTick)
        XCTAssertEqual(suspendedTime, 4.5, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(runningTick).elapsedTime, 7.75, accuracy: 0.000_001)
    }

    private static func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wwb-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func writeSolidColorPNG(size: CGSize) throws -> URL {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0,
              height > 0,
              let representation = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: width,
                  pixelsHigh: height,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: width * 4,
                  bitsPerPixel: 32
              ),
              let pixels = representation.bitmapData else {
            throw CocoaError(.fileWriteUnknown)
        }
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * representation.bytesPerRow + x * 4
                pixels[offset] = 20
                pixels[offset + 1] = 120
                pixels[offset + 2] = 220
                pixels[offset + 3] = 255
            }
        }
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "wwb-frame-\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }

    private static func writeScenePackage(to url: URL, sceneJSON: String) throws {
        try writeScenePackage(to: url, entries: [("scene.json", Data(sceneJSON.utf8))])
    }

    private static func writeScenePackage(to url: URL, entries: [(String, Data)]) throws {
        var data = Data()
        data.appendLengthPrefixedString("PKGV0007")
        data.appendInt32(entries.count)
        var offset = 0
        for (path, contents) in entries {
            data.appendLengthPrefixedString(path)
            data.appendInt32(offset)
            data.appendInt32(contents.count)
            offset += contents.count
        }
        for (_, contents) in entries { data.append(contents) }
        try data.write(to: url, options: [.atomic])
    }

    private static func silentPCM16WAV(sampleRate: UInt32 = 8_000, seconds: UInt32 = 1) -> Data {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let dataSize = sampleRate * seconds * UInt32(channelCount) * bytesPerSample
        let byteRate = sampleRate * UInt32(channelCount) * bytesPerSample
        let blockAlign = channelCount * (bitsPerSample / 8)
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendUInt32(36 + dataSize)
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendUInt32(16)
        data.appendUInt16(1)
        data.appendUInt16(channelCount)
        data.appendUInt32(sampleRate)
        data.appendUInt32(byteRate)
        data.appendUInt16(blockAlign)
        data.appendUInt16(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        data.appendUInt32(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }

    private static func writeSceneEngineAssetsFixture(in root: URL) throws -> URL {
        let assetsDirectory = root.appending(path: "wallpaper-engine-assets")
        for relativePath in SceneEngineRendererConfiguration.requiredAssetPaths {
            let fileURL = assetsDirectory.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "{}\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return assetsDirectory
    }

    /// CI supplies the self-contained FFmpeg artifact through this explicit
    /// environment path. Resolve it directly in integration tests so their
    /// execution does not depend on a package target defining `DEBUG`; the
    /// production resolver's release-time Homebrew rejection remains intact.
    private static func ffmpegPathForIntegrationTests() -> String? {
        if let configured = ProcessInfo.processInfo.environment["BACKGROUND_ENGINE_FFMPEG"],
           FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        return VideoConverter().ffmpegPath()
    }

    private func makePlaybackAsset(
        id: String,
        kind: WallpaperKind,
        entrypoint: String,
        contentHash: String,
        allowsNetworkAccess: Bool
    ) -> WallpaperAsset {
        WallpaperAsset(
            id: id,
            title: id,
            kind: kind,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: URL(filePath: entrypoint).deletingLastPathComponent().path,
            entrypoint: entrypoint,
            thumbnail: nil,
            workshopId: nil,
            contentHash: contentHash,
            compatibility: kind == .web ? .live() : nil,
            compatibilityReport: kind == .web
                ? CompatibilityReport(level: .full, playbackPath: .webLive)
                : nil,
            allowsNetworkAccess: allowsNetworkAccess,
            redistributionAllowed: false,
            issues: []
        )
    }

    private static func sceneAsset(root: URL, entrypoint: URL) -> WallpaperAsset {
        WallpaperAsset(
            id: root.lastPathComponent,
            title: "Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .localSteamWorkshop,
            projectDirectory: root.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
    }

}

/// Collects progress values reported from the background queue the scene
/// video render progress monitor runs on.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        storedValues.append(value)
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }
}

@MainActor
private final class TestSceneTickSource: SceneTickSource {
    private var clock = SceneTickClock()
    private(set) var isRunning = false
    private(set) var didInvalidate = false
    var onTick: ((SceneTick) -> Void)?

    var elapsedTime: TimeInterval {
        clock.elapsedTime
    }

    var frameTime: TimeInterval {
        clock.frameTime
    }

    func start() {
        guard !didInvalidate else {
            return
        }
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func suspend() {
        clock.suspend()
        isRunning = false
    }

    func resume() {
        clock.resume()
    }

    func reset() {
        clock.reset()
        isRunning = false
    }

    func invalidate() {
        clock.invalidate()
        isRunning = false
        didInvalidate = true
        onTick = nil
    }

    func advance(by delta: TimeInterval) {
        guard isRunning, let tick = clock.advance(by: delta) else {
            return
        }
        onTick?(tick)
    }
}

private extension Data {
    mutating func appendInt32(_ value: Int) {
        var raw = Int32(value).littleEndian
        Swift.withUnsafeBytes(of: &raw) { append(contentsOf: $0) }
    }

    mutating func appendLengthPrefixedString(_ string: String) {
        let bytes = Data(string.utf8)
        appendInt32(bytes.count)
        append(bytes)
    }

    mutating func appendUInt16(_ value: UInt16) {
        var raw = value.littleEndian
        Swift.withUnsafeBytes(of: &raw) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var raw = value.littleEndian
        Swift.withUnsafeBytes(of: &raw) { append(contentsOf: $0) }
    }
}
