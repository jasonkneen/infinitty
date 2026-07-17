import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

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

    /// Hand-off: file results the user wants to see in the code-view sidebar.
    var onShowInSidePanel: ((_ paths: [String], _ query: String?) -> Void)?

    init(config: AppConfig) {
        self.config = config
    }

    func attach(to session: TerminalSession) {
        self.session = session
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

    private func ask(_ request: String, in view: NSView) {
        guard let session else { return }
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
                            answer: final ?? "…", files: matches, query: query, in: view)
                    }
                } else {
                    self.finish(
                        answer: reply
                            ?? "I can't reach an AI right now. Configure ai-base-url/ai-key "
                            + "or enable Apple Intelligence.",
                        files: [], query: nil, in: view)
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
        answer: String, files: [String], query: String?, in view: NSView
    ) {
        DispatchQueue.main.async {
            self.session?.petAnimator?.stopThinking()
            self.lastFiles = files
            self.lastQuery = query
            self.presentResult(answer: answer, in: view)
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
