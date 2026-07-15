import Compression
import CoreGraphics
import Foundation
import ImageIO
import os

// Snapshot handed to the renderer. Buffers are reused across frames.
struct TermSnapshot {
    var cols = 0
    var rows = 0
    var cells: [Cell] = []
    var cursorX = 0
    var cursorY = 0 // in view coordinates (scrollback offset applied)
    var cursorVisible = false
    var scrolledBack = false
    var images: [SnapImage] = []
}

/// A visible inline image for the renderer (OSC 1337).
struct SnapImage {
    var id: UInt64
    var viewRow: Int // may be negative when partially scrolled off the top
    var col: Int
    var cellCols: Int
    var cellRows: Int
}

// Fixed-capacity ring of scrollback rows. Index 0 is the oldest row.
private struct RowRing {
    private var buf: [[Cell]] = []
    private var start = 0
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity }
    var count: Int { buf.count }

    mutating func append(_ row: [Cell]) {
        if buf.count < capacity {
            buf.append(row)
        } else {
            buf[start] = row
            start = (start + 1) % capacity
        }
    }

    subscript(i: Int) -> [Cell] { buf[(start + i) % buf.count] }

    mutating func removeAll() {
        buf.removeAll(keepingCapacity: false)
        start = 0
    }
}

private struct Pen {
    var fg: UInt32 = ColorCode.defaultFG
    var bg: UInt32 = ColorCode.defaultBG
    var flags: UInt16 = 0
}

private struct SavedCursor {
    var x = 0
    var y = 0
    var pen = Pen()
    var originMode = false
    var activeCharset = 0
    var charsets: [Bool] = [false, false]
}

/// The terminal engine: grid, scrollback, and a single-pass VT parser.
/// `feed` is called from the PTY read thread with whole kernel-sized batches;
/// the renderer takes snapshots. One unfair lock, held briefly by both sides.
final class Terminal {
    static let maxScrollback = 10_000

    var onOutput: (([UInt8]) -> Void)? // parser responses (DSR etc.) -> pty
    var onTitle: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onChange: (() -> Void)? // fired after every mutating batch, outside the lock
    var onMarker: ((UInt8, Int) -> Void)? // OSC 133 events: (kind, exitCode)

    private let lock = OSAllocatedUnfairLock()
    private var generation: UInt64 = 1

    private(set) var cols: Int
    private(set) var rows: Int

    private var screen: [[Cell]]
    private var inactiveScreen: [[Cell]]
    private var usingAlt = false
    private var scrollback: RowRing
    private var viewOffset = 0 // rows scrolled back into history

    private var cx = 0
    private var cy = 0
    private var pen = Pen()
    private var savedMain = SavedCursor()
    private var savedAlt = SavedCursor()

    private var autowrap = true
    private var insertMode = false
    private var originMode = false
    private var cursorVisible = true
    private var appCursor = false
    private var bracketedPaste = false
    private var wrapPending = false
    private var mouseMode = 0 // 0 off, 9 X10, 1000 clicks, 1002 +drag, 1003 +motion
    private var mouseSGR = false

    private var top = 0
    private var bottom: Int // inclusive scroll region

    private var tabs: [Bool]

    private var charsets: [Bool] = [false, false] // true = DEC special graphics
    private var activeCharset = 0

    // MARK: parser state

    private enum PState {
        case ground, esc, escInter, csi, osc, oscEsc, str, strEsc, apc, apcEsc
    }

    private var pstate = PState.ground
    private var csiParams: [Int] = []
    private var csiColon: [Bool] = [] // param attached to previous via ':'
    private var csiNextColon = false
    private var csiCur = 0
    private var csiHasCur = false
    private var csiMarker: UInt8 = 0
    private var csiInter: UInt8 = 0
    private var escInterByte: UInt8 = 0
    private var oscBuf: [UInt8] = []

    private var utf8Value: UInt32 = 0
    private var utf8Needed = 0
    private var utf8Min: UInt32 = 0 // smallest scalar valid for this length

    private var pendingOutput: [UInt8] = []
    private var pendingTitle: String?
    private var pendingBell = false
    private var pendingMarkers: [(UInt8, Int)] = []

    // MARK: semantic command markers (OSC 133, for agents/tooling)

    private struct Marker {
        var kind: UInt8 // A prompt, B input, C output-start, D done
        var line: Int // absolute line number
        var col: Int // cursor column at marker time
        var exitCode: Int
    }

    private var markers: [Marker] = []
    private var sbAppended = 0 // total rows ever pushed to scrollback

    // MARK: selection & link highlight (absolute content coordinates)

    enum SelectionMode { case character, word, line }

    private var selAnchor: (line: Int, col: Int)?
    private var selHead: (line: Int, col: Int)?
    private var selMode = SelectionMode.character
    private var linkRange: (line: Int, lo: Int, hi: Int)?

    // MARK: inline images (iTerm2 OSC 1337 File=)

    struct ImagePlacement {
        let id: UInt64
        var absLine: Int
        var col: Int
        var cellCols: Int
        var cellRows: Int
        var pxWidth: Int
        var pxHeight: Int
        var rgba: [UInt8] // premultiplied RGBA8
        var kittyID: UInt32? = nil // set for kitty-protocol placements
    }

    private var images: [ImagePlacement] = []
    private var nextImageID: UInt64 = 1
    private var cellPxW: CGFloat = 8 // device px, set by the view
    private var cellPxH: CGFloat = 16

    // kitty graphics protocol state
    private var apcBuf: [UInt8] = []
    private var kittyStore: [UInt32: (w: Int, h: Int, rgba: [UInt8])] = [:]
    private var kittyStoreOrder: [UInt32] = []
    private var kittyChunks: (controls: [String: String], data: [UInt8])?

    init(cols: Int, rows: Int) {
        self.cols = max(2, cols)
        self.rows = max(2, rows)
        self.bottom = self.rows - 1
        self.scrollback = RowRing(capacity: Terminal.maxScrollback)
        let blank = [Cell](repeating: Cell(), count: self.cols)
        self.screen = [[Cell]](repeating: blank, count: self.rows)
        self.inactiveScreen = self.screen
        self.tabs = Terminal.defaultTabs(cols: self.cols)
    }

    private static func defaultTabs(cols: Int) -> [Bool] {
        var t = [Bool](repeating: false, count: cols)
        var i = 8
        while i < cols {
            t[i] = true
            i += 8
        }
        return t
    }

    // MARK: - thread-safe accessors

    var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    var applicationCursorKeys: Bool {
        lock.lock()
        defer { lock.unlock() }
        return appCursor
    }

