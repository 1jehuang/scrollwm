# Multi-Display Swarm Brief (ScrollWM)

You are one of several parallel agents adding full external-monitor support to
ScrollWM. A human has a REAL external monitor connected RIGHT NOW, so live
testing is possible — but obey the GOLDEN RULE below.

## Your isolation
You work in your OWN git worktree on your OWN branch (`feature/md-<area>`),
forked from `feature/multi-display` (the foundation commit). Do NOT touch other
worktrees. Commit to your branch only. The coordinator merges everything.

## Foundation already in place (read these first)
- `Sources/WindowLab/DisplayGeometry.swift` — PURE helpers (no AppKit):
  `axFrame`/`appKitFrame` (AppKit bottom-left <-> AX top-left flip around
  primaryHeight), `overlapArea`, `display(bestOverlapping:)`,
  `display(containing:)`, `isMostlyVisible`, `clamp(_:into:)`,
  `ensureVisible(_:displays:)`. USE THESE; do not re-derive coordinate flips.
- `TeleportEngine.screenFrame` is now `private(set) var` (mutable).
- `TeleportEngine.rebindStripDisplay(to:)` relays the strip onto new geometry.
- `ScrollWMController.refreshDisplayGeometry(stripDisplay:relayout:)` and
  `screenParametersChanged()` already re-bind the strip on display changes and
  set `engine.stripDisplayFrame` / `engine.otherDisplayFrames`.

## The real hardware (for grounding tests)
- Built-in Retina: AppKit `(0,0,1470x956)` = PRIMARY + main. AX frame `(0,0,..)`.
- External Samsung 5K (scaled 2560x1440): AppKit `(-225, 956, 2560x1440)` =
  ABOVE-and-left of built-in. AX frame `(-225, -1440, 2560, 1440)` (negative Y!).
- `spans-displays=1` (one Mission Control Space spans both monitors).

## GOLDEN RULE — never touch the user's real windows
Test with sandbox / spawned disposable windows ONLY. The production controller
is hard-locked to `sandboxPIDs`. Use `.build/debug/WindowLab sandbox [n]` and the
`opstest`/`e2etest`/`unittest`/`spawnlatency` harnesses. NEVER run a bare
`WindowLab run` + Arrange against the live desktop, and NEVER call `arrange()`
without a PID filter in a test.

## Required before you report done
1. `swift build` clean (no warnings you introduced).
2. `.build/debug/WindowLab unittest` green (ADD tests for anything you change;
   prefer extracting PURE functions so logic is unit-testable without AX).
3. `.build/debug/WindowLab e2etest` green (real controller, synthetic hotkeys).
4. Commit to your branch with focused messages explaining WHY.
5. Report: what you changed, new tests, how you verified, any cross-cutting
   risk the coordinator must reconcile at merge.

## Coordination
- Shared files most likely to collide: `ScrollWMApp.swift`, `Config.swift`,
  `ControlCommands.swift`, `ControlCLI.swift`, `main.swift`, `StripOpsTests.swift`.
  Keep edits minimal and localized; put new logic in NEW files where you can
  (pure modules!). Note any edits to these in your final report so the
  coordinator can merge cleanly.
- If you add a pure policy, add it as its own type (like `ResyncPlanner`) so it
  is unit-testable and merge-friendly.
- Use `swarm report` (status=ready) when finished, summarizing for merge.
