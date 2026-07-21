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
            NSSound.beep()
            DispatchQueue.main.async { self?.petAnimator?.bell() }
        }

        control.activityHandler = { [weak view] in
            DispatchQueue.main.async { view?.showAgentGlow() }
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
        engine.onAsyncSuggestion = { [weak self] in self?.terminal.touch() }
        hintEngine = engine
        terminal.setHintProvider { [weak engine] input in engine?.suggest(input) }
    }

    /// Call once the view is inside a window (display link needs it).
    func launch() {
        guard !launched else { return }
        launched = true
        renderer.attach(view: view, layer: view.metalLayer, terminal: terminal)
        view.window?.layoutIfNeeded()
        pty.spawn(
            cols: terminal.cols, rows: terminal.rows,
            socketPath: control.path, cwd: workingDirectory)
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
