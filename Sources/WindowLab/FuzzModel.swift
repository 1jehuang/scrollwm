import Foundation
import ApplicationServices
import AppKit

// DIFFERENTIAL MODEL-ORACLE fuzzer (owned by the `fuzzmodel` swarm agent).
//
// Goal: maintain an INDEPENDENT reference model of the strip (per-workspace
// column order by stable window id, widths/heights, focusIndex, viewportX
// expectation, vertical-workspace membership, and which window the OS thinks is
// focused) and assert the REAL `TeleportEngine` matches it after EVERY random
// op. This catches SEMANTIC bugs the invariant checks miss:
//   - wrong focus-follow (close/width/move acting on the wrong column),
//   - column ordering after move/close/insert,
//   - workspace membership after switch/move/focus,
//   - viewport-follow math (centered/fit),
//   - which window ends up OS-focused after every op.
//
// Reuse `SplitMix64` from Fuzz.swift. This agent is READ-ONLY on production
// code: it does NOT edit TeleportEngine.swift / StripOps.swift. Any divergence
// is reported (with a minimal seed + op log + expected-vs-actual + root cause)
// back to the coordinator via `swarm report`; the engine is NOT patched here.
//
// Design choices that keep the reference model EXACT (so a divergence is a real
// engine bug, never model drift):
//   - Every sim window is given `minSize == .zero`, so `setSize` is never
//     clamped and the readback equals the request. Widths are then fully
//     deterministic: native frame width on adopt/insert, `width(forFraction:)`
//     on a width key, `equalShareWidth` on fit-all. (Min-size clamps + width
//     parity are already stressed by `fuzzEngine`; this fuzzer's value is in
//     ORDER / FOCUS / WORKSPACE / VIEWPORT semantics.)
//   - One sim window per pid, so `pid` is a stable, process-unique window id we
//     can key the model on (mirroring the engine's CFEqual element identity).
//   - The run loop is never pumped, so the engine's async width-reconcile
//     (`DispatchQueue.main.asyncAfter`) never fires. Every op is synchronous and
//     deterministic, exactly like `fuzzEngine`.
//   - No display rebind / external-resize ops (covered by fuzzdisp/fuzzEngine):
//     `screenFrame` is constant, so the model's viewport math is stable.

// MARK: - Reference model

/// A pure, dependency-free reference model of the teleport strip. It encodes
/// the SAME semantics as `TeleportEngine` but in a totally independent
/// implementation, so agreeing with the engine after a long op sequence is
/// strong evidence both are correct (and a disagreement localizes a bug).
private struct StripModel {
    /// Per-window geometry that travels WITH the window across workspaces.
    struct Win { var width: CGFloat; var height: CGFloat }

    /// One vertical workspace: an ordered column list (by pid), plus its own
    /// focus + viewport. Mirrors `TeleportEngine.Workspace`.
    struct WS { var cols: [pid_t] = []; var focusIndex = 0; var viewportX: CGFloat = 0 }

    // Engine config (must match the engine instance exactly).
    let screenW: CGFloat
    let originY: CGFloat
    let gap: CGFloat
    let minColumnWidth: CGFloat
    let widthPresets: [CGFloat]
    let focusMode: TeleportEngine.FocusMode
    var spawnWidthFraction: CGFloat?

    var win: [pid_t: Win] = [:]
    var workspaces: [WS] = [WS()]
    var active = 0
    /// pid of the window the OS currently considers focused, or nil.
    var systemFocus: pid_t?

    var activeCols: [pid_t] { workspaces[active].cols }
    var activeFocus: Int { workspaces[active].focusIndex }
    var activeViewportX: CGFloat { workspaces[active].viewportX }

    // MARK: width math (replicates StripOps.width(forFraction:) bit-for-bit)

