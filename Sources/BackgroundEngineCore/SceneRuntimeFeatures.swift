import CoreFoundation
import Foundation

/// Wallpaper Engine lets a stored `visible.value` be overridden by a user
/// property (including a conditional user binding). Static analysis may
/// discard only layers that are provably hidden for every property value.
enum SceneVisibilitySemantics {
    static func isPotentiallyVisible(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        guard let dictionary = value as? [String: Any] else {
            return true
        }
        if hasDynamicBinding(dictionary) {
            return true
        }
        return dictionary["value"] as? Bool ?? true
    }

    /// Native approximation and authored-audio muxing cannot evaluate the
    /// renderer's user-property or SceneScript bindings. They honor the
    /// stored default instead of making a dynamically hidden layer visible.
    static func isStoredVisible(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        guard let dictionary = value as? [String: Any] else {
            return true
        }
        return dictionary["value"] as? Bool ?? true
    }

    /// `DynamicValueParser` recognizes `user` and `script`; conditional user
    /// settings are represented by an object in `user`. `condition` is kept
    /// as a conservative legacy form used by older exported projects.
    static func hasDynamicBinding(_ value: Any?) -> Bool {
        guard let dictionary = value as? [String: Any] else {
            return false
        }
        return ["user", "script", "condition"].contains { key in
            guard let value = dictionary[key] else { return false }
            return !(value is NSNull)
        }
    }
}

public struct SceneRuntimeLayerFeature: Codable, Equatable, Sendable {
    public let id: Int?
    public let name: String
    public let kind: String
    public let effectFiles: [String]
    public let scriptCount: Int
    public let constantShaderValueKeys: [String]

    public init(
        id: Int?,
        name: String,
        kind: String,
        effectFiles: [String] = [],
        scriptCount: Int = 0,
        constantShaderValueKeys: [String] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.effectFiles = effectFiles
        self.scriptCount = scriptCount
        self.constantShaderValueKeys = constantShaderValueKeys
    }
}

public struct SceneRuntimeFeatures: Codable, Equatable, Sendable {
    public let layers: [SceneRuntimeLayerFeature]
    public let materialFiles: [String]
    public let effectFiles: [String]
    public let shaderFiles: [String]
    public let textureFiles: [String]
    public let audioFiles: [String]
    public let videoFiles: [String]
    public let unreadableRequiredAssetFiles: [String]
    public let unresolvedRequiredAssetFiles: [String]
    public let shaderUniforms: [String]
    public let requiresSceneScriptRuntime: Bool
    public let requiresParticleRuntime: Bool
    public let requiresSoundRuntime: Bool
    public let requiresModelRuntime: Bool
    public let requiresVideoTextureRuntime: Bool
    public let requiresShaderPipeline: Bool
    public let requiresAudioAnalysis: Bool
    public let requiresMaskedEffectComposition: Bool
    public let requiresClockRuntime: Bool
    public let requiresInteractionRuntime: Bool
    public let requiresUnrecognizedLayerRuntime: Bool
    public let requiresDynamicVisibilityRuntime: Bool
    public let requiresExternalAssetRuntime: Bool
    public let hasDependencyAnalysisUncertainty: Bool
    public let hasAudioDependencyUncertainty: Bool
    public let hasInvalidSoundPlaybackMode: Bool

    init(
        layers: [SceneRuntimeLayerFeature],
        materialFiles: [String],
        effectFiles: [String],
        shaderFiles: [String],
        textureFiles: [String],
        audioFiles: [String],
        videoFiles: [String],
        unreadableRequiredAssetFiles: [String],
        unresolvedRequiredAssetFiles: [String],
        shaderUniforms: [String],
        requiresSceneScriptRuntime: Bool,
        requiresParticleRuntime: Bool,
        requiresSoundRuntime: Bool,
        requiresModelRuntime: Bool,
        requiresVideoTextureRuntime: Bool,
        requiresShaderPipeline: Bool,
        requiresAudioAnalysis: Bool,
        requiresMaskedEffectComposition: Bool,
        requiresClockRuntime: Bool,
        requiresInteractionRuntime: Bool,
        requiresUnrecognizedLayerRuntime: Bool,
        requiresDynamicVisibilityRuntime: Bool,
        requiresExternalAssetRuntime: Bool,
        hasDependencyAnalysisUncertainty: Bool,
        hasAudioDependencyUncertainty: Bool,
        hasInvalidSoundPlaybackMode: Bool
    ) {
        self.layers = layers
        self.materialFiles = materialFiles
        self.effectFiles = effectFiles
        self.shaderFiles = shaderFiles
        self.textureFiles = textureFiles
        self.audioFiles = audioFiles
        self.videoFiles = videoFiles
        self.unreadableRequiredAssetFiles = unreadableRequiredAssetFiles
        self.unresolvedRequiredAssetFiles = unresolvedRequiredAssetFiles
        self.shaderUniforms = shaderUniforms
        self.requiresSceneScriptRuntime = requiresSceneScriptRuntime
        self.requiresParticleRuntime = requiresParticleRuntime
        self.requiresSoundRuntime = requiresSoundRuntime
        self.requiresModelRuntime = requiresModelRuntime
        self.requiresVideoTextureRuntime = requiresVideoTextureRuntime
        self.requiresShaderPipeline = requiresShaderPipeline
        self.requiresAudioAnalysis = requiresAudioAnalysis
        self.requiresMaskedEffectComposition = requiresMaskedEffectComposition
        self.requiresClockRuntime = requiresClockRuntime
        self.requiresInteractionRuntime = requiresInteractionRuntime
        self.requiresUnrecognizedLayerRuntime = requiresUnrecognizedLayerRuntime
        self.requiresDynamicVisibilityRuntime = requiresDynamicVisibilityRuntime
        self.requiresExternalAssetRuntime = requiresExternalAssetRuntime
        self.hasDependencyAnalysisUncertainty = hasDependencyAnalysisUncertainty
        self.hasAudioDependencyUncertainty = hasAudioDependencyUncertainty
        self.hasInvalidSoundPlaybackMode = hasInvalidSoundPlaybackMode
    }

    public var requiresEngineRenderer: Bool {
        requiresSceneScriptRuntime
            || requiresParticleRuntime
            || requiresSoundRuntime
            || requiresModelRuntime
            || requiresVideoTextureRuntime
            || requiresShaderPipeline
            || requiresAudioAnalysis
            || requiresMaskedEffectComposition
            || requiresClockRuntime
            || requiresInteractionRuntime
            || requiresUnrecognizedLayerRuntime
            || requiresDynamicVisibilityRuntime
            || requiresExternalAssetRuntime
            || hasDependencyAnalysisUncertainty
    }

    public var runtimeGaps: [String] {
        var gaps: [String] = []
        if requiresShaderPipeline {
            gaps.append("metal-shader-effect-pipeline")
        }
        if requiresSceneScriptRuntime {
            gaps.append("scenescript-runtime")
        }
        if requiresParticleRuntime {
            gaps.append("particle-system-runtime")
        }
        if requiresSoundRuntime {
            gaps.append("sound-layer-playback")
        }
        if requiresModelRuntime {
            gaps.append("model-layer-runtime")
        }
        if requiresAudioAnalysis {
            gaps.append("audio-analysis-uniforms")
        }
        if requiresVideoTextureRuntime {
            gaps.append("video-texture-runtime")
        }
        if requiresMaskedEffectComposition {
            gaps.append("masked-effect-composition")
        }
        if requiresClockRuntime {
            gaps.append("live-clock-runtime")
        }
        if requiresInteractionRuntime {
            gaps.append("interaction-runtime")
        }
        if requiresUnrecognizedLayerRuntime {
            gaps.append("unrecognized-layer-runtime")
        }
        if requiresDynamicVisibilityRuntime {
            gaps.append("dynamic-visibility-runtime")
        }
        if requiresExternalAssetRuntime {
            gaps.append("external-engine-asset-resolution")
        }
        if hasDependencyAnalysisUncertainty {
            gaps.append("scene-dependency-analysis-uncertain")
        }
        if hasAudioDependencyUncertainty {
            gaps.append("audio-dependency-analysis-uncertain")
        }
        if hasInvalidSoundPlaybackMode {
            gaps.append("invalid-sound-playback-mode")
        }
        return gaps
    }

