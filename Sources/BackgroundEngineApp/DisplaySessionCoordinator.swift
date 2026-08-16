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
        player.play(
            assignments: assignments,
            assetsByID: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }),
            autoPauseWhenCovered: autoPauseWhenCovered,
            globalAudioEnabled: globalAudioEnabled,
            globalAudioVolume: globalAudioVolume
        )
    }

    func stopAll() { player.stop() }
}
