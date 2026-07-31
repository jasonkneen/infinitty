import XCTest

@testable import InfinittyKit

final class AppInstanceRegistryTests: XCTestCase {
    func testRegistryListsLiveInstancesAndSweepsDeadOnRegister() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-instance-test-\(UUID().uuidString)")
        let liveSocket = base.appendingPathComponent("live.sock")
        let staleSocket = base.appendingPathComponent("stale.sock")
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: liveSocket.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: staleSocket.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: base) }

        let stale = AppInstanceRegistry(
            instanceID: "stale",
            socketPath: staleSocket.path,
            pid: 999_999,
            baseDirectory: base)
        try stale.register()

        let live = AppInstanceRegistry(
            instanceID: "live",
            socketPath: liveSocket.path,
            pid: getpid(),
            baseDirectory: base)
        try live.register()

        XCTAssertEqual(
            AppInstanceRegistry.list(baseDirectory: base).map(\.id),
            ["live"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: base
                .appendingPathComponent("Infinitty/instances/stale.json").path))

        live.unregister()
        XCTAssertTrue(AppInstanceRegistry.list(baseDirectory: base).isEmpty)
    }

    func testRegistryFilesArePrivate() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-instance-mode-\(UUID().uuidString)")
        let socket = base.appendingPathComponent("instance.sock")
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: socket.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: base) }

        let registry = AppInstanceRegistry(
            instanceID: "private",
            socketPath: socket.path,
            baseDirectory: base)
        try registry.register()
        let file = base.appendingPathComponent(
            "Infinitty/instances/private.json").path
        let attributes = try FileManager.default.attributesOfItem(atPath: file)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
