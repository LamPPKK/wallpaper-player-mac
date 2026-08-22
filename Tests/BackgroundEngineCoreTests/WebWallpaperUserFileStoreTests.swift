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

    func testDirectorySelectionRejectsHiddenSymlink() async throws {
        let asset = try Fixture.makeTempDirectory()
        let source = try Fixture.makeTempDirectory()
        let outside = try Fixture.makeTempDirectory().appending(path: "secret.txt")
        let hiddenSymlink = source.appending(path: ".escape")
        try Data([7]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: hiddenSymlink, withDestinationURL: outside)

        do {
            _ = try await WebWallpaperUserFileStore().copySelection(
                source,
                propertyName: "gallery",
                into: asset
            )
            XCTFail("Expected hidden symlink rejection")
        } catch {
            guard case .symbolicLink(let rejectedPath) = error as? WallpaperImportError else {
                return XCTFail("Expected symbolicLink, got \(error)")
            }
            XCTAssertEqual(URL(filePath: rejectedPath).lastPathComponent, ".escape")
        }
    }

    func testDirectorySelectionRejectsAssetRootToAvoidRecursiveCopy() async throws {
        let asset = try Fixture.makeTempDirectory()
        try Data([1]).write(to: asset.appending(path: "index.html"))

        do {
            _ = try await WebWallpaperUserFileStore().copySelection(
                asset,
                propertyName: "gallery",
                into: asset
            )
            XCTFail("Expected recursive source rejection")
        } catch {
            guard case .unsafeRoot = error as? WallpaperImportError else {
                return XCTFail("Expected unsafeRoot, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: asset.appending(path: WebWallpaperUserFileStore.directoryName).path
            )
        )
    }

    func testConcurrentStoreInstancesPreserveEveryPropertyOverride() async throws {
        let asset = try Fixture.makeTempDirectory()
        let sourceRoot = try Fixture.makeTempDirectory()
        let propertyCount = 12
        for index in 0..<propertyCount {
            try Data(repeating: UInt8(index), count: 128 * 1_024)
                .write(to: sourceRoot.appending(path: "source-\(index).bin"))
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<propertyCount {
                group.addTask {
                    _ = try await WebWallpaperUserFileStore().copySelection(
                        sourceRoot.appending(path: "source-\(index).bin"),
                        propertyName: "property-\(index)",
                        into: asset
                    )
                }
            }
            try await group.waitForAll()
        }

        let overridesURL = asset
            .appending(path: WebWallpaperUserFileStore.directoryName)
            .appending(path: WebWallpaperUserFileStore.overridesFileName)
        let overrides = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: overridesURL)
        )
        XCTAssertEqual(Set(overrides.keys), Set((0..<propertyCount).map { "property-\($0)" }))
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
