import Darwin
import Foundation

public enum HeadlessAppHostError: LocalizedError {
    case alreadyRunning
    case invalidWorkingDirectory(String)
    case invalidInstanceID(String)
    case controlSocketUnavailable(String)
    case terminalLaunchFailed

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "The headless Infinitty host is already running."
        case .invalidWorkingDirectory(let path):
            return "The headless working directory does not exist: \(path)"
        case .invalidInstanceID(let value):
            return "The headless instance id is not path-safe: \(value)"
        case .controlSocketUnavailable(let path):
            return "The headless control socket could not be opened at \(path)."
        case .terminalLaunchFailed:
            return "The headless terminal shell could not be launched."
        }
    }
}

/// Renderer-free Infinitty runtime.
///
/// This host deliberately owns only terminal engines, PTYs, control sockets,
/// Channel state, instance discovery, and lifecycle events. It never creates
/// `NSApplication`, `NSWindow`, a Metal layer, a renderer, or a display link.
/// A visual app instance can run alongside it and address it through the same
/// app-control/MCP protocol.
public final class HeadlessAppHost: @unchecked Sendable {
    public let instanceID: String
    public let socketPath: String

    private let appControl: AppControlServer
    private let registry: AppInstanceRegistry
    private let collaborationCoordinator: CollaborationCoordinatorClient
    private let stateLock = NSLock()

    private var sessions: [Int: HeadlessTerminalSession] = [:]
    private var nextSessionID = 1
    private var focusedSessionID: Int?
    private var started = false

    public init(
        instanceID: String = UUID().uuidString.lowercased(),
        socketPath: String? = nil,
        applicationSupportDirectory: URL? = nil,
        publishesCurrentLink: Bool = true
    ) throws {
        let allowedIDCharacters = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !instanceID.isEmpty,
              instanceID.utf8.count <= 128,
              instanceID.unicodeScalars.allSatisfy(
                allowedIDCharacters.contains)
        else {
            throw HeadlessAppHostError.invalidInstanceID(instanceID)
        }
        self.instanceID = instanceID
        let resolvedSocketPath = socketPath ?? AppControlServer.ownSocketPath
        self.socketPath = resolvedSocketPath

        let server = AppControlServer(
            path: resolvedSocketPath,
            publishesCurrentLink: publishesCurrentLink)
        appControl = server
        registry = AppInstanceRegistry(
            instanceID: instanceID,
            socketPath: resolvedSocketPath,
            mode: "headless",
            baseDirectory: applicationSupportDirectory)

        collaborationCoordinator = CollaborationCoordinatorClient(
            applicationSupportDirectory: applicationSupportDirectory)
    }

    deinit {
        stop()
    }

