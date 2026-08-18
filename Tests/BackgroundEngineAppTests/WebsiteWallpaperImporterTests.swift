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
    }
}
