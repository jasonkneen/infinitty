import AppKit

/// Settings window (⌘,). Controls edit the config *file* and rely on the
/// live-reload watcher, so every change applies to all panes immediately and
/// persists. Saving regenerates the managed config file.
final class SettingsWindowController: NSWindowController {
    private var current: AppConfig
    private let onSave: (AppConfig) -> Void

    private static let labelWidth: CGFloat = 110
    private static let controlWidth: CGFloat = 300

    private let fontCombo = NSComboBox()
    private let stylePopup = NSPopUpButton()
    private let sizeSlider = NSSlider(value: 13, minValue: 9, maxValue: 24, target: nil, action: nil)
    private let sizeValue = NSTextField(labelWithString: "")
    private let marginSlider = NSSlider(value: 8, minValue: 0, maxValue: 32, target: nil, action: nil)
    private let marginValue = NSTextField(labelWithString: "")
    private let lineSlider = NSSlider(value: 1, minValue: 0.8, maxValue: 1.6, target: nil, action: nil)
    private let lineValue = NSTextField(labelWithString: "")
    private let kernSlider = NSSlider(value: 1, minValue: 0.8, maxValue: 1.3, target: nil, action: nil)
    private let kernValue = NSTextField(labelWithString: "")
    private let opacitySlider = NSSlider(value: 1, minValue: 0.3, maxValue: 1, target: nil, action: nil)
    private let opacityValue = NSTextField(labelWithString: "")
    private let blurCheck = NSButton(checkboxWithTitle: "Frosted blur behind window", target: nil, action: nil)
    private let glowCheck = NSButton(checkboxWithTitle: "Glow while an agent is in control", target: nil, action: nil)
    private let titlebarPopup = NSPopUpButton()
    private let lightsPopup = NSPopUpButton()
    private let petPopup = NSPopUpButton()
    private let petModePopup = NSPopUpButton()
    private let petScaleSlider = NSSlider(value: 0.5, minValue: 0.2, maxValue: 1.2, target: nil, action: nil)
    private let petScaleValue = NSTextField(labelWithString: "")
    private let notchCheck = NSButton(checkboxWithTitle: "Show live activity", target: nil, action: nil)
    private let notchPopup = NSPopUpButton()
    private let fgWell = NSColorWell()
    private let bgWell = NSColorWell()
    private let cursorWell = NSColorWell()
    private let selectionWell = NSColorWell()

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self.current = config
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "infinitty Settings"
        super.init(window: window)
        buildUI()
        populate()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: layout helpers

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        l.textColor = .secondaryLabelColor
        l.font = .systemFont(ofSize: 12)
        l.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        return l
    }

    private func row(_ title: String, _ control: NSView, width: CGFloat = controlWidth) -> NSStackView {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: width).isActive = true
        let stack = NSStackView(views: [label(title), control])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .firstBaseline
        return stack
    }

    private func sliderRow(
        _ title: String, _ slider: NSSlider, _ value: NSTextField
    ) -> NSStackView {
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: Self.controlWidth - 54).isActive = true
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let group = NSStackView(views: [slider, value])
        group.orientation = .horizontal
        group.spacing = 10
        let stack = NSStackView(views: [label(title), group])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }

    private func section(_ title: String) -> NSStackView {
        let l = NSTextField(labelWithString: title)
        l.font = .boldSystemFont(ofSize: 12)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [l, line])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func colorRow() -> NSStackView {
        func item(_ name: String, _ well: NSColorWell) -> NSStackView {
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let l = NSTextField(labelWithString: name)
            l.font = .systemFont(ofSize: 10)
            l.textColor = .secondaryLabelColor
            l.alignment = .center
            let s = NSStackView(views: [well, l])
            s.orientation = .vertical
            s.spacing = 3
            s.alignment = .centerX
            return s
        }
        let group = NSStackView(views: [
            item("Text", fgWell), item("Background", bgWell),
            item("Cursor", cursorWell), item("Selection", selectionWell),
        ])
        group.orientation = .horizontal
        group.spacing = 20
        let stack = NSStackView(views: [label(""), group])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .top
        return stack
    }

    // MARK: build

    private func buildUI() {
        // Font pickers
        fontCombo.usesDataSource = false
        fontCombo.completes = true
        fontCombo.addItems(withObjectValues: NSFontManager.shared.availableFontFamilies)
        fontCombo.placeholderString = "SF Mono (default)"
        fontCombo.target = self
        fontCombo.action = #selector(fontChanged(_:))

        titlebarPopup.addItems(withTitles: ["native", "transparent", "hidden"])
        lightsPopup.addItems(withTitles: ["circle", "square", "rectangle", "diamond"])
        petModePopup.addItems(withTitles: ["one per window", "every pane"])
        notchPopup.addItems(withTitles: ["builtin", "external", "primary", "all"])

        petPopup.addItem(withTitle: "none")
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? NSString(string: "~/.codex").expandingTildeInPath
        if let pets = try? FileManager.default.contentsOfDirectory(atPath: "\(codexHome)/pets") {
            for pet in pets.sorted() where !pet.hasPrefix(".") {
                petPopup.addItem(withTitle: pet)
            }
        }

        let notchGroup = NSStackView(views: [notchCheck, notchPopup])
        notchGroup.orientation = .horizontal
        notchGroup.spacing = 10
        notchPopup.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let apply = NSButton(title: "Apply", target: self, action: #selector(applyPressed))
        apply.keyEquivalent = "\r"
        apply.bezelStyle = .rounded
        let note = NSTextField(wrappingLabelWithString:
            "Changes apply live to every pane and are written to the config file.")
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        let footer = NSStackView(views: [note, apply])
        footer.orientation = .horizontal
        footer.spacing = 16
        footer.alignment = .centerY

        let stack = NSStackView(views: [
            section("Font"),
            row("Family", fontCombo),
            row("Style", stylePopup),
            sliderRow("Size", sizeSlider, sizeValue),
            section("Layout"),
            sliderRow("Margin", marginSlider, marginValue),
            sliderRow("Line spacing", lineSlider, lineValue),
            sliderRow("Kerning", kernSlider, kernValue),
            section("Window"),
            sliderRow("Opacity", opacitySlider, opacityValue),
            row("", blurCheck),
            row("Titlebar", titlebarPopup, width: 160),
            row("Traffic lights", lightsPopup, width: 160),
            section("Pet"),
            row("Pet", petPopup, width: 200),
            row("Placement", petModePopup, width: 160),
            sliderRow("Size", petScaleSlider, petScaleValue),
            section("Agents"),
            row("Notch", notchGroup),
            row("", glowCheck),
            section("Colors"),
            colorRow(),
            footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: stack.views[3]) // breathe after sections
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Sections and footer span the full width.
        for view in stack.views {
            stack.setVisibilityPriority(.mustHold, for: view)
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 480),
        ])
        window?.contentView = content
        window?.setContentSize(NSSize(width: 480, height: stack.fittingSize.height))
    }

    // MARK: populate & actions

    private func populate() {
        fontCombo.stringValue = current.fontName ?? ""
        rebuildStyles(for: current.fontName)
        if let style = current.fontStyle { stylePopup.selectItem(withTitle: style) }
        sizeSlider.doubleValue = Double(current.fontSize)
        marginSlider.doubleValue = Double(current.margin)
        lineSlider.doubleValue = Double(current.lineSpacing)
        kernSlider.doubleValue = Double(current.kerning)
        opacitySlider.doubleValue = Double(current.backgroundOpacity)
        blurCheck.state = current.backgroundBlur ? .on : .off
        glowCheck.state = current.agentGlow ? .on : .off
        notchCheck.state = current.notch ? .on : .off
        titlebarPopup.selectItem(withTitle: current.titlebarStyle)
        lightsPopup.selectItem(withTitle: current.trafficLights)
        notchPopup.selectItem(withTitle: current.notchDisplay)
        petPopup.selectItem(withTitle: current.pet ?? "none")
        if petPopup.selectedItem == nil { petPopup.selectItem(at: 0) }
        petModePopup.selectItem(at: current.petMode == "pane" ? 1 : 0)
        petScaleSlider.doubleValue = Double(current.petScale)

        func color(_ v: UInt32?, _ def: UInt32) -> NSColor {
            let c = v ?? def
            return NSColor(
                srgbRed: CGFloat((c >> 16) & 0xFF) / 255,
                green: CGFloat((c >> 8) & 0xFF) / 255,
                blue: CGFloat(c & 0xFF) / 255, alpha: 1
            )
        }
        fgWell.color = color(current.foreground, 0xD7DAE0)
        bgWell.color = color(current.background, 0x0F1216)
        cursorWell.color = color(current.cursorColor, 0xAEB8C4)
        selectionWell.color = color(current.selectionBackground, 0x2F4368)
        refreshValueLabels()
    }

    private func rebuildStyles(for family: String?) {
        stylePopup.removeAllItems()
        stylePopup.addItem(withTitle: "Regular")
        guard let family, !family.isEmpty,
              let members = NSFontManager.shared.availableMembers(ofFontFamily: family) else {
            return
        }
        for m in members {
            if let style = m[1] as? String, style != "Regular" {
                stylePopup.addItem(withTitle: style)
            }
        }
    }

    @objc private func fontChanged(_ sender: Any?) {
        rebuildStyles(for: fontCombo.stringValue)
    }

    @objc private func sliderMoved(_ sender: Any?) {
        refreshValueLabels()
    }

    private func refreshValueLabels() {
        sizeValue.stringValue = String(format: "%.0f pt", sizeSlider.doubleValue)
        marginValue.stringValue = String(format: "%.0f pt", marginSlider.doubleValue)
        lineValue.stringValue = String(format: "%.2f×", lineSlider.doubleValue)
        kernValue.stringValue = String(format: "%.2f×", kernSlider.doubleValue)
        opacityValue.stringValue = String(format: "%.0f%%", opacitySlider.doubleValue * 100)
        petScaleValue.stringValue = String(format: "%.2f×", petScaleSlider.doubleValue)
    }

    @objc private func applyPressed() {
        var c = current
        let family = fontCombo.stringValue.trimmingCharacters(in: .whitespaces)
        c.fontName = family.isEmpty ? nil : family
        let style = stylePopup.titleOfSelectedItem ?? "Regular"
        c.fontStyle = style == "Regular" ? nil : style
        c.fontSize = CGFloat(sizeSlider.doubleValue.rounded())
        c.margin = CGFloat(marginSlider.doubleValue.rounded())
        c.lineSpacing = CGFloat((lineSlider.doubleValue * 100).rounded() / 100)
        c.kerning = CGFloat((kernSlider.doubleValue * 100).rounded() / 100)
        c.backgroundOpacity = CGFloat((opacitySlider.doubleValue * 100).rounded() / 100)
        c.backgroundBlur = blurCheck.state == .on
        c.agentGlow = glowCheck.state == .on
        c.notch = notchCheck.state == .on
        c.notchDisplay = notchPopup.titleOfSelectedItem ?? "builtin"
        c.titlebarStyle = titlebarPopup.titleOfSelectedItem ?? "native"
        c.trafficLights = lightsPopup.titleOfSelectedItem ?? "circle"
        let pet = petPopup.titleOfSelectedItem ?? "none"
        c.pet = pet == "none" ? nil : pet
        c.petMode = petModePopup.indexOfSelectedItem == 1 ? "pane" : "window"
        c.petScale = CGFloat((petScaleSlider.doubleValue * 100).rounded() / 100)

        func pack(_ well: NSColorWell) -> UInt32? {
            guard let rgb = well.color.usingColorSpace(.sRGB) else { return nil }
            return UInt32(rgb.redComponent * 255) << 16
                | UInt32(rgb.greenComponent * 255) << 8
                | UInt32(rgb.blueComponent * 255)
        }
        c.foreground = pack(fgWell)
        c.background = pack(bgWell)
        c.cursorColor = pack(cursorWell)
        c.selectionBackground = pack(selectionWell)

        current = c
        onSave(c)
    }
}
