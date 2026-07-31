import Foundation
import XCTest

@testable import InfinittyKit

final class HeadlessChatRuntimeTests: XCTestCase {
    func testTransportFailureIsVisibleButNeverPublishedAsAgentWork() {
        let failed = expectation(
            description: "headless failure is visible")
        let emissions = HeadlessRuntimeValues<
            CollaborationChatEmission>()
        let runtime = HeadlessChatRuntime(
            id: "chat-cloud-failure",
            participantID: "agent:cloud",
            name: "Remote Agent",
            role: "reviewer",
            workspaceDirectory: "/tmp",
            configuredProvider: "codex",
            configuredModel: "opaque-model",
            config: AppConfig(),
            collaborationMessagePublisher: {
                emissions.append($0)
            },
            backendRunner: {
                _, _, _, _, _, _, _, done in
                done(.failure(
                    "Cloud agent failed: authentication rejected"))
            },
            onStateChange: { state in
                if state == "failed" {
                    failed.fulfill()
                }
            })
        defer { runtime.stop() }

        runtime.submit("perform the approved review")
        wait(for: [failed], timeout: 2)

        let messages =
            runtime.state().threads.first?.messages
        XCTAssertEqual(messages?.map(\.role), ["You", "System"])
        XCTAssertEqual(
            messages?.last?.text,
            "Cloud agent failed: authentication rejected")
        XCTAssertEqual(
            emissions.values.map(\.kind),
            [.humanPrompt, .runtimeFailure])
        XCTAssertFalse(
            emissions.values.contains {
                $0.kind == .agentResponse
            })
        XCTAssertEqual(
            emissions.values.last?.text,
            "Cloud agent failed: authentication rejected")
    }
}

private final class HeadlessRuntimeValues<Value>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var stored: [Value] = []

    var values: [Value] {
        lock.withLock { stored }
    }

    func append(_ value: Value) {
        lock.withLock {
            stored.append(value)
        }
    }
}
