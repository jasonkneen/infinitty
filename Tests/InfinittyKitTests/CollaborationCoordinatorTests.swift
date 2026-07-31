import Foundation
import XCTest

@testable import InfinittyKit

final class CollaborationCoordinatorTests: XCTestCase {
    func testOnlyKernelAttestedNativeHostPathCanApproveProposal() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "infinitty-coordinator-approval-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let coordinator = CollaborationCoordinatorClient(
            applicationSupportDirectory: support)
        let proposal = CollaborationRoomProposalSpec(
            id: "proposal-1",
            channelID: "channel-1",
            roomName: "Implementation Room",
            objective: "Build and verify the requested feature.",
            workspaceRoot: FileManager.default.currentDirectoryPath,
            agents: [
                CollaborationAgentSpec(
                    id: "agent-1",
                    displayName: "Architect",
                    role: "planning lead",
                    runtime: .local,
                    provider: "amp",
                    modelID: "smart",
                    responsibilityScopes: ["Sources/**"]),
            ],
            workspaceStrategy: .worktrees,
            requestedCapabilities: ["workspace.write"],
            expiresAt: Date().addingTimeInterval(300))
        let prepare = CollaborationControlRequest(
            op: .prepareProposal,
            actor: CollaborationActor(
                id: "agent:requester",
                kind: .agent,
                displayName: "Requesting agent"),
            idempotencyKey: "prepare-proposal-1",
            proposal: proposal)
        let prepared = try XCTUnwrap(coordinator.execute(
            try XCTUnwrap(CollaborationControlCodec.encode(prepare)))
            .snapshot?.proposals.first)

        let approval = CollaborationControlRequest(
            op: .approveProposal,
            actor: CollaborationActor(
                id: "human:test",
                kind: .human,
                displayName: "Test human"),
            idempotencyKey: "approve-proposal-1",
            proposalID: proposal.id,
            proposalDigest: prepared.digest)
        let encodedApproval = try XCTUnwrap(
            CollaborationControlCodec.encode(approval))

        let forged = coordinator.execute(encodedApproval)
        XCTAssertNil(forged.snapshot)
        XCTAssertTrue(
            forged.response.contains(
                "requires trusted host confirmation"),
            "response=\(forged.response)")

        let approved = try XCTUnwrap(
            coordinator.executeHumanDecision(encodedApproval).snapshot)
        XCTAssertEqual(approved.proposals.first?.state, .approved)
        XCTAssertEqual(
            approved.proposals.first?.decidedByActorID,
            "human:test")
    }

    func testVisualAndHeadlessClientsShareAuthorityAndReplayAfterOwnerExit()
        throws
    {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "infinitty-coordinator-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        var owner: CollaborationCoordinatorClient? =
            CollaborationCoordinatorClient(
                applicationSupportDirectory: support)
        let peer = CollaborationCoordinatorClient(
            applicationSupportDirectory: support)
        let request = CollaborationControlRequest(
            op: .linkAndJoin,
            actor: CollaborationActor(
                id: "human:test", kind: .human, displayName: "Test"),
            idempotencyKey: "cross-instance-link",
            source: CollaborationEndpoint(
                id: "visual/chat-1", kind: .chat, label: "Chat 1",
                participantID: "visual/participant-1",
                instanceID: "visual"),
            target: CollaborationEndpoint(
                id: "headless/terminal-1", kind: .terminal,
                label: "Amp terminal", instanceID: "headless"),
            participants: [
                CollaborationParticipant(
                    id: "visual/participant-1",
                    displayName: "Chat 1",
                    role: "coding agent",
                    provider: "amp"),
            ])
        let encoded = try XCTUnwrap(
            CollaborationControlCodec.encode(request))

        let committed = try XCTUnwrap(owner?.execute(encoded).snapshot)
        XCTAssertEqual(committed.channels.first?.endpoints.count, 2)
        XCTAssertEqual(peer.snapshot(), committed)

        owner = nil
        let replayed = try XCTUnwrap(peer.snapshot())
        XCTAssertEqual(replayed, committed)
    }
}
