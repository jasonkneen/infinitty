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

private struct HeadlessChannelPanelState {
    var selectedThreadID: String?
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
    private let config: AppConfig
    private let stateLock = NSLock()
    private let orchestrationQueue = DispatchQueue(
        label: "infinitty.headless-orchestration",
        qos: .userInitiated)
    /// Orders Channel publication and context reads so the next provider turn
    /// cannot miss a peer message that the preceding turn already emitted.
    private let collaborationQueue = DispatchQueue(
        label: "infinitty.headless-collaboration",
        qos: .userInitiated)
    private let workspaceProvisioner = AgentWorkspaceProvisioner()

    private var sessions: [Int: HeadlessTerminalSession] = [:]
    private var chats: [String: HeadlessChatRuntime] = [:]
    private var channelPanels: [String: HeadlessChannelPanelState] = [:]
    private var nextSessionID = 1
    private var nextChatID = 1
    private var focusedSessionID: Int?
    private var focusedChatID: String?
    private var focusedChannelID: String?
    private var provisioningProposalIDs = Set<String>()
    private var activeProposalIDs = Set<String>()
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
        config = AppConfig.load()

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
            if let snapshot = collaborationCoordinator.snapshot() {
                resumeApprovedHeadlessProposals(snapshot)
            }
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
        let liveChats = Array(chats.values)
        sessions.removeAll()
        chats.removeAll()
        channelPanels.removeAll()
        focusedSessionID = nil
        focusedChatID = nil
        focusedChannelID = nil
        provisioningProposalIDs.removeAll()
        activeProposalIDs.removeAll()
        stateLock.unlock()

        appControl.handler = nil
        appControl.stop()
        registry.unregister()
        for session in liveSessions {
            leaveChannel(for: session)
            session.shutdown(terminateShell: true)
        }
        for chat in liveChats {
            leaveChannel(for: chat)
            chat.stop()
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

    private func allChannelPanels() -> (
        panels: [String: HeadlessChannelPanelState],
        focusedID: String?
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (channelPanels, focusedChannelID)
    }

    private func allChats() -> (
        chats: [HeadlessChatRuntime],
        focusedID: String?
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (
            chats.values.sorted { $0.id < $1.id },
            focusedChatID)
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

    private func controlHandleAndText(
        _ argument: String
    ) -> (String, String)? {
        let parts = argument.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return nil }
        return (
            String(first),
            parts.count > 1 ? String(parts[1]) : "")
    }

    private enum ControlPane {
        case terminal(HeadlessTerminalSession)
        case chat(HeadlessChatRuntime)
        case channel(String)
    }

    private func controlPane(withHandle handle: String) -> ControlPane? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let terminalID = Int(handle),
           let terminal = sessions[terminalID]
        {
            return .terminal(terminal)
        }
        if let chat = chats[handle] {
            return .chat(chat)
        }
        let prefix = "channel-panel-"
        if handle.hasPrefix(prefix) {
            let channelID = String(handle.dropFirst(prefix.count))
            if channelPanels[channelID] != nil {
                return .channel(channelID)
            }
        }
        return nil
    }

