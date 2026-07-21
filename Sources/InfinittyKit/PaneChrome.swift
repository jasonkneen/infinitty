import AppKit

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
    static func snapshot(of view: NSView) -> PaneLayoutNode? {
        if let terminal = view as? TerminalView {
            return .leaf(ObjectIdentifier(terminal))
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
}

final class PaneHeaderView: NSView {
    static let height: CGFloat = 24

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

        iconView.image = NSImage(
            systemSymbolName: "terminal", accessibilityDescription: "Terminal")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        iconView.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.9)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
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

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
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
        let buttonSize: CGFloat = 22
        splitDownButton.frame = NSRect(
            x: bounds.maxX - buttonSize - 2, y: 1, width: buttonSize, height: buttonSize)
        splitRightButton.frame = NSRect(
            x: splitDownButton.frame.minX - buttonSize, y: 1,
            width: buttonSize, height: buttonSize)
        iconView.frame = NSRect(x: 7, y: 6, width: 12, height: 12)
        titleLabel.frame = NSRect(
            x: 23, y: 4,
            width: max(splitRightButton.frame.minX - 29, 0), height: 16)
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
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch next.type {
            case .leftMouseDragged:
                let point = next.locationInWindow
                if !dragging, hypot(point.x - start.x, point.y - start.y) > 4 {
                    dragging = true
                    onDragBegan?(point)
                }
                if dragging { onDragMoved?(point) }
            case .leftMouseUp:
                if dragging { onDragEnded?(next.locationInWindow, false) }
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
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

