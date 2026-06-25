import Foundation
import ApplicationServices
import AppKit

/// In-memory window world: a headless stand-in for the real Accessibility /
/// WindowServer stack. Installing one as `AXSource.backend` makes the EXACT
/// production engine + controller logic run with NO real windows: nothing is
/// spawned, moved, focused, closed, or hidden on the user's actual desktop, and
/// no global keystrokes are ever injected.
///
/// Why this exists: ScrollWM moves the user's live windows, so its integration
/// tests historically spawned real (visible) windows, teleported them, and stole
/// keyboard focus via `app.activate()` — disruptive to run while working. The
/// sim lets those same tests assert real behavior fully headless.
///
/// Fidelity modeled (everything the engine actually depends on):
///   - one element token per window (CFEqual-stable, even for two windows in the
///     same pid, exactly like real AXUIElements);
///   - app size MINIMUMS: `setSize` below a window's hard minimum is clamped and
///     still reports `.success`, reproducing apps (Music, Discord) that refuse to
///     shrink while AX lies that the write worked;
///   - the WindowServer ON-SCREEN list (current Space): minimized / app-hidden
///     windows drop out of `cgWindows`, so `arrange`/`resync` skip them;
///   - the macOS OFF-SCREEN CLAMP: a window pushed far past a display edge keeps
///     a ~`clampMargin` px sliver visible (drives the parking-corner tests);
///   - system keyboard FOCUS (raise + AXFocused + activate), so the
///     "Cmd+Q closes the OS-focused window" sync logic is exercised;
///   - kAXWindowCreated / kAXUIElementDestroyed events, delivered to the
///     `WindowEventObserver` fast path so adoption-latency logic still runs.
final class SimWindowWorld: WindowBackend {

    final class Win {
        let id: Int
        let pid: pid_t
        let element: AXUIElement
        var appName: String
        var title: String
        var role: String
        var subrole: String
        var frame: CGRect
        /// Hard minimum the "app" enforces; `setSize` never shrinks below it.
        var minSize: CGSize
        var minimized: Bool
        var fullscreen: Bool
        var hasCloseButton: Bool
        var alive: Bool = true
        /// Wall-clock time before which this window is WITHHELD from the
        /// WindowServer on-screen list, even though it already exists in AX.
        /// Models the real `kAXWindowCreated`-beats-WindowServer-publish race: a
        /// just-created window is readable via AX a few frames before it appears
        /// on-screen. Zero (the default) means "published immediately".
        var cgPublishAt: TimeInterval = 0

        init(id: Int, pid: pid_t, appName: String, title: String,
             role: String, subrole: String, frame: CGRect, minSize: CGSize,
             minimized: Bool, fullscreen: Bool, hasCloseButton: Bool) {
            self.id = id
            self.pid = pid
            // A unique CFEqual-stable token per window. Using a per-window fake
            // "pid" as the element handle gives distinct identities even for two
            // windows owned by the same real pid (mirrors real AXUIElement).
            self.element = AXUIElementCreateApplication(pid_t(id))
            self.appName = appName
            self.title = title
            self.role = role
            self.subrole = subrole
            self.frame = frame
            self.minSize = minSize
            self.minimized = minimized
            self.fullscreen = fullscreen
            self.hasCloseButton = hasCloseButton
        }

        var info: AXWindowInfo {
            AXWindowInfo(
                pid: pid, appName: appName, element: element,
                title: title, role: role, subrole: subrole,
                frame: frame, isMinimized: minimized, isFullscreen: fullscreen
            )
        }
    }

    private let lock = NSLock()
    private var wins: [Win] = []
    private var hiddenApps: Set<pid_t> = []
    private var focused: Win?
    private var nextID = 700_001
    private var nextCGID: CGWindowID = 9_000_001

    /// Displays (AX top-left global coords) used ONLY for the off-screen clamp
    /// that models macOS keeping a sliver of a parked window visible. Empty (the
    /// default) disables clamping — fine for tests that never park windows.
    var displays: [CGRect] = []
    /// Pixels of a parked window macOS keeps visible at the nearest display edge.
    var clampMargin: CGFloat = 40

    /// Window-event sinks (set by `WindowEventObserver` in headless mode), so a
    /// window created/destroyed AFTER subscription drives the fast-adopt path.
    private var onCreated: ((Set<pid_t>) -> Void)?
    private var onDestroyed: (() -> Void)?

    // MARK: - Test-facing mutation

