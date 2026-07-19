import AppKit

extension NSView {
    fileprivate var nativeTabRootView: NSView {
        var root = self
        while let superview = root.superview { root = superview }
        return root
    }

    fileprivate func nativeTabDescendants(withClassName name: String) -> [NSView] {
        subviews.flatMap { subview in
            let match = String(describing: type(of: subview)) == name ? [subview] : []
            return match + subview.nativeTabDescendants(withClassName: name)
        }
    }
}

extension NSWindow {
    /// AppKit does not publicly expose native tab buttons. Resolve them by
    /// guarded class-name lookup and keep callers prepared for an empty result
    /// if a future macOS release changes the private view hierarchy.
    func nativeTabButtonsInVisualOrder() -> [NSView] {
        guard let root = contentView?.nativeTabRootView else { return [] }
        // A hidden NSTabBar (e.g. after closing back down to one tab) must
        // read as "no tab strip" so callers can use their bare-titlebar
        // fallbacks instead of hit-testing invisible buttons.
        let tabBars = root.nativeTabDescendants(withClassName: "NSTabBar")
        guard let tabBar = tabBars.first(where: { !$0.isHiddenOrHasHiddenAncestor })
        else { return [] }
        return tabBar
            .nativeTabDescendants(withClassName: "NSTabButton")
            .sorted { left, right in
                let leftPoint = left.convert(left.bounds.origin, to: nil)
                let rightPoint = right.convert(right.bounds.origin, to: nil)
                return leftPoint.x < rightPoint.x
            }
    }

    func nativeTabButton(atScreenPoint screenPoint: NSPoint) -> (index: Int, view: NSView)? {
        for (index, button) in nativeTabButtonsInVisualOrder().enumerated() {
            guard let buttonWindow = button.window else { continue }
            let pointInButtonWindow = buttonWindow.convertPoint(fromScreen: screenPoint)
            let pointInButton = button.convert(pointInButtonWindow, from: nil)
            if button.bounds.contains(pointInButton) { return (index, button) }
        }
        return nil
    }

    /// Hide the native window tab bar while keeping the tab group fully
    /// functional. The tab bar is an NSTitlebarAccessoryViewController AppKit
    /// attaches when tabbing is active; hiding it sticks across tab add/remove
    /// /select (verified), unlike resizing the private NSTabBar. We render our
    /// own TerminalTabStripView inside the content instead. Safe no-op if the
    /// private view layout changes in a future macOS.
    func hideNativeTabBar() {
        for accessory in titlebarAccessoryViewControllers where !accessory.isHidden {
            if accessory.view.nativeTabDescendants(withClassName: "NSTabBar").isEmpty,
               String(describing: type(of: accessory.view)) != "NSTabBar" {
                continue
            }
            accessory.isHidden = true
        }
    }
}
