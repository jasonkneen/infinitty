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
        XCTAssertEqual(panel.newChatTitleForTesting, "New")
        XCTAssertEqual(
            panel.emptyStateForTesting,
            "Choose an agent, ask a question, and keep chatting here.")
        XCTAssertEqual(panel.modelValueForTesting, "Auto")
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

    func testChatComposerHasEffortAndTransparentSurface() {
        let assistant = PetAssistant(config: AppConfig())
        let panel = assistant.makeSidebarPanelView()
        panel.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        panel.layoutSubtreeIfNeeded()

        // (b) sidebar chat has no panel background — sits on the black host.
        XCTAssertTrue(panel.surfaceIsClearForTesting)
        // (d) an effort/thinking control sits beside the model picker.
        XCTAssertEqual(panel.effortTitlesForTesting, ["Auto", "Low", "Medium", "High"])
        XCTAssertEqual(panel.effortValueForTesting, "Auto")

        // (c) user turns render as bubbles; assistant turns do not.
        panel.setMessages([(role: "You", text: "hi"), (role: "Assistant", text: "hello")])
        panel.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.userBubbleCountForTesting, 1)
        XCTAssertEqual(panel.transcriptForTesting, "YOU\nhi\n\nASSISTANT\nhello")

        // Typing indicator appears while thinking and clears afterwards.
        XCTAssertFalse(panel.isShowingTypingIndicatorForTesting)
        panel.setThinking(true)
        XCTAssertTrue(panel.isShowingTypingIndicatorForTesting)
        panel.setThinking(false)
        XCTAssertFalse(panel.isShowingTypingIndicatorForTesting)
    }

    func testComposerListsInjectedProviderChoices() {
        let claude = PetAssistant.AgentChoice(
            kind: .claude, modelID: "claude-sonnet-5",
            displayName: "Claude Sonnet 5", symbolName: "a.circle")
        let codex = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-5.6",
            displayName: "GPT-5.6", symbolName: "o.circle")
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, claude, codex])
        let panel = assistant.makeSidebarPanelView()
        XCTAssertEqual(panel.modelValueForTesting, "Auto")
        let titles = panel.modelItemTitlesForTesting
        XCTAssertEqual(titles.first, "Auto")
        XCTAssertTrue(titles.contains("Claude Sonnet 5"))
        XCTAssertTrue(titles.contains("GPT-5.6"))

        // Selecting a model routes that exact model id into the backend.
        panel.selectModelForTesting(1)
        XCTAssertEqual(panel.selectedChoiceForTesting.modelID, "claude-sonnet-5")
        XCTAssertEqual(
            PetAssistant.resolveBackend(choice: panel.selectedChoiceForTesting, config: AppConfig()),
            .claude(model: "claude-sonnet-5"))
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
        XCTAssertEqual(popoverPanel.newChatTitleForTesting, "New")
        XCTAssertEqual(popoverPanel.modelValueForTesting, "Auto")
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

    /// The rewritten UI→backend fallthrough: when no provider resolves
    /// (ai-provider set to an unrecognized value so ProviderDiscovery returns
    /// nil regardless of installed CLIs), routing falls through to the
    /// OpenAI endpoint, then the hint-command, then none.
    func testResolveBackendFallthroughWhenNoProvider() {
        var config = AppConfig()
        config.aiProvider = "none"  // unrecognized → preferredProvider returns nil

        // Nothing configured → none.
        XCTAssertEqual(
            PetAssistant.resolveBackend(config: config), .none)

        // hint-command configured → command backend.
        config.hintCommand = "cat"
        XCTAssertEqual(
            PetAssistant.resolveBackend(config: config), .command("cat"))

        // ai-base-url takes precedence over the hint command.
        config.aiBaseURL = "https://api.example.com/v1"
        config.aiModel = "gpt-4o-mini"
        XCTAssertEqual(
            PetAssistant.resolveBackend(config: config),
            .openai(base: "https://api.example.com/v1", key: "", model: "gpt-4o-mini"))
    }

}
