import AppKit
import ShadcnUI
import SwiftUI
import XCTest

@testable import InfinittyKit

final class UISurfaceThemeTests: XCTestCase {
    /// The whole derivation rests on taking terminal hex colours into OKLCH, so
    /// the inverse conversion has to round-trip. ShadKit only ships the forward
    /// direction, which `hexString` uses.
    func testPackedRGBRoundTripsThroughOKLCH() {
        for rgb: UInt32 in [
            0x0000_00, 0xFFFF_FF, 0x0F12_16, 0xD7DA_E0, 0x6370_EB, 0xE06C_75, 0x98C3_79,
        ] {
            XCTAssertEqual(
                OKLCH(rgb: rgb).hexString,
                String(format: "#%06X", rgb),
                "0x\(String(rgb, radix: 16)) did not survive the round trip")
        }
    }

    /// Terminal background and foreground land on the surfaces verbatim — a
    /// panel must be exactly the terminal's colour, not an approximation of it.
    func testSurfacesTakeTerminalBackgroundAndForeground() {
        var config = AppConfig()
        config.background = 0x1A_2033
        config.foreground = 0xE8EA_F0

        let palette = UISurfaceTheme.theme(for: config).palette(for: .dark)

        XCTAssertEqual(palette.background, OKLCH(rgb: 0x1A_2033).color)
        XCTAssertEqual(palette.foreground, OKLCH(rgb: 0xE8EA_F0).color)
    }

    /// `accent-color` is the tint, and shadcn puts the brand colour on
    /// `primary`/`ring` — not on `accent`, which is a hover surface.
    func testAccentColourDrivesPrimaryAndRing() {
        var config = AppConfig()
        config.accentColor = 0xE0_6C75

        let palette = UISurfaceTheme.theme(for: config).palette(for: .dark)
        let tint = OKLCH(rgb: 0xE0_6C75).color

        XCTAssertEqual(palette.primary, tint)
        XCTAssertEqual(palette.ring, tint)
        XCTAssertNotEqual(palette.accent, tint, "accent is a surface, not the brand colour")
    }

    /// Without overrides the surfaces still have to resolve to the terminal's
    /// own defaults rather than shadcn's stock neutral.
    func testDefaultsFollowTheDefaultTerminalTheme() {
        let palette = UISurfaceTheme.theme(for: AppConfig()).palette(for: .dark)

        XCTAssertEqual(palette.background, OKLCH(rgb: UISurfaceTheme.defaultBackground).color)
        XCTAssertEqual(palette.foreground, OKLCH(rgb: UISurfaceTheme.defaultForeground).color)
        XCTAssertEqual(palette.primary, OKLCH(rgb: CodePalette.defaultAccentRGB).color)
    }

    /// The mixed steps must stay ordered between background and foreground, or
    /// muted text ends up less legible than the body text it sits under.
    func testMixedStepsStayOrderedBetweenBackgroundAndForeground() {
        var config = AppConfig()
        config.background = 0x0F12_16
        config.foreground = 0xD7DA_E0

        let background = OKLCH(rgb: 0x0F12_16)
        let foreground = OKLCH(rgb: 0xD7DA_E0)
        let spec = UISurfaceTheme.theme(for: config).dark

        for step in [spec.card, spec.muted, spec.border, spec.mutedForeground] {
            XCTAssertGreaterThan(step.l, background.l)
            XCTAssertLessThan(step.l, foreground.l)
        }
        // Border has to out-contrast the card it outlines.
        XCTAssertGreaterThan(spec.border.l, spec.card.l)
        // Muted text has to out-contrast the muted fill.
        XCTAssertGreaterThan(spec.mutedForeground.l, spec.muted.l)
    }

    /// A light terminal theme must not leave the panels rendering dark chrome.
    func testLightTerminalBackgroundSelectsLightScheme() {
        var config = AppConfig()
        config.background = 0xFAFA_FA
        config.foreground = 0x1A_1A1A

        XCTAssertEqual(UISurfaceTheme.colorScheme(for: config), .light)

        let spec = UISurfaceTheme.theme(for: config).light
        // The ramp inverts with the theme: steps darken toward the foreground.
        XCTAssertLessThan(spec.card.l, OKLCH(rgb: 0xFAFA_FA).l)
        XCTAssertGreaterThan(spec.card.l, OKLCH(rgb: 0x1A_1A1A).l)
    }

    func testDarkTerminalBackgroundSelectsDarkScheme() {
        var config = AppConfig()
        config.background = 0x0F12_16

        XCTAssertEqual(UISurfaceTheme.colorScheme(for: config), .dark)
    }

    /// Foreground on the tint has to be the readable end, not a mix that lands
    /// mid-ramp and disappears on a saturated accent.
    func testPrimaryForegroundContrastsWithTheTint() {
        for (accent, expectDark) in [(UInt32(0xF2_C94C), true), (UInt32(0x2B_2F6B), false)] {
            var config = AppConfig()
            config.accentColor = accent
            let spec = UISurfaceTheme.theme(for: config).dark
            if expectDark {
                XCTAssertLessThan(spec.primaryForeground.l, 0.3, "light tint needs dark text")
            } else {
                XCTAssertGreaterThan(spec.primaryForeground.l, 0.9, "dark tint needs light text")
            }
        }
    }
}
