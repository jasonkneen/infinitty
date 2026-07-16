import AppKit
import Carbon
import QuartzCore

/// A parsed system-wide shortcut. Carbon hot keys are deliberately used here
/// instead of an event tap: a single registered shortcut does not need broad
/// Accessibility permission to observe every key press on the system.
struct GlobalHotKeySpec: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static func parse(_ value: String) -> GlobalHotKeySpec? {
        let parts = value.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }

        var modifiers: UInt32 = 0
        var key: String?
        for part in parts {
            switch part {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "opt", "option", "alt": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default:
                guard key == nil else { return nil }
                key = part
            }
        }
        guard modifiers != 0, let key, let keyCode = keyCodes[key] else { return nil }
        return GlobalHotKeySpec(keyCode: keyCode, modifiers: modifiers)
    }

    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
        "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "equals": 24, "9": 25, "7": 26, "-": 27,
        "minus": 27, "8": 28, "0": 29, "]": 30, "rightbracket": 30,
        "o": 31, "u": 32, "[": 33, "leftbracket": 33, "i": 34,
        "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38,
        "'": 39, "quote": 39, "k": 40, ";": 41, "semicolon": 41,
        "\\": 42, "backslash": 42, ",": 43, "comma": 43,
        "/": 44, "slash": 44, "n": 45, "m": 46, ".": 47,
        "period": 47, "tab": 48, "space": 49, "`": 50,
        "backquote": 50, "grave": 50, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
        "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}

/// Owns one Carbon registration and its application event handler.
final class GlobalHotKey {
    private static let signature: OSType = 0x494E4654 // "INFT"
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void

    init?(spec: GlobalHotKeySpec, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(), Self.handleEvent, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard handlerStatus == noErr else { return nil }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            spec.keyCode, spec.modifiers, identifier,
            GetApplicationEventTarget(), 0, &hotKey)
        guard registerStatus == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            self.eventHandler = nil
            return nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private static let handleEvent: EventHandlerUPP = { _, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async { owner.action() }
        return noErr
    }
}

enum QuickTerminalScreen: String {
    case main
    case mouse
    case menuBar = "macos-menu-bar"

    var screen: NSScreen? {
        switch self {
        case .main:
            return NSScreen.main
        case .mouse:
            let point = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        case .menuBar:
            return NSScreen.screens.first ?? NSScreen.main
        }
    }
}

enum QuickTerminalHideReason: Equatable {
    case explicit
    case focusLoss

    var restoresPreviousApplication: Bool { self == .explicit }
}

enum QuickTerminalResidency {
    static func shouldTerminateAfterLastWindowClosed(
        hasRegisteredHotKey: Bool,
        hasLiveSession: Bool
    ) -> Bool {
        !hasRegisteredHotKey && !hasLiveSession
    }
}

final class QuickTerminalHeightState {
    static let defaultsKey = "quickTerminalHeightFraction"
    static let defaultFraction: CGFloat = 0.4

    private let defaults: UserDefaults
    private(set) var fraction: CGFloat

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.object(forKey: Self.defaultsKey) as? NSNumber {
            let value = CGFloat(stored.doubleValue)
            fraction = value.isFinite && value >= 0.1 && value <= 1
                ? value
                : Self.defaultFraction
        } else {
            fraction = Self.defaultFraction
        }
    }

    /// Called once at the end of a live resize, rather than for every frame of
    /// the drag, so UserDefaults is not hammered with redundant writes.
    func record(height: CGFloat, availableHeight: CGFloat) {
        guard availableHeight > 0 else { return }
        fraction = min(max(height / availableHeight, 0.1), 1)
        defaults.set(Double(fraction), forKey: Self.defaultsKey)
    }
}

struct QuickTerminalLayout {
    static func visibleFrame(on screen: NSScreen, heightFraction: CGFloat) -> NSRect {
        visibleFrame(in: screen.visibleFrame, heightFraction: heightFraction)
    }

    static func visibleFrame(in available: NSRect, heightFraction: CGFloat) -> NSRect {
        let resolvedHeight = available.height * min(max(heightFraction, 0.1), 1)
        return NSRect(
            x: available.minX, y: available.maxY - resolvedHeight,
            width: available.width, height: resolvedHeight)
    }

    static func hiddenFrame(for visible: NSRect) -> NSRect {
        NSRect(x: visible.minX, y: visible.maxY, width: visible.width, height: visible.height)
    }
}

