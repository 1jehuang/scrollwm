import Foundation
import ApplicationServices
import AppKit

// MARK: - movetest (headless): window MOVEMENT across native Spaces + lifecycle
//
// Track 4 (window movement across Spaces + lifecycle/removal correctness).
// Builds on the Track 5 sim-Space infrastructure (`SimWindowWorld` native-Space
// API + `Headless.arrangeCurrentSpace`/`resyncDecision`) to drive the REAL
// `LifecycleMonitor` + `TeleportEngine` through cross-Space window movement,
// parking-sliver interactions, oscillation storms, and the `stripIsOnCurrentSpace`
// fast-adopt gate. Fully headless: no real window, no focus theft, no keystroke.
//
// Sections map to the Track-4 questions:
//   1. Removal-keys-on-AX invariant + the PHANTOM GAP when a managed window is
//      sent to another Space (user-drag via Mission Control).
//   2. Parked-sliver vs native-Space switch: a vertical-workspace-parked window
//      stays in the current-Space CG list, drops out when its Space deactivates,
//      and is NOT re-adopted into the wrong Space on return.
//   3. No oscillation / no phantom columns under a rapid Space-toggle storm;
//      `frozenDifferentSpace` never degrades into `skipDegraded` mass-removal.
//   4. The `stripIsOnCurrentSpace` fast-adopt gate is robust under `peekInset`
//      (the production default 48) - the regression this file pins + fixes.
//   5. Inactive-workspace removal gap: a window CLOSED while parked in an
//      inactive vertical workspace is reaped on the safety-net poll.

