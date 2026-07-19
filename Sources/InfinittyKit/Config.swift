import CoreGraphics
import Foundation

/// Runtime configuration. Loaded from a config file, then overridden by
/// environment variables. Applied at launch (restart to pick up changes).
///
/// Config file (first found wins):
///   $INFINITTY_CONFIG (explicit path)
///   ~/.config/infinitty/infinitty.conf
///   ~/.infinitty.conf
///   ~/.config/ghostty/config          (known keys only, as a fallback)
///   ~/Library/Application Support/com.mitchellh.ghostty/config
///
/// Format: `key = value`, `#` comments. Native keys and their Ghostty
/// aliases are both accepted:
///   font / font-family
///   font-size
///   margin / padding / window-padding-x / window-padding-y
///   line-spacing / line-height / adjust-cell-height  (1.1 | 10% | 3)
///   kerning / letter-spacing / cell-width / adjust-cell-width
///   palette = N=#RRGGBB  (ANSI/256-color overrides, indices 0-255)
///
/// adjust-cell-* accepts Ghostty forms: `10%` (relative) or a bare number
/// (extra points added to the cell).
///
/// Environment overrides: INFINITTY_FONT, INFINITTY_FONT_SIZE, INFINITTY_MARGIN,
/// INFINITTY_LINE_SPACING, INFINITTY_KERNING.
struct AppConfig {
    var fontName: String?
    var fontStyle: String? // face style: Thin, Light, Medium, ... (font-style)
    var fontThicken = false // ghostty font-thicken: stroke glyphs slightly
    var fontSize: CGFloat = 13
    var margin: CGFloat = 8
    var lineSpacing: CGFloat = 1.0
    var kerning: CGFloat = 1.0
    var cellWidthExtra: CGFloat = 0 // points added to cell width
    var cellHeightExtra: CGFloat = 0 // points added to cell height
    var foreground: UInt32? // 0xRRGGBB overrides
    var background: UInt32?
    var cursorColor: UInt32?
    var selectionBackground: UInt32?
    /// UI accent for chrome selection (active tab, file-row highlight, chat
    /// bubbles, send button, pinned-tab default). nil = built-in indigo.
    var accentColor: UInt32?
    var palette: [Int: UInt32] = [:] // index (0-255) -> 0xRRGGBB overrides
    var trafficLights = "circle" // circle | square | rectangle | diamond
    var pet: String? = "infinitty" // built-in name, codex pet name, or directory path
    var petScale: CGFloat = 0.5
    var petMode = "window" // window = one pet (follows focus) | pane = every split
    var backgroundOpacity: CGFloat = 1.0
    var backgroundBlur = false // frosted behind-window blur
    var notch = false // live-activity widget beside the MacBook notch
    var notchDisplay = "builtin" // builtin | external | primary | all
    var markdownCommand = "glow -p" // cmd-click on a .md path runs this
    var markdownRender = "off" // off | auto — auto-render command output via glow
    var autoUpdate = "check" // check | off — daily background update check
    var quickTerminalKey: String? // e.g. cmd+shift+space; nil disables global registration
    var quickTerminalScreen: QuickTerminalScreen = .main
    var quickTerminalAutohide = true
    var quickTerminalAnimationDuration = 0.2
    var hints = false // inline ghost-text command suggestions (opt-in — conflicts with shell autosuggestions)
    var hintCommand: String? // custom async hint provider (script)
    var aiBaseURL: String? // OpenAI-compatible endpoint for hints
    var aiKey: String?
    var aiModel: String?
    /// AI provider: "auto" | "apple" | "codex" | "claude". Driven by
    /// ProviderDiscovery.preferredProvider. Powers inline hints AND the pet
    /// assistant — they're the same "AI backend" axis.
    var aiProvider: String = "auto"
    /// Model override for Claude. Falls back to ProviderDiscovery default.
    var claudeModel: String?
    /// Model override for Codex. Falls back to ProviderDiscovery default.
    var codexModel: String?
    /// Auto-register `infinitty-mcp` with Codex (`~/.codex/config.toml`)
    /// and Claude (`~/.claude.json`) on launch so the CLI gains terminal
    /// control tools. Off by default because it touches the user's dotfiles.
    var mcpAutoRegister = false
    var agentGlow = true // pulsing inner glow while an agent drives the pane
    var sourcePath: String? // config file in use (for live reload)

    var atlasKey: String {
        "\(fontName ?? "SF Mono")|\(fontStyle ?? "")|\(fontThicken)|\(fontSize)|" +
        "\(lineSpacing)|\(kerning)|\(cellWidthExtra)|\(cellHeightExtra)"
    }

