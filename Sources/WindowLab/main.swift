import Foundation
import AppKit

// Unbuffered stdout: progress lines must appear immediately even when piped.
setbuf(stdout, nil)

// Never let a broken control-socket pipe kill us. The running app hosts the
// control server in THIS process; if a `scrollwm` CLI client disconnects mid
// reply (e.g. Ctrl-C during a large `status`), the server's `write()` to the
// dead peer would otherwise raise SIGPIPE and terminate the whole window
// manager, dropping the user's managed layout. With SIGPIPE ignored, `write()`
// returns EPIPE and our write loops handle it gracefully. (Also protects the
// short-lived CLI client process itself.)
signal(SIGPIPE, SIG_IGN)

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

// How a BARE invocation (no subcommand) behaves depends on HOW we were reached:
//   - As ScrollWM.app's main executable (Finder/`open`/login agent): start the
//     production app (`run`).
//   - Via the user-facing `scrollwm` CLI shim - a symlink INTO the app bundle
//     (e.g. /opt/homebrew/bin/scrollwm). Here `launchedAsAppBundle` is false
//     (Bundle.main points at the symlink's dir), but the user is exploring the
//     CLI, so print `help` rather than the `probe` window-title dump.
//   - As the bare dev `WindowLab` binary (.build/debug/WindowLab): keep the
//     diagnostic `probe` default for the dev workflow.
let invokedViaBundleSymlink = !launchedAsAppBundle && executableResolvesIntoAppBundle()
let defaultBareCommand = launchedAsAppBundle ? "run" : (invokedViaBundleSymlink ? "help" : "probe")
let command = args.first ?? defaultBareCommand

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

// Explicit help: `scrollwm --help|-h|help` prints usage to stdout and exits 0.
// This is a real, documented command (not an accident of the `default:` arm),
// so it is distinguishable from a typo'd verb (which exits non-zero below).
if command == "--help" || command == "-h" || command == "help" {
    print(scrollwmHelpText())
    exit(0)
}

// CLI control verbs: talk to a RUNNING ScrollWM app over its control socket.
// These are the user-facing `scrollwm <verb>` commands (see runControlCLI).
let controlVerbs: Set<String> = [
    "status", "version", "hello", "arrange", "release", "toggle", "focus", "move", "width",
    "workspace", "ws", "close", "display", "focus-mode", "focusmode", "reload", "reload-config",
    "tutorial", "skills", "proficiency", "login", "launch-at-login", "loginitem",
    "update", "update-check", "ping", "quit",
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
case "mmtest":
    exit(MultiMonitorTests.run() ? 0 : 1)
case "animrender":
    let out = args.dropFirst().first ?? "menubar_anim.png"
    exit(MenuBarAnimationRender.run(outPath: out) ? 0 : 1)
case "tutorialrender":
    let prefix = args.dropFirst().first ?? "tutorial"
    exit(TutorialRender.run(outPrefix: prefix) ? 0 : 1)
case "opstest":
    args.contains("--live") ? runStripOpsIntegrationTest() : runHeadlessOpsTest()
case "spawnlatency":
    args.contains("--live") ? runSpawnLatencyTest() : runHeadlessSpawnLatencyTest()
case "coldstartbench":
    // Headless A/B benchmark of COLD-START adoption latency: how fast a
    // brand-NEW app's first window lands in its strip slot, with the launch
    // fast path OFF (baseline: launch-resync/poll) vs ON (the optimization).
    runColdStartBench(args: Array(args))
case "coldstarttest":
    // Headless regression guard for the cold-start fast path: a brand-NEW app's
    // FIRST window is adopted fast (and lands right of focus) with the launch
    // fast path on, and is markedly slower with it off. Always headless.
    runHeadlessColdStartTest()
case "coldstartwarmtest":
    // Headless guard for the OTHER half of the cold-start fix: registering the
    // per-app observer the instant a process launches must let that cold app's
    // SECOND window ride the WARM kAXWindowCreated fast path (not the poll).
    runHeadlessColdStartWarmSecondTest()
case "coldstartbursttest":
    // Headless regression guard for the cold-start BURST path ("jcode forest
    // swarm"): launching MANY brand-NEW apps at once - each a distinct new pid -
    // adopts EVERY first window fast, in strip order, exactly once (no
    // double-adopt / no drop), ending with the strip == seed + N. Always headless.
    runHeadlessColdStartBurstTest()
case "coldstartlive":
    // LIVE (real-AX) cold-start latency proof: launch a BRAND-NEW disposable
    // process and time until its FIRST window lands in its strip slot, via the
    // real didLaunchApplication -> immediate-register -> onAppLaunched ->
    // fastAdopt(coldStart:true) path. Hard-scoped (pidFilter) to the spawned
    // pids + a deliberately slow 5s poll, so any sub-second adoption proves the
    // launch fast path, not the poll. Never touches the user's real windows.
    runColdStartLiveTest()
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
case "indicatorprobe":
    // Live, non-destructive visual check of the floating per-display indicator:
    // shows a real indicator panel on each menu-bar-less display for a few
    // seconds, then removes it. Never touches a real window.
    let secs = args.dropFirst().compactMap { Double($0) }.first ?? 6
    runIndicatorProbe(seconds: secs)
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
case "statusicontest":
    // Headless test that the menu-bar status icon (live mini-map) + floating
    // per-display indicators refresh on EVERY user-visible event: focus/width/
    // move/close/workspace/resync/floating (G3), a native macOS Space switch
    // (G1), and a monitor hotplug/rearrange/resolution change (G2). Drives the
    // REAL controller against the sim; never touches a real window/monitor/Space.
    runHeadlessStatusIconTest()
case "autotiletest":
    // Headless test of the no-background-windows guarantee
    // (layout.autoTileNewWindows): a standard window left floating while
    // managing is auto-tiled onto the strip; a dialog/panel is not; Release
    // restores everything; the flag-off path leaves floats alone. Drives the
    // REAL controller + lifecycle monitor against the sim; never touches a real
    // window.
    runHeadlessAutoTileTest()
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
    // An unrecognized command. Distinguish a genuine typo from an explicit help
    // request (handled above): print a short error to STDERR and exit non-zero
    // so scripts can detect it, with a pointer to `--help` for the full usage.
    FileHandle.standardError.write(
        "scrollwm: unknown command '\(command)'. Run `scrollwm --help` for usage.\n"
            .data(using: .utf8)!)
    exit(2)
}

