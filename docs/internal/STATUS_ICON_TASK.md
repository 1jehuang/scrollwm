# Task: status icon must update correctly on ALL events

Goal: the menu-bar status icon (the live mini-map `MenuBarStripView` in the
`NSStatusItem`) AND the floating per-display indicators (`FloatingStripIndicator`)
must repaint promptly and correctly on EVERY event that can change what they
should show, including macOS Space (workspace) switches and monitor changes.

"Refresh" = `ProductionMenuBar.refresh()` (repaints status item + reconciles
floating indicators via `updateIndicators()` -> `controller.indicatorViews()`).
Headless seam to assert it ran: `controller.debugMenuBarRefreshCount`
(`menuBar.refreshCount`, bumped once per `refresh()`).

## Current wiring (verified)

- `wireStripLayoutCallbacks()` points EVERY strip engine's `onLayoutChange` ->
  `menuBar.refresh()` (re-called on `rebuildStripsForAllDisplays`). Good.
- `LifecycleMonitor.onFloatingChange` -> `menuBar.refresh()`. Good.
- Direct `menuBar.refresh()` in: arrange/toggle, `focusDisplay`, `moveFocusedToDisplay`,
  `syncActiveStripToFocus`, `setWidthFraction`, `setAllWidthsFraction`,
  `switchWorkspace`, `moveFocusedToWorkspace`, `refreshDisplayGeometry` (relayout+managing).
- `LifecycleMonitor` observes `NSWorkspace.activeSpaceDidChangeNotification` ->
  debounced `resync()`. `applyResync` only mutates the engine (-> onLayoutChange
  -> refresh) when the strip actually changes; on `frozenDifferentSpace` /
  `skipDegraded` it returns early and refreshes NOTHING.

## Gaps to fix

### G1 — macOS Space (native Desktop) switch
The controller does not itself react to a Space switch. When the user switches
macOS Spaces:
- The mini-map's active-vertical-workspace number and per-display indicator
  "active" highlight can be stale until a hotkey fires.
- On a Space where the strip freezes, no refresh happens at all.
Fix: have the CONTROLLER observe `NSWorkspace.activeSpaceDidChangeNotification`
(debounced, mirroring the monitor) and call `menuBar.refresh()` after the
settle, so the icon re-evaluates regardless of whether the strip mutates. Keep
it cheap and idempotent; do not add a new permission. Provide a headless seam
(e.g. `debugHandleActiveSpaceChange()` or wire it so the existing sim
`activeSpaceDidChange` path reaches it) so a headless test can drive it.

### G2 — Monitor hotplug / rearrange / resolution change
`applySettledDisplayChange(displays:)` rebinds only the ACTIVE strip and only
refreshes when relayout+managing. On a display add/remove the floating
indicators (keyed off `NSScreen.screens`) can go stale, and a background strip's
geometry is not rebound.
Fix:
- Rebind EVERY strip to its resolved display on a settled display change (each
  strip follows its own `displayID`; the active-strip migration logic stays).
- ALWAYS call `menuBar.refresh()` at the end of `applySettledDisplayChange` (even
  when dormant / no relayout) so indicators are created/torn-down to match the
  live screen set.
- The existing `screenParametersChanged` debounce stays (one settle action).
Headless path already exists: `applySettledDisplayChange(displays:)` takes
injected `DisplaySnapshot`s. Add/extend a headless test that asserts a refresh
fires for plug, unplug, and resolution change. Note: indicator PANELS are
suppressed under `AXSource.backend`, but `refresh()`/`refreshCount` still runs,
so the assertion is on `debugMenuBarRefreshCount` and on each strip's rebound
`screenFrame`/`stripDisplayFrame`.

### G3 — Audit completeness
Verify EVERY user-visible state change refreshes the icon. Cross-check this list
and add a `menuBar.refresh()` (or confirm `onLayoutChange` covers it) for any
miss: focus move, width preset, move column, close column, workspace switch,
move-to-workspace, focus-display, move-to-display, arrange/toggle, reload-config,
resync add/remove, floating set change, Space switch (G1), display change (G2),
fullscreen enter/exit suspension.

## Constraints (from AGENTS.md)

- HEADLESS ONLY for tests. Never spawn/move/focus real windows or inject keys.
  Tests install `SimWindowWorld` via `Headless.install()`.
- No private APIs, no new permission. Accessibility only.
- Keep pure logic in pure functions where practical; assert via headless seams.
- Commit as you go with focused messages. Run `make test` before claiming done.
- Deploy step (install.sh + relaunch) is NOT required for this change to be
  "correct"; the coordinator will handle deploy after merge. Focus on code+tests.

## Definition of done

1. G1, G2, G3 implemented.
2. A headless test suite asserts a refresh fires for each event class above,
   registered in `HeadlessHarness.runHeadlessSuite()` verbs + `main.swift`
   dispatch (+ `make test` if a new top-level verb is warranted).
3. `make test` green (unittest + animtest + mmtest + headlesstest + fuzz + statespace).
4. No regressions to existing suites.
