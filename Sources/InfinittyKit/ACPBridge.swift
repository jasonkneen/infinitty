import Foundation

/// Long-lived bridge for Agent Client Protocol (ACP) agents — the stdio
/// JSON-RPC protocol that `opencode acp` and `hermes acp` both speak
/// (same protocol Zed/editors use). One warm process per provider, reused
/// across turns so the user pays cold start once.
///
/// Wire protocol (JSON-RPC 2.0, one message per line):
///   REQUESTS (client → agent, carry an `id`):
///     initialize          {protocolVersion, clientCapabilities}
///     session/new         {cwd, mcpServers}                → {sessionId, ...}
///     session/set_config_option {sessionId, configId, value}   (opencode)
///     session/set_model   {sessionId, modelId}                 (hermes)
///     session/prompt      {sessionId, prompt:[{type:"text",text}]} → {stopReason}
///   NOTIFICATIONS (agent → client, carry a `method`):
///     session/update      {sessionId, update:{sessionUpdate:"agent_message_chunk",
///                           content:{type:"text",text}}}   → streamed answer text
///
/// The turn resolves when the `session/prompt` RESPONSE arrives; the
/// streamed `session/update` chunks accumulate the answer text and drive
/// the live `onPartial` callback (so a turn never looks hung). JSON-RPC
/// `error` responses fast-fail the turn instead of riding the timeout —
/// the same hardening Codex got.
final class ACPBridge: @unchecked Sendable {
    /// One warm process per ACP provider.
    static let opencode = ACPBridge(provider: .opencode)
    static let hermes = ACPBridge(provider: .hermes)

    private let provider: InfinittyAIProvider
    private let queue: DispatchQueue
    private let turnGate = AgentTurnGate()
    private let executableURLOverride: URL?
    private let eventScopeID: String?
    /// The current ACP reducer assumes one prompt/session per process. Keyed
    /// conversations therefore get independent child bridges so their session
    /// ids, streamed updates, models, and working directories cannot cross.
    private var conversationBridges: [String: ACPBridge] = [:]
    /// Releasing a keyed conversation blocks late work from recreating its
    /// child. Only a later explicit warm-up registration clears the marker.
    private var tombstonedConversationIDs = Set<String>()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    /// Set only on a keyed child after its owning conversation is released.
    /// Prevents queued/racing work from restarting an orphaned ACP session.
    private var isReleased = false
    private var stdoutBuffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var sessionID: String?
    private var currentModel: String?
    /// The cwd the live session was opened against. A different cwd forces a
    /// new session.
    private var currentCWD: String?
    /// The whole `session/new` result, kept because it is also where both ACP
    /// agents advertise their model list — opencode under `configOptions`,
    /// hermes under `models.availableModels`. Discovery reads it from here
    /// rather than paying a second handshake.
    private var sessionSurface: [String: Any] = [:]
    /// Accumulated answer text + live callback for the in-flight turn.
    private var turnAccumulator = ""
    private var onPartial: ((String) -> Void)?
    private var lastPartialAt: Double = 0

    private static let turnTimeoutSeconds: TimeInterval = 90
    private static let rpcTimeoutSeconds: TimeInterval = 30
    /// `session/new` scans the workspace, so it scales with the directory it's
    /// pointed at: ~4s in a small tree, ~30s at `$HOME`. It needs its own
    /// budget — the generic 30s RPC timeout used to cut opencode off mid-scan.
    private static let sessionTimeoutSeconds: TimeInterval = 90

    /// Neutral directory for sessions opened without a project context
    /// (prewarm, model discovery). Deliberately not `$HOME`: pointing an ACP
    /// agent at the whole home directory makes `session/new` an order of
    /// magnitude slower for no benefit, since these sessions only need the
    /// agent's global config.
    static var neutralWorkspace: String {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return NSTemporaryDirectory()
        }
        let dir = base.appendingPathComponent("infinitty/workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    var isRunning: Bool {
        let state = queue.sync {
            (process?.isRunning == true, Array(conversationBridges.values))
        }
        return state.0 || state.1.contains { $0.isRunning }
    }

