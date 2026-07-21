import AppKit

/// Searchable tab switcher presented from the titlebar search affordance. It
/// behaves like a small command palette instead of a context menu: typing
/// filters both open tabs and actions, arrows move, Return runs, Escape closes.
final class TabCommandPaletteViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate
{
    private enum Action {
        case select(Int)
        case newTab
    }

    private struct Item {
        let title: String
        let detail: String
        let symbol: String
        let action: Action
    }

    var onSelect: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let allItems: [Item]
    private var filteredItems: [Item]

    init(titles: [String], selectedIndex: Int) {
        var items = [Item(
            title: "New terminal tab", detail: "Create a new main tab",
            symbol: "plus", action: .newTab)]
        items += titles.enumerated().map { index, title in
            Item(
                title: title,
                detail: index == selectedIndex ? "Current tab" : "Switch to tab",
                symbol: index == selectedIndex ? "checkmark.circle.fill" : "terminal",
                action: .select(index))
        }
        allItems = items
        filteredItems = items
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 380, height: 270)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let surface = NSVisualEffectView(frame: NSRect(origin: .zero, size: preferredContentSize))
        surface.material = .popover
        surface.blendingMode = .withinWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 14
        surface.layer?.masksToBounds = true

        searchField.placeholderString = "Search tabs or commands"
        searchField.font = .systemFont(ofSize: 14, weight: .medium)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(runSelected)
        searchField.setAccessibilityLabel("Search tabs or commands")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 40
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(runSelected)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        surface.addSubview(searchField)
        surface.addSubview(scroll)
        view = surface
        selectFirstResult()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let inset: CGFloat = 12
        let searchHeight: CGFloat = 32
        searchField.frame = NSRect(
            x: inset, y: view.bounds.height - inset - searchHeight,
            width: max(view.bounds.width - inset * 2, 0), height: searchHeight)
        scroll.frame = NSRect(
            x: 6, y: 6, width: max(view.bounds.width - 12, 0),
            height: max(searchField.frame.minY - 12, 0))
        table.sizeLastColumnToFit()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredItems.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard filteredItems.indices.contains(row) else { return nil }
        let item = filteredItems[row]
        let identifier = NSUserInterfaceItemIdentifier("command-row")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView) ?? makeCommandCell(identifier: identifier)
        cell.textField?.stringValue = item.title
        cell.imageView?.image = NSImage(
            systemSymbolName: item.symbol, accessibilityDescription: item.title)
        cell.imageView?.contentTintColor = .secondaryLabelColor
        if let detail = cell.subviews.compactMap({ $0 as? NSTextField })
            .first(where: { $0 !== cell.textField }) {
            detail.stringValue = item.detail
        }
        return cell
    }

    private func makeCommandCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let icon = NSImageView(frame: NSRect(x: 10, y: 10, width: 18, height: 18))
        icon.imageScaling = .scaleProportionallyDown
        let title = NSTextField(labelWithString: "")
        title.frame = NSRect(x: 38, y: 17, width: 235, height: 17)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: "")
        detail.frame = NSRect(x: 38, y: 2, width: 235, height: 15)
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        cell.imageView = icon
        cell.textField = title
        cell.addSubview(icon)
        cell.addSubview(title)
        cell.addSubview(detail)
        return cell
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss?()
        case #selector(NSResponder.insertNewline(_:)):
            runSelected()
        default:
            return false
        }
        return true
    }

    private func applyFilter(_ query: String) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredItems = needle.isEmpty ? allItems : allItems.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.detail.localizedCaseInsensitiveContains(needle)
        }
        table.reloadData()
        selectFirstResult()
    }

    private func selectFirstResult() {
        if filteredItems.isEmpty {
            table.deselectAll(nil)
        } else {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    private func moveSelection(by delta: Int) {
        guard !filteredItems.isEmpty else { return }
        let current = max(table.selectedRow, 0)
        let row = min(max(current + delta, 0), filteredItems.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func runSelected() {
        let row = table.selectedRow >= 0 ? table.selectedRow : 0
        guard filteredItems.indices.contains(row) else { return }
        switch filteredItems[row].action {
        case .select(let index): onSelect?(index)
        case .newTab: onNewTab?()
        }
        onDismiss?()
    }

    var filteredTitlesForTesting: [String] { filteredItems.map(\.title) }
    func setQueryForTesting(_ query: String) { applyFilter(query) }
    func performFirstResultForTesting() {
        selectFirstResult()
        runSelected()
    }
}

/// Custom in-pane tab strip for standard terminal windows. Replaces the
/// native NSWindow tab bar (which spans the whole titlebar and paints across
/// the code-view sidebar). It lives inside the terminal column of the window
/// content, so the sidebar owns its own clean full-height column.
///
/// The strip is a *view* of the native tab group: it renders one button per
/// `NSWindow` in `tabbedWindows` and drives selection through
/// `tabGroup.selectedWindow`. All window/session/split lifecycle stays with
/// AppKit's tab group — only the tab *bar's appearance* is ours.
final class TerminalTabStripView: NSView, NSPopoverDelegate {
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

    static let height: CGFloat = 48
    /// Vertical column layout (side tabs) instead of a horizontal row.
    var vertical = false { didSet { needsLayout = true } }
    private static var accent: NSColor { CodePalette.selectionAccent }

    private var titles: [String] = []
    private var selectedIndex = 0
    private var tabButtons: [NSButton] = []
    private var tabIconViews: [PassthroughImageView] = []
    private var tabTitleLabels: [PassthroughTextField] = []
    private var closeButtons: [NSButton] = []
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let searchButton = NSButton(title: "", target: nil, action: nil)
    private let hairline = NSView()
    private let selectionPill = NSView()
    private var searchPopover: NSPopover?
    private var animateSelectionOnNextLayout = false
    private var selectionAnimationOrigin: Int?
    private var pendingSelectionAnimationTarget: Int?

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

        searchButton.image = NSImage(
            systemSymbolName: "magnifyingglass", accessibilityDescription: "Search Tabs")
        searchButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        searchButton.imagePosition = .imageOnly
        searchButton.isBordered = false
        searchButton.contentTintColor = .secondaryLabelColor
        searchButton.target = self
        searchButton.action = #selector(searchPressed)
        searchButton.toolTip = "Search Tabs"
        addSubview(searchButton)

        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hairline)

        selectionPill.wantsLayer = true
        selectionPill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        selectionPill.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        selectionPill.layer?.borderWidth = 1
        selectionPill.layer?.masksToBounds = true
        selectionPill.isHidden = true
        addSubview(selectionPill)
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
    var tabButtonImagesForTesting: [NSImage?] { tabIconViews.map { $0.image } }
    var addButtonFrameForTesting: NSRect { addButton.frame }
    var searchButtonFrameForTesting: NSRect { searchButton.frame }
    var backgroundAlphaForTesting: CGFloat {
        layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.alphaComponent ?? 0
    }
    var tabButtonCornerRadiiForTesting: [CGFloat] {
        tabButtons.map { $0.layer?.cornerRadius ?? 0 }
    }
    var tabButtonBackgroundAlphasForTesting: [CGFloat] {
        tabButtons.map {
            $0.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.alphaComponent ?? 0
        }
    }
    var selectionPillFrameForTesting: NSRect { selectionPill.frame }
    var selectionPillAlphaForTesting: CGFloat {
        selectionPill.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.alphaComponent ?? 0
    }

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
    func update(
        titles: [String], selectedIndex: Int,
        pins: [Int: Pin] = [:], icons: [Int: NSImage] = [:],
        animateFromIndex: Int? = nil
    ) {
        // Palette actions are positional. Never leave one open across a tab
        // close, reorder, title refresh, or external selection change.
        let selectionChanged = selectedIndex != self.selectedIndex
        if titles != self.titles || selectionChanged {
            searchPopover?.close()
        }
        selectionAnimationOrigin = animateFromIndex
        pendingSelectionAnimationTarget = nil
        animateSelectionOnNextLayout = (selectionChanged || animateFromIndex != nil)
            && !tabButtons.isEmpty
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
                tabIconViews[index].image = NSImage(
                    systemSymbolName: pin.icon, accessibilityDescription: title)
                tabIconViews[index].contentTintColor = .white
                tabTitleLabels[index].isHidden = true
                button.contentTintColor = .white
                button.layer?.backgroundColor = (active
                    ? pin.color.blended(withFraction: 0.18, of: .white) ?? pin.color
                    : pin.color).cgColor
                button.layer?.borderColor = (active
                    ? NSColor.white.withAlphaComponent(0.22)
                    : NSColor.clear).cgColor
                button.layer?.borderWidth = active ? 1 : 0
            } else {
                tabIconViews[index].image = icons[index] ?? Self.defaultTerminalTabIcon
                tabIconViews[index].contentTintColor = active ? .labelColor : .secondaryLabelColor
                button.title = ""
                tabTitleLabels[index].isHidden = false
                tabTitleLabels[index].stringValue = title
                tabTitleLabels[index].font = .systemFont(
                    ofSize: 15, weight: active ? .semibold : .regular)
                tabTitleLabels[index].textColor = active ? .labelColor : .secondaryLabelColor
                button.contentTintColor = active ? .labelColor : .secondaryLabelColor
                button.layer?.backgroundColor = NSColor.clear.cgColor
                button.layer?.borderColor = NSColor.clear.cgColor
                button.layer?.borderWidth = 0
            }
            button.toolTip = title
            closeButtons[index].isHidden = pin != nil || !active || renamingIndex != nil
            closeButtons[index].contentTintColor = active ? .white : .secondaryLabelColor
        }
        if let renamingIndex, tabButtons.indices.contains(renamingIndex) {
            tabButtons[renamingIndex].isHidden = true
            tabIconViews[renamingIndex].isHidden = true
            tabTitleLabels[renamingIndex].isHidden = true
            closeButtons[renamingIndex].isHidden = true
        }
        needsLayout = true
    }

    private func rebuildButtons(count: Int) {
        tabButtons.forEach { $0.removeFromSuperview() }
        tabIconViews.forEach { $0.removeFromSuperview() }
        tabTitleLabels.forEach { $0.removeFromSuperview() }
        closeButtons.forEach { $0.removeFromSuperview() }
        tabButtons = (0..<count).map { index in
            let button = DraggableTabButton(title: "", target: nil, action: nil)
            button.strip = self
            button.tag = index
            button.isBordered = false
            button.alignment = .center
            button.lineBreakMode = .byTruncatingTail
            button.wantsLayer = true
            button.layer?.cornerRadius = 16
            button.layer?.masksToBounds = true
            addSubview(button)
            return button
        }
        tabIconViews = (0..<count).map { _ in
            let icon = PassthroughImageView()
            icon.imageScaling = .scaleProportionallyDown
            addSubview(icon, positioned: .above, relativeTo: nil)
            return icon
        }
        tabTitleLabels = (0..<count).map { _ in
            let label = PassthroughTextField(labelWithString: "")
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            addSubview(label, positioned: .above, relativeTo: nil)
            return label
        }
        closeButtons = (0..<count).map { index in
            let close = NSButton(title: "", target: self, action: #selector(closePressed(_:)))
            close.tag = index
            close.image = NSImage(
                systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
            close.imagePosition = .imageOnly
            close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
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
        // Leave a reference-sized titlebar runway for traffic lights and
        // global controls before the first tab capsule.
        // 134 points keeps the search affordance clear of both native circles
        // and the widest custom traffic-light treatment at narrow widths.
        let leadingInset = min(CGFloat(165), max(CGFloat(134), bounds.width * 0.13))
        let addSize: CGFloat = 28
        if vertical {
            searchButton.isHidden = false
            hairline.frame = NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height)
            addButton.frame = NSRect(
                x: bounds.maxX - addSize - pad, y: bounds.maxY - addSize - pad,
                width: addSize, height: addSize)
            searchButton.frame = NSRect(
                x: pad, y: bounds.maxY - addSize - pad,
                width: addSize, height: addSize)
            guard !tabButtons.isEmpty else { return }
            let rowH: CGFloat = 30
            let controlsBottom = addButton.frame.minY - pad
            for (index, button) in tabButtons.enumerated() {
                let frame = NSRect(
                    x: pad, y: controlsBottom - CGFloat(index + 1) * (rowH + 4) + 4,
                    width: bounds.width - pad * 2, height: rowH)
                button.frame = frame
                button.layer?.cornerRadius = rowH / 2
                let iconSize: CGFloat = pins[index] == nil ? 20 : 16
                tabIconViews[index].frame = NSRect(
                    x: frame.minX + 10, y: frame.midY - iconSize / 2,
                    width: iconSize, height: iconSize)
                tabTitleLabels[index].alignment = .left
                tabTitleLabels[index].frame = NSRect(
                    x: frame.minX + 36, y: frame.midY - 10,
                    width: max(frame.width - 66, 0), height: 20)
                button.alignment = .left
                closeButtons[index].frame = NSRect(
                    x: frame.maxX - 22, y: frame.minY + (rowH - 20) / 2,
                    width: 20, height: 20)
            }
            if let renamingIndex, tabButtons.indices.contains(renamingIndex), let renameEditor {
                renameEditor.frame = tabButtons[renamingIndex].frame.insetBy(dx: 8, dy: 5)
            }
            positionSelectionPill()
            return
        }
        searchButton.isHidden = false
        searchButton.frame = NSRect(
            x: max(leadingInset - 48, 4), y: (bounds.height - 28) / 2,
            width: 28, height: 28)
        hairline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        addButton.frame = NSRect(
            x: bounds.maxX - addSize - pad, y: (bounds.height - addSize) / 2,
            width: addSize, height: addSize)
        guard !tabButtons.isEmpty else { return }
        let available = max(addButton.frame.minX - pad - leadingInset, 1)
        let pinWidth: CGFloat = 34
        let pinnedCount = pins.count
        let unpinnedCount = max(tabButtons.count - pinnedCount, 0)
        let spacingTotal = pad * CGFloat(max(tabButtons.count - 1, 0))
        let remaining = max(
            available - CGFloat(pinnedCount) * pinWidth - spacingTotal, 1)
        let preferredWidths: [CGFloat] = titles.enumerated().map { index, title in
            guard pins[index] == nil else { return pinWidth }
            let textWidth = ceil(title.size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            ]).width)
            return min(230, max(160, textWidth + 92))
        }
        let preferredUnpinnedTotal = preferredWidths.enumerated().reduce(CGFloat(0)) {
            $0 + (pins[$1.offset] == nil ? $1.element : 0)
        }
        let unpinnedScale = unpinnedCount > 0 && preferredUnpinnedTotal > remaining
            ? remaining / preferredUnpinnedTotal : 1
        let tabHeight = min(34, max(bounds.height - 6, 1))
        let tabY = max((bounds.height - tabHeight) / 2 - 2, 0)
        var xPos = leadingInset
        for (index, button) in tabButtons.enumerated() {
            let isPinned = pins[index] != nil
            let width = isPinned ? pinWidth : max(preferredWidths[index] * unpinnedScale, 1)
            button.alignment = isPinned ? .center : .center
            let frame = NSRect(x: xPos, y: tabY, width: width, height: tabHeight)
            button.frame = frame
            button.layer?.cornerRadius = tabHeight / 2
            if isPinned {
                tabIconViews[index].frame = NSRect(
                    x: frame.midX - 9, y: frame.midY - 9, width: 18, height: 18)
            } else {
                tabIconViews[index].frame = NSRect(
                    x: frame.minX + 8, y: frame.midY - 12, width: 34, height: 24)
            }
            tabTitleLabels[index].alignment = .center
            tabTitleLabels[index].frame = NSRect(
                x: frame.minX + 52, y: frame.midY - 11,
                width: max(frame.width - 104, 0), height: 22)
            closeButtons[index].frame = NSRect(
                x: frame.maxX - 30, y: frame.minY, width: 20, height: frame.height)
            xPos += width + pad
        }
        if let renamingIndex, tabButtons.indices.contains(renamingIndex), let renameEditor {
            renameEditor.frame = tabButtons[renamingIndex].frame.insetBy(dx: 8, dy: 5)
        }
        positionSelectionPill()
    }

    private func positionSelectionPill() {
        guard tabButtons.indices.contains(selectedIndex) else {
            selectionPill.isHidden = true
            animateSelectionOnNextLayout = false
            return
        }
        let target = tabButtons[selectedIndex].frame
        if let origin = selectionAnimationOrigin,
           tabButtons.indices.contains(origin), origin != selectedIndex {
            selectionPill.frame = tabButtons[origin].frame
            selectionPill.isHidden = false
            selectionPill.layer?.cornerRadius = target.height / 2
            selectionAnimationOrigin = nil
            animateSelectionOnNextLayout = false
            guard window != nil else {
                selectionPill.frame = target
                return
            }
            let targetIndex = selectedIndex
            pendingSelectionAnimationTarget = targetIndex
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.pendingSelectionAnimationTarget == targetIndex,
                      self.selectedIndex == targetIndex,
                      self.tabButtons.indices.contains(targetIndex)
                else { return }
                self.pendingSelectionAnimationTarget = nil
                let committedTarget = self.tabButtons[targetIndex].frame
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.20
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.selectionPill.animator().frame = committedTarget
                }
            }
            return
        }
        selectionAnimationOrigin = nil
        if pendingSelectionAnimationTarget != nil { return }
        selectionPill.layer?.cornerRadius = target.height / 2
        let shouldAnimate = animateSelectionOnNextLayout
            && !selectionPill.isHidden && window != nil
        selectionPill.isHidden = false
        animateSelectionOnNextLayout = false
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                selectionPill.animator().frame = target
            }
        } else {
            selectionPill.frame = target
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

    @objc private func searchPressed() {
        commitRename()
        if let searchPopover, searchPopover.isShown {
            searchPopover.close()
            return
        }
        let palette = TabCommandPaletteViewController(
            titles: titles, selectedIndex: selectedIndex)
        let popover = NSPopover()
        popover.contentViewController = palette
        popover.contentSize = palette.preferredContentSize
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        palette.onSelect = { [weak self] index in self?.onSelect?(index) }
        palette.onNewTab = { [weak self] in self?.onNewTab?() }
        palette.onDismiss = { [weak popover] in popover?.close() }
        searchPopover = popover
        popover.show(relativeTo: searchButton.bounds, of: searchButton, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        searchPopover = nil
    }

    // MARK: - rename

    @discardableResult
    func beginRename(at index: Int, currentName: String) -> Bool {
        guard renameEditor == nil, tabButtons.indices.contains(index) else { return false }
        layoutSubtreeIfNeeded()
        renamingIndex = index
        tabButtons[index].isHidden = true
        tabIconViews[index].isHidden = true
        tabTitleLabels[index].isHidden = true
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
        if let index, tabButtons.indices.contains(index) {
            tabButtons[index].isHidden = false
            tabIconViews[index].isHidden = false
            tabTitleLabels[index].isHidden = pins[index] != nil
        }
        endingRename = false
        if committing { onRenameCommit?(value) } else { onRenameCancel?() }
    }
}

private extension TerminalTabStripView {
    static let defaultTerminalTabIcon: NSImage? = {
        guard let terminal = NSImage(
            systemSymbolName: "terminal.fill", accessibilityDescription: "Terminal")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        else { return nil }

        func tinted(_ color: NSColor) -> NSImage {
            let image = NSImage(size: terminal.size)
            image.lockFocus()
            terminal.draw(in: NSRect(origin: .zero, size: terminal.size))
            color.setFill()
            NSRect(origin: .zero, size: terminal.size).fill(using: .sourceAtop)
            image.unlockFocus()
            return image
        }

        let image = NSImage(size: NSSize(width: 30, height: 22))
        image.lockFocus()
        let size = NSSize(width: 22, height: 17)
        tinted(NSColor(white: 0.36, alpha: 1)).draw(
            in: NSRect(x: 8, y: 5, width: size.width, height: size.height))
        tinted(NSColor(white: 0.26, alpha: 1)).draw(
            in: NSRect(x: 4, y: 2.5, width: size.width, height: size.height))
        tinted(NSColor(white: 0.16, alpha: 1)).draw(
            in: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        NSColor.systemGreen.setStroke()
        let prompt = NSBezierPath()
        prompt.lineWidth = 1.5
        prompt.lineCapStyle = .round
        prompt.move(to: NSPoint(x: 6, y: 11))
        prompt.line(to: NSPoint(x: 9, y: 8.5))
        prompt.line(to: NSPoint(x: 6, y: 6))
        prompt.move(to: NSPoint(x: 11, y: 6))
        prompt.line(to: NSPoint(x: 15, y: 6))
        prompt.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }()
}

final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    /// Retained for callers that still report group size. Reference chrome
    /// deliberately keeps the strip visible even when this is false.
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

    private let backingBlur = NSVisualEffectView()
    private let backingTint = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        body.wantsLayer = true
        body.autoresizingMask = [.width, .height]
        backingBlur.material = .hudWindow
        backingBlur.blendingMode = .behindWindow
        backingBlur.state = .active
        backingBlur.isHidden = true
        addSubview(backingBlur)
        backingTint.wantsLayer = true
        backingTint.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(backingTint)
        addSubview(body)
        strip.isHidden = false
        addSubview(strip)
    }

    /// Match the terminal's backing so the transparent titlebar region doesn't
    /// show the desktop behind the tabs. With blur, the strip gets a frosted
    /// backing plus a subtle tint; otherwise a solid theme colour.
    func setBacking(color: NSColor, blur: Bool) {
        backingBlur.isHidden = !blur
        layer?.backgroundColor = NSColor.clear.cgColor
        backingTint.layer?.backgroundColor = color.cgColor
        strip.setBackgroundColor(.clear)
        body.layer?.backgroundColor = NSColor.clear.cgColor
    }

    var bodyBackgroundAlphaForTesting: CGFloat {
        body.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.alphaComponent ?? 0
    }
    var backingBackgroundAlphaForTesting: CGFloat {
        backingTint.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.alphaComponent ?? 0
    }
    var blurSurfaceCountForTesting: Int {
        subviews.compactMap { $0 as? NSVisualEffectView }.count
            + body.subviews.compactMap { $0 as? NSVisualEffectView }.count
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        backingBlur.frame = bounds
        backingTint.frame = bounds
        if sideTabs {
            let stripW = min(Self.sideWidth, bounds.width)
            strip.frame = NSRect(x: 0, y: 0, width: stripW, height: bounds.height)
            body.frame = NSRect(
                x: stripW, y: 0, width: bounds.width - stripW, height: bounds.height)
        } else {
            let stripH = min(TerminalTabStripView.height, bounds.height)
            strip.frame = NSRect(
                x: 0, y: bounds.height - stripH, width: bounds.width, height: stripH)
            body.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - stripH)
        }
        let contentBounds = NSRect(
            x: PaneMetrics.horizontalCanvasInset, y: 0,
            width: max(body.bounds.width - PaneMetrics.horizontalCanvasInset * 2, 0),
            height: body.bounds.height)
        for sub in body.subviews { sub.frame = contentBounds }
    }
}
