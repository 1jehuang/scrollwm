import Foundation
import ApplicationServices
import AppKit

/// Keeps the strip in sync with reality: adopts newly created windows,
/// drops closed ones, reacts to app launch/termination.
///
/// Strategy (validated by `watch`: full resync ~9ms p50):
///   - AX `kAXWindowCreated` observer (see `WindowEventObserver`) -> near
///     instant resync when a window opens in any app, so it is adopted before
///     the user perceives a misplacement (this is the fast path)
///   - NSWorkspace launch/terminate notifications -> resync on app changes
///   - periodic reconciliation every `interval` seconds as the safety net
///     (AX notifications can be missed; polling cannot)
/// Identity: AXUIElement supports CFEqual for the same underlying window.
final class LifecycleMonitor {
    private let engine: TeleportEngine
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var windowEvents: WindowEventObserver?
    private let interval: TimeInterval

    /// Off-main queue for the heavy cross-process AX/CG enumeration, so a slow
    /// app can never hitch the main thread (hotkeys / teleport / menu).
    private let enumerateQueue = DispatchQueue(label: "scrollwm.resync.enumerate", qos: .userInitiated)
    /// True while a background enumeration is in flight (main-thread only).
    /// Coalesces overlapping poll/event triggers into one enumeration.
    private var enumerating = false

    /// Set once `stop()` runs. A `resync()` dispatches its heavy enumeration to a
    /// background queue and hops BACK to main to mutate the engine; if `stop()`
    /// (release / display teardown) lands in that window, the queued main-thread
    /// `applyResync` would re-adopt windows into an engine the controller just
    /// cleared - the "strip not empty after release()" desync. Every deferred
    /// closure (the resync apply, fast-adopt retries, debounced Space resync)
    /// checks this and no-ops once stopped, so a monitor that has been torn down
    /// never touches the engine again.
    private var stopped = false

    /// Settle delay applied to a native Space change before resyncing, so a
    /// burst of `activeSpaceDidChange` edges (rapid Ctrl-arrow, or the
    /// notification firing before the WindowServer on-screen list reflects the
    /// new Space) collapses into ONE resync sampled after the Space committed.
    /// Small enough to feel instant, large enough to clear the transition.
    private let spaceResyncDebounce: TimeInterval = 0.05
    /// Monotonic token so only the latest debounced Space-resync runs; an earlier
    /// scheduled closure whose generation is stale simply no-ops.
    private var spaceResyncGeneration: UInt64 = 0

    /// Fast-adopt retry policy for the kAXWindowCreated -> WindowServer-publish
    /// race. When an app fires `kAXWindowCreated` the window exists in AX
    /// immediately, but the WindowServer's on-screen list (our current-Space
    /// gate) can lag it by a few frames. A single attempt that lost that race
    /// used to bail and leave the window unadopted until the 2s safety-net poll,
    /// which is the visible "new window snaps in late" latency. So `fastAdopt`
    /// re-tries a bounded number of times before giving up to the poll.
    ///
    /// The retry cadence is PROGRESSIVE rather than a flat interval: the common
    /// case is that the WindowServer publishes the window within ~1-2 frames, so
    /// we probe aggressively at first (next runloop turn, then a few ms apart)
    /// to adopt as soon as it lands - shaving the visible "floating then snaps"
    /// gap. CRUCIALLY the tail is FLAT and frame-paced (~16ms), not a widening
    /// geometric back-off: a window that lands LATE (a busy app lagging the
    /// WindowServer publish) is still adopted within ~1 frame of appearing,
    /// never left sitting at its native spot for a coarse back-off gap. The total
    /// budget (~0.36s) still comfortably exceeds any real publish lag while
    /// staying well under the 2s safety-net poll, so a genuinely foreign-Space
    /// window still falls through to the poll harmlessly.
    private static let fastAdoptRetryDelays: [TimeInterval] =
        framePacedRetryCadence(budget: 0.36)

    /// COLD-START retry cadence, used by the app-launch fast path (`onAppLaunched`
    /// -> `fastAdopt(pids:coldStart:true)`). A brand-new process's FIRST window
    /// never fired a per-app create observer (none was attached at creation), so
    /// the launch notification is our only early signal - but the window may not
    /// be readable/published for noticeably longer than the warm publish race
    /// (the process is still spinning up: code-sign check, framework load, first
    /// frame). Same shape as the warm cadence (tight head + FLAT ~16ms tail) so a
    /// window that appears at ANY point is moved within ~1 frame of becoming
    /// visible - the fix for the visible "a new app spawns where macOS puts it,
    /// then jumps into the strip" that the old widening tail (gaps up to 400ms)
    /// caused for a slow-spinning app. The tail extends to ~1.8s total to cover a
    /// slow launch while staying under the 2s safety-net poll.
    private static let coldStartRetryDelays: [TimeInterval] =
        framePacedRetryCadence(budget: 1.8)

    /// Build a fast-adopt retry cadence: a tight HEAD (catch a window published
    /// within a frame or two essentially instantly) followed by a FLAT,
    /// frame-paced (~16ms) tail until `budget` is spent. The flat tail is the key
    /// property: a window that appears LATE (a slow-spinning app's first window,
    /// or a busy app lagging the WindowServer publish) is adopted within ~1 frame
    /// of becoming visible, instead of waiting out a coarse exponential back-off
    /// gap (the visible "spawns at its native spot, then jumps" the old geometric
    /// tail caused). Each tail probe is one cheap scoped `windows(forPID:)` call
    /// and the loop stops the instant the window is adopted, so the full budget
    /// is only ever spent on an app that never produces a window (a hung launch),
    /// which then falls through to the poll. `budget` stays under the 2s poll so
    /// a genuinely foreign-Space window still degrades to the poll harmlessly.
    private static func framePacedRetryCadence(budget: TimeInterval) -> [TimeInterval] {
        let head: [TimeInterval] = [0.004, 0.008, 0.012]
        let frame: TimeInterval = 0.016
        var delays = head
        var total = head.reduce(0, +)
        while total < budget { delays.append(frame); total += frame }
        return delays
    }

