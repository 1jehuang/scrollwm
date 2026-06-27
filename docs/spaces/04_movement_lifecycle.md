# Track 4 - Window movement across Spaces + lifecycle / removal correctness

Scope: the correctness of adopt / keep / drop when windows or the user cross
native macOS Spaces, and the parking-sliver interactions. Every claim is backed
by a `file:line` ref or by an assertion in the headless repro
(`movetest` = `runHeadlessMovementTest`, `Sources/WindowLab/MovementLifecycleTests.swift`,
33/33 green). Built on Track 5's sim-Space API (`SimWindowWorld.setActiveSpace` /
`setNativeSpace` / `nativeSpace(of:)`) and `Headless.arrangeCurrentSpace` /
`resyncDecision`.

TL;DR:
- One **production bug found and fixed** (public-API only): the fast-adopt
  `stripIsOnCurrentSpace` gate ignored `peekInset`, so under the production
  default (`peekInset = 48`) it ALWAYS returned false for a non-empty strip and
  every same-Space window after the first was stranded until the 2s poll.
- The "removal keys on AX existence" invariant is correct and verified
  end-to-end, but it produces a **phantom column / reserved gap** when the user
  sends a managed window to another Space (a real, design-level gap, not a code
  bug; fix belongs to the Track 2 ownership model).
- The parked-sliver assumption is **sound**: a vertical-workspace-parked window
  stays on its native Space, is not re-adopted into the wrong Space, and the
  freeze rule is robust. No oscillation under a Space-toggle storm.

---

## 1. The "removal keys on AX existence" invariant

### What the code does

Removal is driven purely by AX existence, in two layers:

- Pure policy: `ResyncPlanner.decide` computes
  `remove = stripIDs.filter { !axSet.contains($0) }`
  (`ResyncPlanner.swift:78`). A window merely on another Space still appears in
  the AX enumeration (`AXSource.allWindows` spans all Spaces), so it is NOT in
  `remove`.
- Apply: `applyResync` drops slots whose AX element is gone from the fresh
  enumeration via `engine.removeSlots { slot in !standardExisting.contains { CFEqual(...) } }`
  (`LifecycleMonitor.swift:241`). Same CFEqual identity test; a cross-Space
  window still matches, so it is kept.

This is correct and it is the right invariant: AX is the only signal that
distinguishes "closed" from "elsewhere", and the WindowServer on-screen list
(`CGWindowSource.listWindows(onscreenOnly:true)`) only reports the current
Space, so it cannot be used for removal without dropping every window the moment
the user switches Spaces.

Verified end-to-end in **movetest Section 1**:
- `S1 sent window STILL exists in AX (merely on Space 2)` - after
  `setNativeSpace(elM, 2)`, the window is absent from the on-screen list but
  present in `AXSource.windows(forPID:)`.
- `S1 planner does NOT remove a window merely on another Space` - `decide`
  returns `.apply(remove: [], add: [])`.
- `S1 PHANTOM COLUMN (current bug): sent window stays in the strip`.

### The phantom-column / reserved-gap problem (real gap, by design)

When the user drags a **managed** window to another Space via Mission Control
while the strip stays on Space A:

- The window still exists in AX, so it is kept (above).
- It is still a column on the strip's canvas, so `compactStrip` keeps reserving
  its `width + gap` band. Its real frame is on Space B (invisible here), so the
  strip shows a **dead gap** where the column logically sits, and the neighbor
  to its right does NOT slide in to fill it.

movetest Section 1 pins exactly this:
- `S1 phantom still occupies its canvas slot (layout unchanged)`
- `S1 phantom GAP: Right was NOT pulled in to fill the sent column`
  (`Right.canvasX > Mid.canvasX` still holds after the move).

Why this is not just "fix removal": you cannot reuse the freeze test here. The
freeze rule (`frozenDifferentSpace`) fires only when **NONE** of the strip is on
the current Space (`ResyncPlanner.swift:58-62`). A single window sent away leaves
the OTHER columns on the current Space, so the strip is correctly NOT frozen -
it is genuinely diverged per-window. The planner has no concept of "a managed
window that left the strip's Space but is still alive".

This is the same phenomenon Track 2 (strip<->Space ownership) and Track 5
document as the core missing model. The minimal, additive classifier the fix
would build on is prototyped + tested here as a pure oracle:

