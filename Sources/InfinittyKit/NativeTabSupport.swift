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
        let tabBars = root.nativeTabDescendants(withClassName: "NSTabBar")
        guard let tabBar = tabBars.first(where: { !$0.isHidden }) ?? tabBars.first else {
            return []
        }
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
}
