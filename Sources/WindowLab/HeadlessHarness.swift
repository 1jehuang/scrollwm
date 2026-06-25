import Foundation
import ApplicationServices
import AppKit

/// Shared helpers for the HEADLESS integration tests. These run the EXACT
/// production engine/controller logic against an in-memory `SimWindowWorld`
/// (installed as `AXSource.backend`), so they:
///   - spawn NO real windows,
///   - never move/resize/focus/close a real window,
///   - never inject a real global keystroke,
/// and therefore never steal focus or disturb the user's desktop.
///
/// A small test-result accumulator keeps the per-test bodies terse and uniform.
struct TestCounter {
    private(set) var passed = 0
    private(set) var failed = 0
    mutating func check(_ name: String, _ cond: Bool) {
        if cond { passed += 1; print("  \u{2713} \(name)") }
        else { failed += 1; print("  \u{2717} \(name)") }
    }
    var summaryExitCode: Int32 { failed == 0 ? 0 : 1 }
}

enum Headless {
    /// Install a fresh sim world as the global backend. Returns it so the test
    /// can seed/inspect windows. Idempotent per test process.
    static func install(displays: [CGRect] = []) -> SimWindowWorld {
        let world = SimWindowWorld()
        world.displays = displays
        AXSource.backend = world
        return world
    }

    static func uninstall() { AXSource.backend = nil }

    /// A simple single-display AX geometry (top-left origin) for tests that do
    /// not care about multi-display: a 1600x1000 strip at the origin, with a
    /// small menu-bar inset so the visible frame differs from the full frame.
    static let defaultFullFrame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    static let defaultVisibleFrame = CGRect(x: 0, y: 32, width: 1600, height: 968)

    /// Seed `count` disposable sim windows, one per fake pid, tiled left-to-right
    /// across the strip's visible frame. Returns (pids, elements) in order.
    @discardableResult
    static func seedWindows(_ world: SimWindowWorld, count: Int,
                            startPID: pid_t = 5000,
                            within frame: CGRect = Headless.defaultVisibleFrame,
                            width: CGFloat = 360, height: CGFloat = 420,
                            minSize: CGSize = .zero,
                            titlePrefix: String = "SimWin")
        -> (pids: [pid_t], elements: [AXUIElement]) {
        var pids: [pid_t] = []
        var els: [AXUIElement] = []
        for i in 0..<count {
            let pid = startPID + pid_t(i)
            let x = frame.minX + 40 + CGFloat(i) * (width + 20)
            let el = world.addWindow(
                pid: pid,
                title: "\(titlePrefix)-\(i)",
                frame: CGRect(x: x, y: frame.minY + 40, width: width, height: height),
                minSize: minSize
            )
            pids.append(pid)
            els.append(el)
        }
        return (pids, els)
    }

    /// Pump the main run loop briefly so async work (DispatchQueue.main hops the
    /// engine/monitor schedule: focus reconcile, fast-adopt coalescing, the
    /// sim's create/destroy events) drains before the test asserts. Pure time on
    /// the main run loop; no windows, no sleeps that block AX.
    static func pump(_ seconds: TimeInterval = 0.12) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

/// Run EVERY headless integration test as a child process and report a roll-up.
/// Each test ends in `exit()`, so they cannot share one process; spawning child
/// invocations of this same binary keeps each isolated (fresh sim world, fresh
/// controller) while still giving one convenient command. Fully headless: no
/// child ever touches a real window or the keyboard.
func runHeadlessSuite() -> Never {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "WindowLab"
    let verbs = ["opstest", "e2etest", "revealtest", "spawnlatency", "displaytest"]
    var failures = 0
    for verb in verbs {
        print("\n========== headless \(verb) ==========")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = [verb] // headless is the default (no --live)
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { failures += 1 }
        } catch {
            print("failed to launch \(verb): \(error)")
            failures += 1
        }
    }
    print("\n========================================")
    print(failures == 0
          ? "ALL headless integration tests PASSED (\(verbs.count) suites)"
          : "\(failures)/\(verbs.count) headless suites FAILED")
    exit(failures == 0 ? 0 : 1)
}

