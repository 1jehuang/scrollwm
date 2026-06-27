import Foundation
import AppKit
import ApplicationServices

/// Live, NON-destructive visual probe for the floating per-display indicator
/// ([md-indicator]). Spawns a real `FloatingStripIndicator` panel on every
/// connected display that has NO system menu bar (i.e. the external monitors),
/// shows a synthetic strip mini-map in it for a few seconds so you can SEE the
/// indicator on the external screen, then tears everything down. It NEVER
/// touches, enumerates, or moves any of your real windows - it only draws its
/// own floating panels.
///
/// Usage: `WindowLab indicatorprobe [seconds]`  (default 6s)
func runIndicatorProbe(seconds: Double) {
    guard AXSource.isTrusted else {
        print("indicatorprobe: needs Accessibility permission. Grant it and re-run.")
        exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let screens = NSScreen.screens
    guard screens.count > 1 else {
        print("indicatorprobe: only one display connected; the floating indicator "
              + "is only shown on monitors that have no system menu bar. Connect a "
              + "second display and re-run.")
        exit(0)
    }
    let primaryHeight = (screens.first { $0.frame.origin == .zero }
                         ?? NSScreen.main ?? screens[0]).frame.height

    // Build a synthetic 4-window strip state to draw in the indicators, so the
    // mini-map clearly shows columns + a viewport (no real windows involved).
    func syntheticState(viewportWidth: CGFloat) -> TeleportEngine.StripState {
        var x: CGFloat = 12
        var slots: [(id: UInt64, appName: String, title: String, canvasX: CGFloat, width: CGFloat, healthy: Bool)] = []
        for i in 0..<4 {
            slots.append((id: UInt64(i + 1), appName: ["kitty", "Safari", "Code", "Notes"][i],
                          title: "w\(i + 1)", canvasX: x, width: 360, healthy: true))
            x += 372
        }
        return TeleportEngine.StripState(
            slots: slots, viewportX: 0, viewportWidth: viewportWidth,
            focusIndex: 1, lastTeleportMs: 0)
    }

    var indicators: [FloatingStripIndicator] = []
    let inputs = screens.map { s in
        IndicatorPlacement.DisplayInput(
            fullAXFrame: DisplayGeometry.axFrame(appKitFrame: s.frame, primaryHeight: primaryHeight),
            visibleAXFrame: DisplayGeometry.axFrame(appKitFrame: s.visibleFrame, primaryHeight: primaryHeight),
            hasSystemMenuBar: (s.frame.maxY - s.visibleFrame.maxY) > 1,
            isManaging: true,
            id: s.displayID)
    }
    let placements = IndicatorPlacement.placements(
        displays: inputs,
        indicatorSize: CGSize(width: ProductionMenuBar.indicatorWidth,
                              height: ProductionMenuBar.indicatorHeight),
        topInset: ProductionMenuBar.indicatorTopInset)

    guard !placements.isEmpty else {
        print("indicatorprobe: every connected display has a system menu bar "
              + "(\"Displays have separate Spaces\" is ON), so no floating indicator "
              + "is needed - the real status item already shows on each. Nothing to probe.")
        exit(0)
    }

    print("indicatorprobe: showing \(placements.count) floating indicator(s) for "
          + "\(String(format: "%.0f", seconds))s on the menu-bar-less display(s):")
    for (i, p) in placements.enumerated() {
        let ind = FloatingStripIndicator(displayID: p.displayID)
        let vw = inputs.first { $0.id == p.displayID }?.visibleAXFrame.width ?? 1600
        ind.setFrameAX(p.frameAX, primaryHeight: primaryHeight)
        ind.apply(state: syntheticState(viewportWidth: vw), managing: true)
        ind.setActive(i == 0)          // highlight the first as the "active" one
        ind.setVisible(true)
        indicators.append(ind)
        print("  - display id \(p.displayID.map(String.init) ?? "?") at AX \(p.frameAX)")
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        for ind in indicators { ind.close() }
        print("indicatorprobe: done; panels removed.")
        exit(0)
    }
    app.run()
}
