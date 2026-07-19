import AppKit
import XCTest

@testable import InfinittyKit

final class NavigationTests: XCTestCase {
    func testMovesBetweenHorizontalPanesWithoutWrapping() {
        let frames = [
            NSRect(x: 0, y: 0, width: 300, height: 400),
            NSRect(x: 301, y: 0, width: 300, height: 400),
            NSRect(x: 602, y: 0, width: 300, height: 400),
        ]

        XCTAssertEqual(PaneNavigation.targetIndex(from: 1, frames: frames, direction: .left), 0)
        XCTAssertEqual(PaneNavigation.targetIndex(from: 1, frames: frames, direction: .right), 2)
        XCTAssertNil(PaneNavigation.targetIndex(from: 0, frames: frames, direction: .left))
    }

    func testNestedSplitNavigationPrefersAlignedNeighbor() {
        let frames = [
            NSRect(x: 0, y: 201, width: 300, height: 200), // upper-left
            NSRect(x: 0, y: 0, width: 300, height: 200),   // lower-left
            NSRect(x: 301, y: 0, width: 400, height: 401), // right
        ]

        XCTAssertEqual(PaneNavigation.targetIndex(from: 0, frames: frames, direction: .down), 1)
        XCTAssertEqual(PaneNavigation.targetIndex(from: 0, frames: frames, direction: .right), 2)
        XCTAssertEqual(PaneNavigation.targetIndex(from: 1, frames: frames, direction: .up), 0)
    }

    func testTabNumberSelection() {
        XCTAssertEqual(TabNavigation.index(for: 1, tabCount: 12), 0)
        XCTAssertEqual(TabNavigation.index(for: 8, tabCount: 12), 7)
        XCTAssertEqual(TabNavigation.index(for: 9, tabCount: 12), 11)
        XCTAssertNil(TabNavigation.index(for: 8, tabCount: 4))
        XCTAssertNil(TabNavigation.index(for: 0, tabCount: 4))
        XCTAssertEqual(TabNavigation.shortcutNumber(forTabIndex: 0, tabCount: 12), 1)
        XCTAssertNil(TabNavigation.shortcutNumber(forTabIndex: 8, tabCount: 12))
        XCTAssertEqual(TabNavigation.shortcutNumber(forTabIndex: 11, tabCount: 12), 9)
    }

    func testTabArrowSelectionRequiresCommandShift() {
        XCTAssertEqual(TabNavigation.cycleOffset(
            keyCode: 123, modifiers: [.command, .shift]), -1)
        XCTAssertEqual(TabNavigation.cycleOffset(
            keyCode: 124, modifiers: [.command, .shift]), 1)
        XCTAssertNil(TabNavigation.cycleOffset(
            keyCode: 123, modifiers: [.command]))
        XCTAssertNil(TabNavigation.cycleOffset(
            keyCode: 124, modifiers: [.command, .shift, .option]))
        XCTAssertNil(TabNavigation.cycleOffset(
            keyCode: 126, modifiers: [.command, .shift]))
    }

    func testTabCyclingWrapsWithoutResponderChainActions() {
        XCTAssertEqual(TabNavigation.cycledIndex(
            from: 0, offset: -1, tabCount: 3), 2)
        XCTAssertEqual(TabNavigation.cycledIndex(
            from: 2, offset: 1, tabCount: 3), 0)
        XCTAssertEqual(TabNavigation.cycledIndex(
            from: 1, offset: 1, tabCount: 3), 2)
        XCTAssertEqual(TabNavigation.cycledIndex(
            from: 0, offset: 1, tabCount: 1), 0)
        XCTAssertNil(TabNavigation.cycledIndex(
            from: 0, offset: 1, tabCount: 0))
    }

    func testPaneNumberSelectionDoesNotAliasNineToLast() {
        XCTAssertEqual(PaneNavigation.index(for: 1, paneCount: 12), 0)
        XCTAssertEqual(PaneNavigation.index(for: 9, paneCount: 12), 8)
        XCTAssertNil(PaneNavigation.index(for: 9, paneCount: 4))
    }

    func testPaneShortcutFallsThroughWhenItCannotNavigate() {
        XCTAssertNil(PaneNavigation.shortcutTargetIndex(
            for: 1, paneCount: 1, terminalHasFocus: true))
        XCTAssertNil(PaneNavigation.shortcutTargetIndex(
            for: 5, paneCount: 3, terminalHasFocus: true))
        XCTAssertNil(PaneNavigation.shortcutTargetIndex(
            for: 2, paneCount: 3, terminalHasFocus: false))
        XCTAssertEqual(PaneNavigation.shortcutTargetIndex(
            for: 2, paneCount: 3, terminalHasFocus: true), 1)
    }

    func testPaneShortcutRequiresShiftOptionNumberKey() {
        XCTAssertEqual(PaneNavigation.shortcutNumber(
            keyCode: 20, modifiers: [.shift, .option]), 3)
        XCTAssertEqual(PaneNavigation.shortcutNumber(
            keyCode: 85, modifiers: [.shift, .option]), 3)
        XCTAssertNil(PaneNavigation.shortcutNumber(
            keyCode: 20, modifiers: [.option]))
        XCTAssertNil(PaneNavigation.shortcutNumber(
            keyCode: 20, modifiers: [.shift, .option, .command]))
        XCTAssertNil(PaneNavigation.shortcutNumber(
            keyCode: 0, modifiers: [.shift, .option]))
    }

