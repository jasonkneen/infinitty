import Foundation
import XCTest

@testable import InfinittyKit

final class CollaborationCloudRuntimeTests: XCTestCase {
    func testFactoryFailsClosedWhenApprovedCredentialIsUnavailable()
        throws
    {
        let sockets = ScriptedCodexSocketFactory(
            socket: ScriptedCodexSocket(responses: []))
        let factory = CollaborationCloudRuntimeFactory(
            environment: [:],
            http: ScriptedCloudHTTPTransport(),
            webSockets: sockets)

        XCTAssertThrowsError(try factory.makeAdapter(
            context: context(agent: codexAgent()))) { error in
                XCTAssertEqual(
                    error as? CollaborationCloudRuntimeError,
                    .credentialUnavailable("CODEX_CHANNEL_TOKEN"))
            }
        XCTAssertNil(sockets.request)
    }

    func testCodexAdapterUsesApprovedWSSIdentityWorkspaceAndStreams()
        async throws
    {
        let socket = ScriptedCodexSocket(responses: [
            rpcResult(1, [
                "account": ["id": "account-7"],
            ]),
            rpcResult(2, [
                "thread": ["id": "thread-42"],
            ]),
            rpcResult(3, [
                "turn": ["id": "turn-9"],
            ]),
            notification(
                "item/agentMessage/delta",
                [
                    "turnId": "turn-9",
                    "itemId": "message-1",
                    "delta": "Verified ",
                ]),
            notification(
                "item/agentMessage/delta",
                [
                    "turnId": "turn-9",
                    "itemId": "message-1",
                    "delta": "result",
                ]),
            notification(
                "turn/completed",
                [
                    "turn": [
                        "id": "turn-9",
                        "status": "completed",
                    ],
                ]),
        ])
        let sockets = ScriptedCodexSocketFactory(socket: socket)
        let now = Date(timeIntervalSince1970: 12_345)
        let factory = CollaborationCloudRuntimeFactory(
            environment: ["CODEX_CHANNEL_TOKEN": "secret-token"],
            http: ScriptedCloudHTTPTransport(),
            webSockets: sockets,
            now: { now },
            idFactory: { "fixed" })
        let adapter = try factory.makeAdapter(
            context: context(agent: codexAgent()))

        let receipt = try await adapter.prepare()
        XCTAssertEqual(receipt.adapterKind, "codex_app_server")
        XCTAssertEqual(receipt.remoteSessionID, "thread-42")
        XCTAssertEqual(receipt.workspace, "/approved/worktree")
        XCTAssertEqual(receipt.modelID, "opaque-codex-model")
        XCTAssertEqual(receipt.preparedAt, now)
        XCTAssertEqual(
            sockets.request?.value(
                forHTTPHeaderField: "Authorization"),
            "Bearer secret-token")
        XCTAssertEqual(
            sockets.request?.url?.absoluteString,
            "wss://codex.example.test/app-server")

        let partials = LockedValues<String>()
        let answer = try await adapter.turn(
            system: "Channel channel-release; self Architect.",
            user: "Implement the approved scope.",
            approvalScopeID: nil,
            timeout: 2,
            onPartial: { partials.append($0) })

        XCTAssertEqual(answer, "Verified result")
        XCTAssertEqual(partials.values, ["Verified ", "Verified result"])
        let sent = socket.sentObjects
        XCTAssertEqual(sent.map { $0["method"] as? String }, [
            "initialize",
            "initialized",
            "thread/start",
            "turn/start",
        ])
        let start = try XCTUnwrap(sent.last)
        let params = try XCTUnwrap(start["params"] as? [String: Any])
        XCTAssertEqual(params["cwd"] as? String, "/approved/worktree")
        XCTAssertEqual(params["approvalPolicy"] as? String, "on-request")
        let input = try XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertTrue(
            (input.first?["text"] as? String)?
                .contains("Channel channel-release") == true)
        let threadStart = try XCTUnwrap(sent.first {
            $0["method"] as? String == "thread/start"
        })
        XCTAssertEqual(
            (threadStart["params"] as? [String: Any])?["approvalPolicy"]
                as? String,
            "on-request")
    }

