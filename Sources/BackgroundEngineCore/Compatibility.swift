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
    public static let currentProbeVersion = 7

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
    }
}

public struct WebRuntimeFeatureAnalyzer: Sendable {
    private enum DocumentBase {
        case resolved(URL)
        case invalid
    }

    private enum DependencyState {
        case available
        case missingLocal
        case externalNetwork
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
            missingLocalDependencies: dependencies.missingLocal,
            remoteDependencies: dependencies.remote
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

    /// Validates only static local script and stylesheet references from the
    /// entrypoint's bounded markup prefix. Missing images/fonts are allowed to
    /// degrade in WebKit, but a missing script or stylesheet commonly leaves
    /// an otherwise "playable" Web wallpaper completely blank. Remote/data
    /// URLs remain governed by the per-wallpaper network policy.
    private func criticalDependencies(
        entrypoint: URL,
        root: URL
    ) -> (missingLocal: [String], remote: [String]) {
        guard let values = try? entrypoint.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: entrypoint) else {
            return ([], [])
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: WebWallpaperValidation.maximumProbeBytes),
              !data.isEmpty,
              let source = WebWallpaperValidation.decodeTextPrefix(data) else {
            return ([], [])
        }
        let tags = dependencyTags(in: source, limit: 257)
        var effectiveBase = DocumentBase.resolved(entrypoint)
        var hasDocumentBase = false
        var missing = Set<String>()
        var remote = Set<String>()
        for tag in tags.prefix(256) {
            let lowercased = tag.lowercased()
            if lowercased.hasPrefix("<base"),
               !hasDocumentBase,
               let reference = attribute("href", in: tag) {
                effectiveBase = documentBase(reference: reference, entrypoint: entrypoint)
                hasDocumentBase = true
                continue
            }
            let reference: String?
            if lowercased.hasPrefix("<script") {
                reference = attribute("src", in: tag)
            } else if lowercased.hasPrefix("<link") {
                let relationships = attribute("rel", in: tag)?
                    .lowercased()
                    .split(whereSeparator: { $0.isWhitespace })
                    .map(String.init) ?? []
                reference = relationships.contains("stylesheet")
                    ? attribute("href", in: tag)
                    : nil
            } else {
                reference = nil
            }
            guard let reference else { continue }
            switch dependencyState(reference, base: effectiveBase, root: root) {
            case .available:
                break
            case .missingLocal:
                missing.insert(reference)
            case .externalNetwork:
                remote.insert(reference)
            }
        }
        return (missing.sorted(), remote.sorted())
    }

    private func dependencyTags(in source: String, limit: Int) -> [String] {
        let bytes = Array(source.utf8)
        let dependencyNames: Set<String> = ["base", "script", "link"]
        let rawTextNames: Set<String> = [
            "script", "style", "textarea", "title", "xmp", "iframe",
            "noembed", "noframes", "noscript", "plaintext"
        ]
        var tags = [String]()
        var index = 0
        var templateDepth = 0

        while index < bytes.count, tags.count < limit {
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
            if templateDepth == 0, dependencyNames.contains(name) {
                tags.append(String(decoding: bytes[tagStart...tagEnd], as: UTF8.self))
            }
            if rawTextNames.contains(name) {
                guard name != "plaintext",
                      let afterClosingTag = indexAfterClosingTag(
                          bytes,
                          name: name,
                          from: index
                      ) else {
                    break
                }
                index = afterClosingTag
            }
        }
        return tags
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

    private func indexAfterClosingTag(_ bytes: [UInt8], name: String, from start: Int) -> Int? {
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
            return tagEnd + 1
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

    private func dependencyState(
        _ rawReference: String,
        base: DocumentBase,
        root: URL
    ) -> DependencyState {
        let trimmed = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.contains("{{"),
              !trimmed.contains("${") else {
            return .available
        }
        switch base {
        case .invalid:
            return .missingLocal
        case let .resolved(baseURL):
            let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
            guard let candidate = URL(string: normalized, relativeTo: baseURL)?.absoluteURL else {
                return .missingLocal
            }
            if ["http", "https"].contains(candidate.scheme?.lowercased() ?? "") {
                return .externalNetwork
            }
            guard candidate.isFileURL else { return .available }
            let standardized = candidate.standardizedFileURL
            let resolved = standardized.resolvingSymlinksInPath()
            guard isInside(resolved, root: root),
                  let values = try? standardized.resourceValues(
                      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ), values.isRegularFile == true, values.isSymbolicLink != true else {
                return .missingLocal
            }
            return .available
        }
    }
}
