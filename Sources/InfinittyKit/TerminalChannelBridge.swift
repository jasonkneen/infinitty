import Darwin
import Foundation

/// Host-neutral implementation of the pane-bound Channel protocol. Visual and
/// headless sessions provide only their stable endpoint/registration storage
/// and projection callbacks; validation, membership synchronization, and
/// server-bound authorship stay identical in both modes.
protocol TerminalChannelCoordinating: AnyObject {
    func snapshot() -> CollaborationSnapshot?
    func execute(_ encoded: String) -> (
        response: String,
        snapshot: CollaborationSnapshot?)
}

extension CollaborationCoordinatorClient: TerminalChannelCoordinating {}

final class TerminalChannelSessionBridge {
    private static let lifetimeQueue = DispatchQueue(
        label: "infinitty.terminal-channel-lifetime",
        qos: .utility)

    private let coordinator: any TerminalChannelCoordinating
    private let queue: DispatchQueue
    private let operationLock = NSLock()
    private let endpointProvider: () -> CollaborationEndpoint?
    private let registrationProvider: () -> TerminalAgentRegistration?
    private let registrationSetter: (TerminalAgentRegistration?) -> Void
    private let systemActor: CollaborationActor
    private let onSnapshot: (CollaborationSnapshot) -> Void
    private let onRegistered: (TerminalAgentRegistration) -> Void
    private let onUnregistered: () -> Void
    private let onMessage: (String, String) -> Void
    private var lifetimeTimer: DispatchSourceTimer?

    init(
        coordinator: any TerminalChannelCoordinating,
        queue: DispatchQueue,
        endpointProvider: @escaping () -> CollaborationEndpoint?,
        registrationProvider: @escaping () -> TerminalAgentRegistration?,
        registrationSetter: @escaping (TerminalAgentRegistration?) -> Void,
        systemActor: CollaborationActor,
        onSnapshot: @escaping (CollaborationSnapshot) -> Void = { _ in },
        onRegistered: @escaping (TerminalAgentRegistration) -> Void = { _ in },
        onUnregistered: @escaping () -> Void = {},
        onMessage: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.coordinator = coordinator
        self.queue = queue
        self.endpointProvider = endpointProvider
        self.registrationProvider = registrationProvider
        self.registrationSetter = registrationSetter
        self.systemActor = systemActor
        self.onSnapshot = onSnapshot
        self.onRegistered = onRegistered
        self.onUnregistered = onUnregistered
        self.onMessage = onMessage
    }

    deinit {
        lifetimeTimer?.cancel()
    }

    func context() -> String {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let endpoint = endpointProvider() else { return paneGone() }
        let state = synchronizedSnapshot(
            endpoint: endpoint,
            registration: registrationProvider())
        if let error = state.error {
            return TerminalChannelControl.error("coordinator_error", error)
        }
        return TerminalChannelControl.contextResponse(
            snapshot: state.snapshot,
            endpoint: endpoint,
            registration: registrationProvider())
    }

    func register(
        _ encoded: String,
        peerProcessID: pid_t = 0
    ) -> String {
        operationLock.lock()
        defer { operationLock.unlock() }
        let registration: TerminalAgentRegistration
        switch TerminalAgentRegistration.decode(
            encoded,
            peerProcessID: peerProcessID)
        {
        case .success(let value): registration = value
        case .failure(let error):
            return TerminalChannelControl.error(
                "invalid_registration", error.localizedDescription)
        }
        var previousRegistration = registrationProvider()
        if let previous = previousRegistration {
            let sameManagedOwner = previous.lifetimeToken != nil
                && previous.lifetimeToken == registration.lifetimeToken
                && previous.ownerProcessID == registration.ownerProcessID
            if !sameManagedOwner {
                let cleanup = unregisterCurrentLocked()
                guard registrationProvider() == nil else { return cleanup }
                previousRegistration = nil
            }
        }
        registrationSetter(registration)
        guard let endpoint = endpointProvider() else {
            registrationSetter(previousRegistration)
            return paneGone()
        }
        let state = synchronizedSnapshot(
            endpoint: endpoint,
            registration: registration)
        if let error = state.error {
            registrationSetter(previousRegistration)
            return TerminalChannelControl.error("coordinator_error", error)
        }
        updateLifetimeMonitorLocked(for: registration)
        onRegistered(registration)
        return TerminalChannelControl.contextResponse(
            snapshot: state.snapshot,
            endpoint: endpoint,
            registration: registration)
    }

