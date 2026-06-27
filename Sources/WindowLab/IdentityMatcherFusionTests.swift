import Foundation
import ApplicationServices
import CoreGraphics

/// GATE-C: PURE proof tests for the `IdentityMatcher` AX<->CG fusion that decides
/// whether an AX window is "on the current Space" (`cg != nil`). When the fusion
/// fails, the window is treated as off-Space and is SILENTLY DROPPED from
/// `arrange`/`applyResync`/`fastAdopt` (never tiled) AND from
/// `FloatingWindows.compute` (not even surfaced in the floating menu): it
/// vanishes from the manager entirely.
///
/// These tests feed synthetic AX+CG arrays into `IdentityMatcher.match` and
/// assert the DROP, documenting the real failure modes behind the live report
/// ("windows still floating it never caught"). They are deliberately PASSING
/// assertions of the CURRENT (buggy) behavior so they double as a regression
/// guard and an executable spec: the `// BUG:` checks capture exactly what a fix
/// must flip. Wired into `WindowLab unittest` via `StripOpsTests.run()`.
///
/// THE ROOT AMPLIFIER: `score()` grants a title bonus only when BOTH `ax.title`
/// and `cg.title` are present. Since macOS 10.15, `CGWindowListCopyWindowInfo`
/// returns `kCGWindowName` (the title) only with the *Screen Recording*
/// permission, which ScrollWM intentionally never requests (Accessibility-only
/// contract). So in production `cg.title == nil` for every other app's window
/// and the title term can NEVER fire. Fusion is therefore frame-only:
///
///   same PID                         -> 40
///   + exact frame  (all deltas <= 1) -> +35 = 75  (>=50 match)
///   + close frame  (all deltas <= 8) -> +20 = 60  (>=50 match)
///   + same size, moved (pos differs) -> + 8 = 48  (< 50 DROP)
///   + moved AND resized              -> + 0 = 40  (< 50 DROP)
///
/// minimumScore = 50, so ANY position discrepancy > 8px between the AX snapshot
/// and the CG snapshot (taken in separate syscalls, a frame or more apart) drops
/// a real, current-Space window. This is exactly what happens during window
/// CHURN: while the engine is actively parking/teleporting Ghostty windows to
/// off-screen strip X (the live data showed x=-854, x=1880), AX reads one X and
/// the WindowServer reports another -> > 8px -> score <= 48 -> UNMATCHED.
enum IdentityMatcherFusionTests {

    // MARK: - synthetic builders

    private static func ax(pid: pid_t, frame: CGRect, title: String?) -> AXWindowInfo {
        AXWindowInfo(
            pid: pid,
            appName: "App\(pid)",
            element: AXUIElementCreateApplication(pid),
            title: title,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            frame: frame,
            isMinimized: false,
            isFullscreen: false
        )
    }

    /// Models a CG row. `title: nil` is the PRODUCTION default (no Screen
    /// Recording permission); pass a string only to demonstrate the bonus that
    /// production can never actually receive.
    private static func cg(pid: pid_t, bounds: CGRect, title: String? = nil, id: CGWindowID = 1) -> CGWindowInfo {
        CGWindowInfo(
            windowID: id,
            ownerPID: pid,
            ownerName: "App\(pid)",
            title: title,
            bounds: bounds,
            layer: 0,
            alpha: 1.0,
            isOnscreen: true,
            memoryUsage: 0
        )
    }

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        let pid: pid_t = 7777
        let base = CGRect(x: 0, y: 0, width: 800, height: 600)

        // ============================================================
        // SCORE MATH (the quantified core of the gate)
        // ============================================================
        let exactScore = IdentityMatcher.score(ax: ax(pid: pid, frame: base, title: "~"),
                                                cg: cg(pid: pid, bounds: base))
        check("score: exact frame, no CG title -> 75 (matches)", exactScore == 75)

        let closeScore = IdentityMatcher.score(
            ax: ax(pid: pid, frame: base, title: "~"),
            cg: cg(pid: pid, bounds: base.offsetBy(dx: 6, dy: 0))) // <= 8px
        check("score: close frame (6px), no CG title -> 60 (matches)", closeScore == 60)

        let movedSameSize = IdentityMatcher.score(
            ax: ax(pid: pid, frame: base, title: "~"),
            cg: cg(pid: pid, bounds: base.offsetBy(dx: 40, dy: 0))) // > 8px, same size
        check("score: same-size move (40px), no CG title -> 48 (< 50: DROP)", movedSameSize == 48)

        let movedResized = IdentityMatcher.score(
            ax: ax(pid: pid, frame: base, title: "~"),
            cg: cg(pid: pid, bounds: CGRect(x: 40, y: 0, width: 900, height: 600)))
        check("score: moved AND resized, no CG title -> 40 (< 50: DROP)", movedResized == 40)

