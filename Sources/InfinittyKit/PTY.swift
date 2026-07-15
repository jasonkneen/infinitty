import CPty
import Darwin
import Foundation

/// Pseudo-terminal plumbing. Reads happen on a dedicated high-QoS thread in
/// 256 KB batches (one wakeup per kernel buffer, not per byte); writes go
/// through a serial queue so a slow child can never block the UI.
final class PTY {
    private(set) var fd: Int32 = -1
    private(set) var pid: pid_t = -1

    var onData: ((UnsafePointer<UInt8>, Int) -> Void)?
    var onEOF: (() -> Void)?

    private let writeQueue = DispatchQueue(label: "infinitty.pty.write", qos: .userInitiated)
    private var readThread: Thread?

    func spawn(cols: Int, rows: Int, socketPath: String? = nil, cwd: String? = nil) {
        var ws = winsize(
            ws_row: UInt16(rows), ws_col: UInt16(cols),
            ws_xpixel: 0, ws_ypixel: 0
        )
        var master: Int32 = -1
        let child = cpty_spawn_shell(&master, &ws, socketPath, cwd)
        guard child > 0, master >= 0 else {
            fatalError("infinitty: failed to spawn shell (forkpty)")
        }
        // CLOEXEC: shells spawned later for other panes must not inherit
        // this master fd (forkpty leaves it inheritable).
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        fd = master
        pid = child

        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "infinitty-pty-read"
        thread.qualityOfService = .userInitiated
        readThread = thread
        thread.start()
    }

    private func readLoop() {
        let bufSize = 1 << 18
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while true {
            let n = read(fd, buf, bufSize)
            if n > 0 {
                onData?(buf, n)
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        // Close the master exactly once, via the write queue so no in-flight
        // write can race the close.
        let master = fd
        fd = -1
        writeQueue.async { close(master) }
        onEOF?()
    }

    func write(_ bytes: [UInt8]) {
        guard fd >= 0, !bytes.isEmpty else { return }
        let fd = self.fd
        writeQueue.async {
            bytes.withUnsafeBufferPointer { p in
                var off = 0
                while off < p.count {
                    let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
                    if n > 0 {
                        off += n
                    } else if errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
        }
    }

    func setSize(cols: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        guard fd >= 0 else { return }
        _ = cpty_set_winsize(fd, UInt16(rows), UInt16(cols), UInt16(pixelWidth), UInt16(pixelHeight))
    }
}
