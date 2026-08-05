import Foundation

/// Read-only, deterministic projection used by room tests and control adapters. The durable Collaboration room is always the
/// source of truth; this value never owns mutable room state.
struct ChannelPanelProjection: Equatable {
    struct ParticipantRow: Equatable {
        let id: String
        let name: String
        let role: String
        let status: String
        let provider: String?
        let model: String?
    }

    struct ThreadRow: Equatable {
        let id: String
        let title: String
        let ownerName: String?
        let messageCount: Int
        let lastMessage: String
    }

    struct PlanRow: Equatable {
        let id: String
        let title: String
        let status: String
        let ownerName: String?
        let dependencyTitles: [String]
    }

    struct ResponsibilityRow: Equatable {
        let id: String
        let scope: String
        let summary: String
        let ownerName: String
        let leaseExpiresAt: Date?
    }

    struct ProposalRow: Equatable {
        let id: String
        let digest: String
        let state: CollaborationProposalState
        let objective: String
        let workspaceStrategy: CollaborationWorkspaceStrategy
        let presentation: CollaborationRoomPresentation
        let targetInstanceID: String?
        let agents: [CollaborationAgentSpec]
        let runtimeReceipts:
            [CollaborationRuntimeSessionReceipt]
        let expiresAt: Date
        let statusMessage: String?
    }

    let channelID: String
    let title: String
    let revision: Int
    let colorHex: String
    let participants: [ParticipantRow]
    let threads: [ThreadRow]
    let plan: [PlanRow]
    let responsibilities: [ResponsibilityRow]
    let proposals: [ProposalRow]
    let roomMessages: [CollaborationMessage]
    let visibleMessages: [CollaborationMessage]
    let selectedThreadID: String?
    let selectedThreadTitle: String
    let auditReceipt: String

