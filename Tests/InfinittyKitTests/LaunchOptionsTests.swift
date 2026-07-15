import XCTest

@testable import InfinittyKit

final class LaunchOptionsTests: XCTestCase {
    private var base: String!

    override func setUpWithError() throws {
        base = NSTemporaryDirectory() + "launch-options-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: base + "/repo", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: base + "/repo/file.txt", contents: Data())
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: base)
    }

    func testAbsoluteDirectory() {
        XCTAssertEqual(
            LaunchOptions.workingDirectory(from: [base + "/repo"]),
            base + "/repo")
    }

    func testFileFallsBackToParent() {
        XCTAssertEqual(
            LaunchOptions.workingDirectory(from: [base + "/repo/file.txt"]),
            base + "/repo")
    }

    func testRelativeResolvesAgainstBase() {
        XCTAssertEqual(
            LaunchOptions.workingDirectory(from: ["repo"], relativeTo: base),
            base + "/repo")
    }

    func testTildeExpansion() {
        XCTAssertEqual(
            LaunchOptions.workingDirectory(from: ["~"]),
            (("~" as NSString).expandingTildeInPath as NSString).standardizingPath)
    }

    func testNonexistentPathIsIgnored() {
        XCTAssertNil(LaunchOptions.workingDirectory(from: [base + "/missing"]))
    }

    func testAppKitFlagPairsAreSkipped() {
        XCTAssertEqual(
            LaunchOptions.workingDirectory(
                from: ["-NSDocumentRevisionsDebugMode", "YES", base + "/repo"]),
            base + "/repo")
    }

    func testPlainFlagsAreSkippedWithoutEatingNextArg() {
        XCTAssertEqual(
            LaunchOptions.workingDirectory(from: ["-g", base + "/repo"]),
            base + "/repo")
    }

    func testEmptyArgs() {
        XCTAssertNil(LaunchOptions.workingDirectory(from: []))
    }

    func testTrailingSlashNormalized() {
        XCTAssertEqual(
            LaunchOptions.workingDirectory(from: [base + "/repo/"]),
            base + "/repo")
    }
}
