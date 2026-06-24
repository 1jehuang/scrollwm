import Foundation
import AppKit

// Unbuffered stdout: progress lines must appear immediately even when piped.
setbuf(stdout, nil)

// WindowLab: reality-test harness for the scrolling window manager.
//
// Subcommands:
//   probe    - Milestone 1: enumerate CG + AX windows, match identities, report latency
//   bench    - Milestone 2: AX move/resize benchmark (restores all windows afterwards)
//   watch    - repeated probe loop, prints timing each second (for stability testing)

func runProbe(verbose: Bool) {
    let recorder = LatencyRecorder()

    // CG enumeration (repeat to get stable latency numbers).
    var cgWindows: [CGWindowInfo] = []
    for _ in 0..<10 {
        cgWindows = recorder.measure("cg.listWindows.onscreen") {
            CGWindowSource.listWindows(onscreenOnly: true)
        }
    }
    let manageable = cgWindows.filter { $0.looksManageable }

    print("CG windows: \(cgWindows.count) total, \(manageable.count) look manageable")

    let cgTitlesVisible = manageable.contains { ($0.title?.isEmpty == false) }
    if !cgTitlesVisible {
        print("note: CG window titles are empty -> Screen Recording permission not granted (matching uses PID+frame only)")
    }

    // AX enumeration.
    guard AXSource.isTrusted else {
        print("\nAX: NOT TRUSTED. Grant Accessibility permission to this binary, then re-run.")
        print("   System Settings -> Privacy & Security -> Accessibility")
        _ = AXSource.promptForTrustIfNeeded()
        exit(2)
    }

    let axWindows = recorder.measure("ax.allWindows.total") {
        AXSource.allWindows(recorder: recorder)
    }
    print("AX windows: \(axWindows.count) across regular apps")

    // Identity matching.
    let matched = recorder.measure("match.ax-cg") {
        IdentityMatcher.match(axWindows: axWindows, cgWindows: cgWindows)
    }
    let matchedCount = matched.filter { $0.cg != nil }.count
    print("Matched: \(matchedCount)/\(matched.count) AX windows fused to CG windows")

    if verbose {
        print("\n== Window table ==")
        for m in matched {
            let cgID = m.cg.map { String($0.windowID) } ?? "-"
            let flags = [
                m.ax.isMinimized ? "min" : nil,
                m.ax.isFullscreen ? "fs" : nil,
                m.ax.subrole == kAXStandardWindowSubrole as String ? nil : (m.ax.subrole ?? "?")
            ].compactMap { $0 }.joined(separator: ",")
            print(String(
                format: "  %-20@ cg=%-8@ score=%-3d  %4.0fx%-4.0f @ (%5.0f,%5.0f)  %@ %@",
                String(m.ax.appName.prefix(20)) as NSString,
                cgID as NSString,
                m.matchScore,
                m.ax.frame.width, m.ax.frame.height,
                m.ax.frame.origin.x, m.ax.frame.origin.y,
                String((m.ax.title ?? "").prefix(40)) as NSString,
                flags.isEmpty ? "" : "[\(flags)]" as NSString
            ))
        }
    }

    recorder.printSummary(title: "Latency")
}

func runBench() {
    guard AXSource.isTrusted else {
        print("AX: NOT TRUSTED. Grant Accessibility permission first (run `probe`).")
        exit(2)
    }
    let recorder = LatencyRecorder()
    let cgWindows = CGWindowSource.listWindows(onscreenOnly: true)
    let axWindows = AXSource.allWindows()
    let matched = IdentityMatcher.match(axWindows: axWindows, cgWindows: cgWindows)

    print("Benchmarking AX move/resize on up to 8 standard windows (5 iterations each).")
    print("All windows will be restored to their original frames.")
    let results = ControlBenchmark.run(matched: matched, recorder: recorder)
    ControlBenchmark.printReport(results)
    recorder.printSummary(title: "Aggregate control latency")

    let unrestored = results.filter { !$0.restored }
    if !unrestored.isEmpty {
        print("\nWARNING: \(unrestored.count) window(s) may not be fully restored:")
        for r in unrestored { print("  - \(r.appName): \(r.title)") }
    }
}

