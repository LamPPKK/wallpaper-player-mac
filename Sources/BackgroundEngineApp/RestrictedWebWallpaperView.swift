import AppKit
import BackgroundEngineCore
import WebKit

enum WebWallpaperPropertyValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case text(String)

    var jsonObject: Any {
        switch self {
        case .bool(let value): value
        case .number(let value): value
        case .text(let value): value
        }
    }
}

enum WebWallpaperCompatibilityBridge {
    struct FileProperty: Identifiable, Equatable {
        let name: String
        let selectsDirectory: Bool
        var id: String { name }
    }

    static func defaultProperties(projectRoot: URL) -> [String: WebWallpaperPropertyValue] {
        let projectJSON = projectRoot.appending(path: "project.json")
        guard let data = try? Data(contentsOf: projectJSON),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        let general = root["general"] as? [String: Any]
        let rawProperties = (general?["properties"] as? [String: Any])
            ?? (root["properties"] as? [String: Any])
            ?? [:]
        var properties = rawProperties.reduce(into: [String: WebWallpaperPropertyValue]()) { result, item in
            guard let descriptor = item.value as? [String: Any],
                  let type = descriptor["type"] as? String,
                  let value = descriptor["value"],
                  let property = propertyValue(type: type, value: value) else {
                return
            }
            result[item.key] = property
        }
        let overridesURL = projectRoot
            .appending(path: WebWallpaperUserFileStore.directoryName)
            .appending(path: WebWallpaperUserFileStore.overridesFileName)
        if let data = try? Data(contentsOf: overridesURL),
           let overrides = try? JSONDecoder().decode([String: String].self, from: data) {
            for (name, relativePath) in overrides {
                let candidate = projectRoot.appending(path: relativePath).standardizedFileURL
                let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
                let resolved = candidate.resolvingSymlinksInPath()
                guard resolved.pathComponents.starts(with: root.pathComponents),
                      resolved.pathComponents.count > root.pathComponents.count else { continue }
                properties[name] = .text(candidate.path)
            }
        }
        return properties
    }

