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
    /// Version 16 re-probes Web reports after import-map parity, private-network
    /// policy, and additional interaction shapes became part of bounded
    /// capability detection.
    /// Version 18 stops claiming Full compatibility while opaque or dynamic
    /// Web media still requires bounded runtime discovery.
    /// Version 19 classifies permitted remote Website/Lively URLs as Limited:
    /// successful navigation cannot prove visual output or callback parity for
    /// content that is unavailable to the bounded static analyzer.
    /// Version 21 routes explicit Scene fonts through the bundled renderer so
    /// native playback cannot claim Full Live while substituting typography.
    /// Version 22 prevents a successful one-frame renderer preflight from
    /// claiming Full Cached when authored particle modules are silently
    /// ignored by the bundled renderer.
    public static let currentProbeVersion = 22

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

/// Reapplies limitations recorded by the Lively staging normalizer every time
/// an asset is probed. Keeping this in project metadata means a network opt-in,
/// media conversion, manifest migration, or later rescan cannot silently turn
/// a missing Lively control into a false Full result.
enum LivelyPropertyCompatibility {
    static let metadataKey = "backgroundEngineLivelyPropertyLimitations"

    private static let folderDropdown = "folderDropdown"
    private static let nativeMediaProperties = "nativeMediaProperties"
    private static let neutralAudioReactive = "neutralAudioReactive"
    private static let unmappedControl = "unmappedControl"

