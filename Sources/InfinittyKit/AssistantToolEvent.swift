import Foundation

/// A tool call reported by a bridge, on its way to the transcript.
///
/// Deliberately bridge-agnostic: Claude, ACP, Codex and Amp all describe tool
/// calls differently, and the transcript only needs this small common shape.
struct AssistantToolEvent: Sendable {
    enum State: String, Sendable {
        case running
        case completed
        case failed
    }

    let id: String
    let name: String
    var state: State
    var input: String?
    var output: String?
    var errorText: String?
    /// Stable conversation or assistant identity used to keep simultaneous
    /// transcript streams separate. `nil` preserves the legacy unscoped path.
    var scopeID: String?

    init(
        id: String,
        name: String,
        state: State,
        input: String? = nil,
        output: String? = nil,
        errorText: String? = nil,
        scopeID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.input = input
        self.output = output
        self.errorText = errorText
        self.scopeID = scopeID
    }
}

/// Carries tool events from a bridge to whatever is showing the transcript.
///
/// The bridge is built inside a static `askAI`, several layers below the object
/// that renders, so a bus is simpler than threading a callback through every
/// signature. Each transcript owns a subscription token, so removing one
/// transcript never disconnects any other transcript.
enum AssistantToolEventBus {
    typealias Handler = @MainActor (AssistantToolEvent) -> Void

    /// An independently removable observer. Dropping the token also removes
    /// the observer, which keeps closed chat surfaces out of the process-wide
    /// registry.
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
            AssistantToolEventBus.removeSubscription(id: currentID)
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

        /// The recursive lock makes cancellation deterministic without
        /// deadlocking when a callback cancels its own token. Once `cancel`
        /// returns, this subscriber has no callback still running or queued.
        @MainActor
        func deliver(_ event: AssistantToolEvent) {
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
    nonisolated(unsafe) private static var legacySubscriber: Subscriber?
    nonisolated(unsafe) private static var nextOrder: UInt64 = 0

    /// Observe every event, or only events routed to one stable identity.
    ///
    /// An unscoped subscription is a wildcard for backwards compatibility.
    /// A scoped subscription receives exact matches only; unscoped events are
    /// therefore never fanned out to every conversation.
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

    /// Compatibility shim for call sites that have not moved to subscription
    /// ownership yet. Replacing or clearing this sink does not affect any
    /// subscription created with `subscribe`.
    static func setSink(_ sink: Handler?) {
        lock.lock()
        let previous = legacySubscriber
        legacySubscriber = sink.map {
            Subscriber(scopeID: nil, order: makeOrderLocked(), handler: $0)
        }
        lock.unlock()
        previous?.cancel()
    }

    static func publish(_ event: AssistantToolEvent) {
        lock.lock()
        var current = subscribers.values.filter { subscriber in
            subscriber.scopeID == nil || subscriber.scopeID == event.scopeID
        }
        if let legacySubscriber {
            current.append(legacySubscriber)
        }
        current.sort { $0.order < $1.order }
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
    static func publish(_ event: AssistantToolEvent, scopeID: String) {
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
