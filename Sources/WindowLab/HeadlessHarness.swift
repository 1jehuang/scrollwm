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

    // MARK: - Native-Space helpers (Track 5 sim-Space infrastructure)
    //
    // Thin sugar over `SimWindowWorld`'s native-Space API so Space tests stay
    // terse. The sim is the source of truth (`SimWindowWorld.swift`); these only
    // wrap the common "match + adopt the current-Space windows" and "drive the
    // engine's real diff once" steps every Space test repeats.

    /// Fuse the CURRENT-Space AX+CG view exactly as production `arrange` does and
    /// adopt the result into `engine`. Returns the matched current-Space windows.
    /// Because the sim's `cgWindows(onscreenOnly:true)` now omits off-active-Space
    /// windows, only windows on the world's active Space are adopted - mirroring
    /// `arrange`'s on-screen scoping with zero extra test logic.
    ///
    /// Like production `arrange` (`ScrollWMController.arrange` ends in
    /// `engine.focus(index: 0)`), this also FOCUSES column 0, which `teleport`s
    /// every adopted window to its real on-screen target. That matters for any
    /// test that later checks live frames against `engine.onScreenTarget` (e.g.
    /// the `stripIsOnCurrentSpace` fast-adopt gate under a non-zero `peekInset`):
    /// without the teleport the sim windows stay at their spawn X, 48px off the
    /// peek-lane target, and the gate cannot match them. Skipped only when the
    /// adopt found nothing (empty strip), mirroring arrange's early return.
    @discardableResult
    static func arrangeCurrentSpace(_ engine: TeleportEngine,
                                    pids: [pid_t]) -> [MatchedWindow] {
        let ax = pids.flatMap { AXSource.windows(forPID: $0) }
        let matched = IdentityMatcher.match(
            axWindows: ax,
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        ).filter { $0.cg != nil }
        engine.adopt(matched: matched)
        if !engine.slots.isEmpty { engine.focus(index: 0) }
        return matched
    }

    /// Run the SAME pure decision `LifecycleMonitor.applyResync` runs, against the
    /// live engine + sim, so a test can assert the Space-freeze / adopt outcome
    /// without spinning the 2s poll. Returns the planner decision so tests can
    /// distinguish `frozenDifferentSpace` from `apply`. The token mapping mirrors
    /// `applyResync` (LifecycleMonitor.swift): AX index per standard window,
    /// current-Space = windows the on-screen CG list matches.
    @discardableResult
    static func resyncDecision(_ engine: TeleportEngine,
                               pids: [pid_t]) -> ResyncPlanner.Decision {
        let ax = pids.flatMap { AXSource.windows(forPID: $0) }
        let standard = ax.filter { $0.subrole == kAXStandardWindowSubrole as String }
        let cg = CGWindowSource.listWindows(onscreenOnly: true)
        let matched = IdentityMatcher.match(axWindows: standard, cgWindows: cg)
        let axIDs = Array(standard.indices)
        var currentSpaceIDs = Set<Int>()
        for (i, m) in matched.enumerated() where m.cg != nil { currentSpaceIDs.insert(i) }
        let stripIDs: [Int] = engine.allManagedSlots.enumerated().map { (s, slot) in
            standard.firstIndex { CFEqual($0.element, slot.window.element) } ?? -(s + 1)
        }
        return ResyncPlanner.decide(stripIDs: stripIDs, axIDs: axIDs,
                                    currentSpaceIDs: currentSpaceIDs)
    }
}

/// Run EVERY headless integration test as a child process and report a roll-up.
/// Each test ends in `exit()`, so they cannot share one process; spawning child
/// invocations of this same binary keeps each isolated (fresh sim world, fresh
/// controller) while still giving one convenient command. Fully headless: no
/// child ever touches a real window or the keyboard.
func runHeadlessSuite() -> Never {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "WindowLab"
    let verbs = ["opstest", "e2etest", "revealtest", "spawnlatency", "displaytest", "dragofftest", "extadopttest", "parktest", "clamshelltest", "spacetest", "spacedetecttest", "movetest", "fullscreentest", "spacefocustest", "displaymovetest"]
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
