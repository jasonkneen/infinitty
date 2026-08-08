import AIElementsUI
import AppKit
import ShadcnUI
import SwiftUI

enum AssistantRunPhase: Equatable {
    case ready
    case queued
    case thinking
    case responding
    case usingTool
    case awaitingApproval
    case toolFailed
    case toolDenied
    case runFailed

    var label: String {
        switch self {
        case .ready: "READY"
        case .queued: "QUEUED"
        case .thinking: "THINKING"
        case .responding: "RESPONDING"
        case .usingTool: "USING TOOL"
        case .awaitingApproval: "APPROVAL"
        case .toolFailed: "TOOL FAILED"
        case .toolDenied: "TOOL DENIED"
        case .runFailed: "RUN FAILED"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: ShadcnIcon.checkCircle
        case .queued: ShadcnIcon.clock
        case .thinking: ShadcnIcon.brain
        case .responding: ShadcnIcon.sparkles
        case .usingTool: ShadcnIcon.wrench
        case .awaitingApproval: ShadcnIcon.shield
        case .toolFailed, .toolDenied: ShadcnIcon.xCircle
        case .runFailed: ShadcnIcon.alertTriangle
        }
    }

    var badgeVariant: ShadcnBadgeVariant {
        switch self {
        case .ready: .outline
        case .toolFailed, .runFailed: .destructive
        case .toolDenied: .outline
        case .thinking, .usingTool, .queued: .secondary
        case .responding, .awaitingApproval: .primary
        }
    }
}

@MainActor
final class AssistantRunPresentationState: ObservableObject {
    @Published var lastRunFailed = false
    @Published var approvalRequests: [AssistantApprovalRequest] = []
    @Published var usage: AssistantRunEvent.Usage?
    @Published var usageProvenance: AssistantRunEvent.Provenance?
    @Published var reasoningSummary: String?
    @Published var reasoningIsStreaming = false
    @Published var reasoningRunID = UUID()

    func setTelemetry(_ telemetry: AssistantRunTelemetrySnapshot) {
        usage = telemetry.usage
        usageProvenance = telemetry.usageProvenance
        reasoningSummary = telemetry.reasoningSummary
        reasoningIsStreaming = telemetry.reasoningIsStreaming
        reasoningRunID = telemetry.runID
    }
}

/// A truthful, provider-neutral summary of what the built-in Chat can prove.
///
/// Context is deliberately labelled as an estimate: until bridges expose
/// provider usage, only the visible transcript and tool payloads are known.
struct AssistantRunStatusSnapshot: Equatable {
    let modeLabel: String
    let phase: AssistantRunPhase
    let activityLabel: String
    let modelLabel: String
    let effortLabel: String
    let estimatedVisibleTokens: Int
    let usageLabel: String
    let compactUsageLabel: String
    let usageHelp: String
    let costLabel: String?
    let queuedCount: Int
    let enabledAgentCount: Int

