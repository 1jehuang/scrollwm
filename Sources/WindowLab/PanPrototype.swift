import Foundation
import ApplicationServices
import AppKit

/// Milestone 5: the v1 vertical slice.
///
/// Real windows live on a virtual canvas. ctrl+opt+scroll pans the viewport;
/// every managed window is committed to (canvasFrame - viewportOrigin) via AX
/// at up to 60Hz, with inertial coasting. No proxies, no capture - the
/// Accessibility-only architecture validated by scrollbench.
final class PanPrototype {

    struct ManagedWindow {
        let appName: String
        let title: String
        let element: AXUIElement
        let canvasOrigin: CGPoint     // fixed position on the canvas
        var lastCommitted: CGPoint    // last position we sent via AX
        var commitLatenciesMs: [Double] = []
        var errorCount = 0
    }

    private var windows: [ManagedWindow] = []
    private let inputQueue = ScrollInputQueue()
    private var viewport = ViewportPhysics()

    // Metrics
    private var tickDurationsMs: [Double] = []
    private var tickIntervalsMs: [Double] = []
    private var totalCommits = 0
    private var skippedCommits = 0

    private let hz: Double
    init(hz: Double = 60) { self.hz = hz }

    func adopt(matched: [MatchedWindow], maxWindows: Int) {
        windows = matched.filter {
            $0.ax.subrole == kAXStandardWindowSubrole as String
                && !$0.ax.isMinimized && !$0.ax.isFullscreen
        }.prefix(maxWindows).map {
            AXSource.setTimeout($0.ax.element, seconds: 0.05)
            return ManagedWindow(
                appName: $0.ax.appName,
                title: $0.ax.title ?? "(untitled)",
                element: $0.ax.element,
                canvasOrigin: $0.ax.frame.origin,
                lastCommitted: $0.ax.frame.origin
            )
        }
    }

    /// Run the pan loop for `seconds`. Blocks the calling thread.
    func run(seconds: Int) {
        let tickInterval = 1.0 / hz
        let startNs = Clock.nowAbsNs()
        let endNs = startNs + UInt64(seconds) * 1_000_000_000
        var tickIndex: UInt64 = 0
        var lastTickNs: UInt64 = 0
        var lastReportNs = startNs

        while Clock.nowAbsNs() < endNs {
            let tickStart = Clock.nowAbsNs()
            if lastTickNs != 0 {
                tickIntervalsMs.append(Double(tickStart &- lastTickNs) / 1e6)
            }
            lastTickNs = tickStart

            // 1. Input -> viewport
            let samples = inputQueue.drain()
            let dt = tickInterval
            viewport.apply(samples: samples, nowNs: tickStart)
            viewport.coast(dt: dt, nowNs: tickStart)

            // 2. Commit real windows toward (canvas - viewport)
            for i in windows.indices {
                let target = CGPoint(
                    x: windows[i].canvasOrigin.x - CGFloat(viewport.origin.x),
                    y: windows[i].canvasOrigin.y - CGFloat(viewport.origin.y)
                )
                let delta = max(abs(target.x - windows[i].lastCommitted.x),
                                abs(target.y - windows[i].lastCommitted.y))
                guard delta >= 0.5 else { skippedCommits += 1; continue }

                let start = Clock.nowAbsNs()
                let err = AXSource.setPoint(windows[i].element, kAXPositionAttribute as String, target)
                let elapsed = Double(Clock.nowAbsNs() &- start) / 1e6
                if err == .success {
                    windows[i].lastCommitted = target
                    windows[i].commitLatenciesMs.append(elapsed)
                    totalCommits += 1
                } else {
                    windows[i].errorCount += 1
                }
            }

            let tickEnd = Clock.nowAbsNs()
            tickDurationsMs.append(Double(tickEnd &- tickStart) / 1e6)

            // Once per second: progress line.
            if tickEnd &- lastReportNs > 1_000_000_000 {
                lastReportNs = tickEnd
                let recent = tickDurationsMs.suffix(Int(hz))
                print(String(
                    format: "  viewport=(%6.0f,%6.0f) v=(%7.0f,%7.0f) commits=%-6d tickMax=%5.2fms",
                    viewport.origin.x, viewport.origin.y,
                    viewport.velocity.x, viewport.velocity.y,
                    totalCommits, recent.max() ?? 0
                ))
            }

            // 3. Absolute-time pacing: sleep until the next tick boundary,
            // so commit-pass cost never stretches the cadence.
            tickIndex += 1
            let nextTickNs = startNs + UInt64(Double(tickIndex) * tickInterval * 1e9)
            let now = Clock.nowAbsNs()
            if nextTickNs > now {
                usleep(useconds_t((nextTickNs - now) / 1_000))
            } else {
                // We overran one or more whole ticks; resynchronize.
                tickIndex = UInt64(Double(now - startNs) / (tickInterval * 1e9)) + 1
            }
        }
    }

