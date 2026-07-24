import AppKit
import ApplicationServices

// Session discovery and notch UI include MIT-licensed upstream work.
// Copyright (c) 2026 realfishsam; see THIRD_PARTY_NOTICES.md.

// MARK: - Model

enum AgentKind: String { case claude = "Claude Code", codex = "Codex" }

struct AgentSession {
    let id: String
    let kind: AgentKind
    let title: String
    let snippet: String
    let model: String
    let lastModified: Date
    var prompt: String = ""
    var threadID: String = ""
    var workingDirectory: String?
    var processID: pid_t?
    var parentID: String?
    var nickname: String?
    var children: [AgentSession] = []
    var isLive: Bool = false  // process alive (from discovery, never mtime)
    // last user/assistant entry — housekeeping writes (away_summary etc.)
    // bump the file mtime but must not count as activity
    var lastActivity: Date?
    // hybrid: busy = alive AND conversing; quiet-while-alive is idle, not done
    var isBusy: Bool { isLive && Date().timeIntervalSince(lastActivity ?? lastModified) < 30 }
    var anyLive: Bool { isLive || children.contains { $0.isLive } }
    var anyBusy: Bool { isBusy || children.contains { $0.isBusy } }
    var effectiveLastModified: Date { children.reduce(lastModified) { max($0, $1.lastModified) } }

    func resumeCommand(executablePath: String? = nil) -> String? {
        guard UUID(uuidString: threadID) != nil else { return nil }
        let executable: String
        switch kind {
        case .claude:
            executable = executablePath ?? "claude"
            return "\(Self.shellQuote(executable)) --resume \(Self.shellQuote(threadID))"
        case .codex:
            executable = executablePath ?? "codex"
            return "\(Self.shellQuote(executable)) resume \(Self.shellQuote(threadID))"
        }
    }

