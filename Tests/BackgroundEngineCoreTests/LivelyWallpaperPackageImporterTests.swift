import Darwin
import Foundation
@testable import BackgroundEngineCore
import XCTest

final class LivelyWallpaperPackageImporterTests: XCTestCase {
    func testImportsFolderAndMapsMetadataAndPropertiesWithoutChangingSource() async throws {
        let source = try makeProject(
            title: "Mapped Lively",
            type: 1,
            fileName: "index.html",
            extraFiles: [
                "preview.gif": Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!,
                "animated-preview.gif": Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!,
                "images/default.jpg": Data("image".utf8),
                "images/second.jpg": Data("second".utf8),
                "images/not-in-filter.png": Data("png".utf8),
                "images/nested/not-scanned.jpg": Data("nested".utf8),
            ]
        )
        let infoURL = source.appending(path: "LivelyInfo.json")
        var info = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: infoURL)) as? [String: Any]
        )
        info["Thumbnail"] = "missing-thumbnail.png"
        info["Preview"] = "animated-preview.gif"
        try JSONSerialization.data(withJSONObject: info).write(to: infoURL)
        let properties = #"""
        {
          // The importer accepts Lively's documented line comments.
          "enabled": {"type":"checkbox","value":true,"text":"Enabled"},
          "opacity": {"type":"slider","value":50,"min":0,"max":1000,"tick":25},
          "speed": {"type":"slider","value":1.5,"min":0,"max":5,"step":0.25},
          "tint": {"type":"color","value":"#aabbcc"},
          "quality": {"type":"dropdown","value":1,"items":["Low","High"]},
          "caption": {"type":"textbox","value":"https://example.test//not-a-comment"},
          "gallery": {"type":"folderDropdown","folder":"images","value":"default.jpg","filter":"*.jpg"},
          "heading": {"type":"label","value":"Ignored"},
          "action": {"type":"button","text":"Actions","value":"Shuffle now"}
        }
        """#
        try properties.write(
            to: source.appending(path: "LivelyProperties.json"),
            atomically: true,
            encoding: .utf8
        )
        let originalHash = try WallpaperContentHasher.hashDirectory(source)
        let (importer, store, library) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }

        let asset = try await importer.importAndPrepare(source)

        XCTAssertEqual(asset.title, "Mapped Lively")
        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(asset.source, .manualFolder)
        XCTAssertNil(asset.workshopId)
        XCTAssertFalse(asset.redistributionAllowed)
        XCTAssertTrue(asset.id.hasPrefix("lively-"))
        XCTAssertEqual(asset.compatibilityReport?.level, .limited)
        XCTAssertEqual(asset.compatibilityReport?.missingCapabilities, [.interaction])
        XCTAssertEqual(
            asset.compatibilityReport?.diagnosticCode,
            "web_lively_properties_limited"
        )
        XCTAssertFalse(
            asset.compatibilityReport?.warnings.contains {
                $0.localizedCaseInsensitiveContains("button")
            } == true
        )
        XCTAssertTrue(
            asset.compatibilityReport?.warnings.contains {
                $0.localizedCaseInsensitiveContains("folder dropdown")
            } == true
        )
        XCTAssertEqual(try WallpaperContentHasher.hashDirectory(source), originalHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "project.json").path))

        let project = try projectJSON(asset)
        XCTAssertEqual(project["type"] as? String, "web")
        XCTAssertEqual(project["file"] as? String, "index.html")
        XCTAssertEqual(project["preview"] as? String, "animated-preview.gif")
        let general = try XCTUnwrap(project["general"] as? [String: Any])
        let mapped = try XCTUnwrap(general["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(mapped.keys),
            Set(["enabled", "opacity", "speed", "tint", "quality", "caption", "gallery", "action"])
        )
        XCTAssertEqual((mapped["enabled"] as? [String: Any])?["type"] as? String, "bool")
        XCTAssertEqual((mapped["enabled"] as? [String: Any])?["value"] as? Bool, true)
        XCTAssertEqual((mapped["opacity"] as? [String: Any])?["step"] as? Double, 1)
        XCTAssertEqual((mapped["speed"] as? [String: Any])?["step"] as? Double, 0.25)
        let quality = try XCTUnwrap(mapped["quality"] as? [String: Any])
        XCTAssertEqual(quality["type"] as? String, "combo")
        XCTAssertEqual(quality["value"] as? String, "1")
        XCTAssertEqual(quality["backgroundEngineLivelyType"] as? String, "dropdown")
        let options = try XCTUnwrap(quality["options"] as? [[String: Any]])
        XCTAssertEqual(options.compactMap { $0["value"] as? String }, ["0", "1"])
        let gallery = try XCTUnwrap(mapped["gallery"] as? [String: Any])
        XCTAssertEqual(gallery["type"] as? String, "combo")
        XCTAssertEqual(gallery["value"] as? String, "images/default.jpg")
        XCTAssertEqual(gallery["backgroundEngineLivelyType"] as? String, "folderDropdown")
        XCTAssertEqual(gallery["backgroundEngineLivelyFolder"] as? String, "images")
        XCTAssertEqual(gallery["backgroundEngineLivelyFilter"] as? String, "*.jpg")
        let galleryOptions = try XCTUnwrap(gallery["options"] as? [[String: Any]])
        XCTAssertEqual(
            galleryOptions.compactMap { $0["value"] as? String },
            ["images/default.jpg", "images/second.jpg"]
        )
        let action = try XCTUnwrap(mapped["action"] as? [String: Any])
        XCTAssertEqual(action["type"] as? String, "button")
        XCTAssertEqual(action["text"] as? String, "Actions")
        XCTAssertEqual(action["value"] as? String, "Shuffle now")
        XCTAssertEqual(action["backgroundEngineLivelyType"] as? String, "button")
        let persisted = try store.load().assets
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.id, asset.id)
        XCTAssertEqual(persisted.first?.contentHash, asset.contentHash)
    }

    func testButtonOnlyWebPackageStaysFullAndRetainsMomentaryDescriptor() async throws {
        let source = try makeProject(
            title: "Lively Button",
            type: 1,
            fileName: "index.html"
        )
        try Data(#"{"shuffle":{"type":"button","text":"Actions","value":"Shuffle now"}}"#.utf8)
            .write(to: source.appending(path: "LivelyProperties.json"))
        let (importer, _, library) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }

        let asset = try await importer.importAndPrepare(source)

        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(asset.compatibilityReport?.level, .full)
        XCTAssertFalse(asset.compatibilityReport?.missingCapabilities.contains(.interaction) == true)
        XCTAssertFalse(
            asset.compatibilityReport?.warnings.contains {
                $0.localizedCaseInsensitiveContains("button")
            } == true
        )
        let project = try projectJSON(asset)
        let general = try XCTUnwrap(project["general"] as? [String: Any])
        let properties = try XCTUnwrap(general["properties"] as? [String: Any])
        let button = try XCTUnwrap(properties["shuffle"] as? [String: Any])
        XCTAssertEqual(button["text"] as? String, "Actions")
        XCTAssertEqual(button["value"] as? String, "Shuffle now")
        XCTAssertEqual(button["backgroundEngineLivelyType"] as? String, "button")
    }

    func testPropertyNamesUseTheRuntimeUTF8ByteLimit() async throws {
        let acceptedName = String(repeating: "a", count: 300)
        let rejectedMultibyteName = String(repeating: "😀", count: 200)
        XCTAssertLessThanOrEqual(
            acceptedName.lengthOfBytes(using: .utf8),
            WebWallpaperUserFileStore.maximumPropertyNameBytes
        )
        XCTAssertGreaterThan(
            rejectedMultibyteName.lengthOfBytes(using: .utf8),
            WebWallpaperUserFileStore.maximumPropertyNameBytes
        )
        let source = try makeProject(
            title: "Lively UTF-8 Property Names",
            type: 1,
            fileName: "index.html"
        )
        let properties: [String: Any] = [
            acceptedName: ["type": "button", "value": "Accepted"],
            rejectedMultibyteName: ["type": "button", "value": "Rejected"]
        ]
        try JSONSerialization.data(withJSONObject: properties).write(
            to: source.appending(path: "LivelyProperties.json")
        )
        let (importer, _, library) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }

        let asset = try await importer.importAndPrepare(source)
        let project = try projectJSON(asset)
        let general = try XCTUnwrap(project["general"] as? [String: Any])
        let mapped = try XCTUnwrap(general["properties"] as? [String: Any])

        XCTAssertNotNil(mapped[acceptedName])
        XCTAssertNil(mapped[rejectedMultibyteName])
        XCTAssertEqual(asset.compatibilityReport?.level, .limited)
        XCTAssertTrue(asset.compatibilityReport?.missingCapabilities.contains(.interaction) == true)
    }

    func testMusicTVLikeWebWithNestedWebMStaysWeb() async throws {
        let source = try makeProject(
            title: "Music TV",
            type: "WebAudio",
            fileName: "site/index.html",
            extraFiles: ["site/media/background.webm": Data("raw-webm-placeholder".utf8)]
        )
        let (importer, _, library) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }

        let asset = try await importer.importAndPrepare(source)

        XCTAssertEqual(asset.kind, .web)
        XCTAssertTrue(asset.entrypoint?.hasSuffix("/site/index.html") == true)
        XCTAssertEqual(asset.compatibilityReport?.level, .limited)
        XCTAssertEqual(asset.compatibilityReport?.missingCapabilities, [.audioReactive])
        XCTAssertEqual(
            asset.compatibilityReport?.diagnosticCode,
            "web_lively_audio_reactive_limited"
        )
        let general = try XCTUnwrap(try projectJSON(asset)["general"] as? [String: Any])
        XCTAssertEqual(general["supportsaudioprocessing"] as? Bool, true)
    }

    func testMissingTitleUsesSelectedFolderNameInsteadOfPrivateStagingName() async throws {
        let source = try makeProject(
            title: "Temporary title",
            type: 1,
            fileName: "index.html"
        )
        try Data(#"{"Type":1,"FileName":"index.html","IsAbsolutePath":false}"#.utf8)
            .write(to: source.appending(path: "LivelyInfo.json"))
        let (importer, _, library) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }

        let asset = try await importer.importAndPrepare(source)

        XCTAssertEqual(asset.title, source.lastPathComponent)
        XCTAssertNotEqual(asset.title, "normalized")
    }

    func testApplicationTypeIsImportedAsUnsupportedWithoutWorkshopIdentity() async throws {
        let source = try makeProject(
            title: "Windows App",
            type: "Unity",
            fileName: "wallpaper.exe",
            entrypointData: Data("MZ".utf8)
        )
        let (importer, _, library) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }

        let asset = try await importer.importAndPrepare(source)

        XCTAssertEqual(asset.kind, .application)
        XCTAssertEqual(asset.supportStatus, .unsupported)
        XCTAssertNil(asset.workshopId)
        XCTAssertTrue(asset.issues.contains { $0.code == "windows_application_unsupported" })
        XCTAssertEqual(try projectJSON(asset)["file"] as? String, "wallpaper.exe")
        XCTAssertEqual(
            try Data(
                contentsOf: URL(filePath: asset.projectDirectory)
                    .appending(path: "wallpaper.exe")
            ),
            Data("MZ".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: URL(filePath: asset.projectDirectory)
                    .appending(path: ".background-engine-unsupported-application.exe")
                    .path
            )
        )
    }

    func testAbsoluteApplicationReferenceIsVisibleButNeverResolvedOrLaunched() async throws {
        let source = try makeDirectory()
        let metadata: [String: Any] = [
            "Title": "External Windows App",
            "Type": "Unity",
            "FileName": #"C:\Program Files\Lively Wallpaper\wallpaper.exe"#,
            "IsAbsolutePath": true,
            "Preview": #"C:\Program Files\Lively Wallpaper\preview.gif"#,
        ]
        try JSONSerialization.data(withJSONObject: metadata).write(
            to: source.appending(path: "LivelyInfo.json")
        )
        try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        ).write(to: source.appending(path: "preview.gif"))
        let originalEntries = try FileManager.default.contentsOfDirectory(atPath: source.path)
        let (importer, _, library) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }

        let asset = try await importer.importAndPrepare(source)

        XCTAssertEqual(asset.kind, .application)
        XCTAssertEqual(asset.supportStatus, .unsupported)
        XCTAssertTrue(asset.issues.contains { $0.code == "windows_application_unsupported" })
        XCTAssertEqual(
            try projectJSON(asset)["file"] as? String,
            ".background-engine-unsupported-application.exe"
        )
        XCTAssertEqual(try projectJSON(asset)["preview"] as? String, "preview.gif")
        let placeholder = URL(filePath: asset.projectDirectory)
            .appending(path: ".background-engine-unsupported-application.exe")
        XCTAssertEqual(try Data(contentsOf: placeholder), Data())
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: source.path),
            originalEntries,
            "Absolute application references must be represented only in private staging."
        )
        XCTAssertFalse(asset.projectDirectory.contains("Program Files"))
    }

    func testPictureTypeImportsThroughAnimatedImagePlaybackPath() async throws {
        let gif = try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        )
        let source = try makeProject(
            title: "Lively Picture",
            type: "Picture",
            fileName: "wallpaper.gif",
            entrypointData: gif
        )
        let (importer, _, library) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }

        let asset = try await importer.importAndPrepare(source)

        XCTAssertEqual(asset.kind, .image)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(try projectJSON(asset)["type"] as? String, "image")
    }

    func testNativeMediaPropertiesAreReportedLimitedInsteadOfSilentlyFull() async throws {
        let gif = try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        )
        let source = try makeProject(
            title: "Configurable Lively Picture",
            type: "Picture",
            fileName: "wallpaper.gif",
            entrypointData: gif
        )
        try Data(#"{"playbackSpeed":{"type":"slider","value":1,"min":0.5,"max":2}}"#.utf8)
            .write(to: source.appending(path: "LivelyProperties.json"))
        let (importer, _, library) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }

        let asset = try await importer.importAndPrepare(source)

        XCTAssertEqual(asset.kind, .image)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(asset.compatibilityReport?.level, .limited)
        XCTAssertEqual(asset.compatibilityReport?.missingCapabilities, [.interaction])
        XCTAssertEqual(
            asset.compatibilityReport?.diagnosticCode,
            "lively_media_properties_limited"
        )
        XCTAssertTrue(
            asset.compatibilityReport?.warnings.contains {
                $0.contains("native Video or Image")
            } == true
        )
    }

    func testExplicitGIFAndVideoTypesUseTheirNativePlaybackKinds() async throws {
        let gif = try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        )
        let videoBase64 = """
        AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAAGW1kYXQAAAGzABAHAAABthYpGF9t+wAAAy9tb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAD6AABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACWnRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAD6AAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAgAAAAIAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAA+gAAAAAAAEAAAAAAdJtZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAAEAAAABAAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAF9bWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABPXN0YmwAAADZc3RzZAAAAAAAAAABAAAAyW1wNHYAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAgACAEgAAABIAAAAAAAAAAESTGF2YzYzLjEuMTAxIG1wZWc0AAAAAAAAAAAAAAAAAAAY//8AAABfZXNkcwAAAAADgICATgABAASAgIBAIBEAAAAAAw1AAAAAiAWAgIAuAAABsAEAAAG1iRMAAAEAAAABIADEjYgADQAUAFRjAAABskxhdmM2My4xLjEwMQaAgIABAgAAABRidHJ0AAAAAAADDUAAAACIAAAAGHN0dHMAAAAAAAAAAQAAAAEAAEAAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAABAAAAAQAAABRzdHN6AAAAAAAAABEAAAABAAAAFHN0Y28AAAAAAAAAAQAAACwAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAx
        """
        let video = try XCTUnwrap(
            Data(base64Encoded: videoBase64, options: .ignoreUnknownCharacters)
        )
        for (type, fileName, data, expectedKind, expectedProjectType) in [
            ("Gif", "wallpaper.gif", gif, WallpaperKind.image, "image"),
            ("Video", "wallpaper.mp4", video, WallpaperKind.video, "video"),
        ] {
            let source = try makeProject(
                title: "Lively \(type)",
                type: type,
                fileName: fileName,
                entrypointData: data
            )
            let (importer, _, library) = try makeImporter()
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: library)
            }

            let asset = try await importer.importAndPrepare(source)

            XCTAssertEqual(asset.kind, expectedKind, "Lively type: \(type)")
            XCTAssertEqual(
                asset.supportStatus,
                .playable,
                "Lively type: \(type); issues: \(asset.issues)"
            )
            XCTAssertEqual(try projectJSON(asset)["type"] as? String, expectedProjectType)
        }
    }

    func testMetadataOnlyURLAndVideoStreamExportsBecomeOptInWebWallpapers() async throws {
        for (type, target, expectedEntrypoint) in [
            (3, "https://example.com/wallpaper", ".background-engine-lively-url.html"),
            (10, "https://cdn.example.com/live/stream.mp4", ".background-engine-lively-stream.html"),
        ] {
            let source = try makeDirectory()
            let metadata: [String: Any] = [
                "Title": type == 3 ? "Remote Website" : "Remote Stream",
                "Type": type,
                "FileName": target,
                "IsAbsolutePath": true,
            ]
            try JSONSerialization.data(withJSONObject: metadata).write(
                to: source.appending(path: "LivelyInfo.json")
            )
            if type == 3 {
                try Data(#"{"refresh":{"type":"button","text":"Refresh"}}"#.utf8).write(
                    to: source.appending(path: "LivelyProperties.json")
                )
            }
            let originalEntries = try FileManager.default.contentsOfDirectory(atPath: source.path)
            let (importer, _, library) = try makeImporter()
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: library)
            }

            let asset = try await importer.importAndPrepare(source)

            XCTAssertEqual(asset.kind, .web)
            XCTAssertEqual(
                asset.compatibilityReport?.missingCapabilities,
                [.externalNetwork]
            )
            XCTAssertEqual(asset.compatibilityReport?.diagnosticCode, "web_network_access_required")
            XCTAssertEqual(asset.allowsNetworkAccess, false)
            XCTAssertEqual(try projectJSON(asset)["file"] as? String, expectedEntrypoint)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: source.path),
                originalEntries,
                "Remote compatibility files must be generated only in staging."
            )
            XCTAssertEqual(
                RemoteWebWallpaperConfiguration.load(
                    projectRoot: URL(filePath: asset.projectDirectory)
                )?.targetURL.absoluteString,
                target
            )
            let enabled = asset.allowingNetworkAccess(true)
            XCTAssertEqual(enabled.compatibilityReport?.level, .limited)
            XCTAssertEqual(
                enabled.compatibilityReport?.missingCapabilities,
                []
            )
            XCTAssertEqual(
                enabled.compatibilityReport?.diagnosticCode,
                "web_remote_runtime_unverified"
            )
        }
    }

    func testRemoteLivelyExportsRejectInsecureAndPrivateTargets() async throws {
        for target in ["http://example.com/wallpaper", "https://127.0.0.1/private"] {
            let source = try makeDirectory()
            let metadata: [String: Any] = [
                "Title": "Unsafe URL",
                "Type": 3,
                "FileName": target,
                "IsAbsolutePath": false,
            ]
            try JSONSerialization.data(withJSONObject: metadata).write(
                to: source.appending(path: "LivelyInfo.json")
            )
            let (importer, _, library) = try makeImporter()
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: library)
            }

            await assertImportFails(importer, source: source) {
                $0 == .unsupportedRemoteURL
            }
        }
    }

    func testOneWrapperZIPIsValidatedExtractedAndImported() async throws {
        let archive = try makeTemporaryURL(extension: "zip")
        let metadata = livelyInfo(title: "Wrapped ZIP", type: 1, fileName: "index.html")
        try TestZIP(entries: [
            .file("Wrapped/LivelyInfo.json", Data(metadata.utf8)),
            .file("Wrapped/index.html", Data("<!doctype html><title>ZIP</title>".utf8)),
        ]).data().write(to: archive)
        let (importer, _, library) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: library)
        }

        let asset = try await importer.importAndPrepare(archive)

        XCTAssertEqual(asset.title, "Wrapped ZIP")
        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(asset.source, .manualFolder)
    }

    func testRootZIPUsesExactEntrySelectionAndLeavesArchiveUnchanged() async throws {
        let archive = try makeTemporaryURL(extension: "zip")
        let original = TestZIP(entries: [
            .file("LivelyInfo.json", Data(livelyInfo(title: "Root ZIP", type: 1, fileName: "index.html").utf8)),
            .file("index.html", Data("<!doctype html><title>Root</title>".utf8)),
        ]).data()
        try original.write(to: archive)
        let (importer, _, library) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: library)
        }

        let asset = try await importer.importAndPrepare(archive)

        XCTAssertEqual(asset.title, "Root ZIP")
        XCTAssertEqual(asset.kind, .web)
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }

    func testForgedDeclaredSizeStopsAfterOneBoundedReadWithoutCompletingImport() async throws {
        let archive = try makeTemporaryURL(extension: "zip")
        try TestZIP(entries: [
            .file("LivelyInfo.json", Data("{}".utf8)),
        ]).data().write(to: archive)
        let script = try makeExecutableScript("""
        #!/bin/sh
        exec /usr/bin/yes A
        """)
        let (importer, _, library) = try makeImporter(unzipExecutable: script)
        defer {
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: library)
        }

        do {
            _ = try await importer.importAndPrepare(archive)
            XCTFail("Expected forged extraction output to be rejected")
        } catch let error as LivelyWallpaperImportError {
            guard case .extractedEntrySizeMismatch(_, let actual, let expected) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, 2)
            XCTAssertGreaterThan(actual, expected)
            XCTAssertLessThanOrEqual(actual, 16 * 1_024)
        }
    }

    func testCancellationReapsPerEntryExtractor() async throws {
        let archive = try makeTemporaryURL(extension: "zip")
        try TestZIP(entries: [
            .file("LivelyInfo.json", Data(livelyInfo(title: "Cancel", type: 1, fileName: "index.html").utf8)),
            .file("index.html", Data("<!doctype html>".utf8)),
        ]).data().write(to: archive)
        let markerRoot = try makeDirectory()
        let pidFile = markerRoot.appending(path: "extractor.pid")
        let script = try makeExecutableScript("""
        #!/bin/sh
        echo $$ > '\(pidFile.path)'
        exec /bin/sleep 30
        """)
        let (importer, _, library) = try makeImporter(unzipExecutable: script)
        defer {
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: markerRoot)
            try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: library)
        }

        let task = Task { try await importer.importAndPrepare(archive) }
        try await waitForFile(pidFile, timeout: .seconds(5))
        let processIdentifier = try XCTUnwrap(
            Int32(String(decoding: Data(contentsOf: pidFile), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while Darwin.kill(processIdentifier, 0) == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testEntryTimeoutTerminatesAndReapsExtractor() async throws {
        let archive = try makeTemporaryURL(extension: "zip")
        try TestZIP(entries: [
            .file("LivelyInfo.json", Data(livelyInfo(title: "Timeout", type: 1, fileName: "index.html").utf8)),
        ]).data().write(to: archive)
        let markerRoot = try makeDirectory()
        let pidFile = markerRoot.appending(path: "extractor.pid")
        let script = try makeExecutableScript("""
        #!/bin/sh
        echo $$ > '\(pidFile.path)'
        exec /bin/sleep 30
        """)
        let (importer, _, library) = try makeImporter(
            unzipExecutable: script,
            entryExtractionTimeout: .milliseconds(100)
        )
        defer {
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: markerRoot)
            try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: library)
        }

        await assertImportFails(importer, source: archive) { error in
            guard case .extractionTimedOut("LivelyInfo.json") = error else { return false }
            return true
        }
        try await waitForFile(pidFile, timeout: .seconds(5))
        let processIdentifier = try XCTUnwrap(
            Int32(String(decoding: Data(contentsOf: pidFile), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testRejectsUnzipPatternOptionAndUnicodePathOverrideEntries() async throws {
        let unicodeOverride = Data([0x75, 0x70, 0x01, 0x00, 0x01])
        let cases: [[TestZIP.Entry]] = [
            [.file("Wrapped/*.html", Data("wildcard".utf8))],
            [.file("-x", Data("option".utf8))],
            [TestZIP.Entry(
                name: "Wrapped/index.html",
                data: Data("override".utf8),
                centralExtra: unicodeOverride,
                localExtra: unicodeOverride
            )],
        ]
        for entries in cases {
            let archive = try makeTemporaryURL(extension: "zip")
            try TestZIP(entries: entries).data().write(to: archive)
            let (importer, _, library) = try makeImporter()
            defer {
                try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: library)
            }

            await assertImportFails(importer, source: archive) { error in
                switch error {
                case .unsafeMetadataPath, .unsupportedZIPFeature: true
                default: false
                }
            }
        }
    }

    func testRejectsZIPTraversalBeforeExtraction() async throws {
        let archive = try makeTemporaryURL(extension: "zip")
        try TestZIP(entries: [.file("../escape.txt", Data("escape".utf8))]).data().write(to: archive)
        let (importer, _, library) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: library)
        }

        await assertImportFails(importer, source: archive) { error in
            guard case .unsafeMetadataPath = error else { return false }
            return true
        }
    }

    func testRejectsFolderAndZIPSymbolicLinks() async throws {
        let source = try makeProject(title: "Link", type: 1, fileName: "index.html")
        try FileManager.default.createSymbolicLink(
            at: source.appending(path: "escape"),
            withDestinationURL: URL(filePath: "/tmp")
        )
        let (folderImporter, _, folderLibrary) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: folderLibrary)
        }
        await assertImportFails(folderImporter, source: source) { error in
            guard case .unsafeTree = error else { return false }
            return true
        }

        let archive = try makeTemporaryURL(extension: "zip")
        let symlinkMode = UInt32(S_IFLNK | 0o777) << 16
        try TestZIP(entries: [
            .init(name: "Wrapped/escape", data: Data("../../outside".utf8), externalAttributes: symlinkMode),
        ]).data().write(to: archive)
        let (zipImporter, _, zipLibrary) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: zipLibrary)
        }
        await assertImportFails(zipImporter, source: archive) { error in
            guard case .unsafeTree = error else { return false }
            return true
        }
    }

    func testFolderSnapshotRejectsEntryReplacedBySymlinkAfterInspection() async throws {
        let source = try makeProject(title: "Raced Link", type: 1, fileName: "index.html")
        let outside = try makeDirectory()
        let sentinel = outside.appending(path: "secret.html")
        let secret = Data("outside-secret-must-not-be-imported".utf8)
        try secret.write(to: sentinel)
        let inspected = AsyncTestSignal()
        let continueCopy = DispatchSemaphore(value: 0)
        let (importer, store, library) = try makeImporter { checkpoint in
            guard checkpoint == .entryInspected("index.html") else { return }
            inspected.signal()
            continueCopy.wait()
        }
        let entrypoint = source.appending(path: "index.html")
        let mutation = Task.detached {
            await inspected.wait()
            defer { continueCopy.signal() }
            try FileManager.default.removeItem(at: entrypoint)
            try FileManager.default.createSymbolicLink(
                at: entrypoint,
                withDestinationURL: sentinel
            )
        }
        defer {
            continueCopy.signal()
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: outside)
            try? FileManager.default.removeItem(at: library)
        }

        await assertImportFails(importer, source: source) { error in
            guard case .unsafeTree = error else { return false }
            return true
        }
        try await mutation.value
        XCTAssertTrue(try store.load().assets.isEmpty)
    }

    func testFolderSnapshotRejectsFileGrowthAfterOpenWithoutExceedingBound() async throws {
        let source = try makeProject(
            title: "Raced Growth",
            type: 1,
            fileName: "index.html",
            entrypointData: Data("initial".utf8)
        )
        let opened = AsyncTestSignal()
        let continueCopy = DispatchSemaphore(value: 0)
        let limits = LivelyWallpaperPackageImporter.Limits(
            maximumEntries: 100,
            maximumArchiveBytes: 1_024,
            maximumEntryBytes: 1_024,
            maximumUncompressedBytes: 4_096,
            maximumCompressionRatio: 200
        )
        let (importer, store, library) = try makeImporter(
            limits: limits,
            sourceCopyObserver: { checkpoint in
                guard checkpoint == .entryOpened("index.html") else { return }
                opened.signal()
                continueCopy.wait()
            }
        )
        let entrypoint = source.appending(path: "index.html")
        let mutation = Task.detached {
            await opened.wait()
            defer { continueCopy.signal() }
            let handle = try FileHandle(forWritingTo: entrypoint)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 0x61, count: 128))
        }
        defer {
            continueCopy.signal()
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }

        await assertImportFails(importer, source: source) { error in
            guard case .unsafeTree = error else { return false }
            return true
        }
        try await mutation.value
        XCTAssertTrue(try store.load().assets.isEmpty)
    }

    func testArchiveSnapshotRejectsGrowthAfterOpenWithoutParsingChangedBytes() async throws {
        let archive = try makeTemporaryURL(extension: "zip")
        let original = TestZIP(entries: [
            .file(
                "LivelyInfo.json",
                Data(livelyInfo(title: "Raced ZIP", type: 1, fileName: "index.html").utf8)
            ),
            .file("index.html", Data("<!doctype html>".utf8)),
        ]).data()
        try original.write(to: archive)
        let opened = AsyncTestSignal()
        let continueCopy = DispatchSemaphore(value: 0)
        let limits = LivelyWallpaperPackageImporter.Limits(
            maximumEntries: 100,
            maximumArchiveBytes: UInt64(original.count + 1_024),
            maximumEntryBytes: 1_024,
            maximumUncompressedBytes: 4_096,
            maximumCompressionRatio: 200
        )
        let (importer, store, library) = try makeImporter(
            limits: limits,
            sourceCopyObserver: { checkpoint in
                guard checkpoint == .archiveOpened else { return }
                opened.signal()
                continueCopy.wait()
            }
        )
        let mutation = Task.detached {
            await opened.wait()
            defer { continueCopy.signal() }
            let handle = try FileHandle(forWritingTo: archive)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 0, count: 128))
        }
        defer {
            continueCopy.signal()
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: library)
        }

        await assertImportFails(importer, source: archive) { error in
            guard case .unsafeTree = error else { return false }
            return true
        }
        try await mutation.value
        XCTAssertEqual(try Data(contentsOf: archive).count, original.count + 128)
        XCTAssertTrue(try store.load().assets.isEmpty)
    }

    func testArchiveSnapshotRejectsPathReplacementAfterOpen() async throws {
        let archive = try makeTemporaryURL(extension: "zip")
        let original = TestZIP(entries: [
            .file(
                "LivelyInfo.json",
                Data(livelyInfo(title: "Pinned ZIP", type: 1, fileName: "index.html").utf8)
            ),
            .file("index.html", Data("<!doctype html>original".utf8)),
        ]).data()
        try original.write(to: archive)
        let replacement = archive.deletingLastPathComponent().appending(path: "replacement.zip")
        try TestZIP(entries: [
            .file(
                "LivelyInfo.json",
                Data(livelyInfo(title: "Replacement", type: 1, fileName: "index.html").utf8)
            ),
            .file("index.html", Data("outside-replacement".utf8)),
        ]).data().write(to: replacement)
        let movedOriginal = archive.deletingLastPathComponent().appending(path: "opened-original.zip")
        let opened = AsyncTestSignal()
        let continueCopy = DispatchSemaphore(value: 0)
        let (importer, store, library) = try makeImporter { checkpoint in
            guard checkpoint == .archiveOpened else { return }
            opened.signal()
            continueCopy.wait()
        }
        let mutation = Task.detached {
            await opened.wait()
            defer { continueCopy.signal() }
            try FileManager.default.moveItem(at: archive, to: movedOriginal)
            try FileManager.default.createSymbolicLink(
                at: archive,
                withDestinationURL: replacement
            )
        }
        defer {
            continueCopy.signal()
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: library)
        }

        await assertImportFails(importer, source: archive) { error in
            guard case .unsafeTree = error else { return false }
            return true
        }
        try await mutation.value
        XCTAssertEqual(try Data(contentsOf: movedOriginal), original)
        XCTAssertTrue(try store.load().assets.isEmpty)
    }

    func testLocalLivelyProjectCannotSupplyReservedRemoteConfiguration() async throws {
        let source = try makeProject(title: "Reserved Metadata", type: 1, fileName: "index.html")
        let remoteConfiguration = try RemoteWebWallpaperConfiguration(
            targetURL: XCTUnwrap(URL(string: "https://example.com/remote"))
        )
        try JSONEncoder().encode(remoteConfiguration).write(
            to: source.appending(path: RemoteWebWallpaperConfiguration.fileName)
        )
        let (importer, store, library) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }

        await assertImportFails(importer, source: source) {
            $0 == .generatedFileConflict
        }
        XCTAssertTrue(try store.load().assets.isEmpty)
    }

    func testRejectsZIPCompressionBombRatio() async throws {
        let archive = try makeTemporaryURL(extension: "zip")
        try TestZIP(entries: [
            .init(
                name: "Wrapped/payload.bin",
                data: Data([0]),
                method: 8,
                declaredCompressedSize: 1,
                declaredUncompressedSize: 10_000
            ),
        ]).data().write(to: archive)
        let limits = LivelyWallpaperPackageImporter.Limits(maximumCompressionRatio: 50)
        let (importer, _, library) = try makeImporter(limits: limits)
        defer {
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: library)
        }

        await assertImportFails(importer, source: archive) { error in
            guard case .compressionRatioTooHigh = error else { return false }
            return true
        }
    }

    func testRejectsCaseFoldedAndUnicodeNormalizedZIPCollisions() async throws {
        for entries in [
            [TestZIP.Entry.file("Wrapped/Asset.png", Data([1])), .file("Wrapped/asset.png", Data([2]))],
            [TestZIP.Entry.file("Wrapped/café.png", Data([1])), .file("Wrapped/cafe\u{301}.png", Data([2]))],
        ] {
            let archive = try makeTemporaryURL(extension: "zip")
            try TestZIP(entries: entries).data().write(to: archive)
            let (importer, _, library) = try makeImporter()
            defer {
                try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: library)
            }
            await assertImportFails(importer, source: archive) { error in
                guard case .pathCollision = error else { return false }
                return true
            }
        }
    }

    func testRejectsMalformedMetadataAbsolutePathsAndAmbiguousWrapper() async throws {
        let malformed = try makeDirectory()
        try Data("{".utf8).write(to: malformed.appending(path: "LivelyInfo.json"))
        let (malformedImporter, _, malformedLibrary) = try makeImporter()
        await assertImportFails(malformedImporter, source: malformed) { $0 == .malformedMetadata }

        let absolute = try makeProject(
            title: "Absolute",
            type: 1,
            fileName: "index.html",
            isAbsolutePath: true
        )
        let (absoluteImporter, _, absoluteLibrary) = try makeImporter()
        await assertImportFails(absoluteImporter, source: absolute) { $0 == .absolutePathMetadata }

        let ambiguous = try makeDirectory()
        try FileManager.default.createDirectory(at: ambiguous.appending(path: "A"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: ambiguous.appending(path: "B"), withIntermediateDirectories: false)
        try Data(livelyInfo(title: "A", type: 1, fileName: "index.html").utf8)
            .write(to: ambiguous.appending(path: "A/LivelyInfo.json"))
        let (ambiguousImporter, _, ambiguousLibrary) = try makeImporter()
        await assertImportFails(ambiguousImporter, source: ambiguous) { $0 == .missingOrAmbiguousMetadata }
        for url in [
            malformed, malformedLibrary, absolute, absoluteLibrary,
            ambiguous, ambiguousLibrary,
        ] { try? FileManager.default.removeItem(at: url) }
    }

    func testRejectsEncryptedAndMultiDiskZIP() async throws {
        let encrypted = try makeTemporaryURL(extension: "zip")
        try TestZIP(entries: [
            .init(name: "Wrapped/file", data: Data([1]), flags: 0x0001),
        ]).data().write(to: encrypted)
        let (encryptedImporter, _, encryptedLibrary) = try makeImporter()
        await assertImportFails(encryptedImporter, source: encrypted) { $0 == .encryptedZIP }

        let multiDisk = try makeTemporaryURL(extension: "zip")
        try TestZIP(entries: [.file("Wrapped/file", Data([1]))], diskNumber: 1).data().write(to: multiDisk)
        let (multiDiskImporter, _, multiDiskLibrary) = try makeImporter()
        await assertImportFails(multiDiskImporter, source: multiDisk) { $0 == .multiDiskZIP }
        for url in [
            encrypted.deletingLastPathComponent(), encryptedLibrary,
            multiDisk.deletingLastPathComponent(), multiDiskLibrary,
        ] { try? FileManager.default.removeItem(at: url) }
    }

    func testRepeatedImportDeduplicatesByNormalizedContent() async throws {
        let source = try makeProject(title: "Stable", type: 1, fileName: "index.html")
        let (importer, store, library) = try makeImporter()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: library)
        }

        let first = try await importer.importAndPrepare(source)
        let second = try await importer.importAndPrepare(source)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.contentHash, second.contentHash)
        XCTAssertEqual(try store.load().assets.count, 1)
    }

    private func makeImporter(
        limits: LivelyWallpaperPackageImporter.Limits = .init(),
        unzipExecutable: URL = URL(filePath: "/usr/bin/unzip"),
        entryExtractionTimeout: Duration? = nil,
        sourceCopyObserver: (@Sendable (LivelySourceCopyCheckpoint) -> Void)? = nil
    ) throws -> (LivelyWallpaperPackageImporter, LibraryStore, URL) {
        let library = try makeDirectory()
        let store = LibraryStore(root: library)
        return (
            LivelyWallpaperPackageImporter(
                store: store,
                limits: limits,
                unzipExecutable: unzipExecutable,
                entryExtractionTimeout: entryExtractionTimeout ?? .seconds(300),
                sourceCopyObserver: sourceCopyObserver,
                convertedVideoCacheDirectory: library.appending(
                    path: "VideoCache",
                    directoryHint: .isDirectory
                )
            ),
            store,
            library
        )
    }

    private func makeProject(
        title: String,
        type: Any,
        fileName: String,
        isAbsolutePath: Bool = false,
        entrypointData: Data = Data("<!doctype html><title>Lively</title>".utf8),
        extraFiles: [String: Data] = [:]
    ) throws -> URL {
        let root = try makeDirectory()
        let metadata = livelyInfo(
            title: title,
            type: type,
            fileName: fileName,
            isAbsolutePath: isAbsolutePath,
            thumbnail: extraFiles["preview.gif"] == nil ? nil : "preview.gif"
        )
        try Data(metadata.utf8).write(to: root.appending(path: "LivelyInfo.json"))
        var files = extraFiles
        files[fileName] = entrypointData
        for (path, data) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        return root
    }

    private func livelyInfo(
        title: String,
        type: Any,
        fileName: String,
        isAbsolutePath: Bool = false,
        thumbnail: String? = nil
    ) -> String {
        var object: [String: Any] = [
            "Title": title,
            "Type": type,
            "FileName": fileName,
            "IsAbsolutePath": isAbsolutePath,
        ]
        if let thumbnail { object["Thumbnail"] = thumbnail }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func projectJSON(_ asset: WallpaperAsset) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(filePath: asset.projectDirectory).appending(path: "project.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "lively-import-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func makeTemporaryURL(extension pathExtension: String) throws -> URL {
        let root = try makeDirectory()
        return root.appending(path: "package.\(pathExtension)")
    }

    private func makeExecutableScript(_ contents: String) throws -> URL {
        let root = try makeDirectory()
        let script = root.appending(path: "fake-unzip")
        try Data(contents.utf8).write(to: script)
        guard chmod(script.path, S_IRWXU) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return script
    }

    private func waitForFile(_ url: URL, timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !FileManager.default.fileExists(atPath: url.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    private func assertImportFails(
        _ importer: LivelyWallpaperPackageImporter,
        source: URL,
        matching predicate: (LivelyWallpaperImportError) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await importer.importAndPrepare(source)
            XCTFail("Expected Lively import to fail", file: file, line: line)
        } catch let error as LivelyWallpaperImportError {
            XCTAssertTrue(predicate(error), "Unexpected error: \(error)", file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private final class AsyncTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if isSignaled { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func signal() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !isSignaled else { return [] }
            isSignaled = true
            let continuations = waiters
            waiters.removeAll(keepingCapacity: false)
            return continuations
        }
        continuations.forEach { $0.resume() }
    }
}

private struct TestZIP {
    struct Entry {
        let name: String
        let data: Data
        var flags: UInt16 = 0
        var method: UInt16 = 0
        var externalAttributes: UInt32 = UInt32(S_IFREG | 0o644) << 16
        var declaredCompressedSize: UInt32?
        var declaredUncompressedSize: UInt32?
        var centralExtra = Data()
        var localExtra = Data()

        static func file(_ name: String, _ data: Data) -> Entry {
            Entry(name: name, data: data)
        }
    }

    let entries: [Entry]
    var diskNumber: UInt16 = 0

    func data() -> Data {
        var archive = Data()
        var central: [(entry: Entry, name: Data, crc: UInt32, offset: UInt32)] = []
        for var entry in entries {
            let name = Data(entry.name.utf8)
            if name.contains(where: { $0 >= 0x80 }) { entry.flags |= 0x0800 }
            let crc = Self.crc32(entry.data)
            let compressed = entry.declaredCompressedSize ?? UInt32(entry.data.count)
            let uncompressed = entry.declaredUncompressedSize ?? UInt32(entry.data.count)
            let offset = UInt32(archive.count)
            archive.appendLE(UInt32(0x0403_4b50))
            archive.appendLE(UInt16(20))
            archive.appendLE(entry.flags)
            archive.appendLE(entry.method)
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(crc)
            archive.appendLE(compressed)
            archive.appendLE(uncompressed)
            archive.appendLE(UInt16(name.count))
            archive.appendLE(UInt16(entry.localExtra.count))
            archive.append(name)
            archive.append(entry.localExtra)
            archive.append(entry.data)
            central.append((entry, name, crc, offset))
        }
        let centralOffset = UInt32(archive.count)
        for item in central {
            let compressed = item.entry.declaredCompressedSize ?? UInt32(item.entry.data.count)
            let uncompressed = item.entry.declaredUncompressedSize ?? UInt32(item.entry.data.count)
            archive.appendLE(UInt32(0x0201_4b50))
            archive.appendLE(UInt16((3 << 8) | 20))
            archive.appendLE(UInt16(20))
            archive.appendLE(item.entry.flags | (item.name.contains(where: { $0 >= 0x80 }) ? 0x0800 : 0))
            archive.appendLE(item.entry.method)
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(item.crc)
            archive.appendLE(compressed)
            archive.appendLE(uncompressed)
            archive.appendLE(UInt16(item.name.count))
            archive.appendLE(UInt16(item.entry.centralExtra.count))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(item.entry.externalAttributes)
            archive.appendLE(item.offset)
            archive.append(item.name)
            archive.append(item.entry.centralExtra)
        }
        let centralSize = UInt32(archive.count) - centralOffset
        archive.appendLE(UInt32(0x0605_4b50))
        archive.appendLE(diskNumber)
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(centralSize)
        archive.appendLE(centralOffset)
        archive.appendLE(UInt16(0))
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        appendLE(UInt16(truncatingIfNeeded: value))
        appendLE(UInt16(truncatingIfNeeded: value >> 16))
    }
}
