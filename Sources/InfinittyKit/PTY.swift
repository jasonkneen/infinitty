import CPty
import Darwin
import Foundation

/// Pseudo-terminal plumbing. Reads happen on a dedicated high-QoS thread in
/// 256 KB batches (one wakeup per kernel buffer, not per byte); writes go
/// through a serial queue so a slow child can never block the UI.
final class PTY {
    private let lock = NSLock()
    private var _fd: Int32 = -1
    private(set) var pid: pid_t = -1

    var fd: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return _fd
    }

    var onData: ((UnsafePointer<UInt8>, Int) -> Void)?
    var onEOF: (() -> Void)?

    private let writeQueue = DispatchQueue(label: "infinitty.pty.write", qos: .userInitiated)
    private var readThread: Thread?

    /// Spawn the login shell. Returns false on forkpty failure (process limit,
    /// etc.) instead of crashing the whole app.
    @discardableResult
    func spawn(cols: Int, rows: Int, socketPath: String? = nil, cwd: String? = nil) -> Bool {
        var ws = winsize(
            ws_row: UInt16(rows), ws_col: UInt16(cols),
            ws_xpixel: 0, ws_ypixel: 0
        )
        var master: Int32 = -1
        let child = cpty_spawn_shell(&master, &ws, socketPath, cwd)
        guard child > 0, master >= 0 else {
            FileHandle.standardError.write(
                Data("infinitty: failed to spawn shell (forkpty)\n".utf8))
            return false
        }
        // CLOEXEC: shells spawned later for other panes must not inherit
        // this master fd (forkpty leaves it inheritable).
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        lock.lock()
        _fd = master
        pid = child
        lock.unlock()

        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "infinitty-pty-read"
        thread.qualityOfService = .userInitiated
        readThread = thread
        thread.start()
        return true
    }

    private func readLoop() {
        let bufSize = 1 << 18
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        let currentFD = self.fd
        while currentFD >= 0 {
            let n = read(currentFD, buf, bufSize)
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
        if pid > 0 {
            waitpid(pid, &status, 0)
        }
        // Close the master exactly once, via the write queue so no in-flight
        // write can race the close.
        lock.lock()
        let master = _fd
        _fd = -1
        lock.unlock()

        if master >= 0 {
            writeQueue.async { close(master) }
        }
        onEOF?()
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let targetFD = self.fd
        guard targetFD >= 0 else { return }
        writeQueue.async { [weak self] in
            guard let self, self.fd == targetFD else { return }
            bytes.withUnsafeBufferPointer { p in
                var off = 0
                while off < p.count {
                    let n = Darwin.write(targetFD, p.baseAddress! + off, p.count - off)
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
        let targetFD = self.fd
        guard targetFD >= 0 else { return }
        _ = cpty_set_winsize(targetFD, UInt16(rows), UInt16(cols), UInt16(pixelWidth), UInt16(pixelHeight))
    }
}

