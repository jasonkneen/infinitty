import Foundation

/// Long-lived `codex app-server` bridge. One process per infinitty instance,
/// kept warm across turns so the user pays the cold-start cost (Node init,
/// MCP server load, container warmup) **once** instead of every pet-ask.
///
/// Modelled on openclicky's `CodexProcessManager` but trimmed to the
/// surface infinitty actually needs:
///   - lazy warmup on first use (don't burn ~700ms at launch)
///   - a single-threaded stream reducer that turns `item/agentMessage/delta`
///     notifications into a final `String` for `PetAssistant`
///   - safety on teardown (kills stale continuations so a wedged app-server
///     can't park the pet-assistant lane forever)
///
/// Streaming text only — we don't proxy tool calls. The launch injects the
/// bundled `infinitty-mcp` into Codex's config, so app-server's MCP runtime
/// handles terminal tools out-of-process.
final class CodexAppServer: @unchecked Sendable {
    /// Item types that are the conversation itself rather than work the agent
    /// did. Observed the hard way: `userMessage` rendered as a tool card until
    /// it showed up on screen.
    static let conversationalItemTypes: Set<String> = [
        "agentMessage", "userMessage", "reasoning", "todoList",
    ]

    static let shared = CodexAppServer(profile: .workspaceChat)
    static let visibleTerminalShared = CodexAppServer(profile: .visibleTerminal)

    static func server(for profile: AgentExecutionProfile) -> CodexAppServer {
        profile == .visibleTerminal ? visibleTerminalShared : shared
    }

    // MARK: - State

    private let queue = DispatchQueue(label: "infinitty.codex.app-server")
    private let initializationGate = AgentTurnGate()
    private let executableURLOverride: URL?
    private let mcpExecutableURLOverride: URL?
    let profile: AgentExecutionProfile
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    /// Active turn reducers. Keyed by turn id; one per in-flight `turn/start`.
    private var activeTurns: [String: TurnReducer] = [:]
    /// Locally cancelled/timed-out turns must not be re-buffered if the
    /// app-server sends late notifications before acknowledging interruption.
    private var discardedTurnIDs = Set<String>()
    /// Notifications can share a pipe read with the `turn/start` response.
    /// Buffer them until the async caller has installed its reducer.
    private var earlyTurnMessages: [String: [[String: Any]]] = [:]
    private var pendingIdleThreadIDs = Set<String>()
    /// A caller-provided conversation id owns one Codex thread and one FIFO
    /// gate. The legacy key preserves the pre-existing no-id call path.
    private enum ConversationKey: Hashable {
        case legacy
        case identified(String)
    }
    private final class ConversationContext: @unchecked Sendable {
        let token = UUID()
        let turnGate = AgentTurnGate()
        let scopeID: String?
        var threadID: String?
        var model: String?
        var cwd: String?
        var isReleased = false
        var cancellationGeneration = 0

        init(scopeID: String?) {
            self.scopeID = scopeID
        }
    }
    private var conversations: [ConversationKey: ConversationContext] = [:]
    /// Explicit release is a lifecycle tombstone, not just dictionary
    /// removal. A late keyed `turn` must not recreate released state; only
    /// the next explicit `warmUp` registration may clear this marker.
    private var tombstonedConversationIDs = Set<String>()
    /// Whether the JSON-RPC initialize handshake has completed.
    private var hasInitialized = false

    var isRunning: Bool { queue.sync { process?.isRunning == true } }

    init(
        executableURL: URL? = nil,
        mcpExecutableURL: URL? = nil,
        profile: AgentExecutionProfile = .workspaceChat
    ) {
        self.executableURLOverride = executableURL
        self.mcpExecutableURLOverride = mcpExecutableURL
        self.profile = profile
    }

    // MARK: - Public API

    /// Start a turn against the active thread, returning the assistant's
    /// final reply. Creates the thread on first use, handshakes the
    /// initialize step lazily, and reuses the live connection for every
    /// subsequent call.
    func turn(
        prompt: String,
        cwd: String,
        model: String,
        effort: String = "medium",
        timeout: TimeInterval =
            AssistantTurnTimeoutPolicy.defaultInactivitySeconds,
        conversationID: String? = nil,
        onPartial: ((String) -> Void)? = nil
    ) async throws -> String {
        let context = try conversationContextForTurn(for: conversationID)
        await context.turnGate.acquire()
        do {
            try Task.checkCancellation()
            let generation = queue.sync { context.cancellationGeneration }
            try ensureContextIsActive(context, generation: generation)
            try ensureProcess()
            let threadID = try await ensureThread(
                model: model, cwd: cwd, context: context)
            try ensureContextIsActive(context, generation: generation)
            let turnID = try await startTurn(
                threadID: threadID,
                prompt: prompt,
                cwd: cwd,
                effort: effort,
                context: context,
                generation: generation,
                onPartial: onPartial)
            try ensureContextIsActive(context, generation: generation)
            let result = try await awaitTurn(turnID: turnID, timeout: timeout)
            await context.turnGate.release()
            return result
        } catch {
            await context.turnGate.release()
            throw error
        }
    }

