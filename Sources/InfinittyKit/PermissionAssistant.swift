import AppKit

/// Shared machinery behind the permission assistant panels.
///
/// macOS has no API to request Full Disk Access or Screen Recording on the
/// user's behalf — the only supported flow is to open the relevant System
/// Settings pane and have the user add the app themselves. These panels open
/// the pane and hand over a draggable copy of the bundle so the drop target
/// is a single gesture away.
class PermissionAssistant {
    enum LaunchAction: Equatable {
        case showExplicitly
        case showAutomatically
        case none
    }

    let settingsURL: URL
    let defaultsKey: String

    private let title: String
    private let detail: String
    private let accessibilityLabel: String
    private let defaults: UserDefaults
    private var panel: NSPanel?

    init(
        settingsURL: URL,
        defaultsKey: String,
        title: String,
        detail: String,
        accessibilityLabel: String,
        defaults: UserDefaults = .standard
    ) {
        self.settingsURL = settingsURL
        self.defaultsKey = defaultsKey
        self.title = title
        self.detail = detail
        self.accessibilityLabel = accessibilityLabel
        self.defaults = defaults
    }

    /// Whether macOS currently grants the permission. Subclasses override.
    var isGranted: Bool { true }

    static func isDraggableAppURL(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "app" else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func shouldPresentAutomatically(
        permissionGranted: Bool,
        hasPresented: Bool,
        isPackagedApp: Bool
    ) -> Bool {
        !permissionGranted && !hasPresented && isPackagedApp
    }

    /// Presents the panel if the permission is missing and we have not nagged
    /// about it before. Returns whether it actually presented, so callers can
    /// show at most one assistant per launch instead of stacking panels.
    @discardableResult
    func showAutomaticallyIfNeeded() -> Bool {
        let appURL = Bundle.main.bundleURL
        guard Self.shouldPresentAutomatically(
            permissionGranted: isGranted,
            hasPresented: defaults.bool(forKey: defaultsKey),
            isPackagedApp: Self.isDraggableAppURL(appURL)
        ) else { return false }

        defaults.set(true, forKey: defaultsKey)
        show()
        return true
    }

    func show() {
        NSWorkspace.shared.open(settingsURL)

        let appURL = Bundle.main.bundleURL
        let draggableURL = Self.isDraggableAppURL(appURL) ? appURL : nil
        let assistantPanel = panel ?? makePanel()
        let content = PermissionAssistantDragView(
            frame: NSRect(origin: .zero, size: assistantPanel.frame.size),
            appURL: draggableURL,
            title: title,
            detail: detail,
            accessibilityLabel: accessibilityLabel
        )
        content.onClose = { [weak assistantPanel] in
            assistantPanel?.orderOut(nil)
        }
        assistantPanel.contentView = content
        position(assistantPanel)
        assistantPanel.orderFrontRegardless()
        panel = assistantPanel
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 380, height: 150)
        let panel = PermissionAssistantPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visibleFrame.minX + 40,
            y: visibleFrame.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}

private final class PermissionAssistantPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PermissionAssistantDragView: NSVisualEffectView, NSDraggingSource {
    var onClose: (() -> Void)?

    private let appURL: URL?
    private let title: String
    private let detail: String
    private let accessibilityLabel: String
    private let cardFrame = NSRect(x: 16, y: 16, width: 348, height: 64)
    private let appIcon: NSImage

    init(
        frame frameRect: NSRect,
        appURL: URL?,
        title: String,
        detail: String,
        accessibilityLabel: String
    ) {
        self.appURL = appURL
        self.title = title
        self.detail = detail
        self.accessibilityLabel = accessibilityLabel
        if let appURL {
            appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
        } else {
            appIcon = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
                ?? NSImage()
        }
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 16, y: 112, width: 315, height: 20)
        addSubview(titleLabel)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.frame = NSRect(x: 16, y: 91, width: 315, height: 17)
        addSubview(detailLabel)

        let close = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") ?? NSImage(),
            target: self,
            action: #selector(closeTapped(_:))
        )
        close.isBordered = false
        close.bezelStyle = .shadowlessSquare
        close.contentTintColor = .secondaryLabelColor
        close.frame = NSRect(x: 340, y: 112, width: 24, height: 24)
        addSubview(close)

        addSubview(makeAppCard())

        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilityLabel)
    }

    private func makeAppCard() -> NSView {
        let card = NSView(frame: cardFrame)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        card.layer?.cornerRadius = 11
        card.layer?.borderWidth = 0.6
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.8).cgColor
        card.alphaValue = appURL == nil ? 0.6 : 1

        let icon = NSImageView(frame: NSRect(x: 14, y: 14, width: 36, height: 36))
        icon.image = appIcon
        icon.imageScaling = .scaleProportionallyUpOrDown
        card.addSubview(icon)

        let appName = NSTextField(labelWithString: appURL == nil
            ? "Packaged Infinitty.app required"
            : "Infinitty.app")
        appName.font = .systemFont(ofSize: 13, weight: .semibold)
        appName.textColor = .labelColor
        appName.frame = NSRect(x: 62, y: 32, width: 265, height: 18)
        card.addSubview(appName)

        let hint = NSTextField(labelWithString: appURL == nil
            ? "Launch the app bundle, not the SwiftPM executable"
            : "Drag this item into the permissions list")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 62, y: 14, width: 265, height: 15)
        card.addSubview(hint)
        return card
    }

    @objc private func closeTapped(_ sender: Any?) {
        onClose?()
    }

    override func mouseDown(with event: NSEvent) {
        guard let appURL,
              cardFrame.contains(convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }

        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        let dragFrame = NSRect(
            x: cardFrame.minX + 14,
            y: cardFrame.minY + 14,
            width: 36,
            height: 36
        )
        item.setDraggingFrame(dragFrame, contents: appIcon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }
}
