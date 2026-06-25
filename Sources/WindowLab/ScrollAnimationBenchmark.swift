import Foundation
import ApplicationServices
import AppKit

/// scrollbench: can we animate windows via AX moves smoothly enough
/// to skip the Metal/SCK proxy layer (and the Screen Recording permission)?
///
/// Headless by construction: the driver (`runScrollBench`) only ever animates
/// disposable test windows it spawns itself, so a benchmark run never grabs or
/// moves the user's real windows.
///
/// Simulates a viewport pan: every test window translates together along an
/// eased path, driven by a 60Hz tick. Measures per-tick AX commit cost,
/// per-window latency, and effective frame pacing. Restores all windows.
enum ScrollAnimationBenchmark {

    struct WindowResult {
        let appName: String
        let title: String
        var commitLatenciesMs: [Double] = []
        var errors: [AXError] = []
        var restored = false
    }

    struct TickStats {
        var tickDurationsMs: [Double] = []   // full commit pass per tick
        var tickIntervalsMs: [Double] = []   // actual spacing between ticks
        var targetIntervalMs: Double
    }

    /// Ease-in-out cubic.
    private static func ease(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    static func run(
        matched: [MatchedWindow],
        distance: CGFloat = 300,        // pan distance in points
        durationMs: Double = 400,       // animation duration
        hz: Double = 60,
        maxWindows: Int = 10
    ) -> (windows: [WindowResult], ticks: TickStats) {
        let candidates = Array(matched.filter {
            $0.ax.subrole == kAXStandardWindowSubrole as String
                && !$0.ax.isMinimized
                && !$0.ax.isFullscreen
        }.prefix(maxWindows))

        var results = candidates.map {
            WindowResult(appName: $0.ax.appName, title: $0.ax.title ?? "(untitled)")
        }
        let originals = candidates.map { $0.ax.frame.origin }
        let elements = candidates.map { $0.ax.element }
        for e in elements { AXSource.setTimeout(e, seconds: 0.05) }

        var ticks = TickStats(targetIntervalMs: 1000.0 / hz)
        let tickInterval = 1.0 / hz
        let totalTicks = Int(durationMs / 1000.0 * hz)

        print("Animating \(candidates.count) real windows: \(Int(distance))pt pan over \(Int(durationMs))ms at \(Int(hz))Hz (\(totalTicks) ticks)...")

        var lastTickNs: UInt64 = 0
        let animationStart = Clock.nowNs()

        // Out-and-back: pan right with easing, then return. Ends at origin.
        for tick in 0...totalTicks {
            let tickStart = Clock.nowNs()
            if lastTickNs != 0 {
                ticks.tickIntervalsMs.append(Double(tickStart - lastTickNs) / 1e6)
            }
            lastTickNs = tickStart

            let t = Double(tick) / Double(totalTicks)
            // Triangle wave 0->1->0 through the eased curve.
            let phase = t < 0.5 ? ease(t * 2) : ease((1 - t) * 2)
            let offset = CGFloat(phase) * distance

            for (i, element) in elements.enumerated() {
                let target = CGPoint(x: originals[i].x + offset, y: originals[i].y)
                let start = Clock.nowNs()
                let err = AXSource.setPoint(element, kAXPositionAttribute as String, target)
                let elapsed = Double(Clock.nowNs() - start) / 1e6
                if err == .success {
                    results[i].commitLatenciesMs.append(elapsed)
                } else {
                    results[i].errors.append(err)
                }
            }

            let tickEnd = Clock.nowNs()
            ticks.tickDurationsMs.append(Double(tickEnd - tickStart) / 1e6)

            // Sleep the remainder of the tick budget.
            let elapsedSinceAnimStart = Double(tickEnd - animationStart) / 1e9
            let nextTickAt = Double(tick + 1) * tickInterval
            let sleepFor = nextTickAt - elapsedSinceAnimStart
            if sleepFor > 0 {
                usleep(useconds_t(sleepFor * 1_000_000))
            }
        }

        // Restore and verify.
        for (i, element) in elements.enumerated() {
            let err = AXSource.setPoint(element, kAXPositionAttribute as String, originals[i])
            if err == .success,
               let pos = AXSource.copyPoint(element, kAXPositionAttribute as String),
               abs(pos.x - originals[i].x) <= 2, abs(pos.y - originals[i].y) <= 2 {
                results[i].restored = true
            }
        }

        return (results, ticks)
    }

    static func printReport(windows: [WindowResult], ticks: TickStats) {
        print("\n== Per-window AX commit latency ==")
        for w in windows {
            let stats = LatencyStats(label: "", samples: w.commitLatenciesMs)
            let errNote = w.errors.isEmpty ? "" : "  errors=\(w.errors.count)"
            print(String(
                format: "  %-20@ %-28@ p50=%5.2f p95=%6.2f max=%7.2f ms%@%@",
                String(w.appName.prefix(20)) as NSString,
                String(w.title.prefix(28)) as NSString,
                stats.percentile(50), stats.percentile(95), stats.max,
                errNote as NSString,
                (w.restored ? "" : "  NOT-RESTORED") as NSString
            ))
        }

        let tickStats = LatencyStats(label: "", samples: ticks.tickDurationsMs)
        let intervalStats = LatencyStats(label: "", samples: ticks.tickIntervalsMs)
        let budget = ticks.targetIntervalMs
        let blownTicks = ticks.tickDurationsMs.filter { $0 > budget }.count
        let jankTicks = ticks.tickIntervalsMs.filter { $0 > budget * 1.5 }.count

        print("\n== Tick pacing (the verdict) ==")
        print(String(format: "  commit pass:   p50=%5.2f  p95=%6.2f  max=%7.2f ms  (budget %.2f ms)",
                     tickStats.percentile(50), tickStats.percentile(95), tickStats.max, budget))
        print(String(format: "  tick interval: p50=%5.2f  p95=%6.2f  max=%7.2f ms",
                     intervalStats.percentile(50), intervalStats.percentile(95), intervalStats.max))
        print("  ticks over budget: \(blownTicks)/\(ticks.tickDurationsMs.count)")
        print("  janky intervals (>1.5x budget): \(jankTicks)/\(ticks.tickIntervalsMs.count)")

        let verdict: String
        if tickStats.percentile(95) < budget * 0.5 && jankTicks == 0 {
            verdict = "EXCELLENT - real-window animation is viable at this Hz and window count"
        } else if tickStats.percentile(95) < budget && jankTicks <= 2 {
            verdict = "GOOD - viable with occasional micro-jank"
        } else if tickStats.percentile(50) < budget {
            verdict = "MARGINAL - median ok but tail will cause visible stutter"
        } else {
            verdict = "NOT VIABLE - proxy layer required for smooth motion"
        }
        print("  verdict: \(verdict)")
    }
}

/// Headless-only: scrollbench ALWAYS animates disposable test windows it spawns
/// itself, never the user's real windows. This keeps it from grabbing or moving
/// whatever you happen to be working on. The spawned windows are terminated on
/// exit.
func runScrollBench(windows: Int, hz: Double) {
    guard AXSource.isTrusted else {
        print("AX: NOT TRUSTED. Grant Accessibility permission first.")
        exit(2)
    }

    print("Spawning \(windows) disposable test windows...")
    let spawned = spawnTestWindows(count: windows)
    defer {
        for p in spawned { p.terminate() }
    }
    Thread.sleep(forTimeInterval: 1.5) // let them appear

    let pids = Set(spawned.map { $0.processIdentifier })
    let axWindows = pids.flatMap { pid -> [AXWindowInfo] in
        guard let app = NSRunningApplication(processIdentifier: pid) else { return [] }
        return AXSource.windows(for: app)
    }
    let cg = CGWindowSource.listWindows(onscreenOnly: true)
    let matched = IdentityMatcher.match(axWindows: axWindows, cgWindows: cg)
    print("Found \(matched.count) test windows via AX.\n")

    print("scrollbench: animating disposable test windows via AX moves (terminated afterwards)\n")
    let (results, ticks) = ScrollAnimationBenchmark.run(
        matched: matched, hz: hz, maxWindows: windows
    )
    ScrollAnimationBenchmark.printReport(windows: results, ticks: ticks)
}