    static func fileProperties(projectRoot: URL) -> [FileProperty] {
        let projectJSON = projectRoot.appending(path: "project.json")
        guard let data = try? Data(contentsOf: projectJSON),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let general = root["general"] as? [String: Any]
        let raw = (general?["properties"] as? [String: Any])
            ?? (root["properties"] as? [String: Any])
            ?? [:]
        return raw.compactMap { name, value in
            guard let descriptor = value as? [String: Any],
                  let type = (descriptor["type"] as? String)?.lowercased(),
                  type == "file" || type == "directory" else { return nil }
            return FileProperty(name: name, selectsDirectory: type == "directory")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func bootstrapScript(
        properties: [String: WebWallpaperPropertyValue],
        framesPerSecond: Int = 30
    ) -> String {
        let payload = properties.mapValues { ["value": $0.jsonObject] }
        let propertyJSON = jsonString(payload)
        let generalJSON = jsonString(["fps": max(1, framesPerSecond)])
        return #"""
        (() => {
          'use strict';
          const userProperties = \#(propertyJSON);
          const generalProperties = \#(generalJSON);
          let neutralAudioTimer = null;
          window.wallpaperRegisterAudioListener = (listener) => {
            if (neutralAudioTimer !== null) window.clearInterval(neutralAudioTimer);
            if (typeof listener !== 'function') return;
            const neutral = new Array(128).fill(0);
            listener(neutral);
            neutralAudioTimer = window.setInterval(() => listener(neutral), 1000 / 30);
          };
          const applyProperties = () => {
            const listener = window.wallpaperPropertyListener;
            if (!listener) return;
            if (typeof listener.applyUserProperties === 'function') {
              listener.applyUserProperties(userProperties);
            }
            if (typeof listener.applyGeneralProperties === 'function') {
              listener.applyGeneralProperties(generalProperties);
            }
          };
          window.__backgroundEngineSetPaused = (paused) => {
            const listener = window.wallpaperPropertyListener;
            if (listener && typeof listener.setPaused === 'function') listener.setPaused(Boolean(paused));
          };
          window.addEventListener('DOMContentLoaded', () => window.setTimeout(applyProperties, 0), { once: true });
          window.setTimeout(applyProperties, 100);
        })();
        """#
    }

    private static func propertyValue(type: String, value: Any) -> WebWallpaperPropertyValue? {
        switch type.lowercased() {
        case "bool", "boolean":
            if let bool = value as? Bool { return .bool(bool) }
            if let number = value as? NSNumber { return .bool(number.boolValue) }
            if let string = value as? String { return .bool(["1", "true", "yes"].contains(string.lowercased())) }
        case "slider":
            if let number = value as? NSNumber { return .number(number.doubleValue) }
            if let string = value as? String, let number = Double(string) { return .number(number) }
        case "color", "combo", "text", "file", "directory":
            if let string = value as? String { return .text(string) }
        default:
            return nil
        }
        return nil
    }

    private static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

enum RestrictedWebNavigationPolicy {
    static func allows(
        _ candidate: URL?,
        projectRoot: URL,
        isMainFrame: Bool,
        networkAccessAllowed: Bool,
        isDownload: Bool = false
    ) -> Bool {
        guard !isDownload, let candidate else { return false }
        if candidate.isFileURL {
            let rootComponents = projectRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            let candidateComponents = candidate.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard candidateComponents.count > rootComponents.count else { return false }
            return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
        }
        return networkAccessAllowed
            && !isMainFrame
            && ["https", "http"].contains(candidate.scheme?.lowercased() ?? "")
    }
}

@MainActor
final class RestrictedWebWallpaperView: NSView, WKNavigationDelegate, PausableWallpaperContent {
    private let webView: WKWebView
    private let url: URL
    private let readAccessURL: URL
    private let networkAccessAllowed: Bool
    private var failureLabel: NSTextField?

    init(url: URL, readAccessURL: URL, frame: CGRect, networkAccessAllowed: Bool = false) {
        self.url = url
        self.readAccessURL = readAccessURL
        self.networkAccessAllowed = networkAccessAllowed
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false
        let properties = WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: readAccessURL)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WebWallpaperCompatibilityBridge.bootstrapScript(properties: properties),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        webView = WKWebView(frame: frame, configuration: configuration)
        super.init(frame: frame)
        webView.navigationDelegate = self
        addSubview(webView)
        if networkAccessAllowed {
            loadProject()
        } else {
            installRemoteBlockerAndLoad()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    func setPlaybackSuspended(_ suspended: Bool) {
        let command = suspended
            ? "window.__backgroundEngineSetPaused?.(true); document.querySelectorAll('video,audio').forEach((item) => item.pause())"
            : "window.__backgroundEngineSetPaused?.(false); document.querySelectorAll('video,audio').forEach((item) => item.play().catch(() => {}))"
        webView.evaluateJavaScript(command)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let allowed = RestrictedWebNavigationPolicy.allows(
            navigationAction.request.url,
            projectRoot: readAccessURL,
            isMainFrame: navigationAction.targetFrame?.isMainFrame != false,
            networkAccessAllowed: networkAccessAllowed,
            isDownload: navigationAction.shouldPerformDownload
        )
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure("This Web wallpaper could not be loaded: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure("This Web wallpaper could not be loaded: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showFailure("The Web wallpaper process stopped unexpectedly. Replay the wallpaper to retry.")
    }

    private func installRemoteBlockerAndLoad() {
        let rules = #"""
        [{"trigger":{"url-filter":"^https?://.*|^wss?://.*"},"action":{"type":"block"}}]
        """#
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "dev.3xhaust.Background Engine.BlockRemote",
            encodedContentRuleList: rules
        ) { [weak self] ruleList, error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                guard error == nil, let ruleList else {
                    self.showFailure(
                        "Background Engine could not install the offline Web security rules. "
                            + "Enable network access for this wallpaper or replay it to retry."
                    )
                    return
                }
                self.webView.configuration.userContentController.add(ruleList)
                self.loadProject()
            }
        }
    }

    private func loadProject() {
        webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
    }

    private func showFailure(_ message: String) {
        failureLabel?.removeFromSuperview()
        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.7)
        ])
        failureLabel = label
    }

}
