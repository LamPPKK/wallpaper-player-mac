import BackgroundEngineCore
import Darwin
import JavaScriptCore
import WebKit
import XCTest
@testable import BackgroundEngineApp

final class RestrictedWebWallpaperViewTests: XCTestCase {
    func testPropertyBridgeParsesSupportedWallpaperPropertyTypes() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-properties-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try #"""
        {"general":{"properties":{
          "enabled":{"type":"bool","value":true},
          "speed":{"type":"slider","value":1.5},
          "tint":{"type":"color","value":"0.2 0.4 0.6"},
          "mode":{"type":"combo","value":"waves"},
          "caption":{"type":"textinput","value":"Hello"},
          "ignored":{"type":"unsupported","value":"x"}
        }}}
        """#.write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)

        let values = WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: project)

        XCTAssertEqual(values["enabled"], .bool(true))
        XCTAssertEqual(values["speed"], .number(1.5))
        XCTAssertEqual(values["tint"], .text("0.2 0.4 0.6"))
        XCTAssertEqual(values["mode"], .text("waves"))
        XCTAssertEqual(values["caption"], .text("Hello"))
        XCTAssertNil(values["ignored"])
    }

    func testEditablePropertiesPreserveWallpaperMetadataAndTypedOverrides() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-editable-properties-\(UUID().uuidString)")
        let storage = project.appending(path: WebWallpaperUserFileStore.directoryName)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try #"""
        {"general":{"properties":{
          "heading":{"type":"text","text":"Visuals","order":0},
          "enabled":{"type":"bool","text":"Enabled","value":true,"order":1},
          "speed":{"type":"slider","text":"Speed","value":1.5,"min":0.5,"max":3,"step":0.25,"order":2},
          "tint":{"type":"color","text":"Tint","value":"0.2 0.4 0.6","order":3},
          "mode":{"type":"combo","text":"Mode","value":"waves","order":4,
            "options":[{"label":"Waves","value":"waves"},{"label":"Rain","value":"rain"}]},
          "caption":{"type":"textinput","text":"Caption","value":"Hello","order":5},
          "photo":{"type":"file","text":"Photo","value":"","order":6}
        }}}
        """#.write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        let overrides: [String: WebWallpaperPropertyOverrideValue] = [
            "enabled": .bool(false),
            "speed": .number(2.5),
            "mode": .text("rain"),
            // A mismatched type must never be injected into applyUserProperties.
            "caption": .bool(true),
            "unknown": .text("ignored")
        ]
        try JSONEncoder().encode(overrides).write(
            to: storage.appending(path: WebWallpaperUserFileStore.valueOverridesFileName)
        )

        let descriptors = WebWallpaperCompatibilityBridge.editableProperties(projectRoot: project)
        let values = WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: project)

        XCTAssertEqual(descriptors.map(\.name), ["enabled", "speed", "tint", "mode", "caption"])
        XCTAssertEqual(descriptors.map(\.kind), [.bool, .slider, .color, .combo, .text])
        let speed = try XCTUnwrap(descriptors.first { $0.name == "speed" })
        XCTAssertEqual(speed.minimum, 0.5)
        XCTAssertEqual(speed.maximum, 3)
        XCTAssertEqual(speed.step, 0.25)
        XCTAssertEqual(speed.currentValue, .number(2.5))
        let mode = try XCTUnwrap(descriptors.first { $0.name == "mode" })
        XCTAssertEqual(mode.options, [
            .init(label: "Waves", value: "waves"),
            .init(label: "Rain", value: "rain")
        ])
        XCTAssertEqual(mode.currentValue, .text("rain"))
        XCTAssertEqual(
            WebWallpaperCompatibilityBridge.comboDisplayTexts(projectRoot: project),
            ["mode": "Rain"]
        )
        XCTAssertEqual(values["enabled"], .bool(false))
        XCTAssertEqual(values["speed"], .number(2.5))
        XCTAssertEqual(values["mode"], .text("rain"))
        XCTAssertEqual(values["caption"], .text("Hello"))
        XCTAssertNil(values["unknown"])
    }

    func testScalarOverridesReachLateWallpaperPropertyListener() throws {
        let script = WebWallpaperCompatibilityBridge.bootstrapScript(
            properties: [
                "enabled": .bool(false),
                "speed": .number(2.75),
                "caption": .text("Customized"),
                "mode": .text("rain")
            ],
            comboDisplayTexts: ["mode": "Rain"]
        )
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var pendingTimeouts = [];
        var document = { readyState: 'complete' };
        var window = {
          clearInterval: function() {},
          setInterval: function() { return 1; },
          setTimeout: function(callback) { pendingTimeouts.push(callback); return pendingTimeouts.length; },
          addEventListener: function() {}
        };
        """#)
        context.evaluateScript(script)
        context.evaluateScript(#"""
        var received = null;
        window.wallpaperPropertyListener = {
          applyUserProperties: function(properties) { received = properties; }
        };
        while (pendingTimeouts.length > 0) pendingTimeouts.shift()();
        """#)

        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("received.enabled.value")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("received.speed.value")?.toDouble(), 2.75)
        XCTAssertEqual(context.evaluateScript("received.caption.value")?.toString(), "Customized")
        XCTAssertEqual(context.evaluateScript("received.mode.value")?.toString(), "rain")
        XCTAssertEqual(context.evaluateScript("received.mode.text")?.toString(), "Rain")
    }

    func testPersistedOverridesDropDefaultsUnknownKeysAndMismatchedTypes() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-persisted-overrides-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try #"{"general":{"properties":{"enabled":{"type":"bool","value":true},"speed":{"type":"slider","value":1},"caption":{"type":"textinput","value":"Default"}}}}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        let properties = WebWallpaperCompatibilityBridge.editableProperties(projectRoot: project)

        let overrides = WebWallpaperCompatibilityBridge.persistedOverrides(
            [
                "enabled": .bool(true),
                "speed": .text("wrong type"),
                "caption": .text("Customized"),
                "unknown": .bool(false)
            ],
            properties: properties
        )

        XCTAssertEqual(overrides, ["caption": .text("Customized")])
    }

    func testPropertyBridgeRejectsOversizedProjectMetadata() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-oversized-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let metadata = project.appending(path: "project.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: metadata.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: metadata)
        try handle.truncate(
            atOffset: UInt64(WebWallpaperMetadataFileReader.maximumProjectMetadataBytes + 1)
        )
        try handle.close()

        XCTAssertTrue(WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: project).isEmpty)
        XCTAssertTrue(WebWallpaperCompatibilityBridge.fileProperties(projectRoot: project).isEmpty)
        XCTAssertTrue(WebWallpaperCompatibilityBridge.directoryProperties(projectRoot: project).isEmpty)
    }

    func testPropertyBridgeDoesNotFollowProjectMetadataSymlink() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-symlinked-metadata-\(UUID().uuidString)")
        let outside = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-outside-metadata-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: outside)
        }
        try #"{"general":{"properties":{"caption":{"type":"text","value":"outside"}}}}"#
            .write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: project.appending(path: "project.json"),
            withDestinationURL: outside
        )

        XCTAssertTrue(WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: project).isEmpty)
        XCTAssertTrue(WebWallpaperCompatibilityBridge.fileProperties(projectRoot: project).isEmpty)
        XCTAssertTrue(WebWallpaperCompatibilityBridge.directoryProperties(projectRoot: project).isEmpty)
    }

    func testPropertyBridgeIgnoresOversizedOverrideMetadata() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-oversized-overrides-\(UUID().uuidString)")
        let storage = project.appending(path: WebWallpaperUserFileStore.directoryName)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try #"{"general":{"properties":{"photo":{"type":"file","value":"default"},"gallery":{"type":"directory","mode":"fetchall","value":""}}}}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        let overrides = storage.appending(path: WebWallpaperUserFileStore.overridesFileName)
        XCTAssertTrue(FileManager.default.createFile(atPath: overrides.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: overrides)
        try handle.truncate(
            atOffset: UInt64(WebWallpaperMetadataFileReader.maximumAuxiliaryMetadataBytes + 1)
        )
        try handle.close()

        XCTAssertEqual(
            WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: project)["photo"],
            .text("default")
        )
        XCTAssertEqual(
            WebWallpaperCompatibilityBridge.directoryProperties(projectRoot: project)["gallery"]?.files,
            []
        )
    }

    func testPropertyBridgeIgnoresUnsafeScalarOverrideMetadata() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-unsafe-scalar-overrides-\(UUID().uuidString)")
        let outside = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-outside-scalar-overrides-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: outside)
        }
        try #"{"general":{"properties":{"enabled":{"type":"bool","value":true}}}}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(["enabled": WebWallpaperPropertyOverrideValue.bool(false)])
            .write(to: outside.appending(path: WebWallpaperUserFileStore.valueOverridesFileName))
        try FileManager.default.createSymbolicLink(
            at: project.appending(path: WebWallpaperUserFileStore.directoryName),
            withDestinationURL: outside
        )

        XCTAssertEqual(
            WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: project)["enabled"],
            .bool(true)
        )
        XCTAssertEqual(
            WebWallpaperCompatibilityBridge.editableProperties(projectRoot: project).first?.currentValue,
            .bool(true)
        )
    }

    func testPropertyBridgeProvidesNeutralAudioAndPauseCallbacks() {
        let script = WebWallpaperCompatibilityBridge.bootstrapScript(
            properties: ["enabled": .bool(true)]
        )

        XCTAssertTrue(script.contains("wallpaperRegisterAudioListener"))
        XCTAssertTrue(script.contains("applyUserProperties"))
        XCTAssertTrue(script.contains("applyGeneralProperties"))
        XCTAssertTrue(script.contains("setPaused"))
        XCTAssertTrue(script.contains("new Array(128).fill(0)"))
        XCTAssertTrue(script.contains("wallpaperRegisterMediaStatusListener"))
        XCTAssertTrue(script.contains("wallpaperRegisterMediaPropertiesListener"))
        XCTAssertTrue(script.contains("wallpaperRegisterMediaThumbnailListener"))
        XCTAssertTrue(script.contains("wallpaperRegisterMediaPlaybackListener"))
        XCTAssertTrue(script.contains("wallpaperRegisterMediaTimelineListener"))
    }

    func testPropertyBridgeProvidesNeutralMediaIntegrationEvents() throws {
        let script = WebWallpaperCompatibilityBridge.bootstrapScript(properties: [:])
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var pendingTimeouts = [];
        var document = { readyState: 'complete' };
        var window = {
          clearInterval: function() {},
          setInterval: function() { return 1; },
          setTimeout: function(callback) { pendingTimeouts.push(callback); return pendingTimeouts.length; },
          addEventListener: function() {}
        };
        """#)
        context.evaluateScript(script)
        XCTAssertNil(context.exception, "Unexpected bridge exception: \(String(describing: context.exception))")

        context.evaluateScript(#"""
        var mediaEvents = {};
        window.wallpaperRegisterMediaStatusListener(function(event) { mediaEvents.status = event; });
        window.wallpaperRegisterMediaPropertiesListener(function(event) { mediaEvents.properties = event; });
        window.wallpaperRegisterMediaThumbnailListener(function(event) { mediaEvents.thumbnail = event; });
        window.wallpaperRegisterMediaPlaybackListener(function(event) { mediaEvents.playback = event; });
        window.wallpaperRegisterMediaTimelineListener(function(event) { mediaEvents.timeline = event; });
        while (pendingTimeouts.length > 0) pendingTimeouts.shift()();
        """#)
        XCTAssertNil(context.exception, "Unexpected media callback exception: \(String(describing: context.exception))")

        let encoded = try XCTUnwrap(
            context.evaluateScript("JSON.stringify(mediaEvents)")?.toString()
        )
        let mediaEvents = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        )
        XCTAssertEqual((mediaEvents["status"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual((mediaEvents["properties"] as? [String: Any])?["title"] as? String, "")
        XCTAssertEqual((mediaEvents["thumbnail"] as? [String: Any])?["thumbnail"] as? String, "")
        XCTAssertEqual((mediaEvents["timeline"] as? [String: Any])?["duration"] as? Int, 0)
        let stoppedState = try XCTUnwrap(
            context.evaluateScript("window.wallpaperMediaIntegration.PLAYBACK_STOPPED")
        )
        XCTAssertEqual(
            (mediaEvents["playback"] as? [String: Any])?["state"] as? Int,
            Int(stoppedState.toInt32())
        )
        XCTAssertEqual(
            context.evaluateScript("window.wallpaperMediaIntegration.playback.STOPPED")?.toInt32(),
            context.evaluateScript("window.wallpaperMediaIntegration.PLAYBACK_STOPPED")?.toInt32()
        )
    }

    func testPropertyBridgeAppliesPropertiesToListenerRegisteredAfterInitialProbeBudget() throws {
        let script = WebWallpaperCompatibilityBridge.bootstrapScript(
            properties: ["caption": .text("Still delivered")]
        )
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var pendingTimeouts = [];
        var document = { readyState: 'complete' };
        var window = {
          clearInterval: function() {},
          setInterval: function() { return 1; },
          setTimeout: function(callback) { pendingTimeouts.push(callback); return pendingTimeouts.length; },
          addEventListener: function() {}
        };
        """#)
        context.evaluateScript(script)
        XCTAssertNil(context.exception, "Unexpected bridge exception: \(String(describing: context.exception))")
        context.evaluateScript("while (pendingTimeouts.length > 0) pendingTimeouts.shift()();")
        XCTAssertNil(context.exception)

        context.evaluateScript(#"""
        var lateProperties = null;
        var latePaused = null;
        window.wallpaperPropertyListener = {
          applyUserProperties: function(properties) { lateProperties = properties; },
          setPaused: function(paused) { latePaused = paused; }
        };
        while (pendingTimeouts.length > 0) pendingTimeouts.shift()();
        """#)
        XCTAssertNil(context.exception, "Unexpected late-listener exception: \(String(describing: context.exception))")
        XCTAssertEqual(
            context.evaluateScript("lateProperties.caption.value")?.toString(),
            "Still delivered"
        )
        XCTAssertEqual(context.evaluateScript("latePaused")?.toBool(), false)
    }

    func testFilePropertyOverrideUsesCopiedSandboxPath() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-file-property-\(UUID().uuidString)")
        let storage = project.appending(path: WebWallpaperUserFileStore.directoryName)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try #"{"general":{"properties":{"photo":{"type":"file","value":""}}}}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        try Data([1]).write(to: storage.appending(path: "photo"))
        let overrides = ["photo": "\(WebWallpaperUserFileStore.directoryName)/photo"]
        try JSONEncoder().encode(overrides).write(
            to: storage.appending(path: WebWallpaperUserFileStore.overridesFileName)
        )

        let descriptors = WebWallpaperCompatibilityBridge.fileProperties(projectRoot: project)
        let values = WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: project)

        XCTAssertEqual(descriptors, [.init(name: "photo", selectsDirectory: false)])
        XCTAssertEqual(values["photo"], .text(storage.appending(path: "photo").path))
    }

    func testDirectoryPropertiesExposeOnDemandAndFetchAllSandboxFiles() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-directory-properties-\(UUID().uuidString)")
        let storage = project.appending(path: WebWallpaperUserFileStore.directoryName)
        let gallery = storage.appending(path: "gallery")
        let random = storage.appending(path: "random")
        let hiddenGallery = gallery.appending(path: ".hidden")
        try FileManager.default.createDirectory(at: gallery, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: random, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenGallery, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try #"{"general":{"properties":{"gallery":{"type":"directory","mode":"fetchall","value":""},"random":{"type":"directory","mode":"ondemand","fileType":"video","value":""}}}}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        try Data([1]).write(to: gallery.appending(path: "z.png"))
        try Data([2]).write(to: gallery.appending(path: "a.png"))
        try Data([3]).write(to: gallery.appending(path: "clip.webm"))
        try Data([4]).write(to: gallery.appending(path: ".DS_Store"))
        try Data([5]).write(to: hiddenGallery.appending(path: "secret.png"))
        try Data([6]).write(to: random.appending(path: "one.jpg"))
        try Data([7]).write(to: random.appending(path: "one.webm"))
        try Data([8]).write(to: random.appending(path: ".hidden.webm"))
        try JSONEncoder().encode([
            "gallery": "\(WebWallpaperUserFileStore.directoryName)/gallery",
            "random": "\(WebWallpaperUserFileStore.directoryName)/random"
        ]).write(to: storage.appending(path: WebWallpaperUserFileStore.overridesFileName))

        let directories = WebWallpaperCompatibilityBridge.directoryProperties(projectRoot: project)
        let script = WebWallpaperCompatibilityBridge.bootstrapScript(
            properties: WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: project),
            directories: directories
        )

        XCTAssertEqual(directories["gallery"]?.mode, .fetchAll)
        XCTAssertEqual(
            directories["gallery"]?.files.map { URL(filePath: $0).lastPathComponent },
            ["a.png", "z.png"]
        )
        XCTAssertEqual(directories["random"]?.mode, .onDemand)
        XCTAssertEqual(
            directories["random"]?.files.map { URL(filePath: $0).lastPathComponent },
            ["one.webm"]
        )
        XCTAssertTrue(directories.values.flatMap(\.files).allSatisfy {
            $0.contains(WebWallpaperUserFileStore.directoryName)
        })
        XCTAssertTrue(script.contains("wallpaperRequestRandomFileForProperty"))
        XCTAssertTrue(script.contains("userDirectoryFilesAddedOrChanged"))
        XCTAssertTrue(script.contains("fetchAllProperties"))
        XCTAssertTrue(script.contains("currentPausedState"))
    }

    func testDirectoryBridgeDeliversCallbacksAndLateListenerPauseState() throws {
        let script = WebWallpaperCompatibilityBridge.bootstrapScript(
            properties: [
                "caption": .text("Hello"),
                "gallery": .text("/sandbox/gallery"),
                "random": .text("/sandbox/random")
            ],
            directories: [
                "gallery": .init(mode: .fetchAll, files: ["/sandbox/gallery/a.png"]),
                "random": .init(mode: .onDemand, files: ["/sandbox/random/b.jpg"])
            ]
        )
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var pendingTimeouts = [];
        var domContentLoaded = null;
        var document = { readyState: 'loading' };
        var window = {
          clearInterval: function() {},
          setInterval: function() { return 1; },
          setTimeout: function(callback) { pendingTimeouts.push(callback); return pendingTimeouts.length; },
          addEventListener: function(name, callback) {
            if (name === 'DOMContentLoaded') domContentLoaded = callback;
          }
        };
        """#)
        let exception = context.evaluateScript(script)
        XCTAssertNil(context.exception, "Unexpected bridge exception: \(String(describing: context.exception))")
        XCTAssertNotNil(exception)
        context.evaluateScript(#"""
        var observed = { user: null, general: null, fetchall: null, paused: null, random: null };
        var userDeliveryAttempts = 0;
        window.wallpaperPropertyListener = {
          applyUserProperties: function(value) {
            userDeliveryAttempts += 1;
            if (userDeliveryAttempts === 1) throw new Error('listener not ready');
            observed.user = value;
          },
          applyGeneralProperties: function(value) { observed.general = value; },
          userDirectoryFilesAddedOrChanged: function(name, files) {
            observed.fetchall = { name: name, files: files };
          },
          setPaused: function(value) { observed.paused = value; }
        };
        window.__backgroundEngineSetPaused(true);
        pendingTimeouts.shift()();
        var deliveredBeforeDOMReady = observed.user !== null;
        var pauseDeliveredBeforeDOMReady = observed.paused !== null;
        document.readyState = 'complete';
        domContentLoaded();
        while (pendingTimeouts.length > 0) pendingTimeouts.shift()();
        window.wallpaperRequestRandomFileForProperty('random', function(name, path) {
          observed.random = { name: name, path: path };
        });
        """#)
        XCTAssertNil(context.exception, "Unexpected callback exception: \(String(describing: context.exception))")
        let report = try XCTUnwrap(context.evaluateScript("JSON.stringify(observed)")?.toString())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any]
        )
        XCTAssertEqual(context.evaluateScript("deliveredBeforeDOMReady")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("pauseDeliveredBeforeDOMReady")?.toBool(), false)
        XCTAssertGreaterThanOrEqual(context.evaluateScript("userDeliveryAttempts")?.toInt32() ?? 0, 2)
        let user = try XCTUnwrap(object["user"] as? [String: Any])
        XCTAssertEqual((user["caption"] as? [String: Any])?["value"] as? String, "Hello")
        XCTAssertNotNil(user["random"])
        XCTAssertNil(user["gallery"])
        XCTAssertEqual(object["paused"] as? Bool, true)
        let fetchAll = try XCTUnwrap(object["fetchall"] as? [String: Any])
        XCTAssertEqual(fetchAll["name"] as? String, "gallery")
        XCTAssertEqual(fetchAll["files"] as? [String], ["/sandbox/gallery/a.png"])
        let random = try XCTUnwrap(object["random"] as? [String: Any])
        XCTAssertEqual(random["name"] as? String, "random")
        XCTAssertEqual(random["path"] as? String, "/sandbox/random/b.jpg")
    }

    func testWebWallpaperDoesNotLoadWhenRemoteBlockerCompilationFails() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/RestrictedWebWallpaperView.swift")

        XCTAssertTrue(source.contains("guard error == nil, let ruleList else"))
        XCTAssertFalse(source.contains("if let ruleList {"))
    }

    func testWebProjectResolverServesOnlyCanonicalProjectFiles() throws {
        let parent = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-resolver-\(UUID().uuidString)")
        let project = parent.appending(path: "project")
        let media = project.appending(path: "media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let local = media.appending(path: "loop #1.ogv")
        let quickTime = media.appending(path: "intro.mov")
        let aac = media.appending(path: "sound.aac")
        let wasm = media.appending(path: "renderer.wasm")
        let avi = media.appending(path: "legacy.avi")
        let flac = media.appending(path: "ambience.flac")
        let manifest = media.appending(path: "app.webmanifest")
        let outside = parent.appending(path: "outside.ogv")
        try Data([1, 2, 3]).write(to: local)
        try Data([1]).write(to: quickTime)
        try Data([2]).write(to: aac)
        try Data([3]).write(to: wasm)
        try Data([4]).write(to: avi)
        try Data([5]).write(to: flac)
        try Data([6]).write(to: manifest)
        try Data([4, 5, 6]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: media.appending(path: "linked.ogv"),
            withDestinationURL: outside
        )
        let resolver = try WebProjectResourceResolver(
            projectRoot: project,
            sessionHost: "session-test"
        )
        let virtual = try resolver.virtualURL(for: local)
        var components = try XCTUnwrap(URLComponents(url: virtual, resolvingAgainstBaseURL: false))
        components.query = "cache=1"
        components.fragment = "start"

        XCTAssertEqual(try resolver.resolve(try XCTUnwrap(components.url)).fileURL, local)
        XCTAssertEqual(try resolver.resolve(virtual).mimeType, "video/ogg")
        XCTAssertEqual(
            try resolver.resolve(try resolver.virtualURL(for: quickTime)).mimeType,
            "video/quicktime"
        )
        XCTAssertEqual(
            try resolver.resolve(try resolver.virtualURL(for: aac)).mimeType,
            "audio/aac"
        )
        XCTAssertEqual(
            try resolver.resolve(try resolver.virtualURL(for: wasm)).mimeType,
            "application/wasm"
        )
        XCTAssertEqual(
            try resolver.resolve(try resolver.virtualURL(for: avi)).mimeType,
            "video/x-msvideo"
        )
        XCTAssertEqual(
            try resolver.resolve(try resolver.virtualURL(for: flac)).mimeType,
            "audio/flac"
        )
        XCTAssertEqual(
            try resolver.resolve(try resolver.virtualURL(for: manifest)).mimeType,
            "application/manifest+json"
        )
        XCTAssertThrowsError(try resolver.virtualURL(for: outside))
        XCTAssertThrowsError(
            try resolver.resolve(
                URL(string: "background-engine-web://session-test/project/%2E%2E/outside.ogv")!
            )
        )
        XCTAssertThrowsError(
            try resolver.resolve(
                URL(string: "background-engine-web://session-test/project/media%2Floop.ogv")!
            )
        )
        XCTAssertThrowsError(
            try resolver.resolve(
                URL(string: "background-engine-web://other/project/media/loop.ogv")!
            )
        )
        let linkedVirtual = URL(
            string: "background-engine-web://session-test/project/media/linked.ogv"
        )!
        XCTAssertThrowsError(try resolver.resolve(linkedVirtual))
    }

    func testWebProjectResolverAtomicallyMapsPreparedMediaByExactSource() throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-prepared-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = project.appending(path: "loop.ogv")
        let prepared = cache.appending(path: "prepared.mp4")
        try Data([1]).write(to: source)
        try Data([2]).write(to: prepared)
        let original = try WebProjectResourceResolver(
            projectRoot: project,
            sessionHost: "session-test"
        )
        let virtual = try original.virtualURL(for: source)
        let mapped = try original.replacingPreparedResources([
            WebProjectPreparedResource(
                sourceURL: source,
                preparedURL: prepared,
                mimeType: "video/mp4"
            )
        ])

        XCTAssertEqual(try original.resolve(virtual).fileURL, source)
        XCTAssertEqual(try original.resolve(virtual).mimeType, "video/ogg")
        XCTAssertEqual(try mapped.resolve(virtual).fileURL, prepared)
        XCTAssertEqual(try mapped.resolve(virtual).mimeType, "video/mp4")
    }

    @MainActor
    func testVirtualURLBridgeRemapsOnlySandboxedFileAndDirectoryProperties() throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-property-urls-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        let gallery = project.appending(path: ".background-engine-web-properties/gallery")
        try FileManager.default.createDirectory(at: gallery, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = project.appending(path: ".background-engine-web-properties/photo.png")
        let galleryImage = gallery.appending(path: "frame.png")
        try Data([1]).write(to: image)
        try Data([2]).write(to: galleryImage)
        let handler = try WebProjectURLSchemeHandler(projectRoot: project)

        let mapped = WebWallpaperVirtualURLBridge.remap(
            properties: [
                "photo": .text(image.path),
                "gallery": .text(gallery.path),
                "caption": .text(image.path)
            ],
            fileProperties: [
                .init(name: "photo", selectsDirectory: false),
                .init(name: "gallery", selectsDirectory: true)
            ],
            directories: [
                "gallery": .init(mode: .fetchAll, files: [galleryImage.path])
            ],
            using: handler
        )

        guard case .text(let photo) = mapped.properties["photo"],
              case .text(let directory) = mapped.properties["gallery"] else {
            return XCTFail("Expected mapped file properties")
        }
        XCTAssertTrue(photo.hasPrefix("background-engine-web://"))
        XCTAssertTrue(directory.hasPrefix("background-engine-web://"))
        XCTAssertTrue(directory.hasSuffix("/"))
        XCTAssertEqual(mapped.properties["caption"], .text(image.path))
        XCTAssertTrue(
            try XCTUnwrap(mapped.directories["gallery"]?.files.first)
                .hasPrefix("background-engine-web://")
        )
    }

    func testWebProjectByteRangesSupportMediaSeekAndRejectInvalidRequests() throws {
        XCTAssertEqual(
            try WebProjectByteRange.resolve(header: nil, totalLength: 100),
            WebProjectByteRange(offset: 0, length: 100)
        )
        XCTAssertEqual(
            try WebProjectByteRange.resolve(header: "bytes=10-19", totalLength: 100),
            WebProjectByteRange(offset: 10, length: 10)
        )
        XCTAssertEqual(
            try WebProjectByteRange.resolve(header: "bytes=95-", totalLength: 100),
            WebProjectByteRange(offset: 95, length: 5)
        )
        XCTAssertEqual(
            try WebProjectByteRange.resolve(header: "bytes=-7", totalLength: 100),
            WebProjectByteRange(offset: 93, length: 7)
        )
        XCTAssertThrowsError(
            try WebProjectByteRange.resolve(header: "bytes=100-101", totalLength: 100)
        )
        XCTAssertThrowsError(
            try WebProjectByteRange.resolve(header: "bytes=0-1,4-5", totalLength: 100)
        )
        XCTAssertThrowsError(
            try WebProjectByteRange.resolve(header: "items=0-1", totalLength: 100)
        )
    }

    func testLoopbackServerUsesSecretOriginRangesPreparedFilesAndOfflineCSP() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-loopback-http-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = project.appending(path: "index.html")
        let source = project.appending(path: "loop.ogv")
        let symlink = project.appending(path: "escape.bin")
        let outside = root.appending(path: "outside.bin")
        let prepared = cache.appending(path: "loop.mp4")
        try "<title>loopback</title>".write(
            to: entrypoint,
            atomically: true,
            encoding: .utf8
        )
        try Data([0]).write(to: source)
        try Data([99]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let preparedBytes = Data((0..<64).map(UInt8.init))
        try preparedBytes.write(to: prepared)

        let server = try WebProjectLoopbackServer(
            projectRoot: project,
            networkAccessAllowed: false
        )
        defer { server.stop() }
        XCTAssertEqual(server.originURL.host, "127.0.0.1")
        XCTAssertEqual(server.originURL.port, Int(server.port))
        XCTAssertEqual(server.token.count, 64)
        XCTAssertTrue(server.token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        try server.installPreparedResources([
            WebProjectPreparedResource(
                sourceURL: source,
                preparedURL: prepared,
                mimeType: "video/mp4"
            )
        ])

        let entrypointURL = try server.virtualURL(for: entrypoint)
        let (html, htmlResponseValue) = try await URLSession.shared.data(from: entrypointURL)
        let htmlResponse = try XCTUnwrap(htmlResponseValue as? HTTPURLResponse)
        XCTAssertEqual(htmlResponse.statusCode, 200)
        XCTAssertEqual(String(data: html, encoding: .utf8), "<title>loopback</title>")
        let csp = try XCTUnwrap(htmlResponse.value(forHTTPHeaderField: "Content-Security-Policy"))
        XCTAssertTrue(csp.contains("connect-src 'self'"))
        XCTAssertTrue(csp.contains("media-src 'self' data: blob:"))

        var rangeRequest = URLRequest(url: try server.virtualURL(for: source))
        rangeRequest.setValue("bytes=10-19", forHTTPHeaderField: "Range")
        let (rangeData, rangeResponseValue) = try await URLSession.shared.data(for: rangeRequest)
        let rangeResponse = try XCTUnwrap(rangeResponseValue as? HTTPURLResponse)
        XCTAssertEqual(rangeResponse.statusCode, 206)
        XCTAssertEqual(rangeResponse.mimeType, "video/mp4")
        XCTAssertEqual(rangeResponse.value(forHTTPHeaderField: "Content-Range"), "bytes 10-19/64")
        XCTAssertEqual(
            rangeResponse.value(forHTTPHeaderField: "Content-Security-Policy"),
            csp,
            "Offline policy must accompany media/worker/SVG responses, not only the main HTML."
        )
        XCTAssertEqual(rangeData, preparedBytes.subdata(in: 10..<20))

        // Prepared cache maintenance may unlink the pathname while a display
        // is active; the listener must continue from its pinned descriptor.
        try FileManager.default.removeItem(at: prepared)
        let (pinnedData, pinnedResponseValue) = try await URLSession.shared.data(
            from: try server.virtualURL(for: source)
        )
        XCTAssertEqual((pinnedResponseValue as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(pinnedData, preparedBytes)

        var headRequest = URLRequest(url: entrypointURL)
        headRequest.httpMethod = "HEAD"
        let (headData, headResponseValue) = try await URLSession.shared.data(for: headRequest)
        XCTAssertTrue(headData.isEmpty)
        XCTAssertEqual((headResponseValue as? HTTPURLResponse)?.statusCode, 200)

        let wrongTokenURL = URL(
            string: entrypointURL.absoluteString.replacingOccurrences(
                of: "/\(server.token)/",
                with: "/\(String(repeating: "0", count: 64))/"
            )
        )!
        let (_, wrongTokenResponse) = try await URLSession.shared.data(from: wrongTokenURL)
        let wrongTokenHTTPResponse = try XCTUnwrap(wrongTokenResponse as? HTTPURLResponse)
        XCTAssertEqual(wrongTokenHTTPResponse.statusCode, 404)
        XCTAssertEqual(
            wrongTokenHTTPResponse.value(forHTTPHeaderField: "Content-Security-Policy"),
            csp
        )
        let escapedURL = URL(
            string: "http://127.0.0.1:\(server.port)/\(server.token)/project/%2e%2e/outside.bin"
        )!
        let (_, escapedResponse) = try await URLSession.shared.data(from: escapedURL)
        XCTAssertEqual((escapedResponse as? HTTPURLResponse)?.statusCode, 404)
        let linkedURL = URL(
            string: "http://127.0.0.1:\(server.port)/\(server.token)/project/escape.bin"
        )!
        let (_, linkedResponse) = try await URLSession.shared.data(from: linkedURL)
        XCTAssertEqual((linkedResponse as? HTTPURLResponse)?.statusCode, 404)

        let wrongHost = try sendRawLoopbackRequest(
            port: server.port,
            request: "GET /\(server.token)/project/index.html HTTP/1.1\r\nHost: localhost:\(server.port)\r\n\r\n"
        )
        XCTAssertTrue(wrongHost.hasPrefix("HTTP/1.1 400 Bad Request"))
        let post = try sendRawLoopbackRequest(
            port: server.port,
            request: "POST /\(server.token)/project/index.html HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\nContent-Length: 0\r\n\r\n"
        )
        XCTAssertTrue(post.hasPrefix("HTTP/1.1 405 Method Not Allowed"))
        XCTAssertTrue(post.contains("Content-Security-Policy: \(csp)\r\n"))
        var invalidRangeRequest = URLRequest(url: entrypointURL)
        invalidRangeRequest.setValue("bytes=999999-", forHTTPHeaderField: "Range")
        let (_, invalidRangeResponseValue) = try await URLSession.shared.data(
            for: invalidRangeRequest
        )
        let invalidRangeResponse = try XCTUnwrap(
            invalidRangeResponseValue as? HTTPURLResponse
        )
        XCTAssertEqual(invalidRangeResponse.statusCode, 416)
        XCTAssertEqual(
            invalidRangeResponse.value(forHTTPHeaderField: "Content-Security-Policy"),
            csp
        )
    }

    func testLoopbackUsesDependencyGraphMIMEForExtensionlessAndMislabeledResources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "background-engine-loopback-mime-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = project.appending(path: "main")
        let script = project.appending(path: "logic.asset")
        let module = project.appending(path: "module")
        let stylesheet = project.appending(path: "theme.asset")
        let frame = project.appending(path: "frame.bin")
        try #"<link rel="stylesheet" href="theme.asset"><script type="module" src="logic.asset"></script><iframe src="frame.bin"></iframe>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try "import './module';".write(to: script, atomically: true, encoding: .utf8)
        try "export const ready = true;".write(to: module, atomically: true, encoding: .utf8)
        try "body { background: black; }".write(
            to: stylesheet,
            atomically: true,
            encoding: .utf8
        )
        try "<title>frame</title>".write(to: frame, atomically: true, encoding: .utf8)

        let features = WebRuntimeFeatureAnalyzer().analyze(
            entrypoint: entrypoint,
            projectRoot: project
        )
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: features.localResourceMIMEOverrides.map {
                    ($0.sourceURL.lastPathComponent, $0.mimeType)
                }
            ),
            [
                "frame.bin": "text/html",
                "logic.asset": "text/javascript",
                "main": "text/html",
                "module": "text/javascript",
                "theme.asset": "text/css"
            ]
        )

        let server = try WebProjectLoopbackServer(
            projectRoot: project,
            networkAccessAllowed: false
        )
        defer { server.stop() }
        try server.installPreparedResources(
            [],
            mimeTypeOverrides: features.localResourceMIMEOverrides
        )
        for (source, expectedMIME) in [
            (entrypoint, "text/html"),
            (script, "text/javascript"),
            (module, "text/javascript"),
            (stylesheet, "text/css"),
            (frame, "text/html")
        ] {
            let (_, responseValue) = try await URLSession.shared.data(
                from: server.virtualURL(for: source)
            )
            let response = try XCTUnwrap(responseValue as? HTTPURLResponse)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.mimeType, expectedMIME, source.lastPathComponent)
            XCTAssertEqual(
                response.value(forHTTPHeaderField: "X-Content-Type-Options"),
                "nosniff"
            )
        }
    }

    func testPreparedAliasRouteCannotCollideWithAuthoredFilename() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "background-engine-loopback-alias-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = project.appending(path: "movie.ogv")
        let authoredCollision = project.appending(
            path: "movie.ogv\(WebProjectLoopbackServer.preparedVideoAliasSuffix)"
        )
        let unprepared = project.appending(path: "unprepared.ogv")
        let prepared = cache.appending(path: "movie.mp4")
        let authoredBytes = Data("authored-collision".utf8)
        let preparedBytes = Data("prepared-video".utf8)
        try Data("source".utf8).write(to: source)
        try authoredBytes.write(to: authoredCollision)
        try Data("unprepared".utf8).write(to: unprepared)
        try preparedBytes.write(to: prepared)
        let server = try WebProjectLoopbackServer(
            projectRoot: project,
            networkAccessAllowed: false
        )
        defer { server.stop() }
        try server.installPreparedResources([
            WebProjectPreparedResource(
                sourceURL: source,
                preparedURL: prepared,
                mimeType: "video/mp4"
            )
        ])

        let (authoredData, authoredResponse) = try await URLSession.shared.data(
            from: server.virtualURL(for: authoredCollision)
        )
        XCTAssertEqual((authoredResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(authoredData, authoredBytes)

        let preparedAlias = try XCTUnwrap(URL(string:
            "http://127.0.0.1:\(server.port)/\(server.token)/"
                + "\(WebProjectLoopbackServer.preparedRoutePathComponent)/video/project/"
                + "movie.ogv\(WebProjectLoopbackServer.preparedVideoAliasSuffix)"
        ))
        let (aliasData, aliasResponse) = try await URLSession.shared.data(from: preparedAlias)
        XCTAssertEqual((aliasResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(aliasData, preparedBytes)

        let unpreparedAlias = try XCTUnwrap(URL(string:
            "http://127.0.0.1:\(server.port)/\(server.token)/"
                + "\(WebProjectLoopbackServer.preparedRoutePathComponent)/video/project/"
                + "unprepared.ogv\(WebProjectLoopbackServer.preparedVideoAliasSuffix)"
        ))
        let (_, unpreparedResponse) = try await URLSession.shared.data(from: unpreparedAlias)
        XCTAssertEqual((unpreparedResponse as? HTTPURLResponse)?.statusCode, 404)
    }

    func testLoopbackHeaderDeadlineIsAbsoluteAcrossSlowDrip() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-loopback-slow-header-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let entrypoint = project.appending(path: "index.html")
        try "<title>healthy</title>".write(
            to: entrypoint,
            atomically: true,
            encoding: .utf8
        )
        let server = try WebProjectLoopbackServer(
            projectRoot: project,
            networkAccessAllowed: false,
            requestHeaderTimeout: 0.2,
            responseTimeout: 0.2
        )
        defer { server.stop() }

        let descriptor = try openLoopbackSocket(port: server.port)
        defer { close(descriptor) }
        let dripFinished = DispatchGroup()
        dripFinished.enter()
        let drip = Data("GET /\(server.token)/project/index.html HTTP/1.1\r\n".utf8)
        let started = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.global(qos: .userInitiated).async {
            defer { dripFinished.leave() }
            for byte in drip {
                var current = byte
                let result = Darwin.send(descriptor, &current, 1, 0)
                if result <= 0 { return }
                usleep(40_000)
            }
        }
        let response = try receiveRawLoopbackResponse(descriptor: descriptor)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        dripFinished.wait()

        XCTAssertLessThan(
            elapsed,
            0.75,
            "A client sending one byte at a time must not reset the absolute header deadline."
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 400 Bad Request"), response)
        let healthy = try sendRawLoopbackRequest(
            port: server.port,
            request: "GET /\(server.token)/project/index.html HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n\r\n"
        )
        XCTAssertTrue(healthy.hasPrefix("HTTP/1.1 200 OK"), healthy)
    }

    func testLoopbackResponseDeadlineReleasesWorkersBlockedBySlowReaders() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-loopback-slow-response-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let entrypoint = project.appending(path: "index.html")
        let large = project.appending(path: "large.bin")
        try "<title>healthy</title>".write(
            to: entrypoint,
            atomically: true,
            encoding: .utf8
        )
        try Data(repeating: 0x5A, count: 16 * 1_024 * 1_024).write(to: large)
        let server = try WebProjectLoopbackServer(
            projectRoot: project,
            networkAccessAllowed: false,
            requestHeaderTimeout: 0.5,
            responseTimeout: 0.2
        )
        defer { server.stop() }
        var slowReaders = [Int32]()
        defer { slowReaders.forEach { close($0) } }
        let request = "GET /\(server.token)/project/large.bin HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n\r\n"
        for _ in 0..<8 {
            let descriptor = try openLoopbackSocket(
                port: server.port,
                receiveBufferBytes: 1_024
            )
            try sendRawLoopbackBytes(descriptor: descriptor, data: Data(request.utf8))
            slowReaders.append(descriptor)
        }

        usleep(500_000)
        let started = DispatchTime.now().uptimeNanoseconds
        let healthy = try sendRawLoopbackRequest(
            port: server.port,
            request: "GET /\(server.token)/project/index.html HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n\r\n"
        )
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        XCTAssertLessThan(elapsed, 0.75)
        XCTAssertTrue(healthy.hasPrefix("HTTP/1.1 200 OK"), healthy)
    }

    func testLoopbackResponseIdleDeadlineRenewsWhileSlowReaderMakesProgress() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-loopback-progress-response-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let payload = Data(repeating: 0x5A, count: 1_024 * 1_024)
        try payload.write(to: project.appending(path: "large.bin"))
        // Keep a wide margin for loaded CI runners while still making the
        // deliberately throttled transfer outlive one complete idle window.
        let responseIdleTimeout: TimeInterval = 1
        let server = try WebProjectLoopbackServer(
            projectRoot: project,
            networkAccessAllowed: false,
            requestHeaderTimeout: 0.5,
            responseTimeout: responseIdleTimeout,
            responseSocketSendBufferBytes: 4 * 1_024
        )
        defer { server.stop() }

        let descriptor = try openLoopbackSocket(
            port: server.port,
            receiveBufferBytes: 4 * 1_024
        )
        defer { close(descriptor) }
        let request = "GET /\(server.token)/project/large.bin HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(server.port)\r\n"
            + "Range: bytes=0-\r\n\r\n"
        try sendRawLoopbackBytes(descriptor: descriptor, data: Data(request.utf8))
        _ = shutdown(descriptor, SHUT_WR)

        let started = DispatchTime.now().uptimeNanoseconds
        var response = Data()
        // The fixed 4 KiB read cap guarantees at least 256 progress events,
        // so the response must span multiple idle windows even on fast hosts.
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw CocoaError(.fileReadUnknown) }
            response.append(buffer, count: count)
            // Total transfer intentionally exceeds the configured timeout,
            // while every read frees capacity well within the idle window.
            usleep(10_000)
        }
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - started
        ) / 1_000_000_000

        let headerBoundary = try XCTUnwrap(
            response.range(of: Data("\r\n\r\n".utf8))
        )
        let header = String(decoding: response[..<headerBoundary.lowerBound], as: UTF8.self)
        let body = Data(response[headerBoundary.upperBound...])
        XCTAssertTrue(header.hasPrefix("HTTP/1.1 206 Partial Content"), header)
        XCTAssertEqual(body, payload)
        XCTAssertGreaterThan(
            elapsed,
            responseIdleTimeout,
            "The successful response must outlive one idle-timeout interval."
        )
    }

    @MainActor
    func testLoopbackAsyncStopIsBoundedAndDoesNotStopAnotherView() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-loopback-multiview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let entrypoint = project.appending(path: "index.html")
        try "<title>second-view</title>".write(
            to: entrypoint,
            atomically: true,
            encoding: .utf8
        )
        let first = try WebProjectLoopbackServer(
            projectRoot: project,
            networkAccessAllowed: false,
            requestHeaderTimeout: 30,
            responseTimeout: 30
        )
        let second = try WebProjectLoopbackServer(
            projectRoot: project,
            networkAccessAllowed: false
        )
        defer {
            first.stop()
            second.stop()
        }
        var stalled = [Int32]()
        defer { stalled.forEach { close($0) } }
        for _ in 0..<16 {
            let descriptor = try openLoopbackSocket(port: first.port)
            try sendRawLoopbackBytes(descriptor: descriptor, data: Data("G".utf8))
            stalled.append(descriptor)
        }
        usleep(50_000)

        let asyncStarted = DispatchTime.now().uptimeNanoseconds
        first.stopAsync()
        let asyncElapsed = Double(
            DispatchTime.now().uptimeNanoseconds - asyncStarted
        ) / 1_000_000_000
        XCTAssertLessThan(
            asyncElapsed,
            0.1,
            "Main-actor view teardown must only schedule the drain."
        )
        let drainStarted = DispatchTime.now().uptimeNanoseconds
        first.stop()
        let drainElapsed = Double(
            DispatchTime.now().uptimeNanoseconds - drainStarted
        ) / 1_000_000_000
        XCTAssertLessThan(drainElapsed, 1)

        let secondResponse = try sendRawLoopbackRequest(
            port: second.port,
            request: "GET /\(second.token)/project/index.html HTTP/1.1\r\nHost: 127.0.0.1:\(second.port)\r\n\r\n"
        )
        XCTAssertTrue(secondResponse.hasPrefix("HTTP/1.1 200 OK"), secondResponse)
        XCTAssertThrowsError(try openLoopbackSocket(port: first.port))
    }

    func testLoopbackServerOmitsOfflineCSPWhenWallpaperOptsIntoNetwork() async throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-loopback-network-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let entrypoint = project.appending(path: "index.html")
        try "<title>network</title>".write(to: entrypoint, atomically: true, encoding: .utf8)
        let server = try WebProjectLoopbackServer(
            projectRoot: project,
            networkAccessAllowed: true
        )
        defer { server.stop() }

        let (_, responseValue) = try await URLSession.shared.data(
            from: try server.virtualURL(for: entrypoint)
        )
        let response = try XCTUnwrap(responseValue as? HTTPURLResponse)
        XCTAssertNil(response.value(forHTTPHeaderField: "Content-Security-Policy"))
        let wrongToken = URL(
            string: "http://127.0.0.1:\(server.port)/invalid/project/index.html"
        )!
        let (_, errorResponseValue) = try await URLSession.shared.data(from: wrongToken)
        let errorResponse = try XCTUnwrap(errorResponseValue as? HTTPURLResponse)
        XCTAssertEqual(errorResponse.statusCode, 404)
        XCTAssertNil(errorResponse.value(forHTTPHeaderField: "Content-Security-Policy"))
    }

    @MainActor
    func testOptedInNetworkBoundaryRulesCompileWithoutPersistingSecretToken() async throws {
        let token = String(repeating: "a", count: 64)
        let encoded = try WebWallpaperLocalNetworkPolicy.encodedRules(
            trustedLoopbackPort: 49152
        )
        XCTAssertTrue(encoded.contains("ignore-previous-rules"))
        XCTAssertTrue(encoded.contains("49152"))
        XCTAssertFalse(encoded.contains(token))
        XCTAssertTrue(encoded.contains("wss?"))
        for blocked in ["localhost", "192", "169", "fe[89ab]"] {
            XCTAssertTrue(encoded.contains(blocked), blocked)
        }
        let decodedRules = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Any]]
        )
        let blockingPatterns = decodedRules.compactMap { rule -> String? in
            guard let action = rule["action"] as? [String: Any],
                  action["type"] as? String == "block",
                  let trigger = rule["trigger"] as? [String: Any] else {
                return nil
            }
            return trigger["url-filter"] as? String
        }
        for privateURL in [
            "http://@127.0.0.1:9/resource",
            "http://:@127.0.0.1:9/resource",
            "ws://@127.0.0.1:9/socket",
            "ws://:@127.0.0.1:9/socket",
            "http://2130706433:9/resource",
            "http://127.1:9/resource",
            "http://017700000001:9/resource",
            "http://0177.0.0.1:9/resource",
            "http://127.00.0.1:9/resource",
            "http://0x7f000001:9/resource",
            "ws://127.0x0.0.1:9/socket",
            "http://localhost.:9/resource",
            "http://[::]:9/resource",
            "http://[::ffff:127.0.0.1]:9/resource",
            "ws://[0:0:0:0:0:0:0:1]:9/socket"
        ] {
            let range = NSRange(privateURL.startIndex..<privateURL.endIndex, in: privateURL)
            XCTAssertTrue(
                try blockingPatterns.contains { pattern in
                    try NSRegularExpression(pattern: pattern).firstMatch(
                        in: privateURL,
                        range: range
                    ) != nil
                },
                "Legacy host spelling must not bypass the private-network block: \(privateURL)"
            )
        }
        for publicLiteralURL in [
            "https://8.8.8.8/resource",
            "wss://1.1.1.1/socket"
        ] {
            let range = NSRange(
                publicLiteralURL.startIndex..<publicLiteralURL.endIndex,
                in: publicLiteralURL
            )
            XCTAssertFalse(
                try blockingPatterns.contains { pattern in
                    try NSRegularExpression(pattern: pattern).firstMatch(
                        in: publicLiteralURL,
                        range: range
                    ) != nil
                },
                "Canonical public IPv4 literals must remain available: \(publicLiteralURL)"
            )
        }
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let identifier = "com.lamppkk.backgroundengine.Tests.LocalBoundary.\(UUID().uuidString)"
        let result: (WKContentRuleList?, (any Error)?) = await withCheckedContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encoded
            ) { ruleList, error in
                continuation.resume(returning: (ruleList, error))
            }
        }
        XCTAssertNotNil(result.0)
        XCTAssertNil(result.1)
        try await store.removeContentRuleList(forIdentifier: identifier)
        XCTAssertThrowsError(
            try WebWallpaperLocalNetworkPolicy.encodedRules(trustedLoopbackPort: 0)
        )
        let remoteRules = try WebWallpaperLocalNetworkPolicy.encodedRules(
            trustedLoopbackPort: nil
        )
        XCTAssertFalse(remoteRules.contains("ignore-previous-rules"))
        XCTAssertFalse(remoteRules.contains(token))
        XCTAssertTrue(blockingPatterns.contains { $0.contains("([^/@]*@)?") })
        XCTAssertTrue(blockingPatterns.contains { $0.hasPrefix("^wss?://([^/@]*@)?") })

        let offline = try WebWallpaperLocalNetworkPolicy.encodedOfflineRules(
            trustedLoopbackPort: 49152
        )
        let offlineDecoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(offline.utf8)) as? [[String: Any]]
        )
        let offlinePatterns = offlineDecoded.compactMap {
            ($0["trigger"] as? [String: Any])?["url-filter"] as? String
        }
        XCTAssertTrue(offlinePatterns.contains("^https?://.*"))
        XCTAssertTrue(offlinePatterns.contains("^wss?://.*"))
        XCTAssertTrue(offline.contains("ignore-previous-rules"))
        XCTAssertTrue(offline.contains("49152"))
        XCTAssertFalse(offline.contains(token))
        XCTAssertThrowsError(
            try WebWallpaperLocalNetworkPolicy.encodedOfflineRules(
                trustedLoopbackPort: 0
            )
        )
        let offlineIdentifier = "com.lamppkk.backgroundengine.Tests.OfflineBoundary.\(UUID().uuidString)"
        let offlineResult: (WKContentRuleList?, (any Error)?) = await withCheckedContinuation {
            continuation in
            store.compileContentRuleList(
                forIdentifier: offlineIdentifier,
                encodedContentRuleList: offline
            ) { ruleList, error in
                continuation.resume(returning: (ruleList, error))
            }
        }
        XCTAssertNotNil(offlineResult.0)
        XCTAssertNil(offlineResult.1)
        try await store.removeContentRuleList(forIdentifier: offlineIdentifier)
    }

    func testMediaSourceBridgeRequestsPreparedLocalLegacySources() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        function Element(tagName, attributes) {
          this.tagName = tagName;
          this.attributes = attributes || {};
        }
        Element.prototype.getAttribute = function(name) {
          return Object.prototype.hasOwnProperty.call(this.attributes, name)
            ? this.attributes[name]
            : null;
        };
        Element.prototype.removeAttribute = function(name) { delete this.attributes[name]; };
        Element.prototype.setAttribute = function(name, value) { this.attributes[name] = value; };
        Element.prototype.querySelectorAll = function() { return this.sources || []; };
        function HTMLMediaElement(tagName, attributes) {
          Element.call(this, tagName, attributes);
          this.sources = [];
        }
        HTMLMediaElement.prototype = Object.create(Element.prototype);
        HTMLMediaElement.prototype.constructor = HTMLMediaElement;
        HTMLMediaElement.prototype.querySelectorAll = function() { return this.sources; };
        HTMLMediaElement.prototype.load = function() { this.didLoad = true; };
        HTMLMediaElement.prototype.play = function() { this.didPlay = true; return 'played'; };
        Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
          configurable: true,
          enumerable: true,
          get: function() { return !!this._muted; },
          set: function(value) { this._muted = Boolean(value); }
        });
        Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
          configurable: true,
          enumerable: true,
          get: function() { return this._volume === undefined ? 1 : this._volume; },
          set: function(value) { this._volume = Number(value); }
        });
        Object.defineProperty(HTMLMediaElement.prototype, 'src', {
          configurable: true,
          enumerable: true,
          get: function() { return this.attributes.src || ''; },
          set: function(value) { this.attributes.src = String(value); }
        });
        function HTMLSourceElement(attributes) {
          Element.call(this, 'SOURCE', attributes);
        }
        HTMLSourceElement.prototype = Object.create(Element.prototype);
        HTMLSourceElement.prototype.constructor = HTMLSourceElement;
        Object.defineProperty(HTMLSourceElement.prototype, 'src', {
          configurable: true,
          enumerable: true,
          get: function() { return this.attributes.src || ''; },
          set: function(value) { this.attributes.src = String(value); }
        });
        function Document() {}
        Document.prototype.querySelectorAll = function() { return this.sources || []; };
        function DocumentFragment() {}
        DocumentFragment.prototype.querySelectorAll = function() { return []; };
        function TestURL(source, base) {
          var value = String(source);
          if (value.indexOf('://') < 0) {
            var baseValue = String(base || '');
            value = baseValue.substring(0, baseValue.lastIndexOf('/') + 1) + value;
          }
          var match = value.match(/^([a-z-]+:)\/\/([^/]+)(\/[^?#]*)?/);
          this.protocol = match ? match[1] : '';
          this.host = match ? match[2] : '';
          this.hostname = this.host.split(':')[0];
          this.origin = this.protocol + '//' + this.host;
          this.pathname = match && match[3] ? match[3] : '/';
        }
        Object.defineProperty(TestURL.prototype, 'href', {
          get: function() { return this.origin + this.pathname; }
        });
        var mutationCallback = null;
        function MutationObserver(callback) { mutationCallback = callback; }
        MutationObserver.prototype.observe = function() {};
        var localSource = new Element('SOURCE', { type: 'video/ogg', src: 'loop.ogv' });
        var unpreparedLocalSource = new Element('SOURCE', {
          type: 'video/mp4',
          src: 'direct.mp4'
        });
        var nestedSource = new Element('SOURCE', {
          type: 'video/ogg',
          src: 'folder.__background_engine_prepared.mp4/loop.ogv'
        });
        var encodedUnreservedSource = new Element('SOURCE', {
          type: 'video/x-msvideo',
          src: 'clip%2Eavi'
        });
        var encodedSeparatorSource = new Element('SOURCE', {
          type: 'video/x-msvideo',
          src: 'folder%2Fclip.avi'
        });
        var remoteSource = new Element('SOURCE', {
          type: 'video/ogg',
          src: 'https://example.test/loop.ogv'
        });
        var wrongPortSource = new Element('SOURCE', {
          type: 'video/ogg',
          src: 'http://127.0.0.1:54322/session-test/project/loop.ogv'
        });
        var wrongTokenSource = new Element('SOURCE', {
          type: 'video/ogg',
          src: 'http://127.0.0.1:54321/session-other/project/loop.ogv'
        });
        var document = new Document();
        document.baseURI = 'http://127.0.0.1:54321/session-test/project/index.html';
        document.sources = [
          localSource, unpreparedLocalSource, nestedSource,
          encodedUnreservedSource, encodedSeparatorSource, remoteSource,
          wrongPortSource, wrongTokenSource
        ];
        var window = {
          Document: Document,
          DocumentFragment: DocumentFragment,
          Element: Element,
          HTMLMediaElement: HTMLMediaElement,
          HTMLSourceElement: HTMLSourceElement,
          MutationObserver: MutationObserver,
          URL: TestURL
        };
        """#)

        context.evaluateScript(
            WebWallpaperMediaSourceBridge.bootstrapScript(
                preparedKindsByPath: [
                    "/session-test/project/loop.ogv": "video",
                    "/session-test/project/folder.__background_engine_prepared.mp4/loop.ogv": "video",
                    "/session-test/project/clip.avi": "video",
                    "/session-test/project/folder/clip.avi": "video",
                    "/session-test/project/sound.ogg": "audio"
                ]
            )
        )
        // Production registers the media bridge before the audio bridge. The
        // latter intentionally seals `play`, so this order must preserve the
        // synchronous detached-media normalization wrapper underneath it.
        context.evaluateScript(
            WebWallpaperAudioBridge.bootstrapScript(controlToken: "media-audio-order-test")
        )

        XCTAssertNil(context.exception)
        XCTAssertTrue(context.evaluateScript("localSource.attributes.type === undefined")?.toBool() == true)
        XCTAssertEqual(
            context.evaluateScript("localSource.attributes.src")?.toString(),
            "http://127.0.0.1:54321/session-test/__background_engine_prepared/video/project/loop.ogv.__background_engine_prepared.mp4"
        )
        XCTAssertEqual(
            context.evaluateScript("nestedSource.attributes.src")?.toString(),
            "http://127.0.0.1:54321/session-test/__background_engine_prepared/video/project/folder.__background_engine_prepared.mp4/loop.ogv.__background_engine_prepared.mp4"
        )
        XCTAssertTrue(
            context.evaluateScript("encodedUnreservedSource.attributes.type === undefined")?
                .toBool() == true
        )
        XCTAssertEqual(
            context.evaluateScript("encodedUnreservedSource.attributes.src")?.toString(),
            "http://127.0.0.1:54321/session-test/__background_engine_prepared/video/project/clip%2Eavi.__background_engine_prepared.mp4"
        )
        XCTAssertEqual(
            context.evaluateScript("encodedSeparatorSource.attributes.type")?.toString(),
            "video/x-msvideo"
        )
        XCTAssertEqual(
            context.evaluateScript("encodedSeparatorSource.attributes.src")?.toString(),
            "folder%2Fclip.avi"
        )
        context.evaluateScript(#"""
        var detachedVideo = new HTMLMediaElement('VIDEO', {});
        detachedVideo.src = 'clip%2Eavi';
        detachedVideo.setAttribute('type', 'video/x-msvideo');
        var detachedAudio = new HTMLMediaElement('AUDIO', {});
        detachedAudio.setAttribute('src', 'sound.ogg');
        var detachedChildSource = new HTMLSourceElement({
          type: 'video/x-msvideo',
          src: 'clip%2Eavi'
        });
        var detachedParentVideo = new HTMLMediaElement('VIDEO', {});
        detachedParentVideo.sources = [detachedChildSource];
        var detachedPlayResult = detachedParentVideo.play();
        """#)
        XCTAssertNil(context.exception)
        XCTAssertTrue(
            context.evaluateScript("detachedVideo.attributes.type === undefined")?.toBool()
                == true
        )
        XCTAssertEqual(
            context.evaluateScript("detachedVideo.attributes.src")?.toString(),
            "http://127.0.0.1:54321/session-test/__background_engine_prepared/video/project/clip%2Eavi.__background_engine_prepared.mp4"
        )
        XCTAssertEqual(
            context.evaluateScript("detachedAudio.attributes.src")?.toString(),
            "http://127.0.0.1:54321/session-test/__background_engine_prepared/audio/project/sound.ogg.__background_engine_prepared.m4a"
        )
        XCTAssertTrue(
            context.evaluateScript("detachedChildSource.attributes.type === undefined")?
                .toBool() == true
        )
        XCTAssertEqual(
            context.evaluateScript("detachedChildSource.attributes.src")?.toString(),
            "http://127.0.0.1:54321/session-test/__background_engine_prepared/video/project/clip%2Eavi.__background_engine_prepared.mp4"
        )
        XCTAssertEqual(context.evaluateScript("detachedPlayResult")?.toString(), "played")
        XCTAssertTrue(
            context.evaluateScript(
                "Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'play').configurable === false"
            )?.toBool() == true
        )
        XCTAssertEqual(
            context.evaluateScript("unpreparedLocalSource.attributes.type")?.toString(),
            "video/mp4"
        )
        XCTAssertEqual(context.evaluateScript("remoteSource.attributes.type")?.toString(), "video/ogg")
        XCTAssertEqual(context.evaluateScript("wrongPortSource.attributes.type")?.toString(), "video/ogg")
        XCTAssertEqual(context.evaluateScript("wrongTokenSource.attributes.type")?.toString(), "video/ogg")
        context.evaluateScript(#"""
        var dynamicSource = new Element('SOURCE', { type: 'audio/ogg', src: 'sound.ogg' });
        mutationCallback([{ addedNodes: [dynamicSource] }]);
        """#)
        XCTAssertTrue(context.evaluateScript("dynamicSource.attributes.type === undefined")?.toBool() == true)
        XCTAssertEqual(
            context.evaluateScript("dynamicSource.attributes.src")?.toString(),
            "http://127.0.0.1:54321/session-test/__background_engine_prepared/audio/project/sound.ogg.__background_engine_prepared.m4a"
        )
        XCTAssertNil(context.exception)
    }

    @MainActor
    func testWebProjectSchemeHandlerStreamsRequestedRangeWithPreparedMIME() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-stream-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = project.appending(path: "loop.ogv")
        let prepared = cache.appending(path: "loop.mp4")
        try Data([0]).write(to: source)
        let preparedBytes = Data((0..<64).map(UInt8.init))
        try preparedBytes.write(to: prepared)
        let handler = try WebProjectURLSchemeHandler(projectRoot: project)
        try handler.installPreparedResources([
            WebProjectPreparedResource(
                sourceURL: source,
                preparedURL: prepared,
                mimeType: "video/mp4"
            )
        ])
        var request = URLRequest(url: try handler.virtualURL(for: source))
        request.setValue("bytes=10-19", forHTTPHeaderField: "Range")
        let finished = expectation(description: "scheme task finished")
        let task = CapturingWebProjectSchemeTask(request: request, finished: finished)

        handler.webView(WKWebView(), start: task)
        await fulfillment(of: [finished], timeout: 2)

        let response = try XCTUnwrap(task.response as? HTTPURLResponse)
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.mimeType, "video/mp4")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 10-19/64")
        XCTAssertEqual(task.receivedData, preparedBytes.subdata(in: 10..<20))
        XCTAssertNil(task.error)
    }

    @MainActor
    func testWebProjectSchemeHandlerStopSuppressesCallbacksAfterActiveResponse() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-active-stop-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = project.appending(path: "payload.bin")
        let payload = Data(repeating: 0xA5, count: 512 * 1_024)
        try payload.write(to: source)

        let handler = try WebProjectURLSchemeHandler(projectRoot: project)
        let webView = WKWebView()
        defer { handler.cancelAll() }
        let responseReceived = expectation(description: "active transfer received response")
        let stoppedTask = RecordingWebProjectSchemeTask(
            request: URLRequest(url: try handler.virtualURL(for: source)),
            responseReceived: responseReceived,
            onResponse: { task in
                handler.webView(webView, stop: task)
            }
        )

        handler.webView(webView, start: stoppedTask)
        await fulfillment(of: [responseReceived], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            stoppedTask.callbacks,
            ["response"],
            "Stopping inside the serialized response callback must suppress all later callbacks."
        )
        XCTAssertNil(stoppedTask.error)

        let replacementFinished = expectation(description: "replacement transfer finished")
        let replacement = CapturingWebProjectSchemeTask(
            request: URLRequest(url: try handler.virtualURL(for: source)),
            finished: replacementFinished
        )
        handler.webView(webView, start: replacement)
        await fulfillment(of: [replacementFinished], timeout: 2)

        XCTAssertEqual(replacement.receivedData, payload)
        XCTAssertNil(replacement.error, "Stopping the active task must immediately release its slot.")
    }

    @MainActor
    func testWebProjectSchemeHandlerStoppingQueuedTransfersReleasesCapacityAndDescriptors() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-queued-stop-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = project.appending(path: "payload.bin")
        let payload = Data(repeating: 0x5A, count: 512 * 1_024)
        try payload.write(to: source)

        let handler = try WebProjectURLSchemeHandler(projectRoot: project)
        let webView = WKWebView()
        defer { handler.cancelAll() }
        let baselineDescriptorCount = try openDescriptorCount(referringTo: project)
        let request = URLRequest(url: try handler.virtualURL(for: source))
        let stoppedTasks = (0..<64).map { _ in
            RecordingWebProjectSchemeTask(request: request)
        }

        // This method remains on the main actor while all 64 transfers are
        // enqueued. Workers that start block at their first serialized
        // callback, leaving the remainder genuinely queued.
        for task in stoppedTasks {
            handler.webView(webView, start: task)
        }
        XCTAssertGreaterThan(
            try openDescriptorCount(referringTo: project),
            baselineDescriptorCount,
            "Queued transfers should hold duplicated project descriptors before cancellation."
        )
        for task in stoppedTasks {
            handler.webView(webView, stop: task)
        }

        let replacementFinished = expectation(description: "replacement after full queue finished")
        let replacement = CapturingWebProjectSchemeTask(
            request: request,
            finished: replacementFinished
        )
        handler.webView(webView, start: replacement)
        await fulfillment(of: [replacementFinished], timeout: 3)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(
            stoppedTasks.allSatisfy(\.callbacks.isEmpty),
            "A stopped queued or active transfer must never call its WKURLSchemeTask."
        )
        XCTAssertEqual(replacement.receivedData, payload)
        XCTAssertNil(
            replacement.error,
            "Removing stopped transfers must release the 64-request admission capacity."
        )

        handler.cancelAll()
        var restoredDescriptorCount = try openDescriptorCount(referringTo: project)
        for _ in 0..<100 where restoredDescriptorCount != baselineDescriptorCount {
            try await Task.sleep(for: .milliseconds(10))
            restoredDescriptorCount = try openDescriptorCount(referringTo: project)
        }
        XCTAssertEqual(
            restoredDescriptorCount,
            baselineDescriptorCount,
            "Queued cancellation must close every duplicated project descriptor."
        )
    }

    @MainActor
    func testPreparedMediaRemainsReadableFromPinnedDescriptorAfterCacheUnlink() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-pinned-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = project.appending(path: "loop.ogv")
        let prepared = cache.appending(path: "loop.mp4")
        let expected = Data([9, 8, 7, 6])
        try Data([0]).write(to: source)
        try expected.write(to: prepared)

        let handler = try WebProjectURLSchemeHandler(projectRoot: project)
        try handler.installPreparedResources([
            WebProjectPreparedResource(
                sourceURL: source,
                preparedURL: prepared,
                mimeType: "video/mp4"
            )
        ])
        try FileManager.default.removeItem(at: prepared)
        let finished = expectation(description: "pinned scheme task finished")
        let task = CapturingWebProjectSchemeTask(
            request: URLRequest(url: try handler.virtualURL(for: source)),
            finished: finished
        )

        handler.webView(WKWebView(), start: task)
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertEqual(task.receivedData, expected)
        XCTAssertEqual((task.response as? HTTPURLResponse)?.mimeType, "video/mp4")
        XCTAssertNil(task.error)
        handler.cancelAll()
    }

    @MainActor
    func testRealWKWebViewLoadsPreparedMediaThroughOfflineContentBoundary() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-webkit-smoke-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        let blockedProject = root.appending(path: "blocked-project")
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blockedProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = project.appending(path: "index.html")
        let script = project.appending(path: "runtime.js")
        let source = project.appending(path: "loop.ogv")
        let prepared = cache.appending(path: "loop.mp4")
        let blockedEntrypoint = blockedProject.appending(path: "blocked.html")
        try "blocked".write(to: blockedEntrypoint, atomically: true, encoding: .utf8)
        let blockedServer = try WebProjectLoopbackServer(
            projectRoot: blockedProject,
            networkAccessAllowed: true
        )
        defer { blockedServer.stop() }
        let blockedURL = try blockedServer.virtualURL(for: blockedEntrypoint)
        try #"""
        <!doctype html>
        <title>pending</title>
        <script src="runtime.js"></script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)
        let runtimeSource = #"""
        fetch('loop.ogv').then(async response => {
          const bytes = new Uint8Array(await response.arrayBuffer());
          const valid = response.status === 200
            && response.headers.get('Content-Type') === 'video/mp4'
            && bytes.length === 4
            && bytes[0] === 7;
          if (!valid) throw new Error('prepared-invalid');
          try {
            await fetch('__BLOCKED_URL__', { mode: 'no-cors' });
            document.title = 'external-leaked';
          } catch (_) {
            document.title = 'prepared-ready';
          }
        }).catch(() => { document.title = 'prepared-failed'; });
        """#
        try runtimeSource.replacingOccurrences(
            of: "__BLOCKED_URL__",
            with: blockedURL.absoluteString
        ).write(to: script, atomically: true, encoding: .utf8)
        try Data([0]).write(to: source)
        try Data([7, 8, 9, 10]).write(to: prepared)

        let server = try WebProjectLoopbackServer(
            projectRoot: project,
            // Deliberately omit server CSP to model a same-origin service
            // worker response. The out-of-band content rule must still allow
            // this exact project origin and reject the second loopback server.
            networkAccessAllowed: true
        )
        try server.installPreparedResources([
            WebProjectPreparedResource(
                sourceURL: source,
                preparedURL: prepared,
                mimeType: "video/mp4"
            )
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let offlineBoundary = try await installOfflineBoundary(
            on: configuration,
            trustedLoopbackPort: server.port
        )
        defer {
            offlineBoundary.store.removeContentRuleList(
                forIdentifier: offlineBoundary.identifier
            ) { _ in }
        }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: configuration)
        webView.load(URLRequest(url: try server.virtualURL(for: entrypoint)))
        defer {
            webView.stopLoading()
            server.stop()
        }

        var title = ""
        for _ in 0..<100 {
            if let value = try? await webView.evaluateJavaScript("document.title"),
               let current = value as? String {
                title = current
                if current != "pending" && !current.isEmpty { break }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(title, "prepared-ready")
    }

    #if XCODE_APP_HOST_TESTS
    @MainActor
    func testRealWKWebViewPlaysSeeksAndLoopsPreparedH264WithoutLegacyTypeHint() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-webkit-media-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        guard let ffmpeg = configuredFFmpegPathForIntegrationTests() else {
            throw XCTSkip("Configured FFmpeg is required for the real WebKit media smoke test.")
        }
        let entrypoint = project.appending(path: "index.html")
        let runtime = project.appending(path: "runtime.js")
        let source = project.appending(path: "loop.ogv")
        let rawFrames = root.appending(path: "frames.rgb")
        let prepared = cache.appending(path: "loop.mp4")
        try Data([0]).write(to: source)
        try makeSmallH264Fixture(
            at: prepared,
            rawFrames: rawFrames,
            ffmpeg: ffmpeg
        )
        try #"""
        <!doctype html>
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'self'; script-src 'self'; media-src 'self'">
        <title>pending</title>
        <script defer src="runtime.js"></script>
        <video id="media" muted playsinline preload="none" loop>
          <source id="source" type="video/ogg" src="loop.ogv">
        </video>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)
        try #"""
        (() => {
          const media = document.getElementById('media');
          const source = document.getElementById('source');
          const state = window.playbackSmoke = {
            typeRemoved: false,
            loadedMetadata: false,
            canPlay: false,
            seeked: false,
            loopEnabled: false,
            looped: false,
            sawNearEnd: false,
            duration: 0,
            currentTime: 0,
            stage: 'waiting',
            error: null,
            reported: false
          };
          const report = () => {
            if (state.reported) return;
            state.reported = true;
            window.webkit.messageHandlers.playbackSmoke.postMessage(state);
          };
          const fail = message => {
            state.error = String(message);
            document.title = 'media-failed';
            report();
          };
          const beginSeek = () => {
            if (!state.loadedMetadata || !state.canPlay || state.stage !== 'waiting') return;
            state.typeRemoved = source.getAttribute('type') === null;
            state.duration = media.duration;
            state.loopEnabled = media.loop === true;
            if (!state.typeRemoved) return fail('legacy type hint remained');
            if (!Number.isFinite(media.duration) || media.duration <= 0) {
              return fail('invalid duration');
            }
            state.stage = 'initial-seek';
            media.currentTime = Math.min(0.5, media.duration / 2);
          };
          media.addEventListener('loadedmetadata', () => {
            state.loadedMetadata = true;
            beginSeek();
          });
          media.addEventListener('canplay', () => {
            state.canPlay = true;
            beginSeek();
          });
          media.addEventListener('seeked', () => {
            state.currentTime = media.currentTime;
            if (state.stage === 'initial-seek') {
              state.seeked = media.currentTime > 0.05;
              if (!state.seeked) return fail('initial seek did not advance');
              state.stage = 'near-end-seek';
              media.currentTime = Math.max(0, media.duration - 0.25);
              return;
            }
            if (state.stage === 'near-end-seek') {
              state.sawNearEnd = media.currentTime > media.duration * 0.5;
              state.stage = 'playing-for-loop';
              media.play().catch(error => fail(error && error.message || error));
            }
          });
          media.addEventListener('timeupdate', () => {
            state.currentTime = media.currentTime;
            if (state.stage !== 'playing-for-loop') return;
            if (media.currentTime > media.duration * 0.5) state.sawNearEnd = true;
            if (state.sawNearEnd && media.currentTime < media.duration * 0.35) {
              state.looped = true;
              state.stage = 'ready';
              media.pause();
              document.title = 'media-ready';
              report();
            }
          });
          media.addEventListener('error', () => {
            fail('media error ' + (media.error ? media.error.code : 'unknown'));
          });
          setTimeout(() => {
            state.typeRemoved = source.getAttribute('type') === null;
            media.preload = 'auto';
            media.load();
          }, 0);
        })();
        """#.write(to: runtime, atomically: true, encoding: .utf8)

        let server = try WebProjectLoopbackServer(
            projectRoot: project,
            networkAccessAllowed: false
        )
        try server.installPreparedResources([
            WebProjectPreparedResource(
                sourceURL: source,
                preparedURL: prepared,
                mimeType: "video/mp4"
            )
        ])
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let playbackReported = expectation(description: "WebKit playback reported")
        let messageHandler = WebKitPlaybackSmokeMessageHandler(expectation: playbackReported)
        configuration.userContentController.add(messageHandler, name: "playbackSmoke")
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WebWallpaperMediaSourceBridge.bootstrapScript(
                    preparedKindsByPath: [
                        try server.virtualURL(for: source).path: "video"
                    ]
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        let offlineBoundary = try await installOfflineBoundary(
            on: configuration,
            trustedLoopbackPort: server.port
        )
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 180),
            configuration: configuration
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // AppKit's close-time self-release must not race Swift ARC when the
        // app-hosted XCTest scope later releases this strong local reference.
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        webView.load(URLRequest(url: try server.virtualURL(for: entrypoint)))
        defer {
            // Remove the callback first, then detach WebKit from AppKit. This
            // prevents a late WebContent callback from racing the app-hosted
            // XCTest memory check while the window hierarchy is released.
            autoreleasepool {
                configuration.userContentController.removeScriptMessageHandler(
                    forName: "playbackSmoke"
                )
                webView.stopLoading()
                window.contentView = nil
                webView.removeFromSuperview()
                window.orderOut(nil)
                window.close()
            }
            offlineBoundary.store.removeContentRuleList(
                forIdentifier: offlineBoundary.identifier
            ) { _ in }
            server.stop()
        }

        await fulfillment(of: [playbackReported], timeout: 10)
        guard let report = messageHandler.report else {
            let snapshot = try? await webView.evaluateJavaScript(#"""
            JSON.stringify({
              title: document.title,
              state: window.playbackSmoke || null,
              sourceType: document.getElementById('source')?.getAttribute('type'),
              sourceAttribute: document.getElementById('source')?.getAttribute('src'),
              sourceURL: document.getElementById('source')?.src,
              mediaURL: document.getElementById('media')?.src,
              currentSource: document.getElementById('media')?.currentSrc,
              canPlayMP4: document.getElementById('media')?.canPlayType('video/mp4'),
              readyState: document.getElementById('media')?.readyState,
              networkState: document.getElementById('media')?.networkState,
              mediaError: document.getElementById('media')?.error?.code || null
            })
            """#)
            XCTFail(
                "WebKit posted no playback smoke report. Snapshot: \(snapshot ?? "unavailable")"
            )
            return
        }
        let diagnostic = "WebKit playback report: \(report)"
        XCTAssertNil(report["error"] as? String, diagnostic)
        XCTAssertEqual(report["typeRemoved"] as? Bool, true, diagnostic)
        XCTAssertEqual(report["loadedMetadata"] as? Bool, true, diagnostic)
        XCTAssertEqual(report["canPlay"] as? Bool, true, diagnostic)
        XCTAssertEqual(report["seeked"] as? Bool, true, diagnostic)
        XCTAssertEqual(report["loopEnabled"] as? Bool, true, diagnostic)
        XCTAssertEqual(report["looped"] as? Bool, true, diagnostic)
    }
    #endif

    @MainActor
    func testRestrictedViewFailsClosedWhenProjectRootIsASymlink() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-symlink-root-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        let linkedProject = root.appending(path: "linked-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = project.appending(path: "index.html")
        try "<title>must-not-load</title>".write(
            to: entrypoint,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: linkedProject,
            withDestinationURL: project
        )
        let linkedEntrypoint = linkedProject.appending(path: "index.html")

        let view = RestrictedWebWallpaperView(
            url: linkedEntrypoint,
            readAccessURL: linkedProject,
            frame: CGRect(x: 0, y: 0, width: 320, height: 180)
        )
        defer { view.prepareForClose() }
        try await Task.sleep(for: .milliseconds(50))

        let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        XCTAssertNil(webView.url)
        XCTAssertTrue(
            view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
                .contains { $0.contains("failed secure file validation") }
        )
    }

    @MainActor
    func testRestrictedViewRejectsLegacyHTTPRemoteMetadataInsteadOfLoadingPlaceholder() throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-legacy-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = root.appending(path: "index.html")
        try "<title>must-not-load-placeholder</title>".write(
            to: entrypoint,
            atomically: true,
            encoding: .utf8
        )
        try #"{"schemaVersion":1,"targetURL":"http://legacy.example.test/live"}"#
            .write(
                to: root.appending(path: RemoteWebWallpaperConfiguration.fileName),
                atomically: true,
                encoding: .utf8
            )

        let view = RestrictedWebWallpaperView(
            url: entrypoint,
            readAccessURL: root,
            frame: CGRect(x: 0, y: 0, width: 320, height: 180),
            networkAccessAllowed: true
        )
        defer { view.prepareForClose() }

        let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        XCTAssertNil(webView.url)
        let messages = view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(messages.contains { $0.contains("invalid or legacy remote metadata") })
        XCTAssertTrue(messages.contains { $0.contains("Re-import") && $0.contains("HTTPS") })
    }

    @MainActor
    func testValidRemoteViewInstallsExactlyOneAudioBridgeBeforeLoading() throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-remote-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = root.appending(path: "index.html")
        try "<title>remote-placeholder</title>".write(
            to: entrypoint,
            atomically: true,
            encoding: .utf8
        )
        try #"{"schemaVersion":1,"targetURL":"https://example.test/live"}"#
            .write(
                to: root.appending(path: RemoteWebWallpaperConfiguration.fileName),
                atomically: true,
                encoding: .utf8
            )

        // Network stays disabled so the test never contacts the remote host;
        // script installation happens synchronously before that policy gate.
        let view = RestrictedWebWallpaperView(
            url: entrypoint,
            readAccessURL: root,
            frame: CGRect(x: 0, y: 0, width: 320, height: 180),
            networkAccessAllowed: false
        )
        defer { view.prepareForClose() }
        let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        let registeredScripts = webView.configuration.userContentController.userScripts
            .map(\.source)

        XCTAssertEqual(
            registeredScripts.filter { $0.contains("__backgroundEngineApplyAudioPolicy") }
                .count,
            1
        )
        XCTAssertFalse(
            registeredScripts.contains {
                $0.contains("__backgroundEngineMediaSourceBridgeInstalled")
            },
            "Remote websites do not use local prepared-resource aliases."
        )
    }

    @MainActor
    func testPreparationFailureShowsNonfatalWarningAndStillLoadsAuthoredPage() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-warning-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = project.appending(path: "index.html")
        let brokenMedia = project.appending(path: "broken.ogv")
        try #"<title>authored-fallback-loaded</title><video src="broken.ogv"></video>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try Data("broken-media".utf8).write(to: brokenMedia)
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: root.appending(path: "cache"),
            preparationOperation: { _, _, _ in
                throw WebMediaPreparationError.unsupportedSource
            }
        )

        let view = RestrictedWebWallpaperView(
            url: entrypoint,
            readAccessURL: project,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            mediaRuntimeCoordinator: coordinator
        )
        defer { view.prepareForClose() }
        let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        var loadedTitle = ""
        for _ in 0..<200 {
            if let value = try? await webView.evaluateJavaScript("document.title"),
               let title = value as? String {
                loadedTitle = title
                if title == "authored-fallback-loaded" { break }
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(loadedTitle, "authored-fallback-loaded")
        let registeredScripts = webView.configuration.userContentController.userScripts
            .map(\.source)
        let mediaBridgeIndex = try XCTUnwrap(
            registeredScripts.firstIndex {
                $0.contains("__backgroundEngineMediaSourceBridgeInstalled")
            }
        )
        let audioBridgeIndex = try XCTUnwrap(
            registeredScripts.firstIndex {
                $0.contains("__backgroundEngineApplyAudioPolicy")
            }
        )
        XCTAssertLessThan(
            mediaBridgeIndex,
            audioBridgeIndex,
            "The tamper-resistant audio wrapper must seal play only after media normalization."
        )
        XCTAssertEqual(
            registeredScripts.filter {
                $0.contains("__backgroundEngineMediaSourceBridgeInstalled")
            }.count,
            1
        )
        XCTAssertEqual(
            registeredScripts.filter { $0.contains("__backgroundEngineApplyAudioPolicy") }
                .count,
            1
        )
        // Give `didFinish` a chance to clear its separate navigation status.
        try await Task.sleep(for: .milliseconds(100))
        let warning = try XCTUnwrap(
            view.subviews.compactMap { $0 as? NSTextField }.first {
                $0.identifier?.rawValue
                    == "BackgroundEngine.WebMediaPreparationWarning"
            }
        )
        XCTAssertTrue(warning.stringValue.contains("may use another authored source"))
        XCTAssertEqual(warning.accessibilityLabel(), "Web media preparation warning")
        XCTAssertNotNil(webView.url, "A media warning must not block the authored page load.")
        view.prepareForClose()
        XCTAssertFalse(
            view.subviews.compactMap { $0 as? NSTextField }.contains {
                $0.identifier?.rawValue
                    == "BackgroundEngine.WebMediaPreparationWarning"
            },
            "Closing a display must remove its persistent warning immediately."
        )
    }

    func testAllFailedPreparationWarningPersistsWhilePartialWarningAutoDismisses() throws {
        let allFailed = try XCTUnwrap(
            WebMediaPreparationWarningPresentation.make(
                failureCount: 2,
                allLocalPreparationFailed: true
            )
        )
        XCTAssertFalse(allFailed.automaticallyDismisses)
        XCTAssertEqual(
            allFailed.message,
            "Local media could not be prepared. The page may use another authored source. "
                + "Replay the wallpaper or clear Web Media Cache to retry."
        )
        let partial = try XCTUnwrap(
            WebMediaPreparationWarningPresentation.make(
                failureCount: 1,
                allLocalPreparationFailed: false
            )
        )
        XCTAssertTrue(partial.automaticallyDismisses)
        XCTAssertNil(
            WebMediaPreparationWarningPresentation.make(
                failureCount: 0,
                allLocalPreparationFailed: false
            )
        )
    }

    func testNavigationPolicyAllowsOnlyTheTrustedWebProjectOrigin() {
        let root = URL(filePath: "/tmp/background-engine-web/project")
        let trusted = URL(
            string: "background-engine-web://session-test/project/index.html"
        )!

        XCTAssertTrue(
            RestrictedWebNavigationPolicy.allows(
                trusted,
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: false,
                trustedVirtualMainFrameURL: trusted
            )
        )
        XCTAssertTrue(
            RestrictedWebNavigationPolicy.allows(
                URL(string: "background-engine-web://session-test/project/frame.html")!,
                projectRoot: root,
                isMainFrame: false,
                networkAccessAllowed: false,
                trustedVirtualMainFrameURL: trusted
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                URL(string: "background-engine-web://session-test/project/other.html")!,
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: false,
                trustedVirtualMainFrameURL: trusted
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                URL(string: "background-engine-web://attacker/project/frame.html")!,
                projectRoot: root,
                isMainFrame: false,
                networkAccessAllowed: true,
                trustedVirtualMainFrameURL: trusted
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                URL(string: "background-engine-web://session-test/other/frame.html")!,
                projectRoot: root,
                isMainFrame: false,
                networkAccessAllowed: true,
                trustedVirtualMainFrameURL: trusted
            )
        )
    }

    func testNavigationPolicyAllowsOnlyExactSecretLoopbackOriginAndEntrypoint() {
        let root = URL(filePath: "/tmp/background-engine-web/project")
        let trusted = URL(
            string: "http://127.0.0.1:49152/secret-token/project/index.html"
        )!

        XCTAssertTrue(
            RestrictedWebNavigationPolicy.allows(
                trusted,
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: false,
                trustedLoopbackMainFrameURL: trusted
            )
        )
        XCTAssertTrue(
            RestrictedWebNavigationPolicy.allows(
                URL(string: trusted.absoluteString + "#clock")!,
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: false,
                trustedLoopbackMainFrameURL: trusted
            ),
            "Hash routers stay on the exact trusted document."
        )
        XCTAssertTrue(
            RestrictedWebNavigationPolicy.allows(
                URL(string: "http://127.0.0.1:49152/secret-token/project/frame.html")!,
                projectRoot: root,
                isMainFrame: false,
                networkAccessAllowed: false,
                trustedLoopbackMainFrameURL: trusted
            )
        )
        for rejected in [
            "http://127.0.0.1:49153/secret-token/project/frame.html",
            "http://127.0.0.1:49152/other-token/project/frame.html",
            "http://localhost:49152/secret-token/project/frame.html",
            "http://localhost.:49152/secret-token/project/frame.html",
            "http://[::ffff:127.0.0.1]:49152/secret-token/project/frame.html",
            "http://[::]:49152/secret-token/project/frame.html",
            "http://[0:0:0:0:0:0:0:1]:49152/secret-token/project/frame.html",
            "http://127.0.0.1:49152/secret-token/project/other.html",
            "http://127.0.0.1:49152/secret-token/project/index.html?redirect=1"
        ] {
            XCTAssertFalse(
                RestrictedWebNavigationPolicy.allows(
                    URL(string: rejected)!,
                    projectRoot: root,
                    isMainFrame: rejected.contains("other.html") || rejected.contains("redirect"),
                    networkAccessAllowed: true,
                    trustedLoopbackMainFrameURL: trusted
                ),
                rejected
            )
        }
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                URL(string: "http://127.0.0.1:8080/status")!,
                projectRoot: root,
                isMainFrame: false,
                networkAccessAllowed: true,
                trustedLoopbackMainFrameURL: trusted
            ),
            "Network opt-in must never grant ambient localhost access."
        )
    }

    func testNavigationPolicyRestrictsFilesToProjectRootAndRejectsDownloads() {
        let root = URL(filePath: "/tmp/background-engine-web/project")
        let entrypoint = root.appending(path: "index.html")
        XCTAssertTrue(
            RestrictedWebNavigationPolicy.allows(
                entrypoint,
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: false,
                trustedLocalMainFrameURL: entrypoint
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                root.appending(path: "second.html"),
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: false,
                trustedLocalMainFrameURL: entrypoint
            )
        )
        XCTAssertTrue(
            RestrictedWebNavigationPolicy.allows(
                root.appending(path: "frame.html"),
                projectRoot: root,
                isMainFrame: false,
                networkAccessAllowed: false,
                trustedLocalMainFrameURL: entrypoint
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                URL(string: "file://attacker.example/tmp/background-engine-web/project/index.html"),
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: false,
                trustedLocalMainFrameURL: entrypoint
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                root.deletingLastPathComponent().appending(path: "secret.html"),
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: true
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                root.appending(path: "file.zip"),
                projectRoot: root,
                isMainFrame: false,
                networkAccessAllowed: true,
                isDownload: true
            )
        )
    }

    func testNavigationPolicyAllowsOptedInNetworkOnlyInSubframes() {
        let root = URL(filePath: "/tmp/background-engine-web/project")
        let remote = URL(string: "https://example.com/texture.png")
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                remote,
                projectRoot: root,
                isMainFrame: false,
                networkAccessAllowed: false
            )
        )
        XCTAssertTrue(
            RestrictedWebNavigationPolicy.allows(
                remote,
                projectRoot: root,
                isMainFrame: false,
                networkAccessAllowed: true
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                remote,
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: true
            )
        )
    }

    func testNavigationPolicyAllowsOpaqueDocumentsOnlyInsideTrustedSubframes() throws {
        let root = URL(filePath: "/tmp/background-engine-web/project")
        let trusted = try XCTUnwrap(
            URL(string: "http://127.0.0.1:49152/secret-token/project/index.html")
        )
        let allowedSubframes = [
            "data:text/html;base64,PGNhbnZhcz48L2NhbnZhcz4=",
            "about:blank",
            "about:srcdoc",
            "blob:http://127.0.0.1:49152/9D20D9F4-4F6A-4100-A87E-9EEC8F54A955",
            "blob:null/9D20D9F4-4F6A-4100-A87E-9EEC8F54A955"
        ]
        for value in allowedSubframes {
            let candidate = try XCTUnwrap(URL(string: value))
            XCTAssertTrue(
                RestrictedWebNavigationPolicy.allows(
                    candidate,
                    projectRoot: root,
                    isMainFrame: false,
                    networkAccessAllowed: false,
                    trustedLoopbackMainFrameURL: trusted
                ),
                value
            )
            XCTAssertFalse(
                RestrictedWebNavigationPolicy.allows(
                    candidate,
                    projectRoot: root,
                    isMainFrame: true,
                    networkAccessAllowed: true,
                    trustedLoopbackMainFrameURL: trusted
                ),
                "Opaque/document-generated URLs must never replace the main frame: \(value)"
            )
            XCTAssertFalse(
                RestrictedWebNavigationPolicy.allows(
                    candidate,
                    projectRoot: root,
                    isMainFrame: false,
                    networkAccessAllowed: true
                ),
                "An opaque subframe requires an established trusted top-level page: \(value)"
            )
        }
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                URL(string: "blob:https://attacker.example/id")!,
                projectRoot: root,
                isMainFrame: false,
                networkAccessAllowed: true,
                trustedLoopbackMainFrameURL: trusted
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                URL(string: "data:text/html,download")!,
                projectRoot: root,
                isMainFrame: false,
                networkAccessAllowed: false,
                isDownload: true,
                trustedLoopbackMainFrameURL: trusted
            )
        )
    }

    func testNavigationPolicyAllowsOnlyTrustedRemoteWebsiteInMainFrame() {
        let root = URL(filePath: "/tmp/background-engine-web/project")
        let trusted = URL(string: "https://example.com/dashboard")!

        XCTAssertTrue(
            RestrictedWebNavigationPolicy.allows(
                URL(string: "https://example.com/next"),
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: true,
                trustedRemoteMainFrameURL: trusted
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                URL(string: "https://www.example.com/next"),
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: true,
                trustedRemoteMainFrameURL: trusted
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                URL(string: "https://user:password@example.com/next"),
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: true,
                trustedRemoteMainFrameURL: trusted
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                URL(string: "https://user:password@example.com/texture.png"),
                projectRoot: root,
                isMainFrame: false,
                networkAccessAllowed: true,
                trustedRemoteMainFrameURL: trusted
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                URL(string: "https://example.com:8443/next"),
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: true,
                trustedRemoteMainFrameURL: trusted
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                URL(string: "https://tracker.example.net/redirect"),
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: true,
                trustedRemoteMainFrameURL: trusted
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allows(
                trusted,
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: false,
                trustedRemoteMainFrameURL: trusted
            )
        )
    }

    func testNavigationResponsePolicyRejectsCrossOriginRedirectTargets() {
        let root = URL(filePath: "/tmp/background-engine-web/project")
        let trusted = URL(string: "https://example.com/start")!

        XCTAssertTrue(
            RestrictedWebNavigationPolicy.allowsResponse(
                URL(string: "https://example.com/final"),
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: true,
                canShowMIMEType: true,
                trustedRemoteMainFrameURL: trusted
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allowsResponse(
                URL(string: "https://redirect.example.net/final"),
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: true,
                canShowMIMEType: true,
                trustedRemoteMainFrameURL: trusted
            )
        )
        XCTAssertFalse(
            RestrictedWebNavigationPolicy.allowsResponse(
                URL(string: "https://example.com/final"),
                projectRoot: root,
                isMainFrame: true,
                networkAccessAllowed: true,
                canShowMIMEType: false,
                trustedRemoteMainFrameURL: trusted
            )
        )
    }

    func testAudioBridgeFailClosedRoutingPreservesAuthoredMediaStateAndHandlesDynamicMedia() throws {
        let controlToken = "test-media-control-token"
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        function HTMLMediaElement() {
          this._muted = false;
          this._volume = 0.8;
          this.playCount = 0;
        }
        Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
          configurable: true,
          enumerable: true,
          get: function() { return this._muted; },
          set: function(value) { this._muted = Boolean(value); }
        });
        Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
          configurable: true,
          enumerable: true,
          get: function() { return this._volume; },
          set: function(value) { this._volume = Number(value); }
        });
        HTMLMediaElement.prototype.play = function() {
          this.playCount += 1;
          return Promise.resolve();
        };
        var existingMedia = new HTMLMediaElement();
        var dynamicMedia = new HTMLMediaElement();
        dynamicMedia._volume = 0.6;
        var mutationCallback = null;
        function MutationObserver(callback) { mutationCallback = callback; }
        MutationObserver.prototype.observe = function() {};
        var document = {
          documentElement: {},
          querySelectorAll: function() { return [existingMedia]; }
        };
        var window = {
          HTMLMediaElement: HTMLMediaElement,
          MutationObserver: MutationObserver,
          frames: []
        };
        """#)

        context.evaluateScript(WebWallpaperAudioBridge.bootstrapScript(controlToken: controlToken))
        XCTAssertNil(context.exception, "Unexpected bridge exception: \(String(describing: context.exception))")
        XCTAssertEqual(context.evaluateScript("existingMedia._muted")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("existingMedia._volume")?.toDouble(), 0)
        XCTAssertEqual(context.evaluateScript("existingMedia.muted")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("existingMedia.volume")?.toDouble(), 0.8)

        context.evaluateScript(
            WebWallpaperAudioBridge.updateScript(
                controlToken: controlToken,
                enabled: true,
                volume: 0.5
            )
        )
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("existingMedia._muted")?.toBool(), false)
        XCTAssertEqual(
            try XCTUnwrap(context.evaluateScript("existingMedia._volume")?.toDouble()),
            0.4,
            accuracy: 0.000_001
        )

        context.evaluateScript("existingMedia.volume = 0.6; existingMedia.muted = true;")
        XCTAssertEqual(context.evaluateScript("existingMedia._muted")?.toBool(), true)
        XCTAssertEqual(
            try XCTUnwrap(context.evaluateScript("existingMedia._volume")?.toDouble()),
            0.3,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(context.evaluateScript("existingMedia.volume")?.toDouble()),
            0.6,
            accuracy: 0.000_001
        )

        context.evaluateScript(
            WebWallpaperAudioBridge.updateScript(
                controlToken: controlToken,
                enabled: false,
                volume: 1
            )
        )
        context.evaluateScript("existingMedia.muted = false;")
        XCTAssertEqual(context.evaluateScript("existingMedia._muted")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("existingMedia._volume")?.toDouble(), 0)
        XCTAssertEqual(context.evaluateScript("existingMedia.muted")?.toBool(), false)

        context.evaluateScript("mutationCallback([{ addedNodes: [dynamicMedia] }]);")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("dynamicMedia._muted")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("dynamicMedia._volume")?.toDouble(), 0)
        context.evaluateScript(
            WebWallpaperAudioBridge.updateScript(
                controlToken: controlToken,
                enabled: true,
                volume: 0.25
            )
        )
        XCTAssertEqual(context.evaluateScript("dynamicMedia._muted")?.toBool(), false)
        XCTAssertEqual(
            try XCTUnwrap(context.evaluateScript("dynamicMedia._volume")?.toDouble()),
            0.15,
            accuracy: 0.000_001
        )

        context.evaluateScript(
            WebWallpaperAudioBridge.suspensionScript(
                controlToken: controlToken,
                suspended: true
            )
        )
        XCTAssertEqual(context.evaluateScript("dynamicMedia._muted")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("dynamicMedia._volume")?.toDouble(), 0)
        context.evaluateScript(
            WebWallpaperAudioBridge.suspensionScript(
                controlToken: controlToken,
                suspended: false
            )
        )
        XCTAssertEqual(context.evaluateScript("dynamicMedia._muted")?.toBool(), false)
        XCTAssertEqual(
            try XCTUnwrap(context.evaluateScript("dynamicMedia._volume")?.toDouble()),
            0.15,
            accuracy: 0.000_001
        )
    }

