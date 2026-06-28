import Foundation
import ApplicationServices
import AppKit

// COLD-START adoption-latency benchmark.
//
// "Cold start" = launching a brand-NEW app (a new process), then how long until
// its FIRST window lands in its strip slot (right of focus). This is a DIFFERENT
// path from the warm case `spawnlatency` covers (a new window in an app the
// strip already observes):
//
//   - WARM: the app already has a registered `kAXWindowCreated` observer, so a
//     new window fires it and the progressive fast-adopt lands it in a few ms.
//   - COLD: a brand-new process has NO observer yet (it is attached off the
//     `didLaunchApplication` notification, AFTER the window already exists), so
//     the first window never fires the warm create path. Pre-optimization it
//     waited for the flat ~0.5s launch-resync (or the 2s safety-net poll) - the
//     visible "new app floats at its native spot, then snaps into the strip."
//
// The fix (see `WindowEventObserver` cold-start fast path + `LifecycleMonitor`
// `onAppLaunched`): on launch, register the observer IMMEDIATELY and kick off a
// bounded progressive fast-adopt for that pid, so the first window lands as fast
// as a warm one.
//
// This harness measures the win HEADLESS and A/B: it drives the EXACT production
// engine + `LifecycleMonitor` against an in-memory `SimWindowWorld` whose
// `coldStartModel` faithfully routes a brand-new pid's first window through the
// LAUNCH stand-in (not the warm create sink). It compares:
//   - BASELINE   cold start with the launch fast path DISABLED (only the real
//                production 0.5s launch-resync + poll adopt it), and
//   - OPTIMIZED  cold start with the launch fast path ENABLED, plus
//   - WARM       a second window in the now-known app (reference lower bound).
// Fully headless: never spawns/moves/focuses/closes a real window. `--live`
// runs the real-window variant (spawns disposable child processes).

private struct ColdStartTrialResult {
    var placedMs: Double?      // time until the new window reached its strip slot
    var adopted: Bool          // engine grew by one column
    var rightOfFocus: Bool     // the new window landed right of the old focus
}

/// One headless cold-start trial: seed + adopt one window, then LAUNCH a
/// brand-new process (new pid) whose first window is delivered via the sim's
/// cold-start launch stand-in. Measures time-to-final-position.
///
/// `fastPath` toggles the launch fast path (the optimization). `publishDelay`
/// models how long the spinning-up process withholds its first window from the
/// WindowServer on-screen list (AX-readable, but not yet published).
private func runColdStartTrial(fastPath: Bool, publishDelay: TimeInterval,
                               pollInterval: TimeInterval = 2.0) -> ColdStartTrialResult {
    let world = SimWindowWorld()
    world.coldStartModel = true
    AXSource.backend = world
    defer { AXSource.backend = nil }

    let visible = Headless.defaultVisibleFrame
    let engine = TeleportEngine(screenFrame: visible)
    let seedPID: pid_t = 7000
    let newPID: pid_t = 7001

    // Seed one window (existing app) and adopt it, so the strip is populated and
    // confirmed on the current Space (the fast-adopt Space-freeze gate needs at
    // least one on-screen managed column to pass for a non-empty strip).
    _ = world.addWindow(pid: seedPID, title: "Seed",
                        frame: CGRect(x: 40, y: 80, width: 360, height: 420))
    let matched = IdentityMatcher.match(
        axWindows: AXSource.windows(forPID: seedPID),
        cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
    ).filter { $0.cg != nil }
    engine.adopt(matched: matched)
    engine.focus(index: 0)
    // Narrow the seed so the newcomer has room to the right (no scroll needed).
    _ = engine.setFocusedWidth(fraction: 0.25)

    let monitor = LifecycleMonitor(engine: engine, interval: pollInterval)
    monitor.pidFilter = [seedPID, newPID]
    monitor.coldStartFastPathEnabled = fastPath
    monitor.start()
    Headless.pump(0.1) // let the observer subscribe

    let focusedBefore = engine.slots[engine.focusIndex].window.element
    let focusedXBefore = world.frame(of: focusedBefore)?.minX ?? 0
    let startCount = engine.slots.count

    let t0 = Clock.nowAbsNs()
    // LAUNCH a brand-new process: under `coldStartModel` this fires the LAUNCH
    // stand-in (not the warm create sink). We ALSO post the real
    // `didLaunchApplication` notification so the production launch-resync (the
    // monitor's own 0.5s-delayed resync) fires exactly as it would live - this is
    // what adopts the window in the BASELINE (fast path off), and what the
    // optimized path races and beats.
    let newEl = world.addWindow(pid: newPID, title: "ColdApp",
                                frame: CGRect(x: 460, y: 80, width: 360, height: 420),
                                notify: true, cgPublishDelay: publishDelay)
    NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.didLaunchApplicationNotification, object: NSWorkspace.shared)

    var placedNs: UInt64?
    let deadline = Clock.nowAbsNs() + 4_000_000_000
    while Clock.nowAbsNs() < deadline {
        Headless.pump(0.005)
        if engine.slots.count > startCount,
           let f = world.frame(of: newEl), f.minX > focusedXBefore + 1 {
            placedNs = Clock.nowAbsNs(); break
        }
    }

    let result = ColdStartTrialResult(
        placedMs: placedNs.map { Double($0 &- t0) / 1e6 },
        adopted: engine.slots.count > startCount,
        rightOfFocus: (world.frame(of: newEl)?.minX ?? 0) > focusedXBefore + 1
    )
    monitor.stop()
    return result
}

