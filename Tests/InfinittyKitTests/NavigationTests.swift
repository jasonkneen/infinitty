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

        let zoom = try XCTUnwrap(file.item(withTitle: "Toggle Pane Zoom"))
        XCTAssertEqual(zoom.keyEquivalent, "\r")
        XCTAssertEqual(zoom.keyEquivalentModifierMask, [.command, .shift])

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

    /// The custom in-pane tab strip renders one button per title, highlights
    /// the selected index, and shows/hides its close + selection state.
    func testTabStripRendersTitlesAndSelection() {
        let strip = TerminalTabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: 34))
        strip.update(titles: ["one", "two", "three"], selectedIndex: 1)
        strip.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.titlesForTesting, ["one", "two", "three"])
        XCTAssertEqual(strip.selectedIndexForTesting, 1)
        XCTAssertEqual(strip.tabButtonFramesForTesting.count, 3)
        // Tabs fill left-to-right without overlap.
        let frames = strip.tabButtonFramesForTesting
        XCTAssertLessThanOrEqual(frames[0].maxX, frames[1].minX + 0.5)
        XCTAssertLessThanOrEqual(frames[1].maxX, frames[2].minX + 0.5)
        // The + button sits to the right of the last tab.
        XCTAssertGreaterThan(strip.addButtonFrameForTesting.minX, frames[2].minX)
        XCTAssertLessThan(strip.searchButtonFrameForTesting.maxX, frames[0].minX)
        XCTAssertGreaterThanOrEqual(strip.searchButtonFrameForTesting.minX, 86)
        XCTAssertEqual(
            strip.tabButtonCornerRadiiForTesting[1], frames[1].height / 2,
            accuracy: 0.5)
        XCTAssertEqual(strip.selectionPillFrameForTesting, frames[1])
        XCTAssertGreaterThanOrEqual(strip.selectionPillAlphaForTesting, 0.16)

        strip.update(titles: ["one", "two", "three"], selectedIndex: 2)
        strip.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.selectionPillFrameForTesting, strip.tabButtonFramesForTesting[2])
    }

    func testTabCommandPaletteFiltersAndSelectsOriginalTabIndex() {
        let palette = TabCommandPaletteViewController(
            titles: ["fish", "top", "build logs"], selectedIndex: 0)
        _ = palette.view
        palette.setQueryForTesting("build")
        XCTAssertEqual(palette.filteredTitlesForTesting, ["build logs"])

        var selected: Int?
        palette.onSelect = { selected = $0 }
        palette.performFirstResultForTesting()
        XCTAssertEqual(selected, 2)
    }

    func testTabCommandPaletteOffersNewTabCommand() {
        let palette = TabCommandPaletteViewController(
            titles: ["fish"], selectedIndex: 0)
        _ = palette.view
        palette.setQueryForTesting("new")
        XCTAssertEqual(palette.filteredTitlesForTesting, ["New terminal tab"])

        var created = false
        palette.onNewTab = { created = true }
        palette.performFirstResultForTesting()
        XCTAssertTrue(created)
    }

    /// The chrome hides the strip for a single tab (matching macOS) and shows
    /// it once there are multiple.
    func testChromeHidesStripForSingleTab() {
        let chrome = TerminalChromeView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        chrome.showsStrip = false
        chrome.layoutSubtreeIfNeeded()
        XCTAssertFalse(chrome.strip.isHidden)
        XCTAssertEqual(chrome.body.frame.height, 400 - TerminalTabStripView.height, accuracy: 0.5)
        chrome.showsStrip = true
        chrome.layoutSubtreeIfNeeded()
        XCTAssertFalse(chrome.strip.isHidden)
        XCTAssertEqual(chrome.strip.frame.height, TerminalTabStripView.height, accuracy: 0.5)
        XCTAssertEqual(chrome.body.frame.height, 400 - TerminalTabStripView.height, accuracy: 0.5)
    }

    func testChromeUsesOneTintStrengthAcrossTitlebarAndBody() {
        let chrome = TerminalChromeView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        chrome.setBacking(color: NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 0.79), blur: true)
        XCTAssertEqual(chrome.strip.backgroundAlphaForTesting, 0, accuracy: 0.01)
        XCTAssertEqual(chrome.bodyBackgroundAlphaForTesting, 0, accuracy: 0.01)
        XCTAssertEqual(chrome.backingBackgroundAlphaForTesting, 0.79, accuracy: 0.01)
        XCTAssertEqual(chrome.blurSurfaceCountForTesting, 1)
    }

    /// Pinned tabs render as compact fixed-width chips; unpinned tabs take the
    /// remaining width.
    func testTabStripPinnedTabsAreCompact() {
        let strip = TerminalTabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: 34))
        let pin = TerminalTabStripView.Pin(icon: "pin.fill", color: .systemRed)
        strip.update(titles: ["pinned", "normal", "normal2"], selectedIndex: 1, pins: [0: pin])
        strip.layoutSubtreeIfNeeded()
        let frames = strip.tabButtonFramesForTesting
        XCTAssertEqual(frames.count, 3)
        // The pinned tab (index 0) is narrower than an unpinned tab.
        XCTAssertLessThan(frames[0].width, frames[1].width)
        XCTAssertLessThanOrEqual(frames[0].width, 40)
    }

    func testTabStripUsesLiveProcessIconWhenProvided() {
        let strip = TerminalTabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: 36))
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        strip.update(titles: ["shell", "btop"], selectedIndex: 1, icons: [1: icon])
        XCTAssertTrue(strip.tabButtonImagesForTesting[1] === icon)
        XCTAssertNotNil(strip.tabButtonImagesForTesting[0])
    }

    /// Side-tabs mode lays the strip out as a left column and the body fills
    /// the remaining width.
    func testChromeSideTabsLeftColumn() {
        let chrome = TerminalChromeView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        chrome.sideTabs = true
        chrome.showsStrip = true
        chrome.layoutSubtreeIfNeeded()
        // Strip is a full-height left column, not a top row.
        XCTAssertEqual(chrome.strip.frame.height, 400, accuracy: 0.5)
        XCTAssertEqual(chrome.strip.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(chrome.strip.frame.width, TerminalChromeView.sideWidth, accuracy: 0.5)
        // Body sits to the right of the strip.
        XCTAssertEqual(chrome.body.frame.minX, TerminalChromeView.sideWidth, accuracy: 0.5)
        XCTAssertEqual(chrome.body.frame.width, 800 - TerminalChromeView.sideWidth, accuracy: 0.5)
        XCTAssertFalse(chrome.strip.searchButtonFrameForTesting.isEmpty)
    }

    func testPaneDropZoneUsesDirectionalEdgesAndCenterSwap() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertEqual(PaneDropZone.resolve(point: NSPoint(x: 20, y: 150), in: bounds), .left)
        XCTAssertEqual(PaneDropZone.resolve(point: NSPoint(x: 380, y: 150), in: bounds), .right)
        XCTAssertEqual(PaneDropZone.resolve(point: NSPoint(x: 200, y: 285), in: bounds), .top)
        XCTAssertEqual(PaneDropZone.resolve(point: NSPoint(x: 200, y: 15), in: bounds), .bottom)
        XCTAssertEqual(PaneDropZone.resolve(point: NSPoint(x: 200, y: 150), in: bounds), .center)
    }

    func testPaneDropZonePreviewFramesMatchReferenceRegions() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertEqual(PaneDropZone.left.previewFrame(in: bounds), NSRect(x: 0, y: 0, width: 200, height: 300))
        XCTAssertEqual(PaneDropZone.right.previewFrame(in: bounds), NSRect(x: 200, y: 0, width: 200, height: 300))
        XCTAssertEqual(PaneDropZone.top.previewFrame(in: bounds), NSRect(x: 0, y: 150, width: 400, height: 150))
        XCTAssertEqual(PaneDropZone.bottom.previewFrame(in: bounds), NSRect(x: 0, y: 0, width: 400, height: 150))
        XCTAssertEqual(PaneDropZone.center.previewFrame(in: bounds), bounds)
    }

    func testReferencePaneMetricsKeepTerminalTextInsideCard() {
        XCTAssertEqual(PaneMetrics.inset, 5)
        XCTAssertEqual(PaneMetrics.horizontalCanvasInset, 6)
        XCTAssertEqual(PaneMetrics.cornerRadius, 10)
        XCTAssertEqual(PaneMetrics.terminalContentInset(configured: 0), 15)
        XCTAssertEqual(PaneMetrics.terminalContentInset(configured: 24), 24)
    }

    func testFocusedPaneOutlineUsesBlueStateOnlyWhenSelected() throws {
        let outline = PaneOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(outline.backgroundAlphaForTesting, 0, accuracy: 0.01)
        let idle = try XCTUnwrap(outline.layer?.borderColor)
        let idleColor = try XCTUnwrap(NSColor(cgColor: idle))
        XCTAssertEqual(idleColor.alphaComponent, 0.12, accuracy: 0.01)
        XCTAssertEqual(outline.layer?.borderWidth, 1)

        outline.isSelected = true
        let focused = try XCTUnwrap(outline.layer?.borderColor)
        let focusedColor = try XCTUnwrap(NSColor(cgColor: focused)?.usingColorSpace(.sRGB))
        XCTAssertEqual(focusedColor.alphaComponent, 0.50, accuracy: 0.01)
        XCTAssertGreaterThan(focusedColor.blueComponent, focusedColor.redComponent)
        XCTAssertEqual(outline.layer?.borderWidth, 1.5)
        XCTAssertGreaterThan(outline.backgroundAlphaForTesting, 0)
    }

    func testPaneHeaderExposesSplitZoomAndDragAccessibility() {
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: 500, height: PaneHeaderView.height))
        header.title = "fish"
        header.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.title, "fish")
        XCTAssertEqual(header.accessibilityLabel(), "Terminal pane: fish")
        XCTAssertEqual(header.splitRightAccessibilityLabelForTesting, "Split pane right")
        XCTAssertEqual(header.splitDownAccessibilityLabelForTesting, "Split pane down")
    }

    func testSplitChooserOffersExactlyTerminalFilesAndChat() {
        XCTAssertEqual(PaneType.allCases.map(\.title), ["Terminal", "Files", "Chat"])
        XCTAssertEqual(PaneType.allCases.map(\.symbol), [
            "terminal", "folder", "bubble.left.and.bubble.right",
        ])
    }

    func testUtilityPaneUsesInsetHeaderAndContent() {
        let content = NSView()
        let pane = UtilityPaneView(
            kind: .files, contentView: content, background: NSColor.black)
        pane.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.paneHeader.frame.minX, 5, accuracy: 0.5)
        XCTAssertEqual(content.frame.minX, 5, accuracy: 0.5)
        XCTAssertGreaterThan(content.frame.height, 400)
        XCTAssertEqual(pane.accessibilityLabel(), "Files panel")
        XCTAssertTrue(pane.outlineIsAboveContentForTesting)
    }

    func testUtilityPaneStaysTransparentOverSharedWindowSurface() {
        let background = NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 0.79)
        let pane = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: background, blurred: true)
        XCTAssertEqual(pane.surfaceAlphaForTesting, 0, accuracy: 0.01)
    }

    func testTerminalViewReservesTopPaneHeader() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.paneHeader.frame.minY, 300 - PaneHeaderView.height, accuracy: 0.5)
        XCTAssertEqual(view.paneHeader.frame.height, PaneHeaderView.height, accuracy: 0.5)
    }

    func testPaneLayoutSnapshotCapturesNestedSplitTopology() throws {
        let root = NSSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        root.isVertical = true
        let left = TerminalView(frame: .zero)
        let right = NSSplitView(frame: .zero)
        right.isVertical = false
        let top = TerminalView(frame: .zero)
        let bottom = TerminalView(frame: .zero)
        root.addArrangedSubview(left)
        root.addArrangedSubview(right)
        right.addArrangedSubview(top)
        right.addArrangedSubview(bottom)

        let snapshot = try XCTUnwrap(PaneLayoutController.snapshot(of: root))
        let expected = PaneLayoutNode.split(vertical: true, children: [
            .leaf(ObjectIdentifier(left)),
            .split(vertical: false, children: [
                .leaf(ObjectIdentifier(top)),
                .leaf(ObjectIdentifier(bottom)),
            ]),
        ])
        XCTAssertEqual(snapshot, expected)
    }

    func testPaneLayoutMoveReparentsLeafAtDirectionalEdge() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let original = NSSplitView(frame: host.bounds)
        original.isVertical = true
        let source = NSView(frame: .zero)
        let target = NSView(frame: .zero)
        host.addSubview(original)
        original.addArrangedSubview(source)
        original.addArrangedSubview(target)

        let result = PaneLayoutController.move(source: source, target: target, zone: .bottom)
        XCTAssertTrue(result.changed)
        let replacement = try XCTUnwrap(result.insertedSplit)
        XCTAssertFalse(replacement.isVertical)
        XCTAssertTrue(replacement.superview === host)
        XCTAssertTrue(replacement.arrangedSubviews[0] === source)
        XCTAssertTrue(replacement.arrangedSubviews[1] === target)
    }

    func testPaneLayoutCenterDropSwapsLeavesWithoutNewSplit() {
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let first = NSView(frame: .zero)
        let second = NSView(frame: .zero)
        split.addArrangedSubview(first)
        split.addArrangedSubview(second)

        let result = PaneLayoutController.move(source: first, target: second, zone: .center)
        XCTAssertTrue(result.changed)
        XCTAssertNil(result.insertedSplit)
        XCTAssertTrue(split.arrangedSubviews[0] === second)
        XCTAssertTrue(split.arrangedSubviews[1] === first)
    }

    func testPaneLayoutReplacementPreservesSplitSlotGeometry() {
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        split.isVertical = true
        let original = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        let sibling = NSView(frame: NSRect(x: 241, y: 0, width: 359, height: 400))
        split.addArrangedSubview(original)
        split.addArrangedSubview(sibling)
        original.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        sibling.frame = NSRect(x: 241, y: 0, width: 359, height: 400)
        let expected = original.frame
        let replacement = NSView(frame: .zero)

        XCTAssertTrue(PaneLayoutController.replace(original, with: replacement, in: split))
        XCTAssertEqual(replacement.frame, expected)
    }

    func testPaneLayoutDividerSnapshotRestoresAsymmetricRatio() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let split = NSSplitView(frame: host.bounds)
        split.isVertical = true
        let first = NSView(frame: .zero)
        let second = NSView(frame: .zero)
        host.addSubview(split)
        split.addArrangedSubview(first)
        split.addArrangedSubview(second)
        split.setPosition(240, ofDividerAt: 0)
        let snapshot = PaneLayoutController.captureDividerPositions(in: host)
        let saved = try XCTUnwrap(snapshot.first?.positions.first)
        split.setPosition(100, ofDividerAt: 0)

        PaneLayoutController.restoreDividerPositions(snapshot)

        XCTAssertEqual(first.frame.maxX, saved, accuracy: 0.5)
    }

}