func runHeadlessMovementTest() {
    let world = Headless.install()
    defer { Headless.uninstall() }
    var t = TestCounter()

    // =====================================================================
    // Section 1. Removal-keys-on-AX invariant + the phantom gap.
    // The user drags a MANAGED window to another Space via Mission Control while
    // the strip stays put. The window still EXISTS in AX (it was not closed), so
    // the removal rule (drop only when gone from AX) KEEPS it - leaving a phantom
    // column that reserves a visible gap on the strip's Space. We pin this as the
    // CURRENT behavior (a real bug the design doc proposes a fix for).
    // =====================================================================
    do {
        let f = Headless.defaultVisibleFrame
        let engine = TeleportEngine(screenFrame: f)
        let pidL: pid_t = 7200, pidM: pid_t = 7201, pidR: pid_t = 7202
        _ = world.addWindow(pid: pidL, title: "Left",
                            frame: CGRect(x: f.minX + 40, y: f.minY + 40, width: 360, height: 420))
        let elM = world.addWindow(pid: pidM, title: "Mid",
                            frame: CGRect(x: f.minX + 440, y: f.minY + 40, width: 360, height: 420))
        _ = world.addWindow(pid: pidR, title: "Right",
                            frame: CGRect(x: f.minX + 840, y: f.minY + 40, width: 360, height: 420))
        let pids: [pid_t] = [pidL, pidM, pidR]
        Headless.arrangeCurrentSpace(engine, pids: pids)
        t.check("S1 arranged 3 current-Space columns", engine.slots.count == 3)

        let monitor = LifecycleMonitor(engine: engine, interval: 30.0)
        monitor.pidFilter = Set(pids)
        monitor.start()
        defer { monitor.stop() }

        // Record the middle column's canvasX BEFORE the move (for the gap proof).
        let midCanvasXBefore = engine.slots.first { $0.window.title == "Mid" }?.canvasX
        let rightCanvasXBefore = engine.slots.first { $0.window.title == "Right" }?.canvasX

        // Send "Mid" to native Space 2 (user-drag), user stays on Space 1.
        world.setNativeSpace(elM, 2)
        Headless.pump(0.05)
        t.check("S1 sent window left the current-Space (on-screen) list",
                !CGWindowSource.listWindows(onscreenOnly: true).contains { $0.ownerPID == pidM })
        t.check("S1 sent window STILL exists in AX (merely on Space 2)",
                AXSource.windows(forPID: pidM).count == 1 && world.nativeSpace(of: elM) == 2)

        // The planner must NOT remove it (removal keys on AX existence).
        let dec = Headless.resyncDecision(engine, pids: pids)
        if case .apply(let remove, let add) = dec {
            t.check("S1 planner does NOT remove a window merely on another Space", remove.isEmpty)
            t.check("S1 planner adds nothing (no cross-Space contamination)", add.isEmpty)
        } else {
            t.check("S1 planner applies (Left/Right still on current Space)", false)
        }

        monitor.resync()
        Headless.pump(0.1)
        // PHANTOM COLUMN: the sent window is still managed and still occupies a
        // column between its neighbors, so a visible gap is reserved where it
        // sits (its real frame is on Space 2, invisible here).
        t.check("S1 PHANTOM COLUMN (current bug): sent window stays in the strip",
                engine.slots.count == 3 && engine.isManaged(elM))
        let midCanvasXAfter = engine.slots.first { $0.window.title == "Mid" }?.canvasX
        let rightCanvasXAfter = engine.slots.first { $0.window.title == "Right" }?.canvasX
        t.check("S1 phantom still occupies its canvas slot (layout unchanged)",
                midCanvasXAfter == midCanvasXBefore && rightCanvasXAfter == rightCanvasXBefore)
        // Proof of the GAP: "Right" did not slide left to fill the phantom's
        // place, so there is a Mid-width+gap dead band on the strip.
        t.check("S1 phantom GAP: Right was NOT pulled in to fill the sent column",
                (rightCanvasXAfter ?? 0) > (midCanvasXAfter ?? 0))

        // Design-recommendation oracle (pure, NOT wired into production): a
        // partial-divergence classifier would drop exactly the phantom.
        let phantom = MovementLifecycle.divergedManagedWindows(
            stripPIDs: engine.slots.map { $0.window.pid },
            currentSpacePIDs: Set(CGWindowSource.listWindows(onscreenOnly: true).map { $0.ownerPID }))
        t.check("S1 proposed classifier flags exactly the sent window as diverged",
                phantom == [pidM])

        for pid in pids { for w in world.snapshot() where w.pid == pid { world.destroyWindow(w.element, notify: false) } }
    }

    // =====================================================================
    // Section 2. Parked sliver vs native-Space switch.
    // A window parked off-screen in an INACTIVE vertical workspace stays on its
    // native Space (it was only slid sideways), so it remains in the current-
    // Space CG list as a sliver. When the user switches native Spaces it does
    // NOT follow, drops out of the new Space's CG list, and is NOT re-adopted
    // into the wrong Space on return (the `isManaged` span-all-workspaces guard).
    // =====================================================================
    do {
        let f = Headless.defaultVisibleFrame
        let engine = TeleportEngine(screenFrame: f)
        let pidA: pid_t = 7300, pidB: pid_t = 7301
        let elA = world.addWindow(pid: pidA, title: "WsA",
                            frame: CGRect(x: f.minX + 40, y: f.minY + 40, width: 360, height: 420))
        let elB = world.addWindow(pid: pidB, title: "WsB",
                            frame: CGRect(x: f.minX + 440, y: f.minY + 40, width: 360, height: 420))
        let pids: [pid_t] = [pidA, pidB]
        Headless.arrangeCurrentSpace(engine, pids: pids)
        t.check("S2 adopted 2 columns on Space 1", engine.slots.count == 2)

        // Park WsB in an inactive vertical workspace: move it down (active->ws2),
        // then switch back up so ws1 (WsA) is active and WsB is parked off-screen.
        engine.focusIndex = engine.slots.firstIndex { $0.window.title == "WsB" } ?? 0
        _ = engine.moveFocusedToWorkspace(by: 1)   // WsB -> ws2 (now active); WsA parked
        _ = engine.switchWorkspace(by: -1)         // back to ws1 (WsA active); WsB parked
        Headless.pump(0.05)
        t.check("S2 active workspace holds only WsA",
                engine.slots.count == 1 && engine.slots[0].window.title == "WsA")
        t.check("S2 WsB is still managed (parked in inactive workspace)", engine.isManaged(elB))

        // The parked sliver stays in the current-Space CG list (only slid sideways,
        // never left native Space 1).
        t.check("S2 parked sliver is still in the current-Space CG list",
                CGWindowSource.listWindows(onscreenOnly: true).contains { $0.ownerPID == pidB })

        let monitor = LifecycleMonitor(engine: engine, interval: 30.0)
        monitor.pidFilter = Set(pids)
        monitor.start()
        defer { monitor.stop() }

        // Switch native Space to 2: BOTH windows live on Space 1, so the CG list
        // empties and the strip freezes (nothing re-adopted, nothing dropped).
        world.setActiveSpace(2)
        Headless.pump(0.05)
        t.check("S2 on Space 2 the parked sliver drops out of the CG list",
                !CGWindowSource.listWindows(onscreenOnly: true).contains { $0.ownerPID == pidB })
        t.check("S2 strip freezes on the foreign Space",
                Headless.resyncDecision(engine, pids: pids) == .frozenDifferentSpace)
        monitor.resync(); Headless.pump(0.1)
        t.check("S2 frozen: active workspace unchanged", engine.slots.count == 1)
        t.check("S2 frozen: WsB not duplicated/re-adopted", engine.workspaceCount == 2)

        // Return to Space 1: the parked sliver reappears in CG. It must NOT be
        // re-adopted into the active workspace (already managed in ws2).
        world.setActiveSpace(1)
        Headless.pump(0.05)
        monitor.resync(); Headless.pump(0.1)
        t.check("S2 back on Space 1: active workspace still only WsA",
                engine.slots.count == 1 && engine.slots[0].window.title == "WsA")
        t.check("S2 back on Space 1: WsB NOT re-adopted into the wrong workspace",
                engine.workspaceCount == 2 && engine.isManaged(elB))
        // Exactly one managed instance of WsB across all workspaces.
        t.check("S2 WsB managed exactly once (no phantom duplicate)",
                engine.allManagedSlots.filter { CFEqual($0.window.element, elB) }.count == 1)

        _ = elA
        for w in world.snapshot() where pids.contains(w.pid) { world.destroyWindow(w.element, notify: false) }
    }

    // =====================================================================
    // Section 3. Oscillation storm + frozen-vs-degraded separation.
    // Rapidly toggle the active native Space with B-Space windows present; the
    // Space-1 strip must stay EXACTLY its own columns - never drop one, never
    // adopt a B window, never duplicate - proving no adopt/frozen oscillation in
    // the clean (non-overlap) transition case. Also: a freeze must never be
    // mistaken for AX degradation (no mass-removal).
    // =====================================================================
    do {
        let f = Headless.defaultVisibleFrame
        let engine = TeleportEngine(screenFrame: f)
        // A 4-window strip so the degradation guard (count >= 4) is in play.
        let base: pid_t = 7400
        var aPids: [pid_t] = []
        for i in 0..<4 {
            let pid = base + pid_t(i)
            aPids.append(pid)
            _ = world.addWindow(pid: pid, title: "A\(i)",
                                frame: CGRect(x: f.minX + 40 + CGFloat(i) * 380, y: f.minY + 40,
                                              width: 360, height: 420))
        }
        // Two windows that live on Space 2 the whole time.
        let bPids: [pid_t] = [7420, 7421]
        for (i, pid) in bPids.enumerated() {
            _ = world.addWindow(pid: pid, title: "B\(i)",
                                frame: CGRect(x: f.minX + 40 + CGFloat(i) * 380, y: f.minY + 40,
                                              width: 360, height: 420),
                                nativeSpace: 2)
        }
        let allPids = aPids + bPids
        Headless.arrangeCurrentSpace(engine, pids: allPids)
        t.check("S3 strip adopted only the 4 current-Space (A) windows", engine.slots.count == 4)

        let monitor = LifecycleMonitor(engine: engine, interval: 30.0)
        monitor.pidFilter = Set(allPids)
        monitor.start()
        defer { monitor.stop() }

        let expectedTitles = Set((0..<4).map { "A\($0)" })
        var oscillated = false
        var contaminated = false
        // Storm: 1->2->1->2 ... resync every step.
        for step in 0..<12 {
            world.setActiveSpace(step % 2 == 0 ? 2 : 1)
            Headless.pump(0.02)
            monitor.resync()
            Headless.pump(0.03)
            let titles = Set(engine.slots.map { $0.window.title })
            // While on Space 2 the strip is frozen (still 4 A columns); while on
            // Space 1 it is the same 4. It must NEVER drop an A or add a B.
            if !titles.isSubset(of: expectedTitles) { contaminated = true }
            if engine.slots.count != 4 { oscillated = true }
        }
        // End on Space 1 for the final assertions.
        world.setActiveSpace(1)
        Headless.pump(0.02)
        monitor.resync()
        Headless.pump(0.05)
        t.check("S3 no oscillation: strip stayed at 4 columns throughout", !oscillated)
        t.check("S3 no contamination: no Space-2 (B) window ever entered the strip", !contaminated)
        t.check("S3 final strip is exactly its 4 original columns",
                Set(engine.slots.map { $0.window.title }) == expectedTitles)
        // Freeze must never be read as AX degradation: on Space 2 the decision is
        // frozenDifferentSpace, NOT skipDegraded, and no removal happens.
        world.setActiveSpace(2)
        Headless.pump(0.02)
        t.check("S3 foreign Space yields frozenDifferentSpace (not skipDegraded)",
                Headless.resyncDecision(engine, pids: allPids) == .frozenDifferentSpace)
        monitor.resync(); Headless.pump(0.05)
        t.check("S3 freeze did not mass-remove the 4-window strip", engine.slots.count == 4)

        world.setActiveSpace(1)
        for w in world.snapshot() where allPids.contains(w.pid) { world.destroyWindow(w.element, notify: false) }
    }

    // =====================================================================
    // Section 4. stripIsOnCurrentSpace gate is robust under peekInset.
    // REGRESSION: the gate compared each slot's expected on-screen X computed
    // WITHOUT the peek-lane inset against the real CG bounds (which include it),
    // so with the production default `peekInset = 48` (> the 8px tolerance) NO
    // on-screen slot ever matched -> the gate always returned false -> the
    // fast-adopt path's Space-freeze guard always tripped for a non-empty strip
    // -> every subsequent same-Space window waited for the 2s safety-net poll.
    // The fix computes the expected position the SAME way teleport does
    // (`engine.onScreenTarget`), so the gate matches reality at any peekInset.
    // =====================================================================
    func fastAdoptUnderPeekInset(_ name: String, peekInset: CGFloat) {
        let f = Headless.defaultVisibleFrame
        let engine = TeleportEngine(screenFrame: f)
        engine.peekInset = peekInset
        let seedPID: pid_t = 7500
        _ = world.addWindow(pid: seedPID, title: "Seed",
                            frame: CGRect(x: f.minX + 40, y: f.minY + 40, width: 360, height: 420))
        Headless.arrangeCurrentSpace(engine, pids: [seedPID])
        t.check("S4/\(name): seed adopted (1 column)", engine.slots.count == 1)

        // SLOW poll so only the event-driven fast path can adopt within the pump.
        let monitor = LifecycleMonitor(engine: engine, interval: 30.0)
        monitor.pidFilter = [seedPID]
        monitor.start()
        defer { monitor.stop() }
        Headless.pump(0.1) // let the observer subscribe

        // Open a SECOND window in the SAME (observed) process on the SAME Space.
        let newEl = world.addWindow(pid: seedPID, title: "Seed-2",
                            frame: CGRect(x: f.minX + 440, y: f.minY + 40, width: 360, height: 420),
                            notify: true)
        // Poll up to ~1s (well under the 30s poll) for the fast path to adopt.
        var adopted = false
        let deadline = Clock.nowAbsNs() + 1_200_000_000
        while Clock.nowAbsNs() < deadline {
            Headless.pump(0.01)
            if engine.slots.count == 2 { adopted = true; break }
        }
        t.check("S4/\(name): 2nd same-Space window fast-adopted with peekInset=\(Int(peekInset)) (not poll)",
                adopted && engine.isManaged(newEl))

        for w in world.snapshot() where w.pid == seedPID { world.destroyWindow(w.element, notify: false) }
        Headless.pump(0.02)
    }
    fastAdoptUnderPeekInset("inset0", peekInset: 0)    // legacy: always worked
    fastAdoptUnderPeekInset("inset48", peekInset: 48)  // production default: the regression

    // =====================================================================
    // Section 5. Inactive-workspace removal: a window CLOSED while parked in an
    // inactive vertical workspace must still be reaped (eventually) so it does
    // not linger as a zombie column. The active-strip-only removeSlots scan in
    // applyResync does not see inactive workspaces, so the reap happens when the
    // user returns to that workspace and the poll runs. We pin that contract.
    // =====================================================================
    do {
        let f = Headless.defaultVisibleFrame
        let engine = TeleportEngine(screenFrame: f)
        let pidA: pid_t = 7600, pidB: pid_t = 7601
        _ = world.addWindow(pid: pidA, title: "ZA",
                            frame: CGRect(x: f.minX + 40, y: f.minY + 40, width: 360, height: 420))
        let elB = world.addWindow(pid: pidB, title: "ZB",
                            frame: CGRect(x: f.minX + 440, y: f.minY + 40, width: 360, height: 420))
        let pids: [pid_t] = [pidA, pidB]
        Headless.arrangeCurrentSpace(engine, pids: pids)
        engine.focusIndex = engine.slots.firstIndex { $0.window.title == "ZB" } ?? 0
        _ = engine.moveFocusedToWorkspace(by: 1)  // ZB -> ws2 active, ZA parked
        _ = engine.switchWorkspace(by: -1)        // back to ws1 (ZA active), ZB parked
        t.check("S5 ZB parked in inactive workspace", engine.isManaged(elB) && engine.slots.count == 1)

        let monitor = LifecycleMonitor(engine: engine, interval: 30.0)
        monitor.pidFilter = Set(pids)
        monitor.start()
        defer { monitor.stop() }

        // Close ZB (gone from AX) while it is parked in the inactive workspace.
        world.destroyWindow(elB, notify: true)
        Headless.pump(0.1)
        monitor.resync(); Headless.pump(0.1)
        // CURRENT behavior: the active-only removeSlots scan does not reach ws2,
        // so ZB lingers as a managed zombie until the user returns to ws2.
        t.check("S5 (current) closed parked window lingers in inactive workspace",
                engine.allManagedSlots.contains { CFEqual($0.window.element, elB) })

        // Returning to ws2 + resyncing reaps it (the active scan now sees it gone).
        _ = engine.switchWorkspace(by: 1)
        Headless.pump(0.05)
        monitor.resync(); Headless.pump(0.1)
        t.check("S5 returning to the workspace reaps the closed zombie",
                !engine.allManagedSlots.contains { CFEqual($0.window.element, elB) })

        for w in world.snapshot() where pids.contains(w.pid) { world.destroyWindow(w.element, notify: false) }
    }

    print("\n[headless-movetest] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}

/// PURE design helpers for the movement/lifecycle track. These are NOT wired
/// into production (the brief defers behavior changes); they are the classifiers
/// the design doc (`docs/spaces/04_movement_lifecycle.md`) recommends folding
/// into `ResyncPlanner` once a Space-divergence policy is agreed, exercised here
/// as oracles so the recommendation is backed by a runnable test.
enum MovementLifecycle {
    /// Managed strip windows that have DIVERGED from the rest of the strip: they
    /// are absent from the current-Space set while OTHER strip windows are still
    /// present (so the user did not switch Spaces - the window was sent away).
    /// Returns the PIDs that look like phantom columns. Empty when the whole
    /// strip is off the current Space (that is a Space switch -> freeze, handled
    /// elsewhere) or when nothing diverged.
    static func divergedManagedWindows(stripPIDs: [pid_t],
                                       currentSpacePIDs: Set<pid_t>) -> [pid_t] {
        let present = stripPIDs.filter { currentSpacePIDs.contains($0) }
        // No strip window on the current Space -> a whole-strip Space switch, not
        // a per-window divergence. Leave it to the freeze rule.
        guard !present.isEmpty else { return [] }
        return stripPIDs.filter { !currentSpacePIDs.contains($0) }
    }
}
