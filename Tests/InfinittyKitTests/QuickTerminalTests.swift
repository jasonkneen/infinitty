import AppKit
import Carbon
import XCTest

@testable import InfinittyKit

final class QuickTerminalTests: XCTestCase {
    func testParsesGlobalShortcutAliases() {
        let spec = GlobalHotKeySpec.parse("cmd+shift+space")
        XCTAssertEqual(spec?.keyCode, 49)
        XCTAssertEqual(spec?.modifiers, UInt32(cmdKey | shiftKey))

        let alternate = GlobalHotKeySpec.parse("control+option+space")
        XCTAssertEqual(alternate?.keyCode, 49)
        XCTAssertEqual(alternate?.modifiers, UInt32(controlKey | optionKey))
    }

    func testRejectsUnsafeOrAmbiguousGlobalShortcuts() {
        XCTAssertNil(GlobalHotKeySpec.parse("backquote"))
        XCTAssertNil(GlobalHotKeySpec.parse("cmd+unknown"))
        XCTAssertNil(GlobalHotKeySpec.parse("cmd+a+b"))
    }

    func testAutohideDoesNotRestorePreviouslyFocusedApplication() {
        XCTAssertTrue(QuickTerminalHideReason.explicit.restoresPreviousApplication)
        XCTAssertFalse(QuickTerminalHideReason.focusLoss.restoresPreviousApplication)
    }

    func testLiveSessionKeepsAppResidentWithoutHotKey() {
        XCTAssertTrue(QuickTerminalResidency.shouldTerminateAfterLastWindowClosed(
            hasRegisteredHotKey: false, hasLiveSession: false))
        XCTAssertFalse(QuickTerminalResidency.shouldTerminateAfterLastWindowClosed(
            hasRegisteredHotKey: true, hasLiveSession: false))
        XCTAssertFalse(QuickTerminalResidency.shouldTerminateAfterLastWindowClosed(
            hasRegisteredHotKey: false, hasLiveSession: true))
    }

    func testQuickTerminalHeightStateDefaultsAndPersistsFraction() {
        let suiteName = "QuickTerminalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = QuickTerminalHeightState(defaults: defaults)
        XCTAssertEqual(initial.fraction, 0.4)

        initial.record(height: 420, availableHeight: 1_000)
        XCTAssertEqual(initial.fraction, 0.42)
        XCTAssertEqual(
            QuickTerminalHeightState(defaults: defaults).fraction,
            0.42)
    }

    func testTopFramesMeetAtScreenEdge() {
        let screen = NSRect(x: 100, y: 50, width: 1_400, height: 900)
        let visible = QuickTerminalLayout.visibleFrame(
            in: screen, heightFraction: 0.4)
        XCTAssertEqual(visible, NSRect(x: 100, y: 590, width: 1_400, height: 360))

        let hidden = QuickTerminalLayout.hiddenFrame(for: visible)
        XCTAssertEqual(hidden, NSRect(x: 100, y: 950, width: 1_400, height: 360))
    }

    func testQuickTabStripRemainsVisibleWithOneTab() {
        let tabsView = QuickTerminalTabsView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let content = NSView(frame: .zero)
        let page = QuickTerminalTabPageView(content: content)
        tabsView.install(page)
        tabsView.strip.update(titles: ["shell"], selectedIndex: 0)
        tabsView.layoutSubtreeIfNeeded()

        XCTAssertEqual(tabsView.strip.frame.height, QuickTerminalTabsView.stripHeight)
        XCTAssertEqual(tabsView.pageHost.frame.height, 400 - QuickTerminalTabsView.stripHeight)
        XCTAssertTrue(page.superview === tabsView.pageHost)
        XCTAssertEqual(page.frame, tabsView.pageHost.bounds)
        XCTAssertTrue(content.superview === page)
        XCTAssertEqual(content.frame, page.bounds)
    }

