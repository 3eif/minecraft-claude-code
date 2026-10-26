// The screens that take over the display until they are closed: advancements,
// options and the guide. Each reads one JSON argument, and the ones that decide
// something print one JSON line as they close.
//
//   MCOverlay <assetsDir> advancements <json>
//   MCOverlay <assetsDir> options <json>
//   MCOverlay <assetsDir> guide {}
//
// Layouts and colors follow Minecraft 1.21's AdvancementsScreen and OptionsScreen.

import AppKit

// MARK: input, set by the view each event and cleared after every frame

var keys: [UInt16] = []
var held = false
var released = false
var scrolled: CGFloat = 0      // points scrolled since the last frame, up positive
var scrolledX: CGFloat = 0     // the same across, left positive

// MARK: drawing

let uiFont = MCFont(loadImage("ascii.png")!)
var images: [String: CGImage] = [:]
func image(_ path: String) -> CGImage? {
    if let hit = images[path] { return hit }
    let made = loadImage(path)
    images[path] = made
    return made
}

/// The font holds ASCII only; anything else reads as a question mark.
func clean(_ s: String) -> String {
    // Typographic punctuation has a plain stand-in; anything else the font lacks reads as a question mark.
    let plain: [Character: String] = ["\u{2014}": "-", "\u{2013}": "-", "\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\"", "\u{2026}": "...", "\u{00A0}": " ", "\n": " "]
    return s.map { c in c.asciiValue.map { $0 >= 32 && $0 < 127 } == true ? String(c) : plain[c] ?? "?" }.joined()
}

func fill(_ ctx: CGContext, _ r: CGRect, _ argb: UInt32) {
    ctx.setFillColor(red: CGFloat((argb >> 16) & 255) / 255, green: CGFloat((argb >> 8) & 255) / 255,
                     blue: CGFloat(argb & 255) / 255, alpha: CGFloat((argb >> 24) & 255) / 255)
    ctx.fill(r)
}

func text(_ ctx: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat, _ rgb: UInt32, shadow: Bool = false, font: MCFont = uiFont) {
    if shadow {
        let dark = ((rgb >> 16) & 255) / 4 << 16 | ((rgb >> 8) & 255) / 4 << 8 | (rgb & 255) / 4
        font.draw(s, x: x + 1, y: y + 1, rgb: dark, in: ctx)
    }
    font.draw(s, x: x, y: y, rgb: rgb, in: ctx)
}

func centered(_ ctx: CGContext, _ s: String, _ cx: CGFloat, _ y: CGFloat, _ rgb: UInt32, shadow: Bool = true) {
    text(ctx, s, cx.rounded(.down) - CGFloat(uiFont.width(s) / 2), y, rgb, shadow: shadow)
}

/// A piece of a texture sheet, drawn at its own size.
func part(_ ctx: CGContext, _ img: CGImage, _ src: CGRect, _ x: CGFloat, _ y: CGFloat) {
    if let cut = img.cropping(to: src) { blit(ctx, cut, CGRect(x: x, y: y, width: src.width, height: src.height)) }
}

func sprite(_ ctx: CGContext, _ path: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat? = nil, _ h: CGFloat? = nil) {
    guard let img = image(path) else { return }
    blit(ctx, img, CGRect(x: x, y: y, width: w ?? CGFloat(img.width), height: h ?? CGFloat(img.height)))
}

/// A sprite with fixed corners and edges, its middle stretched: the game's nine-slice.
func nine(_ ctx: CGContext, _ path: String, _ r: CGRect, _ b: CGFloat) {
    guard let img = image(path) else { return }
    let sw = CGFloat(img.width), sh = CGFloat(img.height)
    let xs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0, b, r.minX, b), (b, sw - 2 * b, r.minX + b, r.width - 2 * b), (sw - b, b, r.maxX - b, b)]
    let ys: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0, b, r.minY, b), (b, sh - 2 * b, r.minY + b, r.height - 2 * b), (sh - b, b, r.maxY - b, b)]
    for (sx, sWide, dx, dWide) in xs where dWide > 0 {
        for (sy, sHigh, dy, dHigh) in ys where dHigh > 0 {
            if let cut = img.cropping(to: CGRect(x: sx, y: sy, width: sWide, height: sHigh)) {
                blit(ctx, cut, CGRect(x: dx, y: dy, width: dWide, height: dHigh))
            }
        }
    }
}

func item(_ ctx: CGContext, _ name: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 16) {
    if let img = image("item/\(name).png") { blit(ctx, img, CGRect(x: x, y: y, width: size, height: size)) }
}

/// What every container and menu draws behind itself.
func dim(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
    let colors = [CGColor(red: 0x10 / 255, green: 0x10 / 255, blue: 0x10 / 255, alpha: 0xC0 / 255),
                  CGColor(red: 0x10 / 255, green: 0x10 / 255, blue: 0x10 / 255, alpha: 0xD0 / 255)] as CFArray
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h), options: [])
    }
}

func wrap(_ s: String, _ width: Int, font: MCFont = uiFont) -> [String] {
    var lines: [String] = [], line = ""
    for word in s.split(separator: " ") {
        let next = line.isEmpty ? String(word) : line + " " + word
        if font.width(next) > width, !line.isEmpty { lines.append(line); line = String(word) } else { line = next }
    }
    if !line.isEmpty { lines.append(line) }
    return lines
}

