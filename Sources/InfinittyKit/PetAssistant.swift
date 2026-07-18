import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Full-height presentation of the pet assistant for the sidebar CHAT page.
/// It owns its own AppKit views while sharing the assistant's request state.
final class PetAssistantPanelView: NSView {
    var onSubmit: ((String) -> Void)?
    var onShowFiles: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Assistant")
    private let newChatButton = NSButton(title: "New chat", target: nil, action: nil)
    private let closeButton = NSButton()
    private let sparkleTile = NSView()
    private let sparkleIcon = NSImageView()
    private let separator = NSView()
    private let transcript = NSTextView()
    private let transcriptScroll = NSScrollView()
    private let emptyStateLabel = NSTextField(
        labelWithString: "Choose an agent, ask a question, and keep chatting here.")
    private let modelLabel = NSTextField(labelWithString: "MODEL")
    private let modelPicker = NSPopUpButton()
    private let inputContainer = NSView()
    private let inputScroll = NSScrollView()
    private let input = TabRenameTextView()
    private let attachmentButton = NSButton()
    private let sendButton = NSButton()
    private let showFilesButton = NSButton(title: "Show Files", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        layer?.backgroundColor = NSColor(
            calibratedRed: 0.105, green: 0.11, blue: 0.145, alpha: 1).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        layer?.masksToBounds = true
    }

    private func configureHeader() {
        sparkleTile.wantsLayer = true
        sparkleTile.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        sparkleTile.layer?.cornerRadius = 6
        sparkleIcon.image = NSImage(
            systemSymbolName: "sparkles", accessibilityDescription: "Assistant")
        sparkleIcon.contentTintColor = NSColor(
            calibratedRed: 0.48, green: 0.52, blue: 1, alpha: 1)

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .labelColor

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

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
    }

    private func configureMessages() {
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.textColor = .labelColor
        transcript.font = .systemFont(ofSize: NSFont.systemFontSize)
        transcript.textContainerInset = NSSize(width: 12, height: 10)
        transcriptScroll.borderType = .noBorder
        transcriptScroll.drawsBackground = false
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.documentView = transcript
        transcriptScroll.isHidden = true

        emptyStateLabel.font = .systemFont(ofSize: 12, weight: .regular)
        emptyStateLabel.textColor = NSColor(white: 0.56, alpha: 1)
        emptyStateLabel.alignment = .center
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
        modelLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        modelLabel.textColor = .secondaryLabelColor
        modelPicker.addItem(withTitle: "Auto · Best available")
        modelPicker.controlSize = .regular
        modelPicker.font = .systemFont(ofSize: NSFont.systemFontSize)

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
        input.minSize = NSSize(width: 80, height: 32)
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 32)
        input.textContainerInset = NSSize(width: 3, height: 7)
        input.textContainer?.lineFragmentPadding = 0
        input.textContainer?.maximumNumberOfLines = 1
        input.textContainer?.lineBreakMode = .byClipping
        input.onCommit = { [weak self] in self?.submit() }

        inputScroll.borderType = .noBorder
        inputScroll.drawsBackground = false
        inputScroll.hasHorizontalScroller = false
        inputScroll.hasVerticalScroller = false
        inputScroll.documentView = input

