// The parrot: a desktop pet in a small window of its own, built in 3D from the
// game's ParrotModel and parrot texture. It stands still and watches the
// pointer; while the jukebox plays it dances, as parrots do by a jukebox.
// Drag it anywhere; click it and it chirps and hops; right-click changes its
// coat. It is shown and hidden from the hotbar, and only one process shows it.

import AppKit
import SceneKit
import simd

let petState = cacheDir.appendingPathComponent("parrot.json")
let coats = ["red_blue", "blue", "green", "yellow_blue", "grey"]

func readPet() -> [String: Any] {
    (try? Data(contentsOf: petState)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
}
func writePet(_ change: [String: Any]) {
    var state = readPet()
    for (k, v) in change { state[k] = v }
    if let data = try? JSONSerialization.data(withJSONObject: state) { try? data.write(to: petState, options: .atomic) }
}

// MARK: the model

/// One cube of a ModelPart: texture offset, then the box (origin and size) in model pixels.
struct Cube { let u: Float, v: Float, x: Float, y: Float, z: Float, w: Float, h: Float, d: Float }

/// ModelPart.Cube's six faces with their texture rectangles, as the game lays them out
/// (Polygon: the first vertex takes (u2, v1), then (u1, v1), (u1, v2), (u2, v2)).
func cubeGeometry(_ c: Cube, _ material: SCNMaterial) -> SCNGeometry {
    let x0 = c.x, y0 = c.y, z0 = c.z, x1 = c.x + c.w, y1 = c.y + c.h, z1 = c.z + c.d
    let v1 = SIMD3(x0, y0, z0), v2 = SIMD3(x1, y0, z0), v3 = SIMD3(x1, y1, z0), v4 = SIMD3(x0, y1, z0)
    let v5 = SIMD3(x0, y0, z1), v6 = SIMD3(x1, y0, z1), v7 = SIMD3(x1, y1, z1), v8 = SIMD3(x0, y1, z1)
    let u = c.u, v = c.v, w = c.w, h = c.h, d = c.d
    let f = u, f4 = u + d, f5 = u + d + w, f6 = u + d + w + w, f7 = u + d + w + d, f8 = u + d + w + d + w
    let f9 = v, f10 = v + d, f11 = v + d + h
    let faces: [([SIMD3<Float>], Float, Float, Float, Float)] = [
        ([v6, v5, v1, v2], f4, f9, f5, f10),     // the side toward -Y: the top, the model being upside down
        ([v3, v4, v8, v7], f5, f10, f6, f9),
        ([v1, v5, v8, v4], f, f10, f4, f11),
        ([v2, v1, v4, v3], f4, f10, f5, f11),
        ([v6, v2, v3, v7], f5, f10, f7, f11),
        ([v5, v6, v7, v8], f7, f10, f8, f11),
    ]
    var positions: [SCNVector3] = [], uvs: [CGPoint] = [], indices: [Int32] = []
    for (verts, u1, vv1, u2, vv2) in faces {
        let base = Int32(positions.count)
        let corners = [(u2, vv1), (u1, vv1), (u1, vv2), (u2, vv2)]
        for (p, (tu, tv)) in zip(verts, corners) {
            positions.append(SCNVector3(p.x, p.y, p.z))
            uvs.append(CGPoint(x: CGFloat(tu / 32), y: CGFloat(tv / 32)))
        }
        indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    }
    let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(textureCoordinates: uvs)],
                               elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    geometry.materials = [material]
    return geometry
}

final class Part {
    let node = SCNNode()
    let pivot: SIMD3<Float>, rotation: SIMD3<Float>
    init(_ cubes: [Cube], pivot: SIMD3<Float>, rotation: SIMD3<Float> = .zero, material: SCNMaterial, parent: SCNNode) {
        self.pivot = pivot; self.rotation = rotation
        for c in cubes { node.addChildNode(SCNNode(geometry: cubeGeometry(c, material))) }
        parent.addChildNode(node)
        pose(pivot, rotation)
    }
    /// ModelPart.translateAndRotate: to the pivot, then Z, Y, X rotations.
    func pose(_ at: SIMD3<Float>, _ r: SIMD3<Float>) {
        node.simdPosition = at
        node.simdOrientation = simd_quatf(angle: r.z, axis: [0, 0, 1]) * simd_quatf(angle: r.y, axis: [0, 1, 0]) * simd_quatf(angle: r.x, axis: [1, 0, 0])
    }
}