    static func load() -> AppConfig {
        var c = AppConfig()
        let env = ProcessInfo.processInfo.environment

        var candidates: [String] = []
        if let explicit = env["INFINITTY_CONFIG"] ?? env["TITERM_CONFIG"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        candidates += [
            "~/.config/infinitty/infinitty.conf",
            "~/.infinitty.conf",
            "~/.config/titerm/titerm.conf", // legacy name
            "~/.titerm.conf",
            "~/.config/ghostty/config",
            "~/Library/Application Support/com.mitchellh.ghostty/config",
        ]
        for path in candidates {
            let expanded = NSString(string: path).expandingTildeInPath
            if let text = try? String(contentsOfFile: expanded, encoding: .utf8) {
                c.apply(fileContents: text)
                c.sourcePath = expanded
                break
            }
        }

        func envValue(_ key: String) -> String? {
            env["INFINITTY_\(key)"] ?? env["TITERM_\(key)"] // legacy fallback
        }
        if let v = envValue("FONT"), !v.isEmpty { c.fontName = v }
        if let v = envValue("FONT_SIZE").flatMap(Double.init) { c.fontSize = CGFloat(v) }
        if let v = envValue("MARGIN").flatMap(Double.init) { c.margin = CGFloat(v) }
        if let v = envValue("LINE_SPACING").flatMap(Double.init) { c.lineSpacing = CGFloat(v) }
        if let v = envValue("KERNING").flatMap(Double.init) { c.kerning = CGFloat(v) }

        c.clamp()
        return c
    }

    mutating func apply(fileContents: String) {
        var fontSet = false
        var paddingX: CGFloat?
        var paddingY: CGFloat?

        for rawLine in fileContents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue } // full-line comment
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("#") {
                // hex color, not a comment: value is the first token
                if let sp = value.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                    value = String(value[..<sp])
                }
            } else if key != "palette", let hash = value.firstIndex(of: "#") {
                // trailing comment (palette values carry their hex color
                // after an inner `=`, so the `#` is data there, not a comment)
                value = value[..<hash].trimmingCharacters(in: .whitespaces)
            }
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { continue }