func runWatch(seconds: Int) {
    guard AXSource.isTrusted else {
        print("AX: NOT TRUSTED. Grant Accessibility permission first (run `probe`).")
        exit(2)
    }
    print("Watching for \(seconds)s: full CG+AX resync every second...")
    let recorder = LatencyRecorder()
    for i in 0..<seconds {
        let cycleStart = Clock.nowNs()
        let cg = CGWindowSource.listWindows(onscreenOnly: true)
        let ax = AXSource.allWindows()
        let matched = IdentityMatcher.match(axWindows: ax, cgWindows: cg)
        let elapsed = Double(Clock.nowNs() - cycleStart) / 1_000_000.0
        recorder.record("resync.full", ms: elapsed)
        let matchedCount = matched.filter { $0.cg != nil }.count
        print(String(format: "  [%2ds] resync %6.1f ms  cg=%d ax=%d matched=%d",
                     i + 1, elapsed, cg.count, ax.count, matchedCount))
        Thread.sleep(forTimeInterval: max(0, 1.0 - elapsed / 1000.0))
    }
    recorder.printSummary(title: "Resync latency")
}

// MARK: - Entry point

// Drop a LaunchServices process-serial-number argument: older macOS passes
// `-psn_0_12345` when a .app is launched by double-click, and it is not a
// command. (Modern macOS no longer passes it, but filtering is cheap insurance
// now that the Mach-O is the bundle's main executable - see scripts/make-bundle.sh.)
let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }

// Default command depends on HOW we were launched:
//   - As ScrollWM.app's main executable (Finder / `open` / menu-bar agent),
//     a bare invocation must start the production app (`run`).
//   - As the bare `WindowLab` dev/CLI binary (e.g. `.build/debug/WindowLab`),
//     it defaults to the diagnostic `probe`, preserving the dev workflow.
// We detect the app case via the main bundle's URL ending in `.app`.
let launchedAsAppBundle = Bundle.main.bundleURL.pathExtension == "app"
let command = args.first ?? (launchedAsAppBundle ? "run" : "probe")

// CLI control verbs: talk to a RUNNING ScrollWM app over its control socket.
// These are the user-facing `scrollwm <verb>` commands (see runControlCLI).
let controlVerbs: Set<String> = [
    "status", "arrange", "release", "toggle", "focus", "move", "width",
    "workspace", "ws", "close", "focus-mode", "focusmode", "reload", "reload-config",
    "tutorial", "ping", "quit",
]
if controlVerbs.contains(command) {
    exit(runControlCLI(Array(args)))
}

