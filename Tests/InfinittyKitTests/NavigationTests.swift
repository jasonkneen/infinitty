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
        // Programmatic titled windows default to releasedWhenClosed; close()
        // in the defer below would over-release them under ARC and crash the
        // autorelease-pool drain at test teardown.
        window.isReleasedWhenClosed = false
        let rename = TabRenameField(hostWindow: window, currentName: "Terminal")
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        otherWindow.isReleasedWhenClosed = false
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
        window.isReleasedWhenClosed = false
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
        window.isReleasedWhenClosed = false
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
            strip.tabButtonCornerRadiiForTesting[1], 8,
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

    func testExpandedTabSelectionUsesItsPerTabTint() throws {
        let strip = TerminalTabStripView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 34))
        strip.update(
            titles: ["infinitty"], selectedIndex: 0,
            tints: [0: .systemRed])
        strip.layoutSubtreeIfNeeded()

        let tint = try XCTUnwrap(
            strip.selectionPillColorForTesting?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(tint.redComponent, tint.blueComponent)
        XCTAssertEqual(tint.alphaComponent, 0.24, accuracy: 0.01)
    }

    func testExpandedTabSelectionDefaultsToNeutralPill() throws {
        let strip = TerminalTabStripView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 34))
        strip.update(titles: ["infinitty"], selectedIndex: 0)

        let tint = try XCTUnwrap(
            strip.selectionPillColorForTesting?.usingColorSpace(.sRGB))
        XCTAssertEqual(tint.blueComponent, tint.redComponent, accuracy: 0.001)
        XCTAssertEqual(tint.alphaComponent, 0.18, accuracy: 0.01)
    }

    func testMainTabContextMenuOffersPinAndTintColorsTogether() {
        let delegate = AppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        let titles = delegate.tabPinMenuForTesting(for: window).items.map(\.title)

        XCTAssertTrue(titles.contains("Pin Tab"))
        XCTAssertTrue(titles.contains("Default Blue"))
        XCTAssertTrue(titles.contains("Red"))
        XCTAssertTrue(titles.contains("Purple"))
    }

    func testMainTabUsesAgentBrandAssetsForAgentProcesses() {
        let delegate = AppDelegate()
        XCTAssertEqual(
            delegate.tabIconAssetNameForTesting("Claude Code claude"),
            "anthropic")
        XCTAssertEqual(
            delegate.tabIconAssetNameForTesting("Codex codex"),
            "openai")
        XCTAssertNil(delegate.tabIconAssetNameForTesting("zsh"))
        XCTAssertNotNil(delegate.bundledTabIconForTesting("anthropic"))
        XCTAssertNotNil(delegate.bundledTabIconForTesting("openai"))
    }

    func testPaneInsertedAfterTintSelectionInheritsTabTint() throws {
        let delegate = AppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let session = TerminalSession(config: AppConfig(), scale: 2)
        defer { session.shutdown() }
        let terminal = session.view
        terminal.frame = window.contentView!.bounds
        window.contentView = terminal
        delegate.setTabTintForTesting(.systemRed, in: window)
        let chat = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)

        XCTAssertTrue(delegate.insertPaneViewForTesting(
            chat, relativeTo: terminal, vertical: true))
        let terminalTint = try XCTUnwrap(
            terminal.paneAccentColorForTesting.usingColorSpace(.sRGB))
        let chatTint = try XCTUnwrap(
            chat.paneAccentColorForTesting.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(terminalTint.redComponent, terminalTint.blueComponent)
        XCTAssertGreaterThan(chatTint.redComponent, chatTint.blueComponent)
    }

    func testTabStripUsesLiveProcessIconWhenProvided() {
        let strip = TerminalTabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: 36))
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        strip.update(titles: ["shell", "btop"], selectedIndex: 1, icons: [1: icon])
        XCTAssertTrue(strip.tabButtonImagesForTesting[1] === icon)
        XCTAssertNotNil(strip.tabButtonImagesForTesting[0])

        let pin = TerminalTabStripView.Pin(icon: "pin.fill", color: .systemRed)
        strip.update(
            titles: ["shell", "btop"], selectedIndex: 0,
            pins: [0: pin], icons: [0: icon])
        XCTAssertTrue(strip.tabButtonImagesForTesting[0] === icon)

        strip.update(
            titles: ["shell", "btop"], selectedIndex: 0,
            pins: [0: pin])
        XCTAssertEqual(strip.tabButtonImagesForTesting[0]?.accessibilityDescription, "shell")
    }

    func testMainTabUsesWiderShorterRoundedRectWhenSpaceAllows() throws {
        let strip = TerminalTabStripView(
            frame: NSRect(x: 0, y: 0, width: 900, height: TerminalTabStripView.height))
        strip.update(titles: ["infinitty"], selectedIndex: 0)
        strip.layoutSubtreeIfNeeded()

        let frame = try XCTUnwrap(strip.tabButtonFramesForTesting.first)
        XCTAssertEqual(frame.height, 26, accuracy: 0.5)
        XCTAssertEqual(frame.minY, 5, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(frame.width, 160)
        XCTAssertLessThanOrEqual(frame.width, 230)
        XCTAssertEqual(strip.tabButtonCornerRadiiForTesting.first, 8)
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
        XCTAssertEqual(PaneMetrics.leadingInset, 8)
        XCTAssertEqual(PaneMetrics.trailingInset, 8)
        XCTAssertEqual(PaneMetrics.internalHorizontalInset, 2)
        XCTAssertEqual(PaneMetrics.topInset, 3)
        XCTAssertEqual(PaneMetrics.bottomInset, 8)
        XCTAssertEqual(PaneMetrics.internalVerticalInset, 2)
        XCTAssertEqual(PaneMetrics.horizontalCanvasInset, 0)
        XCTAssertEqual(PaneMetrics.cornerRadius, 10)
        XCTAssertEqual(PaneMetrics.terminalContentInset(configured: 0), 15)
        XCTAssertEqual(PaneMetrics.terminalContentInset(configured: 24), 24)
    }

    func testHorizontalPaneRowPreservesDividerRatiosWhenWindowGrows() {
        let split = PaneSplitView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 500))
        split.isVertical = true
        split.dividerStyle = .thin
        let files = UtilityPaneView(
            kind: .files, contentView: NSView(), background: .black)
        let terminal = TerminalView(frame: .zero)
        let chat = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        split.addArrangedSubview(files)
        split.addArrangedSubview(terminal)
        split.addArrangedSubview(chat)
        split.adjustSubviews()
        split.setPosition(200, ofDividerAt: 0)
        split.setPosition(799, ofDividerAt: 1)
        let before = [files.frame.width, terminal.frame.width, chat.frame.width]
        let beforeAvailable = before.reduce(0, +)

        split.setFrameSize(NSSize(width: 1_200, height: 500))
        let after = [files.frame.width, terminal.frame.width, chat.frame.width]
        let afterAvailable = after.reduce(0, +)

        for index in before.indices {
            XCTAssertEqual(
                after[index] / afterAvailable,
                before[index] / beforeAvailable,
                accuracy: 0.002)
        }
    }

    func testMaximizedPaneResizeKeepsVisiblePaneInsideSplitBounds() {
        for hiddenIndex in [0, 1] {
            let split = PaneSplitView(
                frame: NSRect(x: 0, y: 0, width: 500, height: 400))
            split.isVertical = true
            split.dividerStyle = .thin
            let panes = [TerminalView(frame: .zero), TerminalView(frame: .zero)]
            panes.forEach(split.addArrangedSubview)
            split.adjustSubviews()
            panes[hiddenIndex].isHidden = true
            // Maximize/restore animation can leave the hidden pane's model
            // frame stale while the visible pane already fills the split.
            panes[hiddenIndex].frame = NSRect(
                x: hiddenIndex == 0 ? 0 : 250, y: 0, width: 250, height: 400)
            panes[1 - hiddenIndex].frame = split.bounds

            split.setFrameSize(NSSize(width: 600, height: 400))

            let visible = panes[1 - hiddenIndex]
            XCTAssertGreaterThan(visible.frame.width, 0)
            XCTAssertGreaterThanOrEqual(visible.frame.minX, split.bounds.minX - 0.5)
            XCTAssertLessThanOrEqual(visible.frame.maxX, split.bounds.maxX + 0.5)
        }
    }

    func testZoomDividerSnapshotRestoresRatioAfterResize() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let split = PaneSplitView(frame: host.bounds)
        split.isVertical = true
        host.addSubview(split)
        split.addArrangedSubview(TerminalView(frame: .zero))
        split.addArrangedSubview(TerminalView(frame: .zero))
        split.adjustSubviews()
        split.setPosition(150, ofDividerAt: 0)
        let snapshot = PaneLayoutController.captureDividerRatios(in: host)

        split.setFrameSize(NSSize(width: 1_000, height: 300))
        split.setPosition(900, ofDividerAt: 0)
        PaneLayoutController.restoreDividerRatios(snapshot)

        let divider = try XCTUnwrap(
            PaneLayoutController.captureDividerPositions(in: host).first?.positions.first)
        XCTAssertEqual(divider, 300, accuracy: 1)
    }

    func testEveryPaneUsesSubtleBlueAndFocusBrightensIt() throws {
        let outline = PaneOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let idleFillAlpha = outline.backgroundAlphaForTesting
        XCTAssertEqual(idleFillAlpha, 0.045, accuracy: 0.01)
        let idle = try XCTUnwrap(outline.layer?.borderColor)
        let idleColor = try XCTUnwrap(NSColor(cgColor: idle)?.usingColorSpace(.sRGB))
        XCTAssertEqual(idleColor.alphaComponent, 0.30, accuracy: 0.01)
        XCTAssertGreaterThan(idleColor.blueComponent, idleColor.redComponent)
        XCTAssertEqual(outline.layer?.borderWidth, 1)

        outline.isSelected = true
        let focused = try XCTUnwrap(outline.layer?.borderColor)
        let focusedColor = try XCTUnwrap(NSColor(cgColor: focused)?.usingColorSpace(.sRGB))
        XCTAssertEqual(focusedColor.alphaComponent, 0.68, accuracy: 0.01)
        XCTAssertGreaterThan(focusedColor.blueComponent, focusedColor.redComponent)
        XCTAssertEqual(outline.layer?.borderWidth, 1.5)
        XCTAssertGreaterThan(outline.backgroundAlphaForTesting, idleFillAlpha)

        outline.accentColor = .systemRed
        let custom = try XCTUnwrap(
            outline.accentColorForTesting.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(custom.redComponent, custom.blueComponent)
    }

    func testPaneHeaderExposesSplitZoomAndDragAccessibility() {
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: 500, height: PaneHeaderView.height))
        header.title = "fish"
        header.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.title, "fish")
        XCTAssertEqual(header.accessibilityLabel(), "Terminal pane: fish")
        XCTAssertEqual(header.splitRightAccessibilityLabelForTesting, "Split pane right")
        XCTAssertEqual(header.splitDownAccessibilityLabelForTesting, "Split pane down")
        XCTAssertEqual(header.iconFrameForTesting.minY, 6, accuracy: 0.5)
        XCTAssertEqual(header.titleFrameForTesting.minY, 1, accuracy: 0.5)
        XCTAssertEqual(
            header.splitRightFrameForTesting.midY,
            header.splitDownFrameForTesting.midY,
            accuracy: 0.5)
        XCTAssertEqual(
            header.iconFrameForTesting.midY,
            header.splitRightFrameForTesting.midY,
            accuracy: 0.5)
        // The title text sits 3pt below the buttons' center: the label field
        // renders its text high, so the offset optically centers it.
        XCTAssertEqual(
            header.titleFrameForTesting.midY,
            header.splitRightFrameForTesting.midY - 3,
            accuracy: 1)
        XCTAssertEqual(
            header.channelConnectorAccessibilityLabelForTesting,
            "Connect pane to a Channel")
        XCTAssertTrue(header.channelAnchorView.isAccessibilityElement())
        var channelActivated = false
        header.onChannelActivate = { channelActivated = true }
        XCTAssertTrue(header.channelAnchorView.accessibilityPerformPress())
        XCTAssertTrue(channelActivated)
        XCTAssertEqual(header.channelConnectorFrameForTesting.width, 28)
        XCTAssertLessThanOrEqual(
            header.channelConnectorFrameForTesting.maxX,
            header.splitRightFrameForTesting.minX)
    }

    func testPaneHeaderConnectorReflectsChannelMembership() {
        let header = PaneHeaderView(
            frame: NSRect(x: 0, y: 0, width: 500, height: PaneHeaderView.height))
        header.setChannel(name: "Release", color: .systemPurple, memberCount: 6)
        header.setChannelDropTarget(true)

        XCTAssertEqual(
            header.channelConnectorAccessibilityLabelForTesting,
            "Channel Release, 6 connected panes")
        XCTAssertEqual(header.channelBadgeTextForTesting, "Release · 6")
        XCTAssertFalse(header.channelBadgeIsHiddenForTesting)
        header.setChannel(name: "Channel 1", color: .systemBlue, memberCount: 2)
        XCTAssertEqual(
            header.channelConnectorAccessibilityLabelForTesting,
            "Channel 1, 2 connected panes")
        XCTAssertEqual(header.channelBadgeTextForTesting, "Channel 1 · 2")
        header.setChannel(name: nil, color: nil, memberCount: 0)
        XCTAssertTrue(header.channelBadgeIsHiddenForTesting)
    }

    func testPaneHeaderIconBecomesCloseButtonOnHoverWhenClosable() {
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: 500, height: PaneHeaderView.height))
        header.iconSymbol = "terminal"
        header.layoutSubtreeIfNeeded()

        // Without a close handler the icon never changes.
        header.simulateIconHoverForTesting(true)
        XCTAssertFalse(header.closeHoverActiveForTesting)

        var closed = 0
        header.onClose = { closed += 1 }
        header.simulateIconHoverForTesting(true)
        XCTAssertTrue(header.closeHoverActiveForTesting)
        header.simulateIconHoverForTesting(false)
        XCTAssertFalse(header.closeHoverActiveForTesting)
        XCTAssertEqual(closed, 0)
    }

    func testSplitChooserOffersTerminalFilesChatAndBrowser() {
        XCTAssertEqual(PaneType.allCases.map(\.title), ["Terminal", "Files", "Chat", "Browser"])
        XCTAssertEqual(PaneType.allCases.map(\.symbol), [
            "terminal", "folder", "bubble.left.and.bubble.right", "globe",
        ])
    }

    func testUtilityPaneUsesInsetHeaderAndContent() {
        let content = NSView()
        let pane = UtilityPaneView(
            kind: .files, contentView: content, background: NSColor.black)
        pane.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.paneHeader.frame.minX, 8, accuracy: 0.5)
        XCTAssertEqual(content.frame.minX, 8, accuracy: 0.5)
        XCTAssertEqual(content.frame.minY, PaneMetrics.bottomInset, accuracy: 0.5)
        XCTAssertGreaterThan(content.frame.height, 400)
        XCTAssertEqual(pane.accessibilityLabel(), "Files panel")
        XCTAssertTrue(pane.outlineIsAboveContentForTesting)
    }

    func testChatPanePlacesNewChatActionInPaneHeader() {
        let pane = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: NSColor.black)
        XCTAssertTrue(pane.showsNewChatInHeaderForTesting)
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
        XCTAssertEqual(
            view.paneHeader.frame.minY,
            300 - PaneHeaderView.height - PaneMetrics.topInset,
            accuracy: 0.5)
        XCTAssertEqual(view.paneHeader.frame.height, PaneHeaderView.height, accuracy: 0.5)
    }

    func testVerticallySplitPanesUseCompactSharedGap() {
        let split = PaneSplitView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        split.isVertical = false
        split.dividerStyle = .thin
        let first = TerminalView(frame: .zero)
        let second = TerminalView(frame: .zero)
        split.addArrangedSubview(first)
        split.addArrangedSubview(second)
        let divider = split.dividerThickness
        first.frame = NSRect(x: 0, y: 0, width: 500, height: 150)
        second.frame = NSRect(
            x: 0, y: 150 + divider, width: 500,
            height: 150 - divider)
        first.layoutSubtreeIfNeeded()
        second.layoutSubtreeIfNeeded()

        let firstInsets = first.paneVerticalInsets()
        let secondInsets = second.paneVerticalInsets()
        XCTAssertEqual(firstInsets.top, PaneMetrics.topInset)
        XCTAssertEqual(firstInsets.bottom, PaneMetrics.internalVerticalInset)
        XCTAssertEqual(secondInsets.top, PaneMetrics.internalVerticalInset)
        XCTAssertEqual(secondInsets.bottom, PaneMetrics.bottomInset)
    }

    func testHorizontallySplitPanesUseCompactSharedGapAndEightPointOuterEdges() {
        let split = PaneSplitView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        split.isVertical = true
        split.dividerStyle = .thin
        let first = TerminalView(frame: .zero)
        let second = TerminalView(frame: .zero)
        split.addArrangedSubview(first)
        split.addArrangedSubview(second)
        let divider = split.dividerThickness
        first.frame = NSRect(x: 0, y: 0, width: 250, height: 300)
        second.frame = NSRect(
            x: 250 + divider, y: 0,
            width: 250 - divider, height: 300)
        first.layoutSubtreeIfNeeded()
        second.layoutSubtreeIfNeeded()

        let outlines = ([first, second] as [TerminalView]).map {
            $0.outlineFrameForTesting.offsetBy(dx: $0.frame.minX, dy: $0.frame.minY)
        }.sorted { $0.minX < $1.minX }
        XCTAssertEqual(outlines[0].minX, PaneMetrics.leadingInset, accuracy: 0.5)
        XCTAssertEqual(
            split.bounds.maxX - outlines[1].maxX,
            PaneMetrics.trailingInset, accuracy: 0.5)
        XCTAssertEqual(
            outlines[1].minX - outlines[0].maxX,
            PaneMetrics.internalHorizontalInset * 2 + split.dividerThickness,
            accuracy: 0.5)
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
        XCTAssertTrue(replacement.arrangedSubviews[0] === target)
        XCTAssertTrue(replacement.arrangedSubviews[1] === source)
    }

    func testMovingChatBelowTerminalKeepsEveryPaneInsideTheRootGeometry() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1_570, height: 999))
        let root = PaneSplitView(frame: host.bounds)
        root.isVertical = true
        root.autoresizingMask = [.width, .height]
        let left = PaneSplitView(frame: .zero)
        left.isVertical = true
        let files = UtilityPaneView(
            kind: .files, contentView: NSView(), background: .black)
        let terminal = TerminalView(frame: .zero)
        let chat = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        // Live panes historically inherited root-style flexible masks before
        // being nested; exercise that reparenting path explicitly.
        files.autoresizingMask = [.width, .height]
        terminal.autoresizingMask = [.width, .height]
        chat.autoresizingMask = [.width, .height]
        left.autoresizingMask = [.width, .height]
        host.addSubview(root)
        root.addArrangedSubview(left)
        root.addArrangedSubview(chat)
        left.addArrangedSubview(files)
        left.addArrangedSubview(terminal)
        root.setPosition(1_055, ofDividerAt: 0)
        left.setPosition(350, ofDividerAt: 0)
        host.layoutSubtreeIfNeeded()

        let result = PaneLayoutController.move(
            source: chat, target: terminal, zone: .bottom)
        XCTAssertTrue(result.changed)
        if let inserted = result.insertedSplit {
            inserted.setPosition(inserted.bounds.height / 2, ofDividerAt: 0)
        }
        host.layoutSubtreeIfNeeded()

        for pane in [files, terminal, chat] {
            let frame = pane.convert(pane.bounds, to: host)
            XCTAssertGreaterThan(frame.width, 0, "pane=\(pane) frame=\(frame)")
            XCTAssertGreaterThan(frame.height, 0, "pane=\(pane) frame=\(frame)")
            XCTAssertTrue(host.bounds.contains(frame), "pane=\(pane) frame=\(frame)")
            XCTAssertFalse(pane.autoresizingMask.contains(.width))
            XCTAssertFalse(pane.autoresizingMask.contains(.height))
        }
    }

    func testBottomDropsAcceptEveryRequestedPanePairing() throws {
        func verify(source: NSView, target: NSView) throws {
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let root = PaneSplitView(frame: host.bounds)
            root.isVertical = true
            host.addSubview(root)
            root.addArrangedSubview(target)
            root.addArrangedSubview(source)
            root.adjustSubviews()

            let result = PaneLayoutController.move(
                source: source, target: target, zone: .bottom)
            let verticalStack = try XCTUnwrap(result.insertedSplit)
            XCTAssertTrue(result.changed)
            XCTAssertFalse(verticalStack.isVertical)
            XCTAssertTrue(verticalStack.arrangedSubviews[0] === target)
            XCTAssertTrue(verticalStack.arrangedSubviews[1] === source)
        }

        try verify(
            source: UtilityPaneView(kind: .chat, contentView: NSView(), background: .black),
            target: TerminalView(frame: .zero))
        try verify(
            source: UtilityPaneView(kind: .chat, contentView: NSView(), background: .black),
            target: UtilityPaneView(
                kind: .files, contentView: NSView(), background: .black))
        try verify(
            source: UtilityPaneView(kind: .files, contentView: NSView(), background: .black),
            target: TerminalView(frame: .zero))
    }

    func testTwoPaneTopAndBottomDropNeverCollapseRootGeometry() throws {
        for zone in [PaneDropZone.top, .bottom] {
            let chrome = TerminalChromeView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 646))
            let root = PaneSplitView(frame: chrome.body.bounds)
            root.isVertical = true
            root.autoresizingMask = [.width, .height]
            let terminal = TerminalView(frame: .zero)
            let utility = UtilityPaneView(
                kind: zone == .top ? .chat : .files,
                contentView: NSView(), background: .black)
            chrome.body.addSubview(root)
            root.addArrangedSubview(terminal)
            root.addArrangedSubview(utility)
            chrome.layoutSubtreeIfNeeded()
            root.adjustSubviews()

            let result = PaneLayoutController.move(
                source: utility, target: terminal, zone: zone)
            let stack = try XCTUnwrap(result.insertedSplit)
            chrome.layoutSubtreeIfNeeded()
            stack.setPosition(stack.bounds.height / 2, ofDividerAt: 0)
            chrome.layoutSubtreeIfNeeded()

            XCTAssertEqual(stack.frame, chrome.body.bounds, "zone=\(zone)")
            for pane in [terminal, utility] {
                let frame = pane.convert(pane.bounds, to: chrome.body)
                XCTAssertGreaterThan(frame.width, 0, "zone=\(zone) frame=\(frame)")
                XCTAssertGreaterThan(frame.height, 0, "zone=\(zone) frame=\(frame)")
                XCTAssertTrue(chrome.body.bounds.contains(frame), "zone=\(zone) frame=\(frame)")
            }
        }
    }

    func testPaneLifecycleKeepsTabOpenUntilFinalPaneLeafCloses() {
        XCTAssertFalse(PaneLifecyclePolicy.shouldCloseTab(remainingPaneCount: 2))
        XCTAssertFalse(PaneLifecyclePolicy.shouldCloseTab(remainingPaneCount: 1))
        XCTAssertTrue(PaneLifecyclePolicy.shouldCloseTab(remainingPaneCount: 0))
    }

    func testRootCollapseKeepsRemainingSmartPaneVisible() throws {
        let chrome = TerminalChromeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 646))
        let root = PaneSplitView(frame: chrome.body.bounds)
        root.isVertical = true
        root.autoresizingMask = [.width, .height]
        let terminal = TerminalView(frame: .zero)
        let chat = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        chrome.body.addSubview(root)
        root.addArrangedSubview(terminal)
        root.addArrangedSubview(chat)
        chrome.layoutSubtreeIfNeeded()
        root.adjustSubviews()

        terminal.removeFromSuperview()
        XCTAssertTrue(PaneLayoutController.collapseSingleChildSplit(root))
        chrome.layoutSubtreeIfNeeded()

        XCTAssertTrue(chat.superview === chrome.body)
        XCTAssertGreaterThan(chat.frame.width, 0)
        XCTAssertGreaterThan(chat.frame.height, 0)
        XCTAssertTrue(chrome.body.bounds.contains(chat.frame))
        XCTAssertEqual(
            PaneLayoutController.snapshot(of: chrome.body),
            .leaf(ObjectIdentifier(chat)))
    }

    /// Multi-chat: terminal | (chat1 / chat2). Closing the terminal must leave
    /// both chat leaves with non-zero geometry (no black empty chrome body).
    func testClosingTerminalLeavesTwoChatPanesVisible() throws {
        let chrome = TerminalChromeView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 700))
        let root = PaneSplitView(frame: chrome.body.bounds)
        root.isVertical = true
        root.autoresizingMask = [.width, .height]
        let chats = PaneSplitView(frame: .zero)
        chats.isVertical = false
        let terminal = TerminalView(frame: .zero)
        let chat1 = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        let chat2 = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        chrome.body.addSubview(root)
        root.addArrangedSubview(terminal)
        root.addArrangedSubview(chats)
        chats.addArrangedSubview(chat1)
        chats.addArrangedSubview(chat2)
        chrome.layoutSubtreeIfNeeded()
        root.adjustSubviews()
        chats.adjustSubviews()

        XCTAssertTrue(PaneLayoutController.removeLeaf(terminal, from: chrome.body))

        XCTAssertTrue(chat1.superview === chats)
        XCTAssertTrue(chat2.superview === chats)
        XCTAssertTrue(PaneLayoutController.rootInvariantHolds(in: chrome.body))
        XCTAssertEqual(chrome.body.subviews.count, 1)
        for pane in [chat1, chat2] {
            let frame = pane.convert(pane.bounds, to: chrome.body)
            XCTAssertGreaterThan(frame.width, 10, "pane frame=\(frame)")
            // The live bug: width ~495, height 0 → black window.
            XCTAssertGreaterThan(frame.height, 10, "zero-height leaf (black screen) frame=\(frame)")
            XCTAssertTrue(chrome.body.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                          "pane frame=\(frame)")
        }
        XCTAssertEqual(
            PaneLayoutController.snapshot(of: chrome.body),
            .split(vertical: false, children: [
                .leaf(ObjectIdentifier(chat1)),
                .leaf(ObjectIdentifier(chat2)),
            ]))
    }

    /// Reproduces the live sequence that previously turned two surviving chats
    /// into overlapping full-window root children after the middle chat closed.
    func testRemovingMiddleChatKeepsOneRootAndBothSurvivorsVisible() throws {
        let chrome = TerminalChromeView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 700))
        let root = PaneSplitView(frame: chrome.body.bounds)
        root.isVertical = true
        root.autoresizingMask = [.width, .height]
        let inner = PaneSplitView(frame: .zero)
        inner.isVertical = true
        let terminal = TerminalView(frame: .zero)
        let chat1 = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        let chat2 = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        let chat3 = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        chrome.body.addSubview(root)
        root.addArrangedSubview(terminal)
        root.addArrangedSubview(inner)
        inner.addArrangedSubview(chat1)
        let lastPair = PaneSplitView(frame: .zero)
        lastPair.isVertical = true
        inner.addArrangedSubview(lastPair)
        lastPair.addArrangedSubview(chat2)
        lastPair.addArrangedSubview(chat3)
        chrome.layoutSubtreeIfNeeded()
        root.adjustSubviews()
        inner.adjustSubviews()
        lastPair.adjustSubviews()

        XCTAssertTrue(PaneLayoutController.removeLeaf(terminal, from: chrome.body))
        XCTAssertTrue(PaneLayoutController.removeLeaf(chat2, from: chrome.body))

        XCTAssertTrue(PaneLayoutController.rootInvariantHolds(in: chrome.body))
        XCTAssertEqual(chrome.body.subviews.count, 1)
        XCTAssertEqual(
            PaneLayoutController.snapshot(of: chrome.body),
            .split(vertical: true, children: [
                .leaf(ObjectIdentifier(chat1)),
                .leaf(ObjectIdentifier(chat3)),
            ]))
        let firstFrame = chat1.convert(chat1.bounds, to: chrome.body)
        let secondFrame = chat3.convert(chat3.bounds, to: chrome.body)
        for frame in [firstFrame, secondFrame] {
            XCTAssertGreaterThan(frame.width, 10, "pane frame=\(frame)")
            XCTAssertGreaterThan(frame.height, 10, "pane frame=\(frame)")
            XCTAssertTrue(chrome.body.bounds.contains(frame), "pane frame=\(frame)")
        }
        XCTAssertTrue(firstFrame.intersection(secondFrame).isEmpty)
    }

    func testAppDelegateClosesExactMiddleChatWithoutDestroyingSiblings() throws {
        _ = NSApplication.shared
        ShadcnChatFeature.overrideForTesting = true
        defer { ShadcnChatFeature.overrideForTesting = nil }
        let delegate = AppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.tabbingIdentifier = "infinitty"
        window.isReleasedWhenClosed = false
        let chrome = TerminalChromeView(frame: window.contentView?.bounds ?? .zero)
        chrome.autoresizingMask = [.width, .height]
        delegate.installPaneHostForTesting(chrome, in: window)
        chrome.layoutSubtreeIfNeeded()
        defer {
            delegate.windowWillClose(Notification(
                name: NSWindow.willCloseNotification, object: window))
            window.close()
        }
        let anchor = UtilityPaneView(
            kind: .files, contentView: NSView(), background: .black)
        anchor.frame = chrome.body.bounds
        chrome.body.addSubview(anchor)
        let chat1 = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: anchor,
            forceNewInstance: true))
        chrome.layoutSubtreeIfNeeded()
        let chat2 = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: chat1,
            forceNewInstance: true))
        chrome.layoutSubtreeIfNeeded()
        let chat3 = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: chat2,
            forceNewInstance: true))
        chrome.layoutSubtreeIfNeeded()

        XCTAssertEqual(chat1.paneHeader.title, "Chat 1")
        XCTAssertEqual(chat2.paneHeader.title, "Chat 2")
        XCTAssertEqual(chat3.paneHeader.title, "Chat 3")
        XCTAssertTrue(PaneLayoutController.removeLeaf(anchor, from: chrome.body))
        XCTAssertTrue(delegate.closeUtilityPaneForTesting(chat2, in: window))

        XCTAssertEqual(delegate.utilityPaneCountForTesting(in: window), 2)
        XCTAssertNil(chat2.superview)
        XCTAssertTrue(chat1.isDescendant(of: chrome.body))
        XCTAssertTrue(chat3.isDescendant(of: chrome.body))
        XCTAssertTrue(PaneLayoutController.rootInvariantHolds(in: chrome.body))
        XCTAssertEqual(chrome.body.subviews.count, 1)
        let firstFrame = chat1.convert(chat1.bounds, to: chrome.body)
        let thirdFrame = chat3.convert(chat3.bounds, to: chrome.body)
        XCTAssertTrue(firstFrame.intersection(thirdFrame).isEmpty)
        XCTAssertGreaterThan(firstFrame.width, 10)
        XCTAssertGreaterThan(thirdFrame.width, 10)
    }

    func testConnectedChatPanesReceiveNamesMembershipAndPeerMessages() throws {
        _ = NSApplication.shared
        ShadcnChatFeature.overrideForTesting = true
        defer { ShadcnChatFeature.overrideForTesting = nil }
        let delegate = AppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.tabbingIdentifier = "infinitty"
        window.isReleasedWhenClosed = false
        let chrome = TerminalChromeView(frame: window.contentView?.bounds ?? .zero)
        chrome.autoresizingMask = [.width, .height]
        delegate.installPaneHostForTesting(chrome, in: window)
        chrome.layoutSubtreeIfNeeded()
        defer {
            delegate.windowWillClose(Notification(
                name: NSWindow.willCloseNotification, object: window))
            window.close()
        }
        let anchor = UtilityPaneView(
            kind: .files, contentView: NSView(), background: .black)
        anchor.frame = chrome.body.bounds
        chrome.body.addSubview(anchor)
        let chat1 = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: anchor,
            forceNewInstance: true))
        let chat2 = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: chat1,
            forceNewInstance: true))

        let firstTurn = expectation(description: "Chat 1 provider turn")
        let secondTurn = expectation(description: "Chat 2 provider turn")
        var firstProviderContext = ""
        var secondProviderContext = ""
        let assistant1 = PetAssistant(
            config: AppConfig(), availableChoices: [.auto],
            backendRunner: { _, _, user, _, _, _, _, done in
                DispatchQueue.main.async {
                    firstProviderContext = user
                    done(.text("Chat 1 has completed the implementation."))
                    firstTurn.fulfill()
                }
            })
        let assistant2 = PetAssistant(
            config: AppConfig(), availableChoices: [.auto],
            backendRunner: { _, _, user, _, _, _, _, done in
                DispatchQueue.main.async {
                    secondProviderContext = user
                    done(.text("Chat 2 received Chat 1's handoff."))
                    secondTurn.fulfill()
                }
            })
        delegate.installUtilityPaneAssistantForTesting(assistant1, in: chat1)
        delegate.installUtilityPaneAssistantForTesting(assistant2, in: chat2)

        let linked = expectation(description: "Channel link committed")
        delegate.linkCollaborationPanesForTesting(
            source: chat1, target: chat2
        ) { result in
            if case .failure(let error) = result {
                XCTFail("Channel link failed: \(error)")
            }
            linked.fulfill()
        }
        wait(for: [linked], timeout: 3)

        XCTAssertEqual(chat1.paneHeader.title, "Chat 1")
        XCTAssertEqual(chat2.paneHeader.title, "Chat 2")
        XCTAssertEqual(chat1.paneHeader.channelBadgeTextForTesting, "Channel 1 · 2")
        XCTAssertEqual(chat2.paneHeader.channelBadgeTextForTesting, "Channel 1 · 2")
        XCTAssertEqual(
            delegate.collaborationContextForTesting(pane: chat1)?
                .peers.map(\.displayName),
            ["Chat 2"])
        XCTAssertEqual(
            delegate.collaborationContextForTesting(pane: chat2)?
                .peers.map(\.displayName),
            ["Chat 1"])

        let firstTranscript = assistant1.makeSidebarPanelView()
        assistant1.submitForQA("Tell the Channel what you completed.")
        wait(for: [firstTurn], timeout: 3)
        let visibleAnswerDeadline = Date(timeIntervalSinceNow: 3)
        while !firstTranscript.transcriptForTesting.contains(
            "Chat 1 has completed the implementation."),
            Date() < visibleAnswerDeadline
        {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertTrue(firstTranscript.transcriptForTesting.contains(
            "Chat 1 has completed the implementation."))
        XCTAssertTrue(firstProviderContext.contains("Your participant name: \"Chat 1\""))
        XCTAssertTrue(firstProviderContext.contains("- \"Chat 2\" [chat]"))

        // Submit as soon as Chat 1's answer is visible. Chat 2's provider
        // context must wait behind the queued durable publication instead of
        // racing the eventually-applied AppKit projection.
        assistant2.submitForQA("What did the other Chat report?")
        wait(for: [secondTurn], timeout: 3)
        XCTAssertTrue(secondProviderContext.contains("Your participant name: \"Chat 2\""))
        XCTAssertTrue(secondProviderContext.contains("- \"Chat 1\" [chat]"))
        XCTAssertTrue(secondProviderContext.contains(
            "- \"Chat 1\": \"Chat 1 has completed the implementation.\""))

        let chat3 = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: chat2,
            forceNewInstance: true))
        let thirdLinked = expectation(description: "third Chat joined")
        delegate.linkCollaborationPanesForTesting(
            source: chat1, target: chat3
        ) { result in
            if case .failure(let error) = result {
                XCTFail("Third Channel link failed: \(error)")
            }
            thirdLinked.fulfill()
        }
        wait(for: [thirdLinked], timeout: 3)
        XCTAssertEqual(chat1.paneHeader.channelBadgeTextForTesting, "Channel 1 · 3")
        XCTAssertEqual(
            delegate.collaborationContextForTesting(pane: chat1)?
                .peers.map(\.displayName),
            ["Chat 2", "Chat 3"])
        chat1.paneHeader.title = "Lead Agent"
        chat1.paneHeader.onRenameCommit?("Lead Agent")
        XCTAssertEqual(
            delegate.collaborationContextForTesting(pane: chat1)?
                .identity.displayName,
            "Lead Agent")
        XCTAssertEqual(
            delegate.collaborationContextForTesting(pane: chat3)?
                .peers.map(\.displayName),
            ["Chat 2", "Lead Agent"])

        XCTAssertTrue(delegate.closeUtilityPaneForTesting(chat2, in: window))
        XCTAssertEqual(chat1.paneHeader.channelBadgeTextForTesting, "Channel 1 · 2")
        XCTAssertEqual(
            delegate.collaborationContextForTesting(pane: chat1)?
                .peers.map(\.displayName),
            ["Chat 3"])
        XCTAssertTrue(delegate.closeUtilityPaneForTesting(chat3, in: window))
        XCTAssertEqual(chat1.paneHeader.channelBadgeTextForTesting, "Channel 1 · 1")
        XCTAssertEqual(
            delegate.collaborationContextForTesting(pane: chat1)?
                .peers.map(\.displayName),
            [])
    }

    func testTerminalExitThenMiddleChatClosePreservesRealChatPanesAndOwners() throws {
        _ = NSApplication.shared
        ShadcnChatFeature.overrideForTesting = true
        defer { ShadcnChatFeature.overrideForTesting = nil }
        let delegate = AppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let chrome = TerminalChromeView(frame: window.contentView?.bounds ?? .zero)
        chrome.autoresizingMask = [.width, .height]
        delegate.installPaneHostForTesting(chrome, in: window)
        chrome.layoutSubtreeIfNeeded()
        defer {
            delegate.windowWillClose(Notification(
                name: NSWindow.willCloseNotification, object: window))
            window.close()
        }

        let bootstrap = UtilityPaneView(
            kind: .files, contentView: NSView(), background: .black)
        bootstrap.frame = chrome.body.bounds
        chrome.body.addSubview(bootstrap)
        let terminal = try XCTUnwrap(delegate.splitTerminalForTesting(
            relativeTo: bootstrap, vertical: true))
        XCTAssertTrue(PaneLayoutController.removeLeaf(bootstrap, from: chrome.body))
        let terminalPet = delegate.petAssistantForTesting(terminal)
        let chat1 = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: terminal.view,
            forceNewInstance: true))
        let chat2 = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: chat1,
            forceNewInstance: true))
        let chat3 = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: chat2,
            forceNewInstance: true))
        let assistant1 = try XCTUnwrap(delegate.utilityPaneAssistantForTesting(chat1))
        let assistant2 = try XCTUnwrap(delegate.utilityPaneAssistantForTesting(chat2))
        let assistant3 = try XCTUnwrap(delegate.utilityPaneAssistantForTesting(chat3))
        chrome.layoutSubtreeIfNeeded()

        delegate.sessionDidExitForTesting(terminal)

        XCTAssertEqual(delegate.utilityPaneCountForTesting(in: window), 3)
        XCTAssertNil(terminal.view.superview)
        XCTAssertNil(terminalPet.onPetMessage)
        XCTAssertFalse(assistant1.isAttached(to: terminal))
        XCTAssertFalse(assistant2.isAttached(to: terminal))
        XCTAssertFalse(assistant3.isAttached(to: terminal))
        XCTAssertTrue(delegate.utilityPaneAssistantForTesting(chat1) === assistant1)
        XCTAssertTrue(delegate.utilityPaneAssistantForTesting(chat2) === assistant2)
        XCTAssertTrue(delegate.utilityPaneAssistantForTesting(chat3) === assistant3)
        XCTAssertTrue(PaneLayoutController.rootInvariantHolds(in: chrome.body))
        XCTAssertEqual(chrome.body.subviews.count, 1)
        chrome.layoutSubtreeIfNeeded()
        let chat1RatioBeforeMiddleClose =
            chat1.convert(chat1.bounds, to: chrome.body).width / chrome.body.bounds.width

        XCTAssertTrue(delegate.closeUtilityPaneForTesting(chat2, in: window))

        XCTAssertEqual(delegate.utilityPaneCountForTesting(in: window), 2)
        XCTAssertNil(chat2.superview)
        XCTAssertNil(assistant2.onPetMessage)
        XCTAssertTrue(delegate.utilityPaneAssistantForTesting(chat1) === assistant1)
        XCTAssertTrue(delegate.utilityPaneAssistantForTesting(chat3) === assistant3)
        XCTAssertNotNil(assistant1.onPetMessage)
        XCTAssertNotNil(assistant3.onPetMessage)
        XCTAssertTrue(chat1.isDescendant(of: chrome.body))
        XCTAssertTrue(chat3.isDescendant(of: chrome.body))
        XCTAssertTrue(PaneLayoutController.rootInvariantHolds(in: chrome.body))
        XCTAssertEqual(chrome.body.subviews.count, 1)
        chrome.layoutSubtreeIfNeeded()
        let firstFrame = chat1.convert(chat1.bounds, to: chrome.body)
        let thirdFrame = chat3.convert(chat3.bounds, to: chrome.body)
        XCTAssertEqual(
            firstFrame.width / chrome.body.bounds.width,
            chat1RatioBeforeMiddleClose,
            accuracy: 0.03)
        for frame in [firstFrame, thirdFrame] {
            XCTAssertGreaterThan(frame.width, 10, "pane frame=\(frame)")
            XCTAssertGreaterThan(frame.height, 10, "pane frame=\(frame)")
            XCTAssertTrue(chrome.body.bounds.contains(frame), "pane frame=\(frame)")
        }
        XCTAssertTrue(firstFrame.intersection(thirdFrame).isEmpty)
    }

    func testChatSplitMovesSharedPetOwnershipAndCloseReopenKeepsSessionsIsolated() throws {
        _ = NSApplication.shared
        ShadcnChatFeature.overrideForTesting = true
        defer { ShadcnChatFeature.overrideForTesting = nil }
        let delegate = AppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let chrome = TerminalChromeView(frame: window.contentView?.bounds ?? .zero)
        chrome.autoresizingMask = [.width, .height]
        delegate.installPaneHostForTesting(chrome, in: window)
        chrome.layoutSubtreeIfNeeded()
        defer {
            delegate.windowWillClose(Notification(
                name: NSWindow.willCloseNotification, object: window))
            window.close()
        }

        let anchor = UtilityPaneView(
            kind: .files, contentView: NSView(), background: .black)
        anchor.frame = chrome.body.bounds
        chrome.body.addSubview(anchor)
        let source = try XCTUnwrap(delegate.splitTerminalForTesting(
            relativeTo: anchor, vertical: true))
        var submittedRequests: [String] = []
        var requestCompletion: PetAssistant.AskCompletion?
        let controlledPet = PetAssistant(
            config: AppConfig(),
            availableChoices: [.auto],
            requestRunner: { request, _, _, completion in
                submittedRequests.append(request)
                requestCompletion = completion
            })
        delegate.installPetAssistantForTesting(controlledPet, for: source)
        let sourcePet = delegate.petAssistantForTesting(source)
        XCTAssertTrue(sourcePet === controlledPet)
        window.makeFirstResponder(source.view)
        let chat = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: source.view))
        XCTAssertTrue(delegate.utilityPaneAssistantForTesting(chat) === sourcePet)

        let splitSession = try XCTUnwrap(delegate.splitTerminalForTesting(
            relativeTo: chat, vertical: true))

        XCTAssertTrue(sourcePet.isAttached(to: splitSession))
        XCTAssertTrue(delegate.petAssistantForTesting(splitSession) === sourcePet)
        let replacementSourcePet = delegate.petAssistantForTesting(source)
        XCTAssertFalse(replacementSourcePet === sourcePet)
        XCTAssertTrue(replacementSourcePet.isAttached(to: source))

        sourcePet.submitForQA("finish after the Chat closes")
        XCTAssertEqual(submittedRequests, ["finish after the Chat closes"])
        let finishRequest = try XCTUnwrap(requestCompletion)
        XCTAssertTrue(delegate.closeUtilityPaneForTesting(chat, in: window))
        let survivingSplitPet = delegate.petAssistantForTesting(splitSession)
        XCTAssertTrue(survivingSplitPet === sourcePet)
        XCTAssertTrue(sourcePet.isAttached(to: splitSession))
        XCTAssertNotNil(sourcePet.onPetMessage)
        finishRequest("answer survived the ownership handoff", [], nil)
        let retainedTranscript = survivingSplitPet.makeSidebarPanelView()
            .transcriptForTesting
        XCTAssertTrue(retainedTranscript.contains("finish after the Chat closes"))
        XCTAssertTrue(retainedTranscript.contains("answer survived the ownership handoff"))

        window.makeFirstResponder(source.view)
        let reopened = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: source.view))
        XCTAssertTrue(
            delegate.utilityPaneAssistantForTesting(reopened) === replacementSourcePet)
        XCTAssertFalse(
            delegate.utilityPaneAssistantForTesting(reopened) === sourcePet)
    }

    func testChatSplitUsesItsAttachedTerminalContextInsteadOfFocusedSibling() throws {
        _ = NSApplication.shared
        ShadcnChatFeature.overrideForTesting = false
        defer { ShadcnChatFeature.overrideForTesting = nil }
        let delegate = AppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let chrome = TerminalChromeView(frame: window.contentView?.bounds ?? .zero)
        delegate.installPaneHostForTesting(chrome, in: window)
        chrome.layoutSubtreeIfNeeded()
        defer {
            delegate.windowWillClose(Notification(
                name: NSWindow.willCloseNotification, object: window))
            window.close()
        }

        let anchor = UtilityPaneView(
            kind: .files, contentView: NSView(), background: .black)
        anchor.frame = chrome.body.bounds
        chrome.body.addSubview(anchor)
        let attached = try XCTUnwrap(delegate.splitTerminalForTesting(
            relativeTo: anchor, vertical: true))
        let unrelated = try XCTUnwrap(delegate.splitTerminalForTesting(
            relativeTo: attached.view, vertical: false))
        attached.workingDirectory = "/tmp/chat-attached-context"
        unrelated.workingDirectory = "/tmp/unrelated-focused-context"

        window.makeFirstResponder(attached.view)
        let chat = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: attached.view))
        let chatAssistant = try XCTUnwrap(
            delegate.utilityPaneAssistantForTesting(chat))
        XCTAssertTrue(chatAssistant.isAttached(to: attached))

        window.makeFirstResponder(unrelated.view)
        XCTAssertTrue(
            delegate.sourceSessionForSplitForTesting(relativeTo: chat) === attached)
        let expectedDirectory = attached.currentDirectory()
        let split = try XCTUnwrap(delegate.splitTerminalForTesting(
            relativeTo: chat, vertical: true))

        XCTAssertEqual(split.workingDirectory, expectedDirectory)
        XCTAssertTrue(chatAssistant.isAttached(to: split))
        XCTAssertFalse(chatAssistant.isAttached(to: unrelated))
    }

    func testForceNewChatSplitKeepsPaneAssistantOutOfPetOwnership() throws {
        _ = NSApplication.shared
        ShadcnChatFeature.overrideForTesting = false
        defer { ShadcnChatFeature.overrideForTesting = nil }
        let delegate = AppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let chrome = TerminalChromeView(frame: window.contentView?.bounds ?? .zero)
        delegate.installPaneHostForTesting(chrome, in: window)
        chrome.layoutSubtreeIfNeeded()
        defer {
            delegate.windowWillClose(Notification(
                name: NSWindow.willCloseNotification, object: window))
            window.close()
        }

        let anchor = UtilityPaneView(
            kind: .files, contentView: NSView(), background: .black)
        anchor.frame = chrome.body.bounds
        chrome.body.addSubview(anchor)
        let source = try XCTUnwrap(delegate.splitTerminalForTesting(
            relativeTo: anchor, vertical: true))
        let sourcePet = delegate.petAssistantForTesting(source)
        let chat = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: source.view,
            forceNewInstance: true))
        let paneAssistant = try XCTUnwrap(
            delegate.utilityPaneAssistantForTesting(chat))

        XCTAssertFalse(paneAssistant === sourcePet)
        XCTAssertTrue(paneAssistant.isAttached(to: source))
        XCTAssertNotNil(paneAssistant.onPetMessage)

        let split = try XCTUnwrap(delegate.splitTerminalForTesting(
            relativeTo: chat, vertical: true))
        XCTAssertTrue(paneAssistant.isAttached(to: split))
        let splitPet = delegate.petAssistantForTesting(split)

        XCTAssertFalse(splitPet === paneAssistant)
        XCTAssertFalse(splitPet === sourcePet)
        XCTAssertTrue(splitPet.isAttached(to: split))
        XCTAssertTrue(sourcePet.isAttached(to: source))

        XCTAssertTrue(delegate.closeUtilityPaneForTesting(chat, in: window))
        XCTAssertNil(paneAssistant.onPetMessage)
        XCTAssertNil(paneAssistant.onShowInSidePanel)
        XCTAssertTrue(splitPet.isAttached(to: split))
        XCTAssertNotNil(splitPet.onPetMessage)
        XCTAssertTrue(sourcePet.isAttached(to: source))
    }

    func testBackgroundQuickTabEOFUsesOwningPageAndRetainsSmartPane() throws {
        _ = NSApplication.shared
        ShadcnChatFeature.overrideForTesting = false
        defer { ShadcnChatFeature.overrideForTesting = nil }
        let delegate = AppDelegate()
        var cleanupSessions: [TerminalSession] = []
        var cleanupPanes: [UtilityPaneView] = []
        defer {
            for pane in cleanupPanes {
                if let window = pane.window {
                    _ = delegate.closeUtilityPaneForTesting(pane, in: window)
                }
            }
            cleanupSessions.forEach(delegate.sessionDidExitForTesting)
        }

        let (window, first) = try XCTUnwrap(
            delegate.ensureQuickTerminalForTesting())
        cleanupSessions.append(first)
        let firstRoot = try XCTUnwrap(
            delegate.quickTerminalRootForTesting(containing: first))
        let firstChat = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: first.view,
            forceNewInstance: true))
        cleanupPanes.append(firstChat)
        let firstAssistant = try XCTUnwrap(
            delegate.utilityPaneAssistantForTesting(firstChat))
        let sibling = try XCTUnwrap(delegate.splitTerminalForTesting(
            relativeTo: first.view, vertical: true))
        cleanupSessions.append(sibling)

        let second = try XCTUnwrap(delegate.newQuickTerminalTabForTesting())
        cleanupSessions.append(second)
        let secondRoot = try XCTUnwrap(
            delegate.quickTerminalRootForTesting(containing: second))
        let secondChat = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: second.view,
            forceNewInstance: true))
        cleanupPanes.append(secondChat)
        let secondAssistant = try XCTUnwrap(
            delegate.utilityPaneAssistantForTesting(secondChat))
        let firstLayoutHost = try XCTUnwrap(
            delegate.quickTerminalLayoutHostForTesting(containing: firstChat))
        let secondLayoutHost = try XCTUnwrap(
            delegate.quickTerminalLayoutHostForTesting(containing: secondChat))

        XCTAssertTrue(delegate.quickTerminalActiveRootForTesting === secondRoot)
        XCTAssertEqual(delegate.quickTerminalTabCountForTesting, 2)
        XCTAssertTrue(firstAssistant.isAttached(to: first))
        XCTAssertTrue(secondAssistant.isAttached(to: second))

        delegate.sessionDidExitForTesting(first)

        XCTAssertTrue(delegate.quickTerminalActiveRootForTesting === secondRoot)
        let activeResponder = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertTrue(
            activeResponder === secondRoot
                || activeResponder.isDescendant(of: secondRoot))
        XCTAssertNil(first.view.superview)
        XCTAssertTrue(sibling.view.isDescendant(of: firstRoot))
        XCTAssertTrue(firstChat.isDescendant(of: firstRoot))
        XCTAssertTrue(firstAssistant.isAttached(to: sibling))
        XCTAssertTrue(secondAssistant.isAttached(to: second))
        XCTAssertEqual(delegate.utilityPaneCountForTesting(
            in: window, rootedAt: firstRoot), 1)
        XCTAssertEqual(delegate.utilityPaneCountForTesting(
            in: window, rootedAt: secondRoot), 1)
        XCTAssertTrue(PaneLayoutController.rootInvariantHolds(in: firstLayoutHost))
        XCTAssertTrue(PaneLayoutController.rootInvariantHolds(in: secondLayoutHost))

        delegate.sessionDidExitForTesting(sibling)

        XCTAssertEqual(delegate.quickTerminalTabCountForTesting, 2)
        XCTAssertTrue(delegate.quickTerminalActiveRootForTesting === secondRoot)
        XCTAssertTrue(firstChat.isDescendant(of: firstRoot))
        XCTAssertFalse(firstAssistant.isAttached(to: sibling))
        XCTAssertEqual(
            PaneLayoutController.snapshot(of: firstRoot),
            .leaf(ObjectIdentifier(firstChat)))

        // A real EOF arriving after this explicit teardown is idempotent.
        delegate.sessionDidExitForTesting(sibling)
        XCTAssertEqual(delegate.quickTerminalTabCountForTesting, 2)
        XCTAssertTrue(firstChat.isDescendant(of: firstRoot))

        XCTAssertTrue(delegate.closeQuickTerminalTabForTesting(containing: firstChat))
        XCTAssertEqual(delegate.quickTerminalTabCountForTesting, 1)
        XCTAssertTrue(delegate.quickTerminalActiveRootForTesting === secondRoot)
        XCTAssertTrue(secondChat.isDescendant(of: secondRoot))
        XCTAssertNil(firstAssistant.onPetMessage)
        XCTAssertTrue(secondAssistant.isAttached(to: second))

        XCTAssertTrue(delegate.closeUtilityPaneForTesting(secondChat, in: window))
        delegate.sessionDidExitForTesting(second)
        XCTAssertEqual(delegate.quickTerminalTabCountForTesting, 0)
    }

    func testUtilityCloseFailureRetainsLivePaneAndBackingRecord() throws {
        _ = NSApplication.shared
        ShadcnChatFeature.overrideForTesting = true
        defer { ShadcnChatFeature.overrideForTesting = nil }
        let delegate = AppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let chrome = TerminalChromeView(frame: window.contentView?.bounds ?? .zero)
        delegate.installPaneHostForTesting(chrome, in: window)
        chrome.layoutSubtreeIfNeeded()
        defer {
            delegate.windowWillClose(Notification(
                name: NSWindow.willCloseNotification, object: window))
            window.close()
        }

        let anchor = UtilityPaneView(
            kind: .files, contentView: NSView(), background: .black)
        anchor.frame = chrome.body.bounds
        chrome.body.addSubview(anchor)
        let source = try XCTUnwrap(delegate.splitTerminalForTesting(
            relativeTo: anchor, vertical: true))
        window.makeFirstResponder(source.view)
        let chat = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: source.view))
        let retainedAssistant = try XCTUnwrap(
            delegate.utilityPaneAssistantForTesting(chat))
        let retainedController = try XCTUnwrap(
            delegate.utilityPaneControllerForTesting(chat))
        let retainedSubviewCount = chat.subviews.count
        let layoutBranch = try XCTUnwrap(chrome.body.subviews.first {
            PaneLayoutController.snapshot(of: $0) != nil
        })
        let invalidWrapper = NSView(frame: layoutBranch.frame)
        XCTAssertTrue(PaneLayoutController.replace(
            layoutBranch, with: invalidWrapper, in: chrome.body))
        layoutBranch.frame = invalidWrapper.bounds
        layoutBranch.autoresizingMask = [.width, .height]
        invalidWrapper.addSubview(layoutBranch)
        XCTAssertFalse(PaneLayoutController.rootInvariantHolds(in: chrome.body))

        XCTAssertFalse(delegate.closeUtilityPaneForTesting(chat, in: window))
        XCTAssertEqual(delegate.utilityPaneCountForTesting(in: window), 1)
        XCTAssertTrue(chat.window === window)
        XCTAssertTrue(chat.isDescendant(of: chrome.body))
        XCTAssertEqual(chat.subviews.count, retainedSubviewCount)
        XCTAssertTrue(
            delegate.utilityPaneAssistantForTesting(chat) === retainedAssistant)
        XCTAssertTrue(
            delegate.utilityPaneControllerForTesting(chat) === retainedController)
        XCTAssertNotNil(retainedAssistant.onPetMessage)
    }

    func testTerminalExitFallbackRemovesDeadLeafAndInvalidatesUnownedAssistant() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let chrome = TerminalChromeView(frame: window.contentView?.bounds ?? .zero)
        delegate.installPaneHostForTesting(chrome, in: window)
        chrome.layoutSubtreeIfNeeded()
        defer {
            delegate.windowWillClose(Notification(
                name: NSWindow.willCloseNotification, object: window))
            window.close()
        }

        let anchor = UtilityPaneView(
            kind: .files, contentView: NSView(), background: .black)
        anchor.frame = chrome.body.bounds
        chrome.body.addSubview(anchor)
        let session = try XCTUnwrap(delegate.splitTerminalForTesting(
            relativeTo: anchor, vertical: true))
        let assistant = delegate.petAssistantForTesting(session)
        XCTAssertNotNil(assistant.onPetMessage)
        let split = try XCTUnwrap(session.view.superview as? NSSplitView)
        let index = try XCTUnwrap(split.arrangedSubviews.firstIndex(of: session.view))
        let invalidWrapper = NSView(frame: session.view.frame)
        split.removeArrangedSubview(session.view)
        session.view.removeFromSuperview()
        split.insertArrangedSubview(invalidWrapper, at: index)
        invalidWrapper.addSubview(session.view)

        delegate.sessionDidExitForTesting(session)

        XCTAssertNil(session.view.superview)
        XCTAssertNil(assistant.onPetMessage)
        XCTAssertNil(assistant.onShowInSidePanel)
        XCTAssertTrue(PaneLayoutController.rootInvariantHolds(in: chrome.body))
        XCTAssertEqual(PaneLayoutController.snapshot(of: chrome.body),
                       .leaf(ObjectIdentifier(anchor)))
    }

    func testTerminalExitFallbackNeverPrunesCorruptWrapperContainingLiveChats() throws {
        _ = NSApplication.shared
        ShadcnChatFeature.overrideForTesting = false
        defer { ShadcnChatFeature.overrideForTesting = nil }
        let delegate = AppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let chrome = TerminalChromeView(frame: window.contentView?.bounds ?? .zero)
        delegate.installPaneHostForTesting(chrome, in: window)
        chrome.layoutSubtreeIfNeeded()
        defer {
            delegate.windowWillClose(Notification(
                name: NSWindow.willCloseNotification, object: window))
            window.close()
        }

        let anchor = UtilityPaneView(
            kind: .files, contentView: NSView(), background: .black)
        anchor.frame = chrome.body.bounds
        chrome.body.addSubview(anchor)
        let session = try XCTUnwrap(delegate.splitTerminalForTesting(
            relativeTo: anchor, vertical: true))
        let firstChat = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: session.view,
            forceNewInstance: true))
        let secondChat = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: firstChat,
            forceNewInstance: true))
        let firstAssistant = try XCTUnwrap(
            delegate.utilityPaneAssistantForTesting(firstChat))
        let secondAssistant = try XCTUnwrap(
            delegate.utilityPaneAssistantForTesting(secondChat))

        // Model a legacy malformed branch with one valid sibling and one
        // snapshot-less plain wrapper containing two live Chat leaves. The old
        // EOF fallback saw only the valid sibling and replaced the whole outer
        // wrapper with it, orphaning both Chats.
        let layoutBranch = try XCTUnwrap(chrome.body.subviews.first {
            PaneLayoutController.containsLayoutLeaf($0)
        })
        let outerWrapper = NSView(frame: layoutBranch.frame)
        XCTAssertTrue(PaneLayoutController.replace(
            layoutBranch, with: outerWrapper, in: chrome.body))
        for view in [anchor, session.view, firstChat, secondChat] {
            view.removeFromSuperview()
        }
        let corruptChatWrapper = NSView(frame: outerWrapper.bounds)
        corruptChatWrapper.addSubview(firstChat)
        corruptChatWrapper.addSubview(secondChat)
        outerWrapper.addSubview(session.view)
        outerWrapper.addSubview(corruptChatWrapper)
        outerWrapper.addSubview(anchor)
        XCTAssertFalse(PaneLayoutController.rootInvariantHolds(in: chrome.body))

        delegate.sessionDidExitForTesting(session)

        XCTAssertNil(session.view.superview)
        XCTAssertTrue(firstChat.isDescendant(of: chrome.body))
        XCTAssertTrue(secondChat.isDescendant(of: chrome.body))
        XCTAssertEqual(delegate.utilityPaneCountForTesting(in: window), 2)
        XCTAssertTrue(
            delegate.utilityPaneAssistantForTesting(firstChat) === firstAssistant)
        XCTAssertTrue(
            delegate.utilityPaneAssistantForTesting(secondChat) === secondAssistant)
        XCTAssertNotNil(firstAssistant.onPetMessage)
        XCTAssertNotNil(secondAssistant.onPetMessage)
    }

    func testTerminalExitFallbackUnwrapsSurvivingUtilityFromLegacyWrapper() throws {
        _ = NSApplication.shared
        ShadcnChatFeature.overrideForTesting = false
        defer { ShadcnChatFeature.overrideForTesting = nil }
        let delegate = AppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let chrome = TerminalChromeView(frame: window.contentView?.bounds ?? .zero)
        delegate.installPaneHostForTesting(chrome, in: window)
        chrome.layoutSubtreeIfNeeded()
        defer {
            delegate.windowWillClose(Notification(
                name: NSWindow.willCloseNotification, object: window))
            window.close()
        }

        let anchor = UtilityPaneView(
            kind: .files, contentView: NSView(), background: .black)
        anchor.frame = chrome.body.bounds
        chrome.body.addSubview(anchor)
        let session = try XCTUnwrap(delegate.splitTerminalForTesting(
            relativeTo: anchor, vertical: true))
        var requestCompletion: PetAssistant.AskCompletion?
        let controlledAssistant = PetAssistant(
            config: AppConfig(),
            availableChoices: [.auto],
            requestRunner: { _, _, _, completion in
                requestCompletion = completion
            })
        delegate.installPetAssistantForTesting(controlledAssistant, for: session)
        window.makeFirstResponder(session.view)
        let survivor = try XCTUnwrap(delegate.openUtilityPaneForTesting(
            .chat, in: window, relativeTo: session.view))
        let retainedController = try XCTUnwrap(
            delegate.utilityPaneControllerForTesting(survivor))
        XCTAssertTrue(
            delegate.utilityPaneAssistantForTesting(survivor) === controlledAssistant)

        let nestedSplit = try XCTUnwrap(session.view.superview as? NSSplitView)
        XCTAssertTrue(nestedSplit.arrangedSubviews.contains(survivor))
        let parent = try XCTUnwrap(nestedSplit.superview)
        let wrapper = NSView(frame: nestedSplit.frame)
        XCTAssertTrue(PaneLayoutController.replace(
            nestedSplit, with: wrapper, in: parent))
        session.view.removeFromSuperview()
        survivor.removeFromSuperview()
        let halfWidth = wrapper.bounds.width / 2
        session.view.frame = NSRect(
            x: 0, y: 0, width: halfWidth, height: wrapper.bounds.height)
        survivor.frame = NSRect(
            x: halfWidth, y: 0,
            width: wrapper.bounds.width - halfWidth, height: wrapper.bounds.height)
        wrapper.addSubview(session.view)
        wrapper.addSubview(survivor)
        controlledAssistant.submitForQA("finish after terminal exit")
        let finishRequest = try XCTUnwrap(requestCompletion)

        delegate.sessionDidExitForTesting(session)
        chrome.layoutSubtreeIfNeeded()
        finishRequest("answer retained by surviving Chat", [], nil)

        XCTAssertNil(session.view.superview)
        XCTAssertTrue(survivor.window === window)
        XCTAssertTrue(survivor.isDescendant(of: chrome.body))
        XCTAssertEqual(delegate.utilityPaneCountForTesting(in: window), 1)
        XCTAssertTrue(
            delegate.utilityPaneControllerForTesting(survivor) === retainedController)
        XCTAssertTrue(
            delegate.utilityPaneAssistantForTesting(survivor) === controlledAssistant)
        XCTAssertFalse(controlledAssistant.isAttached(to: session))
        XCTAssertNotNil(controlledAssistant.onPetMessage)
        let transcript = controlledAssistant.makeSidebarPanelView()
            .transcriptForTesting
        XCTAssertTrue(transcript.contains("finish after terminal exit"))
        XCTAssertTrue(transcript.contains("answer retained by surviving Chat"))
        XCTAssertTrue(PaneLayoutController.rootInvariantHolds(in: chrome.body))
        let roots = chrome.body.subviews.filter {
            PaneLayoutController.snapshot(of: $0) != nil
        }
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(
            PaneLayoutController.snapshot(of: chrome.body),
            .split(
                vertical: true,
                children: [
                    .leaf(ObjectIdentifier(anchor)),
                    .leaf(ObjectIdentifier(survivor)),
                ]))
        XCTAssertGreaterThan(survivor.frame.width, 0)
        XCTAssertGreaterThan(survivor.frame.height, 0)

        XCTAssertTrue(delegate.closeUtilityPaneForTesting(survivor, in: window))
        XCTAssertNil(controlledAssistant.onPetMessage)
        XCTAssertNil(controlledAssistant.onShowInSidePanel)
        XCTAssertEqual(delegate.utilityPaneCountForTesting(in: window), 0)
        XCTAssertEqual(
            PaneLayoutController.snapshot(of: chrome.body),
            .leaf(ObjectIdentifier(anchor)))
    }

    func testPaneRemovalPreservesUnaffectedDividerRatio() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 600))
        let root = PaneSplitView(frame: host.bounds)
        root.isVertical = true
        root.autoresizingMask = [.width, .height]
        let left = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        let right = PaneSplitView(frame: .zero)
        right.isVertical = false
        let top = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        let bottom = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        host.addSubview(root)
        root.addArrangedSubview(left)
        root.addArrangedSubview(right)
        right.addArrangedSubview(top)
        right.addArrangedSubview(bottom)
        root.adjustSubviews()
        right.adjustSubviews()
        root.setPosition(320, ofDividerAt: 0)
        let ratioBefore = left.frame.maxX / root.bounds.width

        XCTAssertTrue(PaneLayoutController.removeLeaf(top, from: host))

        let ratioAfter = left.frame.maxX / root.bounds.width
        XCTAssertEqual(ratioAfter, ratioBefore, accuracy: 0.02)
        XCTAssertTrue(PaneLayoutController.rootInvariantHolds(in: host))
        XCTAssertTrue(right.superview == nil)
        XCTAssertTrue(bottom.superview === root)
    }

    func testRootNormalizationRepairsOverlappingLayoutBranches() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let first = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        let second = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        first.frame = host.bounds
        second.frame = host.bounds
        host.addSubview(first)
        host.addSubview(second)

        XCTAssertFalse(PaneLayoutController.rootInvariantHolds(in: host))
        XCTAssertTrue(PaneLayoutController.normalizeRoot(in: host))
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(PaneLayoutController.rootInvariantHolds(in: host))
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertTrue(first.isDescendant(of: host))
        XCTAssertTrue(second.isDescendant(of: host))
        XCTAssertEqual(
            PaneLayoutController.snapshot(of: host),
            .split(vertical: true, children: [
                .leaf(ObjectIdentifier(first)),
                .leaf(ObjectIdentifier(second)),
            ]))
        let firstFrame = first.convert(first.bounds, to: host)
        let secondFrame = second.convert(second.bounds, to: host)
        XCTAssertTrue(firstFrame.intersection(secondFrame).isEmpty)
        XCTAssertGreaterThan(firstFrame.width, 10)
        XCTAssertGreaterThan(secondFrame.width, 10)
    }

    func testRootInvariantRejectsPlainWrapperWithMultiplePaneLeaves() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let corruptWrapper = NSView(frame: host.bounds)
        let terminal = TerminalView(frame: corruptWrapper.bounds)
        let chat = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        chat.frame = corruptWrapper.bounds
        host.addSubview(corruptWrapper)
        corruptWrapper.addSubview(terminal)
        corruptWrapper.addSubview(chat)

        XCTAssertNil(PaneLayoutController.snapshot(of: corruptWrapper))
        XCTAssertFalse(PaneLayoutController.rootInvariantHolds(in: host))
        XCTAssertFalse(PaneLayoutController.removeLeaf(chat, from: host))
        XCTAssertTrue(chat.isDescendant(of: host))
        XCTAssertTrue(terminal.isDescendant(of: host))
    }

    func testRootInvariantRejectsCorruptWrapperBesideValidBranch() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let validChat = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        let corruptWrapper = NSView(frame: host.bounds)
        let firstHiddenChat = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        let secondHiddenChat = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        host.addSubview(validChat)
        host.addSubview(corruptWrapper)
        corruptWrapper.addSubview(firstHiddenChat)
        corruptWrapper.addSubview(secondHiddenChat)

        XCTAssertFalse(PaneLayoutController.rootInvariantHolds(in: host))
        XCTAssertFalse(PaneLayoutController.removeLeaf(validChat, from: host))
        XCTAssertTrue(validChat.isDescendant(of: host))
        XCTAssertTrue(firstHiddenChat.isDescendant(of: host))
        XCTAssertTrue(secondHiddenChat.isDescendant(of: host))
    }

    func testRemovingFinalLeafLeavesEmptyValidHost() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let chat = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        chat.frame = host.bounds
        host.addSubview(chat)

        XCTAssertTrue(PaneLayoutController.removeLeaf(chat, from: host))

        XCTAssertTrue(PaneLayoutController.rootInvariantHolds(in: host))
        XCTAssertTrue(host.subviews.isEmpty)
        XCTAssertNil(chat.superview)
    }

    func testRootNormalizationCollapsesLegacySingleChildSplit() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let redundant = PaneSplitView(frame: host.bounds)
        redundant.isVertical = true
        let chat = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        host.addSubview(redundant)
        redundant.addArrangedSubview(chat)

        XCTAssertFalse(PaneLayoutController.rootInvariantHolds(in: host))
        XCTAssertTrue(PaneLayoutController.normalizeRoot(in: host))

        XCTAssertTrue(PaneLayoutController.rootInvariantHolds(in: host))
        XCTAssertTrue(chat.superview === host)
        XCTAssertNil(redundant.superview)
        XCTAssertGreaterThan(chat.bounds.width, 0)
        XCTAssertGreaterThan(chat.bounds.height, 0)
    }

    func testZeroSizedNestedSurvivorStaysInsideOneRoot() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let outer = PaneSplitView(frame: host.bounds)
        outer.isVertical = true
        outer.autoresizingMask = [.width, .height]
        let terminal = TerminalView(frame: .zero)
        let nested = PaneSplitView(frame: .zero)
        nested.isVertical = false
        let first = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        let second = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        host.addSubview(outer)
        outer.addArrangedSubview(terminal)
        outer.addArrangedSubview(nested)
        nested.addArrangedSubview(first)
        nested.addArrangedSubview(second)
        first.frame = .zero
        second.frame = .zero

        XCTAssertTrue(PaneLayoutController.removeLeaf(terminal, from: host))

        XCTAssertTrue(PaneLayoutController.rootInvariantHolds(in: host))
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertTrue(host.subviews.first === nested)
        XCTAssertTrue(first.isDescendant(of: host))
        XCTAssertTrue(second.isDescendant(of: host))
        XCTAssertGreaterThan(first.bounds.width, 0)
        XCTAssertGreaterThan(first.bounds.height, 0)
        XCTAssertGreaterThan(second.bounds.width, 0)
        XCTAssertGreaterThan(second.bounds.height, 0)
    }

    func testNormalizeThenMoveMaintainsSingleRootAndLeafIdentity() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let first = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        let second = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        let third = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        for pane in [first, second, third] {
            pane.frame = host.bounds
            host.addSubview(pane)
        }

        XCTAssertTrue(PaneLayoutController.normalizeRoot(in: host))
        let result = PaneLayoutController.move(
            source: third, target: first, zone: .bottom)
        XCTAssertTrue(result.changed)
        PaneLayoutController.stabilizeRoot(in: host)

        XCTAssertTrue(PaneLayoutController.rootInvariantHolds(in: host))
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertEqual(
            Set([first, second, third].filter { $0.isDescendant(of: host) }
                .map(ObjectIdentifier.init)),
            Set([first, second, third].map(ObjectIdentifier.init)))
    }

    func testNestedTerminalCloseKeepsTerminalAndChatGeometry() throws {
        let chrome = TerminalChromeView(
            frame: NSRect(x: 0, y: 0, width: 1_050, height: 646))
        let root = PaneSplitView(frame: chrome.body.bounds)
        root.isVertical = true
        root.autoresizingMask = [.width, .height]
        let terminals = PaneSplitView(frame: .zero)
        terminals.isVertical = false
        let firstTerminal = TerminalView(frame: .zero)
        let closingTerminal = TerminalView(frame: .zero)
        let chat = UtilityPaneView(
            kind: .chat, contentView: NSView(), background: .black)
        chrome.body.addSubview(root)
        root.addArrangedSubview(terminals)
        root.addArrangedSubview(chat)
        terminals.addArrangedSubview(firstTerminal)
        terminals.addArrangedSubview(closingTerminal)
        chrome.layoutSubtreeIfNeeded()
        root.adjustSubviews()
        terminals.adjustSubviews()

        closingTerminal.removeFromSuperview()
        XCTAssertTrue(PaneLayoutController.collapseSingleChildSplit(terminals))
        chrome.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            PaneLayoutController.snapshot(of: chrome.body),
            .split(vertical: true, children: [
                .leaf(ObjectIdentifier(firstTerminal)),
                .leaf(ObjectIdentifier(chat)),
            ]))
        for pane in [firstTerminal, chat] {
            let frame = pane.convert(pane.bounds, to: chrome.body)
            XCTAssertGreaterThan(frame.width, 0, "pane=\(pane) frame=\(frame)")
            XCTAssertGreaterThan(frame.height, 0, "pane=\(pane) frame=\(frame)")
            XCTAssertTrue(chrome.body.bounds.contains(frame), "pane=\(pane) frame=\(frame)")
        }
    }

    func testRepeatedNestedPaneMovesPreserveEveryLeafIdentity() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let root = PaneSplitView(frame: host.bounds)
        root.isVertical = true
        let left = TerminalView(frame: .zero)
        let right = PaneSplitView(frame: .zero)
        right.isVertical = false
        let top = TerminalView(frame: .zero)
        let bottom = TerminalView(frame: .zero)
        host.addSubview(root)
        root.addArrangedSubview(left)
        root.addArrangedSubview(right)
        right.addArrangedSubview(top)
        right.addArrangedSubview(bottom)
        let expected = Set([left, top, bottom].map(ObjectIdentifier.init))

        func leafIDs(_ node: PaneLayoutNode?) -> Set<ObjectIdentifier> {
            guard let node else { return [] }
            switch node {
            case .leaf(let id): return [id]
            case .split(_, let children):
                return children.reduce(into: []) { $0.formUnion(leafIDs($1)) }
            }
        }

        XCTAssertTrue(PaneLayoutController.move(
            source: left, target: top, zone: .bottom).changed)
        XCTAssertEqual(leafIDs(PaneLayoutController.snapshot(of: host)), expected)

        XCTAssertTrue(PaneLayoutController.move(
            source: bottom, target: left, zone: .center).changed)
        XCTAssertEqual(leafIDs(PaneLayoutController.snapshot(of: host)), expected)

        XCTAssertTrue(PaneLayoutController.move(
            source: top, target: bottom, zone: .right).changed)
        XCTAssertEqual(leafIDs(PaneLayoutController.snapshot(of: host)), expected)
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

    func testMaximizedPaneDividerPositionsPushSiblingsOffCanvas() {
        XCTAssertEqual(
            PaneLayoutController.maximizedDividerPositions(
                length: 600, childCount: 2, selectedIndex: 0,
                collapsedExtent: 0, dividerThickness: 1),
            [599])
        XCTAssertEqual(
            PaneLayoutController.maximizedDividerPositions(
                length: 600, childCount: 2, selectedIndex: 1,
                collapsedExtent: 0, dividerThickness: 1),
            [0])
    }

    func testPaneDividerAnimationMovesThroughIntermediateGeometry() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        split.isVertical = true
        host.addSubview(split)
        let first = NSView()
        let second = NSView()
        split.addArrangedSubview(first)
        split.addArrangedSubview(second)
        split.adjustSubviews()
        split.setPosition(300, ofDividerAt: 0)
        XCTAssertEqual(first.frame.maxX, 300, accuracy: 0.5)

        let completed = expectation(description: "divider animation completes")
        let animation = PaneDividerAnimation(
            keyframes: [PaneDividerKeyframe(split: split, start: [300], end: [599])],
            duration: 0.12
        ) {
            completed.fulfill()
        }
        animation.start()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertGreaterThan(first.frame.maxX, 300)
        XCTAssertLessThan(first.frame.maxX, 599)
        wait(for: [completed], timeout: 0.5)
        XCTAssertLessThanOrEqual(second.frame.width, 8.5)
    }

}
