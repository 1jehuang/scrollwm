import Foundation
import ApplicationServices
import AppKit

// HEADLESS integration tests.
//
// Each mirrors the assertions of its real-window counterpart (opstest, e2etest,
// revealtest, spawnlatency, displaytest) but runs the EXACT production engine /
// controller logic against an in-memory `SimWindowWorld`. No real window is ever
// spawned, moved, focused, or closed, and no global keystroke is injected, so
// these can run while you work without ever touching your screen or focus.
//
// They run entirely on the MAIN thread (the harness is single-threaded): the
// test calls production methods directly, then `Headless.pump()` drains the
// engine/monitor's async work (focus reconcile, fast-adopt coalescing, the sim's
// create/destroy events) before asserting.

// MARK: - opstest (headless): width / min-clamp / spawn-width / move / focus-sync / close

func runHeadlessOpsTest() {
    let world = Headless.install()
    defer { Headless.uninstall() }
    var t = TestCounter()

    let engine = TeleportEngine(screenFrame: Headless.defaultVisibleFrame)
    let (pids, _) = Headless.seedWindows(world, count: 4)

    func liveWindows() -> [AXWindowInfo] { pids.flatMap { AXSource.windows(forPID: $0) } }
    func liveSize(title: String) -> CGSize? { liveWindows().first { $0.title == title }?.frame.size }

    let matched = IdentityMatcher.match(
        axWindows: liveWindows(),
        cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
    ).filter { pids.contains($0.ax.pid) }
    engine.adopt(matched: matched)
    t.check("adopted 4 sim windows", engine.slots.count == 4)
    guard engine.slots.count == 4 else {
        print("[headless-opstest] adoption failed, aborting")
        print("\n[headless-opstest] \(t.passed) passed, \(t.failed) failed"); exit(1)
    }

    // --- WIDTH 25% / 100% reconciled against the sim frame ---
    engine.focusIndex = 0
    let focusTitle0 = engine.slots[0].window.title
    let want25 = engine.width(forFraction: 0.25)
    _ = engine.setFocusedWidth(fraction: 0.25)
    if let live = liveSize(title: focusTitle0) {
        t.check("width 25%: real (sim) window width == requested (\(Int(want25)))", abs(live.width - want25) <= 1)
    } else { t.check("width 25%: live readback available", false) }

    let want100 = engine.width(forFraction: 1.0)
    _ = engine.setFocusedWidth(fraction: 1.0)
    if let live = liveSize(title: focusTitle0) {
        t.check("width 100%: real (sim) window width == requested (\(Int(want100)))", abs(live.width - want100) <= 1)
    } else { t.check("width 100%: live readback available", false) }
    t.check("strip compact after resizes", StripOpsTests.isCompact(engine))

    // --- MIN-SIZE CLAMP: app refuses to shrink below its minimum, AX "succeeds" ---
    let bigMin = 900.0
    let clampEngine = TeleportEngine(screenFrame: Headless.defaultVisibleFrame)
    let clampPID: pid_t = 5100
    _ = world.addWindow(pid: clampPID, title: "MinWidthApp",
                        frame: CGRect(x: 60, y: 80, width: 1000, height: 600),
                        minSize: CGSize(width: bigMin, height: 200))
    let clampMatched = IdentityMatcher.match(
        axWindows: AXSource.windows(forPID: clampPID),
        cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
    ).filter { $0.ax.pid == clampPID }
    clampEngine.adopt(matched: clampMatched)
    if clampEngine.slots.count == 1 {
        let requested = clampEngine.width(forFraction: 0.25)
        t.check("min-clamp: requested width is below the window minimum", requested < bigMin)
        _ = clampEngine.setFocusedWidth(fraction: 0.25)
        let liveClamped = AXSource.windows(forPID: clampPID).first?.frame.size.width ?? 0
        t.check("min-clamp: real window did not shrink below its minimum", liveClamped >= bigMin - 1)
        t.check("min-clamp: model width matches the real (clamped) width",
                abs(clampEngine.slots[0].width - liveClamped) <= 1)
        t.check("min-clamp: model did NOT store the (smaller) requested width",
                clampEngine.slots[0].width > requested + 1)
        t.check("min-clamp: strip stays compact", StripOpsTests.isCompact(clampEngine))
    } else {
        t.check("min-clamp: adopted the min-width window", false)
    }

    // --- SPAWN WIDTH: a freshly opened wide window snaps to the column target ---
    let spawnEngine = TeleportEngine(screenFrame: Headless.defaultVisibleFrame)
    spawnEngine.spawnWidthFraction = 0.25
    let spawnTarget = spawnEngine.width(forFraction: 0.25)
    let widePID: pid_t = 5200
    _ = world.addWindow(pid: widePID, title: "SpawnWide",
                        frame: CGRect(x: 40, y: 80, width: 1200, height: 500))
    if let wideInfo = AXSource.windows(forPID: widePID).first {
        t.check("spawn-width: wide window opened wider than the target",
                wideInfo.frame.width > spawnTarget + 50)
        spawnEngine.insert(window: wideInfo, at: 0)
        spawnEngine.applySpawnWidth(toSlotAt: 0)
        spawnEngine.compactStrip()
        let liveWide = AXSource.windows(forPID: widePID).first?.frame.size.width ?? 0
        t.check("spawn-width: real window shrank to the column target (\(Int(spawnTarget)))",
                abs(liveWide - spawnTarget) <= 1)
        t.check("spawn-width: model matches the real (resized) width",
                abs(spawnEngine.slots[0].width - liveWide) <= 1)
        t.check("spawn-width: strip stays compact", StripOpsTests.isCompact(spawnEngine))
    } else {
        t.check("spawn-width: adopted the wide window", false)
    }

    // A window whose hard minimum exceeds the spawn target keeps its minimum.
    let spawnClampEngine = TeleportEngine(screenFrame: Headless.defaultVisibleFrame)
    spawnClampEngine.spawnWidthFraction = 0.25
    let scTarget = spawnClampEngine.width(forFraction: 0.25)
    let scMin = 880.0
    let scPID: pid_t = 5300
    _ = world.addWindow(pid: scPID, title: "SpawnClamp",
                        frame: CGRect(x: 40, y: 80, width: 1000, height: 500),
                        minSize: CGSize(width: scMin, height: 200))
    if let scInfo = AXSource.windows(forPID: scPID).first {
        t.check("spawn-width clamp: target is below the window minimum", scTarget < scMin)
        spawnClampEngine.insert(window: scInfo, at: 0)
        spawnClampEngine.applySpawnWidth(toSlotAt: 0)
        let liveSC = AXSource.windows(forPID: scPID).first?.frame.size.width ?? 0
        t.check("spawn-width clamp: app kept its minimum (did not shrink to target)", liveSC >= scMin - 1)
        t.check("spawn-width clamp: model stores the real clamped width, not the target",
                abs(spawnClampEngine.slots[0].width - liveSC) <= 1 && spawnClampEngine.slots[0].width > scTarget + 1)
    } else {
        t.check("spawn-width clamp: adopted the min-width window", false)
    }

    // --- MOVE: reorder focused column right ---
    engine.focusIndex = 0
    let before = engine.slots.map { $0.window.title }
    _ = engine.moveFocused(by: 1)
    let after = engine.slots.map { $0.window.title }
    t.check("move right swapped first two columns",
            after.count == before.count && after[0] == before[1] && after[1] == before[0])
    t.check("focus follows moved window", engine.slots[engine.focusIndex].window.title == before[0])
    t.check("strip compact after move", StripOpsTests.isCompact(engine))

    // --- FOCUS SYNC: closeFocused honors the live OS focus, not a stale index ---
    let staleIndex = 0
    let liveFocusIndex = engine.slots.count - 1
    engine.focusIndex = staleIndex
    let staleTitle = engine.slots[staleIndex].window.title
    let liveTitle = engine.slots[liveFocusIndex].window.title
    t.check("focus-sync precondition: stale != live target", staleTitle != liveTitle)
    // Model the user clicking the live target: focus it in the sim directly.
    world.setSystemFocus(engine.slots[liveFocusIndex].window.element)
    let resolved = engine.syncFocusToSystemFocusedWindow()
    t.check("focus-sync: resolved the live OS-focused window", resolved)
    t.check("focus-sync: focusIndex now points at the live-focused column",
            engine.slots.indices.contains(engine.focusIndex) &&
            engine.slots[engine.focusIndex].window.title == liveTitle)

    engine.focusIndex = staleIndex
    let beforeFocusSyncClose = liveWindows().count
    world.setSystemFocus(engine.slots[liveFocusIndex].window.element)
    _ = engine.closeFocused()
    t.check("focus-sync close: closed the OS-focused window (not the stale one)",
            engine.slots.allSatisfy { $0.window.title != liveTitle })
    t.check("focus-sync close: the stale-index window is STILL open",
            engine.slots.contains { $0.window.title == staleTitle })
    t.check("focus-sync close: a real (sim) window actually closed",
            liveWindows().count == beforeFocusSyncClose - 1)

    // --- CLOSE: close focused window, verify it disappears ---
    let closeTitle = engine.slots[engine.focusIndex].window.title
    world.setSystemFocus(engine.slots[engine.focusIndex].window.element)
    let slotsBeforeClose = engine.slots.count
    let liveCountBefore = liveWindows().count
    _ = engine.closeFocused()
    t.check("close: dropped from strip", engine.slots.count == slotsBeforeClose - 1)
    t.check("close: gone from strip model", engine.slots.allSatisfy { $0.window.title != closeTitle })
    t.check("close: real (sim) window count dropped", liveWindows().count == liveCountBefore - 1)
    t.check("strip compact after close", StripOpsTests.isCompact(engine))

    print("\n[headless-opstest] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}

// MARK: - e2etest (headless): real controller + synthetic chords (no CGEvents)

func runHeadlessE2ETest() {
    // Isolate crash-recovery state from the real session before the controller
    // (which checks the restore file on init) is built.
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

    let world = Headless.install()
    defer { Headless.uninstall(); RestoreStore.clear() }
    var t = TestCounter()

    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    // Seed sim windows WITHIN the controller's strip display, so the default
    // stripDisplay adopt-scope keeps them (mirrors arrange's real behavior).
    let frame = controller.debugScreenFrame
    let (pids, _) = Headless.seedWindows(
        world, count: 4, startPID: 6000, within: frame, width: 320, height: 300)
    let pidSet = Set(pids)

    func chord(_ s: String) -> Chord { Chord(string: s)! }
    @discardableResult func key(_ s: String) -> Bool {
        let ok = controller.debugDeliverChord(chord(s)); Headless.pump(0.06); return ok
    }

    controller.arrange(pidFilter: pidSet)
    Headless.pump(0.1)
    t.check("controller is managing", controller.isManaging)
    t.check("4 columns in strip", controller.debugSlotCount == 4)

    // --- Alt+2 -> 50% width (management tap binding) ---
    key("opt+2")
    let want50 = controller.debugWidth(forFraction: 0.5)
    t.check("Alt+2 set focused width to ~50%", abs(controller.debugFocusedWidth - want50) <= 1)

    // --- Cmd+1 -> 25% width ---
    key("cmd+1")
    let want25 = controller.debugWidth(forFraction: 0.25)
    t.check("Cmd+1 set focused width to ~25%", abs(controller.debugFocusedWidth - want25) <= 1)

    // --- Cmd+4 -> 100% width ---
    key("cmd+4")
    let want100 = controller.debugWidth(forFraction: 1.0)
    t.check("Cmd+4 set focused width to ~100%", abs(controller.debugFocusedWidth - want100) <= 1)

    // --- Key-hint HUD: the menu-bar icon flashes the chord + action ---
    t.check("Cmd+4 flashed a key hint", controller.debugHintText != nil)
    t.check("hint shows the chord + action", controller.debugHintText == "⌘4  Width 100%")
    key("cmd+1")
    t.check("hint retargets on the next press", controller.debugHintText == "⌘1  Width 25%")
    // Reset width back to 100% so later assertions keep their footing.
    key("cmd+4")

    // --- Cmd+L focus next, Cmd+H focus prev ---
    controller.focus(index: 0); Headless.pump(0.05)
    key("cmd+l")
    t.check("Cmd+L focused next column (index 1)", controller.debugFocusIndex == 1)
    key("cmd+h")
    t.check("Cmd+H focused previous column (index 0)", controller.debugFocusIndex == 0)

    // --- Cmd+Shift+L move right, Cmd+Shift+H move back ---
    let focusTitle = controller.debugFocusedTitle
    let order0 = controller.debugSlotTitles
    key("cmd+shift+l")
    let order1 = controller.debugSlotTitles
    t.check("Cmd+Shift+L moved focused column right",
            order1.count == order0.count && order1.firstIndex(of: focusTitle) == 1)
    key("cmd+shift+h")
    t.check("Cmd+Shift+H moved focused column back left",
            controller.debugSlotTitles.firstIndex(of: focusTitle) == 0)

    // --- Cmd+J workspace down (creates empty ws), Cmd+K back up ---
    controller.focus(index: 0); Headless.pump(0.05)
    let wsCountBefore = controller.debugWorkspaceCount
    let colsBefore = controller.debugSlotCount
    key("cmd+j")
    t.check("Cmd+J switched to workspace 2 (index 1)", controller.debugActiveWorkspace == 1)
    t.check("Cmd+J created a new empty workspace", controller.debugWorkspaceCount == wsCountBefore + 1)
    t.check("Cmd+J new workspace is empty", controller.debugSlotCount == 0)
    key("cmd+k")
    t.check("Cmd+K switched back to workspace 1 (index 0)", controller.debugActiveWorkspace == 0)
    t.check("Cmd+K restored the original columns", controller.debugSlotCount == colsBefore)
    t.check("Cmd+K pruned the empty trailing workspace", controller.debugWorkspaceCount == wsCountBefore)

    // --- Cmd+Shift+J send focused window down + follow ---
    let sendTitle = controller.debugFocusedTitle
    key("cmd+shift+j")
    t.check("Cmd+Shift+J followed window to workspace 2", controller.debugActiveWorkspace == 1)
    t.check("Cmd+Shift+J destination holds the sent window", controller.debugSlotCount == 1)
    t.check("Cmd+Shift+J sent the focused window", controller.debugFocusedTitle == sendTitle)
    key("cmd+k")
    t.check("back on workspace 1 after workspace tests", controller.debugActiveWorkspace == 0)
    t.check("workspace 1 has the remaining columns", controller.debugSlotCount == colsBefore - 1)
    controller.focus(index: 0); Headless.pump(0.05)

    // --- Cmd+Q close focused window ---
    let colsBeforeClose = controller.debugSlotCount
    let liveBefore = pids.flatMap { AXSource.windows(forPID: $0) }.count
    key("cmd+q")
    Headless.pump(0.1)
    t.check("Cmd+Q dropped a column", controller.debugSlotCount == colsBeforeClose - 1)
    let liveAfter = pids.flatMap { AXSource.windows(forPID: $0) }.count
    t.check("Cmd+Q closed a real (sim) window", liveAfter == liveBefore - 1)

    // --- Release: restores + tears down hotkeys ---
    controller.release()
    Headless.pump(0.1)
    t.check("controller stopped managing", !controller.isManaging)
    t.check("strip empty after release", controller.debugSlotCount == 0)
    // After release the management tap is gone: a Cmd+H must NOT reach the
    // controller anymore (no binding consumes it).
    t.check("management chord no longer handled after release", !controller.debugDeliverChord(chord("cmd+h")))

    print("\n[headless-e2etest] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}

// MARK: - revealtest (headless): Arrange All reveals + adopts hidden/minimized

func runHeadlessRevealTest() {
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

    let world = Headless.install()
    defer { Headless.uninstall(); RestoreStore.clear() }
    var t = TestCounter()

    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller
    let frame = controller.debugScreenFrame

    let total = 4, minimizeCount = 2
    let (pids, els) = Headless.seedWindows(
        world, count: total, startPID: 6200, within: frame, width: 320, height: 300)
    let pidSet = Set(pids)
    controller.sandboxPIDs = pidSet

    // Minimize the first `minimizeCount` windows (sorted by title for determinism).
    let sorted = zip(els, pids).sorted { ($0.1) < ($1.1) }.map { $0.0 }
    for el in sorted.prefix(minimizeCount) { world.setMinimized(el, true) }
    let minimizedNow = pids.flatMap { AXSource.windows(forPID: $0) }.filter { $0.isMinimized }.count
    t.check("minimized \(minimizeCount) windows up front", minimizedNow == minimizeCount)

    // --- Plain arrange: adopts only the VISIBLE windows ---
    controller.arrange()
    Headless.pump(0.1)
    t.check("plain arrange adopts only visible windows (\(total - minimizeCount))",
            controller.debugSlotCount == total - minimizeCount)

    controller.release()
    Headless.pump(0.1)
    t.check("released back to dormant", !controller.isManaging)
    // Re-minimize the same windows (release does not change minimized state, but
    // be explicit so the precondition holds).
    for el in sorted.prefix(minimizeCount) { world.setMinimized(el, true) }

    // --- Arrange All: reveals minimized windows, then adopts EVERYTHING ---
    controller.arrangeAllWindows()
    // arrangeAllWindows reveals (sim de-miniaturize is instant) then adopts after
    // a settle delay; pump generously to cover the asyncAfter chain.
    Headless.pump(0.8)
    t.check("arrange all adopts every window incl. minimized (\(total))",
            controller.debugSlotCount == total)
    t.check("no spawned window left minimized after arrange all",
            pids.flatMap { AXSource.windows(forPID: $0) }.allSatisfy { !$0.isMinimized })

    controller.release()
    Headless.pump(0.1)
    print("\n[headless-revealtest] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}

// MARK: - spawnlatency (headless): new-window adoption via the AX-observer fast path

func runHeadlessSpawnLatencyTest() {
    let world = Headless.install()
    defer { Headless.uninstall() }
    var t = TestCounter()

    let engine = TeleportEngine(screenFrame: Headless.defaultVisibleFrame)
    let seedPID: pid_t = 6400
    _ = world.addWindow(pid: seedPID, title: "Seed",
                        frame: CGRect(x: 40, y: 80, width: 360, height: 420))
    let matched = IdentityMatcher.match(
        axWindows: AXSource.windows(forPID: seedPID),
        cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
    ).filter { $0.ax.pid == seedPID }
    engine.adopt(matched: matched)
    t.check("seed adopted", engine.slots.count == 1)
    _ = engine.setFocusedWidth(fraction: 0.25)

    // Deliberately SLOW poll so an adoption under ~1s proves the AX-observer
    // (here: sim create-event) fast path drove it, not the poll.
    let monitor = LifecycleMonitor(engine: engine, interval: 5.0)
    monitor.pidFilter = [seedPID]
    monitor.start()
    Headless.pump(0.1) // let the observer subscribe

    // Open a SECOND window in the already-observed seed process (notify -> fires
    // the create event -> fast adopt).
    let startCount = engine.slots.count
    let t0 = Clock.nowAbsNs()
    _ = world.addWindow(pid: seedPID, title: "Seed-2",
                        frame: CGRect(x: 460, y: 80, width: 360, height: 420), notify: true)

    var adoptedNs: UInt64?
    let deadline = Clock.nowAbsNs() + 3_000_000_000
    while Clock.nowAbsNs() < deadline {
        Headless.pump(0.01)
        if engine.slots.count > startCount { adoptedNs = Clock.nowAbsNs(); break }
    }
    if let adoptedNs {
        let ms = Double(adoptedNs &- t0) / 1e6
        print(String(format: "[headless-spawnlatency] adopted in %.0f ms", ms))
        t.check("new window adopted", true)
        t.check("adoption latency < 1000ms (fast path, not poll)", ms < 1000)
    } else {
        t.check("new window adopted", false)
    }

    // --- Publish-race adoption: a window readable via AX but WITHHELD from the
    // WindowServer on-screen list for ~150ms (the real kAXWindowCreated-beats-
    // publish gap). The single-shot fast path used to miss this and fall back to
    // the 2s poll; the bounded retry must adopt it well under that. ---
    let raceStartCount = engine.slots.count
    let raceT0 = Clock.nowAbsNs()
    // Distinct title (no "Seed" substring) so the current-Space gate cannot
    // false-match it to a stale CG entry during the withhold window.
    _ = world.addWindow(pid: seedPID, title: "Helper",
                        frame: CGRect(x: 860, y: 80, width: 360, height: 420),
                        notify: true, cgPublishDelay: 0.15)
    var raceAdoptedNs: UInt64?
    let raceDeadline = Clock.nowAbsNs() + 3_000_000_000
    while Clock.nowAbsNs() < raceDeadline {
        Headless.pump(0.01)
        if engine.slots.count > raceStartCount { raceAdoptedNs = Clock.nowAbsNs(); break }
    }
    if let raceAdoptedNs {
        let ms = Double(raceAdoptedNs &- raceT0) / 1e6
        print(String(format: "[headless-spawnlatency] publish-race window adopted in %.0f ms", ms))
        t.check("publish-race window adopted", true)
        // The poll is 5s; adoption under ~1s proves the retry bridged the gap.
        t.check("publish-race adoption < 1000ms (retry bridged the gap, not poll)", ms < 1000)
        // It must arrive AFTER the publish delay (we can't adopt before it is
        // on-screen), confirming the retry waited for the WindowServer.
        t.check("publish-race adoption respected the publish delay (>= 140ms)", ms >= 140)
    } else {
        t.check("publish-race window adopted", false)
    }

    // --- Close latency: destroy the new window, time the gap close. ---
    let countBeforeClose = engine.slots.count
    if countBeforeClose >= 2 {
        if let extra = world.snapshot().first(where: { $0.title == "Helper" })?.element {
            let tc0 = Clock.nowAbsNs()
            world.destroyWindow(extra, notify: true)
            var closedNs: UInt64?
            let cdeadline = Clock.nowAbsNs() + 3_000_000_000
            while Clock.nowAbsNs() < cdeadline {
                Headless.pump(0.01)
                if engine.slots.count < countBeforeClose { closedNs = Clock.nowAbsNs(); break }
            }
            if let closedNs {
                let ms = Double(closedNs &- tc0) / 1e6
                print(String(format: "[headless-spawnlatency] gap closed in %.0f ms", ms))
                t.check("closed window removed", true)
                t.check("close latency < 1000ms (destroy event, not poll)", ms < 1000)
            } else {
                t.check("closed window removed", false)
            }
        }
    }

    monitor.stop()
    print("\n[headless-spawnlatency] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}

// MARK: - displaytest (headless): on-strip placement, parking sliver, rebind

func runHeadlessDisplayTest() {
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

    // A deterministic synthetic 2-display layout in AX global (top-left) coords,
    // independent of the real hardware: strip on the LEFT, neighbor on the RIGHT.
    let stripFull = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let stripVisible = CGRect(x: 0, y: 32, width: 1600, height: 968)
    let otherFull = CGRect(x: 1600, y: 0, width: 1440, height: 900)

    let world = Headless.install(displays: [stripFull, otherFull])
    defer { Headless.uninstall(); RestoreStore.clear() }
    var t = TestCounter()

    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller
    // Bind the engine to our synthetic strip display BEFORE arranging, so the
    // test is independent of the machine's real monitors.
    controller.debugRebindStrip(visible: stripVisible, stripFull: stripFull, others: [otherFull])

    let (pids, _) = Headless.seedWindows(
        world, count: 4, startPID: 6600, within: stripVisible, width: 300, height: 360)
    controller.sandboxPIDs = Set(pids)

    func liveFrame(title: String) -> CGRect? {
        pids.flatMap { AXSource.windows(forPID: $0) }.first { $0.title == title }?.frame
    }

    // --- Phase 1: arrange + on-strip-display ---
    controller.arrange(pidFilter: Set(pids))
    Headless.pump(0.1)
    t.check("controller is managing", controller.isManaging)
    t.check("4 columns adopted", controller.debugSlotCount == 4)
    guard controller.debugSlotCount == 4 else {
        print("\n[headless-displaytest] \(t.passed) passed, \(t.failed) failed"); exit(1)
    }
    t.check("strip bound to the strip display",
            controller.debugStripDisplayFrame.map { approxEqualRect($0, stripFull) } ?? false)

    var allOnStrip = true
    for title in controller.debugSlotTitles {
        guard let f = liveFrame(title: title) else { allOnStrip = false; continue }
        let onStripOverlap = DisplayGeometry.overlapArea(f, stripFull)
        let neighborOverlap = DisplayGeometry.overlapArea(f, otherFull)
        if onStripOverlap <= neighborOverlap { allOnStrip = false }
    }
    t.check("every arranged window's frame is on the strip display", allOnStrip)

    // --- Phase 2: off-viewport parking sliver stays on the strip display ---
    for i in 0..<controller.debugSlotCount {
        controller.focus(index: i); controller.setWidthFraction(1.0); Headless.pump(0.04)
    }
    controller.focus(index: controller.debugSlotCount - 1)
    Headless.pump(0.1)
    let parkedTitle = controller.debugSlotTitles.first ?? ""
    if let pf = liveFrame(title: parkedTitle) {
        let onStripOverlap = DisplayGeometry.overlapArea(pf, stripFull)
        let neighborOverlap = DisplayGeometry.overlapArea(pf, otherFull)
        print("[headless-displaytest] parked '\(parkedTitle)' \(rectStrHL(pf)) "
              + "stripOverlap=\(Int(onStripOverlap)) neighborOverlap=\(Int(neighborOverlap))")
        t.check("parked window's clamp sliver is visible ON the strip display", onStripOverlap > 0)
        t.check("parked window's sliver did NOT spill onto the neighbor display",
                neighborOverlap <= onStripOverlap * 0.05)
    } else {
        t.check("parked window readback available", false)
    }

    // Reset widths small for the rebind.
    for i in 0..<controller.debugSlotCount {
        controller.focus(index: i); controller.setWidthFraction(0.25); Headless.pump(0.04)
    }
    Headless.pump(0.1)

    // --- Phase 3: rebind onto the OTHER display; windows must follow ---
    let otherVisible = CGRect(x: 1600, y: 32, width: 1440, height: 868)
    let relayWrites = controller.debugRebindStrip(visible: otherVisible, stripFull: otherFull, others: [stripFull])
    Headless.pump(0.1)
    t.check("rebind relayed windows (issued AX position writes)", relayWrites > 0)
    t.check("strip now bound to the rebind target",
            controller.debugStripDisplayFrame.map { approxEqualRect($0, otherFull) } ?? false)
    var allMoved = true
    for title in controller.debugSlotTitles {
        guard let f = liveFrame(title: title) else { allMoved = false; continue }
        let onTarget = DisplayGeometry.overlapArea(f, otherFull)
        let elsewhere = DisplayGeometry.overlapArea(f, stripFull)
        if onTarget <= elsewhere {
            allMoved = false
            print("    \(title) \(rectStrHL(f)) onTarget=\(Int(onTarget)) elsewhere=\(Int(elsewhere))")
        }
    }
    t.check("after rebind, every window moved onto the other display", allMoved)

    // --- Restore + cleanup ---
    controller.release()
    Headless.pump(0.1)
    t.check("controller stopped managing", !controller.isManaging)
    t.check("strip empty after release", controller.debugSlotCount == 0)

    print("\n[headless-displaytest] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}

// MARK: - small local helpers

private func approxEqualRect(_ a: CGRect, _ b: CGRect, tol: CGFloat = 1) -> Bool {
    abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
        && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
}
private func rectStrHL(_ r: CGRect) -> String {
    String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
}
