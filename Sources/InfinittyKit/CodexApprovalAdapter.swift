import Foundation

/// Maps Codex app-server approval RPCs onto the shared Chat approval model.
/// The adapter is deliberately pure so protocol drift can be regression-tested
/// without launching a provider process.
enum CodexApprovalAdapter {
    static let supportedMethods: Set<String> = [
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval",
        "execCommandApproval",
        "applyPatchApproval",
    ]

    static func request(
        method: String,
        params: [String: Any],
        scopeID: String
    ) -> AssistantApprovalRequest? {
        guard supportedMethods.contains(method) else { return nil }
        let reason = params["reason"] as? String
        switch method {
        case "item/commandExecution/requestApproval":
            var preview: [String: Any] = [:]
            copy("command", from: params, to: &preview)
            copy("cwd", from: params, to: &preview)
            copy("additionalPermissions", from: params, to: &preview)
            return AssistantApprovalRequest(
                scopeID: scopeID,
                provider: "Codex",
                kind: .commandExecution,
                toolName: "command execution",
                input: prettyJSON(preview),
                reason: reason ?? "Codex wants to run this command.",
                availableDecisions: commandDecisions(from: params))

        case "item/fileChange/requestApproval":
            var preview: [String: Any] = [:]
            copy("grantRoot", from: params, to: &preview)
            copy("itemId", from: params, to: &preview)
            return AssistantApprovalRequest(
                scopeID: scopeID,
                provider: "Codex",
                kind: .fileChange,
                toolName: "file change",
                input: prettyJSON(preview),
                reason: reason ?? "Codex wants to modify files.")

        case "item/permissions/requestApproval":
            var preview: [String: Any] = [:]
            copy("cwd", from: params, to: &preview)
            copy("permissions", from: params, to: &preview)
            return AssistantApprovalRequest(
                scopeID: scopeID,
                provider: "Codex",
                kind: .permissions,
                toolName: "additional permissions",
                input: prettyJSON(preview),
                reason: reason ?? "Codex wants additional sandbox permissions.")

        case "execCommandApproval":
            var preview: [String: Any] = [:]
            copy("command", from: params, to: &preview)
            copy("cwd", from: params, to: &preview)
            return AssistantApprovalRequest(
                scopeID: scopeID,
                provider: "Codex",
                kind: .commandExecution,
                toolName: "command execution",
                input: prettyJSON(preview),
                reason: reason ?? "Codex wants to run this command.")

        case "applyPatchApproval":
            var preview: [String: Any] = [:]
            copy("fileChanges", from: params, to: &preview)
            copy("grantRoot", from: params, to: &preview)
            return AssistantApprovalRequest(
                scopeID: scopeID,
                provider: "Codex",
                kind: .fileChange,
                toolName: "apply patch",
                input: prettyJSON(preview),
                reason: reason ?? "Codex wants to apply file changes.")

        default:
            return nil
        }
    }

    static func response(
        method: String,
        params: [String: Any],
        decision: AssistantApprovalDecision
    ) -> [String: Any] {
        switch method {
        case "item/commandExecution/requestApproval":
            return ["decision": commandDecision(
                decision, available: commandDecisionStrings(from: params))]
        case "item/fileChange/requestApproval":
            return ["decision": modernDecision(decision)]
        case "item/permissions/requestApproval":
            let granted = decision == .allowOnce || decision == .allowSession
                ? (params["permissions"] as? [String: Any] ?? [:])
                : [:]
            return [
                "permissions": granted,
                "scope": decision == .allowSession ? "session" : "turn",
            ]
        case "execCommandApproval", "applyPatchApproval":
            return ["decision": legacyDecision(decision)]
        default:
            return [:]
        }
    }

    private static func commandDecisions(
        from params: [String: Any]
    ) -> [AssistantApprovalDecision] {
        let available = commandDecisionStrings(from: params)
        var result: [AssistantApprovalDecision] = []
        if available.contains("accept") { result.append(.allowOnce) }
        if available.contains("acceptForSession") { result.append(.allowSession) }
        result.append(.deny)
        return result
    }

    private static func commandDecisionStrings(
        from params: [String: Any]
    ) -> Set<String> {
        guard let raw = params["availableDecisions"] else {
            return ["accept", "acceptForSession", "decline", "cancel"]
        }
        if raw is NSNull {
            return ["accept", "acceptForSession", "decline", "cancel"]
        }
        guard let values = raw as? [Any] else { return ["decline", "cancel"] }
        return Set(values.compactMap { $0 as? String })
    }

    private static func commandDecision(
        _ decision: AssistantApprovalDecision,
        available: Set<String>
    ) -> String {
        switch decision {
        case .allowOnce:
            return available.contains("accept") ? "accept" : denial(in: available)
        case .allowSession:
            if available.contains("acceptForSession") { return "acceptForSession" }
            return available.contains("accept") ? "accept" : denial(in: available)
        case .deny:
            return denial(in: available)
        case .cancel:
            return "cancel"
        }
    }

    private static func denial(in available: Set<String>) -> String {
        available.contains("decline") ? "decline" : "cancel"
    }

    private static func modernDecision(
        _ decision: AssistantApprovalDecision
    ) -> String {
        switch decision {
        case .allowOnce: "accept"
        case .allowSession: "acceptForSession"
        case .deny: "decline"
        case .cancel: "cancel"
        }
    }

    private static func legacyDecision(
        _ decision: AssistantApprovalDecision
    ) -> Any {
        switch decision {
        case .allowOnce:
            return "approved"
        case .allowSession:
            return "approved_for_session"
        case .deny:
            return ["denied": ["rejection": "The user denied this request."]]
        case .cancel:
            return "abort"
        }
    }

    private static func copy(
        _ key: String,
        from source: [String: Any],
        to destination: inout [String: Any]
    ) {
        guard let value = source[key], !(value is NSNull) else { return }
        destination[key] = value
    }

    private static func prettyJSON(_ object: [String: Any]) -> String? {
        guard !object.isEmpty,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return bounded(String(decoding: data, as: UTF8.self), maximumBytes: 12_000)
    }

    private static func bounded(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        let marker = "\n…[parameters truncated]"
        let budget = max(maximumBytes - marker.utf8.count, 0)
        var result = ""
        var used = 0
        for character in value {
            let next = String(character)
            guard used + next.utf8.count <= budget else { break }
            result.append(character)
            used += next.utf8.count
        }
        return result + marker
    }
}
