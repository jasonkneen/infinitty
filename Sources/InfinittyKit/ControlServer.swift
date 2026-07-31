import Darwin
import Foundation

/// Agent-facing control plane: a Unix socket any script or LLM tool can hit
/// with newline-terminated commands. The path is exported to the child shell
/// as $INFINITTY_SOCKET. Runs at utility QoS (efficiency cores) — it must never
/// compete with the render or PTY threads.
///
///   screen              -> visible screen as text
///   history <n>         -> last n lines (scrollback + screen)
///   last-output         -> output of last completed command (OSC 133)
///   last-command        -> last command line as typed (OSC 133)
///   exit-code           -> exit code of last completed command (OSC 133)
///   send <text>         -> type text into the terminal
///   send-line <text>    -> type text followed by return
///   channel-context     -> live room, self, peers, plan, and recent messages
///   channel-register    -> base64url JSON agent identity for this exact pane
///   channel-post        -> base64url JSON message authored by this exact pane
///   channel-unregister  -> release this pane's registered agent identity
///
/// One command per connection; the response is the body, then close.
final class ControlServer {
    let path: String
    private let terminal: Terminal
    private let pty: PTY
    private var listenFD: Int32 = -1
    var reloadHandler: (() -> Void)?
    var activityHandler: (() -> Void)? // agent is driving this pane
    /// `todos [json]` — set (or read, with no argument) the pane's agent todo
    /// list. Wired by the session so hooks can publish via $INFINITTY_SOCKET
    /// without knowing pane ids.
    var todosHandler: ((String) -> String)?
    /// Dynamic, pane-bound Channel operations. The host owns identity and room
    /// lookup so a caller holding one pane socket cannot impersonate another.
    var channelContextHandler: (() -> String)?
    var channelRegisterHandler: ((String, pid_t) -> String)?
    var channelPostHandler: ((String) -> String)?
    var channelUnregisterHandler: ((String, pid_t) -> String)?

    private static var nextID = 0
    private static let idLock = NSLock()

    init(terminal: Terminal, pty: PTY) {
        self.terminal = terminal
        self.pty = pty
        ControlServer.idLock.lock()
        ControlServer.nextID += 1
        let id = ControlServer.nextID
        ControlServer.idLock.unlock()
        self.path = "/tmp/infinitty-\(getpid())-\(id).sock"
    }

    @discardableResult
    func start() -> Bool {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        let ok = withUnsafeMutablePointer(to: &addr.sun_path) { tuple -> Bool in
            tuple.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { dst in
                let bytes = Array(path.utf8)
                guard bytes.count < pathCapacity else { return false }
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
                return true
            }
        }
        guard ok else {
            close(fd)
            return false
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return false
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listenFD = fd

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "infinitty-control"
        thread.qualityOfService = .utility
        thread.start()
        return true
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }

    /// Hard cap on any single response so an agent's context can't be
    /// flooded by one call (~64k tokens worst case is still far too big;
    /// callers should page with `history N`).
    static let maxResponseBytes = 262_144

    /// Cap on concurrent client threads. Each client gets a native thread +
    /// 64 KiB buffer; without a cap, any local process could open thousands
    /// of connections (trickling a byte before each 5s timeout to keep them
    /// alive) and exhaust threads/fds. Excess connections are closed at once.
    private static let maxConcurrentClients = 32
    private let clientSlots = DispatchSemaphore(value: maxConcurrentClients)

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            // CLOEXEC: a shell forked mid-request must not inherit the
            // client fd — a leaked copy keeps the connection open (no EOF)
            // for as long as that shell lives.
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            // Reject (don't queue) when at the concurrency cap, so a flood of
            // stalled clients can't exhaust threads.
            guard clientSlots.wait(timeout: .now()) == .success else {
                close(client)
                continue
            }
            // One thread per client: a stalled connection can't block the
            // control plane. Read/write deadlines bound each thread's life.
            let slots = clientSlots
            let thread = Thread { [weak self] in
                self?.handle(client)
                close(client)
                slots.signal()
            }
            thread.name = "infinitty-control-client"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    private func handle(_ fd: Int32) {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8](repeating: 0, count: 65536)
        var line: [UInt8] = []
        loop: while line.count < 65536 {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { return } // EOF, timeout, or error: drop silently
            for i in 0..<n {
                if buf[i] == 0x0A { break loop }
                line.append(buf[i])
            }
        }
        if line.last == 0x0D { line.removeLast() } // tolerate CRLF clients
        let request = String(decoding: line, as: UTF8.self)
        let response = execute(
            request,
            peerProcessID: Self.peerProcessID(for: fd))
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
    }

    private func execute(
        _ request: String,
        peerProcessID: pid_t
    ) -> String {
        // Split off the command word only; the argument is byte-exact so
        // `send` can transmit leading/trailing whitespace faithfully.
        let parts = request.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let cmd = parts.first.map(String.init) ?? ""
        let arg = parts.count > 1 ? String(parts[1]) : ""

        switch cmd {
        case "screen":
            return terminal.screenText()
        case "history":
            let n = min(max(Int(arg.trimmingCharacters(in: .whitespaces)) ?? 100, 1), Terminal.maxScrollback)
            return terminal.historyText(lines: n)
        case "last-output":
            return terminal.lastCommandOutput()
                ?? "error: no completed command (enable OSC 133 shell integration)"
        case "last-command":
            return terminal.lastCommandLine()
                ?? "error: no command markers (enable OSC 133 shell integration)"
        case "exit-code":
            if let code = terminal.lastExitCode() { return String(code) }
            return "error: no completed command (enable OSC 133 shell integration)"
        case "send":
            activityHandler?()
            pty.write(Array(arg.utf8))
            return "ok"
        case "send-line":
            activityHandler?()
            pty.write(Array(arg.utf8) + [0x0D])
            return "ok"
        case "reload":
            if let handler = reloadHandler {
                handler()
                return "ok"
            }
            return "error: reload not wired"
        case "todos":
            if let handler = todosHandler { return handler(arg) }
            return "error: todos not wired"
        case "channel-context":
            if let handler = channelContextHandler { return handler() }
            return TerminalChannelControl.error(
                "channel_unavailable",
                "Channel context is not wired for this pane.")
        case "channel-register":
            if let handler = channelRegisterHandler {
                return handler(arg, peerProcessID)
            }
            return TerminalChannelControl.error(
                "channel_unavailable",
                "Channel registration is not wired for this pane.")
        case "channel-post":
            if let handler = channelPostHandler { return handler(arg) }
            return TerminalChannelControl.error(
                "channel_unavailable",
                "Channel posting is not wired for this pane.")
        case "channel-unregister":
            if let handler = channelUnregisterHandler {
                return handler(arg, peerProcessID)
            }
            return TerminalChannelControl.error(
                "channel_unavailable",
                "Channel registration is not wired for this pane.")
        case "ping":
            return "pong"
        default:
            return "error: unknown command '\(cmd)' (screen | history N | last-output | last-command | exit-code | send TEXT | send-line TEXT | todos | channel-context | channel-register | channel-post | channel-unregister | ping)"
        }
    }

    private static func peerProcessID(for fd: Int32) -> pid_t {
        var processID = pid_t(0)
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            fd,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &processID,
            &length) == 0
        else { return 0 }
        return processID
    }
}
