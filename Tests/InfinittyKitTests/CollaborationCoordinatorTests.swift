import Foundation
import XCTest

@testable import InfinittyKit

final class CollaborationCoordinatorTests: XCTestCase {
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
