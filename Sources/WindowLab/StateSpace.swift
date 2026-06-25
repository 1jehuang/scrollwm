import Foundation
import ApplicationServices
import AppKit

// STATE-SPACE (bounded exhaustive / explicit-state model checking) testing.
//
// Where fuzzing samples the reachable state space RANDOMLY, this ENUMERATES it:
// a breadth-first search over every reachable state up to a depth bound, with
// visited-state dedup so the search is finite and never revisits a state. Two
// properties make it complementary to the fuzzers:
//   1. COVERAGE: within the bound, EVERY reachable state and EVERY enabled
//      transition out of it is checked, so a bug that only triggers on one
//      precise interleaving is found deterministically (not probabilistically).
//   2. SHORTEST COUNTEREXAMPLE: BFS finds a bug at the minimum number of ops,
//      and we reconstruct the exact path, so a failure is a tiny, readable repro
//      instead of a 400-step fuzz log.
//
// Targets (each is a place where exhaustive checking pays off):
//   - ENGINE: the strip state machine (focus/move/close/width/open/workspace/
//     fit) under a SMALL alphabet, BFS to a depth/visited bound, asserting the
//     same structural invariants the fuzzer uses PLUS a canonical-form check.
//   - ResyncPlanner.decide: exhaustive over all (strip, ax, currentSpace)
//     subsets of a tiny id universe (a full decision-table proof).
//   - computeParkingPoint: exhaustive over all neighbor-display configurations
//     x preferred side (the sliver must land on the strip's own display).
//   - DisplaySelector.pick: exhaustive over specs x layouts x current index.
//   - SemVer: exhaustive total-order axiom proof over a curated version set.
//
// All headless / pure: nothing here spawns, moves, or focuses a real window.

// MARK: - Engine state-space exploration

/// One transition the explorer can take from a state. Deterministic: a given
/// label always maps to the same engine mutation, so a path replays exactly.
private enum EngineMove: Hashable, CustomStringConvertible {
    case focus(Int)            // focus an absolute index
    case focusNext, focusPrev
    case moveLeft, moveRight   // reorder focused column
    case width(Int)            // preset index into a fixed width table
    case close
    case open                  // adopt a brand-new window to the right of focus
    case wsDown, wsUp          // switch workspace
    case moveWsDown, moveWsUp  // send focused column to adjacent workspace
    case fitAll

    var description: String {
        switch self {
        case .focus(let i): return "focus(\(i))"
        case .focusNext: return "focusNext"
        case .focusPrev: return "focusPrev"
        case .moveLeft: return "moveLeft"
        case .moveRight: return "moveRight"
        case .width(let i): return "width[\(i)]"
        case .close: return "close"
        case .open: return "open"
        case .wsDown: return "wsDown"
        case .wsUp: return "wsUp"
        case .moveWsDown: return "moveWsDown"
        case .moveWsUp: return "moveWsUp"
        case .fitAll: return "fitAll"
        }
    }
}

/// Bounded explicit-state explorer over the REAL `TeleportEngine`.
///
/// Each visited node is the engine's canonical `WorkspacesSnapshot` (logical
/// structure across all workspaces, geometry-independent). For every node we
/// rebuild the engine to that state by REPLAYING the shortest path that reached
/// it (the engine is stateful and not cheaply clone-able, so we replay from a
/// fresh engine), then try every enabled move, check invariants on the result,
/// and enqueue any new canonical state. A bound on visited states keeps it
/// finite even though `open` can grow the strip without limit.
private final class EngineStateSpace {
    /// Fixed width presets the `width(i)` move chooses among. Includes the
    /// edge fractions so the width-clamp paths are exercised exhaustively.
    private let widthTable: [CGFloat] = [0.25, 0.5, 1.0]
    private let screen = CGRect(x: 0, y: 32, width: 1600, height: 1000)
    private let maxVisited: Int
    private let maxDepth: Int
    /// Cap the strip size so `open` cannot expand the alphabet/state unboundedly.
    private let maxWindows: Int

    private(set) var visitedCount = 0
    private(set) var maxDepthReached = 0

    init(maxVisited: Int, maxDepth: Int, maxWindows: Int) {
        self.maxVisited = maxVisited
        self.maxDepth = maxDepth
        self.maxWindows = maxWindows
    }