    /// Add a window to the world. Returns its element token. When `notify` is
    /// true and an observer is subscribed, fires a created event (the new-window
    /// fast path) so the strip adopts it like a real `kAXWindowCreated`.
    ///
    /// `cgPublishDelay` models the real WindowServer-publish race: for that many
    /// seconds after creation the window is readable via AX (so the fast-adopt
    /// path "sees" it) but is WITHHELD from the on-screen list (so the
    /// current-Space gate fails), exactly like a just-opened real window. The
    /// fast-adopt retry must bridge that gap; zero (the default) publishes the
    /// window immediately, preserving every existing test's behavior.
    @discardableResult
    func addWindow(pid: pid_t, title: String, frame: CGRect,
                   minSize: CGSize = .zero,
                   role: String = kAXWindowRole as String,
                   subrole: String = kAXStandardWindowSubrole as String,
                   minimized: Bool = false, fullscreen: Bool = false,
                   hasCloseButton: Bool = true,
                   appName: String? = nil,
                   notify: Bool = false,
                   cgPublishDelay: TimeInterval = 0) -> AXUIElement {
        lock.lock()
        let id = nextID; nextID += 1
        let win = Win(id: id, pid: pid, appName: appName ?? "Sim-\(pid)",
                      title: title, role: role, subrole: subrole,
                      frame: frame, minSize: minSize,
                      minimized: minimized, fullscreen: fullscreen,
                      hasCloseButton: hasCloseButton)
        if cgPublishDelay > 0 {
            win.cgPublishAt = Date().timeIntervalSinceReferenceDate + cgPublishDelay
        }
        wins.append(win)
        let sink = onCreated
        lock.unlock()
        if notify, let sink {
            DispatchQueue.main.async { sink([pid]) }
        }
        return win.element
    }

    /// Remove (destroy) a window, as if its app closed it. Fires a destroyed
    /// event so the strip drops the column via the fast path.
    func destroyWindow(_ element: AXUIElement, notify: Bool = true) {
        lock.lock()
        if let w = find(element) { w.alive = false; wins.removeAll { $0 === w } }
        let sink = onDestroyed
        lock.unlock()
        if notify, let sink { DispatchQueue.main.async { sink() } }
    }

    /// Programmatically focus a window (models a user click / Cmd-Tab landing on
    /// it) without going through the engine, so focus-sync logic can be tested.
    func setSystemFocus(_ element: AXUIElement) {
        lock.lock(); focused = find(element); lock.unlock()
    }

    func setMinimized(_ element: AXUIElement, _ value: Bool) {
        lock.lock(); find(element)?.minimized = value; lock.unlock()
    }

    func setAppHidden(_ pid: pid_t, _ value: Bool) {
        lock.lock(); if value { hiddenApps.insert(pid) } else { hiddenApps.remove(pid) }; lock.unlock()
    }

    /// Snapshot of every live window (for assertions). Thread-safe copy.
    func snapshot() -> [Win] { lock.lock(); defer { lock.unlock() }; return wins }

    func frame(of element: AXUIElement) -> CGRect? {
        lock.lock(); defer { lock.unlock() }; return find(element)?.frame
    }

    // MARK: - Event subscription (used by WindowEventObserver headless path)

    func subscribeEvents(created: @escaping (Set<pid_t>) -> Void,
                         destroyed: @escaping () -> Void) {
        lock.lock(); onCreated = created; onDestroyed = destroyed; lock.unlock()
    }
    func unsubscribeEvents() {
        lock.lock(); onCreated = nil; onDestroyed = nil; lock.unlock()
    }

    // MARK: - WindowBackend (read)

    func windows(forPID pid: pid_t) -> [AXWindowInfo] {
        lock.lock(); defer { lock.unlock() }
        return wins.filter { $0.pid == pid }.map { $0.info }
    }

    func allWindows() -> [AXWindowInfo] {
        lock.lock(); defer { lock.unlock() }
        return wins.map { $0.info }
    }

    func cgWindows(onscreenOnly: Bool) -> [CGWindowInfo] {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSinceReferenceDate
        // The WindowServer on-screen list = current-Space, visible windows. A
        // minimized or app-hidden window is NOT on screen, so it drops out here
        // (which is exactly what makes `arrange`/`resync` skip them). A window
        // still within its `cgPublishAt` window is withheld too, modeling the
        // WindowServer publish lag after `kAXWindowCreated`.
        return wins.compactMap { w -> CGWindowInfo? in
            if onscreenOnly && (w.minimized || hiddenApps.contains(w.pid)) { return nil }
            if onscreenOnly && w.cgPublishAt > now { return nil }
            nextCGID += 1
            return CGWindowInfo(
                windowID: nextCGID, ownerPID: w.pid, ownerName: w.appName,
                title: w.title, bounds: w.frame, layer: 0, alpha: 1.0,
                isOnscreen: true, memoryUsage: 0
            )
        }
    }

    func regularAppPIDs() -> [pid_t] {
        lock.lock(); defer { lock.unlock() }
        return Array(Set(wins.map { $0.pid }))
    }

    func position(of element: AXUIElement) -> CGPoint? {
        lock.lock(); defer { lock.unlock() }; return find(element)?.frame.origin
    }
    func size(of element: AXUIElement) -> CGSize? {
        lock.lock(); defer { lock.unlock() }; return find(element)?.frame.size
    }

    // MARK: - WindowBackend (write)

