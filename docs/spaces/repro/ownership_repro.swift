// Track 2 (STRIP <-> SPACE OWNERSHIP) headless repro.
//
// Standalone, self-contained Swift script. It VENDORS the exact decision logic
// from production so it can be run with `swift docs/spaces/repro/ownership_repro.swift`
// without an Accessibility permission, a window, or the rest of the build. The
// vendored copies below are byte-faithful to the cited sources so the trace
// cannot drift from what ScrollWM actually does:
//
//   - decide(...)            <- Sources/WindowLab/ResyncPlanner.swift:48-84
//   - stripIsOnCurrentSpace  <- Sources/WindowLab/LifecycleMonitor.swift:482-494
//   - the applyResync add/remove plumbing it feeds  <- LifecycleMonitor.swift:193-322
//
// The goal is to PROVE, scenario by scenario, what today's "one strip per
// display, no Space tag" model does when the user moves between native Spaces.
//
// Run:  swift docs/spaces/repro/ownership_repro.swift

import Foundation

// ---------------------------------------------------------------------------
// VENDORED: ResyncPlanner.decide  (ResyncPlanner.swift:48-84, verbatim)
// ---------------------------------------------------------------------------

enum Decision: Equatable {
    case frozenDifferentSpace
    case skipDegraded
    case apply(remove: [Int], add: [Int])
}

func decide(stripIDs: [Int], axIDs: [Int], currentSpaceIDs: Set<Int>) -> Decision {
    let axSet = Set(axIDs)
    let stripPresentInAX = stripIDs.filter { axSet.contains($0) }
    if !stripPresentInAX.isEmpty
        && !stripPresentInAX.contains(where: { currentSpaceIDs.contains($0) }) {
        return .frozenDifferentSpace
    }
    let missing = stripIDs.reduce(into: 0) { count, id in
        if !axSet.contains(id) { count += 1 }
    }
    if stripIDs.count >= 4 && missing * 2 > stripIDs.count {
        return .skipDegraded
    }
    let stripSet = Set(stripIDs)
    let remove = stripIDs.filter { !axSet.contains($0) }
    let add = axIDs.filter { !stripSet.contains($0) && currentSpaceIDs.contains($0) }
    return .apply(remove: remove, add: add)
}

// ---------------------------------------------------------------------------
// A tiny world model. Each window has a stable id, lives on exactly one native
// Space, and may or may not be in the AX enumeration (closed => not in AX).
// The "current Space" is what the user is viewing; the WindowServer on-screen
// list (CGWindowSource.listWindows(onscreenOnly:true)) = windows on that Space.
// This mirrors the real pipeline in LifecycleMonitor.applyResync exactly.
// ---------------------------------------------------------------------------

struct Win { let id: Int; var space: Int; var closed = false }

final class World {
    var wins: [Win]
    var currentSpace: Int
    init(_ wins: [Win], currentSpace: Int) { self.wins = wins; self.currentSpace = currentSpace }

    /// AX enumerates windows across ALL Spaces; a closed window drops out.
    var axIDs: [Int] { wins.filter { !$0.closed }.map { $0.id } }
    /// WindowServer on-screen list = current-Space, non-closed windows.
    var currentSpaceIDs: Set<Int> { Set(wins.filter { !$0.closed && $0.space == currentSpace }.map { $0.id }) }
}

/// A strip: an ordered list of managed window ids (one display, no Space tag).
final class Strip {
    var ids: [Int] = []
    /// "viewport" abstraction: the focused index, so we can show the strip
    /// resumes the SAME layout/focus on return.
    var focus: Int = 0
    var managing: Bool { !ids.isEmpty }
}

