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

    func testPropertyBridgeProvidesNeutralAudioAndPauseCallbacks() {
        let script = WebWallpaperCompatibilityBridge.bootstrapScript(
            properties: ["enabled": .bool(true)]
        )

        XCTAssertTrue(script.contains("wallpaperRegisterAudioListener"))
        XCTAssertTrue(script.contains("applyUserProperties"))
        XCTAssertTrue(script.contains("applyGeneralProperties"))
        XCTAssertTrue(script.contains("setPaused"))
        XCTAssertTrue(script.contains("new Array(128).fill(0)"))
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
