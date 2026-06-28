import Foundation
import ApplicationServices
import AppKit

/// LIVE (real-Accessibility) proof that the COLD-START fast path holds on a real
/// machine. This is the live companion to the headless `coldstarttest` /
/// `coldstartbench`, and the COLD counterpart to `spawnlatency` (which only
/// covers the WARM path: a second window opened in an already-observed process).
///
/// "Cold start" = launching a BRAND-NEW app (a new PID) and timing until its
/// FIRST window lands in its strip slot. A new process's first window is created
/// BEFORE its `kAXWindowCreated` observer could ever be attached (that observer
/// is registered off `NSWorkspace.didLaunchApplication`, which fires AFTER the
/// window already exists), so the first window never rides the warm create path.
/// Pre-optimization it waited for the ~0.5s launch-resync or the 2s safety-net
/// poll - the visible "new app floats at its native spot, then snaps in."
///
/// The fix (see `WindowEventObserver`'s cold-start branch + `LifecycleMonitor`'s
/// `onAppLaunched` -> `fastAdopt(pids:coldStart:true)`): on `didLaunchApplication`
/// the observer is registered IMMEDIATELY and a bounded progressive fast-adopt
/// (`coldStartRetryDelays`, ~1.8s budget, under the 2s poll) runs for that pid,
/// landing the first window as fast as a warm one. This test drives that EXACT
/// production path against live AX and asserts the window lands fast.
///
/// GOLDEN RULE: like `spawnlatency` / `newwintest`, this builds its OWN engine +
/// monitor and is hard-scoped to the disposable PIDs it spawns (the monitor's
/// `pidFilter`), so it can NEVER enumerate or move the user's real windows. The
/// monitor is given a deliberately SLOW 5s poll, so any sub-second adoption we
/// observe is PROOF the launch fast path fired, not the safety-net poll. Every
/// launch handler is itself pid-filtered, so even the launch notification we post
/// below can only ever act on our disposable pids.
///
/// Why we POST the launch notification: the disposable `testwindow` helper runs
/// as an `.accessory` app, and macOS does not reliably post
/// `didLaunchApplication` for accessory/background processes. To exercise the
/// real cold-start path deterministically we post the SAME notification macOS
/// posts for a real app launch (with the new pid's `NSRunningApplication` in
/// `userInfo`), exactly as the headless `coldstartbench` does. The production
/// handlers (`WindowEventObserver.onAppLaunched` -> register + cold fast-adopt,
/// and the monitor's launch-resync) then run byte-for-byte as they would live.
///
/// Run with: `WindowLab coldstartlive`  (requires Accessibility permission)
func runColdStartLiveTest() {
    guard AXSource.isTrusted else {
        print("coldstartlive: needs Accessibility permission. Grant it and re-run.")
        exit(2)
    }
    // The production controller refuses to arrange while the session is locked
    // (AX returns nothing then); fail fast with a clear message so a locked-
    // screen / headless-agent run is never mistaken for a logic regression.
    guard LifecycleMonitor.sessionIsActive() else {
        print("coldstartlive: session is locked/inactive (screen locked). "
              + "Unlock the Mac and re-run - live AX adoption is disabled while locked.")
        exit(2)
    }
    // Redirect crash-recovery to the sandbox subdir so this test's own restore
    // file can never clobber/recover the user's real session.
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    DispatchQueue.global().async {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        // --- Seed: one disposable window in its OWN process; adopt + narrow it
        // to 25% so the cold newcomer has room to the RIGHT (no scroll needed).
        print("[coldstartlive] spawning seed window...")
        let seed = spawnTestWindows(count: 1)
        Thread.sleep(forTimeInterval: 1.2)
        let seedPids = Set(seed.map { $0.processIdentifier })

        let screen = NSScreen.main!.visibleFrame
        let axFrame = CGRect(x: screen.origin.x,
                             y: NSScreen.main!.frame.height - screen.maxY,
                             width: screen.width, height: screen.height)
        let engine = TeleportEngine(screenFrame: axFrame)

        func cleanupAndExit(_ code: Int32) -> Never {
            DispatchQueue.main.sync { _ = engine.releaseAll() }
            for p in seed where p.isRunning { p.terminate() }
            RestoreStore.clear()
            exit(code)
        }

        let seedAX = seedPids.flatMap { AXSource.windows(forPID: $0) }
        let matched = IdentityMatcher.match(
            axWindows: seedAX,
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        ).filter { seedPids.contains($0.ax.pid) }
        DispatchQueue.main.sync { engine.adopt(matched: matched); engine.focus(index: 0) }
        check("seed adopted", engine.slots.count == 1)
        guard engine.slots.count == 1 else {
            print("[coldstartlive] seed window never became adoptable; aborting")
            cleanupAndExit(1)
        }
        DispatchQueue.main.sync { _ = engine.setFocusedWidth(fraction: 0.25) }
        Thread.sleep(forTimeInterval: 0.2)

        // --- Monitor with a DELIBERATELY SLOW poll (5s): any sub-second adoption
        // proves the LAUNCH fast path, not the safety-net poll. Hard-scoped to the
        // seed pid for now; we widen it to the new pid the instant we spawn it
        // (BEFORE its launch notification is processed), so the cold-start fast
        // path is allowed to act on it. The filter also keeps every enumeration
        // confined to disposable pids - the user's real windows are never read.
        let monitor = LifecycleMonitor(engine: engine, interval: 5.0)
        DispatchQueue.main.sync {
            monitor.pidFilter = seedPids
            monitor.start()
        }
        // Let the AX observers + launch-notification hooks attach.
        Thread.sleep(forTimeInterval: 0.4)

        // The seed column's slot index BEFORE the launch: the cold window must
        // land to its RIGHT (a higher canvasX slot, the niri/PaperWM contract).
        let seedCanvasX: CGFloat = DispatchQueue.main.sync {
            engine.slots.first { seedPids.contains($0.window.pid) }?.canvasX ?? 0
        }
        let startCount = DispatchQueue.main.sync { engine.slots.count }

        // --- COLD START: launch a BRAND-NEW process (new PID). We learn its pid
        // synchronously from the Process handle the instant `run()` returns, then
        // widen the monitor's pidFilter to include it BEFORE any launch handling,
        // so the cold-start fast path (onAppLaunched -> fastAdopt(coldStart:true))
        // is scoped to it. t0 is the spawn instant: we measure the full, honest
        // cold-start latency (process spin-up + adoption), which must still beat
        // the 5s poll by a wide margin.
        print("[coldstartlive] launching a BRAND-NEW process (cold start)...")
        let t0 = Clock.nowAbsNs()
        let cold = spawnTestWindows(count: 1)
        let newPids = Set(cold.map { $0.processIdentifier })
        DispatchQueue.main.sync { monitor.pidFilter = seedPids.union(newPids) }

        // Drive the REAL production cold-start path: resolve the new process's
        // NSRunningApplication (it registers a beat after fork/exec), then post
        // the SAME `didLaunchApplication` notification macOS posts for a real app
        // launch. This fires `WindowEventObserver.onAppLaunched` ->
        // `register(app:)` + `fastAdopt(coldStart:true)` and the monitor's
        // launch-resync, exactly as live. Pure additive insurance for the
        // accessory-app case; if macOS also posts it naturally, the second post is
        // harmless (the fast path no-ops once the window is managed).
        DispatchQueue.global().async {
            var runningApp: NSRunningApplication?
            let resolveDeadline = Clock.nowAbsNs() + 3_000_000_000
            while Clock.nowAbsNs() < resolveDeadline {
                if let newPid = newPids.first,
                   let a = NSRunningApplication(processIdentifier: newPid), !a.isTerminated {
                    runningApp = a; break
                }
                usleep(10_000)
            }
            guard let runningApp else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.notificationCenter.post(
                    name: NSWorkspace.didLaunchApplicationNotification,
                    object: NSWorkspace.shared,
                    userInfo: [NSWorkspace.applicationUserInfoKey: runningApp])
            }
        }

        // --- Measure: time-to-final-position is the instant the new window's LIVE
        // AX frame reaches the EXACT slot the engine assigned it (its on-screen
        // target), to the right of the seed. Matching the live frame to the engine
        // target (not merely "x greater than the seed") avoids a false positive
        // from the window's native spawn position and proves it was truly
        // teleported INTO the strip.
        var adoptedNs: UInt64?
        var placedNs: UInt64?
        var landedRightOfSeed = false
        let deadline = Clock.nowAbsNs() + 6_000_000_000 // 6s hard cap (> the 5s poll)
        while Clock.nowAbsNs() < deadline {
            let snap: (count: Int, landed: Bool, rightOfSeed: Bool) = DispatchQueue.main.sync {
                let count = engine.slots.count
                guard let slot = engine.slots.first(where: { newPids.contains($0.window.pid) })
                else { return (count, false, false) }
                let target = engine.onScreenTarget(for: slot)
                let rightOfSeed = slot.canvasX > seedCanvasX
                guard let live = AXSource.copyPoint(slot.window.element, kAXPositionAttribute as String)
                else { return (count, false, rightOfSeed) }
                let landed = abs(live.x - target.x) <= 8 && abs(live.y - target.y) <= 8
                return (count, landed, rightOfSeed)
            }
            if adoptedNs == nil && snap.count > startCount { adoptedNs = Clock.nowAbsNs() }
            if adoptedNs != nil && snap.landed {
                landedRightOfSeed = snap.rightOfSeed
                placedNs = Clock.nowAbsNs(); break
            }
            usleep(2_000) // 2ms
        }

        if let adoptedNs {
            let adoptMs = Double(adoptedNs &- t0) / 1e6
            check("cold-start window adopted into the strip", true)
            check("strip grew by exactly one column",
                  DispatchQueue.main.sync { engine.slots.count } == startCount + 1)
            check(String(format: "cold-start adoption < 1500ms (launch fast path, not the 5s poll) [%.0fms]", adoptMs),
                  adoptMs < 1500)
            if let placedNs {
                let placeMs = Double(placedNs &- t0) / 1e6
                print(String(format: "[coldstartlive] COLD start: adopted in %.0f ms, reached its strip slot in %.0f ms",
                             adoptMs, placeMs))
                check("cold-start window teleported to its strip slot (live frame == engine target)", true)
                check("cold-start window landed to the RIGHT of the seed column", landedRightOfSeed)
                check(String(format: "cold-start final-position latency < 1500ms (beats the 5s poll) [%.0fms]", placeMs),
                      placeMs < 1500)
            } else {
                print(String(format: "[coldstartlive] adopted in %.0f ms but its live frame never reached the engine target", adoptMs))
                check("cold-start window teleported to its strip slot (live frame == engine target)", false)
            }
        } else {
            print("[coldstartlive] cold-start window was NEVER adopted within 6s")
            check("cold-start window adopted into the strip", false)
        }

        // Cleanup: restore frames we touched, then SIGTERM every spawned process.
        DispatchQueue.main.sync { monitor.stop(); _ = engine.releaseAll() }
        for p in seed where p.isRunning { p.terminate() }
        for p in cold where p.isRunning { p.terminate() }
        RestoreStore.clear()

        print("\n[coldstartlive] \(passed) passed, \(failed) failed (live cold-start, real AX)")
        exit(failed == 0 ? 0 : 1)
    }

    app.run()
}
