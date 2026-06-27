# External-Monitor Fixes — handoff (branch `emt-deploy`)

Branch `emt-deploy` = team commit `79df444` + 4 commits below. Pushed to
`origin/emt-deploy`. Already BUILT + INSTALLED + RELAUNCHED live as
`~/Applications/ScrollWM.app` v0.1.7 (the user is running the fix now).

## Why a separate branch
The main `/Users/jeremy/scrollwm` checkout was being edited concurrently by
several other jcode sessions (uncommitted WIP in HeadlessTests/LifecycleMonitor/
ScrollWMApp/TeleportEngine). To avoid clobbering them I worked in isolated git
worktrees and cherry-picked onto the latest COMMITTED main (`79df444`). Merge
`emt-deploy` into the team branch when that WIP settles. Only one production file
overlaps their dirty set: `LifecycleMonitor.swift` (my eviction hook in
`applyResync` + new engine methods; localized, should merge cleanly).

## Commits
1. `68d03d1 fix(display): evict a managed window dragged onto another monitor`
   - THE behavioral fix. Pure policy `AdoptionScope.evictedFromStripDisplay` +
     engine `TeleportEngine.evictDraggedOffDisplay`/`slotIsParked`, wired into
     `LifecycleMonitor.applyResync` after removals. Under `stripDisplay` scope a
     managed column whose fresh AX frame best-overlaps another display is dropped
     (left where the user put it), never yanked back. Parked columns exempt;
     `allDisplays`/single-display never evict. Sim gains `debugSetFrame`.
   - Test `dragofftest` (negative-control verified: 3 fails without the fix).
2. `2e1e981 test: lock single-strip adoption scoping vs the external` (`extadopttest`)
   - Proves arrange/fast-adopt/resync only adopt built-in windows, never the
     external. (Confirmed already-correct; locks it for the real geometry.)
3. `2ac40e1 test: pin parked-sliver placement vs the external` (`parktest`)
   - Parked clamp sliver stays on the strip display for the real above-left
     external AND a side-by-side rearrangement. (Confirmed already-correct.)
4. `2da9d92 test: cover unplug/replug/migrate for the above-left external`
   (`exthotplugtest`) - strip stays on built-in when the external is unplugged/
   replugged; migrates to the external when the built-in is unplugged; no window
   stranded; eviction does NOT misfire on a redundant display change.

## Validation
- All 16 headless suites green (`headlesstest`), `unittest` green.
- `fuzz`/`fuzzmodel`/`fuzzdisp`(120 seeds)/`fuzzconc`/`statespace` green.
- `fuzzctrl`: one PRE-EXISTING load-induced timing flake (seed 2199023256423,
  width model-vs-real desync) that does NOT reproduce on deterministic replay and
  passes 5/5 in isolation on BOTH this branch and clean `79df444`. It is a
  single-display fuzz where the eviction is a guarded no-op, so it is unrelated
  to these changes.

## Real hardware these are grounded in
Built-in primary AX `(0,0,1710x1112)`; external LG ULTRAFINE above-and-left AX
`(-105,-1080,1920x1080)`. User config: multiDisplay=false, adoptScope=stripDisplay.