// MARK: the window

final class PetView: SCNView {
    weak var pet: ParrotPet?
    var downAt: NSPoint? = nil, moved = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downAt = NSEvent.mouseLocation; moved = false }
    override func mouseDragged(with event: NSEvent) {
        guard let from = downAt, let window else { return }
        let now = NSEvent.mouseLocation
        if hypot(now.x - from.x, now.y - from.y) > 2 || moved {
            moved = true
            window.setFrameOrigin(NSPoint(x: window.frame.minX + now.x - from.x, y: window.frame.minY + now.y - from.y))
            downAt = now
        }
    }
    override func mouseUp(with event: NSEvent) {
        if moved, let f = window?.frame { writePet(["x": f.minX, "y": f.minY]) } else { pet?.hop() }
        downAt = nil
    }
    override func rightMouseDown(with event: NSEvent) { pet?.nextCoat() }
}

final class ParrotPet {
    let window: NSWindow
    let view: PetView
    let scene = SCNScene()
    let material = SCNMaterial()
    var parts: [String: Part] = [:]
    var timer: Timer? = nil
    let born = CACurrentMediaTime()
    var hopAt: Double = -10
    var dancing = false
    var lastMouse = NSPoint(x: -1, y: -1)

    init(show: Bool = true) {
        let size = NSSize(width: 120, height: 140)
        let state = readPet()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        var x = (state["x"] as? Double).map { CGFloat($0) } ?? screen.visibleFrame.maxX - size.width - 40
        var y = (state["y"] as? Double).map { CGFloat($0) } ?? screen.visibleFrame.minY + 30
        // Left on a display that is gone: back to the corner of the main one.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(NSRect(origin: NSPoint(x: x, y: y), size: size)) }) {
            x = screen.visibleFrame.maxX - size.width - 40; y = screen.visibleFrame.minY + 30
        }
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view = PetView(frame: NSRect(origin: .zero, size: size))
        view.backgroundColor = .clear
        view.antialiasingMode = .none
        view.preferredFramesPerSecond = 30
        view.scene = scene
        view.pet = self
        window.contentView = view

        // The texture drawn as the game draws it: whole pixels, no smoothing.
        material.diffuse.magnificationFilter = .none
        material.diffuse.minificationFilter = .none
        material.diffuse.mipFilter = .none
        material.isDoubleSided = true
        material.lightingModel = .lambert
        setCoat(state["coat"] as? String ?? "red_blue")

