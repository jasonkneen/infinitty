import Foundation
import XCTest

@testable import InfinittyKit

final class CollaborationAuditTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "infinitty-audit-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testQueryIsVerifiedFilteredBoundedAndTipStable() throws {
        let store = MemoryCollaborationEventStore()
        var clock: TimeInterval = 1_000
        var event = 0
        let room = try CollaborationRoom(
            store: store,
            now: {
                defer { clock += 1 }
                return Date(timeIntervalSince1970: clock)
            },
            idFactory: { "channel-audit" },
            eventIDFactory: {
                event += 1
                return "event-\(event)"
            })
        let human = CollaborationActor(
            id: "human:jason",
            kind: .human,
            displayName: "Jason")
        _ = try room.apply(
            .createChannel(
                id: "channel-audit",
                name: "Audit",
                colorHex: nil),
            by: human)
        _ = try room.apply(
            .joinParticipant(
                channelID: "channel-audit",
                participant: CollaborationParticipant(
                    id: "agent:one",
                    displayName: "One",
                    role: "Review",
                    provider: "amp")),
            by: human)
        _ = try room.apply(
            .postMessage(
                channelID: "channel-audit",
                message: CollaborationMessage(
                    id: "message-1",
                    threadID: nil,
                    authorID: human.id,
                    text: "Start")),
            by: human)

        let service = CollaborationAuditService(
            store: store,
            rootDirectory: root,
            now: { Date(timeIntervalSince1970: 2_000) })
        let first = try service.query(CollaborationAuditQuery(limit: 1))
        XCTAssertTrue(first.verified)
        XCTAssertEqual(first.journalTipSequence, 3)
        XCTAssertEqual(first.records.map(\.sequence), [1])
        XCTAssertNotNil(first.nextCursor)

        _ = try room.apply(
            .postMessage(
                channelID: "channel-audit",
                message: CollaborationMessage(
                    id: "message-2",
                    threadID: nil,
                    authorID: human.id,
                    text: "Later")),
            by: human)
        let second = try service.query(CollaborationAuditQuery(
            cursor: first.nextCursor,
            eventKinds: ["message_posted"],
            limit: 10))
        XCTAssertEqual(second.journalTipSequence, 3)
        XCTAssertEqual(second.records.map(\.sequence), [3])
        XCTAssertNil(second.nextCursor)
    }

    func testQueryRejectsHashValidSemanticallyImpossibleJournal() throws {
        let created = CollaborationChannelState(
            id: "channel-audit",
            name: "Audit",
            colorHex: "#3366FF",
            createdAt: Date(timeIntervalSince1970: 1_000),
            revision: 1,
            endpoints: [],
            participants: [],
            responsibilities: [],
            plan: [],
            messages: [])
        let first = try CollaborationAuditRecord.make(
            sequence: 1,
            eventID: "event-1",
            idempotencyKey: nil,
            commandFingerprint: "create",
            timestamp: created.createdAt,
            actor: CollaborationActor(
                id: "human:jason",
                kind: .human,
                displayName: "Jason"),
            causationID: nil,
            channelID: created.id,
            body: .channelCreated(created),
            previousHash: CollaborationAuditRecord.genesisHash)
        let impossible = try CollaborationAuditRecord.make(
            sequence: 2,
            eventID: "event-2",
            idempotencyKey: nil,
            commandFingerprint: "leave-missing",
            timestamp: Date(timeIntervalSince1970: 1_001),
            actor: first.actor,
            causationID: nil,
            channelID: created.id,
            body: .endpointLeft(
                channelID: created.id,
                endpointID: "missing",
                participantID: nil),
            previousHash: first.hash)
        XCTAssertTrue(CollaborationAuditRecord.verify(impossible))
        let service = CollaborationAuditService(
            store: MemoryCollaborationEventStore(
                records: [first, impossible]),
            rootDirectory: root)

        XCTAssertThrowsError(
            try service.query(CollaborationAuditQuery())
        ) { error in
            XCTAssertEqual(
                error as? CollaborationAuditError,
                .integrityFailure(sequence: 2))
        }
    }

    func testSignedExportVerifiesAndTamperingFailsClosed() throws {
        let store = MemoryCollaborationEventStore()
        let room = try CollaborationRoom(
            store: store,
            now: { Date(timeIntervalSince1970: 1_000) },
            idFactory: { "channel-export" },
            eventIDFactory: { "event-export" })
        _ = try room.apply(
            .createChannel(
                id: "channel-export",
                name: "Export",
                colorHex: nil),
            by: CollaborationActor(
                id: "human:jason",
                kind: .human,
                displayName: "Jason"))
        let service = CollaborationAuditService(
            store: store,
            rootDirectory: root,
            now: { Date(timeIntervalSince1970: 2_000) },
            idFactory: { "fixture" })
        let receipt = try service.export()
        XCTAssertEqual(receipt.exportID, "audit-fixture")
        XCTAssertEqual(receipt.recordCount, 1)
        XCTAssertEqual(receipt.journalTipSequence, 1)

        let verification = try service.verify(
            exportID: receipt.exportID)
        XCTAssertTrue(verification.verified)
        XCTAssertEqual(verification.payloadSHA256, receipt.payloadSHA256)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: receipt.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
        let keyAttributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent(
                "audit-signing-key-v1").path)
        XCTAssertEqual(
            (keyAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)

        let url = URL(fileURLWithPath: receipt.path)
        var data = try Data(contentsOf: url)
        let index = try XCTUnwrap(data.firstIndex(of: UInt8(ascii: "E")))
        data[index] = UInt8(ascii: "X")
        try data.write(to: url)
        XCTAssertThrowsError(
            try service.verify(exportID: receipt.exportID))
    }

    func testVerifyRejectsPathTraversalIds() throws {
        let service = CollaborationAuditService(
            store: MemoryCollaborationEventStore(),
            rootDirectory: root)
        XCTAssertThrowsError(
            try service.verify(exportID: "../coordinator"))
    }

    func testCoordinatorExposesStructuredQueryExportAndVerification()
        throws
    {
        let support = root.appendingPathComponent(
            "support", isDirectory: true)
        let coordinator = CollaborationCoordinatorClient(
            applicationSupportDirectory: support)
        let create = CollaborationControlRequest(
            op: .create,
            actor: CollaborationActor(
                id: "human:jason",
                kind: .human,
                displayName: "Jason"),
            idempotencyKey: "audit-create",
            channelID: "channel-audit",
            name: "Audit")
        XCTAssertNotNil(coordinator.execute(try XCTUnwrap(
            CollaborationControlCodec.encode(create))).snapshot)

        let queryResponse = coordinator.executeAudit(try XCTUnwrap(
            CollaborationAuditControlCodec.encode(
                CollaborationAuditControlRequest(
                    op: .query,
                    query: CollaborationAuditQuery(limit: 10)))))
        let queryObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(queryResponse.utf8)) as? [String: Any])
        XCTAssertEqual(queryObject["ok"] as? Bool, true)
        let page = try XCTUnwrap(
            queryObject["page"] as? [String: Any])
        XCTAssertEqual(page["verified"] as? Bool, true)
        XCTAssertEqual(page["journalTipSequence"] as? Int, 1)

        let exportResponse = coordinator.executeAudit(try XCTUnwrap(
            CollaborationAuditControlCodec.encode(
                CollaborationAuditControlRequest(op: .export))))
        let exportObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(exportResponse.utf8)) as? [String: Any])
        let export = try XCTUnwrap(
            exportObject["export"] as? [String: Any])
        let exportID = try XCTUnwrap(export["exportID"] as? String)
        let verifyResponse = coordinator.executeAudit(try XCTUnwrap(
            CollaborationAuditControlCodec.encode(
                CollaborationAuditControlRequest(
                    op: .verify,
                    exportID: exportID))))
        let verifyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(verifyResponse.utf8)) as? [String: Any])
        let verification = try XCTUnwrap(
            verifyObject["verification"] as? [String: Any])
        XCTAssertEqual(verification["verified"] as? Bool, true)
    }
}
