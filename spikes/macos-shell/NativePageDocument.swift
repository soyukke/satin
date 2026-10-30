import AppKit
import WebKit

/// The page renderer the app bundles: index.html, its stylesheet and script,
/// and the libraries under lib/.
enum NativePageRenderer {
    static let scheme = "satin-page"
    static let host = "reader"

    /// `Resources/PageRenderer` in the app, `PageRenderer` beside a bare
    /// build, or the checkout's own `page-renderer`.
    static let folder: URL? = {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("PageRenderer", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("page-renderer", isDirectory: true),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path)
        }
    }()

    /// The renderer's own files a page may load; nothing else under its
    /// folder is served.
    static func isRendererFile(_ parts: [String]) -> Bool {
        switch parts.count {
        case 1: return ["index.html", "satin-page.css", "satin-page.js"].contains(parts[0])
        case 2: return parts[0] == "lib" && parts[1].hasSuffix(".js")
        default: return false
        }
    }

    /// The colors of the current look, as the renderer's CSS custom
    /// properties. `--sheet` continues the frame the reader draws around
    /// the page.
    static func colors() -> [String: String] {
        var colors: [String: String] = [
            "--surface": css(NativePageStyle.surface),
            "--raised": css(NativePageStyle.raised),
            "--text": css(NativePageStyle.text),
            "--muted": css(NativePageStyle.muted),
            "--teal": css(NativePageStyle.teal),
            "--violet": css(NativePageStyle.violet),
            "--amber": css(NativePageStyle.amber),
            "--rose": css(NativePageStyle.rose),
            "--ink": css(NativePageStyle.ink),
            "--line": css(NativePageStyle.line),
        ]
        colors["--sheet"] = NativePageStyle.paper ? colors["--raised"] : colors["--surface"]
        return colors
    }

    static func css(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func channel(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
        let alpha = (rgb.alphaComponent * 1000).rounded() / 1000
        return
            "rgba(\(channel(rgb.redComponent)), \(channel(rgb.greenComponent)), \(channel(rgb.blueComponent)), \(alpha))"
    }

    static func mimeType(_ file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "md", "markdown": return "text/markdown; charset=utf-8"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }

    /// `file` below `folder` with no step out of it, links included.
    static func confined(_ parts: [String], in folder: URL) -> URL? {
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            return nil
        }
        let base = folder.resolvingSymlinksInPath().standardizedFileURL
        let file = parts.reduce(base) { $0.appendingPathComponent($1) }
            .resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.path + "/") else {
            return nil
        }
        return file
    }

    /// Lets only `satin-page:` load; WebKit refuses everything else before
    /// it is fetched, as a second wall behind the page's
    /// Content-Security-Policy.
    static func contentRules(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let rules = compiledRules {
            completion(rules)
            return
        }
        let source = """
            [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^\(scheme):"},"action":{"type":"ignore-previous-rules"}}]
            """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "satin-page-only", encodedContentRuleList: source
        ) { rules, error in
            if error != nil {
                NativeLog.runtimeError("page_rules_failed")
            }
            compiledRules = rules
            completion(rules)
        }
    }

    private static var compiledRules: WKContentRuleList?
}

/// Serves the reader's `satin-page:` loads: the bundled renderer, and the
/// files of the one version on show under `page/KEY/`. Every other path is
/// not found.
final class NativePageSchemeHandler: NSObject, WKURLSchemeHandler {
    let renderer: URL
    /// The version on show: the key its files are served under, and its folder.
    var page: (key: String, folder: URL)?

    init(renderer: URL) {
        self.renderer = renderer
    }

