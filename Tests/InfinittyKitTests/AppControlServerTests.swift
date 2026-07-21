import XCTest
@testable import InfinittyKit

final class AppControlServerTests: XCTestCase {

    /// The bridge-facing socket path must match what AppControlServer binds to,
    /// so the in-process AI bridges can hand it to their spawned infinitty-mcp.
    func testOwnSocketPathMatchesPid() {
        XCTAssertEqual(
            AppControlServer.ownSocketPath, "/tmp/infinitty-app-\(getpid()).sock")
    }

    /// The sweep removes sockets owned by dead pids and never touches a live
    /// process's socket (here: our own pid).
    func testSweepRemovesDeadSocketsKeepsLive() throws {
        // A dead pid: pid 999999 is above the default macOS pid_max, so kill(,0)
        // returns ESRCH. Create a stand-in socket file for it and for us.
        let dead = "/tmp/infinitty-999999-1.sock"
        let deadApp = "/tmp/infinitty-app-999999.sock"
        let live = "/tmp/infinitty-\(getpid())-77.sock"
        for p in [dead, deadApp, live] {
            FileManager.default.createFile(atPath: p, contents: Data())
        }
        defer { for p in [dead, deadApp, live] { unlink(p) } }

        AppControlServer.sweepStaleSockets()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dead),
                       "dead-pid pane socket should be swept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: deadApp),
                       "dead-pid app socket should be swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live),
                      "a live process's socket must be left alone")
    }
}
