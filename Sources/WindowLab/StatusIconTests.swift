import Foundation
import ApplicationServices
import AppKit

// MARK: - statusicontest (headless): the status icon refreshes on EVERY event
//
// The menu-bar status item (the live mini-map `MenuBarStripView`) AND the
// floating per-display indicators must repaint promptly on EVERY event that can
// change what they should show - including the two that historically slipped
// through: a native macOS Space (Desktop) switch (G1) and a monitor hotplug /
// rearrange / resolution change (G2). This suite drives the REAL
// `ScrollWMController` (multi-display, per-monitor strips) against the in-memory
// `SimWindowWorld` and asserts the menu-bar refresh counter (`debugMenuBarRefreshCount`,
// bumped once per `ProductionMenuBar.refresh()`) increases for each event class.
//
// Headless honesty: the floating indicator PANELS are suppressed under
// `AXSource.backend` (no NSWindow is ever created), but `refresh()` /
// `refreshCount` and the per-strip geometry rebind still run, so the assertions
// are on `debugMenuBarRefreshCount` (the refresh actually fired) and on each
// strip's rebound `screenFrame` / `stripDisplayFrame` (every strip followed its
// display). No real window / monitor / Space / keystroke is ever touched.
//
// Two side-by-side displays in AX coords (mirrors `displaymovetest`):
//   Display 0 (primary/main): x in [0, 1600)   id 1000
//   Display 1:                x in [1600, 3200) id 1001
//
// Run: `WindowLab statusicontest` (headless; default). Part of `headlesstest`.

