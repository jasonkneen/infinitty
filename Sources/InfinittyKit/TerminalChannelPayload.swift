import Darwin
import Foundation

/// Identity asserted by an agent through the socket of the terminal pane that
/// owns it. The host derives durable endpoint/participant IDs; callers may
/// describe themselves, but cannot choose another pane, Channel, or author ID.
struct TerminalAgentRegistration: Equatable, Sendable {
    static let maximumCapabilities = 32

    let displayName: String
    let role: String
    let provider: String?
    let modelID: String?
    let sessionID: String?
    let capabilities: [String]
    /// Present only for lifecycle-managed clients such as the MCP process.
    /// The PID comes from LOCAL_PEERPID, never from caller JSON.
    let lifetimeToken: String?
    let ownerProcessID: pid_t?

    init(
        displayName: String,
        role: String,
        provider: String?,
        modelID: String? = nil,
        sessionID: String? = nil,
        capabilities: [String] = [],
        lifetimeToken: String? = nil,
        ownerProcessID: pid_t? = nil
    ) {
        self.displayName = displayName
        self.role = role
        self.provider = provider
        self.modelID = modelID
        self.sessionID = sessionID
        self.capabilities = capabilities
        self.lifetimeToken = lifetimeToken
        self.ownerProcessID = ownerProcessID
    }

    var jsonObject: [String: Any] {
        var value: [String: Any] = [
            "displayName": displayName,
            "role": role,
            "capabilities": capabilities,
        ]
        value["provider"] = provider ?? NSNull()
        value["modelID"] = modelID ?? NSNull()
        value["sessionID"] = sessionID ?? NSNull()
        return value
    }

    func participant(endpointID: String) -> CollaborationParticipant {
        CollaborationParticipant(
            id: Self.participantID(endpointID: endpointID),
            displayName: displayName,
            role: role,
            provider: provider,
            modelID: modelID,
            capabilities: capabilities)
    }

    static func participantID(endpointID: String) -> String {
        "\(endpointID)/participant"
    }

    static func decode(
        _ encoded: String,
        peerProcessID: pid_t = 0
    ) -> Result<Self, Error> {
        let payload: [String: Any]
        switch BrowserControlCodec.decode(encoded) {
        case .success(let value): payload = value
        case .failure(let error): return .failure(error)
        }
        guard payload["v"] as? Int == 1 else {
            return .failure(TerminalChannelControlError.unsupportedVersion)
        }
        do {
            let displayName = try requiredString(
                payload["displayName"], field: "displayName", maximum: 80)
            let role = try optionalString(
                payload["role"], field: "role", maximum: 120)
                ?? "terminal agent"
            let provider = try optionalString(
                payload["provider"], field: "provider", maximum: 80)
            let modelID = try optionalString(
                payload["modelID"], field: "modelID", maximum: 160)
            let sessionID = try optionalString(
                payload["sessionID"], field: "sessionID", maximum: 160)
            let rawCapabilities: [Any]
            if let raw = payload["capabilities"] {
                guard raw is NSNull || raw is [Any] else {
                    throw TerminalChannelControlError.invalidField(
                        "capabilities", "must be an array")
                }
                rawCapabilities = raw as? [Any] ?? []
            } else {
                rawCapabilities = []
            }
            guard rawCapabilities.count <= maximumCapabilities else {
                throw TerminalChannelControlError.invalidField(
                    "capabilities", "must contain at most \(maximumCapabilities) values")
            }
            let capabilities = try rawCapabilities.map {
                try requiredString($0, field: "capability", maximum: 120)
            }
            let managedLifetime: Bool
            if let raw = payload["managedLifetime"] {
                guard raw is NSNull || raw is Bool else {
                    throw TerminalChannelControlError.invalidField(
                        "managedLifetime", "must be a boolean")
                }
                managedLifetime = raw as? Bool ?? false
            } else {
                managedLifetime = false
            }
            let lifetimeToken = try optionalString(
                payload["lifetimeToken"], field: "lifetimeToken", maximum: 128)
            if managedLifetime && (lifetimeToken == nil || peerProcessID <= 0) {
                throw TerminalChannelControlError.invalidField(
                    "managedLifetime",
                    "requires a lifetimeToken and an authenticated peer process")
            }
            return .success(TerminalAgentRegistration(
                displayName: displayName,
                role: role,
                provider: provider,
                modelID: modelID,
                sessionID: sessionID,
                capabilities: Array(Set(capabilities)).sorted(),
                lifetimeToken: managedLifetime ? lifetimeToken : nil,
                ownerProcessID: managedLifetime ? peerProcessID : nil))
        } catch {
            return .failure(error)
        }
    }

