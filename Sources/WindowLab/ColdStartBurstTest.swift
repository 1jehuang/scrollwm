import Foundation
import ApplicationServices
import AppKit

// COLD-START BURST adoption test (`WindowLab coldstartbursttest`).
//
// The "jcode forest swarm" case: the user launches MANY brand-new apps at once -
// each a DISTINCT new process (pid) whose FIRST window appears almost
// simultaneously. Every one of those first windows is a COLD start: the process
// has no `kAXWindowCreated` observer attached yet (that observer is registered
// off `NSWorkspace.didLaunchApplication`, AFTER the window already exists), so
// none of them fire the warm create path. They each ride the LAUNCH fast path
// (`onAppLaunched` -> `LifecycleMonitor.fastAdopt(coldStart:true)`).
//
// `coldstarttest` proves ONE cold start lands fast. This proves the BURST holds
// the harder invariants when N independent cold-adopt chains run concurrently on
// the main run loop, interleaved by varied publish lags:
//
//   (B1 fast)        all N adopt well under the launch-resync budget (the fast
//                    path, not the 0.5s launch-resync / 2s poll, drives them).
//   (B2 exactly N)   the strip grows by EXACTLY N columns - no window is dropped
//                    and none is DOUBLE-adopted (a real risk: each new pid kicks
//                    its own retry chain, and the +0.5s launch-resync races them).
//   (B3 unique)      each new window appears in exactly ONE slot (no element is
//                    tiled twice), and the strip never transiently exceeds N+seed.
//   (B4 right)       every newcomer lands to the RIGHT of the original seed.
//   (B5 final set)   after settling past the launch-resync + a poll, the strip ==
//                    exactly {seed} + the N newcomers (the manageable set).
//
// It drives the REAL `TeleportEngine` + `LifecycleMonitor` + `WindowEventObserver`
// against `SimWindowWorld` (installed as `AXSource.backend`), fully HEADLESS:
// nothing is spawned, moved, focused, or closed on the real desktop, and no
// global keystroke is injected. Several trials with varied publish-lag patterns
// shake out ordering / double-adopt races deterministically.

/// One burst trial: seed + adopt one window, then LAUNCH `newCount` brand-new
/// processes (distinct pids) in a tight burst, each with its own publish lag.
/// Drives the production fast path and reports per-window + whole-burst latency.
private struct BurstTrialResult {
    var seedPID: pid_t
    var seedElement: AXUIElement
    var newPIDs: [pid_t]
    var newElements: [AXUIElement]
    /// ms from burst start until EACH new window first became managed (nil = never).
    var adoptMs: [pid_t: Double]
    /// ms from burst start until ALL `newCount` were adopted (nil = not all).
    var allAdoptedMs: Double?
    /// Highest slot count observed at any sampled instant (catches a transient
    /// double-adopt that a later pass might paper over).
    var maxSlotCount: Int
    /// Final strip slot elements, in strip (left-to-right) order.
    var finalSlotElements: [AXUIElement]
    /// Final per-slot `canvasX` (strip-layout coordinate), aligned with
    /// `finalSlotElements`. Unlike a live on-screen frame, canvasX is immune to
    /// viewport scroll/parking, so it is the honest "strip order" coordinate when
    /// the overflowing strip scrolls the seed off-screen to reveal the newest.
    var finalCanvasX: [CGFloat]
    /// Whether THIS trial's publish lags were all zero (the deterministic,
    /// single-coalesce case where strip order must equal creation order).
    var deterministicOrder: Bool
}

