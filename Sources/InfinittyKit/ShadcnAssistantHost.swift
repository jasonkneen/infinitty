import AIElementsUI
import AppKit
import ShadcnUI
import SwiftUI

/// Replaces `PetAssistantPanelView`'s entire UI with the ShadKit panel.
///
/// The whole surface is swapped rather than a SwiftUI island inserted into the
/// existing constraints — mixed layouts are where the sizing surprises live,
/// and an earlier attempt to nest just the transcript collapsed the panel.
@MainActor
final class ShadcnAssistantHost {
    let model = AIAssistantPanelModel()
    private(set) var view: ShadcnHostingView<AIAssistantPanel>!
    private var baseTheme: ShadcnTheme
    /// Host-fed identity, separate from the eagerly updated SwiftUI binding.
    /// Comparing against `model.activeThreadId` would miss user-driven switches.
    private var lastPresentedThreadID: String?

    init(config: AppConfig = AppConfig()) {
        baseTheme = UISurfaceTheme.theme(for: config)
        model.messageFontSize = config.interfaceFontSize
        let model = self.model
        view = ShadcnHostingView(
            theme: Self.assistantTheme(
                base: baseTheme, interfaceFontSize: config.interfaceFontSize),
            colorScheme: UISurfaceTheme.colorScheme(for: config),
            paintsBackground: true
        ) {
            // Panel fills proposed size (see AIAssistantPanel body) so a
            // popover's contentSize isn't overflow-clipped at the footer.
            AIAssistantPanel(model: model, showsHeader: false)
        }
    }

    func applyAppearance(config: AppConfig) {
        baseTheme = UISurfaceTheme.theme(for: config)
        model.messageFontSize = config.interfaceFontSize
        let model = self.model
        view.update(
            theme: Self.assistantTheme(
                base: baseTheme, interfaceFontSize: config.interfaceFontSize),
            colorScheme: UISurfaceTheme.colorScheme(for: config),
            paintsBackground: true
        ) {
            AIAssistantPanel(model: model, showsHeader: false)
        }
    }

    private static func assistantTheme(
        base: ShadcnTheme, interfaceFontSize: CGFloat
    ) -> ShadcnTheme {
        var theme = base
        // Keep the normal type ramp for editable controls. The compact ramp
        // makes ShadKit text fields inherit its smallest token, so the
        // interface-size setting only scales text that is already too small.
        theme.typography = base.typography.scaled(by: interfaceFontSize / 15)
        return theme
    }

    // MARK: Feeds mirroring PetAssistantPanelView

    func setMessages(_ messages: [AssistantChatMessage]) {
        model.messages = messages.enumerated().map { index, message in
            UIMessage(
                id: "turn-\(index)",
                role: message.role.caseInsensitiveCompare("You") == .orderedSame
                    ? .user : .assistant,
                text: message.text,
                author: message.author,
                createdAt: message.createdAt)
        }
    }

    func setQueuedMessages(_ queued: [String]) { model.queued = queued }

    func setStreamingText(_ text: String?) { model.streamingText = text }

    func setRoster(_ agents: [ConfiguredChatAgent]) {
        model.roster = agents.map {
            AIAssistantRosterEntry(
                id: $0.id, name: $0.alias,
                detail: "\($0.modelTitle) · \($0.effort)",
                isEnabled: $0.isEnabled)
        }
    }

    func setStreamingAuthor(_ author: String?) {
        model.streamingAuthor = author
    }

    func setThinking(_ thinking: Bool, label: String?) {
        model.isThinking = thinking
        if let label { model.thinkingLabel = label }
        if !thinking { model.streamingText = nil }
        // A new turn starts with no cards; finished ones are part of the
        // answer that was appended.
        if thinking { model.tools.removeAll() }
    }

    func clearToolEvents() {
        model.tools.removeAll()
    }

    func setHasFiles(_ hasFiles: Bool) { model.hasFiles = hasFiles }

    func setTerminalAccess(available: Bool, enabled: Bool) {
        model.terminalAvailable = available
        model.terminalAccessEnabled = available && enabled
    }

    func setThreads(_ threads: [(id: String, title: String)], activeId: String?) {
        if lastPresentedThreadID != activeId {
            model.tools.removeAll()
        }
        lastPresentedThreadID = activeId
        model.threads = threads.map {
            ShadcnSelectOption(value: $0.id, label: $0.title)
        }
        model.activeThreadId = activeId
    }

    func setAgents(_ agents: [ShadcnSelectOption<String>], selected: String?) {
        model.agentOptions = agents
        model.agents = agents.map { (value: $0.value, label: $0.label) }
        model.agent = selected
    }

    func setModels(_ models: [ShadcnSelectOption<String>], selected: String?) {
        model.modelOptions = models
        model.models = models.map { (value: $0.value, label: $0.label) }
        model.model = selected
    }

    func setEfforts(_ efforts: [ShadcnSelectOption<String>], selected: String?) {
        model.effortOptions = efforts
        model.efforts = efforts.map { (value: $0.value, label: $0.label) }
        model.effort = selected
    }

    /// Label-only convenience used by older call sites / tests.
    func setModels(_ models: [(value: String, label: String)], selected: String?) {
        setModels(
            models.map { ShadcnSelectOption(value: $0.value, label: $0.label) },
            selected: selected)
    }

    func setEfforts(_ efforts: [(value: String, label: String)], selected: String?) {
        setEfforts(
            efforts.map { ShadcnSelectOption(value: $0.value, label: $0.label) },
            selected: selected)
    }
}

extension ShadcnAssistantHost {
    /// Routes a bridge tool event to the panel's live tool list.
    func applyToolEvent(_ event: AssistantToolEvent) {
        let state: AIToolState
        switch event.state {
        case .running: state = .inputAvailable
        case .completed: state = .outputAvailable
        case .failed: state = .outputError
        }
        model.applyTool(
            id: event.id, name: event.name, state: state,
            input: event.input, output: event.output, errorText: event.errorText)
    }
}
