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

private struct ChannelConnectorDragState {
    let sourceView: NSView
    let sourceEndpoint: CollaborationEndpoint
    let overlay: ChannelWireOverlay
    var targetView: NSView?
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
    let surface: SurfacePaneController?
    let channelController: ChannelPanelController?
    let channelID: String?
    let pane: UtilityPaneView
    /// Stable pane-ledger identity. Files stays a per-window singleton
    /// (`files`); each Chat and Browser instance gets a unique
    /// `chat-N` / `browser-N` so structural records can tell them apart.
    let ledgerID: String
    /// Chat is a pane-level surface. Each Chat leaf owns its assistant; keep
    /// it alive if the terminal it started from exits while the leaf remains.
    var assistant: PetAssistant?
    /// Durable room membership is projected from the Channel journal. Before
    /// first link, an orchestrator-created Chat carries its requested role
    /// here so the atomic link-and-join publishes the exact approved role.
    var participantRole = "coding agent"
    /// Registry ownership is authoritative even while a test host or an
    /// off-screen AppKit window has not attached the pane to a visible screen.
    /// Structured control must still be able to target and close that pane.
    weak var ownerWindow: NSWindow?
    /// Preserve the exact configured provider/model for unlinked Chats.
    /// Channel membership later projects the same provenance durably.
    var configuredProvider: String?
    var configuredModel: String?
    /// Stable logical agent identity from an approved room proposal. This is
    /// also the durable Channel participant id, independent of pane numbering.
    var proposedAgentID: String?
    var proposalID: String?
    var participantCapabilities = ["channel.receive", "channel.send"]
    var cloudRuntimeAdapter:
        (any CollaborationAgentRuntimeAdapter)?

    var kind: UtilityPanelKind { pane.kind }

    init(controller: CodeViewController, pane: UtilityPaneView, ledgerID: String) {
        self.controller = controller
        self.browser = nil
        self.surface = nil
        self.channelController = nil
        self.channelID = nil
        self.pane = pane
        self.ledgerID = ledgerID
    }

    init(browser: BrowserPaneController, pane: UtilityPaneView, ledgerID: String) {
        self.controller = nil
        self.browser = browser
        self.surface = nil
        self.channelController = nil
        self.channelID = nil
        self.pane = pane
        self.ledgerID = ledgerID
    }

    init(surface: SurfacePaneController, pane: UtilityPaneView, ledgerID: String) {
        self.controller = nil
        self.browser = nil
        self.surface = surface
        self.channelController = nil
        self.channelID = nil
        self.pane = pane
        self.ledgerID = ledgerID
    }

