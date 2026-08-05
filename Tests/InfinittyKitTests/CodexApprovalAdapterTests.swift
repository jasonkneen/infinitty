import XCTest
@testable import InfinittyKit

final class CodexApprovalAdapterTests: XCTestCase {
    func testCommandRequestHonorsProviderAvailableDecisions() throws {
        let params: [String: Any] = [
            "threadId": "thread-1",
            "turnId": "turn-1",
            "itemId": "item-1",
            "command": "swift test",
            "cwd": "/tmp/project",
            "availableDecisions": ["accept", "decline"],
        ]

        let request = try XCTUnwrap(CodexApprovalAdapter.request(
            method: "item/commandExecution/requestApproval",
            params: params,
            scopeID: "chat#epoch=1"))

        XCTAssertEqual(request.kind, .commandExecution)
        XCTAssertEqual(request.provider, "Codex")
        XCTAssertEqual(request.availableDecisions, [.allowOnce, .deny])
        XCTAssertTrue(request.input?.contains("swift test") == true)
        XCTAssertEqual(
            CodexApprovalAdapter.response(
                method: "item/commandExecution/requestApproval",
                params: params,
                decision: .allowSession)["decision"] as? String,
            "accept",
            "session approval must degrade to the provider's advertised one-shot choice")
    }

    func testCommandSessionAndDenialMapToModernProtocol() {
        let params: [String: Any] = [
            "availableDecisions": [
                "accept", "acceptForSession", "decline", "cancel",
            ],
        ]
        XCTAssertEqual(
            CodexApprovalAdapter.response(
                method: "item/commandExecution/requestApproval",
                params: params,
                decision: .allowSession)["decision"] as? String,
            "acceptForSession")
        XCTAssertEqual(
            CodexApprovalAdapter.response(
                method: "item/commandExecution/requestApproval",
                params: params,
                decision: .deny)["decision"] as? String,
            "decline")
    }

    func testPermissionResponseReturnsRequestedProfileAtChosenScope() throws {
        let permissions: [String: Any] = [
            "network": ["enabled": true],
            "fileSystem": ["write": ["/tmp/generated"]],
        ]
        let params: [String: Any] = [
            "permissions": permissions,
            "cwd": "/tmp/project",
        ]

        let session = CodexApprovalAdapter.response(
            method: "item/permissions/requestApproval",
            params: params,
            decision: .allowSession)
        let granted = try XCTUnwrap(session["permissions"] as? [String: Any])
        XCTAssertEqual(session["scope"] as? String, "session")
        XCTAssertEqual(
            (granted["network"] as? [String: Bool])?["enabled"], true)

        let denied = CodexApprovalAdapter.response(
            method: "item/permissions/requestApproval",
            params: params,
            decision: .deny)
        XCTAssertTrue((denied["permissions"] as? [String: Any])?.isEmpty == true)
        XCTAssertEqual(denied["scope"] as? String, "turn")
    }

    func testLegacyApprovalUsesLegacyDecisionShape() throws {
        let allowed = CodexApprovalAdapter.response(
            method: "execCommandApproval", params: [:],
            decision: .allowSession)
        XCTAssertEqual(allowed["decision"] as? String, "approved_for_session")

        let denied = CodexApprovalAdapter.response(
            method: "applyPatchApproval", params: [:],
            decision: .deny)
        let wrapper = try XCTUnwrap(denied["decision"] as? [String: Any])
        let detail = try XCTUnwrap(wrapper["denied"] as? [String: String])
        XCTAssertEqual(detail["rejection"], "The user denied this request.")
    }

    func testLargeFilePreviewIsUTF8Bounded() throws {
        let request = try XCTUnwrap(CodexApprovalAdapter.request(
            method: "applyPatchApproval",
            params: [
                "fileChanges": [
                    "large.txt": [
                        "type": "add",
                        "content": String(repeating: "é", count: 20_000),
                    ],
                ],
            ],
            scopeID: "chat"))

        XCTAssertLessThanOrEqual(request.input?.utf8.count ?? .max, 12_000)
        XCTAssertTrue(request.input?.contains("parameters truncated") == true)
    }
}