        // The model's space is the game's: Y down, a sixteenth of a block to the unit.
        let root = SCNNode()
        root.simdScale = [-1 / 16, -1 / 16, 1 / 16]
        root.simdPosition = [0, 16.5 / 16, 1 / 16]
        scene.rootNode.addChildNode(root)
        let m = material
        parts["body"] = Part([Cube(u: 2, v: 8, x: -1.5, y: 0, z: -1.5, w: 3, h: 6, d: 3)], pivot: [0, 16.5, -3], rotation: [0.4937, 0, 0], material: m, parent: root)
        parts["tail"] = Part([Cube(u: 22, v: 1, x: -1.5, y: -1, z: -1, w: 3, h: 4, d: 1)], pivot: [0, 21.07, 1.16], rotation: [1.015, 0, 0], material: m, parent: root)
        parts["left_wing"] = Part([Cube(u: 19, v: 8, x: -0.5, y: 0, z: -1.5, w: 1, h: 5, d: 3)], pivot: [1.5, 16.94, -2.76], rotation: [-0.6981, -.pi, 0], material: m, parent: root)
        parts["right_wing"] = Part([Cube(u: 19, v: 8, x: -0.5, y: 0, z: -1.5, w: 1, h: 5, d: 3)], pivot: [-1.5, 16.94, -2.76], rotation: [-0.6981, -.pi, 0], material: m, parent: root)
        let head = Part([Cube(u: 2, v: 2, x: -1, y: -1.5, z: -1, w: 2, h: 3, d: 2)], pivot: [0, 15.69, -2.76], material: m, parent: root)
        parts["head"] = head
        _ = Part([Cube(u: 10, v: 0, x: -1, y: -0.5, z: -2, w: 2, h: 1, d: 4)], pivot: [0, -2, -1], material: m, parent: head.node)
        _ = Part([Cube(u: 11, v: 7, x: -0.5, y: -1, z: -0.5, w: 1, h: 2, d: 1)], pivot: [0, -0.5, -1.5], material: m, parent: head.node)
        _ = Part([Cube(u: 16, v: 7, x: -0.5, y: 0, z: -0.5, w: 1, h: 2, d: 1)], pivot: [0, -1.75, -2.45], material: m, parent: head.node)
        _ = Part([Cube(u: 2, v: 18, x: 0, y: -4, z: -2, w: 0, h: 5, d: 4)], pivot: [0, -2.15, 0.15], rotation: [-0.2214, 0, 0], material: m, parent: head.node)
        parts["left_leg"] = Part([Cube(u: 14, v: 18, x: -0.5, y: 0, z: -0.5, w: 1, h: 2, d: 1)], pivot: [1, 22, -1.05], rotation: [-0.0299, 0, 0], material: m, parent: root)
        parts["right_leg"] = Part([Cube(u: 14, v: 18, x: -0.5, y: 0, z: -0.5, w: 1, h: 2, d: 1)], pivot: [-1, 22, -1.05], rotation: [-0.0299, 0, 0], material: m, parent: root)

        // Seen from a little to its left and above, as the inventory shows a mob, without perspective.
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 0.62
        camera.simdPosition = [-2.1, 0.6, -1.4]
        camera.simdLook(at: [0, 0, 0])
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera
        // The game's entity light: a soft fill and one light from above and in front.
        let fill = SCNNode(); fill.light = SCNLight(); fill.light?.type = .ambient; fill.light?.intensity = 520
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional; key.light?.intensity = 650
        key.simdPosition = [-1, 2, -2]; key.simdLook(at: .zero)
        scene.rootNode.addChildNode(fill); scene.rootNode.addChildNode(key)