    var recoveryContext: String {
        let location = workingDirectory.map { "\nWorking directory: \($0)" } ?? ""
        let lastPrompt = prompt.isEmpty ? "(not available)" : prompt
        let lastReply = snippet.isEmpty ? "(not available)" : snippet
        return """
        Recovered \(kind.rawValue) session
        Session ID: \(threadID.isEmpty ? id : threadID)
        Model: \(model.isEmpty ? "unknown" : model)\(location)
        Last user message: \(lastPrompt)
        Last reply: \(lastReply)
        Transcript: \(id)
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Process discovery
// Ported from open-vibe-island's ActiveAgentProcessDiscovery: "a session IS a
// running agent process in a terminal." `ps` finds agent processes (a TTY is
// required, which excludes headless/background sessions), `lsof` maps each
// process to the transcript file it holds open. Liveness comes from the OS,
// never from transcript mtimes.

final class ProcessDiscovery {
    // Claude Code appends-and-closes its transcript, so lsof usually shows no
    // open jsonl for it — open-vibe-island falls back to the process cwd (and
    // claims by tty so a terminal maps to one session). Codex holds its
    // rollout file open, so the path route always works there.
    struct Snapshot {
        let kind: AgentKind
        let processID: pid_t
        let transcriptPath: String?
        let cwd: String?
    }

    // open-vibe-island uses 0.5s/0.2s here, but Process-spawn overhead under
    // heavy load (a codex swarm compiling) blows through 0.2s and every agent
    // reads as dead — so: generous budgets, and ONE batched lsof per poll.
    private static let psTimeout: TimeInterval = 2.0
    private static let lsofTimeout: TimeInterval = 2.0

    func liveTranscripts() -> [Snapshot] {
        guard let psOut = run("/bin/ps", ["-Ao", "pid=,ppid=,tty=,command="], timeout: Self.psTimeout) else { return [] }
        var candidates: [(pid: String, tty: String, kind: AgentKind)] = []
        for line in psOut.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard parts.count == 4 else { continue }
            let pid = String(parts[0]), tty = String(parts[2])
            let command = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard tty != "??", !command.isEmpty else { continue }  // agent must be terminal-attached
            if isClaude(command) { candidates.append((pid, tty, .claude)) }
            else if isCodex(command) { candidates.append((pid, tty, .codex)) }
        }
        let chunks = lsofChunks(pids: candidates.map(\.pid))
        var out: [Snapshot] = []
        var claimed = Set<String>()
        for (pid, tty, kind) in candidates {
            guard let lsof = chunks[pid] else { continue }
            let cwd = workingDirectory(from: lsof)
            // Claude subagents run in .claude/worktrees/agent-*/ — they are
            // metadata on the parent session, not sessions of their own.
            if kind == .claude, let cwd, cwd.contains("/.claude/worktrees/agent-") { continue }
            switch kind {
            case .claude:
                let path = bestClaudeTranscript(in: lsof, cwd: cwd)
                guard path != nil || cwd != nil else { continue }
                // claim key: sessionID ?? tty ?? cwd — one session per terminal
                guard claimed.insert("claude:\(path ?? tty)").inserted else { continue }
                out.append(Snapshot(
                    kind: kind, processID: pid_t(pid) ?? 0,
                    transcriptPath: path, cwd: cwd))
            case .codex:
                guard let path = bestCodexTranscript(in: lsof),
                      claimed.insert("codex:\(path)").inserted else { continue }
                out.append(Snapshot(
                    kind: kind, processID: pid_t(pid) ?? 0,
                    transcriptPath: path, cwd: cwd))
            }
        }
        return out
    }

    /// One lsof for all pids; -Fn output is split per-pid on its `p<pid>` markers.
    private func lsofChunks(pids: [String]) -> [String: String] {
        guard !pids.isEmpty,
              let outText = run("/usr/sbin/lsof", ["-a", "-p", pids.joined(separator: ","), "-Fn"], timeout: Self.lsofTimeout) else { return [:] }
        var chunks: [String: String] = [:]
        var curPid: String?
        var cur = ""
        for line in outText.split(whereSeparator: \.isNewline) {
            if line.first == "p" {
                if let p = curPid { chunks[p] = cur }
                curPid = String(line.dropFirst())
                cur = ""
            } else {
                cur += line + "\n"
            }
        }
        if let p = curPid { chunks[p] = cur }
        return chunks
    }

    private func isClaude(_ command: String) -> Bool {
        let lowered = command.lowercased()
        if lowered.contains("/.local/bin/claude") { return true }
        guard let first = lowered.split(separator: " ").first.map(String.init) else { return false }
        return first == "claude" || first.hasSuffix("/claude")
    }

    private func isCodex(_ command: String) -> Bool {
        let lowered = command.lowercased()
        guard let first = lowered.split(separator: " ").first.map(String.init) else { return false }
        return first == "codex" || first.hasSuffix("/codex") || lowered.contains("/codex/codex")
    }

    private func workingDirectory(from lsof: String) -> String? {
        let lines = lsof.split(whereSeparator: \.isNewline).map(String.init)
        for i in lines.indices where lines[i] == "fcwd" && lines.indices.contains(i + 1) {
            let next = lines[i + 1]
            guard next.first == "n" else { continue }
            let v = String(next.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            if v.hasPrefix("/") { return v }
        }
        return nil
    }

    private func paths(in lsof: String, containing fragment: String) -> [String] {
        lsof.split(whereSeparator: \.isNewline).compactMap {
            guard $0.first == "n" else { return nil }
            let v = String($0.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return v.contains(fragment) && v.hasSuffix(".jsonl") ? v : nil
        }
    }

    private func bestClaudeTranscript(in lsof: String, cwd: String?) -> String? {
        let all = paths(in: lsof, containing: "/.claude/projects/")
        // a claude process can hold several project transcripts open; prefer
        // the one whose encoded project dir matches the process cwd
        if all.count > 1, let cwd {
            let encoded = cwd.replacingOccurrences(of: "/", with: "-")
            if let preferred = all.first(where: { $0.contains(encoded) }) { return preferred }
        }
        return all.first
    }

    private func bestCodexTranscript(in lsof: String) -> String? {
        // rollout filenames embed a timestamp, so the max name is the newest
        paths(in: lsof, containing: "/.codex/sessions/").max {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                < URL(fileURLWithPath: $1).deletingPathExtension().lastPathComponent
        }
    }

    private func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            group.leave()
        }
        guard group.wait(timeout: .now() + timeout) == .success else { p.terminate(); return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Session scanning

final class SessionScanner {
    private let fm = FileManager.default
    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// `live` = transcript paths held open by a running agent process;
    /// `claudeCwdCounts` = encoded-project-dir → number of claude processes
    /// with that cwd (the fallback when claude exposes no open transcript).
    /// Together they are the sole source of truth for isRunning.
    func scan(live: Set<String>, claudeCwdCounts: [String: Int]) -> [AgentSession] {
        let recent: (AgentSession) -> Bool = { $0.isLive || Date().timeIntervalSince($0.lastModified) < 6 * 3600 }
        var sessions = scanClaude(
            live: live, cwdCounts: claudeCwdCounts,
            liveByPath: [:], cwdProcesses: [:]).filter(recent)
            + groupCodex(scanCodex(live: live, liveByPath: [:]).filter(recent))
        sessions.sort { $0.effectiveLastModified > $1.effectiveLastModified }
        return sessions
    }

    func scan(liveProcesses: [ProcessDiscovery.Snapshot]) -> [AgentSession] {
        var liveByPath: [String: ProcessDiscovery.Snapshot] = [:]
        var cwdProcesses: [String: [ProcessDiscovery.Snapshot]] = [:]
        for process in liveProcesses {
            if let path = process.transcriptPath {
                liveByPath[path] = process
            } else if process.kind == .claude, let cwd = process.cwd {
                let encoded = cwd.replacingOccurrences(of: "/", with: "-")
                cwdProcesses[encoded, default: []].append(process)
            }
        }
        let counts = cwdProcesses.mapValues(\.count)
        let recent: (AgentSession) -> Bool = {
            $0.isLive || Date().timeIntervalSince($0.lastModified) < 6 * 3600
        }
        var sessions = scanClaude(
            live: Set(liveByPath.keys), cwdCounts: counts,
            liveByPath: liveByPath, cwdProcesses: cwdProcesses).filter(recent)
            + groupCodex(scanCodex(
                live: Set(liveByPath.keys), liveByPath: liveByPath).filter(recent))
        sessions.sort { $0.effectiveLastModified > $1.effectiveLastModified }
        return sessions
    }

    /// Fold Codex subagent rollouts under their root thread as children.
    private func groupCodex(_ nodes: [AgentSession]) -> [AgentSession] {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.threadID, $0) })
        func rootKey(_ n: AgentSession) -> String {
            var cur = n, hops = 0
            while let p = cur.parentID, hops < 10 {
                guard let parent = byID[p] else { return p }  // parent aged out: group under its id anyway
                cur = parent; hops += 1
            }
            return cur.threadID
        }
        var groups: [String: [AgentSession]] = [:]
        for n in nodes { groups[rootKey(n), default: []].append(n) }
        var out: [AgentSession] = []
        for (key, members) in groups {
            var parent = byID[key] ?? members.sorted { $0.lastModified > $1.lastModified }[0]
            var kids = members.filter { $0.threadID != parent.threadID }
            kids.sort { $0.lastModified > $1.lastModified }
            // One codex process serves the whole thread group but holds only
            // its most recently opened rollout fd — so liveness observed on
            // any member means the shared process is alive for all of them.
            if parent.isLive || kids.contains(where: { $0.isLive }) {
                let sharedProcessID = parent.processID
                    ?? kids.first(where: { $0.processID != nil })?.processID
                let sharedDirectory = parent.workingDirectory
                    ?? kids.first(where: { $0.workingDirectory != nil })?.workingDirectory
                parent.isLive = true
                parent.processID = sharedProcessID
                parent.workingDirectory = sharedDirectory
                for i in kids.indices {
                    kids[i].isLive = true
                    kids[i].processID = sharedProcessID
                    kids[i].workingDirectory = sharedDirectory
                }
            }
            parent.children = kids
            out.append(parent)
        }
        return out
    }

    private func scanClaude(
        live: Set<String>, cwdCounts: [String: Int],
        liveByPath: [String: ProcessDiscovery.Snapshot],
        cwdProcesses: [String: [ProcessDiscovery.Snapshot]]
    ) -> [AgentSession] {
        var out: [AgentSession] = []
        let root = home.appendingPathComponent(".claude/projects")
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return out }
        for proj in projects {
            guard let files = try? fm.contentsOfDirectory(at: proj, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            var dated: [(URL, Date)] = files.compactMap { f in
                guard f.pathExtension == "jsonl",
                      let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
                return (f, m)
            }
            dated.sort { $0.1 > $1.1 }
            // cwd fallback: N claude processes in this project dir make its N
            // newest transcripts live (claude keeps no transcript fd open)
            let liveByCwd = cwdCounts[proj.lastPathComponent] ?? 0
            for (idx, (f, mtime)) in dated.enumerated() {
                // Skip stale transcripts before any file I/O — the recency
                // filter in scan() would drop them anyway, and reading all of
                // ~/.claude/projects (easily thousands of files) every pass
                // is what ballooned the scan.
                let isLive = live.contains(f.path) || idx < liveByCwd
                if !isLive, Date().timeIntervalSince(mtime) > 6 * 3600 { continue }
                autoreleasepool {
                    let projName = proj.lastPathComponent.split(separator: "-").last.map(String.init) ?? proj.lastPathComponent
                    let info = tailInfo(of: f)
                    let context = claudeContext(of: f)
                    var sess = AgentSession(id: f.path, kind: .claude, title: projName,
                                            snippet: info.snippet, model: info.model, lastModified: mtime)
                    sess.prompt = info.prompt
                    sess.lastActivity = info.activity
                    sess.isLive = isLive
                    sess.threadID = context.sessionID
                        ?? f.deletingPathExtension().lastPathComponent
                    let cwdCandidates = cwdProcesses[proj.lastPathComponent] ?? []
                    // Claude normally closes its transcript. A single process in
                    // the cwd can be paired safely; two processes in the same cwd
                    // cannot be assigned to two transcript files from ordering
                    // alone, so keep them live but deliberately ownership-unknown.
                    let cwdProcess = cwdCandidates.count == 1 && idx == 0
                        ? cwdCandidates[0] : nil
                    let process = liveByPath[f.path] ?? cwdProcess
                    sess.processID = process?.processID
                    sess.workingDirectory = process?.cwd ?? context.cwd
                    sess.children = claudeSubagents(sessionFile: f, parentLive: sess.isLive)
                    for i in sess.children.indices {
                        sess.children[i].processID = sess.processID
                        sess.children[i].workingDirectory = sess.workingDirectory
                    }
                    out.append(sess)
                }
            }
        }
        return out
    }

    private func scanCodex(
        live: Set<String>, liveByPath: [String: ProcessDiscovery.Snapshot]
    ) -> [AgentSession] {
        var out: [AgentSession] = []
        let root = home.appendingPathComponent(".codex/sessions")
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return out }
        for case let f as URL in en where f.pathExtension == "jsonl" {
            guard let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            // Skip old files early to avoid reading them
            if Date().timeIntervalSince(mtime) > 6 * 3600 { continue }
            autoreleasepool {
                let meta = codexMeta(of: f)
                let info = tailInfo(of: f)
                var sess = AgentSession(id: f.path, kind: .codex, title: meta.title,
                                        snippet: info.snippet, model: info.model, lastModified: mtime)
                sess.prompt = info.prompt
                sess.lastActivity = info.activity
                sess.isLive = live.contains(f.path)
                sess.threadID = meta.id
                sess.parentID = meta.parentID
                sess.nickname = meta.nickname
                sess.workingDirectory = liveByPath[f.path]?.cwd ?? meta.cwd
                sess.processID = liveByPath[f.path]?.processID
                out.append(sess)
            }
        }
        return out
    }

    /// Claude Code subagent transcripts live in <proj>/<session-uuid>/subagents/agent-*.jsonl
    private func claudeSubagents(sessionFile f: URL, parentLive: Bool) -> [AgentSession] {
        let dir = f.deletingPathExtension().appendingPathComponent("subagents")
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var kids: [AgentSession] = []
        for c in files where c.pathExtension == "jsonl" {
            guard let mtime = (try? c.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  Date().timeIntervalSince(mtime) < 6 * 3600 else { continue }
            autoreleasepool {
                let info = tailInfo(of: c)
                var kid = AgentSession(id: c.path, kind: .claude, title: "subagent",
                                       snippet: info.snippet, model: info.model, lastModified: mtime)
                // no nicknames here — label with the task it was given
                kid.nickname = info.prompt.isEmpty ? "subagent" : String(info.prompt.prefix(40))
                // subagents share the parent process (open-vibe-island tracks them
                // as parent metadata) — liveness inherits, busyness from writes
                kid.isLive = parentLive
                kid.lastActivity = info.activity
                kids.append(kid)
            }
        }
        return kids.sorted { $0.lastModified > $1.lastModified }
    }

    private func codexMeta(
        of file: URL
    ) -> (title: String, id: String, parentID: String?, nickname: String?, cwd: String?) {
        guard let fh = try? FileHandle(forReadingFrom: file) else {
            return ("Codex", file.path, nil, nil, nil)
        }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 262_144)
        guard let line = String(data: head, encoding: .utf8)?.split(separator: "\n").first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else {
            return ("Codex", file.path, nil, nil, nil)
        }
        let cwd = payload["cwd"] as? String
        let title = cwd.map { ($0 as NSString).lastPathComponent } ?? "Codex"
        let id = (payload["id"] as? String) ?? file.path
        let parentID = payload["parent_thread_id"] as? String
        let nickname = (((payload["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any])?["agent_nickname"] as? String
        return (title, id, parentID, nickname, cwd)
    }

    private func claudeContext(of file: URL) -> (sessionID: String?, cwd: String?) {
        guard let fh = try? FileHandle(forReadingFrom: file) else { return (nil, nil) }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 262_144)
        guard let text = String(data: head, encoding: .utf8) else { return (nil, nil) }
        var sessionID: String?
        var cwd: String?
        for line in text.split(separator: "\n").prefix(80) {
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any] else { continue }
            sessionID = sessionID
                ?? object["sessionId"] as? String
                ?? object["session_id"] as? String
            cwd = cwd ?? object["cwd"] as? String
            if sessionID != nil, cwd != nil { break }
        }
        return (sessionID, cwd)
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Read the tail of a jsonl transcript: last human-readable text + model
    /// name + timestamp of the last conversational (user/assistant) entry.
    private func tailInfo(of file: URL) -> (snippet: String, model: String, prompt: String, activity: Date?) {
        guard let fh = try? FileHandle(forReadingFrom: file) else { return ("", "", "", nil) }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let readLen: UInt64 = min(size, 131_072)
        try? fh.seek(toOffset: size - readLen)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return ("", "", "", nil) }
        var snippet = "", model = "", prompt = ""
        var activity: Date?
        for line in text.split(separator: "\n").reversed() {
            if model.isEmpty, let r = line.range(of: #""model":"([^"]+)""#, options: .regularExpression) {
                model = String(line[r].dropFirst(9).dropLast(1))
                model = model.replacingOccurrences(of: "claude-", with: "")
            }
            if snippet.isEmpty || prompt.isEmpty || activity == nil,
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                if snippet.isEmpty, let s = extractText(obj) { snippet = s }
                if prompt.isEmpty, let p = extractUserPrompt(obj) { prompt = p }
                // "system" entries (away_summary, compaction notes…) are
                // housekeeping, not activity
                let topLevelType = obj["type"] as? String
                let payloadType = (obj["payload"] as? [String: Any])?["type"] as? String
                let conversational = topLevelType == "user" || topLevelType == "assistant"
                    || payloadType == "user_message" || payloadType == "agent_message"
                    || payloadType == "message"
                if activity == nil, conversational,
                   let ts = obj["timestamp"] as? String {
                    activity = Self.isoParser.date(from: ts)
                }
            }
            if !snippet.isEmpty && !model.isEmpty && !prompt.isEmpty && activity != nil { break }
        }
        if model.isEmpty, size > readLen {
            // model can appear only early in long transcripts — check the head too
            try? fh.seek(toOffset: 0)
            if let head = try? fh.read(upToCount: 65_536),
               let headText = String(data: head, encoding: .utf8),
               let r = headText.range(of: #""model":"([^"]+)""#, options: .regularExpression) {
                model = String(headText[r].dropFirst(9).dropLast(1))
                    .replacingOccurrences(of: "claude-", with: "")
            }
        }
        return (snippet, model, prompt, activity)
    }

    /// The user's own message, if this line is one.
    private func extractUserPrompt(_ obj: [String: Any]) -> String? {
        // Codex: {"payload":{"type":"user_message","message":"..."}}
        if let payload = obj["payload"] as? [String: Any],
           payload["type"] as? String == "user_message",
           let m = payload["message"] as? String { return clean(m) }
        // Claude: {"type":"user","message":{"content":"..." | [{"type":"text","text":...}]}}
        if obj["type"] as? String == "user", let msg = obj["message"] as? [String: Any] {
            if let c = msg["content"] as? String { return clean(c) }
            if let arr = msg["content"] as? [[String: Any]] {
                for part in arr where part["type"] as? String == "text" {
                    if let t = part["text"] as? String { return clean(t) }
                }
            }
        }
        return nil
    }

    private func extractText(_ obj: [String: Any]) -> String? {
        // Claude: {"message": {"content": [{"type":"text","text":...}] | "..."}}
        var content: Any? = nil
        if let msg = obj["message"] as? [String: Any] { content = msg["content"] }
        // Codex: {"payload": {"content": [...]}} or nested message
        if content == nil, let payload = obj["payload"] as? [String: Any] {
            content = payload["content"] ?? (payload["message"] as? [String: Any])?["content"]
        }
        if let s = content as? String { return clean(s) }
        if let arr = content as? [[String: Any]] {
            for part in arr.reversed() {
                if let t = part["text"] as? String { return clean(t) }
            }
        }
        return nil
    }

    private func clean(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("{") { return nil }  // skip system-reminder / tool json
        t = t.replacingOccurrences(of: "\n", with: " ")
        if t.count > 90 { t = String(t.prefix(90)) + "…" }
        return t
    }
}

// MARK: - Dither theme views

struct NotchAppearance {
    var fontName: String?
    var fontStyle: String?
    var fontSize: CGFloat = 13
    var pet: String?

    func font(size: CGFloat, bold: Bool) -> NSFont {
        let scale = min(max(fontSize / 13, 0.85), 1.25)
        let pointSize = size * scale
        if let fontName,
           let configured = GlyphAtlas.resolveFace(
               family: fontName, style: fontStyle, size: pointSize) {
            guard bold else { return configured }
            return NSFontManager.shared.convert(
                configured, toHaveTrait: .boldFontMask)
        }
        return NSFont.monospacedSystemFont(
            ofSize: pointSize, weight: bold ? .semibold : .regular)
    }
}

enum SessionOpenMode { case automatic, resume, chat }

/// Row icon: mini mascot / Codex pet while running, green pixel checkmark when done.
final class DitherIconView: NSView {
    var running = false
    var idle = false  // alive but quiet: dim, static
    var kind: AgentKind = .claude
    var color: NSColor = .systemBlue  // kept for tint fallbacks
    var t: CGFloat = 0 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 16) }

    static let checkmark: [(Int, Int)] = [
        (6, 1), (5, 2), (4, 3), (0, 3), (1, 4), (3, 4), (2, 5)
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if !running && !idle {
            // done: green pixel checkmark
            let cell: CGFloat = 2.2
            for (x, y) in Self.checkmark {
                ctx.setFillColor(NSColor.systemGreen.cgColor)
                ctx.fill(CGRect(x: 1 + CGFloat(x) * cell, y: 1 + CGFloat(7 - y) * cell,
                                width: cell - 0.4, height: cell - 0.4))
            }
            return
        }
        let alpha: CGFloat = idle ? 0.4 : 1.0
        if kind == .codex, let sprite = IndicatorView.codexSprite {
            let fw: CGFloat = 192, fh: CGFloat = 208
            let idx = idle ? 0 : Int(t / 0.12) % 8
            let src = NSRect(x: CGFloat(idx) * fw, y: 1872 - 2 * fh, width: fw, height: fh)
            NSGraphicsContext.current?.imageInterpolation = .none
            sprite.draw(in: NSRect(x: 1, y: 0, width: 16 * fw / fh, height: 16),
                        from: src, operation: .sourceOver, fraction: alpha)
            return
        }
        // mini Claude mascot walking, with a visible bob (static + dim when idle)
        let subW: CGFloat = 1.0, subH: CGFloat = 2.0
        let walk = idle ? 0 : Int(t * 2.5)
        let frame = IndicatorView.mascotFrames[walk % 2]
        let rows = frame.count * 2
        let y0 = CGFloat(rows) * subH + 1 + (walk % 2 == 0 ? 0 : 1.5)
        for (j, line) in frame.enumerated() {
            for (i, ch) in line.enumerated() {
                guard let q = IndicatorView.quadrants[ch] else { continue }
                let cells = [(q.0, 0, 0), (q.1, 1, 0), (q.2, 0, 1), (q.3, 1, 1)]
                for (on, qx, qy) in cells where on {
                    ctx.setFillColor(IndicatorView.claudeOrange.withAlphaComponent(alpha).cgColor)
                    ctx.fill(CGRect(x: CGFloat(i * 2 + qx) * subW,
                                    y: y0 - CGFloat(j * 2 + qy + 1) * subH,
                                    width: subW - 0.2, height: subH - 0.3))
                }
            }
        }
    }
}

/// A sparse row of gray pixels — the dithered stand-in for a separator line.
final class DitherSeparator: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 4) }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cell: CGFloat = 2
        var x: CGFloat = 0
        var seed: UInt64 = 0x9E3779B9
        while x < bounds.width {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let r = CGFloat(seed >> 33 & 0xFFFF) / 65535
            if r > 0.55 {
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.06 + 0.10 * r).cgColor)
                ctx.fill(CGRect(x: x, y: 1, width: cell - 0.4, height: cell - 0.4))
            }
            x += cell
        }
    }
}

// MARK: - Session list popover

final class SessionListController: NSViewController {
    var sessions: [AgentSession] = [] { didSet { rebuild() } }
    var notchAppearance = NotchAppearance() { didSet { rebuild() } }
    var onLayoutChange: (() -> Void)?
    var onOpenSession: ((AgentSession, SessionOpenMode) -> Void)?
    private let stack = NSStackView()
    private var icons: [DitherIconView] = []
    private var animTimer: Timer?
    private var expandedIDs = Set<String>()
    private var sessionsByID: [String: AgentSession] = [:]

    override func loadView() {
        let v = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        ])
        view = v
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        icons.removeAll()
        sessionsByID.removeAll()
        if sessions.isEmpty {
            stack.addArrangedSubview(label("No recent agent sessions", size: 12, color: .secondaryLabelColor, bold: false))
            return
        }
        for (i, s) in sessions.prefix(6).enumerated() {
            if i > 0 {
                let sep = DitherSeparator()
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
            sessionsByID[s.id] = s
            stack.addArrangedSubview(interactive(row(for: s), session: s))
            if !s.children.isEmpty {
                let open = expandedIDs.contains(s.id)
                let btn = NSButton(title: "\(open ? "▾" : "▸") \(s.children.count) subagent\(s.children.count == 1 ? "" : "s")",
                                   target: self, action: #selector(toggleChildren(_:)))
                btn.isBordered = false
                btn.font = notchAppearance.font(size: 10, bold: true)
                btn.contentTintColor = .systemBlue
                btn.identifier = NSUserInterfaceItemIdentifier(s.id)
                let wrap = NSStackView(views: [btn])
                wrap.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 0, right: 0)
                stack.addArrangedSubview(wrap)
                if open {
                    for child in s.children.prefix(8) {
                        sessionsByID[child.id] = child
                        stack.addArrangedSubview(interactive(
                            childRow(for: child), session: child))
                    }
                }
            }
        }
        if animTimer == nil {
            animTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                guard let self else { return }
                for icon in self.icons { icon.t += 0.12 }
            }
        }
    }

    @objc private func toggleChildren(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
        rebuild()
        onLayoutChange?()
    }

    private func interactive(_ row: NSView, session: AgentSession) -> NSView {
        row.identifier = NSUserInterfaceItemIdentifier(session.id)
        row.toolTip = session.isLive
            ? "Open the terminal running this session"
            : "Resume this session in Infinitty"
        let click = NSClickGestureRecognizer(
            target: self, action: #selector(openClickedSession(_:)))
        click.buttonMask = 0x1
        row.addGestureRecognizer(click)
        let context = NSClickGestureRecognizer(
            target: self, action: #selector(showSessionMenu(_:)))
        context.buttonMask = 0x2
        row.addGestureRecognizer(context)
        row.addCursorRect(row.bounds, cursor: .pointingHand)
        return row
    }

    @objc private func openClickedSession(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended,
              let id = gesture.view?.identifier?.rawValue,
              let session = sessionsByID[id] else { return }
        let mode: SessionOpenMode = NSEvent.modifierFlags.contains(.option)
            ? .chat : .automatic
        onOpenSession?(session, mode)
    }

    @objc private func showSessionMenu(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended,
              let view = gesture.view,
              let id = view.identifier?.rawValue,
              let session = sessionsByID[id] else { return }
        let menu = NSMenu()
        let openTitle = session.isLive ? "Jump to Running Session" : "Resume in Terminal"
        let open = menu.addItem(
            withTitle: openTitle, action: #selector(openSessionMenuItem(_:)),
            keyEquivalent: "")
        open.target = self
        open.representedObject = id
        let chat = menu.addItem(
            withTitle: "Continue in Built-In Chat",
            action: #selector(chatSessionMenuItem(_:)), keyEquivalent: "")
        chat.target = self
        chat.representedObject = id
        menu.popUp(positioning: nil, at: gesture.location(in: view), in: view)
    }

    @objc private func openSessionMenuItem(_ sender: NSMenuItem) {
        openSession(sender, mode: .automatic)
    }

    @objc private func chatSessionMenuItem(_ sender: NSMenuItem) {
        openSession(sender, mode: .chat)
    }

    private func openSession(_ sender: NSMenuItem, mode: SessionOpenMode) {
        guard let id = sender.representedObject as? String,
              let session = sessionsByID[id] else { return }
        onOpenSession?(session, mode)
    }

    private func childRow(for s: AgentSession) -> NSView {
        let icon = DitherIconView()
        icon.running = s.isBusy
        icon.idle = s.isLive && !s.isBusy
        icon.kind = s.kind
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        icons.append(icon)
        let name = label(s.nickname ?? (s.title.isEmpty ? s.kind.rawValue : s.title), size: 11, color: .secondaryLabelColor, bold: true)
        let tag = label("\(s.model.isEmpty ? s.kind.rawValue : s.model) · \(relative(s.lastModified))", size: 9,
                        color: (s.isBusy ? NSColor.systemBlue : s.isLive ? .secondaryLabelColor : .systemGreen).withAlphaComponent(0.6), bold: false)
        tag.setContentCompressionResistancePriority(.required, for: .horizontal)
        let top = NSStackView(views: [icon, name, NSView(), tag])
        top.orientation = .horizontal
        top.translatesAutoresizingMaskIntoConstraints = false
        var views: [NSView] = [top]
        if !s.snippet.isEmpty {
            let snip = label(s.snippet, size: 11, color: .secondaryLabelColor, bold: false)
            snip.maximumNumberOfLines = 1
            snip.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
            views.append(snip)
        }
        let col = NSStackView(views: views)
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 1
        col.edgeInsets = NSEdgeInsets(top: 2, left: 28, bottom: 2, right: 4)
        top.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -32).isActive = true
        return col
    }

    var contentHeight: CGFloat {
        stack.fittingSize.height
    }

    private func row(for s: AgentSession) -> NSView {
        let icon = DitherIconView()
        icon.running = s.anyBusy
        icon.idle = s.anyLive && !s.anyBusy
        icon.kind = s.kind
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        icons.append(icon)
        let title = label(s.kind.rawValue, size: 12, color: .labelColor, bold: true)
        let tag = label("\(s.model.isEmpty ? s.title : s.model) · \(relative(s.lastModified))", size: 10,
                        color: (s.anyBusy ? NSColor.systemBlue : s.anyLive ? .secondaryLabelColor : .systemGreen).withAlphaComponent(0.75), bold: false)
        tag.setContentCompressionResistancePriority(.required, for: .horizontal)
        let top = NSStackView(views: [icon, title, NSView(), tag])
        top.orientation = .horizontal
        top.translatesAutoresizingMaskIntoConstraints = false

        var views: [NSView] = [top]
        let line = s.prompt.isEmpty ? s.snippet : "You: " + s.prompt
        if !line.isEmpty {
            let snippet = label(line, size: 11, color: .secondaryLabelColor, bold: false)
            snippet.maximumNumberOfLines = 1
            snippet.widthAnchor.constraint(lessThanOrEqualToConstant: 440).isActive = true
            views.append(snippet)
        }
        let col = NSStackView(views: views)
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 1
        col.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        top.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -8).isActive = true
        return col
    }

    private func label(_ text: String, size: CGFloat, color: NSColor, bold: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = notchAppearance.font(size: size, bold: bold)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        // Truncate rather than force the window wider than its frame
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    private func relative(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}

// MARK: - Notch window content

/// Indicator content: branded pixel animations for whichever agents are running.
enum AgentGlyphState: Equatable { case inactive, idle, running, done }

enum NotchSessionState {
    static func resolve(
        live: Bool, busy: Bool, wasLive: Bool, current: AgentGlyphState
    ) -> AgentGlyphState {
        if busy { return .running }
        if live { return .idle }
        if wasLive { return .done }
        return current
    }
}

final class IndicatorView: NSView {
    var claudeState: AgentGlyphState = .inactive { didSet { needsDisplay = true } }
    var codexState: AgentGlyphState = .inactive { didSet { needsDisplay = true } }
    var activityText: String? { didSet { needsDisplay = true } }
    var activityColor: NSColor = .systemGray { didSet { needsDisplay = true } }
    var notchAppearance = NotchAppearance() { didSet { needsDisplay = true } }
    var notchWidth: CGFloat = 180 { didSet { needsDisplay = true } }
    var t: CGFloat = 0 { didSet { needsDisplay = true } }

    static let claudeOrange = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)  // Anthropic coral
    static let codexTeal = NSColor(red: 0.06, green: 0.64, blue: 0.50, alpha: 1)     // OpenAI teal

    // The Claude Code launch-banner mascot, drawn from its real block characters.
    // Two frames: the feet alternate so it walks.
    static let mascotFrames: [[String]] = [
        [" ▐▛███▜▌ ",
         "▝▜█████▛▘",
         "  ▘▘ ▝▝  "],
        [" ▐▛███▜▌ ",
         "▝▜█████▛▘",
         "  ▝▝ ▘▘  "],
    ]
    // quadrant bits: (upper-left, upper-right, lower-left, lower-right)
    static let quadrants: [Character: (Bool, Bool, Bool, Bool)] = [
        "█": (true, true, true, true),
        "▐": (false, true, false, true),
        "▌": (true, false, true, false),
        "▛": (true, true, true, false),
        "▜": (true, true, false, true),
        "▙": (true, false, true, true),
        "▟": (false, true, true, true),
        "▘": (true, false, false, false),
        "▝": (false, true, false, false),
        "▖": (false, false, true, false),
        "▗": (false, false, false, true),
        " ": (false, false, false, false),
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cy = bounds.midY
        let leftSlotWidth = activityText == nil
            ? NotchLayout.collapsedIndicatorWidth
            : NotchLayout.activityIndicatorWidth
        let notchLeft = bounds.minX + leftSlotWidth
        let notchRight = notchLeft + notchWidth
        if let activityText, !activityText.isEmpty {
            let statusRect = NSRect(
                x: bounds.minX + 2, y: bounds.minY + 3,
                width: max(0, notchLeft - bounds.minX - 44),
                height: max(0, bounds.height - 6))
            let background = NSBezierPath(roundedRect: statusRect, xRadius: 8, yRadius: 8)
            NSColor.black.withAlphaComponent(0.92).setFill()
            background.fill()
            activityColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: statusRect.minX + 9, y: cy - 3, width: 6, height: 6)).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: notchAppearance.font(size: 11, bold: true),
                .foregroundColor: NSColor.white,
            ]
            let text = NSAttributedString(string: activityText, attributes: attributes)
            text.draw(in: NSRect(
                x: statusRect.minX + 22, y: cy - 8,
                width: max(0, statusRect.width - 28), height: 16))
        }
        let claudeRight = notchLeft - 8
        let codexLeft = notchRight + 8
        // Claude owns the slot left of the centered notch; the configured pet
        // owns the slot on its right. Both stay visible but dim while live and
        // quiet, so a running session can never collapse into a blank bar.
        switch claudeState {
        case .idle: _ = drawCrab(
            ctx, right: claudeRight, cy: cy, animated: false, alpha: 0.42)
        case .running: _ = drawCrab(
            ctx, right: claudeRight, cy: cy, animated: true, alpha: 1)
        case .done: drawGreenBlob(ctx, right: claudeRight, cy: cy)
        case .inactive: break
        }
        switch codexState {
        case .idle: _ = drawCodexPet(
            ctx, left: codexLeft, cy: cy, animated: false, alpha: 0.42)
        case .running: _ = drawCodexPet(
            ctx, left: codexLeft, cy: cy, animated: true, alpha: 1)
        case .done: drawGreenBlob(ctx, right: codexLeft + 18, cy: cy)
        case .inactive: break
        }
    }

    private func drawGreenBlob(_ ctx: CGContext, right: CGFloat, cy: CGFloat) {
        let cell: CGFloat = 2.5, grid = 7
        let c = CGFloat(grid) / 2
        let step = Int(t * 2)
        let x0 = right - CGFloat(grid) * cell
        for i in 0..<grid {
            for j in 0..<grid {
                let dx = CGFloat(i) + 0.5 - c, dy = CGFloat(j) + 0.5 - c
                let dist = sqrt(dx * dx + dy * dy)
                let n = sin(CGFloat(i * 374761 + j * 668265 + step * 982451) * 0.0001) * 43758.5453
                let r = n - n.rounded(.down)
                guard r > 0.1 + dist / c * 0.8 else { continue }
                ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.5 + 0.5 * r).cgColor)
                ctx.fill(CGRect(x: x0 + CGFloat(i) * cell, y: cy - CGFloat(grid) * cell / 2 + CGFloat(j) * cell,
                                width: cell - 0.5, height: cell - 0.5))
            }
        }
    }

    /// Returns the left edge of what was drawn.
    private func drawCrab(
        _ ctx: CGContext, right: CGFloat, cy: CGFloat,
        animated: Bool, alpha baseAlpha: CGFloat
    ) -> CGFloat {
        // terminal cells are ~2x taller than wide — keep that aspect or he squishes
        let subW: CGFloat = 1.6, subH: CGFloat = 3.2
        let walk = animated ? Int(t * 2.5) : 0
        let frame = Self.mascotFrames[walk % 2]
        let cols = frame[0].count * 2, rows = frame.count * 2
        let x0 = right - CGFloat(cols) * subW
        let bob: CGFloat = (walk % 2 == 0) ? -0.5 : 0.5  // little bounce, symmetric around center
        let y0 = cy + CGFloat(rows) * subH / 2 + bob - 2  // feet row is sparse; nudge down so the body reads centered
        let step = Int(t * 3)
        for (j, line) in frame.enumerated() {
            for (i, ch) in line.enumerated() {
                guard let q = Self.quadrants[ch] else { continue }
                let cells = [(q.0, 0, 0), (q.1, 1, 0), (q.2, 0, 1), (q.3, 1, 1)]
                for (on, qx, qy) in cells where on {
                    let n = sin(CGFloat(i * 374761 + j * 668265 + (qx + qy * 2) * 97 + step * 982451) * 0.0001) * 43758.5453
                    let r = n - n.rounded(.down)
                    // feet stay solid; body shimmers gently
                    let isFeet = j == frame.count - 1
                    let alpha = (isFeet ? 1.0 : 0.8 + 0.2 * r) * baseAlpha
                    ctx.setFillColor(Self.claudeOrange.withAlphaComponent(alpha).cgColor)
                    ctx.fill(CGRect(x: x0 + CGFloat(i * 2 + qx) * subW,
                                    y: y0 - CGFloat(j * 2 + qy + 1) * subH,
                                    width: subW - 0.3, height: subH - 0.4))
                }
            }
        }
        return x0
    }

    // The activity indicator uses Infinitty's configured terminal pet. Sheets
    // use the same 8-column × 9-row layout as the terminal renderer.
    static var currentPetID: String?
    private static var spriteCache: [String: NSImage] = [:]
    static var codexSprite: NSImage? {
        guard let currentPetID, !currentPetID.isEmpty else { return nil }
        if let img = spriteCache[currentPetID] { return img }
        let configuredURL = Pet.resolveImagePath(currentPetID).map {
            URL(fileURLWithPath: $0)
        }
        let resource = "pet-\(currentPetID.lowercased())"
        let url = configuredURL
            ?? Bundle.module.url(
                forResource: resource, withExtension: "webp",
                subdirectory: "NotchPets")
            ?? Bundle.module.url(forResource: resource, withExtension: "webp")
        guard let url, let img = NSImage(contentsOf: url) else { return nil }
        spriteCache[currentPetID] = img
        return img
    }
    static func configurePet(_ name: String?) {
        currentPetID = name
    }

    private func drawCodexPet(
        _ ctx: CGContext, left: CGFloat, cy: CGFloat,
        animated: Bool, alpha: CGFloat
    ) -> CGFloat {
        guard let sprite = Self.codexSprite else {
            return drawRing(
                ctx, right: left + 22.5, cy: cy,
                color: Self.codexTeal, animated: animated, baseAlpha: alpha)
        }
        let fw: CGFloat = 192, fh: CGFloat = 208
        let idx = animated ? Int(t / 0.12) % 8 : 0
        let src = NSRect(x: CGFloat(idx) * fw, y: 1872 - 2 * fh, width: fw, height: fh)
        let h: CGFloat = 26, w = h * fw / fh
        let dest = NSRect(x: left, y: cy - h / 2, width: w, height: h)
        NSGraphicsContext.current?.imageInterpolation = .none  // keep the pixel art crisp
        sprite.draw(in: dest, from: src, operation: .sourceOver, fraction: alpha)
        return dest.maxX
    }

    /// Returns the left edge of what was drawn.
    private func drawRing(
        _ ctx: CGContext, right: CGFloat, cy: CGFloat, color: NSColor,
        animated: Bool, baseAlpha: CGFloat
    ) -> CGFloat {
        let cell: CGFloat = 2.5, grid = 9
        let x0 = right - CGFloat(grid) * cell
        let y0 = cy - CGFloat(grid) * cell / 2
        let c = CGFloat(grid) / 2
        let phase = animated ? t * 1.4 : 0
        let step = animated ? Int(t * 3) : 0
        for i in 0..<grid {
            for j in 0..<grid {
                let dx = CGFloat(i) + 0.5 - c
                let dy = CGFloat(j) + 0.5 - c
                let dist = sqrt(dx * dx + dy * dy)
                guard dist > c - 2.4, dist < c else { continue }
                var angle = atan2(dy, dx) - phase
                angle = angle - (angle / (2 * .pi)).rounded(.down) * 2 * .pi
                let intensity = 1 - angle / (2 * .pi)
                let n = sin(CGFloat(i * 374761 + j * 668265 + step * 982451) * 0.0001) * 43758.5453
                let r = n - n.rounded(.down)
                let a = intensity * intensity * (0.55 + 0.45 * r)
                guard a > 0.08 else { continue }
                ctx.setFillColor(color.withAlphaComponent(a * baseAlpha).cgColor)
                ctx.fill(CGRect(x: x0 + CGFloat(i) * cell, y: y0 + CGFloat(j) * cell,
                                width: cell - 0.5, height: cell - 0.5))
            }
        }
        return x0
    }
}

final class NotchView: NSView {
    var expanded = false { didSet { needsDisplay = true } }
    var barHeight: CGFloat = 32
    var notchWidth: CGFloat = 180
    var simulatesNotch = false
    var onCollapse: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) { onCollapse?() }
    override func rightMouseUp(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Quit Infinitty", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        if expanded {
            // Black panel with rounded bottom corners, only when open
            let r: CGFloat = 16
            let path = NSBezierPath()
            path.move(to: NSPoint(x: b.minX, y: b.maxY))
            path.line(to: NSPoint(x: b.minX, y: b.minY + r))
            path.appendArc(withCenter: NSPoint(x: b.minX + r, y: b.minY + r), radius: r, startAngle: 180, endAngle: 270, clockwise: false)
            path.line(to: NSPoint(x: b.maxX - r, y: b.minY))
            path.appendArc(withCenter: NSPoint(x: b.maxX - r, y: b.minY + r), radius: r, startAngle: 270, endAngle: 0, clockwise: false)
            path.line(to: NSPoint(x: b.maxX, y: b.maxY))
            path.close()
            NSColor.black.setFill()
            path.fill()
            return  // no spinner while the panel is open
        }
        guard simulatesNotch else { return }
        let r: CGFloat = min(12, barHeight / 2)
        let path = NSBezierPath()
        let left = b.midX - notchWidth / 2
        let right = b.midX + notchWidth / 2
        path.move(to: NSPoint(x: left, y: b.maxY))
        path.line(to: NSPoint(x: left, y: b.minY + r))
        path.appendArc(
            withCenter: NSPoint(x: left + r, y: b.minY + r), radius: r,
            startAngle: 180, endAngle: 270, clockwise: false)
        path.line(to: NSPoint(x: right - r, y: b.minY))
        path.appendArc(
            withCenter: NSPoint(x: right - r, y: b.minY + r), radius: r,
            startAngle: 270, endAngle: 0, clockwise: false)
        path.line(to: NSPoint(x: right, y: b.maxY))
        path.close()
        NSColor.black.setFill()
        path.fill()
    }
}

// MARK: - App

struct NotchLayout {
    static let collapsedIndicatorWidth: CGFloat = 66
    static let activityIndicatorWidth: CGFloat = 260

    static func indicatorFrame(
        centerX: CGFloat,
        notchWidth: CGFloat,
        screenTop: CGFloat,
        barHeight: CGFloat,
        showsActivity: Bool
    ) -> NSRect {
        let leftWidth = showsActivity ? activityIndicatorWidth : collapsedIndicatorWidth
        let rightWidth = collapsedIndicatorWidth
        return NSRect(
            x: centerX - notchWidth / 2 - leftWidth,
            y: screenTop - barHeight,
            width: leftWidth + notchWidth + rightWidth,
            height: barHeight)
    }
}

/// One centered session-notch runtime per selected display.
private final class NotchRuntime: NSObject {
    private var window: NSWindow!
    private var indicatorWindow: NSWindow!
    private let notchView = NotchView()
    private let indicatorView = IndicatorView()
    private let scanner = SessionScanner()
    private let discovery = ProcessDiscovery()
    private let scanQueue = DispatchQueue(label: "infinitty.session-notch.scan", qos: .utility)
    // open-vibe-island removal rule: a transcript's process must be missing
    // for 2 consecutive polls (~6 s) before its session stops being live
    private var missCounts: [String: Int] = [:]
    private var processesByKey: [String: ProcessDiscovery.Snapshot] = [:]
    private let listController = SessionListController()
    private var frame = 0
    private var claudeWasLive = false
    private var codexWasLive = false
    private var claudeState: AgentGlyphState = .inactive
    private var codexState: AgentGlyphState = .inactive
    private var expanded = false
    private let screen: NSScreen
    private var timers: [Timer] = []
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var isShown = false
    private let appearance: NotchAppearance
    private let onOpenSession: (AgentSession, SessionOpenMode) -> Void

    init(
        screen: NSScreen, appearance: NotchAppearance,
        onOpenSession: @escaping (AgentSession, SessionOpenMode) -> Void
    ) {
        self.screen = screen
        self.appearance = appearance
        self.onOpenSession = onOpenSession
        super.init()
    }

    // Geometry
    private var notchWidth: CGFloat {
        let s = screen
        if #available(macOS 12.0, *), s.safeAreaInsets.top > 0,
           let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            return s.frame.width - left.width - right.width
        }
        return 180  // no physical notch: fake pill
    }
    private var barHeight: CGFloat {
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        return 30
    }
    private let sidePad: CGFloat = 120  // indicator strip beside the notch
    private let expandedSize = NSSize(width: 480, height: 240)

    // In a fullscreen space the menu bar is hidden, so the bar can own the whole top edge
    private var isFullscreenSpace: Bool {
        screen.visibleFrame.maxY >= screen.frame.maxY - 1
    }

    private func collapsedFrame() -> NSRect {
        // Always full-width: transparent and click-through, so it costs nothing,
        // and the indicator can dodge menu items anywhere along the bar
        let s = screen.frame
        return NSRect(x: s.minX, y: s.maxY - barHeight, width: s.width, height: barHeight)
    }

    private func expandedFrame() -> NSRect {
        let s = screen.frame
        let w = max(expandedSize.width, notchWidth + sidePad * 2)
        let h = barHeight + max(60, listController.contentHeight) + 10
        return NSRect(x: s.midX - w / 2, y: s.maxY - h, width: w, height: h)
    }

    func show() {
        guard !isShown else { return }
        isShown = true

        // Panel window: full-width, mouse-transparent unless expanded
        window = NSWindow(contentRect: collapsedFrame(), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .darkAqua)  // panel is always black
        window.contentView = notchView
        notchView.wantsLayer = true
        notchView.barHeight = barHeight
        notchView.notchWidth = notchWidth
        notchView.simulatesNotch = screen.safeAreaInsets.top <= 0

        // Indicator window: tiny, always interactive, never steals focus
        indicatorWindow = NSPanel(contentRect: indicatorScreenRect,
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        indicatorWindow.isOpaque = false
        indicatorWindow.backgroundColor = .clear
        indicatorWindow.hasShadow = false
        indicatorWindow.level = .statusBar
        indicatorWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        indicatorWindow.ignoresMouseEvents = true  // visual only — clicks are caught by the global monitor
        indicatorWindow.contentView = indicatorView
        indicatorView.notchWidth = notchWidth
        indicatorView.notchAppearance = appearance
        IndicatorView.configurePet(appearance.pet)
        listController.notchAppearance = appearance
        listController.onOpenSession = { [weak self] session, mode in
            guard let self else { return }
            self.setExpanded(false)
            self.onOpenSession(session, mode)
        }

        listController.onLayoutChange = { [weak self] in
            guard let self, self.isShown, self.expanded else { return }
            self.window.setFrame(self.expandedFrame(), display: true)
        }
        notchView.onCollapse = { [weak self] in
            guard let self, self.isShown, self.expanded else { return }
            self.setExpanded(false)
        }
        // The indicator window never takes mouse input (routing to tiny borderless
        // menu-bar windows is unreliable) — a global monitor catches its clicks,
        // and also handles click-away dismissal.
        var lastToggle = ProcessInfo.processInfo.systemUptime
        let handleMouseDown: () -> Void = { [weak self] in
            guard let self, self.isShown else { return }
            let loc = NSEvent.mouseLocation
            let now = ProcessInfo.processInfo.systemUptime
            if !self.expanded {
                if self.indicatorScreenRect.insetBy(dx: -4, dy: 0).contains(loc), now - lastToggle > 0.15 {
                    lastToggle = now
                    self.setExpanded(true)
                }
            } else if !self.window.frame.contains(loc) {
                self.setExpanded(false)
            }
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
            handleMouseDown()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            handleMouseDown()
            return event
        }
        window.orderFrontRegardless()
        indicatorWindow.orderFrontRegardless()

        // Revisiting the terminal acknowledges finished agents — green clears
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isShown,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let terminals = ["com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2",
                             "net.kovidgoyal.kitty", "dev.warp.Warp-Stable", "io.alacritty"]
            let bundleID = app.bundleIdentifier ?? ""
            if terminals.contains(bundleID) || bundleID == Bundle.main.bundleIdentifier {
                if self.claudeState == .done { self.claudeState = .inactive }
                if self.codexState == .done { self.codexState = .inactive }
                self.render()
            }
        }

        timers.append(Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() })
        rescan()
        // 3 s poll cadence, matching open-vibe-island's process discovery
        timers.append(Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in self?.rescan() })
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        expanded = false
        notchView.layer?.removeAllAnimations()
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        window?.orderOut(nil)
        indicatorWindow?.orderOut(nil)
        window = nil
        indicatorWindow = nil
    }

    /// Screen rect of the indicator — the only collapsed region that should catch clicks
    private var indicatorScreenRect: NSRect {
        NotchLayout.indicatorFrame(
            centerX: screen.frame.midX,
            notchWidth: notchWidth,
            screenTop: screen.frame.maxY,
            barHeight: barHeight,
            showsActivity: indicatorView.activityText != nil)
    }

    func setActivity(text: String?, color: NSColor = .systemGray) {
        indicatorView.activityText = text.map { String($0.prefix(38)) }
        indicatorView.activityColor = color
        guard isShown else { return }
        indicatorWindow.setFrame(indicatorScreenRect, display: true)
        if !expanded { indicatorWindow.orderFrontRegardless() }
    }

    private func setExpanded(_ on: Bool) {
        guard expanded != on else { return }
        expanded = on
        // Attach the list only while expanded — its Auto Layout content would
        // otherwise force the borderless window wider than the collapsed frame.
        let listView = listController.view
        if on {
            notchView.expanded = true
            listView.translatesAutoresizingMaskIntoConstraints = false
            listView.alphaValue = 1
            notchView.addSubview(listView)
            NSLayoutConstraint.activate([
                listView.topAnchor.constraint(equalTo: notchView.topAnchor, constant: barHeight + 4),
                listView.leadingAnchor.constraint(equalTo: notchView.leadingAnchor, constant: 8),
                listView.trailingAnchor.constraint(equalTo: notchView.trailingAnchor, constant: -8),
            ])
        }
        // Never animate the window frame — macOS interpolates it unreliably.
        // Resize instantly while invisible and animate the content layer instead
        // (the technique used by boring.notch / NotchNook).
        if on {
            window.ignoresMouseEvents = false
            window.setFrame(expandedFrame(), display: true)
            indicatorWindow.orderOut(nil)  // spinner hides while the panel is open
            animatePanelLayer(open: true)
        } else {
            indicatorWindow.orderFrontRegardless()  // back immediately — never leave a dead zone
            window.ignoresMouseEvents = true
            animatePanelLayer(open: false) { [weak self] in
                guard let self, self.isShown, !self.expanded else { return }
                self.notchView.expanded = false
                listView.removeFromSuperview()
                self.window.setFrame(self.collapsedFrame(), display: true)
                self.indicatorWindow.orderFrontRegardless()
            }
        }
    }

    private var animating = false
    /// Scale + fade the content layer toward/away from the notch (top center).
    private func animatePanelLayer(open: Bool, completion: (() -> Void)? = nil) {
        guard let layer = notchView.layer else { completion?(); return }
        let b = notchView.bounds
        layer.anchorPoint = CGPoint(x: 0.5, y: 1)
        layer.position = CGPoint(x: b.midX, y: b.maxY)
        let small = CATransform3DMakeScale(0.25, 0.06, 1)
        let from = open ? small : CATransform3DIdentity
        let to = open ? CATransform3DIdentity : small
        animating = true
        // Set model values to the end state, then animate the presentation to match
        layer.transform = to
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.animating = false
            if !open {
                // window is about to shrink; restore the layer for next time
                layer.transform = CATransform3DIdentity
            }
            completion?()
        }
        let t = CABasicAnimation(keyPath: "transform")
        t.fromValue = NSValue(caTransform3D: from)
        t.toValue = NSValue(caTransform3D: to)
        t.duration = 0.22
        t.timingFunction = CAMediaTimingFunction(name: open ? .easeOut : .easeIn)
        layer.add(t, forKey: t.keyPath)
        CATransaction.commit()
    }

    private func rescan() {
        scanQueue.async { [weak self] in
            guard let self, self.isShown else { return }
            // Pool the whole pass: this serial queue can stay busy back-to-back,
            // and GCD only drains its own pool when a queue goes idle — without
            // this, every transcript read of every pass accumulates.
            let result = autoreleasepool { () -> [AgentSession] in
                // Process discovery is the authoritative liveness signal. Keys are
                // transcript paths, or "cwd#<encoded>#<i>" for claude's cwd fallback.
                var seen = Set<String>()
                var cwdIndex: [String: Int] = [:]
                for snap in self.discovery.liveTranscripts() {
                    let key: String
                    if let path = snap.transcriptPath {
                        key = path
                    } else if snap.kind == .claude, let cwd = snap.cwd {
                        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
                        let i = cwdIndex[encoded, default: 0]
                        cwdIndex[encoded] = i + 1
                        key = "cwd#\(encoded)#\(i)"
                    } else { continue }
                    seen.insert(key)
                    self.processesByKey[key] = snap
                }
                for p in seen { self.missCounts[p] = 0 }
                for (p, n) in self.missCounts where !seen.contains(p) {
                    if n + 1 >= 2 {
                        self.missCounts.removeValue(forKey: p)
                        self.processesByKey.removeValue(forKey: p)
                    } else {
                        self.missCounts[p] = n + 1
                    }
                }
                let liveProcesses = self.missCounts.keys.compactMap {
                    self.processesByKey[$0]
                }
                return self.scanner.scan(liveProcesses: liveProcesses)
            }
            DispatchQueue.main.async {
                guard self.isShown else { return }
                // Track fullscreen-space changes: full-width bar when the menu bar is hidden
                if !self.expanded, !self.animating {
                    if self.window.frame != self.collapsedFrame() {
                        self.window.setFrame(self.collapsedFrame(), display: true)
                    }
                    // re-dodge menu items as the frontmost app changes
                    let r = self.indicatorScreenRect
                    if self.indicatorWindow.frame != r { self.indicatorWindow.setFrame(r, display: true) }
                }
                self.listController.sessions = result
                // busy → animation; alive-but-quiet → dim static indicator;
                // process exited → done blob (cleared on terminal focus)
                let claudeLive = result.contains { $0.kind == .claude && $0.anyLive }
                let claudeBusy = result.contains { $0.kind == .claude && $0.anyBusy }
                let codexLive = result.contains { $0.kind == .codex && $0.anyLive }
                let codexBusy = result.contains { $0.kind == .codex && $0.anyBusy }
                self.claudeState = NotchSessionState.resolve(
                    live: claudeLive, busy: claudeBusy,
                    wasLive: self.claudeWasLive, current: self.claudeState)
                self.codexState = NotchSessionState.resolve(
                    live: codexLive, busy: codexBusy,
                    wasLive: self.codexWasLive, current: self.codexState)
                self.claudeWasLive = claudeLive
                self.codexWasLive = codexLive
                self.render()
            }
        }
    }

    private func tick() {
        frame += 1
        render()
    }

    private func render() {
        indicatorView.claudeState = claudeState
        indicatorView.codexState = codexState
        indicatorView.t = CGFloat(frame) * 0.12
    }
}

enum NotchDisplayMode: Equatable {
    case builtin
    case external
    case primary
    case all

    init(_ value: String) {
        switch value.lowercased() {
        case "external": self = .external
        case "primary", "focused": self = .primary
        case "all", "both": self = .all
        default: self = .builtin
        }
    }
}

enum NotchActivityTone: Equatable {
    case custom
    case running
    case success
    case failure
}

struct NotchActivityPresentation: Equatable {
    let text: String
    let tone: NotchActivityTone

    static func custom(_ text: String) -> NotchActivityPresentation {
        NotchActivityPresentation(text: String(text.prefix(38)), tone: .custom)
    }

    static func marker(kind: UInt8, exitCode: Int, commandLine: String?) -> NotchActivityPresentation? {
        switch kind {
        case UInt8(ascii: "C"):
            let command = String((commandLine ?? "command").suffix(34))
            return NotchActivityPresentation(text: "running \(command)", tone: .running)
        case UInt8(ascii: "D") where exitCode == 0:
            return NotchActivityPresentation(text: "done", tone: .success)
        case UInt8(ascii: "D"):
            return NotchActivityPresentation(text: "exit \(exitCode)", tone: .failure)
        default:
            return nil
        }
    }
}

/// Infinitty lifecycle adapter for centered session activity and recovery.
final class NotchActivityController {
    private var runtimes: [NotchRuntime] = []
    private var hideTimer: Timer?
    private var activity: NotchActivityPresentation?
    private var appearance = NotchAppearance()
    var onOpenSession: ((AgentSession, SessionOpenMode) -> Void)?

    func configure(
        fontName: String?, fontStyle: String?, fontSize: CGFloat, pet: String?
    ) {
        appearance = NotchAppearance(
            fontName: fontName, fontStyle: fontStyle,
            fontSize: fontSize, pet: pet)
        IndicatorView.configurePet(pet)
    }

    /// display: builtin | external | primary | all
    func show(display: String) {
        stopRuntimes()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let builtin = screens.filter { $0.safeAreaInsets.top > 0 }
        let external = screens.filter { $0.safeAreaInsets.top <= 0 }
        let main = NSScreen.main ?? screens[0]

        let targets: [NSScreen]
        switch NotchDisplayMode(display) {
        case .external:
            targets = external.isEmpty ? screens : external
        case .primary:
            targets = [main]
        case .all:
            targets = screens
        case .builtin:
            targets = builtin.isEmpty ? [main] : builtin
        }

        runtimes = targets.map { screen in
            let runtime = NotchRuntime(
                screen: screen, appearance: appearance,
                onOpenSession: { [weak self] session, mode in
                    self?.onOpenSession?(session, mode)
                })
            runtime.show()
            if let activity { apply(activity, to: runtime) }
            return runtime
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        activity = nil
        stopRuntimes()
    }

    /// External apps can post a transient message through the app socket or MCP.
    func showCustom(text: String) {
        present(.custom(text), for: 6)
    }

    /// OSC 133 event from a session. kind: A prompt, C output start, D done.
    func handleMarker(kind: UInt8, exitCode: Int, commandLine: String?) {
        guard let presentation = NotchActivityPresentation.marker(
            kind: kind, exitCode: exitCode, commandLine: commandLine)
        else { return }
        present(presentation, for: kind == UInt8(ascii: "D") ? 4 : nil)
    }

    private func present(_ presentation: NotchActivityPresentation, for duration: TimeInterval?) {
        hideTimer?.invalidate()
        activity = presentation
        runtimes.forEach { apply(presentation, to: $0) }
        guard let duration else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.activity = nil
            self.runtimes.forEach { $0.setActivity(text: nil) }
        }
    }

    private func apply(_ presentation: NotchActivityPresentation, to runtime: NotchRuntime) {
        let color: NSColor
        switch presentation.tone {
        case .custom: color = .systemPurple
        case .running: color = .systemBlue
        case .success: color = .systemGreen
        case .failure: color = .systemRed
        }
        runtime.setActivity(text: presentation.text, color: color)
    }

    private func stopRuntimes() {
        runtimes.forEach { $0.hide() }
        runtimes.removeAll()
    }
}
