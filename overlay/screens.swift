// The screens that take over the display until they are closed: advancements,
// the crafting table, the enchanting table and options. Each reads one JSON
// argument, and the ones that decide something print one JSON line as they close.
//
//   MCOverlay <assetsDir> advancements <json>
//   MCOverlay <assetsDir> enchant <json>
//   MCOverlay <assetsDir> options <json>
//
// Layouts and colors follow Minecraft 1.21's AdvancementsScreen, CraftingScreen,
// EnchantmentScreen and OptionsScreen.

import AppKit

// MARK: input, set by the view each event and cleared after every frame

var keys: [UInt16] = []
var held = false
var released = false
var scrolled: CGFloat = 0      // points scrolled since the last frame, up positive

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
    if over, let p = pressed, r.contains(p) { playSound("click", volume: 0.25); return true }
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
func endFrame() { pressed = nil; released = false; keys = []; scrolled = 0 }

// MARK: advancements

final class AdvancementsScene: Scene {
    struct Node {
        let id: String, parent: String?, name: String, frame: String, icon: String, desc: String
        let earned: Bool, progress: String?, part: CGFloat
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
                     progress: $0["progress"] as? String, part: CGFloat($0["part"] as? Double ?? 0))
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
            if let p = pressed, r.contains(p), i != selected { selected = i; playSound("click", volume: 0.25) }
        }
        if let p = pressed, inner.contains(p) { dragging = true; last = p }
        if !held { dragging = false }
        if dragging, let p = pointer, let from = last {
            var tab = tabs[selected]
            if tab.maxX - tab.minX > IW { tab.sx = min(0, max(-(tab.maxX - IW), tab.sx + p.x - from.x)) }
            if tab.maxY - tab.minY > IH { tab.sy = min(0, max(-(tab.maxY - IH), tab.sy + p.y - from.y)) }
            tabs[selected] = tab
            last = p
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
            if let p = pointer, CGRect(x: x, y: y, width: 28, height: 28).contains(p) { tabTip = tabs[i].name }
        }

        if let node = hovered {
            // The title bar with the frame over its left end, the description hanging beneath.
            let lines = wrap(node.desc, 163)
            let titleW = uiFont.width(node.name) + (node.progress.map { uiFont.width($0) + 8 } ?? 0)
            let bw = CGFloat(max(titleW, lines.map { uiFont.width($0) }.max() ?? 0) + 37)
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
            if let progress = node.progress { text(ctx, progress, bx + bw - CGFloat(uiFont.width(progress)) - 5, by + 9, 0xFFFFFF, shadow: true) }
            for (i, line) in lines.enumerated() { text(ctx, line, bx + 5, by + 26 + CGFloat(i * 9), node.earned ? 0x55FF55 : 0xAAAAAA) }
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

final class EnchantScene: Scene {
    struct Option { let name: String, desc: String, need: Int, words: String }
    let draft: String
    let level: Int
    let options: [Option]
    let sga = MCFont(loadImage("font/ascii_sga.png")!)
    var closingAt: Double? = nil
    var finished = false

    init(_ json: String) {
        let data = spec(json)
        draft = clean(data["draft"] as? String ?? "")
        level = data["level"] as? Int ?? 0
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        options = (data["options"] as? [[String: Any]] ?? []).prefix(3).map {
            let words = (0..<4).map { _ in String((0..<Int.random(in: 3...6)).map { _ in letters.randomElement()! }) }.joined(separator: " ")
            return Option(name: clean($0["name"] as? String ?? ""), desc: clean($0["desc"] as? String ?? ""), need: $0["need"] as? Int ?? 1, words: words)
        }
    }

    func draw(_ ctx: CGContext, t: Double, w: CGFloat, h: CGFloat) {
        dim(ctx, w, h)
        guard let sheet = image("gui/container/enchanting_table.png") else { finished = true; return }
        let L = ((w - 176) / 2).rounded(.down), T = ((h - 166) / 2).rounded(.down)
        part(ctx, sheet, CGRect(x: 0, y: 0, width: 176, height: 166), L, T)
        text(ctx, "Enchant", L + 12, T + 5, 0x404040)
        text(ctx, "Inventory", L + 8, T + 72, 0x404040)
        item(ctx, "enchanted_book", L + 17, T + 12, size: 32)

        var tip: [(String, UInt32)] = []
        let paper = Slot(x: 15, y: 47), lapis = Slot(x: 35, y: 47)
        // With nothing to enchant the slot holds a faint paper, as the game's empty slots hint at what goes in them.
        let empty = draft.isEmpty
        ctx.saveGState(); if empty { ctx.setAlpha(0.3) }
        item(ctx, "paper", L + paper.x, T + paper.y)
        ctx.restoreGState()
        item(ctx, "lapis_lazuli", L + lapis.x, T + lapis.y)
        text(ctx, "3", L + lapis.x + 11, T + lapis.y + 9, 0xFFFFFF, shadow: true)
        let nothing: [(String, UInt32)] = [("Nothing to enchant", 0xFFFFFF)] + wrap("Type a prompt in the message box, then open the table again.", 200).map { ($0, UInt32(0xAAAAAA)) }
        if over(paper, L, T) {
            fill(ctx, CGRect(x: L + paper.x, y: T + paper.y, width: 16, height: 16), 0x80FFFFFF)
            tip = empty ? nothing : [("Your prompt", 0xFFFFFF)] + wrap(draft, 220).prefix(8).map { ($0, UInt32(0xAAAAAA)) }
        }
        // EnchantmentScreen with no item: three blank, disabled rows.
        if empty {
            for i in 0..<3 {
                let box = CGRect(x: L + 60, y: T + 14 + CGFloat(19 * i), width: 108, height: 19)
                sprite(ctx, "gui/sprites/container/enchanting_table/enchantment_slot_disabled.png", box.minX, box.minY)
                if pointer.map(box.contains) == true { tip = nothing }
            }
        }
        for (i, option) in options.enumerated() where !empty {
            let x = L + 60, y = T + 14 + CGFloat(19 * i)
            let box = CGRect(x: x, y: y, width: 108, height: 19)
            let can = level >= option.need
            let hot = can && pointer.map(box.contains) == true
            sprite(ctx, "gui/sprites/container/enchanting_table/enchantment_slot\(!can ? "_disabled" : hot ? "_highlighted" : "").png", x, y)
            sprite(ctx, "gui/sprites/container/enchanting_table/level_\(i + 1)\(can ? "" : "_disabled").png", x + 1, y + 1)
            let ink: UInt32 = !can ? 0x342F25 : hot ? 0xFFFF80 : 0x685E4A
            ctx.saveGState(); ctx.clip(to: CGRect(x: x + 20, y: y + 1, width: 86, height: 17))
            for (n, line) in wrap(option.words, 86, font: sga).prefix(2).enumerated() { text(ctx, line, x + 20, y + 2 + CGFloat(n * 8), ink, font: sga) }
            ctx.restoreGState()
            let need = String(option.need)
            text(ctx, need, x + 106 - CGFloat(uiFont.width(need)), y + 9, !can ? 0x407F10 : hot ? 0xFFFF80 : 0x80FF20, shadow: true)
            if pointer.map(box.contains) == true {
                tip = [("\(option.name) . . . ?", 0xFFFFFF)] + wrap(option.desc, 200).map { ($0, UInt32(0xAAAAAA)) }
                tip.append(can ? ("Click to enchant your prompt", 0x55FF55) : ("Level Requirement: \(option.need)", 0xFF5555))
                if can, closingAt == nil, let p = pressed, box.contains(p) {
                    playSound("enchant\(Int.random(in: 1...3))")
                    emit(["choice": i])
                    closingAt = t
                }
            }
        }
        if let p = pointer, !tip.isEmpty { tooltip(ctx, tip, p, w, h) }
        let window = CGRect(x: L, y: T, width: 176, height: 166)
        if keys.contains(53) || keys.contains(14) || (pressed.map { !window.contains($0) } ?? false) || t > 590 { finished = true }
        if let at = closingAt, t - at > 0.6 { finished = true }
        endFrame()
    }
}

// MARK: brewing stand

/// BrewingStandScreen as the chat's settings: the potions along the hotbar row
/// are the models, the glowstone stacks above them the effort, and blaze powder
/// fast mode. What is chosen shows in the stand itself: the bottles hold the
/// model, the ingredient slot the effort, the fuel slot fast mode. A change
/// brews at once and closes the stand.
final class BrewScene: Scene {
    struct Potion { let id: String, name: String, color: UInt32, lines: [String], bottle: String }
    let potions: [Potion]
    let efforts: [String]
    let hasFast: Bool
    var potion: String
    var effort: Int          // -1: the model's default
    var fast: Bool
    let start: (String, Int, Bool)
    var brewingAt: Double? = nil
    var closingAt: Double? = nil
    var finished = false

    init(_ json: String) {
        let data = spec(json)
        potions = (data["potions"] as? [[String: Any]] ?? []).map {
            Potion(id: $0["id"] as? String ?? "", name: clean($0["name"] as? String ?? ""), color: UInt32(($0["color"] as? Int) ?? 0x385DC6),
                   lines: ($0["lines"] as? [String] ?? []).map(clean), bottle: $0["bottle"] as? String ?? "potion")
        }
        efforts = (data["efforts"] as? [String] ?? []).map(clean)
        hasFast = data["fast"] is Bool
        potion = data["potion"] as? String ?? (potions.first?.id ?? "")
        effort = min(max(-1, data["effort"] as? Int ?? -1), efforts.count - 1)
        fast = data["fast"] as? Bool ?? false
        start = (potion, effort, fast)
    }

    /// The game's potion item: the overlay tinted with the effect's color, the glass bottle over it.
    func bottle(_ ctx: CGContext, _ p: Potion, _ x: CGFloat, _ y: CGFloat) {
        if let overlay = image("item/potion_overlay.png") {
            blit(ctx, tint(overlay, CGFloat((p.color >> 16) & 255) / 255, CGFloat((p.color >> 8) & 255) / 255, CGFloat(p.color & 255) / 255), CGRect(x: x, y: y, width: 16, height: 16))
        }
        item(ctx, p.bottle, x, y)
    }

    /// Something changed: brew it, and close once the arrow has filled.
    func brew(_ t: Double) {
        brewingAt = t
        playSound("brew\(Int.random(in: 1...2))", volume: 0.6)
        playSound("bottle", volume: 0.5)
    }

    func stack(_ ctx: CGContext, _ name: String, _ count: Int, _ x: CGFloat, _ y: CGFloat) {
        item(ctx, name, x, y)
        if count > 1 { let n = String(count); text(ctx, n, x + 17 - CGFloat(uiFont.width(n)), y + 9, 0xFFFFFF, shadow: true) }
    }

    func close(_ t: Double) {
        guard closingAt == nil else { return }
        if (potion, effort, fast) != start { emit(["potion": potion, "effort": effort, "fast": fast]) }
        closingAt = t
    }

    func draw(_ ctx: CGContext, t: Double, w: CGFloat, h: CGFloat) {
        dim(ctx, w, h)
        guard let sheet = image("gui/container/brewing_stand.png") else { finished = true; return }
        let L = ((w - 176) / 2).rounded(.down), T = ((h - 166) / 2).rounded(.down)
        part(ctx, sheet, CGRect(x: 0, y: 0, width: 176, height: 166), L, T)
        let title = "Brewing Stand"
        text(ctx, title, L + ((176 - CGFloat(uiFont.width(title))) / 2).rounded(.down), T + 6, 0x404040)
        text(ctx, "Inventory", L + 8, T + 72, 0x404040)
        var tip: [(String, UInt32)] = []
        let current = potions.first { $0.id == potion }
        let describe = { (p: Potion) -> [(String, UInt32)] in [(p.name, 0xFFFFFF)] + p.lines.enumerated().map { ($0.element, $0.offset == 0 ? UInt32(0x5555FF) : 0xAAAAAA) } }
        let clicked = { [self] (r: CGRect) -> Bool in closingAt == nil && brewingAt == nil && pressed.map(r.contains) == true }
        let hover = { (x: CGFloat, y: CGFloat) in fill(ctx, CGRect(x: x, y: y, width: 16, height: 16), 0x80FFFFFF) }

        // The stand shows what is chosen: fuel is fast mode, the ingredient the effort, the bottles the model.
        let fuel = Slot(x: 17, y: 17), ingredient = Slot(x: 79, y: 17)
        if fast { item(ctx, "blaze_powder", L + fuel.x, T + fuel.y); sprite(ctx, "gui/sprites/container/brewing_stand/fuel_length.png", L + 60, T + 44) }
        if over(fuel, L, T), hasFast { hover(L + fuel.x, T + fuel.y); tip = [("Fast Mode", 0xFFFFFF), ("Faster output.", 0xAAAAAA), ("Click to switch it on or off", 0xAAAAAA)] }
        if effort >= 0 { stack(ctx, "glowstone_dust", effort + 1, L + ingredient.x, T + ingredient.y) }
        if over(ingredient, L, T) { hover(L + ingredient.x, T + ingredient.y); tip = [("Effort: \(effort >= 0 ? efforts[effort] : "Default")", 0xFFFFFF)] }
        for b in [Slot(x: 56, y: 51), Slot(x: 79, y: 58), Slot(x: 102, y: 51)] {
            if let current { bottle(ctx, current, L + b.x, T + b.y) }
            if over(b, L, T), let current { tip = describe(current) }
        }

        // Brewing: the arrow fills and the bubbles rise for a moment.
        if let at = brewingAt, t - at < 1.2 {
            let p = min(1, (t - at) / 0.8)
            if let arrow = image("gui/sprites/container/brewing_stand/brew_progress.png"),
               let cut = arrow.cropping(to: CGRect(x: 0, y: 0, width: 9, height: max(1, Int(28 * p)))) {
                blit(ctx, cut, CGRect(x: L + 97, y: T + 16, width: 9, height: CGFloat(cut.height)))
            }
            let rise = [29, 24, 20, 16, 11, 6, 0][Int((t - at) * 12) % 7]
            if rise > 0, let bubbles = image("gui/sprites/container/brewing_stand/bubbles.png"),
               let cut = bubbles.cropping(to: CGRect(x: 0, y: 29 - rise, width: 12, height: rise)) {
                blit(ctx, cut, CGRect(x: L + 63, y: T + 14 + CGFloat(29 - rise), width: 12, height: CGFloat(rise)))
            }
        }

        // The inventory: effort along the top row, fast mode below it, models along the hotbar row.
        for (i, name) in efforts.enumerated() {
            let x = L + 8 + CGFloat(18 * i), y = T + 84
            stack(ctx, "glowstone_dust", i + 1, x, y)
            guard pointer.map({ CGRect(x: x - 1, y: y - 1, width: 18, height: 18).contains($0) }) == true else { continue }
            hover(x, y)
            tip = [("Effort: \(name)", 0xFFFFFF), (i == effort ? "In use" : "Click to use", i == effort ? 0x55FF55 : 0xAAAAAA)]
            if clicked(CGRect(x: x - 1, y: y - 1, width: 18, height: 18)), i != effort { effort = i; brew(t) }
        }
        if hasFast {
            let x = L + 8, y = T + 102
            item(ctx, "blaze_powder", x, y)
            if pointer.map({ CGRect(x: x - 1, y: y - 1, width: 18, height: 18).contains($0) }) == true {
                hover(x, y)
                tip = [("Fast Mode", 0xFFFFFF), ("Faster output.", 0xAAAAAA), ("Click to switch it on or off", 0xAAAAAA)]
            }
        }
        if hasFast, clicked(CGRect(x: L + 7, y: T + 101, width: 18, height: 18)) || clicked(CGRect(x: L + fuel.x - 1, y: T + fuel.y - 1, width: 18, height: 18)) {
            fast.toggle()
            brew(t)
        }
        for (i, p) in potions.enumerated() {
            let x = L + 8 + CGFloat(18 * i), y = T + 142
            bottle(ctx, p, x, y)
            guard pointer.map({ CGRect(x: x - 1, y: y - 1, width: 18, height: 18).contains($0) }) == true else { continue }
            hover(x, y)
            tip = describe(p) + [(p.id == potion ? "In use" : "Click to brew", p.id == potion ? 0x55FF55 : 0xAAAAAA)]
            if clicked(CGRect(x: x - 1, y: y - 1, width: 18, height: 18)), p.id != potion { potion = p.id; brew(t) }
        }

        // What the chat will use, under the window.
        let summary = [current?.lines.first?.replacingOccurrences(of: "Model: ", with: "") ?? "Default model",
                       "\(effort >= 0 ? efforts[effort] : "Default") effort"] + (fast ? ["Fast mode switched"] : [])
        centered(ctx, summary.joined(separator: "  -  "), L + 88, T + 172, 0xFFFFFF)
        if let at = brewingAt, t - at > 0.9 { close(t) }

        if let p = pointer, !tip.isEmpty { tooltip(ctx, tip, p, w, h) }
        let window = CGRect(x: L, y: T, width: 176, height: 166)
        if keys.contains(53) || keys.contains(14) || (pressed.map { !window.contains($0) } ?? false) || t > 590 { close(t) }
        if let at = closingAt, t - at > 0.15 { finished = true }
        endFrame()
    }
}

// MARK: map

/// The project as a held map: each folder an island sized by its files, charted
/// only around the islands Claude has visited this chat. Banners mark changed
/// files, a red X a failing test, the arrow where Claude is. Drag to pan,
/// scroll to zoom; click a marker to mention its file.
final class MapScene: Scene {
    struct Marker { let file: String, kind: String; var x: CGFloat = 0, y: CGFloat = 0 }
    struct Island { let name: String, files: Int, seen: Bool, color: UInt32; var markers: [Marker]; var x: CGFloat = 0, y: CGFloat = 0, r: CGFloat = 0 }
    var islands: [Island] = []
    let title: String
    var world: CGImage? = nil
    var worldW: CGFloat = 128, worldH: CGFloat = 128
    var zoom: CGFloat = 0, panX: CGFloat = 0, panY: CGFloat = 0   // map pixel at the view's center
    var dragFrom: CGPoint? = nil, dragged = false
    var closingAt: Double? = nil
    var finished = false

    init(_ json: String) {
        let data = spec(json)
        title = clean(data["title"] as? String ?? "Map")
        let biomes: [UInt32] = [0x7FB238, 0x007C00, 0x7FB238, 0x667F33, 0xF7E9A3]
        islands = (data["islands"] as? [[String: Any]] ?? []).map { i in
            let name = clean(i["name"] as? String ?? "")
            let hash = name.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7FFFFFFF }
            return Island(name: name, files: i["files"] as? Int ?? 1, seen: i["seen"] as? Bool ?? false,
                          color: name.contains("test") ? 0xF7E9A3 : biomes[hash % biomes.count],
                          markers: (i["markers"] as? [[String: Any]] ?? []).map { Marker(file: clean($0["file"] as? String ?? ""), kind: $0["kind"] as? String ?? "changed") })
        }
        layout()
        world = paint()
    }

    /// Islands placed largest first along a spiral from the middle, each clear of the rest.
    func layout() {
        let order = islands.indices.sorted { islands[$0].files > islands[$1].files }
        var placed: [Int] = []
        for i in order {
            islands[i].r = min(30, 7 + CGFloat(islands[i].files).squareRoot() * 2.2)
            var a: CGFloat = CGFloat(i) * 2.4, d: CGFloat = 0
            while true {
                let x = cos(a) * d, y = sin(a) * d
                if placed.allSatisfy({ hypot(islands[$0].x - x, islands[$0].y - y) > islands[$0].r + islands[i].r + 26 }) {
                    islands[i].x = x; islands[i].y = y; break
                }
                a += 0.5; d += 1.2
            }
            placed.append(i)
        }
        let minX = islands.map { $0.x - $0.r * 2 }.min() ?? 0, minY = islands.map { $0.y - $0.r * 2 }.min() ?? 0
        let maxX = islands.map { $0.x + $0.r * 2 }.max() ?? 128, maxY = islands.map { $0.y + $0.r * 2 }.max() ?? 128
        for i in islands.indices {
            islands[i].x -= minX; islands[i].y -= minY
            // Markers spread over the island, inside its shore.
            // Markers on a sunflower spiral over the island; "here" sits beside its file's banner.
            let files = islands[i].markers.filter { $0.kind != "here" }.count
            var k: CGFloat = 0
            for m in islands[i].markers.indices where islands[i].markers[m].kind != "here" {
                let ring = files <= 1 ? 0 : islands[i].r * 0.62 * ((k + 0.5) / CGFloat(files)).squareRoot()
                islands[i].markers[m].x = islands[i].x + cos(k * 2.39996) * ring
                islands[i].markers[m].y = islands[i].y + sin(k * 2.39996) * ring
                k += 1
            }
            for m in islands[i].markers.indices where islands[i].markers[m].kind == "here" {
                let file = islands[i].markers[m].file
                let same = islands[i].markers.first { $0.kind != "here" && $0.file == file }
                islands[i].markers[m].x = (same?.x ?? islands[i].x) + 5
                islands[i].markers[m].y = (same?.y ?? islands[i].y) - 5
            }
        }
        worldW = max(128, maxX - minX); worldH = max(128, maxY - minY)
    }

    /// The map itself, a pixel to a map pixel, as the game shades it: land, shore, three depths of sea.
    func paint() -> CGImage? {
        let w = Int(worldW), h = Int(worldH)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 12345
        func rand() -> CGFloat { seed = seed &* 1664525 &+ 1013904223; return CGFloat(seed >> 8) / CGFloat(1 << 24) }
        let shades: [CGFloat] = [180 / 255, 220 / 255, 1, 220 / 255]
        let seen = islands.filter(\.seen)
        for y in 0..<h {
            for x in 0..<w {
                let fx = CGFloat(x), fy = CGFloat(y)
                var best: CGFloat = .infinity, bestIsland = -1
                for (i, isl) in islands.enumerated() {
                    let d = (hypot(fx - isl.x, fy - isl.y) + rand() * 2.5) / isl.r
                    if d < best { best = d; bestIsland = i }
                }
                guard bestIsland >= 0 else { continue }
                let k = shades[(x * 3 + y * 5 + Int(rand() * 4)) % 4]
                let color: UInt32, shade: CGFloat
                if !islands[bestIsland].seen {
                    // Land not yet visited: sketched in, a darker parchment inside an inked coastline.
                    if best < 0.9 { color = 0xB49A6E; shade = 0.85 + 0.15 * k }
                    else if best < 1 { color = 0x6E5A3C; shade = 1 }
                    else if seen.contains(where: { hypot(fx - $0.x, fy - $0.y) < $0.r * 1.9 }) { color = 0x4040FF; shade = [135, 180, 220][min(2, Int((best - 1) * 3))] / 255 }
                    else { continue }
                }
                else if best < 0.8 { color = islands[bestIsland].color; shade = k }
                else if best < 1 { color = 0xF7E9A3; shade = k }
                else if seen.contains(where: { hypot(fx - $0.x, fy - $0.y) < $0.r * 1.9 }) { color = 0x4040FF; shade = [135, 180, 220][min(2, Int((best - 1) * 3))] / 255 }
                else { continue }
                let o = (y * w + x) * 4
                px[o] = UInt8(CGFloat((color >> 16) & 255) * shade); px[o + 1] = UInt8(CGFloat((color >> 8) & 255) * shade)
                px[o + 2] = UInt8(CGFloat(color & 255) * shade); px[o + 3] = 255
            }
        }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.data?.copyMemory(from: px, byteCount: px.count)
        return ctx.makeImage()
    }

    func draw(_ ctx: CGContext, t: Double, w: CGFloat, h: CGFloat) {
        dim(ctx, w, h)
        let size = (min(w, h) - 36).rounded(.down), fx = ((w - size) / 2).rounded(.down), fy = ((h - size) / 2).rounded(.down) + 8
        sprite(ctx, "map/map_background.png", fx, fy, size, size)
        let inner = (size * 128 / 142).rounded(.down), ix = ((w - inner) / 2).rounded(.down), iy = fy + ((size - inner) / 2).rounded(.down)
        let view = CGRect(x: ix, y: iy, width: inner, height: inner)
        // Opening: the whole map in view.
        if zoom == 0 { zoom = max(0.8, min(4, inner / max(worldW, worldH))); panX = worldW / 2; panY = worldH / 2 }

        // Scroll zooms about the pointer; dragging pans.
        if scrolled != 0, let p = pointer, view.contains(p) {
            let before = CGPoint(x: panX + (p.x - view.midX) / zoom, y: panY + (p.y - view.midY) / zoom)
            zoom = min(8, max(inner / max(worldW, worldH) * 0.9, zoom * pow(1.0025, scrolled)))
            panX = before.x - (p.x - view.midX) / zoom; panY = before.y - (p.y - view.midY) / zoom
        }
        if let p = pressed, view.contains(p) { dragFrom = p; dragged = false }
        if held, let from = dragFrom, let p = pointer {
            if hypot(p.x - from.x, p.y - from.y) > 2 || dragged {
                dragged = true
                panX -= (p.x - from.x) / zoom; panY -= (p.y - from.y) / zoom
                dragFrom = p
            }
        }
        panX = min(max(0, panX), worldW); panY = min(max(0, panY), worldH)
        let toView = { (x: CGFloat, y: CGFloat) in CGPoint(x: view.midX + (x - self.panX) * self.zoom, y: view.midY + (y - self.panY) * self.zoom) }

        ctx.saveGState(); ctx.clip(to: view)
        if let world {
            let o = toView(0, 0)
            ctx.interpolationQuality = .none
            blit(ctx, world, CGRect(x: o.x, y: o.y, width: worldW * zoom, height: worldH * zoom))
        }
        var tip: [(String, UInt32)] = []
        var hit: Marker? = nil
        let tag = { (s: String, at: CGPoint, color: UInt32, alpha: UInt32) in
            let tw = CGFloat(uiFont.width(s))
            fill(ctx, CGRect(x: (at.x - tw / 2 - 2).rounded(), y: at.y - 2, width: tw + 4, height: 11), alpha << 24)
            text(ctx, s, (at.x - tw / 2).rounded(), at.y, color)
        }
        for isl in islands {
            let c = toView(isl.x, isl.y - isl.r - 5)
            if isl.seen { tag(isl.name, c, 0xFFFF55, 0x96) }
            else if islands.count <= 15 || zoom >= 2 || pointer.map({ hypot($0.x - toView(isl.x, isl.y).x, $0.y - toView(isl.x, isl.y).y) < max(12, isl.r * zoom) }) == true {
                tag(isl.name, c, 0xE0D6B8, 0x50)
            }
            // Zoomed out, an island with many changed files shows one banner and their count.
            let changes = isl.markers.filter { $0.kind == "changed" }
            let grouped = changes.count > 5 && zoom < 3
            if grouped {
                let at = toView(isl.x, isl.y)
                sprite(ctx, "map/decorations/red_banner.png", (at.x - 8).rounded(), (at.y - 8).rounded(), 16, 16)
                tag("\(changes.count) changed", CGPoint(x: at.x, y: at.y + 9), 0xFFFFFF, 0x8C)
                if pointer.map({ hypot($0.x - at.x, $0.y - at.y) < 9 }) == true {
                    tip = [("\(changes.count) files changed in \(isl.name)", 0xFFFFFF), ("Scroll to zoom in and see them", 0xAAAAAA)]
                }
            }
            for m in isl.markers where !(grouped && m.kind == "changed") {
                let at = toView(m.x, m.y)
                let icon = m.kind == "fail" ? "red_x" : m.kind == "here" ? "player" : "red_banner"
                sprite(ctx, "map/decorations/\(icon).png", (at.x - 8).rounded(), (at.y - 8).rounded(), 16, 16)
                let name = (m.file as NSString).lastPathComponent
                // File names when zoomed in, or under the pointer; the overview keeps to folders.
                if m.kind != "here", zoom >= 2.5 || pointer.map({ hypot($0.x - at.x, $0.y - at.y) < 9 }) == true { tag(name, CGPoint(x: at.x, y: at.y + 9), 0xFFFFFF, 0x8C) }
                if pointer.map({ hypot($0.x - at.x, $0.y - at.y) < 9 }) == true {
                    hit = m
                    tip = [(m.file, 0xFFFFFF), (m.kind == "fail" ? "A failing test" : m.kind == "here" ? "Claude is here" : "Changed in this chat", 0xAAAAAA), ("Click to mention it", 0x55FF55)]
                }
            }
        }
        ctx.restoreGState()

        if !islands.contains(where: \.seen) {
            let line = "Claude has not opened any files in this chat yet."
            let tw = CGFloat(uiFont.width(line))
            fill(ctx, CGRect(x: (w - tw) / 2 - 4, y: view.maxY - 26, width: tw + 8, height: 14), 0xA0000000)
            centered(ctx, line, w / 2, view.maxY - 23, 0xFFFFFF)
        }
        centered(ctx, title, w / 2, 6, 0xFFFFFF)
        let visited = islands.filter(\.seen).count
        centered(ctx, "Explored this chat: \(visited) of \(islands.count) folders", w / 2, 17, 0xAAAAAA, shadow: false)
        for (i, (icon, label)) in [("player", "Claude is here"), ("red_banner", "Changed"), ("red_x", "Failing test")].enumerated() {
            sprite(ctx, "map/decorations/\(icon).png", 8, 34 + CGFloat(i * 18), 16, 16)
            text(ctx, label, 28, 38 + CGFloat(i * 18), 0xFFFFFF)
        }
        for (i, s) in ["Drag to look around", "Scroll to zoom", "Click a marker to mention it", "Esc: put away"].enumerated() {
            text(ctx, s, w - CGFloat(uiFont.width(s)) - 8, h - 50 + CGFloat(i * 11), 0xA0A0A0)
        }
        if let p = pointer, !tip.isEmpty { tooltip(ctx, tip, p, w, h) }

        if released, !dragged, let m = hit, closingAt == nil { emit(["file": m.file]); playSound("click", volume: 0.25); closingAt = t }
        if released { dragFrom = nil }
        let frame = CGRect(x: fx, y: fy, width: size, height: size)
        if keys.contains(53) || (pressed.map { !frame.contains($0) } ?? false) || t > 590 { if closingAt == nil { closingAt = t } }
        if let at = closingAt, t - at > 0.15 { finished = true }
        endFrame()
    }
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
                                           ("totem", "Totem"), ("villager", "Villager"), ("enchant", "Enchanting"), ("brewing", "Brewing"), ("clicks", "Clicks")]
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
            if button(ctx, CGRect(x: cx - 100, y: top + 208, width: 200, height: 20), "Done") || back { page = "main" }
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
/// the HUD drawn large with each part labelled, the hotbar's five slots, and the big moments.
final class GuideScene: Scene {
    var closingAt: Double? = nil
    var finished = false

