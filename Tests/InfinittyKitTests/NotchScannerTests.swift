import XCTest
@testable import InfinittyKit

final class NotchScannerTests: XCTestCase {
    private var home: URL!
    private var projectDir: URL!

    override func setUpWithError() throws {
        // Canonicalize the temp home (private/var vs var): directory
        // enumeration hands the scanner canonical paths, and the live-path
        // set must match them exactly.
        home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("notch-scanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let canonical = try XCTUnwrap(
            home.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        home = URL(fileURLWithPath: canonical, isDirectory: true)
        projectDir = home.appendingPathComponent(".claude/projects/-tmp-proj")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func writeTranscript(_ name: String, mtime: Date) throws -> URL {
        let f = projectDir.appendingPathComponent(name)
        let line = #"{"type":"user","sessionId":"abc","cwd":"/tmp/proj","message":{"role":"user","content":"hello world"},"timestamp":"2026-07-24T08:00:00.000Z"}"#
        try (line + "\n").write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: f.path)
        return f
    }

    func testFreshTranscriptIsScanned() throws {
        try writeTranscript("fresh.jsonl", mtime: Date())
        let sessions = SessionScanner(home: home).scan(live: [], claudeCwdCounts: [:])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(try XCTUnwrap(sessions.first).kind, .claude)
    }

    func testOldTranscriptIsNeverRead() throws {
        // A FIFO blocks any reader until a writer appears. If the scanner
        // opens stale transcripts at all, scan() stalls here and the wait
        // times out — that read-everything behavior is what grew the app
        // to 47GB against a 3,852-file ~/.claude/projects corpus.
        try writeTranscript("fresh.jsonl", mtime: Date())
        let fifo = projectDir.appendingPathComponent("old.jsonl")
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7 * 3600)],
            ofItemAtPath: fifo.path)

        let done = expectation(description: "scan returns without opening old transcripts")
        DispatchQueue.global().async { [home] in
            let sessions = SessionScanner(home: home!).scan(live: [], claudeCwdCounts: [:])
            XCTAssertEqual(sessions.count, 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testOldButLiveTranscriptIsStillIncluded() throws {
        let f = try writeTranscript("live-old.jsonl", mtime: Date(timeIntervalSinceNow: -8 * 3600))
        let sessions = SessionScanner(home: home).scan(live: [f.path], claudeCwdCounts: [:])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(try XCTUnwrap(sessions.first).isLive)
    }
}
