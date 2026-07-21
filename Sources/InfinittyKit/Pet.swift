import AppKit
import Metal

/// Codex pet playback. Atlas is the fixed Codex layout: 8 columns x 9 rows
/// of 192x208 cells (1536x1872 total), one animation per row.
enum PetAnimations {
    struct Animation {
        let row: Int
        let durations: [Double] // seconds per frame
    }

    static let idle = Animation(row: 0, durations: [0.28, 0.11, 0.11, 0.14, 0.14, 0.32])
    static let runningRight = Animation(row: 1, durations: [0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.22])
    static let runningLeft = Animation(row: 2, durations: [0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.22])
    static let waving = Animation(row: 3, durations: [0.14, 0.14, 0.14, 0.28])
    static let jumping = Animation(row: 4, durations: [0.14, 0.14, 0.14, 0.14, 0.28])
    static let failed = Animation(row: 5, durations: [0.14, 0.14, 0.14, 0.14, 0.14, 0.14, 0.14, 0.24])
    static let waiting = Animation(row: 6, durations: [0.15, 0.15, 0.15, 0.15, 0.15, 0.26])
    static let running = Animation(row: 7, durations: [0.12, 0.12, 0.12, 0.12, 0.12, 0.22])
    static let review = Animation(row: 8, durations: [0.15, 0.15, 0.15, 0.15, 0.15, 0.28])
}

enum Pet {
    static let atlasWidth = 1536
    static let atlasHeight = 1872

    private static var cache: [String: MTLTexture] = [:]

    /// Load a pet spritesheet as an RGBA texture. Accepts a codex pet name
    /// (looked up in $CODEX_HOME/pets or ~/.codex/pets), a pet directory, or
    /// a direct image path.
    static func loadTexture(_ nameOrPath: String, device: MTLDevice) -> MTLTexture? {
        if let cached = cache[nameOrPath] { return cached }

        guard let imagePath = resolveImagePath(nameOrPath) else {
            FileHandle.standardError.write(Data("infinitty: pet '\(nameOrPath)' not found\n".utf8))
            return nil
        }
        guard let image = NSImage(contentsOfFile: imagePath),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            FileHandle.standardError.write(Data("infinitty: cannot decode pet image \(imagePath)\n".utf8))
            return nil
        }

        let w = Pet.atlasWidth
        let h = Pet.atlasHeight
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        // CGBitmapContext memory is top-down for an upright draw, which is
        // exactly Metal's texture layout.
        texture.replace(
            region: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: w * 4
        )
        cache[nameOrPath] = texture
        return texture
    }

    static func resolveImagePath(_ nameOrPath: String) -> String? {
        let fm = FileManager.default
        let expanded = NSString(string: nameOrPath).expandingTildeInPath

        if !nameOrPath.contains("/") {
            let subdirectory = "Pets/\(nameOrPath.lowercased())"
            // Packaged apps preserve the Pets/<name> directory.
            if let bundled = Bundle.main.url(
                forResource: "spritesheet",
                withExtension: "webp",
                subdirectory: subdirectory
            ) {
                return bundled.path
            }
            // SwiftPM flattens processed resources into its module bundle.
            if nameOrPath.caseInsensitiveCompare("infinitty") == .orderedSame,
               let bundled = Bundle.module.url(
                   forResource: "spritesheet",
                   withExtension: "webp"
               ) {
                return bundled.path
            }
        }

        var dirs: [String] = []
        if nameOrPath.contains("/") {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: expanded, isDirectory: &isDir) {
                if !isDir.boolValue { return expanded } // direct image file
                dirs.append(expanded)
            }
        } else {
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
                ?? NSString(string: "~/.codex").expandingTildeInPath
            dirs.append("\(codexHome)/pets/\(nameOrPath)")
        }

        for dir in dirs {
            // pet.json may point at the sheet; otherwise use conventions.
            if let data = fm.contents(atPath: "\(dir)/pet.json"),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sheet = json["spritesheetPath"] as? String,
               fm.fileExists(atPath: "\(dir)/\(sheet)") {
                return "\(dir)/\(sheet)"
            }
            for name in ["spritesheet.webp", "spritesheet.png"] {
                if fm.fileExists(atPath: "\(dir)/\(name)") { return "\(dir)/\(name)" }
            }
        }
        return nil
    }
}

/// Drives the pet on the main thread. The pet RESTS on a static frame most
/// of the time and animates at things that happen:
///   - occasional idle fidget (one cycle every ~10-20 s)
///   - running loop while a command executes (OSC 133 C..D, or sustained output)
///   - waves on success, plays "failed" on a non-zero exit, jumps on the bell
final class PetAnimator {
    private enum Mode {
        case rest
        case oneShot(cyclesLeft: Int)
        case running
        case thinking
    }

