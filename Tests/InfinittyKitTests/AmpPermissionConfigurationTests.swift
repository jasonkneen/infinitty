import XCTest
@testable import InfinittyKit

final class AmpPermissionConfigurationTests: XCTestCase {
    func testMergePreservesSettingsAndPrependsScopedDelegate() throws {
        let existing = Data(#"""
        {
          "amp.cacheDirectory": "/tmp/amp-cache",
          "amp.dangerouslyAllowAll": true,
          "amp.permissions": [
            {"tool":"Bash","action":"allow"}
          ]
        }
        """#.utf8)

        let data = try XCTUnwrap(AmpPermissionConfiguration.mergedSettings(
            existing: existing,
            helperPath: "/app/infinitty-mcp"))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["amp.cacheDirectory"] as? String, "/tmp/amp-cache")
        XCTAssertEqual(root["amp.dangerouslyAllowAll"] as? Bool, false)
        let permissions = try XCTUnwrap(
            root["amp.permissions"] as? [[String: Any]])
        XCTAssertEqual(permissions.count, 2)
        XCTAssertEqual(permissions[0]["tool"] as? String, "*")
        XCTAssertEqual(permissions[0]["action"] as? String, "delegate")
        XCTAssertEqual(permissions[0]["to"] as? String, "/app/infinitty-mcp")
        XCTAssertEqual(permissions[1]["tool"] as? String, "Bash")
    }

    func testMergeSupportsDocumentedJSONCSettings() throws {
        let existing = Data(#"""
        {
          // Keep URL-like strings intact.
          "amp.example": "https://example.com/a//b",
          "amp.permissions": [
            {"tool":"Read","action":"allow",},
          ],
        }
        """#.utf8)

        let data = try XCTUnwrap(AmpPermissionConfiguration.mergedSettings(
            existing: existing,
            helperPath: "/app/helper"))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["amp.example"] as? String, "https://example.com/a//b")
        XCTAssertEqual(
            (root["amp.permissions"] as? [[String: Any]])?.count,
            2)
    }

    func testTemporarySettingsAreOwnerOnlyAndRemovable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "amp-permission-config-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("settings.json")
        try Data(#"{"amp.mode":"medium"}"#.utf8).write(to: settings)

        let generated = try AmpPermissionConfiguration.writeTemporarySettings(
            helperPath: "/app/helper",
            environment: [
                "AMP_SETTINGS_FILE": settings.path,
                "HOME": directory.path,
            ])
        defer { try? FileManager.default.removeItem(at: generated) }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: generated.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: generated))
                as? [String: Any])
        XCTAssertEqual(root["amp.mode"] as? String, "medium")
    }
}