    /// Restrict adoption to these PIDs (test mode). Nil = all regular apps.
    var pidFilter: Set<pid_t>? {
        didSet { windowEvents?.pidFilter = pidFilter }
    }

    private(set) var adoptedCount = 0
    private(set) var removedCount = 0
    private(set) var resyncCount = 0
    private(set) var lastResyncMs: Double = 0

    /// Windows open on the user's CURRENT Space that are NOT tiled on the strip
    /// (dialogs, panels, or normal windows not yet adopted). Recomputed every
    /// resync from the same enumeration the diff uses, so it costs nothing
    /// extra. Main-thread only. The menu bar reads this to list "floating"
    /// windows alongside the strip.
    private(set) var floatingWindows: [FloatingWindow] = []

    var onChange: ((_ adopted: Int, _ removed: Int) -> Void)?
    /// Fired (main thread) whenever the floating-window set changes, so the menu
    /// bar / status item can refresh.
    var onFloatingChange: (() -> Void)?

    /// Optional predicate: true if `element` is already managed by ANOTHER
    /// strip's engine (a different monitor's strip). On a multi-display setup the
    /// "floating" set must exclude windows other monitors' strips own, or each
    /// strip would mislabel every other display's tiled window as "floating here"
    /// (and "Tile All Floating" would try to yank them across monitors). The
    /// controller installs it spanning all strips; nil (single-strip / tests)
    /// means "only this engine manages anything", the historical behavior.
    var isManagedElsewhere: ((AXUIElement) -> Bool)?

    /// BENCHMARK-ONLY: when false, the app-launch fast path (`onAppLaunched`) is
    /// suppressed, so a brand-new app's first window is adopted ONLY by the
    /// slower launch-resync / safety-net poll - reproducing the pre-optimization
    /// cold-start behavior for an A/B latency comparison. Always true in
    /// production; the `coldstartbench` harness flips it to measure the baseline.
    var coldStartFastPathEnabled = true

    /// When true (default), windows that appear on this strip's display + Space
    /// are AUTO-TILED onto the strip (the standard PaperWM behavior, and the
    /// "no un-arranged window left in the background" guarantee). When false, a
    /// newly-opened / newly-revealed window is left floating instead of being
    /// pulled onto the strip; the user tiles it on demand from the menu. Pushed
    /// from `config.layout.autoTileNewWindows`. Only the ADD path is gated:
    /// removals, eviction, size-reconcile and fullscreen suspension of EXISTING
    /// columns always run, so managed windows still behave correctly. Dialogs /
    /// panels are never adopted regardless (they are not standard windows).
    var autoTileEnabled = true

    /// When true, this monitor drives the engine's per-native-Space strips: on a
    /// native Space change it asks `SpaceProbe` for the active Space id and tells
    /// the engine to `switchToSpace` BEFORE resyncing, so each Desktop keeps its
    /// own columns/viewport and a window opened on any Space tiles on that Space.
    /// Pushed from `config.layout.perSpaceStrips`; the engine must already be
    /// tracking a Space (`beginSpaceTracking`) for the switch to do anything.
    /// When false (default) the engine ignores Spaces and the historical single-
    /// strip freeze/thaw behavior is unchanged.
    var perSpaceStripsEnabled = false

    /// The physical display this monitor's strip is bound to, so per-Space
    /// tracking keys on the active Space of THIS monitor (not always the main
    /// display) under "Displays have separate Spaces". `nil` falls back to the
    /// main display's Space (single-display / spans-displays). Set by the
    /// controller from the strip's `displayID` when management starts.
    var stripDisplayID: CGDirectDisplayID?

    init(engine: TeleportEngine, interval: TimeInterval = 2.0) {
        self.engine = engine
        self.interval = interval
    }

    /// Re-point the engine's live strip to the native Space THIS monitor's
    /// display is now showing, if per-Space strips are on and the Space actually
    /// changed. Runs on the main thread (mutates engine state). Returns true if it
    /// switched, so a caller can force a layout-changing resync follow-up. A `nil`
    /// Space id (probe unavailable, or tracking not yet started) is a safe no-op:
    /// the engine simply stays on its current strip, degrading to single-strip.
    @discardableResult
    func switchActiveSpaceIfNeeded() -> Bool {
        guard perSpaceStripsEnabled, engine.activeSpaceID != nil,
              let id = SpaceProbe.currentSpaceID(forDisplay: stripDisplayID) else { return false }
        return engine.switchToSpace(id)
    }

