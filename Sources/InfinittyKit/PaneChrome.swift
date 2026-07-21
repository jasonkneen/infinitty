import AppKit

enum PaneMetrics {
    static let inset: CGFloat = 5
    static let cornerRadius: CGFloat = 10
    static let minimumTerminalContentInset: CGFloat = 15

    static func terminalContentInset(configured: CGFloat) -> CGFloat {
        max(configured, minimumTerminalContentInset)
    }
}

extension NSView {
    /// Portion covered by a transparent full-size titlebar. Normally zero
    /// below horizontal tabs; nonzero when side tabs extend panes to the top.
    func paneTopObstructionPoints() -> CGFloat {
        guard let window, window.styleMask.contains(.fullSizeContentView) else { return 0 }
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

enum PaneLayoutController {
    typealias DividerPositions = [(split: NSSplitView, positions: [CGFloat])]

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
            guard let index = split.arrangedSubviews.firstIndex(of: old) else { return false }
            old.removeFromSuperview()
            new.frame = oldFrame
            new.autoresizingMask = oldAutoresizingMask
            split.insertArrangedSubview(new, at: index)
            return true
        }
        guard old.superview === parent else { return false }
        new.frame = oldFrame
        new.autoresizingMask = oldAutoresizingMask
        parent.replaceSubview(old, with: new)
        return true
    }

    /// Move an existing leaf without recreating its session. Edge drops nest
    /// it beside the target; center drops exchange leaf positions.
    static func move(
        source: NSView, target: NSView, zone: PaneDropZone
    ) -> (changed: Bool, insertedSplit: NSSplitView?) {
        guard source !== target, let sourceParent = source.superview,
              let targetParent = target.superview else { return (false, nil) }
        if zone == .center {
            let sourcePlaceholder = NSView(frame: source.frame)
            let targetPlaceholder = NSView(frame: target.frame)
            guard replace(source, with: sourcePlaceholder, in: sourceParent),
                  replace(target, with: targetPlaceholder, in: targetParent),
                  let sourceSlot = sourcePlaceholder.superview,
                  let targetSlot = targetPlaceholder.superview,
                  replace(sourcePlaceholder, with: target, in: sourceSlot),
                  replace(targetPlaceholder, with: source, in: targetSlot)
            else { return (false, nil) }
            return (true, nil)
        }

        guard let sourceSplit = sourceParent as? NSSplitView else { return (false, nil) }
        let split = NSSplitView(frame: target.frame)
        split.isVertical = zone == .left || zone == .right
        split.dividerStyle = .thin
        split.autoresizingMask = target.autoresizingMask
        // Replace the target before detaching the source. This is the only
        // fallible topology mutation; once it succeeds, the remaining moves
        // cannot strand a detached pane if the target slot was invalid.
        guard replace(target, with: split, in: targetParent) else { return (false, nil) }
        split.addArrangedSubview(target)
        source.removeFromSuperview()
        collapseSingleChildSplit(sourceSplit)
        if zone == .left || zone == .bottom {
            split.insertArrangedSubview(source, at: 0)
        } else {
            split.addArrangedSubview(source)
        }
        return (true, split)
    }

    private static func collapseSingleChildSplit(_ split: NSSplitView) {
        guard split.arrangedSubviews.count == 1,
              let parent = split.superview else { return }
        let survivor = split.arrangedSubviews[0]
        survivor.removeFromSuperview()
        _ = replace(split, with: survivor, in: parent)
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
}

final class PaneHeaderView: NSView {
    static let height: CGFloat = 34

    var onSplitRight: (() -> Void)?
    var onSplitDown: (() -> Void)?
    var onToggleZoom: (() -> Void)?
    var onFocus: (() -> Void)?
    var onDragBegan: ((NSPoint) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint, Bool) -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let splitRightButton = NSButton()
    private let splitDownButton = NSButton()
    private let bottomHairline = NSView()

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor

        updateIcon()
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        iconView.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.9)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.92)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        configure(
            splitRightButton, symbol: "rectangle.split.2x1",
            label: "Split pane right", action: #selector(splitRightPressed))
        configure(
            splitDownButton, symbol: "rectangle.split.1x2",
            label: "Split pane down", action: #selector(splitDownPressed))

        bottomHairline.wantsLayer = true
        bottomHairline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
        addSubview(bottomHairline)

        setAccessibilityRole(.group)
        setAccessibilityLabel("Terminal pane")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateIcon() {
        iconView.image = NSImage(
            systemSymbolName: iconSymbol, accessibilityDescription: titleLabel.stringValue)
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.8)
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        addSubview(button)
    }

    override func layout() {
        super.layout()
        let buttonSize: CGFloat = 30
        splitDownButton.frame = NSRect(
            x: bounds.maxX - buttonSize - 8, y: 2, width: buttonSize, height: buttonSize)
        splitRightButton.frame = NSRect(
            x: splitDownButton.frame.minX - buttonSize, y: 1,
            width: buttonSize, height: buttonSize)
        iconView.frame = NSRect(x: 14, y: 7, width: 20, height: 20)
        titleLabel.frame = NSRect(
            x: 47, y: 6,
            width: max(splitRightButton.frame.minX - 54, 0), height: 22)
        bottomHairline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        if event.clickCount >= 2 {
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

    @objc private func splitRightPressed() { onSplitRight?() }
    @objc private func splitDownPressed() { onSplitDown?() }
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
    var isSelected = false {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = PaneMetrics.cornerRadius
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateAppearance() {
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.026).cgColor
        layer?.borderColor = (isSelected
            ? NSColor.systemBlue.withAlphaComponent(0.62)
            : NSColor.white.withAlphaComponent(0.12)).cgColor
        layer?.borderWidth = isSelected ? 1.5 : 1
    }
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
