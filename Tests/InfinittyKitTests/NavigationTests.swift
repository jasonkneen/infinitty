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

    func testMenuExposesTabAndPaneShortcuts() throws {
        _ = NSApplication.shared
        let main = AppDelegate.buildMenu()
        let window = try XCTUnwrap(main.items.compactMap(\.submenu).first { $0.title == "Window" })

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
}
