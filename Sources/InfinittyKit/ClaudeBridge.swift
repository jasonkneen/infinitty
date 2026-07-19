import Foundation

/// Long-lived Claude Code CLI bridge. Spawns `claude --print
/// --input-format stream-json --output-format stream-json --verbose`
/// once on first use and keeps that process warm across turns.
///
/// Tool calls are NOT proxied through this layer: the launch injects the
/// bundled `infinitty-mcp` through Claude's `--mcp-config`, and Claude runs
/// that server itself. We
/// only need to forward the user's prompt to Claude's stdin and read
/// the final `result` envelope off stdout. Each subsequent call skips
/// CLI cold-start (Node init + skill filesystem scan + hook load),
/// which is the difference between sub-second and 30-second turns.
///
/// The protocol envelope:
///   INPUT  (one NDJSON line per prompt):
///     {"type":"user","message":{"role":"user","content":[...]},"parent_tool_use_id":null,"session_id":"<uuid>"}
///   OUTPUT (NDJSON):
///     {"type":"system",  "subtype":"init"}                              - sent once at start
///     {"type":"assistant","message":{"content":[{"type":"text","text":...}]}}
///     {"type":"result","subtype":"success","result":"<final answer>"}  - signals turn end
///     {"type":"result","subtype":"error_*"}                             - turn failed
final class ClaudeBridge: @unchecked Sendable {
    static let shared = ClaudeBridge()

    // MARK: - State

    private let queue = DispatchQueue(label: "infinitty.claude.bridge")
    private let turnGate = AgentTurnGate()
    private let executableURLOverride: URL?
    private let mcpExecutableURLOverride: URL?
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    /// Per-process UUID — passed as `--session-id` so multi-turn stays in
    /// the same Claude session (the CLI keeps context across user
    /// messages within one session id). Regenerated on every spawn:
    /// the CLI hard-errors with “Session ID … is already in use” if a
    /// respawned process reuses the previous id, which used to brick
    /// the bridge for the rest of the app's lifetime after any crash
    /// or restart of the child.
    private var sessionID = UUID().uuidString
    private static let defaultModel = "claude-haiku-4-5"
    /// Model the live process was spawned with. A different requested
    /// model forces a respawn (the CLI pins `--model` at launch).
    private var currentModel: String?
    private var currentSystemPrompt: String?
    /// One continuation is active at a time. `AgentTurnGate` serializes
    /// callers because Claude's result envelopes do not echo a client turn id.
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var currentTurnID: String?
    private var assistantAccumulator = ""
    private var stdoutBuffer = Data()

    private static let requestTimeoutSeconds: TimeInterval = 130

    var isRunning: Bool { queue.sync { process?.isRunning == true } }

    init(executableURL: URL? = nil, mcpExecutableURL: URL? = nil) {
        self.executableURLOverride = executableURL
        self.mcpExecutableURLOverride = mcpExecutableURL
    }

    // MARK: - Public API

    /// Spawn the CLI process ahead of the first real turn so its cold
    /// start (Node init, MCP-server boot, session-start hooks) overlaps
    /// with the user still typing their question. Idempotent — a no-op
    /// once the process is live. This is the openclicky trick: warm on
    /// interaction, so the first ask isn't the one paying spawn cost.
    func warmUp(system: String, model: String? = nil) {
        try? ensureProcess(system: system, model: model)
    }