    func unregister(
        _ encoded: String = "",
        peerProcessID: pid_t = 0
    ) -> String {
        let request: TerminalChannelUnregistration
        switch TerminalChannelUnregistration.decode(encoded) {
        case .success(let value): request = value
        case .failure(let error):
            return TerminalChannelControl.error(
                "invalid_unregistration", error.localizedDescription)
        }
        operationLock.lock()
        defer { operationLock.unlock() }
        if let registration = registrationProvider(),
           let ownerToken = registration.lifetimeToken
        {
            guard request.lifetimeToken == ownerToken,
                  registration.ownerProcessID == peerProcessID
            else {
                return TerminalChannelControl.error(
                    "ownership_mismatch",
                    "This registration belongs to another live agent process.")
            }
        }
        return unregisterCurrentLocked()
    }

    func post(_ encoded: String) -> String {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let registration = registrationProvider() else {
            return TerminalChannelControl.error(
                "registration_required",
                "Register this terminal agent before posting to a Channel.")
        }
        let post: TerminalChannelPost
        switch TerminalChannelPost.decode(encoded) {
        case .success(let value): post = value
        case .failure(let error):
            return TerminalChannelControl.error(
                "invalid_message", error.localizedDescription)
        }
        guard let endpoint = endpointProvider() else { return paneGone() }
        let state = synchronizedSnapshot(
            endpoint: endpoint,
            registration: registration)
        if let error = state.error {
            return TerminalChannelControl.error("coordinator_error", error)
        }
        guard let channel = state.snapshot?.channels.first(where: { channel in
            channel.endpoints.contains(where: { $0.id == endpoint.id })
        }) else {
            return TerminalChannelControl.error(
                "not_connected",
                "This terminal pane is not connected to an Infinitty Channel.")
        }
        if let threadID = post.threadID,
           !channel.messages.contains(where: { $0.threadID == threadID }) {
            return TerminalChannelControl.error(
                "unknown_thread", "No Channel thread has id \(threadID).")
        }
        let participantID = TerminalAgentRegistration.participantID(
            endpointID: endpoint.id)
        let messageID = UUID().uuidString.lowercased()
        let mutation = CollaborationControlRequest(
            op: .postMessage,
            actor: CollaborationActor(
                id: participantID,
                kind: .agent,
                displayName: registration.displayName),
            idempotencyKey: "terminal-message:\(messageID)",
            channelID: channel.id,
            message: CollaborationMessage(
                id: messageID,
                threadID: post.threadID,
                authorID: participantID,
                text: post.text))
        let executed = queue.sync { () -> (
            response: String, snapshot: CollaborationSnapshot?) in
            guard let encoded = CollaborationControlCodec.encode(mutation) else {
                return ("Could not encode Channel message.", nil)
            }
            return coordinator.execute(encoded)
        }
        guard let updated = executed.snapshot,
              let updatedChannel = updated.channels.first(where: {
                  $0.id == channel.id
              })
        else {
            return TerminalChannelControl.error(
                "coordinator_error", executed.response)
        }
        onSnapshot(updated)
        onMessage(channel.id, messageID)
        return TerminalChannelControl.postResponse(
            channelID: channel.id,
            messageID: messageID,
            revision: updatedChannel.revision)
    }

