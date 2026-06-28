import Foundation
import ApplicationServices
import AppKit

// HEADLESS multi-display per-native-Space strips test ("Displays have separate
// Spaces": each MONITOR has its own active Desktop, and each monitor's strip
// must follow ITS OWN Desktop independently).
//
// Runs the REAL `ScrollWMController` (multi-display) + per-strip `LifecycleMonitor`
// + `TeleportEngine` + the per-display Space-id probe against `SimWindowWorld`.
// The sim models a separate active Space PER display (`registerDisplays` +
// `setActiveSpace(forDisplay:)`) and the on-screen list hides a window whose
// display is showing a different Desktop - exactly the macOS fidelity. No real
// window/monitor/Space/keyboard is ever touched.
//
// What it pins:
//   1. Each (display, Space) gets its own strip.
//   2. Switching display 1's Desktop re-points ONLY display 1's strip; display 0
//      keeps its columns untouched (the multi-display win the single-display
//      model could not give).
//   3. A window opened on display 1's new Desktop tiles on THAT strip, and does
//      not bleed onto display 0 or display 1's other Desktop.
//   4. Returning each display to its first Desktop restores its strip.

func runHeadlessMultiDisplayPerSpaceTest() {
    let world = Headless.install()
    defer { Headless.uninstall() }
    var t = TestCounter()

    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    // Two side-by-side displays. `debugEnableMultiDisplay` assigns synthetic
    // display ids 1000 + index, so display 0 -> 1000, display 1 -> 1001.
    let d0Full = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let d0Vis  = CGRect(x: 0, y: 32, width: 1600, height: 968)
    let d1Full = CGRect(x: 1600, y: 0, width: 1600, height: 1000)
    let d1Vis  = CGRect(x: 1600, y: 32, width: 1600, height: 968)
    controller.debugEnableMultiDisplay([(d0Full, d0Vis), (d1Full, d1Vis)])
    let dID0: CGDirectDisplayID = 1000
    let dID1: CGDirectDisplayID = 1001

    // Tell the sim the physical displays + that each starts on its own Desktop 1.
    world.registerDisplays([(dID0, d0Full), (dID1, d1Full)])
    world.setActiveSpace(forDisplay: dID0, 1)
    world.setActiveSpace(forDisplay: dID1, 1)

    // Seed: 2 windows on display 0 (Desktop 1), 1 window on display 1 (Desktop 1).
    let a: pid_t = 8300, b: pid_t = 8301   // display 0
    let c: pid_t = 8302                     // display 1
    let later: pid_t = 8303                 // opened later on display 1's Desktop 2
    _ = world.addWindow(pid: a, title: "A0",
                        frame: CGRect(x: 60, y: 80, width: 360, height: 420), nativeSpace: 1)
    _ = world.addWindow(pid: b, title: "B0",
                        frame: CGRect(x: 460, y: 80, width: 360, height: 420), nativeSpace: 1)
    _ = world.addWindow(pid: c, title: "C1",
                        frame: CGRect(x: 1660, y: 80, width: 360, height: 420), nativeSpace: 1)
    controller.sandboxPIDs = [a, b, c, later]
    controller.debugEnablePerSpaceStrips()

    controller.arrange()
    Headless.pump(0.2)

    // --- Each display's strip is bound to its own display's Desktop 1. ---
    let titles = controller.debugStripTitles
    t.check("two strips exist (one per display)", titles.count == 2)
    t.check("display 0 strip adopted its 2 windows", Set(titles[0]) == ["A0", "B0"])
    t.check("display 1 strip adopted its 1 window", titles[1] == ["C1"])
    t.check("each strip is bound to native Space 1",
            controller.debugStripSpaceIDs == [1, 1])
    let d0Order = titles[0]

    // === Switch ONLY display 1 to its Desktop 2. Display 0 must be untouched. ===
    world.setActiveSpace(forDisplay: dID1, 2)
    Headless.pump(0.2)
    let after = controller.debugStripTitles
    t.check("display 0 strip is UNCHANGED by display 1's Desktop switch",
            after[0] == d0Order)
    t.check("display 0 strip still bound to its Desktop 1",
            controller.debugStripSpaceIDs[0] == 1)
    t.check("display 1 strip re-pointed to its Desktop 2 (now empty)",
            after[1].isEmpty && controller.debugStripSpaceIDs[1] == 2)
    t.check("display 1's Desktop-1 window is stashed, not lost",
            controller.debugStripAllSpacesCounts == [2, 1])

    // === Open a window on display 1's Desktop 2. It tiles on display 1's strip
    //     only - not display 0, not display 1's Desktop 1. ===
    _ = world.addWindow(pid: later, title: "Later1",
                        frame: CGRect(x: 1700, y: 120, width: 360, height: 420),
                        notify: true, nativeSpace: 2)
    Headless.pump(0.3)
    let after2 = controller.debugStripTitles
    t.check("window opened on display 1's Desktop 2 tiles on display 1's strip",
            after2[1] == ["Later1"])
    t.check("display 0 strip STILL unchanged (no bleed across displays)",
            after2[0] == d0Order)

    // === Return display 1 to its Desktop 1: its original window comes back. ===
    world.setActiveSpace(forDisplay: dID1, 1)
    Headless.pump(0.2)
    let after3 = controller.debugStripTitles
    t.check("display 1 back on Desktop 1 restores its original window",
            after3[1] == ["C1"])
    t.check("display 0 strip remained constant throughout", after3[0] == d0Order)
    t.check("all four windows still managed across both displays' Desktops",
            controller.debugStripAllSpacesCounts == [2, 2])

    controller.release()
    scrollWMControllerKeepAlive = nil
    print("\n[headless-multidisplay-perspace] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}