    /// Put every window back at its canvas origin (viewport zero).
    func restore() -> Int {
        var failures = 0
        for w in windows {
            if AXSource.setPoint(w.element, kAXPositionAttribute as String, w.canvasOrigin) != .success {
                failures += 1
            }
        }
        return failures
    }

    func startTap() -> ScrollEventTap? {
        let tap = ScrollEventTap(queue: inputQueue)
        return tap.start() ? tap : nil
    }

    func printReport() {
        let ticks = LatencyStats(label: "", samples: tickDurationsMs)
        let intervals = LatencyStats(label: "", samples: tickIntervalsMs)
        let budget = 1000.0 / hz
        let janky = tickIntervalsMs.filter { $0 > budget * 1.5 }.count

        print("\n== Pan prototype report ==")
        print("  managed windows:  \(windows.count)")
        print("  total commits:    \(totalCommits) (skipped \(skippedCommits) sub-pixel)")
        print(String(format: "  tick (commit pass): p50=%5.2f p95=%6.2f max=%7.2f ms (budget %.2f)",
                     ticks.percentile(50), ticks.percentile(95), ticks.max, budget))
        print(String(format: "  tick interval:      p50=%5.2f p95=%6.2f max=%7.2f ms",
                     intervals.percentile(50), intervals.percentile(95), intervals.max))
        print("  janky intervals (>1.5x budget): \(janky)/\(tickIntervalsMs.count)")

        print("\n  per-window commit latency:")
        for w in windows.sorted(by: { ($0.commitLatenciesMs.max() ?? 0) > ($1.commitLatenciesMs.max() ?? 0) }) {
            let s = LatencyStats(label: "", samples: w.commitLatenciesMs)
            let errs = w.errorCount > 0 ? " errors=\(w.errorCount)" : ""
            print(String(format: "    %-18@ %-26@ n=%-5d p50=%5.2f p95=%6.2f max=%7.2f ms%@",
                         String(w.appName.prefix(18)) as NSString,
                         String(w.title.prefix(26)) as NSString,
                         s.count, s.percentile(50), s.percentile(95), s.max,
                         errs as NSString))
        }
    }
}

func runPan(seconds: Int, windowCount: Int, spawn: Bool, selftest: Bool) {
    guard AXSource.isTrusted else {
        print("AX: NOT TRUSTED. Grant Accessibility permission first.")
        exit(2)
    }

    var spawned: [Process] = []
    let matched: [MatchedWindow]

    if spawn {
        print("Spawning \(windowCount) test windows...")
        spawned = spawnTestWindows(count: windowCount)
        Thread.sleep(forTimeInterval: 1.5)
        let pids = Set(spawned.map { $0.processIdentifier })
        let axWindows = pids.flatMap { pid -> [AXWindowInfo] in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return [] }
            return AXSource.windows(for: app)
        }
        matched = IdentityMatcher.match(
            axWindows: axWindows,
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        )
    } else {
        let ax = AXSource.allWindows()
        matched = IdentityMatcher.match(
            axWindows: ax,
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        )
    }
    defer { for p in spawned { p.terminate() } }

    let proto = PanPrototype()
    proto.adopt(matched: matched, maxWindows: windowCount)

    guard let tap = proto.startTap() else {
        print("Failed to create event tap. Check Accessibility / Input Monitoring permission.")
        exit(2)
    }

    let scroller = SelfTestScroller()
    if selftest {
        scroller.start(durationSeconds: Double(seconds) - 1.0)
        print("Selftest: synthetic ctrl+opt scroll driving the canvas.")
    }

    print("Pan prototype: hold CTRL+OPTION and scroll to pan \(spawn ? "the test" : "your real") windows. \(seconds)s...\n")
    proto.run(seconds: seconds)

    tap.stop()
    let failures = proto.restore()
    proto.printReport()
    if selftest { print("\n  synthetic events posted: \(scroller.posted)") }
    if failures > 0 {
        print("\nWARNING: \(failures) window(s) failed to restore to canvas origin")
    } else {
        print("\n  all windows restored to canvas origin")
    }
}
