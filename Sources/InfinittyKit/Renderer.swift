import AppKit
import Metal
import QuartzCore
import os
import simd

// CPU-side mirrors of the shader instance structs (layouts match MSL).
private struct BGInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
}

private struct GlyphInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    var color: SIMD4<Float>
}

/// Metal renderer. Runs on its own thread behind a CADisplayLink, triple
/// buffered, and renders only when the terminal generation changes — idle
/// terminals cost zero GPU and (after a short grace period) zero CPU, because
/// the display link pauses itself until the parser pokes it awake.
final class Renderer: NSObject {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private(set) var atlas: GlyphAtlas
    private var theme: Theme

    private var layer: CAMetalLayer!
    private var terminal: Terminal!

    private var bgPipeline: MTLRenderPipelineState!
    private var glyphPipeline: MTLRenderPipelineState!
    private var spritePipeline: MTLRenderPipelineState!

    // Extra top content inset (transparent/hidden titlebar styles).
    var topInsetPoints: CGFloat = 0

    // Codex pet overlay.
    private var petTexture: MTLTexture?
    private var petFrame = (row: 0, col: 0)
    private var petDirty = false
    private var petSizePoints: CGFloat = 96

    // Inline images (OSC 1337): textures cached per placement id.
    private var imageTextures: [UInt64: MTLTexture] = [:]

    private func imageTexture(for id: UInt64) -> MTLTexture? {
        if let cached = imageTextures[id] { return cached }
        guard let (w, h, rgba) = terminal.imageData(id: id) else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        rgba.withUnsafeBytes { buf in
            texture.replace(
                region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                withBytes: buf.baseAddress!, bytesPerRow: w * 4)
        }
        if imageTextures.count > 16 { imageTextures.removeAll() }
        imageTextures[id] = texture
        return texture
    }

    private let inflight = DispatchSemaphore(value: 3)
    private var frameIndex = 0
    private var bgBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var glyphBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var decoBuffers: [MTLBuffer?] = [nil, nil, nil]

    private var snap = TermSnapshot()
    private var bgInst: [BGInstance] = []
    private var glyphInst: [GlyphInstance] = []
    private var decoInst: [BGInstance] = []

    private let renderLock = NSLock()
    private var lastGen: UInt64 = 0
    private var idleTicks = 0
    private static let idleTicksBeforePause = 120

    private var displayLink: CADisplayLink?
    private var renderThread: Thread?
    private var renderRunLoop: CFRunLoop?
    private let linkPaused = OSAllocatedUnfairLock(initialState: false)

    private(set) var config: AppConfig
    var insetPoints: CGFloat { config.margin }

    static let sharedDevice: MTLDevice = MTLCreateSystemDefaultDevice()!

    init(config: AppConfig, scale: CGFloat) {
        self.config = config
        device = Renderer.sharedDevice
        queue = device.makeCommandQueue()!
        atlas = GlyphAtlas.atlas(device: device, config: config, scale: scale)
        theme = Theme.dark.applying(config)
        super.init()
        buildPipelines()
    }

    /// Live config reload: swap atlas, theme, and metrics. The caller
    /// re-runs view geometry afterwards.
    func applyConfig(_ newConfig: AppConfig, scale: CGFloat) {
        renderLock.lock()
        defer { renderLock.unlock() }
        config = newConfig
        atlas = GlyphAtlas.atlas(device: device, config: newConfig, scale: scale)
        theme = Theme.dark.applying(newConfig)
        if let layer { prepare(layer: layer) }
    }

    // MARK: - pet overlay

    func setPet(texture: MTLTexture?, sizePoints: CGFloat) {
        renderLock.lock()
        defer { renderLock.unlock() }
        petTexture = texture
        petSizePoints = sizePoints
        petFrame = (0, 0)
        petDirty = true
    }

    /// Called by the pet animator (main thread) per animation frame.
    func setPetFrame(row: Int, col: Int) {
        renderLock.lock()
        if petFrame != (row, col) {
            petFrame = (row, col)
            petDirty = true
        }
        let dirty = petDirty
        renderLock.unlock()
        if dirty { poke() }
    }

    var cellSizePoints: CGSize { atlas.cellSizePoints }
    var backgroundColor: SIMD4<Float> { theme.background }