    init(_ json: String) {}

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

    func draw(_ ctx: CGContext, t: Double, w: CGFloat, h: CGFloat) {
        dim(ctx, w, h)
        let cx = (w / 2).rounded(.down)
        centered(ctx, "Welcome to the Minecraft HUD", cx, 12, 0xFFFFFF)
        centered(ctx, "Claude Code, drawn as Minecraft. Here is what everything means.", cx, 24, 0xA0A0A0, shadow: false)

        // The bars, twice their size, each part named over it.
        let bx = cx - 182, by: CGFloat = 66
        ctx.saveGState(); ctx.translateBy(x: bx, y: by); ctx.scaleBy(x: 2, y: 2); hud(ctx, 0, 0); ctx.restoreGState()
        text(ctx, "Hearts: your usage limit", bx, 42, 0xFF5555, shadow: true)
        text(ctx, "Each heart is 10% of it.", bx, 52, 0xA0A0A0)
        let food = "Hunger: the context window", sub = "Empties as the chat fills."
        text(ctx, food, bx + 364 - CGFloat(uiFont.width(food)), 42, 0xFFAA00, shadow: true)
        text(ctx, sub, bx + 364 - CGFloat(uiFont.width(sub)), 52, 0xA0A0A0)
        // What XP is for, before how it is counted.
        centered(ctx, "XP: based on how many tokens you consume", cx, by + 40, 0x80FF20)
        centered(ctx, "The first levels come fast; each one after takes longer.", cx, by + 50, 0xA0A0A0, shadow: false)

        // The hotbar, and what each slot opens.
        let hx = cx - 334, hy: CGFloat = 132
        ctx.saveGState(); ctx.translateBy(x: hx, y: hy); ctx.scaleBy(x: 2, y: 2)
        if let bar = image("gui/sprites/hud/hotbar.png") {
            if let a = bar.cropping(to: CGRect(x: 0, y: 0, width: 161, height: 22)) { blit(ctx, a, CGRect(x: 0, y: 0, width: 161, height: 22)) }
            if let b = bar.cropping(to: CGRect(x: 181, y: 0, width: 1, height: 22)) { blit(ctx, b, CGRect(x: 161, y: 0, width: 1, height: 22)) }
        }
        let slots: [(String, String, String)] = [("written_book", "Skill Book", "Read and use your skills."),
                                                ("enchanting_table", "Enchanting Table", "Rewrite your prompt."),
                                                ("brewing_stand", "Brewing Stand", "Pick the model and effort."),
                                                ("filled_map", "Map", "Where Claude has been."),
                                                ("knowledge_book", "Advancements", "73 to earn."),
                                                ("jukebox", "Jukebox", "Play the game's music."),
                                                ("parrot_spawn_egg", "Parrot", "A friend on your desktop."),
                                                ("comparator", "Settings", "Sounds and animations.")]
        for (i, slot) in slots.enumerated() { item(ctx, slot.0, CGFloat(3 + 20 * i), 3) }
        ctx.restoreGState()
        centered(ctx, "Open one with /minecraft and its name.", hx + 162, hy + 50, 0xA0A0A0, shadow: false)
        for (i, slot) in slots.enumerated() {
            let y = hy - 4 + CGFloat(i * 10)
            item(ctx, slot.0, cx + 10, y - 2, size: 12)
            text(ctx, slot.1, cx + 26, y, 0xFFFFFF, shadow: true)
            text(ctx, slot.2, cx + 26 + CGFloat(uiFont.width(slot.1)) + 6, y, 0xA0A0A0)
        }

        // The moments that take over the screen.
        centered(ctx, "When something big happens", cx, 210, 0xFFFFFF)
        let moments: [(String, String, String)] = [("bone", "You hit your limit", "The death screen."),
                                                  ("totem_of_undying", "Your limit resets", "The Totem of Undying."),
                                                  ("golden_apple", "You compact a chat", "A golden apple.")]
        for (i, m) in moments.enumerated() {
            let x = cx - 186 + CGFloat(i * 128)
            item(ctx, m.0, x, 226)
            text(ctx, m.1, x + 20, 226, 0xFFFFFF, shadow: true)
            text(ctx, m.2, x + 20, 236, 0xA0A0A0)
        }

        if button(ctx, CGRect(x: cx - 100, y: h - 46, width: 200, height: 20), "Let's Go") || keys.contains(36) || keys.contains(53) {
            if closingAt == nil { closingAt = t }
        }
        centered(ctx, "Type /minecraft help to see this again.", cx, h - 20, 0x707070, shadow: false)
        if let at = closingAt, t - at > 0.25 { finished = true }
        if t > 590 { finished = true }
        endFrame()
    }
}

