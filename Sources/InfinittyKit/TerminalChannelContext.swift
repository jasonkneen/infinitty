import Foundation

enum TerminalChannelControl {
    /// This response is injected as one MCP tool item. Keep the complete JSON
    /// envelope small enough to remain a compact per-turn context item.
    private static let maximumContextResponseBytes = 3_500

    static func error(_ code: String, _ message: String) -> String {
        BrowserControlCodec.response(error: code, message: message)
    }

    static func contextResponse(
        snapshot: CollaborationSnapshot?,
        endpoint: CollaborationEndpoint,
        registration: TerminalAgentRegistration?
    ) -> String {
        let channel = snapshot?.channels.first(where: { channel in
            channel.endpoints.contains(where: { $0.id == endpoint.id })
        })
        guard let channel else {
            var result: [String: Any] = [
                "connected": false,
                "registered": registration != nil,
                "endpoint": endpointObject(endpoint),
                "peers": [],
                "recentMessages": [],
            ]
            result["self"] = registration?.jsonObject ?? NSNull()
            result["channel"] = NSNull()
            result["modelContext"] = "Connection status: NOT CONNECTED to an Infinitty Channel."
            return boundedContextResponse(result)
        }

        let currentEndpoint = channel.endpoints.first(where: {
            $0.id == endpoint.id
        }) ?? endpoint
        let selectedEndpoints = [currentEndpoint] + channel.endpoints.lazy
            .filter { $0.id != endpoint.id }
            .prefix(15)
        let selectedMessages = Array(channel.messages.suffix(6))
        let selectedResponsibilities = Array(channel.responsibilities.prefix(8))
        let selectedPlan = Array(channel.plan.prefix(8))
        var wantedParticipantIDs = Set(
            selectedEndpoints.compactMap(\.participantID))
        wantedParticipantIDs.formUnion(selectedMessages.map(\.authorID))
        wantedParticipantIDs.formUnion(selectedResponsibilities.map(\.ownerID))
        wantedParticipantIDs.formUnion(selectedPlan.compactMap(\.ownerID))

        var selectedParticipants = channel.participants.prefix(256).filter {
            wantedParticipantIDs.contains($0.id)
        }
        if let participantID = currentEndpoint.participantID,
           !selectedParticipants.contains(where: { $0.id == participantID }),
           let participant = channel.participants.first(where: {
               $0.id == participantID
           })
        {
            selectedParticipants.append(participant)
        }
        if let registeredParticipant = registration?.participant(
            endpointID: endpoint.id),
           !selectedParticipants.contains(where: {
               $0.id == registeredParticipant.id
           })
        {
            selectedParticipants.append(registeredParticipant)
        }
        let participants = Dictionary(
            uniqueKeysWithValues: selectedParticipants.map { ($0.id, $0) })
        let identities = selectedEndpoints.map {
            identityObject(endpoint: $0, participants: participants)
        }
        let currentIdentity = identityObject(
            endpoint: currentEndpoint,
            participants: participants)
        var current = currentIdentity
        if let registration {
            current["sessionID"] = registration.sessionID ?? NSNull()
            current["capabilities"] = Array(
                registration.capabilities.prefix(8))
        }
        let participantNames = Dictionary(
            uniqueKeysWithValues: selectedParticipants.map {
                ($0.id, $0.displayName)
            })
        let messages = selectedMessages.map { message in
            [
                "id": bounded(message.id, maximumBytes: 128),
                "threadID": message.threadID.map {
                    bounded($0, maximumBytes: 128)
                } ?? NSNull(),
                "authorID": bounded(message.authorID, maximumBytes: 128),
                "authorName": participantNames[message.authorID]
                    .map { bounded($0, maximumBytes: 128) }
                    ?? bounded(message.authorID, maximumBytes: 128),
                "text": bounded(message.text, maximumBytes: 512),
            ] as [String: Any]
        }
        let responsibilities = selectedResponsibilities.map {
            [
                "id": bounded($0.id, maximumBytes: 128),
                "scope": bounded($0.scope, maximumBytes: 256),
                "summary": bounded($0.summary, maximumBytes: 256),
                "ownerID": bounded($0.ownerID, maximumBytes: 128),
            ]
        }
        let plan = selectedPlan.map {
            [
                "id": bounded($0.id, maximumBytes: 128),
                "title": bounded($0.title, maximumBytes: 256),
                "status": $0.status.rawValue,
                "ownerID": $0.ownerID.map {
                    bounded($0, maximumBytes: 128)
                } ?? NSNull(),
                "dependencyIDs": Array($0.dependencyIDs.prefix(8)).map {
                    bounded($0, maximumBytes: 128)
                },
            ] as [String: Any]
        }
        let reducedChannel = CollaborationChannelState(
            id: channel.id,
            name: channel.name,
            colorHex: channel.colorHex,
            createdAt: channel.createdAt,
            revision: channel.revision,
            endpoints: selectedEndpoints,
            participants: selectedParticipants,
            responsibilities: selectedResponsibilities,
            plan: selectedPlan,
            messages: selectedMessages)
        let modelContext = CollaborationChatContext(
            snapshot: CollaborationSnapshot(
                revision: channel.revision,
                channels: [reducedChannel]),
            endpointID: endpoint.id,
            maximumMessages: 6)?.modelContext() ?? ""
        return boundedContextResponse([
            "connected": true,
            "registered": registration != nil,
            "endpoint": endpointObject(currentEndpoint),
            "self": current,
            "channel": [
                "id": channel.id,
                "name": channel.name,
                "colorHex": channel.colorHex,
                "revision": channel.revision,
            ],
            "peers": identities.filter {
                ($0["endpointID"] as? String) != endpoint.id
            },
            "responsibilities": responsibilities,
            "plan": plan,
            "recentMessages": messages,
            "modelContext": modelContext,
        ])
    }

