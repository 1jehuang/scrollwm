import Foundation
import ApplicationServices
import AppKit

// MARK: - extadopttest (headless): single-strip adoption leaves the external alone
//
// External-monitor track "new-window / arrange adoption" for the user's ACTUAL
// configuration: multiDisplay=false (one strip on the built-in), adoptScope=
// stripDisplay, one Mission Control Space spanning BOTH monitors. The WindowServer
// on-screen list therefore includes EXTERNAL windows too, and the strip must:
//   - adopt ONLY built-in windows on arrange,
//   - never fast-adopt a window opened on the external,
//   - still fast-adopt a window opened on the built-in,
//   - never resync-adopt an external window appearing later.
//
// Grounded in the real layout (AX top-left global coords):
//   - Built-in (strip): full (0,0,1710x1112), visible (0,0,1710x1073).
//   - External LG ABOVE-and-LEFT: full (-105,-1080,1920x1080).
// Fully headless: no real window, no focus theft, no keystroke.

func runHeadlessExternalAdoptTest() {
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

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
        e.peekInset = 48
        return e
    }
    // A frame centered on the external monitor (above-and-left of the built-in).
    func externalFrame(_ i: Int = 0) -> CGRect {
        CGRect(x: 200 + CGFloat(i) * 80, y: -700, width: 500, height: 360)
    }
    // A frame on the built-in strip display.
    func builtinFrame(_ i: Int) -> CGRect {
        CGRect(x: 40 + CGFloat(i) * 420, y: 60, width: 360, height: 420)
    }

    // =====================================================================
    // Section 1. arrange adopts ONLY built-in windows; external left alone.
    // =====================================================================
    do {
        let engine = makeEngine()
        let b1: pid_t = 9100, b2: pid_t = 9101
        let x1: pid_t = 9102, x2: pid_t = 9103
        _ = world.addWindow(pid: b1, title: "Built-1", frame: builtinFrame(0))
        _ = world.addWindow(pid: b2, title: "Built-2", frame: builtinFrame(1))
        let xe1 = world.addWindow(pid: x1, title: "Ext-1", frame: externalFrame(0))
        let xe2 = world.addWindow(pid: x2, title: "Ext-2", frame: externalFrame(1))
        let allPids: [pid_t] = [b1, b2, x1, x2]

        // Mirror production arrange's onscreen scoping (Headless.arrangeCurrentSpace
        // adopts everything onscreen; here we exercise the SAME filterByAdoptScope
        // the real arrange applies before adopting).
        let ax = allPids.flatMap { AXSource.windows(forPID: $0) }
        let matched = IdentityMatcher.match(
            axWindows: ax, cgWindows: CGWindowSource.listWindows(onscreenOnly: true))
            .filter { $0.cg != nil }
        let scoped = engine.filterByAdoptScope(matched) { $0.ax.frame }
        engine.adopt(matched: scoped)

        t.check("S1 arrange adopted exactly the 2 built-in windows",
                engine.slots.count == 2)
        t.check("S1 adopted set is Built-1 + Built-2",
                Set(engine.slots.map { $0.window.title }) == ["Built-1", "Built-2"])
        t.check("S1 external windows NOT adopted",
                !engine.isManaged(xe1) && !engine.isManaged(xe2))
        // External frames untouched (still on the external display).
        t.check("S1 external windows left on the external display",
                [xe1, xe2].allSatisfy { el in
                    world.frame(of: el).map {
                        DisplayGeometry.display(bestOverlapping: $0,
                            displays: [stripFull, externalFull]) == externalFull
                    } ?? false
                })
    }

    // =====================================================================
    // Section 2. fast-adopt: a window OPENED on the external is never adopted,
    // while a window opened on the built-in IS adopted (and lands right-of-focus).
    // =====================================================================
    do {
        let engine = makeEngine()
        let pid: pid_t = 9200
        _ = world.addWindow(pid: pid, title: "Seed", frame: builtinFrame(0))
        let matched = IdentityMatcher.match(
            axWindows: AXSource.windows(forPID: pid),
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)).filter { $0.cg != nil }
        engine.adopt(matched: matched)
        t.check("S2 seed adopted", engine.slots.count == 1)

        let monitor = LifecycleMonitor(engine: engine, interval: 5.0)
        monitor.pidFilter = [pid]
        monitor.start(); defer { monitor.stop() }
        Headless.pump(0.1)

        // Open a new window for this pid ON THE EXTERNAL: fires the create event.
        let extEl = world.addWindow(pid: pid, title: "Seed-Ext",
                                    frame: externalFrame(0), notify: true)
        // Give the fast-adopt path + all its bounded retries time to run.
        Headless.pump(0.6)
        t.check("S2 external window NOT fast-adopted",
                engine.slots.count == 1 && !engine.isManaged(extEl))
        t.check("S2 external window left on the external",
                world.frame(of: extEl).map {
                    DisplayGeometry.display(bestOverlapping: $0,
                        displays: [stripFull, externalFull]) == externalFull
                } ?? false)

        // Now open a window on the BUILT-IN: it must be fast-adopted.
        let inEl = world.addWindow(pid: pid, title: "Seed-In",
                                   frame: builtinFrame(1), notify: true)
        var adopted = false
        let deadline = Clock.nowAbsNs() + 2_000_000_000
        while Clock.nowAbsNs() < deadline {
            Headless.pump(0.01)
            if engine.isManaged(inEl) { adopted = true; break }
        }
        t.check("S2 built-in window IS fast-adopted", adopted && engine.slots.count == 2)
    }

    // =====================================================================
    // Section 3. resync: an external window appearing between polls is never
    // adopted by the resync path either (same pure scope rule).
    // =====================================================================
    do {
        let engine = makeEngine()
        let pid: pid_t = 9300
        _ = world.addWindow(pid: pid, title: "Base", frame: builtinFrame(0))
        let m = IdentityMatcher.match(
            axWindows: AXSource.windows(forPID: pid),
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)).filter { $0.cg != nil }
        engine.adopt(matched: m)
        let monitor = LifecycleMonitor(engine: engine, interval: 30.0)
        monitor.pidFilter = [pid]
        monitor.start(); defer { monitor.stop() }

        // Add an external window for the SAME pid WITHOUT a create event, so only
        // the resync poll could pick it up.
        let extEl = world.addWindow(pid: pid, title: "Base-Ext", frame: externalFrame(0))
        monitor.resync()
        Headless.pump(0.1)
        t.check("S3 resync does NOT adopt the external window",
                engine.slots.count == 1 && !engine.isManaged(extEl))
    }

    print("\n[headless-extadopttest] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}
