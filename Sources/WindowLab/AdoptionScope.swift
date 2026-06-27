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

    /// True if a window the strip ALREADY manages has been dragged onto a
    /// DIFFERENT physical display by the user and should therefore be EVICTED
    /// (released back to the desktop, left where the user put it) instead of
    /// teleported back onto the strip.
    ///
    /// ## Why this exists (the multi-display "yank-back" bug)
    ///
    /// With one Mission Control Space spanning both monitors, a managed strip
    /// column the user drags onto the external display still EXISTS in AX and is
    /// still on the current Space, so `removeSlots` (which only drops windows
    /// whose AX element vanished) keeps it. The next teleport then repositions
    /// it back onto the strip's display, fighting the user. Under the default
    /// `stripDisplay` scope the strip should only manage its OWN display's
    /// windows, so a column that genuinely moved to another monitor must be let
    /// go - the mirror image of `belongsToStripDisplay` rejecting a foreign
    /// window at adopt time.
    ///
    /// ## Parked vs dragged (the false-positive we must avoid)
    ///
    /// A column scrolled off the viewport is PARKED: the engine shoves it far
    /// past the strip's side edge (`parkingX`, margin 4000) and macOS clamps it
    /// to a thin sliver pinned at the strip-display edge. That parked frame can
    /// momentarily best-overlap a NEIGHBORING display (e.g. a sliver clamped
    /// onto a monitor that abuts that edge), so evicting purely on best-overlap
    /// would wrongly release parked columns. The caller therefore passes
    /// `isParked` for any slot currently positioned off the content region; a
    /// parked slot is NEVER evicted (the user did not move it, the engine did).
    ///
    /// Only meaningful under `Scope.stripDisplay`; `allDisplays` never evicts
    /// (one strip is meant to span every monitor). Single-display setups have no
    /// `others`, so nothing is ever evicted.
    ///
    /// - Parameters:
    ///   - liveFrame: the window's CURRENT AX frame (top-left global), read back
    ///                fresh - never the stored slot geometry, which is what we
    ///                are trying to detect has gone stale.
    ///   - stripDisplay: the strip's own display, full AX frame.
    ///   - others: every OTHER display's full AX frame (empty on single-display).
    ///   - isParked: true if the engine has this column parked off-screen this
    ///               cycle (so its frame is engine-driven, not user-driven).
    static func evictedFromStripDisplay(liveFrame: CGRect,
                                        stripDisplay: CGRect,
                                        others: [CGRect],
                                        isParked: Bool,
                                        scope: Scope) -> Bool {
        // Legacy whole-desktop strip never evicts; nothing to compare against on
        // a single-display setup; a parked column is engine-positioned, not user-
        // moved, so it is exempt.
        guard scope == .stripDisplay, !others.isEmpty, !isParked else { return false }
        // Degenerate/unmeasurable frames are KEPT (never lose a window we cannot
        // classify) - the same safety bias as `belongsToStripDisplay`.
        let displays = [stripDisplay] + others
        guard let best = DisplayGeometry.display(bestOverlapping: liveFrame, displays: displays) else {
            return false
        }
        return best != stripDisplay
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

    /// PURE: partition candidate window frames across `displays`, assigning each
    /// to EXACTLY ONE display so independent per-display strips never both adopt
    /// the same window (which would teleport it to two places at once).
    ///
    /// Each window goes to the display it best overlaps (`DisplayGeometry`
    /// keeps the FIRST maximum, so a window split evenly across a bezel lands on
    /// the earlier display deterministically). A window that overlaps NO display
    /// (a degenerate/off-screen frame) is assigned to `fallbackIndex` when given
    /// - mirroring the single-strip "never lose a window" bias - otherwise it is
    /// dropped from every display's list.
    ///
    /// - Parameters:
    ///   - frames: candidate window frames (AX top-left global), in order.
    ///   - displays: each managed display's full AX frame, parallel to the
    ///               strips that own them.
    ///   - fallbackIndex: display to receive windows that overlap none, or nil
    ///                    to drop them.
    /// - Returns: for each display index, the candidate indices assigned to it
    ///            (ascending), so `result[d]` are the windows display `d` adopts.
    static func partition(frames: [CGRect],
                          displays: [CGRect],
                          fallbackIndex: Int? = nil) -> [[Int]] {
        var buckets = Array(repeating: [Int](), count: displays.count)
        guard !displays.isEmpty else { return buckets }
        for (i, frame) in frames.enumerated() {
            var bestIdx = -1
            var bestArea: CGFloat = 0
            for (d, disp) in displays.enumerated() {
                let area = DisplayGeometry.overlapArea(frame, disp)
                if area > bestArea { bestArea = area; bestIdx = d }
            }
            if bestIdx >= 0 {
                buckets[bestIdx].append(i)
            } else if let fb = fallbackIndex, displays.indices.contains(fb) {
                buckets[fb].append(i)
            }
        }
        return buckets
    }
}
