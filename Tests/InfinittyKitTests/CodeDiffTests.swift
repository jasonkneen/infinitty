import XCTest
@testable import InfinittyKit

final class CodeDiffTests: XCTestCase {

    private let sample = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    index 1111111..2222222 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -1,4 +1,4 @@
     line one
    -old line
    +new line
     line three
     line four
    @@ -10,2 +10,3 @@
     ctx
    +added
    """

    func testParseExtractsLineNumbersAndKinds() {
        let lines = CodeDiff.parse(sample)
        // File headers dropped, two hunk headers kept.
        XCTAssertEqual(lines.filter { $0.kind == .hunk }.count, 2)
        XCTAssertEqual(lines[0], DiffLine(
            kind: .hunk, oldLine: nil, newLine: nil, text: "@@ -1,4 +1,4 @@"))
        XCTAssertEqual(lines[1], DiffLine(
            kind: .context, oldLine: 1, newLine: 1, text: "line one"))
        XCTAssertEqual(lines[2], DiffLine(
            kind: .del, oldLine: 2, newLine: nil, text: "old line"))
        XCTAssertEqual(lines[3], DiffLine(
            kind: .add, oldLine: nil, newLine: 2, text: "new line"))
        XCTAssertEqual(lines[4], DiffLine(
            kind: .context, oldLine: 3, newLine: 3, text: "line three"))
        // Second hunk picks up its own numbering.
        let added = lines.last!
        XCTAssertEqual(added, DiffLine(
            kind: .add, oldLine: nil, newLine: 11, text: "added"))
    }

    func testParseKeepsUnstagedSeparatorAsHunkRow() {
        let combined = sample + "\n--- unstaged ---\n" + sample
        let lines = CodeDiff.parse(combined)
        let separators = lines.filter { $0.text == "--- unstaged ---" }
        XCTAssertEqual(separators.count, 1)
        XCTAssertEqual(separators.first?.kind, .hunk)
        // Lines after the separator still parse (second diff's hunks).
        XCTAssertTrue(lines.contains(DiffLine(
            kind: .del, oldLine: 2, newLine: nil, text: "old line")))
    }

    func testParseHunkHeaderDefaultsAndRejects() {
        XCTAssertEqual(CodeDiff.parseHunkHeader("@@ -5 +9,2 @@")?.old, 5)
        XCTAssertEqual(CodeDiff.parseHunkHeader("@@ -5 +9,2 @@")?.new, 9)
        XCTAssertNil(CodeDiff.parseHunkHeader("@@ nonsense @@"))
    }

    func testSplitRowsPairDeletionsWithAdditions() {
        let lines = CodeDiff.parse(sample)
        let rows = CodeDiff.splitRows(from: lines)
        // Row 0: hunk header. Row 1: context on both sides.
        XCTAssertTrue(rows[0].isHunk)
        XCTAssertEqual(rows[1].oldText, "line one")
        XCTAssertEqual(rows[1].newText, "line one")
        // Row 2: the del/add pair aligned on one row.
        XCTAssertEqual(rows[2].oldText, "old line")
        XCTAssertEqual(rows[2].oldKind, .del)
        XCTAssertEqual(rows[2].newText, "new line")
        XCTAssertEqual(rows[2].newKind, .add)
        // Second hunk's lone addition gets a blank old side.
        let last = rows.last!
        XCTAssertEqual(last.oldText, "")
        XCTAssertNil(last.oldKind)
        XCTAssertEqual(last.newText, "added")
        XCTAssertEqual(last.newKind, .add)
    }

    func testSplitRowsPadTheShorterSide() {
        let diff = """
        @@ -1,3 +1,1 @@
        -a
        -b
        -c
        +z
        """
        let rows = CodeDiff.splitRows(from: CodeDiff.parse(diff))
        XCTAssertEqual(rows.count, 4) // hunk + 3 paired rows
        XCTAssertEqual(rows[1].newText, "z")
        XCTAssertEqual(rows[2].newText, "")
        XCTAssertNil(rows[2].newKind)
        XCTAssertEqual(rows[3].oldText, "c")
        XCTAssertEqual(rows[3].newText, "")
    }
}
