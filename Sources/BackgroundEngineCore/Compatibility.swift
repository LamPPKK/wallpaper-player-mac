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
    public static let currentProbeVersion = 8

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
        if RemoteWebWallpaperConfiguration.load(projectRoot: effectiveProjectRoot) != nil {
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
        let diagnosticCode: String?
        switch (features.usesAudioListener, features.usesMediaIntegration) {
        case (true, true): diagnosticCode = "web_realtime_integration_limited"
        case (true, false): diagnosticCode = "web_audio_reactive_limited"
        case (false, true): diagnosticCode = "web_media_integration_limited"
        case (false, false): diagnosticCode = nil
        }
        return CompatibilityReport(
            level: missingCapabilities.isEmpty ? .full : .limited,
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

public struct WebRuntimeFeatures: Equatable, Sendable {
    public let usesAudioListener: Bool
    public let usesMediaIntegration: Bool
    public let missingLocalDependencies: [String]
    public let remoteDependencies: [String]
    let dependencyAnalysisLimitExceeded: Bool

    public init(
        usesAudioListener: Bool = false,
        usesMediaIntegration: Bool = false,
        missingLocalDependencies: [String] = [],
        remoteDependencies: [String] = []
    ) {
        self.usesAudioListener = usesAudioListener
        self.usesMediaIntegration = usesMediaIntegration
        self.missingLocalDependencies = Array(Set(missingLocalDependencies)).sorted()
        self.remoteDependencies = Array(Set(remoteDependencies)).sorted()
        self.dependencyAnalysisLimitExceeded = false
    }

    init(
        usesAudioListener: Bool,
        usesMediaIntegration: Bool,
        missingLocalDependencies: [String],
        remoteDependencies: [String],
        dependencyAnalysisLimitExceeded: Bool
    ) {
        self.usesAudioListener = usesAudioListener
        self.usesMediaIntegration = usesMediaIntegration
        self.missingLocalDependencies = Array(Set(missingLocalDependencies)).sorted()
        self.remoteDependencies = Array(Set(remoteDependencies)).sorted()
        self.dependencyAnalysisLimitExceeded = dependencyAnalysisLimitExceeded
    }
}

public struct WebRuntimeFeatureAnalyzer: Sendable {
    static let maximumDependencyNodes = 2_000
    static let maximumDependencyTextBytes = 8 * 1_024 * 1_024
    static let maximumReferencesPerFile = 256
    static let maximumJavaScriptNestingDepth = 64
    static let maximumDocumentDependencyElements = maximumDependencyNodes

    private enum DocumentBase {
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
    }

    private struct DocumentDependencyElement {
        let name: String
        let openingTag: String
        let rawText: String?
    }

    private struct DocumentDependencyScanResult {
        let elements: [DocumentDependencyElement]
        let limitExceeded: Bool
    }

    private struct DependencyScanResult {
        let references: [String]
        let limitExceeded: Bool
    }

    private struct DependencyAnalysisResult {
        var missingLocal = Set<String>()
        var remote = Set<String>()
        var limitExceeded = false
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
            dependencyAnalysisLimitExceeded: dependencies.limitExceeded
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

    /// Walks only the dependency graph reachable from the entrypoint's scripts
    /// and stylesheets. This avoids treating unused files in a Workshop project
    /// as requirements while still finding load-blocking ES module and CSS
    /// imports that would otherwise leave an offline WKWebView blank.
    private func criticalDependencies(
        entrypoint: URL,
        root: URL
    ) -> DependencyAnalysisResult {
        var result = DependencyAnalysisResult()
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
        let documentScan = documentDependencyElements(
            in: source,
            limit: Self.maximumDocumentDependencyElements
        )
        guard !documentScan.limitExceeded else {
            result.limitExceeded = true
            return result
        }
        var effectiveBase = DocumentBase.resolved(entrypoint)
        var hasDocumentBase = false
        var referenceCount = 0
        var queue = [DependencyNode]()
        var discoveredPaths = Set([canonicalFileURL(entrypoint).path])
        for element in documentScan.elements {
            if element.name == "base",
               !hasDocumentBase,
               let reference = attribute("href", in: element.openingTag) {
                effectiveBase = documentBase(reference: reference, entrypoint: entrypoint)
                hasDocumentBase = true
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
                    return result
                }
                appendDependency(
                    dependency.reference,
                    base: effectiveBase,
                    context: .document,
                    kind: dependency.kind,
                    root: root,
                    result: &result,
                    queue: &queue,
                    discoveredPaths: &discoveredPaths
                )
                if result.limitExceeded { return result }
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
                return result
            }
            referenceCount += inlineScan.scan.references.count
            appendScannedDependencies(
                inlineScan.scan.references,
                base: effectiveBase,
                context: inlineScan.context,
                importer: entrypoint,
                root: root,
                result: &result,
                queue: &queue,
                discoveredPaths: &discoveredPaths
            )
            if result.limitExceeded { return result }
        }

        var totalTextBytes = data.count
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
                continue
            }
            let scan = switch node.kind {
            case .javaScript:
                javaScriptDependencies(
                    in: dependencySource,
                    limit: Self.maximumReferencesPerFile
                )
            case .stylesheet:
                stylesheetDependencies(
                    in: dependencySource,
                    limit: Self.maximumReferencesPerFile
                )
            }
            guard !scan.limitExceeded else {
                result.limitExceeded = true
                break
            }
            let context: DependencyReferenceContext = node.kind == .javaScript
                ? .javaScript
                : .stylesheet
            appendScannedDependencies(
                scan.references,
                base: .resolved(node.url),
                context: context,
                importer: node.url,
                root: root,
                result: &result,
                queue: &queue,
                discoveredPaths: &discoveredPaths
            )
            if result.limitExceeded { break }
        }
        return result
    }

    private func appendScannedDependencies(
        _ references: [String],
        base: DocumentBase,
        context: DependencyReferenceContext,
        importer: URL,
        root: URL,
        result: inout DependencyAnalysisResult,
        queue: inout [DependencyNode],
        discoveredPaths: inout Set<String>
    ) {
        for reference in references {
            let kind: DependencyFileKind?
            switch context {
            case .javaScript:
                let ext = dependencyPathExtension(reference, relativeTo: importer)
                kind = ["js", "mjs"].contains(ext) ? .javaScript : nil
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
                discoveredPaths: &discoveredPaths
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
        discoveredPaths: inout Set<String>
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
            guard discoveredPaths.insert(canonical.path).inserted else { return }
            guard discoveredPaths.count <= Self.maximumDependencyNodes else {
                result.limitExceeded = true
                return
            }
            if let kind {
                queue.append(DependencyNode(url: canonical, kind: kind))
            }
        }
    }

    private func canonicalFileURL(_ url: URL) -> URL {
        URL(filePath: url.path).standardizedFileURL.resolvingSymlinksInPath()
    }

    private func dependencyPathExtension(_ reference: String, relativeTo importer: URL) -> String {
        let normalized = reference.replacingOccurrences(of: "\\", with: "/")
        return URL(string: normalized, relativeTo: importer)?.absoluteURL.pathExtension.lowercased() ?? ""
    }

    private func javaScriptDependencies(in source: String, limit: Int) -> DependencyScanResult {
        let bytes = Array(source.utf8)
        var references = [String]()
        var limitExceeded = false
        _ = scanJavaScript(
            bytes,
            from: 0,
            stopAtClosingBrace: false,
            nestingDepth: 0,
            limit: limit,
            references: &references,
            limitExceeded: &limitExceeded
        )
        return DependencyScanResult(
            references: Array(references.prefix(max(limit, 0))),
            limitExceeded: limitExceeded || references.count > limit
        )
    }

    private func scanJavaScript(
        _ bytes: [UInt8],
        from start: Int,
        stopAtClosingBrace: Bool,
        nestingDepth: Int,
        limit: Int,
        references: inout [String],
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
                expectsExpression = false
                if references.count > limit {
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
        let dependencyNames: Set<String> = ["base", "script", "link", "style"]
        let rawTextNames: Set<String> = [
            "script", "style", "textarea", "title", "xmp", "iframe",
            "noembed", "noframes", "noscript", "plaintext"
        ]
        var elements = [DocumentDependencyElement]()
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
            guard let tagEnd = endOfTag(bytes, from: cursor) else { break }
            index = tagEnd + 1

            if isClosing {
                if name == "template", templateDepth > 0 {
                    templateDepth -= 1
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
                elements.append(
                    DocumentDependencyElement(
                        name: name,
                        openingTag: String(decoding: bytes[tagStart...tagEnd], as: UTF8.self),
                        rawText: rawText
                    )
                )
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
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
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
