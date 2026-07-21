import AppKit

private enum TerminalWindowRole {
    case standard
    case quickTerminal
}

private struct PaneDragState {
    let source: TerminalSession
    let badge: PaneDragBadgeView
    var target: TerminalSession?
    var zone: PaneDropZone?
    var preview: PaneDropPreviewView?
}

private struct PaneZoomState {
    let session: TerminalSession
    let placeholder: NSView
    let overlay: NSView
    let hiddenViews: [TerminalView]
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
            guard event.clickCount == 2,
                  let sourceWindow = event.window,
                  sourceWindow.tabbingIdentifier == "infinitty"
            else { return event }
            // The custom tab strip handles its own double-click rename. Here we
            // only cover a double-click on the native titlebar (single tab, or
            // empty titlebar area) → rename the active tab via the strip.
            guard self.eventIsInTitlebar(event, of: sourceWindow) else { return event }
            self.beginStripRename(for: sourceWindow)
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
            // Digits act only while the hint overlay is up (the documented
            // hold-⇧⌥-then-press flow). A quick ⇧⌥digit chord is text input
            // on many layouts (€, °, …) and must keep reaching the pty.
            guard self.showPaneShortcutHints,
                  let number = PaneNavigation.shortcutNumber(
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
    private var sidebarToggleAccessories: [ObjectIdentifier: SidebarToggleAccessory] = [:]
    /// Per-window terminal chrome (custom tab strip + terminal body). The
    /// window's terminal column lives here; the code-view sidebar is a split
    /// beside it, so the strip never crosses the sidebar.
    private var terminalChromes: [ObjectIdentifier: TerminalChromeView] = [:]
    private var paneDragState: PaneDragState?
    private var paneZoomStates: [ObjectIdentifier: PaneZoomState] = [:]
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
        CodePalette.apply(config)
        openWindow(cwd: initialWorkingDirectory)
        launchCompleted = true
        watchConfigFile()
        configureQuickTerminalHotKey()
        if config.mcpAutoRegister { _ = MCPConfiguration.registerIfNeeded() }
        if config.notch { notch.show(display: config.notchDisplay) }
        if ProcessInfo.processInfo.environment["INFINITTY_SHOW_SETTINGS"] != nil {
            openSettings(nil) // UI testing hook
        }
        // Background launch: `open -g` or INFINITTY_NO_ACTIVATE keeps focus on
        // whatever you're doing — infinitty runs and is socket-drivable without
        // ever coming to the foreground.
        let environment = ProcessInfo.processInfo.environment
        switch ScreenRecordingPermissionAssistant.launchAction(environment: environment) {
        case .showExplicitly:
            DispatchQueue.main.async {
                ScreenRecordingPermissionAssistant.shared.show()
            }
        case .showAutomatically:
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                ScreenRecordingPermissionAssistant.shared.showAutomaticallyIfNeeded()
            }
        case .none:
            break
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

    @objc func showScreenRecordingPermission(_ sender: Any?) {
        ScreenRecordingPermissionAssistant.shared.show()
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
                try? newConfig.saveAll() // writes infinitty.conf + settings.conf
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
        s.view.paneTitle = s.title
        s.control.reloadHandler = { [weak self] in
            DispatchQueue.main.async { self?.reloadConfig() }
        }
        s.onExited = { [weak self] session in self?.sessionDidExit(session) }
        s.onTitleChanged = { [weak self] session in
            guard let win = session.view.window else { return }
            session.view.paneTitle = session.title
            self?.quickTerminal.setTitle(session.title, for: session)
            self?.updateTitle(for: win)
            self?.appControl.broadcast(["event": "title", "pane": session.id, "title": session.title])
        }
        s.view.onFocus = { [weak self, weak s] in
            guard let self, let s, let win = s.view.window else { return }
            self.quickTerminal.setFocusedSession(s)
            self.updateTitle(for: win)
            if let controller = self.codeViews[ObjectIdentifier(win)] {
                controller.track(session: s)
                controller.attachAssistant(self.petAssistant(for: s))
            }
        }
        s.view.onPetClick = { [weak self, weak s] in
            guard let self, let s else { return }
            self.presentPetAssistant(for: s)
        }
        s.view.onSplitRight = { [weak self, weak s] in
            guard let self, let s else { return }
            self.split(session: s, vertical: true, newFirst: false)
        }
        s.view.onSplitDown = { [weak self, weak s] in
            guard let self, let s else { return }
            self.split(session: s, vertical: false, newFirst: false)
        }
        s.view.onTogglePaneZoom = { [weak self, weak s] in
            guard let self, let s else { return }
            self.togglePaneZoom(for: s)
        }
        s.view.onPaneDragBegan = { [weak self, weak s] point in
            guard let self, let s else { return }
            self.beginPaneDrag(source: s, at: point)
        }
        s.view.onPaneDragMoved = { [weak self] point in
            self?.updatePaneDrag(at: point)
        }
        s.view.onPaneDragEnded = { [weak self] point, cancelled in
            self?.endPaneDrag(at: point, cancelled: cancelled)
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
        let root = terminalRoot(of: win)
        if let root { collect(from: root) }
        return views.compactMap { view in sessions.first { $0.view === view } }
    }

    private func setShortcutHintModifiers(_ modifiers: NSEvent.ModifierFlags) {
        let relevant = modifiers.shortcutModifiers
        setHintChordHeld(
            relevant == .command,
            held: \.commandModifierHeld,
            pending: \.pendingTabHint,
            show: \.showTabShortcutHints)
        setHintChordHeld(
            relevant == [.shift, .option],
            held: \.paneModifiersHeld,
            pending: \.pendingPaneHint,
            show: \.showPaneShortcutHints)
    }

    /// Hints appear after a short hold (so plain shortcut chords don't
    /// flash them) and clear the moment the chord is released.
    private func setHintChordHeld(
        _ nowHeld: Bool,
        held: ReferenceWritableKeyPath<AppDelegate, Bool>,
        pending: ReferenceWritableKeyPath<AppDelegate, DispatchWorkItem?>,
        show: ReferenceWritableKeyPath<AppDelegate, Bool>
    ) {
        guard nowHeld != self[keyPath: held] else { return }
        self[keyPath: held] = nowHeld
        self[keyPath: pending]?.cancel()
        self[keyPath: pending] = nil
        if nowHeld {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self[keyPath: held] else { return }
                self[keyPath: show] = true
                self.refreshShortcutHints()
            }
            self[keyPath: pending] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        } else if self[keyPath: show] {
            self[keyPath: show] = false
            refreshShortcutHints()
        }
    }

    /// Tracks whether the last refresh left hint chrome (pane badges, ⌘N
    /// title prefixes) applied somewhere, so the app-wide clearing sweep can
    /// be skipped on the frequent tab/pane churn that happens with no
    /// modifiers held.
    private var shortcutHintsApplied = false

    private func refreshShortcutHints() {
        let showingAny = showTabShortcutHints || showPaneShortcutHints
        guard showingAny || shortcutHintsApplied else { return }
        shortcutHintsApplied = showingAny
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
        if let win = notification.object as? NSWindow,
           win.tabbingIdentifier == "infinitty" {
            refreshTabStrips(in: win)
        }
        guard showPaneShortcutHints else { return }
        refreshShortcutHints()
    }

    @objc func focusPaneLeft(_ sender: Any?) { focusPane(in: .left) }
    @objc func focusPaneRight(_ sender: Any?) { focusPane(in: .right) }
    @objc func focusPaneUp(_ sender: Any?) { focusPane(in: .up) }
    @objc func focusPaneDown(_ sender: Any?) { focusPane(in: .down) }

    private func focusPane(in direction: PaneFocusDirection) {
        guard let target = paneTarget(in: direction) else {
            // The ⇧⌥arrow menu equivalents match even when there is nothing
            // to focus. Terminal panes still own this application shortcut,
            // so suppress it at an edge rather than leaking an escape sequence
            // to the pty. Non-terminal editors retain their selection command.
            if PaneNavigation.shouldForwardUnmatchedArrow(
                terminalHasFocus: NSApp.keyWindow?.firstResponder is TerminalView
            ) {
                forwardCurrentKeyEventToFirstResponder()
            }
            return
        }
        focusPane(for: target)
        if showPaneShortcutHints { refreshShortcutHints() }
        target.view.showFocusHighlight()
    }

    private func paneTarget(in direction: PaneFocusDirection) -> TerminalSession? {
        guard let current = focusedSession(), let win = current.view.window else { return nil }
        let panes = panesInVisualOrder(in: win)
        guard let currentIndex = panes.firstIndex(where: { $0 === current }) else { return nil }
        let frames = panes.map { $0.view.convert($0.view.bounds, to: nil) }
        guard let index = PaneNavigation.targetIndex(
            from: currentIndex, frames: frames, direction: direction)
        else { return nil }
        return panes[index]
    }

    /// A matched menu key equivalent consumes its keyDown even when the
    /// action cannot act. Re-deliver the event to the key window's first
    /// responder so the keystroke is not silently dropped.
    private func forwardCurrentKeyEventToFirstResponder() {
        guard let event = NSApp.currentEvent, event.type == .keyDown,
              let responder = NSApp.keyWindow?.firstResponder
        else { return }
        responder.keyDown(with: event)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        guard let current = NSApp.keyWindow else { return }
        if let quickWindow = quickTerminal.window, current === quickWindow {
            _ = quickTerminal.selectPreviousTab()
            refreshShortcutHints()
            return
        }
        // In a non-tabbed key window (Settings fields, the rename popover)
        // ⇧⌘←/→ is the select-to-line-edge editing command, not tab cycling.
        guard current.tabbingIdentifier == "infinitty" else {
            forwardCurrentKeyEventToFirstResponder()
            return
        }
        selectNativeTab(offset: -1, from: current, sender: sender)
    }

    @objc func selectNextTab(_ sender: Any?) {
        guard let current = NSApp.keyWindow else { return }
        if let quickWindow = quickTerminal.window, current === quickWindow {
            _ = quickTerminal.selectNextTab()
            refreshShortcutHints()
            return
        }
        guard current.tabbingIdentifier == "infinitty" else {
            forwardCurrentKeyEventToFirstResponder()
            return
        }
        selectNativeTab(offset: 1, from: current, sender: sender)
    }

    /// Select native tabs directly instead of calling NSWindow's
    /// selectPreviousTab/selectNextTab actions. Those actions traverse the
    /// responder chain and can route straight back to this delegate selector,
    /// causing unbounded recursion.
    private func selectNativeTab(offset: Int, from current: NSWindow, sender: Any?) {
        let tabs = current.tabbedWindows ?? [current]
        guard let currentIndex = tabs.firstIndex(where: { $0 === current }),
              let targetIndex = TabNavigation.cycledIndex(
                from: currentIndex,
                offset: offset,
                tabCount: tabs.count),
              targetIndex != currentIndex
        else { return }
        let target = tabs[targetIndex]
        current.tabGroup?.selectedWindow = target
        target.makeKeyAndOrderFront(sender)
        refreshShortcutHints()
    }

    @objc func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        if let quickWindow = quickTerminal.window, NSApp.keyWindow === quickWindow {
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
    /// Per-window pin metadata (icon + color). Pinned tabs render as compact
    /// colored icon chips. Keyed by window identity like titleOverrides.
    private var tabPins: [ObjectIdentifier: TerminalTabStripView.Pin] = [:]
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
        // Keep the custom tab strip's labels/selection in sync.
        if let chrome = terminalChromes[ObjectIdentifier(win)], !chrome.strip.isRenaming {
            let tabs = win.tabbedWindows ?? [win]
            if let index = tabs.firstIndex(where: { $0 === win }) {
                chrome.showsStrip = tabs.count > 1
                chrome.strip.update(
                    titles: tabs.map { self.tabTitle(for: $0) }, selectedIndex: index)
            }
        }
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
        guard let win = NSApp.keyWindow
                ?? NSApp.windows.first(where: { $0.tabbingIdentifier == "infinitty" }),
              win === quickTerminal.window || win.tabbingIdentifier == "infinitty"
        else { return }
        if win === quickTerminal.window {
            _ = quickTerminal.toggleRenamingActiveTab()
            return
        }
        // Toggle: a second invocation while editing abandons the edit.
        if let chrome = terminalChromes[ObjectIdentifier(win)], chrome.strip.isRenaming {
            _ = chrome.strip.cancelRename()
            return
        }
        beginStripRename(for: win)
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
        restorePaneZoom(containing: s, refocus: false)
        let wasQuickTerminal = quickTerminal.contains(s)
        let quickTabWasActive = wasQuickTerminal
            && quickTerminal.activeSessions.contains { $0 === s }
        let quickTabSessions = wasQuickTerminal
            ? quickTerminal.sessions(inTabContaining: s)
            : []
        let win = s.view.window
        s.shutdown()
        sessions.removeAll { $0 === s }
        petAssistants.removeValue(forKey: s.id)?.detach()
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
    private func makeTerminalWindow(
        cwd: String? = nil,
        role: TerminalWindowRole = .standard
    ) -> (NSWindow, TerminalSession) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let session = createSession(scale: scale)
        session.workingDirectory = cwd

        let cell = session.renderer.cellSizePoints
        let inset = session.renderer.insetPoints
        let chromeHeight: CGFloat
        switch role {
        case .standard:
            chromeHeight = PaneHeaderView.height + TerminalTabStripView.height
        case .quickTerminal:
            chromeHeight = PaneHeaderView.height
        }
        let contentSize = NSSize(
            width: CGFloat(120) * cell.width + inset * 2,
            height: CGFloat(32) * cell.height + inset * 2 + chromeHeight
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
        applyWindowBacking(to: window, renderer: session.renderer)
        window.contentResizeIncrements = cell
        if role == .standard {
            window.tabbingIdentifier = "infinitty"
            window.delegate = self
        }

        // Standard windows use one compact full-size chrome band: native or
        // custom traffic lights share it with our tab strip.
        let customLights = role == .standard && config.trafficLights != "circle"
        let bareTitlebar = role == .quickTerminal || role == .standard
        if bareTitlebar {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            if #available(macOS 11.0, *) { window.titlebarSeparatorStyle = .none }
        }
        if customLights {
            for b: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(b)?.isHidden = true
            }
            // Deliberately NOT isMovableByWindowBackground: it hijacks selection drags.
        }
        // Top inset is derived per-layout from contentLayoutRect in
        // TerminalView.updateGeometry (tracks titlebar + tab bar).

        session.view.frame = NSRect(origin: .zero, size: contentSize)
        session.view.autoresizingMask = [.width, .height]
        if role == .standard {
            // Standard windows host the terminal inside a chrome view (custom
            // tab strip + body). The native tab bar is hidden; our strip lives
            // over the terminal column only, so the sidebar owns its column.
            let chrome = TerminalChromeView(frame: NSRect(origin: .zero, size: contentSize))
            chrome.autoresizingMask = [.width, .height]
            chrome.sideTabs = config.sideTabs
            chrome.body.addSubview(config.backgroundBlur
                ? wrapInBackgroundBlur(session.view)
                : session.view)
            let bg = session.renderer.backgroundColor
            chrome.setBacking(
                color: NSColor(srgbRed: CGFloat(bg.x), green: CGFloat(bg.y),
                               blue: CGFloat(bg.z), alpha: 1),
                blur: config.backgroundBlur)
            terminalChromes[ObjectIdentifier(window)] = chrome
            wireStrip(chrome, for: window)
            window.contentView = chrome
        } else {
            window.contentView = config.backgroundBlur
                ? wrapInBackgroundBlur(session.view)
                : session.view
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

        // Native titlebar accessories sit above AppKit's tab strip.
        if role == .standard {
            if !customLights {
                let acc = TabIconAccessory()
                acc.titlebarShowsTitle = true
                acc.onClick = { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.focusPane(for: session)
                }
                acc.attach(to: window)
                tabIconAccessories[ObjectIdentifier(window)] = acc
            }
            installSidebarToggle(in: window)
        }

        return (window, session)
    }

    /// Creates a page payload for the existing quick-terminal panel. The
    /// controller wraps this in a stable tab page before launching the shell.
    private func makeQuickTerminalTabContent(
        in window: NSWindow
    ) -> (NSView, TerminalSession) {
        let session = createSession(scale: window.backingScaleFactor)
        // New quick-terminal tabs land in the current tab's live folder.
        let focused = (window.firstResponder as? TerminalView)
            .flatMap { view in sessions.first { $0.view === view } }
        session.workingDirectory = (focused ?? quickTerminal.activeSessions.first)?
            .currentDirectory()
        let size = quickTerminal.activeRootView?.bounds.size
            ?? window.contentView?.bounds.size
            ?? window.contentLayoutRect.size
        session.view.frame = NSRect(origin: .zero, size: size)
        session.view.autoresizingMask = [.width, .height]
        if config.backgroundBlur {
            return (wrapInBackgroundBlur(session.view), session)
        }
        return (session.view, session)
    }

    /// Hosts `view` inside a behind-window blur so translucent backgrounds
    /// pick up the frosted look.
    private func wrapInBackgroundBlur(_ view: NSView) -> NSVisualEffectView {
        let blur = NSVisualEffectView(frame: view.frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        blur.addSubview(view)
        return blur
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
            self.refreshTabStrips(in: window)
        }
        return session
    }

    @objc func newTab(_ sender: Any?) {
        // `===` would also be true with no key window and no quick-terminal
        // panel (nil === nil); Cmd+T must fall through to a new window then.
        if let quickWindow = quickTerminal.window, NSApp.keyWindow === quickWindow {
            _ = quickTerminal.newTab()
            return
        }
        guard let key = NSApp.keyWindow, key.tabbingIdentifier == "infinitty" else {
            newWindow(sender)
            return
        }
        // Inherit the live cwd of the current pane so the new tab lands where
        // the user is working, not back in $HOME.
        let source = focusedSession() ?? activeSessions(in: key).first
        let (window, session) = makeTerminalWindow(cwd: source?.currentDirectory())
        key.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        session.launch()
        DispatchQueue.main.async {
            self.refreshPets()
            self.updateTitle(for: window)
            self.refreshShortcutHints()
            self.refreshTabStrips(in: window)
        }
    }

    /// Enables the "+" button in the native tab bar.
    @objc func newWindowForTab(_ sender: Any?) {
        newTab(sender)
    }

    // MARK: - splits

    @objc func togglePaneZoom(_ sender: Any?) {
        guard let session = focusedSession() else { return }
        togglePaneZoom(for: session)
    }

    private func togglePaneZoom(for session: TerminalSession) {
        guard let win = session.view.window, let root = terminalRoot(of: win) else { return }
        let key = ObjectIdentifier(root)
        if paneZoomStates[key] != nil {
            restorePaneZoom(key: key, refocus: true)
            return
        }

        let panes = activeSessions(in: win).filter {
            $0.view === root || $0.view.isDescendant(of: root)
        }
        guard panes.count > 1, session.view !== root,
              let parent = session.view.superview else { return }

        let placeholder = NSView(frame: session.view.frame)
        placeholder.autoresizingMask = session.view.autoresizingMask
        placeholder.wantsLayer = true
        placeholder.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        guard replaceNode(session.view, with: placeholder, in: parent) else { return }

        let overlay = NSView(frame: root.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        let bg = session.renderer.backgroundColor
        overlay.layer?.backgroundColor = NSColor(
            srgbRed: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z),
            alpha: CGFloat(bg.w)
        ).cgColor
        root.addSubview(overlay, positioned: .above, relativeTo: nil)
        session.view.frame = overlay.bounds
        session.view.autoresizingMask = [.width, .height]
        overlay.addSubview(session.view)

        let hidden = panes.filter { $0 !== session }.map(\.view)
        hidden.forEach { $0.isHidden = true }
        paneZoomStates[key] = PaneZoomState(
            session: session, placeholder: placeholder, overlay: overlay, hiddenViews: hidden)
        win.makeFirstResponder(session.view)
    }

    private func restorePaneZoom(containing session: TerminalSession, refocus: Bool) {
        guard let entry = paneZoomStates.first(where: { $0.value.session === session }) else { return }
        restorePaneZoom(key: entry.key, refocus: refocus)
    }

    private func restorePaneZoom(key: ObjectIdentifier, refocus: Bool) {
        guard let state = paneZoomStates.removeValue(forKey: key),
              let parent = state.placeholder.superview else { return }
        state.session.view.removeFromSuperview()
        _ = replaceNode(state.placeholder, with: state.session.view, in: parent)
        state.hiddenViews.forEach { $0.isHidden = false }
        state.overlay.removeFromSuperview()
        if refocus, let win = state.session.view.window {
            win.makeFirstResponder(state.session.view)
        }
    }

    private func beginPaneDrag(source: TerminalSession, at point: NSPoint) {
        guard paneZoomStates.values.allSatisfy({ $0.session !== source }),
              let win = source.view.window,
              source.view.superview is NSSplitView,
              let content = win.contentView else { return }
        endPaneDrag(at: point, cancelled: true)
        let badge = PaneDragBadgeView(title: source.title)
        content.addSubview(badge, positioned: .above, relativeTo: nil)
        paneDragState = PaneDragState(source: source, badge: badge)
        updatePaneDrag(at: point)
    }

    private func updatePaneDrag(at point: NSPoint) {
        guard var state = paneDragState,
              let win = state.source.view.window,
              let content = win.contentView else { return }
        let contentPoint = content.convert(point, from: nil)
        state.badge.frame.origin = NSPoint(
            x: min(max(contentPoint.x + 12, 4), content.bounds.maxX - state.badge.frame.width - 4),
            y: min(max(contentPoint.y - 12, 4), content.bounds.maxY - state.badge.frame.height - 4))

        let target = activeSessions(in: win).first { candidate in
            guard candidate !== state.source,
                  !candidate.view.isHiddenOrHasHiddenAncestor else { return false }
            let local = candidate.view.convert(point, from: nil)
            return candidate.view.bounds.contains(local)
        }
        let zone = target.map {
            PaneDropZone.resolve(point: $0.view.convert(point, from: nil), in: $0.view.bounds)
        }
        if state.target !== target || state.zone != zone {
            state.preview?.removeFromSuperview()
            state.preview = nil
            if let target, let zone {
                let preview = PaneDropPreviewView(
                    frame: zone.previewFrame(in: target.view.bounds).insetBy(dx: 3, dy: 3))
                preview.autoresizingMask = []
                target.view.addSubview(preview, positioned: .above, relativeTo: nil)
                state.preview = preview
            }
            state.target = target
            state.zone = zone
        }
        paneDragState = state
    }

    private func endPaneDrag(at point: NSPoint, cancelled: Bool) {
        guard let state = paneDragState else { return }
        paneDragState = nil
        state.preview?.removeFromSuperview()
        state.badge.removeFromSuperview()
        guard !cancelled, let target = state.target, let zone = state.zone else { return }
        movePane(state.source, relativeTo: target, zone: zone)
    }

    private func movePane(
        _ source: TerminalSession, relativeTo target: TerminalSession, zone: PaneDropZone
    ) {
        guard source !== target, let win = source.view.window,
              target.view.window === win else { return }
        if zone == .center {
            guard let sourceParent = source.view.superview,
                  let targetParent = target.view.superview else { return }
            let sourcePlaceholder = NSView(frame: source.view.frame)
            let targetPlaceholder = NSView(frame: target.view.frame)
            guard replaceNode(source.view, with: sourcePlaceholder, in: sourceParent),
                  replaceNode(target.view, with: targetPlaceholder, in: targetParent),
                  let sourceSlot = sourcePlaceholder.superview,
                  let targetSlot = targetPlaceholder.superview,
                  replaceNode(sourcePlaceholder, with: target.view, in: sourceSlot),
                  replaceNode(targetPlaceholder, with: source.view, in: targetSlot)
            else { return }
            win.makeFirstResponder(source.view)
            refreshPets()
            refreshShortcutHints()
            return
        }

        guard let sourceSplit = source.view.superview as? NSSplitView else { return }
        source.view.removeFromSuperview()
        collapse(sourceSplit, in: win)
        guard let targetParent = target.view.superview else { return }
        let targetFrame = target.view.frame
        let split = NSSplitView(frame: targetFrame)
        split.isVertical = zone == .left || zone == .right
        split.dividerStyle = .thin
        split.autoresizingMask = target.view.autoresizingMask
        guard replaceNode(target.view, with: split, in: targetParent) else { return }
        if zone == .left || zone == .bottom {
            split.addArrangedSubview(source.view)
            split.addArrangedSubview(target.view)
        } else {
            split.addArrangedSubview(target.view)
            split.addArrangedSubview(source.view)
        }
        DispatchQueue.main.async {
            let mid = split.isVertical ? split.bounds.width / 2 : split.bounds.height / 2
            split.setPosition(mid, ofDividerAt: 0)
            win.makeFirstResponder(source.view)
            self.refreshPets()
            self.updateTitle(for: win)
            self.refreshShortcutHints()
        }
    }

    @discardableResult
    private func replaceNode(_ old: NSView, with new: NSView, in parent: NSView) -> Bool {
        if let split = parent as? NSSplitView {
            guard let index = split.arrangedSubviews.firstIndex(of: old) else { return false }
            old.removeFromSuperview()
            split.insertArrangedSubview(new, at: index)
            return true
        }
        guard old.superview === parent else { return false }
        new.frame = old.frame
        new.autoresizingMask = old.autoresizingMask
        parent.replaceSubview(old, with: new)
        return true
    }

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
        restorePaneZoom(containing: session, refocus: false)
        guard let win = session.view.window else { return }
        let newSession = createSession(scale: win.backingScaleFactor)
        // Splits land in the source pane's live folder, same as new tabs.
        newSession.workingDirectory = session.currentDirectory()

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

    // MARK: - code view

    /// Per-window code-view sidebars, keyed by window identity.
    private var codeViews: [ObjectIdentifier: CodeViewController] = [:]
    private static let codeViewWidth: CGFloat = 280

    @objc func toggleCodeView(_ sender: Any?) {
        guard let win = NSApp.keyWindow else { return }
        toggleCodeView(in: win)
    }

    func toggleCodeView(in win: NSWindow) {
        guard win.tabbingIdentifier == "infinitty",
              win !== quickTerminal.window else { return }
        let id = ObjectIdentifier(win)
        if let controller = codeViews[id] {
            // Hide: unwrap the outer split and put the terminal content back.
            if let split = win.contentView as? NSSplitView,
               let content = split.arrangedSubviews.first(where: { $0 !== controller.view }) {
                split.removeArrangedSubview(content)
                content.removeFromSuperview()
                split.removeArrangedSubview(controller.view)
                controller.view.removeFromSuperview()
                win.contentView = content
            }
            codeViews.removeValue(forKey: id)
            sidebarToggleAccessories[id]?.toggleView.setSidebarVisible(false)
            refocusTerminal(in: win)
            return
        }
        openCodeView(in: win)
    }

    /// The view that hosts a window's terminal panes/splits. For standard
    /// windows that's the chrome body (below the custom tab strip); the
    /// quick terminal uses its own tab page; fall back to contentView.
    private func terminalRoot(of win: NSWindow) -> NSView? {
        if let chrome = terminalChromes[ObjectIdentifier(win)] { return chrome.body }
        if win === quickTerminal.window { return quickTerminal.activeRootView }
        return win.contentView
    }

    /// Refresh the custom tab strip in every window of `win`'s tab group so
    /// each shows the shared title list with its own tab highlighted. Also
    /// hides the native tab bar and toggles strip visibility (hidden for a
    /// single tab, like macOS).
    private func refreshTabStrips(in win: NSWindow) {
        let tabs = win.tabbedWindows ?? [win]
        let titles = tabs.map { self.tabTitle(for: $0) }
        for (index, tabWin) in tabs.enumerated() {
            tabWin.hideNativeTabBar()
            guard let chrome = terminalChromes[ObjectIdentifier(tabWin)] else { continue }
            var pins: [Int: TerminalTabStripView.Pin] = [:]
            for (i, w) in tabs.enumerated() where tabPins[ObjectIdentifier(w)] != nil {
                pins[i] = tabPins[ObjectIdentifier(w)]
            }
            chrome.sideTabs = config.sideTabs
            chrome.showsStrip = tabs.count > 1
            chrome.strip.update(titles: titles, selectedIndex: index, pins: pins)
        }
    }

    private func tabTitle(for win: NSWindow) -> String {
        if let override = titleOverrides[ObjectIdentifier(win)], !override.isEmpty {
            return override
        }
        return activeSessions(in: win).first?.title ?? "infinitty"
    }

    /// Wire a chrome's strip callbacks to native tab-group operations.
    private func wireStrip(_ chrome: TerminalChromeView, for win: NSWindow) {
        chrome.strip.onSelect = { [weak self, weak win] index in
            guard let self, let win, let tabs = win.tabbedWindows,
                  tabs.indices.contains(index) else { return }
            let target = tabs[index]
            win.tabGroup?.selectedWindow = target
            target.makeKeyAndOrderFront(nil)
            self.refocusTerminal(in: target)
        }
        chrome.strip.onRename = { [weak self, weak win] index in
            guard let self, let win, let tabs = win.tabbedWindows,
                  tabs.indices.contains(index) else { return }
            let target = tabs[index]
            win.tabGroup?.selectedWindow = target
            target.makeKeyAndOrderFront(nil)
            self.beginStripRename(for: target)
        }
        chrome.strip.onClose = { [weak win] index in
            guard let win, let tabs = win.tabbedWindows,
                  tabs.indices.contains(index) else { return }
            tabs[index].performClose(nil)
        }
        chrome.strip.onNewTab = { [weak self] in self?.newTab(nil) }
        chrome.strip.onRenameCommit = { [weak self, weak win] name in
            guard let self, let win else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.titleOverrides[ObjectIdentifier(win)] = trimmed.isEmpty ? nil : trimmed
            self.updateTitle(for: win)
            self.refreshTabStrips(in: win)
            self.refocusTerminal(in: win)
        }
        chrome.strip.onRenameCancel = { [weak self, weak win] in
            guard let self, let win else { return }
            self.refocusTerminal(in: win)
        }
        chrome.strip.onReorder = { [weak self, weak win] from, to in
            guard let self, let win, let tabs = win.tabbedWindows,
                  tabs.indices.contains(from), tabs.indices.contains(to),
                  from != to else { return }
            let moving = tabs[from]
            let anchor = tabs[to]
            // Reposition within the native group: re-add the moving window
            // before/after the anchor depending on drag direction.
            moving.tabGroup?.removeWindow(moving)
            anchor.addTabbedWindow(moving, ordered: from < to ? .above : .below)
            win.tabGroup?.selectedWindow = moving
            self.refreshTabStrips(in: win)
        }
        chrome.strip.onTearOut = { [weak self, weak win] index in
            guard let self, let win, let tabs = win.tabbedWindows,
                  tabs.count > 1, tabs.indices.contains(index) else { return }
            let torn = tabs[index]
            torn.tabGroup?.removeWindow(torn)
            torn.makeKeyAndOrderFront(nil)
            var frame = torn.frame
            frame.origin.x += 40
            frame.origin.y -= 40
            torn.setFrame(frame, display: true)
            self.refreshTabStrips(in: win)
            self.refreshTabStrips(in: torn)
            self.refocusTerminal(in: torn)
        }
        chrome.strip.onContextMenu = { [weak self, weak win] index, button in
            guard let self, let win, let tabs = win.tabbedWindows,
                  tabs.indices.contains(index) else { return }
            self.showTabPinMenu(for: tabs[index], anchor: button, host: win)
        }
    }

    /// Context menu for a tab: pin/unpin and pick a pin color.
    private func showTabPinMenu(for tabWin: NSWindow, anchor: NSView, host: NSWindow) {
        let id = ObjectIdentifier(tabWin)
        let menu = NSMenu()
        if tabPins[id] == nil {
            let pin = menu.addItem(withTitle: "Pin Tab", action: #selector(pinTabAction(_:)), keyEquivalent: "")
            pin.target = self
            pin.representedObject = tabWin
        } else {
            let unpin = menu.addItem(withTitle: "Unpin Tab", action: #selector(unpinTabAction(_:)), keyEquivalent: "")
            unpin.target = self
            unpin.representedObject = tabWin
            menu.addItem(.separator())
            let colors: [(String, NSColor)] = [
                ("Indigo", CodePalette.selectionAccent),
                ("Red", .systemRed), ("Orange", .systemOrange),
                ("Green", .systemGreen), ("Blue", .systemBlue),
                ("Purple", .systemPurple), ("Gray", .systemGray),
            ]
            for (name, color) in colors {
                let item = menu.addItem(withTitle: name, action: #selector(setPinColorAction(_:)), keyEquivalent: "")
                item.target = self
                let swatch = NSImage(size: NSSize(width: 12, height: 12))
                swatch.lockFocus()
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
                swatch.unlockFocus()
                item.image = swatch
                item.representedObject = TabPinColorChoice(window: tabWin, color: color)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    }

    private final class TabPinColorChoice: NSObject {
        let window: NSWindow
        let color: NSColor
        init(window: NSWindow, color: NSColor) { self.window = window; self.color = color }
    }

    @objc private func pinTabAction(_ sender: NSMenuItem) {
        guard let win = sender.representedObject as? NSWindow else { return }
        tabPins[ObjectIdentifier(win)] = TerminalTabStripView.Pin(
            icon: "pin.fill", color: CodePalette.selectionAccent)
        refreshTabStrips(in: win)
    }

    @objc private func unpinTabAction(_ sender: NSMenuItem) {
        guard let win = sender.representedObject as? NSWindow else { return }
        tabPins.removeValue(forKey: ObjectIdentifier(win))
        refreshTabStrips(in: win)
    }

    @objc private func setPinColorAction(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? TabPinColorChoice else { return }
        tabPins[ObjectIdentifier(choice.window)] = TerminalTabStripView.Pin(
            icon: "pin.fill", color: choice.color)
        refreshTabStrips(in: choice.window)
    }

    /// Begin an inline rename in the window's own custom strip.
    private func beginStripRename(for win: NSWindow) {
        guard let chrome = terminalChromes[ObjectIdentifier(win)],
              let tabs = win.tabbedWindows,
              let index = tabs.firstIndex(where: { $0 === win }) else { return }
        chrome.showsStrip = true
        chrome.strip.update(
            titles: tabs.map { self.tabTitle(for: $0) }, selectedIndex: index)
        _ = chrome.strip.beginRename(at: index, currentName: tabTitle(for: win))
    }

    /// Open the code-view sidebar in `win` (no-op if already open).
    @discardableResult
    private func openCodeView(in win: NSWindow) -> CodeViewController? {
        let id = ObjectIdentifier(win)
        if let existing = codeViews[id] { return existing }
        guard let content = win.contentView else { return nil }
        let controller = CodeViewController(config: config)
        let split = NSSplitView(frame: NSRect(origin: .zero, size: win.contentLayoutRect.size))
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        win.contentView = split
        split.addArrangedSubview(content)
        split.addArrangedSubview(controller.view)
        // Terminal flexes on window resize; the sidebar holds its width.
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        codeViews[id] = controller
        sidebarToggleAccessories[id]?.toggleView.setSidebarVisible(true)
        let source = focusedSession() ?? activeSessions(in: win).first
        if let source {
            controller.track(session: source)
            controller.attachAssistant(petAssistant(for: source))
        }
        DispatchQueue.main.async {
            split.setPosition(split.bounds.width - Self.codeViewWidth, ofDividerAt: 0)
            self.refocusTerminal(in: win)
        }
        return controller
    }

    func installSidebarToggle(in win: NSWindow) {
        let id = ObjectIdentifier(win)
        if let existing = sidebarToggleAccessories[id] {
            existing.toggleView.setSidebarVisible(codeViews[id] != nil)
            return
        }

        let accessory = SidebarToggleAccessory()
        accessory.toggleView.onClick = { [weak self, weak win] in
            guard let self, let win else { return }
            self.toggleCodeView(in: win)
        }
        accessory.toggleView.setSidebarVisible(codeViews[id] != nil)
        accessory.attach(to: win)
        sidebarToggleAccessories[id] = accessory
    }

    /// Keep keyboard input in the terminal after sidebar toggles.
    private func refocusTerminal(in win: NSWindow) {
        if win.firstResponder is TerminalView { return }
        if let target = activeSessions(in: win).first?.view {
            win.makeFirstResponder(target)
        }
    }

    // MARK: - pet assistant

    /// One assistant per session (kept so the popover survives focus changes).
    private var petAssistants: [Int: PetAssistant] = [:]

    private func petAssistant(for session: TerminalSession) -> PetAssistant {
        if let existing = petAssistants[session.id] { return existing }
        let created = PetAssistant(config: config)
        created.attach(to: session)
        created.onShowInSidePanel = { [weak self] paths, query in
            self?.showAssistantResults(paths, query: query, for: session)
        }
        petAssistants[session.id] = created
        return created
    }

    private func presentPetAssistant(for session: TerminalSession) {
        guard let anchor = session.renderer.petHitRect(in: session.view) else { return }
        petAssistant(for: session).presentInput(anchorRect: anchor, in: session.view)
    }

    /// "Show in Side Panel" from the pet's result bubble: open the code view
    /// if needed and load the assistant's file results into it.
    private func showAssistantResults(
        _ paths: [String], query: String?, for session: TerminalSession
    ) {
        guard let win = session.view.window,
              win.tabbingIdentifier == "infinitty",
              win !== quickTerminal.window else { return }
        guard let controller = openCodeView(in: win) else { return }
        controller.track(session: session)
        controller.attachAssistant(petAssistant(for: session))
        controller.showSearchResults(paths, query: query)
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleCodeView(_:)) {
            let win = NSApp.keyWindow
            let standard = win.flatMap {
                $0.tabbingIdentifier == "infinitty" && $0 !== quickTerminal.window ? $0 : nil
            }
            item.state = standard.flatMap { codeViews[ObjectIdentifier($0)] } != nil ? .on : .off
            return standard != nil
        }
        return true
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
                    self.refreshTabStrips(in: window)
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
        case "toggle-sidebar":
            _ = onMain {
                if let win = NSApp.keyWindow
                    ?? NSApp.windows.first(where: { $0.tabbingIdentifier == "infinitty" }) {
                    self.toggleCodeView(in: win)
                }
            }
            return "ok"
        case "sidebar":
            // sidebar show|hide|toggle — explicit control of the code sidebar
            // so an agent can drive its own interface, not just flip it.
            let action = arg.trimmingCharacters(in: .whitespaces).lowercased()
            guard ["show", "hide", "toggle", ""].contains(action) else {
                return "error: sidebar show|hide|toggle"
            }
            _ = onMain {
                guard let win = NSApp.keyWindow
                    ?? NSApp.windows.first(where: { $0.tabbingIdentifier == "infinitty" }) else { return }
                let id = ObjectIdentifier(win)
                switch action {
                case "show": _ = self.openCodeView(in: win)
                case "hide": if self.codeViews[id] != nil { self.toggleCodeView(in: win) }
                default: self.toggleCodeView(in: win)
                }
            }
            return "ok"
        case "sidebar-tab":
            // sidebar-tab files|changes|chat — switch the sidebar page,
            // opening the sidebar first if it's closed.
            let name = arg.trimmingCharacters(in: .whitespaces).lowercased()
            guard ["files", "changes", "git", "chat"].contains(name) else {
                return "error: sidebar-tab files|changes|chat"
            }
            let ok = onMain { () -> Bool in
                guard let win = NSApp.keyWindow
                    ?? NSApp.windows.first(where: { $0.tabbingIdentifier == "infinitty" }),
                      let controller = self.openCodeView(in: win) else { return false }
                return controller.selectPage(named: name)
            } ?? false
            return ok ? "ok" : "error: could not switch sidebar tab"
        case "chat-model", "chat-effort":
            // chat-model <name> | chat-effort <auto|low|medium|high> — let the
            // agent change its own chat model / reasoning depth. Opens the
            // sidebar chat first so the composer exists.
            let value = arg.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return "error: \(cmd) <value>" }
            let ok = onMain { () -> Bool in
                guard let win = NSApp.keyWindow
                    ?? NSApp.windows.first(where: { $0.tabbingIdentifier == "infinitty" }),
                      let controller = self.openCodeView(in: win) else { return false }
                _ = controller.selectPage(named: "chat")
                return cmd == "chat-model"
                    ? controller.setChatModel(value)
                    : controller.setChatEffort(value)
            } ?? false
            return ok ? "ok" : "error: no match for \(cmd) '\(value)'"
        default:
            return "error: unknown command '\(cmd)' (ping | version | list | new-window | new-tab | "
                + "split | focus | close | send | send-line | screen | history | last-output | "
                + "last-command | exit-code | run | activity | toggle-quick-terminal | toggle-sidebar | "
                + "sidebar | sidebar-tab | chat-model | chat-effort | subscribe)"
        }
    }

    // MARK: - config reload

    private func configureQuickTerminalHotKey() {
        guard let value = config.quickTerminalKey, !value.isEmpty else {
            quickTerminalHotKey = nil
            return
        }
        guard let spec = GlobalHotKeySpec.parse(value) else {
            quickTerminalHotKey = nil
            let message = "infinitty: invalid quick-terminal-key '\(value)'\n"
            FileHandle.standardError.write(Data(message.utf8))
            return
        }
        // Config reloads fire on every file write; keep the live Carbon
        // registration when the shortcut is unchanged.
        if quickTerminalHotKey?.spec == spec { return }
        quickTerminalHotKey = nil // unregister before claiming the new combo
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
        CodePalette.apply(config)
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

    /// Veto tab/window closes while a pane still runs a process: closing
    /// terminates it, so confirm first.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.tabbingIdentifier == "infinitty",
              sender !== quickTerminal.window else { return true }
        let running = ForegroundProcessTracker.runningProcesses(
            in: activeSessions(in: sender))
        guard !running.isEmpty else { return true }
        let alert = ForegroundProcessTracker.closeConfirmationAlert(
            for: running.map(\.info))
        return alert.runModal() == .alertSecondButtonReturn
    }

    public func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        if paneDragState?.source.view.window === win {
            endPaneDrag(at: .zero, cancelled: true)
        }
        let zoomKeys = paneZoomStates.compactMap { key, value in
            value.session.view.window === win || value.overlay.window === win ? key : nil
        }
        zoomKeys.forEach { restorePaneZoom(key: $0, refocus: false) }
        // Cancel any in-flight tab rename in this window's strip.
        terminalChromes[ObjectIdentifier(win)]?.strip.cancelRename()
        titleOverrides.removeValue(forKey: ObjectIdentifier(win))
        tabIconAccessories.removeValue(forKey: ObjectIdentifier(win))?.detach()
        codeViews.removeValue(forKey: ObjectIdentifier(win))
        sidebarToggleAccessories.removeValue(forKey: ObjectIdentifier(win))?.detach()
        terminalChromes.removeValue(forKey: ObjectIdentifier(win))
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
        let zoomPane = fileMenu.addItem(
            withTitle: "Toggle Pane Zoom",
            action: #selector(AppDelegate.togglePaneZoom(_:)),
            keyEquivalent: "\r")
        zoomPane.keyEquivalentModifierMask = [.command, .shift]
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

        let codeViewItem = windowMenu.addItem(
            withTitle: "Code View",
            action: #selector(AppDelegate.toggleCodeView(_:)),
            keyEquivalent: "e")
        codeViewItem.keyEquivalentModifierMask = [.command, .shift]

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
        // above uses physical number-key codes for that keyboard path and
        // only consumes the event while the hold-⇧⌥ hint overlay is up and a
        // pane selection can actually be performed; a bare ⇧⌥digit chord
        // stays text input for the pty.
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
