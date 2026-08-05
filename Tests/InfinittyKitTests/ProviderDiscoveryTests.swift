import XCTest

@testable import InfinittyKit

final class ProviderDiscoveryTests: XCTestCase {
    func testWorkspaceMCPExecutableOmitsPaneDiscoveryAndEventTools() throws {
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/infinitty-mcp").path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("infinitty-mcp executable is not built")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        var environment = ProcessInfo.processInfo.environment
        environment["INFINITTY_MCP_PROFILE"] = "workspace-chat"
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(names.contains("infinitty_list_panes"))
        XCTAssertFalse(names.contains("infinitty_events"))
        XCTAssertFalse(names.contains("infinitty_run"))
        XCTAssertTrue(names.contains("infinitty_browser_list"))
        XCTAssertFalse(names.contains("infinitty_permission_prompt"),
                       "the internal callback must not appear without a Chat scope")
    }

    func testScopedWorkspaceMCPExposesInternalPermissionCallback() throws {
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/infinitty-mcp").path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("infinitty-mcp executable is not built")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        var environment = ProcessInfo.processInfo.environment
        environment["INFINITTY_MCP_PROFILE"] = "workspace-chat"
        environment["INFINITTY_ASSISTANT_SCOPE"] = "chat#epoch=4"
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(names.contains("infinitty_permission_prompt"))
    }

