// The host: the app Claude Code runs in (the desktop app, a terminal, an
// editor). Screens are drawn over its front window, not the whole display, and
// close when another app comes forward. Moments (toasts, the totem) are not
// bound: they play across the display whatever is in front.

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

/// Whether a screen may stay up: a host or the helper is in front, or there is no host to follow. The
/// helper is any copy of it: a screen started cold starts the server, which can be put in front as it launches.
func hostInFront() -> Bool {
    guard !hostApps.isEmpty, frontHost() == nil, let front = NSWorkspace.shared.frontmostApplication else { return true }
    return front.processIdentifier == getpid() || front.executableURL?.lastPathComponent == URL(fileURLWithPath: binPath).lastPathComponent
}

/// An app's front window on screen, in Cocoa's coordinates; nil when it has none (minimised, on another Space).
func appWindow(_ pid: pid_t) -> NSRect? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    let primary = NSScreen.screens.first?.frame.height ?? 0
    // Front to back: the first ordinary window big enough to hold a screen.
    for w in list where (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 {
        guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b), r.width >= 320, r.height >= 240 else { continue }
        return NSRect(x: r.minX, y: primary - r.maxY, width: r.width, height: r.height)
    }
    return nil
}

/// Where a screen is drawn: over the host's front window, or the whole display
/// under the pointer when there is no host window to follow.
struct Spot {
    let app: pid_t?
    let rect: NSRect
}

/// The spot for this app's window; with no app, the front host's, or the first host's.
func spot(for app: pid_t? = nil) -> Spot {
    let target = app ?? frontHost() ?? hostApps.sorted().first
    if let target, let rect = appWindow(target) { return Spot(app: target, rect: rect) }
    return Spot(app: nil, rect: currentScreen().frame)
}

/// Covers a display with the window and its view, at this GUI scale.
func place(_ window: NSWindow, _ view: OverlayView, on display: NSScreen, gui: CGFloat) {
    place(window, view, at: Spot(app: nil, rect: display.frame), gui: gui)
}

/// Covers a spot with the window and its view, at this GUI scale.
func place(_ window: NSWindow, _ view: OverlayView, at spot: Spot, gui: CGFloat) {
    if window.frame != spot.rect { window.setFrame(spot.rect, display: false) }
    if view.frame.size != spot.rect.size { view.frame = NSRect(origin: .zero, size: spot.rect.size) }
    view.gui = gui
}

/// A window kept over its host's window as that moves or resizes. Looked at ten
/// times a second, not every frame: reading the window list takes a millisecond or two.
final class Binding {
    private(set) var at: Spot
    /// Whether a host (or the helper) is in front now, and whether one has been since the window went up.
    private(set) var front: Bool
    private(set) var wasFront: Bool
    private var checked = CACurrentMediaTime()

    init(_ at: Spot) {
        self.at = at
        front = hostInFront()
        wasFront = front
    }

    /// Follows the window of the host the screen opened on.
    func update(_ window: NSWindow, _ view: OverlayView) {
        let now = CACurrentMediaTime()
        guard now - checked >= 0.1 else { return }
        checked = now
        front = hostInFront()
        wasFront = wasFront || front
        // With no host window to begin with, the display stays; one lost for a moment (a Space changing) is waited for.
        guard front, let app = at.app else { return }
        let next = spot(for: app)
        guard next.app != nil else { return }
        at = next
        place(window, view, at: at, gui: view.gui)
    }
}
