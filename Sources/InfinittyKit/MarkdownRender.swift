import AppKit

/// Lightweight markdown → NSAttributedString for UI (release notes, dialogs).
/// Handles headers, bold/italic, inline code, fenced code blocks, and bullets
/// — enough for release notes, styled to look native in a dark panel.
enum MarkdownRender {
    static func attributed(_ markdown: String, width: CGFloat = 420) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: 12)
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let text = NSColor.labelColor
        let dim = NSColor.secondaryLabelColor
        let codeBG = NSColor.quaternaryLabelColor.withAlphaComponent(0.35)

        let out = NSMutableAttributedString()
        var inFence = false
        var fenceLines: [String] = []

        func para(_ spacing: CGFloat, head: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = spacing
            p.headIndent = head
            p.firstLineHeadIndent = head
            p.lineSpacing = 1.5
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
                let size: CGFloat = level <= 1 ? 15 : level == 2 ? 13.5 : 12.5
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
            // Paragraph
            out.append(inline(line, base: body, color: dim, mono: mono,
                codeBG: codeBG, paragraph: para(6)))
            out.append(NSAttributedString(string: "\n"))
        }
        if inFence { flushFence() }
        return out
    }

    /// Inline **bold**, *italic*, and `code` within one line.
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
            } else {
                result.append(NSAttributedString(string: String(s[i]), attributes: attrs(base)))
                i = s.index(after: i)
            }
        }
        return result
    }
}
