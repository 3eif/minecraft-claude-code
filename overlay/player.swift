// The jukebox: a screen for choosing what plays, and a player that keeps
// playing after the screen has closed.
//
//   MCOverlay <assetsDir> jukebox <json>     the screen
//   MCOverlay <assetsDir> player [command]   the background player (one at a time)
//   MCOverlay <assetsDir> music <command>    tells the player: toggle | next | prev | stop
//
// The music is the person's own copy: it is read from their Minecraft install
// (the launcher's assets folder) and nothing is bundled here. The game ships
// Ogg Vorbis, which macOS does not play, so each track is converted with
// ffmpeg to a temporary file as it comes up and that file is removed after.

import AppKit
import AVFoundation

struct Track { let path: String, title: String, icon: String }
struct Album { let name: String, icon: String, tracks: [Track] }

// MARK: what there is to play

/// The discs and the soundtrack, from the newest asset index of the local install.
func musicLibrary() -> (discs: [Track], albums: [Album]) {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/minecraft/assets")
    let indexes = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("indexes").path)) ?? []
    let newest = indexes.compactMap { name -> (Int, String)? in Int(name.replacingOccurrences(of: ".json", with: "")).map { ($0, name) } }.max { $0.0 < $1.0 }?.1
    guard let newest, let data = try? Data(contentsOf: root.appendingPathComponent("indexes/\(newest)")),
          let objects = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["objects"] as? [String: [String: Any]] else { return ([], []) }
    func file(_ key: String) -> String? {
        guard let hash = objects[key]?["hash"] as? String else { return nil }
        let path = root.appendingPathComponent("objects/\(hash.prefix(2))/\(hash)").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
    // The discs, in the game's order, with the titles its language file gives them.
    let listed = ((try? JSONSerialization.jsonObject(with: (try? Data(contentsOf: assets.appendingPathComponent("music.json"))) ?? Data())) as? [[String: String]]) ?? []
    let discs = listed.compactMap { disc -> Track? in
        guard let id = disc["id"], let path = file("minecraft/sounds/records/\(id).ogg") else { return nil }
        return Track(path: path, title: disc["title"] ?? id, icon: "music_disc_\(id)")
    }
    // The soundtrack has no titles in the game's files. The classics are named as their albums name
    // them; the newer tracks' files already carry their names.
    let titles = [
        "game/calm1": "Minecraft", "game/calm2": "Clark", "game/calm3": "Sweden", "game/hal1": "Subwoofer Lullaby",
        "game/hal2": "Living Mice", "game/hal3": "Haggstrom", "game/hal4": "Danny", "game/nuance1": "Key", "game/nuance2": "Oxygene",
        "game/piano1": "Dry Hands", "game/piano2": "Wet Hands", "game/piano3": "Mice on Venus",
        "game/creative/creative1": "Biome Fest", "game/creative/creative2": "Blind Spots", "game/creative/creative3": "Haunt Muskie",
        "game/creative/creative4": "Aria Math", "game/creative/creative5": "Dreiton", "game/creative/creative6": "Taswell",
        "menu/menu1": "Mutation", "menu/menu2": "Moog City 2", "menu/menu3": "Beginning 2", "menu/menu4": "Floating Trees",
        "game/end/boss": "Boss", "game/end/end": "The End", "game/end/credits": "Alpha",
        "game/nether/nether1": "Concrete Halls", "game/nether/nether2": "Dead Voxel", "game/nether/nether3": "Warmth", "game/nether/nether4": "Ballad of the Cats",
        "game/water/axolotl": "Axolotl", "game/water/dragon_fish": "Dragon Fish", "game/water/shuniji": "Shuniji",
    ]
    func named(_ key: String) -> String {
        let stem = String(key.dropFirst("minecraft/sounds/music/".count).dropLast(4))
        if let title = titles[stem] { return title }
        let base = URL(fileURLWithPath: key).deletingPathExtension().lastPathComponent
        let spaced = base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "([a-z])([0-9])", with: "$1 $2", options: .regularExpression)
        // Title case, the short words left small: "Mice on Venus", "Ballad of the Cats".
        let small: Set<String> = ["a", "an", "and", "of", "on", "the", "in", "to", "for"]
        return spaced.split(separator: " ").enumerated().map { i, word in
            i > 0 && small.contains(word.lowercased()) ? word.lowercased() : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
    let music = objects.keys.filter { $0.hasPrefix("minecraft/sounds/music/") }.sorted()
    func album(_ name: String, _ icon: String, _ belongs: (String) -> Bool) -> Album {
        Album(name: name, icon: icon, tracks: music.filter { belongs(String($0.dropFirst("minecraft/sounds/music/".count))) }.compactMap { key in
            file(key).map { Track(path: $0, title: named(key), icon: icon) }
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
    }
    let albums = [
        album("Overworld", "grass_block") { $0.hasPrefix("game/") && ($0.split(separator: "/").count == 2 || $0.hasPrefix("game/swamp/")) },
        album("Creative", "diamond") { $0.hasPrefix("game/creative/") },
        album("Nether", "netherrack") { $0.hasPrefix("game/nether/") },
        album("The End", "end_stone") { $0.hasPrefix("game/end/") },
        album("Underwater", "water_bucket") { $0.hasPrefix("game/water/") },
        album("Menu", "painting") { $0.hasPrefix("menu/") },
        album("Everything", "note_block") { _ in true },
    ].filter { !$0.tracks.isEmpty }
    return (discs, albums)
}

// MARK: talking to the player

let playerCommand = Notification.Name("dev.minecraft-hud.player.command")
let playerLock = cacheDir.appendingPathComponent("player.lock").path
let playerState = cacheDir.appendingPathComponent("player.json")

func playerRunning() -> Bool {
    let fd = open(playerLock, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
    return true
}

/// Hands the player a command, starting it first if it is not running. The
/// player is started on its own, with nothing of this process's attached, so
/// it outlives the screen and holds no pipe open.
func tellPlayer(_ command: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: command), let json = String(data: data, encoding: .utf8) else { return }
    if playerRunning() {
        DistributedNotificationCenter.default().postNotificationName(playerCommand, object: json, userInfo: nil, deliverImmediately: true)
        return
    }
    guard command["cmd"] as? String == "play" else { return }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = [assets.path, "player", json]
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try? child.run()
}

func readPlayerState() -> [String: Any] {
    guard playerRunning(), let data = try? Data(contentsOf: playerState) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

var jukeboxVolume: Double {
    get { (try? String(contentsOf: cacheDir.appendingPathComponent("volume"), encoding: .utf8)).flatMap { Double($0) } ?? 0.8 }
    set { try? String(newValue).write(to: cacheDir.appendingPathComponent("volume"), atomically: true, encoding: .utf8) }
}

// MARK: the player

/// "Now Playing: ..." above where the hotbar would be, its color cycling, as
/// the game shows it for a jukebox: 60 ticks, fading over the last 20.
final class NowPlayingView: NSView {
    let font = MCFont(loadImage("ascii.png")!)
    var line = ""
    var began = CACurrentMediaTime()
    var gui: CGFloat = 3
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        let left = 60 - (CACurrentMediaTime() - began) * 20
        guard left > 0 else { return }
        let color = NSColor(hue: CGFloat((left / 50).truncatingRemainder(dividingBy: 1)), saturation: 0.7, brightness: 0.6, alpha: 1).usingColorSpace(.deviceRGB) ?? .white
        // Sixteen steps to the channel, so the font tints a few hundred sheets at most.
        let step = { (v: CGFloat) -> UInt32 in UInt32((v * 15).rounded()) * 17 }
        let rgb = step(color.redComponent) << 16 | step(color.greenComponent) << 8 | step(color.blueComponent)
        ctx.saveGState()
        ctx.scaleBy(x: gui, y: gui)
        ctx.setAlpha(CGFloat(min(1, left / 20)))
        let w = bounds.width / gui, h = bounds.height / gui
        let x = (w / 2).rounded(.down) - CGFloat(font.width(line) / 2), y = h - 68
        font.draw(line, x: x + 1, y: y + 1, rgb: 0x202020, in: ctx)
        font.draw(line, x: x, y: y, rgb: rgb, in: ctx)
        ctx.restoreGState()
    }
}

final class Player: NSObject, AVAudioPlayerDelegate {
    var queue: [Track] = []
    var index = 0
    var loop = false
    var announce = false
    var album = ""
    var audio: AVAudioPlayer?
    var paused = false
    var generation = 0
    var problem = ""
    var banner: NSWindow?
    var bannerView: NowPlayingView?
    let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("minecraft-hud-track-\(getpid()).m4a")
    let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

    func handle(_ json: String) {
        let command = spec(json)
        switch command["cmd"] as? String ?? "" {
        case "play":
            queue = (command["tracks"] as? [[String: String]] ?? []).compactMap { t in
                guard let path = t["path"] else { return nil }
                return Track(path: path, title: t["title"] ?? "", icon: t["icon"] ?? "")
            }
            index = command["index"] as? Int ?? 0
            loop = command["loop"] as? Bool ?? false
            announce = command["announce"] as? Bool ?? false
            album = command["album"] as? String ?? ""
            start()
        case "toggle": toggle()
        case "next": step(1)
        case "prev": if (audio?.currentTime ?? 0) > 3 { audio?.currentTime = 0 } else { step(-1) }
        case "seek": if let audio, let to = command["to"] as? Double { audio.currentTime = max(0, min(audio.duration - 0.5, to)) }
        case "volume":
            if let v = command["volume"] as? Double { jukeboxVolume = v; audio?.volume = Float(v) }
        case "stop": quit()
        default: break
        }
        write()
    }

    func toggle() {
        guard let audio else { return }
        paused.toggle()
        if paused { audio.pause() } else { audio.play() }
    }

    func step(_ by: Int) {
        guard !queue.isEmpty else { quit(); return }
        let next = index + by
        if next >= queue.count || next < 0 {
            if !loop { quit(); return }
            index = (next + queue.count) % queue.count
        } else { index = next }
        start()
    }

    /// Converts the track at `index`, then plays it. A later call overtakes one still converting.
    func start(encoder: String = "aac_at") {
        guard queue.indices.contains(index) else { quit(); return }
        guard let ffmpeg else { problem = "ffmpeg is needed to play the game's music (brew install ffmpeg)"; write(); DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.quit() }; return }
        generation += 1
        let mine = generation, track = queue[index]
        audio?.stop()
        audio = nil
        paused = false
        problem = ""
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: ffmpeg)
        // The system's encoder is several times faster than ffmpeg's own; not every build has it.
        convert.arguments = ["-loglevel", "error", "-y", "-i", track.path, "-c:a", encoder, "-b:a", "192k", temp.path]
        convert.standardOutput = FileHandle.nullDevice
        convert.standardError = FileHandle.nullDevice
        convert.terminationHandler = { done in
            DispatchQueue.main.async {
                guard mine == self.generation else { return }
                if done.terminationStatus != 0, encoder == "aac_at" { self.start(encoder: "aac"); return }
                guard done.terminationStatus == 0, let made = try? AVAudioPlayer(contentsOf: self.temp) else { self.step(1); return }
                made.delegate = self
                made.volume = Float(jukeboxVolume)
                made.play()
                self.audio = made
                if self.announce { self.showBanner("Now Playing: \(clean(track.title))") }
                self.write()
            }
        }
        do { try convert.run() } catch { step(1) }
        write()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { step(1) }

    func showBanner(_ line: String) {
        guard let screen = NSScreen.main else { return }
        if banner == nil {
            let made = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            made.isOpaque = false
            made.backgroundColor = .clear
            made.hasShadow = false
            made.level = .screenSaver
            made.ignoresMouseEvents = true
            made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = NowPlayingView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.gui = CGFloat(max(2, min(Int(screen.frame.width / 320), Int(screen.frame.height / 240)) - 2))
            made.contentView = view
            banner = made
            bannerView = view
        }
        bannerView?.line = line
        bannerView?.began = CACurrentMediaTime()
        banner?.orderFrontRegardless()
    }

    var pausedAt: Double? = nil
    func tick() {
        // Paused for ten minutes: nobody is coming back to it.
        let now = CACurrentMediaTime()
        if paused { pausedAt = pausedAt ?? now; if now - pausedAt! > 600 { quit() } } else { pausedAt = nil }
        if let view = bannerView, banner?.isVisible == true {
            if CACurrentMediaTime() - view.began > 3.1 { banner?.orderOut(nil) } else { view.needsDisplay = true }
        }
    }

    func write() {
        let track = queue.indices.contains(index) ? queue[index] : nil
        let state: [String: Any] = ["title": track?.title ?? "", "icon": track?.icon ?? "", "album": album, "paused": paused, "loading": audio == nil,
                                    "position": audio?.currentTime ?? 0, "duration": audio?.duration ?? 0, "index": index, "count": queue.count, "problem": problem]
        if let data = try? JSONSerialization.data(withJSONObject: state) { try? data.write(to: playerState, options: .atomic) }
    }

    func quit() {
        audio?.stop()
        try? FileManager.default.removeItem(at: temp)
        try? FileManager.default.removeItem(at: playerState)
        exit(0)
    }
}

/// Runs the player until it is told to stop or runs out of music. Never returns.
func runPlayer(_ first: String?) -> Never {
    let fd = open(playerLock, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { exit(0) }
    // playerRunning() takes the lock for an instant to ask; only a lock held for a while means another player.
    var locked = false
    for _ in 0..<10 where !locked {
        locked = flock(fd, LOCK_EX | LOCK_NB) == 0
        if !locked { usleep(20_000) }
    }
    guard locked else { exit(0) }
    let player = Player()
    let center = DistributedNotificationCenter.default()
    let observer = center.addObserver(forName: playerCommand, object: nil, queue: .main) { note in
        if let json = note.object as? String { player.handle(json) }
    }
    center.suspended = false
    var beat = 0
    Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
        player.tick()
        beat += 1
        if beat % 8 == 0 { player.write() }
    }
    if let first { player.handle(first) } else { exit(0) }
    signal(SIGTERM) { _ in exit(0) }
    withExtendedLifetime(observer) { NSApplication.shared.run() }
    exit(0)
}

// MARK: the screen

/// A container window of any size, from the crafting table's own frame: its
/// corners as they are, its edges stretched, its middle filled.
func panel(_ ctx: CGContext, _ r: CGRect) {
    guard let sheet = image("gui/container/crafting_table.png") else { return }
    let b: CGFloat = 5, W: CGFloat = 176, H: CGFloat = 166
    fill(ctx, r.insetBy(dx: b - 1, dy: b - 1), 0xFFC6C6C6)
    let xs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0, b, r.minX, b), (b, 1, r.minX + b, r.width - 2 * b), (W - b, b, r.maxX - b, b)]
    let ys: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0, b, r.minY, b), (b, 1, r.minY + b, r.height - 2 * b), (H - b, b, r.maxY - b, b)]
    for (sx, sw, dx, dw) in xs {
        for (sy, sh, dy, dh) in ys where !(sx == b && sy == b) {
            if let cut = sheet.cropping(to: CGRect(x: sx, y: sy, width: sw, height: sh)) { blit(ctx, cut, CGRect(x: dx, y: dy, width: dw, height: dh)) }
        }
    }
}

