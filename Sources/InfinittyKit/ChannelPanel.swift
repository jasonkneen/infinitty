import AppKit
import Foundation

/// Read-only, deterministic projection used by both the AppKit Channel pane
/// and tests/control adapters. The durable Collaboration room is always the
/// source of truth; this value never owns mutable room state.
struct ChannelPanelProjection: Equatable {
    struct ParticipantRow: Equatable {
        let id: String
        let name: String
        let role: String
        let status: String
        let provider: String?
        let model: String?
    }

    struct ThreadRow: Equatable {
        let id: String
        let title: String
        let ownerName: String?
        let messageCount: Int
        let lastMessage: String
    }

    struct PlanRow: Equatable {
        let id: String
        let title: String
        let status: String
        let ownerName: String?
        let dependencyTitles: [String]
    }

    struct ResponsibilityRow: Equatable {
        let id: String
        let scope: String
        let summary: String
        let ownerName: String
        let leaseExpiresAt: Date?
    }

    let channelID: String
    let title: String
    let revision: Int
    let colorHex: String
    let participants: [ParticipantRow]
    let threads: [ThreadRow]
    let plan: [PlanRow]
    let responsibilities: [ResponsibilityRow]
    let roomMessages: [CollaborationMessage]
    let visibleMessages: [CollaborationMessage]
    let selectedThreadID: String?
    let selectedThreadTitle: String
    let auditReceipt: String

    init(channel: CollaborationChannelState, selectedThreadID: String?) {
        let participantByID = Dictionary(
            uniqueKeysWithValues: channel.participants.map { ($0.id, $0) })
        let connectedParticipantIDs = Set(
            channel.endpoints.compactMap(\.participantID))
        let planByID = Dictionary(
            uniqueKeysWithValues: channel.plan.map { ($0.id, $0) })

        self.channelID = channel.id
        self.title = channel.name
        self.revision = channel.revision
        self.colorHex = channel.colorHex
        self.participants = channel.participants.map {
            ParticipantRow(
                id: $0.id,
                name: $0.displayName,
                role: $0.role,
                status: connectedParticipantIDs.contains($0.id)
                    ? "connected"
                    : "not connected",
                provider: $0.provider,
                model: $0.modelID)
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        var grouped: [String: [CollaborationMessage]] = [:]
        for message in channel.messages {
            guard let threadID = message.threadID, !threadID.isEmpty else {
                continue
            }
            grouped[threadID, default: []].append(message)
        }
        self.threads = grouped.map { threadID, messages in
            let owner = messages.compactMap {
                participantByID[$0.authorID]
            }.first
            let subject = messages.first(where: {
                $0.authorID.hasPrefix("human:")
            })?.text ?? messages.first?.text ?? ""
            let compactSubject = Self.compactThreadSubject(subject)
            let title: String
            if let owner {
                title = compactSubject.isEmpty
                    ? "\(owner.displayName) conversation"
                    : "\(owner.displayName): \(compactSubject)"
            } else if compactSubject.isEmpty {
                title = "Conversation \(threadID.prefix(8))"
            } else {
                title = compactSubject
            }
            return ThreadRow(
                id: threadID,
                title: title,
                ownerName: owner?.displayName,
                messageCount: messages.count,
                lastMessage: messages.last?.text ?? "")
        }.sorted { lhs, rhs in
            let lhsIndex = channel.messages.lastIndex {
                $0.threadID == lhs.id
            } ?? channel.messages.startIndex
            let rhsIndex = channel.messages.lastIndex {
                $0.threadID == rhs.id
            } ?? channel.messages.startIndex
            return lhsIndex < rhsIndex
        }

        self.plan = channel.plan.map { item in
            PlanRow(
                id: item.id,
                title: item.title,
                status: item.status.rawValue,
                ownerName: item.ownerID.flatMap {
                    participantByID[$0]?.displayName
                },
                dependencyTitles: item.dependencyIDs.map {
                    planByID[$0]?.title ?? $0
                })
        }
        self.responsibilities = channel.responsibilities.map {
            ResponsibilityRow(
                id: $0.id,
                scope: $0.scope,
                summary: $0.summary,
                ownerName: participantByID[$0.ownerID]?.displayName
                    ?? $0.ownerID,
                leaseExpiresAt: $0.leaseExpiresAt)
        }
        self.roomMessages = channel.messages.filter {
            $0.threadID == nil || $0.threadID?.isEmpty == true
        }
        self.selectedThreadID = selectedThreadID
        if let selectedThreadID {
            self.visibleMessages = channel.messages.filter {
                $0.threadID == selectedThreadID
            }
            self.selectedThreadTitle = threads.first {
                $0.id == selectedThreadID
            }?.title ?? selectedThreadID
        } else {
            self.visibleMessages = roomMessages
            self.selectedThreadTitle = "Room"
        }
        self.auditReceipt = "Channel \(channel.id) · revision \(channel.revision)"
    }

    private static func compactThreadSubject(_ text: String) -> String {
        let line = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard line.count > 56 else { return line }
        return String(line.prefix(55)) + "…"
    }

    func controlState(isOpen: Bool) -> [String: Any] {
        func messageState(_ message: CollaborationMessage) -> [String: Any] {
            var value: [String: Any] = [
                "id": message.id,
                "authorId": message.authorID,
                "text": message.text,
            ]
            if let threadID = message.threadID {
                value["threadId"] = threadID
            }
            return value
        }

        return [
            "panelId": "channel-panel-\(channelID)",
            "channelId": channelID,
            "title": title,
            "revision": revision,
            "colorHex": colorHex,
            "open": isOpen,
            "selectedThreadId": selectedThreadID ?? NSNull(),
            "selectedThreadTitle": selectedThreadTitle,
            "participants": participants.map { participant in
                var value: [String: Any] = [
                    "id": participant.id,
                    "name": participant.name,
                    "role": participant.role,
                    "status": participant.status,
                ]
                if let provider = participant.provider {
                    value["provider"] = provider
                }
                if let model = participant.model {
                    value["model"] = model
                }
                return value
            },
            "threads": threads.map {
                var value: [String: Any] = [
                    "id": $0.id,
                    "title": $0.title,
                    "messageCount": $0.messageCount,
                    "lastMessage": $0.lastMessage,
                ]
                if let ownerName = $0.ownerName {
                    value["ownerName"] = ownerName
                }
                return value
            },
            "plan": plan.map {
                var value: [String: Any] = [
                    "id": $0.id,
                    "title": $0.title,
                    "status": $0.status,
                    "dependencies": $0.dependencyTitles,
                ]
                if let ownerName = $0.ownerName {
                    value["ownerName"] = ownerName
                }
                return value
            },
            "responsibilities": responsibilities.map {
                var value: [String: Any] = [
                    "id": $0.id,
                    "scope": $0.scope,
                    "summary": $0.summary,
                    "ownerName": $0.ownerName,
                ]
                if let leaseExpiresAt = $0.leaseExpiresAt {
                    value["leaseExpiresAt"] =
                        ISO8601DateFormatter().string(from: leaseExpiresAt)
                }
                return value
            },
            "roomMessages": roomMessages.map(messageState),
            "visibleMessages": visibleMessages.map(messageState),
            "auditReceipt": auditReceipt,
        ]
    }
}

private final class ChannelPanelFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Native three-column Channel workspace:
/// participants/threads, selected transcript + steering composer, and a
/// plan/responsibility/status rail. It is hosted by UtilityPaneView, so pane
/// movement, stage/restore, focus, close, and split behavior stay identical to
/// other Infinitty panes.
final class ChannelPanelController: NSViewController {
    var onSendMessage: ((String, String?) -> Void)?
    var onUpdateRole: ((String, String) -> Void)?

