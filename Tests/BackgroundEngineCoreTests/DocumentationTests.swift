import XCTest

final class DocumentationTests: XCTestCase {
    func testReadmeDescribesProductInReviewableOrder() throws {
        let readme = try String(repositoryFile: "README.md")
        assertHeadings(
            ["## Current capabilities", "## Build", "## Package a DMG", "## Legal and content ownership"],
            appearInOrderIn: readme
        )
        XCTAssertTrue(readme.contains("macOS 14+"))
        XCTAssertTrue(readme.contains("arm64") || readme.contains("Apple Silicon"))
        XCTAssertTrue(readme.contains("Intel"))
    }

    func testV1InterfaceIsEnglishOnly() throws {
        let viewModel = try String(repositoryFile: "Sources/BackgroundEngineApp/AppViewModel.swift")
        let settings = try String(repositoryFile: "Sources/BackgroundEngineApp/SettingsTabView.swift")
        XCTAssertTrue(viewModel.contains("Localization.string(key)"))
        XCTAssertFalse(settings.contains("settings.language.korean"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: testRepositoryPath("Sources/BackgroundEngineApp/Resources/ko.lproj")
            )
        )
    }

    func testReadmeKeepsSafetyAndSupportFacts() throws {
        let readme = try String(repositoryFile: "README.md")
        for fact in ["431960", "MP4", "SteamCMD", "SHA-256", "Unsupported", "No telemetry"] {
            XCTAssertTrue(readme.contains(fact), "README is missing \(fact)")
        }
        XCTAssertTrue(readme.contains("~/Library/Application Support/Background Engine"))
        XCTAssertTrue(readme.contains("DNS rebinding"))
        let libraryView = try String(repositoryFile: "Sources/BackgroundEngineApp/LibraryTabView.swift")
        XCTAssertTrue(libraryView.contains("not a complete local-network boundary"))
        XCTAssertTrue(libraryView.contains("only continue for a wallpaper you trust"))
    }

    func testLibraryExposesUserSuppliedLivelyPackageImportAction() throws {
        let libraryView = try String(
            repositoryFile: "Sources/BackgroundEngineApp/LibraryTabView.swift"
        )

        XCTAssertTrue(libraryView.contains("Button(\"Add Lively…\")"))
        XCTAssertTrue(libraryView.contains("model.chooseLivelyWallpaperPackage()"))
        XCTAssertTrue(
            libraryView.contains(
                "Import a user-provided Lively Wallpaper .zip export or project folder."
            )
        )
    }

    func testUserSuppliedLivelyDocsCoverSafeStagingAndNonredistribution() throws {
        let readme = try String(repositoryFile: "README.md")
        let importGuide = try String(
            repositoryFile: "Sources/User_Documentation_en_US/Documentation.docc/articles/"
                + "import-your-first-wallpaper.md"
        )
        let supportedTypes = try String(
            repositoryFile: "Sources/User_Documentation_en_US/Documentation.docc/articles/"
                + "supported-wallpaper-types.md"
        )

        XCTAssertTrue(readme.contains("user-provided Lively Wallpaper `.zip` exports or project folders"))
        XCTAssertTrue(readme.contains("only on an isolated staging copy"))
        XCTAssertTrue(readme.contains("user-owned, non-redistributable content"))

        XCTAssertTrue(importGuide.contains("Lively Wallpaper `.zip` export or project folder"))
        XCTAssertTrue(importGuide.contains("temporary staging copy"))
        XCTAssertTrue(importGuide.contains("never edits the selected package"))
        XCTAssertTrue(importGuide.contains("never marked for"))
        XCTAssertTrue(importGuide.contains("redistribution."))
        XCTAssertTrue(importGuide.contains("URL and video-stream exports"))
        XCTAssertTrue(importGuide.contains("exports accept public"))
        XCTAssertTrue(importGuide.contains("HTTPS targets only"))
        XCTAssertTrue(importGuide.contains("Lively buttons"))

        XCTAssertTrue(supportedTypes.contains("Lively Wallpaper `.zip` exports and folders"))
        XCTAssertTrue(supportedTypes.contains("`LivelyInfo.json`"))
        XCTAssertTrue(supportedTypes.contains("Button controls"))
        XCTAssertTrue(supportedTypes.contains("reported as **Limited**"))
        XCTAssertTrue(supportedTypes.contains("property edit refreshes every"))
    }

