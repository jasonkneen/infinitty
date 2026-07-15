import AppKit
import InfinittyKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = AppDelegate.buildMenu()
app.run()
