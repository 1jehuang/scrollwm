import Foundation
import ApplicationServices
import AppKit

/// Pure-logic tests for the strip operations (width/move/close). These do not
/// require Accessibility permission: AX calls on the synthetic elements simply
/// fail and are ignored; we assert on the engine's canvas model, which is the
/// source of truth the menu bar and teleport pass read from.
///
/// Run with: `WindowLab unittest`
enum StripOpsTests {

    /// Build an engine pre-populated with `count` synthetic columns, each
    /// `width` wide, laid out left-to-right with the engine's gap.
    static func makeEngine(count: Int, width: CGFloat = 400, screenWidth: CGFloat = 1600) -> TeleportEngine {
        let screen = CGRect(x: 0, y: 0, width: screenWidth, height: 1000)
        let engine = TeleportEngine(screenFrame: screen)
        var x: CGFloat = 0
        for i in 0..<count {
            // A synthetic, non-functional AX element. Geometry calls on it fail
            // harmlessly; we only care about the model bookkeeping.
            let element = AXUIElementCreateApplication(pid_t(90000 + i))
            let ref = TeleportEngine.ManagedWindowRef(
                element: element,
                pid: pid_t(90000 + i),
                appName: "App\(i)",
                title: "Win\(i)",
                originalFrame: CGRect(x: x, y: 0, width: width, height: 300)
            )
            engine.slots.append(TeleportEngine.Slot(
                window: ref, canvasX: x, width: width, y: 0, height: 300
            ))
            x += width + engine.gap
        }
        engine.focusIndex = 0
        return engine
    }

    /// canvasX values must be a gap-separated left-to-right packing.
    static func isCompact(_ engine: TeleportEngine) -> Bool {
        var x: CGFloat = 0
        for slot in engine.slots {
            if abs(slot.canvasX - x) > 0.5 { return false }
            x += slot.width + engine.gap
        }
        return true
    }

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        // --- width(forFraction:) math ---
        let e = makeEngine(count: 3)
        let usable = e.screenFrame.width - e.gap * 2 // 1576
        check("width 25% == usable*0.25", abs(e.width(forFraction: 0.25) - (usable * 0.25).rounded()) < 0.5)
        check("width 50% == usable*0.50", abs(e.width(forFraction: 0.50) - (usable * 0.50).rounded()) < 0.5)
        check("width 75% == usable*0.75", abs(e.width(forFraction: 0.75) - (usable * 0.75).rounded()) < 0.5)
        check("width 100% == usable",     abs(e.width(forFraction: 1.0) - usable.rounded()) < 0.5)
        check("width clamps to minColumnWidth", e.width(forFraction: 0.001) == e.minColumnWidth)
        check("width clamps fraction >1 to 100%", e.width(forFraction: 5.0) == usable.rounded())
        check("presets are [0.25,0.5,0.75,1.0]", TeleportEngine.widthPresets == [0.25, 0.5, 0.75, 1.0])

        // --- setFocusedWidth resizes focused column and recompacts ---
        let e1 = makeEngine(count: 3)
        e1.focusIndex = 1
        let ok1 = e1.setFocusedWidth(fraction: 0.5)
        check("setFocusedWidth returns true", ok1)
        check("focused width updated to 50%", abs(e1.slots[1].width - e1.width(forFraction: 0.5)) < 0.5)
        check("strip stays compact after resize", isCompact(e1))
        check("focus preserved on resized column", e1.focusIndex == 1)

        // --- setFocusedWidth on empty engine is a no-op ---
        let eEmpty = makeEngine(count: 0)
        check("setFocusedWidth on empty == false", eEmpty.setFocusedWidth(fraction: 0.5) == false)

        // --- moveFocused reorders columns ---
        let e2 = makeEngine(count: 3) // titles Win0,Win1,Win2
        e2.focusIndex = 0
        let movedR = e2.moveFocused(by: 1)
        check("move right returns true", movedR)
        check("order after move-right == Win1,Win0,Win2",
              e2.slots.map { $0.window.title } == ["Win1", "Win0", "Win2"])
        check("focus follows moved window (index 1)", e2.focusIndex == 1)
        check("strip compact after move", isCompact(e2))

        let movedL = e2.moveFocused(by: -1)
        check("move left returns true", movedL)
        check("order back to Win0,Win1,Win2",
              e2.slots.map { $0.window.title } == ["Win0", "Win1", "Win2"])
        check("focus back at index 0", e2.focusIndex == 0)

        // --- moveFocused at edges returns false ---
        check("move left at left edge == false", e2.moveFocused(by: -1) == false)
        e2.focusIndex = 2
        check("move right at right edge == false", e2.moveFocused(by: 1) == false)

        // --- moveFocused with single window == false ---
        let eOne = makeEngine(count: 1)
        check("move with one window == false", eOne.moveFocused(by: 1) == false)

        // --- closeFocused drops the focused column ---
        let e3 = makeEngine(count: 3)
        e3.focusIndex = 1
        _ = e3.closeFocused() // returns false (synthetic element has no close button)
        check("close removes one column", e3.slots.count == 2)
        check("closed window (Win1) gone", e3.slots.allSatisfy { $0.window.title != "Win1" })
        check("strip compact after close", isCompact(e3))
        check("focus index clamped in range", e3.focusIndex >= 0 && e3.focusIndex < e3.slots.count)

        // --- closeFocused down to empty ---
        let e4 = makeEngine(count: 1)
        _ = e4.closeFocused()
        check("close last window leaves empty strip", e4.slots.isEmpty)
        check("closeFocused on empty == false", e4.closeFocused() == false)

        print("\n[unittest] \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
