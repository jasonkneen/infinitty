import AppKit

/// Lightweight markdown → NSAttributedString for UI (release notes, dialogs).
/// Handles headers, bold/italic, inline code, fenced code blocks, and bullets
/// — enough for release notes, styled to look native in a dark panel.
enum MarkdownRender {
    enum Style { case preview, chat }

    static func attributed(
        _ markdown: String, width: CGFloat = 420, style: Style = .preview
    ) -> NSAttributedString {
        let bodySize: CGFloat = style == .chat ? NSFont.systemFontSize : 12
        let body = NSFont.systemFont(ofSize: bodySize)
        let mono = NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular)
        let text = style == .chat ? NSColor(white: 0.94, alpha: 1) : NSColor.labelColor
        let dim = style == .chat ? NSColor(white: 0.88, alpha: 1) : NSColor.secondaryLabelColor
        let codeBG = style == .chat
            ? CodePalette.paneFocusAccent.withAlphaComponent(0.12)
            : NSColor.quaternaryLabelColor.withAlphaComponent(0.35)

        let out = NSMutableAttributedString()
        var inFence = false
        var fenceLines: [String] = []

        func para(_ spacing: CGFloat, head: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = spacing
            p.headIndent = head
            p.firstLineHeadIndent = head
            p.lineSpacing = style == .chat ? 2 : 1.5
            return p
        }

        func flushFence() {
            guard !fenceLines.isEmpty else { return }
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = 8
            p.headIndent = 10
            p.firstLineHeadIndent = 10
            p.lineSpacing = 2
            let code = fenceLines.joined(separator: "\n")
            out.append(NSAttributedString(string: code + "\n", attributes: [
                .font: mono, .foregroundColor: text, .paragraphStyle: p,
                .backgroundColor: codeBG,
            ]))
            fenceLines.removeAll()
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence { flushFence() }
                inFence.toggle()
                continue
            }
            if inFence { fenceLines.append(rawLine); continue }

            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
                continue
            }

            // Headers
            if let hashes = line.range(of: "^#{1,6} ", options: .regularExpression) {
                let level = line.distance(from: line.startIndex, to: hashes.upperBound) - 1
                let size: CGFloat = level <= 1 ? bodySize + 3 : level == 2 ? bodySize + 1.5 : bodySize + 0.5
                let content = String(line[hashes.upperBound...])
                out.append(inline(content, base: NSFont.boldSystemFont(ofSize: size),
                    color: text, mono: mono, codeBG: codeBG, paragraph: para(6)))
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            // Bullets
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let content = "•  " + String(line.dropFirst(2))
                out.append(inline(content, base: body, color: text, mono: mono,
                    codeBG: codeBG, paragraph: para(3, head: 14)))
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            // Numbered lists.
            if let marker = line.range(of: "^\\d+\\. ", options: .regularExpression) {
                let content = String(line[..<marker.upperBound]) + String(line[marker.upperBound...])
                out.append(inline(content, base: body, color: text, mono: mono,
                    codeBG: codeBG, paragraph: para(3, head: 18)))
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            // Blockquotes.
            if line.hasPrefix("> ") {
                let content = String(line.dropFirst(2))
                out.append(inline(content, base: NSFontManager.shared.convert(
                    body, toHaveTrait: .italicFontMask), color: dim, mono: mono,
                    codeBG: codeBG, paragraph: para(5, head: 12)))
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            if line == "---" || line == "***" {
                out.append(NSAttributedString(string: "────────────────\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor.separatorColor,
                    .paragraphStyle: para(6),
                ]))
                continue
            }
            // Paragraph
            out.append(inline(line, base: body, color: dim, mono: mono,
                codeBG: codeBG, paragraph: para(6)))
            out.append(NSAttributedString(string: "\n"))
        }
        if inFence { flushFence() }
        return out
    }

    /// Inline **bold**, *italic*, `code`, and [links](https://example.com).
    private static func inline(
        _ s: String, base: NSFont, color: NSColor, mono: NSFont,
        codeBG: NSColor, paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var i = s.startIndex
        func attrs(_ font: NSFont, code: Bool = false) -> [NSAttributedString.Key: Any] {
            var a: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            if code { a[.backgroundColor] = codeBG }
            return a
        }
        while i < s.endIndex {
            if s[i...].hasPrefix("**"), let end = s.range(of: "**", range: s.index(i, offsetBy: 2)..<s.endIndex) {
                let content = String(s[s.index(i, offsetBy: 2)..<end.lowerBound])
                result.append(NSAttributedString(string: content, attributes: attrs(NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask))))
                i = end.upperBound
            } else if s[i] == "`", let end = s.range(of: "`", range: s.index(after: i)..<s.endIndex) {
                let content = String(s[s.index(after: i)..<end.lowerBound])
                result.append(NSAttributedString(string: content, attributes: attrs(mono, code: true)))
                i = end.upperBound
            } else if s[i] == "[",
                      let middle = s.range(of: "](", range: s.index(after: i)..<s.endIndex),
                      let end = s.range(of: ")", range: middle.upperBound..<s.endIndex) {
                let title = String(s[s.index(after: i)..<middle.lowerBound])
                let target = String(s[middle.upperBound..<end.lowerBound])
                var linkAttrs = attrs(base)
                linkAttrs[.foregroundColor] = CodePalette.paneFocusAccent
                linkAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                if let url = URL(string: target) { linkAttrs[.link] = url }
                result.append(NSAttributedString(string: title, attributes: linkAttrs))
                i = end.upperBound
            } else if s[i] == "*",
                      let end = s.range(of: "*", range: s.index(after: i)..<s.endIndex) {
                let content = String(s[s.index(after: i)..<end.lowerBound])
                let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
                result.append(NSAttributedString(string: content, attributes: attrs(italic)))
                i = end.upperBound
            } else {
                result.append(NSAttributedString(string: String(s[i]), attributes: attrs(base)))
                i = s.index(after: i)
            }
        }
        return result
    }
}