    @discardableResult
    private func closeChat(_ chat: HeadlessChatRuntime) -> Bool {
        stateLock.lock()
        guard chats[chat.id] === chat else {
            stateLock.unlock()
            return false
        }
        chats[chat.id] = nil
        if focusedChatID == chat.id { focusedChatID = nil }
        stateLock.unlock()
        leaveChannel(for: chat)
        chat.stop()
        appControl.broadcast([
            "event": "chat-closed",
            "chatId": chat.id,
            "headless": true,
        ])
        return true
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
                    "chat",
                    "channel",
                    "channel.panel",
                    "events",
                ],
            ])
        case "list":
            let values = allSessions()
            let chatValues = allChats()
            let panelValues = allChannelPanels()
            let terminalPanes: [[String: Any]] = values.sessions.map { session in
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
            let channelPanes: [[String: Any]]
            if panelValues.panels.isEmpty {
                channelPanes = []
            } else {
                let snapshot = collaborationCoordinator.snapshot()
                channelPanes =
                    panelValues.panels.keys.sorted().compactMap { channelID in
                        guard let channel = snapshot?.channels.first(where: {
                            $0.id == channelID
                        }) else { return nil }
                        return [
                            "id": "channel-panel-\(channelID)",
                            "title": channel.name,
                            "windowTitle": "",
                            "focused": panelValues.focusedID == channelID,
                            "kind": "channel",
                            "channelId": channelID,
                            "headless": true,
                        ]
                    }
            }
            let chatPanes: [[String: Any]] = chatValues.chats.map { chat in
                let metadata = chat.metadata()
                let endpoint = channelEndpoint(for: chat)
                return [
                    "id": chat.id,
                    "title": metadata.name,
                    "windowTitle": "",
                    "focused": chatValues.focusedID == chat.id,
                    "kind": "chat",
                    "role": metadata.role,
                    "workspace": metadata.workspace,
                    "headless": true,
                    "channelEndpoint": [
                        "id": endpoint.id,
                        "kind": endpoint.kind.rawValue,
                        "label": endpoint.label,
                        "participantID":
                            endpoint.participantID ?? "",
                        "instanceID": endpoint.instanceID ?? "",
                    ],
                ]
            }
            return jsonString(terminalPanes + chatPanes + channelPanes)
        case "chat":
            return handleChat(argument)
        case "channel":
            return collaborationCoordinator.execute(argument).response
        case "channel-panel":
            return handleChannelPanel(argument)
        case "channel-project":
            // Headless panes have no AppKit projection; accepting the
            // coordinator notification confirms this live instance is aware
            // of the new authoritative revision.
            guard let snapshot =
                    CollaborationCoordinatorClient.projectedSnapshot(
                        from: argument)
            else { return "error: invalid Channel projection" }
            resumeApprovedHeadlessProposals(snapshot)
            return "ok"
        case "new-window", "new-tab":
            let directory = workingDirectory(from: argument)
            if let error = directory.error { return error }
            return createSession(cwd: directory.path).map(String.init)
                ?? "error: could not create headless terminal"
        case "split":
            guard let (handle, directionText) =
                    controlHandleAndText(argument),
                  let target = controlPane(withHandle: handle)
            else {
                return "error: split <id> right|left|down|up"
            }
            let direction = directionText.trimmingCharacters(
                in: .whitespaces).lowercased()
            guard ["right", "left", "down", "up"].contains(direction) else {
                return "error: split <id> right|left|down|up"
            }
            let workspace: String?
            switch target {
            case .terminal(let terminal):
                workspace = terminal.workingDirectory
            case .chat(let chat):
                workspace = chat.metadata().workspace
            case .channel:
                workspace = nil
            }
            return createSession(cwd: workspace).map(String.init)
                ?? "error: split failed"
        case "focus":
            guard let (handle, _) = controlHandleAndText(argument),
                  let target = controlPane(withHandle: handle)
            else {
                return "error: focus <id>"
            }
            stateLock.lock()
            switch target {
            case .terminal(let terminal):
                focusedSessionID = terminal.id
                focusedChatID = nil
                focusedChannelID = nil
            case .chat(let chat):
                focusedSessionID = nil
                focusedChatID = chat.id
                focusedChannelID = nil
            case .channel(let channelID):
                focusedSessionID = nil
                focusedChatID = nil
                focusedChannelID = channelID
            }
            stateLock.unlock()
            appControl.broadcast([
                "event": "focus",
                "pane": handle,
                "headless": true,
            ])
            return "ok"
        case "close":
            guard let (handle, _) = controlHandleAndText(argument),
                  let target = controlPane(withHandle: handle)
            else {
                return "error: close <id>"
            }
            switch target {
            case .terminal(let terminal):
                terminal.terminate()
                return "ok"
            case .chat(let chat):
                return closeChat(chat)
                    ? "ok"
                    : "error: close failed"
            case .channel(let channelID):
                stateLock.lock()
                channelPanels[channelID] = nil
                if focusedChannelID == channelID {
                    focusedChannelID = nil
                }
                stateLock.unlock()
                appControl.broadcast([
                    "event": "channel-panel-closed",
                    "channelId": channelID,
                    "panelId": handle,
                    "headless": true,
                ])
                return "ok"
            }
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
                + "exit-code | run | todos | chat | channel | channel-panel | subscribe)"
        }
    }

    private func headlessChatState(
        _ chat: HeadlessChatRuntime,
        isOpen: Bool = true
    ) -> [String: Any] {
        let metadata = chat.metadata()
        var value = chat.state().jsonObject()
        stateLock.lock()
        let focused = focusedChatID == chat.id
        stateLock.unlock()
        value["chatId"] = chat.id
        value["paneId"] = "\(instanceID)/\(chat.id)"
        value["title"] = metadata.name
        value["role"] = metadata.role
        value["provider"] = chat.configuredProvider
        value["model"] = chat.configuredModel ?? NSNull()
        value["participantId"] = chat.participantID
        value["proposalId"] = chat.proposalID ?? NSNull()
        value["channelId"] =
            channelID(for: channelEndpoint(for: chat).id)
            ?? NSNull()
        value["focused"] = focused
        value["open"] = isOpen
        value["headless"] = true
        return value
    }

    private func configuredHeadlessChat(
        provider rawProvider: String?,
        model: String?
    ) -> (config: AppConfig, provider: String, model: String?)? {
        let provider = (rawProvider ?? config.aiProvider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let supported = Set(
            InfinittyAIProvider.allCases.map(\.rawValue) + ["auto"])
        guard supported.contains(provider) else { return nil }
        let model = model?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        var value = config
        value.aiProvider = provider
        switch provider {
        case "claude": value.claudeModel = model
        case "codex": value.codexModel = model
        case "opencode": value.opencodeModel = model
        case "hermes": value.hermesModel = model
        case "amp": value.ampModel = model
        default: break
        }
        return (value, provider, model)
    }

    private func handleChat(_ encoded: String) -> String {
        let request: [String: Any]
        switch BrowserControlCodec.decode(encoded) {
        case .success(let value):
            request = value
        case .failure(let error):
            return BrowserControlCodec.response(
                error: "invalid_request",
                message: error.localizedDescription)
        }
        guard request["v"] as? Int == 1 else {
            return BrowserControlCodec.response(
                error: "unsupported_version",
                message: "Chat requests require version 1.")
        }
        let operation = request["op"] as? String ?? ""
        if operation == "list" {
            return BrowserControlCodec.response(result: [
                "chats": allChats().chats.map {
                    headlessChatState($0)
                },
            ])
        }
        if operation == "create" {
            guard let configured = configuredHeadlessChat(
                provider: request["provider"] as? String,
                model: request["model"] as? String)
            else {
                return BrowserControlCodec.response(
                    error: "invalid_provider",
                    message: "Use auto, claude, codex, opencode, hermes, "
                        + "amp, or apple.")
            }
            let workspace: String
            if let rawWorkspace = request["workspace"] as? String {
                guard let resolved = LaunchOptions.workingDirectory(
                    from: [rawWorkspace])
                else {
                    return BrowserControlCodec.response(
                        error: "invalid_workspace",
                        message:
                            "workspace must be an existing directory.")
                }
                workspace = resolved
            } else {
                let sessions = allSessions()
                workspace = sessions.focusedID
                    .flatMap { id in
                        sessions.sessions.first(where: {
                            $0.id == id
                        })?.workingDirectory
                    }
                    ?? FileManager.default.currentDirectoryPath
            }
            stateLock.lock()
            let chatID = "chat-\(nextChatID)"
            nextChatID += 1
            let defaultName = "Chat \(chatID.dropFirst("chat-".count))"
            stateLock.unlock()
            let rawName = request["name"] as? String
            let name = rawName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawRole = request["role"] as? String
            let role = rawRole?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let runtime = HeadlessChatRuntime(
                id: chatID,
                participantID:
                    "\(instanceID)/participant/\(chatID)",
                name: name?.isEmpty == false
                    ? String(name!.prefix(80))
                    : defaultName,
                role: role?.isEmpty == false
                    ? String(role!.prefix(120))
                    : "coding agent",
                workspaceDirectory: workspace,
                configuredProvider: configured.provider,
                configuredModel: configured.model,
                config: configured.config,
                collaborationContextProvider: {
                    [weak self] in
                    self?.collaborationContext(forChatID: chatID)
                },
                collaborationMessagePublisher: {
                    [weak self] emission in
                    self?.publishCollaborationMessage(
                        emission,
                        fromChatID: chatID)
                },
                onStateChange: { [weak self] state in
                    self?.appControl.broadcast([
                        "event": "chat-state",
                        "chatId": chatID,
                        "state": state,
                        "headless": true,
                    ])
                })
            stateLock.lock()
            chats[chatID] = runtime
            focusedChatID = chatID
            focusedSessionID = nil
            focusedChannelID = nil
            stateLock.unlock()
            appControl.broadcast([
                "event": "chat-opened",
                "chatId": chatID,
                "headless": true,
            ])
            return BrowserControlCodec.response(
                result: headlessChatState(runtime))
        }

        guard let chatID = request["chatId"] as? String else {
            return BrowserControlCodec.response(
                error: "unknown_chat",
                message: "chatId must identify an open Chat.")
        }
        stateLock.lock()
        let chat = chats[chatID]
        stateLock.unlock()
        guard let chat else {
            return BrowserControlCodec.response(
                error: "unknown_chat",
                message: "chatId must identify an open Chat.")
        }

        switch operation {
        case "snapshot":
            break
        case "focus":
            stateLock.lock()
            focusedChatID = chatID
            focusedSessionID = nil
            focusedChannelID = nil
            stateLock.unlock()
        case "close":
            guard closeChat(chat) else {
                return BrowserControlCodec.response(
                    error: "close_failed",
                    message: "The Chat could not be closed.")
            }
            var closed = headlessChatState(chat, isOpen: false)
            closed["focused"] = false
            return BrowserControlCodec.response(result: closed)
        case "submit":
            guard let text = request["text"] as? String,
                  !text.trimmingCharacters(
                      in: .whitespacesAndNewlines).isEmpty
            else {
                return BrowserControlCodec.response(
                    error: "missing_text",
                    message: "text is required.")
            }
            chat.submit(
                text,
                model: request["model"] as? String,
                effort: request["effort"] as? String ?? "Auto")
        case "cancel":
            chat.cancel()
        case "new_thread":
            chat.startNewThread()
        case "select_thread":
            guard let threadID = request["threadId"] as? String,
                  chat.selectThread(threadID)
            else {
                return BrowserControlCodec.response(
                    error: "unknown_thread",
                    message:
                        "threadId must identify a thread in this Chat.")
            }
        case "rename":
            guard let name = request["name"] as? String,
                  !name.trimmingCharacters(
                      in: .whitespacesAndNewlines).isEmpty
            else {
                return BrowserControlCodec.response(
                    error: "missing_name",
                    message: "name is required.")
            }
            chat.rename(name)
        case "set_workspace":
            guard let rawWorkspace = request["workspace"] as? String,
                  let workspace = LaunchOptions.workingDirectory(
                      from: [rawWorkspace])
            else {
                return BrowserControlCodec.response(
                    error: "invalid_workspace",
                    message:
                        "workspace must be an existing directory.")
            }
            guard chat.setWorkspace(workspace) else {
                return BrowserControlCodec.response(
                    error: "chat_busy",
                    message:
                        "Cancel or wait for Chat work before changing workspace.")
            }
        default:
            return BrowserControlCodec.response(
                error: "unknown_operation",
                message: "Unknown Chat operation '\(operation)'.")
        }
        return BrowserControlCodec.response(
            result: headlessChatState(chat))
    }

    private func handleChannelPanel(_ encoded: String) -> String {
        let request: [String: Any]
        switch BrowserControlCodec.decode(encoded) {
        case let .success(value):
            request = value
        case let .failure(error):
            return BrowserControlCodec.response(
                error: "invalid_request",
                message: error.localizedDescription)
        }
        guard request["v"] as? Int == 1 else {
            return BrowserControlCodec.response(
                error: "unsupported_version",
                message: "Channel panel requests require version 1.")
        }
        let operation = request["op"] as? String ?? ""
        guard let snapshot = collaborationCoordinator.snapshot() else {
            return BrowserControlCodec.response(
                error: "coordinator_unavailable",
                message: "The shared Channel coordinator is unavailable.")
        }
        let panelValues = allChannelPanels()
        if operation == "list" {
            let values = snapshot.channels.map { channel in
                ChannelPanelProjection(
                    channel: channel,
                    selectedThreadID:
                        panelValues.panels[channel.id]?.selectedThreadID)
                    .controlState(
                        isOpen: panelValues.panels[channel.id] != nil)
            }
            return BrowserControlCodec.response(result: ["channels": values])
        }
        guard let channelID = request["channelId"] as? String,
              let channel = snapshot.channels.first(where: {
                  $0.id == channelID
              })
        else {
            return BrowserControlCodec.response(
                error: "unknown_channel",
                message: "channelId must identify an existing Channel.")
        }

        if operation == "post_message" {
            guard let rawText = request["text"] as? String else {
                return BrowserControlCodec.response(
                    error: "missing_text",
                    message: "text is required.")
            }
            let text = rawText.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return BrowserControlCodec.response(
                    error: "missing_text",
                    message: "text must not be empty.")
            }
            let threadID = request["threadId"] as? String
            if let threadID,
               !channel.messages.contains(where: {
                   $0.threadID == threadID
               })
            {
                return BrowserControlCodec.response(
                    error: "unknown_thread",
                    message: "No Channel thread has id \(threadID).")
            }
            let messageID = UUID().uuidString.lowercased()
            let actor = CollaborationActor(
                id: "human:headless-control",
                kind: .human,
                displayName: "Headless control")
            let mutation = CollaborationControlRequest(
                op: .postMessage,
                actor: actor,
                idempotencyKey: "headless-channel-panel:\(messageID)",
                channelID: channelID,
                message: CollaborationMessage(
                    id: messageID,
                    threadID: threadID,
                    authorID: actor.id,
                    text: CollaborationMessage.boundedChannelText(text)))
            return executeChannelPanelMutation(
                mutation,
                channelID: channelID,
                selectedThreadID: threadID)
        }

        if operation == "assign_role" {
            guard let participantID = request["participantId"] as? String,
                  let rawRole = request["role"] as? String,
                  let participant = channel.participants.first(where: {
                      $0.id == participantID
                  }),
                  let endpoint = channel.endpoints.first(where: {
                      $0.participantID == participantID
                  })
            else {
                return BrowserControlCodec.response(
                    error: "unknown_participant",
                    message:
                        "participantId and role must identify a connected participant.")
            }
            let role = rawRole.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !role.isEmpty else {
                return BrowserControlCodec.response(
                    error: "missing_role",
                    message: "role must not be empty.")
            }
            let mutation = CollaborationControlRequest(
                op: .updateMembership,
                actor: CollaborationActor(
                    id: "human:headless-control",
                    kind: .human,
                    displayName: "Headless control"),
                idempotencyKey:
                    "headless-channel-role:\(participantID):\(UUID().uuidString)",
                channelID: channelID,
                endpoint: endpoint,
                participant: CollaborationParticipant(
                    id: participant.id,
                    displayName: participant.displayName,
                    role: role,
                    provider: participant.provider,
                    modelID: participant.modelID,
                    capabilities: participant.capabilities))
            return executeChannelPanelMutation(
                mutation,
                channelID: channelID,
                selectedThreadID:
                    panelValues.panels[channelID]?.selectedThreadID)
        }

        stateLock.lock()
        let result: String
        switch operation {
        case "snapshot":
            result = BrowserControlCodec.response(result:
                ChannelPanelProjection(
                    channel: channel,
                    selectedThreadID:
                        channelPanels[channelID]?.selectedThreadID)
                    .controlState(
                        isOpen: channelPanels[channelID] != nil))
        case "open":
            if channelPanels[channelID] == nil {
                channelPanels[channelID] = HeadlessChannelPanelState()
            }
            focusedChannelID = channelID
            focusedSessionID = nil
            focusedChatID = nil
            result = BrowserControlCodec.response(result:
                ChannelPanelProjection(
                    channel: channel,
                    selectedThreadID:
                        channelPanels[channelID]?.selectedThreadID)
                    .controlState(isOpen: true))
        case "focus":
            guard channelPanels[channelID] != nil else {
                stateLock.unlock()
                return BrowserControlCodec.response(
                    error: "panel_closed",
                    message: "Open the Channel panel before focusing it.")
            }
            focusedChannelID = channelID
            focusedSessionID = nil
            focusedChatID = nil
            result = BrowserControlCodec.response(result:
                ChannelPanelProjection(
                    channel: channel,
                    selectedThreadID:
                        channelPanels[channelID]?.selectedThreadID)
                    .controlState(isOpen: true))
        case "close":
            channelPanels[channelID] = nil
            if focusedChannelID == channelID { focusedChannelID = nil }
            result = BrowserControlCodec.response(result:
                ChannelPanelProjection(
                    channel: channel,
                    selectedThreadID: nil)
                    .controlState(isOpen: false))
        case "select_thread":
            guard var panel = channelPanels[channelID] else {
                stateLock.unlock()
                return BrowserControlCodec.response(
                    error: "panel_closed",
                    message:
                        "Open the Channel panel before selecting a thread.")
            }
            let threadID = request["threadId"] as? String
            if let threadID,
               !channel.messages.contains(where: {
                   $0.threadID == threadID
               })
            {
                stateLock.unlock()
                return BrowserControlCodec.response(
                    error: "unknown_thread",
                    message: "No Channel thread has id \(threadID).")
            }
            panel.selectedThreadID = threadID
            channelPanels[channelID] = panel
            result = BrowserControlCodec.response(result:
                ChannelPanelProjection(
                    channel: channel,
                    selectedThreadID: threadID)
                    .controlState(isOpen: true))
        default:
            stateLock.unlock()
            return BrowserControlCodec.response(
                error: "unknown_operation",
                message: "Unknown Channel panel operation '\(operation)'.")
        }
        stateLock.unlock()
        return result
    }

    private func executeChannelPanelMutation(
        _ mutation: CollaborationControlRequest,
        channelID: String,
        selectedThreadID: String?
    ) -> String {
        guard let encoded = CollaborationControlCodec.encode(mutation) else {
            return BrowserControlCodec.response(
                error: "encode_failed",
                message: "Could not encode the Channel panel mutation.")
        }
        let executed = collaborationCoordinator.execute(encoded)
        guard let updated = executed.snapshot?.channels.first(where: {
            $0.id == channelID
        }) else { return executed.response }
        return BrowserControlCodec.response(result:
            ChannelPanelProjection(
                channel: updated,
                selectedThreadID: selectedThreadID)
                .controlState(
                    isOpen:
                        allChannelPanels().panels[channelID] != nil))
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

    private func channelEndpoint(
        for chat: HeadlessChatRuntime
    ) -> CollaborationEndpoint {
        CollaborationEndpoint(
            id: "\(instanceID)/\(chat.id)",
            kind: .chat,
            label: chat.metadata().name,
            participantID: chat.participantID,
            instanceID: instanceID)
    }

    private func leaveChannel(for chat: HeadlessChatRuntime) {
        let endpointID = channelEndpoint(for: chat).id
        guard channelID(for: endpointID) != nil else { return }
        let request = CollaborationControlRequest(
            op: .leave,
            actor: CollaborationActor(
                id: "system:\(instanceID)",
                kind: .system,
                displayName: "Infinitty headless host"),
            idempotencyKey:
                "headless-chat-leave:\(endpointID):"
                + UUID().uuidString.lowercased(),
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
        }
    }

    private func channelID(for endpointID: String) -> String? {
        collaborationCoordinator.snapshot()?.channels.first(where: {
            $0.endpoints.contains(where: { $0.id == endpointID })
        })?.id
    }

    private func collaborationContext(
        forChatID chatID: String
    ) -> CollaborationChatContext? {
        stateLock.lock()
        let chat = chats[chatID]
        stateLock.unlock()
        guard let chat else { return nil }
        return collaborationQueue.sync {
            guard let snapshot = collaborationCoordinator.snapshot()
            else { return nil }
            return CollaborationChatContext(
                snapshot: snapshot,
                endpointID: channelEndpoint(for: chat).id)
        }
    }

    private func publishCollaborationMessage(
        _ emission: CollaborationChatEmission,
        fromChatID chatID: String
    ) {
        stateLock.lock()
        let chat = chats[chatID]
        stateLock.unlock()
        guard let chat else { return }
        let actor: CollaborationActor
        let authorID: String
        switch emission.kind {
        case .humanPrompt:
            authorID = "human:headless-control"
            actor = CollaborationActor(
                id: authorID,
                kind: .human,
                displayName: "Headless control")
        case .agentResponse:
            authorID = chat.participantID
            actor = CollaborationActor(
                id: authorID,
                kind: .agent,
                displayName: chat.metadata().name)
        }
        collaborationQueue.sync {
            guard let channelID = channelID(
                      for: channelEndpoint(for: chat).id)
            else { return }
            let messageID = UUID().uuidString.lowercased()
            let request = CollaborationControlRequest(
                op: .postMessage,
                actor: actor,
                idempotencyKey: "headless-chat-message:\(messageID)",
                channelID: channelID,
                message: CollaborationMessage(
                    id: messageID,
                    threadID: emission.threadID,
                    authorID: authorID,
                    text: CollaborationMessage.boundedChannelText(
                        emission.text)))
            guard let encoded = CollaborationControlCodec.encode(request)
            else { return }
            let result = self.collaborationCoordinator.execute(encoded)
            if result.snapshot == nil {
                self.appControl.broadcast([
                    "event": "channel-error",
                    "chatId": chatID,
                    "message": result.response,
                ])
            }
        }
    }

    private func resumeApprovedHeadlessProposals(
        _ snapshot: CollaborationSnapshot
    ) {
        for proposal in snapshot.proposals
        where [.approved, .provisioning, .running].contains(proposal.state)
            && proposal.spec.presentation == .headless
            && proposal.spec.targetInstanceID == instanceID
        {
            stateLock.lock()
            let inserted =
                !activeProposalIDs.contains(proposal.spec.id)
                && provisioningProposalIDs
                    .insert(proposal.spec.id).inserted
            stateLock.unlock()
            guard inserted else { continue }
            orchestrationQueue.async { [weak self] in
                self?.provisionApprovedHeadlessProposal(proposal)
            }
        }
    }

    private func provisionApprovedHeadlessProposal(
        _ proposal: CollaborationRoomProposal
    ) {
        do {
            let isRunningRecovery = proposal.state == .running
            var snapshot: CollaborationSnapshot
            if proposal.state == .approved {
                snapshot = try executeHeadlessOrchestrationMutation(
                    CollaborationControlRequest(
                        op: .startProvisioning,
                        actor: headlessOrchestrationActor(),
                        idempotencyKey:
                            "proposal:\(proposal.spec.id):provision:"
                            + "\(proposal.updatedAt.timeIntervalSince1970)",
                        proposalID: proposal.spec.id,
                        proposalDigest: proposal.digest))
            } else {
                guard let current = collaborationCoordinator.snapshot(),
                      current.proposals.contains(where: {
                          $0.spec.id == proposal.spec.id
                              && $0.digest == proposal.digest
                              && [.provisioning, .running].contains($0.state)
                      })
                else {
                    throw CollaborationRoomError.invalidValue(
                        field: "proposal state",
                        reason:
                            "the approved room is no longer recoverable")
                }
                snapshot = current
            }
            let mode: AgentWorkspaceMode =
                proposal.spec.workspaceStrategy == .worktrees
                ? .worktree
                : .shared
            var workspaces: [String: ProvisionedAgentWorkspace] = [:]
            for agent in proposal.spec.agents {
                if agent.runtime == .cloud,
                   agent.provider != "codex",
                   agent.provider != "claude"
                {
                    throw CollaborationRoomError.invalidValue(
                        field: "cloud provider",
                        reason:
                            "cloud agents require the real Codex or Claude "
                            + "server adapter")
                }
                workspaces[agent.id] = try workspaceProvisioner.provision(
                    repositoryRoot: proposal.spec.workspaceRoot,
                    channelID: proposal.spec.channelID,
                    participantID: agent.id,
                    mode: mode)
            }
            if !snapshot.channels.contains(where: {
                $0.id == proposal.spec.channelID
            }) {
                snapshot = try executeHeadlessOrchestrationMutation(
                    CollaborationControlRequest(
                        op: .create,
                        actor: headlessOrchestrationActor(),
                        idempotencyKey:
                            "proposal:\(proposal.spec.id):create-channel",
                        channelID: proposal.spec.channelID,
                        name: proposal.spec.roomName))
            }

            stateLock.lock()
            channelPanels[proposal.spec.channelID] =
                channelPanels[proposal.spec.channelID]
                ?? HeadlessChannelPanelState()
            let existingByParticipant = Dictionary(
                uniqueKeysWithValues: chats.values
                    .filter { $0.proposalID == proposal.spec.id }
                    .map { ($0.participantID, $0) })
            stateLock.unlock()
            var runtimes: [(CollaborationAgentSpec, HeadlessChatRuntime)] = []
            for (agentIndex, spec) in proposal.spec.agents.enumerated() {
                if let existing = existingByParticipant[spec.id] {
                    runtimes.append((spec, existing))
                    continue
                }
                guard let workspace = workspaces[spec.id],
                      let configured = configuredHeadlessChat(
                          provider: spec.provider,
                          model: spec.modelID)
                else {
                    throw CollaborationRoomError.invalidValue(
                        field: "agent provider",
                        reason:
                            "unsupported provider for \(spec.displayName)")
                }
                let chatID =
                    "chat-room-\(proposal.spec.id)-\(agentIndex + 1)"
                let runtime = HeadlessChatRuntime(
                    id: chatID,
                    participantID: spec.id,
                    proposalID: proposal.spec.id,
                    name: spec.displayName,
                    role: spec.role,
                    workspaceDirectory: workspace.path,
                    configuredProvider: configured.provider,
                    configuredModel: configured.model,
                    config: configured.config,
                    capabilities: Array(Set(
                        spec.capabilities
                            + ["channel.receive", "channel.send"]))
                        .sorted(),
                    collaborationContextProvider: {
                        [weak self] in
                        self?.collaborationContext(
                            forChatID: chatID)
                    },
                    collaborationMessagePublisher: {
                        [weak self] emission in
                        self?.publishCollaborationMessage(
                            emission,
                            fromChatID: chatID)
                    },
                    onStateChange: { [weak self] state in
                        self?.appControl.broadcast([
                            "event": "chat-state",
                            "chatId": chatID,
                            "state": state,
                            "headless": true,
                        ])
                    })
                stateLock.lock()
                chats[chatID] = runtime
                stateLock.unlock()
                runtimes.append((spec, runtime))
                appControl.broadcast([
                    "event": "chat-opened",
                    "chatId": chatID,
                    "proposalId": proposal.spec.id,
                    "headless": true,
                ])
            }

            let roomEndpoint = CollaborationEndpoint(
                id:
                    "\(instanceID)/channel-panel-"
                    + proposal.spec.channelID,
                kind: .channel,
                label: proposal.spec.roomName,
                instanceID: instanceID)
            for (spec, runtime) in runtimes {
                let endpoint = channelEndpoint(for: runtime)
                if snapshot.channels.first(where: {
                    $0.id == proposal.spec.channelID
                })?.endpoints.contains(where: {
                    $0.id == endpoint.id
                }) == true {
                    continue
                }
                let participant = CollaborationParticipant(
                    id: runtime.participantID,
                    displayName: spec.displayName,
                    role: spec.role,
                    provider: runtime.configuredProvider,
                    modelID: runtime.configuredModel,
                    capabilities: runtime.capabilities)
                let linkIdempotencyKey =
                    isRunningRecovery
                    ? "proposal:\(proposal.spec.id):recover-link:"
                        + "\(snapshot.revision):\(spec.id)"
                    : "proposal:\(proposal.spec.id):link:\(spec.id)"
                snapshot = try executeHeadlessOrchestrationMutation(
                    CollaborationControlRequest(
                        op: .linkAndJoin,
                        actor: headlessOrchestrationActor(),
                        idempotencyKey: linkIdempotencyKey,
                        channelID: proposal.spec.channelID,
                        source: roomEndpoint,
                        target: endpoint,
                        participants: [participant]))
            }

            for spec in proposal.spec.agents {
                for (index, scope) in
                    spec.responsibilityScopes.enumerated()
                {
                    let claimID =
                        "\(proposal.spec.id)-\(spec.id)-scope-\(index)"
                    if snapshot.channels.first(where: {
                        $0.id == proposal.spec.channelID
                    })?.responsibilities.contains(where: {
                        $0.id == claimID
                    }) == true {
                        continue
                    }
                    snapshot = try executeHeadlessOrchestrationMutation(
                        CollaborationControlRequest(
                            op: .claim,
                            actor: headlessOrchestrationActor(),
                            idempotencyKey:
                                "proposal:\(proposal.spec.id):claim:"
                                + "\(spec.id):\(index)",
                            channelID: proposal.spec.channelID,
                            claim: CollaborationResponsibility(
                                id: claimID,
                                scope: scope,
                                summary: spec.role,
                                ownerID: spec.id)))
                }
            }
            if !isRunningRecovery {
                let plan = proposal.spec.agents.enumerated().map {
                    index, spec in
                    CollaborationPlanItem(
                        id: "\(proposal.spec.id)-agent-\(index)",
                        title: "\(spec.displayName): \(spec.role)",
                        status: .inProgress,
                        ownerID: spec.id)
                }
                snapshot = try executeHeadlessOrchestrationMutation(
                    CollaborationControlRequest(
                        op: .replacePlan,
                        actor: headlessOrchestrationActor(),
                        idempotencyKey:
                            "proposal:\(proposal.spec.id):publish-plan",
                        channelID: proposal.spec.channelID,
                        plan: plan))
                snapshot = try executeHeadlessOrchestrationMutation(
                    CollaborationControlRequest(
                        op: .postMessage,
                        actor: headlessOrchestrationActor(),
                        idempotencyKey:
                            "proposal:\(proposal.spec.id):room-kickoff",
                        channelID: proposal.spec.channelID,
                        message: CollaborationMessage(
                            id: "\(proposal.spec.id)-kickoff",
                            threadID: nil,
                            authorID: headlessOrchestrationActor().id,
                            text:
                                "Approved objective: "
                                + proposal.spec.objective)))
            }

            for (spec, runtime) in runtimes {
                let peers = proposal.spec.agents
                    .filter { $0.id != spec.id }
                    .map { "\($0.displayName) — \($0.role)" }
                    .joined(separator: "\n")
                let scopes = spec.responsibilityScopes.isEmpty
                    ? "No exclusive file scope was assigned."
                    : "Your exclusive scopes:\n"
                        + spec.responsibilityScopes.joined(
                            separator: "\n")
                let opening =
                    isRunningRecovery
                    ? "Reconnect to your existing Channel and resume only "
                        + "from its authoritative plan and messages."
                    : "Begin the approved objective."
                runtime.submit(
                    "You are \(spec.displayName), \(spec.role), in "
                    + "Channel \(proposal.spec.roomName).\n\n"
                    + "\(opening)\n\n"
                    + "Objective:\n\(proposal.spec.objective)\n\n"
                    + "\(scopes)\n\nPeers:\n"
                    + "\(peers.isEmpty ? "None" : peers)\n\n"
                    + "Coordinate through Channel state, do not modify "
                    + "another participant's claimed scope, and report only "
                    + "work or tool results you actually observed.")
            }
            if !isRunningRecovery {
                snapshot = try executeHeadlessOrchestrationMutation(
                    CollaborationControlRequest(
                        op: .markProposalRunning,
                        actor: headlessOrchestrationActor(),
                        idempotencyKey:
                            "proposal:\(proposal.spec.id):running",
                        proposalID: proposal.spec.id,
                        proposalDigest: proposal.digest))
            }
            appControl.broadcast([
                "event":
                    isRunningRecovery
                    ? "channel-room-recovered"
                    : "channel-room-running",
                "proposalId": proposal.spec.id,
                "channelId": proposal.spec.channelID,
                "agentCount": proposal.spec.agents.count,
                "headless": true,
                "revision": snapshot.revision,
            ])
            stateLock.lock()
            provisioningProposalIDs.remove(proposal.spec.id)
            activeProposalIDs.insert(proposal.spec.id)
            stateLock.unlock()
        } catch {
            let reason = String(describing: error)
            let request = CollaborationControlRequest(
                op: .markProposalFailed,
                actor: headlessOrchestrationActor(),
                idempotencyKey:
                    "proposal:\(proposal.spec.id):failed:"
                    + UUID().uuidString.lowercased(),
                proposalID: proposal.spec.id,
                proposalDigest: proposal.digest,
                reason: reason)
            _ = try? executeHeadlessOrchestrationMutation(request)
            stateLock.lock()
            provisioningProposalIDs.remove(proposal.spec.id)
            stateLock.unlock()
            appControl.broadcast([
                "event": "channel-room-failed",
                "proposalId": proposal.spec.id,
                "message": reason,
                "headless": true,
            ])
        }
    }

    private func executeHeadlessOrchestrationMutation(
        _ request: CollaborationControlRequest
    ) throws -> CollaborationSnapshot {
        guard let encoded = CollaborationControlCodec.encode(request)
        else {
            throw CollaborationRoomError.invalidValue(
                field: "orchestration request",
                reason: "could not encode")
        }
        let result = collaborationCoordinator.execute(encoded)
        guard let snapshot = result.snapshot else {
            throw CollaborationRoomError.invalidValue(
                field: "orchestration request",
                reason: result.response)
        }
        return snapshot
    }

    private func headlessOrchestrationActor() -> CollaborationActor {
        CollaborationActor(
            id: "system:orchestrator:\(instanceID)",
            kind: .system,
            displayName: "Infinitty headless room orchestrator")
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
