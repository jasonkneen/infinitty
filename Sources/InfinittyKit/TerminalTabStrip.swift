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

    static let height: CGFloat = 34
    private static let accent = CodePalette.selectionAccent

    private var titles: [String] = []
    private var selectedIndex = 0
    private var tabButtons: [NSButton] = []
    private var closeButtons: [NSButton] = []
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let hairline = NSView()

    private var renamingIndex: Int?
    private weak var renameEditor: TabRenameTextView?
    private var endingRename = false

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

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var titlesForTesting: [String] { titles }
    var selectedIndexForTesting: Int { selectedIndex }
    var tabButtonFramesForTesting: [NSRect] { tabButtons.map { $0.frame } }
    var addButtonFrameForTesting: NSRect { addButton.frame }

    /// Rebuild the strip from the tab group's window titles + selection.
    func update(titles: [String], selectedIndex: Int) {
        self.selectedIndex = selectedIndex
        if titles.count != self.titles.count {
            // Structure changed mid-rename: positional target is now ambiguous.
            if renameEditor != nil { finishRename(committing: false) }
            rebuildButtons(count: titles.count)
        }
        self.titles = titles
        for (index, title) in titles.enumerated() {
            let button = tabButtons[index]
            let active = index == selectedIndex
            button.title = title
            button.font = .systemFont(ofSize: 12, weight: active ? .semibold : .regular)
            button.contentTintColor = active ? .white : .secondaryLabelColor
            button.layer?.backgroundColor = active
                ? Self.accent.cgColor
                : NSColor.clear.cgColor
            button.toolTip = title
            closeButtons[index].isHidden = !active || renamingIndex != nil
            closeButtons[index].contentTintColor = active
                ? .white : .secondaryLabelColor
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
            let button = NSButton(title: "", target: self, action: #selector(tabPressed(_:)))
            button.tag = index
            button.isBordered = false
            button.alignment = .center
            button.lineBreakMode = .byTruncatingTail
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
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
        hairline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        let pad: CGFloat = 6
        let addSize: CGFloat = 28
        addButton.frame = NSRect(
            x: bounds.maxX - addSize - pad, y: (bounds.height - addSize) / 2,
            width: addSize, height: addSize)
        guard !tabButtons.isEmpty else { return }
        let available = max(addButton.frame.minX - pad, 1)
        // Tabs fill the available terminal width evenly (no dead space).
        let tabWidth = min(220, max(available / CGFloat(tabButtons.count) - pad, 1))
        let tabHeight = bounds.height - 8
        for (index, button) in tabButtons.enumerated() {
            let frame = NSRect(
                x: pad + CGFloat(index) * (tabWidth + pad), y: 4,
                width: tabWidth, height: tabHeight)
            button.frame = frame
            closeButtons[index].frame = NSRect(
                x: frame.maxX - 22, y: frame.minY, width: 20, height: frame.height)
        }
        if let renamingIndex, tabButtons.indices.contains(renamingIndex), let renameEditor {
            renameEditor.frame = tabButtons[renamingIndex].frame.insetBy(dx: 8, dy: 5)
        }
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

/// Terminal-column chrome: the custom tab strip stacked above the terminal
/// body. The window's content is this view (or a sidebar split wrapping it),
/// so the strip never extends across the code-view sidebar.
final class TerminalChromeView: NSView {
    let strip = TerminalTabStripView()
    let body = NSView()
    /// When false (single tab), the strip is hidden and the body fills the
    /// whole chrome — matching macOS's "no tab bar for one tab" behaviour.
    var showsStrip = false { didSet { needsLayout = true; strip.isHidden = !showsStrip } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        body.autoresizingMask = [.width, .height]
        addSubview(body)
        strip.isHidden = true
        addSubview(strip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let stripH = showsStrip ? min(TerminalTabStripView.height, bounds.height) : 0
        strip.frame = NSRect(
            x: 0, y: bounds.height - stripH, width: bounds.width, height: stripH)
        body.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - stripH)
    }
}