/// The game's tooltip: near-black with a purple edge, beside the pointer and kept on screen.
func tooltip(_ ctx: CGContext, _ lines: [(String, UInt32)], _ at: CGPoint, _ w: CGFloat, _ h: CGFloat) {
    guard !lines.isEmpty else { return }
    let tw = CGFloat(lines.map { uiFont.width($0.0) }.max() ?? 0)
    let th = CGFloat(8 + (lines.count - 1) * 10 + (lines.count > 1 ? 2 : 0))
    var x = at.x + 12, y = at.y - 12
    if x + tw + 4 > w { x = max(4, at.x - 16 - tw) }
    if y + th + 4 > h { y = h - th - 4 }
    if y < 4 { y = 4 }
    fill(ctx, CGRect(x: x - 3, y: y - 4, width: tw + 6, height: th + 8), 0xF0100010)
    fill(ctx, CGRect(x: x - 4, y: y - 3, width: tw + 8, height: th + 6), 0xF0100010)
    for (r, c) in [(CGRect(x: x - 3, y: y - 3, width: tw + 6, height: 1), UInt32(0x505000FF)), (CGRect(x: x - 3, y: y + th + 2, width: tw + 6, height: 1), 0x5028007F),
                   (CGRect(x: x - 3, y: y - 2, width: 1, height: th + 4), 0x505000FF), (CGRect(x: x + tw + 2, y: y - 2, width: 1, height: th + 4), 0x5028007F)] {
        fill(ctx, r, c)
    }
    var ly = y
    for (i, line) in lines.enumerated() {
        text(ctx, line.0, x, ly, line.1, shadow: true)
        ly += i == 0 ? 12 : 10
    }
}

/// A menu button of any width, cut from the 200-wide sprite. True on the frame it is clicked.
func button(_ ctx: CGContext, _ r: CGRect, _ label: String, enabled: Bool = true) -> Bool {
    let over = enabled && pointer.map(r.contains) == true
    if let img = image(!enabled ? "button_disabled.png" : over ? "button_highlighted.png" : "button.png") {
        let half = (r.width / 2).rounded(.down)
        if let left = img.cropping(to: CGRect(x: 0, y: 0, width: half, height: 20)) { blit(ctx, left, CGRect(x: r.minX, y: r.minY, width: half, height: 20)) }
        if let right = img.cropping(to: CGRect(x: 200 - (r.width - half), y: 0, width: r.width - half, height: 20)) {
            blit(ctx, right, CGRect(x: r.minX + half, y: r.minY, width: r.width - half, height: 20))
        }
    }
    centered(ctx, label, r.midX, r.minY + 6, enabled ? 0xFFFFFF : 0xA0A0A0)
    if over, let p = pressed, r.contains(p) { playSound("click", volume: 0.12); return true }
    return false
}

func emit(_ value: Any) {
    emitted = value
    if let data = try? JSONSerialization.data(withJSONObject: value), let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
}

func spec(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}

/// What a screen does once it has drawn a frame.
func endFrame() { pressed = nil; released = false; keys = []; scrolled = 0; scrolledX = 0 }

// MARK: advancements

/// A new advancement's mark: a five-pixel star in the game's yellow, outlined so it reads on any background.
func sparkle(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat) {
    let star = [(2, 0), (1, 1), (2, 1), (3, 1), (0, 2), (1, 2), (2, 2), (3, 2), (4, 2), (1, 3), (2, 3), (3, 3), (2, 4)]
    let dot = { (dx: Int, dy: Int, argb: UInt32) in fill(ctx, CGRect(x: x + CGFloat(dx), y: y + CGFloat(dy), width: 1, height: 1), argb) }
    for (dx, dy) in star { for (ox, oy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] { dot(dx + ox, dy + oy, 0xFF3F3F00) } }
    for (dx, dy) in star { dot(dx, dy, 0xFFFFFF55) }
    dot(2, 2, 0xFFFFFFFF)
}

/// "Oct 26, 2026", in this Mac's own time.
let earnedDate: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "MMM d, yyyy"
    return f
}()

final class AdvancementsScene: Scene {
    struct Node {
        let id: String, parent: String?, name: String, frame: String, icon: String, desc: String
        let earned: Bool, progress: String?, part: CGFloat
        let at: Double?, fresh: Bool      // when it was earned (ms), and whether since the tree was last opened
        var x: CGFloat = 0, y: CGFloat = 0
    }
    struct Tab { let name: String, bg: String, icon: String; var nodes: [Node]; var sx: CGFloat = 0, sy: CGFloat = 0; var minX: CGFloat = 0, maxX: CGFloat = 0, minY: CGFloat = 0, maxY: CGFloat = 0 }
    var tabs: [Tab] = []
    var selected = 0
    var dragging = false
    var last: CGPoint? = nil
    var fade: CGFloat = 0
    var laidOut = false
    var finished = false

