import BackgroundEngineCore
import Foundation
import XCTest
@testable import BackgroundEngineApp

final class WebsiteWallpaperImporterTests: XCTestCase {
    func testRejectsNonHTTPURLsAndEmbeddedCredentials() {
        XCTAssertThrowsError(try RemoteWebWallpaperConfiguration(targetURL: URL(string: "file:///tmp/a")!))
        XCTAssertThrowsError(
            try RemoteWebWallpaperConfiguration(targetURL: URL(string: "https://user:pass@example.com")!)
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
        XCTAssertEqual(restored.compatibilityReport?.level, .full)
        XCTAssertEqual(restored.compatibilityReport?.requiredCapabilities, [.externalNetwork])
        XCTAssertTrue(restored.compatibilityReport?.missingCapabilities.isEmpty == true)
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

        try FileManager.default.removeItem(at: configURL)
        let valid = try RemoteWebWallpaperConfiguration(targetURL: URL(string: "https://example.com")!)
        try JSONEncoder().encode(valid).write(to: outside)
        try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: outside)
        XCTAssertNil(RemoteWebWallpaperConfiguration.load(projectRoot: root))
    }
}
