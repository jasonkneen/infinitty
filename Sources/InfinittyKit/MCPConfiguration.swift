import Foundation

/// Writes the bundled `infinitty-mcp` server into Codex's and Claude's MCP
/// config files, and (when enabled) installs the provider-neutral Claude
/// context hooks so the CLIs gain terminal/Channel awareness automatically.
///
/// This is what makes "the latter two have access to a full suite of tools
/// to control the terminal interface" — when Codex or Claude is picked,
/// infinitty registers itself as an MCP server and the CLIs discover the
/// full tool suite exposed by `infinitty-mcp` (list_panes, run, key, screen,
/// history, send, last_output, app configuration, etc.) without per-call wiring.
///
/// Idempotent: re-running replaces the entry, not the file. Matched on
/// `[mcp_servers.infinitty]` (TOML) and on `mcpServers.infinitty` (JSON).
public enum MCPConfiguration {
    static let serverName = "infinitty"

    private static let channelHookEvents = ["SessionStart", "UserPromptSubmit"]

    /// Absolute path to the provider-neutral agent edge that ships next to
    /// the MCP executable. Hooks use this binary to read the pane-bound
    /// Channel without loading the GUI or a provider SDK.
    public static func agentExecutablePath(
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> String? {
        let candidates: [String] = [
            bundle.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("infinitty-agent").path,
            "\(bundle.bundlePath)/Contents/MacOS/infinitty-agent",
            "\(bundle.bundlePath)/MacOS/infinitty-agent",
        ].compactMap { $0 }
        return candidates.first {
            fileManager.isExecutableFile(atPath: $0)
        }
    }

    /// Path to the bundled Claude-compatible hook script for a hook phase.
    public static func claudeChannelHookPath(
        event: String = "UserPromptSubmit",
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> String? {
        let fileName = event == "SessionStart"
            ? "infinitty-agent-context-session-start.sh"
            : "infinitty-agent-context-user-prompt-submit.sh"
        let candidates: [String] = [
            bundle.resourceURL?.appendingPathComponent(
                "shell-integration/\(fileName)").path,
            "\(bundle.bundlePath)/Contents/Resources/shell-integration/"
                + fileName,
        ].compactMap { $0 }
        return candidates.first {
            fileManager.isExecutableFile(atPath: $0)
        }
    }

    /// Absolute path to the infinitty-mcp binary that ships inside the
    /// app bundle (sibling of the main executable). Re-checked lazily so
    /// tests can swap Bundle.main; in production this resolves to
    /// <infinitty.app>/Contents/MacOS/infinitty-mcp.
    public static func mcpExecutablePath(
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> String? {
        let candidates: [String] = [
            bundle.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("infinitty-mcp").path,
            "\(bundle.bundlePath)/Contents/MacOS/infinitty-mcp",
            "\(bundle.bundlePath)/MacOS/infinitty-mcp",
        ].compactMap { $0 }

        return candidates.first {
            fileManager.isExecutableFile(atPath: $0)
        }
    }

    // MARK: - Codex

    /// Path to Codex's config.toml, honoring $CODEX_HOME.
    public static func codexConfigURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let home = environment["CODEX_HOME"]
            ?? NSString(string: "~/.codex").expandingTildeInPath
        return URL(fileURLWithPath: home).appendingPathComponent("config.toml")
    }

    /// `[mcp_servers.infinitty]` block to merge into Codex's config.
    /// Returns nil when the MCP binary isn't reachable from this app
    /// bundle (e.g. a stripped Release cut, or running from CLI without
    /// a built `.app`).
    public static func codexTOMLBlock(
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> String? {
        guard let binary = mcpExecutablePath(fileManager: fileManager, bundle: bundle) else { return nil }
        return codexTOMLBlock(binaryPath: binary)
    }

    /// Lower-level helper: merge the `[mcp_servers.infinitty]` block into
    /// an existing Codex config string, given an explicit binary path.
    /// Exposed so unit tests can verify merge semantics without needing
    /// the bundled MCP exec to live inside Bundle.main.
    public static func mergedCodexConfigTOML(
        existing: String, binaryPath: String
    ) -> String {
        let block = codexTOMLBlock(binaryPath: binaryPath)
        let header = "[mcp_servers.\(serverName)]"
        var lines = existing.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == header
        }) {
            var end = start + 1
            while end < lines.count {
                let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { break }
                end += 1
            }
            lines.replaceSubrange(start..<end, with: block
                .trimmingCharacters(in: .newlines)
                .components(separatedBy: "\n"))
            var result = lines.joined(separator: "\n")
            if existing.hasSuffix("\n"), !result.hasSuffix("\n") { result += "\n" }
            return result
        }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        return existing + separator + block
    }

    static func codexTOMLBlock(binaryPath: String) -> String {
        let quoted = tomlQuoted(binaryPath)
        return """
        [mcp_servers.\(serverName)]
        command = \(quoted)

        """
    }

    static func codexConfigOverride(binaryPath: String) -> String {
        "mcp_servers.\(serverName).command=\(tomlQuoted(binaryPath))"
    }

    /// Codex `-c` override values for the ephemeral bridge launch. When an app
    /// control-socket path is supplied it is injected as the MCP server's
    /// `INFINITTY_APP_SOCKET` env var, so the spawned `infinitty-mcp` targets
    /// THIS running instance rather than falling back to the shared
    /// `/tmp/infinitty-current.sock` symlink (which can be stale/dangling).
    static func codexConfigOverrides(
        binaryPath: String,
        appSocketPath: String? = nil,
        profile: AgentExecutionProfile? = nil
    ) -> [String] {
        var overrides = [codexConfigOverride(binaryPath: binaryPath)]
        if let appSocketPath {
            overrides.append(
                "mcp_servers.\(serverName).env.INFINITTY_APP_SOCKET=\(tomlQuoted(appSocketPath))")
        }
        if let profile {
            overrides.append(
                "mcp_servers.\(serverName).env.INFINITTY_MCP_PROFILE=\(tomlQuoted(profile.rawValue))")
        }
        return overrides
    }

    /// Append `[mcp_servers.infinitty]` to Codex's user-level config.toml
    /// unless it's already present. Idempotent.
    @discardableResult
    public static func registerWithCodex(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let binary = mcpExecutablePath(fileManager: fileManager, bundle: bundle) else { return false }
        let url = codexConfigURL(fileManager: fileManager, environment: environment)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return false
        }
        let existing: String
        if fileManager.fileExists(atPath: url.path) {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                return false
            }
            existing = contents
        } else {
            existing = ""
        }
        let merged = mergedCodexConfigTOML(existing: existing, binaryPath: binary)
        do {
            try merged.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Claude

    /// Path to Claude Code's user-scoped MCP configuration. Project-scoped
    /// servers live in `<project>/.mcp.json`; user-scoped servers are stored
    /// in `~/.claude.json` and are available from every working directory.
    public static func claudeMCPConfigURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let home = environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
    }

