import AppKit

private enum TerminalWindowRole {
    case standard
    case quickTerminal
}

/// Manages windows, native tabs, and split panes. Every pane is a
/// self-contained TerminalSession; the delegate only does plumbing.
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    override public init() {
        super.init()
        installTitlebarDoubleClickMonitor()
        installModifierHintMonitor()
    }

    /// Install a local mouse monitor that turns a native-tab double-click (or
    /// a single-window titlebar double-click) into the rename UI.
    private func installTitlebarDoubleClickMonitor() {
        titlebarClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self else { return event }
            guard event.clickCount == 2, let sourceWindow = event.window else { return event }

            let screenPoint = sourceWindow.convertPoint(toScreen: event.locationInWindow)
            let normalWindows = NSApp.windows.filter { $0.tabbingIdentifier == "infinitty" }
            for host in normalWindows {
                guard let hit = host.nativeTabButton(atScreenPoint: screenPoint),
                      let tabs = host.tabbedWindows,
                      tabs.indices.contains(hit.index)
                else { continue }
                let target = tabs[hit.index]
                host.tabGroup?.selectedWindow = target
                target.makeKeyAndOrderFront(nil)
                DispatchQueue.main.async { [weak self, weak target] in
                    guard let self, let target else { return }
                    self.beginInlineRename(for: target)
                }
                return nil
            }

            // No native tab button means this is a single-window/bare-titlebar
            // layout. Preserve the documented titlebar double-click gesture.
            guard sourceWindow.tabbingIdentifier == "infinitty",
                  sourceWindow.nativeTabButtonsInVisualOrder().isEmpty,
                  self.eventIsInTitlebar(event, of: sourceWindow)
            else { return event }
            self.beginInlineRename(for: sourceWindow)
            return nil
        }
    }

    private func installModifierHintMonitor() {
        modifierHintMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.setShortcutHintModifiers(event.modifierFlags)
            return event
        }
        paneShortcutKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            if let offset = TabNavigation.cycleOffset(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags),
               NSApp.keyWindow?.firstResponder is TerminalView {
                if offset < 0 {
                    self.selectPreviousTab(event)
                } else {
                    self.selectNextTab(event)
                }
                return nil
            }
            guard let number = PaneNavigation.shortcutNumber(
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags)
            else { return event }
            return self.selectPane(number: number, requireTerminalFocus: true) ? nil : event
        }
    }

    /// True when the mouse event landed in the titlebar/tab strip of `win`,
    /// including the bare-titlebar case where there's no visible strip but
    /// the top inset of the content view occupies the same role.
    private func eventIsInTitlebar(_ event: NSEvent, of win: NSWindow) -> Bool {
        let p = event.locationInWindow
        guard p.x >= 0, p.x <= win.frame.width,
              p.y >= 0, p.y <= win.frame.height
        else { return false }
        let contentTop = win.contentLayoutRect.maxY
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
    private var quickTerminalHotKey: GlobalHotKey?
    private lazy var quickTerminal: QuickTerminalController = {
        let controller = QuickTerminalController(
            config: config,
            makeWindow: { [weak self] in
                self?.makeTerminalWindow(role: .quickTerminal)
            },
            makeTab: { [weak self] window in
                self?.makeQuickTerminalTabContent(in: window)
            },
            sessionsInPage: { [weak self] page in
                self?.sessions.filter {
                    $0.view === page || $0.view.isDescendant(of: page)
                } ?? []
            })
        controller.onTabsChanged = { [weak self, weak controller] in
            guard let self, let window = controller?.window else { return }
            self.updateTitle(for: window)
            self.refreshPets()
            self.refreshShortcutHints()
        }
        return controller
    }()
    /// Currently visible rename UI, if any. Capped to one at a time so the
    /// gestures can't stack.
    private var activeRename: TabRenameField?
    /// Local mouse monitor that turns titlebar double-clicks into inline rename.
    private var titlebarClickMonitor: Any?
    private var modifierHintMonitor: Any?
    private var paneShortcutKeyMonitor: Any?
    private var commandModifierHeld = false
    private var paneModifiersHeld = false
    private var showTabShortcutHints = false
    private var showPaneShortcutHints = false
    private var pendingTabHint: DispatchWorkItem?
    private var pendingPaneHint: DispatchWorkItem?
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
        configureQuickTerminalHotKey()
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
        // Keep a hidden session alive even when it is controlled only through
        // the menu or socket rather than a registered global shortcut.
        QuickTerminalResidency.shouldTerminateAfterLastWindowClosed(
            hasRegisteredHotKey: quickTerminalHotKey != nil,
            hasLiveSession: quickTerminal.hasLiveSession)
    }

    public func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            openWindow(cwd: nil)
            return false
        }
        return true
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
        quickTerminalHotKey = nil
        pendingTabHint?.cancel()
        pendingPaneHint?.cancel()
        if let titlebarClickMonitor { NSEvent.removeMonitor(titlebarClickMonitor) }
        if let modifierHintMonitor { NSEvent.removeMonitor(modifierHintMonitor) }
        if let paneShortcutKeyMonitor { NSEvent.removeMonitor(paneShortcutKeyMonitor) }
        appControl.stop()
        for s in sessions { s.shutdown() }
    }

    public func applicationWillResignActive(_ notification: Notification) {
        setShortcutHintModifiers([])
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
            self?.quickTerminal.setTitle(session.title, for: session)
            self?.updateTitle(for: win)
            self?.appControl.broadcast(["event": "title", "pane": session.id, "title": session.title])
        }
        s.view.onFocus = { [weak self, weak s] in
            guard let s, let win = s.view.window else { return }
            self?.quickTerminal.setFocusedSession(s)
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

    private func activeSessions(in win: NSWindow) -> [TerminalSession] {
        if win === quickTerminal.window { return quickTerminal.activeSessions }
        return sessions.filter { $0.view.window === win }
    }

    /// Bring `session`'s pane to the front within its window and make it first
    /// responder. Used by the titlebar process-icon accessory to refocus the
    /// pane the icon is describing after a tab switch.
    private func focusPane(for session: TerminalSession) {
        guard let win = session.view.window else { return }
        win.makeFirstResponder(session.view)
        win.makeKeyAndOrderFront(nil)
    }

    private func panesInVisualOrder(in win: NSWindow) -> [TerminalSession] {
        var views: [TerminalView] = []
        func collect(from view: NSView) {
            if let terminal = view as? TerminalView {
                views.append(terminal)
                return
            }
            if let split = view as? NSSplitView {
                split.arrangedSubviews.forEach { collect(from: $0) }
            } else {
                view.subviews.forEach { collect(from: $0) }
            }
        }
        let root = win === quickTerminal.window
            ? quickTerminal.activeRootView
            : win.contentView
        if let root { collect(from: root) }
        return views.compactMap { view in sessions.first { $0.view === view } }
    }

    private func setShortcutHintModifiers(_ modifiers: NSEvent.ModifierFlags) {
        let relevant = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        let tabHints = relevant == .command
        let paneHints = relevant == [.shift, .option]
        if tabHints != commandModifierHeld {
            commandModifierHeld = tabHints
            pendingTabHint?.cancel()
            pendingTabHint = nil
            if tabHints {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.commandModifierHeld else { return }
                    self.showTabShortcutHints = true
                    self.refreshShortcutHints()
                }
                pendingTabHint = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            } else if showTabShortcutHints {
                showTabShortcutHints = false
                refreshShortcutHints()
            }
        }
        if paneHints != paneModifiersHeld {
            paneModifiersHeld = paneHints
            pendingPaneHint?.cancel()
            pendingPaneHint = nil
            if paneHints {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.paneModifiersHeld else { return }
                    self.showPaneShortcutHints = true
                    self.refreshShortcutHints()
                }
                pendingPaneHint = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            } else if showPaneShortcutHints {
                showPaneShortcutHints = false
                refreshShortcutHints()
            }
        }
    }

    private func refreshShortcutHints() {
        var windows: [NSWindow] = []
        var seen = Set<ObjectIdentifier>()
        for session in sessions {
            session.view.setPaneShortcutHint(number: nil)
            session.view.setPaneShortcutSelectionHighlighted(false)
            if let win = session.view.window,
               seen.insert(ObjectIdentifier(win)).inserted {
                windows.append(win)
            }
        }
        windows.forEach(updateTitle)

        guard showPaneShortcutHints, let win = NSApp.keyWindow else { return }
        for (index, pane) in panesInVisualOrder(in: win).prefix(9).enumerated() {
            pane.view.setPaneShortcutHint(number: index + 1)
        }
        (win.firstResponder as? TerminalView)?
            .setPaneShortcutSelectionHighlighted(true)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        guard showPaneShortcutHints else { return }
        refreshShortcutHints()
    }

    @objc func focusPaneLeft(_ sender: Any?) { focusPane(in: .left) }
    @objc func focusPaneRight(_ sender: Any?) { focusPane(in: .right) }
    @objc func focusPaneUp(_ sender: Any?) { focusPane(in: .up) }
    @objc func focusPaneDown(_ sender: Any?) { focusPane(in: .down) }

    private func focusPane(in direction: PaneFocusDirection) {
        guard let current = focusedSession(), let win = current.view.window else { return }
        let panes = panesInVisualOrder(in: win)
        guard let currentIndex = panes.firstIndex(where: { $0 === current }) else { return }
        let frames = panes.map { $0.view.convert($0.view.bounds, to: nil) }
        guard let target = PaneNavigation.targetIndex(
            from: currentIndex, frames: frames, direction: direction)
        else { return }
        focusPane(for: panes[target])
        if showPaneShortcutHints { refreshShortcutHints() }
        panes[target].view.showFocusHighlight()
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        if NSApp.keyWindow === quickTerminal.window {
            _ = quickTerminal.selectPreviousTab()
            refreshShortcutHints()
            return
        }
        NSApp.keyWindow?.selectPreviousTab(sender)
        DispatchQueue.main.async { self.refreshShortcutHints() }
    }

    @objc func selectNextTab(_ sender: Any?) {
        if NSApp.keyWindow === quickTerminal.window {
            _ = quickTerminal.selectNextTab()
            refreshShortcutHints()
            return
        }
        NSApp.keyWindow?.selectNextTab(sender)
        DispatchQueue.main.async { self.refreshShortcutHints() }
    }

    @objc func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        if NSApp.keyWindow === quickTerminal.window {
            _ = quickTerminal.selectTab(shortcutNumber: item.tag)
            refreshShortcutHints()
            return
        }
        guard
              let current = NSApp.keyWindow,
              current.tabbingIdentifier == "infinitty" else { return }
        let tabs = current.tabbedWindows ?? [current]
        guard let index = TabNavigation.index(for: item.tag, tabCount: tabs.count) else { return }
        let target = tabs[index]
        current.tabGroup?.selectedWindow = target
        target.makeKeyAndOrderFront(sender)
        refreshShortcutHints()
    }

    @objc func selectPaneByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        _ = selectPane(number: item.tag)
    }

    @discardableResult
    private func selectPane(number: Int, requireTerminalFocus: Bool = false) -> Bool {
        guard let win = NSApp.keyWindow else { return false }
        let panes = panesInVisualOrder(in: win)
        let index = requireTerminalFocus
            ? PaneNavigation.shortcutTargetIndex(
                for: number,
                paneCount: panes.count,
                terminalHasFocus: win.firstResponder is TerminalView)
            : PaneNavigation.index(for: number, paneCount: panes.count)
        guard let index else { return false }
        focusPane(for: panes[index])
        if showPaneShortcutHints { refreshShortcutHints() }
        panes[index].view.showFocusHighlight()
        return true
    }

    private var titleOverrides: [ObjectIdentifier: String] = [:]
    private var tabIconAccessories: [ObjectIdentifier: TabIconAccessory] = [:]

    /// Tab/window title: custom name if renamed, else the focused pane's
    /// title, plus the pane count when the tab holds more than one shell.
    private func updateTitle(for win: NSWindow) {
        let inWindow = activeSessions(in: win)
        guard !inWindow.isEmpty else { return }
        if win === quickTerminal.window {
            let focused = inWindow.first { win.firstResponder === $0.view } ?? inWindow[0]
            quickTerminal.setTitle(focused.title, for: focused)
            quickTerminal.setShowsShortcutHints(showTabShortcutHints)
            win.title = quickTerminal.activeTabID
                .flatMap { quickTerminal.displayTitle(for: $0) }
                ?? focused.title
            win.subtitle = foregroundProcessInfo(for: win)?.displayName ?? ""
            return
        }

        let base: String
        if let custom = titleOverrides[ObjectIdentifier(win)] {
            base = custom
        } else {
            let focused = inWindow.first { win.firstResponder === $0.view } ?? inWindow[0]
            base = focused.title
        }
        let hintedBase: String
        if showTabShortcutHints,
           let tabs = win.tabbedWindows,
           let index = tabs.firstIndex(where: { $0 === win }),
           let number = TabNavigation.shortcutNumber(
                forTabIndex: index, tabCount: tabs.count) {
            hintedBase = "⌘\(number) \(base)"
        } else {
            hintedBase = base
        }
        win.title = inWindow.count > 1 ? "\(hintedBase) (\(inWindow.count))" : hintedBase
        win.subtitle = foregroundProcessInfo(for: win)?.displayName ?? ""
        // also poke the accessory if the title changed in a way that affects it
        tabIconAccessories[ObjectIdentifier(win)]?.refreshFromHost()
    }

    /// The foreground process for the focused pane in `win`, if any session
    /// in the window is currently tracking one.
    func foregroundProcessInfo(for win: NSWindow) -> ForegroundProcessInfo? {
        let inWindow = activeSessions(in: win)
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
        var t = win.title
        if let r = t.range(of: "^⌘[1-9] ", options: .regularExpression) {
            t.removeSubrange(r)
        }
        if let r = t.range(of: " \\(\\d+\\)$", options: .regularExpression) {
            return String(t[..<r.lowerBound])
        }
        return t
    }

    @objc func renameTab(_ sender: Any?) {
        // Treat the shortcut as a mode toggle. Repeating it while an editor
        // is open abandons the pending value instead of replacing the editor.
        if let activeRename {
            activeRename.dismiss(committed: false)
            self.activeRename = nil
            return
        }
        guard let win = NSApp.keyWindow
                ?? NSApp.windows.first(where: { $0.tabbingIdentifier == "infinitty" }),
              win === quickTerminal.window || win.tabbingIdentifier == "infinitty"
        else { return }
        if win === quickTerminal.window {
            _ = quickTerminal.toggleRenamingActiveTab()
            return
        }
        beginInlineRename(for: win)
    }

    /// Show the inline rename UI over `win`'s titlebar. If a rename is
    /// already in flight for some other window, cancel it and replace it
    /// rather than stack two UIs fighting over first responder.
    func beginInlineRename(for win: NSWindow) {
        // A new rename supersedes any unfinished edit without saving it.
        activeRename?.dismiss(committed: false)
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
            guard let self else { return }
            if self.activeRename === field { self.activeRename = nil }
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
            let inWindow = activeSessions(in: win)
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
        let wasQuickTerminal = quickTerminal.contains(s)
        let quickTabWasActive = wasQuickTerminal
            && quickTerminal.activeSessions.contains { $0 === s }
        let quickTabSessions = wasQuickTerminal
            ? quickTerminal.sessions(inTabContaining: s)
            : []
        let win = s.view.window
        s.shutdown()
        sessions.removeAll { $0 === s }
        appControl.broadcast(["event": "pane-closed", "pane": s.id])
        runWaiters.removeValue(forKey: s.id)?.forEach { $0(-1) }
        let v = s.view
        guard let win else { return }

        if wasQuickTerminal, quickTabSessions.count == 1 {
            _ = quickTerminal.removeTab(containing: s)
            refreshPets()
            refreshShortcutHints()
            return
        }

        if let split = v.superview as? NSSplitView {
            v.removeFromSuperview()
            collapse(split, in: win)
            let next: TerminalSession?
            if wasQuickTerminal {
                next = quickTabWasActive
                    ? quickTabSessions.first { $0 !== s }
                    : nil
            } else {
                next = activeSessions(in: win).first
            }
            if let next {
                win.makeFirstResponder(next.view)
            }
            updateTitle(for: win)
            refreshPets()
            refreshShortcutHints()
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

    @discardableResult
    private func makeTerminalWindow(
        cwd: String? = nil,
        role: TerminalWindowRole = .standard
    ) -> (NSWindow, TerminalSession) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let session = createSession(scale: scale)
        session.workingDirectory = cwd

        let cell = session.renderer.cellSizePoints
        let inset = session.renderer.insetPoints
        let contentSize = NSSize(
            width: CGFloat(120) * cell.width + inset * 2,
            height: CGFloat(32) * cell.height + inset * 2
        )
        let contentRect = NSRect(origin: .zero, size: contentSize)
        let window: NSWindow
        switch role {
        case .standard:
            window = NSWindow(
                contentRect: contentRect,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
        case .quickTerminal:
            window = QuickTerminalPanel(
                contentRect: contentRect,
                styleMask: [.borderless, .resizable, .nonactivatingPanel],
                backing: .buffered,
                defer: false)
        }
        window.title = "infinitty"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let bg = session.renderer.backgroundColor
        window.backgroundColor = NSColor(
            srgbRed: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z), alpha: 1
        )
        window.contentResizeIncrements = cell
        if role == .standard {
            window.tabbingIdentifier = "infinitty"
            window.delegate = self
        }

        // Titlebar & traffic-light chrome.
        let customLights = role == .standard && config.trafficLights != "circle"
        let bareTitlebar = role == .quickTerminal
            || config.titlebarStyle != "native" || customLights
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

        // Transparency / frosted blur.
        if config.backgroundOpacity < 1 || config.backgroundBlur {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
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

        if role == .standard { window.center() }

        // Process-icon accessory: only when the OS titlebar is actually visible.
        // Bare-titlebar modes (transparent / hidden / custom traffic lights) make
        // the titlebar invisible, so an accessory there would either be invisible
        // or, worse, fight with the cell grid.
        let useAccessory = role == .standard
            && !bareTitlebar && config.titlebarStyle == "native"
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

    /// Creates a page payload for the existing quick-terminal panel. The
    /// controller wraps this in a stable tab page before launching the shell.
    private func makeQuickTerminalTabContent(
        in window: NSWindow
    ) -> (NSView, TerminalSession) {
        let session = createSession(scale: window.backingScaleFactor)
        let size = quickTerminal.activeRootView?.bounds.size
            ?? window.contentView?.bounds.size
            ?? window.contentLayoutRect.size
        session.view.frame = NSRect(origin: .zero, size: size)
        session.view.autoresizingMask = [.width, .height]
        if config.backgroundBlur {
            let blur = NSVisualEffectView(frame: session.view.frame)
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            blur.addSubview(session.view)
            return (blur, session)
        }
        return (session.view, session)
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
            self.refreshShortcutHints()
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
            self.refreshShortcutHints()
        }
        return session
    }

    @objc func newTab(_ sender: Any?) {
        if NSApp.keyWindow === quickTerminal.window {
            _ = quickTerminal.newTab()
            return
        }
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
            self.refreshShortcutHints()
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
            self.refreshShortcutHints()
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
        if NSApp.keyWindow === quickTerminal.window {
            quickTerminal.hide()
            return
        }
        NSApp.keyWindow?.performClose(sender)
    }

    @objc func toggleQuickTerminal(_ sender: Any?) {
        quickTerminal.toggle()
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
                    self.refreshShortcutHints()
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
                let key = NSApp.keyWindow.flatMap {
                    $0.tabbingIdentifier == "infinitty" ? $0 : nil
                }
                guard let host = key ?? NSApp.windows.first(where: { $0.tabbingIdentifier == "infinitty" }) else {
                    return nil
                }
                let (window, session) = self.makeTerminalWindow(cwd: cwd)
                host.addTabbedWindow(window, ordered: .above)
                // Do not select/key the new tab — keep the user's focus put.
                session.launch()
                DispatchQueue.main.async {
                    self.refreshPets()
                    self.updateTitle(for: window)
                    self.refreshShortcutHints()
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
                if self.quickTerminal.contains(s) {
                    _ = self.quickTerminal.focus(s)
                } else {
                    s.view.window?.makeKeyAndOrderFront(nil)
                    s.view.window?.makeFirstResponder(s.view)
                    NSApp.activate(ignoringOtherApps: true)
                }
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
        case "toggle-quick-terminal":
            _ = onMain { self.quickTerminal.toggle() }
            return "ok"
        default:
            return "error: unknown command '\(cmd)' (ping | version | list | new-window | new-tab | "
                + "split | focus | close | send | send-line | screen | history | last-output | "
                + "last-command | exit-code | run | activity | toggle-quick-terminal | subscribe)"
        }
    }

    // MARK: - config reload

    private func configureQuickTerminalHotKey() {
        quickTerminalHotKey = nil
        guard let value = config.quickTerminalKey, !value.isEmpty else { return }
        guard let spec = GlobalHotKeySpec.parse(value) else {
            let message = "infinitty: invalid quick-terminal-key '\(value)'\n"
            FileHandle.standardError.write(Data(message.utf8))
            return
        }
        quickTerminalHotKey = GlobalHotKey(spec: spec) { [weak self] in
            self?.quickTerminal.toggle()
        }
        if quickTerminalHotKey == nil {
            let message = "infinitty: quick-terminal-key '\(value)' is unavailable or already in use\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    @objc func reloadConfiguration(_ sender: Any?) {
        reloadConfig()
    }

    private func reloadConfig() {
        config = AppConfig.load()
        quickTerminal.applyConfig(config)
        configureQuickTerminalHotKey()
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
                let bg = s.renderer.backgroundColor
                win.backgroundColor = NSColor(
                    srgbRed: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z), alpha: 1)
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
        fileMenu.addItem(
            withTitle: "Toggle Quick Terminal",
            action: #selector(AppDelegate.toggleQuickTerminal(_:)),
            keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Split Right", action: #selector(AppDelegate.splitRight(_:)), keyEquivalent: "d")
        fileMenu.addItem(withTitle: "Split Down", action: #selector(AppDelegate.splitDown(_:)), keyEquivalent: "D")
        fileMenu.addItem(withTitle: "Split Left", action: #selector(AppDelegate.splitLeft(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Split Up", action: #selector(AppDelegate.splitUp(_:)), keyEquivalent: "")
        let renameTab = fileMenu.addItem(
            withTitle: "Rename Tab…",
            action: #selector(AppDelegate.renameTab(_:)),
            keyEquivalent: "t")
        renameTab.keyEquivalentModifierMask = [.command, .shift]
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
        windowMenu.addItem(.separator())

        let previousTab = windowMenu.addItem(
            withTitle: "Previous Tab",
            action: #selector(AppDelegate.selectPreviousTab(_:)),
            keyEquivalent: "\u{F702}")
        previousTab.keyEquivalentModifierMask = [.command, .shift]
        let nextTab = windowMenu.addItem(
            withTitle: "Next Tab",
            action: #selector(AppDelegate.selectNextTab(_:)),
            keyEquivalent: "\u{F703}")
        nextTab.keyEquivalentModifierMask = [.command, .shift]

        let selectTabItem = NSMenuItem(title: "Select Tab", action: nil, keyEquivalent: "")
        let selectTabMenu = NSMenu(title: "Select Tab")
        for number in 1...9 {
            let title = number == 9 ? "Last Tab" : "Tab \(number)"
            let item = selectTabMenu.addItem(
                withTitle: title,
                action: #selector(AppDelegate.selectTabByNumber(_:)),
                keyEquivalent: String(number))
            item.tag = number
        }
        selectTabItem.submenu = selectTabMenu
        windowMenu.addItem(selectTabItem)

        let focusPaneItem = NSMenuItem(title: "Focus Pane", action: nil, keyEquivalent: "")
        let focusPaneMenu = NSMenu(title: "Focus Pane")
        let paneBindings: [(String, Selector, String)] = [
            ("Left", #selector(AppDelegate.focusPaneLeft(_:)), "\u{F702}"),
            ("Right", #selector(AppDelegate.focusPaneRight(_:)), "\u{F703}"),
            ("Up", #selector(AppDelegate.focusPaneUp(_:)), "\u{F700}"),
            ("Down", #selector(AppDelegate.focusPaneDown(_:)), "\u{F701}"),
        ]
        for (title, action, key) in paneBindings {
            let item = focusPaneMenu.addItem(
                withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.shift, .option]
        }
        focusPaneMenu.addItem(.separator())
        // AppKit displays these equivalents in the menu, but shifted Option
        // digits become symbols before menu matching. The local key monitor
        // above uses physical number-key codes for that keyboard path and only
        // consumes the event when a pane selection can be performed.
        for number in 1...9 {
            let item = focusPaneMenu.addItem(
                withTitle: "Pane \(number)",
                action: #selector(AppDelegate.selectPaneByNumber(_:)),
                keyEquivalent: String(number))
            item.tag = number
            item.keyEquivalentModifierMask = [.shift, .option]
        }
        focusPaneItem.submenu = focusPaneMenu
        windowMenu.addItem(focusPaneItem)
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }
}
