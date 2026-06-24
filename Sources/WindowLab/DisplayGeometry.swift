import Foundation
import CoreGraphics

/// Pure, AppKit-free display-geometry helpers shared by every multi-display
/// code path (strip rebinding, parking, restore clamping, adoption scoping).
///
/// Coordinate systems in play:
///   - **AppKit** (`NSScreen.frame`): origin at the PRIMARY display's
///     BOTTOM-left, Y grows UP. Non-primary displays can have negative X and/or
///     negative Y.
///   - **AX / CGWindow** (what we actually move windows in): origin at the
///     PRIMARY display's TOP-left, Y grows DOWN. This is the one true plane the
///     engine commits positions in.
///
/// Keeping these conversions in one pure place (instead of inline flips
/// scattered across the controller) makes the multi-display behavior unit
/// testable without a live `NSScreen`, and gives every agent the same vocabulary.
enum DisplayGeometry {

    /// Convert an AppKit frame (bottom-left origin, Y up) to AX global coords
    /// (top-left origin, Y down). `primaryHeight` is the height of the primary
    /// display (the one whose AppKit origin is `(0,0)`), which defines the
    /// Y-flip for the WHOLE coordinate plane.
    ///
    /// The flip is `axY = primaryHeight - appKitMaxY`. This is exact for every
    /// display, including ones above the primary (negative AppKit Y after the
    /// flip becomes a negative AX Y, i.e. "above" in the top-left plane too) and
    /// ones with negative X (carried through unchanged, X is shared).
    static func axFrame(appKitFrame f: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: f.origin.x,
               y: primaryHeight - f.maxY,
               width: f.width,
               height: f.height)
    }

    /// Inverse of `axFrame`: AX top-left frame back to an AppKit bottom-left
    /// frame. Useful when we have an AX rect (e.g. a stored window frame) and
    /// need to reason in AppKit terms, or to round-trip in tests.
    static func appKitFrame(axFrame f: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: f.origin.x,
               y: primaryHeight - f.maxY,
               width: f.width,
               height: f.height)
    }

    /// Area of the intersection of two rects (0 if they do not overlap).
    static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    /// The display (from `displays`) whose area overlaps `frame` the most.
    /// Ties and the empty case return `nil`. This is how we decide "which
    /// monitor is this window really on" — robust to a window straddling a
    /// bezel, unlike a center-point test.
    static func display(bestOverlapping frame: CGRect, displays: [CGRect]) -> CGRect? {
        var best: CGRect?
        var bestArea: CGFloat = 0
        for d in displays {
            let a = overlapArea(frame, d)
            if a > bestArea {
                bestArea = a
                best = d
            }
        }
        return best
    }

    /// The display (from `displays`) that contains `point`. If several do (they
    /// should not on a real layout), the first wins; if none do, `nil`.
    static func display(containing point: CGPoint, displays: [CGRect]) -> CGRect? {
        displays.first { $0.contains(point) }
    }

    /// True if `frame` is "mostly visible" across the union of `displays`: at
    /// least `minVisibleFraction` of its area falls on some display. Used to
    /// decide whether a stored restore frame would land a window off every
    /// screen (e.g. its display was unplugged) and therefore needs clamping.
    static func isMostlyVisible(_ frame: CGRect,
                                on displays: [CGRect],
                                minVisibleFraction: CGFloat = 0.5) -> Bool {
        let total = frame.width * frame.height
        guard total > 0 else { return true }
        var visible: CGFloat = 0
        for d in displays { visible += overlapArea(frame, d) }
        return visible / total >= minVisibleFraction
    }

    /// Clamp `frame` so it sits fully inside `display`, preserving size where it
    /// fits and shrinking only if `frame` is larger than `display`. This is the
    /// primitive a safe restore uses: if a window's saved frame would land
    /// off-screen (its monitor is gone), move/resize it onto an available one
    /// without surprising the user with an invisible window.
    static func clamp(_ frame: CGRect, into display: CGRect) -> CGRect {
        let w = min(frame.width, display.width)
        let h = min(frame.height, display.height)
        var x = frame.origin.x
        var y = frame.origin.y
        // Keep the right/bottom edges inside, then the left/top edges (left/top
        // win if the display is smaller than the window).
        x = min(x, display.maxX - w)
        x = max(x, display.minX)
        y = min(y, display.maxY - h)
        y = max(y, display.minY)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Ensure `frame` is reachable: if it is already mostly visible on some
    /// display, return it unchanged; otherwise clamp it onto the best available
    /// display (most overlap, else the first). Returns `frame` unchanged when
    /// there are no displays (degenerate; caller has bigger problems).
    static func ensureVisible(_ frame: CGRect,
                              displays: [CGRect],
                              minVisibleFraction: CGFloat = 0.5) -> CGRect {
        guard !displays.isEmpty else { return frame }
        if isMostlyVisible(frame, on: displays, minVisibleFraction: minVisibleFraction) {
            return frame
        }
        let target = display(bestOverlapping: frame, displays: displays) ?? displays[0]
        return clamp(frame, into: target)
    }
}
