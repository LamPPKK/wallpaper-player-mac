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
        XCTAssertTrue(spec.contains("CURRENT_PROJECT_VERSION: 3"))
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
        XCTAssertTrue(notices.contains("does not bypass ownership"))
    }

    func testPackagingScriptBuildsAndChecksUniversalNestedCode() throws {
        let script = try String(repositoryFile: "Scripts/package-app.sh")
        XCTAssertTrue(script.contains("--arch arm64 --arch x86_64"))
        XCTAssertTrue(script.contains("-arch arm64 -arch x86_64"))
        XCTAssertTrue(script.contains("-verify_arch arm64 x86_64"))
        XCTAssertTrue(script.contains("BackgroundEngineSteamCMDRunner.xpc"))
        XCTAssertTrue(script.contains("Background Engine.saver"))
    }

    func testPackagedAppDefaultsToAlphaReleaseVersion() throws {
        let script = try String(repositoryFile: "Scripts/package-app.sh")
        XCTAssertTrue(script.contains("APP_VERSION=\"${APP_VERSION:-0.2.0-alpha.1}\""))
        XCTAssertTrue(script.contains("BUNDLE_VERSION=\"${BUNDLE_VERSION:-3}\""))
    }

    func testFrameDiffScriptBoundsImageAllocationBeforeDecodingPixels() throws {
        let script = try String(repositoryFile: "Scripts/scene-frame-diff.swift")
        XCTAssertTrue(script.contains("maximumImagePixels"))
        XCTAssertTrue(script.contains("checkedPixelCount"))
        XCTAssertTrue(script.contains("imageTooLarge"))
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
