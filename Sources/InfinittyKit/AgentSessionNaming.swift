import Foundation

/// Names panes/tabs after the agent session running in them. Two layers:
/// an immediate generated name ("claude · titerm") the moment an agent CLI is
/// detected in the pane, upgraded to the real session title when the agent's
/// session store yields one (Claude Code writes the first prompt of each
/// session to ~/.claude/projects/<cwd-slug>/<session>.jsonl).
enum AgentSessionNaming {
    private static let knownAgents: [(match: String, display: String)] = [
        ("claude", "claude"),
        ("codex", "codex"),
        ("gemini", "gemini"),
        ("qwen", "qwen"),
        ("grok", "grok"),
        ("copilot", "copilot"),
        ("aider", "aider"),
        ("opencode", "opencode"),
        ("cursor", "cursor"),
        ("droid", "droid"),
        ("kimi", "kimi"),
        ("goose", "goose"),
        ("amp", "amp"),
    ]

    /// Display name of a recognized agent CLI from a foreground process name,
    /// or nil when the process is not a known agent. Short names must match a
    /// whole word; longer ones may match as substrings ("cursor-agent").
    static func agentName(forProcessName name: String) -> String? {
        let value = name.lowercased()
        let tokens = Set(
            value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return knownAgents.first {
            tokens.contains($0.match) || ($0.match.count >= 5 && value.contains($0.match))
        }?.display
    }

    /// Immediate name shown until a real session title is known.
    static func fallbackName(agent: String, cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return agent }
        let base = URL(fileURLWithPath: cwd).lastPathComponent
        return base.isEmpty || base == "/" ? agent : "\(agent) · \(base)"
    }

    /// Claude Code's per-project directory slug: every character outside
    /// [A-Za-z0-9] becomes "-" (so "/Users/x/dev.app" → "-Users-x-dev-app").
    static func claudeProjectSlug(forCwd cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// The newest Claude Code session title for `cwd`: scans the project's
    /// transcript directory for the most recent .jsonl modified after
    /// `startedAfter` and extracts its first user prompt. Best-effort, cheap
    /// (reads at most 64 KiB of one file); returns nil when nothing matches.
    static func claudeSessionTitle(
        cwd: String, startedAfter: Date, home: String = NSHomeDirectory()
    ) -> String? {
        let dir = home + "/.claude/projects/" + claudeProjectSlug(forCwd: cwd)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var newest: (path: String, mtime: Date)?
        for name in names where name.hasSuffix(".jsonl") {
            let path = dir + "/" + name
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  mtime > startedAfter else { continue }
            if newest == nil || mtime > newest!.mtime { newest = (path, mtime) }
        }
        guard let newest,
              let handle = FileHandle(forReadingAtPath: newest.path),
              let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        try? handle.close()
        return title(fromTranscriptData: data)
    }

    /// First real user prompt in a Claude Code stream-json transcript,
    /// compacted for a tab label. Skips tool results, command wrappers, and
    /// meta lines (they start with "<" or "Caveat:").
    static func title(fromTranscriptData data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").prefix(60) {
            guard let object = try? JSONSerialization.jsonObject(
                      with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "user",
                  let message = object["message"] as? [String: Any] else { continue }
            var candidate: String?
            if let content = message["content"] as? String {
                candidate = content
            } else if let parts = message["content"] as? [[String: Any]] {
                candidate = parts.compactMap { part in
                    part["type"] as? String == "text" ? part["text"] as? String : nil
                }.first
            }
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<"),
                  !trimmed.hasPrefix("Caveat:") else { continue }
            return compactTitle(trimmed)
        }
        return nil
    }

    /// One tab-label-sized line: first line only, collapsed whitespace,
    /// ellipsized at `limit`.
    static func compactTitle(_ raw: String, limit: Int = 36) -> String {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let collapsed = firstLine
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.index(collapsed.startIndex, offsetBy: limit - 1)
        return String(collapsed[..<cut]).trimmingCharacters(in: .whitespaces) + "…"
    }
}