    private weak var terminal: Terminal?
    private weak var renderer: Renderer?
    private var frameTimer: Timer?
    private var fidgetTimer: Timer?
    private var activityTimer: Timer?
    private var mode = Mode.rest
    private var animation = PetAnimations.idle
    private var frame = 0
    private var lastGen: UInt64 = 0
    private var quietPolls = 0
    private var markerDriven = false // OSC 133 present: trust it over heuristics

    init(terminal: Terminal, renderer: Renderer) {
        self.terminal = terminal
        self.renderer = renderer
    }

    func start() {
        stop()
        rest()
        // Fallback activity sensing for shells without OSC 133: sustained
        // output (2+ polls in a row with changes) looks like a running command.
        activityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollActivity()
        }
    }

    func stop() {
        frameTimer?.invalidate()
        fidgetTimer?.invalidate()
        activityTimer?.invalidate()
        frameTimer = nil
        fidgetTimer = nil
        activityTimer = nil
    }

    // MARK: events

    func commandStarted() {
        if case .thinking = mode { return }
        markerDriven = true
        enterRunning()
    }

    func commandEnded(exitCode: Int) {
        if case .thinking = mode { return }
        markerDriven = true
        play(exitCode == 0 ? PetAnimations.waving : PetAnimations.failed, cycles: 1)
    }

    func bell() {
        if case .running = mode { return }
        if case .thinking = mode { return }
        play(PetAnimations.jumping, cycles: 1)
    }

    /// Loop the review animation while the assistant works. Sticky: activity
    /// heuristics and command markers don't interrupt it.
    func startThinking() {
        if case .thinking = mode { return }
        mode = .thinking
        animation = PetAnimations.review
        frame = 0
        stepFrame()
    }

    func stopThinking() {
        guard case .thinking = mode else { return }
        rest()
    }

    // MARK: internals

    private func rest() {
        mode = .rest
        frameTimer?.invalidate()
        frameTimer = nil
        renderer?.setPetFrame(row: PetAnimations.idle.row, col: 0)
        scheduleFidget()
    }

    private func scheduleFidget() {
        fidgetTimer?.invalidate()
        fidgetTimer = Timer.scheduledTimer(
            withTimeInterval: Double.random(in: 9...19), repeats: false
        ) { [weak self] _ in
            guard let self, case .rest = self.mode else { return }
            let fidgets = [PetAnimations.idle, PetAnimations.waiting, PetAnimations.review]
            self.play(fidgets.randomElement() ?? PetAnimations.idle, cycles: 1)
        }
    }

    private func play(_ anim: PetAnimations.Animation, cycles: Int) {
        mode = .oneShot(cyclesLeft: cycles)
        animation = anim
        frame = 0
        stepFrame()
    }

    private func enterRunning() {
        if case .running = mode { return }
        mode = .running
        animation = PetAnimations.running
        frame = 0
        stepFrame()
    }

    private func stepFrame() {
        guard let renderer else { return }
        renderer.setPetFrame(row: animation.row, col: frame)
        let delay = animation.durations[frame]
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.advanceFrame()
        }
    }

    private func advanceFrame() {
        frame += 1
        if frame >= animation.durations.count {
            frame = 0
            switch mode {
            case .oneShot(let left) where left <= 1:
                rest()
                return
            case .oneShot(let left):
                mode = .oneShot(cyclesLeft: left - 1)
            case .rest:
                return
            case .running, .thinking:
                break // loop until the command / assistant ends
            }
        }
        stepFrame()
    }

    private func pollActivity() {
        if case .thinking = mode { return } // assistant owns the pet for now
        guard let terminal else { return }
        let gen = terminal.currentGeneration
        let changed = gen != lastGen
        lastGen = gen
        if markerDriven {
            // With OSC 133, only end running when output stops AND no D
            // marker arrived (e.g. interactive TUIs) — after a long quiet.
            if case .running = mode, !changed {
                quietPolls += 1
                if quietPolls >= 6 { rest() } // 3 s safety net
            } else {
                quietPolls = 0
            }
            return
        }
        // Heuristic mode: sustained output = running; quiet = rest.
        if changed {
            quietPolls = 0
            if case .rest = mode { enterRunning() }
        } else if case .running = mode {
            quietPolls += 1
            if quietPolls >= 2 { rest() }
        }
    }
}
