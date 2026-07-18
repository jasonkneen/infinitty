import XCTest
@testable import InfinittyKit

final class AgentBackendTests: XCTestCase {

    // MARK: detection

    func testDetectsCodexAndClaudeOnPath() {
        let env = ["PATH": "/opt/homebrew/bin:/usr/bin"]
        let present: Set<String> = ["/opt/homebrew/bin/codex", "/opt/homebrew/bin/claude"]
        let agents = AgentDetector.detect(env: env) { present.contains($0) }
        XCTAssertEqual(agents.map(\.kind), [.codex, .claude])
        XCTAssertEqual(agents.first?.path, "/opt/homebrew/bin/codex")
        XCTAssertEqual(agents.map(\.label), ["Codex", "Claude"])
    }

    func testDetectsOnlyWhatExists() {
        let env = ["PATH": "/usr/bin"]
        let present: Set<String> = ["/usr/bin/claude"]
        let agents = AgentDetector.detect(env: env) { present.contains($0) }
        XCTAssertEqual(agents.map(\.kind), [.claude])
    }

    func testFallsBackToKnownPathsWhenNotOnPath() {
        let env = ["PATH": "/nonexistent"]
        let home = NSString(string: "~/.local/bin/claude").expandingTildeInPath
        let agents = AgentDetector.detect(env: env) { $0 == home }
        XCTAssertEqual(agents.map(\.kind), [.claude])
        XCTAssertEqual(agents.first?.path, home)
    }

    func testDetectsNothingWhenAbsent() {
        let agents = AgentDetector.detect(env: ["PATH": "/nope"]) { _ in false }
        XCTAssertTrue(agents.isEmpty)
    }

    // MARK: argv contracts

    func testClaudeArgsUseNonInteractivePrint() {
        XCTAssertEqual(
            AgentDetector.args(for: .claude, model: nil),
            ["-p", "--output-format", "text"])
        XCTAssertEqual(
            AgentDetector.args(for: .claude, model: "claude-sonnet-4"),
            ["-p", "--output-format", "text", "--model", "claude-sonnet-4"])
    }

    func testCodexArgsUseExecStdinNoPromptArg() {
        let args = AgentDetector.args(for: .codex, model: nil)
        XCTAssertEqual(args, ["exec", "--skip-git-repo-check"])
        XCTAssertFalse(args.contains("-"), "codex must read stdin via no-prompt-arg, not a literal '-'")
        XCTAssertEqual(
            AgentDetector.args(for: .codex, model: "o3"),
            ["exec", "--skip-git-repo-check", "-m", "o3"])
    }

    // MARK: routing

    private func agents(_ kinds: [DetectedAgent.Kind]) -> [DetectedAgent] {
        kinds.map { DetectedAgent(kind: $0, path: "/bin/\($0.rawValue)") }
    }

    func testAutoPrefersDetectedAgentsFirst() {
        var config = AppConfig()
        config.aiBaseURL = "https://api.example.com/v1"
        let pet = PetAssistant(config: config, detectedAgents: agents([.codex, .claude]))
        let chain = pet.backendChain(for: "Auto · Best available")
        guard case .agent(let first) = chain.first else {
            return XCTFail("Auto should try a detected agent first")
        }
        XCTAssertEqual(first.kind, .codex)
        // The OpenAI smart source is appended as a fallback after the agents.
        if case .smart = chain.last {} else {
            XCTFail("Auto should fall back to the configured smart source")
        }
        XCTAssertEqual(chain.count, 3)
    }

    func testExplicitAgentForcesSingleBackend() {
        let pet = PetAssistant(config: AppConfig(), detectedAgents: agents([.codex, .claude]))
        let chain = pet.backendChain(for: "Claude")
        XCTAssertEqual(chain.count, 1)
        guard case .agent(let only) = chain.first else {
            return XCTFail("explicit pick should force one agent")
        }
        XCTAssertEqual(only.kind, .claude)
    }

    func testConfiguredModelTitleRoutesToOpenAI() {
        var config = AppConfig()
        config.aiBaseURL = "https://api.example.com/v1"
        let pet = PetAssistant(config: config, detectedAgents: [])
        let chain = pet.backendChain(for: "gpt-4o-mini")
        XCTAssertEqual(chain.count, 1)
        guard case .smart(.openai(_, _, let model)) = chain.first else {
            return XCTFail("a configured model title should route to OpenAI")
        }
        XCTAssertEqual(model, "gpt-4o-mini")
    }

    // MARK: picker integration

    func testComposerListsDetectedAgents() {
        let pet = PetAssistant(config: AppConfig(), detectedAgents: agents([.codex, .claude]))
        let panel = pet.makeSidebarPanelView()
        let titles = panel.modelItemTitlesForTesting
        XCTAssertEqual(titles.first, "Auto · Best available")
        XCTAssertTrue(titles.contains("Codex"))
        XCTAssertTrue(titles.contains("Claude"))
    }
    // MARK: spawn (real Process, fake executable)

    /// Write an executable shell script to a temp path and return it.
    private func makeFakeExecutable(_ body: String) throws -> String {
        let dir = NSTemporaryDirectory() + "infinitty-fake-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/claude"
        try ("#!/bin/sh\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testSpawnAgentReturnsStdoutAndDrainsStderr() throws {
        // Echoes stdin to stdout, and writes noise to stderr (must be drained,
        // not merged into the answer).
        let script = try makeFakeExecutable(
            "cat\nfor i in $(seq 1 500); do echo noise-$i 1>&2; done\n")
        let agent = DetectedAgent(kind: .claude, path: script)
        let exp = expectation(description: "spawn")
        var result: String?
        PetAssistant.spawnAgent(agent, system: "SYS", user: "hello world") { answer in
            result = answer
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        XCTAssertEqual(result, "SYS\n\nhello world")
        XCTAssertFalse(result?.contains("noise") ?? true, "stderr must not leak into the answer")
    }

    func testSpawnAgentRunsInProvidedCwd() throws {
        let script = try makeFakeExecutable("pwd\n")
        let agent = DetectedAgent(kind: .claude, path: script)
        let dir = NSTemporaryDirectory() + "infinitty-cwd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let exp = expectation(description: "cwd")
        var result: String?
        PetAssistant.spawnAgent(agent, system: "", user: "", cwd: dir) { answer in
            result = answer
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        // pwd may resolve /var → /private/var symlink; compare last path component.
        XCTAssertEqual(
            (result as NSString?)?.lastPathComponent,
            (dir as NSString).lastPathComponent)
    }

    func testSpawnAgentTimesOutToNil() throws {
        let script = try makeFakeExecutable("sleep 5\necho too-late\n")
        let agent = DetectedAgent(kind: .claude, path: script)
        let exp = expectation(description: "timeout")
        var result: String? = "unset"
        PetAssistant.spawnAgent(agent, system: "", user: "x", timeout: 0.5) { answer in
            result = answer
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        XCTAssertNil(result, "a run exceeding the timeout is killed and yields nil")
    }

    func testSpawnAgentNonZeroExitYieldsNil() throws {
        let script = try makeFakeExecutable("exit 3\n")
        let agent = DetectedAgent(kind: .claude, path: script)
        let exp = expectation(description: "exit")
        var result: String? = "unset"
        PetAssistant.spawnAgent(agent, system: "", user: "x") { answer in
            result = answer
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        XCTAssertNil(result)
    }
}
