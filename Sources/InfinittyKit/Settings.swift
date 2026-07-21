import AppKit

extension NSBox {
    /// A thin horizontal separator line for settings panels.
    static func separatorLine() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 440).isActive = true
        return box
    }
}

/// Opens an associated URL when its button is clicked.
final class LinkOpener: NSObject {
    @objc func open(_ sender: NSButton) {
        if let url = objc_getAssociatedObject(sender, &SettingsWindowController.urlKey) as? String,
           let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }
}

/// Settings window (⌘,). Controls edit the config *file* and rely on the
/// live-reload watcher, so every change applies to all panes immediately and
/// persists. Saving regenerates the managed config file.
final class SettingsWindowController: NSWindowController {
    static let linkOpener = LinkOpener()
    static var urlKey: UInt8 = 0
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
    private let hintsCheck = NSButton(checkboxWithTitle: "Inline AI hints (ghost text)", target: nil, action: nil)
    private let hintsWarning = NSTextField(wrappingLabelWithString: "")
    private let lightsPopup = NSPopUpButton()
    private let petPopup = NSPopUpButton()
    private var sidebarButtons: [NSButton] = []
    private let petModePopup = NSPopUpButton()
    private let petScaleSlider = NSSlider(value: 0.5, minValue: 0.2, maxValue: 1.2, target: nil, action: nil)
    private let petScaleValue = NSTextField(labelWithString: "")
    private let notchCheck = NSButton(checkboxWithTitle: "Show Agent Notch", target: nil, action: nil)
    private let notchPopup = NSPopUpButton()
    private let fgWell = NSColorWell()
    private let bgWell = NSColorWell()
    private let cursorWell = NSColorWell()
    private let selectionWell = NSColorWell()
    private let accentWell = NSColorWell()
    private var panels: [String: NSView] = [:]
    private var panelHost: NSView?

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
            item("Accent", accentWell),
        ])
        group.orientation = .horizontal
        group.spacing = 14
        return group
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

        lightsPopup.addItems(withTitles: ["circle", "square", "rectangle", "diamond"])
        petModePopup.addItems(withTitles: ["one per window", "every pane"])
        notchPopup.addItems(withTitles: ["builtin", "external", "primary", "all"])

        petPopup.addItem(withTitle: "none")
        petPopup.addItem(withTitle: "infinitty")
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? NSString(string: "~/.codex").expandingTildeInPath
        if let pets = try? FileManager.default.contentsOfDirectory(atPath: "\(codexHome)/pets") {
            for pet in pets.sorted() where !pet.hasPrefix(".") && pet != "infinitty" {
                petPopup.addItem(withTitle: pet)
            }
        }

        let notchGroup = NSStackView(views: [notchCheck, notchPopup])
        notchGroup.orientation = .horizontal
        notchGroup.spacing = 10

        hintsWarning.stringValue = "⚠ Disable your shell's autosuggestions (zsh-autosuggestions, fish) to avoid overlapping ghost text. Uses on-device Apple Intelligence by default; set an AI endpoint via Edit Config."
        hintsWarning.font = .systemFont(ofSize: 10)
        hintsWarning.textColor = .tertiaryLabelColor
        hintsWarning.lineBreakMode = .byWordWrapping
        hintsWarning.maximumNumberOfLines = 3
        hintsWarning.preferredMaxLayoutWidth = Self.controlWidth
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

        // Version, author, links + update check.
        let versionLabel = NSTextField(labelWithString: "infinitty \(Updater.currentVersion ?? "dev build")")
        versionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        versionLabel.textColor = .secondaryLabelColor
        let byLabel = NSTextField(labelWithString: "by Jason Kneen")
        byLabel.font = .systemFont(ofSize: 11)
        byLabel.textColor = .tertiaryLabelColor
        func linkButton(_ title: String, _ url: String) -> NSButton {
            let b = NSButton(title: title, target: nil, action: nil)
            b.isBordered = false
            b.contentTintColor = .linkColor
            b.font = .systemFont(ofSize: 11)
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 11),
                .link: url,
            ])
            b.target = SettingsWindowController.linkOpener
            b.action = #selector(LinkOpener.open(_:))
            b.toolTip = url
            objc_setAssociatedObject(b, &SettingsWindowController.urlKey, url, .OBJC_ASSOCIATION_RETAIN)
            return b
        }
        let updateButton = NSButton(title: "Check for Updates…", target: nil,
            action: Selector(("checkForUpdates:")))
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .small
        let editConfigButton = NSButton(title: "Edit Config…", target: self,
            action: #selector(editConfig))
        editConfigButton.bezelStyle = .rounded
        editConfigButton.controlSize = .small
        editConfigButton.toolTip = "Open the config file (fonts, colors, AI endpoint, …) in your editor"
        let versionRow = NSStackView(views: [
            versionLabel, byLabel,
            linkButton("GitHub", "https://github.com/jasonkneen"),
            linkButton("X", "https://x.com/jasonkneen"),
            NSView(), editConfigButton, updateButton,
        ])
        versionRow.orientation = .horizontal
        versionRow.spacing = 10
        versionRow.alignment = .centerY

        // Grouped into compact icon panels switched by a top segmented bar.
        func panel(_ rows: [NSView]) -> NSView {
            let s = NSStackView(views: rows)
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 12
            s.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
            s.translatesAutoresizingMaskIntoConstraints = false
            for view in rows { s.setVisibilityPriority(.mustHold, for: view) }
            return s
        }
        panels = [
            "Appearance": panel([
                section("Font"),
                row("Family", fontCombo),
                row("Style", stylePopup),
                sliderRow("Size", sizeSlider, sizeValue),
                section("Colors"),
                colorRow(),
            ]),
            "Terminal": panel([
                section("Layout"),
                sliderRow("Margin", marginSlider, marginValue),
                sliderRow("Line spacing", lineSlider, lineValue),
                sliderRow("Kerning", kernSlider, kernValue),
                section("Window"),
                sliderRow("Opacity", opacitySlider, opacityValue),
                row("", blurCheck),
                row("Traffic lights", lightsPopup, width: 160),
            ]),
            "Pet": panel([
                section("Pet"),
                row("Pet", petPopup, width: 200),
                row("Placement", petModePopup, width: 160),
                sliderRow("Size", petScaleSlider, petScaleValue),
            ]),
            "Agents": panel([
                section("Agents"),
                row("Notch", notchGroup),
                row("", glowCheck),
                row("", hintsCheck),
                row("", hintsWarning),
            ]),
            "About": panel([
                section("About"),
                versionRow,
            ]),
        ]

        // Left source list of panels (options down the side).
        let names = ["Appearance", "Terminal", "Pet", "Agents", "About"]
        let icons = ["paintpalette", "terminal", "pawprint", "sparkles", "info.circle"]
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 2
        sidebar.edgeInsets = NSEdgeInsets(top: 14, left: 8, bottom: 14, right: 8)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebarButtons = names.enumerated().map { index, name in
            let button = NSButton(title: "  \(name)", target: self, action: #selector(sidebarPicked(_:)))
            button.tag = index
            button.image = NSImage(systemSymbolName: icons[index], accessibilityDescription: name)
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.isBordered = false
            button.bezelStyle = .inline
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.contentTintColor = .labelColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 150).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            sidebar.addArrangedSubview(button)
            return button
        }

        let panelHost = NSView()
        panelHost.translatesAutoresizingMaskIntoConstraints = false
        self.panelHost = panelHost

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let bodyRow = NSStackView(views: [sidebar, divider, panelHost])
        bodyRow.orientation = .horizontal
        bodyRow.alignment = .top
        bodyRow.spacing = 0
        bodyRow.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [bodyRow, NSBox.separatorLine(), footer])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 14, right: 0)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panelHost.widthAnchor.constraint(equalToConstant: 340),
            panelHost.topAnchor.constraint(equalTo: bodyRow.topAnchor),
        ])
        window?.contentView = content
        showPanel("Appearance")
    }

    @objc private func sidebarPicked(_ sender: NSButton) {
        let names = ["Appearance", "Terminal", "Pet", "Agents", "About"]
        showPanel(names[sender.tag])
    }

    private func showPanel(_ name: String) {
        guard let host = panelHost, let view = panels[name] else { return }
        let names = ["Appearance", "Terminal", "Pet", "Agents", "About"]
        for (index, button) in sidebarButtons.enumerated() {
            let active = names[index] == name
            button.layer?.backgroundColor = active
                ? CodePalette.selectionAccent.withAlphaComponent(0.9).cgColor
                : NSColor.clear.cgColor
            button.contentTintColor = active ? .white : .labelColor
        }
        host.subviews.forEach { $0.removeFromSuperview() }
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        window?.layoutIfNeeded()
        let target = max(view.fittingSize.height + 90, 340)
        window?.setContentSize(NSSize(width: 560, height: target))
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
        hintsCheck.state = current.hints ? .on : .off
        notchCheck.state = current.notch ? .on : .off
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
        accentWell.color = color(current.accentColor, 0x6370EB)
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

    @objc private func editConfig() {
        let path = current.writePath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            // Seed with the current settings so there's something to edit.
            try? current.serializeTerminal().write(toFile: path, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
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
        c.hints = hintsCheck.state == .on
        c.notch = notchCheck.state == .on
        c.notchDisplay = notchPopup.titleOfSelectedItem ?? "builtin"
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
        c.accentColor = pack(accentWell)

        current = c
        onSave(c)
    }
}
