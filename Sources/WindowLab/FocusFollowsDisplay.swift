import Foundation
import CoreGraphics

/// PURE, AppKit-free policy for "focus follows display": given the OS-focused
/// window (the frontmost app's focused window) and the per-display strips,
/// decide which strip should become the ACTIVE one so navigation/width/move/
/// workspace hotkeys act on the monitor the user is actually looking at.
///
/// STUB — owned by swarm worker B. Replace this whole file with the real
/// implementation + `FocusFollowsDisplayTests`. The controller will call
/// `resolveActiveStrip` from its focused-window observer; keep the input/output
/// shape stable.
enum FocusFollowsDisplay {

    /// Minimal description of a managed strip for the policy.
    struct StripInput: Equatable {
        /// The strip's display, full AX frame.
        var displayAXFrame: CGRect
        var isManaging: Bool
        var id: CGDirectDisplayID?

        init(displayAXFrame: CGRect, isManaging: Bool, id: CGDirectDisplayID? = nil) {
            self.displayAXFrame = displayAXFrame
            self.isManaging = isManaging
            self.id = id
        }
    }

    /// Resolve the index (into `strips`) that should be active given the AX
    /// frame of the currently OS-focused window. Returns nil when the focused
    /// window maps to no managing strip (caller keeps the current active strip).
    ///
    /// STUB returns nil. Worker B: best-overlap the focused window's frame
    /// against each managing strip's display; ignore non-managing strips; bias
    /// to keeping the current strip on a tie/ambiguity.
    static func resolveActiveStrip(focusedWindowAXFrame: CGRect?,
                                  strips: [StripInput],
                                  currentActive: Int) -> Int? {
        _ = (focusedWindowAXFrame, strips, currentActive)
        return nil
    }
}

/// STUB test entrypoint — worker B replaces with real assertions.
enum FocusFollowsDisplayTests {
    static func run() -> Bool {
        print("[mmtest] FocusFollowsDisplay: STUB (no assertions yet)")
        return true
    }
}
