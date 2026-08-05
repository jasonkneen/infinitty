import XCTest
@testable import InfinittyKit

final class ACPApprovalAdapterTests: XCTestCase {
    func testRequestMapsAdvertisedChoicesAndCommandPreview() throws {
        let params: [String: Any] = [
            "sessionId": "session-1",
            "toolCall": [
                "toolCallId": "tool-1",
                "kind": "execute",
                "title": "Run focused tests",
                "rawInput": ["command": "swift test --filter ACP"],
                "locations": [["path": "/tmp/project"]],
            ],
            "options": [
                ["optionId": "once", "name": "Allow once", "kind": "allow_once"],
                ["optionId": "always", "name": "Allow always", "kind": "allow_always"],
                ["optionId": "reject", "name": "Reject", "kind": "reject_once"],
            ],
        ]

        let request = try XCTUnwrap(ACPApprovalAdapter.request(
            params: params, scopeID: "chat#epoch=1", provider: "Hermes"))

        XCTAssertEqual(request.provider, "Hermes")
        XCTAssertEqual(request.kind, .commandExecution)
        XCTAssertEqual(request.toolName, "Run focused tests")
        XCTAssertEqual(
            request.availableDecisions, [.allowOnce, .allowSession, .deny])
        XCTAssertTrue(request.input?.contains("swift test --filter ACP") == true)

        let response = ACPApprovalAdapter.response(
            params: params, decision: .allowSession)
        let outcome = try XCTUnwrap(response["outcome"] as? [String: String])
        XCTAssertEqual(outcome["outcome"], "selected")
        XCTAssertEqual(outcome["optionId"], "always")
    }

    func testFileChangeAndOneShotDenialUseExactProviderOptionIds() throws {
        let params: [String: Any] = [
            "toolCall": [
                "toolCallId": "tool-2",
                "kind": "edit",
                "title": "Edit package manifest",
            ],
            "options": [
                ["optionId": "reject-forever", "name": "Reject always", "kind": "reject_always"],
                ["optionId": "reject-now", "name": "Reject once", "kind": "reject_once"],
            ],
        ]

        let request = try XCTUnwrap(ACPApprovalAdapter.request(
            params: params, scopeID: "chat", provider: "OpenCode"))
        XCTAssertEqual(request.kind, .fileChange)
        XCTAssertEqual(request.availableDecisions, [.deny])

        let response = ACPApprovalAdapter.response(params: params, decision: .deny)
        let outcome = try XCTUnwrap(response["outcome"] as? [String: String])
        XCTAssertEqual(outcome["optionId"], "reject-now")
    }

    func testCachedSessionGrantDegradesToAdvertisedOneShotChoice() throws {
        let params: [String: Any] = [
            "toolCall": ["toolCallId": "tool-3"],
            "options": [
                ["optionId": "only-once", "name": "Allow once", "kind": "allow_once"],
                ["optionId": "no", "name": "Reject", "kind": "reject_once"],
            ],
        ]

        let response = ACPApprovalAdapter.response(
            params: params, decision: .allowSession)
        let outcome = try XCTUnwrap(response["outcome"] as? [String: String])
        XCTAssertEqual(outcome["optionId"], "only-once")
    }

    func testCancelAndUnsupportedApprovalFailClosed() throws {
        let params: [String: Any] = [
            "toolCall": ["toolCallId": "tool-4"],
            "options": [
                ["optionId": "no", "name": "Reject", "kind": "reject_once"],
            ],
        ]

        for decision in [AssistantApprovalDecision.cancel, .allowOnce] {
            let response = ACPApprovalAdapter.response(
                params: params, decision: decision)
            let outcome = try XCTUnwrap(response["outcome"] as? [String: String])
            XCTAssertEqual(outcome, ["outcome": "cancelled"])
        }

        XCTAssertNil(ACPApprovalAdapter.request(
            params: [
                "toolCall": ["toolCallId": "tool-4"],
                "options": [[
                    "optionId": "future", "name": "Future", "kind": "future_kind",
                ]],
            ],
            scopeID: "chat",
            provider: "OpenCode"))
    }

    func testLargeRawInputIsUTF8Bounded() throws {
        let request = try XCTUnwrap(ACPApprovalAdapter.request(
            params: [
                "toolCall": [
                    "toolCallId": "tool-5",
                    "rawInput": ["content": String(repeating: "é", count: 20_000)],
                ],
                "options": [[
                    "optionId": "once", "name": "Allow once", "kind": "allow_once",
                ]],
            ],
            scopeID: "chat",
            provider: "OpenCode"))

        XCTAssertLessThanOrEqual(request.input?.utf8.count ?? .max, 12_000)
        XCTAssertTrue(request.input?.contains("parameters truncated") == true)
    }
}
