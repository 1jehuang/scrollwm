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

// Internal: the detached bundle-swapper for in-app updates. Runs from a
// throwaway COPY of our binary (so it isn't executing inside the bundle it is
// replacing), waits for the old app to exit, atomically swaps + relaunches.
// Handled before anything else so it never touches AppKit / the control plane.
if command == "__update-swap" {
    exit(InstallSwap.runSwapper(Array(args.dropFirst())))
}
if command == "__update-selftest" {
    exit(runUpdateSelfTest(Array(args.dropFirst())))
}

// `scrollwm logs` is handled LOCALLY (no running app / socket needed): it prints
// the log file path, or tails / follows it. Kept out of the socket verb set so
// it works even when the app is dormant or stopped.
if command == "logs" {
    exit(runLogsCLI(Array(args.dropFirst())))
}

// `scrollwm --version` / `-V` prints the running binary's marketing version and
// exits, WITHOUT contacting a running app over the control socket. This works
// even when ScrollWM is dormant, stopped, or not installed - the version is
// baked into the bundle's Info.plist by scripts/make-bundle.sh (from VERSION),
// so a bare CLI binary reports the dev sentinel. (The `version` verb below is a
// separate, JSON capability handshake that DOES require a running app.)
if command == "--version" || command == "-V" {
    print("ScrollWM \(AppVersion.currentString)")
    exit(0)
}

