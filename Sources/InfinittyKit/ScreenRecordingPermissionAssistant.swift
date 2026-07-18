import AppKit
import CoreGraphics

final class ScreenRecordingPermissionAssistant {
    static let shared = ScreenRecordingPermissionAssistant()
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!
    static let hasPresentedDefaultsKey = "hasPresentedScreenRecordingPermissionAssistant"

    enum LaunchAction: Equatable {
        case showExplicitly
        case showAutomatically
        case none
    }

    private let defaults: UserDefaults
    private var panel: NSPanel?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func launchAction(environment: [String: String]) -> LaunchAction {
        if environment["INFINITTY_SHOW_SCREEN_RECORDING_PERMISSION"] != nil {
            return .showExplicitly
        }
        if environment["INFINITTY_NO_ACTIVATE"] != nil {
            return .none
        }
        return .showAutomatically
    }

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

    func showAutomaticallyIfNeeded() {
        let appURL = Bundle.main.bundleURL
        guard Self.shouldPresentAutomatically(
            permissionGranted: CGPreflightScreenCaptureAccess(),
            hasPresented: defaults.bool(forKey: Self.hasPresentedDefaultsKey),
            isPackagedApp: Self.isDraggableAppURL(appURL)
        ) else { return }

        defaults.set(true, forKey: Self.hasPresentedDefaultsKey)
        show()
    }

    func show() {
        NSWorkspace.shared.open(Self.settingsURL)

        let appURL = Bundle.main.bundleURL
        let draggableURL = Self.isDraggableAppURL(appURL) ? appURL : nil
        let assistantPanel = panel ?? makePanel()
        let content = ScreenRecordingPermissionDragView(
            frame: NSRect(origin: .zero, size: assistantPanel.frame.size),
            appURL: draggableURL
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
        let panel = ScreenRecordingPermissionPanel(
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

private final class ScreenRecordingPermissionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ScreenRecordingPermissionDragView: NSVisualEffectView, NSDraggingSource {
    var onClose: (() -> Void)?

    private let appURL: URL?
    private let cardFrame = NSRect(x: 16, y: 16, width: 348, height: 64)
    private let appIcon: NSImage

    init(frame frameRect: NSRect, appURL: URL?) {
        self.appURL = appURL
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

        let title = NSTextField(labelWithString: "Drag Infinitty into Screen Recording")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.frame = NSRect(x: 16, y: 112, width: 315, height: 20)
        addSubview(title)

        let detail = NSTextField(labelWithString: "Then enable its switch in System Settings.")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 16, y: 91, width: 315, height: 17)
        addSubview(detail)

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
        setAccessibilityLabel("Screen Recording permission assistant")
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
