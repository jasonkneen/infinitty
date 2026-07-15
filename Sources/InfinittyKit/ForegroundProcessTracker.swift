import AppKit
import Darwin

/// Snapshot of whatever process is running in a PTY pane right now.
public struct ForegroundProcessInfo: Equatable {
    public let pid: pid_t
    /// Localized name shown to the user (e.g. "Safari", "vim").
    public let displayName: String
    /// Basename of the executable for fallback display.
    public let rawName: String
    /// Resolved executable path on disk, if any.
    public let executablePath: String?
    /// App bundle URL if this PID is part of a `.app`, else nil.
    public let bundleURL: URL?

    public func icon() -> NSImage? {
        if let bundle = bundleURL {
            if let appIcon = NSWorkspace.shared.icon(forFile: bundle.path) as NSImage?,
               appIcon.size.width > 0 {
                return appIcon
            }
        }
        if let path = executablePath {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return nil
    }

    /// A neutral tooltip describing the process.
    public var tooltip: String {
        if let path = executablePath { return path }
        return rawName
    }

    public static func == (lhs: ForegroundProcessInfo, rhs: ForegroundProcessInfo) -> Bool {
        lhs.pid == rhs.pid && lhs.executablePath == rhs.executablePath && lhs.bundleURL == rhs.bundleURL
    }
}

/// Polls a PTY's child processes on a background queue and publishes the
/// current foreground process (deepest direct child of the shell) via
/// `NotificationCenter.default`.
public final class ForegroundProcessTracker {
    public static let didChangeNotification = Notification.Name("infinitty.foregroundProcess.didChange")
    public static let infoKey = "info"

    public let shellPid: pid_t
    public private(set) var current: ForegroundProcessInfo? {
        didSet {
            if current != oldValue {
                NotificationCenter.default.post(
                    name: ForegroundProcessTracker.didChangeNotification,
                    object: self,
                    userInfo: [Self.infoKey: current as Any]
                )
            }
        }
    }

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "infinitty.fgprocess", qos: .utility)
    private var pollInterval: DispatchTimeInterval = .seconds(2)
    private var isRunning = false

    public init(shellPid: pid_t) {
        self.shellPid = shellPid
    }

    deinit { stop() }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(150), repeating: pollInterval, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel(); timer = nil
        isRunning = false
        current = nil
    }

    /// Force an immediate poll (e.g. right after a command starts/ends).
    public func poke() {
        queue.async { [weak self] in self?.tick() }
    }

    private func tick() {
        current = Self.probeForeground(of: shellPid)
    }

    // MARK: - probing

    private static func probeForeground(of shellPid: pid_t) -> ForegroundProcessInfo? {
        // 1) find direct children of the shell
        var buf = [pid_t](repeating: 0, count: 256)
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            // proc_listchildpids returns the count of PIDs, not bytes — pass the
            // full buffer's bytes for capacity but ignore the size when decoding.
            proc_listchildpids(shellPid, ptr.baseAddress, Int32(MemoryLayout<pid_t>.stride * ptr.count))
        }
        if n <= 0 {
            // shell at prompt, or transient ETIMEDOUT — report the shell itself
            return makeInfo(pid: shellPid)
        }
        let childCount = Int(n)
        // 2) pick the highest-pid direct child — that's usually the foreground job
        var bestPid: pid_t = 0
        for i in 0..<childCount where buf[i] > 1 {
            // sanity-check the PID is still alive
            if kill(buf[i], 0) == 0 || errno == EPERM {
                if bestPid == 0 || buf[i] > bestPid { bestPid = buf[i] }
            }
        }
        guard bestPid > 0 else { return makeInfo(pid: shellPid) }
        return makeInfo(pid: bestPid)
    }

    private static func makeInfo(pid: pid_t) -> ForegroundProcessInfo? {
        guard pid > 1 else { return nil }

        // NSRunningApplication gives the real localized name + icon for GUI apps.
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) {
            return ForegroundProcessInfo(
                pid: pid,
                displayName: app.localizedName ?? app.bundleIdentifier ?? procShortName(pid: pid),
                rawName: procShortName(pid: pid),
                executablePath: app.executableURL?.path,
                bundleURL: app.bundleURL
            )
        }

        // CLI tools: resolve executable path.
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = pathBuf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            proc_pidpath(pid, ptr.baseAddress, UInt32(ptr.count))
        }
        let path: String? = len > 0 ? String(cString: pathBuf) : nil

        // If the executable path lives inside an .app bundle, derive the bundle URL
        // so we can show the app's icon (e.g. "/Applications/Safari.app/.../Safari" → Safari.app).
        var bundleURL: URL? = nil
        if let p = path {
            bundleURL = appBundleURL(forExecutableAt: p)
        }

        return ForegroundProcessInfo(
            pid: pid,
            displayName: bundleURL?.deletingPathExtension().lastPathComponent ?? procShortName(pid: pid),
            rawName: procShortName(pid: pid),
            executablePath: path,
            bundleURL: bundleURL
        )
    }

    private static func procShortName(pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            proc_name(pid, ptr.baseAddress, UInt32(ptr.count))
        }
        return n > 0 ? String(cString: buf) : ""
    }

    /// Walks up a path looking for the enclosing `.app` bundle, if any.
    private static func appBundleURL(forExecutableAt path: String) -> URL? {
        var url = URL(fileURLWithPath: path)
        var safety = 8
        while safety > 0 {
            let ext = url.pathExtension
            if ext == "app" { return url }
            url.deleteLastPathComponent()
            // if we've stepped above the bundle, stop
            if url.path.isEmpty || url.path == "/" { return nil }
            safety -= 1
        }
        return nil
    }
}
