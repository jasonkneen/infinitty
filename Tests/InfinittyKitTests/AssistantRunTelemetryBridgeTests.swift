import Foundation
import XCTest
@testable import InfinittyKit

@MainActor
final class AssistantRunTelemetryBridgeTests: XCTestCase {
    func testCodexPublishesExactUsageAndOnlySafeReasoningSummaries() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        result = {"userAgent": "fake-codex"}
    elif method == "thread/start":
        result = {"thread": {"id": "thread-telemetry"}}
    elif method == "turn/start":
        turn_id = "turn-telemetry"
        result = {"turn": {"id": turn_id}}
        sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\n")
        notifications = [
            {
                "method": "thread/tokenUsage/updated",
                "params": {
                    "threadId": "thread-telemetry",
                    "turnId": turn_id,
                    "tokenUsage": {
                        "last": {
                            "inputTokens": 101,
                            "cachedInputTokens": 17,
                            "cacheWriteInputTokens": 3,
                            "outputTokens": 29,
                            "reasoningOutputTokens": 7,
                            "totalTokens": 157,
                        },
                        "total": {
                            "inputTokens": 401,
                            "cachedInputTokens": 61,
                            "cacheWriteInputTokens": 9,
                            "outputTokens": 89,
                            "reasoningOutputTokens": 23,
                            "totalTokens": 583,
                        },
                        "modelContextWindow": 200000,
                    },
                },
            },
            {
                "method": "item/reasoning/summaryTextDelta",
                "params": {
                    "threadId": "thread-telemetry",
                    "turnId": turn_id,
                    "itemId": "reasoning-1",
                    "summaryIndex": 2,
                    "delta": "Safe summary delta",
                },
            },
            {
                "method": "item/reasoning/textDelta",
                "params": {
                    "threadId": "thread-telemetry",
                    "turnId": turn_id,
                    "itemId": "reasoning-1",
                    "contentIndex": 0,
                    "delta": "PRIVATE RAW REASONING",
                },
            },
            {
                "method": "item/completed",
                "params": {
                    "threadId": "thread-telemetry",
                    "turnId": turn_id,
                    "item": {
                        "type": "reasoning",
                        "id": "reasoning-1",
                        "summary": ["Safe completed summary", "Second safe part"],
                        "content": ["PRIVATE COMPLETED REASONING"],
                    },
                },
            },
            {
                "method": "item/agentMessage/delta",
                "params": {
                    "threadId": "thread-telemetry",
                    "turnId": turn_id,
                    "itemId": "answer-1",
                    "delta": "ok",
                },
            },
            {
                "method": "turn/completed",
                "params": {
                    "threadId": "thread-telemetry",
                    "turn": {"id": turn_id, "status": "completed"},
                },
            },
        ]
        for notification in notifications:
            sys.stdout.write(json.dumps(notification) + "\n")
        sys.stdout.flush()
        continue
    else:
        result = {}
    sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let scope = "codex-telemetry-\(UUID().uuidString)"
        var events: [AssistantRunEvent] = []
        let received = expectation(description: "Codex telemetry")
        received.expectedFulfillmentCount = 3
        let subscription = AssistantRunEventBus.subscribe(scopeID: scope) { event in
            events.append(event)
            received.fulfill()
        }
        defer { subscription.cancel() }
        let bridge = CodexAppServer(executableURL: executable)
        defer { bridge.stop() }

