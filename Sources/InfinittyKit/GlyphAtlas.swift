import AppKit
import CoreText
import Metal
import simd

struct GlyphInfo {
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    var pxSize: SIMD2<Float>
}

/// CoreText -> Metal alpha atlas. Glyphs are rasterized once at device pixel
/// scale into a shelf-packed R8 texture; the renderer only ever samples it.
///
/// Nerd Font aware: Private Use Area glyphs resolve through a fallback chain
/// of installed Nerd Fonts, icons are centered in their cell, and powerline
/// separators (U+E0B0–U+E0BF) are stretched from their glyph outline to fill
/// the cell exactly so prompt segments join without seams.
///
/// Atlases are shared across sessions (tabs/splits) and locked internally —
/// multiple render threads may rasterize concurrently.
final class GlyphAtlas {
    static let textureSize = 2048
    static let pad = 2

    let texture: MTLTexture

    // All metrics are device pixels.
    let cellWidth: Int
    let cellHeight: Int
    let scale: CGFloat
    let config: AppConfig

    private let baselineY: CGFloat // from slot bottom, includes line-spacing centering
    private var fonts: [CTFont] // regular, bold, italic, boldItalic
    private var cache: [UInt64: GlyphInfo?] = [:]
    private var fallbackCache: [UInt32: CTFont] = [:]
    private let lock = NSLock()

    private var shelfX = 0
    private var shelfY = 0
    private var shelfHeight = 0

    private var scratch: UnsafeMutablePointer<UInt8>
    private let scratchSize: Int

    // MARK: shared cache (per font+size+scale)

    private static var shared: [String: GlyphAtlas] = [:]
    private static let sharedLock = NSLock()

    static func atlas(device: MTLDevice, config: AppConfig, scale: CGFloat) -> GlyphAtlas {
        let key = "\(config.atlasKey)|\(scale)"
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let existing = shared[key] { return existing }
        let atlas = GlyphAtlas(device: device, config: config, scale: scale)
        shared[key] = atlas
        return atlas
    }

