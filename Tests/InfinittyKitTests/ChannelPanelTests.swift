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
}
