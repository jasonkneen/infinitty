import Foundation
import XCTest
@testable import InfinittyKit

final class AgentBridgeTests: XCTestCase {
    func testClaudeBridgeCompletesRepeatedTurnsOnOneProcess() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

for line in sys.stdin:
    event = json.loads(line)
    text = event["message"]["content"][0]["text"]
    result = {
        "type": "result",
        "subtype": "success",
        "result": "reply:" + text,
    }
    sys.stdout.write(json.dumps(result) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = ClaudeBridge(executableURL: executable)
        defer { bridge.stop() }

        let first = try await bridge.turn(
            prompt: "one", system: "test", model: "test-model", timeout: 2)
        let second = try await bridge.turn(
            prompt: "two", system: "test", model: "test-model", timeout: 2)

        XCTAssertEqual(first, "reply:one")
        XCTAssertEqual(second, "reply:two")
    }

    func testClaudeBridgeSerializesOverlappingTurns() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys
import time

for line in sys.stdin:
    event = json.loads(line)
    text = event["message"]["content"][0]["text"]
    time.sleep(0.05)
    sys.stdout.write(json.dumps({
        "type": "result", "subtype": "success", "result": "reply:" + text,
    }) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = ClaudeBridge(executableURL: executable)
        defer { bridge.stop() }

        async let first = bridge.turn(
            prompt: "one", system: "test", model: "test-model", timeout: 2)
        async let second = bridge.turn(
            prompt: "two", system: "test", model: "test-model", timeout: 2)
        let replies = try await [first, second]

        XCTAssertEqual(Set(replies), Set(["reply:one", "reply:two"]))
    }

    func testClaudeBridgeIsolatesAndReleasesKeyedConversations() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

for line in sys.stdin:
    event = json.loads(line)
    text = event["message"]["content"][0]["text"]
    session = event["session_id"]
    sys.stdout.write(json.dumps({
        "type": "result",
        "subtype": "success",
        "result": session + "|" + text,
    }) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = ClaudeBridge(executableURL: executable)
        defer { bridge.stop() }

        async let a1 = bridge.turn(
            prompt: "a1", system: "test", model: "test-model",
            timeout: 2, conversationID: "conversation-a")
        async let b1 = bridge.turn(
            prompt: "b1", system: "test", model: "test-model",
            timeout: 2, conversationID: "conversation-b")
        let (firstA, firstB) = try await (a1, b1)
        let a2 = try await bridge.turn(
            prompt: "a2", system: "test", model: "test-model",
            timeout: 2, conversationID: "conversation-a")

        let aSession = firstA.components(separatedBy: "|")[0]
        let bSession = firstB.components(separatedBy: "|")[0]
        XCTAssertEqual(a2.components(separatedBy: "|")[0], aSession)
        XCTAssertNotEqual(bSession, aSession)

        bridge.releaseConversation("conversation-a")
        do {
            _ = try await bridge.turn(
                prompt: "late-a3", system: "test", model: "test-model",
                timeout: 2, conversationID: "conversation-a")
            XCTFail("released Claude conversation accepted a late turn")
        } catch is CancellationError {
            // Explicit registration below is the only tombstone reset.
        }
        bridge.warmUp(
            system: "test", model: "test-model",
            conversationID: "conversation-a")
        let a3 = try await bridge.turn(
            prompt: "a3", system: "test", model: "test-model",
            timeout: 2, conversationID: "conversation-a")
        let releasedSession = a3.components(separatedBy: "|")[0]
        XCTAssertNotEqual(releasedSession, aSession)

        bridge.cancelConversation("conversation-a")
        let a4 = try await bridge.turn(
            prompt: "a4", system: "test", model: "test-model",
            timeout: 2, conversationID: "conversation-a")
        XCTAssertNotEqual(a4.components(separatedBy: "|")[0], releasedSession)
    }

    func testClaudeBridgeScopesKeyedToolEvents() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

for line in sys.stdin:
    sys.stdout.write(json.dumps({
        "type": "assistant",
        "message": {"content": [{
            "type": "tool_use", "id": "claude-tool",
            "name": "test_tool", "input": {},
        }]},
    }) + "\n")
    sys.stdout.write(json.dumps({
        "type": "result", "subtype": "success", "result": "ok",
    }) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let scope = "claude-scope-\(UUID().uuidString)"
        let eventReceived = expectation(description: "scoped Claude tool event")
        let subscription = AssistantToolEventBus.subscribe(scopeID: scope) { event in
            guard event.id == "claude-tool" else { return }
            XCTAssertEqual(event.scopeID, scope)
            eventReceived.fulfill()
        }
        defer { subscription.cancel() }
        let bridge = ClaudeBridge(executableURL: executable)
        defer { bridge.stop() }

        _ = try await bridge.turn(
            prompt: "hello", system: "test", model: "test-model",
            timeout: 2, conversationID: scope)
        await fulfillment(of: [eventReceived], timeout: 2)
    }

