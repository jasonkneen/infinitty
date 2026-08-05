import AIElementsUI
import XCTest
@testable import InfinittyKit

/// Covers the bridge from `PetAssistant`'s transcript model into the
/// ShadKit message list — the part that decides what the chat renders.
@MainActor
final class ShadcnChatTranscriptTests: XCTestCase {

    func testRolesMapFromPetAssistantLabels() {
        let model = ShadcnTranscriptModel()
        model.apply([
            AssistantChatMessage(role: "You", text: "hello"),
            AssistantChatMessage(role: "Claude", text: "hi"),
            AssistantChatMessage(role: "Assistant", text: "again"),
        ])

        XCTAssertEqual(model.messages.map(\.role), [.user, .assistant, .assistant])
        XCTAssertEqual(model.messages.map(\.text), ["hello", "hi", "again"])
    }

    func testAttributedAssistantAuthorProjectsWithoutChangingText() {
        let model = ShadcnTranscriptModel()
        model.apply([AssistantChatMessage(
            role: "Assistant", text: "answer", author: "Claude")])
        XCTAssertEqual(model.messages.first?.author, "Claude")
        XCTAssertEqual(model.messages.first?.text, "answer")
    }

    func testUserRoleMatchIsCaseInsensitive() {
        let model = ShadcnTranscriptModel()
        model.apply([AssistantChatMessage(role: "you", text: "hey")])
        XCTAssertEqual(model.messages.first?.role, .user)
    }

    func testIdentitiesAreStableAcrossAppends() {
        let model = ShadcnTranscriptModel()
        model.apply([AssistantChatMessage(role: "You", text: "one")])
        let firstID = model.messages[0].id

        model.apply([
            AssistantChatMessage(role: "You", text: "one"),
            AssistantChatMessage(role: "Claude", text: "two"),
        ])

        // A growing transcript must not re-identify existing rows, or SwiftUI
        // rebuilds every message on each streamed append.
        XCTAssertEqual(model.messages[0].id, firstID)
        XCTAssertEqual(model.messages.count, 2)
    }

    func testStreamTokenAdvancesAsTextArrives() {
        let model = ShadcnTranscriptModel()
        model.apply([AssistantChatMessage(role: "You", text: "q")])
        let atStart = model.streamToken

        model.streamingText = "partial"
        let midStream = model.streamToken
        XCTAssertNotEqual(atStart, midStream, "the conversation must know to re-pin")

        model.streamingText = "partial answer"
        XCTAssertNotEqual(midStream, model.streamToken)
    }

    func testStreamTokenSeparatesTurnsFromCharacters() {
        let model = ShadcnTranscriptModel()
        model.apply([AssistantChatMessage(role: "You", text: "q")])
        model.streamingText = String(repeating: "x", count: 40)
        let oneTurnLongTail = model.streamToken

        model.apply([
            AssistantChatMessage(role: "You", text: "q"),
            AssistantChatMessage(role: "Claude", text: "a"),
        ])
        model.streamingText = nil

        // Adding a turn must outrank any plausible tail length, so a new
        // message never collides with a long in-flight answer.
        XCTAssertGreaterThan(model.streamToken, oneTurnLongTail)
    }

    // MARK: - Host view feeds

    func testHostViewForwardsTranscriptAndStreaming() {
        let host = ShadcnTranscriptHostView()
        XCTAssertTrue(host.isEmpty)

        host.setMessages([AssistantChatMessage(role: "You", text: "hello")])
        XCTAssertFalse(host.isEmpty)

        host.setStreamingText("thinking out loud")
        XCTAssertFalse(host.isEmpty)
    }

    func testEndingThinkingClearsTheInFlightAnswer() {
        let host = ShadcnTranscriptHostView()
        host.setThinking(true, label: "Opus · thinking")
        host.setStreamingText("half an answer")

        // The completed turn arrives via setMessages; the tail must not linger
        // and render the answer twice.
        host.setThinking(false, label: nil)
        host.setMessages([AssistantChatMessage(role: "Claude", text: "half an answer done")])

        XCTAssertFalse(host.isEmpty)
    }

    func testShadKitChatIsDefaultWithLegacyEscapeHatch() {
        // The port now ships on. The AppKit stack stays reachable so a
        // rendering regression is one env var away from a workaround.
        let chatOptedOut = ProcessInfo.processInfo.environment["INFINITTY_LEGACY_CHAT"] == "1"
        XCTAssertEqual(ShadcnChatFeature.isEnabled, !chatOptedOut)

        let settingsOptedOut =
            ProcessInfo.processInfo.environment["INFINITTY_LEGACY_SETTINGS"] == "1"
        XCTAssertEqual(ShadcnChatFeature.usesShadcnSettings, !settingsOptedOut)
    }