    func width(forFraction fraction: CGFloat) -> CGFloat {
        let clamped = max(0.05, min(1.0, fraction))
        let w = clamped * (screenW - gap) - gap
        return max(minColumnWidth, w.rounded())
    }
    func equalShareWidth(count: Int) -> CGFloat {
        count > 0 ? width(forFraction: 1.0 / CGFloat(count)) : minColumnWidth
    }

    /// Compact canvasX of column `i` in `cols`: `gap | w0 | gap | w1 | ...`.
    func canvasX(of cols: [pid_t], at i: Int) -> CGFloat {
        var x = gap
        for j in 0..<i { x += win[cols[j]]!.width + gap }
        return x
    }

    // MARK: viewport math (replicates TeleportEngine.viewportTarget)

    func viewportTarget(canvasX: CGFloat, width: CGFloat, currentViewportX vx: CGFloat) -> CGFloat {
        switch focusMode {
        case .centered:
            return max(0, canvasX - (screenW - width) / 2)
        case .fit:
            let viewRight = vx + screenW
            let slotRight = canvasX + width
            if width >= screenW { return max(0, canvasX - gap) }
            if canvasX < vx { return max(0, canvasX - gap) }
            if slotRight > viewRight { return slotRight - screenW + gap }
            return vx
        }
    }

    // MARK: navigation

    /// Replicate `TeleportEngine.focus(index:)`: clamp, set focus, re-fit the
    /// viewport, and (because the engine raises + AXFocuses the window) make it
    /// the OS-focused window. No-op on an empty active workspace.
    mutating func focus(index: Int) {
        guard !activeCols.isEmpty else { return }
        let clamped = max(0, min(activeCols.count - 1, index))
        workspaces[active].focusIndex = clamped
        let pid = activeCols[clamped]
        let cx = canvasX(of: activeCols, at: clamped)
        workspaces[active].viewportX = viewportTarget(canvasX: cx, width: win[pid]!.width,
                                                      currentViewportX: activeViewportX)
        systemFocus = pid // raiseAndFocus -> AXFocused -> sim focus
    }

    /// Replicate `syncFocusToSystemFocusedWindow`: if the OS-focused window is a
    /// column of the ACTIVE workspace, adopt its index as the focus. Index only;
    /// no viewport change, no raise.
    mutating func syncFocusToSystem() {
        guard !activeCols.isEmpty, let f = systemFocus else { return }
        if let idx = activeCols.firstIndex(of: f) { workspaces[active].focusIndex = idx }
    }

    // MARK: workspace switching (replicates activateWorkspace + prune)

    /// Mirror `TeleportEngine.pruneEmptyWorkspaces`: drop EVERY empty workspace
    /// except the active one (not just trailing ones), shifting `active` left by
    /// the count of removed workspaces that preceded it. The engine generalized
    /// this after the state-space explorer found a phantom empty workspace left
    /// above/between content by the old trailing-only prune.
    private mutating func pruneEmptyWorkspaces() {
        guard workspaces.count > 1 else { return }
        var kept: [WS] = []
        var newActive = active
        for (i, w) in workspaces.enumerated() {
            if w.cols.isEmpty && i != active {
                if i < active { newActive -= 1 }
                continue
            }
            kept.append(w)
        }
        workspaces = kept
        active = max(0, min(newActive, workspaces.count - 1))
    }

    /// Replicate `activateWorkspace(index)`: load the destination, collapse any
    /// now-empty non-active workspace, then focus (or, on an empty destination,
    /// reset viewport/focus with NO OS-focus change).
    private mutating func activate(_ index: Int) {
        guard workspaces.indices.contains(index), index != active else { return }
        active = index
        pruneEmptyWorkspaces()
        if !activeCols.isEmpty {
            focus(index: activeFocus)
        } else {
            workspaces[active].viewportX = 0
            workspaces[active].focusIndex = 0
            // empty destination: no raiseAndFocus, so systemFocus is unchanged.
        }
    }

