import BackgroundEngineCore
import JavaScriptCore
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

    func testWebWallpaperOwnsProcessRecoveryAndCloseLifecycle() throws {
        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/RestrictedWebWallpaperView.swift")

        XCTAssertTrue(source.contains("import PlashRuntime"))
        XCTAssertTrue(source.contains("PlashRuntime.makeConfiguration"))
        XCTAssertTrue(source.contains("PlashWebView(frame:"))
        XCTAssertTrue(source.contains("PlashRuntime.playbackScript"))
        XCTAssertTrue(source.contains("isSuspended = suspended"))
        XCTAssertTrue(source.contains("applyPlaybackSuspension()"))
        XCTAssertTrue(source.contains("scheduleProcessRecovery()"))
        XCTAssertTrue(source.contains("recoveryAttempts < 2"))
        XCTAssertTrue(source.contains("The Web wallpaper stopped repeatedly. Replay it to try again."))
        XCTAssertTrue(source.contains("scheduleRecoveryBudgetReset()"))
        XCTAssertTrue(source.contains("Task.sleep(for: .seconds(30))"))
        XCTAssertTrue(source.contains("WallpaperContentLifecycle"))
        XCTAssertTrue(source.contains("webView.stopLoading()"))
        XCTAssertFalse(source.contains("webView.loadHTMLString"))
    }
}
