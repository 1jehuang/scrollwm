import Foundation
import AppKit

/// A lightweight floating panel that mirrors the menu-bar mini-map onto a
/// display that has NO system menu bar (every non-primary monitor under the
/// default macOS "Displays have separate Spaces = off"). It hosts the SAME
/// `MenuBarStripView` the status item uses, pinned to the top-center of its
/// display, so the user can see the strip's state on the monitor they are
/// looking at without glancing back at the primary display.
///
/// STUB — owned by swarm worker E. Replace this whole file with the real
/// implementation. Requirements (no new permissions, public API only):
///   - Borderless `NSPanel` (`.nonactivatingPanel`), `level = .statusBar`,
///     `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
///     .fullScreenAuxiliary]`, `isOpaque = false`, clear background,
///     `ignoresMouseEvents = true` (pure indicator — clicks pass through),
///     `hidesOnDeactivate = false`.
///   - Hosts a `MenuBarStripView`; expose `apply(state:managing:)` and
///     `setActive(_:)` (the active display's indicator is highlighted).
///   - `setFrameAX(_:)` positions it from an AX-coords rect using
///     `DisplayGeometry.appKitFrame(axFrame:primaryHeight:)`.
///   - Idempotent show/hide; never steals focus; safe to create/destroy on
///     hotplug. NEVER created in headless test mode (`AXSource.backend != nil`).
///
/// The controller owns one `FloatingStripIndicator` per non-menu-bar managed
/// display (see `IndicatorPlacement`) and drives it on every menu refresh.
final class FloatingStripIndicator {

    /// Stable display id this indicator is pinned to.
    let displayID: CGDirectDisplayID?

    /// STUB initializer. Worker E builds the real panel + hosted strip view.
    init(displayID: CGDirectDisplayID?) {
        self.displayID = displayID
    }

    /// Position the panel from an AX-coords frame (top-left origin). `primaryHeight`
    /// is the AX-plane flip anchor (see `DisplayGeometry`). STUB: no-op.
    func setFrameAX(_ frameAX: CGRect, primaryHeight: CGFloat) {
        _ = (frameAX, primaryHeight)
    }

    /// Push live strip state into the hosted mini-map. STUB: no-op.
    func apply(state: TeleportEngine.StripState, managing: Bool) {
        _ = (state, managing)
    }

    /// Highlight (or dim) this indicator when its display is / isn't the active
    /// strip. STUB: no-op.
    func setActive(_ active: Bool) { _ = active }

    /// Show / hide the panel. STUB: no-op.
    func setVisible(_ visible: Bool) { _ = visible }

    /// Tear down the panel (hotplug / release / quit). STUB: no-op.
    func close() {}
}
