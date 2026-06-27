import Foundation
import ApplicationServices

/// PURE policy for the "no un-arranged windows in the background" guarantee:
/// while ScrollWM is MANAGING a display, any standard top-level window that is
/// on the current Space but NOT on the strip should be auto-tiled (adopted)
/// onto that display's strip, so the user never sees a stray window floating
/// behind the strip. Dialogs / panels / utility palettes are NEVER auto-tiled
/// (they stay floating, reachable from the menu); off-Space, minimized,
/// fullscreen and the manager's own windows are skipped.
///
/// STUB — owned by swarm worker C. Replace this whole file with the real
/// implementation + `AutoTilePolicyTests`. This mirrors `FloatingWindows`
/// classification but answers a different question: "should the lifecycle
/// monitor pull this floating window onto the strip THIS cycle?" Reuse
/// `FloatingWindows.classify` where possible; do not duplicate subrole sets.
enum AutoTilePolicy {

    /// PURE decision for one candidate window. Returns true when the window
    /// should be auto-tiled onto the strip now.
    ///
    /// Tiles ONLY a `.tileable` window (standard top-level subrole) that is on
    /// the current Space, not minimized/fullscreen, not the manager's own, and
    /// not already managed - gated by `enabled` (config) AND `managing` (a
    /// dormant ScrollWM must NEVER touch anything). Dialogs / panels / floating
    /// palettes (`.listOnly` in `FloatingWindows`) are never auto-tiled: they
    /// stay floating and reachable from the menu. Classification is delegated to
    /// `FloatingWindows.classify` so the subrole rules live in exactly one place.
    static func shouldTile(subrole: String?,
                          isMinimized: Bool,
                          isFullscreen: Bool,
                          onCurrentSpace: Bool,
                          isSelf: Bool,
                          alreadyManaged: Bool,
                          enabled: Bool,
                          managing: Bool) -> Bool {
        // Master gates first: never act while disabled or dormant, and never
        // re-tile a window the strip already owns.
        guard enabled, managing, !alreadyManaged else { return false }
        // Reuse the floating classifier: only a genuinely TILEABLE window (a
        // standard window on the current Space, not min/fullscreen/self) qualifies.
        return FloatingWindows.classify(
            subrole: subrole,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            onCurrentSpace: onCurrentSpace,
            isSelf: isSelf
        ) == .tileable
    }

    /// Convenience over `shouldTile`: from a `FloatingWindows` set the lifecycle
    /// monitor already computed, return the ones to auto-tile this cycle (the
    /// `.tileable` ones), gated by config + managing. Off-Space / min / dialog
    /// windows are already excluded from the floating set, and every entry is
    /// unmanaged by construction, so this only re-applies the enable/manage gate
    /// and the tileable filter.
    static func windowsToTile(_ floating: [FloatingWindow],
                             enabled: Bool,
                             managing: Bool) -> [FloatingWindow] {
        guard enabled, managing else { return [] }
        return floating.filter { $0.canTile }
    }
}
