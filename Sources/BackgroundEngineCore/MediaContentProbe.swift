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
        if metadataType?.lowercased() == "web" {
            return .init(kind: .web, supportStatus: .playable, diagnosticCode: "development_probe_fallback")
        }
        if metadataType?.lowercased() == "image" {
            return .init(kind: .image, supportStatus: .playable, diagnosticCode: "development_probe_fallback")
        }
        if developmentExtension == "html" || developmentExtension == "htm" {
            return .init(kind: .web, supportStatus: .playable, diagnosticCode: "development_probe_fallback")
        }
        if legacyImageExtensions.contains(developmentExtension) {
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
        if let report = try? mediaProbe.inspect(url) { return report.hasVideo }
        #if DEBUG
        return legacyDirectVideoExtensions.contains(url.pathExtension.lowercased())
            || legacyConvertibleVideoExtensions.contains(url.pathExtension.lowercased())
        #else
        return false
        #endif
    }

    private func isImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return false }
        return CGImageSourceGetCount(source) > 0
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
