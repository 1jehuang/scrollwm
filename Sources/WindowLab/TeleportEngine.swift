import Foundation
import ApplicationServices
import AppKit

/// The teleport core: windows live in columns on a horizontal strip.
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
        /// Managed but TEMPORARILY not an active strip column the engine may
        /// write to: set while the window is in native macOS fullscreen (it owns
        /// its own dedicated Space, so the engine must not fight the OS for its
        /// geometry) and, more generally, while a managed window has diverged to
        /// another native Space. A suspended window is KEPT in the strip (so it
        /// re-attaches in place when it returns) but is skipped by `teleport`,
        /// `reconcileSizes`, and every resize verb, and is excluded from the
        /// active layout (`compactStrip`/`stripContentWidth`/navigation), so it
        /// neither corrupts the window's OS-owned frame nor leaves a phantom gap.
        /// Cleared automatically by the resync once the window is a normal
        /// current-Space window again. Defaults false, so a window never touched
        /// by the Space/fullscreen logic behaves exactly as before.
        var suspended = false
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

    /// Width reserved at the LEFT and RIGHT screen edges for the "peek lane".
    /// When a neighbor column scrolls off the viewport it is parked off that
    /// side, where macOS clamps it to a ~40px sliver pinned at the very edge.
    /// Reserving this inset for on-screen content guarantees a column never
    /// sits on top of (and hides) that peeking sliver, so you always see a
    /// slice of the off-screen neighbor as a navigation hint - the focused
    /// content sits in the middle with the left neighbor peeking from the left
    /// and the right neighbor peeking from the right.
    ///
    /// The usable CONTENT region is the screen inset by `peekInset` on each
    /// side; all width/viewport/parking math reads `contentWidth`/
    /// `contentOriginX` instead of the raw screen frame. Defaults to 0 in the
    /// bare engine (the old edge-to-edge behavior, so unit tests are
    /// unaffected); the production controller sets it from config
    /// (`layout.peekInset`, default 48 ≈ the macOS clamp sliver + a little
    /// breathing room).
    var peekInset: CGFloat = 0

    /// Left edge (AX global x) of the usable content region: the screen's
    /// origin shifted right by the left peek lane.
    var contentOriginX: CGFloat { screenFrame.origin.x + peekInset }

    /// Usable content width: the screen width minus a peek lane on each side.
    /// Floored at `minColumnWidth` so an absurd inset can never collapse it to
    /// nothing. With `peekInset == 0` this is exactly `screenFrame.width`.
    var contentWidth: CGFloat { max(minColumnWidth, screenFrame.width - 2 * peekInset) }

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

    /// Target width (as a fraction of the usable strip width) that a NEWLY
    /// opened window is resized to on adoption, so native apps land at a tidy
    /// column instead of whatever (often oversized) frame they opened with.
    /// `nil` preserves the window's native size (the old behavior). Config-driven
    /// (`layout.spawnWidth`). Apps that enforce a larger minimum still win (we
    /// read back and store the real, clamped frame), so the layout never
    /// diverges from reality; the request is best-effort.
    var spawnWidthFraction: CGFloat?

    /// When true, every adopted window is stretched to FILL the usable strip
    /// height (top pinned to `screenFrame.origin.y`, height = `screenFrame.height`),
    /// PaperWM-style, instead of keeping whatever (often short) frame it opened
    /// with. Apps that enforce a larger MINIMUM height still win (we read back
    /// and store the real, clamped frame), so the layout never diverges from
    /// reality; the request is best-effort. Config-driven (`layout.fillHeight`).
    /// Defaults to false in the bare engine so unit tests see the old behavior;
    /// the production controller sets it from config (which defaults true).
    var fillHeight: Bool = false

    // Metrics
    private(set) var lastTeleportMs: Double = 0
    private(set) var teleportLatencies: [Double] = []
    /// Cumulative count of AX position writes actually issued (no-op commits
    /// are skipped). Lets tests assert that a layout change only moved the
    /// windows that truly needed to move.
    private(set) var totalCommits: Int = 0

    var onLayoutChange: (() -> Void)?

    /// Headless test seam: fire `onLayoutChange` exactly as a background poll /
    /// resize reconcile would, without mutating any slot. Used to verify the
    /// menu bar refreshes on a change from a NON-active strip.
    func debugFireLayoutChange() { onLayoutChange?() }

    init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
    }

    // MARK: - Adoption

    /// Restrict adoption candidates to the windows that belong on the strip's
    /// display under the active `adoptScope`. PURE policy lives in
    /// `AdoptionScope`; this is the thin glue that feeds it the engine's own
    /// display geometry (`stripDisplayFrame`/`otherDisplayFrames`). Used by both
    /// the initial arrange path and the live resync/fast-adopt paths so the rule
    /// is applied identically everywhere.
    ///
    /// `frame(_:)` projects each candidate to its AX frame (top-left global).
    /// Returns the kept candidates in their original order.
    func filterByAdoptScope<T>(_ candidates: [T], frame: (T) -> CGRect) -> [T] {
        guard adoptScope != .allDisplays else { return candidates }
        let strip = stripDisplayFrame ?? screenFrame
        let kept = AdoptionScope.filter(
            frames: candidates.map(frame),
            stripDisplay: strip,
            others: otherDisplayFrames,
            scope: adoptScope
        )
        let keep = Set(kept)
        return candidates.indices.filter { keep.contains($0) }.map { candidates[$0] }
    }

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
        // Snap every adopted column to the configured spawn width (e.g. 50%) so
        // "Arrange Windows into Strip" lands the EXISTING windows at a tidy
        // column just like a freshly opened one - the recurring "arrange did not
        // resize my windows to the spawn width" complaint. No-op when no spawn
        // width is configured; the read-back keeps the model honest if an app
        // clamps to a larger minimum. Mirrors the lifecycle-monitor insert flow
        // (`applySpawnWidth` then `applyFillHeight`).
        for i in slots.indices { applySpawnWidth(toSlotAt: i) }
        // Stretch every column to fill the usable height (PaperWM-style) when
        // enabled. No-op otherwise; clamps are reconciled against the live AX
        // frame inside `applyFillHeight`.
        for i in slots.indices { applyFillHeight(toSlotAt: i) }
        // Spawn-width resizes change column widths, so re-pack the canvas
        // before committing positions (the inline `x += width + gap` above used
        // the native widths).
        compactStrip()
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
        viewportX = clampViewportX(viewportTarget(for: slot, mode: focusMode, currentViewportX: viewportX))

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
        viewportX = clampViewportX(viewportTarget(for: slot, mode: focusMode, currentViewportX: viewportX))
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
        if delta < 0 {
            // Going UP: clamp an overshoot to the topmost workspace rather than
            // either trapping or no-op'ing. From ws0 this is still a no-op (the
            // clamp lands on the current workspace), preserving "up at the top
            // does nothing"; from a lower workspace a big jump lands on ws0.
            let target = max(0, activeWorkspace + delta)
            if target != activeWorkspace { activateWorkspace(target) }
            return activeWorkspace
        }
        // Going DOWN: clamp an overshoot to AT MOST one past the last existing
        // workspace. niri-style dynamic workspaces keep only a single trailing
        // empty one, so `down by 3` from the last real workspace lands on that
        // one new workspace, never on an out-of-range index (the old code
        // appended a single workspace but still indexed at `activeWorkspace +
        // delta`, trapping with "Index out of range" for any delta >= 2).
        let target = min(activeWorkspace + delta, workspaces.count)
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
        // Clamp a downward overshoot to at most one past the last workspace, for
        // the same reason as `switchWorkspace`: append a single trailing empty
        // workspace and target THAT, never an out-of-range index (`by: 2` used
        // to append one workspace but index at `activeWorkspace + 2`, trapping).
        let target = min(activeWorkspace + delta, workspaces.count)
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

        // 4. Tidy: any workspace we just emptied (the source we moved the last
        // window out of, wherever it sits) collapses so the stack never
        // accumulates blank workspaces. May shift `activeWorkspace` left if a
        // removed workspace preceded it.
        pruneEmptyWorkspaces()

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

    /// Park a set of windows off the right side edge (see `teleport`'s parking
    /// discussion). Each keeps its natural vertical band and only slides off the
    /// side, so they collapse into one tall full-height sliver at that edge
    /// instead of a row of peeking corners, and their `lastCommittedOrigin` is
    /// updated so switching back re-places them (their on-screen target differs
    /// from the park point).
    private func parkWindows(_ parked: [Slot]) {
        let px = parkingX(prefer: .right)
        for slot in parked {
            guard slot.window.healthy else { continue }
            let p = CGPoint(x: px, y: slot.y)
            if let last = slot.window.lastCommittedOrigin,
               abs(last.x - p.x) < 0.5, abs(last.y - p.y) < 0.5 { continue }
            let err = AXSource.setPoint(slot.window.element, kAXPositionAttribute as String, p)
            if err == .success { slot.window.lastCommittedOrigin = p }
            else { slot.window.healthy = false }
        }
    }

    /// Remove EVERY empty workspace except the active one, keeping at least one
    /// workspace total. niri-style dynamic workspaces never accumulate blank
    /// ones: a workspace emptied by moving/closing its last window collapses
    /// immediately, whether it sits at the tail, between two populated
    /// workspaces, or above the active one. `activeWorkspace` is shifted down by
    /// the number of removed workspaces that preceded it so it keeps pointing at
    /// the same live strip.
    ///
    /// The active workspace is always kept even when empty: that is the niri
    /// "scratch" workspace you switch DOWN into to start populating, and it is
    /// the one whose live `slots` are authoritative — dropping it would strand
    /// the active index. (It collapses later, once you switch away from it, when
    /// THIS prune runs for the new active workspace.)
    ///
    /// Was previously `pruneTrailingEmptyWorkspaces`, which only trimmed the
    /// tail; that left a phantom empty workspace above/between content after
    /// `moveFocusedToWorkspace` emptied a non-tail source (found by the
    /// state-space explorer: `moveWsDown` from a single-window strip, 1 op).
    private func pruneEmptyWorkspaces() {
        guard workspaces.count > 1 else { return }
        var kept: [Workspace] = []
        var newActive = activeWorkspace
        for (i, _) in workspaces.enumerated() {
            let isActive = (i == activeWorkspace)
            let isEmpty = workspaceSlots(i).isEmpty
            if isEmpty && !isActive {
                // Dropping a workspace before the active one shifts it left.
                if i < activeWorkspace { newActive -= 1 }
                continue
            }
            kept.append(workspaces[i])
        }
        workspaces = kept
        activeWorkspace = max(0, min(newActive, workspaces.count - 1))
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
            // Suspended (fullscreen / off-Space) windows are OS-owned; skip them
            // so "Show All Windows" never resizes a window we do not control.
            if slot.window.suspended { continue }
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

    /// Total width the packed strip occupies on the canvas: the right edge of
    /// the last column plus the trailing `gap` margin (symmetric with the
    /// leading margin `compactStrip` opens with). Zero for an empty strip.
    ///
    /// Suspended columns (fullscreen / off-Space) reserve no canvas band (see
    /// `compactStrip`), so the extent is measured from the last NON-suspended
    /// column; a trailing suspended slot does not inflate the scrollable width.
    var stripContentWidth: CGFloat {
        guard let last = slots.last(where: { !$0.window.suspended }) else { return 0 }
        return last.canvasX + last.width + gap
    }

    /// Largest meaningful viewport offset: scrolling past this would reveal dead
    /// space to the RIGHT of the strip's trailing margin. When the whole strip
    /// fits within the viewport this is 0 (pin to the left). This is what lets
    /// the viewport "pull in" after a column is closed or shrunk so a window
    /// removal never strands the viewport over empty space - exactly the
    /// "closing a window should sometimes scroll the viewport so it fills the
    /// gap" behavior (PaperWM/niri never let you scroll past the strip's end).
    var maxViewportX: CGFloat { max(0, stripContentWidth - contentWidth) }

    /// Clamp a viewport offset into the legal `[0, maxViewportX]` range so the
    /// strip never scrolls before its leading margin nor past its trailing one.
    /// Applied wherever the live viewport is (re)committed (`focus`,
    /// `refitViewportToFocused`, `rebindStripDisplay`) - NOT inside the pure
    /// `viewportTarget` (which is unit-tested against synthetic off-strip slots
    /// whose extent is not reflected in `slots`).
    func clampViewportX(_ x: CGFloat) -> CGFloat { max(0, min(x, maxViewportX)) }

    /// Compute where the viewport's left edge should sit so that `slot` is
    /// shown according to `mode`. Pure function (no side effects) so it can be
    /// unit-tested directly.
    ///
    /// - centered: place the column in the middle of the viewport.
    /// - fit: keep the current viewport unless the column is partly/fully
    ///        offscreen, then scroll the minimum amount to fully reveal it,
    ///        aligning to whichever edge it overflowed.
    func viewportTarget(for slot: Slot, mode: FocusMode, currentViewportX: CGFloat) -> CGFloat {
        // The viewport is the usable CONTENT region (screen minus a peek lane on
        // each side), so all comparisons use `contentWidth`, not the raw screen
        // width. With `peekInset == 0` this is identical to the old behavior.
        let V = contentWidth
        switch mode {
        case .centered:
            let target = slot.canvasX - (V - slot.width) / 2
            // viewportX 0 maps the strip's leading `gap` margin to the content
            // region's left edge, so 0 is the leftmost meaningful scroll position.
            return max(0, target)

        case .fit:
            let viewLeft = currentViewportX
            let viewRight = currentViewportX + V
            let slotLeft = slot.canvasX
            let slotRight = slot.canvasX + slot.width

            if slot.width >= V {
                // Wider than the content region: align its left edge (with a
                // small gap) so the start of the window is visible. Clamp at 0
                // like the other branches: viewportX 0 already maps the strip's
                // leading `gap` margin to the content region's left edge, so 0 is
                // the leftmost meaningful scroll position and a negative offset
                // would push the strip's start off the left of the content area.
                return max(0, slotLeft - gap)
            }
            if slotLeft < viewLeft {
                // Overflows left: bring its left edge to the viewport's left
                // (with a small gap for breathing room). viewportX 0 already
                // leaves the strip's leading `gap` margin, so 0 is the floor.
                return max(0, slotLeft - gap)
            }
            if slotRight > viewRight {
                // Overflows right: bring its right edge to the viewport's right.
                return slotRight - V + gap
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
            // Suspended windows (native fullscreen, or diverged to another Space)
            // are OS-owned; never write their position or we fight the OS for a
            // window we do not control.
            if slot.window.suspended { continue }
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
    /// least partly within the usable CONTENT region (the viewport inset by a
    /// peek lane on each side), that is its natural strip position - mapped via
    /// `contentOriginX` so on-screen content NEVER covers the side peek lanes.
    /// If it is fully outside the content region, park it on the SIDE it
    /// scrolled off: columns past the left edge collapse to a left-edge sliver,
    /// columns past the right edge to a right-edge sliver (see `teleport` and
    /// `parkingX(prefer:)`). The window keeps its natural vertical band
    /// (`slot.y`) and only slides off the side, so the macOS clamp leaves a thin
    /// FULL-HEIGHT peek at that edge where the content went, inside the reserved
    /// lane (uncovered by on-screen columns), instead of a small nub in a corner.
    func onScreenTarget(for slot: Slot) -> CGPoint {
        let left = slot.canvasX - viewportX           // content-relative left
        let right = left + slot.width
        if right <= 0 {
            // Scrolled fully off the LEFT of the content region: park left.
            return CGPoint(x: parkingX(prefer: .left), y: slot.y)
        }
        if left >= contentWidth {
            // Scrolled fully off the RIGHT of the content region: park right.
            return CGPoint(x: parkingX(prefer: .right), y: slot.y)
        }
        return CGPoint(x: contentOriginX + slot.canvasX - viewportX, y: slot.y)
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

    /// Which displays' windows the strip is allowed to adopt. Pushed from
    /// `config.layout.adoptScope` (single source of truth), so both the initial
    /// arrange and the live resync/fast-adopt paths apply the SAME rule, and a
    /// `reloadConfig` updates it for the running monitor. See `AdoptionScope`.
    var adoptScope: AdoptionScope.Scope = .stripDisplay

    /// Optional Space-safety predicate consulted in `raiseAndFocus` before
    /// activating a window's app: returns true when activating is safe (the
    /// window's app has at least one window on the Space the user is currently
    /// viewing), false when it would teleport the user to another Space. The
    /// controller installs it from the live WindowServer on-screen list; nil (the
    /// default) means "assume safe" so bare-engine tests and the common
    /// single-Space case behave exactly as before. See `raiseAndFocus`.
    var activationKeepsCurrentSpace: ((ManagedWindowRef) -> Bool)?

    /// Which horizontal edge a parked window should slide toward. Mirrors the
    /// side a column scrolled off, so the nub lands where the content went.
    enum ParkSide { case left, right }

    /// Which strip-display edges currently have at least one healthy, non-suspended
    /// column PARKED off that side (scrolled fully past the usable content region).
    /// macOS forces a ~`peekInset`-wide sliver of every parked window to stay
    /// visible at the strip-display edge (it refuses to move a window fully off
    /// screen); that sliver is what users misread as a stray/broken window. The
    /// controller paints an opaque "edge scrim" over exactly these sides to cover
    /// the sliver, so a parked column is never visible. Pure (reads only the model)
    /// so the policy is unit-testable without AX.
    ///
    /// A side counts as parked only when a column is fully past that edge of the
    /// CONTENT region (the same boundary `onScreenTarget`/`commitOrder` use), so a
    /// column merely peeking into the viewport never triggers a scrim. Suspended
    /// (fullscreen / off-Space) columns are OS-owned and never parked by us, so
    /// they are ignored.
    func parkedEdges() -> (left: Bool, right: Bool) {
        var left = false, right = false
        for slot in slots {
            guard slot.window.healthy, !slot.window.suspended else { continue }
            let l = slot.canvasX - viewportX
            let r = l + slot.width
            if r <= 0 { left = true }
            else if l >= contentWidth { right = true }
            if left && right { break }
        }
        return (left, right)
    }

    /// AX-coordinate rects (top-left origin) of the opaque edge scrims that should
    /// be shown to cover parked-column slivers, given the live strip-display frame.
    /// Returns 0, 1, or 2 rects (left edge, right edge). Each scrim is a thin
    /// full-display-height band pinned to the strip display's left/right edge,
    /// exactly as wide as the reserved peek lane (`peekInset`) - precisely the
    /// region macOS keeps a parked window's sliver in, and which on-screen columns
    /// (laid out INSIDE the content region) never occupy. So the scrim covers the
    /// sliver without ever clipping real window content.
    ///
    /// Empty when nothing is parked OR when the peek lane is too narrow to fully
    /// contain the ~40px macOS clamp sliver (`peekInset < minSliverCover`,
    /// including the `peekInset == 0` "edge-to-edge, no lane" opt-out): widening
    /// the scrim past the lane would paint over a real on-screen column, so we
    /// rather leave the (now user-accepted) sliver than clip content. Pure; the
    /// controller flips these to AppKit frames and positions its scrim windows.
    func edgeScrimRects(stripDisplay: CGRect) -> [CGRect] {
        // Need a reserved lane at least as wide as the sliver to cover it without
        // overlapping content. With no/with-too-thin a lane, do not scrim.
        guard peekInset >= TeleportEngine.minSliverCover else { return [] }
        let edges = parkedEdges()
        guard edges.left || edges.right else { return [] }
        let w = peekInset
        var rects: [CGRect] = []
        if edges.left {
            rects.append(CGRect(x: stripDisplay.minX, y: stripDisplay.minY,
                                width: w, height: stripDisplay.height))
        }
        if edges.right {
            rects.append(CGRect(x: stripDisplay.maxX - w, y: stripDisplay.minY,
                                width: w, height: stripDisplay.height))
        }
        return rects
    }

    /// Minimum peek-lane width that can fully contain the ~40px sliver macOS keeps
    /// visible for an off-screen window (plus a few px of slop). A scrim is only
    /// drawn when `peekInset >= minSliverCover`, so it never has to extend past the
    /// reserved lane (and thus over real content) to hide the sliver.
    static let minSliverCover: CGFloat = 44

    /// Off-screen X a window scrolled off `side` is shoved to. A parked window
    /// keeps its natural vertical band (its slot `y`) and only slides sideways,
    /// so macOS clamps it into a thin FULL-HEIGHT sliver at one side edge of the
    /// strip display, rather than a corner nub. Every window pushed the same way
    /// shares the same X, so they collapse into a single tall peek at that edge.
    /// Display-aware: if the requested side abuts a neighbor monitor we flip to
    /// the opposite (free) edge so the sliver stays on the strip's own display
    /// and never peeks onto the neighbor (see `computeParkingX`).
    func parkingX(prefer side: ParkSide) -> CGFloat {
        TeleportEngine.computeParkingX(
            stripDisplay: stripDisplayFrame ?? screenFrame,
            others: otherDisplayFrames,
            prefer: side
        )
    }

    /// Debug/back-compat: the parking origin for a window pinned to the strip's
    /// top, on the right edge. Used by the menu-bar/displaytest introspection;
    /// production parking pairs `parkingX` with each slot's own `y`.
    var parkingPoint: CGPoint {
        CGPoint(x: parkingX(prefer: .right), y: screenFrame.origin.y)
    }

    /// Pure parking-edge policy (no side effects, unit-tested).
    ///
    /// Picks the side edge of `stripDisplay` to shove parked windows past, so the
    /// unavoidable ~40px macOS clamp sliver lands on `stripDisplay` along an edge
    /// that has NO adjacent display. Because the window keeps its full height and
    /// only slides horizontally, the sliver is a tall peek at the very left or
    /// right edge of the strip display (not a corner).
    ///
    /// Honor the caller's `prefer`red side (the side the column scrolled off)
    /// UNLESS that edge abuts a neighbor monitor sharing the strip's vertical
    /// band, in which case flip to the opposite edge if THAT one is free; if both
    /// horizontal sides are blocked, fall back to the preferred side (a sliver on
    /// a busy edge is then unavoidable). Vertical neighbors are irrelevant: we
    /// never push the window off the top or bottom.
    static func computeParkingX(stripDisplay s: CGRect,
                                others: [CGRect],
                                prefer side: ParkSide = .right,
                                margin: CGFloat = 4000) -> CGFloat {
        // A neighbor only "blocks" a side if it actually abuts that edge AND
        // overlaps the strip's vertical band (a display offset above/below does
        // not catch a full-height sliver pushed straight out the side).
        func vOverlap(_ d: CGRect) -> Bool { d.minY < s.maxY && d.maxY > s.minY }
        let leftBlocked  = others.contains { $0.maxX <= s.minX + 1 && vOverlap($0) }
        let rightBlocked = others.contains { $0.minX >= s.maxX - 1 && vOverlap($0) }

        // Honor the preferred side when it is free; otherwise flip to the
        // opposite edge if that one is free; otherwise keep the preferred side
        // (both blocked -> unavoidable, so respect the caller's intent).
        let goRight: Bool
        switch side {
        case .right: goRight = !rightBlocked ? true  : (!leftBlocked ? false : true)
        case .left:  goRight = !leftBlocked  ? false : (!rightBlocked ? true : false)
        }
        return goRight ? s.maxX + margin : s.minX - margin
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
        let oldHeight = screenFrame.height
        screenFrame = newScreenFrame
        let topY = newScreenFrame.origin.y
        let maxH = newScreenFrame.height
        func repin(_ s: inout [Slot]) {
            for i in s.indices {
                s[i].y = topY
                // Clamp an over-tall window down so it fits the new display.
                // In fill mode the real resize to the FULL new height is issued
                // below via `applyFillHeight(force:)`; we deliberately do NOT
                // pre-stamp `maxH` here, or that pass would see the model as
                // "already full" and skip the cross-process resize, stranding
                // the real window at its old-resolution height.
                if s[i].height > maxH { s[i].height = maxH }
            }
        }
        repin(&slots)
        for i in workspaces.indices { repin(&workspaces[i].slots) }
        // In fill mode, push the new full height to the REAL windows. The forced
        // resize is needed ONLY when the usable HEIGHT actually changed: `repin`
        // may have clamped a window's model height to the new (shorter) display,
        // so the normal early-return (`abs(slot.height - target) <= 1`) would
        // wrongly skip the cross-process resize. Reconciled against the real
        // frame so an app that clamps height never desyncs the model.
        //
        // When the height is UNCHANGED (a redundant settled display change -
        // macOS fires `didChangeScreenParameters` repeatedly on multi-monitor /
        // ProMotion setups, or the strip is re-bound to the same geometry), the
        // windows are already at the right height, so we must NOT force: forcing
        // would issue a storm of no-op `setSize` calls the user perceives as
        // every window flickering/resizing ("glitching out"). The non-forced
        // path still re-fills any window that genuinely differs (`abs > 1`), so
        // dropping force here never leaves a window mis-sized.
        let heightChanged = abs(newScreenFrame.height - oldHeight) > 1
        if fillHeight {
            for i in slots.indices { applyFillHeight(toSlotAt: i, force: heightChanged) }
            // Inactive workspaces only: `workspaces[activeWorkspace]` is a STALE
            // placeholder (the live active slots are `slots`, handled above), so
            // resizing it would touch out-of-date / closed elements.
            for w in workspaces.indices where w != activeWorkspace {
                for i in workspaces[w].slots.indices {
                    fillSlotToUsableHeight(&workspaces[w].slots[i], force: heightChanged)
                }
            }
        }
        // Keep the focused column visible under the new viewport width.
        if slots.indices.contains(focusIndex) {
            viewportX = clampViewportX(viewportTarget(for: slots[focusIndex], mode: focusMode,
                                       currentViewportX: viewportX))
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
            // On-screen == at least partly within the usable content region
            // (matches `onScreenTarget`'s parking boundary, `contentWidth`).
            if right > 0 && left < contentWidth {
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
        // is not enough). Finally activate the owning app. All routed through
        // AXSource so the headless backend can model focus with no real effect.
        AXSource.raise(window.element)
        AXSource.setBool(window.element, kAXMainAttribute as String, true)
        AXSource.setBool(window.element, kAXFocusedAttribute as String, true)
        // Space-safety guard: NEVER activate an app none of whose windows are on
        // the Space the user is currently viewing. macOS switches the user to a
        // window's Space when its app is activated, so activating a stranded
        // column (a window the user dragged to another Desktop, or one left on a
        // different Space) would yank the user away from the Space they are on -
        // the single most user-hostile Spaces behavior. `activationKeepsCurrentSpace`
        // is set by the controller from the live on-screen list; nil (the default
        // for bare-engine unit/fuzz tests and the common single-Space case) means
        // "assume safe", so existing behavior is byte-identical. The raise / main /
        // focused writes above are harmless AX no-ops for an off-Space window (they
        // never change the active Space); only `activateApp` teleports, so only it
        // is gated.
        if activationKeepsCurrentSpace?(window) ?? true {
            AXSource.activateApp(pid: window.pid)
        }
    }

    // MARK: - Introspection for the menu bar

    struct StripState {
        /// One vertical workspace's horizontal strip, in the same shape the
        /// menu-bar mini-map already consumes for the active strip. Lets the
        /// icon draw EVERY workspace (stacked) rather than only the active one.
        struct WorkspaceStrip {
            let slots: [(id: UInt64, appName: String, title: String, canvasX: CGFloat, width: CGFloat, healthy: Bool)]
            let viewportX: CGFloat
            let viewportWidth: CGFloat
            let focusIndex: Int
            let isActive: Bool
        }

        let slots: [(id: UInt64, appName: String, title: String, canvasX: CGFloat, width: CGFloat, healthy: Bool)]
        let viewportX: CGFloat
        let viewportWidth: CGFloat
        let focusIndex: Int
        let lastTeleportMs: Double
        /// Index of the active vertical workspace (0-based).
        var activeWorkspace: Int = 0
        /// Total number of vertical workspaces (>= 1).
        var workspaceCount: Int = 1
        /// EVERY workspace's strip, top-to-bottom (index 0 = topmost). The active
        /// one is also exposed flat above (`slots`/`viewportX`/...) so existing
        /// callers are unchanged; this is the full stack for the "show all
        /// workspaces" overview. Empty by default so synthetic test states keep
        /// compiling without populating it.
        var workspaces: [WorkspaceStrip] = []
    }

    var stripState: StripState {
        // Build the full vertical stack so the menu-bar overview can draw every
        // workspace. Inactive workspaces read their stashed geometry; the active
        // one reads the live `slots`/`viewportX`/`focusIndex`.
        var stack: [StripState.WorkspaceStrip] = []
        for i in 0..<workspaceCount {
            let s = workspaceSlots(i)
            let vx = (i == activeWorkspace) ? viewportX : workspaces[i].viewportX
            let fi = (i == activeWorkspace) ? focusIndex : workspaces[i].focusIndex
            stack.append(.init(
                slots: s.map { ($0.window.id, $0.window.appName, $0.window.title, $0.canvasX, $0.width, $0.window.healthy) },
                viewportX: vx,
                viewportWidth: contentWidth,
                focusIndex: fi,
                isActive: i == activeWorkspace
            ))
        }
        return StripState(
            slots: slots.map { ($0.window.id, $0.window.appName, $0.window.title, $0.canvasX, $0.width, $0.window.healthy) },
            viewportX: viewportX,
            // Report the usable CONTENT width (screen minus the peek lanes), so
            // the menu-bar mini-map's "in viewport" span matches what the strip
            // actually shows. With `peekInset == 0` this is `screenFrame.width`.
            viewportWidth: contentWidth,
            focusIndex: focusIndex,
            lastTeleportMs: lastTeleportMs,
            activeWorkspace: activeWorkspace,
            workspaceCount: workspaceCount,
            workspaces: stack
        )
    }

    var commitAllCount: Int { slots.count }

    /// Read-only structural snapshot across ALL vertical workspaces, used by the
    /// state-space explorer to build a canonical, hashable signature of the
    /// engine's logical state (independent of geometry). `stripState` only
    /// exposes the ACTIVE workspace; this exposes the whole stack so the
    /// explorer can dedup states and detect divergence per workspace. Window
    /// identity is the stable `ManagedWindowRef.id` (never the array index).
    /// Pure read; no side effects.
    struct WorkspacesSnapshot: Hashable {
        /// Per-workspace ordered window ids + that workspace's own focusIndex.
        let workspaces: [(ids: [UInt64], focusIndex: Int)]
        let activeWorkspace: Int

        static func == (l: WorkspacesSnapshot, r: WorkspacesSnapshot) -> Bool {
            l.activeWorkspace == r.activeWorkspace
                && l.workspaces.count == r.workspaces.count
                && zip(l.workspaces, r.workspaces).allSatisfy {
                    $0.ids == $1.ids && $0.focusIndex == $1.focusIndex
                }
        }
        func hash(into h: inout Hasher) {
            h.combine(activeWorkspace)
            for w in workspaces { h.combine(w.ids); h.combine(w.focusIndex) }
        }
    }

    var workspacesSnapshot: WorkspacesSnapshot {
        var out: [(ids: [UInt64], focusIndex: Int)] = []
        for i in 0..<workspaceCount {
            let s = workspaceSlots(i)
            let fi = (i == activeWorkspace)
                ? focusIndex
                : workspaces[i].focusIndex
            out.append((ids: s.map { $0.window.id }, focusIndex: fi))
        }
        return WorkspacesSnapshot(workspaces: out, activeWorkspace: activeWorkspace)
    }

    func commitAll() {
        teleport()
    }

    func teleportStats() -> LatencyStats {
        LatencyStats(label: "teleport.full", samples: teleportLatencies)
    }

    /// PURE restore-target policy: where a window with pre-adoption frame
    /// `original` should be put back, clamped onto a currently-available display.
    ///
    /// A window's `originalFrame` was captured before adoption and can point at a
    /// monitor that has since been UNPLUGGED — restoring it verbatim would strand
    /// the window fully off-screen. `DisplayGeometry.ensureVisible` returns the
    /// frame UNCHANGED when it is still mostly visible (the common case — no
    /// perturbation), and only when it is not does it pull/shrink the window onto
    /// the best available display. No side effects; unit-tested directly.
    static func restoreFrame(original: CGRect, displays: [CGRect]) -> CGRect {
        DisplayGeometry.ensureVisible(original, displays: displays)
    }

    /// PURE intentional-release placement: unlike crash recovery, a user-triggered
    /// Release should not scatter windows back to old pre-ScrollWM positions. Put
    /// every released window in a simple readable grid on the strip display so the
    /// desktop is immediately usable after management stops.
    static func releaseFrames(count: Int, display: CGRect, gap: CGFloat = 16) -> [CGRect] {
        guard count > 0, display.width > 0, display.height > 0 else { return [] }
        let cols = max(1, Int(ceil(sqrt(Double(count)))))
        let rows = max(1, Int(ceil(Double(count) / Double(cols))))
        let usableW = max(1, display.width - gap * CGFloat(cols + 1))
        let usableH = max(1, display.height - gap * CGFloat(rows + 1))
        let cellW = usableW / CGFloat(cols)
        let cellH = usableH / CGFloat(rows)
        return (0..<count).map { i in
            let r = i / cols
            let c = i % cols
            return CGRect(x: display.minX + gap + CGFloat(c) * (cellW + gap),
                          y: display.minY + gap + CGFloat(r) * (cellH + gap),
                          width: cellW,
                          height: cellH)
        }
    }

    /// PURE restore plan for crash recovery / legacy display-safety tests: every
    /// managed window paired with its saved pre-adoption frame, clamped to the
    /// displays available RIGHT NOW.
    func restorePlan(displays: [CGRect]) -> [(window: ManagedWindowRef, target: CGRect)] {
        allManagedSlots.map { slot in
            (slot.window, Self.restoreFrame(original: slot.window.originalFrame, displays: displays))
        }
    }

    /// PURE plan consumed by intentional `releaseAll`: every managed window gets a
    /// readable, non-overlapping frame on the strip display (or the first available
    /// display if that display disappeared).
    func releasePlan(displays: [CGRect]) -> [(window: ManagedWindowRef, target: CGRect)] {
        let managed = allManagedSlots.map { $0.window }
        guard !managed.isEmpty else { return [] }
        let preferred = stripDisplayFrame ?? screenFrame
        let targetDisplay = displays.first { DisplayGeometry.overlapArea($0, preferred) > 0 }
            ?? displays.first
            ?? preferred
        let frames = Self.releaseFrames(count: managed.count, display: targetDisplay)
        return zip(managed, frames).map { ($0.0, $0.1) }
    }

    /// Place every managed window in a readable on-screen grid and stop managing
    /// it. Returns the number of failures.
    ///
    /// Display-safe: each release target is chosen from a currently-available
    /// display, so unplugging a monitor before Release can never leave a window
    /// stranded off-screen.
    ///
    /// Failures are determined by READBACK, not AX error codes: some windows
    /// (e.g. fixed-size ones) return errors for no-op resizes while ending up
    /// exactly where they belong.
    ///
    /// `displays` defaults to the live `NSScreen` layout; tests inject a fixed
    /// set (e.g. simulating an unplugged monitor) to exercise the clamp.
    @discardableResult
    func releaseAll(displays: [CGRect]? = nil) -> Int {
        let displays = displays ?? DisplayGeometry.currentVisibleAXDisplays()
        var failures = 0
        // Release EVERY workspace's windows, not just the active strip, so a
        // window parked in an inactive vertical workspace is also put back in a
        // usable on-screen position.
        for (w, target) in releasePlan(displays: displays) {
            _ = AXSource.setPoint(w.element, kAXPositionAttribute as String, target.origin)
            _ = AXSource.setSize(w.element, kAXSizeAttribute as String, target.size)

            // Verify by reading back the actual frame.
            if let pos = AXSource.copyPoint(w.element, kAXPositionAttribute as String),
               let size = AXSource.copySize(w.element, kAXSizeAttribute as String) {
                let ok = abs(pos.x - target.origin.x) <= 2
                    && abs(pos.y - target.origin.y) <= 2
                    && abs(size.width - target.width) <= 2
                    && abs(size.height - target.height) <= 2
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
