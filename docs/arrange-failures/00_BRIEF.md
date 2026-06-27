# Arrange Failure Audit — Brief

## The complaint
User ran `scrollwm arrange` and it "didn't arrange everything — there are
windows which are still floating that it never caught." Goal: **comprehensively
enumerate every edge case where a window the user expects to be tiled is left
floating / never adopted into the strip.**

## Ground truth captured live (2026-06-27, this machine)
- Single display: `LG ULTRAFINE`, AX frame `(0,0,1920,1080)`, visible `(0,0,1920,1050)`.
- Config: `adoptScope=stripDisplay`, `multiDisplay=false`, `spawnWidth=0.5`,
  `fillHeight=true`, `peekInset=48`, `minColumnWidth=200`.
- App churns dozens of **Ghostty** windows (each Ghostty = its own PID, 1 AX
  window, `AXStandardWindow`, not minimized).
- **Smoking gun snapshot:** `status` returned `managing:true`, **1 tiled column**,
  but **`floatingCount:42`, every one `canTile:true`** (standard, current-Space,
  eligible to tile, but never adopted). Raw CG showed ~35 Ghostty windows parked
  at off-screen strip X positions (`x=-854`, `x=1880`), MANY at *identical*
  frames, many titled `~`.
- State is highly volatile: seconds later it read `5 cols / 0 floating`. So the
  failure is intermittent and correlated with rapid window churn (spawn/close).

The user's `arrange` was invoked **while already managing**, so it went through
`LifecycleMonitor.resync()` (the `isManaging` branch of `arrange`), NOT the
cold `engine.adopt()` path. Both paths must be audited.

## The pipeline (every gate a window can be silently dropped at)
`scrollwm arrange` (controller) →
1. **Enumeration** — `AXSource.allWindows()` (only `.regular` apps; per-app AX
   messaging timeout 0.15s) OR `windows(forPID:)`.
2. **CG candidate filter** — `CGWindowInfo.looksManageable` (layer==0, alpha>0.05,
   w≥64, h≥64) + `onscreenOnly` (current-Space proxy).
3. **Identity match** — `IdentityMatcher.match` (PID+frame+title score ≥ 50);
   unmatched AX window gets `cg == nil`.
4. **Current-Space gate** — `matched.filter { $0.cg != nil }`; an AX window that
   failed identity match is treated as off-Space and dropped.
5. **Adopt scope** — `engine.filterByAdoptScope` / `AdoptionScope.belongsToStripDisplay`
   (drops windows that best-overlap another display).
6. **Tileability** — `engine.adopt` keeps only
   `subrole==AXStandardWindow && !isMinimized && !isFullscreen`.
7. **Resync planner** — `ResyncPlanner.decide`: `frozenDifferentSpace` /
   `skipDegraded` can adopt **nothing** this cycle.
8. **Fast-adopt** — `LifecycleMonitor.fastAdopt` (event path): bounded retries,
   `stripIsOnCurrentSpace` bail, `enumerating` coalesce drop.
9. **Workspace parking** — managed windows in inactive vertical workspaces are
   parked off-screen but still appear in CG on-screen list (the "sliver").

## How to verify (headless, safe — never touches real windows)
```
cd /Users/jeremy/scrollwm
swift build
.build/debug/WindowLab headlesstest     # all integration suites
.build/debug/WindowLab unittest          # pure logic
```
Headless seam: `SimWindowWorld` installed as `AXSource.backend` drives the REAL
engine/controller. See `Sources/WindowLab/SimWindowWorld.swift`,
`HeadlessHarness.swift`, `FuzzController.swift` for how to seed windows + arrange
and assert adopted counts. **Never run `WindowLab run`/`cycle` or arrange the
real session while auditing** (AGENTS.md golden rule). Live read-only status is
fine: `echo status | nc -U "$HOME/Library/Application Support/ScrollWM/control.sock"`.

## Deliverable per agent
Append your section to `docs/arrange-failures/FINDINGS.md`. For EVERY edge case:
- **ID** (e.g. `MATCH-3`), one-line title.
- **Gate / file:line** where the window is dropped.
- **Trigger** — the concrete real-world condition (be specific).
- **Symptom** — what the user sees (floating? invisible? wrong display?).
- **Severity** — P0 (loses real windows often) / P1 / P2.
- **Repro** — headless test idea or a code path trace; write an actual failing
  test under `Sources/WindowLab/` if feasible and note its name.
- **Fix sketch** — minimal, idiomatic, matching repo conventions.
Be exhaustive. Prefer a verifiable repro over speculation.
