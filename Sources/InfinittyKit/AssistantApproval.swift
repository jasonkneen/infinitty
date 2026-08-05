import Foundation

/// The decisions Infinitty can return through a provider's native approval
/// protocol. A request advertises the subset its provider can actually honor.
enum AssistantApprovalDecision: String, CaseIterable, Sendable, Equatable {
    case allowOnce = "allow-once"
    case allowSession = "allow-session"
    case deny
    case cancel
}

/// One provider request for authority that the current run does not yet have.
///
/// `scopeID` is the backend-conversation epoch, not a display-thread id. This
/// keeps approvals from leaking across retries, agents, or simultaneous Chats.
struct AssistantApprovalRequest: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case toolUse = "tool-use"
        case commandExecution = "command-execution"
        case fileChange = "file-change"
        case permissions
    }

    let id: String
    let scopeID: String
    let provider: String
    let kind: Kind
    let toolName: String
    let input: String?
    let reason: String?
    let availableDecisions: [AssistantApprovalDecision]
    let createdAt: Date

    init(
        id: String = UUID().uuidString.lowercased(),
        scopeID: String,
        provider: String,
        kind: Kind,
        toolName: String,
        input: String? = nil,
        reason: String? = nil,
        availableDecisions: [AssistantApprovalDecision] = [
            .allowOnce, .allowSession, .deny,
        ],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.scopeID = scopeID
        self.provider = provider
        self.kind = kind
        self.toolName = toolName
        self.input = input
        self.reason = reason
        self.availableDecisions = Self.normalizedDecisions(availableDecisions)
        self.createdAt = createdAt
    }

    var message: String {
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            return reason
        }
        return "\(provider) wants to use \(toolName)."
    }

    var supportsSessionApproval: Bool {
        availableDecisions.contains(.allowSession)
    }

    private static func normalizedDecisions(
        _ decisions: [AssistantApprovalDecision]
    ) -> [AssistantApprovalDecision] {
        var seen = Set<AssistantApprovalDecision>()
        var result = decisions.filter { decision in
            decision != .cancel && seen.insert(decision).inserted
        }
        if !result.contains(.deny) { result.append(.deny) }
        return result
    }
}

struct AssistantApprovalEvent: Sendable, Equatable {
    enum State: String, Sendable, Equatable {
        case requested
        case resolved
        case expired
        case cancelled
    }

    let request: AssistantApprovalRequest
    let state: State
    let decision: AssistantApprovalDecision?
}

/// Scope-aware delivery of approval lifecycle changes to Chat surfaces.
enum AssistantApprovalEventBus {
    typealias Handler = @MainActor (AssistantApprovalEvent) -> Void

    final class Subscription: @unchecked Sendable {
        private let lock = NSLock()
        private var id: UUID?

        fileprivate init(id: UUID) { self.id = id }

        func cancel() {
            lock.lock()
            let currentID = id
            id = nil
            lock.unlock()
            guard let currentID else { return }
            AssistantApprovalEventBus.removeSubscription(id: currentID)
        }

        deinit { cancel() }
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
        func deliver(_ event: AssistantApprovalEvent) {
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

    static func subscribe(
        scopeID: String? = nil,
        _ handler: @escaping Handler
    ) -> Subscription {
        let id = UUID()
        lock.lock()
        let subscriber = Subscriber(
            scopeID: scopeID, order: nextOrder, handler: handler)
        nextOrder &+= 1
        subscribers[id] = subscriber
        lock.unlock()
        return Subscription(id: id)
    }

    static func publish(_ event: AssistantApprovalEvent) {
        lock.lock()
        let current = subscribers.values
            .filter { $0.scopeID == nil || $0.scopeID == event.request.scopeID }
            .sorted { $0.order < $1.order }
        lock.unlock()

        guard !current.isEmpty else { return }
        let delivery: @MainActor @Sendable () -> Void = {
            for subscriber in current { subscriber.deliver(event) }
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { delivery() }
        } else {
            DispatchQueue.main.async(execute: delivery)
        }
    }

    private static func removeSubscription(id: UUID) {
        lock.lock()
        let subscriber = subscribers.removeValue(forKey: id)
        lock.unlock()
        subscriber?.cancel()
    }
}

/// Owns pending provider prompts and exact-tool session grants.
///
/// Provider adapters submit here and receive one terminal callback. UI code
/// resolves by both request id and scope, so a stale card cannot approve work
/// in another Chat. Callbacks and event publication always happen outside the
/// lock because either path may synchronously re-enter the broker.
final class AssistantApprovalBroker: @unchecked Sendable {
    static let shared = AssistantApprovalBroker()
    static let defaultTimeout: TimeInterval = 10 * 60

