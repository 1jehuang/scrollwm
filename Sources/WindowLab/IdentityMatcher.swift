import Foundation
import CoreGraphics

/// A fused window identity: one logical window seen through both AX and CG.
struct MatchedWindow {
    let ax: AXWindowInfo
    let cg: CGWindowInfo?
    let matchScore: Int
}

/// Scores and matches AX windows against CG windows.
///
/// There is no public join key between AXUIElement and CGWindowID, so we fuse
/// on PID + frame + title with a scoring model. Ambiguous matches are left
/// unmatched rather than merged wrongly.
enum IdentityMatcher {
    static let minimumScore = 50

    static func score(ax: AXWindowInfo, cg: CGWindowInfo) -> Int {
        guard ax.pid == cg.ownerPID else { return 0 }
        var score = 40 // same PID

        // Frame match (AX and CG both use global top-left-origin coordinates).
        let dx = abs(ax.frame.origin.x - cg.bounds.origin.x)
        let dy = abs(ax.frame.origin.y - cg.bounds.origin.y)
        let dw = abs(ax.frame.width - cg.bounds.width)
        let dh = abs(ax.frame.height - cg.bounds.height)

        if dx <= 1, dy <= 1, dw <= 1, dh <= 1 {
            score += 35 // exact frame
        } else if dx <= 8, dy <= 8, dw <= 8, dh <= 8 {
            score += 20 // close frame
        } else if dw <= 1, dh <= 1 {
            score += 8 // same size, moved (race between snapshots)
        }

        // Title match. CG titles need Screen Recording permission; treat as bonus.
        if let axTitle = ax.title, let cgTitle = cg.title, !axTitle.isEmpty {
            if axTitle == cgTitle { score += 20 }
            else if cgTitle.contains(axTitle) || axTitle.contains(cgTitle) { score += 10 }
        }

        return score
    }

    /// Frame "distance" between an AX window and a CG row, used to order the
    /// motion-invariant fallback (pass 2). Manhattan over origin + size, so the
    /// closest-looking CG row claims each surplus AX window. Only meaningful
    /// within a single PID (the caller already gates on PID).
    static func frameCost(ax: AXWindowInfo, cg: CGWindowInfo) -> CGFloat {
        abs(ax.frame.origin.x - cg.bounds.origin.x)
            + abs(ax.frame.origin.y - cg.bounds.origin.y)
            + abs(ax.frame.width - cg.bounds.width)
            + abs(ax.frame.height - cg.bounds.height)
    }

    /// Fuse AX windows with CG rows in two passes:
    ///
    /// 1. **High-confidence frame match** (the original behavior): every
    ///    `(ax, cg)` pair scoring `>= minimumScore` is collected, sorted
    ///    best-first, and greedily assigned (each CG row used once). This still
    ///    owns exact/close-frame matches, which is what disambiguates an app's
    ///    many windows when the snapshots agree.
    ///
    /// 2. **Motion-invariant per-PID fallback** (the GATE-C fix): the binary
    ///    "is this AX window on the current Space?" question (`cg != nil`) must
    ///    NOT hinge on a same-instant frame agreement. CG titles need Screen
    ///    Recording (never granted), so pass 1 is frame-only and ANY > 8px drift
    ///    between the two separate AX/CG syscalls during churn (windows being
    ///    parked/teleported) dropped a real, current-Space window. So for every
    ///    AX window still unmatched, we consider its SAME-PID still-unconsumed CG
    ///    rows and assign them by ascending `frameCost`, regardless of the score
    ///    threshold. A CG row only ever exists for a CURRENT-Space window (the
    ///    on-screen list is current-Space only), so this never fabricates Space
    ///    membership for an off-Space window - it just lets a moved-but-present
    ///    window claim its app's row, and lets surplus same-PID windows pair up
    ///    instead of being stranded by the global greedy race (fixes C1/C4/C7).
    static func match(axWindows: [AXWindowInfo], cgWindows: [CGWindowInfo]) -> [MatchedWindow] {
        let candidates = cgWindows.filter { $0.looksManageable }

        var axTaken = Set<Int>()
        var cgTaken = Set<Int>()
        var assignment: [Int: (cgIdx: Int, score: Int)] = [:]

        // --- Pass 1: high-confidence frame match (best score first) ---
        var pairs: [(axIdx: Int, cgIdx: Int, score: Int)] = []
        for (ai, ax) in axWindows.enumerated() {
            for (ci, cg) in candidates.enumerated() {
                let s = score(ax: ax, cg: cg)
                if s >= minimumScore {
                    pairs.append((ai, ci, s))
                }
            }
        }
        // Stable order: score desc, then ax/cg index so ties are deterministic.
        pairs.sort { $0.score != $1.score ? $0.score > $1.score
                     : ($0.axIdx != $1.axIdx ? $0.axIdx < $1.axIdx : $0.cgIdx < $1.cgIdx) }
        for pair in pairs where !axTaken.contains(pair.axIdx) && !cgTaken.contains(pair.cgIdx) {
            axTaken.insert(pair.axIdx)
            cgTaken.insert(pair.cgIdx)
            assignment[pair.axIdx] = (pair.cgIdx, pair.score)
        }

        // --- Pass 2: motion-invariant per-PID fallback ---
        // All same-PID (still-unmatched AX, still-unconsumed CG) pairs, ordered
        // by frame proximity so the most-likely-same window claims each row.
        var fallback: [(axIdx: Int, cgIdx: Int, cost: CGFloat, score: Int)] = []
        for (ai, ax) in axWindows.enumerated() where !axTaken.contains(ai) {
            for (ci, cg) in candidates.enumerated()
            where !cgTaken.contains(ci) && ax.pid == cg.ownerPID {
                fallback.append((ai, ci, frameCost(ax: ax, cg: cg), score(ax: ax, cg: cg)))
            }
        }
        fallback.sort { $0.cost != $1.cost ? $0.cost < $1.cost
                        : ($0.axIdx != $1.axIdx ? $0.axIdx < $1.axIdx : $0.cgIdx < $1.cgIdx) }
        for pair in fallback where !axTaken.contains(pair.axIdx) && !cgTaken.contains(pair.cgIdx) {
            axTaken.insert(pair.axIdx)
            cgTaken.insert(pair.cgIdx)
            assignment[pair.axIdx] = (pair.cgIdx, pair.score)
        }

        return axWindows.enumerated().map { (ai, ax) in
            if let hit = assignment[ai] {
                return MatchedWindow(ax: ax, cg: candidates[hit.cgIdx], matchScore: hit.score)
            }
            return MatchedWindow(ax: ax, cg: nil, matchScore: 0)
        }
    }
}
