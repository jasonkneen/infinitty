import Darwin
import Foundation
import XCTest

@testable import InfinittyKit

final class HeadlessAppHostTests: XCTestCase {
    func testHeadlessHostPublishesControlAndRegistryWithoutLaunchingAWindow()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let host = try HeadlessAppHost(
            instanceID: "headless-test",
            socketPath: fixture.socketPath,
            applicationSupportDirectory: fixture.support,
            publishesCurrentLink: false)

        try host.start(launchInitialTerminal: false)
        XCTAssertEqual(
            AppSocketClient.request("ping", socketPath: fixture.socketPath),
            "pong")

        let instanceText = try XCTUnwrap(
            AppSocketClient.request("instance", socketPath: fixture.socketPath))
        let instance = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(instanceText.utf8))
                as? [String: Any])
        XCTAssertEqual(instance["id"] as? String, "headless-test")
        XCTAssertEqual(instance["mode"] as? String, "headless")
        XCTAssertEqual(
            Set(instance["capabilities"] as? [String] ?? []),
            Set([
                "terminal", "terminal.run", "terminal.channel",
                "chat", "channel", "channel.panel",
                "events",
            ]))

        XCTAssertEqual(
            AppSocketClient.request("list", socketPath: fixture.socketPath),
            "[]")
        let registered = AppInstanceRegistry.list(
            baseDirectory: fixture.support)
        XCTAssertEqual(registered.map(\.id), ["headless-test"])
        XCTAssertEqual(registered.first?.mode, "headless")

        host.stop()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.socketPath))
        XCTAssertTrue(AppInstanceRegistry.list(
            baseDirectory: fixture.support).isEmpty)
    }

    func testHeadlessStructuredChatLifecycleMatchesVisualControl()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let host = try HeadlessAppHost(
            instanceID: "headless-chat",
            socketPath: fixture.socketPath,
            applicationSupportDirectory: fixture.support,
            publishesCurrentLink: false)
        try host.start(launchInitialTerminal: false)
        defer { host.stop() }

        func request(_ value: [String: Any]) throws -> [String: Any] {
            let encoded = try XCTUnwrap(BrowserControlCodec.encode(value))
            let response = try XCTUnwrap(AppSocketClient.request(
                "chat \(encoded)",
                socketPath: fixture.socketPath))
            let envelope = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(response.utf8))
                    as? [String: Any])
            XCTAssertEqual(
                envelope["ok"] as? Bool,
                true,
                "response=\(response)")
            return try XCTUnwrap(envelope["result"] as? [String: Any])
        }

        let created = try request([
            "v": 1,
            "op": "create",
            "name": "Headless Architect",
            "role": "planning lead",
            "provider": "amp",
            "model": "smart",
            "workspace": fixture.support.path,
        ])
        let chatID = try XCTUnwrap(created["chatId"] as? String)
        let paneID = try XCTUnwrap(created["paneId"] as? String)
        let threadID = try XCTUnwrap(
            created["activeThreadId"] as? String)
        XCTAssertEqual(created["title"] as? String, "Headless Architect")
        XCTAssertEqual(created["role"] as? String, "planning lead")
        XCTAssertEqual(created["provider"] as? String, "amp")
        XCTAssertEqual(created["model"] as? String, "smart")
        XCTAssertEqual(created["headless"] as? Bool, true)

        let listed = try request(["v": 1, "op": "list"])
        XCTAssertEqual(
            (listed["chats"] as? [[String: Any]])?.first?["chatId"]
                as? String,
            chatID)

        let reset = try request([
            "v": 1,
            "op": "new_thread",
            "chatId": chatID,
        ])
        XCTAssertEqual(
            reset["activeThreadId"] as? String,
            threadID,
            "A blank Chat reuses its empty thread.")
        _ = try request([
            "v": 1,
            "op": "select_thread",
            "chatId": chatID,
            "threadId": threadID,
        ])
        let renamed = try request([
            "v": 1,
            "op": "rename",
            "chatId": chatID,
            "name": "Headless Lead",
        ])
        XCTAssertEqual(renamed["title"] as? String, "Headless Lead")

        let panesText = try XCTUnwrap(AppSocketClient.request(
            "list", socketPath: fixture.socketPath))
        let panes = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(panesText.utf8))
                as? [[String: Any]])
        XCTAssertEqual(panes.first?["kind"] as? String, "chat")
        XCTAssertEqual(panes.first?["id"] as? String, chatID)
        XCTAssertEqual(panes.first?["title"] as? String, "Headless Lead")
        XCTAssertEqual(
            AppSocketClient.request(
                "focus \(chatID)",
                socketPath: fixture.socketPath),
            "ok")
        XCTAssertEqual(paneID, "headless-chat/\(chatID)")
        let splitText = try XCTUnwrap(AppSocketClient.request(
            "split \(chatID) right",
            socketPath: fixture.socketPath))
        let terminalID = try XCTUnwrap(Int(splitText))
        XCTAssertGreaterThan(terminalID, 0)

        let closed = try request([
            "v": 1,
            "op": "close",
            "chatId": chatID,
        ])
        XCTAssertEqual(closed["open"] as? Bool, false)

        let disposable = try request([
            "v": 1,
            "op": "create",
            "name": "Disposable Reviewer",
            "role": "reviewer",
            "provider": "amp",
            "model": "smart",
            "workspace": fixture.support.path,
        ])
        let disposableID = try XCTUnwrap(
            disposable["chatId"] as? String)
        XCTAssertEqual(
            AppSocketClient.request(
                "close \(disposableID)",
                socketPath: fixture.socketPath),
            "ok")

        let remainingText = try XCTUnwrap(AppSocketClient.request(
            "list", socketPath: fixture.socketPath))
        let remaining = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(remainingText.utf8))
                as? [[String: Any]])
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?["id"] as? Int, terminalID)
        XCTAssertNil(remaining.first?["kind"])
    }

    func testApprovedHeadlessProposalCreatesRealConnectedAgentRoom()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let executable = fixture.support.appendingPathComponent(
            "fake-amp")
        try """
        #!/bin/sh
        prompt="$5"
        case "$prompt" in
          *'Your participant name: "Headless Architect"'*)
            output='\(fixture.support.path)/architect-prompt.txt'
            result='ARCHITECT_CONTEXT_MISSING'
            if printf '%s' "$prompt" | grep -Fq 'Connection status: CONNECTED; this is not a solo Chat.' \
              && printf '%s' "$prompt" | grep -Fq 'Channel: "Headless Delivery Room"' \
              && printf '%s' "$prompt" | grep -Fq '"Headless Reviewer" [chat]' \
              && printf '%s' "$prompt" | grep -Fq 'scope "Sources/**" -> "Headless Architect"' \
              && printf '%s' "$prompt" | grep -Fq 'scope "Tests/**" -> "Headless Reviewer"' \
              && printf '%s' "$prompt" | grep -Fq 'plan [in_progress] "Headless Reviewer: integration reviewer" -> "Headless Reviewer"'
            then
              result='ARCHITECT_CHANNEL_READY'
            fi
            ;;
          *'Your participant name: "Headless Reviewer"'*)
            output='\(fixture.support.path)/reviewer-prompt.txt'
            result='REVIEWER_CONTEXT_MISSING'
            if printf '%s' "$prompt" | grep -Fq 'Connection status: CONNECTED; this is not a solo Chat.' \
              && printf '%s' "$prompt" | grep -Fq 'Channel: "Headless Delivery Room"' \
              && printf '%s' "$prompt" | grep -Fq '"Headless Architect" [chat]' \
              && printf '%s' "$prompt" | grep -Fq 'scope "Sources/**" -> "Headless Architect"' \
              && printf '%s' "$prompt" | grep -Fq 'scope "Tests/**" -> "Headless Reviewer"' \
              && printf '%s' "$prompt" | grep -Fq 'plan [in_progress] "Headless Architect: delivery owner" -> "Headless Architect"'
            then
              result='REVIEWER_CHANNEL_READY'
            fi
            ;;
          *)
            output='\(fixture.support.path)/unknown-prompt.txt'
            result='UNKNOWN_PARTICIPANT_CONTEXT'
            ;;
        esac
        printf '%s' "$prompt" > "$output"
        printf '{"type":"result","result":"%s"}\n' "$result"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
        let previousAmp = getenv("INFINITTY_AMP_EXECUTABLE")
            .map { String(cString: $0) }
        setenv("INFINITTY_AMP_EXECUTABLE", executable.path, 1)
        defer {
            if let previousAmp {
                setenv(
                    "INFINITTY_AMP_EXECUTABLE",
                    previousAmp,
                    1)
            } else {
                unsetenv("INFINITTY_AMP_EXECUTABLE")
            }
        }
        // The scoped-approval path requires the bundled infinitty-mcp helper,
        // which resolves against Bundle.main and is therefore unavailable under
        // `swift test`. Bypass approvals here; the approval routing itself is
        // covered by ProviderDiscoveryTests/ProviderPermissionPolicyTests.
        let previousYolo = getenv("INFINITTY_AI_YOLO")
            .map { String(cString: $0) }
        setenv("INFINITTY_AI_YOLO", "1", 1)
        defer {
            if let previousYolo {
                setenv("INFINITTY_AI_YOLO", previousYolo, 1)
            } else {
                unsetenv("INFINITTY_AI_YOLO")
            }
        }

        let host = try HeadlessAppHost(
            instanceID: "headless-room",
            socketPath: fixture.socketPath,
            applicationSupportDirectory: fixture.support,
            publishesCurrentLink: false)
        try host.start(launchInitialTerminal: false)
        defer { host.stop() }
        let coordinator = CollaborationCoordinatorClient(
            applicationSupportDirectory: fixture.support)
        let proposalSpec = CollaborationRoomProposalSpec(
            id: "proposal-headless-room",
            channelID: "channel-headless-room",
            roomName: "Headless Delivery Room",
            objective: "Return a real provider result.",
            workspaceRoot: fixture.support.path,
            agents: [
                CollaborationAgentSpec(
                    id: "agent-headless-architect",
                    displayName: "Headless Architect",
                    role: "delivery owner",
                    runtime: .local,
                    provider: "amp",
                    modelID: "smart",
                    responsibilityScopes: ["Sources/**"],
                    capabilities: ["workspace.write"]),
                CollaborationAgentSpec(
                    id: "agent-headless-reviewer",
                    displayName: "Headless Reviewer",
                    role: "integration reviewer",
                    runtime: .local,
                    provider: "amp",
                    modelID: "smart",
                    responsibilityScopes: ["Tests/**"],
                    capabilities: ["workspace.read", "review"]),
            ],
            workspaceStrategy: .sharedCheckout,
            presentation: .headless,
            targetInstanceID: "headless-room",
            requestedCapabilities: ["workspace.write"],
            expiresAt: Date().addingTimeInterval(300))
        let prepare = CollaborationControlRequest(
            op: .prepareProposal,
            actor: CollaborationActor(
                id: "agent:requester",
                kind: .agent,
                displayName: "Requesting agent"),
            idempotencyKey: "prepare-headless-room",
            proposal: proposalSpec)
        let prepared = try XCTUnwrap(coordinator.execute(
            try XCTUnwrap(CollaborationControlCodec.encode(prepare)))
            .snapshot?.proposals.first)
        let approve = CollaborationControlRequest(
            op: .approveProposal,
            actor: CollaborationActor(
                id: "human:test",
                kind: .human,
                displayName: "Test human"),
            idempotencyKey: "approve-headless-room",
            proposalID: proposalSpec.id,
            proposalDigest: prepared.digest)
        XCTAssertNotNil(coordinator.executeHumanDecision(
            try XCTUnwrap(CollaborationControlCodec.encode(approve)))
            .snapshot)

        var finalSnapshot: CollaborationSnapshot?
        var chatStates: [[String: Any]] = []
        for _ in 0..<120 {
            finalSnapshot = coordinator.snapshot()
            if finalSnapshot?.proposals.first(where: {
                $0.spec.id == proposalSpec.id
            })?.state == .running,
               let encoded = BrowserControlCodec.encode([
                   "v": 1,
                   "op": "list",
               ]),
               let response = AppSocketClient.request(
                   "chat \(encoded)",
                   socketPath: fixture.socketPath),
               let envelope = try? JSONSerialization.jsonObject(
                   with: Data(response.utf8)) as? [String: Any],
               let result = envelope["result"] as? [String: Any]
            {
                chatStates = result["chats"] as? [[String: Any]]
                    ?? []
                let results = Set(chatStates.flatMap { chat -> [String] in
                    let threads = chat["threads"] as? [[String: Any]]
                    let messages = threads?.first?["messages"]
                        as? [[String: Any]]
                    return messages?.compactMap {
                        $0["text"] as? String
                    } ?? []
                })
                if results.contains(where: {
                    $0.contains("ARCHITECT_CHANNEL_READY")
                }), results.contains(where: {
                    $0.contains("REVIEWER_CHANNEL_READY")
                }) {
                    break
                }
            }
            usleep(50_000)
        }

        XCTAssertEqual(
            finalSnapshot?.proposals.first(where: {
                $0.spec.id == proposalSpec.id
            })?.state,
            .running)
        let channel = try XCTUnwrap(
            finalSnapshot?.channels.first(where: {
                $0.id == proposalSpec.channelID
            }))
        XCTAssertEqual(
            channel.participants.map(\.displayName),
            ["Headless Architect", "Headless Reviewer"])
        XCTAssertEqual(
            channel.participants.map(\.role),
            ["delivery owner", "integration reviewer"])
        XCTAssertEqual(
            channel.responsibilities.map(\.scope),
            ["Sources/**", "Tests/**"])
        XCTAssertEqual(
            channel.plan.map(\.ownerID),
            ["agent-headless-architect", "agent-headless-reviewer"])
        XCTAssertEqual(chatStates.count, 2)
        let statesByParticipant: [String: [String: Any]] = Dictionary(
            uniqueKeysWithValues: chatStates.compactMap {
                state -> (String, [String: Any])? in
                guard let participantID =
                        state["participantId"] as? String
                else { return nil }
                return (participantID, state)
            })
        let architect = try XCTUnwrap(
            statesByParticipant["agent-headless-architect"])
        let reviewer = try XCTUnwrap(
            statesByParticipant["agent-headless-reviewer"])
        for state in [architect, reviewer] {
            XCTAssertEqual(
                state["channelId"] as? String,
                proposalSpec.channelID)
            XCTAssertEqual(state["provider"] as? String, "amp")
            XCTAssertEqual(state["model"] as? String, "smart")
        }
        XCTAssertEqual(
            architect["title"] as? String,
            "Headless Architect")
        XCTAssertEqual(
            reviewer["title"] as? String,
            "Headless Reviewer")
        func transcript(_ state: [String: Any]) -> [String] {
            let threads = state["threads"] as? [[String: Any]]
            let messages = threads?.first?["messages"]
                as? [[String: Any]]
            return messages?.compactMap {
                $0["text"] as? String
            } ?? []
        }
        XCTAssertTrue(transcript(architect).contains(where: {
            $0.contains("ARCHITECT_CHANNEL_READY")
        }))
        XCTAssertTrue(transcript(reviewer).contains(where: {
            $0.contains("REVIEWER_CHANNEL_READY")
        }))
        let architectPrompt = try String(
            contentsOf: fixture.support.appendingPathComponent(
                "architect-prompt.txt"),
            encoding: .utf8)
        let reviewerPrompt = try String(
            contentsOf: fixture.support.appendingPathComponent(
                "reviewer-prompt.txt"),
            encoding: .utf8)
        XCTAssertTrue(architectPrompt.contains(
            "Your participant name: \"Headless Architect\""))
        XCTAssertTrue(architectPrompt.contains(
            "\"Headless Reviewer\" [chat]"))
        XCTAssertTrue(reviewerPrompt.contains(
            "Your participant name: \"Headless Reviewer\""))
        XCTAssertTrue(reviewerPrompt.contains(
            "\"Headless Architect\" [chat]"))
    }

    func testHeadlessRoomRecoversProvisioningAndRunningStatesAfterRestart()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let executable = fixture.support.appendingPathComponent(
            "fake-amp-recovery")
        try """
        #!/bin/sh
        printf '%s\n' '{"type":"result","result":"AMP_RECOVERY_READY"}'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
        let previousAmp = getenv("INFINITTY_AMP_EXECUTABLE")
            .map { String(cString: $0) }
        setenv("INFINITTY_AMP_EXECUTABLE", executable.path, 1)
        defer {
            if let previousAmp {
                setenv("INFINITTY_AMP_EXECUTABLE", previousAmp, 1)
            } else {
                unsetenv("INFINITTY_AMP_EXECUTABLE")
            }
        }

        let coordinator = CollaborationCoordinatorClient(
            applicationSupportDirectory: fixture.support)
        let spec = CollaborationRoomProposalSpec(
            id: "proposal-headless-recovery",
            channelID: "channel-headless-recovery",
            roomName: "Recovery Room",
            objective: "Recover the real agent runtime.",
            workspaceRoot: fixture.support.path,
            agents: [
                CollaborationAgentSpec(
                    id: "agent-recovery",
                    displayName: "Recovery Agent",
                    role: "recovery owner",
                    runtime: .local,
                    provider: "amp",
                    modelID: "smart",
                    responsibilityScopes: ["Sources/**"],
                    capabilities: ["workspace.write"]),
            ],
            workspaceStrategy: .sharedCheckout,
            presentation: .headless,
            targetInstanceID: "headless-recovery",
            requestedCapabilities: ["workspace.write"],
            expiresAt: Date().addingTimeInterval(300))
        let prepare = CollaborationControlRequest(
            op: .prepareProposal,
            actor: CollaborationActor(
                id: "agent:requester",
                kind: .agent,
                displayName: "Requesting agent"),
            idempotencyKey: "prepare-headless-recovery",
            proposal: spec)
        let prepared = try XCTUnwrap(coordinator.execute(
            try XCTUnwrap(CollaborationControlCodec.encode(prepare)))
            .snapshot?.proposals.first)
        let approve = CollaborationControlRequest(
            op: .approveProposal,
            actor: CollaborationActor(
                id: "human:test",
                kind: .human,
                displayName: "Test human"),
            idempotencyKey: "approve-headless-recovery",
            proposalID: spec.id,
            proposalDigest: prepared.digest)
        XCTAssertNotNil(coordinator.executeHumanDecision(
            try XCTUnwrap(CollaborationControlCodec.encode(approve)))
            .snapshot)
        let startProvisioning = CollaborationControlRequest(
            op: .startProvisioning,
            actor: CollaborationActor(
                id: "system:orchestrator:headless-recovery",
                kind: .system,
                displayName: "Recovery orchestrator"),
            idempotencyKey: "start-headless-recovery",
            proposalID: spec.id,
            proposalDigest: prepared.digest)
        XCTAssertEqual(
            coordinator.execute(try XCTUnwrap(
                CollaborationControlCodec.encode(startProvisioning)))
                .snapshot?.proposals.first?.state,
            .provisioning)

        func chatState() -> [String: Any]? {
            guard let encoded = BrowserControlCodec.encode([
                "v": 1,
                "op": "list",
            ]),
                  let response = AppSocketClient.request(
                    "chat \(encoded)",
                    socketPath: fixture.socketPath),
                  let envelope = try? JSONSerialization.jsonObject(
                    with: Data(response.utf8)) as? [String: Any],
                  let result = envelope["result"] as? [String: Any]
            else { return nil }
            return (result["chats"] as? [[String: Any]])?.first
        }

        var first: HeadlessAppHost? = try HeadlessAppHost(
            instanceID: "headless-recovery",
            socketPath: fixture.socketPath,
            applicationSupportDirectory: fixture.support,
            publishesCurrentLink: false)
        try first?.start(launchInitialTerminal: false)
        var firstChat: [String: Any]?
        for _ in 0..<120 {
            firstChat = chatState()
            let messages =
                (firstChat?["threads"] as? [[String: Any]])?
                .first?["messages"] as? [[String: Any]]
            if coordinator.snapshot()?.proposals.first?.state == .running,
               messages?.contains(where: {
                   ($0["text"] as? String)?
                    .contains("AMP_RECOVERY_READY") == true
               }) == true
            {
                break
            }
            usleep(50_000)
        }
        XCTAssertEqual(
            coordinator.snapshot()?.proposals.first?.state,
            .running)
        let stableChatID = try XCTUnwrap(firstChat?["chatId"] as? String)
        first?.stop()
        first = nil

        let second = try HeadlessAppHost(
            instanceID: "headless-recovery",
            socketPath: fixture.socketPath,
            applicationSupportDirectory: fixture.support,
            publishesCurrentLink: false)
        try second.start(launchInitialTerminal: false)
        defer { second.stop() }
        var recoveredChat: [String: Any]?
        for _ in 0..<120 {
            recoveredChat = chatState()
            let messages =
                (recoveredChat?["threads"] as? [[String: Any]])?
                .first?["messages"] as? [[String: Any]]
            if recoveredChat?["channelId"] as? String == spec.channelID,
               messages?.contains(where: {
                ($0["text"] as? String)?
                    .contains("AMP_RECOVERY_READY") == true
            }) == true {
                break
            }
            usleep(50_000)
        }
        XCTAssertEqual(
            recoveredChat?["chatId"] as? String,
            stableChatID)
        XCTAssertEqual(
            recoveredChat?["channelId"] as? String,
            spec.channelID)
        XCTAssertEqual(
            coordinator.snapshot()?.proposals.first?.state,
            .running)
    }

    func testHeadlessHostCreatesPTYTerminalAndExposesChannelTransport() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let host = try HeadlessAppHost(
            instanceID: "headless-terminal",
            socketPath: fixture.socketPath,
            applicationSupportDirectory: fixture.support,
            publishesCurrentLink: false)
        try host.start(
            initialWorkingDirectory: fixture.support.path,
            launchInitialTerminal: true)
        defer { host.stop() }

        let listText = try XCTUnwrap(
            AppSocketClient.request("list", socketPath: fixture.socketPath))
        let panes = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(listText.utf8))
                as? [[String: Any]])
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes[0]["headless"] as? Bool, true)
        XCTAssertEqual(panes[0]["focused"] as? Bool, true)
        let paneSocket = try XCTUnwrap(panes[0]["socket"] as? String)
        XCTAssertEqual(
            AppSocketClient.request("ping", socketPath: paneSocket),
            "pong")

        let runText = try XCTUnwrap(AppSocketClient.request(
            "run 1 echo HEADLESS_PTY_OK",
            socketPath: fixture.socketPath,
            timeoutSeconds: 10))
        let run = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(runText.utf8))
                as? [String: Any])
        XCTAssertEqual(run["exitCode"] as? Int, 0)
        XCTAssertEqual(run["output"] as? String, "HEADLESS_PTY_OK")

        let actor = CollaborationActor(
            id: "human:test",
            kind: .human,
            displayName: "Test")
        let request = CollaborationControlRequest(
            op: .create,
            actor: actor,
            idempotencyKey: "create-headless-channel",
            channelID: "headless-channel",
            name: "Headless Channel")
        let encoded = try XCTUnwrap(CollaborationControlCodec.encode(request))
        let responseText = try XCTUnwrap(AppSocketClient.request(
            "channel \(encoded)",
            socketPath: fixture.socketPath))
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(responseText.utf8))
                as? [String: Any])
        XCTAssertEqual(response["ok"] as? Bool, true)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let channels = try XCTUnwrap(result["channels"] as? [[String: Any]])
        XCTAssertEqual(channels.first?["id"] as? String, "headless-channel")

        let openRequest = try XCTUnwrap(BrowserControlCodec.encode([
            "v": 1,
            "op": "open",
            "channelId": "headless-channel",
        ]))
        let openText = try XCTUnwrap(AppSocketClient.request(
            "channel-panel \(openRequest)",
            socketPath: fixture.socketPath))
        let openEnvelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(openText.utf8))
                as? [String: Any])
        XCTAssertEqual(openEnvelope["ok"] as? Bool, false)
        let openError = try XCTUnwrap(openEnvelope["error"] as? [String: Any])
        XCTAssertEqual(openError["code"] as? String, "channel_panel_removed")

        let snapshotRequest = try XCTUnwrap(BrowserControlCodec.encode([
            "v": 1,
            "op": "snapshot",
            "channelId": "headless-channel",
        ]))
        let snapshotText = try XCTUnwrap(AppSocketClient.request(
            "channel-panel \(snapshotRequest)",
            socketPath: fixture.socketPath))
        let snapshotEnvelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(snapshotText.utf8))
                as? [String: Any])
        XCTAssertEqual(snapshotEnvelope["ok"] as? Bool, true)
        let room = try XCTUnwrap(snapshotEnvelope["result"] as? [String: Any])
        XCTAssertEqual(room["title"] as? String, "Headless Channel")
        XCTAssertEqual(room["open"] as? Bool, false)

        let postRequest = try XCTUnwrap(BrowserControlCodec.encode([
            "v": 1,
            "op": "post_message",
            "channelId": "headless-channel",
            "text": "Room data remains mutable",
        ]))
        let postText = try XCTUnwrap(AppSocketClient.request(
            "channel-panel \(postRequest)",
            socketPath: fixture.socketPath))
        let postEnvelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(postText.utf8))
                as? [String: Any])
        XCTAssertEqual(postEnvelope["ok"] as? Bool, true)
        let postedRoom = try XCTUnwrap(postEnvelope["result"] as? [String: Any])
        let roomMessages = try XCTUnwrap(
            postedRoom["roomMessages"] as? [[String: Any]])
        XCTAssertEqual(roomMessages.last?["text"] as? String,
                       "Room data remains mutable")
        XCTAssertEqual(postedRoom["open"] as? Bool, false)

        let listAfterRoomRequest = try XCTUnwrap(
            AppSocketClient.request("list", socketPath: fixture.socketPath))
        let panesAfterRoomRequest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(listAfterRoomRequest.utf8))
                as? [[String: Any]])
        XCTAssertEqual(panesAfterRoomRequest.count, 1)
        XCTAssertEqual(panesAfterRoomRequest.first?["id"] as? Int, 1)
        XCTAssertFalse(panesAfterRoomRequest.contains {
            $0["kind"] as? String == "channel"
        })
    }

    func testTerminalAgentsRegisterAndShareDynamicChannelContext() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let host = try HeadlessAppHost(
            instanceID: "terminal-agents",
            socketPath: fixture.socketPath,
            applicationSupportDirectory: fixture.support,
            publishesCurrentLink: false)
        try host.start(
            initialWorkingDirectory: fixture.support.path,
            launchInitialTerminal: true)
        defer { host.stop() }

        XCTAssertEqual(
            AppSocketClient.request(
                "new-tab \(fixture.support.path)",
                socketPath: fixture.socketPath),
            "2")

        func panes() throws -> [[String: Any]] {
            let text = try XCTUnwrap(AppSocketClient.request(
                "list", socketPath: fixture.socketPath))
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [[String: Any]])
        }

        func paneRequest(
            _ command: String,
            socket: String
        ) throws -> [String: Any] {
            let text = try XCTUnwrap(AppSocketClient.request(
                command, socketPath: socket))
            let envelope = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any],
                "response=\(text)")
            XCTAssertEqual(envelope["ok"] as? Bool, true, "response=\(text)")
            return try XCTUnwrap(envelope["result"] as? [String: Any])
        }

        func encoded(_ payload: [String: Any]) throws -> String {
            try XCTUnwrap(BrowserControlCodec.encode(payload))
        }

        let initial = try panes()
        let adaSocket = try XCTUnwrap(initial[0]["socket"] as? String)
        let turingSocket = try XCTUnwrap(initial[1]["socket"] as? String)

        let beforeRegistration = try paneRequest(
            "channel-context", socket: adaSocket)
        XCTAssertEqual(beforeRegistration["connected"] as? Bool, false)
        XCTAssertEqual(beforeRegistration["registered"] as? Bool, false)
        XCTAssertEqual(
            (beforeRegistration["endpoint"] as? [String: Any])?["id"]
                as? String,
            "terminal-agents/terminal:1")

        let adaRegister = try encoded([
            "v": 1,
            "displayName": "Ada",
            "role": "implementation lead",
            "provider": "claude",
            "modelID": "provider-owned-model",
            "sessionID": "claude-session-1",
            "capabilities": ["code", "review"],
        ])
        let turingRegister = try encoded([
            "v": 1,
            "displayName": "Turing",
            "role": "test lead",
            "provider": "amp",
            "sessionID": "amp-session-1",
            "capabilities": ["test"],
        ])
        let adaDisconnected = try paneRequest(
            "channel-register \(adaRegister)", socket: adaSocket)
        let turingDisconnected = try paneRequest(
            "channel-register \(turingRegister)", socket: turingSocket)
        XCTAssertEqual(adaDisconnected["registered"] as? Bool, true)
        XCTAssertEqual(adaDisconnected["connected"] as? Bool, false)
        XCTAssertEqual(turingDisconnected["registered"] as? Bool, true)

        let registeredPanes = try panes()
        XCTAssertEqual(registeredPanes.map { $0["title"] as? String }, ["Ada", "Turing"])
        let adaEndpoint = try XCTUnwrap(
            registeredPanes[0]["channelEndpoint"] as? [String: Any])
        let turingEndpoint = try XCTUnwrap(
            registeredPanes[1]["channelEndpoint"] as? [String: Any])
        let adaParticipantID = try XCTUnwrap(
            adaEndpoint["participantID"] as? String)
        let turingParticipantID = try XCTUnwrap(
            turingEndpoint["participantID"] as? String)
        XCTAssertNotEqual(adaParticipantID, turingParticipantID)

        let actor = CollaborationActor(
            id: "human:test",
            kind: .human,
            displayName: "Test")
        let link = CollaborationControlRequest(
            op: .link,
            actor: actor,
            idempotencyKey: "terminal-agent-link",
            source: CollaborationEndpoint(
                id: "terminal-agents/terminal:1",
                kind: .terminal,
                label: "Ada",
                participantID: adaParticipantID,
                instanceID: "terminal-agents"),
            target: CollaborationEndpoint(
                id: "terminal-agents/terminal:2",
                kind: .terminal,
                label: "Turing",
                participantID: turingParticipantID,
                instanceID: "terminal-agents"))
        let linkEncoded = try XCTUnwrap(CollaborationControlCodec.encode(link))
        let linkedText = try XCTUnwrap(AppSocketClient.request(
            "channel \(linkEncoded)", socketPath: fixture.socketPath))
        XCTAssertTrue(linkedText.contains("\"ok\":true"), linkedText)

        let adaContext = try paneRequest("channel-context", socket: adaSocket)
        XCTAssertEqual(adaContext["connected"] as? Bool, true)
        XCTAssertEqual(
            (adaContext["channel"] as? [String: Any])?["name"] as? String,
            "Channel 1")
        XCTAssertEqual(
            (adaContext["self"] as? [String: Any])?["displayName"] as? String,
            "Ada")
        XCTAssertEqual(
            ((adaContext["peers"] as? [[String: Any]])?.first)?["displayName"]
                as? String,
            "Turing")
        XCTAssertTrue(
            (adaContext["modelContext"] as? String)?
                .contains("Connection status: CONNECTED") == true)

        let post = try encoded([
            "v": 1,
            "text": "Implementation is ready for verification.",
            "authorID": "human:forged",
            "channelID": "forged-channel",
        ])
        let posted = try paneRequest(
            "channel-post \(post)", socket: adaSocket)
        XCTAssertEqual(posted["posted"] as? Bool, true)

        let turingContext = try paneRequest(
            "channel-context", socket: turingSocket)
        let messages = try XCTUnwrap(
            turingContext["recentMessages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["authorID"] as? String, adaParticipantID)
        XCTAssertEqual(messages.last?["authorName"] as? String, "Ada")
        XCTAssertEqual(
            messages.last?["text"] as? String,
            "Implementation is ready for verification.")

        let beforeUnregisterRevision = try XCTUnwrap(
            (turingContext["channel"] as? [String: Any])?["revision"] as? Int)
        let unregistered = try paneRequest(
            "channel-unregister", socket: adaSocket)
        XCTAssertEqual(unregistered["registered"] as? Bool, false)
        let afterUnregister = try paneRequest(
            "channel-context", socket: turingSocket)
        let afterUnregisterRevision = try XCTUnwrap(
            (afterUnregister["channel"] as? [String: Any])?["revision"] as? Int)
        XCTAssertEqual(afterUnregisterRevision, beforeUnregisterRevision + 1)

        _ = try paneRequest("channel-unregister", socket: adaSocket)
        let afterRepeatedUnregister = try paneRequest(
            "channel-context", socket: turingSocket)
        XCTAssertEqual(
            (afterRepeatedUnregister["channel"] as? [String: Any])?["revision"]
                as? Int,
            afterUnregisterRevision)
    }

    func testHeadlessChannelJournalReplaysAfterHostRestart() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let actor = CollaborationActor(
            id: "human:test",
            kind: .human,
            displayName: "Test")
        let create = CollaborationControlRequest(
            op: .create,
            actor: actor,
            idempotencyKey: "create-replay-channel",
            channelID: "replay-channel",
            name: "Replay Channel")
        let createEncoded = try XCTUnwrap(
            CollaborationControlCodec.encode(create))

        var first: HeadlessAppHost? = try HeadlessAppHost(
            instanceID: "headless-replay",
            socketPath: fixture.socketPath,
            applicationSupportDirectory: fixture.support,
            publishesCurrentLink: false)
        try first?.start(launchInitialTerminal: false)
        let createResponse = try XCTUnwrap(AppSocketClient.request(
            "channel \(createEncoded)",
            socketPath: fixture.socketPath))
        XCTAssertTrue(createResponse.contains("\"ok\":true"))
        first?.stop()
        first = nil

        let secondSocket = fixture.socketPath.replacingOccurrences(
            of: ".sock",
            with: "-second.sock")
        let second = try HeadlessAppHost(
            instanceID: "headless-replay",
            socketPath: secondSocket,
            applicationSupportDirectory: fixture.support,
            publishesCurrentLink: false)
        try second.start(launchInitialTerminal: false)
        defer {
            second.stop()
            unlink(secondSocket)
        }

        let snapshot = CollaborationControlRequest(op: .snapshot)
        let snapshotEncoded = try XCTUnwrap(
            CollaborationControlCodec.encode(snapshot))
        let snapshotResponse = try XCTUnwrap(AppSocketClient.request(
            "channel \(snapshotEncoded)",
            socketPath: secondSocket))
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(snapshotResponse.utf8))
                as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        let channels = try XCTUnwrap(result["channels"] as? [[String: Any]])
        XCTAssertEqual(channels.first?["id"] as? String, "replay-channel")
        XCTAssertEqual(result["revision"] as? Int, 1)
    }

    func testTwoHeadlessHostsAreDirectlyAddressable() throws {
        let firstFixture = try makeFixture()
        let secondFixture = try makeFixture()
        defer {
            firstFixture.cleanup()
            secondFixture.cleanup()
        }
        let first = try HeadlessAppHost(
            instanceID: "headless-a",
            socketPath: firstFixture.socketPath,
            applicationSupportDirectory: firstFixture.support,
            publishesCurrentLink: false)
        let second = try HeadlessAppHost(
            instanceID: "headless-b",
            socketPath: secondFixture.socketPath,
            applicationSupportDirectory: firstFixture.support,
            publishesCurrentLink: false)
        try first.start(launchInitialTerminal: false)
        try second.start(launchInitialTerminal: false)
        defer {
            first.stop()
            second.stop()
        }

        XCTAssertTrue(
            AppSocketClient.request(
                "instance",
                socketPath: firstFixture.socketPath)?
                .contains("\"id\":\"headless-a\"") == true)
        XCTAssertTrue(
            AppSocketClient.request(
                "instance",
                socketPath: secondFixture.socketPath)?
                .contains("\"id\":\"headless-b\"") == true)
        XCTAssertEqual(
            AppInstanceRegistry.list(baseDirectory: firstFixture.support)
                .map(\.id),
            ["headless-a", "headless-b"])

        first.stop()
        XCTAssertEqual(
            AppSocketClient.request(
                "ping",
                socketPath: secondFixture.socketPath),
            "pong")
    }

    func testApprovedHeadlessCloudRoomPersistsSessionBeforeRunning()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let factory = HeadlessCloudRuntimeFactory()
        let host = try HeadlessAppHost(
            instanceID: "headless-cloud-room",
            socketPath: fixture.socketPath,
            applicationSupportDirectory: fixture.support,
            publishesCurrentLink: false)
        host.cloudRuntimeFactory = factory
        try host.start(launchInitialTerminal: false)
        defer { host.stop() }

        let coordinator = CollaborationCoordinatorClient(
            applicationSupportDirectory: fixture.support)
        let spec = CollaborationRoomProposalSpec(
            id: "proposal-headless-cloud",
            channelID: "channel-headless-cloud",
            roomName: "Remote Delivery Room",
            objective:
                "Run the approved remote agent in the shared Channel.",
            workspaceRoot: fixture.support.path,
            agents: [
                CollaborationAgentSpec(
                    id: "agent-headless-cloud",
                    displayName: "Remote Architect",
                    role: "remote delivery owner",
                    runtime: .cloud,
                    provider: "codex",
                    modelID: "opaque-cloud-model",
                    responsibilityScopes: ["Sources/**"],
                    capabilities: ["workspace.write"],
                    cloudConnection:
                        CollaborationCloudConnection(
                            endpointURL:
                                "wss://codex.example.test/app-server",
                            credentialEnvironmentVariable:
                                "CODEX_CHANNEL_TOKEN",
                            remoteWorkspace:
                                "/srv/headless-cloud")),
            ],
            workspaceStrategy: .sharedCheckout,
            presentation: .headless,
            targetInstanceID: "headless-cloud-room",
            requestedCapabilities: ["workspace.write"],
            expiresAt: Date().addingTimeInterval(300))
        let prepare = CollaborationControlRequest(
            op: .prepareProposal,
            actor: CollaborationActor(
                id: "agent:requester",
                kind: .agent,
                displayName: "Requesting agent"),
            idempotencyKey: "prepare-headless-cloud",
            proposal: spec)
        let prepared = try XCTUnwrap(coordinator.execute(
            try XCTUnwrap(
                CollaborationControlCodec.encode(prepare)))
            .snapshot?.proposals.first)
        let approve = CollaborationControlRequest(
            op: .approveProposal,
            actor: CollaborationActor(
                id: "human:test",
                kind: .human,
                displayName: "Test human"),
            idempotencyKey: "approve-headless-cloud",
            proposalID: spec.id,
            proposalDigest: prepared.digest)
        XCTAssertNotNil(coordinator.executeHumanDecision(
            try XCTUnwrap(
                CollaborationControlCodec.encode(approve)))
            .snapshot)

        var finalProposal: CollaborationRoomProposal?
        var chatMessages: [[String: Any]] = []
        for _ in 0..<120 {
            finalProposal = coordinator.snapshot()?
                .proposals.first {
                    $0.spec.id == spec.id
                }
            if finalProposal?.state == .running,
               let encoded = BrowserControlCodec.encode([
                   "v": 1,
                   "op": "list",
               ]),
               let response = AppSocketClient.request(
                   "chat \(encoded)",
                   socketPath: fixture.socketPath),
               let envelope =
                    try? JSONSerialization.jsonObject(
                        with: Data(response.utf8))
                        as? [String: Any],
               let result = envelope["result"]
                    as? [String: Any],
               let chat = (result["chats"]
                    as? [[String: Any]])?.first
            {
                chatMessages =
                    ((chat["threads"] as? [[String: Any]])?
                        .first?["messages"]
                        as? [[String: Any]]) ?? []
                if chatMessages.contains(where: {
                    ($0["text"] as? String)?
                        .contains("CLOUD_CHANNEL_READY")
                        == true
                }) {
                    break
                }
            }
            usleep(50_000)
        }

        XCTAssertEqual(finalProposal?.state, .running)
        let receipt = try XCTUnwrap(
            finalProposal?.runtimeReceipts.first)
        XCTAssertEqual(receipt.agentID, "agent-headless-cloud")
        XCTAssertEqual(receipt.adapterKind, "codex_app_server")
        XCTAssertEqual(receipt.remoteSessionID, "remote-session-1")
        XCTAssertEqual(factory.contexts.count, 1)
        XCTAssertEqual(
            factory.contexts.first?.previousReceipt,
            nil)
        XCTAssertTrue(chatMessages.contains(where: {
            ($0["text"] as? String)?
                .contains("CLOUD_CHANNEL_READY") == true
        }))
        let prompt = try XCTUnwrap(
            factory.adapters.first?.users.first)
        XCTAssertTrue(
            prompt.contains("ACTIVE INFINITTY CHANNEL"))
        XCTAssertTrue(
            prompt.contains(
                "Your participant name: \"Remote Architect\""))
        XCTAssertFalse(
            prompt.contains("chat-only session (no active terminal)"),
            "cloud adapters receive their approved remote workspace context")

        host.stop()
        let recoveryFactory = HeadlessCloudRuntimeFactory()
        let recoveredHost = try HeadlessAppHost(
            instanceID: "headless-cloud-room",
            socketPath: fixture.socketPath,
            applicationSupportDirectory: fixture.support,
            publishesCurrentLink: false)
        recoveredHost.cloudRuntimeFactory = recoveryFactory
        try recoveredHost.start(launchInitialTerminal: false)
        defer { recoveredHost.stop() }
        var recoveredMessages: [[String: Any]] = []
        for _ in 0..<120 {
            if let encoded = BrowserControlCodec.encode([
                "v": 1,
                "op": "list",
            ]),
               let response = AppSocketClient.request(
                   "chat \(encoded)",
                   socketPath: fixture.socketPath),
               let envelope =
                    try? JSONSerialization.jsonObject(
                        with: Data(response.utf8))
                        as? [String: Any],
               let result = envelope["result"]
                    as? [String: Any],
               let chat = (result["chats"]
                    as? [[String: Any]])?.first
            {
                recoveredMessages =
                    ((chat["threads"] as? [[String: Any]])?
                        .first?["messages"]
                        as? [[String: Any]]) ?? []
                if recoveredMessages.contains(where: {
                    ($0["text"] as? String)?
                        .contains("CLOUD_CHANNEL_READY")
                        == true
                }) {
                    break
                }
            }
            usleep(50_000)
        }
        let recoveredContext = try XCTUnwrap(
            recoveryFactory.contexts.first)
        XCTAssertEqual(
            recoveredContext.previousReceipt?.remoteSessionID,
            "remote-session-1")
        XCTAssertTrue(recoveredMessages.contains(where: {
            ($0["text"] as? String)?
                .contains("CLOUD_CHANNEL_READY") == true
        }))
        XCTAssertTrue(
            recoveryFactory.adapters.first?.users.first?
                .contains(
                    "Reconnect to your existing Channel")
                == true)
    }

    func testStoppingHeadlessHostCancelsInflightRun() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let host = try HeadlessAppHost(
            instanceID: "headless-cancel",
            socketPath: fixture.socketPath,
            applicationSupportDirectory: fixture.support,
            publishesCurrentLink: false)
        try host.start(launchInitialTerminal: true)

        let finished = expectation(description: "run request returns")
        let responseLock = NSLock()
        var response: String?
        DispatchQueue.global(qos: .userInitiated).async {
            let value = AppSocketClient.request(
                "run 1 sleep 30",
                socketPath: fixture.socketPath)
            responseLock.lock()
            response = value
            responseLock.unlock()
            finished.fulfill()
        }
        usleep(400_000)
        host.stop()
        wait(for: [finished], timeout: 5)

        responseLock.lock()
        let value = response
        responseLock.unlock()
        XCTAssertTrue(
            value?.hasPrefix("error:") == true,
            "got: \(value ?? "nil")")
        XCTAssertFalse(value?.contains("\"exitCode\":-1") == true)
    }

    func testHeadlessInstanceIDMustBePathSafe() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        XCTAssertThrowsError(try HeadlessAppHost(
            instanceID: "../escape",
            socketPath: fixture.socketPath,
            applicationSupportDirectory: fixture.support,
            publishesCurrentLink: false)) { error in
                guard case HeadlessAppHostError.invalidInstanceID("../escape")
                    = error
                else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
    }

    private func makeFixture() throws -> (
        support: URL,
        socketPath: String,
        cleanup: () -> Void
    ) {
        let token = UUID().uuidString.lowercased()
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-headless-\(token)")
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true)
        let socketPath = "/tmp/infinitty-headless-\(token.prefix(12)).sock"
        return (
            support,
            socketPath,
            {
                unlink(socketPath)
                try? FileManager.default.removeItem(at: support)
            })
    }
}