    func testXcodeProjectSpecDefinesAllProductsAndBundleIdentifiers() throws {
        let spec = try String(repositoryFile: "project.yml")
        for target in [
            "BackgroundEngineApp", "BackgroundEngineCore", "BackgroundEngineSteamCMDRunner",
            "BackgroundEngineScreenSaver", "BackgroundEngineCoreTests", "BackgroundEngineAppTests",
            "BackgroundEngineUITests"
        ] {
            XCTAssertTrue(spec.contains(target))
        }
        XCTAssertTrue(spec.contains("com.lamppkk.backgroundengine.steamcmd-runner"))
        XCTAssertTrue(spec.contains("com.lamppkk.backgroundengine.screensaver"))
    }

    func testXcodeProductsShareAlphaMilestoneVersionMetadata() throws {
        let spec = try String(repositoryFile: "project.yml")
        XCTAssertTrue(spec.contains("MARKETING_VERSION: 0.2.0-alpha.1"))
        XCTAssertTrue(spec.contains("CURRENT_PROJECT_VERSION: 19"))
        for plist in ["App-Info.plist", "SteamCMDRunner-Info.plist", "ScreenSaver-Info.plist"] {
            let source = try String(repositoryFile: "Config/\(plist)")
            XCTAssertTrue(source.contains("$(MARKETING_VERSION)"), "\(plist) must inherit the milestone version")
            XCTAssertTrue(source.contains("$(CURRENT_PROJECT_VERSION)"), "\(plist) must inherit the build number")
        }
    }

    func testEveryAppPackagingPathAllowsOnlyExplicitIPv4LoopbackHTTPForWebPlayback() throws {
        let appPlist = try String(repositoryFile: "Config/App-Info.plist")
        let spec = try String(repositoryFile: "project.yml")
        let packageScript = try String(repositoryFile: "Scripts/package-app.sh")

        for source in [appPlist, spec, packageScript] {
            XCTAssertTrue(source.contains("NSAppTransportSecurity"))
            XCTAssertTrue(source.contains("NSExceptionDomains"))
            XCTAssertTrue(source.contains("127.0.0.1"))
            XCTAssertTrue(source.contains("NSExceptionAllowsInsecureHTTPLoads"))
            XCTAssertFalse(source.contains("NSAllowsLocalNetworking"))
            XCTAssertFalse(source.contains("NSAllowsArbitraryLoads"))
        }
    }

    func testAppHostedWebMediaSmokeUsesPortableExplicitToolSettings() throws {
        let spec = try String(repositoryFile: "project.yml")
        let scheme = try String(
            repositoryFile: "Background Engine.xcodeproj/xcshareddata/xcschemes/Background Engine.xcscheme"
        )
        XCTAssertTrue(spec.contains("-DXCODE_APP_HOST_TESTS"))
        XCTAssertTrue(spec.contains("$(BACKGROUND_ENGINE_TEST_FFMPEG)"))
        XCTAssertTrue(spec.contains("$(BACKGROUND_ENGINE_TEST_FFPROBE)"))
        XCTAssertTrue(scheme.contains("$(BACKGROUND_ENGINE_TEST_FFMPEG)"))
        XCTAssertTrue(scheme.contains("$(BACKGROUND_ENGINE_TEST_FFPROBE)"))
        XCTAssertFalse(scheme.contains("/private/tmp/"))

        for workflowPath in [
            ".github/workflows/ci.yml",
            ".github/workflows/release.yml"
        ] {
            let workflow = try String(repositoryFile: workflowPath)
            XCTAssertTrue(workflow.contains("Run app-hosted WebKit H.264 playback smoke"))
            XCTAssertTrue(workflow.contains("BACKGROUND_ENGINE_TEST_FFMPEG"))
            XCTAssertTrue(workflow.contains("BACKGROUND_ENGINE_TEST_FFPROBE"))
            XCTAssertTrue(
                workflow.contains(
                    "-only-testing:BackgroundEngineAppTests/RestrictedWebWallpaperViewTests/"
                        + "testRealWKWebViewPlaysSeeksAndLoopsPreparedH264WithoutLegacyTypeHint"
                )
            )
            XCTAssertTrue(workflow.contains("Executed 1 test, with 0 failures"))
        }
    }