        let reply = try await bridge.turn(
            prompt: "hello",
            cwd: FileManager.default.currentDirectoryPath,
            model: "test-model",
            timeout: 2,
            conversationID: scope)
        XCTAssertEqual(reply, "ok")
        await fulfillment(of: [received], timeout: 2)

        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.allSatisfy {
            $0.scopeID == scope && $0.provenance == .providerReported
        })

        let usage = try XCTUnwrap(events.compactMap { event -> AssistantRunEvent.Usage? in
            guard case .usage(let usage) = event.update else { return nil }
            return usage
        }.first)
        XCTAssertEqual(
            usage.lastTokens,
            AssistantRunEvent.TokenCounts(
                input: 101,
                cachedInput: 17,
                cacheWriteInput: 3,
                output: 29,
                reasoningOutput: 7,
                total: 157))
        XCTAssertEqual(
            usage.cumulativeTokens,
            AssistantRunEvent.TokenCounts(
                input: 401,
                cachedInput: 61,
                cacheWriteInput: 9,
                output: 89,
                reasoningOutput: 23,
                total: 583))
        XCTAssertNil(usage.contextUsedTokens)
        XCTAssertEqual(usage.contextWindowTokens, 200_000)
        XCTAssertNil(usage.cost)

        let summaries = events.compactMap { event -> AssistantRunEvent.ReasoningSummary? in
            guard case .reasoningSummary(let summary) = event.update else { return nil }
            return summary
        }
        XCTAssertEqual(
            summaries,
            [
                AssistantRunEvent.ReasoningSummary(
                    state: .delta,
                    text: "Safe summary delta",
                    itemID: "reasoning-1",
                    summaryIndex: 2),
                AssistantRunEvent.ReasoningSummary(
                    state: .completed,
                    text: "Safe completed summary\n\nSecond safe part",
                    itemID: "reasoning-1"),
            ])
        XCTAssertFalse(String(describing: events).contains("PRIVATE"))
    }

    func testACPPublishesExactContextCostAndNeverLeaksThoughtChunks() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    request_id = request.get("id")
    if method == "session/new":
        result = {"sessionId": "session-telemetry"}
    elif method == "session/prompt":
        updates = [
            {
                "sessionUpdate": "usage_update",
                "used": 321,
                "size": 8192,
                "cost": {"amount": 0.0125, "currency": "EUR"},
            },
            {
                "sessionUpdate": "agent_thought_chunk",
                "content": {"type": "text", "text": "PRIVATE ACP THOUGHT"},
            },
            {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": "Visible answer"},
            },
        ]
        for update in updates:
            sys.stdout.write(json.dumps({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {"sessionId": "session-telemetry", "update": update},
            }) + "\n")
        sys.stdout.flush()
        result = {"stopReason": "end_turn"}
    else:
        result = {}
    sys.stdout.write(json.dumps({
        "jsonrpc": "2.0", "id": request_id, "result": result,
    }) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let scope = "acp-telemetry-\(UUID().uuidString)"
        var events: [AssistantRunEvent] = []
        let received = expectation(description: "ACP usage telemetry")
        let subscription = AssistantRunEventBus.subscribe(scopeID: scope) { event in
            events.append(event)
            received.fulfill()
        }
        defer { subscription.cancel() }
        let bridge = ACPBridge(provider: .hermes, executableURL: executable)
        defer { bridge.stop() }

        let reply = try await bridge.turn(
            prompt: "hello",
            timeout: 2,
            conversationID: scope)
        XCTAssertEqual(reply, "Visible answer")
        XCTAssertFalse(reply.contains("PRIVATE ACP THOUGHT"))
        await fulfillment(of: [received], timeout: 2)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].scopeID, scope)
        XCTAssertEqual(events[0].provenance, .providerReported)
        guard case .usage(let usage) = events[0].update else {
            return XCTFail("expected ACP usage update")
        }
        XCTAssertNil(usage.lastTokens)
        XCTAssertNil(usage.cumulativeTokens)
        XCTAssertEqual(usage.contextUsedTokens, 321)
        XCTAssertEqual(usage.contextWindowTokens, 8_192)
        XCTAssertEqual(usage.cost?.amount, Decimal(string: "0.0125"))
        XCTAssertEqual(usage.cost?.currency, "EUR")
        XCTAssertFalse(String(describing: events).contains("PRIVATE ACP THOUGHT"))
    }

    private func makePythonExecutable(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "infinitty-run-telemetry-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-agent")
        try ("#!/usr/bin/env python3\n" + body + "\n")
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
        return executable
    }
}