final class HeadlessCloudRuntimeFactory:
    CollaborationCloudRuntimeFactoryProtocol, @unchecked Sendable
{
    private let lock = NSLock()
    private var storedContexts:
        [CollaborationCloudRuntimeContext] = []
    private var storedAdapters:
        [HeadlessCloudRuntimeAdapter] = []

    var contexts: [CollaborationCloudRuntimeContext] {
        lock.withLock { storedContexts }
    }

    var adapters: [HeadlessCloudRuntimeAdapter] {
        lock.withLock { storedAdapters }
    }

    func makeAdapter(
        context: CollaborationCloudRuntimeContext
    ) throws -> any CollaborationAgentRuntimeAdapter {
        let adapter = HeadlessCloudRuntimeAdapter(
            context: context)
        lock.withLock {
            storedContexts.append(context)
            storedAdapters.append(adapter)
        }
        return adapter
    }
}

final class HeadlessCloudRuntimeAdapter:
    CollaborationAgentRuntimeAdapter, @unchecked Sendable
{
    private let context: CollaborationCloudRuntimeContext
    private let lock = NSLock()
    private var storedUsers: [String] = []

    init(context: CollaborationCloudRuntimeContext) {
        self.context = context
    }

    var users: [String] {
        lock.withLock { storedUsers }
    }

    func prepare() async throws
        -> CollaborationRuntimeSessionReceipt
    {
        CollaborationRuntimeSessionReceipt(
            id: "receipt-headless-cloud",
            proposalID: context.proposalID,
            agentID: context.agent.id,
            adapterKind: "codex_app_server",
            provider: "codex",
            remoteSessionID:
                context.previousReceipt?.remoteSessionID
                ?? "remote-session-1",
            workspace: context.workspace,
            modelID: context.agent.modelID,
            endpointFingerprint:
                CollaborationRuntimeSessionReceipt.fingerprint(
                    endpointURL:
                        context.agent.cloudConnection?.endpointURL
                        ?? ""),
            accountFingerprint:
                String(repeating: "b", count: 64),
            capabilities: ["interrupt", "resume", "stream"],
            preparedAt: Date())
    }

    func turn(
        system: String,
        user: String,
        approvalScopeID: String?,
        timeout: TimeInterval,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        lock.withLock {
            storedUsers.append(user)
        }
        onPartial?("CLOUD_CHANNEL")
        return "CLOUD_CHANNEL_READY"
    }

    func interrupt() async {}
    func close() async {}
}