    func testCiWorkflowRunsOnAppleSiliconAndIntel() throws {
        let workflow = try String(repositoryFile: ".github/workflows/ci.yml")
        XCTAssertTrue(workflow.contains("macos-15-intel"))
        XCTAssertTrue(workflow.contains("macos-15"))
        XCTAssertTrue(workflow.contains("swift test"))
        XCTAssertTrue(workflow.contains("renderer-smoke"))
        XCTAssertTrue(workflow.contains("xcodebuild"))
        XCTAssertTrue(workflow.contains("ARCHS=${{ matrix.arch }}"))
        XCTAssertTrue(workflow.contains("ONLY_ACTIVE_ARCH=YES"))
        XCTAssertTrue(workflow.contains("background-engine-v0.2.0-alpha.1-build.19-unsigned"))
    }

    func testPackagePinsDocCPluginUsedByDocumentationWorkflow() throws {
        let package = try String(repositoryFile: "Package.swift")
        let workflow = try String(repositoryFile: ".github/workflows/docs.yml")
        XCTAssertTrue(package.contains("https://github.com/swiftlang/swift-docc-plugin"))
        XCTAssertTrue(package.contains("exact: \"1.5.0\""))
        XCTAssertTrue(
            workflow.contains(
                "image: swift:6.0-jammy@sha256:1ad73b8f2a2300c650da0949519418565661d802765b9a99435df22bc947e2b4"
            )
        )
    }

    func testReleaseWorkflowPublishesRequiredArtifacts() throws {
        let workflow = try String(repositoryFile: ".github/workflows/release.yml")
        for artifact in ["*.dmg", "*.sha256", "*.json", "source.tar.gz", "COMPATIBILITY.md"] {
            XCTAssertTrue(workflow.contains(artifact))
        }
        XCTAssertTrue(workflow.contains("contents: write"))
        XCTAssertTrue(workflow.contains("gh release create \"$RELEASE_TAG\""))
    }

    func testReleaseWorkflowFailsClosedBeforeExpensiveJobsAndUsesResolvedMetadata() throws {
        let workflow = try String(repositoryFile: ".github/workflows/release.yml")

        XCTAssertTrue(workflow.contains("release_tag:"))
        XCTAssertTrue(workflow.contains("marketing_version:"))
        XCTAssertTrue(workflow.contains("default: 0.2.0-alpha.1"))
        XCTAssertTrue(workflow.contains("build_number:"))
        XCTAssertTrue(workflow.contains("default: \"18\""))
        XCTAssertTrue(workflow.contains("./Scripts/resolve-release-metadata.sh"))
        XCTAssertTrue(workflow.contains("./Scripts/verify-release-destination.sh"))
        XCTAssertTrue(workflow.contains("verify:\n    needs: [preflight, media]"))
        XCTAssertTrue(workflow.contains("renderer:\n    needs: preflight"))
        XCTAssertTrue(workflow.contains("media:\n    needs: preflight"))
        XCTAssertTrue(
            workflow.contains("notarized-dmg:\n    needs: [preflight, verify, renderer, media]")
        )
        XCTAssertTrue(workflow.contains("APP_VERSION: ${{ needs.preflight.outputs.marketing_version }}"))
        XCTAssertTrue(workflow.contains("BUNDLE_VERSION: ${{ needs.preflight.outputs.build_number }}"))
        XCTAssertTrue(workflow.contains("--verify-tag"))
        XCTAssertTrue(workflow.contains("--target \"$GITHUB_SHA\""))
        XCTAssertTrue(workflow.contains("--title \"Background Engine $MARKETING_VERSION ($BUILD_NUMBER)\""))
        XCTAssertFalse(workflow.contains("${GITHUB_REF_NAME#v}"))
    }