    @MainActor
    init(
        model: AIAssistantPanelModel,
        runState: AssistantRunPresentationState? = nil
    ) {
        modeLabel = model.terminalAccessEnabled ? "TERMINAL" : "CHAT"
        let selectedModel = model.model ?? model.agent ?? "Auto"
        let resolvedAuthor = model.streamingAuthor
            ?? model.messages.reversed().compactMap(\.author).first
        if Self.isAutomaticSelection(selectedModel),
           let resolvedAuthor,
           !Self.isAutomaticSelection(resolvedAuthor) {
            modelLabel = "\(selectedModel) → \(resolvedAuthor)"
        } else {
            modelLabel = selectedModel
        }
        effortLabel = model.effort ?? "Auto"
        queuedCount = model.queued.count
        enabledAgentCount = model.roster.filter(\.isEnabled).count

        let terminalTool = model.tools.last {
            $0.state == .outputError || $0.state == .outputDenied
        }
        let approvalRequest = runState?.approvalRequests.last
        let approvalTool = model.tools.last { $0.state == .approvalRequested }
        let runningTool = model.tools.last {
            $0.state == .inputStreaming || $0.state == .inputAvailable
        }

        if let approvalRequest {
            phase = .awaitingApproval
            activityLabel = "APPROVE \(approvalRequest.toolName)"
        } else if let approvalTool {
            phase = .awaitingApproval
            activityLabel = "APPROVE \(approvalTool.name)"
        } else if let runningTool {
            phase = .usingTool
            activityLabel = "USING \(runningTool.name)"
        } else if let streamingText = model.streamingText, !streamingText.isEmpty {
            phase = .responding
            activityLabel = AssistantRunPhase.responding.label
        } else if model.isThinking {
            phase = .thinking
            activityLabel = AssistantRunPhase.thinking.label
        } else if let terminalTool {
            if terminalTool.state == .outputDenied {
                phase = .toolDenied
                activityLabel = "DENIED \(terminalTool.name)"
            } else {
                phase = .toolFailed
                activityLabel = "FAILED \(terminalTool.name)"
            }
        } else if !model.queued.isEmpty {
            phase = .queued
            activityLabel = AssistantRunPhase.queued.label
        } else if runState?.lastRunFailed == true {
            phase = .runFailed
            activityLabel = AssistantRunPhase.runFailed.label
        } else {
            phase = .ready
            activityLabel = AssistantRunPhase.ready.label
        }

        let transcriptBytes = model.messages.reduce(into: 0) {
            $0 += $1.text.utf8.count
        }
        let streamingBytes = model.streamingText?.utf8.count ?? 0
        let toolBytes = model.tools.reduce(into: 0) { total, tool in
            total += tool.input?.utf8.count ?? 0
            total += tool.output?.utf8.count ?? 0
            total += tool.errorText?.utf8.count ?? 0
        }
        let visibleBytes = transcriptBytes + streamingBytes + toolBytes
        estimatedVisibleTokens = visibleBytes == 0
            ? 0
            : max(1, Int(ceil(Double(visibleBytes) / 4.0)))

        if runState?.usageProvenance == .providerReported,
           let usage = runState?.usage,
           let reported = Self.providerUsageLabel(usage) {
            usageLabel = reported.label
            compactUsageLabel = reported.compactLabel
            usageHelp = reported.help
        } else {
            usageLabel = "~\(Self.compactCount(estimatedVisibleTokens)) visible tokens"
            compactUsageLabel = "~\(Self.compactCount(estimatedVisibleTokens)) tokens"
            usageHelp = "Estimated from visible messages and tool data; the provider did not report current usage"
        }
        if runState?.usageProvenance == .providerReported,
           let cost = runState?.usage?.cost {
            costLabel = "\(cost.currency.uppercased()) \(NSDecimalNumber(decimal: cost.amount).stringValue)"
        } else {
            costLabel = nil
        }
    }

    /// Compatibility name retained for focused host tests. The value is an
    /// estimate only when the provider did not report usage.
    var visibleTokenLabel: String { usageLabel }

    var visibleEffortLabel: String { "Effort \(effortLabel)" }

    var accessibilityValue: String {
        var parts = [modeLabel, activityLabel, modelLabel, "\(effortLabel) effort"]
        if usageLabel.hasPrefix("~") {
            parts.append("approximately \(estimatedVisibleTokens) visible tokens")
        } else {
            parts.append(usageLabel + ", provider reported")
        }
        if let costLabel { parts.append(costLabel) }
        if queuedCount > 0 { parts.append("\(queuedCount) queued") }
        if enabledAgentCount > 1 { parts.append("\(enabledAgentCount) agents") }
        return parts.joined(separator: ", ")
    }

