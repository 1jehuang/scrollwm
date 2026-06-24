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
        postKey(19, flags: .maskAlternate) // key '2'
        Thread.sleep(forTimeInterval: 0.4)
        let want50 = controller.debugWidth(forFraction: 0.5)
        let got = controller.debugFocusedWidth
        check("Alt+2 set focused width to ~50% (want \(Int(want50)), got \(Int(got)))", abs(got - want50) <= 6)

        // --- Cmd+1 -> 25% width on focused column (keyboard tap) ---
        postKey(18, flags: .maskCommand) // key '1'
        Thread.sleep(forTimeInterval: 0.4)
        let want25 = controller.debugWidth(forFraction: 0.25)
        let got25 = controller.debugFocusedWidth
        check("Cmd+1 set focused width to ~25% (want \(Int(want25)), got \(Int(got25)))", abs(got25 - want25) <= 6)

        // --- Cmd+4 -> 100% width on focused column (keyboard tap) ---
        postKey(21, flags: .maskCommand) // key '4'
        Thread.sleep(forTimeInterval: 0.4)
        let want100b = controller.debugWidth(forFraction: 1.0)
        let got100 = controller.debugFocusedWidth
        check("Cmd+4 set focused width to ~100% (want \(Int(want100b)), got \(Int(got100)))", abs(got100 - want100b) <= 6)

        // --- Cmd+L -> focus next column (keyboard tap) ---
        // Start focus at column 0, then Cmd+L should advance to column 1.
        DispatchQueue.main.sync { controller.focus(index: 0) }
        Thread.sleep(forTimeInterval: 0.2)
        postKey(37, flags: .maskCommand) // key 'l'
        Thread.sleep(forTimeInterval: 0.4)
        check("Cmd+L focused next column (index 1)", controller.debugFocusIndex == 1)

        // --- Cmd+H -> focus previous column (keyboard tap) ---
        postKey(4, flags: .maskCommand) // key 'h'
        Thread.sleep(forTimeInterval: 0.4)
        check("Cmd+H focused previous column (index 0)", controller.debugFocusIndex == 0)

        // --- Cmd+Shift+L -> move focused column right (keyboard tap) ---
        let focusTitle = controller.debugFocusedTitle
        let order0 = controller.debugSlotTitles
        postKey(37, flags: [.maskCommand, .maskShift]) // Cmd+Shift+L
        Thread.sleep(forTimeInterval: 0.4)
        let order1 = controller.debugSlotTitles
        check("Cmd+Shift+L moved focused column right",
              order1.count == order0.count && order1.firstIndex(of: focusTitle) == 1)

        // --- Cmd+Shift+H -> move it back left (keyboard tap) ---
        postKey(4, flags: [.maskCommand, .maskShift]) // Cmd+Shift+H
        Thread.sleep(forTimeInterval: 0.4)
        let order2 = controller.debugSlotTitles
        check("Cmd+Shift+H moved focused column back left", order2.firstIndex(of: focusTitle) == 0)

        // --- Cmd+J -> switch to a new vertical workspace below (keyboard tap) ---
        // Start with all 4 windows on workspace 1, focus column 0.
        DispatchQueue.main.sync { controller.focus(index: 0) }
        Thread.sleep(forTimeInterval: 0.2)
        let wsCountBefore = controller.debugWorkspaceCount
        let colsBefore = controller.debugSlotCount
        postKey(38, flags: .maskCommand) // key 'j'
        Thread.sleep(forTimeInterval: 0.4)
        check("Cmd+J switched to workspace 2 (index 1)", controller.debugActiveWorkspace == 1)
        check("Cmd+J created a new empty workspace", controller.debugWorkspaceCount == wsCountBefore + 1)
        check("Cmd+J new workspace is empty", controller.debugSlotCount == 0)

        // --- Cmd+K -> switch back UP to the original workspace (keyboard tap) ---
        postKey(40, flags: .maskCommand) // key 'k'
        Thread.sleep(forTimeInterval: 0.4)
        check("Cmd+K switched back to workspace 1 (index 0)", controller.debugActiveWorkspace == 0)
        check("Cmd+K restored the original columns", controller.debugSlotCount == colsBefore)
        check("Cmd+K pruned the empty trailing workspace",
              controller.debugWorkspaceCount == wsCountBefore)

        // --- Cmd+Shift+J -> send focused window down to a new workspace + follow ---
        let sendTitle = controller.debugFocusedTitle
        postKey(38, flags: [.maskCommand, .maskShift]) // Cmd+Shift+J
        Thread.sleep(forTimeInterval: 0.4)
        check("Cmd+Shift+J followed window to workspace 2", controller.debugActiveWorkspace == 1)
        check("Cmd+Shift+J destination holds the sent window", controller.debugSlotCount == 1)
        check("Cmd+Shift+J sent the focused window", controller.debugFocusedTitle == sendTitle)
        // Go back up so the close/release checks below run against the main strip.
        postKey(40, flags: .maskCommand) // Cmd+K
        Thread.sleep(forTimeInterval: 0.4)
        check("back on workspace 1 after workspace tests", controller.debugActiveWorkspace == 0)
        check("workspace 1 has the remaining columns", controller.debugSlotCount == colsBefore - 1)
        // Re-focus column 0 for a deterministic close target.
        DispatchQueue.main.sync { controller.focus(index: 0) }
        Thread.sleep(forTimeInterval: 0.2)

        // --- Cmd+Q -> close focused window (Carbon hotkey) ---
        let colsBeforeClose = controller.debugSlotCount
        let liveBefore = pids.flatMap { p -> [AXWindowInfo] in
            guard let a = NSRunningApplication(processIdentifier: p) else { return [] }
            return AXSource.windows(for: a)
        }.count
        postKey(12, flags: .maskCommand) // key 'q'
        Thread.sleep(forTimeInterval: 0.7)
        check("Cmd+Q dropped a column", controller.debugSlotCount == colsBeforeClose - 1)
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
