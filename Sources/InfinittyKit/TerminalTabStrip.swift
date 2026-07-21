import AppKit

/// Custom in-pane tab strip for standard terminal windows. Replaces the
/// native NSWindow tab bar (which spans the whole titlebar and paints across
/// the code-view sidebar). It lives inside the terminal column of the window
/// content, so the sidebar owns its own clean full-height column.
///
/// The strip is a *view* of the native tab group: it renders one button per
/// `NSWindow` in `tabbedWindows` and drives selection through
/// `tabGroup.selectedWindow`. All window/session/split lifecycle stays with
/// AppKit's tab group — only the tab *bar's appearance* is ours.
final class TerminalTabStripView: NSView {
    /// Select the tab at `index` (single click).
    var onSelect: ((Int) -> Void)?
    /// Begin rename for the tab at `index` (double click).
    var onRename: ((Int) -> Void)?
    /// Close the tab at `index`.
    var onClose: ((Int) -> Void)?
    /// Create a new tab (the trailing +).
    var onNewTab: (() -> Void)?
    var onRenameCommit: ((String) -> Void)?
    var onRenameCancel: (() -> Void)?
    /// Reorder the tab from `from` to `to` (drag within the strip).
    var onReorder: ((Int, Int) -> Void)?
    /// Tear the tab at `index` out into its own new window (drag out).
    var onTearOut: ((Int) -> Void)?

    static let height: CGFloat = 36
    /// Vertical column layout (side tabs) instead of a horizontal row.
    var vertical = false { didSet { needsLayout = true } }
    private static var accent: NSColor { CodePalette.selectionAccent }

    private var titles: [String] = []
    private var selectedIndex = 0
    private var tabButtons: [NSButton] = []
    private var closeButtons: [NSButton] = []
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let hairline = NSView()

    private var renamingIndex: Int?
    private weak var renameEditor: TabRenameTextView?
    private var endingRename = false
    private var dragIndex: Int?
    private var dragStart = NSPoint.zero
    private var dragMoved = false

