import XCTest

@testable import InfinittyKit

final class ProviderDiscoveryTests: XCTestCase {

    // MARK: CLIExecutableResolver

    func testCodexResolverFindsHomebrewInstall() {
        let env = ProcessInfo.processInfo.environment
        // The CI / dev box may genuinely lack codex; just confirm the
        // probe walks the same fixed paths openclicky does.
        let candidates = CLIExecutableResolver.candidates(
            for: .codex,
            environment: env)
        let labels = candidates.map { $0.lastPathComponent }
        XCTAssertTrue(labels.allSatisfy { $0 == "codex" },
                      "every codex probe should be named codex")
    }

    func testCodexResolverHonorsEnvOverride() {
        let tmp = makeExecutable()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let env = ["INFINITTY_CODEX_EXECUTABLE": tmp.path]
        let resolved = CLIExecutableResolver.resolve(.codex, environment: env)
        XCTAssertEqual(resolved?.path, tmp.path)
    }

    func testClaudeResolverHonorsHomeLocalBin() {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/dev/null/no/such/bin"
        env.removeValue(forKey: "HOMEBREW_BREW_FILE")
        let candidates = CLIExecutableResolver.candidates(for: .claude, environment: env)
        // ~/.local/bin/claude is one of the fixed candidates and the
        // canonical install path — it must be probed even with PATH wiped.
        XCTAssertTrue(candidates.contains { $0.path.hasSuffix("/.local/bin/claude") })
    }

    func testResolversAreIdempotentAcrossCalls() {
        let env = ProcessInfo.processInfo.environment
        let a = CLIExecutableResolver.candidates(for: .codex, environment: env)
        let b = CLIExecutableResolver.candidates(for: .codex, environment: env)
        XCTAssertEqual(a.map(\.path), b.map(\.path))
    }

    // MARK: ProviderDiscovery.preferredProvider

    func testPreferredProviderAutoPrefersClaudeWhenInstalled() {
        let env = ProcessInfo.processInfo.environment
        let detected = ProviderDiscovery.preferredProvider(
            configured: "auto",
            environment: env
        )
        // If neither CLI is installed in CI, this is nil. If a Claude CLI
        // is sitting on this Mac (the workspace does ship it), the first
        // pick under auto should be Claude.
        let codexOK = CLIExecutableResolver.resolve(.codex, environment: env) != nil
        let claudeOK = CLIExecutableResolver.resolve(.claude, environment: env) != nil
        if claudeOK {
            XCTAssertEqual(detected, .claude,
                           "auto should pick Claude first when present")
        } else if codexOK {
            XCTAssertEqual(detected, .codex)
        } else {
            XCTAssertNil(detected,
                         "with neither CLI installed, auto should yield nil")
        }
    }

    func testPreferredProviderRejectsUnavailableExplicitPick() {
        let env = ProcessInfo.processInfo.environment
        let explicit = ProviderDiscovery.preferredProvider(
            configured: "codex",
            environment: env
        )
        if CLIExecutableResolver.resolve(.codex, environment: env) == nil {
            XCTAssertNil(explicit,
                         "explicit codex with no binary should yield nil")
        } else {
            XCTAssertEqual(explicit, .codex)
        }
    }

    func testPreferredProviderAliasesMapToCanonicalNames() {
        // Generic aliases like "anthropic" or "openai" still resolve.
        let env = ProcessInfo.processInfo.environment
        for (alias, expected) in [
            ("anthropic", InfinittyAIProvider.claude),
            ("openai",    InfinittyAIProvider.codex),
        ] {
            let resolved = ProviderDiscovery.preferredProvider(
                configured: alias, environment: env
            )
            if resolved != nil {
                XCTAssertEqual(resolved, expected, "alias \(alias)")
            }
        }
    }

    // MARK: MCPConfiguration

    func testCodexTOMLBlockIsStable() {
        // Inject a fake binary path so the bundle gate doesn't gate us.
        let fake = "/tmp/infinitty-mcp-fake"
        let existing = "model = \"gpt-5\"\n[notifications]\nenabled = true\n"
        let merged = MCPConfiguration.mergedCodexConfigTOML(
            existing: existing, binaryPath: fake
        )
        XCTAssertTrue(merged.contains("[mcp_servers.infinitty]"))
        XCTAssertTrue(merged.contains("command = \"\(fake)\""))
        XCTAssertTrue(merged.contains("[notifications]"),
                      "pre-existing sections must survive the merge")
    }

    func testCodexRegistrationIsIdempotent() {
        // Verify the merge-by-string path (used by registerWithCodex in
        // production) is idempotent: running it twice produces the same
        // block, not a duplicated one.
        let fake = "/tmp/infinitty-mcp-fake"
        let first = MCPConfiguration.mergedCodexConfigTOML(
            existing: "", binaryPath: fake
        )
        let second = MCPConfiguration.mergedCodexConfigTOML(
            existing: first, binaryPath: fake
        )
        let count = second.components(separatedBy: "[mcp_servers.infinitty]").count
        XCTAssertEqual(count, 2,
                       "block header should appear exactly once (split count = 2)")
        XCTAssertEqual(first, second,
                       "merge must be a no-op on already-merged content")
    }

    func testClaudeUserMCPConfigLivesInClaudeJSON() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-claude-home-\(UUID().uuidString)", isDirectory: true)
        let url = MCPConfiguration.claudeMCPConfigURL(
            environment: ["HOME": home.path])
        XCTAssertEqual(url.path, home.appendingPathComponent(".claude.json").path)
    }

    func testClaudeRegistrationMergesExistingServers() {
        let claudeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-mcp-test-claude-\(UUID().uuidString)",
                                    isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: claudeDir) }
        try? FileManager.default.createDirectory(
            at: claudeDir, withIntermediateDirectories: true)
        let file = claudeDir.appendingPathComponent("mcp_servers.json")
        let preExisting = #"""
        {
          "mcpServers": {
            "github": { "command": "/usr/local/bin/gh-mcp" }
          }
        }
        """#
        try? preExisting.write(to: file, atomically: true, encoding: .utf8)

        let data = MCPConfiguration.mergedClaudeMCPJSON(
            existing: Data(preExisting.utf8),
            binaryPath: "/some/path/infinitty-mcp")
        XCTAssertNotNil(data)
        let round = try? JSONSerialization.jsonObject(
            with: data!) as? [String: Any]
        let merged = (round?["mcpServers"] as? [String: Any])
        XCTAssertNotNil(merged?["github"])
        XCTAssertNotNil(merged?["infinitty"])
    }

    func testClaudeRegistrationRefusesToOverwriteInvalidJSON() {
        XCTAssertNil(MCPConfiguration.mergedClaudeMCPJSON(
            existing: Data("not json".utf8),
            binaryPath: "/some/path/infinitty-mcp"))
    }

    // MARK: helpers

    private func makeExecutable() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("fake-binary")
        try? "#!/bin/sh\necho ok\n".write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }
}
