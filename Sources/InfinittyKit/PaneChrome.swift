import AppKit

enum PaneLog {
    private static let url = URL(fileURLWithPath: "/tmp/infinitty-pane.log")
    private static let queue = DispatchQueue(label: "infinitty.pane-log")

    static func log(_ message: String) {
        let line = "[\(ProcessInfo.processInfo.systemUptime)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func describe(_ view: NSView) -> String {
        if let split = view as? NSSplitView {
            let axis = split.isVertical ? "V" : "H"
            return "\(axis)[\(split.arrangedSubviews.map(describe).joined(separator: ","))]"
        }
        if let terminal = view as? TerminalView {
            return "terminal(\(ObjectIdentifier(terminal)),\(NSStringFromRect(terminal.frame)),"
                + "hidden=\(terminal.isHiddenOrHasHiddenAncestor),alpha=\(terminal.alphaValue))"
        }
        if let utility = view as? UtilityPaneView {
            return "\(utility.kind.title.lowercased())(\(ObjectIdentifier(utility)),"
                + "\(NSStringFromRect(utility.frame)),hidden=\(utility.isHiddenOrHasHiddenAncestor),"
                + "alpha=\(utility.alphaValue))"
        }
        let children = view.subviews.map(describe).joined(separator: ",")
        return children.isEmpty
            ? "view(\(ObjectIdentifier(view)))"
            : "view(\(ObjectIdentifier(view))){\(children)}"
    }
}

enum PaneMetrics {
    static let leadingInset: CGFloat = 8
    static let trailingInset: CGFloat = 8
    static let internalHorizontalInset: CGFloat = 2
    static let topInset: CGFloat = 3
    static let bottomInset: CGFloat = 8
    static let internalVerticalInset: CGFloat = 2
    static let horizontalCanvasInset: CGFloat = 0
    static let cornerRadius: CGFloat = 10
    static let minimumTerminalContentInset: CGFloat = 15

    static func terminalContentInset(configured: CGFloat) -> CGFloat {
        max(configured, minimumTerminalContentInset)
    }
}

/// Pane dividers are geometry handles only. Painting their native black rule
/// breaks the window's one continuous tinted surface.
final class PaneSplitView: NSSplitView {
    override var dividerColor: NSColor { .clear }
}

extension NSView {
    func paneHorizontalInsets() -> (leading: CGFloat, trailing: CGFloat) {
        (
            paneHasHorizontalNeighbor(onRight: false)
                ? PaneMetrics.internalHorizontalInset : PaneMetrics.leadingInset,
            paneHasHorizontalNeighbor(onRight: true)
                ? PaneMetrics.internalHorizontalInset : PaneMetrics.trailingInset
        )
    }

    private func paneHasHorizontalNeighbor(onRight: Bool) -> Bool {
        var branch: NSView = self
        var ancestor = superview
        while let parent = ancestor {
            if let split = parent as? NSSplitView, split.isVertical,
               let index = split.arrangedSubviews.firstIndex(of: branch) {
                if onRight ? index < split.arrangedSubviews.count - 1 : index > 0 {
                    return true
                }
            }
            branch = parent
            ancestor = parent.superview
        }
        return false
    }

    /// Outer window edges keep their larger top/bottom breathing room, while
    /// vertically adjacent tiles contribute only 2pt each to their shared gap.
    func paneVerticalInsets() -> (top: CGFloat, bottom: CGFloat) {
        (
            paneHasVerticalNeighbor(above: true)
                ? PaneMetrics.internalVerticalInset : PaneMetrics.topInset,
            paneHasVerticalNeighbor(above: false)
                ? PaneMetrics.internalVerticalInset : PaneMetrics.bottomInset
        )
    }

    private func paneHasVerticalNeighbor(above: Bool) -> Bool {
        var branch: NSView = self
        var ancestor = superview
        while let parent = ancestor {
            if let split = parent as? NSSplitView, !split.isVertical,
               let index = split.arrangedSubviews.firstIndex(of: branch) {
                // Horizontal NSSplitView order is visual top-to-bottom, even
                // though the split view itself is flipped.
                if above ? index > 0 : index < split.arrangedSubviews.count - 1 {
                    return true
                }
            }
            branch = parent
            ancestor = parent.superview
        }
        return false
    }

