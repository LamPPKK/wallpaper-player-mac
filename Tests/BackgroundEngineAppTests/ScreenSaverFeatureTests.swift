import XCTest

final class ScreenSaverFeatureTests: XCTestCase {
    func testScreenSaverSettingsOpenUsesWallpaperSettingsPane() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/LockScreenAnimationController.swift")

        XCTAssertTrue(source.contains("x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"))
        XCTAssertFalse(source.contains("x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension"))
    }

    func testScreenSaverControlsUseScreenSaverLanguage() throws {
        // Settings-tab controls now source their labels from Localizable.strings
        // rather than a string literal in Swift source (see AppViewModel.L(_:)),
        // so check the English table alongside the still-literal StatusMenu/AppViewModel copy.
        let settingsTab = try String(repositoryFile: "Sources/BackgroundEngineApp/SettingsTabView.swift")
        let localizableEn = try String(
            repositoryFile: "Sources/BackgroundEngineApp/Resources/en.lproj/Localizable.strings"
        )
        let statusMenu = try String(repositoryFile: "Sources/BackgroundEngineApp/StatusMenu.swift")
        let viewModel = try String(repositoryFile: "Sources/BackgroundEngineApp/AppViewModel.swift")

        XCTAssertTrue(settingsTab.contains("settings.animateScreenSaver"))
        XCTAssertTrue(localizableEn.contains("\"settings.animateScreenSaver\" = \"Animate Screen Saver\";"))
        XCTAssertTrue(statusMenu.contains("Animate Screen Saver"))
        XCTAssertTrue(viewModel.contains("Installed and selected Background Engine Screen Saver"))
        XCTAssertFalse(statusMenu.contains("Animate Lock Screen"))
        XCTAssertFalse(viewModel.contains("Animated Lock Screen"))
    }

    func testSceneAssetsSettingsExposePickerAndReset() throws {
        let settingsTab = try String(repositoryFile: "Sources/BackgroundEngineApp/SettingsTabView.swift")
        let localizableEn = try String(
            repositoryFile: "Sources/BackgroundEngineApp/Resources/en.lproj/Localizable.strings"
        )
        let viewModel = try String(repositoryFile: "Sources/BackgroundEngineApp/AppViewModel.swift")
        let wallpaperPlayer = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")

        XCTAssertTrue(settingsTab.contains("settings.scene.title"))
        XCTAssertTrue(localizableEn.contains("\"settings.scene.title\" = \"Scene Engine Assets\";"))
        XCTAssertTrue(localizableEn.contains("\"settings.scene.choose\" = \"Choose Assets Folder...\";"))
        XCTAssertTrue(settingsTab.contains("model.chooseSceneAssetsFolder()"))
        XCTAssertTrue(settingsTab.contains("model.clearSceneAssetsFolder()"))
        XCTAssertTrue(viewModel.contains("steamapps/common/wallpaper_engine/assets"))
        XCTAssertTrue(wallpaperPlayer.contains("materials/"))
        XCTAssertTrue(wallpaperPlayer.contains("shaders/"))
    }

    func testScreenSaverViewShowsFallbackInsteadOfBlackOnlyContent() throws {
        let source = try String(
            repositoryFile: "Sources/BackgroundEngineScreenSaver/BackgroundEngineScreenSaverView.m"
        )

        XCTAssertTrue(source.contains("showFallbackMessage"))
        XCTAssertTrue(source.contains("Background Engine"))
        XCTAssertTrue(source.contains("Choose it in Wallpaper settings"))
        XCTAssertFalse(source.contains("@\"Background Engine has no playable Screen Saver media selected.\""))
    }

    func testScreenSaverReadsConfigurationFromRealUserHomeOutsideLegacyHostContainer() throws {
        let source = try String(
            repositoryFile: "Sources/BackgroundEngineScreenSaver/BackgroundEngineScreenSaverView.m"
        )

        XCTAssertTrue(source.contains("#import <pwd.h>"))
        XCTAssertTrue(source.contains("#import <unistd.h>"))
        XCTAssertTrue(source.contains("- (NSArray<NSURL *> *)configurationURLs"))
        XCTAssertTrue(source.contains("- (NSURL *)realHomeApplicationSupportURL"))
        XCTAssertTrue(source.contains("getpwuid(getuid())"))
        XCTAssertTrue(source.contains("Library/Application Support"))
        XCTAssertTrue(source.contains("[self configurationURLFromApplicationSupport:realHomeApplicationSupport]"))
    }

    func testScreenSaverFallbackLayerUsesNonzeroBackingScale() throws {
        let source = try String(
            repositoryFile: "Sources/BackgroundEngineScreenSaver/BackgroundEngineScreenSaverView.m"
        )

        XCTAssertTrue(source.contains("- (CGFloat)backingScaleFactor"))
        XCTAssertTrue(source.contains("self.window.screen.backingScaleFactor"))
        XCTAssertTrue(source.contains("return 1.0"))
        XCTAssertTrue(source.contains("self.fallbackLayer.contentsScale = [self backingScaleFactor]"))
        XCTAssertFalse(source.contains("NSScreen.mainScreen.backingScaleFactor"))
    }

    func testScreenSaverKeepsStillFallbackVisibleBehindVideoPlayback() throws {
        let source = try String(
            repositoryFile: "Sources/BackgroundEngineScreenSaver/BackgroundEngineScreenSaverView.m"
        )

        XCTAssertTrue(source.contains("NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath]"))
        XCTAssertTrue(source.contains("showVideoAtURL:sourceURL fallbackImageURL:"))
        XCTAssertTrue(source.contains("- (void)showVideoAtURL:(NSURL *)url fallbackImageURL:(NSURL *)fallbackImageURL"))
        XCTAssertTrue(source.contains("if (hasFallbackImage) {\n        [self showImageAtURL:fallbackImageURL displayMode:displayMode];"))
        XCTAssertTrue(source.contains("self.playerLayer.hidden = hasFallbackImage"))
        XCTAssertTrue(source.contains("if (self.observedPlayerItem.status == AVPlayerItemStatusReadyToPlay)"))
        XCTAssertTrue(source.contains("[self revealVideoPlayback]"))
        XCTAssertTrue(source.contains("if (self.observedPlayerItem.status == AVPlayerItemStatusFailed)"))
        XCTAssertTrue(source.contains("self.playerLayer.hidden = YES"))
        XCTAssertTrue(source.contains("dispatch_async(dispatch_get_main_queue()"))
        XCTAssertTrue(source.contains("BackgroundEnginePlayerItemStatusContext"))
    }

    func testScreenSaverChecksOptionalPathsBeforeConstructingFileURLs() throws {
        let source = try String(
            repositoryFile: "Sources/BackgroundEngineScreenSaver/BackgroundEngineScreenSaverView.m"
        )

        XCTAssertTrue(source.contains("if (sourcePath != nil && [self canUseVideoAtPath:sourcePath])"))
        XCTAssertTrue(source.contains("if (imagePath != nil && [self canUseImageAtPath:imagePath])"))
        XCTAssertTrue(source.contains("NSURL *fallbackImageURL = nil"))
    }

    func testScreenSaverShowsDiagnosticInsteadOfBlackWhenStillImageFailsToLoad() throws {
        let source = try String(
            repositoryFile: "Sources/BackgroundEngineScreenSaver/BackgroundEngineScreenSaverView.m"
        )

        XCTAssertTrue(source.contains("CGImageRef cgImage = source ? BackgroundEngineCreateValidatedImageAtIndex(source, 0) : NULL;"))
        XCTAssertTrue(source.contains("if (!source || !cgImage) {"))
        XCTAssertTrue(source.contains("[self showFallbackMessage:[NSString stringWithFormat:@\"Could not load the wallpaper image at %@.\", url.path]];"))
    }

    func testSceneVideoRenderCompletionRefreshesLockScreenConfiguration() throws {
        let wallpaperPlayer = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")
        let viewModel = try String(repositoryFile: "Sources/BackgroundEngineApp/AppViewModel.swift")

        XCTAssertTrue(wallpaperPlayer.contains("static var sceneVideoRenderCompletionHandler: ((String) -> Void)?"))
        XCTAssertTrue(wallpaperPlayer.contains("sceneVideoRenderCompletionHandler?(assetId)"))
        XCTAssertTrue(viewModel.contains("SceneWallpaperContentFactory.sceneVideoRenderCompletionHandler = { [weak self] assetId in"))
        XCTAssertTrue(viewModel.contains("refreshLockScreenAnimationConfigurationAfterSceneVideoRender(assetId: assetId)"))
    }

    func testLockScreenAnimationControllerReusesFreshCachedSceneVideoAsSourcePath() throws {
        let source = try String(
            repositoryFile: "Sources/BackgroundEngineApp/LockScreenAnimationController.swift"
        )

        XCTAssertTrue(source.contains("if asset.kind == .scene {"))
        XCTAssertTrue(source.contains("contentHash: asset.contentHash"))
    }

    func testScreenSaverViewHasAppKitDrawingFallbackForLegacyHosts() throws {
        let source = try String(
            repositoryFile: "Sources/BackgroundEngineScreenSaver/BackgroundEngineScreenSaverView.m"
        )

        XCTAssertTrue(source.contains("@property(nonatomic, strong) NSImage *fallbackImage"))
        XCTAssertTrue(source.contains("@property(nonatomic, copy) NSString *fallbackDisplayMode"))
        XCTAssertTrue(source.contains("@property(nonatomic, copy) NSString *fallbackMessage"))
        XCTAssertTrue(source.contains("- (void)drawRect:(NSRect)rect"))
        XCTAssertTrue(source.contains("[NSColor.blackColor setFill]"))
        XCTAssertTrue(source.contains("[self.fallbackImage drawInRect:"))
        XCTAssertTrue(source.contains("[self.fallbackMessage drawInRect:"))
        XCTAssertTrue(source.contains("[self fallbackImageRectForImageSize:self.fallbackImage.size displayMode:self.fallbackDisplayMode]"))
        XCTAssertTrue(source.contains("self.fallbackImage = [[NSImage alloc] initWithCGImage:image size:size]"))
        XCTAssertTrue(source.contains("self.fallbackDisplayMode = displayMode"))
        XCTAssertTrue(source.contains("self.fallbackMessage = nil"))
        XCTAssertTrue(source.contains("self.fallbackImage = nil"))
        XCTAssertTrue(source.contains("self.fallbackMessage = [NSString stringWithFormat:"))
        XCTAssertTrue(source.contains("self.layer.contents = (__bridge id)image"))
        XCTAssertTrue(source.contains("self.layer.contentsGravity = [self contentsGravityForDisplayMode:displayMode]"))
        XCTAssertTrue(source.contains("self.layer.contents = nil"))
        XCTAssertTrue(source.contains("[self setNeedsDisplay:YES]"))
    }

    func testScreenSaverAnimatesBoundedImageIOFrames() throws {
        let source = try String(
            repositoryFile: "Sources/BackgroundEngineScreenSaver/BackgroundEngineScreenSaverView.m"
        )

        XCTAssertTrue(source.contains("#import <ImageIO/ImageIO.h>"))
        XCTAssertTrue(source.contains("CGImageSourceRef _imageSource"))
        XCTAssertTrue(source.contains("- (void)advanceAnimatedImageIfNeeded"))
        XCTAssertTrue(source.contains("- (NSTimeInterval)animatedImageFrameDurationAtIndex:"))
        XCTAssertTrue(source.contains("CGImageSourceCreateThumbnailAtIndex"))
        XCTAssertTrue(source.contains("kCGImageSourceCreateThumbnailWithTransform"))
        XCTAssertTrue(source.contains("CGImageGetBytesPerRow"))
        XCTAssertTrue(source.contains("[self advanceAnimatedImageIfNeeded]"))
        XCTAssertTrue(source.contains("CGImageSourceGetCount"))
        XCTAssertTrue(source.contains("CFRelease(_imageSource)"))
    }
}