    /// Build a fresh engine + sim world seeded with `initialWindows` columns,
    /// then replay `path`. Returns (engine, world, pidCounterBox) so callers can
    /// keep opening new windows with unique pids. Headless.
    private func makeEngine(initialWindows: Int, path: [EngineMove])
        -> (TeleportEngine, SimWindowWorld, () -> pid_t) {
        let world = SimWindowWorld()
        world.displays = [CGRect(x: 0, y: 0, width: 1600, height: 1032)]
        AXSource.backend = world
        let engine = TeleportEngine(screenFrame: screen)
        engine.stripDisplayFrame = CGRect(x: 0, y: 0, width: 1600, height: 1032)
        engine.gap = 12
        engine.minColumnWidth = 200
        engine.widthPresets = [0.25, 0.5, 0.75, 1.0]

        var nextPID: pid_t = 9000
        func freshPID() -> pid_t { defer { nextPID += 1 }; return nextPID }

        // Seed initial windows and adopt them.
        var infos: [AXWindowInfo] = []
        for i in 0..<initialWindows {
            let pid = freshPID()
            let el = world.addWindow(pid: pid, title: "S\(i)",
                                     frame: CGRect(x: 40 + CGFloat(i) * 320, y: 80, width: 300, height: 400))
            _ = el
            infos += world.windows(forPID: pid)
        }
        let matched = infos.map { MatchedWindow(ax: $0, cg: nil, matchScore: 100) }
        engine.adopt(matched: matched)

        for mv in path { apply(mv, engine, world, freshPID) }
        return (engine, world, freshPID)
    }

    /// Apply one move to a live engine. No-ops (e.g. moveLeft at the left edge)
    /// are allowed; the explorer relies on canonical-state dedup to fold them.
    private func apply(_ mv: EngineMove, _ engine: TeleportEngine,
                       _ world: SimWindowWorld, _ freshPID: () -> pid_t) {
        switch mv {
        case .focus(let i): engine.focus(index: i)
        case .focusNext: engine.focusNext()
        case .focusPrev: engine.focusPrevious()
        case .moveLeft: _ = engine.moveFocused(by: -1)
        case .moveRight: _ = engine.moveFocused(by: 1)
        case .width(let i): _ = engine.setFocusedWidth(fraction: widthTable[i])
        case .close:
            if engine.stripState.slots.indices.contains(engine.focusIndex) {
                // Close via the real AX path: focus the OS on it first.
                let snap = engine.workspacesSnapshot
                _ = snap
            }
            _ = engine.closeFocused()
        case .open:
            let pid = freshPID()
            _ = world.addWindow(pid: pid, title: "N\(pid)",
                                frame: CGRect(x: 40, y: 80, width: 300, height: 400))
            if let info = AXSource.windows(forPID: pid).first {
                let at = engine.stripState.slots.isEmpty ? 0 : engine.focusIndex + 1
                engine.insert(window: info, at: at)
                engine.applySpawnWidth(toSlotAt: at)
                engine.compactStrip()
                engine.focus(index: at)
            }
        case .wsDown: _ = engine.switchWorkspace(by: 1)
        case .wsUp: _ = engine.switchWorkspace(by: -1)
        case .moveWsDown: _ = engine.moveFocusedToWorkspace(by: 1)
        case .moveWsUp: _ = engine.moveFocusedToWorkspace(by: -1)
        case .fitAll: engine.fitAllColumns()
        }
    }

    /// The enabled moves from the current engine state. We always include the
    /// full alphabet (no-ops fold via dedup), but bound `open` by `maxWindows`
    /// so the state space is finite.
    private func moves(for engine: TeleportEngine) -> [EngineMove] {
        var m: [EngineMove] = [.focusNext, .focusPrev, .moveLeft, .moveRight,
                               .close, .wsDown, .wsUp, .moveWsDown, .moveWsUp, .fitAll]
        for i in widthTable.indices { m.append(.width(i)) }
        // A couple of absolute focus targets to reach interior columns fast.
        let n = engine.stripState.slots.count
        if n > 0 { m.append(.focus(0)); m.append(.focus(n - 1)) }
        // Total windows across all workspaces gates `open`.
        let total = engine.workspacesSnapshot.workspaces.reduce(0) { $0 + $1.ids.count }
        if total < maxWindows { m.append(.open) }
        return m
    }