    func testCodexBridgeCompletesWhenThreadReturnsToIdle() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

thread_id = "thread-1"
turn_number = 0
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        result = {"userAgent": "fake-codex"}
    elif method == "thread/start":
        result = {"thread": {"id": thread_id}}
    elif method == "turn/start":
        turn_number += 1
        turn_id = "turn-" + str(turn_number)
        result = {"turn": {"id": turn_id}}
        sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\n")
        sys.stdout.write(json.dumps({
            "method": "item/agentMessage/delta",
            "params": {"threadId": thread_id, "turnId": turn_id,
                       "itemId": "message-1", "delta": "OK"},
        }) + "\n")
        sys.stdout.write(json.dumps({
            "method": "item/completed",
            "params": {"threadId": thread_id, "turnId": turn_id,
                       "item": {"type": "agentMessage", "id": "message-1", "text": "OK"}},
        }) + "\n")
        sys.stdout.write(json.dumps({
            "method": "thread/status/changed",
            "params": {"threadId": thread_id, "status": {"type": "idle"}},
        }) + "\n")
        sys.stdout.flush()
        continue
    else:
        result = {}
    sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = CodexAppServer(executableURL: executable)
        defer { bridge.stop() }

        let reply = try await bridge.turn(
            prompt: "hello", cwd: FileManager.default.currentDirectoryPath,
            model: "test-model", timeout: 2)

        XCTAssertEqual(reply, "OK")
    }

    func testCodexBridgeReturnsAccumulatedTextAtTimeoutWithoutCrashing() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        result = {"userAgent": "fake-codex"}
    elif method == "thread/start":
        result = {"thread": {"id": "thread-1"}}
    elif method == "turn/start":
        result = {"turn": {"id": "turn-1"}}
        sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\n")
        sys.stdout.write(json.dumps({
            "method": "item/agentMessage/delta",
            "params": {"threadId": "thread-1", "turnId": "turn-1",
                       "itemId": "message-1", "delta": "partial"},
        }) + "\n")
        sys.stdout.flush()
        continue
    else:
        result = {}
    sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = CodexAppServer(executableURL: executable)
        defer { bridge.stop() }

        let reply = try await bridge.turn(
            prompt: "hello", cwd: FileManager.default.currentDirectoryPath,
            model: "test-model", timeout: 0.1)

        XCTAssertEqual(reply, "partial")
    }

    func testCodexBridgeIsolatesReusesAndReleasesConversationThreads() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

next_thread = 0
next_turn = 0
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        result = {"userAgent": "fake-codex"}
    elif method == "thread/start":
        next_thread += 1
        result = {"thread": {"id": "thread-" + str(next_thread)}}
    elif method == "turn/start":
        next_turn += 1
        thread_id = request["params"]["threadId"]
        prompt = request["params"]["input"][0]["text"]
        turn_id = "turn-" + str(next_turn)
        text = thread_id + "|" + prompt
        result = {"turn": {"id": turn_id}}
        sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\n")
        sys.stdout.write(json.dumps({
            "method": "item/agentMessage/delta",
            "params": {"threadId": thread_id, "turnId": turn_id,
                       "itemId": "message-" + str(next_turn), "delta": text},
        }) + "\n")
        sys.stdout.write(json.dumps({
            "method": "turn/completed",
            "params": {"threadId": thread_id,
                       "turn": {"id": turn_id, "status": "completed"}},
        }) + "\n")
        sys.stdout.flush()
        continue
    else:
        result = {}
    sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = CodexAppServer(executableURL: executable)
        defer { bridge.stop() }
        let cwd = FileManager.default.currentDirectoryPath

        async let a1 = bridge.turn(
            prompt: "a1", cwd: cwd, model: "test-model", timeout: 2,
            conversationID: "conversation-a")
        async let b1 = bridge.turn(
            prompt: "b1", cwd: cwd, model: "test-model", timeout: 2,
            conversationID: "conversation-b")
        let (firstA, firstB) = try await (a1, b1)
        let secondA = try await bridge.turn(
            prompt: "a2", cwd: cwd, model: "test-model", timeout: 2,
            conversationID: "conversation-a")

        let aThread = firstA.components(separatedBy: "|")[0]
        let bThread = firstB.components(separatedBy: "|")[0]
        XCTAssertEqual(secondA.components(separatedBy: "|")[0], aThread)
        XCTAssertNotEqual(bThread, aThread)

        bridge.releaseConversation("conversation-a")
        do {
            _ = try await bridge.turn(
                prompt: "late-a3", cwd: cwd, model: "test-model", timeout: 2,
                conversationID: "conversation-a")
            XCTFail("released Codex conversation accepted a late turn")
        } catch is CancellationError {
            // Explicit registration below is the only tombstone reset.
        }
        bridge.warmUp(model: "test-model", conversationID: "conversation-a")
        let freshA = try await bridge.turn(
            prompt: "a3", cwd: cwd, model: "test-model", timeout: 2,
            conversationID: "conversation-a")
        XCTAssertNotEqual(freshA.components(separatedBy: "|")[0], aThread)
    }

    func testCodexConversationCancellationLeavesOtherThreadsUsable() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

