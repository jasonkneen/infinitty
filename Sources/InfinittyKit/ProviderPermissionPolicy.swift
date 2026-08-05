import Foundation

/// Fail-closed launch policy shared by provider adapters.
///
/// Provider "danger" modes are never inferred from the absence of a setting.
/// The temporary environment opt-in exists for compatibility while Channel
/// capability grants and consent receipts are wired through the provider
/// broker; only the exact value `1` enables it.
enum ProviderPermissionPolicy {
    static func allowsDangerBypass(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["INFINITTY_AI_YOLO"] == "1"
    }

    static func codexSandboxMode(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        allowsDangerBypass(environment: environment)
            ? "danger-full-access"
            : "workspace-write"
    }

    static func codexApprovalPolicy(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        allowsDangerBypass(environment: environment) ? "never" : "on-request"
    }

    static func claudePermissionArguments(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        allowsDangerBypass(environment: environment)
            ? ["--dangerously-skip-permissions"]
            : []
    }

    static func hermesACPArguments(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        allowsDangerBypass(environment: environment)
            ? ["acp", "--accept-hooks"]
            : ["acp"]
    }
}
