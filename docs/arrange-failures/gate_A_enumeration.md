# GATE-A — Window enumeration

**Gate:** `AXSource.allWindows()` / `AXSource.windows(forPID:)` — the very first
step that decides which windows even ENTER the pipeline.
**Files:** `Sources/WindowLab/AXSource.swift`, callers in
`ScrollWMApp.swift:913` (`arrange`), `LifecycleMonitor.swift:206-211` (`resync`),
`:410-414` (`fastAdopt`).

## Live evidence
- 38 `.regular` apps, **39 `.accessory`**, **32 `.prohibited`** running right now.
  `allWindows()` enumerates ONLY `.regular`, so 71 apps are invisible to arrange.
- None of the accessory/prohibited apps currently own a normal layer-0 window, so
  this edge is LATENT on this machine but fires for any agent/utility app that
  does (many Electron helpers, menu-bar apps that open a real window, some IDE
  helper processes).

## Edge cases

### ENUM-A1 (P1) — `.accessory` / `.prohibited` apps are never enumerated
**Where:** `AXSource.allWindows()` filters `activationPolicy == .regular`
(`AXSource.swift:205`). **Trigger:** an app that runs as an agent/accessory
(`LSUIElement`, or one that calls `setActivationPolicy(.accessory)`) but still
opens a normal, on-screen, standard window the user wants tiled. **Symptom:** the
window never enters `arrange`/`resync` at all -> not tiled and not even listed as
floating (floating uses the same `allWindows()` enumeration). **Severity: P1**
(common for Electron/utility apps; invisible failure). **Fix sketch:** for the
floating/adopt enumeration, union `.regular` with `.accessory` apps that actually
own a standard on-screen CG window, instead of gating purely on activation policy.

### ENUM-A2 (P1) — per-app AX messaging timeout silently yields `[]`
**Where:** `windowsFromAppElement` sets a 0.15s messaging timeout
(`AXSource.swift:172, 179`); if `kAXWindowsAttribute` does not return in time the
`guard err == .success ... else { return [] }` drops ALL of that app's windows.
**Trigger:** a cold/busy/beachballing app (or the cross-process AX call queuing
behind dozens of other Ghostty processes — the user spawns DOZENS). **Symptom:**
that app's windows vanish from this arrange cycle -> floating until a later cycle
catches them; under sustained load they can be perpetually skipped. **Severity:
P1.** **Fix sketch:** distinguish "timeout" from "no windows" (retry the timed-out
app next tick rather than treating empty as authoritative); raise/adaptively tune
the timeout; parallelize per-app enumeration so one slow app cannot starve others.

### ENUM-A3 (P1) — enumeration cost scales with app/window count (churn starvation)
**Where:** `allWindows()` loops every regular app serially on the calling queue
(`AXSource.swift:209-219`). **Trigger:** the user's exact scenario — dozens of
Ghostty processes, each its own PID, each a separate cross-process AX round-trip.
Total enumeration time grows with process count; under rapid spawn/close the
`enumerating` coalesce (GATE-F/G) then drops overlapping cycles. **Symptom:**
new windows are not adopted promptly and pile up as floating. **Severity: P1.**
**Fix sketch:** cache per-PID window lists keyed off `kAXWindowCreated/Destroyed`
events so a full sweep is rarely needed; batch/parallelize the AX reads.

### ENUM-A4 (P2) — `compactMap` drops a window if EITHER position OR size read fails
**Where:** `windowsFromAppElement` returns `nil` for a window when `copyPoint`
OR `copySize` fails (`AXSource.swift:180-183`). **Trigger:** a window mid-creation
that has published one geometry attribute but not the other, or a transient AX
read failure. **Symptom:** the window is omitted from this cycle. **Severity: P2**
(usually self-heals next cycle, but contributes to spawn-time floating). **Fix
sketch:** fall back to a zero/origin frame + retry next tick rather than dropping;
or treat a readable element with partial geometry as "exists, geometry pending."

### ENUM-A5 (P2) — non-deterministic enumeration order
**Where:** `allWindows()` appends per `NSWorkspace.runningApplications` order,
which is not stable. **Trigger:** any multi-window cycle. **Symptom:** not a drop
per se, but combined with GATE-C greedy matching and GATE-F token mapping, order
churn can change which window wins an ambiguous match cycle-to-cycle (flapping).
**Severity: P2.**

## Master-table rows
| ID | Title | Gate / file:line | Trigger | Symptom | Sev | Repro |
|---|---|---|---|---|---|---|
| ENUM-A1 | `.accessory`/`.prohibited` apps never enumerated | `AXSource.swift:205` | agent/Electron app opens a real standard window | never tiled, never listed floating | P1 | live: 39 accessory + 32 prohibited apps running |
| ENUM-A2 | 0.15s AX timeout yields `[]` for whole app | `AXSource.swift:172-183` | cold/busy app or AX queue saturated by dozens of PIDs | app's windows skipped this cycle -> float | P1 | code trace; load-correlated |
| ENUM-A3 | Serial enumeration starves under churn | `AXSource.swift:209-219` | dozens of Ghostty PIDs spawning/closing | new windows pile up floating | P1 | matches live churn signature |
| ENUM-A4 | `compactMap` drops on partial geometry read | `AXSource.swift:180-183` | window mid-creation, one attr unpublished | window omitted this cycle | P2 | code trace |
| ENUM-A5 | Non-deterministic enumeration order | `AXSource.swift:209` | any multi-window cycle | ambiguous-match flapping | P2 | code trace |
