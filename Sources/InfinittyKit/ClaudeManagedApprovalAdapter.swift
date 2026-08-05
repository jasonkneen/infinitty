import Foundation

/// Maps Claude Managed Agents tool-confirmation events onto the shared Chat
/// approval model. Custom tools are intentionally excluded: their protocol
/// requires the client to execute the tool and return a result, not consent.
struct ClaudeManagedToolApproval {
    let eventID: String
    let sessionThreadID: String?
    let request: AssistantApprovalRequest
}

enum ClaudeManagedApprovalAdapter {
    static let supportedEventTypes: Set<String> = [
        "agent.tool_use",
        "agent.mcp_tool_use",
    ]

    static func approval(
        event: [String: Any],
        scopeID: String
    ) -> ClaudeManagedToolApproval? {
        guard let type = event["type"] as? String,
              supportedEventTypes.contains(type),
              let eventID = nonEmpty(event["id"] as? String),
              let name = nonEmpty(event["name"] as? String),
              let input = event["input"] as? [String: Any]
        else { return nil }

        let server = nonEmpty(event["mcp_server_name"] as? String)
        let toolName = server.map { "\($0) / \(name)" } ?? name
        let reason = type == "agent.mcp_tool_use"
            ? "Claude wants to use the \(toolName) MCP tool."
            : "Claude wants to use \(name)."
        return ClaudeManagedToolApproval(
            eventID: eventID,
            sessionThreadID:
                nonEmpty(event["session_thread_id"] as? String),
            request: AssistantApprovalRequest(
                scopeID: scopeID,
                provider: "Claude",
                kind: approvalKind(toolName: name),
                toolName: toolName,
                input: prettyJSON(input),
                reason: reason,
                availableDecisions: [.allowOnce, .deny]))
    }

    static func confirmation(
        for approval: ClaudeManagedToolApproval,
        decision: AssistantApprovalDecision
    ) -> [String: Any] {
        let allowed = decision == .allowOnce || decision == .allowSession
        var event: [String: Any] = [
            "type": "user.tool_confirmation",
            "tool_use_id": approval.eventID,
            "result": allowed ? "allow" : "deny",
        ]
        if !allowed {
            event["deny_message"] = decision == .cancel
                ? "The tool request was cancelled."
                : "The user denied this tool request."
        }
        if let sessionThreadID = approval.sessionThreadID {
            event["session_thread_id"] = sessionThreadID
        }
        return event
    }

    private static func approvalKind(
        toolName: String
    ) -> AssistantApprovalRequest.Kind {
        let name = toolName.lowercased()
        if name == "bash"
            || name == "shell"
            || name == "terminal"
            || name.contains("command")
            || name.contains("execute")
            || name.hasPrefix("exec")
        {
            return .commandExecution
        }
        if name == "write"
            || name == "edit"
            || name == "delete"
            || name == "move"
            || name == "rename"
            || name.contains("patch")
            || name.contains("file_write")
            || name.contains("file_edit")
        {
            return .fileChange
        }
        return .toolUse
    }

    private static func prettyJSON(
        _ object: [String: Any]
    ) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return bounded(
            String(decoding: data, as: UTF8.self),
            maximumBytes: 12_000)
    }

    private static func bounded(
        _ value: String,
        maximumBytes: Int
    ) -> String {
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
            in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }
}
