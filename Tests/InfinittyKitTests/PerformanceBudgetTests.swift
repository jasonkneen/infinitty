import XCTest

@testable import InfinittyKit

/// Gross-regression gates that are stable enough for shared CI. Detailed
/// machine baselines can sit above these, but a parser or snapshot algorithm
/// accidentally becoming quadratic should fail everywhere.
final class PerformanceBudgetTests: XCTestCase {
    private func requireIsolatedPerformanceRun() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[
                "INFINITTY_PERFORMANCE_GATES"] == "1",
            "wall-clock performance gates run separately from the contended suite")
    }

    func testOneMiBASCIIParserBudget() throws {
        try requireIsolatedPerformanceRun()
        let terminal = Terminal(cols: 120, rows: 40)
        let bytes = [UInt8](repeating: UInt8(ascii: "x"), count: 1_048_576)
        let started = ProcessInfo.processInfo.systemUptime
        bytes.withUnsafeBufferPointer {
            terminal.feed($0.baseAddress!, $0.count)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertLessThan(
            elapsed, 2,
            "1 MiB printable ASCII should parse in under the gross CI budget")
    }

    func testThousandFullGridSnapshotsBudget() throws {
        try requireIsolatedPerformanceRun()
        let terminal = Terminal(cols: 160, rows: 60)
        let line = String(repeating: "0123456789abcdef", count: 10) + "\n"
        let bytes = Array(String(repeating: line, count: 60).utf8)
        bytes.withUnsafeBufferPointer {
            terminal.feed($0.baseAddress!, $0.count)
        }
        var snapshot = TermSnapshot()
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1_000 {
            terminal.copySnapshot(into: &snapshot)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertLessThan(
            elapsed, 5,
            "snapshot copying should remain linear and allocation-reusing")
        XCTAssertEqual(snapshot.cells.count, 160 * 60)
    }

    func testThousandCollaborationCommitsBudget() throws {
        try requireIsolatedPerformanceRun()
        var event = 0
        let room = try CollaborationRoom(
            store: MemoryCollaborationEventStore(),
            now: { Date(timeIntervalSince1970: Double(event)) },
            idFactory: { "channel-performance" },
            eventIDFactory: {
                event += 1
                return "event-\(event)"
            })
        let actor = CollaborationActor(
            id: "agent:bench", kind: .agent, displayName: "Bench")
        _ = try room.apply(
            .createChannel(
                id: "channel-performance",
                name: "Performance",
                colorHex: nil),
            by: actor)

        let started = ProcessInfo.processInfo.systemUptime
        for index in 0..<1_000 {
            _ = try room.apply(
                .postMessage(
                    channelID: "channel-performance",
                    message: CollaborationMessage(
                        id: "message-\(index)",
                        threadID: nil,
                        authorID: actor.id,
                        text: "bounded message \(index)")),
                by: actor,
                idempotencyKey: "bench-\(index)")
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertLessThan(elapsed, 3)
        XCTAssertEqual(room.snapshot().revision, 1_001)
    }
}
