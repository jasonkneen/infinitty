import XCTest
@testable import InfinittyKit

final class TerminalTests: XCTestCase {
    private func makeTerminal(cols: Int = 40, rows: Int = 10) -> Terminal {
        Terminal(cols: cols, rows: rows)
    }

    private func feed(_ t: Terminal, _ s: String) {
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { t.feed($0.baseAddress!, $0.count) }
    }

    private func feed(_ t: Terminal, bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { t.feed($0.baseAddress!, $0.count) }
    }

    private func cell(_ t: Terminal, _ col: Int, _ row: Int) -> Cell {
        var snap = TermSnapshot()
        t.copySnapshot(into: &snap)
        return snap.cells[row * snap.cols + col]
    }

    // MARK: SGR color forms

    func testSemicolonTruecolor() {
        let t = makeTerminal()
        feed(t, "\u{1B}[38;2;255;105;180mX")
        XCTAssertEqual(cell(t, 0, 0).fg, ColorCode.rgb(255, 105, 180))
    }

    func testColonTruecolorWithColorspace() {
        // The form Codex emits: 38:2::r:g:b (empty colorspace id).
        let t = makeTerminal()
        feed(t, "\u{1B}[38:2::255:105:180mX")
        XCTAssertEqual(cell(t, 0, 0).fg, ColorCode.rgb(255, 105, 180))
    }

    func testColonTruecolorWithoutColorspace() {
        let t = makeTerminal()
        feed(t, "\u{1B}[38:2:10:20:30mX")
        XCTAssertEqual(cell(t, 0, 0).fg, ColorCode.rgb(10, 20, 30))
    }

    func testColonIndexed() {
        let t = makeTerminal()
        feed(t, "\u{1B}[38:5:208mX")
        XCTAssertEqual(cell(t, 0, 0).fg, ColorCode.indexed(208))
    }

    func testMixedSGRWithColonGroup() {
        let t = makeTerminal()
        feed(t, "\u{1B}[1;38:2::1:2:3;4mX")
        let c = cell(t, 0, 0)
        XCTAssertEqual(c.fg, ColorCode.rgb(1, 2, 3))
        XCTAssertNotEqual(c.flags & CellFlags.bold, 0)
        XCTAssertNotEqual(c.flags & CellFlags.underline, 0)
    }

    // MARK: UTF-8 validation

    func testSurrogateRejected() {
        let t = makeTerminal()
        feed(t, bytes: [0xED, 0xA0, 0x80]) // U+D800
        XCTAssertEqual(cell(t, 0, 0).glyph, 0xFFFD)
    }

    func testOverlongRejected() {
        let t = makeTerminal()
        feed(t, bytes: [0xE0, 0x80, 0xAF]) // overlong 3-byte
        XCTAssertEqual(cell(t, 0, 0).glyph, 0xFFFD)
    }

    func testOutOfRangeRejected() {
        let t = makeTerminal()
        feed(t, bytes: [0xF4, 0x90, 0x80, 0x80]) // > U+10FFFF
        XCTAssertEqual(cell(t, 0, 0).glyph, 0xFFFD)
    }

    func testStrayContinuationRejected() {
        let t = makeTerminal()
        feed(t, bytes: [0x80, UInt8(ascii: "A")])
        XCTAssertEqual(cell(t, 0, 0).glyph, 0xFFFD)
        XCTAssertEqual(cell(t, 1, 0).glyph, UInt32(UInt8(ascii: "A")))
    }

    func testFragmentedMultibyte() {
        let t = makeTerminal()
        feed(t, bytes: [0xE7]) // first byte of 界 alone
        feed(t, bytes: [0x95, 0x8C]) // rest in a second batch
        XCTAssertEqual(cell(t, 0, 0).glyph, 0x754C)
    }

    // MARK: wide-cell pair invariants

