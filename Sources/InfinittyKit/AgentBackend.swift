import Foundation

/// A locally-installed coding-agent CLI the pet assistant can drive as a chat
/// backend. Detection is pure (inject `env`/`fileExists`) so it is testable
/// without depending on what's installed on the build machine.
struct DetectedAgent: Equatable {
    enum Kind: String, Equatable {
        case codex
        case claude
    }

    let kind: Kind
    let path: String

    /// Picker label shown in the composer MODEL row.
    var label: String {
        switch kind {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}

/// Probes for `codex` / `claude` on PATH (plus a few well-known install
/// locations the login shell would resolve). Pure and injectable.
enum AgentDetector {
    /// Well-known absolute locations that a login shell resolves but a
    /// GUI-launched app's `PATH` often misses.
    static let knownPaths: [DetectedAgent.Kind: [String]] = [
        .claude: [
            "~/.local/bin/claude", "~/.claude/local/claude",
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.bun/bin/claude"
        ],
        .codex: [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.bun/bin/codex",
            "~/.codex/bin/codex"
        ],
    ]

    /// Detect installed agents. `env` supplies `PATH`; `fileExists` probes the
    /// filesystem (both injected for tests). Ordering is stable: codex, claude.
    static func detect(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [DetectedAgent] {
        let pathDirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var found: [DetectedAgent] = []
        for kind in [DetectedAgent.Kind.codex, .claude] {
            if let path = resolve(kind, pathDirs: pathDirs, fileExists: fileExists) {
                found.append(DetectedAgent(kind: kind, path: path))
            }
        }
        return found
    }

    private static func resolve(
        _ kind: DetectedAgent.Kind, pathDirs: [String],
        fileExists: (String) -> Bool
    ) -> String? {
        let name = kind.rawValue
        for dir in pathDirs {
            let candidate = dir + "/" + name
            if fileExists(candidate) { return candidate }
        }
        for candidate in knownPaths[kind] ?? [] {
            let expanded = NSString(string: candidate).expandingTildeInPath
            if fileExists(expanded) { return expanded }
        }
        return nil
    }

    /// Non-interactive argv for a one-shot prompt. Prompt is delivered on
    /// stdin (empty argv prompt), so no shell escaping/arg-length limits.
    static func args(for kind: DetectedAgent.Kind, model: String?) -> [String] {
        switch kind {
        case .claude:
            // `claude -p` reads the prompt from stdin, prints the reply, exits.
            var argv = ["-p", "--output-format", "text"]
            if let model, !model.isEmpty { argv += ["--model", model] }
            return argv
        case .codex:
            // `codex exec` with no PROMPT arg reads instructions from stdin.
            var argv = ["exec", "--skip-git-repo-check"]
            if let model, !model.isEmpty { argv += ["-m", model] }
            return argv
        }
    }
}
