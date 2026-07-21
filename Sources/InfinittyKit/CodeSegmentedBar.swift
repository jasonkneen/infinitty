import AppKit

/// Shared chrome colors for the code view.
enum CodePalette {
    static let selectionFill = NSColor(calibratedWhite: 0.23, alpha: 1)
    /// Accent used for emphasized content and focused pane state. Config-driven
    /// (accent-color); defaults to indigo. Utility chrome itself stays neutral.
    static let defaultAccent = NSColor(
        calibratedRed: 0.39, green: 0.44, blue: 0.92, alpha: 1)
    static var selectionAccent = defaultAccent
    /// Saturated blue used only for the active pane card. The configurable
    /// accent can be intentionally muted for text controls, but pane focus must
    /// retain the crisp blue contrast shown in the window layout.
    static let paneFocusAccent = NSColor(
        srgbRed: 0.00, green: 0.36, blue: 0.76, alpha: 1)

    /// Apply the app config's accent-color (call before building chrome).
    static func apply(_ config: AppConfig) {
        if let rgb = config.accentColor {
            selectionAccent = NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        } else {
            selectionAccent = defaultAccent
        }
    }
    static let outline = NSColor(white: 1, alpha: 0.22)
    static let hairline = NSColor(white: 1, alpha: 0.08)
    /// Neutral "raised" fill for the active tab in the icon-style page control
    /// (macOS-segment look), used instead of the accent so the tab bar reads
    /// as clean chrome rather than a colored control.
    static let tabSelectionNeutral = NSColor(white: 1, alpha: 0.16)
    static let glassFill = NSColor(white: 1, alpha: 0.055)
    static let glassBorder = NSColor(white: 1, alpha: 0.16)

    static func isNeutral(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return false }
        return abs(rgb.redComponent - rgb.greenComponent) < 0.01
            && abs(rgb.greenComponent - rgb.blueComponent) < 0.01
    }
}

/// Minimal capsule segmented control for the code view. AppKit's
/// NSSegmentedControl renders in the system accent color, which clashes with
/// the terminal's dark chrome; this one stays on-palette — hairline-dark
/// container, translucent glass pill for the active segment.
/// Compact outlined segmented control for code-view page and preview modes.
final class CodeSegmentedBar: NSView {
    var onChange: ((Int) -> Void)?
    private(set) var selectedIndex: Int
    private let labels: [String]
    /// Optional SF Symbol name per segment. When present the control renders an
    /// icon + label per tab and uses the neutral raised-pill selection.
    private let icons: [String?]
    private let font: NSFont
    private let fontWeight: NSFont.Weight
    private let squared: Bool
    private let neutralSelection: Bool
    private var hasIcons: Bool { icons.contains { $0 != nil } }
    private let iconGap: CGFloat = 5

    var selectionFillColor: NSColor {
        neutralSelection ? CodePalette.tabSelectionNeutral : CodePalette.selectionAccent
    }
    let outlineColor = CodePalette.glassBorder

    init(
        labels: [String], icons: [String?]? = nil,
        fontSize: CGFloat = NSFont.systemFontSize,
        fontWeight: NSFont.Weight = .semibold,
        initialIndex: Int = 0, squared: Bool = false,
        neutralSelection: Bool = false
    ) {
        self.labels = labels
        self.icons = icons ?? Array(repeating: nil, count: labels.count)
        self.fontWeight = fontWeight
        self.font = .systemFont(ofSize: fontSize, weight: fontWeight)
        self.selectedIndex = min(max(initialIndex, 0), labels.count - 1)
        self.squared = squared
        self.neutralSelection = neutralSelection
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var labelsForTesting: [String] { labels }
    var fontSizeForTesting: CGFloat { font.pointSize }
    var fontWeightForTesting: CGFloat { fontWeight.rawValue }
    var outerCornerRadiusForTesting: CGFloat { squared ? 7 : bounds.height / 2 }

    private var iconPointSize: CGFloat { font.pointSize + 2 }

    /// Tinted SF Symbol for a segment (template flattened to `color`).
    private func symbol(_ name: String, color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .medium)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        let out = NSImage(size: base.size)
        out.lockFocus()
        base.draw(at: .zero, from: NSRect(origin: .zero, size: base.size),
                  operation: .sourceOver, fraction: 1)
        color.set()
        NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    override var intrinsicContentSize: NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var width: CGFloat = 0
        for (i, label) in labels.enumerated() {
            // Icon tabs need more breathing room than the compact text-only
            // preview toggle, especially when the bar is centered in a pane.
            var seg = ceil(label.size(withAttributes: attrs).width) + (hasIcons ? 36 : 20)
            if icons[i] != nil { seg += iconPointSize + iconGap }
            width += max(seg, 64)
        }
        let height = hasIcons ? max(28, font.pointSize * 2.6) : max(22, font.pointSize * 2.1)
        return NSSize(width: width, height: height)
    }

