import BackgroundEngineCore
import Foundation
import XCTest
@testable import BackgroundEngineApp

final class WebsiteWallpaperImporterTests: XCTestCase {
    func testRejectsNonHTTPSURLsAndEmbeddedCredentials() {
        XCTAssertThrowsError(try RemoteWebWallpaperConfiguration(targetURL: URL(string: "file:///tmp/a")!))
        XCTAssertThrowsError(
            try RemoteWebWallpaperConfiguration(targetURL: URL(string: "http://example.com")!)
        )
        XCTAssertThrowsError(
            try RemoteWebWallpaperConfiguration(targetURL: URL(string: "https://user:pass@example.com")!)
        )
        for blocked in [
            "https://localhost",
            "https://service.local",
            "https://127.0.0.1",
            "https://2130706433",
            "https://10.1.2.3",
            "https://100.64.0.1",
            "https://169.254.1.2",
            "https://172.16.1.2",
            "https://192.168.1.2",
            "https://[::1]",
            "https://[::ffff:127.0.0.1]",
            "https://[fc00::1]",
            "https://[fe80::1]"
        ] {
            XCTAssertThrowsError(
                try RemoteWebWallpaperConfiguration(targetURL: URL(string: blocked)!),
                "Expected blocked remote Web target: \(blocked)"
            )
        }
        XCTAssertNoThrow(
            try RemoteWebWallpaperConfiguration(targetURL: URL(string: "https://example.com")!)
        )
    }

    func testImportsRemoteWebsiteAsSandboxedWebProject() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "background-engine-website-import-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)

        let imported = try await WebsiteWallpaperImporter(store: store)
            .importWebsite("https://example.com/dashboard")

        XCTAssertEqual(imported.kind, .web)
        XCTAssertEqual(imported.supportStatus, .playable)
        XCTAssertEqual(imported.allowsNetworkAccess, true)
        let projectRoot = URL(filePath: imported.projectDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.entrypoint ?? ""))
        XCTAssertEqual(
            RemoteWebWallpaperConfiguration.load(projectRoot: projectRoot)?.targetURL,
            URL(string: "https://example.com/dashboard")
        )
        let stored = try XCTUnwrap(store.load().assets.first)
        XCTAssertEqual(stored.id, imported.id)
        XCTAssertEqual(stored.kind, .web)
        XCTAssertEqual(stored.allowsNetworkAccess, true)
        XCTAssertEqual(stored.contentHash, imported.contentHash)

        let blocked = try store.setWebNetworkAccess(assetID: imported.id, allowed: false)
        XCTAssertEqual(blocked.supportStatus, .unsupported)
        XCTAssertEqual(blocked.compatibilityReport?.missingCapabilities, [.externalNetwork])
        XCTAssertEqual(blocked.compatibilityReport?.diagnosticCode, "web_network_access_required")

        let restored = try store.setWebNetworkAccess(assetID: imported.id, allowed: true)
        XCTAssertEqual(restored.supportStatus, .playable)
        XCTAssertEqual(restored.compatibilityReport?.level, .limited)
        XCTAssertEqual(restored.compatibilityReport?.requiredCapabilities, [.externalNetwork])
        XCTAssertTrue(restored.compatibilityReport?.missingCapabilities.isEmpty == true)
        XCTAssertEqual(
            restored.compatibilityReport?.diagnosticCode,
            "web_remote_runtime_unverified"
        )
    }

    func testRemoteWebsiteConfigurationRejectsOversizedAndSymlinkedMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "background-engine-website-config-bounds-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appending(path: "background-engine-website-config-outside-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let configURL = root.appending(path: RemoteWebWallpaperConfiguration.fileName)
        XCTAssertTrue(FileManager.default.createFile(atPath: configURL.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: configURL)
        try handle.truncate(atOffset: 16 * 1_024 + 1)
        try handle.close()
        XCTAssertNil(RemoteWebWallpaperConfiguration.load(projectRoot: root))
        XCTAssertEqual(
            RemoteWebWallpaperConfiguration.state(projectRoot: root),
            .invalid(.unsafeOrUnreadableMetadata)
        )

        try FileManager.default.removeItem(at: configURL)
        let valid = try RemoteWebWallpaperConfiguration(targetURL: URL(string: "https://example.com")!)
        try JSONEncoder().encode(valid).write(to: outside)
        try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: outside)
        XCTAssertNil(RemoteWebWallpaperConfiguration.load(projectRoot: root))
        XCTAssertEqual(
            RemoteWebWallpaperConfiguration.state(projectRoot: root),
            .invalid(.unsafeOrUnreadableMetadata)
        )
    }

    func testRemoteWebsiteConfigurationStateDistinguishesAbsentValidAndLegacyHTTP() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "background-engine-website-config-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appending(path: RemoteWebWallpaperConfiguration.fileName)

        XCTAssertEqual(RemoteWebWallpaperConfiguration.state(projectRoot: root), .absent)

        let valid = try RemoteWebWallpaperConfiguration(
            targetURL: URL(string: "https://example.com/live")!
        )
        try JSONEncoder().encode(valid).write(to: configURL, options: .atomic)
        XCTAssertEqual(
            RemoteWebWallpaperConfiguration.state(projectRoot: root),
            .valid(valid)
        )

        try #"{"schemaVersion":1,"targetURL":"http://legacy.example.com/live"}"#
            .write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            RemoteWebWallpaperConfiguration.state(projectRoot: root),
            .invalid(.invalidTargetURL)
        )
    }
}
