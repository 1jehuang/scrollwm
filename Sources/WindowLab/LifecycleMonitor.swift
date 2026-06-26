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
    /// gap - and only back off toward a coarse interval for the rare app that
    /// takes longer. The total budget (`fastAdoptRetryDelays.reduce(+)` ~0.36s)
    /// still comfortably exceeds any real publish lag while staying well under
    /// the 2s safety-net poll, so a genuinely foreign-Space window still falls
    /// through to the poll harmlessly.
    private let fastAdoptRetryDelays: [TimeInterval] =
        [0.004, 0.008, 0.012, 0.02, 0.03, 0.04, 0.06, 0.08, 0.1]
    private var maxFastAdoptRetries: Int { fastAdoptRetryDelays.count }

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

    init(engine: TeleportEngine, interval: TimeInterval = 2.0) {
        self.engine = engine
        self.interval = interval
    }

    func start() {
        // Fast path: when a window is created we get the firing PIDs, so we can
        // adopt by enumerating ONLY those apps - no all-apps sweep, and immune
        // to unrelated hung apps stalling us. A destroyed event triggers the
        // (cheap, off-main) resync so a closed window's gap closes promptly.
        let events = WindowEventObserver(
            onWindowCreated: { [weak self] pids in self?.fastAdopt(pids: pids) },
            onWindowDestroyed: { [weak self] in self?.resync() }
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

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.resync()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
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
            let standard = current.filter {
                $0.subrole == kAXStandardWindowSubrole as String && !$0.isMinimized && !$0.isFullscreen
            }
            let cg = CGWindowSource.listWindows(onscreenOnly: true)

            // --- Main: cheap diff + apply against the live engine ---
            DispatchQueue.main.async {
                self.enumerating = false
                self.applyResync(standard: standard, cg: cg)
                // Floating list uses the FULL enumeration (dialogs/panels too),
                // not just `standard`, and runs after `applyResync` so it sees
                // the post-adoption strip. Reads `engine.slots` -> main thread.
                self.refreshFloating(all: current, cg: cg)
            }
        }
    }

    /// Apply an enumerated snapshot to the engine. MUST run on the main thread
    /// (mutates engine state). Cheap: matching/diff over a handful of windows.
    private func applyResync(standard: [AXWindowInfo], cg: [CGWindowInfo]) {
        let start = Clock.nowAbsNs()
        resyncCount += 1

        // Determine which standard windows are on the CURRENT Space. The
        // WindowServer's on-screen list only contains current-Space windows;
        // fuse it with AX exactly as `arrange` does (PID+frame+title scoring).
        // A window we manage that sits on another Space still appears in `ax`
        // but NOT here, which is precisely what drives the Space-freeze rule.
        let matched = IdentityMatcher.match(axWindows: standard, cgWindows: cg)

        // Map each window to an opaque token (= index into `standard`) so the
        // pure planner can reason without touching AXUIElements.
        let axIDs = Array(standard.indices)
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
            standard.firstIndex { CFEqual($0.element, slot.window.element) } ?? -(s + 1)
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
        // current standard windows. CFEqual matches AXUIElements of the same
        // underlying window, so a closed window simply stops matching. Windows
        // merely on another Space still exist in AX, so they are NOT removed.
        let removed = engine.removeSlots { slot in
            !standard.contains { CFEqual($0.element, slot.window.element) }
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
        let newWindows = engine.filterByAdoptScope(addTokens.map { standard[$0] }) { $0.frame }
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
        let sizeChanged = engine.reconcileSizes(from: standard)

        adoptedCount += newWindows.count
        removedCount += removed
        lastResyncMs = Double(Clock.nowAbsNs() &- start) / 1e6

        if removed > 0 || !newWindows.isEmpty || sizeChanged {
            engine.compactStrip()
            if let lastInsertedIndex {
                // Focus + scroll the viewport to reveal the newly opened window.
                engine.focus(index: lastInsertedIndex)
            } else {
                engine.teleport()
            }
            onChange?(newWindows.count, removed)
        }
    }

    /// Recompute the "floating" set (current-Space windows not on the strip)
    /// from a full AX enumeration fused with the on-screen CG list. MUST run on
    /// the main thread (reads `engine.slots`). Fires `onFloatingChange` only
    /// when the set actually changes, so the menu bar refresh is not spammed.
    private func refreshFloating(all: [AXWindowInfo], cg: [CGWindowInfo]) {
        let managed = engine.slots.map { $0.window.element }
        let next = FloatingWindows.compute(
            axWindows: all,
            cgWindows: cg,
            managed: managed,
            selfPID: getpid()
        )
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
    private func fastAdopt(pids: [pid_t], attempt: Int = 0) {
        guard Self.sessionIsActive() else { return }
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
            scheduleFastAdoptRetry(pids: pids, attempt: attempt)
            return
        }

        // Current-Space gate via the on-screen CG list (cheap, one syscall).
        let cg = CGWindowSource.listWindows(onscreenOnly: true)
        let matched = IdentityMatcher.match(axWindows: unmanaged, cgWindows: cg)
        let onscreenMatches = matched.enumerated()
            .filter { $0.element.cg != nil }
            .map { unmanaged[$0.offset] }
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
            scheduleFastAdoptRetry(pids: pids, attempt: attempt)
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
        if !pending.isEmpty { scheduleFastAdoptRetry(pids: pending, attempt: attempt) }
    }

    /// Re-run `fastAdopt` for the same firing pids after a short delay, up to
    /// `maxFastAdoptRetries` times. This closes the `kAXWindowCreated` ->
    /// WindowServer-publish gap so a same-Space window is adopted within a few
    /// frames instead of waiting for the 2s safety-net poll. A window that keeps
    /// missing (genuinely on another Space / display) exhausts the retries
    /// harmlessly and is left to the poll, preserving the Space-freeze contract.
    private func scheduleFastAdoptRetry(pids: [pid_t], attempt: Int) {
        guard attempt < maxFastAdoptRetries else { return }
        // Progressive back-off: tight probes first (adopt the instant the window
        // is published, ~1-2 frames in the common case), widening toward a coarse
        // interval for slow apps. `attempt` is the count of retries already done,
        // so it indexes the delay to wait before the NEXT attempt.
        let delay = fastAdoptRetryDelays[min(attempt, fastAdoptRetryDelays.count - 1)]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.fastAdopt(pids: pids, attempt: attempt + 1)
        }
    }

    /// True if any managed window is currently on the user's Space, judged by
    /// matching each slot's EXPECTED screen frame against the on-screen CG list.
    /// One match is enough (windows do not all move at once).
    private func stripIsOnCurrentSpace(cg: [CGWindowInfo]) -> Bool {
        for slot in engine.slots {
            let expectedX = engine.screenFrame.origin.x + slot.canvasX - engine.viewportX
            let pid = slot.window.pid
            let hit = cg.contains { c in
                c.ownerPID == pid
                    && abs(c.bounds.origin.x - expectedX) <= 8
                    && abs(c.bounds.origin.y - slot.y) <= 8
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

    /// Re-pack columns left-to-right, removing gaps left by closed windows.
    /// Opens with a `gap` leading margin (symmetric with the trailing margin).
    func compactStrip() {
        var x: CGFloat = gap
        for i in slots.indices {
            slots[i].canvasX = x
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
}
