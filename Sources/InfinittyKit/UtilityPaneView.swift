import AppKit

enum PaneType: Int, CaseIterable {
    case terminal
    case files
    case chat
    case browser

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .files: return "Files"
        case .chat: return "Chat"
        case .browser: return "Browser"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .files: return "folder"
        case .chat: return "bubble.left.and.bubble.right"
        case .browser: return "globe"
        }
    }
}

enum UtilityPanelKind: String, CaseIterable {
    case files
    case chat
    case browser
    /// Agent-requested display surface (markdown doc, MCP-UI HTML, or URL).
    case surface

    var title: String {
        switch self {
        case .files: return "Files"
        case .chat: return "Chat"
        case .browser: return "Browser"
        case .surface: return "Surface"
        }
    }

    var symbol: String {
        switch self {
        case .files: return "folder"
        case .chat: return "bubble.left.and.bubble.right"
        case .browser: return "globe"
        case .surface: return "sparkles.rectangle.stack"
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
    private let newChatButton = NSButton()
    private lazy var focusClickRecognizer: NSClickGestureRecognizer = {
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(focusedWithinPane))
        recognizer.delaysPrimaryMouseButtonEvents = false
        return recognizer
    }()

    var onSplitRight: (() -> Void)? { didSet { paneHeader.onSplitRight = onSplitRight } }
    var onSplitDown: (() -> Void)? { didSet { paneHeader.onSplitDown = onSplitDown } }
    var onChooseSplitRight: (() -> Void)? {
        didSet { paneHeader.onChooseSplitRight = onChooseSplitRight }
    }
    var onChooseSplitDown: (() -> Void)? {
        didSet { paneHeader.onChooseSplitDown = onChooseSplitDown }
    }
    var onClose: (() -> Void)? { didSet { paneHeader.onClose = onClose } }
    var onNewChat: (() -> Void)?
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
        addSubview(contentView)
        // Content may be layer-backed, so the focus border must sit above it
        // or the visible outline stops at the bottom of the pane header.
        addSubview(paneOutline, positioned: .above, relativeTo: contentView)
        addSubview(paneHeader, positioned: .above, relativeTo: paneOutline)

        if kind == .chat {
            newChatButton.image = NSImage(
                systemSymbolName: "plus", accessibilityDescription: "New chat")
            newChatButton.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: 13, weight: .medium)
            newChatButton.imagePosition = .imageOnly
            newChatButton.isBordered = false
            newChatButton.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.72)
            newChatButton.target = self
            newChatButton.action = #selector(newChatPressed)
            newChatButton.toolTip = "New chat"
            paneHeader.addSubview(newChatButton)
            newChatButton.autoresizingMask = [.minXMargin]
        }
        // A recognizer attached to a parent sees events aimed at every
        // descendant. On a Browser pane that includes the address toolbar and
        // the WKWebView, so it can steal a gear/cursor click before AppKit or
        // WebKit handles it. Browser controls manage their own first-responder
        // state; keep this focus helper only on the inert Files/Chat surfaces.
        if kind != .browser { addGestureRecognizer(focusClickRecognizer) }

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

    func setPaneAccent(_ color: NSColor) {
        paneOutline.accentColor = color
    }

    var paneAccentColorForTesting: NSColor { paneOutline.accentColor }

    func updateSurface(background: NSColor, blurred: Bool) {
        // The standard window owns one edge-to-edge themed surface. Utility
        // content stays clear so pane interiors and gutters cannot
        // double-composite into visibly different colors.
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    var surfaceAlphaForTesting: CGFloat {
        layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.alphaComponent ?? 0
    }

    var outlineIsAboveContentForTesting: Bool {
        guard let outlineIndex = subviews.firstIndex(of: paneOutline),
              let contentIndex = subviews.firstIndex(of: contentView) else { return false }
        return outlineIndex > contentIndex
    }

    override func layout() {
        super.layout()
        let horizontalInsets = paneHorizontalInsets()
        let leading = horizontalInsets.leading
        let trailing = horizontalInsets.trailing
        let verticalInsets = paneVerticalInsets()
        let top = verticalInsets.top
        let bottom = verticalInsets.bottom
        let obstruction = paneTopObstructionPoints()
        paneOutline.frame = NSRect(
            x: leading, y: bottom,
            width: max(bounds.width - leading - trailing, 0),
            height: max(bounds.height - top - bottom, 0))
        let headerY = max(
            bounds.height - obstruction - PaneHeaderView.height - top, bottom)
        paneHeader.frame = NSRect(
            x: leading, y: headerY,
            width: max(bounds.width - leading - trailing, 0), height: PaneHeaderView.height)
        contentView.frame = NSRect(
            x: leading, y: bottom,
            width: max(bounds.width - leading - trailing, 0),
            height: max(headerY - top - bottom, 0))
        newChatButton.frame = NSRect(
            x: 70, y: 2, width: 30, height: 30)
    }

    @objc private func newChatPressed() { onNewChat?() }
    @objc private func focusedWithinPane() { onFocus?() }

    var showsNewChatInHeaderForTesting: Bool {
        kind == .chat && newChatButton.superview === paneHeader
    }
}
