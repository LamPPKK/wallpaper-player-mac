import Darwin
import Foundation
import XCTest
@testable import BackgroundEngineCore

final class ScannerTests: XCTestCase {
    func testDiscoversWebWallpaperByContentWithoutKnownExtension() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "content-probed-web")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "<!doctype html><html><body>Wallpaper</body></html>"
            .write(to: project.appending(path: "wallpaper.asset"), atomically: true, encoding: .utf8)

        let result = try WallpaperScanner().scan(root: root)

        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.entrypoint)).lastPathComponent, "wallpaper.asset")
    }

    func testScanUsesWholeWebProjectForAudioReactiveClassification() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "nested-web")
        let pages = project.appending(path: "pages")
        let scripts = project.appending(path: "scripts")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try #"{"title":"Nested Web","file":"pages/index.html","type":"web"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        try #"<script src="../scripts/wallpaper.js"></script>"#
            .write(to: pages.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try "window.wallpaperRegisterAudioListener((levels) => draw(levels));"
            .write(to: scripts.appending(path: "wallpaper.js"), atomically: true, encoding: .utf8)

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)

        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(asset.compatibilityReport?.level, .limited)
        XCTAssertEqual(asset.compatibilityReport?.missingCapabilities, [.audioReactive])
    }

    func testScanMarksWebWallpaperWithMissingRequiredLocalScriptUnsupported() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "missing-web-script")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Incomplete Web","file":"index.html","type":"web"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        try #"<!doctype html><canvas></canvas><script src="ao.js"></script>"#
            .write(to: project.appending(path: "index.html"), atomically: true, encoding: .utf8)

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)

        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(asset.supportStatus, .unsupported)
        XCTAssertEqual(asset.compatibilityReport?.level, .unsupported)
        XCTAssertEqual(asset.compatibilityReport?.diagnosticCode, "web_local_dependency_missing")
        XCTAssertEqual(asset.compatibility?.label, "Unsupported")
    }

    func testScanResolvesWindowsSeparatedProjectEntrypoint() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "windows-path-web")
        let pages = project.appending(path: "pages")
        let images = project.appending(path: "images")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try #"{"title":"Windows Path","file":"pages\\index.html","preview":"images\\cover.png","type":"web"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        try "<!doctype html><html><body>Wrong fallback</body></html>"
            .write(to: project.appending(path: "decoy.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><html><body>Requested entrypoint</body></html>"
            .write(to: pages.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try Data("requested preview".utf8).write(to: images.appending(path: "cover.png"))
        try Data("wrong fallback preview".utf8).write(to: project.appending(path: "preview.png"))

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)

        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(
            URL(filePath: try XCTUnwrap(asset.entrypoint)).standardizedFileURL,
            pages.appending(path: "index.html").standardizedFileURL
        )
        XCTAssertEqual(
            URL(filePath: try XCTUnwrap(asset.thumbnail)).standardizedFileURL,
            images.appending(path: "cover.png").standardizedFileURL
        )
    }

    func testScanFallsBackWhenPreferredEntrypointAndPreviewAreDirectories() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "directory-metadata-web")
        let pages = project.appending(path: "pages")
        let images = project.appending(path: "images")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try #"{"title":"Directory Metadata","file":"pages","preview":"images","type":"web"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        try "<!doctype html><html><body>Playable fallback</body></html>"
            .write(to: pages.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try Data("preview fallback".utf8).write(to: images.appending(path: "cover.png"))

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)

        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(
            URL(filePath: try XCTUnwrap(asset.entrypoint)).standardizedFileURL,
            pages.appending(path: "index.html").standardizedFileURL
        )
        XCTAssertEqual(
            URL(filePath: try XCTUnwrap(asset.thumbnail)).standardizedFileURL,
            images.appending(path: "cover.png").standardizedFileURL
        )
    }

    func testDeclaredWebFallbackPrefersHTMLOverEmbeddedVideo() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "web-with-video")
        let invalidEntrypoint = project.appending(path: "missing-entry")
        try FileManager.default.createDirectory(at: invalidEntrypoint, withIntermediateDirectories: true)
        try #"{"title":"Web With Video","file":"missing-entry","type":"web"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(
            atPath: project.appending(path: "background.mp4").path,
            contents: Data()
        )
        try "<!doctype html><html><body><video src=\"background.mp4\"></video></body></html>"
            .write(to: project.appending(path: "index.html"), atomically: true, encoding: .utf8)

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)

        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.entrypoint)).lastPathComponent, "index.html")
    }

    func testDeclaredSceneFallbackPrefersPKGVOverTextureImage() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "scene-with-texture")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Scene With Texture","file":"missing.pkg","type":"scene"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lz8KWwAAAABJRU5ErkJggg=="
        ))
        try png.write(to: project.appending(path: "background.png"))
        try Fixture.writeScenePackage(
            to: project.appending(path: "scene.pkg"),
            sceneJSON: #"{"objects":[{"text":{"value":"SCENE"}}]}"#
        )

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)

        XCTAssertEqual(asset.kind, .scene)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.entrypoint)).lastPathComponent, "scene.pkg")
    }

    func testDeclaredSceneFallbackRejectsNonPKGVCandidateBeforePackage() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "scene-with-extensionless-package")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Scene Probe Routing","file":"missing.pkg","type":"scene"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        let decoy = project.appending(path: "background.mp4")
        let package = project.appending(path: "scene.asset")
        FileManager.default.createFile(atPath: decoy.path, contents: Data("video".utf8))
        FileManager.default.createFile(atPath: package.path, contents: Data("PKGV".utf8))
        let scanner = WallpaperScanner { url, metadataType in
            switch url.lastPathComponent {
            case decoy.lastPathComponent:
                XCTAssertEqual(metadataType, "scene")
                return MediaContentClassification(kind: .scene, supportStatus: .unsupported)
            case package.lastPathComponent:
                return MediaContentClassification(kind: .scene, supportStatus: .playable)
            default:
                return MediaContentClassification(kind: .unknown, supportStatus: .unsupported)
            }
        }

        let asset = try XCTUnwrap(scanner.scan(root: root).assets.first)

        XCTAssertEqual(asset.kind, .scene)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(
            URL(filePath: try XCTUnwrap(asset.entrypoint)).lastPathComponent,
            package.lastPathComponent
        )
    }

    func testDeclaredSceneWithOnlyNonPKGVPreferredFileStaysUnsupported() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "scene-with-invalid-package")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Invalid Scene","file":"background.mp4","type":"scene"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        try Data("not a PKGV package".utf8).write(to: project.appending(path: "background.mp4"))

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)

        XCTAssertEqual(asset.kind, .scene)
        XCTAssertEqual(asset.supportStatus, .unsupported)
        XCTAssertEqual(asset.compatibilityReport?.level, .unsupported)
        XCTAssertEqual(asset.compatibilityReport?.diagnosticCode, "scene_package_unreadable")
        XCTAssertTrue(asset.issues.contains { $0.code == "scene_package_unreadable" })
    }

    func testDeclaredVideoWithOnlyHTMLPreferredFileRemainsUnsupported() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "video-with-html")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Broken Video","file":"index.html","type":"video"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        try "<!doctype html><html><body>Not a video</body></html>"
            .write(to: project.appending(path: "index.html"), atomically: true, encoding: .utf8)

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)

        XCTAssertEqual(asset.kind, .unknown)
        XCTAssertEqual(asset.supportStatus, .unsupported)
    }

    func testDeclaredImageWithOnlyVideoPreferredFileRemainsUnsupported() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "image-with-video")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Broken Image","file":"clip.mp4","type":"image"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: project.appending(path: "clip.mp4").path, contents: Data())

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)

        XCTAssertEqual(asset.kind, .unknown)
        XCTAssertEqual(asset.supportStatus, .unsupported)
    }

    func testDeclaredVideoFallbackSelectsConvertibleVideo() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "video-fallback")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Video Fallback","file":"missing-video","type":"video"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        try "<!doctype html><html><body>Decoy</body></html>"
            .write(to: project.appending(path: "index.html"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: project.appending(path: "loop.webm").path, contents: Data())

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)

        XCTAssertEqual(asset.kind, .video)
        XCTAssertEqual(asset.supportStatus, .needsConversion)
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.entrypoint)).lastPathComponent, "loop.webm")
    }

    func testDeclaredImageFallbackSelectsImageOverEmbeddedVideo() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "image-fallback")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Image Fallback","file":"missing-image","type":"image"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: project.appending(path: "background.mp4").path, contents: Data())
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lz8KWwAAAABJRU5ErkJggg=="
        ))
        try png.write(to: project.appending(path: "poster.png"))

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)

        XCTAssertEqual(asset.kind, .image)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.entrypoint)).lastPathComponent, "poster.png")
    }

    func testScanDiscoversPlayableVideoWhenWorkshopFolderContainsProjectJson() throws {
        // Given
        let root = try Fixture.makeWorkshopRoot()
        let project = root.appending(path: "123456")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Rain Loop","file":"rain.mp4","type":"video"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        FileManager.default.createFile(atPath: project.appending(path: "rain.mp4").path, contents: Data())

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        XCTAssertEqual(result.assets.count, 1)
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.id, "123456")
        XCTAssertEqual(asset.title, "Rain Loop")
        XCTAssertEqual(asset.kind, .video)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(asset.source, .localSteamWorkshop)
        XCTAssertEqual(asset.redistributionAllowed, false)
    }

    func testScanReadsDateAddedAndSortsNewestFirst() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        try Fixture.project(
            root: root,
            id: "100",
            metadata: #"{"title":"Older","file":"older.mp4"}"#,
            file: "older.mp4"
        )
        try Fixture.project(
            root: root,
            id: "200",
            metadata: #"{"title":"Newer","file":"newer.mp4"}"#,
            file: "newer.mp4"
        )
        let older = root.appending(path: "100")
        let newer = root.appending(path: "200")
        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_700_086_400)
        try FileManager.default.setAttributes([.modificationDate: olderDate], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: newer.path)

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        XCTAssertEqual(result.assets.map(\.id), ["200", "100"])
        XCTAssertNotNil(result.assets[0].dateAdded)
        XCTAssertNotNil(result.assets[1].dateAdded)
    }

    func testScanClassifiesWebImageAndSceneProjects() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        try Fixture.project(
            root: root,
            id: "web",
            metadata: #"{"title":"Clock","file":"index.html"}"#,
            file: "index.html"
        )
        try Fixture.project(
            root: root,
            id: "image",
            metadata: #"{"title":"Poster","file":"poster.png"}"#,
            file: "poster.png"
        )
        try Fixture.project(
            root: root,
            id: "scene",
            metadata: #"{"title":"Particles","file":"scene.pkg"}"#,
            file: "scene.pkg"
        )

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let supportByKind = Dictionary(uniqueKeysWithValues: result.assets.map { ($0.kind, $0.supportStatus) })
        XCTAssertEqual(supportByKind[.image], .playable)
        XCTAssertEqual(supportByKind[.scene], .unsupported)
        XCTAssertEqual(supportByKind[.web], .playable)
    }

    func testScanReportsMalformedProjectJsonWithoutThrowing() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "broken")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "{bad json".write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: project.appending(path: "clip.mp4").path, contents: Data())

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        XCTAssertEqual(result.assets.count, 1)
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .video)
        XCTAssertTrue(asset.issues.contains { $0.code == "malformed_project_json" })
    }

    func testScanRejectsOversizedProjectJsonAndFallsBackToPlayableContent() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "oversized-metadata")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let metadata = project.appending(path: "project.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: metadata.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: metadata)
        try handle.truncate(atOffset: 1_048_577)
        try handle.close()
        try "<!doctype html><html><body>Fallback</body></html>"
            .write(to: project.appending(path: "index.html"), atomically: true, encoding: .utf8)

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)

        XCTAssertEqual(asset.title, "oversized-metadata")
        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.entrypoint)).lastPathComponent, "index.html")
        XCTAssertTrue(asset.issues.contains { $0.code == "project_json_too_large" })
    }

    func testScanDoesNotFollowProjectJsonSymlinkAndFallsBackToPlayableContent() throws {
        let root = try Fixture.makeTempDirectory()
        let outside = try Fixture.makeTempDirectory().appending(path: "outside.json")
        try #"{"title":"Leaked title","file":"outside.html","type":"web"}"#
            .write(to: outside, atomically: true, encoding: .utf8)
        let project = root.appending(path: "symlinked-metadata")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: project.appending(path: "project.json"),
            withDestinationURL: outside
        )
        try "<!doctype html><html><body>Fallback</body></html>"
            .write(to: project.appending(path: "index.html"), atomically: true, encoding: .utf8)

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)

        XCTAssertEqual(asset.title, "symlinked-metadata")
        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.entrypoint)).lastPathComponent, "index.html")
        XCTAssertTrue(asset.issues.contains { $0.code == "project_json_not_regular" })
    }

    func testScanDoesNotBlockOnProjectJsonFIFOAndFallsBackToPlayableContent() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "fifo-metadata")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let metadata = project.appending(path: "project.json")
        let result = metadata.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
        }
        XCTAssertEqual(result, 0)
        try "<!doctype html><html><body>Fallback</body></html>"
            .write(to: project.appending(path: "index.html"), atomically: true, encoding: .utf8)

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)

        XCTAssertEqual(asset.title, "fifo-metadata")
        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.entrypoint)).lastPathComponent, "index.html")
        XCTAssertTrue(asset.issues.contains { $0.code == "project_json_not_regular" })
    }

    func testProjectDiscoveryDoesNotContentProbeFIFOEntries() throws {
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "fifo-only")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fifo = project.appending(path: "wallpaper.pipe")
        let result = fifo.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
        }
        XCTAssertEqual(result, 0)
        let recorder = ClassifiedURLRecorder()
        let scanner = WallpaperScanner { url, _ in
            recorder.record(url)
            return MediaContentClassification(kind: .unknown, supportStatus: .unsupported)
        }

        let scan = try scanner.scan(root: root)

        XCTAssertTrue(scan.assets.isEmpty)
        XCTAssertTrue(recorder.recordedURLs.isEmpty)
    }

    func testScanDoesNotUsePreviewImageAsSceneEntrypointWhenProjectFileIsMissing() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "scene-preview")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Scene Preview"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        try Fixture.writeScenePackage(
            to: project.appending(path: "scene.pkg"),
            sceneJSON: #"{"objects":[{"image":"models/background.json"},{"particle":"particles/leaves.json"}]}"#,
            extraEntries: [(path: "materials/background.tex", data: Data([1, 2, 3]))]
        )
        FileManager.default.createFile(atPath: project.appending(path: "preview.jpg").path, contents: Data())

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .scene)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(asset.compatibility?.label, "Cached")
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.entrypoint)).lastPathComponent, "scene.pkg")
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.thumbnail)).lastPathComponent, "preview.jpg")
        XCTAssertTrue(asset.issues.contains { $0.code == "scene_package_detected" })
        XCTAssertTrue(asset.issues.contains { $0.code == "scene_renderer_limited" })
    }

    func testScanMarksRenderableSceneAsPlayable() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "renderable-scene")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Renderable Scene","file":"scene.pkg"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lz8KWwAAAABJRU5ErkJggg=="
        )!
        try Fixture.writeScenePackage(
            to: project.appending(path: "scene.pkg"),
            sceneJSON: """
            {
              "objects": [
                {
                  "image": "models/background.json",
                  "origin": "960 540 0",
                  "size": "1920 1080"
                }
              ]
            }
            """,
            extraEntries: [
                (path: "models/background.json", data: Data(#"{"material":"materials/background.json"}"#.utf8)),
                (path: "materials/background.json", data: Data(#"{"passes":[{"textures":["background"]}]}"#.utf8)),
                (path: "materials/background.tex", data: Fixture.texData(width: 1, height: 1, imageData: png))
            ]
        )

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .scene)
        XCTAssertEqual(asset.supportStatus, .playable)
    }

    func testScanMarksTextOnlySceneAsPlayable() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "text-only-scene")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Text Scene","file":"scene.pkg"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        try Fixture.writeScenePackage(
            to: project.appending(path: "scene.pkg"),
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .scene)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertTrue(asset.issues.contains { $0.code == "scene_package_detected" })
        XCTAssertTrue(asset.issues.contains { $0.code == "scene_renderer_limited" })
    }

    func testScanMarksMixedTextAndBrokenImageSceneAsPlayable() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "mixed-scene")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Mixed Scene","file":"scene.pkg"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        try Fixture.writeScenePackage(
            to: project.appending(path: "scene.pkg"),
            sceneJSON: #"{"objects":[{"text":{"value":"CLOCK"}},{"image":"models/background.json"}]}"#,
            extraEntries: [
                (path: "models/background.json", data: Data(#"{"material":"materials/background.json"}"#.utf8)),
                (path: "materials/background.json", data: Data(#"{"passes":[{"textures":["background"]}]}"#.utf8)),
                (path: "materials/background.tex", data: Data([1, 2, 3]))
            ]
        )

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .scene)
        XCTAssertEqual(asset.supportStatus, .playable)
    }

    func testScanMarksSceneCachedWhenNativeTextureCannotDecode() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "broken-scene-texture")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Broken Scene","file":"scene.pkg"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        try Fixture.writeScenePackage(
            to: project.appending(path: "scene.pkg"),
            sceneJSON: """
            {
              "objects": [
                {
                  "image": "models/background.json",
                  "origin": "960 540 0",
                  "size": "1920 1080"
                }
              ]
            }
            """,
            extraEntries: [
                (path: "models/background.json", data: Data(#"{"material":"materials/background.json"}"#.utf8)),
                (path: "materials/background.json", data: Data(#"{"passes":[{"textures":["background"]}]}"#.utf8)),
                (path: "materials/background.tex", data: Data([1, 2, 3]))
            ]
        )

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .scene)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(asset.compatibility?.label, "Cached")
    }

    func testScanMarksEffectOnlySceneCached() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "effect-only-scene")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Effect Scene","file":"scene.pkg"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        try Fixture.writeScenePackage(
            to: project.appending(path: "scene.pkg"),
            sceneJSON: """
            {
              "objects": [
                {
                  "image": "models/util/composelayer.json",
                  "effects": [{"file": "effects/waterripple/effect.json"}]
                }
              ]
            }
            """
        )

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .scene)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(asset.compatibility?.label, "Cached")
    }

    func testScanPrefersRealVideoOverPreviewImageWhenProjectFileIsMissing() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "video-preview")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Video Preview"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        FileManager.default.createFile(atPath: project.appending(path: "clip.mp4").path, contents: Data())
        FileManager.default.createFile(atPath: project.appending(path: "preview.jpg").path, contents: Data())

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .video)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.entrypoint)).lastPathComponent, "clip.mp4")
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.thumbnail)).lastPathComponent, "preview.jpg")
    }

    func testScanUsesExplicitImageFileAsPlayableEntrypoint() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "explicit-image")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Poster","file":"poster.jpg","preview":"preview.jpg"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        FileManager.default.createFile(atPath: project.appending(path: "poster.jpg").path, contents: Data())
        FileManager.default.createFile(atPath: project.appending(path: "preview.jpg").path, contents: Data())

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .image)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.entrypoint)).lastPathComponent, "poster.jpg")
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.thumbnail)).lastPathComponent, "preview.jpg")
    }

    func testScanRejectsMetadataPathsOutsideProjectDirectory() throws {
        // Given
        let parent = try Fixture.makeTempDirectory()
        let root = parent.appending(path: "root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = root.appending(path: "path-escape")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Escape","file":"../../outside.mp4","preview":"../../outside.jpg"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        FileManager.default.createFile(atPath: parent.appending(path: "outside.mp4").path, contents: Data())
        FileManager.default.createFile(atPath: parent.appending(path: "outside.jpg").path, contents: Data())

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertNil(asset.entrypoint)
        XCTAssertNil(asset.thumbnail)
        XCTAssertEqual(asset.kind, .unknown)
        XCTAssertEqual(asset.supportStatus, .unsupported)
        XCTAssertTrue(asset.issues.contains { $0.code == "no_supported_entrypoint" })
    }

    func testScanRejectsWindowsSeparatedMetadataTraversal() throws {
        let parent = try Fixture.makeTempDirectory()
        let root = parent.appending(path: "root")
        let project = root.appending(path: "windows-path-escape")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Escape","file":"..\\..\\outside.html","type":"web"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        try "<!doctype html><html><body>Outside</body></html>"
            .write(to: parent.appending(path: "outside.html"), atomically: true, encoding: .utf8)

        let asset = try XCTUnwrap(WallpaperScanner().scan(root: root).assets.first)

        XCTAssertNil(asset.entrypoint)
        XCTAssertEqual(asset.kind, .unknown)
        XCTAssertEqual(asset.supportStatus, .unsupported)
    }

    func testScanRejectsSymlinkEntrypointOutsideProjectDirectory() throws {
        // Given
        let parent = try Fixture.makeTempDirectory()
        let root = parent.appending(path: "root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = root.appending(path: "symlink-escape")
        let outside = parent.appending(path: "outside.mp4")
        let symlink = project.appending(path: "clip.mp4")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outside.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        try #"{"title":"Symlink","file":"clip.mp4"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertNil(asset.entrypoint)
        XCTAssertEqual(asset.kind, .unknown)
        XCTAssertEqual(asset.supportStatus, .unsupported)
    }
}

private final class ClassifiedURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var recordedURLs: [URL] {
        lock.withLock { urls }
    }

    func record(_ url: URL) {
        lock.withLock { urls.append(url) }
    }
}
