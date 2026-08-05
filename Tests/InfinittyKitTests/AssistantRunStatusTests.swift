import AIElementsUI
import AppKit
import SwiftUI
import XCTest
@testable import InfinittyKit

private struct AssistantStatusWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AssistantStatusWidthProbe: View {
    @ObservedObject var model: AIAssistantPanelModel
    @ObservedObject var runState: AssistantRunPresentationState
    let onWidth: (CGFloat) -> Void

    var body: some View {
        AssistantRunTopBarStatus(model: model, runState: runState)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: AssistantStatusWidthPreferenceKey.self,
                        value: proxy.size.width)
                }
            }
            .onPreferenceChange(AssistantStatusWidthPreferenceKey.self) {
                onWidth($0)
            }
    }
}

@MainActor
final class AssistantRunStatusTests: XCTestCase {
    func testReportsModeModelEffortAndHonestVisibleTokenEstimate() {
        let model = AIAssistantPanelModel()
        model.terminalAvailable = true
        model.terminalAccessEnabled = true
        model.model = "gpt-5.6-luna"
        model.effort = "Max"
        model.messages = [
            UIMessage(role: .user, text: "12345678"),
            UIMessage(role: .assistant, text: "1234"),
        ]

        let status = AssistantRunStatusSnapshot(model: model)

        XCTAssertEqual(status.modeLabel, "TERMINAL")
        XCTAssertEqual(status.modelLabel, "gpt-5.6-luna")
        XCTAssertEqual(status.effortLabel, "Max")
        XCTAssertEqual(status.visibleEffortLabel, "Effort Max")
        XCTAssertEqual(status.estimatedVisibleTokens, 3)
        XCTAssertEqual(status.visibleTokenLabel, "~3 visible tokens")
        XCTAssertTrue(status.accessibilityValue.contains("approximately 3"))
    }

    func testAutoSelectionShowsResolvedProviderProvenance() {
        let model = AIAssistantPanelModel()
        model.model = "Auto"
        model.effort = "Auto"
        model.streamingAuthor = "Claude"

        XCTAssertEqual(
            AssistantRunStatusSnapshot(model: model).modelLabel,
            "Auto → Claude")

        model.streamingAuthor = nil
        model.messages = [
            UIMessage(role: .assistant, text: "Timed out", author: "Claude"),
        ]
        XCTAssertEqual(
            AssistantRunStatusSnapshot(model: model).modelLabel,
            "Auto → Claude",
            "resolved identity remains visible after the run finishes")
    }

    func testLifecyclePrecedenceIsExplicit() {
        let model = AIAssistantPanelModel()
        XCTAssertEqual(AssistantRunStatusSnapshot(model: model).phase, .ready)

        model.queued = ["next"]
        XCTAssertEqual(AssistantRunStatusSnapshot(model: model).phase, .queued)

        model.isThinking = true
        XCTAssertEqual(AssistantRunStatusSnapshot(model: model).phase, .thinking)

        model.streamingText = "answer"
        XCTAssertEqual(AssistantRunStatusSnapshot(model: model).phase, .responding)

        model.applyTool(id: "tool", name: "search", state: .inputAvailable)
        var status = AssistantRunStatusSnapshot(model: model)
        XCTAssertEqual(status.phase, .usingTool)
        XCTAssertEqual(status.activityLabel, "USING search")

        model.applyTool(id: "tool", name: "search", state: .approvalRequested)
        status = AssistantRunStatusSnapshot(model: model)
        XCTAssertEqual(status.phase, .awaitingApproval)
        XCTAssertEqual(status.activityLabel, "APPROVE search")

        model.applyTool(id: "tool", name: "search", state: .outputError)
        model.streamingText = nil
        model.isThinking = false
        status = AssistantRunStatusSnapshot(model: model)
        XCTAssertEqual(status.phase, .toolFailed)
        XCTAssertEqual(status.activityLabel, "FAILED search")

        model.applyTool(id: "tool", name: "search", state: .outputAvailable)
        XCTAssertEqual(AssistantRunStatusSnapshot(model: model).phase, .queued)
        model.queued = []
        XCTAssertEqual(AssistantRunStatusSnapshot(model: model).phase, .ready)
    }

