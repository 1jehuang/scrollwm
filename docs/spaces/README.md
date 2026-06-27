# ScrollWM x native macOS Spaces — consolidated findings & design

Synthesis of a 5-track headed-swarm investigation. Source docs:
`01_detection.md` (signal), `02_ownership.md` (model), `03_fullscreen_missioncontrol.md`
(special Spaces), `04_movement_lifecycle.md` (adopt/keep/drop), `05_empirical_and_siminfra.md`
(ground truth + sim infra). All claims there are backed by `file:line` or a
headless repro. This file is the executive view + the ordered plan.

Everything below is investigation/design plus **safe, additive test scaffolding
and ONE small production bug fix**. No risky behavior was shipped.

---

## The one-sentence diagnosis

ScrollWM has **no concept of a macOS Space and no signal that the Space changed**;
it *infers* "the current Space" by intersecting the all-Spaces Accessibility
window list with the WindowServer's on-screen list, and only re-checks that on a
**2-second poll**. Everything that "feels wrong about Spaces" falls out of those
two facts: the strip is **stale for up to ~2s (worst ~4s)** after any Space
switch, it has **no memory of which Space it belongs to**, and it cannot tell
"window closed" from "window sent to another Space."

Empirically confirmed on this machine (read-only probe, `05`): of 170 normal
windows, only 23 were on the current Space; 147 lived on other Spaces and
correctly vanished from the on-screen list while staying in AX. That split is the
entire mechanism ScrollWM rides, with no event to tell it the split changed.

---

## What is actually ALREADY CORRECT (don't break these)

- **The freeze *policy* is right.** `ResyncPlanner.decide` is Space-aware and
  exhaustively state-space-verified: it freezes on a foreign Space
  (`frozenDifferentSpace`), guards AX degradation (`skipDegraded`), and never
  adopts a cross-Space window. The bug is *latency of running it*, not the policy.
- **Removal keying on AX existence is right.** A window merely on another Space
  stays in AX, so it is kept, not dropped (`04`).
- **The parked-sliver / vertical-workspace machinery survives native Space
  switches.** A parked window is not re-adopted into the wrong Space; the
  `isManaged`-spans-all-workspaces guard is load-bearing and works (`04`).
- **Per-display geometry scoping is right and orthogonal to Spaces** — a window
  belongs to the display it overlaps regardless of the separate-Spaces toggle
  (`03`).
- **The lock/degradation guards are load-bearing.** A locked-screen probe showed
  AX collapsing to 1 window while CG still reported 23; `sessionIsActive()` +
  `skipDegraded` are what stop a mass-removal there (`05`). Do not weaken them.

---

## The hard ceiling (be honest about this)

**There is NO public API for a stable Space identifier.** Every Space-id call
(`CGSGetActiveSpace`, `CGSCopyManagedDisplaySpaces`, `CGSCopySpacesForWindows`,
`CGSGetWindowWorkspace`, …) is private SkyLight/CGS, which the project contract
forbids. `NSWorkspace.activeSpaceDidChangeNotification` fires but carries **no
Space id**. Consequences:

- We can know *that* the Space changed (public), never crisply *which* one.
- A truly per-Space strip model (PaperWM/niri shape) is only **approximate**
  under public APIs; the best public proxy is a **content fingerprint** (the set
  of window identities on the Space), which works to answer "is this the same
  Space I built on?" while those windows persist, and degrades for empty Spaces /
  full window turnover.
- `NSScreen.screensHaveSeparateSpaces()` **is** public and should be used to
  branch multi-display behavior.

A crisp model would need a deliberate, documented, isolated **opt-in to one or
two private calls** — a decision for the human, not a default.

---

## Prioritized gap list

### P0 — shipped here (small, safe, tested)

1. **Fast-adopt was effectively always frozen in production.**
   `stripIsOnCurrentSpace` computed expected on-screen X **without `peekInset`**,
   but production runs `peekInset = 48` (> the 8px tolerance), so the gate
   *always* returned false for a non-empty strip. Result: only the FIRST window
   of a session fast-adopted; every later same-Space window waited up to 2s for
   the poll — the visible "new window floats, then snaps in" lag the fast path
   exists to kill. Fixed by reusing `engine.onScreenTarget` (peekInset-aware);
   no-op at `peekInset == 0` so every prior test is unaffected. (`04`,
   committed `504b40c`; repro `movetest` Section 4.)

### P1 — the big one (clear win, public API only, NOT yet shipped)

2. **Adopt a Space-change SIGNAL.** Observe
   `NSWorkspace.activeSpaceDidChangeNotification` (public, same notification
   center already used for launch/terminate) → debounced `resync()`. Collapses
   the up-to-2s staleness to a single signal-fast resync (~12-14ms headless).
   No new policy, no permission, no private API — it just supplies the *edge that
   calls the existing path*. Must keep the `sessionIsActive()` guard and inherit
   the publish-race retry; debounce ~50ms to absorb mid-animation bursts.
   (`01` §5; proven by `spacedetecttest`.)

### P2 — coherence / correctness gaps (design-level, need the ownership model)

