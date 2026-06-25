import Foundation
import ApplicationServices
import AppKit

/// LIVE proof for the [md-newwin] area: ADOPTION SCOPE + NEW-WINDOW landing on a
/// REAL multi-monitor desktop. This is the regression guard for the core
/// multi-display "yank" bug and the new-window adoption path, run end-to-end
/// against live Accessibility on the actual external monitor.
///
/// It exercises the SAME engine glue production uses (`filterByAdoptScope`) via
/// both the initial arrange-equivalent adopt and the real `LifecycleMonitor`
/// fast-adopt (`kAXWindowCreated`) path, asserting against live AX readback:
///
///   (a) NO-YANK: a window already living on the EXTERNAL monitor is NOT adopted
///       by a `stripDisplay`-scoped strip, and its real AX frame is left exactly
///       where it was (arrange never touches it).
///   (b) NEW window opened ON the external is IGNORED (fast path scope-drops it;
///       the strip never grows and the window stays put on the external).
///   (c) NEW window opened on the STRIP display IS adopted fast (the fast path
///       still works - we did not break adoption by adding the scope gate).
///
/// GOLDEN RULE: like `spawnlatency`, this builds its OWN engine + monitor and is
/// hard-scoped to the disposable PIDs it spawns (the monitor's `pidFilter`), so
/// it can never enumerate or move the user's real windows. On a single-display
/// rig it degrades to a clear SKIP (there is no external to leave alone).
///
/// Run with: `WindowLab newwintest`  (requires Accessibility permission)
func runNewWindowAdoptTest() {
    guard AXSource.isTrusted else {
        print("newwintest: needs Accessibility permission. Grant it and re-run.")
        exit(2)
    }
    // The production controller refuses to arrange while the session is locked
    // (AX returns nothing then); fail fast with a clear message so a locked-
    // screen run is never mistaken for a logic regression.
    guard LifecycleMonitor.sessionIsActive() else {
        print("newwintest: session is locked/inactive (screen locked). "
              + "Unlock the Mac and re-run - live AX adoption is disabled while locked.")
        exit(2)
    }
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

        // --- Display geometry in AX top-left global coords (the engine's plane).
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.main!).frame.height
        func axFull(_ s: NSScreen) -> CGRect {
            DisplayGeometry.axFrame(appKitFrame: s.frame, primaryHeight: primaryHeight)
        }
        func axVisible(_ s: NSScreen) -> CGRect {
            DisplayGeometry.axFrame(appKitFrame: s.visibleFrame, primaryHeight: primaryHeight)
        }

        let stripScreen = NSScreen.main!                          // built-in = strip
        guard let extScreen = NSScreen.screens.first(where: { $0 !== stripScreen }) else {
            print("[newwintest] SKIP: only one display connected - no external to leave alone.")
            print("\n[newwintest] 0 passed, 0 failed (single-display: nothing to prove)")
            exit(0)
        }
        let stripFull = axFull(stripScreen)
        let extFull = axFull(extScreen)
        let otherFulls = NSScreen.screens.filter { $0 !== stripScreen }.map(axFull)
        print("[newwintest] strip(built-in)=\(nwRect(stripFull)) external=\(nwRect(extFull))")

        // --- Spawn disposable windows: TWO on the strip display, ONE on the
        // external. Distinct titles so live AX readback is unambiguous.
        let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        func spawn(title: String, on screen: NSScreen, dx: Double, dy: Double,
                   w: Double = 360, h: Double = 280) -> Process {
            // AppKit (bottom-left) coords anchored to the target display's origin.
            let f = screen.frame
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["testwindow",
                           "\(Double(f.origin.x) + dx)", "\(Double(f.origin.y) + dy)",
                           "\(w)", "\(h)", title]
            try? p.run()
            return p
        }
        let bA = spawn(title: "NW-Strip-A", on: stripScreen, dx: 120, dy: 120)
        let bB = spawn(title: "NW-Strip-B", on: stripScreen, dx: 520, dy: 120)
        let xE = spawn(title: "NW-External", on: extScreen, dx: 200, dy: 360)
        let spawned = [bA, bB, xE]
        Thread.sleep(forTimeInterval: 1.6)
        let pids = Set(spawned.map { $0.processIdentifier })

        func liveWindows() -> [AXWindowInfo] {
            pids.flatMap { pid -> [AXWindowInfo] in
                guard let a = NSRunningApplication(processIdentifier: pid), !a.isTerminated else { return [] }
                return AXSource.windows(for: a)
            }.filter { $0.subrole == kAXStandardWindowSubrole as String && !$0.isMinimized && !$0.isFullscreen }
        }
        func liveFrame(_ title: String) -> CGRect? { liveWindows().first { $0.title == title }?.frame }
        func bestIsStrip(_ f: CGRect) -> Bool {
            DisplayGeometry.display(bestOverlapping: f, displays: [stripFull] + otherFulls)
                .map { $0 == stripFull } ?? false
        }

        func cleanupAndExit(_ code: Int32) -> Never {
            for p in spawned where p.isRunning { p.terminate() }
            RestoreStore.clear()
            exit(code)
        }

        // Sanity: the external seed really did land on the external monitor.
        let seen = liveWindows()
        print("[newwintest] live windows: " + seen.map { "\($0.title ?? "?")@\(nwRect($0.frame))" }.joined(separator: " "))
        guard let extBefore = liveFrame("NW-External") else {
            check("external seed window is readable", false); cleanupAndExit(1)
        }
        check("external seed window is really on the external monitor", !bestIsStrip(extBefore))

        // --- Build the engine bound to the STRIP display with the external
        // registered, default `stripDisplay` scope: the exact production config.
        let engine = TeleportEngine(screenFrame: axVisible(stripScreen))
        engine.stripDisplayFrame = stripFull
        engine.otherDisplayFrames = otherFulls
        engine.adoptScope = .stripDisplay

        // ===== Phase A: arrange-equivalent adopt (the yank-bug guard) ==========
        // EXACTLY the controller's arrange scope path: match -> onscreen ->
        // filterByAdoptScope -> adopt. Only the strip-display windows survive.
        let matched = IdentityMatcher.match(
            axWindows: liveWindows(),
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        )
        let onscreen = matched.filter { $0.cg != nil }
        let scoped = engine.filterByAdoptScope(onscreen) { $0.ax.frame }
        DispatchQueue.main.sync { engine.adopt(matched: scoped); engine.focus(index: 0) }
        Thread.sleep(forTimeInterval: 0.6)

        let titlesA = DispatchQueue.main.sync { engine.slots.map { $0.window.title } }
        print("[newwintest] adopted columns: \(titlesA)")
        check("(a) arrange adopts exactly the 2 strip-display windows", engine.slots.count == 2)
        check("(a) external window is NOT adopted (no yank)",
              !titlesA.contains("NW-External"))
        check("(a) both strip-display windows ARE adopted",
              titlesA.contains("NW-Strip-A") && titlesA.contains("NW-Strip-B"))
        // The external window must still be on the external AND not have moved.
        if let extAfter = liveFrame("NW-External") {
            check("(a) external window stayed on the external monitor", !bestIsStrip(extAfter))
            let moved = abs(extAfter.minX - extBefore.minX) + abs(extAfter.minY - extBefore.minY)
            check("(a) external window was left exactly where it was (Δ=\(Int(moved))pt)", moved <= 2)
        } else {
            check("(a) external window readback after arrange", false)
        }

        // Start the REAL lifecycle monitor (scoped to our pids) so the
        // kAXWindowCreated fast path drives the next two phases. Slow poll (5s)
        // so any adoption we observe came from the AX observer, not the poll.
        let monitor = LifecycleMonitor(engine: engine, interval: 5.0)
        monitor.pidFilter = pids
        DispatchQueue.main.sync { monitor.start() }
        Thread.sleep(forTimeInterval: 0.4)

        // ===== Phase B: NEW window opened ON the external is IGNORED ===========
        print("[newwintest] opening a NEW window on the EXTERNAL monitor...")
        let countBeforeB = DispatchQueue.main.sync { engine.slots.count }
        kill(xE.processIdentifier, SIGUSR1)               // opens "NW-External-2" near the external seed
        // Give the observer + coalesce + a generous settle window. It must NOT adopt.
        Thread.sleep(forTimeInterval: 1.5)
        let countAfterB = DispatchQueue.main.sync { engine.slots.count }
        check("(b) new window on the external did NOT grow the strip",
              countAfterB == countBeforeB)
        if let nf = liveFrame("NW-External-2") {
            check("(b) the new external window stayed on the external monitor", !bestIsStrip(nf))
        } else {
            check("(b) new external window readback", false)
        }
        let titlesB = DispatchQueue.main.sync { engine.slots.map { $0.window.title } }
        check("(b) new external window is not on the strip", !titlesB.contains("NW-External-2"))

        // ===== Phase C: NEW window on the STRIP display IS adopted fast ========
        print("[newwintest] opening a NEW window on the STRIP display...")
        let countBeforeC = DispatchQueue.main.sync { engine.slots.count }
        let t0 = Clock.nowAbsNs()
        kill(bA.processIdentifier, SIGUSR1)               // opens "NW-Strip-A-2" on the strip display
        var adoptedNs: UInt64?
        let deadline = Clock.nowAbsNs() + 4_000_000_000
        while Clock.nowAbsNs() < deadline {
            let count = DispatchQueue.main.sync { engine.slots.count }
            if count > countBeforeC { adoptedNs = Clock.nowAbsNs(); break }
            usleep(5_000)
        }
        if let adoptedNs {
            let ms = Double(adoptedNs &- t0) / 1e6
            print(String(format: "[newwintest] strip-display window adopted in %.0f ms", ms))
            check("(c) new strip-display window WAS adopted", true)
            check("(c) adoption used the fast path, not the 5s poll (\(Int(ms))ms < 1500)", ms < 1500)
            Thread.sleep(forTimeInterval: 0.2)
            if let sf = liveFrame("NW-Strip-A-2") {
                check("(c) the adopted window is on the strip display", bestIsStrip(sf))
            }
        } else {
            check("(c) new strip-display window WAS adopted", false)
        }

        // Final invariant: the external window is STILL not on the strip after
        // everything (no late yank from a poll tick).
        Thread.sleep(forTimeInterval: 0.3)
        let finalTitles = DispatchQueue.main.sync { engine.slots.map { $0.window.title } }
        check("external windows never entered the strip (final check)",
              !finalTitles.contains("NW-External") && !finalTitles.contains("NW-External-2"))

        DispatchQueue.main.sync { monitor.stop(); engine.releaseAll() }
        for p in spawned where p.isRunning { p.terminate() }
        RestoreStore.clear()
        print("\n[newwintest] \(passed) passed, \(failed) failed (live 2-display hardware)")
        exit(failed == 0 ? 0 : 1)
    }

    app.run()
}

private func nwRect(_ r: CGRect) -> String {
    String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
}
