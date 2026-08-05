import XCTest
@testable import InfinittyKit

@MainActor
final class AssistantApprovalTests: XCTestCase {
    func testRequestIsScopedAndWrongScopeCannotResolveIt() {
        let broker = AssistantApprovalBroker()
        let scope = "scope-\(UUID().uuidString)"
        let request = AssistantApprovalRequest(
            scopeID: scope,
            provider: "claude",
            kind: .toolUse,
            toolName: "Write",
            input: #"{"file_path":"README.md"}"#)
        var states: [AssistantApprovalEvent.State] = []
        let decision = LockedApprovalValue<AssistantApprovalDecision?>(nil)
        let subscription = AssistantApprovalEventBus.subscribe(scopeID: scope) {
            states.append($0.state)
        }

        broker.request(request) { decision.set($0) }

        XCTAssertEqual(broker.pendingRequests(scopeID: scope), [request])
        XCTAssertEqual(states, [.requested])
        XCTAssertFalse(broker.resolve(
            id: request.id, scopeID: "another-scope", decision: .allowOnce))
        XCTAssertNil(decision.value)
        XCTAssertTrue(broker.resolve(
            id: request.id, scopeID: scope, decision: .allowOnce))
        XCTAssertEqual(decision.value, .allowOnce)
        XCTAssertEqual(states, [.requested, .resolved])
        XCTAssertTrue(broker.pendingRequests(scopeID: scope).isEmpty)
        withExtendedLifetime(subscription) {}
    }

    func testAllowSessionAppliesOnlyToSameScopedProviderTool() {
        let broker = AssistantApprovalBroker()
        let scope = "scope-\(UUID().uuidString)"
        let first = AssistantApprovalRequest(
            scopeID: scope,
            provider: "codex",
            kind: .commandExecution,
            toolName: "shell",
            input: #"{"command":"swift test"}"#)
        let decisions = LockedApprovalValue<[AssistantApprovalDecision]>([])

        broker.request(first) { decision in
            decisions.mutate { $0.append(decision) }
        }
        XCTAssertTrue(broker.resolve(
            id: first.id, scopeID: scope, decision: .allowSession))

        let granted = AssistantApprovalRequest(
            scopeID: scope,
            provider: "codex",
            kind: .commandExecution,
            toolName: "shell",
            input: #"{"command":"git status"}"#)
        broker.request(granted) { decision in
            decisions.mutate { $0.append(decision) }
        }

        let otherTool = AssistantApprovalRequest(
            scopeID: scope,
            provider: "codex",
            kind: .fileChange,
            toolName: "apply_patch")
        broker.request(otherTool) { decision in
            decisions.mutate { $0.append(decision) }
        }

        XCTAssertEqual(decisions.value, [.allowSession, .allowSession])
        XCTAssertEqual(broker.pendingRequests(scopeID: scope), [otherTool])
        broker.cancel(scopeID: scope)
        XCTAssertEqual(decisions.value, [.allowSession, .allowSession, .cancel])
    }

    func testCancellationReleasesEveryPendingRequestInScope() {
        let broker = AssistantApprovalBroker()
        let scope = "scope-\(UUID().uuidString)"
        let first = AssistantApprovalRequest(
            scopeID: scope, provider: "claude", kind: .toolUse,
            toolName: "Bash")
        let second = AssistantApprovalRequest(
            scopeID: scope, provider: "claude", kind: .toolUse,
            toolName: "WebFetch")
        let resolved = LockedApprovalValue<[String: AssistantApprovalDecision]>([:])

        broker.request(first) { decision in
            resolved.mutate { $0[first.id] = decision }
        }
        broker.request(second) { decision in
            resolved.mutate { $0[second.id] = decision }
        }
        broker.cancel(scopeID: scope)

        XCTAssertEqual(resolved.value[first.id], .cancel)
        XCTAssertEqual(resolved.value[second.id], .cancel)
        XCTAssertTrue(broker.pendingRequests(scopeID: scope).isEmpty)
    }

    func testUnsupportedDecisionIsRejected() {
        let broker = AssistantApprovalBroker()
        let scope = "scope-\(UUID().uuidString)"
        let request = AssistantApprovalRequest(
            scopeID: scope,
            provider: "provider",
            kind: .permissions,
            toolName: "network",
            availableDecisions: [.allowOnce, .deny])

        broker.request(request) { _ in }

        XCTAssertFalse(broker.resolve(
            id: request.id, scopeID: scope, decision: .allowSession))
        XCTAssertTrue(broker.resolve(
            id: request.id, scopeID: scope, decision: .deny))
    }

    func testRequestExpiresFailClosed() {
        let broker = AssistantApprovalBroker()
        let scope = "scope-\(UUID().uuidString)"
        let request = AssistantApprovalRequest(
            scopeID: scope, provider: "provider", kind: .toolUse,
            toolName: "dangerous")
        let expired = expectation(description: "approval expired")
        let decision = LockedApprovalValue<AssistantApprovalDecision?>(nil)

        broker.request(request, timeout: 0.02) {
            decision.set($0)
            expired.fulfill()
        }

        wait(for: [expired], timeout: 1)
        XCTAssertEqual(decision.value, .cancel)
        XCTAssertTrue(broker.pendingRequests(scopeID: scope).isEmpty)
    }
}

private final class LockedApprovalValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}
