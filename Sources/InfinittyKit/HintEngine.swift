import Foundation

/// Produces inline command suggestions ("ghost text"). Two sources:
///  - shell history (instant, local, default) — fish-style prefix match
///  - an optional `hint-command` (AI/custom): a program that reads the current
///    input line on stdin and prints a full suggested command on stdout.
///
/// History matching is O(n) over a preloaded cache (never File I/O under the
/// terminal lock). The AI command, when configured, runs async and updates
/// the suggestion when it returns — so typing never blocks on the network.
final class HintEngine {
    /// Async "smart" suggestion source, in priority order at resolution time.
    enum SmartSource {
        case command(String)                    // hint-command (custom script)
        case openai(base: String, key: String, model: String) // OpenAI-compatible
        case foundation                         // Apple on-device (default)
        case none
    }

    private var history: [String] = []          // newest first, deduped
    private var historyLoaded = false
    private let smart: SmartSource
    private let lock = NSLock()

    // Async smart-suggestion cache: last input asked about, and its answer.
    private var aiInput = ""
    private var aiResult: String?
    var onAsyncSuggestion: (() -> Void)?        // poke a redraw when it replies
    var cwdProvider: (() -> String?)?           // optional cwd context
    private let aiQueue = DispatchQueue(label: "infinitty.hint.ai", qos: .utility)
    private var aiInFlight = false
    private let aiSession = URLSession(configuration: .ephemeral)

    #if canImport(FoundationModels)
    private var _fmHinter: Any?
    #endif

