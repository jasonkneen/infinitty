import XCTest
@testable import InfinittyKit

final class ProcessCwdTests: XCTestCase {

    private func realpath(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }

    func testDirectoryOfSelfMatchesProcessCwd() {
        let expected = realpath(FileManager.default.currentDirectoryPath)
        XCTAssertEqual(
            ForegroundProcessTracker.directory(of: getpid()).map(realpath),
            expected)
    }

    func testDirectoryOfSelfFollowsChdir() {
        let original = FileManager.default.currentDirectoryPath
        let tmp = NSTemporaryDirectory()
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(tmp))
        defer { FileManager.default.changeCurrentDirectoryPath(original) }
        XCTAssertEqual(
            ForegroundProcessTracker.directory(of: getpid()).map(realpath),
            realpath(tmp))
    }

    func testDirectoryOfBogusPidReturnsNil() {
        XCTAssertNil(ForegroundProcessTracker.directory(of: 0))
        XCTAssertNil(ForegroundProcessTracker.directory(of: 1))
        XCTAssertNil(ForegroundProcessTracker.directory(of: 999_999_999))
    }

    func testDirectoryOfChildShell() {
        // A spawned shell in a known directory must report that directory.
        let tmp = NSTemporaryDirectory()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "sleep 5"]
        p.standardInput = Pipe()
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        var env = ProcessInfo.processInfo.environment
        env["PWD"] = tmp
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: tmp)
        try! p.run()
        defer {
            kill(p.processIdentifier, SIGHUP)
            p.waitUntilExit()
        }
        // Give the kernel a beat to publish the vnode info.
        usleep(50_000)
        XCTAssertEqual(
            ForegroundProcessTracker.directory(of: p.processIdentifier).map(realpath),
            realpath(tmp))
    }

    func testFileNodeSortIsDirectoriesFirstThenAlphabetical() {
        func node(_ name: String, _ isDir: Bool) -> CodeFileNode {
            CodeFileNode(url: URL(fileURLWithPath: "/tmp/x/" + name), isDirectory: isDir)
        }
        let sorted = CodeFileNode.sort([
            node("zebra.swift", false),
            node("banana", true),
            node("apple.swift", false),
            node("Apple", true),
        ])
        XCTAssertEqual(
            sorted.map { $0.url.lastPathComponent },
            ["Apple", "banana", "apple.swift", "zebra.swift"])
    }
}