    mutating func switchWorkspace(by delta: Int) {
        guard delta != 0 else { return }
        if delta < 0 {
            let target = max(0, active + delta)
            if target != active { activate(target) }
            return
        }
        let target = min(active + delta, workspaces.count)
        if target >= workspaces.count {
            if activeCols.isEmpty { return }   // nothing below an empty workspace
            workspaces.append(WS())
        }
        activate(target)
    }

    mutating func moveFocusedToWorkspace(by delta: Int) {
        guard !activeCols.isEmpty, delta != 0 else { return }
        let target = min(active + delta, workspaces.count)
        if target < 0 { return }
        if target >= workspaces.count { workspaces.append(WS()) }
        let moved = workspaces[active].cols.remove(at: activeFocus)
        workspaces[active].focusIndex = activeCols.isEmpty ? 0 : max(0, min(activeFocus, activeCols.count - 1))
        workspaces[target].cols.append(moved)
        workspaces[target].focusIndex = workspaces[target].cols.count - 1
        activate(target)
    }

    mutating func focusWorkspace(_ index: Int) {
        let clamped = max(0, min(workspaces.count - 1, index))
        if clamped != active { activate(clamped) }
    }

    // MARK: width / move / close / fit / insert

    mutating func setFocusedWidth(fraction: CGFloat) {
        syncFocusToSystem()
        guard !activeCols.isEmpty else { return }
        let pid = activeCols[activeFocus]
        win[pid]!.width = width(forFraction: fraction)   // minSize 0 => readback == request
        focus(index: activeFocus)                        // re-centers viewport
    }

    mutating func moveFocused(by delta: Int) {
        syncFocusToSystem()
        guard activeCols.count > 1 else { return }
        let target = activeFocus + delta
        guard activeCols.indices.contains(target) else { return }
        workspaces[active].cols.swapAt(activeFocus, target)
        workspaces[active].focusIndex = target
        focus(index: target)
    }

    mutating func closeFocused() {
        syncFocusToSystem()
        guard !activeCols.isEmpty else { return }
        let closed = activeCols[activeFocus]
        // pressCloseButton clears sim focus iff the closed window was OS-focused.
        if systemFocus == closed { systemFocus = nil }
        workspaces[active].cols.remove(at: activeFocus)
        // removeSlots: focused window is gone, so clamp the old index into range.
        workspaces[active].focusIndex = activeCols.isEmpty ? 0 : max(0, min(activeFocus, activeCols.count - 1))
        if !activeCols.isEmpty { focus(index: activeFocus) }
        // else: empty -> teleport only, viewportX unchanged, systemFocus stays nil/unchanged.
    }

    mutating func fitAllColumns() {
        guard !activeCols.isEmpty else { return }
        let target = equalShareWidth(count: activeCols.count)
        for pid in activeCols { win[pid]!.width = target }
        workspaces[active].viewportX = 0
        // teleport only: focusIndex + systemFocus unchanged.
    }

    /// Replicate the production fast-adopt of a single new window
    /// (`adoptOneNewWindow`): insert after the current focus, apply the spawn
    /// width, compact, then focus it. NOTE: no syncFocusToSystem (the real path
    /// uses the engine's own focusIndex).
    mutating func newWindow(pid: pid_t, nativeWidth: CGFloat, nativeHeight: CGFloat) {
        let insertAt = activeCols.isEmpty ? 0 : activeFocus + 1
        var width = nativeWidth
        // applySpawnWidth (minSize 0 => no snap-up): only resizes if the native
        // width differs from the target by more than a point.
        if let frac = spawnWidthFraction {
            let target = self.width(forFraction: frac)
            if abs(nativeWidth - target) > 1 { width = target }
        }
        win[pid] = Win(width: width, height: nativeHeight)
        let clamped = max(0, min(insertAt, activeCols.count))
        workspaces[active].cols.insert(pid, at: clamped)
        focus(index: insertAt)
    }