    /// Structural invariants checked at every explored state. Returns nil if OK,
    /// else a description of the first violation. These mirror the fuzzer's
    /// invariants but are checked EXHAUSTIVELY here.
    private func invariant(_ engine: TeleportEngine) -> String? {
        let st = engine.stripState
        let snap = engine.workspacesSnapshot

        // focusIndex bounds (active workspace).
        if st.slots.isEmpty {
            if engine.focusIndex != 0 { return "focusIndex \(engine.focusIndex) on empty active strip" }
        } else if engine.focusIndex < 0 || engine.focusIndex >= st.slots.count {
            return "focusIndex \(engine.focusIndex) out of range 0..<\(st.slots.count)"
        }
        // workspace bounds.
        if snap.activeWorkspace < 0 || snap.activeWorkspace >= snap.workspaces.count {
            return "activeWorkspace \(snap.activeWorkspace) out of range 0..<\(snap.workspaces.count)"
        }
        if snap.workspaces.isEmpty { return "zero workspaces" }
        // Each workspace's stored focusIndex is in range for its size.
        for (i, w) in snap.workspaces.enumerated() {
            if w.ids.isEmpty {
                if w.focusIndex != 0 { return "ws[\(i)] focusIndex \(w.focusIndex) on empty workspace" }
            } else if w.focusIndex < 0 || w.focusIndex >= w.ids.count {
                return "ws[\(i)] focusIndex \(w.focusIndex) out of range 0..<\(w.ids.count)"
            }
        }
        // No duplicate window id across ALL workspaces (the re-adopt class bug).
        var seen = Set<UInt64>()
        for w in snap.workspaces {
            for id in w.ids {
                if !seen.insert(id).inserted { return "window id \(id) appears in two columns" }
            }
        }
        // Compactness + finite/positive geometry on the active strip.
        var x = engine.gap
        for (i, s) in st.slots.enumerated() {
            if !s.canvasX.isFinite || !s.width.isFinite { return "non-finite geometry at slot[\(i)]" }
            if s.width <= 0 { return "width <= 0 at slot[\(i)]: \(s.width)" }
            if abs(s.canvasX - x) > 0.5 { return "not compact at slot[\(i)]: \(s.canvasX) expected \(x)" }
            x += s.width + engine.gap
        }
        if !st.viewportX.isFinite || st.viewportX < -0.5 { return "viewportX bad: \(st.viewportX)" }
        // Only one trailing empty workspace may exist (niri invariant): no empty
        // workspace before a non-empty one, and at most one empty at the tail.
        let emptyTail = snap.workspaces.enumerated().filter { $0.element.ids.isEmpty }
        if emptyTail.count > 1 {
            return "more than one empty workspace: \(snap.workspaces.map { $0.ids.count })"
        }
        if let e = emptyTail.first, e.offset != snap.workspaces.count - 1,
           e.offset != snap.activeWorkspace {
            return "empty workspace at non-tail index \(e.offset): \(snap.workspaces.map { $0.ids.count })"
        }
        return nil
    }

    /// Canonical, id-independent signature of a snapshot. Window ids are
    /// process-globally unique (a freshly opened window always gets a new id),
    /// so two STRUCTURALLY identical strips would otherwise never compare equal
    /// and the BFS would treat every distinct open-count path as a new state
    /// (state explosion at depth ~2). Relabeling ids to their first-appearance
    /// order (scanning workspaces top-to-bottom, columns left-to-right) folds
    /// those together so dedup bounds the search by STRUCTURE, which is what we
    /// actually want to cover. The relabeled tuple is fully `Hashable`.
    private struct CanonicalSig: Hashable {
        let workspaces: [[Int]]      // relabeled ids per workspace
        let focusIndices: [Int]
        let activeWorkspace: Int
    }
    private func canonical(_ snap: TeleportEngine.WorkspacesSnapshot) -> CanonicalSig {
        var label: [UInt64: Int] = [:]
        var next = 0
        var ws: [[Int]] = []
        for w in snap.workspaces {
            var ids: [Int] = []
            for id in w.ids {
                if let l = label[id] { ids.append(l) }
                else { label[id] = next; ids.append(next); next += 1 }
            }
            ws.append(ids)
        }
        return CanonicalSig(workspaces: ws,
                            focusIndices: snap.workspaces.map { $0.focusIndex },
                            activeWorkspace: snap.activeWorkspace)
    }

