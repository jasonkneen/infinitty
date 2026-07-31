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

    /// Cancel a timed-out item only when it has not been sent. Returns true
    /// when the item was removed. A false result for the head is intentional:
    /// the queue remains correlated with the terminal's eventual marker.
    @discardableResult
    func cancelTimedOut(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              index > 0 else { return false }
        items.remove(at: index)
        return true
    }

    func cancelAll(exitCode: Int = -1) {
        let cancelled = items
        items.removeAll()
        for item in cancelled { item.completion(exitCode, "") }
    }
}
