import Foundation
import ApplicationServices
import AppKit

// CLAMSHELL / EQUAL-DISPLAY repro (`WindowLab clamshelltest`).
//
// Reported by a user on an M2 Max MacBook Pro driving TWO external 1440p 120Hz
// monitors with the LAPTOP LID CLOSED (clamshell): "it was glitching out".
//
// The existing displaytest/fuzzdisp cover a strip on a LEFT display with a
// DIFFERENT-SIZE neighbor, and the resolver/engine in pure AX coordinates. What
// they do NOT cover is the controller's live `applySettledDisplayChange`
// AppKit->AX path under the two properties unique to this setup:
//
//   1. CLAMSHELL primary-display change. With the lid open the built-in panel is
//      the AppKit-origin (0,0) PRIMARY and defines the Y-flip height for the
//      WHOLE AX plane. When the lid closes the built-in turns OFF and an external
//      becomes the new primary - a DIFFERENT height - so the Y-flip anchor for
//      every display shifts. A stale primary height lands the strip at the wrong
//      AX Y (windows off the top/bottom, "glitching").
//
//   2. TWO EQUAL displays. The resolver's migration tie-break ("largest
//      survivor") is a TIE, and the macOS sleep/wake burst can transiently drop a
//      display or reorder the set. The strip must FOLLOW its own physical display
//      by stable id and never oscillate between the two equal monitors.
//
// This drives the REAL `ScrollWMController` (hard-locked to sandbox PIDs, against
// the in-memory `SimWindowWorld`) through a clamshell open->closed transition and
// a sleep/wake burst, asserting after every settled change that the managed
// windows stay on ONE display, fully on-screen, with finite geometry and no
// oscillation. Fully HEADLESS: no real window, monitor, or keystroke.

