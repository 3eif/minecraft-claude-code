// MCOverlay: full-screen overlay that plays one Minecraft moment, or shows one
// screen (screens.swift) until it is closed, and quits.
//
//   MCOverlay <assetsDir> totem [volume]
//   MCOverlay <assetsDir> advancement <task|goal|challenge> <title> <itemIcon> [description]
//   MCOverlay <assetsDir> death <title> <cause> <score> <buttonLabel>
//
// Timings follow Minecraft 1.21: GameRenderer.renderItemActivationAnimation (totem),
// AdvancementToast and ToastManager (toast). The game runs at 20 ticks a second.

import AppKit
import AVFoundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: MCOverlay <assetsDir> totem | advancement <type> <title> <icon>\n".data(using: .utf8)!)
    exit(2)
}
let assets = URL(fileURLWithPath: args[1])
let mode = args[2]

// MARK: assets

func loadImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(assets.appendingPathComponent(path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

var players: [AVAudioPlayer] = []
/// MC_VOLUME scales every sound; 0 mutes. MC_MUTED names the kinds of sound
/// turned off in Music & Sounds, comma-separated.
var masterVolume = Float(ProcessInfo.processInfo.environment["MC_VOLUME"] ?? "") ?? 1
var mutedKinds = Set((ProcessInfo.processInfo.environment["MC_MUTED"] ?? "").split(separator: ",").map(String.init))
func soundKind(_ name: String) -> String {
    if name.hasPrefix("hit") { return "damage" }
    if name.hasPrefix("eat") || name == "burp" { return "eating" }
    if name == "orb" { return "orbs" }
    if name == "levelup" { return "xp" }
    if name.hasPrefix("toast") || name == "challenge_complete" { return "advancements" }
    if name == "use_totem" { return "totem" }
    if name.hasPrefix("villager") { return "villager" }
    return name == "click" ? "clicks" : name
}
func playSound(_ name: String, volume: Float = 1) {
    guard masterVolume > 0, !mutedKinds.contains(soundKind(name)) else { return }
    playRaw(name, volume * masterVolume)
}
/// Plays a sound at exactly this volume. Each file is read once; the server keeps them all.
var soundData: [String: Data] = [:]
func playRaw(_ name: String, _ volume: Float) {
    if soundData[name] == nil { soundData[name] = try? Data(contentsOf: assets.appendingPathComponent("sounds/\(name).wav")) }
    guard let data = soundData[name], let p = try? AVAudioPlayer(data: data) else { return }
    p.volume = volume
    p.play()
    players.removeAll { !$0.isPlaying }
    players.append(p)
}

func bitmap(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Multiplies an image by a color, keeping its alpha (how Minecraft tints particles and text).
func tint(_ img: CGImage, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
    let ctx = bitmap(img.width, img.height)
    let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    ctx.draw(img, in: rect)
    ctx.setBlendMode(.multiply)
    ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
    ctx.fill(rect)
    ctx.setBlendMode(.destinationIn)
    ctx.draw(img, in: rect)
    return ctx.makeImage()!
}

/// Draws an image into a y-down context without flipping it.
func blit(_ ctx: CGContext, _ img: CGImage, _ rect: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    ctx.restoreGState()
}

// MARK: Minecraft's default font (ascii.png, 16x16 cells of 8x8)

final class MCFont {
    let sheet: CGImage
    var widths = [Int](repeating: 0, count: 256)
    var tinted: [String: CGImage] = [:]

    init(_ img: CGImage) {
        sheet = img
        let w = img.width, h = img.height, cell = w / 16
        let ctx = bitmap(w, h)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self), stride = ctx.bytesPerRow
        for ch in 0..<256 {
            let gx = (ch % 16) * cell, gy = (ch / 16) * cell
            var width = 0
            outer: for col in Swift.stride(from: cell - 1, through: 0, by: -1) {
                for row in 0..<cell where data[(gy + row) * stride + (gx + col) * 4 + 3] > 0 { width = col + 1; break outer }
            }
            widths[ch] = width
        }
    }

    func advance(_ c: Character) -> Int {
        if c == " " { return 4 }
        guard let a = c.asciiValue else { return 6 }
        return widths[Int(a)] + 1
    }

    func width(_ s: String) -> Int { s.reduce(0) { $0 + advance($1) } }

    func draw(_ s: String, x: CGFloat, y: CGFloat, rgb: UInt32, in ctx: CGContext) {
        let key = String(rgb, radix: 16)
        let sh = tinted[key] ?? {
            let t = tint(sheet, CGFloat((rgb >> 16) & 255) / 255, CGFloat((rgb >> 8) & 255) / 255, CGFloat(rgb & 255) / 255)
            tinted[key] = t
            return t
        }()
        var cx = x
        for c in s {
            if c != " ", let a = c.asciiValue, let g = sh.cropping(to: CGRect(x: Int(a) % 16 * 8, y: Int(a) / 16 * 8, width: 8, height: 8)) {
                blit(ctx, g, CGRect(x: cx, y: y, width: 8, height: 8))
            }
            cx += CGFloat(advance(c))
        }
    }
}

// MARK: scenes

protocol Scene {
    var finished: Bool { get }
    func draw(_ ctx: CGContext, t: Double, w: CGFloat, h: CGFloat)   // t in seconds, w/h in GUI pixels
}

/// GameRenderer.renderItemActivationAnimation, flattened from 3D to 2D, plus the
/// first-person burst of totem particles (a 2D approximation).
final class TotemScene: Scene {
    let item = loadImage("totem_of_undying.png")!
    let offX = Double.random(in: -1...1), offY = Double.random(in: -1...1)
    var glitter: [[CGImage]] = []                   // [color][frame]
    struct P { var x, y, vx, vy: Double; var age = 0; let life: Int; let color: Int; let size: Double }
    var particles: [P] = []
    var lastTick = -1
    var finished = false

    init(volume: Float) {
        let frames = (0..<8).compactMap { loadImage("particle/glitter_\($0).png") }
        // TotemParticle colors: 1 in 4 yellow, the rest green.
        for k in 0..<12 {
            let r = Double.random(in: 0..<1)
            let rgb: (Double, Double, Double) = k < 3 ? (0.6 + r * 0.2, 0.6 + r * 0.3, r * 0.2) : (0.1 + r * 0.2, 0.4 + r * 0.3, r * 0.2)
            glitter.append(frames.map { tint($0, rgb.0, rgb.1, rgb.2) })
        }
        playSound("use_totem", volume: volume)
    }

    func cx(_ w: Double) -> Double { (w / 2).rounded(.down) }
    func cy(_ h: Double) -> Double { (h * 0.72).rounded(.down) }

    func tick(_ n: Int, w: Double, h: Double) {
        // TrackingEmitter: 30 ticks, 16 particles a tick in the game; a few here, close around the totem.
        if n < 30 {
            for _ in 0..<3 {
                let a = Double.random(in: 0..<(2 * .pi)), sp = Double.random(in: 3...10)
                particles.append(P(x: cx(w) + cos(a) * Double.random(in: 4...28),
                                   y: cy(h) + sin(a) * Double.random(in: 4...20),
                                   vx: cos(a) * sp, vy: sin(a) * sp - 3,
                                   life: 60 + Int.random(in: 0..<12),
                                   color: Int.random(in: 0..<4) == 0 ? Int.random(in: 0..<3) : Int.random(in: 3..<12),
                                   size: Double.random(in: 5...12)))
            }
        }
        for i in particles.indices {
            particles[i].x += particles[i].vx; particles[i].y += particles[i].vy
            particles[i].vx *= 0.6; particles[i].vy = particles[i].vy * 0.6 + 1.25 * 0.4
            particles[i].age += 1
        }
        particles.removeAll { $0.age >= $0.life }
    }

    func draw(_ ctx: CGContext, t: Double, w: CGFloat, h: CGFloat) {
        let ticks = t * 20
        let n = Int(ticks)
        while lastTick < n { lastTick += 1; tick(lastTick, w: Double(w), h: Double(h)) }

        for p in particles {
            let frame = min(7, p.age * 7 / max(1, p.life))
            var alpha = 1.0
            if p.age > p.life / 2 { alpha = 1 - Double(p.age - p.life / 2) / Double(p.life) }
            ctx.setAlpha(alpha)
            blit(ctx, glitter[p.color][frame], CGRect(x: p.x - p.size / 2, y: p.y - p.size / 2, width: p.size, height: p.size))
        }
        ctx.setAlpha(1)

        if ticks < 40 {
            let f = ticks / 40, f1 = f * f, f2 = f * f1
            let f3 = 10.25 * f2 * f1 - 24.95 * f1 * f1 + 25.5 * f2 - 13.8 * f1 + 4.0 * f
            let f4 = f3 * .pi
            let s2 = abs(sin(f4 * 2))
            let x = cx(Double(w)) + offX * 12 * s2
            let y = cy(Double(h)) + offY * 8 * s2
            // The game fills the view with it; over a whole desktop that is a jump scare, so
            // it rises small, low on the screen where the prompt usually is, and is gone in two seconds.
            let size = 12 + 36 * sin(f4)
            let yRot = 900 * abs(sin(f4)) * .pi / 180
            let wobble = 6 * cos(f * 8) * .pi / 180
            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            ctx.scaleBy(x: size, y: size)
            ctx.scaleBy(x: cos(yRot), y: cos(wobble))      // Y then X rotation, seen head-on
            ctx.rotate(by: -wobble)                         // Z rotation
            blit(ctx, item, CGRect(x: -0.5, y: -0.5, width: 1, height: 1))
            ctx.restoreGState()
        }
        finished = ticks >= 40 && particles.isEmpty && lastTick >= 30
    }
}

/// Where the helper keeps what its processes share: toast slots, the music player's state.
let cacheDir: URL = {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("minecraft-hud")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

/// AdvancementToast inside ToastManager: slides in over 600 ms (eased f²), holds 10 s (5 in the game), slides out.
/// As in the game, up to five show at once, stacked down the right edge. Each
/// toast is its own process, so a slot is a lock file: the first free one from
/// the top is taken and held until the toast has left.
final class ToastScene: NSObject, Scene, NSSharingServicePickerDelegate {
    // A toast's room in the stack: the tallest one, and the Share button under it.
    static let pitch: CGFloat = 82
    /// How long a toast stays in, after its 600 ms slide; twice the game's five seconds.
    static let hold: Double = 10_000
    let font = MCFont(loadImage("ascii.png")!)
    let icon: CGImage?
    let heading: String, color: UInt32, title: String, type: String
    var tutorial: Bool { type == "tip" }
    let lines: [String]
    let top: CGFloat
    var slot = 0
    var lock: Int32 = -1
    var began: Double? = nil
    var hidden = false
    var finished = false
    // Where the toast and its Share button are now, in GUI pixels, and whether the pointer is on it.
    var rect: CGRect = .zero
    var shareRect: CGRect = .zero
    var hovered = false
    var overShare = false
    // Share shows while the pointer is on the toast and two seconds after it leaves, so it can still be reached.
    var shareUntil = -1.0
    var sharing = false
    var shared = false
    // Time in, less what was spent under the pointer or in the share menu.
    var shownMs = 0.0
    var lastT: Double? = nil

    init(type: String, title: String, iconName: String, desc: String, top: CGFloat) {
        icon = loadImage("item/\(iconName).png")
        switch type {
        case "tip": heading = clean(title); color = 0x500050
        case "challenge": heading = "Challenge Complete!"; color = 0xFF88FF
        case "goal": heading = "Goal Reached!"; color = 0xFFFF00
        default: heading = "Advancement Made!"; color = 0xFFFF00
        }
        self.title = clean(title)
        self.type = type
        self.top = top
        // Up to three lines; a long description widens the toast rather than being cut.
        lines = Array(wrap(clean(desc), max(124, font.width(clean(title)), font.width(clean(desc)) / (type == "tip" ? 2 : 3) + 12)).prefix(3))
    }

    deinit { if lock >= 0 { close(lock) } }

    /// Takes the first free slot; false while all five are showing.
    func claim() -> Bool {
        for i in 0..<5 {
            let fd = open(cacheDir.appendingPathComponent("toast-\(i).lock").path, O_CREAT | O_RDWR, 0o644)
            if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 { slot = i; lock = fd; return true }
            if fd >= 0 { close(fd) }
        }
        return false
    }

    var size: CGSize {
        if tutorial {
            return CGSize(width: CGFloat(max(160, 30 + max(font.width(heading), lines.map { font.width($0) }.max() ?? 0) + 8)),
                          height: CGFloat(max(32, 18 + lines.count * 9 + 6)))
        }
        // The game's toast is 160 wide; a longer title widens it rather than running off the edge.
        return CGSize(width: CGFloat(max(160, 30 + max(font.width(title), font.width(heading), lines.map { font.width($0) }.max() ?? 0) + 8)),
                      height: CGFloat(32 + (lines.isEmpty ? 0 : lines.count * 9 + 2)))
    }

    /// The toast itself at (x, y); with `button`, its Share button too.
    func paint(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, button: Bool) {
        let s = size
        if tutorial {
            // TutorialToast: a light frame, the title in purple, the text in black, one line lower.
            nine(ctx, "gui/sprites/toast/tutorial.png", CGRect(x: x, y: y, width: s.width, height: s.height), 4)
            if let icon { blit(ctx, icon, CGRect(x: x + 8, y: y + 8, width: 16, height: 16)) }
            font.draw(heading, x: x + 30, y: y + 7, rgb: color, in: ctx)
            for (i, line) in lines.enumerated() { font.draw(line, x: x + 30, y: y + 18 + CGFloat(i * 9), rgb: 0x000000, in: ctx) }
            return
        }
        nine(ctx, "toast_advancement.png", CGRect(x: x, y: y, width: s.width, height: s.height), 4)
        if let icon { blit(ctx, icon, CGRect(x: x + 8, y: y + 8, width: 16, height: 16)) }
        font.draw(heading, x: x + 30, y: y + 7, rgb: color, in: ctx)
        font.draw(title, x: x + 30, y: y + 18, rgb: 0xFFFFFF, in: ctx)
        for (i, line) in lines.enumerated() { font.draw(line, x: x + 30, y: y + 30 + CGFloat(i * 9), rgb: 0xAAAAAA, in: ctx) }
        guard button else { return }
        // A game button under the toast's right end, reading Shared once something was shared.
        let label = shared ? "Shared" : "Share"
        let bw = CGFloat(font.width(label) + 16)
        let r = CGRect(x: x + s.width - bw, y: y + s.height + 2, width: bw, height: 16)
        nine(ctx, overShare ? "button_highlighted.png" : "button.png", r, 2)
        font.draw(label, x: (r.midX - CGFloat(font.width(label)) / 2).rounded(.down), y: r.minY + 4, rgb: overShare ? 0xFFFFA0 : 0xE0E0E0, in: ctx)
        shareRect = r
    }

    func draw(_ ctx: CGContext, t: Double, w: CGFloat, h: CGFloat) {
        if began == nil {
            guard claim() else { finished = t > 60; return }
            began = t
            lastT = t
            playSound("toast_in")
            if type == "challenge" { playSound("challenge_complete") }
            if tutorial { hidden = false }
        }
        // The clock stops while the pointer is on the toast or its share menu is open, once it is all the way in.
        let dt = (t - (lastT ?? t)) * 1000
        lastT = t
        if !(shownMs >= 600 && shownMs < ToastScene.hold && (hovered || sharing)) { shownMs += dt }
        let ms = shownMs
        var vis: Double
        if ms < ToastScene.hold { let f = min(1, ms / 600); vis = f * f }
        else {
            if !hidden { hidden = true; playSound("toast_out") }
            let f = min(1, (ms - ToastScene.hold) / 600); vis = 1 - f * f
        }
        let s = size
        let x = w - s.width * vis, y = top + CGFloat(slot) * ToastScene.pitch
        if hovered { shareUntil = t + 2 }
        let showShare = !tutorial && (t < shareUntil || sharing || ProcessInfo.processInfo.environment["MC_TOAST_HOVER"] != nil)
        if !showShare { shareRect = .zero; overShare = false }
        paint(ctx, x, y, button: showShare)
        // What takes the pointer: the toast, and its button under it while it shows.
        let toast = CGRect(x: x, y: y, width: s.width, height: s.height)
        rect = showShare ? toast.union(shareRect) : toast
        finished = ms >= ToastScene.hold + 600
    }

    /// The pointer, in GUI pixels, from the view each frame (nil off the toast's display).
    func point(_ p: CGPoint?) {
        hovered = p.map(rect.contains) ?? false
        overShare = !tutorial && (p.map(shareRect.contains) ?? false)
    }

    /// A click on the toast: Share opens the system's share menu with a picture of it, and nothing else.
    func click(_ p: CGPoint, in view: NSView, gui: CGFloat) {
        guard !tutorial, shareRect.contains(p), !sharing else { return }
        playSound("click", volume: 0.12)
        let s = size, k: CGFloat = 4
        let ctx = bitmap(Int(s.width * k), Int(s.height * k))
        ctx.interpolationQuality = .none
        ctx.translateBy(x: 0, y: s.height * k); ctx.scaleBy(x: k, y: -k)
        paint(ctx, 0, 0, button: false)
        guard let shot = ctx.makeImage() else { return }
        let picture = NSImage(cgImage: shot, size: NSSize(width: s.width * 2, height: s.height * 2))
        let picker = NSSharingServicePicker(items: [picture])
        picker.delegate = self
        sharing = true
        app.activate(ignoringOtherApps: true)
        picker.show(relativeTo: NSRect(x: shareRect.minX * gui, y: shareRect.minY * gui, width: shareRect.width * gui, height: shareRect.height * gui),
                    of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        sharing = false
        if service != nil { shared = true }
    }
}

/// DeathScreen: the red gradient over everything, the title at double size,
/// the cause, the score in yellow, and the two buttons. As in the game the
/// buttons are disabled for the first second, then highlight under the pointer
/// and click; either one closes the screen.
var interactive = false
var pointer: CGPoint? = nil        // in GUI pixels, set by the view
var pressed: CGPoint? = nil

final class DeathScene: Scene {
    let font = MCFont(loadImage("ascii.png")!)
    let idle = loadImage("button.png"), hot = loadImage("button_highlighted.png"), off = loadImage("button_disabled.png")
    let title: String, cause: String, score: String, label: String
    var closingAt: Double? = nil
    var finished = false

    init(title: String, cause: String, score: String, label: String) {
        self.title = title; self.cause = cause; self.score = score; self.label = label
    }

    func shadowed(_ s: String, x: CGFloat, y: CGFloat, rgb: UInt32, in ctx: CGContext) {
        let dark = ((rgb >> 16) & 255) / 4 << 16 | ((rgb >> 8) & 255) / 4 << 8 | (rgb & 255) / 4
        font.draw(s, x: x + 1, y: y + 1, rgb: dark, in: ctx)
        font.draw(s, x: x, y: y, rgb: rgb, in: ctx)
    }

    func centered(_ s: String, y: CGFloat, w: CGFloat, rgb: UInt32, in ctx: CGContext) {
        shadowed(s, x: (w / 2).rounded(.down) - CGFloat(font.width(s) / 2), y: y, rgb: rgb, in: ctx)
    }

    func draw(_ ctx: CGContext, t: Double, w: CGFloat, h: CGFloat) {
        // fillGradient(0x60500000, 0xA0803030), top to bottom
        let colors = [CGColor(red: 0x50 / 255, green: 0, blue: 0, alpha: 0x60 / 255),
                      CGColor(red: 0x80 / 255, green: 0x30 / 255, blue: 0x30 / 255, alpha: 0xA0 / 255)] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        }
        ctx.saveGState()
        ctx.scaleBy(x: 2, y: 2)
        centered(title, y: 30, w: w / 2, rgb: 0xFFFFFF, in: ctx)
        ctx.restoreGState()
        centered(cause, y: 85, w: w, rgb: 0xFFFFFF, in: ctx)
        let head = "Score: "
        let x = (w / 2).rounded(.down) - CGFloat(font.width(head + score) / 2)
        shadowed(head, x: x, y: 100, rgb: 0xFFFFFF, in: ctx)
        shadowed(score, x: x + CGFloat(font.width(head)), y: 100, rgb: 0xFFFF55, in: ctx)

        let active = t >= 1                      // 20 ticks
        for (text, y) in [(label, (h / 4).rounded(.down) + 72), ("Title Screen", (h / 4).rounded(.down) + 96)] {
            let box = CGRect(x: (w / 2).rounded(.down) - 100, y: y, width: 200, height: 20)
            let over = active && pointer.map(box.contains) == true
            if let img = !active ? off : over ? hot : idle { blit(ctx, img, box) }
            centered(text, y: y + 6, w: w, rgb: active ? 0xFFFFFF : 0xA0A0A0, in: ctx)
            if active, closingAt == nil, let p = pressed, box.contains(p) {
                playSound("click", volume: 0.12)
                closingAt = t
                emit(["death": text == label ? "respawn" : "title"])
            }
        }
        pressed = nil
        // Leave a moment for the click to sound; never stay up past a minute.
        finished = closingAt.map { t - $0 > 0.25 } ?? (t > 60)
    }
}

// MARK: window

final class OverlayView: NSView {
    var scene: Scene!
    var gui: CGFloat = 3
    var start = CACurrentMediaTime()
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func gui(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / gui, y: p.y / gui)
    }
    override func mouseMoved(with event: NSEvent) { if !(scene is ToastScene) { pointer = gui(event) } }
    override func mouseDragged(with event: NSEvent) { if !(scene is ToastScene) { pointer = gui(event) } }
    override func mouseDown(with event: NSEvent) {
        if let toast = scene as? ToastScene { toast.click(gui(event), in: self, gui: gui); return }
        pointer = gui(event); pressed = pointer; held = true
    }
    override func mouseUp(with event: NSEvent) { if scene is ToastScene { return }; pointer = gui(event); held = false; released = true }
    override func scrollWheel(with event: NSEvent) {
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        // A mouse wheel held with shift scrolls across, as it does elsewhere on the Mac.
        if !event.hasPreciseScrollingDeltas && event.modifierFlags.contains(.shift) { scrolledX += event.scrollingDeltaY * k; return }
        scrolled += event.scrollingDeltaY * k
        scrolledX += event.scrollingDeltaX * k
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        // On the death screen Return, Space or Escape press Respawn; the other screens read the keys themselves.
        if !(scene is DeathScene) { keys.append(event.keyCode); return }
        if [36, 49, 53, 76].contains(event.keyCode) { pressed = CGPoint(x: bounds.width / gui / 2, y: (bounds.height / gui / 4).rounded(.down) + 82) }
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        ctx.saveGState()
        ctx.scaleBy(x: gui, y: gui)
        scene.draw(ctx, t: CACurrentMediaTime() - start, w: bounds.width / gui, h: bounds.height / gui)
        ctx.restoreGState()
        // A toast's window lets clicks through everywhere but the toast: where the pointer is decides, each frame.
        if let toast = scene as? ToastScene, let window {
            let m = NSEvent.mouseLocation, f = window.frame
            let p = NSMouseInRect(m, f, false) ? CGPoint(x: (m.x - f.minX) / gui, y: (f.maxY - m.y) / gui) : nil
            toast.point(p)
            let wanted = !(toast.hovered && !toast.tutorial)
            if window.ignoresMouseEvents != wanted { window.ignoresMouseEvents = wanted }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let screen = NSScreen.main ?? NSScreen.screens[0]
let frame = screen.frame
/// Borderless windows refuse key status by default, and then swallow clicks.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
let window = overlayWindow()

let view = OverlayView(frame: NSRect(origin: .zero, size: frame.size))
view.gui = guiScale(frame)

switch mode {
case "totem", "advancement", "tip":
    view.gui = momentGui(mode, view.gui)
    guard let scene = momentScene(Array(args[2...]), gui: view.gui) else { exit(2) }
    view.scene = scene
case "player":
    runPlayer(args.count > 3 ? args[3] : nil)
case "music":
    // One word for the player from outside: toggle, next, prev or stop.
    tellPlayer(["cmd": args.count > 3 ? args[3] : "toggle"])
    // Posting is asynchronous: give the notification a moment to leave.
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    exit(0)
case "advancements", "options", "jukebox", "guide", "death", "hero":
    window.ignoresMouseEvents = false
    window.acceptsMouseMovedEvents = true
    interactive = true
    view.scene = makeScreen(mode, args.count > 3 ? args[3] : "{}")
    // Started cold: have the server ready for the next one.
    if ProcessInfo.processInfo.environment["MC_SNAPSHOT"] == nil { startServer() }
case "parrot-snapshot":
    // MCOverlay <assets> parrot-snapshot <out.png> [dance]: the parrot drawn to a file.
    let pet = ParrotPet(show: false)
    let image = pet.snapshot(dancing: args.count > 4, at: 0.4)
    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: args[3]))
    }
    exit(0)
case "decode":
    // MCOverlay <assets> decode <in.ogg> <out.m4a>: one track decoded, for checking the decoder.
    exit(args.count > 4 && decodeVorbis(args[3], to: URL(fileURLWithPath: args[4])) ? 0 : 1)
case "serve":
    startServer()
    exit(0)
case "serve-run":
    window.ignoresMouseEvents = false
    window.acceptsMouseMovedEvents = true
    interactive = true
    view.scene = IdleScene()
default:
    exit(2)
}

// MC_SNAPSHOT=<file.png> draws one frame to a file and quits, for checking a
// screen without opening it. MC_POINTER="x,y" puts the pointer there,
// MC_CLICKS="x,y;x,y" clicks those points first, one frame each (GUI pixels),
// and MC_SCROLL scrolls on the last frame.
if let out = ProcessInfo.processInfo.environment["MC_SNAPSHOT"] {
    // MC_SIZE="w,h" sets the picture's size in pixels; MC_BACKGROUND=<png> draws an image under the
    // screen, stretched to it (a screenshot of the desktop, for pictures of the mod in place).
    let size = (ProcessInfo.processInfo.environment["MC_SIZE"] ?? "").split(separator: ",").compactMap { Int($0) }
    let W = size.count == 2 ? size[0] : 1512, H = size.count == 2 ? size[1] : 982
    let backdrop = ProcessInfo.processInfo.environment["MC_BACKGROUND"].flatMap { path -> CGImage? in
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    let point = { (s: String) -> CGPoint? in
        let n = s.split(separator: ",").compactMap { Double($0) }
        return n.count == 2 ? CGPoint(x: n[0], y: n[1]) : nil
    }
    var frames: [(CGPoint?, Bool)] = (ProcessInfo.processInfo.environment["MC_CLICKS"] ?? "").split(separator: ";").map { (point(String($0)), true) }
    frames.append((point(ProcessInfo.processInfo.environment["MC_POINTER"] ?? ""), false))
    var shot: CGImage? = nil
    for (n, (at, click)) in frames.enumerated() {
        let ctx = bitmap(W, H)
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        ctx.setFillColor(red: 0.35, green: 0.45, blue: 0.4, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        if let backdrop {
            ctx.interpolationQuality = .high
            ctx.draw(backdrop, in: CGRect(x: 0, y: 0, width: W, height: H))
            ctx.interpolationQuality = .none
        }
        // MC_PATCH="x,y,w,h,rrggbb;..." paints over spots of the background (a blur in a screenshot), in its pixels from the top left.
        for patch in (ProcessInfo.processInfo.environment["MC_PATCH"] ?? "").split(separator: ";") {
            let v = patch.split(separator: ",").map(String.init)
            guard v.count == 5, let x = Double(v[0]), let y = Double(v[1]), let w = Double(v[2]), let h = Double(v[3]), let rgb = UInt32(v[4], radix: 16) else { continue }
            ctx.setFillColor(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
            ctx.fill(CGRect(x: x, y: Double(H) - y - h, width: w, height: h))
        }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: view.gui, y: view.gui)
        pointer = at ?? pointer
        pressed = click ? at : nil
        // MC_SCROLL="dy" (or "dx,dy") scrolls by that much on the last frame, as a trackpad would.
        if n == frames.count - 1, let v = ProcessInfo.processInfo.environment["MC_SCROLL"] {
            let d = v.split(separator: ",").compactMap { Double($0) }
            if d.count == 2 { scrolledX = CGFloat(d[0]); scrolled = CGFloat(d[1]) } else if let y = d.first { scrolled = CGFloat(y) }
        }
        view.scene.draw(ctx, t: Double(n) * 0.05 + (Double(ProcessInfo.processInfo.environment["MC_T"] ?? "") ?? 2), w: CGFloat(W) / view.gui, h: CGFloat(H) / view.gui)
        ctx.restoreGState()
        // MC_STICKER="file.png,x,y,w;..." lays images over the screen (the parrot, whose window is above it), in pixels from the top left.
        for sticker in (ProcessInfo.processInfo.environment["MC_STICKER"] ?? "").split(separator: ";") {
            let v = sticker.split(separator: ",").map(String.init)
            guard v.count == 4, let x = Double(v[1]), let y = Double(v[2]), let w = Double(v[3]),
                  let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: v[0]) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let h = w * Double(img.height) / Double(img.width)
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: x, y: Double(H) - y - h, width: w, height: h))
            ctx.interpolationQuality = .none
        }
        shot = ctx.makeImage()
    }
    if let shot, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, shot, nil)
        CGImageDestinationFinalize(dest)
    }
    exit(0)
}

window.contentView = view
if mode == "serve-run" {
    let server = Server()
    server.start()
    withExtendedLifetime(server) { app.run() }
    exit(0)
}
if interactive {
    app.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
} else {
    window.orderFrontRegardless()
}
startFrames { app.terminate(nil) }
app.run()
