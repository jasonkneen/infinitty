import AppKit

/// Single-line rename editor shared by the native-tab popover and the
/// quick-terminal tab strip: ⏎ commits, ⎋ cancels.
class TabRenameTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    /// The main menu claims ⇧⌘←/→ for tab cycling, and key equivalents are
    /// matched before the responder chain runs. While this editor is being
    /// typed in, command-arrow chords must stay the standard line-edge
    /// movement/selection commands; the key window's view hierarchy sees key
    /// equivalents before the menu bar, so reclaim them here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           event.modifierFlags.contains(.command),
           let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
           scalar.value == 0xF702 || scalar.value == 0xF703 { // ←/→ arrows
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func doCommand(by commandSelector: Selector) {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onCommit?()
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        default:
            super.doCommand(by: commandSelector)
        }
    }
}

/// A compact transient popover for renaming an AppKit-native window tab.
/// AppKit does not expose the native tab-label view, so the popover is
/// anchored beneath the selected tab's calculated segment instead of trying
/// to place an editor on top of private titlebar content.
final class TabRenameField: NSObject, NSPopoverDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private weak var hostWindow: NSWindow?
    private let popover = NSPopover()
    private let editor: TabRenameTextView
    private var isPresented = false
    private var clickMonitor: Any?

    var isAcceptingInput: Bool {
        isPresented && popover.isShown && editor.window?.firstResponder === editor
    }

    init(hostWindow: NSWindow, currentName: String) {
        self.hostWindow = hostWindow

        let contentSize = NSSize(width: 280, height: 76)
        let content = NSView(frame: NSRect(origin: .zero, size: contentSize))

        let title = NSTextField(labelWithString: "Rename Tab")
        title.frame = NSRect(x: 18, y: 49, width: 244, height: 18)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        content.addSubview(title)

        let editorFrame = NSRect(x: 0, y: 0, width: 244, height: 27)
        let editor = TabRenameTextView(frame: editorFrame)
        editor.string = currentName
        editor.font = .systemFont(ofSize: 13, weight: .regular)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.isRichText = false
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = true
        editor.autoresizingMask = [.height]
        editor.minSize = editorFrame.size
        editor.maxSize = NSSize(width: .greatestFiniteMagnitude, height: editorFrame.height)
        editor.textContainerInset = NSSize(width: 7, height: 5)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.maximumNumberOfLines = 1
        editor.textContainer?.lineBreakMode = .byClipping
        editor.textContainer?.containerSize = NSSize(
            width: .greatestFiniteMagnitude,
            height: editorFrame.height)
        editor.textContainer?.widthTracksTextView = false

        let editorScroll = NSScrollView(frame: NSRect(x: 18, y: 14, width: 244, height: 27))
        editorScroll.borderType = .noBorder
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = .controlBackgroundColor
        editorScroll.hasHorizontalScroller = false
        editorScroll.hasVerticalScroller = false
        editorScroll.autohidesScrollers = true
        editorScroll.wantsLayer = true
        editorScroll.layer?.cornerRadius = 8
        editorScroll.layer?.borderWidth = 1
        editorScroll.layer?.borderColor = NSColor.separatorColor.cgColor
        editorScroll.layer?.masksToBounds = true
        editorScroll.documentView = editor
        content.addSubview(editorScroll)
        self.editor = editor

        let controller = NSViewController()
        controller.view = content
        controller.preferredContentSize = contentSize
        popover.contentViewController = controller
        popover.contentSize = contentSize
        popover.behavior = .transient
        popover.animates = true

        super.init()

        popover.delegate = self
        editor.onCommit = { [weak self] in self?.commit() }
        editor.onCancel = { [weak self] in self?.dismiss(committed: false) }
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    func present() {
        guard !isPresented,
              let win = hostWindow,
              let contentView = win.contentView
        else { return }

        let tabs = win.tabbedWindows ?? [win]
        let selectedIndex = tabs.firstIndex { $0 === win } ?? 0
        let anchorX = Self.nativeTabAnchorX(
            in: win,
            contentView: contentView,
            selectedIndex: selectedIndex
        ) ?? Self.fallbackAnchorX(
            availableWidth: contentView.bounds.width,
            tabCount: tabs.count,
            selectedIndex: selectedIndex)
        let anchorRect = NSRect(
            x: anchorX - 1,
            y: contentView.bounds.maxY - 1,
            width: 2,
            height: 2)

        isPresented = true
        popover.show(relativeTo: anchorRect, of: contentView, preferredEdge: .minY)
        installClickMonitor()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresented, self.popover.isShown else { return }
            self.editor.window?.makeFirstResponder(self.editor)
            self.editor.setSelectedRange(NSRange(
                location: 0,
                length: (self.editor.string as NSString).length))
        }
    }

    func dismiss(committed: Bool) {
        guard isPresented else { return }
        isPresented = false
        removeClickMonitor()
        popover.close()
        if !committed { onCancel?() }
    }

    func popoverDidClose(_ notification: Notification) {
        guard isPresented else { return }
        isPresented = false
        removeClickMonitor()
        onCancel?()
    }

    private static func nativeTabAnchorX(
        in window: NSWindow,
        contentView: NSView,
        selectedIndex: Int
    ) -> CGFloat? {
        let buttons = window.nativeTabButtonsInVisualOrder()
        guard buttons.indices.contains(selectedIndex),
              let tabWindow = buttons[selectedIndex].window,
              let contentWindow = contentView.window
        else { return nil }

        let button = buttons[selectedIndex]
        let buttonMidpoint = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        let pointInTabWindow = button.convert(buttonMidpoint, to: nil)
        let pointOnScreen = tabWindow.convertPoint(toScreen: pointInTabWindow)
        let pointInContentWindow = contentWindow.convertPoint(fromScreen: pointOnScreen)
        return contentView.convert(pointInContentWindow, from: nil).x
    }

    static func fallbackAnchorX(
        availableWidth: CGFloat,
        tabCount: Int,
        selectedIndex: Int
    ) -> CGFloat {
        guard tabCount > 1 else {
            // With no visible tab strip, place the popover beneath the normal
            // left-side window title instead of floating in empty center space.
            return min(120, max(availableWidth - 1, 1))
        }
        let leadingInset: CGFloat = 14
        let trailingControlsWidth: CGFloat = 76
        let usableWidth = max(availableWidth - leadingInset - trailingControlsWidth, 1)
        let tabWidth = usableWidth / CGFloat(tabCount)
        let index = min(max(selectedIndex, 0), tabCount - 1)
        return min(
            max(leadingInset + tabWidth * (CGFloat(index) + 0.5), 1),
            max(availableWidth - 1, 1))
    }

    private func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isPresented else { return event }
            if event.window === self.editor.window { return event }
            // A click back into the host window saves the typed name — the
            // behavior of Finder's rename-in-place. Clicks anywhere else
            // abandon it. Both run synchronously: the transient popover closes
            // itself on this same click, and popoverDidClose would otherwise
            // record a cancel before a deferred commit could run.
            if event.window === self.hostWindow {
                self.commit()
            } else {
                self.dismiss(committed: false)
            }
            return event
        }
    }

    private func removeClickMonitor() {
        guard let clickMonitor else { return }
        self.clickMonitor = nil
        // Deferred: the outside-click commit reaches here from inside the
        // monitor's own handler, where synchronous removal is not documented
        // as safe.
        DispatchQueue.main.async { NSEvent.removeMonitor(clickMonitor) }
    }

    private func commit() {
        guard isPresented else { return }
        let value = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss(committed: true)
        onCommit?(value)
    }
}