// CLI control verbs: talk to a RUNNING ScrollWM app over its control socket.
// These are the user-facing `scrollwm <verb>` commands (see runControlCLI).
let controlVerbs: Set<String> = [
    "status", "version", "hello", "arrange", "release", "toggle", "focus", "move", "width",
    "workspace", "ws", "close", "display", "focus-mode", "focusmode", "reload", "reload-config",
    "tutorial", "skills", "proficiency", "login", "launch-at-login", "update", "update-check", "ping", "quit",
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
        hz: Double(numbers.dropFirst().first ?? 60)
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
case "updatecheck":
    // Dev helper: run the LIVE GitHub update check directly (no running app).
    // `--install` additionally stages + applies it if this is an installed app.
    exit(runUpdateCheckCLI(install: args.contains("--install"),
                           allowPrerelease: args.contains("--prerelease")))
case "animtest":
    exit(MenuBarAnimationTests.run() ? 0 : 1)
case "animrender":
    let out = args.dropFirst().first ?? "menubar_anim.png"
    exit(MenuBarAnimationRender.run(outPath: out) ? 0 : 1)
case "opstest":
    args.contains("--live") ? runStripOpsIntegrationTest() : runHeadlessOpsTest()
case "spawnlatency":
    args.contains("--live") ? runSpawnLatencyTest() : runHeadlessSpawnLatencyTest()
case "spawnvalidate":
    // Headless property validator: EVERY spawn (across a named edge-case matrix
    // + randomized fuzz) must land in the column right of focus, at its exact
    // slot, via the fast path - never left floating, never poll-speed.
    runSpawnValidate(args: Array(args))
case "newwintest":
    runNewWindowAdoptTest()
case "statusbench":
    let n = args.dropFirst().compactMap { Int($0) }.first ?? 24
    runStatusItemBench(steps: n)
case "sandbox":
    // `--display N` (0-based, left-to-right) spawns the sandbox on a specific
    // monitor; the Int right after the flag is its index. Default = main display.
    var sandboxDisplay: Int? = nil
    var sandboxDisplayValueIdx: Int? = nil
    if let di = args.firstIndex(of: "--display") {
        sandboxDisplayValueIdx = di + 1
        sandboxDisplay = args.indices.contains(di + 1) ? Int(args[di + 1]) : nil
    }
    // Window count = first bare integer that is NOT the --display value.
    let n = args.enumerated().dropFirst()
        .compactMap { (i, a) in i == sandboxDisplayValueIdx ? nil : Int(a) }
        .first ?? 4
    runSandbox(windowCount: n, displayIndex: sandboxDisplay)
case "displaytest":
    args.contains("--live") ? runDisplayTest() : runHeadlessDisplayTest()
case "dragofftest":
    // Headless external-monitor "drag-off" test: a managed column the user drags
    // onto another display is EVICTED (left where they put it) instead of being
    // yanked back, while a merely-parked column is never evicted. Always headless.
    runHeadlessDragOffTest()
case "extadopttest":
    // Headless external-monitor adoption test: single strip (multiDisplay=false,
    // stripDisplay scope) adopts ONLY built-in windows and leaves the external
    // alone on arrange / fast-adopt / resync. Always headless.
    runHeadlessExternalAdoptTest()
case "parktest":
    // Headless external-monitor parking test: a parked column's clamp sliver
    // stays on the strip's own display and never spills onto the external, for
    // both the real above-left layout and a side-by-side rearrangement.
    runHeadlessParkTest()
case "exthotplugtest":
    // Headless external-monitor hotplug test: unplug/replug the above-left
    // external while the strip is on the built-in (strip stays put), and unplug
    // the built-in (strip migrates to the external). Always headless.
    runHeadlessExternalHotplugTest()
case "displaybindcheck":
    runDisplayBindCheck()
case "e2etest":
    args.contains("--live") ? runE2EKeybindingTest() : runHeadlessE2ETest()
case "revealtest":
    args.contains("--live") ? runWindowRevealTest() : runHeadlessRevealTest()
case "spacetest":
    // Headless native-Space membership + switching test (Track 5 sim-Space
    // infra). Always headless: never touches a real window/Space/keyboard.
    runHeadlessSpaceTest()
case "spacedetecttest":
    // Headless Space-change DETECTION/SIGNAL test (Track 1): proves the strip
    // is STALE after a native Space switch with no signal, and that an
    // activeSpaceDidChange-style hook collapses the gap to one signal-fast
    // resync. Always headless: never touches a real window/Space/keyboard.
    runHeadlessSpaceDetectionTest()
case "movetest":
    // Headless window-MOVEMENT-across-Spaces + lifecycle/removal test (Track 4):
    // phantom columns when a managed window is sent to another Space, parking-
    // sliver vs native-Space switch, oscillation storms, and the peekInset-
    // robust fast-adopt gate. Always headless: never touches a real window.
    runHeadlessMovementTest()
case "fullscreentest":
    // Headless native-FULLSCREEN / Mission Control / separate-Spaces test
    // (Track 3): a managed window entering macOS fullscreen leaves the current
    // Space (its own dedicated Space); proves the phantom-strand vs whole-strip-
    // freeze split, the fullscreen-Space spurious-adopt seed, and that returning
    // re-converges. Always headless: never touches a real window/Space/keyboard.
    runHeadlessFullscreenTest()
case "spacefocustest":
    // Headless Space focus-GUARD test (P2a): focusing a strip column whose window
    // was sent to another native Space must NOT activate its app (which would
    // teleport the user across Spaces). Always headless: never touches a real
    // window/Space/keyboard.
    runHeadlessSpaceFocusGuardTest()
case "displaymovetest":
    // Headless MULTI-DISPLAY focus/move test: the new Ctrl+Opt+Cmd+J/K (focus
    // the next/prev monitor's strip) and Ctrl+Opt+Cmd+Shift+J/K (send the
    // focused window to another monitor + follow) verbs. Drives the REAL
    // controller's per-display strips against the sim. Never touches a real
    // window/monitor/keyboard.
    runHeadlessDisplayMoveTest()
case "clamshelltest":
    // Headless CLAMSHELL / equal-display repro: drives the REAL controller's
    // settled-display-change path through a laptop-lid-close transition (built-in
    // primary turns off, an external becomes the new AppKit-origin primary) with
    // two EQUAL 1440p externals + a sleep/wake burst. Asserts the strip follows
    // its own display by stable id, never oscillates, and keeps every window
    // on-screen with finite geometry. Always headless: no real window/monitor.
    runClamshellTest()
case "headlesstest":
    // Run EVERY headless integration test in one child-process sweep, so a
    // single command verifies the whole suite without touching the desktop.
    runHeadlessSuite()
case "fuzz":
    // Seeded, reproducible property-based fuzzing of the real engine + pure
    // logic against the in-memory sim world. Fully headless: never touches a
    // real window or the keyboard. A failure prints the seed + replayable op log.
    runFuzz(args: Array(args))
case "fuzzconc":
    // Concurrency/lifecycle fuzzer (async stack: monitor poll + fast-adopt +
    // reconcile + run-loop hops). Headless. See FuzzConcurrency.swift.
    runFuzzConcurrency(args: Array(args))
case "fuzzmodel":
    // Differential model-oracle fuzzer: an independent reference model vs the
    // real engine, after every random op. Headless. See FuzzModel.swift.
    runFuzzModel(args: Array(args))
case "fuzzctrl":
    // Controller/config/control-socket fuzzer (untrusted-input surface).
    // Headless. See FuzzController.swift.
    runFuzzController(args: Array(args))
case "fuzzdisp":
    // Multi-display/geometry/restore fuzzer (hotplug + parking + restore).
    // Headless. See FuzzDisplay.swift.
    runFuzzDisplay(args: Array(args))
case "statespace":
    // Bounded exhaustive / explicit-state model checking: BFS over the engine
    // state machine (shortest counterexample) + exhaustive pure decision tables.
    // Deterministic, headless. See StateSpace.swift.
    runStateSpace(args: Array(args))
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
      scrollwm display <next|main|primary|largest|N>
                                   move the scrolling strip to another monitor
      scrollwm focus-mode [fit|centered]
                                   get/set how the viewport follows focus
      scrollwm reload              re-read the config file live
      scrollwm skills              report core keybindings you've stopped using
      scrollwm login [on|off]      start ScrollWM automatically at login (get/set)
      scrollwm update [--install]  check GitHub for a newer release (and install it)
      scrollwm tutorial            open the in-app cheat sheet
      scrollwm logs [--tail N|--follow|--path|--clear]
                                   show the app log (~/Library/Logs/ScrollWM/)
      scrollwm --version           print the installed ScrollWM version
      scrollwm quit                restore windows and quit the app

    Lab / test harness (spawns its own processes; safe):
      WindowLab probe [-v]     enumerate CG+AX windows, match, report latency
      WindowLab bench          AX move/resize benchmark (windows restored after)
      WindowLab watch [secs]   repeated full resync loop with timing
      WindowLab overlay [secs] [--selftest]
                               Metal overlay; ctrl+opt+scroll pans fake canvas.
                               --selftest posts synthetic scrolls and reports latency.
      WindowLab scrollbench [n] [hz]
                               animate n disposable test windows via AX moves,
                               measure jank. Headless: always spawns its own
                               throwaway windows; never touches your real ones.
      WindowLab pan [secs] [n] [--spawn] [--selftest]
                               v1 slice: ctrl+opt+scroll pans real windows on a
                               virtual canvas with inertia. Windows restored after.
      WindowLab run [--selftest]
                               ScrollWM production app: dormant menu bar agent.
                               Arrange/release via menu, ctrl+opt+esc, or the CLI.
                               Exact frame restore on release/quit/crash.
      WindowLab unittest       pure-logic tests for width/move/close ops (no AX needed)
      WindowLab updatecheck [--install] [--prerelease] [--stage-only]
                               check GitHub Releases for a newer ScrollWM (pure
                               network; --stage-only downloads+verifies+extracts
                               without self-replacing, for CI/dev validation).
      WindowLab animtest       pure-logic tests for the animated menu-bar
                               mini-map (Spring physics + action inference)
      WindowLab headlesstest   run ALL integration suites (ops/e2e/reveal/
                               spawnlatency/display) HEADLESS: the real engine +
                               controller logic runs against an in-memory window
                               world. No real window is spawned/moved/focused/
                               closed and no global keystroke is injected, so it
                               never touches your screen or focus. Safe to run
                               anytime, even while you work.
      WindowLab fuzz [seed] [--steps N] [--seeds K] [--iters M]
                               [--engine-only | --pure-only] [--replay SEED]
                               seeded, reproducible property-based fuzzing of the
                               real engine + pure logic against the in-memory sim
                               world. Drives long random op sequences and asserts
                               model invariants after every step (compactness,
                               focus/workspace bounds, finite geometry, no dup
                               windows, model==reality width). HEADLESS: never
                               touches your screen or focus. A failure prints the
                               seed + full op log; --replay <seed> re-runs it.
      WindowLab fuzzmodel [seed] [--steps N] [--seeds K] [--replay SEED]
                               DIFFERENTIAL fuzz: an independent reference model
                               of the strip vs the real engine, checked after
                               every random op (catches semantic order/focus/
                               workspace/viewport bugs, not just crashes).
      WindowLab fuzzctrl [seed] [--iters N] [--runs K --ops M] [--replay SEED]
                               fuzz the untrusted-input surface: JSONC config
                               parse, Chord/width parsing, and random chord +
                               control-command sequences through a real headless
                               controller. Asserts state stays coherent.
      WindowLab fuzzdisp [seed] [--seeds K] [--iters M]
                               fuzz multi-display hotplug (resolver + rebind),
                               parking-corner policy, adoption-scope/geometry,
                               and restore round-trips under unplugged monitors.
      WindowLab fuzzconc [seed] [--seeds K] [--steps N]
                               fuzz the async stack (LifecycleMonitor poll +
                               fast-adopt + reconcile) with interleaved timed
                               window events, pumping the run loop between steps.
                               Slower (real timing); keep budgets modest.
      WindowLab statespace [--max-visited N] [--max-depth D] [--max-windows W]
                               [--engine-only | --pure-only]
                               BOUNDED EXHAUSTIVE state-space checking: a BFS
                               over the engine state machine that visits every
                               reachable logical state (deduped) up to a bound
                               and reports the SHORTEST op sequence to any
                               invariant violation, plus exhaustive decision-
                               table proofs of ResyncPlanner / parking corner /
                               DisplaySelector / SemVer ordering. Deterministic
                               and headless.
      WindowLab opstest        integration test for width/move/close/focus-sync.
                               HEADLESS by default (in-memory windows). Pass
                               --live to exercise REAL spawned windows instead.
      WindowLab spawnlatency   new-window adoption latency (AX-observer fast path
                               vs poll). HEADLESS by default; --live for real AX.
      WindowLab newwintest     multi-display adoption scope: spawn windows on the
                               strip AND on the external, then prove (live AX) the
                               external windows are LEFT ALONE (no yank) while a
                               new window on the strip display is adopted fast.
                               Skips cleanly on single-display hardware.
      WindowLab displaybindcheck
                               live check of the strip-move bind path: verify the
                               primary-height Y-flip lands the strip on the right
                               display (incl. a non-primary external). Spawns its
                               own disposable windows; restores them after.
      WindowLab sandbox [n] [--display M]
                               run the REAL controller locked to n disposable
                               windows it spawns (default 4). Drive the real
                               hotkeys safely; your real windows are untouched.
                               --display M tiles them on monitor M (0-based,
                               left-to-right) so you can sandbox on an external.
      WindowLab e2etest        end-to-end keybinding test (Alt+1-4 / Cmd+H/L/Q /
                               workspaces). HEADLESS by default: chords are
                               delivered to the real binding tables with NO
                               CGEvent injected. Pass --live for real windows +
                               synthesized keystrokes.
      WindowLab revealtest     "Arrange All reveals + adopts hidden/minimized".
                               HEADLESS by default; --live for real windows.
      WindowLab displaytest    multi-display integration: strip windows land on
                               the strip display, the off-screen parking sliver
                               stays on the strip display (not a neighbor), and a
                               strip rebind moves windows onto the other display.
                               HEADLESS by default (synthetic 2-display world);
                               --live runs against your real monitors.
      WindowLab clamshelltest  CLAMSHELL / equal-display repro: drives the real
                               controller through a laptop-lid-close transition
                               (built-in primary turns off, an external becomes
                               the new primary) with two equal 1440p externals + a
                               sleep/wake burst. Asserts the strip follows its own
                               display by stable id, never oscillates, keeps every
                               window on-screen, and that a redundant display
                               change issues NO window resizes (no "glitching").
                               Always headless: no real window/monitor.
      WindowLab hotkeyprobe [secs]
                               register Alt+1-4 / Cmd+H / Cmd+L / Cmd+Q globally
                               and report which key combos Carbon actually delivers.
    """)
}