    static func postResponse(
        channelID: String,
        messageID: String,
        revision: Int
    ) -> String {
        BrowserControlCodec.response(result: [
            "posted": true,
            "channelID": channelID,
            "messageID": messageID,
            "revision": revision,
        ])
    }

    private static func endpointObject(
        _ endpoint: CollaborationEndpoint
    ) -> [String: Any] {
        [
            "id": endpoint.id,
            "kind": endpoint.kind.rawValue,
            "label": endpoint.label,
            "participantID": endpoint.participantID ?? NSNull(),
            "instanceID": endpoint.instanceID ?? NSNull(),
        ]
    }

    private static func identityObject(
        endpoint: CollaborationEndpoint,
        participants: [String: CollaborationParticipant]
    ) -> [String: Any] {
        let participant = endpoint.participantID.flatMap { participants[$0] }
        return [
            "endpointID": endpoint.id,
            "participantID": endpoint.participantID ?? NSNull(),
            "displayName": participant?.displayName ?? endpoint.label,
            "kind": endpoint.kind.rawValue,
            "role": participant?.role ?? NSNull(),
            "provider": participant?.provider ?? NSNull(),
            "modelID": participant?.modelID ?? NSNull(),
            "capabilities": Array(
                (participant?.capabilities ?? []).prefix(8)),
        ]
    }

    private static func bounded(_ value: String, maximumBytes: Int) -> String {
        CollaborationChatContext.boundedPrefix(value, to: maximumBytes)
    }

    private static func boundedContextResponse(
        _ result: [String: Any]
    ) -> String {
        let response = BrowserControlCodec.response(result: result)
        guard response.utf8.count > maximumContextResponseBytes else {
            return response
        }

        var compactSelf = result["self"] as? [String: Any]
        compactSelf?["capabilities"] = []
        let compact: [String: Any] = [
            "connected": result["connected"] ?? false,
            "registered": result["registered"] ?? false,
            "endpoint": result["endpoint"] ?? NSNull(),
            "self": compactSelf ?? NSNull(),
            "channel": result["channel"] ?? NSNull(),
            "peers": [],
            "responsibilities": [],
            "plan": [],
            "recentMessages": [],
            "modelContext": result["modelContext"] ?? "",
            "truncated": true,
            "truncationReason": "Structured Channel details exceeded the model-visible response budget; modelContext remains authoritative and bounded.",
        ]
        let compactResponse = BrowserControlCodec.response(result: compact)
        guard compactResponse.utf8.count <= maximumContextResponseBytes else {
            return error(
                "context_too_large",
                "Channel context exceeded the model-visible response budget.")
        }
        return compactResponse
    }
}
