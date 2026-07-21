import AppKit

enum PaneType: Int, CaseIterable {
    case terminal
    case files
    case chat

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .files: return "Files"
        case .chat: return "Chat"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .files: return "folder"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }
}

enum UtilityPanelKind: String, CaseIterable {
    case files
    case chat

    var title: String {
        switch self {
        case .files: return "Files"
        case .chat: return "Chat"
        }
    }

    var symbol: String {
        switch self {
        case .files: return "folder"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }

}

/// A non-terminal leaf in the same NSSplitView tree as terminal panes. It uses
/// the shared pane header and inset treatment, so Files, Changes, and Chat can
/// be dragged, swapped, split around, and mixed with live shells.
final class UtilityPaneView: NSView {
    let kind: UtilityPanelKind
    let contentView: NSView
    let paneHeader = PaneHeaderView()
    private let paneOutline = PaneOutlineView()
    private let closeButton = NSButton()
    private lazy var focusClickRecognizer: NSClickGestureRecognizer = {
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(focusedWithinPane))
        recognizer.delaysPrimaryMouseButtonEvents = false
        return recognizer
    }()

    var onSplitRight: (() -> Void)? { didSet { paneHeader.onSplitRight = onSplitRight } }
    var onSplitDown: (() -> Void)? { didSet { paneHeader.onSplitDown = onSplitDown } }
    var onClose: (() -> Void)?
    var onFocus: (() -> Void)?
    var onDragBegan: ((NSPoint) -> Void)? { didSet { paneHeader.onDragBegan = onDragBegan } }
    var onDragMoved: ((NSPoint) -> Void)? { didSet { paneHeader.onDragMoved = onDragMoved } }
    var onDragEnded: ((NSPoint, Bool) -> Void)? { didSet { paneHeader.onDragEnded = onDragEnded } }

    init(
        kind: UtilityPanelKind, contentView: NSView,
        background: NSColor, blurred: Bool = false
    ) {
        self.kind = kind
        self.contentView = contentView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        updateSurface(background: background, blurred: blurred)

        paneHeader.title = kind.title
        paneHeader.iconSymbol = kind.symbol
        paneHeader.onFocus = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
        addSubview(paneOutline)
        addSubview(contentView)
        addSubview(paneHeader, positioned: .above, relativeTo: contentView)

        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: "Close panel")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.toolTip = "Close \(kind.title) panel"
        closeButton.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
        paneHeader.addSubview(closeButton)
        closeButton.autoresizingMask = [.minXMargin]
        addGestureRecognizer(focusClickRecognizer)

        setAccessibilityRole(.group)
        setAccessibilityLabel("\(kind.title) panel")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return true
    }

    func setPaneSelected(_ selected: Bool) {
        paneOutline.isSelected = selected
    }

    func updateSurface(background: NSColor, blurred: Bool) {
        layer?.backgroundColor = background.withAlphaComponent(blurred ? 0.30 : 1).cgColor
    }

    override func layout() {
        super.layout()
        let inset = PaneMetrics.inset
        let obstruction = paneTopObstructionPoints()
        paneOutline.frame = bounds.insetBy(dx: inset, dy: inset)
        paneHeader.frame = NSRect(
            x: inset,
            y: max(bounds.height - obstruction - PaneHeaderView.height - inset, inset),
            width: max(bounds.width - inset * 2, 0), height: PaneHeaderView.height)
        contentView.frame = NSRect(
            x: inset, y: inset,
            width: max(bounds.width - inset * 2, 0),
            height: max(bounds.height - obstruction - PaneHeaderView.height - inset * 3, 0))
        closeButton.frame.origin = NSPoint(x: max(paneHeader.bounds.width - 98, 0), y: 2)
    }

    @objc private func closePressed() { onClose?() }
    @objc private func focusedWithinPane() { onFocus?() }
}
