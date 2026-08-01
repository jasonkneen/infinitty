import AppKit
import CoreGraphics

final class ScreenRecordingPermissionAssistant: PermissionAssistant {
    static let shared = ScreenRecordingPermissionAssistant()
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!
    static let hasPresentedDefaultsKey = "hasPresentedScreenRecordingPermissionAssistant"

    init(defaults: UserDefaults = .standard) {
        super.init(
            settingsURL: Self.settingsURL,
            defaultsKey: Self.hasPresentedDefaultsKey,
            title: "Drag Infinitty into Screen Recording",
            detail: "Then enable its switch in System Settings.",
            accessibilityLabel: "Screen Recording permission assistant",
            defaults: defaults
        )
    }

    override var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func launchAction(environment: [String: String]) -> LaunchAction {
        if environment["INFINITTY_SHOW_SCREEN_RECORDING_PERMISSION"] != nil {
            return .showExplicitly
        }
        if environment["INFINITTY_NO_ACTIVATE"] != nil {
            return .none
        }
        return .showAutomatically
    }
}