```
MovementLifecycle.divergedManagedWindows(stripPIDs:, currentSpacePIDs:)
```
(`MovementLifecycleTests.swift`, asserted by
`S1 proposed classifier flags exactly the sent window as diverged`). It returns
the managed windows absent from the current Space **while others are present**
(so it is silent on a real Space switch, where the freeze rule owns the
decision). See Section 6 for the recommendation.

### Interaction with the shared parking sliver

The "shared parking sliver" comments
(`LifecycleMonitor.swift:214-218` in `applyResync`,
`LifecycleMonitor.swift:370-373` in `fastAdopt`) are about ScrollWM's OWN
vertical workspaces, not native Spaces: a window parked off-screen in an
inactive vertical workspace is still on the current native Space (it was only
slid sideways by `parkWindows`, `TeleportEngine.swift:442`), so it stays in the
current-Space CG list. The guard that stops it being re-adopted as "new" is
`engine.isManaged` spanning ALL workspaces (`TeleportEngine.swift:96`), used both
in the strip-token mapping (`allManagedSlots`, `LifecycleMonitor.swift:219`) and
in `fastAdopt`'s `unmanaged` filter (`LifecycleMonitor.swift:374`).

This does **not** interact badly with real Space membership: see Section 2.

---

## 2. The "parked window shows on current Space as a sliver" assumption

Claim under test: a window parked off-screen by ScrollWM stays in the CG
on-screen (current-Space) list, and that assumption must survive the user
switching native Spaces.

### Does the parked sliver stay in the current-Space list?

Yes. Parking only changes a window's X to a far off-screen value
(`parkingX`, `TeleportEngine.swift:723`); macOS clamps it to a ~40px sliver but
keeps it on the same Space. The sim models this exactly:
`cgWindows(onscreenOnly:true)` filters on `nativeSpace == activeSpaceID`
(`SimWindowWorld.swift:312`), NOT on position, so a parked-but-on-Space window
is still listed.

movetest Section 2: `S2 parked sliver is still in the current-Space CG list`.

### Does the sliver follow / get re-adopted into the wrong Space?

No, and this is the key result. With WsB parked in an inactive vertical
workspace and the user switching native Space 1 -> 2 -> 1:

- On Space 2 the parked sliver correctly drops out of the CG list (its native
  Space is 1): `S2 on Space 2 the parked sliver drops out of the CG list`.
- The strip freezes (both windows live on Space 1):
  `S2 strip freezes on the foreign Space` (`decide == .frozenDifferentSpace`).
- Returning to Space 1, WsB is NOT re-adopted into the active workspace, because
  `isManaged` already finds it in ws2: `S2 back on Space 1: WsB NOT re-adopted
  into the wrong workspace`, and `S2 WsB managed exactly once (no phantom
  duplicate)`.

So the parked-sliver assumption holds across native Space switches. The
`isManaged`-spans-all-workspaces guard is load-bearing and works.

Caveat (not a bug, but worth stating): the freeze test keys on whether ANY strip
window is on the current Space (`ResyncPlanner.swift:58-60`). The parked sliver
is a strip window on the current Space, so it can keep the strip "thawed" even
when the FOCUSED window has moved away - which is the right behavior here (the
strip genuinely still owns a window on this Space). See Section 4 for the related
`stripIsOnCurrentSpace` edge case.

---

## 3. Re-adoption loops / oscillation during a Space transition

Concern: as the CG on-screen list flickers during a Space transition, could a
window oscillate adopted <-> frozen, or could a freeze be misread as AX
degradation and trigger mass-removal?

movetest Section 3 builds a **storm**: a 4-window strip on Space 1, two windows
permanently on Space 2, then 12 rapid `setActiveSpace` toggles (1<->2) each
followed by a real `monitor.resync()`. Assertions:

- `S3 no oscillation: strip stayed at 4 columns throughout` - count never moved
  off 4 across every step.
- `S3 no contamination: no Space-2 (B) window ever entered the strip`.
- `S3 final strip is exactly its 4 original columns`.

Coverage of the two relevant `ResyncPlanner` branches:
- `frozenDifferentSpace` (`ResyncPlanner.swift:61`): on Space 2, none of the 4
  strip windows are on-screen, so the planner freezes and `applyResync` returns
  before any `removeSlots` (`LifecycleMonitor.swift:230-235`). Asserted:
  `S3 foreign Space yields frozenDifferentSpace (not skipDegraded)`.