    func testReleaseRequiresSigningAndNotarization() throws {
        let workflow = try String(repositoryFile: ".github/workflows/release.yml")
        let package = try String(repositoryFile: "Scripts/package-app.sh")
        XCTAssertTrue(workflow.contains("BUILD_CERTIFICATE_BASE64"))
        XCTAssertTrue(workflow.contains("notarytool store-credentials"))
        XCTAssertTrue(workflow.contains("REQUIRE_SIGNING: \"1\""))
        XCTAssertTrue(workflow.contains("REQUIRE_NOTARIZATION: \"1\""))
        XCTAssertTrue(package.contains("xcrun stapler staple"))
        XCTAssertTrue(package.contains("spctl --assess"))
    }

    func testThirdPartyNoticesPinEveryUpstream() throws {
        let notices = try String(repositoryFile: "THIRD_PARTY_NOTICES.md")
        XCTAssertTrue(notices.contains("fa0929c582914d28a896577d56b29c5ccf2e2bb8"))
        XCTAssertTrue(notices.contains("c0b8becfc77ff8c73141129aa37af8a8f68b510d"))
        XCTAssertTrue(notices.contains("7acc6c92e0175d53e1cb6b2b2dff52f79faf83e0"))
        XCTAssertTrue(notices.contains("0083c721dcc0fa6df55a0a011678c11493ad2810"))
        XCTAssertTrue(notices.contains("b9f585368264c79de997d7d82e10d2dc85f3024e"))
        XCTAssertTrue(notices.contains("does not bypass ownership"))
    }

    func testCuratedLivelyCollectionIsPackagedWithPinnedProvenanceAndNotices() throws {
        let package = try String(repositoryFile: "Package.swift")
        let spec = try String(repositoryFile: "project.yml")
        let notices = try String(repositoryFile: "THIRD_PARTY_NOTICES.md")
        let musicMIT = try String(
            repositoryFile: "ThirdPartyLicenses/Lively-Music-TV-MIT.txt"
        )
        let catalog = try String(
            repositoryFile: "Sources/BackgroundEngineApp/Resources/LivelyWallpapers/catalog.json"
        )

        XCTAssertTrue(package.contains(".copy(\"Resources/LivelyWallpapers\")"))
        XCTAssertTrue(spec.contains("Sources/BackgroundEngineApp/Resources/LivelyWallpapers"))
        XCTAssertTrue(spec.contains("type: folder"))
        for pinnedValue in [
            "v2.2.1.0",
            "6860a4093fc50058c4815908658a4391c4449935",
            "98f4e96bb8e2c416384eeaf48016eadaea9dce8263b8d212052775ebcf2d7e34"
        ] {
            XCTAssertTrue(catalog.contains(pinnedValue))
            XCTAssertTrue(notices.contains(pinnedValue))
        }
        for identifier in [
            "lively-the-hill", "lively-periodic-table", "lively-parallax",
            "lively-music-tv", "lively-depth-observatory", "lively-chromatic-fluids"
        ] {
            XCTAssertTrue(catalog.contains("\"id\": \"\(identifier)\""))
        }
        XCTAssertFalse(catalog.contains("\"id\": \"lively-triangles-light\""))
        XCTAssertFalse(catalog.contains("\"id\": \"lively-medusae\""))
        XCTAssertTrue(notices.contains("Lively-Music-TV-MIT.txt"))
        XCTAssertTrue(notices.contains("Lively-Music-TV-FilmShader-CC-BY-3.0.txt"))
        XCTAssertTrue(catalog.contains("Earcut-ISC.txt"))
        XCTAssertTrue(notices.contains("Earcut-ISC.txt"))
        XCTAssertTrue(musicMIT.contains("stats.js"))
        XCTAssertTrue(musicMIT.contains("https://github.com/mrdoob/stats.js"))
    }

