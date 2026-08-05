import AppKit
import ShadcnUI
import SwiftUI

/// Infinitty's settings, built from ShadKit.
///
/// Panel names, ordering and fields mirror the AppKit `SettingsWindowController`
/// so the two are interchangeable — same `AppConfig` in, same `onSave` out.
struct ShadcnSettingsView: View {
    @State private var config: AppConfig
    // QA hook: lets a screenshot pass open straight onto a panel.
    @State private var panel: SettingsPanel = SettingsPanel(
        rawValue: ProcessInfo.processInfo.environment["INFINITTY_SETTINGS_PANEL"] ?? ""
    ) ?? .appearance
    private let onSave: (AppConfig) -> Void

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self._config = State(initialValue: config)
        self.onSave = onSave
    }

    /// The theme the *whole settings window* renders in — derived from the
    /// terminal colours, so editing them previews itself immediately.
    private var theme: ShadcnTheme {
        var theme = UISurfaceTheme.theme(for: config)
        theme.typography = theme.typography.scaled(by: config.interfaceFontSize / 15)
        return theme
    }

    /// Secondary label colour, taken from the same derived palette as the rest
    /// of the window.
    private var mutedForeground: Color {
        theme.palette(for: UISurfaceTheme.colorScheme(for: config)).mutedForeground
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ShadcnSeparator(.vertical)
            detail
        }
        .frame(width: 760, height: 560)
        .shadcnSurface(theme)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        SettingsSidebar(panel: $panel)
            .frame(width: 190)
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x6) {
                    switch panel {
                    case .appearance: appearancePanel
                    case .terminal: terminalPanel
                    case .pet: petPanel
                    case .agents: agentsPanel
                    case .about: aboutPanel
                    }
                }
                .padding(Space.x6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ShadcnSeparator()

            HStack {
                Spacer()
                ShadcnButton("Save", size: .small) { onSave(config) }
            }
            .padding(Space.x4)
        }
    }

    // MARK: Panels

    private var appearancePanel: some View {
        Group {
            SettingsSection("Interface") {
                ShadcnSliderRow(
                    "Text size",
                    value: doubleBinding(\.interfaceFontSize),
                    in: 11...22,
                    step: 1
                ) { "\(Int($0))pt" }
                Text("Applies to Chat messages, controls, menus, and ShadKit settings.")
                    .font(theme.typography.sans(theme.typography.sm))
                    .foregroundStyle(
                        mutedForeground)
            }

            SettingsSection("Terminal font") {
                SettingsRow("Family") {
                    ShadcnTextField(
                        "System",
                        text: Binding(
                            get: { config.fontName ?? "" },
                            set: { config.fontName = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .frame(width: 240)
                }
                SettingsRow("Style") {
                    ShadcnTextField(
                        "Regular",
                        text: Binding(
                            get: { config.fontStyle ?? "" },
                            set: { config.fontStyle = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .frame(width: 240)
                }
                ShadcnSliderRow(
                    "Size",
                    value: doubleBinding(\.fontSize),
                    in: 8...32,
                    step: 0.5
                ) { "\($0.formatted(.number.precision(.fractionLength(1))))pt" }
            }

            SettingsSection("Colours") {
                SettingsColorRow("Foreground", value: colorBinding(\.foreground))
                SettingsColorRow("Background", value: colorBinding(\.background))
                SettingsColorRow("Cursor", value: colorBinding(\.cursorColor))
                SettingsColorRow("Selection", value: colorBinding(\.selectionBackground))
                SettingsColorRow("Accent", value: colorBinding(\.accentColor))
            }
        }
    }

    private var terminalPanel: some View {
        Group {
            SettingsSection("Layout") {
                ShadcnSliderRow("Margin", value: doubleBinding(\.margin), in: 0...40, step: 1) {
                    "\(Int($0))"
                }
                ShadcnSliderRow(
                    "Line spacing", value: doubleBinding(\.lineSpacing), in: 0.5...2, step: 0.05)
                ShadcnSliderRow("Kerning", value: doubleBinding(\.kerning), in: 0.5...2, step: 0.05)
            }

            SettingsSection("Window") {
                ShadcnSliderRow(
                    "Opacity", value: doubleBinding(\.backgroundOpacity), in: 0.2...1, step: 0.01)
                SettingsRow("Traffic lights") {
                    ShadcnSelect(
                        "Style",
                        selection: Binding(
                            get: { Optional(config.trafficLights) },
                            set: { config.trafficLights = $0 ?? "circle" }
                        ),
                        width: 180,
                        options: [
                            ("circle", "Circle"), ("square", "Square"),
                            ("rectangle", "Rectangle"), ("diamond", "Diamond"),
                        ]
                    )
                }
            }
        }
    }

    private var petPanel: some View {
        SettingsSection("Pet") {
            SettingsRow("Pet") {
                ShadcnTextField(
                    "infinitty",
                    text: Binding(
                        get: { config.pet ?? "" },
                        set: { config.pet = $0.isEmpty ? nil : $0 }
                    )
                )
                .frame(width: 240)
            }
            SettingsRow("Placement") {
                ShadcnSelect(
                    "Placement",
                    selection: Binding(
                        get: { Optional(config.petMode) },
                        set: { config.petMode = $0 ?? "window" }
                    ),
                    width: 180,
                    options: [("window", "One per window"), ("pane", "Every split")]
                )
            }
            ShadcnSliderRow("Size", value: doubleBinding(\.petScale), in: 0.2...2, step: 0.05)
        }
    }

    private var agentsPanel: some View {
        Group {
            SettingsSection("Notch") {
                SettingsToggleRow("Live activity beside the notch", isOn: $config.notch)
                SettingsRow("Display") {
                    ShadcnSelect(
                        "Display",
                        selection: Binding(
                            get: { Optional(config.notchDisplay) },
                            set: { config.notchDisplay = $0 ?? "builtin" }
                        ),
                        width: 180,
                        options: [
                            ("builtin", "Built-in"), ("external", "External"),
                            ("primary", "Primary"), ("all", "All"),
                        ]
                    )
                }
            }
            SettingsSection("Suggestions") {
                SettingsToggleRow("Inline command hints", isOn: $config.hints)
            }
            SettingsSection("Terminal agents") {
                SettingsToggleRow(
                    "Install Channel context hooks",
                    isOn: $config.mcpAutoRegister)
                Text(
                    "Registers Infinitty MCP and installs idempotent Claude hooks. "
                        + "The shared launcher also supports other CLIs.")
                    .font(theme.typography.sans(theme.typography.sm))
                    .foregroundStyle(mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var aboutPanel: some View {
        SettingsSection("About") {
            ShadcnCard {
                ShadcnCardHeader {
                    ShadcnCardTitle("Infinitty")
                    ShadcnCardDescription(
                        Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                            as? String ?? "development build"
                    )
                }
                ShadcnCardFooter {
                    ShadcnButton("Edit config", variant: .outline, size: .small) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: config.writePath))
                    }
                }
            }
        }
    }

    // MARK: Bindings

    /// `AppConfig` stores metrics as `CGFloat`; the sliders work in `Double`.
    private func doubleBinding(_ path: WritableKeyPath<AppConfig, CGFloat>) -> Binding<Double> {
        Binding(
            get: { Double(config[keyPath: path]) },
            set: { config[keyPath: path] = CGFloat($0) }
        )
    }

    private func colorBinding(_ path: WritableKeyPath<AppConfig, UInt32?>) -> Binding<Color> {
        Binding(
            get: {
                guard let packed = config[keyPath: path] else { return .clear }
                return Color(
                    .sRGB,
                    red: Double((packed >> 16) & 0xFF) / 255,
                    green: Double((packed >> 8) & 0xFF) / 255,
                    blue: Double(packed & 0xFF) / 255
                )
            },
            set: { colour in
                guard let srgb = NSColor(colour).usingColorSpace(.sRGB) else { return }
                let r = UInt32(srgb.redComponent * 255) << 16
                let g = UInt32(srgb.greenComponent * 255) << 8
                let b = UInt32(srgb.blueComponent * 255)
                config[keyPath: path] = r | g | b
            }
        )
    }
}

// MARK: - Panels

enum SettingsPanel: String, CaseIterable, Identifiable {
    case appearance, terminal, pet, agents, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .terminal: "Terminal"
        case .pet: "Pet"
        case .agents: "Agents"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintpalette"
        case .terminal: "terminal"
        case .pet: "pawprint"
        case .agents: "sparkles"
        case .about: "info.circle"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var panel: SettingsPanel

    @Environment(\.shadcnPalette) private var palette
    @Environment(\.shadcnTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(theme.typography.sans(theme.typography.sm, weight: .semibold))
                .padding(.horizontal, Space.x3)
                .padding(.top, Space.x4)
                .padding(.bottom, Space.x2)

            ForEach(SettingsPanel.allCases) { entry in
                SettingsSidebarRow(entry: entry, isSelected: entry == panel) {
                    panel = entry
                }
            }
            Spacer()
        }
        .padding(Space.x2)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.sidebar)
    }
}

private struct SettingsSidebarRow: View {
    let entry: SettingsPanel
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.shadcnPalette) private var palette
    @Environment(\.shadcnTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.x2) {
                ShadcnIconView(entry.systemImage, size: 14)
                Text(entry.title)
                    .font(theme.typography.sans(theme.typography.sm))
                Spacer(minLength: 0)
            }
            .foregroundStyle(
                isSelected ? palette.sidebarAccentForeground : palette.sidebarForeground)
            .padding(.horizontal, Space.x2)
            .padding(.vertical, Space.x1_5)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.md, style: .continuous)
                    .fill(
                        isSelected
                            ? palette.sidebarAccent
                            : (isHovering ? palette.sidebarAccent.opacity(0.5) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.shadcnBare)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Form pieces

private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    @Environment(\.shadcnPalette) private var palette
    @Environment(\.shadcnTheme) private var theme

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text(title)
                .font(theme.typography.sans(theme.typography.xs, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(palette.mutedForeground)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    let content: Content

    @Environment(\.shadcnPalette) private var palette
    @Environment(\.shadcnTheme) private var theme

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: Space.x4) {
            Text(title)
                .font(theme.typography.sans(theme.typography.sm))
                .foregroundStyle(palette.foreground)
                .frame(width: 110, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    @Environment(\.shadcnPalette) private var palette
    @Environment(\.shadcnTheme) private var theme

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: Space.x3) {
            ShadcnSwitch(isOn: $isOn)
            Text(title)
                .font(theme.typography.sans(theme.typography.sm))
                .foregroundStyle(palette.foreground)
            Spacer(minLength: 0)
        }
    }
}

/// Colour row backed by AppKit's picker — there's no SwiftUI equivalent of
/// `NSColorWell` that matches the rest of the form, so the swatch is ours and
/// the picker is the system's.
private struct SettingsColorRow: View {
    let title: String
    @Binding var value: Color

    @Environment(\.shadcnPalette) private var palette
    @Environment(\.shadcnTheme) private var theme

    init(_ title: String, value: Binding<Color>) {
        self.title = title
        self._value = value
    }

    var body: some View {
        HStack(spacing: Space.x4) {
            Text(title)
                .font(theme.typography.sans(theme.typography.sm))
                .foregroundStyle(palette.foreground)
                .frame(width: 110, alignment: .leading)

            ColorPicker("", selection: $value, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Window host

/// Drop-in replacement for `SettingsWindowController`, same init shape.
final class ShadcnSettingsWindowController: NSWindowController {
    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Infinitty Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: ShadcnSettingsView(config: config, onSave: onSave))
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}
