# ScrollWM x native macOS Spaces — investigation brief

Goal: figure out EVERYTHING ScrollWM must handle to get native macOS Spaces
(Mission Control "Desktops"/Spaces, NOT ScrollWM's own vertical workspaces)
completely right. This is an INVESTIGATION + DESIGN pass. Produce findings docs
under `docs/spaces/`; do NOT ship behavior changes yet unless explicitly told.
The end deliverable is a single consolidated design + gap list the human can act
on, backed by reproductions/tests where feasible.

## Current architecture (already established — don't re-derive, build on it)

- ScrollWM has **NO direct Space-change signal**. It never observes
  `NSWorkspace.activeSpaceDidChangeNotification` (or any Space API). It INFERS
  "current Space" by intersecting AX windows (which span ALL Spaces) with the
  WindowServer on-screen list (`CGWindowSource.listWindows(onscreenOnly:true)` =
  current Space's visible windows). See `CGWindowSource.swift`,
  `IdentityMatcher`, `LifecycleMonitor.applyResync`.
- Reconciliation cadence: `kAXWindowCreated` fast-adopt + NSWorkspace
  launch/terminate + **2s safety-net poll** (`LifecycleMonitor.interval`).
- Space policy is the PURE `ResyncPlanner.decide(stripIDs, axIDs, currentSpaceIDs)`:
  - `frozenDifferentSpace`: strip windows still exist in AX but NONE are on the
    current Space -> stay inert.
  - `skipDegraded`: AX lost most of the strip at once -> skip (lock-screen edge).
  - `apply(remove, add)`: drop closed, adopt new current-Space windows.
- One strip PER DISPLAY (`DisplayStrip`), NOT per Space. A strip is bound to a
  display via `bindStrip`. There is no notion of "which Space this strip belongs
  to". `arrange` adopts current-Space windows (`$0.cg != nil`) and scopes them to
  the strip's display (`AdoptionScope` / `engine.filterByAdoptScope`).
- ScrollWM's own "vertical workspaces" are an INTERNAL strip concept
  (`engine.workspaceCount`, Cmd+J/K), unrelated to macOS Spaces. Don't conflate.
- Overlay window: `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
  .stationary, .ignoresCycle]` (`MetalOverlay.swift:385`).
- Hard contract (AGENTS.md): NO private APIs, ONE permission (Accessibility).
  Screen Recording / Input Monitoring / private frameworks (incl. SkyLight/CGS
  Space APIs) are OFF LIMITS unless an explicit, documented opt-in is proposed
  and justified. Call out anywhere a correct fix is *impossible* without one.

## Golden testing rule

NEVER arrange the user's real windows. Headless sim (`SimWindowWorld` /
`WindowBackend`) is the default test path and is safe anytime. `WindowLab sandbox N`
is live but hard-locked to spawned throwaway windows. Live Space switching to
reproduce a bug is acceptable but use sandbox windows + your OWN test Spaces; do
NOT rearrange the user's real session.

## Build/test

- `swift build`
- `make test` (unittest + animtest + headlesstest) — must stay green
- `.build/debug/WindowLab headlesstest` / `unittest`
- `.build/debug/WindowLab sandbox 4` (live, isolated)

## Output format (every worker)

Write `docs/spaces/NN_<track>.md` with:
1. Findings (what macOS actually does; what ScrollWM does today).
2. Concrete bugs / gaps (repro steps; headless or sandbox).
3. Design recommendation (public-API only; flag any private-API-only cases).
4. Proposed tests (sim extensions / assertions) — implement reproductions where
   you can without touching real windows.
Keep claims backed by code refs (file:line) or an actual repro.
