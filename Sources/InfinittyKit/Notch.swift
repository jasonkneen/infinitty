import AppKit

/// Live-activity widget: a slim always-on-top strip at the top of chosen
/// displays showing the focused terminal's command state (running / exit
/// code), driven by OSC 133 markers. On a MacBook it sits beside the notch.
final class NotchActivityController {
    private struct Widget {
        let panel: NSPanel
        let label: NSTextField
        let dot: NSView
    }

    private var widgets: [Widget] = []
    private var hideTimer: Timer?

    /// display: builtin | external | primary | all
    func show(display: String) {
        hide()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let builtin = screens.filter { $0.safeAreaInsets.top > 0 }
        let external = screens.filter { $0.safeAreaInsets.top <= 0 }

        let targets: [NSScreen]
        switch display {
        case "external":
            targets = external.isEmpty ? screens : external
        case "primary", "focused":
            targets = [NSScreen.main ?? screens[0]]
        case "all", "both":
            targets = screens
        default: // builtin
            targets = builtin.isEmpty ? [NSScreen.main ?? screens[0]] : builtin
        }

        for screen in targets {
            widgets.append(makeWidget(on: screen))
        }
        set(text: "infinitty", color: .systemGray)
    }

    private func makeWidget(on screen: NSScreen) -> Widget {
        let w: CGFloat = 300
        let hasNotch = screen.safeAreaInsets.top > 0
        let h: CGFloat = hasNotch ? max(screen.safeAreaInsets.top, 30) : 26
        // Beside the notch housing on built-ins; top-center on externals.
        let x = hasNotch ? screen.frame.midX + 110 : screen.frame.midX - w / 2
        let frame = NSRect(x: x, y: screen.frame.maxY - h, width: w, height: h)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.cornerRadius = 10
        content.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemGray.cgColor
        dot.layer?.cornerRadius = 4
        dot.frame = NSRect(x: 12, y: (h - 8) / 2, width: 8, height: 8)
        content.addSubview(dot)

        let label = NSTextField(labelWithString: "infinitty")
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingHead
        label.frame = NSRect(x: 28, y: (h - 16) / 2, width: w - 40, height: 16)
        label.autoresizingMask = [.width]
        content.addSubview(label)

        panel.contentView = content
        panel.orderFrontRegardless()
        return Widget(panel: panel, label: label, dot: dot)
    }

    func hide() {
        for widget in widgets { widget.panel.orderOut(nil) }
        widgets.removeAll()
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func set(text: String, color: NSColor) {
        for widget in widgets {
            widget.label.stringValue = text
            widget.dot.layer?.backgroundColor = color.cgColor
        }
    }

    /// External apps can post a transient message (app socket `activity`).
    func showCustom(text: String) {
        guard !widgets.isEmpty else { return }
        hideTimer?.invalidate()
        set(text: String(text.prefix(38)), color: .systemPurple)
        hideTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            self?.set(text: "infinitty", color: .systemGray)
        }
    }

    /// OSC 133 event from a session. kind: A prompt, C output start, D done.
    func handleMarker(kind: UInt8, exitCode: Int, commandLine: String?) {
        guard !widgets.isEmpty else { return }
        hideTimer?.invalidate()
        switch kind {
        case UInt8(ascii: "C"):
            let cmd = (commandLine ?? "command").suffix(34)
            set(text: "▶ \(cmd)", color: .systemBlue)
        case UInt8(ascii: "D"):
            if exitCode == 0 {
                set(text: "✓ done", color: .systemGreen)
            } else {
                set(text: "✗ exit \(exitCode)", color: .systemRed)
            }
            hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                self?.set(text: "infinitty", color: .systemGray)
            }
        default:
            break
        }
    }
}
