import Foundation

/// Renderer-free Chat state and provider execution for `--headless`.
///
/// This intentionally shares the provider resolver/bridges with PetAssistant
/// but owns no AppKit views and never dispatches completion through the main
/// queue. State is polled through the same structured Chat control contract as
/// visual panes.
final class HeadlessChatRuntime: @unchecked Sendable {
    static let localBackendConversationCanceller:
        @Sendable (String) -> Void = { conversationID in
            PetAssistant.cancelBackendConversation(conversationID)
        }
    static let localBackendConversationReleaser:
        @Sendable (String) -> Void = { conversationID in
            PetAssistant.releaseBackendConversation(conversationID)
        }

    private struct ThreadState {
        let id: UUID
        var title: String
        var messages: [AssistantChatMessage]
        var updatedAt: Date
        var generation: Int
    }

    private struct PendingRequest {
        let id: UUID
        let text: String
        let model: String?
        let effort: String
        let threadID: UUID
        let generation: Int
    }

    let id: String
    let participantID: String
    let proposalID: String?
    let capabilities: [String]
    private var name: String
    private var role: String
    private var workspaceDirectory: String
    let configuredProvider: String
    let configuredModel: String?

    private let config: AppConfig
    private let stateLock = NSLock()
    private let workQueue: DispatchQueue
    private let onStateChange: @Sendable (String) -> Void
    private let collaborationContextProvider:
        @Sendable () -> CollaborationChatContext?
    private let collaborationMessagePublisher:
        @Sendable (CollaborationChatEmission) -> Void
    private let backendRunner: PetAssistant.BackendRunner?
    private let backendConversationCanceller:
        @Sendable (String) -> Void
    private let backendConversationReleaser:
        @Sendable (String) -> Void
    private var threads: [ThreadState]
    private var activeThreadID: UUID
    private var pending: [PendingRequest] = []
    private var inFlight: PendingRequest?
    private var stopped = false

    init(
        id: String,
        participantID: String,
        proposalID: String? = nil,
        name: String,
        role: String,
        workspaceDirectory: String,
        configuredProvider: String,
        configuredModel: String?,
        config: AppConfig,
        capabilities: [String] = [
            "channel.receive", "channel.send",
        ],
        collaborationContextProvider:
            @escaping @Sendable () -> CollaborationChatContext? = {
                nil
            },
        collaborationMessagePublisher:
            @escaping @Sendable (CollaborationChatEmission) -> Void = {
                _ in
            },
        backendRunner: PetAssistant.BackendRunner? = nil,
        backendConversationCanceller:
            @escaping @Sendable (String) -> Void =
                localBackendConversationCanceller,
        backendConversationReleaser:
            @escaping @Sendable (String) -> Void =
                localBackendConversationReleaser,
        onStateChange: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.id = id
        self.participantID = participantID
        self.proposalID = proposalID
        self.name = name
        self.role = role
        self.workspaceDirectory = workspaceDirectory
        self.configuredProvider = configuredProvider
        self.configuredModel = configuredModel
        self.config = config
        self.capabilities = capabilities
        self.collaborationContextProvider =
            collaborationContextProvider
        self.collaborationMessagePublisher =
            collaborationMessagePublisher
        self.backendRunner = backendRunner
        self.backendConversationCanceller =
            backendConversationCanceller
        self.backendConversationReleaser =
            backendConversationReleaser
        self.onStateChange = onStateChange
        self.workQueue = DispatchQueue(
            label: "infinitty.headless-chat.\(id)",
            qos: .userInitiated)
        let seed = ThreadState(
            id: UUID(),
            title: "New chat",
            messages: [],
            updatedAt: Date(),
            generation: 0)
        self.threads = [seed]
        self.activeThreadID = seed.id
    }

