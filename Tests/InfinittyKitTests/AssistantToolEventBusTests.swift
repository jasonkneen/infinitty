import XCTest
@testable import InfinittyKit

@MainActor
final class AssistantToolEventBusTests: XCTestCase {
    override func tearDown() {
        AssistantToolEventBus.setSink(nil)
        super.tearDown()
    }

    func testSubscribersAreIndependentlyRemovable() {
        var firstReceived: [String] = []
        var secondReceived: [String] = []
        let first = AssistantToolEventBus.subscribe {
            firstReceived.append($0.id)
        }
        let second = AssistantToolEventBus.subscribe {
            secondReceived.append($0.id)
        }

        AssistantToolEventBus.publish(
            AssistantToolEvent(id: "before", name: "read", state: .running))
        first.cancel()
        AssistantToolEventBus.publish(
            AssistantToolEvent(id: "after", name: "read", state: .completed))

        XCTAssertEqual(firstReceived, ["before"])
        XCTAssertEqual(secondReceived, ["before", "after"])
        withExtendedLifetime(second) {}
    }

    func testScopedSubscribersOnlyReceiveMatchingEvents() {
        var allReceived: [String] = []
        var firstReceived: [String] = []
        var secondReceived: [String] = []
        let all = AssistantToolEventBus.subscribe {
            allReceived.append($0.id)
        }
        let first = AssistantToolEventBus.subscribe(scopeID: "conversation-1") {
            firstReceived.append($0.id)
        }
        let second = AssistantToolEventBus.subscribe(scopeID: "conversation-2") {
            secondReceived.append($0.id)
        }

        AssistantToolEventBus.publish(
            AssistantToolEvent(
                id: "one", name: "read", state: .running,
                scopeID: "conversation-1"))
        AssistantToolEventBus.publish(
            AssistantToolEvent(
                id: "two", name: "write", state: .running,
                scopeID: "conversation-2"))
        AssistantToolEventBus.publish(
            AssistantToolEvent(id: "legacy", name: "search", state: .running))

        XCTAssertEqual(allReceived, ["one", "two", "legacy"])
        XCTAssertEqual(firstReceived, ["one"])
        XCTAssertEqual(secondReceived, ["two"])
        withExtendedLifetime((all, first, second)) {}
    }

    func testCancellingLaterSubscriberDuringPublishSuppressesItsCallback() {
        var received: [String] = []
        var later: AssistantToolEventBus.Subscription?
        let first = AssistantToolEventBus.subscribe { _ in
            received.append("first")
            later?.cancel()
        }
        later = AssistantToolEventBus.subscribe { _ in
            received.append("later")
        }

        AssistantToolEventBus.publish(
            AssistantToolEvent(id: "tool", name: "read", state: .running))

        XCTAssertEqual(received, ["first"])
        withExtendedLifetime((first, later)) {}
    }

    func testCancellingBeforeBackgroundDeliverySuppressesQueuedCallback() {
        var received = false
        let subscription = AssistantToolEventBus.subscribe { _ in
            received = true
        }
        let workFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            AssistantToolEventBus.publish(
                AssistantToolEvent(id: "queued", name: "read", state: .running))
            subscription.cancel()
            workFinished.signal()
        }

        // Keep the main queue occupied until publish has queued its delivery
        // and cancellation has completed.
        XCTAssertEqual(workFinished.wait(timeout: .now() + 1), .success)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertFalse(received)
    }

    func testLegacySinkDoesNotReplaceOrClearSubscriptions() {
        var subscriptionReceived: [String] = []
        var legacyReceived: [String] = []
        let subscription = AssistantToolEventBus.subscribe {
            subscriptionReceived.append($0.id)
        }
        AssistantToolEventBus.setSink {
            legacyReceived.append($0.id)
        }

        AssistantToolEventBus.publish(
            AssistantToolEvent(id: "before", name: "read", state: .running))
        AssistantToolEventBus.setSink(nil)
        AssistantToolEventBus.publish(
            AssistantToolEvent(id: "after", name: "read", state: .completed))

        XCTAssertEqual(subscriptionReceived, ["before", "after"])
        XCTAssertEqual(legacyReceived, ["before"])
        withExtendedLifetime(subscription) {}
    }

    func testPublishScopeOverloadRoutesAndAnnotatesAnExistingEvent() {
        var receivedScope: String?
        let subscription = AssistantToolEventBus.subscribe(scopeID: "assistant-1") {
            receivedScope = $0.scopeID
        }

        AssistantToolEventBus.publish(
            AssistantToolEvent(id: "tool", name: "read", state: .running),
            scopeID: "assistant-1")

        XCTAssertEqual(receivedScope, "assistant-1")
        withExtendedLifetime(subscription) {}
    }
}