    /// Portion covered by a transparent full-size titlebar. Normally zero
    /// below horizontal tabs; nonzero when side tabs extend panes to the top.
    func paneTopObstructionPoints() -> CGFloat {
        guard let window, window.styleMask.contains(.fullSizeContentView) else { return 0 }
        var ancestor = superview
        while let view = ancestor {
            if let chrome = view as? TerminalChromeView, !chrome.sideTabs { return 0 }
            ancestor = view.superview
        }
        let layoutRect = convert(window.contentLayoutRect, from: nil)
        return max(bounds.height - layoutRect.maxY, 0)
    }
}

enum PaneDropZone: CaseIterable, Equatable {
    case left
    case right
    case top
    case bottom
    case center

    static func resolve(point: NSPoint, in bounds: NSRect) -> PaneDropZone {
        guard bounds.width > 0, bounds.height > 0 else { return .center }
        let x = (point.x - bounds.minX) / bounds.width
        let y = (point.y - bounds.minY) / bounds.height
        let edge: CGFloat = 0.25
        if x < edge { return .left }
        if x > 1 - edge { return .right }
        if y < edge { return .bottom }
        if y > 1 - edge { return .top }
        return .center
    }

    func previewFrame(in bounds: NSRect) -> NSRect {
        switch self {
        case .left:
            return NSRect(x: bounds.minX, y: bounds.minY,
                          width: bounds.width / 2, height: bounds.height)
        case .right:
            return NSRect(x: bounds.midX, y: bounds.minY,
                          width: bounds.width / 2, height: bounds.height)
        case .top:
            return NSRect(x: bounds.minX, y: bounds.midY,
                          width: bounds.width, height: bounds.height / 2)
        case .bottom:
            return NSRect(x: bounds.minX, y: bounds.minY,
                          width: bounds.width, height: bounds.height / 2)
        case .center:
            return bounds
        }
    }
}

/// A serializable-in-spirit snapshot of the live AppKit split tree. Runtime
/// layout remains native NSSplitView so divider dragging stays fluid, while
/// tests and drag operations get one stable vocabulary for the topology.
indirect enum PaneLayoutNode: Equatable {
    case leaf(ObjectIdentifier)
    case split(vertical: Bool, children: [PaneLayoutNode])
}

/// A main tab stays open while any terminal or smart-pane leaf remains.
/// Terminal sessions are only one kind of leaf, so using their count here
/// would incorrectly close a Chat, Files, or Browser-only tab.
enum PaneLifecyclePolicy {
    static func shouldCloseTab(remainingPaneCount: Int) -> Bool {
        remainingPaneCount == 0
    }
}

enum PaneLayoutController {
    typealias DividerPositions = [(split: NSSplitView, positions: [CGFloat])]
    typealias DividerRatios = [(split: NSSplitView, ratios: [CGFloat])]

    static func snapshot(of view: NSView) -> PaneLayoutNode? {
        if view is TerminalView || view is UtilityPaneView {
            return .leaf(ObjectIdentifier(view))
        }
        if let split = view as? NSSplitView {
            let children = split.arrangedSubviews.compactMap(snapshot)
            guard !children.isEmpty else { return nil }
            return .split(vertical: split.isVertical, children: children)
        }
        for child in view.subviews {
            if let node = snapshot(of: child) { return node }
        }
        return nil
    }

    @discardableResult
    static func replace(_ old: NSView, with new: NSView, in parent: NSView) -> Bool {
        let oldFrame = old.frame
        let oldAutoresizingMask = old.autoresizingMask
        if let split = parent as? NSSplitView {
            guard let index = split.arrangedSubviews.firstIndex(of: old) else {
                PaneLog.log("ERROR replace missing old=\(ObjectIdentifier(old)) "
                    + "parent=\(ObjectIdentifier(parent))")
                return false
            }
            old.removeFromSuperview()
            new.frame = oldFrame
            // NSSplitView owns arranged-subview geometry. Carrying a root
            // `.width/.height` mask into a nested slot lets AppKit resize the
            // child a second time while a drag is reparenting it.
            new.autoresizingMask = []
            split.insertArrangedSubview(new, at: index)
            PaneLog.log("replace split=\(ObjectIdentifier(split)) index=\(index) "
                + "old=\(ObjectIdentifier(old)) new=\(ObjectIdentifier(new))")
            return true
        }
        guard old.superview === parent else {
            PaneLog.log("ERROR replace parent mismatch old=\(ObjectIdentifier(old)) "
                + "expected=\(ObjectIdentifier(parent))")
            return false
        }
        new.frame = oldFrame
        new.autoresizingMask = oldAutoresizingMask
        parent.replaceSubview(old, with: new)
        PaneLog.log("replace view parent=\(ObjectIdentifier(parent)) "
            + "old=\(ObjectIdentifier(old)) new=\(ObjectIdentifier(new))")
        return true
    }