    private static func requiredString(
        _ raw: Any?,
        field: String,
        maximum: Int
    ) throws -> String {
        guard let value = raw as? String else {
            throw TerminalChannelControlError.invalidField(
                field, "must be a string")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TerminalChannelControlError.invalidField(
                field, "must not be empty")
        }
        guard trimmed.utf8.count <= maximum else {
            throw TerminalChannelControlError.invalidField(
                field, "must contain at most \(maximum) UTF-8 bytes")
        }
        return trimmed
    }

    fileprivate static func optionalString(
        _ raw: Any?,
        field: String,
        maximum: Int
    ) throws -> String? {
        guard raw != nil, !(raw is NSNull) else { return nil }
        return try requiredString(raw, field: field, maximum: maximum)
    }
}

struct TerminalChannelPost: Equatable, Sendable {
    let text: String
    let threadID: String?

    static func decode(_ encoded: String) -> Result<Self, Error> {
        let payload: [String: Any]
        switch BrowserControlCodec.decode(encoded) {
        case .success(let value): payload = value
        case .failure(let error): return .failure(error)
        }
        guard payload["v"] as? Int == 1 else {
            return .failure(TerminalChannelControlError.unsupportedVersion)
        }
        guard let rawText = payload["text"] as? String else {
            return .failure(TerminalChannelControlError.invalidField(
                "text", "must be a string"))
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .failure(TerminalChannelControlError.invalidField(
                "text", "must not be empty"))
        }
        let threadID: String?
        if let raw = payload["threadID"], !(raw is NSNull), !(raw is String) {
            return .failure(TerminalChannelControlError.invalidField(
                "threadID", "must be a string"))
        }
        if let rawThreadID = payload["threadID"] as? String {
            let value = rawThreadID.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 128 else {
                return .failure(TerminalChannelControlError.invalidField(
                    "threadID", "must contain 1...128 UTF-8 bytes"))
            }
            threadID = value
        } else {
            threadID = nil
        }
        return .success(TerminalChannelPost(
            text: CollaborationMessage.boundedChannelText(text),
            threadID: threadID))
    }
}

struct TerminalChannelUnregistration: Equatable, Sendable {
    let lifetimeToken: String?

    static func decode(_ encoded: String) -> Result<Self, Error> {
        guard !encoded.isEmpty else {
            return .success(TerminalChannelUnregistration(lifetimeToken: nil))
        }
        let payload: [String: Any]
        switch BrowserControlCodec.decode(encoded) {
        case .success(let value): payload = value
        case .failure(let error): return .failure(error)
        }
        guard payload["v"] as? Int == 1 else {
            return .failure(TerminalChannelControlError.unsupportedVersion)
        }
        do {
            return .success(TerminalChannelUnregistration(
                lifetimeToken: try TerminalAgentRegistration.optionalString(
                    payload["lifetimeToken"],
                    field: "lifetimeToken",
                    maximum: 128)))
        } catch {
            return .failure(error)
        }
    }
}

enum TerminalChannelControlError: LocalizedError {
    case unsupportedVersion
    case invalidField(String, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "Terminal Channel requests require version 1."
        case .invalidField(let field, let reason):
            return "\(field) \(reason)."
        }
    }
}
