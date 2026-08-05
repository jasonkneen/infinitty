import Foundation

/// Provider-neutral telemetry emitted while an assistant run is in flight.
///
/// Values are deliberately optional. A bridge should publish only what its
/// provider actually reported; consumers can then distinguish missing data
/// from a real zero and provider facts from local estimates.
struct AssistantRunEvent: Sendable, Equatable {
    enum Provenance: String, Sendable, Equatable {
        case providerReported
        case estimate
    }

    struct TokenCounts: Sendable, Equatable {
        var input: Int?
        var cachedInput: Int?
        var cacheWriteInput: Int?
        var output: Int?
        var reasoningOutput: Int?
        var total: Int?

        init(
            input: Int? = nil,
            cachedInput: Int? = nil,
            cacheWriteInput: Int? = nil,
            output: Int? = nil,
            reasoningOutput: Int? = nil,
            total: Int? = nil
        ) {
            self.input = input
            self.cachedInput = cachedInput
            self.cacheWriteInput = cacheWriteInput
            self.output = output
            self.reasoningOutput = reasoningOutput
            self.total = total
        }
    }

    struct Cost: Sendable, Equatable {
        let amount: Decimal
        let currency: String
    }

    struct Usage: Sendable, Equatable {
        /// Tokens attributed to the provider's latest request/turn, if known.
        var lastTokens: TokenCounts?
        /// Tokens attributed to the whole provider thread/session, if known.
        var cumulativeTokens: TokenCounts?
        /// Actual current context occupancy. Never inferred from cumulative
        /// token usage because compaction makes those values diverge.
        var contextUsedTokens: Int?
        /// Provider-reported model context capacity.
        var contextWindowTokens: Int?
        /// Provider-reported or estimated cost, with its original currency.
        var cost: Cost?

        init(
            lastTokens: TokenCounts? = nil,
            cumulativeTokens: TokenCounts? = nil,
            contextUsedTokens: Int? = nil,
            contextWindowTokens: Int? = nil,
            cost: Cost? = nil
        ) {
            self.lastTokens = lastTokens
            self.cumulativeTokens = cumulativeTokens
            self.contextUsedTokens = contextUsedTokens
            self.contextWindowTokens = contextWindowTokens
            self.cost = cost
        }
    }

    struct ReasoningSummary: Sendable, Equatable {
        enum State: String, Sendable, Equatable {
            /// Append this provider-designated summary fragment.
            case delta
            /// Replace prior fragments for the item with this authoritative
            /// completed provider summary.
            case completed
        }

        let state: State
        let text: String
        var itemID: String?
        var summaryIndex: Int?

        init(
            state: State,
            text: String,
            itemID: String? = nil,
            summaryIndex: Int? = nil
        ) {
            self.state = state
            self.text = text
            self.itemID = itemID
            self.summaryIndex = summaryIndex
        }
    }

    enum Update: Sendable, Equatable {
        case usage(Usage)
        case reasoningSummary(ReasoningSummary)
    }

    let provenance: Provenance
    let update: Update
    /// Stable conversation or assistant identity. `nil` is the legacy,
    /// explicitly unscoped path and is not delivered to scoped observers.
    var scopeID: String?

    init(
        provenance: Provenance,
        update: Update,
        scopeID: String? = nil
    ) {
        self.provenance = provenance
        self.update = update
        self.scopeID = scopeID
    }
}

/// The bounded, display-safe telemetry retained with one Chat thread.
///
/// Bridges may emit many deltas. Keeping the fold here gives every surface the
/// same semantics and prevents an unbounded provider stream from becoming UI
/// state. Only `ReasoningSummary` events enter this value; raw reasoning is not
/// represented by the event contract at all.
struct AssistantRunTelemetrySnapshot: Equatable {
    private static let maximumSummaryBytes = 12_000

    var usage: AssistantRunEvent.Usage?
    var usageProvenance: AssistantRunEvent.Provenance?
    var reasoningSummary: String?
    var reasoningIsStreaming = false
    var runSerial = 0
    var runID = UUID()

    private var reasoningItemID: String?
    private var reasoningSummaryIndex: Int?

    mutating func beginRun() {
        usage = nil
        usageProvenance = nil
        reasoningSummary = nil
        reasoningIsStreaming = false
        reasoningItemID = nil
        reasoningSummaryIndex = nil
        runSerial &+= 1
        runID = UUID()
    }

