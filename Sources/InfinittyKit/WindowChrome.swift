import AppKit

/// Subtle "update available" pill, top-right of the window. Muted until
/// hovered; click to open the update prompt.
final class UpdateIndicatorView: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var hovering = false

    init(version: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 96, height: 22))
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 1

        label.stringValue = "↑ \(version)"
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.frame = bounds
        label.autoresizingMask = [.width, .height]
        label.isEditable = false
        label.isBezeled = false
        label.drawsBackground = false
        addSubview(label)
        applyStyle()
        toolTip = "Update available — click to install"
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyStyle() {
        let accent = NSColor(srgbRed: 0.36, green: 0.72, blue: 0.55, alpha: 1) // soft green
        layer?.backgroundColor = accent.withAlphaComponent(hovering ? 0.28 : 0.14).cgColor
        layer?.borderColor = accent.withAlphaComponent(hovering ? 0.9 : 0.45).cgColor
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

    /// Position in the top-right of a host content view, below the titlebar inset.
    func place(in host: NSView, topInset: CGFloat) {
        frame.origin = NSPoint(
            x: host.bounds.width - frame.width - 10,
            y: host.bounds.height - frame.height - max(topInset, 6) - 4
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