    static func apply(
        to report: CompatibilityReport,
        projectRoot: URL?
    ) -> CompatibilityReport {
        guard let projectRoot,
              let data = WebWallpaperMetadataFileReader.data(
                  at: projectRoot.appending(path: "project.json"),
                  maximumByteCount: WebWallpaperMetadataFileReader.maximumProjectMetadataBytes
              ), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object[metadataKey] as? [String] else {
            return report
        }
        let limitations = Set(raw).intersection([
            folderDropdown,
            nativeMediaProperties,
            neutralAudioReactive,
            unmappedControl,
        ])
        guard !limitations.isEmpty else { return report }

        var warnings = report.warnings
        func appendWarning(_ warning: String) {
            if !warnings.contains(warning) { warnings.append(warning) }
        }
        if limitations.contains(folderDropdown) {
            appendWarning(
                "Lively folder dropdowns accept filtered sandbox copies one file at a time; multi-file add and delete controls are not available yet."
            )
        }
        if limitations.contains(nativeMediaProperties) {
            appendWarning(
                "Lively controls authored for native Video or Image playback are not applied in this version."
            )
        }
        if limitations.contains(neutralAudioReactive) {
            appendWarning(
                "Lively audio-reactive callbacks receive neutral data because system-audio capture is unavailable."
            )
        }
        if limitations.contains(unmappedControl) {
            appendWarning("One or more Lively property controls could not be mapped safely.")
        }
        var required = Set(report.requiredCapabilities)
        var missing = Set(report.missingCapabilities)
        if !limitations.isDisjoint(with: [folderDropdown, nativeMediaProperties, unmappedControl]) {
            required.insert(.interaction)
            missing.insert(.interaction)
        }
        if limitations.contains(neutralAudioReactive) {
            required.insert(.audioReactive)
            missing.insert(.audioReactive)
        }
        return CompatibilityReport(
            level: report.level == .unsupported ? .unsupported : .limited,
            playbackPath: report.playbackPath,
            requiredCapabilities: required.sorted(),
            missingCapabilities: missing.sorted(),
            warnings: warnings,
            diagnosticCode: report.diagnosticCode ?? (
                limitations.contains(nativeMediaProperties)
                    ? "lively_media_properties_limited"
                    : limitations.contains(neutralAudioReactive)
                        ? "web_lively_audio_reactive_limited"
                        : "web_lively_properties_limited"
            ),
            probeVersion: report.probeVersion,
            needsProbe: report.needsProbe
        )
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
            return LivelyPropertyCompatibility.apply(
                to: CompatibilityReport(level: .full, playbackPath: .direct),
                projectRoot: projectRoot ?? entrypoint?.deletingLastPathComponent()
            )
        case .video where status == .needsConversion:
            return LivelyPropertyCompatibility.apply(
                to: CompatibilityReport(
                    level: .full,
                    playbackPath: .convertedVideo,
                    warnings: ["The video will be converted to a local AVFoundation-compatible cache."]
                ),
                projectRoot: projectRoot ?? entrypoint?.deletingLastPathComponent()
            )
        case .image where status == .playable:
            return LivelyPropertyCompatibility.apply(
                to: CompatibilityReport(level: .full, playbackPath: .direct),
                projectRoot: projectRoot ?? entrypoint?.deletingLastPathComponent()
            )
        case .web where status == .playable:
            return LivelyPropertyCompatibility.apply(
                to: analyzeWeb(
                    entrypoint: entrypoint,
                    projectRoot: projectRoot,
                    networkAccessAllowed: networkAccessAllowed
                ),
                projectRoot: projectRoot ?? entrypoint?.deletingLastPathComponent()
            )
        case .scene where status == .playable:
            return analyzeScene(entrypoint: entrypoint, projectRoot: projectRoot)
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
                level: networkAccessAllowed ? .limited : .unsupported,
                playbackPath: networkAccessAllowed ? .webLive : nil,
                requiredCapabilities: [.externalNetwork],
                missingCapabilities: networkAccessAllowed ? [] : [.externalNetwork],
                warnings: networkAccessAllowed
                    ? [
                        "Remote Web content runs live, but its visual output and runtime APIs cannot be verified before playback."
                    ]
                    : ["This website wallpaper requires external network access."],
                diagnosticCode: networkAccessAllowed
                    ? "web_remote_runtime_unverified"
                    : "web_network_access_required"
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
        if let importMapDiagnosticCode = features.importMapDiagnosticCode {
            let warning: String
            switch importMapDiagnosticCode {
            case "web_import_map_too_large":
                warning = "The inline Web import map exceeds the bounded size or entry limit."
            case "web_import_map_unsafe":
                warning = "The inline Web import map contains an unsupported or unsafe mapping."
            default:
                warning = "The inline Web import map is malformed and cannot be applied safely."
            }
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                warnings: [warning],
                diagnosticCode: importMapDiagnosticCode
            )
        }
        if !features.unmappedBareModuleSpecifiers.isEmpty {
            let visible = features.unmappedBareModuleSpecifiers.prefix(5).joined(separator: ", ")
            let remaining = features.unmappedBareModuleSpecifiers.count - min(
                features.unmappedBareModuleSpecifiers.count,
                5
            )
            let suffix = remaining > 0 ? " and \(remaining) more" : ""
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                warnings: ["Bare Web module specifiers have no import-map entry: \(visible)\(suffix)."],
                diagnosticCode: "web_import_map_specifier_unmapped"
            )
        }
        if !features.blockedRemoteDependencies.isEmpty {
            let visible = features.blockedRemoteDependencies.prefix(5).joined(separator: ", ")
            let remaining = features.blockedRemoteDependencies.count - min(
                features.blockedRemoteDependencies.count,
                5
            )
            let suffix = remaining > 0 ? " and \(remaining) more" : ""
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                warnings: [
                    "Required Web resources target local or private network addresses blocked "
                        + "by Background Engine: \(visible)\(suffix)."
                ],
                diagnosticCode: "web_private_network_blocked"
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
            warnings.append(
                "System media metadata, playback state, and hardware information receive "
                    + "bounded neutral unavailable data in v0.2."
            )
        }
        if features.usesInteraction {
            requiredCapabilities.append(.interaction)
            missingCapabilities.append(.interaction)
            warnings.append(
                "Mouse, pointer, touch, and click interaction is unavailable because wallpaper "
                    + "windows ignore input events."
            )
        }
        var webMediaDiagnostics = [String]()
        var runtimePendingDiagnosticCode: String?
        if features.hasOpaqueOrDynamicNetworkReferences {
            requiredCapabilities.append(.externalNetwork)
            if !networkAccessAllowed {
                missingCapabilities.append(.externalNetwork)
            }
            warnings.append(
                "A dynamic Web request target could not be classified statically; external "
                    + "network access remains governed by this wallpaper's permission."
            )
            runtimePendingDiagnosticCode = "web_dynamic_network_runtime_pending"
        }
        if features.hasOpaqueOrDynamicMediaReferences {
            warnings.append(
                "Dynamic Web media candidates will be discovered and prepared within runtime "
                    + "safety limits before playback."
            )
            runtimePendingDiagnosticCode = runtimePendingDiagnosticCode == nil
                ? "web_dynamic_media_runtime_pending"
                : "web_dynamic_runtime_pending"
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
        let integrationCount = [
            features.usesAudioListener,
            features.usesMediaIntegration,
            features.usesInteraction
        ].filter { $0 }.count
        if integrationCount > 1 {
            integrationDiagnosticCode = "web_realtime_integration_limited"
        } else if features.usesAudioListener {
            integrationDiagnosticCode = "web_audio_reactive_limited"
        } else if features.usesMediaIntegration {
            integrationDiagnosticCode = "web_media_integration_limited"
        } else if features.usesInteraction {
            integrationDiagnosticCode = "web_interaction_limited"
        } else {
            integrationDiagnosticCode = nil
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
            level: missingCapabilities.isEmpty
                    && webMediaDiagnostics.isEmpty
                    && !features.hasOpaqueOrDynamicNetworkReferences
                    && !features.hasOpaqueOrDynamicMediaReferences
                ? .full
                : .limited,
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

    private func analyzeScene(
        entrypoint: URL?,
        projectRoot: URL?
    ) -> CompatibilityReport {
        guard let entrypoint else {
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                diagnosticCode: "scene_package_missing"
            )
        }
        let nativePlayable = SceneRenderPlanBuilder().canBuild(url: entrypoint)
        return analyzeScene(
            entrypoint: entrypoint,
            nativePlayable: nativePlayable,
            projectRoot: projectRoot
        )
    }

    /// Classifies Scene capabilities using a native-readiness result supplied
    /// by a shared asynchronous coordinator. This avoids decoding the same
    /// package again during library reprobes and desktop playback.
    public func analyzeScene(
        entrypoint: URL?,
        nativePlayable: Bool
    ) -> CompatibilityReport {
        analyzeScene(
            entrypoint: entrypoint,
            nativePlayable: nativePlayable,
            projectRoot: nil
        )
    }

    func analyzeScene(
        entrypoint: URL?,
        nativePlayable: Bool,
        projectRoot: URL?
    ) -> CompatibilityReport {
        guard let entrypoint else {
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                diagnosticCode: "scene_package_missing"
            )
        }
        guard let analysis = try? SceneRuntimeFeatureAnalyzer().analyzeForCompatibility(
            url: entrypoint,
            projectRoot: projectRoot
        ) else {
            return CompatibilityReport(
                level: .unsupported,
                playbackPath: nil,
                diagnosticCode: "scene_package_unreadable"
            )
        }
        let features = analysis.features
        let rendererParityIssues = analysis.rendererParityIssues
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
        if features.requiresUnrecognizedLayerRuntime || features.hasDependencyAnalysisUncertainty {
            missing.insert(.engineLayer)
        }
        if features.hasFontDependencyUncertainty {
            missing.insert(.engineLayer)
        }
        if features.hasInvalidSoundPlaybackMode {
            missing.insert(.sound)
        }
        if !rendererParityIssues.isEmpty {
            missing.insert(.particle)
        }
        var warnings: [String] = []
        if features.requiresDynamicVisibilityRuntime {
            warnings.append(
                "Dynamic layer visibility uses its stored default in native/audio approximation; "
                    + "user and script changes remain limited."
            )
        }
        if features.hasDependencyAnalysisUncertainty {
            warnings.append(
                "One or more reachable Scene dependencies could not be classified completely; "
                    + "the bundled renderer and engine assets are required."
            )
        } else if features.requiresExternalAssetRuntime {
            warnings.append(
                "The Scene references assets outside its package and requires the selected engine-assets folder."
            )
        }
        if features.hasAudioDependencyUncertainty {
            warnings.append(
                "Audio-reactive or authored-audio requirements could not be ruled out safely."
            )
        }
        if features.hasInvalidSoundPlaybackMode {
            warnings.append(
                "A sound layer has a non-string playbackmode that the bundled renderer may reject; "
                    + "Background Engine will not guess its loop behavior."
            )
        }
        if features.requiresUnrecognizedLayerRuntime {
            warnings.append("The Scene contains an engine layer this build cannot reproduce exactly.")
        }
        if !rendererParityIssues.isEmpty {
            let visible = rendererParityIssues.prefix(5)
                .map(\.userFacingDescription)
                .joined(separator: ", ")
            let remaining = rendererParityIssues.count - min(rendererParityIssues.count, 5)
            let suffix = remaining > 0 ? ", and \(remaining) more" : ""
            warnings.append(
                "The bundled renderer cannot reproduce these authored particle modules exactly: "
                    + "\(visible)\(suffix)."
            )
        }
        if features.hasFontDependencyUncertainty {
            warnings.append(
                "The requested Scene font could not be validated exactly; cached playback may use a fallback."
            )
        } else if features.requiresFontRuntime {
            warnings.append(
                "Explicit Scene fonts are rendered through the bundled renderer to preserve typography."
            )
        }
        if warnings.isEmpty {
            warnings.append(
                missing.isEmpty
                    ? "The Scene requires the bundled renderer and user-provided engine assets."
                    : "The Scene will play from cache, but some live behavior is unavailable."
            )
        }
        let diagnosticCode: String?
        if features.hasInvalidSoundPlaybackMode {
            diagnosticCode = "scene_invalid_playback_mode_limited"
        } else if !rendererParityIssues.isEmpty {
            diagnosticCode = "scene_particle_modules_limited"
        } else if features.hasFontDependencyUncertainty {
            diagnosticCode = "scene_font_resolution_limited"
        } else if features.hasDependencyAnalysisUncertainty {
            diagnosticCode = "scene_dependency_analysis_limited"
        } else if features.requiresDynamicVisibilityRuntime {
            diagnosticCode = "scene_dynamic_visibility_limited"
        } else if features.requiresUnrecognizedLayerRuntime {
            diagnosticCode = "scene_engine_layer_limited"
        } else {
            diagnosticCode = missing.isEmpty ? nil : "scene_live_capabilities_limited"
        }
        return CompatibilityReport(
            level: missing.isEmpty ? .full : .limited,
            playbackPath: .renderedSceneCache,
            requiredCapabilities: required,
            missingCapabilities: missing.sorted(),
            warnings: warnings,
            diagnosticCode: diagnosticCode
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
        if features.requiresFontRuntime { result.insert(.engineLayer) }
        if features.requiresUnrecognizedLayerRuntime { result.insert(.engineLayer) }
        if features.requiresExternalAssetRuntime || features.hasDependencyAnalysisUncertainty {
            result.insert(.engineLayer)
        }
        if features.requiresDynamicVisibilityRuntime { result.insert(.interaction) }
        if features.hasAudioDependencyUncertainty { result.insert(.audioReactive) }
        if features.hasInvalidSoundPlaybackMode { result.insert(.sound) }
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
    public let usesInteraction: Bool
    public let missingLocalDependencies: [String]
    public let remoteDependencies: [String]
    public let localMediaReferences: [WebLocalMediaReference]
    public let missingLocalMediaReferences: [String]
    public let remoteMediaReferences: [String]
    public let hasOpaqueOrDynamicMediaReferences: Bool
    public let localResourceMIMEOverrides: [WebLocalResourceMIMEOverride]
    let hasOpaqueOrDynamicNetworkReferences: Bool
    let missingLocalMediaHasProvenFallback: Bool
    let remoteMediaHasProvenFallback: Bool
    let dependencyAnalysisLimitExceeded: Bool
    let mediaAnalysisLimitExceeded: Bool
    let importMapDiagnosticCode: String?
    let unmappedBareModuleSpecifiers: [String]
    let blockedRemoteDependencies: [String]

    public init(
        usesAudioListener: Bool = false,
        usesMediaIntegration: Bool = false,
        usesInteraction: Bool = false,
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
        self.usesInteraction = usesInteraction
        self.missingLocalDependencies = Array(Set(missingLocalDependencies)).sorted()
        self.remoteDependencies = Array(Set(remoteDependencies)).sorted()
        self.localMediaReferences = Self.sortedLocalMediaReferences(localMediaReferences)
        self.missingLocalMediaReferences = Array(Set(missingLocalMediaReferences)).sorted()
        self.remoteMediaReferences = Array(Set(remoteMediaReferences)).sorted()
        self.hasOpaqueOrDynamicMediaReferences = hasOpaqueOrDynamicMediaReferences
        self.localResourceMIMEOverrides = Self.sortedMIMEOverrides(
            localResourceMIMEOverrides
        )
        self.hasOpaqueOrDynamicNetworkReferences = false
        self.missingLocalMediaHasProvenFallback = false
        self.remoteMediaHasProvenFallback = false
        self.dependencyAnalysisLimitExceeded = false
        self.mediaAnalysisLimitExceeded = false
        self.importMapDiagnosticCode = nil
        self.unmappedBareModuleSpecifiers = []
        self.blockedRemoteDependencies = []
    }

    init(
        usesAudioListener: Bool,
        usesMediaIntegration: Bool,
        usesInteraction: Bool,
        missingLocalDependencies: [String],
        remoteDependencies: [String],
        localMediaReferences: [WebLocalMediaReference],
        missingLocalMediaReferences: [String],
        remoteMediaReferences: [String],
        hasOpaqueOrDynamicMediaReferences: Bool,
        hasOpaqueOrDynamicNetworkReferences: Bool,
        localResourceMIMEOverrides: [WebLocalResourceMIMEOverride],
        missingLocalMediaHasProvenFallback: Bool,
        remoteMediaHasProvenFallback: Bool,
        dependencyAnalysisLimitExceeded: Bool,
        mediaAnalysisLimitExceeded: Bool,
        importMapDiagnosticCode: String?,
        unmappedBareModuleSpecifiers: [String],
        blockedRemoteDependencies: [String]
    ) {
        self.usesAudioListener = usesAudioListener
        self.usesMediaIntegration = usesMediaIntegration
        self.usesInteraction = usesInteraction
        self.missingLocalDependencies = Array(Set(missingLocalDependencies)).sorted()
        self.remoteDependencies = Array(Set(remoteDependencies)).sorted()
        self.localMediaReferences = Self.sortedLocalMediaReferences(localMediaReferences)
        self.missingLocalMediaReferences = Array(Set(missingLocalMediaReferences)).sorted()
        self.remoteMediaReferences = Array(Set(remoteMediaReferences)).sorted()
        self.hasOpaqueOrDynamicMediaReferences = hasOpaqueOrDynamicMediaReferences
        self.hasOpaqueOrDynamicNetworkReferences = hasOpaqueOrDynamicNetworkReferences
        self.localResourceMIMEOverrides = Self.sortedMIMEOverrides(
            localResourceMIMEOverrides
        )
        self.missingLocalMediaHasProvenFallback = missingLocalMediaHasProvenFallback
        self.remoteMediaHasProvenFallback = remoteMediaHasProvenFallback
        self.dependencyAnalysisLimitExceeded = dependencyAnalysisLimitExceeded
        self.mediaAnalysisLimitExceeded = mediaAnalysisLimitExceeded
        self.importMapDiagnosticCode = importMapDiagnosticCode
        self.unmappedBareModuleSpecifiers = Array(Set(unmappedBareModuleSpecifiers)).sorted()
        self.blockedRemoteDependencies = Array(Set(blockedRemoteDependencies)).sorted()
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

struct WebJavaScriptModuleLiteral: Sendable, Equatable {
    let reference: String
    let utf8ContentRange: Range<Int>
}

struct WebCSSReferenceLiteral: Sendable, Equatable {
    let reference: String
    let utf8ContentRange: Range<Int>
}

struct WebHTMLAttributeLiteral: Sendable, Equatable {
    let name: String
    let reference: String
    let utf8ContentRange: Range<Int>
}

struct WebHTMLStagingReferenceScan: Sendable, Equatable {
    let hasAuthoredBase: Bool
    let resourceAttributes: [WebHTMLAttributeLiteral]
    let sourceSetAttributes: [WebHTMLAttributeLiteral]
    let inlineStyleUTF8Ranges: [Range<Int>]
    let importMapUTF8Ranges: [Range<Int>]
}

public struct WebRuntimeFeatureAnalyzer: Sendable {
    static let maximumDependencyNodes = 2_000
    static let maximumDependencyTextBytes = 8 * 1_024 * 1_024
    static let maximumReferencesPerFile = 256
    static let maximumImportMapBytes = 256 * 1_024
    static let maximumImportMapEntries = 256
    static let maximumJavaScriptNestingDepth = 64
    static let maximumDocumentDependencyElements = maximumDependencyNodes
    static let maximumStaticMediaReferences = 64
    static let maximumHTMLDocuments = 64
    static let maximumHTMLNestingDepth = 8

    private static let interactionEventNames: Set<String> = [
        "auxclick", "click", "contextmenu", "dblclick",
        "drag", "dragend", "dragenter", "dragleave", "dragover", "dragstart", "drop",
        "gotpointercapture", "lostpointercapture",
        "mousedown", "mouseenter", "mouseleave", "mousemove", "mouseout", "mouseover", "mouseup",
        "pointercancel", "pointerdown", "pointerenter", "pointerleave", "pointermove",
        "pointerout", "pointerover", "pointerup",
        "touchcancel", "touchend", "touchmove", "touchstart", "wheel"
    ]
    private static let jqueryInteractionMethodNames: Set<String> = [
        "auxclick", "click", "contextmenu", "dblclick",
        "mousedown", "mouseenter", "mouseleave", "mousemove", "mouseout", "mouseover", "mouseup",
        "pointerdown", "pointermove", "pointerup",
        "touchend", "touchmove", "touchstart", "wheel"
    ]

    private enum DocumentBase: Sendable {
        case resolved(URL)
        case authored(URL)
        case invalid

        var resolvedURL: URL? {
            switch self {
            case .resolved(let url), .authored(let url): return url
            case .invalid: return nil
            }
        }

        var rootReferencesFailClosed: DocumentBase {
            switch self {
            case .resolved(let url), .authored(let url): return .authored(url)
            case .invalid: return .invalid
            }
        }
    }

    private enum DependencyResolution {
        case ignored
        case local(URL)
        case missingLocal
        case externalNetwork
        case blockedExternalNetwork
    }

    private enum ImportMapFailure: String, Error, Sendable {
        case malformed = "web_import_map_malformed"
        case tooLarge = "web_import_map_too_large"
        case unsafe = "web_import_map_unsafe"
    }

    private struct ImportMapResolution: Hashable, Sendable {
        let resolvedReference: String
        let diagnosticReference: String
    }

    private struct ImportMapEntry: Hashable, Sendable {
        let specifier: String
        /// A `null` or otherwise unsafe address blocks a matching specifier,
        /// matching the browser import-map algorithm without rejecting an
        /// unrelated, otherwise valid map.
        let target: ImportMapResolution?
        let isPrefix: Bool
    }

    private struct ImportMapScope: Hashable, Sendable {
        let prefix: String
        let entries: [ImportMapEntry]
    }

    private enum ImportMapLookup: Sendable {
        case resolved(ImportMapResolution)
        case blocked
    }

    private struct StaticImportMap: Hashable, Sendable {
        var entries = [ImportMapEntry]()
        var scopes = [ImportMapScope]()
        var declarationCount = 0

        func resolve(_ specifier: String, importer: URL) -> ImportMapLookup? {
            let normalizedSpecifier: String
            if Self.isURLLikeSpecifier(specifier) {
                guard let resolved = URL(string: specifier, relativeTo: importer)?.absoluteURL else {
                    return .blocked
                }
                normalizedSpecifier = resolved.absoluteString
            } else {
                normalizedSpecifier = specifier
            }
            let importerReference = importer.absoluteURL.absoluteString
            for scope in scopes
                .filter({ importerReference.hasPrefix($0.prefix) })
                .sorted(by: { $0.prefix.count > $1.prefix.count }) {
                if let result = Self.resolve(normalizedSpecifier, in: scope.entries) {
                    return result
                }
            }
            return Self.resolve(normalizedSpecifier, in: entries)
        }

        private static func resolve(
            _ specifier: String,
            in entries: [ImportMapEntry]
        ) -> ImportMapLookup? {
            if let exact = entries.first(where: {
                !$0.isPrefix && $0.specifier == specifier
            }) {
                guard let target = exact.target else { return .blocked }
                return .resolved(target)
            }
            guard let prefix = entries
                .filter({ $0.isPrefix && specifier.hasPrefix($0.specifier) })
                .max(by: { $0.specifier.count < $1.specifier.count }) else {
                return nil
            }
            guard let target = prefix.target else { return .blocked }
            let suffix = String(specifier.dropFirst(prefix.specifier.count))
            guard !Self.containsBacktrackingPathSegment(suffix),
                  let targetURL = URL(string: target.resolvedReference),
                  let resolvedURL = URL(string: suffix, relativeTo: targetURL)?.absoluteURL,
                  resolvedURL.absoluteString.hasPrefix(targetURL.absoluteString) else {
                return .blocked
            }
            return .resolved(
                ImportMapResolution(
                    resolvedReference: resolvedURL.absoluteString,
                    diagnosticReference: target.diagnosticReference + suffix
                )
            )
        }

        private static func isURLLikeSpecifier(_ value: String) -> Bool {
            value.hasPrefix("/")
                || value.hasPrefix("./")
                || value.hasPrefix("../")
                || URL(string: value)?.scheme != nil
        }

        private static func containsBacktrackingPathSegment(_ value: String) -> Bool {
            value.split(separator: "/", omittingEmptySubsequences: false).contains { component in
                let decoded = String(component).removingPercentEncoding ?? String(component)
                return decoded == "."
                    || decoded == ".."
                    || decoded.contains("/")
                    || decoded.contains("\\")
            }
        }
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
        let importMap: StaticImportMap?
    }

    private enum DependencyReferenceContext: Equatable {
        case document
        case javaScript
        case javaScriptResource
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

    private struct ParsedJavaScriptModuleReference {
        let reference: String?
        let end: Int
        let literalContentRange: Range<Int>?

        init(
            _ reference: String?,
            end: Int,
            literalContentRange: Range<Int>? = nil
        ) {
            self.reference = reference
            self.end = end
            self.literalContentRange = literalContentRange
        }
    }

    private struct DependencyNode: Sendable {
        let url: URL
        let kind: DependencyFileKind
        let runtimeBase: DocumentBase
        let importMap: StaticImportMap?
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
        let rawTextUTF8Range: Range<Int>?
        let mediaContainer: WebMediaElementKind?
        let mediaGroupID: Int?
        let imageGroupID: Int?
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

    private struct HTMLImageGroupState {
        var hasLocal = false
        var missingLocal = Set<String>()
        var remote = Set<String>()
    }

    private struct DocumentDependencyScanResult {
        let elements: [DocumentDependencyElement]
        let usesInteraction: Bool
        let limitExceeded: Bool
    }

    private struct DependencyScanResult {
        let references: [String]
        let networkReferences: [String]
        let resourceReferences: [String]
        let mediaReferences: [JavaScriptMediaReference]
        let hasOpaqueOrDynamicMediaReferences: Bool
        let hasOpaqueOrDynamicNetworkReferences: Bool
        let usesInteraction: Bool
        let scannedReferenceCount: Int
        let limitExceeded: Bool

        init(
            references: [String],
            networkReferences: [String] = [],
            resourceReferences: [String] = [],
            mediaReferences: [JavaScriptMediaReference] = [],
            hasOpaqueOrDynamicMediaReferences: Bool = false,
            hasOpaqueOrDynamicNetworkReferences: Bool = false,
            usesInteraction: Bool = false,
            scannedReferenceCount: Int? = nil,
            limitExceeded: Bool
        ) {
            self.references = references
            self.networkReferences = networkReferences
            self.resourceReferences = resourceReferences
            self.mediaReferences = mediaReferences
            self.hasOpaqueOrDynamicMediaReferences = hasOpaqueOrDynamicMediaReferences
            self.hasOpaqueOrDynamicNetworkReferences = hasOpaqueOrDynamicNetworkReferences
            self.usesInteraction = usesInteraction
            self.scannedReferenceCount = scannedReferenceCount
                ?? references.count + networkReferences.count
                    + resourceReferences.count + mediaReferences.count
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
        var htmlImageGroups = [HTMLMediaGroupKey: HTMLImageGroupState]()
        var hasUngroupedMissingLocalMedia = false
        var hasUngroupedRemoteMedia = false
        var nextHTMLDocumentID = 0
        var hasOpaqueOrDynamicMediaReferences = false
        var hasOpaqueOrDynamicNetworkReferences = false
        var localResourceMIMEOverrideByPath = [String: WebLocalResourceMIMEOverride]()
        var usesInteraction = false
        var importMapDiagnosticCode: String?
        var unmappedBareModuleSpecifiers = Set<String>()
        var blockedRemoteDependencies = Set<String>()
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
            if source.contains("wallpaperRegisterAudioListener")
                || source.contains("livelyAudioListener") {
                usesAudioListener = true
            }
            if source.contains("wallpaperRegisterMedia")
                || source.contains("livelyCurrentTrack")
                || source.contains("livelySystemInformation") {
                usesMediaIntegration = true
            }
            if usesAudioListener && usesMediaIntegration { break }
        }
        return WebRuntimeFeatures(
            usesAudioListener: usesAudioListener,
            usesMediaIntegration: usesMediaIntegration,
            usesInteraction: dependencies.usesInteraction,
            missingLocalDependencies: Array(dependencies.missingLocal),
            remoteDependencies: Array(dependencies.remote),
            localMediaReferences: Array(dependencies.localMediaByIdentity.values),
            missingLocalMediaReferences: Array(dependencies.missingLocalMedia),
            remoteMediaReferences: Array(dependencies.remoteMedia),
            hasOpaqueOrDynamicMediaReferences: dependencies.hasOpaqueOrDynamicMediaReferences,
            hasOpaqueOrDynamicNetworkReferences:
                dependencies.hasOpaqueOrDynamicNetworkReferences,
            localResourceMIMEOverrides: Array(
                dependencies.localResourceMIMEOverrideByPath.values
            ),
            missingLocalMediaHasProvenFallback:
                dependencies.missingLocalMediaHasProvenFallback,
            remoteMediaHasProvenFallback: dependencies.remoteMediaHasProvenFallback,
            dependencyAnalysisLimitExceeded: dependencies.limitExceeded,
            mediaAnalysisLimitExceeded: dependencies.mediaLimitExceeded,
            importMapDiagnosticCode: dependencies.importMapDiagnosticCode,
            unmappedBareModuleSpecifiers: Array(dependencies.unmappedBareModuleSpecifiers),
            blockedRemoteDependencies: Array(dependencies.blockedRemoteDependencies)
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
            kind: .htmlDocument,
            importMap: nil
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
            if scan.usesInteraction {
                result.usesInteraction = true
            }
            if case .javaScript = node.kind {
                appendJavaScriptMediaReferences(
                    scan,
                    base: node.runtimeBase,
                    root: root,
                    result: &result
                )
                appendJavaScriptNetworkReferences(
                    scan,
                    base: node.runtimeBase,
                    root: root,
                    result: &result
                )
            } else if case .stylesheet = node.kind {
                appendStaticResourceReferences(
                    scan.resourceReferences,
                    base: .resolved(node.url),
                    root: root,
                    result: &result,
                    context: .stylesheet
                )
            }
            appendScannedDependencies(
                scan.references,
                base: .resolved(node.url),
                runtimeBase: node.runtimeBase,
                context: context,
                importer: node.url,
                importMap: node.importMap,
                root: root,
                result: &result,
                queue: &queue,
                discoveredNodes: &discoveredNodes
            )
            if result.limitExceeded { break }
        }
        finalizeImageResourceGroups(result: &result)
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
        if documentScan.usesInteraction {
            result.usesInteraction = true
        }
        let htmlDocumentID = result.nextHTMLDocumentID
        result.nextHTMLDocumentID += 1
        var effectiveBase = inheritedBase ?? DocumentBase.resolved(documentURL)
        var hasDocumentBase = false
        var importMap = StaticImportMap()
        var hasEncounteredModuleScript = false
        var referenceCount = 0
        for element in documentScan.elements {
            if let inlineStyle = attribute("style", in: element.openingTag) {
                let styleScan = stylesheetDependencies(
                    in: inlineStyle,
                    limit: Self.maximumReferencesPerFile - referenceCount
                )
                guard !styleScan.limitExceeded else {
                    result.limitExceeded = true
                    return
                }
                referenceCount += styleScan.scannedReferenceCount
                appendStaticResourceReferences(
                    styleScan.resourceReferences,
                    base: effectiveBase,
                    root: root,
                    result: &result,
                    context: .stylesheet
                )
            }
            if element.name == "base",
               !hasDocumentBase,
               let reference = attribute("href", in: element.openingTag) {
                effectiveBase = documentBase(reference: reference, entrypoint: documentURL)
                hasDocumentBase = true
                continue
            }
            if element.name == "script", isImportMapScript(element.openingTag) {
                // Import maps do not have external `src` semantics. Keep such a
                // tag inert, matching WebKit, instead of treating its URL as a
                // dependency or parsing unrelated fallback text.
                if attribute("src", in: element.openingTag) != nil { continue }
                guard !hasEncounteredModuleScript else {
                    result.importMapDiagnosticCode = ImportMapFailure.unsafe.rawValue
                    return
                }
                guard let rawText = element.rawText else {
                    result.importMapDiagnosticCode = ImportMapFailure.malformed.rawValue
                    return
                }
                switch mergeImportMap(
                    rawText,
                    base: effectiveBase,
                    root: root,
                    into: &importMap
                ) {
                case .success:
                    break
                case .failure(let failure):
                    result.importMapDiagnosticCode = failure.rawValue
                    return
                }
                continue
            }
            if element.name == "script", isJavaScriptModuleScript(element.openingTag) {
                hasEncounteredModuleScript = true
            }
            if element.name == "img", let imageGroupID = element.imageGroupID {
                var candidates = [String]()
                if let source = attribute("src", in: element.openingTag) {
                    candidates.append(source)
                }
                if let sourceSet = attribute("srcset", in: element.openingTag) {
                    let parsed = imageCandidateReferences(
                        in: sourceSet,
                        limit: Self.maximumReferencesPerFile - referenceCount - candidates.count
                    )
                    guard !parsed.limitExceeded else {
                        result.limitExceeded = true
                        return
                    }
                    candidates.append(contentsOf: parsed.references)
                }
                referenceCount += candidates.count
                guard referenceCount <= Self.maximumReferencesPerFile else {
                    result.limitExceeded = true
                    return
                }
                appendStaticImageCandidates(
                    candidates,
                    group: HTMLMediaGroupKey(
                        documentID: htmlDocumentID,
                        containerID: imageGroupID
                    ),
                    base: effectiveBase,
                    root: root,
                    result: &result
                )
                continue
            }
            if element.name == "source", let imageGroupID = element.imageGroupID,
               let sourceSet = attribute("srcset", in: element.openingTag) {
                let parsed = imageCandidateReferences(
                    in: sourceSet,
                    limit: Self.maximumReferencesPerFile - referenceCount
                )
                guard !parsed.limitExceeded else {
                    result.limitExceeded = true
                    return
                }
                referenceCount += parsed.references.count
                appendStaticImageCandidates(
                    parsed.references,
                    group: HTMLMediaGroupKey(
                        documentID: htmlDocumentID,
                        containerID: imageGroupID
                    ),
                    base: effectiveBase,
                    root: root,
                    result: &result
                )
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
                        // `srcdoc` has no staging file whose package-root URLs
                        // can be made token-relative. Preserve relative URL
                        // resolution but reject single-leading-slash sinks.
                        inheritedBase: effectiveBase.rootReferencesFailClosed,
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
                    runtimeBase: effectiveBase,
                    importMap: dependency.kind.keyKind == .javaScript ? importMap : nil
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
            if inlineScan.scan.usesInteraction {
                result.usesInteraction = true
            }
            if inlineScan.context == .javaScript {
                appendJavaScriptMediaReferences(
                    inlineScan.scan,
                    base: effectiveBase,
                    root: root,
                    result: &result
                )
                appendJavaScriptNetworkReferences(
                    inlineScan.scan,
                    base: effectiveBase,
                    root: root,
                    result: &result
                )
            } else if inlineScan.context == .stylesheet {
                appendStaticResourceReferences(
                    inlineScan.scan.resourceReferences,
                    base: effectiveBase,
                    root: root,
                    result: &result,
                    context: .stylesheet
                )
            }
            appendScannedDependencies(
                inlineScan.scan.references,
                base: effectiveBase,
                runtimeBase: effectiveBase,
                context: inlineScan.context,
                // Inline module specifiers are resolved against the document's
                // effective base URL, including the first valid `<base href>`.
                // Using the source file URL here makes URL-like import-map keys
                // miss even though WebKit resolves them through that base.
                importer: effectiveBase.resolvedURL ?? documentURL,
                importMap: inlineScan.context == .javaScript ? importMap : nil,
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
        case .blockedExternalNetwork:
            result.blockedRemoteDependencies.insert(reference)
        case .local(let url):
            let canonical = canonicalFileURL(url)
            recordRuntimeMIMEType("text/html", for: canonical, result: &result)
            let key = DependencyNodeKey(
                canonicalPath: canonical.path,
                kind: .htmlDocument,
                importMap: nil
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
                    runtimeBase: .resolved(canonical),
                    importMap: nil
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
            if media.requiresMediaPathHint,
               javaScriptSourcePathKind(media.reference) == .knownNonMedia {
                // A generic DOM `.src`/`setAttribute("src", ...)` assignment
                // can target an image, script, iframe, or other visual
                // resource. It is not FFmpeg media, but it is still a runtime
                // dependency and must follow the same local/public/private
                // policy as authored HTML and CSS resources.
                appendStaticResourceReferences(
                    [media.reference],
                    base: base,
                    root: root,
                    result: &result,
                    context: .javaScriptResource
                )
                continue
            }
            appendStaticMediaReference(
                media.reference,
                kind: media.kind,
                base: base,
                root: root,
                result: &result,
                requiresMediaPathHint: media.requiresMediaPathHint,
                context: .javaScriptResource
            )
        }
    }

    private func appendJavaScriptNetworkReferences(
        _ scan: DependencyScanResult,
        base: DocumentBase,
        root: URL,
        result: inout DependencyAnalysisResult
    ) {
        if scan.hasOpaqueOrDynamicNetworkReferences {
            result.hasOpaqueOrDynamicNetworkReferences = true
        }
        for reference in scan.networkReferences {
            switch dependencyResolution(
                reference,
                base: base,
                context: .javaScriptResource,
                root: root
            ) {
            case .ignored:
                break
            case .missingLocal:
                result.missingLocal.insert(reference)
            case .externalNetwork:
                result.remote.insert(reference)
            case .blockedExternalNetwork:
                result.blockedRemoteDependencies.insert(reference)
            case .local:
                break
            }
        }
    }

    private func appendStaticResourceReferences(
        _ references: [String],
        base: DocumentBase,
        root: URL,
        result: inout DependencyAnalysisResult,
        context: DependencyReferenceContext = .document
    ) {
        for reference in references {
            switch dependencyResolution(reference, base: base, context: context, root: root) {
            case .ignored, .local:
                break
            case .missingLocal:
                result.missingLocal.insert(reference)
            case .externalNetwork:
                result.remote.insert(reference)
            case .blockedExternalNetwork:
                result.blockedRemoteDependencies.insert(reference)
            }
        }
    }

    private func appendStaticImageCandidates(
        _ references: [String],
        group: HTMLMediaGroupKey,
        base: DocumentBase,
        root: URL,
        result: inout DependencyAnalysisResult
    ) {
        for reference in references {
            switch dependencyResolution(reference, base: base, context: .document, root: root) {
            case .ignored:
                break
            case .local:
                result.htmlImageGroups[group, default: HTMLImageGroupState()].hasLocal = true
            case .missingLocal:
                result.htmlImageGroups[group, default: HTMLImageGroupState()]
                    .missingLocal.insert(reference)
            case .externalNetwork:
                result.htmlImageGroups[group, default: HTMLImageGroupState()].remote.insert(reference)
            case .blockedExternalNetwork:
                // A private candidate can be selected by media/DPR negotiation.
                // Never let a sibling fallback turn an ambient-network request
                // into a Full compatibility report.
                result.blockedRemoteDependencies.insert(reference)
            }
        }
    }

    private func finalizeImageResourceGroups(result: inout DependencyAnalysisResult) {
        for group in result.htmlImageGroups.values {
            // `src` and sibling `srcset`/`picture` candidates are selected by
            // media queries, viewport and backing-scale factor. A local 1x
            // candidate is not a guaranteed fallback for a missing 2x source,
            // so every selectable candidate remains part of compatibility.
            result.missingLocal.formUnion(group.missingLocal)
            result.remote.formUnion(group.remote)
        }
    }

    private func imageCandidateReferences(
        in sourceSet: String,
        limit: Int
    ) -> (references: [String], limitExceeded: Bool) {
        guard limit >= 0 else { return ([], true) }
        let bytes = Array(sourceSet.utf8)
        var result = [String]()
        var index = 0
        while index < bytes.count {
            while index < bytes.count,
                  isHTMLWhitespace(bytes[index]) || bytes[index] == 0x2C {
                index += 1
            }
            let start = index
            while index < bytes.count, !isHTMLWhitespace(bytes[index]) { index += 1 }
            guard index > start else { break }
            var end = index
            while end > start, bytes[end - 1] == 0x2C { end -= 1 }
            if end > start {
                result.append(String(decoding: bytes[start..<end], as: UTF8.self))
                if result.count > limit {
                    return (Array(result.prefix(limit)), true)
                }
            }
            var parenthesisDepth = 0
            while index < bytes.count {
                if bytes[index] == 0x28 {
                    parenthesisDepth += 1
                } else if bytes[index] == 0x29 {
                    parenthesisDepth = max(0, parenthesisDepth - 1)
                } else if bytes[index] == 0x2C, parenthesisDepth == 0 {
                    index += 1
                    break
                }
                index += 1
            }
        }
        return (result, false)
    }

    private func appendStaticMediaReference(
        _ reference: String,
        kind: WebMediaElementKind,
        base: DocumentBase,
        root: URL,
        result: inout DependencyAnalysisResult,
        requiresMediaPathHint: Bool = false,
        localMediaCanProveFallback: Bool = true,
        mediaGroup: HTMLMediaGroupKey? = nil,
        context: DependencyReferenceContext = .document
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
        switch dependencyResolution(trimmed, base: base, context: context, root: root) {
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
        case .blockedExternalNetwork:
            result.blockedRemoteDependencies.insert(trimmed)
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
        importMap: StaticImportMap?,
        root: URL,
        result: inout DependencyAnalysisResult,
        queue: inout [DependencyNode],
        discoveredNodes: inout Set<DependencyNodeKey>
    ) {
        for reference in references {
            let effectiveReference: ImportMapResolution
            if context == .javaScript,
               let lookup = importMap?.resolve(reference, importer: importer) {
                switch lookup {
                case .resolved(let mapped): effectiveReference = mapped
                case .blocked:
                    result.importMapDiagnosticCode = ImportMapFailure.unsafe.rawValue
                    return
                }
            } else if context == .javaScript,
                      isBareJavaScriptModuleSpecifier(reference) {
                result.unmappedBareModuleSpecifiers.insert(reference)
                continue
            } else {
                effectiveReference = ImportMapResolution(
                    resolvedReference: reference,
                    diagnosticReference: reference
                )
            }
            if context == .javaScript,
               effectiveReference.resolvedReference.hasPrefix("/"),
               !effectiveReference.resolvedReference.hasPrefix("//") {
                // ES-module resolution is performed by WebKit itself and
                // cannot be intercepted by the document-start resource bridge.
                // Only a private staging rewrite can preserve the authenticated
                // /<token>/project/ prefix. Unrewritten project-root module
                // specifiers therefore fail closed instead of being reported
                // Full while the browser receives a tokenless 404.
                result.missingLocal.insert(effectiveReference.diagnosticReference)
                continue
            }
            let kind: DependencyFileKind?
            switch context {
            case .javaScript:
                // Static imports without an extension (or with an authored
                // asset-style extension) are executable JavaScript. Keep
                // standard typed module resources on their normal MIME path;
                // overriding JSON/CSS/WASM as JavaScript would make a valid
                // import assertion fail under `nosniff`.
                let importedExtension = URL(
                    string: effectiveReference.resolvedReference,
                    relativeTo: importer
                )?.pathExtension.lowercased() ?? ""
                kind = ["css", "json", "wasm"].contains(importedExtension)
                    ? nil
                    : .javaScript
            case .javaScriptResource:
                kind = nil
            case .stylesheet:
                kind = .stylesheet
            case .document:
                kind = nil
            }
            appendDependency(
                effectiveReference.resolvedReference,
                base: base,
                context: context,
                kind: kind,
                root: root,
                result: &result,
                queue: &queue,
                discoveredNodes: &discoveredNodes,
                runtimeBase: runtimeBase,
                diagnosticReference: effectiveReference.diagnosticReference,
                importMap: importMap
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

    private func isJavaScriptModuleScript(_ tag: String) -> Bool {
        (attribute("type", in: tag) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "module"
    }

    private func isImportMapScript(_ tag: String) -> Bool {
        (attribute("type", in: tag) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "importmap"
    }

    private func isBareJavaScriptModuleSpecifier(_ rawReference: String) -> Bool {
        let reference = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty,
              !reference.contains("{{"),
              !reference.contains("${"),
              URL(string: reference)?.scheme == nil else {
            return false
        }
        return !reference.hasPrefix("./")
            && !reference.hasPrefix("../")
            && !reference.hasPrefix("/")
    }

    private func mergeImportMap(
        _ source: String,
        base: DocumentBase,
        root: URL,
        into importMap: inout StaticImportMap
    ) -> Result<Void, ImportMapFailure> {
        // macOS 14's baseline WebKit guarantees only one import map registered
        // before module loading. Fail closed instead of analyzing merge
        // semantics that the playback runtime may ignore.
        guard importMap.declarationCount == 0 else { return .failure(.unsafe) }
        let data = Data(source.utf8)
        guard data.count <= Self.maximumImportMapBytes else {
            return .failure(.tooLarge)
        }
        guard hasStrictImportMapJSONSyntax(data),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            return .failure(.malformed)
        }
        let rawImports: [String: Any]
        if let value = object["imports"] {
            guard let mappings = value as? [String: Any] else {
                return .failure(.malformed)
            }
            rawImports = mappings
        } else {
            rawImports = [:]
        }
        let rawScopes: [String: Any]
        if let value = object["scopes"] {
            guard let mappings = value as? [String: Any] else {
                return .failure(.malformed)
            }
            rawScopes = mappings
        } else {
            rawScopes = [:]
        }

        var entryCount = 0
        let additions: [ImportMapEntry]
        switch parsedImportMapEntries(
            rawImports,
            base: base,
            root: root,
            entryCount: &entryCount
        ) {
        case .success(let entries):
            additions = entries
        case .failure(let failure):
            return .failure(failure)
        }

        var scopeAdditions = [ImportMapScope]()
        scopeAdditions.reserveCapacity(rawScopes.count)
        for (rawPrefix, rawMappings) in rawScopes {
            guard rawPrefix == rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawPrefix.isEmpty,
                  !rawPrefix.contains("{{"),
                  !rawPrefix.contains("${"),
                  !rawPrefix.contains("\\"),
                  !isBareJavaScriptModuleSpecifier(rawPrefix),
                  let prefix = resolvedImportMapTarget(rawPrefix, base: base, root: root),
                  let mappings = rawMappings as? [String: Any] else {
                return .failure(.unsafe)
            }
            let entries: [ImportMapEntry]
            switch parsedImportMapEntries(
                mappings,
                base: base,
                root: root,
                entryCount: &entryCount
            ) {
            case .success(let parsed):
                entries = parsed
            case .failure(let failure):
                return .failure(failure)
            }
            guard !scopeAdditions.contains(where: { $0.prefix == prefix }) else {
                return .failure(.unsafe)
            }
            scopeAdditions.append(ImportMapScope(prefix: prefix, entries: entries))
        }

        importMap.entries = additions
        importMap.scopes = scopeAdditions.sorted {
            if $0.prefix.count != $1.prefix.count { return $0.prefix.count > $1.prefix.count }
            return $0.prefix < $1.prefix
        }
        importMap.declarationCount = 1
        return .success(())
    }

    private func parsedImportMapEntries(
        _ mappings: [String: Any],
        base: DocumentBase,
        root: URL,
        entryCount: inout Int
    ) -> Result<[ImportMapEntry], ImportMapFailure> {
        guard mappings.count <= Self.maximumImportMapEntries,
              entryCount <= Self.maximumImportMapEntries - mappings.count else {
            return .failure(.tooLarge)
        }
        entryCount += mappings.count
        var result = [ImportMapEntry]()
        result.reserveCapacity(mappings.count)
        for (rawSpecifier, rawTarget) in mappings {
            guard rawSpecifier == rawSpecifier.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawSpecifier.isEmpty,
                  !rawSpecifier.contains("{{"),
                  !rawSpecifier.contains("${"),
                  !rawSpecifier.contains("\\") else {
                return .failure(.unsafe)
            }
            let specifier: String
            if isBareJavaScriptModuleSpecifier(rawSpecifier) {
                specifier = rawSpecifier
            } else {
                guard isSupportedImportMapAddress(rawSpecifier),
                      let normalized = resolvedImportMapTarget(
                          rawSpecifier,
                          base: base,
                          root: root
                      ) else {
                    return .failure(.unsafe)
                }
                specifier = normalized
            }
            let isPrefix = specifier.hasSuffix("/")
            let target: ImportMapResolution?
            if rawTarget is NSNull {
                target = nil
            } else if let address = rawTarget as? String,
                      !address.isEmpty,
                      address == address.trimmingCharacters(in: .whitespacesAndNewlines),
                      !address.contains("{{"),
                      !address.contains("${"),
                      !address.contains("\\"),
                      isSupportedImportMapAddress(address),
                      (!isPrefix || address.hasSuffix("/")),
                      let resolved = resolvedImportMapTarget(address, base: base, root: root) {
                target = ImportMapResolution(
                    resolvedReference: resolved,
                    diagnosticReference: address
                )
            } else {
                // Browsers ignore or block malformed individual mappings. Keep
                // that failure attached to the key so only a reachable import
                // is rejected by the bounded probe.
                target = nil
            }
            guard !result.contains(where: { $0.specifier == specifier }) else {
                return .failure(.unsafe)
            }
            result.append(
                ImportMapEntry(specifier: specifier, target: target, isPrefix: isPrefix)
            )
        }
        return .success(result.sorted {
            if $0.isPrefix != $1.isPrefix { return !$0.isPrefix }
            if $0.specifier.count != $1.specifier.count {
                return $0.specifier.count > $1.specifier.count
            }
            return $0.specifier < $1.specifier
        })
    }

    private func isSupportedImportMapAddress(_ target: String) -> Bool {
        if target.hasPrefix("//") { return true }
        if target.hasPrefix("/"), target != "/" { return true }
        if target.hasPrefix("./") || target.hasPrefix("../") { return true }
        guard let scheme = URL(string: target)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func hasStrictImportMapJSONSyntax(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var index = 0
        var isInsideString = false
        var isEscaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    isInsideString = false
                }
                index += 1
                continue
            }
            if byte == 0x22 {
                isInsideString = true
                index += 1
                continue
            }
            // JSON has no comments. Foundation's parser can become more
            // permissive across OS releases, so reject JSON5-style input here.
            if byte == 0x2F { return false }
            if byte == 0x2C {
                var lookahead = index + 1
                while lookahead < bytes.count, isHTMLWhitespace(bytes[lookahead]) {
                    lookahead += 1
                }
                if lookahead < bytes.count,
                   bytes[lookahead] == 0x7D || bytes[lookahead] == 0x5D {
                    return false
                }
            }
            index += 1
        }
        return !isInsideString && !isEscaped
    }

    private func resolvedImportMapTarget(
        _ target: String,
        base: DocumentBase,
        root: URL
    ) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == target, !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
            return nil
        }
        if trimmed.hasPrefix("//") {
            guard let components = URLComponents(string: "https:" + trimmed),
                  components.host != nil else { return nil }
            return "https:" + trimmed
        }
        if let scheme = URL(string: trimmed)?.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https",
                  let remote = URL(string: trimmed),
                  remote.host != nil else { return nil }
            return remote.absoluteString
        }
        let baseURL: URL
        switch base {
        case .resolved(let url), .authored(let url): baseURL = url
        case .invalid: return nil
        }
        guard !trimmed.hasPrefix("/"),
              isSafeAuthoredLocalReference(trimmed),
              let candidate = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }
        if ["http", "https"].contains(candidate.scheme?.lowercased() ?? "") {
            guard candidate.host != nil else { return nil }
            return candidate.absoluteString
        }
        guard candidate.isFileURL else { return nil }
        let standardized = candidate.standardizedFileURL
        let rootComponents = root.standardizedFileURL.pathComponents
        let targetComponents = standardized.pathComponents
        guard targetComponents.count >= rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return standardized.absoluteString
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
        runtimeBase: DocumentBase,
        diagnosticReference: String? = nil,
        importMap: StaticImportMap? = nil
    ) {
        let diagnosticReference = diagnosticReference ?? reference
        switch dependencyResolution(reference, base: base, context: context, root: root) {
        case .ignored:
            break
        case .missingLocal:
            result.missingLocal.insert(diagnosticReference)
        case .externalNetwork:
            result.remote.insert(reference)
        case .blockedExternalNetwork:
            result.blockedRemoteDependencies.insert(diagnosticReference)
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
                kind: kind.keyKind,
                importMap: kind.keyKind == .javaScript ? importMap : nil
            )
            guard !discoveredNodes.contains(key) else { return }
            guard discoveredNodes.count < Self.maximumDependencyNodes else {
                result.limitExceeded = true
                return
            }
            discoveredNodes.insert(key)
            queue.append(
                DependencyNode(
                    url: canonical,
                    kind: kind,
                    runtimeBase: runtimeBase,
                    importMap: kind.keyKind == .javaScript ? importMap : nil
                )
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

    /// Returns only module-specifier literals discovered by the same bounded,
    /// comment/string/RegExp-aware lexer used by compatibility analysis. The
    /// Lively importer uses these UTF-8 byte ranges to rewrite a private
    /// staging copy without touching arbitrary strings or the selected source.
    func javaScriptModuleLiteralsForStaging(
        in source: String
    ) -> [WebJavaScriptModuleLiteral]? {
        let bytes = Array(source.utf8)
        var references = [String]()
        var moduleLiterals = [WebJavaScriptModuleLiteral]()
        var networkReferences = [String]()
        var mediaReferences = [JavaScriptMediaReference]()
        var hasOpaqueOrDynamicMediaReferences = false
        var hasOpaqueOrDynamicNetworkReferences = false
        var xmlHTTPRequestReceivers = Set<String>()
        var usesInteraction = false
        var scannedReferenceCount = 0
        var limitExceeded = false
        _ = scanJavaScript(
            bytes,
            from: 0,
            stopAtClosingBrace: false,
            nestingDepth: 0,
            limit: Self.maximumReferencesPerFile,
            references: &references,
            moduleLiterals: &moduleLiterals,
            networkReferences: &networkReferences,
            mediaReferences: &mediaReferences,
            hasOpaqueOrDynamicMediaReferences: &hasOpaqueOrDynamicMediaReferences,
            hasOpaqueOrDynamicNetworkReferences: &hasOpaqueOrDynamicNetworkReferences,
            xmlHTTPRequestReceivers: &xmlHTTPRequestReceivers,
            usesInteraction: &usesInteraction,
            scannedReferenceCount: &scannedReferenceCount,
            limitExceeded: &limitExceeded
        )
        return limitExceeded ? nil : moduleLiterals
    }

    /// Finds executable inline-script bodies with the same quote-aware HTML
    /// raw-text scanner used by compatibility analysis. A caller must not
    /// rewrite these ranges when `hasAuthoredBase` is true because converting
    /// `/module.js` to a relative URL would change which file `<base>` selects.
    func inlineJavaScriptRangesForStaging(
        in source: String
    ) -> (hasAuthoredBase: Bool, utf8Ranges: [Range<Int>])? {
        let scan = documentDependencyElements(
            in: source,
            limit: Self.maximumDocumentDependencyElements
        )
        guard !scan.limitExceeded else { return nil }
        let hasAuthoredBase = scan.elements.contains { $0.name == "base" }
        let ranges = scan.elements.compactMap { element -> Range<Int>? in
            guard element.name == "script",
                  attribute("src", in: element.openingTag) == nil,
                  isExecutableScript(element.openingTag) else {
                return nil
            }
            return element.rawTextUTF8Range
        }
        return (hasAuthoredBase, ranges)
    }

    /// Returns byte ranges that are safe for the Lively staging normalizer to
    /// edit. The scan uses the same quote-aware tag and raw-text boundaries as
    /// compatibility analysis, so a `>` inside an attribute, markup-looking
    /// JavaScript, or inert textarea text can never become an HTML attribute.
    func htmlReferencesForStaging(
        in source: String
    ) -> WebHTMLStagingReferenceScan? {
        let bytes = Array(source.utf8)
        let rawTextNames: Set<String> = [
            "script", "style", "textarea", "title", "xmp", "iframe",
            "noembed", "noframes", "noscript", "plaintext",
        ]
        let stagingAttributeNames: Set<String> = [
            "src", "href", "poster", "data", "srcset", "imagesrcset", "style",
        ]
        var resourceAttributes = [WebHTMLAttributeLiteral]()
        var sourceSetAttributes = [WebHTMLAttributeLiteral]()
        var inlineStyleRanges = [Range<Int>]()
        var importMapRanges = [Range<Int>]()
        var hasAuthoredBase = false
        var index = 0
        var templateDepth = 0

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
            guard let tagEnd = endOfTag(bytes, from: cursor) else { return nil }
            index = tagEnd + 1

            if isClosing {
                if name == "template", templateDepth > 0 { templateDepth -= 1 }
                continue
            }
            let openingTag = String(decoding: bytes[tagStart...tagEnd], as: UTF8.self)
            if templateDepth == 0, name == "base" {
                hasAuthoredBase = true
            }
            for literal in htmlAttributeLiterals(
                bytes,
                nameEnd: cursor,
                tagEnd: tagEnd,
                allowedNames: stagingAttributeNames
            ) {
                switch literal.name {
                case "srcset", "imagesrcset":
                    sourceSetAttributes.append(literal)
                case "style":
                    inlineStyleRanges.append(literal.utf8ContentRange)
                default:
                    resourceAttributes.append(literal)
                }
            }

            if name == "template" {
                templateDepth += 1
                continue
            }
            guard rawTextNames.contains(name) else { continue }
            guard name != "plaintext" else { break }
            if let closingTag = closingTagBounds(bytes, name: name, from: index) {
                if templateDepth == 0,
                   name == "script",
                   isImportMapScript(openingTag),
                   attribute("src", in: openingTag) == nil {
                    importMapRanges.append(index..<closingTag.contentEnd)
                }
                if templateDepth == 0,
                   name == "style",
                   isCSSInlineStyle(openingTag) {
                    inlineStyleRanges.append(index..<closingTag.contentEnd)
                }
                index = closingTag.afterClosingTag
            } else {
                if templateDepth == 0,
                   name == "script",
                   isImportMapScript(openingTag),
                   attribute("src", in: openingTag) == nil {
                    importMapRanges.append(index..<bytes.count)
                }
                if templateDepth == 0,
                   name == "style",
                   isCSSInlineStyle(openingTag) {
                    inlineStyleRanges.append(index..<bytes.count)
                }
                index = bytes.count
            }
        }
        return WebHTMLStagingReferenceScan(
            hasAuthoredBase: hasAuthoredBase,
            resourceAttributes: resourceAttributes,
            sourceSetAttributes: sourceSetAttributes,
            inlineStyleUTF8Ranges: inlineStyleRanges,
            importMapUTF8Ranges: importMapRanges
        )
    }

    private func htmlAttributeLiterals(
        _ bytes: [UInt8],
        nameEnd: Int,
        tagEnd: Int,
        allowedNames: Set<String>
    ) -> [WebHTMLAttributeLiteral] {
        var literals = [WebHTMLAttributeLiteral]()
        var index = nameEnd
        while index < tagEnd {
            while index < tagEnd,
                  isHTMLWhitespace(bytes[index]) || bytes[index] == 0x2F {
                index += 1
            }
            guard index < tagEnd else { break }
            let attributeStart = index
            while index < tagEnd,
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
            let name = asciiLowercased(bytes[attributeStart..<index])
            while index < tagEnd, isHTMLWhitespace(bytes[index]) { index += 1 }
            guard index < tagEnd, bytes[index] == 0x3D else { continue }
            index += 1
            while index < tagEnd, isHTMLWhitespace(bytes[index]) { index += 1 }
            guard index < tagEnd else { continue }
            let valueStart: Int
            let valueEnd: Int
            if bytes[index] == 0x22 || bytes[index] == 0x27 {
                let quote = bytes[index]
                index += 1
                valueStart = index
                while index < tagEnd, bytes[index] != quote { index += 1 }
                valueEnd = index
                if index < tagEnd { index += 1 }
            } else {
                valueStart = index
                while index < tagEnd,
                      !isHTMLWhitespace(bytes[index]),
                      bytes[index] != 0x3E {
                    index += 1
                }
                valueEnd = index
            }
            guard allowedNames.contains(name) else { continue }
            let reference = String(decoding: bytes[valueStart..<valueEnd], as: UTF8.self)
            literals.append(
                WebHTMLAttributeLiteral(
                    name: name,
                    reference: reference,
                    utf8ContentRange: valueStart..<valueEnd
                )
            )
        }
        return literals
    }

    private func javaScriptDependencies(in source: String, limit: Int) -> DependencyScanResult {
        let bytes = Array(source.utf8)
        var references = [String]()
        var moduleLiterals = [WebJavaScriptModuleLiteral]()
        var networkReferences = [String]()
        var mediaReferences = [JavaScriptMediaReference]()
        var hasOpaqueOrDynamicMediaReferences = false
        var hasOpaqueOrDynamicNetworkReferences = false
        var xmlHTTPRequestReceivers = Set<String>()
        var usesInteraction = false
        var scannedReferenceCount = 0
        var limitExceeded = false
        _ = scanJavaScript(
            bytes,
            from: 0,
            stopAtClosingBrace: false,
            nestingDepth: 0,
            limit: limit,
            references: &references,
            moduleLiterals: &moduleLiterals,
            networkReferences: &networkReferences,
            mediaReferences: &mediaReferences,
            hasOpaqueOrDynamicMediaReferences: &hasOpaqueOrDynamicMediaReferences,
            hasOpaqueOrDynamicNetworkReferences: &hasOpaqueOrDynamicNetworkReferences,
            xmlHTTPRequestReceivers: &xmlHTTPRequestReceivers,
            usesInteraction: &usesInteraction,
            scannedReferenceCount: &scannedReferenceCount,
            limitExceeded: &limitExceeded
        )
        return DependencyScanResult(
            references: Array(references.prefix(max(limit, 0))),
            networkReferences: Array(networkReferences.prefix(max(limit, 0))),
            mediaReferences: Array(mediaReferences.prefix(max(limit, 0))),
            hasOpaqueOrDynamicMediaReferences: hasOpaqueOrDynamicMediaReferences,
            hasOpaqueOrDynamicNetworkReferences: hasOpaqueOrDynamicNetworkReferences,
            usesInteraction: usesInteraction,
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
        moduleLiterals: inout [WebJavaScriptModuleLiteral],
        networkReferences: inout [String],
        mediaReferences: inout [JavaScriptMediaReference],
        hasOpaqueOrDynamicMediaReferences: inout Bool,
        hasOpaqueOrDynamicNetworkReferences: inout Bool,
        xmlHTTPRequestReceivers: inout Set<String>,
        usesInteraction: inout Bool,
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
                    moduleLiterals: &moduleLiterals,
                    networkReferences: &networkReferences,
                    mediaReferences: &mediaReferences,
                    hasOpaqueOrDynamicMediaReferences: &hasOpaqueOrDynamicMediaReferences,
                    hasOpaqueOrDynamicNetworkReferences:
                        &hasOpaqueOrDynamicNetworkReferences,
                    xmlHTTPRequestReceivers: &xmlHTTPRequestReceivers,
                    usesInteraction: &usesInteraction,
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
            if byte == 0x5B,
               !expectsExpression,
               javaScriptBracketUsesInteraction(bytes, from: index) {
                usesInteraction = true
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
            if previousSignificantByte != 0x2E,
               javaScriptIdentifierIsAssignedXMLHTTPRequest(
                   bytes,
                   identifierEnd: token.end
               ) {
                xmlHTTPRequestReceivers.insert(token.value)
            }
            if previousSignificantByte == 0x2E {
                if javaScriptMemberUsesInteraction(
                    bytes,
                    memberName: token.value,
                    afterMemberName: token.end
                ) {
                    usesInteraction = true
                }
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
                let networkExpression: JavaScriptMediaExpression?
                let memberReceiver = javaScriptImmediateMemberReceiver(
                    bytes,
                    memberNameStart: index
                )
                switch token.value {
                case "fetch" where ["globalThis", "self", "window"].contains(
                    memberReceiver ?? ""
                ):
                    networkExpression = javaScriptFirstCallArgument(
                        bytes,
                        afterFunctionName: token.end
                    )
                case "sendBeacon" where memberReceiver == "navigator":
                    networkExpression = javaScriptFirstCallArgument(
                        bytes,
                        afterFunctionName: token.end
                    )
                case "open" where memberReceiver.map(xmlHTTPRequestReceivers.contains) == true:
                    networkExpression = javaScriptXHRRequestURL(
                        bytes,
                        afterMemberName: token.end
                    )
                default:
                    networkExpression = nil
                }
                if let networkExpression {
                    recordJavaScriptNetworkExpression(
                        networkExpression,
                        limit: limit,
                        networkReferences: &networkReferences,
                        hasOpaqueOrDynamicNetworkReferences:
                            &hasOpaqueOrDynamicNetworkReferences,
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
            if token.value == "addEventListener",
               javaScriptMemberUsesInteraction(
                   bytes,
                   memberName: token.value,
                   afterMemberName: token.end
               ) {
                usesInteraction = true
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
            if token.value == "fetch",
               let networkExpression = javaScriptFirstCallArgument(
                   bytes,
                   afterFunctionName: token.end
               ) {
                recordJavaScriptNetworkExpression(
                    networkExpression,
                    limit: limit,
                    networkReferences: &networkReferences,
                    hasOpaqueOrDynamicNetworkReferences:
                        &hasOpaqueOrDynamicNetworkReferences,
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
            if token.value == "new",
               let networkSource = javaScriptNewNetworkSource(
                   bytes,
                   afterNewKeyword: token.end
               ) {
                recordJavaScriptNetworkExpression(
                    networkSource.expression,
                    limit: limit,
                    networkReferences: &networkReferences,
                    hasOpaqueOrDynamicNetworkReferences:
                        &hasOpaqueOrDynamicNetworkReferences,
                    scannedReferenceCount: &scannedReferenceCount,
                    limitExceeded: &limitExceeded
                )
                if networkSource.requiresRuntimeProbe {
                    // Worker scripts execute their own dependency graph. The
                    // bounded document/module probe does not recursively
                    // execute worker loading semantics, so never claim Full
                    // merely because the worker entrypoint itself exists.
                    hasOpaqueOrDynamicNetworkReferences = true
                }
                if limitExceeded { return bytes.count }
            }
            if token.value == "import",
               javaScriptDynamicImportIsOpaque(bytes, afterKeyword: token.end) {
                recordJavaScriptNetworkExpression(
                    .opaque,
                    limit: limit,
                    networkReferences: &networkReferences,
                    hasOpaqueOrDynamicNetworkReferences:
                        &hasOpaqueOrDynamicNetworkReferences,
                    scannedReferenceCount: &scannedReferenceCount,
                    limitExceeded: &limitExceeded
                )
                if limitExceeded { return bytes.count }
            }
            let parsed: ParsedJavaScriptModuleReference?
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
                if let literalContentRange = parsed.literalContentRange {
                    moduleLiterals.append(
                        WebJavaScriptModuleLiteral(
                            reference: reference,
                            utf8ContentRange: literalContentRange
                        )
                    )
                }
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

    private func recordJavaScriptNetworkExpression(
        _ expression: JavaScriptMediaExpression,
        limit: Int,
        networkReferences: inout [String],
        hasOpaqueOrDynamicNetworkReferences: inout Bool,
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
            networkReferences.append(reference)
        case .opaque:
            hasOpaqueOrDynamicNetworkReferences = true
        }
    }

    private func javaScriptFirstCallArgument(
        _ bytes: [UInt8],
        afterFunctionName start: Int
    ) -> JavaScriptMediaExpression? {
        var cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] == 0x28 else { return nil }
        cursor = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] != 0x29 else { return .opaque }
        return javaScriptMediaValue(bytes, from: cursor)
    }

    private func javaScriptDynamicImportIsOpaque(
        _ bytes: [UInt8],
        afterKeyword start: Int
    ) -> Bool {
        var cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] == 0x28 else { return false }
        cursor = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
        guard let literal = javaScriptString(bytes, from: cursor) else { return true }
        let afterLiteral = indexAfterJavaScriptTrivia(bytes, from: literal.end) ?? bytes.count
        return afterLiteral >= bytes.count
            || (bytes[afterLiteral] != 0x29 && bytes[afterLiteral] != 0x2C)
    }

    private func javaScriptIdentifierIsAssignedXMLHTTPRequest(
        _ bytes: [UInt8],
        identifierEnd: Int
    ) -> Bool {
        var cursor = indexAfterJavaScriptTrivia(bytes, from: identifierEnd) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] == 0x3D else { return false }
        if cursor + 1 < bytes.count,
           bytes[cursor + 1] == 0x3D || bytes[cursor + 1] == 0x3E {
            return false
        }
        cursor = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
        guard cursor < bytes.count, isJavaScriptIdentifierStart(bytes[cursor]) else {
            return false
        }
        let newKeyword = javascriptIdentifier(bytes, from: cursor)
        guard newKeyword.value == "new" else { return false }
        cursor = indexAfterJavaScriptTrivia(bytes, from: newKeyword.end) ?? bytes.count
        guard cursor < bytes.count, isJavaScriptIdentifierStart(bytes[cursor]) else {
            return false
        }
        var constructor = javascriptIdentifier(bytes, from: cursor)
        if ["globalThis", "self", "window"].contains(constructor.value) {
            cursor = indexAfterJavaScriptTrivia(bytes, from: constructor.end) ?? bytes.count
            guard cursor < bytes.count, bytes[cursor] == 0x2E else { return false }
            cursor = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
            guard cursor < bytes.count, isJavaScriptIdentifierStart(bytes[cursor]) else {
                return false
            }
            constructor = javascriptIdentifier(bytes, from: cursor)
        }
        guard constructor.value == "XMLHttpRequest" else { return false }
        cursor = indexAfterJavaScriptTrivia(bytes, from: constructor.end) ?? bytes.count
        return cursor < bytes.count && bytes[cursor] == 0x28
    }

    private func javaScriptImmediateMemberReceiver(
        _ bytes: [UInt8],
        memberNameStart: Int
    ) -> String? {
        var cursor = memberNameStart
        while cursor > 0, isJavaScriptWhitespace(bytes[cursor - 1]) { cursor -= 1 }
        guard cursor > 0, bytes[cursor - 1] == 0x2E else { return nil }
        cursor -= 1
        while cursor > 0, isJavaScriptWhitespace(bytes[cursor - 1]) { cursor -= 1 }
        if cursor > 0, bytes[cursor - 1] == 0x3F {
            cursor -= 1
            while cursor > 0, isJavaScriptWhitespace(bytes[cursor - 1]) { cursor -= 1 }
        }
        let end = cursor
        while cursor > 0, isJavaScriptIdentifierByte(bytes[cursor - 1]) { cursor -= 1 }
        guard cursor < end, isJavaScriptIdentifierStart(bytes[cursor]) else { return nil }
        return String(decoding: bytes[cursor..<end], as: UTF8.self)
    }

    private func javaScriptXHRRequestURL(
        _ bytes: [UInt8],
        afterMemberName start: Int
    ) -> JavaScriptMediaExpression? {
        var cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] == 0x28 else { return nil }
        cursor = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
        let method = javaScriptString(bytes, from: cursor)
        guard cursor < bytes.count, bytes[cursor] != 0x29,
              let delimiter = javaScriptCallArgumentDelimiter(bytes, from: cursor),
              bytes[delimiter] == 0x2C else { return nil }
        cursor = delimiter
        cursor = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] != 0x29 else { return .opaque }
        let requestURL = javaScriptMediaValue(bytes, from: cursor)

        if let method {
            let knownMethods: Set<String> = [
                "CONNECT", "DELETE", "GET", "HEAD", "LOCK", "MKCOL", "MOVE",
                "OPTIONS", "PATCH", "POST", "PROPFIND", "PROPPATCH", "PUT",
                "REPORT", "SEARCH", "TRACE", "UNLOCK"
            ]
            let isKnownMethod = knownMethods.contains(method.value.uppercased())
            switch requestURL {
            case .literal(let reference):
                guard isKnownMethod
                        || (isHTTPToken(method.value)
                            && isLikelyRuntimeResourceReference(reference)) else {
                    return nil
                }
            case .opaque:
                // With no visible URL, require a recognizable method so an
                // arbitrary `dialog.open("READ", value)` does not become an
                // opaque network dependency.
                guard isKnownMethod else { return nil }
            }
            return requestURL
        }
        // A dynamic method is common (`xhr.open(method, url)`), but `.open`
        // also belongs to Window, dialogs, databases and arbitrary libraries.
        // Only claim a statically visible second argument when it has URL/path
        // syntax; this keeps `window.open(url, "_blank")` out of XHR analysis.
        guard case .literal(let reference) = requestURL,
              isLikelyRuntimeResourceReference(reference) else {
            return nil
        }
        return requestURL
    }

    private func isHTTPToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let bytes = Array(value.utf8)
        guard bytes.allSatisfy({ byte in
            (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte)
                || (0x30...0x39).contains(byte)
                || [0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B,
                    0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E].contains(byte)
        }) else {
            return false
        }
        return true
    }

    private func isLikelyRuntimeResourceReference(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/")
            || trimmed.hasPrefix("./") || trimmed.hasPrefix("../") {
            return true
        }
        if let scheme = URL(string: trimmed)?.scheme?.lowercased(),
           ["http", "https", "ws", "wss"].contains(scheme) {
            return true
        }
        return !URL(filePath: trimmed).pathExtension.isEmpty
    }

    private func javaScriptCallArgumentDelimiter(_ bytes: [UInt8], from start: Int) -> Int? {
        var cursor = start
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        while cursor < bytes.count {
            cursor = indexAfterJavaScriptTrivia(bytes, from: cursor) ?? bytes.count
            guard cursor < bytes.count else { return nil }
            let byte = bytes[cursor]
            if byte == 0x22 || byte == 0x27 {
                cursor = indexAfterQuotedLiteral(bytes, from: cursor)
                continue
            }
            if byte == 0x60 {
                cursor = indexAfterTemplateLiteral(bytes, from: cursor)
                continue
            }
            switch byte {
            case 0x28:
                parenthesisDepth += 1
            case 0x29 where parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0:
                return cursor
            case 0x29:
                parenthesisDepth = max(0, parenthesisDepth - 1)
            case 0x5B:
                bracketDepth += 1
            case 0x5D:
                bracketDepth = max(0, bracketDepth - 1)
            case 0x7B:
                braceDepth += 1
            case 0x7D:
                braceDepth = max(0, braceDepth - 1)
            case 0x2C where parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0:
                return cursor
            default:
                break
            }
            cursor += 1
        }
        return nil
    }

    private func javaScriptNewNetworkSource(
        _ bytes: [UInt8],
        afterNewKeyword start: Int
    ) -> (expression: JavaScriptMediaExpression, requiresRuntimeProbe: Bool)? {
        var cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count, isJavaScriptIdentifierStart(bytes[cursor]) else {
            return nil
        }
        var constructor = javascriptIdentifier(bytes, from: cursor)
        if ["globalThis", "self", "window"].contains(constructor.value) {
            cursor = indexAfterJavaScriptTrivia(bytes, from: constructor.end) ?? bytes.count
            guard cursor < bytes.count, bytes[cursor] == 0x2E else { return nil }
            cursor = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
            guard cursor < bytes.count, isJavaScriptIdentifierStart(bytes[cursor]) else {
                return nil
            }
            constructor = javascriptIdentifier(bytes, from: cursor)
        }
        let supportedConstructors = ["EventSource", "SharedWorker", "WebSocket", "Worker"]
        guard supportedConstructors.contains(constructor.value) else {
            return nil
        }
        cursor = indexAfterJavaScriptTrivia(bytes, from: constructor.end) ?? bytes.count
        guard let expression = javaScriptFirstCallArgument(
            bytes,
            afterFunctionName: cursor
        ) else {
            return nil
        }
        return (
            expression,
            constructor.value == "Worker" || constructor.value == "SharedWorker"
        )
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

    private func javaScriptMemberUsesInteraction(
        _ bytes: [UInt8],
        memberName: String,
        afterMemberName start: Int
    ) -> Bool {
        if memberName == "addEventListener" || memberName == "on" {
            var cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
            guard cursor < bytes.count, bytes[cursor] == 0x28 else { return false }
            cursor = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
            if memberName == "on", cursor < bytes.count, bytes[cursor] == 0x7B {
                return javaScriptEventMapUsesInteraction(bytes, from: cursor)
            }
            guard let eventLiteral = javaScriptStaticEventLiteral(bytes, from: cursor) else {
                return false
            }
            return interactionEventListContainsSupportedEvent(eventLiteral.value)
        }

        let lowercased = memberName.lowercased()
        if Self.jqueryInteractionMethodNames.contains(lowercased) {
            var cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
            guard cursor < bytes.count, bytes[cursor] == 0x28 else { return false }
            cursor = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
            // Native `HTMLElement.click()` and similarly named library methods
            // can be invoked with no handler and do not make a wallpaper depend
            // on user input. jQuery's deprecated event shorthands register a
            // handler only when at least one argument is present.
            return cursor < bytes.count && bytes[cursor] != 0x29
        }

        guard lowercased.hasPrefix("on"),
              Self.interactionEventNames.contains(String(lowercased.dropFirst(2))) else {
            return false
        }
        let cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] == 0x3D else { return false }
        return cursor + 1 >= bytes.count
            || (bytes[cursor + 1] != 0x3D && bytes[cursor + 1] != 0x3E)
    }

    private func javaScriptBracketUsesInteraction(_ bytes: [UInt8], from start: Int) -> Bool {
        guard start < bytes.count, bytes[start] == 0x5B else { return false }
        var cursor = indexAfterJavaScriptTrivia(bytes, from: start + 1) ?? bytes.count
        guard let property = javaScriptStaticEventLiteral(bytes, from: cursor) else { return false }
        let lowercased = property.value.lowercased()
        guard lowercased.hasPrefix("on"),
              Self.interactionEventNames.contains(String(lowercased.dropFirst(2))) else {
            return false
        }
        cursor = indexAfterJavaScriptTrivia(bytes, from: property.end) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] == 0x5D else { return false }
        cursor = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
        guard cursor < bytes.count, bytes[cursor] == 0x3D else { return false }
        return cursor + 1 >= bytes.count
            || (bytes[cursor + 1] != 0x3D && bytes[cursor + 1] != 0x3E)
    }

    private func javaScriptStaticEventLiteral(
        _ bytes: [UInt8],
        from start: Int
    ) -> (value: String, end: Int)? {
        if let string = javaScriptString(bytes, from: start) { return string }
        guard start < bytes.count, bytes[start] == 0x60 else { return nil }
        var cursor = start + 1
        while cursor < bytes.count {
            if bytes[cursor] == 0x5C { return nil }
            if bytes[cursor] == 0x24,
               cursor + 1 < bytes.count,
               bytes[cursor + 1] == 0x7B {
                return nil
            }
            if bytes[cursor] == 0x60 {
                return (String(decoding: bytes[(start + 1)..<cursor], as: UTF8.self), cursor + 1)
            }
            cursor += 1
        }
        return nil
    }

    private func interactionEventListContainsSupportedEvent(_ value: String) -> Bool {
        value.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .contains { rawEvent in
                let eventName = rawEvent.split(separator: ".", maxSplits: 1).first
                    .map(String.init) ?? String(rawEvent)
                return Self.interactionEventNames.contains(eventName)
            }
    }

    private func javaScriptEventMapUsesInteraction(_ bytes: [UInt8], from start: Int) -> Bool {
        guard start < bytes.count, bytes[start] == 0x7B else { return false }
        var cursor = start + 1
        var braceDepth = 1
        var parenthesisDepth = 0
        var bracketDepth = 0
        var expectsKey = true
        while cursor < bytes.count, braceDepth > 0 {
            cursor = indexAfterJavaScriptTrivia(bytes, from: cursor) ?? bytes.count
            guard cursor < bytes.count else { break }
            let isTopLevel = braceDepth == 1 && parenthesisDepth == 0 && bracketDepth == 0
            if isTopLevel, expectsKey {
                let key: (value: String, end: Int)?
                if let literal = javaScriptString(bytes, from: cursor) {
                    key = literal
                } else if isJavaScriptIdentifierStart(bytes[cursor]) {
                    let identifier = javascriptIdentifier(bytes, from: cursor)
                    key = (identifier.value, identifier.end)
                } else {
                    key = nil
                }
                if let key {
                    let afterKey = indexAfterJavaScriptTrivia(bytes, from: key.end) ?? bytes.count
                    if afterKey < bytes.count, bytes[afterKey] == 0x3A,
                       interactionEventListContainsSupportedEvent(key.value) {
                        return true
                    }
                    cursor = key.end
                    expectsKey = false
                    continue
                }
            }
            let byte = bytes[cursor]
            if byte == 0x22 || byte == 0x27 {
                cursor = indexAfterQuotedLiteral(bytes, from: cursor)
                continue
            }
            if byte == 0x60 {
                cursor = indexAfterTemplateLiteral(bytes, from: cursor)
                continue
            }
            switch byte {
            case 0x7B:
                braceDepth += 1
            case 0x7D:
                braceDepth -= 1
            case 0x28:
                parenthesisDepth += 1
            case 0x29:
                parenthesisDepth = max(0, parenthesisDepth - 1)
            case 0x5B:
                bracketDepth += 1
            case 0x5D:
                bracketDepth = max(0, bracketDepth - 1)
            case 0x2C where isTopLevel:
                expectsKey = true
            default:
                break
            }
            cursor += 1
        }
        return false
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
        moduleLiterals: inout [WebJavaScriptModuleLiteral],
        networkReferences: inout [String],
        mediaReferences: inout [JavaScriptMediaReference],
        hasOpaqueOrDynamicMediaReferences: inout Bool,
        hasOpaqueOrDynamicNetworkReferences: inout Bool,
        xmlHTTPRequestReceivers: inout Set<String>,
        usesInteraction: inout Bool,
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
                    moduleLiterals: &moduleLiterals,
                    networkReferences: &networkReferences,
                    mediaReferences: &mediaReferences,
                    hasOpaqueOrDynamicMediaReferences: &hasOpaqueOrDynamicMediaReferences,
                    hasOpaqueOrDynamicNetworkReferences:
                        &hasOpaqueOrDynamicNetworkReferences,
                    xmlHTTPRequestReceivers: &xmlHTTPRequestReceivers,
                    usesInteraction: &usesInteraction,
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
    ) -> ParsedJavaScriptModuleReference {
        let cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count else { return .init(nil, end: cursor) }
        if bytes[cursor] == 0x2E { // import.meta
            return .init(nil, end: cursor + 1)
        }
        if bytes[cursor] == 0x28 { // import("literal")
            let literalStart = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
            guard let literal = javaScriptString(bytes, from: literalStart) else {
                return .init(nil, end: max(literalStart, cursor + 1))
            }
            let afterLiteral = indexAfterJavaScriptTrivia(bytes, from: literal.end) ?? bytes.count
            guard afterLiteral < bytes.count,
                  bytes[afterLiteral] == 0x29 || bytes[afterLiteral] == 0x2C else {
                return .init(nil, end: afterLiteral)
            }
            return .init(
                literal.value,
                end: afterLiteral + 1,
                literalContentRange: (literalStart + 1)..<(literal.end - 1)
            )
        }
        if let literal = javaScriptString(bytes, from: cursor) {
            return .init(
                literal.value,
                end: literal.end,
                literalContentRange: (cursor + 1)..<(literal.end - 1)
            )
        }
        return javaScriptFromReference(bytes, afterKeyword: cursor)
    }

    private func javaScriptExportReference(
        _ bytes: [UInt8],
        afterKeyword start: Int
    ) -> ParsedJavaScriptModuleReference {
        var cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count else { return .init(nil, end: cursor) }

        if bytes[cursor] == 0x2A { // export * [as name] from "module"
            cursor = indexAfterJavaScriptTrivia(bytes, from: cursor + 1) ?? bytes.count
            if cursor < bytes.count, isJavaScriptIdentifierStart(bytes[cursor]) {
                let token = javascriptIdentifier(bytes, from: cursor)
                if token.value == "as" {
                    cursor = indexAfterJavaScriptTrivia(bytes, from: token.end) ?? bytes.count
                    guard cursor < bytes.count,
                          isJavaScriptIdentifierStart(bytes[cursor]) else {
                        return .init(nil, end: cursor)
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
            return .init(nil, end: start)
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
        guard depth == 0 else { return .init(nil, end: cursor) }
        return javaScriptModuleSpecifier(bytes, fromKeywordAt: cursor)
    }

    private func javaScriptModuleSpecifier(
        _ bytes: [UInt8],
        fromKeywordAt start: Int
    ) -> ParsedJavaScriptModuleReference {
        let cursor = indexAfterJavaScriptTrivia(bytes, from: start) ?? bytes.count
        guard cursor < bytes.count, isJavaScriptIdentifierStart(bytes[cursor]) else {
            return .init(nil, end: cursor)
        }
        let token = javascriptIdentifier(bytes, from: cursor)
        guard token.value == "from" else { return .init(nil, end: cursor) }
        let literalStart = indexAfterJavaScriptTrivia(bytes, from: token.end) ?? bytes.count
        guard let literal = javaScriptString(bytes, from: literalStart) else {
            return .init(nil, end: literalStart)
        }
        return .init(
            literal.value,
            end: literal.end,
            literalContentRange: (literalStart + 1)..<(literal.end - 1)
        )
    }

    private func javaScriptFromReference(
        _ bytes: [UInt8],
        afterKeyword start: Int
    ) -> ParsedJavaScriptModuleReference {
        var cursor = start
        var delimiterDepth = 0
        while cursor < bytes.count {
            cursor = indexAfterJavaScriptTrivia(bytes, from: cursor) ?? bytes.count
            guard cursor < bytes.count else { break }
            let byte = bytes[cursor]
            if byte == 0x3B, delimiterDepth == 0 { // ;
                return .init(nil, end: cursor + 1)
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
                        return .init(nil, end: literalStart)
                    }
                    return .init(
                        literal.value,
                        end: literal.end,
                        literalContentRange: (literalStart + 1)..<(literal.end - 1)
                    )
                }
                if (token.value == "import" || token.value == "export"),
                   token.end != start,
                   delimiterDepth == 0 {
                    return .init(nil, end: cursor)
                }
                cursor = token.end
                continue
            }
            cursor += 1
        }
        return .init(nil, end: cursor)
    }

    /// Returns only concrete CSS `url(...)` and `@import` literals found by
    /// the same comment/string-aware parser used by dependency analysis.
    /// Escaped literals remain visible to analysis but callers can decline to
    /// rewrite them by comparing the authored bytes with `reference`.
    func stylesheetLiteralsForStaging(
        in source: String
    ) -> [WebCSSReferenceLiteral]? {
        let bytes = Array(source.utf8)
        var literals = [WebCSSReferenceLiteral]()
        var index = 0
        while index < bytes.count {
            if hasASCIIPrefix(bytes, at: index, literal: "/*") {
                index = indexAfterASCIISequence(bytes, from: index + 2, literal: "*/")
                    ?? bytes.count
                continue
            }
            let byte = bytes[index]
            if byte == 0x22 || byte == 0x27 {
                index = indexAfterQuotedLiteral(bytes, from: index)
                continue
            }
            if hasASCIIPrefix(bytes, at: index, literal: "url", caseInsensitive: true),
               (index == 0 || !isCSSIdentifierByte(bytes[index - 1])) {
                let parsed = cssURLReference(bytes, at: index)
                if let reference = parsed.reference,
                   let literalContentRange = parsed.literalContentRange {
                    literals.append(
                        WebCSSReferenceLiteral(
                            reference: reference,
                            utf8ContentRange: literalContentRange
                        )
                    )
                    guard literals.count <= Self.maximumReferencesPerFile else { return nil }
                    index = max(parsed.end, index + 1)
                    continue
                }
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
            if let reference = parsed.reference,
               let literalContentRange = parsed.literalContentRange {
                literals.append(
                    WebCSSReferenceLiteral(
                        reference: reference,
                        utf8ContentRange: literalContentRange
                    )
                )
                guard literals.count <= Self.maximumReferencesPerFile else { return nil }
            }
        }
        return literals
    }

    /// Mirrors the loopback server's path-segment policy before a virtual
    /// package-root URL is classified as local or rewritten on staging.
    /// Encoded separators, dot segments, controls, and empty interior
    /// segments must remain fail-closed because the server rejects them.
    func isSafeProjectRootReferenceForStaging(_ reference: String) -> Bool {
        guard reference.hasPrefix("/"),
              !reference.hasPrefix("//"),
              isSafeAuthoredLocalReference(reference) else {
            return false
        }
        return true
    }

    private func isSafeAuthoredLocalReference(_ reference: String) -> Bool {
        guard !reference.isEmpty,
              !reference.contains("\\"),
              !reference.unicodeScalars.contains(where: {
                  $0.value <= 0x1F || $0.value == 0x7F
              }) else {
            return false
        }
        let pathEnd = [reference.firstIndex(of: "?"), reference.firstIndex(of: "#")]
            .compactMap { $0 }
            .min() ?? reference.endIndex
        let encodedPath = String(reference[..<pathEnd])
        if encodedPath.isEmpty { return reference.hasPrefix("?") }
        let segments = encodedPath.split(separator: "/", omittingEmptySubsequences: false)
        for (index, segment) in segments.enumerated() {
            if segment.isEmpty {
                let isAbsoluteMarker = index == 0 && reference.hasPrefix("/")
                let isTrailingDirectoryMarker = index == segments.count - 1 && index > 0
                guard isAbsoluteMarker || isTrailingDirectoryMarker else { return false }
                continue
            }
            if segment == "." || segment == ".." { continue }
            guard let decoded = String(segment).removingPercentEncoding,
                  !decoded.isEmpty,
                  decoded != ".",
                  decoded != "..",
                  !decoded.contains("/"),
                  !decoded.contains("\\"),
                  !decoded.unicodeScalars.contains(where: {
                      $0.value <= 0x1F || $0.value == 0x7F
                  }) else {
                return false
            }
        }
        return true
    }

    private func stylesheetDependencies(in source: String, limit: Int) -> DependencyScanResult {
        let bytes = Array(source.utf8)
        let usesInteraction = stylesheetUsesInteraction(bytes)
        var references = [String]()
        var resourceReferences = [String]()
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
            if hasASCIIPrefix(bytes, at: index, literal: "url", caseInsensitive: true),
               (index == 0 || !isCSSIdentifierByte(bytes[index - 1])) {
                let parsed = cssURLReference(bytes, at: index)
                if let reference = parsed.reference {
                    resourceReferences.append(reference)
                    if references.count + resourceReferences.count > limit {
                        return DependencyScanResult(
                            references: Array(references.prefix(limit)),
                            resourceReferences: Array(
                                resourceReferences.prefix(max(0, limit - references.count))
                            ),
                            usesInteraction: usesInteraction,
                            limitExceeded: true
                        )
                    }
                    index = max(parsed.end, index + 1)
                    continue
                }
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
                if references.count + resourceReferences.count > limit {
                    return DependencyScanResult(
                        references: Array(references.prefix(limit)),
                        resourceReferences: Array(
                            resourceReferences.prefix(max(0, limit - references.count))
                        ),
                        usesInteraction: usesInteraction,
                        limitExceeded: true
                    )
                }
            }
        }
        return DependencyScanResult(
            references: references,
            resourceReferences: resourceReferences,
            usesInteraction: usesInteraction,
            limitExceeded: false
        )
    }

    private func stylesheetUsesInteraction(_ bytes: [UInt8]) -> Bool {
        var cursor = 0
        while cursor < bytes.count {
            if hasASCIIPrefix(bytes, at: cursor, literal: "/*") {
                cursor = indexAfterASCIISequence(bytes, from: cursor + 2, literal: "*/")
                    ?? bytes.count
                continue
            }
            if bytes[cursor] == 0x22 || bytes[cursor] == 0x27 {
                cursor = indexAfterQuotedLiteral(bytes, from: cursor)
                continue
            }
            if bytes[cursor] == 0x5C {
                cursor = min(cursor + 2, bytes.count)
                continue
            }
            guard bytes[cursor] == 0x3A else {
                cursor += 1
                continue
            }
            let nameStart = cursor + 1
            var nameEnd = nameStart
            while nameEnd < bytes.count, isCSSIdentifierByte(bytes[nameEnd]) {
                nameEnd += 1
            }
            let name = asciiLowercased(bytes[nameStart..<nameEnd])
            if name == "hover" || name == "active" { return true }
            cursor = max(nameEnd, cursor + 1)
        }
        return false
    }

    private func cssImportReference(
        _ bytes: [UInt8],
        afterKeyword start: Int
    ) -> (reference: String?, end: Int, literalContentRange: Range<Int>?) {
        var cursor = indexAfterCSSTrivia(bytes, from: start)
        guard cursor < bytes.count else { return (nil, cursor, nil) }
        if let literal = javaScriptString(bytes, from: cursor) {
            return (literal.value, literal.end, (cursor + 1)..<(literal.end - 1))
        }
        guard hasASCIIPrefix(bytes, at: cursor, literal: "url", caseInsensitive: true) else {
            return (nil, cursor + 1, nil)
        }
        cursor += 3
        cursor = indexAfterCSSTrivia(bytes, from: cursor)
        guard cursor < bytes.count, bytes[cursor] == 0x28 else { return (nil, cursor, nil) }
        cursor = indexAfterCSSTrivia(bytes, from: cursor + 1)
        if let literal = javaScriptString(bytes, from: cursor) {
            return (literal.value, literal.end, (cursor + 1)..<(literal.end - 1))
        }
        let valueStart = cursor
        while cursor < bytes.count,
              bytes[cursor] != 0x29,
              !isHTMLWhitespace(bytes[cursor]) {
            cursor += 1
        }
        guard cursor > valueStart else { return (nil, cursor + 1, nil) }
        return (
            String(decoding: bytes[valueStart..<cursor], as: UTF8.self),
            cursor,
            valueStart..<cursor
        )
    }

    private func cssURLReference(
        _ bytes: [UInt8],
        at start: Int
    ) -> (reference: String?, end: Int, literalContentRange: Range<Int>?) {
        guard hasASCIIPrefix(bytes, at: start, literal: "url", caseInsensitive: true) else {
            return (nil, min(start + 1, bytes.count), nil)
        }
        var cursor = indexAfterCSSTrivia(bytes, from: start + 3)
        guard cursor < bytes.count, bytes[cursor] == 0x28 else {
            return (nil, cursor, nil)
        }
        cursor = indexAfterCSSTrivia(bytes, from: cursor + 1)
        if let literal = javaScriptString(bytes, from: cursor) {
            let closing = indexAfterCSSTrivia(bytes, from: literal.end)
            guard closing < bytes.count, bytes[closing] == 0x29 else {
                return (nil, closing, nil)
            }
            return (
                literal.value,
                closing + 1,
                (cursor + 1)..<(literal.end - 1)
            )
        }
        let valueStart = cursor
        while cursor < bytes.count, bytes[cursor] != 0x29 { cursor += 1 }
        guard cursor < bytes.count else { return (nil, cursor, nil) }
        var valueEnd = cursor
        while valueEnd > valueStart, isHTMLWhitespace(bytes[valueEnd - 1]) {
            valueEnd -= 1
        }
        guard valueEnd > valueStart else { return (nil, cursor + 1, nil) }
        return (
            String(decoding: bytes[valueStart..<valueEnd], as: UTF8.self),
            cursor + 1,
            valueStart..<valueEnd
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
            "base", "script", "link", "style", "video", "audio", "source", "iframe",
            "img", "picture"
        ]
        let rawTextNames: Set<String> = [
            "script", "style", "textarea", "title", "xmp", "iframe",
            "noembed", "noframes", "noscript", "plaintext"
        ]
        var elements = [DocumentDependencyElement]()
        var index = 0
        var templateDepth = 0
        var usesInteraction = false
        var mediaContainers = [DocumentMediaContainer]()
        var pictureContainers = [Int]()
        var nextMediaGroupID = 0
        var nextImageGroupID = 0

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
                } else if templateDepth == 0, name == "picture" {
                    _ = pictureContainers.popLast()
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
            if templateDepth == 0,
               hasHTMLInteractionAttribute(
                   in: String(decoding: bytes[tagStart...tagEnd], as: UTF8.self)
               ) {
                usesInteraction = true
            }
            var rawText: String?
            var rawTextUTF8Range: Range<Int>?
            if rawTextNames.contains(name) {
                guard name != "plaintext" else { break }
                if let closingTag = closingTagBounds(
                    bytes,
                    name: name,
                    from: index
                ) {
                    if templateDepth == 0, name == "script" || name == "style" {
                        rawTextUTF8Range = index..<closingTag.contentEnd
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
                    rawTextUTF8Range = index..<bytes.count
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
            let openingTag = String(decoding: bytes[tagStart...tagEnd], as: UTF8.self)
            if templateDepth == 0,
               dependencyNames.contains(name) || attribute("style", in: openingTag) != nil {
                guard elements.count < limit else {
                    return DocumentDependencyScanResult(
                        elements: elements,
                        usesInteraction: usesInteraction,
                        limitExceeded: true
                    )
                }
                let declaredMediaKind = WebMediaElementKind(rawValue: name)
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
                let imageGroupID: Int?
                if name == "img" {
                    imageGroupID = pictureContainers.last ?? nextImageGroupID
                    if pictureContainers.isEmpty { nextImageGroupID += 1 }
                } else if name == "source", attribute("srcset", in: openingTag) != nil {
                    imageGroupID = pictureContainers.last
                } else {
                    imageGroupID = nil
                }
                elements.append(
                    DocumentDependencyElement(
                        name: name,
                        openingTag: openingTag,
                        rawText: rawText,
                        rawTextUTF8Range: rawTextUTF8Range,
                        mediaContainer: name == WebMediaElementKind.source.rawValue
                            ? activeSourceContainer?.kind
                            : nil,
                        mediaGroupID: mediaGroupID,
                        imageGroupID: imageGroupID,
                        // A non-empty media query can make this source
                        // ineligible at the current display size. Keep the
                        // local reference available for runtime preparation,
                        // but do not use it as proof that a broken sibling has
                        // a playable fallback.
                        localMediaCanProveFallback: localMediaCanProveFallback
                    )
                )
                if name == "picture", !isSelfClosingTag(bytes[tagStart...tagEnd]) {
                    pictureContainers.append(nextImageGroupID)
                    nextImageGroupID += 1
                }
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
        return DocumentDependencyScanResult(
            elements: elements,
            usesInteraction: usesInteraction,
            limitExceeded: false
        )
    }

    private func documentBase(reference: String, entrypoint: URL) -> DocumentBase {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("{{"), !trimmed.contains("${") else {
            return .authored(entrypoint)
        }
        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        // Playback serves local projects from HTTP loopback. Protocol-relative
        // bases therefore inherit HTTP(S); resolving them against this probe's
        // file URL would incorrectly reinterpret the host as a file authority.
        if normalized.hasPrefix("//") {
            guard let resolved = URL(string: "https:" + normalized) else {
                return .invalid
            }
            return .authored(resolved)
        }
        guard let resolved = URL(string: normalized, relativeTo: entrypoint)?.absoluteURL else {
            return .invalid
        }
        return .authored(resolved)
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

    private func hasHTMLInteractionAttribute(in tag: String) -> Bool {
        let bytes = Array(tag.utf8)
        var index = 0
        guard index < bytes.count, bytes[index] == 0x3C else { return false }
        index += 1
        if index < bytes.count, bytes[index] == 0x2F { return false }
        while index < bytes.count, isTagNameByte(bytes[index]) { index += 1 }

        while index < bytes.count {
            while index < bytes.count,
                  isHTMLWhitespace(bytes[index]) || bytes[index] == 0x2F {
                index += 1
            }
            guard index < bytes.count, bytes[index] != 0x3E else { break }
            let nameStart = index
            while index < bytes.count,
                  !isHTMLWhitespace(bytes[index]),
                  bytes[index] != 0x3D,
                  bytes[index] != 0x2F,
                  bytes[index] != 0x3E {
                index += 1
            }
            guard index > nameStart else {
                index += 1
                continue
            }
            let name = asciiLowercased(bytes[nameStart..<index])
            if name.hasPrefix("on"),
               Self.interactionEventNames.contains(String(name.dropFirst(2))) {
                return true
            }
            while index < bytes.count, isHTMLWhitespace(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] == 0x3D else { continue }
            index += 1
            while index < bytes.count, isHTMLWhitespace(bytes[index]) { index += 1 }
            if index < bytes.count, bytes[index] == 0x22 || bytes[index] == 0x27 {
                let quote = bytes[index]
                index += 1
                while index < bytes.count, bytes[index] != quote { index += 1 }
                if index < bytes.count { index += 1 }
            } else {
                while index < bytes.count,
                      !isHTMLWhitespace(bytes[index]),
                      bytes[index] != 0x3E {
                    index += 1
                }
            }
        }
        return false
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
            guard let candidate = URL(string: "https:" + normalized) else {
                return .ignored
            }
            return WebWallpaperNetworkPolicy.isBlockedExternalURL(candidate)
                ? .blockedExternalNetwork
                : .externalNetwork
        }
        if ["http", "https", "ws", "wss"].contains(explicitScheme ?? "") {
            guard let candidate = URL(string: normalized) else { return .ignored }
            return WebWallpaperNetworkPolicy.isBlockedExternalURL(candidate)
                ? .blockedExternalNetwork
                : .externalNetwork
        }
        if explicitScheme == nil, !isSafeAuthoredLocalReference(trimmed) {
            return .missingLocal
        }
        if normalized.hasPrefix("/"),
           !isSafeProjectRootReferenceForStaging(normalized) {
            return .missingLocal
        }
        if normalized.hasPrefix("/"),
           case .authored(let baseURL) = base,
           ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
           context != .javaScriptResource {
            guard let candidate = URL(
                string: normalized,
                relativeTo: baseURL
            )?.absoluteURL else {
                return .missingLocal
            }
            return WebWallpaperNetworkPolicy.isBlockedExternalURL(candidate)
                ? .blockedExternalNetwork
                : .externalNetwork
        }
        if normalized.hasPrefix("/"),
           context != .javaScript,
           context != .javaScriptResource {
            // Static HTML and CSS are rewritten on the private Lively staging
            // graph. Any root sink that remains (escaped, oversized, srcdoc,
            // or otherwise ambiguous) would hit the tokenless loopback origin.
            // Dynamic JavaScript sinks are the only shape covered by the
            // document-start compatibility bridge.
            return .missingLocal
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
        case .authored where normalized.hasPrefix("/"):
            // A root-relative URL in a document with an authored `<base>` is
            // no longer provably rooted at the authenticated project prefix.
            // The Lively staging normalizer deliberately leaves this rare
            // shape untouched, so fail closed instead of promising playback
            // that would request a tokenless or remote origin.
            return .missingLocal
        case let .resolved(baseURL), let .authored(baseURL):
            // Lively and Wallpaper Engine serve local Web projects from a
            // virtual package origin. A single leading slash therefore means
            // "from the wallpaper project root", not from the host file
            // system root used by this static analyzer. Protocol-relative
            // references were classified above and never reach this branch.
            let resolutionBase: URL
            let reference: String
            if normalized.hasPrefix("/") {
                resolutionBase = URL(fileURLWithPath: root.path, isDirectory: true)
                reference = "." + normalized
            } else {
                resolutionBase = baseURL
                reference = normalized
            }
            guard let candidate = URL(string: reference, relativeTo: resolutionBase)?.absoluteURL else {
                return .missingLocal
            }
            if ["http", "https"].contains(candidate.scheme?.lowercased() ?? "") {
                return WebWallpaperNetworkPolicy.isBlockedExternalURL(candidate)
                    ? .blockedExternalNetwork
                    : .externalNetwork
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
