import Foundation
import ApplicationServices
import AppKit

// MARK: - exthotplugtest (headless): plug/unplug the above-left external
//
// External-monitor track "hotplug". The user runs a single strip on the BUILT-IN
// with an external LG ULTRAFINE ABOVE-and-LEFT. This drives the REAL settled-
// display-change policy (StripDisplayResolver -> refreshDisplayGeometry) through
// the three events that matter for that layout:
//
//   1. UNPLUG the external while the strip is on the built-in: the strip must
//      STAY on the built-in (its own display by stable id is still present),
//      windows untouched, and the "others" parking set must drop the external.
//   2. RE-PLUG the external: the strip stays on the built-in, geometry refreshes
//      so the external is back in the parking "others" set (parking still avoids
//      it). No window is moved onto the external.
//   3. UNPLUG the BUILT-IN (the strip's own display) while the external is the
//      survivor: the strip MIGRATES to the external and lands every window on it,
//      none stranded off-screen.
//
// AppKit coords (bottom-left origin) for the real hardware, used by the injection
// hooks (debugBindStrip / debugApplyDisplayChange take AppKit frames):
//   - Built-in: full (0,0,1710x1112), visible (0,0,1710x1073), id 1, MAIN+PRIMARY.
//   - External: full (-105,1112,1920x1080), id 2 (above-and-left).
// Fully headless: no real window, no focus theft, no keystroke.

private struct HPDisplay {
    let full: CGRect       // AppKit full frame (bottom-left origin)
    let visible: CGRect    // AppKit visible frame
    let id: CGDirectDisplayID?
}