private func runColdStartBurstTrial(newCount: Int,
                                    publishDelays: [TimeInterval],
                                    pollInterval: TimeInterval = 5.0) -> BurstTrialResult {
    let world = SimWindowWorld()
    world.coldStartModel = true
    AXSource.backend = world
    defer { AXSource.backend = nil }

    let visible = Headless.defaultVisibleFrame
    let engine = TeleportEngine(screenFrame: visible)
    let seedPID: pid_t = 7000
    let newPIDs: [pid_t] = (0..<newCount).map { 7001 + pid_t($0) }

    // Seed one existing-app window and adopt it, so the strip is populated and
    // confirmed on the current Space (the fast-adopt Space-freeze gate needs at
    // least one on-screen managed column for a non-empty strip).
    _ = world.addWindow(pid: seedPID, title: "Seed",
                        frame: CGRect(x: 40, y: 80, width: 360, height: 420))
    let matched = IdentityMatcher.match(
        axWindows: AXSource.windows(forPID: seedPID),
        cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
    ).filter { $0.cg != nil }
    engine.adopt(matched: matched)
    engine.focus(index: 0)
    // Narrow the seed hard so all N newcomers have room to the right on the strip
    // (no scroll/parking needed) - keeps "right of seed" an unambiguous check.
    _ = engine.setFocusedWidth(fraction: 0.2)

    // Large poll so the only adopters are the fast path and the +0.5s
    // launch-resync; an adoption inside the budget therefore proves the fast
    // path drove it (the launch-resync would land at ~500ms).
    let monitor = LifecycleMonitor(engine: engine, interval: pollInterval)
    monitor.pidFilter = Set([seedPID] + newPIDs)
    monitor.coldStartFastPathEnabled = true
    monitor.start()
    Headless.pump(0.1) // let the observer subscribe to sim events

    let seedEl = engine.slots[0].window.element
    let startCount = engine.slots.count

    // Fire the BURST: N brand-new processes whose first window appears nearly
    // simultaneously, each with its own publish lag. Under `coldStartModel` the
    // first window of each never-seen pid routes through the LAUNCH sink (not the
    // warm create sink), exactly like real macOS. We also post the real
    // `didLaunchApplication` per pid so the production launch-resync fires as it
    // would live (the safety net the fast path must beat). No pump between adds:
    // they coalesce into one main-loop burst, modeling "all at once".
    var newElements: [AXUIElement] = []
    let t0 = Clock.nowAbsNs()
    for (i, pid) in newPIDs.enumerated() {
        let delay = publishDelays[i % publishDelays.count]
        // Stagger native x so each newcomer starts at a distinct spot (a vacuous
        // "already at its slot" pass is impossible).
        let nx = 480 + CGFloat(i) * 30
        let el = world.addWindow(pid: pid, title: "Cold-\(pid)",
                                 frame: CGRect(x: nx, y: 120, width: 360, height: 420),
                                 notify: true, cgPublishDelay: delay)
        newElements.append(el)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification, object: NSWorkspace.shared)
    }

    // Drive the run loop until all N are managed (or the cap lapses). Record each
    // window's first-managed time and watch for any transient over-adopt.
    var adoptMs: [pid_t: Double] = [:]
    var maxSlotCount = startCount
    var allAdoptedMs: Double?
    let cap = Clock.nowAbsNs() + 2_000_000_000
    while Clock.nowAbsNs() < cap {
        Headless.pump(0.004)
        maxSlotCount = max(maxSlotCount, engine.slots.count)
        for (i, pid) in newPIDs.enumerated() where adoptMs[pid] == nil {
            if engine.isManaged(newElements[i]) {
                adoptMs[pid] = Double(Clock.nowAbsNs() &- t0) / 1e6
            }
        }
        if adoptMs.count == newCount {
            allAdoptedMs = Double(Clock.nowAbsNs() &- t0) / 1e6
            break
        }
    }

    // Settle PAST the +0.5s launch-resync and one safety margin so a late
    // double-adopt or drop would show up in the final structural asserts.
    Headless.pump(0.8)
    maxSlotCount = max(maxSlotCount, engine.slots.count)

    let finalEls = engine.slots.map { $0.window.element }
    let finalCanvasX = engine.slots.map { $0.canvasX }

    monitor.stop()
    return BurstTrialResult(
        seedPID: seedPID, seedElement: seedEl, newPIDs: newPIDs, newElements: newElements,
        adoptMs: adoptMs, allAdoptedMs: allAdoptedMs, maxSlotCount: maxSlotCount,
        finalSlotElements: finalEls, finalCanvasX: finalCanvasX,
        deterministicOrder: publishDelays.allSatisfy { $0 == 0 })
}

/// Count how many slots in `els` are CFEqual-duplicates (same window tiled in two
/// slots) - the signature of a double-adopt.
private func duplicateElementCount(_ els: [AXUIElement]) -> Int {
    var dups = 0
    for i in els.indices {
        for j in (i + 1)..<els.count where CFEqual(els[i], els[j]) { dups += 1 }
    }
    return dups
}

