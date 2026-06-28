import Foundation
import ApplicationServices
import AppKit

/// LIVE measurement of the USER-PERCEIVED cold-start "flash": the window is
/// visibly drawn at its NATIVE spawn position for some time, then snaps into the
/// strip. The existing `coldstartlive` measures spawn->placed latency, but that
/// clock starts at the spawn instant and so folds in the (INVISIBLE) process
/// spin-up time. What the user actually sees is shorter and different:
///
///   flash = (instant we MOVE the window into the strip)
///         - (instant the window first appears ON-SCREEN at its native spot)
///
/// i.e. only the time the window is visible in the WRONG place. That is the
/// number to minimize. This harness times exactly that against real AX:
///   t_publish = first moment the new window is in the WindowServer on-screen
///               list (`CGWindowSource.listWindows`) AND AX-readable at its
///               native frame (what the user sees), and
///   t_moved   = first moment its live AX frame matches the engine's strip slot
///               target (we have teleported it).
///
/// GOLDEN RULE: like the other live tests this builds its OWN engine + monitor,
/// hard-scoped (`pidFilter`) to the disposable pids it spawns, with a slow 5s
/// poll so any sub-second move proves the fast path. It NEVER reads or moves the
/// user's real windows.
///
/// Run: `WindowLab coldstartflash [trials]`   (requires Accessibility)
func runColdStartFlashTest() {
    guard AXSource.isTrusted else {
        print("coldstartflash: needs Accessibility permission. Grant it and re-run.")
        exit(2)
    }
    guard LifecycleMonitor.sessionIsActive() else {
        print("coldstartflash: session is locked/inactive (screen locked). Unlock and re-run.")
        exit(2)
    }
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

    let trials = CommandLine.arguments.dropFirst(2).compactMap { Int($0) }.first ?? 5

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    DispatchQueue.global().async {
        var flashes: [Double] = []
        var placedFromSpawn: [Double] = []

        // One seed window (own process), adopted + narrowed so the newcomer has
        // room to the RIGHT (no scroll needed).
        print("[coldstartflash] spawning seed window...")
        let seed = spawnTestWindows(count: 1)
        Thread.sleep(forTimeInterval: 1.2)
        let seedPids = Set(seed.map { $0.processIdentifier })

        let screen = NSScreen.main!.visibleFrame
        let axFrame = CGRect(x: screen.origin.x,
                             y: NSScreen.main!.frame.height - screen.maxY,
                             width: screen.width, height: screen.height)
        let engine = TeleportEngine(screenFrame: axFrame)

        func cleanup(_ extra: [Process]) {
            DispatchQueue.main.sync { _ = engine.releaseAll() }
            for p in seed + extra where p.isRunning { p.terminate() }
            RestoreStore.clear()
        }

        let seedAX = seedPids.flatMap { AXSource.windows(forPID: $0) }
        let matched = IdentityMatcher.match(
            axWindows: seedAX,
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        ).filter { seedPids.contains($0.ax.pid) }
        DispatchQueue.main.sync { engine.adopt(matched: matched); engine.focus(index: 0) }
        guard engine.slots.count == 1 else {
            print("[coldstartflash] seed never adoptable; aborting"); cleanup([]); exit(1)
        }
        DispatchQueue.main.sync { _ = engine.setFocusedWidth(fraction: 0.25) }
        Thread.sleep(forTimeInterval: 0.2)

        let monitor = LifecycleMonitor(engine: engine, interval: 5.0)
        DispatchQueue.main.sync { monitor.pidFilter = seedPids; monitor.start() }
        Thread.sleep(forTimeInterval: 0.4)

        var spawned: [Process] = []

        for trial in 0..<trials {
            let startCount = DispatchQueue.main.sync { engine.slots.count }

            // Launch a brand-NEW process (cold start). Widen the pidFilter to it
            // BEFORE any launch handling so the fast path is allowed to act.
            let t0 = Clock.nowAbsNs()
            let cold = spawnTestWindows(count: 1)
            spawned += cold
            let newPids = Set(cold.map { $0.processIdentifier })
            DispatchQueue.main.sync { monitor.pidFilter = monitor.pidFilter?.union(newPids) }

            // Post the real launch notification (accessory apps don't reliably get
            // one) so the production cold-start path fires byte-for-byte.
            DispatchQueue.global().async {
                let deadline = Clock.nowAbsNs() + 3_000_000_000
                while Clock.nowAbsNs() < deadline {
                    if let pid = newPids.first,
                       let a = NSRunningApplication(processIdentifier: pid), !a.isTerminated {
                        DispatchQueue.main.async {
                            NSWorkspace.shared.notificationCenter.post(
                                name: NSWorkspace.didLaunchApplicationNotification,
                                object: NSWorkspace.shared,
                                userInfo: [NSWorkspace.applicationUserInfoKey: a])
                        }
                        return
                    }
                    usleep(8_000)
                }
            }

            // Measure: t_publish = first on-screen sighting at native spot;
            //          t_moved   = first time live frame == engine strip target.
            var publishNs: UInt64?
            var movedNs: UInt64?
            let deadline = Clock.nowAbsNs() + 8_000_000_000
            while Clock.nowAbsNs() < deadline {
                // Has the WindowServer listed the new window yet (on-screen)?
                if publishNs == nil {
                    let cg = CGWindowSource.listWindows(onscreenOnly: true)
                    if cg.contains(where: { newPids.contains($0.ownerPID) }) {
                        publishNs = Clock.nowAbsNs()
                    }
                }
                // Has the engine teleported it to its slot target?
                let landed: Bool = DispatchQueue.main.sync {
                    guard engine.slots.count > startCount,
                          let slot = engine.slots.first(where: { newPids.contains($0.window.pid) })
                    else { return false }
                    let target = engine.onScreenTarget(for: slot)
                    guard let live = AXSource.copyPoint(slot.window.element, kAXPositionAttribute as String)
                    else { return false }
                    return abs(live.x - target.x) <= 8 && abs(live.y - target.y) <= 8
                }
                if landed { movedNs = Clock.nowAbsNs(); break }
                usleep(1_000) // 1ms sampling for a sharp flash measurement
            }

            if let movedNs {
                let placeMs = Double(movedNs &- t0) / 1e6
                placedFromSpawn.append(placeMs)
                if let publishNs {
                    let flashMs = Double(movedNs &- publishNs) / 1e6
                    flashes.append(max(0, flashMs))
                    print(String(format: "[coldstartflash] trial %d: FLASH (visible at native spot) = %.0f ms   (spawn->placed %.0f ms)",
                                 trial + 1, max(0, flashMs), placeMs))
                } else {
                    print(String(format: "[coldstartflash] trial %d: placed in %.0f ms but never saw it published first",
                                 trial + 1, placeMs))
                }
            } else {
                print("[coldstartflash] trial \(trial + 1): window never reached its slot within 8s")
            }

            // Tidy up between trials: terminate this trial's cold app + let the
            // strip settle back to just the seed.
            for p in cold where p.isRunning { p.terminate() }
            Thread.sleep(forTimeInterval: 0.8)
            DispatchQueue.main.sync { monitor.resync() }
            Thread.sleep(forTimeInterval: 0.2)
        }

        func stats(_ xs: [Double]) -> (p50: Double, p95: Double, mn: Double, mx: Double, mean: Double) {
            guard !xs.isEmpty else { return (0, 0, 0, 0, 0) }
            let s = xs.sorted()
            func pct(_ p: Double) -> Double { s[min(s.count - 1, Int(p / 100 * Double(s.count)))] }
            return (pct(50), pct(95), s.first!, s.last!, xs.reduce(0, +) / Double(xs.count))
        }

        let f = stats(flashes)
        print("")
        print(String(format: "== Cold-start FLASH (visible-misplacement) over %d trials ==", flashes.count))
        print(String(format: "   flash  mean=%.0f  p50=%.0f  p95=%.0f  min=%.0f  max=%.0f ms",
                     f.mean, f.p50, f.p95, f.mn, f.mx))
        let pf = stats(placedFromSpawn)
        print(String(format: "   spawn->placed  p50=%.0f  p95=%.0f ms (includes invisible spin-up)", pf.p50, pf.p95))

        cleanup(spawned)
        print(String(format: "\n[coldstartflash] done (%d trials)", flashes.count))
        exit(0)
    }

    app.run()
}