    func setPosition(_ element: AXUIElement, _ point: CGPoint) -> AXError {
        lock.lock(); defer { lock.unlock() }
        guard let w = find(element) else { return .invalidUIElement }
        w.frame.origin = clamp(origin: point, size: w.frame.size)
        return .success
    }

    func setSize(_ element: AXUIElement, _ size: CGSize) -> AXError {
        lock.lock(); defer { lock.unlock() }
        guard let w = find(element) else { return .invalidUIElement }
        // Apps clamp to their own minimum while AX still reports success — the
        // central reason the engine always reads back the REAL frame.
        w.frame.size = CGSize(
            width: max(size.width, w.minSize.width),
            height: max(size.height, w.minSize.height)
        )
        return .success
    }

    func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> AXError {
        lock.lock(); defer { lock.unlock() }
        guard let w = find(element) else { return .invalidUIElement }
        switch attribute {
        case kAXFocusedAttribute as String:
            if value { focused = w }
        case kAXMinimizedAttribute as String:
            w.minimized = value
        default:
            break // kAXMain etc. — no observable state needed
        }
        return .success
    }

    func raise(_ element: AXUIElement) -> AXError {
        lock.lock(); defer { lock.unlock() }
        guard find(element) != nil else { return .invalidUIElement }
        return .success
    }

    func pressCloseButton(_ element: AXUIElement) -> Bool {
        lock.lock()
        guard let w = find(element), w.hasCloseButton else { lock.unlock(); return false }
        w.alive = false
        wins.removeAll { $0 === w }
        if focused === w { focused = nil }
        let sink = onDestroyed
        lock.unlock()
        if let sink { DispatchQueue.main.async { sink() } }
        return true
    }

    func systemFocusedWindow() -> AXUIElement? {
        lock.lock(); defer { lock.unlock() }
        return (focused?.alive == true) ? focused?.element : nil
    }

    func activateApp(pid: pid_t) {
        // Record focus only; never steal the user's real keyboard focus.
        lock.lock()
        if focused?.pid != pid {
            // Activating an app focuses its frontmost managed window if we have
            // not already focused one in it.
            focused = wins.first { $0.pid == pid } ?? focused
        }
        lock.unlock()
    }

    func appIsHidden(pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }; return hiddenApps.contains(pid)
    }

    func unhideApp(pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard hiddenApps.contains(pid) else { return false }
        hiddenApps.remove(pid)
        return true
    }

    // MARK: - Internals

    /// Linear CFEqual lookup (window counts are tiny in tests).
    private func find(_ element: AXUIElement) -> Win? {
        wins.first { CFEqual($0.element, element) }
    }

    /// Model the macOS clamp that keeps ~`clampMargin` px of a window on SOME
    /// display. A position far past a display edge is pulled back so a thin
    /// sliver of the window stays visible at the nearest display's edge (the
    /// parking behavior). macOS keeps the window on a SINGLE physical display
    /// (never floating in the dead space between two), so we clamp against the
    /// display whose clamped result sits closest to the requested origin, not
    /// the union bounding box. With no displays configured the origin is verbatim.
    private func clamp(origin: CGPoint, size: CGSize) -> CGPoint {
        guard !displays.isEmpty else { return origin }
        func clampTo(_ d: CGRect) -> CGPoint {
            // Keep at least `clampMargin` px visible on display `d` at every edge.
            let minX = d.minX - (size.width - clampMargin)
            let maxX = d.maxX - clampMargin
            let minY = d.minY - (size.height - clampMargin)
            let maxY = d.maxY - clampMargin
            return CGPoint(
                x: Swift.min(Swift.max(origin.x, minX), maxX),
                y: Swift.min(Swift.max(origin.y, minY), maxY)
            )
        }
        // If the window already overlaps a display at its requested origin, leave
        // it (it is on-screen). Otherwise pull it onto the nearest display.
        let req = CGRect(origin: origin, size: size)
        if displays.contains(where: { $0.intersects(req) }) { return origin }
        // macOS keeps a window on the display its current band points at, never
        // teleporting it diagonally across a gap onto a vertically/horizontally
        // disjoint neighbor. So prefer a display reachable by a PURE single-axis
        // move (dx==0 or dy==0) — e.g. a window shoved straight off the side at
        // its natural y slides back onto the display covering that y-band, not
        // down onto an L-shaped neighbor that merely sticks out horizontally.
        // Only when no pure-axis fix exists (e.g. a window pushed off a corner,
        // off every display's band) do we fall back to the nearest overall.
        var pureBest: (p: CGPoint, dist: CGFloat)?
        var anyBest: (p: CGPoint, dist: CGFloat)?
        for d in displays {
            let c = clampTo(d)
            let dx = c.x - origin.x, dy = c.y - origin.y
            let dist = hypot(dx, dy)
            if anyBest == nil || dist < anyBest!.dist { anyBest = (c, dist) }
            if abs(dx) < 0.5 || abs(dy) < 0.5 {
                if pureBest == nil || dist < pureBest!.dist { pureBest = (c, dist) }
            }
        }
        return (pureBest ?? anyBest)!.p
    }
}
