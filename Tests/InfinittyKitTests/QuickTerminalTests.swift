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
}
