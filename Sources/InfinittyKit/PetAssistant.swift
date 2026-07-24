import Foundation

/// Append-only tracer for the pet-assistant ask path, so a GUI-only failure
/// ("I hit send, nothing happens") leaves evidence in /tmp/infinitty-pet.log.
/// Best-effort — never throws, never blocks the UI meaningfully.
enum PetLog {
    private static let url = URL(fileURLWithPath: "/tmp/infinitty-pet.log")
    private static let queue = DispatchQueue(label: "infinitty.petlog")
    static func log(_ message: String) {
        queue.async {
            let line = "[\(ProcessInfo.processInfo.systemUptime)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A top-anchored document view so stacked chat bubbles fill from the top and
/// the scroll view pins new messages at the bottom naturally.
final class FlippedClipDocument: NSView {
    override var isFlipped: Bool { true }
}

struct AssistantChatMessage {
    let role: String
    let text: String
    let createdAt: Date
    let tokenCount: Int?

    init(role: String, text: String, createdAt: Date = Date(), tokenCount: Int? = nil) {
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.tokenCount = tokenCount
    }

    static func approximateTokenCount(for text: String) -> Int {
        max(1, Int(ceil(Double(text.utf8.count) / 4.0)))
    }
}

/// One chat message row spanning the full transcript width. User turns show a
/// right-aligned rounded accent bubble (≤78% width); assistant turns render as
/// full-width flowing text on the transparent surface — the ChatGPT/Stream
/// layout convention.
final class ChatMessageView: NSView {
    static var accent: NSColor { CodePalette.selectionAccent }
    private let messageText: String
    private let timestamp: Date
    private weak var timeLabel: NSTextField?
    private weak var contentLabel: NSTextField?
    private weak var metadataView: NSView?
    private var timeRefreshTimer: Timer?

    init(role: String, text: String, timestamp: Date = Date(), tokenCount: Int? = nil) {
        messageText = text
        self.timestamp = timestamp
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let isUser = role.caseInsensitiveCompare("You") == .orderedSame

        let label = NSTextField(wrappingLabelWithString: text)
        contentLabel = label
        label.isSelectable = true
        label.isEditable = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.systemFontSize)

        if isUser {
            let bubble = NSView()
            bubble.wantsLayer = true
            bubble.layer?.backgroundColor = Self.accent.cgColor
            bubble.layer?.cornerRadius = 13
            bubble.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .white
            bubble.addSubview(label)
            addSubview(bubble)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 7),
                label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -7),
                label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
                bubble.topAnchor.constraint(equalTo: topAnchor),
                bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
                bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
                bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 44),
                bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.78),
            ])
        } else {
            label.attributedStringValue = MarkdownRender.attributed(text, style: .chat)
            label.allowsEditingTextAttributes = true
            let timeLabel = NSTextField(labelWithString: Self.relativeTime(since: timestamp))
            timeLabel.font = .systemFont(ofSize: 10)
            timeLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
            let estimatedTokens = tokenCount
                ?? AssistantChatMessage.approximateTokenCount(for: text)
            let tokenLabel = NSTextField(labelWithString: "~\(estimatedTokens) tokens")
            tokenLabel.font = .systemFont(ofSize: 10)
            tokenLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
            let copyButton = NSButton()
            copyButton.image = NSImage(
                systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy reply")
            copyButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            copyButton.imagePosition = .imageOnly
            copyButton.isBordered = false
            copyButton.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
            copyButton.target = self
            copyButton.action = #selector(copyReply)
            let metadata = NSStackView(views: [timeLabel, tokenLabel, copyButton])
            metadata.orientation = .horizontal
            metadata.alignment = .centerY
            metadata.spacing = 7
            metadata.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            addSubview(metadata)
            self.timeLabel = timeLabel
            metadataView = metadata
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                self?.refreshRelativeTime()
            }
            RunLoop.main.add(timer, forMode: .common)
            timeRefreshTimer = timer
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: topAnchor),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                metadata.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 3),
                metadata.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                metadata.bottomAnchor.constraint(equalTo: bottomAnchor),
                copyButton.widthAnchor.constraint(equalToConstant: 18),
                copyButton.heightAnchor.constraint(equalToConstant: 16),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { timeRefreshTimer?.invalidate() }

    private static func relativeTime(since date: Date, now: Date = Date()) -> String {
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }

    @objc private func copyReply() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([messageText as NSString])
    }

    private func refreshRelativeTime() {
        timeLabel?.stringValue = Self.relativeTime(since: timestamp)
    }

    var metadataGapForTesting: CGFloat? {
        guard let contentLabel, let metadataView else { return nil }
        return max(
            contentLabel.frame.minY - metadataView.frame.maxY,
            metadataView.frame.minY - contentLabel.frame.maxY,
            0)
    }
}

/// A compact pending user turn. Pending turns stay immediately above the
/// composer until the active request finishes, then move into the transcript
/// as the next real conversation turn.
final class QueuedChatMessageView: NSView {
    init(text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = CodePalette.selectionAccent.withAlphaComponent(0.48).cgColor
        bubble.layer?.cornerRadius = 10
        bubble.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor.white.withAlphaComponent(0.82)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        bubble.addSubview(label)
        addSubview(bubble)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -5),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -10),
            bubble.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 44),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.78),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class PrimaryMenuButton: NSButton {
    override func mouseDown(with event: NSEvent) { showMenu() }
    override func performClick(_ sender: Any?) { showMenu() }

    private func showMenu() {
        menu?.popUp(
            positioning: menu?.items.first(where: { $0.state == .on }),
            at: NSPoint(x: 0, y: bounds.maxY + 2), in: self)
    }
}

/// Status row shown while the assistant generates. Says what is actually
/// happening — which model is thinking and for how long — instead of an
/// anonymous dot animation.
final class ChatTypingIndicator: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let baseText: String
    private var startedAt = Date()
    private var elapsedTimer: Timer?

    init(label baseText: String = "Thinking") {
        self.baseText = baseText
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.85)
        label.stringValue = baseText + "…"
        label.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [spinner, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { elapsedTimer?.invalidate() }

    func startAnimating() {
        spinner.startAnimation(nil)
        startedAt = Date()
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshElapsed()
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
        refreshElapsed()
    }

    private func refreshElapsed() {
        let seconds = Int(Date().timeIntervalSince(startedAt))
        label.stringValue = seconds < 2
            ? baseText + "…"
            : baseText + "… \(seconds)s"
    }

    var labelTextForTesting: String { label.stringValue }
}

/// Full-height presentation of the pet assistant for the sidebar CHAT page.
/// It owns its own AppKit views while sharing the assistant's request state.
final class PetAssistantPanelView: NSView {
    enum Presentation: Equatable {
        case sidebar
        case popover
    }

    private let presentation: Presentation
    private let config: AppConfig
    private let glassBackground = NSVisualEffectView()
    var onSubmit: ((String, String, String) -> Void)?
    /// Concrete model choices for the composer picker, injected at init so
    /// UI construction stays machine-independent and testable.
    private let choices: [PetAssistant.AgentChoice]
    var onShowFiles: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onClose: (() -> Void)?

    private let newChatButton = NSButton(title: "New", target: nil, action: nil)
    private let closeButton = NSButton()
    private let separator = NSView()
    private let transcriptStack = NSStackView()
    private let transcriptScroll = NSScrollView()
    private let queueStack = NSStackView()
    private let queueScroll = NSScrollView()
    private var queueHeightConstraint: NSLayoutConstraint!
    private let emptyStateLabel = NSTextField(
        labelWithString: "Choose an agent, ask a question, and keep chatting here.")
    // Hidden state stores: the pickers keep selection + agent-control APIs
    // stable while the visible controls are the quiet chip buttons below.
    private let modelPicker = NSPopUpButton()
    private let effortPicker = NSPopUpButton()
    private let modelButton = PrimaryMenuButton()
    private let effortButton = PrimaryMenuButton()
    private let inputContainer = NSView()
    private let inputScroll = NSScrollView()
    private let input = TabRenameTextView()
    private let attachmentButton = NSButton()
    private let sendButton = NSButton()
    private let sendWrap = NSView()
    private let showFilesButton = NSButton(title: "Show Files", target: nil, action: nil)
    private var queuedMessages: [String] = []