    init(
        channel: CollaborationChannelState,
        selectedThreadID: String?,
        proposals: [CollaborationRoomProposal] = []
    ) {
        let participantByID = Dictionary(
            uniqueKeysWithValues: channel.participants.map { ($0.id, $0) })
        let connectedParticipantIDs = Set(
            channel.endpoints.compactMap(\.participantID))
        let planByID = Dictionary(
            uniqueKeysWithValues: channel.plan.map { ($0.id, $0) })

        self.channelID = channel.id
        self.title = channel.name
        self.revision = channel.revision
        self.colorHex = channel.colorHex
        self.participants = channel.participants.map {
            ParticipantRow(
                id: $0.id,
                name: $0.displayName,
                role: $0.role,
                status: connectedParticipantIDs.contains($0.id)
                    ? "connected"
                    : "not connected",
                provider: $0.provider,
                model: $0.modelID)
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        var grouped: [String: [CollaborationMessage]] = [:]
        for message in channel.messages {
            guard let threadID = message.threadID, !threadID.isEmpty else {
                continue
            }
            grouped[threadID, default: []].append(message)
        }
        self.threads = grouped.map { threadID, messages in
            let owner = messages.compactMap {
                participantByID[$0.authorID]
            }.first
            let subject = messages.first(where: {
                $0.authorID.hasPrefix("human:")
            })?.text ?? messages.first?.text ?? ""
            let compactSubject = Self.compactThreadSubject(subject)
            let title: String
            if let owner {
                title = compactSubject.isEmpty
                    ? "\(owner.displayName) conversation"
                    : "\(owner.displayName): \(compactSubject)"
            } else if compactSubject.isEmpty {
                title = "Conversation \(threadID.prefix(8))"
            } else {
                title = compactSubject
            }
            return ThreadRow(
                id: threadID,
                title: title,
                ownerName: owner?.displayName,
                messageCount: messages.count,
                lastMessage: messages.last?.text ?? "")
        }.sorted { lhs, rhs in
            let lhsIndex = channel.messages.lastIndex {
                $0.threadID == lhs.id
            } ?? channel.messages.startIndex
            let rhsIndex = channel.messages.lastIndex {
                $0.threadID == rhs.id
            } ?? channel.messages.startIndex
            return lhsIndex < rhsIndex
        }

        self.plan = channel.plan.map { item in
            PlanRow(
                id: item.id,
                title: item.title,
                status: item.status.rawValue,
                ownerName: item.ownerID.flatMap {
                    participantByID[$0]?.displayName
                },
                dependencyTitles: item.dependencyIDs.map {
                    planByID[$0]?.title ?? $0
                })
        }
        self.responsibilities = channel.responsibilities.map {
            ResponsibilityRow(
                id: $0.id,
                scope: $0.scope,
                summary: $0.summary,
                ownerName: participantByID[$0.ownerID]?.displayName
                    ?? $0.ownerID,
                leaseExpiresAt: $0.leaseExpiresAt)
        }
        self.proposals = proposals
            .filter { $0.spec.channelID == channel.id }
            .map {
                ProposalRow(
                    id: $0.spec.id,
                    digest: $0.digest,
                    state: $0.state,
                    objective: $0.spec.objective,
                    workspaceStrategy: $0.spec.workspaceStrategy,
                    presentation: $0.spec.presentation,
                    targetInstanceID: $0.spec.targetInstanceID,
                    agents: $0.spec.agents,
                    runtimeReceipts: $0.runtimeReceipts,
                    expiresAt: $0.spec.expiresAt,
                    statusMessage: $0.statusMessage)
            }
            .sorted { lhs, rhs in
                if lhs.state == .pending, rhs.state != .pending { return true }
                if rhs.state == .pending, lhs.state != .pending { return false }
                return lhs.id < rhs.id
            }
        self.roomMessages = channel.messages.filter {
            $0.threadID == nil || $0.threadID?.isEmpty == true
        }
        self.selectedThreadID = selectedThreadID
        if let selectedThreadID {
            self.visibleMessages = channel.messages.filter {
                $0.threadID == selectedThreadID
            }
            self.selectedThreadTitle = threads.first {
                $0.id == selectedThreadID
            }?.title ?? selectedThreadID
        } else {
            self.visibleMessages = roomMessages
            self.selectedThreadTitle = "Room"
        }
        self.auditReceipt = "Channel \(channel.id) · revision \(channel.revision)"
    }

    private static func compactThreadSubject(_ text: String) -> String {
        let line = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard line.count > 56 else { return line }
        return String(line.prefix(55)) + "…"
    }

    func controlState(isOpen: Bool) -> [String: Any] {
        func messageState(_ message: CollaborationMessage) -> [String: Any] {
            var value: [String: Any] = [
                "id": message.id,
                "authorId": message.authorID,
                "text": message.text,
            ]
            if let threadID = message.threadID {
                value["threadId"] = threadID
            }
            return value
        }

        return [
            "panelId": "channel-panel-\(channelID)",
            "channelId": channelID,
            "title": title,
            "revision": revision,
            "colorHex": colorHex,
            "open": isOpen,
            "selectedThreadId": selectedThreadID ?? NSNull(),
            "selectedThreadTitle": selectedThreadTitle,
            "participants": participants.map { participant in
                var value: [String: Any] = [
                    "id": participant.id,
                    "name": participant.name,
                    "role": participant.role,
                    "status": participant.status,
                ]
                if let provider = participant.provider {
                    value["provider"] = provider
                }
                if let model = participant.model {
                    value["model"] = model
                }
                return value
            },
            "threads": threads.map {
                var value: [String: Any] = [
                    "id": $0.id,
                    "title": $0.title,
                    "messageCount": $0.messageCount,
                    "lastMessage": $0.lastMessage,
                ]
                if let ownerName = $0.ownerName {
                    value["ownerName"] = ownerName
                }
                return value
            },
            "plan": plan.map {
                var value: [String: Any] = [
                    "id": $0.id,
                    "title": $0.title,
                    "status": $0.status,
                    "dependencies": $0.dependencyTitles,
                ]
                if let ownerName = $0.ownerName {
                    value["ownerName"] = ownerName
                }
                return value
            },
            "responsibilities": responsibilities.map {
                var value: [String: Any] = [
                    "id": $0.id,
                    "scope": $0.scope,
                    "summary": $0.summary,
                    "ownerName": $0.ownerName,
                ]
                if let leaseExpiresAt = $0.leaseExpiresAt {
                    value["leaseExpiresAt"] =
                        ISO8601DateFormatter().string(from: leaseExpiresAt)
                }
                return value
            },
            "proposals": proposals.map { proposal in
                var value: [String: Any] = [
                    "id": proposal.id,
                    "digest": proposal.digest,
                    "state": proposal.state.rawValue,
                    "objective": proposal.objective,
                    "workspaceStrategy":
                        proposal.workspaceStrategy.rawValue,
                    "presentation": proposal.presentation.rawValue,
                    "expiresAt": ISO8601DateFormatter().string(
                        from: proposal.expiresAt),
                    "agents": proposal.agents.map { agent in
                        var value: [String: Any] = [
                            "id": agent.id,
                            "name": agent.displayName,
                            "role": agent.role,
                            "runtime": agent.runtime.rawValue,
                            "provider": agent.provider,
                            "responsibilityScopes":
                                agent.responsibilityScopes,
                            "capabilities": agent.capabilities,
                        ]
                        if let model = agent.modelID {
                            value["model"] = model
                        }
                        if let cloud = agent.cloudConnection {
                            value["cloudConnection"] = [
                                "endpointURL": cloud.endpointURL,
                                "credentialEnvironmentVariable":
                                    cloud.credentialEnvironmentVariable,
                                "authentication":
                                    cloud.authentication.rawValue,
                                "remoteWorkspace":
                                    cloud.remoteWorkspace,
                                "agentID":
                                    cloud.agentID ?? NSNull(),
                                "environmentID":
                                    cloud.environmentID ?? NSNull(),
                                "vaultIDs": cloud.vaultIDs,
                            ] as [String: Any]
                        }
                        return value
                    },
                    "runtimeReceipts":
                        proposal.runtimeReceipts.map {
                            [
                                "id": $0.id,
                                "agentID": $0.agentID,
                                "adapterKind": $0.adapterKind,
                                "provider": $0.provider,
                                "remoteSessionID":
                                    $0.remoteSessionID,
                                "workspace": $0.workspace,
                                "capabilities":
                                    $0.capabilities,
                                "preparedAt":
                                    ISO8601DateFormatter()
                                        .string(
                                            from:
                                                $0.preparedAt),
                            ] as [String: Any]
                        },
                ]
                if let statusMessage = proposal.statusMessage {
                    value["statusMessage"] = statusMessage
                }
                if let targetInstanceID = proposal.targetInstanceID {
                    value["targetInstanceId"] = targetInstanceID
                }
                return value
            },
            "roomMessages": roomMessages.map(messageState),
            "visibleMessages": visibleMessages.map(messageState),
            "auditReceipt": auditReceipt,
        ]
    }
}
