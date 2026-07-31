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
                "terminal", "terminal.run", "channel", "channel.panel",
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
