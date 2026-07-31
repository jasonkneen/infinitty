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
    /// Host-fed identity, separate from the eagerly updated SwiftUI binding.
    /// Comparing against `model.activeThreadId` would miss user-driven switches.
    private var lastPresentedThreadID: String?

    init() {
        let model = self.model
        view = ShadcnHostingView(
            theme: ShadcnTheme(typography: .compact()),
            colorScheme: .dark,
            paintsBackground: true
        ) {
            // Panel fills proposed size (see AIAssistantPanel body) so a
            // popover's contentSize isn't overflow-clipped at the footer.
            AIAssistantPanel(model: model, showsHeader: false)
        }
    }

    // MARK: Feeds mirroring PetAssistantPanelView

    func setMessages(_ messages: [AssistantChatMessage]) {
        model.messages = messages.enumerated().map { index, message in
            UIMessage(
                id: "turn-\(index)",
                role: message.role.caseInsensitiveCompare("You") == .orderedSame
                    ? .user : .assistant,
                text: message.text)
        }
    }

    func setQueuedMessages(_ queued: [String]) { model.queued = queued }

    func setStreamingText(_ text: String?) { model.streamingText = text }

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

    func setModels(_ models: [ShadcnSelectOption<String>], selected: String?) {
        model.models = models
        model.model = selected
    }

    func setEfforts(_ efforts: [ShadcnSelectOption<String>], selected: String?) {
        model.efforts = efforts
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
