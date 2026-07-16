import AppKit

/// Manages windows, native tabs, and split panes. Every pane is a
/// self-contained TerminalSession; the delegate only does plumbing.
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    override public init() {
        super.init()
        installTitlebarDoubleClickMonitor()
    }

    /// Install a local mouse monitor that turns double-clicks on an infinitty
    /// window's titlebar into the inline rename UI. (We can't hook the system
    /// tab bar directly — modern macOS native tabs don't expose hit-testing —
    /// but the active tab's title is rendered into the titlebar strip in
    /// both native and bare-titlebar modes, so this is the natural place.)
    private func installTitlebarDoubleClickMonitor() {
        titlebarClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self else { return event }
            guard event.clickCount == 2,
                  let win = event.window,
                  win.tabbingIdentifier == "infinitty",
                  self.eventIsInTitlebar(event, of: win)
            else { return event }
            // Consume the event so the system doesn't also treat it as a
            // window-drag start (native tabs use double-click for nothing,
            // but bare-titlebar drags would otherwise kick off).
            self.beginInlineRename(for: win)
            return nil
        }
    }

    /// True when the mouse event landed in the titlebar/tab strip of `win`,
    /// including the bare-titlebar case where there's no visible strip but
    /// the top inset of the content view occupies the same role.
    private func eventIsInTitlebar(_ event: NSEvent, of win: NSWindow) -> Bool {
        let p = event.locationInWindow
        guard win.frame.contains(p) else { return false }
        let contentTop = win.frame.maxY - win.contentLayoutRect.maxY
        return p.y >= contentTop
    }

    private var config = AppConfig.load()
    private var sessions: [TerminalSession] = []
    private var configWatcher: DispatchSourceFileSystemObject?
    private var reloadPending = false
    private var settings: SettingsWindowController?
    private let notch = NotchActivityController()
    private let appControl = AppControlServer()
    private var runWaiters: [Int: [(Int) -> Void]] = [:] // session id -> completions
    private let updater = Updater()
    private var updateIndicators: [ObjectIdentifier: UpdateIndicatorView] = [:]
    /// Currently visible rename UI, if any. Capped to one at a time so the
    /// gestures can't stack.
    private var activeRename: TabRenameField?
    /// Local mouse monitor that turns titlebar double-clicks into inline rename.
    private var titlebarClickMonitor: Any?
    /// Shell cwd for the first window — set from a folder argv (GitHub
    /// Desktop et al.) before run(), or by an open-folder event that arrives
    /// during launch.
    public var initialWorkingDirectory: String?
    private var launchCompleted = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        appControl.handler = { [weak self] request in
            self?.handleAppRequest(request) ?? "error: shutting down"
        }
        appControl.start()
        openWindow(cwd: initialWorkingDirectory)
        launchCompleted = true
        watchConfigFile()
        if config.notch { notch.show(display: config.notchDisplay) }
        if ProcessInfo.processInfo.environment["INFINITTY_SHOW_SETTINGS"] != nil {
            openSettings(nil) // UI testing hook
        }
        // Background launch: `open -g` or INFINITTY_NO_ACTIVATE keeps focus on
        // whatever you're doing — infinitty runs and is socket-drivable without
        // ever coming to the foreground.
        if ProcessInfo.processInfo.environment["INFINITTY_NO_ACTIVATE"] == nil {
            NSApp.activate(ignoringOtherApps: true)
        }

        // Auto-check for updates (quiet — only lights the top-right indicator),
        // throttled to once per day.
        updater.onUpdateAvailable = { [weak self] release in
            self?.showUpdateIndicator(version: release.version)
        }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        let now = Date().timeIntervalSince1970
        if config.autoUpdate != "off", now - last > 86_400 {
            UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
            updater.check(userInitiated: false)
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updater.check(userInitiated: true)
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString()
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: center,
        ]
        credits.append(NSAttributedString(
            string: "The agent-native GPU terminal for macOS.\nby Jason Kneen\n\n", attributes: base))
        func link(_ text: String, _ url: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .link: url, .font: NSFont.systemFont(ofSize: 11), .paragraphStyle: center,
            ])
        }
        credits.append(link("infinitty.ai", "https://infinitty.ai"))
        credits.append(NSAttributedString(string: "      ", attributes: base))
        credits.append(link("GitHub", "https://github.com/jasonkneen"))
        credits.append(NSAttributedString(string: "      ", attributes: base))
        credits.append(link("X", "https://x.com/jasonkneen"))

        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "infinitty",
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© Jason Kneen",
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showUpdateIndicator(version: String) {
        for win in NSApp.windows where win.tabbingIdentifier == "infinitty" {
            guard let content = win.contentView,
                  updateIndicators[ObjectIdentifier(win)] == nil else { continue }
            let pill = UpdateIndicatorView(version: version)
            pill.onClick = { [weak self] in self?.updater.showPendingPrompt() }
            let topInset = sessions.first { $0.view.window === win }?.renderer.topInsetPoints ?? 0
            pill.place(in: content, topInset: topInset)
            content.addSubview(pill)
            updateIndicators[ObjectIdentifier(win)] = pill
        }
    }

    @objc func openSettings(_ sender: Any?) {
        if settings == nil {
            settings = SettingsWindowController(config: config) { [weak self] newConfig in
                guard let self else { return }
                let path = newConfig.writePath
                let dir = (path as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true)
                try? newConfig.serialize().write(toFile: path, atomically: true, encoding: .utf8)
                self.reloadConfig() // instant apply; also re-arms the watcher
            }
        }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Finder / `open -a Infinitty <folder>` / folder dropped on the Dock
    /// icon: open a tab there (a file opens at its parent directory). Events
    /// that arrive before launch finishes seed the first window instead.
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                continue
            }
            let dir = isDir.boolValue ? url.path : (url.path as NSString).deletingLastPathComponent
            if launchCompleted {
                openTab(cwd: dir)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                initialWorkingDirectory = dir
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        appControl.stop()
        for s in sessions { s.shutdown() }
    }

    // MARK: - session plumbing

    private func createSession(scale: CGFloat) -> TerminalSession {
        let s = TerminalSession(config: config, scale: scale)
        s.control.reloadHandler = { [weak self] in
            DispatchQueue.main.async { self?.reloadConfig() }
        }
        s.onExited = { [weak self] session in self?.sessionDidExit(session) }
        s.onTitleChanged = { [weak self] session in
            guard let win = session.view.window else { return }
            self?.updateTitle(for: win)
            self?.appControl.broadcast(["event": "title", "pane": session.id, "title": session.title])
        }
        s.view.onFocus = { [weak self, weak s] in
            guard let s, let win = s.view.window else { return }
            self?.updateTitle(for: win)
        }
        s.terminal.onMarker = { [weak self, weak s] kind, exit in
            guard let self, let s else { return }
            let command = kind == UInt8(ascii: "C") ? s.terminal.lastCommandLine() : nil
            DispatchQueue.main.async {
                self.notch.handleMarker(kind: kind, exitCode: exit, commandLine: command)
                if kind == UInt8(ascii: "C") {
                    s.petAnimator?.commandStarted()
                    s.processTracker?.poke()
                }
                if kind == UInt8(ascii: "D") {
                    s.petAnimator?.commandEnded(exitCode: exit)
                    for waiter in self.runWaiters.removeValue(forKey: s.id) ?? [] {
                        waiter(exit)
                    }
                    s.processTracker?.poke()
                }
                self.appControl.broadcast([
                    "event": "marker", "pane": s.id,
                    "kind": String(UnicodeScalar(kind)), "exit": exit,
                ])
            }
        }
        sessions.append(s)
        appControl.broadcast(["event": "pane-opened", "pane": s.id])
        return s
    }

    private func focusedSession() -> TerminalSession? {
        guard let win = NSApp.keyWindow,
              let view = win.firstResponder as? TerminalView else { return nil }
        return sessions.first { $0.view === view }
    }

    /// Bring `session`'s pane to the front within its window and make it first
    /// responder. Used by the titlebar process-icon accessory to refocus the
    /// pane the icon is describing after a tab switch.
    private func focusPane(for session: TerminalSession) {
        guard let win = session.view.window else { return }
        win.makeFirstResponder(session.view)
        win.makeKeyAndOrderFront(nil)
    }

    private var titleOverrides: [ObjectIdentifier: String] = [:]
    private var tabIconAccessories: [ObjectIdentifier: TabIconAccessory] = [:]

    /// Tab/window title: custom name if renamed, else the focused pane's
    /// title, plus the pane count when the tab holds more than one shell.
    private func updateTitle(for win: NSWindow) {
        let inWindow = sessions.filter { $0.view.window === win }
        guard !inWindow.isEmpty else { return }
        let base: String
        if let custom = titleOverrides[ObjectIdentifier(win)] {
            base = custom
        } else {
            let focused = inWindow.first { win.firstResponder === $0.view } ?? inWindow[0]
            base = focused.title
        }
        win.title = inWindow.count > 1 ? "\(base) (\(inWindow.count))" : base
        win.subtitle = foregroundProcessInfo(for: win)?.displayName ?? ""
        // also poke the accessory if the title changed in a way that affects it
        tabIconAccessories[ObjectIdentifier(win)]?.refreshFromHost()
    }

    /// The foreground process for the focused pane in `win`, if any session
    /// in the window is currently tracking one.
    func foregroundProcessInfo(for win: NSWindow) -> ForegroundProcessInfo? {
        let inWindow = sessions.filter { $0.view.window === win }
        let focused = inWindow.first { win.firstResponder === $0.view } ?? inWindow.first
        return focused?.processTracker?.current
    }

    /// Returns the user-facing "base" title for a window (the override if set,
    /// otherwise whatever win.title currently shows). The " (N)" suffix that
    /// updateTitle appends for multi-pane windows has already been written to
    /// win.title by the time we look at it, so for the override path we use
    /// the stored bare name; for the auto path we strip any " (N)" tail.
    private func baseTitle(for win: NSWindow) -> String {
        if let override = titleOverrides[ObjectIdentifier(win)] {
            return override
        }
        let t = win.title
        if let r = t.range(of: " \\(\\d+\\)$", options: .regularExpression) {
            return String(t[..<r.lowerBound])
        }
        return t
    }

    @objc func renameTab(_ sender: Any?) {
        guard let win = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.tabbingIdentifier == "infinitty" }),
              win.tabbingIdentifier == "infinitty" else { return }
        beginInlineRename(for: win)
    }

    /// Show the inline rename UI over `win`'s titlebar. If a rename is
    /// already in flight for some other window, commit it and replace it
    /// rather than stack two UIs fighting over first responder.
    func beginInlineRename(for win: NSWindow) {
        // Dismiss any previous rename by committing — the user is now
        // expressing intent on a (possibly different) target.
        activeRename?.dismiss(committed: true)
        activeRename = nil

        // Use the stored override if set, otherwise derive the bare title
        // (stripping any " (N)" pane-count suffix that updateTitle adds).
        let current: String
        if let override = titleOverrides[ObjectIdentifier(win)] {
            current = override
        } else {
            current = self.baseTitle(for: win)
        }
        let field = TabRenameField(hostWindow: win, currentName: current)
        field.onCommit = { [weak self, weak win, weak field] name in
            guard let self, let win else { return }
            if name.isEmpty {
                self.titleOverrides.removeValue(forKey: ObjectIdentifier(win))
            } else {
                self.titleOverrides[ObjectIdentifier(win)] = name
            }
            self.updateTitle(for: win)
            // Clear our ref if the panel still references itself.
            if self.activeRename === field { self.activeRename = nil }
        }
        field.onCancel = { [weak self, weak field] in
            if self?.activeRename === field { self?.activeRename = nil }
        }
        activeRename = field
        field.present()
    }

    /// One pet per window (furthest bottom-right pane) unless pet-mode=pane.
    private func refreshPets() {
        if config.pet == nil || config.petMode == "pane" {
            for s in sessions { applyPet(to: s) }
            return
        }
        var chosen = Set<ObjectIdentifier>()
        let windows = Set(sessions.compactMap { $0.view.window })
        for win in windows {
            let inWindow = sessions.filter { $0.view.window === win }
            let host = inWindow.max { a, b in
                let fa = a.view.convert(a.view.bounds, to: nil)
                let fb = b.view.convert(b.view.bounds, to: nil)
                return (fa.maxX, -fa.minY) < (fb.maxX, -fb.minY)
            }
            if let host { chosen.insert(ObjectIdentifier(host)) }
        }
        for s in sessions {
            if chosen.contains(ObjectIdentifier(s)) {
                applyPet(to: s)
            } else {
                removePet(from: s)
            }
        }
    }

    private func removePet(from session: TerminalSession) {
        session.petAnimator?.stop()
        session.petAnimator = nil
        session.renderer.setPet(texture: nil, sizePoints: 0)
    }

    private func sessionDidExit(_ s: TerminalSession) {
        s.shutdown()
        sessions.removeAll { $0 === s }
        appControl.broadcast(["event": "pane-closed", "pane": s.id])
        runWaiters.removeValue(forKey: s.id)?.forEach { $0(-1) }
        let v = s.view
        guard let win = v.window else { return }

        if let split = v.superview as? NSSplitView {
            v.removeFromSuperview()
            collapse(split, in: win)
            if let next = sessions.first(where: { $0.view.window === win }) {
                win.makeFirstResponder(next.view)
            }
            updateTitle(for: win)
            refreshPets()
        } else {
            win.close() // last pane: closes this window/tab
        }
    }

    /// A split with a single child left dissolves into its parent.
    private func collapse(_ split: NSSplitView, in win: NSWindow) {
        guard split.arrangedSubviews.count == 1 else { return }
        let sibling = split.arrangedSubviews[0]
        sibling.removeFromSuperview()
        if win.contentView === split {
            win.contentView = sibling
        } else if let parent = split.superview as? NSSplitView {
            let idx = parent.arrangedSubviews.firstIndex(of: split) ?? 0
            split.removeFromSuperview()
            parent.insertArrangedSubview(sibling, at: idx)
        } else if let parent = split.superview {
            // blur wrapper or other plain container
            sibling.frame = split.frame
            sibling.autoresizingMask = [.width, .height]
            parent.replaceSubview(split, with: sibling)
        }
    }

    // MARK: - windows & tabs

    private func applyWindowBacking(to window: NSWindow, renderer: Renderer) {
        let translucent = config.backgroundOpacity < 1 || config.backgroundBlur
        window.isOpaque = !translucent

        if translucent {
            // A fully clear backing color can make AppKit briefly substitute
            // an opaque backing store while activating a titled window. Keep
            // a visually imperceptible alpha so the window remains classified
            // as translucent throughout the activation transition.
            window.backgroundColor = .white.withAlphaComponent(0.001)
        } else {
            let bg = renderer.backgroundColor
            window.backgroundColor = NSColor(
                srgbRed: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z), alpha: 1
            )
        }
    }

    @discardableResult
    private func makeTerminalWindow(cwd: String? = nil) -> (NSWindow, TerminalSession) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let session = createSession(scale: scale)
        session.workingDirectory = cwd

        let cell = session.renderer.cellSizePoints
        let inset = session.renderer.insetPoints
        let contentSize = NSSize(
            width: CGFloat(120) * cell.width + inset * 2,
            height: CGFloat(32) * cell.height + inset * 2
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "infinitty"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        applyWindowBacking(to: window, renderer: session.renderer)
        window.contentResizeIncrements = cell
        window.tabbingIdentifier = "infinitty"
        window.delegate = self

        // Titlebar & traffic-light chrome.
        let customLights = config.trafficLights != "circle"
        let bareTitlebar = config.titlebarStyle != "native" || customLights
        if bareTitlebar {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        let hideNative = customLights || config.titlebarStyle == "hidden"
        if hideNative {
            for b: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(b)?.isHidden = true
            }
            // Deliberately NOT isMovableByWindowBackground: it hijacks
            // selection drags. The top titlebar strip still moves the window.
        }
        // Top inset is derived per-layout from contentLayoutRect in
        // TerminalView.updateGeometry (tracks titlebar + tab bar).

        session.view.frame = NSRect(origin: .zero, size: contentSize)
        session.view.autoresizingMask = [.width, .height]
        if config.backgroundBlur {
            let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentSize))
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.addSubview(session.view)
            window.contentView = blur
        } else {
            window.contentView = session.view
        }

        if customLights, let shape = TrafficLightsView.Shape(rawValue: config.trafficLights) {
            let lights = TrafficLightsView(shape: shape)
            var f = lights.frame
            f.origin = NSPoint(x: 12, y: contentSize.height - f.height - 9)
            lights.frame = f
            lights.autoresizingMask = [.minYMargin, .maxXMargin]
            window.contentView?.addSubview(lights)
        }

        window.center()

        // Process-icon accessory: only when the OS titlebar is actually visible.
        // Bare-titlebar modes (transparent / hidden / custom traffic lights) make
        // the titlebar invisible, so an accessory there would either be invisible
        // or, worse, fight with the cell grid.
        let useAccessory = !bareTitlebar && config.titlebarStyle == "native"
        if useAccessory {
            let acc = TabIconAccessory()
            acc.titlebarShowsTitle = true
            acc.onClick = { [weak self, weak session] in
                guard let self, let session else { return }
                self.focusPane(for: session)
            }
            acc.attach(to: window)
            tabIconAccessories[ObjectIdentifier(window)] = acc
        }

        return (window, session)
    }

    private func applyPet(to session: TerminalSession) {
        guard let name = config.pet,
              let texture = Pet.loadTexture(name, device: Renderer.sharedDevice) else {
            removePet(from: session)
            return
        }
        session.renderer.setPet(texture: texture, sizePoints: 192 * config.petScale)
        if session.petAnimator == nil {
            let animator = PetAnimator(terminal: session.terminal, renderer: session.renderer)
            session.petAnimator = animator
            animator.start()
        }
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(cwd: nil)
    }

    @discardableResult
    private func openWindow(cwd: String?) -> TerminalSession {
        let (window, session) = makeTerminalWindow(cwd: cwd)
        window.makeKeyAndOrderFront(nil)
        session.launch()
        DispatchQueue.main.async {
            self.refreshPets()
            self.updateTitle(for: window)
        }
        return session
    }

    /// Human-initiated tab at a directory (open-folder events): joins the
    /// key window, or the first terminal window, and takes focus — unlike
    /// the socket new-tab, which never steals it.
    @discardableResult
    private func openTab(cwd: String?) -> TerminalSession {
        let key = NSApp.keyWindow.flatMap { $0.tabbingIdentifier == "infinitty" ? $0 : nil }
        guard let host = key ?? NSApp.windows.first(where: { $0.tabbingIdentifier == "infinitty" })
        else {
            return openWindow(cwd: cwd)
        }
        let (window, session) = makeTerminalWindow(cwd: cwd)
        host.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        session.launch()
        DispatchQueue.main.async {
            self.refreshPets()
            self.updateTitle(for: window)
        }
        return session
    }

    @objc func newTab(_ sender: Any?) {
        guard let key = NSApp.keyWindow, key.tabbingIdentifier == "infinitty" else {
            newWindow(sender)
            return
        }
        let (window, session) = makeTerminalWindow()
        key.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        session.launch()
        DispatchQueue.main.async {
            self.refreshPets()
            self.updateTitle(for: window)
        }
    }

    /// Enables the "+" button in the native tab bar.
    @objc func newWindowForTab(_ sender: Any?) {
        newTab(sender)
    }

    // MARK: - splits

    @objc func splitRight(_ sender: Any?) {
        split(vertical: true, newFirst: false)
    }

    @objc func splitLeft(_ sender: Any?) {
        split(vertical: true, newFirst: true)
    }

    @objc func splitDown(_ sender: Any?) {
        split(vertical: false, newFirst: false)
    }

    @objc func splitUp(_ sender: Any?) {
        split(vertical: false, newFirst: true)
    }

    private func split(vertical: Bool, newFirst: Bool = false) {
        guard let session = focusedSession() else { return }
        split(session: session, vertical: vertical, newFirst: newFirst)
    }

    private func split(session: TerminalSession, vertical: Bool, newFirst: Bool) {
        guard let win = session.view.window else { return }
        let newSession = createSession(scale: win.backingScaleFactor)

        let old = session.view
        let container = old.superview
        let frame = old.frame

        let splitView = NSSplitView(frame: frame)
        splitView.isVertical = vertical
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]

        if win.contentView === old {
            win.contentView = splitView
        } else if let parent = container as? NSSplitView {
            let idx = parent.arrangedSubviews.firstIndex(of: old) ?? 0
            old.removeFromSuperview()
            parent.insertArrangedSubview(splitView, at: idx)
        } else if let parent = container {
            splitView.frame = old.frame
            parent.replaceSubview(old, with: splitView)
        } else {
            return
        }
        if newFirst {
            splitView.addArrangedSubview(newSession.view)
            splitView.addArrangedSubview(old)
        } else {
            splitView.addArrangedSubview(old)
            splitView.addArrangedSubview(newSession.view)
        }

        DispatchQueue.main.async {
            let mid = vertical ? splitView.bounds.width / 2 : splitView.bounds.height / 2
            splitView.setPosition(mid, ofDividerAt: 0)
            win.makeFirstResponder(newSession.view)
            self.refreshPets()
            self.updateTitle(for: win)
        }
        newSession.launch()
    }

    @objc func closePane(_ sender: Any?) {
        if let session = focusedSession() {
            session.terminate() // EOF path handles pane/tab teardown
        } else {
            NSApp.keyWindow?.performClose(sender)
        }
    }

    @objc func closeWindow(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }

    // MARK: - app control API (external apps / MCP)

    /// Run work on the main thread from a socket thread, with a deadline.
    private func onMain<T>(_ work: @escaping () -> T) -> T? {
        if Thread.isMainThread { return work() }
        var result: T?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            result = work()
            sem.signal()
        }
        return sem.wait(timeout: .now() + 3) == .success ? result : nil
    }

    private func session(withID id: Int) -> TerminalSession? {
        onMain { self.sessions.first { $0.id == id } } ?? nil
    }

    private func handleAppRequest(_ request: String) -> String {
        let parts = request.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let cmd = parts.first.map(String.init) ?? ""
        let arg = parts.count > 1 ? String(parts[1]) : ""

        func paneAndText(_ arg: String) -> (TerminalSession, String)? {
            let sub = arg.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = sub.first, let id = Int(first),
                  let s = session(withID: id) else { return nil }
            return (s, sub.count > 1 ? String(sub[1]) : "")
        }

        switch cmd {
        case "ping":
            return "pong"
        case "version":
            return "infinitty 0.1"
        case "list":
            let panes = onMain { () -> [[String: Any]] in
                let key = NSApp.keyWindow
                return self.sessions.map { s in
                    [
                        "id": s.id,
                        "title": s.title,
                        "windowTitle": s.view.window?.title ?? "",
                        "focused": key?.firstResponder === s.view,
                        "cols": s.terminal.cols,
                        "rows": s.terminal.rows,
                        "socket": s.control.path,
                    ]
                }
            } ?? []
            let data = (try? JSONSerialization.data(withJSONObject: panes)) ?? Data("[]".utf8)
            return String(decoding: data, as: UTF8.self)
        case "new-window":
            let trimmed = arg.trimmingCharacters(in: .whitespaces)
            var cwd: String?
            if !trimmed.isEmpty {
                guard let dir = LaunchOptions.workingDirectory(from: [trimmed]) else {
                    return "error: no such directory: \(trimmed)"
                }
                cwd = dir
            }
            let id = onMain { () -> Int in
                let (window, session) = self.makeTerminalWindow(cwd: cwd)
                // orderFront, NOT makeKey: an agent creating a pane must never
                // steal keyboard focus from whatever the user is typing in.
                window.orderFront(nil)
                session.launch()
                DispatchQueue.main.async {
                    self.refreshPets()
                    self.updateTitle(for: window)
                }
                return session.id
            }
            return id.map(String.init) ?? "error: could not create window"
        case "new-tab":
            let trimmed = arg.trimmingCharacters(in: .whitespaces)
            var cwd: String?
            if !trimmed.isEmpty {
                guard let dir = LaunchOptions.workingDirectory(from: [trimmed]) else {
                    return "error: no such directory: \(trimmed)"
                }
                cwd = dir
            }
            let id = onMain { () -> Int? in
                guard let host = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.tabbingIdentifier == "infinitty" }) else {
                    return nil
                }
                let (window, session) = self.makeTerminalWindow(cwd: cwd)
                host.addTabbedWindow(window, ordered: .above)
                // Do not select/key the new tab — keep the user's focus put.
                session.launch()
                DispatchQueue.main.async {
                    self.refreshPets()
                    self.updateTitle(for: window)
                }
                return session.id
            } ?? nil
            return id.map(String.init) ?? "error: no window to attach a tab to"
        case "split":
            guard let (target, dir) = paneAndText(arg) else { return "error: split <id> right|left|down|up" }
            let direction = dir.trimmingCharacters(in: .whitespaces).lowercased()
            guard ["right", "left", "down", "up"].contains(direction) else {
                return "error: split <id> right|left|down|up"
            }
            let before = onMain { self.sessions.map(\.id) } ?? []
            _ = onMain {
                self.split(
                    session: target,
                    vertical: direction == "right" || direction == "left",
                    newFirst: direction == "left" || direction == "up"
                )
            }
            let after = onMain { self.sessions.map(\.id) } ?? []
            if let newID = after.first(where: { !before.contains($0) }) { return String(newID) }
            return "error: split failed"
        case "focus":
            guard let (s, _) = paneAndText(arg) else { return "error: focus <id>" }
            _ = onMain {
                s.view.window?.makeKeyAndOrderFront(nil)
                s.view.window?.makeFirstResponder(s.view)
                NSApp.activate(ignoringOtherApps: true)
            }
            return "ok"
        case "close":
            guard let (s, _) = paneAndText(arg) else { return "error: close <id>" }
            s.terminate()
            return "ok"
        case "send", "send-line":
            guard let (s, text) = paneAndText(arg) else { return "error: \(cmd) <id> <text>" }
            _ = onMain { s.view.showAgentGlow() }
            s.pty.write(Array(text.utf8) + (cmd == "send-line" ? [0x0D] : []))
            return "ok"
        case "screen":
            guard let (s, _) = paneAndText(arg) else { return "error: screen <id>" }
            return s.terminal.screenText()
        case "history":
            guard let (s, text) = paneAndText(arg) else { return "error: history <id> <n>" }
            let n = min(max(Int(text.trimmingCharacters(in: .whitespaces)) ?? 100, 1), Terminal.maxScrollback)
            return s.terminal.historyText(lines: n)
        case "last-output":
            guard let (s, _) = paneAndText(arg) else { return "error: last-output <id>" }
            return s.terminal.lastCommandOutput() ?? "error: no completed command (enable OSC 133)"
        case "last-command":
            guard let (s, _) = paneAndText(arg) else { return "error: last-command <id>" }
            return s.terminal.lastCommandLine() ?? "error: no command markers (enable OSC 133)"
        case "exit-code":
            guard let (s, _) = paneAndText(arg) else { return "error: exit-code <id>" }
            if let code = s.terminal.lastExitCode() { return String(code) }
            return "error: no completed command (enable OSC 133)"
        case "run":
            // Synchronous run: type the command, wait for its OSC 133 D
            // marker, return JSON with output + exit code.
            guard let (s, text) = paneAndText(arg), !text.isEmpty else {
                return "error: run <id> <command>"
            }
            let sem = DispatchSemaphore(value: 0)
            var exitCode = -1
            _ = onMain {
                self.runWaiters[s.id, default: []].append { code in
                    exitCode = code
                    sem.signal()
                }
                s.view.showAgentGlow()
                s.pty.write(Array(text.utf8) + [0x0D])
            }
            guard sem.wait(timeout: .now() + 120) == .success else {
                _ = onMain { self.runWaiters.removeValue(forKey: s.id) }
                return "error: timed out waiting for completion (is OSC 133 shell integration enabled?)"
            }
            let payload: [String: Any] = [
                "exitCode": exitCode,
                "output": s.terminal.lastCommandOutput() ?? "",
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        case "activity":
            _ = onMain { self.notch.showCustom(text: arg) }
            return "ok"
        default:
            return "error: unknown command '\(cmd)' (ping | version | list | new-window | new-tab | "
                + "split | focus | close | send | send-line | screen | history | last-output | "
                + "last-command | exit-code | run | activity | subscribe)"
        }
    }

    // MARK: - config reload

    @objc func reloadConfiguration(_ sender: Any?) {
        reloadConfig()
    }

    private func reloadConfig() {
        config = AppConfig.load()
        var windows = Set<NSWindow>()
        for s in sessions {
            let scale = s.view.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 2
            s.renderer.applyConfig(config, scale: scale)
            s.applyMarkdownConfig(config)
            s.view.needsLayout = true // re-derives cols/rows from new metrics
            s.terminal.touch()
            if let win = s.view.window { windows.insert(win) }
        }
        for win in windows {
            if let s = sessions.first(where: { $0.view.window === win }) {
                applyWindowBacking(to: win, renderer: s.renderer)
                win.contentResizeIncrements = s.renderer.cellSizePoints
            }
        }
        refreshPets()
        if config.notch { notch.show(display: config.notchDisplay) } else { notch.hide() }
        watchConfigFile() // re-arm (file may have been atomically replaced)
    }

    /// Watch the active config file; editors replace files atomically, so
    /// events re-arm the watcher after a debounced reload.
    private func watchConfigFile() {
        configWatcher?.cancel()
        configWatcher = nil
        guard let path = config.sourcePath else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        configWatcher = src
    }

    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.reloadPending = false
            self?.reloadConfig()
        }
    }

    // MARK: - window delegate

    public func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        // If a rename is currently anchored to this window, cancel it so the
        // monitors and panel don't outlive their host.
        if activeRename != nil {
            activeRename?.dismiss(committed: false)
            activeRename = nil
        }
        titleOverrides.removeValue(forKey: ObjectIdentifier(win))
        tabIconAccessories.removeValue(forKey: ObjectIdentifier(win))?.detach()
        win.subtitle = ""
        let closing = sessions.filter { $0.view.window === win }
        for s in closing { s.shutdown() }
        sessions.removeAll { s in closing.contains { $0 === s } }
    }

    // MARK: - menu

    public static func buildMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About infinitty",
            action: #selector(AppDelegate.showAbout(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(AppDelegate.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(AppDelegate.openSettings(_:)),
            keyEquivalent: ","
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit infinitty",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(AppDelegate.newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Split Right", action: #selector(AppDelegate.splitRight(_:)), keyEquivalent: "d")
        fileMenu.addItem(withTitle: "Split Down", action: #selector(AppDelegate.splitDown(_:)), keyEquivalent: "D")
        fileMenu.addItem(withTitle: "Split Left", action: #selector(AppDelegate.splitLeft(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Split Up", action: #selector(AppDelegate.splitUp(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Rename Tab…", action: #selector(AppDelegate.renameTab(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Reload Configuration", action: #selector(AppDelegate.reloadConfiguration(_:)), keyEquivalent: "r")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Pane", action: #selector(AppDelegate.closePane(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(AppDelegate.closeWindow(_:)), keyEquivalent: "W")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Copy",
            action: #selector(TerminalView.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(TerminalView.paste(_:)),
            keyEquivalent: "v"
        )
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }
}
