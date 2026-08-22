import AppKit
import BackgroundEngineCore
import CoreGraphics

struct ConnectedDisplay: Identifiable, Equatable {
    let id: String
    let name: String
    let resolution: CGSize
    let isPrimary: Bool

    @MainActor
    static func current() -> [ConnectedDisplay] {
        NSScreen.screens.enumerated().map { index, screen in
            ConnectedDisplay(
                id: DisplayIdentity.uuid(for: screen),
                name: screen.localizedName,
                resolution: screen.frame.size,
                isPrimary: index == 0
            )
        }
    }
}

struct WallpaperDisplaySnapshot: Equatable {
    let id: String
    let frame: CGRect
    let backingScaleFactor: CGFloat
    let isPrimary: Bool
}

struct WallpaperDisplayReconciliation: Equatable {
    let removedDisplayUUIDs: Set<String>
    let addedOrChangedDisplayUUIDs: Set<String>

    var requiresChanges: Bool {
        !removedDisplayUUIDs.isEmpty || !addedOrChangedDisplayUUIDs.isEmpty
    }
}

enum WallpaperDisplayTopology {
    @MainActor
    static func current(screens: [NSScreen] = NSScreen.screens) -> [WallpaperDisplaySnapshot] {
        screens.enumerated().map { index, screen in
            WallpaperDisplaySnapshot(
                id: DisplayIdentity.uuid(for: screen),
                frame: screen.frame,
                backingScaleFactor: screen.backingScaleFactor,
                isPrimary: index == 0
            )
        }
    }

    static func shouldReopenWindows(
        previous: [WallpaperDisplaySnapshot],
        current: [WallpaperDisplaySnapshot]
    ) -> Bool {
        reconciliation(previous: previous, current: current).requiresChanges
    }

    static func reconciliation(
        previous: [WallpaperDisplaySnapshot],
        current: [WallpaperDisplaySnapshot]
    ) -> WallpaperDisplayReconciliation {
        let previousByID = previous.reduce(into: [String: WallpaperDisplaySnapshot]()) {
            $0[$1.id] = $1
        }
        let currentByID = current.reduce(into: [String: WallpaperDisplaySnapshot]()) {
            $0[$1.id] = $1
        }
        return WallpaperDisplayReconciliation(
            removedDisplayUUIDs: Set(previousByID.keys).subtracting(currentByID.keys),
            addedOrChangedDisplayUUIDs: Set(currentByID.compactMap { id, snapshot in
                previousByID[id] == snapshot ? nil : id
            })
        )
    }

    /// Records successful topology changes while retaining the old snapshot
    /// for displays whose replacement failed. The next screen notification
    /// will therefore retry only those failed displays.
    static func snapshotAfterReconciliation(
        previous: [WallpaperDisplaySnapshot],
        current: [WallpaperDisplaySnapshot],
        failedDisplayUUIDs: Set<String>
    ) -> [WallpaperDisplaySnapshot] {
        let previousByID = previous.reduce(into: [String: WallpaperDisplaySnapshot]()) {
            $0[$1.id] = $1
        }
        var captured = current.filter { !failedDisplayUUIDs.contains($0.id) }
        captured.append(contentsOf: failedDisplayUUIDs.compactMap { previousByID[$0] })
        return normalized(captured)
    }

    private static func normalized(_ snapshots: [WallpaperDisplaySnapshot]) -> [WallpaperDisplaySnapshot] {
        snapshots.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
            if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
            if lhs.frame.width != rhs.frame.width { return lhs.frame.width < rhs.frame.width }
            return lhs.frame.height < rhs.frame.height
        }
    }
}

@MainActor
enum DisplayIdentity {
    static func uuid(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let displayID = CGDirectDisplayID(number.uint32Value)
            if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) {
                return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
            }
            return "display-\(displayID)"
        }
        let frame = screen.frame
        return "display-\(Int(frame.origin.x))-\(Int(frame.origin.y))-\(Int(frame.width))x\(Int(frame.height))"
    }
}

struct DisplayPlaybackFailure: Equatable, Identifiable {
    let displayUUID: String
    let message: String
    var id: String { displayUUID }
}

/// Resolves persistent display UUID assignments into independent wallpaper
/// sessions. A broken wallpaper on one display is reported without tearing
/// down sessions that were created successfully for other displays.
@MainActor
final class DisplaySessionCoordinator {
    static let shared = DisplaySessionCoordinator(player: .shared)

    private let player: WallpaperPlayer

    init(player: WallpaperPlayer) {
        self.player = player
    }

    func apply(
        assignments: [DisplayAssignment],
        assets: [WallpaperAsset],
        autoPauseWhenCovered: Bool,
        globalAudioEnabled: Bool,
        globalAudioVolume: Double
    ) -> [DisplayPlaybackFailure] {
        let assetsByID = assets.reduce(into: [WallpaperAsset.ID: WallpaperAsset]()) {
            $0[$1.id] = $1
        }
        return player.play(
            assignments: assignments,
            assetsByID: assetsByID,
            autoPauseWhenCovered: autoPauseWhenCovered,
            globalAudioEnabled: globalAudioEnabled,
            globalAudioVolume: globalAudioVolume
        )
    }

    func stopAll() { player.stop() }
}
