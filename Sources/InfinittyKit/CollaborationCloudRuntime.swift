import Foundation

struct CollaborationCloudRuntimeContext: Sendable {
    let proposalID: String
    let agent: CollaborationAgentSpec
    let workspace: String
    let previousReceipt: CollaborationRuntimeSessionReceipt?
}

protocol CollaborationAgentRuntimeAdapter: AnyObject, Sendable {
    func prepare() async throws
        -> CollaborationRuntimeSessionReceipt
    func turn(
        system: String,
        user: String,
        timeout: TimeInterval,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String
    func interrupt() async
    func close() async
}

protocol CollaborationCloudRuntimeFactoryProtocol: Sendable {
    func makeAdapter(
        context: CollaborationCloudRuntimeContext
    ) throws -> any CollaborationAgentRuntimeAdapter
}

/// Chat transport closures backed by one prepared remote session. The
/// conversation id is intentionally ignored: the durable provider receipt,
/// not an in-process CLI key, owns cloud resume/cancel/close semantics.
struct CollaborationCloudChatBindings {
    let backendRunner: PetAssistant.BackendRunner
    let cancel: @Sendable (String) -> Void
    let release: @Sendable (String) -> Void

    init(adapter: any CollaborationAgentRuntimeAdapter) {
        backendRunner = {
            _, system, user, _, _, onPartial, timeout, done in
            let callbacks = CollaborationCloudCallbackBox(
                partial: onPartial,
                done: done)
            Task {
                do {
                    let answer = try await adapter.turn(
                        system: system,
                        user: user,
                        timeout: timeout ?? 120,
                        onPartial: { text in
                            callbacks.partial?(text)
                        })
                    callbacks.done(.text(answer))
                } catch {
                    callbacks.done(.failure(
                        "Cloud agent failed: "
                            + String(describing: error)))
                }
            }
        }
        cancel = { _ in
            Task { await adapter.interrupt() }
        }
        release = { _ in
            Task { await adapter.close() }
        }
    }
}

private final class CollaborationCloudCallbackBox:
    @unchecked Sendable
{
    let partial: ((String) -> Void)?
    let done: (PetAssistant.AIOutcome) -> Void

    init(
        partial: ((String) -> Void)?,
        done: @escaping (PetAssistant.AIOutcome) -> Void
    ) {
        self.partial = partial
        self.done = done
    }
}

enum CollaborationCloudRuntimeError:
    Error, Equatable, CustomStringConvertible
{
    case invalidConfiguration(String)
    case credentialUnavailable(String)
    case authenticationFailed(Int)
    case transport(String)
    case protocolViolation(String)
    case remoteFailure(String)
    case timeout
    case requiresAction([String])
    case closed

    var description: String {
        switch self {
        case let .invalidConfiguration(reason):
            return "invalid cloud runtime configuration: \(reason)"
        case let .credentialUnavailable(reference):
            return "cloud credential reference \(reference) is unavailable"
        case let .authenticationFailed(status):
            return "cloud authentication failed with HTTP \(status)"
        case let .transport(reason):
            return "cloud transport failed: \(reason)"
        case let .protocolViolation(reason):
            return "cloud protocol violation: \(reason)"
        case let .remoteFailure(reason):
            return "cloud runtime failed: \(reason)"
        case .timeout:
            return "cloud runtime timed out"
        case let .requiresAction(eventIDs):
            return "cloud runtime requires explicit tool approval: "
                + eventIDs.joined(separator: ", ")
        case .closed:
            return "cloud runtime is closed"
        }
    }
}

struct CollaborationCloudHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
}

struct CollaborationCloudHTTPLineStream: Sendable {
    let statusCode: Int
    let lines: AsyncThrowingStream<String, Error>
}

protocol CollaborationCloudHTTPTransport: Sendable {
    func data(
        for request: URLRequest
    ) async throws -> CollaborationCloudHTTPResponse
    func openLineStream(
        for request: URLRequest
    ) async throws -> CollaborationCloudHTTPLineStream
}

