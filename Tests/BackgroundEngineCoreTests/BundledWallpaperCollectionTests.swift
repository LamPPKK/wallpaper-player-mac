import Foundation
import XCTest
@testable import BackgroundEngineCore

final class BundledWallpaperCollectionTests: XCTestCase {
    func testValidatedCollectionReturnsPlayableRedistributableWebCandidate() async throws {
        let fixture = try makeCollection()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let store = LibraryStore(root: fixture.library)
        let collection = BundledWallpaperCollection(
            root: fixture.root,
            store: store
        )

        let untrustedDirectScan = try XCTUnwrap(
            WallpaperScanner().scan(root: fixture.project).assets.first
        )
        let candidates = try await collection.candidates()

        let asset = try XCTUnwrap(candidates.first).asset
        XCTAssertEqual(untrustedDirectScan.source, .manualFolder)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(asset.id, "lively-test")
        XCTAssertEqual(asset.title, "Lively Test")
        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(asset.source, .bundledLively)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertTrue(asset.redistributionAllowed)
        XCTAssertEqual(asset.contentHash, try WallpaperContentHasher.hashDirectory(fixture.project))

        let imported = try await WallpaperImporter(store: store)
            .importAndPrepareBundledCandidate(try XCTUnwrap(candidates.first))
        XCTAssertEqual(imported.source, .bundledLively)
        XCTAssertTrue(imported.redistributionAllowed)
        XCTAssertEqual(imported.contentHash, asset.contentHash)
    }

    func testCollectionRejectsContentChangedAfterCatalogWasWritten() async throws {
        let fixture = try makeCollection()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        try "changed".write(
            to: fixture.project.appending(path: "index.html"),
            atomically: true,
            encoding: .utf8
        )
        let collection = BundledWallpaperCollection(
            root: fixture.root,
            store: LibraryStore(root: fixture.library)
        )

        do {
            _ = try await collection.candidates()
            XCTFail("Expected the modified project to fail its catalog hash.")
        } catch let error as BundledWallpaperCollectionError {
            XCTAssertEqual(error, .contentHashMismatch("lively-test"))
        }
    }

    func testCollectionRejectsUncataloguedVisibleItems() async throws {
        let fixture = try makeCollection()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        try Data().write(to: fixture.root.appending(path: "unexpected.bin"))
        let collection = BundledWallpaperCollection(
            root: fixture.root,
            store: LibraryStore(root: fixture.library)
        )

        do {
            _ = try await collection.candidates()
            XCTFail("Expected the uncatalogued item to be rejected.")
        } catch let error as BundledWallpaperCollectionError {
            XCTAssertEqual(error, .unexpectedItem("unexpected.bin"))
        }
    }

    func testCollectionStillRunsImporterSymlinkValidation() async throws {
        let fixture = try makeCollection()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let outside = fixture.parent.appending(path: "outside.js")
        try "alert('outside')".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: fixture.project.appending(path: "escape.js"),
            withDestinationURL: outside
        )
        try rewriteCatalogHash(for: fixture)
        let collection = BundledWallpaperCollection(
            root: fixture.root,
            store: LibraryStore(root: fixture.library)
        )

