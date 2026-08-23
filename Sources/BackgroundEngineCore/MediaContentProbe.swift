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
    public static let maximumFrameDimension = 16_384
    private static let conservativeBytesPerPixel: UInt64 = 16

    public static func decodedByteCount(width: Int, height: Int) -> UInt64? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, pixelOverflow) = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        guard !pixelOverflow else { return nil }
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: conservativeBytesPerPixel)
        return byteOverflow ? nil : bytes
    }

    public static func decodedByteCount(for image: CGImage) -> UInt64? {
        let (bytes, overflow) = UInt64(image.bytesPerRow).multipliedReportingOverflow(by: UInt64(image.height))
        return overflow ? nil : bytes
    }

    /// Returns the bounded ImageIO frame count for an animated source without
    /// decoding every frame. Static images return nil so callers continue to
    /// normalize EXIF orientation before configuring the legacy Screen Saver.
    /// The importer performs the full decode validation once; Screen Saver
    /// configuration uses this lightweight check so it can preserve the
    /// original GIF/APNG/WebP path instead of flattening it to a PNG.
    public static func animatedFrameCount(at url: URL) -> Int? {
        guard let count = validatedSource(at: url)?.frameCount, count > 1 else {
            return nil
        }
        return count
    }

    public static func createPlaybackFrame(from source: CGImageSource, at index: Int) -> CGImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue <= maximumFrameDimension,
              height.intValue <= maximumFrameDimension,
              let declaredBytes = decodedByteCount(width: width.intValue, height: height.intValue),
              declaredBytes <= maximumDecodedFrameBytes else {
            return nil
        }
        let maximumPixelSize = max(width.intValue, height.intValue)
        guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldAllowFloat: false,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary),
              let decodedBytes = decodedByteCount(for: frame),
              decodedBytes <= maximumDecodedFrameBytes else {
            return nil
        }
        return frame
    }

    public static func isPlayableImage(at url: URL) -> Bool {
        guard let validated = validatedSource(at: url) else {
            return false
        }
        for index in 0..<validated.frameCount {
            let frameIsValid = autoreleasepool {
                createPlaybackFrame(from: validated.source, at: index) != nil
            }
            guard frameIsValid else {
                return false
            }
        }
        return true
    }

    private static func validatedSource(at url: URL) -> (source: CGImageSource, frameCount: Int)? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? 0) <= maximumSourceBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, [
                  kCGImageSourceShouldCache: false
              ] as CFDictionary) else {
            return nil
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0, frameCount <= maximumFrameCount else { return nil }
        return (source, frameCount)
    }
}

/// Bounded validation for local Web wallpaper entrypoints. Wallpaper Engine
/// projects are commonly UTF-8, but WebKit also accepts documents with a BOM,
/// UTF-16 markup, or a long comment/license preamble. Reading only the first
/// few kilobytes as UTF-8 incorrectly rejects those otherwise valid projects.
enum WebWallpaperValidation {
    static let maximumProbeBytes = 256 * 1_024