    /// Move an existing leaf without recreating its session. Edge drops nest
    /// it beside the target; center drops exchange leaf positions.
    static func move(
        source: NSView, target: NSView, zone: PaneDropZone
    ) -> (changed: Bool, insertedSplit: NSSplitView?) {
        guard source !== target, let sourceParent = source.superview,
              let targetParent = target.superview else {
            PaneLog.log("ERROR move invalid endpoints source=\(ObjectIdentifier(source)) "
                + "target=\(ObjectIdentifier(target)) zone=\(zone)")
            return (false, nil)
        }
        PaneLog.log("layout move zone=\(zone) source=\(ObjectIdentifier(source)) "
            + "target=\(ObjectIdentifier(target))")
        if zone == .center {
            let sourcePlaceholder = NSView(frame: source.frame)
            let targetPlaceholder = NSView(frame: target.frame)
            guard replace(source, with: sourcePlaceholder, in: sourceParent),
                  replace(target, with: targetPlaceholder, in: targetParent),
                  let sourceSlot = sourcePlaceholder.superview,
                  let targetSlot = targetPlaceholder.superview,
                  replace(sourcePlaceholder, with: target, in: sourceSlot),
                  replace(targetPlaceholder, with: source, in: targetSlot)
            else {
                PaneLog.log("ERROR center swap failed source=\(ObjectIdentifier(source)) "
                    + "target=\(ObjectIdentifier(target))")
                return (false, nil)
            }
            normalizeArrangedSubviewMasks(around: source)
            return (true, nil)
        }

        guard let sourceSplit = sourceParent as? NSSplitView else {
            PaneLog.log("ERROR edge move source parent is not split "
                + "source=\(ObjectIdentifier(source)) parent=\(ObjectIdentifier(sourceParent))")
            return (false, nil)
        }
        // Reorient a two-pane sibling split in place. Building a nested split,
        // removing the source, then collapsing the old root briefly detaches
        // the only layout node from TerminalChromeView; AppKit can resolve
        // that transient tree to a zero-width, double-height stack.
        if targetParent === sourceSplit, sourceSplit.arrangedSubviews.count == 2 {
            source.removeFromSuperview()
            target.removeFromSuperview()
            sourceSplit.isVertical = zone == .left || zone == .right
            source.autoresizingMask = []
            target.autoresizingMask = []
            if zone == .left || zone == .top {
                sourceSplit.addArrangedSubview(source)
                sourceSplit.addArrangedSubview(target)
            } else {
                sourceSplit.addArrangedSubview(target)
                sourceSplit.addArrangedSubview(source)
            }
            normalizeArrangedSubviewMasks(around: source)
            PaneLog.log("reorient two-pane split=\(ObjectIdentifier(sourceSplit)) "
                + "vertical=\(sourceSplit.isVertical) zone=\(zone)")
            return (true, sourceSplit)
        }
        let split = PaneSplitView(frame: target.frame)
        split.isVertical = zone == .left || zone == .right
        split.dividerStyle = .thin
        split.autoresizingMask = []
        // Replace the target before detaching the source. This is the only
        // fallible topology mutation; once it succeeds, the remaining moves
        // cannot strand a detached pane if the target slot was invalid.
        guard replace(target, with: split, in: targetParent) else { return (false, nil) }
        target.autoresizingMask = []
        split.addArrangedSubview(target)
        source.removeFromSuperview()
        collapseSingleChildSplit(sourceSplit)
        source.autoresizingMask = []
        // Horizontal NSSplitView order is visual top-to-bottom, so a bottom
        // drop appends after the target while a top drop inserts before it.
        if zone == .left || zone == .top {
            split.insertArrangedSubview(source, at: 0)
        } else {
            split.addArrangedSubview(source)
        }
        normalizeArrangedSubviewMasks(around: source)
        return (true, split)
    }

