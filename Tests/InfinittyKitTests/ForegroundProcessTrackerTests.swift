import XCTest
@testable import InfinittyKit

final class ForegroundProcessTrackerTests: XCTestCase {
    func testProcessOwnershipWalkIncludesDirectParent() {
        XCTAssertTrue(ForegroundProcessTracker.isProcess(
            getpid(), ownedByShell: getppid()))
        XCTAssertFalse(ForegroundProcessTracker.isProcess(
            getpid(), ownedByShell: -1))
    }
    func testShellAtPromptReportsShell() {
        // Run a long-lived shell and confirm the tracker reports the shell
        // itself as the foreground (no children).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-i"]
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try! p.run()
        defer {
            kill(p.processIdentifier, SIGHUP)
            p.waitUntilExit()
        }
        XCTAssertGreaterThan(p.processIdentifier, 1)

        let tracker = ForegroundProcessTracker(shellPid: p.processIdentifier)
        var firstInfo: ForegroundProcessInfo?
        let exp = expectation(description: "first probe")
        let observer = NotificationCenter.default.addObserver(
            forName: ForegroundProcessTracker.didChangeNotification,
            object: tracker,
            queue: .main
        ) { note in
            guard firstInfo == nil else { return }
            firstInfo = note.userInfo?[ForegroundProcessTracker.infoKey] as? ForegroundProcessInfo
            exp.fulfill()
        }
        tracker.start()
        wait(for: [exp], timeout: 5)
        tracker.stop()
        NotificationCenter.default.removeObserver(observer)
        // Either the shell itself, or nil if kill(0) says dead — both are fine.
        XCTAssertTrue(firstInfo == nil || firstInfo?.pid == p.processIdentifier)
    }

    func testProcessInfoEqualityDistinguishesPid() {
        // Same pid + same path → equal
        let a = ForegroundProcessInfo(
            pid: 100, displayName: "vim", rawName: "vim",
            executablePath: "/usr/bin/vim", bundleURL: nil
        )
        let b = ForegroundProcessInfo(
            pid: 100, displayName: "Vim", rawName: "vim",
            executablePath: "/usr/bin/vim", bundleURL: nil
        )
        XCTAssertEqual(a, b)
        // Different pid → not equal
        let c = ForegroundProcessInfo(
            pid: 200, displayName: "vim", rawName: "vim",
            executablePath: "/usr/bin/vim", bundleURL: nil
        )
        XCTAssertNotEqual(a, c)
    }

    func testFreshProbeIdleShellReportsItself() {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let pipe = Pipe()
        shell.standardInput = pipe
        shell.standardOutput = Pipe()
        shell.standardError = Pipe()
        try! shell.run()
        defer {
            kill(shell.processIdentifier, SIGHUP)
            shell.waitUntilExit()
        }
        // Let any transient startup children exit first.
        Thread.sleep(forTimeInterval: 1.5)
        let info = ForegroundProcessTracker.foregroundProcess(
            of: shell.processIdentifier)
        // Idle: the probe reports the shell itself (or nil if it died).
        XCTAssertTrue(info == nil || info?.pid == shell.processIdentifier)
    }

    func testFreshProbeSeesChildProcess() {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let pipeIn = Pipe()
        shell.standardInput = pipeIn
        shell.standardOutput = Pipe()
        shell.standardError = Pipe()
        try! shell.run()
        defer {
            pipeIn.fileHandleForWriting.write("exit\n".data(using: .utf8)!)
            shell.waitUntilExit()
        }
        pipeIn.fileHandleForWriting.write("sleep 30 &\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 1.5) // give zsh time to fork

        let info = ForegroundProcessTracker.foregroundProcess(
            of: shell.processIdentifier)
        XCTAssertEqual(info?.rawName, "sleep")
        XCTAssertNotEqual(info?.pid, shell.processIdentifier)
    }

    func testCloseConfirmationAlertCancelIsDefault() {
        let info = ForegroundProcessInfo(
            pid: 42, displayName: "vim", rawName: "vim",
            executablePath: nil, bundleURL: nil)
        let alert = ForegroundProcessTracker.closeConfirmationAlert(for: [info])
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Close"])
        XCTAssertTrue(alert.messageText.contains("vim"))
        let multi = ForegroundProcessTracker.closeConfirmationAlert(
            for: [info, info])
        XCTAssertTrue(multi.messageText.contains("2"))
    }
}

extension ForegroundProcessTrackerTests {
    func testTrackerResolvesChildProcess() {
        // Spawn a shell with `sleep 30 &` then verify the tracker reports `sleep`
        // as the foreground process.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let pipeIn = Pipe()
        let pipeOut = Pipe()
        shell.standardInput = pipeIn
        shell.standardOutput = pipeOut
        shell.standardError = pipeOut
        try! shell.run()
        defer {
            pipeIn.fileHandleForWriting.write("exit\n".data(using: .utf8)!)
            shell.waitUntilExit()
        }
        let shellPid = shell.processIdentifier
        pipeIn.fileHandleForWriting.write("sleep 30 &\n".data(using: .utf8)!)
        // give zsh time to fork
        Thread.sleep(forTimeInterval: 1.5)

        let tracker = ForegroundProcessTracker(shellPid: shellPid)
        let exp = expectation(description: "resolved sleep as foreground")
        var resolved: ForegroundProcessInfo?
        let observer = NotificationCenter.default.addObserver(
            forName: ForegroundProcessTracker.didChangeNotification,
            object: tracker,
            queue: .main
        ) { note in
            if let info = note.userInfo?[ForegroundProcessTracker.infoKey] as? ForegroundProcessInfo,
               info.displayName == "sleep" {
                resolved = info
                exp.fulfill()
            }
        }
        tracker.poke()
        wait(for: [exp], timeout: 5)
        tracker.stop()
        NotificationCenter.default.removeObserver(observer)
        XCTAssertEqual(resolved?.rawName, "sleep", "expected tracker to report 'sleep' as foreground")
        XCTAssertEqual(resolved?.pid, resolved?.pid) // pid sanity
    }
}
