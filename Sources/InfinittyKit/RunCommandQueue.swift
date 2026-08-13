import Foundation

/// Main-thread state machine for synchronous app-control `run` requests.
///
/// An OSC 133 D marker has no request identifier, so queue order is the only
/// correlation mechanism. A timed-out in-flight head must remain in place
/// until its marker arrives; otherwise that late marker would be attributed to
/// the next queued command. Unsent items can be removed immediately.
final class RunCommandQueue {
    struct Item {
        let id: UUID
        let command: String
        let completion: (Int, String) -> Void
    }

    private var items: [Item] = []

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    /// Returns true when the caller should send this command now.
    func enqueue(_ item: Item) -> Bool {
        items.append(item)
        return items.count == 1
    }

    /// Complete the in-flight head and return the next command to send.
    func completeHead(exitCode: Int, output: String) -> String? {
        guard !items.isEmpty else { return nil }
        let finished = items.removeFirst()
        finished.completion(exitCode, output)
        return items.first?.command
    }

    /// Cancel a timed-out item. If the timed-out item was the in-flight head,
    /// it is removed and the next command to send (if any) is returned so that
    /// the queue never remains wedged behind a stalled or markerless command.
    @discardableResult
    func cancelTimedOut(id: UUID) -> String? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let wasHead = index == 0
        items.remove(at: index)
        if wasHead {
            return items.first?.command
        }
        return nil
    }

    func cancelAll(exitCode: Int = -1) {
        let cancelled = items
        items.removeAll()
        for item in cancelled { item.completion(exitCode, "") }
    }
}
