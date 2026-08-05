import Foundation

/// Shared safety bounds for native agent-provider turns.
///
/// `defaultInactivitySeconds` is reset by meaningful provider activity. The
/// absolute duration remains a separate fail-safe so a continuously noisy
/// child cannot retain a run forever.
enum AssistantTurnTimeoutPolicy {
    static let defaultInactivitySeconds: TimeInterval = 300
    static let maximumTurnDurationSeconds: TimeInterval = 30 * 60
}