    /// The game's window is 252 by 140, too small for these trees, so its frame
    /// is stretched: the corners and edges keep their size and the middle grows.
    func frame(_ ctx: CGContext, _ sheet: CGImage, _ r: CGRect) {
        let xs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0, 9, r.minX, 9), (9, 234, r.minX + 9, r.width - 18), (243, 9, r.maxX - 9, 9)]
        let ys: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0, 18, r.minY, 18), (18, 113, r.minY + 18, r.height - 27), (131, 9, r.maxY - 9, 9)]
        for (sx, sw, dx, dw) in xs {
            for (sy, sh, dy, dh) in ys where !(sx == 9 && sy == 18) {
                if let cut = sheet.cropping(to: CGRect(x: sx, y: sy, width: sw, height: sh)) { blit(ctx, cut, CGRect(x: dx, y: dy, width: dw, height: dh)) }
            }
        }
    }

    init(_ json: String) {
        let data = spec(json)
        selected = data["open"] as? Int ?? 0
        for raw in data["tabs"] as? [[String: Any]] ?? [] {
            var nodes = (raw["items"] as? [[String: Any]] ?? []).map {
                Node(id: $0["id"] as? String ?? "", parent: $0["parent"] as? String, name: clean($0["name"] as? String ?? ""), frame: $0["frame"] as? String ?? "task",
                     icon: $0["icon"] as? String ?? "", desc: clean($0["desc"] as? String ?? ""), earned: $0["earned"] as? Bool ?? false,
                     progress: $0["progress"] as? String, part: CGFloat($0["part"] as? Double ?? 0),
                     at: $0["at"] as? Double, fresh: $0["fresh"] as? Bool ?? false)
            }
            // A tidy tree, root at the left: each depth is a column, each leaf a row.
            var row: CGFloat = 0
            func place(_ i: Int, _ depth: CGFloat) -> CGFloat {
                let kids = nodes.indices.filter { nodes[$0].parent == nodes[i].id }
                nodes[i].x = depth * 28
                if kids.isEmpty { nodes[i].y = row * 27; row += 1 } else {
                    let ys = kids.map { place($0, depth + 1) }
                    nodes[i].y = ((ys.first! + ys.last!) / 2).rounded()
                }
                return nodes[i].y
            }
            for i in nodes.indices where nodes[i].parent == nil || !nodes.contains(where: { $0.id == nodes[i].parent }) { _ = place(i, 0) }
            var tab = Tab(name: raw["name"] as? String ?? "", bg: raw["bg"] as? String ?? "stone", icon: raw["icon"] as? String ?? "", nodes: nodes)
            tab.minX = nodes.map(\.x).min() ?? 0; tab.maxX = (nodes.map(\.x).max() ?? 0) + 28
            tab.minY = nodes.map(\.y).min() ?? 0; tab.maxY = (nodes.map(\.y).max() ?? 0) + 27
            tabs.append(tab)
        }
        selected = min(max(0, selected), max(0, tabs.count - 1))
    }

    func draw(_ ctx: CGContext, t: Double, w: CGFloat, h: CGFloat) {
        dim(ctx, w, h)
        guard !tabs.isEmpty, let sheet = image("gui/advancements/window.png") else { finished = true; return }
        let W = min(400, w - 40).rounded(.down), H = min(236, h - 80).rounded(.down)
        let L = ((w - W) / 2).rounded(.down), T = ((h - H) / 2).rounded(.down) + 10
        let inner = CGRect(x: L + 9, y: T + 18, width: W - 18, height: H - 27)
        let IW = inner.width, IH = inner.height
        if !laidOut {
            laidOut = true
            // Centred when it fits; otherwise the root starts in view at the left.
            for i in tabs.indices {
                let tab = tabs[i]
                tabs[i].sx = tab.maxX - tab.minX > IW ? 0 : ((IW - (tab.maxX + tab.minX)) / 2).rounded()
                let rootY = tab.nodes.first?.y ?? 0
                tabs[i].sy = tab.maxY - tab.minY > IH ? min(0, max(-(tab.maxY - IH), (IH / 2 - rootY - 13).rounded())) : ((IH - (tab.maxY + tab.minY)) / 2).rounded()
            }
        }

        // Tabs first, so a press on one changes what is drawn this frame.
        for i in tabs.indices {
            let r = CGRect(x: L + CGFloat(32 * i), y: T - 28, width: 28, height: 32)
            if let p = pressed, r.contains(p), i != selected { selected = i; playSound("click", volume: 0.12) }
        }
        if let p = pressed, inner.contains(p) { dragging = true; last = p }
        if !held { dragging = false }
        // Dragged, or scrolled with the wheel or a trackpad: the tree moves with the hand, up to its edges.
        var dx: CGFloat = 0, dy: CGFloat = 0
        if dragging, let p = pointer, let from = last { dx = p.x - from.x; dy = p.y - from.y; last = p }
        if !dragging, let p = pointer, inner.contains(p) { dx += scrolledX * 0.5; dy += scrolled * 0.5 }
        if dx != 0 || dy != 0 {
            var tab = tabs[selected]
            if tab.maxX - tab.minX > IW { tab.sx = min(0, max(-(tab.maxX - IW), tab.sx + dx)) }
            if tab.maxY - tab.minY > IH { tab.sy = min(0, max(-(tab.maxY - IH), tab.sy + dy)) }
            tabs[selected] = tab
        }
        let tab = tabs[selected]
        let ox = inner.minX + tab.sx.rounded(), oy = inner.minY + tab.sy.rounded()

        ctx.saveGState()
        ctx.clip(to: inner)
        if let bg = image("gui/advancements/backgrounds/\(tab.bg).png") {
            let px = tab.sx.rounded().truncatingRemainder(dividingBy: 16), py = tab.sy.rounded().truncatingRemainder(dividingBy: 16)
            for tx in -1...Int(IW / 16) + 1 { for ty in -1...Int(IH / 16) + 1 { blit(ctx, bg, CGRect(x: inner.minX + px + CGFloat(tx * 16), y: inner.minY + py + CGFloat(ty * 16), width: 16, height: 16)) } }
        }
        // AdvancementWidget.drawConnectivity: a black outline, then the white line over it.
        for shadow in [true, false] {
            for node in tab.nodes {
                guard let parent = tab.nodes.first(where: { $0.id == node.parent }) else { continue }
                let i = ox + parent.x + 13, j = ox + parent.x + 30, k = oy + parent.y + 13, l = ox + node.x + 13, m = oy + node.y + 13
                let c: UInt32 = shadow ? 0xFF000000 : 0xFFFFFFFF
                let hLine = { (a: CGFloat, b: CGFloat, y: CGFloat) in fill(ctx, CGRect(x: min(a, b), y: y, width: abs(b - a) + 1, height: 1), c) }
                let vLine = { (x: CGFloat, a: CGFloat, b: CGFloat) in fill(ctx, CGRect(x: x, y: min(a, b), width: 1, height: abs(b - a) + 1), c) }
                if shadow {
                    hLine(j, i, k - 1); hLine(j + 1, i, k); hLine(j, i, k + 1)
                    hLine(l, j - 1, m - 1); hLine(l, j - 1, m); hLine(l, j - 1, m + 1)
                    vLine(j - 1, m, k); vLine(j + 1, m, k)
                } else { hLine(j, i, k); hLine(l, j, m); vLine(j, m, k) }
            }
        }
        var hovered: Node? = nil
        for node in tab.nodes {
            let fx = ox + node.x + 3, fy = oy + node.y
            sprite(ctx, "gui/sprites/advancements/\(node.frame)_frame_\(node.earned ? "obtained" : "unobtained").png", fx, fy)
            item(ctx, node.icon, fx + 5, fy + 5)
            if node.fresh { sparkle(ctx, fx + 19, fy) }
            if !dragging, let p = pointer, inner.contains(p), CGRect(x: fx, y: fy, width: 26, height: 26).contains(p) { hovered = node }
        }
        fade = hovered == nil ? max(0, fade - 0.04) : min(0.3, fade + 0.02)
        if fade > 0 { fill(ctx, inner, UInt32(fade * 255) << 24) }
        ctx.restoreGState()

        frame(ctx, sheet, CGRect(x: L, y: T, width: W, height: H))
        text(ctx, "Advancements", L + 8, T + 6, 0x404040)
        var tabTip: String? = nil
        for i in tabs.indices {
            let x = L + CGFloat(32 * i), y = T - 28
            let side = i == 0 ? "left" : "middle"
            sprite(ctx, "gui/sprites/advancements/tab_above_\(side)\(i == selected ? "_selected" : "").png", x, y)
            item(ctx, tabs[i].icon, x + 6, y + 9)
            if tabs[i].nodes.contains(where: \.fresh) { sparkle(ctx, x + 20, y + 3) }
            if let p = pointer, CGRect(x: x, y: y, width: 28, height: 28).contains(p) { tabTip = tabs[i].name }
        }

        if let node = hovered {
            // The title bar with the frame over its left end, the description hanging beneath.
            // Under the description, when it was earned; at the title's right, how far along, or that it is new.
            var lines = wrap(node.desc, 163).map { ($0, UInt32(node.earned ? 0x55FF55 : 0xAAAAAA)) }
            if let at = node.at { lines.append(("Earned \(earnedDate.string(from: Date(timeIntervalSince1970: at / 1000)))", 0x808080)) }
            let tag = node.progress ?? (node.fresh ? "New!" : nil)
            let titleW = uiFont.width(node.name) + (tag.map { uiFont.width($0) + 8 } ?? 0)
            let bw = CGFloat(max(titleW, lines.map { uiFont.width($0.0) }.max() ?? 0) + 37)
            var bx = ox + node.x
            let by = oy + node.y
            if bx + bw > w - 4 { bx = w - 4 - bw }
            nine(ctx, "gui/sprites/advancements/title_box.png", CGRect(x: bx, y: by, width: bw, height: CGFloat(32 + lines.count * 9)), 10)
            let done = node.earned ? bw : (bw * node.part).rounded()
            for (name, clip) in [("box_obtained", CGRect(x: bx, y: by, width: done, height: 26)), ("box_unobtained", CGRect(x: bx + done, y: by, width: bw - done, height: 26))] where clip.width > 0 {
                ctx.saveGState(); ctx.clip(to: clip)
                nine(ctx, "gui/sprites/advancements/\(name).png", CGRect(x: bx, y: by, width: bw, height: 26), 10)
                ctx.restoreGState()
            }
            text(ctx, node.name, bx + 32, by + 9, 0xFFFFFF, shadow: true)
            if let tag { text(ctx, tag, bx + bw - CGFloat(uiFont.width(tag)) - 5, by + 9, node.progress == nil ? 0xFFFF55 : 0xFFFFFF, shadow: true) }
            for (i, line) in lines.enumerated() { text(ctx, line.0, bx + 5, by + 26 + CGFloat(i * 9), line.1) }
            sprite(ctx, "gui/sprites/advancements/\(node.frame)_frame_\(node.earned ? "obtained" : "unobtained").png", ox + node.x + 3, by)
            item(ctx, node.icon, ox + node.x + 8, by + 5)
        } else if let tip = tabTip, let p = pointer { tooltip(ctx, [(tip, 0xFFFFFF)], p, w, h) }

        let window = CGRect(x: L, y: T - 28, width: W, height: H + 28)
        if keys.contains(53) || keys.contains(37) || (pressed.map { !window.contains($0) } ?? false) || t > 590 { finished = true }
        endFrame()
    }
}

