import Foundation
import ApplicationServices
import AppKit

// HEADLESS Space focus-guard test (P2a): focusing a strip column whose window
// was sent to another native Space must NEVER activate that window's app,
// because macOS would teleport the user to that Space. We run the REAL
// production controller + engine against the sim and spy on `activateApp`.
//
// Fully headless: no real window/Space/keystroke. The sim's `setNativeSpace`
// moves a window off the active Space (drops out of the on-screen CG list, stays
// in AX) exactly like "send window to Desktop N".
//
// Run: `WindowLab spacefocustest` (headless; default). Part of `headlesstest`.

func runHeadlessSpaceFocusGuardTest() {
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

    let world = Headless.install()
    defer { Headless.uninstall(); RestoreStore.clear() }
    var t = TestCounter()

    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller
    let frame = controller.debugScreenFrame

    // Seed 3 normal windows on the active Space (id 1) and arrange them.
    let (pids, els) = Headless.seedWindows(
        world, count: 3, startPID: 7600, within: frame, width: 360, height: 360)
    controller.sandboxPIDs = Set(pids)
    controller.arrange()
    Headless.pump(0.1)
    t.check("arrange adopts 3 windows", controller.debugSlotCount == 3)

    // Identify each column by title (arrange order is not pid-sorted: pidFilter
    // is a Set). Seed titles are "SimWin-<i>".
    let titles = controller.debugSlotTitles
    guard let awayIndex = titles.firstIndex(of: "SimWin-1"),
          let stayIndex = titles.firstIndex(of: "SimWin-0") else {
        t.check("located the columns by title", false)
        print("\n[headless-spacefocus] \(t.passed) passed, \(t.failed) failed")
        exit(t.summaryExitCode)
    }
    // Map the away column back to its element/pid.
    let awayPID = pids[1]; let awayEl = els[1]
    _ = awayEl

    // === Baseline: focusing an ON-Space column DOES activate (no regression). ===
    world.resetActivateSpy()
    controller.focus(index: stayIndex)
    Headless.pump(0.1)
    t.check("focusing an on-Space column activates its app (baseline)",
            world.activateAppCalls.contains(pids[0]))

    // === Send the middle window to native Space 2 (user stays on Space 1). ===
    world.setNativeSpace(awayEl, 2)
    Headless.pump(0.1)
    t.check("sent window left the current-Space on-screen list",
            !CGWindowSource.listWindows(onscreenOnly: true).contains { $0.ownerPID == awayPID })
    t.check("sent window still managed as a (stranded) strip column",
            controller.debugSlotCount == 3)

    // === The guard: focusing the stranded column must NOT activate its app. ===
    world.resetActivateSpy()
    controller.focus(index: awayIndex)
    Headless.pump(0.1)
    t.check("GUARD: focusing an off-Space column does NOT activate its app (no teleport)",
            !world.activateAppCalls.contains(awayPID))

    // === Bring it back to Space 1: activation is allowed again. ===
    world.setNativeSpace(awayEl, 1)
    Headless.pump(0.1)
    world.resetActivateSpy()
    controller.focus(index: awayIndex)
    Headless.pump(0.1)
    t.check("after return, focusing the column activates its app again",
            world.activateAppCalls.contains(awayPID))

    controller.release()
    Headless.pump(0.1)

    print("\n[headless-spacefocus] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}
