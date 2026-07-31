import XCTest

@testable import InfinittyKit

final class RunCommandQueueTests: XCTestCase {
    func testTimedOutHeadStaysCorrelatedUntilItsMarkerArrives() {
        let queue = RunCommandQueue()
        let firstID = UUID()
        let secondID = UUID()
        var completions: [(String, Int, String)] = []

        XCTAssertTrue(queue.enqueue(.init(
            id: firstID,
            command: "slow",
            completion: { completions.append(("slow", $0, $1)) })))
        XCTAssertFalse(queue.enqueue(.init(
            id: secondID,
            command: "fast",
            completion: { completions.append(("fast", $0, $1)) })))

        XCTAssertFalse(queue.cancelTimedOut(id: firstID))
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(
            queue.completeHead(exitCode: 7, output: "slow output"),
            "fast")
        XCTAssertEqual(completions.map(\.0), ["slow"])
        XCTAssertEqual(completions[0].1, 7)
        XCTAssertEqual(completions[0].2, "slow output")

        XCTAssertNil(queue.completeHead(exitCode: 0, output: "fast output"))
        XCTAssertEqual(completions.map(\.0), ["slow", "fast"])
        XCTAssertEqual(completions[1].2, "fast output")
        XCTAssertTrue(queue.isEmpty)
    }

    func testTimedOutUnsentItemCanBeRemoved() {
        let queue = RunCommandQueue()
        let firstID = UUID()
        let secondID = UUID()

        XCTAssertTrue(queue.enqueue(.init(
            id: firstID, command: "active", completion: { _, _ in })))
        XCTAssertFalse(queue.enqueue(.init(
            id: secondID, command: "queued", completion: { _, _ in })))

        XCTAssertTrue(queue.cancelTimedOut(id: secondID))
        XCTAssertEqual(queue.count, 1)
        XCTAssertNil(queue.completeHead(exitCode: 0, output: "done"))
    }

    func testCompletionCapturesOutputBeforeNextCommandRuns() {
        let queue = RunCommandQueue()
        var firstOutput = ""
        _ = queue.enqueue(.init(
            id: UUID(), command: "first",
            completion: { _, output in firstOutput = output }))
        _ = queue.enqueue(.init(
            id: UUID(), command: "second",
            completion: { _, _ in }))

        XCTAssertEqual(
            queue.completeHead(exitCode: 0, output: "owned by first"),
            "second")
        XCTAssertEqual(firstOutput, "owned by first")
    }
}
