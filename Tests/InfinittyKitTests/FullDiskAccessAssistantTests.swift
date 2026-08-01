import AppKit
import Foundation
import XCTest
@testable import InfinittyKit

final class FullDiskAccessAssistantTests: XCTestCase {
    func testSettingsURLTargetsAllFilesPrivacyPane() {
        XCTAssertEqual(
            FullDiskAccessAssistant.settingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
    }

    func testReadableProbeReportsGranted() throws {
        let readable = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("probe".utf8).write(to: readable)
        defer { try? FileManager.default.removeItem(at: readable) }

        XCTAssertTrue(FullDiskAccessAssistant.isGranted(probePaths: [readable.path]))
    }

    func testUnreadableProbeReportsDenied() throws {
        let unreadable = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("probe".utf8).write(to: unreadable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: unreadable.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: unreadable.path
            )
            try? FileManager.default.removeItem(at: unreadable)
        }

        XCTAssertFalse(FullDiskAccessAssistant.isGranted(probePaths: [unreadable.path]))
    }

    /// A missing probe is "can't tell", not "denied" — otherwise a machine
    /// where Apple has relocated TCC would nag on every first launch.
    func testMissingProbesDoNotReportDenied() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path

        XCTAssertTrue(FullDiskAccessAssistant.isGranted(probePaths: [missing]))
    }

    /// An existing-but-denied path must win over a later missing one, rather
    /// than falling through to the can't-tell default.
    func testDeniedProbeWinsOverLaterMissingProbe() throws {
        let unreadable = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("probe".utf8).write(to: unreadable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: unreadable.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: unreadable.path
            )
            try? FileManager.default.removeItem(at: unreadable)
        }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path

        XCTAssertFalse(FullDiskAccessAssistant.isGranted(probePaths: [unreadable.path, missing]))
    }

    func testDefaultProbeListLeadsWithTheAlwaysPresentSystemDatabase() {
        XCTAssertEqual(
            FullDiskAccessAssistant.probePaths.first,
            "/Library/Application Support/com.apple.TCC/TCC.db"
        )
    }

    func testAppMenuIncludesFullDiskAccessRecoveryAction() {
        _ = NSApplication.shared
        let appMenu = AppDelegate.buildMenu().items.first?.submenu
        let item = appMenu?.items.first {
            $0.action == #selector(AppDelegate.showFullDiskAccessPermission(_:))
        }

        XCTAssertEqual(item?.title, "Full Disk Access…")
    }

    func testLaunchPolicyPrioritizesExplicitHookAndSuppressesBackgroundAutomaticPrompt() {
        XCTAssertEqual(
            FullDiskAccessAssistant.launchAction(environment: [
                "INFINITTY_SHOW_FULL_DISK_ACCESS": "1",
                "INFINITTY_NO_ACTIVATE": "1"
            ]),
            .showExplicitly
        )
        XCTAssertEqual(
            FullDiskAccessAssistant.launchAction(environment: ["INFINITTY_NO_ACTIVATE": "1"]),
            .none
        )
        XCTAssertEqual(FullDiskAccessAssistant.launchAction(environment: [:]), .showAutomatically)
    }

    /// The once-only gate is what stops the assistant reappearing every launch.
    func testAutomaticPresentationIsSuppressedAfterItHasBeenSeen() {
        XCTAssertTrue(FullDiskAccessAssistant.shouldPresentAutomatically(
            permissionGranted: false, hasPresented: false, isPackagedApp: true
        ))
        XCTAssertFalse(FullDiskAccessAssistant.shouldPresentAutomatically(
            permissionGranted: false, hasPresented: true, isPackagedApp: true
        ))
        XCTAssertFalse(FullDiskAccessAssistant.shouldPresentAutomatically(
            permissionGranted: true, hasPresented: false, isPackagedApp: true
        ))
    }

    func testAssistantsUseSeparateDefaultsKeysSoOneDoesNotSuppressTheOther() {
        XCTAssertNotEqual(
            FullDiskAccessAssistant.hasPresentedDefaultsKey,
            ScreenRecordingPermissionAssistant.hasPresentedDefaultsKey
        )
    }
}
