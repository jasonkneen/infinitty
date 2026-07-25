import XCTest
@testable import InfinittyKit

/// The spawned shell is where every agent, script, and SSH client starts, so
/// what infinitty exports into it is a contract. Spawns a real pty and asks
/// the shell what it got.
final class PTYEnvironmentTests: XCTestCase {

    private var previousShell: String?

    override func setUpWithError() throws {
        previousShell = ProcessInfo.processInfo.environment["SHELL"]
        // A login `zsh` would source the developer's dotfiles; `sh` keeps the
        // spawned environment attributable to cpty_spawn_shell alone.
        setenv("SHELL", "/bin/sh", 1)
    }

    override func tearDownWithError() throws {
        if let previousShell {
            setenv("SHELL", previousShell, 1)
        } else {
            unsetenv("SHELL")
        }
    }

    /// Collects pty output until `marker` appears.
    ///
    /// Armed before the shell is spawned, never after: the read thread is live
    /// from `spawn` onward and `PTY.write` dispatches asynchronously, so a
    /// callback installed later can miss a fast reply entirely — `onData` is
    /// still nil when `readLoop` fires, the marker is dropped, and the test
    /// waits out its full timeout before failing.
    private final class Reader {
        let satisfied: XCTestExpectation
        private let lock = NSLock()
        private var buffer = Data()
        private var fulfilled = false

        init(pty: PTY, marker: String, expectation: XCTestExpectation) {
            satisfied = expectation
            pty.onData = { [self] bytes, count in
                lock.lock()
                buffer.append(bytes, count: count)
                let seen = String(decoding: buffer, as: UTF8.self).contains(marker)
                let alreadyFulfilled = fulfilled
                if seen { fulfilled = true }
                lock.unlock()
                if seen, !alreadyFulfilled { satisfied.fulfill() }
            }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    private func reader(_ pty: PTY, waitingFor marker: String) -> Reader {
        Reader(pty: pty, marker: marker, expectation: expectation(description: marker))
    }

    /// Asks the shell to print the named variables, single-quoted so expansion
    /// happens there — the echoed command line must not contain the answer the
    /// assertion looks for.
    private func askShell(_ pty: PTY, label: String, variables: [String]) {
        let slots = variables.map { _ in "[%s]" }.joined(separator: " ")
        let arguments = variables.map { "\"$\($0)\"" }.joined(separator: " ")
        pty.write(Array("printf '\(label) \(slots)\\n' \(arguments)\n".utf8))
    }

    /// Lets the shell exit so its process and the pty read thread go away with
    /// the test, rather than lingering for the lifetime of the test runner.
    private func endShell(_ pty: PTY) {
        pty.write(Array("exit\n".utf8))
    }

    func testSpawnedShellReceivesPaneIdentity() {
        let pty = PTY()
        let expected = "IDENTITY [/tmp/infinitty-test-pane.sock]"
            + " [/tmp/infinitty-test-pane.sock] [42] [/tmp/infinitty-test-app.sock]"
        let output = reader(pty, waitingFor: expected)

        XCTAssertTrue(pty.spawn(
            cols: 80, rows: 24,
            socketPath: "/tmp/infinitty-test-pane.sock",
            paneID: 42,
            appSocketPath: "/tmp/infinitty-test-app.sock"))
        defer { endShell(pty) }

        askShell(pty, label: "IDENTITY", variables: [
            "INFINITTY_SOCKET", "TITERM_SOCKET",
            "INFINITTY_PANE_ID", "INFINITTY_APP_SOCKET",
        ])

        wait(for: [output.satisfied], timeout: 15)
        XCTAssertTrue(output.text.contains(expected), "pty output was:\n\(output.text)")
    }

    func testAbsentIdentityLeavesVariablesUnset() {
        let pty = PTY()
        let expected = "IDENTITY [] [] []"
        let output = reader(pty, waitingFor: expected)

        XCTAssertTrue(pty.spawn(cols: 80, rows: 24))
        defer { endShell(pty) }

        askShell(pty, label: "IDENTITY", variables: [
            "INFINITTY_SOCKET", "INFINITTY_PANE_ID", "INFINITTY_APP_SOCKET",
        ])

        wait(for: [output.satisfied], timeout: 15)
        XCTAssertTrue(output.text.contains(expected), "pty output was:\n\(output.text)")
    }

    /// The pane id is the handle the app socket's `todos <id> …` family takes,
    /// so it has to arrive as an exact decimal string.
    func testPaneIdIsExportedAsPlainDecimal() {
        let pty = PTY()
        let output = reader(pty, waitingFor: "PANE [7]")

        XCTAssertTrue(pty.spawn(cols: 80, rows: 24, paneID: 7))
        defer { endShell(pty) }

        askShell(pty, label: "PANE", variables: ["INFINITTY_PANE_ID"])

        wait(for: [output.satisfied], timeout: 15)
        XCTAssertTrue(output.text.contains("PANE [7]"), "pty output was:\n\(output.text)")
    }
}
