import Foundation
import ApplicationServices
import AppKit

/// Pure-logic tests for the native-Space strip layer (`TeleportEngine`'s
/// per-(native Space) axis, Model B). Like `StripOpsTests`, these assert on the
/// engine's in-memory model only: AX position writes on the synthetic elements
/// fail harmlessly, so nothing real is moved. No Accessibility permission, no
/// `SimWindowWorld`, no controller - just the engine's Space-switch bookkeeping.
///
/// Run as part of `WindowLab unittest`.
enum SpaceLayerTests {

    /// Build an engine with `count` synthetic columns (reuses the StripOps
    /// builder so the geometry is identical to the rest of the unit suite).
    private static func engine(_ count: Int) -> TeleportEngine {
        StripOpsTests.makeEngine(count: count)
    }

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        print("\n[spacelayer] native-Space strip layer")

        // --- Default: per-Space tracking is OFF, every path is the old model ---
        let e0 = engine(3)
        check("tracking off by default (activeSpaceID nil)", e0.activeSpaceID == nil)
        check("no tracked Spaces by default", e0.trackedSpaceIDs.isEmpty)
        check("switchToSpace is a no-op while tracking is off",
              e0.switchToSpace(99) == false && e0.slots.count == 3)
        check("allSpacesManagedSlots == allManagedSlots with no stash",
              e0.allSpacesManagedSlots.count == e0.allManagedSlots.count)

        // --- beginSpaceTracking binds the live strip to a Space id ---
        let e1 = engine(2)
        let titlesA = e1.slots.map { $0.window.title }
        e1.beginSpaceTracking(spaceID: 10)
        check("beginSpaceTracking sets the active Space id", e1.activeSpaceID == 10)
        check("only Space 10 is tracked", e1.trackedSpaceIDs == [10])
        check("switching to the SAME Space is a no-op", e1.switchToSpace(10) == false)

        // --- Switch to a brand-new Space: live strip stashes, fresh empty loads ---
        check("switch to a new Space returns true", e1.switchToSpace(20) == true)
        check("now on Space 20", e1.activeSpaceID == 20)
        check("Space 20 starts EMPTY (its own fresh strip)", e1.slots.isEmpty)
        check("both Spaces now tracked", e1.trackedSpaceIDs == [10, 20])
        check("Space 10's 2 windows are stashed, not lost",
              e1.allSpacesManagedSlots.count == 2)
        check("isManaged is scoped to the ACTIVE Space (stashed window invisible)",
              !e1.isManaged(AXUIElementCreateApplication(90000)) )

        // --- Return to Space 10: its exact strip comes back intact ---
        check("switch back to Space 10 returns true", e1.switchToSpace(10) == true)
        check("Space 10's 2 columns restored", e1.slots.count == 2)
        check("Space 10's column order/identity preserved",
              e1.slots.map { $0.window.title } == titlesA)
        check("empty Space 20 is KEPT in the stash (native Desktops are user-owned, not auto-pruned)",
              e1.trackedSpaceIDs == [10, 20])

        // --- Open windows on each of two Spaces; they never bleed across ---
        let e2 = engine(2)                      // Space A: 2 windows
        e2.beginSpaceTracking(spaceID: 1)
        e2.switchToSpace(2)                      // Space B: empty
        // Simulate adopting a window on Space B by inserting into the live strip.
        let bWin = AXWindowInfo(
            pid: 91000, appName: "BApp", element: AXUIElementCreateApplication(91000),
            title: "OnlyOnB", role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            isMinimized: false, isFullscreen: false)
        e2.append(window: bWin)
        check("Space B holds exactly the window opened there", e2.slots.count == 1
              && e2.slots[0].window.title == "OnlyOnB")
        e2.switchToSpace(1)
        check("Space A still has only its own 2 windows (no bleed from B)",
              e2.slots.count == 2 && !e2.slots.contains { $0.window.title == "OnlyOnB" })
        check("both Spaces' windows persist across the switch (2 + 1)",
              e2.allSpacesManagedSlots.count == 3)

        // --- forgetSpace drops a removed Desktop's stash; never the active one ---
        check("forgetSpace on the ACTIVE Space is ignored",
              { e2.forgetSpace(1); return e2.trackedSpaceIDs.contains(1) }())
        check("forgetSpace drops a stashed Space",
              { e2.forgetSpace(2); return !e2.trackedSpaceIDs.contains(2)
                  && e2.allSpacesManagedSlots.count == 2 }())

        // --- Release clears all Space state (back to the single-strip model) ---
        let e3 = engine(1)
        e3.beginSpaceTracking(spaceID: 5)
        e3.switchToSpace(6)
        e3.append(window: bWin)
        _ = e3.releaseAll(displays: [CGRect(x: 0, y: 0, width: 1600, height: 1000)])
        check("releaseAll stops Space tracking", e3.activeSpaceID == nil)
        check("releaseAll forgets every stashed Space", e3.trackedSpaceIDs.isEmpty)

        // --- Re-entry after several Spaces preserves each independently ---
        let e4 = engine(1)
        e4.beginSpaceTracking(spaceID: 100)
        e4.switchToSpace(200); e4.append(window: bWin)   // B: 1 win
        e4.switchToSpace(300)                             // C: empty
        check("three distinct Spaces tracked (C active+empty, A/B stashed)",
              e4.trackedSpaceIDs == [100, 200, 300])
        e4.switchToSpace(100)
        check("Space 100 still has its original window", e4.slots.count == 1
              && e4.slots[0].window.title == "Win0")
        e4.switchToSpace(200)
        check("Space 200 still has the window opened there", e4.slots.count == 1
              && e4.slots[0].window.title == "OnlyOnB")

        let ok = failed == 0
        print("[spacelayer] \(passed) passed, \(failed) failed -> \(ok ? "PASS" : "FAIL")")
        return ok
    }
}
