import AppKit
import InfinittyKit

let launchArguments = Array(CommandLine.arguments.dropFirst())
let headless = launchArguments.contains("--headless")

// `infinitty <folder>` — GitHub Desktop's custom shell, scripts, the npm
// shim. A live instance gets the folder as a new tab (focused, unless
// INFINITTY_NO_ACTIVATE says this is a background/agent launch); otherwise
// this process launches normally and opens its first window there.
let requestedDir = LaunchOptions.workingDirectory(
    from: launchArguments)

if headless {
    do {
        let environment = ProcessInfo.processInfo.environment
        let supportDirectory = environment["INFINITTY_HEADLESS_SUPPORT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let host = try HeadlessAppHost(
            instanceID: environment["INFINITTY_INSTANCE_ID"]
                ?? UUID().uuidString.lowercased(),
            socketPath: environment["INFINITTY_HEADLESS_SOCKET"],
            applicationSupportDirectory: supportDirectory,
            publishesCurrentLink:
                environment["INFINITTY_HEADLESS_PUBLISH_CURRENT"] != "0")
        try host.start(initialWorkingDirectory: requestedDir)
        let message = "infinitty: headless host \(host.instanceID) listening at "
            + "\(host.socketPath)\n"
        FileHandle.standardError.write(Data(message.utf8))
        host.waitForTerminationSignal()
        exit(0)
    } catch {
        let message = "infinitty: could not start headless host: "
            + "\(error.localizedDescription)\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(1)
    }
}

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
