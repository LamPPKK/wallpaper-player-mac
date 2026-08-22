import AppKit
import BackgroundEngineCore
import PlashRuntime
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
    enum DirectoryMode: String, Equatable, Sendable {
        case onDemand = "ondemand"
        case fetchAll = "fetchall"
    }

    struct DirectoryPropertyFiles: Equatable, Sendable {
        let mode: DirectoryMode
        let files: [String]
    }

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

    static func directoryProperties(projectRoot: URL) -> [String: DirectoryPropertyFiles] {
        let projectJSON = projectRoot.appending(path: "project.json")
        guard let data = try? Data(contentsOf: projectJSON),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        let general = root["general"] as? [String: Any]
        let raw = (general?["properties"] as? [String: Any])
            ?? (root["properties"] as? [String: Any])
            ?? [:]
        let overridesURL = projectRoot
            .appending(path: WebWallpaperUserFileStore.directoryName)
            .appending(path: WebWallpaperUserFileStore.overridesFileName)
        let overrides: [String: String]
        if let data = try? Data(contentsOf: overridesURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            overrides = decoded
        } else {
            overrides = [:]
        }

        return raw.reduce(into: [String: DirectoryPropertyFiles]()) { result, item in
            guard let descriptor = item.value as? [String: Any],
                  (descriptor["type"] as? String)?.lowercased() == "directory" else {
                return
            }
            let mode = (descriptor["mode"] as? String)?.lowercased() == DirectoryMode.fetchAll.rawValue
                ? DirectoryMode.fetchAll
                : DirectoryMode.onDemand
            let allowedExtensions = (descriptor["fileType"] as? String)?.lowercased() == "video"
                ? videoDirectoryExtensions
                : imageDirectoryExtensions
            let files: [String]
            if let relativePath = overrides[item.key],
               let directory = safeOverride(relativePath, projectRoot: projectRoot),
               (try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
                .map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true {
                files = safeRegularFiles(
                    in: directory,
                    projectRoot: projectRoot,
                    allowedExtensions: allowedExtensions
                )
            } else {
                files = []
            }
            result[item.key] = DirectoryPropertyFiles(mode: mode, files: files)
        }
    }

    static func bootstrapScript(
        properties: [String: WebWallpaperPropertyValue],
        directories: [String: DirectoryPropertyFiles] = [:],
        framesPerSecond: Int = 30
    ) -> String {
        let payload = properties.mapValues { ["value": $0.jsonObject] }
        let propertyJSON = jsonString(payload)
        let directoryPayload = directories.mapValues {
            ["mode": $0.mode.rawValue, "files": $0.files] as [String: Any]
        }
        let directoryJSON = jsonString(directoryPayload)
        let generalJSON = jsonString(["fps": max(1, framesPerSecond)])
        return #"""
        (() => {
          'use strict';
          const userProperties = \#(propertyJSON);
          const directoryProperties = \#(directoryJSON);
          const fetchAllProperties = new Set(
            Object.entries(directoryProperties)
              .filter(([, property]) => property.mode === 'fetchall')
              .map(([name]) => name)
          );
          for (const name of fetchAllProperties) delete userProperties[name];
          const generalProperties = \#(generalJSON);
          let neutralAudioTimer = null;
          let currentPausedState = false;
          let lastAppliedListener = null;
          const isDOMReady = () => typeof document === 'undefined' || document.readyState !== 'loading';
          const safelyInvoke = (listener, callback, argumentsList) => {
            if (typeof callback !== 'function') return true;
            try {
              callback.apply(listener, argumentsList);
              return true;
            } catch (_) {
              return false;
            }
          };
          window.wallpaperRegisterAudioListener = (listener) => {
            if (neutralAudioTimer !== null) window.clearInterval(neutralAudioTimer);
            if (typeof listener !== 'function') return;
            const neutral = new Array(128).fill(0);
            if (!currentPausedState) listener(neutral);
            neutralAudioTimer = window.setInterval(() => {
              if (!currentPausedState) listener(neutral);
            }, 1000 / 30);
          };
          window.wallpaperRequestRandomFileForProperty = (propertyName, callback) => {
            const property = directoryProperties[propertyName];
            if (typeof callback !== 'function' || !property || property.mode !== 'ondemand') return;
            const files = property.files || [];
            const selected = files.length > 0
              ? files[Math.floor(Math.random() * files.length)]
              : '';
            callback(propertyName, selected);
          };
          const applyProperties = () => {
            if (!isDOMReady()) return false;
            const listener = window.wallpaperPropertyListener;
            if (!listener) return false;
            if (listener === lastAppliedListener) return true;
            let delivered = safelyInvoke(listener, listener.applyUserProperties, [userProperties]);
            delivered = safelyInvoke(listener, listener.applyGeneralProperties, [generalProperties]) && delivered;
            if (typeof listener.userDirectoryFilesAddedOrChanged === 'function') {
              for (const name of fetchAllProperties) {
                delivered = safelyInvoke(
                  listener,
                  listener.userDirectoryFilesAddedOrChanged,
                  [name, directoryProperties[name].files || []]
                ) && delivered;
              }
            }
            delivered = safelyInvoke(listener, listener.setPaused, [currentPausedState]) && delivered;
            if (delivered) lastAppliedListener = listener;
            return delivered;
          };
          window.__backgroundEngineSetPaused = (paused) => {
            currentPausedState = Boolean(paused);
            if (!isDOMReady()) return;
            const listener = window.wallpaperPropertyListener;
            if (listener) safelyInvoke(listener, listener.setPaused, [currentPausedState]);
          };
          window.addEventListener('DOMContentLoaded', applyProperties, { once: true });
          let listenerProbeAttempts = 0;
          const probeForListener = () => {
            applyProperties();
            listenerProbeAttempts += 1;
            if (listenerProbeAttempts < 100) window.setTimeout(probeForListener, 100);
          };
          window.setTimeout(probeForListener, 0);
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
        case "color", "combo", "text", "textinput", "file", "directory":
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

    private static func safeOverride(_ relativePath: String, projectRoot: URL) -> URL? {
        let candidate = projectRoot.appending(path: relativePath).standardizedFileURL
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.pathComponents.starts(with: root.pathComponents),
              resolved.pathComponents.count > root.pathComponents.count else {
            return nil
        }
        return candidate
    }

    private static let imageDirectoryExtensions: Set<String> = [
        "jpeg", "jpg", "png", "pnga", "bmp", "gif", "svg", "webp"
    ]
    private static let videoDirectoryExtensions: Set<String> = ["webm", "ogg", "ogv"]

    private static func safeRegularFiles(
        in directory: URL,
        projectRoot: URL,
        allowedExtensions: Set<String>
    ) -> [String] {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }
        var files: [String] = []
        for case let candidate as URL in enumerator {
            guard files.count < 2_000 else { break }
            guard let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            ) else {
                continue
            }
            if candidate.lastPathComponent.hasPrefix(".") {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true,
                  allowedExtensions.contains(candidate.pathExtension.lowercased()) else {
                continue
            }
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.pathComponents.starts(with: root.pathComponents),
                  resolved.pathComponents.count > root.pathComponents.count else {
                continue
            }
            files.append(candidate.path)
        }
        return files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

enum RestrictedWebNavigationPolicy {
    static func allows(
        _ candidate: URL?,
        projectRoot: URL,
        isMainFrame: Bool,
        networkAccessAllowed: Bool,
        isDownload: Bool = false,
        trustedLocalMainFrameURL: URL? = nil,
        trustedRemoteMainFrameURL: URL? = nil
    ) -> Bool {
        guard !isDownload, let candidate else { return false }
        guard candidate.user == nil, candidate.password == nil else { return false }
        if candidate.isFileURL {
            guard candidate.host?.isEmpty ?? true else { return false }
            let rootComponents = projectRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            let candidateComponents = candidate.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard candidateComponents.count > rootComponents.count,
                  Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
                return false
            }
            guard isMainFrame else { return true }
            guard let trustedLocalMainFrameURL else { return false }
            return candidate.standardizedFileURL.resolvingSymlinksInPath().path
                == trustedLocalMainFrameURL.standardizedFileURL.resolvingSymlinksInPath().path
        }
        guard networkAccessAllowed,
              ["https", "http"].contains(candidate.scheme?.lowercased() ?? "") else {
            return false
        }
        guard isMainFrame else { return true }
        guard let trustedRemoteMainFrameURL else { return false }
        return sameRemoteOrigin(candidate, trustedRemoteMainFrameURL)
    }

    private static func sameRemoteOrigin(_ candidate: URL, _ trusted: URL) -> Bool {
        guard candidate.user == nil,
              candidate.password == nil,
              trusted.user == nil,
              trusted.password == nil else {
            return false
        }
        let candidateScheme = candidate.scheme?.lowercased()
        let trustedScheme = trusted.scheme?.lowercased()
        guard let candidateHost = candidate.host?.lowercased(),
              let trustedHost = trusted.host?.lowercased(),
              let candidateScheme,
              let trustedScheme else {
            return false
        }
        return candidateScheme == trustedScheme
            && candidateHost == trustedHost
            && effectivePort(candidate) == effectivePort(trusted)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

@MainActor
final class RestrictedWebWallpaperView: NSView,
    WKNavigationDelegate,
    PausableWallpaperContent,
    WallpaperContentLifecycle {
    private let webView: PlashWebView
    private let url: URL
    private let readAccessURL: URL
    private let networkAccessAllowed: Bool
    private let remoteConfiguration: RemoteWebWallpaperConfiguration?
    private var failureLabel: NSTextField?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryBudgetResetTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    private var isSuspended = false
    private var isClosed = false

    init(url: URL, readAccessURL: URL, frame: CGRect, networkAccessAllowed: Bool = false) {
        self.url = url
        self.readAccessURL = readAccessURL
        self.networkAccessAllowed = networkAccessAllowed
        remoteConfiguration = RemoteWebWallpaperConfiguration.load(projectRoot: readAccessURL)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        let configuration = PlashRuntime.makeConfiguration(
            applicationName: "Background Engine/\(version)",
            usesPersistentWebsiteData: false
        )
        let properties = WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: readAccessURL)
        let directories = WebWallpaperCompatibilityBridge.directoryProperties(projectRoot: readAccessURL)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WebWallpaperCompatibilityBridge.bootstrapScript(
                    properties: properties,
                    directories: directories
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        let plashWebView = PlashWebView(frame: frame, configuration: configuration)
        PlashRuntime.prepare(plashWebView)
        webView = plashWebView
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
        isSuspended = suspended
        applyPlaybackSuspension()
    }

    func prepareForClose() {
        guard !isClosed else { return }
        isClosed = true
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryBudgetResetTask?.cancel()
        recoveryBudgetResetTask = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
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
            isDownload: navigationAction.shouldPerformDownload,
            trustedLocalMainFrameURL: remoteConfiguration == nil ? url : nil,
            trustedRemoteMainFrameURL: remoteConfiguration?.targetURL
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
        recoveryBudgetResetTask?.cancel()
        recoveryBudgetResetTask = nil
        if recoveryAttempts < 2 {
            showFailure("The Web wallpaper process stopped unexpectedly. Background Engine is retrying it.")
            scheduleProcessRecovery()
        } else {
            showFailure("The Web wallpaper stopped repeatedly. Replay it to try again.")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        failureLabel?.removeFromSuperview()
        failureLabel = nil
        applyPlaybackSuspension()
        scheduleRecoveryBudgetReset()
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
        guard !isClosed else { return }
        if let remoteConfiguration {
            guard networkAccessAllowed else {
                showFailure("This website wallpaper requires external network access.")
                return
            }
            webView.load(URLRequest(
                url: remoteConfiguration.targetURL,
                cachePolicy: .reloadRevalidatingCacheData,
                timeoutInterval: 30
            ))
        } else {
            webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
        }
    }

    private func scheduleProcessRecovery() {
        guard !isClosed, recoveryAttempts < 2 else { return }
        recoveryAttempts += 1
        recoveryTask?.cancel()
        let delay = Duration.milliseconds(250 * recoveryAttempts)
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.isClosed else { return }
            self.recoveryTask = nil
            self.loadProject()
        }
    }

    private func applyPlaybackSuspension() {
        guard !isClosed else { return }
        webView.evaluateJavaScript(PlashRuntime.playbackScript(suspended: isSuspended))
    }

    private func scheduleRecoveryBudgetReset() {
        recoveryBudgetResetTask?.cancel()
        recoveryBudgetResetTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.isClosed else { return }
            self.recoveryAttempts = 0
            self.recoveryBudgetResetTask = nil
        }
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
