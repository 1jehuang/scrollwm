import Foundation
import ApplicationServices
import AppKit

/// Measures how long it takes the strip to ADOPT a brand-new window opened in
/// an already-running app, exercising the real `LifecycleMonitor` (AX observer
/// + poll). This is the regression guard for the new-window latency bug: before
/// the `WindowEventObserver` fast path, adoption waited for the 2-second poll;
/// after it, adoption happens in tens of milliseconds.
///
/// Faithful model of the common case: a helper process opens one window and is
/// adopted + observed. Then we signal it (SIGUSR1) to open a SECOND window in
/// that SAME process - exactly "open another window in an app the strip already
/// manages". The `kAXWindowCreated` observer for that pid should fire and drive
/// adoption long before the (deliberately slow) safety-net poll.
///
/// Run with: `WindowLab spawnlatency`  (requires Accessibility permission)
func runSpawnLatencyTest() {
    guard AXSource.isTrusted else {
        print("spawnlatency: needs Accessibility permission. Grant it and re-run.")
        exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    DispatchQueue.global().async {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        print("[spawnlatency] spawning seed window...")
        let seed = spawnTestWindows(count: 1)
        Thread.sleep(forTimeInterval: 1.2)
        let seedPids = Set(seed.map { $0.processIdentifier })

        // Build a real engine + monitor and adopt the seed window.
        let screen = NSScreen.main!.visibleFrame
        let axFrame = CGRect(x: screen.origin.x,
                             y: NSScreen.main!.frame.height - screen.maxY,
                             width: screen.width, height: screen.height)
        let engine = TeleportEngine(screenFrame: axFrame)

        let seedAX = seedPids.flatMap { pid -> [AXWindowInfo] in
            guard let a = NSRunningApplication(processIdentifier: pid) else { return [] }
            return AXSource.windows(for: a)
        }
        let matched = IdentityMatcher.match(
            axWindows: seedAX,
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        ).filter { seedPids.contains($0.ax.pid) }
        DispatchQueue.main.sync { engine.adopt(matched: matched) }
        check("seed adopted", engine.slots.count == 1)

        // Make the seed column narrow (25%) so a new window has room to the
        // right and the strip does NOT need to scroll/move existing columns.
        DispatchQueue.main.sync { _ = engine.setFocusedWidth(fraction: 0.25) }
        Thread.sleep(forTimeInterval: 0.2)

        // Monitor with a deliberately SLOW poll so we measure the AX observer
        // fast path, not the safety-net poll. The observer registers on the
        // seed pid (set via pidFilter), so a NEW window in that process fires
        // kAXWindowCreated and should be adopted well before this 5s poll.
        let monitor = LifecycleMonitor(engine: engine, interval: 5.0)
        monitor.pidFilter = seedPids
        DispatchQueue.main.sync { monitor.start() }
        // Give the observer a moment to attach before we trigger the event.
        Thread.sleep(forTimeInterval: 0.4)

        // Open a SECOND window inside the already-observed seed process.
        print("[spawnlatency] opening a NEW window in the already-managed app...")
        let startCount = DispatchQueue.main.sync { engine.slots.count }
        let commitsBefore = DispatchQueue.main.sync { engine.totalCommits }
        // The frame the new window must land to the RIGHT of: the focused
        // column's current live position. "Final destination = right of focus"
        // is the contract we care about, so we time until the new window's REAL
        // AX frame actually reaches a slot to the right of that, not merely until
        // the engine adopts it.
        let focusedXBefore: CGFloat = DispatchQueue.main.sync {
            guard engine.slots.indices.contains(engine.focusIndex) else { return 0 }
            let el = engine.slots[engine.focusIndex].window.element
            return AXSource.copyPoint(el, kAXPositionAttribute as String)?.x ?? 0
        }
        let seedElsBefore = Set(seedPids.flatMap { AXSource.windows(forPID: $0).map { $0.element } })
        let t0 = Clock.nowAbsNs()
        for p in seed { kill(p.processIdentifier, SIGUSR1) }

        // Find the newly created AX element (the one absent before the spawn),
        // then read its live frame to detect when it reaches its strip slot.
        func newElement() -> AXUIElement? {
            seedPids.flatMap { AXSource.windows(forPID: $0) }
                .first { info in !seedElsBefore.contains(where: { CFEqual($0, info.element) }) }?
                .element
        }

        var adoptedNs: UInt64?
        var placedNs: UInt64?
        let deadline = Clock.nowAbsNs() + 6_000_000_000 // 6s hard cap
        while Clock.nowAbsNs() < deadline {
            let count = DispatchQueue.main.sync { engine.slots.count }
            if adoptedNs == nil && count > startCount { adoptedNs = Clock.nowAbsNs() }
            // Time-to-final-position: the new window's live AX frame sits to the
            // right of where the focused column was. This is the instant it stops
            // looking like it is "floating" at its native spawn spot.
            if adoptedNs != nil,
               let el = newElement(),
               let x = AXSource.copyPoint(el, kAXPositionAttribute as String)?.x,
               x > focusedXBefore + 1 {
                placedNs = Clock.nowAbsNs(); break
            }
            usleep(2_000) // 2ms
        }

        if let adoptedNs {
            let adoptMs = Double(adoptedNs &- t0) / 1e6
            // Let the focus/teleport pass for the new window settle.
            Thread.sleep(forTimeInterval: 0.15)
            let commitsAfter = DispatchQueue.main.sync { engine.totalCommits }
            let delta = commitsAfter - commitsBefore
            if let placedNs {
                let placeMs = Double(placedNs &- t0) / 1e6
                print(String(format: "[spawnlatency] adopted in %.0f ms, reached final position (right of focus) in %.0f ms, %d AX commit(s)",
                             adoptMs, placeMs, delta))
                check("new window reached its final position right of focus", true)
                check("final-position latency < 1000ms (AX observer fast path, not poll)", placeMs < 1000)
            } else {
                print(String(format: "[spawnlatency] adopted in %.0f ms but never confirmed right-of-focus placement", adoptMs))
                check("new window reached its final position right of focus", false)
            }
            check("new window adopted", true)
            // Efficiency: the new window has room to the right, so ONLY it
            // should move. The existing seed column must not be re-committed.
            check("adoption committed only the new window (<= 1 move, got \(delta))", delta <= 1)
        } else {
            check("new window adopted", false)
        }

        // --- Close latency: close the new window and time the gap closing. ---
        // The poll is 5s, so adoption-removal under ~1s proves the destroy
        // observer (kAXUIElementDestroyed) drove it, not the poll.
        let countBeforeClose = DispatchQueue.main.sync { engine.slots.count }
        if countBeforeClose >= 2 {
            print("[spawnlatency] closing the new window...")
            let tc0 = Clock.nowAbsNs()
            for p in seed { kill(p.processIdentifier, SIGUSR2) }
            var closedNs: UInt64?
            let cdeadline = Clock.nowAbsNs() + 6_000_000_000
            while Clock.nowAbsNs() < cdeadline {
                let count = DispatchQueue.main.sync { engine.slots.count }
                if count < countBeforeClose { closedNs = Clock.nowAbsNs(); break }
                usleep(5_000)
            }
            if let closedNs {
                let ms = Double(closedNs &- tc0) / 1e6
                print(String(format: "[spawnlatency] gap closed in %.0f ms", ms))
                check("closed window removed", true)
                check("close latency < 1000ms (destroy observer, not poll)", ms < 1000)
            } else {
                check("closed window removed", false)
            }
        }

        DispatchQueue.main.sync { monitor.stop(); engine.releaseAll() }
        for p in seed { p.terminate() }

        print("\n[spawnlatency] \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    app.run()
}
