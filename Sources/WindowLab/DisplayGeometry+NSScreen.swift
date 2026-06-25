import Foundation
import CoreGraphics
import AppKit

/// AppKit bridge for `DisplayGeometry`. The core enum is deliberately
/// AppKit-free (so its coordinate/clamp logic is unit-testable without a live
/// `NSScreen`); this extension lives in its OWN file with `import AppKit` so the
/// pure module never pulls in AppKit, while restore/parking paths can still ask
/// "what displays exist RIGHT NOW".
extension DisplayGeometry {

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
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.main)?.frame.height ?? 0
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