    private var channel: CollaborationChannelState
    private(set) var selectedThreadID: String?
    private var projection: ChannelPanelProjection

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let participantsStack = NSStackView()
    private let threadStack = NSStackView()
    private let transcriptStack = NSStackView()
    private let statusStack = NSStackView()
    private let composer = NSTextField()
    private let sendButton = NSButton()
    private let roomButton = NSButton()
    private let splitView = NSSplitView()
    private let compactSelector = NSSegmentedControl(
        labels: ["People", "Room", "Plan"],
        trackingMode: .selectOne,
        target: nil,
        action: nil)
    private var splitTopToRoot: NSLayoutConstraint?
    private var splitTopToSelector: NSLayoutConstraint?
    private var channelColumns: [NSView] = []
    private(set) var isCompact = false
    private var threadButtons: [String: NSButton] = [:]

    init(channel: CollaborationChannelState) {
        self.channel = channel
        self.projection = ChannelPanelProjection(
            channel: channel, selectedThreadID: nil)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        for stack in [
            participantsStack, threadStack, transcriptStack, statusStack,
        ] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
        }

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)

        compactSelector.selectedSegment = 1
        compactSelector.target = self
        compactSelector.action = #selector(compactSectionChanged)
        compactSelector.segmentStyle = .texturedSquare
        compactSelector.setAccessibilityLabel("Channel section")
        compactSelector.translatesAutoresizingMaskIntoConstraints = false
        compactSelector.isHidden = true
        root.addSubview(compactSelector)

