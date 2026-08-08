import XCTest
@testable import InfinittyKit

final class ChatEnsembleTests: XCTestCase {
    private let choices = [
        PetAssistant.AgentChoice(
            kind: .claude, modelID: "claude-sonnet", displayName: "Claude · Sonnet",
            symbolName: "a.circle"),
        PetAssistant.AgentChoice(
            kind: .codex, modelID: "gpt-5-codex", displayName: "Codex · GPT-5",
            symbolName: "o.circle"),
    ]

    func testAddAgentParserAcceptsProviderAndRejectsMissingValue() {
        XCTAssertEqual(
            try? ChatEnsemble.addAgentArgument(in: "/add-agent claude")?.get(),
            "claude")
        XCTAssertEqual(
            ChatEnsemble.addAgentArgument(in: "please add claude"), nil)
        XCTAssertEqual(
            ChatEnsemble.addAgentArgument(in: "/add-agent")?.failure,
            .missingAgent)
    }

    func testGeneratedAliasesUseModelIdentityInsteadOfProviderOrder() {
        XCTAssertEqual(
            ChatEnsemble.suggestedAlias(
                provider: "codex", modelTitle: "Codex · GPT-5",
                modelID: "gpt-5"),
            "gpt-5")
        XCTAssertEqual(
            ChatEnsemble.suggestedAlias(
                provider: "claude", modelTitle: "Claude · Claude Sonnet 5",
                modelID: "claude-sonnet-5"),
            "sonnet")
        XCTAssertEqual(
            ChatEnsemble.suggestedAlias(
                provider: "codex", modelTitle: "Codex · GPT-5",
                modelID: "gpt-5-codex"),
            "codex")
        XCTAssertEqual(
            ConfiguredChatAgent(
                provider: "claude", modelID: "claude-sonnet-5",
                modelTitle: "Claude · Claude Sonnet 5", effort: "Auto",
                alias: "!!!").alias,
            "sonnet")
        let first = ConfiguredChatAgent(
            provider: "hermes", modelID: "openrouter:foo/model-a",
            modelTitle: "Hermes · Model A", effort: "High", alias: "first")
        let renamed = ConfiguredChatAgent(
            provider: "hermes", modelID: "openrouter:foo/model-a",
            modelTitle: "Hermes · Model A", effort: "High", alias: "second")
        XCTAssertEqual(first.id, renamed.id, "aliases must not change backend identity")
        XCTAssertNotEqual(
            first.id,
            ConfiguredChatAgent(
                provider: "hermes", modelID: "openrouter:foo/model-b",
                modelTitle: "Hermes · Model A", effort: "High", alias: "other").id,
            "distinct exact model ids need distinct backend state")
    }

    func testResolverSupportsProviderAndExactModelAliases() {
        let claude = ChatEnsemble.resolve("claude", choices: choices, effort: "Low")
        XCTAssertEqual(claude?.modelTitle, "Claude · Sonnet")
        XCTAssertEqual(claude?.alias, "sonnet", "agents are auto-named from their model")
        XCTAssertEqual(
            ChatEnsemble.resolve("gpt-5-codex", choices: choices, effort: "High")?.provider,
            "codex")
    }

    func testBroadcastAndMentionRoutingAreOrderedAndBoundedOnce() throws {
        let claude = try XCTUnwrap(ChatEnsemble.resolve(
            "claude", choices: choices, effort: "Auto"))
        let codex = try XCTUnwrap(ChatEnsemble.resolve(
            "codex", choices: choices, effort: "Auto"))
        let roster = [claude, codex]
        XCTAssertEqual(try ChatEnsemble.route(prompt: "review this", roster: roster).get(), roster)
        XCTAssertEqual(
            try ChatEnsemble.route(
                prompt: "@codex then @claude and @codex", roster: roster).get(),
            [codex, claude])
    }

    func testUnknownMentionFailsLocally() throws {
        let claude = try XCTUnwrap(ChatEnsemble.resolve(
            "claude", choices: choices, effort: "Auto"))
        XCTAssertEqual(
            ChatEnsemble.route(prompt: "@ghost do this", roster: [claude]).failure,
            .unknownMention("ghost"))
    }

    func testDisabledAgentsDoNotReceiveBroadcastsOrMentions() throws {
        var claude = try XCTUnwrap(ChatEnsemble.resolve(
            "claude", choices: choices, effort: "Auto"))
        let codex = try XCTUnwrap(ChatEnsemble.resolve(
            "codex", choices: choices, effort: "Auto"))
        claude.isEnabled = false

        XCTAssertEqual(
            try ChatEnsemble.route(prompt: "review this", roster: [claude, codex]).get(),
            [codex])
        XCTAssertEqual(
            ChatEnsemble.route(prompt: "@claude review this", roster: [claude, codex]).failure,
            .disabledMention("claude"))
        XCTAssertEqual(
            ChatEnsembleError.disabledMention("claude").description,
            "Agent @claude is disabled. Use the agent control to re-enable it.")
    }

    func testProductionChatStartsWithOneToggleableAutoAgent() throws {
        var backendCalls = 0
        let assistant = PetAssistant(
            config: AppConfig(),
            requestRunner: { _, _, _, _ in backendCalls += 1 })
        let primary = try XCTUnwrap(assistant.configuredAgentsForTesting.first)
        XCTAssertEqual(assistant.controlState().ensembleAgents, ["Auto"])
        XCTAssertTrue(primary.isEnabled)

        assistant.toggleAgentForTesting(primary.id)
        assistant.submitFromControl("do not run")

        XCTAssertEqual(backendCalls, 0)
        XCTAssertTrue(
            assistant.controlState().threads[0].messages.last?.text
                .contains("Every agent") == true)
    }