next_thread = 0
next_turn = 0
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        result = {"userAgent": "fake-codex"}
    elif method == "thread/start":
        next_thread += 1
        result = {"thread": {"id": "thread-" + str(next_thread)}}
    elif method == "turn/start":
        next_turn += 1
        thread_id = request["params"]["threadId"]
        prompt = request["params"]["input"][0]["text"]
        turn_id = "turn-" + str(next_turn)
        result = {"turn": {"id": turn_id}}
        sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\n")
        sys.stdout.write(json.dumps({
            "method": "item/agentMessage/delta",
            "params": {"threadId": thread_id, "turnId": turn_id,
                       "itemId": "message-" + str(next_turn),
                       "delta": "started" if prompt == "hold" else "other-ok"},
        }) + "\n")
        if prompt != "hold":
            sys.stdout.write(json.dumps({
                "method": "turn/completed",
                "params": {"threadId": thread_id,
                           "turn": {"id": turn_id, "status": "completed"}},
            }) + "\n")
        sys.stdout.flush()
        continue
    else:
        result = {}
    sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = CodexAppServer(executableURL: executable)
        defer { bridge.stop() }
        let partial = expectation(description: "held turn started")
        partial.assertForOverFulfill = false
        let cwd = FileManager.default.currentDirectoryPath
        let held = Task {
            try await bridge.turn(
                prompt: "hold", cwd: cwd, model: "test-model", timeout: 5,
                conversationID: "conversation-a",
                onPartial: { _ in partial.fulfill() })
        }
        await fulfillment(of: [partial], timeout: 2)

        bridge.cancelConversation("conversation-a")
        do {
            _ = try await held.value
            XCTFail("cancelled conversation should fail its active turn")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        let other = try await bridge.turn(
            prompt: "other", cwd: cwd, model: "test-model", timeout: 2,
            conversationID: "conversation-b")
        XCTAssertEqual(other, "other-ok")
    }

    func testCodexBridgeScopesKeyedToolEvents() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        result = {"userAgent": "fake-codex"}
    elif method == "thread/start":
        result = {"thread": {"id": "thread-1"}}
    elif method == "turn/start":
        result = {"turn": {"id": "turn-1"}}
        sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\n")
        sys.stdout.write(json.dumps({
            "method": "item/started",
            "params": {"threadId": "thread-1", "turnId": "turn-1",
                       "item": {"type": "commandExecution", "id": "codex-tool"}},
        }) + "\n")
        sys.stdout.write(json.dumps({
            "method": "item/agentMessage/delta",
            "params": {"threadId": "thread-1", "turnId": "turn-1",
                       "itemId": "message-1", "delta": "ok"},
        }) + "\n")
        sys.stdout.write(json.dumps({
            "method": "turn/completed",
            "params": {"threadId": "thread-1",
                       "turn": {"id": "turn-1", "status": "completed"}},
        }) + "\n")
        sys.stdout.flush()
        continue
    else:
        result = {}
    sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let scope = "codex-scope-\(UUID().uuidString)"
        let eventReceived = expectation(description: "scoped Codex tool event")
        let subscription = AssistantToolEventBus.subscribe(scopeID: scope) { event in
            guard event.id == "codex-tool" else { return }
            XCTAssertEqual(event.scopeID, scope)
            eventReceived.fulfill()
        }
        defer { subscription.cancel() }
        let bridge = CodexAppServer(executableURL: executable)
        defer { bridge.stop() }

        _ = try await bridge.turn(
            prompt: "hello", cwd: FileManager.default.currentDirectoryPath,
            model: "test-model", timeout: 2, conversationID: scope)
        await fulfillment(of: [eventReceived], timeout: 2)
    }

    func testLiveClaudeBridgeWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INFINITTY_LIVE_AGENT_TESTS"] == "1" else {
            throw XCTSkip("Set INFINITTY_LIVE_AGENT_TESTS=1 to exercise installed agent CLIs")
        }
        let bridge = ClaudeBridge()
        defer { bridge.stop() }
        let reply = try await bridge.turn(
            prompt: "Reply with exactly LIVE_CLAUDE_OK.",
            system: "Follow the user's output-format instruction exactly.",
            model: "claude-haiku-4-5", timeout: 45)
        XCTAssertEqual(reply, "LIVE_CLAUDE_OK")
    }

    func testLiveCodexBridgeWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INFINITTY_LIVE_AGENT_TESTS"] == "1" else {
            throw XCTSkip("Set INFINITTY_LIVE_AGENT_TESTS=1 to exercise installed agent CLIs")
        }
        let bridge = CodexAppServer()
        defer { bridge.stop() }
        let reply = try await bridge.turn(
            prompt: "Reply with exactly LIVE_CODEX_OK.",
            cwd: FileManager.default.currentDirectoryPath,
            model: "gpt-5.4", effort: "low", timeout: 45)
        XCTAssertEqual(reply, "LIVE_CODEX_OK")
    }

    func testACPBridgeCompletesTurnAndStreamsPartials() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

