import Foundation
import XCTest

@testable import InfinittyKit

private final class TerminalRegistrationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TerminalAgentRegistration?

    var value: TerminalAgentRegistration? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: TerminalAgentRegistration?) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private final class UnavailableTerminalChannelCoordinator:
    TerminalChannelCoordinating
{
    func snapshot() -> CollaborationSnapshot? { nil }

    func execute(_ encoded: String) -> (
        response: String,
        snapshot: CollaborationSnapshot?
    ) {
        ("unavailable", nil)
    }
}

final class TerminalChannelBridgeTests: XCTestCase {
    func testContextResponseHasHardModelVisibleSizeCap() throws {
        let endpointID = "instance/terminal:1"
        let participantID = TerminalAgentRegistration.participantID(
            endpointID: endpointID)
        let endpoint = CollaborationEndpoint(
            id: endpointID,
            kind: .terminal,
            label: "Claude 1",
            participantID: participantID,
            instanceID: "instance")
        let participant = CollaborationParticipant(
            id: participantID,
            displayName: "Claude 1",
            role: "terminal agent",
            provider: "claude",
            capabilities: ["channel.receive", "channel.send"])
        let messages = (0..<12).map { index in
            CollaborationMessage(
                id: "message-\(index)",
                threadID: nil,
                authorID: participantID,
                text: String(repeating: "x", count: 2_048))
        }
        let snapshot = CollaborationSnapshot(
            revision: 1,
            channels: [CollaborationChannelState(
                id: "channel-1",
                name: "Channel 1",
                colorHex: "#7C8CF8",
                createdAt: Date(timeIntervalSince1970: 0),
                revision: 1,
                endpoints: [endpoint],
                participants: [participant],
                responsibilities: [],
                plan: [],
                messages: messages)])
        let registration = TerminalAgentRegistration(
            displayName: "Claude 1",
            role: "terminal agent",
            provider: "claude",
            modelID: nil,
            sessionID: nil,
            capabilities: ["channel.receive", "channel.send"])

        let response = TerminalChannelControl.contextResponse(
            snapshot: snapshot,
            endpoint: endpoint,
            registration: registration)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(response.utf8))
                as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])

        XCTAssertLessThanOrEqual(response.utf8.count, 3_500)
        XCTAssertEqual(result["truncated"] as? Bool, true)
        XCTAssertEqual((result["recentMessages"] as? [Any])?.count, 0)
        XCTAssertTrue(
            (result["modelContext"] as? String)?
                .contains("Connection status: CONNECTED") == true)
    }

    func testDecodersRejectWrongTypesAndOversizedUTF8() throws {
        let badCapabilities = try XCTUnwrap(BrowserControlCodec.encode([
            "v": 1,
            "displayName": "Claude 1",
            "capabilities": "channel.send",
        ]))
        XCTAssertThrowsError(
            try TerminalAgentRegistration.decode(badCapabilities).get())

        let oversizedName = try XCTUnwrap(BrowserControlCodec.encode([
            "v": 1,
            "displayName": String(repeating: "é", count: 80),
        ]))
        XCTAssertThrowsError(
            try TerminalAgentRegistration.decode(oversizedName).get())

        let numericThread = try XCTUnwrap(BrowserControlCodec.encode([
            "v": 1,
            "text": "Status update",
            "threadID": 42,
        ]))
        XCTAssertThrowsError(try TerminalChannelPost.decode(numericThread).get())
    }

    func testManagedRegistrationIsOwnerSafeAndExpiresWithProcess() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "infinitty-terminal-lifetime-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let coordinator = CollaborationCoordinatorClient(
            applicationSupportDirectory: support)
        let box = TerminalRegistrationBox()
        let endpointID = "lifetime/terminal:1"
        let bridge = TerminalChannelSessionBridge(
            coordinator: coordinator,
            queue: DispatchQueue(label: "terminal-lifetime-test"),
            endpointProvider: {
                CollaborationEndpoint(
                    id: endpointID,
                    kind: .terminal,
                    label: box.value?.displayName ?? "infinitty",
                    participantID: box.value.map { _ in
                        TerminalAgentRegistration.participantID(
                            endpointID: endpointID)
                    },
                    instanceID: "lifetime")
            },
            registrationProvider: { box.value },
            registrationSetter: { box.set($0) },
            systemActor: CollaborationActor(
                id: "system:lifetime",
                kind: .system,
                displayName: "Infinitty"))

        let firstOwner = Process()
        firstOwner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        firstOwner.arguments = ["30"]
        try firstOwner.run()
        defer {
            if firstOwner.isRunning { firstOwner.terminate() }
        }
        let secondOwner = Process()
        secondOwner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        secondOwner.arguments = ["30"]
        try secondOwner.run()
        defer {
            if secondOwner.isRunning { secondOwner.terminate() }
        }

        func registration(_ name: String, token: String) throws -> String {
            try XCTUnwrap(BrowserControlCodec.encode([
                "v": 1,
                "displayName": name,
                "managedLifetime": true,
                "lifetimeToken": token,
            ]))
        }
        func unregistration(_ token: String) throws -> String {
            try XCTUnwrap(BrowserControlCodec.encode([
                "v": 1,
                "lifetimeToken": token,
            ]))
        }

        let firstPID = pid_t(firstOwner.processIdentifier)
        let secondPID = pid_t(secondOwner.processIdentifier)
        XCTAssertTrue(bridge.register(
            try registration("Claude 1", token: "first-owner"),
            peerProcessID: firstPID).contains("\"ok\":true"))
        XCTAssertTrue(bridge.register(
            try registration("Amp 1", token: "second-owner"),
            peerProcessID: secondPID).contains("\"ok\":true"))

        let staleCleanup = bridge.unregister(
            try unregistration("first-owner"),
            peerProcessID: firstPID)
        XCTAssertTrue(staleCleanup.contains("ownership_mismatch"))
        XCTAssertEqual(box.value?.displayName, "Amp 1")

        secondOwner.terminate()
        secondOwner.waitUntilExit()
        let deadline = Date(timeIntervalSinceNow: 4)
        while box.value != nil, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertNil(box.value, "dead managed owner should not leave a ghost agent")
    }

    func testRegistrationMutationsRollBackWhenCoordinatorIsUnavailable()
        throws
    {
        let box = TerminalRegistrationBox()
        box.set(TerminalAgentRegistration(
            displayName: "Claude 1",
            role: "terminal agent",
            provider: "claude"))
        let endpointID = "unavailable/terminal:1"
        let bridge = TerminalChannelSessionBridge(
            coordinator: UnavailableTerminalChannelCoordinator(),
            queue: DispatchQueue(label: "terminal-unavailable-test"),
            endpointProvider: {
                CollaborationEndpoint(
                    id: endpointID,
                    kind: .terminal,
                    label: box.value?.displayName ?? "infinitty",
                    participantID: box.value.map { _ in
                        TerminalAgentRegistration.participantID(
                            endpointID: endpointID)
                    },
                    instanceID: "unavailable")
            },
            registrationProvider: { box.value },
            registrationSetter: { box.set($0) },
            systemActor: CollaborationActor(
                id: "system:unavailable",
                kind: .system,
                displayName: "Infinitty"))

        let replacement = try XCTUnwrap(BrowserControlCodec.encode([
            "v": 1,
            "displayName": "Amp 1",
            "provider": "amp",
        ]))
        let registrationResponse = bridge.register(replacement)
        XCTAssertTrue(registrationResponse.contains("coordinator_error"))
        XCTAssertEqual(box.value?.displayName, "Claude 1")

        let response = bridge.unregister()

        XCTAssertTrue(response.contains("coordinator_error"))
        XCTAssertEqual(box.value?.displayName, "Claude 1")
    }
}
