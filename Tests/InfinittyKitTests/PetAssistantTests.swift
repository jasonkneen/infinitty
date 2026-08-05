import XCTest
import AppKit
@testable import InfinittyKit

final class PetAssistantTests: XCTestCase {
    func testAppControlStateCanSubmitSelectAndCancelRealChatWork() throws {
        let completed = expectation(description: "control turn completed")
        let assistant = PetAssistant(
            config: AppConfig(),
            requestRunner: { request, _, _, done in
                done("answer to \(request)", [], nil)
                completed.fulfill()
            })
        assistant.setWorkspaceDirectory("/tmp/control-workspace")

        let initial = assistant.controlState()
        XCTAssertEqual(initial.threads.count, 1)
        XCTAssertEqual(initial.workspaceDirectory, "/tmp/control-workspace")

        assistant.submitFromControl("controlled request")
        wait(for: [completed], timeout: 2)
        let answered = assistant.controlState()
        XCTAssertEqual(
            answered.threads.first?.messages.map(\.text),
            ["controlled request", "answer to controlled request"])
        XCTAssertFalse(answered.requestInFlight)

        let firstThread = answered.activeThreadID
        assistant.startNewChat()
        let fresh = assistant.controlState()
        XCTAssertNotEqual(fresh.activeThreadID, firstThread)
        XCTAssertEqual(fresh.threads.count, 2)
        XCTAssertTrue(assistant.selectThreadFromControl(firstThread))
        XCTAssertEqual(assistant.controlState().activeThreadID, firstThread)
        XCTAssertFalse(assistant.selectThreadFromControl("not-a-thread"))

        assistant.cancelConversationWork()
        XCTAssertFalse(assistant.controlState().requestInFlight)
    }


    func testPetSizePresetsChooseNearestMenuSize() {
        XCTAssertEqual(PetSizePreset.nearest(to: 0.22), .tiny)
        XCTAssertEqual(PetSizePreset.nearest(to: 0.34), .small)
        XCTAssertEqual(PetSizePreset.nearest(to: 0.52), .medium)
        XCTAssertEqual(PetSizePreset.nearest(to: 0.8), .large)
        XCTAssertEqual(PetSizePreset.nearest(to: 1.2), .extraLarge)
        XCTAssertEqual(PetSizePreset.allCases.map(\.menuTag), [23, 35, 50, 75, 100])
    }

    func testPetSpeechTextUsesACompactPlainFirstLine() {
        XCTAssertEqual(
            PetSpeechText.notification(
                "\n## Build fixed\n\nThere is much more detail after this."),
            "Done.\nBuild fixed")
        let long = PetSpeechText.preview(String(repeating: "a", count: 180), limit: 112)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertLessThanOrEqual(long.count, 112)
    }

    func testPixelPetSpeechBubbleStaysCompactAndAccessible() {
        let text = "Done.\nYour build passed."
        let bubble = PixelPetSpeechBubble(text: text)
        bubble.frame.size = PixelPetSpeechBubble.fittingSize(for: text)
        XCTAssertGreaterThanOrEqual(bubble.frame.width, 164)
        XCTAssertLessThanOrEqual(bubble.frame.width, 276)
        XCTAssertGreaterThanOrEqual(bubble.frame.height, 52)
        XCTAssertEqual(bubble.accessibilityLabel(), text)
        XCTAssertFalse(
            bubble.subviews.compactMap { $0 as? NSTextField }.first?
                .isAccessibilityElement() ?? true)
    }

    func testPanelAndTerminalContextMenusExposeWorkspaceShortcuts() throws {
        let renderer = Renderer(config: AppConfig(), scale: 2)
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        terminal.renderer = renderer
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let terminalTitles = try XCTUnwrap(terminal.menu(for: event))
            .items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertTrue(terminalTitles.contains("New Chat"))
        XCTAssertTrue(terminalTitles.contains("Browser"))
        XCTAssertTrue(terminalTitles.contains("Files"))
        XCTAssertTrue(terminalTitles.contains("Rename Panel…"))
        XCTAssertEqual(
            terminal.petContextMenuTitlesForTesting,
            ["Ask Infinitty…", "Size", "Hide Until Needed"])

        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        XCTAssertEqual(
            Array(header.contextMenuTitlesForTesting.prefix(4)),
            ["Rename Panel…", "New Chat", "Browser", "Files"])
    }

    func testPanelRenameCommitsInlineAndTabRenameAvoidsSolidBlueFill() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        header.title = "infinitty"
        window.contentView = header
        var committed: String?
        header.onRenameCommit = { committed = $0 }
        header.beginRename()
        let panelEditor = try XCTUnwrap(
            header.subviews.compactMap { $0 as? TabRenameTextView }.first)
        XCTAssertLessThanOrEqual(panelEditor.frame.width, 120)
        panelEditor.string = "Server"
        panelEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(header.title, "Server")
        XCTAssertEqual(committed, "Server")
        XCTAssertFalse(header.isRenamingForTesting)

