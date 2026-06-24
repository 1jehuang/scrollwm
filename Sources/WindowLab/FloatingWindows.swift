import Foundation
import ApplicationServices

/// A window that is open on the user's CURRENT Space but is NOT tiled on the
/// strip - what the user perceives as a "floating" window (a save dialog, a
/// tool palette, a utility panel, or a normal window the strip has not adopted
/// yet). Surfaced in the menu bar so every on-screen window stays reachable.
struct FloatingWindow {
    /// The underlying AX view of the window (carries the element used to raise
    /// it, and the real frame used if it is pulled onto the strip).
    let info: AXWindowInfo
    /// True for a normal top-level window (standard subrole): it COULD be tiled
    /// onto the strip. Dialogs / panels are listed so the user can jump to them,
    /// but are never tiled (moving a modal sheet into a column is wrong).
    let canTile: Bool

    var pid: pid_t { info.pid }
    var appName: String { info.appName }
    var title: String { info.title ?? "(untitled)" }
    var element: AXUIElement { info.element }
}

/// PURE policy for "which open windows are floating (not on the strip)".
///
/// Factored out of `LifecycleMonitor` so the rules are unit-testable without
/// Accessibility permission or real windows: `classify` is a total function of
/// plain values, and `compute` is a thin assembler over it.
enum FloatingWindows {
    /// Standard top-level windows can be tiled onto the strip.
    static let tileableSubroles: Set<String> = [kAXStandardWindowSubrole as String]

    /// Dialogs / panels are LISTED (so the user can jump to them) but never
    /// tiled - tiling a modal sheet or a floating palette would be surprising
    /// and often impossible.
    static let listableSubroles: Set<String> = [
        kAXDialogSubrole as String,
        kAXSystemDialogSubrole as String,
        kAXFloatingWindowSubrole as String,
    ]

    enum Kind: Equatable { case tileable, listOnly }

    /// PURE per-window classification. Returns nil when the window should NOT be
    /// surfaced as floating at all.
    ///
    /// We deliberately require `onCurrentSpace`: the AX API enumerates windows
    /// across EVERY Space, so without the current-Space gate (the WindowServer's
    /// on-screen list) we would list windows the user cannot even see and
    /// mislabel them as "floating here".
    static func classify(
        subrole: String?,
        isMinimized: Bool,
        isFullscreen: Bool,
        onCurrentSpace: Bool,
        isSelf: Bool
    ) -> Kind? {
        // The manager's own menu-bar / tutorial windows, off-Space windows,
        // minimized and fullscreen windows are never "floating on this Space".
        if isSelf || isMinimized || isFullscreen || !onCurrentSpace { return nil }
        guard let subrole else { return nil }
        if tileableSubroles.contains(subrole) { return .tileable }
        if listableSubroles.contains(subrole) { return .listOnly }
        // Anything else (unknown subrole, content views, sheets attached to a
        // parent, etc.) is intentionally not surfaced.
        return nil
    }

    /// Build the floating list from a full AX enumeration fused with the
    /// on-screen (current-Space) CG list.
    ///
    /// - Parameters:
    ///   - axWindows: ALL standard+non-standard AX windows (across every Space).
    ///   - cgWindows: the WindowServer on-screen list (current Space only); a
    ///                successful fuse is our current-Space signal.
    ///   - managed: AX elements already on the strip (compared by `CFEqual`),
    ///              excluded so a tiled window never double-appears as floating.
    ///   - selfPID: the manager's own process, so its windows are never listed.
    static func compute(
        axWindows: [AXWindowInfo],
        cgWindows: [CGWindowInfo],
        managed: [AXUIElement],
        selfPID: pid_t
    ) -> [FloatingWindow] {
        let matched = IdentityMatcher.match(axWindows: axWindows, cgWindows: cgWindows)
        var out: [FloatingWindow] = []
        for m in matched {
            if managed.contains(where: { CFEqual($0, m.ax.element) }) { continue }
            guard let kind = classify(
                subrole: m.ax.subrole,
                isMinimized: m.ax.isMinimized,
                isFullscreen: m.ax.isFullscreen,
                onCurrentSpace: m.cg != nil,
                isSelf: m.ax.pid == selfPID
            ) else { continue }
            out.append(FloatingWindow(info: m.ax, canTile: kind == .tileable))
        }
        return out
    }
}
