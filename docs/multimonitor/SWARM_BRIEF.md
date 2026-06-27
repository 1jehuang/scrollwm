# Multi-Monitor + Per-Display Indicator + No-Background-Windows — Swarm Brief

You are ONE worker in a swarm improving ScrollWM's multi-monitor experience.
The user's three asks (verbatim intent):

1. **Indicator on external monitors.** The status mini-map only shows in the
   system menu bar, which macOS draws on ONE display. On a second monitor (no
   menu bar) the user can't see ScrollWM's state. Add a floating per-display
   mini-map so the indicator is visible on every managed monitor.
2. **Great multi-monitor seams.** Per-monitor (and per-desktop) strips should
   feel seamless: focus-follows-display, hotkey routing, hotplug, parking on the
   strip's own display. Much of this already exists (`DisplayStrip`,
   `multiDisplay`, `focusDisplay`, `StripDisplayResolver`); we are POLISHING it.
3. **Never see un-arranged / background windows.** While managing, no standard
   window should be left floating behind the strip on any managed display.

## GOLDEN RULE — never touch the user's real windows
The user has a REAL external monitor connected right now. Test with the HEADLESS
sim (`WindowLab unittest`/`mmtest`/`headlesstest`) ONLY, or `WindowLab sandbox N`
(hard-locked to spawned throwaway windows). NEVER run `WindowLab run` + Arrange
against the live desktop, and NEVER call `arrange()` without a PID filter.

## Your isolation (CRITICAL — avoid merge collisions)
- You work in YOUR OWN git worktree on YOUR OWN branch. The coordinator gave you
  the path. Commit ONLY to your branch.
- You OWN exactly ONE new file (named in your task). Replace its STUB body with
  the real implementation + its `*Tests` type. Do NOT edit ANY other file —
  especially the big shared ones (`ScrollWMApp.swift`, `Config.swift`,
  `LifecycleMonitor.swift`, `main.swift`, `ControlCommands.swift`,
  `MenuBarStripView.swift`). The coordinator does ALL integration into shared
  files after you report. If you think a shared file MUST change, write it in
  your report instead of editing it.
- Keep the PUBLIC SHAPE (type/func signatures) in your file stable. You may add
  fields/funcs; do not rename or remove the documented ones without telling the
  coordinator (other workers + the integration code call them).

## Architecture you build on (read these first)
- `DisplayGeometry.swift` — PURE coord helpers. AX plane = top-left origin, Y
  down. `axFrame`/`appKitFrame` flip around `primaryHeight`. `overlapArea`,
  `display(bestOverlapping:)`, `clamp`, `ensureVisible`. USE THESE.
- `DisplayStrip.swift` — one `{engine, displayID, lifecycle, isManaging}` per
  managed display. `ScrollWMController.strips` is the array; `activeStripIndex`
  is the focused one.
- `AdoptionScope.swift` — pure adopt/evict/partition policy per display.
- `TeleportEngine.swift` — the per-strip model. `stripState` is the menu-bar
  snapshot. `computeParkingX` keeps parked slivers on the strip's own display.
- `FloatingWindows.swift` — pure classify of "windows on this Space not on the
  strip". REUSE its subrole sets; do not duplicate them.
- `MenuBarStripView.swift` — the animated mini-map view (springs + flourishes).
  Reused by both the status item and the floating indicator.
- `MenuBarAnimationRender.swift` — shows how to render a `MenuBarStripView`
  offscreen to a bitmap (`cacheDisplay`), useful for a visual smoke test.
- Real hardware right now: built-in primary AX `(0,0,1710x1112)`, menu bar ~39pt;
  external LG ULTRAFINE above-left AX `(-105,-1080,1920x1080)`, NO menu bar.

## Build / test (must stay green before you report)
- `swift build` — clean, no new warnings.
- `.build/debug/WindowLab mmtest` — your lane + the others (all pure, headless).
- `.build/debug/WindowLab unittest` — must stay green if you touched anything it
  covers (you shouldn't, since you own one new file).
- ADD real assertions to your `*Tests.run()` — negative controls where you can
  (prove the test fails without your logic). Aim for thorough edge-case coverage
  (above/left external with negative AX Y, single display, 3 displays, hotplug,
  ties, degenerate frames).

## Report (use `swarm report`, status=ready)
Include: what you implemented, the exact public API you settled on (signatures),
every test you added + how you verified (paste the `mmtest` pass line), and a
crisp **INTEGRATION NOTE** telling the coordinator exactly how to wire your
module into the controller (which call site, when to call it, any shared-file
edit you recommend). Flag any cross-worker dependency.
