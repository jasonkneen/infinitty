import AppKit

/// Full Disk Access has no request API — no prompt exists for it, so an app
/// can only detect the grant and walk the user to System Settings.
///
/// It matters more for a terminal than for most apps: TCC attributes a child
/// process's file access to the *responsible* process, which is Infinitty. So
/// every `ls ~/Library`, every agent reading a project outside the sandbox of
/// blessed folders, is checked against Infinitty's grant, not the shell's.
final class FullDiskAccessAssistant: PermissionAssistant {
    static let shared = FullDiskAccessAssistant()
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
    static let hasPresentedDefaultsKey = "hasPresentedFullDiskAccessAssistant"

    /// Paths only a Full Disk Access grant can open. The system TCC database
    /// is the primary probe because it exists on every Mac — the per-user one
    /// is absent on machines that have never written a user-scoped grant.
    /// Safari's bookmark store is the fallback if Apple relocates TCC again.
    static let probePaths = [
        "/Library/Application Support/com.apple.TCC/TCC.db",
        NSHomeDirectory() + "/Library/Safari/Bookmarks.plist",
    ]

    /// Opening a TCC-protected file fails silently without the grant — no
    /// prompt, no dialog — which is what makes this safe to run at launch.
    static func isGranted(probePaths: [String] = probePaths) -> Bool {
        for path in probePaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let handle = FileHandle(forReadingAtPath: path) else { return false }
            try? handle.close()
            return true
        }
        // Nothing probeable on this machine: never nag about a permission we
        // cannot actually verify.
        return true
    }

    init(defaults: UserDefaults = .standard) {
        super.init(
            settingsURL: Self.settingsURL,
            defaultsKey: Self.hasPresentedDefaultsKey,
            title: "Give Infinitty Full Disk Access",
            detail: "Enable its switch, or drag it in if it isn't listed.",
            accessibilityLabel: "Full Disk Access permission assistant",
            defaults: defaults
        )
    }

    override var isGranted: Bool { Self.isGranted() }

    static func launchAction(environment: [String: String]) -> LaunchAction {
        if environment["INFINITTY_SHOW_FULL_DISK_ACCESS"] != nil {
            return .showExplicitly
        }
        if environment["INFINITTY_NO_ACTIVATE"] != nil {
            return .none
        }
        return .showAutomatically
    }
}
