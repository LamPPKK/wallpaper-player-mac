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
    case mediaIntegration
    case externalNetwork
    case videoTexture
    case maskedComposition

    public static func < (lhs: WallpaperCapability, rhs: WallpaperCapability) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct CompatibilityReport: Codable, Equatable, Sendable {
    public static let currentProbeVersion = 12

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
    private let webMediaPlaybackProbe: WebMediaPlaybackProbe

    public init(webMediaPlaybackProbe: WebMediaPlaybackProbe = WebMediaPlaybackProbe()) {
        self.webMediaPlaybackProbe = webMediaPlaybackProbe
    }

    public func analyze(
        kind: WallpaperKind,
        status: SupportStatus,
        entrypoint: URL?,
        projectRoot: URL? = nil,
        networkAccessAllowed: Bool = false
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
            return analyzeWeb(
                entrypoint: entrypoint,
                projectRoot: projectRoot,
                networkAccessAllowed: networkAccessAllowed
            )
        case .scene where status == .playable:
            return analyzeScene(entrypoint: entrypoint)
        case .scene:
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                warnings: ["The Scene package could not be read."],
                diagnosticCode: entrypoint == nil
                    ? "scene_package_missing"
                    : "scene_package_unreadable"
            )
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

    private func analyzeWeb(
        entrypoint: URL?,
        projectRoot: URL?,
        networkAccessAllowed: Bool
    ) -> CompatibilityReport {
        let effectiveProjectRoot = projectRoot ?? entrypoint?.deletingLastPathComponent()
        guard let entrypoint,
              let effectiveProjectRoot,
              isReadableWebEntrypoint(
                  entrypoint,
                  projectRoot: effectiveProjectRoot
              ) else {
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                warnings: ["The Web wallpaper entrypoint is missing, unreadable, or outside its project."],
                diagnosticCode: "web_entrypoint_unavailable"
            )
        }
        switch RemoteWebWallpaperConfiguration.state(projectRoot: effectiveProjectRoot) {
        case .valid:
            return CompatibilityReport(
                level: networkAccessAllowed ? .full : .unsupported,
                playbackPath: networkAccessAllowed ? .webLive : nil,
                requiredCapabilities: [.externalNetwork],
                missingCapabilities: networkAccessAllowed ? [] : [.externalNetwork],
                warnings: networkAccessAllowed
                    ? []
                    : ["This website wallpaper requires external network access."],
                diagnosticCode: networkAccessAllowed ? nil : "web_network_access_required"
            )
        case .invalid:
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                warnings: [
                    "This website wallpaper has invalid or legacy remote metadata. "
                        + "Re-import it using an HTTPS URL."
                ],
                diagnosticCode: "web_remote_configuration_invalid"
            )
        case .absent:
            break
        }
        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: effectiveProjectRoot
        )
        if features.dependencyAnalysisLimitExceeded {
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                warnings: [
                    "Required Web dependency analysis exceeded its safe file, text, or reference limit."
                ],
                diagnosticCode: "web_dependency_probe_limit_exceeded"
            )
        }
        if !features.missingLocalDependencies.isEmpty {
            let visible = features.missingLocalDependencies.prefix(5).joined(separator: ", ")
            let remaining = features.missingLocalDependencies.count - min(
                features.missingLocalDependencies.count,
                5
            )
            let suffix = remaining > 0 ? " and \(remaining) more" : ""
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                warnings: ["Required local Web resources are missing: \(visible)\(suffix)."],
                diagnosticCode: "web_local_dependency_missing"
            )
        }
        if !features.remoteDependencies.isEmpty, !networkAccessAllowed {
            let visible = features.remoteDependencies.prefix(5).joined(separator: ", ")
            let remaining = features.remoteDependencies.count - min(
                features.remoteDependencies.count,
                5
            )
            let suffix = remaining > 0 ? " and \(remaining) more" : ""
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                requiredCapabilities: [.externalNetwork],
                missingCapabilities: [.externalNetwork],
                warnings: [
                    "Enable external network access for required Web resources: \(visible)\(suffix)."
                ],
                diagnosticCode: "web_network_access_required"
            )
        }
        if features.mediaAnalysisLimitExceeded {
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                warnings: [
                    "Static Web media analysis exceeded its safe unique-reference limit."
                ],
                diagnosticCode: "web_static_media_probe_limit_exceeded"
            )
        }
        if !features.missingLocalMediaReferences.isEmpty,
           !features.missingLocalMediaHasProvenFallback {
            let visible = features.missingLocalMediaReferences.prefix(5).joined(separator: ", ")
            let remaining = features.missingLocalMediaReferences.count - min(
                features.missingLocalMediaReferences.count,
                5
            )
            let suffix = remaining > 0 ? " and \(remaining) more" : ""
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                warnings: ["Required local Web media is unavailable: \(visible)\(suffix)."],
                diagnosticCode: "web_static_media_missing"
            )
        }
        if !features.remoteMediaReferences.isEmpty,
           !networkAccessAllowed,
           !features.remoteMediaHasProvenFallback {
            let visible = features.remoteMediaReferences.prefix(5).joined(separator: ", ")
            let remaining = features.remoteMediaReferences.count - min(
                features.remoteMediaReferences.count,
                5
            )
            let suffix = remaining > 0 ? " and \(remaining) more" : ""
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                requiredCapabilities: [.externalNetwork],
                missingCapabilities: [.externalNetwork],
                warnings: [
                    "Enable external network access for required Web media: \(visible)\(suffix)."
                ],
                diagnosticCode: "web_network_access_required"
            )
        }
        var requiredCapabilities = features.remoteDependencies.isEmpty
            ? [WallpaperCapability]()
            : [.externalNetwork]
        var missingCapabilities = [WallpaperCapability]()
        var warnings = [String]()
        if features.usesAudioListener {
            requiredCapabilities.append(.audioReactive)
            missingCapabilities.append(.audioReactive)
            warnings.append("System-audio visualization receives neutral data in v0.2.")
        }
        if features.usesMediaIntegration {
            requiredCapabilities.append(.mediaIntegration)
            missingCapabilities.append(.mediaIntegration)
            warnings.append("System media metadata and playback state receive neutral unavailable data in v0.2.")
        }
        var webMediaDiagnostics = [String]()
        var runtimePendingDiagnosticCode: String?
        if features.hasOpaqueOrDynamicMediaReferences {
            warnings.append(
                "Dynamic Web media candidates will be discovered and prepared within runtime "
                    + "safety limits before playback."
            )
            runtimePendingDiagnosticCode = "web_dynamic_media_runtime_pending"
        }
        if !features.missingLocalMediaReferences.isEmpty {
            let visible = features.missingLocalMediaReferences.prefix(5).joined(separator: ", ")
            let remaining = features.missingLocalMediaReferences.count - min(
                features.missingLocalMediaReferences.count,
                5
            )
            let suffix = remaining > 0 ? " and \(remaining) more" : ""
            warnings.append(
                "Some local Web media sources are unavailable; an authored local source "
                    + "remains available: \(visible)\(suffix)."
            )
            webMediaDiagnostics.append("web_static_media_missing")
        }
        let mediaNeedingPreparation = features.localMediaReferences.filter {
            !webMediaPlaybackProbe.isDirectlyPlayable($0)
        }
        let preparationDiagnosticCode: String?
        if !mediaNeedingPreparation.isEmpty {
            warnings.append(
                "Some local Web media will be converted to a WebKit-compatible cache before playback."
            )
            preparationDiagnosticCode = "web_static_media_needs_preparation"
        } else {
            preparationDiagnosticCode = nil
        }
        if !features.remoteMediaReferences.isEmpty {
            requiredCapabilities.append(.externalNetwork)
            if !networkAccessAllowed {
                missingCapabilities.append(.externalNetwork)
                warnings.append(
                    "Some Web media requires external network access; an authored local "
                        + "source remains available."
                )
                webMediaDiagnostics.append("web_static_media_network_limited")
            }
        }
        let integrationDiagnosticCode: String?
        switch (features.usesAudioListener, features.usesMediaIntegration) {
        case (true, true): integrationDiagnosticCode = "web_realtime_integration_limited"
        case (true, false): integrationDiagnosticCode = "web_audio_reactive_limited"
        case (false, true): integrationDiagnosticCode = "web_media_integration_limited"
        case (false, false): integrationDiagnosticCode = nil
        }
        let diagnosticCode: String?
        if let integrationDiagnosticCode, webMediaDiagnostics.isEmpty {
            diagnosticCode = integrationDiagnosticCode
        } else if integrationDiagnosticCode == nil, webMediaDiagnostics.count == 1 {
            diagnosticCode = webMediaDiagnostics[0]
        } else if integrationDiagnosticCode != nil || !webMediaDiagnostics.isEmpty {
            diagnosticCode = "web_runtime_limited"
        } else if let runtimePendingDiagnosticCode {
            diagnosticCode = runtimePendingDiagnosticCode
        } else {
            diagnosticCode = preparationDiagnosticCode
        }
        return CompatibilityReport(
            level: missingCapabilities.isEmpty && webMediaDiagnostics.isEmpty ? .full : .limited,
            playbackPath: .webLive,
            requiredCapabilities: requiredCapabilities,
            missingCapabilities: missingCapabilities,
            warnings: warnings,
            diagnosticCode: diagnosticCode
        )
    }

    private func isReadableWebEntrypoint(_ entrypoint: URL, projectRoot: URL) -> Bool {
        guard entrypoint.isFileURL else { return false }
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let lexical = entrypoint.standardizedFileURL
        let resolved = lexical.resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        let entrypointComponents = resolved.pathComponents
        guard entrypointComponents.count > rootComponents.count,
              Array(entrypointComponents.prefix(rootComponents.count)) == rootComponents,
              let values = try? lexical.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: lexical) else {
            return false
        }
        try? handle.close()
        return true
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
        if !nativePlayable, !features.unreadableRequiredAssetFiles.isEmpty {
            let visible = features.unreadableRequiredAssetFiles.prefix(5).joined(separator: ", ")
            let remaining = features.unreadableRequiredAssetFiles.count - min(
                features.unreadableRequiredAssetFiles.count,
                5
            )
            let suffix = remaining > 0 ? " and \(remaining) more" : ""
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                requiredCapabilities: required,
                warnings: ["Required Scene asset data is unreadable: \(visible)\(suffix)."],
                diagnosticCode: "scene_required_asset_unreadable"
            )
        }
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

public enum WebMediaElementKind: String, Equatable, Hashable, Sendable {
    case video
    case audio
    case source
}

public struct WebLocalMediaReference: Equatable, Hashable, Sendable {
    public let elementKind: WebMediaElementKind
    public let rawReference: String
    public let sourceURL: URL

    public init(elementKind: WebMediaElementKind, rawReference: String, sourceURL: URL) {
        self.elementKind = elementKind
        self.rawReference = rawReference
        self.sourceURL = sourceURL
    }
}

/// An exact local dependency whose HTTP response needs a semantic MIME type
/// that cannot be inferred safely from its authored filename. Wallpaper
/// Engine projects commonly use extensionless entrypoints, scripts, styles,
/// and iframe documents; the loopback runtime applies these overrides only to
/// canonical files reached by the analyzer's bounded dependency graph.
public struct WebLocalResourceMIMEOverride: Equatable, Hashable, Sendable {
    public let sourceURL: URL
    public let mimeType: String

    public init(sourceURL: URL, mimeType: String) {
        self.sourceURL = sourceURL
        self.mimeType = mimeType
    }
}

public struct WebRuntimeFeatures: Equatable, Sendable {
    public let usesAudioListener: Bool
    public let usesMediaIntegration: Bool
    public let missingLocalDependencies: [String]
    public let remoteDependencies: [String]
    public let localMediaReferences: [WebLocalMediaReference]
    public let missingLocalMediaReferences: [String]
    public let remoteMediaReferences: [String]
    public let hasOpaqueOrDynamicMediaReferences: Bool
    public let localResourceMIMEOverrides: [WebLocalResourceMIMEOverride]
    let missingLocalMediaHasProvenFallback: Bool
    let remoteMediaHasProvenFallback: Bool
    let dependencyAnalysisLimitExceeded: Bool
    let mediaAnalysisLimitExceeded: Bool