    func explore(initialWindows: Int) -> (msg: String, path: [EngineMove])? {
        var visited = Set<CanonicalSig>()
        // Queue of shortest paths to unexplored canonical states.
        var queue: [[EngineMove]] = [[]]

        // Check the initial state itself.
        do {
            let (engine, _, _) = makeEngine(initialWindows: initialWindows, path: [])
            if let v = invariant(engine) { AXSource.backend = nil; return (v, []) }
            visited.insert(canonical(engine.workspacesSnapshot))
            AXSource.backend = nil
        }

        while !queue.isEmpty {
            if visitedCount >= maxVisited { break }
            let path = queue.removeFirst()
            if path.count >= maxDepth { continue }
            maxDepthReached = max(maxDepthReached, path.count)

            // Rebuild the engine at this path, enumerate its enabled moves.
            let (engine, _, _) = makeEngine(initialWindows: initialWindows, path: path)
            let enabled = moves(for: engine)
            AXSource.backend = nil

            for mv in enabled {
                let nextPath = path + [mv]
                // Apply on a fresh engine (engines are stateful; cheapest correct
                // approach is replay from scratch — small bounds keep this fast).
                let (e2, _, _) = makeEngine(initialWindows: initialWindows, path: nextPath)
                if let v = invariant(e2) {
                    AXSource.backend = nil
                    return ("\(v)", nextPath)
                }
                let sig = canonical(e2.workspacesSnapshot)
                AXSource.backend = nil
                if visited.insert(sig).inserted {
                    visitedCount += 1
                    queue.append(nextPath)
                    if visitedCount >= maxVisited { break }
                }
            }
        }
        return nil
    }
}

// MARK: - Exhaustive pure-function checks

private enum ExhaustivePure {
    /// ResyncPlanner.decide over EVERY (strip, ax, currentSpace) combination of
    /// a tiny id universe. A full decision-table proof of the adopt/drop policy.
    /// Returns a list of failures (empty = proven correct over the universe).
    static func resyncPlanner(universe n: Int) -> [String] {
        var fails: [String] = []
        // ids 0..<n. Each id is independently in/out of strip, ax, currentSpace.
        // To keep it exhaustive yet bounded we enumerate all subsets via bitmask.
        let full = 1 << n
        for stripMask in 0..<full {
            for axMask in 0..<full {
                for spaceMask in 0..<full {
                    let strip = (0..<n).filter { stripMask & (1 << $0) != 0 }
                    let ax = (0..<n).filter { axMask & (1 << $0) != 0 }
                    let space = Set((0..<n).filter { spaceMask & (1 << $0) != 0 })
                    let d = ResyncPlanner.decide(stripIDs: strip, axIDs: ax, currentSpaceIDs: space)
                    switch d {
                    case .frozenDifferentSpace, .skipDegraded:
                        continue
                    case .apply(let remove, let add):
                        let axSet = Set(ax), stripSet = Set(strip)
                        for r in remove where axSet.contains(r) {
                            fails.append("decide(strip=\(strip),ax=\(ax),space=\(Array(space).sorted())): removed \(r) still in AX")
                        }
                        for r in remove where !stripSet.contains(r) {
                            fails.append("decide(...): removed \(r) not in strip")
                        }
                        for a in add where stripSet.contains(a) {
                            fails.append("decide(...): re-added managed \(a)")
                        }
                        for a in add where !space.contains(a) {
                            fails.append("decide(...): added off-Space \(a)")
                        }
                        for a in add where !axSet.contains(a) {
                            fails.append("decide(...): added non-AX \(a)")
                        }
                    }
                    if fails.count > 20 { return fails }
                }
            }
        }
        return fails
    }

