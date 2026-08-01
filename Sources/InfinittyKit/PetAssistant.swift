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
import ShadcnUI
import SwiftUI
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

/// One conversation in the multi-chat store. In-memory for now; popover and
/// sidebar share the same `PetAssistant` so both surfaces see every thread.
/// Weak box so multi-pane embeddings don't keep closed Chat leaves alive.
private final class WeakPetAssistantPanel {
    weak var panel: PetAssistantPanelView?
    init(_ panel: PetAssistantPanelView) { self.panel = panel }
}

struct ChatThread: Identifiable {
    let id: UUID
    var title: String
    var messages: [AssistantChatMessage]
    var updatedAt: Date
    /// File hand-off state belongs to the conversation that produced it.
    var lastFiles: [String]
    var lastQuery: String?
    /// Backend/model/workspace identity whose state currently backs this
    /// thread. A change means the next stateful turn must bootstrap from the
    /// bounded visible transcript because the bridge will start fresh.
    var backendSessionSignature: String?
    /// Distinguishes a never-used thread from one whose keyed backend state was
    /// explicitly cancelled and must be rebuilt from visible history.
    var needsBackendBootstrap: Bool
    /// Keyed transport lifecycle epoch. Unlike the UI request generation,
    /// this advances only when backend work/state is actually cancelled.
    var backendEpoch: Int
    /// Bumped when this thread is abandoned mid-flight so stale answers drop.
    var generation: Int

    init(
        id: UUID = UUID(),
        title: String = "New chat",
        messages: [AssistantChatMessage] = [],
        updatedAt: Date = Date(),
        lastFiles: [String] = [],
        lastQuery: String? = nil,
        backendSessionSignature: String? = nil,
        needsBackendBootstrap: Bool = false,
        backendEpoch: Int = 0,
        generation: Int = 0
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.updatedAt = updatedAt
        self.lastFiles = lastFiles
        self.lastQuery = lastQuery
        self.backendSessionSignature = backendSessionSignature
        self.needsBackendBootstrap = needsBackendBootstrap
        self.backendEpoch = backendEpoch
        self.generation = generation
    }