        guard show else { return }
        window.orderFrontRegardless()
        playRaw("parrot\(Int.random(in: 1...6))", 0.5)
        pace(30)
    }

    /// Ticks as often as the parrot needs: 30 a second while it moves, 10 while it waits.
    var rate: Double = 0
    func pace(_ perSecond: Double) {
        guard perSecond != rate else { return }
        rate = perSecond
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / perSecond, repeats: true) { [weak self] _ in self?.tick() }
        view.preferredFramesPerSecond = perSecond > 10 ? 30 : 1
    }

    func setCoat(_ coat: String) {
        let name = coats.contains(coat) ? coat : "red_blue"
        material.diffuse.contents = loadImage("entity/parrot/parrot_\(name).png")
    }
    func nextCoat() {
        let now = coats.firstIndex(of: readPet()["coat"] as? String ?? "red_blue") ?? 0
        let next = coats[(now + 1) % coats.count]
        writePet(["coat": next]); setCoat(next)
        playRaw("parrot\(Int.random(in: 1...6))", 0.5)
    }
    func hop() {
        hopAt = CACurrentMediaTime() - born
        playRaw("parrot\(Int.random(in: 1...6))", 0.6)
        playRaw("parrot_fly", 0.3)
    }

    /// The parrot drawn to an image, for checking it without a window: idle, or mid-dance.
    func snapshot(dancing: Bool, at t: Double) -> NSImage {
        self.dancing = dancing
        pose(t: t, mouse: NSPoint(x: window.frame.midX + CGFloat(Double(ProcessInfo.processInfo.environment["MC_LOOK"] ?? "200") ?? 200), y: window.frame.midY))
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = view.pointOfView
        return renderer.snapshot(atTime: 0, with: CGSize(width: 240, height: 280), antialiasingMode: .none)
    }

    func tick() {
        let t = CACurrentMediaTime() - born
        // Dancing while the jukebox plays: the player is running, has a track, and is not paused.
        if Int(t * rate) % max(1, Int(rate / 2)) == 0 {
            let state = readPlayerState()
            dancing = !(state["paused"] as? Bool ?? true) && !((state["title"] as? String) ?? "").isEmpty
        }
        // It watches the pointer only when it is near; farther off it looks ahead. Nothing new: nothing drawn.
        var m = NSEvent.mouseLocation
        if hypot(m.x - window.frame.midX, m.y - window.frame.midY) > 600 { m = NSPoint(x: window.frame.midX - 300, y: window.frame.midY) }
        let moved = hypot(m.x - lastMouse.x, m.y - lastMouse.y) > 3
        let still = !dancing && t - hopAt > 0.6 && !moved
        view.isPlaying = !still
        pace(still ? 10 : 30)
        if still { return }
        lastMouse = m
        pose(t: t, mouse: m)
        // Clicks land on the parrot alone; the clear space around it passes them through.
        let local = view.convert(window.convertPoint(fromScreen: m), from: nil)
        let over = view.bounds.contains(local) && !view.hitTest(local, options: [.searchMode: SCNHitTestSearchMode.any.rawValue]).isEmpty
        if window.ignoresMouseEvents == over, view.downAt == nil { window.ignoresMouseEvents = !over }
    }

    func pose(t: Double, mouse m: NSPoint) {
        let hopping = t - hopAt < 0.5
        let up = hopping ? Float(sin((t - hopAt) / 0.5 * .pi)) * 3 : 0
        // Where the pointer is, from the parrot's head: the head turns to it, as mobs look at the player.
        let f = window.frame
        let dx = Float(m.x - f.midX), dy = Float(m.y - (f.minY + f.height * 0.72))
        let yaw = max(-0.9, min(0.9, atan2(dx, 260))), pitch = max(-0.5, min(0.5, atan2(-dy, 260)))

        guard let head = parts["head"], let body = parts["body"], let tail = parts["tail"],
              let lw = parts["left_wing"], let rw = parts["right_wing"] else { return }
        if dancing {
            // ParrotModel's party pose: everything circles a pixel, the head rocks, the wings open.
            let ticks = Float(t * 20), c = cos(ticks), s = sin(ticks)
            head.pose([c, 15.69 + s - up, -2.76], [0, 0, s * 0.4])
            body.pose([c, 16.5 + s - up, -3], body.rotation)
            tail.pose([c, 21.07 + s - up, 1.16], tail.rotation)
            let open = 0.35 + 0.25 * sin(ticks * 2)
            lw.pose([1.5 + c, 16.94 + s - up, -2.76], [-0.6981, -.pi, -0.0873 - open])
            rw.pose([-1.5 + c, 16.94 + s - up, -2.76], [-0.6981, -.pi, 0.0873 + open])
        } else {
            head.pose([0, 15.69 - up, -2.76], [pitch, -yaw, 0])
            body.pose([0, 16.5 - up, -3], body.rotation)
            tail.pose([0, 21.07 - up, 1.16], tail.rotation)
            // A hop flaps the wings once.
            let flap: Float = hopping ? Float(sin((t - hopAt) * 30)) * 0.6 : 0
            lw.pose([1.5, 16.94 - up, -2.76], [-0.6981, -.pi, -flap])
            rw.pose([-1.5, 16.94 - up, -2.76], [-0.6981, -.pi, flap])
        }
    }

    func close() {
        timer?.invalidate()
        window.orderOut(nil)
    }
}
