import Foundation
import ApplicationServices
import AppKit

// HEADLESS Space-change DETECTION / SIGNAL test (Track 1).
//
// Track 5 owns the sim-Space MODEL (`SimWindowWorld` native Spaces + the
// `subscribeActiveSpace` hook) and the MEMBERSHIP/freeze policy proof
// (`spacetest`). THIS suite proves the orthogonal claim Track 1 investigates:
// ScrollWM has NO Space-change signal today, so after a native Space switch the
// strip stays STALE for up to the safety-net poll `interval` (2s in prod), and
// shows how an `NSWorkspace.activeSpaceDidChangeNotification`-style hook
// collapses that gap to ~one resync (single-digit ms headless).
//
// It runs the EXACT production `LifecycleMonitor` against an in-memory
// `SimWindowWorld`: no real window is spawned/moved/focused/closed, no global
// keystroke injected. It modifies NO production behavior - the "immediate
// resync on Space change" is wired in the TEST via the sim's
// `subscribeActiveSpace` hook calling the existing `monitor.resync()`, exactly
// the design Track 1's doc recommends shipping.
//
// Determinism: the monitor's safety-net poll is set to a deliberately SLOW 5s,
// so ANY adoption observed under ~1s came from a SIGNAL (the Space hook), never
// the poll. The "stale" assertions check a sub-poll window (0.8s) in which the
// poll provably cannot have fired.

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

    // Real production monitor, SLOW poll so a prompt reaction must be a signal.
    // Filter to our pids so it never enumerates anything but the sim windows.
    let monitor = LifecycleMonitor(engine: engine, interval: 5.0)
    monitor.pidFilter = Set(stripPIDs + [stripPID + 10, stripPID + 11])
    monitor.start()
    Headless.pump(0.1) // let the observer subscribe

    // ===================================================================
    // PART A — THE DETECTION GAP (no Space signal observed): a native Space
    // switch fires NO window-created/destroyed/launch event, so the monitor
    // never re-evaluates. A window that appears on the strip's OWN Space while
    // the user is away is therefore NOT in the strip on return, and STAYS
    // missing until the 2s safety-net poll. We prove it is still missing across
    // a sub-poll window, and that ZERO resyncs ran across two Space switches.
    // ===================================================================
    let resyncAtStart = monitor.resyncCount

    // User switches AWAY to Space 2 (Ctrl-Right / Mission Control). With no
    // subscriber this is invisible to ScrollWM.
    world.setActiveSpace(2)
    Headless.pump(0.1)
    // While viewing Space 2, the strip's windows are off-screen, so the pure
    // policy (Track 5's helper) would freeze - but nothing RUNS it without a
    // trigger. Confirm the policy itself agrees this is a different Space.
    t.check("policy: strip is frozen while viewing another Space (no current-Space windows)",
            Headless.resyncDecision(engine, pids: stripPIDs) == .frozenDifferentSpace)

    // A new window opens on the strip's Space (Space 1) WHILE the user is on
    // Space 2 - e.g. an app you left on that Desktop opens a document window.
    // notify:false => NO kAXWindowCreated reaches us (it is off the active
    // Space; the WindowServer would not list it on-screen, and our fast path's
    // current-Space gate would reject it anyway). So nothing schedules a resync.
    let lateEl = world.addWindow(pid: stripPID + 10, title: "Late-OnSpace1",
                                 frame: CGRect(x: 860, y: 80, width: 360, height: 420),
                                 nativeSpace: 1)

    // User switches BACK to Space 1. The strip's windows AND the new window are
    // now all on-screen. But switching Spaces fires no event ScrollWM observes,
    // so the monitor does not re-run.
    world.setActiveSpace(1)
    let staleDeadline = Date().addingTimeInterval(0.8) // << the 5s poll
    while Date() < staleDeadline {
        Headless.pump(0.02)
        if engine.isManaged(lateEl) { break } // would only happen if a resync ran
    }
    t.check("GAP: window present on the strip's Space is NOT adopted on return (stale until poll)",
            !engine.isManaged(lateEl))
    t.check("GAP: strip still holds only its original 2 columns after the Space round-trip",
            engine.slots.count == 2)
    t.check("GAP: ZERO resyncs ran across two native Space switches (no signal exists)",
            monitor.resyncCount == resyncAtStart)

    // ===================================================================
    // PART B — THE SIGNAL FIX (observe activeSpaceDidChange): wire the sim's
    // Space hook to the EXISTING `monitor.resync()`. This is precisely the
    // design Track 1 recommends - observe NSWorkspace.activeSpaceDidChange and
    // trigger an immediate resync. The previously-stale window is now adopted
    // within a single resync (~ms), not after the multi-second poll.
    // ===================================================================
    var spaceSignals = 0
    world.subscribeActiveSpace { _ in
        spaceSignals += 1
        monitor.resync()
    }

    // First signal fires for the transition we are ALREADY on? No: the hook
    // fires only on a CHANGE. Round-trip again to drive it. Drop the still-
    // unmanaged Part-A window first so the only newly-adoptable window is the
    // one we time, keeping the latency attribution unambiguous.
    world.destroyWindow(lateEl, notify: false)
    Headless.pump(0.05)

    world.setActiveSpace(2)             // away (fires signal -> resync, strip freezes)
    Headless.pump(0.1)
    let newEl = world.addWindow(pid: stripPID + 11, title: "Opened-OnSpace1",
                                frame: CGRect(x: 860, y: 80, width: 360, height: 420),
                                nativeSpace: 1)
    let switchBackT0 = Clock.nowAbsNs()
    world.setActiveSpace(1)             // back (fires signal -> resync -> adopt)

    var adoptedNs: UInt64?
    let signalDeadline = Clock.nowAbsNs() + 2_000_000_000
    while Clock.nowAbsNs() < signalDeadline {
        Headless.pump(0.005)
        if engine.isManaged(newEl) { adoptedNs = Clock.nowAbsNs(); break }
    }
    if let adoptedNs {
        let ms = Double(adoptedNs &- switchBackT0) / 1e6
        print(String(format: "[headless-spacedetect] Space-signal adoption in %.1f ms", ms))
        t.check("FIX: activeSpaceDidChange signal adopts the on-Space window on return", true)
        t.check(String(format: "FIX: adoption was signal-fast, not the 5s poll (%.0fms < 500)", ms),
                ms < 500)
    } else {
        t.check("FIX: activeSpaceDidChange signal adopts the on-Space window on return", false)
    }
    t.check("FIX: the Space hook actually fired (>=2 transitions observed)", spaceSignals >= 2)
    t.check("FIX: at least one resync ran, driven by the Space signal",
            monitor.resyncCount > resyncAtStart)

    monitor.stop()
    world.subscribeActiveSpace(nil)
    print("\n[headless-spacedetect] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}
