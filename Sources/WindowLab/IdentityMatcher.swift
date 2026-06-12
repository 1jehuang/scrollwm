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

    /// Greedy best-score assignment: each CG window used at most once.
    static func match(axWindows: [AXWindowInfo], cgWindows: [CGWindowInfo]) -> [MatchedWindow] {
        let candidates = cgWindows.filter { $0.looksManageable }

        // All (axIndex, cgIndex, score) pairs above threshold, best first.
        var pairs: [(axIdx: Int, cgIdx: Int, score: Int)] = []
        for (ai, ax) in axWindows.enumerated() {
            for (ci, cg) in candidates.enumerated() {
                let s = score(ax: ax, cg: cg)
                if s >= minimumScore {
                    pairs.append((ai, ci, s))
                }
            }
        }
        pairs.sort { $0.score > $1.score }

        var axTaken = Set<Int>()
        var cgTaken = Set<Int>()
        var assignment: [Int: (cgIdx: Int, score: Int)] = [:]

        for pair in pairs where !axTaken.contains(pair.axIdx) && !cgTaken.contains(pair.cgIdx) {
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