    func start() {
        // Fast path: when a window is created we get the firing PIDs, so we can
        // adopt by enumerating ONLY those apps - no all-apps sweep, and immune
        // to unrelated hung apps stalling us. A destroyed event triggers the
        // (cheap, off-main) resync so a closed window's gap closes promptly.
        let events = WindowEventObserver(
            onWindowCreated: { [weak self] pids in self?.fastAdopt(pids: pids) },
            onWindowDestroyed: { [weak self] in self?.resync() },
            onAppLaunched: { [weak self] pid in
                guard let self, self.coldStartFastPathEnabled else { return }
                self.fastAdopt(pids: [pid], coldStart: true)
            }
        )
        events.pidFilter = pidFilter
        events.start()
        windowEvents = events

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Slight delay: a launching app needs a beat before AX sees windows.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.resync()
                }
            })
        }

        // Native macOS Space-change signal. ScrollWM has no concept of WHICH
        // Space it is on (no public API exposes a stable Space id); it infers the
        // current Space by intersecting all-Spaces AX windows with the
        // WindowServer on-screen list. That intersection is only re-sampled inside
        // a resync, and a pure native-Space switch (Ctrl-arrow, Mission Control,
        // entering/leaving a fullscreen Space, an app activation that follows a
        // window to another Space) fires NONE of the other triggers - so without
        // this observer the strip stayed stale for up to one poll interval (~2s,
        // worst ~4s when a tick coalesces). `activeSpaceDidChange` is the public,
        // permission-free edge that says "recompute now": debounce it (Space
        // transitions can fire mid-animation before the on-screen list settles,
        // and can burst on rapid switching) and route to the SAME `resync()` path,
        // which already guards the locked session, coalesces, and applies the
        // Space-aware `ResyncPlanner`. No new policy, no new permission.
        observers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleSpaceResync()
        })

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.resync()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Debounced resync for a native Space change. Coalesces a burst of
    /// `activeSpaceDidChange` edges (rapid Ctrl-arrow, or the WindowServer firing
    /// before the on-screen list settles mid-animation) into ONE resync after a
    /// short settle delay, so we sample the on-screen membership once the Space
    /// has actually committed. `resync()` itself still owns the publish-race retry
    /// (the fast path) and every safety guard, so this stays a thin edge.
    private func scheduleSpaceResync() {
        spaceResyncGeneration &+= 1
        let generation = spaceResyncGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + spaceResyncDebounce) { [weak self] in
            guard let self, generation == self.spaceResyncGeneration else { return }
            // Per-Space strips: re-point the live strip to the Desktop the user
            // just switched to BEFORE resyncing, so the resync samples that
            // Space's windows against that Space's strip (no cross-Space freeze).
            // The switch already re-commits the destination layout; the resync
            // then adopts anything opened there while we were away and drops
            // anything closed. A no-op when per-Space strips are off.
            self.switchActiveSpaceIfNeeded()
            self.resync()
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        windowEvents?.stop()
        windowEvents = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers.removeAll()
    }

    /// True when the user session is active and unlocked. While locked,
    /// AX queries fail with attributeUnsupported (-25205) for everything;
    /// trusting them would mass-remove the strip and clobber restore data.
    static func sessionIsActive() -> Bool {
        // Headless tests install a sim backend and never touch real windows, so
        // the lock/console guard is meaningless there (and would falsely fail in
        // a CI/agent environment with no active console session). Treat the
        // session as active whenever a test backend is installed.
        if AXSource.backend != nil { return true }
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        let locked = (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
        let onConsole = (dict[kCGSessionOnConsoleKey as String] as? Bool) ?? true
        return !locked && onConsole
    }

    /// Diff current AX reality against the strip.
    ///
    /// Space-aware (see `ResyncPlanner`): adoption is scoped to windows on the
    /// Space the user is currently viewing, exactly like `arrange`. While the
    /// user is on a different Space than the strip, this is inert, so native
    /// Space switching never pulls foreign windows into the strip or teleports
    /// the user around.
    ///
    /// Performance: the expensive part is the cross-process AX/CG enumeration
    /// (10ms typical, but up to ~260ms when an app is cold or busy). That runs
    /// on a background queue so it never blocks the main thread; only the cheap
    /// diff + engine mutation (sub-millisecond) runs on main. So hotkeys,
    /// teleport, and the menu stay responsive even during a slow enumeration.
    func resync() {
        // Guard 0: a stopped (released / torn-down) monitor never enumerates.
        guard !stopped else { return }
        // Guard 1: never resync while the session is locked/inactive.
        guard Self.sessionIsActive() else { return }
        // Coalesce: never run two enumerations at once. A pending poll/event
        // while one is in flight is dropped; the next tick (or the in-flight
        // result) covers it.
        if enumerating { return }
        enumerating = true

        let pids = pidFilter
        enumerateQueue.async { [weak self] in
            guard let self else { return }
            // --- Background: heavy cross-process enumeration ---
            let current: [AXWindowInfo]
            if let pids {
                current = pids.flatMap { pid -> [AXWindowInfo] in
                    AXSource.windows(forPID: pid)
                }
            } else {
                current = AXSource.allWindows()
            }
            // Existence and adoptability are different questions. A managed
            // minimized/fullscreen window still exists and must not be silently
            // dropped from the strip; only newly-adopted windows need to be visible
            // and manageable on the current Space.
            //
            // EXISTENCE keys on ROLE (`AXWindow` = a genuine top-level window),
            // NOT subrole: macOS MUTATES a window's subrole while it is minimized
            // (a standard window can report `AXDialog` in the Dock - the exact
            // reason `WindowReveal.shouldUnminimize` also keys on role). A
            // subrole-keyed existence set would therefore make a managed window
            // that the user merely MINIMIZED vanish from the set and get dropped
            // from the strip the instant it minimized. Role is stable across
            // minimize, so a managed window survives until it is genuinely closed.
            let existing = current.filter { $0.role == kAXWindowRole as String }
            // ADOPTABILITY still keys on subrole (+ not minimized/fullscreen): a
            // brand-new window is only auto-tiled when it is a real standard
            // window visible on the current Space.
            let standard = existing.filter {
                $0.subrole == kAXStandardWindowSubrole as String
                    && !$0.isMinimized && !$0.isFullscreen
            }
            let cg = CGWindowSource.listWindows(onscreenOnly: true)

            // --- Main: cheap diff + apply against the live engine ---
            DispatchQueue.main.async {
                self.enumerating = false
                // The monitor may have been stopped (release / teardown) while
                // this enumeration ran on the background queue. Applying now would
                // re-adopt windows into an engine the controller already cleared
                // (the "strip not empty after release()" desync), so bail.
                guard !self.stopped else { return }
                self.applyResync(existing: existing,
                                 standardAdoptable: standard,
                                 cg: cg)
                // Floating list uses the FULL enumeration (dialogs/panels too),
                // not just `standard`, and runs after `applyResync` so it sees
                // the post-adoption strip. Reads `engine.slots` -> main thread.
                self.refreshFloating(all: current, cg: cg)
            }
        }
    }

    /// Apply an enumerated snapshot to the engine. MUST run on the main thread
    /// (mutates engine state). Cheap: matching/diff over a handful of windows.
    private func applyResync(existing: [AXWindowInfo],
                             standardAdoptable: [AXWindowInfo],
                             cg: [CGWindowInfo]) {
        let start = Clock.nowAbsNs()
        resyncCount += 1

        // Determine which standard windows are on the CURRENT Space. The
        // WindowServer's on-screen list only contains current-Space windows;
        // fuse it with AX exactly as `arrange` does (PID+frame+title scoring).
        // A window we manage that sits on another Space still appears in `ax`
        // but NOT here, which is precisely what drives the Space-freeze rule.
        let matched = IdentityMatcher.match(axWindows: existing, cgWindows: cg)

        // Map each window to an opaque token (= index into `existing`) so the
        // pure planner can reason without touching AXUIElements.
        let axIDs = Array(existing.indices)
        var currentSpaceIDs = Set<Int>()
        for (i, m) in matched.enumerated() where m.cg != nil { currentSpaceIDs.insert(i) }

        // Strip tokens: windows the engine manages in ANY vertical workspace map
        // to their `standard` index; genuinely-closed ones get a negative
        // sentinel that is never in `axIDs`/`currentSpaceIDs` (so they read as
        // removed). Spanning ALL workspaces is what stops a window PARKED in an
        // inactive workspace (still on-screen as the shared parking sliver, so
        // it shows up in the current-Space set) from being re-adopted into the
        // active workspace as if it were brand new.
        let stripIDs: [Int] = engine.allManagedSlots.enumerated().map { (s, slot) in
            existing.firstIndex { CFEqual($0.element, slot.window.element) } ?? -(s + 1)
        }

        let decision = ResyncPlanner.decide(
            stripIDs: stripIDs,
            axIDs: axIDs,
            currentSpaceIDs: currentSpaceIDs
        )
        let addTokens: [Int]
        switch decision {
        case .frozenDifferentSpace, .skipDegraded:
            // Strip belongs to another Space, or AX looks degraded: stay inert.
            return
        case .apply(_, let add):
            addTokens = add
        }

        // Removals: strip windows whose AX element no longer exists among
        // current top-level windows (role `AXWindow`). CFEqual matches
        // AXUIElements of the same underlying window, so a closed window simply
        // stops matching. Windows merely on another Space - or MINIMIZED (whose
        // subrole macOS may flip) - still exist in AX with role `AXWindow`, so
        // they are NOT removed.
        let removed = engine.removeSlots { slot in
            !existing.contains { CFEqual($0.element, slot.window.element) }
        }

        // Fullscreen suspension: a managed window in native macOS fullscreen owns
        // its own dedicated Space and its OS-controlled full-display frame. If we
        // kept treating it as a normal strip column the engine would fight the OS
        // for its geometry (teleport/resize writes) and `reconcileSizes` would
        // pull the full-display size in as that column's width, exploding the
        // strip. Marking it `suspended` keeps it in the strip (so it re-attaches
        // in place on exit) but excludes it from layout + every AX write. We read
        // fullscreen straight from the fresh AX enumeration (`existing`
        // carries fullscreen windows; only the *adoptable* set filters them out),
        // and clear the flag the moment a column is no longer fullscreen.
        let suspensionChanged = engine.reconcileFullscreenSuspension(from: existing)

        // Eviction: a managed column the user DRAGGED onto another physical
        // display still exists in AX (so `removeSlots` kept it) and is still on
        // the current Space, but under the default `stripDisplay` scope the strip
        // must not own another monitor's window - the next teleport would yank it
        // back, fighting the user. Read each surviving column's FRESH AX frame
        // from this enumeration and drop the ones that now best-overlap a
        // different display (parked columns are exempt; see the pure policy in
        // `AdoptionScope.evictedFromStripDisplay`). Evicted windows are left
        // exactly where the user put them - we remove the slot WITHOUT moving it.
        let evicted = engine.evictDraggedOffDisplay { ref in
            existing.first { CFEqual($0.element, ref.element) }?.frame
        }

        // Additions: new windows ON THE CURRENT SPACE (per the planner). Insert
        // each immediately to the RIGHT of the focused column (PaperWM/niri
        // style) and focus the newest so the viewport follows the window the
        // user just opened. Cross-Space windows are intentionally skipped.
        // Display-scope: with one Space spanning multiple monitors the planner's
        // current-Space additions include windows on OTHER displays; drop those
        // under the default `stripDisplay` scope so a window opened on the
        // external monitor is not yanked onto the strip. Same pure rule as
        // `arrange` (`engine.filterByAdoptScope`).
        let addExisting = addTokens.map { existing[$0] }
        let addAdoptable = addExisting.filter { candidate in
            standardAdoptable.contains { CFEqual($0.element, candidate.element) }
        }
        // Auto-tile gate: when disabled, a window that appears un-managed is left
        // FLOATING instead of being pulled onto the strip (the user tiles it on
        // demand). Default on = the standard "no un-arranged window in the
        // background" behavior. Removals/eviction/size-reconcile of EXISTING
        // columns below are unaffected, so managed windows still behave.
        let newWindows = autoTileEnabled
            ? engine.filterByAdoptScope(addAdoptable) { $0.frame }
            : []
        var lastInsertedIndex: Int?
        var insertedIndices: [Int] = []
        if !newWindows.isEmpty {
            // Insertion point sits just after the current focus. Inserting at
            // focusIndex+1 never shifts the focused window's own index, so the
            // anchor stays valid as we insert successive new windows in order.
            var insertAt = engine.slots.isEmpty ? 0 : engine.focusIndex + 1
            for info in newWindows {
                engine.insert(window: info, at: insertAt)
                insertedIndices.append(insertAt)
                lastInsertedIndex = insertAt
                insertAt += 1
            }
            // Snap each new window to the configured spawn width (no-op when
            // unset); the read-back keeps the model honest if the app clamps.
            for i in insertedIndices { engine.applySpawnWidth(toSlotAt: i) }
            // Then stretch each to the full usable height (no-op when disabled).
            for i in insertedIndices { engine.applyFillHeight(toSlotAt: i) }
        }

        // Reconcile each surviving column's stored size against the live AX
        // frame. The teleport pass only ever REPOSITIONS windows, so any size
        // change made outside our resize verbs (a terminal snapping to whole
        // character cells, an app clamping to its own minimum, the user
        // dragging an edge, or a `setSize` whose immediate read-back was stale)
        // would otherwise leave the model permanently diverged from reality:
        // compacted columns overlap or leave gaps and the menu-bar mini-map
        // shows the wrong widths. This is the safety net that makes size
        // self-heal even when the per-resize read-back lied.
        let sizeChanged = engine.reconcileSizes(from: standardAdoptable)

        adoptedCount += newWindows.count
        removedCount += removed + evicted
        lastResyncMs = Double(Clock.nowAbsNs() &- start) / 1e6

        if removed > 0 || evicted > 0 || !newWindows.isEmpty || sizeChanged || suspensionChanged {
            engine.compactStrip()
            if let lastInsertedIndex {
                // Focus + scroll the viewport to reveal the newly opened window.
                engine.focus(index: lastInsertedIndex)
            } else if sizeChanged || removed > 0 || evicted > 0 || suspensionChanged {
                // A managed window changed size out from under us (an app that
                // settled its async resize slower than the fast-path follow-up's
                // budget, a terminal snapping to character cells, the user
                // dragging an edge, ...) OR a column was removed (the app closed
                // a window, it minimized, moved to another Space, or was EVICTED
                // after the user dragged it to another display). Re-fit the
                // viewport to the focused column so:
                //   - a focused window that GREW past the viewport edge scrolls
                //     fully into view (the 2s safety net behind the fast-path
                //     width-reconcile), and
                //   - after a removal the viewport PULLS IN (via `clampViewportX`)
                //     so the remaining windows fill the gap instead of leaving
                //     dead space where the closed column used to be - the "closing
                //     a window should sometimes move the viewport" behavior.
                // In `fit` mode this is a no-op when the focused column is already
                // fully visible and the strip still overflows, so an unrelated
                // change never yanks the viewport.
                engine.refitViewportToFocused()
            } else {
                engine.teleport()
            }
            onChange?(newWindows.count, removed + evicted)
        }
    }

    /// Recompute the "floating" set (current-Space windows not on the strip)
    /// from a full AX enumeration fused with the on-screen CG list. MUST run on
    /// the main thread (reads `engine.slots`). Fires `onFloatingChange` only
    /// when the set actually changes, so the menu bar refresh is not spammed.
    private func refreshFloating(all: [AXWindowInfo], cg: [CGWindowInfo]) {
        let managed = engine.slots.map { $0.window.element }
        var next = FloatingWindows.compute(
            axWindows: all,
            cgWindows: cg,
            managed: managed,
            selfPID: getpid()
        )
        // Multi-display: drop windows ANOTHER monitor's strip already manages, so
        // they are not mislabeled as "floating" on this strip (and so "Tile All
        // Floating" never tries to yank another display's tiled windows across).
        // No-op on a single-strip setup (predicate nil).
        if let isManagedElsewhere {
            next = next.filter { !isManagedElsewhere($0.element) }
        }
        // Display-scope: a floating window the user could tile here should belong
        // to THIS strip's display under the active adopt scope. Without this, the
        // active monitor's menu would list every OTHER monitor's not-yet-tiled
        // windows too. Dialogs/panels keep showing (they are tile-here targets
        // only on their own display). No-op when the engine has no display
        // geometry (single-display / bare engine).
        let scoped = engine.filterByAdoptScope(next) { $0.info.frame }
        next = scoped
        // Cheap identity diff: same windows in the same order -> no refresh.
        let changed = next.count != floatingWindows.count
            || zip(next, floatingWindows).contains { !CFEqual($0.element, $1.element) }
        floatingWindows = next
        if changed { onFloatingChange?() }
    }

    /// Low-latency adoption for a window-created event. Enumerates ONLY the
    /// apps that fired (not all apps), so it is fast and immune to unrelated
    /// hung apps. Purely additive: removals and the full reconciliation stay
    /// with the safety-net `resync()` poll.
    ///
    /// Keeps the Space-freeze guarantee: a window is adopted only if it is on
    /// the current Space AND the strip itself is currently on the current Space
    /// (so we never mix windows from different Spaces). If anything is
    /// ambiguous it simply does nothing and lets the poll converge.
    private func fastAdopt(pids: [pid_t], attempt: Int = 0, coldStart: Bool = false) {
        guard !stopped else { return }
        guard Self.sessionIsActive() else { return }
        // Auto-tile gate: when disabled, do not pull newly-opened windows onto
        // the strip from the fast path either - they stay floating until the
        // user tiles them. (The poll path's add is gated identically.)
        guard autoTileEnabled else { return }
        if ProcessInfo.processInfo.environment["SCROLLWM_TRACE_ADOPT"] != nil {
            FileHandle.standardError.write("[trace] fastAdopt ENTER pids=\(pids) attempt=\(attempt) enumerating=\(enumerating)\n".data(using: .utf8)!)
        }
        // Respect an explicit pid filter (sandbox/test mode); the observer only
        // watches filtered pids anyway, so this is usually a no-op. Preserve the
        // FIRE ORDER so a multi-window burst is adopted left-to-right in creation
        // order (a Set here scrambled the order, landing bursts out of sequence).
        let targets: [pid_t] = pidFilter.map { f in pids.filter { f.contains($0) } } ?? pids
        guard !targets.isEmpty else { return }

        // Enumerate ONLY the firing apps' standard windows, in fire order.
        let appWindows = targets.flatMap { pid -> [AXWindowInfo] in
            AXSource.windows(forPID: pid)
        }.filter {
            $0.subrole == kAXStandardWindowSubrole as String && !$0.isMinimized && !$0.isFullscreen
        }
        // Windows we do not already manage in ANY vertical workspace. Spanning
        // all workspaces keeps a window parked in an inactive workspace (which is
        // still on-screen as the shared parking sliver) from being re-adopted
        // into the active workspace by the fast path.
        let unmanaged = appWindows.filter { info in !engine.isManaged(info.element) }
        guard !unmanaged.isEmpty else {
            // AX has not published the new window's element yet (it can lag the
            // `kAXWindowCreated` notification by a frame or two). Retry shortly
            // rather than waiting for the slow poll.
            if ProcessInfo.processInfo.environment["SCROLLWM_TRACE_ADOPT"] != nil {
                FileHandle.standardError.write("[trace] fastAdopt unmanaged EMPTY attempt=\(attempt) appWindows=\(appWindows.count) targets=\(targets)\n".data(using: .utf8)!)
            }
            scheduleFastAdoptRetry(pids: pids, attempt: attempt, coldStart: coldStart)
            return
        }

        // Current-Space gate via the on-screen CG list (cheap, one syscall).
        let cg = CGWindowSource.listWindows(onscreenOnly: true)
        // Match the FULL firing-app window set (managed + unmanaged), not just the
        // unmanaged subset. The motion-invariant per-PID fusion fallback
        // (`IdentityMatcher.match` pass 2) will hand a same-PID CG row to ANY
        // unmatched AX window of that PID; if we matched only the new window it
        // could wrongly claim an EXISTING managed window's CG row and be adopted
        // before the WindowServer has actually published it (the publish race).
        // Matching every app window lets the managed ones soak up their own rows
        // first, so a genuinely-unpublished new window finds no leftover row and
        // correctly waits (retries) until it is really on-screen.
        let matched = IdentityMatcher.match(axWindows: appWindows, cgWindows: cg)
        let onscreenMatches = zip(appWindows, matched)
            .filter { (info, m) in m.cg != nil && !engine.isManaged(info.element) }
            .map { $0.0 }
        // Display-scope: drop newly-created windows that live on ANOTHER monitor
        // under the default `stripDisplay` scope, so the fast path never yanks an
        // external-display window onto the strip. Same pure rule as
        // `arrange`/`applyResync` (`engine.filterByAdoptScope`).
        let onscreenNew = engine.filterByAdoptScope(onscreenMatches) { $0.frame }
        guard !onscreenNew.isEmpty else {
            if ProcessInfo.processInfo.environment["SCROLLWM_TRACE_ADOPT"] != nil {
                FileHandle.standardError.write("[trace] fastAdopt onscreenNew EMPTY attempt=\(attempt) unmanaged=\(unmanaged.count) onscreenMatches=\(onscreenMatches.count) cg=\(cg.count)\n".data(using: .utf8)!)
            }
            // The window exists in AX but the WindowServer has not yet listed it
            // on-screen (the current-Space publish race), OR it is genuinely on
            // another display/Space. We cannot tell those apart from one sample,
            // so retry a bounded number of times: a real same-Space window shows
            // up within a few frames, while a foreign-Space window simply keeps
            // missing and is correctly left to the poll once the retries lapse.
            scheduleFastAdoptRetry(pids: pids, attempt: attempt, coldStart: coldStart)
            return
        }

        // If we already manage windows but none are on the current Space, the
        // user is on another Space: defer to the poll (stay frozen).
        if !engine.slots.isEmpty && !stripIsOnCurrentSpace(cg: cg) {
            if ProcessInfo.processInfo.environment["SCROLLWM_TRACE_ADOPT"] != nil {
                FileHandle.standardError.write("[trace] fastAdopt BAIL stripIsOnCurrentSpace=false attempt=\(attempt) slots=\(engine.slots.count) viewportX=\(engine.viewportX) onscreenNew=\(onscreenNew.count)\n".data(using: .utf8)!)
            }
            return
        }

        let start = Clock.nowAbsNs()
        var insertAt = engine.slots.isEmpty ? 0 : engine.focusIndex + 1
        var lastInsertedIndex = insertAt
        var insertedIndices: [Int] = []
        for info in onscreenNew {
            engine.insert(window: info, at: insertAt)
            insertedIndices.append(insertAt)
            lastInsertedIndex = insertAt
            insertAt += 1
        }
        // Snap each freshly opened window to the configured spawn width (no-op
        // when unset). Native apps that enforce a larger minimum keep their size
        // (we read back the real frame), so the model never diverges.
        for i in insertedIndices { engine.applySpawnWidth(toSlotAt: i) }
        // Then stretch each to the full usable height (no-op when disabled).
        for i in insertedIndices { engine.applyFillHeight(toSlotAt: i) }
        adoptedCount += onscreenNew.count
        engine.compactStrip()
        // Reveal the newest. `focus` -> `teleport` now only moves windows whose
        // position actually changed, so a window that fits to the right costs a
        // single AX write (the new window) and no viewport change.
        engine.focus(index: lastInsertedIndex)
        lastResyncMs = Double(Clock.nowAbsNs() &- start) / 1e6
        onChange?(onscreenNew.count, 0)

        // Partial-burst publish race: some of the firing apps still have an
        // unmanaged window that has not yet been published on-screen (we adopted
        // the ones that were ready, but more are coming). Keep retrying for those
        // pids so the rest of the burst lands fast too, instead of stranding them
        // until the slow safety-net poll. A pid whose windows are all managed now
        // simply finds nothing on the next pass and stops.
        let pending = targets.filter { pid in
            AXSource.windows(forPID: pid).contains {
                $0.subrole == kAXStandardWindowSubrole as String
                    && !$0.isMinimized && !$0.isFullscreen
                    && !engine.isManaged($0.element)
            }
        }
        if !pending.isEmpty { scheduleFastAdoptRetry(pids: pending, attempt: attempt, coldStart: coldStart) }
    }

    /// Re-run `fastAdopt` for the same firing pids after a short delay, up to
    /// `maxFastAdoptRetries` times. This closes the `kAXWindowCreated` ->
    /// WindowServer-publish gap so a same-Space window is adopted within a few
    /// frames instead of waiting for the 2s safety-net poll. A window that keeps
    /// missing (genuinely on another Space / display) exhausts the retries
    /// harmlessly and is left to the poll, preserving the Space-freeze contract.
    private func scheduleFastAdoptRetry(pids: [pid_t], attempt: Int, coldStart: Bool = false) {
        // Cold-start launches use a longer-tailed schedule (the first window of a
        // spinning-up process can take longer to publish than a warm window).
        let delays = coldStart ? Self.coldStartRetryDelays : Self.fastAdoptRetryDelays
        guard attempt < delays.count else { return }
        // Frame-paced cadence: tight probes first (adopt the instant the window is
        // published, ~1-2 frames in the common case), then a FLAT ~16ms tail so a
        // window that appears late is still caught within ~1 frame, never left at
        // its native spot for a coarse back-off gap. `attempt` is the count of
        // retries already done, so it indexes the delay to wait before the NEXT.
        let delay = delays[min(attempt, delays.count - 1)]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.fastAdopt(pids: pids, attempt: attempt + 1, coldStart: coldStart)
        }
    }

    /// True if any managed window is currently on the user's Space, judged by
    /// matching each slot's EXPECTED screen frame against the on-screen CG list.
    /// One match is enough (windows do not all move at once).
    ///
    /// The expected position MUST be computed exactly the way `teleport` places
    /// the window (`engine.onScreenTarget`), which insets every on-screen column
    /// by the side peek lane (`peekInset`/`contentOriginX`). The earlier inline
    /// math omitted that inset, so with the production default `peekInset = 48`
    /// (larger than the 8px tolerance) NO on-screen slot ever matched the real CG
    /// bounds: the gate always returned false, the fast-adopt Space-freeze guard
    /// always tripped for a non-empty strip, and every same-Space window after
    /// the first was stranded until the 2s safety-net poll instead of adopting
    /// instantly. Reusing `onScreenTarget` keeps the gate honest at any inset
    /// (and parked columns simply don't match - one on-screen column is enough).
    private func stripIsOnCurrentSpace(cg: [CGWindowInfo]) -> Bool {
        for slot in engine.slots {
            let expected = engine.onScreenTarget(for: slot)
            let pid = slot.window.pid
            let hit = cg.contains { c in
                c.ownerPID == pid
                    && abs(c.bounds.origin.x - expected.x) <= 8
                    && abs(c.bounds.origin.y - expected.y) <= 8
            }
            if hit { return true }
        }
        return false
    }

}