    /// Spawn the app-server and open the thread ahead of the first real
    /// turn so its cold start (Node init + booting the ~/.codex MCP
    /// servers) overlaps with the user still typing. Idempotent. This is
    /// the openclicky trick — warm on interaction, not on first ask.
    func warmUp(
        model: String,
        conversationID: String? = nil,
        cwd: String? = nil
    ) {
        let context = registerConversationContext(for: conversationID)
        try? ensureProcess()
        Task { [weak self] in
            guard let self else { return }
            await context.turnGate.acquire()
            if (try? self.ensureContextIsActive(context)) != nil {
                let workingDirectory = cwd?.isEmpty == false
                    ? cwd!
                    : FileManager.default.currentDirectoryPath
                _ = try? await self.ensureThread(
                    model: model, cwd: workingDirectory, context: context)
            }
            await context.turnGate.release()
        }
    }

    /// Cancel the active turn for one keyed conversation while retaining its
    /// Codex thread for a later turn.
    func cancelConversation(_ conversationID: String) {
        cancelConversation(key: .identified(conversationID), release: false)
    }

    /// Forget one keyed conversation and cancel any turn it still owns. A
    /// later explicit `warmUp` registration with the same id starts a fresh
    /// Codex thread. A racing `turn` cannot silently recreate it.
    func releaseConversation(_ conversationID: String) {
        cancelConversation(key: .identified(conversationID), release: true)
    }

    /// Ask the app-server which models this account actually has. One RPC on
    /// the already-warm process, so opening the model menu costs no spawn.
    /// The result carries per-model reasoning efforts, which is what lets the
    /// effort chip follow the selected model.
    func listModels() async throws -> [String: Any] {
        try ensureProcess()
        return try await sendRequest(method: "model/list", params: [:])
    }

    /// Tear the bridge down. Called from `deinit`; safe to invoke multiple
    /// times. Any in-flight turn awaits fail with `CancellationError`.
    func stop() {
        queue.sync {
            stdoutHandle?.readabilityHandler = nil
            stderrHandle?.readabilityHandler = nil
            try? stdinHandle?.close()
            stdinHandle = nil
            stdoutHandle = nil
            stderrHandle = nil
            if process?.isRunning == true { process?.terminate() }
            process = nil
            hasInitialized = false
            for context in conversations.values { context.isReleased = true }
            conversations.removeAll()
            for (_, continuation) in pending {
                continuation.resume(throwing: CancellationError())
            }
            pending.removeAll()
            for (_, reducer) in activeTurns {
                reducer.fail(CancellationError())
            }
            activeTurns.removeAll()
            discardedTurnIDs.removeAll()
            earlyTurnMessages.removeAll()
            pendingIdleThreadIDs.removeAll()
        }
    }

    deinit { stop() }

    // MARK: - Process management

