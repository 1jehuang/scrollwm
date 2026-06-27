import Foundation
import CoreGraphics
import ApplicationServices

/// Pure-policy tests for the multi-monitor swarm modules. Headless, no AX
/// permission and no real monitors: every case is synthetic geometry in the AX
/// plane (top-left origin, Y down). Run via `WindowLab mmtest`.
///
/// Grounded in the user's real hardware where useful:
///   - built-in primary  AX (0, 0, 1710x1112), menu bar (~39pt), visible y=39
///   - external LG above-left AX (-105, -1080, 1920x1080), NO menu bar
enum MultiMonitorPolicyTests {

    // MARK: - shared harness

    final class Counter {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1 }
            else { failed += 1; print("  ✗ \(name)") }
        }
    }

    // MARK: - IndicatorPlacement

    static func runIndicator() -> Bool {
        let c = Counter()
        typealias D = IndicatorPlacement.DisplayInput
        let size = CGSize(width: 60, height: 22)
        let inset: CGFloat = 6

        // Real two-display layout: built-in primary (menu bar) + external above-left.
        let builtIn = D(fullAXFrame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
                        visibleAXFrame: CGRect(x: 0, y: 39, width: 1710, height: 1073),
                        hasSystemMenuBar: true, isManaging: true, id: 1)
        let external = D(fullAXFrame: CGRect(x: -105, y: -1080, width: 1920, height: 1080),
                         visibleAXFrame: CGRect(x: -105, y: -1080, width: 1920, height: 1080),
                         hasSystemMenuBar: false, isManaging: true, id: 2)

        // Single display -> never float a redundant panel.
        c.check("single display -> no placements",
                IndicatorPlacement.placements(displays: [builtIn], indicatorSize: size, topInset: inset).isEmpty)

        // Two displays, both managing -> exactly one panel, on the external.
        let p = IndicatorPlacement.placements(displays: [builtIn, external], indicatorSize: size, topInset: inset)
        c.check("two displays -> one placement", p.count == 1)
        c.check("placement is on the external (id 2)", p.first?.displayID == 2)
        if let f = p.first?.frameAX {
            // Centered horizontally on the external's visible region.
            c.check("centered on external x", abs(f.midX - external.visibleAXFrame.midX) < 0.5)
            // Pinned topInset below the (negative) top edge.
            c.check("pinned below top edge", abs(f.minY - (external.visibleAXFrame.minY + inset)) < 0.5)
            c.check("uses requested size", f.width == 60 && f.height == 22)
            // Fully on-display.
            c.check("fully on external", external.fullAXFrame.contains(f))
        }

        // The menu-bar display is skipped even though it is managing.
        c.check("menu-bar display skipped",
                !p.contains { $0.displayID == 1 })

        // Non-managing external -> skipped (indicator only reflects a live strip).
        let dormantExternal = D(fullAXFrame: external.fullAXFrame, visibleAXFrame: external.visibleAXFrame,
                                hasSystemMenuBar: false, isManaging: false, id: 2)
        c.check("non-managing external skipped",
                IndicatorPlacement.placements(displays: [builtIn, dormantExternal], indicatorSize: size, topInset: inset).isEmpty)

        // Three displays: only the managing, non-menu-bar ones get panels.
        let third = D(fullAXFrame: CGRect(x: 1710, y: 0, width: 1280, height: 1080),
                      visibleAXFrame: CGRect(x: 1710, y: 0, width: 1280, height: 1080),
                      hasSystemMenuBar: false, isManaging: true, id: 3)
        let p3 = IndicatorPlacement.placements(displays: [builtIn, external, third], indicatorSize: size, topInset: inset)
        c.check("three displays -> two panels", p3.count == 2)
        c.check("panels on id 2 and 3", Set(p3.map { $0.displayID }) == Set([2, 3]))
        c.check("order preserved (2 then 3)", p3.map { $0.displayID } == [2, 3])

        // Degenerate: a panel WIDER than the display still lands on-display (top-left).
        let tiny = D(fullAXFrame: CGRect(x: 500, y: 500, width: 40, height: 18),
                     visibleAXFrame: CGRect(x: 500, y: 500, width: 40, height: 18),
                     hasSystemMenuBar: false, isManaging: true, id: 4)
        let pTiny = IndicatorPlacement.placements(displays: [builtIn, tiny], indicatorSize: size, topInset: inset)
        if let f = pTiny.first?.frameAX {
            c.check("oversized panel clamps to display left", f.minX == 500)
            c.check("oversized panel clamps to display top", f.minY == 500)
        } else { c.check("oversized panel still placed", false) }

        // Zero-size display does not crash and is dropped.
        let zero = D(fullAXFrame: .zero, visibleAXFrame: .zero,
                     hasSystemMenuBar: false, isManaging: true, id: 5)
        c.check("zero-size display dropped",
                IndicatorPlacement.placements(displays: [builtIn, zero], indicatorSize: size, topInset: inset).isEmpty)

        print("[mmtest] IndicatorPlacement: \(c.passed) passed, \(c.failed) failed")
        return c.failed == 0
    }

    // MARK: - FocusFollowsDisplay

    static func runFocus() -> Bool {
        let c = Counter()
        typealias S = FocusFollowsDisplay.StripInput
        let builtIn = S(displayAXFrame: CGRect(x: 0, y: 0, width: 1710, height: 1112), isManaging: true, id: 1)
        let external = S(displayAXFrame: CGRect(x: -105, y: -1080, width: 1920, height: 1080), isManaging: true, id: 2)
        let strips = [builtIn, external]

        // Window centered on the external resolves to strip index 1.
        let onExternal = CGRect(x: 200, y: -800, width: 600, height: 400)
        c.check("focus on external -> strip 1",
                FocusFollowsDisplay.resolveActiveStrip(focusedWindowAXFrame: onExternal, strips: strips, currentActive: 0) == 1)

        // Window on the built-in resolves to strip 0.
        let onBuiltIn = CGRect(x: 100, y: 100, width: 600, height: 400)
        c.check("focus on built-in -> strip 0",
                FocusFollowsDisplay.resolveActiveStrip(focusedWindowAXFrame: onBuiltIn, strips: strips, currentActive: 1) == 0)

        // Already on the resolved strip -> nil (no redundant switch).
        c.check("already active -> nil",
                FocusFollowsDisplay.resolveActiveStrip(focusedWindowAXFrame: onExternal, strips: strips, currentActive: 1) == nil)

        // nil focused frame -> nil.
        c.check("nil frame -> nil",
                FocusFollowsDisplay.resolveActiveStrip(focusedWindowAXFrame: nil, strips: strips, currentActive: 0) == nil)

        // Focused window on a NON-managing display's region -> nil (ignored).
        let dormantThird = S(displayAXFrame: CGRect(x: 1710, y: 0, width: 1280, height: 1080), isManaging: false, id: 3)
        let onThird = CGRect(x: 2000, y: 100, width: 400, height: 300)
        c.check("focus on non-managing display -> nil",
                FocusFollowsDisplay.resolveActiveStrip(focusedWindowAXFrame: onThird, strips: [builtIn, external, dormantThird], currentActive: 0) == nil)

        // Straddling a bezel resolves by MAX overlap. Mostly on external.
        let straddle = CGRect(x: -50, y: -200, width: 200, height: 200) // mostly external (x<0 band)
        c.check("bezel straddle -> max overlap (external)",
                FocusFollowsDisplay.resolveActiveStrip(focusedWindowAXFrame: straddle, strips: strips, currentActive: 0) == 1)

        // Single managing strip -> nil.
        c.check("single managing strip -> nil",
                FocusFollowsDisplay.resolveActiveStrip(focusedWindowAXFrame: onBuiltIn, strips: [builtIn], currentActive: 0) == nil)

        print("[mmtest] FocusFollowsDisplay: \(c.passed) passed, \(c.failed) failed")
        return c.failed == 0
    }

    // MARK: - AutoTilePolicy

    static func runAutoTile() -> Bool {
        let c = Counter()
        let std = kAXStandardWindowSubrole as String
        let dialog = kAXDialogSubrole as String

        func tile(subrole: String? = nil, minimized: Bool = false, fullscreen: Bool = false,
                  onSpace: Bool = true, isSelf: Bool = false, managed: Bool = false,
                  enabled: Bool = true, managing: Bool = true) -> Bool {
            AutoTilePolicy.shouldTile(subrole: subrole ?? std, isMinimized: minimized,
                                      isFullscreen: fullscreen, onCurrentSpace: onSpace,
                                      isSelf: isSelf, alreadyManaged: managed,
                                      enabled: enabled, managing: managing)
        }

        c.check("standard on-Space unmanaged while managing+enabled -> tile", tile())
        c.check("dialog subrole -> never tile", !tile(subrole: dialog))
        c.check("floating-panel subrole -> never tile",
                !tile(subrole: kAXFloatingWindowSubrole as String))
        c.check("minimized -> never tile", !tile(minimized: true))
        c.check("fullscreen -> never tile", !tile(fullscreen: true))
        c.check("off-Space -> never tile", !tile(onSpace: false))
        c.check("self window -> never tile", !tile(isSelf: true))
        c.check("already managed -> never tile", !tile(managed: true))
        c.check("disabled -> never tile", !tile(enabled: false))
        c.check("dormant (not managing) -> never tile", !tile(managing: false))
        // explicit nil subrole
        c.check("explicit nil subrole -> never tile",
                !AutoTilePolicy.shouldTile(subrole: nil, isMinimized: false, isFullscreen: false,
                                           onCurrentSpace: true, isSelf: false, alreadyManaged: false,
                                           enabled: true, managing: true))

        print("[mmtest] AutoTilePolicy: \(c.passed) passed, \(c.failed) failed")
        return c.failed == 0
    }
}