switch command {
case "probe":
    runProbe(verbose: args.contains("-v") || args.contains("--verbose"))
case "bench":
    runBench()
case "watch":
    let seconds = args.dropFirst().compactMap { Int($0) }.first ?? 10
    runWatch(seconds: seconds)
case "overlay":
    let seconds = args.dropFirst().compactMap { Int($0) }.first ?? 15
    runOverlay(seconds: seconds, selftest: args.contains("--selftest"))
case "scrollbench":
    let numbers = args.dropFirst().compactMap { Int($0) }
    runScrollBench(
        windows: numbers.first ?? 6,
        hz: Double(numbers.dropFirst().first ?? 60),
        spawn: args.contains("--spawn")
    )
case "testwindow":
    runTestWindow(args: Array(args.dropFirst()))
case "pan":
    let numbers = args.dropFirst().compactMap { Int($0) }
    runPan(
        seconds: numbers.first ?? 15,
        windowCount: numbers.dropFirst().first ?? 8,
        spawn: args.contains("--spawn"),
        selftest: args.contains("--selftest")
    )
case "teleport":
    let numbers = args.dropFirst().compactMap { Int($0) }
    runTeleport(
        windowCount: numbers.first ?? 8,
        spawn: args.contains("--spawn"),
        selftestSeconds: args.contains("--selftest") ? (numbers.dropFirst().first ?? 5) : nil
    )
case "capturebench":
    let seconds = args.dropFirst().compactMap { Int($0) }.first ?? 5
    runCaptureBench(seconds: seconds)
case "run":
    runScrollWM(
        selftest: args.contains("--selftest"),
        crashPhase: args.contains("--crashtest") ? .crash : .none
    )
case "sizeprobe":
    let target = args.dropFirst().compactMap { Double($0) }.first.map { CGFloat($0) } ?? 360
    SizeProbe.run(targetWidth: target)
case "cycle":
    runCycleTest()
case "unittest":
    exit(StripOpsTests.run() ? 0 : 1)
case "animtest":
    exit(MenuBarAnimationTests.run() ? 0 : 1)
case "animrender":
    let out = args.dropFirst().first ?? "menubar_anim.png"
    exit(MenuBarAnimationRender.run(outPath: out) ? 0 : 1)
case "opstest":
    runStripOpsIntegrationTest()
case "spawnlatency":
    runSpawnLatencyTest()
case "sandbox":
    let n = args.dropFirst().compactMap { Int($0) }.first ?? 4
    runSandbox(windowCount: n)
case "e2etest":
    runE2EKeybindingTest()
case "hotkeyprobe":
    let seconds = args.dropFirst().compactMap { Int($0) }.first ?? 20
    runHotkeyProbe(seconds: seconds)
case "keytapprobe":
    let seconds = args.dropFirst().compactMap { Int($0) }.first ?? 20
    runKeyTapProbe(seconds: seconds)
default:
    print("""
    ScrollWM / WindowLab

    Control a running ScrollWM from your shell (the app must be running):
      scrollwm status              print strip state as JSON
      scrollwm arrange             adopt current-Space windows (launches app if needed)
      scrollwm release             restore all windows, go dormant
      scrollwm toggle              arrange <-> release
      scrollwm focus <next|prev|left|right|N>
                                   change focused column (N is 1-based)
      scrollwm move <left|right>   move focused column within the strip
      scrollwm move <up|down>      send focused window to the workspace above/below
      scrollwm workspace <up|down|N>
                                   switch vertical workspace (niri-style)
      scrollwm width <25|50|75|100|0.0-1.0>
                                   resize focused column
      scrollwm close               close the focused window
      scrollwm focus-mode [fit|centered]
                                   get/set how the viewport follows focus
      scrollwm reload              re-read the config file live
      scrollwm tutorial            open the in-app cheat sheet
      scrollwm quit                restore windows and quit the app

    Lab / test harness (spawns its own processes; safe):
      WindowLab probe [-v]     enumerate CG+AX windows, match, report latency
      WindowLab bench          AX move/resize benchmark (windows restored after)
      WindowLab watch [secs]   repeated full resync loop with timing
      WindowLab overlay [secs] [--selftest]
                               Metal overlay; ctrl+opt+scroll pans fake canvas.
                               --selftest posts synthetic scrolls and reports latency.
      WindowLab scrollbench [n] [hz] [--spawn]
                               animate n real windows via AX moves, measure jank.
                               --spawn uses disposable test windows (default: your real ones)
      WindowLab pan [secs] [n] [--spawn] [--selftest]
                               v1 slice: ctrl+opt+scroll pans real windows on a
                               virtual canvas with inertia. Windows restored after.
      WindowLab run [--selftest]
                               ScrollWM production app: dormant menu bar agent.
                               Arrange/release via menu, ctrl+opt+esc, or the CLI.
                               Exact frame restore on release/quit/crash.
      WindowLab unittest       pure-logic tests for width/move/close ops (no AX needed)
      WindowLab animtest       pure-logic tests for the animated menu-bar
                               mini-map (Spring physics + action inference)
      WindowLab opstest        integration test: spawn windows, exercise
                               width/move/close via the engine, verify + restore.
      WindowLab spawnlatency   measure how fast a NEW window in a managed app is
                               adopted (AX observer fast path vs poll).
      WindowLab sandbox [n]    run the REAL controller locked to n disposable
                               windows it spawns (default 4). Drive the real
                               hotkeys safely; your real windows are untouched.
      WindowLab e2etest        end-to-end: run the real controller, synthesize
                               Alt+1-4 / Cmd+H / Cmd+L / Cmd+Q, verify effects.
      WindowLab hotkeyprobe [secs]
                               register Alt+1-4 / Cmd+H / Cmd+L / Cmd+Q globally
                               and report which key combos Carbon actually delivers.
    """)
}
