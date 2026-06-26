import Foundation
import CoreGraphics

/// One scrolling strip bound to ONE physical display. ScrollWM keeps an array of
/// these (one per managed display) so each monitor gets its own independent
/// PaperWM-style strip: its own column layout, viewport, vertical workspaces,
/// and lifecycle monitor. Navigation/width/move/workspace hotkeys act on
/// whichever strip the user's focus is currently on ("focus follows display").
///
/// This is a thin bundle, not logic: the real model lives in `TeleportEngine`
/// (unchanged, still single-strip) and adoption sync in `LifecycleMonitor`. By
/// keeping one engine + one monitor PER display we reuse every existing,
/// well-tested per-strip code path verbatim and only add a routing layer above
/// them. On a single-display setup `strips` has exactly one entry, so behavior
/// is identical to the historical single-engine controller.
final class DisplayStrip {
    /// The strip model for this display. Each display owns its own engine, so
    /// columns/viewport/workspaces never bleed across monitors.
    let engine: TeleportEngine

    /// Stable id of the physical display this strip is bound to. Tracked so a
    /// monitor hotplug / rearrange can follow the strip by identity (the same
    /// reasoning as the old single-strip `stripDisplayID`). `nil` until bound.
    var displayID: CGDirectDisplayID?

    /// Per-strip adoption sync. Each display runs its own `LifecycleMonitor` so a
    /// window created on monitor A is adopted into A's strip and a window on B
    /// into B's, driven by each engine's own `filterByAdoptScope` display
    /// geometry. `nil` while this strip is dormant (not yet arranged).
    var lifecycle: LifecycleMonitor?

    init(engine: TeleportEngine, displayID: CGDirectDisplayID? = nil) {
        self.engine = engine
        self.displayID = displayID
    }
}
