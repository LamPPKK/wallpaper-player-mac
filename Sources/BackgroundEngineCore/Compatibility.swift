import Foundation

public enum CompatibilityLevel: String, Codable, CaseIterable, Sendable {
    case full
    case limited
    case unsupported
}

public enum PlaybackPath: String, Codable, CaseIterable, Sendable {
    case direct
    case convertedVideo
    case webLive
    case nativeScene
    case renderedSceneCache
}

public enum WallpaperCapability: String, Codable, CaseIterable, Comparable, Sendable {
    case engineLayer
    case shader
    case particle
    case puppet
    case sound
    case clock
    case sceneScript
    case interaction
    case audioReactive
    case videoTexture
    case maskedComposition

    public static func < (lhs: WallpaperCapability, rhs: WallpaperCapability) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct CompatibilityReport: Codable, Equatable, Sendable {
    public static let currentProbeVersion = 4

    public let level: CompatibilityLevel
    public let playbackPath: PlaybackPath?
    public let requiredCapabilities: [WallpaperCapability]
    public let missingCapabilities: [WallpaperCapability]
    public let warnings: [String]
    public let diagnosticCode: String?
    public let probeVersion: Int
    public let needsProbe: Bool

    public init(
        level: CompatibilityLevel,
        playbackPath: PlaybackPath?,
        requiredCapabilities: [WallpaperCapability] = [],
        missingCapabilities: [WallpaperCapability] = [],
        warnings: [String] = [],
        diagnosticCode: String? = nil,
        probeVersion: Int = CompatibilityReport.currentProbeVersion,
        needsProbe: Bool = false
    ) {
        self.level = level
        self.playbackPath = playbackPath
        self.requiredCapabilities = Array(Set(requiredCapabilities)).sorted()
        self.missingCapabilities = Array(Set(missingCapabilities)).sorted()
        self.warnings = warnings
        self.diagnosticCode = diagnosticCode
        self.probeVersion = probeVersion
        self.needsProbe = needsProbe
    }

    /// A conservative placeholder used while an imported Scene is waiting
    /// for its full texture/render-plan probe. Library loading must not decode
    /// every Scene synchronously, so stale reports are migrated to this
    /// state and resolved by the app's background probe queue.
    public static func pendingSceneProbe(
        preserving previous: CompatibilityReport? = nil
    ) -> CompatibilityReport {
        CompatibilityReport(
            level: .limited,
            playbackPath: previous?.playbackPath ?? .renderedSceneCache,
            requiredCapabilities: previous?.requiredCapabilities ?? [],
            missingCapabilities: previous?.missingCapabilities ?? [],
            warnings: ["Scene compatibility is being checked in the background."],
            diagnosticCode: "scene_probe_pending",
            needsProbe: true
        )
    }

    public var supportMode: SupportMode {
        let reason = warnings.first ?? Self.defaultReason(
            level: level,
            playbackPath: playbackPath,
            missingCapabilities: missingCapabilities,
            diagnosticCode: diagnosticCode
        )
        switch level {
        case .full:
            switch playbackPath {
            case .convertedVideo, .renderedSceneCache:
                return .cached(reason: reason)
            default:
                return .live(reason: warnings.first)
            }
        case .limited:
            return .limited(reason: reason)
        case .unsupported:
            return .unsupported(reason: reason)
        }
    }

    private static func defaultReason(
        level: CompatibilityLevel,
        playbackPath: PlaybackPath?,
        missingCapabilities: [WallpaperCapability],
        diagnosticCode: String?
    ) -> String {
        if !missingCapabilities.isEmpty {
            return "Limited because these live capabilities are unavailable: "
                + missingCapabilities.map(\.rawValue).joined(separator: ", ") + "."
        }
        if let diagnosticCode {
            return "Compatibility probe reported \(diagnosticCode)."
        }
        switch (level, playbackPath) {
        case (.full, .convertedVideo):
            return "A local compatible video cache is required."
        case (.full, .renderedSceneCache):
            return "The Scene is rendered to a local video cache."
        case (.limited, _):
            return "The main wallpaper content can play with limited live behavior."
        case (.unsupported, _):
            return "No compatible playback path is available."
        default:
            return "Compatible."
        }
    }
}

public enum RuntimeAvailability: String, Codable, CaseIterable, Sendable {
    case available
    case missing
    case invalid
}

public struct RuntimeComponentHealth: Codable, Equatable, Sendable {
    public let availability: RuntimeAvailability
    public let version: String?
    public let detail: String

