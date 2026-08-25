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
        XCTAssertTrue(spec.contains("CURRENT_PROJECT_VERSION: 6"))
        for plist in ["App-Info.plist", "SteamCMDRunner-Info.plist", "ScreenSaver-Info.plist"] {
            let source = try String(repositoryFile: "Config/\(plist)")
            XCTAssertTrue(source.contains("$(MARKETING_VERSION)"), "\(plist) must inherit the milestone version")
            XCTAssertTrue(source.contains("$(CURRENT_PROJECT_VERSION)"), "\(plist) must inherit the build number")
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
        XCTAssertTrue(workflow.contains("background-engine-v0.2.0-alpha.1-build.6-unsigned"))
    }

    func testPackagePinsDocCPluginUsedByDocumentationWorkflow() throws {
        let package = try String(repositoryFile: "Package.swift")
        let workflow = try String(repositoryFile: ".github/workflows/docs.yml")
        XCTAssertTrue(package.contains("https://github.com/swiftlang/swift-docc-plugin"))
        XCTAssertTrue(package.contains("exact: \"1.5.0\""))
        XCTAssertTrue(workflow.contains("swift-actions/setup-swift@v2.4.0"))
    }

    func testReleaseWorkflowPublishesRequiredArtifacts() throws {
        let workflow = try String(repositoryFile: ".github/workflows/release.yml")
        for artifact in ["*.dmg", "*.sha256", "*.json", "source.tar.gz", "COMPATIBILITY.md"] {
            XCTAssertTrue(workflow.contains(artifact))
        }
        XCTAssertTrue(workflow.contains("contents: write"))
        XCTAssertTrue(workflow.contains("gh release create"))
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

    func testPackagingScriptBuildsAndChecksUniversalNestedCode() throws {
        let script = try String(repositoryFile: "Scripts/package-app.sh")
        XCTAssertTrue(script.contains("--arch arm64 --arch x86_64"))
        XCTAssertTrue(script.contains("-arch arm64 -arch x86_64"))
        XCTAssertTrue(script.contains("-verify_arch arm64 x86_64"))
        XCTAssertTrue(script.contains("BackgroundEngineSteamCMDRunner.xpc"))
        XCTAssertTrue(script.contains("Background Engine.saver"))
        XCTAssertTrue(script.contains("cp -R ThirdPartyLicenses"))
        XCTAssertTrue(script.contains("Scripts/scene-golden-parity.sh"))
        XCTAssertTrue(script.contains("Scripts/runtime-script-common.sh"))
        XCTAssertTrue(script.contains("Scripts/create-dmg.sh"))
        XCTAssertFalse(script.contains("hdiutil create"))
        XCTAssertTrue(script.contains("(cd \"$DIST_DIR\" && shasum -a 256 \"$DMG_NAME\")"))
        XCTAssertFalse(script.contains("shasum -a 256 \"$DMG_PATH\""))
    }

    func testPackagedAppDefaultsToAlphaReleaseVersion() throws {
        let script = try String(repositoryFile: "Scripts/package-app.sh")
        let spec = try String(repositoryFile: "project.yml")
        XCTAssertTrue(script.contains("APP_VERSION=\"${APP_VERSION:-0.2.0-alpha.1}\""))
        XCTAssertTrue(script.contains("BUNDLE_VERSION=\"${BUNDLE_VERSION:-6}\""))
        XCTAssertTrue(spec.contains("CURRENT_PROJECT_VERSION: 6"))

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
    }

    func testRendererBuildVersionStaysSynchronizedAcrossCacheAndReleaseMetadata() throws {
        let renderer = try String(repositoryFile: "Sources/BackgroundEngineApp/SceneVideoRenderer.swift")
        let notices = try String(repositoryFile: "THIRD_PARTY_NOTICES.md")
        let sbom = try String(repositoryFile: "Scripts/generate-sbom.sh")
        let ci = try String(repositoryFile: ".github/workflows/ci.yml")
        let release = try String(repositoryFile: ".github/workflows/release.yml")
        let build = "7acc6c9-be2"

        XCTAssertTrue(renderer.contains("rendererVersion = \"\(build)\""))
        XCTAssertTrue(renderer.contains("static let cacheVersion = 13"))
        XCTAssertTrue(notices.contains("renderer build: `\(build)`"))
        XCTAssertTrue(sbom.contains("\"version\": \"\(build)\""))
        XCTAssertTrue(ci.contains("wallpaperengine-mac-renderer-\(build)-source.tar.gz"))
        XCTAssertTrue(ci.contains("-DBUILD_TESTING=ON"))
        XCTAssertTrue(ci.contains("system-font-resolver-tests"))
        XCTAssertTrue(ci.contains("-R '^SystemFontResolver$'"))
        XCTAssertTrue(release.contains("wallpaperengine-mac-renderer-\(build)-source.tar.gz"))
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