    /// Run a single, blocking turn against the warm bridge. Lazy-sprawls
    /// (sic). Returns the assistant's final `result` text.
    func turn(prompt: String, system: String, model: String? = nil,
              timeout: TimeInterval = requestTimeoutSeconds) async throws -> String {
        await turnGate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await performTurn(
                prompt: prompt, system: system, model: model, timeout: timeout)
            await turnGate.release()
            return result
        } catch {
            await turnGate.release()
            throw error
        }
    }

    private func performTurn(
        prompt: String, system: String, model: String?, timeout: TimeInterval
    ) async throws -> String {
        try ensureProcess(system: system, model: model)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let turnID = UUID().uuidString
                queue.async { [weak self] in
                    guard let self else {
                        cont.resume(throwing: CancellationError()); return
                    }
                    self.currentTurnID = turnID
                    self.assistantAccumulator = ""
                    self.pending[turnID] = cont
                    self.writeUserMessage(turnID: turnID, text: prompt)
                }
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, let pending = self.pending.removeValue(forKey: turnID) else {
                        return
                    }
                    if self.currentTurnID == turnID { self.currentTurnID = nil }
                    pending.resume(throwing: ClaudeBridgeError.turnTimeout)
                }
            }
        }, onCancel: { [weak self] in
            self?.queue.async {
                guard let self, let id = self.currentTurnID,
                      let pending = self.pending.removeValue(forKey: id) else { return }
                self.currentTurnID = nil
                pending.resume(throwing: CancellationError())
            }
        })
    }

    func stop() {
        queue.sync { teardownLocked() }
    }

    /// Must be called on `queue`.
    private func teardownLocked() {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        currentModel = nil
        currentSystemPrompt = nil
        stdoutBuffer.removeAll()
        for (_, c) in pending { c.resume(throwing: CancellationError()) }
        pending.removeAll()
        currentTurnID = nil
    }

    deinit { stop() }

    // MARK: - Process

    private func ensureProcess(system: String, model: String?) throws {
        try queue.sync {
            let resolvedModel = model ?? Self.defaultModel
            if process?.isRunning == true {
                if currentModel == resolvedModel, currentSystemPrompt == system { return }
                // Model and system prompt are pinned at process launch.
                teardownLocked()
            } else if process != nil {
                teardownLocked()
            }
            guard let executable = executableURLOverride
                    ?? CLIExecutableResolver.resolve(.claude) else {
                throw ClaudeBridgeError.processUnavailable(
                    "Claude Code CLI not found on PATH; install it or set "
                    + "INFINITTY_CLAUDE_EXECUTABLE.")
            }
            // Fresh id per spawn — reusing the previous one makes the
            // CLI exit immediately with “Session ID … is already in use”.
            sessionID = UUID().uuidString.lowercased()
            let p = Process()
            p.executableURL = executable
            var args: [String] = [
                "--print",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--verbose",
                "--model", resolvedModel,
                "--system-prompt", system,
                "--session-id", sessionID,
            ]
            // YOLO by default — same opt-out as Codex (`INFINITTY_AI_YOLO=0`).
            // Background pet-assistant turns can't surface interactive
            // approval prompts, so tool calls would otherwise hang the
            // SSE turn until the timeout. With this flag the CLI
            // auto-approves every tool call against its permissions
            // policy; opt out per launch with the env var above.
            if ProcessInfo.processInfo.environment["INFINITTY_AI_YOLO"] != "0" {
                args.append("--dangerously-skip-permissions")
            }
            let mcpURL = mcpExecutableURLOverride
                ?? MCPConfiguration.mcpExecutablePath().map(URL.init(fileURLWithPath:))
            if let mcpURL,
               let data = MCPConfiguration.claudeMCPJSON(binaryPath: mcpURL.path),
               let json = String(data: data, encoding: .utf8) {
                // Give the embedded assistant its terminal tools without
                // depending on or mutating the user's global Claude config.
                args += ["--mcp-config", json, "--strict-mcp-config"]
            }
            p.arguments = args
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            p.standardInput = stdin
            p.standardOutput = stdout
            p.standardError = stderr
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
            env.removeValue(forKey: "CLAUDECODE")
            env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
            p.environment = env
            p.terminationHandler = { [weak self] proc in
                self?.queue.async {
                    guard let self, self.process === proc else { return }
                    self.stdoutHandle?.readabilityHandler = nil
                    self.stderrHandle?.readabilityHandler = nil
                    self.process = nil
                    self.currentModel = nil
                    self.currentSystemPrompt = nil
                    for (_, continuation) in self.pending {
                        continuation.resume(throwing: ClaudeBridgeError.processUnavailable(
                            "Claude bridge exited (\(proc.terminationStatus))."))
                    }
                    self.pending.removeAll()
                    self.currentTurnID = nil
                }
            }
            try p.run()
            self.process = p
            self.currentModel = resolvedModel
            self.currentSystemPrompt = system
            self.stdinHandle = stdin.fileHandleForWriting
            self.stdoutHandle = stdout.fileHandleForReading
            self.stderrHandle = stderr.fileHandleForReading
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                self?.queue.async { [weak self] in
                    self?.consumeStdout(data)
                }
            }
            // Drain stderr (--verbose chatter, hook noise). An undrained
            // 64 KB pipe blocks the child mid-write and wedges the bridge.
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
            }
        }
    }

    // MARK: - Stream I/O

    private func writeUserMessage(turnID: String, text: String) {
        let env: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]] as [[String: Any]],
            ] as [String: Any],
            "parent_tool_use_id": NSNull(),
            "session_id": sessionID,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: env, options: [.sortedKeys, .withoutEscapingSlashes]),
              let h = stdinHandle else { return }
        h.write(data)
        h.write(Data([0x0A]))
    }

    private func consumeStdout(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<stdoutBuffer.index(after: nl))
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            handleEvent(parsed)
        }
    }

    private func handleEvent(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        switch type {
        case "assistant":
            if let message = event["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content where (block["type"] as? String) == "text" {
                    if let text = block["text"] as? String {
                        assistantAccumulator += text
                        assistantAccumulator += "\n"
                    }
                }
            }
        case "result":
            handleResult(event)
        default:
            break
        }
    }

    private func handleResult(_ event: [String: Any]) {
        guard let turnID = currentTurnID,
              let continuation = pending.removeValue(forKey: turnID)
        else { return }
        currentTurnID = nil
        let subtype = event["subtype"] as? String ?? ""
        switch subtype {
        case "success":
            // Prefer the explicit `result` field; fall back to the
            // accumulator so we never return empty for a successful turn.
            let explicit = (event["result"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !explicit.isEmpty {
                continuation.resume(returning: explicit)
            } else {
                continuation.resume(returning: assistantAccumulator
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
        default:
            let msg = (event["result"] as? String)
                ?? (event["error"] as? String)
                ?? "Claude finished with subtype \(subtype)."
            continuation.resume(throwing: ClaudeBridgeError.rpcError(msg))
        }
    }
}

enum ClaudeBridgeError: LocalizedError {
    case processUnavailable(String)
    case rpcError(String)
    case turnTimeout

    var errorDescription: String? {
        switch self {
        case .processUnavailable(let m), .rpcError(let m): return m
        case .turnTimeout:
            return "Claude did not respond within the turn timeout."
        }
    }
}
