import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import BackgroundEngineApp
import BackgroundEngineCore

@MainActor
final class LockScreenAnimationControllerTests: XCTestCase {
    func testSetEnabledInstallsAndSelectsBundledScreenSaver() throws {
        // Given
        let root = try makeTempDirectory()
        let applicationSupport = root.appending(path: "ApplicationSupport")
        let screenSaverDirectory = root.appending(path: "Screen Savers")
        let bundle = try makeBundleWithScreenSaver(root: root)
        let selectionWriter = RecordingScreenSaverSelectionWriter()
        let controller = LockScreenAnimationController(
            applicationSupportDirectory: applicationSupport,
            screenSaverDirectory: screenSaverDirectory,
            bundle: bundle,
            screenSaverSelectionWriter: selectionWriter
        )

        // When
        try controller.setEnabled(true, activeAsset: nil, displayMode: .fit)

        // Then
        let installedURL = screenSaverDirectory.appending(path: "Background Engine.saver")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL.path))
        XCTAssertEqual(selectionWriter.selectedModules, [
            ScreenSaverModuleSelection(
                moduleName: "Background Engine",
                path: installedURL.path,
                type: 0
            )
        ])
    }

    func testOpenScreenSaverSettingsInstallsAndSelectsBeforeOpeningSettings() throws {
        // Given
        let root = try makeTempDirectory()
        let applicationSupport = root.appending(path: "ApplicationSupport")
        let screenSaverDirectory = root.appending(path: "Screen Savers")
        let bundle = try makeBundleWithScreenSaver(root: root)
        let selectionWriter = RecordingScreenSaverSelectionWriter()
        let settingsOpener = RecordingScreenSaverSettingsOpener()
        let controller = LockScreenAnimationController(
            applicationSupportDirectory: applicationSupport,
            screenSaverDirectory: screenSaverDirectory,
            bundle: bundle,
            screenSaverSelectionWriter: selectionWriter,
            screenSaverSettingsOpener: settingsOpener
        )

        // When
        try controller.openScreenSaverSettings()

        // Then
        let installedURL = screenSaverDirectory.appending(path: "Background Engine.saver")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL.path))
        XCTAssertEqual(selectionWriter.selectedModules.first?.path, installedURL.path)
        XCTAssertEqual(settingsOpener.openCount, 1)
    }

    func testUpdateActiveAssetUsesFreshCachedSceneVideoAsSourcePath() throws {
        // Given
        let root = try makeTempDirectory()
        let applicationSupport = root.appending(path: "ApplicationSupport")
        let screenSaverDirectory = root.appending(path: "Screen Savers")
        let bundle = try makeBundleWithScreenSaver(root: root)
        let cacheDirectory = root.appending(path: "SceneVideoCache")
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        addTeardownBlock {
            SceneVideoCache.overrideCacheDirectoryURL = nil
        }
        let asset = try makeSceneAsset(root: root, id: "scene-1")
        // A cache entry is fresh only if it was written after the scene's
        // source package; write the source first, sleep past filesystem
        // mtime resolution, then write the cache entry.
        Thread.sleep(forTimeInterval: 0.05)
        let cachedVideoURL = SceneVideoCache.cachedVideoURL(assetId: asset.id)
        try FileManager.default.createDirectory(
            at: cachedVideoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1]).write(to: cachedVideoURL)
        let controller = LockScreenAnimationController(
            applicationSupportDirectory: applicationSupport,
            screenSaverDirectory: screenSaverDirectory,
            bundle: bundle
        )

        // When
        try controller.updateActiveAsset(asset, displayMode: .fill)

        // Then
        let configuration = try readConfiguration(applicationSupport: applicationSupport)
        let configuredSourcePath = try XCTUnwrap(configuration["sourcePath"] as? String)
        XCTAssertEqual(
            URL(filePath: configuredSourcePath).resolvingSymlinksInPath().path,
            cachedVideoURL.resolvingSymlinksInPath().path
        )
    }

    func testUpdateActiveVideoDoesNotRequireAFileExtensionForScreenSaverPlayback() throws {
        let root = try makeTempDirectory()
        let applicationSupport = root.appending(path: "ApplicationSupport")
        let videoURL = root.appending(path: "content-probed-video")
        try Data([1]).write(to: videoURL)
        let asset = WallpaperAsset(
            id: "extensionless-video",
            title: "Extensionless Video",
            kind: .video,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: root.path,
            entrypoint: videoURL.path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
        let controller = LockScreenAnimationController(
            applicationSupportDirectory: applicationSupport,
            screenSaverDirectory: root.appending(path: "Screen Savers"),
            bundle: try makeBundleWithScreenSaver(root: root)
        )

        try controller.updateActiveAsset(asset, displayMode: .fill)

        let configuration = try readConfiguration(applicationSupport: applicationSupport)
        XCTAssertEqual(configuration["sourcePath"] as? String, videoURL.path)
    }

    func testUpdateActiveAssetFallsBackToStillImageWithoutCachedSceneVideo() throws {
        // Given
        let root = try makeTempDirectory()
        let applicationSupport = root.appending(path: "ApplicationSupport")
        let screenSaverDirectory = root.appending(path: "Screen Savers")
        let bundle = try makeBundleWithScreenSaver(root: root)
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        addTeardownBlock {
            SceneVideoCache.overrideCacheDirectoryURL = nil
        }
        let asset = try makeSceneAsset(root: root, id: "scene-2")
        let controller = LockScreenAnimationController(
            applicationSupportDirectory: applicationSupport,
            screenSaverDirectory: screenSaverDirectory,
            bundle: bundle
        )

        // When
        try controller.updateActiveAsset(asset, displayMode: .fill)

        // Then
        let configuration = try readConfiguration(applicationSupport: applicationSupport)
        XCTAssertNil(configuration["sourcePath"])
    }

    func testUpdateActiveAnimatedImagePreservesOriginalImagePath() throws {
        let root = try makeTempDirectory()
        let applicationSupport = root.appending(path: "ApplicationSupport")
        let screenSaverDirectory = root.appending(path: "Screen Savers")
        let bundle = try makeBundleWithScreenSaver(root: root)
        let imageURL = root.appending(path: "animated.gif")
        try writeAnimatedGIF(to: imageURL)
        let asset = WallpaperAsset(
            id: "animated-image",
            title: "Animated Image",
            kind: .image,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: root.path,
            entrypoint: imageURL.path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
        let controller = LockScreenAnimationController(
            applicationSupportDirectory: applicationSupport,
            screenSaverDirectory: screenSaverDirectory,
            bundle: bundle
        )

        try controller.updateActiveAsset(asset, displayMode: .fill)

        let configuration = try readConfiguration(applicationSupport: applicationSupport)
        XCTAssertEqual(configuration["imagePath"] as? String, imageURL.path)
        XCTAssertEqual(ImageWallpaperValidation.animatedFrameCount(at: imageURL), 2)
    }

    func testUpdateActiveStaticImageNormalizesExifOrientation() throws {
        let root = try makeTempDirectory()
        let applicationSupport = root.appending(path: "ApplicationSupport")
        let screenSaverDirectory = root.appending(path: "Screen Savers")
        let bundle = try makeBundleWithScreenSaver(root: root)
        let imageURL = root.appending(path: "oriented.jpg")
        try writeOrientedJPEG(to: imageURL)
        let asset = WallpaperAsset(
            id: "oriented-image",
            title: "Oriented Image",
            kind: .image,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: root.path,
            entrypoint: imageURL.path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
        let controller = LockScreenAnimationController(
            applicationSupportDirectory: applicationSupport,
            screenSaverDirectory: screenSaverDirectory,
            stillImageProvider: StillWallpaperImageProvider(
                cacheDirectory: root.appending(path: "GeneratedStillWallpapers")
            ),
            bundle: bundle
        )

        try controller.updateActiveAsset(asset, displayMode: .fill)

        let configuration = try readConfiguration(applicationSupport: applicationSupport)
        let normalizedPath = try XCTUnwrap(configuration["imagePath"] as? String)
        XCTAssertNotEqual(normalizedPath, imageURL.path)
        let normalizedSource = try XCTUnwrap(CGImageSourceCreateWithURL(URL(filePath: normalizedPath) as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(normalizedSource, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 2)
    }

    private func makeSceneAsset(root: URL, id: String) throws -> WallpaperAsset {
        let project = root.appending(path: id)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let entrypoint = project.appending(path: "scene.pkg")
        try Data([1]).write(to: entrypoint)
        return WallpaperAsset(
            id: id,
            title: "Scene \(id)",
            kind: .scene,
            supportStatus: .playable,
            source: .localSteamWorkshop,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: id,
            redistributionAllowed: false,
            issues: []
        )
    }

    private func readConfiguration(applicationSupport: URL) throws -> [String: Any] {
        let configurationURL = applicationSupport
            .appending(path: "LockScreen")
            .appending(path: "active.json")
        let data = try Data(contentsOf: configurationURL)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeBundleWithScreenSaver(root: URL) throws -> Bundle {
        let resources = root.appending(path: "Test.app/Contents/Resources")
        let saver = resources.appending(path: "Background Engine.saver")
        try FileManager.default.createDirectory(at: saver, withIntermediateDirectories: true)
        let info = root.appending(path: "Test.app/Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleIdentifier</key>
          <string>dev.3xhaust.Background EngineTests</string>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
        </dict>
        </plist>
        """.utf8).write(to: info)
        return try XCTUnwrap(Bundle(url: root.appending(path: "Test.app")))
    }

    private func writeAnimatedGIF(to url: URL) throws {
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil)
        )
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ] as CFDictionary)
        for pixel in [Data([255, 0, 0, 255]), Data([0, 0, 255, 255])] {
            let provider = try XCTUnwrap(CGDataProvider(data: pixel as CFData))
            let image = try XCTUnwrap(CGImage(
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ))
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFUnclampedDelayTime: 0.05
                ]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func writeOrientedJPEG(to url: URL) throws {
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        )
        let data = Data([
            255, 0, 0, 255,
            0, 0, 255, 255,
        ])
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 2,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 6
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private final class RecordingScreenSaverSelectionWriter: ScreenSaverSelectionWriting {
    var selectedModules: [ScreenSaverModuleSelection] = []

    func selectScreenSaver(_ selection: ScreenSaverModuleSelection) throws {
        selectedModules.append(selection)
    }
}

private final class RecordingScreenSaverSettingsOpener: ScreenSaverSettingsOpening {
    var openCount = 0

    func openScreenSaverSettings() {
        openCount += 1
    }
}
