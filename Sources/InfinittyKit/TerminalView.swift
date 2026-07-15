import AppKit
import QuartzCore

/// The window's content view for one pane. Owns no rendering state — it
/// translates input into PTY bytes and geometry changes into terminal/pty
/// resizes. All drawing happens on the renderer's thread via the CAMetalLayer.
final class TerminalView: NSView {
    var terminal: Terminal!
    var pty: PTY!
    var renderer: Renderer!
    var onFocus: (() -> Void)?

    private var scrollAccumulator: CGFloat = 0
    private var mouseScrollAccumulator: CGFloat = 0
    private var lastMouseCell: (Int, Int) = (-1, -1)

    private enum DragMode { case none, report, select }
    private var dragMode = DragMode.none

    // Live-resize winsize coalescing: our grid reflows and repaints every
    // frame, but the child only gets SIGWINCH at ~12 Hz plus a final one.
    private var winsizeTimer: Timer?
    private var pendingWinsize: (cols: Int, rows: Int, pw: Int, ph: Int)?

    // Agent-control glow (control-socket activity).
    private var glowView: AgentGlowView?
    private var glowTimer: Timer?

    /// Pulse the inner border while an agent drives this pane; fades 3 s
    /// after the last socket command.
    func showAgentGlow() {
        guard renderer?.config.agentGlow ?? true else { return }
        if glowView == nil {
            let glow = AgentGlowView(frame: bounds)
            glow.autoresizingMask = [.width, .height]
            addSubview(glow)
            glowView = glow
        }
        glowView?.startPulse()
        glowTimer?.invalidate()
        glowTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.glowView?.stopPulse()
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool {
        (renderer?.config.backgroundOpacity ?? 1) >= 1 && !(renderer?.config.backgroundBlur ?? false)
    }

    // Clicks in the grid select text; they must never drag the window.
    override var mouseDownCanMoveWindow: Bool { false }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.isOpaque = true
        return layer
    }

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return true
    }

    // MARK: - geometry

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        updateGeometry()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        updateGeometry()
        if inLiveResize {
            // Synchronous present keeps content glued to the window edge
            // while dragging — the thing that makes resize feel instant.
            renderer.renderNow(sync: true)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor, scale > 0 else { return }
        renderer.updateScale(scale)
        updateGeometry()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        metalLayer.presentsWithTransaction = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        metalLayer.presentsWithTransaction = false
        updateGeometry()
        // Guarantee the child sees the final size immediately.
        winsizeTimer?.invalidate()
        winsizeTimer = nil
        flushPendingWinsize()
        terminal.touch()
    }

    private func updateGeometry() {
        guard let window, terminal != nil else { return }
        let scale = window.backingScaleFactor
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return }

        metalLayer.contentsScale = scale
        metalLayer.drawableSize = pixelSize

        // With a full-size content view, AppKit tells us how much of the top
        // is obscured by the (transparent) titlebar and any tab bar — this
        // tracks tab-bar appearance automatically.
        if window.styleMask.contains(.fullSizeContentView) {
            if renderer.config.titlebarStyle == "hidden" && renderer.config.trafficLights == "circle" {
                renderer.topInsetPoints = 4
            } else {
                let layoutRect = convert(window.contentLayoutRect, from: nil)
                renderer.topInsetPoints = max(bounds.height - layoutRect.maxY, 0) + 2
            }
        } else {
            renderer.topInsetPoints = 0
        }

        terminal.setCellPixelSize(
            width: CGFloat(renderer.atlas.cellWidth),
            height: CGFloat(renderer.atlas.cellHeight)
        )
        let insetPx = renderer.insetPoints * scale
        let topPx = renderer.topInsetPoints * scale
        let cols = max(2, Int((pixelSize.width - insetPx * 2) / CGFloat(renderer.atlas.cellWidth)))
        let rows = max(2, Int((pixelSize.height - insetPx * 2 - topPx) / CGFloat(renderer.atlas.cellHeight)))
        if cols != terminal.cols || rows != terminal.rows {
            terminal.resize(cols: cols, rows: rows)
            let size = (cols, rows, Int(pixelSize.width), Int(pixelSize.height))
            if inLiveResize {
                // Flooding the child with SIGWINCH makes slow TUIs lag far
                // behind the drag; coalesce to ~12 Hz (leading edge fires
                // immediately so responsive apps track the drag).
                if winsizeTimer == nil {
                    pty.setSize(cols: size.0, rows: size.1, pixelWidth: size.2, pixelHeight: size.3)
                    winsizeTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) {
                        [weak self] _ in
                        self?.winsizeTimer = nil
                        self?.flushPendingWinsize()
                    }
                } else {
                    pendingWinsize = size
                }
            } else {
                pendingWinsize = nil
                pty.setSize(cols: size.0, rows: size.1, pixelWidth: size.2, pixelHeight: size.3)
            }
        }
        terminal.touch()
    }

    private func flushPendingWinsize() {
        guard let size = pendingWinsize else { return }
        pendingWinsize = nil
        pty.setSize(cols: size.cols, rows: size.rows, pixelWidth: size.pw, pixelHeight: size.ph)
    }

    // MARK: - keyboard

    override func keyDown(with event: NSEvent) {
        // Accept an inline hint with Tab or Right-arrow (when one is showing).
        if event.keyCode == 48 || event.keyCode == 124, // Tab or →
           !event.modifierFlags.contains(.shift),
           let accepted = terminal.acceptHint(), !accepted.isEmpty {
            pty.write(accepted)
            renderer.poke()
            return
        }
        guard let bytes = encodeKey(event), !bytes.isEmpty else { return }
        terminal.userDidInput()
        pty.write(bytes)
    }

    private func encodeKey(_ event: NSEvent) -> [UInt8]? {
        let flags = event.modifierFlags
        if flags.contains(.command) { return nil }

        func esc(_ s: String) -> [UInt8] { [0x1B] + Array(s.utf8) }

        var mod = 1
        if flags.contains(.shift) { mod += 1 }
        if flags.contains(.option) { mod += 2 }
        if flags.contains(.control) { mod += 4 }

        let appCursor = terminal.applicationCursorKeys
        func arrow(_ ch: String) -> [UInt8] {
            if mod > 1 { return esc("[1;\(mod)\(ch)") }
            return appCursor ? esc("O\(ch)") : esc("[\(ch)")
        }
        func editKey(_ n: Int) -> [UInt8] {
            mod > 1 ? esc("[\(n);\(mod)~") : esc("[\(n)~")
        }
        func fkey14(_ ch: String) -> [UInt8] {
            mod > 1 ? esc("[1;\(mod)\(ch)") : esc("O\(ch)")
        }

        switch event.keyCode {
        case 126: return arrow("A")
        case 125: return arrow("B")
        case 124: return arrow("C")
        case 123: return arrow("D")
        case 115: return arrow("H") // home
        case 119: return arrow("F") // end
        case 116: return editKey(5) // page up
        case 121: return editKey(6) // page down
        case 117: return editKey(3) // forward delete
        case 51: return flags.contains(.option) ? [0x1B, 0x7F] : [0x7F]
        case 36, 76: // return: CSI-u encodes shifted/ctrl variants so TUIs
            // (Claude Code etc.) can insert a newline without submitting
            if flags.contains(.shift) { return esc("[13;2u") }
            if flags.contains(.control) { return esc("[13;5u") }
            return [0x0D]
        case 48: return flags.contains(.shift) ? esc("[Z") : [0x09]
        case 53: return [0x1B]
        case 122: return fkey14("P") // F1
        case 120: return fkey14("Q")
        case 99: return fkey14("R")
        case 118: return fkey14("S")
        case 96: return editKey(15) // F5
        case 97: return editKey(17)
        case 98: return editKey(18)
        case 100: return editKey(19)
        case 101: return editKey(20)
        case 109: return editKey(21)
        case 103: return editKey(23)
        case 111: return editKey(24) // F12
        default: break
        }

        // Option-as-meta: ESC prefix + the unmodified character.
        if flags.contains(.option), !flags.contains(.control),
           let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            return [0x1B] + Array(chars.utf8)
        }
        if let chars = event.characters, !chars.isEmpty {
            return Array(chars.utf8)
        }
        return nil
    }

    // MARK: - paste

    @objc func paste(_ sender: Any?) {
        guard var s = NSPasteboard.general.string(forType: .string) else { return }
        s = s.replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        var bytes = Array(s.utf8)
        if terminal.bracketedPasteEnabled {
            bytes = Array("\u{1B}[200~".utf8) + bytes + Array("\u{1B}[201~".utf8)
        }
        terminal.userDidInput()
        pty.write(bytes)
    }

    // MARK: - mouse reporting (xterm protocol)

    private func mouseCell(_ event: NSEvent) -> (col: Int, row: Int)? {
        guard terminal != nil else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let inset = renderer.insetPoints
        let cell = renderer.cellSizePoints
        guard cell.width > 0, cell.height > 0 else { return nil }
        let x = p.x - inset
        let yTop = (bounds.height - p.y) - inset - renderer.topInsetPoints
        let col = Int(floor(x / cell.width))
        let row = Int(floor(yTop / cell.height))
        guard col >= 0, row >= 0, col < terminal.cols, row < terminal.rows else { return nil }
        return (col, row)
    }

    /// Like mouseCell but clamped to the grid, for drag-selection outside it.
    private func clampedCell(_ event: NSEvent) -> (col: Int, row: Int) {
        let p = convert(event.locationInWindow, from: nil)
        let inset = renderer.insetPoints
        let cell = renderer.cellSizePoints
        let x = p.x - inset
        let yTop = (bounds.height - p.y) - inset - renderer.topInsetPoints
        let col = min(max(Int(floor(x / cell.width)), 0), terminal.cols - 1)
        let row = min(max(Int(floor(yTop / cell.height)), 0), terminal.rows - 1)
        return (col, row)
    }

    private func modifierBits(_ event: NSEvent) -> Int {
        var m = 0
        if event.modifierFlags.contains(.shift) { m += 4 }
        if event.modifierFlags.contains(.option) { m += 8 }
        if event.modifierFlags.contains(.control) { m += 16 }
        return m
    }

    /// Send one xterm mouse report. button: 0/1/2, 64/65 for scroll,
    /// 3 for motion with no button. Returns true if it was reported.
    @discardableResult
    private func reportMouse(_ event: NSEvent, button: Int, pressed: Bool, motion: Bool) -> Bool {
        let (mode, sgr) = terminal.mouseReporting
        guard mode != 0 else { return false }
        if motion {
            let needed = button == 3 ? 1003 : 1002
            guard mode >= needed else { return false }
        }
        guard let (col, row) = mouseCell(event) else { return false }

        if motion && (col, row) == lastMouseCell { return true }
        lastMouseCell = motion ? (col, row) : (-1, -1)

        var code = button
        if motion { code += 32 }
        if mode != 9 { code += modifierBits(event) }

        var bytes: [UInt8]
        if sgr {
            let suffix = pressed || motion ? "M" : "m"
            bytes = Array("\u{1B}[<\(code);\(col + 1);\(row + 1)\(suffix)".utf8)
        } else {
            if !pressed && !motion { code = 3 } // legacy release
            let cb = UInt8(min(32 + code, 255))
            let cx = UInt8(min(32 + col + 1, 255))
            let cy = UInt8(min(32 + row + 1, 255))
            bytes = [0x1B, UInt8(ascii: "["), UInt8(ascii: "M"), cb, cx, cy]
        }
        pty.write(bytes)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // Clicks in the titlebar strip (top inset) drag the window — the one
        // place dragging is allowed; everywhere else drags select.
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.height - pt.y < renderer.topInsetPoints {
            window?.performDrag(with: event)
            return
        }
        window?.makeFirstResponder(self)

        if event.modifierFlags.contains(.command) {
            openLink(at: event)
            dragMode = .none
            return
        }

        let reporting = terminal.mouseReporting.mode != 0
            && !event.modifierFlags.contains(.shift)
        if reporting {
            dragMode = .report
            reportMouse(event, button: 0, pressed: true, motion: false)
            return
        }

        dragMode = .select
        terminal.clearSelection()
        let (col, row) = clampedCell(event)
        switch event.clickCount {
        case 2:
            terminal.selectionBegin(viewRow: row, col: col, mode: .word)
        case 3:
            terminal.selectionBegin(viewRow: row, col: col, mode: .line)
        default:
            terminal.selectionBegin(viewRow: row, col: col, mode: .character)
        }
        renderer.poke()
    }

    override func mouseUp(with event: NSEvent) {
        if dragMode == .report {
            reportMouse(event, button: 0, pressed: false, motion: false)
        }
        dragMode = .none
    }

    override func mouseDragged(with event: NSEvent) {
        switch dragMode {
        case .report:
            reportMouse(event, button: 0, pressed: true, motion: true)
        case .select:
            let (col, row) = clampedCell(event)
            terminal.selectionExtend(viewRow: row, col: col)
            renderer.poke()
        case .none:
            break
        }
    }

    // MARK: - copy & links

    @objc func copy(_ sender: Any?) {
        guard let text = terminal.selectedText() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static let urlRegex = try! NSRegularExpression(
        pattern: "(https?://|file:///|www\\.)[^\\s\"'`<>]+"
    )

    /// URL under a cell, with its column range on that row.
    private func link(atCol col: Int, viewRow row: Int) -> (URL, Int, Int)? {
        guard let chars = terminal.lineChars(viewRow: row) else { return nil }
        // Force one UTF-16 unit per column so regex ranges map to columns.
        let line = String(chars.map { $0.isASCII ? $0 : " " })
        let ns = line as NSString
        for m in TerminalView.urlRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let lo = m.range.location
            var hi = m.range.location + m.range.length - 1
            guard col >= lo, col <= hi else { continue }
            var text = ns.substring(with: m.range)
            while let last = text.last, ").,;:!?'\"".contains(last) {
                text.removeLast()
                hi -= 1
            }
            if text.hasPrefix("www.") { text = "https://" + text }
            guard let url = URL(string: text) else { continue }
            return (url, lo, hi)
        }
        return nil
    }

    private func openLink(at event: NSEvent) {
        guard let (col, row) = mouseCell(event) else { return }
        if let (url, _, _) = link(atCol: col, viewRow: row) {
            NSWorkspace.shared.open(url)
            return
        }
        // Markdown files open through the configured viewer (default glow).
        if let path = pathToken(atCol: col, viewRow: row),
           path.lowercased().hasSuffix(".md") || path.lowercased().hasSuffix(".markdown") {
            let cmd = renderer.config.markdownCommand + " " + TerminalView.shellEscape(path) + "\r"
            terminal.userDidInput()
            pty.write(Array(cmd.utf8))
        }
    }

    /// Path-ish token under a cell (for cmd-click on file names).
    private func pathToken(atCol col: Int, viewRow row: Int) -> String? {
        guard let chars = terminal.lineChars(viewRow: row) else { return nil }
        func isPathChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || "_-./~+@%".contains(c)
        }
        guard col < chars.count, isPathChar(chars[col]) else { return nil }
        var lo = col
        var hi = col
        while lo > 0 && isPathChar(chars[lo - 1]) { lo -= 1 }
        while hi < chars.count - 1 && isPathChar(chars[hi + 1]) { hi += 1 }
        let token = String(chars[lo...hi])
        return token.isEmpty ? nil : token
    }

    private func updateLinkHover(_ event: NSEvent) {
        guard event.modifierFlags.contains(.command),
              let (col, row) = mouseCell(event),
              let (_, lo, hi) = link(atCol: col, viewRow: row) else {
            terminal.clearLinkHighlight()
            renderer.poke()
            NSCursor.arrow.set()
            return
        }
        terminal.setLinkHighlight(viewRow: row, lo: lo, hi: hi)
        renderer.poke()
        NSCursor.pointingHand.set()
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if !event.modifierFlags.contains(.command) {
            terminal.clearLinkHighlight()
            renderer.poke()
            NSCursor.arrow.set()
        }
    }

    // MARK: - drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            let escaped = urls.map { TerminalView.shellEscape($0.path) }.joined(separator: " ") + " "
            terminal.userDidInput()
            pty.write(Array(escaped.utf8))
            return true
        }
        if let s = pb.string(forType: .string), !s.isEmpty {
            var bytes = Array(s.replacingOccurrences(of: "\n", with: "\r").utf8)
            if terminal.bracketedPasteEnabled {
                bytes = Array("\u{1B}[200~".utf8) + bytes + Array("\u{1B}[201~".utf8)
            }
            terminal.userDidInput()
            pty.write(bytes)
            return true
        }
        return false
    }

    private static func shellEscape(_ path: String) -> String {
        if path.range(of: "^[A-Za-z0-9_/.=-]+$", options: .regularExpression) != nil {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    override func rightMouseDown(with event: NSEvent) {
        let (mode, _) = terminal.mouseReporting
        if mode != 0 && !event.modifierFlags.contains(.shift) {
            reportMouse(event, button: 2, pressed: true, motion: false)
            return
        }
        super.rightMouseDown(with: event) // shows menu(for:)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Split Right", action: Selector(("splitRight:")), keyEquivalent: "")
        menu.addItem(withTitle: "Split Left", action: Selector(("splitLeft:")), keyEquivalent: "")
        menu.addItem(withTitle: "Split Down", action: Selector(("splitDown:")), keyEquivalent: "")
        menu.addItem(withTitle: "Split Up", action: Selector(("splitUp:")), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename Tab…", action: Selector(("renameTab:")), keyEquivalent: "")
        menu.addItem(.separator())
        let reset = menu.addItem(withTitle: "Reset Terminal", action: #selector(resetTerminal(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(withTitle: "Close Pane", action: Selector(("closePane:")), keyEquivalent: "")
        return menu
    }

    @objc func resetTerminal(_ sender: Any?) {
        terminal.hardReset()
        pty.write([0x0C]) // ^L so the shell repaints its prompt
    }

    override func rightMouseUp(with event: NSEvent) {
        reportMouse(event, button: 2, pressed: false, motion: false)
    }

    override func rightMouseDragged(with event: NSEvent) {
        reportMouse(event, button: 2, pressed: true, motion: true)
    }

    override func otherMouseDown(with event: NSEvent) {
        reportMouse(event, button: 1, pressed: true, motion: false)
    }

    override func otherMouseUp(with event: NSEvent) {
        reportMouse(event, button: 1, pressed: false, motion: false)
    }

    override func otherMouseDragged(with event: NSEvent) {
        reportMouse(event, button: 1, pressed: true, motion: true)
    }

    override func mouseMoved(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            updateLinkHover(event)
            return
        }
        let (mode, _) = terminal.mouseReporting
        if mode == 1003 {
            reportMouse(event, button: 3, pressed: true, motion: true)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    // MARK: - scrolling (app reporting or local scrollback)

    override func scrollWheel(with event: NSEvent) {
        let cellH = renderer.cellSizePoints.height
        guard cellH > 0 else { return }

        // Apps get scroll events when they asked for the mouse — hold Shift
        // to force local scrollback instead.
        let (mode, _) = terminal.mouseReporting
        if mode >= 1000 && !event.modifierFlags.contains(.shift) {
            var steps = 0
            if event.hasPreciseScrollingDeltas {
                mouseScrollAccumulator += event.scrollingDeltaY
                steps = Int(mouseScrollAccumulator / cellH)
                mouseScrollAccumulator -= CGFloat(steps) * cellH
            } else {
                steps = Int(event.scrollingDeltaY.rounded())
            }
            guard steps != 0 else { return }
            let button = steps > 0 ? 64 : 65
            for _ in 0..<min(abs(steps), 30) {
                reportMouse(event, button: button, pressed: true, motion: false)
            }
            return
        }

        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += event.scrollingDeltaY
            let lines = Int(scrollAccumulator / cellH)
            if lines != 0 {
                scrollAccumulator -= CGFloat(lines) * cellH
                terminal.scrollViewport(by: lines)
            }
        } else {
            let lines = Int(event.scrollingDeltaY.rounded())
            if lines != 0 { terminal.scrollViewport(by: lines * 3) }
        }
    }
}
