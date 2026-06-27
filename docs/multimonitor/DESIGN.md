# Multi-Monitor + Per-Display Indicator + No-Background-Windows — Design

This describes the multi-monitor work that lands the three asks:

1. The status mini-map is visible on monitors that have **no system menu bar**.
2. The multi-monitor seams (per-monitor strips) feel seamless.
3. While managing, you **never see un-arranged windows in the background**.

It builds on the existing per-display foundation (`DisplayStrip`, `multiDisplay`,
`AdoptionScope`, `StripDisplayResolver`, display-aware parking) rather than
re-deriving it.

## 1. Floating per-display indicator

macOS draws the system menu bar on ONE display (unless "Displays have separate
Spaces" is on), so the `NSStatusItem` only shows on that monitor. On every other
monitor you couldn't see ScrollWM's state.

- **`IndicatorPlacement`** (pure, AppKit-free, unit-tested): given each display's
  AX frames + `hasSystemMenuBar` + `isManaging`, returns one `Placement` (panel
  frame in the AX plane) per **managing** display that has **no** system menu
  bar. Top-center, pinned below the visible top edge, clamped on-display. Empty
  for a single display or when nothing qualifies.
- **`FloatingStripIndicator`** (AppKit): a borderless `.nonactivatingPanel` at
  `.statusBar` level, `canJoinAllSpaces + stationary + ignoresCycle +
  fullScreenAuxiliary`, clear background with a rounded translucent capsule,
  `ignoresMouseEvents = true` (pure indicator, clicks pass through), never steals
  focus. Hosts the SAME `MenuBarStripView` the status item uses. Inert in
  headless mode (`AXSource.backend != nil`) so tests never spawn a panel.
- **`ProductionMenuBar`** owns `[CGDirectDisplayID: FloatingStripIndicator]` and,
  on every `refresh()` (and hotplug), reconciles it against
  `controller.indicatorViews()`: create/update/position live panels, tear down
  ones whose display no longer qualifies (released, unplugged, gained a menu
  bar). The active display's panel is highlighted with the accent border.
- Config: `menuBar.showExternalDisplayIndicator` (default on). Only appears with
  >1 display.
- Permission story: public AppKit `NSPanel` only. No Screen Recording, no private
  APIs.
- Verify live: `WindowLab indicatorprobe [seconds]` shows a real panel on each
  menu-bar-less display, then removes it. Confirmed on the real LG-above-built-in
  rig (panel centered at the external's top).

## 2. Multi-monitor seams: focus follows display

Per-display strips already existed (`multiDisplay`, one `DisplayStrip` per
monitor, `focusDisplay`/`moveFocusedToDisplay` verbs). The missing seam was
AUTOMATIC active-strip switching when you click a window on another monitor.

- **`FocusFollowsDisplay`** (pure, unit-tested): `resolveActiveStrip(
  focusedWindowAXFrame:strips:currentActive:)` returns the index of the MANAGING
  strip whose display best-overlaps the OS-focused window, biased to no-switch on
  a tie; nil when nothing should change.
- **Controller** observes `NSWorkspace.didActivateApplicationNotification`, reads
  the focused window's AX frame, and calls `syncActiveStripToFocus()`. On a
  non-nil result it sets `activeStripIndex` and refreshes the menu + indicator
  highlight. It NEVER moves/raises a window (you already focused it). No-op with
  <2 managing strips. Permission-free (public activation edge + AX frame).

## 3. Never see un-arranged background windows

The existing per-strip auto-adopt (resync + fast-adopt) already pulls every
same-display, current-Space, standard window onto the strip. The guarantee on
ALL monitors is therefore delivered by **per-display strips** (each monitor's
strip auto-adopts its own windows). A second sweep over the (non-display-scoped)
floating set would re-introduce the multi-display "yank" bug, so we did NOT add
one.

- Config: `layout.autoTileNewWindows` (default on) gates the EXISTING add path
  (`LifecycleMonitor.autoTileEnabled`). On = a newly opened/revealed standard
  window is auto-tiled onto its monitor's strip so nothing is left floating
  behind it. Off = it stays floating until you tile it from the menu.
- Only the ADD path is gated. Removals, eviction (window dragged to another
  display), size-reconcile, and fullscreen suspension of EXISTING columns always
  run, so managed windows still behave.
- Dialogs / panels / utility palettes are never adopted (not standard windows);
  they stay floating + reachable from the menu.
- Fully reversible: Release restores every window's original frame; dormant never
  touches anything.
- **`AutoTilePolicy`** is the unit-tested pure SPEC of the gate (subrole
  classification delegated to `FloatingWindows.classify`).
- Verify: `WindowLab autotiletest` (a stray standard window is auto-tiled; a
  dialog stays floating; Release restores; flag-off leaves it floating).

## Status / introspection

`scrollwm status` JSON gains a `displays` array (one entry per managed monitor:
index, displayID, managing, active, windowCount, workspace, workspaceCount), so
scripts see every monitor's strip, not just the focused one. Additive.

## Tests

- `WindowLab mmtest` — pure policies (IndicatorPlacement, FocusFollowsDisplay,
  AutoTilePolicy): 33 assertions.
- `WindowLab autotiletest` — no-background guarantee end-to-end (headless).
- `WindowLab displaymovetest` — per-display focus/move + focus-follows-display +
  per-display status (26 assertions).
- `WindowLab indicatorprobe` — live visual check of the floating panel.

## Coordinate plane reminder

Everything geometric is in the engine's AX plane (top-left origin, Y down).
`DisplayGeometry.axFrame`/`appKitFrame` flip around the primary display height;
the indicator panel converts AX -> AppKit at display time.