// MARK: the lectern

/// BookViewScreen on a lectern: the skills you can run, as a book. The first
/// pages list every skill by name (click one to turn to it); each skill then
/// has its own page. "Use Skill" closes the book and prints the skill's name.
final class LecternScene: Scene {
    struct Skill { let name: String, desc: String, source: String, use: String }
    let skills: [Skill]
    let perContents = 12
    var page = 0
    var closingAt: Double? = nil
    var finished = false

    init(_ json: String) {
        skills = (spec(json)["skills"] as? [[String: Any]] ?? []).map {
            Skill(name: clean($0["name"] as? String ?? ""), desc: clean($0["desc"] as? String ?? ""), source: clean($0["source"] as? String ?? ""), use: $0["use"] as? String ?? "")
        }
    }

    var contentsPages: Int { max(1, (skills.count + perContents - 1) / perContents) }
    var total: Int { contentsPages + skills.count }

    /// One line, cut to the page's width.
    func fit(_ s: String) -> String {
        if uiFont.width(s) <= 114 { return s }
        var cut = s
        while !cut.isEmpty, uiFont.width(cut + "...") > 114 { cut.removeLast() }
        return cut + "..."
    }

    func turn(_ to: Int) {
        let next = min(max(0, to), total - 1)
        if next != page { page = next; playSound("click", volume: 0.25) }
    }

