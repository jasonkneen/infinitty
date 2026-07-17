import Foundation

/// One line of a unified diff, headers stripped. `oldLine`/`newLine` are the
/// 1-based line numbers on each side; nil where the line doesn't exist on
/// that side (additions/deletions). `.hunk` rows carry the raw hunk header
/// (or a section separator like "unstaged") in `text`.
struct DiffLine: Equatable {
    enum Kind: Equatable { case context, add, del, hunk }
    let kind: Kind
    let oldLine: Int?
    let newLine: Int?
    let text: String
}

/// One row of a side-by-side diff: an old-side cell and a new-side cell.
/// Either side may be blank (padding opposite an add/del run). Hunk rows set
/// `isHunk` and carry the header text on the left.
struct SplitDiffRow {
    let oldLine: Int?
    let oldText: String
    let oldKind: DiffLine.Kind?
    let newLine: Int?
    let newText: String
    let newKind: DiffLine.Kind?
    let isHunk: Bool
}

/// Unified-diff parsing and side-by-side pairing. Pure — unit-tested without
/// any UI.
enum CodeDiff {

    /// Parse `git diff` output into displayable lines. File headers are
    /// dropped; hunk headers become `.hunk` rows; CodeGit's custom
    /// "--- unstaged ---" separator becomes a `.hunk` row too.
    static func parse(_ diff: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var oldNo = 0
        var newNo = 0
        var inHunk = false
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                if let (o, n) = parseHunkHeader(line) {
                    oldNo = o
                    newNo = n
                    lines.append(DiffLine(kind: .hunk, oldLine: nil, newLine: nil, text: line))
                    inHunk = true
                }
                continue
            }
            if line.hasPrefix("diff --git") { inHunk = false; continue }
            if line == "--- unstaged ---" {
                lines.append(DiffLine(kind: .hunk, oldLine: nil, newLine: nil, text: line))
                inHunk = false
                continue
            }
            guard inHunk, let first = line.first, first != "\\" else { continue }
            let text = String(line.dropFirst())
            switch first {
            case " ":
                lines.append(DiffLine(kind: .context, oldLine: oldNo, newLine: newNo, text: text))
                oldNo += 1
                newNo += 1
            case "-":
                lines.append(DiffLine(kind: .del, oldLine: oldNo, newLine: nil, text: text))
                oldNo += 1
            case "+":
                lines.append(DiffLine(kind: .add, oldLine: nil, newLine: newNo, text: text))
                newNo += 1
            default:
                break
            }
        }
        return lines
    }

    /// "@@ -3,7 +3,8 @@" → (3, 3); counts default to 1 when omitted.
    static func parseHunkHeader(_ line: String) -> (old: Int, new: Int)? {
        guard let rx = try? NSRegularExpression(
            pattern: "@@ -(\\d+)(?:,\\d+)? \\+(\\d+)(?:,\\d+)? @@"),
              let m = rx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let oldRange = Range(m.range(at: 1), in: line),
              let newRange = Range(m.range(at: 2), in: line),
              let old = Int(line[oldRange]), let new = Int(line[newRange])
        else { return nil }
        return (old, new)
    }

    /// Pair parsed lines into side-by-side rows. Context lines appear on both
    /// sides; each del*/add* run is paired index-wise (git emits deletions
    /// first), with blanks padding the shorter side.
    static func splitRows(from lines: [DiffLine]) -> [SplitDiffRow] {
        var rows: [SplitDiffRow] = []
        var i = 0
        func blankRow(old: DiffLine?, new: DiffLine?) -> SplitDiffRow {
            SplitDiffRow(
                oldLine: old?.oldLine, oldText: old?.text ?? "", oldKind: old?.kind,
                newLine: new?.newLine, newText: new?.text ?? "", newKind: new?.kind,
                isHunk: false)
        }
        while i < lines.count {
            let line = lines[i]
            switch line.kind {
            case .hunk:
                rows.append(SplitDiffRow(
                    oldLine: nil, oldText: line.text, oldKind: .hunk,
                    newLine: nil, newText: "", newKind: nil, isHunk: true))
                i += 1
            case .context:
                rows.append(blankRow(old: line, new: line))
                i += 1
            case .del, .add:
                var dels: [DiffLine] = []
                var adds: [DiffLine] = []
                while i < lines.count, lines[i].kind == .del { dels.append(lines[i]); i += 1 }
                while i < lines.count, lines[i].kind == .add { adds.append(lines[i]); i += 1 }
                for k in 0..<max(dels.count, adds.count) {
                    rows.append(blankRow(
                        old: k < dels.count ? dels[k] : nil,
                        new: k < adds.count ? adds[k] : nil))
                }
            }
        }
        return rows
    }
}