    /// computeParkingPoint over EVERY subset of the 4 canonical neighbor
    /// positions (left/right/above/below) x preferred side. The parked sliver
    /// (origin clamped to keep ~40px visible) must land on the STRIP's own
    /// display, never inside a neighbor.
    static func parkingCorner() -> [String] {
        var fails: [String] = []
        let strip = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let neighbors: [(name: String, rect: CGRect)] = [
            ("left",  CGRect(x: -1920, y: 0, width: 1920, height: 1080)),
            ("right", CGRect(x: 1470, y: 0, width: 1920, height: 1080)),
            ("above", CGRect(x: 0, y: -1080, width: 1470, height: 1080)),
            ("below", CGRect(x: 0, y: 956, width: 1470, height: 1080)),
        ]
        let clampMargin: CGFloat = 40
        let winW: CGFloat = 600, winH: CGFloat = 400
        for mask in 0..<(1 << neighbors.count) {
            let others = neighbors.indices.filter { mask & (1 << $0) != 0 }.map { neighbors[$0].rect }
            for side in [TeleportEngine.ParkSide.left, .right] {
                let p = TeleportEngine.computeParkingPoint(
                    stripDisplay: strip, others: others, prefer: side, margin: 4000)
                if !p.x.isFinite || !p.y.isFinite {
                    fails.append("park(side=\(side), others=\(mask)): non-finite \(p)")
                    continue
                }
                // Model the macOS clamp: a window pushed to `p` keeps ~40px on the
                // nearest display. We verify the clamped sliver intersects the
                // STRIP display and does NOT end up fully inside a neighbor.
                // The clamp pulls the origin back so the window stays >= margin
                // visible on the strip display along the pushed axis.
                let clamped = CGPoint(
                    x: min(max(p.x, strip.minX - (winW - clampMargin)), strip.maxX - clampMargin),
                    y: min(max(p.y, strip.minY - (winH - clampMargin)), strip.maxY - clampMargin))
                let sliver = CGRect(x: clamped.x, y: clamped.y, width: winW, height: winH)
                let onStrip = DisplayGeometry.overlapArea(sliver, strip)
                if onStrip <= 0 {
                    fails.append("park(side=\(side), others=\(mask)): sliver \(sliver) does not touch strip display")
                }
                // The pushed corner must be OUTSIDE every neighbor's interior
                // (the whole point: never park onto a neighbor). We allow the
                // sliver to touch the strip; check the raw push point p is not
                // inside a neighbor that blocks that direction.
                for (i, nb) in others.enumerated() {
                    if nb.contains(p) {
                        fails.append("park(side=\(side), others=\(mask)): corner \(p) lands inside neighbor #\(i) \(nb)")
                    }
                }
            }
        }
        return fails
    }

    /// DisplaySelector.pick over a curated set of specs x layouts x current
    /// index. The result must always be a valid index into the layout or nil
    /// (never out of range, never a crash).
    static func displaySelector() -> [String] {
        var fails: [String] = []
        func info(_ r: CGRect, main: Bool, primary: Bool) -> DisplaySelector.DisplayInfo {
            DisplaySelector.DisplayInfo(frame: r, isMain: main, isPrimary: primary)
        }
        let layouts: [[DisplaySelector.DisplayInfo]] = [
            [],
            [info(CGRect(x: 0, y: 0, width: 1470, height: 956), main: true, primary: true)],
            [info(CGRect(x: 0, y: 0, width: 1470, height: 956), main: true, primary: true),
             info(CGRect(x: -225, y: 956, width: 2560, height: 1440), main: false, primary: false)],
            [info(CGRect(x: 0, y: 0, width: 1470, height: 956), main: false, primary: true),
             info(CGRect(x: -225, y: 956, width: 2560, height: 1440), main: true, primary: false),
             info(CGRect(x: 3000, y: 0, width: 1000, height: 800), main: false, primary: false)],
        ]
        let specs = ["", " ", "main", "MAIN", "primary", "largest", " largest ",
                     "next", "0", "1", "2", "3", "4", "-1", "1.5", "banana", "next "]
        for layout in layouts {
            for spec in specs {
                for current in [Int?.none, .some(-1), .some(0), .some(1), .some(2), .some(99)] {
                    let r = DisplaySelector.pick(spec: spec, displays: layout, current: current)
                    if let idx = r, !layout.indices.contains(idx) {
                        fails.append("pick(spec=\"\(spec)\", n=\(layout.count), current=\(String(describing: current))) -> \(idx) OUT OF RANGE")
                    }
                }
            }
        }
        return fails
    }

