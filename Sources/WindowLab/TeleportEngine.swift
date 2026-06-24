import Foundation
import ApplicationServices
import AppKit

/// The teleport-tier core: windows live in columns on a horizontal strip.
/// Navigation = instant viewport jumps (no animation). All real, all AX.
///
/// Canvas model (PaperWM-style):
///   - The strip is a sequence of columns, one window per column (v1).
///   - The viewport shows a contiguous run of columns, centered on focus.
///   - Teleporting = recommitting every window to (canvasX - viewportX).
final class TeleportEngine {

    struct Slot {
        var window: ManagedWindowRef
        var canvasX: CGFloat       // left edge on the strip
        var width: CGFloat
        var y: CGFloat             // top, in screen coords
        var height: CGFloat
    }

    final class ManagedWindowRef {
        /// Stable, process-unique identity assigned at adoption. Unlike the
        /// array index (which shifts on insert/move/remove) this never changes
        /// for a given managed window, so the animated menu-bar view can track
        /// the same window across frames and animate it smoothly when columns
        /// are reordered, inserted, or removed. Assigned on the main thread.
        static var nextID: UInt64 = 0
        let id: UInt64

        let element: AXUIElement
        let pid: pid_t
        var appName: String
        var title: String
        var healthy = true
        /// Frame the window had before WE first moved it. Ground truth for restore.
        let originalFrame: CGRect
        /// Last screen-space origin we actually committed via AX. Used to skip
        /// redundant `setPoint` calls (each is a ~0.4ms cross-process round-trip),
        /// so a layout change only pays for windows that genuinely move. `nil`
        /// until the first commit, which forces an initial placement.
        var lastCommittedOrigin: CGPoint?

        init(element: AXUIElement, pid: pid_t, appName: String, title: String, originalFrame: CGRect) {
            Self.nextID += 1
            self.id = Self.nextID
            self.element = element
            self.pid = pid
            self.appName = appName
            self.title = title
            self.originalFrame = originalFrame
        }
    }

    // Mutable internally (lifecycle extension lives in another file).
    var slots: [Slot] = []
    private(set) var viewportX: CGFloat = 0
    var focusIndex: Int = 0

    let screenFrame: CGRect       // visible frame, AX coordinates (top-left origin)
    /// Spacing between columns and at the strip's outer edges. Config-driven
    /// (`layout.columnGap`); defaults to 12.
    var gap: CGFloat = 12
    /// Floor for column width so a resize can never collapse a window.
    /// Config-driven (`layout.minColumnWidth`); defaults to 200.
    var minColumnWidth: CGFloat = 200

    /// How the viewport follows the focused column.
    enum FocusMode: String, CaseIterable {
        /// Always center the focused column in the viewport (original behavior).
        case centered
        /// Only scroll the minimum needed so the focused column is fully on
        /// screen; if it already fits, the viewport does not move (PaperWM /
        /// niri "fit" behavior).
        case fit

        var label: String {
            switch self {
            case .centered: return "Centered"
            case .fit: return "Fit (scroll only when needed)"
            }
        }
    }

    /// Current focus-follow mode. Defaults to `fit` per user preference.
    var focusMode: FocusMode = .fit

    /// Column-width presets (fractions of usable width) bound to the width
    /// keys. Config-driven (`layout.widthPresets`); defaults to the static
    /// `widthPresets`.
    var widthPresets: [CGFloat] = TeleportEngine.widthPresets

    // Metrics
    private(set) var lastTeleportMs: Double = 0
    private(set) var teleportLatencies: [Double] = []
    /// Cumulative count of AX position writes actually issued (no-op commits
    /// are skipped). Lets tests assert that a layout change only moved the
    /// windows that truly needed to move.
    private(set) var totalCommits: Int = 0

    var onLayoutChange: (() -> Void)?