    private static func compactCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return String(value)
    }

    private static func providerUsageLabel(
        _ usage: AssistantRunEvent.Usage
    ) -> (label: String, compactLabel: String, help: String)? {
        if let used = usage.contextUsedTokens,
           let window = usage.contextWindowTokens {
            return (
                "\(compactCount(used)) / \(compactCount(window)) context",
                "\(compactCount(used))/\(compactCount(window)) ctx",
                "Provider-reported context occupancy: \(used) of \(window) tokens")
        }
        if let used = usage.contextUsedTokens {
            return (
                "\(compactCount(used)) context tokens",
                "\(compactCount(used)) ctx",
                "Provider-reported context occupancy: \(used) tokens")
        }
        if let total = usage.lastTokens?.total {
            var help = "Provider-reported usage for the latest turn: \(total) tokens"
            if let window = usage.contextWindowTokens {
                help += "; model context capacity: \(window) tokens"
            }
            return (
                "\(compactCount(total)) turn tokens",
                "\(compactCount(total)) turn",
                help)
        }
        if let input = usage.lastTokens?.input,
           let output = usage.lastTokens?.output {
            return (
                "\(compactCount(input)) in · \(compactCount(output)) out",
                "\(compactCount(input)) in·\(compactCount(output)) out",
                "Provider-reported latest-turn tokens: \(input) input and \(output) output")
        }
        if let total = usage.cumulativeTokens?.total {
            return (
                "\(compactCount(total)) session tokens",
                "\(compactCount(total)) session",
                "Provider-reported cumulative session usage: \(total) tokens")
        }
        return nil
    }

    private static func isAutomaticSelection(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines).lowercased()
        return normalized == "auto" || normalized.hasPrefix("auto ·")
    }
}

/// The subset of run status that earns permanent space in Titerm's compact
/// top bar. Model, execution mode and effort remain in the composer's controls
/// and in `accessibilityValue`; READY is intentionally quiet.
struct AssistantRunTopBarStatusContent: Equatable {
    let phase: AssistantRunPhase
    let activityLabel: String?
    let usageLabel: String
    let compactUsageLabel: String
    let usageHelp: String
    let costLabel: String?
    let queuedLabel: String?
    let accessibilityValue: String

    var compactMetricsLabel: String {
        [compactUsageLabel, costLabel, queuedLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    init(snapshot: AssistantRunStatusSnapshot) {
        phase = snapshot.phase
        activityLabel = snapshot.phase == .ready ? nil : snapshot.activityLabel
        usageLabel = snapshot.usageLabel
        compactUsageLabel = snapshot.compactUsageLabel
        usageHelp = snapshot.usageHelp
        costLabel = snapshot.costLabel
        queuedLabel = snapshot.queuedCount > 0
            ? "\(snapshot.queuedCount) queued" : nil
        accessibilityValue = snapshot.accessibilityValue
    }

}

struct AssistantRunDeck: View {
    @ObservedObject var model: AIAssistantPanelModel
    @ObservedObject var runState: AssistantRunPresentationState
    let chrome: AIAssistantPanelChrome

    var body: some View {
        VStack(spacing: 0) {
            AIAssistantPanelTopBar(model: model, chrome: chrome) {
                AssistantRunTopBarStatus(model: model, runState: runState)
            }
            ShadcnSeparator()
            if let reasoning = runState.reasoningSummary,
               !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AIReasoning(
                    content: reasoning,
                    isStreaming: runState.reasoningIsStreaming,
                    defaultOpen: runState.reasoningIsStreaming)
                    .id(runState.reasoningRunID)
                    .padding(.horizontal, Space.x3)
                    .padding(.vertical, Space.x2)
                ShadcnSeparator()
            }
            if !runState.approvalRequests.isEmpty {
                AssistantApprovalDeck(requests: runState.approvalRequests)
                ShadcnSeparator()
            }
            AIAssistantPanel(model: model, chrome: chrome)
        }
    }
}

private struct AssistantApprovalDeck: View {
    let requests: [AssistantApprovalRequest]

