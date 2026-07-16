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

/// Manages one persistent quick-terminal window. `orderOut` hides it without
/// touching its live TerminalSession, so scrollback and child processes survive.
final class QuickTerminalController: NSObject, NSWindowDelegate {
    typealias WindowFactory = () -> (NSWindow, TerminalSession)?
    typealias SessionsProvider = (NSWindow) -> [TerminalSession]

    private let makeWindow: WindowFactory
    private let sessionsInWindow: SessionsProvider
    private let heightState: QuickTerminalHeightState
    private var config: AppConfig
    private(set) var window: NSWindow?
    private var previousApp: NSRunningApplication?
    private var transition: UInt64 = 0
    private(set) var visible = false

    init(
        config: AppConfig,
        makeWindow: @escaping WindowFactory,
        sessionsInWindow: @escaping SessionsProvider,
        heightState: QuickTerminalHeightState = QuickTerminalHeightState()
    ) {
        self.config = config
        self.makeWindow = makeWindow
        self.sessionsInWindow = sessionsInWindow
        self.heightState = heightState
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
        guard let window else { return false }
        return session.view.window === window
    }

    var hasLiveSession: Bool {
        guard let window else { return false }
        return !sessionsInWindow(window).isEmpty
    }

    func toggle() {
        visible ? hide() : show()
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

    private func ensureWindow() -> (NSWindow, TerminalSession)? {
        if let window {
            guard let session = sessionsInWindow(window).first else { return nil }
            return (window, session)
        }
        guard let (window, session) = makeWindow() else { return nil }
        self.window = window
        window.delegate = self
        configureWindow()
        session.launch()
        return (window, session)
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
