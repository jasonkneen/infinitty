import AppKit
import InfinittyKit

// `infinitty <folder>` — GitHub Desktop's custom shell, scripts, the npm
// shim. A live instance gets the folder as a new tab (focused, unless
// INFINITTY_NO_ACTIVATE says this is a background/agent launch); otherwise
// this process launches normally and opens its first window there.
let requestedDir = LaunchOptions.workingDirectory(
    from: Array(CommandLine.arguments.dropFirst()))
if let dir = requestedDir,
   let reply = AppSocketClient.request("new-tab \(dir)"),
   let pane = Int(reply) {
    if ProcessInfo.processInfo.environment["INFINITTY_NO_ACTIVATE"] == nil {
        _ = AppSocketClient.request("focus \(pane)")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
delegate.initialWorkingDirectory = requestedDir
app.delegate = delegate
app.mainMenu = AppDelegate.buildMenu()
app.run()
