import Foundation

/// Maps ACP `session/request_permission` requests onto the shared Chat
/// approval model. The adapter stays independent of the process bridge so the
/// protocol's advertised choices and exact response shape can be tested in
/// isolation.
enum ACPApprovalAdapter {
    static let method = "session/request_permission"

    static func request(
        params: [String: Any],
        scopeID: String,
        provider: String
    ) -> AssistantApprovalRequest? {
        guard let toolCall = params["toolCall"] as? [String: Any],
              toolCall["toolCallId"] as? String != nil,
              !options(from: params).isEmpty
        else { return nil }

        let toolKind = toolCall["kind"] as? String
        let title = nonEmpty(toolCall["title"] as? String)
        let toolName = title ?? nonEmpty(toolKind) ?? "tool call"
        var preview: [String: Any] = [:]
        copy("rawInput", from: toolCall, to: &preview)
        copy("locations", from: toolCall, to: &preview)
        copy("content", from: toolCall, to: &preview)

        return AssistantApprovalRequest(
            scopeID: scopeID,
            provider: provider,
            kind: approvalKind(for: toolKind),
            toolName: toolName,
            input: prettyJSON(preview),
            reason: "\(provider) requests permission for \(toolName).",
            availableDecisions: availableDecisions(from: params))
    }

    /// ACP requires either a selected provider option id or an explicit
    /// cancelled outcome. Never invent an option the provider did not offer.
    static func response(
        params: [String: Any],
        decision: AssistantApprovalDecision
    ) -> [String: Any] {
        let choices = options(from: params)
        let selected: PermissionOption?
        switch decision {
        case .allowOnce:
            selected = choices.first { $0.kind == "allow_once" }
        case .allowSession:
            // A cached session grant can meet a later request that only offers
            // one-shot approval. Degrade safely instead of fabricating an
            // `allow_always` option id.
            selected = choices.first { $0.kind == "allow_always" }
                ?? choices.first { $0.kind == "allow_once" }
        case .deny:
            // The shared UI's Deny action is intentionally one-shot. Only use
            // the persistent rejection when it is the sole reject choice.
            selected = choices.first { $0.kind == "reject_once" }
                ?? choices.first { $0.kind == "reject_always" }
        case .cancel:
            selected = nil
        }

        guard let selected else {
            return ["outcome": ["outcome": "cancelled"]]
        }
        return [
            "outcome": [
                "outcome": "selected",
                "optionId": selected.id,
            ],
        ]
    }

    private struct PermissionOption {
        let id: String
        let kind: String
    }

    private static func options(
        from params: [String: Any]
    ) -> [PermissionOption] {
        guard let raw = params["options"] as? [[String: Any]] else { return [] }
        let supportedKinds: Set<String> = [
            "allow_once", "allow_always", "reject_once", "reject_always",
        ]
        return raw.compactMap { option in
            guard let id = nonEmpty(option["optionId"] as? String),
                  let kind = option["kind"] as? String,
                  supportedKinds.contains(kind)
            else { return nil }
            return PermissionOption(id: id, kind: kind)
        }
    }

    private static func availableDecisions(
        from params: [String: Any]
    ) -> [AssistantApprovalDecision] {
        let kinds = Set(options(from: params).map(\.kind))
        var decisions: [AssistantApprovalDecision] = []
        if kinds.contains("allow_once") { decisions.append(.allowOnce) }
        if kinds.contains("allow_always") { decisions.append(.allowSession) }
        if kinds.contains("reject_once") || kinds.contains("reject_always") {
            decisions.append(.deny)
        }
        return decisions
    }

    private static func approvalKind(
        for toolKind: String?
    ) -> AssistantApprovalRequest.Kind {
        switch toolKind {
        case "execute":
            return .commandExecution
        case "edit", "delete", "move":
            return .fileChange
        default:
            return .toolUse
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

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(
            in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