    private func ensureProcess() throws {
        try queue.sync {
            if process?.isRunning == true { return }
            if process != nil {
                process = nil
                stdinHandle = nil
                stdoutHandle = nil
                stderrHandle = nil
                hasInitialized = false
                for context in conversations.values {
                    context.threadID = nil
                    context.model = nil
                    context.cwd = nil
                }
            }
            guard let executable = executableURLOverride
                    ?? CLIExecutableResolver.resolve(.codex) else {
                throw CodexBridgeError.processUnavailable(
                    "Codex CLI not found on PATH; install it or set "
                    + "INFINITTY_CODEX_EXECUTABLE.")
            }
            let p = Process()
            p.executableURL = executable
            var arguments = [
                "app-server", "--listen", "stdio://",
                "-c", "approval_policy=never",
                // `never` fails requests that need escalation. The sandbox
                // stays workspace-scoped unless danger bypass is explicitly
                // opted into for this process.
                "-c", "sandbox_mode=\(ProviderPermissionPolicy.codexSandboxMode())",
            ]
            let mcpURL = mcpExecutableURLOverride
                ?? MCPConfiguration.mcpExecutablePath().map(URL.init(fileURLWithPath:))
            if let mcpURL {
                // Inject the app's own terminal-control MCP server for this
                // bridge without requiring a persistent user config edit, and
                // pin it to THIS instance's control socket.
                for override in MCPConfiguration.codexConfigOverrides(
                    binaryPath: mcpURL.path,
                    appSocketPath: AppControlServer.ownSocketPath,
                    profile: profile) {
                    arguments += ["-c", override]
                }
            }
            p.arguments = arguments
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            p.standardInput = stdin
            p.standardOutput = stdout
            p.standardError = stderr
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
            // Belt-and-suspenders alongside the `-c ...env...` override: the
            // spawned infinitty-mcp inherits this and targets THIS instance.
            env["INFINITTY_APP_SOCKET"] = AppControlServer.ownSocketPath
            env["INFINITTY_MCP_PROFILE"] = profile.rawValue
            p.environment = env
            p.terminationHandler = { [weak self] proc in
                self?.queue.async {
                    guard let self, self.process === proc else { return }
                    self.stdoutHandle?.readabilityHandler = nil
                    self.stderrHandle?.readabilityHandler = nil
                    self.process = nil
                    self.hasInitialized = false
                    for context in self.conversations.values {
                        context.threadID = nil
                        context.model = nil
                        context.cwd = nil
                    }
                    for (_, continuation) in self.pending {
                        continuation.resume(throwing: CodexBridgeError.processUnavailable(
                            "Codex app-server exited (\(proc.terminationStatus))."))
                    }
                    self.pending.removeAll()
                    for (_, reducer) in self.activeTurns {
                        reducer.fail(CodexBridgeError.processUnavailable(
                            "Codex app-server exited mid-turn."))
                    }
                    self.activeTurns.removeAll()
                    self.discardedTurnIDs.removeAll()
                    self.earlyTurnMessages.removeAll()
                    self.pendingIdleThreadIDs.removeAll()
                }
            }
            try p.run()
            self.process = p
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
            // Drain stderr even though we don't surface it: the app-server
            // writes tracing there, and an undrained 64 KB pipe eventually
            // blocks the child mid-write, wedging the whole bridge.
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
            }
        }
    }

    // MARK: - JSON-RPC

    private func ensureThread(
        model: String,
        cwd: String,
        context: ConversationContext
    ) async throws -> String {
        let cached: String? = queue.sync {
            guard !context.isReleased,
                  context.model == model,
                  context.cwd == cwd
            else { return nil }
            return context.threadID
        }
        if let cached { return cached }
        let threadStart = try await sendRequest(method: "thread/start", params: [
            "model": model,
            "cwd": cwd,
        ])
        guard let id = (threadStart["thread"] as? [String: Any])?["id"] as? String else {
            throw CodexBridgeError.protocolViolation(
                "thread/start did not return a thread id.")
        }
        let stored = queue.sync { () -> Bool in
            guard !context.isReleased else { return false }
            context.threadID = id
            context.model = model
            context.cwd = cwd
            return true
        }
        guard stored else { throw CancellationError() }
        return id
    }

    private func startTurn(
        threadID: String,
        prompt: String,
        cwd: String,
        effort: String,
        context: ConversationContext,
        generation: Int,
        onPartial: ((String) -> Void)?
    ) async throws -> String {
        let input: [[String: Any]] = [["type": "text", "text": prompt]]
        _ = queue.sync { pendingIdleThreadIDs.remove(threadID) }
        let sandboxPolicy: [String: Any] =
            ProviderPermissionPolicy.codexSandboxMode() == "danger-full-access"
            ? ["type": "dangerFullAccess"]
            : ["type": "workspaceWrite", "writableRoots": [] as [String],
               "networkAccess": false, "excludeTmpdirEnvVar": false,
               "excludeSlashTmp": false]
        let turnResponse = try await sendRequest(method: "turn/start", params: [
            "threadId": threadID,
            "input": input,
            "cwd": cwd,
            "approvalPolicy": "never",
            "sandboxPolicy": sandboxPolicy,
            "effort": effort,
        ])
        guard let id = (turnResponse["turn"] as? [String: Any])?["id"] as? String else {
            throw CodexBridgeError.protocolViolation("turn/start returned no turn id.")
        }
        let installed = queue.sync { () -> Bool in
            guard !context.isReleased,
                  context.cancellationGeneration == generation else {
                earlyTurnMessages.removeValue(forKey: id)
                return false
            }
            let reducer = TurnReducer(
                turnID: id,
                threadID: threadID,
                conversationToken: context.token,
                scopeID: context.scopeID,
                onPartial: onPartial)
            activeTurns[id] = reducer
            let buffered = earlyTurnMessages.removeValue(forKey: id) ?? []
            for message in buffered { handleMessage(message) }
            if pendingIdleThreadIDs.remove(threadID) != nil,
               !reducer.isFinished, !reducer.snapshot().isEmpty {
                reducer.finish(reducer.snapshot())
            }
            return true
        }
        guard installed else {
            interruptTurn(threadID: threadID, turnID: id)
            throw CancellationError()
        }
        return id
    }

    private func awaitTurn(turnID: String, timeout: TimeInterval) async throws -> String {
        let reducer = queue.sync { activeTurns[turnID] }
        guard let reducer else { throw CodexBridgeError.protocolViolation("no reducer for \(turnID)") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                reducer.attach { result in
                    self.queue.async {
                        self.activeTurns.removeValue(forKey: turnID)
                    }
                    switch result {
                    case .success(let text): cont.resume(returning: text)
                    case .failure(let err):  cont.resume(throwing: err)
                    }
                }
                self.scheduleInactivityTimeout(
                    reducer: reducer, timeout: max(timeout, 0.001))
            }
        } onCancel: {
            self.queue.async {
                if let r = self.activeTurns[turnID] {
                    r.fail(CancellationError())
                    self.activeTurns.removeValue(forKey: turnID)
                    self.discardLateNotifications(for: turnID)
                    self.interruptTurn(threadID: r.threadID, turnID: turnID)
                }
            }
        }
    }

    /// Treat the configured turn timeout as an inactivity budget. Agentic
    /// Codex runs may legitimately exceed it while continuing to emit tool,
    /// usage, summary, or answer events. A separate absolute cap prevents an
    /// endlessly active provider from owning the conversation forever.
    private func scheduleInactivityTimeout(
        reducer: TurnReducer,
        timeout: TimeInterval
    ) {
        let activity = reducer.activitySnapshot()
        let elapsed = activity.now - activity.startedAt
        let firstDelay = min(timeout, max(
            AssistantTurnTimeoutPolicy.maximumTurnDurationSeconds
                - elapsed,
            0.001))
        queue.asyncAfter(deadline: .now() + firstDelay) { [weak self] in
            self?.enforceInactivityTimeout(reducer: reducer, timeout: timeout)
        }
    }

    private func enforceInactivityTimeout(
        reducer: TurnReducer,
        timeout: TimeInterval
    ) {
        guard activeTurns[reducer.turnID] === reducer, !reducer.isFinished else {
            return
        }
        let activity = reducer.activitySnapshot()
        let idleFor = activity.now - activity.lastActivityAt
        let elapsed = activity.now - activity.startedAt
        let reachedSafetyLimit = elapsed
            >= AssistantTurnTimeoutPolicy.maximumTurnDurationSeconds
        if !reachedSafetyLimit, idleFor < timeout {
            let delay = min(
                max(timeout - idleFor, 0.001),
                max(
                    AssistantTurnTimeoutPolicy.maximumTurnDurationSeconds
                        - elapsed,
                    0.001))
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.enforceInactivityTimeout(
                    reducer: reducer, timeout: timeout)
            }
            return
        }

        activeTurns.removeValue(forKey: reducer.turnID)
        discardLateNotifications(for: reducer.turnID)
        for context in conversations.values
        where context.token == reducer.conversationToken {
            // The interrupted thread may have provider-side state that never
            // reached a terminal event. Force the next turn onto a fresh one.
            context.threadID = nil
        }
        reducer.fail(reachedSafetyLimit
            ? CodexBridgeError.maximumDurationExceeded
            : CodexBridgeError.turnTimeout)
        interruptTurn(threadID: reducer.threadID, turnID: reducer.turnID)
    }

    /// Per-RPC deadline. The initialize / newThread / startTurn handshake RPCs
    /// used to have NO deadline, so a mute or wedged Codex child would hang the
    /// continuation forever — and with it the turn gate, bricking the assistant
    /// until restart. `awaitTurn` gets the long turn timeout; the handshake RPCs
    /// get this shorter one.
    private static let rpcTimeoutSeconds: TimeInterval = 30

    private func sendRequest(
        method: String,
        params: [String: Any],
        requiresInitialization: Bool = true,
        timeout: TimeInterval = CodexAppServer.rpcTimeoutSeconds
    ) async throws -> [String: Any] {
        if requiresInitialization {
            try await ensureInitialized()
        }
        let requestID: Int = queue.sync {
            let id = nextRequestID
            nextRequestID += 1
            return id
        }
        let line = try Self.encode(id: requestID, method: method, params: params)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.pending[requestID] = continuation
                self.writeLine(line)
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self,
                          let cont = self.pending.removeValue(forKey: requestID) else { return }
                    cont.resume(throwing: CodexBridgeError.processUnavailable(
                        "Codex did not respond to \(method) within \(Int(timeout))s."))
                }
            }
        }
    }

    private func ensureInitialized() async throws {
        await initializationGate.acquire()
        do {
            let already = queue.sync { hasInitialized }
            if !already {
                _ = try await sendRequest(
                    method: "initialize",
                    params: [
                        "clientInfo": [
                            "name": "infinitty", "title": "infinitty", "version": "0.1",
                        ] as [String: Any],
                        "capabilities": [:] as [String: Any],
                    ],
                    requiresInitialization: false
                )
                queue.sync {
                    hasInitialized = true
                }
            }
            await initializationGate.release()
        } catch {
            await initializationGate.release()
            throw error
        }
        // Codex 0.144 dropped the `initialized` notification (it's
        // absorbed into the initialize response handshake). Sending it
        // returns an error. Older versions accepted it. Either way, the
        // bridge works without it; keep this commented for reference.
        // try? writeNotification(method: "initialized")
    }

    private func writeNotification(method: String, params: [String: Any]? = nil) throws {
        let line = try Self.encode(id: nil, method: method, params: params)
        queue.async { [weak self] in self?.writeLine(line) }
    }

    private func writeLine(_ line: String) {
        guard let data = line.data(using: .utf8), let h = stdinHandle else { return }
        // Catchable throw on a broken pipe instead of the legacy `write(_:)`'s
        // uncatchable NSException (which would crash the app if the child died).
        try? h.write(contentsOf: data)
    }

    private static func encode(id: Int?, method: String, params: [String: Any]?) throws -> String {
        var obj: [String: Any] = ["method": method]
        if let id { obj["id"] = id }
        if let params { obj["params"] = params }
        let data = try JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    // MARK: - Stream parsing

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<stdoutBuffer.index(after: nl))
            guard let line = String(data: lineData, encoding: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            handleMessage(parsed)
        }
    }

    private func handleMessage(_ msg: [String: Any]) {
        if let id = msg["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let err = msg["error"] as? [String: Any] {
                let text = (err["message"] as? String)
                    ?? "Codex returned an error."
                continuation.resume(throwing: CodexBridgeError.rpcError(text))
            } else {
                continuation.resume(returning: (msg["result"] as? [String: Any]) ?? [:])
            }
            return
        }
        // Notification: dispatch by method.
        guard let method = msg["method"] as? String else { return }
        let params = (msg["params"] as? [String: Any]) ?? [:]
        if let turnID = Self.notificationTurnID(method: method, params: params) {
            if discardedTurnIDs.contains(turnID) {
                if method == "turn/completed" || method == "turn/aborted"
                    || method == "turn/failed" {
                    discardedTurnIDs.remove(turnID)
                }
                return
            }
            guard let reducer = activeTurns[turnID] else {
                earlyTurnMessages[turnID, default: []].append(msg)
                return
            }
            reducer.recordActivity()
        }
        switch method {
        case "thread/tokenUsage/updated":
            guard let usage = Self.runUsage(from: params) else { break }
            AssistantRunEventBus.publish(
                AssistantRunEvent(
                    provenance: .providerReported,
                    update: .usage(usage),
                    scopeID: scopeIDForNotification(params)))
        case "item/reasoning/summaryTextDelta":
            // This method is explicitly provider-designated summary text.
            // The similarly named `item/reasoning/textDelta` is private raw
            // reasoning and is intentionally ignored below.
            guard let delta = params["delta"] as? String, !delta.isEmpty else {
                break
            }
            AssistantRunEventBus.publish(
                AssistantRunEvent(
                    provenance: .providerReported,
                    update: .reasoningSummary(
                        AssistantRunEvent.ReasoningSummary(
                            state: .delta,
                            text: delta,
                            itemID: params["itemId"] as? String,
                            summaryIndex: Self.integer(params["summaryIndex"]))),
                    scopeID: scopeIDForNotification(params)))
        case "item/reasoning/textDelta":
            // Never surface raw model reasoning. Only the provider's explicit
            // summary channel above is suitable for user-visible telemetry.
            break
        case "item/agentMessage/delta":
            // 0.144 params: {threadId, turnId, itemId, delta}.
            let turnID = (params["turnId"] as? String) ?? (params["turn_id"] as? String)
            let itemID = (params["itemId"] as? String) ?? (params["item_id"] as? String)
            let delta  = (params["delta"] as? String)
            if let turnID, let delta, let reducer = activeTurns[turnID] {
                reducer.append(delta, itemID: itemID)
                reducer.emitPartial()
            }
        // Item types that are the conversation itself rather than work the
        // agent did. Observed the hard way: `userMessage` was rendering as a
        // tool card until it showed up on screen.
        case "item/started", "item/updated":
            // Anything that isn't the agent talking or thinking is work it did
            // — surface it as a tool card. The item type doubles as the name,
            // so this holds up without hardcoding Codex's evolving type list.
            if let item = params["item"] as? [String: Any],
               let type = item["type"] as? String,
               !CodexAppServer.conversationalItemTypes.contains(type),
               let id = item["id"] as? String {
                let scopeID = scopeIDForNotification(params)
                AssistantToolEventBus.publish(
                    AssistantToolEvent(
                        id: id,
                        name: type,
                        state: .running,
                        scopeID: scopeID))
            }
        case "item/completed":
            // Same, for the terminal state.
            if let item = params["item"] as? [String: Any],
               let type = item["type"] as? String,
               !CodexAppServer.conversationalItemTypes.contains(type),
               let id = item["id"] as? String {
                let failed = (item["status"] as? String).map {
                    $0 == "failed" || $0 == "error"
                } ?? false
                let scopeID = scopeIDForNotification(params)
                AssistantToolEventBus.publish(
                    AssistantToolEvent(
                        id: id,
                        // No name on completion keeps the one from the start.
                        name: "",
                        state: failed ? .failed : .completed,
                        output: item["text"] as? String,
                        scopeID: scopeID))
            }
            // A completed reasoning item carries an authoritative array of
            // provider-created summaries. Its `content` field is raw
            // reasoning and must never enter this event stream.
            if let item = params["item"] as? [String: Any],
               (item["type"] as? String) == "reasoning",
               let summaryParts = item["summary"] as? [String] {
                let summary = summaryParts
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                if !summary.isEmpty {
                    AssistantRunEventBus.publish(
                        AssistantRunEvent(
                            provenance: .providerReported,
                            update: .reasoningSummary(
                                AssistantRunEvent.ReasoningSummary(
                                    state: .completed,
                                    text: summary,
                                    itemID: item["id"] as? String)),
                            scopeID: scopeIDForNotification(params)))
                }
            }
            // 0.144 delivers the agent reply as a completed `agentMessage`
            // item carrying the FULL text. If that item never streamed
            // deltas (non-streaming models), take its text wholesale;
            // if it did, the deltas already built the same string.
            guard let item = params["item"] as? [String: Any],
                  (item["type"] as? String) == "agentMessage",
                  let turnID = (params["turnId"] as? String) ?? (params["turn_id"] as? String),
                  let reducer = activeTurns[turnID]
            else { break }
            if let itemID = item["id"] as? String,
               let text = item["text"] as? String {
                reducer.recordCompletedItem(id: itemID, text: text)
                reducer.emitPartial()
            }
        case "thread/status/changed":
            guard let threadID = params["threadId"] as? String,
                  let status = params["status"] as? [String: Any],
                  let statusType = status["type"] as? String else { break }
            if statusType == "systemError" {
                for reducer in activeTurns.values where reducer.threadID == threadID {
                    reducer.fail(CodexBridgeError.rpcError("Codex thread entered a system error state."))
                }
            } else if statusType == "idle" {
                let reducers = activeTurns.values.filter {
                    $0.threadID == threadID && !$0.isFinished
                }
                if reducers.isEmpty {
                    pendingIdleThreadIDs.insert(threadID)
                } else {
                    for reducer in reducers {
                        let text = reducer.snapshot()
                        if !text.isEmpty { reducer.finish(text) }
                    }
                }
            }
        case "turn/completed", "turn/aborted", "turn/failed":
            // 0.144 nests the turn object: params = {threadId, turn:
            // {id, status, error, ...}} — there is NO top-level turnId.
            // (Reading params["turnId"] here was why every turn used to
            // ride the 130 s timeout instead of resolving instantly.)
            let turn = (params["turn"] as? [String: Any]) ?? [:]
            let turnID = (turn["id"] as? String)
                ?? (params["turnId"] as? String)
                ?? (params["turn_id"] as? String)
            guard let turnID, let reducer = activeTurns[turnID] else { break }
            let status = turn["status"] as? String
            let errMessage = ((turn["error"] as? [String: Any])?["message"] as? String)
                ?? ((params["error"] as? [String: Any])?["message"] as? String)
            if method != "turn/completed" || status == "failed" || status == "aborted" {
                reducer.fail(CodexBridgeError.rpcError(
                    errMessage ?? "Codex turn \(status ?? "aborted")."))
                break
            }
            let text = reducer.snapshot()
            if text.isEmpty {
                // Rare: completion beat the agentMessage item. Give the
                // item a short grace window instead of the full timeout.
                queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, let r = self.activeTurns[turnID],
                          !r.isFinished else { return }
                    r.finish(r.snapshot())
                }
            } else {
                reducer.finish(text)
            }
        case "error":
            // Fatal turn errors (bad model, 400s, auth) arrive as an
            // `error` notification: {error: {message}, willRetry,
            // threadId, turnId}. Ignoring these used to leave the turn
            // hanging until timeout with an empty buffer.
            let turnID = (params["turnId"] as? String) ?? (params["turn_id"] as? String)
            let willRetry = (params["willRetry"] as? Bool) ?? false
            let message = ((params["error"] as? [String: Any])?["message"] as? String)
                ?? "Codex reported an error."
            if !willRetry, let turnID, let reducer = activeTurns[turnID] {
                reducer.fail(CodexBridgeError.rpcError(message))
            }
        default:
            break
        }
    }

    private static func notificationTurnID(
        method: String, params: [String: Any]
    ) -> String? {
        if let direct = (params["turnId"] as? String)
            ?? (params["turn_id"] as? String) {
            return direct
        }
        switch method {
        case "turn/completed", "turn/aborted", "turn/failed":
            let turn = params["turn"] as? [String: Any]
            return turn?["id"] as? String
        default:
            return nil
        }
    }

    private func discardLateNotifications(for turnID: String) {
        discardedTurnIDs.insert(turnID)
        earlyTurnMessages.removeValue(forKey: turnID)
        // Provider acknowledgement normally removes this immediately. The
        // fallback keeps the tombstone set bounded if no terminal event comes.
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.discardedTurnIDs.remove(turnID)
        }
    }

    private func scopeIDForNotification(_ params: [String: Any]) -> String? {
        guard let turnID = (params["turnId"] as? String)
                ?? (params["turn_id"] as? String) else { return nil }
        return activeTurns[turnID]?.scopeID
    }

    private static func runUsage(
        from params: [String: Any]
    ) -> AssistantRunEvent.Usage? {
        guard let usage = params["tokenUsage"] as? [String: Any] else {
            return nil
        }
        let last = tokenCounts(usage["last"] as? [String: Any])
        let cumulative = tokenCounts(usage["total"] as? [String: Any])
        let contextWindow = integer(usage["modelContextWindow"])
        guard last != nil || cumulative != nil || contextWindow != nil else {
            return nil
        }
        return AssistantRunEvent.Usage(
            lastTokens: last,
            cumulativeTokens: cumulative,
            // Codex reports the window but not true current occupancy. Its
            // cumulative total is not a safe substitute after compaction.
            contextUsedTokens: nil,
            contextWindowTokens: contextWindow,
            cost: nil)
    }

    private static func tokenCounts(
        _ usage: [String: Any]?
    ) -> AssistantRunEvent.TokenCounts? {
        guard let usage else { return nil }
        let counts = AssistantRunEvent.TokenCounts(
            input: integer(usage["inputTokens"]),
            cachedInput: integer(usage["cachedInputTokens"]),
            cacheWriteInput: integer(usage["cacheWriteInputTokens"]),
            output: integer(usage["outputTokens"]),
            reasoningOutput: integer(usage["reasoningOutputTokens"]),
            total: integer(usage["totalTokens"]))
        guard counts.input != nil || counts.cachedInput != nil
                || counts.cacheWriteInput != nil || counts.output != nil
                || counts.reasoningOutput != nil || counts.total != nil else {
            return nil
        }
        return counts
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func registerConversationContext(
        for conversationID: String?
    ) -> ConversationContext {
        let key = conversationID.map(ConversationKey.identified) ?? .legacy
        return queue.sync {
            if let conversationID {
                tombstonedConversationIDs.remove(conversationID)
            }
            if let context = conversations[key], !context.isReleased {
                return context
            }
            let context = ConversationContext(scopeID: conversationID)
            conversations[key] = context
            return context
        }
    }

    private func conversationContextForTurn(
        for conversationID: String?
    ) throws -> ConversationContext {
        let key = conversationID.map(ConversationKey.identified) ?? .legacy
        return try queue.sync {
            if let conversationID,
               tombstonedConversationIDs.contains(conversationID) {
                throw CancellationError()
            }
            if let context = conversations[key], !context.isReleased {
                return context
            }
            let context = ConversationContext(scopeID: conversationID)
            conversations[key] = context
            return context
        }
    }

    private func ensureContextIsActive(
        _ context: ConversationContext,
        generation: Int? = nil
    ) throws {
        let isCancelled = queue.sync {
            context.isReleased
                || generation.map { context.cancellationGeneration != $0 } == true
        }
        if isCancelled { throw CancellationError() }
    }

    private func cancelConversation(
        key: ConversationKey,
        release: Bool
    ) {
        let turns: [(threadID: String, turnID: String)] = queue.sync {
            if release, case .identified(let conversationID) = key {
                tombstonedConversationIDs.insert(conversationID)
            }
            guard let context = conversations[key] else { return [] }
            context.cancellationGeneration &+= 1
            if release {
                context.isReleased = true
                conversations.removeValue(forKey: key)
            }
            let matches = activeTurns.values.filter {
                $0.conversationToken == context.token && !$0.isFinished
            }
            for reducer in matches {
                reducer.fail(CancellationError())
                activeTurns.removeValue(forKey: reducer.turnID)
                discardLateNotifications(for: reducer.turnID)
            }
            return matches.map { ($0.threadID, $0.turnID) }
        }
        for turn in turns {
            interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
        }
    }

    /// Best-effort protocol cancellation. The local reducer is failed first,
    /// so callers never depend on the app-server acknowledging the interrupt.
    private func interruptTurn(threadID: String, turnID: String) {
        Task { [weak self] in
            _ = try? await self?.sendRequest(
                method: "turn/interrupt",
                params: ["threadId": threadID, "turnId": turnID])
        }
    }
}

