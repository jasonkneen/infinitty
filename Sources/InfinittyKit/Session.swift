import AppKit

/// One live terminal: grid + parser, pty, renderer, view, control socket.
/// A window shows one session, or several via native tabs and split panes.
final class TerminalSession: NSObject {
    private static var nextID = 0
    let id: Int
    let terminal: Terminal
    let pty: PTY
    let renderer: Renderer
    let view: TerminalView
    let control: ControlServer

    private(set) var title = "infinitty"
    var paneTitleOverride: String?
    /// Live agent-session name ("claude · titerm", later the real session
    /// title) while a recognized agent CLI runs in this pane. Cleared when the
    /// pane returns to its shell.
    var agentSessionName: String?
    /// Agent-published plan/todo list shown from the pane header's checklist
    /// icon. Set via the pane socket (`todos <json>`), the app socket
    /// (`todos <id> <json>`), or the infinitty_todos MCP tool.
    private(set) var todos: [PaneTodo] = []
    /// Broadcast hook for todo changes (wired by the app delegate).
    var onTodosChanged: ((TerminalSession) -> Void)?

    /// Replace the pane's todo list and refresh the header UI (main-safe).
    func setTodos(_ todos: [PaneTodo]) {
        let apply = { [weak self] in
            guard let self else { return }
            self.todos = todos
            self.view.setTodos(todos)
            self.onTodosChanged?(self)
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }
    /// Shell starting directory; set before launch() (folder launches, socket
    /// new-tab/new-window with a path).
    var workingDirectory: String?
    var petAnimator: PetAnimator?
    private(set) var processTracker: ForegroundProcessTracker?
    private var lastForegroundPokeMs: Int64 = 0
    private var launched = false
    private var torndown = false

    var onExited: ((TerminalSession) -> Void)?
    var onTitleChanged: ((TerminalSession) -> Void)?

    init(config: AppConfig, scale: CGFloat) {
        TerminalSession.nextID += 1
        id = TerminalSession.nextID
        terminal = Terminal(cols: 120, rows: 32)
        pty = PTY()
        renderer = Renderer(config: config, scale: scale)
        renderer.debugLabel = "pane-\(id)"
        view = TerminalView(frame: .zero)
        control = ControlServer(terminal: terminal, pty: pty)
        super.init()

        view.terminal = terminal
        view.pty = pty
        view.renderer = renderer
        // A split can expose this view before Metal has produced its first
        // drawable. Seed the backing layer now so borderless panels never show
        // the desktop through the new pane for a frame.
        renderer.prepare(layer: view.metalLayer)

        // Weak captures: Session owns terminal/pty/renderer for the pane's
        // whole life, so these callbacks never need to keep each other alive.
        // Strong captures here form pty<->terminal and terminal->renderer
        // cycles that leak the entire engine on every pane close.
        pty.onData = { [weak terminal] buf, count in terminal?.feed(buf, count) }
        pty.onEOF = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.onExited?(self)
            }
        }
        terminal.onOutput = { [weak pty] bytes in pty?.write(bytes) }
        terminal.onChange = { [weak renderer] in renderer?.poke() }
        terminal.onTitle = { [weak self] t in
            DispatchQueue.main.async {
                guard let self else { return }
                self.title = t.isEmpty ? "infinitty" : t
                self.onTitleChanged?(self)
            }
        }
        terminal.onBell = { [weak self] in
            // AppKit audio + pet animator must run on main — never the PTY thread.
            DispatchQueue.main.async {
                NSSound.beep()
                self?.petAnimator?.bell()
            }
        }

        control.activityHandler = { [weak view] in
            DispatchQueue.main.async { view?.showAgentGlow() }
        }
        control.todosHandler = { [weak self] arg in
            guard let self else { return "error: pane gone" }
            let trimmed = arg.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // Socket threads must not read main-mutated state directly.
                let current = Thread.isMainThread
                    ? self.todos : DispatchQueue.main.sync { self.todos }
                return PaneTodoParser.encode(current)
            }
            guard let todos = PaneTodoParser.parse(trimmed) else {
                return "error: todos expects a JSON array"
            }
            self.setTodos(todos)
            return "ok"
        }
        control.start()
        applyMarkdownConfig(config)
    }

    private var hintEngine: HintEngine?

    /// Push markdown-render settings into the terminal (launch + live reload).
    func applyMarkdownConfig(_ config: AppConfig) {
        terminal.setMarkdownConfig(
            auto: config.markdownRender == "auto", command: config.markdownCommand)
        applyHintConfig(config)
    }

    /// Inline hints: history + CLI specs + a smart async source (Foundation
    /// Models by default, or a configured OpenAI-compatible endpoint / command).
    func applyHintConfig(_ config: AppConfig) {
        guard config.hints else {
            hintEngine = nil
            terminal.setHintProvider(nil)
            return
        }
        let smart = HintEngine.resolveSmart(
            hints: true, hintCommand: config.hintCommand,
            aiBaseURL: config.aiBaseURL, aiKey: config.aiKey, aiModel: config.aiModel)
        let engine = HintEngine(smart: smart)
        engine.onAsyncSuggestion = { [weak self] in
            self?.terminal.refreshHint()
        }
        hintEngine = engine
        terminal.setHintProvider { [weak engine] input in engine?.suggest(input) }
    }

    /// Call once the view is inside a window (display link needs it).
    func launch() {
        guard !launched else { return }
        launched = true
        renderer.attach(view: view, layer: view.metalLayer, terminal: terminal)
        view.window?.layoutIfNeeded()
        let ok = pty.spawn(
            cols: terminal.cols, rows: terminal.rows,
            socketPath: control.path, cwd: workingDirectory)
        guard ok else {
            // Don't crash the whole app on process-table exhaustion; surface
            // a modal and tear the pane down cleanly.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let alert = NSAlert()
                alert.messageText = "Could not open a terminal"
                alert.informativeText =
                    "Failed to spawn a shell (forkpty). Close other terminals or "
                    + "raise the process limit, then try again."
                alert.alertStyle = .warning
                if let win = self.view.window {
                    alert.beginSheetModal(for: win) { _ in }
                } else {
                    alert.runModal()
                }
                self.onExited?(self)
            }
            return
        }
        // Foreground process tracking starts once the shell PID is alive.
        if pty.pid > 0 {
            let tracker = ForegroundProcessTracker(shellPid: pty.pid)
            tracker.start()
            processTracker = tracker
        }
    }

    /// Ask the shell to exit; the EOF path fires onExited for teardown.
    func terminate() {
        if pty.pid > 0 { kill(pty.pid, SIGHUP) }
    }

    /// The pane's live working directory: the foreground process's cwd (the
    /// shell itself at a prompt), probed on demand so it's fresh even between
    /// the tracker's 2s polls. Falls back to the launch directory.
    func currentDirectory() -> String? {
        let pid = processTracker?.current?.pid ?? pty.pid
        if pid > 1, let dir = ForegroundProcessTracker.directory(of: pid) {
            return dir
        }
        return workingDirectory
    }

    /// Release threads and the socket. Idempotent.
    func shutdown() {
        guard !torndown else { return }
        torndown = true
        petAnimator?.stop()
        petAnimator = nil
        processTracker?.stop()
        processTracker = nil
        control.stop()
        terminal.setHintProvider(nil)
        renderer.shutdown()
        if pty.pid > 0 { kill(pty.pid, SIGHUP) }
    }
}
