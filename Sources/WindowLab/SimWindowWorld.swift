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
        /// Optional fixed aspect ratio (width / height). Models apps like
        /// QuickTime Player whose movie window refuses a width that cannot fit the
        /// requested height while preserving the media aspect ratio.
        var fixedAspectRatio: CGFloat?
        var minimized: Bool
        var fullscreen: Bool
        var hasCloseButton: Bool
        /// The native macOS Space (Mission Control "Desktop") this window lives
        /// on, modeled as an opaque integer id. A window appears in the
        /// WindowServer on-screen list (`cgWindows(onscreenOnly:true)`) ONLY
        /// while its Space is the active one, mirroring how
        /// `CGWindowListCopyWindowInfo(onScreenOnly)` reports only the current
        /// Space. It still exists in AX (`allWindows`/`windows(forPID:)`) on any
        /// Space, exactly like a real window. Defaults to the world's active
        /// Space at creation, so a test that never models Spaces behaves
        /// identically (every window is on Space 1, which is active).
        var nativeSpace: Int
        var alive: Bool = true
        /// Wall-clock time before which this window is WITHHELD from the
        /// WindowServer on-screen list, even though it already exists in AX.
        /// Models the real `kAXWindowCreated`-beats-WindowServer-publish race: a
        /// just-created window is readable via AX a few frames before it appears
        /// on-screen. Zero (the default) means "published immediately".
        var cgPublishAt: TimeInterval = 0
        /// Test-only divergence between the AX frame and the WindowServer (CG)
        /// bounds for this window. Real macOS reads AX (`allWindows`) and CG
        /// (`CGWindowListCopyWindowInfo`) in SEPARATE syscalls a frame or more
        /// apart, so while a window is mid-move/park the two snapshots disagree
        /// by more than the fusion threshold (> 8px). The base sim derives both
        /// from `frame`, so it cannot reproduce that race on its own; this offset
        /// shifts ONLY the reported CG bounds (origin + size deltas), modeling a
        /// churning window whose CG row lags its AX frame. Zero = perfectly
        /// agreeing snapshots (the default).
        var cgFrameOffset: CGRect = .zero

        init(id: Int, pid: pid_t, appName: String, title: String,
             role: String, subrole: String, frame: CGRect, minSize: CGSize,
             fixedAspectRatio: CGFloat?,
             minimized: Bool, fullscreen: Bool, hasCloseButton: Bool,
             nativeSpace: Int) {
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
            self.fixedAspectRatio = fixedAspectRatio
            self.minimized = minimized
            self.fullscreen = fullscreen
            self.hasCloseButton = hasCloseButton
            self.nativeSpace = nativeSpace
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

    /// The native macOS Space (Mission Control "Desktop") the user is currently
    /// VIEWING, as an opaque integer id. Only windows whose `nativeSpace`
    /// matches this appear in the on-screen list `cgWindows(onscreenOnly:true)`,
    /// mirroring real macOS where `CGWindowListCopyWindowInfo(onScreenOnly)`
    /// reports only the current Space. New windows default to this Space, so any
    /// test that never calls the Space API sees one Space (id 1) that is always
    /// active - byte-identical to the pre-Space behavior. Switch it with
    /// `setActiveSpace(_:)`. Read-only access via `activeSpace`.
    private var activeSpaceID: Int = 1
    /// Fired (on the main queue) AFTER the active Space changes, mirroring
    /// `NSWorkspace.activeSpaceDidChangeNotification`. ScrollWM does NOT observe
    /// that today (it infers the Space by intersecting AX with the on-screen
    /// list), so this hook lets Track 1 prototype/assert a real Space-change
    /// signal headlessly. Nil (the default) = no observer, exactly like prod.
    private var onActiveSpaceChanged: ((_ space: Int) -> Void)?

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
                   fixedAspectRatio: CGFloat? = nil,
                   role: String = kAXWindowRole as String,
                   subrole: String = kAXStandardWindowSubrole as String,
                   minimized: Bool = false, fullscreen: Bool = false,
                   hasCloseButton: Bool = true,
                   appName: String? = nil,
                   notify: Bool = false,
                   cgPublishDelay: TimeInterval = 0,
                   nativeSpace: Int? = nil) -> AXUIElement {
        lock.lock()
        let id = nextID; nextID += 1
        let win = Win(id: id, pid: pid, appName: appName ?? "Sim-\(pid)",
                      title: title, role: role, subrole: subrole,
                      frame: frame, minSize: minSize,
                      fixedAspectRatio: fixedAspectRatio,
                      minimized: minimized, fullscreen: fullscreen,
                      hasCloseButton: hasCloseButton,
                      // Default a new window onto the Space the user is viewing,
                      // exactly like opening one in real macOS. An explicit
                      // `nativeSpace` models "opened on another Space" (e.g. an
                      // app restoring a window onto its origin Desktop).
                      nativeSpace: nativeSpace ?? activeSpaceID)
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

    // MARK: - Native macOS Spaces (test-facing)
    //
    // A MINIMAL, additive model of Mission Control "Desktops"/Spaces, owned by
    // Track 5 so Tracks 1/4 can model Space membership + switching headlessly.
    // The single fidelity that matters to the engine: the WindowServer on-screen
    // list (`cgWindows(onscreenOnly:true)`) shows ONLY windows on the ACTIVE
    // Space, so a managed window that ends up on another Space silently drops
    // out of the current-Space set (driving `ResyncPlanner.frozenDifferentSpace`
    // and `arrange`/`fastAdopt` scoping) WITHOUT touching its AX existence,
    // minimized, or hidden state. Real `CGWindowListCopyWindowInfo(onScreenOnly)`
    // behaves exactly this way; `setAppHidden` (the only prior lever) had to
    // also flip app-hidden state, which the engine treats differently.

    /// The native Space the user is currently VIEWING (read-only). Defaults to 1.
    var activeSpace: Int { lock.lock(); defer { lock.unlock() }; return activeSpaceID }

    /// `WindowBackend` Space-id probe: the modeled active Space, so the per-Space
    /// strip logic runs against the sim exactly as it would against the live CGS
    /// query. Set `spaceIDProbeUnavailable` to model a machine/OS where the
    /// private symbol is missing (the controller must then stay single-strip).
    func currentSpaceID() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return spaceIDProbeUnavailable ? nil : activeSpaceID
    }

    /// Test lever: when true, `currentSpaceID()` returns nil, modeling a host
    /// where the read-only CGS Space-id symbol could not be resolved. Lets a
    /// headless test prove the graceful single-strip fallback.
    var spaceIDProbeUnavailable = false

    /// The native Space a window currently lives on, or nil if unknown.
    func nativeSpace(of element: AXUIElement) -> Int? {
        lock.lock(); defer { lock.unlock() }; return find(element)?.nativeSpace
    }

    /// Move a sim window to native Space `space` WITHOUT moving its frame. While
    /// `space != activeSpace` the window vanishes from the on-screen list (other
    /// Space) but still exists in AX, modeling "send window to another Desktop"
    /// and a window that lives on its origin Space while the user is elsewhere.
    func setNativeSpace(_ element: AXUIElement, _ space: Int) {
        lock.lock(); find(element)?.nativeSpace = space; lock.unlock()
    }

    /// Test-only: place a window's frame VERBATIM, bypassing the off-screen
    /// clamp and min-size/aspect logic that `setPosition`/`setSize` apply. Models
    /// the user DRAGGING a window anywhere on the desktop - including fully onto
    /// another monitor - which macOS allows (the clamp only fires for positions
    /// that would leave NO part of the window on any display). Used by the
    /// drag-off-display eviction test to relocate a managed window onto the
    /// external display exactly as a user would.
    func debugSetFrame(_ element: AXUIElement, _ frame: CGRect) {
        lock.lock(); find(element)?.frame = frame; lock.unlock()
    }

    /// Inject a test-only AX-vs-CG snapshot divergence for one window (the GATE-C
    /// churn race). `offset` shifts ONLY the reported CG bounds relative to the AX
    /// frame: `offset.origin` moves the CG origin, `offset.size` deltas its size.
    /// Pass `.zero` to clear. Used to prove the motion-invariant fusion fallback
    /// still recognizes a moved-but-present current-Space window.
    func setCGFrameOffset(_ element: AXUIElement, _ offset: CGRect) {
        lock.lock(); find(element)?.cgFrameOffset = offset; lock.unlock()
    }

    /// Switch the active native Space (Ctrl+Left/Right, Mission Control, or a
    /// fullscreen-Space toggle). Windows on `space` now appear on-screen; windows
    /// on the previously-active Space drop out of the on-screen list. Fires the
    /// `activeSpaceDidChange` hook (async on main) AFTER the switch, mirroring
    /// `NSWorkspace.activeSpaceDidChangeNotification`. No-op (and no fire) when
    /// already on `space`, matching macOS coalescing identical transitions.
    func setActiveSpace(_ space: Int) {
        lock.lock()
        guard space != activeSpaceID else { lock.unlock(); return }
        activeSpaceID = space
        let hook = onActiveSpaceChanged
        lock.unlock()
        // Post the REAL public notification too, so the production
        // `LifecycleMonitor` observer (which listens for
        // `activeSpaceDidChangeNotification` on `NSWorkspace.shared`) fires under
        // the headless backend exactly as it would on a live Space switch. This
        // is what lets headless tests exercise the shipped Space-signal wiring,
        // not just the explicit `subscribeActiveSpace` hook.
        DispatchQueue.main.async {
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.activeSpaceDidChangeNotification,
                object: NSWorkspace.shared)
            hook?(space)
        }
    }

    /// All distinct native Space ids that currently have at least one window,
    /// plus the active Space (which may legitimately be empty). For assertions.
    func knownSpaces() -> Set<Int> {
        lock.lock(); defer { lock.unlock() }
        var s = Set(wins.map { $0.nativeSpace }); s.insert(activeSpaceID); return s
    }

    /// Subscribe to active-Space changes (the headless stand-in for
    /// `NSWorkspace.activeSpaceDidChangeNotification`). The closure runs on the
    /// main queue AFTER each `setActiveSpace` that actually changed the Space.
    /// Pass nil to unsubscribe. Independent of the window create/destroy sinks.
    func subscribeActiveSpace(_ handler: ((_ space: Int) -> Void)?) {
        lock.lock(); onActiveSpaceChanged = handler; lock.unlock()
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
        // WindowServer publish lag after `kAXWindowCreated`. A window on a
        // NON-ACTIVE native Space is likewise absent from the on-screen list -
        // `CGWindowListCopyWindowInfo(onScreenOnly)` only reports the Space the
        // user is viewing - while still existing in AX. This is the single
        // fidelity that drives Space-freeze / cross-Space adoption scoping.
        return wins.compactMap { w -> CGWindowInfo? in
            if onscreenOnly && (w.minimized || hiddenApps.contains(w.pid)) { return nil }
            if onscreenOnly && w.cgPublishAt > now { return nil }
            if onscreenOnly && w.nativeSpace != activeSpaceID { return nil }
            nextCGID += 1
            // Apply the test-only AX-vs-CG divergence: the reported CG bounds are
            // the AX frame shifted by `cgFrameOffset` (origin + size), modeling a
            // churning window whose WindowServer row lags its AX frame.
            let o = w.cgFrameOffset
            let cgBounds = CGRect(
                x: w.frame.origin.x + o.origin.x,
                y: w.frame.origin.y + o.origin.y,
                width: w.frame.width + o.size.width,
                height: w.frame.height + o.size.height
            )
            return CGWindowInfo(
                windowID: nextCGID, ownerPID: w.pid, ownerName: w.appName,
                title: w.title, bounds: cgBounds, layer: 0, alpha: 1.0,
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

    /// Total real `setPosition` calls the engine issued (test introspection).
    /// Counts cross-process AX position writes so a test can prove a redundant
    /// display change does NOT re-move every window.
    private(set) var setPositionCount = 0
    /// Total real `setSize` calls the engine issued (test introspection).
    private(set) var setSizeCount = 0
    /// Reset both write counters to zero (call before a measured operation).
    func resetWriteCounters() {
        lock.lock(); setPositionCount = 0; setSizeCount = 0; lock.unlock()
    }

    func setPosition(_ element: AXUIElement, _ point: CGPoint) -> AXError {
        lock.lock(); defer { lock.unlock() }
        guard let w = find(element) else { return .invalidUIElement }
        setPositionCount += 1
        w.frame.origin = clamp(origin: point, size: w.frame.size)
        return .success
    }

    /// When > 0, `setSize` does NOT apply immediately: AX returns `.success`
    /// (as real apps do) but the new frame only lands after this many seconds,
    /// modeling apps that resize ASYNCHRONOUSLY. The immediate readback then
    /// reports the OLD size, exactly like production, so tests can exercise the
    /// engine's `scheduleWidthReconcile` follow-up. Zero = synchronous (default).
    var asyncResizeDelay: TimeInterval = 0

    /// When true, `setSize` is additionally CONSTRAINED so the window cannot
    /// grow past the right/bottom edge of the display it currently sits on,
    /// modeling macOS/AppKit's `constrainFrameRect`: a window anchored near a
    /// display's right edge can only widen until its right edge reaches that
    /// edge, NOT to an arbitrary requested width. This reproduces the real
    /// "grow a right-side window to 100% and it only fills to the screen edge"
    /// bug, so the engine must REPOSITION the window left (giving the full width
    /// room) BEFORE resizing. Off by default (and requires `displays`) so suites
    /// that don't exercise it - including the unconstrained async-resize test -
    /// are unaffected. The min-size / aspect clamps still apply on top.
    var constrainResizeToDisplay = false

    func setSize(_ element: AXUIElement, _ size: CGSize) -> AXError {
        lock.lock(); defer { lock.unlock() }
        guard let w = find(element) else { return .invalidUIElement }
        setSizeCount += 1
        // Apps clamp to their own minimum while AX still reports success — the
        // central reason the engine always reads back the REAL frame.
        var clamped = CGSize(
            width: max(size.width, w.minSize.width),
            height: max(size.height, w.minSize.height)
        )
        if let ratio = w.fixedAspectRatio, ratio > 0, clamped.height > 0 {
            // Preserve aspect ratio inside the requested bounding size. This makes
            // a width-only grow request fail/stay small when the paired height is
            // too short, reproducing QuickTime-style behavior.
            let boundedWidth = min(clamped.width, clamped.height * ratio)
            clamped = CGSize(width: boundedWidth, height: boundedWidth / ratio)
        }
        // macOS keeps a window within its display's visible frame: from a fixed
        // origin it can only grow until its right/bottom edge meets the display
        // edge. Apply AFTER the min/aspect clamps (a window must still honor its
        // hard minimum even if that overflows the edge).
        if constrainResizeToDisplay, let d = displayContaining(w.frame.origin) {
            let maxW = Swift.max(w.minSize.width, d.maxX - w.frame.origin.x)
            let maxH = Swift.max(w.minSize.height, d.maxY - w.frame.origin.y)
            clamped.width = Swift.min(clamped.width, maxW)
            clamped.height = Swift.min(clamped.height, maxH)
        }
        if asyncResizeDelay > 0 {
            // Apply LATER so the immediate readback is stale (real async resize).
            let el = w.element
            DispatchQueue.main.asyncAfter(deadline: .now() + asyncResizeDelay) { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.find(el)?.frame.size = clamped; self.lock.unlock()
            }
        } else {
            w.frame.size = clamped
        }
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
        activateAppCalls.append(pid)
        if focused?.pid != pid {
            // Activating an app focuses its frontmost managed window if we have
            // not already focused one in it.
            focused = wins.first { $0.pid == pid } ?? focused
        }
        lock.unlock()
    }

    /// Every pid the engine asked to activate, in order (test introspection).
    /// The Space-focus guard must NOT activate an app whose target window is on
    /// another native Space (that would teleport the user); this spy proves it.
    private(set) var activateAppCalls: [pid_t] = []
    /// Clear the activate spy (call before a measured focus operation).
    func resetActivateSpy() { lock.lock(); activateAppCalls.removeAll(); lock.unlock() }

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

    /// The configured display whose visible frame contains `origin` (the
    /// window's top-left), or the one whose right edge is nearest when the
    /// origin sits in a gap. Used by the resize-constraint model to know which
    /// edge a window can grow toward. Nil only when no displays are configured.
    private func displayContaining(_ origin: CGPoint) -> CGRect? {
        if let hit = displays.first(where: { $0.contains(origin) }) { return hit }
        return displays.min { abs($0.minX - origin.x) < abs($1.minX - origin.x) }
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
