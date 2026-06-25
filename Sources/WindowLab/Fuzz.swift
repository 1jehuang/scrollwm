import Foundation
import ApplicationServices
import AppKit

// Seeded, reproducible FUZZ testing for ScrollWM.
//
// Two complementary fuzzers, both fully HEADLESS (they install a
// `SimWindowWorld` as `AXSource.backend`, so no real window is ever spawned,
// moved, focused, or closed, and no global keystroke is injected — safe to run
// while you work):
//
//   1. ENGINE fuzzer (`fuzzEngine`): a stateful, synchronous property test that
//      drives the EXACT production `TeleportEngine` + strip-ops + lifecycle
//      adopt/drop/resize logic against the sim world with a long sequence of
//      randomly chosen operations (focus, width, move, close, new-window adopt,
//      external-resize reconcile, vertical-workspace switch/move, fit-all,
//      display rebind, release/re-arrange). After EVERY step it asserts a set of
//      model invariants (compactness, focus/workspace bounds, finite geometry,
//      no duplicate windows, model-vs-reality width parity). A violation prints
//      the seed and the full replayable op log, so any failure is deterministic
//      to reproduce with `WindowLab fuzz --replay <seed>`.
//
//   2. PURE fuzzer (`fuzzPure`): randomized property tests of the dependency-free
//      logic (SemVer ordering is a total order, width/viewportTarget math is
//      finite + monotone + keeps a fitting column visible, ResyncPlanner emits
//      only legal add/remove sets, AdoptionScope.filter is a sorted idempotent
//      subset, DisplayGeometry.ensureVisible always lands visible, Chord parsing
//      never crashes). These need no AX/AppKit state at all.
//
// Reproducibility: everything is driven by a single 64-bit seed through a
// SplitMix64 PRNG, so a given (seed, step-budget) replays bit-for-bit. The
// engine fuzzer logs each operation it performs; on the first invariant
// violation it dumps that log next to the seed.

// MARK: - Deterministic PRNG (SplitMix64)

/// A tiny, fast, fully-deterministic PRNG. We deliberately do NOT use
/// `SystemRandomNumberGenerator` (non-reproducible) so a failing seed always
/// replays identically. SplitMix64 is the canonical seeding generator and is
/// more than random enough for fuzzing control flow / geometry.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform integer in `0..<n` (n > 0).
    mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    /// Inclusive integer in `[lo, hi]`.
    mutating func int(in r: ClosedRange<Int>) -> Int { r.lowerBound + int(r.count) }
    /// Uniform Double in `[0,1)`.
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    /// Uniform Double in `[lo, hi]`.
    mutating func double(in r: ClosedRange<Double>) -> Double {
        r.lowerBound + unit() * (r.upperBound - r.lowerBound)
    }
    mutating func bool() -> Bool { next() & 1 == 0 }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
}

// MARK: - Engine fuzzer

/// Stateful fuzzer over the real `TeleportEngine` + sim world.
final class EngineFuzzer {
    private let seed: UInt64
    private var rng: SplitMix64
    private let world: SimWindowWorld
    private let engine: TeleportEngine
    /// Visible (usable) strip frame in AX coords.
    private let screen = CGRect(x: 0, y: 32, width: 1680, height: 1018)
    /// Full strip-display frame (parking reference).
    private let stripFull = CGRect(x: 0, y: 0, width: 1680, height: 1050)

    /// Every pid we have ever spawned (so we can enumerate "all sim windows").
    private var pids: [pid_t] = []
    private var nextPID: pid_t = 7000
    /// Human-readable replay log of every op performed, in order.
    private(set) var log: [String] = []
    /// When true, each op is printed the moment it is recorded, so a HARD crash
    /// (an out-of-range trap in production code) still reveals the culprit op
    /// even though the in-memory log never gets a chance to print.
    var verbose = false

    /// Record an op into the replay log (and echo it live when `verbose`).
    private func record(_ op: String) {
        log.append(op)
        if verbose { print(String(format: "  %4d  %@", log.count - 1, op as NSString)) }
    }

