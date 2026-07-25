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

    /// Asks the shell to print the named variables, single-quoted so expansion
    /// happens there — the echoed command line must not contain the answer the
    /// assertion looks for.
    private func askShell(_ pty: PTY, label: String, variables: [String]) {
        let slots = variables.map { _ in "[%s]" }.joined(separator: " ")
        let arguments = variables.map { "\"$\($0)\"" }.joined(separator: " ")
        let command = "printf '\(label) \(slots)\\n' \(arguments)\n"
        pty.write(Array(command.utf8))
    }

    /// Reads from the pty until `marker` appears, then returns everything read.
    private func readUntil(_ pty: PTY, marker: String, timeout: TimeInterval) -> String {
        let lock = NSLock()
        var buffer = Data()
        let found = expectation(description: "shell printed \(marker)")
        var fulfilled = false

        pty.onData = { bytes, count in
            lock.lock()
            buffer.append(bytes, count: count)
            let seen = String(decoding: buffer, as: UTF8.self).contains(marker)
            lock.unlock()
            if seen, !fulfilled {
                fulfilled = true
                found.fulfill()
            }
        }

        wait(for: [found], timeout: timeout)
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    func testSpawnedShellReceivesPaneIdentity() {
        let pty = PTY()
        XCTAssertTrue(pty.spawn(
            cols: 80, rows: 24,
            socketPath: "/tmp/infinitty-test-pane.sock",
            paneID: 42,
            appSocketPath: "/tmp/infinitty-test-app.sock"))

        askShell(pty, label: "IDENTITY", variables: [
            "INFINITTY_SOCKET", "TITERM_SOCKET",
            "INFINITTY_PANE_ID", "INFINITTY_APP_SOCKET",
        ])

        let expected = "IDENTITY [/tmp/infinitty-test-pane.sock]"
            + " [/tmp/infinitty-test-pane.sock] [42] [/tmp/infinitty-test-app.sock]"
        let output = readUntil(pty, marker: expected, timeout: 15)
        XCTAssertTrue(output.contains(expected), "pty output was:\n\(output)")
    }

    func testAbsentIdentityLeavesVariablesUnset() {
        let pty = PTY()
        XCTAssertTrue(pty.spawn(cols: 80, rows: 24))

        askShell(pty, label: "IDENTITY", variables: [
            "INFINITTY_SOCKET", "INFINITTY_PANE_ID", "INFINITTY_APP_SOCKET",
        ])

        let expected = "IDENTITY [] [] []"
        let output = readUntil(pty, marker: expected, timeout: 15)
        XCTAssertTrue(output.contains(expected), "pty output was:\n\(output)")
    }

    /// The pane id is the handle the app socket's `todos <id> …` family takes,
    /// so it has to arrive as an exact decimal string.
    func testPaneIdIsExportedAsPlainDecimal() {
        let pty = PTY()
        XCTAssertTrue(pty.spawn(cols: 80, rows: 24, paneID: 7))

        askShell(pty, label: "PANE", variables: ["INFINITTY_PANE_ID"])

        let output = readUntil(pty, marker: "PANE [7]", timeout: 15)
        XCTAssertTrue(output.contains("PANE [7]"), "pty output was:\n\(output)")
    }
}