func runClamshellTest() {
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

    func approxEqualRect(_ a: CGRect, _ b: CGRect, tol: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
            && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }
    func rectStrHL(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
    }

    var t = TestCounter()

    // --- Geometry (AppKit: bottom-left origin, primary at (0,0)) -------------
    // Real-ish M2 Max points. Built-in panel ~1512x982 (the primary while the
    // lid is open). Two equal 1440p externals (scaled "looks like 2560x1440").
    let menuBar: CGFloat = 37

    // IDs are stable CGDirectDisplayIDs (the built-in + two externals).
    let builtinID: CGDirectDisplayID = 1
    let extAID: CGDirectDisplayID = 10
    let extBID: CGDirectDisplayID = 20

    // While the lid is OPEN the built-in is primary (origin 0,0). The two
    // externals tile to its right. AppKit visibleFrame trims the menu bar off the
    // top (so its origin.y rises by `menuBar` and height shrinks by it).
    func vis(_ full: CGRect, menu: Bool) -> CGRect {
        menu ? CGRect(x: full.minX, y: full.minY, width: full.width, height: full.height - menuBar)
             : full
    }
    let builtinFull = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let extAFull_open = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
    let extBFull_open = CGRect(x: 1512 + 2560, y: 0, width: 2560, height: 1440)

    // Lid OPEN: built-in primary + two externals (menu bar on the main/built-in).
    let openSet: [(full: CGRect, visible: CGRect, id: CGDirectDisplayID?)] = [
        (builtinFull, vis(builtinFull, menu: true), builtinID),
        (extAFull_open, vis(extAFull_open, menu: false), extAID),
        (extBFull_open, vis(extBFull_open, menu: false), extBID),
    ]

    // Lid CLOSED (clamshell): the built-in is GONE. macOS re-origins the
    // remaining displays so the new primary sits at (0,0). External A becomes the
    // primary at (0,0); external B tiles to its right. The menu bar moves to the
    // new primary (A).
    let extAFull_closed = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let extBFull_closed = CGRect(x: 2560, y: 0, width: 2560, height: 1440)
    let closedSet: [(full: CGRect, visible: CGRect, id: CGDirectDisplayID?)] = [
        (extAFull_closed, vis(extAFull_closed, menu: true), extAID),
        (extBFull_closed, vis(extBFull_closed, menu: false), extBID),
    ]

    // --- Controller bound to the LID-OPEN layout, strip on external B ---------
    // Build the world's displays in AX (top-left) coords for the OPEN layout, so
    // the sim's off-screen clamp models the real monitors. Primary height = 982.
    func axFlip(_ appKitFull: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: appKitFull.minX, y: primaryHeight - appKitFull.maxY,
               width: appKitFull.width, height: appKitFull.height)
    }
    let world = Headless.install(displays: openSet.map { axFlip($0.full, primaryHeight: 982) })
    defer { Headless.uninstall(); RestoreStore.clear() }

    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    // Bind the strip to external B (index 2) under the OPEN layout, as if the user
    // launched ScrollWM on that monitor in clamshell-about-to-happen state.
    controller.debugBindStrip(to: openSet, stripIndex: 2)
    let stripVisibleOpen = controller.debugScreenFrame
    print("[clamshelltest] strip bound to external B (open): \(rectStrHL(stripVisibleOpen))")

    // Seed 3 windows ON external B's visible area and arrange them.
    let bVisAX = stripVisibleOpen
    let (pids, _) = Headless.seedWindows(
        world, count: 3, startPID: 7700, within: bVisAX, width: 360, height: 360)
    controller.sandboxPIDs = Set(pids)
    func liveFrames() -> [CGRect] {
        controller.debugSlotTitles.compactMap { title in
            pids.flatMap { AXSource.windows(forPID: $0) }.first { $0.title == title }?.frame
        }
    }

    controller.arrange(pidFilter: Set(pids))
    Headless.pump(0.1)
    t.check("arranged 3 windows on external B", controller.debugSlotCount == 3)
    guard controller.debugSlotCount == 3 else {
        print("\n[clamshelltest] \(t.passed) passed, \(t.failed) failed"); exit(1)
    }

    // The display the strip is bound to right now, in AX coords (for on-screen
    // checks). Under the OPEN layout external B is at AX full:
    let stripFullOpen = controller.debugStripDisplayFrame!
    var allOnB = true
    for f in liveFrames() where DisplayGeometry.overlapArea(f, stripFullOpen) <= 0 { allOnB = false }
    t.check("windows are on the strip display before the lid closes", allOnB)

    // Helper: every managed window must overlap the strip's CURRENT display, be
    // finite, and not strand off all displays.
    func assertHealthy(_ label: String, worldDisplays: [CGRect]) {
        let stripFull = controller.debugStripDisplayFrame ?? controller.debugScreenFrame
        var onStrip = true, finite = true, onSomeScreen = true
        for f in liveFrames() {
            if !(f.minX.isFinite && f.minY.isFinite && f.width.isFinite && f.height.isFinite) { finite = false }
            if DisplayGeometry.overlapArea(f, stripFull) <= 0 { onStrip = false }
            if !worldDisplays.contains(where: { $0.intersects(f) }) { onSomeScreen = false }
        }
        t.check("\(label): all managed frames are finite", finite)
        t.check("\(label): no managed window stranded off all displays", onSomeScreen)
        t.check("\(label): every managed window is on the strip's own display", onStrip)
    }

    // --- THE LID CLOSE (clamshell). Update the world to the closed layout, then
    // drive the real settled-change policy. Primary height changes 982 -> 1440.
    let closedAX = closedSet.map { axFlip($0.full, primaryHeight: 1440) }
    world.displays = closedAX
    controller.debugApplyDisplayChange(closedSet)
    Headless.pump(0.1)
    let stripFullClosed = controller.debugStripDisplayFrame ?? .null
    print("[clamshelltest] after lid close: strip display = \(rectStrHL(stripFullClosed)) "
          + "screenFrame = \(rectStrHL(controller.debugScreenFrame))")
    // The strip must still be on external B (id 20), now re-origined to (2560,0).
    let expectBClosed = axFlip(extBFull_closed, primaryHeight: 1440)
    t.check("strip followed external B across the lid close (by stable id, not migrated)",
            approxEqualRect(stripFullClosed, expectBClosed))
    assertHealthy("lid closed", worldDisplays: closedAX)

    // --- SLEEP/WAKE BURST in clamshell: macOS fires several settled changes as
    // the externals power-save and return, sometimes transiently dropping B or
    // reordering the set. The strip must FOLLOW B and never oscillate onto A.
    let reordered: [(full: CGRect, visible: CGRect, id: CGDirectDisplayID?)] =
        [closedSet[1], closedSet[0]]                // B then A (reordered set)
    var stripDisplayHistory: [CGRect] = [stripFullClosed]
    let wakeSequence: [[(full: CGRect, visible: CGRect, id: CGDirectDisplayID?)]] = [
        closedSet,                                   // both present
        reordered,                                   // wake reorders the set
        closedSet,                                   // settle
        reordered, closedSet, reordered, closedSet,  // a few flip-flops
    ]
    for (i, set) in wakeSequence.enumerated() {
        world.displays = set.map { axFlip($0.full, primaryHeight: 1440) }
        controller.debugApplyDisplayChange(set)
        Headless.pump(0.02)
        stripDisplayHistory.append(controller.debugStripDisplayFrame ?? .null)
        assertHealthy("wake burst step \(i)", worldDisplays: world.displays)
    }
    // The strip must have stayed on external B the WHOLE time (no oscillation
    // between the two equal monitors). Every recorded strip display equals B.
    let stayedOnB = stripDisplayHistory.allSatisfy { approxEqualRect($0, expectBClosed) }
    t.check("strip never oscillated between the two equal displays (stayed on B)", stayedOnB)
    if !stayedOnB {
        print("    strip display history: " + stripDisplayHistory.map(rectStrHL).joined(separator: " -> "))
    }

    // --- A NEW WINDOW spawned in clamshell must still land on the strip display,
    // on-screen (the "using it glitches" path). Spawn on external B.
    let bVisClosed = controller.debugScreenFrame
    let newEl = world.addWindow(pid: pids[0], title: "clamshell-new",
                                frame: CGRect(x: bVisClosed.minX + 80, y: bVisClosed.minY + 80,
                                              width: 360, height: 360),
                                notify: true)
    _ = newEl
    // Wait for fast-adopt.
    let deadline = Date().addingTimeInterval(1.0)
    while Date() < deadline {
        Headless.pump(0.02)
        if controller.debugSlotCount == 4 { break }
    }
    t.check("new clamshell window adopted into the strip", controller.debugSlotCount == 4)
    assertHealthy("after new-window spawn", worldDisplays: world.displays)

    // --- LID RE-OPEN: built-in returns as primary; the AX plane re-anchors back
    // to height 982. The strip must follow B back to its open-layout AX position.
    let openAX = openSet.map { axFlip($0.full, primaryHeight: 982) }
    world.displays = openAX
    controller.debugApplyDisplayChange(openSet)
    Headless.pump(0.05)
    let expectBOpen = axFlip(extBFull_open, primaryHeight: 982)
    t.check("strip followed external B back across the lid re-open",
            approxEqualRect(controller.debugStripDisplayFrame ?? .null, expectBOpen))
    assertHealthy("lid re-opened", worldDisplays: openAX)

    controller.release()
    Headless.pump(0.05)
    t.check("controller released cleanly", !controller.isManaging)

    // ====================================================================
    // PHASE B: strip on the BUILT-IN display when the lid closes. The strip's
    // own display VANISHES, and there are TWO EQUAL survivors (a migration tie).
    // The strip must migrate to a survivor and land every window on-screen there,
    // not strand them on the dead built-in's old coordinates.
    // ====================================================================
    runClamshellMigrationPhase(&t, approxEqualRect: approxEqualRect, rectStrHL: rectStrHL)

    // ====================================================================
    // PHASE C: clamshell transition with NO stable display IDs vended (a real
    // possibility mid sleep/wake). The resolver falls back to pure GEOMETRY
    // overlap - but the engine's stored strip frame is in the OLD AX plane
    // (primary height 982) while the new displays are flipped around 1440. This
    // is the most fragile path: a cross-plane comparison must still keep the
    // strip on-screen.
    // ====================================================================
    runClamshellNoIDPhase(&t, approxEqualRect: approxEqualRect, rectStrHL: rectStrHL)

    // ====================================================================
    // PHASE D: REDUNDANT display-change thrash. macOS fires
    // `didChangeScreenParameters` repeatedly on a dual-120Hz/ProMotion setup
    // (sleep/wake, refresh renegotiation, brightness/HDR, a window crossing
    // displays). A settled change whose RESOLVED geometry is IDENTICAL to the
    // current binding must be a NO-OP - it must not re-move/re-resize every
    // managed window, which the user sees as windows visibly jumping/resizing
    // ("glitching out"). This measures the real AX writes such a redundant
    // change issues; the contract is ZERO.
    // ====================================================================
    runClamshellRedundantChangePhase(&t, rectStrHL: rectStrHL)

    print("\n[clamshelltest] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}

// MARK: - Phase B: strip on the built-in display when the lid closes (migration
// with two EQUAL survivors).

private func runClamshellMigrationPhase(_ t: inout TestCounter,
                                        approxEqualRect: (CGRect, CGRect, CGFloat) -> Bool,
                                        rectStrHL: (CGRect) -> String) {
    let menuBar: CGFloat = 37
    func vis(_ full: CGRect, menu: Bool) -> CGRect {
        menu ? CGRect(x: full.minX, y: full.minY, width: full.width, height: full.height - menuBar) : full
    }
    func axFlip(_ appKitFull: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: appKitFull.minX, y: primaryHeight - appKitFull.maxY,
               width: appKitFull.width, height: appKitFull.height)
    }

    let builtinID: CGDirectDisplayID = 1
    let extAID: CGDirectDisplayID = 10
    let extBID: CGDirectDisplayID = 20

    // Lid OPEN: built-in primary at (0,0); two equal externals to its right.
    let builtinFull = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let extAFull = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
    let extBFull = CGRect(x: 1512 + 2560, y: 0, width: 2560, height: 1440)
    let openSet: [(full: CGRect, visible: CGRect, id: CGDirectDisplayID?)] = [
        (builtinFull, vis(builtinFull, menu: true), builtinID),
        (extAFull, vis(extAFull, menu: false), extAID),
        (extBFull, vis(extBFull, menu: false), extBID),
    ]
    // Lid CLOSED: built-in gone; externals re-origin so the new primary is at 0.
    let extAClosed = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let extBClosed = CGRect(x: 2560, y: 0, width: 2560, height: 1440)
    let closedSet: [(full: CGRect, visible: CGRect, id: CGDirectDisplayID?)] = [
        (extAClosed, vis(extAClosed, menu: true), extAID),
        (extBClosed, vis(extBClosed, menu: false), extBID),
    ]

    let world = Headless.install(displays: openSet.map { axFlip($0.full, primaryHeight: 982) })
    defer { Headless.uninstall(); RestoreStore.clear() }
    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    // Strip lives on the BUILT-IN (index 0) - the display that will vanish.
    controller.debugBindStrip(to: openSet, stripIndex: 0)
    let builtinVisAX = controller.debugScreenFrame
    let (pids, _) = Headless.seedWindows(world, count: 3, startPID: 8800,
                                         within: builtinVisAX, width: 320, height: 320)
    controller.sandboxPIDs = Set(pids)
    controller.arrange(pidFilter: Set(pids))
    Headless.pump(0.1)
    t.check("phaseB: arranged 3 windows on the built-in display", controller.debugSlotCount == 3)
    guard controller.debugSlotCount == 3 else { return }

    func liveFrames() -> [CGRect] {
        controller.debugSlotTitles.compactMap { title in
            pids.flatMap { AXSource.windows(forPID: $0) }.first { $0.title == title }?.frame
        }
    }

    // LID CLOSE: built-in vanishes; the strip MUST migrate to a survivor.
    let closedAX = closedSet.map { axFlip($0.full, primaryHeight: 1440) }
    world.displays = closedAX
    controller.debugApplyDisplayChange(closedSet)
    Headless.pump(0.1)
    let strip = controller.debugStripDisplayFrame ?? .null
    print("[clamshelltest][phaseB] strip migrated to \(rectStrHL(strip)) "
          + "screenFrame=\(rectStrHL(controller.debugScreenFrame))")
    // It must have migrated to one of the two survivors (A or B), not stayed on
    // the dead built-in's coordinates.
    let onSurvivor = approxEqualRect(strip, closedAX[0], 1) || approxEqualRect(strip, closedAX[1], 1)
    t.check("phaseB: strip migrated onto a surviving display (not the dead built-in)", onSurvivor)
    // Every window must be on-screen (overlap some live display) and on the strip.
    var allOn = true, allOnStrip = true
    for f in liveFrames() {
        if !closedAX.contains(where: { $0.intersects(f) }) { allOn = false }
        if DisplayGeometry.overlapArea(f, strip) <= 0 { allOnStrip = false }
    }
    t.check("phaseB: every window is on a live display after migration", allOn)
    t.check("phaseB: every window is on the strip's new display after migration", allOnStrip)
    if !allOn || !allOnStrip {
        for f in liveFrames() { print("    window frame \(rectStrHL(f))") }
    }

    controller.release(); Headless.pump(0.05)
}

