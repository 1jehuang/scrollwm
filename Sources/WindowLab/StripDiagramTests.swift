import AppKit

/// Tests for the tutorial hero strip diagram: the PURE `StripDiagramModel`
/// (focus wrap/clamp, reorder, width-cycle, the keep-focus-visible viewport
/// rule, totals) plus an offscreen-render smoke test of `TutorialStripDiagramView`
/// (it must lay out + paint into a bitmap without crashing, animated AND in the
/// reduced-motion static fallback). The model assertions are headless; the view
/// smoke test only touches an offscreen bitmap, never a real window.
///
/// Run with: `WindowLab stripdiagramtest` (wired into `unittest` by coordinator).
enum StripDiagramTests {

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }
        func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

        // MARK: Totals / geometry

        let cols = [
            DiagramColumn(id: 0, appName: "A", title: "a", widthFraction: 0.5),
            DiagramColumn(id: 1, appName: "B", title: "b", widthFraction: 0.5),
            DiagramColumn(id: 2, appName: "C", title: "c", widthFraction: 1.0),
        ]
        var m = StripDiagramModel(columns: cols, focusIndex: 0)
        check("total width is sum of fractions", approx(m.totalWidth, 2.0))
        check("x(0) == 0", approx(m.x(of: 0), 0))
        check("x(1) == width(0)", approx(m.x(of: 1), 0.5))
        check("x(2) == 1.0", approx(m.x(of: 2), 1.0))
        check("maxOffset == total - viewport", approx(m.maxOffset, 1.0))

        // x() is a running prefix sum: sum of all widths == total.
        let prefixEnd = m.x(of: m.count - 1) + m.width(of: m.count - 1)
        check("prefix sum reaches total", approx(prefixEnd, m.totalWidth))

        // MARK: Viewport rule — keeps the focused column fully visible

        // Focus column 2 (x=1.0, w=1.0): it should scroll right so its right
        // edge sits at the viewport's right edge.
        m.setFocus(2)
        let want2 = m.x(of: 2) + m.width(of: 2) - m.viewportWidth  // = 1.0
        check("viewport reveals far-right column", approx(m.viewportTargetOffset(), want2))
        check("focused column fully inside target window", {
            let off = m.viewportTargetOffset()
            return m.x(of: 2) >= off - 1e-9 &&
                   m.x(of: 2) + m.width(of: 2) <= off + m.viewportWidth + 1e-9
        }())

        // Focus back to 0: scroll left, never negative.
        m.setFocus(0)
        check("viewport never negative", m.viewportTargetOffset() >= -1e-9)
        check("viewport reveals left column at 0", approx(m.viewportTargetOffset(), 0))

        // Never overscroll past the strip end.
        m.setFocus(m.count - 1)
        check("viewport clamped at maxOffset", m.viewportTargetOffset() <= m.maxOffset + 1e-9)

        // A focused column wider than the viewport pins its left edge in view.
        var wide = StripDiagramModel(columns: [
            DiagramColumn(id: 0, appName: "X", title: "x", widthFraction: 2.0),
        ], focusIndex: 0)
        wide.retargetViewport()
        check("over-wide focus pins left edge", approx(wide.viewportTargetOffset(), 0))

        // MARK: Focus wrap vs clamp

        var wrap = StripDiagramModel(columns: cols, focusIndex: 0, wrapsFocus: true)
        wrap.focus(by: -1)
        check("wrap: left from 0 -> last", wrap.focusIndex == 2)
        wrap.focus(by: 1)
        check("wrap: right from last -> 0", wrap.focusIndex == 0)
        wrap.focus(by: 5)   // 5 % 3 == 2
        check("wrap: multi-step modular", wrap.focusIndex == 2)

        var clamp = StripDiagramModel(columns: cols, focusIndex: 0, wrapsFocus: false)
        clamp.focus(by: -1)
        check("clamp: left from 0 stays 0", clamp.focusIndex == 0)
        clamp.focus(by: 99)
        check("clamp: right beyond end stays last", clamp.focusIndex == 2)

        // MARK: Reorder (move) — swaps + focus follows, clamps at ends

        var mv = StripDiagramModel(columns: cols, focusIndex: 1)
        let order0 = mv.columns.map { $0.id }
        check("initial order 0,1,2", order0 == [0, 1, 2])
        let movedR = mv.moveFocused(by: 1)
        check("move right succeeded", movedR)
        check("move right swaps ids", mv.columns.map { $0.id } == [0, 2, 1])
        check("focus follows moved column", mv.focusIndex == 2)
        let movedPastEnd = mv.moveFocused(by: 1)
        check("move past end refused", !movedPastEnd)
        check("order unchanged after refused move", mv.columns.map { $0.id } == [0, 2, 1])
        // A move never loses or duplicates a column.
        check("move preserves column set", Set(mv.columns.map { $0.id }) == Set([0, 1, 2]))
        check("move preserves count", mv.columns.count == 3)

        // MARK: Width-cycle — steps through presets, totals track

        var wc = StripDiagramModel(columns: [
            DiagramColumn(id: 0, appName: "A", title: "a", widthFraction: StripDiagramModel.widthPresets[0]),
        ], focusIndex: 0)
        let p = StripDiagramModel.widthPresets
        wc.cycleWidth()
        check("width cycles to preset 1", approx(wc.focusedColumn.widthFraction, p[1]))
        wc.cycleWidth()
        check("width cycles to preset 2", approx(wc.focusedColumn.widthFraction, p[2]))
        // Cycle through the rest back to the start.
        for _ in 0..<(p.count - 2) { wc.cycleWidth() }
        check("width wraps back to preset 0", approx(wc.focusedColumn.widthFraction, p[0]))
        check("width always a known preset", p.contains { approx($0, wc.focusedColumn.widthFraction) })

        // MARK: Spring eases value toward target over time, then settles

        var sm = StripDiagramModel(columns: cols, focusIndex: 0)
        sm.setFocus(2)
        let tgt = sm.viewportTargetOffset()
        check("viewport starts away from target", !approx(sm.viewport.value, tgt, 1e-3))
        for _ in 0..<600 { sm.step(1.0 / 120.0) }
        check("viewport eases to target", approx(sm.viewport.value, tgt, 1e-2))
        check("viewport settles", sm.isSettled)

        // MARK: Full demo script keeps the model valid throughout (loopable)

        var demo = StripDiagramModel.demo()
        let baseSet = Set(demo.columns.map { $0.id })
        var ok = true
        for _ in 0..<3 {   // three loops
            for a in StripDiagramModel.demoScript {
                demo.apply(a)
                for _ in 0..<30 { demo.step(1.0 / 60.0) }
                if Set(demo.columns.map { $0.id }) != baseSet { ok = false }
                if !demo.viewport.value.isFinite { ok = false }
                if demo.focusIndex < 0 || demo.focusIndex >= demo.count { ok = false }
                // Viewport stays within legal bounds (0...max, or pinned for over-wide focus).
                let upper = max(demo.maxOffset, demo.focusX)
                if demo.viewport.target < -1e-6 || demo.viewport.target > upper + 1e-6 { ok = false }
            }
        }
        check("demo script stays valid over 3 loops", ok)

        // MARK: Offscreen view smoke test (animated + reduced-motion)

        check("view renders offscreen (animated)", smokeRender(reduced: false))
        check("view renders offscreen (reduced motion)", smokeRender(reduced: true))

        print("\n[stripdiagramtest] \(passed) passed, \(failed) failed")
        return failed == 0
    }

    /// Construct the view, advance a few frames, and cache-render it into a
    /// bitmap. Asserts it produces a non-empty image without crashing. Touches
    /// only an offscreen bitmap — no real window, no display link.
    private static func smokeRender(reduced: Bool) -> Bool {
        let view = TutorialStripDiagramView()
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 200)
        view.forceReducedMotion = reduced
        // Advance several frames (drives the script + springs) when animated.
        if !reduced {
            for _ in 0..<120 { view.advance(dt: 1.0 / 60.0) }
        }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.pixelsWide > 0 && rep.pixelsHigh > 0
    }
}