// MARK: - CLI help

/// The full `scrollwm`/`WindowLab` usage text. Printed by an explicit
/// `--help`/`-h`/`help` (exit 0). Kept as a function so it can be referenced
/// from the top-level command dispatch above regardless of source order.
func scrollwmHelpText() -> String {
    """
    ScrollWM / WindowLab

    Control a running ScrollWM from your shell (the app must be running):
      scrollwm status              print strip state as JSON
      scrollwm arrange [25|50|75|100|0.0-1.0]
                                   adopt current-Space windows (launches app if
                                   needed); optional width sizes EVERY column
      scrollwm release             restore all windows, go dormant
      scrollwm toggle              arrange <-> release
      scrollwm focus <next|prev|left|right|N>
                                   change focused column (N is 1-based)
      scrollwm move <left|right>   move focused column within the strip
      scrollwm move <up|down>      send focused window to the workspace above/below
      scrollwm workspace <up|down|N>
                                   switch vertical workspace (niri-style)
      scrollwm width [all] <25|50|75|100|0.0-1.0>
                                   resize focused column (or `all` columns)
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
      scrollwm version             print app version + capabilities as JSON
      scrollwm --version           print the installed ScrollWM version (no app needed)
      scrollwm --help              show this help
      scrollwm quit                restore windows and quit the app

    Lab / test harness (spawns its own processes; safe):
      WindowLab probe [-v]     enumerate CG+AX windows, match, report latency
      WindowLab bench          AX move/resize benchmark (windows restored after)
      WindowLab watch [secs]   repeated full resync loop with timing
      WindowLab run [--selftest]
                               ScrollWM production app: dormant menu bar agent.
                               Arrange/release via menu, ctrl+opt+esc, or the CLI.
                               Exact frame restore on release/quit/crash.
      WindowLab unittest       pure-logic tests for width/move/close ops (no AX needed)
      WindowLab mmtest         pure-logic tests for the multi-monitor policies (no AX needed)
      WindowLab headlesstest   run ALL integration suites HEADLESS (no real window
                               is spawned/moved/focused/closed; safe while you work)
      WindowLab updatecheck [--install] [--prerelease] [--stage-only]
                               check GitHub Releases for a newer ScrollWM
      WindowLab fuzz | fuzzmodel | fuzzctrl | fuzzdisp | fuzzconc | statespace
                               headless property/state-space checkers (see source)
      WindowLab coldstartbench [trials]
                               headless A/B latency: a brand-new app's first
                               window landing in the strip, launch fast path
                               OFF (baseline) vs ON (optimized)
      WindowLab coldstartlive  LIVE cold-start latency: launch a brand-new
                               disposable process, time its first window into the
                               strip (real AX; isolated to spawned pids)
      WindowLab sandbox [n] [--display M]
                               drive the REAL controller on n disposable windows
                               it spawns (your real windows are untouched)

    Run `WindowLab --help` (or with no subcommand on the dev binary) for the full
    diagnostic/test command set.
    """
}

/// True when THIS executable resolves (through symlinks) to a file inside a
/// `*.app` bundle - i.e. we were launched via the user-facing `scrollwm` shim
/// (a symlink into `ScrollWM.app/Contents/MacOS/ScrollWM`), even though
/// `Bundle.main` points at the symlink's directory. Used to choose a friendly
/// default (`help`) for a bare `scrollwm` instead of the dev `probe` dump.
func executableResolvesIntoAppBundle() -> Bool {
    let raw = Bundle.main.executableURL?.path
        ?? Bundle.main.executablePath
        ?? CommandLine.arguments.first
    guard let raw, !raw.isEmpty else { return false }
    var url = URL(fileURLWithPath: (raw as NSString).resolvingSymlinksInPath)
    while url.pathComponents.count > 1 {
        if url.pathExtension == "app" { return true }
        url.deleteLastPathComponent()
    }
    return false
}