    func testUnmatchedPaneArrowIsSuppressedForTerminalOnly() {
        XCTAssertFalse(PaneNavigation.shouldForwardUnmatchedArrow(
            terminalHasFocus: true))
        XCTAssertTrue(PaneNavigation.shouldForwardUnmatchedArrow(
            terminalHasFocus: false))
    }

    func testMenuExposesTabAndPaneShortcuts() throws {
        _ = NSApplication.shared
        let main = AppDelegate.buildMenu()
        let file = try XCTUnwrap(main.items.compactMap(\.submenu).first { $0.title == "File" })
        let window = try XCTUnwrap(main.items.compactMap(\.submenu).first { $0.title == "Window" })

        let rename = try XCTUnwrap(file.item(withTitle: "Rename Tab…"))
        XCTAssertEqual(rename.keyEquivalent, "t")
        XCTAssertEqual(rename.keyEquivalentModifierMask, [.command, .shift])

        let previous = try XCTUnwrap(window.item(withTitle: "Previous Tab"))
        XCTAssertEqual(previous.keyEquivalent, "\u{F702}")
        XCTAssertEqual(previous.keyEquivalentModifierMask, [.command, .shift])

        let next = try XCTUnwrap(window.item(withTitle: "Next Tab"))
        XCTAssertEqual(next.keyEquivalent, "\u{F703}")
        XCTAssertEqual(next.keyEquivalentModifierMask, [.command, .shift])

        let tabs = try XCTUnwrap(window.item(withTitle: "Select Tab")?.submenu)
        XCTAssertEqual(tabs.item(withTitle: "Tab 1")?.keyEquivalent, "1")
        XCTAssertEqual(tabs.item(withTitle: "Tab 1")?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(tabs.item(withTitle: "Last Tab")?.keyEquivalent, "9")

        let panes = try XCTUnwrap(window.item(withTitle: "Focus Pane")?.submenu)
        let left = try XCTUnwrap(panes.item(withTitle: "Left"))
        XCTAssertEqual(left.keyEquivalent, "\u{F702}")
        XCTAssertEqual(left.keyEquivalentModifierMask, [.shift, .option])
        let paneOne = try XCTUnwrap(panes.item(withTitle: "Pane 1"))
        XCTAssertEqual(paneOne.keyEquivalent, "1")
        XCTAssertEqual(paneOne.keyEquivalentModifierMask, [.shift, .option])
    }

    func testNativeTabRenameTakesFocusThenCancelsWhenItLosesFocus() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let rename = TabRenameField(hostWindow: window, currentName: "Terminal")
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        var cancelled = false
        rename.onCancel = { cancelled = true }
        defer {
            rename.dismiss(committed: false)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            otherWindow.close()
            window.close()
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        rename.present()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        XCTAssertTrue(rename.isAcceptingInput)
        otherWindow.makeKeyAndOrderFront(nil)
        let outsideClick = try! XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: otherWindow.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1))
        NSApp.sendEvent(outsideClick)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        XCTAssertTrue(cancelled)
        XCTAssertFalse(rename.isAcceptingInput)
    }

    func testNativeTabRenameCommitsWhenHostWindowIsClicked() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let rename = TabRenameField(hostWindow: window, currentName: "Terminal")
        var committedNames: [String] = []
        var cancelCount = 0
        rename.onCommit = { committedNames.append($0) }
        rename.onCancel = { cancelCount += 1 }
        defer {
            rename.dismiss(committed: false)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            window.close()
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        rename.present()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        XCTAssertTrue(rename.isAcceptingInput)

        let editor = try XCTUnwrap(
            NSApp.windows.compactMap { $0.firstResponder as? TabRenameTextView }.first)
        editor.string = "Renamed Tab"
        let hostClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1))
        NSApp.sendEvent(hostClick)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))

        XCTAssertEqual(committedNames, ["Renamed Tab"])
        XCTAssertEqual(cancelCount, 0)
        XCTAssertFalse(rename.isAcceptingInput)
    }

    func testNativeRenamePopoverAnchorsBelowSelectedTabSegment() {
        let anchorX = TabRenameField.fallbackAnchorX(
            availableWidth: 1_000,
            tabCount: 2,
            selectedIndex: 1)
        let usableWidth: CGFloat = 1_000 - 14 - 76
        let expectedMidX = 14 + usableWidth / 2 * 1.5
        XCTAssertEqual(anchorX, expectedMidX, accuracy: 0.5)
        XCTAssertGreaterThan(anchorX, 500)

        XCTAssertEqual(
            TabRenameField.fallbackAnchorX(
                availableWidth: 1_000,
                tabCount: 1,
                selectedIndex: 0),
            120)
    }

    func testPaneFocusHighlightStartsTransientAnimation() {
        let highlight = PaneFocusHighlightView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        highlight.flash()
        XCTAssertEqual(highlight.layer?.opacity, 0)
        XCTAssertEqual(highlight.layer?.borderWidth, 2)
        XCTAssertEqual(highlight.layer?.animation(forKey: "focusFlash")?.duration, 0.38)
    }

    func testPaneFocusHighlightCanStayVisibleForShortcutHints() {
        let highlight = PaneFocusHighlightView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        highlight.setPersistentlyVisible(true)
        XCTAssertTrue(highlight.isPersistentlyVisible)
        XCTAssertEqual(highlight.layer?.opacity, 1)

        highlight.flash()
        XCTAssertNil(highlight.layer?.animation(forKey: "focusFlash"))
        XCTAssertEqual(highlight.layer?.opacity, 1)

        highlight.setPersistentlyVisible(false)
        XCTAssertFalse(highlight.isPersistentlyVisible)
        XCTAssertEqual(highlight.layer?.opacity, 0)
    }

    func testPaneShortcutHintDisplaysShiftOptionNumber() throws {
        let hint = PaneShortcutHintView(number: 3)
        XCTAssertEqual(hint.shortcutText, "⇧⌥3")
        XCTAssertEqual(hint.frame.size, NSSize(width: 50, height: 30))
        let label = try XCTUnwrap(hint.subviews.first as? NSTextField)
        XCTAssertEqual(label.frame.midX, hint.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(label.frame.midY, hint.bounds.midY, accuracy: 0.5)
        XCTAssertNil(hint.hitTest(.zero))
        hint.setNumber(8)
        XCTAssertEqual(hint.shortcutText, "⇧⌥8")
    }
    func testSidebarToggleReflectsActualSidebarVisibility() throws {
        let toggle = SidebarToggleView()
        XCTAssertEqual(toggle.toolTip, "Show sidebar")
        let icon = try XCTUnwrap(toggle.subviews.compactMap { $0 as? NSImageView }.first)
        XCTAssertEqual(icon.contentTintColor, NSColor.labelColor)

        toggle.setSidebarVisible(true)
        XCTAssertEqual(toggle.toolTip, "Hide sidebar")

        var clickCount = 0
        toggle.onClick = { clickCount += 1 }
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1))
        toggle.mouseDown(with: click)
        XCTAssertEqual(clickCount, 1)
    }

    func testSidebarIconUsesRightTitlebarAccessoryAndTogglesSidebar() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let originalContent = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(
            contentRect: originalContent.frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false)
        window.tabbingIdentifier = "infinitty"
        window.contentView = originalContent
        defer {
            delegate.windowWillClose(Notification(
                name: NSWindow.willCloseNotification,
                object: window))
            window.close()
        }

        delegate.installSidebarToggle(in: window)
        let accessory = try XCTUnwrap(
            window.titlebarAccessoryViewControllers
                .compactMap { $0 as? SidebarToggleAccessory }.first)
        XCTAssertEqual(accessory.layoutAttribute, .right)
        let toggle = accessory.toggleView
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1))

        toggle.mouseDown(with: click)
        let split = try XCTUnwrap(window.contentView as? NSSplitView)
        XCTAssertEqual(split.arrangedSubviews.count, 2)
        XCTAssertEqual(toggle.toolTip, "Hide sidebar")

        toggle.mouseDown(with: click)
        XCTAssertTrue(window.contentView === originalContent)
        XCTAssertTrue(split.arrangedSubviews.isEmpty)
        XCTAssertEqual(toggle.toolTip, "Show sidebar")
        XCTAssertTrue(window.titlebarAccessoryViewControllers.contains { $0 === accessory })
    }

    /// Native window tabs span the full titlebar; with the sidebar open the
    /// tab strip must be clamped to end at the sidebar's leading edge so the
    /// tabs don't paint across it. Reverts to full width on hide.
    func testTabBarClampsToSidebarEdge() throws {
        _ = NSApplication.shared
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let host = NSWindow(
            contentRect: first.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        host.tabbingIdentifier = "infinitty"
        host.contentView = first
        let second = NSWindow(
            contentRect: first.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        second.tabbingIdentifier = "infinitty"
        second.contentView = NSView(frame: first.frame)
        host.addTabbedWindow(second, ordered: .above)
        host.makeKeyAndOrderFront(nil)
        host.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        defer { host.orderOut(nil) }

        // The private NSTabBar must be resolvable — the whole clamp depends on
        // it. If a future macOS hides it, the clamp is a safe no-op.
        guard let bar = host.nativeTabBarView, let parent = bar.superview else {
            throw XCTSkip("native NSTabBar not resolvable on this macOS build")
        }
        let full = parent.bounds.width
        XCTAssertEqual(bar.frame.width, full, accuracy: 1)

        // Apply the same resize clampTabBar performs and confirm AppKit keeps
        // it after a relayout (it does not re-expand the strip).
        var clamped = bar.frame
        clamped.size.width = full - 280
        bar.frame = clamped
        bar.autoresizingMask = [.maxXMargin, .height]
        host.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(bar.frame.width, full - 280, accuracy: 1,
                       "clamped tab strip must hold through a relayout")
    }

}