for line in sys.stdin:
    req = json.loads(line)
    method = req.get("method")
    rid = req.get("id")
    if method == "session/new":
        out = {"jsonrpc": "2.0", "id": rid, "result": {"sessionId": "s1"}}
    elif method == "session/prompt":
        for chunk in ["Hello", " world"]:
            sys.stdout.write(json.dumps({
                "jsonrpc": "2.0", "method": "session/update",
                "params": {"sessionId": "s1", "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": chunk}}},
            }) + "\n")
        sys.stdout.flush()
        out = {"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}}
    else:
        out = {"jsonrpc": "2.0", "id": rid, "result": {}}
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = ACPBridge(provider: .hermes, executableURL: executable)
        defer { bridge.stop() }

        let partialExp = expectation(description: "partial streamed")
        partialExp.assertForOverFulfill = false
        let reply = try await bridge.turn(
            prompt: "hi", timeout: 5,
            onPartial: { _ in partialExp.fulfill() })

        XCTAssertEqual(reply, "Hello world")
        await fulfillment(of: [partialExp], timeout: 3)
    }

    /// Regression for the "responses hang" bug: an error response must
    /// fast-fail the turn instead of riding the full timeout.
    func testACPBridgeFastFailsOnRPCErrorInsteadOfTimeout() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

for line in sys.stdin:
    req = json.loads(line)
    method = req.get("method")
    rid = req.get("id")
    if method == "session/new":
        out = {"jsonrpc": "2.0", "id": rid, "result": {"sessionId": "s1"}}
    elif method == "session/prompt":
        out = {"jsonrpc": "2.0", "id": rid,
               "error": {"code": -32000, "message": "bad model: nope"}}
    else:
        out = {"jsonrpc": "2.0", "id": rid, "result": {}}
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = ACPBridge(provider: .hermes, executableURL: executable)
        defer { bridge.stop() }

        let start = Date()
        do {
            _ = try await bridge.turn(prompt: "hi", timeout: 8)
            XCTFail("turn should have thrown")
        } catch {
            XCTAssertTrue("\(error)".contains("bad model"), "got: \(error)")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 7,
            "error must surface fast, not ride the timeout")
    }

    func testACPBridgeIsolatesAndReleasesKeyedConversations() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys
import uuid

