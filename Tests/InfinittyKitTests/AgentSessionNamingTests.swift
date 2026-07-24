import XCTest
@testable import InfinittyKit

final class AgentSessionNamingTests: XCTestCase {

    func testAgentNameRecognizesKnownCLIsAndIgnoresOthers() {
        XCTAssertEqual(AgentSessionNaming.agentName(forProcessName: "Claude Code claude"), "claude")
        XCTAssertEqual(AgentSessionNaming.agentName(forProcessName: "codex codex"), "codex")
        XCTAssertEqual(AgentSessionNaming.agentName(forProcessName: "cursor-agent cursor-agent"), "cursor")
        XCTAssertEqual(AgentSessionNaming.agentName(forProcessName: "amp amp"), "amp")
        // Short names must match whole words only.
        XCTAssertNil(AgentSessionNaming.agentName(forProcessName: "sampler sampler"))
        XCTAssertNil(AgentSessionNaming.agentName(forProcessName: "zsh zsh"))
        XCTAssertNil(AgentSessionNaming.agentName(forProcessName: "vim vim"))
    }

    func testFallbackNameUsesAgentAndDirectoryBasename() {
        XCTAssertEqual(
            AgentSessionNaming.fallbackName(agent: "claude", cwd: "/Users/x/GitHub/titerm"),
            "claude · titerm")
        XCTAssertEqual(AgentSessionNaming.fallbackName(agent: "codex", cwd: nil), "codex")
        XCTAssertEqual(AgentSessionNaming.fallbackName(agent: "codex", cwd: "/"), "codex")
    }

    func testClaudeProjectSlugReplacesNonAlphanumerics() {
        XCTAssertEqual(
            AgentSessionNaming.claudeProjectSlug(forCwd: "/Users/jk/Documents/GitHub/titerm"),
            "-Users-jk-Documents-GitHub-titerm")
        XCTAssertEqual(
            AgentSessionNaming.claudeProjectSlug(forCwd: "/Users/jk/dev.app_v2"),
            "-Users-jk-dev-app-v2")
    }

    func testTranscriptTitleSkipsMetaAndFindsFirstRealPrompt() throws {
        let lines: [[String: Any]] = [
            ["type": "summary", "summary": "not this"],
            ["type": "user", "message": ["content": "<command-name>/clear</command-name>"]],
            ["type": "user", "message": ["content": "Caveat: injected context"]],
            ["type": "user", "message": ["content": [
                ["type": "tool_result", "content": "ignored"],
            ]]],
            ["type": "user", "message": ["content": "fix the pet bubbles\nplus more detail"]],
            ["type": "assistant", "message": ["content": "on it"]],
        ]
        let data = try lines.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }.joined(separator: "\n").data(using: .utf8)!
        XCTAssertEqual(
            AgentSessionNaming.title(fromTranscriptData: data),
            "fix the pet bubbles")
    }

    func testTranscriptTitleReadsTextPartsArray() throws {
        let line: [String: Any] = ["type": "user", "message": ["content": [
            ["type": "text", "text": "rename   the tabs  properly"],
        ]]]
        let data = try JSONSerialization.data(withJSONObject: line)
        XCTAssertEqual(
            AgentSessionNaming.title(fromTranscriptData: data),
            "rename the tabs properly")
    }

    func testCompactTitleCollapsesAndEllipsizes() {
        XCTAssertEqual(AgentSessionNaming.compactTitle("short one"), "short one")
        let long = AgentSessionNaming.compactTitle(String(repeating: "word ", count: 30))
        XCTAssertLessThanOrEqual(long.count, 36)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testClaudeSessionTitleFindsNewestTranscriptForCwd() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-naming-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/tmp/demo"
        let projectDir = home.appendingPathComponent(
            ".claude/projects/" + AgentSessionNaming.claudeProjectSlug(forCwd: cwd))
        try FileManager.default.createDirectory(
            at: projectDir, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "type": "user", "message": ["content": "ship the release"],
        ]
        try JSONSerialization.data(withJSONObject: record)
            .write(to: projectDir.appendingPathComponent("abc.jsonl"))

        XCTAssertEqual(
            AgentSessionNaming.claudeSessionTitle(
                cwd: cwd, startedAfter: Date(timeIntervalSinceNow: -60),
                home: home.path),
            "ship the release")
        // A cutoff after the file's mtime finds nothing.
        XCTAssertNil(
            AgentSessionNaming.claudeSessionTitle(
                cwd: cwd, startedAfter: Date(timeIntervalSinceNow: 60),
                home: home.path))
    }
}