    var bracketedPasteEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return bracketedPaste
    }

    /// Current mouse reporting mode for the view: (mode, sgrEncoding).
    var mouseReporting: (mode: Int, sgr: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (mouseMode, mouseSGR)
    }

    /// Full reset (context-menu Reset Terminal).
    func hardReset() {
        lock.lock()
        fullReset()
        generation &+= 1
        lock.unlock()
        onChange?()
    }

    /// Force a redraw (resize, focus changes, ...).
    func touch() {
        lock.lock()
        generation &+= 1
        lock.unlock()
        onChange?()
    }

    /// Called on user keystrokes: snap the viewport back to the live screen
    /// and drop any selection.
    func userDidInput() {
        lock.lock()
        let changed = viewOffset != 0 || selAnchor != nil
        viewOffset = 0
        selAnchor = nil
        selHead = nil
        if changed { generation &+= 1 }
        lock.unlock()
        if changed { onChange?() }
    }

    /// Scroll the viewport into history. Positive = older lines.
    func scrollViewport(by lines: Int) {
        lock.lock()
        let old = viewOffset
        viewOffset = min(max(0, viewOffset + lines), usingAlt ? 0 : scrollback.count)
        let changed = viewOffset != old
        if changed { generation &+= 1 }
        lock.unlock()
        if changed { onChange?() }
    }

    // MARK: - feed (PTY read thread)

    func feed(_ buf: UnsafePointer<UInt8>, _ count: Int) {
        lock.lock()
        var i = 0
        while i < count {
            let b = buf[i]
            // Fast path: in ground state, blit whole printable-ASCII runs
            // into the row instead of stepping the state machine per byte.
            if b >= 0x20 && b < 0x7F && pstate == .ground && utf8Needed == 0 {
                var end = i + 1
                while end < count {
                    let c = buf[end]
                    if c < 0x20 || c >= 0x7F { break }
                    end += 1
                }
                putASCIIRun(buf + i, end - i)
                i = end
            } else {
                process(b)
                i += 1
            }
        }
        generation &+= 1
        let out = pendingOutput
        pendingOutput.removeAll(keepingCapacity: true)
        let title = pendingTitle
        pendingTitle = nil
        let bell = pendingBell
        pendingBell = false
        let markerEvents = pendingMarkers
        pendingMarkers.removeAll(keepingCapacity: true)
        lock.unlock()

        if !out.isEmpty { onOutput?(out) }
        if let t = title { onTitle?(t) }
        if bell { onBell?() }
        for (kind, exit) in markerEvents { onMarker?(kind, exit) }
        onChange?()
    }

    // MARK: - snapshot (render thread)

    @discardableResult
    func copySnapshot(into snap: inout TermSnapshot) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        snap.cols = cols
        snap.rows = rows
        let needed = cols * rows
        if snap.cells.count != needed {
            snap.cells = [Cell](repeating: Cell(), count: needed)
        }
        let offset = viewOffset
        let sbCount = scrollback.count
        let selection = normalizedSelection
        for r in 0..<rows {
            let srcRow: [Cell]
            if r < offset {
                srcRow = scrollback[sbCount - offset + r]
            } else {
                srcRow = screen[r - offset]
            }
            let base = r * cols
            let n = min(cols, srcRow.count)
            for c in 0..<n { snap.cells[base + c] = srcRow[c] }
            if n < cols {
                for c in n..<cols { snap.cells[base + c] = Cell() }
            }

            let abs = sbAppended - offset + r
            if let (s, e) = selection, abs >= s.line, abs <= e.line {
                let lo = abs == s.line ? min(s.col, cols - 1) : 0
                let hi = abs == e.line ? min(e.col, cols - 1) : cols - 1
                if lo <= hi {
                    for c in lo...hi { snap.cells[base + c].flags |= CellFlags.selected }
                }
            }
            if let link = linkRange, link.line == abs {
                let lo = min(max(link.lo, 0), cols - 1)
                let hi = min(max(link.hi, lo), cols - 1)
                for c in lo...hi { snap.cells[base + c].flags |= CellFlags.underline }
            }
        }
        snap.cursorX = min(cx, cols - 1)
        let viewY = cy + offset
        snap.cursorY = viewY
        snap.cursorVisible = cursorVisible && viewY < rows
        snap.scrolledBack = offset > 0

        snap.images.removeAll(keepingCapacity: true)
        if !images.isEmpty && !usingAlt {
            let viewTopAbs = sbAppended - offset
            for img in images {
                let viewRow = img.absLine - viewTopAbs
                guard viewRow + img.cellRows > 0, viewRow < rows else { continue }
                snap.images.append(SnapImage(
                    id: img.id, viewRow: viewRow, col: img.col,
                    cellCols: img.cellCols, cellRows: img.cellRows
                ))
            }
        }
        return generation
    }

    // MARK: - resize

    func resize(cols newCols: Int, rows newRows: Int) {
        let nc = max(2, newCols)
        let nr = max(2, newRows)
        lock.lock()
        defer {
            generation &+= 1
            lock.unlock()
        }
        guard nc != cols || nr != rows else { return }

        func adjust(_ grid: inout [[Cell]], keepHistory: Bool) {
            for i in 0..<grid.count {
                if grid[i].count > nc {
                    grid[i].removeLast(grid[i].count - nc)
                } else if grid[i].count < nc {
                    grid[i].append(contentsOf: [Cell](repeating: Cell(), count: nc - grid[i].count))
                }
            }
            if grid.count > nr {
                let excess = grid.count - nr
                // Drop from the top when the cursor would fall off the bottom,
                // preserving history; otherwise trim blank space at the bottom.
                if cy >= nr {
                    for _ in 0..<excess {
                        let row = grid.removeFirst()
                        if keepHistory {
                            scrollback.append(row)
                            sbAppended += 1
                        }
                    }
                } else {
                    grid.removeLast(excess)
                }
            } else if grid.count < nr {
                let blank = [Cell](repeating: Cell(), count: nc)
                grid.append(contentsOf: [[Cell]](repeating: blank, count: nr - grid.count))
            }
        }

        adjust(&screen, keepHistory: !usingAlt)
        adjust(&inactiveScreen, keepHistory: false)

        if cy >= nr { cy = nr - 1 }
        cols = nc
        rows = nr
        top = 0
        bottom = nr - 1
        cx = min(cx, nc - 1)
        wrapPending = false
        tabs = Terminal.defaultTabs(cols: nc)
        viewOffset = min(viewOffset, scrollback.count)
    }

    // MARK: - byte processing (lock held)

    private func process(_ b: UInt8) {
        // UTF-8 continuation handling first (only reachable from ground).
        if utf8Needed > 0 {
            if b & 0xC0 == 0x80 {
                utf8Value = (utf8Value << 6) | UInt32(b & 0x3F)
                utf8Needed -= 1
                if utf8Needed == 0 {
                    // Reject overlong encodings, UTF-16 surrogates, and
                    // scalars beyond U+10FFFF.
                    if utf8Value < utf8Min
                        || (utf8Value >= 0xD800 && utf8Value <= 0xDFFF)
                        || utf8Value > 0x10FFFF {
                        putScalar(0xFFFD)
                    } else {
                        putScalar(utf8Value)
                    }
                }
            } else {
                utf8Needed = 0
                putScalar(0xFFFD)
                process(b)
            }
            return
        }

        switch pstate {
        case .ground:
            if b >= 0x20 && b < 0x7F {
                putScalar(UInt32(b))
            } else if b == 0x1B {
                pstate = .esc
            } else if b < 0x20 {
                execC0(b)
            } else if b == 0x7F {
                // ignore
            } else {
                startUTF8(b)
            }

        case .esc:
            switch b {
            case UInt8(ascii: "["):
                csiParams.removeAll(keepingCapacity: true)
                csiColon.removeAll(keepingCapacity: true)
                csiNextColon = false
                csiCur = 0
                csiHasCur = false
                csiMarker = 0
                csiInter = 0
                pstate = .csi
            case UInt8(ascii: "]"):
                oscBuf.removeAll(keepingCapacity: true)
                pstate = .osc
            case UInt8(ascii: "_"): // APC: kitty graphics
                apcBuf.removeAll(keepingCapacity: true)
                pstate = .apc
            case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"):
                pstate = .str
            case 0x20...0x2F:
                escInterByte = b
                pstate = .escInter
            case 0x1B:
                pstate = .esc
            default:
                escDispatch(inter: 0, final: b)
                pstate = .ground
            }

        case .escInter:
            if b >= 0x30 && b <= 0x7E {
                escDispatch(inter: escInterByte, final: b)
                pstate = .ground
            } else if b >= 0x20 && b <= 0x2F {
                escInterByte = b // keep last
            } else if b == 0x1B {
                pstate = .esc
            } else {
                pstate = .ground
            }

        case .csi:
            switch b {
            case 0x30...0x39: // digit
                csiCur = min(csiCur * 10 + Int(b - 0x30), 65535)
                csiHasCur = true
            case UInt8(ascii: ";"), UInt8(ascii: ":"):
                csiParams.append(csiHasCur ? csiCur : 0)
                csiColon.append(csiNextColon)
                csiNextColon = b == UInt8(ascii: ":")
                csiCur = 0
                csiHasCur = false
            case 0x3C...0x3F: // < = > ?
                csiMarker = b
            case 0x20...0x2F:
                csiInter = b
            case 0x40...0x7E:
                if csiHasCur || !csiParams.isEmpty {
                    csiParams.append(csiHasCur ? csiCur : 0)
                    csiColon.append(csiNextColon)
                }
                csiDispatch(final: b)
                pstate = .ground
            case 0x1B:
                pstate = .esc
            case 0x00..<0x20:
                execC0(b)
            default:
                break // 0x7F ignored
            }

        case .osc:
            if b == 0x07 {
                oscDispatch()
                pstate = .ground
            } else if b == 0x1B {
                pstate = .oscEsc
            } else if oscBuf.count < 8192 {
                oscBuf.append(b)
            } else if oscBuf.count < 16_777_216,
                      oscBuf.count >= 5,
                      oscBuf[0] == UInt8(ascii: "1"), oscBuf[1] == UInt8(ascii: "3"),
                      oscBuf[2] == UInt8(ascii: "3"), oscBuf[3] == UInt8(ascii: "7") {
                oscBuf.append(b) // inline image payloads are large
            }

        case .oscEsc:
            if b == UInt8(ascii: "\\") {
                oscDispatch()
                pstate = .ground
            } else {
                oscDispatch()
                pstate = .esc
                process(b)
            }

        case .str:
            if b == 0x1B {
                pstate = .strEsc
            } else if b == 0x07 {
                pstate = .ground
            }

        case .strEsc:
            pstate = b == UInt8(ascii: "\\") ? .ground : .str

        case .apc:
            if b == 0x1B {
                pstate = .apcEsc
            } else if apcBuf.count < 16_777_216 {
                apcBuf.append(b)
            }

        case .apcEsc:
            if b == UInt8(ascii: "\\") {
                apcDispatch()
                pstate = .ground
            } else {
                apcBuf.removeAll(keepingCapacity: true)
                pstate = .esc
                process(b)
            }
        }
    }

    private func startUTF8(_ b: UInt8) {
        switch b {
        case 0xC2...0xDF:
            utf8Value = UInt32(b & 0x1F)
            utf8Needed = 1
            utf8Min = 0x80
        case 0xE0...0xEF:
            utf8Value = UInt32(b & 0x0F)
            utf8Needed = 2
            utf8Min = 0x800
        case 0xF0...0xF4:
            utf8Value = UInt32(b & 0x07)
            utf8Needed = 3
            utf8Min = 0x10000
        default:
            putScalar(0xFFFD) // 0xC0/0xC1 overlong starters land here too
        }
    }

    // MARK: - C0 controls

    private func execC0(_ b: UInt8) {
        switch b {
        case 0x07:
            pendingBell = true
        case 0x08:
            wrapPending = false
            if cx > 0 { cx -= 1 }
        case 0x09:
            wrapPending = false
            var x = cx + 1
            while x < cols - 1 && !tabs[x] { x += 1 }
            cx = min(x, cols - 1)
        case 0x0A, 0x0B, 0x0C:
            lineFeed()
        case 0x0D:
            cx = 0
            wrapPending = false
        case 0x0E:
            activeCharset = 1
        case 0x0F:
            activeCharset = 0
        default:
            break
        }
    }

    // MARK: - printing

    private static let decGraphics: [UInt32] = [
        0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, 0x00B1,
        0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C, 0x23BA,
        0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534, 0x252C,
        0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7,
    ]

    @inline(__always)
    private func charWidth(_ u: UInt32) -> Int {
        if u < 0x0300 { return 1 }
        // combining marks
        if (u >= 0x0300 && u <= 0x036F) || (u >= 0x1AB0 && u <= 0x1AFF)
            || (u >= 0x1DC0 && u <= 0x1DFF) || (u >= 0x20D0 && u <= 0x20FF)
            || (u >= 0xFE20 && u <= 0xFE2F) || u == 0x200B || u == 0xFEFF {
            return 0
        }
        // wide (East Asian W/F + emoji)
        if (u >= 0x1100 && u <= 0x115F) || (u >= 0x2E80 && u <= 0x303E)
            || (u >= 0x3041 && u <= 0x33FF) || (u >= 0x3400 && u <= 0x4DBF)
            || (u >= 0x4E00 && u <= 0x9FFF) || (u >= 0xA000 && u <= 0xA4CF)
            || (u >= 0xAC00 && u <= 0xD7A3) || (u >= 0xF900 && u <= 0xFAFF)
            || (u >= 0xFE30 && u <= 0xFE4F) || (u >= 0xFF00 && u <= 0xFF60)
            || (u >= 0xFFE0 && u <= 0xFFE6) || (u >= 0x1F300 && u <= 0x1F64F)
            || (u >= 0x1F680 && u <= 0x1F6FF) || (u >= 0x1F900 && u <= 0x1F9FF)
            || (u >= 0x1FA70 && u <= 0x1FAFF) || (u >= 0x20000 && u <= 0x3FFFD) {
            return 2
        }
        return 1
    }

    private func putScalar(_ u: UInt32) {
        var ch = u
        if charsets[activeCharset] && ch >= 0x60 && ch <= 0x7E {
            ch = Terminal.decGraphics[Int(ch - 0x60)]
        }
        let w = charWidth(ch)
        if w == 0 { return } // combining marks dropped in v1

        if wrapPending {
            wrapPending = false
            if autowrap {
                cx = 0
                lineFeed()
            }
        }
        if cx + w > cols {
            if autowrap {
                cx = 0
                lineFeed()
            } else {
                cx = max(cols - w, 0)
            }
        }

        if insertMode {
            let shift = w
            var row = screen[cy]
            row.removeLast(shift)
            row.insert(contentsOf: [Cell](repeating: blankCell(), count: shift), at: cx)
            screen[cy] = row
        }

        normalizeWideBoundaries(row: cy, lo: cx, hi: min(cx + w - 1, cols - 1))
        var cell = Cell(glyph: ch, fg: pen.fg, bg: pen.bg, flags: pen.flags)
        if w == 2 { cell.flags |= CellFlags.wide }
        screen[cy][cx] = cell
        if w == 2 && cx + 1 < cols {
            var cont = Cell(glyph: 0, fg: pen.fg, bg: pen.bg, flags: pen.flags)
            cont.flags |= CellFlags.wideContinuation
            screen[cy][cx + 1] = cont
        }

        if cx + w >= cols {
            cx = cols - 1
            wrapPending = true
        } else {
            cx += w
        }
    }

    /// Bulk write of printable ASCII. Falls back to putScalar when the
    /// active charset or insert mode changes per-cell semantics.
    private func putASCIIRun(_ p: UnsafePointer<UInt8>, _ n: Int) {
        if charsets[activeCharset] || insertMode {
            for k in 0..<n { putScalar(UInt32(p[k])) }
            return
        }
        let fg = pen.fg
        let bg = pen.bg
        let flags = pen.flags
        var k = 0
        while k < n {
            if wrapPending {
                wrapPending = false
                if autowrap {
                    cx = 0
                    lineFeed()
                }
            }
            let take = min(cols - cx, n - k)
            let x = cx
            normalizeWideBoundaries(row: cy, lo: x, hi: x + take - 1)
            screen[cy].withUnsafeMutableBufferPointer { row in
                for j in 0..<take {
                    row[x + j] = Cell(glyph: UInt32(p[k + j]), fg: fg, bg: bg, flags: flags)
                }
            }
            cx += take
            k += take
            if cx >= cols {
                cx = cols - 1
                wrapPending = true
            }
        }
    }

    // MARK: - grid primitives

    @inline(__always)
    private func blankCell() -> Cell {
        // BCE: erased cells take the current background.
        Cell(glyph: 0, fg: pen.fg, bg: pen.bg, flags: 0)
    }

    /// Before mutating columns [lo...hi] of a row, dissolve any wide pair
    /// that straddles a boundary so no orphan half survives.
    private func normalizeWideBoundaries(row y: Int, lo: Int, hi: Int) {
        if lo > 0 && lo < cols,
           screen[y][lo].flags & CellFlags.wideContinuation != 0 {
            screen[y][lo - 1] = blankCell()
        }
        if hi + 1 < cols,
           screen[y][hi].flags & CellFlags.wide != 0 {
            screen[y][hi + 1] = blankCell()
        }
    }

    private func blankRow() -> [Cell] {
        [Cell](repeating: blankCell(), count: cols)
    }

    private func lineFeed() {
        wrapPending = false
        if cy == bottom {
            scrollUp(1)
        } else if cy < rows - 1 {
            cy += 1
        }
    }

    private func reverseIndex() {
        wrapPending = false
        if cy == top {
            scrollDown(1)
        } else if cy > 0 {
            cy -= 1
        }
    }

    private func scrollUp(_ n: Int) {
        let count = min(n, bottom - top + 1)
        for _ in 0..<count {
            let row = screen.remove(at: top)
            if top == 0 && !usingAlt {
                scrollback.append(row)
                sbAppended += 1
                if viewOffset > 0 {
                    viewOffset = min(viewOffset + 1, scrollback.count)
                }
            }
            screen.insert(blankRow(), at: bottom)
        }
    }

    private func scrollDown(_ n: Int) {
        let count = min(n, bottom - top + 1)
        for _ in 0..<count {
            screen.remove(at: bottom)
            screen.insert(blankRow(), at: top)
        }
    }

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            if cy + 1 < rows {
                for y in (cy + 1)..<rows { screen[y] = blankRow() }
            }
        case 1:
            eraseInLine(1)
            for y in 0..<cy { screen[y] = blankRow() }
        case 2:
            for y in 0..<rows { screen[y] = blankRow() }
        case 3:
            scrollback.removeAll()
            viewOffset = 0
            images.removeAll()
        default:
            break
        }
    }

    private func eraseInLine(_ mode: Int) {
        let blank = blankCell()
        switch mode {
        case 0:
            normalizeWideBoundaries(row: cy, lo: cx, hi: cols - 1)
            for x in cx..<cols { screen[cy][x] = blank }
        case 1:
            let hi = min(cx, cols - 1)
            normalizeWideBoundaries(row: cy, lo: 0, hi: hi)
            for x in 0...hi { screen[cy][x] = blank }
        case 2:
            screen[cy] = blankRow()
        default:
            break
        }
    }

    // MARK: - ESC dispatch

    private func escDispatch(inter: UInt8, final: UInt8) {
        if inter == UInt8(ascii: "(") || inter == UInt8(ascii: ")") {
            let g = inter == UInt8(ascii: "(") ? 0 : 1
            charsets[g] = final == UInt8(ascii: "0")
            return
        }
        if inter == UInt8(ascii: "#") {
            if final == UInt8(ascii: "8") { // DECALN
                let fill = Cell(glyph: UInt32(UInt8(ascii: "E")), fg: ColorCode.defaultFG, bg: ColorCode.defaultBG, flags: 0)
                for y in 0..<rows { screen[y] = [Cell](repeating: fill, count: cols) }
                cx = 0
                cy = 0
                top = 0
                bottom = rows - 1
            }
            return
        }
        guard inter == 0 else { return }
        switch final {
        case UInt8(ascii: "7"):
            saveCursor()
        case UInt8(ascii: "8"):
            restoreCursor()
        case UInt8(ascii: "D"):
            lineFeed()
        case UInt8(ascii: "E"):
            cx = 0
            lineFeed()
        case UInt8(ascii: "H"):
            if cx < cols { tabs[cx] = true }
        case UInt8(ascii: "M"):
            reverseIndex()
        case UInt8(ascii: "c"):
            fullReset()
        case UInt8(ascii: "="), UInt8(ascii: ">"):
            break // keypad modes
        default:
            break
        }
    }

    private func saveCursor() {
        var s = SavedCursor()
        s.x = cx
        s.y = cy
        s.pen = pen
        s.originMode = originMode
        s.activeCharset = activeCharset
        s.charsets = charsets
        if usingAlt { savedAlt = s } else { savedMain = s }
    }

    private func restoreCursor() {
        let s = usingAlt ? savedAlt : savedMain
        cx = min(s.x, cols - 1)
        cy = min(s.y, rows - 1)
        pen = s.pen
        originMode = s.originMode
        activeCharset = s.activeCharset
        charsets = s.charsets
        wrapPending = false
    }

    private func fullReset() {
        pen = Pen()
        cx = 0
        cy = 0
        top = 0
        bottom = rows - 1
        autowrap = true
        insertMode = false
        originMode = false
        cursorVisible = true
        appCursor = false
        bracketedPaste = false
        wrapPending = false
        mouseMode = 0
        mouseSGR = false
        charsets = [false, false]
        activeCharset = 0
        tabs = Terminal.defaultTabs(cols: cols)
        for y in 0..<rows { screen[y] = blankRow() }
        if usingAlt { switchScreen(toAlt: false) }
        viewOffset = 0
        images.removeAll()
    }

    // MARK: - CSI dispatch

    @inline(__always)
    private func p(_ i: Int, _ def: Int) -> Int {
        guard i < csiParams.count, csiParams[i] != 0 else { return def }
        return csiParams[i]
    }

    private func csiDispatch(final: UInt8) {
        if csiMarker == UInt8(ascii: "?") {
            switch final {
            case UInt8(ascii: "h"):
                for v in (csiParams.isEmpty ? [0] : csiParams) { setPrivateMode(v, true) }
            case UInt8(ascii: "l"):
                for v in (csiParams.isEmpty ? [0] : csiParams) { setPrivateMode(v, false) }
            default:
                break
            }
            return
        }
        if csiMarker == UInt8(ascii: ">") {
            if final == UInt8(ascii: "c") {
                emit("\u{1B}[>0;100;0c")
            }
            return
        }
        guard csiMarker == 0 else { return }

        switch final {
        case UInt8(ascii: "@"): // ICH
            let n = min(p(0, 1), cols - cx)
            normalizeWideBoundaries(row: cy, lo: cx, hi: cols - 1)
            var row = screen[cy]
            row.removeLast(n)
            row.insert(contentsOf: [Cell](repeating: blankCell(), count: n), at: cx)
            screen[cy] = row
        case UInt8(ascii: "A"):
            cy = max(cy - p(0, 1), originMode ? top : 0)
            wrapPending = false
        case UInt8(ascii: "B"):
            cy = min(cy + p(0, 1), originMode ? bottom : rows - 1)
            wrapPending = false
        case UInt8(ascii: "C"):
            cx = min(cx + p(0, 1), cols - 1)
            wrapPending = false
        case UInt8(ascii: "D"):
            cx = max(cx - p(0, 1), 0)
            wrapPending = false
        case UInt8(ascii: "E"):
            cy = min(cy + p(0, 1), rows - 1)
            cx = 0
            wrapPending = false
        case UInt8(ascii: "F"):
            cy = max(cy - p(0, 1), 0)
            cx = 0
            wrapPending = false
        case UInt8(ascii: "G"):
            cx = min(max(p(0, 1) - 1, 0), cols - 1)
            wrapPending = false
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            setCursor(row: p(0, 1) - 1, col: p(1, 1) - 1)
        case UInt8(ascii: "I"):
            for _ in 0..<p(0, 1) { execC0(0x09) }
        case UInt8(ascii: "J"):
            eraseInDisplay(csiParams.first ?? 0)
        case UInt8(ascii: "K"):
            eraseInLine(csiParams.first ?? 0)
        case UInt8(ascii: "L"): // IL
            if cy >= top && cy <= bottom {
                let n = min(p(0, 1), bottom - cy + 1)
                for _ in 0..<n {
                    screen.remove(at: bottom)
                    screen.insert(blankRow(), at: cy)
                }
            }
        case UInt8(ascii: "M"): // DL
            if cy >= top && cy <= bottom {
                let n = min(p(0, 1), bottom - cy + 1)
                for _ in 0..<n {
                    screen.remove(at: cy)
                    screen.insert(blankRow(), at: bottom)
                }
            }
        case UInt8(ascii: "P"): // DCH
            let n = min(p(0, 1), cols - cx)
            normalizeWideBoundaries(row: cy, lo: cx, hi: min(cx + n - 1, cols - 1))
            var row = screen[cy]
            row.removeSubrange(cx..<(cx + n))
            row.append(contentsOf: [Cell](repeating: blankCell(), count: n))
            screen[cy] = row
        case UInt8(ascii: "S"):
            scrollUp(p(0, 1))
        case UInt8(ascii: "T"):
            scrollDown(p(0, 1))
        case UInt8(ascii: "X"): // ECH
            let n = min(p(0, 1), cols - cx)
            normalizeWideBoundaries(row: cy, lo: cx, hi: min(cx + n - 1, cols - 1))
            let blank = blankCell()
            for x in cx..<(cx + n) { screen[cy][x] = blank }
        case UInt8(ascii: "Z"): // CBT
            wrapPending = false
            for _ in 0..<p(0, 1) {
                var x = cx - 1
                while x > 0 && !tabs[x] { x -= 1 }
                cx = max(x, 0)
            }
        case UInt8(ascii: "d"): // VPA
            cy = min(max(p(0, 1) - 1, 0), rows - 1)
            wrapPending = false
        case UInt8(ascii: "g"): // TBC
            if (csiParams.first ?? 0) == 3 {
                tabs = [Bool](repeating: false, count: cols)
            } else if cx < cols {
                tabs[cx] = false
            }
        case UInt8(ascii: "h"):
            for v in csiParams where v == 4 { insertMode = true }
        case UInt8(ascii: "l"):
            for v in csiParams where v == 4 { insertMode = false }
        case UInt8(ascii: "m"):
            applySGR()
        case UInt8(ascii: "n"):
            switch csiParams.first ?? 0 {
            case 5:
                emit("\u{1B}[0n")
            case 6:
                let row = cy - (originMode ? top : 0) + 1
                emit("\u{1B}[\(row);\(cx + 1)R")
            default:
                break
            }
        case UInt8(ascii: "r"): // DECSTBM
            let t = p(0, 1) - 1
            let b = p(1, rows) - 1
            if t < b && b < rows {
                top = t
                bottom = b
                setCursor(row: 0, col: 0)
            }
        case UInt8(ascii: "s"):
            saveCursor()
        case UInt8(ascii: "u"):
            restoreCursor()
        case UInt8(ascii: "c"):
            if (csiParams.first ?? 0) == 0 { emit("\u{1B}[?6c") }
        case UInt8(ascii: "q"), UInt8(ascii: "t"):
            break // cursor style / window ops: ignored
        default:
            break
        }
    }

    private func setCursor(row: Int, col: Int) {
        wrapPending = false
        if originMode {
            cy = min(max(top + row, top), bottom)
        } else {
            cy = min(max(row, 0), rows - 1)
        }
        cx = min(max(col, 0), cols - 1)
    }

    private func setPrivateMode(_ mode: Int, _ on: Bool) {
        switch mode {
        case 1:
            appCursor = on
        case 6:
            originMode = on
            setCursor(row: 0, col: 0)
        case 7:
            autowrap = on
        case 25:
            cursorVisible = on
        case 47, 1047:
            if on != usingAlt {
                switchScreen(toAlt: on)
                if on { for y in 0..<rows { screen[y] = blankRow() } }
            }
        case 1048:
            on ? saveCursor() : restoreCursor()
        case 1049:
            if on {
                if !usingAlt {
                    saveCursor()
                    switchScreen(toAlt: true)
                    for y in 0..<rows { screen[y] = blankRow() }
                    setCursor(row: 0, col: 0)
                }
            } else {
                if usingAlt {
                    switchScreen(toAlt: false)
                    restoreCursor()
                }
            }
        case 2004:
            bracketedPaste = on
        case 9, 1000, 1002, 1003:
            mouseMode = on ? mode : 0
        case 1006:
            mouseSGR = on
        default:
            break
        }
    }

    private func switchScreen(toAlt: Bool) {
        swap(&screen, &inactiveScreen)
        usingAlt = toAlt
        top = 0
        bottom = rows - 1
        if toAlt { viewOffset = 0 }
    }

    private func applySGR() {
        if csiParams.isEmpty {
            pen = Pen()
            return
        }
        let params = csiParams
        let colon = csiColon
        var i = 0
        while i < params.count {
            // Extent of this param's colon-attached subparameter group.
            var groupEnd = i + 1
            while groupEnd < params.count && groupEnd < colon.count && colon[groupEnd] {
                groupEnd += 1
            }
            let v = params[i]
            switch v {
            case 0: pen = Pen()
            case 1: pen.flags |= CellFlags.bold
            case 2: pen.flags |= CellFlags.faint
            case 3: pen.flags |= CellFlags.italic
            case 4: pen.flags |= CellFlags.underline // incl. 4:n styles
            case 7: pen.flags |= CellFlags.inverse
            case 8: pen.flags |= CellFlags.invisible
            case 9: pen.flags |= CellFlags.strikethrough
            case 22: pen.flags &= ~(CellFlags.bold | CellFlags.faint)
            case 23: pen.flags &= ~CellFlags.italic
            case 24: pen.flags &= ~CellFlags.underline
            case 27: pen.flags &= ~CellFlags.inverse
            case 28: pen.flags &= ~CellFlags.invisible
            case 29: pen.flags &= ~CellFlags.strikethrough
            case 30...37: pen.fg = ColorCode.indexed(v - 30)
            case 39: pen.fg = ColorCode.defaultFG
            case 40...47: pen.bg = ColorCode.indexed(v - 40)
            case 49: pen.bg = ColorCode.defaultBG
            case 90...97: pen.fg = ColorCode.indexed(v - 90 + 8)
            case 100...107: pen.bg = ColorCode.indexed(v - 100 + 8)
            case 38, 48, 58:
                var color: UInt32? = nil
                if groupEnd - i > 1 {
                    // Colon form: 38:5:n, 38:2:r:g:b, or 38:2:<colorspace>:r:g:b.
                    // RGB values are always the last three subparameters.
                    let sub = Array(params[(i + 1)..<groupEnd])
                    if sub[0] == 5 && sub.count >= 2 {
                        color = ColorCode.indexed(sub[1])
                    } else if sub[0] == 2 && sub.count >= 4 {
                        color = ColorCode.rgb(sub[sub.count - 3], sub[sub.count - 2], sub[sub.count - 1])
                    }
                } else if i + 1 < params.count {
                    // Legacy semicolon form consumes following params.
                    if params[i + 1] == 5 && i + 2 < params.count {
                        color = ColorCode.indexed(params[i + 2])
                        groupEnd = i + 3
                    } else if params[i + 1] == 2 && i + 4 < params.count {
                        color = ColorCode.rgb(params[i + 2], params[i + 3], params[i + 4])
                        groupEnd = i + 5
                    } else {
                        groupEnd = params.count // malformed; bail
                    }
                }
                if let c = color {
                    if v == 38 { pen.fg = c } else if v == 48 { pen.bg = c }
                    // 58 (underline color) parsed but not yet rendered
                }
            default:
                break // unknown SGR: its colon subparams are skipped via groupEnd
            }
            i = groupEnd
        }
    }

    // MARK: - OSC

    private func oscDispatch() {
        guard let sep = oscBuf.firstIndex(of: UInt8(ascii: ";")) else { return }
        let code = oscBuf[..<sep]
        guard code.count <= 4, let n = Int(String(decoding: code, as: UTF8.self)) else { return }
        switch n {
        case 0, 1, 2:
            pendingTitle = String(decoding: oscBuf[(sep + 1)...], as: UTF8.self)
        case 133:
            handleSemanticMarker(Array(oscBuf[(sep + 1)...]))
        case 1337:
            handleITerm2Payload(Array(oscBuf[(sep + 1)...]))
        default:
            break
        }
    }

    // MARK: - OSC 1337 inline images

    private func handleITerm2Payload(_ payload: [UInt8]) {
        let filePrefix = Array("File=".utf8)
        guard payload.count > filePrefix.count,
              Array(payload[0..<filePrefix.count]) == filePrefix,
              let colon = payload.firstIndex(of: UInt8(ascii: ":")) else { return }

        var params: [String: String] = [:]
        let paramText = String(decoding: payload[filePrefix.count..<colon], as: UTF8.self)
        for pair in paramText.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { params[kv[0].lowercased()] = String(kv[1]) }
        }
        guard params["inline"] == "1" else { return }

        let base64 = Data(payload[(colon + 1)...])
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let decoded = Terminal.decodeImage(data) else { return }

        let (wCells, hCells) = imageCellSize(
            pxW: decoded.width, pxH: decoded.height,
            widthParam: params["width"], heightParam: params["height"]
        )
        images.append(ImagePlacement(
            id: nextImageID,
            absLine: sbAppended + cy,
            col: cx,
            cellCols: wCells,
            cellRows: hCells,
            pxWidth: decoded.width,
            pxHeight: decoded.height,
            rgba: decoded.rgba
        ))
        nextImageID += 1
        if images.count > 12 { images.removeFirst(images.count - 12) }

        // Cursor lands on the line after the image, column 0.
        for _ in 0..<hCells { lineFeed() }
        cx = 0
        wrapPending = false
    }

    private func imageCellSize(
        pxW: Int, pxH: Int, widthParam: String?, heightParam: String?
    ) -> (Int, Int) {
        func cells(_ param: String?, perCell: CGFloat, total: Int, px: Int) -> Int? {
            guard var p = param?.lowercased(), p != "auto" else { return nil }
            if p.hasSuffix("px") {
                p.removeLast(2)
                guard let v = Double(p) else { return nil }
                return Int(ceil(CGFloat(v) / perCell))
            }
            if p.hasSuffix("%") {
                p.removeLast()
                guard let v = Double(p) else { return nil }
                return Int(ceil(CGFloat(total) * CGFloat(v) / 100))
            }
            return Int(p)
        }

        var w = cells(widthParam, perCell: cellPxW, total: cols, px: pxW)
        var h = cells(heightParam, perCell: cellPxH, total: rows, px: pxH)
        let aspect = CGFloat(pxH) / CGFloat(max(pxW, 1))
        if w == nil && h == nil {
            w = min(Int(ceil(CGFloat(pxW) / cellPxW)), cols)
        }
        if let wv = w, h == nil {
            let widthPx = CGFloat(wv) * cellPxW
            h = Int(ceil(widthPx * aspect / cellPxH))
        } else if let hv = h, w == nil {
            let heightPx = CGFloat(hv) * cellPxH
            w = Int(ceil(heightPx / aspect / cellPxW))
        }
        return (min(max(w ?? 1, 1), cols), min(max(h ?? 1, 1), 200))
    }

    /// Decode any ImageIO-supported format into premultiplied RGBA8,
    /// downscaling to at most 2048 on the long edge.
    private static func decodeImage(_ data: Data) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var w = image.width
        var h = image.height
        let maxEdge = 2048
        if max(w, h) > maxEdge {
            let scale = CGFloat(maxEdge) / CGFloat(max(w, h))
            w = max(Int(CGFloat(w) * scale), 1)
            h = max(Int(CGFloat(h) * scale), 1)
        }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (w, h, rgba) : nil
    }

    // MARK: - kitty graphics protocol (APC _G ... ST)

    private func apcDispatch() {
        guard apcBuf.first == UInt8(ascii: "G") else {
            apcBuf.removeAll(keepingCapacity: true)
            return
        }
        let body = apcBuf.dropFirst()
        apcBuf.removeAll(keepingCapacity: true)

        var controls: [String: String] = [:]
        var payload: [UInt8] = []
        if let semi = body.firstIndex(of: UInt8(ascii: ";")) {
            payload = Array(body[(semi + 1)...])
            parseKittyControls(String(decoding: body[..<semi], as: UTF8.self), into: &controls)
        } else {
            parseKittyControls(String(decoding: body, as: UTF8.self), into: &controls)
        }

        // Chunked transmissions: m=1 accumulates; controls come from chunk 1.
        if controls["m"] == "1" {
            if kittyChunks == nil {
                kittyChunks = (controls, payload)
            } else {
                kittyChunks?.data.append(contentsOf: payload)
            }
            return
        }
        if var pending = kittyChunks {
            pending.data.append(contentsOf: payload)
            kittyChunks = nil
            handleKitty(controls: pending.controls, payload: pending.data)
        } else {
            handleKitty(controls: controls, payload: payload)
        }
    }

    private func parseKittyControls(_ text: String, into dict: inout [String: String]) {
        for pair in text.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
        }
    }

    private func kittyRespond(_ controls: [String: String], _ message: String) {
        let quiet = Int(controls["q"] ?? "0") ?? 0
        if message == "OK" && quiet >= 1 { return }
        if message != "OK" && quiet >= 2 { return }
        var idPart = "i=\(controls["i"] ?? "0")"
        if let num = controls["I"] { idPart += ",I=\(num)" }
        emit("\u{1B}_G\(idPart);\(message)\u{1B}\\")
    }

    private func handleKitty(controls: [String: String], payload: [UInt8]) {
        let action = controls["a"] ?? "t"
        switch action {
        case "q":
            // capability probe (kitten icat does this before sending)
            kittyRespond(controls, decodeKittyPixels(controls, payload) != nil ? "OK" : "EINVAL")
        case "t", "T":
            guard let decoded = decodeKittyPixels(controls, payload) else {
                kittyRespond(controls, "EINVAL:could not decode image")
                return
            }
            let id = UInt32(controls["i"] ?? "") ?? 0
            if id != 0 {
                if kittyStore[id] == nil { kittyStoreOrder.append(id) }
                kittyStore[id] = decoded
                while kittyStoreOrder.count > 8 {
                    kittyStore.removeValue(forKey: kittyStoreOrder.removeFirst())
                }
            }
            if action == "T" {
                placeKittyImage(decoded, controls: controls, kittyID: id)
            }
            if controls["i"] != nil { kittyRespond(controls, "OK") }
        case "p":
            guard let id = UInt32(controls["i"] ?? ""), let stored = kittyStore[id] else {
                kittyRespond(controls, "ENOENT:no such image")
                return
            }
            placeKittyImage(stored, controls: controls, kittyID: id)
            kittyRespond(controls, "OK")
        case "d":
            let what = controls["d"] ?? "a"
            switch what.lowercased() {
            case "i":
                if let id = UInt32(controls["i"] ?? "") {
                    images.removeAll { $0.kittyID == id }
                    kittyStore.removeValue(forKey: id)
                    kittyStoreOrder.removeAll { $0 == id }
                }
            default:
                images.removeAll { $0.kittyID != nil }
            }
        default:
            kittyRespond(controls, "EINVAL:unsupported action")
        }
    }

    private func placeKittyImage(
        _ decoded: (w: Int, h: Int, rgba: [UInt8]), controls: [String: String], kittyID: UInt32
    ) {
        var wCells = Int(controls["c"] ?? "") ?? 0
        var hCells = Int(controls["r"] ?? "") ?? 0
        if wCells <= 0 && hCells <= 0 {
            (wCells, hCells) = imageCellSize(
                pxW: decoded.w, pxH: decoded.h, widthParam: nil, heightParam: nil)
        } else if wCells <= 0 {
            (wCells, _) = imageCellSize(
                pxW: decoded.w, pxH: decoded.h, widthParam: nil, heightParam: "\(hCells)")
        } else if hCells <= 0 {
            (_, hCells) = imageCellSize(
                pxW: decoded.w, pxH: decoded.h, widthParam: "\(wCells)", heightParam: nil)
        }
        wCells = min(max(wCells, 1), cols)
        hCells = min(max(hCells, 1), 200)

        images.append(ImagePlacement(
            id: nextImageID, absLine: sbAppended + cy, col: cx,
            cellCols: wCells, cellRows: hCells,
            pxWidth: decoded.w, pxHeight: decoded.h, rgba: decoded.rgba,
            kittyID: kittyID == 0 ? UInt32.max : kittyID
        ))
        nextImageID += 1
        if images.count > 24 { images.removeFirst(images.count - 24) }

        // C=1: app manages the cursor itself (yazi, chafa placements).
        if controls["C"] != "1" {
            for _ in 0..<hCells { lineFeed() }
            cx = 0
            wrapPending = false
        }
    }

    /// Decode a kitty payload into premultiplied RGBA8.
    private func decodeKittyPixels(
        _ controls: [String: String], _ payload: [UInt8]
    ) -> (w: Int, h: Int, rgba: [UInt8])? {
        // Transmission medium
        var data: Data
        switch controls["t"] ?? "d" {
        case "d":
            guard let d = Data(base64Encoded: Data(payload), options: .ignoreUnknownCharacters) else {
                return nil
            }
            data = d
        case "f", "t":
            guard let pathData = Data(base64Encoded: Data(payload), options: .ignoreUnknownCharacters),
                  let path = String(data: pathData, encoding: .utf8) else { return nil }
            // kitty's own safety rule: only obvious temp locations.
            let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
            guard path.contains("tty-graphics-protocol")
                || path.hasPrefix("/tmp/") || path.hasPrefix(tmpdir)
                || path.hasPrefix("/private/tmp/") || path.hasPrefix("/private/var/folders/") else {
                return nil
            }
            guard let d = FileManager.default.contents(atPath: path), d.count <= 33_554_432 else {
                return nil
            }
            if controls["t"] == "t" { try? FileManager.default.removeItem(atPath: path) }
            data = d
        default:
            return nil
        }

        let format = Int(controls["f"] ?? "32") ?? 32
        if format == 100 {
            guard let img = Terminal.decodeImage(data) else { return nil }
            return (img.width, img.height, img.rgba)
        }

        guard format == 24 || format == 32,
              let w = Int(controls["s"] ?? ""), let h = Int(controls["v"] ?? ""),
              w > 0, h > 0, w * h <= 8_388_608 else { return nil }
        let bpp = format == 24 ? 3 : 4

        if controls["o"] == "z" {
            guard let inflated = Terminal.inflateZlib(data, expected: w * h * bpp) else { return nil }
            data = inflated
        }
        guard data.count >= w * h * bpp else { return nil }

        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let s = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<(w * h) {
                let r = s[i * bpp]
                let g = s[i * bpp + 1]
                let b = s[i * bpp + 2]
                let a = bpp == 4 ? s[i * bpp + 3] : 255
                // premultiply for the sprite pipeline
                rgba[i * 4] = UInt8(Int(r) * Int(a) / 255)
                rgba[i * 4 + 1] = UInt8(Int(g) * Int(a) / 255)
                rgba[i * 4 + 2] = UInt8(Int(b) * Int(a) / 255)
                rgba[i * 4 + 3] = a
            }
        }
        return (w, h, rgba)
    }

    /// RFC1950 zlib payload -> raw bytes (strip header/adler, raw DEFLATE).
    private static func inflateZlib(_ data: Data, expected: Int) -> Data? {
        guard data.count > 6, expected > 0, expected <= 33_554_432 else { return nil }
        let deflate = data.dropFirst(2).dropLast(4)
        var out = Data(count: expected)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            deflate.withUnsafeBytes { src -> Int in
                compression_decode_buffer(
                    dst.baseAddress!.assumingMemoryBound(to: UInt8.self), expected,
                    src.baseAddress!.assumingMemoryBound(to: UInt8.self), deflate.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expected else { return nil }
        return out
    }

    /// Cell pixel metrics from the renderer (for image sizing).
    func setCellPixelSize(width: CGFloat, height: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        cellPxW = max(width, 1)
        cellPxH = max(height, 1)
    }

    /// Image pixels for the renderer's texture cache.
    func imageData(id: UInt64) -> (width: Int, height: Int, rgba: [UInt8])? {
        lock.lock()
        defer { lock.unlock() }
        guard let img = images.first(where: { $0.id == id }) else { return nil }
        return (img.pxWidth, img.pxHeight, img.rgba)
    }

    // OSC 133 semantic prompts: A = prompt start, B = input start,
    // C = command output start, D;<exit> = command finished.
    private func handleSemanticMarker(_ payload: [UInt8]) {
        guard !usingAlt, let kind = payload.first else { return }
        guard kind == UInt8(ascii: "A") || kind == UInt8(ascii: "B")
            || kind == UInt8(ascii: "C") || kind == UInt8(ascii: "D") else { return }
        var exitCode = 0
        if kind == UInt8(ascii: "D"), payload.count > 2, payload[1] == UInt8(ascii: ";") {
            exitCode = Int(String(decoding: payload[2...], as: UTF8.self)) ?? 0
        }
        markers.append(Marker(kind: kind, line: sbAppended + cy, col: cx, exitCode: exitCode))
        pendingMarkers.append((kind, exitCode))
        if markers.count > 512 {
            markers.removeFirst(markers.count - 256)
        }

        // Auto markdown: at command completion, if the output looks like
        // markdown and is on-screen, re-render it through glow in place.
        if kind == UInt8(ascii: "D"), markdownAuto, !usingAlt {
            renderCommandOutputAsMarkdown()
        }
    }

    // MARK: - auto markdown rendering (opt-in, guarded)

    var markdownAuto = false
    var markdownCommand = "glow -p"

    private func looksLikeMarkdown(_ s: String) -> Bool {
        var score = 0
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.drop { $0 == " " }
            if t.hasPrefix("# ") || t.hasPrefix("## ") || t.hasPrefix("### ") { score += 2 }
            if t.hasPrefix("```") { score += 2 }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { score += 1 }
            if t.hasPrefix("> ") { score += 1 }
            if line.contains("**") || line.contains("__") { score += 1 }
            if score >= 3 { return true }
        }
        return false
    }

    private func renderCommandOutputAsMarkdown() {
        guard let dIdx = markers.lastIndex(where: { $0.kind == UInt8(ascii: "D") }),
              let cIdx = markers[..<dIdx].lastIndex(where: { $0.kind == UInt8(ascii: "C") })
        else { return }
        let c = markers[cIdx]
        let d = markers[dIdx]

        // Output must still be fully on-screen (not scrolled into history).
        let startRow = c.line - sbAppended
        guard startRow >= 0, startRow < rows, d.line - c.line <= 300 else { return }

        let text = textBetween(startLine: c.line, startCol: c.col, endLine: d.line, endCol: d.col)
        guard !text.isEmpty, looksLikeMarkdown(text),
              let rendered = Terminal.runGlow(markdownCommand, input: text) else { return }

        // Erase the raw output region and re-emit glow's ANSI at its start.
        // We're being called mid-OSC-dispatch, so force the parser back to
        // ground before re-feeding, else glow's bytes get eaten as OSC data.
        pstate = .ground
        cy = min(max(startRow, 0), rows - 1)
        cx = 0
        wrapPending = false
        eraseInDisplay(0)
        for b in rendered { process(b) }
    }

    /// Run the markdown command with `input` on stdin; return its ANSI stdout.
    /// Synchronous — called on the PTY read thread, bounded by a short timeout.
    private static func runGlow(_ command: String, input: String) -> [UInt8]? {
        // Drop interactive pager flags — we capture stdout, not a TTY pager.
        let parts = command.split(separator: " ").map(String.init)
            .filter { $0 != "-p" && $0 != "--pager" }
        guard let exe = parts.first else { return nil }
        let proc = Process()
        // Resolve via /usr/bin/env so PATH is respected without a login shell.
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [exe] + parts.dropFirst()
        // GUI apps inherit a minimal PATH; add the common Homebrew locations.
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = env["PATH"].map { "\(extra):\($0)" } ?? extra
        proc.environment = env
        let stdin = Pipe(), stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        stdin.fileHandleForWriting.closeFile()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, !data.isEmpty else { return nil }
        // Normalize LF -> CRLF so the terminal advances columns correctly.
        var out: [UInt8] = []
        out.reserveCapacity(data.count + 64)
        for b in data {
            if b == 0x0A { out.append(0x0D) }
            out.append(b)
        }
        return out
    }

    // MARK: - agent/tooling text extraction (control socket)

    private func rowToString(_ row: [Cell]) -> String {
        var end = row.count
        while end > 0 && (row[end - 1].glyph == 0 || row[end - 1].glyph == 0x20) { end -= 1 }
        var s = ""
        s.reserveCapacity(end)
        for i in 0..<end {
            let cell = row[i]
            if cell.flags & CellFlags.wideContinuation != 0 { continue }
            if cell.glyph == 0 {
                s.append(" ")
            } else if let us = Unicode.Scalar(cell.glyph) {
                s.unicodeScalars.append(us)
            }
        }
        return s
    }

    /// Row by absolute line number, spanning scrollback + live screen.
    private func rowAtAbsoluteLine(_ line: Int) -> [Cell]? {
        let dropped = sbAppended - scrollback.count
        let idx = line - dropped
        guard idx >= 0 else { return nil }
        if idx < scrollback.count { return scrollback[idx] }
        let screenIdx = idx - scrollback.count
        guard screenIdx < rows else { return nil }
        return screen[screenIdx]
    }

    private func textForLines(from: Int, to: Int) -> String {
        var lines: [String] = []
        for l in from..<to {
            guard let row = rowAtAbsoluteLine(l) else { continue }
            lines.append(rowToString(row))
        }
        return lines.joined(separator: "\n")
    }

    /// The visible screen as plain text.
    func screenText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return screen.map(rowToString).joined(separator: "\n")
    }

    /// The last `count` lines of scrollback + screen as plain text.
    func historyText(lines count: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        let total = scrollback.count + rows
        let dropped = sbAppended - scrollback.count
        let from = max(dropped, sbAppended + rows - count)
        return textForLines(from: from, to: dropped + total)
    }

    /// Text between two marker positions (line + column), inclusive of the
    /// start position, exclusive of the end position.
    private func textBetween(
        startLine: Int, startCol: Int, endLine: Int, endCol: Int
    ) -> String {
        guard startLine <= endLine else { return "" }
        if startLine == endLine {
            guard let row = rowAtAbsoluteLine(startLine), startCol < endCol else { return "" }
            let hi = min(endCol - 1, row.count - 1)
            guard startCol <= hi else { return "" }
            var text = ""
            for c in startCol...hi {
                let cell = row[c]
                if cell.flags & CellFlags.wideContinuation != 0 { continue }
                if cell.glyph != 0, let us = Unicode.Scalar(cell.glyph) {
                    text.unicodeScalars.append(us)
                } else {
                    text.append(" ")
                }
            }
            while text.hasSuffix(" ") { text.removeLast() }
            return text
        }
        var lines: [String] = []
        for line in startLine...endLine {
            guard let row = rowAtAbsoluteLine(line) else { continue }
            let lo = line == startLine ? startCol : 0
            let hiBound = line == endLine ? endCol - 1 : row.count - 1
            let hi = min(hiBound, row.count - 1)
            var text = ""
            if lo <= hi {
                for c in lo...hi {
                    let cell = row[c]
                    if cell.flags & CellFlags.wideContinuation != 0 { continue }
                    if cell.glyph != 0, let us = Unicode.Scalar(cell.glyph) {
                        text.unicodeScalars.append(us)
                    } else {
                        text.append(" ")
                    }
                }
                while text.hasSuffix(" ") { text.removeLast() }
            }
            if line == endLine && text.isEmpty { continue } // cursor at col 0 of a fresh line
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    /// Output of the most recently completed command (needs OSC 133 shell
    /// integration). Returns nil when no completed command is known.
    func lastCommandOutput() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let dIdx = markers.lastIndex(where: { $0.kind == UInt8(ascii: "D") }) else { return nil }
        let d = markers[dIdx]
        guard let cIdx = markers[..<dIdx].lastIndex(where: { $0.kind == UInt8(ascii: "C") }) else { return nil }
        let c = markers[cIdx]
        return textBetween(startLine: c.line, startCol: c.col, endLine: d.line, endCol: d.col)
    }

    /// Exit code of the most recently completed command, if known.
    func lastExitCode() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return markers.last(where: { $0.kind == UInt8(ascii: "D") })?.exitCode
    }

    /// The most recent command line(s) as typed (between input start and
    /// output start markers). Includes the prompt text.
    func lastCommandLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let cIdx = markers.lastIndex(where: { $0.kind == UInt8(ascii: "C") }) else { return nil }
        let c = markers[cIdx]
        let startKinds: Set<UInt8> = [UInt8(ascii: "B"), UInt8(ascii: "A")]
        guard let sIdx = markers[..<cIdx].lastIndex(where: { startKinds.contains($0.kind) }) else { return nil }
        let s = markers[sIdx]
        return textForLines(from: s.line, to: max(c.line, s.line + 1))
    }

    private func emit(_ s: String) {
        pendingOutput.append(contentsOf: Array(s.utf8))
    }

    // MARK: - selection API (called from the view)

    @inline(__always)
    private func absLineLocked(forViewRow r: Int) -> Int {
        sbAppended - viewOffset + r
    }

    private static let wordChars = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_-./~:@?&=%#+"))

    private func rowChars(absLine: Int) -> [Character]? {
        guard let row = rowAtAbsoluteLine(absLine) else { return nil }
        var chars = [Character](repeating: " ", count: cols)
        for c in 0..<min(cols, row.count) {
            let cell = row[c]
            if cell.glyph != 0, cell.flags & CellFlags.wideContinuation == 0,
               let us = Unicode.Scalar(cell.glyph) {
                chars[c] = Character(us)
            }
        }
        return chars
    }

    func selectionBegin(viewRow: Int, col: Int, mode: SelectionMode) {
        lock.lock()
        defer {
            generation &+= 1
            lock.unlock()
        }
        let line = absLineLocked(forViewRow: viewRow)
        let c = min(max(col, 0), cols - 1)
        selMode = mode
        switch mode {
        case .character:
            selAnchor = (line, c)
            selHead = (line, c)
        case .word:
            if let chars = rowChars(absLine: line) {
                var lo = c
                var hi = c
                func isWord(_ ch: Character) -> Bool {
                    ch.unicodeScalars.allSatisfy { Terminal.wordChars.contains($0) }
                }
                guard isWord(chars[c]) else {
                    selAnchor = (line, c)
                    selHead = (line, c)
                    return
                }
                while lo > 0 && isWord(chars[lo - 1]) { lo -= 1 }
                while hi < cols - 1 && isWord(chars[hi + 1]) { hi += 1 }
                selAnchor = (line, lo)
                selHead = (line, hi)
            }
        case .line:
            selAnchor = (line, 0)
            selHead = (line, cols - 1)
        }
    }

    func selectionExtend(viewRow: Int, col: Int) {
        lock.lock()
        defer {
            generation &+= 1
            lock.unlock()
        }
        guard selAnchor != nil else { return }
        let line = absLineLocked(forViewRow: viewRow)
        var c = min(max(col, 0), cols - 1)
        if selMode == .line { c = line >= selAnchor!.line ? cols - 1 : 0 }
        selHead = (line, c)
    }

    func clearSelection() {
        lock.lock()
        defer { lock.unlock() }
        guard selAnchor != nil else { return }
        selAnchor = nil
        selHead = nil
        generation &+= 1
    }

    private var normalizedSelection: (start: (line: Int, col: Int), end: (line: Int, col: Int))? {
        guard let a = selAnchor, let h = selHead else { return nil }
        if selMode == .character && a == h { return nil } // click, no drag
        if (h.line, h.col) < (a.line, a.col) { return (h, a) }
        return (a, h)
    }

    func selectedText() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let (s, e) = normalizedSelection else { return nil }
        var lines: [String] = []
        for line in s.line...e.line {
            guard let row = rowAtAbsoluteLine(line) else { continue }
            let lo = line == s.line ? s.col : 0
            var hi = line == e.line ? e.col : cols - 1
            hi = min(hi, row.count - 1)
            guard lo <= hi else {
                lines.append("")
                continue
            }
            var text = ""
            for c in lo...hi {
                let cell = row[c]
                if cell.flags & CellFlags.wideContinuation != 0 { continue }
                if cell.glyph != 0, let us = Unicode.Scalar(cell.glyph) {
                    text.unicodeScalars.append(us)
                } else {
                    text.append(" ")
                }
            }
            // Trim trailing padding except for a mid-line selection end.
            if line != e.line || e.col >= cols - 1 {
                while text.hasSuffix(" ") { text.removeLast() }
            }
            lines.append(text)
        }
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    // MARK: - link detection support

    /// Per-column characters of a view row (columns map 1:1).
    func lineChars(viewRow: Int) -> [Character]? {
        lock.lock()
        defer { lock.unlock() }
        guard viewRow >= 0, viewRow < rows else { return nil }
        return rowChars(absLine: absLineLocked(forViewRow: viewRow))
    }

    func setLinkHighlight(viewRow: Int, lo: Int, hi: Int) {
        lock.lock()
        defer { lock.unlock() }
        let line = absLineLocked(forViewRow: viewRow)
        if let existing = linkRange, existing == (line, lo, hi) { return }
        linkRange = (line, lo, hi)
        generation &+= 1
    }

    func clearLinkHighlight() {
        lock.lock()
        defer { lock.unlock() }
        guard linkRange != nil else { return }
        linkRange = nil
        generation &+= 1
    }
}