session = "session-" + str(uuid.uuid4())
for line in sys.stdin:
    req = json.loads(line)
    method = req.get("method")
    rid = req.get("id")
    if method == "session/new":
        out = {"jsonrpc": "2.0", "id": rid, "result": {"sessionId": session}}
    elif method == "session/prompt":
        prompt = req["params"]["prompt"][0]["text"]
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": session, "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": session + "|" + prompt}}},
        }) + "\n")
        sys.stdout.flush()
        out = {"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}}
    else:
        out = {"jsonrpc": "2.0", "id": rid, "result": {}}
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = ACPBridge(provider: .hermes, executableURL: executable)
        defer { bridge.stop() }

        async let a1 = bridge.turn(
            prompt: "a1", timeout: 2, conversationID: "conversation-a")
        async let b1 = bridge.turn(
            prompt: "b1", timeout: 2, conversationID: "conversation-b")
        let (firstA, firstB) = try await (a1, b1)
        let a2 = try await bridge.turn(
            prompt: "a2", timeout: 2, conversationID: "conversation-a")

        let aSession = firstA.components(separatedBy: "|")[0]
        let bSession = firstB.components(separatedBy: "|")[0]
        XCTAssertEqual(a2.components(separatedBy: "|")[0], aSession)
        XCTAssertNotEqual(bSession, aSession)

        bridge.releaseConversation("conversation-a")
        do {
            _ = try await bridge.turn(
                prompt: "late-a3", timeout: 2,
                conversationID: "conversation-a")
            XCTFail("released ACP conversation accepted a late turn")
        } catch is CancellationError {
            // Explicit registration below is the only tombstone reset.
        }
        bridge.warmUp(conversationID: "conversation-a")
        let a3 = try await bridge.turn(
            prompt: "a3", timeout: 2, conversationID: "conversation-a")
        let releasedSession = a3.components(separatedBy: "|")[0]
        XCTAssertNotEqual(releasedSession, aSession)

        bridge.cancelConversation("conversation-a")
        let a4 = try await bridge.turn(
            prompt: "a4", timeout: 2, conversationID: "conversation-a")
        XCTAssertNotEqual(a4.components(separatedBy: "|")[0], releasedSession)
    }

    func testACPBridgeScopesKeyedToolEvents() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

for line in sys.stdin:
    req = json.loads(line)
    method = req.get("method")
    rid = req.get("id")
    if method == "session/new":
        out = {"jsonrpc": "2.0", "id": rid, "result": {"sessionId": "s1"}}
    elif method == "session/prompt":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "s1", "update": {
                "sessionUpdate": "tool_call",
                "toolCallId": "acp-tool",
                "title": "test_tool",
                "status": "in_progress"}},
        }) + "\n")
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "s1", "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": "ok"}}},
        }) + "\n")
        sys.stdout.flush()
        out = {"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}}
    else:
        out = {"jsonrpc": "2.0", "id": rid, "result": {}}
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let scope = "acp-scope-\(UUID().uuidString)"
        let eventReceived = expectation(description: "scoped ACP tool event")
        let subscription = AssistantToolEventBus.subscribe(scopeID: scope) { event in
            guard event.id == "acp-tool" else { return }
            XCTAssertEqual(event.scopeID, scope)
            eventReceived.fulfill()
        }
        defer { subscription.cancel() }
        let bridge = ACPBridge(provider: .hermes, executableURL: executable)
        defer { bridge.stop() }

        _ = try await bridge.turn(
            prompt: "hello", timeout: 2, conversationID: scope)
        await fulfillment(of: [eventReceived], timeout: 2)
    }

    func testAmpBridgeReturnsProviderOutput() async throws {
        let executable = try makePythonExecutable(#"""
import os
import sys
execute_index = sys.argv.index("--execute")
message = sys.argv[execute_index + 1]
sys.stdout.write("AMP:" + os.getcwd() + ":" + message)
sys.stdout.flush()
sys.exit(0)
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let workspace = executable.deletingLastPathComponent()
        let bridge = AmpBridge(executableURL: executable)
        let reply = try await bridge.turn(
            prompt: "hello", system: "test", cwd: workspace.path, timeout: 5)
        XCTAssertTrue(
            reply.hasSuffix("/\(workspace.lastPathComponent):test\n\nhello"),
            "got: \(reply)")
    }

    func testAmpBridgeFailsFastWhenProviderExecutionFails() async throws {
        let executable = try makePythonExecutable(#"""
import sys
sys.exit(1)
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let bridge = AmpBridge(executableURL: executable)
        let start = Date()
        do {
            _ = try await bridge.turn(prompt: "hi", timeout: 5)
            XCTFail("should throw executionFailed")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("provider execution failed"),
                "got: \(error.localizedDescription)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testAmpStripANSIRemovesEscapeSequences() {
        XCTAssertEqual(
            AmpBridge.stripANSI("\u{1B}[31mred\u{1B}[0m plain"),
            "red plain")
    }

    func testAmpParsesClaudeCompatibleStreamJSON() {
        let stream = """
        {"type":"system","subtype":"init"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"hello "}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"world"}]}}
        {"type":"result","result":"hello world"}
        """
        XCTAssertEqual(AmpBridge.textFromStreamJSON(stream), "hello world")
    }

    private func makePythonExecutable(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-agent-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-agent")
        try ("#!/usr/bin/env python3\n" + body + "\n")
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
