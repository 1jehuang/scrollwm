import Foundation
import CoreGraphics

/// PURE, AppKit-free policy for "which display should the strip live on after a
/// monitor hotplug / rearrange?". Extracted so the catastrophic case (the
/// strip's OWN display is unplugged and its windows would be orphaned off
/// every screen) is decided by unit-testable logic instead of an inline
/// `NSScreen.max(by:)` whose all-zero-overlap tie-break is arbitrary.
///
/// All rects are in ONE coordinate space (the engine's AX top-left plane). The
/// caller passes the strip's currently-bound frame and the AX *visible* frames
/// of every currently-available display; the resolver returns the frame the
/// strip should bind to (plus the index of the chosen display so the caller can
/// map back to its `NSScreen`).
///
/// Decision:
///   1. **Strip display still present** (some display overlaps the strip frame
///      by at least `minOverlapFraction` of the strip's area): bind to the
///      display with the MOST overlap. This is robust to a display that merely
///      changed resolution/scale or shifted origin - it is "the same screen", so
///      the strip follows it onto the new geometry.
///   2. **Strip display GONE** (no display meaningfully overlaps): MIGRATE to
///      the best surviving display - the largest by area (most room for the
///      strip), ties broken by lowest index for determinism.
///   3. **No displays at all** (degenerate, e.g. all monitors asleep): keep the
///      last frame so we never bind to garbage; the caller stays put until a
///      display reappears.
enum StripDisplayResolver {

    /// Outcome of a resolve. `displayIndex` is `nil` only when there are no
    /// displays to choose from (case 3). `migrated` is true when the strip's
    /// own display vanished and we moved its windows to a survivor.
    struct Decision: Equatable {
        /// AX visible frame the strip should bind to (`rebindStripDisplay`).
        let frame: CGRect
        /// Index into the `displays` array of the chosen display, or `nil` when
        /// `displays` was empty (so the caller knows to leave the strip put).
        let displayIndex: Int?
        /// True when the strip's prior display was gone and we relocated the
        /// strip onto a different surviving display (the windows-rescue case).
        let migrated: Bool
    }

    /// Resolve the display the strip should bind to. See the type doc for the
    /// three cases. `minOverlapFraction` is the share of the STRIP's area that
    /// must still land on some display for that display to count as "the strip's
    /// display" (default 20%: tolerant of a big resolution drop, intolerant of a
    /// strip stranded entirely off-screen).
    static func resolve(stripFrame: CGRect,
                        displays: [CGRect],
                        minOverlapFraction: CGFloat = 0.2) -> Decision {
        // Case 3: nothing to bind to - keep the last frame, signal "no choice".
        guard !displays.isEmpty else {
            return Decision(frame: stripFrame, displayIndex: nil, migrated: false)
        }

        // Best-overlapping display with the strip's current frame.
        var bestIdx = 0
        var bestArea: CGFloat = -1
        for (i, d) in displays.enumerated() {
            let a = DisplayGeometry.overlapArea(stripFrame, d)
            if a > bestArea { bestArea = a; bestIdx = i }
        }

        // Is the strip's display still present? Judge by the fraction of the
        // STRIP that still falls on its best-overlapping display.
        let stripArea = stripFrame.width * stripFrame.height
        let presentEnough = stripArea > 0 && (bestArea / stripArea) >= minOverlapFraction

        if presentEnough {
            // Case 1: same screen (possibly resized) - follow it.
            return Decision(frame: displays[bestIdx], displayIndex: bestIdx, migrated: false)
        }

        // Case 2: strip display gone - migrate to the largest survivor.
        var survivor = 0
        var survivorArea: CGFloat = -1
        for (i, d) in displays.enumerated() {
            let area = d.width * d.height
            if area > survivorArea { survivorArea = area; survivor = i }
        }
        return Decision(frame: displays[survivor], displayIndex: survivor, migrated: true)
    }
}