final class URLSessionCollaborationCloudHTTPTransport:
    CollaborationCloudHTTPTransport, @unchecked Sendable
{
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(
        for request: URLRequest
    ) async throws -> CollaborationCloudHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CollaborationCloudRuntimeError.transport(
                "response was not HTTP")
        }
        return CollaborationCloudHTTPResponse(
            statusCode: response.statusCode,
            data: data)
    }

    func openLineStream(
        for request: URLRequest
    ) async throws -> CollaborationCloudHTTPLineStream {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CollaborationCloudRuntimeError.transport(
                "stream response was not HTTP")
        }
        let lines = AsyncThrowingStream<String, Error> {
            continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return CollaborationCloudHTTPLineStream(
            statusCode: response.statusCode,
            lines: lines)
    }
}

protocol CollaborationCodexWebSocketConnection: Sendable {
    func start()
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

protocol CollaborationCodexWebSocketFactory: Sendable {
    func make(
        request: URLRequest
    ) -> any CollaborationCodexWebSocketConnection
}

struct URLSessionCollaborationCodexWebSocketFactory:
    CollaborationCodexWebSocketFactory, Sendable
{
    func make(
        request: URLRequest
    ) -> any CollaborationCodexWebSocketConnection {
        URLSessionCollaborationCodexWebSocketConnection(
            request: request)
    }
}

final class URLSessionCollaborationCodexWebSocketConnection:
    CollaborationCodexWebSocketConnection, @unchecked Sendable
{
    private let task: URLSessionWebSocketTask

    init(
        request: URLRequest,
        session: URLSession = .shared
    ) {
        task = session.webSocketTask(with: request)
    }

    func start() {
        task.resume()
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data):
            return data
        case .string(let string):
            return Data(string.utf8)
        @unknown default:
            throw CollaborationCloudRuntimeError.transport(
                "unsupported WebSocket message")
        }
    }

    func close() {
        task.cancel(
            with: .goingAway,
            reason: nil)
    }
}

final class CollaborationCloudRuntimeFactory:
    CollaborationCloudRuntimeFactoryProtocol, @unchecked Sendable
{
    private let environment: [String: String]
    private let http: any CollaborationCloudHTTPTransport
    private let webSockets: any CollaborationCodexWebSocketFactory
    private let now: @Sendable () -> Date
    private let idFactory: @Sendable () -> String

    init(
        environment: [String: String] =
            ProcessInfo.processInfo.environment,
        http: any CollaborationCloudHTTPTransport =
            URLSessionCollaborationCloudHTTPTransport(),
        webSockets: any CollaborationCodexWebSocketFactory =
            URLSessionCollaborationCodexWebSocketFactory(),
        now: @escaping @Sendable () -> Date = { Date() },
        idFactory: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.environment = environment
        self.http = http
        self.webSockets = webSockets
        self.now = now
        self.idFactory = idFactory
    }

    func makeAdapter(
        context: CollaborationCloudRuntimeContext
    ) throws -> any CollaborationAgentRuntimeAdapter {
        guard context.agent.runtime == .cloud,
              let connection = context.agent.cloudConnection
        else {
            throw CollaborationCloudRuntimeError
                .invalidConfiguration(
                    "cloud agents require an approved connection")
        }
        let reference =
            connection.credentialEnvironmentVariable
        guard let credential = environment[reference],
              !credential.isEmpty
        else {
            throw CollaborationCloudRuntimeError
                .credentialUnavailable(reference)
        }
        switch context.agent.provider.lowercased() {
        case "codex":
            return CodexCloudAgentAdapter(
                context: context,
                connection: connection,
                credential: credential,
                webSockets: webSockets,
                now: now,
                idFactory: idFactory)
        case "claude":
            return ClaudeManagedAgentAdapter(
                context: context,
                connection: connection,
                credential: credential,
                http: http,
                now: now,
                idFactory: idFactory)
        default:
            throw CollaborationCloudRuntimeError
                .invalidConfiguration(
                    "unsupported cloud provider "
                        + context.agent.provider)
        }
    }
}

