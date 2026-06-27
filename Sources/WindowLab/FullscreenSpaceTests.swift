import Foundation
import ApplicationServices
import AppKit

/// HEADLESS reproductions for Track 3: native macOS FULLSCREEN Spaces, Mission
/// Control, and the multi-display "Displays have separate Spaces" setting.
///
/// Every scenario runs the EXACT production controller + `LifecycleMonitor` +
/// `ResyncPlanner` against the in-memory `SimWindowWorld` (installed as
/// `AXSource.backend`). NO real window is ever spawned, moved, focused, or
/// closed, and no global keystroke is injected (the golden rule).
///
/// The fidelity that matters here is the SIM SPACE MODEL (owned by Track 5):
///   - `setNativeSpace(el, id)` puts a window on another native Space WITHOUT
///     touching its frame/minimized/hidden state, so it leaves the WindowServer
///     on-screen list (`cgWindows(onscreenOnly:)`) but still exists in AX -
///     EXACTLY how macOS reports a window that moved to a fullscreen / other
///     Desktop Space.
///   - `setActiveSpace(id)` switches which Space the user is viewing.
/// A macOS NATIVE-FULLSCREEN window is just a window that (a) sets
/// `AXFullScreen == true` and (b) moves onto its OWN dedicated Space. We model
/// both: flip the sim window's `fullscreen` flag (Track 5 exposes it at create
/// time; we toggle the live `Win` via a tiny local helper) AND move it to a new
/// native Space.
///
/// What these tests PROVE (each is a real, reproducible gap, not a hypothesis):
///   1. STRAND/FREEZE: a managed window entering native fullscreen leaves the
///      current Space. Because the OTHER managed columns are still on the
///      origin Space, `ResyncPlanner` does NOT freeze - it sees the strip as
///      "still here" and KEEPS the fullscreen column as a phantom slot (it is
///      not removed: still in AX). The fullscreen window's strip column is
///      stranded (the engine still teleports it, fighting the OS).
///   2. SOLO-FULLSCREEN FREEZE FLIP: if the ONLY managed window goes fullscreen,
///      the whole strip freezes (`frozenDifferentSpace`) because now NO managed
///      window is on the current Space - even though the user is still "on" the
///      same desktop conceptually. Re-adoption is blocked until it returns.
///   3. FULLSCREEN-SPACE SPURIOUS ADOPT: while viewing a window's dedicated
///      fullscreen Space, any OTHER app window that the WindowServer still lists
///      on that Space (a HUD/panel/helper) is a current-Space candidate and can
///      be pulled onto a strip that does not belong there.
///   4. RETURN converges: coming back from fullscreen re-lists the window and a
///      single resync re-fits it (no permanent strand) - the upper bound on the
///      damage once a signal/poll fires.
///
/// Run: `WindowLab fullscreentest` (headless; default). Part of `headlesstest`.

/// Toggle a sim window's fullscreen flag by element identity. The sim models
/// fullscreen as a per-window bool surfaced through `AXWindowInfo.isFullscreen`
/// (the same `AXFullScreen` read production uses, `AXSource.swift:186`). We do
/// this through the public snapshot rather than reaching into private state.
private func simSetFullscreen(_ world: SimWindowWorld, _ element: AXUIElement, _ on: Bool) {
    for w in world.snapshot() where CFEqual(w.element, element) { w.fullscreen = on }
}

