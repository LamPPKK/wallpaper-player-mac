import AppKit
import WebKit

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

    init(url: URL, readAccessURL: URL, frame: CGRect, networkAccessAllowed: Bool = false) {
        self.url = url
        self.readAccessURL = readAccessURL
        self.networkAccessAllowed = networkAccessAllowed
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
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
            ? "document.querySelectorAll('video,audio').forEach((item) => item.pause())"
            : "document.querySelectorAll('video,audio').forEach((item) => item.play().catch(() => {}))"
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

    private func installRemoteBlockerAndLoad() {
        let rules = #"""
        [{"trigger":{"url-filter":"^https?://.*"},"action":{"type":"block"}}]
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

}
