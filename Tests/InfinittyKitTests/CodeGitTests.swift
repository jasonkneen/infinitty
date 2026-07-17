import XCTest
@testable import InfinittyKit

final class CodeGitTests: XCTestCase {

    func testParseStatusExtractsBranchAndChanges() {
        let out = """
        ## main...origin/main [ahead 1]
         M Sources/App.swift
        M  Sources/Staged.swift
        A  Sources/New.swift
        ?? scratch.txt
        R  Old.swift -> Renamed.swift

        """
        let (branch, changes) = CodeGit.parseStatus(out)
        XCTAssertEqual(branch, "main")
        XCTAssertEqual(changes, [
            CodeChange(x: " ", y: "M", path: "Sources/App.swift"),
            CodeChange(x: "M", y: " ", path: "Sources/Staged.swift"),
            CodeChange(x: "A", y: " ", path: "Sources/New.swift"),
            CodeChange(x: "?", y: "?", path: "scratch.txt"),
            CodeChange(x: "R", y: " ", path: "Renamed.swift"),
        ])
    }

    func testParseStatusNoCommitsYet() {
        let (branch, changes) = CodeGit.parseStatus("## No commits yet on main\n?? a.txt\n")
        XCTAssertEqual(branch, "main")
        XCTAssertEqual(changes, [CodeChange(x: "?", y: "?", path: "a.txt")])
    }

    func testParseStatusDetachedHeadHasNoBranch() {
        let (branch, _) = CodeGit.parseStatus("## HEAD (no branch)\n")
        XCTAssertNil(branch)
    }

    func testChangeLabels() {
        XCTAssertEqual(CodeChange(x: "M", y: " ", path: "a").label, "M")
        XCTAssertEqual(CodeChange(x: " ", y: "M", path: "a").label, "M")
        XCTAssertEqual(CodeChange(x: "?", y: "?", path: "a").label, "??")
        XCTAssertEqual(CodeChange(x: " ", y: "D", path: "a").label, "D")
        XCTAssertTrue(CodeChange(x: "M", y: " ", path: "a").isStaged)
        XCTAssertFalse(CodeChange(x: " ", y: "M", path: "a").isStaged)
        XCTAssertTrue(CodeChange(x: "?", y: "?", path: "a").isUntracked)
    }