// MARK: - TeleportEngine lifecycle extensions

extension TeleportEngine {
    /// Insert a newly discovered window into the strip at array index `at`
    /// (clamped into range). `canvasX` here is provisional; callers re-pack
    /// with `compactStrip()` so the only thing that matters for ordering is
    /// the array position.
    func insert(window info: AXWindowInfo, at index: Int) {
        AXSource.setTimeout(info.element, seconds: 0.08)
        let slot = Slot(
            window: ManagedWindowRef(
                element: info.element,
                pid: info.pid,
                appName: info.appName,
                title: info.title ?? "(untitled)",
                originalFrame: info.frame
            ),
            canvasX: 0,
            // Store the window's ACTUAL frame size. The teleport pass only ever
            // repositions windows, it never resizes them, so the model MUST
            // mirror the real frame. Clamping the stored size to the usable area
            // (as this used to) made the model NARROWER than the real window for
            // anything larger than the strip: `compactStrip` then packed the
            // next column a gap too close and the freshly-opened column
            // overflowed the viewport edge by the clamped-off amount - exactly
            // the "new window ignores the gaps / is slightly the wrong size"
            // symptom. Keep model == reality; `viewportTarget` (fit mode) already
            // handles a column wider than the screen.
            width: info.frame.width,
            y: screenFrame.origin.y,
            height: info.frame.height
        )
        let clamped = max(0, min(index, slots.count))
        slots.insert(slot, at: clamped)
        onLayoutChange?()
    }

