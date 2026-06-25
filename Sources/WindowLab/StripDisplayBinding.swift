import Foundation
import CoreGraphics

/// PURE, AppKit-free policy for "what AX frames does the strip bind to when it
/// lives on display `stripIndex`?". Extracted as its own unit-tested type (like
/// `DisplaySelector` / `StripDisplayResolver`) so the LAUNCH bind, the runtime
/// `moveStripToDisplay`, the `sandbox --display N` bind, and the hotplug relay
/// all share ONE coordinate-flip instead of re-deriving it inline.
///
/// Why this matters: the engine commits window positions in the AX top-left
/// plane whose Y origin is the PRIMARY display's top-left. Flipping a display's
/// AppKit frame to AX requires the PRIMARY display's height, NOT the strip
/// display's own height. Re-deriving the flip inline made it tempting to write
/// `stripScreen.frame.height - visible.maxY`, which is only correct when the
/// strip display IS the primary; on a non-primary (e.g. a negative-origin
/// external the user configured as `stripDisplay`) it mis-places the whole strip
/// vertically by `(stripHeight - primaryHeight)`. Centralizing the math here, and
/// reusing `DisplayGeometry.axFrame`, removes that whole class of bug.
enum StripDisplayBinding {

    /// One connected display, described purely in AppKit coordinates (the values
    /// `NSScreen.frame` / `NSScreen.visibleFrame` report). Trivial to fabricate
    /// in tests; production maps `NSScreen.screens` to this, parallel order.
    struct DisplayFrames: Equatable {
        /// `NSScreen.frame` — the full display rect (parking/other reference).
        var full: CGRect
        /// `NSScreen.visibleFrame` — usable area minus menu bar / Dock (the
        /// strip's own laid-out area, `engine.screenFrame`).
        var visible: CGRect
    }

    /// The AX (top-left, Y-down) frames the controller pushes into the engine for
    /// a given strip display. `stripVisible` becomes `engine.screenFrame`;
    /// `stripFull` the parking reference (`stripDisplayFrame`); `others` the full
    /// frames of every OTHER display (`otherDisplayFrames`).
    struct Binding: Equatable {
        var stripFull: CGRect
        var stripVisible: CGRect
        var others: [CGRect]
    }

    /// Height of the PRIMARY display — the one whose AppKit origin is `(0,0)` —
    /// which defines the Y-flip for the WHOLE AX coordinate plane. Falls back to
    /// the `mainIndex` display, then the strip display, then 0, mirroring the
    /// controller's `NSScreen.main`/`stripDisplay` fallbacks so the pure result
    /// matches production exactly even in degenerate layouts.
    static func primaryHeight(displays: [DisplayFrames],
                              mainIndex: Int?,
                              stripIndex: Int) -> CGFloat {
        if let p = displays.first(where: { $0.full.origin == .zero }) {
            return p.full.height
        }
        if let m = mainIndex, displays.indices.contains(m) {
            return displays[m].full.height
        }
        if displays.indices.contains(stripIndex) {
            return displays[stripIndex].full.height
        }
        return 0
    }

    /// Compute the AX binding for the strip living on `displays[stripIndex]`.
    ///
    /// Every display (the strip's AND the others') is flipped with the SAME
    /// primary-display height, so a strip on a non-primary, negative-origin
    /// external lands correctly instead of being shoved by its own height.
    /// Returns `nil` only when `stripIndex` is out of range / `displays` is
    /// empty, so the caller can keep the previous binding rather than crash.
    static func bind(displays: [DisplayFrames],
                     stripIndex: Int,
                     mainIndex: Int?) -> Binding? {
        guard displays.indices.contains(stripIndex) else { return nil }
        let h = primaryHeight(displays: displays, mainIndex: mainIndex, stripIndex: stripIndex)
        let strip = displays[stripIndex]
        let stripFull = DisplayGeometry.axFrame(appKitFrame: strip.full, primaryHeight: h)
        let stripVisible = DisplayGeometry.axFrame(appKitFrame: strip.visible, primaryHeight: h)
        let others = displays.indices
            .filter { $0 != stripIndex }
            .map { DisplayGeometry.axFrame(appKitFrame: displays[$0].full, primaryHeight: h) }
        return Binding(stripFull: stripFull, stripVisible: stripVisible, others: others)
    }
}
