import XCTest

@testable import InfinittyKit

/// The visual Channel pane is intentionally gone. These tests cover the
/// deterministic room projection retained for MCP/headless control adapters.
final class ChannelPanelTests: XCTestCase {
    func testProjectionSeparatesRoomConversationThreadsAndCoordinationState() {
        let projection = ChannelPanelProjection(
            channel: makeChannel(),
            selectedThreadID: nil)

        XCTAssertEqual(projection.channelID, "channel-1")
        XCTAssertEqual(projection.title, "Launch Room")
        XCTAssertEqual(projection.roomMessages.map(\.text), ["Room kickoff"])
        XCTAssertEqual(projection.threads.map(\.id), ["thread-a", "thread-b"])
        XCTAssertEqual(projection.threads.first?.messageCount, 2)
        XCTAssertEqual(projection.participants.map(\.name), ["Chat 1", "Chat 2"])
        XCTAssertEqual(projection.participants.map(\.role), ["planner", "implementer"])
        XCTAssertEqual(projection.participants.map(\.status), ["connected", "connected"])
        XCTAssertEqual(projection.plan.map(\.title), ["Design", "Build"])
        XCTAssertEqual(projection.plan.last?.dependencyTitles, ["Design"])
        XCTAssertEqual(projection.responsibilities.first?.scope, "Sources/**")
        XCTAssertTrue(projection.auditReceipt.contains("revision 7"))
    }

    func testProjectionShowsOnlySelectedDelegationThreadMessages() {
        let projection = ChannelPanelProjection(
            channel: makeChannel(),
            selectedThreadID: "thread-a")

        XCTAssertEqual(
            projection.visibleMessages.map(\.text),
            ["I will design", "Design complete"])
        XCTAssertEqual(projection.selectedThreadTitle, "Chat 1: I will design")
    }

    func testControlStateExposesRoomDataWithoutClaimingAVisualPanelIsOpen() {
        let state = ChannelPanelProjection(
            channel: makeChannel(),
            selectedThreadID: "thread-b")
            .controlState(isOpen: false)

        XCTAssertEqual(state["panelId"] as? String, "channel-panel-channel-1")
        XCTAssertEqual(state["channelId"] as? String, "channel-1")
        XCTAssertEqual(state["title"] as? String, "Launch Room")
        XCTAssertEqual(state["selectedThreadId"] as? String, "thread-b")
        XCTAssertEqual(state["open"] as? Bool, false)
        let participants = state["participants"] as? [[String: Any]]
        XCTAssertEqual(participants?.map { $0["name"] as? String }, ["Chat 1", "Chat 2"])
        let threads = state["threads"] as? [[String: Any]]
        XCTAssertEqual(threads?.map { $0["id"] as? String }, ["thread-a", "thread-b"])
    }

    func testProposalDetailsRemainAvailableThroughRoomProjection() {
        let proposal = makeProposal()
        let state = ChannelPanelProjection(
            channel: makeChannel(),
            selectedThreadID: nil,
            proposals: [proposal])
            .controlState(isOpen: false)

        let proposals = state["proposals"] as? [[String: Any]]
        XCTAssertEqual(proposals?.first?["state"] as? String, "pending")
        XCTAssertEqual(proposals?.first?["objective"] as? String, "Build the release safely")
        XCTAssertEqual(
            (proposals?.first?["agents"] as? [[String: Any]])?
                .first?["provider"] as? String,
            "amp")
    }

    func testCloudProposalProjectsSafeConnectionAndDurableSessionState() {
        let cloud = CollaborationCloudConnection(
            endpointURL: "wss://codex.example.test/app-server",
            credentialEnvironmentVariable: "CODEX_CHANNEL_TOKEN",
            remoteWorkspace: "/srv/project")
        let spec = CollaborationRoomProposalSpec(
            id: "proposal-cloud",
            channelID: "channel-1",
            roomName: "Launch Room",
            objective: "Run the approved remote agent",
            workspaceRoot: "/tmp/project",
            agents: [
                CollaborationAgentSpec(
                    id: "agent-cloud",
                    displayName: "Remote Architect",
                    role: "Own remote implementation",
                    runtime: .cloud,
                    provider: "codex",
                    modelID: "opaque-model",
                    cloudConnection: cloud),
            ],
            workspaceStrategy: .worktrees,
            expiresAt: Date(timeIntervalSince1970: 5_000))
        let receipt = CollaborationRuntimeSessionReceipt(
            id: "receipt-cloud",
            proposalID: spec.id,
            agentID: "agent-cloud",
            adapterKind: "codex_app_server",
            provider: "codex",
            remoteSessionID: "remote-session-1",
            workspace: "/srv/project",
            modelID: "opaque-model",
            endpointFingerprint: String(repeating: "a", count: 64),
            accountFingerprint: nil,
            capabilities: ["resume", "stream"],
            preparedAt: Date(timeIntervalSince1970: 10))
        let proposal = CollaborationRoomProposal(
            spec: spec,
            digest: try! spec.canonicalDigest(),
            state: .running,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 10),
            decidedByActorID: "human:test",
            decidedAt: Date(timeIntervalSince1970: 2),
            statusMessage: nil,
            runtimeReceipts: [receipt])