    func setSelectedIndex(_ index: Int, notify: Bool = false) {
        let clamped = min(max(index, 0), labels.count - 1)
        guard clamped != selectedIndex else { return }
        selectedIndex = clamped
        needsDisplay = true
        if notify { onChange?(clamped) }
    }

    private func segmentRect(_ index: Int) -> NSRect {
        let width = bounds.width / CGFloat(labels.count)
        return NSRect(x: width * CGFloat(index), y: 0, width: width, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let outerRadius = squared ? 7.0 : bounds.height / 2

        // Faint track so the strip reads as a container without a hard box.
        if hasIcons {
            let track = NSBezierPath(
                roundedRect: bounds, xRadius: outerRadius, yRadius: outerRadius)
            CodePalette.glassFill.setFill()
            track.fill()
        }

        // Subtle outer hairline (kept intentionally — reads as a segmented
        // container edge; also what `pageControlHasOutlineForTesting` checks).
        let container = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: outerRadius, yRadius: outerRadius)
        container.lineWidth = 1
        outlineColor.setStroke()
        container.stroke()

        // Active segment.
        let selectedRect = segmentRect(selectedIndex).insetBy(dx: 2, dy: 2)
        let selectedRadius = squared ? 5.0 : (bounds.height - 4) / 2
        let selected = NSBezierPath(
            roundedRect: selectedRect, xRadius: selectedRadius, yRadius: selectedRadius)
        if neutralSelection {
            // macOS-style raised pill: neutral fill + a soft top highlight and
            // a 0.75px light border so it looks lifted off the track.
            selectionFillColor.setFill()
            selected.fill()
            let border = NSBezierPath(
                roundedRect: selectedRect.insetBy(dx: 0.375, dy: 0.375),
                xRadius: selectedRadius, yRadius: selectedRadius)
            border.lineWidth = 0.75
            NSColor(white: 1, alpha: 0.22).setStroke()
            border.stroke()
        } else {
            selectionFillColor.setFill()
            selected.fill()
        }

        // Segment content: icon + label (when icons present), else label only.
        for (index, label) in labels.enumerated() {
            let active = index == selectedIndex
            let color: NSColor = active ? .white : .secondaryLabelColor
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: style,
            ]
            let rect = segmentRect(index)
            let labelSize = label.size(withAttributes: attrs)

            if let iconName = icons[index], let image = symbol(iconName, color: color) {
                let gap = iconGap
                let groupW = image.size.width + gap + labelSize.width
                let originX = rect.minX + (rect.width - groupW) / 2
                let iconRect = NSRect(
                    x: originX, y: rect.midY - image.size.height / 2,
                    width: image.size.width, height: image.size.height)
                image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
                let textRect = NSRect(
                    x: originX + image.size.width + gap,
                    y: rect.midY - labelSize.height / 2,
                    width: labelSize.width + 1, height: labelSize.height)
                label.draw(in: textRect, withAttributes: [
                    .font: font, .foregroundColor: color,
                ])
            } else {
                let textRect = NSRect(
                    x: rect.minX, y: rect.midY - labelSize.height / 2,
                    width: rect.width, height: labelSize.height)
                label.draw(in: textRect, withAttributes: attrs)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.x / (bounds.width / CGFloat(labels.count)))
        setSelectedIndex(index, notify: true)
    }
}
