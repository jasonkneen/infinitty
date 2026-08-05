import Foundation
import XCTest

@testable import InfinittyKit

final class HeadlessChatRuntimeTests: XCTestCase {
    func testClaudeEffortAndModelChangesRotateLifecycleAndBootstrapHistoryOnce() {
        let completions = (1...4).map {
            expectation(description: "headless Claude turn \($0) completed")
        }
        let turns = HeadlessRuntimeValues<(
            backend: PetAssistant.Backend,
            user: String,
            conversationID: String
        )>()
        let releases = HeadlessRuntimeValues<String>()
        let completedCount = HeadlessRuntimeCounter()
        var config = AppConfig()
        config.aiProvider = "claude"
        config.claudeModel = "claude-model-a"
        let runtime = HeadlessChatRuntime(
            id: "chat-claude-lifecycle",
            participantID: "agent:claude-lifecycle",
            name: "Claude Agent",
            role: "coder",
            workspaceDirectory: "/tmp",
            configuredProvider: "claude",
            configuredModel: "claude-model-a",
            config: config,
            backendRunner: {
                backend, _, user, _, conversationID, _, _, done in
                let turnNumber = turns.values.count + 1
                turns.append((
                    backend: backend,
                    user: user,
                    conversationID: conversationID ?? ""))
                done(.text("answer \(turnNumber)"))
            },
            backendConversationReleaser: { releases.append($0) },
            onStateChange: { state in
                guard state == "completed" else { return }
                completions[completedCount.increment() - 1].fulfill()
            })
        defer { runtime.stop() }

        runtime.submit("question one", model: "claude-model-a", effort: "Low")
        wait(for: [completions[0]], timeout: 2)
        runtime.submit("question two", model: "claude-model-a", effort: "Max")
        wait(for: [completions[1]], timeout: 2)
        runtime.submit("question three", model: "claude-model-b", effort: "Max")
        wait(for: [completions[2]], timeout: 2)
        runtime.submit("question four", model: "claude-model-b", effort: "max")
        wait(for: [completions[3]], timeout: 2)

        let captured = turns.values
        XCTAssertEqual(captured.count, 4)
        XCTAssertNotEqual(
            captured[0].conversationID, captured[1].conversationID,
            "a native effort change must replace Claude's keyed lifecycle")
        XCTAssertNotEqual(
            captured[1].conversationID, captured[2].conversationID,
            "a model change must replace Claude's keyed lifecycle")
        XCTAssertEqual(
            captured[2].conversationID, captured[3].conversationID,
            "canonical-equivalent effort must retain the current lifecycle")
        XCTAssertEqual(
            releases.values,
            [captured[0].conversationID, captured[1].conversationID])

        XCTAssertFalse(captured[0].user.contains("--- prior chat turns ---"))
        XCTAssertTrue(captured[1].user.contains("question one"))
        XCTAssertTrue(captured[1].user.contains("answer 1"))
        XCTAssertEqual(
            captured[1].user.components(
                separatedBy: "--- prior chat turns ---").count - 1,
            1)
        XCTAssertTrue(captured[2].user.contains("question two"))
        XCTAssertTrue(captured[2].user.contains("answer 2"))
        XCTAssertEqual(
            captured[2].user.components(
                separatedBy: "--- prior chat turns ---").count - 1,
            1)
        XCTAssertFalse(
            captured[3].user.contains("--- prior chat turns ---"),
            "steady-state Claude turns must not duplicate visible history")
        XCTAssertFalse(captured[3].user.contains("answer 3"))
    }

    func testStatefulFailureRotatesEpochAndBootstrapsRetryHistory() {
        let failed = expectation(description: "first stateful turn failed")
        let completed = expectation(description: "retry completed")
        let turns = HeadlessRuntimeValues<(user: String, conversationID: String)>()
        let releases = HeadlessRuntimeValues<String>()
        var config = AppConfig()
        config.aiProvider = "claude"
        config.claudeModel = "claude-test"
        let runtime = HeadlessChatRuntime(
            id: "chat-stateful-retry",
            participantID: "agent:stateful-retry",
            name: "Retry Agent",
            role: "coder",
            workspaceDirectory: "/tmp",
            configuredProvider: "claude",
            configuredModel: "claude-test",
            config: config,
            backendRunner: {
                _, _, user, _, conversationID, _, _, done in
                turns.append((user: user, conversationID: conversationID ?? ""))
                if turns.values.count == 1 {
                    done(.failure("provider stalled"))
                } else {
                    done(.text("retry recovered"))
                }
            },
            backendConversationReleaser: { releases.append($0) },
            onStateChange: { state in
                if state == "failed" { failed.fulfill() }
                if state == "completed" { completed.fulfill() }
            })
        defer { runtime.stop() }

        runtime.submit("inspect the workspace", effort: "High")
        wait(for: [failed], timeout: 2)
        runtime.submit("continue the review", effort: "High")
        wait(for: [completed], timeout: 2)

        let captured = turns.values
        XCTAssertEqual(captured.count, 2)
        XCTAssertNotEqual(captured[0].conversationID, captured[1].conversationID)
        XCTAssertEqual(releases.values, [captured[0].conversationID])
        XCTAssertTrue(captured[1].user.contains("--- prior chat turns ---"))
        XCTAssertTrue(captured[1].user.contains("inspect the workspace"))
        XCTAssertTrue(captured[1].user.contains("provider stalled"))
        XCTAssertTrue(captured[1].user.contains("continue the review"))
    }