// MARK: containers

/// A slot in a container window, and whether the pointer is over it.
struct Slot { let x: CGFloat, y: CGFloat }
func over(_ s: Slot, _ L: CGFloat, _ T: CGFloat) -> Bool {
    pointer.map { CGRect(x: L + s.x - 1, y: T + s.y - 1, width: 18, height: 18).contains($0) } == true
}

// MARK: options

/// A slider the width of `r`, 0 to 1 in steps of 5%, its label drawn over it.
func slider(_ ctx: CGContext, _ r: CGRect, _ value: inout Double, _ dragging: inout Bool, _ label: String) -> Bool {
    let before = value
    if let p = pressed, r.contains(p) { dragging = true }
    if !held { dragging = false }
    if dragging, let p = pointer { value = (Double(min(1, max(0, (p.x - r.minX - 4) / (r.width - 8)))) * 20).rounded() / 20 }
    nine(ctx, "gui/sprites/widget/slider.png", r, 3)
    sprite(ctx, "gui/sprites/widget/slider_handle\(dragging || pointer.map(r.contains) == true ? "_highlighted" : "").png", r.minX + CGFloat(value) * (r.width - 8), r.minY)
    centered(ctx, label, r.midX, r.minY + 6, 0xFFFFFF)
    return value != before
}