    init(presentation: Presentation, config: AppConfig,
         choices: [PetAssistant.AgentChoice] = [.auto]) {
        self.presentation = presentation
        self.config = config
        self.choices = choices
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        configureSurface()
        configureHeader()
        configureMessages()
        configureComposer()
        installSubviewsAndConstraints()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configureSurface() {
        wantsLayer = true
        layer?.cornerRadius = presentation == .popover ? 16 : 14
        layer?.masksToBounds = true

        if presentation == .popover {
            layer?.backgroundColor = NSColor.clear.cgColor
            glassBackground.material = .hudWindow
            glassBackground.blendingMode = .behindWindow
            glassBackground.state = .active
            glassBackground.wantsLayer = true
            glassBackground.layer?.cornerRadius = 16
            glassBackground.layer?.borderWidth = 1
            glassBackground.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
            glassBackground.layer?.masksToBounds = true
        } else {
            // Sidebar chat sits directly on the terminal-theme (black) host —
            // no panel fill or border.
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    private func configureHeader() {
        newChatButton.image = NSImage(
            systemSymbolName: "plus", accessibilityDescription: "New chat")
        newChatButton.imagePosition = .imageLeading
        newChatButton.isBordered = false
        newChatButton.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        newChatButton.contentTintColor = .labelColor
        newChatButton.target = self
        newChatButton.action = #selector(newChatTapped)
        newChatButton.isHidden = presentation == .sidebar

        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = presentation == .sidebar

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        separator.isHidden = presentation == .sidebar
    }

    private func configureMessages() {
        // Bubble transcript: a vertical stack of per-message views inside a
        // scroll view. Assistant replies render as plain text on the black
        // surface; user messages get a rounded bubble panel.
        transcriptStack.orientation = .vertical
        transcriptStack.alignment = .width
        transcriptStack.distribution = .fill
        transcriptStack.spacing = 14
        transcriptStack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 10, right: 0)
        transcriptStack.translatesAutoresizingMaskIntoConstraints = false
        let flipped = FlippedClipDocument()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(transcriptStack)
        transcriptScroll.borderType = .noBorder
        transcriptScroll.drawsBackground = false
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.documentView = flipped
        transcriptScroll.isHidden = true
        NSLayoutConstraint.activate([
            flipped.leadingAnchor.constraint(equalTo: transcriptScroll.contentView.leadingAnchor),
            flipped.trailingAnchor.constraint(equalTo: transcriptScroll.contentView.trailingAnchor),
            flipped.topAnchor.constraint(equalTo: transcriptScroll.contentView.topAnchor),
            transcriptStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            transcriptStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            transcriptStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            transcriptStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])

        queueStack.orientation = .vertical
        queueStack.alignment = .width
        queueStack.distribution = .fill
        queueStack.spacing = 4
        queueStack.edgeInsets = NSEdgeInsets(top: 1, left: 0, bottom: 1, right: 0)
        queueStack.translatesAutoresizingMaskIntoConstraints = false
        let queueDocument = FlippedClipDocument()
        queueDocument.translatesAutoresizingMaskIntoConstraints = false
        queueDocument.addSubview(queueStack)
        queueScroll.borderType = .noBorder
        queueScroll.drawsBackground = false
        queueScroll.hasVerticalScroller = true
        queueScroll.autohidesScrollers = true
        queueScroll.documentView = queueDocument
        queueScroll.isHidden = true
        NSLayoutConstraint.activate([
            queueDocument.leadingAnchor.constraint(equalTo: queueScroll.contentView.leadingAnchor),
            queueDocument.trailingAnchor.constraint(equalTo: queueScroll.contentView.trailingAnchor),
            queueDocument.topAnchor.constraint(equalTo: queueScroll.contentView.topAnchor),
            queueStack.topAnchor.constraint(equalTo: queueDocument.topAnchor),
            queueStack.leadingAnchor.constraint(equalTo: queueDocument.leadingAnchor),
            queueStack.trailingAnchor.constraint(equalTo: queueDocument.trailingAnchor),
            queueStack.bottomAnchor.constraint(equalTo: queueDocument.bottomAnchor),
        ])

        emptyStateLabel.font = .systemFont(ofSize: 12, weight: .regular)
        emptyStateLabel.textColor = NSColor(white: 0.56, alpha: 1)
        emptyStateLabel.alignment = .left
        emptyStateLabel.lineBreakMode = .byWordWrapping
        emptyStateLabel.maximumNumberOfLines = 2

        showFilesButton.target = self
        showFilesButton.action = #selector(showFilesTapped)
        showFilesButton.bezelStyle = .inline
        showFilesButton.font = .systemFont(ofSize: 12, weight: .medium)
        showFilesButton.contentTintColor = .labelColor
        showFilesButton.isHidden = true
    }

    private func configureComposer() {
        modelPicker.controlSize = .small
        modelPicker.font = .systemFont(ofSize: 13, weight: .medium)
        modelPicker.menu?.removeAllItems()
        for choice in choices {
            let item = NSMenuItem(title: choice.displayName, action: nil, keyEquivalent: "")
            item.representedObject = choice
            item.image = PetAssistantPanelView.providerImage(for: choice)
            modelPicker.menu?.addItem(item)
        }
        modelPicker.isHidden = true

        effortPicker.controlSize = .regular
        effortPicker.font = .systemFont(ofSize: NSFont.systemFontSize)
        effortPicker.menu?.removeAllItems()
        for level in ["Auto", "None", "Low", "Medium", "High"] {
            effortPicker.menu?.addItem(
                NSMenuItem(title: level, action: nil, keyEquivalent: ""))
        }
        effortPicker.selectItem(at: 0)
        effortPicker.isHidden = true

        styleChip(modelButton)
        modelButton.imagePosition = .imageLeading
        modelButton.menu = makeModelMenu()
        refreshModelChip()

        styleChip(effortButton)
        effortButton.menu = makeEffortMenu()
        refreshEffortChip()

        inputContainer.wantsLayer = true
        inputContainer.layer?.backgroundColor = NSColor(white: 0.055, alpha: 0.72).cgColor
        inputContainer.layer?.cornerRadius = 11
        inputContainer.layer?.borderWidth = 1
        inputContainer.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor

        attachmentButton.image = NSImage(
            systemSymbolName: "paperclip", accessibilityDescription: "Attach")
        attachmentButton.isBordered = false
        attachmentButton.contentTintColor = .secondaryLabelColor
        attachmentButton.target = self
        attachmentButton.action = #selector(attachmentTapped)

        input.font = .systemFont(ofSize: NSFont.systemFontSize)
        input.textColor = .labelColor
        input.insertionPointColor = .labelColor
        input.drawsBackground = false
        input.isRichText = false
        input.isVerticallyResizable = false
        input.isHorizontallyResizable = true
        input.autoresizingMask = [.height]
        input.frame = NSRect(x: 0, y: 0, width: 200, height: 32)
        input.minSize = NSSize(width: 0, height: 32)
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 32)
        input.textContainerInset = NSSize(width: 3, height: 7)
        input.textContainer?.lineFragmentPadding = 0
        input.textContainer?.maximumNumberOfLines = 1
        input.textContainer?.lineBreakMode = .byClipping
        input.textContainer?.widthTracksTextView = false
        input.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: 32)
        input.onCommit = { [weak self] in self?.submit() }

        inputScroll.borderType = .noBorder
        inputScroll.drawsBackground = false
        inputScroll.hasHorizontalScroller = false
        inputScroll.hasVerticalScroller = false
        inputScroll.documentView = input

        let sendConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        sendButton.image = NSImage(
            systemSymbolName: "arrow.up", accessibilityDescription: "Send")?
            .withSymbolConfiguration(sendConfig)
        sendButton.isBordered = false
        sendButton.imagePosition = .imageOnly
        sendButton.bezelStyle = .regularSquare
        sendButton.focusRingType = .none
        sendButton.contentTintColor = .white
        sendButton.target = self
        sendButton.action = #selector(sendTapped)

        // The circle lives on a fixed-size wrapper, not the button: NSButton's
        // .regularSquare bezel installs a required intrinsic-height constraint
        // (~36pt) that beats an explicit height, distorting the button into a
        // vertical oval. The wrapper is a plain NSView, so its 30x30 is exact.
        sendWrap.wantsLayer = true
        sendWrap.layer?.backgroundColor = CodePalette.selectionAccent.cgColor
        sendWrap.layer?.cornerRadius = 15
        sendWrap.layer?.masksToBounds = true
    }

