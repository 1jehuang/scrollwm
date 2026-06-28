import Foundation
import AppKit

/// Opaque "edge scrim" windows that COVER the unavoidable macOS off-screen
/// clamp sliver of a parked column, so the user never sees a stray/broken-looking
/// window slice at a screen edge.
///
/// ## Why this exists
///
/// macOS refuses to move a standard window fully off-screen: it clamps any
/// position to keep ~40px of the window visible at some display edge (AppKit's
/// `constrainFrameRect`, the "keep the title bar reachable" rule). ScrollWM parks
/// a column scrolled out of the viewport by shoving it far past the strip-display
/// edge, so that clamp leaves a thin full-height sliver pinned at the edge. Users
/// read that sliver as a stray window and find it confusing.
///
/// We cannot defeat the clamp by position (measured), and we cannot reliably
/// COVER the sliver with another app's window (macOS z-orders per-app, so
/// activating the focused column's app raises ITS parked windows above other
/// columns - measured to leak). Minimizing a parked column hides it but costs a
/// ~600ms genie animation + Dock clutter on every scroll. The robust, no-private-
/// API answer is to paint a thin opaque window WE own at an elevated level over
/// exactly the sliver lane: a `.floating`-level borderless window composites
/// above every normal app window and never steals keyboard focus (verified).
///
/// ## Contract
///
/// - The scrim sits in the reserved peek lane (`peekInset`), a region on-screen
///   columns never occupy, so it never clips real content. The controller only
///   asks for scrims when the lane is at least as wide as the sliver.
/// - It is purely cosmetic: ignores mouse so it cannot trap clicks meant for a
///   real window edge (there is none - the area is the dead sliver lane), never
///   activates ScrollWM, joins all Spaces and stays put so it does not churn on
///   Space switches, and is excluded from window cycling / screenshots' app list.
/// - Headless/test safe: under `AXSource.backend` (the sim) NOTHING is created,
///   exactly like the menu-bar status item, so tests never spawn a real window.
/// - Torn down completely on release/quit (`hideAll`), so a dormant ScrollWM
///   leaves no chrome on the desktop.
final class EdgeScrim {

    /// One reusable scrim window. Borderless, opaque, elevated, non-activating.
    private final class ScrimWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Live scrim windows. We keep a small pool and show/position/hide them each
    /// layout change; at most two are visible at once per call (left + right).
    private var pool: [ScrimWindow] = []

    /// Appearance: a flat, slightly translucent dark bar that reads as an
    /// intentional "strip edge" rather than a window. Tunable; kept subtle.
    private let fill: NSColor

    init(fill: NSColor = NSColor(white: 0.10, alpha: 1.0)) {
        self.fill = fill
    }

    /// Show opaque scrims at exactly `frames` (AppKit coordinates, bottom-left
    /// origin) and hide any extra pooled windows. Idempotent: call it every
    /// layout change with the current desired frames. Pass `[]` to hide all.
    ///
    /// No-op under a headless backend (never creates a real window in tests).
    func show(frames: [CGRect]) {
        guard AXSource.backend == nil else { return }
        // Grow the pool to cover the requested count.
        while pool.count < frames.count { pool.append(makeWindow()) }
        for (i, win) in pool.enumerated() {
            if i < frames.count {
                let f = frames[i]
                // Only move if it actually changed (avoid needless server churn).
                if win.frame != f { win.setFrame(f, display: false) }
                if !win.isVisible { win.orderFrontRegardless() }
            } else if win.isVisible {
                win.orderOut(nil)
            }
        }
    }

    /// Hide every scrim (release/quit/dormant). Keeps the pool for cheap reuse.
    func hideAll() {
        for win in pool where win.isVisible { win.orderOut(nil) }
    }

    /// Permanently tear down all scrim windows (deinit / full reset).
    func destroy() {
        for win in pool { win.orderOut(nil) }
        pool.removeAll()
    }

    private func makeWindow() -> ScrimWindow {
        let win = ScrimWindow(contentRect: .zero, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        win.isOpaque = true
        win.backgroundColor = fill
        win.hasShadow = false
        // Above normal windows so it covers the parked sliver, but below the
        // menu bar / modal panels. `.floating` is exactly one above `.normal`.
        win.level = .floating
        // Cosmetic only: never trap clicks, never steal focus, never activate.
        win.ignoresMouseEvents = true
        win.isExcludedFromWindowsMenu = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                  .fullScreenAuxiliary]
        // Do not let showing the scrim make ScrollWM the active app.
        win.hidesOnDeactivate = false
        win.alphaValue = 1.0
        return win
    }

    deinit { destroy() }
}