    func testCodexApprovalRequestUsesChatScopeAndExactRPCResponse()
        async throws
    {
        let scopeID = "cloud-chat-scope"
        AssistantApprovalBroker.shared.cancel(scopeID: scopeID)
        defer {
            AssistantApprovalBroker.shared.cancel(scopeID: scopeID)
        }
        let socket = ScriptedCodexSocket(responses: [
            rpcResult(1, [:]),
            rpcResult(2, [
                "thread": ["id": "thread-approval"],
            ]),
            json([
                // Deliberately collides with the outstanding turn/start id.
                // A server request must be handled before client responses.
                "id": 3,
                "method": "item/commandExecution/requestApproval",
                "params": [
                    "threadId": "thread-approval",
                    "command": "swift test",
                    "cwd": "/approved/worktree",
                    "reason": "Run the focused verification suite.",
                    "availableDecisions": [
                        "accept", "acceptForSession", "decline",
                    ],
                ],
            ]),
            rpcResult(3, [
                "turn": ["id": "turn-approval"],
            ]),
            notification(
                "item/agentMessage/delta",
                [
                    "turnId": "turn-approval",
                    "itemId": "message-approval",
                    "delta": "Approved result",
                ]),
            notification(
                "turn/completed",
                [
                    "turn": [
                        "id": "turn-approval",
                        "status": "completed",
                    ],
                ]),
        ])
        let factory = CollaborationCloudRuntimeFactory(
            environment: ["CODEX_CHANNEL_TOKEN": "token"],
            http: ScriptedCloudHTTPTransport(),
            webSockets: ScriptedCodexSocketFactory(socket: socket))
        let adapter = try factory.makeAdapter(
            context: context(agent: codexAgent()))
        _ = try await adapter.prepare()
        let bindings = CollaborationCloudChatBindings(adapter: adapter)
        let outcomes = LockedValues<PetAssistant.AIOutcome>()
        let completed = expectation(description: "cloud turn completed")

        bindings.backendRunner(
            .codex(model: "opaque-codex-model"),
            "system",
            "user",
            "/approved/worktree",
            scopeID,
            nil,
            1,
            { outcome in
                outcomes.append(outcome)
                completed.fulfill()
            })

        let approval = try await waitForApproval(scopeID: scopeID)
        XCTAssertEqual(approval.provider, "Codex")
        XCTAssertEqual(approval.kind, .commandExecution)
        XCTAssertEqual(approval.scopeID, scopeID)
        XCTAssertTrue(approval.input?.contains("swift test") == true)
        XCTAssertTrue(AssistantApprovalBroker.shared.resolve(
            id: approval.id,
            scopeID: scopeID,
            decision: .allowOnce))

        await fulfillment(of: [completed], timeout: 2)
        guard case let .text(answer) = try XCTUnwrap(outcomes.values.first)
        else {
            return XCTFail("cloud turn did not return text")
        }
        XCTAssertEqual(answer, "Approved result")
        let response = try XCTUnwrap(socket.sentObjects.first {
            $0["method"] == nil && $0["id"] as? Int == 3
        })
        XCTAssertEqual(
            (response["result"] as? [String: Any])?["decision"]
                as? String,
            "accept")
        XCTAssertTrue(
            AssistantApprovalBroker.shared.pendingRequests(
                scopeID: scopeID).isEmpty)
    }