    public init(
        usesAudioListener: Bool = false,
        usesMediaIntegration: Bool = false,
        missingLocalDependencies: [String] = [],
        remoteDependencies: [String] = [],
        localMediaReferences: [WebLocalMediaReference] = [],
        missingLocalMediaReferences: [String] = [],
        remoteMediaReferences: [String] = [],
        hasOpaqueOrDynamicMediaReferences: Bool = false,
        localResourceMIMEOverrides: [WebLocalResourceMIMEOverride] = []
    ) {
        self.usesAudioListener = usesAudioListener
        self.usesMediaIntegration = usesMediaIntegration
        self.missingLocalDependencies = Array(Set(missingLocalDependencies)).sorted()
        self.remoteDependencies = Array(Set(remoteDependencies)).sorted()
        self.localMediaReferences = Self.sortedLocalMediaReferences(localMediaReferences)
        self.missingLocalMediaReferences = Array(Set(missingLocalMediaReferences)).sorted()
        self.remoteMediaReferences = Array(Set(remoteMediaReferences)).sorted()
        self.hasOpaqueOrDynamicMediaReferences = hasOpaqueOrDynamicMediaReferences
        self.localResourceMIMEOverrides = Self.sortedMIMEOverrides(
            localResourceMIMEOverrides
        )
        self.missingLocalMediaHasProvenFallback = false
        self.remoteMediaHasProvenFallback = false
        self.dependencyAnalysisLimitExceeded = false
        self.mediaAnalysisLimitExceeded = false
    }

    init(
        usesAudioListener: Bool,
        usesMediaIntegration: Bool,
        missingLocalDependencies: [String],
        remoteDependencies: [String],
        localMediaReferences: [WebLocalMediaReference],
        missingLocalMediaReferences: [String],
        remoteMediaReferences: [String],
        hasOpaqueOrDynamicMediaReferences: Bool,
        localResourceMIMEOverrides: [WebLocalResourceMIMEOverride],
        missingLocalMediaHasProvenFallback: Bool,
        remoteMediaHasProvenFallback: Bool,
        dependencyAnalysisLimitExceeded: Bool,
        mediaAnalysisLimitExceeded: Bool
    ) {
        self.usesAudioListener = usesAudioListener
        self.usesMediaIntegration = usesMediaIntegration
        self.missingLocalDependencies = Array(Set(missingLocalDependencies)).sorted()
        self.remoteDependencies = Array(Set(remoteDependencies)).sorted()
        self.localMediaReferences = Self.sortedLocalMediaReferences(localMediaReferences)
        self.missingLocalMediaReferences = Array(Set(missingLocalMediaReferences)).sorted()
        self.remoteMediaReferences = Array(Set(remoteMediaReferences)).sorted()
        self.hasOpaqueOrDynamicMediaReferences = hasOpaqueOrDynamicMediaReferences
        self.localResourceMIMEOverrides = Self.sortedMIMEOverrides(
            localResourceMIMEOverrides
        )
        self.missingLocalMediaHasProvenFallback = missingLocalMediaHasProvenFallback
        self.remoteMediaHasProvenFallback = remoteMediaHasProvenFallback
        self.dependencyAnalysisLimitExceeded = dependencyAnalysisLimitExceeded
        self.mediaAnalysisLimitExceeded = mediaAnalysisLimitExceeded
    }

    private static func sortedLocalMediaReferences(
        _ references: [WebLocalMediaReference]
    ) -> [WebLocalMediaReference] {
        Array(Set(references)).sorted {
            if $0.sourceURL.path != $1.sourceURL.path {
                return $0.sourceURL.path < $1.sourceURL.path
            }
            if $0.elementKind != $1.elementKind {
                return $0.elementKind.rawValue < $1.elementKind.rawValue
            }
            return $0.rawReference < $1.rawReference
        }
    }

    private static func sortedMIMEOverrides(
        _ overrides: [WebLocalResourceMIMEOverride]
    ) -> [WebLocalResourceMIMEOverride] {
        Array(Set(overrides)).sorted {
            if $0.sourceURL.path != $1.sourceURL.path {
                return $0.sourceURL.path < $1.sourceURL.path
            }
            return $0.mimeType < $1.mimeType
        }
    }
}

public struct WebRuntimeFeatureAnalyzer: Sendable {
    static let maximumDependencyNodes = 2_000
    static let maximumDependencyTextBytes = 8 * 1_024 * 1_024
    static let maximumReferencesPerFile = 256
    static let maximumJavaScriptNestingDepth = 64
    static let maximumDocumentDependencyElements = maximumDependencyNodes
    static let maximumStaticMediaReferences = 64
    static let maximumHTMLDocuments = 64
    static let maximumHTMLNestingDepth = 8

    private enum DocumentBase: Sendable {
        case resolved(URL)
        case invalid
    }

    private enum DependencyResolution {
        case ignored
        case local(URL)
        case missingLocal
        case externalNetwork
    }

    private enum DependencyFileKind: Sendable {
        case javaScript
        case stylesheet
        case htmlDocument(depth: Int)

        var keyKind: DependencyFileKeyKind {
            switch self {
            case .javaScript: .javaScript
            case .stylesheet: .stylesheet
            case .htmlDocument: .htmlDocument
            }
        }
    }

    private enum DependencyFileKeyKind: Hashable, Sendable {
        case javaScript
        case stylesheet
        case htmlDocument
    }

    private struct DependencyNodeKey: Hashable, Sendable {
        let canonicalPath: String
        let kind: DependencyFileKeyKind
    }

    private enum DependencyReferenceContext: Equatable {
        case document
        case javaScript
        case stylesheet
    }

    private enum JavaScriptParenthesisContext {
        case controlHeader
        case expression
    }

    private enum JavaScriptBraceContext {
        case controlStatement
        case expression
    }

    private struct DependencyNode: Sendable {
        let url: URL
        let kind: DependencyFileKind
        let runtimeBase: DocumentBase
    }

    private struct JavaScriptMediaReference: Sendable {
        let kind: WebMediaElementKind
        let reference: String
        /// Generic `.src`/`setAttribute("src", …)` also targets images,
        /// scripts, iframes and stylesheets. Only treat a literal from those
        /// shapes as media when its path is recognizably media-like; `new
        /// Audio(...)` and explicit HTML media elements do not need this hint.
        let requiresMediaPathHint: Bool
    }

    private enum JavaScriptMediaExpression {
        case literal(String)
        case opaque
    }

    private enum JavaScriptSourcePathKind {
        case media
        case knownNonMedia
        case unknown
    }

    private static let javaScriptMediaPathExtensions: Set<String> = [
        "3g2", "3gp", "aac", "ac3", "asf", "avi", "flac", "m2ts", "m4a",
        "m4v", "mka", "mkv", "mov", "mp2", "mp3", "mp4", "mpeg", "mpg",
        "oga", "ogg", "ogv", "opus", "ts", "wav", "webm", "wma", "wmv"
    ]

    private static let javaScriptKnownNonMediaPathExtensions: Set<String> = [
        "apng", "avif", "bmp", "cjs", "css", "gif", "heic", "heif", "htm",
        "html", "ico", "jpeg", "jpg", "js", "json", "mjs", "otf", "pdf",
        "png", "srt", "svg", "tif", "tiff", "ttf", "txt", "vtt", "wasm",
        "webp", "woff", "woff2", "xml"
    ]

    private enum StaticMediaIdentity: Hashable {
        case local(path: String, kind: WebMediaElementKind)
        case missing(reference: String, kind: WebMediaElementKind)
        case remote(reference: String, kind: WebMediaElementKind)
    }

    private struct DocumentDependencyElement {
        let name: String
        let openingTag: String
        let rawText: String?
        let mediaContainer: WebMediaElementKind?
        let mediaGroupID: Int?
        let localMediaCanProveFallback: Bool
    }

    private struct DocumentMediaContainer {
        let kind: WebMediaElementKind
        let groupID: Int
        let hasAuthoredSource: Bool
    }

    private struct HTMLMediaGroupKey: Hashable {
        let documentID: Int
        let containerID: Int
    }

    private enum HTMLMediaAvailability {
        case local
        case missingLocal
        case remote
    }

    private struct HTMLMediaGroupState {
        var hasLocal = false
        var hasMissingLocal = false
        var hasRemote = false
    }

    private struct DocumentDependencyScanResult {
        let elements: [DocumentDependencyElement]
        let limitExceeded: Bool
    }

    private struct DependencyScanResult {
        let references: [String]
        let mediaReferences: [JavaScriptMediaReference]
        let hasOpaqueOrDynamicMediaReferences: Bool
        let scannedReferenceCount: Int
        let limitExceeded: Bool

        init(
            references: [String],
            mediaReferences: [JavaScriptMediaReference] = [],
            hasOpaqueOrDynamicMediaReferences: Bool = false,
            scannedReferenceCount: Int? = nil,
            limitExceeded: Bool
        ) {
            self.references = references
            self.mediaReferences = mediaReferences
            self.hasOpaqueOrDynamicMediaReferences = hasOpaqueOrDynamicMediaReferences
            self.scannedReferenceCount = scannedReferenceCount
                ?? references.count + mediaReferences.count
            self.limitExceeded = limitExceeded
        }
    }

    private struct DependencyAnalysisResult {
        var missingLocal = Set<String>()
        var remote = Set<String>()
        var localMediaByIdentity = [StaticMediaIdentity: WebLocalMediaReference]()
        var missingLocalMedia = Set<String>()
        var remoteMedia = Set<String>()
        var mediaIdentities = Set<StaticMediaIdentity>()
        var htmlMediaGroups = [HTMLMediaGroupKey: HTMLMediaGroupState]()
        var hasUngroupedMissingLocalMedia = false
        var hasUngroupedRemoteMedia = false
        var nextHTMLDocumentID = 0
        var hasOpaqueOrDynamicMediaReferences = false
        var localResourceMIMEOverrideByPath = [String: WebLocalResourceMIMEOverride]()
        var limitExceeded = false
        var mediaLimitExceeded = false

        var missingLocalMediaHasProvenFallback: Bool {
            guard !missingLocalMedia.isEmpty, !hasUngroupedMissingLocalMedia else {
                return false
            }
            let affectedGroups = htmlMediaGroups.values.filter(\.hasMissingLocal)
            return !affectedGroups.isEmpty && affectedGroups.allSatisfy(\.hasLocal)
        }

        var remoteMediaHasProvenFallback: Bool {
            guard !remoteMedia.isEmpty, !hasUngroupedRemoteMedia else { return false }
            let affectedGroups = htmlMediaGroups.values.filter(\.hasRemote)
            return !affectedGroups.isEmpty && affectedGroups.allSatisfy(\.hasLocal)
        }
    }

    public init() {}