    /// JSON content for `~/.claude.json` (top-level
    /// `mcpServers` object). Kept minimal — Claude CLI picks up the
    /// `command` field and runs it as stdio MCP.
    public static func claudeMCPJSON(
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> Data? {
        guard let binary = mcpExecutablePath(fileManager: fileManager, bundle: bundle) else { return nil }
        return claudeMCPJSON(binaryPath: binary)
    }

    static func claudeMCPJSON(
        binaryPath: String,
        appSocketPath: String? = nil,
        profile: AgentExecutionProfile? = nil
    ) -> Data? {
        var server: [String: Any] = ["command": binaryPath]
        var environment: [String: String] = [:]
        if let appSocketPath {
            // Pin the spawned infinitty-mcp to THIS instance's control socket
            // instead of the shared (possibly stale) current.sock symlink.
            environment["INFINITTY_APP_SOCKET"] = appSocketPath
        }
        if let profile {
            environment["INFINITTY_MCP_PROFILE"] = profile.rawValue
        }
        if !environment.isEmpty {
            server["env"] = environment
        }
        let obj: [String: Any] = ["mcpServers": [serverName: server]]
        return try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    /// Write the infinitty MCP entry into Claude's user config. If a
    /// pre-existing file lists other MCP servers, the infinitty entry is
    /// merged alongside them. Always returns the new file contents'
    /// server list (for logging / status reporting).
    @discardableResult
    public static func registerWithClaude(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let binary = mcpExecutablePath(fileManager: fileManager, bundle: bundle) else { return false }
        let url = claudeMCPConfigURL(fileManager: fileManager, environment: environment)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return false
        }

        let existing: Data?
        if fileManager.fileExists(atPath: url.path) {
            guard let contents = try? Data(contentsOf: url) else { return false }
            existing = contents
        } else {
            existing = nil
        }
        guard let data = mergedClaudeMCPJSON(
            existing: existing, binaryPath: binary) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Path to Claude Code's user settings, separate from its MCP registry.
    /// Hook installation merges this file and preserves every existing
    /// provider hook.
    public static func claudeSettingsURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let home = environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/settings.json")
    }

    /// Idempotently add the Channel context hook to Claude's SessionStart and
    /// UserPromptSubmit phases. Existing hooks and matchers remain untouched.
    static func mergedClaudeChannelHookSettings(
        existing: Data?, commandPath: String
    ) -> Data? {
        mergedClaudeChannelHookSettings(
            existing: existing,
            commandPaths: Dictionary(
                uniqueKeysWithValues: channelHookEvents.map { ($0, commandPath) }))
    }

    static func mergedClaudeChannelHookSettings(
        existing: Data?, commandPaths: [String: String]
    ) -> Data? {
        var root: [String: Any] = [:]
        if let existing {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing)
                as? [String: Any]
            else { return nil }
            root = parsed
        }

        var hooks: [String: Any]
        if let existingHooks = root["hooks"] {
            guard let parsedHooks = existingHooks as? [String: Any] else {
                return nil
            }
            hooks = parsedHooks
        } else {
            hooks = [:]
        }

        for event in channelHookEvents {
            guard let commandPath = commandPaths[event] else { return nil }
            let hook: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": commandPath,
                ] as [String: Any]],
            ]
            var entries: [Any]
            if let existingEntries = hooks[event] {
                guard let parsedEntries = existingEntries as? [Any] else {
                    return nil
                }
                entries = parsedEntries
            } else {
                entries = []
            }
            let alreadyInstalled = entries.contains { rawEntry in
                guard let entry = rawEntry as? [String: Any],
                      let nested = entry["hooks"] as? [Any]
                else { return false }
                return nested.contains { rawHook in
                    guard let command = (rawHook as? [String: Any])?["command"] as? String
                    else { return false }
                    return command == commandPath
                }
            }
            if !alreadyInstalled { entries.append(hook) }
            hooks[event] = entries
        }
        root["hooks"] = hooks
        let result = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys])
        return result
    }

    /// Write the provider-neutral Channel hooks into Claude's user settings.
    @discardableResult
    public static func registerClaudeChannelHooks(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let sessionStartPath = claudeChannelHookPath(
                event: "SessionStart", fileManager: fileManager, bundle: bundle),
              let promptSubmitPath = claudeChannelHookPath(
                event: "UserPromptSubmit", fileManager: fileManager, bundle: bundle)
        else { return false }
        let url = claudeSettingsURL(
            fileManager: fileManager, environment: environment)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        } catch {
            return false
        }
        let existing: Data?
        if fileManager.fileExists(atPath: url.path) {
            guard let contents = try? Data(contentsOf: url) else { return false }
            existing = contents
        } else {
            existing = nil
        }
        guard let merged = mergedClaudeChannelHookSettings(
            existing: existing,
            commandPaths: [
                "SessionStart": sessionStartPath,
                "UserPromptSubmit": promptSubmitPath,
            ])
        else { return false }
        do {
            try merged.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func mergedClaudeMCPJSON(
        existing: Data?, binaryPath: String
    ) -> Data? {
        var root: [String: Any] = [:]
        if let existing {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any]
            else { return nil }
            root = parsed
        }
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers[serverName] = ["command": binaryPath]
        root["mcpServers"] = servers
        return try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Best-effort registration for whichever providers the user has
    /// actually installed. Never writes to user config if the matching
    /// CLI is missing — that prevents infinitty from leaving stray MCP
    /// entries behind when someone uninstalls Codex or Claude later.
    public static func registerIfNeeded(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (codex: Bool, claude: Bool) {
        let codexURL = CLIExecutableResolver.resolve(
            .codex, fileManager: fileManager, environment: environment)
        let claudeURL = CLIExecutableResolver.resolve(
            .claude, fileManager: fileManager, environment: environment)
        let claudeRegistered = claudeURL != nil && registerWithClaude(
            fileManager: fileManager, bundle: bundle, environment: environment)
        if claudeURL != nil {
            _ = registerClaudeChannelHooks(
                fileManager: fileManager, bundle: bundle, environment: environment)
        }
        return (
            codex: codexURL != nil && registerWithCodex(
                fileManager: fileManager, bundle: bundle, environment: environment),
            claude: claudeRegistered
        )
    }

    private static func tomlQuoted(_ value: String) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