    func testQuickTabPagesStayAttachedWhileSelectionChanges() {
        let tabsView = QuickTerminalTabsView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let first = QuickTerminalTabPageView(content: NSView())
        let second = QuickTerminalTabPageView(content: NSView())
        tabsView.install(first)
        tabsView.install(second)

        tabsView.select(first)
        XCTAssertFalse(first.isHidden)
        XCTAssertTrue(second.isHidden)
        XCTAssertTrue(first.superview === tabsView.pageHost)
        XCTAssertTrue(second.superview === tabsView.pageHost)

        tabsView.select(second)
        XCTAssertTrue(first.isHidden)
        XCTAssertFalse(second.isHidden)
        XCTAssertTrue(first.superview === tabsView.pageHost)
        XCTAssertTrue(second.superview === tabsView.pageHost)
    }

    func testQuickTabStripShowsTitlesAndAddButton() throws {
        let strip = QuickTerminalTabStripView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 34))
        strip.update(titles: ["one", "two"], selectedIndex: 1)
        strip.layoutSubtreeIfNeeded()

        let titles = strip.subviews.compactMap { ($0 as? NSButton)?.title }
        XCTAssertTrue(titles.contains("one"))
        XCTAssertTrue(titles.contains("two"))
        XCTAssertTrue(titles.contains("+"))
        let tabButtons = strip.subviews.compactMap { $0 as? NSButton }
            .filter { $0.title != "+" && $0.title != "×" }
        XCTAssertEqual(tabButtons.map(\.alignment), [.center, .center])
        XCTAssertEqual(tabButtons[0].frame.width, tabButtons[1].frame.width)
        XCTAssertGreaterThan(tabButtons.reduce(0) { $0 + $1.frame.width }, 400)
        let close = try XCTUnwrap(
            strip.subviews.compactMap { $0 as? NSButton }.first { $0.title == "×" })
        var closedIndex: Int?
        strip.onClose = { closedIndex = $0 }
        close.performClick(nil)
        XCTAssertEqual(closedIndex, 1)

        var doubleClickedIndex: Int?
        strip.onRenameRequest = { doubleClickedIndex = $0 }
        strip.handleTabClick(at: 0, clickCount: 2)
        XCTAssertEqual(doubleClickedIndex, 0)

        var renamedValue: String?
        strip.onRenameCommit = { renamedValue = $0 }
        XCTAssertTrue(strip.beginRename(at: 1, currentName: "two"))
        strip.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(
            strip.subviews.compactMap { $0 as? QuickTabRenameTextView }.first)
        XCTAssertEqual(editor.frame.midX, tabButtons[1].frame.midX, accuracy: 0.5)
        XCTAssertEqual(editor.frame.midY, tabButtons[1].frame.midY, accuracy: 0.5)
        editor.string = "renamed"
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(renamedValue, "renamed")
        XCTAssertFalse(strip.subviews.contains { $0 === editor })

        var cancelled = false
        strip.onRenameCancel = { cancelled = true }
        XCTAssertTrue(strip.beginRename(at: 0, currentName: "one"))
        let cancelEditor = try XCTUnwrap(
            strip.subviews.compactMap { $0 as? QuickTabRenameTextView }.first)
        cancelEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(cancelled)
    }

    func testQuickTabControllerKeepsSessionsAttachedAcrossTabs() throws {
        _ = NSApplication.shared
        var sessions: [TerminalSession] = []
        func makeSession() -> TerminalSession {
            let session = TerminalSession(config: AppConfig(), scale: 2)
            session.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
            sessions.append(session)
            return session
        }

        let first = makeSession()
        let window = QuickTerminalPanel(
            contentRect: first.view.frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false)
        window.contentView = first.view
        let controller = QuickTerminalController(
            config: AppConfig(),
            makeWindow: { (window, first) },
            makeTab: { _ in
                let session = makeSession()
                return (session.view, session)
            },
            sessionsInPage: { page in
                sessions.filter { $0.view === page || $0.view.isDescendant(of: page) }
            },
            launchSession: { _ in })
        defer {
            controller.lastSessionDidExit()
            sessions.forEach { $0.shutdown() }
        }

        _ = try XCTUnwrap(controller.ensureWindow())
        XCTAssertEqual(controller.tabCount, 1)
        XCTAssertEqual(controller.activeSessions.map(\.id), [first.id])
        let firstTabID = try XCTUnwrap(controller.activeTabID)
        controller.setTitle("automatic one", for: first)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(controller.beginRenamingActiveTab())
        let tabsView = try XCTUnwrap(window.contentView as? QuickTerminalTabsView)
        let inlineEditor = try XCTUnwrap(
            tabsView.strip.subviews.compactMap { $0 as? QuickTabRenameTextView }.first)
        XCTAssertTrue(window.firstResponder === inlineEditor)
        XCTAssertFalse(controller.toggleRenamingActiveTab())
        XCTAssertFalse(inlineEditor.superview === tabsView.strip)
        XCTAssertEqual(controller.baseTitle(for: firstTabID), "automatic one")

        XCTAssertTrue(controller.toggleRenamingActiveTab())
        let toggledEditor = try XCTUnwrap(
            tabsView.strip.subviews.compactMap { $0 as? QuickTabRenameTextView }.first)
        XCTAssertTrue(window.firstResponder === toggledEditor)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        XCTAssertTrue(toggledEditor.superview === tabsView.strip)
        XCTAssertTrue(window.firstResponder === toggledEditor)
        controller.setShowsShortcutHints(true)
        controller.setShowsShortcutHints(false)
        XCTAssertTrue(toggledEditor.superview === tabsView.strip)
        XCTAssertTrue(window.firstResponder === toggledEditor)
        // Focus loss commits the typed name, mirroring Finder rename-in-place.
        toggledEditor.string = "Saved On Focus Loss"
        XCTAssertTrue(window.makeFirstResponder(tabsView.pageHost))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        XCTAssertFalse(toggledEditor.superview === tabsView.strip)
        XCTAssertEqual(controller.baseTitle(for: firstTabID), "Saved On Focus Loss")

        XCTAssertTrue(controller.beginRenamingActiveTab())
        let committedEditor = try XCTUnwrap(
            tabsView.strip.subviews.compactMap { $0 as? QuickTabRenameTextView }.first)
        committedEditor.string = "Project One"
        committedEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(controller.baseTitle(for: firstTabID), "Project One")
        XCTAssertTrue(window.firstResponder === first.view)
        controller.setTitle("changed automatically", for: first)
        controller.setFocusedSession(first)
        XCTAssertEqual(controller.baseTitle(for: firstTabID), "Project One")

        let second = try XCTUnwrap(controller.newTab())
        let secondTabID = try XCTUnwrap(controller.activeTabID)
        XCTAssertNotEqual(secondTabID, firstTabID)
        controller.setCustomTitle("Project Two", for: secondTabID)
        XCTAssertEqual(controller.tabCount, 2)
        XCTAssertEqual(controller.activeSessions.map(\.id), [second.id])
        XCTAssertTrue(first.view.window === window)
        XCTAssertTrue(second.view.window === window)

        XCTAssertTrue(controller.selectTab(containing: first))
        XCTAssertEqual(controller.activeSessions.map(\.id), [first.id])
        XCTAssertEqual(controller.baseTitle(for: firstTabID), "Project One")
        XCTAssertEqual(controller.baseTitle(for: secondTabID), "Project Two")
        controller.setCustomTitle(nil, for: firstTabID)
        XCTAssertEqual(controller.baseTitle(for: firstTabID), "changed automatically")
        XCTAssertFalse(controller.removeTab(containing: second))
        XCTAssertEqual(controller.tabCount, 1)
        XCTAssertEqual(controller.activeSessions.map(\.id), [first.id])

        XCTAssertTrue(controller.removeTab(containing: first))
        XCTAssertEqual(controller.tabCount, 0)
        XCTAssertNil(controller.window)
    }

    func testConfigSerializationPreservesQuickTerminalSettings() {
        var config = AppConfig()
        config.quickTerminalKey = "cmd+shift+space"
        config.quickTerminalScreen = .mouse
        config.quickTerminalAutohide = false
        config.quickTerminalAnimationDuration = 0.15

        let text = config.serialize()
        XCTAssertTrue(text.contains("quick-terminal-key = cmd+shift+space"))
        XCTAssertFalse(text.contains("quick-terminal-height"))
        XCTAssertTrue(text.contains("quick-terminal-screen = mouse"))
        XCTAssertTrue(text.contains("quick-terminal-autohide = false"))
        XCTAssertTrue(text.contains("quick-terminal-animation-duration = 0.15"))
    }

    func testConfigSerializationDropsMalformedQuickTerminalKey() {
        var config = AppConfig()
        config.quickTerminalKey = "cmd+not-a-key"

        XCTAssertFalse(config.serialize().contains("quick-terminal-key"))
    }

    func testConfigSerializationKeepsQuickTerminalSettingsWithoutKey() {
        // The quick terminal is also reachable via the File menu and the
        // control socket, so its settings must survive a Settings-window
        // rewrite even when no hot key is configured.
        var config = AppConfig()
        config.quickTerminalScreen = .mouse
        config.quickTerminalAutohide = false
        config.quickTerminalAnimationDuration = 0.15

        let text = config.serialize()
        XCTAssertFalse(text.contains("quick-terminal-key"))
        XCTAssertTrue(text.contains("quick-terminal-screen = mouse"))
        XCTAssertTrue(text.contains("quick-terminal-autohide = false"))
        XCTAssertTrue(text.contains("quick-terminal-animation-duration = 0.15"))
    }

    func testQuickTabStripCommitsRenameOnTabSwitchAndNewTab() throws {
        let strip = QuickTerminalTabStripView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 34))
        strip.update(titles: ["one", "two"], selectedIndex: 0)
        strip.layoutSubtreeIfNeeded()

        var committed: String?
        var selected: Int?
        var newTabRequested = false
        strip.onRenameCommit = { committed = $0 }
        strip.onSelect = { selected = $0 }
        strip.onNewTab = { newTabRequested = true }

        // Clicking another tab saves the typed name before selecting it.
        XCTAssertTrue(strip.beginRename(at: 0, currentName: "one"))
        var editor = try XCTUnwrap(
            strip.subviews.compactMap { $0 as? QuickTabRenameTextView }.first)
        editor.string = "renamed one"
        strip.handleTabClick(at: 1, clickCount: 1)
        XCTAssertEqual(committed, "renamed one")
        XCTAssertEqual(selected, 1)
        XCTAssertFalse(strip.isRenaming)

        // The "+" button saves the typed name before opening the new tab.
        committed = nil
        XCTAssertTrue(strip.beginRename(at: 1, currentName: "two"))
        editor = try XCTUnwrap(
            strip.subviews.compactMap { $0 as? QuickTabRenameTextView }.first)
        editor.string = "renamed two"
        let addButton = try XCTUnwrap(
            strip.subviews.compactMap { $0 as? NSButton }.first { $0.title == "+" })
        addButton.performClick(nil)
        XCTAssertEqual(committed, "renamed two")
        XCTAssertTrue(newTabRequested)
        XCTAssertFalse(strip.isRenaming)
    }

    func testQuickTabStripAbandonsRenameWhenTabCountChanges() {
        let strip = QuickTerminalTabStripView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 34))
        strip.update(titles: ["one", "two", "three"], selectedIndex: 2)
        strip.layoutSubtreeIfNeeded()

        var cancelled = false
        var committed: String?
        strip.onRenameCancel = { cancelled = true }
        strip.onRenameCommit = { committed = $0 }
        XCTAssertTrue(strip.beginRename(at: 2, currentName: "three"))

        strip.update(titles: ["one", "three"], selectedIndex: 1)
        XCTAssertTrue(cancelled)
        XCTAssertNil(committed)
        XCTAssertFalse(strip.isRenaming)
        XCTAssertFalse(strip.subviews.contains { $0 is QuickTabRenameTextView })
        let tabButtons = strip.subviews.compactMap { $0 as? NSButton }
            .filter { $0.title != "+" && $0.title != "×" }
        XCTAssertTrue(tabButtons.allSatisfy { !$0.isHidden })
    }
}
