# 06 — Per-native-Space strips (Model B), SHIPPED

Status: shipped behind `layout.perSpaceStrips` (default OFF). This delivers the
"each macOS Desktop gets its own ScrollWM strip" model from `02_ownership.md`
(Model B), using the documented opt-in to a single READ-ONLY private call for
stable Space identity that `02`/`README` said it would require.

## What shipped

- **`SpaceProbe`** (`Sources/WindowLab/SpaceProbe.swift`): a `dlsym`-resolved,
  READ-ONLY query of the active native-Space id
  (`CGSCopyManagedDisplaySpaces` -> the main display's `Current Space` ->
  `ManagedSpaceID`). It creates/moves/destroys nothing, needs no new permission
  (the Accessibility grant is untouched), and returns `nil` if the symbol is ever
  unavailable so the app silently falls back to the single-strip model. Routed
  through `WindowBackend.currentSpaceID()` so headless tests resolve the
  `SimWindowWorld`'s modeled Space and the real CGS call is reached only in prod.
  This is the **one** deliberate, documented private-API opt-in (AGENTS.md's
  carve-out); it is read-only and isolated. Verify on a real machine with
  `WindowLab spaceprobe`.

- **`TeleportEngine` native-Space layer**: a per-(native Space) axis ABOVE the
  existing vertical-workspace axis. The active Space's strip IS the live
  `slots`/`viewportX`/`focusIndex`/`workspaces`, so every existing path is
  unchanged; inactive Spaces are stashed by stable id in `spaceLayers`.
  - `beginSpaceTracking(spaceID:)` binds the live strip to a Space id.
  - `switchToSpace(id)` stashes the live strip and loads the destination Space's
    strip, re-committing its layout. It **never moves a window across a native
    Space** (macOS owns that): it only re-points in-memory state and re-asserts
    positions. This is the orthogonal-axes rule from `02` §2.2 — vertical
    workspaces park windows (same Space/screen); native Spaces do not.
  - `allSpacesManagedSlots` / `releasePlan` span every tracked Space, so
    crash-restore and Release put back windows stashed on other Desktops too.
  - Empty native Spaces are KEPT (a user-owned Desktop), unlike vertical
    workspaces which auto-prune.

- **`LifecycleMonitor.switchActiveSpaceIfNeeded()`**: on
  `activeSpaceDidChange`, query `SpaceProbe` and `engine.switchToSpace` BEFORE
  the debounced resync, so the resync samples the new Desktop's windows against
  that Desktop's strip. A window opened on any Space tiles there (the old
  "frozen on a different Space" trap, `02` scenarios a/b, is gone).

- **Controller wiring**: `startLifecycle` enables the monitor flag and calls
  `beginSpaceTracking` when `layout.perSpaceStrips` is on and the probe works.
  `RestoreStore.save` persists `allSpacesManagedSlots`.

## Tests (headless, in `make test`)

- `unittest` → `SpaceLayerTests` (27 checks): pure engine model — tracking-off
  default == old model, bind/switch/stash/restore round-trips, no cross-Space
  window bleed, empty Desktops kept, `forgetSpace`, Release clears Space state.
- `perspacetest` (15 checks): REAL controller + monitor + engine + probe vs the
  sim across native Space switches — each Desktop keeps its own columns, a window
  opened on Space 2 is tiled there (not ignored, not leaked to Space 1),
  returning restores Space 1 intact, Release ends tracking.
- `perspacefallbacktest` (4 checks): probe unavailable → arrange still works,
  engine stays single-strip, never crashes.

## Not yet (future)

- Per-display Space keys for multi-strip setups under "Displays have separate
  Spaces" (read each `CGSCopyManagedDisplaySpaces` entry by display UUID; today
  we key on the MAIN display's Space, which is correct for the single live strip
  we bind).
- Space-aware `RestoreStore` (entries still carry no Space tag; `allSpacesManagedSlots`
  makes them all persist, but recover() does not yet defer off-current-Space
  windows — `02` §3).