    /// Append a newly discovered window to the right end of the strip.
    func append(window info: AXWindowInfo) {
        insert(window: info, at: slots.count)
    }

    /// Detach the focused column from the active workspace and return its slot,
    /// so a caller can re-home it on ANOTHER display's engine (the cross-display
    /// "send window to next monitor" verb). Unlike `removeSlots`, this does NOT
    /// release the window (no AX restore) - the slot keeps its identity/size and
    /// is handed off intact. Re-packs the remaining columns and keeps focus on a
    /// neighbor. Returns nil when there is nothing focused.
    func detachFocusedSlot() -> Slot? {
        guard slots.indices.contains(focusIndex) else { return nil }
        let detached = slots.remove(at: focusIndex)
        focusIndex = max(0, min(focusIndex, slots.count - 1))
        compactStrip()
        // Reveal the gap-fill on the source display and reset the moved window's
        // committed-origin cache so the destination engine always re-places it.
        detached.window.lastCommittedOrigin = nil
        if !slots.isEmpty { refitViewportToFocused() }
        onLayoutChange?()
        return detached
    }

    /// Adopt a slot detached from another display's engine at array index `at`,
    /// preserving its window identity and size. The caller re-packs/focuses; this
    /// only splices it into the active workspace. Pairs with `detachFocusedSlot`.
    func adoptDetachedSlot(_ slot: Slot, at index: Int) {
        var s = slot
        // Re-anchor onto this display's vertical band; `compactStrip`/`focus`
        // recompute canvasX + the on-screen origin, and the nil committed-origin
        // forces a fresh placement on the new monitor.
        s.y = screenFrame.origin.y
        s.window.lastCommittedOrigin = nil
        let clamped = max(0, min(index, slots.count))
        slots.insert(s, at: clamped)
        compactStrip()
        onLayoutChange?()
    }

