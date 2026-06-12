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

        init(element: AXUIElement, pid: pid_t, appName: String, title: String) {
            self.element = element
            self.pid = pid
            self.appName = appName
            self.title = title
        }
    }

    private(set) var slots: [Slot] = []
    private(set) var viewportX: CGFloat = 0
    private(set) var focusIndex: Int = 0

    let screenFrame: CGRect       // visible frame, AX coordinates (top-left origin)
    private let gap: CGFloat = 12

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
                    title: m.ax.title ?? "(untitled)"
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

        // Viewport policy: keep the focused column fully visible,
        // centered when possible.
        let slot = slots[clamped]
        let target = slot.canvasX - (screenFrame.width - slot.width) / 2
        viewportX = max(-gap, target)

        teleport()
        raiseAndFocus(slot.window)
        onLayoutChange?()
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
}
