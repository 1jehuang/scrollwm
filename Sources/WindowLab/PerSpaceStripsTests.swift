import Foundation
import ApplicationServices
import AppKit

// HEADLESS per-native-Space strips test (Model B, the feature the user asked
// for: each macOS Desktop gets its OWN ScrollWM strip).
//
// Runs the REAL `ScrollWMController` + `LifecycleMonitor` + `TeleportEngine`
// against an in-memory `SimWindowWorld`. The sim's `setActiveSpace` posts the
// REAL `NSWorkspace.activeSpaceDidChangeNotification` (so the production observer
// fires exactly as on a live Ctrl-arrow / Mission Control switch) and answers the
// read-only Space-id probe (`currentSpaceID()`) from its modeled active Space, so
// the entire per-Space code path is exercised with NO real window/Space/keyboard.
//
// What it pins (the invariants from docs/spaces/02_ownership.md):
//   1. Each native Space keeps its own columns + viewport; switching Desktops
//      re-points the live strip and restores the layout you left.
//   2. A window opened on Space B is tiled on B's strip - NOT ignored (the old
//      "frozen on a different Space" trap) and NOT pulled onto A.
//   3. Windows never bleed across Spaces; both Spaces' windows persist.
//   4. Returning to a Space restores its exact strip (order + identity).
//   5. Graceful fallback: with the probe unavailable, it stays single-strip.

func runHeadlessPerSpaceStripsTest() {
    let world = Headless.install()
    defer { Headless.uninstall() }
    var t = TestCounter()

    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    // Single 1600x1000 display. The sim starts on native Space 1.
    // Seed two windows on Space 1; they become Space 1's strip.
    let a: pid_t = 9300, b: pid_t = 9301      // Space 1
    let c: pid_t = 9302                        // opened later on Space 2
    _ = world.addWindow(pid: a, title: "A1",
                        frame: CGRect(x: 60, y: 80, width: 360, height: 420))
    _ = world.addWindow(pid: b, title: "B1",
                        frame: CGRect(x: 460, y: 80, width: 360, height: 420))
    // Sandbox-lock to all pids we will ever use (incl. the Space-2 window), so
    // arrange + the fast-adopt observer only ever see our sim windows.
    controller.sandboxPIDs = [a, b, c]
    controller.debugEnablePerSpaceStrips()

    controller.arrange()
    Headless.pump(0.2)

    // --- Arrange binds the live strip to the Space it ran on (Space 1). ---
    // Capture the arranged order: arrange enumerates `sandboxPIDs` (a Set), so
    // the column order is whatever that yields - the round-trip must restore
    // THAT exact order, so we compare against it rather than a hardcoded order.
    let space1Order = controller.debugActiveStripColumnTitles
    t.check("arrange adopted the 2 Space-1 windows",
            Set(space1Order) == ["A1", "B1"])
    t.check("live strip is bound to native Space 1",
            controller.debugActiveSpaceID == 1)
    t.check("only Space 1 is tracked so far",
            controller.debugTrackedSpaceIDs == [1])

    // === 1. Switch to Space 2 (empty). The strip re-points to Space 2's own
    //        (empty) strip; Space 1's columns are stashed, not dropped. ===
    world.setActiveSpace(2)
    Headless.pump(0.2)
    t.check("after switching to Space 2 the live strip is bound to Space 2",
            controller.debugActiveSpaceID == 2)
    t.check("Space 2 starts with its OWN empty strip",
            controller.debugActiveStripColumnTitles.isEmpty)
    t.check("Space 1's 2 windows are stashed (still managed across Spaces)",
            controller.debugAllSpacesManagedCount == 2)
    t.check("both Spaces are now tracked",
            controller.debugTrackedSpaceIDs == [1, 2])

    // === 2. Open a window WHILE on Space 2. The old model would freeze and
    //        ignore it; per-Space strips tile it on Space 2's strip. ===
    _ = world.addWindow(pid: c, title: "C2",
                        frame: CGRect(x: 200, y: 120, width: 360, height: 420),
                        notify: true)            // fires the fast-adopt path
    Headless.pump(0.3)
    t.check("a window opened on Space 2 is tiled on Space 2's strip (not ignored)",
            controller.debugActiveStripColumnTitles == ["C2"])
    t.check("the Space-2 window did NOT leak onto Space 1 (3 windows total across Spaces)",
            controller.debugAllSpacesManagedCount == 3)

    // === 3. Return to Space 1. Its exact 2-column strip comes back; the Space-2
    //        window is stashed (does not bleed onto Space 1). ===
    world.setActiveSpace(1)
    Headless.pump(0.2)
    t.check("back on Space 1, the live strip is bound to Space 1",
            controller.debugActiveSpaceID == 1)
    t.check("Space 1's original 2 columns are restored, in order",
            controller.debugActiveStripColumnTitles == space1Order)
    t.check("the Space-2 window stays on Space 2 (no bleed onto Space 1)",
            !controller.debugActiveStripColumnTitles.contains("C2"))
    t.check("all three windows still managed across the two Spaces",
            controller.debugAllSpacesManagedCount == 3)

    // === 4. Round-trip back to Space 2: its single column is intact. ===
    world.setActiveSpace(2)
    Headless.pump(0.2)
    t.check("Space 2's strip still holds exactly its own window after the round trip",
            controller.debugActiveStripColumnTitles == ["C2"])

    controller.release()
    Headless.pump(0.1)
    t.check("Release ends Space tracking (back to single-strip model)",
            controller.debugActiveSpaceID == nil)

    scrollWMControllerKeepAlive = nil
    print("\n[headless-perspace] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}

// HEADLESS graceful-degradation test: when the read-only Space-id probe is
// UNAVAILABLE on the host (the private CGS symbol could not be resolved), the
// per-Space feature must silently fall back to the single-strip model - never
// crash, never refuse to arrange.
func runHeadlessPerSpaceFallbackTest() {
    let world = Headless.install()
    defer { Headless.uninstall() }
    var t = TestCounter()
    world.spaceIDProbeUnavailable = true       // model "symbol missing on this host"

    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    let a: pid_t = 9400, b: pid_t = 9401
    _ = world.addWindow(pid: a, title: "A",
                        frame: CGRect(x: 60, y: 80, width: 360, height: 420))
    _ = world.addWindow(pid: b, title: "B",
                        frame: CGRect(x: 460, y: 80, width: 360, height: 420))
    controller.sandboxPIDs = [a, b]
    controller.debugEnablePerSpaceStrips()

    controller.arrange()
    Headless.pump(0.2)
    t.check("arrange still works with the probe unavailable",
            Set(controller.debugActiveStripColumnTitles) == ["A", "B"])
    t.check("per-Space tracking did NOT start (no stable Space id) -> single-strip model",
            controller.debugActiveSpaceID == nil)

    // A Space switch is a harmless no-op for the engine's Space layer; the strip
    // behaves exactly as the historical single-strip model (freeze/thaw).
    world.setActiveSpace(2)
    Headless.pump(0.2)
    t.check("Space switch does not start tracking when the probe is unavailable",
            controller.debugActiveSpaceID == nil)
    t.check("strip keeps its columns (frozen, not dropped) on the foreign Space",
            controller.debugAllSpacesManagedCount == 2)

    controller.release()
    scrollWMControllerKeepAlive = nil
    print("\n[headless-perspace-fallback] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}
