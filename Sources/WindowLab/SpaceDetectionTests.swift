import Foundation
import ApplicationServices
import AppKit

// HEADLESS Space-change DETECTION / SIGNAL test (Track 1, now SHIPPED).
//
// ScrollWM now observes `NSWorkspace.activeSpaceDidChangeNotification` and runs a
// debounced `resync()` on every native Space change (LifecycleMonitor.start ->
// scheduleSpaceResync). This suite proves that shipped wiring end-to-end against
// an in-memory `SimWindowWorld`: no real window is spawned/moved/focused/closed,
// no global keystroke injected. The sim's `setActiveSpace` posts the REAL public
// notification on `NSWorkspace.shared.notificationCenter`, so the production
// observer fires exactly as it would on a live Ctrl-arrow / Mission Control /
// fullscreen-Space switch.
//
// Determinism: the monitor's safety-net poll is set to a deliberately SLOW 5s,
// so ANY adoption observed under ~1s came from the SIGNAL (the Space observer),
// never the poll. Before this shipped, a Space switch fired none of the other
// triggers and the strip stayed stale until that 5s poll; that historical gap is
// documented in `docs/spaces/01_detection.md` and was pinned by this suite's
// earlier revision.

func runHeadlessSpaceDetectionTest() {
    let world = Headless.install()
    defer { Headless.uninstall() }
    var t = TestCounter()

    let engine = TeleportEngine(screenFrame: Headless.defaultVisibleFrame)

    // Two windows on Space 1 (the world's initial active Space). These become
    // the strip; the strip thus "belongs" to Space 1.
    let stripPID: pid_t = 7000
    let aEl = world.addWindow(pid: stripPID, title: "Strip-A",
                              frame: CGRect(x: 60, y: 80, width: 360, height: 420))
    let bEl = world.addWindow(pid: stripPID + 1, title: "Strip-B",
                              frame: CGRect(x: 460, y: 80, width: 360, height: 420))
    _ = aEl; _ = bEl
    let stripPIDs = [stripPID, stripPID + 1]

    Headless.arrangeCurrentSpace(engine, pids: stripPIDs)
    t.check("seeded strip adopts its 2 Space-1 windows", engine.slots.count == 2)
    guard engine.slots.count == 2 else {
        print("\n[headless-spacedetect] \(t.passed) passed, \(t.failed) failed"); exit(1)
    }

    // Real production monitor, SLOW poll so a prompt reaction must be the signal.
    // Filter to our pids so it never enumerates anything but the sim windows.
    let monitor = LifecycleMonitor(engine: engine, interval: 5.0)
    monitor.pidFilter = Set(stripPIDs + [stripPID + 10, stripPID + 11])
    monitor.start()
    Headless.pump(0.1) // let the observers subscribe

    // ===================================================================
    // PART A — THE SHIPPED SIGNAL: a native Space switch now triggers a
    // debounced resync, so a window that appeared on the strip's OWN Space while
    // the user was away is adopted within ONE signal-fast resync on return, not
    // after the multi-second safety-net poll. This is the exact scenario that
    // used to be the detection gap.
    // ===================================================================
    let resyncAtStart = monitor.resyncCount

    // User switches AWAY to Space 2 (Ctrl-Right / Mission Control). The sim posts
    // the real activeSpaceDidChange notification -> the monitor resyncs (and the
    // strip freezes, since its windows are off-screen on Space 2).
    world.setActiveSpace(2)
    Headless.pump(0.2)
    t.check("policy: strip is frozen while viewing another Space (no current-Space windows)",
            Headless.resyncDecision(engine, pids: stripPIDs) == .frozenDifferentSpace)
    t.check("SIGNAL: switching away fired a Space-driven resync",
            monitor.resyncCount > resyncAtStart)
    t.check("away on Space 2: strip kept its 2 columns (frozen, not dropped)",
            engine.slots.count == 2)

    // A new window opens on the strip's Space (Space 1) WHILE the user is on
    // Space 2 - e.g. an app you left on that Desktop opens a document window. It
    // is off the active Space, so no kAXWindowCreated reaches us (the fast path's
    // current-Space gate would reject it anyway).
    let lateEl = world.addWindow(pid: stripPID + 10, title: "Late-OnSpace1",
                                 frame: CGRect(x: 860, y: 80, width: 360, height: 420),
                                 nativeSpace: 1)
    t.check("while away, the new on-Space-1 window is NOT yet adopted (off the active Space)",
            !engine.isManaged(lateEl))

    // User switches BACK to Space 1. The shipped Space observer fires a debounced
    // resync; the strip's windows AND the new window are now on-screen, so the
    // new window is adopted promptly - WITHOUT waiting for the 5s poll.
    let switchBackT0 = Clock.nowAbsNs()
    world.setActiveSpace(1)
    var adoptedNs: UInt64?
    let signalDeadline = Clock.nowAbsNs() + 2_000_000_000 // << the 5s poll
    while Clock.nowAbsNs() < signalDeadline {
        Headless.pump(0.005)
        if engine.isManaged(lateEl) { adoptedNs = Clock.nowAbsNs(); break }
    }
    if let adoptedNs {
        let ms = Double(adoptedNs &- switchBackT0) / 1e6
        print(String(format: "[headless-spacedetect] Space-signal adoption in %.1f ms", ms))
        t.check("SIGNAL: window present on the strip's Space IS adopted on return", true)
        t.check(String(format: "SIGNAL: adoption was signal-fast, not the 5s poll (%.0fms < 500)", ms),
                ms < 500)
    } else {
        t.check("SIGNAL: window present on the strip's Space IS adopted on return", false)
    }
    t.check("SIGNAL: strip now holds its 2 originals + the late window",
            engine.slots.count == 3 && engine.isManaged(lateEl))

    // ===================================================================
    // PART B — DEBOUNCE: a burst of rapid Space switches must collapse into a
    // bounded number of resyncs (not one per edge), while still converging to the
    // correct final membership. We storm 1<->2 several times quickly and assert
    // the resync count stays well under the number of edges.
    // ===================================================================
    world.destroyWindow(lateEl, notify: false)
    Headless.pump(0.05)
    let resyncBeforeBurst = monitor.resyncCount
    let edges = 8
    for i in 0..<edges {
        world.setActiveSpace(i % 2 == 0 ? 2 : 1)
        Headless.pump(0.005) // faster than the 0.05s debounce -> edges coalesce
    }
    // Let the final debounce settle.
    Headless.pump(0.3)
    world.setActiveSpace(1) // end on the strip's Space
    Headless.pump(0.2)
    let burstResyncs = monitor.resyncCount - resyncBeforeBurst
    t.check("DEBOUNCE: a burst of \(edges) rapid switches coalesced (resyncs < edges)",
            burstResyncs < edges)
    t.check("DEBOUNCE: strip converged back to its 2 original columns",
            engine.slots.count == 2
                && engine.slots.map { $0.window.title } == ["Strip-A", "Strip-B"])

    monitor.stop()
    print("\n[headless-spacedetect] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}
