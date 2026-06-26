import Foundation
import ApplicationServices
import AppKit

// SPAWN-PLACEMENT VALIDATOR (`WindowLab spawnvalidate`).
//
// `spawnlatency` proves the happy path is fast. `fuzzconc` proves the strip
// EVENTUALLY converges to the right SET of windows. Neither proves the property
// the user actually cares about for EVERY spawn:
//
//   (P1 placement) a newly opened window ends up in the column IMMEDIATELY to
//     the RIGHT of the column that was focused when it opened, becomes the new
//     focus, and its REAL on-screen frame equals the strip's computed slot
//     position - i.e. it is not left "floating" at its native spawn spot.
//   (P2 latency) it reaches that final position via the FAST path (AX-observer
//     create event + bounded retry), not the 2s safety-net poll.
//
// This validator drives the REAL async stack (`LifecycleMonitor` +
// `WindowEventObserver` + `scheduleWidthReconcile`) against `SimWindowWorld` and,
// after EVERY spawn, asserts P1 + P2 exactly. It runs a hand-written matrix of
// named edge cases AND a randomized property fuzz that interleaves spawns with
// focus moves, width changes, destroys, and minimize/app-hide noise, so the
// "right place, instantly" contract is checked from many strip states - not just
// "focus at the end of an otherwise-idle strip".
//
// The poll is deliberately SLOW (5s) so any adoption observed within the test
// window MUST have come from the fast path; a placement that only the poll could
// produce would blow the per-spawn deadline and FAIL. Fully HEADLESS: no real
// window/keystroke. Deterministic from the base seed so a failure replays.

// MARK: - Validator

final class SpawnValidator {
    // Synthetic single-display geometry (AX top-left coords). Tests that need a
    // second monitor pass it via `others`.
    static let stripFull   = CGRect(x: 0, y: 0,  width: 1600, height: 1000)
    static let stripVisible = CGRect(x: 0, y: 32, width: 1600, height: 968)

    let world: SimWindowWorld
    let engine: TeleportEngine
    let monitor: LifecycleMonitor
    private var nextPID: pid_t = 9000

    /// Collected per-spawn latencies (ms) so we can report the distribution and
    /// assert a hard cap across the whole run.
    let rec = LatencyRecorder()
    /// First failure message (nil = all good). The caller decides exit code.
    private(set) var failures: [String] = []
    /// Human log of ops, for a failure dump.
    private(set) var log: [String] = []

    init(spawnWidth: CGFloat?, fillHeight: Bool,
         focusMode: TeleportEngine.FocusMode, others: [CGRect] = []) {
        world = SimWindowWorld()
        world.displays = [Self.stripFull] + others
        AXSource.backend = world

        engine = TeleportEngine(screenFrame: Self.stripVisible)
        engine.stripDisplayFrame = Self.stripFull
        engine.otherDisplayFrames = others
        engine.adoptScope = .stripDisplay
        engine.gap = 12
        engine.minColumnWidth = 200
        engine.widthPresets = [0.25, 0.5, 0.75, 1.0]
        engine.spawnWidthFraction = spawnWidth
        engine.fillHeight = fillHeight
        engine.focusMode = focusMode

        // SLOW poll: an adoption inside the per-spawn deadline therefore proves
        // the fast path drove it, not the safety-net poll.
        monitor = LifecycleMonitor(engine: engine, interval: 5.0)
        monitor.start()
        Headless.pump(0.05) // let the observer subscribe to sim events
    }

    func teardown() { monitor.stop(); AXSource.backend = nil }

    private func note(_ s: String) { log.append(s) }
    private func fail(_ s: String) { failures.append(s); note("FAIL: " + s) }
    var ok: Bool { failures.isEmpty }

    // MARK: window helpers

