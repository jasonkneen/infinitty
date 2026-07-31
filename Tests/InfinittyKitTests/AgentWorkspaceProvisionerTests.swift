import Foundation
import XCTest

@testable import InfinittyKit

final class AgentWorkspaceProvisionerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "infinitty-workspace-tests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testSharedWorkspaceHasNoGitOrFilesystemSideEffects() throws {
        let repository = temporaryDirectory.appendingPathComponent(
            "repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository, withIntermediateDirectories: true)
        var commands: [AgentWorkspaceCommand] = []
        let provisioner = AgentWorkspaceProvisioner(
            storageRoot: temporaryDirectory.appendingPathComponent("storage"),
            commandRunner: {
                commands.append($0)
                return AgentWorkspaceCommandResult(exitCode: 0)
            })

        let workspace = try provisioner.provision(
            repositoryRoot: repository.path,
            channelID: "channel-1",
            participantID: "agent-1",
            mode: .shared)

        XCTAssertEqual(workspace.mode, .shared)
        XCTAssertEqual(
            workspace.path,
            repository.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertNil(workspace.branch)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temporaryDirectory
                .appendingPathComponent("storage").path))
    }

    func testWorktreeWorkspaceUsesArgumentSafeGitAndStableIsolatedPath()
        throws
    {
        let repository = temporaryDirectory.appendingPathComponent(
            "repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository, withIntermediateDirectories: true)
        let storage = temporaryDirectory.appendingPathComponent(
            "storage", isDirectory: true)
        var commands: [AgentWorkspaceCommand] = []
        let provisioner = AgentWorkspaceProvisioner(
            storageRoot: storage,
            commandRunner: { command in
                commands.append(command)
                if command.arguments.last == "--show-toplevel" {
                    return AgentWorkspaceCommandResult(
                        exitCode: 0,
                        stdout: repository.path + "\n")
                }
                let destination = URL(
                    fileURLWithPath: command.arguments[
                        command.arguments.count - 2])
                try FileManager.default.createDirectory(
                    at: destination, withIntermediateDirectories: true)
                try Data("gitdir: test\n".utf8).write(
                    to: destination.appendingPathComponent(".git"))
                return AgentWorkspaceCommandResult(exitCode: 0)
            })

        let workspace = try provisioner.provision(
            repositoryRoot: repository.path,
            channelID: "release room",
            participantID: "agent/reviewer",
            mode: .worktree)

        XCTAssertEqual(workspace.mode, .worktree)
        XCTAssertTrue(workspace.path.hasPrefix(storage.path + "/"))
        XCTAssertTrue(workspace.path.contains("release-room"))
        XCTAssertTrue(workspace.path.contains("agent-reviewer"))
        XCTAssertEqual(
            workspace.branch,
            "infinitty/release-room/agent-reviewer")
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].executable, "/usr/bin/git")
        XCTAssertEqual(
            commands[0].arguments,
            ["-C", repository.path, "rev-parse", "--show-toplevel"])
        XCTAssertEqual(commands[1].arguments.prefix(5), [
            "-C", repository.path, "worktree", "add", "-b",
        ])
        XCTAssertEqual(commands[1].arguments.last, "HEAD")
        XCTAssertFalse(commands[1].arguments.contains("-c"))
    }

    func testExistingOwnedWorktreeIsIdempotent() throws {
        let repository = temporaryDirectory.appendingPathComponent(
            "repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository, withIntermediateDirectories: true)
        let storage = temporaryDirectory.appendingPathComponent(
            "storage", isDirectory: true)
        var commands: [AgentWorkspaceCommand] = []
        let provisioner = AgentWorkspaceProvisioner(
            storageRoot: storage,
            commandRunner: { command in
                commands.append(command)
                return AgentWorkspaceCommandResult(
                    exitCode: 0,
                    stdout: repository.path + "\n")
            })
        let expected = try provisioner.destination(
            repositoryRoot: repository.path,
            channelID: "room",
            participantID: "agent")
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: expected.path),
            withIntermediateDirectories: true)
        try Data("gitdir: existing\n".utf8).write(
            to: URL(fileURLWithPath: expected.path)
                .appendingPathComponent(".git"))

        let workspace = try provisioner.provision(
            repositoryRoot: repository.path,
            channelID: "room",
            participantID: "agent",
            mode: .worktree)

        XCTAssertEqual(workspace, expected)
        XCTAssertEqual(commands.count, 1)
    }

    func testWorktreeFailureReturnsTypedErrorInsteadOfPretendSuccess()
        throws
    {
        let repository = temporaryDirectory.appendingPathComponent(
            "repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository, withIntermediateDirectories: true)
        var call = 0
        let provisioner = AgentWorkspaceProvisioner(
            storageRoot: temporaryDirectory.appendingPathComponent("storage"),
            commandRunner: { _ in
                call += 1
                if call == 1 {
                    return AgentWorkspaceCommandResult(
                        exitCode: 0, stdout: repository.path + "\n")
                }
                return AgentWorkspaceCommandResult(
                    exitCode: 128, stderr: "fatal: branch exists")
            })

        XCTAssertThrowsError(try provisioner.provision(
            repositoryRoot: repository.path,
            channelID: "room",
            participantID: "agent",
            mode: .worktree)
        ) { error in
            guard case let AgentWorkspaceProvisionerError.commandFailed(
                exitCode, message) = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(exitCode, 128)
            XCTAssertEqual(message, "fatal: branch exists")
        }
    }
}