func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
}

final class JukeboxScene: Scene {
    struct Note { var x: CGFloat, born: Double, hue: CGFloat }
    let library = musicLibrary()
    let announce: Bool
    var state: [String: Any] = [:]
    var readAt = -1.0
    var volume = jukeboxVolume
    var sliding = false
    var seeking: Double? = nil      // where along the track the pointer holds it, 0 to 1, while dragging
    var notes: [Note] = []
    var noteAt = 0.0
    var played = 0
    var discs: Set<String> = []
    var openAlbum: Int? = nil      // an album opened to its tracks
    var scroll: CGFloat = 0
    var finished = false

    init(_ json: String) { announce = spec(json)["announce"] as? Bool ?? true }

    func send(_ command: [String: Any], _ t: Double) {
        tellPlayer(command)
        readAt = t + 0.35            // let the player answer before the screen reads it again
    }

    func play(_ tracks: [Track], index: Int, loop: Bool, album: String, _ t: Double) {
        send(["cmd": "play", "tracks": tracks.map { ["path": $0.path, "title": $0.title, "icon": $0.icon] }, "index": index, "loop": loop, "announce": announce, "album": album], t)
        state = ["title": tracks[index].title, "icon": tracks[index].icon, "album": album, "paused": false, "loading": true, "position": 0.0, "duration": 0.0]
        played += 1
        discs.insert(tracks[index].icon)
        playSound("click", volume: 0.25)
    }