/// OptionsScreen, with Music & Sounds and Accessibility behind their own buttons as in the game.
final class OptionsScene: Scene {
    static let kinds: [(String, String)] = [("damage", "Damage"), ("eating", "Eating"), ("orbs", "XP Orbs"), ("xp", "Level Up"), ("advancements", "Advancements"),
                                           ("totem", "Totem"), ("villager", "Villager"), ("clicks", "Clicks")]
    static let motions: [(String, String)] = [("flash", "Damage Flash"), ("shake", "Low Health Shake"), ("hunger", "Hunger Shake"),
                                             ("regen", "Regeneration"), ("apple", "Eating Animation"), ("nowplaying", "Now Playing Text")]
    var volume: Double, music = jukeboxVolume, fullscreen: Bool, hotbar: Bool
    var muted: Set<String>, still: Set<String>
    let level: Int
    var page = "main"
    var resetXp = false
    var confirming = false
    var sliding = false, slidingMusic = false
    var closingAt: Double? = nil
    var finished = false

    init(_ json: String) {
        let data = spec(json)
        let on = data["sounds"] as? Bool ?? true
        volume = on ? data["volume"] as? Double ?? 1 : 0
        fullscreen = data["fullscreen"] as? Bool ?? true
        hotbar = data["hotbar"] as? Bool ?? true
        muted = Set(data["muted"] as? [String] ?? [])
        still = Set(data["still"] as? [String] ?? [])
        level = data["level"] as? Int ?? 0
    }

    func done(_ t: Double) {
        guard closingAt == nil else { return }
        emit(["sounds": volume > 0, "volume": volume, "fullscreen": fullscreen, "hotbar": hotbar, "resetXp": resetXp,
              "muted": muted.sorted(), "still": still.sorted()])
        closingAt = t
    }

    /// Two columns of ON/OFF buttons, one per entry, toggling membership of `set` (in the set means OFF).
    func toggles(_ ctx: CGContext, _ entries: [(String, String)], _ set: inout Set<String>, _ top: CGFloat, _ cx: CGFloat) {
        for (i, (key, name)) in entries.enumerated() {
            let x = i % 2 == 0 ? cx - 155 : cx + 5, y = top + CGFloat(24 * (i / 2))
            if button(ctx, CGRect(x: x, y: y, width: 150, height: 20), "\(name): \(set.contains(key) ? "OFF" : "ON")") {
                if set.contains(key) { set.remove(key) } else { set.insert(key) }
            }
        }
    }