    func testExtendedEffortPropagatesThroughTheHeadlessRequest() {
        let completed = expectation(description: "headless turn completed")
        let users = HeadlessRuntimeValues<String>()
        var config = AppConfig()
        config.aiProvider = "codex"
        config.codexModel = "gpt-test"
        let runtime = HeadlessChatRuntime(
            id: "chat-native-effort",
            participantID: "agent:effort",
            name: "Effort Agent",
            role: "coder",
            workspaceDirectory: "/tmp",
            configuredProvider: "codex",
            configuredModel: "gpt-test",
            config: config,
            backendRunner: { _, _, user, _, _, _, _, done in
                users.append(user)
                done(.text("ok"))
            },
            onStateChange: { state in
                if state == "completed" { completed.fulfill() }
            })
        defer { runtime.stop() }

        runtime.submit("solve this", effort: "Ultra")
        wait(for: [completed], timeout: 2)

        XCTAssertTrue(users.values.last?.contains(
            "Reasoning effort: ultra;") == true)
    }

    func testHeadlessBootstrapPreservesCurrentRequestWithinProviderPayloadCap() {
        let failed = expectation(description: "first bounded turn failed")
        let completed = expectation(description: "bounded retry completed")
        let payloads = HeadlessRuntimeValues<(system: String, user: String)>()
        var config = AppConfig()
        config.aiProvider = "codex"
        config.codexModel = "gpt-test"
        let runtime = HeadlessChatRuntime(
            id: "chat-bounded-bootstrap",
            participantID: "agent:bounded-bootstrap",
            name: "Bounded Agent",
            role: "coder",
            workspaceDirectory: "/tmp",
            configuredProvider: "codex",
            configuredModel: "gpt-test",
            config: config,
            backendRunner: { _, system, user, _, _, _, _, done in
                payloads.append((system: system, user: user))
                if payloads.values.count == 1 {
                    done(.failure("provider stalled"))
                } else {
                    done(.text("retry recovered"))
                }
            },
            onStateChange: { state in
                if state == "failed" { failed.fulfill() }
                if state == "completed" { completed.fulfill() }
            })
        defer { runtime.stop() }

        runtime.submit("FIRST-" + String(repeating: "a", count: 20_000))
        wait(for: [failed], timeout: 2)
        runtime.submit("SECOND-" + String(repeating: "b", count: 20_000))
        wait(for: [completed], timeout: 2)

        let captured = payloads.values
        XCTAssertEqual(captured.count, 2)
        for payload in captured {
            XCTAssertLessThanOrEqual(
                (payload.system + "\n\n" + payload.user).utf8.count,
                PetAssistant.maximumBackendUserBytesForTesting)
        }
        XCTAssertTrue(captured[1].user.contains("--- prior chat turns ---"))
        XCTAssertTrue(captured[1].user.contains("System: provider stalled"))
        XCTAssertTrue(captured[1].user.contains("--- user request ---"))
        XCTAssertTrue(captured[1].user.contains("SECOND-"))
        XCTAssertTrue(captured[1].user.contains("[request truncated]"))
        XCTAssertLessThanOrEqual(
            runtime.state().threads.first?.messages.first?.text.utf8.count ?? .max,
            6_000)
    }

    func testNativeProvidersShareDocumentedTimeoutPolicy() {
        XCTAssertEqual(
            AssistantTurnTimeoutPolicy.defaultInactivitySeconds, 300)
        XCTAssertEqual(
            AssistantTurnTimeoutPolicy.maximumTurnDurationSeconds, 30 * 60)
    }

    func testTransportFailureIsVisibleButNeverPublishedAsAgentWork() {
        let failed = expectation(
            description: "headless failure is visible")
        let emissions = HeadlessRuntimeValues<
            CollaborationChatEmission>()
        let runtime = HeadlessChatRuntime(
            id: "chat-cloud-failure",
            participantID: "agent:cloud",
            name: "Remote Agent",
            role: "reviewer",
            workspaceDirectory: "/tmp",
            configuredProvider: "codex",
            configuredModel: "opaque-model",
            config: AppConfig(),
            collaborationMessagePublisher: {
                emissions.append($0)
            },
            backendRunner: {
                _, _, _, _, _, _, _, done in
                done(.failure(
                    "Cloud agent failed: authentication rejected"))
            },
            onStateChange: { state in
                if state == "failed" {
                    failed.fulfill()
                }
            })
        defer { runtime.stop() }

        runtime.submit("perform the approved review")
        wait(for: [failed], timeout: 2)

        let messages =
            runtime.state().threads.first?.messages
        XCTAssertEqual(messages?.map(\.role), ["You", "System"])
        XCTAssertEqual(
            messages?.last?.text,
            "Cloud agent failed: authentication rejected")
        XCTAssertEqual(
            emissions.values.map(\.kind),
            [.humanPrompt, .runtimeFailure])
        XCTAssertFalse(
            emissions.values.contains {
                $0.kind == .agentResponse
            })
        XCTAssertEqual(
            emissions.values.last?.text,
            "Cloud agent failed: authentication rejected")
    }
}

private final class HeadlessRuntimeValues<Value>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var stored: [Value] = []

    var values: [Value] {
        lock.withLock { stored }
    }

    func append(_ value: Value) {
        lock.withLock {
            stored.append(value)
        }
    }
}

private final class HeadlessRuntimeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