        sendButton.image = NSImage(
            systemSymbolName: "arrow.up", accessibilityDescription: "Send")
        sendButton.isBordered = false
        sendButton.contentTintColor = .white
        sendButton.wantsLayer = true
        sendButton.layer?.backgroundColor = NSColor(
            calibratedRed: 0.39, green: 0.44, blue: 0.92, alpha: 1).cgColor
        sendButton.layer?.cornerRadius = 15
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
    }

    private func installSubviewsAndConstraints() {
        sparkleTile.addSubview(sparkleIcon)
        inputContainer.addSubview(attachmentButton)
        inputContainer.addSubview(inputScroll)
        inputContainer.addSubview(sendButton)
        let views = [
            sparkleTile, sparkleIcon, titleLabel, newChatButton, closeButton,
            separator, transcriptScroll, emptyStateLabel, showFilesButton,
            modelLabel, modelPicker, inputContainer, attachmentButton,
            inputScroll, sendButton,
        ]
        for view in views { view.translatesAutoresizingMaskIntoConstraints = false }
        for view in [
            sparkleTile, titleLabel, newChatButton, closeButton, separator,
            transcriptScroll, emptyStateLabel, showFilesButton, modelLabel,
            modelPicker, inputContainer,
        ] { addSubview(view) }

        NSLayoutConstraint.activate(headerConstraints() + bodyConstraints() + composerConstraints())
    }

    private func headerConstraints() -> [NSLayoutConstraint] {
        [
            sparkleTile.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            sparkleTile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            sparkleTile.widthAnchor.constraint(equalToConstant: 24),
            sparkleTile.heightAnchor.constraint(equalToConstant: 24),
            sparkleIcon.centerXAnchor.constraint(equalTo: sparkleTile.centerXAnchor),
            sparkleIcon.centerYAnchor.constraint(equalTo: sparkleTile.centerYAnchor),
            sparkleIcon.widthAnchor.constraint(equalToConstant: 14),
            sparkleIcon.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: sparkleTile.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: sparkleTile.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            closeButton.centerYAnchor.constraint(equalTo: sparkleTile.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            newChatButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            newChatButton.centerYAnchor.constraint(equalTo: sparkleTile.centerYAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor, constant: 50),
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
            emptyStateLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: transcriptScroll.centerYAnchor, constant: -42),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
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
            modelLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            modelLabel.centerYAnchor.constraint(equalTo: modelPicker.centerYAnchor),
            modelPicker.leadingAnchor.constraint(equalTo: modelLabel.trailingAnchor, constant: 10),
            modelPicker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            modelPicker.bottomAnchor.constraint(equalTo: inputContainer.topAnchor, constant: -10),
            modelPicker.heightAnchor.constraint(equalToConstant: 30),
            attachmentButton.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 8),
            attachmentButton.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            attachmentButton.widthAnchor.constraint(equalToConstant: 24),
            inputScroll.leadingAnchor.constraint(equalTo: attachmentButton.trailingAnchor, constant: 4),
            inputScroll.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            inputScroll.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            inputScroll.heightAnchor.constraint(equalToConstant: 32),
            sendButton.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -7),
            sendButton.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 30),
            sendButton.heightAnchor.constraint(equalToConstant: 30),
        ]
    }

    func setMessages(_ messages: [(role: String, text: String)]) {
        let rendered = NSMutableAttributedString()
        for (index, message) in messages.enumerated() {
            if index > 0 { rendered.append(NSAttributedString(string: "\n\n")) }
            rendered.append(NSAttributedString(
                string: message.role.uppercased() + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            rendered.append(NSAttributedString(
                string: message.text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.labelColor,
                ]))
        }
        transcript.textStorage?.setAttributedString(rendered)
        let isEmpty = messages.isEmpty
        emptyStateLabel.isHidden = !isEmpty
        transcriptScroll.isHidden = isEmpty
        transcript.scrollRangeToVisible(NSRange(location: rendered.length, length: 0))
    }

    func setThinking(_ thinking: Bool) {
        input.isEditable = !thinking
        sendButton.alphaValue = thinking ? 0.45 : 1
    }

    func setHasFiles(_ hasFiles: Bool) { showFilesButton.isHidden = !hasFiles }

    private func submit() {
        let request = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        input.string = ""
        onSubmit?(request)
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

    var titleForTesting: String { titleLabel.stringValue }
    var newChatTitleForTesting: String { newChatButton.title }
    var emptyStateForTesting: String { emptyStateLabel.stringValue }
    var modelLabelForTesting: String { modelLabel.stringValue }
    var modelValueForTesting: String { modelPicker.titleOfSelectedItem ?? "" }
    var attachmentSymbolForTesting: String { "paperclip" }
    var sendSymbolForTesting: String { "arrow.up" }
    var sendButtonIsCircularForTesting: Bool { sendButton.layer?.cornerRadius == 15 }
}

/// The pet assistant. Clicking the pet pops a bubble (same idiom as the
/// rename-tab popover) asking "How can I help?"; the typed request goes to
/// the configured AI with the terminal's recent output as context. While it
/// thinks, the pet loops its review animation; the answer comes back in a
/// second bubble. If the AI asks for files (`SEARCH: <query>` as its whole
/// reply), an rg file search runs in the shell's cwd and the matches come
/// back with a "Show in Side Panel" hand-off to the code view.
final class PetAssistant: NSObject, NSPopoverDelegate {
    private weak var session: TerminalSession?
    private let config: AppConfig
    private var popover: NSPopover?
    private var editor: TabRenameTextView?
    private var anchorRect = NSRect.zero
    private weak var anchorView: NSView?
    private var lastFiles: [String] = []
    private var lastQuery: String?
    private var sidebarMessages: [(role: String, text: String)] = []
    private weak var sidebarPanel: PetAssistantPanelView?

    /// Hand-off: file results the user wants to see in the code-view sidebar.
    var onShowInSidePanel: ((_ paths: [String], _ query: String?) -> Void)?

    init(config: AppConfig) {
        self.config = config
    }

    func attach(to session: TerminalSession) {
        self.session = session
    }

    func makeSidebarPanelView() -> PetAssistantPanelView {
        if let sidebarPanel { return sidebarPanel }
        let panel = PetAssistantPanelView()
        panel.setMessages(sidebarMessages)
        panel.setHasFiles(!lastFiles.isEmpty)
        panel.onSubmit = { [weak self] request in
            self?.submitFromSidebar(request)
        }
        panel.onShowFiles = { [weak self] in
            guard let self, !self.lastFiles.isEmpty else { return }
            self.onShowInSidePanel?(self.lastFiles, self.lastQuery)
        }
        panel.onNewChat = { [weak self] in
            guard let self else { return }
            self.sidebarMessages.removeAll()
            self.lastFiles.removeAll()
            self.lastQuery = nil
            self.sidebarPanel?.setMessages([])
            self.sidebarPanel?.setHasFiles(false)
        }
        sidebarPanel = panel
        return panel
    }

    private func submitFromSidebar(_ request: String) {
        sidebarMessages.append((role: "You", text: request))
        sidebarPanel?.setMessages(sidebarMessages)
        sidebarPanel?.setThinking(true)
        ask(request) { [weak self] answer, files, _ in
            guard let self else { return }
            self.sidebarMessages.append((role: "Assistant", text: answer))
            self.sidebarPanel?.setMessages(self.sidebarMessages)
            self.sidebarPanel?.setHasFiles(!files.isEmpty)
            self.sidebarPanel?.setThinking(false)
        }
    }

    func detach() {
        popover?.close()
        popover = nil
        session = nil
    }

    // MARK: - input bubble

    func presentInput(anchorRect: NSRect, in view: NSView) {
        self.anchorRect = anchorRect
        self.anchorView = view
        let contentSize = NSSize(width: 300, height: 76)
        let content = NSView(frame: NSRect(origin: .zero, size: contentSize))

        let title = NSTextField(labelWithString: "How can I help?")
        title.frame = NSRect(x: 18, y: 49, width: 264, height: 18)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        content.addSubview(title)

        let editor = TabRenameTextView(frame: NSRect(x: 0, y: 0, width: 264, height: 27))
        editor.font = .systemFont(ofSize: 13, weight: .regular)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.isRichText = false
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = true
        editor.autoresizingMask = [.height]
        editor.minSize = NSSize(width: 264, height: 27)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 27)
        editor.textContainerInset = NSSize(width: 7, height: 5)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.maximumNumberOfLines = 1
        editor.textContainer?.lineBreakMode = .byClipping
        editor.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: 27)
        editor.textContainer?.widthTracksTextView = false

        let editorScroll = NSScrollView(frame: NSRect(x: 18, y: 14, width: 264, height: 27))
        editorScroll.borderType = .noBorder
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = .controlBackgroundColor
        editorScroll.hasHorizontalScroller = false
        editorScroll.hasVerticalScroller = false
        editorScroll.autohidesScrollers = true
        editorScroll.wantsLayer = true
        editorScroll.layer?.cornerRadius = 8
        editorScroll.layer?.borderWidth = 1
        editorScroll.layer?.borderColor = NSColor.separatorColor.cgColor
        editorScroll.layer?.masksToBounds = true
        editorScroll.documentView = editor
        content.addSubview(editorScroll)
        self.editor = editor

        editor.onCommit = { [weak self] in self?.commitInput() }
        editor.onCancel = { [weak self] in self?.closePopover() }

        let pop = NSPopover()
        let controller = NSViewController()
        controller.view = content
        controller.preferredContentSize = contentSize
        pop.contentViewController = controller
        pop.contentSize = contentSize
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        popover = pop

        // The pet sits at the bottom of the view: open the bubble above it.
        pop.show(relativeTo: anchorRect, of: view, preferredEdge: .maxY)
        DispatchQueue.main.async { [weak self] in
            guard let self, let editor = self.editor else { return }
            editor.window?.makeFirstResponder(editor)
        }
    }

    private func commitInput() {
        let request = editor?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        closePopover()
        guard !request.isEmpty, let view = anchorView else { return }
        ask(request, in: view)
    }

    private func closePopover() {
        popover?.close()
        popover = nil
        editor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        editor = nil
    }

    // MARK: - the ask pipeline

    private static let systemPrompt = """
    You are the user's pet assistant living inside their terminal. Answer \
    concisely — a few short sentences, plain text, no markdown. Use the \
    terminal context when it's relevant. If fulfilling the request requires \
    finding files in the project, reply with EXACTLY one line in the form \
    "SEARCH: <filename or path keywords>" and nothing else; you will receive \
    the matching files to compose the final answer.
    """

    private typealias AskCompletion = (String, [String], String?) -> Void

    private func ask(
        _ request: String, in view: NSView? = nil, completion: AskCompletion? = nil
    ) {
        guard let session else {
            completion?("No terminal session is available.", [], nil)
            return
        }
        session.petAnimator?.startThinking()
        let source = HintEngine.resolveSmart(
            hints: true, hintCommand: config.hintCommand,
            aiBaseURL: config.aiBaseURL, aiKey: config.aiKey, aiModel: config.aiModel)

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

            Self.askAI(source: source, system: Self.systemPrompt, user: user) { reply in
                if let query = Self.parseSearchDirective(reply), let cwd {
                    let all = CodeSearch.listFilesSync(root: cwd)
                    let matches = CodeSearch.filter(all, query: query, limit: 50)
                    let fileBlock = matches.isEmpty
                        ? "(no files matched)" : matches.joined(separator: "\n")
                    let followUp = context
                        + "\n--- files matching \"\(query)\" ---\n" + fileBlock
                        + "\n--- user request ---\n" + request
                    Self.askAI(source: source, system: Self.systemPrompt, user: followUp) { final in
                        self.finish(
                            answer: final ?? "…", files: matches, query: query,
                            in: view, completion: completion)
                    }
                } else {
                    self.finish(
                        answer: reply
                            ?? "I can't reach an AI right now. Configure ai-base-url/ai-key "
                            + "or enable Apple Intelligence.",
                        files: [], query: nil, in: view, completion: completion)
                }
            }
        }
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
        answer: String, files: [String], query: String?, in view: NSView?,
        completion: AskCompletion?
    ) {
        DispatchQueue.main.async {
            self.session?.petAnimator?.stopThinking()
            self.lastFiles = files
            self.lastQuery = query
            if let completion {
                completion(answer, files, query)
            } else if let view {
                self.presentResult(answer: answer, in: view)
            }
        }
    }

    // MARK: - result bubble

    private func presentResult(answer: String, in view: NSView) {
        let width: CGFloat = 320
        let contentSize = NSSize(width: width, height: 240)
        let content = NSView(frame: NSRect(origin: .zero, size: contentSize))

        let title = NSTextField(labelWithString: "Here's what I found")
        title.frame = NSRect(x: 18, y: contentSize.height - 26, width: width - 36, height: 18)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        content.addSubview(title)

        let answerView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: width - 36, height: 160))
        answerView.isEditable = false
        answerView.isSelectable = true
        answerView.drawsBackground = false
        answerView.font = .systemFont(ofSize: 12)
        answerView.textColor = .labelColor
        answerView.textContainerInset = NSSize(width: 4, height: 4)
        answerView.textContainer?.widthTracksTextView = true
        answerView.isHorizontallyResizable = false
        answerView.isVerticallyResizable = true
        answerView.autoresizingMask = [.width]
        answerView.string = answer

        let scroll = NSScrollView(
            frame: NSRect(x: 18, y: 42, width: width - 36, height: contentSize.height - 76))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = answerView
        content.addSubview(scroll)

        var buttonX: CGFloat = width - 18
        func placeButton(_ title: String, action: Selector, visible: Bool = true) {
            guard visible else { return }
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.sizeToFit()
            button.frame.origin = NSPoint(x: buttonX - button.frame.width, y: 10)
            buttonX -= button.frame.width + 8
            content.addSubview(button)
        }
        placeButton("Done", action: #selector(doneTapped(_:)))
        placeButton("Ask Again", action: #selector(askAgainTapped(_:)))
        placeButton("Show in Side Panel",
                    action: #selector(showInPanelTapped(_:)),
                    visible: !lastFiles.isEmpty)

        let pop = NSPopover()
        let controller = NSViewController()
        controller.view = content
        controller.preferredContentSize = contentSize
        pop.contentViewController = controller
        pop.contentSize = contentSize
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        popover = pop
        pop.show(relativeTo: anchorRect, of: view, preferredEdge: .maxY)
    }

    @objc private func doneTapped(_ sender: Any?) {
        closePopover()
    }

    @objc private func askAgainTapped(_ sender: Any?) {
        guard let view = anchorView else { return }
        closePopover()
        presentInput(anchorRect: anchorRect, in: view)
    }

    @objc private func showInPanelTapped(_ sender: Any?) {
        let files = lastFiles
        let query = lastQuery
        closePopover()
        onShowInSidePanel?(files, query)
    }

    // MARK: - AI backends (mirrors HintEngine's smart-source resolution)

    /// Calls `done` on whatever thread the backend completes on; callers hop
    /// to main as needed.
    static func askAI(
        source: HintEngine.SmartSource,
        system: String, user: String,
        done: @escaping (String?) -> Void
    ) {
        switch source {
        case .none:
            done(nil)
        case .command(let cmd):
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", cmd]
            let stdin = Pipe()
            let stdout = Pipe()
            p.standardInput = stdin
            p.standardOutput = stdout
            p.standardError = Pipe()
            guard let _ = try? p.run() else { done(nil); return }
            stdin.fileHandleForWriting.write(Data((system + "\n\n" + user).utf8))
            try? stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { done(nil); return }
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            done(text?.isEmpty == false ? text : nil)
        case .openai(let base, let key, let model):
            askOpenAI(base: base, key: key, model: model, system: system, user: user, done: done)
        case .foundation:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                Task {
                    let r = await PetAssistantFM.answer(system: system, user: user)
                    done(r)
                }
            } else { done(nil) }
            #else
            done(nil)
            #endif
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
