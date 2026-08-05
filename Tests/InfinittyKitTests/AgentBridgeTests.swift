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

    func testClaudeBridgeLaunchesInWorkspaceWithModeSpecificToolPolicy() async throws {
        let executable = try makePythonExecutable(#"""
import json
import os
import sys

for line in sys.stdin:
    event = json.loads(line)
    result = {
        "type": "result",
        "subtype": "success",
        "result": json.dumps({
            "cwd": os.getcwd(),
            "profile": os.environ.get("INFINITTY_MCP_PROFILE"),
            "scope": os.environ.get("INFINITTY_ASSISTANT_SCOPE"),
            "args": sys.argv[1:],
            "session": event["session_id"],
        }),
    }
    sys.stdout.write(json.dumps(result) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let bridge = ClaudeBridge(
            executableURL: executable, mcpExecutableURL: executable)
        defer { bridge.stop() }
        let chatText = try await bridge.turn(
            prompt: "chat", system: "test", model: "test-model", timeout: 2,
            conversationID: "profile-conversation", cwd: workspace.path,
            profile: .workspaceChat)
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(chatText.utf8)) as? [String: Any])
        let chatArgs = try XCTUnwrap(chat["args"] as? [String])
        XCTAssertEqual(
            (chat["cwd"] as? String).map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            },
            workspace.resolvingSymlinksInPath().path)
        XCTAssertEqual(chat["profile"] as? String, "workspace-chat")
        XCTAssertEqual(chat["scope"] as? String, "profile-conversation")
        XCTAssertTrue(chatArgs.contains(
            #"{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true,"allowUnsandboxedCommands":false}}"#))
        XCTAssertTrue(chatArgs.contains {
            $0.contains("Read Write Edit Glob Grep Bash BashOutput KillShell")
                && $0.contains(MCPConfiguration.claudePermissionPromptToolName)
        })
        XCTAssertTrue(chatArgs.contains("WebFetch WebSearch Task TodoWrite"))
        XCTAssertFalse(chatArgs.contains(
            "Bash BashOutput KillShell WebFetch WebSearch Task TodoWrite"))
        XCTAssertEqual(
            value(after: "--permission-prompt-tool", in: chatArgs),
            MCPConfiguration.claudePermissionPromptToolName)
        let mcpJSON = try XCTUnwrap(value(after: "--mcp-config", in: chatArgs))
        let mcpRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(mcpJSON.utf8))
                as? [String: Any])
        let mcpServer = try XCTUnwrap(
            (mcpRoot["mcpServers"] as? [String: Any])?["infinitty"]
                as? [String: Any])
        let mcpEnvironment = try XCTUnwrap(mcpServer["env"] as? [String: String])
        XCTAssertEqual(
            mcpEnvironment["INFINITTY_ASSISTANT_SCOPE"],
            "profile-conversation")

        let terminalText = try await bridge.turn(
            prompt: "terminal", system: "test", model: "test-model", timeout: 2,
            conversationID: "profile-conversation", cwd: workspace.path,
            profile: .visibleTerminal)
        let terminal = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(terminalText.utf8)) as? [String: Any])
        let terminalArgs = try XCTUnwrap(terminal["args"] as? [String])
        XCTAssertEqual(terminal["profile"] as? String, "visible-terminal")
        XCTAssertTrue(terminalArgs.contains {
            $0.contains("Read Write Edit Glob Grep")
                && $0.contains(MCPConfiguration.claudePermissionPromptToolName)
        })
        XCTAssertTrue(terminalArgs.contains {
            $0.contains("Bash BashOutput KillShell")
        })
        XCTAssertNotEqual(chat["session"] as? String, terminal["session"] as? String)
    }

    func testClaudeBridgePassesNativeEffortAndRespawnsOnlyWhenItChanges() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

