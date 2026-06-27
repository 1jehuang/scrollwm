import Foundation
import ApplicationServices
import AppKit

// HEADLESS multi-display focus / move test.
//
// Exercises the cross-display keybindings:
//   - focusDisplayNext / focusDisplayPrevious (Ctrl+Opt+Cmd+J / K): move keyboard
//     focus to the next/previous MONITOR's strip ("focus follows display").
//   - moveToDisplayNext / moveToDisplayPrevious (Ctrl+Opt+Cmd+Shift+J / K): send
//     the focused window to another monitor's strip and follow it there.
//
// Runs the REAL `ScrollWMController` with its per-display strips against the
// in-memory `SimWindowWorld` (two synthetic displays injected via
// `debugEnableMultiDisplay`). No real window/monitor/keyboard is ever touched.
//
// Two displays, side by side in AX coords:
//   Display 0 (primary): x in [0, 1600)
//   Display 1:           x in [1600, 3200)
// Windows are seeded onto each so the multi-display arrange partitions them by
// best overlap into two managing strips.

func runHeadlessDisplayMoveTest() {
    let world = Headless.install()
    defer { Headless.uninstall() }
    var t = TestCounter()

    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    // Two side-by-side 1600x1000 displays (32px menu-bar inset on the visible).
    let d0Full = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let d0Vis  = CGRect(x: 0, y: 32, width: 1600, height: 968)
    let d1Full = CGRect(x: 1600, y: 0, width: 1600, height: 1000)
    let d1Vis  = CGRect(x: 1600, y: 32, width: 1600, height: 968)
    controller.debugEnableMultiDisplay([(d0Full, d0Vis), (d1Full, d1Vis)])

    // Seed 2 windows on display 0 and 1 window on display 1.
    let pidA: pid_t = 8100, pidB: pid_t = 8101  // display 0
    let pidC: pid_t = 8102                       // display 1
    _ = world.addWindow(pid: pidA, title: "A0",
                        frame: CGRect(x: 60, y: 80, width: 360, height: 420))
    _ = world.addWindow(pid: pidB, title: "B0",
                        frame: CGRect(x: 460, y: 80, width: 360, height: 420))
    _ = world.addWindow(pid: pidC, title: "C1",
                        frame: CGRect(x: 1660, y: 80, width: 360, height: 420))
    let pids: [pid_t] = [pidA, pidB, pidC]
    controller.sandboxPIDs = Set(pids)

    controller.arrange()
    Headless.pump(0.2)

    // --- Arrange partitioned windows across the two displays' strips. ---
    let titles = controller.debugStripTitles
    t.check("two strips exist (one per display)", titles.count == 2)
    t.check("display 0 strip adopted its 2 windows", Set(titles[0]) == ["A0", "B0"])
    t.check("display 1 strip adopted its 1 window", titles[1] == ["C1"])
    // The active strip starts on the primary (display 0).
    t.check("active strip starts on display 0", controller.debugActiveStripIndex == 0)

    // === 1. focusDisplayNext moves the active strip to display 1. ===
    world.resetActivateSpy()
    controller.debugFocusDisplay(by: 1)
    Headless.pump(0.1)
    t.check("focusDisplayNext makes display 1 active",
            controller.debugActiveStripIndex == 1)
    // Focusing the destination strip activates ITS focused window's app (C1),
    // moving the keyboard focus to that monitor.
    t.check("focusDisplayNext activated the destination monitor's window (C1)",
            world.activateAppCalls.contains(pidC))

    // === 2. focusDisplayNext wraps back to display 0. ===
    controller.debugFocusDisplay(by: 1)
    Headless.pump(0.1)
    t.check("focusDisplayNext wraps from display 1 back to display 0",
            controller.debugActiveStripIndex == 0)

    // === 3. focusDisplayPrevious from display 0 wraps to display 1. ===
    controller.debugFocusDisplay(by: -1)
    Headless.pump(0.1)
    t.check("focusDisplayPrevious wraps from display 0 to display 1",
            controller.debugActiveStripIndex == 1)

    // Back to display 0 for the move tests.
    controller.debugFocusDisplay(by: 1)
    Headless.pump(0.1)
    t.check("back on display 0", controller.debugActiveStripIndex == 0)

    // === 4. moveToDisplayNext sends the focused window (display 0) to display 1. ===
    // Focus B0 on display 0 by its title (arrange column order is not guaranteed
    // since the pidFilter is a Set), then send it to display 1.
    let b0Index = controller.debugStripTitles[0].firstIndex(of: "B0") ?? 0
    controller.focus(index: b0Index)
    Headless.pump(0.1)
    let beforeMove = controller.debugStripTitles
    t.check("pre-move: display 0 has [A0, B0]", Set(beforeMove[0]) == ["A0", "B0"])
    t.check("pre-move: B0 is focused", controller.debugFocusedTitle == "B0")
    controller.debugMoveFocusedToDisplay(by: 1)
    Headless.pump(0.1)
    let afterMove = controller.debugStripTitles
    t.check("moveToDisplayNext removed the window from display 0",
            afterMove[0] == ["A0"])
    t.check("moveToDisplayNext added the window to display 1",
            Set(afterMove[1]) == ["B0", "C1"])
    t.check("moveToDisplayNext follows the window (active strip is now display 1)",
            controller.debugActiveStripIndex == 1)

    // The moved window's frame must now sit on display 1's x-span (it was
    // physically teleported onto the other monitor), proving it is not stranded
    // on the old display.
    if let b0 = world.snapshot().first(where: { $0.pid == pidB }) {
        t.check("moved window B0 is physically on display 1 (x >= 1600)",
                b0.frame.origin.x >= 1600 - 1)
    } else {
        t.check("moved window B0 located", false)
    }

    // === 5. moveToDisplayPrevious sends it back to display 0. ===
    // B0 is focused on display 1 (we followed it). Send it back.
    controller.debugMoveFocusedToDisplay(by: -1)
    Headless.pump(0.1)
    let afterBack = controller.debugStripTitles
    t.check("moveToDisplayPrevious returned the window to display 0",
            Set(afterBack[0]) == ["A0", "B0"])
    t.check("moveToDisplayPrevious left display 1 with just C1",
            afterBack[1] == ["C1"])
    t.check("moveToDisplayPrevious follows back to display 0",
            controller.debugActiveStripIndex == 0)
    if let b0 = world.snapshot().first(where: { $0.pid == pidB }) {
        t.check("returned window B0 is physically back on display 0 (x < 1600)",
                b0.frame.origin.x < 1600)
    } else {
        t.check("returned window B0 located", false)
    }

    controller.release()
    Headless.pump(0.1)

    print("\n[headless-displaymove] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}
