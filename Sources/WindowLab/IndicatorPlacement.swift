import Foundation
import CoreGraphics

/// PURE, AppKit-free placement policy for the floating per-display strip
/// indicator (the mini-map shown on monitors that have NO system menu bar).
///
/// STUB — owned by swarm worker A. Replace this whole file with the real
/// implementation + `IndicatorPlacementTests`. Keep the public shape below
/// stable (the `FloatingStripIndicator` panel and the controller integration
/// code against it); extend it as needed but do not remove fields without
/// telling the coordinator.
///
/// Coordinate plane: everything here is in the engine's AX plane (top-left
/// origin, Y down — see `DisplayGeometry`). The AppKit `NSWindow` host converts
/// to AppKit coords with `DisplayGeometry.appKitFrame`.
enum IndicatorPlacement {

    /// One connected display described for placement.
    struct DisplayInput: Equatable {
        /// Full display frame in AX coords.
        var fullAXFrame: CGRect
        /// Usable (menu-bar/Dock-excluded) frame in AX coords.
        var visibleAXFrame: CGRect
        /// True if macOS draws the system menu bar on this display (so the
        /// `NSStatusItem` is already visible here and no floating panel is
        /// needed). Usually true only for the display that owns the menu bar.
        var hasSystemMenuBar: Bool
        /// True if a strip is actively managing this display.
        var isManaging: Bool
        /// Stable display id, carried through to the placement.
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

    /// Decide which displays get a floating indicator and where. STUB returns
    /// nothing; worker A implements the real top-center placement.
    static func placements(displays: [DisplayInput],
                           indicatorSize: CGSize,
                           topInset: CGFloat) -> [Placement] {
        _ = (displays, indicatorSize, topInset)
        return []
    }
}

/// STUB test entrypoint — worker A replaces with real assertions.
enum IndicatorPlacementTests {
    static func run() -> Bool {
        print("[mmtest] IndicatorPlacement: STUB (no assertions yet)")
        return true
    }
}