/// Borderless panels still need to explicitly opt into keyboard focus.
final class QuickTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Stable page container for one quick-terminal tab. The page stays attached
/// to the panel while hidden, so its terminal renderers and split tree retain
/// normal window ownership.
final class QuickTerminalTabPageView: NSView {
    init(content: NSView) {
        super.init(frame: content.frame)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class QuickTerminalTabStripView: NSView {
    var onSelect: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    private var buttons: [NSButton] = []
    private let addButton = NSButton(title: "+", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.34).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.borderWidth = 1

        addButton.target = self
        addButton.action = #selector(addPressed(_:))
        addButton.isBordered = false
        addButton.font = .systemFont(ofSize: 19, weight: .regular)
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = "New Quick Tab (⌘T)"
        addSubview(addButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(titles: [String], selectedIndex: Int) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = titles.enumerated().map { index, title in
            let button = NSButton(title: title, target: self, action: #selector(tabPressed(_:)))
            button.tag = index
            button.isBordered = false
            button.alignment = .center
            button.lineBreakMode = .byTruncatingTail
            button.font = .systemFont(ofSize: 12, weight: index == selectedIndex ? .semibold : .regular)
            button.contentTintColor = index == selectedIndex ? .labelColor : .secondaryLabelColor
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.backgroundColor = index == selectedIndex
                ? NSColor.white.withAlphaComponent(0.14).cgColor
                : NSColor.clear.cgColor
            button.layer?.borderWidth = index == selectedIndex ? 1 : 0
            button.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            button.toolTip = title
            addSubview(button)
            return button
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 6
        let addWidth: CGFloat = 32
        addButton.frame = NSRect(
            x: bounds.maxX - addWidth - padding,
            y: 2,
            width: addWidth,
            height: max(bounds.height - 4, 0))
        guard !buttons.isEmpty else { return }
        let available = max(addButton.frame.minX - padding * 2, 1)
        let width = floor(available / CGFloat(buttons.count))
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: padding + CGFloat(index) * width,
                y: 3,
                width: max(width - 3, 1),
                height: max(bounds.height - 6, 0))
        }
    }

    @objc private func tabPressed(_ sender: NSButton) { onSelect?(sender.tag) }
    @objc private func addPressed(_ sender: Any?) { onNewTab?() }
}

final class QuickTerminalTabsView: NSView {
    static let stripHeight: CGFloat = 34
    let pageHost = NSView()
    let strip = QuickTerminalTabStripView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(pageHost)
        addSubview(strip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let stripHeight = min(Self.stripHeight, bounds.height)
        pageHost.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - stripHeight)
        strip.frame = NSRect(x: 0, y: bounds.height - stripHeight, width: bounds.width, height: stripHeight)
        for page in pageHost.subviews { page.frame = pageHost.bounds }
    }

    func install(_ page: QuickTerminalTabPageView) {
        page.frame = pageHost.bounds
        page.autoresizingMask = [.width, .height]
        pageHost.addSubview(page)
    }

    func remove(_ page: QuickTerminalTabPageView) { page.removeFromSuperview() }

    func select(_ selected: QuickTerminalTabPageView) {
        for page in pageHost.subviews { page.isHidden = page !== selected }
    }
}

/// Manages one persistent quick-terminal window. `orderOut` hides it without
/// touching its live TerminalSession, so scrollback and child processes survive.
final class QuickTerminalController: NSObject, NSWindowDelegate {
    typealias WindowFactory = () -> (NSWindow, TerminalSession)?
    typealias TabFactory = (NSWindow) -> (NSView, TerminalSession)?
    typealias SessionsProvider = (NSView) -> [TerminalSession]

    private final class Tab {
        let page: QuickTerminalTabPageView
        var title = "Terminal"
        weak var lastFocusedView: TerminalView?

        init(page: QuickTerminalTabPageView) { self.page = page }
    }

    private let makeWindow: WindowFactory
    private let makeTab: TabFactory
    private let sessionsInPage: SessionsProvider
    private let launchSession: (TerminalSession) -> Void
    private let heightState: QuickTerminalHeightState
    private var config: AppConfig
    private(set) var window: NSWindow?
    private var tabsView: QuickTerminalTabsView?
    private var tabs: [Tab] = []
    private var selectedIndex = 0
    private var showShortcutHints = false
    private var previousApp: NSRunningApplication?
    private var transition: UInt64 = 0
    private(set) var visible = false
    var onTabsChanged: (() -> Void)?

    init(
        config: AppConfig,
        makeWindow: @escaping WindowFactory,
        makeTab: @escaping TabFactory,
        sessionsInPage: @escaping SessionsProvider,
        heightState: QuickTerminalHeightState = QuickTerminalHeightState(),
        launchSession: @escaping (TerminalSession) -> Void = { $0.launch() }
    ) {
        self.config = config
        self.makeWindow = makeWindow
        self.makeTab = makeTab
        self.sessionsInPage = sessionsInPage
        self.heightState = heightState
        self.launchSession = launchSession
    }