    init(seed: UInt64) {
        self.seed = seed
        self.rng = SplitMix64(seed: seed)
        self.world = SimWindowWorld()
        self.world.displays = [stripFull]
        AXSource.backend = world
        self.engine = TeleportEngine(screenFrame: screen)
        engine.stripDisplayFrame = stripFull
        engine.otherDisplayFrames = []
        engine.gap = 12
        engine.minColumnWidth = 200
        engine.widthPresets = [0.25, 0.5, 0.75, 1.0]
    }

    deinit { AXSource.backend = nil }

    // MARK: sim helpers

    private func spawnSimWindow(minSize: CGSize = .zero) -> (pid_t, AXUIElement) {
        let pid = nextPID; nextPID += 1
        pids.append(pid)
        // Frames range from small to larger-than-screen, sometimes partly off the
        // strip display, to stress the layout/parking/overflow math.
        let w = rng.double(in: 120...2200)
        let h = rng.double(in: 120...1400)
        let x = rng.double(in: -400...1800)
        let y = rng.double(in: 0...900)
        let el = world.addWindow(pid: pid, title: "W\(pid)",
                                 frame: CGRect(x: x, y: y, width: w, height: h),
                                 minSize: minSize)
        return (pid, el)
    }

    /// All standard AX windows currently in the sim (via the real AXSource path).
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

    /// Run `steps` random operations, checking invariants after each. Returns
    /// nil on success, or a (failure message) on the first violation.
    func run(steps: Int) -> String? {
        // Seed an initial arrange of 1...6 windows.
        let initial = rng.int(in: 1...6)
        for _ in 0..<initial { _ = spawnSimWindow(minSize: rng.bool() ? CGSize(width: rng.double(in: 200...900), height: 200) : .zero) }
        record("arrange(\(initial))")
        engine.spawnWidthFraction = rng.bool() ? rng.pick([0.25, 0.5, 0.75, 1.0]) : nil
        engine.focusMode = rng.bool() ? .fit : .centered
        engine.adopt(matched: matchedNow())
        if let v = checkInvariants(after: "arrange") { return v }

        for step in 0..<steps {
            performRandomOp()
            if let v = checkInvariants(after: "step \(step)") { return v }
        }
        return nil
    }

    private func performRandomOp() {
        enum Op: CaseIterable {
            case focusIndex, focusNext, focusPrev, width, move, close
            case newWindow, externalResize, switchWS, moveToWS, focusWS
            case fitAll, rebind, releaseRearrange, setFocusSync, toggleFocusMode
        }
        switch rng.pick(Op.allCases) {
        case .focusIndex:
            let i = rng.int(in: -2...(engine.slots.count + 2))
            record("focus(\(i))"); engine.focus(index: i)
        case .focusNext:
            record("focusNext"); engine.focusNext()
        case .focusPrev:
            record("focusPrev"); engine.focusPrevious()
        case .width:
            // Adversarial fractions: negatives, zero, >1, huge, and NaN/inf.
            let frac = rng.pick([CGFloat(0.25), 0.5, 0.75, 1.0, 0.0, -1.0, 2.0, 1e9,
                                 CGFloat.nan, CGFloat.infinity, 0.001])
            record("setFocusedWidth(\(frac))"); _ = engine.setFocusedWidth(fraction: frac)
        case .move:
            let d = rng.pick([-2, -1, 1, 2])
            record("moveFocused(\(d))"); _ = engine.moveFocused(by: d)
        case .close:
            // Close the OS-focused-or-focused column via the real AX close path.
            if engine.slots.indices.contains(engine.focusIndex) {
                world.setSystemFocus(engine.slots[engine.focusIndex].window.element)
            }
            record("closeFocused"); _ = engine.closeFocused()
        case .newWindow:
            adoptOneNewWindow()
        case .externalResize:
            externalResizeAndReconcile()
        case .switchWS:
            let d = rng.pick([-2, -1, 1, 2])
            record("switchWorkspace(\(d))"); _ = engine.switchWorkspace(by: d)
        case .moveToWS:
            let d = rng.pick([-1, 1, 2])
            record("moveFocusedToWorkspace(\(d))"); _ = engine.moveFocusedToWorkspace(by: d)
        case .focusWS:
            let i = rng.int(in: -1...(engine.workspaceCount + 1))
            record("focusWorkspace(\(i))"); _ = engine.focusWorkspace(i)
        case .fitAll:
            record("fitAllColumns"); engine.fitAllColumns()
        case .rebind:
            randomRebind()
        case .releaseRearrange:
            record("releaseAll+adopt")
            _ = engine.releaseAll(displays: [stripFull])
            engine.adopt(matched: matchedNow())
        case .setFocusSync:
            // Model the user clicking some other window: focus a random managed
            // element in the sim, then reconcile the engine focus to it.
            if !engine.slots.isEmpty {
                let el = engine.slots[rng.int(engine.slots.count)].window.element
                world.setSystemFocus(el)
                record("syncFocusToSystemFocusedWindow")
                _ = engine.syncFocusToSystemFocusedWindow()
            }
        case .toggleFocusMode:
            engine.focusMode = (engine.focusMode == .fit) ? .centered : .fit
            record("focusMode=\(engine.focusMode.rawValue)")
            if engine.slots.indices.contains(engine.focusIndex) { engine.refitViewportToFocused() }
        }
    }