    init(
        channel: ChannelPanelController,
        channelID: String,
        pane: UtilityPaneView,
        ledgerID: String
    ) {
        self.controller = nil
        self.browser = nil
        self.surface = nil
        self.channelController = channel
        self.channelID = channelID
        self.pane = pane
        self.ledgerID = ledgerID
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
        installRepoTipMonitor()
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
    private var settings: NSWindowController?
    private let notch = NotchActivityController()
    private let collaborationInstanceID = UUID().uuidString.lowercased()
    private let appControl = AppControlServer()
    private lazy var appInstanceRegistry = AppInstanceRegistry(
        instanceID: collaborationInstanceID,
        socketPath: appControl.path)
    private let collaborationQueue = DispatchQueue(
        label: "com.infinitty.collaboration", qos: .userInitiated)
    private let orchestrationQueue = DispatchQueue(
        label: "com.infinitty.orchestration", qos: .userInitiated)
    private lazy var collaborationCoordinator = CollaborationCoordinatorClient(
        applicationSupportDirectory: collaborationSupportDirectory)
    private var presentedProposalIDs = Set<String>()
    private var provisioningProposalIDs = Set<String>()
    private let agentWorkspaceProvisioner = AgentWorkspaceProvisioner()
    var cloudRuntimeFactory:
        any CollaborationCloudRuntimeFactoryProtocol =
            CollaborationCloudRuntimeFactory()
    private var collaborationSupportDirectory: URL? {
        if let configured = ProcessInfo.processInfo.environment[
            "INFINITTY_COLLABORATION_SUPPORT_DIR"],
           !configured.isEmpty
        {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "infinitty-app-tests-\(getpid())-\(collaborationInstanceID)",
                    isDirectory: true)
        }
        return nil
    }
    private var runQueues: [Int: RunCommandQueue] = [:] // session id -> request queue
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
    private var channelConnectorDragState: ChannelConnectorDragState?
    private var channelPopover: NSPopover?
    /// Main-thread projection only. The authoritative room and its fsyncing
    /// event store stay on `collaborationQueue`.
    private var collaborationProjection = CollaborationSnapshot(
        revision: 0, channels: [])
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
        controller.onCloseTabRequested = { [weak self] rootView, sessions in
            self?.closeQuickTerminalTab(rootView: rootView, sessions: sessions)
        }
        return controller
    }()
    /// Local mouse monitor that turns titlebar double-clicks into inline rename.
    private var titlebarClickMonitor: Any?
    private var modifierHintMonitor: Any?
    private var paneShortcutKeyMonitor: Any?
    private var foregroundProcessObserver: NSObjectProtocol?
    private var repoTipObserver: NSObjectProtocol?
    /// Repo roots the pet has already tipped about, per session id.
    private var petTipShownRoots: [Int: Set<String>] = [:]
    /// Rotation index so revisits of a root surface a different tip.
    private var petTipRotation: [String: Int] = [:]
    private var lastPetTipAt = Date.distantPast
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
        // QA hook: open Settings straight away so a screenshot pass can
        // capture it without driving the menu.
        if ProcessInfo.processInfo.environment["INFINITTY_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.openSettings(nil)
            }
        }
        // QA hook: open the assistant and submit a prompt, so a screenshot
        // pass can verify a real turn end to end without driving the UI.
        // The sidebar is preferred over the popover: it stays open long enough
        // to be looked at, and it is where the panel is actually used.
        if let prompt = ProcessInfo.processInfo.environment["INFINITTY_ASSISTANT_PROMPT"],
           !prompt.isEmpty {
            let useSidebar =
                ProcessInfo.processInfo.environment["INFINITTY_ASSISTANT_SIDEBAR"] == "1"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, let session = self.sessions.first else { return }
                if useSidebar, let win = session.view.window {
                    self.openUtilityPanel(.chat, in: win)
                } else {
                    self.presentPetAssistant(for: session)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.petAssistant(for: session).submitForQA(prompt)
                }
            }
        }
        signal(SIGPIPE, SIG_IGN)
        paneLifecycleLedger.start()
        appControl.handler = { [weak self] request in
            self?.handleAppRequest(request) ?? "error: shutting down"
        }
        appControl.start()
        do {
            try appInstanceRegistry.register()
        } catch {
            PaneLog.log("ERROR instance registry unavailable: \(error)")
        }
        collaborationQueue.async { [weak self] in
            guard let self else { return }
            guard let snapshot = self.collaborationCoordinator.snapshot() else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.applyCollaborationProjection(snapshot)
            }
        }
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
        if FullDiskAccessAssistant.launchAction(environment: environment) == .showExplicitly {
            DispatchQueue.main.async {
                FullDiskAccessAssistant.shared.show()
            }
        }
        switch ScreenRecordingPermissionAssistant.launchAction(environment: environment) {
        case .showExplicitly:
            DispatchQueue.main.async {
                ScreenRecordingPermissionAssistant.shared.show()
            }
        case .showAutomatically:
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                // At most one assistant per launch — the panels share a screen
                // position, so stacking them would hide one behind the other.
                // Full Disk Access leads: it gates the terminal's whole reason
                // for existing, screen recording only gates pane capture.
                if !FullDiskAccessAssistant.shared.showAutomaticallyIfNeeded() {
                    ScreenRecordingPermissionAssistant.shared.showAutomaticallyIfNeeded()
                }
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

    @objc func showFullDiskAccessPermission(_ sender: Any?) {
        FullDiskAccessAssistant.shared.show()
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
            let apply: (AppConfig) -> Void = { [weak self] newConfig in
                guard let self else { return }
                try? newConfig.saveAll() // writes infinitty.conf + settings.conf
                self.reloadConfig() // instant apply; also re-arms the watcher
            }
            // The ShadKit settings are opt-in until they have been looked
            // at in the real window; both take the same config and callback.
            settings = ShadcnChatFeature.usesShadcnSettings
                ? ShadcnSettingsWindowController(config: config, onSave: apply)
                : SettingsWindowController(config: config, onSave: apply)
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
        if let repoTipObserver {
            NotificationCenter.default.removeObserver(repoTipObserver)
        }
        if let foregroundProcessObserver {
            NotificationCenter.default.removeObserver(foregroundProcessObserver)
        }
        appInstanceRegistry.unregister()
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
        let channelBridge = TerminalChannelSessionBridge(
            coordinator: collaborationCoordinator,
            queue: collaborationQueue,
            endpointProvider: { [weak self, weak s] in
                guard let self, let s else { return nil }
                return self.terminalChannelEndpoint(for: s)
            },
            registrationProvider: { [weak s] in s?.channelRegistration },
            registrationSetter: { [weak s] value in
                s?.setChannelRegistration(value)
            },
            systemActor: CollaborationActor(
                id: "system:\(collaborationInstanceID)",
                kind: .system,
                displayName: "Infinitty"),
            onSnapshot: { [weak self] snapshot in
                DispatchQueue.main.async {
                    self?.applyCollaborationProjection(snapshot)
                }
            },
            onRegistered: { [weak self, weak s] registration in
                DispatchQueue.main.async {
                    guard let self, let s,
                          self.sessions.contains(where: { $0 === s })
                    else { return }
                    s.view.paneTitle = self.paneHeaderTitle(for: s)
                    self.quickTerminal.setTitle(
                        self.paneHeaderTitle(for: s),
                        for: s)
                    if let window = s.view.window {
                        self.updateTitle(for: window)
                        self.refreshTabStrips(in: window)
                    }
                    self.appControl.broadcast([
                        "event": "agent-registered",
                        "pane": s.id,
                        "name": registration.displayName,
                        "provider": registration.provider ?? "",
                    ])
                }
            },
            onUnregistered: { [weak self, weak s] in
                DispatchQueue.main.async {
                    guard let self, let s else { return }
                    // A managed MCP process can disappear while its CLI stays
                    // foreground. Re-run detection so the visual host takes
                    // ownership again instead of leaving the pane unregistered
                    // until the next process transition.
                    self.updateAgentSessionName(for: s)
                    s.view.paneTitle = self.paneHeaderTitle(for: s)
                    self.quickTerminal.setTitle(
                        self.paneHeaderTitle(for: s),
                        for: s)
                    if let window = s.view.window {
                        self.updateTitle(for: window)
                        self.refreshTabStrips(in: window)
                    }
                    self.appControl.broadcast([
                        "event": "agent-unregistered",
                        "pane": s.id,
                    ])
                }
            },
            onMessage: { [weak self, weak s] channelID, messageID in
                DispatchQueue.main.async {
                    guard let self, let s else { return }
                    self.appControl.broadcast([
                        "event": "channel-message",
                        "channelId": channelID,
                        "messageId": messageID,
                        "pane": s.id,
                    ])
                }
            })
        s.control.channelContextHandler = { channelBridge.context() }
        s.control.channelRegisterHandler = {
            channelBridge.register($0, peerProcessID: $1)
        }
        s.control.channelPostHandler = { channelBridge.post($0) }
        s.control.channelUnregisterHandler = {
            channelBridge.unregister($0, peerProcessID: $1)
        }
        s.onExited = { [weak self] session in self?.sessionDidExit(session) }
        s.onTitleChanged = { [weak self] session in
            guard let win = session.view.window else { return }
            let title = self?.paneHeaderTitle(for: session) ?? session.title
            session.view.paneTitle = title
            self?.quickTerminal.setTitle(title, for: session)
            self?.updateTitle(for: win)
            self?.appControl.broadcast(["event": "title", "pane": session.id, "title": session.title])
        }
        s.view.onFocus = { [weak self, weak s] in
            guard let self, let s, let win = s.view.window else { return }
            self.updatePaneSelection(in: win, focused: s.view)
            self.quickTerminal.setFocusedSession(s)
            self.updateTitle(for: win)
            self.refreshUtilityPanels(for: s, in: win)
        }
        s.view.onPetClick = { [weak self, weak s] in
            guard let self, let s else { return }
            self.presentPetAssistant(for: s)
        }
        s.view.onPetScaleChange = { [weak self] scale in
            self?.changePetScale(to: scale)
        }
        s.view.onPetHideUntilNeeded = { [weak self] in
            self?.hidePetUntilNeeded()
        }
        s.view.onPetKeepVisible = { [weak self] in
            self?.keepPetVisible()
        }
        s.view.onPaneRename = { [weak self, weak s] name in
            guard let self, let s else { return }
            s.paneTitleOverride = name
            s.view.paneTitle = self.paneHeaderTitle(for: s)
            self.updateCollaborationMembership(for: s.view)
        }
        // Inline ghost text already shows completions; echoing every hint as
        // a pet bubble was noise. Pet bubbles now carry repo-mined tips
        // (installRepoTipMonitor) and assistant notifications only.
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
        s.view.onClosePane = { [weak self, weak s] in
            guard let self, let s else { return }
            let running = ForegroundProcessTracker.runningProcesses(in: [s])
            if !running.isEmpty {
                let alert = ForegroundProcessTracker.closeConfirmationAlert(
                    for: running.map(\.info))
                guard alert.runModal() == .alertSecondButtonReturn else { return }
            }
            if let win = s.view.window {
                self.recordPaneLedgerNote(
                    in: win, paneID: self.paneLedgerTerminalID(s),
                    reason: "close-requested", origin: "pane-header-close")
            }
            s.terminate() // EOF path handles pane/tab teardown
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
        s.view.onChannelActivate = { [weak self, weak s] in
            guard let self, let s else { return }
            self.activateChannel(for: s.view)
        }
        s.view.onChannelDragBegan = { [weak self, weak s] point in
            guard let self, let s else { return }
            self.beginChannelConnectorDrag(sourceView: s.view, at: point)
        }
        s.view.onChannelDragMoved = { [weak self] point in
            self?.updateChannelConnectorDrag(at: point)
        }
        s.view.onChannelDragEnded = { [weak self] point, cancelled in
            self?.endChannelConnectorDrag(at: point, cancelled: cancelled)
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
                    if let queue = self.runQueues[s.id], !queue.isEmpty {
                        // Capture output at the same marker that owns it.
                        // A following queued command may finish before the
                        // waiting socket thread is scheduled again.
                        let output = s.terminal.lastCommandOutput() ?? ""
                        let nextCommand = queue.completeHead(
                            exitCode: exit, output: output)
                        if queue.isEmpty { self.runQueues[s.id] = nil }
                        if let nextCommand {
                            s.view.showAgentGlow()
                            s.pty.write(Array(nextCommand.utf8) + [0x0D])
                        }
                    }
                    s.processTracker?.poke()
                }
                self.appControl.broadcast([
                    "event": "marker", "pane": s.id,
                    "kind": String(UnicodeScalar(kind)), "exit": exit,
                ])
            }
        }
        s.onTodosChanged = { [weak self] session in
            self?.appControl.broadcast([
                "event": "todos", "pane": session.id,
                "total": session.todos.count,
                "done": session.todos.filter(\.done).count,
            ])
        }
        sessions.append(s)
        DispatchQueue.main.async { [weak self] in
            self?.refreshCollaborationProjection()
        }
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
            self.updateAgentSessionName(for: session)
            session.view.paneTitle = self.paneHeaderTitle(for: session)
            if let win = session.view.window {
                self.updateTitle(for: win)
                self.refreshTabStrips(in: win)
            }
            // Foreground-process transitions are how agents observe "a CLI
            // (claude, codex, vim…) started or finished" in a pane. An empty
            // name means the pane returned to its shell prompt.
            let process = session.processTracker?.current
            let isShell = process == nil || process?.pid == session.pty.pid
            self.appControl.broadcast([
                "event": "process", "pane": session.id,
                "name": isShell ? "" : (process?.rawName ?? ""),
                "displayName": isShell ? "" : (process?.displayName ?? ""),
            ])
        }
    }

    private func paneHeaderTitle(for session: TerminalSession) -> String {
        if let override = session.paneTitleOverride, !override.isEmpty {
            return override
        }
        if let registered = session.channelRegistration {
            return registered.displayName
        }
        if let agentName = session.agentSessionName { return agentName }
        guard let process = session.processTracker?.current,
              process.pid != session.pty.pid else { return session.title }
        return "\(session.title) — \(process.displayName)"
    }

    /// Keep `agentSessionName` in sync with the pane's foreground process:
    /// set a generated name the moment an agent CLI appears, upgrade it to the
    /// real Claude session title once the transcript exists, clear it when the
    /// pane returns to its shell.
    private func updateAgentSessionName(for session: TerminalSession) {
        let process = session.processTracker?.current
        guard let process, process.pid != session.pty.pid,
              let provider = AgentSessionNaming.provider(
                  forProcessName: "\(process.displayName) \(process.rawName)")
        else {
            if session.channelRegistration?.lifetimeToken == nil,
               session.channelRegistration != nil
            {
                _ = session.control.channelUnregisterHandler?("", getpid())
            }
            session.agentSessionName = nil
            return
        }
        let agent = provider
        if let registration = session.channelRegistration,
           registration.lifetimeToken == nil,
           registration.provider != provider
        {
            _ = session.control.channelUnregisterHandler?("", getpid())
            session.agentSessionName = nil
        }
        let needsSessionName = session.agentSessionName == nil
        let cwd = session.currentDirectory()
        if needsSessionName {
            session.agentSessionName = AgentSessionNaming.fallbackName(agent: agent, cwd: cwd)
        }
        if session.channelRegistration == nil {
            let payload: [String: Any] = [
                "v": 1,
                "displayName": AgentSessionNaming.registrationDisplayName(
                    forProvider: provider, ordinal: session.id),
                "role": "terminal agent",
                "provider": provider,
                "capabilities": ["channel.receive", "channel.send"],
            ]
            if let encoded = BrowserControlCodec.encode(payload) {
                _ = session.control.channelRegisterHandler?(encoded, process.pid)
            }
        }
        guard needsSessionName, agent == "claude", let cwd else { return }
        // The transcript appears only after the first prompt is sent; probe a
        // few times, accepting any session file modified since just before
        // the CLI was detected.
        let started = Date().addingTimeInterval(-120)
        for delay: TimeInterval in [4, 15, 40] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                [weak self, weak session] in
                guard let title = AgentSessionNaming.claudeSessionTitle(
                    cwd: cwd, startedAfter: started) else { return }
                DispatchQueue.main.async {
                    guard let self, let session,
                          session.agentSessionName != nil else { return }
                    let named = "\(agent) · \(title)"
                    guard session.agentSessionName != named else { return }
                    session.agentSessionName = named
                    session.view.paneTitle = self.paneHeaderTitle(for: session)
                    if let win = session.view.window {
                        self.updateTitle(for: win)
                        self.refreshTabStrips(in: win)
                    }
                }
            }
        }
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

    private func sessions(in win: NSWindow, rootedAt root: NSView?) -> [TerminalSession] {
        guard let root else { return activeSessions(in: win) }
        return sessions.filter {
            $0.view === root || $0.view.isDescendant(of: root)
        }
    }

    /// Resolve the terminal context owned by a pane. Chat must follow its
    /// attached assistant even when another terminal happens to be focused.
    private func sourceSession(relativeTo sourceView: NSView, in win: NSWindow) -> TerminalSession? {
        let root = terminalRoot(of: win, containing: sourceView)
        let candidates = sessions(in: win, rootedAt: root)
        if let record = utilityRecord(forPane: sourceView),
           record.kind == .chat,
           let assistant = record.assistant,
           let attached = candidates.first(where: { assistant.isAttached(to: $0) }) {
            return attached
        }
        if let terminal = sourceView as? TerminalView,
           let exact = candidates.first(where: { $0.view === terminal }) {
            return exact
        }
        if let focused = focusedSession(in: win),
           candidates.contains(where: { $0 === focused }) {
            return focused
        }
        return candidates.first
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
        if let utility = view as? UtilityPaneView {
            return utilityRecord(forPane: utility)?.ledgerID ?? utility.kind.rawValue
        }
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
        paneID: String,
        in win: NSWindow,
        reason: String,
        origin: String,
        sourceView: NSView?,
        vertical: Bool
    ) {
        guard let tabID = paneLedgerTabID(for: win) else { return }
        paneLifecycleLedger.addPane(
            tabID: tabID, paneID: paneID, reason: reason, origin: origin,
            sourcePaneID: sourceView.map { paneLedgerPaneID(for: $0) },
            axis: sourceView == nil ? nil : (vertical ? "vertical" : "horizontal"),
            topology: paneLedgerTopology(in: win))
    }

    private func recordPaneLedgerUtilityRemoved(
        paneID: String,
        in win: NSWindow,
        reason: String,
        origin: String
    ) {
        guard let tabID = paneLedgerTabID(for: win) else { return }
        paneLifecycleLedger.removePane(
            tabID: tabID, paneID: paneID, reason: reason, origin: origin,
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

    private func paneLeafViews(
        in win: NSWindow,
        rootedAt explicitRoot: NSView? = nil
    ) -> [NSView] {
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
        if let root = explicitRoot ?? terminalRoot(of: win) { collect(root) }
        return result
    }

    /// A surviving Chat pane owns its conversation. If its source terminal
    /// exits, preserve any assistant still mounted on a Chat leaf; a remaining
    /// or newly-created terminal rebinds below.
    private func retainChatAssistantAfterTerminalExit(
        _ assistant: PetAssistant?, in win: NSWindow, rootedAt root: NSView? = nil
    ) {
        guard let assistant else { return }
        let stillMounted = utilityRecords(in: win, rootedAt: root).contains {
            $0.kind == .chat && $0.assistant === assistant
        }
        // A mounted Chat still needs the old identity long enough for
        // migrateUtilityPanels to recognize and rebind it. An unowned pet
        // assistant has reached its final owner and must release every keyed
        // backend conversation rather than merely dropping its terminal.
        if !stillMounted { assistant.invalidate() }
    }

    /// Terminal focus updates Files, but a Chat pane keeps the terminal it was
    /// created against. Merely clicking another terminal must not silently
    /// change that conversation's cwd, history, or tool target.
    private func refreshUtilityPanels(
        for session: TerminalSession, in win: NSWindow, rootedAt root: NSView? = nil
    ) {
        let owningRoot = root ?? terminalRoot(of: win, containing: session.view)
        for record in utilityRecords(in: win, rootedAt: owningRoot) where record.kind != .chat {
            record.controller?.track(session: session)
        }
    }

    /// Only chats actually attached to an exiting terminal migrate to its
    /// replacement. Chats bound to other sibling terminals remain untouched.
    private func migrateUtilityPanels(
        from previous: TerminalSession, to replacement: TerminalSession?,
        in win: NSWindow, rootedAt root: NSView? = nil
    ) {
        if let replacement {
            refreshUtilityPanels(for: replacement, in: win, rootedAt: root)
        }
        for record in utilityRecords(in: win, rootedAt: root) where record.kind == .chat {
            guard let assistant = record.assistant,
                  assistant.isAttached(to: previous) else { continue }
            if let replacement {
                bindAssistant(assistant, to: replacement)
                record.controller?.track(session: replacement)
            } else {
                assistant.detach()
            }
            record.controller?.attachAssistant(assistant)
        }
    }

    private func focusedPaneLeaf(in win: NSWindow) -> NSView? {
        guard let responder = win.firstResponder as? NSView else {
            return focusedSession(in: win)?.view
        }
        return paneLeafViews(in: win).first {
            responder === $0 || responder.isDescendant(of: $0)
        }
    }

    private func updatePaneSelection(
        in win: NSWindow, focused: NSView?, rootedAt root: NSView? = nil
    ) {
        for pane in paneLeafViews(in: win, rootedAt: root) {
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
            let focusedTitle = paneHeaderTitle(for: focused)
            quickTerminal.setTitle(focusedTitle, for: focused)
            quickTerminal.setShowsShortcutHints(showTabShortcutHints)
            win.title = quickTerminal.activeTabID
                .flatMap { quickTerminal.displayTitle(for: $0) }
                ?? focusedTitle
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
        if petHiddenUntilNeeded {
            for s in sessions {
                if s.id == temporarilyRevealedPetSessionID {
                    applyPet(to: s)
                } else {
                    removePet(from: s)
                }
            }
            return
        }
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
        session.view.dismissPetSpeech(notify: false)
        session.petAnimator?.stop()
        session.petAnimator = nil
        session.renderer.setPet(texture: nil, sizePoints: 0)
    }

    /// Close one complete Quick Terminal page after its foreground-process
    /// confirmation. Terminal EOF owns terminal teardown; utility panes use
    /// their normal close path so controllers, browsers, surfaces, assistants,
    /// and backend conversations are all released exactly once.
    private func closeQuickTerminalTab(
        rootView: NSView, sessions requestedSessions: [TerminalSession]
    ) {
        guard let win = quickTerminal.window,
              quickTerminal.rootView(containing: rootView) === rootView else { return }
        let records = utilityRecords(in: win, rootedAt: rootView)
        let liveSessions = requestedSessions.filter { requested in
            sessions.contains { $0 === requested }
                && (requested.view === rootView
                    || requested.view.isDescendant(of: rootView))
        }
        let probe = records.first?.pane ?? liveSessions.first?.view
        if let probe,
           let layoutRoot = quickTerminal.paneLayoutHost(containing: probe),
           !PaneLayoutController.rootInvariantHolds(in: layoutRoot) {
            PaneLog.log(
                "ERROR quick tab close rejected invalid-root "
                    + "tree=\(PaneLog.describe(layoutRoot))")
            recordPaneLedgerFailure(
                in: win, reason: "quick-tab-close-invalid-root",
                origin: "quick-tab-strip")
            return
        }

        for record in records {
            guard closeUtilityPanel(record, in: win) else { return }
        }
        for session in liveSessions { session.terminate() }
        if liveSessions.isEmpty {
            // The final utility close normally removes the page. This also
            // handles an already-empty page without inventing a dummy shell.
            _ = quickTerminal.removeTab(rootView: rootView)
        }
    }

    private func sessionDidExit(_ s: TerminalSession) {
        // EOF can race a test/manual teardown. Claim the callback first and
        // make every later delivery for this session a no-op.
        s.onExited = nil
        guard sessions.contains(where: { $0 === s }) else { return }

        restorePaneZoom(containing: s, refocus: false)
        let wasQuickTerminal = quickTerminal.contains(s)
        let quickRoot = wasQuickTerminal
            ? quickTerminal.rootView(inTabContaining: s)
            : nil
        let quickTabWasActive = quickRoot != nil
            && quickTerminal.activeRootView === quickRoot
        let quickTabSessions = wasQuickTerminal
            ? quickTerminal.sessions(inTabContaining: s)
            : []
        let win = s.view.window
        let preservedQuickResponder: NSResponder? =
            wasQuickTerminal && !quickTabWasActive ? win?.firstResponder : nil
        let v = s.view
        let lifecycleRoot = win.flatMap {
            paneLayoutHost(of: $0, containing: v)
        }
        let tabRoot = quickRoot ?? lifecycleRoot
        // Pull the leaf out of the split tree *before* tearing the PTY/renderer
        // down so a dying Metal layer cannot blank the whole chrome surface.
        if let win {
            if let root = lifecycleRoot {
                removeExitedTerminalLeaf(v, from: root, in: win)
            } else if v.superview != nil {
                v.removeFromSuperview()
            }
        }
        leaveCollaborationPane(v)

        s.shutdown()
        pendingLaunchCommands.removeValue(forKey: s.id)
        sessions.removeAll { $0 === s }
        let exitingAssistant = petAssistants.removeValue(forKey: s.id)
        appControl.broadcast(["event": "pane-closed", "pane": s.id])
        runQueues.removeValue(forKey: s.id)?.cancelAll()

        guard let win else {
            exitingAssistant?.invalidate()
            recordPaneLedgerTerminalRemoved(
                s, in: nil, reason: "terminal-exit", origin: "pty-eof")
            return
        }

        if !wasQuickTerminal {
            recordPaneLedgerTerminalRemoved(
                s, in: win, reason: "terminal-exit", origin: "pty-eof")
        }

        let next: TerminalSession?
        if wasQuickTerminal {
            next = quickTabSessions.first { $0 !== s }
        } else {
            next = activeSessions(in: win).first
        }
        let scopedRoot = wasQuickTerminal ? quickRoot : nil
        retainChatAssistantAfterTerminalExit(
            exitingAssistant, in: win, rootedAt: scopedRoot)
        migrateUtilityPanels(
            from: s, to: next, in: win, rootedAt: scopedRoot)
        if let next, !wasQuickTerminal || quickTabWasActive {
            win.makeFirstResponder(next.view)
        } else if next == nil, !wasQuickTerminal || quickTabWasActive {
            // Last terminal in this tab — Chat/Files/Browser must keep the tab.
            if let remainingPane = paneLeafViews(
                in: win, rootedAt: tabRoot
            ).first {
                win.makeFirstResponder(remainingPane)
                updatePaneSelection(
                    in: win, focused: remainingPane, rootedAt: tabRoot)
            }
        }
        stabilizePaneTree(
            in: win, root: lifecycleRoot, reason: "terminal-exit")
        if let preservedQuickResponder {
            win.makeFirstResponder(preservedQuickResponder)
        }

        // A terminal is not the lifetime owner of a tab. Keep any Files,
        // Chat, Browser, or future smart pane alive; only the final pane leaf
        // closes this native main tab.
        //
        let remaining = remainingTabLeafCount(in: win, rootedAt: tabRoot)
        if wasQuickTerminal,
           PaneLifecyclePolicy.shouldCloseTab(remainingPaneCount: remaining) {
            if let quickRoot {
                _ = quickTerminal.removeTab(rootView: quickRoot)
            }
            refreshPets()
            refreshShortcutHints()
            return
        }
        if !wasQuickTerminal,
           PaneLifecyclePolicy.shouldCloseTab(remainingPaneCount: remaining) {
            PaneLog.log(
                "session-exit closing-tab leaves=\(remaining) "
                    + "tree=\(lifecycleRoot.map(PaneLog.describe) ?? "nil")")
            win.close()
            return
        }

        updateTitle(for: win)
        refreshPets()
        refreshShortcutHints()
        PaneLog.log(
            "session-exit remaining=\(remaining) "
                + "visible=\(paneLeafViews(in: win, rootedAt: lifecycleRoot).count) "
                + "utilities=\(utilityRecords(in: win, rootedAt: scopedRoot).count) "
                + "tree=\(lifecycleRoot.map(PaneLog.describe) ?? "nil")")
    }

    /// EOF cannot leave a dead terminal view mounted. The normal controller
    /// path preserves split ratios; if a legacy wrapper makes that path reject
    /// the leaf, detach only the dead branch, prune now-empty wrappers, and
    /// normalize the surviving pane tree.
    private func removeExitedTerminalLeaf(
        _ leaf: TerminalView, from root: NSView, in win: NSWindow
    ) {
        guard !PaneLayoutController.removeLeaf(leaf, from: root) else { return }
        PaneLog.log(
            "ERROR terminal removal failed pane=\(ObjectIdentifier(leaf)) "
                + "tree=\(PaneLog.describe(root)); forcing dead-leaf detach")
        recordPaneLedgerFailure(
            in: win, paneID: paneLedgerPaneID(for: leaf),
            reason: "terminal-remove-failed", origin: "pty-eof")

        var container = leaf.superview
        leaf.removeFromSuperview()
        while let candidate = container,
              candidate !== root,
              !(candidate is TerminalView),
              !(candidate is UtilityPaneView) {
            let parent = candidate.superview
            // `snapshot(of:)` intentionally returns nil for a corrupt plain
            // wrapper with multiple pane leaves. Treating that as empty here
            // would delete the wrapper and orphan every surviving Chat below
            // it while recovering from terminal EOF.
            let layoutBranches = candidate.subviews.filter(
                PaneLayoutController.containsLayoutLeaf)
            if layoutBranches.isEmpty {
                candidate.removeFromSuperview()
                container = parent
                continue
            }
            // A legacy plain wrapper may have held both the dead terminal and
            // one surviving pane. Unwrap that sole branch into the wrapper's
            // slot; leaving the plain view inside an NSSplitView would keep the
            // root structurally invalid even though the survivor is healthy.
            if !(candidate is NSSplitView),
               layoutBranches.count == 1,
               let survivor = layoutBranches.first,
               let parent {
                survivor.removeFromSuperview()
                if PaneLayoutController.replace(candidate, with: survivor, in: parent) {
                    container = parent
                    continue
                }
                candidate.addSubview(survivor)
            }
            break
        }
        _ = PaneLayoutController.normalizeRoot(in: root)
        PaneLayoutController.stabilizeRoot(in: root)
    }

    /// A tab's lifetime follows reachable layout leaves. Registry entries are
    /// bookkeeping, not hidden panes; counting detached records here preserved
    /// blank zombie windows after a structural failure.
    private func remainingTabLeafCount(
        in win: NSWindow, rootedAt root: NSView? = nil
    ) -> Int {
        paneLeafViews(in: win, rootedAt: root).count
    }

    /// Maintain the pane host's single-root invariant without changing
    /// unaffected divider ratios or reparenting nested leaves.
    private func stabilizePaneTree(
        in win: NSWindow, root explicitRoot: NSView? = nil, reason: String
    ) {
        guard let root = explicitRoot ?? paneLayoutHost(of: win) else { return }
        _ = PaneLayoutController.normalizeRoot(in: root)
        PaneLayoutController.stabilizeRoot(in: root)
        guard PaneLayoutController.rootInvariantHolds(in: root) else {
            PaneLog.log(
                "ERROR invalid pane root after \(reason) tree=\(PaneLog.describe(root))")
            recordPaneLedgerFailure(
                in: win, reason: "invalid-pane-root", origin: reason)
            return
        }
        PaneLog.log("pane root stable after \(reason) tree=\(PaneLog.describe(root))")
    }

    /// A split with a single child left dissolves into its parent.
    private func collapse(_ split: NSSplitView, in win: NSWindow) {
        guard split.arrangedSubviews.count == 1 else { return }
        let sibling = split.arrangedSubviews[0]
        let parent = split.superview
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
            // Compatibility path for legacy/test content-view splits. Native
            // pane hosts use PaneLayoutController.removeLeaf directly.
            _ = PaneLayoutController.collapseSingleChildSplit(split)
        }
        win.contentView?.needsLayout = true
        win.contentView?.layoutSubtreeIfNeeded()
        // Walk up: parent may now be a one-child split after this dissolve.
        if let parentSplit = parent as? NSSplitView {
            collapse(parentSplit, in: win)
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
        session.view.configurePetInteraction(
            scale: config.petScale,
            temporarilyRevealed: petHiddenUntilNeeded
                && temporarilyRevealedPetSessionID == session.id)
        if session.petAnimator == nil {
            let animator = PetAnimator(terminal: session.terminal, renderer: session.renderer)
            session.petAnimator = animator
            animator.start()
        }
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(cwd: nil)
    }

    /// Opens the ShadKit component gallery, for eyeballing the AI controls
    /// against the shadcn and AI Elements references.
    @objc func showDesignGallery(_ sender: Any?) {
        DesignGalleryWindowController.present()
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
        let t0 = CFAbsoluteTimeGetCurrent()
        let source = focusedSession() ?? activeSessions(in: key).first
        let cwd = source?.currentDirectory()
        let t1 = CFAbsoluteTimeGetCurrent()
        let (window, session) = makeTerminalWindow(cwd: cwd)
        let t2 = CFAbsoluteTimeGetCurrent()
        key.addTabbedWindow(window, ordered: .above)
        let t3 = CFAbsoluteTimeGetCurrent()
        recordPaneLedgerNote(in: window, reason: "tab-joined", origin: "menu-new-tab")
        window.makeKeyAndOrderFront(nil)
        let t4 = CFAbsoluteTimeGetCurrent()
        session.launch()
        let t5 = CFAbsoluteTimeGetCurrent()
        PaneLog.log(String(
            format: "NEWTAB cwd=%.0f make=%.0f addTab=%.0f key=%.0f launch=%.0f total=%.0f ms",
            (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000,
            (t4 - t3) * 1000, (t5 - t4) * 1000, (t5 - t0) * 1000))
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
            // Split chooser always places a fresh Chat leaf (multi-chat panes).
            _ = openUtilityPanel(
                .chat, in: win, relativeTo: context.sourceView, vertical: context.vertical,
                forceNewInstance: true)
        case .channel:
            guard let channelID = channelID(for: context.sourceView) else {
                presentChannelSummary(
                    for: context.sourceView,
                    errorMessage: "Link this pane to a Channel first.")
                return
            }
            _ = openChannelPanel(
                channelID: channelID,
                in: win,
                relativeTo: context.sourceView,
                vertical: context.vertical)
        case .browser:
            // The split chooser places a pane at a chosen spot, so it always
            // creates a fresh Browser instance instead of refocusing one.
            _ = openUtilityPanel(
                .browser, in: win, relativeTo: context.sourceView, vertical: context.vertical,
                forceNewInstance: true)
        case nil:
            break
        }
    }

    @discardableResult
    private func splitTerminal(
        relativeTo sourceView: NSView,
        vertical: Bool,
        newFirst: Bool = false
    ) -> TerminalSession? {
        restorePaneZoom(containing: sourceView, refocus: false)
        guard let win = sourceView.window else { return nil }
        let session = createSession(
            scale: win.backingScaleFactor,
            usesSharedWindowSurface: terminalChromes[ObjectIdentifier(win)] != nil)
        session.workingDirectory = sourceSession(
            relativeTo: sourceView, in: win)?.currentDirectory()
        guard insertPaneView(
            session.view,
            relativeTo: sourceView,
            vertical: vertical,
            newFirst: newFirst)
        else {
            recordPaneLedgerFailure(
                in: win, paneID: paneLedgerTerminalID(session), reason: "split-insert-failed",
                origin: "pane-header")
            session.shutdown()
            sessions.removeAll { $0 === session }
            return nil
        }
        recordPaneLedgerTerminalAdded(
            session, in: win, reason: vertical ? "split-right" : "split-down",
            origin: "pane-header", sourceView: sourceView, vertical: vertical)
        session.launch()
        if let sourceRecord = utilityRecord(forPane: sourceView),
           sourceRecord.kind == .chat,
           let assistant = sourceRecord.assistant {
            bindAssistantAfterChatSplit(assistant, to: session)
            sourceRecord.controller?.track(session: session)
            sourceRecord.controller?.attachAssistant(assistant)
        }
        refreshUtilityPanels(for: session, in: win)
        win.makeFirstResponder(session.view)
        refreshPets()
        updateTitle(for: win)
        refreshShortcutHints()
        return session
    }

    /// Resolves the stable handle returned by `list` for any pane kind. Legacy
    /// numeric terminal ids remain valid, while utility panes can be addressed
    /// by ledger id, Channel endpoint id, browser id, or Channel panel id.
    private func controlPane(withHandle handle: String) -> NSView? {
        if let terminalID = Int(handle),
           let session = sessions.first(where: { $0.id == terminalID })
        {
            return session.view
        }
        for records in utilityPanels.values {
            for record in records {
                if record.ledgerID == handle
                    || record.browser?.browserID == handle
                    || collaborationEndpoint(for: record.pane).id == handle
                {
                    return record.pane
                }
            }
        }
        return liveCollaborationPanes().first {
            collaborationEndpoint(for: $0).id == handle
        }
    }

    @discardableResult
    private func insertPaneView(
        _ newView: NSView, relativeTo oldView: NSView,
        vertical: Bool, newFirst: Bool = false
    ) -> Bool {
        let owningWindow = oldView.window
        if let owningWindow,
           let root = paneLayoutHost(of: owningWindow, containing: oldView) {
            _ = PaneLayoutController.normalizeRoot(in: root)
            guard PaneLayoutController.rootInvariantHolds(in: root) else {
                PaneLog.log(
                    "ERROR split insert invalid source root tree=\(PaneLog.describe(root))")
                return false
            }
        }
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
        // Seed both children with usable local geometry before AppKit asks
        // their internal Auto Layout trees to resolve. A newly constructed
        // Shadcn Chat starts at `.zero`; adding it at that size can transiently
        // break its required composer constraints and leave the split at
        // width zero before the deferred divider-centering pass.
        let localBounds = split.bounds
        let divider = split.dividerThickness
        let firstFrame: NSRect
        let secondFrame: NSRect
        if vertical {
            let usable = max(localBounds.width - divider, 0)
            let firstWidth = usable / 2
            firstFrame = NSRect(
                x: 0, y: 0, width: firstWidth, height: localBounds.height)
            secondFrame = NSRect(
                x: firstWidth + divider, y: 0,
                width: usable - firstWidth, height: localBounds.height)
        } else {
            let usable = max(localBounds.height - divider, 0)
            let firstHeight = usable / 2
            firstFrame = NSRect(
                x: 0, y: localBounds.height - firstHeight,
                width: localBounds.width, height: firstHeight)
            secondFrame = NSRect(
                x: 0, y: 0,
                width: localBounds.width, height: usable - firstHeight)
        }
        if newFirst {
            newView.frame = firstFrame
            oldView.frame = secondFrame
            split.addArrangedSubview(newView)
            split.addArrangedSubview(oldView)
        } else {
            oldView.frame = firstFrame
            newView.frame = secondFrame
            split.addArrangedSubview(oldView)
            split.addArrangedSubview(newView)
        }
        if let owningWindow { applyTabTint(to: owningWindow) }
        if let owningWindow,
           let root = paneLayoutHost(of: owningWindow, containing: oldView) {
            PaneLayoutController.stabilizeRoot(in: root)
        }
        // Establish usable geometry immediately. The deferred pass below
        // handles the final window layout, but a rapid add-then-close can
        // happen before that runloop turn and must not capture zero ratios.
        split.layoutSubtreeIfNeeded()
        let initialMid = split.isVertical ? split.bounds.width / 2 : split.bounds.height / 2
        if initialMid > 0 { split.setPosition(initialMid, ofDividerAt: 0) }
        DispatchQueue.main.async { [weak split] in
            guard let split, split.superview != nil,
                  split.arrangedSubviews.count == 2 else { return }
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
        guard let win = pane.window,
              let root = terminalRoot(of: win, containing: pane) else { return }
        let key = ObjectIdentifier(root)
        if paneZoomStates[key] != nil {
            restorePaneZoom(key: key, refocus: true, animated: true)
            return
        }
        if paneZoomRestoreStates[key] != nil {
            finishPaneZoomRestore(key: key, refocus: true)
            return
        }

        let panes = paneLeafViews(in: win, rootedAt: root)
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
        guard let win = pane.window,
              let root = terminalRoot(of: win, containing: pane) else { return }
        if let entry = paneZoomStates.first(where: { $0.value.root === root }) {
            restorePaneZoom(key: entry.key, refocus: refocus, animated: animated)
        } else if let entry = paneZoomRestoreStates.first(where: { $0.value.root === root }) {
            finishPaneZoomRestore(key: entry.key, refocus: refocus)
        }
    }

    private func restorePaneZoom(revealing pane: NSView) {
        guard let win = pane.window,
              let root = terminalRoot(of: win, containing: pane) else { return }
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

    // MARK: - collaboration Channels

    private func collaborationEndpoint(for view: NSView) -> CollaborationEndpoint {
        let paneID = paneLedgerPaneID(for: view)
        let kind: CollaborationEndpoint.Kind
        let label: String
        let participantID: String?
        if let terminal = view as? TerminalView {
            kind = .terminal
            if let session = sessions.first(where: { $0.view === terminal }),
               let registration = session.channelRegistration
            {
                label = registration.displayName
                participantID = TerminalAgentRegistration.participantID(
                    endpointID: "\(collaborationInstanceID)/\(paneID)")
            } else {
                label = terminal.paneTitle
                participantID = nil
            }
        } else if let utility = view as? UtilityPaneView {
            switch utility.kind {
            case .chat: kind = .chat
            case .channel: kind = .channel
            case .browser: kind = .browser
            case .surface: kind = .surface
            case .files: kind = CollaborationEndpoint.Kind(rawValue: "files")
            }
            label = utility.paneHeader.title
            participantID = utility.kind == .chat
                ? utilityRecord(forPane: utility)?.proposedAgentID
                    ?? "\(collaborationInstanceID)/participant/\(paneID)"
                : nil
        } else {
            kind = CollaborationEndpoint.Kind(rawValue: "pane")
            label = paneID
            participantID = nil
        }
        return CollaborationEndpoint(
            id: "\(collaborationInstanceID)/\(paneID)",
            kind: kind,
            label: label,
            participantID: participantID,
            instanceID: collaborationInstanceID)
    }

    private func collaborationParticipant(for view: NSView)
        -> CollaborationParticipant?
    {
        if let terminal = view as? TerminalView,
           let session = sessions.first(where: { $0.view === terminal }),
           let registration = session.channelRegistration
        {
            let endpointID = "\(collaborationInstanceID)/"
                + paneLedgerTerminalID(session)
            return registration.participant(endpointID: endpointID)
        }
        guard let utility = view as? UtilityPaneView,
              utility.kind == .chat,
              let participantID = collaborationEndpoint(for: utility).participantID
        else { return nil }
        return CollaborationParticipant(
            id: participantID,
            displayName: utility.paneHeader.title,
            role: utilityRecord(forPane: utility)?.participantRole
                ?? "coding agent",
            provider: utilityRecord(forPane: utility)?.configuredProvider,
            modelID: utilityRecord(forPane: utility)?.configuredModel,
            capabilities:
                utilityRecord(forPane: utility)?.participantCapabilities
                ?? ["channel.receive", "channel.send"])
    }

    private func terminalChannelEndpoint(
        for session: TerminalSession
    ) -> CollaborationEndpoint {
        let endpointID = "\(collaborationInstanceID)/"
            + paneLedgerTerminalID(session)
        let registration = session.channelRegistration
        let label: String
        if let registration {
            label = registration.displayName
        } else if Thread.isMainThread {
            label = paneHeaderTitle(for: session)
        } else {
            label = DispatchQueue.main.sync {
                self.paneHeaderTitle(for: session)
            }
        }
        return CollaborationEndpoint(
            id: endpointID,
            kind: .terminal,
            label: label,
            participantID: registration.map { _ in
                TerminalAgentRegistration.participantID(endpointID: endpointID)
            },
            instanceID: collaborationInstanceID)
    }

    private func paneHeader(for view: NSView) -> PaneHeaderView? {
        if let terminal = view as? TerminalView { return terminal.paneHeader }
        if let utility = view as? UtilityPaneView { return utility.paneHeader }
        return nil
    }

    private func liveCollaborationPanes() -> [NSView] {
        NSApp.windows.flatMap { paneLeafViews(in: $0) }
    }

    private func channel(for endpointID: String) -> CollaborationChannelState? {
        collaborationProjection.channels.first {
            $0.endpoints.contains(where: { $0.id == endpointID })
        }
    }

    private func channelID(for pane: NSView) -> String? {
        if let record = utilityRecord(forPane: pane),
           let channelID = record.channelID
        {
            return channelID
        }
        return channel(for: collaborationEndpoint(for: pane).id)?.id
    }

    private func activateChannel(for pane: NSView) {
        guard let channelID = channelID(for: pane),
              let window = pane.window
        else {
            presentChannelSummary(for: pane)
            return
        }
        _ = openChannelPanel(
            channelID: channelID,
            in: window,
            relativeTo: pane,
            vertical: true)
    }

    private func beginChannelConnectorDrag(sourceView: NSView, at point: NSPoint) {
        endChannelConnectorDrag(at: point, cancelled: true)
        let endpoint = collaborationEndpoint(for: sourceView)
        let existing = channel(for: endpoint.id)
        let color = existing.map { collaborationColor(hex: $0.colorHex) }
            ?? NSColor.controlAccentColor
        let anchor = paneHeader(for: sourceView)?.channelConnectorScreenFrame
        let start = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? point
        channelConnectorDragState = ChannelConnectorDragState(
            sourceView: sourceView,
            sourceEndpoint: endpoint,
            overlay: ChannelWireOverlay(start: start, color: color),
            targetView: nil)
        updateChannelConnectorDrag(at: point)
    }

    private func updateChannelConnectorDrag(at point: NSPoint) {
        guard var state = channelConnectorDragState else { return }
        let target = liveCollaborationPanes().first { candidate in
            guard candidate !== state.sourceView,
                  !candidate.isHiddenOrHasHiddenAncestor,
                  let frame = paneHeader(for: candidate)?.channelConnectorScreenFrame
            else { return false }
            return frame.insetBy(dx: -7, dy: -7).contains(point)
        }
        if state.targetView !== target {
            state.targetView.flatMap(paneHeader(for:))?.setChannelDropTarget(false)
            target.flatMap(paneHeader(for:))?.setChannelDropTarget(true)
            state.targetView = target
        }
        let targetColor = target.flatMap {
            channel(for: collaborationEndpoint(for: $0).id)
        }.map { collaborationColor(hex: $0.colorHex) }
        state.overlay.update(end: point, color: targetColor)
        channelConnectorDragState = state
    }

    private func endChannelConnectorDrag(at point: NSPoint, cancelled: Bool) {
        guard let state = channelConnectorDragState else { return }
        channelConnectorDragState = nil
        state.targetView.flatMap(paneHeader(for:))?.setChannelDropTarget(false)
        state.overlay.close()
        guard !cancelled, let target = state.targetView else { return }
        linkCollaborationPanes(source: state.sourceView, target: target)
    }

    private func linkCollaborationPanes(
        source: NSView,
        target: NSView,
        completion: ((Result<CollaborationSnapshot, Error>) -> Void)? = nil
    ) {
        let sourceEndpoint = collaborationEndpoint(for: source)
        let targetEndpoint = collaborationEndpoint(for: target)
        let chatParticipants = [source, target]
            .compactMap(collaborationParticipant(for:))
        let actor = CollaborationActor(
            id: "local-user:\(NSUserName())",
            kind: .human,
            displayName: NSFullUserName().isEmpty ? NSUserName() : NSFullUserName())
        let sourceEndpointID = sourceEndpoint.id
        let commandID = UUID().uuidString.lowercased()

        collaborationQueue.async { [weak self, weak source] in
            guard let self else { return }
            do {
                let request = CollaborationControlRequest(
                    op: .linkAndJoin,
                    actor: actor,
                    idempotencyKey: commandID,
                    source: sourceEndpoint,
                    target: targetEndpoint,
                    participants: chatParticipants)
                guard let encoded = CollaborationControlCodec.encode(request) else {
                    throw CollaborationRoomError.invalidValue(
                        field: "request", reason: "could not encode link")
                }
                let result = self.collaborationCoordinator.execute(encoded)
                guard let snapshot = result.snapshot else {
                    throw CollaborationRoomError.invalidValue(
                        field: "coordinator", reason: result.response)
                }
                guard snapshot.channels.contains(where: {
                    $0.endpoints.contains(where: {
                        $0.id == sourceEndpointID
                            || $0.id == targetEndpoint.id
                    })
                }) else {
                    throw CollaborationRoomError.invalidValue(
                        field: "channel", reason: "link produced no Channel")
                }
                DispatchQueue.main.async { [weak self] in
                    self?.applyCollaborationProjection(snapshot)
                    completion?(.success(snapshot))
                }
            } catch {
                self.appControl.broadcast([
                    "event": "channel-error",
                    "commandId": commandID,
                    "message": String(describing: error),
                ])
                DispatchQueue.main.async { [weak self, weak source] in
                    if let self, let source {
                        NSSound.beep()
                        self.presentChannelSummary(
                            for: source,
                            errorMessage: String(describing: error))
                    }
                    completion?(.failure(error))
                }
            }
        }
    }

    private func applyCollaborationProjection(_ snapshot: CollaborationSnapshot) {
        dispatchPrecondition(condition: .onQueue(.main))
        collaborationProjection = snapshot
        for pane in liveCollaborationPanes() {
            if let utility = pane as? UtilityPaneView,
               utility.kind == .channel,
               let record = utilityRecord(forPane: utility),
               let channelID = record.channelID,
               let state = snapshot.channels.first(where: {
                   $0.id == channelID
               })
            {
                let color = collaborationColor(hex: state.colorHex)
                utility.paneHeader.title = state.name
                utility.setChannel(
                    name: state.name,
                    color: color,
                    memberCount: state.endpoints.count)
                utility.setPaneAccent(color)
                record.channelController?.update(
                    channel: state,
                    proposals: snapshot.proposals)
                continue
            }
            let endpointID = collaborationEndpoint(for: pane).id
            let state = channel(for: endpointID)
            let color = state.map { collaborationColor(hex: $0.colorHex) }
            let memberCount = state?.endpoints.count ?? 0
            if let terminal = pane as? TerminalView {
                terminal.setChannel(
                    name: state?.name, color: color, memberCount: memberCount)
                terminal.setPaneAccent(color ?? CodePalette.paneFocusAccent)
            } else if let utility = pane as? UtilityPaneView {
                utility.setChannel(
                    name: state?.name, color: color, memberCount: memberCount)
                utility.setPaneAccent(color ?? CodePalette.paneFocusAccent)
            }
        }
        presentPendingProposalConsents(snapshot)
        for proposal in snapshot.proposals
        where [.approved, .provisioning].contains(proposal.state)
            && proposal.spec.presentation == .visual
            && (proposal.spec.targetInstanceID == nil
                || proposal.spec.targetInstanceID
                    == collaborationInstanceID)
        {
            provisionApprovedProposal(proposal)
        }
    }

    private func refreshCollaborationProjection() {
        applyCollaborationProjection(collaborationProjection)
    }

    private func configureCollaboration(
        for record: UtilityPanelRecord,
        assistant: PetAssistant
    ) {
        guard record.kind == .chat else { return }
        assistant.configureCollaboration(
            contextProvider: { [weak self, weak record] in
                guard let self, let record else { return nil }
                let endpointID = self.collaborationEndpoint(for: record.pane).id
                return CollaborationChatContext(
                    snapshot: self.authoritativeCollaborationSnapshot(),
                    endpointID: endpointID)
            },
            messagePublisher: { [weak self, weak record] emission in
                guard let self, let record else { return }
                self.publishCollaborationMessage(emission, for: record)
            },
            identityPublisher: { [weak self, weak record] provider, model in
                guard let self, let record else { return }
                self.updateCollaborationMembership(
                    for: record.pane,
                    provenance: (provider, model))
            })
    }

    /// Provider turns read through the room's serial lane instead of the
    /// eventually-applied AppKit projection. `sync` waits behind any prompt or
    /// response publication already queued by a peer, closing the race where
    /// a fast next turn could miss a response that was visible in the other
    /// Chat but not yet painted into `collaborationProjection`.
    private func authoritativeCollaborationSnapshot() -> CollaborationSnapshot {
        let fallback = collaborationProjection
        return collaborationQueue.sync {
            collaborationCoordinator.snapshot() ?? fallback
        }
    }

    private func leaveCollaborationPane(_ pane: NSView) {
        let endpointID = collaborationEndpoint(for: pane).id
        let actor = CollaborationActor(
            id: "local-user:\(NSUserName())",
            kind: .human,
            displayName: NSFullUserName().isEmpty
                ? NSUserName()
                : NSFullUserName())
        let result: Result<CollaborationSnapshot?, Error> = collaborationQueue.sync {
            guard collaborationCoordinator.snapshot()?.channels.contains(where: {
                      $0.endpoints.contains(where: { $0.id == endpointID })
                  }) == true
            else { return .success(nil) }
            let request = CollaborationControlRequest(
                op: .leave,
                actor: actor,
                idempotencyKey:
                    "pane-leave:\(endpointID):\(UUID().uuidString)",
                endpointID: endpointID)
            guard let encoded = CollaborationControlCodec.encode(request) else {
                return .failure(CollaborationRoomError.invalidValue(
                    field: "request", reason: "could not encode leave"))
            }
            let executed = collaborationCoordinator.execute(encoded)
            guard let snapshot = executed.snapshot else {
                return .failure(CollaborationRoomError.invalidValue(
                    field: "coordinator", reason: executed.response))
            }
            return .success(snapshot)
        }
        switch result {
        case .success(let snapshot):
            if let snapshot { applyCollaborationProjection(snapshot) }
        case .failure(let error):
            appControl.broadcast([
                "event": "channel-error",
                "endpointId": endpointID,
                "message": String(describing: error),
            ])
        }
    }

    private func updateCollaborationMembership(
        for pane: NSView,
        provenance: (provider: String?, model: String?)? = nil
    ) {
        let endpoint = collaborationEndpoint(for: pane)
        let snapshot = authoritativeCollaborationSnapshot()
        guard let channel = snapshot.channels.first(where: {
            $0.endpoints.contains(where: { $0.id == endpoint.id })
        }) else { return }
        let previous = endpoint.participantID.flatMap { participantID in
            channel.participants.first { $0.id == participantID }
        }
        let participant = previous.map {
            let provider: String?
            let model: String?
            if let provenance {
                provider = provenance.provider
                model = provenance.model
            } else {
                provider = $0.provider
                model = $0.modelID
            }
            return CollaborationParticipant(
                id: $0.id,
                displayName: endpoint.label,
                role: $0.role,
                provider: provider,
                modelID: model,
                capabilities: $0.capabilities)
        }
        if channel.endpoints.first(where: { $0.id == endpoint.id }) == endpoint,
           participant == previous
        {
            return
        }
        let actor = CollaborationActor(
            id: "local-user:\(NSUserName())",
            kind: .human,
            displayName: NSFullUserName().isEmpty
                ? NSUserName()
                : NSFullUserName())
        do {
            let updated: CollaborationSnapshot = try collaborationQueue.sync {
                let request = CollaborationControlRequest(
                    op: .updateMembership,
                    actor: actor,
                    idempotencyKey:
                        "membership-update:\(endpoint.id):\(UUID().uuidString)",
                    channelID: channel.id,
                    endpoint: endpoint,
                    participant: participant)
                guard let encoded = CollaborationControlCodec.encode(request) else {
                    throw CollaborationRoomError.invalidValue(
                        field: "request",
                        reason: "could not encode membership update")
                }
                let result = collaborationCoordinator.execute(encoded)
                guard let snapshot = result.snapshot else {
                    throw CollaborationRoomError.invalidValue(
                        field: "coordinator", reason: result.response)
                }
                return snapshot
            }
            applyCollaborationProjection(updated)
        } catch {
            if let previous {
                paneHeader(for: pane)?.title = previous.displayName
            }
            appControl.broadcast([
                "event": "channel-error",
                "endpointId": endpoint.id,
                "message": String(describing: error),
            ])
            NSSound.beep()
        }
    }

    private func publishCollaborationMessage(
        _ emission: CollaborationChatEmission,
        for record: UtilityPanelRecord
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self, weak record] in
                guard let self, let record else { return }
                self.publishCollaborationMessage(emission, for: record)
            }
            return
        }
        let endpoint = collaborationEndpoint(for: record.pane)
        guard let channel = channel(for: endpoint.id),
              let participantID = endpoint.participantID
        else { return }

        let actor: CollaborationActor
        let authorID: String
        switch emission.kind {
        case .humanPrompt:
            authorID = "human:\(NSUserName())"
            actor = CollaborationActor(
                id: authorID,
                kind: .human,
                displayName: NSFullUserName().isEmpty
                    ? NSUserName()
                    : NSFullUserName())
        case .agentResponse:
            authorID = participantID
            actor = CollaborationActor(
                id: participantID,
                kind: .agent,
                displayName: record.pane.paneHeader.title)
        case .runtimeFailure:
            authorID = "system:runtime"
            actor = CollaborationActor(
                id: authorID,
                kind: .system,
                displayName:
                    "Runtime for \(record.pane.paneHeader.title)")
        }
        let messageText: String
        if emission.kind == .runtimeFailure {
            messageText =
                "Runtime failure for \(record.pane.paneHeader.title): "
                + emission.text
        } else {
            messageText = emission.text
        }
        let messageID = UUID().uuidString.lowercased()
        let message = CollaborationMessage(
            id: messageID,
            threadID: emission.threadID,
            authorID: authorID,
            text: CollaborationMessage.boundedChannelText(messageText))

        collaborationQueue.async { [weak self] in
            guard let self else { return }
            let request = CollaborationControlRequest(
                op: .postMessage,
                actor: actor,
                idempotencyKey: "chat-message:\(messageID)",
                channelID: channel.id,
                message: message)
            if let encoded = CollaborationControlCodec.encode(request) {
                let result = self.collaborationCoordinator.execute(encoded)
                if let snapshot = result.snapshot {
                    DispatchQueue.main.async { [weak self] in
                        self?.applyCollaborationProjection(snapshot)
                    }
                    return
                }
                self.appControl.broadcast([
                    "event": "channel-error",
                    "messageId": messageID,
                    "message": result.response,
                ])
            } else {
                self.appControl.broadcast([
                    "event": "channel-error",
                    "messageId": messageID,
                    "message": "Could not encode Channel message.",
                ])
            }
        }
    }

    private func postChannelPanelMessage(
        _ text: String,
        threadID: String?,
        channelID: String
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let actorID = "human:\(NSUserName())"
        let actor = CollaborationActor(
            id: actorID,
            kind: .human,
            displayName: NSFullUserName().isEmpty
                ? NSUserName()
                : NSFullUserName())
        let message = CollaborationMessage(
            id: UUID().uuidString.lowercased(),
            threadID: threadID,
            authorID: actorID,
            text: CollaborationMessage.boundedChannelText(trimmed))
        collaborationQueue.async { [weak self] in
            guard let self else { return }
            let request = CollaborationControlRequest(
                op: .postMessage,
                actor: actor,
                idempotencyKey: "channel-panel-message:\(message.id)",
                channelID: channelID,
                message: message)
            guard let encoded = CollaborationControlCodec.encode(request) else {
                self.appControl.broadcast([
                    "event": "channel-error",
                    "channelId": channelID,
                    "message": "Could not encode Channel panel message.",
                ])
                return
            }
            let result = self.collaborationCoordinator.execute(encoded)
            guard let snapshot = result.snapshot else {
                self.appControl.broadcast([
                    "event": "channel-error",
                    "channelId": channelID,
                    "message": result.response,
                ])
                return
            }
            self.appControl.broadcast([
                "event": "channel-message",
                "channelId": channelID,
                "messageId": message.id,
                "threadId": threadID ?? "",
            ])
            DispatchQueue.main.async { [weak self] in
                self?.applyCollaborationProjection(snapshot)
            }
        }
    }

    private func updateChannelParticipantRole(
        participantID: String,
        role: String,
        channelID: String
    ) {
        let role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !role.isEmpty,
              let channel = authoritativeCollaborationSnapshot()
                .channels.first(where: { $0.id == channelID }),
              let participant = channel.participants.first(where: {
                  $0.id == participantID
              }),
              participant.role != role,
              let endpoint = channel.endpoints.first(where: {
                  $0.participantID == participantID
              })
        else { return }
        let updated = CollaborationParticipant(
            id: participant.id,
            displayName: participant.displayName,
            role: role,
            provider: participant.provider,
            modelID: participant.modelID,
            capabilities: participant.capabilities)
        let actor = CollaborationActor(
            id: "local-user:\(NSUserName())",
            kind: .human,
            displayName: NSFullUserName().isEmpty
                ? NSUserName()
                : NSFullUserName())
        collaborationQueue.async { [weak self] in
            guard let self else { return }
            let request = CollaborationControlRequest(
                op: .updateMembership,
                actor: actor,
                idempotencyKey:
                    "channel-role:\(participantID):\(UUID().uuidString)",
                channelID: channelID,
                endpoint: endpoint,
                participant: updated)
            guard let encoded = CollaborationControlCodec.encode(request) else {
                return
            }
            let result = self.collaborationCoordinator.execute(encoded)
            guard let snapshot = result.snapshot else {
                self.appControl.broadcast([
                    "event": "channel-error",
                    "channelId": channelID,
                    "message": result.response,
                ])
                return
            }
            self.appControl.broadcast([
                "event": "channel-role-updated",
                "channelId": channelID,
                "participantId": participantID,
                "role": role,
            ])
            DispatchQueue.main.async { [weak self] in
                self?.applyCollaborationProjection(snapshot)
            }
        }
    }

    private func presentPendingProposalConsents(
        _ snapshot: CollaborationSnapshot
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let window = standardKeyWindow()
                ?? NSApp.windows.first(where: {
                    $0.tabbingIdentifier == "infinitty"
                        && $0 !== quickTerminal.window
                })
        else { return }
        for proposal in snapshot.proposals
        where proposal.state == .pending
            && !presentedProposalIDs.contains(proposal.spec.id)
        {
            presentedProposalIDs.insert(proposal.spec.id)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText =
                "Create “\(proposal.spec.roomName)” with "
                + "\(proposal.spec.agents.count) agents?"
            let agentDetails = proposal.spec.agents.map { agent in
                let model = agent.modelID.map { " / \($0)" } ?? ""
                let scopes = agent.responsibilityScopes.isEmpty
                    ? "no file scope declared"
                    : agent.responsibilityScopes.joined(separator: ", ")
                return
                    "\(agent.displayName) — \(agent.role)\n"
                    + "\(agent.runtime.rawValue) · \(agent.provider)\(model)\n"
                    + "Owns: \(scopes)"
            }.joined(separator: "\n\n")
            let workspace = proposal.spec.workspaceStrategy.rawValue
                .replacingOccurrences(of: "_", with: " ")
            let target = proposal.spec.targetInstanceID.map {
                "\nTarget instance: \($0)"
            } ?? ""
            alert.informativeText =
                "\(proposal.spec.objective)\n\n"
                + "Workspace: \(proposal.spec.workspaceRoot)\n"
                + "Workspace mode: \(workspace)\n"
                + "Presentation: \(proposal.spec.presentation.rawValue)"
                + "\(target)\n\n"
                + agentDetails
                + "\n\nNothing is created until you approve."
            alert.addButton(withTitle: "Create room and agents")
            alert.addButton(withTitle: "Deny")
            alert.beginSheetModal(for: window) {
                [weak self] response in
                self?.decideChannelProposal(
                    proposalID: proposal.spec.id,
                    digest: proposal.digest,
                    approved:
                        response == .alertFirstButtonReturn)
            }
        }
    }

    private func decideChannelProposal(
        proposalID: String,
        digest: String,
        approved: Bool
    ) {
        let actor = CollaborationActor(
            id: "local-user:\(NSUserName())",
            kind: .human,
            displayName: NSFullUserName().isEmpty
                ? NSUserName()
                : NSFullUserName())
        collaborationQueue.async { [weak self] in
            guard let self else { return }
            let request = CollaborationControlRequest(
                op: approved ? .approveProposal : .denyProposal,
                actor: actor,
                idempotencyKey:
                    "proposal-decision:\(proposalID):"
                    + "\(approved ? "approve" : "deny")",
                proposalID: proposalID,
                proposalDigest: digest,
                reason: approved
                    ? nil
                    : "Denied by the local user")
            guard let encoded =
                    CollaborationControlCodec.encode(request)
            else { return }
            let result = self.collaborationCoordinator
                .executeHumanDecision(encoded)
            guard let snapshot = result.snapshot else {
                self.appControl.broadcast([
                    "event": "channel-proposal-error",
                    "proposalId": proposalID,
                    "message": result.response,
                ])
                return
            }
            self.appControl.broadcast([
                "event": approved
                    ? "channel-proposal-approved"
                    : "channel-proposal-denied",
                "proposalId": proposalID,
            ])
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyCollaborationProjection(snapshot)
            }
        }
    }

    private func provisionApprovedProposal(
        _ proposal: CollaborationRoomProposal
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard [.approved, .provisioning].contains(proposal.state),
              proposal.spec.presentation == .visual,
              proposal.spec.targetInstanceID == nil
                || proposal.spec.targetInstanceID
                    == collaborationInstanceID,
              provisioningProposalIDs.insert(proposal.spec.id).inserted
        else { return }
        Task { [weak self] in
            await self?.provisionApprovedProposalOffMain(
                proposal)
        }
    }

    private func provisionApprovedProposalOffMain(
        _ proposal: CollaborationRoomProposal
    ) async {
        var preparedCloudAdapters:
            [any CollaborationAgentRuntimeAdapter] = []
        defer {
            _ = self.onMain {
                self.provisioningProposalIDs.remove(proposal.spec.id)
            }
        }
        do {
                guard let authoritativeSnapshot =
                        self.collaborationCoordinator.snapshot(),
                      let authoritativeProposal =
                        authoritativeSnapshot.proposals.first(where: {
                            $0.spec.id == proposal.spec.id
                        }),
                      authoritativeProposal.digest == proposal.digest
                else {
                    return
                }

                var snapshot: CollaborationSnapshot
                switch authoritativeProposal.state {
                case .approved:
                    snapshot = try self.executeOrchestrationMutation(
                        CollaborationControlRequest(
                            op: .startProvisioning,
                            actor: self.orchestrationActor(),
                            idempotencyKey:
                                "proposal:\(proposal.spec.id):provision:"
                                + "\(proposal.updatedAt.timeIntervalSince1970)",
                            proposalID: proposal.spec.id,
                            proposalDigest: proposal.digest))
                case .provisioning:
                    snapshot = authoritativeSnapshot
                default:
                    // Projection delivery is asynchronous. An older approved
                    // or provisioning snapshot can arrive after this proposal
                    // has already reached running or another terminal state.
                    // Treat that delivery as stale instead of corrupting the
                    // authoritative outcome with a synthetic failure.
                    return
                }

                let workspaceMode: AgentWorkspaceMode =
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
                                "cloud agents currently require the real Codex "
                                + "or Claude server adapter")
                    }
                    workspaces[agent.id] =
                        try self.agentWorkspaceProvisioner.provision(
                            repositoryRoot: proposal.spec.workspaceRoot,
                            channelID: proposal.spec.channelID,
                            participantID: agent.id,
                            mode: workspaceMode)
                }
                var cloudBindings:
                    [String: CollaborationCloudChatBindings] = [:]
                var cloudAdapters:
                    [String: any CollaborationAgentRuntimeAdapter] =
                        [:]
                for agent in proposal.spec.agents
                where agent.runtime == .cloud {
                    guard let workspace = workspaces[agent.id] else {
                        throw CollaborationRoomError.invalidValue(
                            field: "cloud workspace",
                            reason:
                                "approved workspace is unavailable for "
                                + agent.id)
                    }
                    let previous =
                        proposal.runtimeReceipts.first {
                            $0.agentID == agent.id
                        }
                    let adapter = try self.cloudRuntimeFactory
                        .makeAdapter(
                            context:
                                CollaborationCloudRuntimeContext(
                                    proposalID: proposal.spec.id,
                                    agent: agent,
                                    workspace:
                                        agent.cloudConnection?
                                            .remoteWorkspace
                                        ?? workspace.path,
                                    previousReceipt: previous))
                    let preparedReceipt = try await adapter.prepare()
                    preparedCloudAdapters.append(adapter)
                    if previous == nil {
                        snapshot =
                            try self.executeOrchestrationMutation(
                                CollaborationControlRequest(
                                    op: .recordRuntimeSession,
                                    actor:
                                        self.orchestrationActor(),
                                    idempotencyKey:
                                        "proposal:"
                                        + "\(proposal.spec.id):runtime:"
                                        + agent.id,
                                    proposalID: proposal.spec.id,
                                    proposalDigest: proposal.digest,
                                    runtimeReceipt:
                                        preparedReceipt))
                    }
                    cloudBindings[agent.id] =
                        CollaborationCloudChatBindings(
                            adapter: adapter)
                    cloudAdapters[agent.id] = adapter
                }

                if !snapshot.channels.contains(where: {
                    $0.id == proposal.spec.channelID
                }) {
                    snapshot = try self.executeOrchestrationMutation(
                        CollaborationControlRequest(
                            op: .create,
                            actor: self.orchestrationActor(),
                            idempotencyKey:
                                "proposal:\(proposal.spec.id):create-channel",
                            channelID: proposal.spec.channelID,
                            name: proposal.spec.roomName))
                }
                let visual = try await self.makeApprovedVisualAgents(
                    proposal: proposal,
                    snapshot: snapshot,
                    workspaces: workspaces,
                    cloudBindings: cloudBindings,
                    cloudAdapters: cloudAdapters)
                snapshot = visual.snapshot

                for agent in visual.agents {
                    if snapshot.channels.first(where: {
                        $0.id == proposal.spec.channelID
                    })?.endpoints.contains(where: {
                        $0.id == agent.endpoint.id
                    }) != true {
                        snapshot = try self.executeOrchestrationMutation(
                            CollaborationControlRequest(
                                op: .linkAndJoin,
                                actor: self.orchestrationActor(),
                                idempotencyKey:
                                    "proposal:\(proposal.spec.id):link:"
                                    + agent.spec.id,
                                channelID: proposal.spec.channelID,
                                source: visual.channelEndpoint,
                                target: agent.endpoint,
                                participants: [agent.participant]))
                    }
                }

                for agent in proposal.spec.agents {
                    for (index, scope) in
                        agent.responsibilityScopes.enumerated()
                    {
                        let claimID =
                            "\(proposal.spec.id)-\(agent.id)-scope-\(index)"
                        let channel = snapshot.channels.first {
                            $0.id == proposal.spec.channelID
                        }
                        if channel?.responsibilities.contains(where: {
                            $0.id == claimID
                        }) == true {
                            continue
                        }
                        snapshot = try self.executeOrchestrationMutation(
                            CollaborationControlRequest(
                                op: .claim,
                                actor: self.orchestrationActor(),
                                idempotencyKey:
                                    "proposal:\(proposal.spec.id):claim:"
                                    + "\(agent.id):\(index)",
                                channelID: proposal.spec.channelID,
                                claim: CollaborationResponsibility(
                                    id: claimID,
                                    scope: scope,
                                    summary: agent.role,
                                    ownerID: agent.id)))
                    }
                }

                let plan = proposal.spec.agents.enumerated().map {
                    index, agent in
                    CollaborationPlanItem(
                        id: "\(proposal.spec.id)-agent-\(index)",
                        title: "\(agent.displayName): \(agent.role)",
                        status: .inProgress,
                        ownerID: agent.id)
                }
                snapshot = try self.executeOrchestrationMutation(
                    CollaborationControlRequest(
                        op: .replacePlan,
                        actor: self.orchestrationActor(),
                        idempotencyKey:
                            "proposal:\(proposal.spec.id):publish-plan",
                        channelID: proposal.spec.channelID,
                        plan: plan))

                let kickoffID = "\(proposal.spec.id)-kickoff"
                snapshot = try self.executeOrchestrationMutation(
                    CollaborationControlRequest(
                        op: .postMessage,
                        actor: self.orchestrationActor(),
                        idempotencyKey:
                            "proposal:\(proposal.spec.id):room-kickoff",
                        channelID: proposal.spec.channelID,
                        message: CollaborationMessage(
                            id: kickoffID,
                            threadID: nil,
                            authorID: self.orchestrationActor().id,
                            text:
                                "Approved objective: "
                                + proposal.spec.objective)))

                await self.onMainAsync {
                    self.applyCollaborationProjection(snapshot)
                    for agent in visual.agents {
                        let peers = proposal.spec.agents
                            .filter { $0.id != agent.spec.id }
                            .map { "\($0.displayName) — \($0.role)" }
                            .joined(separator: "\n")
                        let scopes =
                            agent.spec.responsibilityScopes.isEmpty
                            ? "No exclusive file scope was assigned."
                            : "Your exclusive scopes:\n"
                                + agent.spec.responsibilityScopes
                                    .joined(separator: "\n")
                        let prompt =
                            "You are \(agent.spec.displayName), "
                            + "\(agent.spec.role), in Channel "
                            + "\(proposal.spec.roomName).\n\n"
                            + "Objective:\n\(proposal.spec.objective)\n\n"
                            + "\(scopes)\n\n"
                            + "Peers:\n\(peers.isEmpty ? "None" : peers)\n\n"
                            + "Use the shared Channel plan and messages to "
                            + "coordinate. Do not modify another participant's "
                            + "claimed scope. Report only work and tool results "
                            + "you actually observed."
                        agent.record.assistant?.submitFromControl(
                            prompt,
                            model: "Auto",
                            effort: "Auto")
                    }
                }

                snapshot = try self.executeOrchestrationMutation(
                    CollaborationControlRequest(
                        op: .markProposalRunning,
                        actor: self.orchestrationActor(),
                        idempotencyKey:
                            "proposal:\(proposal.spec.id):running",
                        proposalID: proposal.spec.id,
                        proposalDigest: proposal.digest))
                self.appControl.broadcast([
                    "event": "channel-room-running",
                    "proposalId": proposal.spec.id,
                    "channelId": proposal.spec.channelID,
                    "agentCount": proposal.spec.agents.count,
                ])
                await self.onMainAsync {
                    self.applyCollaborationProjection(snapshot)
                }
        } catch {
            for adapter in preparedCloudAdapters {
                await adapter.close()
            }
            self.markProposalProvisioningFailed(
                proposal,
                error: error)
        }
    }

    private struct ApprovedVisualAgent {
        let spec: CollaborationAgentSpec
        let record: UtilityPanelRecord
        let endpoint: CollaborationEndpoint
        let participant: CollaborationParticipant
    }

    private struct ApprovedVisualRoom {
        let snapshot: CollaborationSnapshot
        let channelEndpoint: CollaborationEndpoint
        let agents: [ApprovedVisualAgent]
    }

    private func makeApprovedVisualAgents(
        proposal: CollaborationRoomProposal,
        snapshot: CollaborationSnapshot,
        workspaces: [String: ProvisionedAgentWorkspace],
        cloudBindings:
            [String: CollaborationCloudChatBindings],
        cloudAdapters:
            [String: any CollaborationAgentRuntimeAdapter]
    ) async throws -> ApprovedVisualRoom {
        guard let result = await onMainAsync({ () -> ApprovedVisualRoom? in
            self.applyCollaborationProjection(snapshot)
            guard let window = self.standardKeyWindow()
                    ?? NSApp.windows.first(where: {
                        $0.tabbingIdentifier == "infinitty"
                            && $0 !== self.quickTerminal.window
                    }),
                  let channelRecord = self.openUtilityPanel(
                    .channel,
                    in: window,
                    forceNewInstance: true,
                    channelID: proposal.spec.channelID)
            else { return nil }
            var anchor: NSView = channelRecord.pane
            var agents: [ApprovedVisualAgent] = []
            for spec in proposal.spec.agents {
                guard let workspace = workspaces[spec.id] else {
                    return nil
                }
                let record: UtilityPanelRecord
                if let existing = self.utilityPanels.values
                    .flatMap({ $0 })
                    .first(where: {
                        $0.proposalID == proposal.spec.id
                            && $0.proposedAgentID == spec.id
                    })
                {
                    record = existing
                } else {
                    let chatConfig: AppConfig
                    switch self.configuredChat(
                        provider: spec.provider,
                        model: spec.modelID)
                    {
                    case .success(let value):
                        chatConfig = value
                    case .failure:
                        return nil
                    }
                    guard let created = self.openUtilityPanel(
                        .chat,
                        in: window,
                        relativeTo: anchor,
                        vertical: true,
                        forceNewInstance: true,
                        chatConfiguration: chatConfig,
                        chatWorkspaceDirectory:
                            spec.cloudConnection?.remoteWorkspace
                            ?? workspace.path,
                        chatTitle: spec.displayName,
                        chatRole: spec.role,
                        chatBackendRunner:
                            cloudBindings[spec.id]?.backendRunner,
                        chatConversationReleaser:
                            cloudBindings[spec.id]?.cancel)
                    else { return nil }
                    created.proposalID = proposal.spec.id
                    created.proposedAgentID = spec.id
                    created.cloudRuntimeAdapter =
                        cloudAdapters[spec.id]
                    created.participantCapabilities = Array(Set(
                        spec.capabilities
                            + ["channel.receive", "channel.send"]))
                        .sorted()
                    record = created
                }
                anchor = record.pane
                let endpoint = self.collaborationEndpoint(
                    for: record.pane)
                guard let participant =
                        self.collaborationParticipant(for: record.pane)
                else { return nil }
                agents.append(ApprovedVisualAgent(
                    spec: spec,
                    record: record,
                    endpoint: endpoint,
                    participant: participant))
            }
            return ApprovedVisualRoom(
                snapshot: snapshot,
                channelEndpoint: self.collaborationEndpoint(
                    for: channelRecord.pane),
                agents: agents)
        }) else {
            throw CollaborationRoomError.invalidValue(
                field: "visual host",
                reason:
                    "could not create the approved Channel and Chat panes")
        }
        return result
    }

    private func executeOrchestrationMutation(
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

    private func orchestrationActor() -> CollaborationActor {
        CollaborationActor(
            id: "system:orchestrator:\(collaborationInstanceID)",
            kind: .system,
            displayName: "Infinitty room orchestrator")
    }

    private func markProposalProvisioningFailed(
        _ proposal: CollaborationRoomProposal,
        error: Error
    ) {
        let reason = String(describing: error)
        let request = CollaborationControlRequest(
            op: .markProposalFailed,
            actor: orchestrationActor(),
            idempotencyKey:
                "proposal:\(proposal.spec.id):failed:"
                + UUID().uuidString.lowercased(),
            proposalID: proposal.spec.id,
            proposalDigest: proposal.digest,
            reason: reason)
        let snapshot = try? executeOrchestrationMutation(request)
        appControl.broadcast([
            "event": "channel-room-failed",
            "proposalId": proposal.spec.id,
            "message": reason,
        ])
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.provisioningProposalIDs.remove(proposal.spec.id)
            if let snapshot {
                self.applyCollaborationProjection(snapshot)
            }
        }
    }

    private func collaborationColor(hex: String) -> NSColor {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else {
            return NSColor.controlAccentColor
        }
        return NSColor(
            calibratedRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1)
    }

    private func presentChannelSummary(
        for pane: NSView,
        errorMessage: String? = nil
    ) {
        guard let header = paneHeader(for: pane) else { return }
        channelPopover?.close()

        let endpoint = collaborationEndpoint(for: pane)
        let state = channel(for: endpoint.id)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = .labelColor
            field.maximumNumberOfLines = 0
            field.preferredMaxLayoutWidth = 316
            return field
        }

        if let errorMessage {
            let error = label(errorMessage, size: 12, weight: .medium)
            error.textColor = .systemRed
            stack.addArrangedSubview(error)
        }
        if let state {
            let title = label(state.name, size: 16, weight: .semibold)
            title.textColor = collaborationColor(hex: state.colorHex)
            stack.addArrangedSubview(title)
            stack.addArrangedSubview(label(
                "\(state.endpoints.count) connected panes · revision \(state.revision)",
                size: 11, weight: .regular))
            stack.addArrangedSubview(label(
                state.endpoints.map { "\($0.label) · \($0.kind.rawValue)" }.joined(separator: "\n"),
                size: 12, weight: .regular))
            if !state.participants.isEmpty {
                stack.addArrangedSubview(label(
                    "Roles\n" + state.participants.map {
                        "\($0.displayName) · \($0.role)"
                    }.joined(separator: "\n"),
                    size: 12, weight: .medium))
            }
            if !state.plan.isEmpty {
                stack.addArrangedSubview(label(
                    "Plan\n" + state.plan.map {
                        "\($0.status.rawValue) · \($0.title)"
                    }.joined(separator: "\n"),
                    size: 12, weight: .medium))
            }
            if !state.messages.isEmpty {
                stack.addArrangedSubview(label(
                    "Recent\n" + state.messages.suffix(4).map {
                        "\($0.authorID): \($0.text)"
                    }.joined(separator: "\n"),
                    size: 12, weight: .regular))
            }
        } else {
            stack.addArrangedSubview(label(
                "No Channel yet", size: 16, weight: .semibold))
            stack.addArrangedSubview(label(
                "Drag this connector onto another pane to create a shared Channel.",
                size: 12, weight: .regular))
        }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 348, height: 300))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        let controller = NSViewController()
        controller.view = scroll
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = scroll.frame.size
        popover.contentViewController = controller
        popover.show(
            relativeTo: header.channelAnchorView.bounds,
            of: header.channelAnchorView,
            preferredEdge: .maxY)
        channelPopover = popover
    }

    private func movePaneView(_ source: NSView, relativeTo target: NSView, zone: PaneDropZone) {
        guard source !== target, let win = source.window, target.window === win else { return }
        guard let root = paneLayoutHost(of: win, containing: source) else { return }
        _ = PaneLayoutController.normalizeRoot(in: root)
        guard PaneLayoutController.rootInvariantHolds(in: root) else {
            PaneLog.log(
                "ERROR move rejected invalid-root tree=\(PaneLog.describe(root))")
            recordPaneLedgerFailure(
                in: win, paneID: paneLedgerPaneID(for: source),
                reason: "pane-move-invalid-root", origin: "pane-drag")
            return
        }
        let beforePanes = paneLeafViews(in: win)
        let beforeIDs = Set(beforePanes.map(ObjectIdentifier.init))
        PaneLog.log("move begin zone=\(zone) count=\(beforePanes.count) "
            + "source=\(ObjectIdentifier(source)) target=\(ObjectIdentifier(target)) "
            + "tree=\(PaneLog.describe(root))")
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
        PaneLayoutController.stabilizeRoot(in: root)
        win.contentView?.layoutSubtreeIfNeeded()
        let afterPanes = paneLeafViews(in: win)
        let afterIDs = Set(afterPanes.map(ObjectIdentifier.init))
        let missing = beforeIDs.subtracting(afterIDs)
        let added = afterIDs.subtracting(beforeIDs)
        let validRoot = PaneLayoutController.rootInvariantHolds(in: root)
        let summary = "move end count=\(afterPanes.count) missing=\(missing) added=\(added) "
            + "validRoot=\(validRoot) tree=\(PaneLog.describe(root))"
        let moveIsValid = beforeIDs == afterIDs && validRoot
        PaneLog.log(moveIsValid ? summary : "ERROR \(summary)")
        if moveIsValid {
            recordPaneLedgerNote(
                in: win, paneID: paneLedgerPaneID(for: source),
                reason: "pane-moved", origin: "pane-drag",
                sourcePaneID: paneLedgerPaneID(for: target), axis: String(describing: zone))
        } else {
            recordPaneLedgerFailure(
                in: win, paneID: paneLedgerPaneID(for: source),
                reason: "pane-move-invalid-result", origin: "pane-drag")
        }
        animatePaneReflow(from: oldGeometry)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak win] in
            guard let self, let win else { return }
            let settled = self.paneLeafViews(in: win)
            let settledIDs = Set(settled.map(ObjectIdentifier.init))
            let settledRoot = self.paneLayoutHost(of: win)
            let validRoot = settledRoot.map {
                PaneLayoutController.rootInvariantHolds(in: $0)
            } ?? false
            let settledSummary = "move settled count=\(settled.count) "
                + "missing=\(beforeIDs.subtracting(settledIDs)) "
                + "added=\(settledIDs.subtracting(beforeIDs)) "
                + "validRoot=\(validRoot) "
                + "tree=\(settledRoot.map(PaneLog.describe) ?? "nil")"
            let settledIsValid = beforeIDs == settledIDs && validRoot
            PaneLog.log(settledIsValid ? settledSummary : "ERROR \(settledSummary)")
            if settledIsValid {
                self.recordPaneLedgerNote(
                    in: win, reason: "pane-move-settled", origin: "pane-drag")
            } else {
                self.recordPaneLedgerFailure(
                    in: win, paneID: self.paneLedgerPaneID(for: source),
                    reason: "pane-move-invalid-settled", origin: "pane-drag")
            }
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

    @discardableResult
    private func split(
        session: TerminalSession,
        vertical: Bool,
        newFirst: Bool
    ) -> TerminalSession? {
        restorePaneZoom(containing: session, refocus: false)
        guard let win = session.view.window else { return nil }
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
            return nil
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
        return newSession
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
                  let record = utilityRecord(forPane: pane) {
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

    /// Independent utility leaves mixed into each tab's pane tree, in
    /// creation order. Files stays one-per-window; Chat, Channel, and Browser
    /// may have multiple instances, so records are a list rather than keyed
    /// by kind.
    private var utilityPanels: [ObjectIdentifier: [UtilityPanelRecord]] = [:]
    /// Monotonic counters behind per-instance "browser-N" / "chat-N" ledger IDs.
    private var nextBrowserLedgerID = 1
    private var nextChatLedgerID = 1
    private var nextSurfaceLedgerID = 1
    /// Agent surfaces opened as standalone windows: the controller must stay
    /// alive (it is the WKWebView's script-message handler) until close.
    private var surfaceWindowControllers: [ObjectIdentifier: SurfacePaneController] = [:]
    /// surface id → its standalone window, for agent-driven surface-close.
    private var surfaceWindows: [String: NSWindow] = [:]

    private func utilityRecords(in win: NSWindow) -> [UtilityPanelRecord] {
        utilityPanels[ObjectIdentifier(win)] ?? []
    }

    /// Quick Terminal keeps every internal tab attached to one panel window.
    /// Scope records by their actual page ancestry whenever a lifecycle
    /// operation belongs to one of those internal tabs.
    private func utilityRecords(
        in win: NSWindow, rootedAt root: NSView?
    ) -> [UtilityPanelRecord] {
        guard let root else { return utilityRecords(in: win) }
        return utilityRecords(in: win).filter {
            $0.pane === root || $0.pane.isDescendant(of: root)
        }
    }

    /// The most recently created panel of `kind` in `win`. For Files that is
    /// the only one; for Chat/Browser it is the last instance opened, which
    /// plain "open" focuses.
    private func utilityRecord(
        _ kind: UtilityPanelKind, in win: NSWindow, rootedAt root: NSView? = nil
    ) -> UtilityPanelRecord? {
        utilityRecords(in: win, rootedAt: root).last { $0.kind == kind }
    }

    /// Resolve a pane leaf back to its record by identity — required once two
    /// panes of the same kind can coexist in one window.
    private func utilityRecord(forPane view: NSView) -> UtilityPanelRecord? {
        for records in utilityPanels.values {
            if let record = records.first(where: { $0.pane === view }) { return record }
        }
        return nil
    }

    private func browserRecord(withID browserID: String) -> UtilityPanelRecord? {
        for records in utilityPanels.values {
            if let record = records.first(where: { $0.browser?.browserID == browserID }) {
                return record
            }
        }
        return nil
    }

    private func chatRecord(withID chatID: String) -> UtilityPanelRecord? {
        for records in utilityPanels.values {
            if let record = records.first(where: {
                $0.kind == .chat && $0.ledgerID == chatID
            }) {
                return record
            }
        }
        return nil
    }

    private func channelRecord(
        withID channelID: String,
        in window: NSWindow? = nil
    ) -> UtilityPanelRecord? {
        let records: [UtilityPanelRecord]
        if let window {
            records = utilityRecords(in: window)
        } else {
            records = utilityPanels.values.flatMap { $0 }
        }
        return records.first {
            $0.kind == .channel && $0.channelID == channelID
        }
    }

    private func removeUtilityRecord(_ record: UtilityPanelRecord, windowKey id: ObjectIdentifier) {
        utilityPanels[id]?.removeAll { $0 === record }
        if utilityPanels[id]?.isEmpty == true { utilityPanels.removeValue(forKey: id) }
    }

    @objc func toggleCodeView(_ sender: Any?) {
        guard let win = NSApp.keyWindow else { return }
        _ = toggleCodeView(in: win)
    }

    @discardableResult
    func toggleCodeView(in win: NSWindow) -> Bool {
        guard win.tabbingIdentifier == "infinitty",
              win !== quickTerminal.window else { return false }
        let id = ObjectIdentifier(win)
        if let record = utilityRecord(.files, in: win) {
            guard closeUtilityPanel(record, in: win) else { return false }
            sidebarToggleAccessories[id]?.toggleView.setSidebarVisible(false)
            refocusTerminal(in: win)
            return true
        }
        return openUtilityPanel(.files, in: win) != nil
    }

    /// Context-menu form: show/focus Files without toggling an existing pane closed.
    @objc func openFilesPane(_ sender: Any?) {
        guard let win = standardKeyWindow() else { return }
        _ = openUtilityPanel(.files, in: win)
    }

    /// Open a new Chat pane (always a fresh leaf, like New Browser). Each pane
    /// owns its own assistant/threads.
    @objc func newChatPane(_ sender: Any?) {
        guard let win = standardKeyWindow(),
              let record = openUtilityPanel(
                  .chat, in: win, forceNewInstance: true)
        else { return }
        record.controller?.focusChatInput()
    }

    /// Open or focus the most recent Chat pane in the key window.
    @objc func openChatPane(_ sender: Any?) {
        guard let win = standardKeyWindow(),
              let record = openUtilityPanel(.chat, in: win) else { return }
        record.controller?.focusChatInput()
    }

    @discardableResult
    private func openChannelPanel(
        channelID: String,
        in window: NSWindow,
        relativeTo source: NSView? = nil,
        vertical: Bool = true
    ) -> UtilityPanelRecord? {
        if let existing = channelRecord(withID: channelID, in: window) {
            restorePaneZoom(revealing: existing.pane)
            window.makeFirstResponder(existing.pane)
            return existing
        }
        return openUtilityPanel(
            .channel,
            in: window,
            relativeTo: source,
            vertical: vertical,
            forceNewInstance: true,
            channelID: channelID)
    }

    /// Open (or focus the most recent) Browser pane in the key window.
    @objc func openBrowserPane(_ sender: Any?) {
        guard let win = standardKeyWindow() else { return }
        _ = openUtilityPanel(.browser, in: win)
    }

    /// Always create an additional Browser pane, even when one already exists.
    @objc func newBrowserPane(_ sender: Any?) {
        guard let win = standardKeyWindow() else { return }
        _ = openUtilityPanel(.browser, in: win, forceNewInstance: true)
    }

    private func standardKeyWindow() -> NSWindow? {
        guard let win = NSApp.keyWindow,
              win.tabbingIdentifier == "infinitty",
              win !== quickTerminal.window else { return nil }
        return win
    }

    /// The view that hosts a window's terminal panes/splits. For standard
    /// windows that's the chrome body (below the custom tab strip); the
    /// quick terminal uses its own tab page; fall back to contentView.
    private func terminalRoot(
        of win: NSWindow, containing view: NSView? = nil
    ) -> NSView? {
        if let chrome = terminalChromes[ObjectIdentifier(win)] { return chrome.body }
        if win === quickTerminal.window {
            if let view, let root = quickTerminal.rootView(containing: view) {
                return root
            }
            return quickTerminal.activeRootView
        }
        return win.contentView
    }

    /// A real pane host has stable plain-container ownership. The content-view
    /// fallback above exists for lightweight tests and legacy sidebar callers;
    /// it must not be interpreted as TerminalChromeView.body when the content
    /// view itself is an NSSplitView.
    private func paneLayoutHost(
        of win: NSWindow, containing view: NSView? = nil
    ) -> NSView? {
        if let chrome = terminalChromes[ObjectIdentifier(win)] { return chrome.body }
        if win === quickTerminal.window {
            if let view, let root = quickTerminal.paneLayoutHost(containing: view) {
                return root
            }
            if let activeRoot = quickTerminal.activeRootView {
                return quickTerminal.paneLayoutHost(containing: activeRoot) ?? activeRoot
            }
            return nil
        }
        return nil
    }

    /// Refresh the custom tab strip in every window of `win`'s tab group so
    /// each shows the shared title list with its own tab highlighted. The
    /// native tab bar stays hidden; reference chrome keeps our strip visible
    /// even for a single tab.
    private func refreshTabStrips(in win: NSWindow) {
        // The quick terminal renders its own QuickTerminalTabStripView in a
        // borderless panel. Querying AppKit titlebar accessories on that panel
        // raises an NSInternalInconsistencyException.
        guard win !== quickTerminal.window else { return }
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
        guard let url = Bundle.infinittyResourceURL(
            forResource: asset, withExtension: "svg", subdirectory: "Logos"),
            let data = try? Data(contentsOf: url),
            let image = NSImage(data: data), image.isValid
        else { return nil }
        image.size = NSSize(width: 24, height: 24)
        // The logo SVGs draw with currentColor (usually black). Template mode
        // lets the tab strip tint them via contentTintColor — without it the
        // glyph renders as a solid black blob on the dark strip.
        image.isTemplate = true
        return image
    }

    /// Provider logo asset for a foreground process, keyed by the agent CLIs
    /// we recognize. Assets are the models.dev brand SVGs in Resources/Logos.
    static let agentLogoAssets: [(match: String, asset: String)] = [
        ("claude", "anthropic"),
        ("codex", "openai"),
        ("gemini", "google"),
        ("qwen", "qwen"),
        ("grok", "xai"),
        ("copilot", "github-copilot"),
        ("ollama", "ollama"),
        ("opencode", "opencode"),
        ("cursor", "cursor"),
        ("droid", "factory"),
        ("kimi", "moonshotai"),
        ("mistral", "mistral"),
        ("deepseek", "deepseek"),
        ("amp", "amp"),
    ]

    private func tabIconAssetName(forProcessName name: String) -> String? {
        let value = name.lowercased()
        // Short names (amp, grok…) must match a whole word so they don't fire
        // inside unrelated process names; longer ones may match as substrings
        // ("claude-code", "cursor-agent").
        let tokens = Set(
            value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return AppDelegate.agentLogoAssets.first {
            tokens.contains($0.match) || ($0.match.count >= 5 && value.contains($0.match))
        }?.asset
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

    func installPaneHostForTesting(_ chrome: TerminalChromeView, in window: NSWindow) {
        terminalChromes[ObjectIdentifier(window)] = chrome
        window.contentView = chrome
    }

    func openUtilityPaneForTesting(
        _ kind: UtilityPanelKind,
        in window: NSWindow,
        relativeTo source: NSView,
        vertical: Bool = true,
        forceNewInstance: Bool = false
    ) -> UtilityPaneView? {
        openUtilityPanel(
            kind, in: window, relativeTo: source,
            vertical: vertical, forceNewInstance: forceNewInstance)?.pane
    }

    @discardableResult
    func closeUtilityPaneForTesting(
        _ pane: UtilityPaneView,
        in window: NSWindow
    ) -> Bool {
        guard let record = utilityRecord(forPane: pane) else { return false }
        return closeUtilityPanel(record, in: window)
    }

    func utilityPaneCountForTesting(in window: NSWindow) -> Int {
        utilityRecords(in: window).count
    }

    var collaborationInstanceIDForTesting: String {
        collaborationInstanceID
    }

    func executeCollaborationForTesting(
        _ encoded: String
    ) -> CollaborationSnapshot? {
        collaborationQueue.sync {
            collaborationCoordinator.execute(encoded).snapshot
        }
    }

    func decideChannelProposalForTesting(
        proposalID: String,
        digest: String,
        approved: Bool
    ) {
        decideChannelProposal(
            proposalID: proposalID,
            digest: digest,
            approved: approved)
    }

    func collaborationSnapshotForTesting() -> CollaborationSnapshot {
        authoritativeCollaborationSnapshot()
    }

    func utilityPaneCountForTesting(in window: NSWindow, rootedAt root: NSView) -> Int {
        utilityRecords(in: window, rootedAt: root).count
    }

    func ensureQuickTerminalForTesting() -> (NSWindow, TerminalSession)? {
        guard let (window, session) = quickTerminal.ensureWindow(),
              let session else { return nil }
        return (window, session)
    }

    func newQuickTerminalTabForTesting() -> TerminalSession? {
        quickTerminal.newTab()
    }

    func selectQuickTerminalTabForTesting(containing session: TerminalSession) -> Bool {
        quickTerminal.selectTab(containing: session)
    }

    func quickTerminalRootForTesting(containing session: TerminalSession) -> NSView? {
        quickTerminal.rootView(inTabContaining: session)
    }

    func quickTerminalLayoutHostForTesting(containing view: NSView) -> NSView? {
        quickTerminal.paneLayoutHost(containing: view)
    }

    @discardableResult
    func closeQuickTerminalTabForTesting(containing view: NSView) -> Bool {
        guard let root = quickTerminal.rootView(containing: view) else { return false }
        return quickTerminal.requestCloseTab(rootView: root)
    }

    var quickTerminalActiveRootForTesting: NSView? {
        quickTerminal.activeRootView
    }

    var quickTerminalTabCountForTesting: Int {
        quickTerminal.tabCount
    }

    func quickTerminalTitleForTesting(
        containing session: TerminalSession
    ) -> String? {
        quickTerminal.displayTitle(containing: session)
    }

    @discardableResult
    func splitTerminalForTesting(
        relativeTo source: NSView, vertical: Bool
    ) -> TerminalSession? {
        splitTerminal(relativeTo: source, vertical: vertical)
    }

    func sourceSessionForSplitForTesting(relativeTo source: NSView) -> TerminalSession? {
        guard let window = source.window else { return nil }
        return sourceSession(relativeTo: source, in: window)
    }

    func petAssistantForTesting(_ session: TerminalSession) -> PetAssistant {
        petAssistant(for: session)
    }

    func installPetAssistantForTesting(
        _ assistant: PetAssistant, for session: TerminalSession
    ) {
        if let previous = petAssistants.updateValue(assistant, forKey: session.id),
           previous !== assistant {
            previous.invalidate()
        }
        bindAssistant(assistant, to: session)
    }

    func utilityPaneAssistantForTesting(_ pane: UtilityPaneView) -> PetAssistant? {
        utilityRecord(forPane: pane)?.assistant
    }

    func installUtilityPaneAssistantForTesting(
        _ assistant: PetAssistant,
        in pane: UtilityPaneView
    ) {
        guard let record = utilityRecord(forPane: pane) else { return }
        if let previous = record.assistant,
           previous !== assistant,
           !petAssistants.values.contains(where: { $0 === previous }) {
            previous.invalidate()
        }
        record.assistant = assistant
        configureCollaboration(for: record, assistant: assistant)
        record.controller?.attachAssistant(assistant)
    }

    func linkCollaborationPanesForTesting(
        source: NSView,
        target: NSView,
        completion: @escaping (Result<CollaborationSnapshot, Error>) -> Void
    ) {
        linkCollaborationPanes(
            source: source, target: target, completion: completion)
    }

    func collaborationContextForTesting(
        pane: UtilityPaneView
    ) -> CollaborationChatContext? {
        let endpointID = collaborationEndpoint(for: pane).id
        return CollaborationChatContext(
            snapshot: authoritativeCollaborationSnapshot(),
            endpointID: endpointID)
    }

    func openChannelPanelForTesting(
        channelID: String,
        in window: NSWindow,
        relativeTo source: NSView
    ) -> UtilityPaneView? {
        openChannelPanel(
            channelID: channelID,
            in: window,
            relativeTo: source)?.pane
    }

    func channelPanelControllerForTesting(
        _ pane: UtilityPaneView
    ) -> ChannelPanelController? {
        utilityRecord(forPane: pane)?.channelController
    }

    func channelIDForTesting(_ pane: UtilityPaneView) -> String? {
        utilityRecord(forPane: pane)?.channelID
    }

    func handleAppRequestForTesting(_ request: String) -> String {
        handleAppRequest(request)
    }

    func utilityPaneControllerForTesting(_ pane: UtilityPaneView) -> CodeViewController? {
        utilityRecord(forPane: pane)?.controller
    }

    func sessionDidExitForTesting(_ session: TerminalSession) {
        sessionDidExit(session)
    }

    private func tabTitle(for win: NSWindow) -> String {
        if let override = titleOverrides[ObjectIdentifier(win)], !override.isEmpty {
            return override
        }
        let inWindow = activeSessions(in: win)
        if let registeredName = inWindow.compactMap({
            $0.channelRegistration?.displayName
        }).first {
            return registeredName
        }
        if let agentName = inWindow.compactMap(\.agentSessionName).first {
            return agentName
        }
        return inWindow.first?.title ?? "infinitty"
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
        vertical: Bool = true,
        forceNewInstance: Bool = false,
        channelID: String? = nil,
        chatConfiguration: AppConfig? = nil,
        chatWorkspaceDirectory: String? = nil,
        chatTitle: String? = nil,
        chatRole: String? = nil,
        chatBackendRunner: PetAssistant.BackendRunner? = nil,
        chatConversationReleaser:
            ((String) -> Void)? = nil
    ) -> UtilityPanelRecord? {
        let id = ObjectIdentifier(win)
        // Files stays one-per-window. Chat, Channel, and Browser support extra
        // instances when forceNewInstance is set; a plain "open" focuses the
        // newest existing pane of that kind.
        if kind == .channel {
            guard let channelID else { return nil }
            if let existing = channelRecord(withID: channelID, in: win) {
                restorePaneZoom(revealing: existing.pane)
                win.makeFirstResponder(existing.pane)
                return existing
            }
        }
        let allowsMultiple =
            kind == .browser || kind == .chat || kind == .channel
        let wantsNewInstance = forceNewInstance && allowsMultiple
        let requestedRoot = requestedSource.flatMap {
            terminalRoot(of: win, containing: $0)
        } ?? (win === quickTerminal.window ? quickTerminal.activeRootView : nil)
        if kind != .channel,
           !wantsNewInstance,
           let existing = utilityRecord(kind, in: win, rootedAt: requestedRoot) {
            restorePaneZoom(revealing: existing.pane)
            win.makeFirstResponder(existing.pane)
            // Focusing Chat again: never leave the pet popover stacked on it.
            if kind == .chat {
                existing.assistant?.dismissPopover()
            }
            recordPaneLedgerNote(
                in: win, paneID: existing.ledgerID, reason: "pane-focused", origin: "utility-open")
            return existing
        }
        guard let anchorView = requestedSource
                ?? focusedPaneLeaf(in: win)
                ?? activeSessions(in: win).first?.view
                ?? paneLeafViews(in: win, rootedAt: requestedRoot).first
                ?? terminalRoot(of: win),
              anchorView.window === win else { return nil }

        let bg = Theme.dark.applying(config).background
        let background = NSColor(
            srgbRed: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z),
            alpha: CGFloat(bg.w))
        let codeController: CodeViewController?
        let browserController: BrowserPaneController?
        let channelController: ChannelPanelController?
        let contentView: NSView
        switch kind {
        case .files, .chat:
            let controller = CodeViewController(config: config, panelKind: kind)
            codeController = controller
            browserController = nil
            channelController = nil
            contentView = controller.view
        case .channel:
            guard let channelID,
                  let state = authoritativeCollaborationSnapshot()
                    .channels.first(where: { $0.id == channelID })
            else { return nil }
            let snapshot = authoritativeCollaborationSnapshot()
            let controller = ChannelPanelController(
                channel: state,
                proposals: snapshot.proposals)
            codeController = nil
            browserController = nil
            channelController = controller
            contentView = controller.view
        case .browser:
            let controller = BrowserPaneController()
            codeController = nil
            browserController = controller
            channelController = nil
            contentView = controller.view
        case .surface:
            return nil // surfaces are agent-created via openSurfacePanel
        }
        let pane = UtilityPaneView(
            kind: kind,
            contentView: contentView,
            background: background,
            blurred: config.backgroundBlur)
        let ledgerID: String
        switch kind {
        case .browser:
            ledgerID = "browser-\(nextBrowserLedgerID)"
            nextBrowserLedgerID += 1
        case .chat:
            ledgerID = "chat-\(nextChatLedgerID)"
            nextChatLedgerID += 1
            pane.paneHeader.title = "Chat \(ledgerID.dropFirst("chat-".count))"
        case .channel:
            guard let channelID,
                  let state = authoritativeCollaborationSnapshot()
                    .channels.first(where: { $0.id == channelID })
            else { return nil }
            ledgerID = "channel-panel-\(channelID)"
            pane.paneHeader.title = state.name
        case .files, .surface:
            ledgerID = kind.rawValue
        }
        let record: UtilityPanelRecord
        if let controller = codeController {
            record = UtilityPanelRecord(controller: controller, pane: pane, ledgerID: ledgerID)
        } else if let controller = browserController {
            record = UtilityPanelRecord(browser: controller, pane: pane, ledgerID: ledgerID)
        } else if let controller = channelController, let channelID {
            record = UtilityPanelRecord(
                channel: controller,
                channelID: channelID,
                pane: pane,
                ledgerID: ledgerID)
        } else {
            return nil
        }
        record.ownerWindow = win
        if kind == .chat {
            let chatConfig = chatConfiguration ?? config
            record.configuredProvider = chatConfig.aiProvider
            switch chatConfig.aiProvider.lowercased() {
            case "claude": record.configuredModel = chatConfig.claudeModel
            case "codex": record.configuredModel = chatConfig.codexModel
            case "opencode": record.configuredModel = chatConfig.opencodeModel
            case "hermes": record.configuredModel = chatConfig.hermesModel
            case "amp": record.configuredModel = chatConfig.ampModel
            default: record.configuredModel = nil
            }
        }
        utilityPanels[id, default: []].append(record)
        if let controller = channelController, let channelID {
            controller.onSendMessage = { [weak self] text, threadID in
                self?.postChannelPanelMessage(
                    text,
                    threadID: threadID,
                    channelID: channelID)
            }
            controller.onUpdateRole = {
                [weak self] participantID, role in
                self?.updateChannelParticipantRole(
                    participantID: participantID,
                    role: role,
                    channelID: channelID)
            }
            controller.onProposalDecision = {
                [weak self] proposalID, digest, approved in
                self?.decideChannelProposal(
                    proposalID: proposalID,
                    digest: digest,
                    approved: approved)
            }
        }
        if let controller = codeController {
            controller.onPageChanged = { [weak self, weak win, weak record] page in
                guard let self, let win, let record,
                      self.utilityRecords(in: win).contains(where: { $0 === record })
                else { return }
                self.recordPaneLedgerNote(
                    in: win, paneID: record.ledgerID, reason: "page-\(page)", origin: "sidebar")
            }
        }
        if let browser = browserController {
            browser.onEvent = { [weak self, weak win] event in
                guard let self, let win else { return }
                self.appControl.broadcast(event)
                if let name = event["event"] as? String {
                    self.recordPaneLedgerNote(
                        in: win, paneID: ledgerID, reason: name, origin: "browser-pane")
                }
            }
            browser.onAnnotationsSubmitted = { [weak self, weak win] annotations in
                guard let self, let win else { return }
                self.submitBrowserAnnotations(annotations, in: win)
            }
        }

        wireUtilityPane(pane, record: record, in: win)

        let sourceSession = sourceSession(relativeTo: anchorView, in: win)
        if let controller = codeController {
            if let sourceSession { controller.track(session: sourceSession) }
            if kind == .chat {
                // Each Chat leaf owns its own assistant so multi-pane chats
                // don't share transcripts. The first pane opened without
                // forceNewInstance can still adopt the session's pet
                // assistant so pet-popover history continues in that leaf.
                let assistant: PetAssistant
                if forceNewInstance {
                    assistant = PetAssistant(
                        config: chatConfiguration ?? config,
                        backendRunner: chatBackendRunner,
                        conversationReleaser:
                            chatConversationReleaser)
                    if let chatWorkspaceDirectory {
                        assistant.setWorkspaceDirectory(
                            chatWorkspaceDirectory)
                    } else if let sourceSession {
                        assistant.attach(to: sourceSession)
                        bindAssistant(assistant, to: sourceSession)
                    }
                } else if let sourceSession {
                    assistant = petAssistant(for: sourceSession)
                } else {
                    assistant = PetAssistant(
                        config: chatConfiguration ?? config,
                        backendRunner: chatBackendRunner,
                        conversationReleaser:
                            chatConversationReleaser)
                }
                // This Chat surface owns the conversation — drop the pet bubble.
                assistant.dismissPopover()
                record.assistant = assistant
                if let chatTitle {
                    let title = chatTitle.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        pane.paneHeader.title = String(title.prefix(80))
                    }
                }
                if let chatRole {
                    let role = chatRole.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if !role.isEmpty {
                        record.participantRole = String(role.prefix(120))
                    }
                }
                configureCollaboration(for: record, assistant: assistant)
                let paneLedger = ledgerID
                pane.onNewChat = { [weak self, weak win, weak assistant] in
                    if let self, let win {
                        self.recordPaneLedgerNote(
                            in: win, paneID: paneLedger, reason: "chat-new",
                            origin: "chat-header")
                    }
                    // Pane-header + starts a new *thread* in this pane.
                    assistant?.startNewChat()
                }
            }
        }
        guard insertPaneView(pane, relativeTo: anchorView, vertical: vertical)
        else {
            recordPaneLedgerFailure(
                in: win, paneID: ledgerID, reason: "utility-insert-failed",
                origin: requestedSource == nil ? "utility-open" : "split-chooser")
            removeUtilityRecord(record, windowKey: id)
            return nil
        }
        // Building the Shadcn transcript/composer installs required internal
        // constraints. Do that only after the pane has received its real split
        // geometry; attaching while the new UtilityPaneView is still `.zero`
        // produces a transient required-constraint break and can strand a
        // zero-width Chat.
        if kind == .chat, let assistant = record.assistant {
            codeController?.attachAssistant(assistant)
        }
        recordPaneLedgerUtilityAdded(
            paneID: ledgerID, in: win,
            reason: requestedSource == nil ? "utility-open" : "split-insert",
            origin: requestedSource == nil ? "utility-open" : "split-chooser",
            sourceView: anchorView, vertical: vertical)
        if let browser = record.browser {
            DispatchQueue.main.async { [weak browser] in browser?.paneDidBecomeVisible() }
        }
        sidebarToggleAccessories[id]?.toggleView.setSidebarVisible(
            utilityRecord(.files, in: win) != nil)
        win.makeFirstResponder(pane)
        refreshCollaborationProjection()
        return record
    }

    /// Standard pane-leaf interactions shared by every utility pane kind:
    /// splits, zoom, focus, close, and drag-to-rearrange.
    private func wireUtilityPane(
        _ pane: UtilityPaneView, record: UtilityPanelRecord, in win: NSWindow
    ) {
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
        pane.paneHeader.onRenameCommit = { [weak self, weak pane] _ in
            guard let self, let pane else { return }
            self.updateCollaborationMembership(for: pane)
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
            self.beginPaneDrag(sourceView: pane, title: pane.kind.title, at: point)
        }
        pane.onDragMoved = { [weak self] point in self?.updatePaneDrag(at: point) }
        pane.onDragEnded = { [weak self] point, cancelled in
            self?.endPaneDrag(at: point, cancelled: cancelled)
        }
        pane.onChannelActivate = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.activateChannel(for: pane)
        }
        pane.onChannelDragBegan = { [weak self, weak pane] point in
            guard let self, let pane else { return }
            self.beginChannelConnectorDrag(sourceView: pane, at: point)
        }
        pane.onChannelDragMoved = { [weak self] point in
            self?.updateChannelConnectorDrag(at: point)
        }
        pane.onChannelDragEnded = { [weak self] point, cancelled in
            self?.endChannelConnectorDrag(at: point, cancelled: cancelled)
        }
    }

    /// Agent-requested surface (markdown / MCP-UI HTML / URL) as a ratio'd
    /// split beside the requesting pane, or as its own plain window.
    /// Returns the surface's ledger id, or an error string.
    private func openSurfacePanel(
        _ request: AgentSurfaceRequest, for session: TerminalSession
    ) -> String {
        let controller = SurfacePaneController(request: request)
        let ledgerID = "surface-\(nextSurfaceLedgerID)"
        nextSurfaceLedgerID += 1
        controller.onUIEvent = { [weak self] payload in
            self?.appControl.broadcast([
                "event": "ui", "surface": ledgerID, "payload": payload,
            ])
        }

        if request.target == .window {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = request.title ?? "Agent Surface"
            window.isReleasedWhenClosed = false
            window.contentView = controller.view
            window.center()
            // An agent opening a doc must not steal the user's keyboard focus.
            window.orderFront(nil)
            surfaceWindowControllers[ObjectIdentifier(window)] = controller
            surfaceWindows[ledgerID] = window
            // Box so the observer can remove itself without capturing a
            // mutating local (Sendable-closure diagnostic on `var token`).
            final class CloseObserver {
                var token: NSObjectProtocol?
            }
            let closeObserver = CloseObserver()
            closeObserver.token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] note in
                if let token = closeObserver.token {
                    NotificationCenter.default.removeObserver(token)
                    closeObserver.token = nil
                }
                guard let closing = note.object as? NSWindow else { return }
                let key = ObjectIdentifier(closing)
                self?.surfaceWindowControllers[key]?.teardown()
                self?.surfaceWindowControllers.removeValue(forKey: key)
                self?.surfaceWindows.removeValue(forKey: ledgerID)
                self?.appControl.broadcast([
                    "event": "surface-closed", "surface": ledgerID,
                ])
            }
            return ledgerID
        }

        guard let win = session.view.window else { return "error: pane has no window" }
        let pane = UtilityPaneView(
            kind: .surface, contentView: controller.view,
            background: .clear, blurred: false)
        if let title = request.title { pane.paneHeader.title = title }
        let record = UtilityPanelRecord(surface: controller, pane: pane, ledgerID: ledgerID)
        record.ownerWindow = win
        utilityPanels[ObjectIdentifier(win), default: []].append(record)
        wireUtilityPane(pane, record: record, in: win)
        guard insertPaneView(
            pane, relativeTo: session.view,
            vertical: request.isVertical, newFirst: request.newFirst)
        else {
            removeUtilityRecord(record, windowKey: ObjectIdentifier(win))
            return "error: could not insert surface split"
        }
        recordPaneLedgerUtilityAdded(
            paneID: ledgerID, in: win, reason: "surface-open", origin: "agent-surface",
            sourceView: session.view, vertical: request.isVertical)
        // insertPaneView centers the divider on the next runloop turn; queue
        // the requested ratio behind that so it wins.
        DispatchQueue.main.async { [weak pane] in
            guard let pane, let split = pane.superview as? NSSplitView,
                  split.arrangedSubviews.count == 2 else { return }
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            let position = request.newFirst
                ? total * request.ratio
                : total * (1 - request.ratio)
            split.setPosition(position, ofDividerAt: 0)
        }
        return ledgerID
    }

    @discardableResult
    private func closeUtilityPanel(
        _ record: UtilityPanelRecord,
        in win: NSWindow
    ) -> Bool {
        let id = ObjectIdentifier(win)
        restorePaneZoom(containing: record.pane, refocus: false)
        let lifecycleRoot = paneLayoutHost(of: win, containing: record.pane)
        let tabRoot = win === quickTerminal.window
            ? quickTerminal.rootView(containing: record.pane)
            : lifecycleRoot
        if let root = lifecycleRoot {
            let didRemove = PaneLayoutController.removeLeaf(record.pane, from: root)
            if !didRemove {
                PaneLog.log(
                    "ERROR utility removal failed pane=\(record.ledgerID) "
                        + "tree=\(PaneLog.describe(root))")
                recordPaneLedgerFailure(
                    in: win, paneID: record.ledgerID,
                    reason: "utility-remove-failed", origin: "utility-pane")
                // The pane is still a live UI owner. Keep its controller,
                // assistant, and registry record intact so a structural
                // failure cannot turn it into an untracked black/orphan pane.
                return false
            }
        } else {
            if let split = record.pane.superview as? NSSplitView {
                record.pane.removeFromSuperview()
                collapse(split, in: win)
            } else {
                record.pane.removeFromSuperview()
            }
        }
        leaveCollaborationPane(record.pane)
        if let browser = record.browser {
            browser.cancelPendingAutomation()
            appControl.broadcast(["event": "browser-closed", "browserId": browser.browserID])
        }
        if let surface = record.surface {
            surface.teardown()
            appControl.broadcast(["event": "surface-closed", "surface": record.ledgerID])
        }
        if let cloudRuntimeAdapter = record.cloudRuntimeAdapter {
            Task {
                await cloudRuntimeAdapter.interrupt()
                await cloudRuntimeAdapter.close()
            }
            record.cloudRuntimeAdapter = nil
        }
        if let assistant = record.assistant {
            appControl.broadcast([
                "event": "chat-closed",
                "chatId": record.ledgerID,
            ])
            let remainsOwnedByPet = petAssistants.values.contains { $0 === assistant }
            // A Chat pane may share the terminal's pet assistant. Closing only
            // that presentation must not cancel a turn still owned by the pet;
            // final-owner invalidation performs cancellation and backend release.
            if !remainsOwnedByPet { assistant.invalidate() }
            record.assistant = nil
        }
        if record.kind == .channel {
            appControl.broadcast([
                "event": "channel-panel-closed",
                "channelId": record.channelID ?? "",
                "panelId": record.ledgerID,
            ])
        }
        removeUtilityRecord(record, windowKey: id)
        recordPaneLedgerUtilityRemoved(
            paneID: record.ledgerID, in: win, reason: "utility-close", origin: "utility-pane")
        stabilizePaneTree(in: win, root: lifecycleRoot, reason: "utility-close")
        if PaneLifecyclePolicy.shouldCloseTab(
            remainingPaneCount: remainingTabLeafCount(in: win, rootedAt: tabRoot)
        ) {
            if win === quickTerminal.window, let tabRoot {
                if !quickTerminal.removeTab(rootView: tabRoot) {
                    PaneLog.log(
                        "ERROR quick tab removal failed after utility close "
                            + "pane=\(record.ledgerID)")
                }
            } else {
                win.close()
            }
            return true
        }
        sidebarToggleAccessories[id]?.toggleView.setSidebarVisible(
            utilityRecord(.files, in: win) != nil)
        let ownsActivePage = win !== quickTerminal.window
            || tabRoot == nil
            || quickTerminal.activeRootView === tabRoot
        guard ownsActivePage else { return true }
        let rootedSessions = sessions(in: win, rootedAt: tabRoot)
        if rootedSessions.isEmpty {
            if let remaining = paneLeafViews(in: win, rootedAt: tabRoot).first {
                win.makeFirstResponder(remaining)
                updatePaneSelection(in: win, focused: remaining, rootedAt: tabRoot)
            }
        } else {
            refocusTerminal(in: win)
        }
        return true
    }

    func installSidebarToggle(in win: NSWindow) {
        let id = ObjectIdentifier(win)
        if let existing = sidebarToggleAccessories[id] {
            existing.toggleView.setSidebarVisible(utilityRecord(.files, in: win) != nil)
            return
        }

        let accessory = SidebarToggleAccessory()
        accessory.toggleView.onClick = { [weak self, weak win] in
            guard let self, let win else { return }
            _ = self.toggleCodeView(in: win)
        }
        accessory.toggleView.setSidebarVisible(utilityRecord(.files, in: win) != nil)
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
    private var petHiddenUntilNeeded = false
    private var temporarilyRevealedPetSessionID: Int?

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
            .chat, in: win, relativeTo: source.view, vertical: true,
            forceNewInstance: true)
        else { return }
        let assistant = record.assistant ?? PetAssistant(config: config)
        if record.assistant == nil {
            bindAssistant(assistant, to: source)
            record.assistant = assistant
            configureCollaboration(for: record, assistant: assistant)
        }
        assistant.prepareRecovery(
            context: detected.recoveryContext,
            provider: detected.kind == .claude ? .claude : .codex,
            transcriptPath: detected.id)
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
        let sourceLedgerID = annotations.first
            .flatMap { browserRecord(withID: $0.browserID)?.ledgerID } ?? "browser"
        recordPaneLedgerNote(
            in: win, paneID: sourceLedgerID, reason: "browser-annotations",
            origin: "browser-inspector")
        guard let source = focusedSession(in: win) ?? activeSessions(in: win).first else {
            // A Browser-only tab is still valid after its last terminal exits.
            // Create or reuse a detached assistant: it can answer via the
            // app-level browser tools without pretending terminal context is
            // present, and will rebind if a terminal is later added.
            guard let record = openUtilityPanel(.chat, in: win) else { return }
            let assistant = record.assistant ?? PetAssistant(config: config)
            record.assistant = assistant
            configureCollaboration(for: record, assistant: assistant)
            record.controller?.attachAssistant(assistant)
            let paneLedger = record.ledgerID
            record.pane.onNewChat = { [weak self, weak win, weak assistant] in
                if let self, let win {
                    self.recordPaneLedgerNote(
                        in: win, paneID: paneLedger, reason: "chat-new",
                        origin: "chat-header")
                }
                assistant?.startNewChat()
            }
            assistant.submitBrowserAnnotations(annotations)
            win.makeFirstResponder(record.pane)
            broadcastBrowserAnnotationSubmission(annotations)
            return
        }
        // Prefer an existing Chat pane; don't force a second leaf for browser
        // feedback — annotations join the focused/most-recent conversation.
        guard let record = openUtilityPanel(.chat, in: win) else { return }
        let assistant = record.assistant ?? petAssistant(for: source)
        if record.assistant == nil {
            bindAssistant(assistant, to: source)
            record.controller?.track(session: source)
        }
        record.assistant = assistant
        configureCollaboration(for: record, assistant: assistant)
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
        assistant.onPetMessage = { [weak self, weak session] answer in
            guard let self, let session else { return }
            self.presentPetMessage(PetSpeechText.notification(answer), for: session)
        }
    }

    /// A Chat created from a terminal can share that terminal's pet assistant.
    /// If the user then splits a new terminal from that Chat, move the existing
    /// pet ownership to the new terminal before rebinding it. Pane-only
    /// assistants from additional Chat leaves stay pane-owned.
    private func bindAssistantAfterChatSplit(
        _ assistant: PetAssistant, to session: TerminalSession
    ) {
        let previousOwnerIDs = petAssistants.compactMap { id, candidate in
            candidate === assistant && id != session.id ? id : nil
        }
        if !previousOwnerIDs.isEmpty {
            for id in previousOwnerIDs {
                petAssistants.removeValue(forKey: id)
            }
            petAssistants[session.id] = assistant
        }
        bindAssistant(assistant, to: session)
    }

    private func presentPetAssistant(for session: TerminalSession) {
        let assistant = petAssistant(for: session)
        // Any visible Chat pane → focus the most recent one. Never stack the
        // pet popover on top, and never overwrite that pane's assistant (each
        // multi-chat leaf owns its own transcript).
        if let win = session.view.window,
           let chat = utilityRecords(in: win).reversed().first(where: {
               $0.kind == .chat && !$0.pane.isHiddenOrHasHiddenAncestor
           }) {
            assistant.dismissPopover()
            chat.assistant?.dismissPopover()
            if let chatAssistant = chat.assistant {
                chat.controller?.attachAssistant(chatAssistant)
            }
            restorePaneZoom(revealing: chat.pane)
            chat.controller?.focusChatInput()
            win.makeFirstResponder(chat.pane)
            return
        }
        guard let anchor = session.renderer.petHitRect(in: session.view) else { return }
        assistant.presentInput(anchorRect: anchor, in: session.view)
    }

    private func changePetScale(to scale: CGFloat) {
        config.petScale = min(max(scale, 0.1), 2)
        petHiddenUntilNeeded = false
        temporarilyRevealedPetSessionID = nil
        do {
            try config.saveAll()
        } catch {
            FileHandle.standardError.write(
                Data("infinitty: could not save pet size: \(error)\n".utf8))
        }
        refreshPets()
    }

    private func hidePetUntilNeeded() {
        petHiddenUntilNeeded = true
        temporarilyRevealedPetSessionID = nil
        refreshPets()
    }

    private func keepPetVisible() {
        petHiddenUntilNeeded = false
        temporarilyRevealedPetSessionID = nil
        refreshPets()
    }

    private func presentPetMessage(
        _ message: String, for session: TerminalSession,
        timeout: TimeInterval = 8, onClick: (() -> Void)? = nil
    ) {
        guard config.pet != nil, !message.isEmpty,
              !session.view.isHiddenOrHasHiddenAncestor else { return }
        if petHiddenUntilNeeded {
            temporarilyRevealedPetSessionID = session.id
            refreshPets()
        }
        session.view.showPetSpeech(message, timeout: timeout, onClick: onClick) {
            [weak self, weak session] in
            guard let self, let session, self.petHiddenUntilNeeded,
                  self.temporarilyRevealedPetSessionID == session.id else { return }
            self.temporarilyRevealedPetSessionID = nil
            self.refreshPets()
        }
    }

    /// Watch each pane's live cwd; the first time a pane lands in a repo,
    /// mine that repo for something genuinely useful (AGENTS.md/CLAUDE.md
    /// commands, package scripts, Makefile targets) and offer ONE tip.
    private func installRepoTipMonitor() {
        repoTipObserver = NotificationCenter.default.addObserver(
            forName: ForegroundProcessTracker.cwdDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let tracker = notification.object as? ForegroundProcessTracker,
                  let session = self.sessions.first(where: { $0.processTracker === tracker }),
                  let cwd = notification.userInfo?[ForegroundProcessTracker.cwdKey] as? String
            else { return }
            self.maybeShowRepoTip(for: session, cwd: cwd)
        }
    }

    private func maybeShowRepoTip(for session: TerminalSession, cwd: String) {
        guard config.pet != nil,
              Date().timeIntervalSince(lastPetTipAt) > 90 else { return }
        let sessionID = session.id
        DispatchQueue.global(qos: .utility).async { [weak self, weak session] in
            guard let root = PetTipScanner.repoRoot(for: cwd) else { return }
            let tips = PetTipScanner.scan(directory: root)
            guard !tips.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, let session,
                      !(self.petTipShownRoots[sessionID]?.contains(root) ?? false),
                      Date().timeIntervalSince(self.lastPetTipAt) > 90 else { return }
                self.petTipShownRoots[sessionID, default: []].insert(root)
                let index = self.petTipRotation[root, default: 0]
                self.petTipRotation[root] = index + 1
                self.lastPetTipAt = Date()
                let tip = tips[index % tips.count]
                self.presentPetMessage(
                    PetSpeechText.tip(tip), for: session, timeout: 12,
                    onClick: tip.command.map { command in
                        { [weak self, weak session] in
                            guard let self, let session else { return }
                            self.insertSuggestedCommand(command, into: session)
                        }
                    })
            }
        }
    }

    /// Type a suggested command at the pane's prompt — no newline, the user
    /// reviews and hits return. Refuses when something other than the shell
    /// is foreground so we never type into a running TUI.
    private func insertSuggestedCommand(_ command: String, into session: TerminalSession) {
        let foreground = ForegroundProcessTracker.foregroundProcess(of: session.pty.pid)
        guard foreground == nil || foreground?.pid == session.pty.pid else { return }
        session.terminal.userDidInput()
        session.pty.write(Array(command.utf8))
        session.view.window?.makeFirstResponder(session.view)
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
            let standard = standardKeyWindow()
            item.state = standard.flatMap {
                utilityRecord(.files, in: $0)
            } != nil ? .on : .off
            return standard != nil
        }
        if item.action == #selector(openBrowserPane(_:))
            || item.action == #selector(newBrowserPane(_:)) {
            return standardKeyWindow() != nil
        }
        return true
    }

    // MARK: - app control API (external apps / MCP)

    /// Run work on the main thread from a socket thread, with a deadline.
    private func onMain<T>(_ work: @escaping () -> T) -> T? {
        if Thread.isMainThread { return work() }
        var result: T?
        let sem = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            result = work()
            sem.signal()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        return sem.wait(timeout: .now() + 3) == .success ? result : nil
    }

    /// AppKit provisioning is required work, not a best-effort control query.
    /// Await the main actor instead of timing out while its run loop is busy;
    /// a timed-out block remains queued and can otherwise create panes after
    /// the proposal has already been marked failed.
    private func onMainAsync<T>(
        _ work: @escaping @MainActor () -> T
    ) async -> T {
        await MainActor.run {
            work()
        }
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
                    .flatMap { $0 }
                    .compactMap(\.browser)
                    .map { $0.controlState() }
                finish(BrowserControlCodec.response(result: ["browsers": browsers]))
                return true
            }

            if operation == "open" {
                var browserRequest = request
                if let url = request["url"] as? String, !url.isEmpty {
                    browserRequest["op"] = "navigate"
                } else {
                    browserRequest["op"] = "state"
                }

                // Optional target: focus (and optionally navigate) a specific
                // existing instance instead of the most recent one.
                if let browserID = request["browserId"] as? String, !browserID.isEmpty {
                    guard let record = self.browserRecord(withID: browserID),
                          let browser = record.browser else {
                        finish(BrowserControlCodec.response(
                            error: "unknown_browser",
                            message: "No live browser has id \(browserID)."))
                        return true
                    }
                    self.restorePaneZoom(revealing: record.pane)
                    record.pane.window?.makeFirstResponder(record.pane)
                    browser.performAutomation(
                        browserRequest, isCancelled: { operationState.isCancelled },
                        completion: finish)
                    return true
                }

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
                let wantsNewInstance = request["newPane"] as? Bool ?? false
                guard let record = self.openUtilityPanel(
                          .browser, in: window, forceNewInstance: wantsNewInstance),
                      let browser = record.browser else {
                    finish(BrowserControlCodec.response(
                        error: "open_failed", message: "Could not create a browser pane."))
                    return true
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
            guard let browser = self.browserRecord(withID: browserID)?.browser else {
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

    private func handleCollaborationControl(_ encoded: String) -> String {
        return collaborationQueue.sync {
            let result = collaborationCoordinator.execute(encoded)
            if let snapshot = result.snapshot {
                DispatchQueue.main.async { [weak self] in
                    self?.applyCollaborationProjection(snapshot)
                }
            }
            return result.response
        }
    }

    private func chatControlState(
        _ record: UtilityPanelRecord
    ) -> [String: Any]? {
        guard let assistant = record.assistant else { return nil }
        var state = assistant.controlState().jsonObject()
        state["chatId"] = record.ledgerID
        state["paneId"] = collaborationEndpoint(for: record.pane).id
        state["title"] = record.pane.paneHeader.title
        state["role"] = record.participantRole
        let owner = record.pane.window ?? record.ownerWindow
        state["focused"] = owner?.firstResponder === record.pane
        state["open"] = record.pane.superview != nil && owner != nil
        state["channelId"] = channelID(for: record.pane) ?? NSNull()
        let participant = collaborationParticipant(for: record.pane)
        state["provider"] =
            participant?.provider ?? record.configuredProvider ?? NSNull()
        state["model"] =
            participant?.modelID ?? record.configuredModel ?? NSNull()
        return state
    }

    private enum ChatConfigurationResult {
        case success(AppConfig)
        case failure(String)
    }

    private func configuredChat(
        provider rawProvider: String?,
        model: String?
    ) -> ChatConfigurationResult {
        guard let rawProvider else { return .success(config) }
        let provider = rawProvider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let supported = Set(
            InfinittyAIProvider.allCases.map(\.rawValue) + ["auto"])
        guard supported.contains(provider) else {
            return .failure(
                "Unknown provider '\(rawProvider)'. Use auto, claude, codex, "
                    + "opencode, hermes, amp, or apple.")
        }
        var value = config
        value.aiProvider = provider
        let model = model?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        switch provider {
        case "claude": value.claudeModel = model
        case "codex": value.codexModel = model
        case "opencode": value.opencodeModel = model
        case "hermes": value.hermesModel = model
        case "amp": value.ampModel = model
        default: break
        }
        return .success(value)
    }

    private func handleChatControl(_ encoded: String) -> String {
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
        let response = onMain { () -> String in
            if operation == "list" {
                let chats = self.utilityPanels.values
                    .flatMap { $0 }
                    .filter { $0.kind == .chat }
                    .compactMap(self.chatControlState)
                    .sorted {
                        ($0["chatId"] as? String ?? "")
                            < ($1["chatId"] as? String ?? "")
                    }
                return BrowserControlCodec.response(
                    result: ["chats": chats])
            }

            if operation == "create" {
                let chatConfiguration: AppConfig
                switch self.configuredChat(
                    provider: request["provider"] as? String,
                    model: request["model"] as? String)
                {
                case .success(let value):
                    chatConfiguration = value
                case .failure(let message):
                    return BrowserControlCodec.response(
                        error: "invalid_provider", message: message)
                }
                let workspace: String?
                if let rawWorkspace = request["workspace"] as? String {
                    let resolved = URL(fileURLWithPath: rawWorkspace)
                        .resolvingSymlinksInPath().standardizedFileURL
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(
                        atPath: resolved.path,
                        isDirectory: &isDirectory),
                          isDirectory.boolValue
                    else {
                        return BrowserControlCodec.response(
                            error: "invalid_workspace",
                            message:
                                "workspace must be an existing directory.")
                    }
                    workspace = resolved.path
                } else {
                    workspace = nil
                }
                let existingWindow = self.standardKeyWindow()
                    ?? NSApp.windows.first(where: {
                        $0.tabbingIdentifier == "infinitty"
                            && $0 !== self.quickTerminal.window
                    })
                let window: NSWindow
                if let existingWindow {
                    window = existingWindow
                } else {
                    let created = self.makeTerminalWindow(cwd: workspace)
                    window = created.0
                    window.orderFront(nil)
                    created.1.launch()
                }
                guard let record = self.openUtilityPanel(
                          .chat,
                          in: window,
                          forceNewInstance: true,
                          chatConfiguration: chatConfiguration,
                          chatWorkspaceDirectory: workspace,
                          chatTitle: request["name"] as? String,
                          chatRole: request["role"] as? String),
                      let state = self.chatControlState(record)
                else {
                    return BrowserControlCodec.response(
                        error: "create_failed",
                        message: "Could not create the Chat pane.")
                }
                self.appControl.broadcast([
                    "event": "chat-opened",
                    "chatId": record.ledgerID,
                    "paneId": self.collaborationEndpoint(
                        for: record.pane).id,
                ])
                return BrowserControlCodec.response(result: state)
            }

            guard let chatID = request["chatId"] as? String,
                  let record = self.chatRecord(withID: chatID),
                  let assistant = record.assistant
            else {
                return BrowserControlCodec.response(
                    error: "unknown_chat",
                    message: "chatId must identify an open Chat.")
            }
            switch operation {
            case "snapshot":
                guard let state = self.chatControlState(record) else {
                    return BrowserControlCodec.response(
                        error: "chat_unavailable",
                        message: "The Chat assistant is unavailable.")
                }
                return BrowserControlCodec.response(result: state)
            case "focus":
                self.restorePaneZoom(revealing: record.pane)
                (record.pane.window ?? record.ownerWindow)?
                    .makeFirstResponder(record.pane)
            case "close":
                guard let window = record.pane.window ?? record.ownerWindow,
                      self.closeUtilityPanel(record, in: window)
                else {
                    return BrowserControlCodec.response(
                        error: "close_failed",
                        message: "The Chat could not be closed.")
                }
                return BrowserControlCodec.response(result: [
                    "chatId": chatID,
                    "open": false,
                ])
            case "submit":
                guard let rawText = request["text"] as? String,
                      !rawText.trimmingCharacters(
                          in: .whitespacesAndNewlines).isEmpty
                else {
                    return BrowserControlCodec.response(
                        error: "missing_text",
                        message: "text is required.")
                }
                assistant.submitFromControl(
                    rawText,
                    model: "Auto",
                    effort: request["effort"] as? String ?? "Auto")
            case "cancel":
                assistant.cancelConversationWork()
            case "new_thread":
                assistant.startNewChat()
            case "select_thread":
                guard let threadID = request["threadId"] as? String,
                      assistant.selectThreadFromControl(threadID)
                else {
                    return BrowserControlCodec.response(
                        error: "unknown_thread",
                        message:
                            "threadId must identify a thread in this Chat.")
                }
            case "rename":
                guard let rawName = request["name"] as? String else {
                    return BrowserControlCodec.response(
                        error: "missing_name",
                        message: "name is required.")
                }
                let name = rawName.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    return BrowserControlCodec.response(
                        error: "missing_name",
                        message: "name must not be empty.")
                }
                record.pane.paneHeader.title = String(name.prefix(80))
                self.updateCollaborationMembership(for: record.pane)
                self.appControl.broadcast([
                    "event": "chat-renamed",
                    "chatId": chatID,
                    "name": record.pane.paneHeader.title,
                ])
            case "set_workspace":
                guard let rawWorkspace = request["workspace"] as? String else {
                    return BrowserControlCodec.response(
                        error: "invalid_workspace",
                        message: "workspace is required.")
                }
                let workspace = URL(fileURLWithPath: rawWorkspace)
                    .resolvingSymlinksInPath().standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: workspace.path,
                    isDirectory: &isDirectory),
                      isDirectory.boolValue
                else {
                    return BrowserControlCodec.response(
                        error: "invalid_workspace",
                        message:
                            "workspace must be an existing directory.")
                }
                assistant.setWorkspaceDirectory(workspace.path)
            default:
                return BrowserControlCodec.response(
                    error: "unknown_operation",
                    message: "Unknown Chat operation '\(operation)'.")
            }
            guard let state = self.chatControlState(record) else {
                return BrowserControlCodec.response(
                    error: "chat_unavailable",
                    message: "The Chat assistant is unavailable.")
            }
            return BrowserControlCodec.response(result: state)
        }
        return response ?? BrowserControlCodec.response(
            error: "main_thread_timeout",
            message: "Could not schedule Chat control.")
    }

    private func handleChannelPanelControl(_ encoded: String) -> String {
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
        let snapshot = authoritativeCollaborationSnapshot()

        if operation == "list" {
            let states = onMain {
                snapshot.channels.map { channel in
                    let record = self.channelRecord(withID: channel.id)
                    return ChannelPanelProjection(
                        channel: channel,
                        selectedThreadID:
                            record?.channelController?.selectedThreadID)
                        .controlState(isOpen: record != nil)
                }
            } ?? snapshot.channels.map {
                ChannelPanelProjection(
                    channel: $0,
                    selectedThreadID: nil)
                    .controlState(isOpen: false)
            }
            return BrowserControlCodec.response(result: ["channels": states])
        }

        guard let channelID = request["channelId"] as? String,
              !channelID.isEmpty
        else {
            return BrowserControlCodec.response(
                error: "missing_channel",
                message: "channelId is required.")
        }
        guard let channel = snapshot.channels.first(where: {
            $0.id == channelID
        }) else {
            return BrowserControlCodec.response(
                error: "unknown_channel",
                message: "No Channel has id \(channelID).")
        }

        if operation == "post_message" {
            guard let rawText = request["text"] as? String else {
                return BrowserControlCodec.response(
                    error: "missing_text",
                    message: "text is required.")
            }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return BrowserControlCodec.response(
                    error: "missing_text",
                    message: "text must not be empty.")
            }
            let threadID = request["threadId"] as? String
            if let threadID,
               !channel.messages.contains(where: { $0.threadID == threadID })
            {
                return BrowserControlCodec.response(
                    error: "unknown_thread",
                    message: "No Channel thread has id \(threadID).")
            }
            let messageID = UUID().uuidString.lowercased()
            let actor = CollaborationActor(
                id: "local-user:\(NSUserName())",
                kind: .human,
                displayName: NSFullUserName().isEmpty
                    ? NSUserName()
                    : NSFullUserName())
            let message = CollaborationMessage(
                id: messageID,
                threadID: threadID,
                authorID: actor.id,
                text: CollaborationMessage.boundedChannelText(text))
            let mutation = CollaborationControlRequest(
                op: .postMessage,
                actor: actor,
                idempotencyKey: "channel-panel:\(messageID)",
                channelID: channelID,
                message: message)
            guard let encodedMutation = CollaborationControlCodec.encode(mutation)
            else {
                return BrowserControlCodec.response(
                    error: "encode_failed",
                    message: "Could not encode the Channel message.")
            }
            let response = handleCollaborationControl(encodedMutation)
            guard let committed = CollaborationControlCodec.snapshot(
                fromResponse: response),
                  let updated = committed.channels.first(where: {
                      $0.id == channelID
                  })
            else { return response }
            return BrowserControlCodec.response(result:
                ChannelPanelProjection(
                    channel: updated,
                    selectedThreadID: threadID)
                    .controlState(
                        isOpen: onMain {
                            self.channelRecord(withID: channelID) != nil
                        } ?? false))
        }

        if operation == "assign_role" {
            guard let participantID = request["participantId"] as? String,
                  let rawRole = request["role"] as? String
            else {
                return BrowserControlCodec.response(
                    error: "missing_role",
                    message: "participantId and role are required.")
            }
            let role = rawRole.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !role.isEmpty else {
                return BrowserControlCodec.response(
                    error: "missing_role",
                    message: "role must not be empty.")
            }
            guard let participant = channel.participants.first(where: {
                $0.id == participantID
            }), let endpoint = channel.endpoints.first(where: {
                $0.participantID == participantID
            }) else {
                return BrowserControlCodec.response(
                    error: "unknown_participant",
                    message: "No connected participant has id \(participantID).")
            }
            let updatedParticipant = CollaborationParticipant(
                id: participant.id,
                displayName: participant.displayName,
                role: role,
                provider: participant.provider,
                modelID: participant.modelID,
                capabilities: participant.capabilities)
            let actor = CollaborationActor(
                id: "local-user:\(NSUserName())",
                kind: .human,
                displayName: NSFullUserName().isEmpty
                    ? NSUserName()
                    : NSFullUserName())
            let mutation = CollaborationControlRequest(
                op: .updateMembership,
                actor: actor,
                idempotencyKey:
                    "channel-role:\(participantID):\(UUID().uuidString)",
                channelID: channelID,
                endpoint: endpoint,
                participant: updatedParticipant)
            guard let encodedMutation = CollaborationControlCodec.encode(mutation)
            else {
                return BrowserControlCodec.response(
                    error: "encode_failed",
                    message: "Could not encode the role update.")
            }
            let response = handleCollaborationControl(encodedMutation)
            guard let committed = CollaborationControlCodec.snapshot(
                fromResponse: response),
                  let updated = committed.channels.first(where: {
                      $0.id == channelID
                  })
            else { return response }
            let record = onMain {
                self.channelRecord(withID: channelID)
            } ?? nil
            return BrowserControlCodec.response(result:
                ChannelPanelProjection(
                    channel: updated,
                    selectedThreadID:
                        record?.channelController?.selectedThreadID)
                    .controlState(isOpen: record != nil))
        }

        let result = onMain { () -> String in
            let existing = self.channelRecord(withID: channelID)
            switch operation {
            case "snapshot":
                return BrowserControlCodec.response(result:
                    ChannelPanelProjection(
                        channel: channel,
                        selectedThreadID:
                            existing?.channelController?.selectedThreadID)
                        .controlState(isOpen: existing != nil))
            case "open":
                let window = existing?.pane.window
                    ?? self.liveCollaborationPanes().first(where: { pane in
                        guard let paneWindow = pane.window,
                              paneWindow !== self.quickTerminal.window
                        else { return false }
                        let endpointID =
                            self.collaborationEndpoint(for: pane).id
                        return channel.endpoints.contains {
                            $0.id == endpointID
                        }
                    })?.window
                    ?? self.standardKeyWindow()
                guard let window,
                      let record = self.openChannelPanel(
                          channelID: channelID,
                          in: window)
                else {
                    return BrowserControlCodec.response(
                        error: "open_failed",
                        message: "No main tab can host the Channel panel.")
                }
                return BrowserControlCodec.response(result:
                    record.channelController?.controlState()
                        ?? ChannelPanelProjection(
                            channel: channel,
                            selectedThreadID: nil)
                            .controlState(isOpen: true))
            case "focus":
                guard let existing else {
                    return BrowserControlCodec.response(
                        error: "panel_closed",
                        message: "Open the Channel panel before focusing it.")
                }
                self.restorePaneZoom(revealing: existing.pane)
                existing.pane.window?.makeFirstResponder(existing.pane)
                return BrowserControlCodec.response(result:
                    existing.channelController?.controlState()
                        ?? ChannelPanelProjection(
                            channel: channel,
                            selectedThreadID: nil)
                            .controlState(isOpen: true))
            case "close":
                if let existing, let window = existing.pane.window,
                   !self.closeUtilityPanel(existing, in: window)
                {
                    return BrowserControlCodec.response(
                        error: "close_failed",
                        message: "The Channel panel could not be closed.")
                }
                return BrowserControlCodec.response(result:
                    ChannelPanelProjection(
                        channel: channel,
                        selectedThreadID: nil)
                        .controlState(isOpen: false))
            case "select_thread":
                guard let existing,
                      let controller = existing.channelController
                else {
                    return BrowserControlCodec.response(
                        error: "panel_closed",
                        message: "Open the Channel panel before selecting a thread.")
                }
                let threadID = request["threadId"] as? String
                guard controller.selectThreadForControl(threadID) else {
                    return BrowserControlCodec.response(
                        error: "unknown_thread",
                        message: "No Channel thread has id \(threadID ?? "").")
                }
                return BrowserControlCodec.response(result:
                    controller.controlState())
            default:
                return BrowserControlCodec.response(
                    error: "unknown_operation",
                    message: "Unknown Channel panel operation '\(operation)'.")
            }
        }
        return result ?? BrowserControlCodec.response(
            error: "main_thread_timeout",
            message: "Could not schedule Channel panel control.")
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

        func controlHandleAndText(_ arg: String) -> (String, String)? {
            let sub = arg.split(
                separator: " ",
                maxSplits: 1,
                omittingEmptySubsequences: false)
            guard let first = sub.first, !first.isEmpty else { return nil }
            return (
                String(first),
                sub.count > 1 ? String(sub[1]) : "")
        }

        switch cmd {
        case "ping":
            return "pong"
        case "version":
            return "infinitty 0.1"
        case "instance":
            let descriptor: [String: Any] = [
                "id": collaborationInstanceID,
                "pid": Int(getpid()),
                "socket": appControl.path,
                "protocolVersion": 1,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: descriptor))
                ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        case "browser":
            return handleBrowserControl(arg)
        case "chat":
            return handleChatControl(arg)
        case "channel":
            return handleCollaborationControl(arg)
        case "audit":
            return collaborationCoordinator.executeAudit(arg)
        case "channel-panel":
            return handleChannelPanelControl(arg)
        case "channel-project":
            if let snapshot = CollaborationCoordinatorClient.projectedSnapshot(
                from: arg)
            {
                DispatchQueue.main.async { [weak self] in
                    self?.applyCollaborationProjection(snapshot)
                }
                return "ok"
            }
            return "error: invalid Channel projection"
        case "list":
            let panes = onMain { () -> [[String: Any]] in
                let key = NSApp.keyWindow
                return self.liveCollaborationPanes().compactMap { pane in
                    let endpoint = self.collaborationEndpoint(for: pane)
                    var descriptor: [String: Any] = [
                        "id": endpoint.id,
                        "title": endpoint.label,
                        "windowTitle": pane.window?.title ?? "",
                        "focused": key?.firstResponder === pane,
                        "kind": endpoint.kind.rawValue,
                        "channelEndpoint": [
                            "id": endpoint.id,
                            "kind": endpoint.kind.rawValue,
                            "label": endpoint.label,
                            "participantID": endpoint.participantID ?? "",
                            "instanceID": endpoint.instanceID ?? "",
                        ],
                    ]
                    if let terminal = pane as? TerminalView,
                       let session = self.sessions.first(where: {
                           $0.view === terminal
                       })
                    {
                        // Preserve the legacy numeric terminal handle while
                        // exposing every utility pane through the same list.
                        descriptor["id"] = session.id
                        descriptor["terminalSessionID"] = session.id
                        descriptor["cols"] = session.terminal.cols
                        descriptor["rows"] = session.terminal.rows
                        descriptor["socket"] = session.control.path
                    }
                    return descriptor
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
                let t0 = CFAbsoluteTimeGetCurrent()
                let (window, session) = self.makeTerminalWindow(cwd: cwd)
                let t1 = CFAbsoluteTimeGetCurrent()
                host.addTabbedWindow(window, ordered: .above)
                let t2 = CFAbsoluteTimeGetCurrent()
                self.recordPaneLedgerNote(
                    in: window, reason: "tab-joined", origin: "app-control-new-tab")
                // Do not select/key the new tab — keep the user's focus put.
                session.launch()
                let t3 = CFAbsoluteTimeGetCurrent()
                PaneLog.log(String(
                    format: "SOCKTAB make=%.0f addTab=%.0f launch=%.0f total=%.0f ms",
                    (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000,
                    (t3 - t0) * 1000))
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
            guard let (handle, dir) = controlHandleAndText(arg) else {
                return "error: split <id> right|left|down|up"
            }
            let direction = dir.trimmingCharacters(in: .whitespaces).lowercased()
            guard ["right", "left", "down", "up"].contains(direction) else {
                return "error: split <id> right|left|down|up"
            }
            let newID = onMain { () -> Int? in
                guard let target = self.controlPane(withHandle: handle)
                else { return nil }
                let vertical =
                    direction == "right" || direction == "left"
                let newFirst =
                    direction == "left" || direction == "up"
                if let terminal = target as? TerminalView,
                   let session = self.sessions.first(where: {
                       $0.view === terminal
                   })
                {
                    return self.split(
                        session: session,
                        vertical: vertical,
                        newFirst: newFirst)?.id
                }
                return self.splitTerminal(
                    relativeTo: target,
                    vertical: vertical,
                    newFirst: newFirst)?.id
            } ?? nil
            if let newID { return String(newID) }
            return "error: split failed"
        case "focus":
            guard let (handle, _) = controlHandleAndText(arg) else {
                return "error: focus <id>"
            }
            let focused = onMain { () -> Bool in
                if let surfaceWindow = self.surfaceWindows[handle] {
                    surfaceWindow.makeKeyAndOrderFront(nil)
                    return true
                }
                guard let pane = self.controlPane(withHandle: handle),
                      let window = pane.window
                else { return false }
                if let terminal = pane as? TerminalView,
                   let session = self.sessions.first(where: {
                       $0.view === terminal
                   })
                {
                    self.focusSession(session)
                } else {
                    self.restorePaneZoom(revealing: pane)
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(pane)
                    self.updatePaneSelection(in: window, focused: pane)
                }
                return true
            }
            return focused == true ? "ok" : "error: no such pane: \(handle)"
        case "surface":
            guard let (s, json) = paneAndText(arg),
                  !json.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "error: surface <id> <json>"
            }
            switch AgentSurfaceRequest.parse(json) {
            case .failure(let error):
                return "error: \(error.message)"
            case .success(let request):
                return onMain { self.openSurfacePanel(request, for: s) }
                    ?? "error: not ready"
            }
        case "surface-close":
            let surfaceID = arg.trimmingCharacters(in: .whitespaces)
            guard !surfaceID.isEmpty else { return "error: surface-close <surface-id>" }
            let closed = onMain { () -> Bool in
                if let window = self.surfaceWindows[surfaceID] {
                    window.close()
                    return true
                }
                for win in NSApp.windows {
                    if let record = self.utilityRecords(in: win).first(
                        where: { $0.ledgerID == surfaceID && $0.surface != nil }) {
                        return self.closeUtilityPanel(record, in: win)
                    }
                }
                return false
            } ?? false
            return closed ? "ok" : "error: no such surface: \(surfaceID)"
        case "todos":
            guard let (s, json) = paneAndText(arg) else {
                return "error: todos <id> [json-array]"
            }
            let trimmed = json.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return onMain { PaneTodoParser.encode(s.todos) } ?? "[]"
            }
            guard let todos = PaneTodoParser.parse(trimmed) else {
                return "error: todos expects a JSON array"
            }
            _ = onMain { s.setTodos(todos) }
            return "ok"
        case "close":
            guard let (handle, _) = controlHandleAndText(arg) else {
                return "error: close <id>"
            }
            let closed = onMain { () -> Bool in
                if let surfaceWindow = self.surfaceWindows[handle] {
                    surfaceWindow.close()
                    return true
                }
                guard let pane = self.controlPane(withHandle: handle)
                else { return false }
                if let terminal = pane as? TerminalView,
                   let session = self.sessions.first(where: {
                       $0.view === terminal
                   })
                {
                    if let win = session.view.window {
                        self.recordPaneLedgerNote(
                            in: win,
                            paneID: self.paneLedgerTerminalID(session),
                            reason: "close-requested",
                            origin: "app-control-close")
                    }
                    session.terminate()
                    return true
                }
                guard let record = self.utilityRecord(forPane: pane),
                      let window = pane.window ?? record.ownerWindow
                else { return false }
                return self.closeUtilityPanel(record, in: window)
            }
            if closed == true { return "ok" }
            return "error: no such pane: \(handle)"
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
            let itemID = UUID()
            let sem = DispatchSemaphore(value: 0)
            var exitCode = -1
            var commandOutput = ""
            _ = onMain {
                let item = RunCommandQueue.Item(id: itemID, command: text) { code, output in
                    exitCode = code
                    commandOutput = output
                    sem.signal()
                }
                let queue = self.runQueues[s.id] ?? RunCommandQueue()
                self.runQueues[s.id] = queue
                if queue.enqueue(item) {
                    s.view.showAgentGlow()
                    s.pty.write(Array(text.utf8) + [0x0D])
                }
            }
            guard sem.wait(timeout: .now() + 120) == .success else {
                _ = onMain {
                    if let queue = self.runQueues[s.id] {
                        _ = queue.cancelTimedOut(id: itemID)
                        if queue.isEmpty { self.runQueues[s.id] = nil }
                    }
                }
                return "error: timed out waiting for completion (is OSC 133 shell integration enabled?)"
            }
            let payload: [String: Any] = [
                "exitCode": exitCode,
                "output": commandOutput,
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
            let toggled = onMain { () -> Bool in
                guard let win = NSApp.keyWindow
                    ?? NSApp.windows.first(where: { $0.tabbingIdentifier == "infinitty" })
                else { return false }
                return self.toggleCodeView(in: win)
            } ?? false
            return toggled ? "ok" : "error: could not toggle sidebar"
        case "sidebar":
            // Compatibility surface: sidebar show|hide|toggle now controls
            // the Files pane, whose internal switch includes Changes.
            let action = arg.trimmingCharacters(in: .whitespaces).lowercased()
            guard ["show", "hide", "toggle", ""].contains(action) else {
                return "error: sidebar show|hide|toggle"
            }
            let changed = onMain { () -> Bool in
                guard let win = NSApp.keyWindow
                    ?? NSApp.windows.first(where: { $0.tabbingIdentifier == "infinitty" })
                else { return false }
                switch action {
                case "show":
                    return self.openCodeView(in: win) != nil
                case "hide":
                    guard self.utilityRecord(.files, in: win) != nil else { return true }
                    return self.toggleCodeView(in: win)
                default:
                    return self.toggleCodeView(in: win)
                }
            } ?? false
            return changed ? "ok" : "error: could not update sidebar"
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
                + "sidebar | sidebar-tab | chat | chat-model | chat-effort | browser | channel | "
                + "channel-panel | subscribe)"
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
        if config.mcpAutoRegister { _ = MCPConfiguration.registerIfNeeded() }
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
                utilityPanels[ObjectIdentifier(win)]?.forEach {
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
        var invalidatedAssistants = Set<ObjectIdentifier>()
        for record in utilityRecords(in: win) {
            leaveCollaborationPane(record.pane)
            record.browser?.cancelPendingAutomation()
            record.surface?.teardown()
            if let assistant = record.assistant,
               invalidatedAssistants.insert(ObjectIdentifier(assistant)).inserted {
                assistant.invalidate()
            }
            record.assistant = nil
        }
        utilityPanels.removeValue(forKey: ObjectIdentifier(win))
        sidebarToggleAccessories.removeValue(forKey: ObjectIdentifier(win))?.detach()
        terminalChromes.removeValue(forKey: ObjectIdentifier(win))
        updateIndicators.removeValue(forKey: ObjectIdentifier(win))
        win.subtitle = ""
        let closing = sessions.filter { $0.view.window === win }
        for s in closing {
            leaveCollaborationPane(s.view)
            s.shutdown()
        }
        sessions.removeAll { s in closing.contains { $0 === s } }
        // Free per-session state now instead of waiting for the PTY EOF —
        // a child that keeps the pty open (nohup) would otherwise pin the
        // whole session graph forever.
        for s in closing {
            pendingLaunchCommands.removeValue(forKey: s.id)
            petAssistants.removeValue(forKey: s.id)?.invalidate()
            runQueues.removeValue(forKey: s.id)?.cancelAll()
        }
        // Repaint the surviving siblings' strips on the next runloop (after
        // AppKit drops this window from the tab group); without this a closed
        // background tab lingers in every other tab's strip until the next
        // key-window change.
        let siblings = (win.tabbedWindows ?? []).filter { $0 !== win }
        if siblings.isEmpty, let groupID = win.tabGroup.map(ObjectIdentifier.init) {
            lastSelectedTabIndex.removeValue(forKey: groupID)
        }
        if let survivor = siblings.first {
            DispatchQueue.main.async { [weak self] in
                self?.refreshTabStrips(in: survivor)
            }
        }
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
        appMenu.addItem(
            withTitle: "Full Disk Access…",
            action: #selector(AppDelegate.showFullDiskAccessPermission(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(
            withTitle: "Screen Recording Permission…",
            action: #selector(AppDelegate.showScreenRecordingPermission(_:)),
            keyEquivalent: ""
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
        windowMenu.addItem(
            withTitle: "Design Gallery",
            action: #selector(AppDelegate.showDesignGallery(_:)),
            keyEquivalent: "")
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

        let browserItem = windowMenu.addItem(
            withTitle: "Browser",
            action: #selector(AppDelegate.openBrowserPane(_:)),
            keyEquivalent: "b")
        browserItem.keyEquivalentModifierMask = [.command, .shift]
        let newBrowserItem = windowMenu.addItem(
            withTitle: "New Browser Pane",
            action: #selector(AppDelegate.newBrowserPane(_:)),
            keyEquivalent: "b")
        newBrowserItem.keyEquivalentModifierMask = [.command, .option]

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