    func file(for url: URL) -> URL? {
        guard url.scheme == NativePageRenderer.scheme, url.host == NativePageRenderer.host else {
            return nil
        }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst().map(String.init)
        if parts.first == "page" {
            guard let page, parts.count >= 3, parts[1] == page.key else {
                return nil
            }
            return NativePageRenderer.confined(Array(parts.dropFirst(2)), in: page.folder)
        }
        guard NativePageRenderer.isRendererFile(parts) else {
            return nil
        }
        return NativePageRenderer.confined(parts, in: renderer)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let file = file(for: url)
        let data = file.flatMap { try? Data(contentsOf: $0) }
        var headers = ["Cache-Control": "no-store"]
        if let file, data != nil {
            headers["Content-Type"] = NativePageRenderer.mimeType(file)
        }
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: data == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                headerFields: headers)
        else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data ?? Data())
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// The reader's page: one version drawn by the page renderer in a WebKit
/// view laid over the reader's pane, which stays behind it for the control
/// API. The view loads only `satin-page:`, keeps nothing on disk, and has no
/// message handler, so a page cannot reach Satin, the files beside it, or
/// the network.
final class NativePageDocumentView: NSView, WKNavigationDelegate {
    private(set) var webView: WKWebView?
    private var handler: NativePageSchemeHandler?
    private var loaded = false
    /// The version to draw once the renderer has loaded, and the one drawn.
    private var pending: (path: String, language: String)?
    private var drawn: (path: String, language: String)?
    private(set) var shown: String?
    /// The version last drawn to the end, diagrams and charts included.
    private(set) var drawnKey: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.group)
        refreshSheet()
        guard let renderer = NativePageRenderer.folder else {
            NativeLog.runtimeError("page_renderer_missing")
            return
        }
        NativePageRenderer.contentRules { [weak self] rules in
            // Without the rules nothing is loaded.
            guard let self, let rules else { return }
            self.makeWebView(renderer: renderer, rules: rules)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func makeWebView(renderer: URL, rules: WKContentRuleList) {
        let handler = NativePageSchemeHandler(renderer: renderer)
        handler.page = pendingPage
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: NativePageRenderer.scheme)
        configuration.userContentController.add(rules)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.isHidden = true
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = sheetColor
        addSubview(webView)
        self.webView = webView
        self.handler = handler
        load()
    }

    private func load() {
        loaded = false
        guard let webView,
            let url = URL(
                string: "\(NativePageRenderer.scheme)://\(NativePageRenderer.host)/index.html?host")
        else {
            return
        }
        webView.load(URLRequest(url: url))
    }

    /// The folder and key waiting for the handler while the view is made.
    private var pendingPage: (key: String, folder: URL)?

    /// Shows one version: its folder, the document's name in it, and its
    /// language. `key` names the version, so the same one is not drawn again.
    func show(folder: URL, document: String, language: String, key: String) {
        guard key != shown else {
            return
        }
        shown = key
        // The key is served as one plain path segment.
        let served = String(
            key.unicodeScalars.map {
                $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-"
            })
        pendingPage = (served, folder)
        handler?.page = (served, folder)
        let name =
            document.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? document
        pending = ("page/\(served)/\(name)", language)
        drawPending()
    }

    func refreshLook() {
        refreshSheet()
        webView?.underPageBackgroundColor = sheetColor
        guard loaded else { return }
        call("await satinPage.setLook(look, colors)", arguments: look())
    }

    /// Space and the page keys scroll by a screen; the arrows by a few lines.
    func scroll(lines: CGFloat? = nil, down: Bool) {
        let step = lines.map { "\($0 * 22)" } ?? "Math.max(40, window.innerHeight - 60)"
        webView?.evaluateJavaScript(
            "window.scrollBy({top: \(down ? "" : "-")\(step), behavior: 'smooth'})")
    }

    private var sheetColor: NSColor {
        NativePageStyle.paper ? NativePageStyle.raised : NativePageStyle.surface
    }

    private func refreshSheet() {
        layer?.backgroundColor = sheetColor.cgColor
    }

    private func look() -> [String: Any] {
        [
            "look": NativePageStyle.paper ? "paper" : "datasheet",
            "colors": NativePageRenderer.colors(),
        ]
    }

    private func drawPending() {
        guard loaded, let pending else { return }
        self.pending = nil
        drawn = pending
        let key = shown
        call(
            "await satinPage.open(path, language); window.scrollTo(0, 0)",
            arguments: ["path": pending.path, "language": pending.language]
        ) { [weak self] in
            self?.webView?.isHidden = false
            self?.drawnKey = key
        }
    }

    private func call(
        _ body: String, arguments: [String: Any], then done: (() -> Void)? = nil
    ) {
        webView?.callAsyncJavaScript(
            body, arguments: arguments, in: nil, in: .page
        ) { result in
            if case .failure = result {
                NativeLog.runtimeError("page_render_failed")
            }
            done?()
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        call("await satinPage.setLook(look, colors)", arguments: look()) { [weak self] in
            self?.drawPending()
        }
    }

    /// WebKit's page process ended; the renderer is loaded again and the
    /// version on show drawn anew.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pending = pending ?? drawn
        webView.isHidden = true
        load()
    }

    /// Only the renderer itself loads in the view. A clicked web or mail link
    /// is opened by the system; a link within the page moves to its anchor.
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(
            Self.policy(
                for: action.request.url, current: webView.url,
                mainFrame: action.targetFrame?.isMainFrame ?? false,
                clicked: action.navigationType == .linkActivated))
    }

    static func policy(for url: URL?, current: URL?, mainFrame: Bool, clicked: Bool)
        -> WKNavigationActionPolicy
    {
        guard let url else {
            return .cancel
        }
        if clicked {
            if mainFrame, let current, url.fragment != nil,
                url.absoluteString.split(separator: "#").first
                    == current.absoluteString.split(separator: "#").first
            {
                return .allow
            }
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
        let renderer =
            url.scheme == NativePageRenderer.scheme && url.host == NativePageRenderer.host
            && url.path == "/index.html"
        return mainFrame && renderer ? .allow : .cancel
    }
}

