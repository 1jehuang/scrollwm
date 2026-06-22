import Foundation
import ApplicationServices
import AppKit

/// End-to-end keybinding test against the REAL production controller.
///
/// This is the closest thing to a user: it spawns disposable windows, runs the
/// actual ScrollWMController, Arranges (which registers the real Alt/Cmd
/// hotkeys + the Cmd+H/L keyboard tap), then SYNTHESIZES the exact key combos
/// and verifies the strip reacted. Finally it Releases (which restores windows
/// and tears down the hotkeys) and confirms teardown.
///
/// Run with: `WindowLab e2etest`  (requires Accessibility permission)
func runE2EKeybindingTest() {
    guard AXSource.isTrusted else {
        print("e2etest: needs Accessibility permission. Grant it and re-run.")
        exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // Build the real controller (installs the always-on ctrl+opt hotkeys).
    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    DispatchQueue.global().async {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }
        func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
            let src = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
            down?.flags = flags
            let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
            up?.flags = flags
            down?.post(tap: .cgSessionEventTap)
            usleep(20_000)
            up?.post(tap: .cgSessionEventTap)
        }

        print("[e2e] spawning 4 test windows...")
        let spawned = spawnTestWindows(count: 4)
        Thread.sleep(forTimeInterval: 1.5)
        let pids = Set(spawned.map { $0.processIdentifier })

        print("[e2e] arranging (scoped to test windows)...")
        DispatchQueue.main.sync { controller.arrange(pidFilter: pids) }
        Thread.sleep(forTimeInterval: 0.6)
        check("controller is managing", controller.isManaging)
        check("4 columns in strip", controller.debugSlotCount == 4)

        // --- Alt+2 -> 50% width on focused column (Carbon hotkey) ---
        let focusTitle = controller.debugFocusedTitle
        postKey(19, flags: .maskAlternate) // key '2'
        Thread.sleep(forTimeInterval: 0.4)
        let want50 = controller.debugWidth(forFraction: 0.5)
        let got = controller.debugFocusedWidth
        check("Alt+2 set focused width to ~50% (want \(Int(want50)), got \(Int(got)))", abs(got - want50) <= 6)

        // --- Cmd+L -> move focused column right (keyboard tap) ---
        let order0 = controller.debugSlotTitles
        postKey(37, flags: .maskCommand) // key 'l'
        Thread.sleep(forTimeInterval: 0.4)
        let order1 = controller.debugSlotTitles
        check("Cmd+L moved focused column right",
              order1.count == order0.count && order1.firstIndex(of: focusTitle) == 1)

        // --- Cmd+H -> move it back left (keyboard tap) ---
        postKey(4, flags: .maskCommand) // key 'h'
        Thread.sleep(forTimeInterval: 0.4)
        let order2 = controller.debugSlotTitles
        check("Cmd+H moved focused column back left", order2.firstIndex(of: focusTitle) == 0)

        // --- Cmd+Q -> close focused window (Carbon hotkey) ---
        let liveBefore = pids.flatMap { p -> [AXWindowInfo] in
            guard let a = NSRunningApplication(processIdentifier: p) else { return [] }
            return AXSource.windows(for: a)
        }.count
        postKey(12, flags: .maskCommand) // key 'q'
        Thread.sleep(forTimeInterval: 0.7)
        check("Cmd+Q dropped a column", controller.debugSlotCount == 3)
        let liveAfter = pids.flatMap { p -> [AXWindowInfo] in
            guard let a = NSRunningApplication(processIdentifier: p) else { return [] }
            return AXSource.windows(for: a)
        }.count
        check("Cmd+Q closed a real window", liveAfter == liveBefore - 1)

        // --- Release: restores + tears down hotkeys ---
        print("[e2e] releasing...")
        DispatchQueue.main.sync { controller.release() }
        Thread.sleep(forTimeInterval: 0.5)
        check("controller stopped managing", !controller.isManaging)

        // After release the Cmd+H tap is gone: a Cmd+H must NOT reach the
        // controller (slot count unchanged). We can't easily observe Hide, but
        // we can confirm the strip is empty and stable.
        check("strip empty after release", controller.debugSlotCount == 0)

        for p in spawned { p.terminate() }
        print("\n[e2e] \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    app.run()
}
