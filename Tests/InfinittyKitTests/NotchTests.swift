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

    func testIndicatorLayoutKeepsNotchCenteredWhenActivityAppears() {
        let idle = NotchLayout.indicatorFrame(
            centerX: 720, notchWidth: 180,
            screenTop: 900, barHeight: 32, showsActivity: false)
        let active = NotchLayout.indicatorFrame(
            centerX: 720, notchWidth: 180,
            screenTop: 900, barHeight: 32, showsActivity: true)

        XCTAssertEqual(idle.width, 312)
        XCTAssertEqual(active.width, 506)
        XCTAssertEqual(idle.minX + 66 + 90, 720)
        XCTAssertEqual(active.minX + 260 + 90, 720)
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

    func testConfiguredPetUsesInfinittyTerminalSpritesheet() {
        IndicatorView.configurePet("infinitty")
        XCTAssertNotNil(IndicatorView.codexSprite)
    }

    func testLiveQuietSessionRendersIdleInsteadOfBlank() {
        XCTAssertEqual(
            NotchSessionState.resolve(
                live: true, busy: false, wasLive: true, current: .running),
            .idle)
        XCTAssertEqual(
            NotchSessionState.resolve(
                live: false, busy: false, wasLive: true, current: .idle),
            .done)
    }

    func testResumeCommandsUseValidatedSessionIdentifiers() {
        let id = "019f7bb9-0f19-7200-8b30-70fcea423ab5"
        let claude = AgentSession(
            id: "/tmp/claude.jsonl", kind: .claude, title: "repo",
            snippet: "", model: "", lastModified: Date(), threadID: id)
        let codex = AgentSession(
            id: "/tmp/codex.jsonl", kind: .codex, title: "repo",
            snippet: "", model: "", lastModified: Date(), threadID: id)
        let invalid = AgentSession(
            id: "/tmp/invalid.jsonl", kind: .codex, title: "repo",
            snippet: "", model: "", lastModified: Date(), threadID: "not-a-uuid")

        XCTAssertEqual(
            claude.resumeCommand(executablePath: "/opt/tools/claude"),
            "'/opt/tools/claude' --resume '\(id)'")
        XCTAssertEqual(
            codex.resumeCommand(executablePath: "/opt/tools/codex"),
            "'/opt/tools/codex' resume '\(id)'")
        XCTAssertNil(invalid.resumeCommand())
    }

    func testConfiguredNotchTypographyUsesMainFontFamily() {
        let font = NotchAppearance(
            fontName: "Helvetica", fontStyle: nil,
            fontSize: 13, pet: "infinitty")
            .font(size: 11, bold: false)
        XCTAssertTrue(font.familyName?.contains("Helvetica") == true)
    }

    func testConfiguredNotchTypographyUsesConfiguredFaceStyle() throws {
        let font = NotchAppearance(
            fontName: "Berkeley Mono", fontStyle: "ExtraLight",
            fontSize: 14, pet: "infinitty")
            .font(size: 11, bold: false)
        XCTAssertEqual(font.fontName, "BerkeleyMono-ExtraLight")
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

    func testScannerPreservesClaudeResumeIDAndWorkingDirectory() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-notch-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent(".claude/projects/-tmp-titerm")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = "019f7bb9-0f19-7200-8b30-70fcea423ab5"
        let transcript = project.appendingPathComponent("\(id).jsonl")
        try writeJSONLines([
            ["type": "user", "sessionId": id, "cwd": "/tmp/titerm",
             "timestamp": "2026-07-21T12:00:00.000Z",
             "message": ["content": "continue the work"]],
        ], to: transcript)

        let result = SessionScanner(home: home).scan(live: [], claudeCwdCounts: [:])

        XCTAssertEqual(result.first?.threadID, id)
        XCTAssertEqual(result.first?.workingDirectory, "/tmp/titerm")
    }

    func testMultipleClaudeProcessesInOneDirectoryStayOwnershipAmbiguous() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-notch-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent(".claude/projects/-tmp-shared")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for id in [
            "019f7bb9-0f19-7200-8b30-70fcea423ab5",
            "019f7bb9-0f19-7200-8b30-70fcea423ab6",
        ] {
            try writeJSONLines([
                ["type": "user", "sessionId": id, "cwd": "/tmp/shared",
                 "message": ["content": "work"]],
            ], to: project.appendingPathComponent("\(id).jsonl"))
        }
        let processes = [101, 102].map {
            ProcessDiscovery.Snapshot(
                kind: .claude, processID: pid_t($0),
                transcriptPath: nil, cwd: "/tmp/shared")
        }

        let result = SessionScanner(home: home).scan(liveProcesses: processes)

        XCTAssertEqual(result.filter(\.isLive).count, 2)
        XCTAssertTrue(result.allSatisfy { $0.processID == nil })
    }

    private func writeJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        let lines = try objects.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
