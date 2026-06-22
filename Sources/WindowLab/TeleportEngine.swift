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
            let width = min(m.ax.frame.width, screenFrame.width - gap * 2)
            let height = min(m.ax.frame.height, screenFrame.height)
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
            let target = CGPoint(
                x: screenFrame.origin.x + slot.canvasX - viewportX,
                y: slot.y
            )
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