    typealias Completion = @Sendable (AssistantApprovalDecision) -> Void

    private struct SessionGrant: Hashable {
        let scopeID: String
        let provider: String
        let kind: AssistantApprovalRequest.Kind
        let toolName: String
    }

    private final class Pending: @unchecked Sendable {
        let request: AssistantApprovalRequest
        let completion: Completion
        var timeoutWorkItem: DispatchWorkItem?

        init(request: AssistantApprovalRequest, completion: @escaping Completion) {
            self.request = request
            self.completion = completion
        }
    }

    private let lock = NSLock()
    private var pendingByID: [String: Pending] = [:]
    private var sessionGrants = Set<SessionGrant>()

    init() {}

    func request(
        _ request: AssistantApprovalRequest,
        timeout: TimeInterval = AssistantApprovalBroker.defaultTimeout,
        completion: @escaping Completion
    ) {
        let grant = sessionGrant(for: request)
        var immediateDecision: AssistantApprovalDecision?
        var inserted: Pending?

        lock.lock()
        if sessionGrants.contains(grant) {
            immediateDecision = .allowSession
        } else if pendingByID[request.id] != nil {
            immediateDecision = .deny
        } else {
            let pending = Pending(request: request, completion: completion)
            pendingByID[request.id] = pending
            inserted = pending
        }
        lock.unlock()

        if let immediateDecision {
            completion(immediateDecision)
            return
        }
        guard let inserted else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.expire(requestID: request.id)
        }
        lock.lock()
        if pendingByID[request.id] === inserted {
            inserted.timeoutWorkItem = workItem
        }
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(timeout, 0.001), execute: workItem)
        AssistantApprovalEventBus.publish(AssistantApprovalEvent(
            request: request, state: .requested, decision: nil))
    }

    @discardableResult
    func resolve(
        id: String,
        scopeID: String,
        decision: AssistantApprovalDecision
    ) -> Bool {
        let result: Pending?
        lock.lock()
        if let pending = pendingByID[id], pending.request.scopeID == scopeID,
           pending.request.availableDecisions.contains(decision) {
            result = pendingByID.removeValue(forKey: id)
            if decision == .allowSession {
                sessionGrants.insert(sessionGrant(for: pending.request))
            }
        } else {
            result = nil
        }
        lock.unlock()

        guard let result else { return false }
        result.timeoutWorkItem?.cancel()
        AssistantApprovalEventBus.publish(AssistantApprovalEvent(
            request: result.request, state: .resolved, decision: decision))
        result.completion(decision)
        return true
    }

    /// Cancel every pending prompt and session grant owned by one backend
    /// epoch. Used when the user stops, replaces, or closes that Chat run.
    func cancel(scopeID: String) {
        let removed: [Pending]
        lock.lock()
        let ids = pendingByID.compactMap { key, value in
            value.request.scopeID == scopeID ? key : nil
        }
        removed = ids.compactMap { pendingByID.removeValue(forKey: $0) }
        sessionGrants = sessionGrants.filter { $0.scopeID != scopeID }
        lock.unlock()

        for pending in removed {
            pending.timeoutWorkItem?.cancel()
            AssistantApprovalEventBus.publish(AssistantApprovalEvent(
                request: pending.request, state: .cancelled, decision: .cancel))
            pending.completion(.cancel)
        }
    }

    func pendingRequests(scopeID: String) -> [AssistantApprovalRequest] {
        lock.lock()
        let requests = pendingByID.values
            .map(\.request)
            .filter { $0.scopeID == scopeID }
            .sorted { $0.createdAt < $1.createdAt }
        lock.unlock()
        return requests
    }

    func hasPending(scopeID: String?) -> Bool {
        guard let scopeID else { return false }
        lock.lock()
        let result = pendingByID.values.contains {
            $0.request.scopeID == scopeID
        }
        lock.unlock()
        return result
    }

    private func expire(requestID: String) {
        let pending: Pending?
        lock.lock()
        pending = pendingByID.removeValue(forKey: requestID)
        lock.unlock()
        guard let pending else { return }
        AssistantApprovalEventBus.publish(AssistantApprovalEvent(
            request: pending.request, state: .expired, decision: .cancel))
        pending.completion(.cancel)
    }

    private func sessionGrant(
        for request: AssistantApprovalRequest
    ) -> SessionGrant {
        SessionGrant(
            scopeID: request.scopeID,
            provider: request.provider.lowercased(),
            kind: request.kind,
            toolName: request.toolName)
    }
}