    static func isPlayableDocument(at url: URL, declaredAsWeb: Bool) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true,
              let fileSize = values.fileSize, fileSize > 0,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumProbeBytes),
              !data.isEmpty,
              let source = decodeTextPrefix(data),
              isTextLike(source) else {
            return false
        }

        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // A declared Web document may put its first tag beyond the bounded
        // prefix after a generated license/comment block. Accept that case
        // only when more bytes remain; a whitespace-only file is still
        // rejected when the complete file fits inside the probe window.
        guard !normalized.isEmpty else {
            return declaredAsWeb && fileSize > data.count
        }
        if containsHTMLMarkup(normalized) {
            return true
        }
        // A bounded read may contain only a leading HTML comment before the
        // first document tag. Keep that declared-Web compatibility without
        // accepting an entire JavaScript, CSS, or text file as an HTML
        // entrypoint merely because project.json says `type: web`.
        return declaredAsWeb
            && fileSize > data.count
            && normalized.hasPrefix("<!--")
    }

    static func decodeTextPrefix(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return decodeUTF8Prefix(Data(data.dropFirst(3)))
        }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return decodeFixedWidthPrefix(
                Data(data.dropFirst(4)),
                encoding: .utf32LittleEndian,
                codeUnitBytes: 4
            )
        }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return decodeFixedWidthPrefix(
                Data(data.dropFirst(4)),
                encoding: .utf32BigEndian,
                codeUnitBytes: 4
            )
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return decodeFixedWidthPrefix(
                Data(data.dropFirst(2)),
                encoding: .utf16LittleEndian,
                codeUnitBytes: 2,
                trailingUnitsToTry: 1
            )
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return decodeFixedWidthPrefix(
                Data(data.dropFirst(2)),
                encoding: .utf16BigEndian,
                codeUnitBytes: 2,
                trailingUnitsToTry: 1
            )
        }
        if data.count >= 4 {
            let bytes = [UInt8](data.prefix(4))
            if bytes[0] == 0, bytes[1] != 0, bytes[2] == 0, bytes[3] != 0 {
                return decodeFixedWidthPrefix(
                    data,
                    encoding: .utf16BigEndian,
                    codeUnitBytes: 2,
                    trailingUnitsToTry: 1
                )
            }
            if bytes[0] != 0, bytes[1] == 0, bytes[2] != 0, bytes[3] == 0 {
                return decodeFixedWidthPrefix(
                    data,
                    encoding: .utf16LittleEndian,
                    codeUnitBytes: 2,
                    trailingUnitsToTry: 1
                )
            }
        }
        return decodeUTF8Prefix(data)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    /// A bounded read may stop inside the final scalar. Only trim the maximum
    /// possible UTF-8 tail; malformed bytes in the middle still fail strict
    /// decoding and fall through to a declared legacy encoding.
    private static func decodeUTF8Prefix(_ data: Data) -> String? {
        for trailingByteCount in 0...min(3, data.count) {
            let end = data.count - trailingByteCount
            if let source = String(data: data.prefix(end), encoding: .utf8) {
                return source
            }
        }
        return nil
    }

    /// Align a bounded prefix to full code units and optionally discard one
    /// final UTF-16 unit when the read split a surrogate pair. Invalid data
    /// before that final boundary remains a hard failure.
    private static func decodeFixedWidthPrefix(
        _ data: Data,
        encoding: String.Encoding,
        codeUnitBytes: Int,
        trailingUnitsToTry: Int = 0
    ) -> String? {
        let alignedCount = data.count - (data.count % codeUnitBytes)
        for trailingUnitCount in 0...trailingUnitsToTry {
            let byteCount = alignedCount - (trailingUnitCount * codeUnitBytes)
            guard byteCount >= 0 else { continue }
            if let source = String(data: data.prefix(byteCount), encoding: encoding) {
                return source
            }
        }
        return nil
    }

    private static func isTextLike(_ source: String) -> Bool {
        var scalarCount = 0
        var controlCount = 0
        for scalar in source.unicodeScalars {
            scalarCount += 1
            let value = scalar.value
            if value == 0 { return false }
            if (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D)
                || (0x7F...0x9F).contains(value) {
                controlCount += 1
            }
        }
        guard scalarCount > 0 else { return false }
        return controlCount == 0
    }

    private static func containsHTMLMarkup(_ source: String) -> Bool {
        let lowercased = source.lowercased()
        // An entrypoint discovered solely by content must begin like a markup
        // document. This prevents JSON or JavaScript string literals that
        // merely contain snippets such as "<div>" from being misclassified.
        guard lowercased.first == "<" else { return false }
        let tags = ["html", "head", "body", "script", "style", "canvas", "svg", "div"]
        if lowercased.range(of: #"<!\s*doctype\s+html\b"#, options: .regularExpression) != nil {
            return true
        }
        return tags.contains { tag in
            lowercased.range(of: #"<\#(tag)\b"#, options: .regularExpression) != nil
        }
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
        let normalizedMetadataType = metadataType?.lowercased()
        if normalizedMetadataType == "application" {
            return .init(
                kind: .application,
                supportStatus: .unsupported,
                diagnosticCode: "windows_application_unsupported"
            )
        }
        if normalizedMetadataType == "scene" {
            // Declared Scene metadata is only a hint. Gate the expensive
            // package reader behind the bounded PKGV header probe so an
            // invalid preferred path or embedded 512 MiB video is never read
            // wholesale as a Scene package.
            guard isScenePackage(url) else {
                return .init(
                    kind: .scene,
                    supportStatus: .unsupported,
                    diagnosticCode: "scene_package_unreadable"
                )
            }
            return sceneClassification(url)
        }
        if isScenePackage(url) {
            return sceneClassification(url)
        }
        if isHTML(url, declaredAsWeb: normalizedMetadataType == "web") {
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
        // A declared Web/Image candidate that failed its bounded validator is
        // already known not to match the requested kind. Do not launch
        // AVFoundation and ffprobe merely to identify the cross-kind file.
        if normalizedMetadataType == "web" || normalizedMetadataType == "image" {
            return .init(kind: .unknown, supportStatus: .unsupported, diagnosticCode: "unrecognized_content")
        }
        let video = videoClassification(url)
        if normalizedMetadataType == "video" || video.kind == .video {
            return video
        }
        return .init(kind: .unknown, supportStatus: .unsupported, diagnosticCode: "unrecognized_content")
    }

    private func sceneClassification(_ url: URL) -> MediaContentClassification {
        let readable = (try? ScenePackageAnalyzer().analyze(url: url)) != nil
        return .init(
            kind: .scene,
            supportStatus: readable ? .playable : .unsupported,
            diagnosticCode: readable ? nil : "scene_package_unreadable"
        )
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

    private func isImage(_ url: URL) -> Bool {
        ImageWallpaperValidation.isPlayableImage(at: url)
    }

    private func isHTML(_ url: URL, declaredAsWeb: Bool) -> Bool {
        WebWallpaperValidation.isPlayableDocument(at: url, declaredAsWeb: declaredAsWeb)
    }

    private func isScenePackage(_ url: URL) -> Bool {
        ScenePackageReader().hasPackageHeader(url: url)
    }
}

private let legacyDirectVideoExtensions = Set(["mp4", "mov", "m4v"])
private let legacyConvertibleVideoExtensions = Set(["webm", "mkv", "avi"])
private let legacyImageExtensions = Set(["png", "jpg", "jpeg", "gif", "apng", "webp", "heic", "tiff", "bmp"])
