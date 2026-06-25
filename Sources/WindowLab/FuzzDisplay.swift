import Foundation
import ApplicationServices
import AppKit
import CoreGraphics

// MULTI-DISPLAY / GEOMETRY / RESTORE fuzzer (owned by the `fuzzdisp` agent).
//
// Goal: fuzz the multi-monitor + restore bug surface:
//   - random display HOTPLUG sequences (add/remove/resize/rearrange/sleep-wake,
//     negative origins, stable IDs) through `StripDisplayResolver` and the
//     engine's `rebindStripDisplay`, asserting the strip never strands windows
//     off every display and the resolver's choice is always in range;
//   - parking-corner policy (`computeParkingPoint`) across arbitrary layouts;
//   - `AdoptionScope` / `DisplayGeometry` / `DisplaySelector` property checks;
//   - `RestoreStore` save/load round-trips + display-safe restore targets under
//     unplugged monitors.
//
// Reuse `SplitMix64` from Fuzz.swift. Production edits allowed ONLY in
// DisplayGeometry.swift / StripDisplayResolver.swift / DisplaySelector.swift /
// AdoptionScope.swift / RestoreStore.swift; report engine/main changes to the
// coordinator. Keep all logic self-contained here. Entry point wired in main.swift.
//
// Everything is HEADLESS: the hotplug fuzzer installs a `SimWindowWorld` as
// `AXSource.backend` so no real window is ever spawned/moved, and the pure
// checks need no AX/AppKit state at all. A given (seed) replays bit-for-bit, so
// any failure prints the seed + the exact layout that triggered it and exits
// non-zero.

// MARK: - Small geometry helpers (test-local mirrors of production behavior)