// MARK: - Headless flash model (runs anywhere; no AX, no real windows)
//
// The live `coldstartflash` is gated on Accessibility + an unlocked session, so
// it cannot run in CI / an agent box. This headless model reproduces the SAME
// user-perceived metric against the production engine + `LifecycleMonitor` +
// `SimWindowWorld`, and crucially models the part the existing `coldstartbench`
// does NOT: a heavy app whose first window appears in AX LATE (process spin-up),
// landing deep in the cold-start retry cadence where probes are widely spaced.
//
//   flash = time the window is VISIBLE at its native spot before we move it
//         = (moved instant) - (window first on-screen at native frame)
//
// The window becomes on-screen the instant it is added (no publish delay here -
// we are modeling spin-up, not the publish race), so the flash is exactly the
// latency of the first retry probe that fires AFTER the window appears. With the
// coarse tail (...0.3, 0.4) a window that appears ~0.5s post-launch waits up to
// the next 300-400ms gap: a clearly visible jump.

private struct FlashTrial {
    var flashMs: Double?     // visible-at-native -> moved
    var moved: Bool
    var rightOfFocus: Bool
}

/// One headless flash trial. A seed window is adopted + narrowed. Then a
/// brand-new pid "launches" (fireColdLaunch) but its window only APPEARS in AX
/// `appearDelay` seconds later (spin-up). We time from window-appears to
/// window-moved-into-slot: the user-visible flash.
private func runFlashTrial(appearDelay: TimeInterval) -> FlashTrial {
    let world = SimWindowWorld()
    world.coldStartModel = true
    AXSource.backend = world
    defer { AXSource.backend = nil }

    let visible = Headless.defaultVisibleFrame
    let engine = TeleportEngine(screenFrame: visible)
    let seedPID: pid_t = 8000
    let newPID: pid_t = 8001

    _ = world.addWindow(pid: seedPID, title: "Seed",
                        frame: CGRect(x: 40, y: 80, width: 360, height: 420))
    let matched = IdentityMatcher.match(
        axWindows: AXSource.windows(forPID: seedPID),
        cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
    ).filter { $0.cg != nil }
    engine.adopt(matched: matched)
    engine.focus(index: 0)
    _ = engine.setFocusedWidth(fraction: 0.25)

    let monitor = LifecycleMonitor(engine: engine, interval: 5.0)
    monitor.pidFilter = [seedPID, newPID]
    monitor.start()
    Headless.pump(0.1)

    let focusedXBefore = world.frame(of: engine.slots[engine.focusIndex].window.element)?.minX ?? 0
    let startCount = engine.slots.count

    // 1) Process launches NOW (cold-start fast path begins retrying), but its
    //    window does not exist yet.
    world.fireColdLaunch(pid: newPID)

    // 2) After `appearDelay`, the window appears in AX AND on-screen (visible to
    //    the user at its native spawn spot). Record that instant.
    var appearedNs: UInt64?
    var newEl: AXUIElement?
    let appearAt = Clock.nowAbsNs() + UInt64(appearDelay * 1e9)

    var movedNs: UInt64?
    let deadline = Clock.nowAbsNs() + 4_000_000_000
    while Clock.nowAbsNs() < deadline {
        if appearedNs == nil && Clock.nowAbsNs() >= appearAt {
            // Create the window now (no notify: a cold app's first window fired no
            // create observer; only the launch retry loop can find it).
            newEl = world.addWindow(pid: newPID, title: "HeavyApp",
                                    frame: CGRect(x: 460, y: 80, width: 360, height: 420),
                                    notify: false)
            appearedNs = Clock.nowAbsNs()
        }
        Headless.pump(0.002)
        if let newEl, engine.slots.count > startCount,
           let f = world.frame(of: newEl), f.minX > focusedXBefore + 1 {
            movedNs = Clock.nowAbsNs(); break
        }
    }

    let flashMs: Double? = (appearedNs != nil && movedNs != nil)
        ? Double(movedNs! &- appearedNs!) / 1e6 : nil
    let result = FlashTrial(
        flashMs: flashMs,
        moved: movedNs != nil,
        rightOfFocus: (newEl.flatMap { world.frame(of: $0)?.minX } ?? 0) > focusedXBefore + 1
    )
    monitor.stop()
    return result
}

