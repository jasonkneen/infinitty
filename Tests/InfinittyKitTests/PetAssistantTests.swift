import XCTest
@testable import InfinittyKit

final class PetAssistantTests: XCTestCase {

    func testParseSearchDirective() {
        XCTAssertEqual(PetAssistant.parseSearchDirective("SEARCH: markdown render"),
                       "markdown render")
        XCTAssertEqual(PetAssistant.parseSearchDirective("SEARCH:  spaced query  "),
                       "spaced query")
        XCTAssertNil(PetAssistant.parseSearchDirective("SEARCH:"))
        XCTAssertNil(PetAssistant.parseSearchDirective("Sure! You could try SEARCH: foo"))
        XCTAssertNil(PetAssistant.parseSearchDirective("Just an answer."))
        XCTAssertNil(PetAssistant.parseSearchDirective(nil))
    }

    func testPetHitRectNilWithoutPet() {
        let renderer = Renderer(config: AppConfig(), scale: 2)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        XCTAssertNil(renderer.petHitRect(in: view))
    }

    func testAssistantShowResultsSwitchesToFilesPage() {
        let controller = CodeViewController(config: AppConfig())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.layoutIfNeeded()
        controller.reRootForTesting(NSTemporaryDirectory())
        controller.showSearchResults(
            ["Sources/App.swift", "Sources/CodeView.swift"], query: "app")
        XCTAssertEqual(controller.topLevelRowCountForTesting, 2)
        XCTAssertEqual(controller.cellTextForTesting(row: 0), "Sources/App.swift")
    }

    func testChatTabEmbedsExistingAssistantAtFullHeight() {
        let controller = CodeViewController(config: AppConfig())
        let assistant = PetAssistant(config: AppConfig())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.attachAssistant(assistant)
        controller.switchPageForTesting(2)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.chatPageIsVisibleForTesting)
        XCTAssertTrue(controller.chatPageUsesAssistantForTesting(assistant))
        XCTAssertGreaterThan(controller.chatPageFrameForTesting.height, 500)

        let panel = assistant.makeSidebarPanelView()
        XCTAssertEqual(panel.titleForTesting, "Assistant")
        XCTAssertEqual(panel.newChatTitleForTesting, "New chat")
        XCTAssertEqual(
            panel.emptyStateForTesting,
            "Choose an agent, ask a question, and keep chatting here.")
        XCTAssertEqual(panel.modelLabelForTesting, "MODEL")
        XCTAssertEqual(panel.modelValueForTesting, "Auto · Best available")
        XCTAssertEqual(panel.attachmentSymbolForTesting, "paperclip")
        XCTAssertEqual(panel.sendSymbolForTesting, "arrow.up")
        XCTAssertTrue(panel.sendButtonIsCircularForTesting)
    }
}