- `skipDegraded` (`ResyncPlanner.swift:71`): note that the freeze check runs
  FIRST, so a clean Space switch is classified as `frozenDifferentSpace`, never
  as degradation. The degradation guard only matters when SOME strip windows are
  still on the current Space but many vanished from AX at once (the lock-screen
  / WindowServer-hiccup edge). Asserted that a freeze does not mass-remove:
  `S3 freeze did not mass-remove the 4-window strip`.

Why no oscillation is structurally guaranteed in the clean case: adoption is
gated on the current-Space CG set on BOTH paths (`add = axIDs.filter { ...
currentSpaceIDs.contains }`, `ResyncPlanner.swift:82`; `onscreenNew` in
fastAdopt, `LifecycleMonitor.swift:396`), and removal is gated on AX existence
which is Space-independent. A window that is alive-but-elsewhere is therefore
never added (not on current Space) and never removed (still in AX) - a stable
fixed point, not an oscillation. The only flicker source would be the CG list
momentarily disagreeing with AX about the SAME Space, which the degradation
guard + the "one match is enough" tolerance absorb.

---

## 4. `stripIsOnCurrentSpace` robustness - BUG FOUND + FIXED

`fastAdopt` adopts a newly created window only if the strip itself is on the
current Space (`LifecycleMonitor.swift:413`):
`if !engine.slots.isEmpty && !stripIsOnCurrentSpace(cg: cg) { return }`.

### The bug

The old gate computed each slot's expected on-screen X as
`screenFrame.origin.x + slot.canvasX - viewportX` and matched it against the
real CG bounds with an 8px tolerance. But `teleport` actually places every
on-screen column at `onScreenTarget`, which is
`contentOriginX + canvasX - viewportX` where
`contentOriginX = screenFrame.origin.x + peekInset` (`TeleportEngine.swift:687`,
`:138`). The gate omitted `peekInset`.

The production controller sets `peekInset = 48` from config
(`ScrollWMApp.swift:173`, `Config.swift:46`), which is `> 8` (the tolerance). So
for a real running ScrollWM, NO on-screen slot ever matched, `stripIsOnCurrentSpace`
ALWAYS returned false, and the `fastAdopt` Space-freeze guard ALWAYS tripped the
moment the strip had >=1 window. Consequence: only the very first window of a
session fast-adopts; every subsequent same-Space window falls through to the 2s
safety-net poll - the visible "new window floats for up to 2 seconds, then snaps
in" latency the fast path exists to eliminate. The Space-freeze contract was
accidentally "always frozen".

It went unnoticed because every prior headless fast-adopt test
(`spawnlatency`) ran at the bare-engine default `peekInset = 0`, where the two
formulas are identical.

### The repro

movetest Section 4 runs the SAME fast-adopt scenario at two insets:
- `S4/inset0` (legacy) - always passed.
- `S4/inset48` (production default) - **failed** before the fix: the 2nd
  same-Space window was not adopted within ~1s (slow 30s poll deliberately set
  to isolate the fast path).

Isolation matrix (proving it is a production bug, not a test artifact):

| `stripIsOnCurrentSpace` | helper teleports? | S4/inset48 |
|---|---|---|
| old (no peekInset) | no | FAIL |
| old (no peekInset) | yes | FAIL |
| new (`onScreenTarget`) | no | PASS |
| new (`onScreenTarget`) | yes | PASS |

The fix is necessary and sufficient regardless of the test helper (`adopt()`
already calls `commitAll()->teleport()`, so the seed column is at its
`onScreenTarget` either way).

### The fix (public-API only)

Compute the expected position the exact way `teleport` does, by reusing the
engine's own `onScreenTarget` (`LifecycleMonitor.swift:493-505`):

```swift
private func stripIsOnCurrentSpace(cg: [CGWindowInfo]) -> Bool {
    for slot in engine.slots {
        let expected = engine.onScreenTarget(for: slot)   // peekInset-aware
        let pid = slot.window.pid
        let hit = cg.contains { c in
            c.ownerPID == pid
                && abs(c.bounds.origin.x - expected.x) <= 8
                && abs(c.bounds.origin.y - expected.y) <= 8
        }
        if hit { return true }
    }
    return false
}
```

