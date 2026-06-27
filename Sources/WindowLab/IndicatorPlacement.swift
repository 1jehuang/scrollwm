import Foundation
import CoreGraphics

/// PURE, AppKit-free placement policy for the floating per-display strip
/// indicator (the mini-map shown on monitors that have NO system menu bar).
///
/// macOS draws the system menu bar on only ONE display (unless "Displays have
/// separate Spaces" is enabled, in which case every display has its own). The
/// `NSStatusItem` therefore appears on a single monitor; on every other managed
/// monitor the user cannot see ScrollWM's state. This policy decides which
/// displays get a small floating indicator panel and exactly where to put it.
///
/// Coordinate plane: everything here is the engine's AX plane (top-left origin,
/// Y down — see `DisplayGeometry`). The AppKit `NSWindow` host converts to
/// AppKit coords with `DisplayGeometry.appKitFrame` at display time.
enum IndicatorPlacement {

    /// One connected display described for placement.
    struct DisplayInput: Equatable {
        /// Full display frame in AX coords.
        var fullAXFrame: CGRect
        /// Usable (menu-bar/Dock-excluded) frame in AX coords. The indicator is
        /// pinned just below the TOP of this rect so it never overlaps the menu
        /// bar (on a display that has one) or sits off the panel.
        var visibleAXFrame: CGRect
        /// True if macOS draws the system menu bar on this display (so the
        /// `NSStatusItem` is already visible here and no floating panel is
        /// needed).
        var hasSystemMenuBar: Bool
        /// True if a strip is actively managing this display. A dormant display
        /// shows nothing (the indicator only reflects a live strip).
        var isManaging: Bool
        /// Stable display id, carried through to the placement so the controller
        /// can key its panel cache by display.
        var id: CGDirectDisplayID?

        init(fullAXFrame: CGRect, visibleAXFrame: CGRect,
             hasSystemMenuBar: Bool, isManaging: Bool, id: CGDirectDisplayID? = nil) {
            self.fullAXFrame = fullAXFrame
            self.visibleAXFrame = visibleAXFrame
            self.hasSystemMenuBar = hasSystemMenuBar
            self.isManaging = isManaging
            self.id = id
        }
    }

    /// Where to put one floating indicator panel.
    struct Placement: Equatable {
        var displayID: CGDirectDisplayID?
        /// Panel frame in AX coords (top-left origin).
        var frameAX: CGRect
    }

    /// Decide which displays get a floating indicator and where.
    ///
    /// A display qualifies when it is MANAGING and does NOT host the system menu
    /// bar. The panel is `indicatorSize`, horizontally centered on the display's
    /// visible region, pinned `topInset` points below the visible top edge, and
    /// clamped to stay fully on the display (so a tiny/rotated panel never sits
    /// off-screen). With a single display, or when no display qualifies, returns
    /// an empty array.
    ///
    /// Pure and order-preserving: `placements[i]` corresponds to the i-th
    /// qualifying display in input order, so the caller can diff stably by id.
    static func placements(displays: [DisplayInput],
                           indicatorSize: CGSize,
                           topInset: CGFloat) -> [Placement] {
        // A lone display always has the menu bar; never float a redundant panel.
        guard displays.count > 1 else { return [] }
        let w = max(indicatorSize.width, 1)
        let h = max(indicatorSize.height, 1)

        var out: [Placement] = []
        for d in displays {
            guard d.isManaging, !d.hasSystemMenuBar else { continue }
            // Prefer the visible rect; fall back to the full frame if visible is
            // degenerate (some virtual displays vend a zero visibleFrame).
            let region = (d.visibleAXFrame.width > 0 && d.visibleAXFrame.height > 0)
                ? d.visibleAXFrame : d.fullAXFrame
            guard region.width > 0, region.height > 0 else { continue }

            // Center horizontally; pin near the top (AX y grows DOWN, so "below
            // the top edge" means region.minY + topInset).
            var x = region.midX - w / 2
            var y = region.minY + topInset
            // Clamp fully on-display: right/bottom first, then left/top so a
            // panel wider/taller than the region still lands at the top-left.
            x = min(x, region.maxX - w)
            x = max(x, region.minX)
            y = min(y, region.maxY - h)
            y = max(y, region.minY)

            out.append(Placement(
                displayID: d.id,
                frameAX: CGRect(x: x, y: y, width: w, height: h)))
        }
        return out
    }
}
