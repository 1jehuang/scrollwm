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

    // MARK: - Vertical workspaces (niri-style)
    //
    // Workspaces are stacked VERTICALLY. Each is an independent horizontal
    // strip. The ACTIVE workspace's live state is the existing
    // `slots`/`viewportX`/`focusIndex` above (so every existing code path keeps
    // working unchanged and pays no extra cost). Inactive workspaces are stashed
    // here; `workspaces[activeWorkspace]` is a stale placeholder kept only for
    // ordering — never read its slots for the active index (use the live ones).
    struct Workspace {
        var slots: [Slot] = []
        var viewportX: CGFloat = 0
        var focusIndex: Int = 0
    }
    private var workspaces: [Workspace] = [Workspace()]
    private(set) var activeWorkspace = 0
    /// Total number of vertical workspaces (always >= 1).
    var workspaceCount: Int { workspaces.count }

    /// Slots of workspace `i`, transparently returning the live active slots for
    /// the active index (whose authoritative copy is `slots`, not the stash).
    private func workspaceSlots(_ i: Int) -> [Slot] {
        i == activeWorkspace ? slots : workspaces[i].slots
    }

    /// Every managed window across ALL workspaces, in (workspace, strip) order.
    /// Used by crash-recovery persistence and release so no workspace is lost.
    var allManagedSlots: [Slot] {
        var out: [Slot] = []
        for i in workspaces.indices { out += workspaceSlots(i) }
        return out
    }

    /// True if `element` is managed in ANY workspace (active or stashed). The
    /// lifecycle monitor uses this so a window parked in an inactive workspace
    /// is never re-adopted into the active one (it is still on-screen as the
    /// shared parking sliver, so the naive current-Space test would re-add it).
    func isManaged(_ element: AXUIElement) -> Bool {
        for i in workspaces.indices {
            if workspaceSlots(i).contains(where: { CFEqual($0.window.element, element) }) {
                return true
            }
        }
        return false
    }

    /// Visible frame of the strip's display, AX coordinates (top-left origin).
    /// Mutable so the strip can follow a display resolution/arrangement change
    /// or move to a different monitor at runtime (`rebindStripDisplay`); every
    /// layout computation reads this live, so a rebind + `teleport()` relays the
    /// whole strip onto the new geometry.
    private(set) var screenFrame: CGRect
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
        // A fresh arrange starts from a single workspace.
        workspaces = [Workspace()]
        activeWorkspace = 0
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

    // MARK: - Vertical workspace switching

    /// Switch DOWN (`delta == +1`, niri "workspace-down") or UP
    /// (`delta == -1`, "workspace-up") by `delta` workspaces. Going down past
    /// the last workspace creates a fresh empty one (niri-style dynamic
    /// workspaces); going up past the first is a no-op. Returns the workspace we
    /// ended on (unchanged on a no-op).
    @discardableResult
    func switchWorkspace(by delta: Int) -> Int {
        guard delta != 0 else { return activeWorkspace }
        let target = activeWorkspace + delta
        if target < 0 { return activeWorkspace }            // already at the top
        if target >= workspaces.count {
            // Only one trailing empty workspace ever exists: if the current one
            // is already empty there is nothing below to create.
            if slots.isEmpty { return activeWorkspace }
            workspaces.append(Workspace())
        }
        activateWorkspace(target)
        return activeWorkspace
    }

    /// Move the focused column out of the active workspace and into the one
    /// `delta` away (creating a new trailing workspace if needed), then FOLLOW
    /// it there (niri "move-column-to-workspace-down/up"). Returns false when
    /// nothing is focused or the move is off the top edge.
    @discardableResult
    func moveFocusedToWorkspace(by delta: Int) -> Bool {
        guard slots.indices.contains(focusIndex), delta != 0 else { return false }
        let target = activeWorkspace + delta
        if target < 0 { return false }                       // no workspace above
        if target >= workspaces.count { workspaces.append(Workspace()) }

        // Detach the focused column from the active strip.
        let moved = slots.remove(at: focusIndex)
        focusIndex = slots.isEmpty ? 0 : max(0, min(focusIndex, slots.count - 1))
        compactStrip()

        // Append it to the destination workspace and make it the focus there.
        workspaces[target].slots.append(moved)
        workspaces[target].focusIndex = workspaces[target].slots.count - 1

        // Follow the window: activate the destination (this stashes + parks the
        // source workspace and brings the destination on-screen).
        activateWorkspace(target)
        return true
    }

    /// Jump directly to workspace `index` (0-based), clamped into range. Used by
    /// the CLI and any future "jump to workspace N" binding.
    @discardableResult
    func focusWorkspace(_ index: Int) -> Int {
        let clamped = max(0, min(workspaces.count - 1, index))
        if clamped != activeWorkspace { activateWorkspace(clamped) }
        return activeWorkspace
    }

    /// The heavy lifting of a workspace switch:
    ///   1. stash the live active strip back into its slot,
    ///   2. PARK every window of the outgoing workspace at the shared off-screen
    ///      corner (so only the active workspace is ever visible),
    ///   3. load the destination strip into the live state,
    ///   4. drop a now-vacated trailing empty workspace, and
    ///   5. re-place + focus the destination on-screen.
    private func activateWorkspace(_ index: Int) {
        guard workspaces.indices.contains(index), index != activeWorkspace else { return }
        let outgoing = activeWorkspace

        // 1. Stash the live active strip.
        workspaces[activeWorkspace] = Workspace(slots: slots, viewportX: viewportX, focusIndex: focusIndex)
        // 2. Park the outgoing workspace's windows off-screen.
        parkWindows(workspaces[outgoing].slots)

        // 3. Load the destination strip into the live state.
        activeWorkspace = index
        slots = workspaces[index].slots
        viewportX = workspaces[index].viewportX
        focusIndex = workspaces[index].focusIndex

        // 4. Tidy: a workspace we just left that ended up empty and trailing is
        // removed so the stack never accumulates blank workspaces. This may
        // shift `activeWorkspace` if a workspace before it is removed.
        pruneTrailingEmptyWorkspaces()

        // 5. Re-place + focus the destination on-screen.
        compactStrip()
        if slots.indices.contains(focusIndex) {
            // `focus(index:)` recomputes the viewport for the focus mode,
            // teleports the destination windows back on-screen, and raises the
            // focused one (pulling its app forward like a normal nav).
            focus(index: focusIndex)
        } else {
            // Empty destination: nothing to place or raise.
            viewportX = 0
            focusIndex = 0
            teleport()
            onLayoutChange?()
        }
    }

    /// Park a set of windows at the shared off-screen corner (see `teleport`'s
    /// parking discussion). They collapse into one ~40px sliver instead of a row
    /// of peeking edges, and their `lastCommittedOrigin` is updated so switching
    /// back re-places them (their on-screen target differs from the park point).
    private func parkWindows(_ parked: [Slot]) {
        let p = parkingPoint
        for slot in parked {
            guard slot.window.healthy else { continue }
            if let last = slot.window.lastCommittedOrigin,
               abs(last.x - p.x) < 0.5, abs(last.y - p.y) < 0.5 { continue }
            let err = AXSource.setPoint(slot.window.element, kAXPositionAttribute as String, p)
            if err == .success { slot.window.lastCommittedOrigin = p }
            else { slot.window.healthy = false }
        }
    }

    /// Remove empty workspaces from the END of the stack, keeping at least one
    /// workspace and never removing the active one. Adjusts `activeWorkspace`
    /// for any removed entries that sit before it (none can, since we only trim
    /// the tail past the active index, but the guard keeps it correct if the
    /// active workspace is itself the last and empty — then we stop).
    private func pruneTrailingEmptyWorkspaces() {
        while workspaces.count > 1,
              let lastIdx = workspaces.indices.last,
              lastIdx != activeWorkspace,
              workspaceSlots(lastIdx).isEmpty {
            workspaces.removeLast()
        }
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
            let slot = slots[i]
            // Skip unreachable windows entirely: with no AX write and no
            // readback, stamping `target` into the model would be a lie that
            // strands the column at a width the real window never adopts (the
            // "every column claims the same width but several really differ"
            // desync). Leave the last known real size; the resync size-
            // reconcile refreshes it once the window is reachable again.
            guard slot.window.healthy else { continue }
            // Optimistically update the model so a stale readback still reflects
            // the requested width; the readback below + resync correct it.
            slots[i].width = target
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

    /// Re-bind the strip to a new display geometry at runtime and relay every
    /// window onto it. Called when the strip's display changes resolution/scale,
    /// is rearranged, or the user moves the strip to a different monitor.
    ///
    /// `newScreenFrame` is the new VISIBLE frame (AX top-left coords) the strip
    /// should fill. The vertical band of every slot is re-pinned to the new
    /// display's top (`y = newScreenFrame.origin.y`) and heights are clamped to
    /// the new usable height, so a strip moved from a short laptop panel onto a
    /// tall external (or vice versa) lands correctly instead of off the top/bottom.
    /// Off-viewport parking is recomputed via the (separately set) display frames.
    ///
    /// Returns the number of AX position writes the relay issued. A no-op rebind
    /// (geometry unchanged) costs nothing because `teleport` skips unmoved windows.
    @discardableResult
    func rebindStripDisplay(to newScreenFrame: CGRect) -> Int {
        screenFrame = newScreenFrame
        let topY = newScreenFrame.origin.y
        let maxH = newScreenFrame.height
        func repin(_ s: inout [Slot]) {
            for i in s.indices {
                s[i].y = topY
                if s[i].height > maxH { s[i].height = maxH }
            }
        }
        repin(&slots)
        for i in workspaces.indices { repin(&workspaces[i].slots) }
        // Keep the focused column visible under the new viewport width.
        if slots.indices.contains(focusIndex) {
            viewportX = viewportTarget(for: slots[focusIndex], mode: focusMode,
                                       currentViewportX: viewportX)
        }
        let n = teleport()
        onLayoutChange?()
        return n
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
        /// Index of the active vertical workspace (0-based).
        var activeWorkspace: Int = 0
        /// Total number of vertical workspaces (>= 1).
        var workspaceCount: Int = 1
    }

    var stripState: StripState {
        StripState(
            slots: slots.map { ($0.window.id, $0.window.appName, $0.window.title, $0.canvasX, $0.width, $0.window.healthy) },
            viewportX: viewportX,
            viewportWidth: screenFrame.width,
            focusIndex: focusIndex,
            lastTeleportMs: lastTeleportMs,
            activeWorkspace: activeWorkspace,
            workspaceCount: workspaceCount
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
        // Restore EVERY workspace's windows, not just the active strip, so a
        // window parked in an inactive vertical workspace is also put back.
        for slot in allManagedSlots {
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
        workspaces = [Workspace()]
        activeWorkspace = 0
        focusIndex = 0
        viewportX = 0
        onLayoutChange?()
        return failures
    }
}