    /// First user line, trimmed and capped for the thread switcher.
    static func title(fromFirstUserMessage text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "New chat"
        if line.count <= 36 { return line }
        let end = line.index(line.startIndex, offsetBy: 35)
        return String(line[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }
}

struct AssistantChatControlState: Equatable, Sendable {
    struct Message: Equatable, Sendable {
        let role: String
        let text: String
        let createdAt: Date
        let tokenCount: Int?
    }

    struct Thread: Equatable, Sendable {
        let id: String
        let title: String
        let messages: [Message]
        let updatedAt: Date
    }

    let activeThreadID: String
    let threads: [Thread]
    let queuedRequests: [String]
    let requestInFlight: Bool
    let streamingThreadID: String?
    let workspaceDirectory: String

    func jsonObject() -> [String: Any] {
        [
            "activeThreadId": activeThreadID,
            "threads": threads.map { thread in
                [
                    "id": thread.id,
                    "title": thread.title,
                    "updatedAt": ISO8601DateFormatter().string(
                        from: thread.updatedAt),
                    "messages": thread.messages.map { message in
                        var value: [String: Any] = [
                            "role": message.role,
                            "text": message.text,
                            "createdAt": ISO8601DateFormatter().string(
                                from: message.createdAt),
                        ]
                        if let tokenCount = message.tokenCount {
                            value["tokenCount"] = tokenCount
                        }
                        return value
                    },
                ] as [String: Any]
            },
            "queuedRequests": queuedRequests,
            "requestInFlight": requestInFlight,
            "streamingThreadId": streamingThreadID ?? NSNull(),
            "workspaceDirectory": workspaceDirectory,
        ]
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
    /// Live tail of the in-flight answer, shown while streaming so a long
    /// turn visibly progresses instead of looking hung.
    private var detailText: String?

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

    /// Update (or clear, with nil) the live answer snippet shown alongside
    /// the elapsed-time counter while a turn streams in.
    func setDetail(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        detailText = (trimmed?.isEmpty ?? true) ? nil : trimmed
        refreshElapsed()
    }

    private func refreshElapsed() {
        let seconds = Int(Date().timeIntervalSince(startedAt))
        let elapsed = seconds < 2 ? "" : " · \(seconds)s"
        if let detail = detailText {
            let snippet = detail.count > 80 ? "…" + String(detail.suffix(80)) : detail
            label.stringValue = snippet + elapsed
        } else {
            label.stringValue = baseText + "…" + elapsed
        }
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
    /// UI construction stays machine-independent and testable. Mutable so a
    /// model discovered after launch can be appended live.
    private var choices: [PetAssistant.AgentChoice]
    /// Per-provider discovery state driving the model submenus. `nil` means
    /// "not asked yet"; the submenu shows its seed rows until an answer lands.
    private var discovered: [PetAssistant.AgentChoice.Kind: ProviderModels] = [:]
    var onShowFiles: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onSelectThread: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let newChatButton = NSButton(title: "New", target: nil, action: nil)
    private let closeButton = NSButton()
    private let separator = NSView()
    private let transcriptStack = NSStackView()
    private let transcriptScroll = NSScrollView()
    private let queueStack = NSStackView()
    private let queueScroll = NSScrollView()
    private var queueHeightConstraint: NSLayoutConstraint!
    /// Root constraints for the dormant AppKit surface. The full Shadcn panel
    /// replaces that layout and must not remain constrained by hidden views.
    private var legacyLayoutConstraints: [NSLayoutConstraint] = []
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
        populateModelPicker()
        modelPicker.isHidden = true

        effortPicker.controlSize = .regular
        effortPicker.font = .systemFont(ofSize: NSFont.systemFontSize)
        effortPicker.menu?.removeAllItems()
        for level in Self.fallbackEfforts {
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
        case .opencode: logoAsset = "opencode"   // no asset yet → SF Symbol fallback
        case .hermes: logoAsset = "hermes"
        case .amp: logoAsset = "amp"
        case .auto: logoAsset = nil
        }
        if let logoAsset,
           let url = Bundle.infinittyResourceURL(
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

        legacyLayoutConstraints = headerConstraints() + bodyConstraints() + composerConstraints()
        NSLayoutConstraint.activate(legacyLayoutConstraints)
        installShadcnTranscriptIfEnabled()
    }

    /// Lays the ShadKit transcript over the same rect the AppKit scroll
    /// view occupies. Only the transcript is swapped — the composer, queue and
    /// model pickers are untouched.
    /// Maps an agent kind to the identifier the composer's picker uses.
    private static func agentIdentifier(for kind: PetAssistant.AgentChoice.Kind) -> String {
        switch kind {
        case .auto: "auto"
        case .claude: "claude"
        case .codex: "codex"
        case .opencode: "opencode"
        case .hermes: "hermes"
        case .amp: "amp"
        case .apple: "apple"
        }
    }

    private func installShadcnTranscriptIfEnabled() {
        guard ShadcnChatFeature.isEnabled else { return }

        // Replace the whole surface. Every AppKit child is hidden rather than
        // removed so the existing wiring (and its tests) keeps working, while
        // the SwiftUI panel owns the visible layout.
        NSLayoutConstraint.deactivate(legacyLayoutConstraints)
        for child in subviews { child.isHidden = true }

        let host = ShadcnAssistantHost()
        // Forward the panel's chosen model/effort — never ignore them in
        // favour of AppKit-only state. selectChoice/onModelChange keep the two
        // in lockstep; if they diverge, the panel is the surface the user saw.
        host.model.onSubmit = { [weak self] request, model, effort in
            guard let self else { return }
            if let choice = self.choices.first(where: { $0.displayName == model }) {
                self.selectChoice(choice)
            }
            self.effortPicker.selectItem(withTitle: effort)
            self.onSubmit?(request, model, effort)
        }
        host.model.onNewChat = { [weak self] in self?.onNewChat?() }
        host.model.onSelectThread = { [weak self] id in self?.onSelectThread?(id) }

        // Agent = provider kinds; Model = concrete choices under the kind.
        // Selecting either routes through selectChoice so submit/routing see it.
        host.model.onAgentChange = { [weak self] name in
            guard let self else { return }
            self.applyShadcnAgentSelection(name)
        }
        host.model.onModelChange = { [weak self] name in
            guard let self else { return }
            if let choice = self.choices.first(where: { $0.displayName == name }) {
                self.selectChoice(choice)
            }
            self.syncShadcnComposerState()
        }
        host.model.onEffortChange = { [weak self] value in
            guard let self else { return }
            self.effortPicker.selectItem(withTitle: value)
            self.refreshEffortChip()
            self.syncShadcnComposerState()
        }

        // Seed the three pickers from the live AppKit selection store.
        syncShadcnComposerState(into: host)

        let panel = host.view!
        panel.translatesAutoresizingMaskIntoConstraints = false
        // Menus open upward into the transcript; clipping them at the rounded
        // corner would reintroduce the bottom-picker bug the upward edge fixes.
        // Popover glass also masks — turn that off so the composer footer isn't
        // sliced by the 16pt corner radius.
        layer?.masksToBounds = false
        clipsToBounds = false
        glassBackground.layer?.masksToBounds = false
        glassBackground.clipsToBounds = false
        addSubview(panel)
        // Popover: keep content slightly inside the rounded chrome so chips
        // and the input aren't cut by the popover window's clip shape.
        let edge: CGFloat = presentation == .popover ? 1 : 0
        let bottomInset: CGFloat = presentation == .popover ? 6 : 0
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: edge),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -edge),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: edge),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset),
        ])

        // The AppKit text view is hidden now; if it kept first responder it
        // would swallow every keystroke into a field nobody can see.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel else { return }
            let current = self.window?.firstResponder
            if current == nil || current === self.input || current === self.window {
                self.window?.makeFirstResponder(panel.focusTarget)
            }
        }

        shadcnPanel = host
    }

    /// Observe only the backend conversation represented by this panel's
    /// selected thread. Replacing the scope cancels just this panel's token.
    func setToolEventScopeID(_ scopeID: String?) {
        guard toolEventScopeID != scopeID else { return }
        toolEventScopeID = scopeID
        toolEventSubscription?.cancel()
        toolEventSubscription = nil
        shadcnPanel?.clearToolEvents()
        guard let scopeID, let host = shadcnPanel else { return }
        toolEventSubscription = AssistantToolEventBus.subscribe(scopeID: scopeID) {
            [weak host] event in
            guard let host else { return }
            MainActor.assumeIsolated { host.applyToolEvent(event) }
        }
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
    /// Non-nil when `INFINITTY_SHADCN_CHAT=1` swapped in the SwiftUI transcript.
    private var shadcnTranscript: ShadcnTranscriptHostView?
    /// Non-nil when the whole panel is the ShadKit one.
    private var shadcnPanel: ShadcnAssistantHost?
    private var toolEventSubscription: AssistantToolEventBus.Subscription?
    private var toolEventScopeID: String?

    func setMessages(_ messages: [AssistantChatMessage]) {
        lastMessages = messages
        rebuildTranscript()
    }

    func setMessages(_ messages: [(role: String, text: String)]) {
        setMessages(messages.map { AssistantChatMessage(role: $0.role, text: $0.text) })
    }

    func setQueuedMessages(_ messages: [String]) {
        queuedMessages = messages
        if let shadcnPanel {
            shadcnPanel.setQueuedMessages(messages)
            return
        }
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
        if let shadcnPanel {
            shadcnPanel.setMessages(lastMessages)
            return
        }
        if let shadcnTranscript {
            shadcnTranscript.setMessages(lastMessages)
            let showTranscript = !lastMessages.isEmpty || typingIndicator != nil
            emptyStateLabel.isHidden = showTranscript
            shadcnTranscript.isHidden = !showTranscript
            // The AppKit stack stays out of the way entirely in this mode.
            transcriptScroll.isHidden = true
            return
        }

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
        shadcnTranscript?.setThinking(thinking, label: label)
        if let shadcnPanel {
            shadcnPanel.setThinking(thinking, label: label)
            return
        }
        if thinking, typingIndicator == nil {
            typingIndicator = ChatTypingIndicator(label: label ?? "Thinking")
            rebuildTranscript()
        } else if !thinking, typingIndicator != nil {
            typingIndicator = nil
            rebuildTranscript()
        }
    }

    /// Live-stream the in-flight answer tail into the thinking indicator.
    ///
    /// The ShadKit transcript renders the same tail as a real assistant
    /// turn, so markdown and code blocks appear as they arrive rather than as a
    /// single-line detail string.
    func setStreamingText(_ text: String?) {
        if let shadcnPanel {
            shadcnPanel.setStreamingText(text)
            return
        }
        typingIndicator?.setDetail(text)
        shadcnTranscript?.setStreamingText(text)
    }

    func setHasFiles(_ hasFiles: Bool) {
        showFilesButton.isHidden = !hasFiles
        shadcnPanel?.setHasFiles(hasFiles)
    }

    func setThreads(_ threads: [(id: String, title: String)], activeId: String?) {
        shadcnPanel?.setThreads(threads, activeId: activeId)
    }

    func focusInput() {
        // With the ShadKit panel installed the AppKit input is hidden, so
        // making it first responder sends every keystroke into a view nobody
        // can see. Hand focus to the composer's real NSTextView (the AppKit
        // path ShadKit uses), falling back to the hosting view.
        if let shadcnPanel {
            let root = shadcnPanel.view.focusTarget
            if let textView = Self.firstNSTextView(in: root) {
                window?.makeFirstResponder(textView)
            } else {
                window?.makeFirstResponder(root)
            }
            return
        }
        window?.makeFirstResponder(input)
    }

    private static func firstNSTextView(in root: NSView) -> NSTextView? {
        if let textView = root as? NSTextView { return textView }
        for child in root.subviews {
            if let found = firstNSTextView(in: child) { return found }
        }
        return nil
    }

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

    /// The visible model chip menu: `Auto`, then one submenu per provider that
    /// is actually installed. Provider models are *not* fetched here — each
    /// submenu resolves when it opens (see `menuNeedsUpdate`), so dropping the
    /// chip never spawns five agent processes.
    private func makeModelMenu() -> NSMenu {
        let menu = NSMenu(title: "Model")
        menu.autoenablesItems = false

        if let autoItem = modelPicker.menu?.items.first(where: {
            ($0.representedObject as? PetAssistant.AgentChoice)?.kind == .auto
        }) {
            menu.addItem(selectableItem(for: autoItem))
        }

        let providers = orderedProviderKinds()
        if !providers.isEmpty { menu.addItem(.separator()) }
        for kind in providers {
            let item = NSMenuItem(title: kind.providerLabel, action: nil, keyEquivalent: "")
            item.image = PetAssistantPanelView.providerImage(
                for: PetAssistant.AgentChoice(
                    kind: kind, modelID: nil, displayName: kind.providerLabel,
                    symbolName: kind.symbolName))
            let submenu = NSMenu(title: kind.providerLabel)
            submenu.autoenablesItems = false
            submenu.delegate = self
            submenu.identifier = NSUserInterfaceItemIdentifier(kind.configuredProviderKey)
            populate(submenu, for: kind)
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    /// Providers with at least one choice, in the picker's own order.
    private func orderedProviderKinds() -> [PetAssistant.AgentChoice.Kind] {
        var seen = Set<PetAssistant.AgentChoice.Kind>()
        var out: [PetAssistant.AgentChoice.Kind] = []
        for choice in choices where choice.kind != .auto && choice.kind != .apple {
            if seen.insert(choice.kind).inserted { out.append(choice.kind) }
        }
        return out
    }

    /// Render a provider's current discovery state into its submenu. Called on
    /// build and again each time an answer (or failure) lands.
    private func populate(_ menu: NSMenu, for kind: PetAssistant.AgentChoice.Kind) {
        menu.removeAllItems()
        switch discovered[kind] {
        case .loading:
            menu.addItem(disabledItem("Loading…"))
        case .failed(let message):
            menu.addItem(disabledItem("⚠ \(message)"))
            let retry = NSMenuItem(
                title: "Retry", action: #selector(retryDiscovery(_:)), keyEquivalent: "")
            retry.target = self
            retry.representedObject = kind.configuredProviderKey
            menu.addItem(retry)
        case .loaded(let models):
            addModelItems(models, to: menu, kind: kind)
        case nil:
            // Not asked yet — show what the picker was seeded with so the menu
            // is never empty, and let `menuNeedsUpdate` fetch the real list.
            addModelItems(seededModels(for: kind), to: menu, kind: kind)
        }
    }

    /// One row per model, or a level of sub-provider groups when the provider
    /// returns too many to read flat (only opencode does today, at 123).
    private func addModelItems(
        _ models: [DiscoveredModel], to menu: NSMenu, kind: PetAssistant.AgentChoice.Kind
    ) {
        guard !models.isEmpty else {
            menu.addItem(disabledItem("No models."))
            return
        }
        guard ModelDiscovery.shouldGroup(models) else {
            for model in models { menu.addItem(modelItem(model, kind: kind)) }
            return
        }
        var order: [String] = []
        var grouped: [String: [DiscoveredModel]] = [:]
        for model in models {
            let group = model.group ?? "Other"
            if grouped[group] == nil { order.append(group) }
            grouped[group, default: []].append(model)
        }
        for group in order {
            let item = NSMenuItem(title: group, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: group)
            submenu.autoenablesItems = false
            for model in grouped[group] ?? [] {
                submenu.addItem(modelItem(model, kind: kind))
            }
            item.submenu = submenu
            menu.addItem(item)
        }
    }

    private func modelItem(
        _ model: DiscoveredModel, kind: PetAssistant.AgentChoice.Kind
    ) -> NSMenuItem {
        let choice = PetAssistant.AgentChoice(
            model, kind: kind, symbolName: kind.symbolName)
        let item = NSMenuItem(
            title: model.isDefault ? "\(model.name)  (default)" : model.name,
            action: #selector(modelChoiceSelected(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = choice
        item.toolTip = model.description
        item.state = choice.displayName == selectedChoice.displayName ? .on : .off
        return item
    }

    /// Mirror an existing hidden-picker item (used for the Auto row, whose
    /// choice object is owned by the picker).
    private func selectableItem(for pickerItem: NSMenuItem) -> NSMenuItem {
        let item = NSMenuItem(
            title: pickerItem.title, action: #selector(modelChoiceSelected(_:)),
            keyEquivalent: "")
        item.target = self
        item.representedObject = pickerItem.representedObject
        item.image = pickerItem.image
        item.state = pickerItem === modelPicker.selectedItem ? .on : .off
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// The models this provider was seeded with at init, recovered from the
    /// picker so a not-yet-queried submenu still lists something.
    private func seededModels(for kind: PetAssistant.AgentChoice.Kind) -> [DiscoveredModel] {
        choices.filter { $0.kind == kind }.map { choice in
            DiscoveredModel(
                id: choice.modelID ?? "",
                name: choice.displayName.replacingOccurrences(
                    of: "\(kind.providerLabel) · ", with: ""),
                description: nil, isDefault: false,
                efforts: choice.supportedEfforts, defaultEffort: choice.defaultEffort,
                group: nil)
        }
    }

    @objc private func modelChoiceSelected(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? PetAssistant.AgentChoice else { return }
        selectChoice(choice)
    }

    @objc private func retryDiscovery(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let kind = PetAssistant.AgentChoice.Kind(configuredProvider: key) else { return }
        discovered[kind] = nil
        Task { await ModelDiscovery.shared.refresh(kind) }
        resolveProvider(kind, force: true)
    }

    /// Make a discovered model the live selection: register it in the hidden
    /// picker (the selection store), select it, and let the effort chip follow.
    private func selectChoice(_ choice: PetAssistant.AgentChoice) {
        if !choices.contains(where: { $0.displayName == choice.displayName }) {
            choices.append(choice)
            populateModelPicker()
        }
        modelPicker.selectItem(withTitle: choice.displayName)
        refreshModelChip()
        syncShadcnComposerState()
    }

    /// Pushes agent/model/effort into the ShadKit panel so the composer
    /// pickers show what submit will actually use — with brand logos on
    /// agent/model rows like AI Elements' model selector.
    private func syncShadcnComposerState(into host: ShadcnAssistantHost? = nil) {
        let target = host ?? shadcnPanel
        guard let target else { return }

        // Agent = Auto + each installed provider kind (Claude, Codex…).
        var agentOptions: [ShadcnSelectOption<String>] = [
            Self.selectOption(
                value: "Auto", label: "Auto", kind: .auto),
        ]
        for kind in orderedProviderKinds() {
            agentOptions.append(Self.selectOption(
                value: kind.providerLabel,
                label: kind.providerLabel,
                kind: kind))
        }
        target.model.agents = agentOptions

        let agentLabel: String = selectedChoice.kind == .auto
            ? "Auto"
            : selectedChoice.kind.providerLabel
        target.model.agent = agentLabel

        // Model = concrete choices. Always populate when anything is known so
        // the chip (and its brand icon) is present — not just after picking
        // a non-Auto agent.
        let modelChoices: [PetAssistant.AgentChoice]
        if selectedChoice.kind == .auto {
            modelChoices = choices.filter { $0.kind != .auto }
        } else {
            let matching = choices.filter { $0.kind == selectedChoice.kind }
            modelChoices = matching.isEmpty
                ? [PetAssistant.AgentChoice(
                    kind: selectedChoice.kind, modelID: nil,
                    displayName: agentLabel,
                    symbolName: selectedChoice.kind.symbolName)]
                : matching
        }
        let modelOptions = modelChoices.map { choice -> ShadcnSelectOption<String> in
            // Prefer the bare model name in the chip; keep the full display
            // name as the value so selectChoice still matches.
            let short = Self.shortModelLabel(for: choice)
            return Self.selectOption(
                value: choice.displayName,
                label: short,
                kind: choice.kind)
        }
        target.setModels(
            modelOptions,
            selected: selectedChoice.kind == .auto && selectedChoice.displayName == "Auto"
                ? nil
                : selectedChoice.displayName)

        let titles = effortPicker.itemTitles.isEmpty
            ? Self.fallbackEfforts
            : effortPicker.itemTitles
        // Vertical phone-signal bars at different fill levels (SF Symbol
        // `cellularbars` + variableValue). Chip is icon-only; menu still
        // shows the full label (Auto / Low / Max / …).
        let effortBars: (String) -> Double = { title in
            switch title.lowercased() {
            case "none", "off": return 0
            case "low", "minimal": return 0.25
            case "auto": return 0.4
            case "medium": return 0.55
            case "high", "max": return 0.8
            case "ultra", "xhigh": return 1
            default: return 0.4
            }
        }
        target.setEfforts(
            titles.map {
                ShadcnSelectOption(
                    value: $0, label: $0,
                    systemImage: "cellularbars",
                    symbolVariableValue: effortBars($0))
            },
            selected: selectedEffort)
    }

    /// "Hermes · gpt-5.6-sol" → "gpt-5.6-sol" for compact model chips.
    private static func shortModelLabel(for choice: PetAssistant.AgentChoice) -> String {
        let prefix = "\(choice.kind.providerLabel) · "
        if choice.displayName.hasPrefix(prefix) {
            return String(choice.displayName.dropFirst(prefix.count))
        }
        return choice.displayName
    }

    /// Build a select option with the models.dev brand logo when we have one.
    private static func selectOption(
        value: String,
        label: String,
        kind: PetAssistant.AgentChoice.Kind
    ) -> ShadcnSelectOption<String> {
        let probe = PetAssistant.AgentChoice(
            kind: kind, modelID: nil,
            displayName: label, symbolName: kind.symbolName)
        let image: Image? = {
            guard let ns = PetAssistantPanelView.providerImage(for: probe) else { return nil }
            return Image(nsImage: ns)
        }()
        return ShadcnSelectOption(
            value: value,
            label: label,
            systemImage: kind.symbolName,
            image: image)
    }

    /// Agent chip selected a provider label (or Auto). Pick a concrete model
    /// under that kind so selectChoice / submit stay coherent.
    private func applyShadcnAgentSelection(_ name: String) {
        if name == "Auto" {
            selectChoice(.auto)
            syncShadcnComposerState()
            return
        }
        let knownKinds: [PetAssistant.AgentChoice.Kind] = [
            .claude, .codex, .opencode, .hermes, .amp,
        ]
        guard let kind = orderedProviderKinds().first(where: { $0.providerLabel == name })
            ?? knownKinds.first(where: { $0.providerLabel == name })
        else { return }
        // Prefer an already-known model of this kind; otherwise a kind-level row.
        if let existing = choices.first(where: { $0.kind == kind }) {
            selectChoice(existing)
        } else {
            selectChoice(PetAssistant.AgentChoice(
                kind: kind, modelID: nil,
                displayName: kind.providerLabel, symbolName: kind.symbolName))
        }
        resolveProvider(kind)
        syncShadcnComposerState()
    }

    /// (Re)build the hidden model popup's items from `choices`. This popup is
    /// pure selection state — the "Custom…" rows live only in the visible
    /// chip menu (`makeModelMenu`) so the state titles stay exactly `choices`.
    private func populateModelPicker() {
        modelPicker.menu?.removeAllItems()
        for choice in choices {
            let item = NSMenuItem(title: choice.displayName, action: nil, keyEquivalent: "")
            item.representedObject = choice
            item.image = PetAssistantPanelView.providerImage(for: choice)
            modelPicker.menu?.addItem(item)
        }
    }

    /// Ask a provider for its models, then re-render just its submenu. Runs at
    /// most once per provider unless `force`d by the Retry row.
    private func resolveProvider(
        _ kind: PetAssistant.AgentChoice.Kind, force: Bool = false
    ) {
        guard force || discovered[kind] == nil else { return }
        discovered[kind] = .loading
        Task { @MainActor [weak self] in
            let models = await ModelDiscovery.shared.models(for: kind)
            guard let self else { return }
            self.discovered[kind] = models
            self.refreshProviderSubmenu(kind)
        }
    }

    /// Repaint one provider's submenu in place, so an answer arriving while
    /// the menu is open fills that submenu without rebuilding the whole chip.
    private func refreshProviderSubmenu(_ kind: PetAssistant.AgentChoice.Kind) {
        guard let submenu = modelButton.menu?.items
            .compactMap(\.submenu)
            .first(where: { $0.identifier?.rawValue == kind.configuredProviderKey })
        else { return }
        populate(submenu, for: kind)
    }

    private func refreshModelChip() {
        let choice = selectedChoice
        modelButton.image = PetAssistantPanelView.providerImage(for: choice)
        modelButton.title = " \(choice.displayName) ▾ "
        modelButton.toolTip = "Model: \(choice.displayName)"
        modelButton.menu = makeModelMenu()
        // Every path that changes the model lands here — menu click, agent
        // `selectModel(named:)`, or init — so the effort chip follows from one
        // place rather than each caller remembering to update it.
        applyEfforts(of: choice)
    }

    /// Reasoning efforts to offer when the provider has no opinion. Codex and
    /// opencode report their own; claude, hermes and amp don't.
    private static let fallbackEfforts = ["Auto", "None", "Low", "Medium", "High"]

    /// Repopulate the effort chip from the newly selected model, so the user
    /// can't pick an effort the model rejects. Keeps the current value when it
    /// survives the switch, otherwise falls back to the model's own default.
    private func applyEfforts(of choice: PetAssistant.AgentChoice) {
        let titles = choice.supportedEfforts.isEmpty
            ? Self.fallbackEfforts
            : ["Auto"] + choice.supportedEfforts.map { $0.capitalized }
        let previous = selectedEffort
        effortPicker.menu?.removeAllItems()
        for title in titles {
            effortPicker.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        let preferred = choice.defaultEffort?.capitalized
        if titles.contains(previous) {
            effortPicker.selectItem(withTitle: previous)
        } else if let preferred, titles.contains(preferred) {
            effortPicker.selectItem(withTitle: preferred)
        } else {
            effortPicker.selectItem(at: 0)
        }
        refreshEffortChip()
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
        syncShadcnComposerState()
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
    var isShowingTypingIndicatorForTesting: Bool {
        shadcnPanel?.model.isThinking ?? (typingIndicator != nil)
    }
    var streamingTextForTesting: String? {
        shadcnPanel?.model.streamingText
    }
    var toolCardCountForTesting: Int {
        shadcnPanel?.model.tools.count ?? 0
    }
    var legacyLayoutConstraintsAreInactiveForTesting: Bool {
        shadcnPanel != nil && legacyLayoutConstraints.allSatisfy { !$0.isActive }
    }
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
    var queuedMessagesForTesting: [String] {
        shadcnPanel?.model.queued ?? queuedMessages
    }
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
    var showsFilesButtonForTesting: Bool {
        shadcnPanel?.model.hasFiles ?? !showFilesButton.isHidden
    }
    func submitForTesting(_ request: String) {
        input.string = request
        submit()
    }
    func newChatForTesting() { onNewChat?() }
    func showFilesForTesting() { onShowFiles?() }

    // MARK: - Test seams for the model menu

    /// The whole visible chip menu, for tree-wide assertions.
    var modelMenuForTesting: NSMenu { modelButton.menu ?? NSMenu() }

    /// Titles of the visible chip menu's top level (Auto + provider rows).
    var modelMenuTopLevelForTesting: [String] {
        (modelButton.menu?.items ?? [])
            .filter { !$0.isSeparatorItem }
            .map(\.title)
    }

    /// Titles inside one provider's submenu, as currently rendered.
    func modelSubmenuTitlesForTesting(
        _ kind: PetAssistant.AgentChoice.Kind
    ) -> [String] {
        submenuForTesting(kind)?.items.map(\.title) ?? []
    }

    func modelSubmenuEnabledTitlesForTesting(
        _ kind: PetAssistant.AgentChoice.Kind
    ) -> [String] {
        (submenuForTesting(kind)?.items ?? []).filter(\.isEnabled).map(\.title)
    }

    /// Force a provider into a discovery state without touching a real CLI.
    func setDiscoveredForTesting(
        _ state: ProviderModels, for kind: PetAssistant.AgentChoice.Kind
    ) {
        discovered[kind] = state
        refreshProviderSubmenu(kind)
    }

    private func submenuForTesting(_ kind: PetAssistant.AgentChoice.Kind) -> NSMenu? {
        modelButton.menu?.items
            .compactMap(\.submenu)
            .first { $0.identifier?.rawValue == kind.configuredProviderKey }
    }
}

extension PetAssistantPanelView: NSMenuDelegate {
    /// A provider submenu is opening — that is the moment to go ask its CLI.
    /// Doing it here rather than when the chip drops keeps the cost to the one
    /// provider the user actually reached for.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let key = menu.identifier?.rawValue,
              let kind = PetAssistant.AgentChoice.Kind(configuredProvider: key)
        else { return }
        resolveProvider(kind)
    }
}

/// The pet assistant. Clicking the pet opens the same full Assistant UI used
/// by the sidebar CHAT page in an independently owned popover view. Both
/// presentations share conversation and request state.
final class PetAssistant: NSObject, NSPopoverDelegate {
    typealias AskCompletion = (String, [String], String?) -> Void
    private typealias BackendAskCompletion = (
        AIOutcome, [String], String?
    ) -> Void
    typealias RequestRunner = (
        _ request: String, _ model: String, _ effort: String,
        _ completion: @escaping AskCompletion
    ) -> Void
    typealias BackendRunner = (
        _ backend: Backend,
        _ system: String,
        _ user: String,
        _ cwd: String,
        _ conversationID: String?,
        _ onPartial: ((String) -> Void)?,
        _ timeout: TimeInterval?,
        _ done: @escaping (AIOutcome) -> Void
    ) -> Void
    typealias BackendWorkScheduler = (_ work: @escaping () -> Void) -> Void
    typealias ConversationRegistrar = (
        _ backend: Backend,
        _ system: String,
        _ cwd: String,
        _ conversationID: String
    ) -> Void

    private struct PendingRequest {
        let id: UUID
        let text: String
        let model: String
        let effort: String
        let threadId: UUID
        let generation: Int
    }

    // A model-visible user item is finally capped at 10KB. Keep the current
    // request below that ceiling so the final suffix-preserving assembly can
    // retain it in full while discarding older history/context first.
    private static let maxComposerBytes = 6_000
    private static let maxBackendUserBytes = 10_000
    private static let maxTerminalContextBytes = 6_000
    private static let maxRecoveryContextBytes = 8_000
    private static let maxStatelessHistoryBytes = 6_000
    private static let maxSearchResultsBytes = 6_000
    private static let maxLastCommandBytes = 1_000

    private weak var session: TerminalSession?
    private let config: AppConfig
    private let requestRunner: RequestRunner?
    /// Lower transport seam used by focused tests while retaining the real
    /// request/context/finish pipeline. Production calls `askAI` directly.
    private let backendRunner: BackendRunner?
    /// Schedules the transport-boundary work. Production uses the global
    /// user-initiated queue; tests can hold this boundary deterministically.
    private let backendWorkScheduler: BackendWorkScheduler?
    /// Test-only observation point after the first queued-work identity check.
    /// Production leaves this nil; a second check immediately afterward
    /// closes cancellation that lands while backend input is assembled.
    private let backendStartBoundaryObserver: (() -> Void)?
    /// Registers keyed bridge state synchronously before async work is queued,
    /// so invalidation can always find and release it.
    private let conversationRegistrar: ConversationRegistrar?
    /// Observability seam for signature-transition tests. Production releases
    /// the keyed bridge conversation directly.
    private let conversationReleaser: ((String) -> Void)?
    private var popover: NSPopover?
    private weak var popoverPanel: PetAssistantPanelView?
    /// Multi-chat store. Active thread drives the visible transcript.
    private var threads: [ChatThread] = [ChatThread()]
    private var activeThreadId: UUID
    private var pendingRequests: [PendingRequest] = []
    private var requestInFlight = false
    private var activeRequestID: UUID?
    /// Thread id of the turn currently streaming (if any).
    private var streamingThreadId: UUID?
    /// Generation-qualified keyed transport id for the active backend call.
    private var activeBackendConversationID: String?
    /// Every keyed conversation synchronously registered by this assistant.
    /// Invalidation can therefore release all live epochs, not just the one
    /// currently streaming.
    private var registeredConversationIDs = Set<String>()
    /// Recovery belongs to the thread it was imported into. A new thread must
    /// never inherit a previous session's transcript.
    private var recoveryContexts: [UUID: String] = [:]
    private var invalidated = false
    private weak var sidebarPanel: PetAssistantPanelView?
    /// Extra embedded sidebar surfaces when more than one Chat pane hosts this
    /// assistant (multi-pane). Weak so closed panes drop out.
    private var extraSidebarPanels: [WeakPetAssistantPanel] = []
    /// Last known project root for file SEARCH/LIST when no terminal is attached.
    private var lastWorkspaceDirectory: String?
    /// Dynamic Channel state is resolved at the beginning of every turn. It is
    /// intentionally not cached in the provider's constant system prompt:
    /// membership, peer names, and room messages can change while a stateful
    /// provider process remains warm.
    private var collaborationContextProvider: (() -> CollaborationChatContext?)?
    /// Both sides of an accepted Chat turn are appended to the durable Channel
    /// transcript. AppDelegate supplies the room adapter; PetAssistant remains
    /// unaware of AppKit panes and persistence.
    private var collaborationMessagePublisher: ((CollaborationChatEmission) -> Void)?
    /// Publishes the provider/model selected for this turn before Channel
    /// context is resolved, so peers see the live agent provenance.
    private var collaborationIdentityPublisher: ((String?, String?) -> Void)?

    private var sidebarMessages: [AssistantChatMessage] {
        get { activeThread?.messages ?? [] }
        set {
            guard let idx = threads.firstIndex(where: { $0.id == activeThreadId }) else { return }
            threads[idx].messages = newValue
            threads[idx].updatedAt = Date()
        }
    }

    private var activeThread: ChatThread? {
        threads.first(where: { $0.id == activeThreadId })
    }

    private var lastFiles: [String] {
        get { activeThread?.lastFiles ?? [] }
        set {
            guard let idx = threadIndex(activeThreadId) else { return }
            threads[idx].lastFiles = newValue
        }
    }

    private var lastQuery: String? {
        get { activeThread?.lastQuery }
        set {
            guard let idx = threadIndex(activeThreadId) else { return }
            threads[idx].lastQuery = newValue
        }
    }

    private var conversationGeneration: Int {
        activeThread?.generation ?? 0
    }
    /// Interactive provider choices available in the composer's MODEL picker,
    /// gated by which CLIs/models this Mac actually has. Apple Foundation
    /// Models remain a background capability and are intentionally excluded.
    /// Mutable so user-typed custom models can be appended at runtime.
    var availableChoices: [AgentChoice]

    /// Hand-off: file results the user wants to see in the code-view sidebar.
    var onShowInSidePanel: ((_ paths: [String], _ query: String?) -> Void)?
    /// Compact pet-bubble notification when a background answer is ready.
    var onPetMessage: ((String) -> Void)?

    init(
        config: AppConfig,
        availableChoices: [AgentChoice]? = nil,
        requestRunner: RequestRunner? = nil,
        backendRunner: BackendRunner? = nil,
        backendWorkScheduler: BackendWorkScheduler? = nil,
        backendStartBoundaryObserver: (() -> Void)? = nil,
        conversationRegistrar: ConversationRegistrar? = nil,
        conversationReleaser: ((String) -> Void)? = nil
    ) {
        self.config = config
        self.requestRunner = requestRunner
        self.backendRunner = backendRunner
        self.backendWorkScheduler = backendWorkScheduler
        self.backendStartBoundaryObserver = backendStartBoundaryObserver
        self.conversationRegistrar = conversationRegistrar
        self.conversationReleaser = conversationReleaser
        let injected = availableChoices != nil
        var resolved = PetAssistant.interactiveChoices(
            availableChoices ?? PetAssistant.resolveChoices(config: config))
        // Re-add the user's recently typed custom models (cross-launch),
        // but only when discovering choices for real — injected test
        // choices stay exactly as given.
        if !injected {
            for recent in RecentCustomModels.load()
            where !resolved.contains(where: { $0.displayName == recent.displayName }) {
                resolved.append(recent)
            }
        }
        self.availableChoices = resolved
        // Seed one empty thread; `threads` default already has it, but the
        // active id must match that instance.
        let seed = ChatThread()
        self.threads = [seed]
        self.activeThreadId = seed.id
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
        // Interactive providers shown in the picker (Apple stays a
        // background capability), gated by whether the CLI is actually
        // installed on this Mac. The rows are seeded from the last discovery
        // run's cache (or a static table for the two providers that can't be
        // discovered), then replaced live as each provider answers.
        let interactive: [(InfinittyAIProvider, AgentChoice.Kind, String)] = [
            (.claude, .claude, "a.circle"),
            (.codex, .codex, "o.circle"),
            (.opencode, .opencode, "terminal"),
            (.hermes, .hermes, "brain"),
            (.amp, .amp, "bolt"),
        ]
        var choices: [AgentChoice] = [.auto]
        for (provider, kind, symbol) in interactive
        where ProviderDiscovery.isAvailable(provider, environment: environment) {
            for model in ModelDiscovery.seedModels(for: kind) {
                choices.append(AgentChoice(model, kind: kind, symbolName: symbol))
            }
        }
        return choices
    }

    func attach(to session: TerminalSession) {
        guard !invalidated else { return }
        self.session = session
        if let cwd = session.currentDirectory(), !cwd.isEmpty {
            lastWorkspaceDirectory = cwd
        }
    }

    func isAttached(to candidate: TerminalSession) -> Bool {
        session === candidate
    }

    func configureCollaboration(
        contextProvider: @escaping () -> CollaborationChatContext?,
        messagePublisher: @escaping (CollaborationChatEmission) -> Void,
        identityPublisher: ((String?, String?) -> Void)? = nil
    ) {
        collaborationContextProvider = contextProvider
        collaborationMessagePublisher = messagePublisher
        collaborationIdentityPublisher = identityPublisher
    }

    /// Workspace used for chat-side file listing when a terminal is absent.
    /// Prefers the live pane cwd, then the last attached project, then the
    /// process cwd (often the repo when Infinitty was launched from one).
    func workspaceDirectoryForChat() -> String {
        if let cwd = session?.currentDirectory(), !cwd.isEmpty {
            lastWorkspaceDirectory = cwd
            return cwd
        }
        if let last = lastWorkspaceDirectory, !last.isEmpty {
            return last
        }
        let processCwd = FileManager.default.currentDirectoryPath
        if !processCwd.isEmpty, processCwd != "/" {
            return processCwd
        }
        return NSHomeDirectory()
    }

    /// Binds a chat-only agent to an explicit checkout/worktree without
    /// manufacturing a terminal pane. The provisioning layer validates and
    /// creates the directory before this is called.
    func setWorkspaceDirectory(_ path: String) {
        let value = path.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !invalidated, !value.isEmpty else { return }
        lastWorkspaceDirectory = value
    }

    /// Versioned app-control projection. This intentionally exposes the
    /// transcript already visible in this Chat and no backend secrets.
    func controlState() -> AssistantChatControlState {
        AssistantChatControlState(
            activeThreadID: activeThreadId.uuidString.lowercased(),
            threads: threads.map { thread in
                AssistantChatControlState.Thread(
                    id: thread.id.uuidString.lowercased(),
                    title: thread.title,
                    messages: thread.messages.map {
                        AssistantChatControlState.Message(
                            role: $0.role,
                            text: $0.text,
                            createdAt: $0.createdAt,
                            tokenCount: $0.tokenCount)
                    },
                    updatedAt: thread.updatedAt)
            },
            queuedRequests: pendingRequests.map(\.text),
            requestInFlight: requestInFlight,
            streamingThreadID:
                streamingThreadId?.uuidString.lowercased(),
            workspaceDirectory: workspaceDirectoryForChat())
    }

    func submitFromControl(
        _ request: String,
        model: String = "Auto",
        effort: String = "Auto"
    ) {
        submitFromPanel(request, model: model, effort: effort)
    }

    @discardableResult
    func selectThreadFromControl(_ id: String) -> Bool {
        guard let threadID = UUID(uuidString: id),
              threads.contains(where: { $0.id == threadID })
        else { return false }
        selectThread(threadID)
        return true
    }

    /// Panel for embedding in a Chat leaf. Never reuses a panel that is already
    /// in another host — doing so would empty the first Chat pane (black).
    func makeSidebarPanelView() -> PetAssistantPanelView {
        pruneExtraSidebarPanels()
        if let sidebarPanel, sidebarPanel.superview == nil {
            return sidebarPanel
        }
        let panel = makePanelView(presentation: .sidebar)
        if sidebarPanel == nil {
            sidebarPanel = panel
        } else {
            extraSidebarPanels.append(WeakPetAssistantPanel(panel))
        }
        return panel
    }

    private func pruneExtraSidebarPanels() {
        extraSidebarPanels.removeAll { $0.panel == nil }
    }

    private var allSidebarPanels: [PetAssistantPanelView] {
        pruneExtraSidebarPanels()
        var panels: [PetAssistantPanelView] = []
        if let sidebarPanel { panels.append(sidebarPanel) }
        panels.append(contentsOf: extraSidebarPanels.compactMap(\.panel))
        return panels
    }

    private func makePanelView(
        presentation: PetAssistantPanelView.Presentation
    ) -> PetAssistantPanelView {
        let panel = PetAssistantPanelView(
            presentation: presentation, config: config,
            choices: availableChoices)
        panel.setToolEventScopeID(backendConversationID(for: activeThreadId))
        panel.setMessages(sidebarMessages)
        panel.setQueuedMessages(
            pendingRequests
                .filter { $0.threadId == activeThreadId }
                .map(\.text))
        panel.setHasFiles(!lastFiles.isEmpty)
        panel.onSubmit = { [weak self] request, model, effort in
            self?.submitFromPanel(request, model: model, effort: effort)
        }
        panel.onShowFiles = { [weak self] in
            guard let self, !self.lastFiles.isEmpty else { return }
            self.onShowInSidePanel?(self.lastFiles, self.lastQuery)
        }
        panel.onNewChat = { [weak self] in self?.startNewChat() }
        panel.onSelectThread = { [weak self] id in
            guard let uuid = UUID(uuidString: id) else { return }
            self?.selectThread(uuid)
        }
        return panel
    }

    /// Opens a blank thread. The previous transcript stays in the switcher.
    /// Pending/in-flight turns on the thread we leave are cancelled (stale
    /// completions drop); messages already shown remain. An empty active
    /// thread is reused so we don't pile up blanks.
    func startNewChat() {
        guard !invalidated else { return }
        var shouldResumeOtherThreads = false
        defer {
            if shouldResumeOtherThreads {
                processNextRequest()
            }
        }
        if let active = activeThread {
            bumpGeneration(of: active.id)
            shouldResumeOtherThreads = dropPending(for: active.id)
            if active.messages.isEmpty {
                lastFiles.removeAll()
                lastQuery = nil
                recoveryContexts.removeValue(forKey: active.id)
                setPanelsThinking(false)
                setPanelsStreaming(nil)
                updatePanels()
                return
            }
        }
        let fresh = ChatThread()
        threads.insert(fresh, at: 0)
        activeThreadId = fresh.id
        lastFiles.removeAll()
        lastQuery = nil
        setPanelsThinking(false)
        setPanelsStreaming(nil)
        updatePanels()
    }

    func selectThread(_ id: UUID) {
        guard threads.contains(where: { $0.id == id }) else { return }
        guard id != activeThreadId else { return }
        activeThreadId = id
        // Only show thinking/stream chrome for the thread that's actually live.
        let live = streamingThreadId == id && requestInFlight
        setPanelsThinking(live, label: live ? "Thinking" : nil)
        if !live { setPanelsStreaming(nil) }
        updatePanels()
    }

    private func bumpGeneration(of id: UUID) {
        guard let idx = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[idx].generation += 1
    }

    @discardableResult
    private func dropPending(for id: UUID) -> Bool {
        let hadPendingRequest = pendingRequests.contains { $0.threadId == id }
        pendingRequests.removeAll { $0.threadId == id }
        let cancelledActiveRequest = streamingThreadId == id
        if hadPendingRequest || cancelledActiveRequest {
            let oldConversationID = cancelledActiveRequest
                ? (activeBackendConversationID ?? backendConversationID(for: id))
                : backendConversationID(for: id)
            // Cancellation means the next turn must bootstrap visible history,
            // so retain no keyed transport state. Release also tombstones the
            // id, preventing already-queued bridge work from recreating it.
            releaseRegisteredBackendConversation(oldConversationID)
            if let idx = threadIndex(id) {
                threads[idx].backendEpoch &+= 1
                threads[idx].needsBackendBootstrap = true
            }
        }
        if cancelledActiveRequest {
            streamingThreadId = nil
            activeBackendConversationID = nil
            activeRequestID = nil
            requestInFlight = false
        }
        return cancelledActiveRequest
    }

    private func threadIndex(_ id: UUID) -> Int? {
        threads.firstIndex(where: { $0.id == id })
    }

    private static func backendConversationID(
        threadID: UUID, epoch: Int
    ) -> String {
        AgentConversationIdentity.transportID(threadID: threadID, epoch: epoch)
    }

    private func backendConversationID(for threadID: UUID) -> String {
        let epoch = threads.first(where: { $0.id == threadID })?.backendEpoch ?? 0
        return Self.backendConversationID(threadID: threadID, epoch: epoch)
    }

    private func appendMessage(
        _ message: AssistantChatMessage, to threadId: UUID, titleFromUser: Bool = false
    ) {
        guard let idx = threadIndex(threadId) else { return }
        threads[idx].messages.append(message)
        threads[idx].updatedAt = Date()
        if titleFromUser, threads[idx].title == "New chat", message.role == "You" {
            threads[idx].title = ChatThread.title(fromFirstUserMessage: message.text)
        }
    }

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
        startNewChat()
        var imported: [AssistantChatMessage] = []
        if let transcriptPath {
            imported = Self.recentConversation(at: transcriptPath)
            sidebarMessages = imported
            if let firstUser = imported.first(where: { $0.role == "You" }),
               let idx = threadIndex(activeThreadId) {
                threads[idx].title = ChatThread.title(fromFirstUserMessage: firstUser.text)
            }
        }
        let importedContext = imported.map {
            "\($0.role): \($0.text)"
        }.joined(separator: "\n\n")
        recoveryContexts[activeThreadId] = importedContext.isEmpty
            ? context
            : context + "\n--- recent recovered turns ---\n" + importedContext
        if sidebarMessages.isEmpty {
            sidebarMessages = [AssistantChatMessage(
                role: "Assistant",
                text: "Session context recovered. Continue below when you're ready.")]
        }
        for panel in allVisiblePanels {
            _ = panel.selectProvider(provider)
        }
        updatePanels()
    }

    private func updatePanels() {
        let activePending = pendingRequests
            .filter { $0.threadId == activeThreadId }
            .map(\.text)
        let threadSummaries = threads.map {
            (id: $0.id.uuidString, title: $0.title)
        }
        let activeId = activeThreadId.uuidString
        let activeBackendID = backendConversationID(for: activeThreadId)
        for panel in allVisiblePanels {
            panel.setToolEventScopeID(activeBackendID)
            panel.setMessages(sidebarMessages)
            panel.setQueuedMessages(activePending)
            panel.setHasFiles(!lastFiles.isEmpty)
            panel.setThreads(threadSummaries, activeId: activeId)
        }
    }

    private var allVisiblePanels: [PetAssistantPanelView] {
        var panels = allSidebarPanels
        if let popoverPanel { panels.append(popoverPanel) }
        return panels
    }

    private func setPanelsThinking(_ thinking: Bool, label: String? = nil) {
        for panel in allVisiblePanels {
            panel.setThinking(thinking, label: label)
        }
    }

    /// Apply an explicit stream-state transition. Request partials use the
    /// identity-scoped overload below.
    private func setPanelsStreaming(_ text: String?) {
        let apply = { [weak self] in
            guard let self else { return }
            for panel in self.allVisiblePanels {
                panel.setStreamingText(text)
            }
        }
        if Thread.isMainThread { apply() }
        else { DispatchQueue.main.async(execute: apply) }
    }

    /// A bridge may emit tokens after cancellation. Only the exact active
    /// request, still on its original thread generation, may paint the visible
    /// live tail.
    private func setPanelsStreaming(_ text: String, for request: PendingRequest) {
        let apply = { [weak self] in
            guard let self,
                  self.activeRequestID == request.id,
                  self.requestInFlight,
                  self.streamingThreadId == request.threadId,
                  self.activeThreadId == request.threadId,
                  self.threads.first(where: { $0.id == request.threadId })?
                    .generation == request.generation
            else { return }
            for panel in self.allVisiblePanels {
                panel.setStreamingText(text)
            }
        }
        if Thread.isMainThread { apply() }
        else { DispatchQueue.main.async(execute: apply) }
    }

    /// QA seam: submits a request as though it came from the composer, so a
    /// screenshot pass can drive a real turn.
    func submitForQA(_ request: String) {
        submitFromControl(request)
    }

    private func submitFromPanel(_ request: String, model: String, effort: String = "Auto") {
        guard !invalidated else { return }
        let request = Self.bounded(
            request.trimmingCharacters(in: .whitespacesAndNewlines),
            to: Self.maxComposerBytes)
        guard !request.isEmpty else { return }
        let threadId = activeThreadId
        let thread = threads.first(where: { $0.id == threadId })
        let generation = thread?.generation ?? 0
        pendingRequests.append(PendingRequest(
            id: UUID(), text: request, model: model, effort: effort,
            threadId: threadId, generation: generation))
        updatePanels()
        processNextRequest()
    }

    private func processNextRequest() {
        guard !invalidated, !requestInFlight else { return }
        // Drop stale requests whose thread generation has moved on.
        pendingRequests.removeAll { req in
            guard let thread = threads.first(where: { $0.id == req.threadId }) else {
                return true
            }
            return req.generation != thread.generation
        }
        guard !pendingRequests.isEmpty else {
            streamingThreadId = nil
            setPanelsThinking(false)
            updatePanels()
            return
        }

        let request = pendingRequests.removeFirst()
        let conversationID = backendConversationID(for: request.threadId)
        let priorHistory = statelessHistory(for: request.threadId)
        let backendRequest: String
        if let recoveryContext = recoveryContexts.removeValue(forKey: request.threadId) {
            backendRequest = """
            --- recovered session context ---
            \(Self.bounded(recoveryContext, to: Self.maxRecoveryContextBytes))
            --- new user request ---
            \(request.text)
            """
        } else {
            backendRequest = request.text
        }
        requestInFlight = true
        activeRequestID = request.id
        streamingThreadId = request.threadId
        activeBackendConversationID = conversationID
        appendMessage(
            AssistantChatMessage(role: "You", text: request.text),
            to: request.threadId, titleFromUser: true)
        collaborationMessagePublisher?(CollaborationChatEmission(
            kind: .humanPrompt,
            text: request.text,
            threadID: request.threadId.uuidString.lowercased()))
        updatePanels()
        // Only the active thread shows the thinking chrome.
        if request.threadId == activeThreadId {
            setPanelsThinking(
                true,
                label: request.model.hasPrefix("Auto")
                    ? "Thinking" : "\(request.model) · thinking")
        }

        let completion: AskCompletion = { [weak self] answer, files, query in
            guard let self, !self.invalidated else { return }
            let finish = {
                self.completeRequest(
                    request,
                    outcome: .text(answer),
                    files: files,
                    query: query)
            }
            if Thread.isMainThread { finish() }
            else { DispatchQueue.main.async(execute: finish) }
        }
        if let requestRunner {
            requestRunner(backendRequest, request.model, request.effort, completion)
        } else {
            let backendCompletion: BackendAskCompletion = {
                [weak self] outcome, files, query in
                guard let self, !self.invalidated else { return }
                let finish = {
                    self.completeRequest(
                        request,
                        outcome: outcome,
                        files: files,
                        query: query)
                }
                if Thread.isMainThread { finish() }
                else { DispatchQueue.main.async(execute: finish) }
            }
            ask(
                backendRequest, model: request.model, effort: request.effort,
                priorHistory: priorHistory, conversationID: conversationID,
                requestIdentity: request,
                completion: backendCompletion)
        }
    }

    private func statelessHistory(for threadId: UUID) -> String {
        guard let thread = threads.first(where: { $0.id == threadId }) else { return "" }
        var selected: [String] = []
        var remaining = Self.maxStatelessHistoryBytes
        for message in thread.messages.reversed() {
            let line = "\(message.role): \(message.text)"
            guard remaining > 0 else { break }
            let bounded = Self.boundedSuffix(line, to: remaining)
            selected.append(bounded)
            remaining -= bounded.utf8.count + 2
        }
        return selected.reversed().joined(separator: "\n\n")
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

    private static func bounded(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.utf8.count > limit else { return text }
        let marker = "\n…[truncated]"
        let keep = max(limit - marker.utf8.count, 0)
        var result = ""
        var bytes = 0
        for character in text {
            let next = String(character)
            guard bytes + next.utf8.count <= keep else { break }
            result.append(character)
            bytes += next.utf8.count
        }
        return result + marker
    }

    private static func boundedSuffix(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.utf8.count > limit else { return text }
        let marker = "[truncated]…\n"
        let keep = max(limit - marker.utf8.count, 0)
        var reversed: [Character] = []
        var bytes = 0
        for character in text.reversed() {
            let size = String(character).utf8.count
            guard bytes + size <= keep else { break }
            reversed.append(character)
            bytes += size
        }
        return marker + String(reversed.reversed())
    }

    private func completeRequest(
        _ request: PendingRequest, outcome: AIOutcome,
        files: [String], query: String?
    ) {
        // A cancelled request may finish after a new thread has already
        // started another turn. It must not clear that newer turn's state.
        guard activeRequestID == request.id else { return }
        activeRequestID = nil
        requestInFlight = false
        activeBackendConversationID = nil
        if streamingThreadId == request.threadId {
            streamingThreadId = nil
        }
        let stillCurrent = threads.first(where: { $0.id == request.threadId })
            .map { $0.generation == request.generation } ?? false
        guard stillCurrent else {
            processNextRequest()
            return
        }

        // Every visible/UI finish effect is downstream of both identity and
        // generation acceptance. A late callback cannot stop a newer spinner,
        // clear its stream, publish files, or raise a stale pet notification.
        session?.petAnimator?.stopThinking()
        if let idx = threadIndex(request.threadId) {
            threads[idx].lastFiles = files
            threads[idx].lastQuery = query
        }
        let answer = Self.displayText(for: outcome)
        let isSuccessfulAgentResponse: Bool
        if case .text = outcome {
            isSuccessfulAgentResponse = true
        } else {
            isSuccessfulAgentResponse = false
        }
        appendMessage(
            AssistantChatMessage(
                role: isSuccessfulAgentResponse ? "Assistant" : "System",
                text: answer,
                tokenCount: AssistantChatMessage.approximateTokenCount(for: answer)),
            to: request.threadId)
        if isSuccessfulAgentResponse {
            collaborationMessagePublisher?(CollaborationChatEmission(
                kind: .agentResponse,
                text: answer,
                threadID: request.threadId.uuidString.lowercased()))
        } else {
            collaborationMessagePublisher?(CollaborationChatEmission(
                kind: .runtimeFailure,
                text: answer,
                threadID: request.threadId.uuidString.lowercased()))
        }
        // Move completed thread to the top of the switcher.
        if let idx = threadIndex(request.threadId), idx > 0 {
            let thread = threads.remove(at: idx)
            threads.insert(thread, at: 0)
        }
        updatePanels()
        if request.threadId == activeThreadId {
            setPanelsThinking(false)
            setPanelsStreaming(nil)
        }
        // Pet bubble is for answers you would otherwise miss. If the chat
        // surface is already on screen, the transcript is the notification.
        if !isChatSurfaceVisible {
            onPetMessage?(answer)
        }
        processNextRequest()
    }

    func detach() {
        closePopover()
        session = nil
    }

    /// Stop this assistant's queued/active conversation work. Backends may
    /// still deliver a late transport callback, but request identity and
    /// generation guards make that callback inert.
    func cancelConversationWork() {
        let pendingThreadIDs = Set(pendingRequests.map(\.threadId))
        var conversationIDs = registeredConversationIDs
        if let activeBackendConversationID {
            conversationIDs.insert(activeBackendConversationID)
        }
        let affectedThreadIDs = Set(threads.compactMap { thread -> UUID? in
            let id = Self.backendConversationID(
                threadID: thread.id, epoch: thread.backendEpoch)
            return conversationIDs.contains(id)
                || pendingThreadIDs.contains(thread.id)
                || streamingThreadId == thread.id
                ? thread.id : nil
        })
        for conversationID in conversationIDs {
            // This path marks affected threads bootstrap-needed below. Discard
            // and tombstone keyed state rather than retaining transport history
            // that the retry would then duplicate.
            releaseRegisteredBackendConversation(conversationID)
        }
        for index in threads.indices {
            threads[index].generation += 1
            if affectedThreadIDs.contains(threads[index].id) {
                threads[index].backendEpoch &+= 1
                threads[index].needsBackendBootstrap = true
            }
        }
        pendingRequests.removeAll()
        activeRequestID = nil
        requestInFlight = false
        streamingThreadId = nil
        activeBackendConversationID = nil
        recoveryContexts.removeAll()
        session?.petAnimator?.stopThinking()
        setPanelsThinking(false)
        setPanelsStreaming(nil)
        updatePanels()
    }

    /// Final lifecycle endpoint for a Chat pane that has no remaining pet or
    /// UI owner. Closed conversations cannot publish UI callbacks afterward.
    func invalidate() {
        guard !invalidated else { return }
        // Close the async backend-start boundary before cancellation/release.
        // A queued work item observes this tombstone and never invokes a
        // transport after its keyed context has been released.
        invalidated = true
        cancelConversationWork()
        closePopover()
        session = nil
        onShowInSidePanel = nil
        onPetMessage = nil
        collaborationContextProvider = nil
        collaborationMessagePublisher = nil
        collaborationIdentityPublisher = nil
    }

    // MARK: - input bubble

    func presentInput(anchorRect: NSRect, in view: NSView) {
        closePopover()
        prewarm()
        // Tall enough for empty-state + compact ShadKit composer (chips row)
        // without the footer being clipped by the popover chrome.
        let contentSize = NSSize(width: 400, height: 500)
        let panel = makePanelView(presentation: .popover)
        panel.frame = NSRect(origin: .zero, size: contentSize)
        panel.translatesAutoresizingMaskIntoConstraints = true
        panel.autoresizingMask = [.width, .height]
        panel.clipsToBounds = false
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
        // NSPopover wraps content; keep the wrapper from re-clipping the
        // composer after presentation.
        if let popoverView = pop.contentViewController?.view {
            popoverView.clipsToBounds = false
            popoverView.wantsLayer = true
            popoverView.layer?.masksToBounds = false
        }
        DispatchQueue.main.async { [weak panel] in panel?.focusInput() }
    }


    /// Dismiss the floating pet chat. Used when the sidebar Chat pane is
    /// already open so we never stack both surfaces.
    func dismissPopover() { closePopover() }

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
    You are infinitty — an agentic coding assistant inside a terminal app. You \
    can drive a visible terminal when one is attached, and you can also answer \
    entirely from chat when no terminal exists.

    CHAT WITHOUT A TERMINAL (context will say "no active terminal"):
    - Do NOT refuse. Do NOT open a terminal, new tab, or pane just to list \
    files, search the project, or answer a question.
    - File listings and project lookups stay in chat: reply with EXACTLY one \
    line "SEARCH: <keywords>" (or "SEARCH: *" for a broad listing under the \
    workspace cwd) and nothing else; you will get matching paths and then \
    compose the final answer in chat.
    - Only call infinitty_new_tab / infinitty_run / infinitty_send when the user \
    explicitly wants shell work or a program launched in a terminal.

    WHEN A TERMINAL IS ATTACHED you have infinitty tools (infinitty_list_panes, \
    infinitty_run, infinitty_send, infinitty_screen, infinitty_history, \
    infinitty_last_output, infinitty_exit_code, infinitty_new_tab, \
        infinitty_split, infinitty_focus, infinitty_close, infinitty_surface, \
        infinitty_todos, infinitty_channels, infinitty_channel_link, \
        infinitty_channel_apply, infinitty_channel_self, infinitty_channel_post). To SHOW the user something rich — a plan, a doc, a \
    rendered preview, a small UI — use infinitty_surface (markdown, HTML, or a \
    URL; target=split for a side panel at a ratio like 0.25, target=window for \
    a standalone doc). For multi-step work, keep infinitty_todos updated so the \
    pane header shows your progress. When the user asks you to DO something in \
    the terminal — run a command, type text, open a tab, launch a program — \
    you MUST call the matching tool. Never describe an action as done unless \
    the tool call returned success. Never invent output, exit codes, or state: \
    read them with infinitty_screen / infinitty_last_output / \
    infinitty_exit_code and report exactly what came back. If a tool returns an \
    error, say so plainly.

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
    (infinitty_new_tab) only if asked or no pane exists and they want a shell. \
    Act in ONE or two tool calls — don't retry with variations.

    For plain questions that need no terminal action, answer concisely in a few \
    sentences of plain text (no markdown). If answering requires finding or \
    listing files in the project, reply with EXACTLY one line \
    "SEARCH: <filename or path keywords>" or "SEARCH: *" and nothing else; you \
    will receive the matching files to compose the final answer in chat.

    CHANNEL AWARENESS:
    - A turn may contain an "ACTIVE INFINITTY CHANNEL" section. When present, \
    it is authoritative live app state: you are connected to that Channel as \
    the named participant and the listed peer endpoints are connected with you.
    - Never describe yourself as a solo chat when an active Channel section is \
    present. If asked about the connection, state your participant name, the \
    Channel name, and the exact connected peer names.
    - Read recent Channel messages as shared collaboration context and refer to \
    other participants by their displayed names.
    """

    private func ask(
        _ request: String, model: String = "Auto · Best available",
        effort: String = "Auto",
        priorHistory: String = "",
        conversationID: String,
        requestIdentity: PendingRequest,
        completion: BackendAskCompletion? = nil
    ) {
        var conversationID = conversationID
        // A Chat/Browser tab is allowed to outlive its final terminal pane.
        // File listings and Q&A still run in chat via workspace SEARCH — never
        // force-open a terminal for that.
        let activeSession = session
        activeSession?.petAnimator?.startThinking()
        let backend = resolveBackend(forSelectedTitle: model)
        let provenance = Self.collaborationProvenance(for: backend)
        collaborationIdentityPublisher?(provenance.provider, provenance.model)
        // Keep the system prompt CONSTANT: the CLI bridges pin --system-prompt
        // at process launch, so folding effort in here forced a full cold
        // respawn on every effort change (and invalidated the prewarm). The
        // effort directive rides in the per-turn user message instead, so the
        // warm process is reused across Auto/Low/Medium/High.
        let system = Self.systemPrompt
        let effortNote = Self.effortDirective(effort)
        let runCwd = workspaceDirectoryForChat()
        let activeCollaborationContext = collaborationContextProvider?()
        let sessionSignature = Self.backendSessionSignature(for: backend, cwd: runCwd)
        let previousSignature: String?
        let needsBackendBootstrap: Bool
        if let idx = threadIndex(requestIdentity.threadId) {
            previousSignature = threads[idx].backendSessionSignature
            needsBackendBootstrap = threads[idx].needsBackendBootstrap
            threads[idx].backendSessionSignature = sessionSignature
            threads[idx].needsBackendBootstrap = false
        } else {
            previousSignature = nil
            needsBackendBootstrap = false
        }
        let statefulSessionChanged = Self.isStateful(backend)
            && (needsBackendBootstrap
                || (previousSignature != nil && previousSignature != sessionSignature))
        let shouldReleaseStatefulConversation = Self.isStateful(backend)
            && registeredConversationIDs.contains(conversationID)
            && (needsBackendBootstrap
                || (previousSignature != nil && previousSignature != sessionSignature))
        if shouldReleaseStatefulConversation {
            // One signature owns one keyed bridge lifecycle. Tear down any old
            // provider/model/workspace state before seeding visible history so
            // returning to an earlier provider cannot duplicate retained turns.
            releaseRegisteredBackendConversation(conversationID)
            conversationID = advanceBackendEpoch(for: requestIdentity)
        }
        let explicitHistory: String
        switch backend {
        case .command, .openai, .amp, .foundation:
            explicitHistory = priorHistory
        case .codex, .claude, .opencode, .hermes:
            // These bridges retain turns while the provider/model/workspace
            // signature is stable. A changed signature starts fresh, so seed
            // that first turn from the bounded UI transcript exactly once.
            explicitHistory = statefulSessionChanged ? priorHistory : ""
        case .none:
            explicitHistory = ""
        }
        if Self.isStateful(backend)
            && (previousSignature == nil || statefulSessionChanged) {
            registerBackendConversation(
                backend: backend, system: system, cwd: runCwd,
                conversationID: conversationID)
        }
        let requestWithHistory = explicitHistory.isEmpty
            ? request
            : """
              --- prior chat turns ---
              \(explicitHistory)
              --- current user request ---
              \(request)
              """

        let backendWork = { [weak self] in
            guard let self,
                  self.backendStartIsCurrent(
                    requestIdentity, conversationID: conversationID)
            else { return }
            let turnTimeout = self.config.aiTurnTimeout
            let onPartial: (String) -> Void = { [weak self] text in
                self?.setPanelsStreaming(text, for: requestIdentity)
            }
            let context: String
            if let activeSession {
                let terminalHistory = Self.boundedSuffix(
                    activeSession.terminal.historyText(lines: 60),
                    to: Self.maxTerminalContextBytes)
                let lastCommand = Self.boundedSuffix(
                    activeSession.terminal.lastCommandLine() ?? "(unknown)",
                    to: Self.maxLastCommandBytes)
                context = """
                cwd: \(runCwd)
                last command: \(lastCommand)
                --- recent terminal output ---
                \(terminalHistory)
                """
            } else {
                context = """
                cwd: \(runCwd)
                last command: (no active terminal)
                --- chat-only session ---
                There is no attached terminal pane. Answer in chat. For project \
                files use SEARCH: keywords or SEARCH: * — do not open a terminal, \
                new tab, or shell just to list or find files. Do not claim \
                terminal output. Browser tools remain available for page work.
                """
            }
            let requestItem = requestWithHistory
                + (effortNote.isEmpty ? "" : "\n" + effortNote)
            let user = Self.composedBackendUser(
                for: backend,
                system: system,
                baseContext: context,
                collaborationContext: activeCollaborationContext,
                request: requestItem)
            let initialPayload = Self.boundedBackendPayload(
                for: backend, system: system, user: user)

            self.backendStartBoundaryObserver?()
            guard self.backendStartIsCurrent(
                requestIdentity, conversationID: conversationID)
            else { return }
            self.runBackend(
                backend: backend,
                system: initialPayload.system,
                user: initialPayload.user,
                cwd: runCwd,
                conversationID: conversationID,
                onPartial: onPartial, timeout: turnTimeout) { outcome in
                if Self.isStateful(backend), case .failure = outcome {
                    self.markBackendBootstrapNeeded(after: requestIdentity)
                }
                // Always resolve against runCwd — previously `let cwd` required
                // a live terminal, so SEARCH: was dropped in chat-only mode.
                if let query = Self.parseSearchDirective(Self.replyText(for: outcome)) {
                    let all = CodeSearch.listFilesSync(root: runCwd)
                    let matches = CodeSearch.filter(all, query: query, limit: 50)
                    let followUpBudget = Self.backendUserBudget(
                        for: backend, system: system)
                    let searchResultContext = Self.searchResultContext(
                        root: runCwd, query: query, matches: matches,
                        userBudget: followUpBudget)
                    let followUp: String
                    if Self.isStateful(backend) {
                        // This bridge retained the initial user turn. Repeating
                        // it here duplicates both bootstrap history and request.
                        followUp = searchResultContext
                    } else {
                        // Stateless transports need the request again, but the
                        // SEARCH result is the new information. Reserve its
                        // complete bounded section at the retained end.
                        followUp = Self.composedBackendUser(
                            for: backend,
                            system: system,
                            baseContext: context,
                            collaborationContext: activeCollaborationContext,
                            request: requestWithHistory
                                + "\n" + searchResultContext)
                    }
                    let followUpPayload = Self.boundedBackendPayload(
                        for: backend, system: system, user: followUp)
                    // SEARCH runs between two transports. New Chat, explicit
                    // cancellation, or invalidation during the file lookup
                    // must make this second turn inert.
                    guard self.backendStartIsCurrent(
                        requestIdentity, conversationID: conversationID)
                    else { return }
                    self.runBackend(
                        backend: backend,
                        system: followUpPayload.system,
                        user: followUpPayload.user,
                        cwd: runCwd,
                        conversationID: conversationID,
                        onPartial: onPartial, timeout: turnTimeout) { final in
                        if Self.isStateful(backend), case .failure = final {
                            self.markBackendBootstrapNeeded(after: requestIdentity)
                        }
                        self.finish(
                            outcome: final, files: matches, query: query,
                            completion: completion)
                    }
                } else {
                    self.finish(
                        outcome: outcome,
                        files: [], query: nil, completion: completion)
                }
            }
        }
        scheduleBackendWork(backendWork)
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
        enum Kind: Equatable { case auto, claude, codex, opencode, hermes, amp, apple }
        let kind: Kind
        /// Exact API/CLI model id (e.g. "claude-sonnet-5"). Nil for Auto/Apple.
        let modelID: String?
        /// Display label shown in the picker (e.g. "Claude Sonnet 5").
        let displayName: String
        /// SF Symbol used as the provider glyph beside the label.
        let symbolName: String
        /// Reasoning efforts this specific model accepts, as reported by its
        /// provider. Empty means "provider didn't say", and the effort chip
        /// keeps its fixed list.
        var supportedEfforts: [String] = []
        /// The provider's own default effort for this model, preselected when
        /// the model is picked.
        var defaultEffort: String?

        static let auto = AgentChoice(
            kind: .auto, modelID: nil,
            displayName: "Auto", symbolName: "sparkles")

        /// Spelled out because the discovery initializer below suppresses the
        /// synthesized memberwise one.
        init(
            kind: Kind, modelID: String?, displayName: String, symbolName: String,
            supportedEfforts: [String] = [], defaultEffort: String? = nil
        ) {
            self.kind = kind
            self.modelID = modelID
            self.displayName = displayName
            self.symbolName = symbolName
            self.supportedEfforts = supportedEfforts
            self.defaultEffort = defaultEffort
        }

        /// Build a selectable choice from a discovered model. The label keeps
        /// the provider name so the flat picker (and agent-driven
        /// `selectModel(named:)`) stays unambiguous across providers that ship
        /// same-named models.
        init(_ model: DiscoveredModel, kind: Kind, symbolName: String) {
            self.kind = kind
            // An empty id is the "whatever the agent is configured for" row;
            // nil here is what makes `resolveBackend` fall through to config.
            self.modelID = model.id.isEmpty ? nil : model.id
            self.displayName = "\(kind.providerLabel) · \(model.name)"
            self.symbolName = symbolName
            self.supportedEfforts = model.efforts
            self.defaultEffort = model.defaultEffort
        }

        var configuredProvider: String {
            switch kind {
            case .auto: return "auto"
            case .claude: return "claude"
            case .codex: return "codex"
            case .opencode: return "opencode"
            case .hermes: return "hermes"
            case .amp: return "amp"
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
            case .opencode: return NSColor(calibratedRed: 0.35, green: 0.72, blue: 0.62, alpha: 1)
            case .hermes: return NSColor(calibratedRed: 0.62, green: 0.45, blue: 0.9, alpha: 1)
            case .amp: return NSColor(calibratedRed: 0.95, green: 0.4, blue: 0.45, alpha: 1)
            case .apple: return NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.64, alpha: 1)
            }
        }
    }

    enum Backend: Equatable {
        case none
        case command(String)
        case openai(base: String, key: String, model: String)
        case codex(model: String?)
        case claude(model: String?)
        case opencode(model: String?)
        case hermes(model: String?)
        case amp(model: String?)
        case foundation
    }

    private static func isStateful(_ backend: Backend) -> Bool {
        switch backend {
        case .codex, .claude, .opencode, .hermes:
            return true
        case .none, .command, .openai, .amp, .foundation:
            return false
        }
    }

    private static func collaborationProvenance(
        for backend: Backend
    ) -> (provider: String?, model: String?) {
        switch backend {
        case .none:
            return (nil, nil)
        case .command:
            return ("command", nil)
        case .openai(_, _, let model):
            return ("openai", model)
        case .codex(let model):
            return ("codex", model)
        case .claude(let model):
            return ("claude", model)
        case .opencode(let model):
            return ("opencode", model)
        case .hermes(let model):
            return ("hermes", model)
        case .amp(let model):
            return ("amp", model)
        case .foundation:
            return ("apple-foundation-models", nil)
        }
    }

    private static func combinesSystemAndUser(_ backend: Backend) -> Bool {
        switch backend {
        case .command, .codex, .opencode, .hermes, .amp:
            return true
        case .none, .openai, .claude, .foundation:
            return false
        }
    }

    private static func backendUserBudget(
        for backend: Backend, system: String
    ) -> Int {
        guard combinesSystemAndUser(backend) else {
            return maxBackendUserBytes
        }
        let separatorBytes = 2
        let systemBytes: Int
        if system.utf8.count + separatorBytes < maxBackendUserBytes {
            systemBytes = system.utf8.count
        } else {
            systemBytes = bounded(
                system, to: max((maxBackendUserBytes - separatorBytes) / 2, 0))
                .utf8.count
        }
        return max(maxBackendUserBytes - systemBytes - separatorBytes, 0)
    }

    /// Composes the provider-visible user item by reserving complete space for
    /// the active Channel block and newest request before admitting older
    /// terminal/history context. Combined-system bridges therefore cannot
    /// suffix-truncate the identity that tells an agent which room it is in.
    private static func composedBackendUser(
        for backend: Backend,
        system: String,
        baseContext: String,
        collaborationContext: CollaborationChatContext?,
        request: String
    ) -> String {
        let budget = backendUserBudget(for: backend, system: system)
        let channel = collaborationContext?.modelContext() ?? ""
        let requestHeader = "--- user request ---\n"
        let separators = channel.isEmpty ? 1 : 2
        let fixedBytes = channel.utf8.count
            + requestHeader.utf8.count + separators
        let requestBudget = max(budget - fixedBytes, 0)
        let boundedRequest = boundedSuffix(request, to: requestBudget)
        let retainedBytes = fixedBytes + boundedRequest.utf8.count
        let baseBudget = max(budget - retainedBytes, 0)
        let boundedBase = boundedSuffix(baseContext, to: baseBudget)

        var sections: [String] = []
        if !boundedBase.isEmpty { sections.append(boundedBase) }
        if !channel.isEmpty { sections.append(channel) }
        sections.append(requestHeader + boundedRequest)
        return sections.joined(separator: "\n")
    }

    /// Builds a complete SEARCH section within at most half of the available
    /// user item. The other half remains available to stateless transports for
    /// bounded request/history context, while the section itself is never
    /// clipped by the final suffix-preserving payload cap.
    private static func searchResultContext(
        root: String,
        query: String,
        matches: [String],
        userBudget: Int
    ) -> String {
        let sectionBudget = min(
            userBudget, max(userBudget / 2, min(userBudget, 1_024)))
        let safeRoot = boundedSuffix(root, to: min(512, sectionBudget))
        let safeQuery = boundedSuffix(query, to: min(512, sectionBudget))
        let header = "--- files under \(safeRoot) matching \"\(safeQuery)\" ---\n"
        let instruction = "\nAnswer in chat using the file list above. Do not open a terminal."
        let fileBudget = max(
            min(
                maxSearchResultsBytes,
                sectionBudget - header.utf8.count - instruction.utf8.count),
            0)
        let rawFiles = matches.isEmpty
            ? "(no files matched under \(safeRoot))"
            : matches.joined(separator: "\n")
        let fileBlock = bounded(rawFiles, to: fileBudget)
        return header + fileBlock + instruction
    }

    /// Bounds the item the model actually sees. Several bridges concatenate
    /// system and user text internally, so capping `user` alone is insufficient.
    /// The constant system prefix stays intact while the newest user/request
    /// suffix wins the remaining budget.
    static func boundedBackendPayload(
        for backend: Backend, system: String, user: String
    ) -> (system: String, user: String) {
        guard combinesSystemAndUser(backend) else {
            return (system, boundedSuffix(user, to: maxBackendUserBytes))
        }

        let separatorBytes = 2 // "\n\n"
        let boundedSystem: String
        if system.utf8.count + separatorBytes < maxBackendUserBytes {
            boundedSystem = system
        } else {
            // Fail closed if the constant prompt grows unexpectedly: retain a
            // deterministic prefix and reserve at least half for the request.
            boundedSystem = bounded(
                system, to: max((maxBackendUserBytes - separatorBytes) / 2, 0))
        }
        let userBudget = backendUserBudget(for: backend, system: system)
        return (boundedSystem, boundedSuffix(user, to: userBudget))
    }

    /// Stable identity for the backend state that can retain this thread's
    /// prior turns. Secrets are deliberately excluded.
    private static func backendSessionSignature(
        for backend: Backend, cwd: String
    ) -> String {
        let backendIdentity: String
        switch backend {
        case .none:
            backendIdentity = "none"
        case .command(let command):
            backendIdentity = "command|\(command)"
        case .openai(let base, _, let model):
            backendIdentity = "openai|\(base)|\(model)"
        case .codex(let model):
            backendIdentity = "codex|\(model ?? "")"
        case .claude(let model):
            backendIdentity = "claude|\(model ?? "")"
        case .opencode(let model):
            backendIdentity = "opencode|\(model ?? "")"
        case .hermes(let model):
            backendIdentity = "hermes|\(model ?? "")"
        case .amp(let model):
            backendIdentity = "amp|\(model ?? "")"
        case .foundation:
            backendIdentity = "foundation"
        }
        return backendIdentity + "|cwd:" + cwd
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
    func prewarm() {
        let backend = Self.resolveBackend(config: config)
        guard Self.isStateful(backend) else { return }
        registerBackendConversation(
            backend: backend,
            system: Self.systemPrompt,
            cwd: workspaceDirectoryForChat(),
            conversationID: backendConversationID(for: activeThreadId))
    }

    /// Warm whichever CLI bridge the config resolves to, so its cold start
    /// overlaps the user typing. No-op for HTTP/Apple/none.
    static func prewarm(config: AppConfig, conversationID: String? = nil) {
        switch resolveBackend(config: config) {
        case .claude(let model):
            ClaudeBridge.shared.warmUp(
                system: systemPrompt, model: model,
                conversationID: conversationID)
        case .codex(let model):
            CodexAppServer.shared.warmUp(
                model: model ?? "gpt-5.4",
                conversationID: conversationID)
        case .opencode(let model):
            ACPBridge.opencode.warmUp(
                model: model, conversationID: conversationID)
        case .hermes(let model):
            ACPBridge.hermes.warmUp(
                model: model, conversationID: conversationID)
        case .amp, .openai, .foundation, .command, .none:
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
        case .opencode:
            return .opencode(model: choice.modelID ?? config.opencodeModel)
        case .hermes:
            return .hermes(model: choice.modelID ?? config.hermesModel)
        case .amp:
            return .amp(model: choice.modelID ?? config.ampModel)
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
        case .opencode: return .opencode(model: config.opencodeModel)
        case .hermes: return .hermes(model: config.hermesModel)
        case .amp: return .amp(model: config.ampModel)
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

    /// "SEARCH: keywords" or "LIST:" / "SEARCH: *" as the entire reply →
    /// query string (list-all normalizes to `"*"`), else nil.
    static func parseSearchDirective(_ reply: String?) -> String? {
        guard let line = reply?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1).first
            .map(String.init)
        else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "LIST" || trimmed.hasPrefix("LIST:") {
            return "*"
        }
        guard trimmed.hasPrefix("SEARCH:") else { return nil }
        let query = trimmed.dropFirst("SEARCH:".count)
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
        outcome: AIOutcome, files: [String], query: String?,
        completion: BackendAskCompletion?
    ) {
        DispatchQueue.main.async {
            completion?(outcome, files, query)
        }
    }

    /// Sidebar chat tab or the floating assistant popover currently showing.
    private var isChatSurfaceVisible: Bool {
        if let popover, popover.isShown { return true }
        if let panel = sidebarPanel,
           !panel.isHidden,
           panel.window != nil,
           panel.superview != nil,
           panel.visibleRect.width > 0,
           panel.visibleRect.height > 0 {
            return true
        }
        if let panel = popoverPanel,
           !panel.isHidden,
           panel.window != nil,
           panel.visibleRect.width > 0 {
            return true
        }
        return false
    }


    var popoverPanelForTesting: PetAssistantPanelView? { popoverPanel }
    var threadCountForTesting: Int { threads.count }
    var threadIdsForTesting: [UUID] { threads.map(\.id) }
    var activeThreadTitleForTesting: String { activeThread?.title ?? "" }
    static var maximumComposerInputBytesForTesting: Int { maxComposerBytes }
    static var maximumBackendUserBytesForTesting: Int { maxBackendUserBytes }
    static var systemPromptBytesForTesting: Int { systemPrompt.utf8.count }
    static var maximumCombinedUserBytesForTesting: Int {
        max(maxBackendUserBytes - systemPrompt.utf8.count - 2, 0)
    }

    static func composedBackendUserForTesting(
        backend: Backend,
        baseContext: String,
        collaborationContext: CollaborationChatContext?,
        request: String
    ) -> String {
        composedBackendUser(
            for: backend,
            system: systemPrompt,
            baseContext: baseContext,
            collaborationContext: collaborationContext,
            request: request)
    }
    var activeToolEventScopeIDForTesting: String {
        backendConversationID(for: activeThreadId)
    }
    func selectThreadForTesting(_ id: UUID) { selectThread(id) }
    func setWorkspaceDirectoryForTesting(_ path: String) {
        setWorkspaceDirectory(path)
    }

    // MARK: - AI backends (mirrors HintEngine's smart-source resolution)

    private func advanceBackendEpoch(for request: PendingRequest) -> String {
        guard let idx = threadIndex(request.threadId) else {
            return activeBackendConversationID
                ?? Self.backendConversationID(threadID: request.threadId, epoch: 0)
        }
        threads[idx].backendEpoch &+= 1
        let conversationID = Self.backendConversationID(
            threadID: request.threadId, epoch: threads[idx].backendEpoch)
        activeBackendConversationID = conversationID
        // Tool cards are scoped by the same epoch as the bridge. Switching the
        // subscription now rejects any already-queued events from the released
        // lifecycle.
        updatePanels()
        return conversationID
    }

    private func backendStartIsCurrent(
        _ request: PendingRequest,
        conversationID: String
    ) -> Bool {
        let check = {
            !self.invalidated
                && self.requestInFlight
                && self.activeRequestID == request.id
                && self.streamingThreadId == request.threadId
                && self.activeBackendConversationID == conversationID
                && self.threads.first(where: { $0.id == request.threadId })?
                    .generation == request.generation
        }
        if Thread.isMainThread { return check() }
        return DispatchQueue.main.sync(execute: check)
    }

    private func scheduleBackendWork(_ work: @escaping () -> Void) {
        if let backendWorkScheduler {
            backendWorkScheduler(work)
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    }

    private func registerBackendConversation(
        backend: Backend,
        system: String,
        cwd: String,
        conversationID: String
    ) {
        guard Self.isStateful(backend) else { return }
        registeredConversationIDs.insert(conversationID)
        if let conversationRegistrar {
            conversationRegistrar(backend, system, cwd, conversationID)
            return
        }
        // Injected transports do not own real bridge state.
        guard backendRunner == nil else { return }
        switch backend {
        case .codex(let model):
            CodexAppServer.shared.warmUp(
                model: model ?? "gpt-5.4", conversationID: conversationID)
        case .claude(let model):
            ClaudeBridge.shared.warmUp(
                system: system, model: model, conversationID: conversationID)
        case .opencode(let model):
            ACPBridge.opencode.warmUp(
                model: model, cwd: cwd, conversationID: conversationID)
        case .hermes(let model):
            ACPBridge.hermes.warmUp(
                model: model, cwd: cwd, conversationID: conversationID)
        case .none, .command, .openai, .amp, .foundation:
            break
        }
    }

    private func releaseRegisteredBackendConversation(_ conversationID: String) {
        registeredConversationIDs.remove(conversationID)
        if let conversationReleaser {
            conversationReleaser(conversationID)
        } else {
            Self.releaseBackendConversation(conversationID)
        }
    }

    private func markBackendBootstrapNeeded(after request: PendingRequest) {
        let mark = { [weak self] in
            guard let self, !self.invalidated,
                  let idx = self.threadIndex(request.threadId),
                  self.threads[idx].generation == request.generation
            else { return }
            self.threads[idx].needsBackendBootstrap = true
        }
        if Thread.isMainThread { mark() }
        else { DispatchQueue.main.async(execute: mark) }
    }

    private func runBackend(
        backend: Backend,
        system: String,
        user: String,
        cwd: String,
        conversationID: String?,
        onPartial: ((String) -> Void)?,
        timeout: TimeInterval?,
        done: @escaping (AIOutcome) -> Void
    ) {
        if let backendRunner {
            backendRunner(
                backend, system, user, cwd, conversationID,
                onPartial, timeout, done)
        } else {
            Self.askAI(
                backend: backend, system: system, user: user, cwd: cwd,
                conversationID: conversationID,
                onPartial: onPartial, timeout: timeout, done: done)
        }
    }

    /// Calls `done` on whatever thread the backend completes on; callers hop
    /// to main as needed.
    static func askAI(
        backend: Backend,
        system: String, user: String, cwd: String,
        conversationID: String? = nil,
        onPartial: ((String) -> Void)? = nil,
        timeout: TimeInterval? = nil,
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
            askCodex(model: model, cwd: cwd, system: system, user: user,
                     conversationID: conversationID,
                     onPartial: onPartial, timeout: timeout, done: done)
        case .claude(let model):
            askClaude(model: model, system: system, user: user,
                      conversationID: conversationID,
                      onPartial: onPartial, timeout: timeout, done: done)
        case .opencode(let model):
            askACP(.opencode, model: model, cwd: cwd, system: system, user: user,
                   conversationID: conversationID,
                   onPartial: onPartial, timeout: timeout, done: done)
        case .hermes(let model):
            askACP(.hermes, model: model, cwd: cwd, system: system, user: user,
                   conversationID: conversationID,
                   onPartial: onPartial, timeout: timeout, done: done)
        case .amp(let model):
            askAmp(model: model, system: system, user: user, cwd: cwd,
                   conversationID: conversationID,
                   onPartial: onPartial, timeout: timeout, done: done)
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

    static func cancelBackendConversation(_ conversationID: String) {
        CodexAppServer.shared.cancelConversation(conversationID)
        ClaudeBridge.shared.cancelConversation(conversationID)
        ACPBridge.opencode.cancelConversation(conversationID)
        ACPBridge.hermes.cancelConversation(conversationID)
        AmpBridge.shared.cancelConversation(conversationID)
    }

    static func releaseBackendConversation(_ conversationID: String) {
        CodexAppServer.shared.releaseConversation(conversationID)
        ClaudeBridge.shared.releaseConversation(conversationID)
        ACPBridge.opencode.releaseConversation(conversationID)
        ACPBridge.hermes.releaseConversation(conversationID)
        AmpBridge.shared.cancelConversation(conversationID)
    }

    /// Codex CLI via the persistent `codex app-server` bridge. One-time cold
    /// start, then warm turns. Tool calls run between Codex and infinitty-mcp.
    /// Default per-turn bridge timeout when `ai-turn-timeout` is unset.
    /// Lower than the old hardcoded 130s so a genuinely stalled turn fails
    /// fast instead of looking hung; users can raise it in config.
    private static let defaultTurnTimeout: TimeInterval = 90

    private static func askCodex(
        model: String?, cwd: String,
        system: String, user: String,
        conversationID: String? = nil,
        onPartial: ((String) -> Void)? = nil,
        timeout: TimeInterval? = nil,
        done: @escaping (AIOutcome) -> Void
    ) {
        let prompt = system + "\n\n" + user
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                do {
                    let reply = try await CodexAppServer.shared.turn(
                        prompt: prompt, cwd: cwd, model: model ?? "gpt-5.4",
                        timeout: timeout ?? defaultTurnTimeout,
                        conversationID: conversationID,
                        onPartial: onPartial)
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
        conversationID: String? = nil,
        onPartial: ((String) -> Void)? = nil,
        timeout: TimeInterval? = nil,
        done: @escaping (AIOutcome) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                do {
                    let reply = try await ClaudeBridge.shared.turn(
                        prompt: user, system: system, model: model,
                        timeout: timeout ?? defaultTurnTimeout,
                        conversationID: conversationID,
                        onPartial: onPartial)
                    done(.text(reply.trimmingCharacters(in: .whitespacesAndNewlines)))
                } catch {
                    PetLog.log("claude failed: \(error.localizedDescription)")
                    done(.failure("Claude: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// OpenCode / Hermes via the shared ACP bridge. Both speak the same
    /// stdio JSON-RPC protocol, so one bridge class drives either; the
    /// provider only picks the binary + launch args + model-selection hook.
    private static func askACP(
        _ provider: InfinittyAIProvider,
        model: String?, cwd: String,
        system: String, user: String,
        conversationID: String? = nil,
        onPartial: ((String) -> Void)? = nil,
        timeout: TimeInterval? = nil,
        done: @escaping (AIOutcome) -> Void
    ) {
        let bridge: ACPBridge = provider == .hermes ? .hermes : .opencode
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                do {
                    let reply = try await bridge.turn(
                        prompt: user, system: system, model: model, cwd: cwd,
                        timeout: timeout ?? defaultTurnTimeout,
                        conversationID: conversationID,
                        onPartial: onPartial)
                    done(.text(reply.trimmingCharacters(in: .whitespacesAndNewlines)))
                } catch {
                    PetLog.log("\(provider.rawValue) failed: \(error.localizedDescription)")
                    done(.failure("\(provider.displayName): \(error.localizedDescription)"))
                }
            }
        }
    }

    /// Amp one-shot through its supported non-interactive execute contract.
    private static func askAmp(
        model: String?, system: String, user: String, cwd: String,
        conversationID: String? = nil,
        onPartial: ((String) -> Void)? = nil,
        timeout: TimeInterval? = nil,
        done: @escaping (AIOutcome) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                do {
                    let reply = try await AmpBridge.shared.turn(
                        prompt: user, system: system, model: model,
                        cwd: cwd,
                        conversationID: conversationID,
                        timeout: timeout ?? defaultTurnTimeout,
                        onPartial: onPartial)
                    done(.text(reply.trimmingCharacters(in: .whitespacesAndNewlines)))
                } catch {
                    PetLog.log("amp failed: \(error.localizedDescription)")
                    done(.failure(error.localizedDescription))
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

extension PetAssistant.AgentChoice.Kind {
    /// Human label for menus/alerts ("Claude", "OpenCode", …).
    var providerLabel: String {
        switch self {
        case .auto: return "Auto"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .hermes: return "Hermes"
        case .amp: return "Amp"
        case .apple: return "Apple"
        }
    }

    /// SF Symbol used beside a picker row when no brand logo asset exists.
    var symbolName: String {
        switch self {
        case .auto: return "sparkles"
        case .claude: return "a.circle"
        case .codex: return "o.circle"
        case .opencode: return "terminal"
        case .hermes: return "brain"
        case .amp: return "bolt"
        case .apple: return "applelogo"
        }
    }

    /// Reverse map from the config / `configuredProvider` string.
    init?(configuredProvider: String) {
        switch configuredProvider {
        case "auto": self = .auto
        case "claude": self = .claude
        case "codex": self = .codex
        case "opencode": self = .opencode
        case "hermes": self = .hermes
        case "amp": self = .amp
        case "apple": self = .apple
        default: return nil
        }
    }
}

/// Cross-launch store for recently typed custom model ids. Kept in a
/// dedicated Application Support file — deliberately NOT the user's
/// infinitty.conf — so recording a custom model can never clobber
/// hand-edited config. Capped at the 10 most recent.
enum RecentCustomModels {
    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("infinitty", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recent-custom-models.json")
    }

    static func load() -> [PetAssistant.AgentChoice] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return [] }
        return entries.compactMap { entry in
            guard let provider = entry["provider"],
                  let id = entry["id"], !id.isEmpty,
                  let kind = PetAssistant.AgentChoice.Kind(configuredProvider: provider)
            else { return nil }
            return PetAssistant.AgentChoice(
                kind: kind, modelID: id,
                displayName: entry["name"] ?? "\(kind.providerLabel) · \(id)",
                symbolName: kind.symbolName)
        }
    }

    static func record(provider: String, id: String, name: String) {
        guard let url = fileURL else { return }
        var entries = ((try? Data(contentsOf: url)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [[String: String]]
        }) ?? []
        entries.removeAll { $0["provider"] == provider && $0["id"] == id }
        entries.insert(["provider": provider, "id": id, "name": name], at: 0)
        entries = Array(entries.prefix(10))
        if let data = try? JSONSerialization.data(
            withJSONObject: entries, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Test seam: forget all recorded custom models.
    static func clearForTesting() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
