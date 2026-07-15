import Darwin
import Foundation

/// Argv handling for `infinitty [folder]` — GitHub Desktop's custom shell,
/// scripts, and the npm shim all pass a repo/folder path this way.
public enum LaunchOptions {
    /// First usable path argument resolved to an existing directory: `~` is
    /// expanded, relative paths resolve against `base`, and a file path falls
    /// back to its parent directory. Flag-style arguments are skipped (AppKit
    /// injects "-NSKey value" pairs on debug launches). Returns nil when no
    /// argument names an existing path.
    public static func workingDirectory(
        from args: [String],
        relativeTo base: String = FileManager.default.currentDirectoryPath
    ) -> String? {
        var skipValue = false
        for raw in args {
            if skipValue {
                skipValue = false
                continue
            }
            if raw.hasPrefix("-") {
                skipValue = raw.hasPrefix("-NS") || raw.hasPrefix("-Apple")
                continue
            }
            var path = (raw as NSString).expandingTildeInPath
            if !path.hasPrefix("/") {
                path = (base as NSString).appendingPathComponent(path)
            }
            path = (path as NSString).standardizingPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                continue
            }
            return isDir.boolValue ? path : (path as NSString).deletingLastPathComponent
        }
        return nil
    }
}

/// Client side of the app control socket, for a second `infinitty <folder>`
/// invocation to hand its folder to the live instance instead of launching a
/// duplicate app. Same line protocol as the server: one command per
/// connection, newline-terminated.
public enum AppSocketClient {
    /// Send one request line; returns the first response line trimmed, or
    /// nil when no live instance is listening (missing/stale socket,
    /// timeout). Single-line responses only (pane ids, ok/error) — it stops
    /// reading at the first newline so a shell forked by an older server
    /// holding a leaked copy of the connection can't stall us waiting for
    /// EOF.
    public static func request(_ line: String) -> String? {
        let path = ProcessInfo.processInfo.environment["INFINITTY_APP_SOCKET"]
            ?? AppControlServer.currentLink
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

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
        guard ok else { return nil }

        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard connected == 0 else { return nil }

        let out = Array((line + "\n").utf8)
        var off = 0
        while off < out.count {
            let n = out.withUnsafeBufferPointer {
                write(fd, $0.baseAddress! + off, $0.count - off)
            }
            if n > 0 { off += n } else if errno == EINTR { continue } else { return nil }
        }

        var data: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < ControlServer.maxResponseBytes, !data.contains(0x0A) {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                data.append(contentsOf: buf[0..<n])
            } else if n < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        guard !data.isEmpty else { return nil }
        let firstLine = data.prefix { $0 != 0x0A }
        return String(decoding: firstLine, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
