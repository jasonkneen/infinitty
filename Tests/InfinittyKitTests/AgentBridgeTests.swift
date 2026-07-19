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
