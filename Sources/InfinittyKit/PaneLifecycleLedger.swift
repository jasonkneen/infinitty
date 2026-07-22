import Foundation

/// A durable, privacy-safe record of structural pane changes.  This is kept
/// separate from `PaneLog`: drag diagnostics are noisy and asynchronous,
/// while lifecycle records need to survive as close as possible to a crash.
final class PaneLifecycleLedger {
    enum Action: String, Equatable {
        case runStarted = "run+"
        case runEnded = "run-"
        case tabOpened = "tab+"
        case tabClosed = "tab-"
        case added = "+"
        case removed = "-"
        case note = "="
        case error = "!"
    }

    struct Entry: Equatable {
        let sequence: Int
        let uptime: TimeInterval
        let runID: String
        let tabID: String?
        let action: Action
        let paneID: String?
        let reason: String
        let origin: String
        let sourcePaneID: String?
        let axis: String?
        let paneIDs: [String]
        let topology: String

        /// One human-readable line so a live investigation can simply tail
        /// the file and follow the +/- history of a single main tab.
        var line: String {
            var fields = [
                "uptime=\(String(format: "%.3f", uptime))",
                "seq=\(sequence)",
                "run=\(Self.escape(runID))",
            ]
            if let tabID { fields.append("tab=\(Self.escape(tabID))") }
            fields.append(action.rawValue)
            if let paneID { fields.append("pane=\(Self.escape(paneID))") }
            fields.append("reason=\(Self.escape(reason))")
            fields.append("origin=\(Self.escape(origin))")
            if let sourcePaneID { fields.append("source=\(Self.escape(sourcePaneID))") }
            if let axis { fields.append("axis=\(Self.escape(axis))") }
            fields.append("panes=[\(paneIDs.map(Self.escape).joined(separator: ","))]")
            fields.append("tree=\(Self.escape(topology.isEmpty ? "-" : topology))")
            return fields.joined(separator: " ")
        }

