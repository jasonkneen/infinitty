import AppKit

private enum TerminalWindowRole {
    case standard
    case quickTerminal
}

private struct PaneDragState {
    let sourceView: NSView
    let title: String
    let badge: PaneDragBadgeView
    var targetView: NSView?
    var zone: PaneDropZone?
    var preview: PaneDropPreviewView?
}

private struct PaneZoomState {
    let pane: NSView
    let root: NSView
    let dividerRatios: PaneLayoutController.DividerRatios
    let maximizedRatios: PaneLayoutController.DividerRatios
    let collapsedViews: [NSView]
}

struct PaneDividerKeyframe {
    let split: NSSplitView
    let start: [CGFloat]
    let end: [CGFloat]
}

/// `NSSplitView.setPosition` is not implicitly animatable. Drive the divider
/// model values directly so panes physically displace one another every frame.
final class PaneDividerAnimation {
    private let keyframes: [PaneDividerKeyframe]
    private let duration: TimeInterval
    private let completion: () -> Void
    private var timer: Timer?
    private var startedAt: TimeInterval = 0

    init(
        keyframes: [PaneDividerKeyframe], duration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        self.keyframes = keyframes
        self.duration = duration
        self.completion = completion
    }

    func start() {
        cancel()
        startedAt = ProcessInfo.processInfo.systemUptime
        apply(progress: 0)
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let linear = min(max(elapsed / duration, 0), 1)
        let eased = linear < 0.5
            ? 4 * linear * linear * linear
            : 1 - pow(-2 * linear + 2, 3) / 2
        apply(progress: CGFloat(eased))
        if linear >= 1 {
            cancel()
            completion()
        }
    }

    private func apply(progress: CGFloat) {
        for keyframe in keyframes
        where keyframe.split.superview != nil
            && keyframe.start.count == keyframe.end.count {
            for index in keyframe.start.indices {
                let start = keyframe.start[index]
                let position = start + (keyframe.end[index] - start) * progress
                keyframe.split.setPosition(position, ofDividerAt: index)
            }
        }
    }

    deinit { cancel() }
}

private final class UtilityPanelRecord {
    /// Files and Chat use the shared code/chat controller. Browser is a
    /// native WebKit surface with its own controller, but both remain pane
    /// leaves governed by the same lifecycle and ledger.
    let controller: CodeViewController?
    let browser: BrowserPaneController?
    let pane: UtilityPaneView
    /// Chat is a tab-level surface. Keep its assistant alive if the terminal
    /// it started from exits while the Chat leaf remains visible.
    var assistant: PetAssistant?

    init(controller: CodeViewController, pane: UtilityPaneView) {
        self.controller = controller
        self.browser = nil
        self.pane = pane
    }

    init(browser: BrowserPaneController, pane: UtilityPaneView) {
        self.controller = nil
        self.browser = browser
        self.pane = pane
    }
}

/// A socket request can outlive its caller while WebKit waits on a consent
/// sheet. This token makes completion/cancellation one-way, so a late Allow
/// cannot execute an abandoned browser operation.
private final class BrowserControlOperation {
    private let lock = NSLock()
    private var ended = false

    func claimCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return false }
        ended = true
        return true
    }

    func cancel() {
        lock.lock()
        ended = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }
}