private func rectStr(_ r: CGRect) -> String {
    String(format: "(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.width, r.height)
}

private func isFinite(_ r: CGRect) -> Bool {
    r.origin.x.isFinite && r.origin.y.isFinite && r.width.isFinite && r.height.isFinite
}

/// Mirror of the macOS off-screen clamp that `SimWindowWorld` models: a window
/// shoved far past a display edge keeps a `clampMargin`px sliver visible at the
/// NEAREST display's edge (it is never left floating in the dead space between
/// two screens). Used by the parking-corner property to prove a parked sliver
/// actually lands on the strip's own display, not a neighbor.
private func macClamp(origin: CGPoint, size: CGSize, displays: [CGRect],
                      clampMargin: CGFloat = 40) -> CGPoint {
    guard !displays.isEmpty else { return origin }
    func clampTo(_ d: CGRect) -> CGPoint {
        let minX = d.minX - (size.width - clampMargin)
        let maxX = d.maxX - clampMargin
        let minY = d.minY - (size.height - clampMargin)
        let maxY = d.maxY - clampMargin
        return CGPoint(x: min(max(origin.x, minX), maxX),
                       y: min(max(origin.y, minY), maxY))
    }
    let req = CGRect(origin: origin, size: size)
    if displays.contains(where: { $0.intersects(req) }) { return origin }
    // Match `SimWindowWorld.clamp`: prefer a display reachable by a PURE
    // single-axis move (a side-parked full-height window slides straight back
    // onto the display covering its y-band, never diagonally onto a disjoint
    // neighbor); fall back to the nearest overall only if no pure-axis fix
    // exists (a true corner push off every display's band).
    var pureBest: (p: CGPoint, dist: CGFloat)?
    var anyBest: (p: CGPoint, dist: CGFloat)?
    for d in displays {
        let c = clampTo(d)
        let dx = c.x - origin.x, dy = c.y - origin.y
        let dist = hypot(dx, dy)
        if anyBest == nil || dist < anyBest!.dist { anyBest = (c, dist) }
        if abs(dx) < 0.5 || abs(dy) < 0.5 {
            if pureBest == nil || dist < pureBest!.dist { pureBest = (c, dist) }
        }
    }
    return (pureBest ?? anyBest)!.p
}

// MARK: - Hotplug fuzzer (resolver + engine rebind against the sim world)

/// One physical display, tracked by a STABLE id across the hotplug sequence
/// (exactly like a real `CGDirectDisplayID`): its frame may move/resize but its
/// id is constant while it stays plugged in.
private struct PhysDisplay {
    let id: CGDirectDisplayID
    var frame: CGRect            // AX top-left global coords
}

/// Stateful fuzzer: drives a real `TeleportEngine` (managing windows in a
/// `SimWindowWorld`) through a long sequence of random display hotplug events,
/// each resolved by `StripDisplayResolver` and applied via `rebindStripDisplay`.
/// After every step it checks the multi-display invariants the brief calls out.
private final class DisplayHotplugFuzzer {
    private let seed: UInt64
    private var rng: SplitMix64
    private let world = SimWindowWorld()
    private let engine: TeleportEngine

    private var phys: [PhysDisplay] = []
    private var stripID: CGDirectDisplayID?
    private var nextDisplayID: CGDirectDisplayID = 1
    private var pids: [pid_t] = []
    private var nextPID: pid_t = 9000
    /// Replay log of the layout at each step, so a failure is reproducible.
    private(set) var log: [String] = []

    init(seed: UInt64) {
        self.seed = seed
        self.rng = SplitMix64(seed: seed)
        // A throwaway starting frame; the first bind overwrites it.
        self.engine = TeleportEngine(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        AXSource.backend = world
        engine.gap = 12
        engine.minColumnWidth = 200
        engine.widthPresets = [0.25, 0.5, 0.75, 1.0]
        engine.adoptScope = rng.bool() ? .stripDisplay : .allDisplays
    }

    deinit { AXSource.backend = nil }

    private func freshID() -> CGDirectDisplayID { let id = nextDisplayID; nextDisplayID += 1; return id }

    /// A random display frame in AX coords, including NEGATIVE origins (monitors
    /// above/left of the primary) and a wide range of resolutions.
    private func randDisplay(id: CGDirectDisplayID) -> PhysDisplay {
        let x = CGFloat(rng.double(in: -2400...3200))
        let y = CGFloat(rng.double(in: -2200...2200))
        let w = CGFloat(rng.double(in: 640...3840))
        let h = CGFloat(rng.double(in: 480...2160))
        return PhysDisplay(id: id, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    private func spawnWindow() {
        let pid = nextPID; nextPID += 1
        pids.append(pid)
        // Frames span on/off the strip display to stress layout + parking.
        let x = CGFloat(rng.double(in: -600...2400))
        let y = CGFloat(rng.double(in: -600...1600))
        let w = CGFloat(rng.double(in: 160...2200))
        let h = CGFloat(rng.double(in: 160...1400))
        _ = world.addWindow(pid: pid, title: "W\(pid)", frame: CGRect(x: x, y: y, width: w, height: h))
    }

    private func standardWindows() -> [AXWindowInfo] {
        pids.flatMap { AXSource.windows(forPID: $0) }
            .filter { $0.subrole == kAXStandardWindowSubrole as String && !$0.isMinimized && !$0.isFullscreen }
    }

    private func matchedNow() -> [MatchedWindow] {
        IdentityMatcher.match(axWindows: standardWindows(),
                              cgWindows: CGWindowSource.listWindows(onscreenOnly: true))
    }

    /// Push the current `phys` set into the engine + sim world for the chosen
    /// strip display index, then relay every managed window onto it.
    private func applyBind(stripIndex idx: Int) {
        let chosen = phys[idx]
        engine.stripDisplayFrame = chosen.frame
        engine.otherDisplayFrames = phys.indices.filter { $0 != idx }.map { phys[$0].frame }
        world.displays = phys.map { $0.frame }
        stripID = chosen.id
        engine.rebindStripDisplay(to: chosen.frame)
        // Model what the real WindowServer does on a display reconfiguration:
        // every existing window is RE-CLAMPED to stay on some surviving screen.
        // The sim only clamps at `setPosition` time, and the engine legitimately
        // SKIPS re-committing a parked window whose (unclamped) target corner is
        // unchanged - so without this, a window parked against the strip's own
        // edge could read as "off-screen" purely because the sim never re-clamped
        // it after the OTHER displays moved. macOS itself re-clamps here, so we
        // mirror that to test the ENGINE's intent, not a sim-staleness artifact.
        for slot in engine.allManagedSlots {
            if let f = world.frame(of: slot.window.element) {
                _ = AXSource.setPoint(slot.window.element, kAXPositionAttribute as String, f.origin)
            }
        }
    }

    func run(steps: Int) -> String? {
        // Seed an initial display set (1-4) and bind the strip to the first.
        let n = rng.int(in: 1...4)
        phys = (0..<n).map { _ in randDisplay(id: freshID()) }
        applyBind(stripIndex: 0)

        // Adopt 0-6 windows (0 exercises the empty-strip path).
        let windows = rng.int(in: 0...6)
        for _ in 0..<windows { spawnWindow() }
        engine.focusMode = rng.bool() ? .fit : .centered
        engine.adopt(matched: matchedNow())
        if !engine.slots.isEmpty { engine.focus(index: rng.int(engine.slots.count)) }
        if let v = check(step: -1, sleeping: false) { return v }

        for step in 0..<steps {
            // ~1 in 7 steps simulate ALL monitors asleep (resolver case 3).
            let sleeping = rng.int(7) == 0
            if !sleeping { mutate() }
            if let v = stepResolve(step: step, sleeping: sleeping) { return v }
        }
        return nil
    }

    /// Apply ONE random hotplug mutation to the physical display set.
    private func mutate() {
        enum Op: CaseIterable { case add, remove, resize, move, swap }
        switch rng.pick(Op.allCases) {
        case .add where phys.count < 4:
            phys.append(randDisplay(id: freshID()))
        case .remove where phys.count > 1:
            phys.remove(at: rng.int(phys.count))
        case .resize:
            let i = rng.int(phys.count)
            phys[i].frame.size = CGSize(width: CGFloat(rng.double(in: 640...3840)),
                                        height: CGFloat(rng.double(in: 480...2160)))
        case .move:
            let i = rng.int(phys.count)
            phys[i].frame.origin = CGPoint(x: CGFloat(rng.double(in: -2400...3200)),
                                           y: CGFloat(rng.double(in: -2200...2200)))
        case .swap where phys.count >= 2:
            // Arrangement swap: two displays exchange origins (the case pure
            // overlap gets wrong but stable-id tracking must get right).
            let a = rng.int(phys.count); var b = rng.int(phys.count)
            if a == b { b = (b + 1) % phys.count }
            let tmp = phys[a].frame.origin; phys[a].frame.origin = phys[b].frame.origin; phys[b].frame.origin = tmp
        default:
            // Op not applicable to current count (e.g. add at 4): nudge a frame.
            let i = rng.int(phys.count)
            phys[i].frame.origin.x += CGFloat(rng.double(in: -50...50))
        }
    }

    /// Resolve the strip display for the current (possibly empty) layout, assert
    /// invariants, and apply the rebind. Returns a failure description or nil.
    private func stepResolve(step: Int, sleeping: Bool) -> String? {
        let priorStripID = stripID
        let priorFrame = engine.screenFrame
        let displays = sleeping ? [] : phys.map { $0.frame }
        let ids: [CGDirectDisplayID]? = sleeping ? nil : phys.map { $0.id }

        log.append("step \(step): strip=\(priorStripID.map { "\($0)" } ?? "nil") "
                   + "displays=[\(phys.map { "\($0.id)@\(rectStr($0.frame))" }.joined(separator: ", "))]"
                   + (sleeping ? " (ASLEEP)" : ""))

        let decision = StripDisplayResolver.resolve(
            stripFrame: priorFrame, displays: displays,
            stripDisplayID: priorStripID, displayIDs: ids)

        // (a) chosen index in range / nil only when empty.
        if displays.isEmpty {
            if decision.displayIndex != nil {
                return fail(step, "resolver returned index \(decision.displayIndex!) for an EMPTY display set")
            }
            if decision.frame != priorFrame {
                return fail(step, "resolver changed frame with no displays: \(rectStr(priorFrame)) -> \(rectStr(decision.frame))")
            }
            if decision.migrated { return fail(step, "resolver migrated with no displays") }
            return nil // monitors asleep: keep put, nothing to relay.
        }
        guard let idx = decision.displayIndex else {
            return fail(step, "resolver returned nil index for \(displays.count) displays")
        }
        if idx < 0 || idx >= displays.count {
            return fail(step, "resolver index \(idx) out of range 0..<\(displays.count)")
        }
        if decision.frame != displays[idx] {
            return fail(step, "resolver frame \(rectStr(decision.frame)) != chosen display \(rectStr(displays[idx]))")
        }
        if !isFinite(decision.frame) { return fail(step, "resolver frame non-finite: \(decision.frame)") }

        // (b) a PRESENT display-by-ID is FOLLOWED, never spuriously migrated.
        if let sid = priorStripID, let presentIdx = phys.firstIndex(where: { $0.id == sid }) {
            if decision.migrated {
                return fail(step, "strip's display id \(sid) is still present (index \(presentIdx)) but resolver MIGRATED")
            }
            if idx != presentIdx {
                return fail(step, "strip's display id \(sid) is at index \(presentIdx) but resolver chose \(idx)")
            }
        }

        // Apply the resolved bind, then check the relayed world.
        applyBind(stripIndex: idx)
        return check(step: step, sleeping: sleeping)
    }

    /// Post-rebind invariants: finite geometry, and no managed window stranded
    /// off EVERY display.
    private func check(step: Int, sleeping: Bool) -> String? {
        if !isFinite(engine.screenFrame) {
            return fail(step, "engine.screenFrame non-finite: \(engine.screenFrame)")
        }
        for (i, s) in engine.slots.enumerated() {
            for (name, v) in [("canvasX", s.canvasX), ("width", s.width), ("height", s.height), ("y", s.y)] {
                if !v.isFinite { return fail(step, "slot[\(i)] \(s.window.title) \(name) non-finite: \(v)") }
            }
            if s.width <= 0 { return fail(step, "slot[\(i)] \(s.window.title) width <= 0: \(s.width)") }
            if s.height <= 0 { return fail(step, "slot[\(i)] \(s.window.title) height <= 0: \(s.height)") }
        }

        // AdoptionScope.filter never crashes / always returns a sorted subset for
        // the live geometry (extra coverage of the adopt path each step).
        let strip = engine.stripDisplayFrame ?? engine.screenFrame
        let frames = engine.slots.map { $0.window.originalFrame }
        let kept = AdoptionScope.filter(frames: frames, stripDisplay: strip,
                                        others: engine.otherDisplayFrames, scope: engine.adoptScope)
        if kept != kept.sorted() { return fail(step, "AdoptionScope.filter not sorted: \(kept)") }
        if !kept.allSatisfy({ frames.indices.contains($0) }) { return fail(step, "AdoptionScope.filter out-of-range index in \(kept)") }

        // The strip must never strand a managed window off ALL displays: the
        // relay (+ macOS sliver clamp the sim models) keeps every window touching
        // some screen. Skip while asleep (no displays to be on).
        let displays = world.displays
        guard !displays.isEmpty else { return nil }
        for s in engine.slots where s.window.healthy {
            guard let f = world.frame(of: s.window.element) else { continue }
            if !displays.contains(where: { $0.intersects(f) }) {
                return fail(step, "managed window \(s.window.title) stranded off ALL displays at \(rectStr(f))")
            }
        }
        return nil
    }

    private func fail(_ step: Int, _ msg: String) -> String {
        """
        DISPLAY HOTPLUG VIOLATION (seed \(seed), step \(step)): \(msg)
          adoptScope: \(engine.adoptScope.rawValue), focusMode: \(engine.focusMode.rawValue)
          layout trace (\(log.count) steps):
            \(log.suffix(12).joined(separator: "\n    "))
        """
    }
}

// MARK: - Pure property fuzzer (parking / scope / geometry / selector / restore)

private enum DisplayPureFuzz {

    /// Run `iterations` randomized property checks. Returns failure messages
    /// (empty on success). Each failure embeds the seed + concrete inputs.
    static func run(seed: UInt64, iterations: Int) -> [String] {
        var rng = SplitMix64(seed: seed)
        var fails: [String] = []
        func bad(_ s: String) { if fails.count < 30 { fails.append("seed \(seed): \(s)") } }

        randomDisplaysHelper(&rng) // warm-up no-op to keep determinism explicit
        parkingChecks(&rng, iterations, bad)
        adoptionScopeChecks(&rng, iterations, bad)
        ensureVisibleChecks(&rng, iterations, bad)
        displaySelectorChecks(&rng, iterations, bad)
        restoreChecks(&rng, iterations, bad)
        return fails
    }

    private static func randomDisplaysHelper(_ rng: inout SplitMix64) {}

    private static func randRect(_ rng: inout SplitMix64,
                                 x: ClosedRange<Double> = -2400...3200,
                                 y: ClosedRange<Double> = -2200...2200,
                                 w: ClosedRange<Double> = 200...3840,
                                 h: ClosedRange<Double> = 200...2160) -> CGRect {
        CGRect(x: CGFloat(rng.double(in: x)), y: CGFloat(rng.double(in: y)),
               width: CGFloat(rng.double(in: w)), height: CGFloat(rng.double(in: h)))
    }

    // 2) computeParkingX: the parked FULL-HEIGHT sliver lands on the strip's OWN
    //    display. A parked window keeps its natural vertical band and only slides
    //    off a side, so this is a purely horizontal contract.
    private static func parkingChecks(_ rng: inout SplitMix64, _ iters: Int, _ bad: (String) -> Void) {
        for _ in 0..<iters {
            // --- (i) ARBITRARY (possibly overlapping) layouts: the edge is
            // always finite, outside the strip horizontally, and favors a free
            // strip side. These hold regardless of physical realizability.
            let strip = randRect(&rng, w: 640...3840, h: 480...2160)
            let others = (0..<rng.int(in: 0...3)).map { _ in randRect(&rng, w: 640...3840, h: 480...2160) }
            for side in [TeleportEngine.ParkSide.left, .right] {
                let x = TeleportEngine.computeParkingX(stripDisplay: strip, others: others, prefer: side)
                if !x.isFinite { bad("parking non-finite: strip=\(rectStr(strip)) others=\(others.map(rectStr)) -> \(x)"); continue }
                // The shove is past a strip side edge (outside it horizontally).
                if x > strip.minX && x < strip.maxX { bad("parking x inside strip: strip=\(rectStr(strip)) -> \(x)") }
                // Documented contract: edge favors the strip (past a FREE side).
                if !GeometryHardeningTests.parkingEdgeFavorsStrip(x, strip: strip, others: others) {
                    bad("parking edge does not favor strip (side=\(side)): strip=\(rectStr(strip)) others=\(others.map(rectStr)) -> \(x)")
                }
            }

            // --- (ii) REALISTIC (non-overlapping, edge-tiled) layouts: simulate
            // the actual macOS off-screen clamp and prove the parked sliver lands
            // on the STRIP, never inside a neighbor. Real displays never overlap,
            // so the nearest-display clamp is only meaningful on a tiled layout.
            // The parked window keeps its full vertical band (origin y = strip
            // top), so the sliver is a TALL peek at the chosen side edge.
            let (rStrip, rOthers, blockedSides) = tiledLayout(&rng)
            let allDisplays = [rStrip] + rOthers
            for side in [TeleportEngine.ParkSide.left, .right] {
                let x = TeleportEngine.computeParkingX(stripDisplay: rStrip, others: rOthers, prefer: side)
                // Skip when BOTH side edges are blocked (a sliver on a busy edge
                // is then unavoidable, matching the production contract).
                if blockedSides.left && blockedSides.right { continue }
                // Full-height-ish window pinned to the strip's vertical band.
                let size = CGSize(width: 360, height: min(280, rStrip.height))
                let p = CGPoint(x: x, y: rStrip.minY)
                let clamped = macClamp(origin: p, size: size, displays: allDisplays)
                let frame = CGRect(origin: clamped, size: size)
                if let landed = DisplayGeometry.display(bestOverlapping: frame, displays: allDisplays),
                   landed != rStrip {
                    bad("parked sliver landed on a NEIGHBOR not the strip (side=\(side)): "
                        + "strip=\(rectStr(rStrip)) others=\(rOthers.map(rectStr)) parkX=\(x) clamped=\(rectStr(frame)) landed=\(rectStr(landed))")
                } else if !frame.intersects(rStrip) {
                    bad("parked sliver does not touch the strip (side=\(side)): strip=\(rectStr(rStrip)) clamped=\(rectStr(frame))")
                }
            }
        }
    }

    /// A physically-realizable display layout: a strip plus up to one neighbor
    /// flush against each of a random subset of its four edges (non-overlapping,
    /// sharing the perpendicular span so the neighbor genuinely BLOCKS that edge,
    /// exactly like real monitors tiled around a primary). Returns the strip, the
    /// neighbors, and which strip edges ended up blocked.
    private static func tiledLayout(_ rng: inout SplitMix64)
        -> (strip: CGRect, others: [CGRect], blocked: (left: Bool, right: Bool, top: Bool, bottom: Bool)) {
        let strip = CGRect(x: CGFloat(rng.double(in: -1500...1500)),
                           y: CGFloat(rng.double(in: -1200...1200)),
                           width: CGFloat(rng.double(in: 800...2560)),
                           height: CGFloat(rng.double(in: 600...1600)))
        var others: [CGRect] = []
        var blocked = (left: false, right: false, top: false, bottom: false)
        // Each side independently gets a neighbor with ~50% probability.
        if rng.bool() {
            let w = CGFloat(rng.double(in: 600...2000)), h = CGFloat(rng.double(in: 400...1400))
            others.append(CGRect(x: strip.maxX, y: strip.minY, width: w, height: h)); blocked.right = true
        }
        if rng.bool() {
            let w = CGFloat(rng.double(in: 600...2000)), h = CGFloat(rng.double(in: 400...1400))
            others.append(CGRect(x: strip.minX - w, y: strip.minY, width: w, height: h)); blocked.left = true
        }
        if rng.bool() {
            let w = CGFloat(rng.double(in: 400...1400)), h = CGFloat(rng.double(in: 400...1400))
            others.append(CGRect(x: strip.minX, y: strip.minY - h, width: w, height: h)); blocked.top = true
        }
        if rng.bool() {
            let w = CGFloat(rng.double(in: 400...1400)), h = CGFloat(rng.double(in: 400...1400))
            others.append(CGRect(x: strip.minX, y: strip.maxY, width: w, height: h)); blocked.bottom = true
        }
        return (strip, others, blocked)
    }

    // 3a) AdoptionScope.filter: sorted, idempotent, subset; semantics by scope.
    private static func adoptionScopeChecks(_ rng: inout SplitMix64, _ iters: Int, _ bad: (String) -> Void) {
        for _ in 0..<iters {
            let n = rng.int(in: 0...8)
            let frames = (0..<n).map { _ in randRect(&rng, w: 1...1600, h: 1...1200) }
            let strip = randRect(&rng, w: 640...2400, h: 480...1600)
            let others = (0..<rng.int(in: 0...3)).map { _ in randRect(&rng, w: 640...2400, h: 480...1600) }
            let scope: AdoptionScope.Scope = rng.bool() ? .stripDisplay : .allDisplays
            let keep = AdoptionScope.filter(frames: frames, stripDisplay: strip, others: others, scope: scope)

            if keep != keep.sorted() { bad("AdoptionScope.filter not sorted: \(keep)") }
            if Set(keep).count != keep.count { bad("AdoptionScope.filter has duplicates: \(keep)") }
            if !keep.allSatisfy({ frames.indices.contains($0) }) { bad("AdoptionScope.filter out-of-range index: \(keep)") }
            // allDisplays keeps everything; single-display (no others) keeps everything.
            if scope == .allDisplays && keep.count != n { bad("allDisplays dropped windows: \(keep.count)/\(n)") }
            if others.isEmpty && keep.count != n { bad("single-display dropped windows: \(keep.count)/\(n)") }
            // Every kept frame genuinely belongs to the strip display under stripDisplay scope.
            if scope == .stripDisplay {
                for i in keep where !AdoptionScope.belongsToStripDisplay(frames[i], stripDisplay: strip, others: others) {
                    bad("AdoptionScope kept a frame that does not belong to strip: \(rectStr(frames[i]))")
                }
            }
            // Idempotent: filtering the kept frames again keeps all of them.
            let keptFrames = keep.map { frames[$0] }
            let again = AdoptionScope.filter(frames: keptFrames, stripDisplay: strip, others: others, scope: scope)
            if again.count != keep.count { bad("AdoptionScope.filter not idempotent: \(keep.count) -> \(again.count)") }
        }
    }

    // 3b) DisplayGeometry.ensureVisible: always visible, never grows, finite.
    private static func ensureVisibleChecks(_ rng: inout SplitMix64, _ iters: Int, _ bad: (String) -> Void) {
        for _ in 0..<iters {
            let frame = randRect(&rng, w: 1...2400, h: 1...1800)
            let displays = (0..<rng.int(in: 1...4)).map { _ in randRect(&rng, w: 200...3840, h: 200...2160) }
            let out = DisplayGeometry.ensureVisible(frame, displays: displays)
            if !isFinite(out) { bad("ensureVisible non-finite: \(rectStr(frame)) -> \(out)") }
            if !DisplayGeometry.isMostlyVisible(out, on: displays) {
                bad("ensureVisible result not visible: \(rectStr(frame)) displays=\(displays.map(rectStr)) -> \(rectStr(out))")
            }
            if out.width > frame.width + 0.5 || out.height > frame.height + 0.5 {
                bad("ensureVisible grew the frame: \(rectStr(frame)) -> \(rectStr(out))")
            }
            // No-op when already visible.
            if DisplayGeometry.isMostlyVisible(frame, on: displays) && out != frame {
                bad("ensureVisible perturbed an already-visible frame: \(rectStr(frame)) -> \(rectStr(out))")
            }
            // clamp lands fully inside its target display.
            let target = displays[rng.int(displays.count)]
            let clamped = DisplayGeometry.clamp(frame, into: target)
            let eps: CGFloat = 0.001
            if clamped.minX < target.minX - eps || clamped.maxX > target.maxX + eps
                || clamped.minY < target.minY - eps || clamped.maxY > target.maxY + eps {
                bad("clamp escaped its display: \(rectStr(frame)) into \(rectStr(target)) -> \(rectStr(clamped))")
            }
        }
    }

    // 3c) DisplaySelector.pick: in-range or nil, never crashes.
    private static func displaySelectorChecks(_ rng: inout SplitMix64, _ iters: Int, _ bad: (String) -> Void) {
        let specs = ["", "main", "primary", "largest", "next", " MAIN ", "Largest", "NEXT",
                     "1", "2", "3", "4", "5", "0", "-1", "abc", " 2 ", "1.5", "  "]
        for _ in 0..<iters {
            let n = rng.int(in: 1...4)
            let displays = (0..<n).map { _ in
                DisplaySelector.DisplayInfo(frame: randRect(&rng, w: 200...3840, h: 200...2160),
                                            isMain: rng.bool(), isPrimary: rng.bool())
            }
            let spec = rng.bool() ? rng.pick(specs) : "\(rng.int(in: -2...8))"
            let current: Int? = rng.bool() ? rng.int(in: -1...(n + 1)) : nil
            let r = DisplaySelector.pick(spec: spec, displays: displays, current: current)
            if let i = r, i < 0 || i >= n {
                bad("DisplaySelector.pick(\"\(spec)\") returned out-of-range \(i) for \(n) displays")
            }
            // An empty display list always yields nil.
            if DisplaySelector.pick(spec: spec, displays: [], current: current) != nil {
                bad("DisplaySelector.pick(\"\(spec)\") returned non-nil for an EMPTY display list")
            }
            // A well-formed 1-based integer in range maps to n-1.
            if let v = Int(spec.trimmingCharacters(in: .whitespaces)), v >= 1, v <= n {
                if r != v - 1 { bad("DisplaySelector.pick(\"\(spec)\") = \(String(describing: r)), expected \(v - 1)") }
            }
        }
    }

    // 4) RestoreStore safeTarget under unplugged monitors (pure path).
    private static func restoreChecks(_ rng: inout SplitMix64, _ iters: Int, _ bad: (String) -> Void) {
        for _ in 0..<iters {
            let saved = randRect(&rng, w: 1...2400, h: 1...1800)
            let entry = RestoreStore.Entry(pid: pid_t(rng.int(in: 1...9999)), appName: "App", title: "Win",
                                           x: Double(saved.origin.x), y: Double(saved.origin.y),
                                           w: Double(saved.width), h: Double(saved.height))
            // Sometimes NO displays (degenerate): safeTarget must be the saved frame untouched.
            if rng.int(8) == 0 {
                let t = RestoreStore.safeTarget(for: entry, displays: [])
                if t != saved { bad("safeTarget with no displays changed the frame: \(rectStr(saved)) -> \(rectStr(t))") }
                continue
            }
            let displays = (0..<rng.int(in: 1...4)).map { _ in randRect(&rng, w: 200...3840, h: 200...2160) }
            let t = RestoreStore.safeTarget(for: entry, displays: displays)
            if !isFinite(t) { bad("safeTarget non-finite: \(rectStr(saved)) -> \(t)") }
            if !DisplayGeometry.isMostlyVisible(t, on: displays) {
                bad("safeTarget not visible on survivors: \(rectStr(saved)) displays=\(displays.map(rectStr)) -> \(rectStr(t))")
            }
            if t.width > saved.width + 0.5 || t.height > saved.height + 0.5 {
                bad("safeTarget grew the frame: \(rectStr(saved)) -> \(rectStr(t))")
            }
            // Untouched when the saved frame is already mostly visible.
            if DisplayGeometry.isMostlyVisible(saved, on: displays) && t != saved {
                bad("safeTarget perturbed an already-visible frame: \(rectStr(saved)) -> \(rectStr(t))")
            }
        }
    }
}

// MARK: - RestoreStore disk round-trip (sandboxed file, real save/load)

private enum RestoreRoundTrip {
    /// Build a managed engine in a sim world, persist via `RestoreStore.save`,
    /// reload via `pendingEntries`, and assert the round-trip is lossless and
    /// `safeTarget` keeps every entry on a surviving display. Uses the
    /// sandbox subdirectory + clear() so the user's real recovery file is never
    /// touched. Returns failure messages (empty on success).
    static func run(seed: UInt64) -> [String] {
        var rng = SplitMix64(seed: seed)
        var fails: [String] = []
        func bad(_ s: String) { fails.append("restore round-trip seed \(seed): \(s)") }

        RestoreStore.subdirectory = "ScrollWM-Sandbox"
        RestoreStore.clear()

        let world = SimWindowWorld()
        let strip = CGRect(x: 0, y: 0, width: 1680, height: 1050)
        world.displays = [strip]
        AXSource.backend = world
        defer { AXSource.backend = nil; RestoreStore.clear() }

        let engine = TeleportEngine(screenFrame: CGRect(x: 0, y: 32, width: 1680, height: 1018))
        engine.stripDisplayFrame = strip
        engine.gap = 12; engine.minColumnWidth = 200

        var pids: [pid_t] = []
        let n = rng.int(in: 1...6)
        for k in 0..<n {
            let pid = pid_t(5000 + k); pids.append(pid)
            _ = world.addWindow(pid: pid, title: "RW\(pid)",
                                frame: CGRect(x: CGFloat(rng.double(in: -200...1400)),
                                              y: CGFloat(rng.double(in: 0...900)),
                                              width: CGFloat(rng.double(in: 200...1200)),
                                              height: CGFloat(rng.double(in: 200...900))))
        }
        let std = pids.flatMap { AXSource.windows(forPID: $0) }
        let matched = IdentityMatcher.match(axWindows: std, cgWindows: CGWindowSource.listWindows(onscreenOnly: true))
        engine.adopt(matched: matched)

        let slots = engine.allManagedSlots
        RestoreStore.save(engine: engine)
        let entries = RestoreStore.pendingEntries()

        if entries.count != slots.count {
            bad("entry count \(entries.count) != managed slots \(slots.count)")
            return fails
        }
        for (e, s) in zip(entries, slots) {
            let orig = s.window.originalFrame
            if e.pid != s.window.pid { bad("pid mismatch: \(e.pid) vs \(s.window.pid)") }
            if abs(e.x - Double(orig.origin.x)) > 1e-6 || abs(e.y - Double(orig.origin.y)) > 1e-6
                || abs(e.w - Double(orig.width)) > 1e-6 || abs(e.h - Double(orig.height)) > 1e-6 {
                bad("frame did not round-trip for \(s.window.title): saved (\(e.x),\(e.y),\(e.w),\(e.h)) vs original \(rectStr(orig))")
            }
        }

        // safeTarget under the strip display UNPLUGGED: every entry rescued onto
        // a surviving (negative-origin) external instead of stranded off-screen.
        let survivor = CGRect(x: -300, y: -1080, width: 1920, height: 1080)
        for e in entries {
            let t = RestoreStore.safeTarget(for: e, displays: [survivor])
            if !DisplayGeometry.isMostlyVisible(t, on: [survivor]) {
                bad("safeTarget did not rescue \(e.title) onto the surviving display: -> \(rectStr(t))")
            }
            if !isFinite(t) { bad("safeTarget non-finite for \(e.title): \(t)") }
        }

        // clear() actually removes the file.
        RestoreStore.clear()
        if !RestoreStore.pendingEntries().isEmpty { bad("RestoreStore.clear did not remove the recovery file") }
        return fails
    }
}

// MARK: - Entry point

/// `WindowLab fuzzdisp [baseSeed] [--iters M] [--seeds K] [--steps N]`
///
/// Runs K hotplug seeds (each N random display events), K pure-property seeds
/// (each M iterations of the parking/scope/geometry/selector/restore checks),
/// and K restore disk round-trip seeds. Deterministic from the base seed; any
/// failure prints the seed + the exact layout that triggered it and exits 1.
func runFuzzDisplay(args: [String]) -> Never {
    func intArg(_ flag: String, _ def: Int) -> Int {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return def }
        return Int(args[i + 1]) ?? def
    }

    let baseSeed = args.dropFirst().first.flatMap { UInt64($0) }
        ?? UInt64(Date().timeIntervalSince1970)
    let iters = intArg("--iters", 2000)
    let seedCount = intArg("--seeds", 120)
    let steps = intArg("--steps", 160)

    print("== ScrollWM fuzzdisp ==  base seed \(baseSeed)")
    var totalFail = 0
    var firstFail: String?
    func note(_ s: String) { if firstFail == nil { firstFail = s } }

    // --- Hotplug fuzz: resolver + engine rebind against the sim world. --------
    print("\n-- display hotplug fuzz: \(seedCount) seeds x \(steps) steps --")
    for k in 0..<seedCount {
        let seed = baseSeed &+ UInt64(k) &* 0x100000001B3
        let fuzzer = DisplayHotplugFuzzer(seed: seed)
        if let v = fuzzer.run(steps: steps) {
            totalFail += 1; note(v)
            print("  \u{2717} seed \(seed) FAILED")
        }
        if (k + 1) % 25 == 0 || k + 1 == seedCount {
            print("JCODE_PROGRESS {\"current\":\(k + 1),\"total\":\(seedCount),\"unit\":\"seeds\",\"message\":\"hotplug fuzz\"}")
        }
    }
    if firstFail == nil {
        print("  \u{2713} hotplug fuzz: all \(seedCount) seeds passed (\(seedCount * steps) hotplug events)")
    }

    // --- Pure property fuzz: parking / scope / geometry / selector / restore. -
    print("\n-- pure property fuzz: \(seedCount) seeds x \(iters) iters --")
    var pureFails: [String] = []
    for k in 0..<seedCount {
        let seed = baseSeed &+ 0xD15D_0000 &+ UInt64(k) &* 0x100000001B3
        let fs = DisplayPureFuzz.run(seed: seed, iterations: iters)
        if !fs.isEmpty { totalFail += fs.count; if pureFails.count < 12 { pureFails.append(fs[0]) }; note(fs[0]) }
    }
    if pureFails.isEmpty {
        print("  \u{2713} pure fuzz: all \(seedCount) seeds passed (~\(seedCount * iters * 5) checks)")
    } else {
        for f in pureFails { print("  \u{2717} \(f)") }
    }

    // --- Restore disk round-trip (sandboxed file). ----------------------------
    print("\n-- restore round-trip: \(seedCount) seeds --")
    var restoreFails: [String] = []
    for k in 0..<seedCount {
        let seed = baseSeed &+ 0x12E5_7000 &+ UInt64(k) &* 0x100000001B3
        let fs = RestoreRoundTrip.run(seed: seed)
        if !fs.isEmpty { totalFail += fs.count; if restoreFails.count < 12 { restoreFails.append(fs[0]) }; note(fs[0]) }
    }
    if restoreFails.isEmpty {
        print("  \u{2713} restore round-trip: all \(seedCount) seeds passed")
    } else {
        for f in restoreFails { print("  \u{2717} \(f)") }
    }

    print("\n========================================")
    if totalFail == 0 {
        print("FUZZDISP PASSED (no violations)")
        exit(0)
    } else {
        if let f = firstFail { print("FIRST FAILURE:\n\(f)\n") }
        print("FUZZDISP FAILED: \(totalFail) violation(s)")
        exit(1)
    }
}