    func state() -> AssistantChatControlState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return AssistantChatControlState(
            activeThreadID: activeThreadID.uuidString.lowercased(),
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
            queuedRequests: pending.map(\.text),
            requestInFlight: inFlight != nil,
            streamingThreadID:
                inFlight?.threadID.uuidString.lowercased(),
            workspaceDirectory: workspaceDirectory,
            terminalAvailable: false,
            terminalAccessRequested: false,
            terminalAccessEffective: false,
            executionMode: AgentExecutionProfile.workspaceChat.rawValue,
            ensembleAgents: [])
    }

    func metadata() -> (
        name: String,
        role: String,
        workspace: String
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (name, role, workspaceDirectory)
    }

    func rename(_ value: String) {
        let value = value.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        stateLock.lock()
        name = String(value.prefix(80))
        stateLock.unlock()
        onStateChange("renamed")
    }

    @discardableResult
    func setWorkspace(_ path: String) -> Bool {
        let value = path.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        stateLock.lock()
        guard inFlight == nil, pending.isEmpty, !stopped else {
            stateLock.unlock()
            return false
        }
        workspaceDirectory = value
        stateLock.unlock()
        onStateChange("workspace-changed")
        return true
    }

    func submit(
        _ text: String,
        model: String? = nil,
        effort: String = "Auto"
    ) {
        let text = text.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stateLock.lock()
        guard !stopped,
              let thread = threads.first(where: {
                  $0.id == activeThreadID
              })
        else {
            stateLock.unlock()
            return
        }
        pending.append(PendingRequest(
            id: UUID(),
            text: text,
            model: model,
            effort: effort,
            threadID: activeThreadID,
            generation: thread.generation))
        stateLock.unlock()
        onStateChange("queued")
        processNext()
    }

    func startNewThread() {
        var conversationToCancel: String?
        stateLock.lock()
        guard !stopped,
              let index = threads.firstIndex(where: {
                  $0.id == activeThreadID
              })
        else {
            stateLock.unlock()
            return
        }
        threads[index].generation += 1
        let existingID = threads[index].id
        pending.removeAll { $0.threadID == existingID }
        if inFlight?.threadID == existingID {
            conversationToCancel = conversationID(for: existingID)
            inFlight = nil
        }
        if threads[index].messages.isEmpty {
            stateLock.unlock()
            if let conversationToCancel {
                backendConversationCanceller(conversationToCancel)
            }
            onStateChange("thread-reset")
            processNext()
            return
        }
        let fresh = ThreadState(
            id: UUID(),
            title: "New chat",
            messages: [],
            updatedAt: Date(),
            generation: 0)
        threads.insert(fresh, at: 0)
        activeThreadID = fresh.id
        stateLock.unlock()
        if let conversationToCancel {
            backendConversationCanceller(conversationToCancel)
        }
        onStateChange("thread-opened")
        processNext()
    }

    @discardableResult
    func selectThread(_ id: String) -> Bool {
        guard let threadID = UUID(uuidString: id) else { return false }
        stateLock.lock()
        guard threads.contains(where: { $0.id == threadID }) else {
            stateLock.unlock()
            return false
        }
        activeThreadID = threadID
        stateLock.unlock()
        onStateChange("thread-selected")
        return true
    }

    func cancel() {
        let conversations: [String]
        stateLock.lock()
        let affected = Set(
            pending.map(\.threadID)
                + [inFlight?.threadID].compactMap { $0 })
        for index in threads.indices where affected.contains(threads[index].id) {
            threads[index].generation += 1
        }
        conversations = affected.map(conversationID(for:))
        pending.removeAll()
        inFlight = nil
        stateLock.unlock()
        for conversation in conversations {
            backendConversationCanceller(conversation)
        }
        onStateChange("cancelled")
    }

    func stop() {
        let conversations: [String]
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        conversations = threads.map { conversationID(for: $0.id) }
        pending.removeAll()
        inFlight = nil
        stateLock.unlock()
        for conversation in conversations {
            backendConversationReleaser(conversation)
        }
    }

    private func processNext() {
        stateLock.lock()
        guard !stopped, inFlight == nil, !pending.isEmpty else {
            stateLock.unlock()
            return
        }
        let request = pending.removeFirst()
        guard let index = threads.firstIndex(where: {
            $0.id == request.threadID
                && $0.generation == request.generation
        }) else {
            stateLock.unlock()
            processNext()
            return
        }
        inFlight = request
        threads[index].messages.append(AssistantChatMessage(
            role: "You", text: request.text))
        if threads[index].title == "New chat" {
            threads[index].title = ChatThread.title(
                fromFirstUserMessage: request.text)
        }
        threads[index].updatedAt = Date()
        let conversationID = conversationID(for: request.threadID)
        let workspace = workspaceDirectory
        stateLock.unlock()

        collaborationMessagePublisher(CollaborationChatEmission(
            kind: .humanPrompt,
            text: request.text,
            threadID:
                request.threadID.uuidString.lowercased()))
        let backend = resolvedBackend(modelOverride: request.model)
        let channelContext =
            collaborationContextProvider()?.modelContext() ?? ""
        let user = [
            "cwd: \(workspace)",
            channelContext,
            "--- headless Chat request ---",
            request.text,
            effortDirective(request.effort),
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        onStateChange("started")

        workQueue.async { [weak self] in
            guard let self else { return }
            let done: (PetAssistant.AIOutcome) -> Void = {
                [weak self] outcome in
                self?.complete(request, outcome: outcome)
            }
            if let backendRunner = self.backendRunner {
                backendRunner(
                    backend,
                    Self.systemPrompt,
                    user,
                    workspace,
                    conversationID,
                    { [weak self] _ in
                        self?.onStateChange("streaming")
                    },
                    self.config.aiTurnTimeout,
                    done)
            } else {
                PetAssistant.askAI(
                    backend: backend,
                    system: Self.systemPrompt,
                    user: user,
                    cwd: workspace,
                    conversationID: conversationID,
                    timeout: self.config.aiTurnTimeout,
                    done: done)
            }
        }
    }

    private func complete(
        _ request: PendingRequest,
        outcome: PetAssistant.AIOutcome
    ) {
        stateLock.lock()
        guard !stopped,
              inFlight?.id == request.id,
              let index = threads.firstIndex(where: {
                  $0.id == request.threadID
                      && $0.generation == request.generation
              })
        else {
            stateLock.unlock()
            return
        }
        let response = PetAssistant.displayText(for: outcome)
        let isSuccessfulAgentResponse: Bool
        if case .text = outcome {
            isSuccessfulAgentResponse = true
        } else {
            isSuccessfulAgentResponse = false
        }
        threads[index].messages.append(AssistantChatMessage(
            role: isSuccessfulAgentResponse ? "Assistant" : "System",
            text: response))
        threads[index].updatedAt = Date()
        inFlight = nil
        stateLock.unlock()
        if isSuccessfulAgentResponse {
            collaborationMessagePublisher(CollaborationChatEmission(
                kind: .agentResponse,
                text: response,
                threadID:
                    request.threadID.uuidString.lowercased()))
        } else {
            collaborationMessagePublisher(CollaborationChatEmission(
                kind: .runtimeFailure,
                text: response,
                threadID:
                    request.threadID.uuidString.lowercased()))
        }
        onStateChange(
            isSuccessfulAgentResponse ? "completed" : "failed")
        processNext()
    }

    private func resolvedBackend(
        modelOverride: String?
    ) -> PetAssistant.Backend {
        guard let modelOverride,
              !modelOverride.trimmingCharacters(
                  in: .whitespacesAndNewlines).isEmpty
        else { return PetAssistant.resolveBackend(config: config) }
        var overridden = config
        let model = modelOverride.trimmingCharacters(
            in: .whitespacesAndNewlines)
        switch overridden.aiProvider {
        case "claude": overridden.claudeModel = model
        case "codex": overridden.codexModel = model
        case "opencode": overridden.opencodeModel = model
        case "hermes": overridden.hermesModel = model
        case "amp": overridden.ampModel = model
        default: break
        }
        return PetAssistant.resolveBackend(config: overridden)
    }

    private func conversationID(for threadID: UUID) -> String {
        "headless-chat:\(id):\(threadID.uuidString.lowercased())"
    }

    private func effortDirective(_ effort: String) -> String {
        switch effort.lowercased() {
        case "none": return "Reasoning effort: none."
        case "low": return "Reasoning effort: low."
        case "medium": return "Reasoning effort: medium."
        case "high": return "Reasoning effort: high; verify before answering."
        default: return ""
        }
    }

    private static let systemPrompt = """
    You are an agent running in an Infinitty headless Chat. Work against the
    exact cwd supplied with each turn. Report real provider or tool failures;
    never claim a command, file change, peer, Channel, or result that you did
    not actually observe.
    """
}