    /// Replicate `adopt`: lay out the windows in order, reset to one workspace,
    /// focus 0 WITHOUT raising (commitAll teleports only => systemFocus stays).
    mutating func adopt(order: [pid_t], widths: [pid_t: CGFloat], heights: [pid_t: CGFloat]) {
        win = [:]
        for pid in order { win[pid] = Win(width: widths[pid]!, height: heights[pid]!) }
        workspaces = [WS(cols: order, focusIndex: 0, viewportX: 0)]
        active = 0
        // commitAll() is a teleport, not a focus: no raiseAndFocus, so the OS
        // focus is whatever it was (nil at the start of a run).
        systemFocus = nil
    }

    /// Every managed pid across ALL workspaces, in (workspace, column) order.
    var allManagedPids: [pid_t] {
        var out: [pid_t] = []
        for ws in workspaces { out += ws.cols }
        return out
    }
}

// MARK: - Differential fuzzer

private final class ModelFuzzer {
    let seed: UInt64
    private var rng: SplitMix64
    private let world: SimWindowWorld
    private let engine: TeleportEngine
    private var model: StripModel

    // Engine geometry / config (kept in sync with the model).
    private let screen = CGRect(x: 0, y: 32, width: 1680, height: 1018)

    private var pids: [pid_t] = []
    private var nextPID: pid_t = 7000
    private var elementOf: [pid_t: AXUIElement] = [:]
    /// Native spawn size of each pid (used to drive adopt/insert in the model).
    private var nativeSize: [pid_t: CGSize] = [:]

    private(set) var log: [String] = []
    var verbose = false

    private func record(_ op: String) {
        log.append(op)
        if verbose { print(String(format: "  %4d  %@", log.count - 1, op as NSString)) }
    }

    init(seed: UInt64) {
        self.seed = seed
        self.rng = SplitMix64(seed: seed)
        self.world = SimWindowWorld()       // displays empty: no parking clamp needed
        AXSource.backend = world
        self.engine = TeleportEngine(screenFrame: screen)
        engine.gap = 12
        engine.minColumnWidth = 200
        engine.widthPresets = [0.25, 0.5, 0.75, 1.0]
        engine.focusMode = (seed & 1 == 0) ? .fit : .centered
        engine.spawnWidthFraction = nil      // overwritten in run()
        self.model = StripModel(
            screenW: screen.width, originY: screen.origin.y,
            gap: engine.gap, minColumnWidth: engine.minColumnWidth,
            widthPresets: engine.widthPresets,
            focusMode: engine.focusMode,
            spawnWidthFraction: nil)
    }

    deinit { AXSource.backend = nil }

    // MARK: sim helpers

    /// Spawn a sim window (minSize zero so `setSize` is never clamped: the model
    /// stays exact). Widths sometimes exceed the screen to exercise fit/overflow.
    private func spawn() -> pid_t {
        let pid = nextPID; nextPID += 1
        pids.append(pid)
        let w = rng.double(in: 150...2200)
        let h = rng.double(in: 150...1400)
        let el = world.addWindow(pid: pid, title: "W\(pid)",
                                 frame: CGRect(x: 0, y: 0, width: w, height: h),
                                 minSize: .zero)
        elementOf[pid] = el
        nativeSize[pid] = CGSize(width: w, height: h)
        return pid
    }

    private func standardWindows() -> [AXWindowInfo] {
        pids.flatMap { AXSource.windows(forPID: $0) }
            .filter { $0.subrole == kAXStandardWindowSubrole as String
                && !$0.isMinimized && !$0.isFullscreen }
    }
    private func matchedNow() -> [MatchedWindow] {
        IdentityMatcher.match(axWindows: standardWindows(),
                              cgWindows: CGWindowSource.listWindows(onscreenOnly: true))
    }

    // MARK: run

