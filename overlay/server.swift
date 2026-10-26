// The screen server: one helper kept running in the background with its window
// built and its pictures loaded, so a screen opens the moment it is asked for
// instead of after a cold start.
//
//   MCOverlay <assetsDir> serve        starts the server on its own, if it is not running, and returns
//
// Each copy of the helper has its own inbox, so two versions of the mod never
// share a server. The mod writes <id>.request into the inbox; the server takes
// it by renaming it away, shows the screen, and writes <id>.reply when the
// screen closes. A request past its deadline is dropped (the mod has gone on to
// start the screen itself). `alive` is touched every two seconds, so the mod
// can tell a server that is there from one that is gone.

import AppKit
import AVFoundation

let binPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path   // absolute, however it was started
let inbox: URL = {
    let name = String(binPath.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    let dir = cacheDir.appendingPathComponent("screens").appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

/// Which file the helper is: its inode and when it was written. A rebuild or a
/// reinstall changes both, though the path stays the same.
func binaryStamp() -> String {
    let at = try? FileManager.default.attributesOfItem(atPath: binPath)
    return "\((at?[.systemFileNumber] as? Int) ?? 0):\(((at?[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0)"
}

/// A full-screen, see-through window above everything, on every Space.
func overlayWindow() -> OverlayWindow {
    let window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.level = .screenSaver
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    return window
}

/// A toast is a corner notice, not an event: half the size of the rest.
func momentGui(_ mode: String, _ gui: CGFloat) -> CGFloat {
    mode == "totem" || ProcessInfo.processInfo.environment["MC_GUI_SCALE"] != nil ? gui : max(1.5, gui / 2)
}

/// The display under the pointer, where a screen or moment should appear now:
/// displays come and go, and the one at startup may not be the one in use.
func currentScreen() -> NSScreen {
    let m = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
}

/// Minecraft's GUI scale, in points: the largest that keeps 320x240 GUI pixels on screen, less one.
func guiScale(_ f: NSRect) -> CGFloat {
    if let s = ProcessInfo.processInfo.environment["MC_GUI_SCALE"], let v = Double(s) { return CGFloat(v) }
    return CGFloat(max(2, min(Int(f.width / 320), Int(f.height / 240)) - 1))
}

/// Covers a display with the window and its view, at that display's scale.
func place(_ window: NSWindow, _ view: OverlayView, on display: NSScreen, gui: CGFloat) {
    if window.frame != display.frame { window.setFrame(display.frame, display: false) }
    view.frame = NSRect(origin: .zero, size: display.frame.size)
    view.gui = gui
}

/// A moment that plays over the screen and goes: totem [volume], advancement
/// <type> <title> <icon> [description], or tip <title> <icon> [description].
func momentScene(_ m: [String], gui: CGFloat, on display: NSScreen = screen) -> Scene? {
    let arg = { (i: Int) in m.count > i ? m[i] : nil }
    switch m.first {
    case "totem": return TotemScene(volume: arg(1).flatMap { Float($0) } ?? 1)
    case "advancement", "tip":
        let tip = m.first == "tip"
        return ToastScene(type: tip ? "tip" : arg(1) ?? "task", title: arg(2) ?? "Test Driven", iconName: arg(3) ?? "emerald",
                          desc: arg(4) ?? "", top: ProcessInfo.processInfo.environment["MC_TOAST_TOP"].flatMap { Double($0) }.map { CGFloat($0) } ?? (display.frame.maxY - display.visibleFrame.maxY) / gui)
    default: return nil
    }
}

/// The interactive screen for a mode, from its JSON.
func makeScreen(_ mode: String, _ json: String) -> Scene? {
    switch mode {
    case "death":
        let d = spec(json)
        return DeathScene(title: d["title"] as? String ?? "You Died!", cause: d["cause"] as? String ?? "Claude was slain by the 5-hour limit",
                          score: d["score"] as? String ?? "0", label: d["label"] as? String ?? "Respawn")
    case "advancements": return AdvancementsScene(json)
    case "jukebox": return JukeboxScene(json)
    case "guide": return GuideScene(json)
    case "options": return OptionsScene(json)
    case "hero": return HeroScene(json)
    default: return nil
    }
}

/// What the screen decided, kept for the reply when the server shows it.
var emitted: Any? = nil

// MARK: frames

var frames: Timer? = nil
var askedAt = Date()
var shownMode = mode

/// Redraws at 60 a second until the scene is finished. Records once when the
/// first frame went up, for timing how long a screen takes to appear.
func startFrames(_ done: @escaping () -> Void) {
    var firstDrawn = false
    frames = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
        if !firstDrawn, interactive {
            firstDrawn = true
            let line = "{\"mode\":\"\(shownMode)\",\"started\":\(Int(askedAt.timeIntervalSince1970 * 1000)),\"shown\":\(Int(Date().timeIntervalSince1970 * 1000)),\"active\":\(app.isActive)}"
            try? line.write(to: cacheDir.appendingPathComponent("timing.json"), atomically: true, encoding: .utf8)
        }
        view.needsDisplay = true
        if view.scene.finished { done() }
    }
}

// MARK: the server

final class IdleScene: Scene {
    var finished: Bool { false }
    func draw(_ ctx: CGContext, t: Double, w: CGFloat, h: CGFloat) {}
}

/// A process's parent and short name, from the kernel's process table.
func processInfo(_ pid: pid_t) -> (parent: pid_t, name: String)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafePointer(to: info.kp_proc.p_comm) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) } }
    return (info.kp_eproc.e_ppid, name)
}

