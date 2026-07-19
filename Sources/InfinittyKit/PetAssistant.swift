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

/// One chat message row spanning the full transcript width. User turns show a
/// right-aligned rounded accent bubble (≤78% width); assistant turns render as
/// full-width flowing text on the transparent surface — the ChatGPT/Stream
/// layout convention.
final class ChatMessageView: NSView {
    static var accent: NSColor { CodePalette.selectionAccent }

    init(role: String, text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let isUser = role.caseInsensitiveCompare("You") == .orderedSame

        let label = NSTextField(wrappingLabelWithString: text)
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
            label.textColor = NSColor(white: 0.92, alpha: 1)
            addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: topAnchor),
                label.bottomAnchor.constraint(equalTo: bottomAnchor),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Animated "Thinking" row shown while the assistant generates — three pulsing
/// dots, matching the Stream AITypingIndicator pattern.
final class ChatTypingIndicator: NSView {
    private let dots = (0..<3).map { _ -> NSView in
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(white: 0.6, alpha: 1).cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        return dot
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: dots)
        row.orientation = .horizontal
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ] + dots.flatMap { [
            $0.widthAnchor.constraint(equalToConstant: 6),
            $0.heightAnchor.constraint(equalToConstant: 6),
        ] })
    }

    required init?(coder: NSCoder) { fatalError() }

    func startAnimating() {
        for (index, dot) in dots.enumerated() {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.3
            pulse.toValue = 1.0
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.2
            dot.layer?.add(pulse, forKey: "pulse")
        }
    }
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
    private let emptyStateLabel = NSTextField(
        labelWithString: "Choose an agent, ask a question, and keep chatting here.")
    private let modelPicker = NSPopUpButton()
    private let effortPicker = NSPopUpButton()
    private let inputContainer = NSView()
    private let inputScroll = NSScrollView()
    private let input = TabRenameTextView()
    private let attachmentButton = NSButton()
    private let sendButton = NSButton()
    private let sendWrap = NSView()
    private let showFilesButton = NSButton(title: "Show Files", target: nil, action: nil)

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

        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = presentation == .sidebar

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
    }

    private func configureMessages() {
        // Bubble transcript: a vertical stack of per-message views inside a
        // scroll view. Assistant replies render as plain text on the black
        // surface; user messages get a rounded bubble panel.
        transcriptStack.orientation = .vertical
        transcriptStack.alignment = .width
        transcriptStack.spacing = 14
        transcriptStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
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
        modelPicker.controlSize = .regular
        modelPicker.font = .systemFont(ofSize: NSFont.systemFontSize)
        modelPicker.menu?.removeAllItems()
        for choice in choices {
            let item = NSMenuItem(title: choice.displayName, action: nil, keyEquivalent: "")
            item.representedObject = choice
            item.image = PetAssistantPanelView.providerImage(for: choice)
            modelPicker.menu?.addItem(item)
        }

        effortPicker.controlSize = .regular
        effortPicker.font = .systemFont(ofSize: NSFont.systemFontSize)
        effortPicker.menu?.removeAllItems()
        for level in ["Auto", "Low", "Medium", "High"] {
            effortPicker.menu?.addItem(
                NSMenuItem(title: level, action: nil, keyEquivalent: ""))
        }
        effortPicker.selectItem(at: 0)

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
            separator, transcriptScroll, emptyStateLabel, showFilesButton,
            modelPicker, effortPicker, inputContainer, attachmentButton,
            inputScroll, sendButton, sendWrap,
        ]
        for view in views { view.translatesAutoresizingMaskIntoConstraints = false }
        for view in [
            newChatButton, closeButton, separator,
            transcriptScroll, emptyStateLabel, showFilesButton,
            modelPicker, effortPicker, inputContainer,
        ] { addSubview(view) }

        NSLayoutConstraint.activate(headerConstraints() + bodyConstraints() + composerConstraints())
    }

    private func headerConstraints() -> [NSLayoutConstraint] {
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
        [
            transcriptScroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            transcriptScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            transcriptScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            transcriptScroll.bottomAnchor.constraint(equalTo: modelPicker.topAnchor, constant: -12),
            emptyStateLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 18),
            emptyStateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            showFilesButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            showFilesButton.bottomAnchor.constraint(equalTo: modelPicker.topAnchor, constant: -8),
        ]
    }

    private func composerConstraints() -> [NSLayoutConstraint] {
        [
            inputContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            inputContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            inputContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            inputContainer.heightAnchor.constraint(equalToConstant: 44),
            modelPicker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            modelPicker.trailingAnchor.constraint(equalTo: effortPicker.leadingAnchor, constant: -6),
            modelPicker.bottomAnchor.constraint(equalTo: inputContainer.topAnchor, constant: -10),
            modelPicker.heightAnchor.constraint(equalToConstant: 30),
            effortPicker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            effortPicker.centerYAnchor.constraint(equalTo: modelPicker.centerYAnchor),
            effortPicker.heightAnchor.constraint(equalToConstant: 30),
            effortPicker.widthAnchor.constraint(equalToConstant: 96),
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

    private var lastMessages: [(role: String, text: String)] = []
    private var typingIndicator: ChatTypingIndicator?

    func setMessages(_ messages: [(role: String, text: String)]) {
        lastMessages = messages
        rebuildTranscript()
    }

    private func rebuildTranscript() {
        transcriptStack.arrangedSubviews.forEach {
            transcriptStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for message in lastMessages {
            transcriptStack.addArrangedSubview(
                ChatMessageView(role: message.role, text: message.text))
        }
        if let typingIndicator {
            transcriptStack.addArrangedSubview(typingIndicator)
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

    func setThinking(_ thinking: Bool) {
        input.isEditable = !thinking
        sendWrap.alphaValue = thinking ? 0.45 : 1
        if thinking, typingIndicator == nil {
            typingIndicator = ChatTypingIndicator()
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
    func selectModelForTesting(_ index: Int) { modelPicker.selectItem(at: index) }
    var selectedChoiceForTesting: PetAssistant.AgentChoice { selectedChoice }
    var modelItemTitlesForTesting: [String] { modelPicker.itemTitles }
    var effortTitlesForTesting: [String] { effortPicker.itemTitles }
    var effortValueForTesting: String { effortPicker.titleOfSelectedItem ?? "" }
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
    /// The picker's leading edge, to confirm it moved into the old MODEL slot.
    var modelPickerLeadingForTesting: CGFloat { modelPicker.frame.minX }
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
    private weak var session: TerminalSession?
    private let config: AppConfig
    private var popover: NSPopover?
    private weak var popoverPanel: PetAssistantPanelView?
    private var lastFiles: [String] = []
    private var lastQuery: String?
    private var sidebarMessages: [(role: String, text: String)] = []
    private weak var sidebarPanel: PetAssistantPanelView?
    /// AI provider choices available in the composer's MODEL picker,
    /// gated by which CLIs/models this Mac actually has.
    let availableChoices: [AgentChoice]

    /// Hand-off: file results the user wants to see in the code-view sidebar.
    var onShowInSidePanel: ((_ paths: [String], _ query: String?) -> Void)?

    init(config: AppConfig, availableChoices: [AgentChoice]? = nil) {
        self.config = config
        self.availableChoices = availableChoices ?? PetAssistant.resolveChoices(config: config)
        super.init()
    }

    /// Build the ordered picker choices: always Auto, plus each provider
    /// whose backend is actually available on this machine.
    static func resolveChoices(
        config: AppConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [AgentChoice] {
        var choices: [AgentChoice] = [.auto]
        for provider in [InfinittyAIProvider.claude, .codex, .apple]
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
                choices.append(AgentChoice(
                    kind: .apple, modelID: nil,
                    displayName: "Apple On-device", symbolName: "apple.logo"))
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
        sidebarMessages.removeAll()
        lastFiles.removeAll()
        lastQuery = nil
        updatePanels()
    }

    private func updatePanels() {
        for panel in [sidebarPanel, popoverPanel].compactMap({ $0 }) {
            panel.setMessages(sidebarMessages)
            panel.setHasFiles(!lastFiles.isEmpty)
        }
    }

    private func setPanelsThinking(_ thinking: Bool) {
        for panel in [sidebarPanel, popoverPanel].compactMap({ $0 }) {
            panel.setThinking(thinking)
        }
    }

    private func submitFromPanel(_ request: String, model: String, effort: String = "Auto") {
        sidebarMessages.append((role: "You", text: request))
        updatePanels()
        setPanelsThinking(true)
        ask(request, model: model, effort: effort) { [weak self] answer, _, _ in
            guard let self else { return }
            self.sidebarMessages.append((role: "Assistant", text: answer))
            self.updatePanels()
            self.setPanelsThinking(false)
        }
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
    infinitty_close). When the user asks you to DO something in the terminal — \
    run a command, type text, open a tab, launch a program — you MUST call the \
    matching tool. Never describe an action as done unless the tool call \
    returned success. Never invent output, exit codes, or state: read them with \
    infinitty_screen / infinitty_last_output / infinitty_exit_code and report \
    exactly what came back. If a tool returns an error, say so plainly.

    To act on a specific pane, first call infinitty_list_panes to get pane ids \
    (the focused pane is marked). "Type X and press enter" = infinitty_send \
    with submit:true. "Type X" without running = submit:false. To run a command \
    and capture its result, prefer infinitty_run.

    For plain questions that need no terminal action, answer concisely in a few \
    sentences of plain text (no markdown). If answering requires finding files \
    in the project, reply with EXACTLY one line "SEARCH: <filename or path \
    keywords>" and nothing else; you will receive the matching files to compose \
    the final answer.
    """

    private typealias AskCompletion = (String, [String], String?) -> Void

    private func ask(
        _ request: String, model: String = "Auto · Best available",
        effort: String = "Auto",
        completion: AskCompletion? = nil
    ) {
        guard let session else {
            completion?("No terminal session is available.", [], nil)
            return
        }
        session.petAnimator?.startThinking()
        let backend = resolveBackend(forSelectedTitle: model)
        let system = Self.systemPrompt + Self.effortDirective(effort)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let cwd = session.currentDirectory()
            let context = """
            cwd: \(cwd ?? NSHomeDirectory())
            last command: \(session.terminal.lastCommandLine() ?? "(unknown)")
            --- recent terminal output ---
            \(session.terminal.historyText(lines: 60))
            """
            let user = context + "\n--- user request ---\n" + request
            let runCwd = cwd ?? NSHomeDirectory()

            Self.askAI(backend: backend, system: system, user: user, cwd: runCwd) { reply in
                if let query = Self.parseSearchDirective(reply), let cwd {
                    let all = CodeSearch.listFilesSync(root: cwd)
                    let matches = CodeSearch.filter(all, query: query, limit: 50)
                    let fileBlock = matches.isEmpty
                        ? "(no files matched)" : matches.joined(separator: "\n")
                    let followUp = context
                        + "\n--- files matching \"\(query)\" ---\n" + fileBlock
                        + "\n--- user request ---\n" + request
                    Self.askAI(backend: backend, system: system, user: followUp, cwd: runCwd) { final in
                        self.finish(
                            answer: final ?? "…", files: matches, query: query,
                            completion: completion)
                    }
                } else {
                    self.finish(
                        answer: reply
                            ?? "I can't reach an AI right now. Configure a codex/claude CLI, "
                            + "ai-base-url/ai-key, or enable Apple Intelligence.",
                        files: [], query: nil, completion: completion)
                }
            }
        }
    }

    /// Reasoning-effort directive appended to the system prompt. "Auto" adds
    /// nothing (let the model/backend decide); the rest steer depth.
    private static func effortDirective(_ effort: String) -> String {
        switch effort.lowercased() {
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

    private func finish(
        answer: String, files: [String], query: String?,
        completion: AskCompletion?
    ) {
        DispatchQueue.main.async {
            self.session?.petAnimator?.stopThinking()
            self.lastFiles = files
            self.lastQuery = query
            completion?(answer, files, query)
        }
    }


    var popoverPanelForTesting: PetAssistantPanelView? { popoverPanel }

    // MARK: - AI backends (mirrors HintEngine's smart-source resolution)

    /// Calls `done` on whatever thread the backend completes on; callers hop
    /// to main as needed.
    static func askAI(
        backend: Backend,
        system: String, user: String, cwd: String,
        done: @escaping (String?) -> Void
    ) {
        switch backend {
        case .none:
            done(nil)
        case .command(let cmd):
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-c", cmd]
            let stdin = Pipe(), stdout = Pipe()
            proc.standardInput = stdin
            proc.standardOutput = stdout
            proc.standardError = Pipe()
            guard (try? proc.run()) != nil else { done(nil); return }
            stdin.fileHandleForWriting.write(Data((system + "\n\n" + user).utf8))
            try? stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { done(nil); return }
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            done(text?.isEmpty == false ? text : nil)
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
                    done(reply)
                }
            } else { done(nil) }
            #else
            done(nil)
            #endif
        }
    }

    /// Codex CLI via the persistent `codex app-server` bridge. One-time cold
    /// start, then warm turns. Tool calls run between Codex and infinitty-mcp.
    private static func askCodex(
        model: String?, cwd: String,
        system: String, user: String,
        done: @escaping (String?) -> Void
    ) {
        let prompt = system + "\n\n" + user
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                do {
                    let reply = try await CodexAppServer.shared.turn(
                        prompt: prompt, cwd: cwd, model: model ?? "gpt-5.4")
                    done(reply.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    PetLog.log("codex failed: \(error.localizedDescription)")
                    done(nil)
                }
            }
        }
    }

    /// Claude Code CLI via the persistent stream-json bridge. Same warm-turn
    /// shape as Codex; tools route through the injected infinitty-mcp config.
    private static func askClaude(
        model: String?,
        system: String, user: String,
        done: @escaping (String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                do {
                    let reply = try await ClaudeBridge.shared.turn(
                        prompt: user, system: system, model: model)
                    done(reply.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    PetLog.log("claude failed: \(error.localizedDescription)")
                    done(nil)
                }
            }
        }
    }

    private static func askOpenAI(
        base: String, key: String, model: String,
        system: String, user: String,
        done: @escaping (String?) -> Void
    ) {
        let urlStr = base.hasSuffix("/chat/completions") ? base
            : base.hasSuffix("/v1") ? base + "/chat/completions"
            : base + "/v1/chat/completions"
        guard let url = URL(string: urlStr) else { done(nil); return }
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
        URLSession(configuration: .ephemeral).dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else { done(nil); return }
            done(content.trimmingCharacters(in: .whitespacesAndNewlines))
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
