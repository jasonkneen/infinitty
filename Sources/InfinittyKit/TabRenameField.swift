import AppKit

/// A floating NSPanel that hosts an inline NSTextField for renaming the
/// active window/tab. Designed to look like a modern Spotlight/find-bar
/// affordance: rounded, slightly translucent, fades in.
///
/// Usage:
///   let field = TabRenameField(window: someWindow, currentName: "...", ...)
///   field.onCommit = { newName in ... }
///   field.onCancel = { ... }
///   field.present()
///   field.dismiss() when done.
///
/// Dismissal is automatic on:
///   - ⏎ commit (with trimmed text)
///   - ⎋ cancel
///   - focus loss (clicked outside or window deactivated)
///   - `dismiss()` from outside
final class TabRenameField: NSObject, NSTextFieldDelegate {

    /// Commit handler. Receives the trimmed text. Empty string means
    /// "clear the override and restore the automatic title".
    var onCommit: ((String) -> Void)?
    /// Cancel handler. Fired when the user pressed ⎋ or otherwise
    /// dismissed without committing.
    var onCancel: (() -> Void)?

    private weak var hostWindow: NSWindow?
    private let panel: NSPanel
    private let textField: NSTextField
    private let initialName: String

    private var focusObserver: Any?
    private var clickMonitor: Any?

    /// Frame used when `hostWindow` is nil or detached.
    private static let panelSize = NSSize(width: 260, height: 32)

    init(hostWindow: NSWindow, currentName: String) {
        self.hostWindow = hostWindow
        self.initialName = currentName

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: TabRenameField.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // Don't let the system add it to the window menu.
        panel.isExcludedFromWindowsMenu = true
        self.panel = panel

        // Visual container — rounded rect, slightly translucent fill.
        let visual = NSView(frame: NSRect(origin: .zero, size: TabRenameField.panelSize))
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 7
        visual.layer?.borderWidth = 1
        visual.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        visual.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 0.92).cgColor
        panel.contentView = visual

        // The text field itself — 8pt side padding inside the panel.
        let field = NSTextField(frame: NSRect(
            x: 10, y: 5,
            width: TabRenameField.panelSize.width - 20,
            height: TabRenameField.panelSize.height - 10
        ))
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = NSColor.white
        field.placeholderString = "Tab name"
        field.placeholderAttributedString = NSAttributedString(
            string: "Tab name",
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.4),
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            ]
        )
        field.stringValue = currentName
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        visual.addSubview(field)
        self.textField = field

        super.init()

        field.delegate = self
        field.target = self
        field.action = #selector(commitField(_:))
    }

    deinit {
        if let f = focusObserver { NotificationCenter.default.removeObserver(f) }
        if let c = clickMonitor { NSEvent.removeMonitor(c) }
    }

    // MARK: - Presentation

    /// Show the rename panel over the given window's titlebar area, focus the
    /// field, and select its current contents.
    func present() {
        guard let win = hostWindow else { return }
        positionOver(win: win)

        // Order front regardless of key state.
        win.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        // Focus + select all on the next runloop tick so the panel is real.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.makeFirstResponder(self.textField)
            self.textField.currentEditor()?.selectedRange = NSRange(location: 0, length: self.textField.stringValue.count)
        }

        installDismissMonitors()
    }

    /// Close the panel. Calls `onCancel` only if `committed == false`.
    func dismiss(committed: Bool) {
        // Tear down monitors first so they don't fire on the dismissal path.
        if let f = focusObserver { NotificationCenter.default.removeObserver(f); focusObserver = nil }
        if let c = clickMonitor { NSEvent.removeMonitor(c); clickMonitor = nil }

        // Detach from host.
        hostWindow?.removeChildWindow(panel)
        panel.orderOut(nil)

        if !committed { onCancel?() }
    }

    // MARK: - Layout

    /// Place the panel over the titlebar of the host window — centered
    /// horizontally, vertically pinned just above the top of the content view
    /// (so it sits in or under the titlebar/tab strip depending on style).
    private func positionOver(win: NSWindow) {
        let winFrame = win.frame
        let layoutRect = win.contentLayoutRect
        let tabBarHeight = max(0, winFrame.height - layoutRect.maxY)
        let x = winFrame.midX - Self.panelSize.width / 2
        // Aim for the middle of the titlebar+tab strip; clamp to a sane
        // offset so we always sit *inside* the window, not above it.
        let stripMidY = winFrame.maxY - tabBarHeight / 2
        let y = stripMidY - Self.panelSize.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Dismiss monitors

    /// Install (a) a focus-change observer that dismisses on app deactivation,
    /// and (b) a local mouse monitor that dismisses when the user clicks
    /// outside the panel and not on a text-field-activating widget.
    private func installDismissMonitors() {
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.dismiss(committed: false) }

        // Click outside → commit (treat as "ok"). This matches the
        // behavior of Finder's rename-in-place.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, let panel = self.panel as NSPanel?, panel.isVisible else { return event }
            // If the click is inside our panel, let it through.
            if event.window === panel { return event }
            // If the click is on the host window, commit (treat as OK).
            if let host = self.hostWindow, event.window === host {
                // Commit on the next runloop so the field finishes its own
                // mouseDown handling first.
                DispatchQueue.main.async { [weak self] in self?.commit() }
                return event
            }
            // Otherwise (clicked another window), commit too.
            DispatchQueue.main.async { [weak self] in self?.commit() }
            return event
        }
    }

    // MARK: - Actions

    @objc private func commitField(_ sender: Any?) { commit() }

    private func commit() {
        // Guard against double-dismiss.
        guard panel.isVisible else { return }
        let value = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onCommit?(value)
        dismiss(committed: true)
    }


    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            // ⎋ pressed — cancel.
            dismiss(committed: false)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // ⏎ pressed — commit.
            commit()
            return true
        default:
            return false
        }
    }
}