    func draw(_ ctx: CGContext, t: Double, w: CGFloat, h: CGFloat) {
        dim(ctx, w, h)
        let cx = (w / 2).rounded(.down), top = (h / 6).rounded(.down)
        let back = keys.contains(53) || keys.contains(36)
        switch page {
        case "sounds":
            centered(ctx, "Music & Sounds", cx, top - 8, 0xFFFFFF)
            _ = slider(ctx, CGRect(x: cx - 155, y: top + 24, width: 310, height: 20), &volume, &sliding, volume > 0 ? "Master Volume: \(Int((volume * 100).rounded()))%" : "Master Volume: OFF")
            if slider(ctx, CGRect(x: cx - 155, y: top + 48, width: 310, height: 20), &music, &slidingMusic, music > 0 ? "Jukebox: \(Int((music * 100).rounded()))%" : "Jukebox: OFF") {
                jukeboxVolume = music
                if playerRunning() { tellPlayer(["cmd": "volume", "volume": music]) }
            }
            toggles(ctx, OptionsScene.kinds, &muted, top + 80, cx)
            if button(ctx, CGRect(x: cx - 100, y: top + CGFloat(88 + 24 * ((OptionsScene.kinds.count + 1) / 2)), width: 200, height: 20), "Done") || back { page = "main" }
        case "motion":
            centered(ctx, "Accessibility Settings", cx, top - 8, 0xFFFFFF)
            toggles(ctx, OptionsScene.motions, &still, top + 24, cx)
            centered(ctx, "Turned off, the HUD stays still for that moment.", cx, top + 104, 0xA0A0A0)
            if button(ctx, CGRect(x: cx - 100, y: top + 136, width: 200, height: 20), "Done") || back { page = "main" }
        default:
            centered(ctx, "Minecraft HUD Options", cx, top - 8, 0xFFFFFF)
            if button(ctx, CGRect(x: cx - 155, y: top + 24, width: 150, height: 20), "Music & Sounds...") { page = "sounds" }
            if button(ctx, CGRect(x: cx + 5, y: top + 24, width: 150, height: 20), "Accessibility...") { page = "motion" }
            if button(ctx, CGRect(x: cx - 155, y: top + 48, width: 150, height: 20), "Full-Screen Moments: \(fullscreen ? "ON" : "OFF")") { fullscreen.toggle() }
            if button(ctx, CGRect(x: cx + 5, y: top + 48, width: 150, height: 20), "Hotbar: \(hotbar ? "ON" : "OFF")") { hotbar.toggle() }
            // The hotbar is how this screen is opened: with it hidden, the way back has to be said.
            if !hotbar { centered(ctx, "Hidden. Type /minecraft hotbar on to bring it back.", cx, top + 100, 0xA0A0A0, shadow: false) }
            let label = resetXp ? "Level will reset to 0" : confirming ? "Click again to reset level \(level)" : "Reset XP Level..."
            if button(ctx, CGRect(x: cx - 155, y: top + 72, width: 310, height: 20), label, enabled: !resetXp) {
                if confirming { resetXp = true } else { confirming = true }
            }
            if button(ctx, CGRect(x: cx - 100, y: top + 120, width: 200, height: 20), "Done") || back { done(t) }
        }
        if let at = closingAt, t - at > 0.25 { finished = true }
        if t > 590 { finished = true }
        endFrame()
    }
}

// MARK: the guide

/// What everything means, shown once on the first run and again with /minecraft help:
/// four short pages, one idea each (welcome, the bars, the hotbar, the big
/// moments), turned with Back and Next or the arrow keys.
final class GuideScene: Scene {
    static let pages = 4
    var page = 0
    var closingAt: Double? = nil
    var finished = false

    init(_ json: String) {}

