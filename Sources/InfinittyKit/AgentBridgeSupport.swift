import Foundation

/// Keyed backend and tool-event identity for one chat-thread lifecycle epoch.
/// The suffix prevents a retry from clearing the tombstone or accepting late
/// tool cards that belong to cancelled work.
enum AgentConversationIdentity {
    private static let epochMarker = "#epoch="

    static func transportID(threadID: UUID, epoch: Int) -> String {
        "\(threadID.uuidString)\(epochMarker)\(epoch)"
    }
}

/// Serializes request/response protocols that do not carry a client-generated
/// correlation id. Waiting callers are resumed in FIFO order.
actor AgentTurnGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