    /// The composer's currently-selected model choice. Read at submit time.
    var selectedChoice: PetAssistant.AgentChoice {
        modelPicker.selectedItem?.representedObject as? PetAssistant.AgentChoice ?? .auto
    }

    /// The composer's selected reasoning effort (Auto/Low/Medium/High).
    var selectedEffort: String { effortPicker.titleOfSelectedItem ?? "Auto" }

    /// Agent/self-control: select a model by name — exact title first (e.g.
    /// "Claude Sonnet 5"), then a case-insensitive substring ("claude",
    /// "gpt", "auto"). Returns false if nothing matched.
    @discardableResult
    func selectModel(named name: String) -> Bool {
        let q = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, let items = modelPicker.menu?.items else { return false }
        if let item = items.first(where: { $0.title.lowercased() == q })
            ?? items.first(where: { $0.title.lowercased().contains(q) }) {
            modelPicker.select(item)
            refreshModelChip()
            return true
        }
        return false
    }

    @discardableResult
    func selectProvider(_ kind: PetAssistant.AgentChoice.Kind) -> Bool {
        guard let item = modelPicker.menu?.items.first(where: {
            ($0.representedObject as? PetAssistant.AgentChoice)?.kind == kind
        }) else { return false }
        modelPicker.select(item)
        refreshModelChip()
        return true
    }

    /// Agent/self-control: select reasoning effort by name (auto/low/medium/high).
    @discardableResult
    func selectEffort(named name: String) -> Bool {
        let q = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, let items = effortPicker.menu?.items else { return false }
        if let item = items.first(where: { $0.title.lowercased() == q }) {
            effortPicker.select(item)
            refreshEffortChip()
            return true
        }
        return false
    }