    func testCompactTopBarHidesReadyActivityButKeepsUsage() {
        let model = AIAssistantPanelModel()
        model.model = "Codex · Sol"
        model.effort = "High"

        let content = AssistantRunTopBarStatusContent(
            snapshot: AssistantRunStatusSnapshot(model: model))

        XCTAssertEqual(content.phase, .ready)
        XCTAssertNil(content.activityLabel)
        XCTAssertEqual(content.usageLabel, "~0 visible tokens")
        XCTAssertEqual(content.compactUsageLabel, "~0 tokens")
        XCTAssertNil(content.costLabel)
        XCTAssertNil(content.queuedLabel)
        XCTAssertEqual(content.compactMetricsLabel, "~0 tokens")
        XCTAssertTrue(content.accessibilityValue.contains("Codex · Sol"))
        XCTAssertTrue(content.accessibilityValue.contains("High effort"))
        XCTAssertTrue(content.accessibilityValue.contains("CHAT"))
    }

    func testCompactTopBarMapsActivityUsageCostAndQueueInPriorityOrder() {
        let model = AIAssistantPanelModel()
        model.isThinking = true
        model.queued = ["second", "third"]
        let runState = AssistantRunPresentationState()
        var telemetry = AssistantRunTelemetrySnapshot()
        telemetry.beginRun()
        telemetry.apply(AssistantRunEvent(
            provenance: .providerReported,
            update: .usage(AssistantRunEvent.Usage(
                contextUsedTokens: 512,
                contextWindowTokens: 16_384,
                cost: AssistantRunEvent.Cost(
                    amount: Decimal(string: "0.01")!, currency: "usd")))))
        runState.setTelemetry(telemetry)

        let content = AssistantRunTopBarStatusContent(
            snapshot: AssistantRunStatusSnapshot(
                model: model, runState: runState))

        XCTAssertEqual(content.phase, .thinking)
        XCTAssertEqual([
            content.activityLabel,
            content.usageLabel,
            content.costLabel,
            content.queuedLabel,
        ].compactMap { $0 }, [
            "THINKING", "512 / 16.4K context", "USD 0.01", "2 queued",
        ])
        XCTAssertEqual(
            content.compactMetricsLabel,
            "512/16.4K ctx · USD 0.01 · 2 queued")
    }