    private func unregisterCurrentLocked() -> String {
        guard let registeredEndpoint = endpointProvider() else {
            return paneGone()
        }
        let previousRegistration = registrationProvider()
        guard let snapshot = queue.sync(execute: {
            coordinator.snapshot()
        }) else {
            return TerminalChannelControl.error(
                "coordinator_error",
                "The Channel coordinator is unavailable.")
        }
        guard let channel = snapshot.channels.first(where: { channel in
            channel.endpoints.contains(where: {
                $0.id == registeredEndpoint.id
            })
        }) else {
            registrationSetter(nil)
            updateLifetimeMonitorLocked(for: nil)
            if previousRegistration != nil { onUnregistered() }
            guard let endpoint = endpointProvider() else { return paneGone() }
            return TerminalChannelControl.contextResponse(
                snapshot: snapshot,
                endpoint: endpoint,
                registration: nil)
        }
        let authoritativeEndpoint = channel.endpoints.first(where: {
            $0.id == registeredEndpoint.id
        })
        if previousRegistration == nil,
           authoritativeEndpoint?.participantID == nil
        {
            return TerminalChannelControl.contextResponse(
                snapshot: snapshot,
                endpoint: registeredEndpoint,
                registration: nil)
        }

        registrationSetter(nil)
        guard let endpoint = endpointProvider() else {
            registrationSetter(previousRegistration)
            return paneGone()
        }
        if authoritativeEndpoint?.participantID == nil {
            updateLifetimeMonitorLocked(for: nil)
            if previousRegistration != nil { onUnregistered() }
            return TerminalChannelControl.contextResponse(
                snapshot: snapshot,
                endpoint: endpoint,
                registration: nil)
        }
        let result: (response: String, snapshot: CollaborationSnapshot?) =
            queue.sync {
                let request = CollaborationControlRequest(
                    op: .updateMembership,
                    actor: systemActor,
                    idempotencyKey:
                        "terminal-unregister:\(endpoint.id):"
                        + UUID().uuidString.lowercased(),
                    channelID: channel.id,
                    endpoint: endpoint,
                    participant: nil)
                guard let encoded = CollaborationControlCodec.encode(request) else {
                    return ("Could not encode Channel membership.", nil)
                }
                return coordinator.execute(encoded)
            }
        guard let updated = result.snapshot else {
            registrationSetter(previousRegistration)
            return TerminalChannelControl.error(
                "coordinator_error", result.response)
        }
        updateLifetimeMonitorLocked(for: nil)
        onSnapshot(updated)
        if previousRegistration != nil { onUnregistered() }
        return TerminalChannelControl.contextResponse(
            snapshot: updated,
            endpoint: endpoint,
            registration: nil)
    }

    private func updateLifetimeMonitorLocked(
        for registration: TerminalAgentRegistration?
    ) {
        lifetimeTimer?.cancel()
        lifetimeTimer = nil
        guard let registration,
              let token = registration.lifetimeToken,
              let processID = registration.ownerProcessID
        else { return }
        let timer = DispatchSource.makeTimerSource(
            queue: Self.lifetimeQueue)
        timer.schedule(deadline: .now() + 1, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard kill(processID, 0) != 0, errno == ESRCH,
                  let self
            else { return }
            self.operationLock.lock()
            defer { self.operationLock.unlock() }
            guard self.registrationProvider()?.lifetimeToken == token,
                  self.registrationProvider()?.ownerProcessID == processID
            else { return }
            _ = self.unregisterCurrentLocked()
        }
        lifetimeTimer = timer
        timer.resume()
    }

    private func synchronizedSnapshot(
        endpoint: CollaborationEndpoint,
        registration: TerminalAgentRegistration?
    ) -> (snapshot: CollaborationSnapshot?, error: String?) {
        queue.sync {
            guard let snapshot = coordinator.snapshot() else {
                return (nil, "The Channel coordinator is unavailable.")
            }
            guard let registration,
                  let channel = snapshot.channels.first(where: { channel in
                      channel.endpoints.contains(where: { $0.id == endpoint.id })
                  })
            else { return (snapshot, nil) }
            let participant = registration.participant(endpointID: endpoint.id)
            let existingEndpoint = channel.endpoints.first(where: {
                $0.id == endpoint.id
            })
            let existingParticipant = channel.participants.first(where: {
                $0.id == participant.id
            })
            guard existingEndpoint != endpoint || existingParticipant != participant
            else { return (snapshot, nil) }
            let request = CollaborationControlRequest(
                op: .updateMembership,
                actor: CollaborationActor(
                    id: participant.id,
                    kind: .agent,
                    displayName: registration.displayName),
                idempotencyKey:
                    "terminal-register:\(endpoint.id):"
                    + UUID().uuidString.lowercased(),
                channelID: channel.id,
                endpoint: endpoint,
                participant: participant)
            guard let encoded = CollaborationControlCodec.encode(request) else {
                return (snapshot, "Could not encode Channel membership.")
            }
            let executed = coordinator.execute(encoded)
            guard let updated = executed.snapshot else {
                return (snapshot, executed.response)
            }
            onSnapshot(updated)
            return (updated, nil)
        }
    }

    private func paneGone() -> String {
        TerminalChannelControl.error(
            "pane_gone", "The terminal pane is no longer available.")
    }
}