    private static func normalizeArrangedSubviewMasks(around view: NSView) {
        var root = view
        while let parent = root.superview as? NSSplitView { root = parent }
        guard let split = root as? NSSplitView else { return }
        func normalize(_ current: NSSplitView) {
            for child in current.arrangedSubviews {
                child.autoresizingMask = []
                if let nested = child as? NSSplitView { normalize(nested) }
            }
        }
        normalize(split)
    }

    /// Dissolve a one-child split without exposing an empty plain container.
    /// `TerminalChromeView.body` lays out all of its direct children together;
    /// briefly removing its only child can make AppKit retain a zero-sized
    /// layout result through the next display pass. A placeholder preserves
    /// the root slot while the survivor changes parents.
    @discardableResult
    static func collapseSingleChildSplit(_ split: NSSplitView) -> Bool {
        guard split.arrangedSubviews.count == 1,
              let parent = split.superview else { return false }
        let survivor = split.arrangedSubviews[0]
        PaneLog.log("collapse split=\(ObjectIdentifier(split)) "
            + "survivor=\(ObjectIdentifier(survivor)) parent=\(ObjectIdentifier(parent))")

        if parent is NSSplitView {
            survivor.removeFromSuperview()
            if !replace(split, with: survivor, in: parent) {
                PaneLog.log("ERROR collapse replace failed split=\(ObjectIdentifier(split))")
                return false
            }
            return true
        }

        // Keep a layout child in a plain root container at every point in the
        // reparenting sequence. This is especially important for chrome.body.
        let placeholder = NSView(frame: split.frame)
        placeholder.autoresizingMask = split.autoresizingMask
        guard replace(split, with: placeholder, in: parent) else {
            PaneLog.log("ERROR collapse placeholder failed split=\(ObjectIdentifier(split))")
            return false
        }
        survivor.removeFromSuperview()
        if !replace(placeholder, with: survivor, in: parent) {
            PaneLog.log("ERROR collapse survivor failed split=\(ObjectIdentifier(split))")
            return false
        }
        return true
    }

    static func captureDividerPositions(in root: NSView) -> DividerPositions {
        var result: DividerPositions = []
        func collect(_ view: NSView) {
            if let split = view as? NSSplitView {
                let positions = split.arrangedSubviews.dropLast().map {
                    split.isVertical ? $0.frame.maxX : $0.frame.maxY
                }
                result.append((split, positions))
                split.arrangedSubviews.forEach(collect)
            } else {
                view.subviews.forEach(collect)
            }
        }
        collect(root)
        return result
    }

    static func restoreDividerPositions(_ snapshots: DividerPositions) {
        for snapshot in snapshots
        where snapshot.split.superview != nil
            && snapshot.split.arrangedSubviews.count == snapshot.positions.count + 1 {
            for (index, position) in snapshot.positions.enumerated() {
                snapshot.split.setPosition(position, ofDividerAt: index)
            }
        }
    }

    /// Zoom snapshots are ratios rather than pixels so restoring after a
    /// window resize preserves the layout the user had before maximizing.
    static func captureDividerRatios(in root: NSView) -> DividerRatios {
        ratios(for: captureDividerPositions(in: root))
    }

    static func ratios(for snapshots: DividerPositions) -> DividerRatios {
        snapshots.map { snapshot in
            let length = snapshot.split.isVertical
                ? snapshot.split.bounds.width : snapshot.split.bounds.height
            let denominator = max(length, 1)
            return (snapshot.split, snapshot.positions.map { $0 / denominator })
        }
    }

    static func positions(
        for snapshot: (split: NSSplitView, ratios: [CGFloat])
    ) -> [CGFloat] {
        let length = snapshot.split.isVertical
            ? snapshot.split.bounds.width : snapshot.split.bounds.height
        return snapshot.ratios.map { min(max($0, 0), 1) * length }
    }

    static func restoreDividerRatios(_ snapshots: DividerRatios) {
        for snapshot in snapshots where snapshot.split.superview != nil {
            let values = positions(for: snapshot)
            guard snapshot.split.arrangedSubviews.count == values.count + 1 else { continue }
            for (index, position) in values.enumerated() {
                snapshot.split.setPosition(position, ofDividerAt: index)
            }
        }
    }