// MARK: - Phase C: clamshell with NO stable IDs vended (geometry-only resolve
// across the primary-height plane shift).

private func runClamshellNoIDPhase(_ t: inout TestCounter,
                                   approxEqualRect: (CGRect, CGRect, CGFloat) -> Bool,
                                   rectStrHL: (CGRect) -> String) {
    let menuBar: CGFloat = 37
    func vis(_ full: CGRect, menu: Bool) -> CGRect {
        menu ? CGRect(x: full.minX, y: full.minY, width: full.width, height: full.height - menuBar) : full
    }
    func axFlip(_ appKitFull: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: appKitFull.minX, y: primaryHeight - appKitFull.maxY,
               width: appKitFull.width, height: appKitFull.height)
    }

    // Lid OPEN: built-in primary; two equal externals. NO ids vended (all nil).
    let builtinFull = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let extAFull = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
    let extBFull = CGRect(x: 1512 + 2560, y: 0, width: 2560, height: 1440)
    let openSet: [(full: CGRect, visible: CGRect, id: CGDirectDisplayID?)] = [
        (builtinFull, vis(builtinFull, menu: true), nil),
        (extAFull, vis(extAFull, menu: false), nil),
        (extBFull, vis(extBFull, menu: false), nil),
    ]
    let extAClosed = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let extBClosed = CGRect(x: 2560, y: 0, width: 2560, height: 1440)
    let closedSet: [(full: CGRect, visible: CGRect, id: CGDirectDisplayID?)] = [
        (extAClosed, vis(extAClosed, menu: true), nil),
        (extBClosed, vis(extBClosed, menu: false), nil),
    ]

    let world = Headless.install(displays: openSet.map { axFlip($0.full, primaryHeight: 982) })
    defer { Headless.uninstall(); RestoreStore.clear() }
    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    // Strip on external B (index 2) under the OPEN layout, no ids.
    controller.debugBindStrip(to: openSet, stripIndex: 2)
    let bVisAX = controller.debugScreenFrame
    let (pids, _) = Headless.seedWindows(world, count: 3, startPID: 9900,
                                         within: bVisAX, width: 320, height: 320)
    controller.sandboxPIDs = Set(pids)
    controller.arrange(pidFilter: Set(pids))
    Headless.pump(0.1)
    t.check("phaseC: arranged 3 windows on external B (no display ids)", controller.debugSlotCount == 3)
    guard controller.debugSlotCount == 3 else { return }

    func liveFrames() -> [CGRect] {
        controller.debugSlotTitles.compactMap { title in
            pids.flatMap { AXSource.windows(forPID: $0) }.first { $0.title == title }?.frame
        }
    }

    // LID CLOSE with no ids: pure-geometry resolve across the plane shift.
    let closedAX = closedSet.map { axFlip($0.full, primaryHeight: 1440) }
    world.displays = closedAX
    controller.debugApplyDisplayChange(closedSet)
    Headless.pump(0.1)
    let strip = controller.debugStripDisplayFrame ?? .null
    print("[clamshelltest][phaseC] strip resolved to \(rectStrHL(strip)) "
          + "screenFrame=\(rectStrHL(controller.debugScreenFrame))")
    var allOn = true, allOnStrip = true
    for f in liveFrames() {
        if !closedAX.contains(where: { $0.intersects(f) }) { allOn = false }
        if DisplayGeometry.overlapArea(f, strip) <= 0 { allOnStrip = false }
    }
    t.check("phaseC: strip resolved onto a live display (geometry fallback)",
            approxEqualRect(strip, closedAX[0], 1) || approxEqualRect(strip, closedAX[1], 1))
    t.check("phaseC: every window on-screen after a no-id clamshell change", allOn)
    t.check("phaseC: every window on the strip display after a no-id clamshell change", allOnStrip)
    if !allOn || !allOnStrip {
        for f in liveFrames() { print("    window frame \(rectStrHL(f))") }
    }

    controller.release(); Headless.pump(0.05)
}

