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
                "terminal", "terminal.run", "chat", "channel", "channel.panel",
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
        XCTAssertEqual(panes.first?["title"] as? String, "Headless Lead")

        let closed = try request([
            "v": 1,
            "op": "close",
            "chatId": chatID,
        ])
        XCTAssertEqual(closed["open"] as? Bool, false)
        XCTAssertEqual(
            AppSocketClient.request(
                "list", socketPath: fixture.socketPath),
            "[]")
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
        printf '%s\n' '{"type":"result","result":"AMP_ROOM_READY"}'
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
        var chatState: [String: Any]?
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
               let result = envelope["result"] as? [String: Any],
               let first = (result["chats"] as? [[String: Any]])?
                   .first
            {
                chatState = first
                let threads = first["threads"] as? [[String: Any]]
                let messages = threads?.first?["messages"]
                    as? [[String: Any]]
                if messages?.contains(where: {
                    ($0["text"] as? String)?
                        .contains("AMP_ROOM_READY") == true
                }) == true {
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
            ["Headless Architect"])
        XCTAssertEqual(
            channel.responsibilities.map(\.scope),
            ["Sources/**"])
        XCTAssertEqual(
            channel.plan.map(\.ownerID),
            ["agent-headless-architect"])
        XCTAssertEqual(
            chatState?["channelId"] as? String,
            proposalSpec.channelID)
        XCTAssertEqual(
            chatState?["participantId"] as? String,
            "agent-headless-architect")
        let threads = chatState?["threads"] as? [[String: Any]]
        let messages = threads?.first?["messages"]
            as? [[String: Any]]
        XCTAssertTrue(messages?.contains(where: {
            ($0["text"] as? String)?
                .contains("AMP_ROOM_READY") == true
        }) == true)
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

        let panelRequest = try XCTUnwrap(BrowserControlCodec.encode([
            "v": 1,
            "op": "open",
            "channelId": "headless-channel",
        ]))
        let panelText = try XCTUnwrap(AppSocketClient.request(
            "channel-panel \(panelRequest)",
            socketPath: fixture.socketPath))
        let panelEnvelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(panelText.utf8))
                as? [String: Any])
        XCTAssertEqual(panelEnvelope["ok"] as? Bool, true)
        let panel = try XCTUnwrap(
            panelEnvelope["result"] as? [String: Any])
        XCTAssertEqual(panel["panelId"] as? String,
                       "channel-panel-headless-channel")
        XCTAssertEqual(panel["title"] as? String, "Headless Channel")
        XCTAssertEqual(panel["open"] as? Bool, true)

        let listWithPanelText = try XCTUnwrap(
            AppSocketClient.request("list", socketPath: fixture.socketPath))
        let listWithPanel = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(listWithPanelText.utf8))
                as? [[String: Any]])
        XCTAssertEqual(
            listWithPanel.compactMap { $0["kind"] as? String },
            ["channel"])
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