    /// Starts the control plane and, by default, one shell-backed terminal.
    /// `launchInitialTerminal: false` is useful for a coordinator-only host and
    /// deterministic lifecycle tests.
    public func start(
        initialWorkingDirectory: String? = nil,
        launchInitialTerminal: Bool = true
    ) throws {
        if let initialWorkingDirectory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                    atPath: initialWorkingDirectory,
                    isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw HeadlessAppHostError.invalidWorkingDirectory(
                    initialWorkingDirectory)
            }
        }

        stateLock.lock()
        guard !started else {
            stateLock.unlock()
            throw HeadlessAppHostError.alreadyRunning
        }
        started = true
        stateLock.unlock()

        signal(SIGPIPE, SIG_IGN)
        appControl.handler = { [weak self] request in
            self?.handle(request) ?? "error: shutting down"
        }
        guard appControl.start() else {
            stateLock.lock()
            started = false
            stateLock.unlock()
            throw HeadlessAppHostError.controlSocketUnavailable(socketPath)
        }

        do {
            try registry.register()
            if launchInitialTerminal {
                guard createSession(cwd: initialWorkingDirectory) != nil else {
                    throw HeadlessAppHostError.terminalLaunchFailed
                }
            }
        } catch {
            stop()
            throw error
        }
    }

    /// Blocks without starting an AppKit run loop and stops cleanly on
    /// SIGINT/SIGTERM.
    public func waitForTerminationSignal() {
        let done = DispatchSemaphore(value: 0)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(
            signal: SIGINT, queue: .global(qos: .utility))
        let terminate = DispatchSource.makeSignalSource(
            signal: SIGTERM, queue: .global(qos: .utility))
        interrupt.setEventHandler { done.signal() }
        terminate.setEventHandler { done.signal() }
        interrupt.resume()
        terminate.resume()
        done.wait()
        interrupt.cancel()
        terminate.cancel()
        stop()
    }

    public func stop() {
        stateLock.lock()
        guard started else {
            stateLock.unlock()
            return
        }
        started = false
        let liveSessions = Array(sessions.values)
        sessions.removeAll()
        focusedSessionID = nil
        stateLock.unlock()

        appControl.handler = nil
        appControl.stop()
        registry.unregister()
        for session in liveSessions {
            leaveChannel(for: session)
            session.shutdown(terminateShell: true)
        }
    }

    private func createSession(cwd: String?) -> Int? {
        stateLock.lock()
        guard started else {
            stateLock.unlock()
            return nil
        }
        let id = nextSessionID
        nextSessionID += 1
        stateLock.unlock()

        let session = HeadlessTerminalSession(id: id, workingDirectory: cwd)
        session.onTitleChanged = { [weak self] session, title in
            self?.appControl.broadcast([
                "event": "title",
                "pane": session.id,
                "title": title,
                "headless": true,
            ])
        }
        session.onMarker = { [weak self] session, kind, exitCode in
            self?.appControl.broadcast([
                "event": "marker",
                "pane": session.id,
                "kind": String(UnicodeScalar(kind)),
                "exit": exitCode,
                "headless": true,
            ])
        }
        session.onExited = { [weak self] session in
            self?.removeSession(session)
        }

        stateLock.lock()
        guard started else {
            stateLock.unlock()
            session.shutdown(terminateShell: false)
            return nil
        }
        sessions[id] = session
        if focusedSessionID == nil { focusedSessionID = id }
        stateLock.unlock()

        guard session.launch() else {
            stateLock.lock()
            sessions[id] = nil
            if focusedSessionID == id {
                focusedSessionID = sessions.keys.sorted().first
            }
            stateLock.unlock()
            session.shutdown(terminateShell: false)
            return nil
        }
        appControl.broadcast([
            "event": "pane-opened",
            "pane": id,
            "headless": true,
        ])
        return id
    }

    private func removeSession(_ session: HeadlessTerminalSession) {
        stateLock.lock()
        guard sessions[session.id] === session else {
            stateLock.unlock()
            return
        }
        sessions[session.id] = nil
        if focusedSessionID == session.id {
            focusedSessionID = sessions.keys.sorted().first
        }
        stateLock.unlock()
        leaveChannel(for: session)
        session.shutdown(terminateShell: false)
        appControl.broadcast([
            "event": "pane-closed",
            "pane": session.id,
            "headless": true,
        ])
    }

    private func leaveChannel(for session: HeadlessTerminalSession) {
        let endpointID = channelEndpoint(for: session).id
        if collaborationCoordinator.snapshot()?.channels.contains(where: {
            $0.endpoints.contains(where: { $0.id == endpointID })
        }) == true {
            let request = CollaborationControlRequest(
                op: .leave,
                actor: CollaborationActor(
                    id: "system:\(instanceID)",
                    kind: .system,
                    displayName: "Infinitty headless host"),
                idempotencyKey:
                    "headless-leave:\(endpointID):\(UUID().uuidString)",
                endpointID: endpointID)
            if let encoded = CollaborationControlCodec.encode(request) {
                let result = collaborationCoordinator.execute(encoded)
                if result.snapshot == nil {
                    appControl.broadcast([
                        "event": "channel-error",
                        "endpointId": endpointID,
                        "message": result.response,
                    ])
                }
            } else {
                appControl.broadcast([
                    "event": "channel-error",
                    "endpointId": endpointID,
                    "message": "Could not encode Channel leave.",
                ])
            }
        }
    }

    private func session(id: Int) -> HeadlessTerminalSession? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sessions[id]
    }

    private func allSessions() -> (
        sessions: [HeadlessTerminalSession],
        focusedID: Int?
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (
            sessions.values.sorted { $0.id < $1.id },
            focusedSessionID)
    }

    private func paneAndText(
        _ argument: String
    ) -> (HeadlessTerminalSession, String)? {
        let parts = argument.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: false)
        guard let first = parts.first,
              let id = Int(first),
              let session = session(id: id)
        else { return nil }
        return (
            session,
            parts.count > 1 ? String(parts[1]) : "")
    }

    private func workingDirectory(from argument: String) -> (
        path: String?,
        error: String?
    ) {
        let trimmed = argument.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (nil, nil) }
        guard let directory = LaunchOptions.workingDirectory(from: [trimmed])
        else {
            return (nil, "error: no such directory: \(trimmed)")
        }
        return (directory, nil)
    }

    private func handle(_ request: String) -> String {
        let parts = request.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: false)
        let command = parts.first.map(String.init) ?? ""
        let argument = parts.count > 1 ? String(parts[1]) : ""

        switch command {
        case "ping":
            return "pong"
        case "version":
            return "infinitty 0.1 headless"
        case "instance":
            return jsonString([
                "id": instanceID,
                "pid": Int(getpid()),
                "socket": socketPath,
                "protocolVersion": 1,
                "mode": "headless",
                "capabilities": [
                    "terminal",
                    "terminal.run",
                    "channel",
                    "events",
                ],
            ])
        case "list":
            let values = allSessions()
            let panes: [[String: Any]] = values.sessions.map { session in
                let endpoint = channelEndpoint(for: session)
                return [
                    "id": session.id,
                    "title": session.title,
                    "windowTitle": "",
                    "focused": values.focusedID == session.id,
                    "cols": session.terminal.cols,
                    "rows": session.terminal.rows,
                    "socket": session.control.path,
                    "headless": true,
                    "channelEndpoint": [
                        "id": endpoint.id,
                        "kind": endpoint.kind.rawValue,
                        "label": endpoint.label,
                        "instanceID": endpoint.instanceID ?? "",
                    ],
                ]
            }
            return jsonString(panes)
        case "channel":
            return collaborationCoordinator.execute(argument).response
        case "channel-project":
            // Headless panes have no AppKit projection; accepting the
            // coordinator notification confirms this live instance is aware
            // of the new authoritative revision.
            return CollaborationCoordinatorClient.projectedSnapshot(
                from: argument) == nil
                ? "error: invalid Channel projection"
                : "ok"
        case "new-window", "new-tab":
            let directory = workingDirectory(from: argument)
            if let error = directory.error { return error }
            return createSession(cwd: directory.path).map(String.init)
                ?? "error: could not create headless terminal"
        case "split":
            guard let (target, directionText) = paneAndText(argument) else {
                return "error: split <id> right|left|down|up"
            }
            let direction = directionText.trimmingCharacters(
                in: .whitespaces).lowercased()
            guard ["right", "left", "down", "up"].contains(direction) else {
                return "error: split <id> right|left|down|up"
            }
            return createSession(cwd: target.workingDirectory).map(String.init)
                ?? "error: split failed"
        case "focus":
            guard let (target, _) = paneAndText(argument) else {
                return "error: focus <id>"
            }
            stateLock.lock()
            focusedSessionID = target.id
            stateLock.unlock()
            appControl.broadcast([
                "event": "focus",
                "pane": target.id,
                "headless": true,
            ])
            return "ok"
        case "close":
            guard let (target, _) = paneAndText(argument) else {
                return "error: close <id>"
            }
            target.terminate()
            return "ok"
        case "send", "send-line":
            guard let (target, text) = paneAndText(argument) else {
                return "error: \(command) <id> <text>"
            }
            target.send(text, newline: command == "send-line")
            return "ok"
        case "screen":
            guard let (target, _) = paneAndText(argument) else {
                return "error: screen <id>"
            }
            return target.terminal.screenText()
        case "history":
            guard let (target, countText) = paneAndText(argument) else {
                return "error: history <id> <n>"
            }
            let count = min(
                max(Int(countText.trimmingCharacters(in: .whitespaces)) ?? 100, 1),
                Terminal.maxScrollback)
            return target.terminal.historyText(lines: count)
        case "last-output":
            guard let (target, _) = paneAndText(argument) else {
                return "error: last-output <id>"
            }
            return target.terminal.lastCommandOutput()
                ?? "error: no completed command (enable OSC 133)"
        case "last-command":
            guard let (target, _) = paneAndText(argument) else {
                return "error: last-command <id>"
            }
            return target.terminal.lastCommandLine()
                ?? "error: no command markers (enable OSC 133)"
        case "exit-code":
            guard let (target, _) = paneAndText(argument) else {
                return "error: exit-code <id>"
            }
            return target.terminal.lastExitCode().map(String.init)
                ?? "error: no completed command (enable OSC 133)"
        case "run":
            guard let (target, text) = paneAndText(argument), !text.isEmpty else {
                return "error: run <id> <command>"
            }
            switch target.run(text, timeout: 120) {
            case .success(let receipt):
                return jsonString([
                    "exitCode": receipt.exitCode,
                    "output": receipt.output,
                ])
            case .failure(let error):
                return "error: \(error.message)"
            }
        case "todos":
            guard let (target, json) = paneAndText(argument) else {
                return "error: todos <id> [json-array]"
            }
            let trimmed = json.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return target.encodedTodos() }
            guard let todos = PaneTodoParser.parse(trimmed) else {
                return "error: todos expects a JSON array"
            }
            target.setTodos(todos)
            appControl.broadcast([
                "event": "todos",
                "pane": target.id,
                "total": todos.count,
                "done": todos.filter(\.done).count,
                "headless": true,
            ])
            return "ok"
        case "browser", "surface", "surface-close", "activity",
             "toggle-quick-terminal", "toggle-sidebar", "sidebar",
             "sidebar-tab", "chat-model", "chat-effort":
            return "error: \(command) is unavailable in the headless host"
        default:
            return "error: unknown command '\(command)' (ping | version | instance | "
                + "list | new-window | new-tab | split | focus | close | send | "
                + "send-line | screen | history | last-output | last-command | "
                + "exit-code | run | todos | channel | subscribe)"
        }
    }

    private func channelEndpoint(
        for session: HeadlessTerminalSession
    ) -> CollaborationEndpoint {
        CollaborationEndpoint(
            id: "\(instanceID)/terminal:\(session.id)",
            kind: .terminal,
            label: session.title,
            instanceID: instanceID)
    }

    private func jsonString(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private final class HeadlessTerminalSession: @unchecked Sendable {
    struct RunReceipt {
        let exitCode: Int
        let output: String
    }

    enum RunError: Error {
        case failed(String)

        var message: String {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    let id: Int
    let terminal: Terminal
    let pty: PTY
    let control: ControlServer
    let workingDirectory: String?

    var onExited: ((HeadlessTerminalSession) -> Void)?
    var onTitleChanged: ((HeadlessTerminalSession, String) -> Void)?
    var onMarker: ((HeadlessTerminalSession, UInt8, Int) -> Void)?

    private let stateLock = NSLock()
    private let runLock = NSLock()
    private let promptCondition = NSCondition()
    private let runQueue = RunCommandQueue()
    private var storedTitle = "infinitty"
    private var todos: [PaneTodo] = []
    private var launched = false
    private var stopped = false
    private var promptReady = false
    private var promptStopped = false

    var title: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedTitle
    }

    init(id: Int, workingDirectory: String?) {
        self.id = id
        self.workingDirectory = workingDirectory
        terminal = Terminal(cols: 120, rows: 32)
        pty = PTY()
        control = ControlServer(terminal: terminal, pty: pty)

        pty.onData = { [weak terminal] buffer, count in
            terminal?.feed(buffer, count)
        }
        pty.onEOF = { [weak self] in
            guard let self else { return }
            self.onExited?(self)
        }
        terminal.onOutput = { [weak pty] bytes in
            pty?.write(bytes)
        }
        terminal.onTitle = { [weak self] value in
            guard let self else { return }
            let title = value.isEmpty ? "infinitty" : value
            self.stateLock.lock()
            self.storedTitle = title
            self.stateLock.unlock()
            self.onTitleChanged?(self, title)
        }
        terminal.onMarker = { [weak self] kind, exitCode in
            guard let self else { return }
            if kind == UInt8(ascii: "A") || kind == UInt8(ascii: "B") {
                self.promptCondition.lock()
                self.promptReady = true
                self.promptCondition.broadcast()
                self.promptCondition.unlock()
            } else if kind == UInt8(ascii: "C") {
                self.promptCondition.lock()
                self.promptReady = false
                self.promptCondition.unlock()
            }
            if kind == UInt8(ascii: "D") {
                let output = self.terminal.lastCommandOutput() ?? ""
                self.runLock.lock()
                let next = self.runQueue.completeHead(
                    exitCode: exitCode,
                    output: output)
                self.runLock.unlock()
                if let next {
                    self.pty.write(Array(next.utf8) + [0x0D])
                }
            }
            self.onMarker?(self, kind, exitCode)
        }
        control.todosHandler = { [weak self] argument in
            guard let self else { return "error: pane gone" }
            let trimmed = argument.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return self.encodedTodos() }
            guard let todos = PaneTodoParser.parse(trimmed) else {
                return "error: todos expects a JSON array"
            }
            self.setTodos(todos)
            return "ok"
        }
    }

    @discardableResult
    func launch() -> Bool {
        stateLock.lock()
        guard !launched, !stopped else {
            stateLock.unlock()
            return false
        }
        launched = true
        stateLock.unlock()

        guard control.start() else { return false }
        guard pty.spawn(
            cols: terminal.cols,
            rows: terminal.rows,
            socketPath: control.path,
            cwd: workingDirectory)
        else {
            control.stop()
            return false
        }
        return true
    }

    func send(_ text: String, newline: Bool) {
        terminal.userDidInput()
        pty.write(Array(text.utf8) + (newline ? [0x0D] : []))
    }

    func terminate() {
        pty.terminateProcessGroup()
    }

    func run(
        _ command: String,
        timeout: TimeInterval
    ) -> Result<RunReceipt, RunError> {
        runLock.lock()
        let needsPromptAdmission = runQueue.isEmpty
        runLock.unlock()
        if needsPromptAdmission,
           !waitForPrompt(timeout: min(timeout, 5)) {
            return .failure(.failed(
                "terminal prompt was not ready for execution"))
        }

        let itemID = UUID()
        let completion = DispatchSemaphore(value: 0)
        let receiptLock = NSLock()
        var receipt: RunReceipt?
        var cancelled = false

        let item = RunCommandQueue.Item(
            id: itemID,
            command: command
        ) { [weak self] exitCode, output in
            receiptLock.lock()
            if self?.isStopped == true {
                cancelled = true
            } else {
                receipt = RunReceipt(exitCode: exitCode, output: output)
            }
            receiptLock.unlock()
            completion.signal()
        }

        runLock.lock()
        let shouldSend = runQueue.enqueue(item)
        runLock.unlock()
        if shouldSend {
            promptCondition.lock()
            promptReady = false
            promptCondition.unlock()
            terminal.userDidInput()
            pty.write(Array(command.utf8) + [0x0D])
        }

        guard completion.wait(timeout: .now() + timeout) == .success else {
            runLock.lock()
            _ = runQueue.cancelTimedOut(id: itemID)
            runLock.unlock()
            return .failure(.failed(
                "timed out waiting for completion "
                    + "(is OSC 133 shell integration enabled?)"))
        }
        receiptLock.lock()
        let result = receipt
        let wasCancelled = cancelled
        receiptLock.unlock()
        if wasCancelled {
            return .failure(.failed(
                "terminal execution was cancelled during host shutdown"))
        }
        guard let result else {
            return .failure(.failed(
                "terminal execution ended without a receipt"))
        }
        return .success(result)
    }

    func setTodos(_ value: [PaneTodo]) {
        stateLock.lock()
        todos = value
        stateLock.unlock()
    }

    func encodedTodos() -> String {
        stateLock.lock()
        let value = todos
        stateLock.unlock()
        return PaneTodoParser.encode(value)
    }

    func shutdown(terminateShell: Bool) {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        stateLock.unlock()

        onExited = nil
        onTitleChanged = nil
        onMarker = nil
        control.stop()
        promptCondition.lock()
        promptStopped = true
        promptCondition.broadcast()
        promptCondition.unlock()
        runLock.lock()
        runQueue.cancelAll()
        runLock.unlock()
        if terminateShell {
            pty.terminateProcessGroup()
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func waitForPrompt(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        promptCondition.lock()
        defer { promptCondition.unlock() }
        while !promptReady, !promptStopped {
            guard promptCondition.wait(until: deadline) else { return false }
        }
        return promptReady && !promptStopped
    }
}
