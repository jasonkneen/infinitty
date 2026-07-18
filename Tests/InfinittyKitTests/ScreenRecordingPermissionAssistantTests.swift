import AppKit
import Foundation
import XCTest
@testable import InfinittyKit

final class ScreenRecordingPermissionAssistantTests: XCTestCase {
    func testOnlyExistingAppBundlesAreDraggable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent("Infinitty.app", isDirectory: true)
        let executable = root.appendingPathComponent("infinitty")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data().write(to: executable)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(ScreenRecordingPermissionAssistant.isDraggableAppURL(app))
        XCTAssertFalse(ScreenRecordingPermissionAssistant.isDraggableAppURL(executable))
        XCTAssertFalse(ScreenRecordingPermissionAssistant.isDraggableAppURL(
            root.appendingPathComponent("Missing.app", isDirectory: true)
        ))
    }

    func testAutomaticPresentationRequiresMissingPermissionUnseenAndPackagedApp() {
        XCTAssertTrue(ScreenRecordingPermissionAssistant.shouldPresentAutomatically(
            permissionGranted: false,
            hasPresented: false,
            isPackagedApp: true
        ))
        XCTAssertFalse(ScreenRecordingPermissionAssistant.shouldPresentAutomatically(
            permissionGranted: true,
            hasPresented: false,
            isPackagedApp: true
        ))
        XCTAssertFalse(ScreenRecordingPermissionAssistant.shouldPresentAutomatically(
            permissionGranted: false,
            hasPresented: true,
            isPackagedApp: true
        ))
        XCTAssertFalse(ScreenRecordingPermissionAssistant.shouldPresentAutomatically(
            permissionGranted: false,
            hasPresented: false,
            isPackagedApp: false
        ))
    }

    func testSettingsURLTargetsScreenCapturePrivacyPane() {
        XCTAssertEqual(
            ScreenRecordingPermissionAssistant.settingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    func testAppMenuIncludesScreenRecordingPermissionRecoveryAction() {
        _ = NSApplication.shared
        let appMenu = AppDelegate.buildMenu().items.first?.submenu
        let item = appMenu?.items.first {
            $0.action == #selector(AppDelegate.showScreenRecordingPermission(_:))
        }

        XCTAssertEqual(item?.title, "Screen Recording Permission…")
    }

    func testLaunchPolicyPrioritizesExplicitHookAndSuppressesBackgroundAutomaticPrompt() {
        XCTAssertEqual(
            ScreenRecordingPermissionAssistant.launchAction(environment: [
                "INFINITTY_SHOW_SCREEN_RECORDING_PERMISSION": "1",
                "INFINITTY_NO_ACTIVATE": "1"
            ]),
            .showExplicitly
        )
        XCTAssertEqual(
            ScreenRecordingPermissionAssistant.launchAction(environment: [
                "INFINITTY_NO_ACTIVATE": "1"
            ]),
            .none
        )
        XCTAssertEqual(
            ScreenRecordingPermissionAssistant.launchAction(environment: [:]),
            .showAutomatically
        )
    }
}
