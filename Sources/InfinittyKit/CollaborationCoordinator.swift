import CryptoKit
import Darwin
import Foundation

/// One local, renderer-independent Channel authority shared by every visual
/// and headless Infinitty process. The first live client owns the Unix socket;
/// if it exits, the next request takes over and replays the same durable
/// journal before answering.
final class CollaborationCoordinatorClient {
    private let supportDirectory: URL
    private let socketPath: String
    private let lockPath: String
    private let stateLock = NSLock()
    private var ownedServer: AppControlServer?
    private var ownedRoom: CollaborationRoom?
    private var ownedAuditService: CollaborationAuditService?

    init(applicationSupportDirectory: URL? = nil) {
        supportDirectory = applicationSupportDirectory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let digest = SHA256.hash(data: Data(supportDirectory.path.utf8))
        let key = digest.prefix(8).map {
            String(format: "%02x", $0)
        }.joined()
        socketPath = "/tmp/infinitty-channel-\(key).sock"
        lockPath = "/tmp/infinitty-channel-\(key).lock"
    }

    deinit {
        stateLock.lock()
        let server = ownedServer
        ownedServer = nil
        ownedRoom = nil
        ownedAuditService = nil
        stateLock.unlock()
        server?.stop()
    }

    func execute(_ encoded: String) -> (
        response: String,
        snapshot: CollaborationSnapshot?
    ) {
        request("channel-local \(encoded)")
    }

    /// Native UI confirmation crosses a distinct host-only transport. The
    /// coordinator validates the Unix peer PID against its own executable
    /// before minting the non-Codable domain authority. App control and MCP
    /// callers stay on `execute` and cannot self-assert this privilege.
    func executeHumanDecision(_ encoded: String) -> (
        response: String,
        snapshot: CollaborationSnapshot?
    ) {
        request("channel-local-human \(encoded)")
    }

    func executeAudit(_ encoded: String) -> String {
        request("audit-local \(encoded)").response
    }

    func snapshot() -> CollaborationSnapshot? {
        guard let encoded = CollaborationControlCodec.encode(
            CollaborationControlRequest(op: .snapshot))
        else { return nil }
        return execute(encoded).snapshot
    }

    private func ensureAuthority() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if AppSocketClient.request("ping", socketPath: socketPath) == "pong" {
            return true
        }

        let lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { return false }
        defer {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }
        guard flock(lockFD, LOCK_EX) == 0 else { return false }
        if AppSocketClient.request("ping", socketPath: socketPath) == "pong" {
            return true
        }

        let collaborationDirectory = supportDirectory
            .appendingPathComponent("Infinitty", isDirectory: true)
            .appendingPathComponent("Collaboration", isDirectory: true)
        let journal = collaborationDirectory
            .appendingPathComponent("coordinator.jsonl")
        let room: CollaborationRoom
        let eventStore = JSONLCollaborationEventStore(url: journal)
        do {
            room = try CollaborationRoom(
                store: eventStore)
        } catch {
            return false
        }
        let auditService = CollaborationAuditService(
            store: eventStore,
            rootDirectory: collaborationDirectory)

        unlink(socketPath)
        let server = AppControlServer(
            path: socketPath,
            publishesCurrentLink: false,
            replacesExistingSocket: false)
        server.contextualHandler = {
            [weak self, weak room, weak auditService] context, request in
            guard let self, let room, let auditService else {
                return CollaborationControlCodec.response(
                    error: "coordinator_stopping",
                    message: "The shared Channel coordinator is stopping.")
            }
            if request == "ping" { return "pong" }
            let parts = request.split(
                separator: " ",
                maxSplits: 1,
                omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                return CollaborationControlCodec.response(
                    error: "invalid_request",
                    message: "Unknown coordinator request.")
            }
            let encoded = String(parts[1])
            if parts.first == "audit-local" {
                return CollaborationAuditControlCodec.execute(
                    encoded,
                    service: auditService)
            }
            let result: (
                response: String,
                snapshot: CollaborationSnapshot?
            )
            if parts.first == "channel-local" {
                result = CollaborationControlCodec.execute(
                    encoded,
                    in: room)
            } else if parts.first == "channel-local-human" {
                guard Self.isTrustedHostPeer(context.peerProcessID) else {
                    return CollaborationControlCodec.response(
                        error: "human_decision_not_authorized",
                        message:
                            "Human decisions require a native Infinitty UI peer.")
                }
                guard case let .success(decoded) =
                        CollaborationControlCodec.decode(encoded),
                      decoded.op == .approveProposal
                        || decoded.op == .denyProposal,
                      let actor = decoded.actor,
                      actor.kind == .human
                else {
                    return CollaborationControlCodec.response(
                        error: "invalid_human_decision",
                        message:
                            "The trusted decision path accepts only human approve or deny.")
                }
                result = CollaborationControlCodec.execute(
                    encoded,
                    in: room,
                    humanDecisionAuthority: .confirmed(actorID: actor.id))
            } else {
                return CollaborationControlCodec.response(
                    error: "invalid_request",
                    message: "Unknown coordinator request.")
            }
            if result.snapshot != nil,
               case .success(let decoded) =
                   CollaborationControlCodec.decode(encoded),
               decoded.op != .snapshot
            {
                self.notifyInstances(response: result.response)
            }
            return result.response
        }
        guard server.start() else { return false }
        ownedRoom = room
        ownedAuditService = auditService
        ownedServer = server
        return true
    }

    private func request(_ command: String) -> (
        response: String,
        snapshot: CollaborationSnapshot?
    ) {
        if let response = AppSocketClient.request(
            command,
            socketPath: socketPath)
        {
            return (
                response,
                CollaborationControlCodec.snapshot(fromResponse: response))
        }
        guard ensureAuthority(),
              let response = AppSocketClient.request(
                  command,
                  socketPath: socketPath)
        else {
            return (
                CollaborationControlCodec.response(
                    error: "coordinator_unavailable",
                    message: "The shared Channel coordinator could not start."),
                nil)
        }
        return (
            response,
            CollaborationControlCodec.snapshot(fromResponse: response))
    }

    private static func isTrustedHostPeer(_ processID: pid_t) -> Bool {
        guard let peerPath = AppControlServer.executablePath(
                  for: processID),
              let ownPath = AppControlServer.executablePath(
                  for: getpid())
        else { return false }
        let peer = URL(fileURLWithPath: peerPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let own = URL(fileURLWithPath: ownPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        return peer == own
    }

    private func notifyInstances(response: String) {
        let encoded = Data(response.utf8).base64EncodedString()
        DispatchQueue.global(qos: .utility).async {
            for instance in AppInstanceRegistry.list(
                baseDirectory: self.supportDirectory)
            {
                _ = AppSocketClient.request(
                    "channel-project \(encoded)",
                    socketPath: instance.socketPath)
            }
        }
    }

    static func projectedSnapshot(from argument: String) -> CollaborationSnapshot? {
        guard let data = Data(base64Encoded: argument),
              let response = String(data: data, encoding: .utf8)
        else { return nil }
        return CollaborationControlCodec.snapshot(fromResponse: response)
    }
}
