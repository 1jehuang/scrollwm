# GATE-F — ResyncPlanner + applyResync freeze cascade (PRIME CAUSE)

**Gate:** `ResyncPlanner.decide` + `LifecycleMonitor.applyResync`, the path
`scrollwm arrange` takes WHEN ALREADY MANAGING (the user's exact case).
**Files:** `Sources/WindowLab/ResyncPlanner.swift`,
`LifecycleMonitor.swift:191-379` (`resync`/`applyResync`),
`ScrollWMApp.swift:894-900` (the `if isManaging { ... resync ... }` branch).
**Verification:** `Sources/WindowLab/ResyncFreezeTests.swift`
(`WindowLab unittest` -> "[resyncfreeze] GATE-F: 8 passed, 0 failed").

## Why this is THE cause of the live report
The user ran `arrange` while `managing:true`. `arrange()` then takes the
`isManaging` branch (`ScrollWMApp.swift:894`) and calls `strip.lifecycle?.resync()`
for every managing strip — it NEVER runs the cold `engine.adopt()` path. So the
question "why are 42 tileable windows floating" is entirely a `resync` question.
`resync` can adopt ZERO windows in two ways, both reproduced:

### RESYNC-F1 (P0) — `frozenDifferentSpace` cascade strands EVERYTHING
**Where:** `ResyncPlanner.decide` returns `.frozenDifferentSpace` when the strip's
managed tokens still exist in AX but NONE are in `currentSpaceIDs`
(`ResyncPlanner.swift:58-62`); `applyResync` then `return`s immediately
(`LifecycleMonitor.swift:274-277`) — no adds, no removes. **Trigger:** the strip's
OWN columns fail the current-Space test this cycle. Given GATE-C (frame-only
fusion) + GATE-B (parked sliver < 64px), a managed column whose live frame drifted
> 8px from the CG snapshot, or whose parked CG sliver was filtered, drops out of
`currentSpaceIDs` — even though the user is NOT on a different Space. **Symptom:**
the planner concludes "user switched Spaces," freezes, and the dozens of new
standard current-Space windows are never adopted -> they ALL float. This exactly
matches `managing:true` + 1 column + 42 `canTile:true` floating. **Severity: P0.**
**Repro:** `ResyncFreezeTests` F1 (pure) + `BUG(F1 e2e)` (end-to-end through the
real sim/engine/IdentityMatcher: managed column off the current-Space set -> the
brand-new tileable window is NOT adopted).

### RESYNC-F2 (P1) — `skipDegraded` skips the whole cycle
**Where:** `decide` returns `.skipDegraded` when `stripIDs.count >= 4 &&
missing*2 > count` (`ResyncPlanner.swift:71-73`). **Trigger:** a transient AX/
fusion dropout (a slow enumeration under churn — GATE-A2/A3 — or many same-frame
windows mis-fused — GATE-C4/C7) makes more than half of a >=4 column strip look
"gone" for one cycle. **Symptom:** the cycle is skipped wholesale, so any new
current-Space window is not adopted until a healthy cycle -> floats meanwhile;
under sustained churn "healthy" may rarely occur. **Severity: P1.** **Repro:**
`ResyncFreezeTests` F2.

### RESYNC-F3 (P1) — `enumerating` coalesce drops overlapping cycles under churn
**Where:** `resync` sets `enumerating = true` and early-returns any resync
requested while one is in flight (`LifecycleMonitor.swift:197-198`). **Trigger:**
the user's rapid spawn/close of dozens of Ghostty windows fires resyncs faster
than each ~10-260ms enumeration completes. **Symptom:** intermediate states are
never reconciled; windows opened during an in-flight enumeration wait for the next
poll, which may again coalesce away -> prolonged floating. **Severity: P1.**
**Repro idea:** drive `resync()` reentrantly in a headless test and assert a
dropped cycle leaves an un-adopted window (needs a small seam to observe the
coalesce; documented as a follow-up).

### RESYNC-F4 (P2) — additions re-filtered by `standardAdoptable` AND scope
**Where:** even when `.apply` adds tokens, `applyResync` intersects them with
`standardAdoptable` (`LifecycleMonitor.swift:300-302`) and then
`filterByAdoptScope` (`:303/315`). **Trigger:** a window that is on the current
Space but momentarily non-standard (GATE-E3) or judged off-display (GATE-D).
**Symptom:** an add token is still dropped at apply time. **Severity: P2** (a
re-entry of the other gates inside resync; recorded so the apply path is complete).

### RESYNC-F5 (P2) — `stripIDs` token mapping via `firstIndex{CFEqual}`
**Where:** each managed slot maps to the FIRST AX window whose element CFEquals it,
else a negative sentinel (`LifecycleMonitor.swift:264-266`). **Trigger:** a stale/
replaced AX element for a managed window. **Symptom:** the column maps to a
sentinel -> counts as "missing" -> feeds F2's degradation count and can mis-drive
removal. **Severity: P2.**

## Fix direction (this gate)
The freeze/skip guards are CORRECT in intent (don't yank the user across Spaces;
don't mass-remove on an AX hiccup) but are too trusting of the frame-only
current-Space signal. Two changes neutralize the P0:
1. **Make the current-Space signal robust (fix GATE-C/B first):** if managed
   columns are correctly recognized as on-Space, the freeze never false-fires.
2. **Guard the guard:** only treat the strip as `frozenDifferentSpace` when there
   is POSITIVE evidence of a Space switch (e.g. `activeSpaceDidChange`, already
   observed per commit `4232e71`), not merely the absence of fused columns. Absent
   such evidence, prefer `.apply` so new current-Space windows are still adopted.

## Master-table rows
| ID | Title | Gate / file:line | Trigger | Symptom | Sev | Repro |
|---|---|---|---|---|---|---|
| RESYNC-F1 | `frozenDifferentSpace` cascade strands everything | `ResyncPlanner.swift:58-62`, `LifecycleMonitor.swift:274-277` | strip's own columns fail current-Space fusion (GATE-C/B) while still on this Space | resync freezes, dozens of tileable windows never adopted -> float | P0 | ResyncFreezeTests F1 + BUG(F1 e2e) |
| RESYNC-F2 | `skipDegraded` skips whole cycle | `ResyncPlanner.swift:71-73` | >half of a >=4 strip transiently missing (churn/mis-fuse) | cycle skipped -> new windows float until healthy cycle | P1 | ResyncFreezeTests F2 |
| RESYNC-F3 | `enumerating` coalesce drops cycles | `LifecycleMonitor.swift:197-198` | rapid spawn/close faster than enumeration | intermediate windows wait/poll -> prolonged floating | P1 | reentrancy test (follow-up) |
| RESYNC-F4 | Adds re-filtered by adoptable+scope | `LifecycleMonitor.swift:300-315` | add token momentarily non-standard / off-display | add dropped at apply time | P2 | code trace |
| RESYNC-F5 | `stripIDs` CFEqual mapping to sentinel | `LifecycleMonitor.swift:264-266` | stale/replaced managed AX element | column counts "missing" -> feeds F2 | P2 | code trace |