    /// Remove slots matching the predicate. Returns count removed.
    /// Keeps focus on the same window when possible.
    func removeSlots(where predicate: (Slot) -> Bool) -> Int {
        guard !slots.isEmpty else { return 0 }
        let focusedWindow = slots.indices.contains(focusIndex) ? slots[focusIndex].window : nil
        let before = slots.count
        slots.removeAll(where: predicate)
        let removed = before - slots.count
        if removed > 0 {
            if let fw = focusedWindow,
               let newIndex = slots.firstIndex(where: { $0.window === fw }) {
                focusIndex = newIndex
            } else {
                focusIndex = max(0, min(focusIndex, slots.count - 1))
            }
            onLayoutChange?()
        }
        return removed
    }

    /// True if the column at array index `i` (in the ACTIVE workspace) is
    /// currently PARKED off the content region this cycle - i.e. the engine,
    /// not the user, is the reason its live frame sits off the strip. A parked
    /// column has scrolled fully past one side of the viewport, so `onScreenTarget`
    /// shoves it to `parkingX`. Eviction (`evictDraggedOffDisplay`) must exempt
    /// these so a parked sliver clamped onto a neighbor monitor is not mistaken
    /// for a window the user dragged there.
    func slotIsParked(_ i: Int) -> Bool {
        guard slots.indices.contains(i) else { return false }
        let slot = slots[i]
        let left = slot.canvasX - viewportX
        let right = left + slot.width
        return right <= 0 || left >= contentWidth
    }