for line in sys.stdin:
    event = json.loads(line)
    sys.stdout.write(json.dumps({
        "type": "result",
        "subtype": "success",
        "result": json.dumps({
            "args": sys.argv[1:],
            "session": event["session_id"],
        }),
    }) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = ClaudeBridge(executableURL: executable)
        defer { bridge.stop() }

        func result(_ effort: String) async throws -> [String: Any] {
            let text = try await bridge.turn(
                prompt: effort, system: "test", model: "test-model",
                effort: effort, timeout: 2)
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any])
        }

        let firstLow = try await result("Low")
        let secondLow = try await result("low")
        let max = try await result("Max")
        let auto = try await result("Auto")
        let none = try await result("None")

        func args(_ result: [String: Any]) throws -> [String] {
            try XCTUnwrap(result["args"] as? [String])
        }
        XCTAssertEqual(try value(after: "--effort", in: args(firstLow)), "low")
        XCTAssertEqual(firstLow["session"] as? String, secondLow["session"] as? String)
        XCTAssertEqual(try value(after: "--effort", in: args(max)), "max")
        XCTAssertNotEqual(max["session"] as? String, secondLow["session"] as? String)
        XCTAssertFalse(try args(auto).contains("--effort"))
        XCTAssertNotEqual(auto["session"] as? String, max["session"] as? String)
        XCTAssertFalse(try args(none).contains("--effort"))
        XCTAssertEqual(none["session"] as? String, auto["session"] as? String,
                       "Auto and None share the same provider-default process identity")
    }

    func testClaudeWarmUpCannotReconfigureBetweenTurnSetupAndRegistration() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

