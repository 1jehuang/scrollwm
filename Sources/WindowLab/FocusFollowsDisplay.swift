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
    /// window maps to no managing strip, or when the best match is already
    /// `currentActive` (caller then keeps the current active strip and does no
    /// redundant work).
    ///
    /// Policy: among MANAGING strips only, pick the one whose display has the
    /// greatest overlap with the focused window. Non-managing strips are ignored
    /// entirely (a window on a dormant monitor should not steal focus routing).
    /// On an exact overlap tie, bias to KEEPING `currentActive` if it is among
    /// the tied winners, else the lowest index. Returns nil for a nil frame, no
    /// managing strips, fewer than two managing strips, or zero overlap with any
    /// managing display.
    static func resolveActiveStrip(focusedWindowAXFrame: CGRect?,
                                  strips: [StripInput],
                                  currentActive: Int) -> Int? {
        guard let frame = focusedWindowAXFrame else { return nil }
        // Managing strips are the only routing targets; with fewer than two of
        // them there is nothing to switch between.
        let managing = strips.indices.filter { strips[$0].isManaging }
        guard managing.count > 1 else { return nil }

        var bestIndex = -1
        var bestArea: CGFloat = 0
        for i in managing {
            let area = DisplayGeometry.overlapArea(frame, strips[i].displayAXFrame)
            guard area > 0 else { continue }
            if area > bestArea {
                bestArea = area
                bestIndex = i
            } else if area == bestArea, bestIndex >= 0 {
                // Tie: prefer keeping the current active strip if it is tied.
                if i == currentActive { bestIndex = i }
            }
        }
        // If the current active strip ties the max, keep it (bias to no switch).
        if bestArea > 0, managing.contains(currentActive),
           DisplayGeometry.overlapArea(frame, strips[currentActive].displayAXFrame) == bestArea {
            bestIndex = currentActive
        }

        guard bestIndex >= 0 else { return nil }          // overlaps no managing display
        return bestIndex == currentActive ? nil : bestIndex
    }
}