    /// Mirror the production fast-adopt of a single freshly opened window.
    private func adoptOneNewWindow() {
        let (pid, _) = spawnSimWindow()
        record("newWindow(pid=\(pid))")
        guard let info = AXSource.windows(forPID: pid).first else { return }
        let insertAt = engine.slots.isEmpty ? 0 : engine.focusIndex + 1
        engine.insert(window: info, at: insertAt)
        engine.applySpawnWidth(toSlotAt: insertAt)
        engine.compactStrip()
        engine.focus(index: insertAt)
    }

    /// Simulate a window being resized by SOMETHING OTHER than our resize verbs
    /// (a terminal snapping to char cells, the user dragging an edge), then run
    /// the real size-reconcile + repack the resync poll would do.
    private func externalResizeAndReconcile() {
        guard !engine.slots.isEmpty else { return }
        let slot = engine.slots[rng.int(engine.slots.count)]
        let newSize = CGSize(width: rng.double(in: 120...2400), height: rng.double(in: 120...1400))
        record("externalResize(\(slot.window.pid) -> \(Int(newSize.width))x\(Int(newSize.height)))")
        _ = AXSource.setSize(slot.window.element, kAXSizeAttribute as String, newSize)
        if engine.reconcileSizes(from: standardWindows()) {
            engine.compactStrip(); engine.teleport()
        }
    }

    /// Rebind onto a fresh (possibly multi-display) geometry, as a monitor
    /// hotplug / resolution change would.
    private func randomRebind() {
        let w = rng.double(in: 800...3000)
        let h = rng.double(in: 600...2000)
        let menubar = rng.double(in: 0...40)
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        let visible = CGRect(x: 0, y: menubar, width: w, height: h - menubar)
        // Sometimes add a neighbor display so the parking-corner code runs.
        let others: [CGRect] = rng.bool() ? [CGRect(x: w, y: 0, width: 1000, height: h)] : []
        engine.stripDisplayFrame = full
        engine.otherDisplayFrames = others
        world.displays = [full] + others
        record("rebind(\(Int(w))x\(Int(h)), others=\(others.count))")
        _ = engine.rebindStripDisplay(to: visible)
    }

    // MARK: invariants