    func testSBOMDeclaresPlashAndEveryBundledLivelyWallpaperLicense() throws {
        let sbom = try String(repositoryFile: "Scripts/generate-sbom.sh")

        for required in [
            "PlashRuntime",
            "b9f585368264c79de997d7d82e10d2dc85f3024e",
            "Lively bundled wallpaper collection",
            "rocksdanister/lively@6860a4093fc50058c4815908658a4391c4449935",
            "98f4e96bb8e2c416384eeaf48016eadaea9dce8263b8d212052775ebcf2d7e34",
            "Lively wallpaper: The Hill",
            "Lively wallpaper: Periodic Table",
            "Lively wallpaper: Parallax.js",
            "Lively wallpaper: Music TV (LQ)",
            "Lively wallpaper: Depth Observatory",
            "Lively wallpaper: Chromatic Fluids",
            "a85bbf10244b0978dd7ca32c56553b93dbcd19c2a78eb58a5fa19b2226dfb17a",
            "10519543efbe05f727db1e9c09046b887add60868e6ad24abf60791633be5b4f",
            "43496ded57b3b91524ebbe8ccd371fd6c82bbff84841e75f16cd46c74fc60bb9",
            "4e70957a2fdcc34de02dfd5bbbbc99bdb9e3c53524376ab6981a7c991bd9413b",
            "ede0136a2bd235d20ce8669a545eae3e437808dfe6aa80b8b8c25fa40d68c60b",
            "eba7f82e08d3e72e3f6cde8d4a80738a6d4cef67573e1b53a217c4dc09f7a2c8",
            "Three.js",
            "dat.GUI depthmap snapshot",
            "\"id\": \"OFL-1.1\"",
            "\"id\": \"Apache-2.0\"",
            "\"id\": \"ISC\"",
            "\"id\": \"CC-BY-4.0\"",
            "\"id\": \"CC-BY-3.0\"",
            "\"id\": \"CC0-1.0\""
        ] {
            XCTAssertTrue(sbom.contains(required), required)
        }
        XCTAssertFalse(sbom.contains("Lively wallpaper: Triangles & Light"))
        XCTAssertFalse(sbom.contains("Lively wallpaper: Medusae"))
    }