    func testCodexAdapterResumesThePersistedRemoteThread()
        async throws
    {
        let socket = ScriptedCodexSocket(responses: [
            rpcResult(1, [:]),
            rpcResult(2, [
                "thread": ["id": "thread-persisted"],
            ]),
        ])
        let factory = CollaborationCloudRuntimeFactory(
            environment: ["CODEX_CHANNEL_TOKEN": "token"],
            http: ScriptedCloudHTTPTransport(),
            webSockets: ScriptedCodexSocketFactory(socket: socket))
        let previous = receipt(
            adapterKind: "codex_app_server",
            provider: "codex",
            remoteSessionID: "thread-persisted")
        let adapter = try factory.makeAdapter(
            context: context(
                agent: codexAgent(),
                previousReceipt: previous))

        let recovered = try await adapter.prepare()

        XCTAssertEqual(recovered.remoteSessionID, "thread-persisted")
        let resume = try XCTUnwrap(
            socket.sentObjects.first {
                $0["method"] as? String == "thread/resume"
            })
        let params = try XCTUnwrap(
            resume["params"] as? [String: Any])
        XCTAssertEqual(
            params["threadId"] as? String,
            "thread-persisted")
        XCTAssertEqual(
            params["cwd"] as? String,
            "/approved/worktree")
        XCTAssertEqual(
            params["model"] as? String,
            "opaque-codex-model")
    }

    func testCodexAdapterRejectsResumeToDifferentRemoteThread()
        async throws
    {
        let socket = ScriptedCodexSocket(responses: [
            rpcResult(1, [:]),
            rpcResult(2, [
                "thread": ["id": "thread-substituted"],
            ]),
        ])
        let factory = CollaborationCloudRuntimeFactory(
            environment: ["CODEX_CHANNEL_TOKEN": "token"],
            http: ScriptedCloudHTTPTransport(),
            webSockets: ScriptedCodexSocketFactory(socket: socket))
        let previous = receipt(
            adapterKind: "codex_app_server",
            provider: "codex",
            remoteSessionID: "thread-approved")
        let adapter = try factory.makeAdapter(
            context: context(
                agent: codexAgent(),
                previousReceipt: previous))

        do {
            _ = try await adapter.prepare()
            XCTFail("resume unexpectedly accepted a different thread")
        } catch {
            XCTAssertEqual(
                error as? CollaborationCloudRuntimeError,
                .protocolViolation(
                    "Codex resume returned a different thread"))
        }
    }

    func testClaudeAdapterUsesManagedAgentAPIAndAuthoritativeEvents()
        async throws
    {
        let http = ScriptedCloudHTTPTransport(
            responses: [
                .init(
                    statusCode: 201,
                    data: json([
                        "id": "session-77",
                        "organization_id": "organization-3",
                    ])),
                .init(statusCode: 202, data: json([:])),
                .init(statusCode: 202, data: json([:])),
            ],
            streams: [
                .init(
                    statusCode: 200,
                    lines: lines([
                        sse([
                            "type": "event_start",
                            "event": [
                                "type": "agent.message",
                                "id": "message-4",
                            ],
                        ]),
                        sse([
                            "type": "event_delta",
                            "event_id": "message-4",
                            "delta": [
                                "content": [
                                    "type": "text",
                                    "text": "preview",
                                ],
                            ],
                        ]),
                        sse([
                            "type": "agent.message",
                            "id": "message-4",
                            "content": [[
                                "type": "text",
                                "text": "authoritative result",
                            ]],
                        ]),
                        sse([
                            "type": "session.status_idle",
                        ]),
                    ])),
            ])
        let factory = CollaborationCloudRuntimeFactory(
            environment: ["CLAUDE_CHANNEL_KEY": "api-secret"],
            http: http,
            webSockets: ScriptedCodexSocketFactory(
                socket: ScriptedCodexSocket(responses: [])),
            idFactory: { "claude-fixed" })
        let adapter = try factory.makeAdapter(
            context: context(agent: claudeAgent()))

        let receipt = try await adapter.prepare()
        XCTAssertEqual(receipt.adapterKind, "claude_managed_agents")
        XCTAssertEqual(receipt.remoteSessionID, "session-77")
        let partials = LockedValues<String>()
        let answer = try await adapter.turn(
            system: "Channel shared context.",
            user: "Do the assigned task.",
            approvalScopeID: nil,
            timeout: 2,
            onPartial: { partials.append($0) })
        await adapter.interrupt()

        XCTAssertEqual(answer, "authoritative result")
        XCTAssertEqual(partials.values, [
            "preview",
            "authoritative result",
        ])
        let requests = http.dataRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(
            requests[0].url?.path,
            "/v1/sessions")
        XCTAssertEqual(
            requests[0].value(
                forHTTPHeaderField: "x-api-key"),
            "api-secret")
        XCTAssertEqual(
            requests[0].value(
                forHTTPHeaderField: "anthropic-beta"),
            "managed-agents-2026-04-01")
        let create = try jsonObject(requests[0].httpBody)
        XCTAssertEqual(create["agent"] as? String, "agent-template")
        XCTAssertEqual(
            create["environment_id"] as? String,
            "environment-2")
        XCTAssertEqual(
            create["vault_ids"] as? [String],
            ["vault-a", "vault-b"])
        let turnBody = try jsonObject(requests[1].httpBody)
        XCTAssertEqual(
            eventType(in: turnBody),
            "user.message")
        let interruptBody = try jsonObject(requests[2].httpBody)
        XCTAssertEqual(
            eventType(in: interruptBody),
            "user.interrupt")
        XCTAssertEqual(http.streamRequests.count, 1)
        XCTAssertEqual(
            http.streamRequests[0].url?.path,
            "/v1/sessions/session-77/events/stream")
    }

