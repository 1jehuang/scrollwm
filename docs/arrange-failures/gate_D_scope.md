# GATE-D — Adoption scope / display partition

**Gate:** `engine.filterByAdoptScope` -> `AdoptionScope.belongsToStripDisplay` /
`AdoptionScope.partition` — decides whether a current-Space window "belongs to
the strip's display."
**Files:** `Sources/WindowLab/AdoptionScope.swift`,
`TeleportEngine.swift:227-238` (`filterByAdoptScope`), callers
`ScrollWMApp.swift:934` (`arrange`), `:963` (`arrangeMultiDisplay`),
`LifecycleMonitor.swift:303,441`.

## Live config
Single display (`LG ULTRAFINE`, `0,0,1920,1080`), `adoptScope=stripDisplay`,
`multiDisplay=false`. On a single display `otherDisplayFrames` is empty, so
`belongsToStripDisplay` short-circuits to `true` (`AdoptionScope.swift:61`) — this
gate is mostly a NO-OP for the user's current setup and is therefore NOT the
Ghostty cause. The edges below bite when a second display is/was attached.

## Edge cases

### SCOPE-D1 (P1) — stale `otherDisplayFrames` after a display unplug
**Where:** `belongsToStripDisplay` only short-circuits when `others.isEmpty`
(`AdoptionScope.swift:61`); `otherDisplayFrames` is set in `bindStrip`
(`ScrollWMApp.swift:876-877`) and only refreshed on a display-config change.
**Trigger:** an external display is disconnected but the strip's engine still
holds the old `otherDisplayFrames` (or `multiDisplay` path leaves a stale frame).
**Symptom:** a window now on the only display can best-overlap the PHANTOM display
and be judged "not mine" -> dropped from adoption -> floats. **Severity: P1.**
**Fix sketch:** rebuild `otherDisplayFrames` from live `NSScreen` at the start of
every `arrange`/`resync`, not only on the display-change notification.

### SCOPE-D2 (P1) — window split across a bezel / mostly on another display
**Where:** `belongsToStripDisplay` keeps a window only if the strip's display
WINS the best-overlap contest (`AdoptionScope.swift:58-67`). **Trigger:** a window
straddling two monitors with >50% on the OTHER one, or sitting in the bezel gap.
**Symptom:** not adopted by the strip's display (and, depending on the other
strip's state, possibly by neither) -> floats. **Severity: P1** on multi-display.
**Fix sketch:** the `partition` fallback (`fallbackIndex`) exists for the
multi-display path; ensure the single-strip `filterByAdoptScope` has an analogous
"adopt if it overlaps me at all and no managing strip claimed it" safety net.

### SCOPE-D3 (P2) — degenerate/off-screen frame kept but then mis-placed
**Where:** `belongsToStripDisplay` returns `true` when a frame overlaps NO display
(`AdoptionScope.swift:63-65`, "never lose a window"). **Trigger:** a window with a
fully off-screen frame (the live `x=-854` parked windows overlap the display 0px).
**Symptom:** it IS kept (good) but is then laid out from a garbage origin; if the
opposite branch (partition with `fallbackIndex == nil`) is ever taken it is
DROPPED instead. **Severity: P2.** **Fix sketch:** normalize off-screen frames to
the strip origin before adoption; always pass a `fallbackIndex` in `partition`.

### SCOPE-D4 (P2) — `multiDisplay` partition assigns a window to exactly one strip
**Where:** `AdoptionScope.partition` gives each window to its best-overlap display
once (`AdoptionScope.swift:112-131`); a dormant/unmanaged target strip means the
window is bucketed to a strip that never adopts it. **Trigger:** `multiDisplay=1`
with a strip that fails to start managing. **Symptom:** the window is "claimed" by
a strip that drops it -> floats. **Severity: P2** (config not in use here).

## Master-table rows
| ID | Title | Gate / file:line | Trigger | Symptom | Sev | Repro |
|---|---|---|---|---|---|---|
| SCOPE-D1 | Stale `otherDisplayFrames` after unplug | `AdoptionScope.swift:61`, `ScrollWMApp.swift:876` | external display disconnected, stale frames retained | window judged "not mine" -> floats | P1 | `AdoptionScope.filter` unit test w/ phantom display |
| SCOPE-D2 | Window mostly on another display | `AdoptionScope.swift:58-67` | window straddles bezel >50% on other monitor | adopted by neither strip -> floats | P1 | `belongsToStripDisplay` unit test |
| SCOPE-D3 | Off-screen frame kept but mis-placed / droppable | `AdoptionScope.swift:63-65,126` | fully off-screen frame (x=-854) | mis-placed, or dropped if fallbackIndex nil | P2 | `partition` unit test |
| SCOPE-D4 | Partition assigns window to a non-managing strip | `AdoptionScope.swift:112-131` | multiDisplay with a dormant target strip | claimed-but-dropped -> floats | P2 | code trace (config off) |
