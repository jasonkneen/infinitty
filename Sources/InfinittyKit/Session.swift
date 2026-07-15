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
    var petAnimator: PetAnimator?
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

        pty.onData = { [terminal] buf, count in terminal.feed(buf, count) }
        pty.onEOF = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.onExited?(self)
            }
        }
        terminal.onOutput = { [pty] bytes in pty.write(bytes) }
        terminal.onChange = { [renderer] in renderer.poke() }
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

    /// Push markdown-render settings into the terminal (launch + live reload).
    func applyMarkdownConfig(_ config: AppConfig) {
        terminal.markdownAuto = config.markdownRender == "auto"
        terminal.markdownCommand = config.markdownCommand
    }

    /// Call once the view is inside a window (display link needs it).
    func launch() {
        guard !launched else { return }
        launched = true
        renderer.attach(view: view, layer: view.metalLayer, terminal: terminal)
        view.window?.layoutIfNeeded()
        pty.spawn(cols: terminal.cols, rows: terminal.rows, socketPath: control.path)
    }

    /// Ask the shell to exit; the EOF path fires onExited for teardown.
    func terminate() {
        if pty.pid > 0 { kill(pty.pid, SIGHUP) }
    }

    /// Release threads and the socket. Idempotent.
    func shutdown() {
        guard !torndown else { return }
        torndown = true
        petAnimator?.stop()
        petAnimator = nil
        control.stop()
        renderer.shutdown()
        if pty.pid > 0 { kill(pty.pid, SIGHUP) }
    }
}