/// Headless cold-start BURST regression guard (`WindowLab coldstartbursttest`).
func runHeadlessColdStartBurstTest() {
    var t = TestCounter()
    let newCount = 6

    // A handful of trials with DIFFERENT publish-lag patterns, so concurrent
    // cold-adopt chains interleave differently each time and any ordering /
    // double-adopt race is shaken out deterministically. All lags <= 120ms keep
    // every newcomer adopting via the fast path well before the 0.5s launch-resync.
    let patterns: [[TimeInterval]] = [
        [0, 0, 0, 0, 0, 0],                       // all instant: tightest coalesce
        [0, 0.02, 0.05, 0.08, 0.12, 0.04],        // varied lag (the bench spread)
        [0.12, 0.1, 0.08, 0.05, 0.02, 0],         // reversed: slowest fires first
        [0.05, 0.05, 0.05, 0.05, 0.05, 0.05],     // uniform mid lag
        [0, 0.12, 0, 0.12, 0, 0.12],              // alternating fast/slow
    ]

    var worstAllAdopted = 0.0
    var worstSingle = 0.0
    var anyDoubleAdopt = false
    var anyTransientOver = false

    for (trialIdx, delays) in patterns.enumerated() {
        let r = runColdStartBurstTrial(newCount: newCount, publishDelays: delays)
        let tag = "trial \(trialIdx)"

        // B1: all N adopted (none stranded).
        let adoptedAll = r.adoptMs.count == newCount
        t.check("[\(tag)] all \(newCount) cold-start windows adopted", adoptedAll)

        // B1: within the fast budget (the launch fast path, not the 0.5s
        // launch-resync / poll). The brief's budget is 600ms; with <=120ms publish
        // lag the fast path lands every newcomer comfortably under it.
        if let ms = r.allAdoptedMs {
            worstAllAdopted = max(worstAllAdopted, ms)
            t.check(String(format: "[\(tag)] whole burst adopted < 600ms (got %.0fms)", ms), ms < 600)
            // Stronger: the fast path BEAT the 0.5s launch-resync. A burst that
            // only finished because the +0.5s resync swept it up would land >=
            // ~500ms; staying under 480ms proves the cold fast path drove it.
            t.check(String(format: "[\(tag)] fast path beat the launch-resync (< 480ms, got %.0fms)", ms), ms < 480)
        } else {
            t.check("[\(tag)] whole burst adopted within the cap", false)
        }
        worstSingle = max(worstSingle, r.adoptMs.values.max() ?? 0)

        // B2: the strip grew by EXACTLY N (no drop, no double-adopt).
        let grewByN = r.finalSlotElements.count == 1 + newCount
        t.check("[\(tag)] strip count == seed + \(newCount) (got \(r.finalSlotElements.count))", grewByN)

        // B3: each new window appears in exactly ONE slot (no element tiled twice).
        let dups = duplicateElementCount(r.finalSlotElements)
        if dups > 0 { anyDoubleAdopt = true }
        t.check("[\(tag)] no window double-adopted (0 duplicate slots, got \(dups))", dups == 0)

        // B3: the strip never TRANSIENTLY exceeded seed + N (a double-adopt that a
        // later pass might have hidden).
        if r.maxSlotCount > 1 + newCount { anyTransientOver = true }
        t.check("[\(tag)] strip never exceeded seed + \(newCount) (peak \(r.maxSlotCount))",
                r.maxSlotCount <= 1 + newCount)

        // B5: the final set is EXACTLY {seed} + the N newcomers (every one present
        // and managed, none lost).
        let allNewPresent = r.newElements.allSatisfy { el in
            r.finalSlotElements.contains { CFEqual($0, el) }
        }
        t.check("[\(tag)] every newcomer present in the final strip", allNewPresent)

        // B4: every newcomer landed to the RIGHT of the original seed IN STRIP
        // ORDER. The strip overflows the viewport, so focusing the newest scrolls
        // the seed off-screen - its LIVE on-screen frame is no longer leftmost.
        // The honest strip-order coordinate is the slot's `canvasX` (the layout
        // X, immune to viewport scroll/parking): the seed packs at the left
        // (`gap`), every newcomer at a strictly larger canvasX.
        let seedSlot = r.finalSlotElements.firstIndex { CFEqual($0, r.seedElement) }
        var allRightOfSeed = seedSlot != nil
        if let s = seedSlot {
            let seedX = r.finalCanvasX[s]
            for (i, el) in r.finalSlotElements.enumerated()
            where !CFEqual(el, r.seedElement) {
                if r.finalCanvasX[i] <= seedX { allRightOfSeed = false }
            }
        }
        t.check("[\(tag)] every newcomer is right of the seed in strip order", allRightOfSeed)

        // B4 (strict, deterministic trials only): with ZERO publish lag the whole
        // burst folds into one coalesced delivery and is adopted in creation
        // order, so the final strip MUST be exactly [seed, new0, new1, ...]. With
        // varied lags the windows publish at different times across separate
        // adopt passes, so only the weaker "all right of seed, exactly once"
        // holds - asserting a strict order there would over-constrain reality.
        if r.deterministicOrder {
            let expected = [r.seedElement] + r.newElements
            let exactOrder = r.finalSlotElements.count == expected.count
                && zip(r.finalSlotElements, expected).allSatisfy { CFEqual($0, $1) }
            t.check("[\(tag)] deterministic burst is in exact creation order", exactOrder)
        }
    }

    // Cross-trial roll-ups (so a single line summarizes the contract).
    t.check("no double-adopt across any trial", !anyDoubleAdopt)
    t.check("strip never transiently over-grew across any trial", !anyTransientOver)
    print(String(format: "[coldstartburst] worst whole-burst latency %.0fms, worst single-window %.0fms",
                 worstAllAdopted, worstSingle))

    print("\n[coldstartburst] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}
