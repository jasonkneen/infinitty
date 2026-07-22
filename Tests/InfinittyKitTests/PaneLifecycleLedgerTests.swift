import XCTest

@testable import InfinittyKit

final class PaneLifecycleLedgerTests: XCTestCase {
    func testRecordsAddsAndRemovalsAgainstOneMainTab() {
        var entries: [PaneLifecycleLedger.Entry] = []
        let ledger = PaneLifecycleLedger(emit: { entries.append($0) }, now: { 12.5 })

        ledger.openTab("tab-1", reason: "new-window", origin: "launch")
        ledger.addPane(
            tabID: "tab-1", paneID: "terminal:41", reason: "initial-pane", origin: "launch")
        ledger.addPane(
            tabID: "tab-1", paneID: "chat", reason: "split-right", origin: "pane-header",
            sourcePaneID: "terminal:41", axis: "vertical")
        ledger.removePane(
            tabID: "tab-1", paneID: "terminal:41", reason: "shell-exit", origin: "pty")

        XCTAssertEqual(entries.map(\.action), [.tabOpened, .added, .added, .removed])
        XCTAssertEqual(entries.map(\.paneIDs), [
            [],
            ["terminal:41"],
            ["terminal:41", "chat"],
            ["chat"],
        ])
        XCTAssertEqual(entries[2].sourcePaneID, "terminal:41")
        XCTAssertEqual(entries[2].axis, "vertical")
        XCTAssertTrue(entries[2].line.contains("tab=tab-1 + pane=chat"))
    }

    func testClosingOneTabRemovesItsLeavesAndIgnoresLateCallbacks() {
        var entries: [PaneLifecycleLedger.Entry] = []
        let ledger = PaneLifecycleLedger(emit: { entries.append($0) }, now: { 4.0 })

        ledger.openTab("tab-a", reason: "new-window", origin: "menu")
        ledger.addPane(tabID: "tab-a", paneID: "terminal:1", reason: "initial-pane", origin: "menu")
        ledger.addPane(tabID: "tab-a", paneID: "files", reason: "utility-open", origin: "sidebar")
        ledger.closeTab("tab-a", reason: "window-closed", origin: "window-close")
        ledger.removePane(
            tabID: "tab-a", paneID: "terminal:1", reason: "terminal-exit", origin: "pty-eof")
        ledger.closeTab("tab-a", reason: "window-closed", origin: "window-close")
        ledger.finish()

        XCTAssertEqual(entries.map(\.action), [
            .tabOpened, .added, .added, .removed, .removed, .tabClosed, .runEnded,
        ])
        XCTAssertEqual(entries.map(\.paneIDs), [
            [],
            ["terminal:1"],
            ["terminal:1", "files"],
            ["files"],
            [],
            [],
            [],
        ])
    }

    func testDefaultWriterSynchronouslyAppendsReadableLedgerLine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-ledger-tests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("ledger.log")
        defer { try? FileManager.default.removeItem(at: directory) }

        let ledger = PaneLifecycleLedger(
            now: { 7.25 }, logURL: url, runID: "test-run")
        ledger.openTab("tab-7", reason: "new-window", origin: "test")
        ledger.addPane(
            tabID: "tab-7", paneID: "terminal:9", reason: "initial-pane", origin: "test")

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("seq=1 run=test-run tab=tab-7 tab+"))
        XCTAssertTrue(contents.contains("seq=2 run=test-run tab=tab-7 + pane=terminal:9"))
    }
}