for line in sys.stdin:
    event = json.loads(line)
    sys.stdout.write(json.dumps({
        "type": "result",
        "subtype": "success",
        "result": json.dumps({
            "args": sys.argv[1:],
            "session": event["session_id"],
        }),
    }) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let processEnsured = expectation(description: "turn process ensured")
        let allowRegistration = DispatchSemaphore(value: 0)
        let bridge = ClaudeBridge(
            executableURL: executable,
            turnProcessEnsuredForTesting: {
                processEnsured.fulfill()
                _ = allowRegistration.wait(timeout: .now() + 3)
            })
        defer { bridge.stop() }

        let turn = Task {
            try await bridge.turn(
                prompt: "real turn", system: "test", model: "test-model",
                effort: "High", timeout: 2)
        }
        await fulfillment(of: [processEnsured], timeout: 2)

        bridge.warmUp(
            system: "test", model: "test-model", effort: "Auto")
        allowRegistration.signal()

        let result = try await turn.value
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.utf8))
                as? [String: Any])
        let arguments = try XCTUnwrap(decoded["args"] as? [String])
        XCTAssertEqual(value(after: "--effort", in: arguments), "high")
    }

    func testCodexUsesDistinctProcessPoolsForWorkspaceAndTerminalProfiles() {
        XCTAssertFalse(CodexAppServer.shared === CodexAppServer.visibleTerminalShared)
        XCTAssertEqual(CodexAppServer.shared.profile, .workspaceChat)
        XCTAssertEqual(
            CodexAppServer.visibleTerminalShared.profile,
            .visibleTerminal)
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

    func testCodexBridgeTreatsSilenceAfterPartialTextAsIncompleteTimeout() async throws {
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

        do {
            _ = try await bridge.turn(
                prompt: "hello", cwd: FileManager.default.currentDirectoryPath,
                model: "test-model", timeout: 0.1)
            XCTFail("an unterminated partial answer must not be reported as success")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Codex was inactive for the configured turn timeout.")
        }
    }

    func testCodexTimeoutRetiresThreadAndRejectsLateTurnOutput() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys
import threading
import time

write_lock = threading.Lock()
thread_number = 0
turn_number = 0

def send(value):
    with write_lock:
        sys.stdout.write(json.dumps(value) + "\n")
        sys.stdout.flush()

def late_first_turn(thread_id, turn_id):
    time.sleep(1.8)
    send({
        "method": "item/agentMessage/delta",
        "params": {"threadId": thread_id, "turnId": turn_id,
                   "itemId": "old-message", "delta": "|late-old"},
    })
    send({
        "method": "turn/completed",
        "params": {"threadId": thread_id,
                   "turn": {"id": turn_id, "status": "completed"}},
    })

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        result = {"userAgent": "fake-codex"}
    elif method == "thread/start":
        thread_number += 1
        result = {"thread": {"id": "thread-" + str(thread_number)}}
    elif method == "turn/start":
        turn_number += 1
        turn_id = "turn-" + str(turn_number)
        thread_id = request["params"]["threadId"]
        send({"id": request["id"], "result": {"turn": {"id": turn_id}}})
        if turn_number == 1:
            send({
                "method": "item/agentMessage/delta",
                "params": {"threadId": thread_id, "turnId": turn_id,
                           "itemId": "old-message", "delta": "partial-old"},
            })
            threading.Thread(
                target=late_first_turn,
                args=(thread_id, turn_id),
                daemon=True).start()
        else:
            time.sleep(2.0)
            send({
                "method": "item/agentMessage/delta",
                "params": {"threadId": thread_id, "turnId": turn_id,
                           "itemId": "fresh-message",
                           "delta": "fresh|" + thread_id},
            })
            send({
                "method": "turn/completed",
                "params": {"threadId": thread_id,
                           "turn": {"id": turn_id, "status": "completed"}},
            })
        continue
    else:
        result = {}
    send({"id": request["id"], "result": result})
"""#)
        defer {
            try? FileManager.default.removeItem(
                at: executable.deletingLastPathComponent())
        }

        let bridge = CodexAppServer(executableURL: executable)
        defer { bridge.stop() }

        do {
            _ = try await bridge.turn(
                prompt: "first", cwd: FileManager.default.currentDirectoryPath,
                model: "test-model", timeout: 1)
            XCTFail("the incomplete first Codex turn must time out")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Codex was inactive for the configured turn timeout.")
        }

        let reply = try await bridge.turn(
            prompt: "second", cwd: FileManager.default.currentDirectoryPath,
            model: "test-model", timeout: 3)

        XCTAssertEqual(reply, "fresh|thread-2")
        XCTAssertFalse(reply.contains("partial-old"))
        XCTAssertFalse(reply.contains("late-old"))
    }

    func testCodexProviderActivityExtendsTurnPastWallClockTimeout() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys
import time

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        result = {"userAgent": "fake-codex"}
    elif method == "thread/start":
        result = {"thread": {"id": "thread-active"}}
    elif method == "turn/start":
        turn_id = "turn-active"
        result = {"turn": {"id": turn_id}}
        sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\n")
        sys.stdout.flush()
        time.sleep(0.4)
        sys.stdout.write(json.dumps({
            "method": "item/agentMessage/delta",
            "params": {"threadId": "thread-active", "turnId": turn_id,
                       "itemId": "message-1", "delta": "A"},
        }) + "\n")
        sys.stdout.flush()
        time.sleep(0.4)
        sys.stdout.write(json.dumps({
            "method": "item/reasoning/textDelta",
            "params": {"threadId": "thread-active", "turnId": turn_id,
                       "itemId": "reasoning-1", "delta": "PRIVATE"},
        }) + "\n")
        sys.stdout.flush()
        time.sleep(0.4)
        sys.stdout.write(json.dumps({
            "method": "item/agentMessage/delta",
            "params": {"threadId": "thread-active", "turnId": turn_id,
                       "itemId": "message-1", "delta": "B"},
        }) + "\n")
        sys.stdout.write(json.dumps({
            "method": "turn/completed",
            "params": {"threadId": "thread-active",
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

        let reply = try await bridge.turn(
            prompt: "hello", cwd: FileManager.default.currentDirectoryPath,
            model: "test-model", timeout: 1.0)

        XCTAssertEqual(reply, "AB")
        XCTAssertFalse(reply.contains("PRIVATE"))
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

    func testACPBridgeNeverExposesThoughtChunksAsAnswer() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

for line in sys.stdin:
    req = json.loads(line)
    method = req.get("method")
    rid = req.get("id")
    if method == "session/new":
        result = {"sessionId": "s1"}
    elif method == "session/prompt":
        for kind, text in [
            ("agent_thought_chunk", "PRIVATE-REASONING-MUST-NOT-LEAK"),
            ("agent_message_chunk", "Visible answer"),
        ]:
            sys.stdout.write(json.dumps({
                "jsonrpc": "2.0", "method": "session/update",
                "params": {"sessionId": "s1", "update": {
                    "sessionUpdate": kind,
                    "content": {"type": "text", "text": text}}},
            }) + "\n")
        sys.stdout.flush()
        result = {"stopReason": "end_turn"}
    else:
        result = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = ACPBridge(provider: .hermes, executableURL: executable)
        defer { bridge.stop() }

        let partialExp = expectation(description: "visible partial streamed")
        var partials: [String] = []
        let reply = try await bridge.turn(
            prompt: "hi", timeout: 2,
            onPartial: {
                partials.append($0)
                partialExp.fulfill()
            })

        XCTAssertEqual(reply, "Visible answer")
        await fulfillment(of: [partialExp], timeout: 2)
        XCTAssertFalse(partials.joined().contains("PRIVATE-REASONING-MUST-NOT-LEAK"))
    }

    func testACPProviderActivityExtendsTurnPastWallClockTimeout() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys
import time

for line in sys.stdin:
    req = json.loads(line)
    method = req.get("method")
    rid = req.get("id")
    if method == "session/new":
        result = {"sessionId": "s-active"}
    elif method == "session/prompt":
        time.sleep(0.4)
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "s-active", "update": {
                "sessionUpdate": "tool_call", "toolCallId": "tool-1",
                "title": "scan", "status": "in_progress"}},
        }) + "\n")
        sys.stdout.flush()
        time.sleep(0.4)
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "s-active", "update": {
                "sessionUpdate": "agent_thought_chunk",
                "content": {"type": "text", "text": "PRIVATE"}}},
        }) + "\n")
        sys.stdout.flush()
        time.sleep(0.4)
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "s-active", "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": "Visible"}}},
        }) + "\n")
        sys.stdout.flush()
        result = {"stopReason": "end_turn"}
    else:
        result = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = ACPBridge(provider: .hermes, executableURL: executable)
        defer { bridge.stop() }

        let reply = try await bridge.turn(prompt: "hi", timeout: 1.0)

        XCTAssertEqual(reply, "Visible")
        XCTAssertFalse(reply.contains("PRIVATE"))
    }

    func testACPSilenceAfterPartialTextFailsAndRetiresProcess() async throws {
        let executable = try makePythonExecutable(#"""
import json
import os
import signal
import sys
import time

signal.signal(signal.SIGTERM, lambda _signum, _frame: None)
session_id = "session-" + str(os.getpid())

for line in sys.stdin:
    req = json.loads(line)
    method = req.get("method")
    rid = req.get("id")
    if method == "session/new":
        result = {"sessionId": session_id}
    elif method == "session/prompt":
        prompt = req["params"]["prompt"][0]["text"]
        if "hi" in prompt:
            text = "incomplete:" + str(os.getpid())
            delay = 1.8
            suffix = "late-old"
        else:
            text = ""
            delay = 2.0
            suffix = "fresh:" + str(os.getpid())
        if text:
            sys.stdout.write(json.dumps({
                "jsonrpc": "2.0", "method": "session/update",
                "params": {"sessionId": session_id, "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": text}}},
            }) + "\n")
            sys.stdout.flush()
        time.sleep(delay)
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": session_id, "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": suffix}}},
        }) + "\n")
        sys.stdout.flush()
        result = {"stopReason": "end_turn"}
    else:
        result = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = ACPBridge(provider: .hermes, executableURL: executable)
        defer { bridge.stop() }
        let firstPartial = AgentBridgeStringValue()
        let partialReceived = expectation(description: "first ACP process identified")

        do {
            _ = try await bridge.turn(
                prompt: "hi", timeout: 1,
                onPartial: { text in
                    firstPartial.set(text)
                    partialReceived.fulfill()
                })
            XCTFail("an unterminated partial answer must not be reported as success")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Hermes was inactive for the configured turn timeout.")
        }
        await fulfillment(of: [partialReceived], timeout: 2)

        let reply = try await bridge.turn(prompt: "retry", timeout: 3)
        XCTAssertTrue(reply.hasPrefix("fresh:"), reply)
        XCTAssertFalse(reply.contains("incomplete"))
        XCTAssertFalse(reply.contains("late-old"))
        XCTAssertNotEqual(
            firstPartial.value.split(separator: ":").last.map(String.init),
            reply.split(separator: ":").last.map(String.init),
            "the retry must use a replacement ACP process")
    }

    func testOpenCodeACPUsesAdvertisedEffortConfigOption() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

