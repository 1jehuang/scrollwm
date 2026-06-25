import Foundation
import ApplicationServices
import AppKit

// CONCURRENCY & LIFECYCLE fuzzer (owned by the `fuzzconc` swarm agent).
//
// Goal: drive the REAL async stack — `LifecycleMonitor` (poll + fast-adopt
// retries), `WindowEventObserver`, `scheduleWidthReconcile`, the controller's
// DispatchQueue.main hops — against `SimWindowWorld` with INTERLEAVED, randomly
// timed window create/destroy/resize/minimize/app-hide/focus events, pumping the
// run loop between steps. Asserts the same model invariants the synchronous
// engine fuzzer does, plus async-specific ones (no double-adopt under
// coalescing, the strip converges after the poll, no lost/duplicated windows
// across a burst).
//
// Reuse `SplitMix64` from Fuzz.swift. Keep ALL logic self-contained in this
// file; encode any bug you find as a fixed deterministic seed so re-running the
// subcommand is the regression test. Entry point wired in main.swift.
//
// ## Why this is a SEPARATE fuzzer from the engine fuzzer
//
// `EngineFuzzer` (Fuzz.swift) is SYNCHRONOUS: it calls engine methods directly
// and checks invariants the instant each returns. That can never exercise the
// part of ScrollWM that has historically been the buggiest: the asynchronous
// lifecycle plumbing. New windows are not adopted inline — they ride a chain of
// `DispatchQueue.main.async` hops (the observer coalesce delay, the fast-adopt
// publish-race retries, the 2s safety-net poll) and resizes settle through
// `scheduleWidthReconcile`'s polling. Bugs there only appear when many of those
// async chains overlap in time: two create events coalescing, a window being
// destroyed mid-retry, a resize landing while a poll is enumerating. This fuzzer
// stands up the REAL `LifecycleMonitor` + `WindowEventObserver`, fires timed
// events at it, pumps the main run loop so every async hop actually runs, and
// asserts after each settle. A failure prints the seed + the full event log and
// exits non-zero, so it replays bit-for-bit.

// MARK: - Concurrency fuzzer

/// Stateful fuzzer over the REAL async lifecycle stack + sim world. Single
/// `TeleportEngine` driven by a live `LifecycleMonitor` (fast-adopt + poll) and
/// the engine's own `scheduleWidthReconcile`, all on the main run loop, exactly
/// like production.
final class ConcurrencyFuzzer {
    private let seed: UInt64
    private var rng: SplitMix64
    private let world: SimWindowWorld
    private let engine: TeleportEngine
    private let monitor: LifecycleMonitor

    /// Visible (usable) strip frame in AX coords.
    private let screen = CGRect(x: 0, y: 32, width: 1680, height: 1018)
    /// Full strip-display frame (parking reference).
    private let stripFull = CGRect(x: 0, y: 0, width: 1680, height: 1050)

    /// Poll interval for the live monitor. SHORT so the safety-net poll fires
    /// often within a fuzz run (the convergence oracle waits a multiple of it).
    private let pollInterval: TimeInterval = 0.05

    /// One pid per spawned window (so each window is its own app — mirrors the
    /// common real case where every adopted window comes from a distinct app and
    /// keeps the per-pid AX-observer / fast-adopt bookkeeping under stress).
    private var nextPID: pid_t = 7000
    /// Stable identity key for an AX element token (CFEqual-stable per window),
    /// so the convergence oracle can diff "managed" vs "manageable" as Sets.
    private func key(_ el: AXUIElement) -> UInt { UInt(bitPattern: Unmanaged.passUnretained(el).toOpaque().hashValue) }

    /// Human-readable replay log of every op performed, in order.
    private(set) var log: [String] = []
    /// When true, each op is echoed live (so a HARD trap still reveals the
    /// culprit op even though the in-memory log never gets to print).
    var verbose = false

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

        self.monitor = LifecycleMonitor(engine: engine, interval: pollInterval)

