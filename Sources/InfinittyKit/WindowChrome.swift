import AppKit

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