    func run(steps: Int) -> String? {
        // Seed an initial arrange of 1...6 windows.
        let initial = rng.int(in: 1...6)
        var order: [pid_t] = []
        for _ in 0..<initial { order.append(spawn()) }
        let frac: CGFloat? = rng.bool() ? rng.pick([0.25, 0.5, 0.75, 1.0]) : nil
        engine.spawnWidthFraction = frac
        model.spawnWidthFraction = frac
        record("arrange(\(initial), spawnWidth=\(frac.map { "\($0)" } ?? "nil"), mode=\(engine.focusMode.rawValue))")

        engine.adopt(matched: matchedNow())
        // Adopt order/sizes = spawn order + native frame (IdentityMatcher preserves
        // input order, adopt stores the real frame width/height with minSize 0).
        var widths: [pid_t: CGFloat] = [:], heights: [pid_t: CGFloat] = [:]
        for pid in order { widths[pid] = nativeSize[pid]!.width; heights[pid] = nativeSize[pid]!.height }
        model.adopt(order: order, widths: widths, heights: heights)
        if let v = diff(after: "arrange") { return v }

        for step in 0..<steps {
            performRandomOp()
            if let v = diff(after: "step \(step)") { return v }
        }
        return nil
    }

    private func performRandomOp() {
        enum Op: CaseIterable {
            case focusIndex, focusNext, focusPrev, width, move, close
            case newWindow, switchWS, moveToWS, focusWS, fitAll, userClick
        }
        switch rng.pick(Op.allCases) {
        case .focusIndex:
            let i = rng.int(in: -2...(engine.slots.count + 2))
            record("focus(\(i))")
            engine.focus(index: i); model.focus(index: i)
        case .focusNext:
            record("focusNext")
            engine.focusNext(); model.focus(index: model.activeFocus + 1)
        case .focusPrev:
            record("focusPrev")
            engine.focusPrevious(); model.focus(index: model.activeFocus - 1)
        case .width:
            let frac = rng.pick([CGFloat(0.25), 0.5, 0.75, 1.0, 0.0, -1.0, 2.0, 0.001])
            record("setFocusedWidth(\(frac))")
            _ = engine.setFocusedWidth(fraction: frac); model.setFocusedWidth(fraction: frac)
        case .move:
            let d = rng.pick([-2, -1, 1, 2])
            record("moveFocused(\(d))")
            _ = engine.moveFocused(by: d); model.moveFocused(by: d)
        case .close:
            record("closeFocused")
            _ = engine.closeFocused(); model.closeFocused()
        case .newWindow:
            let pid = spawn()
            record("newWindow(pid=\(pid))")
            guard let info = AXSource.windows(forPID: pid).first else { return }
            let insertAt = engine.slots.isEmpty ? 0 : engine.focusIndex + 1
            engine.insert(window: info, at: insertAt)
            engine.applySpawnWidth(toSlotAt: insertAt)
            engine.compactStrip()
            engine.focus(index: insertAt)
            model.newWindow(pid: pid, nativeWidth: nativeSize[pid]!.width, nativeHeight: nativeSize[pid]!.height)
        case .switchWS:
            let d = rng.pick([-2, -1, 1, 2])
            record("switchWorkspace(\(d))")
            _ = engine.switchWorkspace(by: d); model.switchWorkspace(by: d)
        case .moveToWS:
            let d = rng.pick([-1, 1, 2])
            record("moveFocusedToWorkspace(\(d))")
            _ = engine.moveFocusedToWorkspace(by: d); model.moveFocusedToWorkspace(by: d)
        case .focusWS:
            let i = rng.int(in: -1...(engine.workspaceCount + 1))
            record("focusWorkspace(\(i))")
            _ = engine.focusWorkspace(i); model.focusWorkspace(i)
        case .fitAll:
            record("fitAllColumns")
            engine.fitAllColumns(); model.fitAllColumns()
        case .userClick:
            // Model a mouse click / Cmd-Tab landing on a random ACTIVE column:
            // set the OS focus but do NOT move the engine's focusIndex (a later
            // close/width/move op's internal sync is what should follow it).
            guard !engine.slots.isEmpty else { return }
            let i = rng.int(engine.slots.count)
            let el = engine.slots[i].window.element
            world.setSystemFocus(el)
            model.systemFocus = engine.slots[i].window.pid
            record("userClick(slot=\(i))")
        }
    }

