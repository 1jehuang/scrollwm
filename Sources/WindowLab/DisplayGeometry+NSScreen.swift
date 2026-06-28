import Foundation
import CoreGraphics
import AppKit

/// AppKit bridge for `DisplayGeometry`. The core enum is deliberately
/// AppKit-free (so its coordinate/clamp logic is unit-testable without a live
/// `NSScreen`); this extension lives in its OWN file with `import AppKit` so the
/// pure module never pulls in AppKit, while restore/parking paths can still ask
/// "what displays exist RIGHT NOW".
extension DisplayGeometry {

    /// THE Y-flip anchor for the AX coordinate plane: the height of the PRIMARY
    /// display (the one whose AppKit origin is `(0,0)`). Every site that converts
    /// between AppKit and AX coordinates must use THIS, so the anchor can never
    /// diverge between the rebind, the indicators, restore, and `managedDisplays`
    /// (the old code re-derived it in ~7 places with three different fallback
    /// chains, which disagreed by `mainHeight - firstHeight` in the transient
    /// "no display at origin" window).
    ///
    /// Fallback chain, deterministic and never `0` while ANY screen exists:
    ///   1. `NSScreen.main` when it sits at the origin (the normal layout; also
    ///      disambiguates the pathological co-origin / mirrored case),
    ///   2. else the first screen found at the AppKit origin,
    ///   3. else `NSScreen.main`'s height (mid-reconfiguration, no origin screen),
    ///   4. else the first screen's height (`0` only when there are no screens).
    static func primaryHeight(of screens: [NSScreen] = NSScreen.screens) -> CGFloat {
        if let m = NSScreen.main, m.frame.origin == .zero { return m.frame.height }
        if let p = screens.first(where: { $0.frame.origin == .zero }) { return p.frame.height }
        if let m = NSScreen.main { return m.frame.height }
        return screens.first?.frame.height ?? 0
    }

    /// Visible frames of every currently-attached display, in AX global
    /// coordinates (top-left origin, Y down) — the same plane the engine commits
    /// window positions in.
    ///
    /// `visibleFrame` (not `frame`) is used on purpose: a rescued/restored window
    /// should land in the usable area BELOW the menu bar, not under it. The
    /// primary display (AppKit origin `(0,0)`) defines the Y-flip height for the
    /// whole plane, matching `ScrollWMController.refreshDisplayGeometry`.
    ///
    /// Returns `[]` only in the degenerate headless case (no screens), which
    /// `ensureVisible` treats as "leave the frame alone".
    static func currentVisibleAXDisplays() -> [CGRect] {
        let primaryHeight = primaryHeight()
        return NSScreen.screens.map {
            axFrame(appKitFrame: $0.visibleFrame, primaryHeight: primaryHeight)
        }
    }
}

extension NSScreen {
    /// The stable `CGDirectDisplayID` macOS assigns this physical display, read
    /// from `deviceDescription["NSScreenNumber"]`. Unlike a screen's frame, the
    /// id survives an arrangement/origin change, a resolution/scale change, and a
    /// re-plug of the same monitor, so the hotplug resolver can track "the strip's
    /// OWN display" by identity instead of by ambiguous geometry overlap.
    ///
    /// Returns `nil` only if AppKit fails to vend the number (never observed in
    /// practice); callers fall back to the geometry path, which is still correct
    /// for the common cases.
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