        let strip = TerminalTabStripView(
            frame: NSRect(x: 0, y: 0, width: 600, height: TerminalTabStripView.height))
        window.contentView = strip
        strip.update(titles: ["infinitty"], selectedIndex: 0)
        strip.layoutSubtreeIfNeeded()
        XCTAssertTrue(strip.beginRename(at: 0, currentName: "infinitty"))
        let frame = try XCTUnwrap(strip.renameEditorFrameForTesting)
        XCTAssertLessThan(frame.width, 150)
        XCTAssertFalse(strip.renameEditorUsesSolidAccentFillForTesting)
    }

    func testChatMarkdownRendersStructureInsteadOfRawMarkers() {
        let rendered = MarkdownRender.attributed(
            "## Root\n\n**Directories:**\n- `Sources` — main code",
            style: .chat)
        XCTAssertFalse(rendered.string.contains("**"))
        XCTAssertFalse(rendered.string.contains("`"))
        XCTAssertTrue(rendered.string.contains("Root"))
        XCTAssertTrue(rendered.string.contains("•  Sources"))
    }

    func testChatMarkdownRendersPipeTableAsNativeTable() {
        let rendered = MarkdownRender.attributed(
            """
            | Files | Directories |
            |---|---|
            | Certificates dev.p12 | assets |
            | README.md | Tests |
            """,
            style: .chat)

        XCTAssertFalse(rendered.string.contains("|"))
        XCTAssertFalse(rendered.string.contains("---"))
        XCTAssertTrue(rendered.string.contains("Files"))
        XCTAssertTrue(rendered.string.contains("Certificates dev.p12"))
        XCTAssertTrue(rendered.string.contains("assets"))
        XCTAssertTrue(rendered.string.contains("README.md"))
        XCTAssertTrue(rendered.string.contains("Tests"))

        let tableBlock = (0..<rendered.length).compactMap { index in
            (rendered.attribute(.paragraphStyle, at: index, effectiveRange: nil)
                as? NSParagraphStyle)?
                .textBlocks
                .first { $0 is NSTextTableBlock } as? NSTextTableBlock
        }.first
        XCTAssertEqual(tableBlock?.table.numberOfColumns, 2)
    }

    func testChatMarkdownRendersOneColumnPipeTable() {
        let rendered = MarkdownRender.attributed(
            """
            | File |
            | --- |
            | README.md |
            """,
            style: .chat)

        XCTAssertFalse(rendered.string.contains("|"))
        let tableBlock = (0..<rendered.length).compactMap { index in
            (rendered.attribute(.paragraphStyle, at: index, effectiveRange: nil)
                as? NSParagraphStyle)?
                .textBlocks
                .first { $0 is NSTextTableBlock } as? NSTextTableBlock
        }.first
        XCTAssertEqual(tableBlock?.table.numberOfColumns, 1)
    }

    func testChatMarkdownKeepsShortRowInTableButStopsAtFollowingHeading() {
        let rendered = MarkdownRender.attributed(
            """
            | File |
            | --- |
            README.md
            # Later | Stuff
            """,
            style: .chat)

        XCTAssertFalse(rendered.string.contains("# Later"))
        let source = rendered.string as NSString
        let readmeIndex = source.range(of: "README.md").location
        let headingIndex = source.range(of: "Later | Stuff").location
        guard readmeIndex != NSNotFound, headingIndex != NSNotFound else {
            return XCTFail("Expected table row and following heading to render")
        }
        let readmeBlocks = (rendered.attribute(
            .paragraphStyle, at: readmeIndex, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks ?? []
        let headingBlocks = (rendered.attribute(
            .paragraphStyle, at: headingIndex, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks ?? []
        XCTAssertTrue(readmeBlocks.contains { $0 is NSTextTableBlock })
        XCTAssertFalse(headingBlocks.contains { $0 is NSTextTableBlock })
    }

    func testParseSearchDirective() {
        XCTAssertEqual(PetAssistant.parseSearchDirective("SEARCH: markdown render"),
                       "markdown render")
        XCTAssertEqual(PetAssistant.parseSearchDirective("SEARCH:  spaced query  "),
                       "spaced query")
        XCTAssertEqual(PetAssistant.parseSearchDirective("SEARCH: *"), "*")
        XCTAssertEqual(PetAssistant.parseSearchDirective("LIST:"), "*")
        XCTAssertEqual(PetAssistant.parseSearchDirective("LIST"), "*")
        XCTAssertNil(PetAssistant.parseSearchDirective("SEARCH:"))
        XCTAssertNil(PetAssistant.parseSearchDirective("Sure! You could try SEARCH: foo"))
        XCTAssertNil(PetAssistant.parseSearchDirective("Just an answer."))
        XCTAssertNil(PetAssistant.parseSearchDirective(nil))
    }

    func testWorkspaceDirectoryWithoutTerminalUsesProcessCwd() {
        let assistant = PetAssistant(config: AppConfig())
        // No session attached — still a real path so chat SEARCH can run.
        let cwd = assistant.workspaceDirectoryForChat()
        XCTAssertFalse(cwd.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cwd))
    }

    func testTerminalAccessDefaultsOffRejectsMissingTerminalAndResetsOnDetach() {
        let assistant = PetAssistant(config: AppConfig())
        XCTAssertFalse(assistant.terminalAvailable)
        XCTAssertFalse(assistant.terminalAccessEnabled)
        XCTAssertFalse(assistant.setTerminalAccessEnabled(true))
        XCTAssertEqual(assistant.controlState().executionMode, "workspace-chat")

        let terminal = TerminalSession(config: AppConfig(), scale: 2)
        terminal.workingDirectory = "/tmp"
        defer { terminal.shutdown() }
        assistant.attach(to: terminal)

        XCTAssertTrue(assistant.terminalAvailable)
        XCTAssertFalse(assistant.terminalAccessEnabled)
        XCTAssertTrue(assistant.setTerminalAccessEnabled(true))
        XCTAssertTrue(assistant.effectiveTerminalAccessEnabled)
        XCTAssertEqual(assistant.controlState().executionMode, "visible-terminal")

        let replacement = TerminalSession(config: AppConfig(), scale: 2)
        replacement.workingDirectory = "/tmp"
        defer { replacement.shutdown() }
        assistant.attach(to: replacement)
        XCTAssertFalse(
            assistant.terminalAccessEnabled,
            "binding a different terminal must require fresh authorization")
        XCTAssertTrue(assistant.setTerminalAccessEnabled(true))

        assistant.detach()
        XCTAssertFalse(assistant.terminalAvailable)
        XCTAssertFalse(assistant.terminalAccessEnabled)
        assistant.attach(to: terminal)
        XCTAssertTrue(assistant.terminalAvailable)
        XCTAssertFalse(assistant.terminalAccessEnabled)
        XCTAssertEqual(assistant.controlState().executionMode, "workspace-chat")
    }

    func testExplicitWorkspaceWinsAcrossChatAndTerminalModes() {
        let assistant = PetAssistant(config: AppConfig())
        assistant.setWorkspaceDirectory("/tmp/explicit-workspace")
        let terminal = TerminalSession(config: AppConfig(), scale: 2)
        terminal.workingDirectory = "/tmp/terminal-workspace"
        defer { terminal.shutdown() }
        assistant.attach(to: terminal)

        XCTAssertEqual(
            assistant.workspaceDirectoryForChat(),
            "/tmp/explicit-workspace")
        XCTAssertTrue(assistant.setTerminalAccessEnabled(true))
        XCTAssertEqual(
            assistant.workspaceDirectoryForChat(),
            "/tmp/explicit-workspace")
    }

    func testModeSpecificPromptsAndSignaturesSeparateTerminalAuthorization() {
        let chat = PetAssistant.systemPromptForTesting(profile: .workspaceChat)
        let terminal = PetAssistant.systemPromptForTesting(profile: .visibleTerminal)
        XCTAssertTrue(chat.contains("EXECUTION MODE: CHAT"))
        XCTAssertTrue(chat.contains("No visible terminal is authorized"))
        XCTAssertTrue(chat.contains("native workspace Read, Write, Edit"))
        XCTAssertTrue(terminal.contains("EXECUTION MODE: TERMINAL"))
        XCTAssertTrue(terminal.contains("explicitly enabled access"))
        XCTAssertTrue(terminal.contains("visible pane"))

        let chatSignature = PetAssistant.backendSessionSignatureForTesting(
            backend: .codex(model: "gpt-test"), cwd: "/tmp/work",
            profile: .workspaceChat)
        let terminalSignature = PetAssistant.backendSessionSignatureForTesting(
            backend: .codex(model: "gpt-test"), cwd: "/tmp/work",
            profile: .visibleTerminal)
        XCTAssertNotEqual(chatSignature, terminalSignature)

        let claudeLow = PetAssistant.backendSessionSignatureForTesting(
            backend: .claude(model: "claude-test"), effort: "Low",
            cwd: "/tmp/work", profile: .workspaceChat)
        let claudeMax = PetAssistant.backendSessionSignatureForTesting(
            backend: .claude(model: "claude-test"), effort: "Max",
            cwd: "/tmp/work", profile: .workspaceChat)
        XCTAssertNotEqual(claudeLow, claudeMax,
                          "a native Claude effort change starts a fresh CLI session")
    }

    func testStatefulModeToggleReleasesAndBootstrapsNewProfileLifecycle() {
        let terminal = TerminalSession(config: AppConfig(), scale: 2)
        terminal.workingDirectory = "/tmp"
        defer { terminal.shutdown() }
        let codex = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-mode-test",
            displayName: "Codex mode test", symbolName: "o.circle")
        let starts = [
            expectation(description: "chat profile turn"),
            expectation(description: "terminal profile turn"),
        ]
        let firstFinished = expectation(description: "chat profile finished")
        var conversationIDs: [String] = []
        var dones: [(PetAssistant.AIOutcome) -> Void] = []
        var registeredSystems: [String] = []
        var releases: [String] = []
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, codex],
            backendRunner: { _, _, _, _, conversationID, _, _, done in
                DispatchQueue.main.async {
                    conversationIDs.append(conversationID ?? "")
                    dones.append(done)
                    starts[dones.count - 1].fulfill()
                }
            },
            conversationRegistrar: { _, system, _, _ in
                registeredSystems.append(system)
            },
            conversationReleaser: { releases.append($0) })
        assistant.attach(to: terminal)
        assistant.onPetMessage = { text in
            if text == "chat profile answer" { firstFinished.fulfill() }
        }
        let panel = assistant.makeSidebarPanelView()
        panel.selectModelForTesting(1)
        panel.submitForTesting("first mode request")
        wait(for: [starts[0]], timeout: 2)
        dones[0](.text("chat profile answer"))
        wait(for: [firstFinished], timeout: 2)

        XCTAssertTrue(assistant.setTerminalAccessEnabled(true))
        panel.submitForTesting("second mode request")
        wait(for: [starts[1]], timeout: 2)

        XCTAssertEqual(releases.count, 1)
        XCTAssertNotEqual(conversationIDs[0], conversationIDs[1])
        XCTAssertEqual(registeredSystems.count, 2)
        XCTAssertTrue(registeredSystems[0].contains("EXECUTION MODE: CHAT"))
        XCTAssertTrue(registeredSystems[1].contains("EXECUTION MODE: TERMINAL"))
        dones[1](.text("terminal profile answer"))
    }

    func testTerminalHistoryIsInjectedOnlyWhenTerminalModeIsEffective() {
        let terminal = TerminalSession(config: AppConfig(), scale: 2)
        terminal.workingDirectory = "/tmp"
        let bytes = Array("SECRET_TERMINAL_OUTPUT\r\n".utf8)
        bytes.withUnsafeBufferPointer {
            terminal.terminal.feed($0.baseAddress!, $0.count)
        }
        defer { terminal.shutdown() }

        let first = expectation(description: "chat-mode turn")
        let second = expectation(description: "terminal-mode turn")
        var users: [String] = []
        let amp = PetAssistant.AgentChoice(
            kind: .amp, modelID: "amp-test",
            displayName: "Amp test", symbolName: "bolt")
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, amp],
            backendRunner: { _, _, user, _, _, _, _, done in
                users.append(user)
                done(.text("ok"))
                (users.count == 1 ? first : second).fulfill()
            })
        assistant.attach(to: terminal)
        let panel = assistant.makeSidebarPanelView()
        panel.selectModelForTesting(1)
        panel.submitForTesting("chat request")
        wait(for: [first], timeout: 2)

        XCTAssertTrue(assistant.setTerminalAccessEnabled(true))
        panel.submitForTesting("terminal request")
        wait(for: [second], timeout: 2)

        XCTAssertEqual(users.count, 2)
        XCTAssertTrue(users[0].contains("workspace Chat mode"))
        XCTAssertFalse(users[0].contains("SECRET_TERMINAL_OUTPUT"))
        XCTAssertTrue(users[1].contains("recent terminal output"))
        XCTAssertTrue(users[1].contains("SECRET_TERMINAL_OUTPUT"))
    }

    func testPanelModeCallbacksUpdateAssistantInLegacyAndShadKitSurfaces() {
        let terminal = TerminalSession(config: AppConfig(), scale: 2)
        terminal.workingDirectory = "/tmp"
        defer { terminal.shutdown() }

        ShadcnChatFeature.overrideForTesting = false
        let legacyAssistant = PetAssistant(config: AppConfig())
        legacyAssistant.attach(to: terminal)
        let legacy = legacyAssistant.makeSidebarPanelView()
        XCTAssertTrue(legacy.terminalModeAvailableForTesting)
        XCTAssertFalse(legacy.terminalModeEnabledForTesting)
        legacy.selectTerminalModeForTesting(true)
        XCTAssertTrue(legacyAssistant.effectiveTerminalAccessEnabled)
        XCTAssertTrue(legacy.terminalModeEnabledForTesting)

        ShadcnChatFeature.overrideForTesting = true
        defer { ShadcnChatFeature.overrideForTesting = nil }
        let shadAssistant = PetAssistant(config: AppConfig())
        shadAssistant.attach(to: terminal)
        let shad = shadAssistant.makeSidebarPanelView()
        XCTAssertEqual(shad.shadcnTerminalModeAvailableForTesting, true)
        XCTAssertEqual(shad.shadcnTerminalModeEnabledForTesting, false)
        shad.selectShadcnTerminalModeForTesting(true)
        XCTAssertTrue(shadAssistant.effectiveTerminalAccessEnabled)
        XCTAssertEqual(shad.shadcnTerminalModeEnabledForTesting, true)
    }

    func testConnectedChatInjectsIdentityAndPublishesBothSidesOfTurn() throws {
        let endpointOne = CollaborationEndpoint(
            id: "instance/chat-1", kind: .chat, label: "Chat 1",
            participantID: "participant-chat-1", instanceID: "instance")
        let endpointTwo = CollaborationEndpoint(
            id: "instance/chat-2", kind: .chat, label: "Chat 2",
            participantID: "participant-chat-2", instanceID: "instance")
        let context = try XCTUnwrap(CollaborationChatContext(
            snapshot: CollaborationSnapshot(
                revision: 3,
                channels: [
                    CollaborationChannelState(
                        id: "channel-1", name: "Channel 1", colorHex: "#3366FF",
                        createdAt: Date(), revision: 3,
                        endpoints: [endpointOne, endpointTwo],
                        participants: [
                            CollaborationParticipant(
                                id: "participant-chat-1", displayName: "Chat 1",
                                role: "coding agent", provider: "codex"),
                            CollaborationParticipant(
                                id: "participant-chat-2", displayName: "Chat 2",
                                role: "coding agent", provider: "claude"),
                        ],
                        responsibilities: [], plan: [], messages: []),
                ]),
            endpointID: endpointTwo.id))

        let backendStarted = expectation(description: "provider received Channel context")
        let responsePublished = expectation(description: "assistant response published")
        var providerUser = ""
        var emissions: [CollaborationChatEmission] = []
        var provenance: (String?, String?)?
        let amp = PetAssistant.AgentChoice(
            kind: .amp, modelID: "amp-test",
            displayName: "Amp test", symbolName: "bolt")
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, amp],
            backendRunner: { _, _, user, _, _, _, _, done in
                DispatchQueue.main.async {
                    providerUser = user
                    backendStarted.fulfill()
                    done(.text("I am Chat 2 in Channel 1 with Chat 1."))
                }
            })
        assistant.configureCollaboration(
            contextProvider: { context },
            messagePublisher: { emission in
                emissions.append(emission)
                if emission.kind == .agentResponse {
                    responsePublished.fulfill()
                }
            },
            identityPublisher: { provider, model in
                provenance = (provider, model)
            })
        let panel = assistant.makeSidebarPanelView()

        panel.selectModelForTesting(1)
        panel.submitForTesting("Are you connected to another chat?")
        wait(for: [backendStarted, responsePublished], timeout: 2)

        XCTAssertTrue(providerUser.contains("ACTIVE INFINITTY CHANNEL"))
        XCTAssertTrue(providerUser.contains("Your participant name: \"Chat 2\""))
        XCTAssertTrue(providerUser.contains("Channel: \"Channel 1\""))
        XCTAssertTrue(providerUser.contains("- \"Chat 1\" [chat]"))
        XCTAssertTrue(providerUser.contains("Are you connected to another chat?"))
        XCTAssertEqual(emissions.map(\.kind), [.humanPrompt, .agentResponse])
        XCTAssertEqual(emissions.first?.text, "Are you connected to another chat?")
        XCTAssertEqual(
            emissions.last?.text,
            "I am Chat 2 in Channel 1 with Chat 1.")
        XCTAssertEqual(emissions.first?.threadID, emissions.last?.threadID)
        XCTAssertEqual(provenance?.0, "amp")
        XCTAssertEqual(provenance?.1, "amp-test")
    }

    func testCombinedBackendRetainsCompleteChannelIdentityWithMaximumRequest()
        throws
    {
        let one = CollaborationEndpoint(
            id: "instance/chat-1", kind: .chat, label: "Chat 1",
            participantID: "participant-1")
        let two = CollaborationEndpoint(
            id: "instance/chat-2", kind: .chat, label: "Chat 2",
            participantID: "participant-2")
        let context = try XCTUnwrap(CollaborationChatContext(
            snapshot: CollaborationSnapshot(
                revision: 1,
                channels: [
                    CollaborationChannelState(
                        id: "channel", name: "Release Channel",
                        colorHex: "#3366FF", createdAt: Date(), revision: 1,
                        endpoints: [one, two],
                        participants: [
                            CollaborationParticipant(
                                id: "participant-1", displayName: "Chat 1",
                                role: "agent"),
                            CollaborationParticipant(
                                id: "participant-2", displayName: "Chat 2",
                                role: "agent"),
                        ],
                        responsibilities: [], plan: [], messages: []),
                ]),
            endpointID: one.id))
        let requestEnd = "CURRENT-REQUEST-END"
        let user = PetAssistant.composedBackendUserForTesting(
            backend: .amp(model: "amp-test"),
            baseContext: String(repeating: "old-terminal-", count: 2_000),
            collaborationContext: context,
            request: String(repeating: "q", count: 6_000) + requestEnd)

        XCTAssertLessThanOrEqual(
            user.utf8.count, PetAssistant.maximumCombinedUserBytesForTesting)
        XCTAssertTrue(user.contains("--- ACTIVE INFINITTY CHANNEL ---"))
        XCTAssertTrue(user.contains("Your participant name: \"Chat 1\""))
        XCTAssertTrue(user.contains("Channel: \"Release Channel\""))
        XCTAssertTrue(user.contains("- \"Chat 2\" [chat]"))
        XCTAssertTrue(user.contains("--- END ACTIVE INFINITTY CHANNEL ---"))
        XCTAssertTrue(user.hasSuffix(requestEnd))
    }

    func testVisualTransportFailureIsNotPublishedAsAgentResponse() {
        let displayed = expectation(
            description: "transport failure displayed")
        var emissions: [CollaborationChatEmission] = []
        let assistant = PetAssistant(
            config: AppConfig(),
            backendRunner: {
                _, _, _, _, _, _, _, done in
                done(.failure("remote authentication failed"))
            })
        assistant.configureCollaboration(
            contextProvider: { nil },
            messagePublisher: { emissions.append($0) })
        assistant.onPetMessage = { text in
            if text == "remote authentication failed" {
                displayed.fulfill()
            }
        }

        assistant.submitFromControl("start the remote agent")
        wait(for: [displayed], timeout: 2)

        let messages =
            assistant.controlState().threads.first?.messages
        XCTAssertEqual(messages?.map(\.role), ["You", "Failure"])
        XCTAssertEqual(
            messages?.last?.text,
            "remote authentication failed")
        XCTAssertEqual(
            emissions.map(\.kind),
            [.humanPrompt, .runtimeFailure])
        XCTAssertFalse(
            emissions.contains { $0.kind == .agentResponse })
        XCTAssertEqual(
            emissions.last?.text,
            "remote authentication failed")
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
        // Measures the AppKit panel's own subview layout; pin that path.
        ShadcnChatFeature.overrideForTesting = false
        defer { ShadcnChatFeature.overrideForTesting = nil }

        let controller = CodeViewController(config: AppConfig())
        let assistant = PetAssistant(config: AppConfig())
        // Capture the detached panel that attachAssistant will mount. Asking
        // for another panel after attachment intentionally creates a second
        // multi-pane surface, which has no window geometry or first responder.
        let panel = assistant.makeSidebarPanelView()
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

    func testDedicatedChatPaneRemovesInternalTopChromeGap() {
        let controller = CodeViewController(config: AppConfig(), panelKind: .chat)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            controller.chatPageFrameForTesting.maxY,
            controller.view.bounds.maxY,
            accuracy: 0.5)
    }

    func testChatComposerHasEffortAndTransparentSurface() {
        // Asserts the AppKit panel's own subviews; pin that path so
        // the ShadKit default doesn't hide what's being measured.
        ShadcnChatFeature.overrideForTesting = false
        defer { ShadcnChatFeature.overrideForTesting = nil }

        let assistant = PetAssistant(config: AppConfig())
        let panel = assistant.makeSidebarPanelView()
        panel.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        panel.layoutSubtreeIfNeeded()

        // (b) sidebar chat has no panel background — sits on the black host.
        XCTAssertTrue(panel.surfaceIsClearForTesting)
        // (d) labeled chips replace the stock popup + brain glyph: the model
        // chip carries the provider logo + name, the effort chip says what it
        // is and its current value.
        XCTAssertEqual(panel.effortTitlesForTesting, ["Auto", "None", "Low", "Medium", "High"])
        XCTAssertEqual(panel.effortValueForTesting, "Auto")
        XCTAssertTrue(panel.stockModelPopupIsHiddenForTesting)
        XCTAssertEqual(panel.modelChipTitleForTesting, " Auto ▾ ")
        XCTAssertTrue(panel.effortChipTitleForTesting.contains("Effort · Auto"))
        XCTAssertTrue(panel.effortUsesPrimaryActionMenuForTesting)
        XCTAssertLessThanOrEqual(panel.modelChipHeightForTesting, 24)
        XCTAssertTrue(panel.selectEffort(named: "High"))
        XCTAssertEqual(panel.effortValueForTesting, "High")
        XCTAssertTrue(panel.effortChipTitleForTesting.contains("High"))

        // (c) user turns render as bubbles; assistant turns do not.
        panel.setMessages([(role: "You", text: "hi"), (role: "Assistant", text: "hello")])
        panel.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.userBubbleCountForTesting, 1)
        XCTAssertEqual(panel.transcriptForTesting, "YOU\nhi\n\nASSISTANT\nhello")
        XCTAssertTrue(panel.assistantRowsUseFullWidthForTesting)
        XCTAssertLessThanOrEqual(try XCTUnwrap(panel.assistantMetadataGapForTesting), 3.5)

        // Typing indicator appears while thinking and clears afterwards.
        XCTAssertFalse(panel.isShowingTypingIndicatorForTesting)
        panel.setThinking(true)
        XCTAssertTrue(panel.isShowingTypingIndicatorForTesting)
        panel.setThinking(false)
        XCTAssertFalse(panel.isShowingTypingIndicatorForTesting)
    }

    func testComposerPropagatesExtendedEffortIntoTheBackendTurn() {
        let codex = PetAssistant.AgentChoice(
            kind: .codex,
            modelID: "gpt-test",
            displayName: "Codex · GPT Test",
            symbolName: "o.circle",
            supportedEfforts: ["low", "xhigh", "max", "ultra"])
        let started = expectation(description: "backend received effort directive")
        var backendUser = ""
        var dispatchedEffort = ""
        var dispatchedBackend: PetAssistant.Backend?
        let assistant = PetAssistant(
            config: AppConfig(),
            availableChoices: [.auto, codex],
            backendRunner: { _, _, user, _, _, _, _, done in
                backendUser = user
                started.fulfill()
                done(.text("ok"))
            },
            backendInvocationObserver: { backend, effort in
                dispatchedBackend = backend
                dispatchedEffort = effort
            },
            backendWorkScheduler: { $0() })
        let panel = assistant.makeSidebarPanelView()

        panel.selectModelForTesting(1)
        XCTAssertTrue(panel.selectEffort(named: "Max"))
        panel.submitForTesting("solve this")

        wait(for: [started], timeout: 2)
        XCTAssertTrue(backendUser.contains("Reasoning effort: MAX."))
        XCTAssertEqual(dispatchedBackend, .codex(model: "gpt-test"))
        XCTAssertEqual(dispatchedEffort, "Max")
    }

    func testPrewarmPreservesTheActiveThreadsLastClaudeEffort() {
        var config = AppConfig()
        config.aiProvider = "claude"
        config.claudeModel = "claude-test"
        let claude = PetAssistant.AgentChoice(
            kind: .claude,
            modelID: "claude-test",
            displayName: "Claude Test",
            symbolName: "a.circle",
            supportedEfforts: ["low", "high", "max"])
        var scheduled: [() -> Void] = []
        let assistant = PetAssistant(
            config: config,
            availableChoices: [.auto, claude],
            backendRunner: { _, _, _, _, _, _, _, _ in },
            backendWorkScheduler: { scheduled.append($0) })
        let panel = assistant.makeSidebarPanelView()

        panel.selectModelForTesting(1)
        XCTAssertTrue(panel.selectEffort(named: "Max"))
        panel.submitForTesting("hold this turn at the transport boundary")
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(assistant.activeLastSelectedEffortForTesting, "Max")
        let turnSignature = assistant.activeBackendSessionSignatureForTesting
        XCTAssertTrue(turnSignature?.contains("effort:max") == true)

        assistant.prewarm()

        XCTAssertEqual(assistant.activeBackendSessionSignatureForTesting, turnSignature)
        XCTAssertEqual(assistant.activeLastSelectedEffortForTesting, "Max")
    }

    func testComposerControlsSitBelowInputAndQueuedTurnsSitAboveIt() {
        ShadcnChatFeature.overrideForTesting = false
        defer { ShadcnChatFeature.overrideForTesting = nil }

        let panel = PetAssistant(config: AppConfig()).makeSidebarPanelView()
        panel.frame = NSRect(x: 0, y: 0, width: 360, height: 600)
        panel.setQueuedMessages(["second question", "third question"])
        panel.layoutSubtreeIfNeeded()

        XCTAssertTrue(panel.composerControlsAreBelowInputForTesting)
        XCTAssertTrue(panel.queueIsAboveInputForTesting)
        XCTAssertEqual(panel.queuedMessagesForTesting, ["second question", "third question"])
    }

    func testMessagesSubmittedDuringGenerationQueueAndRunInOrder() {
        var started: [String] = []
        var completions: [PetAssistant.AskCompletion] = []
        let assistant = PetAssistant(
            config: AppConfig(),
            requestRunner: { request, _, _, completion in
                started.append(request)
                completions.append(completion)
            })
        let panel = assistant.makeSidebarPanelView()

        panel.submitForTesting("first")
        panel.submitForTesting("second")
        panel.submitForTesting("third")

        XCTAssertEqual(started, ["first"])
        XCTAssertEqual(panel.queuedMessagesForTesting, ["second", "third"])
        XCTAssertEqual(panel.transcriptForTesting, "YOU\nfirst")
        XCTAssertTrue(panel.isShowingTypingIndicatorForTesting)

        completions[0]("first answer", [], nil)

        XCTAssertEqual(started, ["first", "second"])
        XCTAssertEqual(panel.queuedMessagesForTesting, ["third"])
        XCTAssertEqual(
            panel.transcriptForTesting,
            "YOU\nfirst\n\nASSISTANT\nfirst answer\n\nYOU\nsecond")

        completions[1]("second answer", [], nil)
        completions[2]("third answer", [], nil)

        XCTAssertEqual(started, ["first", "second", "third"])
        XCTAssertEqual(panel.queuedMessagesForTesting, [])
        XCTAssertTrue(panel.transcriptForTesting.hasSuffix("ASSISTANT\nthird answer"))
        XCTAssertFalse(panel.isShowingTypingIndicatorForTesting)
    }

    func testVisibleShadKitStopCancelsActiveAndQueuedWork() {
        ShadcnChatFeature.overrideForTesting = true
        defer { ShadcnChatFeature.overrideForTesting = nil }

        var completions: [PetAssistant.AskCompletion] = []
        let assistant = PetAssistant(
            config: AppConfig(),
            requestRunner: { _, _, _, completion in
                completions.append(completion)
            })
        let panel = assistant.makeSidebarPanelView()

        panel.submitForTesting("active")
        panel.submitForTesting("queued")
        XCTAssertTrue(assistant.controlState().requestInFlight)
        XCTAssertEqual(panel.queuedMessagesForTesting, ["queued"])
        XCTAssertTrue(panel.isShowingTypingIndicatorForTesting)

        panel.stopForTesting()

        XCTAssertFalse(assistant.controlState().requestInFlight)
        XCTAssertTrue(panel.queuedMessagesForTesting.isEmpty)
        XCTAssertFalse(panel.isShowingTypingIndicatorForTesting)

        completions[0]("late answer", [], nil)
        XCTAssertFalse(panel.transcriptForTesting.contains("late answer"))
    }

    func testVisibleShadKitStopOnlyCancelsTheSelectedThread() {
        ShadcnChatFeature.overrideForTesting = true
        defer { ShadcnChatFeature.overrideForTesting = nil }

        let codex = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-stop-test",
            displayName: "Codex stop test", symbolName: "o.circle")
        var started: [String] = []
        var completions: [String: (PetAssistant.AIOutcome) -> Void] = [:]
        var conversationIDs: [String: String] = [:]
        var registrations: [String] = []
        var releases: [String] = []
        let seedFinished = expectation(description: "thread A seed completed")
        let queuedFinished = expectation(description: "thread A queue completed")
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, codex],
            backendRunner: { backend, _, user, _, conversationID, _, _, done in
                XCTAssertEqual(backend, .codex(model: "gpt-stop-test"))
                let label = [
                    "thread A seed", "thread B active", "thread A queued",
                ].first(where: { user.contains($0) }) ?? user
                started.append(label)
                completions[label] = done
                conversationIDs[label] = conversationID ?? ""
            },
            backendWorkScheduler: { $0() },
            conversationRegistrar: { backend, _, _, conversationID in
                XCTAssertEqual(backend, .codex(model: "gpt-stop-test"))
                registrations.append(conversationID)
            },
            conversationReleaser: { releases.append($0) })
        assistant.onPetMessage = { text in
            if text == "thread A answer" { seedFinished.fulfill() }
            if text == "queued A answer" { queuedFinished.fulfill() }
        }
        let panel = assistant.makeSidebarPanelView()
        panel.selectModelForTesting(1)

        panel.submitForTesting("thread A seed")
        completions["thread A seed"]?(.text("thread A answer"))
        wait(for: [seedFinished], timeout: 2)
        let threadA = assistant.threadIdsForTesting[0]
        let idA = conversationIDs["thread A seed"]

        panel.newChatForTesting()
        let threadB = assistant.threadIdsForTesting[0]
        panel.submitForTesting("thread B active")
        let idB = conversationIDs["thread B active"]
        assistant.selectThreadForTesting(threadA)
        panel.submitForTesting("thread A queued")

        assistant.selectThreadForTesting(threadB)
        panel.stopForTesting()

        XCTAssertEqual(
            started,
            ["thread A seed", "thread B active", "thread A queued"],
            "stopping B must preserve and immediately resume A's queued turn")
        XCTAssertEqual(conversationIDs["thread A queued"], idA)
        XCTAssertEqual(registrations, [idA, idB].compactMap { $0 })
        XCTAssertEqual(releases, [idB].compactMap { $0 })
        XCTAssertFalse(releases.contains(idA ?? ""))

        completions["thread B active"]?(.text("stale B answer"))
        completions["thread A queued"]?(.text("queued A answer"))
        wait(for: [queuedFinished], timeout: 2)

        assistant.selectThreadForTesting(threadA)
        XCTAssertTrue(panel.transcriptForTesting.contains("queued A answer"))
        XCTAssertFalse(panel.transcriptForTesting.contains("stale B answer"))
    }

    func testAutoRunShowsResolvedProviderAndRetainsFailureState() {
        ShadcnChatFeature.overrideForTesting = true
        defer { ShadcnChatFeature.overrideForTesting = nil }

        var config = AppConfig()
        config.aiProvider = "claude"
        config.claudeModel = "claude-test"
        var done: ((PetAssistant.AIOutcome) -> Void)?
        let assistant = PetAssistant(
            config: config,
            availableChoices: [.auto],
            backendRunner: { backend, _, _, _, _, _, _, completion in
                XCTAssertEqual(backend, .claude(model: "claude-test"))
                done = completion
            },
            backendWorkScheduler: { $0() })
        let finished = expectation(description: "failure rendered")
        assistant.onPetMessage = { text in
            if text.contains("configured turn timeout") {
                finished.fulfill()
            }
        }
        let panel = assistant.makeSidebarPanelView()

        panel.submitForTesting("review everything")

        XCTAssertEqual(
            panel.shadcnStreamingAuthorForTesting,
            "Claude · claude-test")
        done?(.failure("Claude was inactive for the configured turn timeout."))
        wait(for: [finished], timeout: 2)

        XCTAssertEqual(
            panel.shadcnLastMessageAuthorForTesting,
            "Claude · claude-test")
        XCTAssertTrue(panel.shadcnLastMessageIsSystemForTesting)
        XCTAssertEqual(panel.shadcnRunPhaseForTesting, .runFailed)
    }

    func testRunTelemetryIsScopedRetainedAndRejectsLateEvents() throws {
        ShadcnChatFeature.overrideForTesting = true
        defer { ShadcnChatFeature.overrideForTesting = nil }

        var config = AppConfig()
        config.aiProvider = "claude"
        config.claudeModel = "claude-test"
        var scopeID: String?
        var done: ((PetAssistant.AIOutcome) -> Void)?
        let assistant = PetAssistant(
            config: config,
            availableChoices: [.auto],
            backendRunner: { _, _, _, _, conversationID, _, _, completion in
                scopeID = conversationID
                done = completion
            },
            backendWorkScheduler: { $0() })
        let finished = expectation(description: "telemetry run completed")
        assistant.onPetMessage = { text in
            if text == "done" { finished.fulfill() }
        }
        let panel = assistant.makeSidebarPanelView()
        let originalThread = try XCTUnwrap(assistant.threadIdsForTesting.first)

        panel.submitForTesting("inspect telemetry")
        let activeScope = try XCTUnwrap(scopeID)
        AssistantRunEventBus.publish(AssistantRunEvent(
            provenance: .providerReported,
            update: .usage(AssistantRunEvent.Usage(
                contextUsedTokens: 512,
                contextWindowTokens: 16_384,
                cost: AssistantRunEvent.Cost(
                    amount: Decimal(string: "0.01")!, currency: "USD"))),
            scopeID: activeScope))
        AssistantRunEventBus.publish(AssistantRunEvent(
            provenance: .providerReported,
            update: .reasoningSummary(.init(
                state: .completed,
                text: "Checked the provider-designated summary only")),
            scopeID: activeScope))

        XCTAssertEqual(panel.shadcnUsageLabelForTesting, "512 / 16.4K context")
        XCTAssertEqual(panel.shadcnUsageCostLabelForTesting, "USD 0.01")
        XCTAssertEqual(
            panel.shadcnReasoningSummaryForTesting,
            "Checked the provider-designated summary only")

        AssistantRunEventBus.publish(AssistantRunEvent(
            provenance: .providerReported,
            update: .usage(AssistantRunEvent.Usage(contextUsedTokens: 999)),
            scopeID: "wrong-scope"))
        XCTAssertEqual(panel.shadcnUsageLabelForTesting, "512 / 16.4K context")

        done?(.text("done"))
        wait(for: [finished], timeout: 2)
        AssistantRunEventBus.publish(AssistantRunEvent(
            provenance: .providerReported,
            update: .usage(AssistantRunEvent.Usage(contextUsedTokens: 999)),
            scopeID: activeScope))
        XCTAssertEqual(panel.shadcnUsageLabelForTesting, "512 / 16.4K context")

        assistant.startNewChat()
        XCTAssertEqual(panel.shadcnUsageLabelForTesting, "~0 visible tokens")
        assistant.selectThreadForTesting(originalThread)
        XCTAssertEqual(panel.shadcnUsageLabelForTesting, "512 / 16.4K context")
        XCTAssertEqual(
            panel.shadcnReasoningSummaryForTesting,
            "Checked the provider-designated summary only")
    }

    func testRecoveredSessionImportsTurnsAndPrefixesFirstRequest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-chat-recovery-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines: [[String: Any]] = [
            ["type": "user", "message": ["content": "fix the split"]],
            ["type": "assistant", "message": ["content": "I found the layout issue."]],
            ["type": "system", "message": ["content": "housekeeping"]],
        ]
        let data = try lines.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }.joined(separator: "\n").data(using: .utf8)!
        try data.write(to: url)

        let claude = PetAssistant.AgentChoice(
            kind: .claude, modelID: nil,
            displayName: "Claude", symbolName: "a.circle")
        var requests: [String] = []
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, claude],
            requestRunner: { request, _, _, _ in requests.append(request) })
        let panel = assistant.makeSidebarPanelView()

        assistant.prepareRecovery(
            context: "Session ID: 019f7bb9-0f19-7200-8b30-70fcea423ab5",
            provider: .claude, transcriptPath: url.path)
        XCTAssertTrue(panel.transcriptForTesting.contains("fix the split"))
        XCTAssertTrue(panel.transcriptForTesting.contains("I found the layout issue."))
        XCTAssertFalse(panel.transcriptForTesting.contains("housekeeping"))
        XCTAssertEqual(panel.modelValueForTesting, "Claude")

        panel.submitForTesting("carry on")
        let sent = try XCTUnwrap(requests.first)
        XCTAssertTrue(sent.contains("recovered session context"))
        XCTAssertTrue(sent.contains("Session ID:"))
        XCTAssertTrue(sent.contains("fix the split"))
        XCTAssertTrue(sent.contains("I found the layout issue."))
        XCTAssertTrue(sent.contains("carry on"))
        XCTAssertTrue(panel.transcriptForTesting.hasSuffix("YOU\ncarry on"))
    }

    func testNewChatDropsQueuedTurnsAndIgnoresStaleCompletion() {
        var started: [String] = []
        var completions: [PetAssistant.AskCompletion] = []
        let assistant = PetAssistant(
            config: AppConfig(),
            requestRunner: { request, _, _, completion in
                started.append(request)
                completions.append(completion)
            })
        let panel = assistant.makeSidebarPanelView()

        panel.submitForTesting("old in flight")
        panel.submitForTesting("old queued")
        panel.newChatForTesting()
        panel.submitForTesting("new chat")

        // New chat cancels the previous thread's queue and frees the runner,
        // so "new chat" starts immediately rather than sitting queued.
        XCTAssertEqual(started, ["old in flight", "new chat"])
        XCTAssertEqual(completions.count, 2)
        completions[0]("stale answer", ["Old.swift"], "old")

        XCTAssertFalse(panel.transcriptForTesting.contains("stale answer"))
        XCTAssertFalse(panel.transcriptForTesting.contains("old queued"))
        XCTAssertEqual(panel.transcriptForTesting, "YOU\nnew chat")
        XCTAssertFalse(panel.showsFilesButtonForTesting)
        XCTAssertTrue(panel.isShowingTypingIndicatorForTesting)

        completions[1]("fresh answer", [], nil)
        XCTAssertTrue(panel.transcriptForTesting.contains("fresh answer"))
        XCTAssertFalse(panel.isShowingTypingIndicatorForTesting)
    }

    func testNewThreadDoesNotInheritRecoveredSessionContext() throws {
        var requests: [String] = []
        let assistant = PetAssistant(
            config: AppConfig(),
            requestRunner: { request, _, _, _ in requests.append(request) })
        let panel = assistant.makeSidebarPanelView()
        assistant.prepareRecovery(
            context: "PRIVATE RECOVERED SESSION", provider: .codex)

        panel.newChatForTesting()
        panel.submitForTesting("fresh thread")

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request, "fresh thread")
        XCTAssertFalse(request.contains("PRIVATE RECOVERED SESSION"))
    }

    func testComposerInputIsHardBoundedByUTF8Bytes() throws {
        var requests: [String] = []
        let assistant = PetAssistant(
            config: AppConfig(),
            requestRunner: { request, _, _, _ in requests.append(request) })
        let panel = assistant.makeSidebarPanelView()
        let oversized = String(
            repeating: "界",
            count: PetAssistant.maximumComposerInputBytesForTesting)
            + "-must-not-survive"

        panel.submitForTesting(oversized)

        let request = try XCTUnwrap(requests.first)
        XCTAssertLessThanOrEqual(
            request.utf8.count,
            PetAssistant.maximumComposerInputBytesForTesting)
        XCTAssertTrue(request.contains("[truncated]"))
        XCTAssertFalse(request.contains("-must-not-survive"))
    }

    func testMultiChatKeepsPriorThreadWhenStartingNew() {
        var completions: [PetAssistant.AskCompletion] = []
        let assistant = PetAssistant(
            config: AppConfig(),
            requestRunner: { _, _, _, completion in
                completions.append(completion)
            })
        let panel = assistant.makeSidebarPanelView()

        panel.submitForTesting("first thread question")
        XCTAssertEqual(completions.count, 1)
        completions[0]("first answer", [], nil)
        XCTAssertTrue(panel.transcriptForTesting.contains("first thread question"))
        XCTAssertTrue(panel.transcriptForTesting.contains("first answer"))

        panel.newChatForTesting()
        XCTAssertEqual(panel.transcriptForTesting, "")
        XCTAssertEqual(assistant.threadCountForTesting, 2)
        XCTAssertEqual(assistant.activeThreadTitleForTesting, "New chat")

        // Prior thread remains selectable and still has its transcript.
        let priorId = assistant.threadIdsForTesting[1]
        assistant.selectThreadForTesting(priorId)
        XCTAssertTrue(panel.transcriptForTesting.contains("first answer"))
        XCTAssertEqual(assistant.activeThreadTitleForTesting, "first thread question")
    }

    func testDroppingActiveThreadResumesQueuedRequestFromAnotherThread() {
        var started: [String] = []
        var completions: [PetAssistant.AskCompletion] = []
        let assistant = PetAssistant(
            config: AppConfig(),
            requestRunner: { request, _, _, completion in
                started.append(request)
                completions.append(completion)
            })
        let panel = assistant.makeSidebarPanelView()

        panel.submitForTesting("thread A seed")
        completions[0]("thread A answer", [], nil)
        let threadA = assistant.threadIdsForTesting[0]

        panel.newChatForTesting()
        let threadB = assistant.threadIdsForTesting[0]
        panel.submitForTesting("thread B active")
        assistant.selectThreadForTesting(threadA)
        panel.submitForTesting("thread A queued")
        XCTAssertEqual(panel.queuedMessagesForTesting, ["thread A queued"])

        assistant.selectThreadForTesting(threadB)
        panel.newChatForTesting()

        XCTAssertEqual(
            started,
            ["thread A seed", "thread B active", "thread A queued"],
            "cancelling B must immediately release the global request gate for A")
        completions[1]("stale B answer", [], nil)
        completions[2]("queued A answer", [], nil)
        assistant.selectThreadForTesting(threadA)
        XCTAssertTrue(panel.transcriptForTesting.contains("queued A answer"))
        XCTAssertFalse(panel.transcriptForTesting.contains("stale B answer"))
    }

    func testFileResultsStayWithTheirThreadWhenCompletionArrivesInBackground() {
        var completions: [PetAssistant.AskCompletion] = []
        let assistant = PetAssistant(
            config: AppConfig(),
            requestRunner: { _, _, _, completion in completions.append(completion) })
        let panel = assistant.makeSidebarPanelView()
        var shown: [([String], String?)] = []
        assistant.onShowInSidePanel = { shown.append(($0, $1)) }

        panel.submitForTesting("find alpha")
        completions[0]("alpha answer", ["Alpha.swift"], "alpha")
        let alphaThread = assistant.threadIdsForTesting[0]

        panel.newChatForTesting()
        let betaThread = assistant.threadIdsForTesting[0]
        panel.submitForTesting("find beta")
        assistant.selectThreadForTesting(alphaThread)
        completions[1]("beta answer", ["Beta.swift"], "beta")

        XCTAssertTrue(panel.showsFilesButtonForTesting)
        panel.showFilesForTesting()
        XCTAssertEqual(shown.last?.0, ["Alpha.swift"])
        XCTAssertEqual(shown.last?.1, "alpha")

        assistant.selectThreadForTesting(betaThread)
        XCTAssertTrue(panel.showsFilesButtonForTesting)
        panel.showFilesForTesting()
        XCTAssertEqual(shown.last?.0, ["Beta.swift"])
        XCTAssertEqual(shown.last?.1, "beta")
    }

    func testLateBackendPartialCannotPaintTheNewThread() {
        ShadcnChatFeature.overrideForTesting = true
        defer { ShadcnChatFeature.overrideForTesting = nil }

        let firstStarted = expectation(description: "first backend turn")
        let secondStarted = expectation(description: "second backend turn")
        let freshFinished = expectation(description: "fresh answer accepted")
        var turns: [(
            partial: ((String) -> Void)?,
            done: (PetAssistant.AIOutcome) -> Void
        )] = []
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto],
            backendRunner: { _, _, _, _, _, partial, _, done in
                DispatchQueue.main.async {
                    turns.append((partial, done))
                    (turns.count == 1 ? firstStarted : secondStarted).fulfill()
                }
            })
        assistant.onPetMessage = { answer in
            if answer == "fresh answer" { freshFinished.fulfill() }
        }
        let panel = assistant.makeSidebarPanelView()

        panel.submitForTesting("old request")
        wait(for: [firstStarted], timeout: 2)
        panel.newChatForTesting()
        panel.submitForTesting("new request")
        wait(for: [secondStarted], timeout: 2)

        turns[1].partial?("fresh partial")
        XCTAssertEqual(panel.streamingTextForTesting, "fresh partial")
        turns[0].partial?("late stale partial")
        XCTAssertEqual(
            panel.streamingTextForTesting, "fresh partial",
            "a cancelled request must not overwrite the new request's tail")

        turns[0].done(.text("stale answer"))
        turns[1].done(.text("fresh answer"))
        wait(for: [freshFinished], timeout: 2)
        XCTAssertFalse(panel.transcriptForTesting.contains("stale answer"))
        XCTAssertTrue(panel.transcriptForTesting.contains("fresh answer"))
    }

    func testStatefulProviderRoundTripReleasesAndBootstrapsVisibleHistory() {
        let codex = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-test-a",
            displayName: "Codex A", symbolName: "o.circle")
        let claude = PetAssistant.AgentChoice(
            kind: .claude, modelID: "claude-test-b",
            displayName: "Claude B", symbolName: "a.circle")
        let starts = (1...3).map { expectation(description: "turn \($0) started") }
        let finishes = (1...3).map { expectation(description: "turn \($0) finished") }
        var prompts: [String] = []
        var systems: [String] = []
        var backends: [PetAssistant.Backend] = []
        var conversationIDs: [String?] = []
        var dones: [(PetAssistant.AIOutcome) -> Void] = []
        var releases: [String] = []
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, codex, claude],
            backendRunner: { backend, system, user, _, conversationID, _, _, done in
                DispatchQueue.main.async {
                    backends.append(backend)
                    systems.append(system)
                    prompts.append(user)
                    conversationIDs.append(conversationID)
                    dones.append(done)
                    starts[dones.count - 1].fulfill()
                }
            },
            conversationReleaser: { releases.append($0) })
        assistant.onPetMessage = { answer in
            if let number = Int(answer.replacingOccurrences(of: "answer ", with: "")),
               (1...3).contains(number) {
                finishes[number - 1].fulfill()
            }
        }
        let panel = assistant.makeSidebarPanelView()

        panel.selectModelForTesting(1)
        panel.submitForTesting("question one")
        wait(for: [starts[0]], timeout: 2)
        dones[0](.text("answer 1"))
        wait(for: [finishes[0]], timeout: 2)

        panel.selectModelForTesting(2)
        panel.submitForTesting("question two")
        wait(for: [starts[1]], timeout: 2)
        dones[1](.text("answer 2"))
        wait(for: [finishes[1]], timeout: 2)

        panel.selectModelForTesting(1)
        panel.submitForTesting("question three")
        wait(for: [starts[2]], timeout: 2)

        XCTAssertFalse(prompts[0].contains("--- prior chat turns ---"))
        XCTAssertTrue(prompts[1].contains("question one"))
        XCTAssertTrue(prompts[1].contains("answer 1"))
        XCTAssertTrue(prompts[2].contains("question two"))
        XCTAssertTrue(prompts[2].contains("answer 2"))
        XCTAssertEqual(backends, [
            .codex(model: "gpt-test-a"),
            .claude(model: "claude-test-b"),
            .codex(model: "gpt-test-a"),
        ])
        XCTAssertEqual(
            Set(conversationIDs.compactMap { $0 }).count, 3,
            "each provider lifecycle replacement must rotate its transport epoch")
        XCTAssertTrue(systems.dropFirst().allSatisfy { $0 == systems[0] })
        XCTAssertEqual(
            releases.count, 2,
            "A→B→A must reset keyed state before injecting visible history")

        dones[2](.text("answer 3"))
        wait(for: [finishes[2]], timeout: 2)
    }

    func testStatefulCWDChangesReleaseCodexAndClaudeBeforeHistoryBootstrap() {
        let codex = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-test",
            displayName: "Codex", symbolName: "o.circle")
        let claude = PetAssistant.AgentChoice(
            kind: .claude, modelID: "claude-test",
            displayName: "Claude", symbolName: "a.circle")
        let starts = (1...4).map { expectation(description: "cwd turn \($0)") }
        let finishes = (1...3).map { expectation(description: "cwd finish \($0)") }
        var prompts: [String] = []
        var dones: [(PetAssistant.AIOutcome) -> Void] = []
        var releases: [String] = []
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, codex, claude],
            backendRunner: { _, _, user, _, _, _, _, done in
                DispatchQueue.main.async {
                    prompts.append(user)
                    dones.append(done)
                    starts[dones.count - 1].fulfill()
                }
            },
            conversationReleaser: { releases.append($0) })
        assistant.onPetMessage = { answer in
            if let number = Int(answer.replacingOccurrences(of: "cwd answer ", with: "")),
               (1...3).contains(number) {
                finishes[number - 1].fulfill()
            }
        }
        let panel = assistant.makeSidebarPanelView()

        assistant.setWorkspaceDirectoryForTesting("/tmp/infinitty-cwd-a")
        panel.selectModelForTesting(1)
        panel.submitForTesting("codex cwd one")
        wait(for: [starts[0]], timeout: 2)
        dones[0](.text("cwd answer 1"))
        wait(for: [finishes[0]], timeout: 2)

        assistant.setWorkspaceDirectoryForTesting("/tmp/infinitty-cwd-b")
        panel.submitForTesting("codex cwd two")
        wait(for: [starts[1]], timeout: 2)
        XCTAssertTrue(prompts[1].contains("codex cwd one"))
        XCTAssertEqual(releases.count, 1)
        dones[1](.text("cwd answer 2"))
        wait(for: [finishes[1]], timeout: 2)

        panel.selectModelForTesting(2)
        panel.submitForTesting("claude cwd one")
        wait(for: [starts[2]], timeout: 2)
        dones[2](.text("cwd answer 3"))
        wait(for: [finishes[2]], timeout: 2)

        assistant.setWorkspaceDirectoryForTesting("/tmp/infinitty-cwd-c")
        panel.submitForTesting("claude cwd two")
        wait(for: [starts[3]], timeout: 2)
        XCTAssertTrue(prompts[3].contains("claude cwd one"))
        XCTAssertEqual(
            releases.count, 3,
            "Codex cwd, provider, and Claude cwd transitions each reset keyed state")
        dones[3](.text("cwd answer 4"))
    }

    func testCancelledStatefulThreadBootstrapsHistoryWhenResumed() {
        let codex = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-test",
            displayName: "Codex", symbolName: "o.circle")
        let starts = (1...2).map { expectation(description: "cancel turn \($0)") }
        let firstFinished = expectation(description: "first turn finished")
        var prompts: [String] = []
        var conversationIDs: [String] = []
        var dones: [(PetAssistant.AIOutcome) -> Void] = []
        var releases: [String] = []
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, codex],
            backendRunner: { _, _, user, _, conversationID, _, _, done in
                DispatchQueue.main.async {
                    prompts.append(user)
                    conversationIDs.append(conversationID ?? "")
                    dones.append(done)
                    starts[dones.count - 1].fulfill()
                }
            },
            conversationReleaser: { releases.append($0) })
        assistant.onPetMessage = { answer in
            if answer == "first answer" { firstFinished.fulfill() }
        }
        let panel = assistant.makeSidebarPanelView()

        panel.selectModelForTesting(1)
        panel.submitForTesting("first question")
        wait(for: [starts[0]], timeout: 2)
        let firstToolScope = assistant.activeToolEventScopeIDForTesting
        dones[0](.text("first answer"))
        wait(for: [firstFinished], timeout: 2)

        assistant.cancelConversationWork()
        panel.submitForTesting("after cancellation")
        wait(for: [starts[1]], timeout: 2)

        XCTAssertTrue(prompts[1].contains("first question"))
        XCTAssertTrue(prompts[1].contains("first answer"))
        XCTAssertEqual(releases.count, 1)
        XCTAssertNotEqual(
            conversationIDs[0], conversationIDs[1],
            "cancellation must retry on a new transport epoch")
        XCTAssertEqual(firstToolScope, conversationIDs[0])
        XCTAssertEqual(assistant.activeToolEventScopeIDForTesting, conversationIDs[1])
        XCTAssertNotEqual(
            firstToolScope, assistant.activeToolEventScopeIDForTesting,
            "tool-event scope must advance with the cancelled transport epoch")
        dones[1](.text("resumed answer"))
    }

    func testCombinedBackendsBoundTheActualModelVisibleItemAndKeepNewestSuffix() {
        let system = String(
            repeating: "s", count: PetAssistant.systemPromptBytesForTesting)
        let newestSuffix = String(repeating: "界", count: 400)
            + "-CURRENT-REQUEST-END"
        let user = String(repeating: "old-context-", count: 2_000)
            + newestSuffix
        let combinedBackends: [PetAssistant.Backend] = [
            .command("custom-agent"),
            .codex(model: "gpt-test"),
            .opencode(model: "open-test"),
            .hermes(model: "hermes-test"),
            .amp(model: "amp-test"),
        ]

        XCTAssertEqual(
            PetAssistant.maximumCombinedUserBytesForTesting,
            PetAssistant.maximumBackendUserBytesForTesting
                - PetAssistant.systemPromptBytesForTesting - 2)
        for backend in combinedBackends {
            let payload = PetAssistant.boundedBackendPayload(
                for: backend, system: system, user: user)
            XCTAssertEqual(payload.system, system)
            XCTAssertLessThanOrEqual(
                (payload.system + "\n\n" + payload.user).utf8.count,
                PetAssistant.maximumBackendUserBytesForTesting)
            XCTAssertTrue(
                payload.user.hasSuffix(newestSuffix),
                "\(backend) discarded the newest request suffix")
        }
    }

    func testInvalidateBeforeQueuedBackendStartReleasesRegistrationWithoutInvocation() {
        let codex = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-gated",
            displayName: "Codex gated", symbolName: "o.circle")
        var scheduled: [() -> Void] = []
        var registrations: [String] = []
        var releases: [String] = []
        var backendInvocations = 0
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, codex],
            backendRunner: { _, _, _, _, _, _, _, _ in
                backendInvocations += 1
            },
            backendWorkScheduler: { scheduled.append($0) },
            conversationRegistrar: { _, _, _, id in registrations.append(id) },
            conversationReleaser: { releases.append($0) })
        let panel = assistant.makeSidebarPanelView()

        panel.selectModelForTesting(1)
        panel.submitForTesting("queued request")

        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(registrations.count, 1)
        assistant.invalidate()
        XCTAssertEqual(releases, registrations)

        scheduled[0]()
        XCTAssertEqual(backendInvocations, 0)
        XCTAssertFalse(panel.isShowingTypingIndicatorForTesting)
    }

    func testCancellationAfterFirstStartGuardStillPreventsBackendInvocation() {
        let codex = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-boundary",
            displayName: "Codex boundary", symbolName: "o.circle")
        var scheduled: [() -> Void] = []
        var registrations: [String] = []
        var releases: [String] = []
        var backendInvocations = 0
        weak var weakAssistant: PetAssistant?
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, codex],
            backendRunner: { _, _, _, _, _, _, _, _ in
                backendInvocations += 1
            },
            backendWorkScheduler: { scheduled.append($0) },
            backendStartBoundaryObserver: {
                weakAssistant?.cancelConversationWork()
            },
            conversationRegistrar: { _, _, _, id in registrations.append(id) },
            conversationReleaser: { releases.append($0) })
        weakAssistant = assistant
        let panel = assistant.makeSidebarPanelView()

        panel.selectModelForTesting(1)
        panel.submitForTesting("cancel at start boundary")
        XCTAssertEqual(scheduled.count, 1)

        scheduled[0]()
        XCTAssertEqual(backendInvocations, 0)
        XCTAssertEqual(releases, registrations)
        XCTAssertFalse(panel.isShowingTypingIndicatorForTesting)
    }

    func testLeavingCompletedStatefulThreadKeepsItsTransportEpochOnReturn() {
        let codex = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-stable",
            displayName: "Codex stable", symbolName: "o.circle")
        let starts = (1...2).map { expectation(description: "stable turn \($0)") }
        let firstFinished = expectation(description: "stable first finished")
        var conversationIDs: [String] = []
        var prompts: [String] = []
        var dones: [(PetAssistant.AIOutcome) -> Void] = []
        var releases: [String] = []
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, codex],
            backendRunner: { _, _, user, _, conversationID, _, _, done in
                DispatchQueue.main.async {
                    conversationIDs.append(conversationID ?? "")
                    prompts.append(user)
                    dones.append(done)
                    starts[dones.count - 1].fulfill()
                }
            },
            conversationReleaser: { releases.append($0) })
        assistant.onPetMessage = { answer in
            if answer == "stable answer one" { firstFinished.fulfill() }
        }
        let panel = assistant.makeSidebarPanelView()

        panel.selectModelForTesting(1)
        panel.submitForTesting("stable question one")
        wait(for: [starts[0]], timeout: 2)
        let firstToolScope = assistant.activeToolEventScopeIDForTesting
        dones[0](.text("stable answer one"))
        wait(for: [firstFinished], timeout: 2)
        let completedThread = assistant.threadIdsForTesting[0]

        panel.newChatForTesting()
        assistant.selectThreadForTesting(completedThread)
        panel.submitForTesting("stable question two")
        wait(for: [starts[1]], timeout: 2)

        XCTAssertEqual(conversationIDs[0], conversationIDs[1])
        XCTAssertEqual(firstToolScope, assistant.activeToolEventScopeIDForTesting)
        XCTAssertEqual(releases, [])
        XCTAssertFalse(
            prompts[1].contains("stable answer one"),
            "the retained stateful session must not receive duplicate visible history")
        dones[1](.text("stable answer two"))
    }

    func testFailedStatefulTransitionRetriesWithReleaseAndHistoryBootstrap() {
        let codex = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-before-failure",
            displayName: "Codex before failure", symbolName: "o.circle")
        let claude = PetAssistant.AgentChoice(
            kind: .claude, modelID: "claude-after-failure",
            displayName: "Claude after failure", symbolName: "a.circle")
        let starts = (1...3).map { expectation(description: "failure turn \($0)") }
        let firstFinished = expectation(description: "pre-transition answer finished")
        let failureFinished = expectation(description: "transition failure finished")
        var prompts: [String] = []
        var conversationIDs: [String] = []
        var dones: [(PetAssistant.AIOutcome) -> Void] = []
        var registrations: [String] = []
        var releases: [String] = []
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, codex, claude],
            backendRunner: { _, _, user, _, conversationID, _, _, done in
                DispatchQueue.main.async {
                    prompts.append(user)
                    conversationIDs.append(conversationID ?? "")
                    dones.append(done)
                    starts[dones.count - 1].fulfill()
                }
            },
            conversationRegistrar: { _, _, _, id in registrations.append(id) },
            conversationReleaser: { releases.append($0) })
        assistant.onPetMessage = { answer in
            if answer == "before transition answer" {
                firstFinished.fulfill()
            } else if answer == "transition failed" {
                failureFinished.fulfill()
            }
        }
        let panel = assistant.makeSidebarPanelView()

        panel.selectModelForTesting(1)
        panel.submitForTesting("before transition question")
        wait(for: [starts[0]], timeout: 2)
        dones[0](.text("before transition answer"))
        wait(for: [firstFinished], timeout: 2)

        panel.selectModelForTesting(2)
        panel.submitForTesting("failing transition question")
        wait(for: [starts[1]], timeout: 2)
        dones[1](.failure("transition failed"))
        wait(for: [failureFinished], timeout: 2)

        panel.submitForTesting("retry transition question")
        wait(for: [starts[2]], timeout: 2)

        XCTAssertEqual(
            Set(conversationIDs).count, 3,
            "provider replacement and failed-session retry each need a fresh epoch")
        XCTAssertEqual(registrations.count, 3)
        XCTAssertEqual(
            releases.count, 2,
            "the provider transition and its failed bootstrap retry must both release")
        XCTAssertTrue(prompts[2].contains("before transition question"))
        XCTAssertTrue(prompts[2].contains("before transition answer"))
        XCTAssertTrue(prompts[2].contains("failing transition question"))
        XCTAssertTrue(prompts[2].contains("transition failed"))
        dones[2](.text("retry succeeded"))
    }

    func testSteadyStatefulFailureAlsoReleasesAndBootstrapsRetry() {
        let codex = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-steady-failure",
            displayName: "Codex steady failure", symbolName: "o.circle")
        let starts = (1...3).map { expectation(description: "steady failure \($0)") }
        let seedFinished = expectation(description: "steady failure seed finished")
        let failureFinished = expectation(description: "steady failure displayed")
        var prompts: [String] = []
        var conversationIDs: [String] = []
        var dones: [(PetAssistant.AIOutcome) -> Void] = []
        var releases: [String] = []
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, codex],
            backendRunner: { _, _, user, _, conversationID, _, _, done in
                DispatchQueue.main.async {
                    prompts.append(user)
                    conversationIDs.append(conversationID ?? "")
                    dones.append(done)
                    starts[dones.count - 1].fulfill()
                }
            },
            conversationReleaser: { releases.append($0) })
        assistant.onPetMessage = { answer in
            if answer == "steady seed answer" {
                seedFinished.fulfill()
            } else if answer == "steady transport failed" {
                failureFinished.fulfill()
            }
        }
        let panel = assistant.makeSidebarPanelView()

        panel.selectModelForTesting(1)
        panel.submitForTesting("steady seed question")
        wait(for: [starts[0]], timeout: 2)
        dones[0](.text("steady seed answer"))
        wait(for: [seedFinished], timeout: 2)

        panel.submitForTesting("steady failing question")
        wait(for: [starts[1]], timeout: 2)
        dones[1](.failure("steady transport failed"))
        wait(for: [failureFinished], timeout: 2)

        panel.submitForTesting("steady retry question")
        wait(for: [starts[2]], timeout: 2)

        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(conversationIDs[0], conversationIDs[1])
        XCTAssertNotEqual(conversationIDs[1], conversationIDs[2])
        XCTAssertTrue(prompts[2].contains("steady seed question"))
        XCTAssertTrue(prompts[2].contains("steady seed answer"))
        XCTAssertTrue(prompts[2].contains("steady failing question"))
        XCTAssertTrue(prompts[2].contains("steady transport failed"))
        dones[2](.text("steady retry succeeded"))
    }

    func testStatefulSearchFollowUpSendsOnlySearchResultsAfterBootstrapTurn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "infinitty-stateful-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let matchedName = "backend-session-stateful-result.swift"
        try Data("let statefulResult = true".utf8).write(
            to: root.appendingPathComponent(matchedName))

        let codex = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-search-seed",
            displayName: "Codex search seed", symbolName: "o.circle")
        let claude = PetAssistant.AgentChoice(
            kind: .claude, modelID: "claude-search",
            displayName: "Claude search", symbolName: "a.circle")
        let starts = (1...3).map { expectation(description: "stateful search \($0)") }
        let seedFinished = expectation(description: "stateful search seed finished")
        var prompts: [String] = []
        var dones: [(PetAssistant.AIOutcome) -> Void] = []
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, codex, claude],
            backendRunner: { _, _, user, _, _, _, _, done in
                DispatchQueue.main.async {
                    prompts.append(user)
                    dones.append(done)
                    starts[dones.count - 1].fulfill()
                }
            })
        assistant.setWorkspaceDirectoryForTesting(root.path)
        assistant.onPetMessage = { answer in
            if answer == "stateful seed answer" { seedFinished.fulfill() }
        }
        let panel = assistant.makeSidebarPanelView()

        panel.selectModelForTesting(1)
        panel.submitForTesting("stateful seed question")
        wait(for: [starts[0]], timeout: 2)
        dones[0](.text("stateful seed answer"))
        wait(for: [seedFinished], timeout: 2)

        panel.selectModelForTesting(2)
        panel.submitForTesting("locate the stateful generated source")
        wait(for: [starts[1]], timeout: 2)
        XCTAssertTrue(prompts[1].contains("stateful seed question"))
        XCTAssertTrue(prompts[1].contains("locate the stateful generated source"))
        dones[1](.text("SEARCH: backend-session-stateful-result"))
        wait(for: [starts[2]], timeout: 2)

        XCTAssertTrue(prompts[2].contains(matchedName))
        XCTAssertFalse(prompts[2].contains("--- prior chat turns ---"))
        XCTAssertFalse(prompts[2].contains("stateful seed question"))
        XCTAssertFalse(prompts[2].contains("stateful seed answer"))
        XCTAssertFalse(prompts[2].contains("locate the stateful generated source"))
        dones[2](.text("stateful search complete"))
    }

    func testStatelessSearchFollowUpRetainsHistoryAndCurrentRequest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "infinitty-stateless-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let matchedName = "backend-session-stateless-result.swift"
        try Data("let statelessResult = true".utf8).write(
            to: root.appendingPathComponent(matchedName))

        let amp = PetAssistant.AgentChoice(
            kind: .amp, modelID: "amp-stateless",
            displayName: "Amp stateless", symbolName: "bolt")
        let starts = (1...3).map { expectation(description: "stateless search \($0)") }
        let seedFinished = expectation(description: "stateless search seed finished")
        let historyEnd = "STATELESS-HISTORY-END"
        let currentEnd = "STATELESS-CURRENT-END"
        let largeHistoryAnswer = String(repeating: "h", count: 7_000) + historyEnd
        let currentRequest = String(repeating: "q", count: 450) + currentEnd
        var prompts: [String] = []
        var dones: [(PetAssistant.AIOutcome) -> Void] = []
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, amp],
            backendRunner: { _, _, user, _, _, _, _, done in
                DispatchQueue.main.async {
                    prompts.append(user)
                    dones.append(done)
                    starts[dones.count - 1].fulfill()
                }
            })
        assistant.setWorkspaceDirectoryForTesting(root.path)
        assistant.onPetMessage = { answer in
            if answer.hasSuffix(historyEnd) { seedFinished.fulfill() }
        }
        let panel = assistant.makeSidebarPanelView()

        panel.selectModelForTesting(1)
        panel.submitForTesting("stateless seed question")
        wait(for: [starts[0]], timeout: 2)
        dones[0](.text(largeHistoryAnswer))
        wait(for: [seedFinished], timeout: 2)

        panel.submitForTesting(currentRequest)
        wait(for: [starts[1]], timeout: 2)
        dones[1](.text("SEARCH: backend-session-stateless-result"))
        wait(for: [starts[2]], timeout: 2)

        XCTAssertTrue(prompts[2].contains(matchedName))
        XCTAssertTrue(prompts[2].contains(historyEnd))
        XCTAssertTrue(prompts[2].contains(currentEnd))
        dones[2](.text("stateless search complete"))
    }

    func testCancelledSearchDirectiveCannotStartFollowUpTransport() {
        let codex = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-search-cancel",
            displayName: "Codex search cancel", symbolName: "o.circle")
        let firstStarted = expectation(description: "search source turn")
        var invocations = 0
        var firstDone: ((PetAssistant.AIOutcome) -> Void)?
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, codex],
            backendRunner: { _, _, _, _, _, _, _, done in
                DispatchQueue.main.async {
                    invocations += 1
                    firstDone = done
                    firstStarted.fulfill()
                }
            })
        let panel = assistant.makeSidebarPanelView()

        panel.selectModelForTesting(1)
        panel.submitForTesting("search then cancel")
        wait(for: [firstStarted], timeout: 2)
        panel.newChatForTesting()
        firstDone?(.text("SEARCH: no-such-cancelled-search-result"))

        XCTAssertEqual(invocations, 1)
        XCTAssertEqual(panel.transcriptForTesting, "")
        XCTAssertFalse(panel.isShowingTypingIndicatorForTesting)
    }

    func testBrowserAnnotationContextKeepsNewestMarkerThroughPanelAndBackendBounds() throws {
        let newestMarker = "NEWEST-MARKER-SURVIVES-END-TO-END"
        let annotations = (1...40).map { index in
            BrowserAnnotation(
                id: "annotation-\(index)",
                browserID: "browser-e2e",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                url: "https://example.com/review/\(index)",
                title: "Review page \(index)",
                documentID: 7,
                anchorRef: "anchor-\(index)",
                ref: "",
                tag: "button",
                role: "button",
                accessibleName: "Save item \(index)",
                text: "Save item \(index)",
                selector: "button:nth-of-type(\(index))",
                outerHTML: "",
                comment: index == 40
                    ? String(repeating: "n", count: 1_800) + newestMarker
                    : "older-\(index)-" + String(repeating: "o", count: 1_800),
                screenshotPath: "/tmp/browser-\(index).png")
        }
        let context = BrowserAnnotation.aiContext(for: annotations)
        XCTAssertLessThanOrEqual(
            BrowserAnnotation.maximumAIContextBytes,
            PetAssistant.maximumComposerInputBytesForTesting)
        XCTAssertLessThanOrEqual(
            context.utf8.count, BrowserAnnotation.maximumAIContextBytes)
        let newestSectionRange = try XCTUnwrap(context.range(of: "## 40."))
        let newestSection = String(context[newestSectionRange.lowerBound...])
        XCTAssertTrue(newestSection.contains("Browser ID: browser-e2e"))
        XCTAssertTrue(newestSection.contains("URL: https://example.com/review/40"))
        XCTAssertTrue(newestSection.contains("Title: Review page 40"))
        XCTAssertTrue(newestSection.contains("Selected element: button role=button name=Save item 40"))
        XCTAssertTrue(newestSection.contains("Selector: button:nth-of-type(40)"))
        XCTAssertTrue(newestSection.contains("Visible text: Save item 40"))
        XCTAssertTrue(newestSection.contains(newestMarker))
        XCTAssertTrue(newestSection.contains("Viewport screenshot: /tmp/browser-40.png"))

        var config = AppConfig()
        config.aiProvider = "codex"
        config.codexModel = "gpt-browser-context-test"
        let backendCalled = expectation(description: "bounded browser context reached backend")
        var backendSystem: String?
        var backendUser: String?
        let assistant = PetAssistant(
            config: config,
            availableChoices: [.auto],
            backendRunner: { _, system, user, _, _, _, _, done in
                DispatchQueue.main.async {
                    backendSystem = system
                    backendUser = user
                    done(.text("review accepted"))
                    backendCalled.fulfill()
                }
            })
        let panel = assistant.makeSidebarPanelView()

        panel.submitForTesting(context)
        wait(for: [backendCalled], timeout: 2)

        let deliveredSystem = try XCTUnwrap(backendSystem)
        let delivered = try XCTUnwrap(backendUser)
        XCTAssertLessThanOrEqual(delivered.utf8.count, 10_000)
        XCTAssertLessThanOrEqual(
            (deliveredSystem + "\n\n" + delivered).utf8.count, 10_000)
        XCTAssertTrue(
            delivered.contains(newestSection),
            "the complete newest annotation section must reach the backend intact")
    }

    func testProductionCommandBackendSuppressesStaleFinishSideEffects() throws {
        let gate = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-command-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: gate, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: gate) }
        let quotedGate = gate.path.replacingOccurrences(of: "'", with: "'\\''")

        var config = AppConfig()
        config.aiProvider = "none"
        config.hintCommand = """
        payload="$(cat)"
        if [[ "$payload" == *"old production request"* ]]; then
          touch '\(quotedGate)/old-started'
          while [[ ! -e '\(quotedGate)/new-started' ]]; do sleep 0.01; done
          print -r -- 'stale production answer'
          touch '\(quotedGate)/old-finished'
        else
          touch '\(quotedGate)/new-started'
          while [[ ! -e '\(quotedGate)/release-new' ]]; do sleep 0.01; done
          print -r -- 'fresh production answer'
        fi
        """
        let assistant = PetAssistant(
            config: config, availableChoices: [.auto])
        let panel = assistant.makeSidebarPanelView()
        let staleNotification = expectation(description: "no stale pet notification")
        staleNotification.isInverted = true
        let freshNotification = expectation(description: "fresh pet notification")
        var notifications: [String] = []
        assistant.onPetMessage = { answer in
            notifications.append(answer)
            if answer == "stale production answer" {
                staleNotification.fulfill()
            } else if answer == "fresh production answer" {
                freshNotification.fulfill()
            }
        }

        panel.submitForTesting("old production request")
        waitForFile(gate.appendingPathComponent("old-started"))
        panel.newChatForTesting()
        panel.submitForTesting("new production request")
        waitForFile(gate.appendingPathComponent("new-started"))
        waitForFile(gate.appendingPathComponent("old-finished"))
        wait(for: [staleNotification], timeout: 0.35)

        XCTAssertEqual(panel.transcriptForTesting, "YOU\nnew production request")
        XCTAssertTrue(panel.isShowingTypingIndicatorForTesting)
        XCTAssertEqual(notifications, [])

        FileManager.default.createFile(
            atPath: gate.appendingPathComponent("release-new").path,
            contents: Data())
        wait(for: [freshNotification], timeout: 2)

        XCTAssertEqual(notifications, ["fresh production answer"])
        XCTAssertTrue(panel.transcriptForTesting.contains("fresh production answer"))
        XCTAssertFalse(panel.transcriptForTesting.contains("stale production answer"))
    }

    func testFullShadcnPanelDeactivatesLegacyLayoutAtZeroWidth() {
        ShadcnChatFeature.overrideForTesting = true
        defer { ShadcnChatFeature.overrideForTesting = nil }

        let panel = PetAssistant(config: AppConfig()).makeSidebarPanelView()
        panel.frame = .zero
        panel.setQueuedMessages(["queued visibly"])
        panel.setThinking(true)
        panel.layoutSubtreeIfNeeded()

        XCTAssertTrue(panel.legacyLayoutConstraintsAreInactiveForTesting)
        XCTAssertEqual(panel.queuedMessagesForTesting, ["queued visibly"])
        XCTAssertTrue(panel.isShowingTypingIndicatorForTesting)
    }

    func testSwitchingThreadScopeClearsPriorToolCardsAndAcceptsOnlyNewScope() {
        ShadcnChatFeature.overrideForTesting = true
        defer { ShadcnChatFeature.overrideForTesting = nil }

        var completion: PetAssistant.AskCompletion?
        let assistant = PetAssistant(
            config: AppConfig(),
            requestRunner: { _, _, _, done in completion = done })
        let panel = assistant.makeSidebarPanelView()

        panel.submitForTesting("seed thread A")
        completion?("answer A", [], nil)
        let threadA = assistant.threadIdsForTesting[0]
        let scopeA = assistant.activeToolEventScopeIDForTesting
        AssistantToolEventBus.publish(
            AssistantToolEvent(
                id: "tool-a", name: "search", state: .running,
                scopeID: scopeA))
        XCTAssertEqual(panel.toolCardCountForTesting, 1)

        panel.newChatForTesting()
        let scopeB = assistant.activeToolEventScopeIDForTesting
        XCTAssertEqual(panel.toolCardCountForTesting, 0)

        AssistantToolEventBus.publish(
            AssistantToolEvent(
                id: "late-a", name: "read", state: .running,
                scopeID: scopeA))
        XCTAssertEqual(panel.toolCardCountForTesting, 0)
        AssistantToolEventBus.publish(
            AssistantToolEvent(
                id: "tool-b", name: "write", state: .running,
                scopeID: scopeB))
        XCTAssertEqual(panel.toolCardCountForTesting, 1)

        assistant.selectThreadForTesting(threadA)
        XCTAssertEqual(panel.toolCardCountForTesting, 0)
    }

    func testApprovalCardsAreScopedAndReloadPendingRequestsOnSwitch() {
        ShadcnChatFeature.overrideForTesting = true
        defer { ShadcnChatFeature.overrideForTesting = nil }

        let panel = PetAssistant(config: AppConfig()).makeSidebarPanelView()
        let scopeA = "approval-a-\(UUID().uuidString)"
        let scopeB = "approval-b-\(UUID().uuidString)"
        let requestA = AssistantApprovalRequest(
            scopeID: scopeA, provider: "Claude", kind: .toolUse,
            toolName: "Write")
        let requestB = AssistantApprovalRequest(
            scopeID: scopeB, provider: "Codex", kind: .commandExecution,
            toolName: "shell")
        defer {
            AssistantApprovalBroker.shared.cancel(scopeID: scopeA)
            AssistantApprovalBroker.shared.cancel(scopeID: scopeB)
        }

        panel.setApprovalEventScopeID(scopeA)
        AssistantApprovalBroker.shared.request(requestA) { _ in }
        XCTAssertEqual(panel.approvalRequestCountForTesting, 1)
        XCTAssertEqual(panel.shadcnRunPhaseForTesting, .awaitingApproval)

        panel.setApprovalEventScopeID(scopeB)
        XCTAssertEqual(panel.approvalRequestCountForTesting, 0)
        AssistantApprovalBroker.shared.request(requestB) { _ in }
        XCTAssertEqual(panel.approvalRequestCountForTesting, 1)

        XCTAssertTrue(AssistantApprovalBroker.shared.resolve(
            id: requestA.id, scopeID: scopeA, decision: .deny))
        XCTAssertEqual(panel.approvalRequestCountForTesting, 1)

        panel.setApprovalEventScopeID(scopeA)
        XCTAssertEqual(panel.approvalRequestCountForTesting, 0)
        panel.setApprovalEventScopeID(scopeB)
        XCTAssertEqual(panel.approvalRequestCountForTesting, 1)
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 2) {
        let appeared = expectation(description: "file appeared: \(url.lastPathComponent)")
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: url.path) {
                    appeared.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        wait(for: [appeared], timeout: timeout + 0.25)
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

    func testComposerHidesAppleChoiceButKeepsInteractiveModels() {
        let apple = PetAssistant.AgentChoice(
            kind: .apple, modelID: nil,
            displayName: "Apple On-device", symbolName: "apple.logo")
        let codex = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-5.6",
            displayName: "GPT-5.6", symbolName: "o.circle")
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto, apple, codex])
        let panel = assistant.makeSidebarPanelView()

        XCTAssertEqual(panel.modelItemTitlesForTesting, ["Auto", "GPT-5.6"])
        XCTAssertFalse(panel.selectProvider(.apple))
        XCTAssertTrue(panel.selectProvider(.codex))
    }

    // MARK: - Provider icons

    /// Every provider must produce an icon. Providers with no SVG (hermes has
    /// none) must fall through to the SF Symbol — the path that used to trap
    /// on `Bundle.module` and kill the app when chat opened.
    func testEveryProviderYieldsAnIconEvenWithoutALogoAsset() {
        let kinds: [PetAssistant.AgentChoice.Kind] =
            [.auto, .claude, .codex, .opencode, .hermes, .amp, .apple]
        for kind in kinds {
            let choice = PetAssistant.AgentChoice(
                kind: kind, modelID: nil, displayName: kind.providerLabel,
                symbolName: kind.symbolName)
            XCTAssertNotNil(PetAssistantPanelView.providerImage(for: choice),
                            "\(kind.providerLabel) produced no icon")
        }
    }

    /// The resource-bundle lookup must answer nil rather than trapping when
    /// the bundle is absent, which is how it ships inside Infinitty.app.
    func testResourceLookupIsNonTrappingForAMissingAsset() {
        XCTAssertNil(Bundle.infinittyResourceURL(
            forResource: "definitely-not-a-real-asset", withExtension: "svg",
            subdirectory: "Logos"))
    }

    // MARK: - Model menu

    /// Injected choices keep the panel machine-independent — no CLI is spawned.
    private func panelWithProviders() -> PetAssistantPanelView {
        let codex = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-5.6-sol",
            displayName: "Codex · GPT-5.6-Sol", symbolName: "o.circle")
        let opencode = PetAssistant.AgentChoice(
            kind: .opencode, modelID: nil,
            displayName: "OpenCode · configured default", symbolName: "terminal")
        return PetAssistant(config: AppConfig(), availableChoices: [.auto, codex, opencode])
            .makeSidebarPanelView()
    }

    func testModelMenuIsProviderSubmenusWithNoTypedInput() {
        let panel = panelWithProviders()

        XCTAssertEqual(panel.modelMenuTopLevelForTesting, ["Auto", "Codex", "OpenCode"],
                       "top level stays short: Auto plus one row per provider")

        // The whole point of the change: nowhere in the tree can a model id be
        // typed. Recursively assert the old escape hatch is gone.
        func titles(of menu: NSMenu) -> [String] {
            menu.items.flatMap { [$0.title] + ($0.submenu.map(titles(of:)) ?? []) }
        }
        let everything = titles(of: panel.modelMenuForTesting)
        XCTAssertFalse(everything.contains { $0.hasPrefix("Custom…") },
                       "found a Custom… row: \(everything)")
    }

    func testProviderSubmenuMarksTheProvidersOwnDefault() {
        let panel = panelWithProviders()
        panel.setDiscoveredForTesting(.loaded([
            DiscoveredModel(id: "gpt-5.6-sol", name: "GPT-5.6-Sol", description: nil,
                            isDefault: true, efforts: [], defaultEffort: nil, group: nil),
            DiscoveredModel(id: "gpt-5.5", name: "GPT-5.5", description: nil,
                            isDefault: false, efforts: [], defaultEffort: nil, group: nil),
        ]), for: .codex)

        XCTAssertEqual(panel.modelSubmenuTitlesForTesting(.codex),
                       ["GPT-5.6-Sol  (default)", "GPT-5.5"])
    }

    func testProviderSubmenuExplainsItsOwnFailureAndOffersRetry() {
        let panel = panelWithProviders()
        panel.setDiscoveredForTesting(
            .failed("Unrecognized key: plugins"), for: .opencode)

        XCTAssertEqual(panel.modelSubmenuTitlesForTesting(.opencode),
                       ["⚠ Unrecognized key: plugins", "Retry"])
        XCTAssertEqual(panel.modelSubmenuEnabledTitlesForTesting(.opencode), ["Retry"],
                       "the reason is a label; only Retry is clickable")
    }

    func testLargeProviderNestsBySubProvider() {
        let panel = panelWithProviders()
        // 123 real opencode models span opencode / opencode-go / fireworks-ai.
        let models = (0..<15).map {
            DiscoveredModel(id: "opencode/m\($0)", name: "M\($0)", description: nil,
                            isDefault: false, efforts: [], defaultEffort: nil,
                            group: "opencode")
        } + (0..<10).map {
            DiscoveredModel(id: "fireworks-ai/f\($0)", name: "F\($0)", description: nil,
                            isDefault: false, efforts: [], defaultEffort: nil,
                            group: "fireworks-ai")
        }
        panel.setDiscoveredForTesting(.loaded(models), for: .opencode)

        XCTAssertEqual(panel.modelSubmenuTitlesForTesting(.opencode),
                       ["opencode", "fireworks-ai"],
                       "25 models nest one level rather than listing flat")
    }

    func testSmallProviderStaysFlatEvenWhenPrefixed() {
        let panel = panelWithProviders()
        panel.setDiscoveredForTesting(.loaded((0..<3).map {
            DiscoveredModel(id: "opencode/m\($0)", name: "M\($0)", description: nil,
                            isDefault: false, efforts: [], defaultEffort: nil,
                            group: "opencode")
        }), for: .opencode)

        XCTAssertEqual(panel.modelSubmenuTitlesForTesting(.opencode), ["M0", "M1", "M2"])
    }

    func testEffortChipFollowsTheSelectedModel() {
        let sol = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-5.6-sol", displayName: "Codex · GPT-5.6-Sol",
            symbolName: "o.circle",
            supportedEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
            defaultEffort: "low")
        let claude = PetAssistant.AgentChoice(
            kind: .claude, modelID: "claude-fable-5", displayName: "Claude · Claude Fable 5",
            symbolName: "a.circle")
        let panel = PetAssistant(config: AppConfig(), availableChoices: [.auto, sol, claude])
            .makeSidebarPanelView()

        // Auto reports no efforts, so the fixed list stands.
        XCTAssertEqual(panel.effortTitlesForTesting, ["Auto", "None", "Low", "Medium", "High"])

        panel.selectModelForTesting(1)
        XCTAssertEqual(panel.effortTitlesForTesting,
                       ["Auto", "Low", "Medium", "High", "Xhigh", "Max", "Ultra"],
                       "codex reports six efforts for Sol; the chip offers exactly those")

        // A provider that says nothing about efforts restores the fixed list.
        panel.selectModelForTesting(2)
        XCTAssertEqual(panel.effortTitlesForTesting, ["Auto", "None", "Low", "Medium", "High"])
    }

    func testEffortSelectionSurvivesAModelSwitchThatStillOffersIt() {
        let sol = PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-5.6-sol", displayName: "Codex · Sol",
            symbolName: "o.circle", supportedEfforts: ["low", "high"], defaultEffort: "low")
        let panel = PetAssistant(config: AppConfig(), availableChoices: [.auto, sol])
            .makeSidebarPanelView()

        XCTAssertTrue(panel.selectEffort(named: "High"))
        panel.selectModelForTesting(1)
        XCTAssertEqual(panel.effortValueForTesting, "High",
                       "High survives because Sol still offers it")
    }
    func testPetClickPresentsIndependentAssistantPanel() throws {
        // Asserts the AppKit panel's own subviews; pin that path so
        // the ShadKit default doesn't hide what's being measured.
        ShadcnChatFeature.overrideForTesting = false
        defer { ShadcnChatFeature.overrideForTesting = nil }

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
        XCTAssertEqual(popoverPanel.frame.size, NSSize(width: 400, height: 500))

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
    func testResolveBackendRoutesCustomModelForNewProviders() {
        let config = AppConfig()
        let opencode = PetAssistant.AgentChoice(
            kind: .opencode, modelID: "openai/gpt-5",
            displayName: "OpenCode · openai/gpt-5", symbolName: "terminal")
        XCTAssertEqual(
            PetAssistant.resolveBackend(choice: opencode, config: config),
            .opencode(model: "openai/gpt-5"))
        let hermes = PetAssistant.AgentChoice(
            kind: .hermes, modelID: "hermes-4",
            displayName: "Hermes · hermes-4", symbolName: "brain")
        XCTAssertEqual(
            PetAssistant.resolveBackend(choice: hermes, config: config),
            .hermes(model: "hermes-4"))
        let amp = PetAssistant.AgentChoice(
            kind: .amp, modelID: "claude-x",
            displayName: "Amp · claude-x", symbolName: "bolt")
        XCTAssertEqual(
            PetAssistant.resolveBackend(choice: amp, config: config),
            .amp(model: "claude-x"))
    }

    func testCustomModelChoiceRoundTripsThroughTitleResolution() {
        // A user-typed gateway model (e.g. qwen) must route its exact id,
        // not collapse to Auto — this is the "missing models" fix.
        let custom = PetAssistant.AgentChoice(
            kind: .claude, modelID: "qwen3.8-max-preview",
            displayName: "Claude · qwen3.8-max-preview", symbolName: "a.circle")
        let assistant = PetAssistant(config: AppConfig(), availableChoices: [.auto, custom])
        XCTAssertEqual(
            assistant.resolveBackend(forSelectedTitle: "Claude · qwen3.8-max-preview"),
            .claude(model: "qwen3.8-max-preview"))
    }

    func testKindHelpersRoundTrip() {
        for (kind, raw) in [
            (PetAssistant.AgentChoice.Kind.claude, "claude"),
            (.codex, "codex"),
            (.opencode, "opencode"),
            (.hermes, "hermes"),
            (.amp, "amp"),
        ] {
            XCTAssertEqual(
                PetAssistant.AgentChoice.Kind(configuredProvider: raw), kind)
            XCTAssertFalse(kind.providerLabel.isEmpty)
            XCTAssertFalse(kind.symbolName.isEmpty)
        }
        XCTAssertNil(PetAssistant.AgentChoice.Kind(configuredProvider: "bogus"))
    }

    func testRecentCustomModelsPersistAndDedupe() {
        RecentCustomModels.clearForTesting()
        defer { RecentCustomModels.clearForTesting() }
        RecentCustomModels.record(
            provider: "claude", id: "qwen3.8-max-preview",
            name: "Claude · qwen3.8-max-preview")
        RecentCustomModels.record(
            provider: "claude", id: "qwen3.8-max-preview",
            name: "Claude · qwen3.8-max-preview")
        RecentCustomModels.record(
            provider: "opencode", id: "openai/gpt-5",
            name: "OpenCode · openai/gpt-5")
        let loaded = RecentCustomModels.load()
        XCTAssertEqual(loaded.count, 2, "duplicate provider+id must dedupe")
        XCTAssertEqual(loaded.first?.modelID, "openai/gpt-5", "most-recent first")
        XCTAssertEqual(loaded.first?.kind, .opencode)
    }

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

    /// Regression: a live backend that ERRORED must not be reported the same
    /// as having no backend configured. `.failure` surfaces the real message;
    /// only `.unconfigured` shows the "configure a backend" hint.
    func testDisplayTextDistinguishesUnconfiguredFromFailure() {
        XCTAssertEqual(PetAssistant.displayText(for: .text("hello")), "hello")

        let unconfigured = PetAssistant.displayText(for: .unconfigured)
        XCTAssertTrue(unconfigured.contains("can't reach an AI"))

        let failure = PetAssistant.displayText(for: .failure("Claude: turn timeout"))
        XCTAssertEqual(failure, "Claude: turn timeout")
        XCTAssertFalse(failure.contains("can't reach an AI"),
                       "a real backend error must not be masked by the generic hint")
    }

    /// Only genuine model text is a candidate for `SEARCH:` directive parsing;
    /// failures and the unconfigured case never are.
    func testReplyTextOnlyForModelText() {
        XCTAssertEqual(PetAssistant.replyText(for: .text("SEARCH: foo")), "SEARCH: foo")
        XCTAssertNil(PetAssistant.replyText(for: .unconfigured))
        XCTAssertNil(PetAssistant.replyText(for: .failure("boom")))
    }

}