    // MARK: differential assertions

    /// pid of the currently OS-focused window (or nil), resolved from the world.
    private func realSystemFocusPid() -> pid_t? {
        guard let el = world.systemFocusedWindow() else { return nil }
        return elementOf.first { CFEqual($0.value, el) }?.key
    }

    private func diff(after ctx: String) -> String? {
        var problems: [String] = []
        func bad(_ s: String) { problems.append(s) }

        let tol: CGFloat = 0.5

        // 1. Workspace count + active index.
        if engine.workspaceCount != model.workspaces.count {
            bad("workspaceCount: engine \(engine.workspaceCount) vs model \(model.workspaces.count)")
        }
        if engine.activeWorkspace != model.active {
            bad("activeWorkspace: engine \(engine.activeWorkspace) vs model \(model.active)")
        }

        // 2. Active workspace: order, widths, heights, compact canvasX, y.
        let slots = engine.slots
        let cols = model.activeCols
        if slots.count != cols.count {
            bad("active column count: engine \(slots.count) vs model \(cols.count)")
        } else {
            for i in slots.indices {
                let s = slots[i]; let pid = cols[i]
                if s.window.pid != pid {
                    bad("active order[\(i)]: engine pid \(s.window.pid) vs model pid \(pid)")
                    continue
                }
                let mw = model.win[pid]!
                if abs(s.width - mw.width) > tol { bad("width pid \(pid): engine \(s.width) vs model \(mw.width)") }
                if abs(s.height - mw.height) > tol { bad("height pid \(pid): engine \(s.height) vs model \(mw.height)") }
                let cx = model.canvasX(of: cols, at: i)
                if abs(s.canvasX - cx) > tol { bad("canvasX[\(i)] pid \(pid): engine \(s.canvasX) vs model \(cx)") }
                if abs(s.y - model.originY) > tol { bad("y[\(i)] pid \(pid): engine \(s.y) vs expected \(model.originY)") }
            }
        }

        // 3. Active focus + viewport.
        if engine.focusIndex != model.activeFocus {
            bad("focusIndex: engine \(engine.focusIndex) vs model \(model.activeFocus)")
        }
        if abs(engine.viewportX - model.activeViewportX) > tol {
            bad("viewportX: engine \(engine.viewportX) vs model \(model.activeViewportX)")
        }

        // 4. Full workspace membership (every workspace, in order) via the only
        // cross-workspace accessor the engine exposes: allManagedSlots.
        let allEnginePids = engine.allManagedSlots.map { $0.window.pid }
        let allModelPids = model.allManagedPids
        if allEnginePids != allModelPids {
            bad("allManagedSlots membership/order: engine \(allEnginePids) vs model \(allModelPids)")
        }
        // No duplicate managed window across all workspaces.
        if Set(allEnginePids).count != allEnginePids.count {
            bad("engine has a duplicate managed window: \(allEnginePids)")
        }

        // 5. OS keyboard focus parity (drives close/width/move's focus-follow).
        let realFocus = realSystemFocusPid()
        if realFocus != model.systemFocus {
            bad("systemFocus: engine OS focus pid \(realFocus.map(String.init) ?? "nil") vs model \(model.systemFocus.map(String.init) ?? "nil")")
        }

        guard !problems.isEmpty else { return nil }
        return """
        MODEL/ENGINE DIVERGENCE after \(ctx):
          seed: \(seed)   focusMode: \(engine.focusMode.rawValue)   steps logged: \(log.count)
          mismatches:
            - \(problems.joined(separator: "\n    - "))
          engine: ws=\(engine.workspaceCount) active=\(engine.activeWorkspace) focus=\(engine.focusIndex) vx=\(engine.viewportX)
                  active cols (pid:w) = \(slots.map { "\($0.window.pid):\(Int($0.width))" })
                  allManaged = \(allEnginePids)
          model:  ws=\(model.workspaces.count) active=\(model.active) focus=\(model.activeFocus) vx=\(model.activeViewportX)
                  active cols (pid:w) = \(cols.map { "\($0):\(Int(model.win[$0]?.width ?? -1))" })
                  allManaged = \(allModelPids)
          ops (\(log.count)):
            \(log.joined(separator: "\n    "))

          Replay: WindowLab fuzzmodel --replay \(seed) --steps <stepsUsed>
        """
    }
}