    public init(availability: RuntimeAvailability, version: String? = nil, detail: String) {
        self.availability = availability
        self.version = version
        self.detail = detail
    }
}

public struct RuntimeHealth: Codable, Equatable, Sendable {
    public let sceneRenderer: RuntimeComponentHealth
    public let mediaTools: RuntimeComponentHealth
    public let engineAssets: RuntimeComponentHealth

    public init(
        sceneRenderer: RuntimeComponentHealth,
        mediaTools: RuntimeComponentHealth,
        engineAssets: RuntimeComponentHealth
    ) {
        self.sceneRenderer = sceneRenderer
        self.mediaTools = mediaTools
        self.engineAssets = engineAssets
    }

    public var canRenderSceneCache: Bool {
        sceneRenderer.availability == .available
            && mediaTools.availability == .available
            && engineAssets.availability == .available
    }
}

public struct WallpaperCompatibilityAnalyzer: Sendable {
    public init() {}

    public func analyze(
        kind: WallpaperKind,
        status: SupportStatus,
        entrypoint: URL?,
        projectRoot: URL? = nil
    ) -> CompatibilityReport {
        switch kind {
        case .video where status == .playable:
            return CompatibilityReport(level: .full, playbackPath: .direct)
        case .video where status == .needsConversion:
            return CompatibilityReport(
                level: .full,
                playbackPath: .convertedVideo,
                warnings: ["The video will be converted to a local AVFoundation-compatible cache."]
            )
        case .image where status == .playable:
            return CompatibilityReport(level: .full, playbackPath: .direct)
        case .web where status == .playable:
            return analyzeWeb(entrypoint: entrypoint, projectRoot: projectRoot)
        case .scene:
            return analyzeScene(entrypoint: entrypoint)
        case .application:
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                warnings: ["Windows Application wallpapers cannot run on macOS."],
                diagnosticCode: "windows_application_unsupported"
            )
        default:
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                diagnosticCode: "no_compatible_renderer"
            )
        }
    }

    private func analyzeWeb(entrypoint: URL?, projectRoot: URL?) -> CompatibilityReport {
        guard let entrypoint else {
            return CompatibilityReport(level: .full, playbackPath: .webLive)
        }
        let isAudioReactive = WebRuntimeFeatureAnalyzer().usesAudioListener(
            entrypoint: entrypoint,
            projectRoot: projectRoot ?? entrypoint.deletingLastPathComponent()
        )
        return CompatibilityReport(
            level: isAudioReactive ? .limited : .full,
            playbackPath: .webLive,
            requiredCapabilities: isAudioReactive ? [.audioReactive] : [],
            missingCapabilities: isAudioReactive ? [.audioReactive] : [],
            warnings: isAudioReactive
                ? ["System-audio visualization receives neutral data in v0.2."]
                : [],
            diagnosticCode: isAudioReactive ? "web_audio_reactive_limited" : nil
        )
    }

    private func analyzeScene(entrypoint: URL?) -> CompatibilityReport {
        guard let entrypoint else {
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                diagnosticCode: "scene_package_missing"
            )
        }
        let nativePlayable = SceneRenderPlanBuilder().canBuild(url: entrypoint)
        return analyzeScene(entrypoint: entrypoint, nativePlayable: nativePlayable)
    }

    /// Classifies Scene capabilities using a native-readiness result supplied
    /// by a shared asynchronous coordinator. This avoids decoding the same
    /// package again during library reprobes and desktop playback.
    public func analyzeScene(
        entrypoint: URL?,
        nativePlayable: Bool
    ) -> CompatibilityReport {
        guard let entrypoint else {
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                diagnosticCode: "scene_package_missing"
            )
        }
        guard let features = try? SceneRuntimeFeatureAnalyzer().analyze(url: entrypoint) else {
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                diagnosticCode: "scene_package_unreadable"
            )
        }
        let required = capabilities(for: features)
        let liveOnly = Set(required).intersection([.sceneScript, .interaction, .audioReactive])
        if nativePlayable && !features.requiresEngineRenderer {
            return CompatibilityReport(
                level: .full,
                playbackPath: .nativeScene,
                requiredCapabilities: required
            )
        }
        if nativePlayable,
           !features.requiresUnrecognizedLayerRuntime,
           liveOnly.isEmpty,
           required.allSatisfy({ nativeCapabilities.contains($0) }) {
            return CompatibilityReport(
                level: .full,
                playbackPath: .nativeScene,
                requiredCapabilities: required
            )
        }
        var missing = liveOnly
        if features.requiresUnrecognizedLayerRuntime {
            missing.insert(.engineLayer)
        }
        return CompatibilityReport(
            level: missing.isEmpty ? .full : .limited,
            playbackPath: .renderedSceneCache,
            requiredCapabilities: required,
            missingCapabilities: missing.sorted(),
            warnings: features.requiresUnrecognizedLayerRuntime
                ? ["The Scene contains an engine layer this build cannot reproduce exactly."]
                : missing.isEmpty
                    ? ["The Scene requires the bundled renderer and user-provided engine assets."]
                    : ["The Scene will play from cache, but some live behavior is unavailable."],
            diagnosticCode: features.requiresUnrecognizedLayerRuntime
                ? "scene_engine_layer_limited"
                : missing.isEmpty ? nil : "scene_live_capabilities_limited"
        )
    }

    // Only capabilities reproduced exactly by the native layer renderer may
    // receive Full Live. Shader, particle, and puppet support is deliberately
    // treated as approximation unless the external renderer creates a cache.
    private let nativeCapabilities: Set<WallpaperCapability> = [.clock]

    private func capabilities(for features: SceneRuntimeFeatures) -> [WallpaperCapability] {
        var result = Set<WallpaperCapability>()
        if features.requiresShaderPipeline { result.insert(.shader) }
        if features.requiresParticleRuntime { result.insert(.particle) }
        if features.requiresModelRuntime { result.insert(.puppet) }
        if features.requiresSoundRuntime { result.insert(.sound) }
        if features.requiresClockRuntime { result.insert(.clock) }
        if features.requiresSceneScriptRuntime { result.insert(.sceneScript) }
        if features.requiresInteractionRuntime { result.insert(.interaction) }
        if features.requiresAudioAnalysis { result.insert(.audioReactive) }
        if features.requiresVideoTextureRuntime { result.insert(.videoTexture) }
        if features.requiresMaskedEffectComposition { result.insert(.maskedComposition) }
        if features.requiresUnrecognizedLayerRuntime { result.insert(.engineLayer) }
        return result.sorted()
    }
}

public struct WebRuntimeFeatureAnalyzer: Sendable {
    public init() {}

    /// Searches only bounded text files inside the project. This finds the
    /// common case where index.html imports the Wallpaper Engine callbacks
    /// from a separate script without following arbitrary URL references.
    public func usesAudioListener(entrypoint: URL, projectRoot: URL) -> Bool {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let allowedExtensions = Set(["html", "htm", "js", "mjs", "css", "json"])
        var candidates = [entrypoint]
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                guard candidates.count < 2_000,
                      allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                candidates.append(url)
            }
        }
        var remainingBytes = 8 * 1_024 * 1_024
        for candidate in candidates {
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard isInside(resolved, root: root),
                  let values = try? candidate.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            let fileSize = values.fileSize ?? 0
            guard fileSize >= 0, fileSize <= remainingBytes else { continue }
            remainingBytes -= fileSize
            guard let data = try? Data(contentsOf: candidate, options: [.mappedIfSafe]),
                  let source = WebWallpaperValidation.decodeTextPrefix(data) else { continue }
            if source.contains("wallpaperRegisterAudioListener") { return true }
        }
        return false
    }

    private func isInside(_ candidate: URL, root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
