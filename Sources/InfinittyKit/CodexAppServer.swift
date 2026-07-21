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
    static let shared = CodexAppServer()

    // MARK: - State

    private let queue = DispatchQueue(label: "infinitty.codex.app-server")
    private let turnGate = AgentTurnGate()
    private let executableURLOverride: URL?
    private let mcpExecutableURLOverride: URL?
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    /// Active turn reducers. Keyed by turn id; one per in-flight `turn/start`.
    private var activeTurns: [String: TurnReducer] = [:]
    /// Notifications can share a pipe read with the `turn/start` response.
    /// Buffer them until the async caller has installed its reducer.
    private var earlyTurnMessages: [String: [[String: Any]]] = [:]
    private var pendingIdleThreadIDs = Set<String>()
    /// Most recently-created thread id; reused so each thread carries prior
    /// turn context (matches openclicky's `CodexVoiceSession` model).
    private var activeThreadID: String?
    /// Whether the JSON-RPC initialize handshake has completed.
    private var hasInitialized = false
    /// Resolved model name used for the current thread.
    private var currentModel: String?

    private static let requestTimeoutSeconds: TimeInterval = 130

    var isRunning: Bool { queue.sync { process?.isRunning == true } }

    init(executableURL: URL? = nil, mcpExecutableURL: URL? = nil) {
        self.executableURLOverride = executableURL
        self.mcpExecutableURLOverride = mcpExecutableURL
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
        timeout: TimeInterval = CodexAppServer.requestTimeoutSeconds
    ) async throws -> String {
        await turnGate.acquire()
        do {
            try Task.checkCancellation()
            try ensureProcess()
            let threadID = try await ensureThread(model: model)
            let turnID = try await startTurn(
                threadID: threadID,
                prompt: prompt,
                cwd: cwd,
                effort: effort)
            let result = try await awaitTurn(turnID: turnID, timeout: timeout)
            await turnGate.release()
            return result
        } catch {
            await turnGate.release()
            throw error
        }
    }

    /// Spawn the app-server and open the thread ahead of the first real
    /// turn so its cold start (Node init + booting the ~/.codex MCP
    /// servers) overlaps with the user still typing. Idempotent. This is
    /// the openclicky trick — warm on interaction, not on first ask.
    func warmUp(model: String) {
        try? ensureProcess()
        Task { [weak self] in
            guard let self else { return }
            await self.turnGate.acquire()
            _ = try? await self.ensureThread(model: model)
            await self.turnGate.release()
        }
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
            activeThreadID = nil
            currentModel = nil
            for (_, continuation) in pending {
                continuation.resume(throwing: CancellationError())
            }
            pending.removeAll()
            for (_, reducer) in activeTurns {
                reducer.fail(CancellationError())
            }
            activeTurns.removeAll()
            earlyTurnMessages.removeAll()
            pendingIdleThreadIDs.removeAll()
        }
    }

    deinit { stop() }

    // MARK: - Process management

    /// YOLO sandbox default. Pet-assistant turns are non-interactive,
    /// so leaving the seed at `workspace-write` causes every write
    /// tool call to bounce an approval prompt back to a user who
    /// isn't there, deadlocking the turn until the 130 s timeout
    /// (that deadlock was the 30 s/turn pathology). Opt out with
    /// `INFINITTY_AI_YOLO=0`.
    private static let yoloSandboxMode: String = {
        ProcessInfo.processInfo.environment["INFINITTY_AI_YOLO"] == "0"
            ? "workspace-write"
            : "danger-full-access"
    }()

    private func ensureProcess() throws {
        try queue.sync {
            if process?.isRunning == true { return }
            if process != nil {
                process = nil
                stdinHandle = nil
                stdoutHandle = nil
                stderrHandle = nil
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
                // YOLO by default — framework lets the CLI self-approve
                // tool calls instead of bouncing prompts back to a
                // background pet-assistant lane. Opt out per launch
                // with `INFINITTY_AI_YOLO=0`.
                "-c", "sandbox_mode=\(CodexAppServer.yoloSandboxMode)",
            ]
            let mcpURL = mcpExecutableURLOverride
                ?? MCPConfiguration.mcpExecutablePath().map(URL.init(fileURLWithPath:))
            if let mcpURL {
                // Inject the app's own terminal-control MCP server for this
                // bridge without requiring a persistent user config edit, and
                // pin it to THIS instance's control socket.
                for override in MCPConfiguration.codexConfigOverrides(
                    binaryPath: mcpURL.path, appSocketPath: AppControlServer.ownSocketPath) {
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
            p.environment = env
            p.terminationHandler = { [weak self] proc in
                self?.queue.async {
                    guard let self, self.process === proc else { return }
                    self.stdoutHandle?.readabilityHandler = nil
                    self.stderrHandle?.readabilityHandler = nil
                    self.process = nil
                    self.hasInitialized = false
                    self.activeThreadID = nil
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

    private func ensureThread(model: String) async throws -> String {
        let cached: String? = queue.sync {
            (activeThreadID.flatMap { currentModel == model ? $0 : nil })
        }
        if let cached { return cached }
        let threadStart = try await sendRequest(method: "thread/start", params: [
            "model": model,
            "cwd": ProcessInfo.processInfo.environment["HOME"].flatMap { URL(fileURLWithPath: $0) }?.path ?? NSHomeDirectory(),
        ])
        guard let id = (threadStart["thread"] as? [String: Any])?["id"] as? String else {
            throw CodexBridgeError.protocolViolation(
                "thread/start did not return a thread id.")
        }
        queue.sync {
            activeThreadID = id
            currentModel = model
        }
        return id
    }

    private func startTurn(
        threadID: String, prompt: String, cwd: String, effort: String
    ) async throws -> String {
        let input: [[String: Any]] = [["type": "text", "text": prompt]]
        _ = queue.sync { pendingIdleThreadIDs.remove(threadID) }
        let sandboxPolicy: [String: Any] = CodexAppServer.yoloSandboxMode == "danger-full-access"
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
        queue.sync {
            let reducer = TurnReducer(turnID: id, threadID: threadID)
            activeTurns[id] = reducer
            let buffered = earlyTurnMessages.removeValue(forKey: id) ?? []
            for message in buffered { handleMessage(message) }
            if pendingIdleThreadIDs.remove(threadID) != nil,
               !reducer.isFinished, !reducer.snapshot().isEmpty {
                reducer.finish(reducer.snapshot())
            }
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
                let deadline = DispatchTime.now() + timeout
                self.queue.asyncAfter(deadline: deadline) {
                    guard !reducer.isFinished else { return }
                    // If we never got a clean completion signal (Codex
                    // 0.144 sometimes doesn't broadcast one), return
                    // whatever text the deltas accumulated — better
                    // than throwing, since Codex did finish replying.
                    let partial = reducer.snapshot()
                    if partial.isEmpty {
                        reducer.fail(CodexBridgeError.turnTimeout)
                    } else {
                        reducer.finish(partial)
                    }
                }
            }
        } onCancel: {
            self.queue.async {
                if let r = self.activeTurns[turnID] {
                    r.fail(CancellationError())
                    self.activeTurns.removeValue(forKey: turnID)
                }
            }
        }
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
        let already = queue.sync { hasInitialized }
        guard !already else { return }
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
        if let turnID = Self.notificationTurnID(method: method, params: params),
           activeTurns[turnID] == nil {
            earlyTurnMessages[turnID, default: []].append(msg)
            return
        }
        switch method {
        case "item/agentMessage/delta":
            // 0.144 params: {threadId, turnId, itemId, delta}.
            let turnID = (params["turnId"] as? String) ?? (params["turn_id"] as? String)
            let itemID = (params["itemId"] as? String) ?? (params["item_id"] as? String)
            let delta  = (params["delta"] as? String)
            if let turnID, let delta, let reducer = activeTurns[turnID] {
                reducer.append(delta, itemID: itemID)
            }
        case "item/completed":
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
        switch method {
        case "item/agentMessage/delta", "item/completed", "error":
            return (params["turnId"] as? String) ?? (params["turn_id"] as? String)
        case "turn/completed", "turn/aborted", "turn/failed":
            let turn = params["turn"] as? [String: Any]
            return (turn?["id"] as? String)
                ?? (params["turnId"] as? String)
                ?? (params["turn_id"] as? String)
        default:
            return nil
        }
    }
}

// MARK: - Turn reducer

private final class TurnReducer: @unchecked Sendable {
    let turnID: String
    let threadID: String
    private(set) var buffer = ""
    /// Item ids that streamed via `item/agentMessage/delta`. Used to
    /// avoid double-counting when the same item later completes with
    /// its full text.
    private var streamedItemIDs = Set<String>()
    private var onComplete: ((Result<String, Error>) -> Void)?
    private var completionResult: Result<String, Error>?
    private let lock = NSLock()

    init(turnID: String, threadID: String) {
        self.turnID = turnID
        self.threadID = threadID
    }

    var isFinished: Bool { lock.withLock { completionResult != nil } }

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

    var errorDescription: String? {
        switch self {
        case .processUnavailable(let m), .protocolViolation(let m), .rpcError(let m):
            return m
        case .turnTimeout:
            return "Codex did not respond within the turn timeout."
        }
    }
}
