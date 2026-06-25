import Foundation
import CoreGraphics

/// Pure, AppKit-free adoption-scope policy: given the AX frames of windows the
/// strip *could* adopt this cycle, decide which ones actually belong to the
/// display the strip lives on.
///
/// ## Why this exists (the multi-display "yank" bug)
///
/// `arrange`/`resync` adopt every window on the user's CURRENT Space. With
/// `spans-displays=1` a single Mission Control Space covers BOTH monitors, so a
/// window sitting on the external display is "on the current Space" too. The
/// old behavior teleported it onto the strip's display, ripping the user's
/// external-monitor windows out from under them.
///
/// Most PaperWM/niri users expect the scrolling strip to manage ONLY its own
/// display's windows and leave every other monitor alone. `Scope.stripDisplay`
/// (the default) enforces that; `Scope.allDisplays` keeps the legacy behavior
/// for anyone who wants one strip to swallow the whole desktop.
///
/// Factored out as a pure function (like `ResyncPlanner`) so the geometry rule
/// is unit-testable with synthetic frames, without Accessibility or live
/// `NSScreen`s. Both the initial `arrange` path and the live resync/adopt paths
/// run candidates through `filter` before committing them to the strip.
enum AdoptionScope {

    /// Which displays' windows the strip is allowed to adopt.
    enum Scope: String, Equatable, CaseIterable {
        /// Manage ONLY windows whose frame best-overlaps the strip's own
        /// display. Windows on every other monitor are left untouched. Default.
        case stripDisplay
        /// Legacy: manage every current-Space window regardless of monitor, so
        /// one strip spans the whole desktop.
        case allDisplays

        /// Parse a config string, tolerating case/whitespace; nil if unknown.
        init?(configValue raw: String) {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "stripdisplay", "strip", "own", "thisdisplay": self = .stripDisplay
            case "alldisplays", "all", "legacy", "everywhere":  self = .allDisplays
            default: return nil
            }
        }
    }

    /// True if `frame` belongs to the strip's display under the given geometry.
    ///
    /// "Belongs" = the strip's display wins the best-overlap contest against
    /// every other monitor. Strip display is weighed FIRST, so an exact tie
    /// (a window split 50/50 across a bezel) is resolved IN FAVOR of the strip
    /// (`DisplayGeometry.display(bestOverlapping:)` keeps the first maximum).
    ///
    /// Safety bias: when a window overlaps NO display at all (degenerate frame,
    /// or geometry we cannot classify), it is KEPT rather than silently dropped
    /// - losing a real window the user opened is worse than over-adopting one we
    /// could not place. On a single-display setup (no `others`) everything is on
    /// the strip's display, so nothing is ever dropped.
    static func belongsToStripDisplay(_ frame: CGRect,
                                      stripDisplay: CGRect,
                                      others: [CGRect]) -> Bool {
        guard !others.isEmpty else { return true }
        let displays = [stripDisplay] + others
        guard let best = DisplayGeometry.display(bestOverlapping: frame, displays: displays) else {
            return true // overlaps nothing measurable -> keep (never lose a window)
        }
        return best == stripDisplay
    }

    /// Filter adoption candidates to the indices the strip should keep.
    ///
    /// - Parameters:
    ///   - frames: AX (top-left global) frames of the candidate windows, in
    ///             candidate order. The caller maps the returned indices back to
    ///             its own richer objects (`MatchedWindow`, `AXWindowInfo`, ...).
    ///   - stripDisplay: the strip's own display, full AX frame.
    ///   - others: every OTHER display's full AX frame (empty on single-display).
    ///   - scope: the configured policy.
    /// - Returns: indices into `frames` to adopt, in ascending order.
    static func filter(frames: [CGRect],
                       stripDisplay: CGRect,
                       others: [CGRect],
                       scope: Scope) -> [Int] {
        switch scope {
        case .allDisplays:
            return Array(frames.indices)
        case .stripDisplay:
            return frames.indices.filter {
                belongsToStripDisplay(frames[$0], stripDisplay: stripDisplay, others: others)
            }
        }
    }
}
