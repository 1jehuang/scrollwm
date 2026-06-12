import Foundation
import AppKit

/// The teleport-tier app: menu bar + hotkeys + instant strip navigation.
/// Permission tiers (each mode checks only what it needs):
///   Tier 0 "teleport":  Accessibility only (hotkeys are permission-free)
///   Tier 1 "pan":       + Input Monitoring (scroll event tap)
///   Tier 2 "cinematic": + Screen Recording (Metal/SCK proxies)  [future]
func runTeleport(windowCount: Int, spawn: Bool, selftestSeconds: Int?) {
    guard AXSource.isTrusted else {
        print("Teleport tier requires exactly one permission: Accessibility.")
        print("System Settings -> Privacy & Security -> Accessibility")
        _ = AXSource.promptForTrustIfNeeded()
        exit(2)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // Visible frame in AX coordinates (top-left origin):
    // AX y = screenHeight - visibleFrame.maxY (menu bar offset).
    guard let screen = NSScreen.main else { exit(1) }
    let vf = screen.visibleFrame
    let axScreenFrame = CGRect(
        x: vf.origin.x,
        y: screen.frame.height - vf.maxY,
        width: vf.width,
        height: vf.height
    )

    // Adopt windows.
    var spawned: [Process] = []
    let matched: [MatchedWindow]
    if spawn {
        print("Spawning \(windowCount) test windows...")
        spawned = spawnTestWindows(count: windowCount)
        Thread.sleep(forTimeInterval: 1.5)
        let pids = Set(spawned.map { $0.processIdentifier })
        let axWindows = pids.flatMap { pid -> [AXWindowInfo] in
            guard let a = NSRunningApplication(processIdentifier: pid) else { return [] }
            return AXSource.windows(for: a)
        }
        matched = IdentityMatcher.match(
            axWindows: axWindows,
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        )
    } else {
        matched = IdentityMatcher.match(
            axWindows: AXSource.allWindows(),
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        )
    }

    let engine = TeleportEngine(screenFrame: axScreenFrame)
    engine.adopt(matched: matched)
    print("Adopted \(engine.slots.count) windows into the strip. First teleport: \(String(format: "%.1f", engine.lastTeleportMs))ms")

    // Menu bar.
    let menuBar = MenuBarController(
        engine: engine,
        onSelectIndex: { engine.focus(index: $0) },
        onQuit: {
            for p in spawned { p.terminate() }
            app.terminate(nil)
        }
    )

    // Hotkeys: ctrl+opt+arrows navigate, ctrl+opt+1..9 jump directly.
    let hotkeys = HotkeyManager()
    hotkeys.install()
    hotkeys.register(.right) { engine.focusNext() }
    hotkeys.register(.left) { engine.focusPrevious() }
    for (i, key) in HotkeyManager.Key.digits.enumerated() {
        hotkeys.register(key) { engine.focus(index: i) }
    }

    // Lifecycle: adopt new windows, drop closed ones.
    let lifecycle = LifecycleMonitor(engine: engine)
    if spawn {
        // Track windows of our test processes only; the set is updated live
        // so lifecycle tests can spawn/kill at will.
        lifecycle.pidFilter = Set(spawned.map { $0.processIdentifier })
    }
    lifecycle.onChange = { adopted, removed in
        print("  lifecycle: +\(adopted) -\(removed) windows (strip now \(engine.slots.count), resync \(String(format: "%.1f", lifecycle.lastResyncMs))ms)")
    }
    lifecycle.start()

    print("""
    Teleport tier running (menu bar mini-map active):
      ctrl+opt+left/right   focus previous/next column
      ctrl+opt+1..9         jump to column N
      menu bar              click any window to jump
    """)

    // Report whether macOS actually gave us menu bar space (notch can hide us).
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        print("  menubar: \(menuBar.debugDescription2)")
    }

    // Selftest: scripted navigation + lifecycle churn, then report and exit.
    if let seconds = selftestSeconds {
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 1.5) // give the status item time to settle
            var menubarOK = false
            DispatchQueue.main.sync {
                print("  menubar: \(menuBar.debugDescription2)")
                menubarOK = menuBar.isVisibleInMenuBar
            }
            let jumps = max(4, seconds * 4)
            print("Selftest: \(jumps) scripted teleports...")
            for i in 0..<jumps {
                let target = (i * 3 + 1) % max(engine.slots.count, 1)
                DispatchQueue.main.sync { engine.focus(index: target) }
                Thread.sleep(forTimeInterval: 0.25)
            }

            // Lifecycle test (spawn mode): kill one window, spawn two new ones,
            // verify the strip converges to count+1.
            var lifecycleOK = true
            if spawn && !spawned.isEmpty {
                let startCount = DispatchQueue.main.sync { engine.slots.count }
                print("Selftest lifecycle: killing 1 window, spawning 2 new...")
                spawned[0].terminate()
                let fresh = spawnTestWindows(count: 2)
                spawned.append(contentsOf: fresh)
                DispatchQueue.main.sync {
                    lifecycle.pidFilter = Set(spawned.filter { $0.isRunning }.map { $0.processIdentifier })
                }
                // Wait for the periodic resync to converge.
                var converged = false
                for _ in 0..<10 {
                    Thread.sleep(forTimeInterval: 1.0)
                    let count = DispatchQueue.main.sync { engine.slots.count }
                    if count == startCount + 1 { converged = true; break }
                }
                let endCount = DispatchQueue.main.sync { engine.slots.count }
                lifecycleOK = converged
                print("  lifecycle: strip \(startCount) -> \(endCount) windows (expected \(startCount + 1)) \(converged ? "OK" : "FAIL")")
            }

            DispatchQueue.main.sync {
                let stats = engine.teleportStats()
                print("\n== Teleport latency (full strip recommit) ==")
                print("  " + stats.summaryRow)
                let unhealthy = engine.slots.filter { !$0.window.healthy }
                print("  unhealthy windows: \(unhealthy.count)/\(engine.slots.count)")
                print("  menubar visible: \(menubarOK)")
                print("  lifecycle: \(lifecycleOK ? "OK" : "FAIL") (resyncs \(lifecycle.resyncCount), adopted \(lifecycle.adoptedCount), removed \(lifecycle.removedCount))")
                for p in spawned { p.terminate() }
                exit(stats.percentile(95) < 100 && unhealthy.isEmpty && menubarOK && lifecycleOK ? 0 : 1)
            }
        }
    }

    app.run()
}