    func testPeerContextIsBoundedAndMarkedUntrusted() {
        let messages = [AssistantChatMessage(
            role: "Assistant", text: String(repeating: "x", count: 20_000),
            author: "Claude")]
        let context = ChatEnsemble.peerContext(messages: messages)
        XCTAssertLessThanOrEqual(context.utf8.count, ChatEnsemble.maxPeerContextBytes)
        XCTAssertTrue(context.contains("explicitly untrusted"))
        XCTAssertTrue(context.contains("Claude:"))
    }

    func testPetAssistantRunsOneSequentialAttributedFanout() {
        var starts: [(model: String, completion: PetAssistant.AskCompletion)] = []
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto] + choices,
            requestRunner: { _, model, _, completion in
                starts.append((model, completion))
            })
        var emissions: [CollaborationChatEmission] = []
        assistant.configureCollaboration(
            contextProvider: { nil },
            messagePublisher: { emissions.append($0) })
        assistant.submitFromControl("/add-agent claude")
        assistant.submitFromControl("/add-agent codex")
        XCTAssertEqual(assistant.controlState().ensembleAgents, ["Sonnet", "Codex"])

        assistant.submitFromControl("review this")
        XCTAssertEqual(starts.map(\.model), ["Claude · Sonnet"])
        starts[0].completion("claude answer", [], nil)
        XCTAssertEqual(starts.map(\.model), ["Claude · Sonnet", "Codex · GPT-5"])
        starts[1].completion("codex answer", [], nil)

        let messages = assistant.controlState().threads[0].messages
        XCTAssertEqual(messages.filter { $0.role == "You" }.count, 1)
        XCTAssertEqual(messages.suffix(2).map(\.text), ["claude answer", "codex answer"])
        XCTAssertEqual(emissions.filter { $0.kind == .humanPrompt }.count, 1)
        XCTAssertEqual(
            emissions.filter { $0.kind == .agentResponse }.compactMap(\.agentName),
            ["Sonnet", "Codex"])
    }

    func testAgentMentionsTriggerBoundedSequentialPeerFollowUps() {
        var starts: [(model: String, request: String, completion: PetAssistant.AskCompletion)] = []
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto] + choices,
            requestRunner: { request, model, _, completion in
                starts.append((model, request, completion))
            })
        assistant.submitFromControl("/add-agent claude")
        assistant.submitFromControl("/add-agent codex")
        assistant.submitFromControl("work together")

        XCTAssertEqual(starts.map(\.model), ["Claude · Sonnet"])
        XCTAssertTrue(starts[0].request.contains("You are @sonnet"))
        XCTAssertTrue(starts[0].request.contains("@codex"))

        // Codex is already waiting in the initial pass, so this mention does
        // not duplicate its request.
        starts[0].completion("@codex please verify this", [], nil)
        XCTAssertEqual(starts.map(\.model), ["Claude · Sonnet", "Codex · GPT-5"])

        // A backwards mention schedules one bounded Sonnet follow-up.
        starts[1].completion("@sonnet I found one issue", [], nil)
        XCTAssertEqual(starts.map(\.model), [
            "Claude · Sonnet", "Codex · GPT-5", "Claude · Sonnet",
        ])
        XCTAssertTrue(starts[2].request.contains("bounded peer follow-up"))

        // Sonnet may hand back once; Codex then cannot recursively requeue
        // Sonnet because each peer gets at most one follow-up per user turn.
        starts[2].completion("@codex fixed; final check?", [], nil)
        XCTAssertEqual(starts.map(\.model), [
            "Claude · Sonnet", "Codex · GPT-5", "Claude · Sonnet", "Codex · GPT-5",
        ])
        starts[3].completion("@sonnet approved", [], nil)
        XCTAssertEqual(starts.count, 4)

        XCTAssertEqual(
            assistant.controlState().threads[0].messages.filter { $0.role == "You" }.count,
            1)
    }

    func testStatefulAgentsUseDistinctConversationIDsAndPeerAnswers() {
        let first = expectation(description: "first agent")
        let second = expectation(description: "second agent")
        var ids: [String] = []
        var prompts: [String] = []
        var completions: [(PetAssistant.AIOutcome) -> Void] = []
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto] + choices,
            backendRunner: { _, _, user, _, conversationID, _, _, done in
                DispatchQueue.main.async {
                    ids.append(conversationID ?? "")
                    prompts.append(user)
                    completions.append(done)
                    (ids.count == 1 ? first : second).fulfill()
                }
            })
        assistant.submitFromControl("/add-agent claude")
        assistant.submitFromControl("/add-agent codex")
        assistant.submitFromControl("review this")
        wait(for: [first], timeout: 2)
        completions[0](.text("peer answer marker"))
        wait(for: [second], timeout: 2)

        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertTrue(ids.allSatisfy { $0.contains("#agent=") })
        XCTAssertTrue(prompts[1].contains("peer answer marker"))
        XCTAssertTrue(prompts[1].contains("explicitly untrusted"))
        completions[1](.text("done"))
    }

    func testUnknownMentionDoesNotInvokeBackend() {
        var calls = 0
        let assistant = PetAssistant(
            config: AppConfig(), availableChoices: [.auto] + choices,
            requestRunner: { _, _, _, _ in calls += 1 })
        assistant.submitFromControl("/add-agent claude")
        assistant.submitFromControl("@ghost review this")
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(assistant.controlState().threads[0].messages.last?.text
            .contains("Unknown agent mention") == true)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