// MARK: - Entry point

/// `WindowLab fuzzmodel [baseSeed] [--steps N] [--seeds K] [--replay SEED]
///                      [--verbose]`
///
/// Default: K differential runs derived from the base seed (the base seed runs
/// first), each doing `steps` random ops, asserting model == engine after each.
/// Deterministic: a failing seed replays bit-for-bit. `--replay SEED` runs one
/// seed verbosely (live op log + final state) regardless of outcome.
func runFuzzModel(args: [String]) -> Never {
    func intArg(_ flag: String, _ def: Int) -> Int {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return def }
        return Int(args[i + 1]) ?? def
    }
    func u64Arg(_ flag: String) -> UInt64? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return UInt64(args[i + 1])
    }

    let steps = intArg("--steps", 400)
    let seedCount = intArg("--seeds", 200)
    let verbose = args.contains("--verbose")

    // --replay: run one seed verbosely and dump the full op log + outcome.
    if let replay = u64Arg("--replay") {
        print("== fuzzmodel replay: seed \(replay), \(steps) steps ==")
        let f = ModelFuzzer(seed: replay)
        f.verbose = true
        print("ops (live; the LAST line printed is the culprit if it hard-crashes):")
        let result = f.run(steps: steps)
        if let v = result { print("\n\(v)"); exit(1) }
        print("\nno divergence for seed \(replay) (\(f.log.count) ops)")
        exit(0)
    }

    let baseSeed = args.dropFirst().first.flatMap { UInt64($0) }
        ?? UInt64(Date().timeIntervalSince1970)

    print("== ScrollWM fuzzmodel ==  base seed \(baseSeed)")
    print("-- differential model-oracle: \(seedCount) seeds x \(steps) steps --")

    var totalFail = 0
    var firstFail: String?
    var firstFailSeed: UInt64?
    for k in 0..<seedCount {
        let seed = baseSeed &+ UInt64(k) &* 0x100000001B3
        let f = ModelFuzzer(seed: seed)
        f.verbose = verbose
        if let v = f.run(steps: steps) {
            totalFail += 1
            if firstFail == nil { firstFail = v; firstFailSeed = seed }
            print("  \u{2717} seed \(seed) DIVERGED")
        }
        if (k + 1) % 25 == 0 || k + 1 == seedCount {
            print("JCODE_PROGRESS {\"current\":\(k + 1),\"total\":\(seedCount),\"unit\":\"seeds\",\"message\":\"fuzzmodel\"}")
        }
    }

    print("\n========================================")
    if totalFail == 0 {
        print("FUZZMODEL PASSED: all \(seedCount) seeds agree (\(seedCount * steps) ops, 0 divergences)")
        exit(0)
    } else {
        if let f = firstFail { print("\n\(f)") }
        print("\nFUZZMODEL FAILED: \(totalFail) diverging seed(s)")
        if let s = firstFailSeed {
            print("Replay the first: WindowLab fuzzmodel --replay \(s) --steps \(steps)")
        }
        exit(1)
    }
}
