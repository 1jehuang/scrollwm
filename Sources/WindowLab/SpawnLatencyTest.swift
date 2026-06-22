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
        let t0 = Clock.nowAbsNs()
        for p in seed { kill(p.processIdentifier, SIGUSR1) }

        var adoptedNs: UInt64?
        let deadline = Clock.nowAbsNs() + 6_000_000_000 // 6s hard cap
        while Clock.nowAbsNs() < deadline {
            let count = DispatchQueue.main.sync { engine.slots.count }
            if count > startCount { adoptedNs = Clock.nowAbsNs(); break }
            usleep(5_000) // 5ms
        }

        if let adoptedNs {
            let ms = Double(adoptedNs &- t0) / 1e6
            print(String(format: "[spawnlatency] adopted in %.0f ms", ms))
            check("new window adopted", true)
            // Old poll-only path: up to ~2000ms (default interval). Here the
            // poll is 5000ms, so anything under ~1000ms proves the AX observer
            // fast path drove the adoption, not the poll.
            check("adoption latency < 1000ms (AX observer fast path, not poll)", ms < 1000)
        } else {
            check("new window adopted", false)
        }

        DispatchQueue.main.sync { monitor.stop(); engine.releaseAll() }
        for p in seed { p.terminate() }

        print("\n[spawnlatency] \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    app.run()
}