    func testComplete320PointTopBarProtectsActualStatusBeforeThreadTitle() {
        let model = AIAssistantPanelModel()
        model.threads = [
            .init(
                value: "one",
                label: "A deliberately long thread title that must truncate"),
            .init(value: "two", label: "Second thread"),
        ]
        model.activeThreadId = "one"
        model.roster = [
            .init(id: "claude", name: "Claude", detail: "Sonnet", isEnabled: true),
            .init(id: "codex", name: "Codex", detail: "GPT", isEnabled: true),
        ]
        model.isThinking = true
        model.queued = ["second", "third"]
        let runState = AssistantRunPresentationState()
        var telemetry = AssistantRunTelemetrySnapshot()
        telemetry.beginRun()
        telemetry.apply(AssistantRunEvent(
            provenance: .providerReported,
            update: .usage(AssistantRunEvent.Usage(
                contextUsedTokens: 512,
                contextWindowTokens: 16_384,
                cost: AssistantRunEvent.Cost(
                    amount: Decimal(string: "0.01")!, currency: "usd")))))
        runState.setTelemetry(telemetry)
        let chrome = AIAssistantPanelChrome(
            showsHeader: false,
            rosterPresentation: .menu,
            density: .compact)
        var statusWidth: CGFloat = 0
        let host = NSHostingView(
            rootView: AIAssistantPanelTopBar(model: model, chrome: chrome) {
                AssistantStatusWidthProbe(
                    model: model,
                    runState: runState,
                    onWidth: { statusWidth = $0 })
            })
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        let measured = pollRunLoop(timeout: 1.0) {
            host.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            return statusWidth > 0
        }

        XCTAssertTrue(measured)
        XCTAssertEqual(host.frame.width, 320, accuracy: 0.5)
        let compactStatusText = "512/16.4K ctx · USD 0.01 · 2 queued"
        let minimumReadableStatusWidth =
            (compactStatusText as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 12),
            ]).width * 0.65 + 16
        XCTAssertGreaterThanOrEqual(
            statusWidth, minimumReadableStatusWidth,
            "the actual usage/cost/queue status must fit at its allowed scale")
    }

    func testBrokerApprovalOutranksStreamingAndToolActivity() {
        let model = AIAssistantPanelModel()
        let runState = AssistantRunPresentationState()
        model.isThinking = true
        model.streamingText = "partial answer"
        model.applyTool(id: "tool", name: "search", state: .inputAvailable)
        runState.approvalRequests = [AssistantApprovalRequest(
            scopeID: "conversation",
            provider: "Claude",
            kind: .toolUse,
            toolName: "Write")]

        let status = AssistantRunStatusSnapshot(
            model: model, runState: runState)

        XCTAssertEqual(status.phase, .awaitingApproval)
        XCTAssertEqual(status.activityLabel, "APPROVE Write")
    }

    func testIncludesToolPayloadsAndAgentCounts() {
        let model = AIAssistantPanelModel()
        model.applyTool(
            id: "tool", name: "read", state: .outputAvailable,
            input: "1234", output: "12345678")
        model.roster = [
            AIAssistantRosterEntry(id: "a", name: "A", detail: "one"),
            AIAssistantRosterEntry(id: "b", name: "B", detail: "two"),
            AIAssistantRosterEntry(id: "c", name: "C", detail: "three", isEnabled: false),
        ]

        let status = AssistantRunStatusSnapshot(model: model)
        XCTAssertEqual(status.estimatedVisibleTokens, 3)
        XCTAssertEqual(status.enabledAgentCount, 2)
        XCTAssertTrue(status.accessibilityValue.contains("2 agents"))
    }

    func testEarlierFailureDoesNotHideActionableWork() {
        let model = AIAssistantPanelModel()
        model.applyTool(id: "failed", name: "read", state: .outputError)
        model.applyTool(id: "running", name: "build", state: .inputAvailable)

        var status = AssistantRunStatusSnapshot(model: model)
        XCTAssertEqual(status.phase, .usingTool)
        XCTAssertEqual(status.activityLabel, "USING build")

        model.applyTool(id: "approval", name: "write", state: .approvalRequested)
        status = AssistantRunStatusSnapshot(model: model)
        XCTAssertEqual(status.phase, .awaitingApproval)
        XCTAssertEqual(status.activityLabel, "APPROVE write")
    }

    func testDenialIsNotReportedAsFailure() {
        let model = AIAssistantPanelModel()
        model.applyTool(id: "tool", name: "write", state: .outputDenied)

        let status = AssistantRunStatusSnapshot(model: model)
        XCTAssertEqual(status.phase, .toolDenied)
        XCTAssertEqual(status.activityLabel, "DENIED write")
    }

    func testRuntimeFailureDoesNotMasqueradeAsReady() {
        let model = AIAssistantPanelModel()
        let runState = AssistantRunPresentationState()
        runState.lastRunFailed = true

        var status = AssistantRunStatusSnapshot(
            model: model, runState: runState)
        XCTAssertEqual(status.phase, .runFailed)
        XCTAssertEqual(status.activityLabel, "RUN FAILED")

        model.queued = ["retry"]
        status = AssistantRunStatusSnapshot(
            model: model, runState: runState)
        XCTAssertEqual(status.phase, .queued)
    }

    func testProviderUsageReplacesEstimateWithoutInventingContextOccupancy() {
        let model = AIAssistantPanelModel()
        model.messages = [UIMessage(role: .user, text: "12345678")]
        let runState = AssistantRunPresentationState()
        var telemetry = AssistantRunTelemetrySnapshot()
        telemetry.beginRun()
        telemetry.apply(AssistantRunEvent(
            provenance: .providerReported,
            update: .usage(AssistantRunEvent.Usage(
                lastTokens: AssistantRunEvent.TokenCounts(
                    input: 101, output: 29, total: 157),
                cumulativeTokens: AssistantRunEvent.TokenCounts(total: 583),
                contextWindowTokens: 200_000))))
        runState.setTelemetry(telemetry)

        var status = AssistantRunStatusSnapshot(
            model: model, runState: runState)
        XCTAssertEqual(status.estimatedVisibleTokens, 2)
        XCTAssertEqual(status.usageLabel, "157 turn tokens")
        XCTAssertTrue(status.usageHelp.contains("latest turn"))
        XCTAssertFalse(status.usageLabel.contains("context"))
        XCTAssertTrue(status.accessibilityValue.contains("provider reported"))

        telemetry.apply(AssistantRunEvent(
            provenance: .providerReported,
            update: .usage(AssistantRunEvent.Usage(
                contextUsedTokens: 321,
                contextWindowTokens: 8_192,
                cost: AssistantRunEvent.Cost(
                    amount: Decimal(string: "0.0125")!, currency: "eur")))))
        runState.setTelemetry(telemetry)
        status = AssistantRunStatusSnapshot(model: model, runState: runState)

        XCTAssertEqual(status.usageLabel, "321 / 8.2K context")
        XCTAssertEqual(status.costLabel, "EUR 0.0125")
        XCTAssertTrue(status.usageHelp.contains("321 of 8192"))
    }

    func testSafeReasoningSummaryFoldIsBoundedAndCompletionIsAuthoritative() {
        var telemetry = AssistantRunTelemetrySnapshot()
        telemetry.beginRun()
        let serial = telemetry.runSerial
        telemetry.apply(AssistantRunEvent(
            provenance: .providerReported,
            update: .reasoningSummary(.init(
                state: .delta, text: "Inspecting ",
                itemID: "reasoning-1", summaryIndex: 0))))
        telemetry.apply(AssistantRunEvent(
            provenance: .providerReported,
            update: .reasoningSummary(.init(
                state: .delta, text: "the failure",
                itemID: "reasoning-1", summaryIndex: 0))))

        XCTAssertEqual(telemetry.reasoningSummary, "Inspecting the failure")
        XCTAssertTrue(telemetry.reasoningIsStreaming)

        telemetry.apply(AssistantRunEvent(
            provenance: .providerReported,
            update: .reasoningSummary(.init(
                state: .completed, text: "Verified timeout root cause",
                itemID: "reasoning-1"))))
        XCTAssertEqual(telemetry.reasoningSummary, "Verified timeout root cause")
        XCTAssertFalse(telemetry.reasoningIsStreaming)

        telemetry.beginRun()
        XCTAssertEqual(telemetry.runSerial, serial + 1)
        XCTAssertNil(telemetry.reasoningSummary)
        telemetry.apply(AssistantRunEvent(
            provenance: .providerReported,
            update: .reasoningSummary(.init(
                state: .completed, text: String(repeating: "x", count: 20_000)))))
        XCTAssertLessThanOrEqual(
            telemetry.reasoningSummary?.utf8.count ?? .max, 12_000)
        XCTAssertTrue(telemetry.reasoningSummary?.contains("summary truncated") == true)
    }

    private func pollRunLoop(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        } while Date() < deadline
        return condition()
    }
}