    init(
        provider: InfinittyAIProvider,
        executableURL: URL? = nil,
        eventScopeID: String? = nil
    ) {
        self.provider = provider
        self.executableURLOverride = executableURL
        self.eventScopeID = eventScopeID
        self.queue = DispatchQueue(label: "infinitty.acp.bridge.\(provider.rawValue)")
    }

    /// ACP launch arguments per provider. opencode → `opencode acp`;
    /// hermes → `hermes acp --accept-hooks` (auto-approve hooks without a
    /// TTY, mirroring the other bridges' YOLO default).
    private var launchArguments: [String] {
        switch provider {
        case .hermes:   return ["acp", "--accept-hooks"]
        default:        return ["acp"]   // opencode (and any future ACP agent)
        }
    }

    /// How this agent wants to be told which model to use. The two ACP agents
    /// disagree: opencode exposes the model as a *config option* and answers
    /// `Method not found` to `session/set_model`, while hermes only implements
    /// `session/set_model`. Verified against both binaries.
    private enum ModelSelection {
        case configOption   // session/set_config_option {sessionId, configId, value}
        case setModel       // session/set_model         {sessionId, modelId}
    }

    private var modelSelection: ModelSelection {
        switch provider {
        case .opencode: return .configOption
        default:        return .setModel
        }
    }

    // MARK: - Public API

    func warmUp(
        model: String? = nil,
        cwd: String = ACPBridge.neutralWorkspace,
        conversationID: String? = nil
    ) {
        if let conversationID {
            registerConversationBridge(for: conversationID).warmUpLocally(
                model: model, cwd: cwd)
            return
        }
        warmUpLocally(model: model, cwd: cwd)
    }