    /// The bars at the game's own size: seven and a half hearts, six and a half drumsticks, a level.
    func hud(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat) {
        for i in 0..<10 {
            sprite(ctx, "gui/sprites/hud/heart/container.png", x + CGFloat(i * 8), y)
            sprite(ctx, i < 7 ? "gui/sprites/hud/heart/full.png" : i == 7 ? "gui/sprites/hud/heart/half.png" : "", x + CGFloat(i * 8), y)
            let fx = x + 182 - 9 - CGFloat(i * 8)
            sprite(ctx, "gui/sprites/hud/food_empty.png", fx, y)
            if i < 6 { sprite(ctx, "gui/sprites/hud/food_full.png", fx, y) } else if i == 6 { sprite(ctx, "gui/sprites/hud/food_half.png", fx, y) }
        }
        sprite(ctx, "gui/sprites/hud/experience_bar_background.png", x, y + 12)
        if let fill = image("gui/sprites/hud/experience_bar_progress.png"), let cut = fill.cropping(to: CGRect(x: 0, y: 0, width: 113, height: 5)) {
            blit(ctx, cut, CGRect(x: x, y: y + 12, width: 113, height: 5))
        }
        let level = "11", lx = x + 91 - CGFloat(uiFont.width(level) / 2)
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] { text(ctx, level, lx + CGFloat(dx), y + 5 + CGFloat(dy), 0x000000) }
        text(ctx, level, lx, y + 5, 0x80FF20)
    }

    static let slots: [(String, String)] = [("knowledge_book", "Advancements"), ("jukebox", "Jukebox"), ("parrot_spawn_egg", "Parrot"), ("comparator", "Settings")]

    func draw(_ ctx: CGContext, t: Double, w: CGFloat, h: CGFloat) {
        dim(ctx, w, h)
        let cx = (w / 2).rounded(.down), mid = (h / 2).rounded(.down) - 16
        var tip: String? = nil

        switch page {
        case 0:
            ctx.saveGState(); ctx.translateBy(x: cx - 24, y: mid - 56); ctx.scaleBy(x: 3, y: 3); item(ctx, "grass_block", 0, 0); ctx.restoreGState()
            centered(ctx, "Minecraft Claude Code Mod", cx, mid + 4, 0xFFFFFF)
            centered(ctx, "Here is what's on your screen.", cx, mid + 18, 0xA0A0A0, shadow: false)
        case 1:
            centered(ctx, "Your bars", cx, mid - 52, 0xFFFFFF)
            let bx = cx - 182
            ctx.saveGState(); ctx.translateBy(x: bx, y: mid - 20); ctx.scaleBy(x: 2, y: 2); hud(ctx, 0, 0); ctx.restoreGState()
            text(ctx, "Hearts: your usage limit", bx, mid - 32, 0xFF5555, shadow: true)
            let food = "Hunger: your context"
            text(ctx, food, bx + 364 - CGFloat(uiFont.width(food)), mid - 32, 0xFFAA00, shadow: true)
            centered(ctx, "XP: the tokens you use", cx, mid + 24, 0x80FF20)
        case 2:
            centered(ctx, "The hotbar", cx, mid - 52, 0xFFFFFF)
            let n = GuideScene.slots.count, bw = CGFloat(20 * n + 2), hx = cx - bw, hy = mid - 30
            ctx.saveGState(); ctx.translateBy(x: hx, y: hy); ctx.scaleBy(x: 2, y: 2)
            if let bar = image("gui/sprites/hud/hotbar.png") {
                if let a = bar.cropping(to: CGRect(x: 0, y: 0, width: bw - 1, height: 22)) { blit(ctx, a, CGRect(x: 0, y: 0, width: bw - 1, height: 22)) }
                if let b = bar.cropping(to: CGRect(x: 181, y: 0, width: 1, height: 22)) { blit(ctx, b, CGRect(x: bw - 1, y: 0, width: 1, height: 22)) }
            }
            for (i, slot) in GuideScene.slots.enumerated() { item(ctx, slot.0, CGFloat(3 + 20 * i), 3) }
            ctx.restoreGState()
            if let p = pointer {
                for i in 0..<n where CGRect(x: hx + CGFloat(2 + 40 * i), y: hy + 2, width: 40, height: 40).contains(p) { tip = GuideScene.slots[i].1 }
            }
            centered(ctx, "Click a slot to open it.", cx, hy + 56, 0xFFFFFF, shadow: false)
            centered(ctx, "Or type /minecraft and its name.", cx, hy + 68, 0xA0A0A0, shadow: false)
        default:
            centered(ctx, "When something big happens", cx, mid - 52, 0xFFFFFF)
            let moments: [(String, String)] = [("bone", "You hit your limit"), ("totem_of_undying", "Your week resets"), ("golden_apple", "You compact a chat")]
            for (i, m) in moments.enumerated() {
                let x = cx + CGFloat(i - 1) * 120
                item(ctx, m.0, x - 16, mid - 28, size: 32)
                centered(ctx, m.1, x, mid + 12, 0xFFFFFF, shadow: false)
            }
        }

        // Back, where the page is, Next (or Let's Go on the last page).
        let last = page == GuideScene.pages - 1
        let by = h - 46
        let next = button(ctx, CGRect(x: cx + 30, y: by, width: 100, height: 20), last ? "Let's Go" : "Next")
            || keys.contains(124) || keys.contains(36)
        let back = button(ctx, CGRect(x: cx - 130, y: by, width: 100, height: 20), "Back", enabled: page > 0) || keys.contains(123)
        centered(ctx, "\(page + 1) / \(GuideScene.pages)", cx, by + 6, 0xA0A0A0, shadow: false)
        if next { if last { if closingAt == nil { closingAt = t } } else { page += 1 } }
        else if back, page > 0 { page -= 1 }
        if keys.contains(53), closingAt == nil { closingAt = t }
        centered(ctx, "Type /minecraft help to see this again.", cx, h - 20, 0x707070, shadow: false)
        if let tip, let p = pointer { tooltip(ctx, [(tip, 0xFFFFFF)], p, w, h) }

        if let at = closingAt, t - at > 0.25 { finished = true }
        if t > 590 { finished = true }
        endFrame()
    }
}

// MARK: the README's hero

/// The README's first picture alone (mode "hero", MC_GUI_SCALE=1): Claude Code's
/// prompt area drawn from scratch, large: the HUD in its band above the input,
/// so the HUD reads at the README's width. The HUD at 6 pixels to the GUI pixel and
/// the hotbar at 5, whole numbers so every edge is crisp.
final class HeroScene: Scene {
    let finished = true
    init(_ json: String) {}

    func label(_ ctx: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular, right: Bool = false) {
        let string = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        string.draw(at: NSPoint(x: right ? x - string.size().width : x, y: y))
        NSGraphicsContext.restoreGraphicsState()
    }

