import AppKit
import XCTest

@testable import InfinittyKit

/// The terminal must never lock or steal keyboard input. These tests pin the
/// chrome and attach-path mistakes that silently swallow keystrokes.
final class InputOwnershipTests: XCTestCase {
    func testChannelConnectorDoesNotAcceptFirstResponder() {
        let connector = ChannelConnectorView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        XCTAssertFalse(connector.acceptsFirstResponder)
    }

    func testPetSpeechBubbleDoesNotAcceptFirstResponder() {
        let bubble = PixelPetSpeechBubble(text: "hello")
        XCTAssertFalse(bubble.acceptsFirstResponder)
    }

    func testTodosReadDoesNotHopToMain() {
        let session = TerminalSession(config: AppConfig.load(), scale: 2)
        defer { session.shutdown() }
        session.setTodos([PaneTodo(text: "one", done: false, active: false)])

        let encoded = expectation(description: "todos read off-main")
        var result = ""
        DispatchQueue.global(qos: .userInitiated).async {
            result = session.control.todosHandler?("") ?? "missing"
            encoded.fulfill()
        }
        wait(for: [encoded], timeout: 1)
        XCTAssertTrue(result.contains("one"), "todos read was: \(result)")
    }
}
