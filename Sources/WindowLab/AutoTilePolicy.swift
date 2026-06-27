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
    /// STUB returns false (no auto-tiling). Worker C: tile only `.tileable`
    /// windows (standard subrole, on current Space, not minimized/fullscreen/
    /// self, not already managed), gated on `enabled` (config) and `managing`.
    static func shouldTile(subrole: String?,
                          isMinimized: Bool,
                          isFullscreen: Bool,
                          onCurrentSpace: Bool,
                          isSelf: Bool,
                          alreadyManaged: Bool,
                          enabled: Bool,
                          managing: Bool) -> Bool {
        _ = (subrole, isMinimized, isFullscreen, onCurrentSpace,
             isSelf, alreadyManaged, enabled, managing)
        return false
    }
}

/// STUB test entrypoint — worker C replaces with real assertions.
enum AutoTilePolicyTests {
    static func run() -> Bool {
        print("[mmtest] AutoTilePolicy: STUB (no assertions yet)")
        return true
    }
}