    /// Searches only bounded text files inside the project. This finds the
    /// common case where index.html imports the Wallpaper Engine callbacks
    /// from a separate script without following arbitrary URL references.
    public func analyze(entrypoint: URL, projectRoot: URL) -> WebRuntimeFeatures {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let dependencies = criticalDependencies(
            entrypoint: entrypoint,
            root: root
        )
        let allowedExtensions = Set(["html", "htm", "js", "mjs", "css", "json"])
        var candidates = [entrypoint]
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            var examinedEntries = 0
            for case let url as URL in enumerator {
                examinedEntries += 1
                guard examinedEntries <= 10_000, candidates.count < 2_000 else { break }
                guard allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                candidates.append(url)
            }
        }
        var remainingBytes = 8 * 1_024 * 1_024
        var usesAudioListener = false
        var usesMediaIntegration = false
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
            if source.contains("wallpaperRegisterAudioListener") {
                usesAudioListener = true
            }
            if source.contains("wallpaperRegisterMedia") {
                usesMediaIntegration = true
            }
            if usesAudioListener && usesMediaIntegration { break }
        }
        return WebRuntimeFeatures(
            usesAudioListener: usesAudioListener,
            usesMediaIntegration: usesMediaIntegration,
            missingLocalDependencies: Array(dependencies.missingLocal),
            remoteDependencies: Array(dependencies.remote),
            localMediaReferences: Array(dependencies.localMediaByIdentity.values),
            missingLocalMediaReferences: Array(dependencies.missingLocalMedia),
            remoteMediaReferences: Array(dependencies.remoteMedia),
            hasOpaqueOrDynamicMediaReferences: dependencies.hasOpaqueOrDynamicMediaReferences,
            localResourceMIMEOverrides: Array(
                dependencies.localResourceMIMEOverrideByPath.values
            ),
            missingLocalMediaHasProvenFallback:
                dependencies.missingLocalMediaHasProvenFallback,
            remoteMediaHasProvenFallback: dependencies.remoteMediaHasProvenFallback,
            dependencyAnalysisLimitExceeded: dependencies.limitExceeded,
            mediaAnalysisLimitExceeded: dependencies.mediaLimitExceeded
        )
    }

    public func usesAudioListener(entrypoint: URL, projectRoot: URL) -> Bool {
        analyze(entrypoint: entrypoint, projectRoot: projectRoot).usesAudioListener
    }

    private func isInside(_ candidate: URL, root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// Walks only the dependency graph reachable from the entrypoint's scripts,
    /// stylesheets, and local iframe documents. This avoids treating unused
    /// files in a Workshop project as requirements while still finding media
    /// and load-blocking resources that affect the rendered Web wallpaper.
    private func criticalDependencies(
        entrypoint: URL,
        root: URL
    ) -> DependencyAnalysisResult {
        var result = DependencyAnalysisResult()
        let canonicalEntrypoint = canonicalFileURL(entrypoint)
        recordRuntimeMIMEType(
            "text/html",
            for: canonicalEntrypoint,
            result: &result
        )
        guard let values = try? entrypoint.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true,
              let fileSize = values.fileSize, fileSize > 0,
              fileSize <= Self.maximumDependencyTextBytes,
              let data = try? Data(contentsOf: entrypoint, options: [.mappedIfSafe]),
              !data.isEmpty,
              data.count <= Self.maximumDependencyTextBytes,
              let source = WebWallpaperValidation.decodeTextPrefix(data) else {
            // The entrypoint itself is part of the aggregate dependency-text
            // budget. An oversized file or a read/decode race must not silently
            // become Full Live merely because dependency analysis was skipped.
            result.limitExceeded = true
            return result
        }
        let entrypointKey = DependencyNodeKey(
            canonicalPath: canonicalFileURL(entrypoint).path,
            kind: .htmlDocument
        )
        var queue = [DependencyNode]()
        var discoveredNodes = Set([entrypointKey])
        var htmlDocumentCount = 1
        var totalTextBytes = data.count
        scanHTMLDocument(
            source,
            documentURL: entrypoint,
            depth: 0,
            inheritedBase: nil,
            root: root,
            result: &result,
            totalTextBytes: &totalTextBytes,
            htmlDocumentCount: &htmlDocumentCount,
            queue: &queue,
            discoveredNodes: &discoveredNodes
        )
        if result.limitExceeded { return result }

        var queueIndex = 0
        while queueIndex < queue.count {
            let node = queue[queueIndex]
            queueIndex += 1
            guard let values = try? node.url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            ), values.isRegularFile == true, values.isSymbolicLink != true,
                  let fileSize = values.fileSize, fileSize >= 0,
                  fileSize <= Self.maximumDependencyTextBytes - totalTextBytes else {
                result.limitExceeded = true
                break
            }
            guard let dependencyData = try? Data(contentsOf: node.url, options: [.mappedIfSafe]) else {
                result.missingLocal.insert(node.url.lastPathComponent)
                continue
            }
            guard dependencyData.count <= Self.maximumDependencyTextBytes - totalTextBytes else {
                result.limitExceeded = true
                break
            }
            totalTextBytes += dependencyData.count
            guard let dependencySource = WebWallpaperValidation.decodeTextPrefix(dependencyData) else {
                if case .htmlDocument = node.kind {
                    result.limitExceeded = true
                    break
                }
                continue
            }
            if case .htmlDocument(let depth) = node.kind {
                scanHTMLDocument(
                    dependencySource,
                    documentURL: node.url,
                    depth: depth,
                    inheritedBase: nil,
                    root: root,
                    result: &result,
                    totalTextBytes: &totalTextBytes,
                    htmlDocumentCount: &htmlDocumentCount,
                    queue: &queue,
                    discoveredNodes: &discoveredNodes
                )
                if result.limitExceeded { break }
                continue
            }
            let scan: DependencyScanResult
            let context: DependencyReferenceContext
            switch node.kind {
            case .javaScript:
                scan = javaScriptDependencies(
                    in: dependencySource,
                    limit: Self.maximumReferencesPerFile
                )
                context = .javaScript
            case .stylesheet:
                scan = stylesheetDependencies(
                    in: dependencySource,
                    limit: Self.maximumReferencesPerFile
                )
                context = .stylesheet
            case .htmlDocument:
                continue
            }
            guard !scan.limitExceeded else {
                result.limitExceeded = true
                break
            }
            if case .javaScript = node.kind {
                appendJavaScriptMediaReferences(
                    scan,
                    base: node.runtimeBase,
                    root: root,
                    result: &result
                )
            }
            appendScannedDependencies(
                scan.references,
                base: .resolved(node.url),
                runtimeBase: node.runtimeBase,
                context: context,
                importer: node.url,
                root: root,
                result: &result,
                queue: &queue,
                discoveredNodes: &discoveredNodes
            )
            if result.limitExceeded { break }
        }
        return result
    }

    private func scanHTMLDocument(
        _ source: String,
        documentURL: URL,
        depth: Int,
        inheritedBase: DocumentBase?,
        root: URL,
        result: inout DependencyAnalysisResult,
        totalTextBytes: inout Int,
        htmlDocumentCount: inout Int,
        queue: inout [DependencyNode],
        discoveredNodes: inout Set<DependencyNodeKey>
    ) {
        let documentScan = documentDependencyElements(
            in: source,
            limit: Self.maximumDocumentDependencyElements
        )
        guard !documentScan.limitExceeded else {
            result.limitExceeded = true
            return
        }
        let htmlDocumentID = result.nextHTMLDocumentID
        result.nextHTMLDocumentID += 1
        var effectiveBase = inheritedBase ?? DocumentBase.resolved(documentURL)
        var hasDocumentBase = false
        var referenceCount = 0
        for element in documentScan.elements {
            if element.name == "base",
               !hasDocumentBase,
               let reference = attribute("href", in: element.openingTag) {
                effectiveBase = documentBase(reference: reference, entrypoint: documentURL)
                hasDocumentBase = true
                continue
            }
            if let declaredMediaKind = WebMediaElementKind(rawValue: element.name),
               let mediaReference = attribute("src", in: element.openingTag) {
                // `<source>` also belongs to `<picture>`. Only an audio/video
                // container participates in HTMLMediaElement playback; an
                // orphan or picture source must not be sent through FFmpeg as
                // though an image were malformed video.
                let mediaKind: WebMediaElementKind
                if declaredMediaKind == .source {
                    guard let container = element.mediaContainer else { continue }
                    mediaKind = container
                } else {
                    mediaKind = declaredMediaKind
                }
                guard let mediaGroupID = element.mediaGroupID else { continue }
                appendStaticMediaReference(
                    mediaReference,
                    kind: mediaKind,
                    base: effectiveBase,
                    root: root,
                    result: &result,
                    localMediaCanProveFallback: element.localMediaCanProveFallback,
                    mediaGroup: HTMLMediaGroupKey(
                        documentID: htmlDocumentID,
                        containerID: mediaGroupID
                    )
                )
                continue
            }
            if element.name == "iframe" {
                referenceCount += 1
                guard referenceCount <= Self.maximumReferencesPerFile else {
                    result.limitExceeded = true
                    return
                }
                if let inlineSource = attribute("srcdoc", in: element.openingTag) {
                    appendInlineHTMLDocument(
                        inlineSource,
                        documentURL: documentURL,
                        inheritedBase: effectiveBase,
                        depth: depth + 1,
                        root: root,
                        result: &result,
                        totalTextBytes: &totalTextBytes,
                        htmlDocumentCount: &htmlDocumentCount,
                        queue: &queue,
                        discoveredNodes: &discoveredNodes
                    )
                } else if let iframeReference = attribute("src", in: element.openingTag) {
                    appendHTMLDocumentDependency(
                        iframeReference,
                        base: effectiveBase,
                        depth: depth + 1,
                        root: root,
                        result: &result,
                        htmlDocumentCount: &htmlDocumentCount,
                        queue: &queue,
                        discoveredNodes: &discoveredNodes
                    )
                }
                if result.limitExceeded { return }
                continue
            }
            let dependency: (reference: String, kind: DependencyFileKind)?
            if element.name == "script", isExecutableScript(element.openingTag) {
                dependency = attribute("src", in: element.openingTag).map { ($0, .javaScript) }
            } else if element.name == "link" {
                let relationships = attribute("rel", in: element.openingTag)?
                    .lowercased()
                    .split(whereSeparator: { $0.isWhitespace })
                    .map(String.init) ?? []
                dependency = relationships.contains("stylesheet")
                    ? attribute("href", in: element.openingTag).map { ($0, .stylesheet) }
                    : nil
            } else {
                dependency = nil
            }
            if let dependency {
                referenceCount += 1
                guard referenceCount <= Self.maximumReferencesPerFile else {
                    result.limitExceeded = true
                    return
                }
                appendDependency(
                    dependency.reference,
                    base: effectiveBase,
                    context: .document,
                    kind: dependency.kind,
                    root: root,
                    result: &result,
                    queue: &queue,
                    discoveredNodes: &discoveredNodes,
                    runtimeBase: effectiveBase
                )
                if result.limitExceeded { return }
                continue
            }

            let inlineScan: (scan: DependencyScanResult, context: DependencyReferenceContext)?
            if element.name == "script",
               isExecutableScript(element.openingTag),
               let rawText = element.rawText {
                inlineScan = (
                    javaScriptDependencies(
                        in: rawText,
                        limit: Self.maximumReferencesPerFile - referenceCount
                    ),
                    .javaScript
                )
            } else if element.name == "style",
                      isCSSInlineStyle(element.openingTag),
                      let rawText = element.rawText {
                inlineScan = (
                    stylesheetDependencies(
                        in: rawText,
                        limit: Self.maximumReferencesPerFile - referenceCount
                    ),
                    .stylesheet
                )
            } else {
                inlineScan = nil
            }
            guard let inlineScan else { continue }
            guard !inlineScan.scan.limitExceeded else {
                result.limitExceeded = true
                return
            }
            referenceCount += inlineScan.scan.scannedReferenceCount
            if inlineScan.context == .javaScript {
                appendJavaScriptMediaReferences(
                    inlineScan.scan,
                    base: effectiveBase,
                    root: root,
                    result: &result
                )
            }
            appendScannedDependencies(
                inlineScan.scan.references,
                base: effectiveBase,
                runtimeBase: effectiveBase,
                context: inlineScan.context,
                importer: documentURL,
                root: root,
                result: &result,
                queue: &queue,
                discoveredNodes: &discoveredNodes
            )
            if result.limitExceeded { return }
        }
    }

    private func appendHTMLDocumentDependency(
        _ reference: String,
        base: DocumentBase,
        depth: Int,
        root: URL,
        result: inout DependencyAnalysisResult,
        htmlDocumentCount: inout Int,
        queue: inout [DependencyNode],
        discoveredNodes: inout Set<DependencyNodeKey>
    ) {
        switch dependencyResolution(reference, base: base, context: .document, root: root) {
        case .ignored:
            break
        case .missingLocal:
            result.missingLocal.insert(reference)
        case .externalNetwork:
            result.remote.insert(reference)
        case .local(let url):
            let canonical = canonicalFileURL(url)
            recordRuntimeMIMEType("text/html", for: canonical, result: &result)
            let key = DependencyNodeKey(
                canonicalPath: canonical.path,
                kind: .htmlDocument
            )
            guard !discoveredNodes.contains(key) else { return }
            guard depth <= Self.maximumHTMLNestingDepth,
                  htmlDocumentCount < Self.maximumHTMLDocuments,
                  discoveredNodes.count < Self.maximumDependencyNodes else {
                result.limitExceeded = true
                return
            }
            discoveredNodes.insert(key)
            htmlDocumentCount += 1
            queue.append(
                DependencyNode(
                    url: canonical,
                    kind: .htmlDocument(depth: depth),
                    runtimeBase: .resolved(canonical)
                )
            )
        }
    }

    private func appendInlineHTMLDocument(
        _ source: String,
        documentURL: URL,
        inheritedBase: DocumentBase,
        depth: Int,
        root: URL,
        result: inout DependencyAnalysisResult,
        totalTextBytes: inout Int,
        htmlDocumentCount: inout Int,
        queue: inout [DependencyNode],
        discoveredNodes: inout Set<DependencyNodeKey>
    ) {
        let byteCount = source.utf8.count
        guard depth <= Self.maximumHTMLNestingDepth,
              htmlDocumentCount < Self.maximumHTMLDocuments,
              byteCount <= Self.maximumDependencyTextBytes - totalTextBytes else {
            result.limitExceeded = true
            return
        }
        htmlDocumentCount += 1
        totalTextBytes += byteCount
        scanHTMLDocument(
            source,
            documentURL: documentURL,
            depth: depth,
            inheritedBase: inheritedBase,
            root: root,
            result: &result,
            totalTextBytes: &totalTextBytes,
            htmlDocumentCount: &htmlDocumentCount,
            queue: &queue,
            discoveredNodes: &discoveredNodes
        )
    }

    private func appendJavaScriptMediaReferences(
        _ scan: DependencyScanResult,
        base: DocumentBase,
        root: URL,
        result: inout DependencyAnalysisResult
    ) {
        if scan.hasOpaqueOrDynamicMediaReferences {
            result.hasOpaqueOrDynamicMediaReferences = true
        }
        for media in scan.mediaReferences {
            appendStaticMediaReference(
                media.reference,
                kind: media.kind,
                base: base,
                root: root,
                result: &result,
                requiresMediaPathHint: media.requiresMediaPathHint
            )
        }
    }

    private func appendStaticMediaReference(
        _ reference: String,
        kind: WebMediaElementKind,
        base: DocumentBase,
        root: URL,
        result: inout DependencyAnalysisResult,
        requiresMediaPathHint: Bool = false,
        localMediaCanProveFallback: Bool = true,
        mediaGroup: HTMLMediaGroupKey? = nil
    ) {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("{{") || trimmed.contains("${") {
            result.hasOpaqueOrDynamicMediaReferences = true
            return
        }
        var requiresLocalContentHint = false
        if requiresMediaPathHint {
            switch javaScriptSourcePathKind(trimmed) {
            case .media:
                break
            case .knownNonMedia:
                return
            case .unknown:
                // A generic DOM `.src` assignment can target an image,
                // script, frame, audio, or video element. Resolve safe local
                // literals first so extensionless and percent-encoded media
                // can be recognized by bounded content signatures without
                // sending obvious image/script assets to FFmpeg.
                requiresLocalContentHint = true
            }
        }
        switch dependencyResolution(trimmed, base: base, context: .document, root: root) {
        case .ignored:
            if requiresLocalContentHint {
                result.hasOpaqueOrDynamicMediaReferences = true
            }
        case .missingLocal:
            if requiresLocalContentHint {
                result.hasOpaqueOrDynamicMediaReferences = true
                return
            }
            let identity = StaticMediaIdentity.missing(reference: trimmed, kind: kind)
            recordHTMLMediaAvailability(.missingLocal, group: mediaGroup, result: &result)
            guard reserveStaticMediaIdentity(identity, result: &result) else { return }
            result.missingLocalMedia.insert(trimmed)
        case .externalNetwork:
            if requiresLocalContentHint {
                result.hasOpaqueOrDynamicMediaReferences = true
                return
            }
            let identity = StaticMediaIdentity.remote(reference: trimmed, kind: kind)
            recordHTMLMediaAvailability(.remote, group: mediaGroup, result: &result)
            guard reserveStaticMediaIdentity(identity, result: &result) else { return }
            result.remoteMedia.insert(trimmed)
        case .local(let url):
            let canonical = canonicalFileURL(url)
            if requiresLocalContentHint {
                switch javaScriptLocalSourceContentKind(canonical) {
                case .media:
                    break
                case .knownNonMedia:
                    return
                case .unknown:
                    result.hasOpaqueOrDynamicMediaReferences = true
                    return
                }
            }
            let identity = StaticMediaIdentity.local(path: canonical.path, kind: kind)
            if localMediaCanProveFallback {
                recordHTMLMediaAvailability(.local, group: mediaGroup, result: &result)
            }
            guard reserveStaticMediaIdentity(identity, result: &result) else { return }
            let candidate = WebLocalMediaReference(
                elementKind: kind,
                rawReference: trimmed,
                sourceURL: canonical
            )
            // One canonical source needs one prepared mapping regardless of how
            // many syntactic aliases reference it. Keeping only the stable
            // smallest spelling prevents an alias-heavy Workshop project from
            // multiplying AVFoundation probes while preserving deterministic
            // diagnostics and the exact canonical source identity.
            if let existing = result.localMediaByIdentity[identity] {
                if candidate.rawReference < existing.rawReference {
                    result.localMediaByIdentity[identity] = candidate
                }
            } else {
                result.localMediaByIdentity[identity] = candidate
            }
        }
    }

    private func recordHTMLMediaAvailability(
        _ availability: HTMLMediaAvailability,
        group: HTMLMediaGroupKey?,
        result: inout DependencyAnalysisResult
    ) {
        guard let group else {
            switch availability {
            case .local:
                break
            case .missingLocal:
                result.hasUngroupedMissingLocalMedia = true
            case .remote:
                result.hasUngroupedRemoteMedia = true
            }
            return
        }
        var state = result.htmlMediaGroups[group] ?? HTMLMediaGroupState()
        switch availability {
        case .local:
            state.hasLocal = true
        case .missingLocal:
            state.hasMissingLocal = true
        case .remote:
            state.hasRemote = true
        }
        result.htmlMediaGroups[group] = state
    }

    private func reserveStaticMediaIdentity(
        _ identity: StaticMediaIdentity,
        result: inout DependencyAnalysisResult
    ) -> Bool {
        if result.mediaIdentities.contains(identity) { return true }
        guard result.mediaIdentities.count < Self.maximumStaticMediaReferences else {
            result.mediaLimitExceeded = true
            return false
        }
        result.mediaIdentities.insert(identity)
        return true
    }

    private func javaScriptSourcePathKind(_ reference: String) -> JavaScriptSourcePathKind {
        // Strip URL query/fragment syntax before asking NSString for the last
        // path extension. The result is only a disambiguation hint for generic
        // DOM `src` assignments; actual playability remains content-probed.
        let withoutFragment = reference.split(separator: "#", maxSplits: 1).first
            .map(String.init) ?? reference
        let path = withoutFragment.split(separator: "?", maxSplits: 1).first
            .map(String.init) ?? withoutFragment
        let pathExtension = (path as NSString).pathExtension.lowercased()
        if Self.javaScriptMediaPathExtensions.contains(pathExtension) {
            return .media
        }
        if Self.javaScriptKnownNonMediaPathExtensions.contains(pathExtension) {
            return .knownNonMedia
        }
        return .unknown
    }

    private func javaScriptLocalSourceContentKind(_ url: URL) -> JavaScriptSourcePathKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512), !data.isEmpty else {
            return .unknown
        }
        let bytes = [UInt8](data)
        func matches(_ offset: Int, _ signature: [UInt8]) -> Bool {
            guard offset >= 0, offset <= bytes.count,
                  signature.count <= bytes.count - offset else {
                return false
            }
            return bytes[offset..<(offset + signature.count)].elementsEqual(signature)
        }
        func ascii(_ value: String) -> [UInt8] { Array(value.utf8) }

        // This analyzer runs synchronously during import and must never invoke
        // the full animated-image validator: a hostile image can advertise
        // thousands of huge frames. A bounded header is enough to exclude
        // common image containers from generic DOM `src` media discovery.
        let imageISOBMFFBrands: Set<[UInt8]> = [
            ascii("avif"), ascii("avis"), ascii("heic"), ascii("heix"),
            ascii("hevc"), ascii("hevx"), ascii("mif1"), ascii("msf1")
        ]
        let isImageContainer = matches(0, [0x89, 0x50, 0x4E, 0x47,
                                          0x0D, 0x0A, 0x1A, 0x0A])
            || matches(0, ascii("GIF87a"))
            || matches(0, ascii("GIF89a"))
            || matches(0, [0xFF, 0xD8, 0xFF])
            || matches(0, ascii("BM"))
            || matches(0, [0x49, 0x49, 0x2A, 0x00])
            || matches(0, [0x4D, 0x4D, 0x00, 0x2A])
            || matches(0, [0x00, 0x00, 0x01, 0x00])
            || matches(0, ascii("8BPS"))
            || matches(0, ascii("DDS "))
            || matches(0, [0xFF, 0x0A])
            || matches(0, [0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20,
                           0x0D, 0x0A, 0x87, 0x0A])
            || (matches(0, ascii("RIFF")) && matches(8, ascii("WEBP")))
            || (matches(4, ascii("ftyp"))
                && bytes.count >= 12
                && imageISOBMFFBrands.contains(Array(bytes[8..<12])))
        if isImageContainer { return .knownNonMedia }

        if matches(0, ascii("OggS"))
            || matches(0, ascii("fLaC"))
            || matches(0, ascii("ID3"))
            || matches(0, ascii(".snd"))
            || matches(0, ascii("MThd"))
            || matches(0, [0x1A, 0x45, 0xDF, 0xA3])
            || matches(0, [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
                           0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C])
            || (matches(0, ascii("RIFF"))
                && (matches(8, ascii("AVI ")) || matches(8, ascii("WAVE"))))
            || (matches(0, ascii("FORM"))
                && (matches(8, ascii("AIFF")) || matches(8, ascii("AIFC"))))
            || matches(4, ascii("ftyp"))
            || (bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0)
            || (bytes.count > 188 && bytes[0] == 0x47 && bytes[188] == 0x47) {
            return .media
        }
        if let text = String(data: data, encoding: .utf8),
           !text.unicodeScalars.contains(where: {
               $0.value == 0
                   || ($0.value < 0x20
                       && $0.value != 0x09
                       && $0.value != 0x0A
                       && $0.value != 0x0D)
           }) {
            return .knownNonMedia
        }
        return .unknown
    }

    private func appendScannedDependencies(
        _ references: [String],
        base: DocumentBase,
        runtimeBase: DocumentBase,
        context: DependencyReferenceContext,
        importer: URL,
        root: URL,
        result: inout DependencyAnalysisResult,
        queue: inout [DependencyNode],
        discoveredNodes: inout Set<DependencyNodeKey>
    ) {
        for reference in references {
            let kind: DependencyFileKind?
            switch context {
            case .javaScript:
                // Static imports without an extension (or with an authored
                // asset-style extension) are executable JavaScript. Keep
                // standard typed module resources on their normal MIME path;
                // overriding JSON/CSS/WASM as JavaScript would make a valid
                // import assertion fail under `nosniff`.
                let importedExtension = URL(
                    string: reference,
                    relativeTo: importer
                )?.pathExtension.lowercased() ?? ""
                kind = ["css", "json", "wasm"].contains(importedExtension)
                    ? nil
                    : .javaScript
            case .stylesheet:
                kind = .stylesheet
            case .document:
                kind = nil
            }
            appendDependency(
                reference,
                base: base,
                context: context,
                kind: kind,
                root: root,
                result: &result,
                queue: &queue,
                discoveredNodes: &discoveredNodes,
                runtimeBase: runtimeBase
            )
            if result.limitExceeded { return }
        }
    }

    private func isExecutableScript(_ tag: String) -> Bool {
        let type = (attribute("type", in: tag) ?? "")
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let isModule = type == "module"
        let isClassic = type.isEmpty || [
            "text/javascript", "application/javascript", "application/x-javascript",
            "text/ecmascript", "application/ecmascript", "text/jscript"
        ].contains(type)
        guard isModule || isClassic else { return false }
        // WKWebView on the macOS 14 deployment target supports modules, so a
        // classic `nomodule` fallback is inert. The attribute has no effect on
        // an actual module script.
        return isModule || attribute("nomodule", in: tag) == nil
    }

    private func isCSSInlineStyle(_ tag: String) -> Bool {
        guard let rawType = attribute("type", in: tag) else { return true }
        let type = rawType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return type.isEmpty || type == "text/css"
    }

    private func appendDependency(
        _ reference: String,
        base: DocumentBase,
        context: DependencyReferenceContext,
        kind: DependencyFileKind?,
        root: URL,
        result: inout DependencyAnalysisResult,
        queue: inout [DependencyNode],
        discoveredNodes: inout Set<DependencyNodeKey>,
        runtimeBase: DocumentBase
    ) {
        switch dependencyResolution(reference, base: base, context: context, root: root) {
        case .ignored:
            break
        case .missingLocal:
            result.missingLocal.insert(reference)
        case .externalNetwork:
            result.remote.insert(reference)
        case .local(let url):
            let canonical = canonicalFileURL(url)
            guard let kind else { return }
            recordRuntimeMIMEType(
                runtimeMIMEType(for: kind),
                for: canonical,
                result: &result
            )
            let key = DependencyNodeKey(
                canonicalPath: canonical.path,
                kind: kind.keyKind
            )
            guard !discoveredNodes.contains(key) else { return }
            guard discoveredNodes.count < Self.maximumDependencyNodes else {
                result.limitExceeded = true
                return
            }
            discoveredNodes.insert(key)
            queue.append(
                DependencyNode(url: canonical, kind: kind, runtimeBase: runtimeBase)
            )
        }
    }

    private func canonicalFileURL(_ url: URL) -> URL {
        URL(filePath: url.path).standardizedFileURL.resolvingSymlinksInPath()
    }

    private func runtimeMIMEType(for kind: DependencyFileKind) -> String {
        switch kind {
        case .javaScript: "text/javascript"
        case .stylesheet: "text/css"
        case .htmlDocument: "text/html"
        }
    }

    private func recordRuntimeMIMEType(
        _ mimeType: String,
        for sourceURL: URL,
        result: inout DependencyAnalysisResult
    ) {
        let canonical = canonicalFileURL(sourceURL)
        // A valid Web dependency has one semantic role at a given URL. If a
        // malformed project imports the same bytes with conflicting roles,
        // keep the first dependency-graph interpretation deterministic rather
        // than allowing filename sniffing to weaken `nosniff` responses.
        guard result.localResourceMIMEOverrideByPath[canonical.path] == nil else {
            return
        }
        result.localResourceMIMEOverrideByPath[canonical.path] =
            WebLocalResourceMIMEOverride(sourceURL: canonical, mimeType: mimeType)
    }

    private func javaScriptDependencies(in source: String, limit: Int) -> DependencyScanResult {
        let bytes = Array(source.utf8)
        var references = [String]()
        var mediaReferences = [JavaScriptMediaReference]()
        var hasOpaqueOrDynamicMediaReferences = false
        var scannedReferenceCount = 0
        var limitExceeded = false
        _ = scanJavaScript(
            bytes,
            from: 0,
            stopAtClosingBrace: false,
            nestingDepth: 0,
            limit: limit,
            references: &references,
            mediaReferences: &mediaReferences,
            hasOpaqueOrDynamicMediaReferences: &hasOpaqueOrDynamicMediaReferences,
            scannedReferenceCount: &scannedReferenceCount,
            limitExceeded: &limitExceeded
        )
        return DependencyScanResult(
            references: Array(references.prefix(max(limit, 0))),
            mediaReferences: Array(mediaReferences.prefix(max(limit, 0))),
            hasOpaqueOrDynamicMediaReferences: hasOpaqueOrDynamicMediaReferences,
            scannedReferenceCount: scannedReferenceCount,
            limitExceeded: limitExceeded || scannedReferenceCount > limit
        )
    }

    private func scanJavaScript(
        _ bytes: [UInt8],
        from start: Int,
        stopAtClosingBrace: Bool,
        nestingDepth: Int,
        limit: Int,
        references: inout [String],
        mediaReferences: inout [JavaScriptMediaReference],
        hasOpaqueOrDynamicMediaReferences: inout Bool,
        scannedReferenceCount: inout Int,
        limitExceeded: inout Bool
    ) -> Int {
        guard nestingDepth <= Self.maximumJavaScriptNestingDepth else {
            limitExceeded = true
            return bytes.count
        }
        var index = start
        var parenthesisContexts = [JavaScriptParenthesisContext]()
        var braceContexts = [JavaScriptBraceContext]()
        var previousSignificantByte: UInt8?
        var expectsExpression = true
        var pendingControlHeader = false
        var pendingControlBody = false
        while index < bytes.count, !limitExceeded {
            if let afterTrivia = indexAfterJavaScriptTrivia(bytes, from: index), afterTrivia != index {
                index = afterTrivia
                continue
            }
            let byte = bytes[index]
            if pendingControlHeader, byte != 0x28 { pendingControlHeader = false }
            if pendingControlBody, byte != 0x7B { pendingControlBody = false }
            if byte == 0x22 || byte == 0x27 {
                if let mediaExpression = javaScriptQuotedObjectSourceProperty(
                    bytes,
                    from: index
                ) {
                    recordJavaScriptMediaExpression(
                        mediaExpression,
                        kind: .source,
                        requiresMediaPathHint: true,
                        limit: limit,
                        mediaReferences: &mediaReferences,
                        hasOpaqueOrDynamicMediaReferences: &hasOpaqueOrDynamicMediaReferences,
                        scannedReferenceCount: &scannedReferenceCount,
                        limitExceeded: &limitExceeded
                    )
                    if limitExceeded { return bytes.count }
                }
                index = indexAfterQuotedLiteral(bytes, from: index)
                previousSignificantByte = byte
                expectsExpression = false
                continue
            }
            if byte == 0x60 {
                index = scanJavaScriptTemplate(
                    bytes,
                    from: index,
                    nestingDepth: nestingDepth + 1,
                    limit: limit,
                    references: &references,
                    mediaReferences: &mediaReferences,
                    hasOpaqueOrDynamicMediaReferences: &hasOpaqueOrDynamicMediaReferences,
                    scannedReferenceCount: &scannedReferenceCount,
                    limitExceeded: &limitExceeded
                )
                previousSignificantByte = byte
                expectsExpression = false
                continue
            }
            if byte == 0x2F { // /: RegExp literal or division operator
                if expectsExpression,
                   let afterRegularExpression = indexAfterJavaScriptRegularExpression(
                       bytes,
                       from: index
                   ) {
                    index = afterRegularExpression
                    previousSignificantByte = byte
                    expectsExpression = false
                    continue
                }
                previousSignificantByte = byte
                index += index + 1 < bytes.count && bytes[index + 1] == 0x3D ? 2 : 1
                expectsExpression = true
                continue
            }
            if byte == 0x28 { // (
                guard parenthesisContexts.count < Self.maximumJavaScriptNestingDepth else {
                    limitExceeded = true
                    return bytes.count
                }
                parenthesisContexts.append(
                    pendingControlHeader ? .controlHeader : .expression
                )
                pendingControlHeader = false
                previousSignificantByte = byte
                index += 1
                expectsExpression = true
                continue
            }
            if byte == 0x29 { // )
                let context = parenthesisContexts.popLast() ?? .expression
                previousSignificantByte = byte
                index += 1
                if context == .controlHeader {
                    expectsExpression = true
                    pendingControlBody = true
                } else {
                    expectsExpression = false
                }
                continue
            }
            if byte == 0x7B { // {
                guard braceContexts.count < Self.maximumJavaScriptNestingDepth else {
                    limitExceeded = true
                    return bytes.count
                }
                braceContexts.append(
                    pendingControlBody ? .controlStatement : .expression
                )
                pendingControlBody = false
                previousSignificantByte = byte
                index += 1
                expectsExpression = true
                continue
            }
            if byte == 0x7D { // }
                if stopAtClosingBrace, braceContexts.isEmpty {
                    return index + 1
                }
                let context = braceContexts.popLast() ?? .expression
                previousSignificantByte = byte
                index += 1
                expectsExpression = context == .controlStatement
                continue
            }
            // Computed property assignment, for example
            // `video["src"] = chooseSource()`.
            if byte == 0x5B,
               let mediaExpression = javaScriptBracketSourceAssignment(
                   bytes,
                   from: index
               ) {
                recordJavaScriptMediaExpression(
                    mediaExpression,
                    kind: .source,
                    requiresMediaPathHint: true,
                    limit: limit,
                    mediaReferences: &mediaReferences,
                    hasOpaqueOrDynamicMediaReferences: &hasOpaqueOrDynamicMediaReferences,
                    scannedReferenceCount: &scannedReferenceCount,
                    limitExceeded: &limitExceeded
                )
                if limitExceeded { return bytes.count }
            }
            guard isJavaScriptIdentifierStart(byte) else {
                previousSignificantByte = byte
                if (byte == 0x2B || byte == 0x2D),
                   index + 1 < bytes.count,
                   bytes[index + 1] == byte {
                    // Prefix ++/-- still expects an operand; postfix ++/--
                    // leaves a complete expression. Preserve the prior state.
                    index += 2
                    continue
                }
                switch byte {
                case 0x30...0x39, 0x5D: // number, ]
                    expectsExpression = false
                case 0x2E: // member access or decimal point
                    break
                default:
                    expectsExpression = true
                }
                index += 1
                continue
            }
            let token = javascriptIdentifier(bytes, from: index)
            if previousSignificantByte == 0x2E {
                let mediaExpression: JavaScriptMediaExpression?
                switch token.value {
                case "src":
                    mediaExpression = javaScriptSourceAssignment(
                        bytes,
                        afterMemberName: token.end
                    )
                case "setAttribute", "attr":
                    mediaExpression = javaScriptSetAttributeSource(
                        bytes,
                        afterMemberName: token.end
                    )
                default:
                    mediaExpression = nil
                }
                if let mediaExpression {
                    recordJavaScriptMediaExpression(
                        mediaExpression,
                        kind: .source,
                        requiresMediaPathHint: true,
                        limit: limit,
                        mediaReferences: &mediaReferences,
                        hasOpaqueOrDynamicMediaReferences: &hasOpaqueOrDynamicMediaReferences,
                        scannedReferenceCount: &scannedReferenceCount,
                        limitExceeded: &limitExceeded
                    )
                    if limitExceeded { return bytes.count }
                }
                // Identifiers after `.` or `?.` are member names, even when
                // their spelling is a JavaScript keyword such as `catch` or
                // `return`. They must not open control-flow lexical context.
                previousSignificantByte = bytes[token.end - 1]
                index = token.end
                expectsExpression = false
                pendingControlHeader = false
                pendingControlBody = false
                continue
            }
            if token.value == "src",
               let mediaExpression = javaScriptObjectSourceProperty(
                   bytes,
                   afterPropertyName: token.end
               ) {
                recordJavaScriptMediaExpression(
                    mediaExpression,
                    kind: .source,
                    requiresMediaPathHint: true,
                    limit: limit,
                    mediaReferences: &mediaReferences,
                    hasOpaqueOrDynamicMediaReferences: &hasOpaqueOrDynamicMediaReferences,
                    scannedReferenceCount: &scannedReferenceCount,
                    limitExceeded: &limitExceeded
                )
                if limitExceeded { return bytes.count }
            }
            if token.value == "new",
               let mediaExpression = javaScriptNewAudioSource(
                   bytes,
                   afterNewKeyword: token.end
               ) {
                recordJavaScriptMediaExpression(
                    mediaExpression,
                    kind: .audio,
                    requiresMediaPathHint: false,
                    limit: limit,
                    mediaReferences: &mediaReferences,
                    hasOpaqueOrDynamicMediaReferences: &hasOpaqueOrDynamicMediaReferences,
                    scannedReferenceCount: &scannedReferenceCount,
                    limitExceeded: &limitExceeded
                )
                if limitExceeded { return bytes.count }
            }
            let parsed: (reference: String?, end: Int)?
            switch token.value {
            case "import":
                parsed = javaScriptImportReference(bytes, afterKeyword: token.end)
            case "export":
                parsed = javaScriptExportReference(bytes, afterKeyword: token.end)
            default:
                parsed = nil
            }
            guard let parsed else {
                previousSignificantByte = bytes[token.end - 1]
                index = token.end
                expectsExpression = javaScriptKeywordExpectsExpression(after: token.value)
                pendingControlHeader = isJavaScriptControlHeaderKeyword(token.value)
                pendingControlBody = isJavaScriptStatementBodyKeyword(token.value)
                continue
            }
            index = parsed.reference == nil
                ? token.end
                : max(parsed.end, token.end)
            previousSignificantByte = index > 0 ? bytes[index - 1] : nil
            if let reference = parsed.reference {
                references.append(reference)
                scannedReferenceCount += 1
                expectsExpression = false
                if scannedReferenceCount > limit {
                    limitExceeded = true
                    return bytes.count
                }
            } else {
                expectsExpression = javaScriptKeywordExpectsExpression(after: token.value)
                pendingControlHeader = isJavaScriptControlHeaderKeyword(token.value)
                pendingControlBody = isJavaScriptStatementBodyKeyword(token.value)
            }
        }
        return index
    }

    private func recordJavaScriptMediaExpression(
        _ expression: JavaScriptMediaExpression,
        kind: WebMediaElementKind,
        requiresMediaPathHint: Bool,
        limit: Int,
        mediaReferences: inout [JavaScriptMediaReference],
        hasOpaqueOrDynamicMediaReferences: inout Bool,
        scannedReferenceCount: inout Int,
        limitExceeded: inout Bool
    ) {
        scannedReferenceCount += 1
        guard scannedReferenceCount <= limit else {
            limitExceeded = true
            return
        }
        switch expression {
        case .literal(let reference):
            mediaReferences.append(
                JavaScriptMediaReference(
                    kind: kind,
                    reference: reference,
                    requiresMediaPathHint: requiresMediaPathHint
                )
            )
        case .opaque:
            hasOpaqueOrDynamicMediaReferences = true
        }
    }

    private func javaScriptNewAudioSource(
        _ bytes: [UInt8],
        afterNewKeyword start: Int
    ) -> JavaScriptMediaExpression? {
        var cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count, isJavaScriptIdentifierStart(bytes[cursor]) else {
            return nil
        }
        let constructor = javascriptIdentifier(bytes, from: cursor)
        guard constructor.value == "Audio" else { return nil }
        cursor = indexAfterJavaScriptTrivia(bytes, from: constructor.end) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] == 0x28 else { return nil }
        cursor = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] != 0x29 else { return nil }
        if let literal = javaScriptString(bytes, from: cursor) {
            let afterLiteral = indexAfterJavaScriptTrivia(bytes, from: literal.end) ?? bytes.count
            guard afterLiteral < bytes.count,
                  bytes[afterLiteral] == 0x29 || bytes[afterLiteral] == 0x2C else {
                return .opaque
            }
            return .literal(literal.value)
        }
        return .opaque
    }

    private func javaScriptSourceAssignment(
        _ bytes: [UInt8],
        afterMemberName start: Int
    ) -> JavaScriptMediaExpression? {
        let cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] == 0x3D else { return nil }
        if cursor + 1 < bytes.count,
           bytes[cursor + 1] == 0x3D || bytes[cursor + 1] == 0x3E {
            return nil
        }
        return javaScriptMediaValue(bytes, from: cursor + 1)
    }

    private func javaScriptBracketSourceAssignment(
        _ bytes: [UInt8],
        from start: Int
    ) -> JavaScriptMediaExpression? {
        var cursor = indexAfterJavaScriptTrivia(bytes, from: start + 1) ?? bytes.count
        guard let property = javaScriptString(bytes, from: cursor),
              property.value.lowercased() == "src" else { return nil }
        cursor = indexAfterJavaScriptTrivia(bytes, from: property.end) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] == 0x5D else { return nil }
        cursor = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] == 0x3D else { return nil }
        if cursor + 1 < bytes.count,
           bytes[cursor + 1] == 0x3D || bytes[cursor + 1] == 0x3E {
            return nil
        }
        return javaScriptMediaValue(bytes, from: cursor + 1)
    }

    private func javaScriptObjectSourceProperty(
        _ bytes: [UInt8],
        afterPropertyName start: Int
    ) -> JavaScriptMediaExpression? {
        let cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] == 0x3A else { return nil }
        return javaScriptMediaValue(bytes, from: cursor + 1)
    }

    private func javaScriptQuotedObjectSourceProperty(
        _ bytes: [UInt8],
        from start: Int
    ) -> JavaScriptMediaExpression? {
        guard let property = javaScriptString(bytes, from: start),
              property.value.lowercased() == "src" else { return nil }
        return javaScriptObjectSourceProperty(
            bytes,
            afterPropertyName: property.end
        )
    }

    private func javaScriptMediaValue(
        _ bytes: [UInt8],
        from start: Int
    ) -> JavaScriptMediaExpression {
        let cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count else { return .opaque }
        guard let literal = javaScriptString(bytes, from: cursor) else {
            return .opaque
        }
        let afterLiteral = indexAfterJavaScriptTrivia(bytes, from: literal.end)
            ?? bytes.count
        guard afterLiteral == bytes.count
                || [UInt8(0x3B), 0x2C, 0x29, 0x5D, 0x7D].contains(bytes[afterLiteral]) else {
            return .opaque
        }
        return .literal(literal.value)
    }

    private func javaScriptSetAttributeSource(
        _ bytes: [UInt8],
        afterMemberName start: Int
    ) -> JavaScriptMediaExpression? {
        var cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] == 0x28 else { return nil }
        cursor = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
        guard let attributeName = javaScriptString(bytes, from: cursor),
              attributeName.value.lowercased() == "src" else {
            return nil
        }
        cursor = indexAfterJavaScriptTrivia(bytes, from: attributeName.end) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] == 0x2C else { return .opaque }
        return javaScriptMediaValue(bytes, from: cursor + 1)
    }

    private func javaScriptKeywordExpectsExpression(after token: String) -> Bool {
        [
            "await", "case", "default", "delete", "do", "else", "export",
            "extends", "in", "instanceof", "new", "of", "return", "throw",
            "typeof", "void", "yield"
        ].contains(token)
    }

    private func isJavaScriptControlHeaderKeyword(_ token: String) -> Bool {
        ["catch", "for", "if", "switch", "while", "with"].contains(token)
    }

    private func isJavaScriptStatementBodyKeyword(_ token: String) -> Bool {
        ["catch", "do", "else", "finally", "try"].contains(token)
    }

    private func scanJavaScriptTemplate(
        _ bytes: [UInt8],
        from start: Int,
        nestingDepth: Int,
        limit: Int,
        references: inout [String],
        mediaReferences: inout [JavaScriptMediaReference],
        hasOpaqueOrDynamicMediaReferences: inout Bool,
        scannedReferenceCount: inout Int,
        limitExceeded: inout Bool
    ) -> Int {
        guard nestingDepth <= Self.maximumJavaScriptNestingDepth else {
            limitExceeded = true
            return bytes.count
        }
        var cursor = start + 1
        while cursor < bytes.count, !limitExceeded {
            if bytes[cursor] == 0x5C {
                cursor = min(cursor + 2, bytes.count)
                continue
            }
            if bytes[cursor] == 0x60 {
                return cursor + 1
            }
            if bytes[cursor] == 0x24,
               cursor + 1 < bytes.count,
               bytes[cursor + 1] == 0x7B {
                cursor = scanJavaScript(
                    bytes,
                    from: cursor + 2,
                    stopAtClosingBrace: true,
                    nestingDepth: nestingDepth,
                    limit: limit,
                    references: &references,
                    mediaReferences: &mediaReferences,
                    hasOpaqueOrDynamicMediaReferences: &hasOpaqueOrDynamicMediaReferences,
                    scannedReferenceCount: &scannedReferenceCount,
                    limitExceeded: &limitExceeded
                )
                continue
            }
            cursor += 1
        }
        return cursor
    }

    private func javaScriptImportReference(
        _ bytes: [UInt8],
        afterKeyword start: Int
    ) -> (reference: String?, end: Int) {
        let cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count else { return (nil, cursor) }
        if bytes[cursor] == 0x2E { // import.meta
            return (nil, cursor + 1)
        }
        if bytes[cursor] == 0x28 { // import("literal")
            let literalStart = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
            guard let literal = javaScriptString(bytes, from: literalStart) else {
                return (nil, max(literalStart, cursor + 1))
            }
            let afterLiteral = indexAfterJavaScriptTrivia(bytes, from: literal.end) ?? bytes.count
            guard afterLiteral < bytes.count,
                  bytes[afterLiteral] == 0x29 || bytes[afterLiteral] == 0x2C else {
                return (nil, afterLiteral)
            }
            return (literal.value, afterLiteral + 1)
        }
        if let literal = javaScriptString(bytes, from: cursor) {
            return (literal.value, literal.end)
        }
        return javaScriptFromReference(bytes, afterKeyword: cursor)
    }

    private func javaScriptExportReference(
        _ bytes: [UInt8],
        afterKeyword start: Int
    ) -> (reference: String?, end: Int) {
        var cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count else { return (nil, cursor) }

        if bytes[cursor] == 0x2A { // export * [as name] from "module"
            cursor = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
            if cursor < bytes.count, isJavaScriptIdentifierStart(bytes[cursor]) {
                let token = javascriptIdentifier(bytes, from: cursor)
                if token.value == "as" {
                    cursor = indexAfterJavaScriptTrivia(bytes, from: token.end) ?? bytes.count
                    guard cursor < bytes.count,
                          isJavaScriptIdentifierStart(bytes[cursor]) else {
                        return (nil, cursor)
                    }
                    cursor = javascriptIdentifier(bytes, from: cursor).end
                }
            }
            return javaScriptModuleSpecifier(bytes, fromKeywordAt: cursor)
        }

        guard bytes[cursor] == 0x7B else {
            // `export default`, declarations, objects, and class bodies are
            // executable JavaScript. Leave them to the outer lexer so nested
            // dynamic imports remain visible.
            return (nil, start)
        }
        var depth = 1
        cursor += 1
        while cursor < bytes.count, depth > 0 {
            cursor = indexAfterJavaScriptTrivia(bytes, from: cursor) ?? bytes.count
            guard cursor < bytes.count else { break }
            if bytes[cursor] == 0x22 || bytes[cursor] == 0x27 {
                cursor = indexAfterQuotedLiteral(bytes, from: cursor)
            } else if bytes[cursor] == 0x7B {
                depth += 1
                cursor += 1
            } else if bytes[cursor] == 0x7D {
                depth -= 1
                cursor += 1
            } else {
                cursor += 1
            }
        }
        guard depth == 0 else { return (nil, cursor) }
        return javaScriptModuleSpecifier(bytes, fromKeywordAt: cursor)
    }

    private func javaScriptModuleSpecifier(
        _ bytes: [UInt8],
        fromKeywordAt start: Int
    ) -> (reference: String?, end: Int) {
        let cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count, isJavaScriptIdentifierStart(bytes[cursor]) else {
            return (nil, cursor)
        }
        let token = javascriptIdentifier(bytes, from: cursor)
        guard token.value == "from" else { return (nil, cursor) }
        let literalStart = indexAfterJavaScriptTrivia(bytes, from: token.end) ?? bytes.count
        guard let literal = javaScriptString(bytes, from: literalStart) else {
            return (nil, literalStart)
        }
        return (literal.value, literal.end)
    }

    private func javaScriptFromReference(
        _ bytes: [UInt8],
        afterKeyword start: Int
    ) -> (reference: String?, end: Int) {
        var cursor = start
        var delimiterDepth = 0
        while cursor < bytes.count {
            cursor = indexAfterJavaScriptTrivia(bytes, from: cursor) ?? bytes.count
            guard cursor < bytes.count else { break }
            let byte = bytes[cursor]
            if byte == 0x3B, delimiterDepth == 0 { // ;
                return (nil, cursor + 1)
            }
            if byte == 0x22 || byte == 0x27 {
                cursor = indexAfterQuotedLiteral(bytes, from: cursor)
                continue
            }
            if byte == 0x60 {
                cursor = indexAfterTemplateLiteral(bytes, from: cursor)
                continue
            }
            if [UInt8(0x28), 0x5B, 0x7B].contains(byte) {
                delimiterDepth += 1
                cursor += 1
                continue
            }
            if [UInt8(0x29), 0x5D, 0x7D].contains(byte) {
                delimiterDepth = max(0, delimiterDepth - 1)
                cursor += 1
                continue
            }
            if isJavaScriptIdentifierStart(byte) {
                let token = javascriptIdentifier(bytes, from: cursor)
                if token.value == "from", delimiterDepth == 0 {
                    let literalStart = indexAfterJavaScriptTrivia(bytes, from: token.end) ?? bytes.count
                    guard let literal = javaScriptString(bytes, from: literalStart) else {
                        return (nil, literalStart)
                    }
                    return (literal.value, literal.end)
                }
                if (token.value == "import" || token.value == "export"),
                   token.end != start,
                   delimiterDepth == 0 {
                    return (nil, cursor)
                }
                cursor = token.end
                continue
            }
            cursor += 1
        }
        return (nil, cursor)
    }

    private func stylesheetDependencies(in source: String, limit: Int) -> DependencyScanResult {
        let bytes = Array(source.utf8)
        var references = [String]()
        var index = 0
        while index < bytes.count {
            if hasASCIIPrefix(bytes, at: index, literal: "/*") {
                index = indexAfterASCIISequence(bytes, from: index + 2, literal: "*/") ?? bytes.count
                continue
            }
            let byte = bytes[index]
            if byte == 0x22 || byte == 0x27 {
                index = indexAfterQuotedLiteral(bytes, from: index)
                continue
            }
            guard byte == 0x40,
                  hasASCIIPrefix(bytes, at: index + 1, literal: "import", caseInsensitive: true) else {
                index += 1
                continue
            }
            let boundary = index + 1 + "import".utf8.count
            guard boundary >= bytes.count || !isCSSIdentifierByte(bytes[boundary]) else {
                index = boundary
                continue
            }
            let parsed = cssImportReference(bytes, afterKeyword: boundary)
            index = max(parsed.end, boundary)
            if let reference = parsed.reference {
                references.append(reference)
                if references.count > limit {
                    return DependencyScanResult(
                        references: Array(references.prefix(limit)),
                        limitExceeded: true
                    )
                }
            }
        }
        return DependencyScanResult(references: references, limitExceeded: false)
    }

    private func cssImportReference(
        _ bytes: [UInt8],
        afterKeyword start: Int
    ) -> (reference: String?, end: Int) {
        var cursor = indexAfterCSSTrivia(bytes, from: start)
        guard cursor < bytes.count else { return (nil, cursor) }
        if let literal = javaScriptString(bytes, from: cursor) {
            return (literal.value, literal.end)
        }
        guard hasASCIIPrefix(bytes, at: cursor, literal: "url", caseInsensitive: true) else {
            return (nil, cursor + 1)
        }
        cursor += 3
        cursor = indexAfterCSSTrivia(bytes, from: cursor)
        guard cursor < bytes.count, bytes[cursor] == 0x28 else { return (nil, cursor) }
        cursor = indexAfterCSSTrivia(bytes, from: cursor + 1)
        if let literal = javaScriptString(bytes, from: cursor) {
            return (literal.value, literal.end)
        }
        let valueStart = cursor
        while cursor < bytes.count,
              bytes[cursor] != 0x29,
              !isHTMLWhitespace(bytes[cursor]) {
            cursor += 1
        }
        guard cursor > valueStart else { return (nil, cursor + 1) }
        return (
            String(decoding: bytes[valueStart..<cursor], as: UTF8.self),
            cursor
        )
    }

    private func indexAfterJavaScriptTrivia(_ bytes: [UInt8], from start: Int) -> Int? {
        var cursor = start
        while cursor < bytes.count {
            if isJavaScriptWhitespace(bytes[cursor]) {
                cursor += 1
                continue
            }
            if hasASCIIPrefix(bytes, at: cursor, literal: "//") {
                cursor += 2
                while cursor < bytes.count, bytes[cursor] != 0x0A, bytes[cursor] != 0x0D {
                    cursor += 1
                }
                continue
            }
            if hasASCIIPrefix(bytes, at: cursor, literal: "/*") {
                cursor = indexAfterASCIISequence(bytes, from: cursor + 2, literal: "*/") ?? bytes.count
                continue
            }
            break
        }
        return cursor
    }

    private func indexAfterCSSTrivia(_ bytes: [UInt8], from start: Int) -> Int {
        var cursor = start
        while cursor < bytes.count {
            if isJavaScriptWhitespace(bytes[cursor]) {
                cursor += 1
                continue
            }
            if hasASCIIPrefix(bytes, at: cursor, literal: "/*") {
                cursor = indexAfterASCIISequence(bytes, from: cursor + 2, literal: "*/") ?? bytes.count
                continue
            }
            break
        }
        return cursor
    }

    private func indexAfterQuotedLiteral(_ bytes: [UInt8], from start: Int) -> Int {
        guard start < bytes.count, bytes[start] == 0x22 || bytes[start] == 0x27 else {
            return min(start + 1, bytes.count)
        }
        let quote = bytes[start]
        var cursor = start + 1
        while cursor < bytes.count {
            if bytes[cursor] == 0x5C {
                cursor = min(cursor + 2, bytes.count)
            } else if bytes[cursor] == quote {
                return cursor + 1
            } else {
                cursor += 1
            }
        }
        return bytes.count
    }

    /// Consumes a JavaScript RegExp literal without interpreting quotes,
    /// braces, or import-shaped text inside it as executable source. The
    /// caller decides whether `/` may begin a literal from expression context;
    /// comments have already been removed as trivia.
    private func indexAfterJavaScriptRegularExpression(
        _ bytes: [UInt8],
        from start: Int
    ) -> Int? {
        guard start < bytes.count, bytes[start] == 0x2F,
              start + 1 < bytes.count,
              bytes[start + 1] != 0x2F,
              bytes[start + 1] != 0x2A else {
            return nil
        }
        var cursor = start + 1
        var isInsideCharacterClass = false
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte == 0x0A || byte == 0x0D { return nil }
            if byte == 0x5C { // escaped atom, slash, or character-class byte
                guard cursor + 1 < bytes.count,
                      bytes[cursor + 1] != 0x0A,
                      bytes[cursor + 1] != 0x0D else {
                    return nil
                }
                cursor += 2
                continue
            }
            if byte == 0x5B, !isInsideCharacterClass { // [
                isInsideCharacterClass = true
                cursor += 1
                continue
            }
            if byte == 0x5D, isInsideCharacterClass { // ]
                isInsideCharacterClass = false
                cursor += 1
                continue
            }
            if byte == 0x2F, !isInsideCharacterClass {
                cursor += 1
                while cursor < bytes.count,
                      isJavaScriptIdentifierByte(bytes[cursor]) {
                    cursor += 1
                }
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private func indexAfterTemplateLiteral(_ bytes: [UInt8], from start: Int) -> Int {
        guard start < bytes.count, bytes[start] == 0x60 else {
            return min(start + 1, bytes.count)
        }
        var cursor = start + 1
        while cursor < bytes.count {
            if bytes[cursor] == 0x5C {
                cursor = min(cursor + 2, bytes.count)
            } else if bytes[cursor] == 0x60 {
                return cursor + 1
            } else {
                cursor += 1
            }
        }
        return bytes.count
    }

    private func javaScriptString(
        _ bytes: [UInt8],
        from start: Int
    ) -> (value: String, end: Int)? {
        guard start < bytes.count, bytes[start] == 0x22 || bytes[start] == 0x27 else {
            return nil
        }
        let quote = bytes[start]
        var cursor = start + 1
        var segmentStart = cursor
        var value = ""
        func decodedSegment(_ range: Range<Int>) -> String {
            String(decoding: bytes[range], as: UTF8.self)
        }
        while cursor < bytes.count {
            if bytes[cursor] == quote {
                value += decodedSegment(segmentStart..<cursor)
                return (value, cursor + 1)
            }
            guard bytes[cursor] == 0x5C else {
                cursor += 1
                continue
            }
            value += decodedSegment(segmentStart..<cursor)
            cursor += 1
            guard cursor < bytes.count else { return nil }
            let escaped = bytes[cursor]
            switch escaped {
            case 0x0A:
                cursor += 1
            case 0x0D:
                cursor += 1
                if cursor < bytes.count, bytes[cursor] == 0x0A { cursor += 1 }
            case 0x62: value.append("\u{08}"); cursor += 1
            case 0x66: value.append("\u{0C}"); cursor += 1
            case 0x6E: value.append("\n"); cursor += 1
            case 0x72: value.append("\r"); cursor += 1
            case 0x74: value.append("\t"); cursor += 1
            case 0x76: value.append("\u{0B}"); cursor += 1
            case 0x78:
                guard let scalar = hexadecimalScalar(bytes, from: cursor + 1, count: 2) else { return nil }
                value.unicodeScalars.append(scalar.value)
                cursor = scalar.end
            case 0x75:
                guard let scalar = unicodeEscapeScalar(bytes, from: cursor + 1) else { return nil }
                value.unicodeScalars.append(scalar.value)
                cursor = scalar.end
            default:
                value.append(Character(UnicodeScalar(escaped)))
                cursor += 1
            }
            segmentStart = cursor
        }
        return nil
    }

    private func unicodeEscapeScalar(
        _ bytes: [UInt8],
        from start: Int
    ) -> (value: UnicodeScalar, end: Int)? {
        if start < bytes.count, bytes[start] == 0x7B {
            var cursor = start + 1
            let digitsStart = cursor
            while cursor < bytes.count, bytes[cursor] != 0x7D { cursor += 1 }
            guard cursor < bytes.count,
                  cursor > digitsStart,
                  cursor - digitsStart <= 6,
                  let value = hexadecimalValue(bytes[digitsStart..<cursor]),
                  let scalar = UnicodeScalar(value) else { return nil }
            return (scalar, cursor + 1)
        }
        return hexadecimalScalar(bytes, from: start, count: 4)
    }

    private func hexadecimalScalar(
        _ bytes: [UInt8],
        from start: Int,
        count: Int
    ) -> (value: UnicodeScalar, end: Int)? {
        let end = start + count
        guard start >= 0, end <= bytes.count,
              let value = hexadecimalValue(bytes[start..<end]),
              let scalar = UnicodeScalar(value) else { return nil }
        return (scalar, end)
    }

    private func hexadecimalValue(_ bytes: ArraySlice<UInt8>) -> UInt32? {
        var value: UInt32 = 0
        for byte in bytes {
            let digit: UInt32
            switch byte {
            case 0x30...0x39: digit = UInt32(byte - 0x30)
            case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
            default: return nil
            }
            value = value * 16 + digit
        }
        return value
    }

    private func javascriptIdentifier(
        _ bytes: [UInt8],
        from start: Int
    ) -> (value: String, end: Int) {
        var cursor = start
        while cursor < bytes.count, isJavaScriptIdentifierByte(bytes[cursor]) { cursor += 1 }
        return (String(decoding: bytes[start..<cursor], as: UTF8.self), cursor)
    }

    private func isJavaScriptIdentifierStart(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
            || byte == 0x24
            || byte == 0x5F
    }

    private func isJavaScriptIdentifierByte(_ byte: UInt8) -> Bool {
        isJavaScriptIdentifierStart(byte) || (0x30...0x39).contains(byte)
    }

    private func isCSSIdentifierByte(_ byte: UInt8) -> Bool {
        isJavaScriptIdentifierByte(byte) || byte == 0x2D
    }

    private func isJavaScriptWhitespace(_ byte: UInt8) -> Bool {
        isHTMLWhitespace(byte) || byte == 0x0B
    }

    private func documentDependencyElements(
        in source: String,
        limit: Int
    ) -> DocumentDependencyScanResult {
        let bytes = Array(source.utf8)
        let dependencyNames: Set<String> = [
            "base", "script", "link", "style", "video", "audio", "source", "iframe"
        ]
        let rawTextNames: Set<String> = [
            "script", "style", "textarea", "title", "xmp", "iframe",
            "noembed", "noframes", "noscript", "plaintext"
        ]
        var elements = [DocumentDependencyElement]()
        var index = 0
        var templateDepth = 0
        var mediaContainers = [DocumentMediaContainer]()
        var nextMediaGroupID = 0

        while index < bytes.count {
            guard bytes[index] == 0x3C else {
                index += 1
                continue
            }
            if hasASCIIPrefix(bytes, at: index, literal: "<!--") {
                index = indexAfterASCIISequence(bytes, from: index + 4, literal: "-->")
                    ?? bytes.count
                continue
            }

            let tagStart = index
            var cursor = index + 1
            var isClosing = false
            if cursor < bytes.count, bytes[cursor] == 0x2F {
                isClosing = true
                cursor += 1
            }
            let nameStart = cursor
            while cursor < bytes.count, isTagNameByte(bytes[cursor]) {
                cursor += 1
            }
            guard cursor > nameStart else {
                index += 1
                continue
            }
            let name = asciiLowercased(bytes[nameStart..<cursor])
            guard let tagEnd = endOfTag(bytes, from: cursor) else { break }
            index = tagEnd + 1

            if isClosing {
                if name == "template", templateDepth > 0 {
                    templateDepth -= 1
                } else if templateDepth == 0,
                          let mediaKind = WebMediaElementKind(rawValue: name),
                          mediaKind != .source,
                          let containerIndex = mediaContainers.lastIndex(where: {
                              $0.kind == mediaKind
                          }) {
                    mediaContainers.removeSubrange(containerIndex...)
                }
                continue
            }
            if name == "template" {
                templateDepth += 1
                continue
            }
            var rawText: String?
            if rawTextNames.contains(name) {
                guard name != "plaintext" else { break }
                if let closingTag = closingTagBounds(
                    bytes,
                    name: name,
                    from: index
                ) {
                    if templateDepth == 0, name == "script" || name == "style" {
                        rawText = String(
                            decoding: bytes[index..<closingTag.contentEnd],
                            as: UTF8.self
                        )
                    }
                    index = closingTag.afterClosingTag
                } else if templateDepth == 0, name == "script" || name == "style" {
                    // HTML raw-text elements consume through EOF when their
                    // closing tag is absent. Analyze executable script/style
                    // content rather than silently presenting it as Full.
                    rawText = String(decoding: bytes[index..<bytes.count], as: UTF8.self)
                    index = bytes.count
                } else if templateDepth == 0, name == "iframe" {
                    // An unclosed iframe still loads its `src`; only its fallback
                    // text consumes the remainder of the parent document.
                    index = bytes.count
                } else {
                    // Inert raw text (for example textarea or template
                    // contents) also consumes through EOF but must not be
                    // interpreted as document dependencies.
                    break
                }
            }
            if templateDepth == 0, dependencyNames.contains(name) {
                guard elements.count < limit else {
                    return DocumentDependencyScanResult(
                        elements: elements,
                        limitExceeded: true
                    )
                }
                let declaredMediaKind = WebMediaElementKind(rawValue: name)
                let openingTag = String(decoding: bytes[tagStart...tagEnd], as: UTF8.self)
                let activeSourceContainer = mediaContainers.last.flatMap {
                    $0.hasAuthoredSource ? nil : $0
                }
                let mediaGroupID: Int?
                if declaredMediaKind == .source {
                    mediaGroupID = activeSourceContainer?.groupID
                } else if declaredMediaKind != nil {
                    mediaGroupID = nextMediaGroupID
                    nextMediaGroupID += 1
                } else {
                    mediaGroupID = nil
                }
                let sourceMediaQuery = attribute("media", in: openingTag)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let localMediaCanProveFallback = declaredMediaKind != .source
                    || sourceMediaQuery.isEmpty
                elements.append(
                    DocumentDependencyElement(
                        name: name,
                        openingTag: openingTag,
                        rawText: rawText,
                        mediaContainer: name == WebMediaElementKind.source.rawValue
                            ? activeSourceContainer?.kind
                            : nil,
                        mediaGroupID: mediaGroupID,
                        // A non-empty media query can make this source
                        // ineligible at the current display size. Keep the
                        // local reference available for runtime preparation,
                        // but do not use it as proof that a broken sibling has
                        // a playable fallback.
                        localMediaCanProveFallback: localMediaCanProveFallback
                    )
                )
                if let mediaKind = declaredMediaKind,
                   mediaKind != .source,
                   let mediaGroupID,
                   !isSelfClosingTag(bytes[tagStart...tagEnd]) {
                    mediaContainers.append(
                        DocumentMediaContainer(
                            kind: mediaKind,
                            groupID: mediaGroupID,
                            hasAuthoredSource: attribute("src", in: openingTag) != nil
                        )
                    )
                }
            }
        }
        return DocumentDependencyScanResult(elements: elements, limitExceeded: false)
    }

    private func documentBase(reference: String, entrypoint: URL) -> DocumentBase {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("{{"), !trimmed.contains("${") else {
            return .resolved(entrypoint)
        }
        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        guard let resolved = URL(string: normalized, relativeTo: entrypoint)?.absoluteURL else {
            return .invalid
        }
        return .resolved(resolved)
    }

    private func isSelfClosingTag(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard var index = bytes.indices.last else { return false }
        if bytes[index] == 0x3E, index > bytes.startIndex {
            index = bytes.index(before: index)
        }
        while index > bytes.startIndex, isHTMLWhitespace(bytes[index]) {
            index = bytes.index(before: index)
        }
        return bytes[index] == 0x2F
    }

    private func isTagNameByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
            || byte == 0x2D
            || byte == 0x3A
            || byte == 0x5F
    }

    private func asciiLowercased(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.map { byte in
            (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
        }, as: UTF8.self)
    }

    private func endOfTag(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        var quote: UInt8?
        while index < bytes.count {
            let byte = bytes[index]
            if let activeQuote = quote {
                if byte == activeQuote { quote = nil }
            } else if byte == 0x22 || byte == 0x27 {
                quote = byte
            } else if byte == 0x3E {
                return index
            }
            index += 1
        }
        return nil
    }

    private func closingTagBounds(
        _ bytes: [UInt8],
        name: String,
        from start: Int
    ) -> (contentEnd: Int, afterClosingTag: Int)? {
        let closingPrefix = "</\(name)"
        var index = start
        while index < bytes.count {
            guard bytes[index] == 0x3C,
                  hasASCIIPrefix(bytes, at: index, literal: closingPrefix, caseInsensitive: true) else {
                index += 1
                continue
            }
            let boundary = index + closingPrefix.utf8.count
            guard boundary >= bytes.count
                    || bytes[boundary] == 0x3E
                    || bytes[boundary] == 0x2F
                    || isHTMLWhitespace(bytes[boundary]) else {
                index += 1
                continue
            }
            guard let tagEnd = endOfTag(bytes, from: boundary) else { return nil }
            return (index, tagEnd + 1)
        }
        return nil
    }

    private func hasASCIIPrefix(
        _ bytes: [UInt8],
        at start: Int,
        literal: String,
        caseInsensitive: Bool = false
    ) -> Bool {
        let expected = Array(literal.utf8)
        guard start >= 0, start + expected.count <= bytes.count else { return false }
        for offset in expected.indices {
            let actual = bytes[start + offset]
            if caseInsensitive {
                let foldedActual = (0x41...0x5A).contains(actual) ? actual + 0x20 : actual
                let wanted = expected[offset]
                let foldedWanted = (0x41...0x5A).contains(wanted) ? wanted + 0x20 : wanted
                guard foldedActual == foldedWanted else { return false }
            } else if actual != expected[offset] {
                return false
            }
        }
        return true
    }

    private func indexAfterASCIISequence(
        _ bytes: [UInt8],
        from start: Int,
        literal: String
    ) -> Int? {
        var index = start
        while index < bytes.count {
            if hasASCIIPrefix(bytes, at: index, literal: literal) {
                return index + literal.utf8.count
            }
            index += 1
        }
        return nil
    }

    private func isHTMLWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
    }

    private func decodeHTMLCharacterReferences(_ source: String) -> String {
        let bytes = Array(source.utf8)
        var decoded = [UInt8]()
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x26 else {
                decoded.append(bytes[index])
                index += 1
                continue
            }
            // HTML references accepted below are at most 12 bytes including
            // the leading ampersand. Searching the entire remaining attribute
            // for every malformed `&` turns an otherwise bounded 8 MiB input
            // into quadratic work. Scan only the constant-size entity window.
            let maximumEntityEnd = min(bytes.count - 1, index + 12)
            var semicolon: Int?
            if index < maximumEntityEnd {
                for candidate in (index + 1)...maximumEntityEnd
                where bytes[candidate] == 0x3B {
                    semicolon = candidate
                    break
                }
            }
            guard let semicolon else {
                decoded.append(bytes[index])
                index += 1
                continue
            }
            let entity = String(decoding: bytes[(index + 1)..<semicolon], as: UTF8.self)
            let scalar: UnicodeScalar?
            switch entity {
            case "amp": scalar = "&"
            case "apos": scalar = "'"
            case "gt": scalar = ">"
            case "lt": scalar = "<"
            case "quot": scalar = "\""
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init)
                } else if entity.hasPrefix("#") {
                    scalar = UInt32(entity.dropFirst(), radix: 10).flatMap(UnicodeScalar.init)
                } else {
                    scalar = nil
                }
            }
            guard let scalar else {
                decoded.append(bytes[index])
                index += 1
                continue
            }
            decoded.append(contentsOf: String(scalar).utf8)
            index = semicolon + 1
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    private func attribute(_ name: String, in tag: String) -> String? {
        let requestedName = name.lowercased()
        let bytes = Array(tag.utf8)
        var index = 0
        guard index < bytes.count, bytes[index] == 0x3C else { return nil }
        index += 1
        if index < bytes.count, bytes[index] == 0x2F { index += 1 }
        while index < bytes.count, isTagNameByte(bytes[index]) { index += 1 }

        while index < bytes.count {
            while index < bytes.count,
                  isHTMLWhitespace(bytes[index]) || bytes[index] == 0x2F {
                index += 1
            }
            guard index < bytes.count, bytes[index] != 0x3E else { break }
            let attributeStart = index
            while index < bytes.count,
                  !isHTMLWhitespace(bytes[index]),
                  bytes[index] != 0x3D,
                  bytes[index] != 0x2F,
                  bytes[index] != 0x3E {
                index += 1
            }
            guard index > attributeStart else {
                index += 1
                continue
            }
            let attributeName = asciiLowercased(bytes[attributeStart..<index])
            while index < bytes.count, isHTMLWhitespace(bytes[index]) { index += 1 }

            var value = ""
            if index < bytes.count, bytes[index] == 0x3D {
                index += 1
                while index < bytes.count, isHTMLWhitespace(bytes[index]) { index += 1 }
                if index < bytes.count, bytes[index] == 0x22 || bytes[index] == 0x27 {
                    let quote = bytes[index]
                    index += 1
                    let valueStart = index
                    while index < bytes.count, bytes[index] != quote { index += 1 }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                    if index < bytes.count { index += 1 }
                } else {
                    let valueStart = index
                    while index < bytes.count,
                          !isHTMLWhitespace(bytes[index]),
                          bytes[index] != 0x3E {
                        index += 1
                    }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                }
            }
            if attributeName == requestedName {
                return decodeHTMLCharacterReferences(value)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func dependencyResolution(
        _ rawReference: String,
        base: DocumentBase,
        context: DependencyReferenceContext,
        root: URL
    ) -> DependencyResolution {
        let trimmed = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.contains("{{"),
              !trimmed.contains("${") else {
            return .ignored
        }
        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        let explicitScheme = URL(string: normalized)?.scheme?.lowercased()
        if explicitScheme == "data" || explicitScheme == "blob" {
            return .ignored
        }
        // The analyzer resolves local projects from file URLs, but playback
        // runs on an HTTP loopback origin. A scheme-relative URL therefore
        // inherits HTTP(S) in WebKit and must be classified as network access
        // before Foundation can reinterpret it as a `file://host/path` URL.
        if normalized.hasPrefix("//") {
            return .externalNetwork
        }
        if explicitScheme == "http" || explicitScheme == "https" {
            return .externalNetwork
        }
        if context == .javaScript,
           explicitScheme == nil,
           !normalized.hasPrefix("./"),
           !normalized.hasPrefix("../"),
           !normalized.hasPrefix("/") {
            // Bare package specifiers require an import map or a package
            // resolver that WKWebView does not expose to this static probe.
            // Treat them as opaque instead of inventing a project-relative file.
            return .ignored
        }
        switch base {
        case .invalid:
            return .missingLocal
        case let .resolved(baseURL):
            guard let candidate = URL(string: normalized, relativeTo: baseURL)?.absoluteURL else {
                return .missingLocal
            }
            if ["http", "https"].contains(candidate.scheme?.lowercased() ?? "") {
                return .externalNetwork
            }
            guard candidate.isFileURL else { return .ignored }
            let standardized = candidate.standardizedFileURL
            let resolved = standardized.resolvingSymlinksInPath()
            guard isInside(resolved, root: root),
                  let values = try? standardized.resourceValues(
                      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ), values.isRegularFile == true, values.isSymbolicLink != true else {
                return .missingLocal
            }
            return .local(canonicalFileURL(resolved))
        }
    }
}