    func testPackagingScriptBuildsAndChecksUniversalNestedCode() throws {
        let script = try String(repositoryFile: "Scripts/package-app.sh")
        let livelyVerifier = try String(
            repositoryFile: "Scripts/verify-lively-resource-bundle.sh"
        )
        XCTAssertTrue(script.contains("--arch arm64 --arch x86_64"))
        XCTAssertTrue(script.contains("-arch arm64 -arch x86_64"))
        XCTAssertTrue(script.contains("-verify_arch arm64 x86_64"))
        XCTAssertTrue(script.contains("BackgroundEngineSteamCMDRunner.xpc"))
        XCTAssertTrue(script.contains("Background Engine.saver"))
        XCTAssertTrue(script.contains("cp -R ThirdPartyLicenses"))
        XCTAssertTrue(script.contains("Scripts/scene-golden-parity.sh"))
        XCTAssertTrue(script.contains("Scripts/runtime-script-common.sh"))
        XCTAssertTrue(script.contains("Scripts/create-dmg.sh"))
        XCTAssertTrue(script.contains("verify-lively-resource-bundle.sh"))
        XCTAssertTrue(script.contains("LIVELY_WALLPAPER_DIR=\"$(bash"))
        XCTAssertTrue(livelyVerifier.contains("$LIVELY_WALLPAPER_DIR/catalog.json"))
        XCTAssertTrue(livelyVerifier.contains("Contents/Resources/LivelyWallpapers"))
        for identifier in [
            "lively-the-hill", "lively-periodic-table", "lively-parallax",
            "lively-music-tv", "lively-depth-observatory", "lively-chromatic-fluids"
        ] {
            XCTAssertTrue(livelyVerifier.contains(identifier))
        }
        XCTAssertTrue(livelyVerifier.contains("LIVELY_DIRECTORY_COUNT"))
        XCTAssertTrue(livelyVerifier.contains("-ne 6"))
        XCTAssertTrue(livelyVerifier.contains("LIVELY_TOP_LEVEL_COUNT"))
        XCTAssertTrue(livelyVerifier.contains("-ne 7"))
        XCTAssertFalse(script.contains("hdiutil create"))
        XCTAssertTrue(script.contains("(cd \"$DIST_DIR\" && shasum -a 256 \"$DMG_NAME\")"))
        XCTAssertFalse(script.contains("shasum -a 256 \"$DMG_PATH\""))
    }

    func testPackagedAppDefaultsToAlphaReleaseVersion() throws {
        let script = try String(repositoryFile: "Scripts/package-app.sh")
        let spec = try String(repositoryFile: "project.yml")
        XCTAssertTrue(script.contains("APP_VERSION=\"${APP_VERSION:-0.2.0-alpha.1}\""))
        XCTAssertTrue(script.contains("BUNDLE_VERSION=\"${BUNDLE_VERSION:-19}\""))
        XCTAssertTrue(spec.contains("CURRENT_PROJECT_VERSION: 19"))

        let projectBuild = try XCTUnwrap(
            spec.split(whereSeparator: \.isNewline)
                .first { $0.contains("CURRENT_PROJECT_VERSION:") }?
                .split(separator: ":", maxSplits: 1)
                .last?
                .trimmingCharacters(in: .whitespaces)
        )
        XCTAssertTrue(
            script.contains("BUNDLE_VERSION=\"${BUNDLE_VERSION:-\(projectBuild)}\""),
            "The packaged app must use the same build number as the Xcode products."
        )
        let ci = try String(repositoryFile: ".github/workflows/ci.yml")
        let release = try String(repositoryFile: ".github/workflows/release.yml")
        XCTAssertTrue(
            ci.contains("dist/Background Engine.app\" \"0.2.0-alpha.1\" \"\(projectBuild)\""),
            "CI must verify the same build number that package-app.sh writes."
        )
        XCTAssertTrue(
            release.contains(
                "dist/Background Engine.app\" \"$APP_VERSION\" \"$BUNDLE_VERSION\""
            ),
            "Release packaging must verify the same build number that package-app.sh writes."
        )
    }

    func testRendererBuildVersionStaysSynchronizedAcrossCacheAndReleaseMetadata() throws {
        let renderer = try String(repositoryFile: "Sources/BackgroundEngineApp/SceneVideoRenderer.swift")
        let notices = try String(repositoryFile: "THIRD_PARTY_NOTICES.md")
        let sbom = try String(repositoryFile: "Scripts/generate-sbom.sh")
        let ci = try String(repositoryFile: ".github/workflows/ci.yml")
        let release = try String(repositoryFile: ".github/workflows/release.yml")
        let build = "7acc6c9-be4"

        XCTAssertTrue(renderer.contains("rendererVersion = \"\(build)\""))
        XCTAssertTrue(renderer.contains("static let cacheVersion = 16"))
        XCTAssertTrue(notices.contains("renderer build: `\(build)`"))
        XCTAssertTrue(sbom.contains("\"version\": \"\(build)\""))
        XCTAssertTrue(ci.contains("wallpaperengine-mac-renderer-\(build)-source.tar.gz"))
        XCTAssertTrue(ci.contains("-DBUILD_TESTING=ON"))
        XCTAssertTrue(ci.contains("system-font-resolver-tests"))
        XCTAssertTrue(ci.contains("-R '^SystemFontResolver$'"))
        XCTAssertTrue(ci.contains("shader-sampler-requirements-tests"))
        XCTAssertTrue(ci.contains("-R '^ShaderSamplerRequirements$'"))
        XCTAssertTrue(release.contains("wallpaperengine-mac-renderer-\(build)-source.tar.gz"))
    }

