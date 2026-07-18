import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

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
    var onSubmit: ((String, String) -> Void)?
    /// Agent backend labels ("Codex", "Claude") the owner detected; injected
    /// at init so UI construction stays machine-independent and testable.
    private let agentTitles: [String]
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

    init(presentation: Presentation, config: AppConfig, agentTitles: [String] = []) {
        self.presentation = presentation
        self.config = config
        self.agentTitles = agentTitles
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
            layer?.backgroundColor = NSColor(
                calibratedRed: 0.105, green: 0.11, blue: 0.145, alpha: 1).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        }
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
        closeButton.isHidden = presentation == .sidebar

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
        modelLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        modelLabel.textColor = .secondaryLabelColor
        for title in composerModelTitles() { modelPicker.addItem(withTitle: title) }
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

        sendButton.image = NSImage(
            systemSymbolName: "arrow.up", accessibilityDescription: "Send")
        sendButton.isBordered = false
        sendButton.imagePosition = .imageOnly
        sendButton.focusRingType = .none
        sendButton.contentTintColor = .white
        sendButton.wantsLayer = true
        sendButton.layer?.backgroundColor = NSColor(
            calibratedRed: 0.39, green: 0.44, blue: 0.92, alpha: 1).cgColor
        sendButton.layer?.cornerRadius = 15
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
    }

    private func composerModelTitles() -> [String] {
        var titles = ["Auto · Best available"]
        titles += agentTitles
        if let model = config.aiModel, !model.isEmpty {
            titles.append(model)
        } else if let base = config.aiBaseURL, !base.isEmpty {
            titles.append("gpt-4o-mini")
        }
        return titles
    }

    /// The composer's currently-selected MODEL title ("Auto · Best available",
    /// "Codex", "Claude", or a configured model name). Read at submit time.
    var selectedModelTitle: String { modelPicker.titleOfSelectedItem ?? "Auto · Best available" }

    override func layout() {
        super.layout()
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
        let newChatTrailing = presentation == .popover
            ? newChatButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8)
            : newChatButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13)
        return [
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
            newChatTrailing,
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

    func focusInput() { window?.makeFirstResponder(input) }

    private func submit() {
        let request = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        input.string = ""
        onSubmit?(request, selectedModelTitle)
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
    var modelItemTitlesForTesting: [String] { modelPicker.itemTitles }
    var inputFrameForTesting: NSRect { input.frame }
    var inputIsFirstResponderForTesting: Bool { input.window?.firstResponder === input }
    var attachmentSymbolForTesting: String { "paperclip" }
    var sendSymbolForTesting: String { "arrow.up" }
    var sendButtonIsCircularForTesting: Bool { sendButton.layer?.cornerRadius == 15 }
    var presentationForTesting: Presentation { presentation }
    var showsCloseButtonForTesting: Bool { !closeButton.isHidden }
    var usesGlassSurfaceForTesting: Bool { presentation == .popover }
    var transcriptForTesting: String { transcript.string }
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
    /// Locally-installed coding-agent CLIs, detected once at construction.
    let detectedAgents: [DetectedAgent]

    /// Hand-off: file results the user wants to see in the code-view sidebar.
    var onShowInSidePanel: ((_ paths: [String], _ query: String?) -> Void)?

    init(config: AppConfig, detectedAgents: [DetectedAgent] = AgentDetector.detect()) {
        self.config = config
        self.detectedAgents = detectedAgents
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
            agentTitles: detectedAgents.map(\.label))
        panel.setMessages(sidebarMessages)
        panel.setHasFiles(!lastFiles.isEmpty)
        panel.onSubmit = { [weak self] request, model in
            self?.submitFromPanel(request, model: model)
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
    private func submitFromPanel(_ request: String, model: String) {
        sidebarMessages.append((role: "You", text: request))
        updatePanels()
        setPanelsThinking(true)
        ask(request, model: model) { [weak self] answer, _, _ in
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
    You are the user's pet assistant living inside their terminal. Answer \
    concisely — a few short sentences, plain text, no markdown. Use the \
    terminal context when it's relevant. If fulfilling the request requires \
    finding files in the project, reply with EXACTLY one line in the form \
    "SEARCH: <filename or path keywords>" and nothing else; you will receive \
    the matching files to compose the final answer.
    """

    private typealias AskCompletion = (String, [String], String?) -> Void

    private func ask(
        _ request: String, model: String = "Auto · Best available",
        completion: AskCompletion? = nil
    ) {
        guard let session else {
            completion?("No terminal session is available.", [], nil)
            return
        }
        session.petAnimator?.startThinking()
        let chain = backendChain(for: model)

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

            Self.runChain(chain, system: Self.systemPrompt, user: user, cwd: cwd) { reply in
                if let query = Self.parseSearchDirective(reply), let cwd {
                    let all = CodeSearch.listFilesSync(root: cwd)
                    let matches = CodeSearch.filter(all, query: query, limit: 50)
                    let fileBlock = matches.isEmpty
                        ? "(no files matched)" : matches.joined(separator: "\n")
                    let followUp = context
                        + "\n--- files matching \"\(query)\" ---\n" + fileBlock
                        + "\n--- user request ---\n" + request
                    Self.runChain(chain, system: Self.systemPrompt, user: followUp, cwd: cwd) { final in
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

    /// A resolved chat backend: a detected CLI agent or the hint-style source.
    enum ChatBackend {
        case agent(DetectedAgent)
        case smart(HintEngine.SmartSource)
    }

    /// Ordered backends to try for `model`. Explicit picks force a single
    /// backend; "Auto" prefers detected agents, then OpenAI, then Foundation.
    func backendChain(for model: String) -> [ChatBackend] {
        if let agent = detectedAgents.first(where: { $0.label == model }) {
            return [.agent(agent)]
        }
        if let base = config.aiBaseURL, !base.isEmpty,
           model != "Auto · Best available" {
            return [.smart(.openai(base: base, key: config.aiKey ?? "", model: model))]
        }
        // Auto: detected agents first, then configured smart source.
        var chain: [ChatBackend] = detectedAgents.map { .agent($0) }
        let smart = HintEngine.resolveSmart(
            hints: true, hintCommand: config.hintCommand,
            aiBaseURL: config.aiBaseURL, aiKey: config.aiKey, aiModel: config.aiModel)
        if case .none = smart {} else { chain.append(.smart(smart)) }
        return chain
    }

    /// Try each backend in order until one returns a non-empty answer.
    static func runChain(
        _ chain: [ChatBackend], system: String, user: String,
        cwd: String? = nil,
        done: @escaping (String?) -> Void
    ) {
        guard let first = chain.first else { done(nil); return }
        let rest = Array(chain.dropFirst())
        run(first, system: system, user: user, cwd: cwd) { reply in
            if let reply, !reply.isEmpty { done(reply); return }
            runChain(rest, system: system, user: user, cwd: cwd, done: done)
        }
    }

    static func run(
        _ backend: ChatBackend, system: String, user: String,
        cwd: String? = nil,
        done: @escaping (String?) -> Void
    ) {
        switch backend {
        case .agent(let agent):
            spawnAgent(agent, system: system, user: user, cwd: cwd, done: done)
        case .smart(let source):
            askAI(source: source, system: system, user: user, done: done)
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

    /// Drive a detected coding-agent CLI non-interactively: prompt on stdin,
    /// answer read from stdout (or codex's last-message file). stderr is
    /// drained on a background read so verbose agent logs never deadlock the
    /// pipe. A watchdog kills a run that exceeds `timeout`.
    static func spawnAgent(
        _ agent: DetectedAgent, system: String, user: String,
        cwd: String? = nil,
        timeout: TimeInterval = 90,
        done: @escaping (String?) -> Void
    ) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: agent.path)
        if let cwd, !cwd.isEmpty {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        var lastMessageFile: String?
        var args = AgentDetector.args(for: agent.kind, model: nil)
        if agent.kind == .codex {
            let tmp = NSTemporaryDirectory() + "infinitty-codex-\(UUID().uuidString).txt"
            FileManager.default.createFile(atPath: tmp, contents: nil)
            lastMessageFile = tmp
            args += ["-o", tmp]
        }
        proc.arguments = args

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        // Drain stderr so a full pipe can't block the child.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        guard (try? proc.run()) != nil else {
            if let lastMessageFile { try? FileManager.default.removeItem(atPath: lastMessageFile) }
            done(nil)
            return
        }

        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        stdin.fileHandleForWriting.write(Data((system + "\n\n" + user).utf8))
        try? stdin.fileHandleForWriting.close()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()
        stderr.fileHandleForReading.readabilityHandler = nil

        var answer: String?
        if let lastMessageFile {
            answer = try? String(contentsOfFile: lastMessageFile, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: lastMessageFile)
        }
        if answer == nil || answer?.isEmpty == true {
            answer = String(data: stdoutData, encoding: .utf8)
        }
        let trimmed = answer?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard proc.terminationStatus == 0, let trimmed, !trimmed.isEmpty else {
            done(nil)
            return
        }
        done(trimmed)
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
