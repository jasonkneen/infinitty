import Darwin
import Foundation

/// App-level control socket: one per infinitty process, discoverable at the
/// stable path /tmp/infinitty-current.sock (symlink to the newest instance).
/// This is the API other apps use to take control of infinitty as a whole —
/// enumerate panes, create tabs/windows/splits, drive any pane, and
/// subscribe to events. Same line protocol as the pane sockets:
///
///   ping                     -> pong
///   version                  -> infinitty <version>
///   list                     -> JSON array of panes (id, title, focused, …)
///   new-window [dir]         -> pane id of the new window's session
///   new-tab [dir]            -> pane id (tab of the key window); optional
///                               dir = shell starting directory
///   split <id> right|left|down|up -> pane id of the new split
///   focus <id>               -> ok (raises + focuses the pane)
///   close <id>               -> ok (terminates the pane's shell)
///   send <id> <text>         -> ok (type into pane; triggers agent glow)
///   send-line <id> <text>    -> ok (type + return)
///   screen <id>              -> pane's visible screen
///   history <id> <n>         -> last n lines
///   last-output <id>         -> last command's output (OSC 133)
///   last-command <id>        -> last command line (OSC 133)
///   exit-code <id>           -> last exit code (OSC 133)
///   activity <text>          -> show text in the notch live-activity widget
///   toggle-quick-terminal    -> show or hide the persistent quick terminal
///   subscribe                -> connection stays open; JSON events stream in:
///                               pane-opened, pane-closed, title, marker
final class AppControlServer {
    let path: String
    static let currentLink = "/tmp/infinitty-current.sock"

    /// Handles one request line, returns the response body.
    var handler: ((String) -> String)?

    private var listenFD: Int32 = -1
    private var subscribers: [Int32] = []
    private let subscriberLock = NSLock()

    init() {
        path = AppControlServer.ownSocketPath
    }

    /// The app control socket path for the current process. Deterministic from
    /// the pid so the in-process AI bridges can hand it to their spawned
    /// `infinitty-mcp` server (via `INFINITTY_APP_SOCKET`) without needing a
    /// reference to this instance. Must match `init`'s `path`.
    static var ownSocketPath: String { "/tmp/infinitty-app-\(getpid()).sock" }

    /// Remove socket files left behind by infinitty processes that are no
    /// longer running. `stop()` only runs on a clean quit, so a crash,
    /// force-quit, or Xcode "stop" during a dev rebuild strands the pane and
    /// app sockets forever. This is a cheap, pid-keyed sweep — it never
    /// touches a live process's files and needs no cross-instance coordination.
    static func sweepStaleSockets(fileManager: FileManager = .default) {
        let dir = "/tmp"
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else { return }
        let mypid = getpid()
        for name in entries
        where name.hasPrefix("infinitty-") && name.hasSuffix(".sock") {
            let stem = name.dropFirst("infinitty-".count).dropLast(".sock".count)
            let parts = stem.split(separator: "-")
            // infinitty-<pid>-<n>.sock  or  infinitty-app-<pid>.sock
            let pidToken = parts.first == "app" ? parts.dropFirst().first : parts.first
            guard let pidToken, let pid = pid_t(pidToken), pid != mypid else { continue }
            // kill(pid, 0): 0 = alive, ESRCH = gone.
            if kill(pid, 0) != 0, errno == ESRCH {
                unlink("\(dir)/\(name)")
            }
        }
        // Drop a dangling discovery symlink (points at a now-removed socket).
        if let target = readlinkString(currentLink),
           !fileManager.fileExists(atPath: target) {
            unlink(currentLink)
        }
    }

    /// Resolve a symlink to its target path, or nil if not a readable link.
    static func readlinkString(_ link: String) -> String? {
        var buf = [CChar](repeating: 0, count: 1024)
        let n = readlink(link, &buf, buf.count - 1)
        guard n >= 0 else { return nil }
        buf[n] = 0
        return String(cString: buf)
    }

    func start() {
        AppControlServer.sweepStaleSockets()
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let ok = withUnsafeMutablePointer(to: &addr.sun_path) { tuple -> Bool in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                let bytes = Array(path.utf8)
                guard bytes.count < capacity else { return false }
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
                return true
            }
        }
        guard ok else {
            close(fd)
            return
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listenFD = fd

        // Stable discovery path for external apps.
        unlink(AppControlServer.currentLink)
        symlink(path, AppControlServer.currentLink)

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "infinitty-app-control"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
        // Only remove the shared discovery symlink if it still points at us.
        // A newer instance may have repointed it to its own socket during our
        // lifetime; clobbering that would break the live instance's discovery.
        if AppControlServer.readlinkString(AppControlServer.currentLink) == path {
            unlink(AppControlServer.currentLink)
        }
        subscriberLock.lock()
        for fd in subscribers { close(fd) }
        subscribers.removeAll()
        subscriberLock.unlock()
    }