actor CodexCloudAgentAdapter:
    CollaborationAgentRuntimeAdapter
{
    private let context: CollaborationCloudRuntimeContext
    private let connection: CollaborationCloudConnection
    private let credential: String
    private let webSockets: any CollaborationCodexWebSocketFactory
    private let now: @Sendable () -> Date
    private let idFactory: @Sendable () -> String
    private var socket:
        (any CollaborationCodexWebSocketConnection)?
    private var threadID: String?
    private var activeTurnID: String?
    private var nextRequestID = 1
    private var bufferedNotifications: [[String: Any]] = []
    private var closed = false
    private var turnInFlight = false

    init(
        context: CollaborationCloudRuntimeContext,
        connection: CollaborationCloudConnection,
        credential: String,
        webSockets: any CollaborationCodexWebSocketFactory,
        now: @escaping @Sendable () -> Date,
        idFactory: @escaping @Sendable () -> String
    ) {
        self.context = context
        self.connection = connection
        self.credential = credential
        self.webSockets = webSockets
        self.now = now
        self.idFactory = idFactory
    }

    func prepare() async throws
        -> CollaborationRuntimeSessionReceipt
    {
        guard !closed else {
            throw CollaborationCloudRuntimeError.closed
        }
        guard let url = URL(string: connection.endpointURL) else {
            throw CollaborationCloudRuntimeError
                .invalidConfiguration("Codex endpoint is invalid")
        }
        // Codex app-server WebSocket transport is currently an experimental
        // upstream surface. Infinitty therefore requires an explicit,
        // credential-free WSS endpoint in the approved proposal and never
        // manufactures a public listener or downgrades to a local CLI.
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Bearer \(credential)",
            forHTTPHeaderField: "Authorization")
        let socket = webSockets.make(request: request)
        socket.start()
        self.socket = socket
        let initialize = try await requestRPC(
            "initialize",
            params: [
                "clientInfo": [
                    "name": "infinitty",
                    "title": "Infinitty Channels",
                    "version": "0.1.0",
                ],
                "capabilities": [
                    "experimentalApi": false,
                ],
            ])
        try await sendJSON([
            "method": "initialized",
            "params": [:] as [String: Any],
        ])

        let remoteThread: String
        if let previous = context.previousReceipt {
            var params: [String: Any] = [
                "threadId": previous.remoteSessionID,
                "cwd": context.workspace,
            ]
            if let model = context.agent.modelID {
                params["model"] = model
            }
            let response = try await requestRPC(
                "thread/resume",
                params: params)
            remoteThread = try Self.threadID(from: response)
            guard remoteThread == previous.remoteSessionID else {
                throw CollaborationCloudRuntimeError
                    .protocolViolation(
                        "Codex resume returned a different thread")
            }
        } else {
            var params: [String: Any] = [
                "cwd": context.workspace,
                "approvalPolicy": "never",
                "sandbox": "workspaceWrite",
                "serviceName": "infinitty",
            ]
            if let model = context.agent.modelID {
                params["model"] = model
            }
            let response = try await requestRPC(
                "thread/start",
                params: params)
            remoteThread = try Self.threadID(from: response)
        }
        threadID = remoteThread
        let account = Self.accountFingerprint(from: initialize)
        return CollaborationRuntimeSessionReceipt(
            id: "runtime-\(idFactory())",
            proposalID: context.proposalID,
            agentID: context.agent.id,
            adapterKind: "codex_app_server",
            provider: "codex",
            remoteSessionID: remoteThread,
            workspace: context.workspace,
            modelID: context.agent.modelID,
            endpointFingerprint:
                CollaborationRuntimeSessionReceipt.fingerprint(
                    endpointURL: connection.endpointURL),
            accountFingerprint: account,
            capabilities: ["interrupt", "resume", "stream"],
            preparedAt: now())
    }

    func turn(
        system: String,
        user: String,
        timeout: TimeInterval,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        guard !closed else {
            throw CollaborationCloudRuntimeError.closed
        }
        guard !turnInFlight else {
            throw CollaborationCloudRuntimeError.remoteFailure(
                "another Codex turn is already running")
        }
        guard let threadID else {
            throw CollaborationCloudRuntimeError.protocolViolation(
                "Codex adapter was not prepared")
        }
        turnInFlight = true
        defer {
            turnInFlight = false
            activeTurnID = nil
        }
        return try await withThrowingTaskGroup(
            of: String.self
        ) { group in
            group.addTask {
                try await self.performTurn(
                    threadID: threadID,
                    prompt: system + "\n\n" + user,
                    onPartial: onPartial)
            }
            group.addTask {
                let boundedTimeout = min(max(timeout, 1), 86_400)
                let nanoseconds = UInt64(
                    boundedTimeout * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                await self.interrupt()
                throw CollaborationCloudRuntimeError.timeout
            }
            guard let result = try await group.next() else {
                throw CollaborationCloudRuntimeError.transport(
                    "Codex turn produced no result")
            }
            group.cancelAll()
            return result
        }
    }

    func interrupt() async {
        guard let threadID, let activeTurnID else { return }
        _ = try? await requestRPC(
            "turn/interrupt",
            params: [
                "threadId": threadID,
                "turnId": activeTurnID,
            ])
    }

    func close() async {
        closed = true
        socket?.close()
        socket = nil
    }

    private func performTurn(
        threadID: String,
        prompt: String,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let response = try await requestRPC(
            "turn/start",
            params: [
                "threadId": threadID,
                "input": [[
                    "type": "text",
                    "text": prompt,
                ]],
                "cwd": context.workspace,
                "approvalPolicy": "never",
                "sandboxPolicy": [
                    "type": "workspaceWrite",
                    "writableRoots": [] as [String],
                    "networkAccess": false,
                    "excludeTmpdirEnvVar": false,
                    "excludeSlashTmp": false,
                ],
            ])
        guard let turn = response["turn"] as? [String: Any],
              let turnID = turn["id"] as? String
        else {
            throw CollaborationCloudRuntimeError.protocolViolation(
                "turn/start returned no turn id")
        }
        activeTurnID = turnID
        var text = ""
        var streamedItems = Set<String>()
        while true {
            let message = try await nextNotification()
            let method = message["method"] as? String
            let params =
                message["params"] as? [String: Any] ?? [:]
            let notificationTurnID =
                (params["turnId"] as? String)
                ?? (params["turn_id"] as? String)
                ?? ((params["turn"] as? [String: Any])?["id"]
                    as? String)
            if let notificationTurnID,
               notificationTurnID != turnID
            {
                // Only one turn may be active on this adapter. A stale
                // notification belongs to an already-finished turn; putting
                // it back at the head would create an infinite replay loop.
                continue
            }
            switch method {
            case "item/agentMessage/delta":
                guard let delta = params["delta"] as? String else {
                    continue
                }
                text += delta
                if let itemID = params["itemId"] as? String {
                    streamedItems.insert(itemID)
                }
                onPartial?(text)
            case "item/completed":
                guard let item =
                        params["item"] as? [String: Any],
                      item["type"] as? String == "agentMessage",
                      let itemText = item["text"] as? String
                else { continue }
                let itemID = item["id"] as? String
                if itemID.map({
                    !streamedItems.contains($0)
                }) ?? true {
                    if !text.isEmpty { text += "\n" }
                    text += itemText
                    onPartial?(text)
                }
            case "turn/completed":
                let status =
                    (params["turn"] as? [String: Any])?["status"]
                        as? String
                if status == "failed" || status == "aborted" {
                    throw CollaborationCloudRuntimeError.remoteFailure(
                        Self.errorMessage(params)
                            ?? "Codex turn \(status ?? "failed")")
                }
                let final = text.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                guard !final.isEmpty else {
                    throw CollaborationCloudRuntimeError
                        .protocolViolation(
                            "Codex completed without agent text")
                }
                return final
            case "turn/aborted", "turn/failed":
                throw CollaborationCloudRuntimeError.remoteFailure(
                    Self.errorMessage(params)
                        ?? "Codex turn failed")
            case "error":
                if params["willRetry"] as? Bool != true {
                    throw CollaborationCloudRuntimeError.remoteFailure(
                        Self.errorMessage(params)
                            ?? "Codex reported an error")
                }
            case "thread/status/changed":
                if let status =
                    params["status"] as? [String: Any],
                   status["type"] as? String == "systemError"
                {
                    throw CollaborationCloudRuntimeError.remoteFailure(
                        "Codex thread entered systemError")
                }
            default:
                continue
            }
        }
    }

    private func requestRPC(
        _ method: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        let requestID = nextRequestID
        nextRequestID += 1
        try await sendJSON([
            "id": requestID,
            "method": method,
            "params": params,
        ])
        while true {
            let message = try await receiveJSON()
            if let id = message["id"] as? Int, id == requestID {
                if let error =
                    message["error"] as? [String: Any]
                {
                    let code = error["code"] as? Int
                    let detail =
                        error["message"] as? String
                        ?? "JSON-RPC error"
                    throw CollaborationCloudRuntimeError.remoteFailure(
                        code.map { "\($0): \(detail)" } ?? detail)
                }
                guard let result =
                        message["result"] as? [String: Any]
                else {
                    throw CollaborationCloudRuntimeError
                        .protocolViolation(
                            "\(method) returned no result")
                }
                return result
            }
            if message["method"] != nil {
                bufferedNotifications.append(message)
            }
        }
    }

    private func nextNotification() async throws
        -> [String: Any]
    {
        if !bufferedNotifications.isEmpty {
            return bufferedNotifications.removeFirst()
        }
        while true {
            let message = try await receiveJSON()
            if message["method"] != nil { return message }
        }
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CollaborationCloudRuntimeError.protocolViolation(
                "outbound Codex JSON is invalid")
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys])
        guard let socket else {
            throw CollaborationCloudRuntimeError.closed
        }
        do {
            try await socket.send(data)
        } catch {
            throw CollaborationCloudRuntimeError.transport(
                error.localizedDescription)
        }
    }

    private func receiveJSON() async throws -> [String: Any] {
        guard let socket else {
            throw CollaborationCloudRuntimeError.closed
        }
        do {
            let data = try await socket.receive()
            guard let object =
                    try JSONSerialization.jsonObject(with: data)
                        as? [String: Any]
            else {
                throw CollaborationCloudRuntimeError
                    .protocolViolation(
                        "Codex sent non-object JSON")
            }
            return object
        } catch let error as CollaborationCloudRuntimeError {
            throw error
        } catch {
            throw CollaborationCloudRuntimeError.transport(
                error.localizedDescription)
        }
    }

    private static func threadID(
        from response: [String: Any]
    ) throws -> String {
        guard let thread =
                response["thread"] as? [String: Any],
              let id = thread["id"] as? String,
              !id.isEmpty
        else {
            throw CollaborationCloudRuntimeError.protocolViolation(
                "thread response returned no id")
        }
        return id
    }

    private static func accountFingerprint(
        from initialize: [String: Any]
    ) -> String? {
        let account =
            (initialize["account"] as? [String: Any])?["id"]
                as? String
        guard let account else { return nil }
        return endpointFingerprint(account)
    }

    private static func errorMessage(
        _ params: [String: Any]
    ) -> String? {
        ((params["error"] as? [String: Any])?["message"]
            as? String)
            ?? ((params["turn"] as? [String: Any])?["error"]
                as? [String: Any])?["message"] as? String
    }

    fileprivate static func endpointFingerprint(
        _ value: String
    ) -> String {
        CollaborationRuntimeSessionReceipt.fingerprint(
            endpointURL: value)
    }
}

