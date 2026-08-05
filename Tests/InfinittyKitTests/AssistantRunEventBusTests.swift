import Foundation
import XCTest
@testable import InfinittyKit

@MainActor
final class AssistantRunEventBusTests: XCTestCase {
    func testScopedSubscriptionsAreIndependentAndCancellable() {
        var wildcardScopes: [String?] = []
        var firstTotals: [Int?] = []
        var secondTotals: [Int?] = []
        let wildcard = AssistantRunEventBus.subscribe {
            wildcardScopes.append($0.scopeID)
        }
        let first = AssistantRunEventBus.subscribe(scopeID: "run-1") { event in
            guard case .usage(let usage) = event.update else { return }
            firstTotals.append(usage.cumulativeTokens?.total)
        }
        let second = AssistantRunEventBus.subscribe(scopeID: "run-2") { event in
            guard case .usage(let usage) = event.update else { return }
            secondTotals.append(usage.cumulativeTokens?.total)
        }

        AssistantRunEventBus.publish(Self.usageEvent(total: 11, scopeID: "run-1"))
        first.cancel()
        AssistantRunEventBus.publish(Self.usageEvent(total: 22, scopeID: "run-1"))
        AssistantRunEventBus.publish(Self.usageEvent(total: 33, scopeID: "run-2"))
        AssistantRunEventBus.publish(Self.usageEvent(total: 44, scopeID: nil))

        XCTAssertEqual(firstTotals, [11])
        XCTAssertEqual(secondTotals, [33])
        XCTAssertEqual(wildcardScopes, ["run-1", "run-1", "run-2", nil])
        withExtendedLifetime((wildcard, first, second)) {}
    }

    func testEventPreservesEstimateProvenanceAndUnknownValues() {
        let event = AssistantRunEvent(
            provenance: .estimate,
            update: .usage(AssistantRunEvent.Usage()))

        XCTAssertEqual(event.provenance, .estimate)
        guard case .usage(let usage) = event.update else {
            return XCTFail("expected usage update")
        }
        XCTAssertNil(usage.lastTokens)
        XCTAssertNil(usage.cumulativeTokens)
        XCTAssertNil(usage.contextUsedTokens)
        XCTAssertNil(usage.contextWindowTokens)
        XCTAssertNil(usage.cost)
    }

    func testBackgroundEventQueuedBeforeCancellationIsNotDelivered() {
        let delivered = expectation(description: "cancelled event delivered")
        delivered.isInverted = true
        let subscription = AssistantRunEventBus.subscribe(scopeID: "run") { _ in
            delivered.fulfill()
        }
        let published = DispatchSemaphore(value: 0)
        let event = Self.usageEvent(total: 1, scopeID: "run")

        DispatchQueue.global(qos: .userInitiated).async {
            AssistantRunEventBus.publish(event)
            published.signal()
        }

        XCTAssertEqual(published.wait(timeout: .now() + 1), .success)
        subscription.cancel()
        wait(for: [delivered], timeout: 0.1)
    }

    func testEarlierSubscriberCanCancelLaterSubscriberDuringDelivery() {
        var firstCount = 0
        var secondCount = 0
        var second: AssistantRunEventBus.Subscription?
        let first = AssistantRunEventBus.subscribe(scopeID: "run") { _ in
            firstCount += 1
            second?.cancel()
        }
        second = AssistantRunEventBus.subscribe(scopeID: "run") { _ in
            secondCount += 1
        }

        AssistantRunEventBus.publish(Self.usageEvent(total: 1, scopeID: "run"))

        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 0)
        withExtendedLifetime((first, second)) {}
    }

    private static func usageEvent(
        total: Int,
        scopeID: String?
    ) -> AssistantRunEvent {
        AssistantRunEvent(
            provenance: .providerReported,
            update: .usage(
                AssistantRunEvent.Usage(
                    cumulativeTokens: AssistantRunEvent.TokenCounts(total: total))),
            scopeID: scopeID)
    }
}