    /// Returns nil if every invariant holds, else a description of the FIRST
    /// violation (prefixed with the op context).
    private func checkInvariants(after ctx: String) -> String? {
        func fail(_ s: String) -> String {
            """
            INVARIANT VIOLATION after \(ctx): \(s)
              seed: \(seed)
              ops (\(log.count)):
                \(log.joined(separator: "\n    "))
            """
        }

        let slots = engine.slots

        // 1. focusIndex bounds.
        if slots.isEmpty {
            if engine.focusIndex != 0 { return fail("focusIndex \(engine.focusIndex) on empty strip (expected 0)") }
        } else if engine.focusIndex < 0 || engine.focusIndex >= slots.count {
            return fail("focusIndex \(engine.focusIndex) out of range 0..<\(slots.count)")
        }

        // 2. Workspace bounds.
        if engine.workspaceCount < 1 { return fail("workspaceCount \(engine.workspaceCount) < 1") }
        if engine.activeWorkspace < 0 || engine.activeWorkspace >= engine.workspaceCount {
            return fail("activeWorkspace \(engine.activeWorkspace) out of range 0..<\(engine.workspaceCount)")
        }

        // 3. Finite + positive geometry, viewportX non-negative.
        if !engine.viewportX.isFinite || engine.viewportX < -0.5 {
            return fail("viewportX not a sane value: \(engine.viewportX)")
        }
        for (i, s) in slots.enumerated() {
            for (name, v) in [("canvasX", s.canvasX), ("width", s.width), ("height", s.height), ("y", s.y)] {
                if !v.isFinite { return fail("slot[\(i)] (\(s.window.title)) \(name) is non-finite: \(v)") }
            }
            if s.width <= 0 { return fail("slot[\(i)] (\(s.window.title)) width <= 0: \(s.width)") }
            if s.height <= 0 { return fail("slot[\(i)] (\(s.window.title)) height <= 0: \(s.height)") }
        }

        // 4. Strip is compact (gap-separated, leading gap margin). Every public
        // op ends by compacting (we mirror that for raw inserts), so this must
        // always hold at a step boundary.
        var x = engine.gap
        for (i, s) in slots.enumerated() {
            if abs(s.canvasX - x) > 0.5 {
                return fail("strip not compact at slot[\(i)] (\(s.window.title)): canvasX \(s.canvasX) expected \(x)")
            }
            x += s.width + engine.gap
        }

        // 5. No duplicate managed windows across ALL workspaces (a window must
        // never be tiled in two columns at once — the classic re-adopt bug).
        let all = engine.allManagedSlots
        for a in 0..<all.count {
            for b in (a + 1)..<all.count {
                if CFEqual(all[a].window.element, all[b].window.element) {
                    return fail("duplicate managed window: \(all[a].window.title) appears in two columns")
                }
            }
        }

        // 6. Model-vs-reality WIDTH parity for healthy active-strip windows. The
        // engine promises model == real frame (it reads back after every resize
        // and never trusts a request), so a divergence here is the desync class
        // of bug the whole codebase is built to avoid. (Height is intentionally
        // NOT checked: `rebindStripDisplay` clamps the model height to the new
        // usable area without resizing the real window, by design.)
        for s in slots where s.window.healthy {
            guard let real = world.frame(of: s.window.element) else {
                return fail("healthy managed window \(s.window.title) is gone from the world")
            }
            if abs(s.width - real.width) > 1.5 {
                return fail("width desync for \(s.window.title): model \(s.width) vs real \(real.width)")
            }
        }

        return nil
    }
}

// MARK: - Pure-function property fuzzer

