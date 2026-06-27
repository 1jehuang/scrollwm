# GATE-B — CG candidate filter + current-Space gate

**Gate:** `CGWindowInfo.looksManageable` + the `onscreenOnly` list, used as the
"is this window on the current Space?" oracle (`cg != nil`).
**Files:** `Sources/WindowLab/CGWindowSource.swift` (`looksManageable:18-23`,
`listWindows:29-67`), consumers at `ScrollWMApp.swift:917,922`,
`LifecycleMonitor.swift:220,432`, `IdentityMatcher.swift:48`,
`FloatingWindows.swift:92`.

## Live evidence
- Onscreen window layer distribution right now: **layer 0 = 9**, layer 24 = 1,
  layer 25 = 9. Only layer-0 windows pass `looksManageable`; everything on a
  non-zero layer is filtered out as a fusion candidate.
- The live "smoking gun" Ghostty windows were parked at `x=-854` (fully left of
  the 0..1920 display) and `x=1880` (right edge). A window shoved off-screen still
  appears in the on-screen list but with a clamped sliver — see B2/B3.

## Edge cases

### CGF-B1 (P1) — `layer == 0` ONLY: non-zero-layer real windows are dropped
**Where:** `looksManageable` requires `layer == 0` (`CGWindowSource.swift:20`).
**Trigger:** an app that puts its window on a non-zero CG layer — "always on top"
/ floating-panel terminals, some game/emulator windows, tool windows. **Symptom:**
the window is never a fusion candidate -> every AX window for it gets `cg == nil`
-> treated as off-Space -> never tiled, never listed floating. **Severity: P1.**
**Fix sketch:** treat a small positive layer band as manageable, or key
manageability on subrole/role from AX rather than CG layer alone.

### CGF-B2 (P1) — parked/off-screen sliver fails the 64x64 size floor
**Where:** `looksManageable` requires `width >= 64 && height >= 64`
(`CGWindowSource.swift:21-22`). **Trigger:** a window parked off-display (the
live `x=-854`/`x=1880` case, or a workspace-parked column); macOS clamps its
on-screen CG bounds to a few-px sliver. **Symptom:** the only CG row for that
window is < 64px -> filtered out -> AX window gets `cg == nil` -> read as
off-Space. Interacts badly with the GATE-F freeze (a parked managed column that
loses its CG row can flip the strip to `frozenDifferentSpace`). **Severity: P1.**
**Fix sketch:** for already-managed windows, match against the stored pre-park
frame / window id instead of the live clamped sliver; relax the floor for known
windows. (Mirrors GATE-C MATCH-C5.)

### CGF-B3 (P1) — on-screen presence is a LOSSY Space proxy
**Where:** the whole design uses "appears in `optionOnScreenOnly`" as
"on current Space" (`CGWindowSource.swift:35`, used as `cg != nil`). **Trigger:**
a window that is on the current Space but momentarily NOT in the on-screen list —
fully occluded behind another window, mid-move/animation, or just-created before
the WindowServer publishes it (the AX-beats-WindowServer race the sim models as
`cgPublishAt`). **Symptom:** transiently read as off-Space -> dropped this cycle.
This is the mechanism behind the flapping 42->0 floating counts. **Severity: P1.**
**Fix sketch:** debounce the off-Space decision (require N consecutive misses
before treating a previously-on-Space window as gone); combine with a real Space
id signal rather than pure on-screen presence.

### CGF-B4 (P2) — `alpha > 0.05` floor drops faded/transitioning windows
**Where:** `looksManageable` requires `alpha > 0.05` (`CGWindowSource.swift:21`).
**Trigger:** a window mid-fade-in on open, or an app that runs at low opacity.
**Symptom:** filtered out until it finishes fading -> brief floating window on
spawn. **Severity: P2** (usually self-heals).

### CGF-B5 (P2) — `.excludeDesktopElements` and title needing Screen Recording
**Where:** `listWindows` passes `.excludeDesktopElements` (`:34`) and reads
`kCGWindowName` which is nil without Screen Recording. **Trigger:** general.
**Symptom:** the nil CG title is what makes GATE-C's fusion frame-only (see
MATCH-C2); recorded here as the upstream cause. **Severity: P2** (amplifier, not
a standalone drop).

## Master-table rows
| ID | Title | Gate / file:line | Trigger | Symptom | Sev | Repro |
|---|---|---|---|---|---|---|
| CGF-B1 | `layer==0` only drops non-zero-layer windows | `CGWindowSource.swift:20` | always-on-top / panel terminal, game window | no CG candidate -> `cg==nil` -> never tiled/listed | P1 | live: 10 onscreen windows on layers 24/25 |
| CGF-B2 | parked sliver fails 64x64 floor | `CGWindowSource.swift:21-22` | off-screen/workspace-parked window clamped to sliver | filtered candidate -> AX read off-Space | P1 | live: windows at x=-854 / x=1880 |
| CGF-B3 | on-screen presence is a lossy Space proxy | `CGWindowSource.swift:35` | occlusion / animation / publish race | transient off-Space drop -> flapping floating count | P1 | matches live 42->0 flap |
| CGF-B4 | `alpha>0.05` drops faded/transitioning windows | `CGWindowSource.swift:21` | window mid-fade or low-opacity app | brief floating on spawn | P2 | code trace |
| CGF-B5 | nil CG title (no Screen Recording) | `CGWindowSource.swift:60` | always (Accessibility-only contract) | makes GATE-C fusion frame-only | P2 | see MATCH-C2 |