    func symbol(_ ctx: CGContext, _ name: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .regular)) else { return }
        let tinted = NSImage(size: base.size, flipped: false) { rect in base.draw(in: rect); color.set(); rect.fill(using: .sourceAtop); return true }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        tinted.draw(in: NSRect(x: x, y: y, width: base.size.width, height: base.size.height))
        NSGraphicsContext.restoreGraphicsState()
    }

    func rounded(_ ctx: CGContext, _ r: CGRect, _ radius: CGFloat, fill: UInt32, stroke: UInt32? = nil) {
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let c = { (v: UInt32) in CGColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1) }
        ctx.addPath(path); ctx.setFillColor(c(fill)); ctx.fillPath()
        if let stroke { ctx.addPath(path); ctx.setStrokeColor(c(stroke)); ctx.setLineWidth(2); ctx.strokePath() }
    }

    func draw(_ ctx: CGContext, t: Double, w: CGFloat, h: CGFloat) {
        fill(ctx, CGRect(x: 0, y: 0, width: w, height: h), 0xFFFFFFFF)
        let left: CGFloat = 160, width = w - 2 * left
        let grey = NSColor(white: 0.45, alpha: 1), faint = NSColor(white: 0.62, alpha: 1)

        // The band: its grey panel, the HUD at the left, the hotbar at the right.
        let k: CGFloat = 6, hk: CGFloat = 5, pad: CGFloat = 26
        let slots = ["knowledge_book", "jukebox", "parrot_spawn_egg", "comparator"]
        let barW = CGFloat(20 * slots.count + 2)
        let panel = CGRect(x: left, y: 40, width: width, height: 22 * hk + 2 * pad)
        rounded(ctx, panel, 34, fill: 0xF2F2F1)
        let g = ((width - 2 * pad - barW * hk - 24) / k).rounded(.down)
        ctx.saveGState(); ctx.translateBy(x: left + pad, y: panel.maxY - pad - 18 * k); ctx.scaleBy(x: k, y: k)
        for i in 0..<10 {
            sprite(ctx, "gui/sprites/hud/heart/container.png", CGFloat(i * 8), 2)
            if i < 7 { sprite(ctx, "gui/sprites/hud/heart/full.png", CGFloat(i * 8), 2) } else if i == 7 { sprite(ctx, "gui/sprites/hud/heart/half.png", CGFloat(i * 8), 2) }
            let fx = g - 9 - CGFloat(i * 8)
            sprite(ctx, "gui/sprites/hud/food_empty.png", fx, 2)
            if i < 6 { sprite(ctx, "gui/sprites/hud/food_full.png", fx, 2) } else if i == 6 { sprite(ctx, "gui/sprites/hud/food_half.png", fx, 2) }
        }
        for (name, clip) in [("experience_bar_background", g), ("experience_bar_progress", (g * 0.62).rounded())] {
            guard let bar = image("gui/sprites/hud/\(name).png") else { continue }
            ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 12, width: clip, height: 5))
            let n = Int(((g - 2) / 10).rounded(.up))
            if let cap = bar.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 5)) { blit(ctx, cap, CGRect(x: 0, y: 12, width: 1, height: 5)) }
            for i in 0..<n {
                let from = 1 + 10 * (i == n - 1 ? 17 : i % 17)
                if let piece = bar.cropping(to: CGRect(x: from, y: 0, width: 10, height: 5)) { blit(ctx, piece, CGRect(x: 1 + CGFloat(i * 10), y: 12, width: 10, height: 5)) }
            }
            if let cap = bar.cropping(to: CGRect(x: 181, y: 0, width: 1, height: 5)) { blit(ctx, cap, CGRect(x: g - 1, y: 12, width: 1, height: 5)) }
            ctx.restoreGState()
        }
        let level = "57", lx = ((g - CGFloat(uiFont.width(level))) / 2).rounded(.down)
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] { text(ctx, level, lx + CGFloat(dx), 6 + CGFloat(dy), 0x000000) }
        text(ctx, level, lx, 6, 0x80FF20)
        ctx.restoreGState()
        ctx.saveGState(); ctx.translateBy(x: panel.maxX - pad - barW * hk, y: panel.maxY - pad - 22 * hk); ctx.scaleBy(x: hk, y: hk)
        if let bar = image("gui/sprites/hud/hotbar.png") {
            if let a = bar.cropping(to: CGRect(x: 0, y: 0, width: barW - 1, height: 22)) { blit(ctx, a, CGRect(x: 0, y: 0, width: barW - 1, height: 22)) }
            if let b = bar.cropping(to: CGRect(x: 181, y: 0, width: 1, height: 22)) { blit(ctx, b, CGRect(x: barW - 1, y: 0, width: 1, height: 22)) }
        }
        for (i, icon) in slots.enumerated() { item(ctx, icon, CGFloat(3 + 20 * i), 3) }
        ctx.restoreGState()

        // The prompt input under it, and the mode and model under that.
        let input = CGRect(x: left, y: panel.maxY + 22, width: width, height: 120)
        rounded(ctx, input, 36, fill: 0xFFFFFF, stroke: 0xE1E1E0)
        symbol(ctx, "plus", input.minX + 34, input.midY - 20, 34, grey)
        label(ctx, "Type / for commands", input.minX + 100, input.midY - 24, size: 36, color: faint)
        symbol(ctx, "mic", input.maxX - 74, input.midY - 24, 34, grey)
        label(ctx, "Auto", input.minX + 40, input.maxY + 26, size: 30, color: grey)
        label(ctx, "Opus 5.5   High", input.maxX - 40, input.maxY + 26, size: 30, color: grey, right: true)
    }
}
