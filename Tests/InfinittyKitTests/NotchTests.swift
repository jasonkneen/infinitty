import AppKit
import XCTest

@testable import InfinittyKit

final class NotchTests: XCTestCase {
    func testDisplayModePreservesConfigAliases() {
        XCTAssertEqual(NotchDisplayMode("builtin"), .builtin)
        XCTAssertEqual(NotchDisplayMode("external"), .external)
        XCTAssertEqual(NotchDisplayMode("focused"), .primary)
        XCTAssertEqual(NotchDisplayMode("both"), .all)
        XCTAssertEqual(NotchDisplayMode("unknown"), .builtin)
    }

    func testIndicatorLayoutKeepsItsRightEdgeWhenActivityAppears() {
        let idle = NotchLayout.indicatorFrame(
            rightEdge: 720, screenTop: 900, barHeight: 32, showsActivity: false)
        let active = NotchLayout.indicatorFrame(
            rightEdge: 720, screenTop: 900, barHeight: 32, showsActivity: true)

        XCTAssertEqual(idle.width, 66)
        XCTAssertEqual(active.width, 260)
        XCTAssertEqual(idle.maxX, 720)
        XCTAssertEqual(active.maxX, 720)
        XCTAssertEqual(active.maxY, 900)
    }

    func testOSCMarkersAndSocketTextProduceCompatibleActivityPresentations() {
        XCTAssertEqual(
            NotchActivityPresentation.marker(
                kind: UInt8(ascii: "C"), exitCode: 0, commandLine: "swift test"),
            NotchActivityPresentation(text: "running swift test", tone: .running))
        XCTAssertEqual(
            NotchActivityPresentation.marker(
                kind: UInt8(ascii: "D"), exitCode: 0, commandLine: nil),
            NotchActivityPresentation(text: "done", tone: .success))
        XCTAssertEqual(
            NotchActivityPresentation.marker(
                kind: UInt8(ascii: "D"), exitCode: 17, commandLine: nil),
            NotchActivityPresentation(text: "exit 17", tone: .failure))
        XCTAssertNil(NotchActivityPresentation.marker(
            kind: UInt8(ascii: "A"), exitCode: 0, commandLine: nil))
        XCTAssertEqual(NotchActivityPresentation.custom(String(repeating: "x", count: 50)).text.count, 38)
    }

    func testBundledCodexPetDoesNotDependOnAgentNotchCheckout() {
        IndicatorView.currentPetID = "codex"
        XCTAssertNotNil(IndicatorView.codexSprite)
    }

    func testScannerGroupsCodexSubagentAndKeepsRuntimeModelIdentifier() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-notch-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".codex/sessions/2026/07/21")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let root = sessions.appendingPathComponent("root.jsonl")
        let child = sessions.appendingPathComponent("child.jsonl")
        try writeJSONLines([
            ["payload": ["id": "root", "cwd": "/tmp/titerm"]],
            ["payload": ["type": "user_message", "message": "build the notch"],
             "model": "runtime-model-2026"],
        ], to: root)
        try writeJSONLines([
            ["payload": [
                "id": "child", "cwd": "/tmp/titerm", "parent_thread_id": "root",
                "source": ["subagent": ["thread_spawn": ["agent_nickname": "Gauss"]]],
            ]],
            ["payload": ["type": "user_message", "message": "review the UI"],
             "model": "runtime-subagent-model"],
        ], to: child)

        let scanner = SessionScanner(home: home)
        let discovered = scanner.scan(live: [], claudeCwdCounts: [:])
        let discoveredChildPath = try XCTUnwrap(discovered.first?.children.first?.id)
        let result = scanner.scan(
            live: Set([discoveredChildPath]), claudeCwdCounts: [:])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].threadID, "root")
        XCTAssertEqual(result[0].model, "runtime-model-2026")
        XCTAssertTrue(result[0].isLive)
        XCTAssertEqual(result[0].children.count, 1)
        XCTAssertEqual(result[0].children[0].nickname, "Gauss")
        XCTAssertEqual(result[0].children[0].model, "runtime-subagent-model")
    }

    private func writeJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        let lines = try objects.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
