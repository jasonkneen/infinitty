import AIElementsUI
import AppKit
import ShadcnUI
import SwiftUI

/// Backing store for the ShadKit transcript.
///
/// `PetAssistant` owns the conversation as `[AssistantChatMessage]` plus a
/// separate live tail while a request is in flight. This turns both into the
/// `UIMessage` list the AI Elements views render, so the in-flight answer
/// streams as real markdown instead of a one-line indicator.
@MainActor
final class ShadcnTranscriptModel: ObservableObject {
    @Published var messages: [UIMessage] = []
    /// Text of the answer currently arriving, if any.
    @Published var streamingText: String?
    @Published var isThinking = false
    @Published var thinkingLabel = "Thinking"
    /// Tool calls for the turn in flight, in the order they started.
    @Published var tools: [UIToolPart] = []

    /// Changes whenever anything visible changes, so the conversation knows to
    /// stay pinned to the bottom.
    var streamToken: Int {
        messages.count &* 100_000
            &+ (streamingText?.count ?? 0)
            &+ (isThinking ? 1 : 0)
            &+ tools.count
    }

    /// Folds a bridge event into the live tool list. A result carries no name,
    /// so it updates the call it matches rather than replacing it.
    func apply(_ event: AssistantToolEvent) {
        let state: AIToolState
        switch event.state {
        case .running: state = .inputAvailable
        case .completed: state = .outputAvailable
        case .failed: state = .outputError
        }

        if let index = tools.firstIndex(where: { $0.id == event.id }) {
            tools[index].state = state
            if let output = event.output { tools[index].output = output }
            if let errorText = event.errorText { tools[index].errorText = errorText }
            if !event.name.isEmpty { tools[index].type = "tool-" + event.name }
        } else {
            tools.append(
                UIToolPart(
                    id: event.id,
                    type: "tool-" + (event.name.isEmpty ? "tool" : event.name),
                    state: state,
                    input: event.input,
                    output: event.output,
                    errorText: event.errorText))
        }
    }

    func apply(_ transcript: [AssistantChatMessage]) {
        messages = transcript.enumerated().map { index, message in
            UIMessage(
                // Index-based so a growing transcript keeps stable identities
                // and SwiftUI doesn't rebuild every row on each append.
                id: "turn-\(index)",
                role: Self.role(for: message.role),
                text: message.text
            )
        }
    }

    /// `PetAssistant` labels the user's turns "You"; everything else is the
    /// assistant speaking.
    private static func role(for raw: String) -> AIMessageRole {
        raw.caseInsensitiveCompare("You") == .orderedSame ? .user : .assistant
    }
}

/// The transcript itself.
private struct ShadcnTranscriptView: View {
    @ObservedObject var model: ShadcnTranscriptModel

    var body: some View {
        AIConversation(streamToken: model.streamToken) {
            ForEach(model.messages) { message in
                AIMessageView(message: message, onCopy: { copy($0.text) })
            }

            // Tool calls for the turn in flight, above the answer they feed.
            if !model.tools.isEmpty {
                AIMessage(.assistant) {
                    ForEach(model.tools) { tool in
                        AITool(name: tool.name, state: tool.state) {
                            if let input = tool.input { AIToolInput(json: input) }
                            AIToolOutput(output: tool.output, errorText: tool.errorText)
                        }
                    }
                }
            }

            // The in-flight answer. Rendered as a normal assistant turn so
            // markdown, lists and code blocks appear as they stream.
            if let streamingText, !streamingText.isEmpty {
                AIMessageView(
                    message: UIMessage(id: "in-flight", role: .assistant, text: streamingText)
                )
            } else if model.isThinking {
                AIMessage(.assistant) {
                    HStack(spacing: Space.x2) {
                        AILoader(size: 14)
                        AIShimmer(model.thinkingLabel, duration: 1.2)
                    }
                }
            }
        }
    }

    private var streamingText: String? { model.streamingText }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// AppKit wrapper so `PetAssistantPanelView` can drop the SwiftUI transcript in
/// where its `NSScrollView` sat.
final class ShadcnTranscriptHostView: NSView {
    private let model = ShadcnTranscriptModel()
    private var host: NSHostingView<AnyView>?
    private var toolEventSubscription: AssistantToolEventBus.Subscription?
    private var observedToolScopeID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = ShadcnTranscriptView(model: model)
            // The assistant panel is a dark surface, so the palette is pinned
            // rather than following the system appearance.
            .environment(\.colorScheme, .dark)
            // A sidebar is a dense surface; the web type scale reads oversized
            // there, and a 64pt resting composer looks like an empty box that
            // then shrinks once content arrives.
            .shadcnTheme(ShadcnTheme(typography: .compact()))

        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        host = hosting
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    // MARK: Feeds mirroring PetAssistantPanelView's existing API

    func setMessages(_ messages: [AssistantChatMessage]) {
        MainActor.assumeIsolated { model.apply(messages) }
    }

    func setStreamingText(_ text: String?) {
        MainActor.assumeIsolated { model.streamingText = text }
    }

    func setThinking(_ thinking: Bool, label: String?) {
        MainActor.assumeIsolated {
            model.isThinking = thinking
            if let label { model.thinkingLabel = label }
            if !thinking { model.streamingText = nil }
            // A new turn starts with no tool calls; the finished ones are
            // already part of the answer that got appended.
            if thinking { model.tools.removeAll() }
        }
    }

    /// Routes bridge tool events into the transcript. A stored subscription
    /// keeps this host independent from every other open Chat surface.
    func observeToolEvents(_ observe: Bool, scopeID: String? = nil) {
        toolEventSubscription?.cancel()
        toolEventSubscription = nil
        let nextScopeID = observe ? scopeID : nil
        if observedToolScopeID != nextScopeID {
            MainActor.assumeIsolated { model.tools.removeAll() }
        }
        observedToolScopeID = nextScopeID
        guard observe else { return }
        toolEventSubscription = AssistantToolEventBus.subscribe(scopeID: scopeID) {
            [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated { self.model.apply(event) }
        }
    }

    var isEmpty: Bool {
        MainActor.assumeIsolated {
            model.messages.isEmpty && !model.isThinking
                && (model.streamingText?.isEmpty ?? true)
        }
    }
}

// MARK: - Opt-in

enum ShadcnChatFeature {
    /// Renders the assistant transcript and composer with ShadKit.
    ///
    /// This is the default. The AppKit bubble stack is still built and one env
    /// var away, so a rendering regression has an immediate workaround:
    ///
    ///     INFINITTY_LEGACY_CHAT=1 open -a Infinitty
    /// Lets a test pin which panel it is asserting against, rather than
    /// depending on whichever is currently the default.
    nonisolated(unsafe) static var overrideForTesting: Bool?

    static var isEnabled: Bool {
        if let overrideForTesting { return overrideForTesting }
        return ProcessInfo.processInfo.environment["INFINITTY_LEGACY_CHAT"] != "1"
    }

    /// Renders Settings with ShadKit. Default; the AppKit form remains at:
    ///
    ///     INFINITTY_LEGACY_SETTINGS=1 open -a Infinitty
    static var usesShadcnSettings: Bool {
        ProcessInfo.processInfo.environment["INFINITTY_LEGACY_SETTINGS"] != "1"
    }
}
