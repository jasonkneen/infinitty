import AppKit
import XCTest

@testable import InfinittyKit

final class ChannelPanelTests: XCTestCase {
    func testProjectionSeparatesRoomConversationThreadsAndCoordinationState() {
        let channel = makeChannel()
        let projection = ChannelPanelProjection(
            channel: channel,
            selectedThreadID: nil)

        XCTAssertEqual(projection.channelID, "channel-1")
        XCTAssertEqual(projection.title, "Launch Room")
        XCTAssertEqual(projection.roomMessages.map(\.text), ["Room kickoff"])
        XCTAssertEqual(projection.threads.map(\.id), ["thread-a", "thread-b"])
        XCTAssertEqual(projection.threads.first?.messageCount, 2)
        XCTAssertEqual(projection.participants.map(\.name), ["Chat 1", "Chat 2"])
        XCTAssertEqual(
            projection.participants.map(\.role),
            ["planner", "implementer"])
        XCTAssertEqual(
            projection.participants.map(\.status),
            ["connected", "connected"])
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
        XCTAssertEqual(
            projection.selectedThreadTitle,
            "Chat 1: I will design")
    }

    func testControllerCanSteerRoomAndSelectedSubthread() {
        let controller = ChannelPanelController(channel: makeChannel())
        var sent: [(String, String?)] = []
        var roleUpdates: [(String, String)] = []
        controller.onSendMessage = { sent.append(($0, $1)) }
        controller.onUpdateRole = { roleUpdates.append(($0, $1)) }

        controller.submitForTesting("Room steer")
        controller.selectThreadForTesting("thread-b")
        controller.submitForTesting("Thread steer")

        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0].0, "Room steer")
        XCTAssertNil(sent[0].1)
        XCTAssertEqual(sent[1].0, "Thread steer")
        XCTAssertEqual(sent[1].1, "thread-b")
        controller.updateRoleForTesting(
            participantID: "participant-2",
            role: "test owner")
        XCTAssertEqual(roleUpdates.first?.0, "participant-2")
        XCTAssertEqual(roleUpdates.first?.1, "test owner")
        XCTAssertTrue(controller.renderedTextForTesting.contains("Launch Room"))
        XCTAssertTrue(controller.renderedTextForTesting.contains("Chat 1"))
        XCTAssertTrue(controller.renderedTextForTesting.contains("Sources/**"))
        XCTAssertTrue(controller.renderedTextForTesting.contains("revision 7"))
    }

    func testChannelIsAFirstClassMovableUtilityPaneKind() {
        XCTAssertEqual(UtilityPanelKind.channel.title, "Channel")
        XCTAssertEqual(UtilityPanelKind.channel.symbol, "person.3.sequence")
        let pane = UtilityPaneView(
            kind: .channel,
            contentView: NSView(),
            background: .black)
        XCTAssertEqual(pane.accessibilityLabel(), "Channel panel")
        XCTAssertFalse(pane.showsNewChatInHeaderForTesting)
    }

    func testControlStateExposesStableRoomParticipantAndThreadIdentity() {
        let controller = ChannelPanelController(channel: makeChannel())
        XCTAssertTrue(controller.selectThreadForControl("thread-b"))

        let state = controller.controlState()
        XCTAssertEqual(state["panelId"] as? String, "channel-panel-channel-1")
        XCTAssertEqual(state["channelId"] as? String, "channel-1")
        XCTAssertEqual(state["title"] as? String, "Launch Room")
        XCTAssertEqual(state["selectedThreadId"] as? String, "thread-b")
        XCTAssertEqual(state["open"] as? Bool, true)
        let participants = state["participants"] as? [[String: Any]]
        XCTAssertEqual(participants?.map { $0["name"] as? String }, [
            "Chat 1", "Chat 2",
        ])
        let threads = state["threads"] as? [[String: Any]]
        XCTAssertEqual(threads?.map { $0["id"] as? String }, [
            "thread-a", "thread-b",
        ])
        XCTAssertFalse(controller.selectThreadForControl("missing-thread"))
    }

    func testNarrowChannelPaneUsesOneUsableTabbedSection() {
        let controller = ChannelPanelController(channel: makeChannel())
        controller.layoutForTesting(width: 360)

        XCTAssertTrue(controller.isCompact)
        XCTAssertEqual(controller.visibleCompactSectionForTesting, 1)
        controller.selectCompactSectionForTesting(0)
        XCTAssertEqual(controller.visibleCompactSectionForTesting, 0)
        controller.selectCompactSectionForTesting(2)
        XCTAssertEqual(controller.visibleCompactSectionForTesting, 2)

        controller.layoutForTesting(width: 900)
        XCTAssertFalse(controller.isCompact)
        XCTAssertNil(controller.visibleCompactSectionForTesting)
    }

    func testPendingProposalShowsExactAgentsAndRequiresExplicitDecision() {
        let proposal = makeProposal()
        let controller = ChannelPanelController(
            channel: makeChannel(),
            proposals: [proposal])
        var decisions: [(String, String, Bool)] = []
        controller.onProposalDecision = {
            decisions.append(($0, $1, $2))
        }

        XCTAssertTrue(controller.renderedTextForTesting.contains(
            "Build the release safely"))
        XCTAssertTrue(controller.renderedTextForTesting.contains(
            "Architecture Lead"))
        XCTAssertTrue(controller.renderedTextForTesting.contains("worktrees"))
        let proposals = controller.controlState()["proposals"]
            as? [[String: Any]]
        XCTAssertEqual(proposals?.first?["state"] as? String, "pending")
        XCTAssertEqual(
            (proposals?.first?["agents"] as? [[String: Any]])?
                .first?["provider"] as? String,
            "amp")

        controller.decideProposalForTesting(
            proposalID: proposal.spec.id,
            approve: true)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.0, proposal.spec.id)
        XCTAssertEqual(decisions.first?.1, proposal.digest)
        XCTAssertEqual(decisions.first?.2, true)
    }

    func testCloudProposalShowsSafeConnectionAndDurableSessionState() {
        let cloud = CollaborationCloudConnection(
            endpointURL:
                "wss://codex.example.test/app-server",
            credentialEnvironmentVariable:
                "CODEX_CHANNEL_TOKEN",
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
            endpointFingerprint:
                String(repeating: "a", count: 64),
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
        let controller = ChannelPanelController(
            channel: makeChannel(),
            proposals: [proposal])

        let state = controller.controlState()
        let projected = (state["proposals"]
            as? [[String: Any]])?.first
        let agent = (projected?["agents"]
            as? [[String: Any]])?.first
        let connection = agent?["cloudConnection"]
            as? [String: Any]
        XCTAssertEqual(
            connection?["endpointURL"] as? String,
            cloud.endpointURL)
        XCTAssertEqual(
            connection?["credentialEnvironmentVariable"]
                as? String,
            "CODEX_CHANNEL_TOKEN")
        XCTAssertEqual(
            (projected?["runtimeReceipts"]
                as? [[String: Any]])?
                .first?["remoteSessionID"] as? String,
            "remote-session-1")
        XCTAssertTrue(
            controller.renderedTextForTesting.contains(
                "remote session ready"))
        XCTAssertFalse(
            controller.renderedTextForTesting.contains(
                "secret-token"))
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
                    id: "endpoint-1",
                    kind: .chat,
                    label: "Chat 1",
                    participantID: "participant-1",
                    instanceID: "instance-1"),
                CollaborationEndpoint(
                    id: "endpoint-2",
                    kind: .chat,
                    label: "Chat 2",
                    participantID: "participant-2",
                    instanceID: "instance-1"),
            ],
            participants: [
                CollaborationParticipant(
                    id: "participant-1",
                    displayName: "Chat 1",
                    role: "planner",
                    provider: "amp",
                    modelID: "low",
                    capabilities: ["channel.send"]),
                CollaborationParticipant(
                    id: "participant-2",
                    displayName: "Chat 2",
                    role: "implementer",
                    provider: "codex",
                    modelID: "configured default",
                    capabilities: ["channel.send"]),
            ],
            responsibilities: [
                CollaborationResponsibility(
                    id: "claim-1",
                    scope: "Sources/**",
                    summary: "Own implementation",
                    ownerID: "participant-2"),
            ],
            plan: [
                CollaborationPlanItem(
                    id: "plan-1",
                    title: "Design",
                    status: .completed,
                    ownerID: "participant-1"),
                CollaborationPlanItem(
                    id: "plan-2",
                    title: "Build",
                    status: .inProgress,
                    ownerID: "participant-2",
                    dependencyIDs: ["plan-1"]),
            ],
            messages: [
                CollaborationMessage(
                    id: "message-1",
                    threadID: nil,
                    authorID: "human:jason",
                    text: "Room kickoff"),
                CollaborationMessage(
                    id: "message-2",
                    threadID: "thread-a",
                    authorID: "participant-1",
                    text: "I will design"),
                CollaborationMessage(
                    id: "message-3",
                    threadID: "thread-a",
                    authorID: "participant-1",
                    text: "Design complete"),
                CollaborationMessage(
                    id: "message-4",
                    threadID: "thread-b",
                    authorID: "participant-2",
                    text: "Implementation started"),
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