    func applyConfig(_ config: AppConfig) {
        self.config = config
        configureWindow()
        if visible, let window, let screen = config.quickTerminalScreen.screen {
            window.setFrame(
                QuickTerminalLayout.visibleFrame(
                    on: screen, heightFraction: heightState.fraction),
                display: true)
        }
    }

    func contains(_ session: TerminalSession) -> Bool {
        tab(containing: session) != nil
    }

    var hasLiveSession: Bool {
        tabs.contains { !sessionsInPage($0.page).isEmpty }
    }

    var tabCount: Int { tabs.count }
    var activeRootView: NSView? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex].page : nil }
    var activeSessions: [TerminalSession] {
        guard let activeRootView else { return [] }
        return sessionsInPage(activeRootView)
    }

    func sessions(inTabContaining session: TerminalSession) -> [TerminalSession] {
        guard let tab = tab(containing: session) else { return [] }
        return sessionsInPage(tab.page)
    }

    func setTitle(_ title: String, for session: TerminalSession) {
        guard let index = tabs.firstIndex(where: { contains(session.view, in: $0.page) })
        else { return }
        let tab = tabs[index]
        if index == selectedIndex,
           let focused = window?.firstResponder as? TerminalView,
           contains(focused, in: tab.page),
           focused !== session.view {
            return
        }
        if index != selectedIndex,
           let lastFocusedView = tab.lastFocusedView,
           lastFocusedView !== session.view {
            return
        }
        tab.title = title
        renderTabStrip()
    }

    func setFocusedSession(_ session: TerminalSession) {
        guard let tab = tab(containing: session) else { return }
        tab.lastFocusedView = session.view
        tab.title = session.title
        renderTabStrip()
    }

    func setShowsShortcutHints(_ visible: Bool) {
        guard showShortcutHints != visible else { return }
        showShortcutHints = visible
        renderTabStrip()
    }

    func toggle() {
        visible ? hide() : show()
    }

    @discardableResult
    func newTab() -> TerminalSession? {
        guard let window, let (content, session) = makeTab(window) else { return nil }
        let page = QuickTerminalTabPageView(content: content)
        let tab = Tab(page: page)
        tabs.append(tab)
        tabsView?.install(page)
        selectTab(at: tabs.count - 1)
        launchSession(session)
        onTabsChanged?()
        return session
    }

    @discardableResult
    func selectPreviousTab() -> Bool {
        guard tabs.count > 1 else { return false }
        return selectTab(at: (selectedIndex - 1 + tabs.count) % tabs.count)
    }

    @discardableResult
    func selectNextTab() -> Bool {
        guard tabs.count > 1 else { return false }
        return selectTab(at: (selectedIndex + 1) % tabs.count)
    }

    @discardableResult
    func selectTab(shortcutNumber: Int) -> Bool {
        guard let index = TabNavigation.index(for: shortcutNumber, tabCount: tabs.count) else {
            return false
        }
        return selectTab(at: index)
    }

    /// Removes the tab owning `session`. Returns true when it was the final
    /// tab and the controller reset its panel.
    @discardableResult
    func removeTab(containing session: TerminalSession) -> Bool {
        guard let index = tabs.firstIndex(where: { contains(session.view, in: $0.page) }) else {
            return false
        }
        let removed = tabs.remove(at: index)
        tabsView?.remove(removed.page)
        if tabs.isEmpty {
            lastSessionDidExit()
            return true
        }
        if index < selectedIndex {
            selectedIndex -= 1
        } else if index == selectedIndex {
            selectedIndex = min(index, tabs.count - 1)
        }
        showTab(at: selectedIndex)
        onTabsChanged?()
        return false
    }

    func show() {
        guard !visible, let (window, session) = ensureWindow(),
              let screen = config.quickTerminalScreen.screen else { return }
        visible = true
        transition &+= 1
        let currentTransition = transition

        if !NSApp.isActive,
           let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        }

        let finalFrame = QuickTerminalLayout.visibleFrame(
            on: screen, heightFraction: heightState.fraction)
        window.setFrame(QuickTerminalLayout.hiddenFrame(for: finalFrame), display: false)
        window.alphaValue = 0
        window.level = .popUpMenu
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = config.quickTerminalAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(finalFrame, display: true)
            window.animator().alphaValue = 1
        } completionHandler: { [weak self, weak window, weak session] in
            DispatchQueue.main.async {
                guard let self, let window, let session,
                      self.visible, self.transition == currentTransition else { return }
                window.level = .floating
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                let responder = window.firstResponder as? TerminalView ?? session.view
                window.makeFirstResponder(responder)
            }
        }
    }

    func hide(reason: QuickTerminalHideReason = .explicit) {
        guard visible, let window else { return }
        visible = false
        transition &+= 1
        let currentTransition = transition
        let screen = window.screen ?? config.quickTerminalScreen.screen ?? NSScreen.main
        let visibleFrame = screen.map {
            QuickTerminalLayout.visibleFrame(on: $0, heightFraction: heightState.fraction)
        } ?? window.frame

        let appToRestore = previousApp
        previousApp = nil
        if reason.restoresPreviousApplication, let previousApp = appToRestore {
            if !previousApp.isTerminated { _ = previousApp.activate(options: []) }
        }

        window.level = .popUpMenu
        NSAnimationContext.runAnimationGroup { context in
            context.duration = config.quickTerminalAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(
                QuickTerminalLayout.hiddenFrame(for: visibleFrame), display: true)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            DispatchQueue.main.async {
                guard let self, let window,
                      !self.visible, self.transition == currentTransition else { return }
                window.orderOut(nil)
                window.level = .floating
            }
        }
    }

    /// Called after AppDelegate has already removed and shut down the final
    /// session. The next toggle lazily creates a fresh shell and panel.
    func lastSessionDidExit() {
        visible = false
        transition &+= 1
        window?.orderOut(nil)
        window?.delegate = nil
        window?.contentView = nil
        window?.close()
        window = nil
        tabs.removeAll()
        tabsView = nil
        selectedIndex = 0
        previousApp = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard visible, config.quickTerminalAutohide, window?.attachedSheet == nil else { return }
        hide(reason: .focusLoss)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard visible,
              let resizedWindow = notification.object as? NSWindow,
              resizedWindow === window,
              let screen = resizedWindow.screen ?? config.quickTerminalScreen.screen else { return }
        let available = screen.visibleFrame
        heightState.record(
            height: resizedWindow.frame.height,
            availableHeight: available.height)
        resizedWindow.setFrame(
            QuickTerminalLayout.visibleFrame(
                in: available, heightFraction: heightState.fraction),
            display: true)
    }

    func ensureWindow() -> (NSWindow, TerminalSession)? {
        if let window {
            guard let session = activeSessions.first else { return nil }
            return (window, session)
        }
        guard let (window, session) = makeWindow() else { return nil }
        guard let initialContent = window.contentView else { return nil }
        let tabsView = QuickTerminalTabsView(frame: initialContent.frame)
        window.contentView = tabsView
        let firstPage = QuickTerminalTabPageView(content: initialContent)
        tabsView.install(firstPage)
        tabs = [Tab(page: firstPage)]
        selectedIndex = 0
        self.tabsView = tabsView
        tabsView.strip.onSelect = { [weak self] index in
            _ = self?.selectTab(at: index)
        }
        tabsView.strip.onNewTab = { [weak self] in
            _ = self?.newTab()
        }
        self.window = window
        showTab(at: 0)
        window.delegate = self
        configureWindow()
        launchSession(session)
        onTabsChanged?()
        return (window, session)
    }

    @discardableResult
    private func selectTab(at index: Int) -> Bool {
        guard tabs.indices.contains(index), let window else { return false }
        if tabs.indices.contains(selectedIndex),
           let focused = window.firstResponder as? TerminalView,
           contains(focused, in: tabs[selectedIndex].page) {
            tabs[selectedIndex].lastFocusedView = focused
        }
        selectedIndex = index
        showTab(at: index)
        onTabsChanged?()
        return true
    }

    private func showTab(at index: Int) {
        guard tabs.indices.contains(index), let window else { return }
        let tab = tabs[index]
        tabsView?.select(tab.page)
        renderTabStrip()
        let responder = tab.lastFocusedView
            ?? sessionsInPage(tab.page).first?.view
        if let responder { window.makeFirstResponder(responder) }
    }

    private func renderTabStrip() {
        let titles = tabs.enumerated().map { index, tab in
            guard showShortcutHints,
                  let number = TabNavigation.shortcutNumber(
                    forTabIndex: index, tabCount: tabs.count)
            else { return tab.title }
            return "⌘\(number)  \(tab.title)"
        }
        tabsView?.strip.update(titles: titles, selectedIndex: selectedIndex)
    }

    private func tab(containing session: TerminalSession) -> Tab? {
        tabs.first { contains(session.view, in: $0.page) }
    }

    private func contains(_ view: NSView, in page: NSView) -> Bool {
        view === page || view.isDescendant(of: page)
    }

    private func configureWindow() {
        guard let window else { return }
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.level = .floating
        window.hasShadow = true
        window.isMovable = false
        window.isExcludedFromWindowsMenu = true
    }

}