    public var userFacingSummary: String {
        guard requiresEngineRenderer else {
            return "This scene only uses the basic layer renderer."
        }
        return "This scene requires engine rendering features: \(runtimeGaps.joined(separator: ", "))."
    }

    private enum CodingKeys: String, CodingKey {
        case layers
        case materialFiles
        case effectFiles
        case shaderFiles
        case textureFiles
        case audioFiles
        case videoFiles
        case unreadableRequiredAssetFiles
        case unresolvedRequiredAssetFiles
        case shaderUniforms
        case requiresSceneScriptRuntime
        case requiresParticleRuntime
        case requiresSoundRuntime
        case requiresModelRuntime
        case requiresVideoTextureRuntime
        case requiresShaderPipeline
        case requiresAudioAnalysis
        case requiresMaskedEffectComposition
        case requiresClockRuntime
        case requiresInteractionRuntime
        case requiresUnrecognizedLayerRuntime
        case requiresDynamicVisibilityRuntime
        case requiresExternalAssetRuntime
        case hasDependencyAnalysisUncertainty
        case hasAudioDependencyUncertainty
        case hasInvalidSoundPlaybackMode
        case requiresEngineRenderer
        case runtimeGaps
        case userFacingSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layers = try container.decode([SceneRuntimeLayerFeature].self, forKey: .layers)
        materialFiles = try container.decode([String].self, forKey: .materialFiles)
        effectFiles = try container.decode([String].self, forKey: .effectFiles)
        shaderFiles = try container.decode([String].self, forKey: .shaderFiles)
        textureFiles = try container.decode([String].self, forKey: .textureFiles)
        audioFiles = try container.decode([String].self, forKey: .audioFiles)
        videoFiles = try container.decode([String].self, forKey: .videoFiles)
        unreadableRequiredAssetFiles = try container
            .decodeIfPresent([String].self, forKey: .unreadableRequiredAssetFiles) ?? []
        unresolvedRequiredAssetFiles = try container
            .decodeIfPresent([String].self, forKey: .unresolvedRequiredAssetFiles) ?? []
        shaderUniforms = try container.decode([String].self, forKey: .shaderUniforms)
        requiresSceneScriptRuntime = try container.decode(Bool.self, forKey: .requiresSceneScriptRuntime)
        requiresParticleRuntime = try container.decode(Bool.self, forKey: .requiresParticleRuntime)
        requiresSoundRuntime = try container.decode(Bool.self, forKey: .requiresSoundRuntime)
        requiresModelRuntime = try container.decodeIfPresent(Bool.self, forKey: .requiresModelRuntime) ?? false
        requiresVideoTextureRuntime = try container.decode(Bool.self, forKey: .requiresVideoTextureRuntime)
        requiresShaderPipeline = try container.decode(Bool.self, forKey: .requiresShaderPipeline)
        requiresAudioAnalysis = try container.decode(Bool.self, forKey: .requiresAudioAnalysis)
        requiresMaskedEffectComposition = try container
            .decodeIfPresent(Bool.self, forKey: .requiresMaskedEffectComposition) ?? false
        requiresClockRuntime = try container.decodeIfPresent(Bool.self, forKey: .requiresClockRuntime) ?? false
        requiresInteractionRuntime = try container
            .decodeIfPresent(Bool.self, forKey: .requiresInteractionRuntime) ?? false
        requiresUnrecognizedLayerRuntime = try container
            .decodeIfPresent(Bool.self, forKey: .requiresUnrecognizedLayerRuntime)
            ?? layers.contains { $0.kind == "unknown" }
        requiresDynamicVisibilityRuntime = try container
            .decodeIfPresent(Bool.self, forKey: .requiresDynamicVisibilityRuntime) ?? false
        requiresExternalAssetRuntime = try container
            .decodeIfPresent(Bool.self, forKey: .requiresExternalAssetRuntime) ?? false
        hasDependencyAnalysisUncertainty = try container
            .decodeIfPresent(Bool.self, forKey: .hasDependencyAnalysisUncertainty) ?? false
        hasAudioDependencyUncertainty = try container
            .decodeIfPresent(Bool.self, forKey: .hasAudioDependencyUncertainty) ?? false
        hasInvalidSoundPlaybackMode = try container
            .decodeIfPresent(Bool.self, forKey: .hasInvalidSoundPlaybackMode) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layers, forKey: .layers)
        try container.encode(materialFiles, forKey: .materialFiles)
        try container.encode(effectFiles, forKey: .effectFiles)
        try container.encode(shaderFiles, forKey: .shaderFiles)
        try container.encode(textureFiles, forKey: .textureFiles)
        try container.encode(audioFiles, forKey: .audioFiles)
        try container.encode(videoFiles, forKey: .videoFiles)
        try container.encode(unreadableRequiredAssetFiles, forKey: .unreadableRequiredAssetFiles)
        try container.encode(unresolvedRequiredAssetFiles, forKey: .unresolvedRequiredAssetFiles)
        try container.encode(shaderUniforms, forKey: .shaderUniforms)
        try container.encode(requiresSceneScriptRuntime, forKey: .requiresSceneScriptRuntime)
        try container.encode(requiresParticleRuntime, forKey: .requiresParticleRuntime)
        try container.encode(requiresSoundRuntime, forKey: .requiresSoundRuntime)
        try container.encode(requiresModelRuntime, forKey: .requiresModelRuntime)
        try container.encode(requiresVideoTextureRuntime, forKey: .requiresVideoTextureRuntime)
        try container.encode(requiresShaderPipeline, forKey: .requiresShaderPipeline)
        try container.encode(requiresAudioAnalysis, forKey: .requiresAudioAnalysis)
        try container.encode(requiresMaskedEffectComposition, forKey: .requiresMaskedEffectComposition)
        try container.encode(requiresClockRuntime, forKey: .requiresClockRuntime)
        try container.encode(requiresInteractionRuntime, forKey: .requiresInteractionRuntime)
        try container.encode(requiresUnrecognizedLayerRuntime, forKey: .requiresUnrecognizedLayerRuntime)
        try container.encode(requiresDynamicVisibilityRuntime, forKey: .requiresDynamicVisibilityRuntime)
        try container.encode(requiresExternalAssetRuntime, forKey: .requiresExternalAssetRuntime)
        try container.encode(hasDependencyAnalysisUncertainty, forKey: .hasDependencyAnalysisUncertainty)
        try container.encode(hasAudioDependencyUncertainty, forKey: .hasAudioDependencyUncertainty)
        try container.encode(hasInvalidSoundPlaybackMode, forKey: .hasInvalidSoundPlaybackMode)
        try container.encode(requiresEngineRenderer, forKey: .requiresEngineRenderer)
        try container.encode(runtimeGaps, forKey: .runtimeGaps)
        try container.encode(userFacingSummary, forKey: .userFacingSummary)
    }
}