func runNativePageDocumentSelfTests() -> Bool {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("satin-page-self-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let renderer = root.appendingPathComponent("renderer", isDirectory: true)
    let version = root.appendingPathComponent("v001", isDirectory: true)
    let other = root.appendingPathComponent("v002", isDirectory: true)
    do {
        for folder in [renderer.appendingPathComponent("lib"), version, other] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("<!doctype html>".utf8).write(to: renderer.appendingPathComponent("index.html"))
        try Data("x".utf8).write(to: renderer.appendingPathComponent("lib/a.js"))
        try Data("x".utf8).write(to: renderer.appendingPathComponent("README.md"))
        try Data("# Page".utf8).write(to: version.appendingPathComponent("artifact.md"))
        try Data("x".utf8).write(to: other.appendingPathComponent("secret.png"))
        try fileManager.createSymbolicLink(
            at: version.appendingPathComponent("out.png"),
            withDestinationURL: other.appendingPathComponent("secret.png"))
    } catch {
        return false
    }
    let handler = NativePageSchemeHandler(renderer: renderer)
    handler.page = ("p1", version)
    func served(_ path: String) -> Bool {
        URL(string: "satin-page://reader\(path)").flatMap(handler.file(for:)) != nil
    }
    let wanted = [
        "/index.html", "/lib/a.js", "/page/p1/artifact.md",
    ]
    let refused = [
        "/README.md", "/page/p2/artifact.md", "/page/p1/../v002/secret.png",
        "/page/p1/%2E%2E/v002/secret.png", "/page/p1/out.png", "/page/p1/",
    ]
    guard wanted.allSatisfy(served), !refused.contains(where: served),
        URL(string: "satin-page://elsewhere/index.html").flatMap(handler.file(for:)) == nil,
        URL(string: "file:///etc/hosts").flatMap(handler.file(for:)) == nil
    else {
        return false
    }
    let index = URL(string: "satin-page://reader/index.html?host")
    let policy = NativePageDocumentView.policy
    return policy(index, nil, true, false) == .allow
        && policy(index, nil, false, false) == .cancel
        && policy(URL(string: "satin-page://reader/page/p1/artifact.md"), index, true, false)
            == .cancel
        && policy(URL(string: "file:///etc/hosts"), index, true, false) == .cancel
        && policy(URL(string: "satin-page://reader/index.html?host#usage"), index, true, true)
            == .allow
        && policy(URL(string: "satin-page://reader/notes.md"), index, true, true) == .cancel
        && NativePageRenderer.css(NativePageStyle.rgb(31, 138, 138)) == "rgba(31, 138, 138, 1.0)"
}