    func draw(_ ctx: CGContext, t: Double, w: CGFloat, h: CGFloat) {
        dim(ctx, w, h)
        if t >= readAt { state = readPlayerState(); readAt = t + 0.25 }
        let W: CGFloat = 176, H: CGFloat = 190
        let L = ((w - W) / 2).rounded(.down), T = ((h - H) / 2).rounded(.down)
        panel(ctx, CGRect(x: L, y: T, width: W, height: H))
        text(ctx, "Jukebox", L + 8, T + 6, 0x404040)

        let title = clean(state["title"] as? String ?? "")
        let playing = !title.isEmpty
        let paused = state["paused"] as? Bool ?? false
        let problem = clean(state["problem"] as? String ?? "")
        var tip: [(String, UInt32)] = []

        // The jukebox itself, notes rising from it while it plays.
        item(ctx, "jukebox", L + 12, T + 20, size: 32)
        if playing, !paused, t - noteAt > 0.45 { noteAt = t; notes.append(Note(x: CGFloat.random(in: 16...34), born: t, hue: CGFloat.random(in: 0...1))) }
        notes.removeAll { t - $0.born > 1.4 }
        if let sheet = image("particle/note.png") {
            for note in notes {
                let age = CGFloat(t - note.born)
                let c = NSColor(hue: note.hue, saturation: 0.8, brightness: 1, alpha: 1).usingColorSpace(.deviceRGB) ?? .white
                ctx.setAlpha(max(0, 1 - age / 1.4))
                blit(ctx, tint(sheet, c.redComponent, c.greenComponent, c.blueComponent), CGRect(x: L + note.x, y: T + 20 - age * 14, width: 8, height: 8))
            }
            ctx.setAlpha(1)
        }

        // The slot: what is in the jukebox. A click takes it out.
        let slot = Slot(x: 52, y: 27)
        sprite(ctx, "gui/sprites/container/slot.png", L + slot.x - 1, T + slot.y - 1)
        if playing {
            item(ctx, state["icon"] as? String ?? "", L + slot.x, T + slot.y)
            if over(slot, L, T) {
                fill(ctx, CGRect(x: L + slot.x, y: T + slot.y, width: 16, height: 16), 0x80FFFFFF)
                tip = [("Take it out", 0xFFFFFF), ("Stops the music", 0xAAAAAA)]
                if pressed != nil { send(["cmd": "stop"], t); state = [:]; playSound("click", volume: 0.25) }
            }
        }

        // What is playing, how far in, and the controls.
        let tx = L + 76
        if !problem.isEmpty {
            for (i, line) in wrap(problem, 92).prefix(3).enumerated() { text(ctx, line, tx, T + 20 + CGFloat(i * 9), 0xAA0000) }
        } else if playing {
            for (i, line) in wrap(title, 92).prefix(2).enumerated() { text(ctx, line, tx, T + 20 + CGFloat(i * 9), 0x404040) }
            let duration = state["duration"] as? Double ?? 0
            // The bar seeks: press anywhere along it, drag, and the track jumps there on release.
            let track = CGRect(x: tx, y: T + 38, width: 92, height: 10)
            let along = { (p: CGPoint) in Double(min(1, max(0, (p.x - tx) / 92))) }
            if duration > 0, let p = pressed, track.contains(p) { seeking = along(p) }
            if seeking != nil, let p = pointer { seeking = along(p) }
            if let to = seeking, !held {
                send(["cmd": "seek", "to": to * duration], t)
                state["position"] = to * duration
                seeking = nil
                playSound("click", volume: 0.25)
            }
            let position = seeking.map { $0 * duration } ?? state["position"] as? Double ?? 0
            fill(ctx, CGRect(x: tx, y: T + 42, width: 92, height: 3), 0xFF373737)
            if duration > 0 { fill(ctx, CGRect(x: tx, y: T + 42, width: (92 * CGFloat(min(1, position / duration))).rounded(), height: 3), 0xFF80FF20) }
            if duration > 0, seeking == nil, let p = pointer, track.contains(p) { tip = [("Jump to \(clock(along(p) * duration))", 0xFFFFFF)] }
            let end = duration > 0 ? clock(duration) : "..."
            text(ctx, clock(position), tx, T + 48, 0x404040)
            text(ctx, end, tx + 92 - CGFloat(uiFont.width(end)), T + 48, 0x404040)
        } else {
            text(ctx, "Empty.", tx, T + 20, 0x404040)
            for (i, line) in wrap("Click a disc to put it in.", 92).enumerated() { text(ctx, line, tx, T + 31 + CGFloat(i * 9), 0x707070) }
        }
        let many = (state["count"] as? Int ?? 1) > 1
        if button(ctx, CGRect(x: tx, y: T + 62, width: 28, height: 20), "<<", enabled: playing) { send(["cmd": "prev"], t) }
        if button(ctx, CGRect(x: tx + 32, y: T + 62, width: 28, height: 20), paused ? ">" : "||", enabled: playing) || (playing && keys.contains(49)) {
            send(["cmd": "toggle"], t); state["paused"] = !paused
        }
        if button(ctx, CGRect(x: tx + 64, y: T + 62, width: 28, height: 20), ">>", enabled: playing && many) { send(["cmd": "next"], t) }

        let bar = CGRect(x: L + 8, y: T + 62, width: 62, height: 20)
        if let p = pressed, bar.contains(p) { sliding = true }
        if sliding, let p = pointer {
            let now = (Double(min(1, max(0, (p.x - bar.minX - 4) / (bar.width - 8)))) * 20).rounded() / 20
            if now != volume { volume = now; jukeboxVolume = now; tellPlayer(["cmd": "volume", "volume": now]) }
        }
        if !held { sliding = false }
        nine(ctx, "gui/sprites/widget/slider.png", bar, 3)
        sprite(ctx, "gui/sprites/widget/slider_handle\(sliding || pointer.map(bar.contains) == true ? "_highlighted" : "").png", bar.minX + CGFloat(volume) * (bar.width - 8), bar.minY)
        centered(ctx, "Vol \(Int((volume * 100).rounded()))%", bar.midX, bar.minY + 6, 0xFFFFFF)

        // An album opened: its tracks, to play one, or all of them shuffled.
        if let a = openAlbum, a < library.albums.count {
            let album = library.albums[a]
            item(ctx, album.icon, L + 8, T + 86, size: 12)
            text(ctx, album.name, L + 24, T + 88, 0x404040)
            if button(ctx, CGRect(x: L + W - 86, y: T + 84, width: 44, height: 16), "Shuffle") {
                play(album.tracks.shuffled(), index: 0, loop: true, album: album.name, t)
            }
            if button(ctx, CGRect(x: L + W - 40, y: T + 84, width: 32, height: 16), "Back") || keys.contains(51) { openAlbum = nil; scroll = 0 }
            let list = CGRect(x: L + 8, y: T + 104, width: W - 16, height: H - 112)
            fill(ctx, list, 0xFF8B8B8B)
            let row: CGFloat = 11
            let maxScroll = max(0, CGFloat(album.tracks.count) * row - list.height)
            if let p = pointer, list.contains(p), scrolled != 0 { scroll = min(maxScroll, max(0, scroll - scrolled * 0.5)) }
            ctx.saveGState(); ctx.clip(to: list)
            for (i, track) in album.tracks.enumerated() {
                let y = list.minY + 2 + CGFloat(i) * row - scroll
                guard y > list.minY - row, y < list.maxY else { continue }
                let r = CGRect(x: list.minX, y: y - 1, width: list.width, height: row)
                let now = playing && state["album"] as? String == album.name && clean(track.title) == title
                let hot = pointer.map { r.contains($0) && list.contains($0) } == true
                if hot { fill(ctx, r, 0xFFA0A0A0) }
                text(ctx, clean(track.title), list.minX + 4, y + 1, now ? 0x55FF55 : 0xFFFFFF, shadow: true)
                if hot, pressed != nil, !now { play(album.tracks, index: i, loop: true, album: album.name, t) }
            }
            ctx.restoreGState()
            if let p = pointer, !tip.isEmpty { tooltip(ctx, tip, p, w, h) }
            let window = CGRect(x: L, y: T, width: W, height: H)
            if keys.contains(53) || (pressed.map { !window.contains($0) } ?? false) || t > 590 {
                emit(["played": played, "discs": Array(discs)])
                finished = true
            }
            endFrame()
            return
        }

        // The discs, then the soundtrack by where it plays in the game.
        text(ctx, "Music Discs", L + 8, T + 86, 0x404040)
        let current = state["icon"] as? String ?? ""
        for i in 0..<27 {
            let s = Slot(x: CGFloat(8 + 18 * (i % 9)), y: CGFloat(97 + 18 * (i / 9)))
            sprite(ctx, "gui/sprites/container/slot.png", L + s.x - 1, T + s.y - 1)
            guard i < library.discs.count else { continue }
            let disc = library.discs[i]
            let inside = playing && current == disc.icon
            if !inside { item(ctx, disc.icon, L + s.x, T + s.y) }
            if over(s, L, T) {
                fill(ctx, CGRect(x: L + s.x, y: T + s.y, width: 16, height: 16), 0x80FFFFFF)
                tip = [("Music Disc", 0x55FFFF), (clean(disc.title), 0xAAAAAA)]
                if pressed != nil, !inside { play([disc], index: 0, loop: false, album: "", t) }
            }
        }
        text(ctx, "Soundtrack", L + 8, T + 153, 0x404040)
        for i in 0..<9 {
            let s = Slot(x: CGFloat(8 + 18 * i), y: 164)
            sprite(ctx, "gui/sprites/container/slot.png", L + s.x - 1, T + s.y - 1)
            guard i < library.albums.count else { continue }
            let album = library.albums[i]
            let inside = playing && state["album"] as? String == album.name
            if !inside { item(ctx, album.icon, L + s.x, T + s.y) }
            if over(s, L, T) {
                fill(ctx, CGRect(x: L + s.x, y: T + s.y, width: 16, height: 16), 0x80FFFFFF)
                tip = [(album.name, 0xFFFFFF), ("\(album.tracks.count) tracks", 0xAAAAAA), ("Click to choose one", 0x55FF55)]
                if pressed != nil { openAlbum = i; scroll = 0; playSound("click", volume: 0.25) }
            }
        }
        if library.discs.isEmpty, library.albums.isEmpty {
            centered(ctx, "No Minecraft install was found to read the music from.", w / 2, T + H + 8, 0xFFFFFF)
        }

        if let p = pointer, !tip.isEmpty { tooltip(ctx, tip, p, w, h) }
        let window = CGRect(x: L, y: T, width: W, height: H)
        if keys.contains(53) || keys.contains(14) || (pressed.map { !window.contains($0) } ?? false) || t > 590 {
            emit(["played": played, "discs": Array(discs)])
            finished = true
        }
        endFrame()
    }
}