/// The Claude process the helper was started for: the nearest ancestor that is not a shell or a wrapper.
func hostProcess() -> pid_t {
    let wrappers: Set<String> = ["sh", "bash", "zsh", "dash", "env", "sandbox-exec", "timeout", "nice", "nohup", "MCOverlay"]
    var pid = getppid()
    for _ in 0..<8 {
        guard pid > 1, let info = processInfo(pid) else { break }
        if !wrappers.contains(info.name) { return pid }
        pid = info.parent
    }
    return pid
}

/// Starts the server as its own process, unless one is running already, and tells it which
/// Claude process wants it: the server stays while any such process lives.
func startServer() {
    let host = hostProcess()
    if host > 1 { FileManager.default.createFile(atPath: inbox.appendingPathComponent("\(host).host").path, contents: nil) }
    let fd = open(inbox.appendingPathComponent("server.lock").path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { return }
    flock(fd, LOCK_UN)
    close(fd)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: binPath)
    child.arguments = [assets.path, "serve-run"]
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try? child.run()
}

/// A moment the server is playing, in a click-through window of its own, so
/// several can run at once (toasts stack) and none waits on a screen.
final class Moment {
    let window = overlayWindow()
    let view: OverlayView
    var timer: Timer? = nil

    init(_ scene: Scene, gui: CGFloat, on display: NSScreen) {
        view = OverlayView(frame: NSRect(origin: .zero, size: display.frame.size))
        place(window, view, on: display, gui: gui)
        view.scene = scene
        window.contentView = view
        window.orderFrontRegardless()
    }

    func run(_ done: @escaping (Moment) -> Void) {
        let began = Date()
        var firstDrawn = false
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [unowned self] _ in
            if !firstDrawn {
                firstDrawn = true
                let line = "{\"mode\":\"moment\",\"started\":\(Int(began.timeIntervalSince1970 * 1000)),\"shown\":\(Int(Date().timeIntervalSince1970 * 1000))}"
                try? line.write(to: cacheDir.appendingPathComponent("timing.json"), atomically: true, encoding: .utf8)
            }
            view.needsDisplay = true
            guard view.scene.finished else { return }
            timer?.invalidate()
            window.orderOut(nil)
            // Lets the scene go, and with it a toast's slot.
            view.scene = IdleScene()
            done(self)
        }
    }
}

final class Server {
    var showing: String? = nil      // the id of the request on screen
    var lastUsed = Date()
    var watcher: DispatchSourceFileSystemObject? = nil
    var petWatcher: DispatchSourceFileSystemObject? = nil
    var timers: [Timer] = []
    var warm: AVAudioPlayer? = nil
    var moments: [Moment] = []
    var pet: ParrotPet? = nil
    var petLock: Int32 = -1
    // The Claude processes using this server, each watched by the kernel for its exit.
    var hosts: [pid_t: DispatchSourceProcess] = [:]
    var everHosted = false
    let startedAt = Date()
    let startedStamp = binaryStamp()