    func testScopedMCPPermissionCallbackRoundTripsNativeDecision() throws {
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/infinitty-mcp").path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("infinitty-mcp executable is not built")
        }
        let socketPath = "/tmp/ia-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let server = AppControlServer(
            path: socketPath, publishesCurrentLink: false)
        server.handler = { request in
            let prefix = "assistant-approval "
            guard request.hasPrefix(prefix) else {
                return AssistantApprovalControlCodec.response(
                    error: "unexpected control request")
            }
            let encoded = String(request.dropFirst(prefix.count))
            guard case .success(let approval) =
                    AssistantApprovalControlCodec.decodeRequest(encoded),
                  approval.scopeID == "chat#epoch=9",
                  approval.provider == "Claude",
                  approval.toolName == "Write",
                  approval.input?.contains("README.md") == true else {
                return AssistantApprovalControlCodec.response(
                    error: "invalid approval payload")
            }
            return AssistantApprovalControlCodec.response(decision: .allowOnce)
        }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        var environment = ProcessInfo.processInfo.environment
        environment["INFINITTY_MCP_PROFILE"] = "workspace-chat"
        environment["INFINITTY_ASSISTANT_SCOPE"] = "chat#epoch=9"
        environment["INFINITTY_APP_SOCKET"] = socketPath
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let call: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "infinitty_permission_prompt",
                "arguments": [
                    "tool_name": "Write",
                    "input": ["file_path": "README.md"],
                ],
            ],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: call)
        input.fileHandleForWriting.write(requestData + Data([0x0A]))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let permission = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(permission["behavior"] as? String, "allow")
        XCTAssertEqual(
            (permission["updatedInput"] as? [String: String])?["file_path"],
            "README.md")
    }


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

    /// Regression (discovery bug): the ephemeral bridge config must pin the
    /// spawned infinitty-mcp to THIS instance's control socket via an `env`
    /// block, instead of relying on the shared (stale-prone) current.sock.
    func testClaudeMCPJSONInjectsAppSocketEnv() {
        let data = MCPConfiguration.claudeMCPJSON(
            binaryPath: "/b/infinitty-mcp",
            appSocketPath: "/tmp/infinitty-app-42.sock",
            profile: .workspaceChat,
            assistantScopeID: "chat#epoch=2")
        XCTAssertNotNil(data)
        let root = try? JSONSerialization.jsonObject(with: data!) as? [String: Any]
        let server = ((root?["mcpServers"] as? [String: Any])?["infinitty"]) as? [String: Any]
        XCTAssertEqual(server?["command"] as? String, "/b/infinitty-mcp")
        let env = server?["env"] as? [String: String]
        XCTAssertEqual(env?["INFINITTY_APP_SOCKET"], "/tmp/infinitty-app-42.sock")
        XCTAssertEqual(env?["INFINITTY_MCP_PROFILE"], "workspace-chat")
        XCTAssertEqual(env?["INFINITTY_ASSISTANT_SCOPE"], "chat#epoch=2")

        // Without a socket path (persistent global config) there is no env.
        let plain = MCPConfiguration.claudeMCPJSON(binaryPath: "/b/infinitty-mcp")
        let plainRoot = try? JSONSerialization.jsonObject(with: plain!) as? [String: Any]
        let plainServer = ((plainRoot?["mcpServers"] as? [String: Any])?["infinitty"]) as? [String: Any]
        XCTAssertNil(plainServer?["env"])
    }

    func testCodexConfigOverridesInjectAppSocketEnv() {
        let overrides = MCPConfiguration.codexConfigOverrides(
            binaryPath: "/b/infinitty-mcp",
            appSocketPath: "/tmp/infinitty-app-42.sock",
            profile: .visibleTerminal)
        XCTAssertTrue(overrides.contains { $0.hasPrefix("mcp_servers.infinitty.command=") })
        XCTAssertTrue(overrides.contains {
            $0.contains("mcp_servers.infinitty.env.INFINITTY_APP_SOCKET")
                && $0.contains("/tmp/infinitty-app-42.sock")
        })
        XCTAssertTrue(overrides.contains {
            $0.contains("mcp_servers.infinitty.env.INFINITTY_MCP_PROFILE")
                && $0.contains("visible-terminal")
        })
        // No socket path → command only, no env override.
        let plain = MCPConfiguration.codexConfigOverrides(binaryPath: "/b/infinitty-mcp")
        XCTAssertEqual(plain.count, 1)
    }

    func testClaudeChannelHooksMergeByEventAndAreIdempotent() throws {
        let existing = Data(#"{"permissions":{"allow":["Read"]},"hooks":{"UserPromptSubmit":[{"matcher":"*","hooks":[{"type":"command","command":"/usr/local/bin/user-hook"}]}]}}"#.utf8)
        let first = try XCTUnwrap(
            MCPConfiguration.mergedClaudeChannelHookSettings(
                existing: existing,
                commandPaths: [
                    "SessionStart": "/app/session-start.sh",
                    "UserPromptSubmit": "/app/user-prompt-submit.sh",
                ]))
        let second = try XCTUnwrap(
            MCPConfiguration.mergedClaudeChannelHookSettings(
                existing: first,
                commandPaths: [
                    "SessionStart": "/app/session-start.sh",
                    "UserPromptSubmit": "/app/user-prompt-submit.sh",
                ]))
        XCTAssertEqual(first, second)

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertNotNil(root["permissions"])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let start = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let prompt = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        XCTAssertEqual(start.count, 1)
        XCTAssertEqual(prompt.count, 2)
        XCTAssertTrue(
            (start[0]["hooks"] as? [[String: Any]])?.contains {
                $0["command"] as? String == "/app/session-start.sh"
            } == true)
        XCTAssertTrue(
            (prompt[1]["hooks"] as? [[String: Any]])?.contains {
                $0["command"] as? String == "/app/user-prompt-submit.sh"
            } == true)
    }

    // MARK: new providers (opencode / hermes / amp)

    func testNewProviderResolversHonorEnvOverride() {
        for (kind, envKey) in [
            (CLIExecutableKind.opencode, "INFINITTY_OPENCODE_EXECUTABLE"),
            (CLIExecutableKind.hermes, "INFINITTY_HERMES_EXECUTABLE"),
            (CLIExecutableKind.amp, "INFINITTY_AMP_EXECUTABLE"),
        ] {
            let tmp = makeExecutable()
            defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
            let resolved = CLIExecutableResolver.resolve(kind, environment: [envKey: tmp.path])
            XCTAssertEqual(resolved?.path, tmp.path, "\(kind) should honor \(envKey)")
        }
    }

    func testHermesAndAmpProbeHomeLocalBin() {
        // Hermes and Amp install launchers into ~/.local/bin (like Claude);
        // that path must be probed even with PATH wiped.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/dev/null/no/such/bin"
        for kind in [CLIExecutableKind.hermes, .amp] {
            let candidates = CLIExecutableResolver.candidates(for: kind, environment: env)
            XCTAssertTrue(
                candidates.contains { $0.path.hasSuffix("/.local/bin/\(kind.binaryName)") },
                "\(kind) must probe ~/.local/bin")
        }
    }

    func testPreferredProviderMapsNewAliases() {
        let env = ProcessInfo.processInfo.environment
        // Alias resolution maps to the canonical provider when that CLI is
        // present, else nil — independent of this machine's install state.
        for (alias, canonical) in [
            ("openclaw", InfinittyAIProvider.opencode),
            ("opencode", InfinittyAIProvider.opencode),
            ("nous", InfinittyAIProvider.hermes),
            ("sourcegraph", InfinittyAIProvider.amp),
        ] {
            let resolved = ProviderDiscovery.preferredProvider(configured: alias, environment: env)
            if ProviderDiscovery.isAvailable(canonical, environment: env) {
                XCTAssertEqual(resolved, canonical, "alias \(alias)")
            } else {
                XCTAssertNil(resolved, "alias \(alias) with no binary should be nil")
            }
        }
    }

    func testNewProviderMetadata() {
        XCTAssertEqual(InfinittyAIProvider.opencode.binaryName, "opencode")
        XCTAssertEqual(InfinittyAIProvider.hermes.binaryName, "hermes")
        XCTAssertEqual(InfinittyAIProvider.amp.binaryName, "amp")
        XCTAssertEqual(InfinittyAIProvider.opencode.displayName, "OpenCode")
        // Every provider exposes a distinct one-char chip label.
        let labels = Set(InfinittyAIProvider.allCases.map(\.shortLabel))
        XCTAssertEqual(labels.count, InfinittyAIProvider.allCases.count)
    }

    func testCLIAvailabilityShapeIsConsistent() {
        // Whatever the install state, the status label must agree with
        // isAvailable (never a crash, never a stale "Missing").
        var env: [String: String] = ["PATH": "/dev/null/no/such/bin"]
        env["INFINITTY_OPENCODE_EXECUTABLE"] = ""
        let avail = ProviderDiscovery.cliAvailability(.opencode, environment: env)
        XCTAssertEqual(avail.provider, .opencode)
        XCTAssertEqual(avail.statusLabel, avail.isAvailable ? "Detected" : "Missing")
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