    static func maximizedDividerPositions(
        length: CGFloat, childCount: Int, selectedIndex: Int,
        collapsedExtent: CGFloat, dividerThickness: CGFloat
    ) -> [CGFloat] {
        guard childCount > 1, (0..<childCount).contains(selectedIndex) else { return [] }
        let dividerTotal = dividerThickness * CGFloat(childCount - 1)
        let available = max(length - dividerTotal, 0)
        let sideExtent = min(
            collapsedExtent,
            available / CGFloat(childCount))
        let selectedExtent = max(available - sideExtent * CGFloat(childCount - 1), 0)
        let extents = (0..<childCount).map {
            $0 == selectedIndex ? selectedExtent : sideExtent
        }
        var positions: [CGFloat] = []
        var cursor: CGFloat = 0
        for index in 0..<(childCount - 1) {
            cursor += extents[index]
            positions.append(cursor)
            cursor += dividerThickness
        }
        return positions
    }
}

private final class PaneSplitButton: NSButton {
    var onRightClick: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

final class PaneHeaderView: NSView {
    static let height: CGFloat = 28

    var onSplitRight: (() -> Void)?
    var onSplitDown: (() -> Void)?
    var onChooseSplitRight: (() -> Void)?
    var onChooseSplitDown: (() -> Void)?
    var onToggleTodos: (() -> Void)?
    var onToggleZoom: (() -> Void)?
    var onFocus: (() -> Void)?
    var onRenameCommit: ((String) -> Void)?
    var onDragBegan: ((NSPoint) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint, Bool) -> Void)?
    /// When set, hovering the pane icon turns it into a close button.
    var onClose: (() -> Void)? {
        didSet { iconView.toolTip = onClose == nil ? nil : "Close Pane" }
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let splitRightButton = PaneSplitButton()
    private let splitDownButton = PaneSplitButton()
    private let todoButton = PaneSplitButton()
    private var todoTotal = 0
    private let bottomHairline = NSView()
    private var closeHoverActive = false
    private var iconTrackingArea: NSTrackingArea?
    private weak var renameEditor: TabRenameTextView?

    var iconSymbol: String = "terminal" {
        didSet { updateIcon() }
    }

    var title: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            setAccessibilityLabel("Terminal pane: \(newValue)")
            needsLayout = true
        }
    }

    var splitRightAccessibilityLabelForTesting: String {
        splitRightButton.accessibilityLabel() ?? ""
    }
    var splitDownAccessibilityLabelForTesting: String {
        splitDownButton.accessibilityLabel() ?? ""
    }
    var iconFrameForTesting: NSRect { iconView.frame }
    var titleFrameForTesting: NSRect { titleLabel.frame }
    var splitRightFrameForTesting: NSRect { splitRightButton.frame }
    var splitDownFrameForTesting: NSRect { splitDownButton.frame }
    var isRenamingForTesting: Bool { renameEditor != nil }
    var todoButtonIsVisibleForTesting: Bool { !todoButton.isHidden }
    var todoTooltipForTesting: String { todoButton.toolTip ?? "" }

    /// Anchor for the todo popover.
    var todoAnchorView: NSView { todoButton }

    /// Show/hide the checklist icon and reflect progress in its tooltip and
    /// tint (accent while work remains, green when everything is done).
    func setTodoProgress(total: Int, done: Int) {
        todoTotal = total
        todoButton.isHidden = total == 0
        guard total > 0 else { return }
        todoButton.toolTip = "Agent todos: \(done)/\(total) done"
        todoButton.setAccessibilityLabel("Agent todo list, \(done) of \(total) done")
        todoButton.contentTintColor = done == total
            ? NSColor.systemGreen.withAlphaComponent(0.8)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.85)
        needsLayout = true
    }

    @objc private func todoPressed(_ sender: Any?) {
        onToggleTodos?()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        updateIcon()
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        iconView.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.72)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.92)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        configure(
            splitRightButton, symbol: "rectangle.split.2x1",
            label: "Split pane right", action: #selector(splitRightPressed))
        splitRightButton.onRightClick = { [weak self] in self?.onChooseSplitRight?() }
        configure(
            splitDownButton, symbol: "rectangle.split.1x2",
            label: "Split pane down", action: #selector(splitDownPressed))
        splitDownButton.onRightClick = { [weak self] in self?.onChooseSplitDown?() }
        configure(
            todoButton, symbol: "checklist",
            label: "Agent todo list", action: #selector(todoPressed))
        todoButton.isHidden = true

        bottomHairline.wantsLayer = true
        bottomHairline.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(bottomHairline)

        setAccessibilityRole(.group)
        setAccessibilityLabel("Terminal pane")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateIcon() {
        guard !closeHoverActive else { return }
        iconView.image = NSImage(
            systemSymbolName: iconSymbol, accessibilityDescription: titleLabel.stringValue)
    }

    /// Slightly padded hit region so the close affordance is easy to target.
    private var iconHoverRect: NSRect { iconView.frame.insetBy(dx: -3, dy: -3) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let iconTrackingArea { removeTrackingArea(iconTrackingArea) }
        let area = NSTrackingArea(
            rect: iconHoverRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        iconTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard onClose != nil, !closeHoverActive else { return }
        closeHoverActive = true
        iconView.image = NSImage(
            systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close pane")
        iconView.contentTintColor = NSColor.systemRed.withAlphaComponent(0.85)
    }

    override func mouseExited(with event: NSEvent) {
        guard closeHoverActive else { return }
        closeHoverActive = false
        iconView.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.72)
        updateIcon()
    }

    var closeHoverActiveForTesting: Bool { closeHoverActive }
    func simulateIconHoverForTesting(_ inside: Bool) {
        let event = NSEvent.enterExitEvent(
            with: inside ? .mouseEntered : .mouseExited,
            location: NSPoint(x: iconHoverRect.midX, y: iconHoverRect.midY),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil)
        guard let event else { return }
        inside ? mouseEntered(with: event) : mouseExited(with: event)
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.62)
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        addSubview(button)
    }

    override func layout() {
        super.layout()
        let buttonSize: CGFloat = 26
        splitDownButton.frame = NSRect(
            x: bounds.maxX - buttonSize - 8, y: 1, width: buttonSize, height: buttonSize)
        splitRightButton.frame = NSRect(
            x: splitDownButton.frame.minX - buttonSize, y: 1,
            width: buttonSize, height: buttonSize)
        todoButton.frame = NSRect(
            x: splitRightButton.frame.minX - (todoButton.isHidden ? 0 : buttonSize), y: 1,
            width: buttonSize, height: buttonSize)
        iconView.frame = NSRect(x: 10, y: 6, width: 16, height: 16)
        let titleLimit = todoButton.isHidden
            ? splitRightButton.frame.minX : todoButton.frame.minX
        titleLabel.frame = NSRect(
            x: 32, y: 1,
            width: max(titleLimit - 39, 0), height: 20)
        if let renameEditor {
            renameEditor.frame = renameFrame
        }
        bottomHairline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    private var renameFrame: NSRect {
        let name = renameEditor?.string ?? title
        let textWidth = ceil(name.size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
        ]).width)
        let width = min(titleLabel.frame.width, max(96, textWidth + 28))
        return NSRect(
            x: titleLabel.frame.minX - 4, y: 3,
            width: width, height: 22)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if closeHoverActive, let onClose,
           iconHoverRect.contains(convert(event.locationInWindow, from: nil)) {
            onClose()
            return
        }
        onFocus?()
        if event.clickCount >= 2 {
            let point = convert(event.locationInWindow, from: nil)
            if titleLabel.frame.insetBy(dx: -5, dy: -4).contains(point) {
                beginRename()
                return
            }
            onToggleZoom?()
            return
        }
        guard let window else { return }
        let start = event.locationInWindow
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            switch next.type {
            case .leftMouseDragged:
                guard window.isKeyWindow else {
                    if dragging { onDragEnded?(next.locationInWindow, true) }
                    return
                }
                let point = next.locationInWindow
                if !dragging, hypot(point.x - start.x, point.y - start.y) > 4 {
                    dragging = true
                    onDragBegan?(point)
                }
                if dragging { onDragMoved?(point) }
            case .leftMouseUp:
                if dragging { onDragEnded?(next.locationInWindow, !window.isKeyWindow) }
                return
            case .keyDown where next.keyCode == 53: // Escape
                if dragging { onDragEnded?(next.locationInWindow, true) }
                return
            default:
                break
            }
        }
        if dragging { onDragEnded?(start, true) }
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(panelContextMenu(), with: event, for: self)
    }

    private func panelContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Panel")
        let rename = menu.addItem(
            withTitle: "Rename Panel…", action: #selector(renamePanel(_:)),
            keyEquivalent: "")
        rename.target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "New Chat",
            action: #selector(AppDelegate.newChatPane(_:)), keyEquivalent: "")
        menu.addItem(
            withTitle: "Browser",
            action: #selector(AppDelegate.openBrowserPane(_:)), keyEquivalent: "")
        menu.addItem(
            withTitle: "Files",
            action: #selector(AppDelegate.openFilesPane(_:)), keyEquivalent: "")
        return menu
    }

    var contextMenuTitlesForTesting: [String] {
        panelContextMenu().items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    @objc private func renamePanel(_ sender: Any?) {
        beginRename()
    }

    func beginRename() {
        guard renameEditor == nil else { return }
        onFocus?()
        layoutSubtreeIfNeeded()
        let editor = TabRenameTextView(frame: renameFrame)
        editor.string = title
        editor.font = .monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.textContainerInset = NSSize(width: 5, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.maximumNumberOfLines = 1
        editor.textContainer?.lineBreakMode = .byClipping
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 4
        editor.layer?.borderWidth = 1
        editor.layer?.borderColor = CodePalette.selectionAccent.cgColor
        editor.layer?.backgroundColor = NSColor.controlBackgroundColor
            .withAlphaComponent(0.96).cgColor
        editor.onCommit = { [weak self] in self?.finishRename(committing: true) }
        editor.onCancel = { [weak self] in self?.finishRename(committing: false) }
        titleLabel.isHidden = true
        addSubview(editor, positioned: .above, relativeTo: nil)
        renameEditor = editor
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(
            NSRange(location: 0, length: (editor.string as NSString).length))
    }

    private func finishRename(committing: Bool) {
        guard let editor = renameEditor else { return }
        let value = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        renameEditor = nil
        editor.onCommit = nil
        editor.onCancel = nil
        editor.removeFromSuperview()
        titleLabel.isHidden = false
        if committing, !value.isEmpty {
            title = value
            onRenameCommit?(value)
        }
        onFocus?()
    }

    @objc private func splitRightPressed() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            onChooseSplitRight?()
        } else {
            onSplitRight?()
        }
    }

    @objc private func splitDownPressed() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            onChooseSplitDown?()
        } else {
            onSplitDown?()
        }
    }

}

