import Foundation
import ApplicationServices
import AppKit

// MARK: - spacetest (headless): native macOS Space membership + switching
//
// Exercises the Track 5 sim-Space infrastructure (`SimWindowWorld`'s native
// Space API) end-to-end through the REAL `LifecycleMonitor` + `ResyncPlanner`,
// fully headless: no real window, no focus theft, no keystroke. It proves the
// new API drives the exact production current-Space scoping the engine already
// relies on, and pins the CURRENT (sometimes buggy) cross-Space behavior so the
// other tracks have a ground-truth baseline to design against.
//
// What it asserts:
//   1. Active-Space switch hides off-Space windows from the on-screen CG list
//      while they stay present in AX (the core fidelity).
//   2. With the strip built on Space 1, switching to an empty Space 2 freezes
//      the monitor (`frozenDifferentSpace`): no columns added/removed.
//   3. A window opened on the NON-active Space 2 is NOT adopted into the Space-1
//      strip (strip stays frozen) - the "new window on another Space" case.
//   4. Switching back to Space 1 resumes management with the SAME columns and
//      adopts nothing spurious (the Space-2 window is left alone).
//   5. Sending a MANAGED window to another Space while the user stays put leaves
//      it as a phantom column (still in AX, off the on-screen list) - the stale
//      strip / phantom-column bug, asserted as current behavior + flagged.
//   6. `activeSpaceDidChange` fires (once) on a real switch, never on a no-op.