func runHeadlessExternalHotplugTest() {
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()
    var t = TestCounter()

    // Real hardware in AppKit coords.
    let builtin = HPDisplay(full: CGRect(x: 0, y: 0, width: 1710, height: 1112),
                            visible: CGRect(x: 0, y: 0, width: 1710, height: 1073), id: 1)
    let external = HPDisplay(full: CGRect(x: -105, y: 1112, width: 1920, height: 1080),
                             visible: CGRect(x: -105, y: 1112, width: 1920, height: 1080), id: 2)

    // AppKit (bottom-left) -> AX (top-left) flip around the primary height. The
    // primary is the display whose AppKit origin is (0,0) -> the built-in (1112).
    func axFlip(_ f: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }
    func tuples(_ ds: [HPDisplay]) -> [(full: CGRect, visible: CGRect, id: CGDirectDisplayID?)] {
        ds.map { (full: $0.full, visible: $0.visible, id: $0.id) }
    }
    func worldDisplays(_ ds: [HPDisplay], primaryHeight: CGFloat) -> [CGRect] {
        ds.map { axFlip($0.full, primaryHeight: primaryHeight) }
    }

    let bothPrimaryH: CGFloat = 1112   // built-in is primary while present

    // =====================================================================
    // Setup: strip on the BUILT-IN, external above-left present, 3 windows.
    // =====================================================================
    let both: [HPDisplay] = [builtin, external]
    let world = Headless.install(displays: worldDisplays(both, primaryHeight: bothPrimaryH))
    defer { Headless.uninstall(); RestoreStore.clear() }
    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    controller.debugBindStrip(to: tuples(both), stripIndex: 0) // strip on built-in
    let stripVisible = controller.debugScreenFrame
    let (pids, _) = Headless.seedWindows(
        world, count: 3, startPID: 7900, within: stripVisible, width: 360, height: 360)
    controller.sandboxPIDs = Set(pids)
    func liveFrames() -> [CGRect] {
        controller.debugSlotTitles.compactMap { title in
            pids.flatMap { AXSource.windows(forPID: $0) }.first { $0.title == title }?.frame
        }
    }
    controller.arrange(pidFilter: Set(pids))
    Headless.pump(0.1)
    t.check("setup: 3 windows arranged on the built-in strip", controller.debugSlotCount == 3)
    let builtinAX = axFlip(builtin.full, primaryHeight: bothPrimaryH)
    t.check("setup: strip bound to the built-in display",
            controller.debugStripDisplayFrame.map { approxEqualRectHP($0, builtinAX) } ?? false)
    t.check("setup: external is in the parking 'others' set",
            controller.debugOtherDisplayFrames.contains {
                approxEqualRectHP($0, axFlip(external.full, primaryHeight: bothPrimaryH)) })

    // =====================================================================
    // 1. UNPLUG the external. Strip stays on the built-in; external drops out of
    //    the parking 'others' set; no window moves off the built-in.
    // =====================================================================
    let onlyBuiltin: [HPDisplay] = [builtin]
    world.displays = worldDisplays(onlyBuiltin, primaryHeight: bothPrimaryH)
    controller.debugApplyDisplayChange(tuples(onlyBuiltin))
    Headless.pump(0.1)
    t.check("1 unplug external: strip STAYS on the built-in",
            controller.debugStripDisplayFrame.map { approxEqualRectHP($0, builtinAX) } ?? false)
    t.check("1 unplug external: parking 'others' set is now empty",
            controller.debugOtherDisplayFrames.isEmpty)
    t.check("1 unplug external: every window still on the built-in",
            liveFrames().allSatisfy { DisplayGeometry.overlapArea($0, builtinAX) > 0 })
    t.check("1 unplug external: 3 columns intact (none evicted)", controller.debugSlotCount == 3)

    // =====================================================================
    // 2. RE-PLUG the external. Strip stays on the built-in; external is back in
    //    the parking 'others' set; no window is moved onto the external.
    // =====================================================================
    world.displays = worldDisplays(both, primaryHeight: bothPrimaryH)
    controller.debugApplyDisplayChange(tuples(both))
    Headless.pump(0.1)
    t.check("2 re-plug external: strip STILL on the built-in",
            controller.debugStripDisplayFrame.map { approxEqualRectHP($0, builtinAX) } ?? false)
    t.check("2 re-plug external: external back in the parking 'others' set",
            controller.debugOtherDisplayFrames.contains {
                approxEqualRectHP($0, axFlip(external.full, primaryHeight: bothPrimaryH)) })
    t.check("2 re-plug external: no window moved onto the external",
            liveFrames().allSatisfy { DisplayGeometry.overlapArea($0, builtinAX) > 0 })
    t.check("2 re-plug external: 3 columns intact", controller.debugSlotCount == 3)

    // =====================================================================
    // 3. UNPLUG the BUILT-IN (the strip's own display). The external becomes the
    //    only survivor and the new primary; the strip MIGRATES onto it and every
    //    window lands on-screen there.
    // =====================================================================
    // With the built-in gone, the external is the new AppKit-origin primary.
    // Re-express it at origin (0,0); primary height becomes the external's 1080.
    let externalAlone = HPDisplay(
        full: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visible: CGRect(x: 0, y: 0, width: 1920, height: 1080), id: 2)
    let onlyExternal: [HPDisplay] = [externalAlone]
    let extPrimaryH: CGFloat = 1080
    let extAloneAX = axFlip(externalAlone.full, primaryHeight: extPrimaryH)
    world.displays = worldDisplays(onlyExternal, primaryHeight: extPrimaryH)
    controller.debugApplyDisplayChange(tuples(onlyExternal))
    Headless.pump(0.1)
    t.check("3 unplug built-in: strip MIGRATED to the external",
            controller.debugStripDisplayFrame.map { approxEqualRectHP($0, extAloneAX) } ?? false)
    t.check("3 unplug built-in: 3 columns survived the migration", controller.debugSlotCount == 3)
    let frames = liveFrames()
    t.check("3 unplug built-in: every window landed on the external",
            !frames.isEmpty && frames.allSatisfy { DisplayGeometry.overlapArea($0, extAloneAX) > 0 })
    t.check("3 unplug built-in: no window stranded off all displays",
            frames.allSatisfy { f in
                worldDisplays(onlyExternal, primaryHeight: extPrimaryH).contains { $0.intersects(f) } })

    controller.release()
    Headless.pump(0.05)
    print("\n[headless-exthotplugtest] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}

private func approxEqualRectHP(_ a: CGRect, _ b: CGRect, tol: CGFloat = 1) -> Bool {
    abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
        && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
}
