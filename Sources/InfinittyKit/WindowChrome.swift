import AppKit

/// Subtle "update available" chip, tucked into the top-right corner. Compact,
/// centered, lightly rounded. Click to open the update prompt.
final class UpdateIndicatorView: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var hovering = false
    private let accent = NSColor(srgbRed: 0.40, green: 0.78, blue: 0.60, alpha: 1)
    private let h: CGFloat = 15

    init(version: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4                 // less rounded than a capsule
        layer?.masksToBounds = true

        label.stringValue = "↑ \(version)"
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.alignment = .center               // centered text
        label.isEditable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.textColor = accent
        addSubview(label)

        // Snug width: just the text plus a little side padding.
        let textW = ceil(label.attributedStringValue.size().width)
        setFrameSize(NSSize(width: textW + 12, height: h))
        label.frame = bounds
        label.autoresizingMask = [.width, .height]
        applyStyle()
        toolTip = "Update available — click to install"
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyStyle() {
        layer?.backgroundColor = accent.withAlphaComponent(hovering ? 0.24 : 0.14).cgColor
        label.textColor = accent.withAlphaComponent(hovering ? 1.0 : 0.85)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyStyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyStyle() }
    override func mouseDown(with event: NSEvent) { onClick?() }

    /// Pin to the top-right corner, tight under the titlebar inset.
    func place(in host: NSView, topInset: CGFloat) {
        frame.origin = NSPoint(
            x: host.bounds.width - frame.width - 8,
            y: host.bounds.height - h - max(topInset, 4) - 3
        )
        autoresizingMask = [.minXMargin, .minYMargin]
    }
}

/// Sidebar collapse/expand toggle in the top-right corner. Collapses the
/// code-view sidebar to a minimal width and expands it back.
final class SidebarCollapseView: NSView {
    var onClick: (() -> Void)?
    private let icon = NSTextField(labelWithString: "")
    private var hovering = false
    private let accent = NSColor.controlAccentColor
    private let size: CGFloat = 28
    private var isCollapsed = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        icon.stringValue = "⊟"
        icon.font = .systemFont(ofSize: 13, weight: .semibold)
        icon.alignment = .center
        icon.isEditable = false
        icon.isBezeled = false
        icon.drawsBackground = false
        addSubview(icon)

        setFrameSize(NSSize(width: size, height: size))
        icon.frame = bounds
        icon.autoresizingMask = [.width, .height]
        applyStyle()
        updateTooltip()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyStyle() {
        layer?.backgroundColor = accent.withAlphaComponent(hovering ? 0.16 : 0.08).cgColor
        icon.textColor = accent.withAlphaComponent(hovering ? 1.0 : 0.75)
    }

    private func updateTooltip() {
        toolTip = isCollapsed ? "Show sidebar" : "Hide sidebar"
    }

    func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        updateTooltip()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyStyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyStyle() }
    override func mouseDown(with event: NSEvent) { onClick?() }

    /// Pin to the top-right corner, tight under the titlebar inset.
    func place(in host: NSView, topInset: CGFloat) {
        frame.origin = NSPoint(
            x: host.bounds.width - frame.width - 8,
            y: host.bounds.height - size - max(topInset, 4) - 3
        )
        autoresizingMask = [.minXMargin, .minYMargin]
    }
}

/// Pulsing inner glow shown while an agent drives the pane through the
/// control socket — an Apple-Intelligence-style rotating conic gradient ring.
final class AgentGlowView: NSView {
    private let container = CALayer()
    private let gradient = CAGradientLayer()
    private let ringMask = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = [
            NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1).cgColor, // blue
            NSColor(srgbRed: 0.75, green: 0.35, blue: 0.95, alpha: 1).cgColor, // purple
            NSColor(srgbRed: 1.00, green: 0.22, blue: 0.37, alpha: 1).cgColor, // pink
            NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1).cgColor, // orange
            NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1).cgColor, // back to blue
        ]

        ringMask.fillColor = nil
        ringMask.strokeColor = NSColor.white.cgColor
        ringMask.lineWidth = 6

        container.mask = ringMask
        container.addSublayer(gradient)
        layer?.addSublayer(container)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // never eat clicks

    override func layout() {
        super.layout()
        container.frame = bounds
        ringMask.frame = container.bounds
        ringMask.path = CGPath(
            roundedRect: bounds.insetBy(dx: 2, dy: 2),
            cornerWidth: 9, cornerHeight: 9, transform: nil
        )
        // The gradient is an oversized centered square so rotating it never
        // exposes corners.
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func startPulse() {
        isHidden = false
        if gradient.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = 4
            spin.repeatCount = .infinity
            gradient.add(spin, forKey: "spin")
        }
        if container.animation(forKey: "pulse") == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.45
            pulse.toValue = 1.0
            pulse.duration = 1.1
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            container.add(pulse, forKey: "pulse")
        }
    }

    func stopPulse() {
        gradient.removeAnimation(forKey: "spin")
        container.removeAnimation(forKey: "pulse")
        isHidden = true
    }
}