efforts = []
for line in sys.stdin:
    req = json.loads(line)
    method = req.get("method")
    rid = req.get("id")
    if method == "session/new":
        result = {
            "sessionId": "s1",
            "configOptions": [{
                "id": "effort",
                "currentValue": "low",
                "options": [
                    {"value": "low", "name": "Low"},
                    {"value": "high", "name": "High"},
                ],
            }],
        }
    elif method == "session/set_config_option":
        if req["params"].get("configId") == "effort":
            efforts.append(req["params"].get("value"))
        result = {}
    elif method == "session/prompt":
        text = json.dumps(efforts)
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "s1", "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": text}}},
        }) + "\n")
        sys.stdout.flush()
        result = {"stopReason": "end_turn"}
    else:
        result = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = ACPBridge(provider: .opencode, executableURL: executable)
        defer { bridge.stop() }

        let high = try await bridge.turn(prompt: "hi", effort: "High", timeout: 2)
        let auto = try await bridge.turn(prompt: "again", effort: "Auto", timeout: 2)

        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(high.utf8)), ["high"])
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(auto.utf8)),
            ["high", "low"],
            "Auto restores OpenCode's advertised provider default")
    }

    func testHermesACPNeverReceivesOpenCodeEffortConfigRPC() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys

methods = []
for line in sys.stdin:
    req = json.loads(line)
    method = req.get("method")
    methods.append(method)
    rid = req.get("id")
    if method == "session/new":
        result = {
            "sessionId": "s1",
            "configOptions": [{
                "id": "effort", "currentValue": "low",
                "options": [{"value": "low"}, {"value": "max"}],
            }],
        }
    elif method == "session/prompt":
        text = json.dumps(methods)
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "s1", "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": text}}},
        }) + "\n")
        sys.stdout.flush()
        result = {"stopReason": "end_turn"}
    else:
        result = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}) + "\n")
    sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let bridge = ACPBridge(provider: .hermes, executableURL: executable)
        defer { bridge.stop() }

        let text = try await bridge.turn(prompt: "hi", effort: "Max", timeout: 2)
        let methods = try JSONDecoder().decode([String].self, from: Data(text.utf8))
        XCTAssertFalse(methods.contains("session/set_config_option"))
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

    func testAmpProviderActivityExtendsTurnPastWallClockTimeout() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys
