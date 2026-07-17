import XCTest
@testable import InfinittyKit

final class CodeSearchTests: XCTestCase {

    func testFilterMatchesCaseInsensitiveSubstring() {
        let paths = [
            "Sources/InfinittyKit/App.swift",
            "Sources/InfinittyKit/CodeView.swift",
            "Tests/InfinittyKitTests/CodeViewTests.swift",
            "README.md",
        ]
        XCTAssertEqual(
            CodeSearch.filter(paths, query: "codeview"),
            ["Sources/InfinittyKit/CodeView.swift",
             "Tests/InfinittyKitTests/CodeViewTests.swift"])
    }

    func testFilterRanksFilenameHitsAbovePathHits() {
        let paths = [
            "Sources/app/deep/nested/Thing.swift", // "app" in directory only
            "Sources/InfinittyKit/App.swift",      // "app" in filename
        ]
        XCTAssertEqual(
            CodeSearch.filter(paths, query: "app"),
            ["Sources/InfinittyKit/App.swift",
             "Sources/app/deep/nested/Thing.swift"])
    }

    func testFilterEmptyQueryReturnsNothing() {
        XCTAssertEqual(CodeSearch.filter(["a.swift"], query: ""), [])
    }

    /// rg must find files in a real directory tree and respect .gitignore.
    func testListFilesSyncUsesRipgrep() throws {
        let dir = NSTemporaryDirectory() + "/infinitty-search-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        try "x".write(toFile: dir + "/top.swift", atomically: true, encoding: .utf8)
        try "x".write(toFile: dir + "/sub/nested.md", atomically: true, encoding: .utf8)
        try "ignored.log\n".write(toFile: dir + "/.gitignore", atomically: true, encoding: .utf8)
        try "x".write(toFile: dir + "/ignored.log", atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: dir) }

        let files = CodeSearch.listFilesSync(root: dir)
        XCTAssertTrue(files.contains("top.swift"), "got \(files)")
        XCTAssertTrue(files.contains("sub/nested.md"), "got \(files)")
        // Present iff rg is driving (its gitignore handling); the FileManager
        // fallback lists everything, so only assert when rg exists.
        if CodeSearch.ripgrepPath() != nil {
            XCTAssertFalse(files.contains("ignored.log"), "got \(files)")
        }
    }
}
