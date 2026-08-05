import Foundation
import XCTest
@testable import InfinittyKit

final class ClaudeBridgeTimeoutTests: XCTestCase {
    func testProviderActivityExtendsClaudeTurnPastWallClockTimeout() async throws {
        let executable = try makePythonExecutable(#"""
import json
import sys
import time

for line in sys.stdin:
    json.loads(line)
    time.sleep(0.4)
    sys.stdout.write(json.dumps({
        "type": "assistant",
        "message": {"content": [{
            "type": "tool_use", "id": "tool-1", "name": "read",
            "input": {"path": "README.md"},
        }]},
    }) + "\n")
    sys.stdout.flush()
    time.sleep(0.4)
    sys.stdout.write(json.dumps({
        "type": "user",
        "message": {"content": [{
            "type": "tool_result", "tool_use_id": "tool-1",
            "content": "done",
        }]},
    }) + "\n")
    sys.stdout.flush()
    time.sleep(0.4)
    sys.stdout.write(json.dumps({
        "type": "result", "subtype": "success", "result": "review complete",
    }) + "\n")
    sys.stdout.flush()
"""#)
        defer {
            try? FileManager.default.removeItem(
                at: executable.deletingLastPathComponent())
        }

        let bridge = ClaudeBridge(executableURL: executable)
        defer { bridge.stop() }
        let started = ProcessInfo.processInfo.systemUptime

        let reply = try await bridge.turn(
            prompt: "review", system: "test", model: "test-model",
            timeout: 1.0)

        XCTAssertEqual(reply, "review complete")
        XCTAssertGreaterThan(
            ProcessInfo.processInfo.systemUptime - started, 1.0,
            "the fixture must outlive the wall-clock timeout")
    }

    func testSilentClaudeTurnStillFailsAtInactivityTimeout() async throws {
        let executable = try makePythonExecutable(#"""
import json
import os
import signal
import sys
import time

signal.signal(signal.SIGTERM, lambda _signum, _frame: None)

for line in sys.stdin:
    request = json.loads(line)
    prompt = request["message"]["content"][0]["text"]
    if "stall" in prompt:
        sys.stdout.write(json.dumps({
            "type": "assistant",
            "message": {"content": [{
                "type": "text", "text": "pid:" + str(os.getpid()),
            }]},
        }) + "\n")
        sys.stdout.flush()
        time.sleep(1.8)
        result = "too late"
    else:
        time.sleep(2.0)
        result = "fresh:" + str(os.getpid())
    sys.stdout.write(json.dumps({
        "type": "result", "subtype": "success", "result": result,
    }) + "\n")
    sys.stdout.flush()
"""#)
        defer {
            try? FileManager.default.removeItem(
                at: executable.deletingLastPathComponent())
        }

        let bridge = ClaudeBridge(executableURL: executable)
        defer { bridge.stop() }
        let firstPartial = ClaudeTimeoutValue()
        let partialReceived = expectation(description: "first process identified")

        do {
            _ = try await bridge.turn(
                prompt: "stall", system: "test", model: "test-model",
                timeout: 1.0,
                onPartial: { text in
                    firstPartial.set(text)
                    partialReceived.fulfill()
                })
            XCTFail("silent Claude turn should have timed out")
        } catch let error as ClaudeBridgeError {
            XCTAssertEqual(
                error.localizedDescription,
                "Claude was inactive for the configured turn timeout.")
        }
        await fulfillment(of: [partialReceived], timeout: 2)

        let reply = try await bridge.turn(
            prompt: "retry", system: "test", model: "test-model",
            timeout: 3)
        XCTAssertTrue(reply.hasPrefix("fresh:"), reply)
        XCTAssertFalse(reply.contains("too late"))
        XCTAssertNotEqual(
            firstPartial.value
                .split(separator: ":").last.map(String.init),
            reply.split(separator: ":").last.map(String.init),
            "the retry must run in a fresh process")
    }

    private func makePythonExecutable(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "infinitty-claude-timeout-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fixture.py")
        let body = "#!/usr/bin/env python3\n" + source
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}

private final class ClaudeTimeoutValue: @unchecked Sendable {
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
