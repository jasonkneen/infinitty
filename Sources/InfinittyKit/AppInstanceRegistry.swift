import Darwin
import Foundation

struct AppInstanceDescriptor: Codable, Equatable, Sendable {
    let id: String
    let pid: Int32
    let socketPath: String
    let startedAt: Date
    let protocolVersion: Int
    let mode: String?
}

/// File-backed discovery only; it is not the room coordinator. Each app owns
/// exactly one private descriptor and removes only that descriptor. The later
/// coordinator can replace this adapter without changing instance identities
/// or callers.
final class AppInstanceRegistry {
    private let descriptor: AppInstanceDescriptor
    private let directory: URL
    private let fileURL: URL

    init(
        instanceID: String,
        socketPath: String,
        pid: Int32 = getpid(),
        startedAt: Date = Date(),
        mode: String = "visual",
        baseDirectory: URL? = nil
    ) {
        let support = baseDirectory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = support
            .appendingPathComponent("Infinitty", isDirectory: true)
            .appendingPathComponent("instances", isDirectory: true)
        fileURL = directory.appendingPathComponent("\(instanceID).json")
        descriptor = AppInstanceDescriptor(
            id: instanceID,
            pid: pid,
            socketPath: socketPath,
            startedAt: startedAt,
            protocolVersion: 1,
            mode: mode)
    }

    func register() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try sweepStale()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(descriptor).write(to: fileURL, options: .atomic)
        _ = chmod(fileURL.path, 0o600)
    }

    func unregister() {
        guard let registered = try? Self.decode(fileURL),
              registered.id == descriptor.id,
              registered.pid == descriptor.pid
        else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    func sweepStale() throws {
        for entry in try Self.descriptors(in: directory) where !Self.isLive(entry) {
            let staleURL = directory.appendingPathComponent("\(entry.id).json")
            guard let onDisk = try? Self.decode(staleURL),
                  onDisk.pid == entry.pid else { continue }
            try? FileManager.default.removeItem(at: staleURL)
        }
    }

    static func list(baseDirectory: URL? = nil) -> [AppInstanceDescriptor] {
        let support = baseDirectory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support
            .appendingPathComponent("Infinitty", isDirectory: true)
            .appendingPathComponent("instances", isDirectory: true)
        return ((try? descriptors(in: directory)) ?? [])
            .filter(isLive)
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id < $1.id
            }
    }

    private static func descriptors(in directory: URL) throws -> [AppInstanceDescriptor] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decode($0) }
    }

    private static func decode(_ url: URL) throws -> AppInstanceDescriptor {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(
            AppInstanceDescriptor.self,
            from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    private static func isLive(_ descriptor: AppInstanceDescriptor) -> Bool {
        guard descriptor.pid > 0,
              kill(descriptor.pid, 0) == 0 || errno == EPERM
        else { return false }
        return FileManager.default.fileExists(atPath: descriptor.socketPath)
    }
}