    func draw(_ ctx: CGContext, t: Double, w: CGFloat, h: CGFloat) {
        dim(ctx, w, h)
        guard let book = image("gui/book.png") else { finished = true; return }
        let L = ((w - 192) / 2).rounded(.down), T = max(2, ((h - 222) / 2).rounded(.down))
        part(ctx, book, CGRect(x: 0, y: 0, width: 192, height: 192), L, T)
        let label = "Page \(page + 1) of \(total)"
        text(ctx, label, L + 148 - CGFloat(uiFont.width(label)), T + 16, 0x000000)
        let tx = L + 36, ty = T + 32
        let link: UInt32 = 0x2C2CA8

        if page < contentsPages {
            text(ctx, page == 0 ? "Your Skills" : "Your Skills, continued", tx, ty, 0x000000)
            if skills.isEmpty {
                for (i, line) in wrap("No skills yet. Skills you add to ~/.claude/skills, to a project, or with a plugin appear here.", 114).enumerated() {
                    text(ctx, line, tx, ty + 18 + CGFloat(i * 9), 0x404040)
                }
            }
            for i in 0..<perContents {
                let index = page * perContents + i
                guard index < skills.count else { break }
                let y = ty + 14 + CGFloat(i * 9)
                let line = fit(skills[index].name)
                let hot = pointer.map { CGRect(x: tx, y: y - 1, width: 114, height: 9).contains($0) } == true
                text(ctx, line, tx, y, hot ? 0x5050FF : link)
                if hot { fill(ctx, CGRect(x: tx, y: y + 8, width: CGFloat(uiFont.width(line)), height: 1), 0xFF5050FF) }
                if hot, pressed != nil { turn(contentsPages + index) }
            }
        } else {
            let skill = skills[page - contentsPages]
            text(ctx, fit(skill.name), tx, ty, 0x000000)
            text(ctx, fit(skill.source), tx, ty + 9, 0x707070)
            let lines = wrap(skill.desc.isEmpty ? "No description." : skill.desc, 114)
            for (i, line) in lines.prefix(10).enumerated() { text(ctx, i == 9 && lines.count > 10 ? fit(line + "...") : line, tx, ty + 24 + CGFloat(i * 9), 0x000000) }
            text(ctx, fit("/" + skill.use), tx, ty + 13 * 9, link)
        }

        // The page arrows, as the book screen draws them.
        for (forward, x) in [(false, L + 43), (true, L + 116)] {
            let shown = forward ? page < total - 1 : page > 0
            guard shown else { continue }
            let r = CGRect(x: x, y: T + 157, width: 23, height: 13)
            let hot = pointer.map(r.contains) == true
            sprite(ctx, "gui/sprites/widget/page_\(forward ? "forward" : "backward")\(hot ? "_highlighted" : "").png", r.minX, r.minY)
            if hot, pressed != nil { turn(page + (forward ? 1 : -1)) }
        }
        if keys.contains(124) { turn(page + 1) }
        if keys.contains(123) { turn(page - 1) }

        let cx = (w / 2).rounded(.down)
        if button(ctx, CGRect(x: cx - 100, y: T + 196, width: 98, height: 20), "Done") || keys.contains(53) { if closingAt == nil { closingAt = t } }
        let onSkill = page >= contentsPages
        if button(ctx, CGRect(x: cx + 2, y: T + 196, width: 98, height: 20), "Use Skill", enabled: onSkill), closingAt == nil {
            emit(["use": skills[page - contentsPages].use])
            closingAt = t
        }
        if let at = closingAt, t - at > 0.25 { finished = true }
        if t > 590 { finished = true }
        endFrame()
    }
}
