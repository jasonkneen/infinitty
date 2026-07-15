import AppKit

/// Docks a small icon view in the window's titlebar. Shows the running
/// process's icon for the active pane of `window` and updates when:
///   * the foreground process changes
///   * focus moves between panes in the same window
///   * the user switches tabs
///
/// In bare-titlebar style (where AppKit hides the titlebar entirely), the
/// accessory is uninstalled and the icon area collapses to nothing.
public final class TabIconAccessory: NSTitlebarAccessoryViewController {
    private weak var hostWindow: NSWindow?
    private let imageView: NSImageView
    private let textField: NSTextField
    private let stack: NSStackView

    /// If true, only the icon is shown. The name goes into `NSWindow.subtitle`
    /// (set by `AppDelegate`). Set to false when the bare titlebar is on so we
    /// can show both inline.
    public var titlebarShowsTitle: Bool = true

    /// Closure invoked when the user wants to switch into a different pane.
    /// `AppDelegate` sets this so a click on the icon can cycle focus.
    public var onClick: (() -> Void)?

    public override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 16).isActive = true

        textField = NSTextField(labelWithString: "")
        textField.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        textField.textColor = .secondaryLabelColor
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isHidden = true

        stack = NSStackView(views: [imageView, textField])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        layoutAttribute = .trailing
        view = stack
        view.frame = NSRect(x: 0, y: 0, width: 96, height: 22)
        stack.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleClick)))
        layout()
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func viewDidAppear() {
        super.viewDidAppear()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(foregroundDidChange(_:)),
            name: ForegroundProcessTracker.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFocusDidChange(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        refreshFromHost()
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        NotificationCenter.default.removeObserver(self)
    }

    public func attach(to window: NSWindow) {
        hostWindow = window
        window.addTitlebarAccessoryViewController(self)
        refreshFromHost()
    }

    public func detach() {
        if let host = hostWindow,
           let idx = host.titlebarAccessoryViewControllers.firstIndex(where: { $0 === self }) {
            host.removeTitlebarAccessoryViewController(at: idx)
        }
        hostWindow = nil
    }

    public func update(info: ForegroundProcessInfo?) {
        imageView.image = info?.icon()
        if let name = info?.displayName, !name.isEmpty {
            if titlebarShowsTitle {
                textField.stringValue = name
                textField.isHidden = false
            } else {
                textField.isHidden = true
            }
            view.isHidden = false
        } else {
            textField.stringValue = ""
            textField.isHidden = true
            // keep the icon area visible at 16px if we have an icon, else hide
            view.isHidden = (imageView.image == nil)
        }
    }

    public func refreshFromHost() {
        guard let host = hostWindow,
              let appDelegate = NSApp.delegate as? AppDelegate else { return }
        let info = appDelegate.foregroundProcessInfo(for: host)
        update(info: info)
        // the matching subtitle lives on the NSWindow itself
        host.subtitle = titlebarShowsTitle ? (info?.displayName ?? "") : ""
    }

    // MARK: - notifications

    @objc private func foregroundDidChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.refreshFromHost() }
    }

    @objc private func windowFocusDidChange(_ note: Notification) {
        guard let note = note.object as? NSWindow, note === hostWindow else { return }
        DispatchQueue.main.async { [weak self] in self?.refreshFromHost() }
    }

    @objc private func handleClick() {
        onClick?()
    }

    // MARK: - layout

    private func layout() {
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // bound the width so the accessory doesn't sprawl the title
        textField.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
    }
}