func runHeadlessStatusIconTest() {
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

    let world = Headless.install()
    defer { Headless.uninstall(); RestoreStore.clear() }
    var t = TestCounter()

    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    // Two side-by-side 1600x1000 displays (32px menu-bar inset on the visible).
    let d0Full = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let d0Vis  = CGRect(x: 0, y: 32, width: 1600, height: 968)
    let d1Full = CGRect(x: 1600, y: 0, width: 1600, height: 1000)
    let d1Vis  = CGRect(x: 1600, y: 32, width: 1600, height: 968)
    controller.debugEnableMultiDisplay([(d0Full, d0Vis), (d1Full, d1Vis)])

    // Seed 2 windows on display 0 and 1 window on display 1 (each on its own pid).
    let pidA: pid_t = 8200, pidB: pid_t = 8201   // display 0
    let pidC: pid_t = 8202                        // display 1
    _ = world.addWindow(pid: pidA, title: "A0",
                        frame: CGRect(x: 60, y: 80, width: 360, height: 420))
    _ = world.addWindow(pid: pidB, title: "B0",
                        frame: CGRect(x: 460, y: 80, width: 360, height: 420))
    _ = world.addWindow(pid: pidC, title: "C1",
                        frame: CGRect(x: 1660, y: 80, width: 360, height: 420))
    var sandboxPIDs: Set<pid_t> = [pidA, pidB, pidC]
    controller.sandboxPIDs = sandboxPIDs

    controller.arrange()
    Headless.pump(0.2)
    t.check("setup: two strips manage after multi-display arrange",
            controller.debugStripTitles.count == 2)
    t.check("setup: 3 windows arranged across the displays",
            controller.debugStripTitles.reduce(0) { $0 + $1.count } == 3)
    t.check("setup: active strip starts on display 0", controller.debugActiveStripIndex == 0)

    // Small helper: an action must strictly increase the menu-bar refresh count
    // (i.e. it repainted the status item + floating indicators). `settle` pumps
    // the main run loop long enough for an async refresh (engine onLayoutChange
    // hops to main) or a debounced one (the Space-change reaction) to land.
    func expectRefresh(_ name: String, settle: TimeInterval = 0.08, _ action: () -> Void) {
        Headless.pump(0.02)                       // drain any in-flight refresh
        let before = controller.debugMenuBarRefreshCount
        action()
        Headless.pump(settle)
        t.check("\(name) refreshes the status icon",
                controller.debugMenuBarRefreshCount > before)
    }

    // =====================================================================
    // G3 - every user-visible state change refreshes the icon.
    // =====================================================================
    expectRefresh("focus move") { controller.focusNext() }
    expectRefresh("width preset") { controller.setWidthPreset(0) }
    expectRefresh("move column") { controller.moveFocused(by: 1) }
    expectRefresh("workspace switch") { controller.switchWorkspace(by: 1) }
    expectRefresh("workspace switch back") { controller.switchWorkspace(by: -1) }
    expectRefresh("move-to-workspace") { controller.moveFocusedToWorkspace(by: 1) }
    // Bring the window back to the active workspace so later steps have a focus.
    expectRefresh("move-to-workspace back") { controller.moveFocusedToWorkspace(by: -1) }

    // resync ADD: a stray standard window appears on the active strip's display
    // and is auto-tiled on the next resync (-> engine onLayoutChange -> refresh).
    let strayPID: pid_t = 8300
    let activeFrame = controller.debugScreenFrame   // active strip = display 0
    _ = world.addWindow(pid: strayPID, title: "Stray0",
                        frame: CGRect(x: activeFrame.minX + 40, y: activeFrame.minY + 40,
                                      width: 360, height: 360),
                        subrole: kAXStandardWindowSubrole as String)
    sandboxPIDs.insert(strayPID)
    controller.debugSetLifecyclePIDFilter(sandboxPIDs)   // active strip's monitor
    let slotsBeforeAdd = controller.debugSlotCount
    expectRefresh("resync add (auto-tile)", settle: 0.18) { controller.debugTriggerResync() }
    t.check("resync add actually grew the active strip",
            controller.debugSlotCount == slotsBeforeAdd + 1)

    // resync REMOVE: destroy the stray; the resync drops its column (-> refresh).
    if let strayEl = world.snapshot().first(where: { $0.pid == strayPID })?.element {
        world.destroyWindow(strayEl, notify: false)
    }
    expectRefresh("resync remove", settle: 0.18) { controller.debugTriggerResync() }
    t.check("resync remove shrank the active strip back",
            controller.debugSlotCount == slotsBeforeAdd)

    // FLOATING change: a dialog/panel appears (never auto-tiled) so it joins the
    // floating set; the monitor's onFloatingChange drives a refresh.
    let dialogPID: pid_t = 8400
    _ = world.addWindow(pid: dialogPID, title: "Dialog0",
                        frame: CGRect(x: activeFrame.minX + 80, y: activeFrame.minY + 80,
                                      width: 280, height: 160),
                        subrole: kAXDialogSubrole as String)
    sandboxPIDs.insert(dialogPID)
    controller.debugSetLifecyclePIDFilter(sandboxPIDs)
    expectRefresh("floating set change", settle: 0.18) { controller.debugTriggerResync() }

    // reload-config: re-reads the config + re-applies sizing -> refresh.
    expectRefresh("reload config") { controller.reloadConfig() }

    // Cross-display focus + move (multi-display verbs).
    expectRefresh("focus display") { controller.debugFocusDisplay(by: 1) }
    expectRefresh("move-to-display") { controller.debugMoveFocusedToDisplay(by: 1) }

    // close: closes the focused window (-> engine.closeFocused -> refresh).
    expectRefresh("close window", settle: 0.18) { controller.closeFocused() }

    // arrange/toggle: release then arrange both repaint the icon.
    expectRefresh("toggle release") { controller.release() }
    t.check("toggle release went dormant", !controller.isManaging)
    expectRefresh("toggle arrange", settle: 0.2) { controller.arrange() }
    t.check("toggle arrange resumed managing", controller.isManaging)

    // =====================================================================
    // G1 - native macOS Space (Desktop) switch repaints the icon, EVEN when the
    // strip freezes (its windows are off the active Space, so the monitor's own
    // Space-driven resync mutates nothing and never fires onLayoutChange).
    // =====================================================================
    Headless.pump(0.1)
    // Drive the REAL wired observer: the sim posts NSWorkspace.activeSpaceDidChange
    // on a switch. Moving to empty Space 2 freezes both strips, so a refresh here
    // can ONLY come from the controller's own Space observer (G1's fix).
    do {
        Headless.pump(0.05)
        let before = controller.debugMenuBarRefreshCount
        world.setActiveSpace(2)                  // strips freeze (windows on Space 1)
        Headless.pump(0.3)                       // past the 0.12s controller debounce
        t.check("G1 frozen-Space switch (wired observer) refreshes the icon",
                controller.debugMenuBarRefreshCount > before)
    }
    // And the explicit headless seam drives the same path deterministically while
    // still on the frozen Space 2.
    do {
        Headless.pump(0.05)
        let before = controller.debugMenuBarRefreshCount
        controller.debugHandleActiveSpaceChange()
        Headless.pump(0.25)
        t.check("G1 debugHandleActiveSpaceChange() seam refreshes the icon",
                controller.debugMenuBarRefreshCount > before)
    }
    world.setActiveSpace(1)                       // back to the strips' Space
    Headless.pump(0.2)

    // =====================================================================
    // G2 - monitor hotplug / rearrange / resolution change ALWAYS repaints the
    // icon AND rebinds EVERY strip to its resolved display (not just the active
    // one). Drives the REAL settled-display-change path with injected snapshots.
    // =====================================================================
    // AppKit (bottom-left) display sets with stable ids matching the strips'
    // (1000, 1001). full == visible (no inset) keeps the flip arithmetic simple.
    func appkit(_ x: CGFloat, _ w: CGFloat, _ h: CGFloat, _ id: CGDirectDisplayID)
        -> (full: CGRect, visible: CGRect, id: CGDirectDisplayID?) {
        let f = CGRect(x: x, y: 0, width: w, height: h)
        return (full: f, visible: f, id: id)
    }

    // G2a - resolution change of BOTH displays (both present): both strips must
    // rebind to the new geometry and the icon must refresh.
    let beforeFrames = controller.debugStripScreenFrames
    let resBefore = controller.debugMenuBarRefreshCount
    controller.debugApplyDisplayChange([appkit(0, 1440, 900, 1000),
                                        appkit(1440, 1440, 900, 1001)])
    Headless.pump(0.1)
    let afterFrames = controller.debugStripScreenFrames
    t.check("G2a resolution change refreshed the icon",
            controller.debugMenuBarRefreshCount > resBefore)
    t.check("G2a rebound EVERY strip (both screenFrames changed)",
            beforeFrames.count == 2 && afterFrames.count == 2
                && afterFrames[0] != beforeFrames[0] && afterFrames[1] != beforeFrames[1])

    // G2b - UNPLUG the external (display 1 / id 1001): the icon must refresh even
    // though the surviving strip merely follows / migrates.
    let unplugBefore = controller.debugMenuBarRefreshCount
    controller.debugApplyDisplayChange([appkit(0, 1440, 900, 1000)])
    Headless.pump(0.1)
    t.check("G2b unplug external refreshed the icon",
            controller.debugMenuBarRefreshCount > unplugBefore)

    // G2c - REPLUG the external: the icon must refresh again as the screen set
    // grows back (the floating-indicator reconcile point).
    let replugBefore = controller.debugMenuBarRefreshCount
    controller.debugApplyDisplayChange([appkit(0, 1440, 900, 1000),
                                        appkit(1440, 1440, 900, 1001)])
    Headless.pump(0.1)
    t.check("G2c replug external refreshed the icon",
            controller.debugMenuBarRefreshCount > replugBefore)

    // G2d - DORMANT path: even with NO managing strip (nothing relays out), a
    // settled display change must STILL refresh so the floating indicators
    // reconcile to the live screen set. This is the "ALWAYS refresh at the end"
    // guarantee that the relayout+managing-gated per-strip refresh does not cover.
    controller.release()
    Headless.pump(0.1)
    t.check("G2d setup: controller is dormant", !controller.isManaging)
    let dormantBefore = controller.debugMenuBarRefreshCount
    controller.debugApplyDisplayChange([appkit(0, 1600, 1000, 1000),
                                        appkit(1600, 1600, 1000, 1001)])
    Headless.pump(0.1)
    t.check("G2d settled display change refreshes the icon even while DORMANT",
            controller.debugMenuBarRefreshCount > dormantBefore)

    print("\n[headless-statusicon] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}
