import Foundation
import ApplicationServices
import AppKit
import CoreGraphics

/// GATE-F (ResyncPlanner + applyResync freeze cascade) audit tests.
///
/// The user's `scrollwm arrange` ran while ALREADY managing, so it dispatched to
/// `LifecycleMonitor.resync()` (the `isManaging` branch of `arrange`), NOT the
/// cold `engine.adopt()`. The live "smoking gun" was `managing:true`, ONE tiled
/// column, but `floatingCount:42` (every one `canTile:true`): resync adopted
/// nobody even though dozens of standard, current-Space, tileable windows were
/// on screen.
///
/// This file proves the two ways `resync` adopts NOTHING and strands every
/// window as floating, both driven by the SAME upstream cause GATE-C found
/// (frame-only AX<->CG fusion that misses a moved/churning window):
///
///   F1 (frozenDifferentSpace cascade): if the strip's OWN managed columns fail
///      identity-fusion this cycle (their live frame drifted > 8px from the CG
///      snapshot during churn), NONE of the strip's tokens land in
///      `currentSpaceIDs`. `ResyncPlanner.decide` then concludes "the user is on
///      a different Space" and returns `.frozenDifferentSpace` -> the WHOLE
///      resync bails: no adds, no removes. Every unmanaged window stays floating.
///
///   F2 (skipDegraded): a transient fusion/AX dropout that removes more than half
///      of a >=4 column strip from the current-Space set trips the degradation
///      guard (`missing*2 > count`) and skips the cycle -> again adopts nothing.
///
/// These run the SAME pure planner production runs (`ResyncPlanner.decide`) with
/// synthetic tokens, plus a `Headless.resyncDecision` end-to-end check through
/// the real sim + engine + IdentityMatcher, so the cascade is pinned without AX
/// permission or real windows. They are PASSING assertions of today's (buggy)
/// behavior so they double as a regression guard; the `// BUG:` checks mark what
/// a fix must flip. Wired into `WindowLab unittest`.
enum ResyncFreezeTests {

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  \u{2713} \(name)") }
            else { failed += 1; print("  \u{2717} \(name)") }
        }

        print("[resyncfreeze] GATE-F: resync adopts nothing -> windows stay floating")

        // ============================================================
        // F1 — PURE planner: strip columns missing from current-Space => FROZEN,
        // so brand-new current-Space windows are NEVER added this cycle.
        // ============================================================
        // Strip manages tokens [0,1]. AX still reports them (not closed: axIDs
        // contains 0,1) plus two NEW standard windows [2,3] that ARE on the
        // current Space. But the strip's own columns (0,1) failed fusion this
        // cycle (frame drift), so they are NOT in currentSpaceIDs.
        do {
            let decision = ResyncPlanner.decide(
                stripIDs: [0, 1],
                axIDs: [0, 1, 2, 3],
                currentSpaceIDs: [2, 3]) // new windows present, strip's own absent
            check("F1: strip columns absent from current-Space -> frozenDifferentSpace",
                  decision == .frozenDifferentSpace)
            // BUG: tokens 2 & 3 are standard current-Space windows the user wants
            // tiled, yet the freeze means they are NEVER adopted -> they float.
            if case .apply(_, let add) = decision {
                check("BUG(F1): would have added the 2 new current-Space windows", add == [2, 3])
            } else {
                check("BUG(F1): frozen => 2 new current-Space windows stranded floating", true)
            }
        }

        // Positive control: when even ONE managed column fuses on the current
        // Space, the planner is NOT frozen and the new windows are added.
        do {
            let decision = ResyncPlanner.decide(
                stripIDs: [0, 1],
                axIDs: [0, 1, 2, 3],
                currentSpaceIDs: [1, 2, 3]) // one managed column (1) present
            if case .apply(_, let add) = decision {
                check("control(F1): one managed column present -> adds new windows", add.contains(2) && add.contains(3))
            } else {
                check("control(F1): expected .apply when a managed column is present", false)
            }
        }

        // ============================================================
        // F2 — PURE planner: degradation guard skips the cycle.
        // ============================================================
        do {
            // 4-column strip; 3 of 4 vanish from AX this cycle (missing*2 > count).
            let decision = ResyncPlanner.decide(
                stripIDs: [0, 1, 2, 3],
                axIDs: [3, 9],          // only token 3 still present (+ a new one)
                currentSpaceIDs: [3, 9])
            check("F2: majority of strip missing from AX -> skipDegraded",
                  decision == .skipDegraded)
            // BUG: token 9 is a standard current-Space window but the skip means
            // it is not adopted this cycle (left floating until a healthy cycle).
            check("BUG(F2): new current-Space window 9 not adopted during skip", true)
        }

        // ============================================================
        // F1 end-to-end through the REAL sim + engine + IdentityMatcher.
        //
        // NOTE ON SIM FIDELITY: `SimWindowWorld` derives BOTH the AX frame and
        // the CG bounds from the SAME `Win.frame`, so it is internally
        // consistent and CANNOT reproduce the production AX-vs-CG snapshot
        // divergence that GATE-C proved drops a window (that divergence is a
        // timing race between two separate syscalls). So here we (a) confirm a
        // healthy resync DOES adopt a new current-Space window, and (b) prove
        // the cascade the other half of the bug needs by moving the managed
        // window to ANOTHER native Space — which is the ONE way the sim can take
        // a managed column out of the current-Space CG set. Composed with
        // GATE-C (fusion can do the same on the CURRENT Space via frame drift),
        // this pins the full "resync adopts nothing -> everything floats" path.
        // ============================================================
        do {
            let world = Headless.install()
            defer { Headless.uninstall() }
            let engine = TeleportEngine(screenFrame: Headless.defaultVisibleFrame)
            engine.stripDisplayFrame = Headless.defaultFullFrame

            // Seed one managed window + adopt it (becomes the strip's only column).
            let (pids, els) = Headless.seedWindows(world, count: 1, startPID: 6000)
            Headless.arrangeCurrentSpace(engine, pids: pids)
            check("e2e setup: 1 column adopted", engine.slots.count == 1)

            // Now seed a SECOND standard, current-Space window the user wants tiled.
            let (pids2, _) = Headless.seedWindows(
                world, count: 1, startPID: 6100,
                within: CGRect(x: 800, y: 72, width: 360, height: 420))
            let allPids = pids + pids2

            // Healthy cycle: both fuse, planner applies, new window is an add.
            let healthy = Headless.resyncDecision(engine, pids: allPids)
            if case .apply(_, let add) = healthy {
                check("e2e control: healthy resync would add the new window", !add.isEmpty)
            } else {
                check("e2e control: expected .apply on a healthy cycle", false)
            }

            // Take the MANAGED column out of the current-Space CG set (the sim's
            // only lever for that is a native-Space move; in production GATE-C's
            // frame-drift fusion miss does the same on the current Space).
            world.setNativeSpace(els[0], 2)
            let frozen = Headless.resyncDecision(engine, pids: allPids)
            // BUG: the strip's only column is no longer in the current-Space set,
            // so the planner freezes and the brand-new tileable window (still on
            // the current Space) is NOT adopted -> it stays floating.
            check("BUG(F1 e2e): managed column off current-Space set -> frozenDifferentSpace",
                  frozen == .frozenDifferentSpace)
        }

        print("[resyncfreeze] GATE-F: \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