        // Half the runs configure a spawn width, so each fast-adopt / poll-adopt
        // runs `applySpawnWidth` -> `scheduleWidthReconcile`: a second async resize
        // chain firing concurrently with the adoption that triggered it (and with
        // any in-flight retries / the poll). Exercising it here is the whole point
        // — it is the most concurrency-dense path in the lifecycle stack.
        engine.spawnWidthFraction = rng.bool() ? rng.pick([0.25, 0.5, 0.75, 1.0]) : nil
        engine.focusMode = rng.bool() ? .fit : .centered
    }

    deinit {
        monitor.stop()
        AXSource.backend = nil
    }

    // MARK: sim helpers

    /// Create a sim window. `notify`/`cgPublishDelay` ride straight through to the
    /// sim so the create event fires the REAL observer->fast-adopt chain, and the
    /// WindowServer-publish race is modeled. Returns its element token + pid.
    @discardableResult
    private func spawn(notify: Bool, cgPublishDelay: TimeInterval, minSize: CGSize = .zero) -> (pid_t, AXUIElement) {
        let pid = nextPID; nextPID += 1
        // Frames span small to larger-than-screen, and start ON the strip display
        // (so the default `stripDisplay` adopt-scope keeps them — placing them off
        // the strip would just make the fast path correctly ignore them and add
        // noise rather than concurrency coverage).
        let w = rng.double(in: 200...2000)
        let h = rng.double(in: 200...1200)
        let x = rng.double(in: 0...1200)
        let y = rng.double(in: 40...700)
        let el = world.addWindow(
            pid: pid, title: "W\(pid)",
            frame: CGRect(x: x, y: y, width: w, height: h),
            minSize: minSize,
            notify: notify,
            cgPublishDelay: cgPublishDelay
        )
        return (pid, el)
    }

    /// All standard, visible (non-minimized / non-app-hidden / non-fullscreen)
    /// sim windows on the current Space, via the REAL AXSource+CG path. This is
    /// the set the strip is SUPPOSED to converge to once everything settles.
    private func expectedManageableElements() -> [AXUIElement] {
        // AX reports across all Spaces; intersect with the on-screen CG list
        // exactly like arrange/resync, so a minimized/app-hidden window drops out.
        let standard = world.allWindows().filter {
            $0.subrole == kAXStandardWindowSubrole as String && !$0.isMinimized && !$0.isFullscreen
        }
        let cg = CGWindowSource.listWindows(onscreenOnly: true)
        let matched = IdentityMatcher.match(axWindows: standard, cgWindows: cg)
        let onCurrentSpace = matched.enumerated().filter { $0.element.cg != nil }.map { standard[$0.offset] }
        // Honor the same display adopt-scope the strip applies.
        return engine.filterByAdoptScope(onCurrentSpace) { $0.frame }.map { $0.element }
    }

    // MARK: run

    /// Run `steps` random async operations, pumping the run loop between each and
    /// checking invariants after every settle. Returns nil on success, or a
    /// failure description on the first violation.
    func run(steps: Int) -> String? {
        monitor.start()
        // Let the observer subscribe to the sim's create/destroy events before we
        // start firing them (mirrors `Headless.pump(0.1)` in spawnlatency).
        Headless.pump(0.05)

        // Seed an initial set of windows via the create-event fast path, so the
        // strip is populated by the SAME async adoption code production uses
        // (never the synchronous `adopt`). Interleave varied publish delays.
        let initial = rng.int(in: 1...5)
        for _ in 0..<initial {
            let delay = rng.bool() ? rng.double(in: 0...0.12) : 0
            spawn(notify: true, cgPublishDelay: delay,
                  minSize: rng.bool() ? CGSize(width: rng.double(in: 200...900), height: 200) : .zero)
            // Sometimes pump a little between spawns so create events coalesce
            // differently each run; sometimes fire them back-to-back (one burst).
            if rng.bool() { Headless.pump(rng.double(in: 0...0.05)) }
        }
        record("seed(\(initial))")
        // Pump long enough for every initial fast-adopt (incl. publish-race
        // retries) AND at least one poll to land, then assert the seeded strip
        // converged to exactly the manageable set before any perturbation.
        settle()
        if let v = checkAlways(after: "seed") { return v }
        if let v = checkConverged(after: "seed") { return v }

        for step in 0..<steps {
            performRandomOp()
            // Pump a randomly-sized slice so async chains overlap differently
            // each step: sometimes barely (events still in flight at the next op),
            // sometimes fully (everything drains before the next op). The
            // STRUCTURAL invariants must hold at every such boundary, even with
            // async chains (adopt/remove/reconcile) still pending.
            Headless.pump(rng.double(in: 0...0.08))
            if let v = checkAlways(after: "step \(step)") { return v }

            // Every so often, stop perturbing, REVEAL everything that could be
            // hidden (un-minimize / un-hide), let the world fully settle, and
            // assert the strip CONVERGED to exactly the manageable set. This
            // catches a monitor that wedges partway through a long event stream
            // (e.g. ghost columns a poll never reaps). We reveal first because
            // the EVENTUAL "closed dropped / exact set" guarantee only holds from
            // a non-degraded state — `ResyncPlanner` intentionally freezes
            // (`.skipDegraded`) while >half a >=4 strip is hidden at once, so
            // asserting from a half-hidden state would be a false positive.
            if (step + 1) % 12 == 0 {
                if let v = checkConverged(after: "checkpoint@\(step)") { return v }
            }
        }

        // Final convergence: stop perturbing, reveal everything hidden, and let
        // the poll fully settle. The strip MUST equal the manageable set exactly.
        if let v = checkConverged(after: "final") { return v }
        return nil
    }

    /// Pump the run loop long enough that the fast-adopt retry budget
    /// (the sum of `fastAdoptRetryDelays` ≈ 0.36s) AND at least two
    /// poll cycles complete, so a settled assertion is meaningful.
    private func settle() {
        Headless.pump(0.4 + pollInterval * 3)
    }

    // MARK: ops

    private func performRandomOp() {
        enum Op: CaseIterable {
            case create, createBurst, destroy, resizeExternal, widthKey
            case minimize, unminimize, appHide, appUnhide
            case focusSystem, focusNav, move, fitAll, close
        }
        switch rng.pick(Op.allCases) {
        case .create:
            // A single new window via the fast path, with a varied publish delay
            // so the create-event-beats-WindowServer race is exercised.
            let delay = rng.bool() ? rng.double(in: 0...0.18) : 0
            let (pid, _) = spawn(notify: true, cgPublishDelay: delay,
                                 minSize: rng.bool() ? CGSize(width: rng.double(in: 200...900), height: 200) : .zero)
            record("create(pid=\(pid), publish=\(fmt(delay)))")
        case .createBurst:
            // Several windows created within the observer coalesce window, so
            // they fold into ONE delivery — the classic double-adopt risk.
            let n = rng.int(in: 2...4)
            var pids: [pid_t] = []
            for _ in 0..<n {
                let delay = rng.bool() ? rng.double(in: 0...0.12) : 0
                let (pid, _) = spawn(notify: true, cgPublishDelay: delay)
                pids.append(pid)
            }
            record("createBurst(\(pids))")
        case .destroy:
            // Destroy a random live window via the REAL destroy event (fast
            // remove path). Bias toward managed windows so the gap-close runs.
            if let el = pickLiveElement() {
                record("destroy(\(titleOf(el)))")
                world.destroyWindow(el, notify: true)
            } else { record("destroy(none)") }
        case .resizeExternal:
            // A window resized by SOMETHING OTHER than our verbs (terminal cell
            // snap, user drag). The poll's `reconcileSizes` must heal the model.
            if let el = pickLiveElement() {
                let size = CGSize(width: rng.double(in: 200...2400), height: rng.double(in: 200...1200))
                record("resizeExternal(\(titleOf(el)) -> \(Int(size.width))x\(Int(size.height)))")
                _ = AXSource.setSize(el, kAXSizeAttribute as String, size)
            } else { record("resizeExternal(none)") }
        case .widthKey:
            // The async resize path: setFocusedWidth schedules scheduleWidthReconcile.
            if engine.slots.indices.contains(engine.focusIndex) {
                world.setSystemFocus(engine.slots[engine.focusIndex].window.element)
            }
            let frac = rng.pick([CGFloat(0.25), 0.5, 0.75, 1.0])
            record("widthKey(\(frac))")
            _ = engine.setFocusedWidth(fraction: frac)
        case .minimize:
            if let el = pickLiveElement() {
                record("minimize(\(titleOf(el)))")
                world.setMinimized(el, true)
            } else { record("minimize(none)") }
        case .unminimize:
            if let el = world.snapshot().first(where: { $0.minimized })?.element {
                record("unminimize(\(titleOf(el)))")
                world.setMinimized(el, false)
            } else { record("unminimize(none)") }
        case .appHide:
            if let el = pickLiveElement() {
                let pid = pidOf(el)
                record("appHide(pid=\(pid))")
                world.setAppHidden(pid, true)
            } else { record("appHide(none)") }
        case .appUnhide:
            // Unhide any currently-hidden app (find via a snapshot probe).
            if let el = world.snapshot().first(where: { world.appIsHidden(pid: $0.pid) })?.element {
                let pid = pidOf(el)
                record("appUnhide(pid=\(pid))")
                world.setAppHidden(pid, false)
            } else { record("appUnhide(none)") }
        case .focusSystem:
            // Model the user clicking some window: move OS focus, then let the
            // engine reconcile to it (mirrors width/close honoring live focus).
            if !engine.slots.isEmpty {
                let el = engine.slots[rng.int(engine.slots.count)].window.element
                world.setSystemFocus(el)
                record("focusSystem(\(titleOf(el)))")
                _ = engine.syncFocusToSystemFocusedWindow()
            } else { record("focusSystem(none)") }
        case .focusNav:
            let i = rng.int(in: -1...(engine.slots.count))
            record("focusNav(\(i))"); engine.focus(index: i)
        case .move:
            let d = rng.pick([-2, -1, 1, 2])
            record("move(\(d))"); _ = engine.moveFocused(by: d)
        case .fitAll:
            record("fitAll"); engine.fitAllColumns()
        case .close:
            if engine.slots.indices.contains(engine.focusIndex) {
                world.setSystemFocus(engine.slots[engine.focusIndex].window.element)
                let el = engine.slots[engine.focusIndex].window.element
                record("close(\(titleOf(el)))")
                _ = engine.closeFocused()
            } else { record("close(none)") }
        }
    }

    private func fmt(_ d: TimeInterval) -> String { String(format: "%.0fms", d * 1000) }

    /// Pick a random ALIVE sim element, biased toward managed ones so the
    /// destroy/resize/minimize ops mostly hit the strip.
    private func pickLiveElement() -> AXUIElement? {
        let live = world.snapshot()
        guard !live.isEmpty else { return nil }
        let managed = live.filter { engine.isManaged($0.element) }
        if !managed.isEmpty && rng.int(4) != 0 { return managed[rng.int(managed.count)].element }
        return live[rng.int(live.count)].element
    }

    private func titleOf(_ el: AXUIElement) -> String {
        world.snapshot().first { CFEqual($0.element, el) }?.title ?? "?"
    }
    private func pidOf(_ el: AXUIElement) -> pid_t {
        world.snapshot().first { CFEqual($0.element, el) }?.pid ?? -1
    }

    // MARK: invariants

    private func dump(_ kind: String, _ ctx: String, _ s: String) -> String {
        """
        \(kind) after \(ctx): \(s)
          seed: \(seed)
          command: WindowLab fuzzconc \(seed) --replay --steps <N>
          ops (\(log.count)):
            \(log.joined(separator: "\n    "))
        """
    }

    /// ALWAYS-TRUE structural invariants: these must hold at EVERY step boundary,
    /// mid-burst, even while async chains (adopt / remove / reconcile) are still
    /// in flight, because every public op and every monitor mutation re-packs
    /// and re-clamps BEFORE it yields the run loop. Returns the first violation.
    private func checkAlways(after ctx: String) -> String? {
        func fail(_ s: String) -> String { dump("INVARIANT VIOLATION", ctx, s) }

        let slots = engine.slots

        // 1. focusIndex bounds.
        if slots.isEmpty {
            if engine.focusIndex != 0 { return fail("focusIndex \(engine.focusIndex) on empty strip (expected 0)") }
        } else if engine.focusIndex < 0 || engine.focusIndex >= slots.count {
            return fail("focusIndex \(engine.focusIndex) out of range 0..<\(slots.count)")
        }

        // 2. Workspace bounds (this fuzzer never switches workspaces, but the
        // invariant is cheap and guards against an accidental regression).
        if engine.workspaceCount < 1 { return fail("workspaceCount \(engine.workspaceCount) < 1") }
        if engine.activeWorkspace < 0 || engine.activeWorkspace >= engine.workspaceCount {
            return fail("activeWorkspace \(engine.activeWorkspace) out of range 0..<\(engine.workspaceCount)")
        }

        // 3. Finite + positive geometry, viewportX sane.
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

        // 4. Strip is compact (gap-separated, leading gap margin). Every adopt /
        // remove / resize path ends by compacting, so this holds at a step
        // boundary even with async chains pending (each one compacts before it
        // yields the run loop).
        var x = engine.gap
        for (i, s) in slots.enumerated() {
            if abs(s.canvasX - x) > 0.5 {
                return fail("strip not compact at slot[\(i)] (\(s.window.title)): canvasX \(s.canvasX) expected \(x)")
            }
            x += s.width + engine.gap
        }

        // 5. NO DUPLICATE adoptions under coalescing. The central async hazard:
        // a create burst folds into one observer delivery, a fast-adopt retry
        // overlaps a poll, a window parked off-viewport still shows on-screen.
        // None may adopt the same window twice — EVER, in flight or settled.
        let all = engine.allManagedSlots
        for a in 0..<all.count {
            for b in (a + 1)..<all.count {
                if CFEqual(all[a].window.element, all[b].window.element) {
                    return fail("DUPLICATE adoption: \(all[a].window.title) appears in two columns "
                                + "(coalescing/retry double-adopt)")
                }
            }
        }
        return nil
    }

    /// CONVERGENCE oracle (the "converges after the poll" guarantee). Stop
    /// perturbing, REVEAL everything that could be hidden (un-minimize / un-hide),
    /// fully settle, then assert the strip equals the manageable set EXACTLY (same
    /// windows, no dups, no stragglers — which subsumes "closed windows dropped"),
    /// model width == the real sim frame for every column, and the strip is
    /// compact / in bounds. Revealing first is essential: the EXACT-set guarantee
    /// only holds from a NON-degraded state, because `ResyncPlanner` deliberately
    /// freezes (`.skipDegraded`) while more than half of a >=4 window strip is
    /// hidden from AX at once (the anti-mass-removal valve). Asserting from a
    /// half-hidden state would be a false positive, not a product bug.
    ///
    /// Run both at periodic mid-stream checkpoints and once at the end, so a
    /// monitor that wedges partway through a long event stream is caught.
    private func checkConverged(after ctx: String) -> String? {
        func fail(_ s: String) -> String { dump("CONVERGENCE VIOLATION", ctx, s) }

        // Reveal everything so the manageable set is deterministic: un-hide every
        // app and un-minimize every window. (We do NOT resurrect destroyed ones —
        // those are gone for good.)
        for w in world.snapshot() {
            if w.minimized { world.setMinimized(w.element, false) }
            if world.appIsHidden(pid: w.pid) { world.setAppHidden(w.pid, false) }
        }

        // Drain the world: long enough for several poll cycles to enumerate, the
        // fast-adopt retry budget to lapse, and every scheduleWidthReconcile to
        // finish. Generous so a slow CI box still converges.
        Headless.pump(1.0 + pollInterval * 8)

        // Re-check the structural invariants first (compactness, bounds, dups).
        if let v = checkAlways(after: "\(ctx) (structure)") { return v }

        let expected = expectedManageableElements()
        let expectedKeys = Set(expected.map { key($0) })
        let managed = engine.slots.map { $0.window.element }
        let managedKeys = Set(managed.map { key($0) })

        // No duplicates in the strip (already checked, but be explicit here).
        if managedKeys.count != managed.count {
            return fail("strip has duplicate windows after settle (\(managed.count) slots, \(managedKeys.count) unique)")
        }

        // Strip must hold EXACTLY the manageable set.
        let missing = expectedKeys.subtracting(managedKeys)
        let extra = managedKeys.subtracting(expectedKeys)
        if !missing.isEmpty {
            let titles = expected.filter { missing.contains(key($0)) }.map { titleOf($0) }
            return fail("strip did NOT converge: \(missing.count) manageable window(s) never adopted "
                        + "after the poll: \(titles)")
        }
        if !extra.isEmpty {
            let titles = engine.slots.filter { extra.contains(key($0.window.element)) }.map { $0.window.title }
            return fail("strip did NOT converge: \(extra.count) window(s) still managed that should have "
                        + "been dropped (closed/minimized/hidden): \(titles)")
        }

        // Model width == real sim frame for every healthy column (the resize
        // reconcile + poll size-heal must have pulled the model back to reality).
        for s in engine.slots where s.window.healthy {
            guard let real = world.frame(of: s.window.element) else {
                return fail("healthy managed window \(s.window.title) vanished during convergence")
            }
            if abs(s.width - real.width) > 1.5 {
                return fail("width desync after settle for \(s.window.title): model \(s.width) vs real \(real.width)")
            }
        }
        return nil
    }
}

