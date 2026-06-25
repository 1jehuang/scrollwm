import Foundation
import AppKit
import QuartzCore

/// Benchmarks the cost of refreshing the menu-bar status item when windows are
/// added/removed, isolating each stage of the production update path:
///
///   engine.onLayoutChange
///     -> ProductionMenuBar.refresh()
///        -> stripView.apply(state:)              [diff + spring retargets + redraw request]
///           -> onDesiredContentWidthChange(w)
///              -> setContentWidth(w)
///                 -> statusItem.length = w + pad [SYSTEM menu-bar relayout]
///
/// The question this answers: is the slow part our `apply()` work, or is it the
/// `NSStatusItem.length` assignment forcing the system to relayout the menu bar?
///
/// Pure-logic: builds synthetic `StripState`s with a growing slot count and
/// feeds them through a REAL `NSStatusItem` hosting the REAL `MenuBarStripView`.
/// No AX, no spawned windows - the system menu-bar relayout is the only "live"
/// cost, which is exactly what we want to measure.
///
/// Run with: `WindowLab statusbench [steps]`  (default 24 add/remove events)
func runStatusItemBench(steps: Int) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // Build a status item that mirrors ProductionMenuBar exactly.
    let hPadding: CGFloat = 4
    let minWidth: CGFloat = 30
    let maxWidth: CGFloat = 220
    let pointsPerScreen: CGFloat = 30

    let stripView = MenuBarStripView(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
    stripView.pointsPerScreen = pointsPerScreen
    stripView.minContentWidth = minWidth
    stripView.maxContentWidth = maxWidth

    var contentWidth: CGFloat = minWidth
    let statusItem = NSStatusBar.system.statusItem(withLength: contentWidth + hPadding)
    statusItem.autosaveName = "ScrollWMStatusBench"
    if let button = statusItem.button {
        button.image = nil
        button.title = ""
        stripView.frame = button.bounds
        stripView.autoresizingMask = [.width, .height]
        button.addSubview(stripView)
    }
    let menu = NSMenu()
    statusItem.menu = menu

    // Recorders for each isolated stage.
    let rApply = LatencyRecorder()       // full stripView.apply() (our work)
    let rLengthChange = LatencyRecorder() // statusItem.length = <new value>
    let rLengthNoop = LatencyRecorder()   // statusItem.length = <same value>
    let rSnapshot = LatencyRecorder()     // building StripState (array map)

    let viewportWidth: CGFloat = 1440
    let columnWidth: CGFloat = 360 // 25% columns -> strip grows with each add

    // Build a StripState with `n` columns laid left-to-right, focus on the last.
    func makeState(_ n: Int) -> TeleportEngine.StripState {
        var slots: [(id: UInt64, appName: String, title: String, canvasX: CGFloat, width: CGFloat, healthy: Bool)] = []
        for i in 0..<n {
            slots.append((
                id: UInt64(i + 1),
                appName: "App\(i % 5)",
                title: "Window \(i)",
                canvasX: CGFloat(i) * columnWidth,
                width: columnWidth,
                healthy: true
            ))
        }
        let focus = max(0, n - 1)
        let viewportX = max(0, CGFloat(focus) * columnWidth - viewportWidth + columnWidth)
        return TeleportEngine.StripState(
            slots: slots,
            viewportX: viewportX,
            viewportWidth: viewportWidth,
            focusIndex: focus,
            lastTeleportMs: 1.0
        )
    }

    // Drive the bench on the main thread once the run loop is up.
    DispatchQueue.main.async {
        print("[statusbench] mirror of ProductionMenuBar update path")
        print("[statusbench] padding=\(hPadding) min=\(minWidth) max=\(maxWidth) ppScreen=\(pointsPerScreen)")
        print("[statusbench] simulating \(steps) window-add then \(steps) window-remove events\n")

        // Wire the width callback to time the ISOLATED statusItem.length write.
        var lastReported: CGFloat = -1
        var lengthSamples: [(old: CGFloat, new: CGFloat)] = []
        stripView.onDesiredContentWidthChange = { width in
            let clamped = max(minWidth, min(width, maxWidth))
            guard abs(clamped - contentWidth) >= 0.5 else { return }
            // Time ONLY the system resize.
            let ms = Clock.measureMs {
                statusItem.length = clamped + hPadding
            }
            rLengthChange.record("statusItem.length=changed", ms: ms)
            lengthSamples.append((old: contentWidth, new: clamped))
            contentWidth = clamped
        }

        func applyState(_ n: Int) {
            let snap = makeState(n)
            // Snapshot cost is trivial but measured for completeness.
            rSnapshot.record("stripState.snapshot(map)", ms: Clock.measureMs {
                _ = makeState(n)
            })
            // The real apply() includes the width callback (timed separately above)
            // but its own cost is what we attribute here.
            rApply.measure("stripView.apply()") {
                stripView.apply(state: snap, managing: true)
            }
        }

        // Warm up (first apply does mode cross-fade + initial reconcile).
        applyState(0)

        // --- Grow: add windows one at a time ---
        for n in 1...steps {
            applyState(n)
        }

        // --- Shrink: remove windows one at a time ---
        for n in stride(from: steps - 1, through: 0, by: -1) {
            applyState(n)
        }

        // --- Isolated no-op length writes: assign the SAME value repeatedly. ---
        // If even a no-op assignment is slow, the cost is the system relayout
        // triggered by touching `.length`, not the value changing.
        let fixed = statusItem.length
        for _ in 0..<60 {
            rLengthNoop.record("statusItem.length=same", ms: Clock.measureMs {
                statusItem.length = fixed
            })
        }

        // --- Isolated changing length writes WITHOUT any apply()/redraw, to
        // measure the pure system resize cost in isolation. ---
        let rLengthPure = LatencyRecorder()
        var w = minWidth
        for i in 0..<120 {
            // Alternate between two distinct widths so each write is a real change.
            w = (i % 2 == 0) ? 120 : 160
            rLengthPure.record("statusItem.length=pureChange", ms: Clock.measureMs {
                statusItem.length = w + hPadding
            })
        }

        // --- End-to-end ASYNC relayout latency: the synchronous `.length`
        // write returns fast, but the menu bar's backing window is resized by
        // the system on a later run-loop turn. Measure from the write until the
        // hosted button's window frame actually reflects the new width. THIS is
        // the latency a user perceives as "the icon resizing is slow". ---
        let rAsync = LatencyRecorder()
        func currentButtonWidth() -> CGFloat { statusItem.button?.window?.frame.width ?? -1 }
        for i in 0..<40 {
            let target = (i % 2 == 0) ? CGFloat(100) : CGFloat(190)
            let before = currentButtonWidth()
            let t0 = Clock.nowNs()
            statusItem.length = target + hPadding
            // Spin the run loop until the backing window frame changes, capping
            // at 250ms so a stuck case can't hang the bench.
            let deadline = Date().addingTimeInterval(0.25)
            while currentButtonWidth() == before && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
            }
            let ms = Double(Clock.nowNs() - t0) / 1e6
            rAsync.record("async relayout (write -> window frame updated)", ms: ms)
        }

        // Report.
        rSnapshot.printSummary(title: "StripState snapshot")
        rApply.printSummary(title: "stripView.apply() (our diff + spring + redraw request)")
        rLengthChange.printSummary(title: "statusItem.length = <changed> (during apply, system relayout)")
        rLengthPure.printSummary(title: "statusItem.length = <changed> (isolated, no apply)")
        rLengthNoop.printSummary(title: "statusItem.length = <same value> (no-op write)")
        rAsync.printSummary(title: "ASYNC relayout: write -> backing window frame actually resized")

        // --- Does the SYSTEM animate the length change? Do ONE big jump and
        // sample the backing window width every ~1ms for 400ms. A smooth ramp
        // means macOS animates the resize (perceived "slow"); an instant step
        // means it does not. ---
        print("\n[statusbench] length-change trajectory (one 30 -> 200 jump):")
        statusItem.length = minWidth + hPadding
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        let startW = statusItem.button?.window?.frame.width ?? -1
        statusItem.length = 200 + hPadding
        let t0 = Clock.nowNs()
        var lastW: CGFloat = -1
        var samples = 0
        while Clock.nowNs() - t0 < 400_000_000 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
            let w = statusItem.button?.window?.frame.width ?? -1
            if abs(w - lastW) > 0.5 {
                let ms = Double(Clock.nowNs() - t0) / 1e6
                print(String(format: "    +%6.1f ms  width=%.1f", ms, w))
                lastW = w
            }
            samples += 1
        }
        print("    (started at \(startW), sampled \(samples)x over 400ms)")


        print("\n[statusbench] distinct length changes during grow/shrink: \(lengthSamples.count)")
        if !lengthSamples.isEmpty {
            let widths = lengthSamples.map { String(format: "%.0f", $0.new) }.joined(separator: " ")
            print("[statusbench] content widths visited: \(widths)")
        }
        print("\n[statusbench] done")
        exit(0)
    }

    app.run()
}
