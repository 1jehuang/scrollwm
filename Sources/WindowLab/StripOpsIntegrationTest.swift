import Foundation
import ApplicationServices
import AppKit

/// Integration test for the focused-window operations. Spawns disposable test
/// windows, adopts them into a real TeleportEngine, then drives width/move/close
/// and verifies the effect against live Accessibility readback. Survivors are
/// restored to their original frames at the end.
///
/// Run with: `WindowLab opstest`  (requires Accessibility permission)
func runStripOpsIntegrationTest() {
    guard AXSource.isTrusted else {
        print("opstest: needs Accessibility permission. Grant it and re-run.")
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

        print("[opstest] spawning 4 test windows...")
        let spawned = spawnTestWindows(count: 4)
        Thread.sleep(forTimeInterval: 1.5)
        let pids = Set(spawned.map { $0.processIdentifier })

        // Live AX readback helpers, scoped to our spawned windows.
        func liveWindows() -> [AXWindowInfo] {
            pids.flatMap { pid -> [AXWindowInfo] in
                guard let a = NSRunningApplication(processIdentifier: pid), !a.isTerminated else { return [] }
                return AXSource.windows(for: a)
            }
        }
        func liveSize(title: String) -> CGSize? {
            liveWindows().first { $0.title == title }?.frame.size
        }

        // Build a real engine and adopt only our test windows.
        let screen = NSScreen.main!.visibleFrame
        let axFrame = CGRect(x: screen.origin.x,
                             y: NSScreen.main!.frame.height - screen.maxY,
                             width: screen.width, height: screen.height)
        let engine = TeleportEngine(screenFrame: axFrame)
        let ax = liveWindows()
        let matched = IdentityMatcher.match(
            axWindows: ax,
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        ).filter { pids.contains($0.ax.pid) }
        DispatchQueue.main.sync { engine.adopt(matched: matched) }
        Thread.sleep(forTimeInterval: 0.4)
        check("adopted 4 test windows", engine.slots.count == 4)
        guard engine.slots.count == 4 else {
            print("[opstest] adoption failed, aborting"); for p in spawned { p.terminate() }; exit(1)
        }

        // --- WIDTH: set focused to 25%, verify real window resized ---
        engine.focusIndex = 0
        let focusTitle0 = engine.slots[0].window.title
        let want25 = engine.width(forFraction: 0.25)
        DispatchQueue.main.sync { _ = engine.setFocusedWidth(fraction: 0.25) }
        Thread.sleep(forTimeInterval: 0.3)
        if let live = liveSize(title: focusTitle0) {
            check("width 25%: real window width ≈ requested (\(Int(want25)))", abs(live.width - want25) <= 6)
        } else { check("width 25%: live readback available", false) }

        // 100% width
        let want100 = engine.width(forFraction: 1.0)
        DispatchQueue.main.sync { _ = engine.setFocusedWidth(fraction: 1.0) }
        Thread.sleep(forTimeInterval: 0.3)
        if let live = liveSize(title: focusTitle0) {
            check("width 100%: real window width ≈ requested (\(Int(want100)))", abs(live.width - want100) <= 6)
        } else { check("width 100%: live readback available", false) }
        check("strip compact after resizes", StripOpsTests.isCompact(engine))

        // --- MIN-SIZE CLAMP: a window with a hard minimum (like Apple Music)
        // refuses to shrink below it, yet AX reports success. The model MUST
        // track the real (clamped) width, not the request, or the strip layout
        // corrupts. We spawn a dedicated window with a large contentMinSize and
        // adopt a fresh engine over just it.
        let bigMin = 900.0
        let clampProc = spawnTestWindowWithMin(width: 1000, height: 600, minWidth: bigMin, title: "MinWidthApp")
        Thread.sleep(forTimeInterval: 1.5)
        let clampPid = clampProc.processIdentifier
        func clampWindows() -> [AXWindowInfo] {
            guard let a = NSRunningApplication(processIdentifier: clampPid), !a.isTerminated else { return [] }
            return AXSource.windows(for: a)
        }
        let clampEngine = TeleportEngine(screenFrame: axFrame)
        let clampMatched = IdentityMatcher.match(
            axWindows: clampWindows(),
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        ).filter { $0.ax.pid == clampPid }
        DispatchQueue.main.sync { clampEngine.adopt(matched: clampMatched) }
        Thread.sleep(forTimeInterval: 0.4)
        if clampEngine.slots.count == 1 {
            // Ask for a width that is BELOW the window's hard minimum.
            let requested = clampEngine.width(forFraction: 0.25)
            check("min-clamp: requested width is below the window minimum", requested < bigMin)
            DispatchQueue.main.sync { _ = clampEngine.setFocusedWidth(fraction: 0.25) }
            Thread.sleep(forTimeInterval: 0.3)
            let liveClamped = clampWindows().first?.frame.size.width ?? 0
            // The real window stays at its minimum; the model must match the
            // real width (within AX rounding), NOT the smaller request.
            check("min-clamp: real window did not shrink below its minimum", liveClamped >= bigMin - 6)
            check("min-clamp: model width matches the real (clamped) width",
                  abs(clampEngine.slots[0].width - liveClamped) <= 6)
            check("min-clamp: model did NOT store the (smaller) requested width",
                  clampEngine.slots[0].width > requested + 6)
            check("min-clamp: strip stays compact", StripOpsTests.isCompact(clampEngine))
            DispatchQueue.main.sync { _ = clampEngine.releaseAll() }
        } else {
            check("min-clamp: adopted the min-width window", false)
        }
        clampProc.terminate()

        // --- MOVE: reorder focused column right, verify model order ---
        engine.focusIndex = 0
        let before = engine.slots.map { $0.window.title }
        DispatchQueue.main.sync { _ = engine.moveFocused(by: 1) }
        Thread.sleep(forTimeInterval: 0.2)
        let after = engine.slots.map { $0.window.title }
        check("move right swapped first two columns",
              after.count == before.count && after[0] == before[1] && after[1] == before[0])
        check("focus follows moved window", engine.slots[engine.focusIndex].window.title == before[0])
        check("strip compact after move", StripOpsTests.isCompact(engine))

        // --- CLOSE: close focused window, verify it disappears for real ---
        let closeTitle = engine.slots[engine.focusIndex].window.title
        let liveCountBefore = liveWindows().count
        DispatchQueue.main.sync { _ = engine.closeFocused() }
        Thread.sleep(forTimeInterval: 0.6)
        check("close: dropped from strip", engine.slots.count == 3)
        check("close: gone from strip model", engine.slots.allSatisfy { $0.window.title != closeTitle })
        let liveCountAfter = liveWindows().count
        check("close: real window count dropped", liveCountAfter == liveCountBefore - 1)
        check("strip compact after close", StripOpsTests.isCompact(engine))

        // --- RESTORE survivors ---
        print("[opstest] restoring survivors...")
        DispatchQueue.main.sync { _ = engine.releaseAll() }
        Thread.sleep(forTimeInterval: 0.4)

        // Clean up any windows still alive.
        for p in spawned { p.terminate() }

        print("\n[opstest] \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    app.run()
}

/// Interactive probe: registers the management hotkeys globally and prints a
/// line every time one fires. This is how we verify, on real hardware, whether
/// Carbon RegisterEventHotKey actually delivers the system-reserved Cmd+Q /
/// Cmd+H combos (macOS may route them to the focused app instead).
///
/// Run with: `WindowLab hotkeyprobe [secs]`, then press the combos.
func runHotkeyProbe(seconds: Int) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let hk = HotkeyManager()
    hk.install()

    var fired: [String: Int] = [:]
    func mark(_ label: String) {
        fired[label, default: 0] += 1
        print("  fired: \(label)  (count \(fired[label]!))")
    }

    let registrations: [(String, HotkeyManager.Key, UInt32)] = [
        ("Alt+1", .one, HotkeyManager.opt),
        ("Alt+2", .two, HotkeyManager.opt),
        ("Alt+3", .three, HotkeyManager.opt),
        ("Alt+4", .four, HotkeyManager.opt),
        ("Cmd+H", .h, HotkeyManager.cmd),
        ("Cmd+L", .l, HotkeyManager.cmd),
        ("Cmd+Q", .q, HotkeyManager.cmd),
    ]
    print("[hotkeyprobe] registering \(registrations.count) hotkeys...")
    for (label, key, mods) in registrations {
        let id = hk.register(key, modifiers: mods) { mark(label) }
        print("  \(label): \(id != nil ? "registered (id \(id!))" : "REGISTRATION FAILED")")
    }
    print("""
    [hotkeyprobe] press the combos now. Reporting in \(seconds)s.
      NOTE: Cmd+Q/Cmd+H are system/app shortcuts; if they DON'T fire here,
      Carbon hotkeys are insufficient and we need an event tap instead.
    """)

    DispatchQueue.global().async {
        Thread.sleep(forTimeInterval: TimeInterval(seconds))
        print("\n[hotkeyprobe] results:")
        for (label, _, _) in registrations {
            print("  \(label): \(fired[label, default: 0]) press(es) delivered")
        }
        exit(0)
    }
    app.run()
}