    func testSceneCompatibilityProbeVersionIsDocumented() throws {
        let compatibility = try String(repositoryFile: "Sources/BackgroundEngineCore/Compatibility.swift")
        let readme = try String(repositoryFile: "README.md")

        XCTAssertTrue(compatibility.contains("currentProbeVersion = 19"))
        XCTAssertTrue(readme.contains("Compatibility probe version 19"))
        XCTAssertTrue(readme.contains("at most two distinct external renders"))
        XCTAssertTrue(readme.contains("preserves FIFO order"))
        XCTAssertTrue(readme.contains("SteamCMD `validate`"))
        XCTAssertTrue(readme.contains("distinct **Importing** state"))
        XCTAssertTrue(readme.contains("rejects a genuinely overlapping Workshop operation"))
        XCTAssertTrue(readme.contains("immediate download step cannot receive a false busy result"))
        XCTAssertTrue(readme.contains("former 512 MiB inspection limit"))
        XCTAssertTrue(readme.contains("bounded inline import maps"))
        XCTAssertTrue(readme.contains("bare and URL-like keys"))
        XCTAssertTrue(readme.contains("Static `fetch`, XHR, WebSocket, EventSource"))
        XCTAssertTrue(readme.contains("dynamic request targets"))
        XCTAssertTrue(readme.contains("web_interaction_limited"))
        XCTAssertTrue(readme.contains("supportsaudioprocessing"))
        XCTAssertTrue(readme.contains("audioprocessingmode"))
        XCTAssertTrue(readme.contains("g_Audio*"))
        XCTAssertTrue(readme.contains("valid string `playbackmode`"))
        XCTAssertTrue(readme.contains("non-string value is invalid renderer metadata"))
        XCTAssertFalse(readme.contains("missing, wrapped, or differently cased values play once"))
    }

    func testFrameDiffScriptBoundsImageAllocationBeforeDecodingPixels() throws {
        let script = try String(repositoryFile: "Scripts/scene-frame-diff.swift")
        XCTAssertTrue(script.contains("maximumImagePixels"))
        XCTAssertTrue(script.contains("checkedPixelCount"))
        XCTAssertTrue(script.contains("imageTooLarge"))
    }

    func testSceneParityToolsAreImplementedAndFailClosed() throws {
        let cli = try String(repositoryFile: "Sources/becli/BECLI.swift")
        XCTAssertFalse(cli.contains("renderer capture comparison is not implemented yet"))
        XCTAssertTrue(cli.contains("sceneGoldenParityScriptURL"))
        XCTAssertTrue(cli.contains("--out <dir>"))

        for path in ["Scripts/scene-parity-compare.sh", "Scripts/scene-golden-parity.sh"] {
            let script = try String(repositoryFile: path)
            XCTAssertTrue(script.contains("be_resolve_new_output"), "\(path) must reject existing output")
        }
    }

    private func assertHeadings(_ headings: [String], appearInOrderIn readme: String) {
        var searchStart = readme.startIndex
        for heading in headings {
            guard let range = readme.range(of: heading, range: searchStart..<readme.endIndex) else {
                XCTFail("Missing or out-of-order README heading: \(heading)")
                return
            }
            searchStart = range.upperBound
        }
    }
}