            switch key {
            case "font", "font-family":
                // Ghostty repeats font-family for fallbacks; first one wins.
                if !fontSet {
                    fontName = value
                    fontSet = true
                }
            case "font-size", "fontsize", "size":
                if let v = Double(value) { fontSize = CGFloat(v) }
            case "margin", "padding":
                if let v = Double(value) { margin = CGFloat(v) }
            case "window-padding-x":
                if let v = Double(value) { paddingX = CGFloat(v) }
            case "window-padding-y":
                if let v = Double(value) { paddingY = CGFloat(v) }
            case "line-spacing", "linespacing", "line-height":
                if let v = Double(value) { lineSpacing = CGFloat(v) }
            case "adjust-cell-height":
                if let (mult, extra) = AppConfig.parseAdjust(value) {
                    lineSpacing = mult
                    cellHeightExtra = extra
                }
            case "kerning", "letter-spacing", "letterspacing", "cell-width":
                if let v = Double(value) { kerning = CGFloat(v) }
            case "adjust-cell-width":
                if let (mult, extra) = AppConfig.parseAdjust(value) {
                    kerning = mult
                    cellWidthExtra = extra
                }
            case "font-style", "font-weight":
                fontStyle = value
            case "font-thicken":
                fontThicken = AppConfig.parseBool(value)
            case "foreground":
                foreground = AppConfig.parseColor(value)
            case "background":
                background = AppConfig.parseColor(value)
            case "cursor-color", "cursor":
                cursorColor = AppConfig.parseColor(value)
            case "selection-background":
                selectionBackground = AppConfig.parseColor(value)
            case "accent-color", "accent":
                accentColor = AppConfig.parseColor(value)
            case "palette":
                if let (index, color) = AppConfig.parsePaletteEntry(value) {
                    palette[index] = color
                }
            case "traffic-lights", "trafficlights":
                let v = value.lowercased()
                if ["circle", "square", "rectangle", "diamond"].contains(v) {
                    trafficLights = v
                }
            case "pet", "codex-pet":
                let normalized = value.lowercased()
                pet = ["none", "off", "false"].contains(normalized) ? nil : value
            case "pet-scale":
                if let v = Double(value) { petScale = CGFloat(v) }
            case "pet-mode", "petmode":
                switch value.lowercased() {
                case "pane", "all", "every": petMode = "pane"
                default: petMode = "window"
                }
            case "background-opacity", "opacity", "transparency":
                if let v = Double(value) { backgroundOpacity = CGFloat(v) }
            case "background-blur", "background-blur-radius", "blur":
                if let v = Double(value) {
                    backgroundBlur = v > 0
                } else {
                    backgroundBlur = AppConfig.parseBool(value)
                }
            case "notch", "live-activity":
                notch = AppConfig.parseBool(value)
            case "notch-display", "notch-screen":
                let v = value.lowercased()
                if ["builtin", "external", "primary", "focused", "all", "both"].contains(v) {
                    notchDisplay = v == "both" ? "all" : v
                }
            case "markdown-command", "markdown-viewer":
                markdownCommand = value
            case "markdown-render", "auto-markdown":
                let v = value.lowercased()
                markdownRender = (v == "auto" || v == "on" || v == "true") ? "auto" : "off"
            case "auto-update", "updates":
                autoUpdate = AppConfig.parseBool(value) || value.lowercased() == "check" ? "check" : "off"
            case "quick-terminal-key", "quick-terminal-shortcut":
                quickTerminalKey = value
            case "quick-terminal-screen":
                if let screen = QuickTerminalScreen(rawValue: value.lowercased()) {
                    quickTerminalScreen = screen
                }
            case "quick-terminal-autohide":
                quickTerminalAutohide = AppConfig.parseBool(value)
            case "quick-terminal-animation-duration":
                if let duration = Double(value) { quickTerminalAnimationDuration = duration }
            case "hints":
                hints = AppConfig.parseBool(value)
            case "hint-command":
                hintCommand = value
            case "ai-base-url", "ai-endpoint":
                aiBaseURL = value
            case "ai-key", "ai-api-key":
                aiKey = value
            case "ai-model":
                aiModel = value
            case "ai-provider", "ai":
                let v = value.lowercased()
                if ["auto", "apple", "codex", "claude"].contains(v) { aiProvider = v }
            case "claude-model":
                claudeModel = value
            case "codex-model":
                codexModel = value
            case "mcp-auto-register", "mcp-register":
                mcpAutoRegister = AppConfig.parseBool(value)
            case "agent-glow":
                agentGlow = AppConfig.parseBool(value)
            default:
                break // unknown keys (themes, cursor styles, ...) ignored
            }
        }

        if paddingX != nil || paddingY != nil {
            margin = max(paddingX ?? 0, paddingY ?? 0)
        }
    }

    private static func parseBool(_ value: String) -> Bool {
        ["true", "yes", "on", "1"].contains(value.lowercased())
    }

    /// Hex (#RRGGBB / RRGGBB) or a basic color name.
    static func parseColor(_ value: String) -> UInt32? {
        let names: [String: UInt32] = [
            "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000,
            "green": 0x00FF00, "blue": 0x0000FF, "yellow": 0xFFFF00,
            "cyan": 0x00FFFF, "magenta": 0xFF00FF, "orange": 0xFFA500,
            "gray": 0x808080, "grey": 0x808080, "purple": 0x800080,
            "pink": 0xFFC0CB,
        ]
        var v = value.lowercased()
        if let named = names[v] { return named }
        if v.hasPrefix("#") { v.removeFirst() }
        guard v.count == 6, let n = UInt32(v, radix: 16) else { return nil }
        return n
    }

    /// Ghostty palette entry: `N=#RRGGBB` (hex or basic color name), N 0-255.
    /// Anything after the color token (a trailing comment) is ignored.
    static func parsePaletteEntry(_ value: String) -> (index: Int, color: UInt32)? {
        guard let eq = value.firstIndex(of: "=") else { return nil }
        let indexPart = value[..<eq].trimmingCharacters(in: .whitespaces)
        var colorPart = value[value.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if let sp = colorPart.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            colorPart = String(colorPart[..<sp])
        }
        guard let index = Int(indexPart), (0...255).contains(index),
              let color = parseColor(colorPart) else { return nil }
        return (index, color)
    }

    /// Ghostty adjust-cell-* values: "10%" -> multiplier, "3" -> extra points.
    private static func parseAdjust(_ value: String) -> (multiplier: CGFloat, extra: CGFloat)? {
        if value.hasSuffix("%") {
            guard let pct = Double(value.dropLast()) else { return nil }
            return (CGFloat(1.0 + pct / 100.0), 0)
        }
        guard let pts = Double(value) else { return nil }
        return (1.0, CGFloat(pts))
    }

    /// Serialize for the Settings window. Regenerates the whole file.
    func serialize() -> String {
        func hex(_ c: UInt32) -> String { String(format: "#%06X", c) }
        var out = "# infinitty configuration — written by infinitty Settings (⌘,)\n"
        out += "# Edits apply live. See infinitty.conf.example for all keys.\n\n"
        if let f = fontName { out += "font = \(f)\n" }
        if let s = fontStyle, !s.isEmpty { out += "font-style = \(s)\n" }
        out += "font-size = \(Double(fontSize))\n"
        if fontThicken { out += "font-thicken = true\n" }
        out += "margin = \(Double(margin))\n"
        out += "line-spacing = \(Double(lineSpacing))\n"
        out += "kerning = \(Double(kerning))\n"
        if backgroundOpacity < 1 { out += "background-opacity = \(Double(backgroundOpacity))\n" }
        if backgroundBlur { out += "background-blur = true\n" }
        out += "traffic-lights = \(trafficLights)\n"
        if let p = pet, !p.isEmpty {
            out += "pet = \(p)\n"
            out += "pet-scale = \(Double(petScale))\n"
            if petMode != "window" { out += "pet-mode = pane\n" }
        } else {
            // The built-in pet is enabled by default, so an explicit opt-out
            // must survive Settings rewrites and subsequent launches.
            out += "pet = none\n"
        }
        if !agentGlow { out += "agent-glow = false\n" }
        // Settings rewrites the managed config. Do not perpetuate a malformed
        // shortcut that can never be registered; valid-but-currently-busy
        // shortcuts still serialize because registration availability is
        // transient.
        if let key = quickTerminalKey, GlobalHotKeySpec.parse(key) != nil {
            out += "quick-terminal-key = \(key)\n"
        }
        // The remaining quick-terminal settings also govern menu/socket
        // toggles, so they persist independently of the hot key.
        if quickTerminalScreen != .main {
            out += "quick-terminal-screen = \(quickTerminalScreen.rawValue)\n"
        }
        if !quickTerminalAutohide { out += "quick-terminal-autohide = false\n" }
        if quickTerminalAnimationDuration != 0.2 {
            out += "quick-terminal-animation-duration = \(quickTerminalAnimationDuration)\n"
        }
        if hints { out += "hints = true\n" }
        if let v = hintCommand, !v.isEmpty { out += "hint-command = \(v)\n" }
        if let v = aiBaseURL, !v.isEmpty { out += "ai-base-url = \(v)\n" }
        if let v = aiKey, !v.isEmpty { out += "ai-key = \(v)\n" }
        if let v = aiModel, !v.isEmpty { out += "ai-model = \(v)\n" }
        if aiProvider != "auto" { out += "ai-provider = \(aiProvider)\n" }
        if let v = claudeModel, !v.isEmpty { out += "claude-model = \(v)\n" }
        if let v = codexModel, !v.isEmpty { out += "codex-model = \(v)\n" }
        if mcpAutoRegister { out += "mcp-auto-register = true\n" }
        if markdownCommand != "glow -p" { out += "markdown-command = \(markdownCommand)\n" }
        if markdownRender != "off" { out += "markdown-render = \(markdownRender)\n" }
        if notch {
            out += "notch = true\n"
            if notchDisplay != "builtin" { out += "notch-display = \(notchDisplay)\n" }
        }
        if let c = foreground { out += "foreground = \(hex(c))\n" }
        if let c = background { out += "background = \(hex(c))\n" }
        if let c = cursorColor { out += "cursor-color = \(hex(c))\n" }
        if let c = selectionBackground { out += "selection-background = \(hex(c))\n" }
        if let c = accentColor { out += "accent-color = \(hex(c))\n" }
        for (index, color) in palette.sorted(by: { $0.key < $1.key }) {
            out += "palette = \(index)=\(hex(color))\n"
        }
        return out
    }

    /// The path the Settings window writes to (the loaded file, or the
    /// default location when no config exists yet).
    var writePath: String {
        sourcePath ?? NSString(string: "~/.config/infinitty/infinitty.conf").expandingTildeInPath
    }

    private mutating func clamp() {
        fontSize = min(max(fontSize, 6), 72)
        margin = min(max(margin, 0), 64)
        lineSpacing = min(max(lineSpacing, 0.7), 3)
        kerning = min(max(kerning, 0.7), 2)
        cellWidthExtra = min(max(cellWidthExtra, -10), 40)
        cellHeightExtra = min(max(cellHeightExtra, -10), 40)
        petScale = min(max(petScale, 0.1), 2)
        backgroundOpacity = min(max(backgroundOpacity, 0.15), 1)
        quickTerminalAnimationDuration = min(max(quickTerminalAnimationDuration, 0), 2)
    }
}