    /// Evict columns the user has DRAGGED onto a different physical display.
    /// Under the default `stripDisplay` adopt scope the strip manages only its
    /// own monitor's windows, so a managed column whose freshly-read AX frame now
    /// best-overlaps another display was moved off by the user and should be let
    /// go (dropped from the strip, left exactly where they put it) rather than
    /// teleported back. Parked columns (engine-positioned off-screen) are exempt.
    ///
    /// `liveFrame(_:)` reads the window's CURRENT AX frame (top-left global); a
    /// nil result (unreadable) keeps the column (never lose a window we cannot
    /// classify). Returns the number of columns evicted. Pure policy lives in
    /// `AdoptionScope.evictedFromStripDisplay`; this is the engine glue that
    /// feeds it each slot's live frame + parked state and removes the matches
    /// WITHOUT moving them (unlike `releaseAll`, which restores frames).
    @discardableResult
    func evictDraggedOffDisplay(liveFrame: (ManagedWindowRef) -> CGRect?) -> Int {
        guard adoptScope == .stripDisplay, !otherDisplayFrames.isEmpty else { return 0 }
        let strip = stripDisplayFrame ?? screenFrame
        // Snapshot the eviction decision per active-workspace slot BEFORE
        // mutating, since `slotIsParked` reads live viewport/canvas state.
        var evictIDs = Set<UInt64>()
        for i in slots.indices {
            let slot = slots[i]
            guard let frame = liveFrame(slot.window) else { continue }
            if AdoptionScope.evictedFromStripDisplay(
                liveFrame: frame,
                stripDisplay: strip,
                others: otherDisplayFrames,
                isParked: slotIsParked(i),
                scope: adoptScope) {
                evictIDs.insert(slot.window.id)
            }
        }
        guard !evictIDs.isEmpty else { return 0 }
        return removeSlots { evictIDs.contains($0.window.id) }
    }

