import AppKit

/// Shared chrome colors for the code view.
enum CodePalette {
    /// Muted indigo accent — active segment pill and selected tree row.
    static let accent = NSColor(
        calibratedRed: 0x6C / 255, green: 0x63 / 255, blue: 0xF0 / 255, alpha: 1)
    static let hairline = NSColor(white: 1, alpha: 0.08)
}

/// Minimal capsule segmented control for the code view. AppKit's
/// NSSegmentedControl renders in the system accent color, which clashes with
/// the terminal's dark chrome; this one stays on-palette — hairline-dark
/// container, indigo pill for the active segment.
final class CodeSegmentedBar: NSView {
    var onChange: ((Int) -> Void)?
    private(set) var selectedIndex: Int
    private let labels: [String]
    private let font: NSFont
    private let squared: Bool

    init(labels: [String], fontSize: CGFloat = 11.5, initialIndex: Int = 0, squared: Bool = false) {
        self.labels = labels
        self.font = .systemFont(ofSize: fontSize, weight: .medium)
        self.selectedIndex = min(max(initialIndex, 0), labels.count - 1)
        self.squared = squared
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var width: CGFloat = 0
        for label in labels {
            width += max(ceil(label.size(withAttributes: attrs).width) + 20, 64)
        }
        return NSSize(width: width, height: max(18, font.pointSize * 2.1))
    }

    func setSelectedIndex(_ index: Int, notify: Bool = false) {
        let clamped = min(max(index, 0), labels.count - 1)
        guard clamped != selectedIndex else { return }
        selectedIndex = clamped
        needsDisplay = true
        if notify { onChange?(clamped) }
    }

    private func segmentRect(_ index: Int) -> NSRect {
        let w = bounds.width / CGFloat(labels.count)
        return NSRect(x: w * CGFloat(index), y: 0, width: w, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let outerRadius = squared ? 6.0 : bounds.height / 2
        let container = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: outerRadius, yRadius: outerRadius)
        NSColor(white: 1, alpha: 0.07).setFill()
        container.fill()

        let pillRect = segmentRect(selectedIndex).insetBy(dx: 2, dy: 2)
        let pillRadius = squared ? 4.0 : (bounds.height - 4) / 2
        let pill = NSBezierPath(
            roundedRect: pillRect,
            xRadius: pillRadius, yRadius: pillRadius)
        CodePalette.accent.setFill()
        pill.fill()

        for (i, label) in labels.enumerated() {
            let color: NSColor = i == selectedIndex ? .white : .secondaryLabelColor
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: style,
            ]
            let size = label.size(withAttributes: attrs)
            let rect = segmentRect(i)
            let textRect = NSRect(
                x: rect.minX, y: rect.midY - size.height / 2,
                width: rect.width, height: size.height)
            label.draw(in: textRect, withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let index = Int(pt.x / (bounds.width / CGFloat(labels.count)))
        setSelectedIndex(index, notify: true)
    }
}