        let diffPID = IdentityMatcher.score(
            ax: ax(pid: pid, frame: base, title: "~"),
            cg: cg(pid: pid + 1, bounds: base))
        check("score: different PID -> 0 (PID gate)", diffPID == 0)

        // ============================================================
        // ROOT AMPLIFIER: the title bonus is what WOULD have saved a churned
        // window, but production never has CG titles (no Screen Recording), so
        // the SAME 40px move flips from match (68) to drop (48) purely because
        // cg.title is nil.
        // ============================================================
        let movedWithTitle = IdentityMatcher.score(
            ax: ax(pid: pid, frame: base, title: "~"),
            cg: cg(pid: pid, bounds: base.offsetBy(dx: 40, dy: 0), title: "~"))
        check("root: WITH a CG title the same 40px move scores 68 (would match)", movedWithTitle == 68)
        check("root: dropping ONLY the CG title (production) turns 68 -> 48 (drop)",
              movedWithTitle >= IdentityMatcher.minimumScore && movedSameSize < IdentityMatcher.minimumScore)

        // ============================================================
        // FAILURE MODE C (P0): a single churned window is UNMATCHED -> cg==nil.
        // This is the Ghostty-parking case: AX frame and CG frame disagree by
        // > 8px while the engine is mid-teleport. The window is real and on the
        // current Space, yet match() returns cg == nil.
        // ============================================================
        let churnMatched = IdentityMatcher.match(
            axWindows: [ax(pid: pid, frame: base, title: "~")],
            cgWindows: [cg(pid: pid, bounds: base.offsetBy(dx: 40, dy: 0))]) // production: no title
        check("BUG: churned same-size move -> UNMATCHED (cg == nil), dropped as off-Space",
              churnMatched.count == 1 && churnMatched[0].cg == nil)

        // Positive control: when the snapshots agree (<= 8px), it DOES match, so
        // the drop is specifically a churn/race artifact, not a blanket failure.
        let calmMatched = IdentityMatcher.match(
            axWindows: [ax(pid: pid, frame: base, title: "~")],
            cgWindows: [cg(pid: pid, bounds: base.offsetBy(dx: 6, dy: 0))])
        check("control: settled window (<=8px) DOES match (cg != nil)",
              calmMatched.count == 1 && calmMatched[0].cg != nil)

        // ============================================================
        // FAILURE MODE F (P0 amplifier): a fusion-dropped window is NOT even
        // surfaced as floating. `FloatingWindows.compute` gates on cg != nil, so
        // the churned window is invisible to BOTH the strip and the floating
        // menu -- the manager loses it entirely.
        // ============================================================
        let churnAX = ax(pid: pid, frame: base, title: "~")
        let floating = FloatingWindows.compute(
            axWindows: [churnAX],
            cgWindows: [cg(pid: pid, bounds: base.offsetBy(dx: 40, dy: 0))],
            managed: [],
            selfPID: 1)
        check("BUG: fusion-dropped window is ALSO absent from the floating list (invisible)",
              floating.isEmpty)

        // ============================================================
        // FAILURE MODE E (P1): greedy "each CG used once" strands a real window
        // when an app has MORE current-Space AX windows than visible CG rows
        // with the same frame+PID (identical-frame stacking / a coalesced or
        // lagged CG snapshot). Two real windows, one CG row -> exactly one is
        // unmatched and silently dropped, even though both are on this Space.
        // ============================================================
        let dupPID: pid_t = 8888
        let dupMatched = IdentityMatcher.match(
            axWindows: [
                ax(pid: dupPID, frame: base, title: "~"),
                ax(pid: dupPID, frame: base, title: "~"),
            ],
            cgWindows: [cg(pid: dupPID, bounds: base, title: "~", id: 42)])
        let dupUnmatched = dupMatched.filter { $0.cg == nil }.count
        check("BUG: 2 identical same-PID AX windows + 1 CG row -> exactly 1 stranded (cg == nil)",
              dupUnmatched == 1)
        check("greedy: the winner kept the high (exact) score 95",
              dupMatched.contains { $0.cg != nil && $0.matchScore == 95 })

        // ============================================================
        // FAILURE MODE H (interaction): a CG row whose on-screen sliver is
        // clamped below the looksManageable floor (w < 64 / h < 64) is filtered
        // out as a candidate, so its AX window can never fuse and is dropped --
        // even though AX reports the full off-screen frame.
        // ============================================================
        let slimPID: pid_t = 9999
        let slimMatched = IdentityMatcher.match(
            axWindows: [ax(pid: slimPID, frame: CGRect(x: 1880, y: 0, width: 800, height: 600), title: "~")],
            cgWindows: [cg(pid: slimPID, bounds: CGRect(x: 1918, y: 0, width: 2, height: 600))]) // parked sliver
        check("BUG: parked-sliver CG (<64px wide) filtered by looksManageable -> AX dropped (cg == nil)",
              slimMatched.count == 1 && slimMatched[0].cg == nil)

        print("\n[unittest] IdentityMatcher fusion (GATE-C): \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
