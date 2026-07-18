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
        XCTAssertEqual(panel.presentationForTesting, .sidebar)
        XCTAssertFalse(panel.showsCloseButtonForTesting)
        XCTAssertFalse(panel.usesGlassSurfaceForTesting)
        XCTAssertGreaterThan(panel.inputFrameForTesting.width, 100)
        window.makeKeyAndOrderFront(nil)
        panel.focusInput()
        XCTAssertTrue(panel.inputIsFirstResponderForTesting)
    }

    func testComposerListsConfiguredModel() {
        var config = AppConfig()
        config.aiModel = "claude-sonnet-4"
        let assistant = PetAssistant(config: config)
        let panel = assistant.makeSidebarPanelView()
        XCTAssertEqual(panel.modelValueForTesting, "Auto · Best available")
        XCTAssertTrue(panel.modelItemTitlesForTesting.contains("claude-sonnet-4"))
    }

    func testComposerDefaultsModelWhenBaseURLSet() {
        var config = AppConfig()
        config.aiBaseURL = "https://api.example.com/v1"
        let assistant = PetAssistant(config: config)
        let panel = assistant.makeSidebarPanelView()
        XCTAssertTrue(panel.modelItemTitlesForTesting.contains("gpt-4o-mini"))
    }
    func testPetClickPresentsIndependentAssistantPanel() throws {
        let assistant = PetAssistant(config: AppConfig())
        let sidebarPanel = assistant.makeSidebarPanelView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let anchorView = NSView(frame: window.contentView!.bounds)
        window.contentView = anchorView

        assistant.presentInput(
            anchorRect: NSRect(x: 380, y: 8, width: 24, height: 24),
            in: anchorView)

        let popoverPanel = try XCTUnwrap(assistant.popoverPanelForTesting)
        XCTAssertFalse(popoverPanel === sidebarPanel)
        XCTAssertEqual(popoverPanel.titleForTesting, "Assistant")
        XCTAssertEqual(popoverPanel.newChatTitleForTesting, "New chat")
        XCTAssertEqual(popoverPanel.modelValueForTesting, "Auto · Best available")
        XCTAssertTrue(popoverPanel.sendButtonIsCircularForTesting)
        XCTAssertEqual(popoverPanel.presentationForTesting, .popover)
        XCTAssertTrue(popoverPanel.showsCloseButtonForTesting)
        XCTAssertTrue(popoverPanel.usesGlassSurfaceForTesting)
        XCTAssertEqual(popoverPanel.frame.size, NSSize(width: 380, height: 420))

        popoverPanel.submitForTesting("Hello")
        XCTAssertEqual(sidebarPanel.transcriptForTesting, popoverPanel.transcriptForTesting)
        XCTAssertTrue(sidebarPanel.transcriptForTesting.contains("Hello"))
        XCTAssertFalse(sidebarPanel.showsEmptyStateForTesting)
        XCTAssertFalse(popoverPanel.showsEmptyStateForTesting)

        popoverPanel.newChatForTesting()
        XCTAssertEqual(sidebarPanel.transcriptForTesting, "")
        XCTAssertEqual(popoverPanel.transcriptForTesting, "")
        XCTAssertTrue(sidebarPanel.showsEmptyStateForTesting)
        XCTAssertTrue(popoverPanel.showsEmptyStateForTesting)
        assistant.detach()
    }

}
