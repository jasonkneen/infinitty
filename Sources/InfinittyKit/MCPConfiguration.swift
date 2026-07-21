import Foundation

/// Writes the bundled `infinitty-mcp` server into Codex's and Claude's MCP
/// config files so the CLIs gain terminal-control tools automatically.
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
        binaryPath: String, appSocketPath: String? = nil
    ) -> [String] {
        var overrides = [codexConfigOverride(binaryPath: binaryPath)]
        if let appSocketPath {
            overrides.append(
                "mcp_servers.\(serverName).env.INFINITTY_APP_SOCKET=\(tomlQuoted(appSocketPath))")
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

    static func claudeMCPJSON(binaryPath: String, appSocketPath: String? = nil) -> Data? {
        var server: [String: Any] = ["command": binaryPath]
        if let appSocketPath {
            // Pin the spawned infinitty-mcp to THIS instance's control socket
            // instead of the shared (possibly stale) current.sock symlink.
            server["env"] = ["INFINITTY_APP_SOCKET": appSocketPath]
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
        return (
            codex: codexURL != nil && registerWithCodex(
                fileManager: fileManager, bundle: bundle, environment: environment),
            claude: claudeURL != nil && registerWithClaude(
                fileManager: fileManager, bundle: bundle, environment: environment)
        )
    }

    private static func tomlQuoted(_ value: String) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