    func testAudioBridgeTracksMediaThroughWeakReferencesWhenAvailable() throws {
        let controlToken = "weak-media-control-token"
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        function HTMLMediaElement() { this._muted = false; this._volume = 0.75; }
        Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
          configurable: true,
          get: function() { return this._muted; },
          set: function(value) { this._muted = Boolean(value); }
        });
        Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
          configurable: true,
          get: function() { return this._volume; },
          set: function(value) { this._volume = Number(value); }
        });
        HTMLMediaElement.prototype.play = function() { return Promise.resolve(); };
        var weakReferenceConstructionCount = 0;
        var weakReferenceDereferenceCount = 0;
        var trackedWeakReference = null;
        function TrackingWeakRef(target) {
          weakReferenceConstructionCount += 1;
          this._target = target;
          trackedWeakReference = this;
        }
        TrackingWeakRef.prototype.deref = function() {
          weakReferenceDereferenceCount += 1;
          return this._target;
        };
        var media = new HTMLMediaElement();
        var document = {
          documentElement: null,
          querySelectorAll: function() { return [media]; }
        };
        var window = {
          HTMLMediaElement: HTMLMediaElement,
          WeakRef: TrackingWeakRef,
          frames: []
        };
        """#)

        let bootstrap = WebWallpaperAudioBridge.bootstrapScript(controlToken: controlToken)
        context.evaluateScript(bootstrap)
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("weakReferenceConstructionCount")?.toInt32(), 1)

        context.evaluateScript(
            WebWallpaperAudioBridge.updateScript(
                controlToken: controlToken,
                enabled: true,
                volume: 0.4
            )
        )
        XCTAssertEqual(context.evaluateScript("media._muted")?.toBool(), false)
        XCTAssertEqual(
            try XCTUnwrap(context.evaluateScript("media._volume")?.toDouble()),
            0.3,
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(
            context.evaluateScript("weakReferenceDereferenceCount")?.toInt32() ?? 0,
            0
        )

        context.evaluateScript("trackedWeakReference._target = null; media = null;")
        context.evaluateScript(
            WebWallpaperAudioBridge.suspensionScript(
                controlToken: controlToken,
                suspended: true
            )
        )
        XCTAssertNil(context.exception)

        XCTAssertTrue(bootstrap.contains("const NativeWeakRef = window.WeakRef;"))
        XCTAssertTrue(bootstrap.contains("makeMediaReference(element)"))
        XCTAssertTrue(bootstrap.contains("retainedMedia[retainedMedia.length] = reference;"))
        XCTAssertFalse(bootstrap.contains("gate.media[gate.media.length] = element;"))
    }

    func testAudioBridgeBoundsStrongReferenceFallbackAndEvictsFailClosed() throws {
        let controlToken = "bounded-media-fallback-token"
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        function HTMLMediaElement() { this._muted = false; this._volume = 1; }
        Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
          configurable: true,
          get: function() { return this._muted; },
          set: function(value) { this._muted = Boolean(value); }
        });
        Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
          configurable: true,
          get: function() { return this._volume; },
          set: function(value) { this._volume = Number(value); }
        });
        HTMLMediaElement.prototype.play = function() { return Promise.resolve(); };
        var mediaElements = [];
        for (var index = 0; index < 257; index += 1) {
          mediaElements.push(new HTMLMediaElement());
        }
        var document = {
          documentElement: null,
          querySelectorAll: function() { return mediaElements; }
        };
        var window = { HTMLMediaElement: HTMLMediaElement, frames: [] };
        """#)

        context.evaluateScript(WebWallpaperAudioBridge.bootstrapScript(controlToken: controlToken))
        context.evaluateScript(
            WebWallpaperAudioBridge.updateScript(
                controlToken: controlToken,
                enabled: true,
                volume: 1
            )
        )
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("mediaElements[0]._muted")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("mediaElements[0]._volume")?.toDouble(), 0)
        XCTAssertEqual(context.evaluateScript("mediaElements[1]._muted")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("mediaElements[256]._muted")?.toBool(), false)

        context.evaluateScript("mediaElements[0].muted = false;")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("mediaElements[0]._muted")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("mediaElements[1]._muted")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("mediaElements[1]._volume")?.toDouble(), 0)

        context.evaluateScript(
            WebWallpaperAudioBridge.suspensionScript(
                controlToken: controlToken,
                suspended: true
            )
        )
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("mediaElements[0]._muted")?.toBool(), true)
    }

    func testAudioBridgeRoutesWebAudioThroughGlobalGainAndPreservesAuthoredSuspension() throws {
        let controlToken = "test-web-audio-control-token"
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        function AudioNode(context) {
          this.context = context;
          this.connectedTo = null;
        }
        AudioNode.prototype.connect = function(destination) {
          this.connectedTo = destination;
          return destination;
        };
        function AudioContext() {
          this.state = 'running';
          this.destination = { kind: 'destination' };
          this.nativeResumeCount = 0;
          this.nativeSuspendCount = 0;
        }
        AudioContext.prototype.createGain = function() {
          var node = new AudioNode(this);
          node.gain = { value: 1 };
          return node;
        };
        AudioContext.prototype.resume = function() {
          this.state = 'running';
          this.nativeResumeCount += 1;
          return Promise.resolve();
        };
        AudioContext.prototype.suspend = function() {
          this.state = 'suspended';
          this.nativeSuspendCount += 1;
          return Promise.resolve();
        };
        AudioContext.prototype.close = function() {
          this.state = 'closed';
          return Promise.resolve();
        };
        var document = { documentElement: null, querySelectorAll: function() { return []; } };
        var window = {
          AudioNode: AudioNode,
          AudioContext: AudioContext,
          frames: []
        };
        """#)

        context.evaluateScript(WebWallpaperAudioBridge.bootstrapScript(controlToken: controlToken))
        context.evaluateScript(#"""
        var authoredContext = new window.AudioContext();
        var authoredNode = new AudioNode(authoredContext);
        var connectResult = authoredNode.connect(authoredContext.destination);
        """#)
        XCTAssertNil(context.exception, "Unexpected WebAudio bridge exception: \(String(describing: context.exception))")
        XCTAssertEqual(context.evaluateScript("authoredNode.connectedTo.gain.value")?.toDouble(), 0)
        XCTAssertEqual(context.evaluateScript("authoredNode.connectedTo !== authoredContext.destination")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("connectResult === authoredContext.destination")?.toBool(), true)

        context.evaluateScript(
            WebWallpaperAudioBridge.updateScript(
                controlToken: controlToken,
                enabled: true,
                volume: 0.35
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(context.evaluateScript("authoredNode.connectedTo.gain.value")?.toDouble()),
            0.35,
            accuracy: 0.000_001
        )

        context.evaluateScript(
            WebWallpaperAudioBridge.suspensionScript(
                controlToken: controlToken,
                suspended: true
            )
        )
        XCTAssertEqual(context.evaluateScript("authoredContext.state")?.toString(), "suspended")
        XCTAssertEqual(context.evaluateScript("authoredNode.connectedTo.gain.value")?.toDouble(), 0)
        context.evaluateScript(
            WebWallpaperAudioBridge.suspensionScript(
                controlToken: controlToken,
                suspended: false
            )
        )
        XCTAssertEqual(context.evaluateScript("authoredContext.state")?.toString(), "running")
        XCTAssertEqual(
            try XCTUnwrap(context.evaluateScript("authoredNode.connectedTo.gain.value")?.toDouble()),
            0.35,
            accuracy: 0.000_001
        )

        context.evaluateScript("authoredContext.suspend();")
        context.evaluateScript(
            WebWallpaperAudioBridge.suspensionScript(
                controlToken: controlToken,
                suspended: true
            )
        )
        context.evaluateScript(
            WebWallpaperAudioBridge.suspensionScript(
                controlToken: controlToken,
                suspended: false
            )
        )
        XCTAssertEqual(context.evaluateScript("authoredContext.state")?.toString(), "suspended")
    }

    func testAudioBridgeRejectsWallpaperAttemptsToOverrideOrInvokeHostPolicy() throws {
        let controlToken = "host-only-audio-token"
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        function HTMLMediaElement() { this._muted = false; this._volume = 1; }
        Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
          configurable: true,
          get: function() { return this._muted; },
          set: function(value) { this._muted = Boolean(value); }
        });
        Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
          configurable: true,
          get: function() { return this._volume; },
          set: function(value) { this._volume = +value; }
        });
        HTMLMediaElement.prototype.play = function() { return Promise.resolve(); };
        var media = new HTMLMediaElement();
        var document = {
          documentElement: null,
          querySelectorAll: function() { return [media]; }
        };
        var window = { HTMLMediaElement: HTMLMediaElement, frames: [] };
        """#)
        context.evaluateScript(WebWallpaperAudioBridge.bootstrapScript(controlToken: controlToken))

        context.evaluateScript(#"""
        var hostileResult = window.__backgroundEngineApplyAudioPolicy('guessed-token', true, 1);
        var originalPolicyFunction = window.__backgroundEngineApplyAudioPolicy;
        try { window.__backgroundEngineApplyAudioPolicy = function() { return true; }; } catch (_) {}
        try { delete window.__backgroundEngineApplyAudioPolicy; } catch (_) {}
        var policyFunctionStayedLocked =
          window.__backgroundEngineApplyAudioPolicy === originalPolicyFunction;
        var policyDescriptor = Object.getOwnPropertyDescriptor(
          window,
          '__backgroundEngineApplyAudioPolicy'
        );
        var gateWasExposed = Object.prototype.hasOwnProperty.call(
          window,
          '__backgroundEngineAudioGate'
        );
        """#)

        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("hostileResult")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("policyFunctionStayedLocked")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("policyDescriptor.configurable")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("policyDescriptor.writable")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("gateWasExposed")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("media._muted")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("media._volume")?.toDouble(), 0)

        context.evaluateScript(
            WebWallpaperAudioBridge.updateScript(
                controlToken: controlToken,
                enabled: true,
                volume: 0.4
            )
        )
        XCTAssertEqual(context.evaluateScript("media._muted")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("media._volume")?.toDouble(), 0.4)

        context.evaluateScript(#"""
        Array.prototype.filter = function() { return this; };
        Array.prototype.forEach = function() {};
        Boolean = function() { return true; };
        Number = function() { return 1; };
        WeakMap.prototype.get = function() { return null; };
        WeakMap.prototype.has = function() { return false; };
        WeakMap.prototype.set = function() {};
        Promise.prototype.then = function() { return this; };
        Promise.prototype.catch = function() { return this; };
        Object.defineProperty = function() {};
        Reflect.apply = function() { throw new Error('hostile apply'); };
        """#)
        context.evaluateScript(
            WebWallpaperAudioBridge.updateScript(
                controlToken: controlToken,
                enabled: false,
                volume: 0
            )
        )
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("media._muted")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("media._volume")?.toDouble(), 0)
    }

    func testAudioBridgeSerializesDelayedWebAudioSuspendResumeTransitions() throws {
        let controlToken = "delayed-web-audio-control-token"
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var pendingNativeOperations = [];
        function AudioNode(context) { this.context = context; }
        AudioNode.prototype.connect = function(destination) {
          this.connectedTo = destination;
          return destination;
        };
        function AudioContext() {
          this.state = 'running';
          this.destination = {};
        }
        AudioContext.prototype.createGain = function() {
          var node = new AudioNode(this);
          node.gain = { value: 1 };
          return node;
        };
        AudioContext.prototype.resume = function() {
          var context = this;
          return new Promise(function(resolve) {
            pendingNativeOperations.push(function() {
              context.state = 'running';
              resolve();
            });
          });
        };
        AudioContext.prototype.suspend = function() {
          var context = this;
          return new Promise(function(resolve) {
            pendingNativeOperations.push(function() {
              context.state = 'suspended';
              resolve();
            });
          });
        };
        AudioContext.prototype.close = function() { return Promise.resolve(); };
        var document = { documentElement: null, querySelectorAll: function() { return []; } };
        var window = {
          AudioNode: AudioNode,
          AudioContext: AudioContext,
          frames: []
        };
        """#)
        context.evaluateScript(WebWallpaperAudioBridge.bootstrapScript(controlToken: controlToken))
        context.evaluateScript(#"""
        var delayedContext = new window.AudioContext();
        var delayedNode = new AudioNode(delayedContext);
        delayedNode.connect(delayedContext.destination);
        """#)
        context.evaluateScript(
            WebWallpaperAudioBridge.updateScript(
                controlToken: controlToken,
                enabled: true,
                volume: 1
            )
        )

        context.evaluateScript(
            WebWallpaperAudioBridge.suspensionScript(
                controlToken: controlToken,
                suspended: true
            )
        )
        context.evaluateScript("0")
        XCTAssertEqual(context.evaluateScript("pendingNativeOperations.length")?.toInt32(), 1)

        context.evaluateScript(
            WebWallpaperAudioBridge.suspensionScript(
                controlToken: controlToken,
                suspended: false
            )
        )
        XCTAssertEqual(context.evaluateScript("delayedContext.state")?.toString(), "running")
        context.evaluateScript("pendingNativeOperations.shift()();")
        context.evaluateScript("0")
        XCTAssertEqual(context.evaluateScript("delayedContext.state")?.toString(), "suspended")
        XCTAssertEqual(context.evaluateScript("pendingNativeOperations.length")?.toInt32(), 1)

        context.evaluateScript("pendingNativeOperations.shift()();")
        context.evaluateScript("0")
        XCTAssertEqual(context.evaluateScript("delayedContext.state")?.toString(), "running")
        XCTAssertNil(context.exception)
    }

    func testWebWallpaperAudioIsWiredThroughTheSharedPerDisplayAudioContract() throws {
        let webSource = try String(
            repositoryFile: "Sources/BackgroundEngineApp/RestrictedWebWallpaperView.swift"
        )
        let playerSource = try String(repositoryFile: "Sources/BackgroundEngineApp/WallpaperPlayer.swift")

        XCTAssertTrue(webSource.contains("AudioControllableWallpaperContent"))
        XCTAssertTrue(webSource.contains("WebWallpaperAudioBridge.bootstrapScript"))
        XCTAssertTrue(webSource.contains("func setAudioEnabled(_ enabled: Bool, volume: Double)"))
        XCTAssertTrue(webSource.contains("gate.enabled && !gate.suspended"))
        XCTAssertTrue(webSource.contains("enqueueNativeMediaSuspension(true)"))
        XCTAssertTrue(playerSource.contains("networkAccessAllowed: asset.allowsNetworkAccess == true,"))
        XCTAssertTrue(playerSource.contains("audioEnabled: audioEnabled,"))
        XCTAssertTrue(playerSource.contains("audioVolume: audioVolume"))
    }

    func testWebWallpaperOwnsProcessRecoveryAndCloseLifecycle() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/RestrictedWebWallpaperView.swift")

        XCTAssertTrue(source.contains("import PlashRuntime"))
        XCTAssertTrue(source.contains("PlashRuntime.makeConfiguration"))
        XCTAssertTrue(source.contains("PlashWebView(frame:"))
        XCTAssertTrue(source.contains("setAllMediaPlaybackSuspended"))
        XCTAssertFalse(source.contains("PlashRuntime.playbackScript"))
        XCTAssertTrue(source.contains("isSuspended = suspended"))
        XCTAssertTrue(source.contains("applyPlaybackSuspension()"))
        XCTAssertTrue(source.contains("scheduleProcessRecovery()"))
        XCTAssertTrue(source.contains("recoveryAttempts < 2"))
        XCTAssertTrue(source.contains("The Web wallpaper stopped repeatedly. Replay it to try again."))
        XCTAssertTrue(source.contains("scheduleRecoveryBudgetReset()"))
        XCTAssertTrue(source.contains("Task.sleep(for: .seconds(30))"))
        XCTAssertTrue(source.contains("WallpaperContentLifecycle"))
        XCTAssertTrue(source.contains("webView.stopLoading()"))
        XCTAssertTrue(source.contains("nativeMediaSuspensionTask?.cancel()"))
        XCTAssertTrue(source.contains("localLoopbackServer?.stopAsync()"))
        XCTAssertFalse(source.contains("localLoopbackServer?.stop()"))
        XCTAssertTrue(source.contains("private final class OwnedFileDescriptor"))
        XCTAssertTrue(source.contains("deinit { closeNow() }"))
        XCTAssertTrue(source.contains("let canCloseImmediately = !started"))
        XCTAssertFalse(source.contains("webView.loadFileURL"))
        XCTAssertFalse(source.contains("webView.loadHTMLString"))
    }

    @MainActor
    private func installOfflineBoundary(
        on configuration: WKWebViewConfiguration,
        trustedLoopbackPort: UInt16
    ) async throws -> (store: WKContentRuleListStore, identifier: String) {
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let identifier = "com.lamppkk.backgroundengine.Tests.OfflineWebView.\(UUID().uuidString)"
        let encoded = try WebWallpaperLocalNetworkPolicy.encodedOfflineRules(
            trustedLoopbackPort: trustedLoopbackPort
        )
        let result: (WKContentRuleList?, (any Error)?) = await withCheckedContinuation {
            continuation in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encoded
            ) { ruleList, error in
                continuation.resume(returning: (ruleList, error))
            }
        }
        let ruleList = try XCTUnwrap(result.0, "Offline content rules failed: \(String(describing: result.1))")
        configuration.userContentController.add(ruleList)
        return (store, identifier)
    }
}

private final class CapturingWebProjectSchemeTask: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest
    private let finishedExpectation: XCTestExpectation
    private let lock = NSLock()
    private var storedResponse: URLResponse?
    private var storedData = Data()
    private var storedError: Error?

    init(request: URLRequest, finished: XCTestExpectation) {
        self.request = request
        finishedExpectation = finished
    }

    var response: URLResponse? {
        lock.lock()
        defer { lock.unlock() }
        return storedResponse
    }

    var receivedData: Data {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func didReceive(_ response: URLResponse) {
        lock.lock()
        storedResponse = response
        lock.unlock()
    }

    func didReceive(_ data: Data) {
        lock.lock()
        storedData.append(data)
        lock.unlock()
    }

    func didFinish() {
        finishedExpectation.fulfill()
    }

    func didFailWithError(_ error: any Error) {
        lock.lock()
        storedError = error
        lock.unlock()
        finishedExpectation.fulfill()
    }
}

private final class RecordingWebProjectSchemeTask: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest
    private let responseReceivedExpectation: XCTestExpectation?
    private let terminalExpectation: XCTestExpectation?
    private let onResponse: (@MainActor (any WKURLSchemeTask) -> Void)?
    private let lock = NSLock()
    private var storedCallbacks = [String]()
    private var storedError: Error?

    init(
        request: URLRequest,
        responseReceived: XCTestExpectation? = nil,
        terminal: XCTestExpectation? = nil,
        onResponse: (@MainActor (any WKURLSchemeTask) -> Void)? = nil
    ) {
        self.request = request
        responseReceivedExpectation = responseReceived
        terminalExpectation = terminal
        self.onResponse = onResponse
    }

    var callbacks: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedCallbacks
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func didReceive(_ response: URLResponse) {
        record("response")
        responseReceivedExpectation?.fulfill()
        guard let onResponse else { return }
        MainActor.assumeIsolated {
            onResponse(self)
        }
    }

    func didReceive(_ data: Data) {
        record("data")
    }

    func didFinish() {
        record("finish")
        terminalExpectation?.fulfill()
    }

    func didFailWithError(_ error: any Error) {
        lock.lock()
        storedCallbacks.append("failure")
        storedError = error
        lock.unlock()
        terminalExpectation?.fulfill()
    }

    private func record(_ callback: String) {
        lock.lock()
        storedCallbacks.append(callback)
        lock.unlock()
    }
}

private final class WebKitPlaybackSmokeMessageHandler: NSObject, WKScriptMessageHandler,
    @unchecked Sendable {
    private let completionExpectation: XCTestExpectation
    private let lock = NSLock()
    private var storedReport: [String: Any]?

    init(expectation: XCTestExpectation) {
        completionExpectation = expectation
    }

    var report: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return storedReport
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        lock.lock()
        let isFirstReport = storedReport == nil
        storedReport = message.body as? [String: Any]
        lock.unlock()
        if isFirstReport {
            completionExpectation.fulfill()
        }
    }
}

#if XCODE_APP_HOST_TESTS
private func configuredFFmpegPathForIntegrationTests() -> String? {
    if let configured = ProcessInfo.processInfo.environment["BACKGROUND_ENGINE_FFMPEG"],
       FileManager.default.isExecutableFile(atPath: configured) {
        return configured
    }
    return nil
}
#endif

private func sendRawLoopbackRequest(port: UInt16, request: String) throws -> String {
    let descriptor = try openLoopbackSocket(port: port)
    defer { close(descriptor) }
    try sendRawLoopbackBytes(descriptor: descriptor, data: Data(request.utf8))
    _ = shutdown(descriptor, SHUT_WR)
    return try receiveRawLoopbackResponse(descriptor: descriptor)
}

private func openLoopbackSocket(
    port: UInt16,
    receiveBufferBytes: Int32? = nil
) throws -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard descriptor >= 0 else { throw CocoaError(.fileNoSuchFile) }
    var noSignal: Int32 = 1
    _ = setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout<Int32>.size)
    )
    if var receiveBufferBytes {
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVBUF,
            &receiveBufferBytes,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    )
    _ = setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_SNDTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    )
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        close(descriptor)
        throw CocoaError(.fileReadNoSuchFile)
    }
    return descriptor
}

private func sendRawLoopbackBytes(descriptor: Int32, data: Data) throws {
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var sent = 0
        while sent < bytes.count {
            let result = Darwin.send(
                descriptor,
                base.advanced(by: sent),
                bytes.count - sent,
                0
            )
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw CocoaError(.fileWriteUnknown) }
            sent += result
        }
    }
}

private func receiveRawLoopbackResponse(descriptor: Int32) throws -> String {
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
    while true {
        let count = recv(descriptor, &buffer, buffer.count, 0)
        if count == 0 { break }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw CocoaError(.fileReadUnknown) }
        response.append(buffer, count: count)
    }
    return String(decoding: response, as: UTF8.self)
}

private func makeSmallH264Fixture(
    at output: URL,
    rawFrames: URL,
    ffmpeg: String
) throws {
    let width = 64
    let height = 64
    let frameCount = 20
    try Data(repeating: 0x20, count: width * height * 3 * frameCount)
        .write(to: rawFrames)

    let process = Process()
    let standardError = Pipe()
    process.executableURL = URL(filePath: ffmpeg)
    process.arguments = [
        "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
        "-f", "rawvideo",
        "-pixel_format", "rgb24",
        "-video_size", "\(width)x\(height)",
        "-framerate", "10",
        "-i", rawFrames.path,
        "-frames:v", String(frameCount),
        "-an",
        "-c:v", "h264_videotoolbox",
        "-allow_sw", "1",
        "-b:v", "1M",
        "-g", "5",
        "-pix_fmt", "yuv420p",
        "-movflags", "+faststart",
        "-f", "mp4",
        output.path
    ]
    process.standardOutput = Pipe()
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    let diagnostics = standardError.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        XCTFail(
            "FFmpeg fixture generation failed: "
                + (String(data: diagnostics, encoding: .utf8) ?? "unknown error")
        )
        throw CocoaError(.fileWriteUnknown)
    }
}

private func openDescriptorCount(referringTo url: URL) throws -> Int {
    var target = stat()
    let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return lstat(path, &target)
    }
    guard status == 0 else { throw CocoaError(.fileReadUnknown) }

    var count = 0
    for descriptor in 0..<getdtablesize() {
        var candidate = stat()
        if fstat(descriptor, &candidate) == 0,
           candidate.st_dev == target.st_dev,
           candidate.st_ino == target.st_ino {
            count += 1
        }
    }
    return count
}
