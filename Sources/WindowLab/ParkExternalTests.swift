import Foundation
import ApplicationServices
import AppKit

// MARK: - parktest (headless): parked slivers never spill onto the external
//
// External-monitor track "parking / peek lane". When a column scrolls off the
// viewport the engine shoves it past the strip-display edge, where macOS clamps
// it to a thin sliver. That sliver must land on the STRIP's own display and
// never peek onto a neighbor monitor. This pins the behavior for the two layouts
// that matter on the user's machine:
//
//   A. The REAL above-and-left external (AX full (-105,-1080,1920x1080)). It does
//      NOT share the strip's vertical band, so BOTH horizontal edges are free and
//      a parked sliver clamps onto the built-in via the pure-axis preference.
//   B. A side-by-side rearrangement (external to the RIGHT, sharing the band).
//      Now the right edge is blocked, so parking a right-scrolled column must
//      FLIP to the left edge to keep the sliver off the external.
//
// Fully headless: no real window, no focus theft, no keystroke. Drives the REAL
// production controller against a SimWindowWorld whose off-screen clamp models
// the macOS "keep ~40px on the nearest single display" behavior.

func runHeadlessParkTest() {
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()
    var t = TestCounter()

    // ---- helper: arrange 4 wide columns, scroll so the first parks, return its
    // live frame + the two displays for an overlap check. ----
    func parkFirstColumn(stripFull: CGRect, stripVisible: CGRect, other: CGRect,
                         label: String) -> (parked: CGRect?, strip: CGRect, other: CGRect) {
        let world = Headless.install(displays: [stripFull, other])
        defer { Headless.uninstall(); RestoreStore.clear() }
        let controller = ScrollWMController()
        scrollWMControllerKeepAlive = controller
        controller.debugRebindStrip(visible: stripVisible, stripFull: stripFull, others: [other])
        let (pids, _) = Headless.seedWindows(
            world, count: 4, startPID: 7700, within: stripVisible, width: 300, height: 360)
        controller.sandboxPIDs = Set(pids)
        controller.arrange(pidFilter: Set(pids))
        Headless.pump(0.1)
        // Make every column full-width, then focus the LAST so the first scrolls
        // fully off and parks.
        for i in 0..<controller.debugSlotCount {
            controller.focus(index: i); controller.setWidthFraction(1.0); Headless.pump(0.03)
        }
        controller.focus(index: controller.debugSlotCount - 1)
        Headless.pump(0.1)
        let parkedTitle = controller.debugSlotTitles.first ?? ""
        let pf = pids.flatMap { AXSource.windows(forPID: $0) }
            .first { $0.title == parkedTitle }?.frame
        controller.release()
        Headless.pump(0.05)
        return (pf, stripFull, other)
    }

    // =====================================================================
    // Layout A: the REAL above-and-left external.
    // =====================================================================
    do {
        let stripFull = CGRect(x: 0, y: 0, width: 1710, height: 1112)
        let stripVisible = CGRect(x: 0, y: 0, width: 1710, height: 1073)
        let external = CGRect(x: -105, y: -1080, width: 1920, height: 1080)
        let r = parkFirstColumn(stripFull: stripFull, stripVisible: stripVisible,
                                other: external, label: "above-left")
        if let pf = r.parked {
            let onStrip = DisplayGeometry.overlapArea(pf, r.strip)
            let onExt = DisplayGeometry.overlapArea(pf, r.other)
            print("[parktest A] parked \(pf) onStrip=\(Int(onStrip)) onExt=\(Int(onExt))")
            t.check("A parked sliver visible on the built-in strip display", onStrip > 0)
            t.check("A parked sliver did NOT spill onto the above-left external",
                    onExt <= onStrip * 0.05)
        } else {
            t.check("A parked readback available", false)
        }
    }

    // =====================================================================
    // Layout B: external rearranged to the RIGHT (shares the strip's band).
    // The right edge is now blocked, so the parked sliver must flip to the LEFT.
    // =====================================================================
    do {
        let stripFull = CGRect(x: 0, y: 0, width: 1710, height: 1112)
        let stripVisible = CGRect(x: 0, y: 0, width: 1710, height: 1073)
        let external = CGRect(x: 1710, y: 0, width: 1920, height: 1080) // to the RIGHT
        let r = parkFirstColumn(stripFull: stripFull, stripVisible: stripVisible,
                                other: external, label: "right")
        if let pf = r.parked {
            let onStrip = DisplayGeometry.overlapArea(pf, r.strip)
            let onExt = DisplayGeometry.overlapArea(pf, r.other)
            print("[parktest B] parked \(pf) onStrip=\(Int(onStrip)) onExt=\(Int(onExt))")
            t.check("B parked sliver visible on the built-in strip display", onStrip > 0)
            t.check("B parked sliver did NOT spill onto the right external",
                    onExt <= onStrip * 0.05)
            // It specifically landed on the LEFT edge (x < strip center), proving
            // the flip away from the blocked right edge.
            t.check("B parked sliver flipped to the LEFT edge (away from the external)",
                    pf.minX < stripFull.midX)
        } else {
            t.check("B parked readback available", false)
        }
    }

    // =====================================================================
    // Pure policy: computeParkingX edge-blocking for both layouts.
    // =====================================================================
    do {
        let s = CGRect(x: 0, y: 0, width: 1710, height: 1112)
        let aboveLeft = CGRect(x: -105, y: -1080, width: 1920, height: 1080)
        let right = CGRect(x: 1710, y: 0, width: 1920, height: 1080)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)

        // Above-left: neither horizontal edge blocked -> honor preference.
        t.check("policy: above-left external blocks NEITHER side (right honored)",
                TeleportEngine.computeParkingX(stripDisplay: s, others: [aboveLeft],
                    prefer: .right) == s.maxX + 4000)
        // Right neighbor: right blocked -> a right-pref park flips to the left.
        t.check("policy: right external blocks the right edge (park flips left)",
                TeleportEngine.computeParkingX(stripDisplay: s, others: [right],
                    prefer: .right) == s.minX - 4000)
        // Left neighbor: left blocked -> a left-pref park flips to the right.
        t.check("policy: left external blocks the left edge (park flips right)",
                TeleportEngine.computeParkingX(stripDisplay: s, others: [left],
                    prefer: .left) == s.maxX + 4000)
    }

    print("\n[headless-parktest] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}