// MARK: - Turn reducer

private final class TurnReducer: @unchecked Sendable {
    let turnID: String
    let threadID: String
    let conversationToken: UUID
    let scopeID: String?
    private(set) var buffer = ""
    /// Item ids that streamed via `item/agentMessage/delta`. Used to
    /// avoid double-counting when the same item later completes with
    /// its full text.
    private var streamedItemIDs = Set<String>()
    private var onComplete: ((Result<String, Error>) -> Void)?
    private var onPartial: ((String) -> Void)?
    private var lastPartialAt: Double = 0
    private var completionResult: Result<String, Error>?
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var lastActivityAt = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()

    init(
        turnID: String,
        threadID: String,
        conversationToken: UUID,
        scopeID: String?,
        onPartial: ((String) -> Void)?
    ) {
        self.turnID = turnID
        self.threadID = threadID
        self.conversationToken = conversationToken
        self.scopeID = scopeID
        self.onPartial = onPartial
    }

    var isFinished: Bool { lock.withLock { completionResult != nil } }

    func recordActivity() {
        lock.withLock {
            guard completionResult == nil else { return }
            lastActivityAt = ProcessInfo.processInfo.systemUptime
        }
    }

    func activitySnapshot() -> (
        startedAt: Double, lastActivityAt: Double, now: Double
    ) {
        lock.withLock {
            (startedAt, lastActivityAt, ProcessInfo.processInfo.systemUptime)
        }
    }