    /// Re-pack columns left-to-right, removing gaps left by closed windows.
    /// Opens with a `gap` leading margin (symmetric with the trailing margin).
    ///
    /// Suspended columns (native fullscreen, or diverged to another Space) are
    /// OS-owned and not visible on this Space, so they reserve NO canvas band:
    /// `x` does not advance for them, so the strip closes the gap they would
    /// otherwise leave and the neighbor to their right slides in. They keep their
    /// array position (canvasX pinned to the current `x`), so when un-suspended a
    /// later `compactStrip` re-seats them in place between the same neighbors.
    func compactStrip() {
        var x: CGFloat = gap
        for i in slots.indices {
            slots[i].canvasX = x
            if slots[i].window.suspended { continue }
            x += slots[i].width + gap
        }
    }

    /// Reconcile each managed column's stored size against the freshly
    /// enumerated AX frames (`standard`, the same snapshot the resync diff
    /// uses). The teleport pass only repositions windows, never resizes them,
    /// so the model's `width`/`height` are only ever set at adopt time or by a
    /// resize verb. When a window changes size by any OTHER route, the model
    /// silently diverges from reality. This pulls the live size back in.
    ///
    /// Matching is by AX element identity (`CFEqual`), so it is exact and never
    /// confuses two windows. Returns true if any column's size changed beyond a
    /// 1pt tolerance, signalling the caller to re-pack + teleport.
    @discardableResult
    func reconcileSizes(from standard: [AXWindowInfo]) -> Bool {
        var changed = false
        for i in slots.indices {
            // A suspended window (native fullscreen, or diverged to another
            // Space) is OS-owned: its live frame is the full-display fullscreen
            // size, NOT a strip column width. Pulling that into the model would
            // balloon the column and shove every neighbor a screen-width away.
            // Leave its stored size untouched; it is reconciled on un-suspend.
            if slots[i].window.suspended { continue }
            let el = slots[i].window.element
            guard let info = standard.first(where: { CFEqual($0.element, el) }) else { continue }
            // The window is present in a fresh AX enumeration with a readable
            // frame, so it is reachable again. Clear any stale `unhealthy` flag
            // (set by a past failed teleport); otherwise a single transient AX
            // failure would strand the column forever - resize verbs skip it and
            // teleport never repositions it. Recovering health here lets the
            // very next teleport place it correctly.
            if !slots[i].window.healthy {
                slots[i].window.healthy = true
                changed = true
            }
            let liveW = info.frame.width
            let liveH = info.frame.height
            if abs(slots[i].width - liveW) > 1 || abs(slots[i].height - liveH) > 1 {
                slots[i].width = liveW
                slots[i].height = liveH
                changed = true
            }
        }
        if changed { onLayoutChange?() }
        return changed
    }

    /// Reconcile the `suspended` flag of every managed column against a fresh AX
    /// enumeration so a window in native macOS fullscreen is suspended (excluded
    /// from layout + all engine writes) and a window that left fullscreen is
    /// resumed. Spans ALL workspaces, so a fullscreen window parked in an
    /// inactive vertical workspace is handled too. Returns true if any column's
    /// suspension state changed, so the caller re-packs + re-fits the viewport.
    ///
    /// A window absent from the enumeration (closed, or unreadable) is left as-is
    /// here; removal/health is owned by the existing reconcile/remove passes.
    @discardableResult
    func reconcileFullscreenSuspension(from standard: [AXWindowInfo]) -> Bool {
        var changed = false
        func apply(_ slot: Slot) {
            guard let info = standard.first(where: { CFEqual($0.element, slot.window.element) })
            else { return }
            let shouldSuspend = info.isFullscreen
            if slot.window.suspended != shouldSuspend {
                slot.window.suspended = shouldSuspend
                // Force the next teleport to re-place a resumed window (its parked
                // position was never committed while suspended).
                if !shouldSuspend { slot.window.lastCommittedOrigin = nil }
                changed = true
            }
        }
        for slot in allManagedSlots { apply(slot) }
        if changed { onLayoutChange?() }
        return changed
    }
}