func runHeadlessSpaceTest() {
    let world = Headless.install()
    defer { Headless.uninstall() }
    var t = TestCounter()

    let engine = TeleportEngine(screenFrame: Headless.defaultVisibleFrame)

    // --- Seed 3 windows on Space 1 (the default active Space). ---
    let pidA: pid_t = 7100, pidB: pid_t = 7101, pidC: pid_t = 7102
    let f = Headless.defaultVisibleFrame
    let elA = world.addWindow(pid: pidA, title: "Alpha",
                              frame: CGRect(x: f.minX + 40, y: f.minY + 40, width: 360, height: 420))
    _ = world.addWindow(pid: pidB, title: "Bravo",
                        frame: CGRect(x: f.minX + 440, y: f.minY + 40, width: 360, height: 420))
    _ = world.addWindow(pid: pidC, title: "Charlie",
                        frame: CGRect(x: f.minX + 840, y: f.minY + 40, width: 360, height: 420))
    let pids: [pid_t] = [pidA, pidB, pidC]

    t.check("world starts on Space 1", world.activeSpace == 1)
    t.check("all seeds default onto the active Space",
            pids.allSatisfy { world.windows(forPID: $0).first.map { _ in true } ?? false }
                && world.knownSpaces() == [1])

    // Arrange the current Space into the strip (production fuse + adopt).
    Headless.arrangeCurrentSpace(engine, pids: pids)
    t.check("arrange adopted all 3 current-Space windows", engine.slots.count == 3)

    // Start the REAL lifecycle monitor, scoped to our sim pids, with a SLOW poll
    // so each assertion reflects an explicit `resync()` we trigger, not a timer.
    let monitor = LifecycleMonitor(engine: engine, interval: 30.0)
    monitor.pidFilter = Set(pids)
    monitor.start()

    // Observe the active-Space hook (the headless NSWorkspace.activeSpaceDidChange
    // stand-in). Track 1 will wire a real signal onto exactly this shape.
    var spaceChangeFires: [Int] = []
    world.subscribeActiveSpace { space in spaceChangeFires.append(space) }
    Headless.pump(0.05) // let the observer subscribe to sim events

    // === 1. Switch to an empty Space 2: off-Space windows leave the CG list. ===
    world.setActiveSpace(2)
    Headless.pump(0.05)
    let onscreenAfterSwitch = CGWindowSource.listWindows(onscreenOnly: true)
    t.check("Space 2 active: on-screen list is empty (windows live on Space 1)",
            onscreenAfterSwitch.isEmpty)
    t.check("off-Space windows STILL exist in AX (not closed/minimized)",
            pids.flatMap { AXSource.windows(forPID: $0) }.count == 3)
    t.check("activeSpaceDidChange fired once for the 1->2 switch",
            spaceChangeFires == [2])

    // The pure planner decision the monitor will act on: frozen (strip on Space 1).
    let decFrozen = Headless.resyncDecision(engine, pids: pids)
    t.check("planner freezes on a different Space",
            decFrozen == .frozenDifferentSpace)

    // Drive the REAL monitor resync; it must keep the strip intact (frozen).
    monitor.resync()
    Headless.pump(0.1)
    t.check("monitor stayed frozen: strip still has 3 columns", engine.slots.count == 3)

    // === 2. Open a NEW window on the (non-strip) active Space 2. ===
    let pidD: pid_t = 7103
    _ = world.addWindow(pid: pidD, title: "Delta",
                        frame: CGRect(x: f.minX + 40, y: f.minY + 40, width: 360, height: 420),
                        notify: true) // defaults to active Space 2
    Headless.pump(0.2) // let fast-adopt retries run + lapse
    t.check("new Space-2 window is visible on the current (Space 2) on-screen list",
            CGWindowSource.listWindows(onscreenOnly: true).contains { $0.ownerPID == pidD })
    // The Space-1 strip must NOT adopt it: it belongs to a different Space and
    // the strip is frozen. (Current behavior: a fresh strip for Space 2 is a gap
    // the other tracks own; here we pin "no cross-Space contamination".)
    t.check("Space-1 strip did NOT adopt the Space-2 window (still 3 columns)",
            engine.slots.count == 3)
    t.check("Delta is unmanaged by the Space-1 strip", !engine.isManaged(world.snapshot().first { $0.title == "Delta" }!.element))

    // === 3. Switch back to Space 1: management resumes, nothing spurious. ===
    world.setActiveSpace(1)
    Headless.pump(0.05)
    t.check("activeSpaceDidChange fired again for the 2->1 switch",
            spaceChangeFires == [2, 1])
    let decResume = Headless.resyncDecision(engine, pids: pids)
    if case .apply(let remove, let add) = decResume {
        t.check("back on Space 1: planner applies (no freeze)", true)
        t.check("no spurious removals on return", remove.isEmpty)
        // Delta (Space 2) must NOT be added; it is off the current Space.
        t.check("Space-2 Delta is NOT adopted on return (add empty)", add.isEmpty)
    } else {
        t.check("back on Space 1: planner applies (no freeze)", false)
    }
    monitor.resync()
    Headless.pump(0.1)
    t.check("after return the strip still has exactly its 3 original columns",
            engine.slots.count == 3)
    t.check("strip identity preserved across the round-trip",
            engine.slots.map { $0.window.title } == ["Alpha", "Bravo", "Charlie"])

    // === 4. Send a MANAGED window to another Space (user stays on Space 1). ===
    // This models "send window to Desktop 2" via Mission Control. The window
    // leaves the on-screen list but still exists in AX, so the planner keeps it
    // in the strip: a STALE / PHANTOM column. Asserted as the current behavior
    // (a real bug the other tracks design the fix for), not as desired.
    world.setNativeSpace(elA, 2)
    Headless.pump(0.05)
    t.check("sent window left the on-screen (current-Space) list",
            !CGWindowSource.listWindows(onscreenOnly: true).contains { $0.ownerPID == pidA })
    t.check("sent window still exists in AX (on Space 2)",
            world.nativeSpace(of: elA) == 2 && AXSource.windows(forPID: pidA).count == 1)
    let decPhantom = Headless.resyncDecision(engine, pids: pids)
    if case .apply(let remove, _) = decPhantom {
        t.check("planner does NOT remove a window merely sent to another Space",
                !remove.contains(0))
    } else {
        t.check("planner applies (Bravo/Charlie still on current Space)", false)
    }
    monitor.resync()
    Headless.pump(0.1)
    t.check("PHANTOM COLUMN (current bug): off-Space sent window stays in the strip",
            engine.slots.count == 3 && engine.isManaged(elA))

    // === 5. No-op switch fires nothing. ===
    let firesBefore = spaceChangeFires.count
    world.setActiveSpace(1) // already on 1
    Headless.pump(0.03)
    t.check("setActiveSpace to the current Space is a no-op (no hook fire)",
            spaceChangeFires.count == firesBefore)

    monitor.stop()
    print("\n[headless-spacetest] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}