/// A brief, non-interactive border flash used to make keyboard pane focus
/// changes immediately visible without leaving permanent chrome on the grid.
final class PaneFocusHighlightView: NSView {
    private(set) var isPersistentlyVisible = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 7
        layer?.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setPersistentlyVisible(_ visible: Bool) {
        isPersistentlyVisible = visible
        layer?.removeAnimation(forKey: "focusFlash")
        layer?.opacity = visible ? 1 : 0
    }

    func flash() {
        guard let layer else { return }
        guard !isPersistentlyVisible else {
            layer.opacity = 1
            return
        }
        layer.removeAnimation(forKey: "focusFlash")
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 1, 1, 0]
        animation.keyTimes = [0, 0.08, 0.28, 1]
        animation.duration = 0.38
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeIn),
        ]
        layer.add(animation, forKey: "focusFlash")
    }
}

/// Number badge shown while Option is held so direct pane shortcuts are
/// discoverable without permanently consuming terminal space.
final class PaneShortcutHintView: NSView {
    private let label = NSTextField(labelWithString: "")
    var shortcutText: String { label.stringValue }

    init(number: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 9
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 8
        layer?.shadowOffset = .zero

        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        addSubview(label)
        setNumber(number)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setNumber(_ number: Int) {
        label.stringValue = "⇧⌥\(number)"
        label.sizeToFit()
        label.frame.origin = NSPoint(
            x: floor((bounds.width - label.frame.width) / 2),
            y: floor((bounds.height - label.frame.height) / 2))
    }
}

/// Custom traffic-light buttons (square / rectangle / diamond). Replaces the
/// hidden native buttons; clicks map to close / miniaturize / zoom.
final class TrafficLightsView: NSView {
    enum Shape: String {
        case square, rectangle, diamond
    }

    private let shape: Shape
    private static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.74, blue: 0.18, alpha: 1),
        NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1),
    ]

    private var itemSize: NSSize {
        shape == .rectangle ? NSSize(width: 17, height: 10) : NSSize(width: 12, height: 12)
    }

    private let spacing: CGFloat = 8

    init(shape: Shape) {
        self.shape = shape
        super.init(frame: .zero)
        let size = itemSize
        setFrameSize(NSSize(width: size.width * 3 + spacing * 2, height: size.height))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func itemRect(_ i: Int) -> NSRect {
        NSRect(
            x: CGFloat(i) * (itemSize.width + spacing), y: 0,
            width: itemSize.width, height: itemSize.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        for i in 0..<3 {
            let rect = itemRect(i)
            let path: NSBezierPath
            switch shape {
            case .square:
                path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            case .rectangle:
                path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            case .diamond:
                path = NSBezierPath()
                path.move(to: NSPoint(x: rect.midX, y: rect.maxY))
                path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
                path.line(to: NSPoint(x: rect.midX, y: rect.minY))
                path.line(to: NSPoint(x: rect.minX, y: rect.midY))
                path.close()
            }
            TrafficLightsView.colors[i].setFill()
            path.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in 0..<3 where itemRect(i).insetBy(dx: -2, dy: -2).contains(p) {
            switch i {
            case 0: window?.performClose(nil)
            case 1: window?.miniaturize(nil)
            default: window?.zoom(nil)
            }
            return
        }
        window?.performDrag(with: event)
    }
}