    func testAssistantHostUsesAndLiveAppliesSettingsInterfaceSize() {
        var config = AppConfig()
        config.interfaceFontSize = 18
        let host = ShadcnAssistantHost(config: config)
        XCTAssertEqual(host.model.messageFontSize, 18)

        config.interfaceFontSize = 20
        host.applyAppearance(config: config)
        XCTAssertEqual(host.model.messageFontSize, 20)
    }
}

// MARK: - Tool events

@MainActor
final class AssistantToolEventTests: XCTestCase {

    func testRunningCallBecomesAToolCard() {
        let model = ShadcnTranscriptModel()
        model.apply(
            AssistantToolEvent(id: "t1", name: "search", state: .running, input: "{}"))

        XCTAssertEqual(model.tools.count, 1)
        XCTAssertEqual(model.tools[0].name, "search")
        XCTAssertEqual(model.tools[0].state, .inputAvailable)
    }

    func testResultUpdatesTheCallInPlace() {
        let model = ShadcnTranscriptModel()
        model.apply(AssistantToolEvent(id: "t1", name: "search", state: .running, input: "{}"))
        // A result carries no name — it must not create a second card.
        model.apply(AssistantToolEvent(id: "t1", name: "", state: .completed, output: "ok"))

        XCTAssertEqual(model.tools.count, 1)
        XCTAssertEqual(model.tools[0].state, .outputAvailable)
        XCTAssertEqual(model.tools[0].output, "ok")
        XCTAssertEqual(model.tools[0].name, "search", "the name must survive the result")
    }

    func testFailureMarksTheCallErrored() {
        let model = ShadcnTranscriptModel()
        model.apply(AssistantToolEvent(id: "t1", name: "run", state: .running))
        model.apply(
            AssistantToolEvent(id: "t1", name: "", state: .failed, errorText: "boom"))

        XCTAssertEqual(model.tools[0].state, .outputError)
        XCTAssertEqual(model.tools[0].errorText, "boom")
    }

    func testConcurrentCallsStayDistinct() {
        let model = ShadcnTranscriptModel()
        model.apply(AssistantToolEvent(id: "a", name: "read", state: .running))
        model.apply(AssistantToolEvent(id: "b", name: "write", state: .running))
        model.apply(AssistantToolEvent(id: "a", name: "", state: .completed, output: "1"))

        XCTAssertEqual(model.tools.map(\.name), ["read", "write"])
        XCTAssertEqual(model.tools[0].state, .outputAvailable)
        XCTAssertEqual(model.tools[1].state, .inputAvailable)
    }

    func testToolsClearWhenANewTurnStarts() {
        let host = ShadcnTranscriptHostView()
        host.setThinking(true, label: "Thinking")
        XCTAssertFalse(host.isEmpty)
        // Finished calls belong to the answer that was appended; a new turn
        // starts clean rather than stacking last turn's cards.
        host.setThinking(false, label: nil)
        host.setThinking(true, label: "Thinking")
        XCTAssertFalse(host.isEmpty)
    }

    func testBusDeliversToTheSink() {
        var received: [String] = []
        AssistantToolEventBus.setSink { received.append($0.id) }
        AssistantToolEventBus.publish(
            AssistantToolEvent(id: "x", name: "n", state: .running))
        AssistantToolEventBus.setSink(nil)
        // Publishing after the sink is cleared must be a no-op.
        AssistantToolEventBus.publish(
            AssistantToolEvent(id: "y", name: "n", state: .running))

        XCTAssertEqual(received, ["x"])
    }
}

/// Bridge → transcript mapping for the shapes each provider actually emits.
@MainActor
final class BridgeToolMappingTests: XCTestCase {

    func testClaudeToolUseThenResultResolvesOneCard() {
        let model = ShadcnTranscriptModel()
        // Claude names the tool on `tool_use`, then sends a bare result.
        model.apply(AssistantToolEvent(
            id: "toolu_1", name: "Bash", state: .running, input: "{\"cmd\":\"ls\"}"))
        model.apply(AssistantToolEvent(id: "toolu_1", name: "", state: .completed, output: "a\nb"))

        XCTAssertEqual(model.tools.count, 1)
        XCTAssertEqual(model.tools[0].name, "Bash")
        XCTAssertEqual(model.tools[0].state, .outputAvailable)
        XCTAssertEqual(model.tools[0].input, "{\"cmd\":\"ls\"}", "input survives the result")
    }