    /// Push a JSON event line to every subscriber (called from main).
    /// Subscriber sockets carry a short SO_SNDTIMEO (set at subscribe time),
    /// so each write returns within milliseconds; slow or dead readers are
    /// pruned here. A stalled subscriber can never park AppKit behind
    /// write(2). Removal and close happen under the lock, so teardown in the
    /// subscribe handler never double-closes a pruned (and possibly reused)
    /// descriptor.
    func broadcast(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let line = Array(data) + [0x0A]
        subscriberLock.lock()
        var dead: [Int32] = []
        for fd in subscribers {
            let n = line.withUnsafeBufferPointer { write(fd, $0.baseAddress!, $0.count) }
            // Short write = corrupt event line for that client: prune it.
            if n != line.count { dead.append(fd) }
        }
        if !dead.isEmpty {
            for fd in dead { close(fd) }
            subscribers.removeAll { dead.contains($0) }
        }
        subscriberLock.unlock()
    }

    /// Cap on concurrent client threads (includes long-lived `subscribe`
    /// streams). Prevents a flood of stalled local connections from
    /// exhausting threads/fds. Excess connections are closed immediately.
    private static let maxConcurrentClients = 48
    private let clientSlots = DispatchSemaphore(value: maxConcurrentClients)

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            // CLOEXEC: new-tab/new-window/split fork shells mid-request; an
            // inherited client fd would hold the connection open (no EOF)
            // until that shell exits.
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            guard clientSlots.wait(timeout: .now()) == .success else {
                close(client)
                continue
            }
            let slots = clientSlots
            let thread = Thread { [weak self] in
                self?.handle(client)
                slots.signal()
            }
            thread.name = "infinitty-app-client"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    private func handle(_ fd: Int32) {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // Also bound the response write: a client that requests a large
        // response then stops reading must not park this thread forever once
        // the kernel send buffer fills. The subscribe branch overrides this
        // with its own short deadline below.
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8](repeating: 0, count: 65536)
        var line: [UInt8] = []
        loop: while line.count < 65536 {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else {
                close(fd)
                return
            }
            for i in 0..<n {
                if buf[i] == 0x0A { break loop }
                line.append(buf[i])
            }
        }
        if line.last == 0x0D { line.removeLast() }
        let request = String(decoding: line, as: UTF8.self)

        if request == "subscribe" {
            // Long-lived: millisecond send deadline so fanout on the main
            // thread stays bounded and a stalled reader gets pruned; no
            // receive deadline (we only write). Hold until client EOF.
            var sndTv = timeval(tv_sec: 0, tv_usec: 10_000)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sndTv, socklen_t(MemoryLayout<timeval>.size))
            var noTv = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &noTv, socklen_t(MemoryLayout<timeval>.size))
            _ = "ok\n".withCString { write(fd, $0, strlen($0)) }
            subscriberLock.lock()
            subscribers.append(fd)
            subscriberLock.unlock()
            var drain = [UInt8](repeating: 0, count: 256)
            while read(fd, &drain, drain.count) > 0 {}
            // Close only if we still own the fd: broadcast()/stop() prune
            // (remove AND close) subscribers under the same lock, so an
            // unconditional close here could hit a reused descriptor.
            subscriberLock.lock()
            if let i = subscribers.firstIndex(of: fd) {
                subscribers.remove(at: i)
                close(fd)
            }
            subscriberLock.unlock()
            return
        }

        let response = handler?(request) ?? "error: not ready"
        var out = Array(response.utf8)
        if out.count > ControlServer.maxResponseBytes {
            let kept = Array(out.suffix(ControlServer.maxResponseBytes))
            out = Array("[truncated: showing last \(ControlServer.maxResponseBytes) bytes]\n".utf8) + kept
        }
        if out.last != 0x0A { out.append(0x0A) }
        out.withUnsafeBufferPointer { p in
            var off = 0
            while off < p.count {
                let n = write(fd, p.baseAddress! + off, p.count - off)
                if n > 0 { off += n } else if errno == EINTR { continue } else { break }
            }
        }
        close(fd)
    }
}
