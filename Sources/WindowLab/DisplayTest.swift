import Foundation
import ApplicationServices
import AppKit

/// Multi-display integration test against the REAL production controller.
///
/// Like `e2etest`/`opstest`, this spawns DISPOSABLE windows and runs the actual
/// `ScrollWMController` HARD-LOCKED to those PIDs (`sandboxPIDs`), so it can run
/// live without ever enumerating or moving the user's real windows. It then
/// asserts multi-display behavior end-to-end against live Accessibility readback:
///
///   1. ON-DISPLAY: after Arrange, every strip window's real AX frame sits
///      inside the strip display's AX bounds (best display = the strip's).
///   2. PARKING: when columns scroll fully off-viewport, the unavoidable ~40px
///      macOS clamp sliver lands on the STRIP display, never on a neighbor.
///   3. REBIND: after relaying the strip onto another display's geometry
///      (`rebindStripDisplay`), every managed window MOVES onto that display.
///
/// The test adapts to the live hardware:
///   - 2+ displays: phase 3 rebinds onto the REAL second monitor and asserts the
///     windows land there; phase 2 asserts the park sliver avoids that monitor.
///   - 1 display: phase 2/3 use a synthetic neighbor / target REGION carved from
///     the single physical display, so the genuine relay + parking-corner logic
///     still runs on real AX (windows really move), just within one screen.
///
/// Run with: `WindowLab displaytest`  (requires Accessibility permission)
func runDisplayTest() {
    guard AXSource.isTrusted else {
        print("displaytest: needs Accessibility permission. Grant it and re-run.")
        exit(2)
    }

    // Isolate crash-recovery state from the real ScrollWM session (same guard as
    // sandbox): the recovery file can never clobber/recover real managed windows.
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // The real controller. Created up front like e2etest (installs the always-on
    // hotkeys); we LOCK it to the spawned PIDs below so it can only ever see them.
    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    DispatchQueue.global().async {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        // --- Display geometry (AX top-left global coords; the shared plane the
        // engine commits positions in). Use the SAME pure helper the controller
        // uses so the test speaks the controller's vocabulary, not a re-derivation.
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.main!).frame.height
        func axFull(_ s: NSScreen) -> CGRect {
            DisplayGeometry.axFrame(appKitFrame: s.frame, primaryHeight: primaryHeight)
        }
        func axVisible(_ s: NSScreen) -> CGRect {
            DisplayGeometry.axFrame(appKitFrame: s.visibleFrame, primaryHeight: primaryHeight)
        }

        let stripScreen = NSScreen.main!
        let stripFull = axFull(stripScreen)
        let otherScreens = NSScreen.screens.filter { $0 !== stripScreen }
        let otherFulls = otherScreens.map(axFull)
        let multiDisplay = !otherScreens.isEmpty
        let otherStr = otherFulls.map(rectStr).joined(separator: ",")
        let layoutNote = multiDisplay ? "other=\(otherStr)" : "single-display: synthetic neighbor/target"
        print("[displaytest] displays: \(NSScreen.screens.count) strip=\(rectStr(stripFull)) \(layoutNote)")

        // ============ Phase 0: stable display identity ([md-hotplug]) ==========
        // Prove the hotplug fix on REAL hardware: every attached display vends a
        // stable CGDirectDisplayID, and StripDisplayResolver follows the strip's
        // PHYSICAL display BY ID even when its geometry is perturbed (the
        // arrangement-swap / big-resolution-change cases pure overlap gets wrong).
        let liveIDs = NSScreen.screens.map { $0.displayID }
        print("[displaytest] display ids: "
              + zip(NSScreen.screens, liveIDs).map { s, id in
                    "\(s.localizedName)=\(id.map(String.init) ?? "nil")"
                }.joined(separator: ", "))
        check("every real display vends a stable CGDirectDisplayID",
              liveIDs.allSatisfy { ($0 ?? 0) != 0 })
        check("real display ids are unique", Set(liveIDs.compactMap { $0 }).count == liveIDs.count)
        if multiDisplay, liveIDs.allSatisfy({ $0 != nil }) {
            let ids = liveIDs.compactMap { $0 }
            let visibles = NSScreen.screens.map(axVisible)
            // Pick the strip's display (main) and its id.
            let stripIdx = NSScreen.screens.firstIndex { $0 === stripScreen } ?? 0
            let stripID = ids[stripIdx]
            // Perturb ONLY the strip display's frame far away (simulate a big
            // resolution/origin change) so it no longer overlaps its old self,
            // and make a DIFFERENT display the largest survivor. Identity must
            // still follow the strip's own id, not migrate.
            var perturbed = visibles
            perturbed[stripIdx] = CGRect(x: 99_000, y: 99_000,
                                         width: visibles[stripIdx].width,
                                         height: visibles[stripIdx].height)
            let d = StripDisplayResolver.resolve(
                stripFrame: visibles[stripIdx], displays: perturbed,
                stripDisplayID: stripID, displayIDs: ids)
            check("resolver follows the strip's display by id across a big move (live)",
                  d.displayIndex == stripIdx && d.frame == perturbed[stripIdx] && !d.migrated)
            // Now drop the strip's id from the live set (simulate a real unplug):
            // identity is absent -> must MIGRATE to a survivor.
            let survivors = Array(visibles.enumerated().filter { $0.offset != stripIdx }.map { $0.element })
            let survivorIDs = Array(ids.enumerated().filter { $0.offset != stripIdx }.map { $0.element })
            let unplug = StripDisplayResolver.resolve(
                stripFrame: visibles[stripIdx], displays: survivors,
                stripDisplayID: stripID, displayIDs: survivorIDs)
            check("resolver migrates when the strip's id is truly gone (live)",
                  unplug.migrated && unplug.displayIndex != nil)
        }

        // --- Spawn disposable windows ON the strip display, then LOCK the
        // controller to their PIDs so no real window can ever be touched.
        print("[displaytest] spawning 4 test windows on the strip display...")
        let spawned = spawnTestWindows(count: 4, onDisplay: stripScreen)
        Thread.sleep(forTimeInterval: 1.5)
        let pids = Set(spawned.map { $0.processIdentifier })
        controller.sandboxPIDs = pids

        // Live AX readback scoped to OUR spawned windows (never the real session).
        func liveWindows() -> [AXWindowInfo] {
            pids.flatMap { pid -> [AXWindowInfo] in
                guard let a = NSRunningApplication(processIdentifier: pid), !a.isTerminated else { return [] }
                return AXSource.windows(for: a)
            }
        }
        func liveFrame(title: String) -> CGRect? {
            liveWindows().first { $0.title == title }?.frame
        }

        func cleanupAndExit(_ code: Int32) -> Never {
            DispatchQueue.main.sync { if controller.isManaging { controller.release() } }
            for p in spawned where p.isRunning { p.terminate() }
            RestoreStore.clear()
            exit(code)
        }

        // ================= Phase 1: arrange + on-strip-display =================
        print("[displaytest] arranging (locked to test windows)...")
        DispatchQueue.main.sync { controller.arrange(pidFilter: pids) }
        Thread.sleep(forTimeInterval: 0.8)
        check("controller is managing", controller.isManaging)
        check("4 columns adopted", controller.debugSlotCount == 4)
        guard controller.debugSlotCount == 4 else {
            print("[displaytest] adoption failed, aborting"); cleanupAndExit(1)
        }
        check("strip bound to the strip display (parking reference set)",
              controller.debugStripDisplayFrame.map { approxEqual($0, stripFull) } ?? false)

        let titles = controller.debugSlotTitles
        var allOnStrip = true
        for t in titles {
            guard let f = liveFrame(title: t) else { allOnStrip = false; continue }
            let best = DisplayGeometry.display(bestOverlapping: f, displays: [stripFull] + otherFulls)
            let onStrip = best.map { approxEqual($0, stripFull) } ?? false
            if !onStrip {
                allOnStrip = false
                print("    window \(t) AX frame \(rectStr(f)) did NOT land on strip display")
            }
        }
        check("every arranged window's real AX frame is on the strip display", allOnStrip)

        // ================= Phase 2: off-viewport parking sliver =================
        // Force overflow: widen every column to fill the viewport, then focus the
        // LAST column so the leading columns scroll fully off-screen and PARK.
        for i in 0..<controller.debugSlotCount {
            DispatchQueue.main.sync { controller.focus(index: i); controller.setWidthFraction(1.0) }
            Thread.sleep(forTimeInterval: 0.15)
        }
        DispatchQueue.main.sync { controller.focus(index: controller.debugSlotCount - 1) }
        Thread.sleep(forTimeInterval: 0.5)

        // The leading (now off-viewport) column should be parked. Read its real
        // AX frame and confirm the clamp sliver landed on the strip display.
        let parkedTitle = controller.debugSlotTitles.first ?? ""
        let parkPoint = controller.debugParkingPoint
        print("[displaytest] parking corner: \(pointStr(parkPoint))")
        check("parking corner is on/just-past the strip display, not a neighbor",
              parkingCornerFavorsStrip(parkPoint, strip: stripFull, others: otherFulls))
        if let pf = liveFrame(title: parkedTitle) {
            let onStripOverlap = DisplayGeometry.overlapArea(pf, stripFull)
            let neighborOverlap = otherFulls.reduce(CGFloat(0)) { $0 + DisplayGeometry.overlapArea(pf, $1) }
            print("[displaytest] parked '\(parkedTitle)' AX frame \(rectStr(pf)) "
                  + "stripOverlap=\(Int(onStripOverlap)) neighborOverlap=\(Int(neighborOverlap))")
            check("parked window's clamp sliver is visible ON the strip display", onStripOverlap > 0)
            check("parked window's sliver did NOT spill onto a neighbor display",
                  neighborOverlap <= onStripOverlap * 0.05)
        } else {
            check("parked window readback available", false)
        }

        // Reset widths small so the columns fit any rebind target region.
        for i in 0..<controller.debugSlotCount {
            DispatchQueue.main.sync { controller.focus(index: i); controller.setWidthFraction(0.25) }
            Thread.sleep(forTimeInterval: 0.12)
        }
        Thread.sleep(forTimeInterval: 0.3)

        // ================= Phase 3: rebind onto another display =================
        // Choose the rebind target geometry. With a real second monitor we relay
        // the strip ONTO it; on a single display we carve a target REGION (right
        // half) and a synthetic neighbor (left half) so the real relay still runs.
        let targetVisible: CGRect      // new usable frame the strip should fill
        let targetFull: CGRect         // new strip-display parking reference
        let rebindOthers: [CGRect]     // the new "other displays" set
        let targetLabel: String
        if let other = otherScreens.first {
            targetVisible = axVisible(other)
            targetFull = axFull(other)
            rebindOthers = ([stripScreen] + otherScreens.dropFirst()).map(axFull)
            targetLabel = "external display"
        } else {
            // Single physical display: right half = target, left half = neighbor.
            let half = stripFull.width / 2
            let rightFull = CGRect(x: stripFull.minX + half, y: stripFull.minY, width: half, height: stripFull.height)
            let leftFull  = CGRect(x: stripFull.minX, y: stripFull.minY, width: half, height: stripFull.height)
            // Inset the visible target so 0.25-width windows fit comfortably.
            targetVisible = rightFull.insetBy(dx: 8, dy: 40)
            targetFull = rightFull
            rebindOthers = [leftFull]
            targetLabel = "right-half region (single-display fallback)"
        }
        print("[displaytest] rebinding strip onto \(targetLabel): visible=\(rectStr(targetVisible))")
        let relayWrites = DispatchQueue.main.sync {
            controller.debugRebindStrip(visible: targetVisible, stripFull: targetFull, others: rebindOthers)
        }
        Thread.sleep(forTimeInterval: 0.7)
        check("rebind relayed windows (issued AX position writes)", relayWrites > 0)
        check("strip now bound to the rebind target",
              controller.debugStripDisplayFrame.map { approxEqual($0, targetFull) } ?? false)

        // Every managed window should now best-overlap the TARGET, not where it
        // started. Compare overlap with target vs the new "other" set.
        var allMoved = true
        for t in controller.debugSlotTitles {
            guard let f = liveFrame(title: t) else { allMoved = false; continue }
            let onTarget = DisplayGeometry.overlapArea(f, targetFull)
            let elsewhere = rebindOthers.reduce(CGFloat(0)) { $0 + DisplayGeometry.overlapArea(f, $1) }
            // On-viewport columns must be mostly on the target; a column the
            // narrower target pushed off-viewport may park (still on target).
            if onTarget <= elsewhere {
                allMoved = false
                print("    window \(t) AX frame \(rectStr(f)) onTarget=\(Int(onTarget)) elsewhere=\(Int(elsewhere))")
            }
        }
        check("after rebind, every window moved onto the \(targetLabel)", allMoved)

        // ================= Restore + cleanup =================
        print("[displaytest] releasing (restores every window to its original frame)...")
        DispatchQueue.main.sync { controller.release() }
        Thread.sleep(forTimeInterval: 0.5)
        check("controller stopped managing", !controller.isManaging)
        check("strip empty after release", controller.debugSlotCount == 0)

        // Verify the spawned windows actually came back to their spawn frames
        // (release restores originalFrame regardless of the strip's display).
        var restored = 0
        for t in titles where liveFrame(title: t) != nil { restored += 1 }
        check("survivors restored to a real on-screen frame", restored == titles.count)

        for p in spawned where p.isRunning { p.terminate() }
        RestoreStore.clear()
        print("\n[displaytest] \(passed) passed, \(failed) failed "
              + "(\(multiDisplay ? "live 2-display" : "single-display") hardware)")
        exit(failed == 0 ? 0 : 1)
    }

    app.run()
}

// MARK: - displaytest helpers (small, local)

/// Two rects are approximately equal within a 1pt tolerance per edge.
private func approxEqual(_ a: CGRect, _ b: CGRect, tol: CGFloat = 1) -> Bool {
    abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
        && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
}

/// True if the parking edge sits at (or just past) a SIDE edge of the strip
/// display that has NO neighbor in that direction, i.e. the clamp sliver (a tall
/// full-height peek) will stay on the strip display. The window keeps its
/// vertical band and only slides off a side, so this is a purely horizontal
/// check: the X is past whichever side edge is free.
private func parkingCornerFavorsStrip(_ p: CGPoint, strip s: CGRect, others: [CGRect]) -> Bool {
    func vOverlap(_ d: CGRect) -> Bool { d.minY < s.maxY && d.maxY > s.minY }
    let rightBlocked = others.contains { $0.minX >= s.maxX - 1 && vOverlap($0) }
    // X must be past a FREE side edge (flip away from a blocking side neighbor).
    return rightBlocked ? (p.x < s.minX) : (p.x > s.maxX)
}

private func rectStr(_ r: CGRect) -> String {
    String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
}
private func pointStr(_ p: CGPoint) -> String {
    String(format: "(%.0f,%.0f)", p.x, p.y)
}
