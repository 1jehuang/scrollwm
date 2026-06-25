import Foundation
import CoreGraphics

/// Pure, AppKit-free policy for choosing WHICH display the scrolling strip lives
/// on. Kept as its own unit-tested type (like `ResyncPlanner`) so the
/// "main vs primary vs largest vs an explicit index" decision is verifiable
/// without a live `NSScreen`, and so the INITIAL pick (from `layout.stripDisplay`
/// at launch) and the RUNTIME pick (`scrollwm display <…>`) share one source of
/// truth instead of two slightly-different inline switches.
enum DisplaySelector {

    /// Minimal descriptor of a connected display, supplied in `NSScreen.screens`
    /// order. Only the fields the policy actually needs, so it is trivial to
    /// fabricate in tests.
    struct DisplayInfo: Equatable {
        /// AppKit frame; only its AREA matters here (for `"largest"`).
        var frame: CGRect
        /// True for the current `NSScreen.main` (the display the user is on —
        /// has the active window / menu bar). This is what `"main"` resolves to.
        var isMain: Bool
        /// True for the PRIMARY display (AppKit origin `(0,0)`), the anchor of the
        /// coordinate plane. Usually the laptop panel. This is what `"primary"`
        /// resolves to.
        var isPrimary: Bool
    }

    /// Resolve a strip-display spec to an index into `displays`.
    ///
    /// Specs (case-insensitive, surrounding whitespace ignored):
    ///   - `"main"` (default / empty): the current `NSScreen.main`.
    ///   - `"primary"`: the primary display (AppKit origin); falls back to main.
    ///   - `"largest"`: the display with the greatest area — the external on a
    ///     laptop+monitor setup. Ties resolve to the first such display.
    ///   - `"next"`: the display AFTER `current` in `NSScreen.screens` order,
    ///     wrapping around. Used by the runtime cycle verb; needs `current`
    ///     (falls back to main, then 0, when `current` is nil).
    ///   - an integer (1-based, to match `focus`/`workspace`): that display,
    ///     e.g. `"2"` selects the second screen.
    ///
    /// Returns `nil` for an empty display list or an unrecognized / out-of-range
    /// spec, so the caller can keep the current display and surface the error
    /// rather than silently jumping somewhere.
    static func pick(spec: String, displays: [DisplayInfo], current: Int? = nil) -> Int? {
        guard !displays.isEmpty else { return nil }
        let s = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch s {
        case "", "main":
            return displays.firstIndex { $0.isMain } ?? 0
        case "primary":
            return displays.firstIndex { $0.isPrimary }
                ?? displays.firstIndex { $0.isMain } ?? 0
        case "largest":
            var best = 0
            var bestArea = displays[0].frame.width * displays[0].frame.height
            for (i, d) in displays.enumerated() {
                let area = d.frame.width * d.frame.height
                if area > bestArea { bestArea = area; best = i }
            }
            return best
        case "next":
            let base = current ?? displays.firstIndex { $0.isMain } ?? 0
            return (base + 1) % displays.count
        default:
            // Explicit 1-based index (consistent with the focus/workspace CLI).
            guard let n = Int(s), n >= 1, n <= displays.count else { return nil }
            return n - 1
        }
    }
}