    var isRenaming: Bool { renameEditor != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        addButton.image = NSImage(
            systemSymbolName: "plus", accessibilityDescription: "New Tab")
        addButton.imagePosition = .imageOnly
        addButton.isBordered = false
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addPressed)
        addButton.toolTip = "New Tab (⌘T)"
        addSubview(addButton)

        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = CodePalette.hairline.cgColor
        addSubview(hairline)
    }

    /// Fill the strip so the transparent titlebar region (fullSizeContentView
    /// + titlebarAppearsTransparent) doesn't show the desktop behind the tabs.
    func setBackgroundColor(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var titlesForTesting: [String] { titles }
    var selectedIndexForTesting: Int { selectedIndex }
    var tabButtonFramesForTesting: [NSRect] { tabButtons.map { $0.frame } }
    var addButtonFrameForTesting: NSRect { addButton.frame }

    /// Pin metadata for a tab: a compact SF-symbol icon + accent color shown
    /// instead of the title. Pinned tabs render first, icon-only, fixed width.
    struct Pin: Equatable {
        var icon: String
        var color: NSColor
    }
    /// Pin state keyed by tab index (from the last update()).
    private var pins: [Int: Pin] = [:]
    /// Right-click a tab to pin/unpin or restyle.
    var onContextMenu: ((Int, NSButton) -> Void)?

    /// Rebuild the strip from the tab group's titles + selection + pins.
    func update(titles: [String], selectedIndex: Int, pins: [Int: Pin] = [:]) {
        self.selectedIndex = selectedIndex
        self.pins = pins
        if titles.count != self.titles.count {
            // Structure changed mid-rename: positional target is now ambiguous.
            if renameEditor != nil { finishRename(committing: false) }
            rebuildButtons(count: titles.count)
        }
        self.titles = titles
        for (index, title) in titles.enumerated() {
            let button = tabButtons[index]
            let active = index == selectedIndex
            let pin = pins[index]
            if let pin {
                button.title = ""
                button.image = NSImage(systemSymbolName: pin.icon, accessibilityDescription: title)
                button.imagePosition = .imageOnly
                button.contentTintColor = .white
                button.layer?.backgroundColor = pin.color.cgColor
            } else {
                button.image = NSImage(
                    systemSymbolName: "terminal.fill", accessibilityDescription: title)
                button.title = title
                button.imagePosition = .imageLeading
                button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
                button.font = .systemFont(ofSize: 11, weight: active ? .semibold : .regular)
                button.contentTintColor = active ? .labelColor : .secondaryLabelColor
                button.layer?.backgroundColor = active
                    ? NSColor.white.withAlphaComponent(0.10).cgColor
                    : NSColor.clear.cgColor
                button.layer?.borderColor = active
                    ? NSColor.white.withAlphaComponent(0.10).cgColor
                    : NSColor.clear.cgColor
                button.layer?.borderWidth = active ? 1 : 0
            }
            button.toolTip = title
            closeButtons[index].isHidden = pin != nil || !active || renamingIndex != nil
            closeButtons[index].contentTintColor = active ? .white : .secondaryLabelColor
        }
        if let renamingIndex, tabButtons.indices.contains(renamingIndex) {
            tabButtons[renamingIndex].isHidden = true
            closeButtons[renamingIndex].isHidden = true
        }
        needsLayout = true
    }

    private func rebuildButtons(count: Int) {
        tabButtons.forEach { $0.removeFromSuperview() }
        closeButtons.forEach { $0.removeFromSuperview() }
        tabButtons = (0..<count).map { index in
            let button = DraggableTabButton(title: "", target: nil, action: nil)
            button.strip = self
            button.tag = index
            button.isBordered = false
            button.alignment = .center
            button.lineBreakMode = .byTruncatingTail
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            addSubview(button)
            return button
        }
        closeButtons = (0..<count).map { index in
            let close = NSButton(title: "", target: self, action: #selector(closePressed(_:)))
            close.tag = index
            close.image = NSImage(
                systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
            close.imagePosition = .imageOnly
            close.isBordered = false
            close.contentTintColor = .secondaryLabelColor
            (close.cell as? NSButtonCell)?.imageScaling = .scaleProportionallyDown
            close.toolTip = "Close Tab (⌘W)"
            addSubview(close, positioned: .above, relativeTo: nil)
            return close
        }
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 6
        let leadingInset: CGFloat = 78
        let addSize: CGFloat = 28
        if vertical {
            hairline.frame = NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height)
            addButton.frame = NSRect(
                x: (bounds.width - addSize) / 2, y: bounds.maxY - addSize - pad,
                width: addSize, height: addSize)
            guard !tabButtons.isEmpty else { return }
            let rowH: CGFloat = 30
            for (index, button) in tabButtons.enumerated() {
                let frame = NSRect(
                    x: pad, y: bounds.maxY - pad - CGFloat(index + 1) * (rowH + 4) + 4,
                    width: bounds.width - pad * 2, height: rowH)
                button.frame = frame
                button.alignment = .left
                closeButtons[index].frame = NSRect(
                    x: frame.maxX - 22, y: frame.minY + (rowH - 20) / 2,
                    width: 20, height: 20)
            }
            if let renamingIndex, tabButtons.indices.contains(renamingIndex), let renameEditor {
                renameEditor.frame = tabButtons[renamingIndex].frame.insetBy(dx: 8, dy: 5)
            }
            return
        }
        hairline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        addButton.frame = NSRect(
            x: bounds.maxX - addSize - pad - 32, y: (bounds.height - addSize) / 2,
            width: addSize, height: addSize)
        guard !tabButtons.isEmpty else { return }
        let available = max(addButton.frame.minX - pad - leadingInset, 1)
        let pinWidth: CGFloat = 34
        let pinnedCount = pins.count
        let unpinnedCount = max(tabButtons.count - pinnedCount, 0)
        let usedByPins = CGFloat(pinnedCount) * (pinWidth + pad)
        let remaining = max(available - usedByPins, 1)
        let tabWidth = unpinnedCount > 0
            ? min(220, max(remaining / CGFloat(unpinnedCount) - pad, 1))
            : 1
        let tabHeight = bounds.height - 8
        var xPos = leadingInset
        for (index, button) in tabButtons.enumerated() {
            let isPinned = pins[index] != nil
            let width = isPinned ? pinWidth : tabWidth
            button.alignment = isPinned ? .center : .center
            let frame = NSRect(x: xPos, y: 4, width: width, height: tabHeight)
            button.frame = frame
            closeButtons[index].frame = NSRect(
                x: frame.maxX - 22, y: frame.minY, width: 20, height: frame.height)
            xPos += width + pad
        }
        if let renamingIndex, tabButtons.indices.contains(renamingIndex), let renameEditor {
            renameEditor.frame = tabButtons[renamingIndex].frame.insetBy(dx: 8, dy: 5)
        }
    }

    func showTabContextMenu(index: Int, button: NSButton) {
        onContextMenu?(index, button)
    }

    @objc private func tabPressed(_ sender: NSButton) {
        let clicks = NSApp.currentEvent?.clickCount ?? 1
        if clicks >= 2 {
            onRename?(sender.tag)
        } else {
            commitRename()
            onSelect?(sender.tag)
        }
    }

    @objc private func closePressed(_ sender: NSButton) { onClose?(sender.tag) }
    @objc private func addPressed() {
        commitRename()
        onNewTab?()
    }

    // MARK: - rename

    @discardableResult
    func beginRename(at index: Int, currentName: String) -> Bool {
        guard renameEditor == nil, tabButtons.indices.contains(index) else { return false }
        layoutSubtreeIfNeeded()
        renamingIndex = index
        tabButtons[index].isHidden = true
        closeButtons[index].isHidden = true

        let editor = TabRenameTextView(frame: tabButtons[index].frame.insetBy(dx: 8, dy: 5))
        editor.string = currentName
        editor.alignment = .center
        editor.font = .systemFont(ofSize: 12, weight: .semibold)
        editor.textColor = .white
        editor.insertionPointColor = .white
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.textContainerInset = NSSize(width: 4, height: 3)
        editor.textContainer?.lineFragmentPadding = 0
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 7
        editor.layer?.zPosition = 10
        editor.layer?.backgroundColor = Self.accent.cgColor
        editor.onCommit = { [weak self] in self?.finishRename(committing: true) }
        editor.onCancel = { [weak self] in self?.finishRename(committing: false) }
        addSubview(editor, positioned: .above, relativeTo: nil)
        renameEditor = editor
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        return true
    }

    @discardableResult
    func commitRename() -> Bool {
        guard renameEditor != nil else { return false }
        finishRename(committing: true)
        return true
    }

    @discardableResult
    func cancelRename() -> Bool {
        guard renameEditor != nil else { return false }
        finishRename(committing: false)
        return true
    }

    private func finishRename(committing: Bool) {
        guard !endingRename, let editor = renameEditor else { return }
        endingRename = true
        let value = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = renamingIndex
        renameEditor = nil
        renamingIndex = nil
        editor.onCommit = nil
        editor.onCancel = nil
        editor.removeFromSuperview()
        if let index, tabButtons.indices.contains(index) { tabButtons[index].isHidden = false }
        endingRename = false
        if committing { onRenameCommit?(value) } else { onRenameCancel?() }
    }
}

extension TerminalTabStripView {
    /// Handle a press-drag-release cycle originating on the tab button at
    /// `index`. Reorders within the strip when dragged horizontally; tears the
    /// tab out into a new window when dragged vertically beyond the strip.
    func handleTabDrag(index: Int, startEvent: NSEvent) {
        guard let window else { return }
        let startInWindow = startEvent.locationInWindow
        var moved = false
        var currentIndex = index
        var tornOut = false

        trackingLoop: while true {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
            else { break }
            switch event.type {
            case .leftMouseDragged:
                let now = event.locationInWindow
                let dx = now.x - startInWindow.x
                let dy = now.y - startInWindow.y
                if abs(dx) > 4 || abs(dy) > 4 { moved = true }
                // Vertical drag beyond the strip height → tear out.
                if abs(dy) > Self.height + 12 {
                    tornOut = true
                    break trackingLoop
                }
                // Horizontal reorder: find the tab slot under the cursor.
                let localX = convert(now, from: nil).x
                if let target = tabIndex(atX: localX), target != currentIndex {
                    onReorder?(currentIndex, target)
                    currentIndex = target
                }
            case .leftMouseUp:
                break trackingLoop
            default:
                break
            }
        }
        if tornOut {
            onTearOut?(currentIndex)
        } else if !moved {
            // A plain click (no drag) still selects / renames.
            let clicks = startEvent.clickCount
            if clicks >= 2 { onRename?(currentIndex) } else { onSelect?(currentIndex) }
        }
    }

    private func tabIndex(atX x: CGFloat) -> Int? {
        for (index, button) in tabButtons.enumerated() where !button.isHidden {
            if x >= button.frame.minX && x <= button.frame.maxX { return index }
        }
        return nil
    }
}

/// Tab button that hands its full press-drag-release cycle to the strip so
/// drags reorder / tear out instead of just clicking.
final class DraggableTabButton: NSButton {
    weak var strip: TerminalTabStripView?

    override func mouseDown(with event: NSEvent) {
        strip?.handleTabDrag(index: tag, startEvent: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        strip?.showTabContextMenu(index: tag, button: self)
    }
}

/// Terminal-column chrome: the custom tab strip stacked above the terminal
/// body. The window's content is this view (or a sidebar split wrapping it),
/// so the strip never extends across the code-view sidebar.
final class TerminalChromeView: NSView {
    let strip = TerminalTabStripView()
    let body = NSView()
    /// When false (single tab), the strip is hidden and the body fills the
    /// whole chrome — matching macOS's "no tab bar for one tab" behaviour.
    var showsStrip = true {
        didSet {
            // Reference chrome always retains one visible tab, even for a
            // single session. Keep this property for existing call sites.
            strip.isHidden = false
            needsLayout = true
        }
    }
    /// When true the strip is a vertical column on the LEFT instead of a row
    /// on top (config: side-tabs).
    var sideTabs = false {
        didSet { strip.vertical = sideTabs; needsLayout = true }
    }
    static let sideWidth: CGFloat = 150

    private let stripBlur = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        body.autoresizingMask = [.width, .height]
        addSubview(body)
        stripBlur.material = .hudWindow
        stripBlur.blendingMode = .behindWindow
        stripBlur.state = .active
        stripBlur.isHidden = true
        addSubview(stripBlur)
        strip.isHidden = false
        addSubview(strip)
    }

    /// Match the terminal's backing so the transparent titlebar region doesn't
    /// show the desktop behind the tabs. With blur, the strip gets a frosted
    /// backing plus a subtle tint; otherwise a solid theme colour.
    func setBacking(color: NSColor, blur: Bool) {
        stripBlur.isHidden = !blur
        if blur {
            strip.setBackgroundColor(color.withAlphaComponent(0.42))
        } else {
            strip.setBackgroundColor(color)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        if sideTabs {
            let stripW = min(Self.sideWidth, bounds.width)
            strip.frame = NSRect(x: 0, y: 0, width: stripW, height: bounds.height)
            stripBlur.frame = strip.frame
            body.frame = NSRect(
                x: stripW, y: 0, width: bounds.width - stripW, height: bounds.height)
        } else {
        let stripH = min(TerminalTabStripView.height, bounds.height)
            strip.frame = NSRect(
                x: 0, y: bounds.height - stripH, width: bounds.width, height: stripH)
            stripBlur.frame = strip.frame
            body.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - stripH)
        }
        for sub in body.subviews { sub.frame = body.bounds }
    }
}
