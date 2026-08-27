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

    func testScalarValueOverridesRejectSymlinkedAssetRoot() async throws {
        let outside = try Fixture.makeTempDirectory()
        let linkParent = try Fixture.makeTempDirectory()
        let linkedAsset = linkParent.appending(path: "linked-asset")
        try FileManager.default.createSymbolicLink(at: linkedAsset, withDestinationURL: outside)

        do {
            try await WebWallpaperUserFileStore().saveValueOverrides(
                ["enabled": .bool(true)],
                into: linkedAsset
            )
            XCTFail("Expected the symlinked asset root to be rejected")
        } catch let error as WallpaperImportError {
            XCTAssertEqual(error, .unsafeRoot(linkedAsset.path))
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
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

    func testClearSelectionRemovesOnlyNamedOverrideAndKeepsSandboxCopies() async throws {
        let asset = try Fixture.makeTempDirectory()
        let sources = try Fixture.makeTempDirectory()
        let photo = sources.appending(path: "photo.png")
        let sound = sources.appending(path: "sound.ogg")
        try Data([1, 2, 3]).write(to: photo)
        try Data([4, 5, 6]).write(to: sound)
        let store = WebWallpaperUserFileStore()
        let copiedPhoto = try await store.copySelection(
            photo,
            propertyName: "gallery",
            into: asset
        )
        let copiedSound = try await store.copySelection(
            sound,
            propertyName: "sound",
            into: asset
        )

        try await store.clearSelection(propertyName: "gallery", from: asset)

        let overridesURL = asset
            .appending(path: WebWallpaperUserFileStore.directoryName)
            .appending(path: WebWallpaperUserFileStore.overridesFileName)
        let overrides = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: overridesURL)
        )
        XCTAssertNil(overrides["gallery"])
        XCTAssertNotNil(overrides["sound"])
        XCTAssertEqual(try Data(contentsOf: copiedPhoto), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: copiedSound), Data([4, 5, 6]))
    }

    func testLivelyFolderDropdownCopyPreservesFilenameAndNumbersCollisions() async throws {
        let asset = try Fixture.makeTempDirectory()
        let images = asset.appending(path: "images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let source = try Fixture.makeTempDirectory().appending(path: "photo.jpg")
        try Data([1, 2, 3]).write(to: source)
        let store = WebWallpaperUserFileStore()

        let first = try await store.copyLivelyFolderDropdownSelection(
            source,
            propertyName: "gallery",
            projectRelativeFolder: "images",
            allowedExtensions: ["jpg", "png"],
            into: asset
        )
        let second = try await store.copyLivelyFolderDropdownSelection(
            source,
            propertyName: "gallery",
            projectRelativeFolder: "images",
            allowedExtensions: ["jpg", "png"],
            into: asset
        )

        XCTAssertEqual(first.lastPathComponent, "photo.jpg")
        XCTAssertEqual(second.lastPathComponent, "photo (1).jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        let overridesURL = storage.appending(path: WebWallpaperUserFileStore.overridesFileName)
        let overrides = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: overridesURL)
        )
        XCTAssertEqual(overrides["gallery"], "images/photo (1).jpg")
        let mappings = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: storage.appending(
                path: WebWallpaperUserFileStore.folderDropdownFilesFileName
            ))
        )
        XCTAssertEqual(Set(mappings.keys), ["images/photo.jpg", "images/photo (1).jpg"])
        for storedRelativePath in mappings.values {
            XCTAssertEqual(
                try Data(contentsOf: storage.appending(path: storedRelativePath)),
                Data([1, 2, 3])
            )
        }
    }

    func testLivelyFolderDropdownCopyRejectsFilterTraversalAndSymlinkFolder() async throws {
        let asset = try Fixture.makeTempDirectory()
        let images = asset.appending(path: "images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let sources = try Fixture.makeTempDirectory()
        let script = sources.appending(path: "script.js")
        let photo = sources.appending(path: "photo.jpg")
        try Data("alert(1)".utf8).write(to: script)
        try Data([1]).write(to: photo)
        let store = WebWallpaperUserFileStore()

        do {
            _ = try await store.copyLivelyFolderDropdownSelection(
                script,
                propertyName: "gallery",
                projectRelativeFolder: "images",
                allowedExtensions: ["jpg"],
                into: asset
            )
            XCTFail("Expected the authored extension filter to reject JavaScript")
        } catch let error as WallpaperImportError {
            guard case .notRegularFile = error else {
                return XCTFail("Unexpected filter error: \(error)")
            }
        }

        do {
            _ = try await store.copyLivelyFolderDropdownSelection(
                photo,
                propertyName: "gallery",
                projectRelativeFolder: "../outside",
                allowedExtensions: ["jpg"],
                into: asset
            )
            XCTFail("Expected traversal rejection")
        } catch let error as WallpaperImportError {
            XCTAssertEqual(error, .pathEscape("../outside"))
        }

        let outside = try Fixture.makeTempDirectory()
        let linkedFolder = asset.appending(path: "linked-images")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: outside)
        do {
            _ = try await store.copyLivelyFolderDropdownSelection(
                photo,
                propertyName: "gallery",
                projectRelativeFolder: "linked-images",
                allowedExtensions: ["jpg"],
                into: asset
            )
            XCTFail("Expected symlinked authored-folder rejection")
        } catch let error as WallpaperImportError {
            XCTAssertEqual(error, .unsafeRoot(linkedFolder.path))
        }
    }

    func testLivelyFolderDropdownCopyRejectsRuntimeUnrepresentableFilenames() async throws {
        let asset = try Fixture.makeTempDirectory()
        try FileManager.default.createDirectory(
            at: asset.appending(path: "images"),
            withIntermediateDirectories: true
        )
        let sources = try Fixture.makeTempDirectory()
        let store = WebWallpaperUserFileStore()

        for filename in ["back\\slash.jpg", "control\ncharacter.jpg"] {
            let source = sources.appending(path: filename)
            try Data([1, 2, 3]).write(to: source)
            do {
                _ = try await store.copyLivelyFolderDropdownSelection(
                    source,
                    propertyName: "gallery",
                    projectRelativeFolder: "images",
                    allowedExtensions: ["jpg"],
                    into: asset
                )
                XCTFail("Expected the runtime-unrepresentable filename to be rejected")
            } catch let error as WallpaperImportError {
                XCTAssertEqual(error, .notRegularFile(source.path))
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: asset.appending(path: WebWallpaperUserFileStore.directoryName).path
        ))
    }

    func testLivelyFolderDropdownCopyRejectsSymlinkedAssetRoot() async throws {
        let outside = try Fixture.makeTempDirectory()
        try FileManager.default.createDirectory(
            at: outside.appending(path: "images"),
            withIntermediateDirectories: true
        )
        let linkParent = try Fixture.makeTempDirectory()
        let linkedAsset = linkParent.appending(path: "linked-asset")
        try FileManager.default.createSymbolicLink(at: linkedAsset, withDestinationURL: outside)
        let source = try Fixture.makeTempDirectory().appending(path: "photo.jpg")
        try Data([1, 2, 3]).write(to: source)

        do {
            _ = try await WebWallpaperUserFileStore().copyLivelyFolderDropdownSelection(
                source,
                propertyName: "gallery",
                projectRelativeFolder: "images",
                allowedExtensions: ["jpg"],
                into: linkedAsset
            )
            XCTFail("Expected the symlinked asset root to be rejected")
        } catch let error as WallpaperImportError {
            XCTAssertEqual(error, .unsafeRoot(linkedAsset.path))
        }

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: outside.path),
            ["images"]
        )
    }

    func testLivelyFolderDropdownCommitFailureRestoresMetadataAndRemovesCopy() async throws {
        let asset = try Fixture.makeTempDirectory()
        let images = asset.appending(path: "images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let sources = try Fixture.makeTempDirectory()
        let existingSource = sources.appending(path: "existing.png")
        let newSource = sources.appending(path: "photo.jpg")
        try Data([1]).write(to: existingSource)
        try Data([2]).write(to: newSource)
        _ = try await WebWallpaperUserFileStore().copySelection(
            existingSource,
            propertyName: "existing",
            into: asset
        )
        let failingStore = WebWallpaperUserFileStore(
            metadataCommitter: FailingWebWallpaperMetadataCommitter()
        )

        do {
            _ = try await failingStore.copyLivelyFolderDropdownSelection(
                newSource,
                propertyName: "gallery",
                projectRelativeFolder: "images",
                allowedExtensions: ["jpg"],
                into: asset
            )
            XCTFail("Expected injected Lively metadata commit failure")
        } catch let error as FailingWebWallpaperMetadataCommitter.Failure {
            XCTAssertEqual(error, .injected)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: images.appending(path: "photo.jpg").path))
        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        let overrides = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: storage.appending(path: WebWallpaperUserFileStore.overridesFileName))
        )
        XCTAssertNotNil(overrides["existing"])
        XCTAssertNil(overrides["gallery"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appending(
            path: WebWallpaperUserFileStore.folderDropdownFilesFileName
        ).path))
        let managedDirectory = storage.appending(
            path: WebWallpaperUserFileStore.folderDropdownFilesDirectoryName
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: managedDirectory.path),
            []
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: storage.path).contains {
                $0.contains(".incoming-") || $0.contains(".previous-")
            }
        )
    }

    func testLivelyFolderDropdownRetainsPrivateFileWhenMetadataRollbackIsUncertain() async throws {
        let asset = try Fixture.makeTempDirectory()
        let images = asset.appending(path: "images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let sources = try Fixture.makeTempDirectory()
        let original = sources.appending(path: "original.jpg")
        let replacement = sources.appending(path: "replacement.jpg")
        try Data("original".utf8).write(to: original)
        let replacementBytes = Data("replacement".utf8)
        try replacementBytes.write(to: replacement)
        _ = try await WebWallpaperUserFileStore().copyLivelyFolderDropdownSelection(
            original,
            propertyName: "gallery",
            projectRelativeFolder: "images",
            allowedExtensions: ["jpg"],
            into: asset
        )
        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        let failingStore = WebWallpaperUserFileStore(
            metadataCommitter: RenameThenDeleteBackupMetadataCommitter(directory: storage)
        )

        do {
            _ = try await failingStore.copyLivelyFolderDropdownSelection(
                replacement,
                propertyName: "gallery",
                projectRelativeFolder: "images",
                allowedExtensions: ["jpg"],
                into: asset
            )
            XCTFail("Expected an uncertain metadata rollback")
        } catch {
            let recoveryError = error as NSError
            XCTAssertEqual(
                recoveryError.domain,
                "com.lamppkk.backgroundengine.lively-file-recovery"
            )
            XCTAssertNotNil(recoveryError.userInfo["BackgroundEngineRecoveryPath"] as? String)
        }

        let mappings = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: storage.appending(
                path: WebWallpaperUserFileStore.folderDropdownFilesFileName
            ))
        )
        let retainedPath = try XCTUnwrap(mappings["images/replacement.jpg"])
        XCTAssertEqual(
            try Data(contentsOf: storage.appending(path: retainedPath)),
            replacementBytes
        )
    }

    func testLivelyFolderDropdownSourceSwapUsesPinnedDescriptorAndFailsClosed() async throws {
        let asset = try Fixture.makeTempDirectory()
        try FileManager.default.createDirectory(
            at: asset.appending(path: "images"),
            withIntermediateDirectories: true
        )
        let sources = try Fixture.makeTempDirectory()
        let source = sources.appending(path: "photo.jpg")
        let openedSource = sources.appending(path: "opened-photo.jpg")
        try Data([1, 2, 3]).write(to: source)
        let mutation = SynchronousRaceMutation()
        let store = WebWallpaperUserFileStore(
            metadataCommitter: AtomicWebWallpaperMetadataCommitter(),
            livelyCopyObserver: { event in
                guard case .sourceOpened = event else { return }
                mutation.run {
                    try FileManager.default.moveItem(at: source, to: openedSource)
                    let result = source.withUnsafeFileSystemRepresentation { path -> Int32 in
                        guard let path else { return -1 }
                        return Darwin.mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
                    }
                    guard result == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                }
            }
        )

        do {
            _ = try await store.copyLivelyFolderDropdownSelection(
                source,
                propertyName: "gallery",
                projectRelativeFolder: "images",
                allowedExtensions: ["jpg"],
                into: asset
            )
            XCTFail("Expected a raced source path to be rejected")
        } catch let error as WallpaperImportError {
            XCTAssertEqual(error, .notRegularFile(source.path))
        }

        XCTAssertNil(mutation.error)
        XCTAssertEqual(try Data(contentsOf: openedSource), Data([1, 2, 3]))
        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appending(
            path: WebWallpaperUserFileStore.overridesFileName
        ).path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: storage.appending(
                    path: WebWallpaperUserFileStore.folderDropdownFilesDirectoryName
                ).path
            ),
            []
        )
    }

    func testLivelyFolderDropdownDestinationSwapCannotRedirectPrivateCopy() async throws {
        let asset = try Fixture.makeTempDirectory()
        let images = asset.appending(path: "images")
        let retiredImages = asset.appending(path: "images-retired")
        let outside = try Fixture.makeTempDirectory()
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let source = try Fixture.makeTempDirectory().appending(path: "photo.jpg")
        try Data([4, 5, 6]).write(to: source)
        let mutation = SynchronousRaceMutation()
        let store = WebWallpaperUserFileStore(
            metadataCommitter: AtomicWebWallpaperMetadataCommitter(),
            livelyCopyObserver: { event in
                guard case .destinationFolderOpened = event else { return }
                mutation.run {
                    try FileManager.default.moveItem(at: images, to: retiredImages)
                    try FileManager.default.createSymbolicLink(
                        at: images,
                        withDestinationURL: outside
                    )
                }
            }
        )

        do {
            _ = try await store.copyLivelyFolderDropdownSelection(
                source,
                propertyName: "gallery",
                projectRelativeFolder: "images",
                allowedExtensions: ["jpg"],
                into: asset
            )
            XCTFail("Expected a raced authored folder to be rejected")
        } catch let error as WallpaperImportError {
            XCTAssertEqual(error, .unsafeRoot("images"))
        }

        XCTAssertNil(mutation.error)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: retiredImages.path), [])
        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appending(
            path: WebWallpaperUserFileStore.overridesFileName
        ).path))
    }

    func testScalarAndFileResetRollsBackBothDocumentsWhenSecondCommitFails() async throws {
        let asset = try Fixture.makeTempDirectory()
        let source = try Fixture.makeTempDirectory().appending(path: "photo.jpg")
        try Data([7, 8, 9]).write(to: source)
        let initialStore = WebWallpaperUserFileStore()
        _ = try await initialStore.copySelection(
            source,
            propertyName: "gallery",
            into: asset
        )
        try await initialStore.saveValueOverrides(
            ["enabled": .bool(true)],
            into: asset
        )
        let failingStore = WebWallpaperUserFileStore(
            metadataCommitter: FailOnSecondWebWallpaperMetadataCommitter()
        )

        do {
            try await failingStore.saveValueOverrides(
                ["enabled": .bool(false)],
                clearingFileSelections: ["gallery"],
                into: asset
            )
            XCTFail("Expected the second metadata commit to fail")
        } catch let error as FailOnSecondWebWallpaperMetadataCommitter.Failure {
            XCTAssertEqual(error, .injected)
        }

        let restoredValues = try await initialStore.loadValueOverrides(from: asset)
        XCTAssertEqual(restoredValues, ["enabled": .bool(true)])
        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        let fileOverrides = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: storage.appending(path: WebWallpaperUserFileStore.overridesFileName))
        )
        XCTAssertNotNil(fileOverrides["gallery"])
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: storage.path).contains {
                $0.contains(".incoming-") || $0.contains(".previous-")
            }
        )
    }

    func testScalarAndFileResetStagingFailureRemovesEveryTemporaryBackup() async throws {
        let asset = try Fixture.makeTempDirectory()
        let source = try Fixture.makeTempDirectory().appending(path: "photo.jpg")
        try Data([1]).write(to: source)
        let store = WebWallpaperUserFileStore()
        _ = try await store.copySelection(
            source,
            propertyName: "gallery",
            into: asset
        )
        let storage = asset.appending(path: WebWallpaperUserFileStore.directoryName)
        let outside = try Fixture.makeTempDirectory().appending(path: "outside-values.json")
        try Data("outside".utf8).write(to: outside)
        let valuesURL = storage.appending(path: WebWallpaperUserFileStore.valueOverridesFileName)
        try FileManager.default.createSymbolicLink(at: valuesURL, withDestinationURL: outside)

        do {
            try await store.saveValueOverrides(
                ["enabled": .bool(false)],
                clearingFileSelections: ["gallery"],
                into: asset
            )
            XCTFail("Expected symlinked second-document staging to fail")
        } catch let error as WallpaperImportError {
            XCTAssertEqual(error, .symbolicLink(valuesURL.path))
        }

        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: storage.path).contains {
                $0.contains(".incoming-") || $0.contains(".previous-")
            }
        )
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

    func commit(
        incomingName: String,
        destinationName: String,
        directoryDescriptor: Int32
    ) throws {
        throw Failure.injected
    }
}