// MARK: - Entry point

/// `WindowLab fuzzconc [baseSeed] [--steps N] [--seeds K] [--replay] [--verbose]`
///
/// Default: K independent concurrency runs derived from the base seed, each
/// doing `steps` random timed async ops with a live `LifecycleMonitor`. Fully
/// HEADLESS (sim backend; no real window/keystroke). Deterministic from the base
/// seed so a CI failure replays exactly. `--replay` runs the SINGLE base seed
/// verbosely (echoing each op live) so a hard trap reveals the culprit op.
func runFuzzConcurrency(args: [String]) -> Never {
    func intArg(_ flag: String, _ def: Int) -> Int {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return def }
        return Int(args[i + 1]) ?? def
    }

    let baseSeed = args.dropFirst().first.flatMap { UInt64($0) }
        ?? UInt64(Date().timeIntervalSince1970)
    let steps = intArg("--steps", 120)
    let seedCount = intArg("--seeds", 1)
    let replay = args.contains("--replay")
    let verbose = replay || args.contains("--verbose")

    if replay {
        print("== fuzzconc replay: seed \(baseSeed), \(steps) steps ==")
        let fuzzer = ConcurrencyFuzzer(seed: baseSeed)
        fuzzer.verbose = true
        print("ops (live; the LAST line printed is the culprit if it hard-crashes):")
        let result = fuzzer.run(steps: steps)
        if let v = result { print("\n\(v)"); exit(1) }
        print("\nno violation for seed \(baseSeed) (\(fuzzer.log.count) ops)")
        exit(0)
    }

    print("== ScrollWM fuzzconc ==  base seed \(baseSeed)")
    print("-- concurrency/lifecycle fuzz: \(seedCount) seed(s) x \(steps) steps --")
    var firstFail: String?
    var failCount = 0
    for k in 0..<seedCount {
        let seed = baseSeed &+ UInt64(k) &* 0x100000001B3
        let fuzzer = ConcurrencyFuzzer(seed: seed)
        if verbose && seedCount > 1 { print("\n-- seed \(seed) --") }
        if let v = fuzzer.run(steps: steps) {
            failCount += 1
            if firstFail == nil { firstFail = v }
            print("  \u{2717} seed \(seed) FAILED")
        } else {
            print("  \u{2713} seed \(seed) passed (\(fuzzer.log.count) ops)")
        }
        if (k + 1) % 10 == 0 || k + 1 == seedCount {
            print("JCODE_PROGRESS {\"current\":\(k + 1),\"total\":\(seedCount),\"unit\":\"seeds\",\"message\":\"fuzzconc\"}")
        }
    }

    print("\n========================================")
    if failCount == 0 {
        print("FUZZCONC PASSED (\(seedCount) seed(s), 0 violations)")
        exit(0)
    } else {
        print("\(firstFail!)")
        print("\nReplay with: WindowLab fuzzconc <seed> --replay --steps \(steps)")
        print("FUZZCONC FAILED: \(failCount)/\(seedCount) seed(s) violated an invariant")
        exit(1)
    }
}
