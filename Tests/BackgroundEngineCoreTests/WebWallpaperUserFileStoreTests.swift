import Darwin
import Foundation
import XCTest
@testable import BackgroundEngineCore

final class WebWallpaperUserFileStoreTests: XCTestCase {
    func testScalarValueOverridesRoundTripAndReplaceAtomically() async throws {
        let asset = try Fixture.makeTempDirectory()
        let store = WebWallpaperUserFileStore()
        try await store.saveValueOverrides(
            [
                "enabled": .bool(true),
                "speed": .number(1.25),
                "caption": .text("Hello")
            ],
            into: asset
        )
        let initialValues = try await store.loadValueOverrides(from: asset)
        XCTAssertEqual(
            initialValues,
            [
                "enabled": .bool(true),
                "speed": .number(1.25),
                "caption": .text("Hello")
            ]
        )

        try await store.saveValueOverrides(
            ["enabled": .bool(false)],
            into: asset
        )

        let replacedValues = try await store.loadValueOverrides(from: asset)
        XCTAssertEqual(
            replacedValues,
            ["enabled": .bool(false)]
        )
        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(
                at: storage,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)),
            [WebWallpaperUserFileStore.valueOverridesFileName]
        )
    }

    func testScalarValueCommitFailureKeepsCompletePreviousDocument() async throws {
        let asset = try Fixture.makeTempDirectory()
        try await WebWallpaperUserFileStore().saveValueOverrides(
            ["enabled": .bool(true)],
            into: asset
        )
        let failingStore = WebWallpaperUserFileStore(
            metadataCommitter: FailingWebWallpaperMetadataCommitter()
        )

        do {
            try await failingStore.saveValueOverrides(
                ["enabled": .bool(false)],
                into: asset
            )
            XCTFail("Expected injected atomic metadata commit failure")
        } catch let error as FailingWebWallpaperMetadataCommitter.Failure {
            XCTAssertEqual(error, .injected)
        }

        let preserved = try await WebWallpaperUserFileStore().loadValueOverrides(from: asset)
        XCTAssertEqual(preserved, ["enabled": .bool(true)])
        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(
                at: storage,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)),
            [WebWallpaperUserFileStore.valueOverridesFileName]
        )
    }

    func testScalarAndFileOverridesFromDifferentStoresDoNotClobberEachOther() async throws {
        let asset = try Fixture.makeTempDirectory()
        let source = try Fixture.makeTempDirectory().appending(path: "selected.png")
        try Data([1, 2, 3]).write(to: source)

        async let copied = WebWallpaperUserFileStore().copySelection(
            source,
            propertyName: "photo",
            into: asset
        )
        async let scalar: Void = WebWallpaperUserFileStore().saveValueOverrides(
            ["enabled": .bool(false), "speed": .number(2)],
            into: asset
        )
        _ = try await (copied, scalar)

        let scalarValues = try await WebWallpaperUserFileStore().loadValueOverrides(from: asset)
        XCTAssertEqual(
            scalarValues,
            ["enabled": .bool(false), "speed": .number(2)]
        )
        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: storage.appending(path: WebWallpaperUserFileStore.overridesFileName).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: storage.appending(path: WebWallpaperUserFileStore.valueOverridesFileName).path
            )
        )
    }

    func testScalarValueOverridesDoNotFollowMetadataSymlink() async throws {
        let asset = try Fixture.makeTempDirectory()
        let outside = try Fixture.makeTempDirectory().appending(path: "outside.json")
        try Data("{\"keep\":true}".utf8).write(to: outside)
        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let valuesURL = storage.appending(path: WebWallpaperUserFileStore.valueOverridesFileName)
        try FileManager.default.createSymbolicLink(at: valuesURL, withDestinationURL: outside)

        do {
            try await WebWallpaperUserFileStore().saveValueOverrides(
                ["enabled": .bool(true)],
                into: asset
            )
            XCTFail("Expected scalar metadata symlink rejection")
        } catch let error as WallpaperImportError {
            XCTAssertEqual(error, .symbolicLink(valuesURL.path))
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("{\"keep\":true}".utf8))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: valuesURL.path),
            outside.path
        )
    }

    func testScalarValueOverrideLoadRejectsSymlinkedStorageRoot() async throws {
        let asset = try Fixture.makeTempDirectory()
        let outside = try Fixture.makeTempDirectory()
        let valuesURL = outside.appending(path: WebWallpaperUserFileStore.valueOverridesFileName)
        try JSONEncoder().encode(["enabled": WebWallpaperPropertyOverrideValue.bool(false)])
            .write(to: valuesURL)
        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        try FileManager.default.createSymbolicLink(at: storage, withDestinationURL: outside)

        do {
            _ = try await WebWallpaperUserFileStore().loadValueOverrides(from: asset)
            XCTFail("Expected symlinked scalar storage rejection")
        } catch let error as WallpaperImportError {
            XCTAssertEqual(error, .unsafeRoot(storage.path))
        }
    }

    func testScalarValueOverridesRejectOversizedTextBeforeCreatingStorage() async throws {
        let asset = try Fixture.makeTempDirectory()
        let oversized = String(
            repeating: "x",
            count: WebWallpaperUserFileStore.maximumTextValueBytes + 1
        )

        do {
            try await WebWallpaperUserFileStore().saveValueOverrides(
                ["caption": .text(oversized)],
                into: asset
            )
            XCTFail("Expected oversized scalar value rejection")
        } catch let error as WallpaperImportError {
            guard case let .tooLarge(actual, maximum) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(actual, UInt64(WebWallpaperUserFileStore.maximumTextValueBytes + 1))
            XCTAssertEqual(maximum, UInt64(WebWallpaperUserFileStore.maximumTextValueBytes))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: asset.appending(path: WebWallpaperUserFileStore.directoryName).path
            )
        )
    }

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

    func testSelectionRejectsOversizedOverrideMetadata() async throws {
        let asset = try Fixture.makeTempDirectory()
        let sources = try Fixture.makeTempDirectory()
        let originalSource = sources.appending(path: "original.png")
        let replacementSource = sources.appending(path: "replacement.png")
        try Data([1]).write(to: originalSource)
        try Data([2]).write(to: replacementSource)
        let store = WebWallpaperUserFileStore()
        let destination = try await store.copySelection(
            originalSource,
            propertyName: "photo",
            into: asset
        )
        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        let overrides = storage.appending(path: WebWallpaperUserFileStore.overridesFileName)
        let handle = try FileHandle(forWritingTo: overrides)
        try handle.truncate(
            atOffset: UInt64(WebWallpaperUserFileStore.maximumOverrideMetadataBytes + 1)
        )
        try handle.close()

        do {
            _ = try await store.copySelection(
                replacementSource,
                propertyName: "photo",
                into: asset
            )
            XCTFail("Expected oversized override metadata rejection")
        } catch let error as WallpaperImportError {
            guard case let .tooLarge(actual, maximum) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(actual, UInt64(WebWallpaperUserFileStore.maximumOverrideMetadataBytes + 1))
            XCTAssertEqual(maximum, UInt64(WebWallpaperUserFileStore.maximumOverrideMetadataBytes))
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data([1]))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: overrides.path)[.size] as? NSNumber,
            NSNumber(value: WebWallpaperUserFileStore.maximumOverrideMetadataBytes + 1)
        )
    }

    func testSelectionDoesNotFollowOverrideMetadataSymlink() async throws {
        let asset = try Fixture.makeTempDirectory()
        let sourceRoot = try Fixture.makeTempDirectory()
        let source = sourceRoot.appending(path: "selected.png")
        let outside = sourceRoot.appending(path: "outside.json")
        try Data([1]).write(to: source)
        try Data("{}".utf8).write(to: outside)
        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let overrides = storage.appending(path: WebWallpaperUserFileStore.overridesFileName)
        try FileManager.default.createSymbolicLink(at: overrides, withDestinationURL: outside)

        do {
            _ = try await WebWallpaperUserFileStore().copySelection(
                source,
                propertyName: "photo",
                into: asset
            )
            XCTFail("Expected override symlink rejection")
        } catch let error as WallpaperImportError {
            XCTAssertEqual(error, .symbolicLink(overrides.path))
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("{}".utf8))
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(
                at: storage,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)),
            [WebWallpaperUserFileStore.overridesFileName]
        )
    }

    func testSelectionRejectsOverrideMetadataThatWouldExceedLimit() async throws {
        let asset = try Fixture.makeTempDirectory()
        let source = try Fixture.makeTempDirectory().appending(path: "selected.png")
        try Data([1]).write(to: source)
        let propertyName = String(
            repeating: "p",
            count: WebWallpaperUserFileStore.maximumOverrideMetadataBytes
        )

        do {
            _ = try await WebWallpaperUserFileStore().copySelection(
                source,
                propertyName: propertyName,
                into: asset
            )
            XCTFail("Expected encoded override metadata limit rejection")
        } catch let error as WallpaperImportError {
            guard case let .tooLarge(actual, maximum) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, UInt64(WebWallpaperUserFileStore.maximumOverrideMetadataBytes))
        }

        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil),
            []
        )
    }

    func testSelectionDoesNotBlockOnOverrideMetadataFIFO() async throws {
        let asset = try Fixture.makeTempDirectory()
        let source = try Fixture.makeTempDirectory().appending(path: "selected.png")
        try Data([1]).write(to: source)
        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let overrides = storage.appending(path: WebWallpaperUserFileStore.overridesFileName)
        let fifoResult = overrides.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
        }
        XCTAssertEqual(fifoResult, 0)
        let emergencyUnblock = Task.detached {
            do {
                // Let the one-second assertion fail before rescuing a
                // regressed blocking open. A correct O_NONBLOCK reader
                // finishes immediately and cancels this sleep.
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            repeat {
                // Opening and closing a writer is enough to wake a regressed
                // blocking reader. Do not write: a reader that closes first
                // would make SIGPIPE terminate the XCTest process.
                let writer = overrides.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return Int32(-1) }
                    return Darwin.open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
                }
                if writer >= 0 {
                    Darwin.close(writer)
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(25))
                } catch {
                    return
                }
            } while ContinuousClock.now < deadline
        }
        let clock = ContinuousClock()
        let started = clock.now
        let result: Result<URL, Error>
        do {
            result = .success(try await WebWallpaperUserFileStore().copySelection(
                source,
                propertyName: "photo",
                into: asset
            ))
        } catch {
            result = .failure(error)
        }
        let elapsed = started.duration(to: clock.now)
        emergencyUnblock.cancel()
        _ = await emergencyUnblock.result

        XCTAssertLessThan(elapsed, .seconds(1), "Override metadata FIFO blocked the file-store actor")
        switch result {
        case .success:
            XCTFail("Expected FIFO rejection")
        case .failure(let error as WallpaperImportError):
            XCTAssertEqual(error, .notRegularFile(overrides.path))
        case .failure(let error):
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(
                at: storage,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)),
            [WebWallpaperUserFileStore.overridesFileName]
        )
    }
}

private struct FailingWebWallpaperMetadataCommitter: WebWallpaperMetadataCommitting {
    enum Failure: Error, Equatable {
        case injected
    }

    func commit(incoming: URL, destination: URL) throws {
        throw Failure.injected
    }
}