    /// Provider glyph for a picker row: the real models.dev brand logo
    /// (bundled SVG, tinted as a template) for Claude/Codex/Apple, or the
    /// SF Symbol for Auto / when an asset is missing.
    static func providerImage(for choice: PetAssistant.AgentChoice) -> NSImage? {
        let logoAsset: String?
        switch choice.kind {
        case .claude: logoAsset = "anthropic"
        case .codex: logoAsset = "openai"
        case .apple: logoAsset = "apple"
        case .auto: logoAsset = nil
        }
        if let logoAsset,
           let url = Bundle.main.url(
               forResource: logoAsset, withExtension: "svg", subdirectory: "Logos")
               ?? Bundle.module.url(
                   forResource: logoAsset, withExtension: "svg", subdirectory: "Logos"),
           let data = try? Data(contentsOf: url),
           let image = NSImage(data: data), image.isValid {
            image.size = NSSize(width: 14, height: 14)
            image.isTemplate = true
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                choice.tint.set()
                rect.fill()
                image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
                return true
            }
            tinted.isTemplate = false
            return tinted
        }
        guard let symbol = NSImage(
            systemSymbolName: choice.symbolName, accessibilityDescription: choice.displayName)
        else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: choice.tint))
        return symbol.withSymbolConfiguration(cfg)
    }

    override func layout() {
        super.layout()
        let side = min(sendWrap.bounds.width, sendWrap.bounds.height)
        if side > 0 { sendWrap.layer?.cornerRadius = side / 2 }
        let clip = inputScroll.contentView.bounds
        guard clip.width > 0, clip.height > 0 else { return }
        input.minSize = NSSize(width: 0, height: clip.height)
        input.frame = NSRect(x: 0, y: 0, width: clip.width, height: clip.height)
        input.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: clip.height)
    }

    private func installSubviewsAndConstraints() {
        if presentation == .popover {
            glassBackground.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glassBackground)
            NSLayoutConstraint.activate([
                glassBackground.topAnchor.constraint(equalTo: topAnchor),
                glassBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
                glassBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
                glassBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        inputContainer.addSubview(attachmentButton)
        inputContainer.addSubview(inputScroll)
        sendWrap.addSubview(sendButton)
        inputContainer.addSubview(sendWrap)
        let views = [
            newChatButton, closeButton,
            separator, transcriptScroll, emptyStateLabel, showFilesButton, queueScroll,
            modelPicker, modelButton, effortButton, inputContainer, attachmentButton,
            inputScroll, sendButton, sendWrap,
        ]
        for view in views { view.translatesAutoresizingMaskIntoConstraints = false }
        for view in [
            newChatButton, closeButton, separator,
            transcriptScroll, emptyStateLabel, showFilesButton, queueScroll,
            modelButton, effortButton, inputContainer,
        ] { addSubview(view) }

        NSLayoutConstraint.activate(headerConstraints() + bodyConstraints() + composerConstraints())
    }

    private func headerConstraints() -> [NSLayoutConstraint] {
        if presentation == .sidebar { return [] }
        let newChatTrailing = presentation == .popover
            ? newChatButton.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8)
            : newChatButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -13)
        return [
            newChatButton.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            newChatButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            newChatTrailing,
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            closeButton.centerYAnchor.constraint(equalTo: newChatButton.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            separator.topAnchor.constraint(equalTo: topAnchor, constant: 46),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ]
    }

    private func bodyConstraints() -> [NSLayoutConstraint] {
        let transcriptTop = presentation == .sidebar
            ? transcriptScroll.topAnchor.constraint(equalTo: topAnchor)
            : transcriptScroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4)
        let emptyTop = presentation == .sidebar
            ? emptyStateLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2)
            : emptyStateLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 18)
        queueHeightConstraint = queueScroll.heightAnchor.constraint(equalToConstant: 0)
        return [
            transcriptTop,
            transcriptScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            transcriptScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            transcriptScroll.bottomAnchor.constraint(equalTo: queueScroll.topAnchor, constant: -6),
            emptyTop,
            emptyStateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            showFilesButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            showFilesButton.bottomAnchor.constraint(equalTo: queueScroll.topAnchor, constant: -6),
            queueScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            queueScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            queueScroll.bottomAnchor.constraint(equalTo: inputContainer.topAnchor, constant: -6),
            queueHeightConstraint,
        ]
    }

    private func composerConstraints() -> [NSLayoutConstraint] {
        [
            inputContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            inputContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            inputContainer.bottomAnchor.constraint(equalTo: modelButton.topAnchor, constant: -7),
            inputContainer.heightAnchor.constraint(equalToConstant: 44),
            modelButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            modelButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            modelButton.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            effortButton.leadingAnchor.constraint(equalTo: modelButton.trailingAnchor, constant: 6),
            effortButton.centerYAnchor.constraint(equalTo: modelButton.centerYAnchor),
            effortButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            attachmentButton.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 8),
            attachmentButton.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            attachmentButton.widthAnchor.constraint(equalToConstant: 24),
            inputScroll.leadingAnchor.constraint(equalTo: attachmentButton.trailingAnchor, constant: 4),
            inputScroll.trailingAnchor.constraint(equalTo: sendWrap.leadingAnchor, constant: -6),
            inputScroll.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            inputScroll.heightAnchor.constraint(equalToConstant: 32),
            sendWrap.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -7),
            sendWrap.bottomAnchor.constraint(equalTo: inputContainer.bottomAnchor, constant: -7),
            sendWrap.widthAnchor.constraint(equalToConstant: 30),
            sendWrap.heightAnchor.constraint(equalToConstant: 30),
            sendButton.centerXAnchor.constraint(equalTo: sendWrap.centerXAnchor),
            sendButton.centerYAnchor.constraint(equalTo: sendWrap.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 30),
            sendButton.heightAnchor.constraint(equalToConstant: 30),
        ]
    }

    private var lastMessages: [AssistantChatMessage] = []
    private var typingIndicator: ChatTypingIndicator?

    func setMessages(_ messages: [AssistantChatMessage]) {
        lastMessages = messages
        rebuildTranscript()
    }

    func setMessages(_ messages: [(role: String, text: String)]) {
        setMessages(messages.map { AssistantChatMessage(role: $0.role, text: $0.text) })
    }

    func setQueuedMessages(_ messages: [String]) {
        queuedMessages = messages
        queueStack.arrangedSubviews.forEach {
            queueStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for message in messages {
            queueStack.addArrangedSubview(QueuedChatMessageView(text: message))
        }
        queueScroll.isHidden = messages.isEmpty
        queueHeightConstraint?.constant = messages.isEmpty
            ? 0
            : min(CGFloat(messages.count) * 32 + CGFloat(max(messages.count - 1, 0)) * 4, 92)
        layoutSubtreeIfNeeded()
        if let document = queueScroll.documentView {
            queueScroll.contentView.scrollToVisible(
                NSRect(x: 0, y: document.bounds.maxY - 1, width: 1, height: 1))
        }
    }

    private func rebuildTranscript() {
        transcriptStack.arrangedSubviews.forEach {
            transcriptStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for message in lastMessages {
            let row = ChatMessageView(
                role: message.role, text: message.text,
                timestamp: message.createdAt, tokenCount: message.tokenCount)
            transcriptStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor).isActive = true
        }
        if let typingIndicator {
            transcriptStack.addArrangedSubview(typingIndicator)
            typingIndicator.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor).isActive = true
            typingIndicator.startAnimating()
        }
        let showTranscript = !lastMessages.isEmpty || typingIndicator != nil
        emptyStateLabel.isHidden = showTranscript
        transcriptScroll.isHidden = !showTranscript
        layoutSubtreeIfNeeded()
        if let doc = transcriptScroll.documentView {
            transcriptScroll.contentView.scrollToVisible(
                NSRect(x: 0, y: doc.bounds.maxY - 1, width: 1, height: 1))
        }
    }

    func setThinking(_ thinking: Bool, label: String? = nil) {
        input.isEditable = true
        sendWrap.alphaValue = 1
        if thinking, typingIndicator == nil {
            typingIndicator = ChatTypingIndicator(label: label ?? "Thinking")
            rebuildTranscript()
        } else if !thinking, typingIndicator != nil {
            typingIndicator = nil
            rebuildTranscript()
        }
    }

    func setHasFiles(_ hasFiles: Bool) { showFilesButton.isHidden = !hasFiles }

    func focusInput() { window?.makeFirstResponder(input) }

    private func submit() {
        let request = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        input.string = ""
        onSubmit?(request, selectedChoice.displayName, selectedEffort)
    }

    @objc private func sendTapped(_ sender: Any?) { submit() }
    @objc private func showFilesTapped(_ sender: Any?) { onShowFiles?() }
    @objc private func newChatTapped(_ sender: Any?) { onNewChat?() }
    @objc private func closeTapped(_ sender: Any?) { onClose?() }

    /// Shared look for the two quiet composer chips (model + effort): flat,
    /// small, labeled — no stock popup bezel.
    private func styleChip(_ button: NSButton) {
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        button.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        button.layer?.borderWidth = 1
        button.layer?.cornerRadius = 7
    }

    private func makeModelMenu() -> NSMenu {
        let menu = NSMenu(title: "Model")
        for pickerItem in modelPicker.menu?.items ?? [] {
            let item = NSMenuItem(
                title: pickerItem.title, action: #selector(modelChoiceSelected(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = pickerItem.representedObject
            item.image = pickerItem.image
            item.state = pickerItem === modelPicker.selectedItem ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func modelChoiceSelected(_ sender: NSMenuItem) {
        modelPicker.selectItem(withTitle: sender.title)
        refreshModelChip()
    }

    private func refreshModelChip() {
        let choice = selectedChoice
        modelButton.image = PetAssistantPanelView.providerImage(for: choice)
        modelButton.title = " \(choice.displayName) ▾ "
        modelButton.toolTip = "Model: \(choice.displayName)"
        modelButton.menu = makeModelMenu()
    }

    private func makeEffortMenu() -> NSMenu {
        let menu = NSMenu(title: "Effort")
        for level in effortPicker.itemTitles {
            let item = NSMenuItem(
                title: level, action: #selector(effortSelected(_:)), keyEquivalent: "")
            item.target = self
            item.state = level == selectedEffort ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func effortSelected(_ sender: NSMenuItem) {
        effortPicker.selectItem(withTitle: sender.title)
        refreshEffortChip()
    }

    private func refreshEffortChip() {
        effortButton.title = " Effort · \(selectedEffort) ▾ "
        effortButton.toolTip = "Reasoning effort: \(selectedEffort)"
        effortButton.menu = makeEffortMenu()
    }

    @objc private func attachmentTapped(_ sender: Any?) {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let paths = picker.urls.map(\.path).joined(separator: " ")
            guard !paths.isEmpty else { return }
            self?.input.insertText(paths, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    var newChatTitleForTesting: String { newChatButton.title }
    var emptyStateForTesting: String { emptyStateLabel.stringValue }
    var modelValueForTesting: String { modelPicker.titleOfSelectedItem ?? "" }
    func selectModelForTesting(_ index: Int) {
        modelPicker.selectItem(at: index)
        refreshModelChip()
    }
    var selectedChoiceForTesting: PetAssistant.AgentChoice { selectedChoice }
    var modelItemTitlesForTesting: [String] { modelPicker.itemTitles }
    var effortTitlesForTesting: [String] { effortPicker.itemTitles }
    var effortValueForTesting: String { effortPicker.titleOfSelectedItem ?? "" }
    /// The visible composer controls are the flat labeled chips, not the old
    /// stock popup + brain glyph.
    var modelChipTitleForTesting: String { modelButton.title }
    var modelChipShowsProviderLogoForTesting: Bool { modelButton.image != nil }
    var effortChipTitleForTesting: String { effortButton.title }
    var effortUsesPrimaryActionMenuForTesting: Bool {
        effortButton.menu?.items.count == 5
    }
    var stockModelPopupIsHiddenForTesting: Bool { modelPicker.isHidden }
    var modelChipHeightForTesting: CGFloat { modelButton.frame.height }
    /// The sidebar chat surface is transparent (sits on the black host); the
    /// popover keeps its glass. nil layer color reads as clear.
    var surfaceIsClearForTesting: Bool {
        let color = layer?.backgroundColor
        return color == nil || color?.alpha == 0
    }
    /// Count of user-bubble message views currently in the transcript.
    var userBubbleCountForTesting: Int {
        transcriptStack.arrangedSubviews.filter { row in
            row.subviews.contains { $0.layer?.cornerRadius == 13 }
        }.count
    }
    var isShowingTypingIndicatorForTesting: Bool { typingIndicator != nil }
    var inputFrameForTesting: NSRect { input.frame }
    var inputIsFirstResponderForTesting: Bool { input.window?.firstResponder === input }
    var attachmentSymbolForTesting: String { "paperclip" }
    var sendSymbolForTesting: String { "arrow.up" }
    var sendButtonIsCircularForTesting: Bool { sendWrap.layer?.cornerRadius == 15 }
    /// The send affordance's actual laid-out frame — used to confirm it is a
    /// true circle (square bounds + cornerRadius == half the side).
    var sendButtonFrameForTesting: NSRect { sendWrap.frame }
    var sendButtonIsTrueCircleForTesting: Bool {
        let frame = sendWrap.frame
        return abs(frame.width - frame.height) < 0.5
            && sendWrap.layer?.cornerRadius == frame.width / 2
            && sendWrap.layer?.masksToBounds == true
    }
    /// No standalone title/label chrome remains in the header/composer.
    var hasTitleChromeForTesting: Bool {
        subviews.contains { ($0 as? NSTextField)?.stringValue == "Assistant" }
    }
    var hasModelLabelForTesting: Bool {
        subviews.contains { ($0 as? NSTextField)?.stringValue == "MODEL" }
    }
    /// The chip's leading edge, to confirm it sits in the old MODEL slot.
    var modelPickerLeadingForTesting: CGFloat { modelButton.frame.minX }
    var composerControlsAreBelowInputForTesting: Bool {
        modelButton.frame.maxY <= inputContainer.frame.minY + 0.5
            && effortButton.frame.maxY <= inputContainer.frame.minY + 0.5
    }
    var queueIsAboveInputForTesting: Bool {
        queueScroll.isHidden || queueScroll.frame.minY >= inputContainer.frame.maxY - 0.5
    }
    var queuedMessagesForTesting: [String] { queuedMessages }
    var assistantRowsUseFullWidthForTesting: Bool {
        transcriptStack.arrangedSubviews.compactMap { $0 as? ChatMessageView }
            .filter { $0.subviews.allSatisfy { $0.layer?.cornerRadius != 13 } }
            .allSatisfy { abs($0.frame.width - transcriptStack.bounds.width) < 0.5 }
    }
    var assistantMetadataGapForTesting: CGFloat? {
        transcriptStack.arrangedSubviews.compactMap { $0 as? ChatMessageView }
            .compactMap(\.metadataGapForTesting).first
    }
    /// Each non-Auto picker row carries a provider logo image.
    var pickerRowsHaveImagesForTesting: Bool {
        guard let items = modelPicker.menu?.items, items.count > 1 else { return false }
        return items.dropFirst().allSatisfy { $0.image != nil }
    }
    var presentationForTesting: Presentation { presentation }
    var showsCloseButtonForTesting: Bool { !closeButton.isHidden }
    var usesGlassSurfaceForTesting: Bool { presentation == .popover }
    var transcriptForTesting: String {
        lastMessages.map { "\($0.role.uppercased())\n\($0.text)" }.joined(separator: "\n\n")
    }
    var showsEmptyStateForTesting: Bool { !emptyStateLabel.isHidden }
    var showsFilesButtonForTesting: Bool { !showFilesButton.isHidden }
    func submitForTesting(_ request: String) {
        input.string = request
        submit()
    }
    func newChatForTesting() { onNewChat?() }
}

/// The pet assistant. Clicking the pet opens the same full Assistant UI used
/// by the sidebar CHAT page in an independently owned popover view. Both
/// presentations share conversation and request state.
final class PetAssistant: NSObject, NSPopoverDelegate {
    typealias AskCompletion = (String, [String], String?) -> Void
    typealias RequestRunner = (
        _ request: String, _ model: String, _ effort: String,
        _ completion: @escaping AskCompletion
    ) -> Void

    private struct PendingRequest {
        let text: String
        let model: String
        let effort: String
        let generation: Int
    }

    private weak var session: TerminalSession?
    private let config: AppConfig
    private let requestRunner: RequestRunner?
    private var popover: NSPopover?
    private weak var popoverPanel: PetAssistantPanelView?
    private var lastFiles: [String] = []
    private var lastQuery: String?
    private var sidebarMessages: [AssistantChatMessage] = []
    private var pendingRequests: [PendingRequest] = []
    private var requestInFlight = false
    private var conversationGeneration = 0
    private var recoveryContext: String?
    private weak var sidebarPanel: PetAssistantPanelView?
    /// Interactive provider choices available in the composer's MODEL picker,
    /// gated by which CLIs/models this Mac actually has. Apple Foundation
    /// Models remain a background capability and are intentionally excluded.
    let availableChoices: [AgentChoice]

    /// Hand-off: file results the user wants to see in the code-view sidebar.
    var onShowInSidePanel: ((_ paths: [String], _ query: String?) -> Void)?
    /// Compact pet-bubble notification when a background answer is ready.
    var onPetMessage: ((String) -> Void)?

    init(
        config: AppConfig,
        availableChoices: [AgentChoice]? = nil,
        requestRunner: RequestRunner? = nil
    ) {
        self.config = config
        self.requestRunner = requestRunner
        self.availableChoices = PetAssistant.interactiveChoices(
            availableChoices ?? PetAssistant.resolveChoices(config: config))
        super.init()
    }

    private static func interactiveChoices(_ choices: [AgentChoice]) -> [AgentChoice] {
        let visible = choices.filter { $0.kind != .apple }
        return visible.contains(where: { $0.kind == .auto }) ? visible : [.auto] + visible
    }

    /// Build the ordered picker choices: always Auto, plus each provider
    /// whose interactive model backend is actually available on this machine.
    static func resolveChoices(
        config: AppConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [AgentChoice] {
        var choices: [AgentChoice] = [.auto]
        for provider in [InfinittyAIProvider.claude, .codex]
        where ProviderDiscovery.isAvailable(provider, environment: environment) {
            switch provider {
            case .claude:
                for model in ModelCatalog.claude {
                    choices.append(AgentChoice(
                        kind: .claude, modelID: model.id,
                        displayName: model.name, symbolName: "a.circle"))
                }
            case .codex:
                for model in ModelCatalog.codex {
                    choices.append(AgentChoice(
                        kind: .codex, modelID: model.id,
                        displayName: model.name, symbolName: "o.circle"))
                }
            case .apple:
                break
            }
        }
        return choices
    }

    func attach(to session: TerminalSession) {
        self.session = session
    }

    func makeSidebarPanelView() -> PetAssistantPanelView {
        if let sidebarPanel { return sidebarPanel }
        let panel = makePanelView(presentation: .sidebar)
        sidebarPanel = panel
        return panel
    }

    private func makePanelView(
        presentation: PetAssistantPanelView.Presentation
    ) -> PetAssistantPanelView {
        let panel = PetAssistantPanelView(
            presentation: presentation, config: config,
            choices: availableChoices)
        panel.setMessages(sidebarMessages)
        panel.setQueuedMessages(pendingRequests.map(\.text))
        panel.setHasFiles(!lastFiles.isEmpty)
        panel.onSubmit = { [weak self] request, model, effort in
            self?.submitFromPanel(request, model: model, effort: effort)
        }
        panel.onShowFiles = { [weak self] in
            guard let self, !self.lastFiles.isEmpty else { return }
            self.onShowInSidePanel?(self.lastFiles, self.lastQuery)
        }
        panel.onNewChat = { [weak self] in self?.resetConversation() }
        return panel
    }

    private func resetConversation() {
        conversationGeneration += 1
        pendingRequests.removeAll()
        sidebarMessages.removeAll()
        lastFiles.removeAll()
        lastQuery = nil
        recoveryContext = nil
        setPanelsThinking(false)
        updatePanels()
    }

    func startNewChat() { resetConversation() }

    /// Browser inspector hand-off. This intentionally uses the same queued
    /// request path as a typed chat turn so it appears in the transcript and
    /// respects the currently attached terminal/session context.
    func submitBrowserAnnotation(_ annotation: BrowserAnnotation) {
        submitBrowserAnnotations([annotation])
    }

    /// Send a single, ordered feedback pass to the agent. A batch is one
    /// normal chat request (rather than one request per marker), preserving
    /// the user's priority and letting the agent reason across related notes.
    func submitBrowserAnnotations(_ annotations: [BrowserAnnotation]) {
        guard !annotations.isEmpty else { return }
        submitFromPanel(
            BrowserAnnotation.aiContext(for: annotations),
            model: "Auto · Best available")
    }

    func prepareRecovery(
        context: String, provider: AgentChoice.Kind, transcriptPath: String? = nil
    ) {
        resetConversation()
        var imported: [AssistantChatMessage] = []
        if let transcriptPath {
            imported = Self.recentConversation(at: transcriptPath)
            sidebarMessages = imported
        }
        let importedContext = imported.map {
            "\($0.role): \($0.text)"
        }.joined(separator: "\n\n")
        recoveryContext = importedContext.isEmpty
            ? context
            : context + "\n--- recent recovered turns ---\n" + importedContext
        if sidebarMessages.isEmpty {
            sidebarMessages = [AssistantChatMessage(
                role: "Assistant",
                text: "Session context recovered. Continue below when you're ready.")]
        }
        for panel in [sidebarPanel, popoverPanel].compactMap({ $0 }) {
            _ = panel.selectProvider(provider)
        }
        updatePanels()
    }

    private func updatePanels() {
        for panel in [sidebarPanel, popoverPanel].compactMap({ $0 }) {
            panel.setMessages(sidebarMessages)
            panel.setQueuedMessages(pendingRequests.map(\.text))
            panel.setHasFiles(!lastFiles.isEmpty)
        }
    }

    private func setPanelsThinking(_ thinking: Bool, label: String? = nil) {
        for panel in [sidebarPanel, popoverPanel].compactMap({ $0 }) {
            panel.setThinking(thinking, label: label)
        }
    }

    private func submitFromPanel(_ request: String, model: String, effort: String = "Auto") {
        pendingRequests.append(PendingRequest(
            text: request, model: model, effort: effort,
            generation: conversationGeneration))
        updatePanels()
        processNextRequest()
    }

    private func processNextRequest() {
        guard !requestInFlight else { return }
        while let next = pendingRequests.first,
              next.generation != conversationGeneration {
            pendingRequests.removeFirst()
        }
        guard !pendingRequests.isEmpty else {
            setPanelsThinking(false)
            updatePanels()
            return
        }

        let request = pendingRequests.removeFirst()
        let backendRequest: String
        if let recoveryContext {
            backendRequest = """
            --- recovered session context ---
            \(recoveryContext)
            --- new user request ---
            \(request.text)
            """
            self.recoveryContext = nil
        } else {
            backendRequest = request.text
        }
        requestInFlight = true
        sidebarMessages.append(AssistantChatMessage(role: "You", text: request.text))
        updatePanels()
        // The status row names the model doing the work; a bare "Thinking"
        // is only right when routing is automatic.
        setPanelsThinking(
            true,
            label: request.model.hasPrefix("Auto")
                ? "Thinking" : "\(request.model) · thinking")

        let completion: AskCompletion = { [weak self] answer, files, query in
            guard let self else { return }
            let finish = {
                self.completeRequest(
                    request, answer: answer, files: files, query: query)
            }
            if Thread.isMainThread { finish() }
            else { DispatchQueue.main.async(execute: finish) }
        }
        if let requestRunner {
            requestRunner(backendRequest, request.model, request.effort, completion)
        } else {
            ask(
                backendRequest, model: request.model, effort: request.effort,
                completion: completion)
        }
    }

    private static func recentConversation(
        at path: String, limit: Int = 12
    ) -> [AssistantChatMessage] {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let readLength = min(size, 512 * 1024)
        try? handle.seek(toOffset: size - readLength)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var messages: [AssistantChatMessage] = []
        for line in text.split(separator: "\n").reversed() {
            guard messages.count < limit,
                  let object = try? JSONSerialization.jsonObject(
                      with: Data(line.utf8)) as? [String: Any],
                  let turn = recoveryTurn(from: object) else { continue }
            messages.append(AssistantChatMessage(role: turn.role, text: turn.text))
        }
        return Array(messages.reversed())
    }

    private static func recoveryTurn(
        from object: [String: Any]
    ) -> (role: String, text: String)? {
        if let type = object["type"] as? String,
           type == "user" || type == "assistant",
           let message = object["message"] as? [String: Any],
           let text = recoveryText(message["content"]) {
            return (type == "user" ? "You" : "Assistant", text)
        }
        guard let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return nil }
        if type == "user_message", let text = recoveryText(payload["message"]) {
            return ("You", text)
        }
        if type == "agent_message", let text = recoveryText(payload["message"]) {
            return ("Assistant", text)
        }
        if type == "message", let role = payload["role"] as? String,
           role == "user" || role == "assistant",
           let text = recoveryText(payload["content"]) {
            return (role == "user" ? "You" : "Assistant", text)
        }
        return nil
    }

    private static func recoveryText(_ value: Any?) -> String? {
        var text: String?
        if let string = value as? String {
            text = string
        } else if let parts = value as? [[String: Any]] {
            text = parts.compactMap { part in
                guard part["type"] as? String == "text"
                    || part["type"] as? String == "input_text"
                    || part["type"] as? String == "output_text"
                else { return nil }
                return part["text"] as? String
            }.joined(separator: "\n")
        }
        guard var cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty, !cleaned.hasPrefix("<") else { return nil }
        if cleaned.count > 4_000 { cleaned = String(cleaned.prefix(4_000)) + "…" }
        return cleaned
    }

    private func completeRequest(
        _ request: PendingRequest, answer: String,
        files: [String], query: String?
    ) {
        requestInFlight = false
        if request.generation == conversationGeneration {
            lastFiles = files
            lastQuery = query
            sidebarMessages.append(AssistantChatMessage(
                role: "Assistant", text: answer,
                tokenCount: AssistantChatMessage.approximateTokenCount(for: answer)))
            updatePanels()
        }
        processNextRequest()
    }

    func detach() {
        closePopover()
        session = nil
    }

    // MARK: - input bubble

    func presentInput(anchorRect: NSRect, in view: NSView) {
        closePopover()
        PetAssistant.prewarm(config: config)
        let contentSize = NSSize(width: 380, height: 420)
        let panel = makePanelView(presentation: .popover)
        panel.frame = NSRect(origin: .zero, size: contentSize)
        panel.translatesAutoresizingMaskIntoConstraints = true
        panel.autoresizingMask = [.width, .height]
        panel.onClose = { [weak self] in self?.closePopover() }

        let controller = NSViewController()
        controller.view = panel
        controller.preferredContentSize = contentSize

        let pop = NSPopover()
        pop.contentViewController = controller
        pop.contentSize = contentSize
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        popover = pop
        popoverPanel = panel

        pop.show(relativeTo: anchorRect, of: view, preferredEdge: .maxY)
        DispatchQueue.main.async { [weak panel] in panel?.focusInput() }
    }


    private func closePopover() {
        popover?.close()
        popover = nil
        popoverPanel = nil
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        popoverPanel = nil
    }

    // MARK: - the ask pipeline

    private static let systemPrompt = """
    You are infinitty — an agentic terminal. You are not a chatbot describing \
    a terminal; you ARE the terminal, and you control it directly.

    You have infinitty tools (infinitty_list_panes, infinitty_run, \
    infinitty_send, infinitty_screen, infinitty_history, infinitty_last_output, \
    infinitty_exit_code, infinitty_new_tab, infinitty_split, infinitty_focus, \
    infinitty_close, infinitty_surface, infinitty_todos). To SHOW the user \
    something rich — a plan, a doc, a rendered preview, a small UI — use \
    infinitty_surface (markdown, HTML, or a URL; target=split for a side \
    panel at a ratio like 0.25, target=window for a standalone doc). For \
    multi-step work, keep infinitty_todos updated so the pane header shows \
    your progress. When the user asks you to DO something in the terminal — \
    run a command, type text, open a tab, launch a program — you MUST call the \
    matching tool. Never describe an action as done unless the tool call \
    returned success. Never invent output, exit codes, or state: read them with \
    infinitty_screen / infinitty_last_output / infinitty_exit_code and report \
    exactly what came back. If a tool returns an error, say so plainly.

    To act on a specific pane, first call infinitty_list_panes to get pane ids \
    (the focused pane is marked). "Type X and press enter" = infinitty_send \
    with submit:true. "Type X" without running = submit:false. To run a command \
    and capture its result, prefer infinitty_run.

    To OPEN or LAUNCH a program, TYPE ITS COMMAND INTO A VISIBLE PANE so the \
    user sees it. Never launch a macOS desktop app (never `open -a`, never \
    `open`); the user wants the command-line program in their terminal, not a \
    GUI app. Examples: "open claude code" / "open claude" → send `claude`; \
    "open vim" → send `vim`; "start a python repl" → send `python3`. \
    CHOOSE THE RIGHT TOOL: use infinitty_send (submit:true) to launch anything \
    interactive or long-running (claude, vim, a REPL, a server) — it types the \
    command and returns immediately. Use infinitty_run ONLY for a one-shot \
    command that finishes on its own and whose output you need, because \
    infinitty_run WAITS for the command to complete and will hang on an \
    interactive program. Prefer the focused pane; open a new tab \
    (infinitty_new_tab) only if asked. Act in ONE or two tool calls — don't \
    retry with variations.

    For plain questions that need no terminal action, answer concisely in a few \
    sentences of plain text (no markdown). If answering requires finding files \
    in the project, reply with EXACTLY one line "SEARCH: <filename or path \
    keywords>" and nothing else; you will receive the matching files to compose \
    the final answer.
    """

    private func ask(
        _ request: String, model: String = "Auto · Best available",
        effort: String = "Auto",
        completion: AskCompletion? = nil
    ) {
        // A Chat/Browser tab is allowed to outlive its final terminal pane.
        // In that state an assistant can still use the app-level browser MCP
        // tools and answer about the selected page; it simply receives no
        // terminal transcript or project-root search context.
        let activeSession = session
        activeSession?.petAnimator?.startThinking()
        let backend = resolveBackend(forSelectedTitle: model)
        // Keep the system prompt CONSTANT: the CLI bridges pin --system-prompt
        // at process launch, so folding effort in here forced a full cold
        // respawn on every effort change (and invalidated the prewarm). The
        // effort directive rides in the per-turn user message instead, so the
        // warm process is reused across Auto/Low/Medium/High.
        let system = Self.systemPrompt
        let effortNote = Self.effortDirective(effort)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let cwd = activeSession?.currentDirectory()
            let context: String
            if let activeSession {
                context = """
                cwd: \(cwd ?? NSHomeDirectory())
                last command: \(activeSession.terminal.lastCommandLine() ?? "(unknown)")
                --- recent terminal output ---
                \(activeSession.terminal.historyText(lines: 60))
                """
            } else {
                context = """
                cwd: \(NSHomeDirectory())
                last command: (no active terminal)
                --- browser-only session ---
                There is no attached terminal pane. Use browser tools for page work and do not claim terminal output.
                """
            }
            let user = context + "\n--- user request ---\n" + request
                + (effortNote.isEmpty ? "" : "\n" + effortNote)
            let runCwd = cwd ?? NSHomeDirectory()

            Self.askAI(backend: backend, system: system, user: user, cwd: runCwd) { outcome in
                if let query = Self.parseSearchDirective(Self.replyText(for: outcome)), let cwd {
                    let all = CodeSearch.listFilesSync(root: cwd)
                    let matches = CodeSearch.filter(all, query: query, limit: 50)
                    let fileBlock = matches.isEmpty
                        ? "(no files matched)" : matches.joined(separator: "\n")
                    let followUp = context
                        + "\n--- files matching \"\(query)\" ---\n" + fileBlock
                        + "\n--- user request ---\n" + request
                    Self.askAI(backend: backend, system: system, user: followUp, cwd: runCwd) { final in
                        self.finish(
                            answer: Self.displayText(for: final), files: matches, query: query,
                            completion: completion)
                    }
                } else {
                    self.finish(
                        answer: Self.displayText(for: outcome),
                        files: [], query: nil, completion: completion)
                }
            }
        }
    }

    /// Reasoning-effort directive appended to the system prompt. "Auto" adds
    /// nothing (let the model/backend decide); the rest steer depth.
    private static func effortDirective(_ effort: String) -> String {
        switch effort.lowercased() {
        case "none":
            return "\n\nReasoning effort: NONE. Answer immediately; do not deliberate or "
                + "plan — respond with the shortest correct output."
        case "low":
            return "\n\nReasoning effort: LOW. Be fast and direct; minimal deliberation."
        case "medium":
            return "\n\nReasoning effort: MEDIUM. Balance speed and thoroughness."
        case "high":
            return "\n\nReasoning effort: HIGH. Think carefully and verify before acting."
        default:
            return ""
        }
    }

    /// Map the composer's selected MODEL title to a concrete backend.
    func resolveBackend(forSelectedTitle title: String) -> Backend {
        let choice = availableChoices.first { $0.menuTitle(config: config) == title } ?? .auto
        return PetAssistant.resolveBackend(choice: choice, config: config)
    }

    /// One row in the composer's model picker: a concrete provider + model.
    /// `.auto` carries no model (resolves the best available at send time).
    struct AgentChoice: Equatable {
        enum Kind: Equatable { case auto, claude, codex, apple }
        let kind: Kind
        /// Exact API/CLI model id (e.g. "claude-sonnet-5"). Nil for Auto/Apple.
        let modelID: String?
        /// Display label shown in the picker (e.g. "Claude Sonnet 5").
        let displayName: String
        /// SF Symbol used as the provider glyph beside the label.
        let symbolName: String

        static let auto = AgentChoice(
            kind: .auto, modelID: nil,
            displayName: "Auto", symbolName: "sparkles")

        var configuredProvider: String {
            switch kind {
            case .auto: return "auto"
            case .claude: return "claude"
            case .codex: return "codex"
            case .apple: return "apple"
            }
        }

        func menuTitle(config: AppConfig) -> String { displayName }

        /// Brand-ish tint for the provider glyph.
        var tint: NSColor {
            switch kind {
            case .auto: return NSColor(calibratedRed: 0.48, green: 0.52, blue: 1, alpha: 1)
            case .claude: return NSColor(calibratedRed: 0.85, green: 0.52, blue: 0.32, alpha: 1)
            case .codex: return NSColor(white: 0.92, alpha: 1)
            case .apple: return NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.64, alpha: 1)
            }
        }
    }

    /// Latest models per provider (models.dev, July 2026). Display name is
    /// cosmetic; `id` is the real CLI/API identifier that gets routed.
    enum ModelCatalog {
        static let claude: [(id: String, name: String)] = [
            ("claude-haiku-4-5", "Claude Haiku 4.5"),
            ("claude-sonnet-5", "Claude Sonnet 5"),
            ("claude-opus-4-8", "Claude Opus 4.8"),
            ("claude-fable-5", "Claude Fable 5"),
        ]
        static let codex: [(id: String, name: String)] = [
            ("gpt-5.6", "GPT-5.6"),
            ("gpt-5.6-terra", "GPT-5.6 Terra"),
        ]
    }

    enum Backend: Equatable {
        case none
        case command(String)
        case openai(base: String, key: String, model: String)
        case codex(model: String?)
        case claude(model: String?)
        case foundation
    }

    /// Outcome of an AI backend call. Distinguishes a genuinely unconfigured
    /// backend from a configured one that errored — the two used to collapse
    /// to `nil`, so a live bridge that timed out or crashed surfaced the same
    /// misleading "can't reach an AI" message as having no backend at all.
    enum AIOutcome {
        case text(String)
        case unconfigured
        case failure(String)   // complete, human-readable failure message
    }

    /// Warm the resolved CLI bridge ahead of the first sidebar-chat turn, so
    /// its cold start (Node init + MCP boot + session hooks) overlaps the user
    /// reading/typing instead of blocking the first "open claude" ask.
    func prewarm() { PetAssistant.prewarm(config: config) }

    /// Warm whichever CLI bridge the config resolves to, so its cold start
    /// overlaps the user typing. No-op for HTTP/Apple/none.
    static func prewarm(config: AppConfig) {
        switch resolveBackend(config: config) {
        case .claude(let model):
            ClaudeBridge.shared.warmUp(system: systemPrompt, model: model)
        case .codex(let model):
            CodexAppServer.shared.warmUp(model: model ?? "gpt-5.4")
        case .openai, .foundation, .command, .none:
            break
        }
    }

    /// Pick a backend, honoring `ai-provider` (auto = Claude → Codex →
    /// Apple → OpenAI → hint-command → none).
    static func resolveBackend(
        choice: AgentChoice,
        config: AppConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Backend {
        // An explicit model pick forces that provider + exact model, so the
        // UI's selected model is what actually runs (not a config default).
        switch choice.kind {
        case .claude:
            return .claude(model: choice.modelID ?? config.claudeModel)
        case .codex:
            return .codex(model: choice.modelID ?? config.codexModel)
        case .apple:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), FoundationModelHinter.isAvailable {
                return .foundation
            }
            #endif
            return .none
        case .auto:
            return resolveBackend(
                configuredProvider: config.aiProvider, config: config, environment: environment)
        }
    }

    static func resolveBackend(
        config: AppConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Backend {
        resolveBackend(
            configuredProvider: config.aiProvider, config: config, environment: environment)
    }

    private static func resolveBackend(
        configuredProvider: String, config: AppConfig, environment: [String: String]
    ) -> Backend {
        let pick = ProviderDiscovery.preferredProvider(
            configured: configuredProvider, environment: environment)
        switch pick {
        case .codex: return .codex(model: config.codexModel)
        case .claude: return .claude(model: config.claudeModel)
        case .apple:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), FoundationModelHinter.isAvailable {
                return .foundation
            }
            #endif
        case .none:
            break
        }
        if let base = config.aiBaseURL, !base.isEmpty {
            return .openai(base: base, key: config.aiKey ?? "",
                           model: config.aiModel ?? "gpt-4o-mini")
        }
        if let cmd = config.hintCommand, !cmd.isEmpty { return .command(cmd) }
        return .none
    }

    /// "SEARCH: keywords" as the entire reply → keywords, else nil.
    static func parseSearchDirective(_ reply: String?) -> String? {
        guard let line = reply?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1).first
        else { return nil }
        guard line.hasPrefix("SEARCH:") else { return nil }
        let query = line.dropFirst("SEARCH:".count)
            .trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? nil : query
    }

    /// Text shown in the chat when an outcome is the final answer. Only
    /// `.unconfigured` produces the "configure a backend" hint; a live backend
    /// that errored surfaces its real failure message instead of hiding it.
    static func displayText(for outcome: AIOutcome) -> String {
        switch outcome {
        case .text(let t): return t
        case .unconfigured:
            return "I can't reach an AI right now. Configure a codex/claude CLI, "
                + "ai-base-url/ai-key, or enable Apple Intelligence."
        case .failure(let msg):
            return msg
        }
    }

    /// The reply text used for directive parsing (`SEARCH:`) — only real model
    /// text is a candidate; failures and the unconfigured case are not.
    static func replyText(for outcome: AIOutcome) -> String? {
        if case .text(let t) = outcome { return t }
        return nil
    }

    private func finish(
        answer: String, files: [String], query: String?,
        completion: AskCompletion?
    ) {
        DispatchQueue.main.async {
            self.session?.petAnimator?.stopThinking()
            completion?(answer, files, query)
            self.onPetMessage?(answer)
        }
    }


    var popoverPanelForTesting: PetAssistantPanelView? { popoverPanel }

    // MARK: - AI backends (mirrors HintEngine's smart-source resolution)

    /// Calls `done` on whatever thread the backend completes on; callers hop
    /// to main as needed.
    static func askAI(
        backend: Backend,
        system: String, user: String, cwd: String,
        done: @escaping (AIOutcome) -> Void
    ) {
        switch backend {
        case .none:
            done(.unconfigured)
        case .command(let cmd):
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-c", cmd]
            let stdin = Pipe(), stdout = Pipe()
            proc.standardInput = stdin
            proc.standardOutput = stdout
            proc.standardError = Pipe()
            guard (try? proc.run()) != nil else {
                done(.failure("Custom AI command failed to launch: \(cmd)")); return
            }
            stdin.fileHandleForWriting.write(Data((system + "\n\n" + user).utf8))
            try? stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                done(.failure("Custom AI command exited \(proc.terminationStatus).")); return
            }
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty { done(.text(text)) }
            else { done(.failure("Custom AI command produced no output.")) }
        case .openai(let base, let key, let model):
            askOpenAI(base: base, key: key, model: model, system: system, user: user, done: done)
        case .codex(let model):
            askCodex(model: model, cwd: cwd, system: system, user: user, done: done)
        case .claude(let model):
            askClaude(model: model, system: system, user: user, done: done)
        case .foundation:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                Task {
                    let reply = await PetAssistantFM.answer(system: system, user: user)
                    if let reply, !reply.isEmpty { done(.text(reply)) }
                    else { done(.failure("Apple Intelligence returned no response.")) }
                }
            } else { done(.failure("Apple Intelligence requires macOS 26 or later.")) }
            #else
            done(.failure("This build has no Apple Intelligence support."))
            #endif
        }
    }

    /// Codex CLI via the persistent `codex app-server` bridge. One-time cold
    /// start, then warm turns. Tool calls run between Codex and infinitty-mcp.
    private static func askCodex(
        model: String?, cwd: String,
        system: String, user: String,
        done: @escaping (AIOutcome) -> Void
    ) {
        let prompt = system + "\n\n" + user
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                do {
                    let reply = try await CodexAppServer.shared.turn(
                        prompt: prompt, cwd: cwd, model: model ?? "gpt-5.4")
                    done(.text(reply.trimmingCharacters(in: .whitespacesAndNewlines)))
                } catch {
                    PetLog.log("codex failed: \(error.localizedDescription)")
                    done(.failure("Codex: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// Claude Code CLI via the persistent stream-json bridge. Same warm-turn
    /// shape as Codex; tools route through the injected infinitty-mcp config.
    private static func askClaude(
        model: String?,
        system: String, user: String,
        done: @escaping (AIOutcome) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                do {
                    let reply = try await ClaudeBridge.shared.turn(
                        prompt: user, system: system, model: model)
                    done(.text(reply.trimmingCharacters(in: .whitespacesAndNewlines)))
                } catch {
                    PetLog.log("claude failed: \(error.localizedDescription)")
                    done(.failure("Claude: \(error.localizedDescription)"))
                }
            }
        }
    }

    private static func askOpenAI(
        base: String, key: String, model: String,
        system: String, user: String,
        done: @escaping (AIOutcome) -> Void
    ) {
        let urlStr = base.hasSuffix("/chat/completions") ? base
            : base.hasSuffix("/v1") ? base + "/chat/completions"
            : base + "/v1/chat/completions"
        guard let url = URL(string: urlStr) else {
            done(.failure("Invalid ai-base-url: \(base)")); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.3,
            "max_tokens": 400,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession(configuration: .ephemeral).dataTask(with: req) { data, _, err in
            if let err {
                done(.failure("OpenAI request failed: \(err.localizedDescription)")); return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { done(.failure("OpenAI: unreadable response.")); return }
            guard let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                let apiErr = (json["error"] as? [String: Any])?["message"] as? String
                done(.failure("OpenAI: \(apiErr ?? "no choices in response").")); return
            }
            done(.text(content.trimmingCharacters(in: .whitespacesAndNewlines)))
        }.resume()
    }
}

#if canImport(FoundationModels)
/// On-device answers via Apple's Foundation Models (macOS 26+). Same
/// availability gate as FoundationModelHinter.
@available(macOS 26.0, *)
enum PetAssistantFM {
    static func answer(system: String, user: String) async -> String? {
        guard FoundationModelHinter.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: system)
        let options = GenerationOptions(temperature: 0.3)
        return try? await session.respond(to: user, options: options).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
