import Foundation
import ApplicationServices
import AppKit

/// Window operations on the focused column: resize to a fraction of the
/// usable width, reorder within the strip, and close.
///
/// All operations are pure AX (no extra permission) and keep the strip's
/// canvas model consistent: after any geometry change we recompact columns
/// left-to-right and re-teleport so the viewport stays coherent.
extension TeleportEngine {

    /// Standard column-width presets, as fractions of the usable strip width.
    /// Index maps to the Alt+1..4 hotkeys.
    static let widthPresets: [CGFloat] = [0.25, 0.50, 0.75, 1.0]

    /// Width in points for a given fraction of the viewport.
    ///
    /// The strip lays columns out as `gap | col | gap | col | ... | gap`, i.e.
    /// a `gap` margin on both outer edges and a `gap` between every column. For
    /// a fraction `f = 1/N` we want exactly `N` columns to tile the viewport:
    ///
    ///   leftMargin + N*w + (N-1)*gap + rightMargin = V,  margins == gap
    ///     => N*w = V - (N+1)*gap
    ///     => w   = f*(V - gap) - gap        (with f = 1/N)
    ///
    /// So `width(0.5)` fits exactly two columns (both with a `gap` on the
    /// outside and a `gap` between them), `width(0.25)` fits four, and
    /// `width(1.0) == V - 2*gap` fills the screen with a symmetric margin.
    /// Clamped to a sane minimum so a window can never collapse to nothing.
    func width(forFraction fraction: CGFloat) -> CGFloat {
        let clamped = max(0.05, min(1.0, fraction))
        let w = clamped * (screenFrame.width - gap) - gap
        return max(minColumnWidth, w.rounded())
    }

    /// Resize the focused column to a fraction of the usable width.
    /// Returns false when there is nothing focused.
    ///
    /// Many apps enforce a minimum window size (e.g. Apple Music, Calendar,
    /// System Settings) and silently clamp any `setSize` smaller than their
    /// floor. Crucially, AX usually still reports `.success` for the set: the
    /// attribute write "succeeded", the app just overrode the value afterward.
    /// So we cannot trust either the requested width OR the AX error code.
    /// Instead we ALWAYS read back the real size and store that, so the strip
    /// model never diverges from reality (which would otherwise make compacted
    /// columns overlap and the viewport mini-map drift).
    @discardableResult
    func setFocusedWidth(fraction: CGFloat) -> Bool {
        guard slots.indices.contains(focusIndex) else { return false }
        let requestedWidth = width(forFraction: fraction)
        // Optimistically update the model so a missing readback (hung/unhealthy
        // app) still reflects the user's intent.
        slots[focusIndex].width = requestedWidth

        let slot = slots[focusIndex]
        if slot.window.healthy {
            _ = AXSource.setSize(
                slot.window.element,
                kAXSizeAttribute as String,
                CGSize(width: requestedWidth, height: slot.height)
            )
            // Always reconcile against the live frame: an app that clamps to its
            // own minimum reports success but keeps a larger size. Trusting the
            // request here would corrupt the strip layout.
            if let actual = AXSource.copySize(slot.window.element, kAXSizeAttribute as String) {
                slots[focusIndex].width = actual.width
                slots[focusIndex].height = actual.height
            }
        }

        compactStrip()
        focus(index: focusIndex) // re-centers viewport on the resized column
        onLayoutChange?()
        return true
    }

    /// Move the focused column one position toward `delta` (negative = left,
    /// positive = right) within the strip. Returns false at the edges or when
    /// nothing is focused.
    @discardableResult
    func moveFocused(by delta: Int) -> Bool {
        guard slots.indices.contains(focusIndex), slots.count > 1 else { return false }
        let target = focusIndex + delta
        guard slots.indices.contains(target) else { return false }
        slots.swapAt(focusIndex, target)
        focusIndex = target
        compactStrip()
        focus(index: focusIndex)
        onLayoutChange?()
        return true
    }

    /// Close the focused window via its Accessibility close button, then drop
    /// it from the strip. Returns false when nothing is focused or the window
    /// has no usable close button.
    ///
    /// We do NOT restore this window's frame: the user asked to close it, and
    /// the app owns teardown. We simply stop managing it.
    @discardableResult
    func closeFocused() -> Bool {
        guard slots.indices.contains(focusIndex) else { return false }
        let slot = slots[focusIndex]
        let element = slot.window.element

        var closed = false
        var buttonRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &buttonRef) == .success,
           let buttonRef, CFGetTypeID(buttonRef) == AXUIElementGetTypeID() {
            let button = buttonRef as! AXUIElement
            closed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        }

        // Drop from the strip regardless: if the press succeeded the window is
        // gone; if it failed, the lifecycle monitor would otherwise keep trying
        // to teleport a window the user wanted closed. A failed close leaves the
        // real window untouched (we never force-killed anything).
        _ = removeSlots { CFEqual($0.window.element, element) }
        compactStrip()
        if !slots.isEmpty { focus(index: focusIndex) } else { teleport() }
        onLayoutChange?()
        return closed
    }
}
