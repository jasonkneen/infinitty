import XCTest
import WebKit
@testable import InfinittyKit

final class AgentSurfaceTests: XCTestCase {

    func testParseMarkdownSplitDefaults() throws {
        let request = try AgentSurfaceRequest.parse(
            ##"{"kind":"markdown","content":"# Plan\n- step"}"##).get()
        XCTAssertEqual(request.kind, .markdown)
        XCTAssertEqual(request.target, .split)
        XCTAssertEqual(request.direction, "right")
        XCTAssertEqual(request.ratio, 0.35, accuracy: 0.001)
        XCTAssertTrue(request.isVertical)
        XCTAssertFalse(request.newFirst)
    }

    func testParseClampsRatioAndReadsPlacement() throws {
        let request = try AgentSurfaceRequest.parse(
            #"{"kind":"html","content":"<b>hi</b>","direction":"up","ratio":0.05,"target":"window","title":"Doc"}"#
        ).get()
        XCTAssertEqual(request.ratio, 0.15, accuracy: 0.001)
        XCTAssertEqual(request.target, .window)
        XCTAssertTrue(request.newFirst)
        XCTAssertFalse(request.isVertical)
        XCTAssertEqual(request.title, "Doc")
    }

    func testParseRejectsBadInput() {
        if case .success = AgentSurfaceRequest.parse("not json") {
            XCTFail("expected failure")
        }
        if case .success = AgentSurfaceRequest.parse(#"{"kind":"markdown"}"#) {
            XCTFail("markdown without content must fail")
        }
        if case .success = AgentSurfaceRequest.parse(#"{"kind":"url","url":"file:///etc/passwd"}"#) {
            XCTFail("non-http URL must fail")
        }
        if case .success = AgentSurfaceRequest.parse(#"{"kind":"html","content":"x","direction":"sideways"}"#) {
            XCTFail("bad direction must fail")
        }
    }

    func testParseAcceptsURLKind() throws {
        let request = try AgentSurfaceRequest.parse(
            #"{"kind":"url","url":"https://example.com/plan"}"#).get()
        XCTAssertEqual(request.kind, .url)
        XCTAssertEqual(request.content, "https://example.com/plan")
    }

    func testMimeTypeMappingCoversMCPUIResources() {
        XCTAssertEqual(AgentSurfaceRequest.kind(forMimeType: "text/html"), .html)
        XCTAssertEqual(AgentSurfaceRequest.kind(forMimeType: "text/uri-list"), .url)
        XCTAssertEqual(AgentSurfaceRequest.kind(forMimeType: "text/markdown"), .markdown)
        XCTAssertNil(AgentSurfaceRequest.kind(forMimeType: "application/vnd.mcp-ui.remote-dom"))
    }

    func testMarkdownControllerRendersContentIntoTextView() throws {
        let request = try AgentSurfaceRequest.parse(
            ##"{"kind":"markdown","content":"# Build Plan\nStep one"}"##).get()
        let controller = SurfacePaneController(request: request)
        let scroll = try XCTUnwrap(controller.view as? NSScrollView)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertTrue(text.string.contains("Build Plan"))
        XCTAssertFalse(text.isEditable)
    }

    func testParseUIKindAcceptsSpecObjectOrStringAndValidatesShape() throws {
        let inline = try AgentSurfaceRequest.parse(
            ##"{"kind":"ui","spec":{"root":"a","elements":{"a":{"type":"Text","props":{"content":"hi"}}}}}"##
        ).get()
        XCTAssertEqual(inline.kind, .ui)
        XCTAssertTrue(inline.content.contains("\"root\":\"a\""))

        let stringified = try AgentSurfaceRequest.parse(
            ##"{"kind":"ui","content":"{\"root\":\"a\",\"elements\":{}}"}"##).get()
        XCTAssertTrue(stringified.content.contains("\"root\""))

        if case .success = AgentSurfaceRequest.parse(##"{"kind":"ui","spec":{"elements":{}}}"##) {
            XCTFail("spec without root must fail")
        }
        if case .success = AgentSurfaceRequest.parse(##"{"kind":"ui","content":"not json"}"##) {
            XCTFail("non-JSON spec string must fail")
        }
    }

    func testJSONRenderHostPageShipsInBundleAndUIControllerUsesIt() throws {
        let host = try XCTUnwrap(SurfacePaneController.jsonRenderHostHTML)
        XCTAssertTrue(host.contains("__INITIAL_SPEC__") || host.contains("__setSpec"))
        XCTAssertTrue(host.contains("<div id=\"root\">"))

        let request = try AgentSurfaceRequest.parse(
            ##"{"kind":"ui","spec":{"root":"a","elements":{"a":{"type":"Text","props":{"content":"hi"}}}}}"##
        ).get()
        let controller = SurfacePaneController(request: request)
        let web = try XCTUnwrap(controller.view as? WKWebView)
        // Bridge script + injected spec script.
        XCTAssertGreaterThanOrEqual(
            web.configuration.userContentController.userScripts.count, 2)
        XCTAssertTrue(
            web.configuration.userContentController.userScripts
                .contains { $0.source.contains("__INITIAL_SPEC__") })
        controller.teardown()
    }

    func testJSONRenderHostRendersSpecInWebView() throws {
        let request = try AgentSurfaceRequest.parse(
            ##"{"kind":"ui","spec":{"root":"c","elements":{"c":{"type":"Card","props":{"title":"Deploy"},"children":["t"]},"t":{"type":"Text","props":{"content":"Ready"}}}}}"##
        ).get()
        let controller = SurfacePaneController(request: request)
        let web = try XCTUnwrap(controller.view as? WKWebView)
        web.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

        let rendered = expectation(description: "spec rendered")
        var found = false
        var diagnostics = ""
        func poll(_ remaining: Int) {
            web.evaluateJavaScript(
                "document.body && document.body.innerText.includes('Deploy') ? 'OK' : "
                + "'state=' + window.__hostState + ' setSpec=' + (typeof window.__setSpec) + "
                + "' errors=' + JSON.stringify(window.__errors || null) + ' root=' + "
                + "(document.getElementById('root') || {}).innerHTML"
            ) { value, error in
                diagnostics = (value as? String) ?? "eval-error: \(String(describing: error))"
                if diagnostics == "OK" {
                    found = true
                    rendered.fulfill()
                } else if remaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        poll(remaining - 1)
                    }
                } else {
                    rendered.fulfill()
                }
            }
        }
        poll(40)
        wait(for: [rendered], timeout: 15)
        XCTAssertTrue(found, "host should render the Card title; got: \(diagnostics)")
        controller.teardown()
    }

    func testHTMLControllerHostsWebViewWithBridge() throws {
        let request = try AgentSurfaceRequest.parse(
            #"{"kind":"html","content":"<h1>UI</h1>"}"#).get()
        let controller = SurfacePaneController(request: request)
        let web = try XCTUnwrap(controller.view as? WKWebView)
        XCTAssertFalse(web.configuration.userContentController.userScripts.isEmpty)
        controller.teardown()
    }
}
