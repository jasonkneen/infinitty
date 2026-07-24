import AppKit
import WebKit

/// A parsed agent request for a display surface: "give me an 80/20 split (or
/// a window) and show this markdown / HTML / URL in it". Sent over the app
/// socket as `surface <pane-id> <json>` and via the infinitty_surface MCP tool.
struct AgentSurfaceRequest: Equatable {
    enum Kind: String { case markdown, html, url, ui }
    enum Target: String { case split, window }
    struct ParseError: Error, Equatable { let message: String }

    let kind: Kind
    let target: Target
    /// Split placement relative to the requesting pane.
    let direction: String
    /// Fraction of the split the NEW surface occupies (0.15…0.85).
    let ratio: CGFloat
    let title: String?
    let content: String
    var isVertical: Bool { direction == "right" || direction == "left" }
    var newFirst: Bool { direction == "left" || direction == "up" }

    static func parse(_ json: String) -> Result<AgentSurfaceRequest, ParseError> {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failure(ParseError(message: "surface expects a JSON object")) }
        guard let kind = (object["kind"] as? String).flatMap(Kind.init(rawValue:)) else {
            return .failure(ParseError(message: "kind must be markdown|html|url"))
        }
        let target = (object["target"] as? String).flatMap(Target.init(rawValue:)) ?? .split
        let direction = (object["direction"] as? String) ?? "right"
        guard ["right", "left", "down", "up"].contains(direction) else {
            return .failure(ParseError(message: "direction must be right|left|down|up"))
        }
        let content: String
        switch kind {
        case .markdown, .html:
            guard let text = object["content"] as? String, !text.isEmpty else {
                return .failure(ParseError(message: "content is required for kind=\(kind.rawValue)"))
            }
            content = text
        case .ui:
            // A json-render spec: accept it inline as an object (preferred) or
            // as a JSON string; store normalized JSON text either way.
            let specValue = object["spec"] ?? object["content"]
            if let dict = specValue as? [String: Any] {
                guard dict["root"] != nil, dict["elements"] != nil,
                      let data = try? JSONSerialization.data(withJSONObject: dict)
                else {
                    return .failure(ParseError(
                        message: "ui spec must be an object with root and elements"))
                }
                content = String(decoding: data, as: UTF8.self)
            } else if let text = specValue as? String,
                      let data = text.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      dict["root"] != nil, dict["elements"] != nil {
                content = text
            } else {
                return .failure(ParseError(
                    message: "ui spec must be an object with root and elements"))
            }
        case .url:
            guard let raw = (object["url"] as? String) ?? (object["content"] as? String),
                  let parsed = URL(string: raw), parsed.scheme?.hasPrefix("http") == true
            else { return .failure(ParseError(message: "url must be an absolute http(s) URL")) }
            content = parsed.absoluteString
        }
        let rawRatio = (object["ratio"] as? Double) ?? 0.35
        return .success(AgentSurfaceRequest(
            kind: kind,
            target: target,
            direction: direction,
            ratio: CGFloat(min(max(rawRatio, 0.15), 0.85)),
            title: object["title"] as? String,
            content: content))
    }

    /// MCP-UI resource mime types map onto surface kinds: inline HTML renders
    /// directly, uri-list opens the referenced page.
    static func kind(forMimeType mime: String) -> Kind? {
        switch mime.lowercased() {
        case "text/html": return .html
        case "text/uri-list": return .url
        case "text/markdown": return .markdown
        default: return nil
        }
    }
}

/// Hosts one agent surface's content view: rendered markdown in a text view,
/// or a chrome-less WKWebView for HTML (MCP-UI resources) and URLs. UI events
/// posted by MCP-UI content (intent/tool/link messages) surface via `onUIEvent`.
final class SurfacePaneController: NSObject, WKScriptMessageHandler {
    private(set) var view: NSView = NSView()
    private weak var webView: WKWebView?
    var onUIEvent: (([String: Any]) -> Void)?

    init(request: AgentSurfaceRequest) {
        super.init()
        switch request.kind {
        case .markdown:
            view = Self.markdownView(request.content)
        case .html:
            let web = makeWebView()
            web.loadHTMLString(request.content, baseURL: nil)
            view = web
        case .url:
            let web = makeWebView()
            if let url = URL(string: request.content) {
                web.load(URLRequest(url: url))
            }
            view = web
        case .ui:
            // json-render: the bundled host page renders the injected spec
            // with the built-in component registry. The spec was validated as
            // JSON at parse time, so it is a safe JS literal.
            let web = makeWebView()
            web.configuration.userContentController.addUserScript(WKUserScript(
                source: "window.__INITIAL_SPEC__ = \(request.content);",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            // A concrete baseURL gives the document a real origin, so script
            // errors surface with messages instead of the masked
            // "Script error @0:0" a null-origin document reports.
            web.loadHTMLString(
                Self.jsonRenderHostHTML
                    ?? "<pre style=\"color:#eee\">json-render host page missing from bundle</pre>",
                baseURL: URL(string: "https://surface.infinitty.local/"))
            view = web
        }
    }

    /// The self-contained json-render host page (built by
    /// surfaces/json-render-host/build.mjs, shipped in Resources/Surfaces).
    static let jsonRenderHostHTML: String? = {
        let url = Bundle.main.url(
            forResource: "json-render-host", withExtension: "html", subdirectory: "Surfaces")
            ?? Bundle.main.url(forResource: "json-render-host", withExtension: "html")
            ?? Bundle.module.url(
                forResource: "json-render-host", withExtension: "html", subdirectory: "Surfaces")
            ?? Bundle.module.url(forResource: "json-render-host", withExtension: "html")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }()

    private static func markdownView(_ markdown: String) -> NSView {
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 14, height: 14)
        text.textStorage?.setAttributedString(
            MarkdownRender.attributed(markdown, style: .chat))
        text.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = text
        text.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        return scroll
    }

    /// MCP-UI content calls postMessage(window.parent, {type: "tool"|"intent"|
    /// "prompt"|"link"|"notify", …}). Rendered top-level (not in an iframe),
    /// window.parent === window, so a window message listener catches those
    /// posts and forwards them to the native side. window.infinitty.post is
    /// the direct escape hatch for custom content.
    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let bridge = """
        window.addEventListener('message', function (event) {
            try { window.webkit.messageHandlers.infinittyui.postMessage(event.data); }
            catch (_) {}
        });
        window.infinitty = {
            post: function (message) {
                try { window.webkit.messageHandlers.infinittyui.postMessage(message); }
                catch (_) {}
            }
        };
        """
        config.userContentController.addUserScript(WKUserScript(
            source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(self, name: "infinittyui")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        webView = web
        return web
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let payload = message.body as? [String: Any] ?? ["value": "\(message.body)"]
        onUIEvent?(payload)
    }

    func teardown() {
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: "infinittyui")
        webView?.stopLoading()
    }
}
