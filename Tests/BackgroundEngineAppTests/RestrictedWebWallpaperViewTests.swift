import XCTest
@testable import BackgroundEngineApp

final class RestrictedWebWallpaperViewTests: XCTestCase {
    func testWebWallpaperDoesNotLoadWhenRemoteBlockerCompilationFails() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/RestrictedWebWallpaperView.swift")

        XCTAssertTrue(source.contains("guard error == nil, let ruleList else"))
        XCTAssertFalse(source.contains("if let ruleList {"))
    }

    func testNavigationPolicyRestrictsFilesToProjectRootAndRejectsDownloads() {
        let root = URL(filePath: "/tmp/background-engine-web/project")
        XCTAssertTrue(
            RestrictedWebNavigationPolicy.allows(
                root.appending(path: "index.html"),
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: false
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                root.deletingLastPathComponent().appending(path: "secret.html"),
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: true
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                root.appending(path: "file.zip"),
                projectRoot: root,
                isMainFrame: false,
                networkAccessAllowed: true,
                isDownload: true
            )
        )
    }

    func testNavigationPolicyAllowsOptedInNetworkOnlyInSubframes() {
        let root = URL(filePath: "/tmp/background-engine-web/project")
        let remote = URL(string: "https://example.com/texture.png")
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                remote,
                projectRoot: root,
                isMainFrame: false,
                networkAccessAllowed: false
            )
        )
        XCTAssertTrue(
            RestrictedWebNavigationPolicy.allows(
                remote,
                projectRoot: root,
                isMainFrame: false,
                networkAccessAllowed: true
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                remote,
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: true
            )
        )
    }
}
