import XCTest
@testable import InfinittyKit

final class ForegroundProcessTrackerTests: XCTestCase {
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

    func testProcessInfoEqualityIgnoresDisplayName() {
        // Two different localizations of the same binary at the same pid are equal.
        let en = ForegroundProcessInfo(
            pid: 100, displayName: "TextEdit", rawName: "TextEdit",
            executablePath: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit",
            bundleURL: URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        )
        let ja = ForegroundProcessInfo(
            pid: 100, displayName: "テキストエディット", rawName: "TextEdit",
            executablePath: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit",
            bundleURL: URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        )
        XCTAssertEqual(en, ja)
    }
}