    func testClaudeAuthenticationFailureProducesNoSessionReceipt()
        async throws
    {
        let http = ScriptedCloudHTTPTransport(
            responses: [
                .init(statusCode: 401, data: json([:])),
            ])
        let factory = CollaborationCloudRuntimeFactory(
            environment: ["CLAUDE_CHANNEL_KEY": "bad-key"],
            http: http,
            webSockets: ScriptedCodexSocketFactory(
                socket: ScriptedCodexSocket(responses: [])))
        let adapter = try factory.makeAdapter(
            context: context(agent: claudeAgent()))

        do {
            _ = try await adapter.prepare()
            XCTFail("prepare unexpectedly succeeded")
        } catch {
            XCTAssertEqual(
                error as? CollaborationCloudRuntimeError,
                .authenticationFailed(401))
        }
    }

    func testClaudeToolConfirmationUsesChatScopeAndManagedEventShape()
        async throws
    {
        let scopeID = "cloud-claude-scope"
        AssistantApprovalBroker.shared.cancel(scopeID: scopeID)
        defer {
            AssistantApprovalBroker.shared.cancel(scopeID: scopeID)
        }
        let http = ScriptedCloudHTTPTransport(
            responses: [
                .init(
                    statusCode: 201,
                    data: json(["id": "session-confirmation"])),
                .init(statusCode: 202, data: json([:])),
                .init(statusCode: 202, data: json([:])),
            ],
            streams: [
                .init(
                    statusCode: 200,
                    lines: lines([
                        sse([
                            "type": "agent.mcp_tool_use",
                            "id": "tool-request-mcp",
                            "name": "create_issue",
                            "mcp_server_name": "github",
                            "input": [
                                "repository": "owner/project",
                                "title": "Focused failure",
                            ],
                            "session_thread_id": "sthr_reviewer",
                        ]),
                        sse([
                            "type": "session.status_idle",
                            "stop_reason": [
                                "type": "requires_action",
                                "event_ids": ["tool-request-mcp"],
                            ],
                        ]),
                        sse([
                            "type": "agent.message",
                            "id": "message-after-confirmation",
                            "content": [[
                                "type": "text",
                                "text": "Tool request handled",
                            ]],
                        ]),
                        sse([
                            "type": "session.status_idle",
                            "stop_reason": ["type": "end_turn"],
                        ]),
                    ])),
            ])
        let factory = CollaborationCloudRuntimeFactory(
            environment: ["CLAUDE_CHANNEL_KEY": "key"],
            http: http,
            webSockets: ScriptedCodexSocketFactory(
                socket: ScriptedCodexSocket(responses: [])))
        let adapter = try factory.makeAdapter(
            context: context(agent: claudeAgent()))
        _ = try await adapter.prepare()
        let bindings = CollaborationCloudChatBindings(adapter: adapter)
        let outcomes = LockedValues<PetAssistant.AIOutcome>()
        let completed = expectation(description: "managed turn completed")

        bindings.backendRunner(
            .claude(model: "opaque-claude-model"),
            "system",
            "user",
            "/approved/worktree",
            scopeID,
            nil,
            2,
            { outcome in
                outcomes.append(outcome)
                completed.fulfill()
            })

        let approval = try await waitForApproval(scopeID: scopeID)
        XCTAssertEqual(approval.provider, "Claude")
        XCTAssertEqual(approval.kind, .toolUse)
        XCTAssertEqual(approval.toolName, "github / create_issue")
        XCTAssertEqual(
            approval.availableDecisions,
            [.allowOnce, .deny])
        XCTAssertTrue(approval.input?.contains("owner/project") == true)
        XCTAssertTrue(AssistantApprovalBroker.shared.resolve(
            id: approval.id,
            scopeID: scopeID,
            decision: .allowOnce))

        await fulfillment(of: [completed], timeout: 2)
        guard case let .text(answer) = try XCTUnwrap(outcomes.values.first)
        else {
            return XCTFail("managed turn did not return text")
        }
        XCTAssertEqual(answer, "Tool request handled")
        let requests = http.dataRequests
        XCTAssertEqual(requests.count, 3)
        let confirmationBody = try jsonObject(requests[2].httpBody)
        let confirmation = try XCTUnwrap(
            (confirmationBody["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            confirmation["type"] as? String,
            "user.tool_confirmation")
        XCTAssertEqual(
            confirmation["tool_use_id"] as? String,
            "tool-request-mcp")
        XCTAssertEqual(confirmation["result"] as? String, "allow")
        XCTAssertEqual(
            confirmation["session_thread_id"] as? String,
            "sthr_reviewer")
        XCTAssertNil(confirmation["deny_message"])
    }

    func testClaudeManagedApprovalDenialIsExplicitAndOneShot()
        throws
    {
        let approval = try XCTUnwrap(
            ClaudeManagedApprovalAdapter.approval(
                event: [
                    "type": "agent.tool_use",
                    "id": "tool-request-bash",
                    "name": "bash",
                    "input": ["command": "swift test"],
                ],
                scopeID: "scope-denial"))

        XCTAssertEqual(approval.request.kind, .commandExecution)
        XCTAssertEqual(
            approval.request.availableDecisions,
            [.allowOnce, .deny])
        let response = ClaudeManagedApprovalAdapter.confirmation(
            for: approval,
            decision: .deny)
        XCTAssertEqual(response["result"] as? String, "deny")
        XCTAssertEqual(
            response["deny_message"] as? String,
            "The user denied this tool request.")
        XCTAssertNil(response["session_thread_id"])
    }

    func testClaudeRequiresActionFailsClosed()
        async throws
    {
        let http = ScriptedCloudHTTPTransport(
            responses: [
                .init(
                    statusCode: 201,
                    data: json(["id": "session-action"])),
                .init(statusCode: 202, data: json([:])),
            ],
            streams: [
                .init(
                    statusCode: 200,
                    lines: lines([
                        sse([
                            "type": "session.status_idle",
                            "stop_reason": [
                                "type": "requires_action",
                                "event_ids": ["tool-request-1"],
                            ],
                        ]),
                    ])),
            ])
        let factory = CollaborationCloudRuntimeFactory(
            environment: ["CLAUDE_CHANNEL_KEY": "key"],
            http: http,
            webSockets: ScriptedCodexSocketFactory(
                socket: ScriptedCodexSocket(responses: [])))
        let adapter = try factory.makeAdapter(
            context: context(agent: claudeAgent()))
        _ = try await adapter.prepare()

        do {
            _ = try await adapter.turn(
                system: "system",
                user: "user",
                approvalScopeID: nil,
                timeout: 2,
                onPartial: nil)
            XCTFail("turn unexpectedly succeeded")
        } catch {
            XCTAssertEqual(
                error as? CollaborationCloudRuntimeError,
                .requiresAction(["tool-request-1"]))
        }
    }

    private func context(
        agent: CollaborationAgentSpec,
        previousReceipt: CollaborationRuntimeSessionReceipt? = nil
    ) -> CollaborationCloudRuntimeContext {
        CollaborationCloudRuntimeContext(
            proposalID: "proposal-cloud",
            agent: agent,
            workspace: "/approved/worktree",
            previousReceipt: previousReceipt)
    }

    private func codexAgent() -> CollaborationAgentSpec {
        CollaborationAgentSpec(
            id: "agent:codex",
            displayName: "Architect",
            role: "Implement Channels",
            runtime: .cloud,
            provider: "codex",
            modelID: "opaque-codex-model",
            cloudConnection: CollaborationCloudConnection(
                endpointURL:
                    "wss://codex.example.test/app-server",
                credentialEnvironmentVariable:
                    "CODEX_CHANNEL_TOKEN",
                remoteWorkspace: "/approved/worktree"))
    }

    private func claudeAgent() -> CollaborationAgentSpec {
        CollaborationAgentSpec(
            id: "agent:claude",
            displayName: "Reviewer",
            role: "Verify Channels",
            runtime: .cloud,
            provider: "claude",
            modelID: "opaque-claude-model",
            cloudConnection: CollaborationCloudConnection(
                endpointURL:
                    "https://api.anthropic.example.test",
                credentialEnvironmentVariable:
                    "CLAUDE_CHANNEL_KEY",
                authentication: .apiKey,
                remoteWorkspace: "/approved/worktree",
                agentID: "agent-template",
                environmentID: "environment-2",
                vaultIDs: ["vault-b", "vault-a"]))
    }

    private func receipt(
        adapterKind: String,
        provider: String,
        remoteSessionID: String
    ) -> CollaborationRuntimeSessionReceipt {
        CollaborationRuntimeSessionReceipt(
            id: "receipt-existing",
            proposalID: "proposal-cloud",
            agentID: "agent:codex",
            adapterKind: adapterKind,
            provider: provider,
            remoteSessionID: remoteSessionID,
            workspace: "/approved/worktree",
            modelID: "opaque-codex-model",
            endpointFingerprint: String(repeating: "a", count: 64),
            accountFingerprint: nil,
            capabilities: ["resume"],
            preparedAt: Date(timeIntervalSince1970: 100))
    }

    private func waitForApproval(
        scopeID: String
    ) async throws -> AssistantApprovalRequest {
        for _ in 0..<100 {
            if let request = AssistantApprovalBroker.shared
                .pendingRequests(scopeID: scopeID).first
            {
                return request
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try XCTUnwrap(
            AssistantApprovalBroker.shared
                .pendingRequests(scopeID: scopeID).first,
            "approval request did not reach the shared broker")
    }
}

private final class ScriptedCodexSocketFactory:
    CollaborationCodexWebSocketFactory, @unchecked Sendable
{
    private let lock = NSLock()
    private let socket: ScriptedCodexSocket
    private var storedRequest: URLRequest?

    init(socket: ScriptedCodexSocket) {
        self.socket = socket
    }

    var request: URLRequest? {
        lock.withLock { storedRequest }
    }

    func make(
        request: URLRequest
    ) -> any CollaborationCodexWebSocketConnection {
        lock.withLock {
            storedRequest = request
        }
        return socket
    }
}

private final class ScriptedCodexSocket:
    CollaborationCodexWebSocketConnection, @unchecked Sendable
{
    private let lock = NSLock()
    private var responses: [Data]
    private var sent: [Data] = []
    private(set) var started = false
    private(set) var closed = false

    init(responses: [Data]) {
        self.responses = responses
    }

    var sentObjects: [[String: Any]] {
        lock.withLock {
            sent.compactMap {
                try? JSONSerialization.jsonObject(with: $0)
                    as? [String: Any]
            }
        }
    }

    func start() {
        lock.withLock { started = true }
    }

    func send(_ data: Data) async throws {
        lock.withLock { sent.append(data) }
    }

    func receive() async throws -> Data {
        try lock.withLock {
            guard !responses.isEmpty else {
                throw CollaborationCloudRuntimeError.transport(
                    "scripted WebSocket exhausted")
            }
            return responses.removeFirst()
        }
    }

    func close() {
        lock.withLock { closed = true }
    }
}

private final class ScriptedCloudHTTPTransport:
    CollaborationCloudHTTPTransport, @unchecked Sendable
{
    private let lock = NSLock()
    private var responses: [CollaborationCloudHTTPResponse]
    private var streams: [CollaborationCloudHTTPLineStream]
    private var storedDataRequests: [URLRequest] = []
    private var storedStreamRequests: [URLRequest] = []

    init(
        responses: [CollaborationCloudHTTPResponse] = [],
        streams: [CollaborationCloudHTTPLineStream] = []
    ) {
        self.responses = responses
        self.streams = streams
    }

    var dataRequests: [URLRequest] {
        lock.withLock { storedDataRequests }
    }

    var streamRequests: [URLRequest] {
        lock.withLock { storedStreamRequests }
    }

    func data(
        for request: URLRequest
    ) async throws -> CollaborationCloudHTTPResponse {
        try lock.withLock {
            storedDataRequests.append(request)
            guard !responses.isEmpty else {
                throw CollaborationCloudRuntimeError.transport(
                    "scripted HTTP responses exhausted")
            }
            return responses.removeFirst()
        }
    }

    func openLineStream(
        for request: URLRequest
    ) async throws -> CollaborationCloudHTTPLineStream {
        try lock.withLock {
            storedStreamRequests.append(request)
            guard !streams.isEmpty else {
                throw CollaborationCloudRuntimeError.transport(
                    "scripted HTTP streams exhausted")
            }
            return streams.removeFirst()
        }
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    var values: [Value] {
        lock.withLock { stored }
    }

    func append(_ value: Value) {
        lock.withLock { stored.append(value) }
    }
}

private func rpcResult(
    _ id: Int,
    _ result: [String: Any]
) -> Data {
    json([
        "id": id,
        "result": result,
    ])
}

private func notification(
    _ method: String,
    _ params: [String: Any]
) -> Data {
    json([
        "method": method,
        "params": params,
    ])
}

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys])
}

private func jsonObject(_ data: Data?) throws -> [String: Any] {
    let data = try XCTUnwrap(data)
    return try XCTUnwrap(
        JSONSerialization.jsonObject(with: data)
            as? [String: Any])
}

private func sse(_ object: [String: Any]) -> String {
    "data: " + String(data: json(object), encoding: .utf8)!
}

private func lines(
    _ values: [String]
) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream(
        String.self,
        bufferingPolicy: .unbounded
    ) { continuation in
        for value in values {
            _ = continuation.yield(value)
        }
        continuation.finish()
    }
}

private func eventType(
    in object: [String: Any]
) -> String? {
    let events = object["events"] as? [[String: Any]]
    return events?.first?["type"] as? String
}
