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

    // A window whose hard minimum exceeds the spawn target keeps its minimum,
    // and the spawn path then rounds it UP to the smallest preset that fits so
    // a clamp-resistant window still tiles on the column grid.
    let spawnClampEngine = TeleportEngine(screenFrame: Headless.defaultVisibleFrame)
    spawnClampEngine.spawnWidthFraction = 0.25
    spawnClampEngine.widthPresets = [0.25, 0.5, 0.75, 1.0]
    let scTarget = spawnClampEngine.width(forFraction: 0.25)
    let scMin = 880.0
    let expectedSnap = spawnClampEngine.nextPresetWidth(atLeast: scMin) ?? scMin
    let scPID: pid_t = 5300
    _ = world.addWindow(pid: scPID, title: "SpawnClamp",
                        frame: CGRect(x: 40, y: 80, width: 1000, height: 500),
                        minSize: CGSize(width: scMin, height: 200))
    if let scInfo = AXSource.windows(forPID: scPID).first {
        t.check("spawn-width clamp: target is below the window minimum", scTarget < scMin)
        t.check("spawn-width clamp: a larger preset exists to snap up to", expectedSnap > scMin - 1)
        spawnClampEngine.insert(window: scInfo, at: 0)
        spawnClampEngine.applySpawnWidth(toSlotAt: 0)
        let liveSC = AXSource.windows(forPID: scPID).first?.frame.size.width ?? 0
        t.check("spawn-width clamp: app kept at least its minimum (did not shrink to target)", liveSC >= scMin - 1)
        t.check("spawn-width snap-up: real window rounded UP to the preset grid (\(Int(expectedSnap)))",
                abs(liveSC - expectedSnap) <= 1)
        t.check("spawn-width snap-up: model matches the real (snapped) width",
                abs(spawnClampEngine.slots[0].width - liveSC) <= 1)
    } else {
        t.check("spawn-width clamp: adopted the min-width window", false)
    }

    // --- FILL HEIGHT: an adopted short window stretches to the full usable
    // height, top-pinned just under the menu bar; an app with a taller fixed/
    // minimum height keeps it (model reconciles to the real frame) ---
    let fillEngine = TeleportEngine(screenFrame: Headless.defaultVisibleFrame)
    fillEngine.fillHeight = true
    let usableTop = Headless.defaultVisibleFrame.origin.y
    let usableH = Headless.defaultVisibleFrame.height
    let shortPID: pid_t = 5400
    _ = world.addWindow(pid: shortPID, title: "ShortWin",
                        frame: CGRect(x: 60, y: 200, width: 700, height: 360))
    if let shortInfo = AXSource.windows(forPID: shortPID).first {
        t.check("fill-height: window opened shorter than the usable height",
                shortInfo.frame.height < usableH - 50)
        fillEngine.insert(window: shortInfo, at: 0)
        fillEngine.applyFillHeight(toSlotAt: 0)
        fillEngine.compactStrip()
        fillEngine.teleport()   // commit the pinned top to the real window
        let liveShort = AXSource.windows(forPID: shortPID).first?.frame ?? .zero
        t.check("fill-height: real window stretched to full usable height (\(Int(usableH)))",
                abs(liveShort.height - usableH) <= 1)
        t.check("fill-height: real window top pinned under the menu bar (\(Int(usableTop)))",
                abs(liveShort.origin.y - usableTop) <= 1)
        t.check("fill-height: model height matches the real frame",
                abs(fillEngine.slots[0].height - liveShort.height) <= 1)
        t.check("fill-height: model top matches the real frame",
                abs(fillEngine.slots[0].y - usableTop) <= 1)
    } else {
        t.check("fill-height: adopted the short window", false)
    }

    // A window whose hard MINIMUM height exceeds the usable height keeps its
    // minimum (app wins); the model reconciles to that real, clamped height so
    // it never claims a height the window does not actually have.
    let tallMinPID: pid_t = 5500
    let tallMin = usableH + 120
    _ = world.addWindow(pid: tallMinPID, title: "TallMin",
                        frame: CGRect(x: 60, y: 100, width: 700, height: 500),
                        minSize: CGSize(width: 200, height: tallMin))
    if let tallInfo = AXSource.windows(forPID: tallMinPID).first {
        fillEngine.insert(window: tallInfo, at: 0)
        fillEngine.applyFillHeight(toSlotAt: 0)
        let liveTall = AXSource.windows(forPID: tallMinPID).first?.frame ?? .zero
        t.check("fill-height clamp: app kept at least its minimum height", liveTall.height >= tallMin - 1)
        t.check("fill-height clamp: model matches the real (clamped) height",
                abs(fillEngine.slots[0].height - liveTall.height) <= 1)
    } else {
        t.check("fill-height clamp: adopted the tall-min window", false)
    }

    // --- FILL HEIGHT vs. the display BOTTOM-EDGE clamp (regression for
    // "a window spawned LOW on screen, e.g. Messages from Spotlight, fills only
    // part of the column height"). macOS/AppKit's `constrainFrameRect` curtails
    // an in-place GROW at the display's visible-frame bottom edge: from a low
    // spawn origin a `setSize(fullHeight)` can only stretch until the window's
    // bottom meets the screen edge, NOT to the full usable height. The engine
    // must PIN the window's top to the strip top BEFORE the resize so it has the
    // full vertical room. We turn on the sim's `constrainResizeToDisplay` (the
    // same model the width-edge case uses) to reproduce the real curtailing. ---
    do {
        let display = Headless.defaultVisibleFrame
        let edgeEngine = TeleportEngine(screenFrame: display)
        edgeEngine.fillHeight = true
        edgeEngine.stripDisplayFrame = Headless.defaultFullFrame
        world.displays = [Headless.defaultFullFrame]
        world.constrainResizeToDisplay = true
        defer { world.constrainResizeToDisplay = false; world.displays = [] }
        let lowPID: pid_t = 5650
        // Spotlight-style: opens centered/low, short, with room below cut off.
        let spawnY = display.maxY - 360 - 20   // bottom 380px of the display
        let lowEl = world.addWindow(pid: lowPID, title: "LowSpawn",
                                    frame: CGRect(x: 60, y: spawnY, width: 700, height: 360))
        if let lowInfo = AXSource.windows(forPID: lowPID).first {
            edgeEngine.insert(window: lowInfo, at: 0)
            edgeEngine.applyFillHeight(toSlotAt: 0)
            edgeEngine.compactStrip()
            edgeEngine.teleport()
            Headless.pump(0.05)
            let liveLow = world.frame(of: lowEl) ?? .zero
            t.check("fill-height edge: low-spawned window reached the FULL usable height (\(Int(usableH)))",
                    abs(liveLow.height - usableH) <= 2)
            t.check("fill-height edge: top pinned under the menu bar (\(Int(usableTop)))",
                    abs(liveLow.origin.y - usableTop) <= 2)
            t.check("fill-height edge: model height matches the live full height",
                    abs(edgeEngine.slots[0].height - liveLow.height) <= 2)
        } else {
            t.check("fill-height edge: adopted the low-spawned window", false)
        }
        world.destroyWindow(lowEl, notify: false)
    }

    // fillHeight DISABLED preserves the window's native height (regression
    // guard: the flag must actually gate the behavior).
    let noFillEngine = TeleportEngine(screenFrame: Headless.defaultVisibleFrame)
    noFillEngine.fillHeight = false
    let nativePID: pid_t = 5600
    _ = world.addWindow(pid: nativePID, title: "NativeH",
                        frame: CGRect(x: 60, y: 200, width: 700, height: 360))
    if let nativeInfo = AXSource.windows(forPID: nativePID).first {
        noFillEngine.insert(window: nativeInfo, at: 0)
        noFillEngine.applyFillHeight(toSlotAt: 0)
        let liveNative = AXSource.windows(forPID: nativePID).first?.frame ?? .zero
        t.check("fill-height off: native height preserved", abs(liveNative.height - 360) <= 1)
    } else {
        t.check("fill-height off: adopted the native-height window", false)
    }

    // --- FILL HEIGHT across a RESOLUTION / DISPLAY change (regression for
    // "spawned/relaid windows are the wrong height after I changed resolution"):
    // rebindStripDisplay must physically resize the REAL windows to the NEW
    // usable height, in BOTH directions, for the active strip AND windows parked
    // in inactive workspaces. The bug: repin pre-stamped the model to the new
    // height, so applyFillHeight saw "already full" and skipped the AX resize. ---
    func rebindFillCase(_ name: String, from resA: CGRect, to resB: CGRect) {
        let w = SimWindowWorld()
        AXSource.backend = w
        defer { AXSource.backend = world } // restore the suite's world
        let e = TeleportEngine(screenFrame: resA)
        e.fillHeight = true
        let activePID: pid_t = 5700
        let parkedPID: pid_t = 5701
        _ = w.addWindow(pid: activePID, title: "RbActive",
                        frame: CGRect(x: 60, y: 120, width: 700, height: 360))
        _ = w.addWindow(pid: parkedPID, title: "RbParked",
                        frame: CGRect(x: 820, y: 120, width: 700, height: 360))
        let m = IdentityMatcher.match(
            axWindows: [activePID, parkedPID].flatMap { AXSource.windows(forPID: $0) },
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true))
        e.adopt(matched: m)
        func liveH(_ pid: pid_t) -> CGFloat { w.windows(forPID: pid).first?.frame.height ?? -1 }
        // Both windows fill the OLD usable height after adopt.
        t.check("rebind/\(name): adopt filled both to old usable height (\(Int(resA.height)))",
                abs(liveH(activePID) - resA.height) <= 1 && abs(liveH(parkedPID) - resA.height) <= 1)
        // Send RbParked to an inactive workspace so it is stashed/parked, then
        // come back so the active strip holds only RbActive.
        e.focusIndex = e.slots.firstIndex { $0.window.title == "RbParked" } ?? 0
        _ = e.moveFocusedToWorkspace(by: 1)
        _ = e.switchWorkspace(by: -1)
        // The resolution change.
        _ = e.rebindStripDisplay(to: resB)
        t.check("rebind/\(name): ACTIVE window resized to new usable height (\(Int(resB.height)))",
                abs(liveH(activePID) - resB.height) <= 1)
        t.check("rebind/\(name): PARKED (inactive-workspace) window resized to new usable height",
                abs(liveH(parkedPID) - resB.height) <= 1)
    }
    rebindFillCase("shrink",
                   from: CGRect(x: 0, y: 39, width: 1710, height: 1073),
                   to:   CGRect(x: 0, y: 32, width: 1512, height: 944))
    rebindFillCase("grow",
                   from: CGRect(x: 0, y: 32, width: 1512, height: 944),
                   to:   CGRect(x: 0, y: 39, width: 1710, height: 1073))


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

    // --- FOCUS ON UNMANAGED WINDOW: Cmd+Q must NOT close a strip window ---
    // Repro for "I was focused on Discord, pressed Cmd+Q, and it closed the
    // right-hand strip window instead of quitting Discord." When the OS keyboard
    // focus is on a window ScrollWM does NOT manage (clicked an unarranged app,
    // or one on another Space), closeFocused must no-op so the keystroke reaches
    // that app — never fall back to the stale focusIndex and close a strip window.
    do {
        let unmanaged = world.addWindow(
            pid: 8888, title: "UnmanagedApp",
            frame: CGRect(x: 4000, y: 4000, width: 800, height: 600),
            appName: "UnmanagedApp")
        let slotsBefore = engine.slots.count
        let titlesBefore = Set(engine.slots.map { $0.window.title })
        let liveBefore = liveWindows().count
        // Point the engine at the rightmost column (the one wrongly closed by the
        // bug) and move the OS focus onto the unmanaged window.
        engine.focusIndex = engine.slots.count - 1
        world.setSystemFocus(unmanaged)
        let closed = engine.closeFocused()
        t.check("unmanaged-focus close: reports it did nothing", closed == false)
        t.check("unmanaged-focus close: no strip column was closed",
                engine.slots.count == slotsBefore)
        t.check("unmanaged-focus close: the same strip windows remain",
                Set(engine.slots.map { $0.window.title }) == titlesBefore)
        t.check("unmanaged-focus close: no real (sim) window was closed",
                liveWindows().count == liveBefore)
        t.check("unmanaged-focus close: the unmanaged window is untouched",
                world.snapshot().contains { CFEqual($0.element, unmanaged) })
        // Cleanup so later assertions keep a clean world/focus.
        world.destroyWindow(unmanaged, notify: false)
        engine.focusIndex = 0
        world.setSystemFocus(engine.slots[0].window.element)
    }

    // --- FOCUS SYNC: width keys honor the live OS focus, not a stale index ---
    // Repro for "resize the window on the right but the wrong column grows / the
    // viewport never scrolls to fit it." Mirrors the closeFocused fix: clicking
    // a window moves OS focus, so a width key must resize THAT window and scroll
    // the viewport to reveal it, not act on the last column ScrollWM navigated to.
    do {
        let n = engine.slots.count
        guard n >= 2 else { t.check("width-focus-sync: enough columns", false); return }
        let stale = 0
        let liveIdx = n - 1
        engine.focusIndex = stale
        let staleTitle = engine.slots[stale].window.title
        let liveTitle = engine.slots[liveIdx].window.title
        // The user clicks the rightmost window: OS focus moves there.
        world.setSystemFocus(engine.slots[liveIdx].window.element)
        let want100 = engine.width(forFraction: 1.0)
        engine.setFocusedWidth(fraction: 1.0)
        Headless.pump()
        // The clicked (live-focused) window must be the one that resized ...
        let liveW = liveSize(title: liveTitle)?.width ?? 0
        let staleW = liveSize(title: staleTitle)?.width ?? 0
        t.check("width-focus-sync: the OS-focused (clicked) window resized to 100%",
                abs(liveW - want100) <= 2)
        t.check("width-focus-sync: the stale-index window did NOT resize",
                abs(staleW - want100) > 2)
        // ... and the engine's focus + viewport now track that window so it is fully visible.
        let fi = engine.focusIndex
        t.check("width-focus-sync: focusIndex tracks the clicked window",
                engine.slots.indices.contains(fi) &&
                engine.slots[fi].window.title == liveTitle)
        let s = engine.slots[fi]
        let visLeft = s.canvasX - engine.viewportX
        let visRight = visLeft + s.width
        t.check("width-focus-sync: viewport scrolled so the resized window is fully visible",
                visLeft >= -1 && visRight <= engine.screenFrame.width + 1)
    }

    // --- ASYNC RESIZE: viewport follows a window that GROWS to 100% SLOWLY ---
    // Repro for "two 50% columns, focus the RIGHT one, hit cmd+4: it just fills
    // the remaining space on the right instead of scrolling so the now-100%
    // window is fully visible." Real apps resize ASYNCHRONOUSLY, so the immediate
    // read-back after setSize is the OLD (small) width; if the model trusts that
    // stale read, `fit` sees no overflow and never scrolls. The adaptive
    // width-reconcile must keep following until the resize lands and then scroll
    // the focused (grown) window fully into view. We make the resize settle
    // SLOWER than any single poll to prove the follow-up is not a fixed budget.
    do {
        let asyncEngine = TeleportEngine(screenFrame: Headless.defaultVisibleFrame)
        asyncEngine.peekInset = 48 // production-like content region
        let asyncWorld = world
        let basePID: pid_t = 5700
        let lEl = asyncWorld.addWindow(pid: basePID, title: "AsyncL",
                                       frame: CGRect(x: 60, y: 80, width: 360, height: 500))
        let rEl = asyncWorld.addWindow(pid: basePID + 1, title: "AsyncR",
                                       frame: CGRect(x: 460, y: 80, width: 360, height: 500))
        let am = IdentityMatcher.match(
            axWindows: [basePID, basePID + 1].flatMap { AXSource.windows(forPID: $0) },
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        ).filter { [basePID, basePID + 1].contains($0.ax.pid) }
        asyncEngine.adopt(matched: am)
        guard asyncEngine.slots.count == 2 else {
            t.check("async-resize: adopted two columns", false); return
        }
        // Make both columns 50%.
        for i in 0..<2 {
            asyncEngine.focusIndex = i
            asyncWorld.setSystemFocus(asyncEngine.slots[i].window.element)
            asyncEngine.setFocusedWidth(fraction: 0.5)
            Headless.pump(0.05)
        }
        // Focus the RIGHT column and grow it to 100% with a SLOW async settle.
        asyncEngine.focusIndex = 1
        asyncWorld.setSystemFocus(asyncEngine.slots[1].window.element)
        asyncWorld.asyncResizeDelay = 0.35 // longer than a single 50ms poll
        let want100 = asyncEngine.width(forFraction: 1.0)
        asyncEngine.setFocusedWidth(fraction: 1.0)
        // Immediately after, the read-back is stale and the viewport has NOT yet
        // scrolled - the adaptive follow-up has to do it once the resize lands.
        Headless.pump(0.7) // past the 0.35s settle + a couple of follow-up polls
        let liveR = asyncWorld.frame(of: rEl)?.width ?? 0
        t.check("async-resize: real window reached 100% (\(Int(want100)))",
                abs(liveR - want100) <= 2)
        t.check("async-resize: model width caught up to the live 100% width",
                abs(asyncEngine.slots[1].width - liveR) <= 2)
        let s = asyncEngine.slots[asyncEngine.focusIndex]
        let visLeft = s.canvasX - asyncEngine.viewportX
        let visRight = visLeft + s.width
        t.check("async-resize: viewport scrolled so the grown window is fully visible",
                visLeft >= -1 && visRight <= asyncEngine.contentWidth + 1)
        // Cleanup so later assertions keep a clean world/focus.
        asyncWorld.asyncResizeDelay = 0
        asyncWorld.destroyWindow(lEl, notify: false)
        asyncWorld.destroyWindow(rEl, notify: false)
        world.setSystemFocus(engine.slots[engine.focusIndex].window.element)
    }

    // --- ASPECT-LOCKED RESIZE: QuickTime-style windows need height + width ---
    // QuickTime movie windows preserve the video's aspect ratio. A width grow
    // request paired with the OLD short height can be clamped back to the old
    // width, making "resize bigger" appear broken. In fill-height mode the width
    // key must request full column height and target width in the SAME AX write.
    do {
        let qtEngine = TeleportEngine(screenFrame: Headless.defaultVisibleFrame)
        qtEngine.peekInset = 48
        qtEngine.fillHeight = true
        let pid: pid_t = 5750
        let ratio: CGFloat = 16.0 / 9.0
        let qtEl = world.addWindow(pid: pid, title: "QuickTimeAspect",
                                   frame: CGRect(x: 60, y: 80, width: 480, height: 270),
                                   fixedAspectRatio: ratio,
                                   appName: "QuickTime Player")
        let matches = IdentityMatcher.match(
            axWindows: AXSource.windows(forPID: pid),
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        )
        qtEngine.adopt(matched: matches)
        guard qtEngine.slots.count == 1 else {
            t.check("quicktime-aspect-resize: adopted one column", false); return
        }
        world.setSystemFocus(qtEngine.slots[0].window.element)
        let want100 = qtEngine.width(forFraction: 1.0)
        qtEngine.setFocusedWidth(fraction: 1.0)
        Headless.pump(0.05)
        let live = world.frame(of: qtEl)?.size ?? .zero
        t.check("quicktime-aspect-resize: grew to requested wide column",
                abs(live.width - want100) <= 2)
        t.check("quicktime-aspect-resize: model width matches live width",
                abs(qtEngine.slots[0].width - live.width) <= 2)
        t.check("quicktime-aspect-resize: preserved aspect ratio",
                live.height > 0 && abs((live.width / live.height) - ratio) <= 0.01)
        world.destroyWindow(qtEl, notify: false)
        world.setSystemFocus(engine.slots[engine.focusIndex].window.element)
    }

    // --- DISPLAY-CONSTRAINED RESIZE: a RIGHT-edge window must grow to FULL
    // width, not just to the screen edge. The reported bug: with two 50%
    // columns, focus the RIGHT one and hit 100%; macOS curtails an in-place
    // resize at the display's right edge (`constrainFrameRect`), so the window
    // could only fill the remaining viewport space. The engine must REPOSITION
    // the window left (room to the right) BEFORE resizing, then scroll the
    // viewport so the now-full-width window is fully visible. We turn on the
    // sim's `constrainResizeToDisplay` to reproduce the real macOS curtailing. ---
    do {
        let display = Headless.defaultVisibleFrame
        let cEngine = TeleportEngine(screenFrame: display)
        cEngine.peekInset = 48
        cEngine.stripDisplayFrame = Headless.defaultFullFrame
        world.displays = [Headless.defaultFullFrame]
        world.constrainResizeToDisplay = true
        let basePID: pid_t = 5780
        let lEl = world.addWindow(pid: basePID, title: "ConL",
                                  frame: CGRect(x: 60, y: 80, width: 360, height: 500))
        let rEl = world.addWindow(pid: basePID + 1, title: "ConR",
                                  frame: CGRect(x: 460, y: 80, width: 360, height: 500))
        let cm = IdentityMatcher.match(
            axWindows: [basePID, basePID + 1].flatMap { AXSource.windows(forPID: $0) },
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        ).filter { [basePID, basePID + 1].contains($0.ax.pid) }
        cEngine.adopt(matched: cm)
        guard cEngine.slots.count == 2 else {
            t.check("constrained-resize: adopted two columns", false)
            world.constrainResizeToDisplay = false; world.displays = []
            return
        }
        // Make both 50%.
        for i in 0..<2 {
            cEngine.focusIndex = i
            world.setSystemFocus(cEngine.slots[i].window.element)
            cEngine.setFocusedWidth(fraction: 0.5)
            Headless.pump(0.02)
        }
        // Focus the RIGHT column and grow to 100%.
        cEngine.focusIndex = 1
        world.setSystemFocus(cEngine.slots[1].window.element)
        let want100 = cEngine.width(forFraction: 1.0)
        cEngine.setFocusedWidth(fraction: 1.0)
        Headless.pump(0.1)
        let liveR = world.frame(of: rEl)?.width ?? 0
        t.check("constrained-resize: right window grew to FULL width, not the screen edge (\(Int(want100)))",
                abs(liveR - want100) <= 2)
        t.check("constrained-resize: model width matches the live full width",
                abs(cEngine.slots[1].width - liveR) <= 2)
        let s = cEngine.slots[cEngine.focusIndex]
        let visLeft = s.canvasX - cEngine.viewportX
        let visRight = visLeft + s.width
        t.check("constrained-resize: viewport scrolled so the full-width window is fully visible",
                visLeft >= -1 && visRight <= cEngine.contentWidth + 1)
        // Cleanup shared sim state.
        world.constrainResizeToDisplay = false
        world.displays = []
        world.destroyWindow(lEl, notify: false)
        world.destroyWindow(rEl, notify: false)
        world.setSystemFocus(engine.slots[engine.focusIndex].window.element)
    }

    // --- BULK WIDTH (setAllWidths): `scrollwm width all 100` / `arrange 100`
    // must grow EVERY column to the full width with the model matching reality,
    // even though every adopted window starts anchored at a different x (some
    // near the display's right edge). The bulk path pre-moves each window to a
    // spot with room to the right BEFORE growing it, exactly like the focused
    // width key, so macOS's in-place resize clamp never strands a column narrow
    // and desynced. Same sim `constrainResizeToDisplay` curtailing as above. ---
    do {
        let display = Headless.defaultVisibleFrame
        let aEngine = TeleportEngine(screenFrame: display)
        aEngine.peekInset = 48
        aEngine.stripDisplayFrame = Headless.defaultFullFrame
        world.displays = [Headless.defaultFullFrame]
        world.constrainResizeToDisplay = true
        let basePID: pid_t = 5980
        // Three windows tiled left-to-right; the rightmost starts hard against
        // the display's right edge so an in-place grow there would be curtailed.
        var els: [AXUIElement] = []
        for i in 0..<3 {
            els.append(world.addWindow(pid: basePID + pid_t(i), title: "AllW-\(i)",
                                       frame: CGRect(x: 80 + CGFloat(i) * 480, y: 80,
                                                     width: 440, height: 500)))
        }
        let am = IdentityMatcher.match(
            axWindows: (0..<3).flatMap { AXSource.windows(forPID: basePID + pid_t($0)) },
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        ).filter { (basePID..<(basePID + 3)).contains($0.ax.pid) }
        aEngine.adopt(matched: am)
        guard aEngine.slots.count == 3 else {
            t.check("bulk-width: adopted three columns", false)
            world.constrainResizeToDisplay = false; world.displays = []
            return
        }
        // Grow EVERY column to 100% in one bulk op.
        let want100 = aEngine.width(forFraction: 1.0)
        let n = aEngine.setAllWidths(fraction: 1.0)
        Headless.pump(0.1)
        t.check("bulk-width: resized all three columns", n == 3)
        for i in 0..<3 {
            let live = world.frame(of: els[i])?.width ?? 0
            t.check("bulk-width: column \(i) grew to FULL width despite its start x (\(Int(want100)))",
                    abs(live - want100) <= 2)
            t.check("bulk-width: column \(i) model width matches the live width (no desync)",
                    abs(aEngine.slots[i].width - live) <= 2)
        }
        // Cleanup shared sim state.
        world.constrainResizeToDisplay = false
        world.displays = []
        for el in els { world.destroyWindow(el, notify: false) }
        world.setSystemFocus(engine.slots[engine.focusIndex].window.element)
    }

    // --- CLOSE PULL-IN: closing a column that leaves the viewport parked over
    // dead space to the RIGHT must scroll the strip back so the remaining
    // windows fill the gap. The user's "closing a window should sometimes move
    // the viewport" report: with the viewport scrolled to the strip's trailing
    // edge, closing the focused (rightmost) column shrinks the strip; without a
    // pull-in the viewport would hang over emptiness. ---
    do {
        let pEngine = TeleportEngine(screenFrame: Headless.defaultVisibleFrame)
        pEngine.peekInset = 48
        let basePID: pid_t = 5820
        var els: [AXUIElement] = []
        for i in 0..<4 {
            els.append(world.addWindow(pid: basePID + pid_t(i), title: "Pull-\(i)",
                                       frame: CGRect(x: 40 + CGFloat(i) * 420, y: 80,
                                                     width: 700, height: 500)))
        }
        let pm = IdentityMatcher.match(
            axWindows: (0..<4).flatMap { AXSource.windows(forPID: basePID + pid_t($0)) },
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        ).filter { (basePID..<(basePID + 4)).contains($0.ax.pid) }
        pEngine.adopt(matched: pm)
        guard pEngine.slots.count == 4 else {
            t.check("close-pull-in: adopted four columns", false); return
        }
        // Scroll to the rightmost column: the viewport sits at the strip's
        // trailing edge (maxViewportX).
        pEngine.focusIndex = 3
        world.setSystemFocus(pEngine.slots[3].window.element)
        pEngine.focus(index: 3)
        t.check("close-pull-in: viewport at the strip's trailing edge before close",
                abs(pEngine.viewportX - pEngine.maxViewportX) < 1 && pEngine.viewportX > 1)
        // Close the focused rightmost column. The strip shrinks; the viewport
        // must pull in so no dead space is left to the right.
        _ = pEngine.closeFocused()
        Headless.pump(0.05)
        t.check("close-pull-in: a column was removed", pEngine.slots.count == 3)
        t.check("close-pull-in: viewport never sits past the strip's trailing edge",
                pEngine.viewportX <= pEngine.maxViewportX + 0.5)
        // Right edge of the last column must not leave a gap wider than the
        // peek lane on the right side of the content region.
        if let last = pEngine.slots.last {
            let lastRight = last.canvasX + last.width - pEngine.viewportX
            t.check("close-pull-in: last column reaches the content region's right edge (no dead space)",
                    lastRight >= pEngine.contentWidth - pEngine.gap - 1)
        }
        for el in els { world.destroyWindow(el, notify: false) }
        world.setSystemFocus(engine.slots[engine.focusIndex].window.element)
    }

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

    // --- CLI `width all <N>`: resize EVERY column in one command ---
    // Drive the real control-command parser (the `scrollwm` CLI surface) so the
    // verb dispatch + bulk-width path are covered end to end, not just the
    // engine method.
    let allReply = controller.handleControlCommand("width all 50")
    Headless.pump(0.08)
    t.check("`width all 50` reports success", allReply.hasPrefix("ok:"))
    t.check("`width all 50` sized every column to ~50%",
            controller.debugColumnWidths.allSatisfy { abs($0 - want50) <= 1 })
    // `arrange <N>` while already managing re-arranges THEN bulk-sizes.
    let arrReply = controller.handleControlCommand("arrange 25")
    Headless.pump(0.08)
    t.check("`arrange 25` reports success", arrReply.hasPrefix("ok:"))
    t.check("`arrange 25` sized every column to ~25%",
            controller.debugColumnWidths.allSatisfy { abs($0 - want25) <= 1 })
    // A bad width arg is a clean error, not a crash or partial resize.
    let badReply = controller.handleControlCommand("width all wat")
    t.check("`width all wat` is a clean error", badReply.hasPrefix("error:"))
    // Restore 100% so later assertions keep their footing.
    _ = controller.handleControlCommand("width all 100"); Headless.pump(0.06)

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

    // --- Release: places windows nicely + tears down hotkeys ---
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

    // --- Plain arrange: now REVEALS minimized windows and adopts EVERYTHING ---
    // A bare "arrange" un-minimizes (and un-hides) first, so the user's whole
    // current Space lands on the strip, not just what was already visible.
    controller.arrange()
    Headless.pump(0.6) // cover the reveal + deferred resync (asyncAfter ~0.45s)
    t.check("plain arrange reveals + adopts every window incl. minimized (\(total))",
            controller.debugSlotCount == total)
    t.check("no spawned window left minimized after plain arrange",
            pids.flatMap { AXSource.windows(forPID: $0) }.allSatisfy { !$0.isMinimized })

    // Regression: minimizing a window that ScrollWM already manages must NOT be
    // interpreted as an implicit release/removal. Only close or explicit Release
    // should remove it from the strip. The lifecycle poll used to diff against
    // "visible standard" windows and silently dropped this column.
    if let managedVisible = sorted.dropFirst(minimizeCount).first {
        world.setMinimized(managedVisible, true)
        Headless.pump(2.25) // wait for the 2s lifecycle safety-net poll
        t.check("managed minimized window stays in strip until deliberate release/close",
                controller.debugSlotCount == total)
        world.setMinimized(managedVisible, false)
        Headless.pump(0.1)
    }

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