        let state = ChannelPanelProjection(
            channel: makeChannel(),
            selectedThreadID: nil,
            proposals: [proposal])
            .controlState(isOpen: false)
        let projected = (state["proposals"] as? [[String: Any]])?.first
        let agent = (projected?["agents"] as? [[String: Any]])?.first
        let connection = agent?["cloudConnection"] as? [String: Any]
        XCTAssertEqual(connection?["endpointURL"] as? String, cloud.endpointURL)
        XCTAssertEqual(
            connection?["credentialEnvironmentVariable"] as? String,
            "CODEX_CHANNEL_TOKEN")
        XCTAssertEqual(
            (projected?["runtimeReceipts"] as? [[String: Any]])?
                .first?["remoteSessionID"] as? String,
            "remote-session-1")
    }

    private func makeChannel() -> CollaborationChannelState {
        CollaborationChannelState(
            id: "channel-1",
            name: "Launch Room",
            colorHex: "#6688ff",
            createdAt: Date(timeIntervalSince1970: 1),
            revision: 7,
            endpoints: [
                CollaborationEndpoint(
                    id: "endpoint-1", kind: .chat, label: "Chat 1",
                    participantID: "participant-1", instanceID: "instance-1"),
                CollaborationEndpoint(
                    id: "endpoint-2", kind: .chat, label: "Chat 2",
                    participantID: "participant-2", instanceID: "instance-1"),
            ],
            participants: [
                CollaborationParticipant(
                    id: "participant-1", displayName: "Chat 1", role: "planner",
                    provider: "amp", modelID: "low",
                    capabilities: ["channel.send"]),
                CollaborationParticipant(
                    id: "participant-2", displayName: "Chat 2", role: "implementer",
                    provider: "codex", modelID: "configured default",
                    capabilities: ["channel.send"]),
            ],
            responsibilities: [
                CollaborationResponsibility(
                    id: "claim-1", scope: "Sources/**",
                    summary: "Own implementation", ownerID: "participant-2"),
            ],
            plan: [
                CollaborationPlanItem(
                    id: "plan-1", title: "Design", status: .completed,
                    ownerID: "participant-1"),
                CollaborationPlanItem(
                    id: "plan-2", title: "Build", status: .inProgress,
                    ownerID: "participant-2", dependencyIDs: ["plan-1"]),
            ],
            messages: [
                CollaborationMessage(
                    id: "message-1", threadID: nil,
                    authorID: "human:jason", text: "Room kickoff"),
                CollaborationMessage(
                    id: "message-2", threadID: "thread-a",
                    authorID: "participant-1", text: "I will design"),
                CollaborationMessage(
                    id: "message-3", threadID: "thread-a",
                    authorID: "participant-1", text: "Design complete"),
                CollaborationMessage(
                    id: "message-4", threadID: "thread-b",
                    authorID: "participant-2", text: "Implementation started"),
            ])
    }

    private func makeProposal() -> CollaborationRoomProposal {
        let spec = CollaborationRoomProposalSpec(
            id: "proposal-1",
            channelID: "channel-1",
            roomName: "Launch Room",
            objective: "Build the release safely",
            workspaceRoot: "/tmp/project",
            agents: [
                CollaborationAgentSpec(
                    id: "agent-architect",
                    displayName: "Architecture Lead",
                    role: "Own system design",
                    runtime: .local,
                    provider: "amp",
                    modelID: "smart",
                    responsibilityScopes: ["Sources/Architecture/**"]),
            ],
            workspaceStrategy: .worktrees,
            requestedCapabilities: ["workspace.write"],
            expiresAt: Date(timeIntervalSince1970: 5_000))
        return CollaborationRoomProposal(
            spec: spec,
            digest: try! spec.canonicalDigest(),
            state: .pending,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            decidedByActorID: nil,
            decidedAt: nil,
            statusMessage: nil)
    }
}