    /// SemVer total-order axioms proven exhaustively over a curated set: for all
    /// a,b,c: exactly one of <,>,== holds (trichotomy); irreflexive; antisymmetric;
    /// transitive; and < is consistent with == (no a<b and a==b).
    static func semverOrder() -> [String] {
        var fails: [String] = []
        let raw = ["0.0.0", "0.0.0-dev", "0.0.1", "0.1.0", "0.1.0-rc.1", "0.1.0-rc.2",
                   "0.1.1", "0.2.0", "1.0.0", "1.0.0-alpha", "1.0.0-alpha.1",
                   "1.0.0-beta", "1.2.3", "2.0.0", "10.0.0"]
        let vs = raw.compactMap { SemVer($0) }
        guard vs.count == raw.count else { return ["SemVer failed to parse a curated version"] }
        func cmp(_ a: SemVer, _ b: SemVer) -> Int { a < b ? -1 : (b < a ? 1 : 0) }
        for a in vs {
            if a < a { fails.append("irreflexive: \(a) < \(a)") }
            for b in vs {
                // Trichotomy / antisymmetry.
                if a < b && b < a { fails.append("antisymmetry: \(a) <> \(b)") }
                let eqByCmp = cmp(a, b) == 0
                let eqByEq = (a == b)
                if eqByCmp != eqByEq { fails.append("== inconsistent with < for \(a),\(b)") }
                for c in vs {
                    if a < b && b < c && !(a < c) {
                        fails.append("transitivity: \(a)<\(b)<\(c) but !(\(a)<\(c))")
                    }
                }
            }
            if fails.count > 20 { return fails }
        }
        return fails
    }
}

// MARK: - Entry point

/// `WindowLab statespace [--max-visited N] [--max-depth D] [--max-windows W]
///                       [--seeds S] [--engine-only | --pure-only] [--replay]`
///
/// Bounded exhaustive state-space testing. The engine BFS runs from a few
/// initial window counts; the pure checks are fully exhaustive over their
/// bounded domains. Deterministic: no randomness, so a failure is the SAME
/// shortest counterexample every run. Exits non-zero on any violation.
func runStateSpace(args: [String]) -> Never {
    func intArg(_ flag: String, _ def: Int) -> Int {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return def }
        return Int(args[i + 1]) ?? def
    }
    let maxVisited = intArg("--max-visited", 6000)
    let maxDepth = intArg("--max-depth", 10)
    let maxWindows = intArg("--max-windows", 4)
    let pureOnly = args.contains("--pure-only")
    let engineOnly = args.contains("--engine-only")

    print("== ScrollWM state-space ==")
    var failures = 0

    if !pureOnly {
        print("\n-- engine BFS (maxVisited=\(maxVisited), maxDepth=\(maxDepth), maxWindows=\(maxWindows)) --")
        for initial in [1, 2, 3] {
            let ss = EngineStateSpace(maxVisited: maxVisited, maxDepth: maxDepth, maxWindows: maxWindows)
            if let (msg, path) = ss.explore(initialWindows: initial) {
                failures += 1
                print("  \u{2717} initial=\(initial): INVARIANT VIOLATION")
                print("      \(msg)")
                print("      shortest path (\(path.count) ops): \(path.map { $0.description }.joined(separator: " -> "))")
            } else {
                print("  \u{2713} initial=\(initial): \(ss.visitedCount) states, depth<=\(ss.maxDepthReached), no violation")
            }
        }
    }

    if !engineOnly {
        print("\n-- exhaustive pure checks --")
        func report(_ name: String, _ fs: [String]) {
            if fs.isEmpty { print("  \u{2713} \(name): exhaustively verified") }
            else {
                failures += fs.count
                print("  \u{2717} \(name): \(fs.count) violation(s)")
                for f in fs.prefix(5) { print("      \(f)") }
            }
        }
        report("ResyncPlanner.decide (universe=4, all subsets)", ExhaustivePure.resyncPlanner(universe: 4))
        report("computeParkingPoint (all neighbor configs x side)", ExhaustivePure.parkingCorner())
        report("DisplaySelector.pick (specs x layouts x current)", ExhaustivePure.displaySelector())
        report("SemVer total-order axioms", ExhaustivePure.semverOrder())
    }

    print("\n========================================")
    if failures == 0 {
        print("STATE-SPACE PASSED (no violations)")
        exit(0)
    } else {
        print("STATE-SPACE FAILED: \(failures) violation(s)")
        exit(1)
    }
}