    mutating func apply(_ event: AssistantRunEvent) {
        switch event.update {
        case .usage(let usage):
            self.usage = usage
            usageProvenance = event.provenance

        case .reasoningSummary(let summary):
            guard !summary.text.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
            else { return }

            switch summary.state {
            case .delta:
                let continuesCurrentFragment = reasoningItemID == summary.itemID
                    && reasoningSummaryIndex == summary.summaryIndex
                let hasExistingSummary = !(reasoningSummary?.isEmpty ?? true)
                let separator = continuesCurrentFragment || !hasExistingSummary
                    ? "" : "\n\n"
                reasoningSummary = Self.boundedSummary(
                    (reasoningSummary ?? "") + separator + summary.text)
                reasoningIsStreaming = true
            case .completed:
                // A completed provider summary is authoritative for its item
                // and replaces any partial fragments shown while it streamed.
                reasoningSummary = Self.boundedSummary(summary.text)
                reasoningIsStreaming = false
            }
            reasoningItemID = summary.itemID
            reasoningSummaryIndex = summary.summaryIndex
        }
    }

    mutating func finishRun() {
        reasoningIsStreaming = false
    }

    private static func boundedSummary(_ text: String) -> String {
        guard text.utf8.count > maximumSummaryBytes else { return text }
        let marker = "\n…[summary truncated]"
        let budget = max(maximumSummaryBytes - marker.utf8.count, 0)
        var result = ""
        var bytes = 0
        for character in text {
            let next = String(character)
            guard bytes + next.utf8.count <= budget else { break }
            result.append(character)
            bytes += next.utf8.count
        }
        return result + marker
    }
}

/// Transient, scope-aware delivery for provider telemetry.
///
/// This mirrors `AssistantToolEventBus`: every consumer owns a cancellable
/// token, and cancellation is deterministic even when callbacks cancel one
/// another during delivery.
enum AssistantRunEventBus {
    typealias Handler = @MainActor (AssistantRunEvent) -> Void

    final class Subscription: @unchecked Sendable {
        private let lock = NSLock()
        private var id: UUID?

        fileprivate init(id: UUID) {
            self.id = id
        }

        func cancel() {
            lock.lock()
            let currentID = id
            id = nil
            lock.unlock()

            guard let currentID else { return }
            AssistantRunEventBus.removeSubscription(id: currentID)
        }

        deinit {
            cancel()
        }
    }

    private final class Subscriber: @unchecked Sendable {
        let scopeID: String?
        let order: UInt64
        private let handler: Handler
        private let lock = NSRecursiveLock()
        private var isActive = true

        init(scopeID: String?, order: UInt64, handler: @escaping Handler) {
            self.scopeID = scopeID
            self.order = order
            self.handler = handler
        }

        @MainActor
        func deliver(_ event: AssistantRunEvent) {
            lock.lock()
            defer { lock.unlock() }
            guard isActive else { return }
            handler(event)
        }

        func cancel() {
            lock.lock()
            isActive = false
            lock.unlock()
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var subscribers: [UUID: Subscriber] = [:]
    nonisolated(unsafe) private static var nextOrder: UInt64 = 0

    /// An unscoped subscription is a wildcard. A scoped subscription receives
    /// exact scope matches only, so legacy events never fan out across runs.
    static func subscribe(
        scopeID: String? = nil,
        _ handler: @escaping Handler
    ) -> Subscription {
        let id = UUID()
        lock.lock()
        let subscriber = Subscriber(
            scopeID: scopeID,
            order: makeOrderLocked(),
            handler: handler)
        subscribers[id] = subscriber
        lock.unlock()
        return Subscription(id: id)
    }

    static func publish(_ event: AssistantRunEvent) {
        lock.lock()
        let current = subscribers.values
            .filter { $0.scopeID == nil || $0.scopeID == event.scopeID }
            .sorted { $0.order < $1.order }
        lock.unlock()

        guard !current.isEmpty else { return }
        let deliverySubscribers = current
        let deliver: @MainActor @Sendable () -> Void = {
            for subscriber in deliverySubscribers {
                subscriber.deliver(event)
            }
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                deliver()
            }
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    /// Route an event produced before its owning conversation was known.
    static func publish(_ event: AssistantRunEvent, scopeID: String) {
        var scopedEvent = event
        scopedEvent.scopeID = scopeID
        publish(scopedEvent)
    }

    private static func removeSubscription(id: UUID) {
        lock.lock()
        let subscriber = subscribers.removeValue(forKey: id)
        lock.unlock()
        subscriber?.cancel()
    }

    private static func makeOrderLocked() -> UInt64 {
        defer { nextOrder &+= 1 }
        return nextOrder
    }
}
