import AIElementsGallery
import AppKit
import ShadcnUI
import SwiftUI

/// Hosts the ShadKit gallery in its own window.
///
/// This is how the component set gets dogfooded inside the app: the same
/// package a third-party project would consume by URL is rendered here against
/// real app chrome, so regressions show up while working on Infinitty rather
/// than only in the package's own demo.
public final class DesignGalleryWindowController: NSWindowController {
    /// One shared window — reopening focuses the existing one.
    private static var shared: DesignGalleryWindowController?

    public static func present() {
        if let existing = shared, existing.window != nil {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = DesignGalleryWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Design Gallery"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ShadcnAIGallery())
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public override func windowWillLoad() {
        super.windowWillLoad()
    }
}
