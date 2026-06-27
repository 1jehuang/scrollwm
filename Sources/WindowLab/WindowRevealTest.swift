import Foundation
import ApplicationServices
import AppKit

/// Integration test for "arrange includes hidden & minimized windows".
///
/// Spawns disposable windows, MINIMIZES some of them, then drives the REAL
/// production controller (hard-locked to the spawned pids via `sandboxPIDs`):
///
///   1. A plain `arrange` now REVEALS the minimized windows first, then adopts
///      EVERYTHING - so every spawned window ends up on the strip.
///   2. `arrangeAllWindows` does the same and additionally equalizes the columns
///      so the whole desktop is visible at once.
///
/// Restores + terminates the spawned windows at the end.
///
/// Run with: `WindowLab revealtest`  (requires Accessibility permission)
func runWindowRevealTest() {
    guard AXSource.isTrusted else {
        print("revealtest: needs Accessibility permission. Grant it and re-run.")
        exit(2)
    }
    // Isolate crash-recovery state from the real ScrollWM session.
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // Real controller, LOCKED to the spawned pids (cannot touch real windows).
    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    DispatchQueue.global().async {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        let total = 4
        let minimizeCount = 2
        print("[revealtest] spawning \(total) test windows...")
        let spawned = spawnTestWindows(count: total)
        Thread.sleep(forTimeInterval: 1.5)
        let pids = Set(spawned.map { $0.processIdentifier })
        controller.sandboxPIDs = pids

        func liveWindows() -> [AXWindowInfo] {
            pids.flatMap { pid -> [AXWindowInfo] in
                guard let a = NSRunningApplication(processIdentifier: pid), !a.isTerminated else { return [] }
                return AXSource.windows(for: a)
            }
        }

        // Minimize the first `minimizeCount` spawned windows via AX.
        let all = liveWindows().sorted { ($0.title ?? "") < ($1.title ?? "") }
        guard all.count == total else {
            print("[revealtest] expected \(total) windows, saw \(all.count); aborting")
            for p in spawned { p.terminate() }
            exit(1)
        }
        for w in all.prefix(minimizeCount) {
            _ = AXSource.setBool(w.element, kAXMinimizedAttribute as String, true)
        }
        Thread.sleep(forTimeInterval: 0.8)
        let minimizedNow = liveWindows().filter { $0.isMinimized }.count
        check("minimized \(minimizeCount) windows up front", minimizedNow == minimizeCount)

        // --- Plain arrange: now REVEALS minimized windows and adopts ALL ---
        DispatchQueue.main.sync { controller.arrange() }
        // arrange reveals (animated ~0.45s) then resyncs to pull the revealed
        // windows in; give it room.
        Thread.sleep(forTimeInterval: 1.4)
        check("plain arrange reveals + adopts every window incl. minimized (\(total))",
              controller.debugSlotCount == total)
        check("no spawned window left minimized after plain arrange",
              liveWindows().allSatisfy { !$0.isMinimized })

        // Release so arrangeAllWindows starts from dormant, like the menu action.
        DispatchQueue.main.sync { controller.release() }
        Thread.sleep(forTimeInterval: 0.5)
        check("released back to dormant", !controller.isManaging)
        // Re-minimize (release restored the windows but they were already visible;
        // minimized ones stay minimized - ensure the precondition still holds).
        for w in liveWindows().sorted(by: { ($0.title ?? "") < ($1.title ?? "") }).prefix(minimizeCount) {
            _ = AXSource.setBool(w.element, kAXMinimizedAttribute as String, true)
        }
        Thread.sleep(forTimeInterval: 0.6)

        // --- Arrange All: reveals minimized windows, then adopts EVERYTHING ---
        DispatchQueue.main.sync { controller.arrangeAllWindows() }
        // arrangeAllWindows reveals (animated ~0.45s) then adopts; give it room.
        Thread.sleep(forTimeInterval: 1.6)
        check("arrange all adopts every window incl. minimized (\(total))",
              controller.debugSlotCount == total)
        check("no spawned window left minimized after arrange all",
              liveWindows().allSatisfy { !$0.isMinimized })

        // --- Cleanup ---
        DispatchQueue.main.sync { if controller.isManaging { controller.release() } }
        Thread.sleep(forTimeInterval: 0.4)
        for p in spawned where p.isRunning { p.terminate() }
        RestoreStore.clear()

        print("\n[revealtest] \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    app.run()
}
