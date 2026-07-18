import AppKit

/// Shared chrome colors for the code view.
enum CodePalette {
    static let selectionFill = NSColor(calibratedWhite: 0.23, alpha: 1)
    static let outline = NSColor(white: 1, alpha: 0.22)
    static let hairline = NSColor(white: 1, alpha: 0.08)

    static func isNeutral(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return false }
        return abs(rgb.redComponent - rgb.greenComponent) < 0.01
            && abs(rgb.greenComponent - rgb.blueComponent) < 0.01
    }
}

/// Minimal capsule segmented control for the code view. AppKit's
/// NSSegmentedControl renders in the system accent color, which clashes with
/// the terminal's dark chrome; this one stays on-palette — hairline-dark
/// container, indigo pill for the active segment.
/// Compact outlined segmented control for code-view page and preview modes.
final class CodeSegmentedBar: NSView {
    var onChange: ((Int) -> Void)?
    private(set) var selectedIndex: Int
    private let labels: [String]
    private let font: NSFont
    private let fontWeight: NSFont.Weight
    private let squared: Bool
    let selectionFillColor = CodePalette.selectionFill
    let outlineColor = CodePalette.outline

    init(
        labels: [String], fontSize: CGFloat = NSFont.systemFontSize,
        fontWeight: NSFont.Weight = .semibold,
        initialIndex: Int = 0, squared: Bool = false
    ) {
        self.labels = labels
        self.fontWeight = fontWeight
        self.font = .systemFont(ofSize: fontSize, weight: fontWeight)
        self.selectedIndex = min(max(initialIndex, 0), labels.count - 1)
        self.squared = squared
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var labelsForTesting: [String] { labels }
    var fontSizeForTesting: CGFloat { font.pointSize }
    var fontWeightForTesting: CGFloat { fontWeight.rawValue }

    override var intrinsicContentSize: NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var width: CGFloat = 0
        for label in labels {
            width += max(ceil(label.size(withAttributes: attrs).width) + 20, 64)
        }
        return NSSize(width: width, height: max(22, font.pointSize * 2.1))
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
        let outerRadius = squared ? 5.0 : bounds.height / 2
        let container = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: outerRadius, yRadius: outerRadius)
        container.lineWidth = 1
        outlineColor.setStroke()
        container.stroke()

        let selectedRect = segmentRect(selectedIndex).insetBy(dx: 2, dy: 2)
        let selectedRadius = squared ? 3.0 : (bounds.height - 4) / 2
        let selected = NSBezierPath(
            roundedRect: selectedRect,
            xRadius: selectedRadius, yRadius: selectedRadius)
        selectionFillColor.setFill()
        selected.fill()

        for (index, label) in labels.enumerated() {
            let color: NSColor = index == selectedIndex ? .white : .secondaryLabelColor
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: style,
            ]
            let size = label.size(withAttributes: attrs)
            let rect = segmentRect(index)
            let textRect = NSRect(
                x: rect.minX, y: rect.midY - size.height / 2,
                width: rect.width, height: size.height)
            label.draw(in: textRect, withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.x / (bounds.width / CGFloat(labels.count)))
        setSelectedIndex(index, notify: true)
    }
}