        let navigation = makeNavigationColumn()
        let conversation = makeConversationColumn()
        let coordination = makeCoordinationColumn()
        channelColumns = [navigation, conversation, coordination]
        splitView.addArrangedSubview(navigation)
        splitView.addArrangedSubview(conversation)
        splitView.addArrangedSubview(coordination)
        let preferredNavigationWidth = navigation.widthAnchor.constraint(
            equalToConstant: 190)
        preferredNavigationWidth.priority = .defaultLow
        preferredNavigationWidth.isActive = true
        let preferredCoordinationWidth = coordination.widthAnchor.constraint(
            equalToConstant: 230)
        preferredCoordinationWidth.priority = .defaultLow
        preferredCoordinationWidth.isActive = true

        splitTopToRoot = splitView.topAnchor.constraint(
            equalTo: root.topAnchor)
        splitTopToSelector = splitView.topAnchor.constraint(
            equalTo: compactSelector.bottomAnchor, constant: 5)
        splitTopToRoot?.isActive = true
        NSLayoutConstraint.activate([
            compactSelector.leadingAnchor.constraint(
                equalTo: root.leadingAnchor, constant: 8),
            compactSelector.trailingAnchor.constraint(
                equalTo: root.trailingAnchor, constant: -8),
            compactSelector.topAnchor.constraint(
                equalTo: root.topAnchor, constant: 6),
            compactSelector.heightAnchor.constraint(equalToConstant: 26),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Channel workspace")
        view = root
        render()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateCompactLayout(for: view.bounds.width)
    }

    func update(channel: CollaborationChannelState) {
        guard channel.id == self.channel.id else { return }
        self.channel = channel
        if let selectedThreadID,
           !channel.messages.contains(where: {
               $0.threadID == selectedThreadID
           })
        {
            self.selectedThreadID = nil
        }
        projection = ChannelPanelProjection(
            channel: channel, selectedThreadID: selectedThreadID)
        guard isViewLoaded else { return }
        render()
    }

    private func makeNavigationColumn() -> NSView {
        let stack = makeVerticalStack(spacing: 8)
        stack.edgeInsets = NSEdgeInsets(
            top: 14, left: 12, bottom: 14, right: 12)
        let participantsTitle = sectionLabel("Participants")
        let threadsTitle = sectionLabel("Conversations")
        roomButton.title = "Room"
        roomButton.bezelStyle = .recessed
        roomButton.alignment = .left
        roomButton.target = self
        roomButton.action = #selector(selectRoom)
        stack.addArrangedSubview(participantsTitle)
        stack.addArrangedSubview(participantsStack)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(threadsTitle)
        stack.addArrangedSubview(roomButton)
        stack.addArrangedSubview(threadStack)
        return scrollView(hosting: stack)
    }

    private func makeConversationColumn() -> NSView {
        let root = NSView()
        let heading = makeVerticalStack(spacing: 2)
        heading.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor
        heading.addArrangedSubview(titleLabel)
        heading.addArrangedSubview(subtitleLabel)

        let transcript = scrollView(hosting: transcriptStack)
        transcript.translatesAutoresizingMaskIntoConstraints = false

        composer.placeholderString = "Message the room"
        composer.setAccessibilityLabel("Channel message")
        composer.target = self
        composer.action = #selector(sendMessage)
        composer.translatesAutoresizingMaskIntoConstraints = false
        sendButton.title = "Send"
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sendMessage)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        let composerRow = NSView()
        composerRow.translatesAutoresizingMaskIntoConstraints = false
        composerRow.addSubview(composer)
        composerRow.addSubview(sendButton)
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: composerRow.leadingAnchor),
            composer.centerYAnchor.constraint(equalTo: composerRow.centerYAnchor),
            sendButton.leadingAnchor.constraint(
                equalTo: composer.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(
                equalTo: composerRow.trailingAnchor),
            sendButton.centerYAnchor.constraint(
                equalTo: composerRow.centerYAnchor),
            composerRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])

        root.addSubview(heading)
        root.addSubview(transcript)
        root.addSubview(composerRow)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            transcript.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcript.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            transcript.bottomAnchor.constraint(
                equalTo: composerRow.topAnchor, constant: -8),
            composerRow.leadingAnchor.constraint(
                equalTo: root.leadingAnchor, constant: 14),
            composerRow.trailingAnchor.constraint(
                equalTo: root.trailingAnchor, constant: -14),
            composerRow.bottomAnchor.constraint(
                equalTo: root.bottomAnchor, constant: -12),
        ])
        return root
    }

    private func makeCoordinationColumn() -> NSView {
        statusStack.edgeInsets = NSEdgeInsets(
            top: 14, left: 12, bottom: 14, right: 12)
        return scrollView(hosting: statusStack)
    }

    private func makeVerticalStack(spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func scrollView(hosting stack: NSStackView) -> NSScrollView {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = max(stack.spacing, 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = ChannelPanelFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = document
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(
                greaterThanOrEqualTo: scroll.contentView.heightAnchor),
        ])
        return scroll
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func render() {
        projection = ChannelPanelProjection(
            channel: channel, selectedThreadID: selectedThreadID)
        titleLabel.stringValue = projection.title
        subtitleLabel.stringValue =
            "\(projection.selectedThreadTitle) · revision \(projection.revision)"
        composer.placeholderString = selectedThreadID == nil
            ? "Message the room"
            : "Steer \(projection.selectedThreadTitle)"

        clear(participantsStack)
        for participant in projection.participants {
            let provider = [participant.provider, participant.model]
                .compactMap { $0 }.joined(separator: " / ")
            let participantStack = makeVerticalStack(spacing: 3)
            let label = NSTextField(wrappingLabelWithString:
                "\(participant.name) · \(participant.status)"
                    + (provider.isEmpty ? "" : "\n\(provider)"))
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.maximumNumberOfLines = 3
            let roleField = NSTextField(string: participant.role)
            roleField.placeholderString = "Assign a role"
            roleField.font = .systemFont(ofSize: 11)
            roleField.identifier = NSUserInterfaceItemIdentifier(
                participant.id)
            roleField.target = self
            roleField.action = #selector(updateParticipantRole(_:))
            roleField.setAccessibilityLabel(
                "Role for \(participant.name)")
            participantStack.addArrangedSubview(label)
            participantStack.addArrangedSubview(roleField)
            participantsStack.addArrangedSubview(participantStack)
        }
        if projection.participants.isEmpty {
            participantsStack.addArrangedSubview(
                NSTextField(labelWithString: "No participants"))
        }

        clear(threadStack)
        threadButtons.removeAll()
        for thread in projection.threads {
            let button = NSButton(
                title: "\(thread.title) · \(thread.messageCount)",
                target: self,
                action: #selector(selectThread(_:)))
            button.bezelStyle = .recessed
            button.alignment = .left
            button.identifier = NSUserInterfaceItemIdentifier(thread.id)
            button.toolTip = thread.lastMessage
            button.state = thread.id == selectedThreadID ? .on : .off
            threadButtons[thread.id] = button
            threadStack.addArrangedSubview(button)
        }
        roomButton.state = selectedThreadID == nil ? .on : .off

        clear(transcriptStack)
        transcriptStack.edgeInsets = NSEdgeInsets(
            top: 8, left: 16, bottom: 8, right: 16)
        let participantNames = Dictionary(
            uniqueKeysWithValues: channel.participants.map {
                ($0.id, $0.displayName)
            })
        for message in projection.visibleMessages {
            let author = participantNames[message.authorID]
                ?? (message.authorID.hasPrefix("human:")
                    ? "Human"
                    : message.authorID)
            let label = NSTextField(
                wrappingLabelWithString: "\(author)\n\(message.text)")
            label.font = .systemFont(ofSize: 12)
            label.maximumNumberOfLines = 0
            label.setAccessibilityLabel("\(author): \(message.text)")
            transcriptStack.addArrangedSubview(label)
        }
        if projection.visibleMessages.isEmpty {
            let empty = NSTextField(labelWithString:
                selectedThreadID == nil
                    ? "No room-level messages yet."
                    : "No messages in this thread.")
            empty.textColor = .secondaryLabelColor
            transcriptStack.addArrangedSubview(empty)
        }

        clear(statusStack)
        statusStack.addArrangedSubview(sectionLabel("Plan / Status"))
        if projection.plan.isEmpty {
            statusStack.addArrangedSubview(
                NSTextField(labelWithString: "No plan published"))
        } else {
            for item in projection.plan {
                let owner = item.ownerName.map { " · \($0)" } ?? ""
                let deps = item.dependencyTitles.isEmpty
                    ? ""
                    : "\nAfter: \(item.dependencyTitles.joined(separator: ", "))"
                let label = NSTextField(wrappingLabelWithString:
                    "\(item.status) · \(item.title)\(owner)\(deps)")
                label.font = .systemFont(ofSize: 11)
                label.maximumNumberOfLines = 4
                statusStack.addArrangedSubview(label)
            }
        }
        statusStack.addArrangedSubview(separator())
        statusStack.addArrangedSubview(sectionLabel("Responsibilities"))
        if projection.responsibilities.isEmpty {
            statusStack.addArrangedSubview(
                NSTextField(labelWithString: "No active claims"))
        } else {
            for responsibility in projection.responsibilities {
                let label = NSTextField(wrappingLabelWithString:
                    "\(responsibility.scope)\n\(responsibility.ownerName) · "
                    + responsibility.summary)
                label.font = .systemFont(ofSize: 11)
                label.maximumNumberOfLines = 4
                statusStack.addArrangedSubview(label)
            }
        }
        statusStack.addArrangedSubview(separator())
        statusStack.addArrangedSubview(sectionLabel("Coordination safeguards"))
        statusStack.addArrangedSubview(
            NSTextField(wrappingLabelWithString:
                "Active responsibility claims are conflict-checked "
                + "by the room authority."))
        statusStack.addArrangedSubview(separator())
        statusStack.addArrangedSubview(sectionLabel("Audit receipt"))
        let receipt = NSTextField(wrappingLabelWithString:
            projection.auditReceipt)
        receipt.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        receipt.maximumNumberOfLines = 3
        statusStack.addArrangedSubview(receipt)
    }

    @objc private func selectRoom() {
        selectedThreadID = nil
        render()
    }

    @objc private func compactSectionChanged() {
        guard isCompact else { return }
        applyCompactSection()
    }

    private func updateCompactLayout(for width: CGFloat) {
        let wantsCompact = width > 0 && width < 620
        guard wantsCompact != isCompact else { return }
        isCompact = wantsCompact
        compactSelector.isHidden = !wantsCompact
        if wantsCompact {
            splitTopToRoot?.isActive = false
            splitTopToSelector?.isActive = true
            applyCompactSection()
        } else {
            splitTopToSelector?.isActive = false
            splitTopToRoot?.isActive = true
            for column in channelColumns { column.isHidden = false }
            splitView.adjustSubviews()
        }
    }

    private func applyCompactSection() {
        let selection = max(compactSelector.selectedSegment, 0)
        for (index, column) in channelColumns.enumerated() {
            column.isHidden = index != selection
        }
        splitView.adjustSubviews()
    }

    @objc private func selectThread(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        selectedThreadID = id
        render()
    }

    @objc private func sendMessage() {
        let text = composer.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composer.stringValue = ""
        onSendMessage?(text, selectedThreadID)
    }

    @objc private func updateParticipantRole(_ sender: NSTextField) {
        guard let participantID = sender.identifier?.rawValue else { return }
        let role = sender.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !role.isEmpty,
              projection.participants.contains(where: {
                  $0.id == participantID && $0.role != role
              })
        else { return }
        onUpdateRole?(participantID, role)
    }

    func selectThreadForTesting(_ id: String?) {
        _ = selectThreadForControl(id)
    }

    func submitForTesting(_ text: String) {
        _ = view
        composer.stringValue = text
        sendMessage()
    }

    func updateRoleForTesting(participantID: String, role: String) {
        onUpdateRole?(participantID, role)
    }

    func layoutForTesting(width: CGFloat) {
        _ = view
        view.frame.size.width = width
        updateCompactLayout(for: width)
    }

    func selectCompactSectionForTesting(_ index: Int) {
        compactSelector.selectedSegment = index
        if isCompact { applyCompactSection() }
    }

    var visibleCompactSectionForTesting: Int? {
        guard isCompact else { return nil }
        return channelColumns.firstIndex { !$0.isHidden }
    }

    var renderedTextForTesting: String {
        let participantText = projection.participants.map {
            "\($0.name) \($0.role) \($0.status)"
        }
        let threadText = projection.threads.map {
            "\($0.title) \($0.lastMessage)"
        }
        let planText = projection.plan.map {
            "\($0.status) \($0.title) \($0.ownerName ?? "") "
                + $0.dependencyTitles.joined(separator: " ")
        }
        let responsibilityText = projection.responsibilities.map {
            "\($0.scope) \($0.ownerName) \($0.summary)"
        }
        return ([projection.title, projection.auditReceipt]
            + participantText + threadText + planText
            + responsibilityText
            + projection.visibleMessages.map(\.text))
            .joined(separator: "\n")
    }

    @discardableResult
    func selectThreadForControl(_ id: String?) -> Bool {
        if let id, !projection.threads.contains(where: { $0.id == id }) {
            return false
        }
        selectedThreadID = id
        projection = ChannelPanelProjection(
            channel: channel, selectedThreadID: selectedThreadID)
        if isViewLoaded { render() }
        return true
    }

    func controlState(isOpen: Bool = true) -> [String: Any] {
        projection.controlState(isOpen: isOpen)
    }
}