/// Run a batch of cold-start trials and return latency samples (ms) plus the
/// count that ever reached the final position.
private func coldStartSamples(label: String, trials: Int, fastPath: Bool,
                              publishDelays: [TimeInterval]) -> LatencyStats {
    var samples: [Double] = []
    for i in 0..<trials {
        let delay = publishDelays[i % publishDelays.count]
        let r = runColdStartTrial(fastPath: fastPath, publishDelay: delay)
        if let ms = r.placedMs { samples.append(ms) }
        else { samples.append(4000) } // never placed within the cap -> worst case
    }
    return LatencyStats(label: label, samples: samples)
}

/// Headless cold-start benchmark entry point (`WindowLab coldstartbench [trials]`).
func runColdStartBench(args: [String]) {
    let trials = args.dropFirst().compactMap { Int($0) }.first ?? 20
    // Representative spread of how long a spinning-up process withholds its first
    // window from the WindowServer on-screen list (publish lag after launch).
    let publishDelays: [TimeInterval] = [0, 0.02, 0.05, 0.08, 0.12]

    print("== Cold-start adoption latency (headless, \(trials) trials) ==")
    print("   metric: time from app launch until its FIRST window reaches its")
    print("           strip slot (right of focus). poll=2.0s, publish lag in")
    print("           {0, 20, 50, 80, 120} ms.\n")

    let baseline  = coldStartSamples(label: "cold start  BASELINE (launch fast path OFF)",
                                     trials: trials, fastPath: false, publishDelays: publishDelays)
    let optimized = coldStartSamples(label: "cold start  OPTIMIZED (launch fast path ON)",
                                     trials: trials, fastPath: true, publishDelays: publishDelays)

    print(baseline.summaryRow)
    print(optimized.summaryRow)

    let bP50 = baseline.percentile(50), oP50 = optimized.percentile(50)
    let bP95 = baseline.percentile(95), oP95 = optimized.percentile(95)
    let speedup = oP50 > 0 ? bP50 / oP50 : 0
    print(String(format: "\n   p50: %.0f ms -> %.0f ms  (%.1fx faster)", bP50, oP50, speedup))
    print(String(format: "   p95: %.0f ms -> %.0f ms", bP95, oP95))

    // Verifiable success criteria so this doubles as a regression guard:
    //   - the optimized cold start is fast (well under the launch-resync) and
    //   - it is a large, unambiguous improvement over the baseline.
    var t = TestCounter()
    t.check(String(format: "optimized cold-start p50 < 120ms (got %.0f)", oP50), oP50 < 120)
    t.check(String(format: "optimized cold-start p95 < 250ms (got %.0f)", oP95), oP95 < 250)
    t.check(String(format: "baseline cold-start p50 >= 400ms (launch-resync, got %.0f)", bP50), bP50 >= 400)
    t.check(String(format: "optimization is >= 3x faster at p50 (got %.1fx)", speedup), speedup >= 3)

    print("\n[coldstartbench] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}

// MARK: - coldstarttest (headless): cold-start fast-path regression guard
//
// A lean PASS/FAIL version of the benchmark suitable for the standard headless
// suite. It proves the core contract end-to-end against the REAL engine +
// `LifecycleMonitor`:
//   - a brand-NEW app's FIRST window (which never fires the warm create
//     observer) is adopted FAST and lands right of focus, and
//   - with the launch fast path disabled it is markedly SLOWER (the baseline),
//     so the test actually exercises the optimization rather than the warm path.

func runHeadlessColdStartTest() {
    var t = TestCounter()

    // OPTIMIZED: launch fast path on. A cold-start window with a small publish
    // lag must reach its slot well under the production launch-resync (~0.5s).
    let opt = runColdStartTrial(fastPath: true, publishDelay: 0.05)
    t.check("cold-start window adopted (optimized)", opt.adopted)
    t.check("cold-start window landed right of focus (optimized)", opt.rightOfFocus)
    if let ms = opt.placedMs {
        print(String(format: "[headless-coldstart] optimized reached final position in %.0f ms", ms))
        t.check(String(format: "optimized cold-start < 250ms (fast path beat launch-resync, got %.0fms)", ms), ms < 250)
        // It cannot beat the publish lag (the window is not on-screen before it).
        t.check(String(format: "optimized cold-start respected the 50ms publish lag (>= 45ms, got %.0fms)", ms), ms >= 45)
    } else {
        t.check("optimized cold-start reached final position", false)
    }

    // BASELINE: launch fast path off. The SAME window must take much longer
    // (it waits for the production 0.5s launch-resync), proving the test is
    // really gated on the optimization, not the warm path leaking through.
    let base = runColdStartTrial(fastPath: false, publishDelay: 0.05)
    t.check("cold-start window eventually adopted (baseline)", base.adopted)
    if let bms = base.placedMs, let oms = opt.placedMs {
        print(String(format: "[headless-coldstart] baseline reached final position in %.0f ms", bms))
        t.check(String(format: "baseline cold-start is slow (>= 400ms launch-resync, got %.0fms)", bms), bms >= 400)
        t.check(String(format: "optimization is a large win (baseline %.0fms vs optimized %.0fms)", bms, oms),
                bms > oms * 2)
    } else {
        t.check("baseline cold-start reached final position", false)
    }

    print("\n[headless-coldstart] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}

