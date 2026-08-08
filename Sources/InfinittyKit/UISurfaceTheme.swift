import AppKit
import ShadcnUI
import SwiftUI

/// Derives the shadcn token set every SwiftUI surface renders in — chat, files,
/// browse, settings — from the terminal theme, so a panel is the same colour as
/// the terminal beside it instead of carrying a second, unrelated palette.
///
/// `background`/`foreground` come from the terminal theme and `accent-color`
/// supplies the tint, which lands on shadcn's `primary` and `ring`. Everything
/// between those two — card, muted, border — is mixed from them, so the ramp
/// holds up for a light terminal theme as well as a dark one.
enum UISurfaceTheme {
    /// Terminal defaults, matching `Theme.dark`, for a config that overrides
    /// neither colour.
    static let defaultBackground: UInt32 = 0x0F12_16
    static let defaultForeground: UInt32 = 0xD7DA_E0

    static func theme(for config: AppConfig) -> ShadcnTheme {
        let spec = palette(
            background: OKLCH(rgb: config.background ?? defaultBackground),
            foreground: OKLCH(rgb: config.foreground ?? defaultForeground),
            tint: OKLCH(rgb: config.accentColor ?? CodePalette.defaultAccentRGB))
        // Both schemes get the same palette: the terminal theme already decides
        // whether the app reads light or dark, and a panel must not flip with
        // the system appearance while the terminal beside it stays put.
        var theme = ShadcnTheme(light: spec, dark: spec)
        theme.typography = ShadcnTypography(sansFamily: config.interfaceFontName)
        return theme
    }

    /// Which scheme the hosts should render in, so shadows and other
    /// scheme-sensitive chrome match the terminal rather than the system.
    static func colorScheme(for config: AppConfig) -> ColorScheme {
        OKLCH(rgb: config.background ?? defaultBackground).l < 0.5 ? .dark : .light
    }

    private static func palette(
        background: OKLCH, foreground: OKLCH, tint: OKLCH
    ) -> ShadcnPaletteSpec {
        let isDark = background.l < 0.5
        // Start from the stock ramp so tokens this derivation has no opinion on
        // — destructive, the chart series — keep sane values.
        var spec = isDark ? ShadcnPaletteSpec.neutralDark : ShadcnPaletteSpec.neutralLight

        spec.background = background
        spec.foreground = foreground

        // Cards and popovers step off the terminal background just far enough
        // to read as raised without leaving its colour family.
        spec.card = background.mixed(toward: foreground, 0.05)
        spec.cardForeground = foreground
        spec.popover = background.mixed(toward: foreground, 0.07)
        spec.popoverForeground = foreground

        spec.primary = tint
        spec.primaryForeground = Self.readableForeground(on: tint)

        spec.secondary = background.mixed(toward: foreground, 0.12)
        spec.secondaryForeground = foreground
        spec.muted = background.mixed(toward: foreground, 0.10)
        spec.mutedForeground = background.mixed(toward: foreground, 0.62)

        // shadcn's `accent` is the subtle hover surface, not the brand colour —
        // the tint belongs on `primary`/`ring`. It still carries a trace of the
        // tint so hover states read as part of the same theme.
        spec.accent = background.mixed(toward: tint, 0.18)
        spec.accentForeground = foreground

        spec.border = background.mixed(toward: foreground, 0.18)
        spec.input = background.mixed(toward: foreground, 0.22)
        spec.ring = tint

        spec.sidebar = background.mixed(toward: foreground, 0.03)
        spec.sidebarForeground = foreground
        spec.sidebarPrimary = tint
        spec.sidebarPrimaryForeground = Self.readableForeground(on: tint)
        spec.sidebarAccent = background.mixed(toward: tint, 0.18)
        spec.sidebarAccentForeground = foreground
        spec.sidebarBorder = background.mixed(toward: foreground, 0.18)
        spec.sidebarRing = tint

        return spec
    }

    /// Near-black or near-white, whichever survives on top of `colour`.
    private static func readableForeground(on colour: OKLCH) -> OKLCH {
        OKLCH(l: colour.l > 0.62 ? 0.145 : 0.985, c: 0, h: colour.h)
    }
}

extension OKLCH {
    /// Takes a packed `0xRRGGBB` terminal colour into the space the shadcn
    /// palette is authored in. ShadKit ships the OKLCH → sRGB direction only;
    /// this is its inverse (Björn Ottosson's OKLab matrices, run backwards).
    init(rgb: UInt32) {
        let red = Self.gammaDecode(Double((rgb >> 16) & 0xFF) / 255)
        let green = Self.gammaDecode(Double((rgb >> 8) & 0xFF) / 255)
        let blue = Self.gammaDecode(Double(rgb & 0xFF) / 255)

        // Linear sRGB -> approximate cone response (LMS).
        let long = 0.412_221_470_8 * red + 0.536_332_536_3 * green + 0.051_445_992_9 * blue
        let medium = 0.211_903_498_2 * red + 0.680_699_545_1 * green + 0.107_396_956_6 * blue
        let short = 0.088_302_461_9 * red + 0.281_718_837_6 * green + 0.629_978_700_5 * blue

        let lPrime = Foundation.cbrt(long)
        let mPrime = Foundation.cbrt(medium)
        let sPrime = Foundation.cbrt(short)

        // LMS' -> OKLab.
        let labL = 0.210_454_255_3 * lPrime + 0.793_617_785_0 * mPrime - 0.004_072_046_8 * sPrime
        let labA = 1.977_998_495_1 * lPrime - 2.428_592_205_0 * mPrime + 0.450_593_709_9 * sPrime
        let labB = 0.025_904_037_1 * lPrime + 0.782_771_766_2 * mPrime - 0.808_675_766_0 * sPrime

        var hue = atan2(labB, labA) * 180 / .pi
        if hue < 0 { hue += 360 }
        self.init(l: labL, c: (labA * labA + labB * labB).squareRoot(), h: hue)
    }

    /// Blends toward `other` in OKLab, not in LCH: interpolating the hue angle
    /// directly takes the long way round the wheel whenever the two colours
    /// straddle 0°, and produces invented hues when either end is achromatic.
    func mixed(toward other: OKLCH, _ amount: Double) -> OKLCH {
        let start = oklab
        let end = other.oklab
        let labL = start.l + (end.l - start.l) * amount
        let labA = start.a + (end.a - start.a) * amount
        let labB = start.b + (end.b - start.b) * amount

        var hue = atan2(labB, labA) * 180 / .pi
        if hue < 0 { hue += 360 }
        return OKLCH(
            l: labL,
            c: (labA * labA + labB * labB).squareRoot(),
            h: hue,
            alpha: alpha + (other.alpha - alpha) * amount)
    }

    private static func gammaDecode(_ channel: Double) -> Double {
        channel <= 0.040_45 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}
