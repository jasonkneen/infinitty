import Foundation

/// One actionable pet-bubble tip mined from the repo the pane is sitting in.
/// `command` (when present) is inserted at the prompt on click.
struct PetTip: Equatable {
    let text: String
    let command: String?
    let source: String
}

/// Mines a project directory for *meaningful* things the pet can suggest:
/// commands documented in AGENTS.md / CLAUDE.md / README, package scripts,
/// Makefile targets, and the project's build system. Pure file reads, bounded
/// sizes — always call from a background queue.
enum PetTipScanner {
    static let markdownSources = [
        "AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", "CONTRIBUTING.md", "README.md",
    ]

    /// Command words we trust enough to surface as a clickable suggestion.
    private static let commandAllowlist: Set<String> = [
        "git", "npm", "pnpm", "yarn", "bun", "npx", "node", "swift", "make",
        "cargo", "go", "pytest", "pip", "uv", "python", "python3", "ruby",
        "bundle", "rake", "just", "docker", "kubectl", "gh", "mvn", "gradle",
        "dotnet", "flutter", "tuist", "xcodebuild", "fastlane", "deno", "zig",
    ]

    private static let maxFileBytes = 128 * 1024

    /// All tips for a directory, best first. Bounded work: a handful of small
    /// file reads, no process spawns, no recursion.
    static func scan(directory: String, fileManager fm: FileManager = .default) -> [PetTip] {
        var tips: [PetTip] = []
        for name in markdownSources {
            guard let text = read(directory + "/" + name, fm: fm) else { continue }
            tips += commands(inMarkdown: text, source: name)
            if tips.count >= 6 { break }
        }
        if let data = readData(directory + "/package.json", fm: fm) {
            tips += packageScriptTips(json: data, runner: packageRunner(directory: directory, fm: fm))
        }
        if let text = read(directory + "/Makefile", fm: fm) {
            tips += makefileTips(text)
        }
        if fm.fileExists(atPath: directory + "/Package.swift") {
            tips.append(PetTip(
                text: "Swift package here", command: "swift test", source: "Package.swift"))
        }
        if fm.fileExists(atPath: directory + "/Cargo.toml") {
            tips.append(PetTip(
                text: "Rust crate here", command: "cargo test", source: "Cargo.toml"))
        }
        if fm.fileExists(atPath: directory + "/go.mod") {
            tips.append(PetTip(
                text: "Go module here", command: "go test ./...", source: "go.mod"))
        }
        var seen = Set<String>()
        return tips.filter { tip in
            guard let command = tip.command else { return true }
            return seen.insert(command).inserted
        }
    }

    /// Shell commands documented in a markdown file's fenced code blocks.
    static func commands(inMarkdown text: String, source: String, limit: Int = 4) -> [PetTip] {
        var tips: [PetTip] = []
        var inFence = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard inFence, tips.count < limit else { continue }
            var candidate = line
            if candidate.hasPrefix("$ ") { candidate = String(candidate.dropFirst(2)) }
            guard isPlausibleCommand(candidate) else { continue }
            tips.append(PetTip(text: candidate, command: candidate, source: source))
        }
        return tips
    }

    /// A single documented line we would dare to type at the user's prompt.
    static func isPlausibleCommand(_ line: String) -> Bool {
        guard line.count >= 3, line.count <= 72,
              !line.hasPrefix("#"), !line.contains("\n") else { return false }
        guard let first = line.split(separator: " ").first else { return false }
        if first.hasPrefix("./") || first.hasPrefix("scripts/") { return true }
        return commandAllowlist.contains(String(first))
    }

    /// npm/pnpm/yarn/bun scripts, dev/test/build first.
    static func packageScriptTips(json: Data, runner: String, limit: Int = 3) -> [PetTip] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any] else { return [] }
        let preferred = ["dev", "test", "build", "start", "lint"]
        let names = scripts.keys.sorted { a, b in
            let ia = preferred.firstIndex(of: a) ?? Int.max
            let ib = preferred.firstIndex(of: b) ?? Int.max
            return ia == ib ? a < b : ia < ib
        }
        return names.prefix(limit).map { name in
            let command = runner == "npm" ? "npm run \(name)" : "\(runner) \(name)"
            return PetTip(text: command, command: command, source: "package.json")
        }
    }

    static func packageRunner(directory: String, fm: FileManager) -> String {
        if fm.fileExists(atPath: directory + "/pnpm-lock.yaml") { return "pnpm" }
        if fm.fileExists(atPath: directory + "/yarn.lock") { return "yarn" }
        if fm.fileExists(atPath: directory + "/bun.lockb")
            || fm.fileExists(atPath: directory + "/bun.lock") { return "bun run" }
        return "npm"
    }

    /// Top Makefile targets as `make <target>` tips.
    static func makefileTips(_ text: String, limit: Int = 3) -> [PetTip] {
        var tips: [PetTip] = []
        for line in text.split(separator: "\n") {
            guard tips.count < limit else { break }
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line.hasPrefix("\t"), !line.hasPrefix(".") else { continue }
            let target = String(line[..<colon])
            guard target.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                  target != "Makefile" else { continue }
            tips.append(PetTip(
                text: "make \(target)", command: "make \(target)", source: "Makefile"))
        }
        return tips
    }

    /// Nearest ancestor containing .git (the repo the pane is "in"), or nil.
    static func repoRoot(
        for directory: String, fileManager fm: FileManager = .default
    ) -> String? {
        var url = URL(fileURLWithPath: directory)
        for _ in 0..<12 {
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }

    // MARK: - helpers

    private static func read(_ path: String, fm: FileManager) -> String? {
        guard let data = readData(path, fm: fm) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func readData(_ path: String, fm: FileManager) -> Data? {
        guard fm.fileExists(atPath: path),
              let handle = FileHandle(forReadingAtPath: path),
              let data = try? handle.read(upToCount: maxFileBytes) else { return nil }
        try? handle.close()
        return data.isEmpty ? nil : data
    }
}