        do {
            _ = try await collection.candidates()
            XCTFail("Expected a symbolic-link rejection.")
        } catch let error as WallpaperImportError {
            guard case .symbolicLink = error else {
                return XCTFail("Unexpected importer error: \(error)")
            }
        }
    }

    func testCollectionRejectsAnyUnrelatedDuplicateRegardlessOfManifestOrder() async throws {
        let fixture = try makeCollection()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let unrelatedRoot = fixture.parent.appending(path: "Unrelated")
        let unrelatedEntrypoint = unrelatedRoot.appending(path: "wallpaper.mp4")
        try FileManager.default.createDirectory(at: unrelatedRoot, withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: unrelatedEntrypoint)
        let unrelated = WallpaperAsset(
            id: "lively-test",
            title: "User Wallpaper",
            kind: .video,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: unrelatedRoot.path,
            entrypoint: unrelatedEntrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            redistributionAllowed: false,
            issues: []
        )
        let existingBundled = unrelated.replacing(
            source: .bundledLively,
            redistributionAllowed: true
        )
        let store = LibraryStore(root: fixture.library)
        let collection = BundledWallpaperCollection(root: fixture.root, store: store)

        for assets in [[existingBundled, unrelated], [unrelated, existingBundled]] {
            try writeManifest(assets, to: fixture.library)
            do {
                _ = try await collection.candidates()
                XCTFail("Expected an identifier conflict.")
            } catch let error as BundledWallpaperCollectionError {
                XCTAssertEqual(error, .identifierConflict("lively-test"))
            }
        }
        XCTAssertEqual(
            try store.load().assets.filter {
                $0.title == "User Wallpaper" && $0.source == .manualFolder
            }.count,
            1
        )
        XCTAssertEqual(try Data(contentsOf: unrelatedEntrypoint), Data("unrelated".utf8))
    }

    func testValidatedCandidateRejectsSourceChangedBeforeStaging() async throws {
        let fixture = try makeCollection()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let store = LibraryStore(root: fixture.library)
        let collection = BundledWallpaperCollection(root: fixture.root, store: store)
        let candidates = try await collection.candidates()
        let candidate = try XCTUnwrap(candidates.first)
        try "<!doctype html><title>Changed after validation</title>".write(
            to: fixture.project.appending(path: "index.html"),
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try await WallpaperImporter(store: store)
                .importAndPrepareBundledCandidate(candidate)
            XCTFail("Expected the staged content hash to be rejected.")
        } catch let error as BundledWallpaperCollectionError {
            XCTAssertEqual(error, .contentHashMismatch("lively-test"))
        }
        XCTAssertTrue(try store.load().assets.isEmpty)
    }

    func testValidatedCandidateRechecksEveryDuplicateInsideCommitLock() async throws {
        let fixture = try makeCollection()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let store = LibraryStore(root: fixture.library)
        let collection = BundledWallpaperCollection(root: fixture.root, store: store)
        let candidates = try await collection.candidates()
        let candidate = try XCTUnwrap(candidates.first)
        let unrelatedRoot = fixture.parent.appending(path: "LaterUnrelated")
        let unrelatedEntrypoint = unrelatedRoot.appending(path: "wallpaper.mp4")
        try FileManager.default.createDirectory(at: unrelatedRoot, withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: unrelatedEntrypoint)
        let unrelated = WallpaperAsset(
            id: "lively-test",
            title: "Later User Wallpaper",
            kind: .video,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: unrelatedRoot.path,
            entrypoint: unrelatedEntrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .live(),
            redistributionAllowed: false,
            issues: []
        )
        let existingBundled = unrelated.replacing(
            source: .bundledLively,
            redistributionAllowed: true
        )

        for assets in [[existingBundled, unrelated], [unrelated, existingBundled]] {
            try writeManifest(assets, to: fixture.library)
            do {
                _ = try await WallpaperImporter(store: store)
                    .importAndPrepareBundledCandidate(candidate)
                XCTFail("Expected the commit-time identifier conflict to be rejected.")
            } catch let error as BundledWallpaperCollectionError {
                XCTAssertEqual(error, .identifierConflict("lively-test"))
            }
            let stored = try store.load().assets
            XCTAssertEqual(stored.count, 2)
            XCTAssertTrue(stored.contains {
                $0.title == "Later User Wallpaper" && $0.source == .manualFolder
            })
            XCTAssertEqual(try Data(contentsOf: unrelatedEntrypoint), Data("unrelated".utf8))
        }
    }

    func testOrdinaryImportCannotForgeBundledRedistributionProvenance() async throws {
        let fixture = try makeCollection()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let store = LibraryStore(root: fixture.library)
        let candidates = try await BundledWallpaperCollection(
            root: fixture.root,
            store: store
        ).candidates()
        let candidate = try XCTUnwrap(candidates.first)

        let imported = try await WallpaperImporter(store: store)
            .importAndPrepareAsset(candidate.asset)

        XCTAssertEqual(imported.source, .manualFolder)
        XCTAssertFalse(imported.redistributionAllowed)
        XCTAssertFalse(try XCTUnwrap(store.load().assets.first).redistributionAllowed)
    }

    private struct CollectionFixture {
        let parent: URL
        let root: URL
        let project: URL
        let library: URL
    }

    private func makeCollection() throws -> CollectionFixture {
        let parent = try Fixture.makeTempDirectory()
        let root = parent.appending(path: "LivelyWallpapers")
        let project = root.appending(path: "lively-test")
        let library = parent.appending(path: "Library")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try #"{"title":"Lively Test","type":"web","file":"index.html"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        try "<!doctype html><title>Lively Test</title>".write(
            to: project.appending(path: "index.html"),
            atomically: true,
            encoding: .utf8
        )
        try "MIT License".write(
            to: project.appending(path: "LICENSE"),
            atomically: true,
            encoding: .utf8
        )
        let fixture = CollectionFixture(parent: parent, root: root, project: project, library: library)
        try rewriteCatalogHash(for: fixture)
        return fixture
    }

    private func rewriteCatalogHash(for fixture: CollectionFixture) throws {
        let catalog = BundledWallpaperCollectionCatalog(
            collectionID: "test-lively-collection",
            displayName: "Test Lively Collection",
            sourceRepository: "https://github.com/rocksdanister/lively",
            sourceRelease: "v2.2.1.0",
            sourceCommit: "6860a4093fc50058c4815908658a4391c4449935",
            sourceInstallerSHA256: String(repeating: "b", count: 64),
            wallpapers: [
                .init(
                    id: "lively-test",
                    title: "Lively Test",
                    license: "MIT",
                    licenseFiles: ["LICENSE"],
                    sourceArchive: "0.zip",
                    sourceArchiveSHA256: String(repeating: "a", count: 64),
                    sourcePath: "test.project",
                    contentHash: try WallpaperContentHasher.hashDirectory(fixture.project)
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(catalog).write(
            to: fixture.root.appending(path: BundledWallpaperCollection.catalogFileName),
            options: .atomic
        )
    }

    private func writeManifest(_ assets: [WallpaperAsset], to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(LibraryManifest(generatedAt: Date(), assets: assets)).write(
            to: root.appending(path: "library.json"),
            options: .atomic
        )
    }
}