    func testACPUpdateWithoutATitleKeepsTheOriginalName() {
        let model = ShadcnTranscriptModel()
        // ACP puts the command in `title` on tool_call; tool_call_update omits it.
        model.apply(AssistantToolEvent(id: "acp-1", name: "terminal: ls -la", state: .running))
        model.apply(AssistantToolEvent(id: "acp-1", name: "", state: .completed, output: "…"))

        XCTAssertEqual(model.tools[0].name, "terminal: ls -la")
    }

    func testCodexItemTypeBecomesTheToolName() {
        let model = ShadcnTranscriptModel()
        // Codex has no tool name; the item type stands in.
        model.apply(AssistantToolEvent(id: "item-1", name: "commandExecution", state: .running))
        XCTAssertEqual(model.tools[0].name, "commandExecution")
    }

    func testAFailedToolCarriesItsErrorNotItsOutput() {
        let model = ShadcnTranscriptModel()
        model.apply(AssistantToolEvent(id: "t", name: "run", state: .running))
        model.apply(AssistantToolEvent(
            id: "t", name: "", state: .failed, errorText: "exit 1"))

        XCTAssertEqual(model.tools[0].state, .outputError)
        XCTAssertEqual(model.tools[0].errorText, "exit 1")
        XCTAssertNil(model.tools[0].output)
    }

    func testAResultArrivingFirstStillCreatesACard() {
        // Ordering isn't guaranteed across a process boundary.
        let model = ShadcnTranscriptModel()
        model.apply(AssistantToolEvent(id: "t", name: "", state: .completed, output: "done"))
        XCTAssertEqual(model.tools.count, 1)
        XCTAssertEqual(model.tools[0].state, .outputAvailable)
    }

    func testRepeatedResultsAreIdempotent() {
        let model = ShadcnTranscriptModel()
        model.apply(AssistantToolEvent(id: "t", name: "x", state: .running))
        for _ in 0..<3 {
            model.apply(AssistantToolEvent(id: "t", name: "", state: .completed, output: "ok"))
        }
        XCTAssertEqual(model.tools.count, 1)
    }

    func testToolOrderFollowsFirstAppearance() {
        let model = ShadcnTranscriptModel()
        model.apply(AssistantToolEvent(id: "b", name: "second", state: .running))
        model.apply(AssistantToolEvent(id: "a", name: "first", state: .running))
        model.apply(AssistantToolEvent(id: "b", name: "", state: .completed))
        XCTAssertEqual(model.tools.map(\.name), ["second", "first"])
    }
}

/// The panel model an AppKit host drives. Its feeds mirror the view it
/// replaced, so a host can be ported one call at a time.
@MainActor
final class AssistantPanelModelTests: XCTestCase {

    func testStatusIsStreamingWhileEitherSignalIsLive() {
        let model = AIAssistantPanelModel()
        XCTAssertEqual(model.status, .ready)

        model.isThinking = true
        XCTAssertEqual(model.status, .streaming)

        model.isThinking = false
        model.streamingText = "partial"
        XCTAssertEqual(model.status, .streaming, "a tail without the flag still counts")

        model.streamingText = nil
        XCTAssertEqual(model.status, .ready)
    }

    func testSubmitTrimsAndClearsTheComposer() {
        let model = AIAssistantPanelModel()
        var sent: (String, String, String)?
        model.onSubmit = { sent = ($0, $1, $2) }
        model.model = "opus"
        model.effort = "High"
        model.input = "  hello  \n"
        model.submit()

        XCTAssertEqual(sent?.0, "hello")
        XCTAssertEqual(sent?.1, "opus")
        XCTAssertEqual(sent?.2, "High")
        XCTAssertTrue(model.input.isEmpty)
    }

    func testSubmitDefaultsToAutoWhenNothingIsPicked() {
        let model = AIAssistantPanelModel()
        var sent: (String, String, String)?
        model.onSubmit = { sent = ($0, $1, $2) }
        model.input = "go"
        model.submit()
        XCTAssertEqual(sent?.1, "Auto")
        XCTAssertEqual(sent?.2, "Auto")
    }

    func testWhitespaceOnlyInputIsNotSent() {
        let model = AIAssistantPanelModel()
        var called = false
        model.onSubmit = { _, _, _ in called = true }
        model.input = "   \n\t "
        model.submit()
        XCTAssertFalse(called)
        XCTAssertFalse(model.input.isEmpty, "a rejected submit must not clear the box")
    }

    func testToolsAreSeparateFromMessagesSoAHostCannotWipeThem() {
        // The bug this guards: a host rebuilding `messages` erased tool cards.
        let model = AIAssistantPanelModel()
        model.applyTool(id: "t", name: "search", state: .outputAvailable, output: "ok")
        model.messages = [UIMessage(role: .assistant, text: "rebuilt transcript")]
        XCTAssertEqual(model.tools.count, 1, "a transcript rebuild must not clear tools")
    }

