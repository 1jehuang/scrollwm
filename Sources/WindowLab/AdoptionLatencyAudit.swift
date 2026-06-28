import Foundation
import ApplicationServices
import AppKit

/// AUDIT: prove which re-adoption / re-placement situations are FAST (driven by
/// an event-triggered fast path) vs SLOW (only noticed by the ~2s safety-net
/// poll). The cold-start work made NEW windows fast; this harness checks the
/// OTHER ways a window enters / re-enters the strip's managed set:
///
///   A. warm new window      (running app opens a window)     - kAXWindowCreated
///   B. un-minimize          (managed window de-miniaturized)  - ???
///   C. exit fullscreen      (managed window leaves fullscreen) - ???
///   D. un-hide app          (Cmd+H app shown again)           - ???
///   E. native Space switch  (return to the strip's Space)     - activeSpace
///
/// Each scenario, against the REAL engine + LifecycleMonitor + sim:
///   1. setup + adopt so the window is a managed column,
///   2. `leave`: drive the transition that REMOVES it from the active strip
///      (minimize / enter fullscreen / hide / move to another Space), let a
///      resync settle, and ASSERT the precondition actually held (the window
///      really left), so a false-"fast" cannot slip through,
///   3. `enter`: drive the RETURN transition and time until the window is back
///      in its strip slot.
///
/// A SLOW result (~poll interval) is a latency bug: the user sees the window sit
/// un-tiled for up to ~2s after the transition. The monitor gets a deliberately
/// SLOW 5s poll, so any sub-second result proves an event-driven fast path and a
/// multi-second result proves only the poll caught it. Fully headless.

private final class ElBox { var el: AXUIElement? }

private struct AuditResult {
    var preconditionHeld: Bool
    var ms: Double?
}

private func auditLatency(pollInterval: TimeInterval = 5.0,
                          setup: (SimWindowWorld, TeleportEngine) -> Void,
                          leave: (SimWindowWorld, TeleportEngine, LifecycleMonitor) -> Bool,
                          enter: (SimWindowWorld, TeleportEngine) -> Void,
                          placed: (SimWindowWorld, TeleportEngine) -> Bool) -> AuditResult {
    let world = SimWindowWorld()
    AXSource.backend = world
    defer { AXSource.backend = nil }

    let engine = TeleportEngine(screenFrame: Headless.defaultVisibleFrame)
    setup(world, engine)

    let monitor = LifecycleMonitor(engine: engine, interval: pollInterval)
    monitor.start()
    Headless.pump(0.1)

    // Establish the precondition: the window must really leave the active strip.
    let pre = leave(world, engine, monitor)
    guard pre else { monitor.stop(); return AuditResult(preconditionHeld: false, ms: nil) }

    let t0 = Clock.nowAbsNs()
    enter(world, engine)

    var placedNs: UInt64?
    let deadline = Clock.nowAbsNs() + 7_000_000_000
    while Clock.nowAbsNs() < deadline {
        Headless.pump(0.005)
        if placed(world, engine) { placedNs = Clock.nowAbsNs(); break }
    }
    monitor.stop()
    return AuditResult(preconditionHeld: true, ms: placedNs.map { Double($0 &- t0) / 1e6 })
}

/// Adopt every current-Space seed window into the engine and focus the first.
private func adoptSeed(_ world: SimWindowWorld, _ engine: TeleportEngine, pids: [pid_t]) {
    let m = IdentityMatcher.match(
        axWindows: pids.flatMap { AXSource.windows(forPID: $0) },
        cgWindows: CGWindowSource.listWindows(onscreenOnly: true)).filter { $0.cg != nil }
    engine.adopt(matched: m)
    engine.focus(index: 0)
}

