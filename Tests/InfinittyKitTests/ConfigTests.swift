import XCTest

@testable import InfinittyKit

final class ConfigTests: XCTestCase {
    func testBuiltInPetIsEnabledByDefault() {
        XCTAssertEqual(AppConfig().pet, "infinitty")
    }

    func testPetOptOutParsesAndSurvivesSerialization() {
        var config = AppConfig()
        config.apply(fileContents: "pet = none")
        XCTAssertNil(config.pet)

        var reparsed = AppConfig()
        reparsed.apply(fileContents: config.serialize())
        XCTAssertNil(reparsed.pet)
    }

    func testParsePaletteEntry() {
        XCTAssertEqual(AppConfig.parsePaletteEntry("4=#61AFEF")?.index, 4)
        XCTAssertEqual(AppConfig.parsePaletteEntry("4=#61AFEF")?.color, 0x61AFEF)
        XCTAssertEqual(AppConfig.parsePaletteEntry("0=1d1f21")?.color, 0x1D1F21)
        XCTAssertEqual(AppConfig.parsePaletteEntry(" 255 = #FFFFFF ")?.index, 255)
        XCTAssertNil(AppConfig.parsePaletteEntry("256=#FFFFFF")) // index out of range
        XCTAssertNil(AppConfig.parsePaletteEntry("-1=#FFFFFF"))
        XCTAssertNil(AppConfig.parsePaletteEntry("4=#61AFE")) // short hex
        XCTAssertNil(AppConfig.parsePaletteEntry("#61AFEF")) // missing index
    }

    func testPaletteLinesSurviveCommentStripping() {
        var config = AppConfig()
        config.apply(fileContents: """
            # ghostty-style theme
            palette = 4=#61AFEF
            palette = 1=#E06C75 # trailing comment
            palette = 9=red
            palette = not-a-number=#FFFFFF
            foreground = #D7DAE0 # still stripped for non-palette keys
            """)
        XCTAssertEqual(config.palette[4], 0x61AFEF)
        XCTAssertEqual(config.palette[1], 0xE06C75)
        XCTAssertEqual(config.palette[9], 0xFF0000)
        XCTAssertEqual(config.palette.count, 3)
        XCTAssertEqual(config.foreground, 0xD7DAE0)
    }

    func testThemeAppliesPaletteOverrides() {
        var config = AppConfig()
        config.palette = [0: 0x102030, 15: 0xFFFFFF, 200: 0x00FF00]
        let theme = Theme.dark.applying(config)
        XCTAssertEqual(theme.palette[0], Theme.rgba(0x102030))
        XCTAssertEqual(theme.palette[15], Theme.rgba(0xFFFFFF))
        XCTAssertEqual(theme.palette[200], Theme.rgba(0x00FF00))
        // Untouched entries keep the built-in defaults.
        XCTAssertEqual(theme.palette[1], Theme.dark.palette[1])
    }

    func testSerializeRoundTripsPalette() {
        var config = AppConfig()
        config.palette = [4: 0x61AFEF, 1: 0xE06C75]
        var reparsed = AppConfig()
        reparsed.apply(fileContents: config.serialize())
        XCTAssertEqual(reparsed.palette, config.palette)
    }
    func testCustomTitlebarStyleIsNotSerialized() {
        var config = AppConfig()
        config.apply(fileContents: """
            titlebar = hidden
            traffic-lights = diamond
            """)

        let serialized = config.serialize()
        XCTAssertFalse(serialized.contains("titlebar ="))
        XCTAssertTrue(serialized.contains("traffic-lights = diamond"))
    }

    func testSettingsUseReadableLargeControlTypography() {
        let controller = SettingsWindowController(config: AppConfig()) { _ in }

        XCTAssertGreaterThanOrEqual(controller.contentSizeForTesting.width, 700)
        XCTAssertGreaterThanOrEqual(controller.contentSizeForTesting.height, 440)
        XCTAssertTrue(controller.sidebarFontSizesForTesting.allSatisfy { $0 >= 16 })
        XCTAssertTrue(controller.sidebarRowHeightsForTesting.allSatisfy { $0 >= 42 })
        XCTAssertEqual(controller.fontControlSizeForTesting, .large)
        XCTAssertGreaterThanOrEqual(controller.fontControlPointSizeForTesting, 15)
    }

}
