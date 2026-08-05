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
    private let eventScopeID: String?
    /// Deterministic regression seam for the narrow interval after process
    /// configuration and before the turn continuation is registered.
    private let turnProcessEnsuredForTesting: (() -> Void)?
    /// Invalidates asynchronous warm-up tasks that have not acquired the turn
    /// gate yet. This prevents `warmUp(); stop()` from resurrecting a process.
    private var warmUpGeneration: UInt64 = 0
    /// Claude pins `--session-id`, model, effort, and system prompt at process launch.
    /// Keyed conversations therefore get independent child bridges/processes;
    /// the unkeyed path continues to use this bridge's original process.
    private var conversationBridges: [String: ClaudeBridge] = [:]
    /// Releasing a keyed conversation blocks late work from recreating its
    /// child. Only a later explicit warm-up registration clears the marker.
    private var tombstonedConversationIDs = Set<String>()
    private var process: Process?
    /// Invalidates stdout chunks already queued by a retired child. Clearing a
    /// readability handler cannot retract a callback that has already copied
    /// bytes, so every delivery must also prove it belongs to the live process.
    private var processGeneration: UInt64 = 0
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    /// Set only on a keyed child after its owning conversation is released.
    /// Prevents queued/racing work from restarting an orphaned process.
    private var isReleased = false
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
    /// Canonical native `--effort` value for the live process. Nil means the
    /// flag was omitted so Claude applies its own default.
    private var currentEffort: String?
    private var currentSystemPrompt: String?
    private var currentWorkingDirectory: String?
    private var currentProfile: AgentExecutionProfile?
    /// One continuation is active at a time. `AgentTurnGate` serializes
    /// callers because Claude's result envelopes do not echo a client turn id.
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var currentTurnID: String?
    private var assistantAccumulator = ""
    /// Live answer callback for the in-flight turn (throttled), so the UI
    /// can show partial text instead of looking hung.
    private var onPartial: ((String) -> Void)?
    /// Reports tool calls as they happen so the transcript can show tool cards
    /// rather than a log line. Delivered on the main queue.
    var onToolEvent: ((AssistantToolEvent) -> Void)?
    private var lastPartialAt: Double = 0
    /// Uptime when the current turn's message was written — for phase timing.
    private var turnStartUptime: Double = 0
    /// Uptime of the latest provider event that proves the turn is progressing.
    /// The configured timeout is an inactivity budget, not a wall-clock cap:
    /// agentic turns may legitimately spend minutes reading and using tools.
    private var lastTurnActivityUptime: Double = 0
    private var sawFirstTextThisTurn = false
    private var stdoutBuffer = Data()

    var isRunning: Bool {
        let state = queue.sync {
            (process?.isRunning == true, Array(conversationBridges.values))
        }
        return state.0 || state.1.contains { $0.isRunning }
    }

    init(
        executableURL: URL? = nil,
        mcpExecutableURL: URL? = nil,
        eventScopeID: String? = nil,
        turnProcessEnsuredForTesting: (() -> Void)? = nil
    ) {
        self.executableURLOverride = executableURL
        self.mcpExecutableURLOverride = mcpExecutableURL
        self.eventScopeID = eventScopeID
        self.turnProcessEnsuredForTesting = turnProcessEnsuredForTesting
    }

    // MARK: - Public API

    /// Spawn the CLI process ahead of the first real turn so its cold
    /// start (Node init, MCP-server boot, session-start hooks) overlaps
    /// with the user still typing their question. Idempotent — a no-op
    /// once the process is live. This is the openclicky trick: warm on
    /// interaction, so the first ask isn't the one paying spawn cost.
    func warmUp(
        system: String,
        model: String? = nil,
        effort: String = "Auto",
        conversationID: String? = nil,
        cwd: String? = nil,
        profile: AgentExecutionProfile = .workspaceChat
    ) {
        if let conversationID {
            registerConversationBridge(for: conversationID).warmUpLocally(
                system: system, model: model, effort: effort, cwd: cwd,
                profile: profile)
            return
        }
        warmUpLocally(
            system: system, model: model, effort: effort, cwd: cwd,
            profile: profile)
    }

    private func warmUpLocally(
        system: String,
        model: String?,
        effort: String,
        cwd: String?,
        profile: AgentExecutionProfile
    ) {
        let generation = queue.sync { () -> UInt64? in
            guard !isReleased else { return nil }
            warmUpGeneration &+= 1
            return warmUpGeneration
        }
        guard let generation else { return }
        // Warm-up must share the same FIFO gate as real turns. Otherwise it
        // can replace the process after a turn has configured it but before
        // that turn registers its continuation on the bridge queue.
        Task { [weak self] in
            guard let self else { return }
            await self.turnGate.acquire()
            if self.queue.sync(execute: {
                !self.isReleased && self.warmUpGeneration == generation
            }) {
                try? self.ensureProcess(
                    system: system, model: model, effort: effort, cwd: cwd,
                    profile: profile)
            }
            await self.turnGate.release()
        }
    }

    /// Run a single, blocking turn against the warm bridge. Lazy-sprawls
    /// (sic). Returns the assistant's final `result` text.
    func turn(prompt: String, system: String, model: String? = nil,
              effort: String = "Auto",
              timeout: TimeInterval =
                AssistantTurnTimeoutPolicy.defaultInactivitySeconds,
              conversationID: String? = nil,
              cwd: String? = nil,
              profile: AgentExecutionProfile = .workspaceChat,
              onPartial: ((String) -> Void)? = nil) async throws -> String {
        if let conversationID {
            return try await conversationBridgeForTurn(
                for: conversationID
            ).turnLocally(
                prompt: prompt,
                system: system,
                model: model,
                effort: effort,
                cwd: cwd,
                profile: profile,
                timeout: timeout,
                onPartial: onPartial)
        }
        return try await turnLocally(
            prompt: prompt,
            system: system,
            model: model,
            effort: effort,
            cwd: cwd,
            profile: profile,
            timeout: timeout,
            onPartial: onPartial)
    }

    private func turnLocally(
        prompt: String,
        system: String,
        model: String?,
        effort: String,
        cwd: String?,
        profile: AgentExecutionProfile,
        timeout: TimeInterval,
        onPartial: ((String) -> Void)?
    ) async throws -> String {
        // A real turn supersedes any queued speculative warm-up. If warm-up
        // already owns the gate it finishes first; otherwise it becomes inert.
        queue.sync { warmUpGeneration &+= 1 }
        await turnGate.acquire()
        do {
            try Task.checkCancellation()
            try ensureLocallyActive()
            let result = try await performTurn(
                prompt: prompt, system: system, model: model, effort: effort,
                cwd: cwd,
                profile: profile, timeout: timeout, onPartial: onPartial)
            await turnGate.release()
            return result
        } catch {
            await turnGate.release()
            throw error
        }
    }

    /// Cancel a keyed conversation's active turn. Claude result envelopes do
    /// not carry a client turn id, so safely cancelling requires terminating
    /// only that conversation's child process.
    func cancelConversation(_ conversationID: String) {
        existingConversationBridge(for: conversationID)?.stopLocally()
    }

    /// Cancel and forget a keyed conversation. A later explicit warm-up
    /// registration gets a fresh process and Claude session id; a racing turn
    /// remains cancelled.
    func releaseConversation(_ conversationID: String) {
        let bridge = queue.sync {
            tombstonedConversationIDs.insert(conversationID)
            return conversationBridges.removeValue(forKey: conversationID)
        }
        bridge?.releaseLocally()
    }

    private func performTurn(
        prompt: String, system: String, model: String?, effort: String,
        cwd: String?,
        profile: AgentExecutionProfile, timeout: TimeInterval,
        onPartial: ((String) -> Void)? = nil
    ) async throws -> String {
        try ensureProcess(
            system: system, model: model, effort: effort, cwd: cwd,
            profile: profile)
        turnProcessEnsuredForTesting?()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let turnID = UUID().uuidString
                queue.async { [weak self] in
                    guard let self else {
                        cont.resume(throwing: CancellationError()); return
                    }
                    guard !self.isReleased else {
                        cont.resume(throwing: CancellationError()); return
                    }
                    let warm = self.process?.isRunning == true
                    PetLog.log("ClaudeBridge.turn start turn=\(turnID.prefix(8)) warm=\(warm)")
                    self.currentTurnID = turnID
                    self.turnStartUptime = ProcessInfo.processInfo.systemUptime
                    self.lastTurnActivityUptime = self.turnStartUptime
                    self.sawFirstTextThisTurn = false
                    self.assistantAccumulator = ""
                    self.onPartial = onPartial
                    self.lastPartialAt = 0
                    self.pending[turnID] = cont
                    self.writeUserMessage(turnID: turnID, text: prompt)
                    self.scheduleInactivityTimeout(
                        turnID: turnID, timeout: timeout)
                }
            }
        }, onCancel: { [weak self] in
            self?.queue.async {
                guard let self, let id = self.currentTurnID,
                      let pending = self.pending.removeValue(forKey: id) else { return }
                self.currentTurnID = nil
                PetLog.log("ClaudeBridge.onCancel — Task was cancelled turn=\(id.prefix(8))")
                // Same reasoning as the timeout path: discard the child so a
                // late result from this cancelled turn can't resolve the next.
                self.teardownLocked()
                pending.resume(throwing: CancellationError())
            }
        })
    }

    /// Re-check at the end of each inactivity window. Meaningful provider
    /// activity moves the deadline forward; a silent child is still torn down
    /// so its uncorrelated late result cannot resolve a later turn.
    private func scheduleInactivityTimeout(
        turnID: String,
        timeout: TimeInterval
    ) {
        let budget = max(timeout, 0.001)
        let firstCheck = min(
            budget, AssistantTurnTimeoutPolicy.maximumTurnDurationSeconds)
        queue.asyncAfter(deadline: .now() + firstCheck) { [weak self] in
            self?.enforceInactivityTimeout(turnID: turnID, timeout: budget)
        }
    }

    private func enforceInactivityTimeout(
        turnID: String,
        timeout: TimeInterval
    ) {
        guard let pending = pending[turnID] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let idleFor = now - lastTurnActivityUptime
        let elapsed = now - turnStartUptime
        let reachedSafetyLimit = elapsed
            >= AssistantTurnTimeoutPolicy.maximumTurnDurationSeconds
        if !reachedSafetyLimit, idleFor < timeout {
            let delay = min(
                max(timeout - idleFor, 0.001),
                max(
                    AssistantTurnTimeoutPolicy.maximumTurnDurationSeconds
                        - elapsed,
                    0.001))
            queue.asyncAfter(
                deadline: .now() + delay
            ) { [weak self] in
                self?.enforceInactivityTimeout(
                    turnID: turnID, timeout: timeout)
            }
            return
        }
        self.pending.removeValue(forKey: turnID)
        if currentTurnID == turnID { currentTurnID = nil }
        PetLog.log(String(
            format: "ClaudeBridge.%@ idle=%.1fs elapsed=%.1fs turn=%@",
            reachedSafetyLimit ? "maximum-duration" : "inactivity-timeout",
            idleFor, elapsed, String(turnID.prefix(8))))
        // Claude result envelopes carry no client turn id. Discard the child
        // so a late result cannot be mistaken for the next turn's answer.
        teardownLocked()
        pending.resume(throwing: reachedSafetyLimit
            ? ClaudeBridgeError.maximumDurationExceeded
            : ClaudeBridgeError.turnTimeout)
    }

    func stop() {
        let children = queue.sync { () -> [ClaudeBridge] in
            let values = Array(conversationBridges.values)
            conversationBridges.removeAll()
            return values
        }
        for child in children { child.releaseLocally() }
        stopLocally()
    }

    private func stopLocally() {
        queue.sync {
            warmUpGeneration &+= 1
            teardownLocked()
        }
    }

    private func releaseLocally() {
        queue.sync {
            isReleased = true
            warmUpGeneration &+= 1
            teardownLocked()
        }
    }

    private func ensureLocallyActive() throws {
        if queue.sync(execute: { isReleased }) {
            throw CancellationError()
        }
    }

    /// Must be called on `queue`.
    private func teardownLocked() {
        processGeneration &+= 1
        if !pending.isEmpty {
            PetLog.log("ClaudeBridge.teardown WITH \(pending.count) pending turn(s) — will cancel them")
        }
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        currentModel = nil
        currentEffort = nil
        currentSystemPrompt = nil
        currentWorkingDirectory = nil
        currentProfile = nil
        stdoutBuffer.removeAll()
        onPartial = nil
        for (_, c) in pending { c.resume(throwing: CancellationError()) }
        pending.removeAll()
        currentTurnID = nil
    }

    deinit { stop() }

    private func registerConversationBridge(
        for conversationID: String
    ) -> ClaudeBridge {
        queue.sync {
            tombstonedConversationIDs.remove(conversationID)
            if let bridge = conversationBridges[conversationID] {
                bridge.onToolEvent = onToolEvent
                return bridge
            }
            let bridge = ClaudeBridge(
                executableURL: executableURLOverride,
                mcpExecutableURL: mcpExecutableURLOverride,
                eventScopeID: conversationID)
            bridge.onToolEvent = onToolEvent
            conversationBridges[conversationID] = bridge
            return bridge
        }
    }

    private func conversationBridgeForTurn(
        for conversationID: String
    ) throws -> ClaudeBridge {
        try queue.sync {
            if tombstonedConversationIDs.contains(conversationID) {
                throw CancellationError()
            }
            if let bridge = conversationBridges[conversationID] {
                bridge.onToolEvent = onToolEvent
                return bridge
            }
            let bridge = ClaudeBridge(
                executableURL: executableURLOverride,
                mcpExecutableURL: mcpExecutableURLOverride,
                eventScopeID: conversationID)
            bridge.onToolEvent = onToolEvent
            conversationBridges[conversationID] = bridge
            return bridge
        }
    }

    private func existingConversationBridge(
        for conversationID: String
    ) -> ClaudeBridge? {
        queue.sync { conversationBridges[conversationID] }
    }

    // MARK: - Process

    private func ensureProcess(
        system: String,
        model: String?,
        effort: String,
        cwd: String?,
        profile: AgentExecutionProfile
    ) throws {
        try queue.sync {
            if isReleased { throw CancellationError() }
            let resolvedModel = model ?? Self.defaultModel
            let resolvedEffort = NativeReasoningEffort.claudeValue(effort)
            let resolvedCWD = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
            let workingDirectory = resolvedCWD?.isEmpty == false
                ? resolvedCWD!
                : FileManager.default.currentDirectoryPath
            if process?.isRunning == true {
                if currentModel == resolvedModel,
                   currentEffort == resolvedEffort,
                   currentSystemPrompt == system,
                   currentWorkingDirectory == workingDirectory,
                   currentProfile == profile { return }
                // A turn is in flight on this process — tearing it down here
                // would resume its continuation with CancellationError (this
                // was the "Claude: …CancellationError" the sidebar showed when
                // an ungated warmUp/prewarm raced a running turn). Leave the
                // live turn alone; reconfiguration happens once it's idle.
                if !pending.isEmpty { return }
                // Model and system prompt are pinned at process launch.
                teardownLocked()
            } else if process != nil {
                if !pending.isEmpty { return }
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
            p.currentDirectoryURL = URL(
                fileURLWithPath: workingDirectory, isDirectory: true)
            var args: [String] = [
                "--print",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--verbose",
                "--model", resolvedModel,
                "--system-prompt", system,
                "--session-id", sessionID,
                // Skip the user's GLOBAL settings (SessionStart hooks, plugin
                // sync, auto-memory, CLAUDE.md discovery) — measured at
                // ~25-30s of pure cold-start overhead on a heavy config. The
                // embedded assistant is fully self-configured (model, system
                // prompt, MCP, permissions all explicit), and OAuth lives in
                // the keychain, so it stays authed. Cannot use `--bare` (it
                // forces API-key auth and never reads OAuth). Opt back in to
                // the full config with INFINITTY_AI_FULL_SETTINGS=1.
                "--setting-sources",
                ProcessInfo.processInfo.environment["INFINITTY_AI_FULL_SETTINGS"] == "1"
                    ? "user,project,local" : "project,local",
                // Native and MCP tools are selected below from the explicit
                // execution profile. INFINITTY_AI_ALLOW_SHELL=1 retains the
                // legacy escape hatch that skips these native-tool filters.
            ]
            if let resolvedEffort {
                args += ["--effort", resolvedEffort]
            }
            let mcpURL = mcpExecutableURLOverride
                ?? MCPConfiguration.mcpExecutablePath().map(URL.init(fileURLWithPath:))
            let permissionPromptTool = MCPConfiguration.claudePermissionPromptToolName
            let usesApprovalBroker = mcpURL != nil
                && eventScopeID?.isEmpty == false
                && !ProviderPermissionPolicy.allowsDangerBypass()
            if ProcessInfo.processInfo.environment["INFINITTY_AI_ALLOW_SHELL"] != "1" {
                switch profile {
                case .workspaceChat:
                    // Workspace Chat is a real coding agent. Keep Claude's
                    // native file/search/edit and Bash tools available, while
                    // excluding unrelated network/delegation surfaces.
                    args += [
                        "--settings",
                        #"{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true,"allowUnsandboxedCommands":false}}"#,
                        "--allowedTools",
                        "Read Write Edit Glob Grep Bash BashOutput KillShell"
                            + (usesApprovalBroker ? " \(permissionPromptTool)" : ""),
                        "--disallowedTools", "WebFetch WebSearch Task TodoWrite",
                    ]
                case .visibleTerminal:
                    // Terminal mode performs shell/interactive work through
                    // the attached visible pane. Native file editing remains
                    // available, but hidden subprocess shell tools do not.
                    args += [
                        "--allowedTools", "Read Write Edit Glob Grep"
                            + (usesApprovalBroker ? " \(permissionPromptTool)" : ""),
                        "--disallowedTools",
                        "Bash BashOutput KillShell WebFetch WebSearch Task TodoWrite",
                    ]
                }
            } else if usesApprovalBroker {
                // `--allowedTools` grants this callback tool without limiting
                // the legacy shell escape hatch's wider tool surface.
                args += ["--allowedTools", permissionPromptTool]
            }
            args += ProviderPermissionPolicy.claudePermissionArguments()
            if usesApprovalBroker {
                args += ["--permission-prompt-tool", permissionPromptTool]
            }
            if let mcpURL,
               let data = MCPConfiguration.claudeMCPJSON(
                   binaryPath: mcpURL.path,
                   appSocketPath: AppControlServer.ownSocketPath,
                   profile: profile,
                   assistantScopeID: eventScopeID),
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
            // Belt-and-suspenders alongside the MCP config `env`: the spawned
            // infinitty-mcp inherits this and targets THIS instance's socket.
            env["INFINITTY_APP_SOCKET"] = AppControlServer.ownSocketPath
            env["INFINITTY_MCP_PROFILE"] = profile.rawValue
            if let eventScopeID, !eventScopeID.isEmpty {
                env["INFINITTY_ASSISTANT_SCOPE"] = eventScopeID
            }
            p.environment = env
            PetLog.log("ClaudeBridge.spawn model=\(resolvedModel) (cold start begins)")
            p.terminationHandler = { [weak self] proc in
                self?.queue.async {
                    guard let self, self.process === proc else { return }
                    self.processGeneration &+= 1
                    PetLog.log("ClaudeBridge.childExit status=\(proc.terminationStatus) pending=\(self.pending.count)")
                    self.stdoutHandle?.readabilityHandler = nil
                    self.stderrHandle?.readabilityHandler = nil
                    self.process = nil
                    self.currentModel = nil
                    self.currentEffort = nil
                    self.currentSystemPrompt = nil
                    self.currentWorkingDirectory = nil
                    self.currentProfile = nil
                    for (_, continuation) in self.pending {
                        continuation.resume(throwing: ClaudeBridgeError.processUnavailable(
                            "Claude bridge exited (\(proc.terminationStatus))."))
                    }
                    self.pending.removeAll()
                    self.onPartial = nil
                    self.currentTurnID = nil
                }
            }
            try p.run()
            self.process = p
            let generation = self.processGeneration
            self.currentModel = resolvedModel
            self.currentEffort = resolvedEffort
            self.currentSystemPrompt = system
            self.currentWorkingDirectory = workingDirectory
            self.currentProfile = profile
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
                    guard let self,
                          self.processGeneration == generation
                    else {
                        PetLog.log(
                            "ClaudeBridge.drop stale stdout generation=\(generation)")
                        return
                    }
                    self.consumeStdout(data)
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
        // `write(contentsOf:)` throws a catchable error if the child died and
        // the pipe broke (EPIPE); the legacy `write(_:)` raises an uncatchable
        // NSException that would crash the whole app.
        try? h.write(contentsOf: data)
        try? h.write(contentsOf: Data([0x0A]))
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
        if currentTurnID != nil,
           type == "assistant" || type == "user" || type == "system" {
            lastTurnActivityUptime = ProcessInfo.processInfo.systemUptime
        }
        switch type {
        case "assistant":
            if let message = event["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                let dt = ProcessInfo.processInfo.systemUptime - turnStartUptime
                for block in content {
                    let kind = block["type"] as? String
                    if kind == "text", let text = block["text"] as? String {
                        if !sawFirstTextThisTurn, !text.isEmpty {
                            sawFirstTextThisTurn = true
                            PetLog.log(String(format: "ClaudeBridge.first-text at +%.1fs", dt))
                        }
                        // Each text block is a complete narration segment
                        // (tool calls sit between them); a blank line makes
                        // it a Markdown paragraph instead of gluing segments.
                        assistantAccumulator += text
                        assistantAccumulator += "\n\n"
                        emitPartialThrottled()
                    } else if kind == "tool_use" {
                        let name = block["name"] as? String ?? "?"
                        PetLog.log(String(format: "ClaudeBridge.toolcall %@ at +%.1fs", name, dt))
                        let id = block["id"] as? String ?? UUID().uuidString
                        let input = block["input"].flatMap { value -> String? in
                            guard JSONSerialization.isValidJSONObject(value),
                                  let data = try? JSONSerialization.data(
                                      withJSONObject: value,
                                      options: [.prettyPrinted, .sortedKeys])
                            else { return nil }
                            return String(data: data, encoding: .utf8)
                        }
                        let event = AssistantToolEvent(
                            id: id,
                            name: name,
                            state: .running,
                            input: input,
                            scopeID: eventScopeID)
                        if let onToolEvent {
                            DispatchQueue.main.async { onToolEvent(event) }
                        }
                        AssistantToolEventBus.publish(event)
                    }
                }
            }
        case "user":
            // Tool results come back as a synthetic user turn. Without this the
            // matching call would sit at `.running` for ever.
            if let message = event["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "tool_result" {
                    guard let id = block["tool_use_id"] as? String else { continue }
                    let failed = (block["is_error"] as? Bool) ?? false
                    let text: String?
                    if let raw = block["content"] as? String {
                        text = raw
                    } else if let parts = block["content"] as? [[String: Any]] {
                        text = parts.compactMap { $0["text"] as? String }
                            .joined(separator: "\n")
                    } else {
                        text = nil
                    }
                    AssistantToolEventBus.publish(
                        AssistantToolEvent(
                            id: id,
                            name: "",
                            state: failed ? .failed : .completed,
                            output: failed ? nil : text,
                            errorText: failed ? text : nil,
                            scopeID: eventScopeID))
                }
            }
        case "result":
            handleResult(event)
        default:
            break
        }
    }

    /// Throttle live partial callbacks to ~10/s so the UI isn't flooded.
    /// Must be called on `queue`.
    private func emitPartialThrottled() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPartialAt > 0.1, let onPartial else { return }
        lastPartialAt = now
        let snapshot = assistantAccumulator
        DispatchQueue.main.async { onPartial(snapshot) }
    }

    private func handleResult(_ event: [String: Any]) {
        guard let turnID = currentTurnID,
              let continuation = pending.removeValue(forKey: turnID)
        else { return }
        currentTurnID = nil
        onPartial = nil
        let subtype = event["subtype"] as? String ?? ""
        let dt = ProcessInfo.processInfo.systemUptime - turnStartUptime
        PetLog.log(String(format: "ClaudeBridge.turn DONE in %.1fs subtype=%@", dt, subtype))
        switch subtype {
        case "success":
            // Prefer the explicit `result` field; fall back to the
            // accumulator so we never return empty for a successful turn.
            let explicit = (event["result"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let accumulated = assistantAccumulator
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !explicit.isEmpty {
                continuation.resume(returning: explicit)
            } else if !accumulated.isEmpty {
                continuation.resume(returning: accumulated)
            } else {
                // A "success" with no text at all is a silent dead turn —
                // surface it as a failure instead of an empty bubble.
                continuation.resume(throwing: ClaudeBridgeError.rpcError(
                    "Claude returned an empty response."))
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
    case maximumDurationExceeded

    var errorDescription: String? {
        switch self {
        case .processUnavailable(let m), .rpcError(let m): return m
        case .turnTimeout:
            return "Claude was inactive for the configured turn timeout."
        case .maximumDurationExceeded:
            return "Claude reached the 30-minute turn safety limit."
        }
    }
}