    func append(_ chunk: String, itemID: String? = nil) {
        lock.withLock {
            guard completionResult == nil else { return }
            buffer += chunk
            if let itemID { streamedItemIDs.insert(itemID) }
        }
    }

    /// Fold in a completed agentMessage item. No-op when the item's
    /// deltas already streamed into the buffer.
    func recordCompletedItem(id: String, text: String) {
        lock.withLock {
            guard completionResult == nil, !streamedItemIDs.contains(id) else { return }
            if !buffer.isEmpty { buffer += "\n" }
            buffer += text
        }
    }

    func snapshot() -> String { lock.withLock { buffer } }

    /// Throttle live partial callbacks independently for every in-flight turn.
    func emitPartial() {
        let delivery: (((String) -> Void), String)? = lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard completionResult == nil,
                  now - lastPartialAt > 0.1,
                  let onPartial,
                  !buffer.isEmpty else { return nil }
            lastPartialAt = now
            return (onPartial, buffer)
        }
        if let (callback, text) = delivery {
            DispatchQueue.main.async { callback(text) }
        }
    }

    func attach(_ completion: @escaping (Result<String, Error>) -> Void) {
        let completed: Result<String, Error>? = lock.withLock {
            if let result = completionResult { return result }
            onComplete = completion
            return nil
        }
        if let completed { completion(completed) }
    }

    func finish(_ text: String) {
        complete(.success(text))
    }

    func fail(_ error: Error) {
        complete(.failure(error))
    }

    private func complete(_ result: Result<String, Error>) {
        let callback: ((Result<String, Error>) -> Void)? = lock.withLock {
            guard completionResult == nil else { return nil }
            completionResult = result
            let saved = onComplete
            onComplete = nil
            onPartial = nil
            return saved
        }
        callback?(result)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

// MARK: - Errors

enum CodexBridgeError: LocalizedError {
    case processUnavailable(String)
    case protocolViolation(String)
    case rpcError(String)
    case turnTimeout
    case maximumDurationExceeded

    var errorDescription: String? {
        switch self {
        case .processUnavailable(let m), .protocolViolation(let m), .rpcError(let m):
            return m
        case .turnTimeout:
            return "Codex was inactive for the configured turn timeout."
        case .maximumDurationExceeded:
            return "Codex reached the 30-minute turn safety limit."
        }
    }
}
