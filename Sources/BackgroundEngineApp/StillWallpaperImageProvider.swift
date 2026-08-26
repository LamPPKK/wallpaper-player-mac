import AppKit
import AVFoundation
import BackgroundEngineCore

struct StillWallpaperImageProvider {
    let cacheDirectory: URL
    private let exportVideoFrame: (URL, String, URL) throws -> URL

    init(
        cacheDirectory: URL = Self.defaultCacheDirectory(),
        exportVideoFrame: @escaping (URL, String, URL) throws -> URL = Self.exportVideoFrame
    ) {
        self.cacheDirectory = cacheDirectory
        self.exportVideoFrame = exportVideoFrame
    }

    func stillImageURL(for asset: WallpaperAsset) throws -> URL {
        if asset.kind == .video {
            guard asset.supportStatus == .playable,
                  let entrypoint = regularFileURL(for: asset.entrypoint) else {
                throw SystemWallpaperError.conversionRequiredForStillImage
            }
            do {
                return try exportVideoFrame(entrypoint, asset.id, cacheDirectory)
            } catch {
                // A runtime decoder failure is exactly when the preview is
                // most important. Prefer the imported project thumbnail over
                // leaving the desktop as a black layer while FFmpeg recovery
                // runs (or while the user reviews a terminal failure).
                if let thumbnail = playableImageURL(for: asset.thumbnail) {
                    return try normalizeStillImage(thumbnail, assetId: asset.id)
                }
                throw error
            }
        }
        if asset.kind == .image, let entrypoint = playableImageURL(for: asset.entrypoint) {
            return try normalizeStillImage(entrypoint, assetId: asset.id)
        }
        if let thumbnail = playableImageURL(for: asset.thumbnail) {
            return try normalizeStillImage(thumbnail, assetId: asset.id)
        }
        throw SystemWallpaperError.noStillImage
    }

    private static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "Background Engine")
            .appending(path: "GeneratedStillWallpapers")
    }

    /// The importer has already classified video entrypoints by their bytes.
    /// Do not regress to an extension allowlist here: AVFoundation and the
    /// FFmpeg still-frame fallback both accept valid renamed/extensionless
    /// files. Re-check only the filesystem invariants before opening it.
    private func regularFileURL(for path: String?) -> URL? {
        guard let path else {
            return nil
        }
        let url = URL(filePath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return nil
        }
        return url
    }

    private func playableImageURL(for path: String?) -> URL? {
        guard let url = regularFileURL(for: path),
              ImageWallpaperValidation.isPlayableImage(at: url) else {
            return nil
        }
        return url
    }

    private static func exportVideoFrame(from videoURL: URL, assetId: String, cacheDirectory: URL) throws -> URL {
        let output = cacheURL(assetId: assetId, cacheDirectory: cacheDirectory)
        try exportVideoFrameWithAVFoundation(
            from: videoURL,
            to: output,
            cacheDirectory: cacheDirectory
        )
        return output
    }

    private static func exportVideoFrameWithAVFoundation(
        from videoURL: URL,
        to output: URL,
        cacheDirectory: URL
    ) throws {
        let generator = AVAssetImageGenerator(asset: LocalMediaAVAssetPolicy.asset(at: videoURL))
        generator.appliesPreferredTrackTransform = true
        let image: CGImage
        do {
            image = try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
        } catch {
            image = try generator.copyCGImage(at: .zero, actualTime: nil)
        }
        try writePNG(NSBitmapImageRep(cgImage: image), to: output, cacheDirectory: cacheDirectory)
    }

    private func normalizeStillImage(_ url: URL, assetId: String) throws -> URL {
        let output = cacheURL(assetId: assetId)
        let data = try LockScreenWallpaperCache().pngData(from: url)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try data.write(to: output, options: [.atomic])
        return output
    }

    private static func writePNG(_ representation: NSBitmapImageRep, to output: URL, cacheDirectory: URL) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw SystemWallpaperError.noStillImage
        }
        try data.write(to: output, options: [.atomic])
    }

    private func cacheURL(assetId: String) -> URL {
        Self.cacheURL(assetId: assetId, cacheDirectory: cacheDirectory)
    }

    private static func cacheURL(assetId: String, cacheDirectory: URL) -> URL {
        cacheDirectory.appending(path: "\(safeFileName(assetId))-still.png")
    }

    private static func safeFileName(_ value: String) -> String {
        value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