actor ClaudeManagedAgentAdapter:
    CollaborationAgentRuntimeAdapter
{
    private let context: CollaborationCloudRuntimeContext
    private let connection: CollaborationCloudConnection
    private let credential: String
    private let http: any CollaborationCloudHTTPTransport
    private let now: @Sendable () -> Date
    private let idFactory: @Sendable () -> String
    private var sessionID: String?
    private var closed = false
    private var turnInFlight = false

    init(
        context: CollaborationCloudRuntimeContext,
        connection: CollaborationCloudConnection,
        credential: String,
        http: any CollaborationCloudHTTPTransport,
        now: @escaping @Sendable () -> Date,
        idFactory: @escaping @Sendable () -> String
    ) {
        self.context = context
        self.connection = connection
        self.credential = credential
        self.http = http
        self.now = now
        self.idFactory = idFactory
    }

    func prepare() async throws
        -> CollaborationRuntimeSessionReceipt
    {
        guard !closed else {
            throw CollaborationCloudRuntimeError.closed
        }
        let remoteSessionID: String
        let accountFingerprint: String?
        if let previous = context.previousReceipt {
            let response = try await perform(
                method: "GET",
                path: "/v1/sessions/"
                    + Self.pathComponent(
                        previous.remoteSessionID))
            let object = try Self.object(response.data)
            guard let id = object["id"] as? String,
                  id == previous.remoteSessionID
            else {
                throw CollaborationCloudRuntimeError
                    .protocolViolation(
                        "Claude resume returned a different session")
            }
            remoteSessionID = id
            accountFingerprint =
                Self.accountFingerprint(object)
        } else {
            guard let agentID = connection.agentID,
                  let environmentID = connection.environmentID
            else {
                throw CollaborationCloudRuntimeError
                    .invalidConfiguration(
                        "Claude requires agentID and environmentID")
            }
            var payload: [String: Any] = [
                "agent": agentID,
                "environment_id": environmentID,
            ]
            if !connection.vaultIDs.isEmpty {
                payload["vault_ids"] = connection.vaultIDs
            }
            let response = try await perform(
                method: "POST",
                path: "/v1/sessions",
                json: payload)
            let object = try Self.object(response.data)
            guard let id = object["id"] as? String,
                  !id.isEmpty
            else {
                throw CollaborationCloudRuntimeError
                    .protocolViolation(
                        "Claude session create returned no id")
            }
            remoteSessionID = id
            accountFingerprint =
                Self.accountFingerprint(object)
        }
        sessionID = remoteSessionID
        return CollaborationRuntimeSessionReceipt(
            id: "runtime-\(idFactory())",
            proposalID: context.proposalID,
            agentID: context.agent.id,
            adapterKind: "claude_managed_agents",
            provider: "claude",
            remoteSessionID: remoteSessionID,
            workspace: context.workspace,
            modelID: context.agent.modelID,
            endpointFingerprint:
                CollaborationRuntimeSessionReceipt.fingerprint(
                    endpointURL: connection.endpointURL),
            accountFingerprint: accountFingerprint,
            capabilities: [
                "authoritative_buffered_events",
                "interrupt",
                "resume",
                "stream_preview",
            ],
            preparedAt: now())
    }

    func turn(
        system: String,
        user: String,
        timeout: TimeInterval,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        guard !closed else {
            throw CollaborationCloudRuntimeError.closed
        }
        guard !turnInFlight else {
            throw CollaborationCloudRuntimeError.remoteFailure(
                "another Claude turn is already running")
        }
        guard let sessionID else {
            throw CollaborationCloudRuntimeError.protocolViolation(
                "Claude adapter was not prepared")
        }
        turnInFlight = true
        defer { turnInFlight = false }
        return try await withThrowingTaskGroup(
            of: String.self
        ) { group in
            group.addTask {
                try await self.performTurn(
                    sessionID: sessionID,
                    prompt: system + "\n\n" + user,
                    onPartial: onPartial)
            }
            group.addTask {
                let boundedTimeout = min(max(timeout, 1), 86_400)
                let nanoseconds = UInt64(
                    boundedTimeout * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                await self.interrupt()
                throw CollaborationCloudRuntimeError.timeout
            }
            guard let result = try await group.next() else {
                throw CollaborationCloudRuntimeError.transport(
                    "Claude turn produced no result")
            }
            group.cancelAll()
            return result
        }
    }

    func interrupt() async {
        guard let sessionID else { return }
        _ = try? await sendEvents(
            sessionID: sessionID,
            events: [[
                "type": "user.interrupt",
            ]])
    }

    func close() async {
        closed = true
    }

    private func performTurn(
        sessionID: String,
        prompt: String,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let streamRequest = try request(
            method: "GET",
            path: "/v1/sessions/"
                + Self.pathComponent(sessionID)
                + "/events/stream?event_deltas%5B%5D=agent.message",
            accept: "text/event-stream")
        let stream = try await http.openLineStream(
            for: streamRequest)
        try Self.validate(statusCode: stream.statusCode)
        try await sendEvents(
            sessionID: sessionID,
            events: [[
                "type": "user.message",
                "content": [[
                    "type": "text",
                    "text": prompt,
                ]],
            ]])

        var authoritative: [String] = []
        var previews: [String: String] = [:]
        for try await line in stream.lines {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5)
                .trimmingCharacters(in: .whitespaces)
            guard let data = json.data(using: .utf8),
                  let event =
                    try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                  let type = event["type"] as? String
            else { continue }
            switch type {
            case "event_start":
                if let value =
                    event["event"] as? [String: Any],
                   value["type"] as? String == "agent.message",
                   let id = value["id"] as? String
                {
                    previews[id] = ""
                }
            case "event_delta":
                guard let id = event["event_id"] as? String,
                      let delta =
                        event["delta"] as? [String: Any],
                      let content =
                        delta["content"] as? [String: Any],
                      content["type"] as? String == "text",
                      let text = content["text"] as? String
                else { continue }
                previews[id, default: ""] += text
                onPartial?(
                    (authoritative + [previews[id] ?? ""])
                        .joined(separator: "\n"))
            case "agent.message":
                let text = Self.contentText(event["content"])
                if !text.isEmpty {
                    authoritative.append(text)
                    onPartial?(
                        authoritative.joined(separator: "\n"))
                }
                if let id = event["id"] as? String {
                    previews.removeValue(forKey: id)
                }
            case "session.status_idle",
                 "session.thread_status_idle":
                if let stopReason =
                    event["stop_reason"] as? [String: Any],
                   stopReason["type"] as? String
                        == "requires_action"
                {
                    throw CollaborationCloudRuntimeError
                        .requiresAction(
                            stopReason["event_ids"] as? [String]
                                ?? [])
                }
                let result = authoritative.joined(
                    separator: "\n")
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines)
                guard !result.isEmpty else {
                    throw CollaborationCloudRuntimeError
                        .protocolViolation(
                            "Claude went idle without an authoritative agent.message")
                }
                return result
            case "session.error", "agent.error":
                throw CollaborationCloudRuntimeError.remoteFailure(
                    event["message"] as? String
                        ?? "Claude session reported an error")
            default:
                continue
            }
        }
        throw CollaborationCloudRuntimeError.transport(
            "Claude event stream ended before idle")
    }

    private func sendEvents(
        sessionID: String,
        events: [[String: Any]]
    ) async throws {
        _ = try await perform(
            method: "POST",
            path: "/v1/sessions/"
                + Self.pathComponent(sessionID)
                + "/events",
            json: ["events": events])
    }

    private func perform(
        method: String,
        path: String,
        json: [String: Any]? = nil
    ) async throws -> CollaborationCloudHTTPResponse {
        let response = try await http.data(
            for: request(
                method: method,
                path: path,
                json: json))
        try Self.validate(statusCode: response.statusCode)
        return response
    }

    private func request(
        method: String,
        path: String,
        json: [String: Any]? = nil,
        accept: String = "application/json"
    ) throws -> URLRequest {
        guard let base = URL(string: connection.endpointURL),
              let url = URL(
                  string: path,
                  relativeTo: base)?.absoluteURL
        else {
            throw CollaborationCloudRuntimeError
                .invalidConfiguration(
                    "Claude endpoint is invalid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue(
            "2023-06-01",
            forHTTPHeaderField: "anthropic-version")
        request.setValue(
            "managed-agents-2026-04-01",
            forHTTPHeaderField: "anthropic-beta")
        request.setValue(
            accept,
            forHTTPHeaderField: "Accept")
        switch connection.authentication {
        case .apiKey:
            request.setValue(
                credential,
                forHTTPHeaderField: "x-api-key")
        case .bearer:
            request.setValue(
                "Bearer \(credential)",
                forHTTPHeaderField: "Authorization")
        }
        if let json {
            guard JSONSerialization.isValidJSONObject(json) else {
                throw CollaborationCloudRuntimeError
                    .protocolViolation(
                        "outbound Claude JSON is invalid")
            }
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(
                withJSONObject: json,
                options: [.sortedKeys])
        }
        return request
    }

    private static func validate(statusCode: Int) throws {
        guard (200..<300).contains(statusCode) else {
            if statusCode == 401 || statusCode == 403 {
                throw CollaborationCloudRuntimeError
                    .authenticationFailed(statusCode)
            }
            throw CollaborationCloudRuntimeError.remoteFailure(
                "Claude HTTP \(statusCode)")
        }
    }

    private static func object(
        _ data: Data
    ) throws -> [String: Any] {
        guard let object =
                try JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
        else {
            throw CollaborationCloudRuntimeError
                .protocolViolation(
                    "Claude returned non-object JSON")
        }
        return object
    }

    private static func contentText(_ value: Any?) -> String {
        guard let blocks = value as? [[String: Any]] else {
            return ""
        }
        return blocks.compactMap { block in
            guard block["type"] as? String == "text" else {
                return nil
            }
            return block["text"] as? String
        }.joined()
    }

    private static func accountFingerprint(
        _ object: [String: Any]
    ) -> String? {
        let account =
            object["organization_id"] as? String
            ?? object["workspace_id"] as? String
        guard let account else { return nil }
        return CodexCloudAgentAdapter.endpointFingerprint(account)
    }

    private static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? ""
    }
}
