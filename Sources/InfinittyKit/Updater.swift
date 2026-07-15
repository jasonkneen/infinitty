import AppKit

/// Self-contained auto-updater backed by GitHub Releases — no Sparkle, no
/// third-party deps. Checks the latest release, compares versions, and can
/// download the notarized tarball and swap the running .app in place.
final class Updater {
    static let repo = "jasonkneen/infinitty"
    private let session = URLSession(configuration: .ephemeral)
    private var checking = false

    struct Release {
        let version: String       // "0.1.1" (tag without leading v)
        let tag: String           // "v0.1.1"
        let notes: String
        let pageURL: URL
        let tarballURL: URL?      // the -macos.tar.gz asset
    }

    /// Current app version from the bundle (nil when run as a bare binary).
    static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    // MARK: - version comparison

    /// true if `a` is strictly newer than `b` (dotted numeric compare).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - network

    private func fetchLatest(_ done: @escaping (Release?) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("infinitty-updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        session.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                DispatchQueue.main.async { done(nil) }
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let notes = (json["body"] as? String) ?? ""
            let page = URL(string: (json["html_url"] as? String) ?? "https://github.com/\(Updater.repo)/releases")!
            var tarball: URL?
            if let assets = json["assets"] as? [[String: Any]] {
                for a in assets {
                    if let name = a["name"] as? String, name.hasSuffix("-macos.tar.gz"),
                       let u = a["browser_download_url"] as? String {
                        tarball = URL(string: u)
                    }
                }
            }
            let rel = Release(version: version, tag: tag, notes: notes, pageURL: page, tarballURL: tarball)
            DispatchQueue.main.async { done(rel) }
        }.resume()
    }

    // MARK: - check

    /// Called (on main) with a Release when a newer version exists — the app
    /// uses this to show the subtle top-right indicator.
    var onUpdateAvailable: ((Release) -> Void)?
    private(set) var pendingRelease: Release?

    /// userInitiated: show "you're up to date" / errors and open the prompt
    /// immediately. Auto checks stay silent and only light the indicator.
    func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        fetchLatest { [weak self] release in
            self?.checking = false
            guard let self else { return }
            guard let release else {
                if userInitiated { self.alertText("Couldn't check for updates", "Please try again later.") }
                return
            }
            guard let current = Updater.currentVersion else {
                if userInitiated {
                    self.alertText("Development build",
                        "Version info is unavailable (running unbundled). Latest release is \(release.version).")
                }
                return
            }
            if Updater.isNewer(release.version, than: current) {
                self.pendingRelease = release
                self.onUpdateAvailable?(release)        // light the indicator
                if userInitiated { self.promptUpdate(release, current: current) }
            } else if userInitiated {
                self.alertText("You're up to date", "infinitty \(current) is the latest version.")
            }
        }
    }

    /// Open the update prompt for the release the indicator represents.
    func showPendingPrompt() {
        guard let release = pendingRelease, let current = Updater.currentVersion else { return }
        promptUpdate(release, current: current)
    }

    // MARK: - UI

    private func alertText(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }

    private func promptUpdate(_ release: Release, current: String) {
        let a = NSAlert()
        a.messageText = "infinitty \(release.version) is available"
        a.informativeText = "You have \(current).\n\n"
            + String(release.notes.prefix(600))
        a.addButton(withTitle: release.tarballURL != nil ? "Install & Relaunch" : "Download")
        a.addButton(withTitle: "Release Notes")
        a.addButton(withTitle: "Later")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            if release.tarballURL != nil {
                installAndRelaunch(release)
            } else {
                NSWorkspace.shared.open(release.pageURL)
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        default:
            break
        }
    }

    // MARK: - install

    private func installAndRelaunch(_ release: Release) {
        guard let tarball = release.tarballURL,
              let appURL = Bundle.main.bundleURL as URL?,
              appURL.pathExtension == "app" else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }

        let progress = NSAlert()
        progress.messageText = "Downloading infinitty \(release.version)…"
        progress.informativeText = "The app will relaunch when the update is ready."
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        spinner.setFrameSize(NSSize(width: 24, height: 24))
        progress.accessoryView = spinner
        progress.addButton(withTitle: "Cancel")
        // Non-blocking: show, then download in background.
        let window = progress.window
        progress.layout()
        window.makeKeyAndOrderFront(nil)

        session.downloadTask(with: tarball) { [weak self] tmp, _, error in
            DispatchQueue.main.async {
                window.orderOut(nil)
                guard let self, let tmp, error == nil else {
                    self?.alertText("Download failed", "Could not download the update. Try again later.")
                    return
                }
                self.swapAndRelaunch(downloadedTarball: tmp, appURL: appURL)
            }
        }.resume()
    }

    /// Extract the new .app and hand off to a detached script that waits for
    /// this process to quit, replaces the bundle, and relaunches.
    private func swapAndRelaunch(downloadedTarball tmp: URL, appURL: URL) {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-update-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let tar = work.appendingPathComponent("update.tar.gz")
        try? FileManager.default.moveItem(at: tmp, to: tar)

        // Unpack, find the new Infinitty.app, then run the swap script.
        let script = work.appendingPathComponent("swap.sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        let body = """
        #!/bin/zsh
        set -e
        cd "\(work.path)"
        mkdir -p extracted
        tar -xzf update.tar.gz -C extracted
        NEWAPP=$(find extracted -maxdepth 3 -name Infinitty.app -type d | head -1)
        [ -n "$NEWAPP" ] || exit 1
        # wait for the running app to quit (max ~30s)
        for i in $(seq 1 300); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done
        rm -rf "\(appURL.path)"
        ditto "$NEWAPP" "\(appURL.path)"
        xattr -dr com.apple.quarantine "\(appURL.path)" 2>/dev/null || true
        open "\(appURL.path)"
        rm -rf "\(work.path)"
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = [script.path]
            try proc.run() // detached — outlives us
        } catch {
            alertText("Update failed", "Could not stage the update.")
            return
        }
        // Quit so the script can replace the bundle.
        NSApp.terminate(nil)
    }
}
