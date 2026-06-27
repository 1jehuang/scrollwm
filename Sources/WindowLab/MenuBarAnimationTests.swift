import Foundation
import ApplicationServices

/// Pure-logic tests for the animated menu-bar mini-map: the `Spring`
/// integrator and the `MenuBarDiff` action inference. No AppKit window or
/// display link required, so these run headless in CI.
///
/// Run with: `WindowLab animtest`
enum MenuBarAnimationTests {

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        // MARK: Spring

        // Critically damped spring converges to target without overshoot.
        var s = Spring(0, response: 0.3, dampingFraction: 1.0)
        s.target = 100
        var overshot = false
        for _ in 0..<600 { // ~5s at 120Hz
            s.step(1.0 / 120.0)
            if s.value > 100.5 { overshot = true }
        }
        check("critically damped reaches target", abs(s.value - 100) < 0.5)
        check("critically damped does not overshoot", !overshot)
        check("critically damped settles", s.isSettled)

        // Underdamped spring overshoots then still settles at the target.
        var u = Spring(0, response: 0.3, dampingFraction: 0.5)
        u.target = 100
        var peak = 0.0
        for _ in 0..<600 {
            u.step(1.0 / 120.0)
            peak = max(peak, u.value)
        }
        check("underdamped overshoots", peak > 100.5)
        check("underdamped settles at target", abs(u.value - 100) < 0.5)
        check("underdamped settles flag", u.isSettled)

        // A big dt is sub-stepped: result matches many small steps closely
        // (stability check — no blow-up on a hitched frame).
        var big = Spring(0, response: 0.3, dampingFraction: 0.8); big.target = 50
        var small = Spring(0, response: 0.3, dampingFraction: 0.8); small.target = 50
        big.step(0.1)
        for _ in 0..<12 { small.step(0.1 / 12.0) }
        check("substepping matches fine steps", abs(big.value - small.value) < 1.0)
        check("large dt stays finite", big.value.isFinite && abs(big.value) < 1000)

        // kick adds velocity; reset zeroes motion.
        var k = Spring(10); k.kick(5)
        check("kick injects velocity", k.velocity == 5)
        k.reset(to: 3)
        check("reset clears velocity", k.velocity == 0 && k.value == 3 && k.target == 3)

        // step(0) is a no-op.
        var z = Spring(7); z.target = 9; z.step(0)
        check("step(0) is a no-op", z.value == 7)

        // MARK: Diff inference

        func state(_ ids: [UInt64], focus: Int, widths: [CGFloat]? = nil,
                   viewportX: CGFloat = 0) -> TeleportEngine.StripState {
            var x: CGFloat = 12
            var slots: [(id: UInt64, appName: String, title: String, canvasX: CGFloat, width: CGFloat, healthy: Bool)] = []
            for (i, id) in ids.enumerated() {
                let w = widths?[i] ?? 400
                slots.append((id: id, appName: "App\(id)", title: "Win\(id)", canvasX: x, width: w, healthy: true))
                x += w + 12
            }
            return TeleportEngine.StripState(slots: slots, viewportX: viewportX,
                                             viewportWidth: 1600, focusIndex: focus, lastTeleportMs: 0)
        }

        // arrange: dormant -> managing with windows.
        let a0 = MenuBarDiff.infer(old: nil, oldManaging: false,
                                   new: state([1, 2, 3], focus: 0), newManaging: true)
        check("arrange inferred", a0.contains(.arrange))

        // release: managing -> dormant.
        let a1 = MenuBarDiff.infer(old: state([1, 2, 3], focus: 0), oldManaging: true,
                                   new: state([], focus: 0), newManaging: false)
        check("release inferred", a1 == [.release])

        // focus change to the right (id 1 -> id 2): direction +1.
        let f = MenuBarDiff.infer(old: state([1, 2, 3], focus: 0), oldManaging: true,
                                  new: state([1, 2, 3], focus: 1), newManaging: true)
        check("focus change inferred", f.contains(.focusChanged(toID: 2, direction: 1)))

        // focus change to the left (id 3 -> id 1): direction -1.
        let fl = MenuBarDiff.infer(old: state([1, 2, 3], focus: 2), oldManaging: true,
                                   new: state([1, 2, 3], focus: 0), newManaging: true)
        check("focus left direction", fl.contains(.focusChanged(toID: 1, direction: -1)))

        // added: a new window appears.
        let add = MenuBarDiff.infer(old: state([1, 2], focus: 0), oldManaging: true,
                                    new: state([1, 2, 9], focus: 0), newManaging: true)
        check("added inferred", add.contains(.added([9])))

        // removed: a window closes.
        let rem = MenuBarDiff.infer(old: state([1, 2, 3], focus: 0), oldManaging: true,
                                    new: state([1, 3], focus: 0), newManaging: true)
        check("removed inferred", rem.contains(.removed([2])))

