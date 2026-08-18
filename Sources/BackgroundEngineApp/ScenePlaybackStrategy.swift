import Foundation

enum ScenePlaybackStrategy: Equatable {
    case validatedNative
    case cachedVideo(URL)
    case renderCache
    case nativeApproximation(reason: String)
}

struct ScenePlaybackResources: Equatable {
    let cachedVideoURL: URL?
    let hasExternalRenderer: Bool
    let hasEngineAssets: Bool
    let hasMediaTools: Bool

    var canRenderCache: Bool {
        hasExternalRenderer && hasEngineAssets && hasMediaTools
    }

    var missingComponentDescription: String {
        var missing: [String] = []
        if !hasExternalRenderer { missing.append("scene renderer binary") }
        if !hasEngineAssets { missing.append("Wallpaper Engine assets folder") }
        if !hasMediaTools { missing.append("ffmpeg") }
        return missing.isEmpty ? "unknown reason" : missing.joined(separator: ", ")
    }
}

struct ScenePlaybackStrategyResolver {
    func resolve(
        prefersValidatedNative: Bool,
        forcesCachedPlayback: Bool,
        resources: ScenePlaybackResources
    ) -> ScenePlaybackStrategy {
        if forcesCachedPlayback, let cached = resources.cachedVideoURL {
            return .cachedVideo(cached)
        }
        if prefersValidatedNative {
            return .validatedNative
        }
        if let cached = resources.cachedVideoURL {
            return .cachedVideo(cached)
        }
        if resources.canRenderCache {
            return .renderCache
        }
        return .nativeApproximation(
            reason: "Scene cache unavailable: \(resources.missingComponentDescription)."
        )
    }
}
