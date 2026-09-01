import AppKit
@_spi(LivelyCatalog) @testable import BackgroundEngineCore
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

    func testEditableButtonDescriptorsPreserveLivelyAndWallpaperEngineSemanticsWithoutPersistence() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-button-properties-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try #"""
        {"general":{"properties":{
          "livelyShuffle":{"type":"button","text":"Actions","value":"Shuffle now","order":1,
            "backgroundEngineLivelyType":"button"},
          "resetColors":{"type":"button","text":"Reset colors","order":2},
          "":{"type":"button","text":"Unsafe empty name","order":3}
        }}}
        """#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )

        let properties = WebWallpaperCompatibilityBridge.editableProperties(projectRoot: project)

        XCTAssertEqual(properties.map(\.name), ["livelyShuffle", "resetColors"])
        XCTAssertEqual(properties.map(\.kind), [.button, .button])
        let lively = try XCTUnwrap(properties.first { $0.name == "livelyShuffle" })
        XCTAssertEqual(lively.label, "Actions")
        XCTAssertEqual(lively.buttonTitle, "Shuffle now")
        XCTAssertEqual(
            lively.buttonEvent,
            WebWallpaperButtonEvent(propertyName: "livelyShuffle", target: .lively)
        )
        let generic = try XCTUnwrap(properties.first { $0.name == "resetColors" })
        XCTAssertEqual(generic.label, "Reset colors")
        XCTAssertEqual(generic.buttonTitle, "Reset colors")
        XCTAssertEqual(
            generic.buttonEvent,
            WebWallpaperButtonEvent(propertyName: "resetColors", target: .wallpaperEngine)
        )
        XCTAssertTrue(WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: project).isEmpty)
        XCTAssertTrue(
            WebWallpaperCompatibilityBridge.persistedOverrides(
                ["livelyShuffle": .bool(true), "resetColors": .bool(true)],
                properties: properties
            ).isEmpty
        )
    }

    func testButtonEventScriptsDispatchOneShotTrueWithJSONEscapedPropertyName() throws {
        let hostileName = "action\"\\\n}; globalThis.injected = true; //"
        let livelyEvent = try XCTUnwrap(
            WebWallpaperButtonEvent(propertyName: hostileName, target: .lively)
        )
        let wallpaperEngineEvent = try XCTUnwrap(
            WebWallpaperButtonEvent(propertyName: hostileName, target: .wallpaperEngine)
        )
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var window = this;
        var injected = false;
        var livelyCalls = [];
        var wallpaperEngineCalls = [];
        window.livelyPropertyListener = function(name, value) {
          livelyCalls.push({ name: name, value: value });
        };
        window.wallpaperPropertyListener = {
          applyUserProperties: function(properties) { wallpaperEngineCalls.push(properties); }
        };
        """#)

        let livelySource = WebWallpaperButtonEventScript.source(for: livelyEvent)
        let wallpaperEngineSource = WebWallpaperButtonEventScript.source(for: wallpaperEngineEvent)
        XCTAssertTrue(context.evaluateScript(livelySource)?.toBool() == true)
        // A late WebKit completion followed by a native retry must not invoke
        // the same one-shot action twice in one document.
        XCTAssertTrue(context.evaluateScript(livelySource)?.toBool() == true)
        XCTAssertTrue(context.evaluateScript(wallpaperEngineSource)?.toBool() == true)

        XCTAssertNil(context.exception)
        XCTAssertFalse(context.evaluateScript("injected")?.toBool() == true)
        XCTAssertEqual(context.evaluateScript("livelyCalls.length")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("livelyCalls[0].name")?.toString(), hostileName)
        XCTAssertTrue(context.evaluateScript("livelyCalls[0].value === true")?.toBool() == true)
        XCTAssertEqual(context.evaluateScript("wallpaperEngineCalls.length")?.toInt32(), 1)
        context.setObject(hostileName, forKeyedSubscript: "expectedName" as NSString)
        XCTAssertTrue(
            context.evaluateScript(
                "Object.keys(wallpaperEngineCalls[0]).length === 1"
                    + " && wallpaperEngineCalls[0][expectedName].value === true"
            )?.toBool() == true
        )

        context.evaluateScript("window.livelyPropertyListener = null")
        let lateListenerSource = WebWallpaperButtonEventScript.source(
            for: try XCTUnwrap(
                WebWallpaperButtonEvent(propertyName: "lateAction", target: .lively)
            )
        )
        XCTAssertFalse(context.evaluateScript(lateListenerSource)?.toBool() == true)
        context.evaluateScript(#"""
        window.livelyPropertyListener = function(name, value) {
          livelyCalls.push({ name: name, value: value });
        };
        """#)
        XCTAssertTrue(context.evaluateScript(lateListenerSource)?.toBool() == true)
        XCTAssertEqual(context.evaluateScript("livelyCalls.length")?.toInt32(), 2)
        XCTAssertEqual(context.evaluateScript("livelyCalls[1].name")?.toString(), "lateAction")
    }

    func testNativePropertyEditorRendersButtonsAsImmediateMomentaryActions() throws {
        let source = try String(
            repositoryFile: "Sources/BackgroundEngineApp/WebWallpaperPropertiesEditorView.swift"
        )

        XCTAssertTrue(source.contains("case .button:"))
        XCTAssertTrue(source.contains("Button(property.buttonTitle ?? property.label)"))
        XCTAssertTrue(source.contains("try await onButton(event)"))
        XCTAssertTrue(source.contains("Buttons are sent immediately without restarting them."))
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

    func testLivelyDropdownCallbacksKeepNativeTypesWithoutChangingWallpaperEngineCombos() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-lively-property-types-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try #"""
        {"general":{"properties":{
          "quality":{"type":"combo","value":"1","backgroundEngineLivelyType":"dropdown",
            "options":[{"label":"Low","value":"0"},{"label":"High","value":"1"}]},
          "gallery":{"type":"combo","value":"images/second.jpg","backgroundEngineLivelyType":"folderDropdown",
            "backgroundEngineLivelyFolder":"images",
            "options":[{"label":"Default","value":"images/default.jpg"},{"label":"Second","value":"images/second.jpg"}]},
          "missing":{"type":"combo","value":"images/missing.jpg","backgroundEngineLivelyType":"folderDropdown",
            "backgroundEngineLivelyFolder":"images",
            "options":[{"label":"Default","value":"images/default.jpg"}]},
          "wallpaperEngineMode":{"type":"combo","value":"1",
            "options":[{"label":"One","value":"1"}]}
        }}}
        """#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )

        let properties = WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: project)
        let livelyProperties = WebWallpaperCompatibilityBridge.livelyCallbackProperties(
            projectRoot: project,
            mappedValues: properties
        )
        let script = WebWallpaperCompatibilityBridge.bootstrapScript(
            properties: properties,
            comboDisplayTexts: WebWallpaperCompatibilityBridge.comboDisplayTexts(
                projectRoot: project
            ),
            livelyProperties: livelyProperties
        )
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var pendingTimeouts = [];
        var document = { readyState: 'complete' };
        var window = this;
        window.clearInterval = function() {};
        window.setInterval = function() { return 1; };
        window.setTimeout = function(callback) { pendingTimeouts.push(callback); return pendingTimeouts.length; };
        window.addEventListener = function() {};
        """#)
        context.evaluateScript(script)
        context.evaluateScript(#"""
        var livelyValues = {};
        var wallpaperEngineValues = null;
        window.livelyPropertyListener = function(name, value) { livelyValues[name] = value; };
        window.wallpaperPropertyListener = {
          applyUserProperties: function(properties) { wallpaperEngineValues = properties; }
        };
        while (pendingTimeouts.length > 0) pendingTimeouts.shift()();
        """#)

        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("typeof livelyValues.quality")?.toString(), "number")
        XCTAssertEqual(context.evaluateScript("livelyValues.quality")?.toInt32(), 1)
        XCTAssertEqual(
            context.evaluateScript("livelyValues.gallery")?.toString(),
            "images/second.jpg"
        )
        XCTAssertTrue(context.evaluateScript("livelyValues.missing === null")?.toBool() == true)
        XCTAssertEqual(
            context.evaluateScript("typeof livelyValues.wallpaperEngineMode")?.toString(),
            "string"
        )
        XCTAssertEqual(
            context.evaluateScript("typeof wallpaperEngineValues.quality.value")?.toString(),
            "string"
        )
        XCTAssertEqual(
            context.evaluateScript("wallpaperEngineValues.quality.value")?.toString(),
            "1"
        )
    }

    func testLivelyFolderDropdownAcceptsFilteredSandboxCopyWithoutLeakingHostPath() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-lively-folder-dropdown-\(UUID().uuidString)")
        let storage = project.appending(path: WebWallpaperUserFileStore.directoryName)
        let images = project.appending(path: "images")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try #"""
        {"file":"index.html","general":{"properties":{"gallery":{
          "type":"combo","value":"images/default.jpg","backgroundEngineLivelyType":"folderDropdown",
          "backgroundEngineLivelyFolder":"images","backgroundEngineLivelyFilter":"*.JPG|*.png|bad/*",
          "options":[{"label":"Default","value":"images/default.jpg"},{"label":"Second","value":"images/second.jpg"}]
        }}}}
        """#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        let selected = images.appending(path: "gallery-private.png")
        try Data([1, 2, 3]).write(to: selected)
        try JSONEncoder().encode([
            "gallery": "images/\(selected.lastPathComponent)"
        ]).write(to: storage.appending(path: WebWallpaperUserFileStore.overridesFileName))

        let values = WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: project)
        let fileProperty = try XCTUnwrap(
            WebWallpaperCompatibilityBridge.fileProperties(projectRoot: project).first
        )
        let editable = try XCTUnwrap(
            WebWallpaperCompatibilityBridge.editableProperties(projectRoot: project).first
        )

        XCTAssertEqual(values["gallery"], .text("images/gallery-private.png"))
        XCTAssertTrue(fileProperty.isLivelyFolderDropdown)
        XCTAssertEqual(fileProperty.allowedExtensions, ["jpg", "png"])
        XCTAssertTrue(fileProperty.accepts(URL(filePath: "/tmp/picture.JPG")))
        XCTAssertFalse(fileProperty.accepts(URL(filePath: "/tmp/movie.mp4")))
        XCTAssertEqual(editable.currentValue, .text("images/gallery-private.png"))
        XCTAssertTrue(editable.options.contains {
            $0.label == "gallery-private.png" && $0.value == "images/gallery-private.png"
        })
        XCTAssertEqual(
            WebWallpaperCompatibilityBridge.persistedOverrides(
                ["gallery": .text("images/gallery-private.png")],
                properties: [editable]
            ),
            [:]
        )
        XCTAssertEqual(
            WebWallpaperCompatibilityBridge.persistedOverrides(
                ["gallery": .text("images/second.jpg")],
                properties: [editable]
            ),
            ["gallery": .text("images/second.jpg")]
        )

        let lively = WebWallpaperCompatibilityBridge.livelyCallbackProperties(
            projectRoot: project,
            mappedValues: ["gallery": .text("images/gallery-private.png")]
        )
        XCTAssertEqual(lively["gallery"] as? String, "images/gallery-private.png")
        XCTAssertFalse((lively["gallery"] as? String)?.contains(project.path) == true)

        let rejected = WebWallpaperCompatibilityBridge.livelyCallbackProperties(
            projectRoot: project,
            mappedValues: ["gallery": .text("https://example.test/escape.png")]
        )
        XCTAssertTrue(rejected["gallery"] is NSNull)
    }

    func testLivelyFolderDropdownRejectsSandboxOverrideOutsideAuthoredFilter() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-lively-folder-filter-\(UUID().uuidString)")
        let storage = project.appending(path: WebWallpaperUserFileStore.directoryName)
        let images = project.appending(path: "images")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try #"{"file":"index.html","general":{"properties":{"gallery":{"type":"combo","value":"images/default.jpg","backgroundEngineLivelyType":"folderDropdown","backgroundEngineLivelyFolder":"images","backgroundEngineLivelyFilter":"*.jpg","options":[{"label":"Default","value":"images/default.jpg"}]}}}}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        let rejected = images.appending(path: "script.js")
        try Data("alert(1)".utf8).write(to: rejected)
        try JSONEncoder().encode([
            "gallery": "images/\(rejected.lastPathComponent)"
        ]).write(to: storage.appending(path: WebWallpaperUserFileStore.overridesFileName))

        XCTAssertEqual(
            WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: project)["gallery"],
            .text("images/default.jpg")
        )
        XCTAssertEqual(
            WebWallpaperCompatibilityBridge.editableProperties(projectRoot: project).first?.currentValue,
            .text("images/default.jpg")
        )
    }

    func testLivelyFolderDropdownFailsClosedForUnsupportedFilterPattern() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-lively-folder-filter-closed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: project.appending(path: "images"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: project) }
        try #"{"file":"index.html","general":{"properties":{"gallery":{"type":"combo","value":"images/default.jpg","backgroundEngineLivelyType":"folderDropdown","backgroundEngineLivelyFolder":"images","backgroundEngineLivelyFilter":"photo*.jpg"}}}}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)

        let property = try XCTUnwrap(
            WebWallpaperCompatibilityBridge.fileProperties(projectRoot: project).first
        )
        XCTAssertTrue(property.rejectsEveryFile)
        XCTAssertTrue(property.allowedExtensions.isEmpty)
        XCTAssertFalse(property.accepts(URL(filePath: "/tmp/photo.jpg")))
    }

    func testLivelyFolderDropdownCallbackIsRelativeToNestedEntrypoint() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-lively-folder-nested-\(UUID().uuidString)")
        let storage = project.appending(path: WebWallpaperUserFileStore.directoryName)
        let images = project.appending(path: "web/images")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try #"{"file":"web/index.html","general":{"properties":{"gallery":{"type":"combo","value":"images/default.jpg","backgroundEngineLivelyType":"folderDropdown","backgroundEngineLivelyFolder":"web/images","backgroundEngineLivelyFilter":"*.jpg"}}}}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        try Data([1]).write(to: images.appending(path: "custom.jpg"))
        try JSONEncoder().encode(["gallery": "web/images/custom.jpg"])
            .write(to: storage.appending(path: WebWallpaperUserFileStore.overridesFileName))

        let properties = WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: project)
        XCTAssertEqual(properties["gallery"], .text("images/custom.jpg"))
        let lively = WebWallpaperCompatibilityBridge.livelyCallbackProperties(
            projectRoot: project,
            mappedValues: properties
        )
        XCTAssertEqual(lively["gallery"] as? String, "images/custom.jpg")
    }

    func testLivelyFolderDropdownPrivateCopyResolvesAtAuthoredRelativeURL() async throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-lively-folder-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: project.appending(path: "images"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: project) }
        try #"{"file":"index.html","general":{"properties":{"gallery":{"type":"combo","value":"images/default.jpg","backgroundEngineLivelyType":"folderDropdown","backgroundEngineLivelyFolder":"images","backgroundEngineLivelyFilter":"*.jpg"}}}}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        let source = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-lively-alias-source-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: source) }
        let privateBytes = Data("private-lively-bytes".utf8)
        try privateBytes.write(to: source)
        let logicalSelection = try await WebWallpaperUserFileStore()
            .copyLivelyFolderDropdownSelection(
                source,
                propertyName: "gallery",
                projectRelativeFolder: "images",
                allowedExtensions: ["jpg"],
                into: project
            )

        XCTAssertEqual(logicalSelection.lastPathComponent, source.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logicalSelection.path))
        XCTAssertEqual(
            WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: project)["gallery"],
            .text("images/\(source.lastPathComponent)")
        )
        let resolver = try WebProjectResourceResolver(
            projectRoot: project,
            sessionHost: "lively-alias"
        )
        let request = try XCTUnwrap(URL(
            string: "background-engine-web://lively-alias/project/images/\(source.lastPathComponent)"
        ))
        let resolved = try resolver.resolve(request)
        XCTAssertEqual(try Data(contentsOf: resolved.fileURL), privateBytes)
        XCTAssertTrue(resolved.fileURL.path.contains(WebWallpaperUserFileStore.directoryName))
        XCTAssertEqual(
            resolved.projectRelativePathComponents,
            [
                WebWallpaperUserFileStore.directoryName,
                WebWallpaperUserFileStore.folderDropdownFilesDirectoryName,
                resolved.fileURL.lastPathComponent
            ]
        )

        let server = try WebProjectLoopbackServer(
            projectRoot: project,
            networkAccessAllowed: false
        )
        defer { server.stop() }
        let response = try sendRawLoopbackRequest(
            port: server.port,
            request: "GET /\(server.token)/project/images/\(source.lastPathComponent) HTTP/1.1\r\n"
                + "Host: 127.0.0.1:\(server.port)\r\n\r\n"
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"), response)
        XCTAssertEqual(response.components(separatedBy: "\r\n\r\n").last, "private-lively-bytes")
    }

    func testLivelyFolderDropdownKeepsActivePrivateSelectionBeyondOptionCap() async throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-lively-folder-cap-\(UUID().uuidString)")
        let images = project.appending(path: "images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try #"{"file":"index.html","general":{"properties":{"gallery":{"type":"combo","value":"images/0000.jpg","backgroundEngineLivelyType":"folderDropdown","backgroundEngineLivelyFolder":"images","backgroundEngineLivelyFilter":"*.jpg"}}}}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        for index in 0..<1_024 {
            let filename = String(format: "%04d.jpg", index)
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: images.appending(path: filename).path,
                    contents: Data([UInt8(index % 251)])
                )
            )
        }
        let source = URL(filePath: NSTemporaryDirectory())
            .appending(path: "zzzz-selected-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data([9]).write(to: source)
        _ = try await WebWallpaperUserFileStore().copyLivelyFolderDropdownSelection(
            source,
            propertyName: "gallery",
            projectRelativeFolder: "images",
            allowedExtensions: ["jpg"],
            into: project
        )

        let property = try XCTUnwrap(
            WebWallpaperCompatibilityBridge.editableProperties(projectRoot: project).first
        )
        let selectedValue = "images/\(source.lastPathComponent)"
        XCTAssertEqual(property.currentValue, .text(selectedValue))
        XCTAssertEqual(property.options.filter { $0.value == selectedValue }.count, 1)
        XCTAssertEqual(property.options.count, 1_025)
    }

    func testInactivePrivateFolderDropdownCopyDoesNotShadowNewAuthoredFile() async throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-lively-folder-inactive-\(UUID().uuidString)")
        let images = project.appending(path: "images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try #"{"file":"index.html","general":{"properties":{"gallery":{"type":"combo","value":"images/default.jpg","backgroundEngineLivelyType":"folderDropdown","backgroundEngineLivelyFolder":"images","backgroundEngineLivelyFilter":"*.jpg"}}}}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        let source = URL(filePath: NSTemporaryDirectory())
            .appending(path: "update-collision-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("private-old-bytes".utf8).write(to: source)
        let store = WebWallpaperUserFileStore()
        _ = try await store.copyLivelyFolderDropdownSelection(
            source,
            propertyName: "gallery",
            projectRelativeFolder: "images",
            allowedExtensions: ["jpg"],
            into: project
        )
        try await store.saveValueOverrides(
            [:],
            clearingFileSelections: ["gallery"],
            into: project
        )
        let authored = images.appending(path: source.lastPathComponent)
        try Data("authored-new-bytes".utf8).write(to: authored)
        let authoredCallbackValue = "images/\(source.lastPathComponent)"
        try await store.saveValueOverrides(
            ["gallery": .text(authoredCallbackValue)],
            into: project
        )

        XCTAssertNil(
            WebWallpaperCompatibilityBridge.livelyFolderDropdownResourceAliases(
                projectRoot: project
            )[authoredCallbackValue]
        )

        let resolver = try WebProjectResourceResolver(
            projectRoot: project,
            sessionHost: "inactive-lively-alias"
        )
        let request = try XCTUnwrap(URL(
            string: "background-engine-web://inactive-lively-alias/project/images/\(source.lastPathComponent)"
        ))
        let resolved = try resolver.resolve(request)
        XCTAssertEqual(resolved.fileURL, authored.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(resolved.projectRelativePathComponents, ["images", source.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: resolved.fileURL), Data("authored-new-bytes".utf8))
    }

    func testLivelyCallbacksUseMappedFileValuesWithoutExposingHostPaths() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-lively-mapped-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let hostPath = project.appending(path: "private-selected-image.png").path
        let projectObject: [String: Any] = [
            "general": [
                "properties": [
                    "selectedFile": ["type": "file", "value": hostPath]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: projectObject).write(
            to: project.appending(path: "project.json")
        )
        let virtualValue = "http://127.0.0.1:49152/project/private-selected-image.png"

        let livelyProperties = WebWallpaperCompatibilityBridge.livelyCallbackProperties(
            projectRoot: project,
            mappedValues: ["selectedFile": .text(virtualValue)]
        )
        let script = WebWallpaperCompatibilityBridge.bootstrapScript(
            properties: ["selectedFile": .text(virtualValue)],
            livelyProperties: livelyProperties
        )

        XCTAssertEqual(livelyProperties["selectedFile"] as? String, virtualValue)
        XCTAssertFalse(script.contains(hostPath))
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var pendingTimeouts = [];
        var document = { readyState: 'complete' };
        var window = this;
        window.clearInterval = function() {};
        window.setInterval = function() { return 1; };
        window.setTimeout = function(callback) { pendingTimeouts.push(callback); return pendingTimeouts.length; };
        window.addEventListener = function() {};
        """#)
        context.evaluateScript(script)
        context.evaluateScript(#"""
        var selectedFileValue = null;
        window.livelyPropertyListener = function(name, value) {
          if (name === 'selectedFile') selectedFileValue = value;
        };
        while (pendingTimeouts.length > 0) pendingTimeouts.shift()();
        """#)
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("selectedFileValue")?.toString(), virtualValue)

        let source = try String(repositoryFile: "Sources/BackgroundEngineApp/RestrictedWebWallpaperView.swift")
        let remap = try XCTUnwrap(source.range(of: "let mapped = WebWallpaperVirtualURLBridge.remap"))
        let lively = try XCTUnwrap(
            source.range(
                of: "let livelyProperties = WebWallpaperCompatibilityBridge.livelyCallbackProperties",
                range: remap.lowerBound..<source.endIndex
            )
        )
        XCTAssertLessThan(remap.lowerBound, lively.lowerBound)
        XCTAssertTrue(
            source[lively.lowerBound...].prefix(300).contains("mappedValues: properties")
        )
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

    func testExecutionSchedulerFreezesAndResumesAnimationFramesAndTimers() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var window = this;
        window.frames = [];
        window.addEventListener = function() {};
        var nextNativeHandle = 1;
        var nativeFrames = {};
        var nativeTimeouts = {};
        var nativeIntervals = {};
        window.requestAnimationFrame = function(callback) {
          var handle = nextNativeHandle++;
          nativeFrames[handle] = callback;
          return handle;
        };
        window.cancelAnimationFrame = function(handle) { delete nativeFrames[handle]; };
        window.setTimeout = function(callback) {
          var handle = nextNativeHandle++;
          nativeTimeouts[handle] = callback;
          return handle;
        };
        window.clearTimeout = function(handle) { delete nativeTimeouts[handle]; };
        window.setInterval = function(callback) {
          var handle = nextNativeHandle++;
          nativeIntervals[handle] = callback;
          return handle;
        };
        window.clearInterval = function(handle) { delete nativeIntervals[handle]; };
        """#)
        context.evaluateScript(WebWallpaperExecutionScheduler.bootstrapScript)
        XCTAssertNil(
            context.exception,
            "Unexpected scheduler bootstrap exception: \(String(describing: context.exception))"
        )

        context.evaluateScript(#"""
        var frameTicks = 0;
        var timeoutTicks = 0;
        var intervalTicks = 0;
        var crossClearedTimeoutTicks = 0;
        var crossClearedIntervalTicks = 0;
        requestAnimationFrame(function() { frameTicks += 1; });
        setTimeout(function() { timeoutTicks += 1; }, 10);
        setInterval(function() { intervalTicks += 1; }, 20);
        var timeoutClearedAsInterval = setTimeout(function() { crossClearedTimeoutTicks += 1; }, 10);
        var intervalClearedAsTimeout = setInterval(function() { crossClearedIntervalTicks += 1; }, 20);
        clearInterval(timeoutClearedAsInterval);
        clearTimeout(intervalClearedAsTimeout);
        """#)
        XCTAssertEqual(context.evaluateScript("Object.keys(nativeFrames).length")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("Object.keys(nativeTimeouts).length")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("Object.keys(nativeIntervals).length")?.toInt32(), 1)

        context.evaluateScript(WebWallpaperExecutionScheduler.suspensionScript(true))
        XCTAssertEqual(context.evaluateScript("Object.keys(nativeFrames).length")?.toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("Object.keys(nativeTimeouts).length")?.toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("Object.keys(nativeIntervals).length")?.toInt32(), 0)
        context.evaluateScript(#"""
        requestAnimationFrame(function() { frameTicks += 1; });
        setTimeout(function() { timeoutTicks += 10; }, 10);
        """#)
        XCTAssertEqual(context.evaluateScript("Object.keys(nativeFrames).length")?.toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("Object.keys(nativeTimeouts).length")?.toInt32(), 0)

        context.evaluateScript(WebWallpaperExecutionScheduler.suspensionScript(false))
        XCTAssertEqual(context.evaluateScript("Object.keys(nativeFrames).length")?.toInt32(), 2)
        XCTAssertEqual(context.evaluateScript("Object.keys(nativeTimeouts).length")?.toInt32(), 2)
        XCTAssertEqual(context.evaluateScript("Object.keys(nativeIntervals).length")?.toInt32(), 1)
        context.evaluateScript(#"""
        Object.keys(nativeFrames).forEach(function(handle) {
          var callback = nativeFrames[handle];
          delete nativeFrames[handle];
          callback(42);
        });
        Object.keys(nativeTimeouts).forEach(function(handle) {
          var callback = nativeTimeouts[handle];
          delete nativeTimeouts[handle];
          callback();
        });
        Object.keys(nativeIntervals).forEach(function(handle) { nativeIntervals[handle](); });
        """#)
        XCTAssertNil(
            context.exception,
            "Unexpected scheduler resume exception: \(String(describing: context.exception))"
        )
        XCTAssertEqual(context.evaluateScript("frameTicks")?.toInt32(), 2)
        XCTAssertEqual(context.evaluateScript("timeoutTicks")?.toInt32(), 11)
        XCTAssertEqual(context.evaluateScript("intervalTicks")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("crossClearedTimeoutTicks")?.toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("crossClearedIntervalTicks")?.toInt32(), 0)
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

    func testLivelyBridgeDeliversLateGlobalCallbacksAlongsideWallpaperEngineCallbacks() throws {
        let script = WebWallpaperCompatibilityBridge.bootstrapScript(
            properties: [
                "speed": .number(2.5),
                "enabled": .bool(true)
            ]
        )
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var pendingTimeouts = [];
        var intervalCallbacks = [];
        var document = { readyState: 'complete' };
        var window = this;
        window.clearInterval = function(identifier) {
          intervalCallbacks[identifier - 1] = null;
        };
        window.setInterval = function(callback) {
          intervalCallbacks.push(callback);
          return intervalCallbacks.length;
        };
        window.setTimeout = function(callback) {
          pendingTimeouts.push(callback);
          return pendingTimeouts.length;
        };
        window.addEventListener = function() {};
        """#)
        context.evaluateScript(script)
        XCTAssertNil(
            context.exception,
            "Unexpected bridge exception: \(String(describing: context.exception))"
        )
        context.evaluateScript("while (pendingTimeouts.length > 0) pendingTimeouts.shift()();")
        XCTAssertNil(context.exception)

        context.evaluateScript(#"""
        var livelyProperties = [];
        var livelyPlaybackStates = [];
        var livelyAudioEvents = [];
        var livelyTrackPayloads = [];
        var livelySystemPayloads = [];
        var wallpaperEngineProperties = null;
        var wallpaperEnginePausedStates = [];
        window.livelyPropertyListener = function(name, value) {
          livelyProperties.push({ name: name, value: value });
        };
        window.livelyWallpaperPlaybackChanged = function(data) {
          livelyPlaybackStates.push(JSON.parse(data).IsPaused);
        };
        window.livelyAudioListener = function(data) {
          livelyAudioEvents.push({
            length: data.length,
            neutral: data.every(function(value) { return value === 0; })
          });
        };
        window.livelyCurrentTrack = function(data) {
          livelyTrackPayloads.push(data);
        };
        window.livelySystemInformation = function(data) {
          livelySystemPayloads.push({ rawLength: data.length, value: JSON.parse(data) });
        };
        window.wallpaperPropertyListener = {
          applyUserProperties: function(properties) { wallpaperEngineProperties = properties; },
          setPaused: function(paused) { wallpaperEnginePausedStates.push(paused); }
        };
        while (pendingTimeouts.length > 0) pendingTimeouts.shift()();
        var audioCountBeforePause = livelyAudioEvents.length;
        window.__backgroundEngineSetPaused(true);
        intervalCallbacks.filter(Boolean).forEach(function(callback) { callback(); });
        var audioCountWhilePaused = livelyAudioEvents.length;
        window.__backgroundEngineSetPaused(false);
        """#)
        XCTAssertNil(
            context.exception,
            "Unexpected Lively callback exception: \(String(describing: context.exception))"
        )

        let propertiesJSON = try XCTUnwrap(
            context.evaluateScript("JSON.stringify(livelyProperties)")?.toString()
        )
        let properties = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(propertiesJSON.utf8))
                as? [[String: Any]]
        )
        XCTAssertEqual(properties.map { $0["name"] as? String }, ["enabled", "speed"])
        XCTAssertEqual(properties[0]["value"] as? Bool, true)
        XCTAssertEqual(properties[1]["value"] as? Double, 2.5)
        XCTAssertEqual(
            context.evaluateScript("wallpaperEngineProperties.speed.value")?.toDouble(),
            2.5
        )
        XCTAssertEqual(
            context.evaluateScript("JSON.stringify(livelyPlaybackStates)")?.toString(),
            "[false,true,false]"
        )
        XCTAssertEqual(
            context.evaluateScript("JSON.stringify(wallpaperEnginePausedStates)")?.toString(),
            "[false,true,false]"
        )
        XCTAssertGreaterThan(
            context.evaluateScript("audioCountBeforePause")?.toInt32() ?? 0,
            0
        )
        XCTAssertEqual(
            context.evaluateScript("audioCountWhilePaused")?.toInt32(),
            context.evaluateScript("audioCountBeforePause")?.toInt32()
        )
        XCTAssertEqual(
            context.evaluateScript("livelyAudioEvents.every(function(event) { return event.length === 128 && event.neutral; })")?.toBool(),
            true
        )
        XCTAssertEqual(
            context.evaluateScript("JSON.stringify(livelyTrackPayloads)")?.toString(),
            #"["null"]"#
        )
        XCTAssertEqual(
            context.evaluateScript("livelySystemPayloads.length")?.toInt32(),
            1
        )
        XCTAssertEqual(
            context.evaluateScript("livelySystemPayloads[0].rawLength < 512")?.toBool(),
            true
        )
        XCTAssertEqual(
            context.evaluateScript("livelySystemPayloads[0].value.CurrentCpu")?.toDouble(),
            0
        )
        XCTAssertEqual(
            context.evaluateScript("livelySystemPayloads[0].value.CurrentGpu3D")?.toDouble(),
            0
        )
        XCTAssertEqual(
            context.evaluateScript("livelySystemPayloads[0].value.CurrentNetDown")?.toDouble(),
            0
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
        try Data([9]).write(to: gallery.appending(path: "animated.apng"))
        try Data([10]).write(to: random.appending(path: "movie.mp4"))
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
            ["a.png", "animated.apng", "z.png"]
        )
        XCTAssertEqual(directories["random"]?.mode, .onDemand)
        XCTAssertEqual(
            directories["random"]?.files.map { URL(filePath: $0).lastPathComponent },
            ["movie.mp4", "one.webm"]
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
        let outsideImage = root.appending(path: "outside.png")
        try Data([1]).write(to: image)
        try Data([2]).write(to: galleryImage)
        try Data([3]).write(to: outsideImage)
        let handler = try WebProjectURLSchemeHandler(projectRoot: project)

        let mapped = WebWallpaperVirtualURLBridge.remap(
            properties: [
                "photo": .text(image.path),
                "gallery": .text(gallery.path),
                "outside": .text(outsideImage.path),
                "caption": .text(image.path)
            ],
            fileProperties: [
                .init(name: "photo", selectsDirectory: false),
                .init(name: "gallery", selectsDirectory: true),
                .init(name: "outside", selectsDirectory: false),
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
        XCTAssertEqual(mapped.properties["outside"], .text(""))
        XCTAssertEqual(mapped.properties["caption"], .text(image.path))
        XCTAssertTrue(
            try XCTUnwrap(mapped.directories["gallery"]?.files.first)
                .hasPrefix("background-engine-web://")
        )

        let remoteRedacted = WebWallpaperVirtualURLBridge.redactingHostPaths(
            properties: [
                "photo": .text(image.path),
                "gallery": .text(gallery.path),
                "caption": .text(image.path),
            ],
            fileProperties: [
                .init(name: "photo", selectsDirectory: false),
                .init(name: "gallery", selectsDirectory: true),
            ],
            directories: [
                "gallery": .init(mode: .fetchAll, files: [galleryImage.path])
            ]
        )
        XCTAssertEqual(remoteRedacted.properties["photo"], .text(""))
        XCTAssertEqual(remoteRedacted.properties["gallery"], .text(""))
        XCTAssertEqual(remoteRedacted.properties["caption"], .text(image.path))
        XCTAssertEqual(remoteRedacted.directories["gallery"]?.files, [])
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
        let tokenlessURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(server.port)/textures/pixel.svg")
        )
        let (_, tokenlessResponseValue) = try await URLSession.shared.data(from: tokenlessURL)
        XCTAssertEqual(
            (tokenlessResponseValue as? HTTPURLResponse)?.statusCode,
            404,
            "Package-root compatibility must never open a tokenless loopback route."
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

    func testRenewableResponseDeadlineUsesInjectedMonotonicClock() {
        let clock = LockedLoopbackMonotonicClock(initialNanoseconds: 10_000_000_000)
        let deadline = WebProjectLoopbackServer.RenewableMonotonicDeadline(
            timeoutNanoseconds: 5_000_000_000,
            monotonicNanoseconds: clock.now
        )

        XCTAssertEqual(deadline.pollTimeoutMilliseconds, 5_000)
        clock.advance(by: 4_500_000_000)
        XCTAssertEqual(deadline.pollTimeoutMilliseconds, 500)

        deadline.resetAfterProgress()
        XCTAssertEqual(deadline.pollTimeoutMilliseconds, 5_000)
        clock.advance(by: 5_000_000_000)
        XCTAssertNil(deadline.pollTimeoutMilliseconds)

        // Observable progress may arrive after the old deadline when a worker
        // resumes on an already-writable socket. It starts a fresh idle window.
        deadline.resetAfterProgress()
        XCTAssertEqual(deadline.pollTimeoutMilliseconds, 5_000)
        clock.advance(by: 4_999_999_999)
        XCTAssertEqual(deadline.pollTimeoutMilliseconds, 1)
        clock.advance(by: 1)
        XCTAssertNil(deadline.pollTimeoutMilliseconds)
    }

    func testLoopbackPollClassificationBacksOffForWriteHangupWithoutSpinning() {
        XCTAssertEqual(
            WebProjectLoopbackServer.pollReadinessAction(
                requestedEvents: Int16(POLLOUT),
                returnedEvents: Int16(POLLHUP)
            ),
            .backOffBeforeAttempt
        )
        XCTAssertEqual(
            WebProjectLoopbackServer.pollReadinessAction(
                requestedEvents: Int16(POLLOUT),
                returnedEvents: Int16(POLLOUT)
            ),
            .attemptIO
        )
        XCTAssertEqual(
            WebProjectLoopbackServer.pollReadinessAction(
                requestedEvents: Int16(POLLIN),
                returnedEvents: Int16(POLLHUP)
            ),
            .attemptIO
        )
        XCTAssertEqual(
            WebProjectLoopbackServer.pollReadinessAction(
                requestedEvents: Int16(POLLOUT),
                returnedEvents: Int16(POLLNVAL) | Int16(POLLOUT)
            ),
            .fail
        )
    }

    func testLoopbackLargeHalfClosedResponseCompletesWithoutTimingAssumptions() throws {
        let project = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-loopback-half-close-response-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let payload = Data(repeating: 0x5A, count: 1_024 * 1_024)
        try payload.write(to: project.appending(path: "large.bin"))
        let server = try WebProjectLoopbackServer(
            projectRoot: project,
            networkAccessAllowed: false,
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

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw CocoaError(.fileReadUnknown) }
            response.append(buffer, count: count)
        }

        let headerBoundary = try XCTUnwrap(
            response.range(of: Data("\r\n\r\n".utf8))
        )
        let header = String(decoding: response[..<headerBoundary.lowerBound], as: UTF8.self)
        let body = Data(response[headerBoundary.upperBound...])
        XCTAssertTrue(header.hasPrefix("HTTP/1.1 206 Partial Content"), header)
        XCTAssertEqual(body, payload)
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
            "http://0x7f.0.0.1:9/resource",
            "ws://127.0x0.0.1:9/socket",
            "http://localhost.:9/resource",
            "http://[::]:9/resource",
            "http://[::0.0.0.0]:9/resource",
            "http://[::0.0.0.1]:9/resource",
            "http://[::ffff:127.0.0.1]:9/resource",
            "http://[0::ffff:127.0.0.1]:9/resource",
            "http://[::0:0:ffff:127.0.0.1]:9/resource",
            "http://[0:0:0:0:0:ffff:127.0.0.1]:9/resource",
            "http://[fe80::1%25en0]:9/resource",
            "http://[fc00::192.168.1.1]:9/resource",
            "ws://[fd12:3456::10.0.0.1]:9/socket",
            "http://[fe80::169.254.1.1]:9/resource",
            "ws://[0:0::0:1]:9/socket",
            "ws://[0:0:0:0:0:0:0:1]:9/socket"
        ] {
            let candidate = try XCTUnwrap(URL(string: privateURL))
            XCTAssertTrue(
                WebWallpaperNetworkPolicy.isBlockedExternalURL(candidate),
                "The compatibility classifier and runtime policy must agree: \(privateURL)"
            )
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
            "wss://1.1.1.1/socket",
            "https://[2001:db8:ffff::1]/resource",
            "https://0xdead.beef/resource",
            "https://1.0xdead.beef/resource"
        ] {
            let candidate = try XCTUnwrap(URL(string: publicLiteralURL))
            XCTAssertFalse(
                WebWallpaperNetworkPolicy.isBlockedExternalURL(candidate),
                "The compatibility classifier and runtime policy must agree: \(publicLiteralURL)"
            )
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
                "Public IP literals and DNS hosts must remain available: \(publicLiteralURL)"
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

    func testFileURLCompatibilityBridgeNormalizesOnlyExactPassiveProjectCapabilities() throws {
        let context = try makeFileURLCompatibilityContext()
        let token = String(repeating: "a", count: 64)
        let prefix = try XCTUnwrap(
            URL(string: "http://127.0.0.1:54321/\(token)/project/")
        )
        let script = WebWallpaperFileURLCompatibilityBridge.bootstrapScript(
            trustedProjectURLPrefix: prefix
        )
        context.evaluateScript(script)
        XCTAssertNil(context.exception, "Unexpected bridge exception: \(String(describing: context.exception))")

        context.evaluateScript(#"""
        var trustedResource = trustedProjectPrefix + 'folder/photo%20one.png';
        var wrappedResource = 'file:///' + trustedResource;
        var trustedDirectory = trustedProjectPrefix + 'folder/';
        var wrappedDirectory = 'file:///' + trustedDirectory;
        var image = new HTMLImageElement();
        image.src = wrappedResource;
        var audio = new HTMLMediaElement('audio');
        audio.src = wrappedResource;
        var video = new HTMLVideoElement();
        video.src = wrappedResource;
        video.poster = wrappedResource;
        var source = new HTMLSourceElement();
        source.src = wrappedResource;
        var attributeImage = new HTMLImageElement();
        attributeImage.setAttribute('SRC', wrappedResource);
        var observedImage = new HTMLImageElement();
        originalElementSetAttribute.call(observedImage, 'src', wrappedResource);
        mutationCallback([{ type: 'attributes', target: observedImage }]);
        var directoryImage = new HTMLImageElement();
        directoryImage.src = wrappedDirectory;

        var style = new CSSStyleDeclaration();
        style.backgroundImage = 'URL( "' + wrappedResource + '" )';
        style.setProperty(
          'background',
          'linear-gradient(red, blue), url(' + wrappedResource + ')'
        );
        var styledElement = new Element('div');
        styledElement.setAttribute('style', 'background-image: url(\'' + wrappedResource + '\')');

        window.fetch(wrappedResource, { cache: 'no-store' });
        var requestLike = { url: wrappedResource };
        window.fetch(requestLike);
        var xhr = new window.XMLHttpRequest();
        xhr.open('GET', wrappedResource, true, 'user', 'password');

        var spoofedScript = new Element('script');
        spoofedScript.tagName = 'IMG';
        spoofedScript.setAttribute('src', wrappedResource);
        var iframe = new Element('iframe');
        iframe.setAttribute('src', wrappedResource);

        // Lively Web projects use one leading slash for the package root.
        // This is the exact resource pattern used by Simple System 3D.
        var rootRelativeResource = '/textures/icons8-no-image-100.png';
        var expectedRootRelativeResource = trustedProjectPrefix
          + 'textures/icons8-no-image-100.png';
        var rootRelativeImage = new HTMLImageElement();
        rootRelativeImage.src = rootRelativeResource;
        var rootRelativeAttributeImage = new HTMLImageElement();
        rootRelativeAttributeImage.setAttribute('src', rootRelativeResource);
        var rootRelativeStyle = new CSSStyleDeclaration();
        rootRelativeStyle.backgroundImage = 'url("' + rootRelativeResource + '")';
        var rootRelativeScript = new HTMLScriptElement();
        rootRelativeScript.src = '/js/chunk.js';
        var rootRelativeLink = new HTMLLinkElement();
        rootRelativeLink.setAttribute('href', '/css/chunk.css');
        var rootRelativeFrame = new HTMLIFrameElement();
        rootRelativeFrame.src = '/frames/chunk.html';
        var wrappedExecutableScript = new HTMLScriptElement();
        wrappedExecutableScript.src = wrappedResource;
        window.fetch('/data/config.json?theme=dark#current');
        var rootRelativeXHR = new window.XMLHttpRequest();
        rootRelativeXHR.open('GET', '/data/config.json?theme=dark', true);
        """#)
        XCTAssertNil(context.exception, "Unexpected sink exception: \(String(describing: context.exception))")
        XCTAssertEqual(context.evaluateScript("image.src")?.toString(), context.evaluateScript("trustedResource")?.toString())
        XCTAssertEqual(context.evaluateScript("audio.src")?.toString(), context.evaluateScript("trustedResource")?.toString())
        XCTAssertEqual(context.evaluateScript("video.src")?.toString(), context.evaluateScript("trustedResource")?.toString())
        XCTAssertEqual(context.evaluateScript("video.poster")?.toString(), context.evaluateScript("trustedResource")?.toString())
        XCTAssertEqual(context.evaluateScript("source.src")?.toString(), context.evaluateScript("trustedResource")?.toString())
        XCTAssertEqual(
            context.evaluateScript("attributeImage.getAttribute('src')")?.toString(),
            context.evaluateScript("trustedResource")?.toString()
        )
        XCTAssertEqual(
            context.evaluateScript("observedImage.getAttribute('src')")?.toString(),
            context.evaluateScript("trustedResource")?.toString()
        )
        XCTAssertEqual(
            context.evaluateScript("directoryImage.src")?.toString(),
            context.evaluateScript("trustedDirectory")?.toString()
        )
        XCTAssertFalse(context.evaluateScript("style.backgroundImage.includes('file:///')")?.toBool() == true)
        XCTAssertFalse(context.evaluateScript("style.values.background.includes('file:///')")?.toBool() == true)
        XCTAssertFalse(
            context.evaluateScript("styledElement.getAttribute('style').includes('file:///')")?.toBool() == true
        )
        XCTAssertEqual(
            context.evaluateScript("fetchCalls[0].input")?.toString(),
            context.evaluateScript("trustedResource")?.toString()
        )
        XCTAssertTrue(context.evaluateScript("fetchCalls[1].input === requestLike")?.toBool() == true)
        XCTAssertEqual(context.evaluateScript("xhr.openArguments.length")?.toInt32(), 5)
        XCTAssertEqual(
            context.evaluateScript("xhr.openArguments[1]")?.toString(),
            context.evaluateScript("trustedResource")?.toString()
        )
        XCTAssertEqual(
            context.evaluateScript("spoofedScript.getAttribute('src')")?.toString(),
            context.evaluateScript("wrappedResource")?.toString()
        )
        XCTAssertEqual(
            context.evaluateScript("iframe.getAttribute('src')")?.toString(),
            context.evaluateScript("wrappedResource")?.toString()
        )
        XCTAssertEqual(
            context.evaluateScript("rootRelativeImage.src")?.toString(),
            context.evaluateScript("expectedRootRelativeResource")?.toString()
        )
        XCTAssertEqual(
            context.evaluateScript("rootRelativeAttributeImage.getAttribute('src')")?.toString(),
            context.evaluateScript("expectedRootRelativeResource")?.toString()
        )
        XCTAssertTrue(
            context.evaluateScript(
                "rootRelativeStyle.backgroundImage.includes(trustedProjectPrefix)"
            )?.toBool() == true
        )
        XCTAssertEqual(
            context.evaluateScript("rootRelativeScript.src")?.toString(),
            "http://127.0.0.1:54321/\(token)/project/js/chunk.js"
        )
        XCTAssertEqual(
            context.evaluateScript("rootRelativeLink.href")?.toString(),
            "http://127.0.0.1:54321/\(token)/project/css/chunk.css"
        )
        XCTAssertEqual(
            context.evaluateScript("rootRelativeFrame.src")?.toString(),
            "http://127.0.0.1:54321/\(token)/project/frames/chunk.html"
        )
        XCTAssertEqual(
            context.evaluateScript("wrappedExecutableScript.src")?.toString(),
            context.evaluateScript("wrappedResource")?.toString(),
            "Executable sinks must never unwrap file:/// capability wrappers."
        )
        XCTAssertEqual(
            context.evaluateScript("fetchCalls[2].input")?.toString(),
            "http://127.0.0.1:54321/\(token)/project/data/config.json?theme=dark#current"
        )
        XCTAssertEqual(
            context.evaluateScript("rootRelativeXHR.openArguments[1]")?.toString(),
            "http://127.0.0.1:54321/\(token)/project/data/config.json?theme=dark"
        )

        context.evaluateScript(#"""
        var wrongToken = 'file:///' + trustedProjectPrefix.replace(
          '/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/',
          '/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/'
        ) + 'photo.png';
        var badValues = [
          'file:///tmp/photo.png',
          'FILE:///' + trustedProjectPrefix + 'photo.png',
          'file:///file:///' + trustedProjectPrefix + 'photo.png',
          'file:///http://127.0.0.1:54322/' + trustedToken + '/project/photo.png',
          wrongToken,
          'file:///http://localhost:54321/' + trustedToken + '/project/photo.png',
          'file:///https://127.0.0.1:54321/' + trustedToken + '/project/photo.png',
          'file:///http://user@127.0.0.1:54321/' + trustedToken + '/project/photo.png',
          'file:///http://127.0.0.1:54321/' + trustedToken + '/projectish/photo.png',
          'file:///http://127.0.0.1:54321/' + trustedToken
            + '/__background_engine_prepared/video/project/photo.png',
          'file:///' + trustedProjectPrefix + '../escape.png',
          'file:///' + trustedProjectPrefix + '%2e%2e/escape.png',
          'file:///' + trustedProjectPrefix + 'folder/%2Fescape.png',
          'file:///' + trustedProjectPrefix + 'folder/%5Cescape.png',
          'file:///' + trustedProjectPrefix + 'folder//escape.png',
          'file:///' + trustedProjectPrefix + 'folder/photo.png?cache=1',
          'file:///' + trustedProjectPrefix + 'folder/photo.png#frame',
          '//cdn.example.test/photo.png',
          '/../escape.png',
          '/%2e%2e/escape.png',
          '/folder/%2Fescape.png',
          '/folder/%5Cescape.png',
          '/folder//escape.png'
        ];
        var badResults = badValues.map(function(value) {
          var candidate = new HTMLImageElement();
          candidate.src = value;
          return candidate.src === value;
        });
        var badCSS = new CSSStyleDeclaration();
        badCSS.backgroundImage = 'url("' + badValues[10] + '")';
        var badCSSUnchanged = badCSS.backgroundImage === 'url("' + badValues[10] + '")';

        Object.defineProperty(TestURL.prototype, 'pathname', {
          configurable: true,
          get: function() { return '/' + trustedToken + '/project/forged.png'; }
        });
        Object.defineProperty(TestURL.prototype, 'origin', {
          configurable: true,
          get: function() { return 'http://127.0.0.1:54321'; }
        });
        String.prototype.startsWith = function() { return true; };
        window.decodeURIComponent = function() { return 'safe.png'; };
        var tamperCandidate = 'file:///' + trustedProjectPrefix + 'folder/../../escape.png';
        var tamperImage = new HTMLImageElement();
        tamperImage.src = tamperCandidate;
        var tamperRejected = tamperImage.src === tamperCandidate;
        """#)
        XCTAssertNil(context.exception, "Unexpected negative-case exception: \(String(describing: context.exception))")
        XCTAssertTrue(context.evaluateScript("badResults.every(Boolean)")?.toBool() == true)
        XCTAssertTrue(context.evaluateScript("badCSSUnchanged")?.toBool() == true)
        XCTAssertTrue(context.evaluateScript("tamperRejected")?.toBool() == true)
        XCTAssertEqual(
            context.evaluateScript(
                "Object.getOwnPropertyDescriptor(window, '__backgroundEngineFileURLCompatibilityBridgeInstalled').writable"
            )?.toBool(),
            false
        )

        context.evaluateScript(script)
        XCTAssertNil(context.exception, "Duplicate bridge installation must be a no-op")
    }

    func testFileURLCompatibilityBridgeComposesBeforePreparedMediaBridge() throws {
        let context = try makeFileURLCompatibilityContext()
        let token = String(repeating: "a", count: 64)
        let prefix = try XCTUnwrap(
            URL(string: "http://127.0.0.1:54321/\(token)/project/")
        )
        context.evaluateScript(
            WebWallpaperFileURLCompatibilityBridge.bootstrapScript(
                trustedProjectURLPrefix: prefix
            )
        )
        context.evaluateScript(
            WebWallpaperMediaSourceBridge.bootstrapScript(
                preparedKindsByPath: ["/\(token)/project/clip.avi": "video"]
            )
        )
        context.evaluateScript(#"""
        var legacySource = new HTMLSourceElement();
        legacySource.setAttribute('type', 'video/x-msvideo');
        legacySource.src = 'file:///' + trustedProjectPrefix + 'clip.avi';
        """#)

        XCTAssertNil(context.exception, "Unexpected bridge-composition exception: \(String(describing: context.exception))")
        XCTAssertTrue(
            context.evaluateScript("legacySource.getAttribute('type') === null")?.toBool() == true
        )
        XCTAssertEqual(
            context.evaluateScript("legacySource.getAttribute('src')")?.toString(),
            "http://127.0.0.1:54321/\(token)/__background_engine_prepared/video/project/clip.avi.__background_engine_prepared.mp4"
        )
    }

    func testFileURLCompatibilityBridgeRejectsNoncanonicalSwiftCapability() throws {
        let shortToken = try XCTUnwrap(
            URL(string: "http://127.0.0.1:54321/not-a-session/project/")
        )
        let wrongHost = try XCTUnwrap(
            URL(string: "http://localhost:54321/\(String(repeating: "a", count: 64))/project/")
        )

        XCTAssertFalse(
            WebWallpaperFileURLCompatibilityBridge.bootstrapScript(
                trustedProjectURLPrefix: shortToken
            ).contains("__backgroundEngineFileURLCompatibilityBridgeInstalled")
        )
        XCTAssertFalse(
            WebWallpaperFileURLCompatibilityBridge.bootstrapScript(
                trustedProjectURLPrefix: wrongHost
            ).contains("__backgroundEngineFileURLCompatibilityBridgeInstalled")
        )
    }

    @MainActor
    func testLocalLivelyPackageRootImageLoadsOnlyThroughAuthenticatedProjectOrigin() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-lively-root-\(UUID().uuidString)")
        let textures = root.appending(path: "textures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: textures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1" fill="white"/></svg>"#
            .write(
                to: textures.appending(path: "pixel.svg"),
                atomically: true,
                encoding: .utf8
            )
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <!doctype html><title>waiting</title>
        <script>
        const image = new Image();
        image.onload = () => { document.title = 'lively-root-ready'; };
        image.onerror = () => { document.title = 'lively-root-failed'; };
        image.src = '/textures/pixel.svg';
        </script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

        let view = RestrictedWebWallpaperView(
            url: entrypoint,
            readAccessURL: root,
            frame: CGRect(x: 0, y: 0, width: 320, height: 180)
        )
        defer { view.prepareForClose() }
        let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        var title = ""
        for _ in 0..<240 {
            if let value = try? await webView.evaluateJavaScript("document.title"),
               let current = value as? String {
                title = current
                if current == "lively-root-ready" || current == "lively-root-failed" { break }
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(title, "lively-root-ready")
        let scripts = webView.configuration.userContentController.userScripts
        XCTAssertEqual(
            scripts.filter {
                $0.source.contains("__backgroundEngineFileURLCompatibilityBridgeInstalled")
            }.count,
            1,
            "Local Web projects need the package-root bridge even without file properties."
        )
    }

    @MainActor
    func testUntrustedDataSubframeCannotActivateOrInferProjectCapabilityBridge() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-untrusted-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = #"""
        <!doctype html><script>
        const image = new Image();
        image.src = '/known-local-file.png';
        const installed = Boolean(window.__backgroundEngineFileURLCompatibilityBridgeInstalled);
        const leaked = image.src.includes('127.0.0.1') || image.src.includes('/project/');
        parent.postMessage(installed || leaked ? 'untrusted-frame-leaked' : 'untrusted-frame-clean', '*');
        </script>
        """#
        let encodedChild = Data(child.utf8).base64EncodedString()
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <!doctype html><title>waiting-untrusted-frame</title>
        <script>addEventListener('message', event => { document.title = event.data; });</script>
        <iframe src="data:text/html;base64,\#(encodedChild)"></iframe>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

        let view = RestrictedWebWallpaperView(
            url: entrypoint,
            readAccessURL: root,
            frame: CGRect(x: 0, y: 0, width: 320, height: 180)
        )
        defer { view.prepareForClose() }
        let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        var title = ""
        for _ in 0..<240 {
            if let value = try? await webView.evaluateJavaScript("document.title"),
               let current = value as? String {
                title = current
                if current.hasPrefix("untrusted-frame-") { break }
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(title, "untrusted-frame-clean")
    }

    @MainActor
    func testImportedLivelyPackageRootModuleLoadsThroughAuthenticatedProjectOrigin() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-lively-module-\(UUID().uuidString)")
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let site = source.appending(path: "site", directoryHint: .isDirectory)
        let scripts = source.appending(path: "js", directoryHint: .isDirectory)
        let library = root.appending(path: "library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"Title":"Module Root","Type":1,"FileName":"site/index.html","IsAbsolutePath":false}"#
            .write(
                to: source.appending(path: "LivelyInfo.json"),
                atomically: true,
                encoding: .utf8
            )
        try #"""
        <!doctype html><title>waiting-module</title>
        <script type="module">
        import title from "/js/app.js";
        document.title = title;
        </script>
        """#.write(
            to: site.appending(path: "index.html"),
            atomically: true,
            encoding: .utf8
        )
        try "export default 'lively-module-ready';".write(
            to: scripts.appending(path: "app.js"),
            atomically: true,
            encoding: .utf8
        )
        let asset = try await LivelyWallpaperPackageImporter(
            store: LibraryStore(root: library)
        ).importAndPrepare(source)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(asset.compatibilityReport?.level, .full)

        let entrypoint = URL(filePath: try XCTUnwrap(asset.entrypoint))
        let projectRoot = URL(filePath: asset.projectDirectory, directoryHint: .isDirectory)
        let view = RestrictedWebWallpaperView(
            url: entrypoint,
            readAccessURL: projectRoot,
            frame: CGRect(x: 0, y: 0, width: 320, height: 180)
        )
        defer { view.prepareForClose() }
        let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        var title = ""
        for _ in 0..<240 {
            if let value = try? await webView.evaluateJavaScript("document.title"),
               let current = value as? String {
                title = current
                if current == "lively-module-ready" { break }
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(title, "lively-module-ready")
        let staged = try String(contentsOf: entrypoint, encoding: .utf8)
        XCTAssertTrue(staged.contains(#"from "../js/app.js""#))
    }

    @MainActor
    func testImportedLivelyNestedFrameLoadsStaticCSSModuleAndDynamicRootImage() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-lively-frame-\(UUID().uuidString)")
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let frames = source.appending(path: "frames", directoryHint: .isDirectory)
        let scripts = source.appending(path: "js", directoryHint: .isDirectory)
        let styles = source.appending(path: "css", directoryHint: .isDirectory)
        let textures = source.appending(path: "textures", directoryHint: .isDirectory)
        let library = root.appending(path: "library", directoryHint: .isDirectory)
        for directory in [frames, scripts, styles, textures] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"Title":"Nested Root","Type":1,"FileName":"index.html","IsAbsolutePath":false}"#
            .write(
                to: source.appending(path: "LivelyInfo.json"),
                atomically: true,
                encoding: .utf8
            )
        try #"""
        <!doctype html><title>waiting-frame</title>
        <script>
        addEventListener('message', event => { document.title = event.data; });
        </script>
        <iframe src="/frames/child.html"></iframe>
        """#.write(
            to: source.appending(path: "index.html"),
            atomically: true,
            encoding: .utf8
        )
        try #"""
        <!doctype html>
        <link rel="stylesheet" href="/css/frame.css">
        <script type="module">
        import ready from "/js/frame.js";
        const dynamicScript = document.createElement('script');
        dynamicScript.onload = () => {
          const image = new Image();
          image.onload = () => {
            const color = getComputedStyle(document.documentElement).color;
            const suffix = window.dynamicScriptReady ? '' : ':dynamic-missing';
            parent.postMessage(ready + ':' + color + suffix, '*');
          };
          image.onerror = () => parent.postMessage('frame-image-failed', '*');
          image.src = '/textures/pixel.svg';
        };
        dynamicScript.onerror = () => parent.postMessage('frame-script-failed', '*');
        dynamicScript.src = '/js/dynamic.js';
        document.head.append(dynamicScript);
        </script>
        """#.write(
            to: frames.appending(path: "child.html"),
            atomically: true,
            encoding: .utf8
        )
        try "export default 'frame-ready';".write(
            to: scripts.appending(path: "frame.js"),
            atomically: true,
            encoding: .utf8
        )
        try "window.dynamicScriptReady = true;".write(
            to: scripts.appending(path: "dynamic.js"),
            atomically: true,
            encoding: .utf8
        )
        try ":root { color: rgb(1, 2, 3); }".write(
            to: styles.appending(path: "frame.css"),
            atomically: true,
            encoding: .utf8
        )
        try #"<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1" fill="white"/></svg>"#
            .write(
                to: textures.appending(path: "pixel.svg"),
                atomically: true,
                encoding: .utf8
            )

        let asset = try await LivelyWallpaperPackageImporter(
            store: LibraryStore(root: library)
        ).importAndPrepare(source)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(asset.compatibilityReport?.level, .full)
        let entrypoint = URL(filePath: try XCTUnwrap(asset.entrypoint))
        let projectRoot = URL(filePath: asset.projectDirectory, directoryHint: .isDirectory)
        let stagedChild = try String(
            contentsOf: projectRoot.appending(path: "frames/child.html"),
            encoding: .utf8
        )
        XCTAssertTrue(stagedChild.contains(#"href="../css/frame.css""#))
        XCTAssertTrue(stagedChild.contains(#"from "../js/frame.js""#))

        let view = RestrictedWebWallpaperView(
            url: entrypoint,
            readAccessURL: projectRoot,
            frame: CGRect(x: 0, y: 0, width: 320, height: 180)
        )
        defer { view.prepareForClose() }
        let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        var title = ""
        for _ in 0..<240 {
            if let value = try? await webView.evaluateJavaScript("document.title"),
               let current = value as? String {
                title = current
                if current.hasPrefix("frame-ready:")
                    || current == "frame-image-failed"
                    || current == "frame-script-failed" {
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(title, "frame-ready:rgb(1, 2, 3)")
        let fileBridge = try XCTUnwrap(
            webView.configuration.userContentController.userScripts.first {
                $0.source.contains("__backgroundEngineFileURLCompatibilityBridgeInstalled")
            }
        )
        XCTAssertFalse(fileBridge.isForMainFrameOnly)
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
    func testRestrictedViewLoadsWrappedFileAndDirectoryPropertiesBeforeLaterBridges() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "background-engine-web-file-url-compatibility-\(UUID().uuidString)")
        let storage = root.appending(path: WebWallpaperUserFileStore.directoryName)
        let gallery = storage.appending(path: "gallery")
        let random = storage.appending(path: "random")
        try FileManager.default.createDirectory(at: gallery, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: random, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try XCTUnwrap(
            Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )
        )
        let photo = storage.appending(path: "photo.png")
        try png.write(to: photo)
        try png.write(to: gallery.appending(path: "gallery.png"))
        try png.write(to: random.appending(path: "random.png"))
        try #"""
        {"general":{"properties":{
          "photo":{"type":"file","value":""},
          "gallery":{"type":"directory","mode":"fetchall","value":""},
          "random":{"type":"directory","mode":"ondemand","value":""}
        }}}
        """#.write(
            to: root.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        try JSONEncoder().encode([
            "photo": "\(WebWallpaperUserFileStore.directoryName)/photo.png",
            "gallery": "\(WebWallpaperUserFileStore.directoryName)/gallery",
            "random": "\(WebWallpaperUserFileStore.directoryName)/random"
        ]).write(to: storage.appending(path: WebWallpaperUserFileStore.overridesFileName))
        let entrypoint = root.appending(path: "index.html")
        try #"""
        <!doctype html>
        <title>pending</title>
        <script>
        (() => {
          const state = window.propertyCompatibilityState = {
            photo: false,
            gallery: false,
            random: false,
            fetch: false,
            xhr: false,
            css: false,
            sources: [],
            error: null
          };
          const wrapped = value => 'file:///' + value;
          const update = () => {
            if (state.error) {
              document.title = 'failed-' + state.error;
              return;
            }
            if (state.photo && state.gallery && state.random
                && state.fetch && state.xhr && state.css) document.title = 'properties-ready';
          };
          const fail = name => {
            state.error = String(name);
            update();
          };
          const loadImage = (name, value) => {
            const image = new Image();
            image.onload = () => {
              state[name] = true;
              state.sources.push(image.src);
              update();
            };
            image.onerror = () => fail(name);
            image.src = wrapped(value);
          };
          const exerciseOtherSinks = value => {
            fetch(wrapped(value)).then(response => {
              if (!response.ok) throw new Error('status-' + response.status);
              return response.arrayBuffer();
            }).then(bytes => {
              if (bytes.byteLength === 0) throw new Error('empty');
              state.fetch = true;
              update();
            }).catch(() => fail('fetch'));
            const request = new XMLHttpRequest();
            request.responseType = 'arraybuffer';
            request.onload = () => {
              if (request.status !== 200 || !request.response || request.response.byteLength === 0) {
                fail('xhr');
                return;
              }
              state.xhr = true;
              update();
            };
            request.onerror = () => fail('xhr');
            request.open('GET', wrapped(value), true);
            request.send();
            const element = document.createElement('div');
            element.style.backgroundImage = 'url("' + wrapped(value) + '")';
            document.body.appendChild(element);
            setTimeout(() => {
              const serialized = element.getAttribute('style') || '';
              state.css = serialized.includes('http://127.0.0.1:')
                && !serialized.includes('file:///');
              if (!state.css) fail('css');
              update();
            }, 0);
          };
          window.wallpaperPropertyListener = {
            applyUserProperties: properties => {
              loadImage('photo', properties.photo.value);
              exerciseOtherSinks(properties.photo.value);
              window.wallpaperRequestRandomFileForProperty('random', (_name, value) => {
                loadImage('random', value);
              });
            },
            userDirectoryFilesAddedOrChanged: (name, files) => {
              if (name === 'gallery' && files.length > 0) loadImage('gallery', files[0]);
            }
          };
        })();
        </script>
        """#.write(to: entrypoint, atomically: true, encoding: .utf8)

        let view = RestrictedWebWallpaperView(
            url: entrypoint,
            readAccessURL: root,
            frame: CGRect(x: 0, y: 0, width: 320, height: 180)
        )
        defer { view.prepareForClose() }
        let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        var title = ""
        for _ in 0..<240 {
            if let value = try? await webView.evaluateJavaScript("document.title"),
               let current = value as? String {
                title = current
                if current == "properties-ready" || current.hasPrefix("failed-") { break }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let state = try? await webView.evaluateJavaScript(
            "JSON.stringify(window.propertyCompatibilityState || null)"
        )
        XCTAssertEqual(title, "properties-ready", "Property compatibility state: \(state ?? "unavailable")")
        let evaluatedSources = try await webView.evaluateJavaScript(
            "window.propertyCompatibilityState.sources"
        )
        let sources = try XCTUnwrap(evaluatedSources as? [String])
        XCTAssertEqual(sources.count, 3)
        XCTAssertTrue(sources.allSatisfy { source in
            source.hasPrefix("http://127.0.0.1:") && !source.contains("file:///")
        })

        let scripts = webView.configuration.userContentController.userScripts
        let shimIndex = try XCTUnwrap(scripts.firstIndex {
            $0.source.contains("__backgroundEngineFileURLCompatibilityBridgeInstalled")
        })
        let propertyIndex = try XCTUnwrap(scripts.firstIndex {
            $0.source.contains("wallpaperRequestRandomFileForProperty")
        })
        let mediaIndex = try XCTUnwrap(scripts.firstIndex {
            $0.source.contains("__backgroundEngineMediaSourceBridgeInstalled")
        })
        let audioIndex = try XCTUnwrap(scripts.firstIndex {
            $0.source.contains("__backgroundEngineApplyAudioPolicy")
        })
        XCTAssertLessThan(shimIndex, propertyIndex)
        XCTAssertLessThan(propertyIndex, mediaIndex)
        XCTAssertLessThan(mediaIndex, audioIndex)
        XCTAssertFalse(scripts[shimIndex].isForMainFrameOnly)
        XCTAssertTrue(scripts[propertyIndex].isForMainFrameOnly)
        XCTAssertFalse(scripts[mediaIndex].isForMainFrameOnly)
        XCTAssertFalse(scripts[audioIndex].isForMainFrameOnly)
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
        XCTAssertFalse(
            registeredScripts.contains {
                $0.contains("__backgroundEngineFileURLCompatibilityBridgeInstalled")
            },
            "Remote websites must never receive a local loopback capability shim."
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
        let truncated = try XCTUnwrap(
            WebMediaPreparationWarningPresentation.make(
                failureCount: 0,
                noticeCount: 1,
                allLocalPreparationFailed: false
            )
        )
        XCTAssertTrue(truncated.automaticallyDismisses)
        XCTAssertTrue(truncated.message.contains("safety limit"))
        XCTAssertFalse(truncated.message.contains("could not be prepared"))
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
        for blocked in [
            "http://192.168.1.10/texture.png",
            "https://service.local/texture.png",
            "ws://100.64.0.1/socket",
            "http://[fe80::1]/texture.png"
        ] {
            XCTAssertFalse(
                RestrictedWebNavigationPolicy.allows(
                    URL(string: blocked),
                    projectRoot: root,
                    isMainFrame: false,
                    networkAccessAllowed: true
                ),
                "Network opt-in must not grant private-network access: \(blocked)"
            )
        }
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
        XCTAssertTrue(source.contains("WebWallpaperExecutionScheduler.bootstrapScript"))
        XCTAssertTrue(source.contains("WebWallpaperExecutionScheduler.suspensionScript(suspended)"))
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
    func testBundledLivelyWallpapersRenderNonBlankRestrictedWebFrames() async throws {
        // A live WKWebView snapshot needs an app-hosted WindowServer session.
        // Keep the normal headless SwiftPM suite deterministic; release and
        // local GUI smoke jobs opt in explicitly and save the six frames.
        guard ProcessInfo.processInfo.environment[
            "BACKGROUND_ENGINE_RUN_LIVELY_VISUAL_SMOKE"
        ] == "1" else {
            return
        }
        let sourceRoot = URL(
            filePath: testRepositoryPath(
                "Sources/BackgroundEngineApp/Resources/LivelyWallpapers"
            ),
            directoryHint: .isDirectory
        )
        let wallpaperIDs = [
            "lively-the-hill",
            "lively-periodic-table",
            "lively-parallax",
            "lively-music-tv",
            "lively-depth-observatory",
            "lively-chromatic-fluids"
        ]

        // Collection integrity, licensing, import and idempotency are covered
        // by BundledWallpaperCollectionTests. This test intentionally loads the
        // exact immutable project bytes directly so visual smoke remains fast
        // enough to run in CI instead of re-hashing/copying the 26 MiB corpus.
        try await assertLivelyProjectsRenderNonBlankFrames(wallpaperIDs.map {
            (id: $0, root: sourceRoot.appending(path: $0, directoryHint: .isDirectory))
        })
    }

    @MainActor
    func testOfficialLivelyReleaseWallpapersRenderNonBlankRestrictedWebFrames() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BACKGROUND_ENGINE_RUN_OFFICIAL_LIVELY_VISUAL_SMOKE"] == "1" else {
            return
        }
        let corpusPath = try XCTUnwrap(
            environment["BACKGROUND_ENGINE_OFFICIAL_LIVELY_ARCHIVE_DIR"],
            "Official visual smoke requires the nine pinned release ZIPs outside Git."
        )
        XCTAssertFalse(corpusPath.isEmpty)
        let corpus = URL(filePath: corpusPath, directoryHint: .isDirectory)
        let root = FileManager.default.temporaryDirectory.appending(
            path: "background-engine-official-lively-visual-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root.appending(path: "Library"))
        var projects: [(id: String, root: URL)] = []
        XCTAssertEqual(OfficialLivelyWallpaperCatalog.wallpapers.count, 9)
        let requestedWallpaperID = environment[
            "BACKGROUND_ENGINE_OFFICIAL_LIVELY_VISUAL_ID"
        ]
        let wallpapers = OfficialLivelyWallpaperCatalog.wallpapers.filter {
            requestedWallpaperID == nil || $0.id == requestedWallpaperID
        }
        XCTAssertFalse(wallpapers.isEmpty, "The requested official Lively wallpaper is not pinned.")
        for wallpaper in wallpapers {
            // The service owns/removes its download. Never hand it the user's
            // corpus file; hash verification and import run on a private copy.
            let download = root.appending(path: wallpaper.archiveFileName)
            try FileManager.default.copyItem(
                at: corpus.appending(path: wallpaper.archiveFileName), to: download
            )
            let response = try XCTUnwrap(HTTPURLResponse(
                url: wallpaper.downloadURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(wallpaper.archiveByteCount)]
            ))
            let service = OfficialLivelyWallpaperDownloadService(
                store: store,
                catalog: [wallpaper],
                downloader: { _ in (download, response) }
            )
            let asset = try await service.downloadAndImport(wallpaper)
            XCTAssertEqual(asset.kind, .web, wallpaper.id)
            XCTAssertEqual(asset.supportStatus, .playable, wallpaper.id)
            projects.append((
                id: wallpaper.id,
                root: URL(filePath: asset.projectDirectory, directoryHint: .isDirectory)
            ))
        }
        try await assertLivelyProjectsRenderNonBlankFrames(projects)
    }

    @MainActor
    private func assertLivelyProjectsRenderNonBlankFrames(
        _ projects: [(id: String, root: URL)]
    ) async throws {
        _ = NSApplication.shared
        for (assetID, projectRoot) in projects {
            let projectData = try Data(contentsOf: projectRoot.appending(path: "project.json"))
            let project = try XCTUnwrap(
                JSONSerialization.jsonObject(with: projectData) as? [String: Any],
                assetID
            )
            XCTAssertEqual(project["type"] as? String, "web", assetID)
            let entrypoint = projectRoot.appending(
                path: try XCTUnwrap(project["file"] as? String, assetID)
            )
            let view = RestrictedWebWallpaperView(
                url: entrypoint,
                readAccessURL: projectRoot,
                frame: CGRect(x: 0, y: 0, width: 640, height: 360)
            )
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFrontRegardless()
            view.layoutSubtreeIfNeeded()
            defer {
                view.prepareForClose()
                window.contentView = nil
                view.removeFromSuperview()
                window.orderOut(nil)
                window.close()
            }

            let webView = try XCTUnwrap(
                view.subviews.compactMap { $0 as? WKWebView }.first,
                assetID
            )
            // RestrictedWebWallpaperView first prepares local media and
            // compiles a content rule list asynchronously. `about:blank` is
            // already complete during that work, so waiting on isLoading
            // alone can snapshot the initial empty document. Require the
            // authenticated loopback entrypoint before accepting completion.
            var finishedLoading = false
            var readyState = ""
            for _ in 0..<400 {
                let currentURL = webView.url
                let reachedEntrypoint = currentURL?.scheme == "http"
                    && currentURL?.host == "127.0.0.1"
                    && currentURL?.lastPathComponent == entrypoint.lastPathComponent
                if reachedEntrypoint, !webView.isLoading,
                   let currentReadyState = try? await evaluateJavaScriptString(
                       "document.readyState",
                       in: webView
                   ) {
                    readyState = currentReadyState
                    if currentReadyState == "complete" {
                        finishedLoading = true
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(
                finishedLoading,
                "\(assetID) did not finish its authenticated loopback load in 10 seconds; "
                    + "lastLocation=\(sanitizedWebLocation(webView.url)), "
                    + "readyState=\(readyState)"
            )
            XCTAssertEqual(readyState, "complete", assetID)
            if assetID == "rocksdanister-audiorbits-v1.0.0.0" {
                // AudiOrbits intentionally shows a timed photosensitivity
                // warning before fading in its canvas. Never let that warning
                // image satisfy the non-blank visual check by itself.
                var canvasIsVisible = false
                for _ in 0..<240 {
                    canvasIsVisible = (try? await evaluateJavaScriptString(
                        "String(document.querySelector('#mainCvs')?.classList.contains('show') === true)",
                        in: webView
                    )) == "true"
                    if canvasIsVisible { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                XCTAssertTrue(canvasIsVisible, "AudiOrbits did not finish its safety warning.")
                // Its authored title card remains above the live canvas for
                // seven more seconds. Wait until the primary orbit animation
                // is the content being judged by the snapshot assertions.
                try await Task.sleep(for: .seconds(8))
            }
            // A document-ready event does not mean that an asynchronous GLTF,
            // Draco/WASM or large texture has produced its first frame. Poll
            // the actual restricted-runtime surface forty times at 250 ms
            // intervals; each WebKit snapshot also has its own timeout. This
            // still fails closed on a permanently empty/placeholder page.
            var snapshot = try await takeWebSnapshot(webView)
            var report = try analyzeWebSnapshot(snapshot)
            for _ in 0..<40 where report.opaquePixelCount <= 1_000
                || report.luminanceRange <= 12
                || report.quantizedColorCount <= 8 {
                try await Task.sleep(for: .milliseconds(250))
                snapshot = try await takeWebSnapshot(webView)
                report = try analyzeWebSnapshot(snapshot)
            }
            var usedOpaqueSnapshotFallback = false
            if report.opaquePixelCount <= 1_000 {
                // Plash deliberately makes its WKWebView background
                // transparent. WKSnapshotConfiguration can consequently
                // return an entirely transparent image for an otherwise
                // visible page on an app-hosted XCTest window. Retry with an
                // opaque WebKit snapshot surface; the luminance/color checks
                // below still reject a blank white or black frame.
                webView.setValue(true, forKey: "drawsBackground")
                usedOpaqueSnapshotFallback = true
                try await Task.sleep(for: .milliseconds(250))
                snapshot = try await takeWebSnapshot(webView)
                report = try analyzeWebSnapshot(snapshot)
            }
            let pageReport = (try? await evaluateJavaScriptString(
                "JSON.stringify({canvasCount:document.querySelectorAll('canvas').length,"
                    + "resourceCount:performance.getEntriesByType('resource').length,"
                    + "loadedGLTF:performance.getEntriesByType('resource').some(entry=>entry.name.endsWith('.glb'))"
                    + ",loadedWASM:performance.getEntriesByType('resource').some(entry=>entry.name.endsWith('.wasm'))})",
                in: webView
            )) ?? "unavailable"
            let diagnostic = "\(assetID): \(report), "
                + "windowNumber=\(window.windowNumber), "
                + "windowVisible=\(window.isVisible), "
                + "windowOcclusion=\(window.occlusionState.rawValue), "
                + "opaqueSnapshotFallback=\(usedOpaqueSnapshotFallback), "
                + "page=\(pageReport)"
            XCTAssertGreaterThan(report.opaquePixelCount, 1_000, diagnostic)
            XCTAssertGreaterThan(report.luminanceRange, 12, diagnostic)
            XCTAssertGreaterThan(report.quantizedColorCount, 8, diagnostic)
            try saveLivelySnapshotIfRequested(snapshot, assetID: assetID)
            FileHandle.standardOutput.write(Data("Lively visual frame \(assetID): \(report)\n".utf8))
        }
    }

    @MainActor
    private func evaluateJavaScriptString(_ source: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let gate = WebJavaScriptCompletionGate()
            webView.evaluateJavaScript(source) { value, error in
                if let error {
                    gate.resume(.failure(error), continuation: continuation)
                } else if let value = value as? String {
                    gate.resume(.success(value), continuation: continuation)
                } else {
                    gate.resume(
                        .failure(CocoaError(.propertyListReadCorrupt)),
                        continuation: continuation
                    )
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                gate.resume(.failure(URLError(.timedOut)), continuation: continuation)
            }
        }
    }

    private func sanitizedWebLocation(_ url: URL?) -> String {
        guard let url else { return "nil" }
        return "scheme=\(url.scheme ?? "nil"),host=\(url.host ?? "nil"),"
            + "port=\(url.port.map(String.init) ?? "nil")"
    }

    @MainActor
    private func takeWebSnapshot(_ webView: WKWebView) async throws -> NSImage {
        let snapshot: SendableWebSnapshot = try await withCheckedThrowingContinuation { continuation in
            let gate = WebSnapshotCompletionGate()
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            configuration.snapshotWidth = 640
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    gate.resume(.failure(error), continuation: continuation)
                } else if let image {
                    gate.resume(
                        .success(SendableWebSnapshot(image: image)),
                        continuation: continuation
                    )
                } else {
                    gate.resume(
                        .failure(CocoaError(.fileReadUnknown)),
                        continuation: continuation
                    )
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                gate.resume(
                    .failure(URLError(.timedOut)),
                    continuation: continuation
                )
            }
        }
        return snapshot.image
    }

    private struct WebSnapshotPixelReport: CustomStringConvertible {
        let opaquePixelCount: Int
        let luminanceRange: Int
        let quantizedColorCount: Int

        var description: String {
            "opaque=\(opaquePixelCount), luminanceRange=\(luminanceRange), "
                + "colors=\(quantizedColorCount)"
        }
    }

    private func analyzeWebSnapshot(_ image: NSImage) throws -> WebSnapshotPixelReport {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let width = 64
        let height = 36
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw CocoaError(.fileReadCorruptFile) }

        var opaquePixelCount = 0
        var minimumLuminance = 255
        var maximumLuminance = 0
        var quantizedColors = Set<UInt16>()
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            let alpha = Int(pixels[offset + 3])
            guard alpha > 16 else { continue }
            opaquePixelCount += 1
            let luminance = (54 * red + 183 * green + 19 * blue) >> 8
            minimumLuminance = min(minimumLuminance, luminance)
            maximumLuminance = max(maximumLuminance, luminance)
            quantizedColors.insert(
                UInt16((red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4))
            )
        }
        return WebSnapshotPixelReport(
            opaquePixelCount: opaquePixelCount,
            luminanceRange: max(0, maximumLuminance - minimumLuminance),
            quantizedColorCount: quantizedColors.count
        )
    }

    private func saveLivelySnapshotIfRequested(_ image: NSImage, assetID: String) throws {
        guard let rawDirectory = ProcessInfo.processInfo.environment[
            "BACKGROUND_ENGINE_LIVELY_SNAPSHOT_DIR"
        ], !rawDirectory.isEmpty else {
            return
        }
        let directory = URL(filePath: rawDirectory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: directory.appending(path: "\(assetID).png"), options: .atomic)
    }

    private func makeFileURLCompatibilityContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var trustedToken = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        var trustedProjectPrefix = 'http://127.0.0.1:54321/' + trustedToken + '/project/';
        function TestURL(source) {
          var value = String(source);
          var match = value.match(/^([A-Za-z]+:)\/\/([^\/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/);
          if (!match) throw new TypeError('Invalid URL');
          this._protocol = match[1].toLowerCase();
          var authority = match[2];
          this._username = '';
          this._password = '';
          var at = authority.lastIndexOf('@');
          if (at >= 0) {
            var credentials = authority.substring(0, at);
            authority = authority.substring(at + 1);
            var credentialSeparator = credentials.indexOf(':');
            if (credentialSeparator >= 0) {
              this._username = credentials.substring(0, credentialSeparator);
              this._password = credentials.substring(credentialSeparator + 1);
            } else {
              this._username = credentials;
            }
          }
          var portSeparator = authority.lastIndexOf(':');
          this._hostname = (portSeparator >= 0
            ? authority.substring(0, portSeparator)
            : authority).toLowerCase();
          this._port = portSeparator >= 0 ? authority.substring(portSeparator + 1) : '';
          this._query = match[4] || '';
          this._fragment = match[5] || '';
          this._setPathname(match[3] || '/');
        }
        TestURL.prototype._setPathname = function(value) {
          var rawPath = String(value || '/');
          if (rawPath.charAt(0) !== '/') rawPath = '/' + rawPath;
          var parts = rawPath.split('/');
          var normalized = [];
          for (var index = 1; index < parts.length; index += 1) {
            var part = parts[index];
            var decoded = part;
            try { decoded = decodeURIComponent(part); } catch (_) {}
            if (decoded === '.') continue;
            if (decoded === '..') {
              if (normalized.length > 0) normalized.pop();
              continue;
            }
            normalized.push(part);
          }
          this._pathname = '/' + normalized.join('/');
          if (rawPath.endsWith('/') && !this._pathname.endsWith('/')) this._pathname += '/';
        };
        Object.defineProperties(TestURL.prototype, {
          protocol: { configurable: true, get: function() { return this._protocol; } },
          hostname: { configurable: true, get: function() { return this._hostname; } },
          port: { configurable: true, get: function() { return this._port; } },
          username: { configurable: true, get: function() { return this._username; } },
          password: { configurable: true, get: function() { return this._password; } },
          host: {
            configurable: true,
            get: function() { return this._hostname + (this._port ? ':' + this._port : ''); }
          },
          origin: {
            configurable: true,
            get: function() { return this._protocol + '//' + this.host; }
          },
          pathname: {
            configurable: true,
            get: function() { return this._pathname; },
            set: function(value) { this._setPathname(value); }
          },
          href: {
            configurable: true,
            get: function() { return this.origin + this._pathname + this._query + this._fragment; }
          }
        });

        function Element(localName, attributes) {
          this._localName = String(localName || 'div').toLowerCase();
          this.tagName = this._localName.toUpperCase();
          this.attributes = attributes || {};
          this.sources = [];
        }
        Object.defineProperties(Element.prototype, {
          localName: {
            configurable: true,
            get: function() { return this._localName; }
          },
          namespaceURI: {
            configurable: true,
            get: function() { return 'http://www.w3.org/1999/xhtml'; }
          }
        });
        Element.prototype.getAttribute = function(name) {
          var key = String(name).toLowerCase();
          return Object.prototype.hasOwnProperty.call(this.attributes, key)
            ? this.attributes[key]
            : null;
        };
        Element.prototype.setAttribute = function(name, value) {
          this.attributes[String(name).toLowerCase()] = String(value);
        };
        Element.prototype.removeAttribute = function(name) {
          delete this.attributes[String(name).toLowerCase()];
        };
        Element.prototype.querySelectorAll = function() { return this.sources || []; };
        var originalElementSetAttribute = Element.prototype.setAttribute;

        function installElementSubclass(constructor, parent) {
          constructor.prototype = Object.create(parent.prototype);
          constructor.prototype.constructor = constructor;
        }
        function HTMLImageElement(attributes) { Element.call(this, 'img', attributes); }
        installElementSubclass(HTMLImageElement, Element);
        Object.defineProperty(HTMLImageElement.prototype, 'src', {
          configurable: true,
          enumerable: true,
          get: function() { return this.getAttribute('src') || ''; },
          set: function(value) { originalElementSetAttribute.call(this, 'src', value); }
        });
        function HTMLMediaElement(localName, attributes) {
          Element.call(this, localName || 'audio', attributes);
        }
        installElementSubclass(HTMLMediaElement, Element);
        Object.defineProperty(HTMLMediaElement.prototype, 'src', {
          configurable: true,
          enumerable: true,
          get: function() { return this.getAttribute('src') || ''; },
          set: function(value) { originalElementSetAttribute.call(this, 'src', value); }
        });
        HTMLMediaElement.prototype.querySelectorAll = function() { return this.sources || []; };
        HTMLMediaElement.prototype.load = function() {};
        HTMLMediaElement.prototype.play = function() { return 'played'; };
        function HTMLVideoElement(attributes) { HTMLMediaElement.call(this, 'video', attributes); }
        installElementSubclass(HTMLVideoElement, HTMLMediaElement);
        Object.defineProperty(HTMLVideoElement.prototype, 'poster', {
          configurable: true,
          enumerable: true,
          get: function() { return this.getAttribute('poster') || ''; },
          set: function(value) { originalElementSetAttribute.call(this, 'poster', value); }
        });
        function HTMLSourceElement(attributes) { Element.call(this, 'source', attributes); }
        installElementSubclass(HTMLSourceElement, Element);
        Object.defineProperty(HTMLSourceElement.prototype, 'src', {
          configurable: true,
          enumerable: true,
          get: function() { return this.getAttribute('src') || ''; },
          set: function(value) { originalElementSetAttribute.call(this, 'src', value); }
        });
        function HTMLScriptElement(attributes) { Element.call(this, 'script', attributes); }
        installElementSubclass(HTMLScriptElement, Element);
        Object.defineProperty(HTMLScriptElement.prototype, 'src', {
          configurable: true,
          enumerable: true,
          get: function() { return this.getAttribute('src') || ''; },
          set: function(value) { originalElementSetAttribute.call(this, 'src', value); }
        });
        function HTMLLinkElement(attributes) { Element.call(this, 'link', attributes); }
        installElementSubclass(HTMLLinkElement, Element);
        Object.defineProperty(HTMLLinkElement.prototype, 'href', {
          configurable: true,
          enumerable: true,
          get: function() { return this.getAttribute('href') || ''; },
          set: function(value) { originalElementSetAttribute.call(this, 'href', value); }
        });
        function HTMLIFrameElement(attributes) { Element.call(this, 'iframe', attributes); }
        installElementSubclass(HTMLIFrameElement, Element);
        Object.defineProperty(HTMLIFrameElement.prototype, 'src', {
          configurable: true,
          enumerable: true,
          get: function() { return this.getAttribute('src') || ''; },
          set: function(value) { originalElementSetAttribute.call(this, 'src', value); }
        });

        function CSSStyleDeclaration() { this.values = {}; this._cssText = ''; }
        CSSStyleDeclaration.prototype.setProperty = function(name, value, priority) {
          this.values[String(name)] = String(value);
          this.priority = priority;
        };
        Object.defineProperties(CSSStyleDeclaration.prototype, {
          cssText: {
            configurable: true,
            get: function() { return this._cssText; },
            set: function(value) { this._cssText = String(value); }
          },
          background: {
            configurable: true,
            get: function() { return this.values.background || ''; },
            set: function(value) { this.values.background = String(value); }
          },
          backgroundImage: {
            configurable: true,
            get: function() { return this.values.backgroundImage || ''; },
            set: function(value) { this.values.backgroundImage = String(value); }
          }
        });
        function XMLHttpRequest() { this.openArguments = null; }
        XMLHttpRequest.prototype.open = function() {
          this.openArguments = Array.prototype.slice.call(arguments);
        };
        var fetchCalls = [];
        function nativeFetch(input, options) {
          fetchCalls.push({ input: input, options: options });
          return { input: input, options: options };
        }
        function Document() { this.elements = []; }
        Document.prototype.querySelectorAll = function() { return this.elements; };
        function DocumentFragment() { this.elements = []; }
        DocumentFragment.prototype.querySelectorAll = function() { return this.elements; };
        var document = new Document();
        document.baseURI = trustedProjectPrefix + 'index.html';
        var mutationCallback = null;
        function MutationObserver(callback) { mutationCallback = callback; }
        MutationObserver.prototype.observe = function() {};
        var window = {
          URL: TestURL,
          MutationObserver: MutationObserver,
          HTMLImageElement: HTMLImageElement,
          HTMLMediaElement: HTMLMediaElement,
          HTMLSourceElement: HTMLSourceElement,
          HTMLVideoElement: HTMLVideoElement,
          HTMLScriptElement: HTMLScriptElement,
          HTMLLinkElement: HTMLLinkElement,
          HTMLIFrameElement: HTMLIFrameElement,
          CSSStyleDeclaration: CSSStyleDeclaration,
          XMLHttpRequest: XMLHttpRequest,
          Document: Document,
          DocumentFragment: DocumentFragment,
          Element: Element,
          fetch: nativeFetch,
          decodeURIComponent: decodeURIComponent,
          location: { href: trustedProjectPrefix + 'index.html' }
        };
        window.parent = window;
        """#)
        if let exception = context.exception {
            throw NSError(
                domain: "RestrictedWebWallpaperViewTests.JavaScript",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: exception.toString() ?? "Unknown JS error"]
            )
        }
        return context
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

private final class LockedLoopbackMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64

    init(initialNanoseconds: UInt64) {
        nanoseconds = initialNanoseconds
    }

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return nanoseconds
    }

    func advance(by delta: UInt64) {
        lock.lock()
        nanoseconds += delta
        lock.unlock()
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

/// WebKit's snapshot callback is not guaranteed to arrive when a test host has
/// no WindowServer-backed display. Resolve exactly once so the visual smoke
/// fails with a useful timeout instead of hanging the entire test process.
private final class WebSnapshotCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isResolved = false

    func resume(
        _ result: Result<SendableWebSnapshot, Error>,
        continuation: CheckedContinuation<SendableWebSnapshot, Error>
    ) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        lock.unlock()
        switch result {
        case .success(let snapshot): continuation.resume(returning: snapshot)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

/// NSImage predates Swift concurrency. WebKit creates this immutable test
/// snapshot on the main thread and all consumers return to the MainActor.
private struct SendableWebSnapshot: @unchecked Sendable {
    let image: NSImage
}

private final class WebJavaScriptCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isResolved = false

    func resume(
        _ result: Result<String, Error>,
        continuation: CheckedContinuation<String, Error>
    ) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        lock.unlock()
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
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