// MARK: - Phase D: redundant settled display change must be a no-op (no thrash).

private func runClamshellRedundantChangePhase(_ t: inout TestCounter,
                                              rectStrHL: (CGRect) -> String) {
    let menuBar: CGFloat = 37
    func vis(_ full: CGRect, menu: Bool) -> CGRect {
        menu ? CGRect(x: full.minX, y: full.minY, width: full.width, height: full.height - menuBar) : full
    }
    func axFlip(_ appKitFull: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: appKitFull.minX, y: primaryHeight - appKitFull.maxY,
               width: appKitFull.width, height: appKitFull.height)
    }

    // Stable clamshell layout: two equal 1440p externals, A primary at (0,0).
    let extAID: CGDirectDisplayID = 10
    let extBID: CGDirectDisplayID = 20
    let extA = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let extB = CGRect(x: 2560, y: 0, width: 2560, height: 1440)
    let set: [(full: CGRect, visible: CGRect, id: CGDirectDisplayID?)] = [
        (extA, vis(extA, menu: true), extAID),
        (extB, vis(extB, menu: false), extBID),
    ]

    let world = Headless.install(displays: set.map { axFlip($0.full, primaryHeight: 1440) })
    defer { Headless.uninstall(); RestoreStore.clear() }
    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    // Strip on external B; arrange 4 windows with fillHeight (the production
    // default), so a relayout WOULD force-resize every one if it ran.
    controller.debugBindStrip(to: set, stripIndex: 1)
    let bVis = controller.debugScreenFrame
    let (pids, _) = Headless.seedWindows(world, count: 4, startPID: 11000,
                                         within: bVis, width: 360, height: 360)
    controller.sandboxPIDs = Set(pids)
    controller.arrange(pidFilter: Set(pids))
    Headless.pump(0.1)
    t.check("phaseD: arranged 4 windows on external B", controller.debugSlotCount == 4)
    guard controller.debugSlotCount == 4 else { return }

    // Snapshot the live frames, then fire SEVERAL identical settled changes.
    func liveFrames() -> [String: CGRect] {
        var m: [String: CGRect] = [:]
        for title in controller.debugSlotTitles {
            if let f = pids.flatMap({ AXSource.windows(forPID: $0) }).first(where: { $0.title == title })?.frame {
                m[title] = f
            }
        }
        return m
    }
    let before = liveFrames()

    world.resetWriteCounters()
    let redundantEvents = 8
    for _ in 0..<redundantEvents {
        controller.debugApplyDisplayChange(set)   // IDENTICAL geometry each time
        Headless.pump(0.02)
    }
    let posWrites = world.setPositionCount
    let sizeWrites = world.setSizeCount
    print("[clamshelltest][phaseD] \(redundantEvents) identical display changes issued "
          + "\(posWrites) position writes + \(sizeWrites) size writes "
          + "across \(controller.debugSlotCount) windows")

    // Contract: a redundant settled change resolves to the SAME display, so it
    // must not re-move or re-resize any managed window.
    t.check("phaseD: redundant display changes issue NO position writes (no jump)",
            posWrites == 0)
    t.check("phaseD: redundant display changes issue NO size writes (no resize flicker)",
            sizeWrites == 0)

    // And the live frames are byte-identical before/after the storm.
    let after = liveFrames()
    var unchanged = before.count == after.count
    for (title, f) in before {
        guard let g = after[title] else { unchanged = false; continue }
        if abs(f.minX - g.minX) > 0.5 || abs(f.minY - g.minY) > 0.5
            || abs(f.width - g.width) > 0.5 || abs(f.height - g.height) > 0.5 {
            unchanged = false
            print("    '\(title)' moved \(rectStrHL(f)) -> \(rectStrHL(g))")
        }
    }
    t.check("phaseD: every window's live frame is unchanged after the redundant-change storm",
            unchanged)

    // GUARD RAIL: the fix must not over-suppress. A GENUINE resolution change (a
    // different usable height) MUST still re-fill every window, or fillHeight
    // would silently stop working across a real resolution switch. Switch both
    // externals to a SHORTER mode (1080p) and confirm size writes resume.
    let extA1080 = CGRect(x: 0, y: 0, width: 2560, height: 1080)
    let extB1080 = CGRect(x: 2560, y: 0, width: 2560, height: 1080)
    let set1080: [(full: CGRect, visible: CGRect, id: CGDirectDisplayID?)] = [
        (extA1080, vis(extA1080, menu: true), extAID),
        (extB1080, vis(extB1080, menu: false), extBID),
    ]
    world.displays = set1080.map { axFlip($0.full, primaryHeight: 1080) }
    world.resetWriteCounters()
    controller.debugApplyDisplayChange(set1080)
    Headless.pump(0.05)
    print("[clamshelltest][phaseD] genuine resolution change issued "
          + "\(world.setSizeCount) size writes (expected > 0)")
    t.check("phaseD: a GENUINE resolution change still re-fills window heights (fix not over-suppressing)",
            world.setSizeCount > 0)

    controller.release(); Headless.pump(0.05)
}