private struct RenameThenDeleteBackupMetadataCommitter: WebWallpaperMetadataCommitting {
    enum Failure: Error {
        case injected
        case missingBackup
    }

    let directory: URL

    func commit(incoming: URL, destination: URL) throws {
        throw Failure.injected
    }

    func commit(
        incomingName: String,
        destinationName: String,
        directoryDescriptor: Int32
    ) throws {
        try AtomicWebWallpaperMetadataCommitter().commit(
            incomingName: incomingName,
            destinationName: destinationName,
            directoryDescriptor: directoryDescriptor
        )
        let backupPrefix = ".\(destinationName).previous-"
        guard let backup = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first(where: { $0.lastPathComponent.hasPrefix(backupPrefix) }) else {
            throw Failure.missingBackup
        }
        try FileManager.default.removeItem(at: backup)
        throw Failure.injected
    }
}

private final class FailOnSecondWebWallpaperMetadataCommitter:
    WebWallpaperMetadataCommitting,
    @unchecked Sendable
{
    enum Failure: Error, Equatable {
        case injected
    }

    private let lock = NSLock()
    private var commitCount = 0

    func commit(incoming: URL, destination: URL) throws {
        lock.lock()
        commitCount += 1
        let shouldFail = commitCount == 2
        lock.unlock()
        if shouldFail { throw Failure.injected }
        try AtomicWebWallpaperMetadataCommitter().commit(
            incoming: incoming,
            destination: destination
        )
    }

    func commit(
        incomingName: String,
        destinationName: String,
        directoryDescriptor: Int32
    ) throws {
        lock.lock()
        commitCount += 1
        let shouldFail = commitCount == 2
        lock.unlock()
        if shouldFail { throw Failure.injected }
        try AtomicWebWallpaperMetadataCommitter().commit(
            incomingName: incomingName,
            destinationName: destinationName,
            directoryDescriptor: directoryDescriptor
        )
    }
}

private final class SynchronousRaceMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedError: Error?

    var error: Error? {
        lock.withLock { capturedError }
    }

    func run(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            lock.withLock { capturedError = error }
        }
    }
}