        // reordered: two survivors swap order, none added/removed.
        let reo = MenuBarDiff.infer(old: state([1, 2, 3], focus: 0), oldManaging: true,
                                    new: state([2, 1, 3], focus: 0), newManaging: true)
        check("reorder inferred", reo.contains(.reordered([2, 1, 3])))
        check("reorder has no add/remove",
              !reo.contains(where: { if case .added = $0 { return true }; return false }) &&
              !reo.contains(where: { if case .removed = $0 { return true }; return false }))

        // resized: a survivor's width changes materially.
        let rz = MenuBarDiff.infer(old: state([1, 2], focus: 0, widths: [400, 400]), oldManaging: true,
                                   new: state([1, 2], focus: 0, widths: [800, 400]), newManaging: true)
        check("resize inferred", rz.contains(.resized([1])))

        // no-op: identical state yields no actions.
        let noop = MenuBarDiff.infer(old: state([1, 2, 3], focus: 1), oldManaging: true,
                                     new: state([1, 2, 3], focus: 1), newManaging: true)
        check("identical state -> no actions", noop.isEmpty)

        // a sub-pixel width jitter is NOT a resize.
        let jit = MenuBarDiff.infer(old: state([1], focus: 0, widths: [400.0]), oldManaging: true,
                                    new: state([1], focus: 0, widths: [400.4]), newManaging: true)
        check("sub-pixel width jitter ignored", jit.isEmpty)

        // MARK: Adaptive width metrics

        // One full screen of strip maps to exactly pointsPerScreen.
        let oneScreen = MenuBarMetrics.contentWidth(
            span: 1600, screenWidth: 1600, pointsPerScreen: 30, minWidth: 30, maxWidth: 220)
        check("one screen -> pointsPerScreen", abs(oneScreen - 30) < 0.01)

        // Two screens of strip is twice as wide (linear growth as windows pile up).
        let twoScreens = MenuBarMetrics.contentWidth(
            span: 3200, screenWidth: 1600, pointsPerScreen: 30, minWidth: 30, maxWidth: 220)
        check("two screens -> double width", abs(twoScreens - 60) < 0.01)

        // A 25% strip never goes below the floor (min clamp).
        let quarter = MenuBarMetrics.contentWidth(
            span: 400, screenWidth: 1600, pointsPerScreen: 30, minWidth: 30, maxWidth: 220)
        check("sub-screen clamps to min", abs(quarter - 30) < 0.01)

        // 25% vs 50% column density is constant below the cap: doubling the
        // span doubles the width (so each window keeps a fixed on-map size).
        let w25 = MenuBarMetrics.contentWidth(
            span: 2000, screenWidth: 1600, pointsPerScreen: 30, minWidth: 30, maxWidth: 999)
        let w50 = MenuBarMetrics.contentWidth(
            span: 4000, screenWidth: 1600, pointsPerScreen: 30, minWidth: 30, maxWidth: 999)
        check("density constant below cap", abs((w50 / w25) - 2) < 0.01)

        // A huge strip is capped so it never overruns the menu bar.
        let huge = MenuBarMetrics.contentWidth(
            span: 100_000, screenWidth: 1600, pointsPerScreen: 30, minWidth: 30, maxWidth: 220)
        check("huge strip capped at max", abs(huge - 220) < 0.01)

        // Degenerate inputs fall back to the floor, never NaN/negative.
        let degZero = MenuBarMetrics.contentWidth(
            span: 0, screenWidth: 0, pointsPerScreen: 30, minWidth: 30, maxWidth: 220)
        check("degenerate input -> min", degZero == 30)

        // MARK: Key-hint keycap HUD lifecycle (view-level, no window needed)

