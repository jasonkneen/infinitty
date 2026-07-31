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
        stateLock.unlock()
        server?.stop()
    }

    func execute(_ encoded: String) -> (
        response: String,
        snapshot: CollaborationSnapshot?
    ) {
        if let response = AppSocketClient.request(
            "channel-local \(encoded)", socketPath: socketPath)
        {
            return (
                response,
                CollaborationControlCodec.snapshot(fromResponse: response))
        }
        guard ensureAuthority(),
              let response = AppSocketClient.request(
                  "channel-local \(encoded)", socketPath: socketPath)
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

        let journal = supportDirectory
            .appendingPathComponent("Infinitty", isDirectory: true)
            .appendingPathComponent("Collaboration", isDirectory: true)
            .appendingPathComponent("coordinator.jsonl")
        let room: CollaborationRoom
        do {
            room = try CollaborationRoom(
                store: JSONLCollaborationEventStore(url: journal))
        } catch {
            return false
        }

        unlink(socketPath)
        let server = AppControlServer(
            path: socketPath,
            publishesCurrentLink: false,
            replacesExistingSocket: false)
        server.handler = { [weak self, weak room] request in
            guard let self, let room else {
                return CollaborationControlCodec.response(
                    error: "coordinator_stopping",
                    message: "The shared Channel coordinator is stopping.")
            }
            if request == "ping" { return "pong" }
            let parts = request.split(
                separator: " ",
                maxSplits: 1,
                omittingEmptySubsequences: false)
            guard parts.first == "channel-local", parts.count == 2 else {
                return CollaborationControlCodec.response(
                    error: "invalid_request",
                    message: "Unknown coordinator request.")
            }
            let encoded = String(parts[1])
            let result = CollaborationControlCodec.execute(encoded, in: room)
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
        ownedServer = server
        return true
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
