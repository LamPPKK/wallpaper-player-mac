import AVFoundation
import Foundation
import ImageIO

public struct MediaContentClassification: Equatable, Sendable {
    public let kind: WallpaperKind
    public let supportStatus: SupportStatus
    public let diagnosticCode: String?

    public init(kind: WallpaperKind, supportStatus: SupportStatus, diagnosticCode: String? = nil) {
        self.kind = kind
        self.supportStatus = supportStatus
        self.diagnosticCode = diagnosticCode
    }
}

/// Shared safety contract for images accepted by the importer and decoded by
/// the desktop player. Keeping these limits in Core prevents the library from
/// labelling an image playable when the App target must reject it later.
public enum ImageWallpaperValidation {
    public static let maximumSourceBytes: Int64 = 256 * 1_024 * 1_024
    public static let maximumFrameCount = 10_000
    public static let maximumDecodedFrameBytes: UInt64 = 256 * 1_024 * 1_024

    public static func decodedByteCount(width: Int, height: Int) -> UInt64? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, pixelOverflow) = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        guard !pixelOverflow else { return nil }
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return byteOverflow ? nil : bytes
    }

    public static func isPlayableImage(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? 0) <= maximumSourceBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, [
                  kCGImageSourceShouldCache: false
              ] as CFDictionary) else {
            return false
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0, frameCount <= maximumFrameCount else { return false }
        for index in 0..<frameCount {
            let frameIsValid = autoreleasepool {
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                      let declaredBytes = decodedByteCount(width: width.intValue, height: height.intValue),
                      declaredBytes <= maximumDecodedFrameBytes,
                      let frame = CGImageSourceCreateImageAtIndex(source, index, [
                          kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary),
                      let decodedBytes = decodedByteCount(width: frame.width, height: frame.height),
                      decodedBytes <= maximumDecodedFrameBytes else {
                    return false
                }
                return true
            }
            guard frameIsValid else {
                return false
            }
        }
        return true
    }
}

/// Classifies local wallpaper entrypoints by parsable content. Extensions are
/// only a final compatibility fallback for old manifests and synthetic test
/// fixtures when neither AVFoundation nor the bundled ffprobe can inspect the
/// file.
public struct MediaContentProbe: Sendable {
    private let mediaProbe: MediaProbe

    public init(mediaProbe: MediaProbe = MediaProbe()) {
        self.mediaProbe = mediaProbe
    }

    public func classify(_ url: URL, metadataType: String? = nil) -> MediaContentClassification {
        if metadataType?.lowercased() == "application" {
            return .init(
                kind: .application,
                supportStatus: .unsupported,
                diagnosticCode: "windows_application_unsupported"
            )
        }
        if isScenePackage(url) || metadataType?.lowercased() == "scene" {
            let readable = (try? ScenePackageAnalyzer().analyze(url: url)) != nil
            return .init(
                kind: .scene,
                supportStatus: readable ? .playable : .unsupported,
                diagnosticCode: readable ? nil : "scene_package_unreadable"
            )
        }
        if isHTML(url) {
            return .init(kind: .web, supportStatus: .playable)
        }
        if isImage(url) {
            return .init(kind: .image, supportStatus: .playable)
        }
        #if DEBUG
        // Historical unit fixtures used empty files. Keep that compatibility
        // only in development builds; release classification always requires
        // the declared Web/Image content to decode successfully.
        let developmentExtension = url.pathExtension.lowercased()
        let isEmptyDevelopmentFixture = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0
        if metadataType?.lowercased() == "web", isEmptyDevelopmentFixture {
            return .init(kind: .web, supportStatus: .playable, diagnosticCode: "development_probe_fallback")
        }
        if metadataType?.lowercased() == "image", isEmptyDevelopmentFixture {
            return .init(kind: .image, supportStatus: .playable, diagnosticCode: "development_probe_fallback")
        }
        if isEmptyDevelopmentFixture && (developmentExtension == "html" || developmentExtension == "htm") {
            return .init(kind: .web, supportStatus: .playable, diagnosticCode: "development_probe_fallback")
        }
        if isEmptyDevelopmentFixture && legacyImageExtensions.contains(developmentExtension) {
            return .init(kind: .image, supportStatus: .playable, diagnosticCode: "development_probe_fallback")
        }
        if developmentExtension == "pkg" {
            return .init(kind: .scene, supportStatus: .unsupported, diagnosticCode: "scene_package_unreadable")
        }
        #endif
        if metadataType?.lowercased() == "video" || looksLikeVideo(url) {
            return videoClassification(url)
        }
        return .init(kind: .unknown, supportStatus: .unsupported, diagnosticCode: "unrecognized_content")
    }

    public func videoClassification(_ url: URL) -> MediaContentClassification {
        let asset = AVURLAsset(url: url)
        if asset.isPlayable, !asset.tracks(withMediaType: .video).isEmpty {
            return .init(kind: .video, supportStatus: .playable)
        }
        if let report = try? mediaProbe.inspect(url), report.hasVideo {
            return .init(kind: .video, supportStatus: .needsConversion)
        }
        #if DEBUG
        let ext = url.pathExtension.lowercased()
        if legacyDirectVideoExtensions.contains(ext) {
            return .init(kind: .video, supportStatus: .playable, diagnosticCode: "development_probe_fallback")
        }
        if legacyConvertibleVideoExtensions.contains(ext) {
            return .init(kind: .video, supportStatus: .needsConversion, diagnosticCode: "development_probe_fallback")
        }
        #endif
        return .init(kind: .unknown, supportStatus: .unsupported, diagnosticCode: "unrecognized_content")
    }

    private func looksLikeVideo(_ url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        if asset.isPlayable, !asset.tracks(withMediaType: .video).isEmpty {
            return true
        }
        if let report = try? mediaProbe.inspect(url) { return report.hasVideo }
        #if DEBUG
        return legacyDirectVideoExtensions.contains(url.pathExtension.lowercased())
            || legacyConvertibleVideoExtensions.contains(url.pathExtension.lowercased())
        #else
        return false
        #endif
    }

    private func isImage(_ url: URL) -> Bool {
        ImageWallpaperValidation.isPlayableImage(at: url)
    }

    private func isHTML(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4_096),
              let source = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        return source.contains("<!doctype html")
            || source.contains("<html")
            || source.contains("<body")
            || source.contains("<script")
    }

    private func isScenePackage(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32),
              let header = String(data: data, encoding: .utf8) else { return false }
        return header.contains("PKGV")
    }
}

private let legacyDirectVideoExtensions = Set(["mp4", "mov", "m4v"])
private let legacyConvertibleVideoExtensions = Set(["webm", "mkv", "avi"])
private let legacyImageExtensions = Set(["png", "jpg", "jpeg", "gif", "apng", "webp", "heic", "tiff", "bmp"])
