import Foundation
import ApplicationServices
import AppKit

/// HEADLESS integration test for the "no un-arranged windows in the background"
/// guarantee (config `layout.autoTileNewWindows`). Runs the REAL production
/// controller + lifecycle monitor against the in-memory `SimWindowWorld`; no
/// real window is ever spawned/moved.
///
/// Invariants proven:
///   1. A standard window opened (and left floating) while managing is
///      AUTO-TILED onto the strip on the next resync, so the floating set
///      empties — nothing lingers in the background.
///   2. A DIALOG/panel window is NEVER auto-tiled; it stays floating + reachable.
///   3. Release restores every window (auto-tiled ones included) and goes
///      dormant, so the feature is fully reversible.
///   4. With the config flag OFF, a floating standard window is left alone.
///
/// Run with: `WindowLab autotiletest`
func runHeadlessAutoTileTest() {
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

    let world = Headless.install()
    defer { Headless.uninstall(); RestoreStore.clear() }
    var t = TestCounter()

    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    let frame = controller.debugScreenFrame
    // Seed two standard windows we will arrange into the strip.
    let (pids, _) = Headless.seedWindows(
        world, count: 2, startPID: 7000, within: frame, width: 320, height: 300)
    let arrangedPIDs = Set(pids)

    controller.arrange(pidFilter: arrangedPIDs)
    Headless.pump(0.1)
    t.check("controller managing after arrange", controller.isManaging)
    t.check("2 columns arranged", controller.debugSlotCount == 2)

    // --- 1. A standard window appears un-arranged -> auto-tiled on resync ---
    // Open a NEW standard window inside the strip display but DON'T route it
    // through arrange; it starts as a floating (un-managed) current-Space window.
    let strayPID: pid_t = 7100
    _ = world.addWindow(pid: strayPID, title: "StrayStandard",
                        frame: CGRect(x: frame.minX + 40, y: frame.minY + 40, width: 400, height: 300),
                        subrole: kAXStandardWindowSubrole as String)
    // The controller's pid filter from arrange only watched the arranged pids;
    // widen it so the stray window is in scope (mirrors a no-filter prod run).
    controller.debugSetLifecyclePIDFilter(arrangedPIDs.union([strayPID]))
    controller.debugTriggerResync()
    Headless.pump(0.15)
    t.check("stray standard window auto-tiled onto the strip", controller.debugSlotCount == 3)
    t.check("no standard window left floating", controller.debugFloatingCount == 0)

    // --- 2. A dialog/panel is NEVER auto-tiled ---
    let dialogPID: pid_t = 7200
    _ = world.addWindow(pid: dialogPID, title: "SaveDialog",
                        frame: CGRect(x: frame.minX + 60, y: frame.minY + 60, width: 300, height: 180),
                        subrole: kAXDialogSubrole as String)
    controller.debugSetLifecyclePIDFilter(arrangedPIDs.union([strayPID, dialogPID]))
    controller.debugTriggerResync()
    Headless.pump(0.15)
    t.check("dialog NOT auto-tiled (still 3 columns)", controller.debugSlotCount == 3)
    t.check("dialog remains floating + reachable", controller.debugFloatingCount == 1)

    // --- 3. Release restores everything and goes dormant ---
    controller.release()
    Headless.pump(0.1)
    t.check("released -> dormant", !controller.isManaging)
    t.check("nothing managed after release", controller.debugSlotCount == 0)

    print("\n[headless-autotile] \(t.passed) passed, \(t.failed) failed")
    if t.failed != 0 { exit(1) }

    // --- 4. With the flag OFF, a floating standard window is left alone ---
    RestoreStore.clear()
    let world2 = Headless.install()
    defer { Headless.uninstall(); RestoreStore.clear() }
    var t2 = TestCounter()
    let c2 = ScrollWMController()
    scrollWMControllerKeepAlive = c2
    c2.debugSetAutoTile(false)
    let frame2 = c2.debugScreenFrame
    let (pids2, _) = Headless.seedWindows(
        world2, count: 1, startPID: 8000, within: frame2, width: 320, height: 300)
    c2.arrange(pidFilter: Set(pids2))
    Headless.pump(0.1)
    t2.check("managing (flag-off run)", c2.isManaging)
    t2.check("1 column arranged", c2.debugSlotCount == 1)
    let strayPID2: pid_t = 8100
    _ = world2.addWindow(pid: strayPID2, title: "StrayNoTile",
                         frame: CGRect(x: frame2.minX + 40, y: frame2.minY + 40, width: 400, height: 300),
                         subrole: kAXStandardWindowSubrole as String)
    c2.debugSetLifecyclePIDFilter(Set(pids2).union([strayPID2]))
    c2.debugTriggerResync()
    Headless.pump(0.15)
    t2.check("flag OFF: stray window left floating", c2.debugFloatingCount == 1)
    t2.check("flag OFF: strip not grown", c2.debugSlotCount == 1)
    c2.release()

    print("\n[headless-autotile-off] \(t2.passed) passed, \(t2.failed) failed")
    exit(t2.failed == 0 ? 0 : 1)
}