    /// Give a pane an immediate backing color before its first Metal drawable
    /// is available. This prevents a transparent frame when a new pane is
    /// inserted into a borderless/translucent window such as the quick terminal.
    /// Opaque setups only: the drawable's own translucent clear color
    /// composites over the layer background every frame, so a placeholder
    /// there would double the effective background opacity for the lifetime
    /// of the pane.
    func prepare(layer: CAMetalLayer) {
        let opaque = config.backgroundOpacity >= 1 && !config.backgroundBlur
        layer.isOpaque = opaque
        let bg = theme.background
        layer.backgroundColor = opaque
            ? CGColor(red: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z), alpha: 1)
            : nil
    }

    private func buildPipelines() {
        let options = MTLCompileOptions()
        options.fastMathEnabled = true
        let library = try! device.makeLibrary(source: shaderSource, options: options)

        func pipeline(vertex: String, fragment: String, blend: Bool) -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            let att = desc.colorAttachments[0]!
            att.pixelFormat = .bgra8Unorm
            if blend {
                att.isBlendingEnabled = true
                att.rgbBlendOperation = .add
                att.alphaBlendOperation = .add
                att.sourceRGBBlendFactor = .sourceAlpha
                att.sourceAlphaBlendFactor = .sourceAlpha
                att.destinationRGBBlendFactor = .oneMinusSourceAlpha
                att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try! device.makeRenderPipelineState(descriptor: desc)
        }

        bgPipeline = pipeline(vertex: "bg_vertex", fragment: "bg_fragment", blend: true)
        glyphPipeline = pipeline(vertex: "glyph_vertex", fragment: "glyph_fragment", blend: true)

        // Sprite pipeline: premultiplied-alpha blending for CG-decoded pets.
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "glyph_vertex")
        desc.fragmentFunction = library.makeFunction(name: "sprite_fragment")
        let att = desc.colorAttachments[0]!
        att.pixelFormat = .bgra8Unorm
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add
        att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .one
        att.sourceAlphaBlendFactor = .one
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        spritePipeline = try! device.makeRenderPipelineState(descriptor: desc)
    }

    // MARK: - lifecycle

    func attach(view: NSView, layer: CAMetalLayer, terminal: Terminal) {
        self.layer = layer
        self.terminal = terminal
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        prepare(layer: layer)
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true

        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        displayLink = link

        let thread = Thread { [weak self] in
            guard let self else { return }
            self.renderRunLoop = CFRunLoopGetCurrent()
            link.add(to: RunLoop.current, forMode: .common)
            while !Thread.current.isCancelled {
                _ = RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "infinitty-render"
        thread.qualityOfService = .userInteractive
        renderThread = thread
        thread.start()
    }

    /// Called from any thread when terminal content changes.
    func poke() {
        let wasPaused = linkPaused.withLock { paused -> Bool in
            let was = paused
            paused = false
            return was
        }
        guard wasPaused, let rl = renderRunLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.displayLink?.isPaused = false
            self?.idleTicks = 0
        }
        CFRunLoopWakeUp(rl)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let gen = terminal.currentGeneration
        renderLock.lock()
        let petNeedsFrame = petDirty
        let lastGen = self.lastGen // written under renderLock in render()
        renderLock.unlock()
        if petNeedsFrame {
            idleTicks = 0
            render(sync: false)
            return
        }
        if gen == lastGen {
            idleTicks += 1
            if idleTicks >= Renderer.idleTicksBeforePause {
                idleTicks = 0
                linkPaused.withLock { $0 = true }
                // Anything poked after the flag was set will unpause us; only
                // sleep if nothing changed in the meantime.
                if terminal.currentGeneration == lastGen {
                    link.isPaused = true
                } else {
                    linkPaused.withLock { $0 = false }
                }
            }
            return
        }
        idleTicks = 0
        render(sync: false)
    }

    /// Synchronous render for live resize: encode, wait for schedule, present.
    /// Keeps the drawable glued to the window during resize — no jelly.
    func renderNow(sync: Bool) {
        render(sync: sync)
    }

    /// Rebuild the glyph atlas (display scale change).
    func updateScale(_ scale: CGFloat) {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard scale != atlas.scale else { return }
        atlas = GlyphAtlas.atlas(device: device, config: config, scale: scale)
    }

    /// Tear down the render thread and display link (pane/tab closed).
    func shutdown() {
        guard let rl = renderRunLoop else { return }
        renderThread?.cancel()
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [displayLink] in
            displayLink?.invalidate()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(rl)
    }

    // MARK: - frame

    private func render(sync: Bool) {
        renderLock.lock()
        defer { renderLock.unlock() }

        let drawableSize = layer.drawableSize
        guard drawableSize.width >= 1, drawableSize.height >= 1 else { return }

        let gen = terminal.copySnapshot(into: &snap)
        buildInstances()

        inflight.wait()
        guard let drawable = layer.nextDrawable(),
              let cb = queue.makeCommandBuffer() else {
            inflight.signal()
            return
        }

        let slot = frameIndex % 3
        frameIndex += 1
        let bgBuf = fill(&bgBuffers[slot], with: bgInst)
        let glyphBuf = fill(&glyphBuffers[slot], with: glyphInst)
        let decoBuf = fill(&decoBuffers[slot], with: decoInst)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let bg = theme.background
        let alpha = Double(bg.w)
        // Premultiplied clear for translucent windows.
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bg.x) * alpha, green: Double(bg.y) * alpha,
            blue: Double(bg.z) * alpha, alpha: alpha
        )

        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
            inflight.signal()
            return
        }
        var viewport = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))

        if !bgInst.isEmpty, let buf = bgBuf {
            enc.setRenderPipelineState(bgPipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: bgInst.count)
        }
        if !glyphInst.isEmpty, let buf = glyphBuf {
            enc.setRenderPipelineState(glyphPipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: glyphInst.count)
        }
        if !decoInst.isEmpty, let buf = decoBuf {
            enc.setRenderPipelineState(bgPipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: decoInst.count)
        }
        // Single-quad sprite draws (inline images, pet) use setVertexBytes.
        func drawSprite(_ inst: GlyphInstance, texture: MTLTexture) {
            var instance = inst
            enc.setRenderPipelineState(spritePipeline)
            enc.setVertexBytes(&instance, length: MemoryLayout<GlyphInstance>.stride, index: 0)
            enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
        }

        if !snap.images.isEmpty {
            let cw = Float(atlas.cellWidth)
            let ch = Float(atlas.cellHeight)
            let inset = Float(insetPoints * atlas.scale)
            let insetTop = inset + Float(topInsetPoints) * Float(atlas.scale)
            for img in snap.images {
                guard let tex = imageTexture(for: img.id) else { continue }
                drawSprite(GlyphInstance(
                    origin: SIMD2<Float>(
                        inset + Float(img.col) * cw,
                        insetTop + Float(img.viewRow) * ch
                    ),
                    size: SIMD2<Float>(Float(img.cellCols) * cw, Float(img.cellRows) * ch),
                    uvOrigin: SIMD2<Float>(0, 0),
                    uvSize: SIMD2<Float>(1, 1),
                    color: SIMD4<Float>(1, 1, 1, 1)
                ), texture: tex)
            }
        }
        if let petTex = petTexture {
            let scale = Float(atlas.scale)
            let w = Float(petSizePoints) * scale
            let h = w * (208.0 / 192.0)
            let m = 10 * scale
            drawSprite(GlyphInstance(
                origin: SIMD2<Float>(viewport.x - w - m, viewport.y - h - m),
                size: SIMD2<Float>(w, h),
                uvOrigin: SIMD2<Float>(Float(petFrame.col) * 192.0 / 1536.0, Float(petFrame.row) * 208.0 / 1872.0),
                uvSize: SIMD2<Float>(192.0 / 1536.0, 208.0 / 1872.0),
                color: SIMD4<Float>(1, 1, 1, 1)
            ), texture: petTex)
        }
        petDirty = false
        enc.endEncoding()

        cb.addCompletedHandler { [inflight] _ in inflight.signal() }
        if sync {
            cb.commit()
            cb.waitUntilScheduled()
            drawable.present()
        } else {
            cb.present(drawable)
            cb.commit()
        }
        lastGen = gen
    }

    private func fill<T>(_ buffer: inout MTLBuffer?, with data: [T]) -> MTLBuffer? {
        guard !data.isEmpty else { return nil }
        let needed = data.count * MemoryLayout<T>.stride
        if buffer == nil || buffer!.length < needed {
            buffer = device.makeBuffer(length: max(needed * 2, 4096), options: .storageModeShared)
        }
        data.withUnsafeBytes { src in
            buffer!.contents().copyMemory(from: src.baseAddress!, byteCount: needed)
        }
        return buffer
    }

    // MARK: - instance building

    @inline(__always)
    private func resolve(_ code: UInt32, isFG: Bool, flags: UInt16) -> SIMD4<Float> {
        var color: SIMD4<Float>
        if code & 0x4000_0000 != 0 {
            color = code == ColorCode.defaultFG ? theme.foreground : theme.background
        } else if code & 0x8000_0000 != 0 {
            color = SIMD4<Float>(
                Float((code >> 16) & 0xFF) / 255,
                Float((code >> 8) & 0xFF) / 255,
                Float(code & 0xFF) / 255,
                1
            )
        } else {
            var idx = Int(code & 0xFF)
            if isFG && idx < 8 && flags & CellFlags.bold != 0 { idx += 8 }
            color = theme.palette[idx]
        }
        if isFG && flags & CellFlags.faint != 0 {
            color = simd_mix(theme.background, color, SIMD4<Float>(repeating: 0.55))
            color.w = 1
        }
        return color
    }

    private func buildInstances() {
        bgInst.removeAll(keepingCapacity: true)
        glyphInst.removeAll(keepingCapacity: true)
        decoInst.removeAll(keepingCapacity: true)

        let cw = Float(atlas.cellWidth)
        let ch = Float(atlas.cellHeight)
        let pad = Float(GlyphAtlas.pad)
        let inset = Float(insetPoints) * Float(atlas.scale)
        let insetTop = inset + Float(topInsetPoints) * Float(atlas.scale)
        let underlineH = max(Float(atlas.scale), 1)

        for r in 0..<snap.rows {
            let base = r * snap.cols
            let y = insetTop + Float(r) * ch

            // Run-merge identical adjacent backgrounds into single quads.
            var runStart = -1
            var runColor = SIMD4<Float>(repeating: 0)
            func flushRun(at end: Int) {
                guard runStart >= 0 else { return }
                bgInst.append(BGInstance(
                    origin: SIMD2<Float>(inset + Float(runStart) * cw, y),
                    size: SIMD2<Float>(Float(end - runStart) * cw, ch),
                    color: runColor
                ))
                runStart = -1
            }

            for c in 0..<snap.cols {
                let cell = snap.cells[base + c]
                let isCursor = snap.cursorVisible && !snap.scrolledBack
                    && r == snap.cursorY && c == snap.cursorX

                let inverse = cell.flags & CellFlags.inverse != 0
                var fg = resolve(inverse ? cell.bg : cell.fg, isFG: true, flags: cell.flags)
                var bgColor: SIMD4<Float>? = nil
                let bgCode = inverse ? cell.fg : cell.bg
                if inverse || bgCode != ColorCode.defaultBG {
                    bgColor = resolve(bgCode, isFG: false, flags: cell.flags)
                }
                if cell.flags & CellFlags.selected != 0 {
                    bgColor = theme.selection
                }
                if isCursor {
                    bgColor = theme.cursor
                    fg = SIMD4<Float>(theme.background.x, theme.background.y, theme.background.z, 1)
                }

                if let color = bgColor {
                    if runStart >= 0 && color == runColor {
                        // extend run
                    } else {
                        flushRun(at: c)
                        runStart = c
                        runColor = color
                    }
                } else {
                    flushRun(at: c)
                }

                let x = inset + Float(c) * cw

                if cell.glyph > 0x20 && cell.flags & CellFlags.wideContinuation == 0
                    && cell.flags & CellFlags.invisible == 0 {
                    let style = Int(cell.flags & CellFlags.bold != 0 ? 1 : 0)
                        | Int(cell.flags & CellFlags.italic != 0 ? 2 : 0)
                    let wide = cell.flags & CellFlags.wide != 0
                    if let g = atlas.glyph(cell.glyph, style: style, wide: wide) {
                        glyphInst.append(GlyphInstance(
                            origin: SIMD2<Float>(x - pad, y - pad),
                            size: g.pxSize,
                            uvOrigin: g.uvOrigin,
                            uvSize: g.uvSize,
                            color: fg
                        ))
                    }
                }

                if cell.flags & CellFlags.underline != 0 {
                    decoInst.append(BGInstance(
                        origin: SIMD2<Float>(x, y + ch - underlineH - 1),
                        size: SIMD2<Float>(cw, underlineH),
                        color: fg
                    ))
                }
                if cell.flags & CellFlags.strikethrough != 0 {
                    decoInst.append(BGInstance(
                        origin: SIMD2<Float>(x, y + ch * 0.5),
                        size: SIMD2<Float>(cw, underlineH),
                        color: fg
                    ))
                }
            }
            flushRun(at: snap.cols)
        }

        // Inline hint (ghost text): dim glyphs after the cursor, clipped to the
        // line. Not real cells — purely an overlay.
        if !snap.ghost.isEmpty, snap.cursorY < snap.rows {
            let ghostColor = simd_mix(theme.background, theme.foreground, SIMD4<Float>(repeating: 0.42))
            var col = snap.cursorX
            let y = insetTop + Float(snap.cursorY) * ch
            for scalar in snap.ghost.unicodeScalars {
                if col >= snap.cols { break }
                let u = scalar.value
                if u > 0x20, let g = atlas.glyph(u, style: 0, wide: false) {
                    let x = inset + Float(col) * cw
                    glyphInst.append(GlyphInstance(
                        origin: SIMD2<Float>(x - pad, y - pad),
                        size: g.pxSize, uvOrigin: g.uvOrigin, uvSize: g.uvSize,
                        color: SIMD4<Float>(ghostColor.x, ghostColor.y, ghostColor.z, 1)
                    ))
                }
                col += 1
            }
        }
    }
}
