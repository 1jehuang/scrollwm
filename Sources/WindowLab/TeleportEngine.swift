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
        let element: AXUIElement
        let pid: pid_t
        var appName: String
        var title: String
        var healthy = true
        /// Frame the window had before WE first moved it. Ground truth for restore.
        let originalFrame: CGRect

        init(element: AXUIElement, pid: pid_t, appName: String, title: String, originalFrame: CGRect) {
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
    let gap: CGFloat = 12
    /// Floor for column width so a resize can never collapse a window.
    let minColumnWidth: CGFloat = 200

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

    // Metrics
    private(set) var lastTeleportMs: Double = 0
    private(set) var teleportLatencies: [Double] = []

    var onLayoutChange: (() -> Void)?

    init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
    }

    // MARK: - Adoption

    /// Lay out adopted windows as a strip of columns, preserving sizes.
    func adopt(matched: [MatchedWindow]) {
        var x: CGFloat = 0
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
            return max(-gap, target)

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
                // (with a small gap for breathing room).
                return max(-gap, slotLeft - gap)
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
    func teleport() {
        let start = Clock.nowAbsNs()

        // Commit order: focused first (user is looking at it), then
        // on-screen left-to-right, then off-screen.
        let indices = commitOrder()
        for i in indices {
            let slot = slots[i]
            guard slot.window.healthy else { continue }
            let target = CGPoint(
                x: screenFrame.origin.x + slot.canvasX - viewportX,
                y: slot.y
            )
            let err = AXSource.setPoint(slot.window.element, kAXPositionAttribute as String, target)
            if err != .success {
                slot.window.healthy = false
            }
        }

        lastTeleportMs = Double(Clock.nowAbsNs() &- start) / 1e6
        teleportLatencies.append(lastTeleportMs)
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
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate()
        }
    }

    // MARK: - Introspection for the menu bar

    struct StripState {
        let slots: [(appName: String, title: String, canvasX: CGFloat, width: CGFloat, healthy: Bool)]
        let viewportX: CGFloat
        let viewportWidth: CGFloat
        let focusIndex: Int
        let lastTeleportMs: Double
    }

    var stripState: StripState {
        StripState(
            slots: slots.map { ($0.window.appName, $0.window.title, $0.canvasX, $0.width, $0.window.healthy) },
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