public struct SceneRuntimeFeatureAnalyzer: Sendable {
    public init() {}

    public func analyze(url: URL) throws -> SceneRuntimeFeatures {
        let package = try ScenePackageReader().read(url: url)
        guard let sceneData = package.data(forPath: "scene.json"),
              let scene = try JSONSerialization.jsonObject(with: sceneData) as? [String: Any] else {
            throw ScenePackageError.missingSceneJSON
        }
        return analyze(package: package, scene: scene)
    }

    public func analyze(package: ScenePackage, scene: [String: Any]) -> SceneRuntimeFeatures {
        let allObjects = scene["objects"] as? [[String: Any]] ?? []
        let objects = allObjects.filter {
            SceneVisibilitySemantics.isPotentiallyVisible($0["visible"])
        }
        let layers = objects.enumerated().map { index, object in
            SceneRuntimeLayerFeature(
                id: Self.intValue(object["id"]),
                name: Self.stringValue(object["name"]) ?? "layer-\(index)",
                kind: Self.kind(of: object),
                effectFiles: Self.effectFiles(from: object),
                scriptCount: Self.scriptCount(in: object),
                constantShaderValueKeys: Self.constantShaderValueKeys(from: object)
            )
        }
        let dependencies = Self.requiredPackageDependencies(in: objects, package: package)
        let shaderFiles = Self.paths(in: package, where: { $0.hasPrefix("shaders/") })
        let directlyRequiredShaderFiles = dependencies.isComplete
            ? shaderFiles.filter { dependencies.shaderPaths.contains($0) }
            : shaderFiles
        let shaderClosure = Self.shaderDependencyClosure(
            in: package,
            initialFiles: directlyRequiredShaderFiles,
            allShaderFiles: shaderFiles
        )
        let shaderUniformScan = Self.shaderUniforms(in: package, shaderFiles: shaderFiles)
        let requiredShaderUniformScan = Self.shaderUniforms(
            in: package,
            shaderFiles: shaderClosure.files
        )
        let hasAudioUniforms = requiredShaderUniformScan.uniforms.contains {
            $0.hasPrefix("g_Audio")
        }
        let scriptSources = objects.flatMap { Self.scriptSource(in: $0) }
        let textureFiles = Self.paths(in: package, where: { $0.hasSuffix(".tex") })
        let embeddedVideoTextures = textureFiles.filter { path in
            package.data(forPath: path).map(SceneTextureDecoder.isEmbeddedVideoTexture(data:)) ?? false
        }
        let videoFiles = (Self.paths(in: package, where: {
            Self.videoExtensions.contains(Self.pathExtension($0))
        }) + embeddedVideoTextures).sorted()
        let requiredVideoFiles = dependencies.isComplete
            ? videoFiles.filter { dependencies.paths.contains($0) }
            : videoFiles
        let unresolvedRequiredAssetFiles = Array(
            dependencies.unresolvedPaths.union(shaderClosure.unresolvedPaths)
        ).sorted()
        let dependencyAnalysisUncertain = !dependencies.isComplete
            || !shaderClosure.isComplete
            || !requiredShaderUniformScan.isComplete
        let audioDependencyUncertain = dependencies.hasAudioUncertainty
            || shaderClosure.hasAudioUncertainty
            || !requiredShaderUniformScan.isComplete
        let hasDynamicVisibility = Self.containsDynamicVisibility(in: objects)
        let hasInvalidSoundPlaybackMode = Self.hasInvalidSoundPlaybackMode(in: objects)
        return SceneRuntimeFeatures(
            layers: layers,
            materialFiles: Self.paths(in: package, where: { $0.hasPrefix("materials/") && $0.hasSuffix(".json") }),
            effectFiles: Self.paths(in: package, where: { $0.hasPrefix("effects/") }),
            shaderFiles: shaderFiles,
            textureFiles: textureFiles,
            audioFiles: Self.paths(in: package, where: { Self.audioExtensions.contains(Self.pathExtension($0)) }),
            videoFiles: videoFiles,
            unreadableRequiredAssetFiles: Self.unreadableRequiredAssetFiles(
                in: objects,
                package: package
            ),
            unresolvedRequiredAssetFiles: unresolvedRequiredAssetFiles,
            shaderUniforms: shaderUniformScan.uniforms,
            requiresSceneScriptRuntime: layers.contains { $0.scriptCount > 0 },
            requiresParticleRuntime: layers.contains { $0.kind == "particle" },
            requiresSoundRuntime: layers.contains { $0.kind == "sound" },
            requiresModelRuntime: layers.contains { $0.kind == "model" }
                || Self.containsPuppetModel(in: objects, package: package),
            requiresVideoTextureRuntime: !requiredVideoFiles.isEmpty,
            requiresShaderPipeline: dependencies.referencesShader
                || !shaderClosure.files.isEmpty
                || layers.contains { !$0.effectFiles.isEmpty },
            requiresAudioAnalysis: hasAudioUniforms || Self.containsAudioScript(in: objects),
            requiresMaskedEffectComposition: Self.containsEffectMaskReference(in: objects),
            requiresClockRuntime: scriptSources.contains(where: Self.containsClockAPI),
            requiresInteractionRuntime: scriptSources.contains(where: Self.containsInteractionAPI),
            requiresUnrecognizedLayerRuntime: layers.contains { $0.kind == "unknown" },
            requiresDynamicVisibilityRuntime: hasDynamicVisibility,
            requiresExternalAssetRuntime: !unresolvedRequiredAssetFiles.isEmpty,
            hasDependencyAnalysisUncertainty: dependencyAnalysisUncertain,
            hasAudioDependencyUncertainty: audioDependencyUncertain,
            hasInvalidSoundPlaybackMode: hasInvalidSoundPlaybackMode
        )
    }

    private static let audioExtensions = Set(["mp3", "wav", "ogg"])
    private static let videoExtensions = Set(["mp4", "webm"])
    private static let maximumModelJSONBytes = 8 * 1_024 * 1_024
    private static let maximumAssetIntegrityObjectCount = 4_096
    private static let maximumAssetIntegrityEntryCount = 64
    private static let maximumAssetIntegrityBytes = 32 * 1_024 * 1_024
    private static let maximumDependencyJSONEntryCount = 4_096
    private static let maximumDependencyJSONBytes = 64 * 1_024 * 1_024
    private static let maximumShaderDependencyEntryCount = 1_024
    private static let maximumShaderDependencyBytes = 16 * 1_024 * 1_024
    private static let maximumShaderIncludeDirectiveCount = 4_096
    private static let maximumJSONTraversalDepth = 64
    private static let knownShaderUniforms = [
        "g_Time",
        "g_Texture0Resolution",
        "g_Texture1Resolution",
        "g_Texture2Resolution",
        "g_Texture3Resolution",
        "g_AudioSpectrum16Left",
        "g_AudioSpectrum16Right",
        "g_AudioSpectrum16",
        "g_AudioFrequencyMin",
        "g_AudioFrequencyMax",
        "g_AudioPower"
    ]

    private struct RequiredPackageDependencies {
        let paths: Set<String>
        let shaderPaths: Set<String>
        let unresolvedPaths: Set<String>
        let isComplete: Bool
        let hasAudioUncertainty: Bool
        let referencesShader: Bool
    }

    private enum RequiredJSONSchema: String, Hashable {
        case model
        case material
        case effect
        case particle
    }

    private struct PendingJSONDependency {
        let path: String
        let schema: RequiredJSONSchema
    }