enum PureFuzz {
    /// Run `iterations` randomized property checks. Returns a list of failure
    /// messages (empty on success).
    static func run(seed: UInt64, iterations: Int) -> [String] {
        var rng = SplitMix64(seed: seed)
        var failures: [String] = []
        func bad(_ s: String) { failures.append(s); if failures.count > 25 { /* cap noise */ } }

        // --- SemVer: parse never traps; ordering is a strict total order. ---
        func randomVersion(_ r: inout SplitMix64) -> String {
            // Mostly well-formed, sometimes garbage, to exercise both paths.
            if r.int(8) == 0 {
                let junk = "vV.+-rcdevalpha0123456789 "
                let n = r.int(in: 0...10)
                return String((0..<n).map { _ in junk[junk.index(junk.startIndex, offsetBy: r.int(junk.count))] })
            }
            let pre = r.pick(["", "", "", "-dev", "-rc.1", "-rc.2", "-alpha", "-beta.1"])
            return "v\(r.int(in: 0...5)).\(r.int(in: 0...9)).\(r.int(in: 0...9))\(pre)"
        }
        for _ in 0..<iterations {
            let strs = (0..<3).map { _ in randomVersion(&rng) }
            // Parsing must never crash; that alone is a property (we are here).
            let vs = strs.compactMap { SemVer($0) }
            // Irreflexivity + antisymmetry over each pair.
            for i in vs.indices {
                if vs[i] < vs[i] { bad("SemVer irreflexivity: \(vs[i]) < itself") }
                for j in vs.indices where j != i {
                    if vs[i] < vs[j] && vs[j] < vs[i] {
                        bad("SemVer antisymmetry: \(vs[i]) and \(vs[j]) each < the other")
                    }
                }
            }
            // Transitivity over the triple when all three parsed.
            if vs.count == 3 {
                let (a, b, c) = (vs[0], vs[1], vs[2])
                if a < b && b < c && !(a < c) { bad("SemVer transitivity broke: \(a) < \(b) < \(c) but !(\(a) < \(c))") }
            }
        }

        // --- width(forFraction:) finite, floored, monotone non-decreasing. ---
        do {
            let engine = TeleportEngine(screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
            for _ in 0..<iterations {
                let f = CGFloat(rng.double(in: -5...5))
                let w = engine.width(forFraction: f)
                if !w.isFinite { bad("width(forFraction:\(f)) non-finite: \(w)") }
                if w < engine.minColumnWidth - 0.5 { bad("width(\(f))=\(w) below floor \(engine.minColumnWidth)") }
                // Monotone: a larger (clamped) fraction never yields a narrower column.
                let f2 = f + CGFloat(rng.double(in: 0...3))
                if engine.width(forFraction: f2) + 0.5 < w {
                    bad("width not monotone: width(\(f2)) < width(\(f))")
                }
            }
            // NaN must be tolerated (clamped), never propagated.
            let wn = engine.width(forFraction: .nan)
            if !wn.isFinite { bad("width(forFraction: NaN) propagated NaN") }
        }

        // --- viewportTarget: finite, >= 0, and a fully-visible column never moves. ---
        do {
            for _ in 0..<iterations {
                let screenW = CGFloat(rng.double(in: 600...3000))
                let engine = TeleportEngine(screenFrame: CGRect(x: 0, y: 0, width: screenW, height: 1000))
                let canvasX = CGFloat(rng.double(in: 0...8000))
                let width = CGFloat(rng.double(in: 50...4000))
                let slot = TeleportEngine.Slot(
                    window: TeleportEngine.ManagedWindowRef(
                        element: AXUIElementCreateApplication(1),
                        pid: 1, appName: "x", title: "x",
                        originalFrame: .zero),
                    canvasX: canvasX, width: width, y: 0, height: 300)
                let vx = CGFloat(rng.double(in: 0...8000))
                for mode in [TeleportEngine.FocusMode.fit, .centered] {
                    let t = engine.viewportTarget(for: slot, mode: mode, currentViewportX: vx)
                    if !t.isFinite { bad("viewportTarget non-finite (mode \(mode))") }
                    if t < -0.5 { bad("viewportTarget negative: \(t) (mode \(mode))") }
                }
                // Fit mode: a column fully inside the current viewport must NOT scroll.
                if width < screenW {
                    let inside = vx + CGFloat(rng.double(in: 0...Double(max(0, screenW - width))))
                    let s2 = TeleportEngine.Slot(window: slot.window, canvasX: inside, width: width, y: 0, height: 300)
                    let t = engine.viewportTarget(for: s2, mode: .fit, currentViewportX: vx)
                    if abs(t - vx) > 0.5 { bad("fit moved a fully-visible column: vx \(vx) -> \(t)") }
                }
            }
        }

        // --- ResyncPlanner.decide: only legal add/remove sets. ---
        for _ in 0..<iterations {
            let universe = Array(0..<rng.int(in: 1...12))
            func subset() -> [Int] { universe.filter { _ in rng.bool() } }
            let stripIDs = subset()
            let axIDs = subset()
            let currentSpaceIDs = Set(subset())
            switch ResyncPlanner.decide(stripIDs: stripIDs, axIDs: axIDs, currentSpaceIDs: currentSpaceIDs) {
            case .frozenDifferentSpace, .skipDegraded:
                break
            case .apply(let remove, let add):
                let axSet = Set(axIDs), stripSet = Set(stripIDs)
                for r in remove where axSet.contains(r) { bad("ResyncPlanner removed \(r) that AX still reports") }
                for r in remove where !stripSet.contains(r) { bad("ResyncPlanner removed \(r) not in strip") }
                for a in add where stripSet.contains(a) { bad("ResyncPlanner re-added managed \(a)") }
                for a in add where !currentSpaceIDs.contains(a) { bad("ResyncPlanner added off-Space \(a)") }
                for a in add where !axSet.contains(a) { bad("ResyncPlanner added non-AX \(a)") }
            }
        }

        // --- AdoptionScope.filter: sorted, idempotent subset of indices. ---
        for _ in 0..<iterations {
            let n = rng.int(in: 0...8)
            let frames = (0..<n).map { _ in CGRect(x: rng.double(in: -2000...3000), y: rng.double(in: -2000...3000),
                                                   width: rng.double(in: 1...1500), height: rng.double(in: 1...1500)) }
            let strip = CGRect(x: 0, y: 0, width: 1600, height: 1000)
            let others = rng.bool() ? [CGRect(x: 1600, y: 0, width: 1200, height: 1000)] : []
            let scope: AdoptionScope.Scope = rng.bool() ? .stripDisplay : .allDisplays
            let keep = AdoptionScope.filter(frames: frames, stripDisplay: strip, others: others, scope: scope)
            if keep != keep.sorted() { bad("AdoptionScope.filter not sorted: \(keep)") }
            if Set(keep).count != keep.count { bad("AdoptionScope.filter has duplicates: \(keep)") }
            if !keep.allSatisfy({ frames.indices.contains($0) }) { bad("AdoptionScope.filter out-of-range index") }
            // Selecting the kept frames and filtering again is idempotent.
            let keptFrames = keep.map { frames[$0] }
            let again = AdoptionScope.filter(frames: keptFrames, stripDisplay: strip, others: others, scope: scope)
            if again.count != keep.count { bad("AdoptionScope.filter not idempotent: \(keep.count) -> \(again.count)") }
        }

        // --- DisplayGeometry.ensureVisible: result is visible (or unchanged). ---
        for _ in 0..<iterations {
            let frame = CGRect(x: rng.double(in: -4000...4000), y: rng.double(in: -4000...4000),
                               width: rng.double(in: 1...2000), height: rng.double(in: 1...2000))
            let displays = [CGRect(x: 0, y: 0, width: 1600, height: 1000)]
                + (rng.bool() ? [CGRect(x: 1600, y: 0, width: 1200, height: 1000)] : [])
            let out = DisplayGeometry.ensureVisible(frame, displays: displays)
            if !out.origin.x.isFinite || !out.origin.y.isFinite || !out.width.isFinite || !out.height.isFinite {
                bad("ensureVisible produced a non-finite frame from \(frame)")
            }
            if !DisplayGeometry.isMostlyVisible(out, on: displays) {
                bad("ensureVisible result not visible: \(frame) -> \(out)")
            }
            // Output never larger than the input.
            if out.width > frame.width + 0.5 || out.height > frame.height + 0.5 {
                bad("ensureVisible grew the frame: \(frame) -> \(out)")
            }
        }

        // --- Chord(string:): never crashes on arbitrary ASCII. ---
        for _ in 0..<iterations {
            let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789+-  cmdoptctrlshift⌘⌥⌃⇧leftrightupdown"
            let n = rng.int(in: 0...14)
            let s = String((0..<n).map { _ in alphabet[alphabet.index(alphabet.startIndex, offsetBy: rng.int(alphabet.count))] })
            // The only property we assert is "does not crash"; a nil result is fine.
            _ = Chord(string: s)
        }

        return failures
    }
}

// MARK: - Entry point

/// `WindowLab fuzz [baseSeed] [--steps N] [--iters M] [--seeds K]
///                 [--pure-only] [--engine-only] [--replay SEED]`
///
/// Default: K engine runs and K pure runs derived from the base seed, each
/// engine run doing `steps` random ops. Deterministic from the base seed so a
/// CI failure replays exactly. `--replay SEED` re-runs a single engine seed and
/// prints the full op log regardless of outcome.
func runFuzz(args: [String]) -> Never {
    func intArg(_ flag: String, _ def: Int) -> Int {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return def }
        return Int(args[i + 1]) ?? def
    }
    func u64Arg(_ flag: String) -> UInt64? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return UInt64(args[i + 1])
    }

    let baseSeed = args.dropFirst().first.flatMap { UInt64($0) }
        ?? UInt64(Date().timeIntervalSince1970)
    let steps = intArg("--steps", 400)
    let iters = intArg("--iters", 2000)
    let seedCount = intArg("--seeds", 200)
    let pureOnly = args.contains("--pure-only")
    let engineOnly = args.contains("--engine-only")

    // --replay: run one engine seed verbosely.
    if let replay = u64Arg("--replay") {
        print("== fuzz replay: engine seed \(replay), \(steps) steps ==")
        let fuzzer = EngineFuzzer(seed: replay)
        fuzzer.verbose = true
        print("ops (live; the LAST line printed is the culprit if it hard-crashes):")
        let result = fuzzer.run(steps: steps)
        if let v = result { print("\n\(v)"); exit(1) }
        print("\nno invariant violation for seed \(replay) (\(fuzzer.log.count) ops)")
        exit(0)
    }

    print("== ScrollWM fuzz ==  base seed \(baseSeed)")
    var totalFail = 0

    if !pureOnly {
        print("\n-- engine fuzz: \(seedCount) seeds x \(steps) steps --")
        var firstFail: String?
        for k in 0..<seedCount {
            let seed = baseSeed &+ UInt64(k) &* 0x100000001B3
            let fuzzer = EngineFuzzer(seed: seed)
            if let v = fuzzer.run(steps: steps) {
                totalFail += 1
                if firstFail == nil { firstFail = v }
                print("  \u{2717} seed \(seed) FAILED")
            }
            if (k + 1) % 25 == 0 || k + 1 == seedCount {
                print("JCODE_PROGRESS {\"current\":\(k + 1),\"total\":\(seedCount),\"unit\":\"seeds\",\"message\":\"engine fuzz\"}")
            }
        }
        if let f = firstFail {
            print("\n\(f)")
            print("\nReplay with: WindowLab fuzz --replay <seed> --steps \(steps)")
        } else {
            print("  \u{2713} engine fuzz: all \(seedCount) seeds passed (\(seedCount * steps) ops, 0 invariant violations)")
        }
    }

    if !engineOnly {
        print("\n-- pure-function property fuzz: \(seedCount) seeds x \(iters) iters --")
        var pureFails: [String] = []
        for k in 0..<seedCount {
            let seed = baseSeed &+ 0xDEADBEEF &+ UInt64(k) &* 0x100000001B3
            let fs = PureFuzz.run(seed: seed, iterations: iters)
            if !fs.isEmpty {
                totalFail += fs.count
                if pureFails.count < 10 { pureFails.append("seed \(seed): \(fs.first!)") }
            }
        }
        if pureFails.isEmpty {
            print("  \u{2713} pure fuzz: all \(seedCount) seeds passed (~\(seedCount * iters * 6) checks)")
        } else {
            for f in pureFails { print("  \u{2717} \(f)") }
        }
    }

    print("\n========================================")
    if totalFail == 0 {
        print("FUZZ PASSED (no violations)")
        exit(0)
    } else {
        print("FUZZ FAILED: \(totalFail) violation(s)")
        exit(1)
    }
}