    /// A native spawn frame ON the strip display but deliberately far from where
    /// the strip will place the adopted column, so "live frame == strip target"
    /// is a meaningful proof the window actually MOVED (was not left floating).
    private func nativeStripFrame(seq: Int, width: CGFloat, height: CGFloat) -> CGRect {
        // Stagger natives so a burst's members start at distinct spots.
        let x = Self.stripFull.minX + 300 + CGFloat(seq % 3) * 90
        let y = Self.stripFull.minY + 520 + CGFloat(seq % 2) * 60
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The strip's intended on-screen origin for the slot holding `el` right now.
    private func slotTarget(_ el: AXUIElement) -> CGPoint? {
        guard let idx = engine.slots.firstIndex(where: { CFEqual($0.window.element, el) }) else { return nil }
        return engine.onScreenTarget(for: engine.slots[idx])
    }

    /// True once `el` is adopted AND the engine has COMMITTED it to its current
    /// final target (the slot's `onScreenTarget`). Comparing the engine's last
    /// committed origin to the current target is robust for BOTH on-viewport
    /// columns (target == slot position) and off-viewport columns (target ==
    /// parking point, which the OS/sim then clamps to a sliver) - so a burst
    /// member that legitimately scrolls off-screen still reads as "reached its
    /// destination" instead of falsely hanging the wait loop. This is "the window
    /// stopped floating at its native spot and is where the strip wants it".
    private func isPlaced(_ el: AXUIElement) -> Bool {
        guard let idx = engine.slots.firstIndex(where: { CFEqual($0.window.element, el) }) else { return false }
        let slot = engine.slots[idx]
        guard let committed = slot.window.lastCommittedOrigin else { return false }
        let target = engine.onScreenTarget(for: slot)
        return abs(committed.x - target.x) <= 1 && abs(committed.y - target.y) <= 1
    }

    /// Strict check for an ON-VIEWPORT window (the freshly-focused new window
    /// always is): its REAL live frame equals the slot's on-screen position, so
    /// the user sees it exactly in its column, not floating.
    private func liveFrameAtSlot(_ el: AXUIElement) -> Bool {
        guard let target = slotTarget(el), let live = world.frame(of: el) else { return false }
        return abs(live.minX - target.x) <= 1 && abs(live.minY - target.y) <= 1
    }

    // MARK: the core oracle

    /// Spawn ONE window that SHOULD be adopted, then assert P1 (placement) and
    /// P2 (fast-path latency). `label` names the scenario for failure messages.
    @discardableResult
    func spawnExpectPlacedRightOfFocus(label: String,
                                       publishDelay: TimeInterval = 0,
                                       width: CGFloat, height: CGFloat,
                                       minSize: CGSize = .zero) -> AXUIElement {
        let hadFocus = engine.slots.indices.contains(engine.focusIndex)
        let oldFocusIndex = engine.focusIndex
        let oldFocusCanvasX = hadFocus ? engine.slots[engine.focusIndex].canvasX : -.greatestFiniteMagnitude
        let oldElements = engine.slots.map { $0.window.element }
        let expectedIndex = hadFocus ? oldFocusIndex + 1 : 0

        let pid = nextPID; nextPID += 1
        let native = nativeStripFrame(seq: Int(pid), width: width, height: height)
        note("spawn[\(label)] pid=\(pid) publish=\(ms(publishDelay)) native=\(rectStr(native))")
        let t0 = Clock.nowAbsNs()
        let el = world.addWindow(pid: pid, title: "SV-\(pid)", frame: native,
                                 minSize: minSize, notify: true, cgPublishDelay: publishDelay)

        let placedNs = waitUntilPlaced(el, budgetNs: 2_000_000_000)
        guard let placedNs else {
            fail("[\(label)] new window NEVER reached its strip slot within 2s "
                 + "(managed=\(engine.isManaged(el)); the fast path failed to place it)")
            return el
        }
        let latency = Double(placedNs &- t0) / 1e6
        rec.record("spawn-place", ms: latency)

        // P2: fast path, not poll (poll is 5s).
        if latency >= 1000 {
            fail("[\(label)] placement latency \(Int(latency))ms >= 1000ms - the 5s poll, "
                 + "not the fast path, must have driven it")
        }
        // Even allowing for the publish race + coarse end-of-budget retry, the
        // fast path should land within a few hundred ms of the window becoming
        // visible. Catches a regression that silently defers to the poll-ish tail.
        let allowed = publishDelay * 1000 + 300
        if latency > allowed {
            fail("[\(label)] placement latency \(Int(latency))ms exceeds publish+budget "
                 + "(\(Int(allowed))ms) - fast path is too slow")
        }

        // P1: index immediately right of the old focus.
        guard let newIndex = engine.slots.firstIndex(where: { CFEqual($0.window.element, el) }) else {
            fail("[\(label)] adopted window vanished from the strip"); return el
        }
        if newIndex != expectedIndex {
            fail("[\(label)] landed at column \(newIndex), expected \(expectedIndex) "
                 + "(immediately right of the focused column \(oldFocusIndex))")
        }
        // P1: it is now the focused column.
        if engine.focusIndex != newIndex {
            fail("[\(label)] focus is on column \(engine.focusIndex), not the new window at \(newIndex)")
        }
        // P1: strictly to the RIGHT of the old focus on the canvas.
        if hadFocus && engine.slots[newIndex].canvasX <= oldFocusCanvasX {
            fail("[\(label)] new column canvasX \(engine.slots[newIndex].canvasX) is not right of "
                 + "the old focus canvasX \(oldFocusCanvasX)")
        }
        // P1: it actually MOVED off its native spawn spot (not a vacuous pass).
        if let live = world.frame(of: el),
           abs(live.minX - native.minX) <= 1 && abs(live.minY - native.minY) <= 1 {
            fail("[\(label)] window is still at its native spawn frame \(rectStr(native)) - "
                 + "it was adopted but never repositioned ('floating')")
        }
        // P1 (strict): the new window is freshly focused, so it is ALWAYS on the
        // viewport - its REAL live frame must equal its column's on-screen slot.
        // This is the literal "appears instantly in the right place" guarantee.
        if !liveFrameAtSlot(el) {
            let live = world.frame(of: el).map(rectStr) ?? "nil"
            let tgt = slotTarget(el).map { String(format: "(%.0f,%.0f)", $0.x, $0.y) } ?? "nil"
            fail("[\(label)] new window's live frame \(live) is not at its slot \(tgt)")
        }
        // P1: every pre-existing window is still managed (none lost/overwritten).
        for old in oldElements where !engine.isManaged(old) {
            fail("[\(label)] a pre-existing window was dropped when the new one was adopted")
            break
        }
        if engine.slots.count != oldElements.count + 1 {
            fail("[\(label)] strip grew by \(engine.slots.count - oldElements.count), expected exactly 1")
        }

        // Stability: pump past the async width-reconcile window and confirm the
        // window stays put at its slot (no late re-move that the user would see
        // as a second jump).
        Headless.pump(0.25)
        if !isPlaced(el) {
            fail("[\(label)] window drifted off its slot AFTER initial placement "
                 + "(late reconcile/teleport moved it again)")
        }
        return el
    }

    /// Fire `n` windows inside ONE observer coalesce window (no pump between), so
    /// they fold into a single delivery, then assert ALL of them land as a
    /// contiguous, in-ORDER run immediately right of the old focus, the LAST one
    /// focused, every real frame at its slot.
    func spawnBurstExpectContiguousRightOfFocus(label: String, n: Int,
                                                 publishDelay: TimeInterval = 0) {
        let hadFocus = engine.slots.indices.contains(engine.focusIndex)
        let oldFocusIndex = engine.focusIndex
        let firstExpected = hadFocus ? oldFocusIndex + 1 : 0
        let oldCount = engine.slots.count

        var els: [AXUIElement] = []
        let t0 = Clock.nowAbsNs()
        for _ in 0..<n {
            let pid = nextPID; nextPID += 1
            let native = nativeStripFrame(seq: Int(pid), width: 360, height: 300)
            els.append(world.addWindow(pid: pid, title: "SVB-\(pid)", frame: native,
                                       notify: true, cgPublishDelay: publishDelay))
        }
        note("burst[\(label)] n=\(n) publish=\(ms(publishDelay))")

        // Wait until ALL burst members are placed.
        let deadline = Clock.nowAbsNs() + 3_000_000_000
        while Clock.nowAbsNs() < deadline {
            Headless.pump(0.004)
            if els.allSatisfy({ isPlaced($0) }) { break }
        }
        let latency = Double(Clock.nowAbsNs() &- t0) / 1e6
        rec.record("burst-place", ms: latency)

        for (i, el) in els.enumerated() {
            guard let idx = engine.slots.firstIndex(where: { CFEqual($0.window.element, el) }) else {
                fail("[\(label)] burst member #\(i) never adopted"); continue
            }
            if idx != firstExpected + i {
                fail("[\(label)] burst member #\(i) at column \(idx), expected \(firstExpected + i) "
                     + "(burst must be contiguous and in spawn order right of focus)")
            }
            if !isPlaced(el) {
                fail("[\(label)] burst member #\(i) not at its slot position (floating)")
            }
        }
        if engine.slots.count != oldCount + n {
            fail("[\(label)] strip grew by \(engine.slots.count - oldCount), expected \(n)")
        }
        // The newest (last spawned) must be the focus.
        if let lastIdx = engine.slots.firstIndex(where: { CFEqual($0.window.element, els.last!) }),
           engine.focusIndex != lastIdx {
            fail("[\(label)] after a burst, focus is \(engine.focusIndex), not the newest window")
        }
        if latency >= 1500 {
            fail("[\(label)] burst placement \(Int(latency))ms is poll-speed, not fast-path")
        }
    }

    /// Spawn a window that must be IGNORED (on another display under stripDisplay
    /// scope, or never published = foreign Space). Assert the strip does NOT grow
    /// and the window is NOT moved (no yank).
    func spawnExpectIgnored(label: String, frame: CGRect, publishDelay: TimeInterval) {
        let oldCount = engine.slots.count
        let pid = nextPID; nextPID += 1
        note("spawn-ignore[\(label)] pid=\(pid) frame=\(rectStr(frame)) publish=\(ms(publishDelay))")
        let el = world.addWindow(pid: pid, title: "SVX-\(pid)", frame: frame,
                                 notify: true, cgPublishDelay: publishDelay)
        // Pump past the WHOLE fast-adopt retry budget (~0.36s) plus margin, but
        // not so long the 5s poll fires. If it were going to be (wrongly) adopted
        // and moved, it would happen in this window.
        Headless.pump(0.6)
        if engine.isManaged(el) {
            fail("[\(label)] a window that should be ignored was ADOPTED (yanked onto the strip)")
        }
        if engine.slots.count != oldCount {
            fail("[\(label)] strip changed size while ignoring a non-strip/foreign window")
        }
        if let live = world.frame(of: el),
           abs(live.minX - frame.minX) > 1 || abs(live.minY - frame.minY) > 1 {
            fail("[\(label)] an ignored window was MOVED from \(rectStr(frame)) to \(rectStr(live))")
        }
    }

    private func waitUntilPlaced(_ el: AXUIElement, budgetNs: UInt64) -> UInt64? {
        let deadline = Clock.nowAbsNs() + budgetNs
        while Clock.nowAbsNs() < deadline {
            Headless.pump(0.003)
            if isPlaced(el) { return Clock.nowAbsNs() }
        }
        return nil
    }

    // MARK: non-spawn perturbations (to reach varied strip states)

    func focus(to index: Int) { engine.focus(index: index); note("focus(\(index))") }
    func setFocusedWidth(_ frac: CGFloat) {
        if engine.slots.indices.contains(engine.focusIndex) {
            world.setSystemFocus(engine.slots[engine.focusIndex].window.element)
        }
        _ = engine.setFocusedWidth(fraction: frac); Headless.pump(0.05); note("width(\(frac))")
    }
    func destroyFocused() {
        guard engine.slots.indices.contains(engine.focusIndex) else { return }
        let el = engine.slots[engine.focusIndex].window.element
        world.destroyWindow(el, notify: true); Headless.pump(0.1); note("destroyFocused")
    }
    func minimizeNoiseWindow() {
        // Minimize a non-managed (or any) window to add reconcile noise; the
        // strip should be unaffected by it.
        if let w = world.snapshot().first(where: { !engine.isManaged($0.element) }) {
            world.setMinimized(w.element, true); note("minimizeNoise")
        }
    }

    private func ms(_ d: TimeInterval) -> String { String(format: "%.0fms", d * 1000) }
}

private func rectStr(_ r: CGRect) -> String {
    String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
}

// MARK: - Scenario matrix (named edge cases)

private func runSpawnValidateScenarios(_ t: inout TestCounter) {
    // Helper: run a closure against a fresh validator, fold its failures into t.
    func scenario(_ name: String, spawnWidth: CGFloat? = nil, fillHeight: Bool = false,
                  focusMode: TeleportEngine.FocusMode = .fit, others: [CGRect] = [],
                  _ body: (SpawnValidator) -> Void) {
        let v = SpawnValidator(spawnWidth: spawnWidth, fillHeight: fillHeight,
                               focusMode: focusMode, others: others)
        body(v)
        if v.ok { t.check(name, true) }
        else {
            t.check(name, false)
            for f in v.failures.prefix(4) { print("        - \(f)") }
        }
        v.teardown()
    }

    // 1. First window into an EMPTY strip lands focused at column 0, on its slot.
    scenario("empty strip: first window lands placed + focused") { v in
        v.spawnExpectPlacedRightOfFocus(label: "first", width: 360, height: 300)
    }

    // 2. Focus at the END: each new window appends to the right.
    scenario("append-right: 4 sequential spawns each land right of focus") { v in
        for i in 0..<4 { v.spawnExpectPlacedRightOfFocus(label: "seq\(i)", width: 360, height: 300) }
    }

    // 3. Focus in the MIDDLE: a new window inserts between, pushing the right
    //    columns further right (it must NOT append at the end).
    scenario("insert-in-middle: lands right of focus, not at the end") { v in
        for i in 0..<4 { v.spawnExpectPlacedRightOfFocus(label: "pre\(i)", width: 320, height: 300) }
        v.focus(to: 1)                                   // focus a middle column
        v.spawnExpectPlacedRightOfFocus(label: "mid", width: 320, height: 300) // -> column 2
    }

    // 4. Focus at column 0 with WIDE columns so the strip overflows: the new
    //    window (column 1) is off-viewport until focus scrolls to it; it must
    //    still land at its (scrolled) slot position.
    scenario("viewport scroll: new window revealed at its slot") { v in
        for i in 0..<5 { v.spawnExpectPlacedRightOfFocus(label: "wide\(i)", width: 700, height: 300) }
        v.focus(to: 0)
        v.spawnExpectPlacedRightOfFocus(label: "scroll", width: 700, height: 300)
    }

    // 5. Publish race: window readable in AX but withheld from the on-screen list
    //    for a range of delays. Must still land right-of-focus, fast.
    for d in [0.0, 0.03, 0.08, 0.15] {
        scenario("publish race \(Int(d*1000))ms: still lands right of focus fast") { v in
            v.spawnExpectPlacedRightOfFocus(label: "seed", width: 360, height: 300)
            v.spawnExpectPlacedRightOfFocus(label: "race", publishDelay: d, width: 360, height: 300)
        }
    }

    // 6. Burst: several windows created in one coalesce window land contiguous,
    //    in order, right of focus, newest focused.
    scenario("burst of 3: contiguous, in order, newest focused") { v in
        v.spawnExpectPlacedRightOfFocus(label: "seed", width: 320, height: 300)
        v.spawnBurstExpectContiguousRightOfFocus(label: "burst", n: 3)
    }
    scenario("burst of 3 mid-strip with publish race") { v in
        for i in 0..<3 { v.spawnExpectPlacedRightOfFocus(label: "p\(i)", width: 300, height: 300) }
        v.focus(to: 1)
        v.spawnBurstExpectContiguousRightOfFocus(label: "midburst", n: 3, publishDelay: 0.05)
    }

    // 7. spawnWidth + fillHeight (the resize-on-adopt path): the window is
    //    resized AND repositioned; final live frame must equal the slot.
    scenario("spawnWidth+fillHeight: resized window still lands at its slot",
             spawnWidth: 0.5, fillHeight: true) { v in
        v.spawnExpectPlacedRightOfFocus(label: "seed", width: 800, height: 400)
        v.spawnExpectPlacedRightOfFocus(label: "resized", width: 800, height: 400)
    }

    // 8. App that REFUSES to shrink (hard min wider than the spawn target): the
    //    clamp must not break placement; it still lands right-of-focus at its slot.
    scenario("min-size clamp: clamp-resistant app still placed right of focus",
             spawnWidth: 0.25, fillHeight: true) { v in
        v.spawnExpectPlacedRightOfFocus(label: "seed", width: 360, height: 300)
        v.spawnExpectPlacedRightOfFocus(label: "clamped", width: 360, height: 300,
                                        minSize: CGSize(width: 900, height: 600))
    }

    // 9. Over-wide window (wider than the screen): fit-mode aligns its left edge;
    //    live frame must match that slot target.
    scenario("over-wide window: aligned at its slot, no float") { v in
        v.spawnExpectPlacedRightOfFocus(label: "seed", width: 360, height: 300)
        v.spawnExpectPlacedRightOfFocus(label: "huge",
                                        width: SpawnValidator.stripVisible.width + 500, height: 300)
    }

    // 10/11. MULTI-DISPLAY. Strip on the left; a second monitor on the right.
    let other = CGRect(x: 1600, y: 0, width: 1440, height: 900)
    scenario("multi-display: window on OTHER display is ignored (no yank)", others: [other]) { v in
        v.spawnExpectPlacedRightOfFocus(label: "onstrip", width: 360, height: 300)
        v.spawnExpectIgnored(label: "external",
                             frame: CGRect(x: other.minX + 300, y: other.minY + 200, width: 360, height: 300),
                             publishDelay: 0)
    }
    scenario("multi-display: window on STRIP display still adopted fast", others: [other]) { v in
        v.spawnExpectPlacedRightOfFocus(label: "onstrip1", width: 360, height: 300)
        v.spawnExpectPlacedRightOfFocus(label: "onstrip2", width: 360, height: 300)
    }

    // 12. Foreign Space (never published on-screen): the fast path must retry,
    //     give up, and leave it alone - never adopt or move it.
    scenario("foreign Space (never on-screen): ignored, not moved") { v in
        v.spawnExpectPlacedRightOfFocus(label: "seed", width: 360, height: 300)
        v.spawnExpectIgnored(label: "foreign",
                             frame: CGRect(x: 200, y: 520, width: 360, height: 300),
                             publishDelay: 100) // 100s -> never visible during the test
    }

    // 13. Spawn AFTER a destroy (gap closed): the next window still lands right
    //     of the (re-resolved) focus.
    scenario("spawn after destroy: still lands right of focus") { v in
        for i in 0..<3 { v.spawnExpectPlacedRightOfFocus(label: "d\(i)", width: 320, height: 300) }
        v.focus(to: 1)
        v.destroyFocused()                               // focus shifts to a survivor
        v.spawnExpectPlacedRightOfFocus(label: "afterDestroy", width: 320, height: 300)
    }

    // 14. Centered focus mode (the non-default): placement contract is identical.
    scenario("centered focus mode: lands right of focus at its slot",
             focusMode: .centered) { v in
        for i in 0..<3 { v.spawnExpectPlacedRightOfFocus(label: "c\(i)", width: 360, height: 300) }
        v.focus(to: 0)
        v.spawnExpectPlacedRightOfFocus(label: "centered", width: 360, height: 300)
    }
}

// MARK: - Randomized property fuzz

private func runSpawnValidateFuzz(baseSeed: UInt64, seeds: Int, ops: Int, _ t: inout TestCounter) {
    var firstFail: String?
    var failCount = 0
    var maxLatency = 0.0
    var totalSpawns = 0

    for k in 0..<seeds {
        let seed = baseSeed &+ UInt64(k) &* 0x100000001B3
        var rng = SplitMix64(seed: seed)
        let v = SpawnValidator(
            spawnWidth: rng.bool() ? rng.pick([CGFloat(0.25), 0.5, 0.75, 1.0]) : nil,
            fillHeight: rng.bool(),
            focusMode: rng.bool() ? .fit : .centered
        )

        // Always begin with one window so focus exists for the right-of-focus
        // checks from op 0.
        v.spawnExpectPlacedRightOfFocus(label: "s\(seed)-init", width: 360, height: 300)

        for _ in 0..<ops where v.ok {
            switch rng.int(6) {
            case 0:
                // Single spawn with a varied publish race + occasional hard min.
                let delay = rng.bool() ? rng.double(in: 0...0.18) : 0
                let minS: CGSize = rng.int(4) == 0
                    ? CGSize(width: rng.double(in: 200...1000), height: 200) : .zero
                v.spawnExpectPlacedRightOfFocus(
                    label: "s\(seed)-spawn", publishDelay: delay,
                    width: CGFloat(rng.double(in: 250...1900)),
                    height: CGFloat(rng.double(in: 250...700)), minSize: minS)
                totalSpawns += 1
            case 1:
                v.spawnBurstExpectContiguousRightOfFocus(
                    label: "s\(seed)-burst", n: rng.int(in: 2...4),
                    publishDelay: rng.bool() ? rng.double(in: 0...0.1) : 0)
                totalSpawns += rng.int(in: 2...4)
            case 2 where !v.engine.slots.isEmpty:
                v.focus(to: rng.int(v.engine.slots.count))
            case 3:
                v.setFocusedWidth(rng.pick([CGFloat(0.25), 0.5, 0.75, 1.0]))
            case 4 where v.engine.slots.count > 1:
                v.destroyFocused()
            default:
                v.minimizeNoiseWindow()
            }
        }

        for s in v.rec.stats() where s.label == "spawn-place" || s.label == "burst-place" {
            maxLatency = max(maxLatency, s.max)
        }
        if !v.ok {
            failCount += 1
            if firstFail == nil {
                firstFail = "seed \(seed): \(v.failures.first ?? "?")\n    ops:\n      "
                    + v.log.suffix(24).joined(separator: "\n      ")
            }
        }
        v.teardown()
    }

    t.check("fuzz: every spawn across \(seeds) seeds landed right-of-focus, fast (\(totalSpawns) spawns)",
            failCount == 0)
    if let f = firstFail { print("        " + f.replacingOccurrences(of: "\n", with: "\n        ")) }
    print(String(format: "    [spawnvalidate] fuzz max per-spawn placement latency: %.0f ms", maxLatency))
    t.check("fuzz: worst-case placement latency stayed on the fast path (< 1000ms)", maxLatency < 1000)
}

// MARK: - Entry point

/// `WindowLab spawnvalidate [baseSeed] [--seeds K] [--ops N]`
///
/// Exhaustively validates the "new window instantly appears right of focus"
/// contract across a named edge-case matrix AND a randomized property fuzz.
/// HEADLESS + deterministic. Exits non-zero on the first violated property.
func runSpawnValidate(args: [String]) -> Never {
    func intArg(_ flag: String, _ def: Int) -> Int {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return def }
        return Int(args[i + 1]) ?? def
    }
    let baseSeed = args.dropFirst().first.flatMap { UInt64($0) } ?? 1
    let seeds = intArg("--seeds", 24)
    let ops = intArg("--ops", 40)

    print("== ScrollWM spawnvalidate ==  base seed \(baseSeed)")
    var t = TestCounter()

    print("\n-- named edge-case scenarios --")
    runSpawnValidateScenarios(&t)

    print("\n-- randomized property fuzz (\(seeds) seeds x \(ops) ops) --")
    runSpawnValidateFuzz(baseSeed: baseSeed, seeds: seeds, ops: ops, &t)

    print("\n[spawnvalidate] \(t.passed) passed, \(t.failed) failed")
    exit(t.summaryExitCode)
}