    init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
    }

    // MARK: - Adoption

    /// Lay out adopted windows as a strip of columns, preserving sizes.
    /// The strip opens with a `gap` leading margin so the first column is not
    /// flush against the screen edge (symmetric with the trailing margin).
    func adopt(matched: [MatchedWindow]) {
        var x: CGFloat = gap
        slots = matched.filter {
            $0.ax.subrole == kAXStandardWindowSubrole as String
                && !$0.ax.isMinimized && !$0.ax.isFullscreen
        }.map { m in
            AXSource.setTimeout(m.ax.element, seconds: 0.08)
            // Mirror the window's REAL frame size. The teleport pass only moves
            // windows, never resizes them, so clamping the stored size to the
            // usable area would desync the model from reality: `compactStrip`
            // would pack the next column too close and an over-wide window would
            // bleed past the viewport edge by the clamped-off amount. Keep
            // model == reality; `viewportTarget` handles over-wide columns.
            let width = m.ax.frame.width
            let height = m.ax.frame.height
            let slot = Slot(
                window: ManagedWindowRef(
                    element: m.ax.element,
                    pid: m.ax.pid,
                    appName: m.ax.appName,
                    title: m.ax.title ?? "(untitled)",
                    originalFrame: m.ax.frame
                ),
                canvasX: x,
                width: width,
                y: screenFrame.origin.y,
                height: height
            )
            x += width + gap
            return slot
        }
        focusIndex = slots.isEmpty ? 0 : 0
        viewportX = 0
        commitAll()
    }

    // MARK: - Navigation (all instant)

    func focusNext() { focus(index: focusIndex + 1) }
    func focusPrevious() { focus(index: focusIndex - 1) }

    func focus(index: Int) {
        guard !slots.isEmpty else { return }
        let clamped = max(0, min(slots.count - 1, index))
        focusIndex = clamped

        let slot = slots[clamped]
        viewportX = viewportTarget(for: slot, mode: focusMode, currentViewportX: viewportX)

        teleport()
        raiseAndFocus(slot.window)
        onLayoutChange?()
    }

    /// Re-fit the viewport to the currently focused column WITHOUT re-raising
    /// or re-activating its app. Recomputes the viewport target for the current
    /// focus mode and teleports. Used after an asynchronous resize settles so
    /// the viewport follows the window to full visibility, without the focus
    /// flicker / app reactivation that `focus(index:)` would cause (the window
    /// is already focused; we only need to scroll the strip).
    func refitViewportToFocused() {
        guard slots.indices.contains(focusIndex) else { return }
        let slot = slots[focusIndex]
        viewportX = viewportTarget(for: slot, mode: focusMode, currentViewportX: viewportX)
        teleport()
        onLayoutChange?()
    }

    /// "Show All Windows": resize every column to an equal share of the viewport
    /// so all managed windows are visible at once, then scroll the viewport back
    /// to the strip origin. Best-effort: when there are too many windows to fit
    /// at `minColumnWidth`, columns stay at the floor width and the strip may
    /// still overflow, in which case we simply show it from the start.
    ///
    /// Like every resize path, sizes are reconciled against the live AX frame
    /// (apps clamp to their own minimums while still reporting `.success`), so
    /// the model never diverges from reality.
    func fitAllColumns() {
        guard !slots.isEmpty else { return }
        let target = equalShareWidth(count: slots.count)
        for i in slots.indices {
            // Optimistically update the model so a missing readback (unhealthy
            // app) still reflects the requested width.
            slots[i].width = target
            let slot = slots[i]
            guard slot.window.healthy else { continue }
            _ = AXSource.setSize(
                slot.window.element,
                kAXSizeAttribute as String,
                CGSize(width: target, height: slot.height)
            )
            if let actual = AXSource.copySize(slot.window.element, kAXSizeAttribute as String) {
                slots[i].width = actual.width
                slots[i].height = actual.height
            }
        }
        compactStrip()
        viewportX = 0          // show the strip from its leading edge
        teleport()
        onLayoutChange?()
    }

    /// Equal-share column width so `count` columns tile the viewport with gaps:
    ///   leftMargin + count*w + (count-1)*gap + rightMargin = V,  margins == gap
    ///     => w = (V - (count+1)*gap) / count
    /// This is exactly `width(forFraction: 1/count)`. Floored at
    /// `minColumnWidth` so a very crowded strip overflows rather than collapsing
    /// a window to nothing.
    func equalShareWidth(count: Int) -> CGFloat {
        guard count > 0 else { return minColumnWidth }
        return width(forFraction: 1.0 / CGFloat(count))
    }

    /// Compute where the viewport's left edge should sit so that `slot` is
    /// shown according to `mode`. Pure function (no side effects) so it can be
    /// unit-tested directly.
    ///
    /// - centered: place the column in the middle of the viewport.
    /// - fit: keep the current viewport unless the column is partly/fully
    ///        offscreen, then scroll the minimum amount to fully reveal it,
    ///        aligning to whichever edge it overflowed.
    func viewportTarget(for slot: Slot, mode: FocusMode, currentViewportX: CGFloat) -> CGFloat {
        switch mode {
        case .centered:
            let target = slot.canvasX - (screenFrame.width - slot.width) / 2
            // viewportX 0 maps the strip's leading `gap` margin to the screen
            // edge, so 0 is the leftmost meaningful scroll position.
            return max(0, target)

        case .fit:
            let viewLeft = currentViewportX
            let viewRight = currentViewportX + screenFrame.width
            let slotLeft = slot.canvasX
            let slotRight = slot.canvasX + slot.width

            if slot.width >= screenFrame.width {
                // Wider than the screen: align its left edge (with a small gap)
                // so the start of the window is visible.
                return slotLeft - gap
            }
            if slotLeft < viewLeft {
                // Overflows left: bring its left edge to the viewport's left
                // (with a small gap for breathing room). viewportX 0 already
                // leaves the strip's leading `gap` margin, so 0 is the floor.
                return max(0, slotLeft - gap)
            }
            if slotRight > viewRight {
                // Overflows right: bring its right edge to the viewport's right.
                return slotRight - screenFrame.width + gap
            }
            // Already fully visible: don't move.
            return currentViewportX
        }
    }

    /// Recommit every window to its strip position minus viewport offset.
    /// This IS the teleport: one synchronous pass, prioritized smartly.
    ///
    /// Only windows whose target origin actually changed since the last commit
    /// are written via AX. A no-op layout change (e.g. opening a window that
    /// fits to the right, leaving every other column put) therefore costs zero
    /// AX round-trips for the unchanged windows.
    ///
    /// Off-screen handling: macOS clamps any window position to keep ~40px on
    /// screen at every edge, so a column scrolled fully past the viewport cannot
    /// actually leave the screen via position alone - it would otherwise leave a
    /// visible sliver at the edge (and several stacked columns leave several
    /// slivers). To avoid that, columns whose on-screen rect does not intersect
    /// the viewport are PARKED at a single shared off-screen corner, so they all
    /// collapse to one unobtrusive 40x32px sliver instead of a row of them.
    @discardableResult
    func teleport() -> Int {
        let start = Clock.nowAbsNs()

        // Commit order: focused first (user is looking at it), then
        // on-screen left-to-right, then off-screen.
        let indices = commitOrder()
        var committed = 0
        for i in indices {
            let slot = slots[i]
            guard slot.window.healthy else { continue }
            let target = onScreenTarget(for: slot)
            // Skip windows that are already where they should be (within a
            // sub-pixel tolerance): the AX write would be a wasted round-trip.
            if let last = slot.window.lastCommittedOrigin,
               abs(last.x - target.x) < 0.5, abs(last.y - target.y) < 0.5 {
                continue
            }
            let err = AXSource.setPoint(slot.window.element, kAXPositionAttribute as String, target)
            if err != .success {
                slot.window.healthy = false
            } else {
                slot.window.lastCommittedOrigin = target
                committed += 1
            }
        }

        totalCommits += committed
        lastTeleportMs = Double(Clock.nowAbsNs() &- start) / 1e6
        teleportLatencies.append(lastTeleportMs)
        return committed
    }

    /// Where a slot's window should actually be placed. If the column is at
    /// least partly within the viewport, that is its natural strip position.
    /// If it is fully off-screen, return the shared parking corner so all
    /// off-screen columns collapse into one sliver (see `teleport`).
    func onScreenTarget(for slot: Slot) -> CGPoint {
        let left = slot.canvasX - viewportX           // viewport-relative left
        let right = left + slot.width
        let fullyOffscreen = right <= 0 || left >= screenFrame.width
        if fullyOffscreen {
            return parkingPoint
        }
        return CGPoint(x: screenFrame.origin.x + slot.canvasX - viewportX, y: slot.y)
    }

    /// Full AX-frame (top-left origin) of the display the strip lives on. Set by
    /// the controller from `NSScreen`. When nil we fall back to `screenFrame`
    /// (the visible frame), which is correct for the common single-display case.
    var stripDisplayFrame: CGRect?

    /// Full AX-frames of every OTHER display (everything except the strip's).
    /// Empty on single-display setups. macOS never lets a window move fully
    /// off-screen - it clamps to keep ~40px visible at some display edge - so an
    /// off-viewport column always leaves one small sliver. With multiple
    /// displays the naive bottom-right corner clamps that sliver onto the
    /// NEIGHBORING monitor (it "peeks" there). Knowing the other displays lets
    /// us pick a corner whose sliver lands on the strip's OWN display, in a
    /// direction with no adjacent screen.
    var otherDisplayFrames: [CGRect] = []

    /// Shared off-screen parking point: far enough past a free corner that macOS
    /// clamps every parked window to the SAME spot, stacking them into a single
    /// minimal sliver rather than a row of peeking edges. Display-aware: the
    /// corner is chosen so the sliver stays on the strip's display and away from
    /// any neighbor monitor (see `computeParkingPoint`).
    var parkingPoint: CGPoint {
        TeleportEngine.computeParkingPoint(
            stripDisplay: stripDisplayFrame ?? screenFrame,
            others: otherDisplayFrames
        )
    }

    /// Pure parking-corner policy (no side effects, unit-tested).
    ///
    /// Picks the corner of `stripDisplay` to shove parked windows past, so the
    /// unavoidable ~40px macOS clamp sliver lands on `stripDisplay` along an edge
    /// that has NO adjacent display. Pushing toward a free edge makes macOS slide
    /// the window back to the strip display's own outer edge (40px visible there)
    /// instead of onto a neighbor monitor.
    ///
    /// Direction preference per axis: a free edge if one exists, else the legacy
    /// direction (right / bottom) as a graceful fallback when the strip display
    /// is hemmed in on both sides of that axis.
    static func computeParkingPoint(stripDisplay s: CGRect,
                                    others: [CGRect],
                                    margin: CGFloat = 4000) -> CGPoint {
        // A neighbor only "blocks" an edge if it actually abuts that side AND
        // overlaps along the perpendicular axis (a display diagonally offset does
        // not catch a sliver pushed straight out that edge).
        func vOverlap(_ d: CGRect) -> Bool { d.minY < s.maxY && d.maxY > s.minY }
        func hOverlap(_ d: CGRect) -> Bool { d.minX < s.maxX && d.maxX > s.minX }
        let leftBlocked  = others.contains { $0.maxX <= s.minX + 1 && vOverlap($0) }
        let rightBlocked = others.contains { $0.minX >= s.maxX - 1 && vOverlap($0) }
        let topBlocked   = others.contains { $0.maxY <= s.minY + 1 && hOverlap($0) }
        let botBlocked   = others.contains { $0.minY >= s.maxY - 1 && hOverlap($0) }

        // Prefer a free edge; keep legacy right/bottom when both sides are taken.
        let goRight: Bool = !rightBlocked ? true : (!leftBlocked ? false : true)
        let goBottom: Bool = !botBlocked ? true : (!topBlocked ? false : true)

        let x = goRight ? s.maxX + margin : s.minX - margin
        let y = goBottom ? s.maxY + margin : s.minY - margin
        return CGPoint(x: x, y: y)
    }

    /// Test seam: set the viewport offset directly (production code sets it via
    /// `focus`/navigation). Used by unit tests for the parking logic.
    func setViewportXForTest(_ x: CGFloat) { viewportX = x }

    private func commitOrder() -> [Int] {
        guard !slots.isEmpty else { return [] }
        var onscreen: [Int] = []
        var offscreen: [Int] = []
        for (i, slot) in slots.enumerated() where i != focusIndex {
            let left = slot.canvasX - viewportX
            let right = left + slot.width
            if right > 0 && left < screenFrame.width {
                onscreen.append(i)
            } else {
                offscreen.append(i)
            }
        }
        return [focusIndex] + onscreen + offscreen
    }

    private func raiseAndFocus(_ window: ManagedWindowRef) {
        // Raise above its app's other windows, then mark it main/focused so a
        // multi-window app routes keyboard input to THIS window (just raising
        // is not enough). Finally activate the owning app.
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXSource.setBool(window.element, kAXMainAttribute as String, true)
        AXSource.setBool(window.element, kAXFocusedAttribute as String, true)
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate()
        }
    }

    // MARK: - Introspection for the menu bar

    struct StripState {
        let slots: [(id: UInt64, appName: String, title: String, canvasX: CGFloat, width: CGFloat, healthy: Bool)]
        let viewportX: CGFloat
        let viewportWidth: CGFloat
        let focusIndex: Int
        let lastTeleportMs: Double
    }

    var stripState: StripState {
        StripState(
            slots: slots.map { ($0.window.id, $0.window.appName, $0.window.title, $0.canvasX, $0.width, $0.window.healthy) },
            viewportX: viewportX,
            viewportWidth: screenFrame.width,
            focusIndex: focusIndex,
            lastTeleportMs: lastTeleportMs
        )
    }

    var commitAllCount: Int { slots.count }

    func commitAll() {
        teleport()
    }

    func teleportStats() -> LatencyStats {
        LatencyStats(label: "teleport.full", samples: teleportLatencies)
    }

    /// Restore every managed window to its pre-adoption frame (position AND
    /// size) and stop managing it. Returns the number of failures.
    ///
    /// Failures are determined by READBACK, not AX error codes: some windows
    /// (e.g. fixed-size ones) return errors for no-op resizes while ending up
    /// exactly where they belong.
    @discardableResult
    func releaseAll() -> Int {
        var failures = 0
        for slot in slots {
            let w = slot.window
            _ = AXSource.setPoint(w.element, kAXPositionAttribute as String, w.originalFrame.origin)
            _ = AXSource.setSize(w.element, kAXSizeAttribute as String, w.originalFrame.size)

            // Verify by reading back the actual frame.
            if let pos = AXSource.copyPoint(w.element, kAXPositionAttribute as String),
               let size = AXSource.copySize(w.element, kAXSizeAttribute as String) {
                let ok = abs(pos.x - w.originalFrame.origin.x) <= 2
                    && abs(pos.y - w.originalFrame.origin.y) <= 2
                    && abs(size.width - w.originalFrame.width) <= 2
                    && abs(size.height - w.originalFrame.height) <= 2
                if !ok { failures += 1 }
            } else {
                failures += 1
            }
        }
        slots.removeAll()
        focusIndex = 0
        viewportX = 0
        onLayoutChange?()
        return failures
    }
}
