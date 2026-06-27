import Foundation
import ApplicationServices
import AppKit

// MARK: - dragofftest (headless): evict a managed window dragged to another display
//
// External-monitor track "drag-off": with one Mission Control Space spanning
// BOTH monitors and the default `stripDisplay` adopt scope (a single strip bound
// to the built-in), what happens when the user DRAGS a managed strip column onto
// the EXTERNAL display?
//
// The removal rule in `applyResync` keys on AX existence, so a dragged window -
// which still exists in AX and is still on the current Space - is KEPT as a
// managed column. The very next teleport then repositions it back onto the
// strip's display, fighting the user (the "yank-back" bug). The fix
// (`TeleportEngine.evictDraggedOffDisplay` + the pure
// `AdoptionScope.evictedFromStripDisplay`) drops such a column from the strip and
// leaves it exactly where the user put it, while NEVER evicting a column that is
// merely PARKED off the strip's own edge.
//
// Grounded in the user's REAL hardware layout (AX top-left global coords):
//   - Built-in (strip display): full (0,0,1710x1112), visible (0,0,1710x1073).
//   - External LG ULTRAFINE ABOVE-and-LEFT: full (-105,-1080,1920x1080).
// Fully headless: no real window, no focus theft, no keystroke.

func runHeadlessDragOffTest() {
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

    // The real two-display geometry the user runs (AX top-left plane).
    let stripFull = CGRect(x: 0, y: 0, width: 1710, height: 1112)
    let stripVisible = CGRect(x: 0, y: 0, width: 1710, height: 1073)
    let externalFull = CGRect(x: -105, y: -1080, width: 1920, height: 1080)

    let world = Headless.install(displays: [stripFull, externalFull])
    defer { Headless.uninstall(); RestoreStore.clear() }
    var t = TestCounter()

    func makeEngine() -> TeleportEngine {
        let e = TeleportEngine(screenFrame: stripVisible)
        e.stripDisplayFrame = stripFull
        e.otherDisplayFrames = [externalFull]
        e.adoptScope = .stripDisplay
        e.peekInset = 48 // production default, so parking math matches reality
        return e
    }

    // =====================================================================
    // Section 1. A managed window dragged onto the EXTERNAL is EVICTED (dropped
    // from the strip, left where the user put it) instead of being yanked back.
    // =====================================================================
    do {
        let engine = makeEngine()
        let pidL: pid_t = 8100, pidM: pid_t = 8101, pidR: pid_t = 8102
        _ = world.addWindow(pid: pidL, title: "Left",
                            frame: CGRect(x: 40, y: 40, width: 360, height: 420))
        let elM = world.addWindow(pid: pidM, title: "Mid",
                            frame: CGRect(x: 440, y: 40, width: 360, height: 420))
        _ = world.addWindow(pid: pidR, title: "Right",
                            frame: CGRect(x: 840, y: 40, width: 360, height: 420))
        let pids: [pid_t] = [pidL, pidM, pidR]
        Headless.arrangeCurrentSpace(engine, pids: pids)
        t.check("S1 arranged 3 columns on the strip display", engine.slots.count == 3)

        let monitor = LifecycleMonitor(engine: engine, interval: 30.0)
        monitor.pidFilter = Set(pids)
        monitor.start()
        defer { monitor.stop() }

        let rightCanvasBefore = engine.slots.first { $0.window.title == "Right" }?.canvasX

        // User DRAGS "Mid" fully onto the external monitor (above-and-left). Its
        // frame now best-overlaps the external, but it still exists in AX and is
        // still on the current Space (one Space spans both displays).
        world.debugSetFrame(elM, CGRect(x: -50, y: -900, width: 360, height: 420))
        t.check("S1 dragged window still exists in AX",
                AXSource.windows(forPID: pidM).count == 1)
        t.check("S1 dragged window's frame best-overlaps the EXTERNAL display",
                DisplayGeometry.display(bestOverlapping:
                    AXSource.windows(forPID: pidM)[0].frame,
                    displays: [stripFull, externalFull]) == externalFull)

        monitor.resync()
        Headless.pump(0.1)

        // The fix: the dragged column is EVICTED, not kept-and-yanked.
        t.check("S1 dragged window is EVICTED from the strip",
                engine.slots.count == 2 && !engine.isManaged(elM))
        t.check("S1 only Left + Right remain",
                Set(engine.slots.map { $0.window.title }) == ["Left", "Right"])

        // The evicted window was NOT moved back: its frame stays on the external.
        let mFrameAfter = AXSource.windows(forPID: pidM).first?.frame
        t.check("S1 evicted window left on the external (NOT yanked back)",
                mFrameAfter.map {
                    DisplayGeometry.display(bestOverlapping: $0,
                        displays: [stripFull, externalFull]) == externalFull
                } ?? false)

        // The strip compacted: "Right" slid left to fill the gap (no phantom).
        let rightCanvasAfter = engine.slots.first { $0.window.title == "Right" }?.canvasX
        t.check("S1 strip compacted after eviction (Right pulled in)",
                (rightCanvasAfter ?? .greatestFiniteMagnitude) < (rightCanvasBefore ?? 0))
    }

    // =====================================================================
    // Section 2. A column merely PARKED off the strip's own edge is NEVER
    // evicted. With many full-width columns, the non-focused ones scroll off and
    // park; their engine-driven off-screen frame must not be mistaken for a drag.
    // =====================================================================
    do {
        let engine = makeEngine()
        let pids: [pid_t] = [8200, 8201, 8202, 8203]
        for (i, pid) in pids.enumerated() {
            _ = world.addWindow(pid: pid, title: "P\(i)",
                                frame: CGRect(x: 40 + CGFloat(i) * 400, y: 40,
                                              width: 360, height: 420))
        }
        Headless.arrangeCurrentSpace(engine, pids: pids)
        t.check("S2 arranged 4 columns", engine.slots.count == 4)

        let monitor = LifecycleMonitor(engine: engine, interval: 30.0)
        monitor.pidFilter = Set(pids)
        monitor.start()
        defer { monitor.stop() }

        // Make every column full-width and focus the LAST, so the earlier columns
        // scroll fully off the left and PARK (engine shoves them to parkingX).
        for i in 0..<engine.slots.count {
            engine.focus(index: i)
            _ = engine.setFocusedWidth(fraction: 1.0)
        }
        engine.focus(index: engine.slots.count - 1)
        Headless.pump(0.1)
        let parkedCount = (0..<engine.slots.count).filter { engine.slotIsParked($0) }.count
        t.check("S2 at least one column is parked off-screen", parkedCount >= 1)

        monitor.resync()
        Headless.pump(0.1)

        // None of the parked columns may be evicted: they belong to the strip,
        // the engine just parked them. All 4 stay managed.
        t.check("S2 parked columns are NOT evicted (all 4 still managed)",
                engine.slots.count == 4)
    }

    // =====================================================================
    // Section 3. Scope + single-display guards: `allDisplays` never evicts, and a
    // setup with no other displays never evicts (single-monitor users unaffected).
    // =====================================================================
    do {
        // allDisplays scope keeps a window even if it sits on another monitor.
        let engine = makeEngine()
        engine.adoptScope = .allDisplays
        let pid: pid_t = 8300
        let el = world.addWindow(pid: pid, title: "Legacy",
                                 frame: CGRect(x: 200, y: 40, width: 360, height: 420))
        Headless.arrangeCurrentSpace(engine, pids: [pid])
        let monitor = LifecycleMonitor(engine: engine, interval: 30.0)
        monitor.pidFilter = Set([pid]); monitor.start(); defer { monitor.stop() }
        world.debugSetFrame(el, CGRect(x: -50, y: -900, width: 360, height: 420))
        monitor.resync(); Headless.pump(0.1)
        t.check("S3 allDisplays scope NEVER evicts (legacy whole-desktop strip)",
                engine.slots.count == 1 && engine.isManaged(el))

        // No other displays => single-monitor => never evicts.
        let solo = TeleportEngine(screenFrame: stripVisible)
        solo.stripDisplayFrame = stripFull
        solo.otherDisplayFrames = []
        solo.adoptScope = .stripDisplay
        let sFrame = CGRect(x: 200, y: 40, width: 360, height: 420)
        let pid2: pid_t = 8301
        let el2 = world.addWindow(pid: pid2, title: "Solo", frame: sFrame)
        Headless.arrangeCurrentSpace(solo, pids: [pid2])
        let m2 = LifecycleMonitor(engine: solo, interval: 30.0)
        m2.pidFilter = Set([pid2]); m2.start(); defer { m2.stop() }
        // Even a wild frame cannot evict when there are no other displays.
        world.debugSetFrame(el2, CGRect(x: -50, y: -900, width: 360, height: 420))
        m2.resync(); Headless.pump(0.1)
        t.check("S3 single-display setup NEVER evicts",
                solo.slots.count == 1 && solo.isManaged(el2))
    }

    print("\n[headless-dragofftest] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}
