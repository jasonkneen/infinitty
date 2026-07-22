import AppKit

/// Lightweight markdown → NSAttributedString for UI (release notes, dialogs).
/// Handles headers, bold/italic, inline code, fenced code blocks, bullets, and
/// GitHub-style pipe tables — enough for release notes, styled to look native
/// in a dark panel.
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

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lineIndex = 0
        while lineIndex < lines.count {
            let rawLine = lines[lineIndex]
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence { flushFence() }
                inFence.toggle()
                lineIndex += 1
                continue
            }
            if inFence {
                fenceLines.append(rawLine)
                lineIndex += 1
                continue
            }

            if let header = tableCells(in: rawLine), lineIndex + 1 < lines.count,
               let delimiter = tableCells(in: lines[lineIndex + 1]),
               header.count == delimiter.count,
               let alignments = tableAlignments(in: delimiter) {
                var rows: [[String]] = []
                lineIndex += 2
                while lineIndex < lines.count,
                      let cells = tableRowCells(in: lines[lineIndex]) {
                    let visibleCells = Array(cells.prefix(header.count))
                    rows.append(visibleCells + Array(
                        repeating: "", count: max(0, header.count - visibleCells.count)))
                    lineIndex += 1
                }
                appendTable(
                    header: header, rows: rows, alignments: alignments,
                    to: out, body: body, mono: mono, text: text, dim: dim,
                    codeBG: codeBG, style: style, paragraph: para)
                continue
            }

            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
                lineIndex += 1
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
                lineIndex += 1
                continue
            }
            // Bullets
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let content = "•  " + String(line.dropFirst(2))
                out.append(inline(content, base: body, color: text, mono: mono,
                    codeBG: codeBG, paragraph: para(3, head: 14)))
                out.append(NSAttributedString(string: "\n"))
                lineIndex += 1
                continue
            }
            // Numbered lists.
            if let marker = line.range(of: "^\\d+\\. ", options: .regularExpression) {
                let content = String(line[..<marker.upperBound]) + String(line[marker.upperBound...])
                out.append(inline(content, base: body, color: text, mono: mono,
                    codeBG: codeBG, paragraph: para(3, head: 18)))
                out.append(NSAttributedString(string: "\n"))
                lineIndex += 1
                continue
            }
            // Blockquotes.
            if line.hasPrefix("> ") {
                let content = String(line.dropFirst(2))
                out.append(inline(content, base: NSFontManager.shared.convert(
                    body, toHaveTrait: .italicFontMask), color: dim, mono: mono,
                    codeBG: codeBG, paragraph: para(5, head: 12)))
                out.append(NSAttributedString(string: "\n"))
                lineIndex += 1
                continue
            }
            if line == "---" || line == "***" {
                out.append(NSAttributedString(string: "────────────────\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor.separatorColor,
                    .paragraphStyle: para(6),
                ]))
                lineIndex += 1
                continue
            }
            // Paragraph
            out.append(inline(line, base: body, color: dim, mono: mono,
                codeBG: codeBG, paragraph: para(6)))
            out.append(NSAttributedString(string: "\n"))
            lineIndex += 1
        }
        if inFence { flushFence() }
        if out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    /// GFM table cell parser: optional outer pipes are stripped and escaped
    /// pipes remain literal cell content.
    private static func tableCells(in rawLine: String) -> [String]? {
        var contents = rawLine.trimmingCharacters(in: .whitespaces)
        guard contents.contains("|") else { return nil }
        if contents.hasPrefix("|") { contents.removeFirst() }
        if hasUnescapedTrailingPipe(in: contents) { contents.removeLast() }

        var cells: [String] = []
        var cell = ""
        var escaping = false
        for character in contents {
            if escaping {
                if character == "|" {
                    cell.append(character)
                } else {
                    cell.append("\\")
                    cell.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaping { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// A body row may omit trailing cells, including every pipe for a one-cell
    /// row. Block-level Markdown always ends the table instead of becoming a
    /// cell, even when its content happens to contain a pipe.
    private static func tableRowCells(in rawLine: String) -> [String]? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !startsTableTerminatingBlock(line) else { return nil }
        return tableCells(in: rawLine) ?? [line]
    }

    private static func startsTableTerminatingBlock(_ line: String) -> Bool {
        guard !line.isEmpty else { return true }
        if line.hasPrefix("```") || line.hasPrefix("> ") ||
            line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") ||
            line == "---" || line == "***" {
            return true
        }
        return line.range(of: "^#{1,6}(?:\\s|$)|^\\d+\\.\\s", options: .regularExpression) != nil
    }

    private static func hasUnescapedTrailingPipe(in contents: String) -> Bool {
        guard contents.last == "|" else { return false }
        var backslashCount = 0
        var index = contents.index(before: contents.endIndex)
        while index > contents.startIndex {
            index = contents.index(before: index)
            guard contents[index] == "\\" else { break }
            backslashCount += 1
        }
        return backslashCount.isMultiple(of: 2)
    }

    /// Validate a GFM delimiter row and derive the requested column alignment.
    private static func tableAlignments(in cells: [String]) -> [NSTextAlignment]? {
        var alignments: [NSTextAlignment] = []
        for cell in cells {
            let marker = cell.trimmingCharacters(in: .whitespaces)
            guard marker.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil
            else { return nil }
            if marker.hasPrefix(":") && marker.hasSuffix(":") {
                alignments.append(.center)
            } else if marker.hasSuffix(":") {
                alignments.append(.right)
            } else {
                alignments.append(.left)
            }
        }
        return alignments
    }

    private static func appendTable(
        header: [String], rows: [[String]], alignments: [NSTextAlignment],
        to output: NSMutableAttributedString, body: NSFont, mono: NSFont,
        text: NSColor, dim: NSColor, codeBG: NSColor, style: Style,
        paragraph: (CGFloat, CGFloat) -> NSParagraphStyle
    ) {
        let table = NSTextTable()
        table.numberOfColumns = header.count
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        let borderColor = style == .chat
            ? NSColor(white: 1, alpha: 0.16)
            : NSColor.separatorColor
        let allRows = [header] + rows

        for (rowIndex, row) in allRows.enumerated() {
            for column in 0..<header.count {
                let block = NSTextTableBlock(
                    table: table, startingRow: rowIndex, rowSpan: 1,
                    startingColumn: column, columnSpan: 1)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(5, type: .absoluteValueType, for: .padding)
                for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
                    block.setBorderColor(borderColor, for: edge)
                }

                let cellParagraph = NSMutableParagraphStyle()
                cellParagraph.paragraphSpacing = rowIndex == allRows.count - 1 ? 5 : 1
                cellParagraph.lineSpacing = style == .chat ? 2 : 1.5
                cellParagraph.alignment = alignments[column]
                cellParagraph.textBlocks = [block]
                let isHeader = rowIndex == 0
                let cellText = row[column]
                let base = isHeader
                    ? NSFont.monospacedSystemFont(ofSize: body.pointSize - 1, weight: .bold)
                    : mono
                let color = isHeader ? text : dim
                let attributedCell = NSMutableAttributedString(attributedString: inline(
                    cellText, base: base, color: color, mono: mono,
                    codeBG: codeBG, paragraph: cellParagraph))
                attributedCell.append(NSAttributedString(string: "\n", attributes: [
                    .font: body, .paragraphStyle: cellParagraph,
                ]))
                output.append(attributedCell)
            }
        }
        output.append(NSAttributedString(string: "\n", attributes: [
            .font: body, .paragraphStyle: paragraph(6, 0),
        ]))
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
