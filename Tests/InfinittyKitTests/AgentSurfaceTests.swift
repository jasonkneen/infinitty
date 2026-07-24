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

    func testHTMLControllerHostsWebViewWithBridge() throws {
        let request = try AgentSurfaceRequest.parse(
            #"{"kind":"html","content":"<h1>UI</h1>"}"#).get()
        let controller = SurfacePaneController(request: request)
        let web = try XCTUnwrap(controller.view as? WKWebView)
        XCTAssertFalse(web.configuration.userContentController.userScripts.isEmpty)
        controller.teardown()
    }
}