    func testApplyToolUpdatesInPlaceAndKeepsTheName() {
        let model = AIAssistantPanelModel()
        model.applyTool(id: "t", name: "search", state: .inputAvailable, input: "{}")
        model.applyTool(id: "t", name: "", state: .outputAvailable, output: "done")

        XCTAssertEqual(model.tools.count, 1)
        XCTAssertEqual(model.tools[0].name, "search")
        XCTAssertEqual(model.tools[0].output, "done")
    }

    func testChangingPresentedThreadClearsToolsButSameThreadRefreshKeepsThem() {
        let host = ShadcnAssistantHost()
        host.setThreads(
            [(id: "A", title: "Thread A"), (id: "B", title: "Thread B")],
            activeId: "A")
        host.applyToolEvent(
            AssistantToolEvent(id: "tool-a", name: "search", state: .running))
        XCTAssertEqual(host.model.tools.count, 1)

        host.setThreads(
            [(id: "A", title: "Thread A"), (id: "B", title: "Thread B")],
            activeId: "A")
        XCTAssertEqual(host.model.tools.count, 1)

        // Mirror ShadKit's eager selection binding: it writes the model before
        // the host callback reaches `setThreads`.
        host.model.activeThreadId = "B"
        host.setThreads(
            [(id: "A", title: "Thread A"), (id: "B", title: "Thread B")],
            activeId: "B")
        XCTAssertTrue(host.model.tools.isEmpty)
    }



    func testSubmitUsesPanelModelAndEffortNotStaleHostState() {
        // Regression: onSubmit used to ignore panel args and re-read AppKit
        // selectedChoice/selectedEffort, so a SwiftUI pick that wasn't mirrored
        // would silently submit the stale host value.
        let model = AIAssistantPanelModel()
        var sent: (String, String, String)?
        model.onSubmit = { sent = ($0, $1, $2) }
        model.selectModel("Claude · Sonnet")
        model.selectEffort("High")
        model.input = "go"
        model.submit()
        XCTAssertEqual(sent?.0, "go")
        XCTAssertEqual(sent?.1, "Claude · Sonnet")
        XCTAssertEqual(sent?.2, "High")
    }

    func testSelectModelFiresHostCallback() {
        let model = AIAssistantPanelModel()
        var models: [String] = []
        model.onModelChange = { models.append($0) }
        model.selectModel("Codex · o3")
        XCTAssertEqual(model.model, "Codex · o3")
        XCTAssertEqual(models, ["Codex · o3"])
    }

    func testSubmitPrefersExplicitModelOverAgent() {
        let model = AIAssistantPanelModel()
        var sent: (String, String, String)?
        model.onSubmit = { sent = ($0, $1, $2) }
        model.agent = "Claude"
        model.model = "Claude · Opus"
        model.input = "x"
        model.submit()
        XCTAssertEqual(sent?.1, "Claude · Opus")
    }

    func testAgentAndEffortSelectionFireHostCallbacks() {
        // The bug: pickers bound to $model.agent / $model.effort never called
        // onAgentChange / onEffortChange, so the host kept the old selection.
        let model = AIAssistantPanelModel()
        var agents: [String] = []
        var efforts: [String] = []
        model.onAgentChange = { agents.append($0) }
        model.onEffortChange = { efforts.append($0) }

        model.selectAgent("Claude")
        model.selectEffort("High")

        XCTAssertEqual(model.agent, "Claude")
        XCTAssertEqual(model.effort, "High")
        XCTAssertEqual(agents, ["Claude"])
        XCTAssertEqual(efforts, ["High"])
        // Submit must use the chosen effort/model, not leftover defaults.
        var sent: (String, String, String)?
        model.onSubmit = { sent = ($0, $1, $2) }
        model.model = "opus"
        model.input = "go"
        model.submit()
        XCTAssertEqual(sent?.1, "opus")
        XCTAssertEqual(sent?.2, "High")
    }

        func testStreamTokenRespondsToEveryVisibleChange() {
        let model = AIAssistantPanelModel()
        var seen = Set([model.streamToken])

        model.messages = [UIMessage(role: .user, text: "hi")]
        seen.insert(model.streamToken)
        model.streamingText = "partial"
        seen.insert(model.streamToken)
        model.queued = ["next"]
        seen.insert(model.streamToken)
        model.applyTool(id: "t", name: "x", state: .inputAvailable)
        seen.insert(model.streamToken)

        XCTAssertEqual(seen.count, 5, "each change must re-pin the conversation")
    }
}