final class PaneDropPreviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
        layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.95).cgColor
        layer?.borderWidth = 1.5
        layer?.cornerRadius = PaneMetrics.cornerRadius
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PaneOutlineView: NSView {
    var accentColor = CodePalette.paneFocusAccent {
        didSet { updateAppearance(animated: window != nil) }
    }
    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            updateAppearance(animated: window != nil)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = PaneMetrics.cornerRadius
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateAppearance(animated: Bool) {
        let oldBackground = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
        let oldBorder = layer?.presentation()?.borderColor ?? layer?.borderColor
        let background = accentColor.withAlphaComponent(
            isSelected ? 0.09 : 0.045).cgColor
        let border = (isSelected
            ? accentColor.withAlphaComponent(0.68)
            : accentColor.withAlphaComponent(0.30)).cgColor
        layer?.backgroundColor = background
        layer?.borderColor = border
        layer?.borderWidth = isSelected ? 1.5 : 1
        guard animated else { return }
        for (keyPath, from, to) in [
            ("backgroundColor", oldBackground, background),
            ("borderColor", oldBorder, border),
        ] {
            let transition = CABasicAnimation(keyPath: keyPath)
            transition.fromValue = from
            transition.toValue = to
            transition.duration = 0.18
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(transition, forKey: "pane-\(keyPath)")
        }
    }

    var backgroundAlphaForTesting: CGFloat {
        layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.alphaComponent ?? 0
    }
    var accentColorForTesting: NSColor { accentColor }
}

final class PaneDragBadgeView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 7
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.32
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.frame = NSRect(x: 7, y: 6, width: 12, height: 12)
        addSubview(icon)

        label.stringValue = title
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 24, y: 4, width: 88, height: 16)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