    init(device: MTLDevice, config: AppConfig, scale: CGFloat) {
        self.scale = scale
        self.config = config
        let px = config.fontSize * scale

        func ct(_ f: NSFont) -> CTFont { unsafeBitCast(f, to: CTFont.self) }

        var regular: NSFont
        if let name = config.fontName {
            if let custom = GlyphAtlas.resolveFace(family: name, style: config.fontStyle, size: px) {
                regular = custom
            } else {
                FileHandle.standardError.write(
                    Data("infinitty: font '\(name)' not found, using SF Mono\n".utf8))
                regular = NSFont.monospacedSystemFont(ofSize: px, weight: GlyphAtlas.systemWeight(config.fontStyle))
            }
        } else {
            regular = NSFont.monospacedSystemFont(ofSize: px, weight: GlyphAtlas.systemWeight(config.fontStyle))
        }

        let fm = NSFontManager.shared
        let bold = fm.convert(regular, toHaveTrait: .boldFontMask)
        let italic = fm.convert(regular, toHaveTrait: .italicFontMask)
        let boldItalic = fm.convert(bold, toHaveTrait: .italicFontMask)
        fonts = [ct(regular), ct(bold), ct(italic), ct(boldItalic)]

        let ascent = CTFontGetAscent(fonts[0])
        let descent = CTFontGetDescent(fonts[0])
        let leading = max(CTFontGetLeading(fonts[0]), 0)
        let naturalHeight = ceil(ascent + descent + leading)

        var mChar: UniChar = UniChar(UInt8(ascii: "M"))
        var mGlyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(fonts[0], &mChar, &mGlyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(fonts[0], .horizontal, &mGlyph, &advance, 1)

        // Kerning = cell advance multiplier (+ optional ghostty-style extra
        // points); glyphs are centered in the adjusted cell at raster time.
        cellWidth = max(Int(ceil(advance.width * config.kerning + config.cellWidthExtra * scale)), 1)
        cellHeight = max(
            Int(ceil(naturalHeight * max(config.lineSpacing, 0.5) + config.cellHeightExtra * scale)), 1)
        baselineY = descent + (CGFloat(cellHeight) - naturalHeight) / 2

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: GlyphAtlas.textureSize,
            height: GlyphAtlas.textureSize,
            mipmapped: false
        )
        desc.usage = .shaderRead
        texture = device.makeTexture(descriptor: desc)!

        scratchSize = (cellWidth * 2 + GlyphAtlas.pad * 2) * (cellHeight + GlyphAtlas.pad * 2)
        scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: scratchSize)
    }

    deinit {
        scratch.deallocate()
    }

    var cellSizePoints: CGSize {
        CGSize(width: CGFloat(cellWidth) / scale, height: CGFloat(cellHeight) / scale)
    }

    /// style: bit0 = bold, bit1 = italic. Returns nil for blank glyphs.
    func glyph(_ scalar: UInt32, style: Int, wide: Bool) -> GlyphInfo? {
        let key = UInt64(scalar) | (UInt64(style) << 32) | (wide ? 1 << 40 : 0)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let info = rasterize(scalar, style: style, wide: wide)
        cache[key] = info
        return info
    }

    // MARK: - font resolution

    /// Find a family member by style name ("Thin", "Light Oblique", ...).
    /// Falls back to name-mangled PostScript guesses, then the plain family.
    static func resolveFace(family: String, style: String?, size: CGFloat) -> NSFont? {
        if let style, !style.isEmpty {
            if let members = NSFontManager.shared.availableMembers(ofFontFamily: family) {
                for m in members {
                    if let ps = m[0] as? String, let styleName = m[1] as? String,
                       styleName.caseInsensitiveCompare(style) == .orderedSame,
                       let f = NSFont(name: ps, size: size) {
                        return f
                    }
                }
            }
            let compact = style.replacingOccurrences(of: " ", with: "")
            if let f = NSFont(name: "\(family) \(style)", size: size) { return f }
            if let f = NSFont(name: "\(family.replacingOccurrences(of: " ", with: ""))-\(compact)", size: size) {
                return f
            }
        }
        return NSFont(name: family, size: size)
    }

    /// Map a style name to a system-mono weight when no family is set.
    static func systemWeight(_ style: String?) -> NSFont.Weight {
        switch style?.lowercased() {
        case "thin": return .thin
        case "ultralight", "extralight": return .ultraLight
        case "light", "semilight": return .light
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy", "extrabold": return .heavy
        case "black": return .black
        default: return .regular
        }
    }

    @inline(__always)
    private static func isPUA(_ u: UInt32) -> Bool {
        (u >= 0xE000 && u <= 0xF8FF) || (u >= 0xF0000 && u <= 0xFFFFD)
    }

    /// Installed Nerd Fonts to try for icon glyphs the primary font lacks.
    private lazy var nerdFallbacks: [CTFont] = {
        let px = config.fontSize * scale
        let candidates = [
            "Symbols Nerd Font Mono", "Symbols Nerd Font", "SymbolsNFM", "SymbolsNF",
            "CaskaydiaCove Nerd Font Mono", "CaskaydiaCove Nerd Font", "CaskaydiaCoveNFM-Regular",
            "MesloLGS NF", "JetBrainsMono Nerd Font Mono", "Hack Nerd Font Mono",
            "FiraCode Nerd Font Mono", "CaskaydiaMono Nerd Font",
        ]
        var found: [CTFont] = []
        for name in candidates {
            if let f = NSFont(name: name, size: px) {
                found.append(unsafeBitCast(f, to: CTFont.self))
            }
        }
        return found
    }()

    private func lookup(_ font: CTFont, _ chars: [UniChar]) -> CGGlyph? {
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        var mutableChars = chars
        if CTFontGetGlyphsForCharacters(font, &mutableChars, &glyphs, chars.count), glyphs[0] != 0 {
            return glyphs[0]
        }
        return nil
    }

    private func resolveGlyph(_ scalar: UInt32, style: Int) -> (CTFont, CGGlyph)? {
        guard let us = Unicode.Scalar(scalar) else { return nil }
        let str = String(us)
        let chars = Array(str.utf16)
        let font = fonts[style]

        if let g = lookup(font, chars) { return (font, g) }

        if let cached = fallbackCache[scalar], let g = lookup(cached, chars) {
            return (cached, g)
        }

        // Nerd Font chain for PUA icons before the generic cascade.
        if GlyphAtlas.isPUA(scalar) {
            for fb in nerdFallbacks {
                if let g = lookup(fb, chars) {
                    fallbackCache[scalar] = fb
                    return (fb, g)
                }
            }
        }

        let cascade = CTFontCreateForString(font, str as CFString, CFRangeMake(0, chars.count))
        if let g = lookup(cascade, chars) {
            fallbackCache[scalar] = cascade
            return (cascade, g)
        }
        return nil
    }

    // MARK: - rasterization

    private func rasterize(_ scalar: UInt32, style: Int, wide: Bool) -> GlyphInfo? {
        guard let (font, glyph) = resolveGlyph(scalar, style: style) else { return nil }

        let pad = GlyphAtlas.pad
        let innerW = wide ? cellWidth * 2 : cellWidth
        let slotW = innerW + pad * 2
        let slotH = cellHeight + pad * 2
        guard slotW * slotH <= scratchSize else { return nil }

        memset(scratch, 0, slotW * slotH)
        guard let ctx = CGContext(
            data: scratch,
            width: slotW,
            height: slotH,
            bitsPerComponent: 8,
            bytesPerRow: slotW,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        if config.fontThicken {
            // ghostty-style font-thicken: slight stroke on top of the fill.
            ctx.setTextDrawingMode(.fillStroke)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(max(0.5, config.fontSize * scale * 0.03))
        }

        if scalar >= 0xE0B0 && scalar <= 0xE0BF,
           let path = CTFontCreatePathForGlyph(font, glyph, nil) {
            // Powerline separators: stretch the outline to fill the cell
            // exactly (full line height, no line-spacing gaps).
            let box = path.boundingBoxOfPath
            if box.width > 0 && box.height > 0 {
                var t = CGAffineTransform.identity
                t = t.translatedBy(x: CGFloat(pad), y: CGFloat(pad))
                t = t.scaledBy(x: CGFloat(innerW) / box.width, y: CGFloat(cellHeight) / box.height)
                t = t.translatedBy(x: -box.minX, y: -box.minY)
                ctx.addPath(path.copy(using: &t) ?? path)
                ctx.fillPath()
                return pack(slotW: slotW, slotH: slotH)
            }
        }

        // Center every glyph on its natural advance within the (possibly
        // kerning-adjusted) cell. For kerning = 1 this is a subpixel no-op;
        // for icons it fixes fonts whose PUA advances ignore the grid.
        var drawX = CGFloat(pad)
        var advGlyph = glyph
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &advGlyph, &adv, 1)
        if adv.width > 0 {
            drawX += max((CGFloat(innerW) - adv.width) / 2, CGFloat(-pad))
        }

        var g = glyph
        var pos = CGPoint(x: drawX, y: CGFloat(pad) + baselineY)
        CTFontDrawGlyphs(font, &g, &pos, 1, ctx)
        return pack(slotW: slotW, slotH: slotH)
    }

    private func pack(slotW: Int, slotH: Int) -> GlyphInfo {
        if shelfX + slotW > GlyphAtlas.textureSize {
            shelfX = 0
            shelfY += shelfHeight
            shelfHeight = 0
        }
        if shelfY + slotH > GlyphAtlas.textureSize {
            // Atlas exhausted (thousands of unique glyphs): start over.
            shelfX = 0
            shelfY = 0
            shelfHeight = 0
            cache.removeAll(keepingCapacity: true)
        }
        shelfHeight = max(shelfHeight, slotH)

        texture.replace(
            region: MTLRegionMake2D(shelfX, shelfY, slotW, slotH),
            mipmapLevel: 0,
            withBytes: scratch,
            bytesPerRow: slotW
        )

        let ts = Float(GlyphAtlas.textureSize)
        let info = GlyphInfo(
            uvOrigin: SIMD2<Float>(Float(shelfX) / ts, Float(shelfY) / ts),
            uvSize: SIMD2<Float>(Float(slotW) / ts, Float(slotH) / ts),
            pxSize: SIMD2<Float>(Float(slotW), Float(slotH))
        )
        shelfX += slotW
        return info
    }
}