    init(smart: SmartSource) {
        self.smart = smart
        #if canImport(FoundationModels)
        if case .foundation = smart, #available(macOS 26.0, *) {
            _fmHinter = FoundationModelHinter()
        }
        #endif
        // Preload histfile off the PTY path so the first keystroke never
        // stalls the terminal lock on FileManager + 5k-line parse.
        preloadHistory()
    }

    /// Kick (or re-kick) async history load. Safe to call repeatedly.
    func preloadHistory() {
        aiQueue.async { [weak self] in self?.loadHistory() }
    }

    /// Resolve the configured smart source (Foundation Models when available).
    static func resolveSmart(
        hints: Bool, hintCommand: String?,
        aiBaseURL: String?, aiKey: String?, aiModel: String?
    ) -> SmartSource {
        guard hints else { return .none }
        if let cmd = hintCommand, !cmd.isEmpty { return .command(cmd) }
        if let base = aiBaseURL, !base.isEmpty {
            return .openai(base: base, key: aiKey ?? "", model: aiModel ?? "gpt-4o-mini")
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), FoundationModelHinter.isAvailable { return .foundation }
        #endif
        return .none
    }

    // MARK: history

    /// Runs only on `aiQueue`. Never called under the terminal lock.
    private func loadHistory() {
        lock.lock()
        let already = historyLoaded
        lock.unlock()
        if already { return }

        let env = ProcessInfo.processInfo.environment
        let path = env["HISTFILE"]
            ?? NSString(string: "~/.zsh_history").expandingTildeInPath
        var result: [String] = []
        if let data = FileManager.default.contents(atPath: path),
           let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) {
            var seen = Set<String>()
            // Walk newest→oldest so the first match is the most recent.
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                var cmd = String(line)
                // zsh extended history: ": <ts>:<elapsed>;<command>"
                if cmd.hasPrefix(":"), let semi = cmd.firstIndex(of: ";") {
                    cmd = String(cmd[cmd.index(after: semi)...])
                }
                cmd = cmd.trimmingCharacters(in: .whitespaces)
                guard !cmd.isEmpty, !seen.contains(cmd) else { continue }
                seen.insert(cmd)
                result.append(cmd)
                if result.count > 5000 { break }
            }
        }
        lock.lock()
        history = result
        historyLoaded = true
        lock.unlock()
    }

    /// Synchronous suggestion for `input`: the full command it likely becomes.
    /// Layered: configured AI command (if cached) → shell history → built-in
    /// CLI specs. Returns nil if nothing matches.
    ///
    /// Must stay fast: called under the terminal lock from `feed`. Never does
    /// File I/O — history is preloaded on `aiQueue`; until it lands, only the
    /// AI cache + built-in CLI specs apply.
    func suggest(_ input: String) -> String? {
        // Kick off an async smart query; prefer its cached answer when it
        // matches the current input.
        if case .none = smart {} else { requestSmart(input) }
        lock.lock()
        let cachedAI = (aiInput == input) ? aiResult : nil
        let hist = history
        lock.unlock()
        if let ai = cachedAI, ai.hasPrefix(input), ai.count > input.count {
            return ai
        }

        // Personalized: most recent matching history entry.
        for cmd in hist where cmd.hasPrefix(input) && cmd.count > input.count {
            return cmd
        }

        // Generic: known CLI subcommands (git, docker, npm, …).
        return HintEngine.cliSuggestion(input)
    }

    // MARK: built-in CLI specs

    /// subcommands keyed by top-level tool. Suggests the first that extends
    /// the partially-typed subcommand.
    private static let cliSpecs: [String: [String]] = [
        "git": ["status", "commit", "commit -m", "checkout", "checkout -b", "branch",
                "pull", "push", "push -u origin", "clone", "add", "add .", "log --oneline",
                "diff", "stash", "stash pop", "rebase", "merge", "fetch", "reset --hard",
                "remote -v", "restore", "switch", "tag"],
        "docker": ["ps", "ps -a", "images", "run", "run -it", "build", "build -t",
                   "exec -it", "logs", "logs -f", "compose up", "compose up -d",
                   "compose down", "pull", "push", "stop", "rm", "rmi", "system prune"],
        "npm": ["install", "install -g", "run", "run dev", "run build", "run test",
                "start", "test", "publish", "publish --access public", "init", "update",
                "outdated", "audit", "audit fix", "version", "link", "ci"],
        "pnpm": ["install", "add", "add -D", "run", "run dev", "run build", "dlx", "update"],
        "yarn": ["install", "add", "add -D", "run", "build", "dev", "test", "upgrade"],
        "brew": ["install", "uninstall", "update", "upgrade", "list", "search",
                 "info", "doctor", "cleanup", "services list", "services restart"],
        "kubectl": ["get pods", "get svc", "get nodes", "get deployments", "describe",
                    "logs", "logs -f", "apply -f", "delete", "exec -it", "port-forward",
                    "rollout status", "config get-contexts"],
        "cargo": ["build", "build --release", "run", "test", "check", "add", "update",
                  "clippy", "fmt", "publish", "new", "init"],
        "swift": ["build", "build -c release", "run", "test", "package", "package init"],
        "gh": ["pr create", "pr list", "pr view", "pr checkout", "repo clone",
               "repo view", "release create", "release list", "issue list", "run watch"],
        "go": ["build", "run", "test", "get", "mod tidy", "mod init", "install", "fmt", "vet"],
        "make": ["build", "test", "clean", "install", "all", "run"],
        "systemctl": ["status", "start", "stop", "restart", "enable", "disable", "reload"],
        "tmux": ["new -s", "attach -t", "ls", "kill-session -t", "kill-server"],
    ]

    private static func cliSuggestion(_ input: String) -> String? {
        let parts = input.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let subs = cliSpecs[String(parts[0])] else { return nil }
        let partial = String(parts[1])
        guard !partial.isEmpty else { return nil }
        for sub in subs where sub.hasPrefix(partial) && sub.count > partial.count {
            return "\(parts[0]) \(sub)"
        }
        return nil
    }

    // MARK: async smart source (command / OpenAI / Foundation Models)

    private func requestSmart(_ input: String) {
        lock.lock()
        let already = aiInFlight || aiInput == input
        if !already { aiInFlight = true; aiInput = input; aiResult = nil }
        lock.unlock()
        guard !already else { return }
        let cwd = cwdProvider?()

        func finish(_ result: String?) {
            self.lock.lock()
            self.aiInFlight = false
            if self.aiInput == input { self.aiResult = result }
            self.lock.unlock()
            if result != nil { DispatchQueue.main.async { self.onAsyncSuggestion?() } }
        }

        switch smart {
        case .command(let cmd):
            aiQueue.async { finish(HintEngine.runHintCommand(cmd, input: input)) }
        case .openai(let base, let key, let model):
            requestOpenAI(input: input, cwd: cwd, base: base, key: key, model: model, done: finish)
        case .foundation:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), let fm = _fmHinter as? FoundationModelHinter {
                Task.detached {
                    let r = await fm.complete(input, cwd: cwd)
                    finish(r)
                }
            } else { finish(nil) }
            #else
            finish(nil)
            #endif
        case .none:
            finish(nil)
        }
    }

    private func requestOpenAI(
        input: String, cwd: String?, base: String, key: String, model: String,
        done: @escaping (String?) -> Void
    ) {
        let urlStr = base.hasSuffix("/chat/completions") ? base
            : base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
        guard let url = URL(string: urlStr) else { done(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let sys = "You autocomplete shell commands. Reply with ONLY the full command line "
            + "the user most likely intends, including their typed text as a prefix. One line, no markdown."
        let user = cwd.map { "cwd: \($0)\npartial: \(input)" } ?? "partial: \(input)"
        let payload: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": sys], ["role": "user", "content": user]],
            "temperature": 0.15,
            "max_tokens": 40,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        aiSession.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else { done(nil); return }
            var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            if let nl = text.firstIndex(of: "\n") { text = String(text[..<nl]) }
            done(text.isEmpty ? nil : text)
        }.resume()
    }

    private static func runHintCommand(_ command: String, input: String) -> String? {
        let parts = command.split(separator: " ").map(String.init)
        guard let exe = parts.first else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [exe] + parts.dropFirst()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        proc.environment = env
        let stdin = Pipe(), stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        stdin.fileHandleForWriting.closeFile()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let out = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }
}