    /// Live end-to-end: init a repo, commit, modify, stage, add untracked —
    /// status and diff must reflect each state.
    func testLiveRepoStatusAndDiff() throws {
        let dir = NSTemporaryDirectory() + "/infinitty-git-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }

        func git(_ args: String...) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir] + args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try! p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git \(args)")
        }

        git("init", "-q")
        git("config", "user.email", "test@example.com")
        git("config", "user.name", "Test")
        try "one\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        git("add", "a.txt")
        git("commit", "-q", "-m", "init")

        XCTAssertEqual(CodeGit.repoRoot(of: dir)?.standardizedPath, dir.standardizedPath)

        // Modify tracked, stage another, leave one untracked.
        try "two\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        try "staged\n".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)
        git("add", "b.txt")
        try "new\n".write(toFile: dir + "/c.txt", atomically: true, encoding: .utf8)

        let status = CodeGit.status(in: dir)
        XCTAssertNil(status.error)
        let paths = status.changes.map(\.path)
        XCTAssertTrue(paths.contains("a.txt"))
        XCTAssertTrue(paths.contains("b.txt"))
        XCTAssertTrue(paths.contains("c.txt"))

        let modified = status.changes.first { $0.path == "a.txt" }!
        XCTAssertEqual(modified, CodeChange(x: " ", y: "M", path: "a.txt"))
        let diff = CodeGit.diff(in: dir, for: modified)
        XCTAssertTrue(diff.text?.contains("+two") == true)
        XCTAssertTrue(diff.text?.contains("-one") == true)

        let untracked = status.changes.first { $0.path == "c.txt" }!
        XCTAssertTrue(untracked.isUntracked)
        XCTAssertNil(CodeGit.diff(in: dir, for: untracked).text)
    }

    func testRepoRootOutsideRepoIsNil() {
        XCTAssertNil(CodeGit.repoRoot(of: NSTemporaryDirectory()))
    }

    /// Stage/unstage/stageAll move entries between staged and worktree state.
    func testStageUnstageStageAll() throws {
        let dir = try makeLiveRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "two\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: dir + "/c.txt", atomically: true, encoding: .utf8)

        XCTAssertNil(CodeGit.stage(in: dir, path: "a.txt"))
        var status = CodeGit.status(in: dir)
        XCTAssertEqual(status.changes.first { $0.path == "a.txt" },
                       CodeChange(x: "M", y: " ", path: "a.txt"))

        XCTAssertNil(CodeGit.unstage(in: dir, path: "a.txt"))
        status = CodeGit.status(in: dir)
        XCTAssertEqual(status.changes.first { $0.path == "a.txt" },
                       CodeChange(x: " ", y: "M", path: "a.txt"))

        XCTAssertNil(CodeGit.stageAll(in: dir))
        status = CodeGit.status(in: dir)
        XCTAssertEqual(status.changes.first { $0.path == "c.txt" },
                       CodeChange(x: "A", y: " ", path: "c.txt"))
    }

    /// branches lists locals; checkout switches, and fails cleanly on junk.
    func testBranchesAndCheckout() throws {
        let dir = try makeLiveRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        git(in: dir, "branch", "feature")

        let branches = CodeGit.branches(in: dir)
        XCTAssertEqual(branches.count, 2)
        XCTAssertTrue(branches.contains("feature"))

        XCTAssertNil(CodeGit.checkout(in: dir, branch: "feature"))
        XCTAssertEqual(CodeGit.status(in: dir).branch, "feature")

        XCTAssertNotNil(CodeGit.checkout(in: dir, branch: "no-such-branch"))
    }

    /// A stale .git/index.lock surfaces as an error, not a silent no-op.
    func testStageAgainstLockedIndexReturnsError() throws {
        let dir = try makeLiveRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "two\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: dir + "/.git/index.lock", contents: nil))
        let error = CodeGit.stage(in: dir, path: "a.txt")
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("index.lock") == true, error ?? "")
        // The app detects the lock, removes it on confirmation, and retries.
        XCTAssertTrue(CodeViewController.isLockError(error ?? ""))
        XCTAssertFalse(CodeViewController.isLockError("some other failure"))
        XCTAssertTrue(CodeViewController.removeIndexLock(in: dir))
        XCTAssertNil(CodeGit.stage(in: dir, path: "a.txt"))
    }

    /// Commit runs the staged entries through git and reports hook/identity
    /// failures as errors.
    func testCommit() throws {
        let dir = try makeLiveRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "two\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)

        // Nothing staged yet → error.
        XCTAssertNotNil(CodeGit.commit(in: dir, message: "nothing staged"))

        XCTAssertNil(CodeGit.stage(in: dir, path: "a.txt"))
        XCTAssertNil(CodeGit.commit(in: dir, message: "second commit"))
        XCTAssertTrue(CodeGit.status(in: dir).changes.isEmpty)
        XCTAssertTrue(git(in: dir, "log", "--oneline", "-1").contains("second commit"))
    }

    /// A fresh repo in a temp dir with one committed file ("a.txt").
    private func makeLiveRepo() throws -> String {
        let dir = NSTemporaryDirectory() + "/infinitty-git-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        git(in: dir, "init", "-q")
        git(in: dir, "config", "user.email", "test@example.com")
        git(in: dir, "config", "user.name", "Test")
        try "one\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        git(in: dir, "add", "a.txt")
        git(in: dir, "commit", "-q", "-m", "init")
        return dir
    }

    @discardableResult
    private func git(in dir: String, _ args: String...) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try! p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args)")
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private extension String {
    var standardizedPath: String {
        (self as NSString).standardizingPath
    }
}
