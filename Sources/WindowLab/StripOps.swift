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

    /// Width in points for a given fraction of the usable width (screen minus
    /// the outer gaps that `adopt` reserves). Clamped to a sane minimum so a
    /// window can never collapse to nothing.
    func width(forFraction fraction: CGFloat) -> CGFloat {
        let usable = screenFrame.width - gap * 2
        let clamped = max(0.1, min(1.0, fraction))
        return max(minColumnWidth, (usable * clamped).rounded())
    }

    /// Resize the focused column to a fraction of the usable width.
    /// Returns false when there is nothing focused.
    @discardableResult
    func setFocusedWidth(fraction: CGFloat) -> Bool {
        guard slots.indices.contains(focusIndex) else { return false }
        let newWidth = width(forFraction: fraction)
        slots[focusIndex].width = newWidth

        let slot = slots[focusIndex]
        if slot.window.healthy {
            let err = AXSource.setSize(
                slot.window.element,
                kAXSizeAttribute as String,
                CGSize(width: newWidth, height: slot.height)
            )
            if err != .success {
                // Some windows clamp/refuse a size; read back so the model
                // reflects reality rather than our request.
                if let actual = AXSource.copySize(slot.window.element, kAXSizeAttribute as String) {
                    slots[focusIndex].width = actual.width
                    slots[focusIndex].height = actual.height
                }
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