    /// Holds the lock for as long as the process lives, or quits if another server has it.
    func claim() {
        let fd = open(inbox.appendingPathComponent("server.lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
    }

    func start() {
        claim()
        signal(SIGTERM) { _ in exit(0) }
        // The pictures every screen draws, loaded now so a first frame has little to
        // read; each screen's own are loaded the first time it opens, and kept.
        let shared = ((try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? []).filter { $0.hasSuffix(".png") }
            + ["gui/sprites/widget", "gui/sprites/container", "gui/sprites/toast"].flatMap { dir in
                ((try? FileManager.default.contentsOfDirectory(atPath: assets.appendingPathComponent(dir).path)) ?? []).filter { $0.hasSuffix(".png") }.map { "\(dir)/\($0)" }
            }
        for path in shared { _ = image(path) }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: assets.appendingPathComponent("sounds").path)) ?? [] where name.hasSuffix(".wav") {
            soundData[String(name.dropLast(4))] = try? Data(contentsOf: assets.appendingPathComponent("sounds/\(name)"))
        }
        // The window's first showing costs over half a second (its backing store,
        // the compositor's setup): paid now rather than on the first screen. The
        // idle scene draws nothing and clicks pass through, so it is up unseen; a
        // fully transparent window would be skipped by the compositor and warm nothing.
        let display = currentScreen()
        place(window, view, on: display, gui: guiScale(display.frame))
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        view.display()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            window.orderOut(nil)
            window.ignoresMouseEvents = false
        }
        // The sound output opened once now, so a slot's click is not late.
        warm = try? AVAudioPlayer(contentsOf: assets.appendingPathComponent("sounds/click.wav"))
        warm?.prepareToPlay()
        // Stale files from before: requests nobody will wait for, replies nobody read.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? [] where [".request", ".reply", ".sound", ".moment"].contains(where: name.hasSuffix) {
            try? FileManager.default.removeItem(at: inbox.appendingPathComponent(name))
        }
        let fd = open(inbox.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in self?.poll() }
            source.setCancelHandler { close(fd) }
            source.resume()
            watcher = source
        }
        beat()
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.beat() })
        // The parrot's file is watched the same way, its folder being where it is replaced.
        let cacheFd = open(cacheDir.path, O_EVTONLY)
        if cacheFd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: cacheFd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in self?.syncPet() }
            source.setCancelHandler { close(cacheFd) }
            source.resume()
            petWatcher = source
        }
        // Either watcher can miss a write; a slow look now and then catches it.
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.poll(); self?.syncPet() })
        syncPet()
        poll()
    }

    func beat() {
        try? "\(getpid()) \(Int(startedAt.timeIntervalSince1970)) \(Int(lastUsed.timeIntervalSince1970))".write(to: inbox.appendingPathComponent("alive"), atomically: true, encoding: .utf8)
        let idle = showing == nil && moments.isEmpty
        // Unused for half a day: leave, and the next chat starts a fresh one.
        if idle, pet == nil, Date().timeIntervalSince(lastUsed) > 12 * 3600 { exit(0) }
        // Another version's server has been used since this one was: after ten quiet minutes, give way to it.
        if idle, Date().timeIntervalSince(lastUsed) > 600 {
            let all = cacheDir.appendingPathComponent("screens")
            for dir in (try? FileManager.default.contentsOfDirectory(atPath: all.path)) ?? [] where dir != inbox.lastPathComponent {
                guard let line = try? String(contentsOf: all.appendingPathComponent("\(dir)/alive"), encoding: .utf8) else { continue }
                let parts = line.split(separator: " ").compactMap { Int($0) }
                if parts.count == 3, kill(pid_t(parts[0]), 0) == 0, parts[2] > Int(lastUsed.timeIntervalSince1970) { exit(0) }
            }
        }
        // The helper was replaced or removed: this copy is no longer the mod's. A
        // replaced one keeps running its old code from memory, so it leaves once
        // idle and the next screen starts the new one.
        if !FileManager.default.fileExists(atPath: binPath) { exit(0) }
        if idle, binaryStamp() != startedStamp { exit(0) }
    }

    /// Watches a Claude process: the kernel says when it exits, nothing is polled.
    func watchHost(_ pid: pid_t, _ file: URL) {
        guard hosts[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        let gone = { [weak self] in
            source.cancel()
            self?.hosts[pid] = nil
            try? FileManager.default.removeItem(at: file)
            self?.hostsChanged()
        }
        source.setEventHandler(handler: gone)
        hosts[pid] = source
        everHosted = true
        source.resume()
        // Already gone before the watch began: the kernel will not say so.
        if kill(pid, 0) != 0, errno == ESRCH { gone() }
    }

    /// With no Claude process left, the companion leaves too: a moment's grace for a relaunch,
    /// then the music stops, the parrot goes (it comes back next time) and the server quits.
    func hostsChanged() {
        guard everHosted, hosts.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.poll()
            guard self.hosts.isEmpty else { return }
            if playerRunning() { tellPlayer(["cmd": "stop"]) }
            self.pet?.close()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            exit(0)
        }
    }

    /// Plays every sound waiting, starts every moment waiting, then takes a screen request.
    func poll() {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []).sorted()
        for name in names where name.hasSuffix(".host") {
            if let pid = pid_t(name.dropLast(".host".count)) { watchHost(pid, inbox.appendingPathComponent(name)) }
        }
        // A sound is all in its name, <id>~<sound>~<volume>.sound, so there is nothing to half-read.
        for name in names where name.hasSuffix(".sound") {
            try? FileManager.default.removeItem(at: inbox.appendingPathComponent(name))
            let parts = name.dropLast(".sound".count).split(separator: "~")
            if parts.count == 3, let volume = Float(parts[2]) { playRaw(String(parts[1]), volume); lastUsed = Date() }
        }
        for name in names where name.hasSuffix(".moment") {
            let url = inbox.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                let at = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                if at.map({ Date().timeIntervalSince($0) > 5 }) ?? true { try? FileManager.default.removeItem(at: url); continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.poll() }
                continue
            }
            try? FileManager.default.removeItem(at: url)
            lastUsed = Date()
            // Late by more than a few seconds, it is no longer the moment.
            if Date().timeIntervalSince1970 * 1000 - ((req["at"] as? Double) ?? 0) > 5000 { continue }
            masterVolume = Float((req["volume"] as? Double) ?? 1)
            mutedKinds = Set((req["muted"] as? [String]) ?? [])
            var m = (req["moment"] as? [String]) ?? []
            if m.first == "totem" { m = ["totem", String((req["loudness"] as? Double) ?? 1)] }
            let display = currentScreen()
            let gui = momentGui(m.first ?? "", guiScale(display.frame))
            guard let scene = momentScene(m, gui: gui, on: display) else { continue }
            let moment = Moment(scene, gui: gui, on: display)
            moments.append(moment)
            moment.run { [weak self] done in self?.moments.removeAll { $0 === done } }
        }
        take()
    }

    /// Shows the parrot when it is wanted and no other process shows it; hides it when it is not wanted.
    func syncPet() {
        let wanted = readPet()["on"] as? Bool ?? false
        if wanted, pet == nil {
            if petLock < 0 {
                let fd = open(cacheDir.appendingPathComponent("parrot.lock").path, O_CREAT | O_RDWR, 0o644)
                guard fd >= 0 else { return }
                if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return }
                petLock = fd
            }
            pet = ParrotPet()
        } else if !wanted, let shown = pet {
            shown.close(); pet = nil
            if petLock >= 0 { close(petLock); petLock = -1 }
        }
    }

    /// Takes the oldest waiting request, if no screen is up.
    func take() {
        guard showing == nil else { return }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []).filter { $0.hasSuffix(".request") }.sorted()
        for name in names {
            let url = inbox.appendingPathComponent(name)
            let id = String(name.dropLast(".request".count))
            guard let data = try? Data(contentsOf: url), let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                // Still being written: look again in a moment. Unreadable for long, it never will be.
                let at = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                if at.map({ Date().timeIntervalSince($0) > 5 }) ?? true { try? FileManager.default.removeItem(at: url); continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.take() }
                continue
            }
            let taken = inbox.appendingPathComponent("\(id).taken")
            guard rename(url.path, taken.path) == 0 else { continue }
            try? FileManager.default.removeItem(at: taken)
            let deadline = (req["deadline"] as? Double) ?? 0
            guard Date().timeIntervalSince1970 * 1000 <= deadline,
                  let mode = req["mode"] as? String, let scene = makeScreen(mode, req["json"] as? String ?? "{}") else {
                reply(id, ["dropped": true])
                continue
            }
            show(id, scene, req)
            return
        }
    }

    func show(_ id: String, _ scene: Scene, _ req: [String: Any]) {
        showing = id
        lastUsed = Date()
        askedAt = Date()
        shownMode = req["mode"] as? String ?? ""
        masterVolume = Float((req["volume"] as? Double) ?? 1)
        mutedKinds = Set((req["muted"] as? [String]) ?? [])
        if let click = req["click"] as? Double, click > 0 { playSound("click", volume: Float(click)) }
        emitted = nil
        keys = []; held = false; released = false; pressed = nil
        // On the display in use now, at its scale.
        let display = currentScreen()
        place(window, view, on: display, gui: guiScale(display.frame))
        // Where the pointer is now, so whatever is under it lights up on the first frame.
        let m = NSEvent.mouseLocation, f = display.frame
        pointer = CGPoint(x: (m.x - f.minX) / view.gui, y: (f.maxY - m.y) / view.gui)
        view.scene = scene
        view.start = CACurrentMediaTime()
        view.display()
        app.unhideWithoutActivation()
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        startFrames { [weak self] in self?.finish() }
    }

    func finish() {
        frames?.invalidate()
        frames = nil
        window.orderOut(nil)
        // Hands the focus back to whatever had it before the screen.
        app.hide(nil)
        if let id = showing { reply(id, ["result": emitted ?? NSNull()]) }
        showing = nil
        view.scene = IdleScene()
        lastUsed = Date()
        DispatchQueue.main.async { [weak self] in self?.take() }
    }

    func reply(_ id: String, _ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        try? data.write(to: inbox.appendingPathComponent("\(id).reply"), options: .atomic)
        // Replies are read within a fraction of a second; any left a minute on were not wanted.
        let now = Date()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? [] where name.hasSuffix(".reply") {
            let url = inbox.appendingPathComponent(name)
            if let at = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, now.timeIntervalSince(at) > 60 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