import time

time.sleep(0.4)
sys.stdout.write(json.dumps({
    "type": "assistant",
    "message": {"content": [{"type": "text", "text": "A"}]},
}) + "\n")
sys.stdout.flush()
time.sleep(0.4)
sys.stdout.write(json.dumps({"type": "system", "subtype": "progress"}) + "\n")
sys.stdout.flush()
time.sleep(0.4)
sys.stdout.write(json.dumps({
    "type": "assistant",
    "message": {"content": [{"type": "text", "text": "B"}]},
}) + "\n")
sys.stdout.write(json.dumps({"type": "result", "result": "AB"}) + "\n")
sys.stdout.flush()
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let bridge = AmpBridge(executableURL: executable)
        let partial = expectation(description: "Amp streamed a visible partial")
        partial.assertForOverFulfill = false

        let reply = try await bridge.turn(
            prompt: "hello", timeout: 1.0,
            onPartial: { _ in partial.fulfill() })

        XCTAssertEqual(reply, "AB")
        await fulfillment(of: [partial], timeout: 2)
    }

    func testAmpSilenceAfterPartialTextFailsAsIncompleteTimeout() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys
import time

sys.stdout.write(json.dumps({
    "type": "assistant",
    "message": {"content": [{"type": "text", "text": "incomplete"}]},
}) + "\n")
sys.stdout.flush()
time.sleep(30)
"""#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let bridge = AmpBridge(executableURL: executable)

        do {
            _ = try await bridge.turn(prompt: "hello", timeout: 0.4)
            XCTFail("an unterminated partial answer must not be reported as success")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Amp was inactive for the configured turn timeout.")
        }
    }

    func testAmpBridgeCancelsOnlyTheTargetedConversation() async throws {
        let executable = try makePythonExecutable(#"""
import os
import sys
import time

started = os.path.join(os.path.dirname(sys.argv[0]), "started")
with open(started, "w", encoding="utf-8") as marker:
    marker.write("ready")
time.sleep(30)
sys.stdout.write("should not complete")
sys.stdout.flush()
"""#)
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let bridge = AmpBridge(executableURL: executable)
        let turn = Task {
            try await bridge.turn(
                prompt: "wait",
                conversationID: "amp-conversation-to-cancel",
                timeout: 10)
        }

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        let cancelledAt = Date()
        bridge.cancelConversation("amp-conversation-to-cancel")
        do {
            _ = try await turn.value
            XCTFail("A cancelled Amp turn must not complete successfully.")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("provider execution failed"),
                "got: \(error.localizedDescription)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2)
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

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }
}

private final class AgentBridgeStringValue: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: String) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
