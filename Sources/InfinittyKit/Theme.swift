import simd

// One terminal cell: 16 bytes, cache-friendly, trivially memcpy-able.
struct Cell {
    var glyph: UInt32 = 0 // Unicode scalar; 0 = empty
    var fg: UInt32 = ColorCode.defaultFG
    var bg: UInt32 = ColorCode.defaultBG
    var flags: UInt16 = 0
    var _pad: UInt16 = 0
}

enum CellFlags {
    static let bold: UInt16 = 1 << 0
    static let italic: UInt16 = 1 << 1
    static let underline: UInt16 = 1 << 2
    static let inverse: UInt16 = 1 << 3
    static let faint: UInt16 = 1 << 4
    static let strikethrough: UInt16 = 1 << 5
    static let wide: UInt16 = 1 << 6
    static let wideContinuation: UInt16 = 1 << 7
    static let invisible: UInt16 = 1 << 8
    static let selected: UInt16 = 1 << 10 // snapshot-only, set during copySnapshot
}

// Color references stored per cell. Resolved to RGBA only at render time so
// palette/bold-brightening rules stay correct regardless of SGR ordering.
enum ColorCode {
    static let defaultFG: UInt32 = 0x4000_0000
    static let defaultBG: UInt32 = 0x4000_0001

    @inline(__always) static func indexed(_ n: Int) -> UInt32 { 0x1000_0000 | UInt32(n & 0xFF) }
    @inline(__always) static func rgb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        0x8000_0000 | UInt32((r & 0xFF) << 16 | (g & 0xFF) << 8 | (b & 0xFF))
    }
}

struct Theme {
    var background: SIMD4<Float>
    var foreground: SIMD4<Float>
    var cursor: SIMD4<Float>
    var selection: SIMD4<Float>
    var palette: [SIMD4<Float>] // 256 entries

    func applying(_ config: AppConfig) -> Theme {
        var t = self
        if let fg = config.foreground { t.foreground = Theme.rgba(fg) }
        if let bg = config.background { t.background = Theme.rgba(bg) }
        if let cursor = config.cursorColor { t.cursor = Theme.rgba(cursor) }
        if let sel = config.selectionBackground { t.selection = Theme.rgba(sel) }
        for (index, color) in config.palette where t.palette.indices.contains(index) {
            t.palette[index] = Theme.rgba(color)
        }
        t.background.w = Float(config.backgroundOpacity)
        return t
    }

    static func rgba(_ hex: UInt32) -> SIMD4<Float> {
        SIMD4<Float>(
            Float((hex >> 16) & 0xFF) / 255.0,
            Float((hex >> 8) & 0xFF) / 255.0,
            Float(hex & 0xFF) / 255.0,
            1.0
        )
    }

    static let dark: Theme = {
        var p = [SIMD4<Float>](repeating: .zero, count: 256)
        let base16: [UInt32] = [
            0x20242C, 0xE06C75, 0x98C379, 0xE5C07B,
            0x61AFEF, 0xC678DD, 0x56B6C2, 0xC8CCD4,
            0x5C6370, 0xE9737E, 0xA9D089, 0xEDCB8B,
            0x74BAF2, 0xD28AE6, 0x6AC4CF, 0xFFFFFF,
        ]
        for i in 0..<16 { p[i] = rgba(base16[i]) }
        // 6x6x6 color cube
        let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    p[16 + 36 * r + 6 * g + b] = rgba(steps[r] << 16 | steps[g] << 8 | steps[b])
                }
            }
        }
        // grayscale ramp
        for i in 0..<24 {
            let v = UInt32(8 + i * 10)
            p[232 + i] = rgba(v << 16 | v << 8 | v)
        }
        return Theme(
            background: rgba(0x0F1216),
            foreground: rgba(0xD7DAE0),
            cursor: rgba(0xAEB8C4),
            selection: rgba(0x2F4368),
            palette: p
        )
    }()
}