/// Manages windows, native tabs, and split panes. Every pane is a
/// self-contained TerminalSession; the delegate only does plumbing.
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    override public init() {
        super.init()
        installTitlebarDoubleClickMonitor()
        installModifierHintMonitor()
        installForegroundProcessMonitor()
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
    /// Durable, per-main-tab history for tracking pane structural changes
    /// across a crash. IDs are intentionally app-assigned rather than raw
    /// object pointers so successive records can be correlated.
    private let paneLifecycleLedger = PaneLifecycleLedger()
    private var paneLedgerTabIDs: [ObjectIdentifier: String] = [:]
    private var paneLedgerSessionTabs: [Int: String] = [:]
    private var nextPaneLedgerTabID = 1
    private var configWatcher: DispatchSourceFileSystemObject?
    private var reloadPending = false
    private var settings: SettingsWindowController?
    private let notch = NotchActivityController()
    private let appControl = AppControlServer()
    private var runWaiters: [Int: [(Int) -> Void]] = [:] // session id -> completions
    private var pendingLaunchCommands: [Int: String] = [:]
    private let updater = Updater()
    private var updateIndicators: [ObjectIdentifier: UpdateIndicatorView] = [:]
    private var sidebarToggleAccessories: [ObjectIdentifier: SidebarToggleAccessory] = [:]
    /// Per-window terminal chrome (custom tab strip + terminal body). The
    /// window's terminal column lives here; the code-view sidebar is a split
    /// beside it, so the strip never crosses the sidebar.
    private var terminalChromes: [ObjectIdentifier: TerminalChromeView] = [:]
    private var lastSelectedTabIndex: [ObjectIdentifier: Int] = [:]
    private var paneDragState: PaneDragState?
    private var paneZoomStates: [ObjectIdentifier: PaneZoomState] = [:]
    private var paneZoomRestoreStates: [ObjectIdentifier: PaneZoomState] = [:]
    private var paneDividerAnimations: [ObjectIdentifier: PaneDividerAnimation] = [:]
    private var pendingSplitContext: (sourceView: NSView, vertical: Bool)?
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
    private var foregroundProcessObserver: NSObjectProtocol?
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
        paneLifecycleLedger.start()
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
        configureSessionNotch()
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
        if let foregroundProcessObserver {
            NotificationCenter.default.removeObserver(foregroundProcessObserver)
        }
        appControl.stop()
        // `shutdown()` stops PTYs without necessarily calling `onExited`, so
        // close registered main tabs explicitly before emitting the clean end
        // marker. Otherwise a normal quit would resemble a crash in the log.
        for win in NSApp.windows where paneLedgerTabIDs[ObjectIdentifier(win)] != nil {
            closePaneLedgerTab(
                for: win, reason: "application-terminate", origin: "application-terminate")
        }
        for s in sessions { s.shutdown() }
        paneLifecycleLedger.finish()
    }

    public func applicationWillResignActive(_ notification: Notification) {
        setShortcutHintModifiers([])
    }

    // MARK: - session plumbing

    private func createSession(
        scale: CGFloat,
        usesSharedWindowSurface: Bool = false
    ) -> TerminalSession {
        let s = TerminalSession(config: config, scale: scale)
        if usesSharedWindowSurface {
            s.renderer.setUsesSharedWindowSurface(true)
        }
        s.view.paneTitle = s.title
        s.control.reloadHandler = { [weak self] in
            DispatchQueue.main.async { self?.reloadConfig() }
        }
        s.onExited = { [weak self] session in self?.sessionDidExit(session) }
        s.onTitleChanged = { [weak self] session in
            guard let win = session.view.window else { return }
            session.view.paneTitle = self?.paneHeaderTitle(for: session) ?? session.title
            self?.quickTerminal.setTitle(session.title, for: session)
            self?.updateTitle(for: win)
            self?.appControl.broadcast(["event": "title", "pane": session.id, "title": session.title])
        }
        s.view.onFocus = { [weak self, weak s] in
            guard let self, let s, let win = s.view.window else { return }
            self.updatePaneSelection(in: win, focused: s.view)
            self.quickTerminal.setFocusedSession(s)
            self.updateTitle(for: win)
            self.rebindUtilityPanels(to: s, in: win)
        }
        s.view.onPetClick = { [weak self, weak s] in
            guard let self, let s else { return }
            self.presentPetAssistant(for: s)
        }
        s.view.onSplitRight = { [weak self, weak s] in
            guard let self, let s else { return }
            self.splitTerminal(relativeTo: s.view, vertical: true)
        }
        s.view.onSplitDown = { [weak self, weak s] in
            guard let self, let s else { return }
            self.splitTerminal(relativeTo: s.view, vertical: false)
        }
        s.view.onChooseSplitRight = { [weak self, weak s] in
            guard let self, let s else { return }
            self.showSplitChooser(sourceView: s.view, vertical: true)
        }
        s.view.onChooseSplitDown = { [weak self, weak s] in
            guard let self, let s else { return }
            self.showSplitChooser(sourceView: s.view, vertical: false)
        }
        s.view.onTogglePaneZoom = { [weak self, weak s] in
            guard let self, let s else { return }
            self.togglePaneZoom(for: s)
        }
        s.view.onPaneDragBegan = { [weak self, weak s] point in
            guard let self, let s else { return }
            self.beginPaneDrag(sourceView: s.view, title: s.title, at: point)
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
                if kind == UInt8(ascii: "A") || kind == UInt8(ascii: "B") {
                    self.flushPendingLaunchCommand(for: s)
                }
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

    private func installForegroundProcessMonitor() {
        foregroundProcessObserver = NotificationCenter.default.addObserver(
            forName: ForegroundProcessTracker.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let tracker = notification.object as? ForegroundProcessTracker,
                  let session = self.sessions.first(where: { $0.processTracker === tracker })
            else { return }
            session.view.paneTitle = self.paneHeaderTitle(for: session)
            if let win = session.view.window {
                self.updateTitle(for: win)
                self.refreshTabStrips(in: win)
            }
        }
    }

    private func paneHeaderTitle(for session: TerminalSession) -> String {
        guard let process = session.processTracker?.current,
              process.pid != session.pty.pid else { return session.title }
        return "\(session.title) — \(process.displayName)"
    }

    private func focusedSession() -> TerminalSession? {
        guard let win = NSApp.keyWindow else { return nil }
        return focusedSession(in: win)
    }

    private func focusedSession(in win: NSWindow) -> TerminalSession? {
        guard let view = win.firstResponder as? TerminalView else { return nil }
        return sessions.first { $0.view === view }
    }

    private func activeSessions(in win: NSWindow) -> [TerminalSession] {
        if win === quickTerminal.window { return quickTerminal.activeSessions }
        return sessions.filter { $0.view.window === win }
    }

    // MARK: - pane lifecycle ledger

    /// Each standard NSWindow is one native main tab. Keep an app-assigned ID
    /// for its whole lifetime so the structural log is not tied to a reused
    /// memory address or window number.
    private func paneLedgerTabID(
        for win: NSWindow, createIfNeeded: Bool = false
    ) -> String? {
        let key = ObjectIdentifier(win)
        if let id = paneLedgerTabIDs[key] { return id }
        guard createIfNeeded, win.tabbingIdentifier == "infinitty" else { return nil }
        let id = "tab-\(nextPaneLedgerTabID)"
        nextPaneLedgerTabID += 1
        paneLedgerTabIDs[key] = id
        return id
    }

    private func paneLedgerTerminalID(_ session: TerminalSession) -> String {
        "terminal:\(session.id)"
    }

    private func paneLedgerPaneID(
        for view: NSView,
        exitingSession: TerminalSession? = nil
    ) -> String {
        if let terminal = view as? TerminalView {
            if let exitingSession, terminal === exitingSession.view {
                return paneLedgerTerminalID(exitingSession)
            }
            if let session = sessions.first(where: { $0.view === terminal }) {
                return paneLedgerTerminalID(session)
            }
        }
        if let utility = view as? UtilityPaneView { return utility.kind.rawValue }
        return "unknown"
    }

    private func paneLedgerTopology(
        in win: NSWindow,
        exitingSession: TerminalSession? = nil
    ) -> String {
        guard let root = terminalRoot(of: win) else { return "-" }
        func describe(_ view: NSView) -> String {
            if let split = view as? NSSplitView {
                let axis = split.isVertical ? "V" : "H"
                return "\(axis)[\(split.arrangedSubviews.map(describe).joined(separator: ","))]"
            }
            if view is TerminalView || view is UtilityPaneView {
                return paneLedgerPaneID(for: view, exitingSession: exitingSession)
            }
            let children = view.subviews
            if children.count == 1 { return describe(children[0]) }
            return children.isEmpty
                ? "container"
                : "container[\(children.map(describe).joined(separator: ","))]"
        }
        return describe(root)
    }

    private func registerPaneLedgerTab(for win: NSWindow, session: TerminalSession) {
        let key = ObjectIdentifier(win)
        let hadTabID = paneLedgerTabIDs[key] != nil
        guard let tabID = paneLedgerTabID(for: win, createIfNeeded: true) else { return }
        if !hadTabID {
            paneLifecycleLedger.openTab(
                tabID, reason: "main-tab-created", origin: "window-factory",
                topology: paneLedgerTopology(in: win))
        }
        paneLedgerSessionTabs[session.id] = tabID
        paneLifecycleLedger.addPane(
            tabID: tabID, paneID: paneLedgerTerminalID(session), reason: "initial-pane",
            origin: "window-factory", topology: paneLedgerTopology(in: win))
    }

    private func recordPaneLedgerTerminalAdded(
        _ session: TerminalSession,
        in win: NSWindow,
        reason: String,
        origin: String,
        sourceView: NSView,
        vertical: Bool
    ) {
        guard let tabID = paneLedgerTabID(for: win) else { return }
        paneLedgerSessionTabs[session.id] = tabID
        paneLifecycleLedger.addPane(
            tabID: tabID, paneID: paneLedgerTerminalID(session), reason: reason, origin: origin,
            sourcePaneID: paneLedgerPaneID(for: sourceView),
            axis: vertical ? "vertical" : "horizontal", topology: paneLedgerTopology(in: win))
    }

    private func recordPaneLedgerTerminalRemoved(
        _ session: TerminalSession,
        in win: NSWindow?,
        reason: String,
        origin: String
    ) {
        guard let tabID = paneLedgerSessionTabs.removeValue(forKey: session.id) else { return }
        paneLifecycleLedger.removePane(
            tabID: tabID, paneID: paneLedgerTerminalID(session), reason: reason, origin: origin,
            topology: win.map { paneLedgerTopology(in: $0, exitingSession: session) } ?? "-")
    }

    private func recordPaneLedgerUtilityAdded(
        _ kind: UtilityPanelKind,
        in win: NSWindow,
        reason: String,
        origin: String,
        sourceView: NSView?,
        vertical: Bool
    ) {
        guard let tabID = paneLedgerTabID(for: win) else { return }
        paneLifecycleLedger.addPane(
            tabID: tabID, paneID: kind.rawValue, reason: reason, origin: origin,
            sourcePaneID: sourceView.map { paneLedgerPaneID(for: $0) },
            axis: sourceView == nil ? nil : (vertical ? "vertical" : "horizontal"),
            topology: paneLedgerTopology(in: win))
    }

    private func recordPaneLedgerUtilityRemoved(
        _ kind: UtilityPanelKind,
        in win: NSWindow,
        reason: String,
        origin: String
    ) {
        guard let tabID = paneLedgerTabID(for: win) else { return }
        paneLifecycleLedger.removePane(
            tabID: tabID, paneID: kind.rawValue, reason: reason, origin: origin,
            topology: paneLedgerTopology(in: win))
    }

    private func recordPaneLedgerNote(
        in win: NSWindow,
        paneID: String? = nil,
        reason: String,
        origin: String,
        sourcePaneID: String? = nil,
        axis: String? = nil
    ) {
        guard let tabID = paneLedgerTabID(for: win) else { return }
        paneLifecycleLedger.note(
            tabID: tabID, paneID: paneID, reason: reason, origin: origin,
            sourcePaneID: sourcePaneID, axis: axis, topology: paneLedgerTopology(in: win))
    }

    private func recordPaneLedgerFailure(
        in win: NSWindow,
        paneID: String? = nil,
        reason: String,
        origin: String
    ) {
        guard let tabID = paneLedgerTabID(for: win) else { return }
        paneLifecycleLedger.failure(
            tabID: tabID, paneID: paneID, reason: reason, origin: origin,
            topology: paneLedgerTopology(in: win))
    }

    private func closePaneLedgerTab(
        for win: NSWindow,
        reason: String,
        origin: String
    ) {
        let key = ObjectIdentifier(win)
        guard let tabID = paneLedgerTabIDs[key] else { return }
        paneLifecycleLedger.closeTab(
            tabID, reason: reason, origin: origin, topology: paneLedgerTopology(in: win))
        paneLedgerTabIDs.removeValue(forKey: key)
        let sessionIDs = paneLedgerSessionTabs.compactMap { id, mappedTabID in
            mappedTabID == tabID ? id : nil
        }
        for sessionID in sessionIDs { paneLedgerSessionTabs.removeValue(forKey: sessionID) }
    }

    /// Bring `session`'s pane to the front within its window and make it first
    /// responder after tab or pane navigation.
    private func focusPane(for session: TerminalSession) {
        restorePaneZoom(revealing: session.view)
        guard let win = session.view.window else { return }
        win.tabGroup?.selectedWindow = win
        win.makeFirstResponder(session.view)
        win.makeKeyAndOrderFront(nil)
    }

    private func focusSession(_ session: TerminalSession) {
        restorePaneZoom(revealing: session.view)
        if quickTerminal.contains(session) {
            _ = quickTerminal.focus(session)
        } else {
            focusPane(for: session)
            NSApp.activate(ignoringOtherApps: true)
        }
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

    private func paneLeafViews(in win: NSWindow) -> [NSView] {
        var result: [NSView] = []
        func collect(_ view: NSView) {
            if view is TerminalView || view is UtilityPaneView {
                result.append(view)
                return
            }
            if let split = view as? NSSplitView {
                split.arrangedSubviews.forEach(collect)
            } else {
                view.subviews.forEach(collect)
            }
        }
        if let root = terminalRoot(of: win) { collect(root) }
        return result
    }

    /// A surviving Chat owns its conversation at the main-tab level. If its
    /// source terminal exits, preserve the assistant through the close; a
    /// remaining or newly-created terminal rebinds it below.
    private func retainChatAssistantAfterTerminalExit(
        _ assistant: PetAssistant?, in win: NSWindow
    ) {
        guard let assistant else { return }
        guard let chat = utilityPanels[ObjectIdentifier(win)]?[.chat],
              chat.assistant === assistant
        else {
            assistant.detach()
            return
        }
        assistant.detach()
    }

    /// Utility panes follow the terminal that remains in their native tab.
    /// This keeps file tracking current and reconnects the retained Chat
    /// assistant after a sibling terminal closes.
    private func rebindUtilityPanels(to session: TerminalSession, in win: NSWindow) {
        guard let panels = utilityPanels[ObjectIdentifier(win)] else { return }
        for record in panels.values { record.controller?.track(session: session) }
        guard let chat = panels[.chat] else { return }
        let assistant = chat.assistant ?? petAssistant(for: session)
        rehomeAssistant(assistant, to: session)
        chat.assistant = assistant
        chat.controller?.attachAssistant(assistant)
    }

    private func focusedPaneLeaf(in win: NSWindow) -> NSView? {
        guard let responder = win.firstResponder as? NSView else {
            return focusedSession(in: win)?.view
        }
        return paneLeafViews(in: win).first {
            responder === $0 || responder.isDescendant(of: $0)
        }
    }

    private func updatePaneSelection(in win: NSWindow, focused: NSView?) {
        for pane in paneLeafViews(in: win) {
            let selected = pane === focused
            (pane as? TerminalView)?.setPaneSelected(selected)
            (pane as? UtilityPaneView)?.setPaneSelected(selected)
        }
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
    private func positionNativeTrafficLights(in window: NSWindow) {
        guard config.trafficLights == "circle",
              let chrome = terminalChromes[ObjectIdentifier(window)]
        else { return }
        chrome.layoutSubtreeIfNeeded()
        let stripCenterInWindow = chrome.strip.convert(
            NSPoint(x: chrome.strip.bounds.midX, y: chrome.strip.bounds.midY), to: nil)
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type),
                  let parent = button.superview else { continue }
            let stripCenter = parent.convert(stripCenterInWindow, from: nil)
            var frame = button.frame
            frame.origin.y = stripCenter.y - frame.height / 2
            button.frame = frame
        }
    }

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
            positionNativeTrafficLights(in: win)
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
    /// Independent per-tab tint. It survives unpinning and drives both the
    /// full-width active tab and every pane card inside that tab.
    private var tabTints: [ObjectIdentifier: NSColor] = [:]

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
        // Keep the custom tab strip's labels/selection in sync.
        if let chrome = terminalChromes[ObjectIdentifier(win)], !chrome.strip.isRenaming {
            let tabs = win.tabbedWindows ?? [win]
            if let index = tabs.firstIndex(where: { $0 === win }) {
                let presentation = tabPresentation(for: tabs)
                chrome.showsStrip = true
                chrome.strip.update(
                    titles: tabs.map { self.tabTitle(for: $0) }, selectedIndex: index,
                    pins: presentation.pins, icons: presentation.icons,
                    tints: presentation.tints)
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
        pendingLaunchCommands.removeValue(forKey: s.id)
        sessions.removeAll { $0 === s }
        let exitingAssistant = petAssistants.removeValue(forKey: s.id)
        appControl.broadcast(["event": "pane-closed", "pane": s.id])
        runWaiters.removeValue(forKey: s.id)?.forEach { $0(-1) }
        let v = s.view
        guard let win else {
            exitingAssistant?.detach()
            recordPaneLedgerTerminalRemoved(
                s, in: nil, reason: "terminal-exit", origin: "pty-eof")
            return
        }

        if wasQuickTerminal, quickTabSessions.count == 1 {
            exitingAssistant?.detach()
            _ = quickTerminal.removeTab(containing: s)
            refreshPets()
            refreshShortcutHints()
            return
        }

        if let split = v.superview as? NSSplitView {
            v.removeFromSuperview()
            collapse(split, in: win)
        } else {
            v.removeFromSuperview()
        }

        if !wasQuickTerminal {
            recordPaneLedgerTerminalRemoved(
                s, in: win, reason: "terminal-exit", origin: "pty-eof")
        }

        let next: TerminalSession?
        if wasQuickTerminal {
            next = quickTabWasActive ? quickTabSessions.first { $0 !== s } : nil
        } else {
            next = activeSessions(in: win).first
        }
        retainChatAssistantAfterTerminalExit(exitingAssistant, in: win)
        if let next {
            rebindUtilityPanels(to: next, in: win)
            win.makeFirstResponder(next.view)
        } else {
            if let remainingPane = paneLeafViews(in: win).first {
                win.makeFirstResponder(remainingPane)
                updatePaneSelection(in: win, focused: remainingPane)
            }
        }

        // A terminal is not the lifetime owner of a tab. Keep any Files,
        // Chat, Browser, or future smart pane alive; only the final pane leaf
        // closes this native main tab.
        if !wasQuickTerminal,
           PaneLifecyclePolicy.shouldCloseTab(remainingPaneCount: paneLeafViews(in: win).count) {
            win.close()
            return
        }

        updateTitle(for: win)
        refreshPets()
        refreshShortcutHints()
    }

    /// A split with a single child left dissolves into its parent.
    private func collapse(_ split: NSSplitView, in win: NSWindow) {
        guard split.arrangedSubviews.count == 1 else { return }
        let sibling = split.arrangedSubviews[0]
        if win.contentView === split {
            // Keep a real content view in place while the survivor leaves the
            // old split. This mirrors PaneLayoutController's root safeguard.
            let placeholder = NSView(frame: split.frame)
            placeholder.autoresizingMask = split.autoresizingMask
            win.contentView = placeholder
            sibling.removeFromSuperview()
            sibling.frame = placeholder.frame
            sibling.autoresizingMask = placeholder.autoresizingMask
            win.contentView = sibling
        } else {
            // The helper installs a placeholder first when this is the root
            // chrome body, so it never exposes an empty layout container.
            _ = PaneLayoutController.collapseSingleChildSplit(split)
        }
        win.contentView?.needsLayout = true
        win.contentView?.layoutSubtreeIfNeeded()
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
        let session = createSession(
            scale: scale,
            usesSharedWindowSurface: role == .standard)
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
            chrome.body.addSubview(session.view)
            let bg = session.renderer.backgroundColor
            chrome.setBacking(
                color: NSColor(srgbRed: CGFloat(bg.x), green: CGFloat(bg.y),
                               blue: CGFloat(bg.z), alpha: CGFloat(bg.w)),
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
            f.origin = NSPoint(x: 12, y: contentSize.height - f.height - 15)
            lights.frame = f
            lights.autoresizingMask = [.minYMargin, .maxXMargin]
            window.contentView?.addSubview(lights)
        }

        if role == .standard { window.center() }
        if role == .standard { registerPaneLedgerTab(for: window, session: session) }

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
    private func openWindow(
        cwd: String?, launchCommand: String? = nil
    ) -> TerminalSession {
        let (window, session) = makeTerminalWindow(cwd: cwd)
        recordPaneLedgerNote(in: window, reason: "tab-presented", origin: "new-window")
        window.makeKeyAndOrderFront(nil)
        if let launchCommand { queueLaunchCommand(launchCommand, for: session) }
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
    private func openTab(
        cwd: String?, launchCommand: String? = nil
    ) -> TerminalSession {
        let key = NSApp.keyWindow.flatMap { $0.tabbingIdentifier == "infinitty" ? $0 : nil }
        guard let host = key ?? NSApp.windows.first(where: { $0.tabbingIdentifier == "infinitty" })
        else {
            return openWindow(cwd: cwd, launchCommand: launchCommand)
        }
        let (window, session) = makeTerminalWindow(cwd: cwd)
        host.addTabbedWindow(window, ordered: .above)
        recordPaneLedgerNote(in: window, reason: "tab-joined", origin: "open-folder")
        window.makeKeyAndOrderFront(nil)
        if let launchCommand { queueLaunchCommand(launchCommand, for: session) }
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
        recordPaneLedgerNote(in: window, reason: "tab-joined", origin: "menu-new-tab")
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

    private func showSplitChooser(sourceView: NSView, vertical: Bool) {
        guard sourceView.window != nil else { return }
        restorePaneZoom(containing: sourceView, refocus: false)
        let menu = NSMenu(title: vertical ? "Split Right" : "Split Down")
        for choice in PaneType.allCases {
            let item = NSMenuItem(
                title: choice.title, action: #selector(splitChoiceSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = choice.rawValue
            item.image = NSImage(
                systemSymbolName: choice.symbol, accessibilityDescription: choice.title)
            menu.addItem(item)
        }
        pendingSplitContext = (sourceView, vertical)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: max(sourceView.bounds.maxX - 132, 4),
                        y: max(sourceView.bounds.maxY - PaneHeaderView.height - 4, 4)),
            in: sourceView)
        pendingSplitContext = nil
    }

    @objc private func splitChoiceSelected(_ sender: NSMenuItem) {
        guard let context = pendingSplitContext,
              let win = context.sourceView.window else { return }
        switch PaneType(rawValue: sender.tag) {
        case .terminal:
            splitTerminal(relativeTo: context.sourceView, vertical: context.vertical)
        case .files:
            _ = openUtilityPanel(
                .files, in: win, relativeTo: context.sourceView, vertical: context.vertical)
        case .chat:
            _ = openUtilityPanel(
                .chat, in: win, relativeTo: context.sourceView, vertical: context.vertical)
        case .browser:
            _ = openUtilityPanel(
                .browser, in: win, relativeTo: context.sourceView, vertical: context.vertical)
        case nil:
            break
        }
    }

    private func splitTerminal(relativeTo sourceView: NSView, vertical: Bool) {
        restorePaneZoom(containing: sourceView, refocus: false)
        guard let win = sourceView.window else { return }
        let session = createSession(
            scale: win.backingScaleFactor,
            usesSharedWindowSurface: terminalChromes[ObjectIdentifier(win)] != nil)
        session.workingDirectory = focusedSession(in: win)?.currentDirectory()
            ?? activeSessions(in: win).first?.currentDirectory()
        guard insertPaneView(session.view, relativeTo: sourceView, vertical: vertical) else {
            recordPaneLedgerFailure(
                in: win, paneID: paneLedgerTerminalID(session), reason: "split-insert-failed",
                origin: "pane-header")
            session.shutdown()
            sessions.removeAll { $0 === session }
            return
        }
        recordPaneLedgerTerminalAdded(
            session, in: win, reason: vertical ? "split-right" : "split-down",
            origin: "pane-header", sourceView: sourceView, vertical: vertical)
        session.launch()
        rebindUtilityPanels(to: session, in: win)
        win.makeFirstResponder(session.view)
        refreshPets()
        updateTitle(for: win)
        refreshShortcutHints()
    }

    @discardableResult
    private func insertPaneView(
        _ newView: NSView, relativeTo oldView: NSView,
        vertical: Bool, newFirst: Bool = false
    ) -> Bool {
        let owningWindow = oldView.window
        let split = PaneSplitView(frame: oldView.frame)
        split.isVertical = vertical
        split.dividerStyle = .thin
        split.autoresizingMask = oldView.autoresizingMask
        if let win = oldView.window, win.contentView === oldView {
            win.contentView = split
        } else if let parent = oldView.superview {
            guard PaneLayoutController.replace(oldView, with: split, in: parent) else { return false }
        } else {
            return false
        }
        // Only the root split follows a plain container. Once views become
        // arranged children, NSSplitView is their sole geometry owner.
        oldView.autoresizingMask = []
        newView.autoresizingMask = []
        if newFirst {
            split.addArrangedSubview(newView)
            split.addArrangedSubview(oldView)
        } else {
            split.addArrangedSubview(oldView)
            split.addArrangedSubview(newView)
        }
        if let owningWindow { applyTabTint(to: owningWindow) }
        DispatchQueue.main.async {
            let mid = split.isVertical ? split.bounds.width / 2 : split.bounds.height / 2
            split.setPosition(mid, ofDividerAt: 0)
        }
        return true
    }

    @objc func togglePaneZoom(_ sender: Any?) {
        guard let win = NSApp.keyWindow, let pane = focusedPaneLeaf(in: win) else { return }
        togglePaneZoom(for: pane)
    }

    private func togglePaneZoom(for session: TerminalSession) {
        togglePaneZoom(for: session.view)
    }

    private func togglePaneZoom(for pane: NSView) {
        guard let win = pane.window, let root = terminalRoot(of: win) else { return }
        let key = ObjectIdentifier(root)
        if paneZoomStates[key] != nil {
            restorePaneZoom(key: key, refocus: true, animated: true)
            return
        }
        if paneZoomRestoreStates[key] != nil {
            finishPaneZoomRestore(key: key, refocus: true)
            return
        }

        let panes = paneLeafViews(in: win)
        guard panes.count > 1, pane !== root else { return }
        root.layoutSubtreeIfNeeded()
        let dividerRatios = PaneLayoutController.captureDividerRatios(in: root)
        let splitPath = paneSplitPath(from: pane, to: root)
        guard !splitPath.isEmpty else { return }

        // Resolve from the outer split inward so every descendant target uses
        // the size it will actually have after its ancestors expand. Applying
        // these positions synchronously is not displayed; it lets us capture
        // one coherent final geometry before restoring the starting layout.
        for (split, selectedIndex) in splitPath.reversed() {
            let length = split.isVertical ? split.bounds.width : split.bounds.height
            let positions = PaneLayoutController.maximizedDividerPositions(
                length: length,
                childCount: split.arrangedSubviews.count,
                selectedIndex: selectedIndex,
                collapsedExtent: 0,
                dividerThickness: split.dividerThickness)
            for (index, position) in positions.enumerated() {
                split.setPosition(position, ofDividerAt: index)
            }
            root.layoutSubtreeIfNeeded()
        }
        let targets = splitPath.map { split, _ in
            (
                split,
                split.arrangedSubviews.dropLast().map {
                    split.isVertical ? $0.frame.maxX : $0.frame.maxY
                }
            )
        }
        PaneLayoutController.restoreDividerRatios(dividerRatios)
        root.layoutSubtreeIfNeeded()

        let orderedTargets = Array(targets.reversed())
        let collapsedViews = splitPath.flatMap { split, selectedIndex in
            split.arrangedSubviews.enumerated().compactMap { index, view in
                index == selectedIndex ? nil : view
            }
        }

        paneZoomStates[key] = PaneZoomState(
            pane: pane, root: root, dividerRatios: dividerRatios,
            maximizedRatios: PaneLayoutController.ratios(for: orderedTargets),
            collapsedViews: collapsedViews)
        win.makeFirstResponder(pane)
        let keyframes = orderedTargets.map { split, positions in
            PaneDividerKeyframe(
                split: split,
                start: currentDividerPositions(in: split),
                end: positions)
        }
        animatePaneDividers(key: key, keyframes: keyframes, duration: 0.18) { [weak self] in
            guard let self, let state = self.paneZoomStates[key], state.pane === pane else { return }
            state.collapsedViews.forEach { $0.isHidden = true }
            state.root.layoutSubtreeIfNeeded()
            pane.layoutSubtreeIfNeeded()
        }
    }

    private func paneSplitPath(
        from pane: NSView, to root: NSView
    ) -> [(split: NSSplitView, selectedIndex: Int)] {
        var result: [(NSSplitView, Int)] = []
        var branch: NSView = pane
        while branch !== root, let parent = branch.superview {
            if let split = parent as? NSSplitView,
               let index = split.arrangedSubviews.firstIndex(of: branch) {
                result.append((split, index))
            }
            branch = parent
        }
        return result
    }

    private func restorePaneZoom(containing session: TerminalSession, refocus: Bool) {
        restorePaneZoom(containing: session.view, refocus: refocus, animated: false)
    }

    private func restorePaneZoom(
        containing pane: NSView, refocus: Bool, animated: Bool = false
    ) {
        guard let win = pane.window, let root = terminalRoot(of: win) else { return }
        if let entry = paneZoomStates.first(where: { $0.value.root === root }) {
            restorePaneZoom(key: entry.key, refocus: refocus, animated: animated)
        } else if let entry = paneZoomRestoreStates.first(where: { $0.value.root === root }) {
            finishPaneZoomRestore(key: entry.key, refocus: refocus)
        }
    }

    private func restorePaneZoom(revealing pane: NSView) {
        guard let win = pane.window, let root = terminalRoot(of: win) else { return }
        guard let entry = paneZoomStates.first(where: {
            $0.value.root === root && $0.value.pane !== pane
        }) else {
            if let restoring = paneZoomRestoreStates.first(where: { $0.value.root === root }) {
                finishPaneZoomRestore(key: restoring.key, refocus: false)
            }
            return
        }
        restorePaneZoom(key: entry.key, refocus: false, animated: false)
    }

    private func restorePaneZoom(
        key: ObjectIdentifier, refocus: Bool, animated: Bool
    ) {
        guard let state = paneZoomStates.removeValue(forKey: key) else { return }
        paneDividerAnimations.removeValue(forKey: key)?.cancel()
        if animated {
            paneZoomRestoreStates[key] = state
            let wasFullyMaximized = state.collapsedViews.contains(where: \.isHidden)
            state.collapsedViews.forEach { $0.isHidden = false }
            if wasFullyMaximized {
                PaneLayoutController.restoreDividerRatios(state.maximizedRatios)
                state.root.layoutSubtreeIfNeeded()
            }
            let keyframes: [PaneDividerKeyframe] = state.dividerRatios.compactMap { snapshot in
                guard snapshot.split.superview != nil,
                      snapshot.split.arrangedSubviews.count == snapshot.ratios.count + 1
                else { return nil }
                return PaneDividerKeyframe(
                    split: snapshot.split,
                    start: currentDividerPositions(in: snapshot.split),
                    end: PaneLayoutController.positions(for: snapshot))
            }
            animatePaneDividers(key: key, keyframes: keyframes, duration: 0.18) { [weak self] in
                self?.paneZoomRestoreStates.removeValue(forKey: key)
            }
        } else {
            state.collapsedViews.forEach { $0.isHidden = false }
            PaneLayoutController.restoreDividerRatios(state.dividerRatios)
        }
        if refocus, let win = state.pane.window { win.makeFirstResponder(state.pane) }
    }

    private func finishPaneZoomRestore(key: ObjectIdentifier, refocus: Bool) {
        guard let state = paneZoomRestoreStates.removeValue(forKey: key) else { return }
        paneDividerAnimations.removeValue(forKey: key)?.cancel()
        state.collapsedViews.forEach { $0.isHidden = false }
        PaneLayoutController.restoreDividerRatios(state.dividerRatios)
        state.root.layoutSubtreeIfNeeded()
        if refocus, let win = state.pane.window { win.makeFirstResponder(state.pane) }
    }

    private func currentDividerPositions(in split: NSSplitView) -> [CGFloat] {
        split.arrangedSubviews.dropLast().map {
            split.isVertical ? $0.frame.maxX : $0.frame.maxY
        }
    }

    private func animatePaneDividers(
        key: ObjectIdentifier, keyframes: [PaneDividerKeyframe],
        duration: TimeInterval, completion: @escaping () -> Void = {}
    ) {
        paneDividerAnimations.removeValue(forKey: key)?.cancel()
        guard !keyframes.isEmpty else {
            completion()
            return
        }
        let animation = PaneDividerAnimation(
            keyframes: keyframes, duration: duration
        ) { [weak self] in
            guard let self else { return }
            self.paneDividerAnimations.removeValue(forKey: key)
            completion()
        }
        paneDividerAnimations[key] = animation
        animation.start()
    }

    private func beginPaneDrag(sourceView: NSView, title: String, at point: NSPoint) {
        restorePaneZoom(containing: sourceView, refocus: false)
        guard let win = sourceView.window,
              sourceView.superview is NSSplitView,
              let content = win.contentView else { return }
        endPaneDrag(at: point, cancelled: true)
        PaneLog.log("drag begin title=\(title) source=\(ObjectIdentifier(sourceView)) "
            + "point=\(NSStringFromPoint(point))")
        let badge = PaneDragBadgeView(title: title)
        content.addSubview(badge, positioned: .above, relativeTo: nil)
        paneDragState = PaneDragState(sourceView: sourceView, title: title, badge: badge)
        updatePaneDrag(at: point)
    }

    private func updatePaneDrag(at point: NSPoint) {
        guard var state = paneDragState,
              let win = state.sourceView.window,
              let content = win.contentView else { return }
        let contentPoint = content.convert(point, from: nil)
        state.badge.frame.origin = NSPoint(
            x: min(max(contentPoint.x + 12, 4), content.bounds.maxX - state.badge.frame.width - 4),
            y: min(max(contentPoint.y - 12, 4), content.bounds.maxY - state.badge.frame.height - 4))

        let target = paneLeafViews(in: win).first { candidate in
            guard candidate !== state.sourceView,
                  !candidate.isHiddenOrHasHiddenAncestor else { return false }
            let local = candidate.convert(point, from: nil)
            return candidate.bounds.contains(local)
        }
        let zone = target.map {
            PaneDropZone.resolve(point: $0.convert(point, from: nil), in: $0.bounds)
        }
        if state.targetView !== target || state.zone != zone {
            PaneLog.log("drag target source=\(ObjectIdentifier(state.sourceView)) "
                + "target=\(target.map { String(describing: ObjectIdentifier($0)) } ?? "nil") "
                + "zone=\(zone.map(String.init(describing:)) ?? "nil")")
            let targetFrame = target.flatMap { target in
                zone.map { $0.previewFrame(in: target.bounds).insetBy(dx: 3, dy: 3) }
            }
            if state.targetView === target, let preview = state.preview, let targetFrame {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    preview.animator().frame = targetFrame
                }
            } else {
                if let oldPreview = state.preview {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.10
                        oldPreview.animator().alphaValue = 0
                    } completionHandler: {
                        oldPreview.removeFromSuperview()
                    }
                }
                state.preview = nil
                if let target, let targetFrame {
                    let dx = min(8, targetFrame.width / 4)
                    let dy = min(8, targetFrame.height / 4)
                    let preview = PaneDropPreviewView(
                        frame: targetFrame.insetBy(dx: dx, dy: dy))
                    preview.alphaValue = 0
                    preview.autoresizingMask = []
                    target.addSubview(preview, positioned: .above, relativeTo: nil)
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.16
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        preview.animator().frame = targetFrame
                        preview.animator().alphaValue = 1
                    }
                    state.preview = preview
                }
            }
            state.targetView = target
            state.zone = zone
        }
        paneDragState = state
    }

    private func endPaneDrag(at point: NSPoint, cancelled: Bool) {
        guard let state = paneDragState else { return }
        paneDragState = nil
        PaneLog.log("drag end source=\(ObjectIdentifier(state.sourceView)) cancelled=\(cancelled) "
            + "target=\(state.targetView.map { String(describing: ObjectIdentifier($0)) } ?? "nil") "
            + "zone=\(state.zone.map(String.init(describing:)) ?? "nil")")
        if cancelled, let preview = state.preview {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.10
                preview.animator().alphaValue = 0
            } completionHandler: {
                preview.removeFromSuperview()
            }
        }
        state.badge.removeFromSuperview()
        guard !cancelled, let target = state.targetView, let zone = state.zone else { return }
        movePaneView(state.sourceView, relativeTo: target, zone: zone)
        if let preview = state.preview {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                preview.animator().alphaValue = 0
            } completionHandler: {
                preview.removeFromSuperview()
            }
        }
    }

    private func movePaneView(_ source: NSView, relativeTo target: NSView, zone: PaneDropZone) {
        guard source !== target, let win = source.window, target.window === win else { return }
        let beforePanes = paneLeafViews(in: win)
        let beforeIDs = Set(beforePanes.map(ObjectIdentifier.init))
        let root = terminalRoot(of: win)
        PaneLog.log("move begin zone=\(zone) count=\(beforePanes.count) "
            + "source=\(ObjectIdentifier(source)) target=\(ObjectIdentifier(target)) "
            + "tree=\(root.map(PaneLog.describe) ?? "nil")")
        let oldGeometry = beforePanes.map {
            (view: $0, frameInWindow: $0.convert($0.bounds, to: nil))
        }
        let result = PaneLayoutController.move(
            source: source, target: target, zone: zone)
        guard result.changed else {
            PaneLog.log("ERROR move returned unchanged zone=\(zone) "
                + "source=\(ObjectIdentifier(source)) target=\(ObjectIdentifier(target))")
            recordPaneLedgerFailure(
                in: win, paneID: paneLedgerPaneID(for: source), reason: "pane-move-unchanged",
                origin: "pane-drag")
            return
        }
        if let split = result.insertedSplit {
            win.contentView?.layoutSubtreeIfNeeded()
            let mid = split.isVertical ? split.bounds.width / 2 : split.bounds.height / 2
            split.setPosition(mid, ofDividerAt: 0)
        }
        win.contentView?.layoutSubtreeIfNeeded()
        let afterPanes = paneLeafViews(in: win)
        let afterIDs = Set(afterPanes.map(ObjectIdentifier.init))
        let missing = beforeIDs.subtracting(afterIDs)
        let added = afterIDs.subtracting(beforeIDs)
        let summary = "move end count=\(afterPanes.count) missing=\(missing) added=\(added) "
            + "tree=\(root.map(PaneLog.describe) ?? "nil")"
        PaneLog.log(beforeIDs == afterIDs ? summary : "ERROR \(summary)")
        recordPaneLedgerNote(
            in: win, paneID: paneLedgerPaneID(for: source), reason: "pane-moved", origin: "pane-drag",
            sourcePaneID: paneLedgerPaneID(for: target), axis: String(describing: zone))
        animatePaneReflow(from: oldGeometry)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak win] in
            guard let self, let win else { return }
            let settled = self.paneLeafViews(in: win)
            let settledIDs = Set(settled.map(ObjectIdentifier.init))
            let settledRoot = self.terminalRoot(of: win)
            let settledSummary = "move settled count=\(settled.count) "
                + "missing=\(beforeIDs.subtracting(settledIDs)) "
                + "added=\(settledIDs.subtracting(beforeIDs)) "
                + "tree=\(settledRoot.map(PaneLog.describe) ?? "nil")"
            PaneLog.log(beforeIDs == settledIDs ? settledSummary : "ERROR \(settledSummary)")
            self.recordPaneLedgerNote(
                in: win, reason: "pane-move-settled", origin: "pane-drag")
        }
        win.makeFirstResponder(source)
        refreshPets()
        updateTitle(for: win)
        refreshShortcutHints()
    }

    private func animatePaneReflow(
        from oldGeometry: [(view: NSView, frameInWindow: NSRect)]
    ) {
        for (view, oldFrameInWindow) in oldGeometry {
            guard view.window != nil, let parent = view.superview else { continue }
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            let oldFrame = parent.convert(oldFrameInWindow, from: nil)
            let newFrame = view.frame
            guard oldFrame != newFrame else { continue }

            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = NSValue(point: NSPoint(x: oldFrame.midX, y: oldFrame.midY))
            position.toValue = NSValue(point: layer.position)

            let oldBounds = NSRect(origin: view.bounds.origin, size: oldFrame.size)
            let bounds = CABasicAnimation(keyPath: "bounds")
            bounds.fromValue = NSValue(rect: oldBounds)
            bounds.toValue = NSValue(rect: layer.bounds)

            let group = CAAnimationGroup()
            group.animations = [position, bounds]
            group.duration = 0.24
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(group, forKey: "pane-reflow")
        }
    }

    @discardableResult
    private func replaceNode(_ old: NSView, with new: NSView, in parent: NSView) -> Bool {
        PaneLayoutController.replace(old, with: new, in: parent)
    }

    @objc func splitRight(_ sender: Any?) {
        if let win = NSApp.keyWindow, let leaf = focusedPaneLeaf(in: win) {
            showSplitChooser(sourceView: leaf, vertical: true)
        }
    }

    @objc func splitLeft(_ sender: Any?) {
        split(vertical: true, newFirst: true)
    }

    @objc func splitDown(_ sender: Any?) {
        if let win = NSApp.keyWindow, let leaf = focusedPaneLeaf(in: win) {
            showSplitChooser(sourceView: leaf, vertical: false)
        }
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
        let newSession = createSession(
            scale: win.backingScaleFactor,
            usesSharedWindowSurface: terminalChromes[ObjectIdentifier(win)] != nil)
        // Splits land in the source pane's live folder, same as new tabs.
        newSession.workingDirectory = session.currentDirectory()

        let old = session.view
        let container = old.superview
        let frame = old.frame

        let splitView = PaneSplitView(frame: frame)
        splitView.isVertical = vertical
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]

        if win.contentView === old {
            win.contentView = splitView
        } else if let parent = container as? NSSplitView {
            let idx = parent.arrangedSubviews.firstIndex(of: old) ?? 0
            old.removeFromSuperview()
            splitView.autoresizingMask = []
            parent.insertArrangedSubview(splitView, at: idx)
        } else if let parent = container {
            splitView.frame = old.frame
            parent.replaceSubview(old, with: splitView)
        } else {
            recordPaneLedgerFailure(
                in: win, paneID: paneLedgerTerminalID(newSession), reason: "split-insert-failed",
                origin: "split-command")
            newSession.shutdown()
            sessions.removeAll { $0 === newSession }
            return
        }
        old.autoresizingMask = []
        newSession.view.autoresizingMask = []
        if newFirst {
            splitView.addArrangedSubview(newSession.view)
            splitView.addArrangedSubview(old)
        } else {
            splitView.addArrangedSubview(old)
            splitView.addArrangedSubview(newSession.view)
        }
        applyTabTint(to: win)
        recordPaneLedgerTerminalAdded(
            newSession, in: win,
            reason: vertical
                ? (newFirst ? "split-left" : "split-right")
                : (newFirst ? "split-up" : "split-down"),
            origin: "split-command", sourceView: old, vertical: vertical)

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
            if let win = session.view.window {
                recordPaneLedgerNote(
                    in: win, paneID: paneLedgerTerminalID(session), reason: "close-requested",
                    origin: "pane-command")
            }
            session.terminate() // EOF path handles pane/tab teardown
        } else if let win = NSApp.keyWindow,
                  let pane = focusedPaneLeaf(in: win) as? UtilityPaneView,
                  let record = utilityPanels[ObjectIdentifier(win)]?[pane.kind] {
            closeUtilityPanel(record, in: win)
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

    /// Independent Files and Chat leaves mixed into each tab's pane tree.
    private var utilityPanels: [ObjectIdentifier: [UtilityPanelKind: UtilityPanelRecord]] = [:]

    @objc func toggleCodeView(_ sender: Any?) {
        guard let win = NSApp.keyWindow else { return }
        toggleCodeView(in: win)
    }

    func toggleCodeView(in win: NSWindow) {
        guard win.tabbingIdentifier == "infinitty",
              win !== quickTerminal.window else { return }
        let id = ObjectIdentifier(win)
        if let record = utilityPanels[id]?[.files] {
            closeUtilityPanel(record, in: win)
            sidebarToggleAccessories[id]?.toggleView.setSidebarVisible(false)
            refocusTerminal(in: win)
            return
        }
        _ = openUtilityPanel(.files, in: win)
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
    /// each shows the shared title list with its own tab highlighted. The
    /// native tab bar stays hidden; reference chrome keeps our strip visible
    /// even for a single tab.
    private func refreshTabStrips(in win: NSWindow) {
        let tabs = win.tabbedWindows ?? [win]
        let titles = tabs.map { self.tabTitle(for: $0) }
        let presentation = tabPresentation(for: tabs)
        let selectedWindow = win.tabGroup?.selectedWindow ?? win
        let selectedIndex = tabs.firstIndex(where: { $0 === selectedWindow }) ?? 0
        let groupID = win.tabGroup.map(ObjectIdentifier.init)
        let previousIndex = groupID.flatMap { lastSelectedTabIndex[$0] }
        if let groupID { lastSelectedTabIndex[groupID] = selectedIndex }
        for (index, tabWin) in tabs.enumerated() {
            tabWin.hideNativeTabBar()
            guard let chrome = terminalChromes[ObjectIdentifier(tabWin)] else { continue }
            chrome.sideTabs = config.sideTabs
            chrome.showsStrip = true
            chrome.strip.update(
                titles: titles, selectedIndex: index,
                pins: presentation.pins, icons: presentation.icons,
                tints: presentation.tints,
                animateFromIndex: tabWin === selectedWindow ? previousIndex : nil)
            applyTabTint(to: tabWin)
        }
    }

    private func tabPresentation(
        for tabs: [NSWindow]
    ) -> (pins: [Int: TerminalTabStripView.Pin], icons: [Int: NSImage],
          tints: [Int: NSColor]) {
        var pins: [Int: TerminalTabStripView.Pin] = [:]
        var icons: [Int: NSImage] = [:]
        var tints: [Int: NSColor] = [:]
        for (index, window) in tabs.enumerated() {
            let id = ObjectIdentifier(window)
            if var pin = tabPins[id] {
                pin.color = tabTints[id] ?? CodePalette.paneFocusAccent
                pins[index] = pin
            }
            if let tint = tabTints[id] { tints[index] = tint }
            let inWindow = activeSessions(in: window)
            let focused = inWindow.first { window.firstResponder === $0.view } ?? inWindow.first
            if let focused,
               let process = focused.processTracker?.current,
               let icon = tabIcon(for: process, shellPID: focused.pty.pid) {
                icons[index] = icon
            }
        }
        return (pins, icons, tints)
    }

    private func tabIcon(
        for process: ForegroundProcessInfo, shellPID: pid_t
    ) -> NSImage? {
        if let asset = tabIconAssetName(forProcessName:
            "\(process.displayName) \(process.rawName)"),
           let image = bundledTabIcon(named: asset) {
            return image
        }
        // An idle shell keeps the terminal glyph; foreground CLI/GUI apps use
        // their executable or bundle icon.
        return process.pid == shellPID ? nil : process.icon()
    }

    private func bundledTabIcon(named asset: String) -> NSImage? {
        guard let url = Bundle.main.url(
            forResource: asset, withExtension: "svg", subdirectory: "Logos")
            ?? Bundle.main.url(forResource: asset, withExtension: "svg")
            ?? Bundle.module.url(
                forResource: asset, withExtension: "svg", subdirectory: "Logos")
            ?? Bundle.module.url(forResource: asset, withExtension: "svg"),
            let data = try? Data(contentsOf: url),
            let image = NSImage(data: data), image.isValid
        else { return nil }
        image.size = NSSize(width: 24, height: 24)
        return image
    }

    private func tabIconAssetName(forProcessName name: String) -> String? {
        let value = name.lowercased()
        if value.contains("claude") { return "anthropic" }
        if value.contains("codex") { return "openai" }
        return nil
    }

    func tabIconAssetNameForTesting(_ processName: String) -> String? {
        tabIconAssetName(forProcessName: processName)
    }

    func bundledTabIconForTesting(_ asset: String) -> NSImage? {
        bundledTabIcon(named: asset)
    }

    private func applyTabTint(to win: NSWindow) {
        let color = tabTints[ObjectIdentifier(win)] ?? CodePalette.paneFocusAccent
        for pane in paneLeafViews(in: win) {
            (pane as? TerminalView)?.setPaneAccent(color)
            (pane as? UtilityPaneView)?.setPaneAccent(color)
        }
    }

    func setTabTintForTesting(_ color: NSColor, in window: NSWindow) {
        tabTints[ObjectIdentifier(window)] = color
        applyTabTint(to: window)
    }

    func insertPaneViewForTesting(
        _ newView: NSView, relativeTo oldView: NSView, vertical: Bool
    ) -> Bool {
        insertPaneView(newView, relativeTo: oldView, vertical: vertical)
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
            self.showTabPinMenu(for: tabs[index], anchor: button)
        }
    }

    /// Context menu for a tab: pin/unpin and pick a pin color.
    private func showTabPinMenu(for tabWin: NSWindow, anchor: NSView) {
        let menu = makeTabPinMenu(for: tabWin)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    }

    private func makeTabPinMenu(for tabWin: NSWindow) -> NSMenu {
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
        }
        menu.addItem(.separator())
        let colors: [(String, NSColor?)] = [
            ("Default Blue", nil),
            ("Indigo", CodePalette.selectionAccent),
            ("Red", .systemRed), ("Orange", .systemOrange),
            ("Green", .systemGreen), ("Blue", .systemBlue),
            ("Purple", .systemPurple), ("Gray", .systemGray),
        ]
        for (name, color) in colors {
            let item = menu.addItem(
                withTitle: name, action: #selector(setPinColorAction(_:)), keyEquivalent: "")
            item.target = self
            let swatch = NSImage(size: NSSize(width: 12, height: 12))
            swatch.lockFocus()
            (color ?? CodePalette.paneFocusAccent).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 0, y: 0, width: 12, height: 12),
                xRadius: 3, yRadius: 3).fill()
            swatch.unlockFocus()
            item.image = swatch
            item.state = color == nil
                ? (tabTints[id] == nil ? .on : .off)
                : (color?.isEqual(tabTints[id]) == true ? .on : .off)
            item.representedObject = TabPinColorChoice(window: tabWin, color: color)
        }
        return menu
    }

    func tabPinMenuForTesting(for window: NSWindow) -> NSMenu {
        makeTabPinMenu(for: window)
    }

    private final class TabPinColorChoice: NSObject {
        let window: NSWindow
        let color: NSColor?
        init(window: NSWindow, color: NSColor?) { self.window = window; self.color = color }
    }

    @objc private func pinTabAction(_ sender: NSMenuItem) {
        guard let win = sender.representedObject as? NSWindow else { return }
        let color = tabTints[ObjectIdentifier(win)] ?? CodePalette.paneFocusAccent
        tabPins[ObjectIdentifier(win)] = TerminalTabStripView.Pin(
            icon: "pin.fill", color: color)
        refreshTabStrips(in: win)
    }

    @objc private func unpinTabAction(_ sender: NSMenuItem) {
        guard let win = sender.representedObject as? NSWindow else { return }
        tabPins.removeValue(forKey: ObjectIdentifier(win))
        refreshTabStrips(in: win)
    }

    @objc private func setPinColorAction(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? TabPinColorChoice else { return }
        let id = ObjectIdentifier(choice.window)
        if let color = choice.color {
            tabTints[id] = color
        } else {
            tabTints.removeValue(forKey: id)
        }
        if var pin = tabPins[id] {
            pin.color = choice.color ?? CodePalette.paneFocusAccent
            tabPins[id] = pin
        }
        refreshTabStrips(in: choice.window)
    }

    /// Begin an inline rename in the window's own custom strip.
    private func beginStripRename(for win: NSWindow) {
        guard let chrome = terminalChromes[ObjectIdentifier(win)],
              let tabs = win.tabbedWindows,
              let index = tabs.firstIndex(where: { $0 === win }) else { return }
        chrome.showsStrip = true
        let presentation = tabPresentation(for: tabs)
        chrome.strip.update(
            titles: tabs.map { self.tabTitle(for: $0) }, selectedIndex: index,
            pins: presentation.pins, icons: presentation.icons,
            tints: presentation.tints)
        _ = chrome.strip.beginRename(at: index, currentName: tabTitle(for: win))
    }

    /// Compatibility entry point: the former sidebar is now the Files pane,
    /// whose own compact switch still contains Files and Changes.
    @discardableResult
    private func openCodeView(in win: NSWindow) -> CodeViewController? {
        openUtilityPanel(.files, in: win)?.controller ?? nil
    }

    @discardableResult
    private func openUtilityPanel(
        _ kind: UtilityPanelKind,
        in win: NSWindow,
        relativeTo requestedSource: NSView? = nil,
        vertical: Bool = true
    ) -> UtilityPanelRecord? {
        let id = ObjectIdentifier(win)
        if let existing = utilityPanels[id]?[kind] {
            restorePaneZoom(revealing: existing.pane)
            win.makeFirstResponder(existing.pane)
            recordPaneLedgerNote(
                in: win, paneID: kind.rawValue, reason: "pane-focused", origin: "utility-open")
            return existing
        }
        guard let anchorView = requestedSource
                ?? focusedPaneLeaf(in: win)
                ?? activeSessions(in: win).first?.view
                ?? terminalRoot(of: win),
              anchorView.window === win else { return nil }

        let bg = Theme.dark.applying(config).background
        let background = NSColor(
            srgbRed: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z),
            alpha: CGFloat(bg.w))
        let codeController: CodeViewController?
        let browserController: BrowserPaneController?
        let contentView: NSView
        switch kind {
        case .files, .chat:
            let controller = CodeViewController(config: config, panelKind: kind)
            codeController = controller
            browserController = nil
            contentView = controller.view
        case .browser:
            let controller = BrowserPaneController()
            codeController = nil
            browserController = controller
            contentView = controller.view
        }
        let pane = UtilityPaneView(
            kind: kind,
            contentView: contentView,
            background: background,
            blurred: config.backgroundBlur)
        let record: UtilityPanelRecord
        if let controller = codeController {
            record = UtilityPanelRecord(controller: controller, pane: pane)
        } else if let controller = browserController {
            record = UtilityPanelRecord(browser: controller, pane: pane)
        } else {
            return nil
        }
        utilityPanels[id, default: [:]][kind] = record
        if let controller = codeController {
            controller.onPageChanged = { [weak self, weak win, weak controller] page in
                guard let self, let win, let controller,
                      self.utilityPanels[ObjectIdentifier(win)]?[kind]?.controller === controller
                else { return }
                self.recordPaneLedgerNote(
                    in: win, paneID: kind.rawValue, reason: "page-\(page)", origin: "sidebar")
            }
        }
        if let browser = browserController {
            browser.onEvent = { [weak self, weak win] event in
                guard let self, let win else { return }
                self.appControl.broadcast(event)
                if let name = event["event"] as? String {
                    self.recordPaneLedgerNote(
                        in: win, paneID: "browser", reason: name, origin: "browser-pane")
                }
            }
            browser.onAnnotationsSubmitted = { [weak self, weak win] annotations in
                guard let self, let win else { return }
                self.submitBrowserAnnotations(annotations, in: win)
            }
        }

        pane.onSplitRight = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.splitTerminal(relativeTo: pane, vertical: true)
        }
        pane.onSplitDown = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.splitTerminal(relativeTo: pane, vertical: false)
        }
        pane.onChooseSplitRight = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.showSplitChooser(sourceView: pane, vertical: true)
        }
        pane.onChooseSplitDown = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.showSplitChooser(sourceView: pane, vertical: false)
        }
        pane.paneHeader.onToggleZoom = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.togglePaneZoom(for: pane)
        }
        pane.onFocus = { [weak self, weak win, weak pane] in
            guard let self, let win, let pane else { return }
            self.updatePaneSelection(in: win, focused: pane)
        }
        pane.onClose = { [weak self, weak win, weak record] in
            guard let self, let win, let record else { return }
            self.closeUtilityPanel(record, in: win)
        }
        pane.onDragBegan = { [weak self, weak pane] point in
            guard let self, let pane else { return }
            self.beginPaneDrag(sourceView: pane, title: kind.title, at: point)
        }
        pane.onDragMoved = { [weak self] point in self?.updatePaneDrag(at: point) }
        pane.onDragEnded = { [weak self] point, cancelled in
            self?.endPaneDrag(at: point, cancelled: cancelled)
        }

        let sourceSession = focusedSession(in: win) ?? activeSessions(in: win).first
        if let controller = codeController {
            if let sourceSession { controller.track(session: sourceSession) }
            if kind == .chat {
                // A Chat pane can be opened from a Browser-only tab after its
                // last terminal has closed. Keep that conversation usable;
                // it will rebind to the next terminal that appears in this
                // native tab without creating a second assistant.
                let assistant = sourceSession.map { petAssistant(for: $0) }
                    ?? PetAssistant(config: config)
                record.assistant = assistant
                controller.attachAssistant(assistant)
                pane.onNewChat = { [weak self, weak win, weak assistant] in
                    if let self, let win {
                        self.recordPaneLedgerNote(
                            in: win, paneID: "chat", reason: "chat-new", origin: "chat-header")
                    }
                    assistant?.startNewChat()
                }
            }
        }
        guard insertPaneView(pane, relativeTo: anchorView, vertical: vertical)
        else {
            recordPaneLedgerFailure(
                in: win, paneID: kind.rawValue, reason: "utility-insert-failed",
                origin: requestedSource == nil ? "utility-open" : "split-chooser")
            utilityPanels[id]?.removeValue(forKey: kind)
            return nil
        }
        recordPaneLedgerUtilityAdded(
            kind, in: win,
            reason: requestedSource == nil ? "utility-open" : "split-insert",
            origin: requestedSource == nil ? "utility-open" : "split-chooser",
            sourceView: anchorView, vertical: vertical)
        if let browser = record.browser {
            DispatchQueue.main.async { [weak browser] in browser?.paneDidBecomeVisible() }
        }
        sidebarToggleAccessories[id]?.toggleView.setSidebarVisible(
            utilityPanels[id]?[.files] != nil)
        win.makeFirstResponder(pane)
        return record
    }

    private func closeUtilityPanel(_ record: UtilityPanelRecord, in win: NSWindow) {
        let id = ObjectIdentifier(win)
        restorePaneZoom(containing: record.pane, refocus: false)
        if let split = record.pane.superview as? NSSplitView {
            record.pane.removeFromSuperview()
            collapse(split, in: win)
        } else {
            record.pane.removeFromSuperview()
        }
        if let browser = record.browser {
            browser.cancelPendingAutomation()
            appControl.broadcast(["event": "browser-closed", "browserId": browser.browserID])
        }
        utilityPanels[id]?.removeValue(forKey: record.pane.kind)
        if utilityPanels[id]?.isEmpty == true { utilityPanels.removeValue(forKey: id) }
        recordPaneLedgerUtilityRemoved(
            record.pane.kind, in: win, reason: "utility-close", origin: "utility-pane")
        if PaneLifecyclePolicy.shouldCloseTab(remainingPaneCount: paneLeafViews(in: win).count) {
            win.close()
            return
        }
        sidebarToggleAccessories[id]?.toggleView.setSidebarVisible(
            utilityPanels[id]?[.files] != nil)
        refocusTerminal(in: win)
    }

    func installSidebarToggle(in win: NSWindow) {
        let id = ObjectIdentifier(win)
        if let existing = sidebarToggleAccessories[id] {
            existing.toggleView.setSidebarVisible(utilityPanels[id]?[.files] != nil)
            return
        }

        let accessory = SidebarToggleAccessory()
        accessory.toggleView.onClick = { [weak self, weak win] in
            guard let self, let win else { return }
            self.toggleCodeView(in: win)
        }
        accessory.toggleView.setSidebarVisible(utilityPanels[id]?[.files] != nil)
        accessory.attach(to: win)
        sidebarToggleAccessories[id] = accessory
    }

    /// Keep keyboard input in the terminal after sidebar toggles.
    private func refocusTerminal(in win: NSWindow) {
        if win.firstResponder is TerminalView { return }
        let activeRoot = terminalRoot(of: win)
        let zoomed = paneZoomStates.values.first {
            guard let activeRoot else { return false }
            return $0.root === activeRoot
        }?.pane as? TerminalView
        if let target = zoomed ?? activeSessions(in: win).first?.view {
            win.makeFirstResponder(target)
        }
    }

    // MARK: - pet assistant

    /// One assistant per session (kept so the popover survives focus changes).
    private var petAssistants: [Int: PetAssistant] = [:]

    private func configureSessionNotch() {
        notch.configure(
            fontName: config.fontName, fontStyle: config.fontStyle,
            fontSize: config.fontSize, pet: config.pet)
        notch.onOpenSession = { [weak self] session, mode in
            self?.openDetectedSession(session, mode: mode)
        }
    }

    private func openDetectedSession(
        _ detected: AgentSession, mode: SessionOpenMode
    ) {
        switch mode {
        case .chat:
            recoverDetectedSessionInChat(detected)
        case .resume:
            if !resumeDetectedSession(detected) {
                recoverDetectedSessionInChat(detected)
            }
        case .automatic:
            if let processID = detected.processID,
               let owner = sessions.first(where: {
                   ForegroundProcessTracker.isProcess(
                       processID, ownedByShell: $0.pty.pid)
               }) {
                focusSession(owner)
                return
            }
            if detected.isLive, let processID = detected.processID,
               activateHostApplication(for: processID) {
                return
            }
            if !detected.isLive, resumeDetectedSession(detected) { return }
            recoverDetectedSessionInChat(detected)
        }
    }

    private func activateHostApplication(for processID: pid_t) -> Bool {
        var current = processID
        var visited = Set<pid_t>()
        for _ in 0..<32 {
            guard visited.insert(current).inserted else { break }
            if let app = NSRunningApplication(processIdentifier: current),
               app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
               app.activationPolicy == .regular {
                return app.activate(options: [.activateAllWindows])
            }
            guard let parent = ForegroundProcessTracker.parentProcessID(of: current),
                  parent > 1 else { break }
            current = parent
        }
        return false
    }

    @discardableResult
    private func resumeDetectedSession(_ detected: AgentSession) -> Bool {
        guard !detected.isLive else { return false }
        let kind: CLIExecutableKind = detected.kind == .claude ? .claude : .codex
        guard let executable = CLIExecutableResolver.resolve(kind),
              let command = detected.resumeCommand(executablePath: executable.path)
        else { return false }
        _ = openTab(cwd: detected.workingDirectory, launchCommand: command)
        return true
    }

    private func queueLaunchCommand(_ command: String, for session: TerminalSession) {
        pendingLaunchCommands[session.id] = command
        // OSC 133 A/B normally arrives first. This fallback supports shells
        // without Infinitty's integration and is cancelled by the first marker.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak session] in
            guard let self, let session else { return }
            self.flushPendingLaunchCommand(for: session)
        }
    }

    private func flushPendingLaunchCommand(for session: TerminalSession) {
        guard let command = pendingLaunchCommands.removeValue(forKey: session.id) else { return }
        session.view.showAgentGlow()
        session.pty.write(Array(command.utf8) + [0x0D])
    }

    private func recoverDetectedSessionInChat(_ detected: AgentSession) {
        let source = focusedSession()
            ?? sessions.first(where: { !$0.view.isHiddenOrHasHiddenAncestor })
            ?? openTab(cwd: detected.workingDirectory)
        guard let win = source.view.window else { return }
        focusSession(source)
        guard let record = openUtilityPanel(
            .chat, in: win, relativeTo: source.view, vertical: true)
        else { return }
        let assistant = petAssistant(for: source)
        assistant.prepareRecovery(
            context: detected.recoveryContext,
            provider: detected.kind == .claude ? .claude : .codex,
            transcriptPath: detected.id)
        record.assistant = assistant
        record.controller?.track(session: source)
        record.controller?.attachAssistant(assistant)
        record.controller?.focusChatInput()
    }

    /// Legacy single-selection entry point. Browser feedback normally arrives
    /// through the batch callback so one Send becomes one normal chat request.
    private func submitBrowserAnnotation(_ annotation: BrowserAnnotation, in win: NSWindow) {
        submitBrowserAnnotations([annotation], in: win)
    }

    /// Browser feedback becomes a normal chat turn, rather than an opaque
    /// side channel. BrowserAnnotation.aiContext(for:) explicitly marks page
    /// content as untrusted before it reaches a model.
    private func submitBrowserAnnotations(_ annotations: [BrowserAnnotation], in win: NSWindow) {
        guard !annotations.isEmpty else { return }
        recordPaneLedgerNote(
            in: win, paneID: "browser", reason: "browser-annotations", origin: "browser-inspector")
        guard let source = focusedSession(in: win) ?? activeSessions(in: win).first else {
            // A Browser-only tab is still valid after its last terminal exits.
            // Create or reuse a detached assistant: it can answer via the
            // app-level browser tools without pretending terminal context is
            // present, and will rebind if a terminal is later added.
            guard let record = openUtilityPanel(.chat, in: win) else { return }
            let assistant = record.assistant ?? PetAssistant(config: config)
            record.assistant = assistant
            record.controller?.attachAssistant(assistant)
            record.pane.onNewChat = { [weak self, weak win, weak assistant] in
                if let self, let win {
                    self.recordPaneLedgerNote(
                        in: win, paneID: "chat", reason: "chat-new", origin: "chat-header")
                }
                assistant?.startNewChat()
            }
            assistant.submitBrowserAnnotations(annotations)
            win.makeFirstResponder(record.pane)
            broadcastBrowserAnnotationSubmission(annotations)
            return
        }
        guard let record = openUtilityPanel(.chat, in: win) else { return }
        let assistant = record.assistant ?? petAssistant(for: source)
        rehomeAssistant(assistant, to: source)
        record.assistant = assistant
        record.controller?.track(session: source)
        record.controller?.attachAssistant(assistant)
        assistant.submitBrowserAnnotations(annotations)
        win.makeFirstResponder(record.pane)
        broadcastBrowserAnnotationSubmission(annotations)
    }

    private func broadcastBrowserAnnotationSubmission(_ annotations: [BrowserAnnotation]) {
        guard let first = annotations.first else { return }
        appControl.broadcast([
            "event": "browser-annotation-submitted",
            "origin": URL(string: first.url)?.host ?? "",
            "documentId": first.documentID,
            "annotationCount": annotations.count,
        ])
    }

    private func petAssistant(for session: TerminalSession) -> PetAssistant {
        if let existing = petAssistants[session.id] { return existing }
        let created = PetAssistant(config: config)
        bindAssistant(created, to: session)
        petAssistants[session.id] = created
        return created
    }

    private func bindAssistant(_ assistant: PetAssistant, to session: TerminalSession) {
        assistant.attach(to: session)
        assistant.onShowInSidePanel = { [weak self, weak session] paths, query in
            guard let self, let session else { return }
            self.showAssistantResults(paths, query: query, for: session)
        }
    }

    /// The pet bubble and the Chat pane must share one assistant instance.
    /// When focus moves between terminal leaves, move that ownership as well;
    /// otherwise the next pet click would create a second conversation for the
    /// same visible Chat surface.
    private func rehomeAssistant(_ assistant: PetAssistant, to session: TerminalSession) {
        if let displaced = petAssistants[session.id], displaced !== assistant {
            displaced.detach()
        }
        let staleIDs = petAssistants.compactMap { id, candidate in
            candidate === assistant && id != session.id ? id : nil
        }
        for id in staleIDs { petAssistants.removeValue(forKey: id) }
        petAssistants[session.id] = assistant
        bindAssistant(assistant, to: session)
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
        controller.showSearchResults(paths, query: query)
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleCodeView(_:)) {
            let win = NSApp.keyWindow
            let standard = win.flatMap {
                $0.tabbingIdentifier == "infinitty" && $0 !== quickTerminal.window ? $0 : nil
            }
            item.state = standard.flatMap {
                utilityPanels[ObjectIdentifier($0)]?[.files]
            } != nil ? .on : .off
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

    /// Browser actions are asynchronous WebKit work.  The app-control socket
    /// runs on a worker thread, schedules the UI mutation on AppKit's main
    /// thread, then waits only on that worker for the browser completion.
    /// This deliberately avoids blocking the main run loop during navigation.
    private func handleBrowserControl(_ encoded: String) -> String {
        let request: [String: Any]
        switch BrowserControlCodec.decode(encoded) {
        case let .success(value): request = value
        case let .failure(error):
            return BrowserControlCodec.response(
                error: "invalid_request", message: error.localizedDescription)
        }
        if let version = request["v"] as? Int, version != 1 {
            return BrowserControlCodec.response(
                error: "unsupported_version", message: "Browser request version \(version) is unsupported.")
        }

        let done = DispatchSemaphore(value: 0)
        let operationState = BrowserControlOperation()
        var response = BrowserControlCodec.response(
            error: "browser_unavailable", message: "Browser control did not start.")
        let started = onMain { () -> Bool in
            guard !operationState.isCancelled else { return false }
            let operation = request["op"] as? String ?? ""
            let finish: (String) -> Void = { value in
                guard operationState.claimCompletion() else { return }
                response = value
                done.signal()
            }

            if operation == "list" {
                let browsers = self.utilityPanels.values
                    .flatMap { $0.values }
                    .compactMap(\.browser)
                    .map { $0.controlState() }
                finish(BrowserControlCodec.response(result: ["browsers": browsers]))
                return true
            }

            if operation == "open" {
                let host: NSWindow?
                if let anchor = request["anchorPane"] as? Int,
                   let session = self.sessions.first(where: { $0.id == anchor }) {
                    host = session.view.window
                } else {
                    host = NSApp.keyWindow.flatMap {
                        $0.tabbingIdentifier == "infinitty" && $0 !== self.quickTerminal.window ? $0 : nil
                    } ?? NSApp.windows.first(where: {
                        $0.tabbingIdentifier == "infinitty" && $0 !== self.quickTerminal.window
                    })
                }

                let window: NSWindow
                if let host {
                    window = host
                } else {
                    // A browser needs a real native main-tab host.  Keep the
                    // initial terminal visible instead of creating a hidden
                    // process; it also supplies the local AI/chat context.
                    let created = self.makeTerminalWindow()
                    window = created.0
                    window.orderFront(nil)
                    created.1.launch()
                }
                guard let record = self.openUtilityPanel(.browser, in: window),
                      let browser = record.browser else {
                    finish(BrowserControlCodec.response(
                        error: "open_failed", message: "Could not create a browser pane."))
                    return true
                }
                var browserRequest = request
                if let url = request["url"] as? String, !url.isEmpty {
                    browserRequest["op"] = "navigate"
                } else {
                    browserRequest["op"] = "state"
                }
                browser.performAutomation(
                    browserRequest, isCancelled: { operationState.isCancelled }, completion: finish)
                self.appControl.broadcast([
                    "event": "browser-opened", "browserId": browser.browserID,
                ])
                return true
            }

            guard let browserID = request["browserId"] as? String, !browserID.isEmpty else {
                finish(BrowserControlCodec.response(
                    error: "missing_browser", message: "browserId is required."))
                return true
            }
            guard let browser = self.utilityPanels.values
                .flatMap({ $0.values })
                .compactMap(\.browser)
                .first(where: { $0.browserID == browserID }) else {
                finish(BrowserControlCodec.response(
                    error: "unknown_browser", message: "No live browser has id \(browserID)."))
                return true
            }
            browser.performAutomation(
                request, isCancelled: { operationState.isCancelled }, completion: finish)
            return true
        } ?? false

        guard started else {
            operationState.cancel()
            return BrowserControlCodec.response(
                error: "main_thread_timeout", message: "Could not schedule browser control on the main thread.")
        }
        guard done.wait(timeout: .now() + 40) == .success else {
            operationState.cancel()
            return BrowserControlCodec.response(
                error: "timeout", message: "Browser operation timed out.")
        }
        return response
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
        case "browser":
            return handleBrowserControl(arg)
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
                self.recordPaneLedgerNote(
                    in: window, reason: "tab-presented", origin: "app-control-new-window")
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
                self.recordPaneLedgerNote(
                    in: window, reason: "tab-joined", origin: "app-control-new-tab")
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
                self.focusSession(s)
            }
            return "ok"
        case "close":
            guard let (s, _) = paneAndText(arg) else { return "error: close <id>" }
            _ = onMain {
                if let win = s.view.window {
                    self.recordPaneLedgerNote(
                        in: win, paneID: self.paneLedgerTerminalID(s), reason: "close-requested",
                        origin: "app-control-close")
                }
                s.terminate()
            }
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
            // Compatibility surface: sidebar show|hide|toggle now controls
            // the Files pane, whose internal switch includes Changes.
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
                case "hide": if self.utilityPanels[id]?[.files] != nil { self.toggleCodeView(in: win) }
                default: self.toggleCodeView(in: win)
                }
            }
            return "ok"
        case "sidebar-tab":
            // Compatibility command: Files/Changes share one pane; Chat owns
            // its own independent pane.
            let name = arg.trimmingCharacters(in: .whitespaces).lowercased()
            guard ["files", "changes", "git", "chat"].contains(name) else {
                return "error: sidebar-tab files|changes|chat"
            }
            let ok = onMain { () -> Bool in
                guard let win = NSApp.keyWindow
                    ?? NSApp.windows.first(where: { $0.tabbingIdentifier == "infinitty" })
                else { return false }
                if name == "chat" { return self.openUtilityPanel(.chat, in: win) != nil }
                guard let controller = self.openCodeView(in: win) else { return false }
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
                      let controller = self.openUtilityPanel(.chat, in: win)?.controller
                else { return false }
                return cmd == "chat-model"
                    ? controller.setChatModel(value)
                    : controller.setChatEffort(value)
            } ?? false
            return ok ? "ok" : "error: no match for \(cmd) '\(value)'"
        default:
            return "error: unknown command '\(cmd)' (ping | version | list | new-window | new-tab | "
                + "split | focus | close | send | send-line | screen | history | last-output | "
                + "last-command | exit-code | run | activity | toggle-quick-terminal | toggle-sidebar | "
                + "sidebar | sidebar-tab | chat-model | chat-effort | browser | subscribe)"
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
        configureSessionNotch()
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
                let bg = s.renderer.backgroundColor
                let color = NSColor(
                    srgbRed: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z),
                    alpha: CGFloat(bg.w))
                terminalChromes[ObjectIdentifier(win)]?.setBacking(
                    color: color, blur: config.backgroundBlur)
                utilityPanels[ObjectIdentifier(win)]?.values.forEach {
                    $0.pane.updateSurface(
                        background: color.withAlphaComponent(config.backgroundOpacity),
                        blurred: config.backgroundBlur)
                }
            }
            applyTabTint(to: win)
            refreshTabStrips(in: win)
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
        guard !running.isEmpty else {
            recordPaneLedgerNote(
                in: sender, reason: "tab-close-approved", origin: "window-close")
            return true
        }
        let alert = ForegroundProcessTracker.closeConfirmationAlert(
            for: running.map(\.info))
        let approved = alert.runModal() == .alertSecondButtonReturn
        recordPaneLedgerNote(
            in: sender,
            reason: approved ? "tab-close-approved" : "tab-close-vetoed",
            origin: "window-close")
        return approved
    }

    public func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        if paneDragState?.sourceView.window === win {
            endPaneDrag(at: .zero, cancelled: true)
        }
        let zoomKeys = paneZoomStates.compactMap { key, value in
            value.pane.window === win || value.root.window === win ? key : nil
        }
        zoomKeys.forEach { restorePaneZoom(key: $0, refocus: false, animated: false) }
        let restoringKeys = paneZoomRestoreStates.compactMap { key, value in
            value.pane.window === win || value.root.window === win ? key : nil
        }
        restoringKeys.forEach { finishPaneZoomRestore(key: $0, refocus: false) }
        // Do this before clearing the window's utility/session maps so the
        // final `-` records include Files and Chat in the tab's state.
        closePaneLedgerTab(for: win, reason: "window-closed", origin: "window-close")
        // Cancel any in-flight tab rename in this window's strip.
        terminalChromes[ObjectIdentifier(win)]?.strip.cancelRename()
        titleOverrides.removeValue(forKey: ObjectIdentifier(win))
        tabPins.removeValue(forKey: ObjectIdentifier(win))
        tabTints.removeValue(forKey: ObjectIdentifier(win))
        utilityPanels.removeValue(forKey: ObjectIdentifier(win))
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