// MARK: - hiddentest (headless): exhaustive hidden/minimized edge cases
//
// Complements `revealtest` (the happy path) with the edge cases the
// hidden-windows audit surfaced: Cmd+H app reveal end-to-end, EVERY window
// hidden (dormant -> managing only via the deferred adopt), a slow reveal
// animation (the immediate adopt sees nothing; the bounded retry catches it),
// release() cancelling an in-flight reveal follow-up, a window the user
// re-minimizes staying managed, a partial reveal failure, and the reveal-aware
// `scrollwm arrange` CLI reply. All headless: no real window/Space/keystroke.
func runHeadlessHiddenWindowsTest() {
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()
    var t = TestCounter()

    // ---- Case 1: Cmd+H HIDDEN APP is revealed + adopted by a plain arrange ----
    do {
        let world = Headless.install()
        defer { Headless.uninstall(); RestoreStore.clear() }
        let controller = ScrollWMController()
        scrollWMControllerKeepAlive = controller
        let frame = controller.debugScreenFrame
        let (pids, _) = Headless.seedWindows(world, count: 3, startPID: 7000,
                                             within: frame, width: 300, height: 280)
        controller.sandboxPIDs = Set(pids)
        // Hide ONE app entirely (Cmd+H): all its windows leave the on-screen list.
        world.setAppHidden(pids[0], true)
        t.check("case1: hidden app drops out of the on-screen list",
                CGWindowSource.listWindows(onscreenOnly: true).filter { $0.ownerPID == pids[0] }.isEmpty)
        controller.arrange()
        Headless.pump(1.0) // reveal + bounded retry series
        t.check("case1: plain arrange un-hides the Cmd+H app and adopts all 3",
                controller.debugSlotCount == 3)
        t.check("case1: the previously-hidden app is no longer hidden",
                !world.appIsHidden(pid: pids[0]))
        t.check("case1: arrange recorded the unhidden app in its reveal result",
                controller.lastRevealResult.unhiddenApps == 1)
        controller.release()
    }

    // ---- Case 2: EVERY window hidden/minimized -> managing only via deferred ----
    // With a reveal-settle delay the immediate adopt finds NOTHING on-screen, so
    // the controller must reach `isManaging` via the bounded retry. Proves the
    // dormant else-branch (and that the CLI reply is not a false error).
    do {
        let world = Headless.install()
        defer { Headless.uninstall(); RestoreStore.clear() }
        world.revealSettleDelay = 0.25
        let controller = ScrollWMController()
        scrollWMControllerKeepAlive = controller
        let frame = controller.debugScreenFrame
        let (pids, els) = Headless.seedWindows(world, count: 3, startPID: 7100,
                                               within: frame, width: 300, height: 280)
        controller.sandboxPIDs = Set(pids)
        for el in els { world.setMinimized(el, true) }       // ALL minimized
        let reply = controller.handleControlCommand("arrange")
        // Synchronous reply: nothing on-screen yet, but a reveal is pending, so
        // it must NOT be the false "nothing to arrange" error (and not exit 2).
        t.check("case2: CLI reply is success-in-progress, not a false error",
                reply.hasPrefix("ok:") && reply.contains("revealing"))
        t.check("case2: reply surfaces the revealed minimized count",
                reply.contains("3 minimized window(s)"))
        t.check("case2: not yet managing at the synchronous reply (settle delay)",
                controller.debugSlotCount == 0)
        Headless.pump(1.2) // let the settle delay + bounded retry land
        t.check("case2: deferred retry adopts all 3 once they materialize",
                controller.debugSlotCount == 3)
        t.check("case2: reveal-pending flag cleared after the retry series",
                controller.revealAdoptPending == false)
        controller.release()
    }

    // ---- Case 3: release() during the reveal settle CANCELS the follow-up ----
    // The epoch guard must stop a deferred adopt from resurrecting management (or
    // stealing focus) after the user toggled off mid-animation.
    do {
        let world = Headless.install()
        defer { Headless.uninstall(); RestoreStore.clear() }
        world.revealSettleDelay = 0.35
        let controller = ScrollWMController()
        scrollWMControllerKeepAlive = controller
        let frame = controller.debugScreenFrame
        let (pids, els) = Headless.seedWindows(world, count: 3, startPID: 7200,
                                               within: frame, width: 300, height: 280)
        controller.sandboxPIDs = Set(pids)
        // Two visible (so the immediate adopt starts managing) + one minimized
        // (so a reveal follow-up is scheduled).
        world.setMinimized(els[0], true)
        controller.arrange()
        Headless.pump(0.05)
        t.check("case3: immediate adopt started managing the 2 visible windows",
                controller.isManaging && controller.debugSlotCount == 2)
        controller.release()           // user toggles OFF mid-animation
        t.check("case3: released immediately", !controller.isManaging)
        Headless.pump(1.2)             // the would-be deferred adopt fires here
        t.check("case3: deferred follow-up did NOT resurrect management",
                !controller.isManaging)
        t.check("case3: strip stays empty after a cancelled reveal follow-up",
                controller.debugSlotCount == 0)
    }

    // ---- Case 4: a managed window the user RE-MINIMIZES stays in the strip ----
    // The resync removal gate keys on role (AXWindow), which is stable across
    // minimize even though macOS flips the subrole to AXDialog in the Dock (the
    // sim models that flip). The column must survive the 2s safety-net poll.
    do {
        let world = Headless.install()
        defer { Headless.uninstall(); RestoreStore.clear() }
        let controller = ScrollWMController()
        scrollWMControllerKeepAlive = controller
        let frame = controller.debugScreenFrame
        let (pids, els) = Headless.seedWindows(world, count: 3, startPID: 7300,
                                               within: frame, width: 300, height: 280)
        controller.sandboxPIDs = Set(pids)
        controller.arrange()
        Headless.pump(0.2)
        t.check("case4: arranged 3 visible windows", controller.debugSlotCount == 3)
        // Sanity: minimize flips the live subrole but NOT the role.
        world.setMinimized(els[1], true)
        let info = AXSource.windows(forPID: pids[1]).first
        t.check("case4: minimized window's live subrole flipped to AXDialog",
                info?.subrole == kAXDialogSubrole as String)
        t.check("case4: minimized window's role stays AXWindow",
                info?.role == kAXWindowRole as String)
        Headless.pump(2.3) // 2s safety-net poll
        t.check("case4: re-minimized managed window stays in the strip (role-keyed removal)",
                controller.debugSlotCount == 3)
        world.setMinimized(els[1], false)
        controller.release()
    }

    // ---- Case 5: partial reveal FAILURE is tolerated (rest still adopt) ----
    do {
        let world = Headless.install()
        defer { Headless.uninstall(); RestoreStore.clear() }
        let controller = ScrollWMController()
        scrollWMControllerKeepAlive = controller
        let frame = controller.debugScreenFrame
        let (pids, els) = Headless.seedWindows(world, count: 3, startPID: 7400,
                                               within: frame, width: 300, height: 280)
        controller.sandboxPIDs = Set(pids)
        for el in els { world.setMinimized(el, true) }
        // The app refuses to un-minimize ONE window; the other two reveal fine.
        world.failUnminimizeFor = [els[0]]
        controller.arrange()
        Headless.pump(1.0)
        t.check("case5: the two revealable windows are adopted despite one failure",
                controller.debugSlotCount == 2)
        t.check("case5: the stubborn window stays minimized (reveal tolerated the failure)",
                AXSource.windows(forPID: pids[0]).first?.isMinimized == true)
        world.failUnminimizeFor = nil
        controller.release()
    }

    print("\n[headless-hiddentest] \(t.passed) passed, \(t.failed) failed")
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
    // The window we expect the newcomer to land to the RIGHT of: the currently
    // focused column's live frame. "Final destination = right of focus" is the
    // core contract the user cares about, so we measure time until the new
    // window's REAL frame reaches that position, not merely until it is adopted.
    let focusedBefore = engine.slots[engine.focusIndex].window.element
    let focusedXBefore = world.frame(of: focusedBefore)?.minX ?? 0
    let t0 = Clock.nowAbsNs()
    let newEl = world.addWindow(pid: seedPID, title: "Seed-2",
                        frame: CGRect(x: 460, y: 80, width: 360, height: 420), notify: true)

    // Time-to-final-position: poll until the new window is BOTH adopted AND its
    // live frame sits to the right of the (previously) focused column. Because
    // the fast-adopt path inserts + teleports in one synchronous pass, this is
    // effectively the instant the user stops seeing it floating at its native
    // spot and sees it in its strip slot.
    var placedNs: UInt64?
    let deadline = Clock.nowAbsNs() + 3_000_000_000
    while Clock.nowAbsNs() < deadline {
        Headless.pump(0.005)
        if engine.slots.count > startCount,
           let f = world.frame(of: newEl), f.minX > focusedXBefore + 1 {
            placedNs = Clock.nowAbsNs(); break
        }
    }
    if let placedNs {
        let ms = Double(placedNs &- t0) / 1e6
        print(String(format: "[headless-spawnlatency] reached final position (right of focus) in %.0f ms", ms))
        t.check("new window adopted", true)
        t.check("new window landed to the RIGHT of the focused column",
                (world.frame(of: newEl)?.minX ?? 0) > focusedXBefore + 1)
        // The new window is inserted at focusIndex (just after the old focus) and
        // becomes the new focus, exactly the PaperWM "open to the right" rule.
        t.check("new window is the column immediately right of the old focus",
                engine.slots.indices.contains(1)
                    && CFEqual(engine.slots[1].window.element, newEl))
        t.check("adoption latency < 1000ms (fast path, not poll)", ms < 1000)
        // Regression guard for this optimization: the always-paid coalesce +
        // first fast-adopt probe must keep the no-publish-race case well under a
        // few frames. (Headless has no real WindowServer lag, so this isolates
        // our own fixed delays.)
        t.check(String(format: "no-race placement is snappy (< 40ms, got %.0fms)", ms), ms < 40)
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

    // --- Phase 2b: the peek lane is reserved, so the parked sliver is NOT
    // covered by on-screen content. The production controller runs with the
    // default config (`peekInset = 48`), which insets every on-screen column so
    // a thin lane stays clear at each screen edge for a parked neighbor to peek
    // through. Assert: (1) the inset is actually active, (2) the FOCUSED (full-
    // width) on-screen window's right edge stops inside the content region (it
    // does not bleed into the right lane), and (3) the parked sliver sits in the
    // (uncovered) left lane, so the two never overlap horizontally. ---
    t.check("peek lane active in production controller (peekInset > 0)",
            controller.debugPeekInset > 0)
    let region = controller.debugContentRegionX
    let contentRight = region.origin + region.width        // right edge of content
    let rightLaneLeft = contentRight                        // lane occupies [contentRight, stripFull.maxX]
    let leftLaneRight = region.origin                       // left lane is [stripFull.minX, region.origin]
    // The focused, full-width window (last column) must stay inside the content
    // region: its right edge cannot extend into the reserved right peek lane.
    let focusedTitle = controller.debugFocusedTitle
    if let ff = liveFrame(title: focusedTitle) {
        t.check("focused on-screen window's left edge is inside the content region",
                ff.minX >= region.origin - 1)
        t.check("focused on-screen window's right edge stays out of the right peek lane",
                ff.maxX <= rightLaneLeft + 1)
    } else {
        t.check("focused window readback available", false)
    }
    // The parked neighbor's sliver lands in the LEFT peek lane (left of all
    // content), so no on-screen window can be drawn over it: the window's full
    // frame is shoved left until only the macOS clamp sliver shows at the very
    // edge, so its right edge stays at or before the content region's left edge.
    if let pf = liveFrame(title: parkedTitle) {
        t.check("parked sliver stays left of the content region (uncovered lane)",
                pf.maxX <= leftLaneRight + 1)
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