/// Headless flash benchmark entry point (`WindowLab coldstartflashheadless`).
/// Sweeps a realistic spread of spin-up delays (when the window first appears
/// after launch) and reports the user-perceived flash distribution.
func runHeadlessColdStartFlashBench() {
    // How long after launch the first window appears in AX (process spin-up).
    // Light apps ~50-150ms; heavy apps (Xcode, big Electron) 300ms-1s+.
    let appearDelays: [TimeInterval] = [0.05, 0.15, 0.3, 0.5, 0.7, 0.9, 1.2]

    print("== Cold-start FLASH (headless model of spin-up) ==")
    print("   metric: ms the new window is VISIBLE at its native spot before we")
    print("           move it (window-appears -> moved-into-slot). Models a heavy")
    print("           app whose first window appears LATE after launch.\n")

    var samples: [Double] = []
    var allMoved = true, allRight = true
    for d in appearDelays {
        let r = runFlashTrial(appearDelay: d)
        if let ms = r.flashMs {
            samples.append(ms)
            print(String(format: "   window appears %4.0fms after launch -> flash %5.0f ms%@",
                         d * 1000, ms, r.rightOfFocus ? "" : "  (WRONG SIDE)"))
        } else {
            allMoved = false
            print(String(format: "   window appears %4.0fms after launch -> NEVER MOVED within 4s", d * 1000))
        }
        allMoved = allMoved && r.moved
        allRight = allRight && r.rightOfFocus
    }

    let s = samples.sorted()
    func pct(_ p: Double) -> Double { s.isEmpty ? 0 : s[min(s.count - 1, Int(p / 100 * Double(s.count)))] }
    let mean = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
    print(String(format: "\n   flash  mean=%.0f  p50=%.0f  p95=%.0f  max=%.0f ms",
                 mean, pct(50), pct(95), s.last ?? 0))

    var t = TestCounter()
    t.check("every cold-start window eventually moved into the strip", allMoved)
    t.check("every cold-start window landed right of focus", allRight)
    // Target: the user should never see a window sit misplaced for more than ~2
    // frames (~33ms). This is the regression guard the fix must satisfy.
    t.check(String(format: "worst-case flash <= 50ms (got %.0f)", s.last ?? 0), (s.last ?? 0) <= 50)
    t.check(String(format: "p95 flash <= 33ms (got %.0f)", pct(95)), pct(95) <= 33)

    print("\n[coldstartflashheadless] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}