/// One reconcile cycle = exactly LifecycleMonitor.applyResync's shape.
@discardableResult
func reconcile(_ strip: Strip, _ world: World, label: String) -> Decision {
    let axIDs = world.axIDs
    let space = world.currentSpaceIDs
    let d = decide(stripIDs: strip.ids, axIDs: axIDs, currentSpaceIDs: space)
    switch d {
    case .frozenDifferentSpace, .skipDegraded:
        // applyResync returns early: NO add, NO remove. Strip is inert.
        break
    case .apply(let remove, let add):
        strip.ids.removeAll { remove.contains($0) }
        // Additions insert to the right of focus and focus the newest
        // (applyResync lines 259-276).
        for a in add {
            let at = strip.ids.isEmpty ? 0 : strip.focus + 1
            strip.ids.insert(a, at: min(at, strip.ids.count))
            strip.focus = at
        }
    }
    print("  [\(label)] current=\(d)  strip=\(strip.ids) focus=\(strip.focus)")
    return d
}

func banner(_ s: String) { print("\n=== \(s) ===") }

var failures = 0
func expect(_ name: String, _ cond: Bool) {
    print("  \(cond ? "PASS" : "FAIL"): \(name)")
    if !cond { failures += 1 }
}

// ===========================================================================
// SCENARIO (a): arrange on Space A, switch to EMPTY Space B, open a window.
// ===========================================================================
banner("(a) arrange on A, switch to empty B, open a window there")
do {
    // Two managed windows on Space A. User is on A.
    let world = World([Win(id: 1, space: 0), Win(id: 2, space: 0)], currentSpace: 0)
    let strip = Strip(); strip.ids = [1, 2]; strip.focus = 1
    reconcile(strip, world, label: "on A, steady")

    // User switches to Space B (empty). The strip's windows are still in AX
    // (not closed) but none are on B.
    world.currentSpace = 1
    let dB = reconcile(strip, world, label: "switched to empty B")
    expect("on empty B the strip FREEZES (frozenDifferentSpace)", dB == .frozenDifferentSpace)
    expect("strip layout is untouched while frozen", strip.ids == [1, 2])

    // User opens a NEW window on B (id 3, space 1).
    world.wins.append(Win(id: 3, space: 1))
    let dOpen = reconcile(strip, world, label: "opened window 3 on B")
    // CRUCIAL: window 3 is on the current Space (B). The strip's own windows
    // are NOT on B. decide() still freezes because stripPresentInAX (1,2) has
    // none on the current Space -> early-return BEFORE computing `add`.
    expect("new window on B is NOT adopted (strip still frozen)", dOpen == .frozenDifferentSpace)
    expect("window 3 floats unmanaged on B", !strip.ids.contains(3))
    print("  >> SURPRISE: on a non-empty-for-the-strip Space, a brand-new window")
    print("     opened by the user is left UNMANAGED until they return to A and")
    print("     re-arrange. ScrollWM does nothing on B at all.")
}

// ===========================================================================
// SCENARIO (b): switch to a Space B that ALREADY has windows. Adopted or frozen?
// ===========================================================================
banner("(b) switch to a Space B that already has its own windows")
do {
    let world = World([Win(id: 1, space: 0), Win(id: 2, space: 0),
                       Win(id: 10, space: 1), Win(id: 11, space: 1)], currentSpace: 0)
    let strip = Strip(); strip.ids = [1, 2]; strip.focus = 0
    reconcile(strip, world, label: "on A, steady")

    world.currentSpace = 1
    let dB = reconcile(strip, world, label: "switched to populated B")
    expect("strip FREEZES on B even though B has adoptable windows", dB == .frozenDifferentSpace)
    expect("B's own windows 10,11 are NOT adopted", !strip.ids.contains(10) && !strip.ids.contains(11))
    print("  >> B's windows are NEVER tiled. The strip is inert; B behaves like")
    print("     an unmanaged desktop. There is no second strip for B.")
}