        private static func escape(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: " ", with: "_")
        }
    }

    typealias Emit = (Entry) -> Void

    /// The current run's file lives in the conventional user log directory,
    /// rather than `/tmp`, so it remains available after a reboot or cleanup.
    let logURL: URL

    private let emit: Emit
    private let now: () -> TimeInterval
    private let runID: String
    private var nextSequence = 1
    private var panesByTab: [String: [String]] = [:]
    private var closedTabs = Set<String>()

    init(
        emit: Emit? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        logURL: URL? = nil,
        runID: String = PaneLifecycleLedger.makeRunID()
    ) {
        self.now = now
        self.runID = runID
        let resolvedURL = logURL ?? Self.makeLogURL(runID: runID)
        self.logURL = resolvedURL
        let writer = PaneLifecycleLogWriter(url: resolvedURL)
        self.emit = emit ?? { entry in writer.append(entry.line + "\n") }
    }

    func start() {
        recordSystem(.runStarted, reason: "application-start")
    }

    func finish() {
        recordSystem(.runEnded, reason: "application-terminate")
    }

    func openTab(
        _ tabID: String,
        reason: String,
        origin: String,
        topology: String = ""
    ) {
        guard panesByTab[tabID] == nil else {
            recordError(tabID: tabID, paneID: nil, reason: "duplicate-tab-open", origin: origin,
                        topology: topology)
            return
        }
        closedTabs.remove(tabID)
        panesByTab[tabID] = []
        record(.tabOpened, tabID: tabID, paneID: nil, reason: reason, origin: origin,
               sourcePaneID: nil, axis: nil, topology: topology)
    }

    func addPane(
        tabID: String,
        paneID: String,
        reason: String,
        origin: String,
        sourcePaneID: String? = nil,
        axis: String? = nil,
        topology: String = ""
    ) {
        guard var panes = panesByTab[tabID] else {
            recordError(tabID: tabID, paneID: paneID, reason: "pane-added-to-unknown-tab", origin: origin,
                        topology: topology)
            return
        }
        guard !panes.contains(paneID) else {
            recordError(tabID: tabID, paneID: paneID, reason: "duplicate-pane-add", origin: origin,
                        topology: topology)
            return
        }
        panes.append(paneID)
        panesByTab[tabID] = panes
        record(.added, tabID: tabID, paneID: paneID, reason: reason, origin: origin,
               sourcePaneID: sourcePaneID, axis: axis, topology: topology)
    }

    func removePane(
        tabID: String,
        paneID: String,
        reason: String,
        origin: String,
        topology: String = ""
    ) {
        guard var panes = panesByTab[tabID] else {
            // A terminal's EOF callback can follow window teardown. That is
            // expected and must not make the ledger look like two closes.
            guard !closedTabs.contains(tabID) else { return }
            recordError(tabID: tabID, paneID: paneID, reason: "pane-removed-from-unknown-tab",
                        origin: origin, topology: topology)
            return
        }
        guard let index = panes.firstIndex(of: paneID) else {
            recordError(tabID: tabID, paneID: paneID, reason: "unknown-pane-remove", origin: origin,
                        topology: topology)
            return
        }
        panes.remove(at: index)
        panesByTab[tabID] = panes
        record(.removed, tabID: tabID, paneID: paneID, reason: reason, origin: origin,
               sourcePaneID: nil, axis: nil, topology: topology)
    }

    func note(
        tabID: String,
        paneID: String? = nil,
        reason: String,
        origin: String,
        sourcePaneID: String? = nil,
        axis: String? = nil,
        topology: String = ""
    ) {
        guard panesByTab[tabID] != nil else { return }
        record(.note, tabID: tabID, paneID: paneID, reason: reason, origin: origin,
               sourcePaneID: sourcePaneID, axis: axis, topology: topology)
    }

    func failure(
        tabID: String,
        paneID: String? = nil,
        reason: String,
        origin: String,
        topology: String = ""
    ) {
        recordError(tabID: tabID, paneID: paneID, reason: reason, origin: origin,
                    topology: topology)
    }

    /// A forced tab/window close can bypass terminal EOF callbacks. Emit one
    /// `-` per live leaf before `tab-`, then suppress any late duplicate EOF.
    func closeTab(
        _ tabID: String,
        reason: String,
        origin: String,
        topology: String = ""
    ) {
        guard var panes = panesByTab.removeValue(forKey: tabID) else { return }
        while let paneID = panes.first {
            panes.removeFirst()
            record(.removed, tabID: tabID, paneID: paneID, reason: reason, origin: origin,
                   sourcePaneID: nil, axis: nil, topology: topology, paneIDs: panes)
        }
        closedTabs.insert(tabID)
        record(.tabClosed, tabID: tabID, paneID: nil, reason: reason, origin: origin,
               sourcePaneID: nil, axis: nil, topology: topology, paneIDs: [])
    }

    private func recordSystem(_ action: Action, reason: String) {
        record(action, tabID: nil, paneID: nil, reason: reason, origin: "app",
               sourcePaneID: nil, axis: nil, topology: "", paneIDs: [])
    }

    private func recordError(
        tabID: String,
        paneID: String?,
        reason: String,
        origin: String,
        topology: String
    ) {
        record(.error, tabID: tabID, paneID: paneID, reason: reason, origin: origin,
               sourcePaneID: nil, axis: nil, topology: topology)
    }

    private func record(
        _ action: Action,
        tabID: String?,
        paneID: String?,
        reason: String,
        origin: String,
        sourcePaneID: String?,
        axis: String?,
        topology: String,
        paneIDs: [String]? = nil
    ) {
        let entry = Entry(
            sequence: nextSequence,
            uptime: now(),
            runID: runID,
            tabID: tabID,
            action: action,
            paneID: paneID,
            reason: reason,
            origin: origin,
            sourcePaneID: sourcePaneID,
            axis: axis,
            paneIDs: paneIDs ?? tabID.flatMap { panesByTab[$0] } ?? [],
            topology: topology)
        nextSequence += 1
        emit(entry)
    }

    private static func makeRunID() -> String {
        "\(Int(Date().timeIntervalSince1970))-\(ProcessInfo.processInfo.processIdentifier)"
    }

    private static func makeLogURL(runID: String) -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Infinitty", isDirectory: true)
            .appendingPathComponent("pane-ledger", isDirectory: true)
            .appendingPathComponent("pane-ledger-\(runID).log")
    }

}

/// Structural events are rare, so the writer flushes each one synchronously
/// for crash evidence. Keeping one handle open avoids directory work and
/// open/close churn in the AppKit lifecycle callbacks that emit those events.
private final class PaneLifecycleLogWriter {
    private let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?

    init(url: URL) {
        self.url = url
    }

    func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            if handle == nil {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try FileHandle(forWritingTo: url)
                handle?.seekToEndOfFile()
            }
            if let handle {
                handle.write(data)
                try? handle.synchronize()
            }
        } catch {
            // Logging must never turn a pane transition into a fatal error.
            try? handle?.close()
            handle = nil
        }
    }

    deinit { try? handle?.close() }
}