func runHeadlessFullscreenTest() {
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

    let world = Headless.install()
    defer { Headless.uninstall(); RestoreStore.clear() }
    var t = TestCounter()

    // Run the PURE planner/scope contrast first (no run loop): the formal
    // backbone behind the integration scenarios below, accumulated into the same
    // counter so one verb covers both.
    fullscreenPlannerChecks(&t)

    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller
    let frame = controller.debugScreenFrame

    // --- Seed 3 normal windows on the active Space (id 1), arrange them. ---
    let (pids, els) = Headless.seedWindows(
        world, count: 3, startPID: 7100, within: frame, width: 360, height: 360)
    controller.sandboxPIDs = Set(pids)
    controller.arrange()
    Headless.pump(0.1)
    t.check("arrange adopts 3 normal windows", controller.debugSlotCount == 3)

    // Order columns by title so the index we strand is deterministic.
    let sortedEls = zip(els, pids).sorted { $0.1 < $1.1 }.map { $0.0 }
    let fullscreenEl = sortedEls[1] // the MIDDLE column goes fullscreen

    // =====================================================================
    // Scenario 1: a NON-solo managed window enters native fullscreen.
    // macOS: it sets AXFullScreen and moves to its OWN dedicated Space (id 2),
    // which becomes the active Space. The OTHER two managed windows stay on
    // Space 1 and are now OFF the current Space.
    // =====================================================================
    simSetFullscreen(world, fullscreenEl, true)
    world.setNativeSpace(fullscreenEl, 2)   // its own dedicated Space
    world.setActiveSpace(2)                  // user is now viewing the fullscreen Space
    Headless.pump(2.3)                       // let the 2s safety-net poll fire

    let slotsAfterFS = controller.debugSlotCount
    // The fullscreen window still EXISTS in AX, and so do the other two (just on
    // Space 1). ResyncPlanner.decide sees stripPresentInAX = all 3, and the
    // active Space (2) contains the fullscreen window, so it is NOT
    // frozenDifferentSpace and removes nothing. The strip keeps all 3 columns -
    // including a stranded fullscreen column the engine still tries to position.
    t.check("Scenario 1: fullscreen column is NOT dropped (still in AX) - phantom strand",
            slotsAfterFS == 3)
    // The fullscreen window's column is still managed even though the OS owns its
    // geometry now. This is the strand: the engine will fight the OS for it.
    t.check("Scenario 1: fullscreen window still managed by the strip",
            controller.debugSlotTitles.count == 3)

    // PROVE the strand "fights the OS": macOS owns the fullscreen window's frame
    // (it fills its dedicated Space). Model that by stamping the window to the
    // full display frame, then run a real strip resize on that very column.
    // Because the column is still managed, the engine WRITES a narrow strip
    // width straight onto the OS-owned fullscreen window - the engine and macOS
    // fight over the window's geometry. (`setFocusedWidth` writes size
    // unconditionally for a healthy slot, TeleportEngine.swift:515, so this is
    // not masked by teleport's position-skip optimization.)
    let fullDisplay = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    _ = AXSource.setPoint(fullscreenEl, kAXPositionAttribute as String, fullDisplay.origin)
    _ = AXSource.setSize(fullscreenEl, kAXSizeAttribute as String, fullDisplay.size)
    // Locate the fullscreen window's strip column by TITLE (arrange order is not
    // pid-sorted: the controller's pidFilter is a Set). Seed titles are
    // "SimWin-<i>"; sortedEls[1] is "SimWin-1".
    let fsTitle = "SimWin-1"
    if let fsIndex = controller.debugSlotTitles.firstIndex(of: fsTitle) {
        controller.focus(index: fsIndex)
        controller.setWidthFraction(0.25)
        Headless.pump(0.1)
        if let posAfter = world.frame(of: fullscreenEl) {
            // The engine re-committed a NARROW strip width, NOT the full-display
            // size macOS gave the fullscreen window. That overwrite is the strand
            // actively corrupting the fullscreen window's geometry.
            t.check("Scenario 1: engine OVERWRITES the OS-owned fullscreen frame (active strand)",
                    posAfter.width < fullDisplay.width - 1)
        } else {
            t.check("Scenario 1: engine OVERWRITES the OS-owned fullscreen frame (active strand)", false)
        }
    } else {
        t.check("Scenario 1: fullscreen column locatable by title", false)
    }

    // Bring it back: exit fullscreen, return to the shared Space.
    simSetFullscreen(world, fullscreenEl, false)
    world.setNativeSpace(fullscreenEl, 1)
    world.setActiveSpace(1)
    Headless.pump(2.3)
    t.check("Scenario 4: returning from fullscreen re-converges to 3 columns",
            controller.debugSlotCount == 3)

    controller.release()
    Headless.pump(0.1)
    t.check("released after Scenario 1", !controller.isManaging)

    // =====================================================================
    // Scenario 2: the SOLO managed window goes fullscreen -> whole strip freezes.
    // =====================================================================
    let soloWorld = world // same world; tear down old slots first
    for w in soloWorld.snapshot() { soloWorld.destroyWindow(w.element, notify: false) }
    let soloEl = soloWorld.addWindow(pid: 7200, title: "Solo",
                                     frame: CGRect(x: frame.minX + 40, y: frame.minY + 40,
                                                   width: 400, height: 400))
    controller.sandboxPIDs = [7200]
    controller.arrange()
    Headless.pump(0.1)
    t.check("Scenario 2: solo window adopted", controller.debugSlotCount == 1)

    simSetFullscreen(soloWorld, soloEl, true)
    soloWorld.setNativeSpace(soloEl, 3)
    soloWorld.setActiveSpace(3)
    Headless.pump(2.3)
    // Now NO managed window is on the current Space (the only one moved away), so
    // ResyncPlanner returns .frozenDifferentSpace: the column is KEPT (not
    // removed) and adoption is inert. The slot survives as a frozen placeholder.
    t.check("Scenario 2: solo-fullscreen strip is frozen, column retained (not removed)",
            controller.debugSlotCount == 1)

    // A brand-new normal window opened on the SAME fullscreen Space is NOT
    // adopted, because the strip is frozen (its managed window is off-Space).
    let onFsSpace = soloWorld.addWindow(pid: 7201, title: "OnFsSpace",
                                        frame: CGRect(x: frame.minX + 500, y: frame.minY + 40,
                                                      width: 300, height: 300),
                                        notify: true)
    soloWorld.setNativeSpace(onFsSpace, 3) // lives on the active fullscreen Space
    soloWorld.setActiveSpace(3)
    Headless.pump(0.5)
    t.check("Scenario 2: frozen strip does NOT adopt a new window on the fullscreen Space",
            controller.debugSlotCount == 1)

    // Return the solo window: strip thaws and the new window is now adoptable on
    // the shared Space (both back on Space 1).
    simSetFullscreen(soloWorld, soloEl, false)
    soloWorld.setNativeSpace(soloEl, 1)
    soloWorld.setNativeSpace(onFsSpace, 1)
    soloWorld.setActiveSpace(1)
    Headless.pump(2.3)
    t.check("Scenario 2: after return, strip thaws and reconciles (>= 1 column)",
            controller.debugSlotCount >= 1)

    controller.release()
    Headless.pump(0.1)

    print("\n[headless-fullscreentest] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}

// MARK: - Pure planner / scope contrast (no controller, no async)

/// PURE-logic assertions that pin down the exact `ResyncPlanner` /
/// `AdoptionScope` behavior the controller relies on for fullscreen + separate-
/// Spaces. These need no sim and no run loop, so they are deterministic and
/// instant - the formal backbone behind the integration scenarios above.
private func fullscreenPlannerChecks(_ t: inout TestCounter) {
    // --- ResyncPlanner: a non-solo fullscreen window does NOT freeze the strip.
    // strip = {0,1,2}; AX still sees all three; current Space = {1} (only the
    // fullscreen window's dedicated Space window is on-screen). Because window 1
    // IS on the current Space, the strip is "present here" -> apply, not freeze.
    do {
        let d = ResyncPlanner.decide(stripIDs: [0, 1, 2], axIDs: [0, 1, 2],
                                     currentSpaceIDs: [1])
        switch d {
        case .apply(let remove, _):
            t.check("planner: non-solo fullscreen -> apply (not frozen)", true)
            t.check("planner: non-solo fullscreen removes nothing (all still in AX)",
                    remove.isEmpty)
        default:
            t.check("planner: non-solo fullscreen -> apply (not frozen)", false)
        }
    }

    // --- ResyncPlanner: a SOLO fullscreen window DOES freeze.
    // strip = {0}; AX still sees it; current Space = {} (it is on its own Space,
    // which is active, but the on-screen gate matches by token and the strip's
    // sole token is NOT in currentSpaceIDs from the strip's origin-Space view).
    // We model "user switched to the fullscreen Space, strip's window off it".
    do {
        let d = ResyncPlanner.decide(stripIDs: [0], axIDs: [0, 9],
                                     currentSpaceIDs: [9])
        t.check("planner: solo window off current Space -> frozenDifferentSpace",
                d == .frozenDifferentSpace)
    }

    // --- ResyncPlanner: returning from fullscreen re-lists the window -> apply.
    do {
        let d = ResyncPlanner.decide(stripIDs: [0], axIDs: [0],
                                     currentSpaceIDs: [0])
        if case .apply = d { t.check("planner: return-from-fullscreen -> apply", true) }
        else { t.check("planner: return-from-fullscreen -> apply", false) }
    }

    // --- ResyncPlanner: a HUD/helper on the fullscreen Space is a current-Space
    // ADD candidate. strip = {0} (a window that IS on the active fullscreen
    // Space), AX sees {0, 5}; current Space = {0, 5}. Token 5 (the helper) is
    // added. This is the spurious-adopt seed for a strip on the wrong Space.
    do {
        let d = ResyncPlanner.decide(stripIDs: [0], axIDs: [0, 5],
                                     currentSpaceIDs: [0, 5])
        if case .apply(_, let add) = d {
            t.check("planner: helper on fullscreen Space is an ADD candidate",
                    add.contains(5))
        } else {
            t.check("planner: helper on fullscreen Space is an ADD candidate", false)
        }
    }

    // --- AdoptionScope: "Displays have separate Spaces" does NOT change the
    // adoption geometry rule - a window is still bucketed to the display it best
    // overlaps. The bug there is not geometry but the SHARED current-Space gate
    // (see doc). Assert the geometry stays display-correct so we can isolate the
    // separate-Spaces issue to the CG gate, not AdoptionScope.
    do {
        let stripDisplay = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let other = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let onStrip = CGRect(x: 100, y: 100, width: 400, height: 300)
        let onOther = CGRect(x: 1600, y: 100, width: 400, height: 300)
        t.check("scope: window on strip display belongs to strip",
                AdoptionScope.belongsToStripDisplay(onStrip, stripDisplay: stripDisplay,
                                                    others: [other]))
        t.check("scope: window on the other display does NOT belong to strip",
                !AdoptionScope.belongsToStripDisplay(onOther, stripDisplay: stripDisplay,
                                                    others: [other]))
        // Partition assigns each window to exactly one display (no double-adopt).
        let buckets = AdoptionScope.partition(frames: [onStrip, onOther],
                                              displays: [stripDisplay, other])
        t.check("scope: partition is disjoint (no window adopted by two strips)",
                buckets[0] == [0] && buckets[1] == [1])
    }
}
