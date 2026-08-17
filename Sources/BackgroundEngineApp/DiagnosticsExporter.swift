import BackgroundEngineCore
import Foundation

struct BackgroundEngineDiagnostics: Codable, Equatable, Sendable {
    struct AssetFeatureFingerprint: Codable, Equatable, Sendable {
        let kind: WallpaperKind
        let level: CompatibilityLevel
        let playbackPath: PlaybackPath?
        let requiredCapabilities: [WallpaperCapability]
        let missingCapabilities: [WallpaperCapability]
        let diagnosticCode: String?
    }

    let generatedAt: Date
    let appVersion: String
    let manifestSchemaVersion: Int
    let compatibilityProbeVersion: Int
    let runtime: RuntimeHealth
    let assets: [AssetFeatureFingerprint]
    let filteredLog: [String]
}

enum DiagnosticsExporter {
    static func data(
        appVersion: String,
        runtime: RuntimeHealth,
        assets: [WallpaperAsset],
        log: [String],
        generatedAt: Date = Date()
    ) throws -> Data {
        let fingerprints = assets.compactMap { asset -> BackgroundEngineDiagnostics.AssetFeatureFingerprint? in
            guard let report = asset.compatibilityReport else { return nil }
            return .init(
                kind: asset.kind,
                level: report.level,
                playbackPath: report.playbackPath,
                requiredCapabilities: report.requiredCapabilities,
                missingCapabilities: report.missingCapabilities,
                diagnosticCode: report.diagnosticCode
            )
        }
        let report = BackgroundEngineDiagnostics(
            generatedAt: generatedAt,
            appVersion: appVersion,
            manifestSchemaVersion: LibraryManifest.currentSchemaVersion,
            compatibilityProbeVersion: CompatibilityReport.currentProbeVersion,
            runtime: runtime,
            assets: fingerprints,
            filteredLog: log.map(sanitize)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    static func sanitize(_ line: String) -> String {
        let patterns = [
            #"/(?:Users|Volumes|private|tmp)/[^\"'\n\r,;)]*"#,
            #"(?:steamapps/workshop/content/431960/)?\b\d{6,}\b"#
        ]
        return patterns.reduce(line) { result, pattern in
            result.replacingOccurrences(
                of: pattern,
                with: "<redacted>",
                options: .regularExpression
            )
        }
    }
}