        let view = MenuBarStripView(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
        let t0 = 1000.0
        check("no hint before any press", view.debugHintText == nil)

        // A press shows the chord + action; the keycap pop is alive (so the
        // display link keeps running) right after the press.
        view.flashKeyHint(chord: "⌘L", action: "Focus →", now: t0)
        check("press shows chord + action", view.debugHintText == "⌘L  Focus →")
        view.advance(dt: 1.0 / 60.0, now: t0 + 1.0 / 60.0)
        check("hint persists during hold", view.debugHintText == "⌘L  Focus →")

        // A re-press of the SAME chord re-pops and keeps the HUD up.
        view.flashKeyHint(chord: "⌘L", action: "Focus →", now: t0 + 0.1)
        check("re-press keeps hint", view.debugHintText == "⌘L  Focus →")

        // After the hold elapses the HUD eases out and clears itself.
        var vt = t0 + 0.1
        for _ in 0..<240 { vt += 1.0 / 60.0; view.advance(dt: 1.0 / 60.0, now: vt) }
        check("hint clears after hold + fade", view.debugHintText == nil)

        // An action with no chord shows just the action (no keycap text).
        view.flashKeyHint(chord: "", action: "Toggle", now: vt)
        check("chord-less hint shows action only", view.debugHintText == "Toggle")

        // MARK: Workspace number badge + all-workspaces overview

        // Build a multi-workspace StripState: 3 vertical workspaces, the 2nd
        // active, each with a couple of columns.
        func ws(_ ids: [UInt64], focus: Int, active: Bool, vw: CGFloat = 1600) -> TeleportEngine.StripState.WorkspaceStrip {
            var x: CGFloat = 12
            var s: [(id: UInt64, appName: String, title: String, canvasX: CGFloat, width: CGFloat, healthy: Bool)] = []
            for id in ids { s.append((id: id, appName: "kitty", title: "w\(id)", canvasX: x, width: 360, healthy: true)); x += 372 }
            return .init(slots: s, viewportX: 0, viewportWidth: vw, focusIndex: focus, isActive: active)
        }
        let stack = [ws([1, 2], focus: 0, active: false),
                     ws([3, 4, 5], focus: 1, active: true),
                     ws([6], focus: 0, active: false)]
        var multi = state([3, 4, 5], focus: 1)
        multi.activeWorkspace = 1
        multi.workspaceCount = 3
        multi.workspaces = stack

        // Badge: on by default, shows the 1-based active index, only when >1 ws.
        let badgeView = MenuBarStripView(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
        badgeView.showWorkspaceNumber = true
        badgeView.showAllWorkspaces = false
        badgeView.apply(state: multi, managing: true, now: vt)
        check("badge shown with >1 workspace", badgeView.debugShowsBadge)
        check("badge label is active index (2)", badgeView.debugBadgeLabel == "2")
        check("single-strip mode when not stacking", !badgeView.debugStackedMode)

        // Badge suppressed when there is only one workspace.
        let single = state([1, 2, 3], focus: 0)   // workspaceCount defaults to 1
        badgeView.apply(state: single, managing: true, now: vt)
        check("no badge with a single workspace", !badgeView.debugShowsBadge)

        // Badge respects the config toggle.
        let noBadge = MenuBarStripView(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
        noBadge.showWorkspaceNumber = false
        noBadge.apply(state: multi, managing: true, now: vt)
        check("badge off when disabled", !noBadge.debugShowsBadge)

        // All-workspaces overview: stacks every workspace when enabled and >1.
        let stackView = MenuBarStripView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        stackView.showAllWorkspaces = true
        stackView.apply(state: multi, managing: true, now: vt)
        check("stacked mode on with >1 workspace", stackView.debugStackedMode)
        check("stack holds every workspace row", stackView.debugWorkspaceRowCount == 3)

        // Stacking falls back to single-strip for a lone workspace.
        stackView.apply(state: single, managing: true, now: vt)
        check("stacking falls back for single workspace", !stackView.debugStackedMode)

        // Dormant (not managing) never badges or stacks.
        stackView.apply(state: multi, managing: false, now: vt)
        check("no stack/badge while dormant", !stackView.debugStackedMode && !stackView.debugShowsBadge)

        // Width: the badge adds a fixed gutter; stacking sizes to the WIDEST
        // workspace (here ws index 1 with 3 columns), never less than the
        // active strip alone.
        let plain = MenuBarStripView(frame: .zero)
        plain.showWorkspaceNumber = false; plain.showAllWorkspaces = false
        let wPlain = plain.debugDesiredContentWidth(for: multi, managing: true)
        let withBadge = MenuBarStripView(frame: .zero)
        withBadge.showWorkspaceNumber = true; withBadge.showAllWorkspaces = false
        let wBadge = withBadge.debugDesiredContentWidth(for: multi, managing: true)
        check("badge widens the icon by the gutter", wBadge > wPlain)

        // Regression: an EMPTY active workspace (e.g. you just switched DOWN to a
        // fresh empty workspace, or moved the last column out) still shows the
        // workspace number. The strip itself fades to the dormant glyph, but the
        // badge must persist so you can tell WHICH workspace you're on.
        let emptyActive = ws([], focus: 0, active: true)
        var emptyStack = state([], focus: 0)        // active strip has no columns
        emptyStack.activeWorkspace = 1
        emptyStack.workspaceCount = 3
        emptyStack.workspaces = [ws([1, 2], focus: 0, active: false),
                                 emptyActive,
                                 ws([6], focus: 0, active: false)]
        let emptyBadgeView = MenuBarStripView(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
        emptyBadgeView.showWorkspaceNumber = true
        emptyBadgeView.showAllWorkspaces = false
        emptyBadgeView.apply(state: emptyStack, managing: true, now: vt)
        check("badge shown on an EMPTY active workspace", emptyBadgeView.debugShowsBadge)
        check("badge label is active index (2) when empty", emptyBadgeView.debugBadgeLabel == "2")
        // The icon must reserve the badge gutter so the number isn't clipped:
        // its width exceeds the bare dormant floor by the gutter.
        let wEmpty = emptyBadgeView.debugDesiredContentWidth(for: emptyStack, managing: true)
        let bare = MenuBarStripView(frame: .zero)
        bare.showWorkspaceNumber = false
        let wEmptyBare = bare.debugDesiredContentWidth(for: emptyStack, managing: true)
        check("empty-workspace badge reserves the gutter", wEmpty > wEmptyBare)

        // Releasing (stop managing) on an empty workspace drops the badge.
        emptyBadgeView.apply(state: emptyStack, managing: false, now: vt)
        check("no badge once released", !emptyBadgeView.debugShowsBadge)

        print("\n[animtest] \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