    var body: some View {
        ScrollView(.vertical, showsIndicators: requests.count > 1) {
            LazyVStack(spacing: Space.x2) {
                ForEach(requests) { request in
                    AssistantApprovalCard(request: request)
                }
            }
            .padding(.horizontal, Space.x3)
            .padding(.vertical, Space.x2)
        }
        .frame(maxHeight: 300)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pending agent approvals")
    }
}

private struct AssistantApprovalCard: View {
    let request: AssistantApprovalRequest

    @Environment(\.shadcnPalette) private var palette
    @Environment(\.shadcnTheme) private var theme

    var body: some View {
        AITool(
            name: "\(request.provider) · \(request.toolName)",
            state: .approvalRequested,
            defaultOpen: true
        ) {
            if let input = request.input, !input.isEmpty {
                AIToolInput(json: input)
            }
            VStack(alignment: .leading, spacing: Space.x2) {
                Text(request.message)
                    .font(theme.typography.sans(theme.typography.sm))
                    .foregroundStyle(palette.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.x2) {
                    Spacer(minLength: 0)
                    if request.availableDecisions.contains(.deny) {
                        ShadcnButton("Deny", variant: .outline, size: .small) {
                            resolve(.deny)
                        }
                    }
                    if request.availableDecisions.contains(.allowSession) {
                        ShadcnButton(
                            "Allow for session", variant: .secondary, size: .small
                        ) {
                            resolve(.allowSession)
                        }
                    }
                    if request.availableDecisions.contains(.allowOnce) {
                        ShadcnButton("Allow once", size: .small) {
                            resolve(.allowOnce)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.x3)
            .padding(.vertical, Space.x2_5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resolve(_ decision: AssistantApprovalDecision) {
        _ = AssistantApprovalBroker.shared.resolve(
            id: request.id, scopeID: request.scopeID, decision: decision)
    }
}

struct AssistantRunTopBarStatus: View {
    @ObservedObject var model: AIAssistantPanelModel
    @ObservedObject var runState: AssistantRunPresentationState

    @Environment(\.shadcnPalette) private var palette
    @Environment(\.shadcnTheme) private var theme

    var body: some View {
        let snapshot = AssistantRunStatusSnapshot(
            model: model, runState: runState)
        let content = AssistantRunTopBarStatusContent(snapshot: snapshot)
        ViewThatFits(in: .horizontal) {
            statusItems(content, includeCost: true, includeQueue: true)
            compactStatus(content)
        }
        // Combine only this accessory's telemetry, never the canonical top bar
        // around it: the thread and New Chat controls remain distinct elements.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent run status")
        .accessibilityValue(content.accessibilityValue)
    }

    private func compactStatus(
        _ content: AssistantRunTopBarStatusContent
    ) -> some View {
        HStack(spacing: Space.x1) {
            if let activityLabel = content.activityLabel {
                ShadcnIconView(content.phase.systemImage, size: 12)
                    .foregroundStyle(palette.mutedForeground)
                    .help(activityLabel)
            }
            Text(content.compactMetricsLabel)
                .font(theme.typography.sans(theme.typography.xs))
                .foregroundStyle(palette.mutedForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .allowsTightening(true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                .help(content.accessibilityValue)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func statusItems(
        _ content: AssistantRunTopBarStatusContent,
        includeCost: Bool,
        includeQueue: Bool
    ) -> some View {
        HStack(spacing: Space.x1_5) {
            if let activityLabel = content.activityLabel {
                activityBadge(activityLabel, phase: content.phase)
            }
            statusText(content.usageLabel, help: content.usageHelp)
            if includeCost, let costLabel = content.costLabel {
                statusText(costLabel, help: "Provider-reported run cost")
            }
            if includeQueue, let queuedLabel = content.queuedLabel {
                statusText(queuedLabel, help: "Queued prompts")
            }
        }
    }

    private func activityBadge(
        _ label: String, phase: AssistantRunPhase
    ) -> some View {
        ShadcnBadge(
            label,
            systemImage: phase.systemImage,
            variant: phase.badgeVariant)
    }

    private func statusText(_ text: String, help: String) -> some View {
        Text(text)
            .font(theme.typography.sans(theme.typography.xs))
            .foregroundStyle(palette.mutedForeground)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .help(help)
    }
}

/// Replaces `PetAssistantPanelView`'s entire UI with the ShadKit panel.
///
/// The whole surface is swapped rather than a SwiftUI island inserted into the
/// existing constraints — mixed layouts are where the sizing surprises live,
/// and an earlier attempt to nest just the transcript collapsed the panel.
@MainActor
final class ShadcnAssistantHost {
    let model = AIAssistantPanelModel()
    let runState = AssistantRunPresentationState()
    let chrome: AIAssistantPanelChrome
    private(set) var view: ShadcnHostingView<AssistantRunDeck>!
    private var baseTheme: ShadcnTheme
    /// Host-fed identity, separate from the eagerly updated SwiftUI binding.
    /// Comparing against `model.activeThreadId` would miss user-driven switches.
    private var lastPresentedThreadID: String?

    init(
        config: AppConfig = AppConfig(),
        hasExternalNewChatAction: Bool = false
    ) {
        chrome = AIAssistantPanelChrome(
            showsHeader: false,
            hasExternalNewChatAction: hasExternalNewChatAction,
            topBarPlacement: .external,
            rosterPresentation: .menu,
            density: .compact)
        baseTheme = UISurfaceTheme.theme(for: config)
        model.messageFontSize = config.interfaceFontSize
        let model = self.model
        let runState = self.runState
        let chrome = self.chrome
        view = ShadcnHostingView(
            theme: Self.assistantTheme(
                base: baseTheme, interfaceFontSize: config.interfaceFontSize),
            colorScheme: UISurfaceTheme.colorScheme(for: config),
            paintsBackground: true
        ) {
            // Panel fills proposed size (see AIAssistantPanel body) so a
            // popover's contentSize isn't overflow-clipped at the footer.
            AssistantRunDeck(model: model, runState: runState, chrome: chrome)
        }
    }

    func applyAppearance(config: AppConfig) {
        baseTheme = UISurfaceTheme.theme(for: config)
        model.messageFontSize = config.interfaceFontSize
        let model = self.model
        let runState = self.runState
        let chrome = self.chrome
        view.update(
            theme: Self.assistantTheme(
                base: baseTheme, interfaceFontSize: config.interfaceFontSize),
            colorScheme: UISurfaceTheme.colorScheme(for: config),
            paintsBackground: true
        ) {
            AssistantRunDeck(model: model, runState: runState, chrome: chrome)
        }
    }

    /// The ShadKit top bar emits exactly one New Chat action unless an AppKit
    /// presentation explicitly owns it (the dedicated Utility Chat pane).
    var newChatActionCountForTesting: Int {
        chrome.hasExternalNewChatAction ? 0 : 1
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
        runState.lastRunFailed = messages.last?.role == "Failure"
        model.messages = messages.enumerated().map { index, message in
            let role: AIMessageRole
            switch message.role.lowercased() {
            case "you", "user": role = .user
            case "system", "failure": role = .system
            default: role = .assistant
            }
            return UIMessage(
                id: "turn-\(index)",
                role: role,
                text: message.text,
                author: message.author,
                createdAt: message.createdAt)
        }
    }

    func setRunTelemetry(_ telemetry: AssistantRunTelemetrySnapshot) {
        runState.setTelemetry(telemetry)
    }

    func setApprovalRequests(_ requests: [AssistantApprovalRequest]) {
        runState.approvalRequests = requests
    }

    func setQueuedMessages(_ queued: [String]) { model.queued = queued }

    func setStreamingText(_ text: String?) { model.streamingText = text }

    func setRoster(_ agents: [ConfiguredChatAgent]) {
        model.roster = agents.map {
            let model = $0.modelTitle.isEmpty ? $0.provider : $0.modelTitle
            return AIAssistantRosterEntry(
                id: $0.id, name: $0.alias,
                detail: "Model: \(model) · Effort: \($0.effort)",
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
