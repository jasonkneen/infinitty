import CryptoKit
import Foundation

enum AgentWorkspaceMode: String, Codable, Equatable, Sendable {
    case shared
    case worktree
}

struct ProvisionedAgentWorkspace: Codable, Equatable, Sendable {
    let mode: AgentWorkspaceMode
    let path: String
    let repositoryRoot: String
    let branch: String?
}

struct AgentWorkspaceCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let currentDirectory: String?
}

struct AgentWorkspaceCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    init(
        exitCode: Int32,
        stdout: String = "",
        stderr: String = ""
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

enum AgentWorkspaceProvisionerError: LocalizedError, Equatable {
    case repositoryMissing(String)
    case invalidIdentifier(String)
    case notGitRepository(String)
    case unsafeDestination(String)
    case commandFailed(exitCode: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .repositoryMissing(let path):
            return "Workspace does not exist: \(path)"
        case .invalidIdentifier(let value):
            return "Unsafe Channel or participant identifier: \(value)"
        case .notGitRepository(let path):
            return "Workspace is not a Git repository: \(path)"
        case .unsafeDestination(let path):
            return "Refusing to use an unowned worktree destination: \(path)"
        case .commandFailed(let exitCode, let message):
            return "git worktree failed (\(exitCode)): \(message)"
        }
    }
}

/// Creates an agent workspace only after the caller has obtained a durable
/// room grant. This type has no proposal/approval API and therefore cannot
/// silently broaden consent: `.shared` returns the existing checkout without
/// side effects; `.worktree` invokes `/usr/bin/git` with an argument array.
final class AgentWorkspaceProvisioner {
    typealias CommandRunner =
        (AgentWorkspaceCommand) throws -> AgentWorkspaceCommandResult

    private let storageRoot: URL
    private let commandRunner: CommandRunner
    private let fileManager: FileManager

    init(
        storageRoot: URL = AgentWorkspaceProvisioner.defaultStorageRoot(),
        fileManager: FileManager = .default,
        commandRunner: @escaping CommandRunner =
            AgentWorkspaceProvisioner.run
    ) {
        self.storageRoot = storageRoot.standardizedFileURL
        self.fileManager = fileManager
        self.commandRunner = commandRunner
    }

    func provision(
        repositoryRoot: String,
        channelID: String,
        participantID: String,
        mode: AgentWorkspaceMode
    ) throws -> ProvisionedAgentWorkspace {
        let requested = URL(fileURLWithPath: repositoryRoot)
            .resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: requested.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw AgentWorkspaceProvisionerError.repositoryMissing(
                requested.path)
        }
        guard mode == .worktree else {
            return ProvisionedAgentWorkspace(
                mode: .shared,
                path: requested.path,
                repositoryRoot: requested.path,
                branch: nil)
        }

        let repository = try canonicalGitRoot(requested)
        let workspace = try destination(
            repositoryRoot: repository.path,
            channelID: channelID,
            participantID: participantID)
        let destinationURL = URL(fileURLWithPath: workspace.path)
        if fileManager.fileExists(atPath: destinationURL.path) {
            guard fileManager.fileExists(
                atPath: destinationURL.appendingPathComponent(".git").path)
            else {
                throw AgentWorkspaceProvisionerError.unsafeDestination(
                    destinationURL.path)
            }
            return workspace
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let result = try commandRunner(AgentWorkspaceCommand(
            executable: "/usr/bin/git",
            arguments: [
                "-C", repository.path,
                "worktree", "add", "-b",
                workspace.branch ?? "",
                destinationURL.path,
                "HEAD",
            ],
            currentDirectory: repository.path))
        guard result.exitCode == 0 else {
            let message = result.stderr
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentWorkspaceProvisionerError.commandFailed(
                exitCode: result.exitCode,
                message: message.isEmpty ? "unknown Git error" : message)
        }
        guard fileManager.fileExists(
            atPath: destinationURL.appendingPathComponent(".git").path)
        else {
            throw AgentWorkspaceProvisionerError.unsafeDestination(
                destinationURL.path)
        }
        return workspace
    }

    func destination(
        repositoryRoot: String,
        channelID: String,
        participantID: String
    ) throws -> ProvisionedAgentWorkspace {
        let repository = URL(fileURLWithPath: repositoryRoot)
            .resolvingSymlinksInPath().standardizedFileURL
        let channel = try safeComponent(channelID)
        let participant = try safeComponent(participantID)
        let repositoryHash = Self.shortDigest(repository.path)
        let destination = storageRoot
            .appendingPathComponent(repositoryHash, isDirectory: true)
            .appendingPathComponent(channel, isDirectory: true)
            .appendingPathComponent(participant, isDirectory: true)
            .standardizedFileURL
        let storagePrefix = storageRoot.path.hasSuffix("/")
            ? storageRoot.path
            : storageRoot.path + "/"
        guard destination.path.hasPrefix(storagePrefix) else {
            throw AgentWorkspaceProvisionerError.unsafeDestination(
                destination.path)
        }
        return ProvisionedAgentWorkspace(
            mode: .worktree,
            path: destination.path,
            repositoryRoot: repository.path,
            branch: "infinitty/\(channel)/\(participant)")
    }

    private func canonicalGitRoot(_ requested: URL) throws -> URL {
        let result = try commandRunner(AgentWorkspaceCommand(
            executable: "/usr/bin/git",
            arguments: [
                "-C", requested.path, "rev-parse", "--show-toplevel",
            ],
            currentDirectory: requested.path))
        guard result.exitCode == 0 else {
            throw AgentWorkspaceProvisionerError.notGitRepository(
                requested.path)
        }
        let rawRoot = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawRoot.isEmpty else {
            throw AgentWorkspaceProvisionerError.notGitRepository(
                requested.path)
        }
        return URL(fileURLWithPath: rawRoot)
            .resolvingSymlinksInPath().standardizedFileURL
    }

    private func safeComponent(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 160 else {
            throw AgentWorkspaceProvisionerError.invalidIdentifier(raw)
        }
        let mapped = trimmed.unicodeScalars.map { scalar -> Character in
            let allowed =
                CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-" || scalar == "_" || scalar == "."
            return allowed ? Character(String(scalar)) : "-"
        }
        let value = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !value.isEmpty, value != ".", value != ".." else {
            throw AgentWorkspaceProvisionerError.invalidIdentifier(raw)
        }
        return String(value.prefix(80))
    }

    private static func shortDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func defaultStorageRoot() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Infinitty", isDirectory: true)
            .appendingPathComponent("Agent Worktrees", isDirectory: true)
    }

    private static func run(
        _ command: AgentWorkspaceCommand
    ) throws -> AgentWorkspaceCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        if let currentDirectory = command.currentDirectory {
            process.currentDirectoryURL = URL(
                fileURLWithPath: currentDirectory)
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return AgentWorkspaceCommandResult(
            exitCode: process.terminationStatus,
            stdout: String(
                decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self),
            stderr: String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self))
    }
}
