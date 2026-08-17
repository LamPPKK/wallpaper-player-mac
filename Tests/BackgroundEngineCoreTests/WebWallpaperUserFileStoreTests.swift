import Foundation
import XCTest
@testable import BackgroundEngineCore

final class WebWallpaperUserFileStoreTests: XCTestCase {
    func testSelectionIsCopiedUnderAssetWithSanitizedPropertyName() async throws {
        let asset = try Fixture.makeTempDirectory()
        let source = try Fixture.makeTempDirectory().appending(path: "selected image.png")
        try Data([1, 2, 3]).write(to: source)

        let copied = try await WebWallpaperUserFileStore().copySelection(
            source,
            propertyName: "custom/background",
            into: asset
        )

        XCTAssertTrue(copied.lastPathComponent.hasPrefix("custom-background-"))
        XCTAssertEqual(copied.pathExtension, "png")
        XCTAssertTrue(copied.path.contains(WebWallpaperUserFileStore.directoryName))
        XCTAssertEqual(try Data(contentsOf: copied), Data([1, 2, 3]))
        let overridesURL = asset
            .appending(path: WebWallpaperUserFileStore.directoryName)
            .appending(path: WebWallpaperUserFileStore.overridesFileName)
        let overrides = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: overridesURL)
        )
        XCTAssertEqual(overrides["custom/background"], "\(WebWallpaperUserFileStore.directoryName)/\(copied.lastPathComponent)")
    }

    func testSelectionRejectsSymlink() async throws {
        let asset = try Fixture.makeTempDirectory()
        let sourceRoot = try Fixture.makeTempDirectory()
        let original = sourceRoot.appending(path: "original.txt")
        let symlink = sourceRoot.appending(path: "selected.txt")
        try Data([1]).write(to: original)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)

        do {
            _ = try await WebWallpaperUserFileStore().copySelection(
                symlink,
                propertyName: "file",
                into: asset
            )
            XCTFail("Expected symlink rejection")
        } catch {
            XCTAssertEqual(error as? WallpaperImportError, .symbolicLink(symlink.path))
        }
    }

    func testSanitizedPropertyNameCollisionsUseDistinctDestinations() async throws {
        let asset = try Fixture.makeTempDirectory()
        let sources = try Fixture.makeTempDirectory()
        let first = sources.appending(path: "first.txt")
        let second = sources.appending(path: "second.txt")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)
        let store = WebWallpaperUserFileStore()

        let firstCopy = try await store.copySelection(first, propertyName: "a/b", into: asset)
        let secondCopy = try await store.copySelection(second, propertyName: "a?b", into: asset)

        XCTAssertNotEqual(firstCopy.lastPathComponent, secondCopy.lastPathComponent)
        XCTAssertEqual(firstCopy.pathExtension, "txt")
        XCTAssertEqual(secondCopy.pathExtension, "txt")
    }
}
