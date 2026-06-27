# GATE-E — Tileability classification

**Gate:** the eligibility predicate that decides whether a matched, current-Space
window is TILED vs left floating (or made invisible to the manager).
**Files:** `TeleportEngine.adopt` (`subrole==AXStandardWindow && !isMinimized &&
!isFullscreen`, `TeleportEngine.swift:245-247`), the mirror filters in
`LifecycleMonitor.swift:216-219, 413`, and the sibling policy
`FloatingWindows.classify` (`FloatingWindows.swift:50-66`).
**Verification:** `Sources/WindowLab/TileabilityTests.swift`
(`WindowLab unittest` -> "[tileability] GATE-E: 29 passed, 0 failed").

## The core asymmetry
`adopt` (tile) and `classify` (list-in-menu) use DIFFERENT predicates, producing
three user-facing outcomes for a non-`AXStandardWindow` top-level window:
- `AXDialog` / `AXSystemDialog` / `AXFloatingWindow` -> NOT tiled, but LISTED as
  floating (reachable from the menu, never pullable into a column).
- nil subrole / `AXUnknown` / `""` / `AXSystemFloatingWindow` -> NOT tiled AND NOT
  listed -> **completely invisible to the manager.**

NOTE: the user's Ghostty windows ARE `AXStandardWindow` (verified live), so they
PASS this gate. GATE-E is therefore NOT the Ghostty root cause, but it is the
single largest source of OTHER apps' windows "never getting caught."

## Edge cases

### TILE-E1 (P1) — non-standard primary window never tiled
**Trigger:** an app whose MAIN window reports `AXDialog`/`AXFloatingWindow`/
`AXSystemDialog` (some Electron apps, preference-style main windows, certain
utilities, GIMP-style tool windows). **Symptom:** `arrange` lists it as floating
but can never tile it; the user perceives "arrange ignored this window."
**Severity: P1.** **Repro:** `TileabilityTests` "gap: AXDialog -> adopt drops AND
classify lists".

### TILE-E2 (P1) — nil / `AXUnknown` subrole window is invisible
**Trigger:** apps that never set a window subrole — many GLFW/SDL/Java/Electron
primary windows report `subrole == nil` or `AXUnknown`. **Symptom:**
`classify` returns nil -> the window is neither tiled nor listed -> the manager
acts as if it does not exist; the user has NO entry point to it. **Severity: P1**
(worst UX: silent + unreachable). **Repro:** `TileabilityTests` "gap: nil subrole
-> dropped by adopt AND invisible to classify (NOT listed)".

### TILE-E3 (P2) — transient subrole during window creation/animation
**Trigger:** a standard window that briefly reports a non-standard/`AXUnknown`
subrole while opening. **Symptom:** dropped for that cycle -> brief floating on
spawn. **Severity: P2** (self-heals once the subrole settles).

### TILE-E4 (P2) — reveal/adopt asymmetry leaves a de-minimized dialog floating
**Where:** `WindowReveal.shouldUnminimize` keys on ROLE (`AXWindow`) not subrole
(`WindowReveal.swift:37-39`), so "Arrange All" un-minimizes a window whose settled
subrole is `AXDialog`, which `adopt` then drops. **Symptom:** the un-minimized
window floats rather than tiling. **Severity: P2** (by design; documented for
completeness). **Repro:** `TileabilityTests` "reveal->adopt: revealed AXDialog
window still floats".

### TILE-E5 (P2) — all-non-tileable batch -> "arrange did nothing"
**Trigger:** every current-Space window happens to be a dialog/panel/nil-subrole
app. **Symptom:** `adopt` yields an empty strip and the controller logs "no
manageable windows found" (`ScrollWMApp.swift:937`) -> user sees arrange do
nothing. **Severity: P2.** **Repro:** `TileabilityTests` "adopt: all-non-tileable
batch yields empty strip".

## Master-table rows
| ID | Title | Gate / file:line | Trigger | Symptom | Sev | Repro |
|---|---|---|---|---|---|---|
| TILE-E1 | Non-standard primary window never tiled | `TeleportEngine.swift:245-247` | app main window is AXDialog/AXFloatingWindow | listed floating, never tilable | P1 | TileabilityTests gap: AXDialog |
| TILE-E2 | nil/AXUnknown subrole invisible | `FloatingWindows.swift:60-65` | GLFW/SDL/Java/Electron primary windows | neither tiled nor listed -> unreachable | P1 | TileabilityTests gap: nil subrole |
| TILE-E3 | Transient subrole on open | `TeleportEngine.swift:245-247` | standard window briefly non-standard | brief floating on spawn | P2 | code trace |
| TILE-E4 | Reveal un-minimizes a dialog adopt drops | `WindowReveal.swift:37-39` | minimized window with settled AXDialog subrole | floats after "Arrange All" | P2 | TileabilityTests reveal->adopt |
| TILE-E5 | All-non-tileable batch -> empty strip | `ScrollWMApp.swift:936-938` | every window is dialog/panel/nil | "arrange did nothing" | P2 | TileabilityTests empty strip |