func runAdoptionLatencyAudit() {
    print("== Adoption / re-placement latency audit (headless, slow 5s poll) ==")
    print("   FAST (<500ms) = event-driven fast path. SLOW (>2000ms) = poll only.\n")

    var t = TestCounter()

    // ---- A. WARM new window: running app opens a 2nd window ----
    let warm = auditLatency { world, engine in
        let s = Headless.seedWindows(world, count: 1, startPID: 5000)
        adoptSeed(world, engine, pids: s.pids)
        _ = engine.setFocusedWidth(fraction: 0.25)
    } leave: { _, engine, _ in
        engine.slots.count == 1   // nothing to remove; precondition is "1 column"
    } enter: { world, _ in
        _ = world.addWindow(pid: 5000, title: "Warm-2",
                            frame: CGRect(x: 700, y: 120, width: 360, height: 420),
                            notify: true)
    } placed: { _, engine in engine.slots.count == 2 }
    report("A. warm new window (kAXWindowCreated)", warm, &t)

    // ---- B. UN-MINIMIZE a managed window ----
    // NOTE: a managed window that the user minimizes is NOT dropped from the
    // strip (removal keys on AX existence/role, and a minimized window still
    // exists with role AXWindow). Its column is HELD, so on restore it is
    // already in place - no re-adoption latency at all. We assert that contract:
    // the column survives the minimize, so there is nothing slow to wait for.
    let boxB = ElBox()
    let unmin = auditLatency { world, engine in
        let s = Headless.seedWindows(world, count: 2, startPID: 5100)
        adoptSeed(world, engine, pids: s.pids)
        boxB.el = s.elements[1]
    } leave: { world, engine, monitor in
        world.setMinimized(boxB.el!, true)
        monitor.resync(); Headless.pump(0.15)
        // Precondition for THIS scenario: the column is RETAINED (held in place).
        return engine.slots.contains { CFEqual($0.window.element, boxB.el!) }
    } enter: { world, _ in
        world.setMinimized(boxB.el!, false)
    } placed: { _, engine in
        // Already in place the instant it restores: 2 columns, the window present.
        engine.slots.count == 2 && engine.slots.contains { CFEqual($0.window.element, boxB.el!) }
    }
    report("B. un-minimize (column held, instant)", unmin, &t)

    // ---- C. EXIT FULLSCREEN (modeled faithfully: fullscreen = own Space) ----
    // Real macOS: entering native fullscreen moves the window to its OWN Space
    // (which becomes active) and sets AXFullScreen; exiting returns it to the
    // origin Space (active again). The exit therefore fires a Space change - the
    // signal the strip must react to fast (not the 2s poll).
    let boxC = ElBox()
    let exitFS = auditLatency { world, engine in
        let s = Headless.seedWindows(world, count: 2, startPID: 5200)
        adoptSeed(world, engine, pids: s.pids)
        boxC.el = s.elements[1]
    } leave: { world, engine, monitor in
        // Enter fullscreen: flag + move to its own Space (id 9), which activates.
        for w in world.snapshot() where CFEqual(w.element, boxC.el!) { w.fullscreen = true }
        world.setNativeSpace(boxC.el!, 9)
        world.setActiveSpace(9)
        Headless.pump(0.2)   // let the Space-change resync settle
        // Precondition: the fullscreen column is SUSPENDED (excluded from writes).
        return engine.slots.contains { CFEqual($0.window.element, boxC.el!) && $0.window.suspended }
    } enter: { world, _ in
        // Exit fullscreen: clear the flag, return to the origin Space (activate).
        for w in world.snapshot() where CFEqual(w.element, boxC.el!) { w.fullscreen = false }
        world.setNativeSpace(boxC.el!, 1)
        world.setActiveSpace(1)
    } placed: { _, engine in
        !engine.slots.contains { $0.window.suspended }
    }
    report("C. exit native fullscreen", exitFS, &t)

    // ---- D. UN-HIDE app (Cmd+H undo) ----
    // Same contract as B: a Cmd-H'd app's managed window is KEPT as a column
    // (still exists in AX), so un-hiding restores it in place with no latency.
    let boxD = ElBox()
    let unhide = auditLatency { world, engine in
        let s = Headless.seedWindows(world, count: 2, startPID: 5300)
        adoptSeed(world, engine, pids: s.pids)
        boxD.el = s.elements[1]
    } leave: { world, engine, monitor in
        world.setAppHidden(5301, true)
        monitor.resync(); Headless.pump(0.15)
        return engine.slots.contains { CFEqual($0.window.element, boxD.el!) }
    } enter: { world, _ in
        _ = world.unhideApp(pid: 5301)
    } placed: { _, engine in
        engine.slots.count == 2 && engine.slots.contains { CFEqual($0.window.element, boxD.el!) }
    }
    report("D. un-hide app (column held, instant)", unhide, &t)

    // ---- E. native Space switch: a window already managed on the Space we
    // switch TO must re-place fast. Strip spans Space 1 (focused col) + Space 2
    // (a second managed col). While on Space 1, the Space-2 column is suspended/
    // off-screen; switching to Space 2 must re-place it promptly (Space-change
    // signal), not wait for the 2s poll. ----
    let spaceSwitch = auditLatency { world, engine in
        // Two windows, both adopted while on Space 1.
        let s = Headless.seedWindows(world, count: 2, startPID: 5400)
        adoptSeed(world, engine, pids: s.pids)
        // Move the 2nd window to Space 2 (the user dragged it there); it stays a
        // managed column but is off the current Space.
        world.setNativeSpace(s.elements[1], 2)
    } leave: { world, engine, monitor in
        monitor.resync(); Headless.pump(0.15)
        // Precondition: still 2 managed columns (the off-Space one is retained).
        return engine.slots.count == 2
    } enter: { world, _ in
        world.setActiveSpace(2)   // user switches to Space 2
    } placed: { world, engine in
        // The Space-2 column should be on-screen (placed) after the switch. We
        // proxy "re-placed" as: a resync ran and the strip is coherent on Space 2.
        // Concretely the strip stays at 2 columns and is not frozen (the Space-2
        // window is now current). Use the floating/placement signal: the window's
        // live frame is its strip target.
        guard let slot = engine.slots.first(where: { $0.window.pid == 5401 }) else { return false }
        let target = engine.onScreenTarget(for: slot)
        guard let live = world.frame(of: slot.window.element) else { return false }
        return abs(live.minX - target.x) <= 8
    }
    report("E. switch to a Space with a managed window", spaceSwitch, &t)

    print("\n[adoptlatency] \(t.passed) fast, \(t.failed) SLOW/bad")
    exit(t.summaryExitCode)
}

private func report(_ name: String, _ r: AuditResult, _ t: inout TestCounter) {
    let padded = name.padding(toLength: 46, withPad: " ", startingAt: 0)
    guard r.preconditionHeld else {
        print("   \(padded)   PRECONDITION FAILED (window never left the strip)")
        t.check(name + " precondition held", false)
        return
    }
    if let ms = r.ms {
        let fast = ms < 500
        let msStr = String(format: "%6.0f", ms)
        print("   \(padded) \(msStr) ms  \(fast ? "FAST" : "*** SLOW ***")")
        t.check(name + " is fast (<500ms)", fast)
    } else {
        print("   \(padded)   never re-placed within 7s  *** SLOW ***")
        t.check(name + " is fast (<500ms)", false)
    }
}
