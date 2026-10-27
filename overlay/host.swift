// The host: the app Claude Code runs in (the desktop app, a terminal, an
// editor). A screen is drawn over its front window, not the whole display, in
// the same layer just above it: another app brought forward covers both, and
// the screen is still there when the host comes back. Moments (toasts, the
// totem) are not bound: they play across the display whatever is in front.

import AppKit

/// The host apps of the Claude processes using this helper, by pid.
var hostApps: Set<pid_t> = []

/// The app a Claude process runs under: its furthest ancestor that is a regular
/// app (the desktop app, not the CLI bundled inside it). Nil under tmux or ssh.
func hostApp(of pid: pid_t) -> pid_t? {
    var found: pid_t? = nil
    var p = pid
    for _ in 0..<16 {
        guard p > 1, let info = processInfo(p) else { break }
        if NSRunningApplication(processIdentifier: p)?.activationPolicy == .regular { found = p }
        p = info.parent
    }
    return found
}

/// The host app in front, if one is.
func frontHost() -> pid_t? {
    guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, hostApps.contains(front) else { return nil }
    return front
}

/// An app's front window on screen: its number, and its frame in Cocoa's coordinates.
/// Nil when it has none (minimised, hidden, on another Space).
func appWindow(_ pid: pid_t) -> (number: Int, rect: NSRect)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    let primary = NSScreen.screens.first?.frame.height ?? 0
    // Front to back: the first ordinary window big enough to hold a screen.
    for w in list where (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 {
        guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b), r.width >= 320, r.height >= 240,
              let number = (w[kCGWindowNumber as String] as? NSNumber)?.intValue else { continue }
        return (number, NSRect(x: r.minX, y: primary - r.maxY, width: r.width, height: r.height))
    }
    return nil
}

/// Where a screen is drawn: over the host's front window, or the whole display
/// under the pointer when there is no host window to follow.
struct Spot {
    let app: pid_t?
    let window: Int
    let rect: NSRect
}

/// The spot for this app's window; with no app, the front host's, or the first host's.
func spot(for app: pid_t? = nil) -> Spot {
    let target = app ?? frontHost() ?? hostApps.sorted().first
    if let target, let w = appWindow(target) { return Spot(app: target, window: w.number, rect: w.rect) }
    return Spot(app: nil, window: 0, rect: currentScreen().frame)
}

/// Covers a display with the window and its view, at this GUI scale.
func place(_ window: NSWindow, _ view: OverlayView, on display: NSScreen, gui: CGFloat) {
    place(window, view, at: Spot(app: nil, window: 0, rect: display.frame), gui: gui)
}

/// Covers a spot with the window and its view, at this GUI scale.
func place(_ window: NSWindow, _ view: OverlayView, at spot: Spot, gui: CGFloat) {
    if window.frame != spot.rect { window.setFrame(spot.rect, display: false) }
    if view.frame.size != spot.rect.size { view.frame = NSRect(origin: .zero, size: spot.rect.size) }
    view.gui = gui
}

/// A screen's window over the host's window: in the host's own layer, so other apps
/// can come in front of both. With no host to follow, above everything, as moments are.
func layer(_ window: NSWindow, _ spot: Spot) {
    if spot.app != nil {
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
    } else {
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

/// A screen kept over its host's window as that moves or resizes. Looked at ten
/// times a second, not every frame: reading the window list takes a millisecond or two.
final class Binding {
    private(set) var at: Spot
    private var checked = CACurrentMediaTime()
    private var hostWasFront: Bool
    /// The host's window is gone (minimised, hidden, another Space): the screen waits, unseen.
    private var away = false

    init(_ at: Spot) {
        self.at = at
        hostWasFront = at.app != nil && frontHost() == at.app
    }

    /// Puts the screen just above the host's window, without bringing either forward.
    func raise(_ window: NSWindow) {
        guard at.app != nil else { return }
        window.order(.above, relativeTo: at.window)
    }

    /// Follows the window of the host the screen opened on.
    func update(_ window: NSWindow, _ view: OverlayView) {
        let now = CACurrentMediaTime()
        guard now - checked >= 0.1 else { return }
        checked = now
        guard let host = at.app else { return }
        let next = spot(for: host)
        guard next.app != nil else {
            if !away { away = true; window.orderOut(nil) }
            return
        }
        at = next
        place(window, view, at: at, gui: view.gui)
        let hostFront = frontHost() == host
        if away { away = false; raise(window) }
        // The host brought forward again (its Dock icon, Command-Tab): the screen comes up with it and takes the keys back.
        if hostFront, !hostWasFront {
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
        hostWasFront = hostFront
    }
}
