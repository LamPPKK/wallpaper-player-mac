import Foundation

public enum WallpaperKind: String, Codable, CaseIterable, Sendable {
    case video
    case web
    case image
    case scene
    case application
    case unknown
}

/// The user-facing compatibility decision for a wallpaper.
///
/// Scene projects can start in ``live`` mode and later move to ``cached``
/// when a renderer compatibility probe or runtime health check decides that
/// native playback is not reliable enough.
public enum SupportMode: Codable, Equatable, Sendable {
    case live(reason: String? = nil)
    case cached(reason: String)
    case unsupported(reason: String)

    public var label: String {
        switch self {
        case .live: "Live"
        case .cached: "Cached"
        case .unsupported: "Unsupported"
        }
    }

    public var reason: String? {
        switch self {
        case .live(let reason): reason
        case .cached(let reason), .unsupported(let reason): reason
        }
    }

    private enum CodingKeys: String, CodingKey { case mode, reason }
    private enum Mode: String, Codable { case live, cached, unsupported }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let reason = try container.decodeIfPresent(String.self, forKey: .reason)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .live: self = .live(reason: reason)
        case .cached: self = .cached(reason: reason ?? "Rendered fallback is available.")
        case .unsupported: self = .unsupported(reason: reason ?? "This wallpaper is not supported.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let mode: Mode
        switch self {
        case .live: mode = .live
        case .cached: mode = .cached
        case .unsupported: mode = .unsupported
        }
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}

public enum SupportStatus: String, Codable, CaseIterable, Sendable {
    case playable
    case needsConversion
    case previewOnly
    case unsupported
}

public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case localSteamWorkshop
    case steamCMD
    case wallpaperEngineBackup
    case manualFolder
    case legacyMigration
}

public enum WallpaperDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fit
    case fill
    case stretch

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        case .stretch: "Stretch"
        }
    }
}

public enum RenderQuality: String, Codable, CaseIterable, Sendable {
    case low
    case balanced
    case high
}

public enum AudioSource: String, Codable, CaseIterable, Sendable {
    case muted
    case primaryDisplay
}

public struct DisplayAssignment: Codable, Equatable, Identifiable, Sendable {
    public var id: String { displayUUID }
    public let displayUUID: String
    public var assetID: WallpaperAsset.ID?
    public var displayMode: WallpaperDisplayMode
    public var quality: RenderQuality
    public var audioSource: AudioSource

    public init(
        displayUUID: String,
        assetID: WallpaperAsset.ID?,
        displayMode: WallpaperDisplayMode = .fill,
        quality: RenderQuality = .balanced,
        audioSource: AudioSource = .muted
    ) {
        self.displayUUID = displayUUID
        self.assetID = assetID
        self.displayMode = displayMode
        self.quality = quality
        self.audioSource = audioSource
    }
}

public struct WallpaperProject: Codable, Equatable, Sendable {
    public let title: String
    public let kind: WallpaperKind
    public let entrypoint: String?
    public let preview: String?

    public init(title: String, kind: WallpaperKind, entrypoint: String?, preview: String?) {
        self.title = title
        self.kind = kind
        self.entrypoint = entrypoint
        self.preview = preview
    }
}

public struct ScanIssue: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct WallpaperAsset: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let kind: WallpaperKind
    public let supportStatus: SupportStatus
    public let source: SourceKind
    public let projectDirectory: String
    public let entrypoint: String?
    public let thumbnail: String?
    public let workshopId: String?
    public let dateAdded: Date?
    public let contentHash: String?
    public let compatibility: SupportMode?
    public let allowsNetworkAccess: Bool?
    public let redistributionAllowed: Bool
    public let issues: [ScanIssue]

    public init(
        id: String,
        title: String,
        kind: WallpaperKind,
        supportStatus: SupportStatus,
        source: SourceKind,
        projectDirectory: String,
        entrypoint: String?,
        thumbnail: String?,
        workshopId: String?,
        dateAdded: Date? = nil,
        contentHash: String? = nil,
        compatibility: SupportMode? = nil,
        allowsNetworkAccess: Bool? = nil,
        redistributionAllowed: Bool,
        issues: [ScanIssue]
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.supportStatus = supportStatus
        self.source = source
        self.projectDirectory = projectDirectory
        self.entrypoint = entrypoint
        self.thumbnail = thumbnail
        self.workshopId = workshopId
        self.dateAdded = dateAdded
        self.contentHash = contentHash
        self.compatibility = compatibility
        self.allowsNetworkAccess = allowsNetworkAccess
        self.redistributionAllowed = redistributionAllowed
        self.issues = issues
    }
}

public struct LibraryManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let generatedAt: Date
    public let assets: [WallpaperAsset]
    public let displayAssignments: [DisplayAssignment]

    public init(
        schemaVersion: Int = LibraryManifest.currentSchemaVersion,
        generatedAt: Date,
        assets: [WallpaperAsset],
        displayAssignments: [DisplayAssignment] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.assets = assets
        self.displayAssignments = displayAssignments
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, assets, displayAssignments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        assets = try container.decode([WallpaperAsset].self, forKey: .assets)
        displayAssignments = try container.decodeIfPresent(
            [DisplayAssignment].self,
            forKey: .displayAssignments
        ) ?? []
    }
}

public struct ScanResult: Codable, Equatable, Sendable {
    public let root: String
    public let generatedAt: Date
    public let assets: [WallpaperAsset]

    public init(root: String, generatedAt: Date, assets: [WallpaperAsset]) {
        self.root = root
        self.generatedAt = generatedAt
        self.assets = assets
    }
}