    private func warmUpLocally(model: String?, cwd: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.turnGate.acquire()
            do {
                try self.ensureLocallyActive()
                try self.ensureProcess()
                _ = try await self.ensureSession(model: model, cwd: cwd)
            } catch {
                // Warm-up is deliberately best effort.
            }
            await self.turnGate.release()
        }
    }

    /// The `session/new` result, which is where both ACP agents advertise
    /// their models. Ensures a session first (reusing the warm one when the
    /// prewarm already made it), so this costs nothing in the common case.
    func sessionModelSurface(
        conversationID: String? = nil
    ) async throws -> [String: Any] {
        if let conversationID {
            return try await conversationBridgeForTurn(
                for: conversationID
            ).sessionModelSurfaceLocally()
        }
        return try await sessionModelSurfaceLocally()
    }

    private func sessionModelSurfaceLocally() async throws -> [String: Any] {
        await turnGate.acquire()
        defer { Task { await turnGate.release() } }
        try ensureProcess()
        _ = try await ensureSession(model: nil, cwd: Self.neutralWorkspace)
        return queue.sync { sessionSurface }
    }

    /// Run one turn, returning the agent's final answer. Streams chunks
    /// through `onPartial` as they arrive.
    func turn(
        prompt: String,
        system: String = "",
        model: String? = nil,
        cwd: String = ACPBridge.neutralWorkspace,
        timeout: TimeInterval = ACPBridge.turnTimeoutSeconds,
        conversationID: String? = nil,
        onPartial: ((String) -> Void)? = nil
    ) async throws -> String {
        if let conversationID {
            return try await conversationBridgeForTurn(
                for: conversationID
            ).turnLocally(
                prompt: prompt,
                system: system,
                model: model,
                cwd: cwd,
                timeout: timeout,
                onPartial: onPartial)
        }
        return try await turnLocally(
            prompt: prompt,
            system: system,
            model: model,
            cwd: cwd,
            timeout: timeout,
            onPartial: onPartial)
    }

    private func turnLocally(
        prompt: String,
        system: String,
        model: String?,
        cwd: String,
        timeout: TimeInterval,
        onPartial: ((String) -> Void)?
    ) async throws -> String {
        await turnGate.acquire()
        do {
            try Task.checkCancellation()
            try ensureLocallyActive()
            try ensureProcess()
            let sessionID = try await ensureSession(model: model, cwd: cwd)
            let fullPrompt = system.isEmpty ? prompt : system + "\n\n" + prompt
            queue.sync {
                self.turnAccumulator = ""
                self.onPartial = onPartial
                self.lastPartialAt = 0
            }
            // The prompt RESPONSE marks turn end; streamed chunks already
            // filled the accumulator. Long timeout applies to this RPC.
            _ = try await sendRequest(
                method: "session/prompt",
                params: [
                    "sessionId": sessionID,
                    "prompt": [["type": "text", "text": fullPrompt]],
                ],
                requiresInitialization: false,
                timeout: timeout)
            let text = queue.sync { () -> String in
                let t = turnAccumulator
                turnAccumulator = ""
                self.onPartial = nil
                return t
            }
            await turnGate.release()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ACPBridgeError.emptyResponse(provider.displayName)
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            queue.sync { self.onPartial = nil; self.turnAccumulator = "" }
            await turnGate.release()
            throw error
        }
    }

    /// Cancel a keyed conversation without disturbing other ACP sessions.
    /// Its child process is discarded so late, uncorrelated stream updates
    /// cannot leak into the next turn.
    func cancelConversation(_ conversationID: String) {
        existingConversationBridge(for: conversationID)?.stopLocally()
    }

    /// Cancel and forget a keyed ACP conversation. A later explicit warm-up
    /// registration starts a fresh process and `session/new` handshake; a
    /// racing turn remains cancelled.
    func releaseConversation(_ conversationID: String) {
        let bridge = queue.sync {
            tombstonedConversationIDs.insert(conversationID)
            return conversationBridges.removeValue(forKey: conversationID)
        }
        bridge?.releaseLocally()
    }

    func stop() {
        let children = queue.sync { () -> [ACPBridge] in
            let values = Array(conversationBridges.values)
            conversationBridges.removeAll()
            return values
        }
        for child in children { child.releaseLocally() }
        stopLocally()
    }

    private func stopLocally() {
        queue.sync { teardownLocked() }
    }

    private func releaseLocally() {
        queue.sync {
            isReleased = true
            teardownLocked()
        }
    }

    private func ensureLocallyActive() throws {
        if queue.sync(execute: { isReleased }) {
            throw CancellationError()
        }
    }

    deinit { stop() }

    private func registerConversationBridge(
        for conversationID: String
    ) -> ACPBridge {
        queue.sync {
            tombstonedConversationIDs.remove(conversationID)
            if let bridge = conversationBridges[conversationID] {
                return bridge
            }
            let bridge = ACPBridge(
                provider: provider,
                executableURL: executableURLOverride,
                eventScopeID: conversationID)
            conversationBridges[conversationID] = bridge
            return bridge
        }
    }

    private func conversationBridgeForTurn(
        for conversationID: String
    ) throws -> ACPBridge {
        try queue.sync {
            if tombstonedConversationIDs.contains(conversationID) {
                throw CancellationError()
            }
            if let bridge = conversationBridges[conversationID] {
                return bridge
            }
            let bridge = ACPBridge(
                provider: provider,
                executableURL: executableURLOverride,
                eventScopeID: conversationID)
            conversationBridges[conversationID] = bridge
            return bridge
        }
    }

    private func existingConversationBridge(
        for conversationID: String
    ) -> ACPBridge? {
        queue.sync { conversationBridges[conversationID] }
    }

    private func teardownLocked() {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        sessionID = nil
        currentModel = nil
        currentCWD = nil
        sessionSurface = [:]
        turnAccumulator = ""
        onPartial = nil
        lastPartialAt = 0
        stdoutBuffer.removeAll()
        for (_, c) in pending { c.resume(throwing: CancellationError()) }
        pending.removeAll()
    }

    // MARK: - Process

    private func ensureProcess() throws {
        try queue.sync {
            if isReleased { throw CancellationError() }
            if process?.isRunning == true { return }
            teardownLocked()
            guard let executable = executableURLOverride
                    ?? provider.cliKind.flatMap({ CLIExecutableResolver.resolve($0) }) else {
                throw ACPBridgeError.processUnavailable(
                    "\(provider.displayName) CLI not found on PATH; install it or set "
                    + (provider.cliKind?.envOverrideKey ?? "INFINITTY_<BIN>_EXECUTABLE") + ".")
            }
            let p = Process()
            p.executableURL = executable
            p.arguments = launchArguments
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            p.standardInput = stdin
            p.standardOutput = stdout
            p.standardError = stderr
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
            p.environment = env
            PetLog.log("ACPBridge(\(provider.rawValue)).spawn args=\(launchArguments) (cold start)")
            p.terminationHandler = { [weak self] proc in
                self?.queue.async {
                    guard let self, self.process === proc else { return }
                    PetLog.log("ACPBridge(\(self.provider.rawValue)).childExit status=\(proc.terminationStatus)")
                    self.stdoutHandle?.readabilityHandler = nil
                    self.stderrHandle?.readabilityHandler = nil
                    self.process = nil
                    self.sessionID = nil
                    self.currentModel = nil
                    self.sessionSurface = [:]
                    for (_, continuation) in self.pending {
                        continuation.resume(throwing: ACPBridgeError.processUnavailable(
                            "\(self.provider.displayName) bridge exited (\(proc.terminationStatus))."))
                    }
                    self.pending.removeAll()
                }
            }
            try p.run()
            self.process = p
            self.stdinHandle = stdin.fileHandleForWriting
            self.stdoutHandle = stdout.fileHandleForReading
            self.stderrHandle = stderr.fileHandleForReading
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                self?.queue.async { self?.consumeStdout(data) }
            }
            // Drain stderr (logs). An undrained pipe wedges the child.
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
            }
        }
    }

    private func ensureSession(model: String?, cwd: String) async throws -> String {
        // A cwd change invalidates the session: the agent scoped its workspace
        // at session/new and can't be re-pointed afterwards.
        if queue.sync(execute: { currentCWD }) != cwd {
            queue.sync { sessionID = nil; currentModel = nil; sessionSurface = [:] }
        }
        if let sessionID = queue.sync(execute: { sessionID }),
           model == currentModel || (model?.isEmpty ?? true) {
            return sessionID
        }
        if queue.sync(execute: { sessionID }) == nil {
            _ = try await sendRequest(
                method: "initialize",
                params: [
                    "protocolVersion": 1,
                    // Everything stays false: we implement none of the
                    // client-side file or terminal RPCs, and claiming a
                    // capability we can't answer would hang the agent when it
                    // calls back into us.
                    "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
                ],
                requiresInitialization: false)
            let newResponse = try await sendRequest(
                method: "session/new",
                params: ["cwd": cwd, "mcpServers": [] as [Any]],
                requiresInitialization: false,
                timeout: Self.sessionTimeoutSeconds)
            guard let id = newResponse["sessionId"] as? String else {
                throw ACPBridgeError.protocolViolation(
                    "\(provider.displayName) session/new returned no sessionId.")
            }
            queue.sync {
                sessionID = id
                sessionSurface = newResponse
                currentCWD = cwd
            }
        }
        // Best-effort per-session model selection.
        if let model, !model.isEmpty, let sid = queue.sync(execute: { sessionID }) {
            do {
                switch modelSelection {
                case .configOption:
                    _ = try await sendRequest(
                        method: "session/set_config_option",
                        params: ["sessionId": sid, "configId": "model", "value": model],
                        requiresInitialization: false)
                case .setModel:
                    _ = try await sendRequest(
                        method: "session/set_model",
                        params: ["sessionId": sid, "modelId": model],
                        requiresInitialization: false)
                }
                queue.sync { currentModel = model }
            } catch {
                PetLog.log("ACPBridge(\(provider.rawValue)).setModel failed (using default): \(error.localizedDescription)")
            }
        }
        guard let sid = queue.sync(execute: { sessionID }) else {
            throw ACPBridgeError.protocolViolation("no session id")
        }
        return sid
    }

    // MARK: - JSON-RPC

    private func sendRequest(
        method: String,
        params: [String: Any],
        requiresInitialization: Bool,
        timeout: TimeInterval = ACPBridge.rpcTimeoutSeconds
    ) async throws -> [String: Any] {
        let requestID: Int = queue.sync {
            let id = nextRequestID
            nextRequestID += 1
            return id
        }
        let envelope: [String: Any] = [
            "jsonrpc": "2.0", "id": requestID, "method": method, "params": params,
        ]
        let line = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError()); return
                }
                guard !self.isReleased else {
                    continuation.resume(throwing: CancellationError()); return
                }
                self.pending[requestID] = continuation
                try? self.stdinHandle?.write(contentsOf: line)
                try? self.stdinHandle?.write(contentsOf: Data([0x0A]))
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self,
                          let cont = self.pending.removeValue(forKey: requestID) else { return }
                    cont.resume(throwing: ACPBridgeError.timeout(
                        "\(self.provider.displayName) did not answer \(method) within \(Int(timeout))s."))
                }
            }
        }
    }

    private func consumeStdout(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<stdoutBuffer.index(after: nl))
            guard !lineData.isEmpty,
                  let parsed = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            handleMessage(parsed)
        }
    }

    private func handleMessage(_ msg: [String: Any]) {
        // Response to a request we sent (has an id).
        if let id = msg["id"] as? Int, let cont = pending.removeValue(forKey: id) {
            if let error = msg["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "ACP error."
                cont.resume(throwing: ACPBridgeError.rpcError(message))
            } else {
                cont.resume(returning: (msg["result"] as? [String: Any]) ?? [:])
            }
            return
        }
        // Notification: streamed turn text.
        guard (msg["method"] as? String) == "session/update",
              let params = msg["params"] as? [String: Any],
              let update = params["update"] as? [String: Any] else { return }
        let kind = update["sessionUpdate"] as? String ?? ""

        // ACP reports tool calls as their own update kinds. Surfacing them
        // gives opencode and hermes the same tool cards Claude gets.
        if kind == "tool_call" || kind == "tool_call_update" {
            guard let id = update["toolCallId"] as? String else { return }
            let name = update["title"] as? String
                ?? update["kind"] as? String ?? "tool"
            let status = update["status"] as? String ?? "in_progress"
            let state: AssistantToolEvent.State
            switch status {
            case "completed": state = .completed
            case "failed", "error": state = .failed
            default: state = .running
            }
            var output: String?
            if let content = update["content"] as? [[String: Any]] {
                let text = content.compactMap { block -> String? in
                    if let inner = block["content"] as? [String: Any] {
                        return inner["text"] as? String
                    }
                    return block["text"] as? String
                }.joined(separator: "\n")
                output = text.isEmpty ? nil : text
            }
            AssistantToolEventBus.publish(
                AssistantToolEvent(
                    id: id,
                    // An update carries no title; leaving it empty lets the
                    // transcript keep the name from the original call.
                    name: kind == "tool_call" ? name : "",
                    state: state,
                    output: state == .failed ? nil : output,
                    errorText: state == .failed ? output : nil,
                    scopeID: eventScopeID))
            return
        }

        guard kind == "agent_message_chunk" || kind == "agent_thought_chunk" else { return }
        if let content = update["content"] as? [String: Any],
           (content["type"] as? String) == "text",
           let text = content["text"] as? String, !text.isEmpty {
            turnAccumulator += text
            emitPartialThrottled()
        }
    }

    /// Throttle live partial callbacks to ~10/s so the UI isn't flooded.
    private func emitPartialThrottled() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPartialAt > 0.1, let onPartial else { return }
        lastPartialAt = now
        let snapshot = turnAccumulator
        DispatchQueue.main.async { onPartial(snapshot) }
    }
}

enum ACPBridgeError: LocalizedError {
    case processUnavailable(String)
    case protocolViolation(String)
    case rpcError(String)
    case timeout(String)
    case emptyResponse(String)

    var errorDescription: String? {
        switch self {
        case .processUnavailable(let m), .protocolViolation(let m),
             .rpcError(let m), .timeout(let m):
            return m
        case .emptyResponse(let provider):
            return "\(provider) returned an empty response."
        }
    }
}
