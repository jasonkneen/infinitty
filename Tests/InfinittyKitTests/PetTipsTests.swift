import XCTest
@testable import InfinittyKit

final class PetTipsTests: XCTestCase {

    func testMarkdownFencedCommandsAreExtracted() {
        let markdown = """
        # Project

        Build it:

        ```bash
        swift build -c release
        $ swift test --filter TerminalTests
        # a comment, not a command
        rm -rf / --no-preserve-root
        ```

        Prose `inline code` is ignored.
        """
        let tips = PetTipScanner.commands(inMarkdown: markdown, source: "AGENTS.md")
        XCTAssertEqual(tips.map(\.command), [
            "swift build -c release",
            "swift test --filter TerminalTests",
        ])
        XCTAssertEqual(tips.first?.source, "AGENTS.md")
    }

    func testPlausibleCommandFilter() {
        XCTAssertTrue(PetTipScanner.isPlausibleCommand("git status"))
        XCTAssertTrue(PetTipScanner.isPlausibleCommand("./scripts/ship-signed.sh 0.2.0"))
        XCTAssertFalse(PetTipScanner.isPlausibleCommand("# heading"))
        XCTAssertFalse(PetTipScanner.isPlausibleCommand("rm -rf /"))
        XCTAssertFalse(PetTipScanner.isPlausibleCommand("some prose sentence here"))
        XCTAssertFalse(PetTipScanner.isPlausibleCommand(
            "git " + String(repeating: "x", count: 90)))
    }

    func testPackageScriptsPreferDevTestBuildAndHonorRunner() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "scripts": ["zeta": "noop", "build": "tsc", "dev": "vite", "test": "vitest"],
        ])
        let npm = PetTipScanner.packageScriptTips(json: json, runner: "npm")
        XCTAssertEqual(npm.map(\.command), ["npm run dev", "npm run test", "npm run build"])
        let pnpm = PetTipScanner.packageScriptTips(json: json, runner: "pnpm")
        XCTAssertEqual(pnpm.first?.command, "pnpm dev")
    }

    func testMakefileTargets() {
        let makefile = """
        .PHONY: all
        all: build
        \tswift build
        test:
        \tswift test
        weird target with spaces:
        """
        let tips = PetTipScanner.makefileTips(makefile)
        XCTAssertEqual(tips.map(\.command), ["make all", "make test"])
    }

    func testScanFindsProjectFilesAndDeduplicates() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-tips-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        # Agents
        ```
        swift test
        ```
        """.write(to: dir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "// swift-tools-version:5.9".write(
            to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let tips = PetTipScanner.scan(directory: dir.path)
        // "swift test" appears in both AGENTS.md and the Package.swift
        // fallback — deduped to the AGENTS.md occurrence.
        XCTAssertEqual(tips.filter { $0.command == "swift test" }.count, 1)
        XCTAssertEqual(tips.first?.source, "AGENTS.md")
    }

    func testRepoRootWalksUpToGit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertEqual(PetTipScanner.repoRoot(for: nested.path), root.path)
        XCTAssertNil(PetTipScanner.repoRoot(for: "/tmp"))
    }

    func testTipSpeechTextShowsCommandAndProvenance() {
        let tip = PetTip(text: "swift test", command: "swift test", source: "AGENTS.md")
        XCTAssertEqual(
            PetSpeechText.tip(tip),
            "swift test\nclick to insert · AGENTS.md")
    }
}