    func testOverwriteWideContinuationClearsHead() {
        let t = makeTerminal()
        feed(t, "界") // occupies cols 0-1
        feed(t, "\u{1B}[1;2Ha") // write over the continuation half
        let head = cell(t, 0, 0)
        XCTAssertEqual(head.glyph, 0, "orphan wide head must be cleared")
        XCTAssertEqual(cell(t, 1, 0).glyph, UInt32(UInt8(ascii: "a")))
    }

    func testOverwriteWideHeadClearsContinuation() {
        let t = makeTerminal()
        feed(t, "界")
        feed(t, "\u{1B}[1;1Ha")
        XCTAssertEqual(cell(t, 0, 0).glyph, UInt32(UInt8(ascii: "a")))
        let cont = cell(t, 1, 0)
        XCTAssertEqual(cont.flags & CellFlags.wideContinuation, 0, "orphan continuation must be cleared")
    }

    func testEraseHalfOfWidePair() {
        let t = makeTerminal()
        feed(t, "界")
        feed(t, "\u{1B}[1;2H\u{1B}[1X") // ECH the continuation cell
        XCTAssertEqual(cell(t, 0, 0).glyph, 0)
        XCTAssertEqual(cell(t, 0, 0).flags & CellFlags.wide, 0)
    }

    // MARK: OSC 133 output extraction

    func testLastOutputSameRow() {
        let t = makeTerminal()
        feed(t, "\u{1B}]133;C\u{07}foo\u{1B}]133;D;0\u{07}")
        XCTAssertEqual(t.lastCommandOutput(), "foo")
        XCTAssertEqual(t.lastExitCode(), 0)
    }

    func testLastOutputMultiline() {
        let t = makeTerminal()
        feed(t, "\u{1B}]133;C\u{07}one\r\ntwo\r\n\u{1B}]133;D;3\u{07}")
        XCTAssertEqual(t.lastCommandOutput(), "one\ntwo")
        XCTAssertEqual(t.lastExitCode(), 3)
    }

    func testLastOutputEmpty() {
        let t = makeTerminal()
        feed(t, "\u{1B}]133;C\u{07}\u{1B}]133;D;0\u{07}")
        XCTAssertEqual(t.lastCommandOutput(), "")
    }

    func testVisibleHintShowsGhostCompletion() {
        let t = makeTerminal()
        t.setHintProvider { input in
            input == "git st" ? "git status" : nil
        }

        feed(t, "\u{1B}]133;B\u{07}git st")

        XCTAssertEqual(t.currentGhost, "atus")
    }

    func testAsyncHintRefreshUsesCurrentInput() {
        let t = makeTerminal()
        var cached: String?
        t.setHintProvider { _ in cached }
        feed(t, "\u{1B}]133;B\u{07}swift bu")
        XCTAssertEqual(t.currentGhost, "")

        cached = "swift build"
        t.refreshHint()

        XCTAssertEqual(t.currentGhost, "ild")
    }

    // MARK: scroll & alt screen basics

    func testScrollbackAndHistory() {
        let t = makeTerminal(cols: 10, rows: 3)
        for i in 1...5 { feed(t, "line\(i)\r\n") }
        let history = t.historyText(lines: 10)
        XCTAssertTrue(history.contains("line1"))
        XCTAssertTrue(history.contains("line5"))
    }

    func testAltScreenRoundTrip() {
        let t = makeTerminal()
        feed(t, "main\r\n")
        feed(t, "\u{1B}[?1049halt-content\u{1B}[?1049l")
        XCTAssertTrue(t.screenText().contains("main"))
        XCTAssertFalse(t.screenText().contains("alt-content"))
    }

    // MARK: selection

    func testSelectionWordAndText() {
        let t = makeTerminal()
        feed(t, "hello world")
        t.selectionBegin(viewRow: 0, col: 7, mode: .word)
        XCTAssertEqual(t.selectedText(), "world")
    }

    func testSelectionClearedByInput() {
        let t = makeTerminal()
        feed(t, "hello")
        t.selectionBegin(viewRow: 0, col: 0, mode: .word)
        XCTAssertNotNil(t.selectedText())
        t.userDidInput()
        XCTAssertNil(t.selectedText())
    }
}