// ===========================================================================
// SCENARIO (c): return to Space A. Does the strip resume cleanly?
// ===========================================================================
banner("(c) return to Space A after freezing on B")
do {
    let world = World([Win(id: 1, space: 0), Win(id: 2, space: 0), Win(id: 3, space: 1)], currentSpace: 0)
    let strip = Strip(); strip.ids = [1, 2]; strip.focus = 1
    reconcile(strip, world, label: "on A, steady")
    world.currentSpace = 1
    reconcile(strip, world, label: "frozen on B")
    let layoutBefore = strip.ids, focusBefore = strip.focus
    world.currentSpace = 0
    let dA = reconcile(strip, world, label: "back on A")
    if case .apply(let r, let a) = dA {
        expect("on return the strip THAWS (apply)", true)
        expect("nothing removed on return", r.isEmpty)
        expect("nothing spuriously added on return", a.isEmpty)
    } else {
        expect("on return the strip THAWS (apply)", false)
    }
    expect("strip layout identical to pre-freeze", strip.ids == layoutBefore)
    expect("focus identical to pre-freeze", strip.focus == focusBefore)
    print("  >> CLEAN resume: same columns, same order, same focus. The strip")
    print("     'froze/thawed' rather than rebuilding. (Viewport correctness on")
    print("     return depends on the engine re-teleporting; see doc note.)")
}

// ===========================================================================
// SCENARIO (d): move a managed window from A to another Space (Mission Control
// / drag to a Space thumbnail). Kept or dropped?
// ===========================================================================
banner("(d) move managed window 2 from A to Space B, user stays on A")
do {
    let world = World([Win(id: 1, space: 0), Win(id: 2, space: 0)], currentSpace: 0)
    let strip = Strip(); strip.ids = [1, 2]; strip.focus = 1
    reconcile(strip, world, label: "on A, steady")

    // Window 2 is dragged to Space B. It STILL exists in AX (not closed); it is
    // simply no longer on the current Space's on-screen list. User stays on A.
    world.wins[1].space = 1
    let d = reconcile(strip, world, label: "window 2 moved to B")
    // window 1 is still on A so the strip is NOT frozen. decide() computes:
    //   remove = ids AX no longer reports = []  (2 still in AX)
    //   add    = current-Space windows not managed = []  (1 already managed)
    // => window 2 is KEPT in the strip even though it now lives on B.
    expect("strip is NOT frozen (window 1 still on A)", d != .frozenDifferentSpace)
    expect("moved window 2 is KEPT in the strip", strip.ids.contains(2))
    print("  >> STRANDED COLUMN: window 2 now lives on Space B but the strip on A")
    print("     still owns it. The engine will keep teleporting an off-current-")
    print("     Space window. Focusing it (Cmd+L onto column 2) calls")
    print("     activateApp -> macOS yanks the user to Space B. This is the")
    print("     'never teleport the user to another Space' invariant at risk.")
    // Now: user closes window 2 while it is on B. It drops from AX entirely.
    world.wins[1].closed = true
    let d2 = reconcile(strip, world, label: "window 2 closed on B")
    expect("closing the moved window finally removes the column", !strip.ids.contains(2))
}

// ===========================================================================
// EMERGENT (e): the "all strip windows moved away" full-freeze trap.
// If EVERY managed window is dragged off Space A, the strip freezes on A even
// though the user is still on A, because stripPresentInAX has none on A.
// ===========================================================================
banner("(e) ALL managed windows dragged off A while user stays on A")
do {
    let world = World([Win(id: 1, space: 0), Win(id: 2, space: 0)], currentSpace: 0)
    let strip = Strip(); strip.ids = [1, 2]; strip.focus = 0
    reconcile(strip, world, label: "on A, steady")
    world.wins[0].space = 1
    world.wins[1].space = 1   // both now on B; user still on A
    let d = reconcile(strip, world, label: "both moved to B, user on A")
    expect("strip freezes even though the user never left A", d == .frozenDifferentSpace)
    print("  >> The freeze rule keys off WINDOW location, not the user's Space.")
    print("     With every window gone to B, ScrollWM treats A as 'a different")
    print("     Space' and goes inert on a Space the user is actually viewing.")
    // And if the user now opens a fresh window on A, it is ignored (same trap
    // as scenario (a)).
    world.wins.append(Win(id: 5, space: 0))
    let d2 = reconcile(strip, world, label: "open new window 5 on A")
    expect("a new window on A is ALSO ignored while frozen", d2 == .frozenDifferentSpace && !strip.ids.contains(5))
}

print("\n--------------------------------------------------------------")
print(failures == 0 ? "ALL OWNERSHIP REPRO CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
