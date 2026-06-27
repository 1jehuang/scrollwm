import Foundation
import AppKit

/// A lightweight floating panel that mirrors the menu-bar mini-map onto a
/// display that has NO system menu bar (every non-primary monitor under the
/// default macOS "Displays have separate Spaces = off"). It hosts the SAME
/// `MenuBarStripView` the status item uses, pinned to the top-center of its
/// display, so the user can see the strip's state on the monitor they are
/// looking at without glancing back at the primary display.
///
/// Design (public AppKit API only; NO new permissions):
///   - Borderless `.nonactivatingPanel` at `.statusBar` level that joins all
///     Spaces and is stationary, so it stays put as the user switches Spaces /
///     full-screens an app, and never appears in Mission Control's window cycle.
///   - `ignoresMouseEvents = true`: a pure indicator; clicks pass through to
///     whatever is behind it (we do not want to intercept the user's desktop).
///   - Clear background with a subtle rounded translucent backing so light
///     strokes read on any wallpaper, matching the menu bar's vibrancy feel.
///   - Never steals focus (non-activating, never `makeKey`).
///
/// Positioning is done in the engine's AX plane (top-left origin) and converted
/// to AppKit (bottom-left) via `DisplayGeometry.appKitFrame` so it shares the
/// exact same coordinate math as the strip itself.
///
/// Headless safety: in test mode (`AXSource.backend != nil`) NO `NSWindow` is
/// ever created, so `unittest`/`headlesstest` stay completely windowless.
final class FloatingStripIndicator {

    /// Stable display id this indicator is pinned to (nil only in degenerate
    /// setups where AppKit vended no id).
    let displayID: CGDirectDisplayID?

    /// The backing panel + hosted mini-map. Nil in headless mode (never built).
    private var panel: NSPanel?
    private let stripView = MenuBarStripView(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
    /// Rounded translucent backing behind the mini-map so it reads on any
    /// wallpaper. Brightness tracks `setActive`.
    private let backing = IndicatorBackingView(frame: .zero)

    /// Whether this indicator's display is the ACTIVE strip (drawn brighter).
    private var isActive = false

    init(displayID: CGDirectDisplayID?) {
        self.displayID = displayID
        // Headless: stay completely inert (no AppKit window) so tests never spawn
        // a real panel on the user's desktop.
        guard AXSource.backend == nil else { return }
        buildPanel()
    }

    private func buildPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: 22),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true   // pure indicator: clicks pass through

        // Content: a rounded translucent backing hosting the live mini-map.
        let content = NSView(frame: p.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        backing.frame = content.bounds
        backing.autoresizingMask = [.width, .height]
        content.addSubview(backing)
        stripView.frame = content.bounds.insetBy(dx: 4, dy: 2)
        stripView.autoresizingMask = [.width, .height]
        content.addSubview(stripView)
        p.contentView = content

        panel = p
        applyActiveStyle()
    }

    /// Position the panel from an AX-coords frame (top-left origin). `primaryHeight`
    /// is the AX-plane flip anchor (height of the primary display). No-op headless.
    func setFrameAX(_ frameAX: CGRect, primaryHeight: CGFloat) {
        guard let panel else { return }
        let appKit = DisplayGeometry.appKitFrame(axFrame: frameAX, primaryHeight: primaryHeight)
        panel.setFrame(appKit, display: true)
    }

    /// Push live strip state into the hosted mini-map. No-op headless.
    func apply(state: TeleportEngine.StripState, managing: Bool) {
        guard panel != nil else { return }
        stripView.apply(state: state, managing: managing)
    }

    /// Highlight (or dim) this indicator when its display is / isn't the active
    /// strip. The active display reads at full strength; inactive ones dim so the
    /// user can tell at a glance which monitor their hotkeys act on. No-op headless.
    func setActive(_ active: Bool) {
        guard panel != nil, active != isActive else { return }
        isActive = active
        applyActiveStyle()
    }

    private func applyActiveStyle() {
        backing.isActiveDisplay = isActive
        backing.needsDisplay = true
        // Slightly fade the whole panel when inactive.
        panel?.alphaValue = isActive ? 1.0 : 0.78
    }

    /// Show / hide the panel. Ordered front WITHOUT making it key (never steals
    /// focus). No-op headless.
    func setVisible(_ visible: Bool) {
        guard let panel else { return }
        if visible {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    /// Tear down the panel (hotplug / release / quit). Safe to call repeatedly.
    func close() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    deinit { close() }
}

/// Rounded translucent backing drawn behind the mini-map so it reads on any
/// wallpaper, echoing the menu bar's look. Click-through (the host panel sets
/// `ignoresMouseEvents`).
private final class IndicatorBackingView: NSView {
    var isActiveDisplay = false

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.cgContext.clear(bounds)
        let radius: CGFloat = 6
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: radius, yRadius: radius)
        // A dark, semi-transparent capsule; the active display reads brighter
        // and gets a hairline accent so "where am I" is obvious at a glance.
        NSColor(white: 0.08, alpha: isActiveDisplay ? 0.72 : 0.55).setFill()
        path.fill()
        path.lineWidth = 1
        let stroke = isActiveDisplay
            ? NSColor.controlAccentColor.withAlphaComponent(0.9)
            : NSColor(white: 1, alpha: 0.18)
        stroke.setStroke()
        path.stroke()
    }
}