    private struct ShaderDependencyClosure {
        let files: [String]
        let unresolvedPaths: Set<String>
        let isComplete: Bool
        let hasAudioUncertainty: Bool
    }

    private struct ShaderUniformScan {
        let uniforms: [String]
        let isComplete: Bool
    }

    private static func paths(in package: ScenePackage, where predicate: (String) -> Bool) -> [String] {
        package.entries.map(\.path).filter(predicate).sorted()
    }

    private static func pathExtension(_ path: String) -> String {
        URL(filePath: path).pathExtension.lowercased()
    }

    /// Mirrors the renderer container's lexical normalization while keeping
    /// the probe fail-closed: references may use `.` and may cancel an
    /// existing component with `..`, but they may never escape package root.
    private static func normalizedPackagePath(_ rawPath: String, prefix: String? = nil) -> String? {
        let rawPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty,
              !rawPath.hasPrefix("/"),
              !rawPath.contains("\\"),
              !rawPath.contains("\0") else {
            return nil
        }
        let combined = prefix.map { "\($0)/\(rawPath)" } ?? rawPath
        var components: [Substring] = []
        for component in combined.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                guard !components.isEmpty else {
                    return nil
                }
                components.removeLast()
                continue
            }
            components.append(component)
        }
        guard !components.isEmpty else {
            return nil
        }
        return components.joined(separator: "/")
    }

    private static func replacingPathExtension(_ path: String, with newExtension: String) -> String {
        let lastSlash = path.lastIndex(of: "/")
        let filenameStart = lastSlash.map { path.index(after: $0) } ?? path.startIndex
        let lastDot = path[filenameStart...].lastIndex(of: ".")
        let base = lastDot.map { String(path[..<$0]) } ?? path
        return newExtension.isEmpty ? base : "\(base).\(newExtension)"
    }

    /// Traces only package files reachable from layers that can actually be
    /// visible. Package archives commonly retain disabled effect variants;
    /// treating every packaged shader/video as active incorrectly upgrades a
    /// basic scene to Cached/Limited even though the renderer never loads it.
    private static func requiredPackageDependencies(
        in objects: [[String: Any]],
        package: ScenePackage
    ) -> RequiredPackageDependencies {
        var entriesByPath: [String: ScenePackageEntry] = [:]
        entriesByPath.reserveCapacity(package.entries.count)
        for entry in package.entries where entriesByPath[entry.path] == nil {
            entriesByPath[entry.path] = entry
        }

        var paths = Set<String>()
        var shaderPaths = Set<String>()
        var unresolvedPaths = Set<String>()
        var pendingJSONDependencies: [PendingJSONDependency] = []
        var scheduledJSONSchemas: [String: Set<RequiredJSONSchema>] = [:]
        var budgetedJSONPaths = Set<String>()
        var scheduledJSONBytes = 0
        var wasIncomplete = false
        var hasAudioUncertainty = false
        var referencesShader = false
        var rendererProvidedFBOs: Set<String> = [
            "_rt_FullFrameBuffer",
            "_rt_MipMappedFrameBuffer",
            "_rt_shadowAtlas",
            "_alias_lightCookie",
            "_rt_4FrameBuffer",
            "_rt_8FrameBuffer",
            "_rt_Bloom",
            "_rt_FullFrameBufferBloomSrc"
        ]
        for object in objects where object["image"] is String {
            let id = Self.intValue(object["id"]) ?? -1
            rendererProvidedFBOs.insert("_rt_imageLayerComposite_\(id)_a")
            rendererProvidedFBOs.insert("_rt_imageLayerComposite_\(id)_b")
        }

        enum DependencyKind {
            case json
            case texture
            case audio
            case binary

            var canHideAudioRequirements: Bool {
                self == .json || self == .audio
            }
        }

        func recordUnresolved(_ rawPath: String, kind: DependencyKind) {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            unresolvedPaths.insert(trimmed.isEmpty ? "<empty>" : trimmed)
            wasIncomplete = true
            if kind.canHideAudioRequirements {
                hasAudioUncertainty = true
            }
        }

        func enqueuePath(
            _ rawPath: String?,
            kind: DependencyKind,
            jsonSchema: RequiredJSONSchema? = nil
        ) {
            guard let rawPath else { return }
            guard let path = normalizedPackagePath(rawPath) else {
                recordUnresolved(rawPath, kind: kind)
                return
            }
            guard let entry = entriesByPath[path] else {
                recordUnresolved(path, kind: kind)
                return
            }
            paths.insert(path)
            if let jsonSchema {
                // ModelParser, MaterialParser, and EffectParser decode the
                // referenced bytes as JSON regardless of the filename's
                // extension. The probe must follow the explicit dependency
                // schema rather than an extension allowlist.
                var schemas = scheduledJSONSchemas[path, default: []]
                guard schemas.insert(jsonSchema).inserted else { return }
                scheduledJSONSchemas[path] = schemas
                let isNewBudgetedPath = !budgetedJSONPaths.contains(path)
                guard !isNewBudgetedPath || (
                    budgetedJSONPaths.count < maximumDependencyJSONEntryCount
                        && entry.length <= maximumModelJSONBytes
                        && scheduledJSONBytes + entry.length <= maximumDependencyJSONBytes
                ) else {
                    wasIncomplete = true
                    hasAudioUncertainty = true
                    return
                }
                if isNewBudgetedPath {
                    budgetedJSONPaths.insert(path)
                    scheduledJSONBytes += entry.length
                }
                pendingJSONDependencies.append(
                    PendingJSONDependency(path: path, schema: jsonSchema)
                )
            }
        }

        func recordSchemaIssue(_ context: String, field: String, kind: DependencyKind = .json) {
            recordUnresolved("\(context)#\(field)", kind: kind)
        }

        func exactRequiredPath(
            _ value: Any?,
            context: String,
            field: String,
            kind: DependencyKind = .json
        ) -> String? {
            guard let value,
                  !(value is NSNull),
                  let string = value as? String else {
                recordSchemaIssue(context, field: field, kind: kind)
                return nil
            }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed == string else {
                recordSchemaIssue(context, field: field, kind: kind)
                return nil
            }
            return trimmed
        }

        func exactOptionalPath(
            _ value: Any?,
            context: String,
            field: String,
            kind: DependencyKind = .json
        ) -> String? {
            guard let value, !(value is NSNull) else { return nil }
            return exactRequiredPath(value, context: context, field: field, kind: kind)
        }

        func enqueueTexture(_ value: Any?, context: String) {
            let name: String?
            if let string = value as? String {
                // TextureParser deliberately ignores an empty direct string.
                guard !string.isEmpty else { return }
                name = exactRequiredPath(
                    string,
                    context: context,
                    field: "texture",
                    kind: .texture
                )
            } else if let dictionary = value as? [String: Any] {
                guard let rawName = dictionary["name"] as? String else {
                    // Objects without a string `name` are empty slots.
                    return
                }
                name = exactRequiredPath(
                    rawName,
                    context: context,
                    field: "texture.name",
                    kind: .texture
                )
            } else {
                // TextureParser deliberately ignores null, scalar values and
                // objects without a string `name` instead of rejecting the
                // material. Mirror that behavior so these optional slots do
                // not lower compatibility on their own.
                return
            }
            guard let name else { return }
            guard let normalizedName = normalizedPackagePath(name) else {
                recordUnresolved(name, kind: .texture)
                return
            }
            if entriesByPath[normalizedName] != nil {
                enqueuePath(normalizedName, kind: .texture)
                return
            }
            let candidates = textureCandidates(for: normalizedName).compactMap {
                normalizedPackagePath($0)
            }
            if let candidate = candidates.first(where: { entriesByPath[$0] != nil }) {
                enqueuePath(candidate, kind: .texture)
            } else {
                recordUnresolved(candidates.first ?? normalizedName, kind: .texture)
            }
        }

        func enqueueTextures(_ value: Any?, context: String, field: String) {
            guard let value, !(value is NSNull) else { return }
            guard let values = value as? [Any] else {
                // A non-array texture map is defined as an empty map by the
                // bundled renderer.
                return
            }
            for (index, value) in values.enumerated() where !(value is NSNull) {
                enqueueTexture(value, context: "\(context)#\(field)[\(index)]")
            }
        }

        func recordShader(_ value: Any?, context: String, required: Bool) {
            guard let value, !(value is NSNull) else {
                if required {
                    referencesShader = true
                    recordSchemaIssue(context, field: "shader")
                }
                return
            }
            referencesShader = true
            guard let rawName = value as? String else {
                recordSchemaIssue(context, field: "shader")
                return
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name == rawName else {
                recordSchemaIssue(context, field: "shader")
                return
            }
            let baseName = replacingPathExtension(name, with: "")
            for shaderExtension in ["vert", "frag"] {
                let candidate = replacingPathExtension(baseName, with: shaderExtension)
                guard let shaderPath = normalizedPackagePath(candidate, prefix: "shaders") else {
                    recordUnresolved(candidate, kind: .json)
                    continue
                }
                if entriesByPath[shaderPath] != nil {
                    paths.insert(shaderPath)
                    shaderPaths.insert(shaderPath)
                } else {
                    recordUnresolved(shaderPath, kind: .json)
                }
            }
        }

        func scanMaterialPass(_ pass: [String: Any], context: String) {
            recordShader(pass["shader"], context: context, required: true)
            enqueueTextures(pass["textures"], context: context, field: "textures")
            enqueueTextures(pass["usertextures"], context: context, field: "usertextures")
        }

        func isRendererInteger(_ value: Any?) -> Bool {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return false
            }
            let double = number.doubleValue
            return double.isFinite
                && double.rounded(.towardZero) == double
                && double >= Double(Int32.min)
                && double <= Double(Int32.max)
        }

        func scanEffectBinds(
            _ value: Any?,
            context: String,
            availableFBOs: Set<String>,
            validatesResolution: Bool
        ) {
            guard let value, !(value is NSNull) else { return }
            guard let binds = value as? [Any] else {
                // The parser turns this into an empty map, which silently
                // drops an authored binding and cannot earn Full fidelity.
                recordSchemaIssue(context, field: "bind")
                return
            }
            for (index, bindValue) in binds.enumerated() {
                let bindContext = "\(context)#bind[\(index)]"
                guard let bind = bindValue as? [String: Any] else {
                    recordSchemaIssue(bindContext, field: "object")
                    continue
                }
                if !isRendererInteger(bind["index"]) {
                    recordSchemaIssue(bindContext, field: "index")
                }
                if let name = exactRequiredPath(
                    bind["name"],
                    context: bindContext,
                    field: "name"
                ), validatesResolution,
                   name != "previous",
                   !availableFBOs.contains(name) {
                    recordSchemaIssue(bindContext, field: "name-unresolved")
                }
            }
        }

        func scanEffectFBOs(_ value: Any?, context: String) -> Set<String> {
            guard let value, !(value is NSNull) else { return [] }
            guard let fbos = value as? [Any] else {
                // A non-array collection is silently discarded, so declared
                // effect render targets would be missing at runtime.
                recordSchemaIssue(context, field: "fbos")
                return []
            }
            var names = Set<String>()
            for (index, fboValue) in fbos.enumerated() {
                let fboContext = "\(context)#fbos[\(index)]"
                guard let fbo = fboValue as? [String: Any] else {
                    recordSchemaIssue(fboContext, field: "object")
                    continue
                }
                if let name = exactRequiredPath(
                    fbo["name"],
                    context: fboContext,
                    field: "name"
                ) {
                    names.insert(name)
                }
                if let format = fbo["format"], !(format is NSNull), !(format is String) {
                    recordSchemaIssue(fboContext, field: "format")
                }
                if let scale = fbo["scale"], !(scale is NSNull) {
                    guard let number = scale as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID() else {
                        recordSchemaIssue(fboContext, field: "scale")
                        continue
                    }
                    let value = number.doubleValue
                    if !value.isFinite || value <= 0 {
                        // FBOProvider divides all dimensions by scale.
                        recordSchemaIssue(fboContext, field: "scale")
                    }
                }
                if let unique = fbo["unique"], !(unique is NSNull) {
                    guard let number = unique as? NSNumber,
                          CFGetTypeID(number) == CFBooleanGetTypeID() else {
                        recordSchemaIssue(fboContext, field: "unique")
                        continue
                    }
                }
            }
            return names
        }

        func scanEffectPass(
            _ pass: [String: Any],
            context: String,
            availableFBOs: Set<String>
        ) {
            var hasMaterial = false
            if let materialValue = pass["material"], !(materialValue is NSNull) {
                if let material = exactRequiredPath(
                    materialValue,
                    context: context,
                    field: "material"
                ) {
                    hasMaterial = true
                    enqueuePath(material, kind: .json, jsonSchema: .material)
                }
            }
            if let command = pass["command"], !(command is NSNull) {
                // EffectParser only uses presence to select a command (any
                // non-"copy" value becomes swap), but source and target are
                // then renderer-required plain strings.
                _ = command
                _ = exactRequiredPath(pass["source"], context: context, field: "source")
                let target = exactRequiredPath(
                    pass["target"],
                    context: context,
                    field: "target"
                )
                if let target, !availableFBOs.contains(target) {
                    recordSchemaIssue(context, field: "target-unresolved")
                }
                if !hasMaterial, command as? String != "copy" {
                    // Command-only passes other than exact `copy` are parsed
                    // as swap and then skipped by CImage.
                    recordSchemaIssue(context, field: "command")
                }
            } else {
                // Without a command these fields are optional, but when
                // present EffectParser still decodes each as an exact String.
                _ = exactOptionalPath(pass["source"], context: context, field: "source")
                let target = exactOptionalPath(
                    pass["target"],
                    context: context,
                    field: "target"
                )
                if hasMaterial, let target, !availableFBOs.contains(target) {
                    recordSchemaIssue(context, field: "target-unresolved")
                }
                if !hasMaterial {
                    // A fieldless/inert effect pass is skipped entirely and
                    // cannot preserve the authored effect at Full fidelity.
                    recordSchemaIssue(context, field: "material-or-copy-command")
                }
            }
            scanEffectBinds(
                pass["bind"],
                context: context,
                availableFBOs: availableFBOs,
                validatesResolution: hasMaterial
            )
        }

        func scanRequiredPasses(
            _ value: Any?,
            context: String,
            requiresNonEmptyArray: Bool,
            invalidEntryIsUncertain: Bool,
            scan: ([String: Any], String) -> Void
        ) {
            guard let value else {
                recordSchemaIssue(context, field: "passes")
                return
            }
            guard !(value is NSNull),
                  let passes = value as? [Any],
                  !passes.isEmpty else {
                if requiresNonEmptyArray {
                    // Base materials crash when CRenderable dereferences an
                    // empty vector; reachable effects with no passes silently
                    // lose their authored visual behavior.
                    recordSchemaIssue(context, field: "passes")
                }
                return
            }
            for (index, value) in passes.enumerated() {
                let passContext = "\(context)#passes[\(index)]"
                guard let pass = value as? [String: Any] else {
                    if invalidEntryIsUncertain {
                        recordSchemaIssue(passContext, field: "object")
                    }
                    continue
                }
                scan(pass, passContext)
            }
        }

        func scanDefinition(
            _ definition: [String: Any],
            schema: RequiredJSONSchema,
            context: String
        ) {
            switch schema {
            case .model:
                if let material = exactRequiredPath(
                    definition["material"],
                    context: context,
                    field: "material"
                ) {
                    enqueuePath(material, kind: .json, jsonSchema: .material)
                }
                if let puppet = exactOptionalPath(
                    definition["puppet"],
                    context: context,
                    field: "puppet",
                    kind: .binary
                ) {
                    enqueuePath(puppet, kind: .binary)
                }
            case .material:
                scanRequiredPasses(
                    definition["passes"],
                    context: context,
                    requiresNonEmptyArray: true,
                    invalidEntryIsUncertain: true
                ) {
                    scanMaterialPass($0, context: $1)
                }
            case .effect:
                let availableFBOs = rendererProvidedFBOs.union(
                    scanEffectFBOs(definition["fbos"], context: context)
                )
                scanRequiredPasses(
                    definition["passes"],
                    context: context,
                    requiresNonEmptyArray: true,
                    invalidEntryIsUncertain: true
                ) {
                    scanEffectPass($0, context: $1, availableFBOs: availableFBOs)
                }
            case .particle:
                if let materialValue = definition["material"] as? String,
                   !materialValue.isEmpty,
                   let material = exactRequiredPath(
                       materialValue,
                       context: context,
                       field: "material"
                   ) {
                    enqueuePath(material, kind: .json, jsonSchema: .material)
                }
                if let children = definition["children"] as? [Any] {
                    for (index, childValue) in children.enumerated() {
                        let childContext = "\(context)#children[\(index)]"
                        guard let child = childValue as? [String: Any],
                              let particleValue = child["particle"] as? String,
                              !particleValue.isEmpty,
                              let particle = exactRequiredPath(
                                  particleValue,
                                  context: childContext,
                                  field: "particle"
                              ) else { continue }
                        enqueuePath(particle, kind: .json, jsonSchema: .particle)
                    }
                }
            }
        }

        for (objectIndex, object) in objects.enumerated() {
            let objectContext = "scene.objects[\(objectIndex)]"
            if object["image"] != nil,
               let image = exactRequiredPath(
                   object["image"],
                   context: objectContext,
                   field: "image"
               ) {
                enqueuePath(image, kind: .json, jsonSchema: .model)
            }
            if object["model"] != nil,
               let model = exactRequiredPath(
                   object["model"],
                   context: objectContext,
                   field: "model"
               ) {
                enqueuePath(model, kind: .json, jsonSchema: .model)
            }
            if let particle = object["particle"] as? [String: Any] {
                scanDefinition(particle, schema: .particle, context: "\(objectContext)#particle")
            } else if let particleValue = object["particle"] as? String,
                      !particleValue.isEmpty,
                      let particle = exactRequiredPath(
                          particleValue,
                          context: objectContext,
                          field: "particle"
                      ) {
                enqueuePath(particle, kind: .json, jsonSchema: .particle)
            }
            if let sounds = object["sound"] as? [Any] {
                for sound in sounds {
                    guard let path = sound as? String else {
                        recordUnresolved("<invalid-sound-reference>", kind: .audio)
                        continue
                    }
                    enqueuePath(path, kind: .audio)
                }
            } else if object["sound"] != nil {
                recordUnresolved("<invalid-sound-reference>", kind: .audio)
            }
            if let instanceValue = object["instance"] {
                if let instance = instanceValue as? [String: Any] {
                    enqueueTextures(
                        instance["textures"],
                        context: "\(objectContext)#instance",
                        field: "textures"
                    )
                    enqueueTextures(
                        instance["usertextures"],
                        context: "\(objectContext)#instance",
                        field: "usertextures"
                    )
                }
            }
            if let effectsValue = object["effects"] {
                guard let effects = effectsValue as? [Any] else {
                    // ObjectParser defines a non-array effect collection as
                    // empty, so it is not a dependency-analysis failure.
                    continue
                }
                for (effectIndex, effectValue) in effects.enumerated() {
                    let effectContext = "\(objectContext)#effects[\(effectIndex)]"
                    guard let effect = effectValue as? [String: Any] else {
                        recordSchemaIssue(effectContext, field: "object")
                        continue
                    }
                    guard SceneVisibilitySemantics.isPotentiallyVisible(effect["visible"]) else {
                        continue
                    }
                    if let effectPath = exactRequiredPath(
                        effect["file"],
                        context: effectContext,
                        field: "file"
                    ) {
                        enqueuePath(effectPath, kind: .json, jsonSchema: .effect)
                    }
                    if let overrides = effect["passes"] {
                        guard let passOverrides = overrides as? [Any] else {
                            // Non-array pass overrides are safely ignored.
                            continue
                        }
                        for (passIndex, passValue) in passOverrides.enumerated() {
                            let passContext = "\(effectContext)#passes[\(passIndex)]"
                            guard let pass = passValue as? [String: Any] else {
                                // Optional fields on a scalar override parse
                                // as absent, yielding an empty override.
                                continue
                            }
                            enqueueTextures(pass["textures"], context: passContext, field: "textures")
                            enqueueTextures(
                                pass["usertextures"],
                                context: passContext,
                                field: "usertextures"
                            )
                        }
                    }
                }
            }
        }

        var nextJSONIndex = 0
        while nextJSONIndex < pendingJSONDependencies.count {
            let dependency = pendingJSONDependencies[nextJSONIndex]
            nextJSONIndex += 1
            let path = dependency.path
            guard let entry = entriesByPath[path] else {
                recordUnresolved(path, kind: .json)
                continue
            }
            guard let definition = (try? JSONSerialization.jsonObject(with: package.data(for: entry)))
                    as? [String: Any] else {
                wasIncomplete = true
                hasAudioUncertainty = true
                continue
            }
            scanDefinition(definition, schema: dependency.schema, context: path)
        }

        return RequiredPackageDependencies(
            paths: paths,
            shaderPaths: shaderPaths,
            unresolvedPaths: unresolvedPaths,
            isComplete: !wasIncomplete,
            hasAudioUncertainty: hasAudioUncertainty,
            referencesShader: referencesShader
        )
    }

    private static func shaderDependencyClosure(
        in package: ScenePackage,
        initialFiles: [String],
        allShaderFiles: [String]
    ) -> ShaderDependencyClosure {
        let available = Set(allShaderFiles)
        let boundedInitial = Array(initialFiles.prefix(maximumShaderDependencyEntryCount))
        var required = Set(boundedInitial)
        var pending = boundedInitial
        var nextIndex = 0
        var inspectedBytes = 0
        var includeCount = 0
        var unresolvedPaths = Set<String>()
        var isComplete = initialFiles.count <= maximumShaderDependencyEntryCount
        var hasAudioUncertainty = !isComplete
        while nextIndex < pending.count {
            guard nextIndex < maximumShaderDependencyEntryCount else {
                isComplete = false
                hasAudioUncertainty = true
                break
            }
            let path = pending[nextIndex]
            nextIndex += 1
            guard let data = package.data(forPath: path),
                  inspectedBytes + data.count <= maximumShaderDependencyBytes,
                  let source = String(data: data, encoding: .utf8) else {
                isComplete = false
                hasAudioUncertainty = true
                continue
            }
            inspectedBytes += data.count
            for line in source.split(whereSeparator: \.isNewline) {
                guard let directive = line.range(of: "#include") else {
                    continue
                }
                includeCount += 1
                guard includeCount <= maximumShaderIncludeDirectiveCount else {
                    isComplete = false
                    hasAudioUncertainty = true
                    break
                }
                let suffix = line[directive.upperBound...]
                guard let openingQuote = suffix.firstIndex(of: "\""),
                      let closingQuote = suffix[suffix.index(after: openingQuote)...].firstIndex(of: "\"") else {
                    isComplete = false
                    hasAudioUncertainty = true
                    continue
                }
                let rawInclude = String(suffix[suffix.index(after: openingQuote)..<closingQuote])
                let headerName = replacingPathExtension(rawInclude, with: "h")
                guard let includePath = normalizedPackagePath(headerName, prefix: "shaders") else {
                    unresolvedPaths.insert(rawInclude.isEmpty ? "<empty-shader-include>" : rawInclude)
                    isComplete = false
                    hasAudioUncertainty = true
                    continue
                }
                guard available.contains(includePath) else {
                    unresolvedPaths.insert(includePath)
                    isComplete = false
                    hasAudioUncertainty = true
                    continue
                }
                if required.insert(includePath).inserted {
                    pending.append(includePath)
                }
            }
        }
        return ShaderDependencyClosure(
            files: required.sorted(),
            unresolvedPaths: unresolvedPaths,
            isComplete: isComplete,
            hasAudioUncertainty: hasAudioUncertainty
        )
    }

    private static func shaderUniforms(in package: ScenePackage, shaderFiles: [String]) -> ShaderUniformScan {
        var uniforms = Set<String>()
        var inspectedBytes = 0
        var isComplete = shaderFiles.count <= maximumShaderDependencyEntryCount
        for path in shaderFiles.prefix(maximumShaderDependencyEntryCount) {
            guard let data = package.data(forPath: path),
                  inspectedBytes + data.count <= maximumShaderDependencyBytes,
                  let source = String(data: data, encoding: .utf8) else {
                isComplete = false
                continue
            }
            inspectedBytes += data.count
            for uniform in knownShaderUniforms where containsIdentifier(uniform, in: source) {
                uniforms.insert(uniform)
            }
        }
        return ShaderUniformScan(uniforms: uniforms.sorted(), isComplete: isComplete)
    }

    private static func containsIdentifier(_ identifier: String, in source: String) -> Bool {
        var searchRange = source.startIndex..<source.endIndex
        while let range = source.range(of: identifier, options: [], range: searchRange) {
            let hasIdentifierPrefix = range.lowerBound > source.startIndex
                && isIdentifierCharacter(source[source.index(before: range.lowerBound)])
            let hasIdentifierSuffix = range.upperBound < source.endIndex
                && isIdentifierCharacter(source[range.upperBound])
            if !hasIdentifierPrefix && !hasIdentifierSuffix {
                return true
            }
            searchRange = range.upperBound..<source.endIndex
        }
        return false
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private static func kind(of object: [String: Any]) -> String {
        if object["image"] != nil {
            return "image"
        }
        if object["text"] != nil {
            return "text"
        }
        if object["particle"] != nil {
            return "particle"
        }
        if object["sound"] != nil {
            return "sound"
        }
        if object["model"] != nil {
            return "model"
        }
        return "unknown"
    }

    private static func containsPuppetModel(
        in objects: [[String: Any]],
        package: ScenePackage
    ) -> Bool {
        objects.contains { object in
            guard let imagePath = stringValue(object["image"]),
                  let modelData = package.data(forPath: imagePath) else {
                return false
            }
            // A model beyond the bounded inspection budget must not be
            // assumed to be a basic native layer. Conservatively route it
            // through the engine path, which also prevents a false Full Live
            // classification when a puppet reference appears past the cap.
            guard modelData.count <= maximumModelJSONBytes else {
                return true
            }
            guard
                  let model = (try? JSONSerialization.jsonObject(with: modelData)) as? [String: Any],
                  let puppetPath = stringValue(model["puppet"]) else {
                return false
            }
            return !puppetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Finds only corruption that can be proved from bytes stored in this
    /// package. An unresolved path is not enough: the external renderer also
    /// searches the user-provided Wallpaper Engine assets tree, so stock
    /// models, materials, and textures may intentionally be absent here.
    /// Inspection has both entry-count and aggregate-byte limits so a library
    /// probe cannot turn an adversarial package into unbounded JSON/texture
    /// decoding work.
    private static func unreadableRequiredAssetFiles(
        in objects: [[String: Any]],
        package: ScenePackage
    ) -> [String] {
        var failures = Set<String>()
        var inspectedImagePaths = Set<String>()
        var inspectedEntryCount = 0
        var inspectedObjectCount = 0
        var remainingBytes = maximumAssetIntegrityBytes
        var entriesByPath: [String: ScenePackageEntry] = [:]
        entriesByPath.reserveCapacity(package.entries.count)
        for entry in package.entries where entriesByPath[entry.path] == nil {
            entriesByPath[entry.path] = entry
        }

        func boundedData(for path: String, maximumBytes: Int? = nil) -> Data? {
            guard inspectedEntryCount < maximumAssetIntegrityEntryCount,
                  let entry = entriesByPath[path],
                  entry.length <= remainingBytes,
                  maximumBytes.map({ entry.length <= $0 }) ?? true else {
                return nil
            }
            inspectedEntryCount += 1
            remainingBytes -= entry.length
            return package.data(for: entry)
        }

        for object in objects {
            guard inspectedObjectCount < maximumAssetIntegrityObjectCount,
                  inspectedEntryCount < maximumAssetIntegrityEntryCount,
                  remainingBytes > 0 else {
                break
            }
            inspectedObjectCount += 1
            guard SceneVisibilitySemantics.isPotentiallyVisible(object["visible"]) else { continue }
            guard let imagePath = stringValue(object["image"]),
                  inspectedImagePaths.insert(imagePath).inserted,
                  let modelEntry = entriesByPath[imagePath] else {
                continue
            }
            guard let modelData = boundedData(
                for: imagePath,
                maximumBytes: maximumModelJSONBytes
            ) else {
                continue
            }
            guard let model = (try? JSONSerialization.jsonObject(with: modelData)) as? [String: Any] else {
                failures.insert(modelEntry.path)
                continue
            }
            guard let materialPath = stringValue(model["material"]),
                  let materialEntry = entriesByPath[materialPath] else {
                continue
            }
            guard let materialData = boundedData(
                for: materialPath,
                maximumBytes: maximumModelJSONBytes
            ) else {
                continue
            }
            guard let material = (try? JSONSerialization.jsonObject(with: materialData)) as? [String: Any] else {
                failures.insert(materialEntry.path)
                continue
            }
            guard let textureName = firstTextureName(in: material),
                  let texturePath = textureCandidates(for: textureName).first(where: {
                      entriesByPath[$0] != nil
                  }),
                  let textureData = boundedData(for: texturePath) else {
                continue
            }
            do {
                _ = try SceneTextureDecoder(
                    maximumSoftwareDecodedPixels: 4_000_000,
                    maximumDisplayDimension: 256
                ).decode(data: textureData)
            } catch let error as SceneTextureError where isDefinitivelyCorruptTexture(error) {
                failures.insert(texturePath)
            } catch {
                // Unsupported native formats remain valid renderer candidates.
            }
        }
        return failures.sorted()
    }

    private static func isDefinitivelyCorruptTexture(_ error: SceneTextureError) -> Bool {
        switch error {
        case .unsupportedContainer,
             .unsupportedMagic,
             .unsupportedFormat,
             .unsupportedTextureFlags,
             .unsupportedVideoTexture,
             .textureTooLargeForSoftwareDecode,
             .invalidDimensions,
             .invalidCount:
            return false
        case .invalidString,
             .invalidLZ4Block,
             .invalidMatchOffset,
             .missingDecompressedSize,
             .truncatedTexture:
            return true
        }
    }

    private static func firstTextureName(in material: [String: Any]) -> String? {
        if let textures = material["textures"] as? [String], let first = textures.first {
            return first
        }
        if let texture = stringValue(material["texture"]) {
            return texture
        }
        for key in ["name", "file", "path"] {
            if let texture = stringValue(material[key]) {
                return texture
            }
        }
        guard let passes = material["passes"] as? [[String: Any]] else {
            return nil
        }
        for pass in passes {
            guard let textures = pass["textures"] as? [Any] else {
                continue
            }
            for texture in textures {
                if let value = stringValue(texture) {
                    return value
                }
                if let dictionary = texture as? [String: Any] {
                    for key in ["name", "file", "path", "texture", "value"] {
                        if let value = stringValue(dictionary[key]) {
                            return value
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func textureCandidates(for textureName: String) -> [String] {
        let name = textureName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return []
        }
        if name.hasSuffix(".tex") {
            return name.contains("/") ? [name, "materials/\(name)"] : ["materials/\(name)", name]
        }
        if name.contains("/") {
            return ["\(name).tex", "materials/\(name).tex", name]
        }
        return ["materials/\(name).tex", "\(name).tex", name]
    }

    private static func effectFiles(from object: [String: Any]) -> [String] {
        guard let effects = object["effects"] as? [[String: Any]] else {
            return []
        }
        return effects
            .filter { SceneVisibilitySemantics.isPotentiallyVisible($0["visible"]) }
            .compactMap { stringValue($0["file"]) }
            .sorted()
    }

    private static func constantShaderValueKeys(from object: [String: Any]) -> [String] {
        var keys = Set<String>()
        collectConstantShaderValueKeys(object, into: &keys, depth: 0)
        return keys.sorted()
    }

    private static func collectConstantShaderValueKeys(_ value: Any, into keys: inout Set<String>, depth: Int) {
        guard depth <= maximumJSONTraversalDepth else {
            return
        }
        if let dict = value as? [String: Any] {
            guard SceneVisibilitySemantics.isPotentiallyVisible(dict["visible"]) else {
                return
            }
            if let constants = dict["constantshadervalues"] as? [String: Any] {
                keys.formUnion(constants.keys)
            }
            for child in dict.values {
                collectConstantShaderValueKeys(child, into: &keys, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectConstantShaderValueKeys(child, into: &keys, depth: depth + 1)
            }
        }
    }

    private static func containsDynamicVisibility(in objects: [[String: Any]]) -> Bool {
        objects.contains { containsDynamicVisibility(in: $0, depth: 0) }
    }

    private static func containsDynamicVisibility(in value: Any, depth: Int) -> Bool {
        guard depth <= maximumJSONTraversalDepth else {
            // A visibility graph beyond the bounded probe cannot safely earn
            // Full compatibility.
            return true
        }
        if let dictionary = value as? [String: Any] {
            if let visibility = dictionary["visible"] {
                if SceneVisibilitySemantics.hasDynamicBinding(visibility) {
                    return true
                }
                guard SceneVisibilitySemantics.isPotentiallyVisible(visibility) else {
                    return false
                }
            }
            return dictionary.values.contains {
                containsDynamicVisibility(in: $0, depth: depth + 1)
            }
        }
        if let array = value as? [Any] {
            return array.contains { containsDynamicVisibility(in: $0, depth: depth + 1) }
        }
        return false
    }

    private static func hasInvalidSoundPlaybackMode(in objects: [[String: Any]]) -> Bool {
        objects.contains { object in
            guard object["sound"] != nil,
                  let playbackMode = object["playbackmode"],
                  !(playbackMode is NSNull) else {
                return false
            }
            return !(playbackMode is String)
        }
    }

    private static func scriptCount(in value: Any, depth: Int = 0) -> Int {
        guard depth <= maximumJSONTraversalDepth else {
            return 0
        }
        if let dict = value as? [String: Any] {
            guard SceneVisibilitySemantics.isPotentiallyVisible(dict["visible"]) else {
                return 0
            }
            let ownCount = stringValue(dict["script"]) == nil ? 0 : 1
            return ownCount + dict.values.reduce(0) { $0 + scriptCount(in: $1, depth: depth + 1) }
        }
        if let array = value as? [Any] {
            return array.reduce(0) { $0 + scriptCount(in: $1, depth: depth + 1) }
        }
        return 0
    }

    private static func containsAudioScript(in objects: [[String: Any]]) -> Bool {
        objects.contains { object in
            Self.scriptSource(in: object).contains { source in
                source.contains("registerAudioBuffers")
                    || source.contains("AudioBuffers")
                    || source.contains("audio")
            }
        }
    }

    private static func containsClockAPI(_ source: String) -> Bool {
        source.contains("new Date")
            || source.contains("Date.now")
            || source.contains("getHours")
            || source.contains("getMinutes")
            || source.contains("timeOfDay")
    }

    private static func containsInteractionAPI(_ source: String) -> Bool {
        let lowered = source.lowercased()
        return lowered.contains("cursor")
            || lowered.contains("mouse")
            || lowered.contains("click")
            || lowered.contains("thisscene.getlayer")
            || lowered.contains("input.")
    }

    private static func containsEffectMaskReference(in objects: [[String: Any]]) -> Bool {
        objects.contains { object in
            guard let effects = object["effects"] as? [[String: Any]] else {
                return false
            }
            return effects.contains {
                SceneVisibilitySemantics.isPotentiallyVisible($0["visible"])
                    && effectContainsMaskReference($0)
            }
        }
    }

    private static func effectContainsMaskReference(_ effect: [String: Any]) -> Bool {
        if let mask = stringValue(effect["mask"]), isLikelyMaskTextureReference(mask) {
            return true
        }
        guard let passes = effect["passes"] as? [[String: Any]] else {
            return false
        }
        return passes.contains { pass in
            guard let textures = pass["textures"] as? [Any] else {
                return false
            }
            return textures.dropFirst().contains { texture in
                guard let texture = stringValue(texture) else {
                    return false
                }
                return isLikelyMaskTextureReference(texture)
            }
        }
    }

    private static func isLikelyMaskTextureReference(_ value: String) -> Bool {
        value.lowercased().contains("mask")
    }

    private static func scriptSource(in value: Any, depth: Int = 0) -> [String] {
        guard depth <= maximumJSONTraversalDepth else {
            return []
        }
        if let dict = value as? [String: Any] {
            guard SceneVisibilitySemantics.isPotentiallyVisible(dict["visible"]) else {
                return []
            }
            var scripts = stringValue(dict["script"]).map { [$0] } ?? []
            for child in dict.values {
                scripts.append(contentsOf: scriptSource(in: child, depth: depth + 1))
            }
            return scripts
        }
        if let array = value as? [Any] {
            return array.flatMap { scriptSource(in: $0, depth: depth + 1) }
        }
        return []
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let dict = value as? [String: Any] {
            return stringValue(dict["value"])
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}