3. **Phantom column when a managed window is sent to another Space.** It stays in
   AX so it is kept, but its frame is on the other Space, leaving a dead gap that
   neighbors don't fill — and **focusing it teleports the user to that Space**
   (the single most user-hostile behavior). Two halves:
   - *Focus side:* add a Space guard so focus/activation never `activateApp` a
     window that is not on the current Space (`02` inv #1).
   - *Layout side:* a per-window divergence classifier (tested oracle
     `MovementLifecycle.divergedManagedWindows`) detaches off-Space columns from
     the layout (gap closes) while remembering them for re-attach, requiring
     persistence across a couple polls so a transient flicker never reaps a real
     column. (`04` R2.)

4. **Fullscreen is incoherent: same action, opposite outcomes.** A managed window
   entering native fullscreen moves to its own Space. If other columns remain it
   becomes a **stranded phantom** the engine keeps fighting (and `reconcileSizes`
   can balloon its width to a full display, exploding the strip); if it was the
   only column the **whole strip freezes**. Fix: treat "managed window went
   fullscreen" as a first-class **suspended** state (skip it in teleport /
   reconcile / resize), unifying both cases. Detect via the existing AXObserver
   (`AXFullScreen` re-read on resize). Public API only. (`03` R1.)

5. **"Strip frozen on the Space I'm actually looking at" trap.** Because freeze
   keys on *window location* not *user location*, if all a strip's windows leave
   Space A while the user stays on A, the strip goes inert on the very Space the
   user is viewing, and ignores new windows opened there. The Space signal (P1)
   lets us distinguish "user switched" from "my windows left" and thaw correctly.
   (`02` scenarios a/e.)

### P3 — multi-display + polish

6. **Single shared current-Space gate assumes one Space spans displays.** Under
   "Displays have separate Spaces" = ON (modern default), each display has its
   own active Space, but ScrollWM feeds one union on-screen list to every strip's
   planner. Make the gate per-display (filter the CG list to each strip's display
   before computing its `currentSpaceIDs`; geometry already exists). Branch on
   `NSScreen.screensHaveSeparateSpaces()`; refuse/warn on `allDisplays` scope when
   separate-Spaces is ON. Cannot be made Space-id-correct without private APIs.
   (`03` R2/R3.)

7. **RestoreStore is Space-blind.** Crash-recovery frames carry no Space tag, so
   recovery can reposition a window onto whatever Space it now lives on (off the
   user's view) and `app.activate()` during recovery can teleport the user's
   Space at startup. Restore must carry a Space key and defer off-current-Space
   windows. (`02` §3.)

8. **Menu-bar mini-map shows a stale/frozen strip on a fullscreen Space.** (Note:
   production has **no** Metal canvas overlay; the user-visible indicator is the
   `NSStatusItem` mini-map — `03` corrected that premise.) Render a visibly
   "paused/off-Space" state when the strip is frozen/suspended. Pure UI. (`03` R5.)

9. **Minor:** a window closed while parked in an *inactive* vertical workspace is
   reaped only on return to that workspace; a cross-workspace reap pass in the
   poll closes it. Low severity. (`04` §5.)

---

## Recommended sequencing

1. **P0 (done):** peekInset fast-adopt fix.
2. **P1:** ship the `activeSpaceDidChange` → debounced resync signal. Highest
   value-to-risk; reuses the whole existing path. This alone removes the dominant
   "Spaces feels laggy/stale" complaint.
3. **P2 focus-guard:** the never-teleport-the-user invariant (small, high safety
   value), then the fullscreen `suspended` state, then the divergence/phantom
   classifier.
4. **Decision point:** does the human want a true per-(display,Space) strip model?
   - If staying public-only: implement the **fingerprint** approximation + freeze
     P2/P5 hardening (Model A-hardened).
   - If a crisp model is wanted: approve a documented opt-in to `CGSGetActiveSpace`
     (+ maybe `CGSCopySpacesForWindows`) behind a flag, then build Model B
     (strip per display+Space).
5. **P3:** multi-display per-display gate + separate-Spaces detection; Space-aware
   restore; mini-map paused state.

---

## Test infrastructure delivered (all headless, in `make test`, green)

The sim (`SimWindowWorld`) now models native Spaces (Track 5, owner of those
edits): per-window `nativeSpace`, `setActiveSpace`, `setNativeSpace`,
`subscribeActiveSpace` (the `activeSpaceDidChange` stand-in), and
`cgWindows(onscreenOnly:)` drops off-active-Space windows exactly like the real
WindowServer. Harness sugar: `Headless.arrangeCurrentSpace`,
`Headless.resyncDecision`.

New suites (run the REAL `LifecycleMonitor` + `ResyncPlanner`, no real windows):

| Verb | Suite | What it pins |
|------|-------|--------------|
| `spacetest` | 22 | core fidelity + freeze/thaw + phantom-column baseline |
| `spacedetecttest` | 9 | staleness with no signal vs signal-fast resync |
| `movetest` | 33 | removal-by-AX, parked-sliver vs Space switch, no oscillation, peekInset fast-adopt fix |
| `fullscreentest` | 18 | phantom-strand vs whole-strip-freeze, separate-Spaces geometry |

`make test`: unittest PASS, animtest 34, **9 headless suites** (incl. the 4
above), 5 fuzzers, state-space — all green.

A live, sandbox-only, lock-guarded repro harness exists at
`scripts/track5-spaces-repro.sh` to confirm the few claims a headless sim cannot
(that the real notification fires for each transition class; Mission Control
false-frame-match). Run it on throwaway sandbox windows + your own test Spaces.

---

## What still needs the real machine (not provable headlessly)

- That `activeSpaceDidChangeNotification` truly fires for Ctrl-arrow, Mission
  Control, fullscreen enter/exit, and app-follow (and its race vs on-screen
  publish). — `scripts/track5-spaces-repro.sh`.
- Whether a poll landing exactly at Mission Control "thumbnails at rest" can
  false-match a managed AX window to a different thumbnail. Low probability;
  `minimumScore=50` + 8px frame gate make it unlikely. — sandbox probe.