This is a no-op at `peekInset == 0` (identical math), so every existing test is
unaffected; `make test` stays green (8 headless suites + 5 fuzzers + statespace).
Bonus robustness: it also accounts for `parkingX` (a parked column reports its
parked target, which won't match a current-Space window - correct, since "one
match is enough" only needs a genuinely on-screen column).

### Edge case: parked windows on another Space but the focused one moved

The gate iterates ALL slots and returns true on the first match, so it is robust
when the strip has a parked window on the current Space even though the focused
window scrolled off: any on-screen column (parked sliver included, IF it lands
at its `onScreenTarget`) keeps the strip "on the current Space". The fix makes
this honest at any inset. The residual subtlety - that a parked sliver can keep
the strip thawed - is the same intentional behavior as the `ResyncPlanner` freeze
test (Section 2) and is correct: the strip really does still own a window here.

---

## 5. Secondary finding: closed window parked in an inactive vertical workspace

`applyResync`'s `removeSlots` scans only the ACTIVE strip
(`engine.removeSlots`, `LifecycleMonitor.swift:241`, which operates on `slots`,
the active workspace). A window CLOSED while parked in an INACTIVE vertical
workspace is therefore not reaped until the user returns to that workspace and a
resync runs.

movetest Section 5 pins this as current behavior (not a crash, just delayed
reaping):
- `S5 (current) closed parked window lingers in inactive workspace`.
- `S5 returning to the workspace reaps the closed zombie`.

This is low severity (the zombie is invisible and harmless, and is reaped on
return) but worth noting for the Track 2 ownership model: a cross-workspace reap
pass in the poll would close the gap. It is NOT specific to native Spaces, so I
am only flagging it, not fixing it (out of this track's blast radius, and it
touches the workspace-removal surface other tracks may be reworking).

---

## 6. Recommendations

### Shipped here (public-API only, fixed + tested)

1. **`stripIsOnCurrentSpace` peekInset fix** (`LifecycleMonitor.swift:493`).
   Reuse `engine.onScreenTarget`. This restores fast-adopt for the 2nd+
   same-Space window in production. No private API, no new permission.

### Recommended (design-level, deferred per brief - "do NOT ship behavior
changes yet")

2. **Phantom-column reaping when a managed window is sent to another Space.**
   Extend the resync policy with a per-window divergence classifier
   (`MovementLifecycle.divergedManagedWindows` is the tested oracle): when SOME
   strip windows are on the current Space and others are alive-but-off-Space,
   the off-Space ones should be detached from the strip layout (so the gap
   closes) while remembering them for re-attach. This is the Track 2 ownership
   model's job; the classifier here is the pure seed.
   - Public-API feasibility: detecting it is fully public (AX existence + CG
     current-Space, exactly what `decide` already consumes). The ambiguity it
     cannot resolve from one sample - "sent to another Space" vs "temporarily
     missing from the on-screen list during a transition" - is handled the same
     way fastAdopt already handles its publish race: require persistence across
     a couple of polls before detaching, so a transient flicker never reaps a
     real column. No private Space API needed.

3. **Cross-workspace reap in the safety-net poll** (Section 5): have the poll
   also drop slots in inactive vertical workspaces whose AX element is gone.
   Public-API only.

### Where a correct fix is impossible without private API

- **None in this track.** Every movement/lifecycle correctness issue here is
  solvable with AX existence + the CG current-Space list. The thing ScrollWM
  fundamentally cannot do without a private Space API (SkyLight/CGS) is
  *proactively* know WHICH Space a window was sent to, or move a window to a
  specific Space itself - but neither is required for the keep/drop/adopt
  correctness this track owns. (The lack of a Space-change SIGNAL is Track 1's
  domain; it makes the above reaping latency-bounded by the 2s poll rather than
  instant, which is acceptable.)

---

## Repro index (`movetest`, all assertions green)

| Section | What it proves | Key assertions |
|---|---|---|
| 1 | Removal keys on AX; phantom gap on send-to-Space | `planner does NOT remove ...`, `PHANTOM COLUMN ...`, `phantom GAP ...`, `classifier flags ...` |
| 2 | Parked sliver vs native Space switch; no wrong-Space re-adopt | `parked sliver still in CG list`, `freezes on the foreign Space`, `WsB NOT re-adopted`, `managed exactly once` |
| 3 | No oscillation / no contamination under a Space-toggle storm | `no oscillation ...`, `no contamination ...`, `frozenDifferentSpace (not skipDegraded)` |
| 4 | `stripIsOnCurrentSpace` robust under peekInset (BUG + FIX) | `2nd same-Space window fast-adopted with peekInset=48` |
| 5 | Closed-while-parked window reaped on workspace return | `closed parked window lingers ...`, `returning ... reaps the zombie` |

Run: `.build/debug/WindowLab movetest` (also part of `make test` via the
headless suite). Source: `Sources/WindowLab/MovementLifecycleTests.swift`.
