import XCTest

@testable import InfinittyKit

final class ProviderPermissionPolicyTests: XCTestCase {
    func testProviderDangerModesAreOffByDefault() {
        XCTAssertFalse(ProviderPermissionPolicy.allowsDangerBypass(environment: [:]))
        XCTAssertEqual(
            ProviderPermissionPolicy.codexSandboxMode(environment: [:]),
            "workspace-write")
        XCTAssertEqual(
            ProviderPermissionPolicy.codexApprovalPolicy(environment: [:]),
            "on-request")
        XCTAssertEqual(
            ProviderPermissionPolicy.claudePermissionArguments(environment: [:]),
            [])
        XCTAssertEqual(
            ProviderPermissionPolicy.hermesACPArguments(environment: [:]),
            ["acp"])
    }

    func testOnlyExactExplicitOptInEnablesDangerModes() {
        for value in ["", "0", "true", "yes"] {
            XCTAssertFalse(ProviderPermissionPolicy.allowsDangerBypass(
                environment: ["INFINITTY_AI_YOLO": value]))
        }
        let environment = ["INFINITTY_AI_YOLO": "1"]
        XCTAssertTrue(ProviderPermissionPolicy.allowsDangerBypass(
            environment: environment))
        XCTAssertEqual(
            ProviderPermissionPolicy.codexSandboxMode(environment: environment),
            "danger-full-access")
        XCTAssertEqual(
            ProviderPermissionPolicy.codexApprovalPolicy(environment: environment),
            "never")
        XCTAssertEqual(
            ProviderPermissionPolicy.claudePermissionArguments(environment: environment),
            ["--dangerously-skip-permissions"])
        XCTAssertEqual(
            ProviderPermissionPolicy.hermesACPArguments(environment: environment),
            ["acp", "--accept-hooks"])
    }
}
