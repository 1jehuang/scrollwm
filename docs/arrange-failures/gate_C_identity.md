# GATE-C — IdentityMatcher AX<->CG fusion

**Auditor:** GATE-C
**Gate:** `IdentityMatcher.score` / `IdentityMatcher.match` — PID+frame+title
scoring fusion, `minimumScore = 50`.
**File:** `Sources/WindowLab/IdentityMatcher.swift`
**Verification:** `Sources/WindowLab/IdentityMatcherFusionTests.swift`
(`WindowLab unittest` → "IdentityMatcher fusion (GATE-C): 13 passed, 0 failed").

---

## TL;DR (the one sentence)

`cg != nil` is the manager's **"this AX window is on the current Space" signal**,
and it is produced ENTIRELY by frame geometry: the title bonus is **dead code in
production** (CG window titles require Screen Recording, which ScrollWM never
requests). So fusion is **frame-only**, and **any position discrepancy > 8px
between the AX snapshot and the CG snapshot** — exactly what happens while the
engine is mid-teleport/parking dozens of churning Ghostty windows — scores a
real, current-Space window at **≤ 48 < 50**, leaves it **UNMATCHED → `cg == nil`
→ dropped as "off-Space"**, so it is **never tiled AND never even listed as
floating**. That is the user's "windows it never caught."

---

## How a fusion miss becomes a silent drop (the blast radius)

`IdentityMatcher.match` returns `MatchedWindow(ax:, cg: nil, matchScore: 0)` for
any AX window it cannot fuse. EVERY consumer treats `cg == nil` as "not on the
current Space" and removes it:

| Consumer | File:line | What `cg == nil` does |
|---|---|---|
| Cold arrange | `ScrollWMApp.swift:922` | `let onscreen = matched.filter { $0.cg != nil }` → window never adopted into the strip. |
| Resync (managing path — the user's actual case) | `LifecycleMonitor.swift:255` | `for ... where m.cg != nil { currentSpaceIDs.insert(i) }`; a missed window is absent from `currentSpaceIDs`, so `ResyncPlanner` never lists it as a current-Space add. |
| Fast-adopt (new-window event) | `LifecycleMonitor.swift:447` | `.filter { $0.element.cg != nil }`; a churned new window misses, retries lapse, falls to the poll, which also misses → never adopted. |
| Floating menu | `FloatingWindows.swift:92` | `onCurrentSpace: m.cg != nil` → `classify` returns `nil` → the window is not even surfaced as floating. **It becomes invisible to the manager entirely.** |

The brief's live "smoking gun" — `floatingCount:42, every one canTile:true`,
then seconds later `5 cols / 0 floating` — is the **intermittent** signature of a
geometry race: during churn the snapshots disagree and windows drop; once motion
settles the frames agree and they re-fuse.

---

## Quantified score math (the heart of the gate)

`minimumScore = 50`. Title term cannot fire in production. So:

```
same PID                                 ->  40
  + exact frame  (dx,dy,dw,dh all <= 1)  -> +35  = 75   >= 50  MATCH
  + close frame  (all deltas <= 8)       -> +20  = 60   >= 50  MATCH
  + same size, position moved (> 8px)    -> + 8  = 48   < 50   DROP
  + moved AND resized (> 8px, > 1px)     -> + 0  = 40   < 50   DROP
different PID                            ->   0          DROP
```

**Minimum score for a same-PID window whose frame moved > 8px with no usable
title = 48 (same size) or 40 (also resized). Both are < 50 → UNMATCHED → dropped
as "off-Space" → never adopted.** Proven by the passing checks
`score: same-size move (40px) -> 48 (< 50: DROP)` and
`score: moved AND resized -> 40 (< 50: DROP)`.

The "moved" bonus is only **+8**, deliberately too small to rescue a moved
window on its own (it tops out at 48). The "close frame" bonus (+20) only applies
inside an **8px** box on ALL of x, y, w, h simultaneously — a single axis off by
9px collapses the whole frame term from +20 to (at best) +8.

---

## Exhaustive failure-mode enumeration

### MATCH-C1 (P0) — frame race during churn drops a real current-Space window
**Trigger:** AX `allWindows()`/`windows(forPID:)` and `CGWindowSource.listWindows`
are **separate syscalls** taken a frame or more apart. While the engine is
actively teleporting/parking windows (or an app is animating its own move/resize,
or the user is dragging), the two snapshots report origins that differ by > 8px.
The live data showed Ghostty windows parked at `x=-854` and `x=1880` — large,
fast position deltas. **Symptom:** `score ≤ 48 < 50` → `cg == nil` → window
treated as off-Space → never tiled, never listed floating; reappears once motion
stops (matches the volatile 42→0 readings). **Severity: P0** (loses real,
visible, current-Space windows during exactly the churn the brief reported).
**Repro:** `IdentityMatcherFusionTests` →
`BUG: churned same-size move -> UNMATCHED (cg == nil)` plus the positive control
`control: settled window (<=8px) DOES match`.

### MATCH-C2 (P0, root amplifier) — title bonus is dead in production
**Trigger:** `score()` adds the title bonus only `if let cgTitle = cg.title`
(IdentityMatcher.swift:38). `CGWindowListCopyWindowInfo`'s `kCGWindowName` is
returned only with **Screen Recording** permission (macOS 10.15+), which ScrollWM
intentionally never requests (Accessibility-only contract, see AGENTS.md). So
`cg.title == nil` for every other app's window and the +20/+10 title term can
**never** add anything. **Symptom:** fusion is frame-only, so MATCH-C1 has no
fallback signal — the very mechanism designed to disambiguate moved windows is
inert. **Severity: P0** (it is the multiplier that turns a transient geometry
race into a hard drop). **Repro:**
`root: WITH a CG title the same 40px move scores 68 (would match)` and
`root: dropping ONLY the CG title (production) turns 68 -> 48 (drop)` — identical
inputs except `cg.title`, flipping match→drop.

### MATCH-C3 (P0) — fusion-dropped window is also invisible as floating
**Trigger:** any C1/C2 miss. **Symptom:** `FloatingWindows.compute` gates on
`onCurrentSpace: m.cg != nil`, so a dropped window is excluded from the floating
menu too — the user has no entry point to reach it. The window is lost from BOTH
surfaces. **Severity: P0** (the failure is undetectable to the user from the UI).
**Repro:** `BUG: fusion-dropped window is ALSO absent from the floating list`.

### MATCH-C4 (P1) — greedy "each CG used once" strands surplus AX windows
**Trigger:** an app with **more current-Space AX windows than visible CG rows**
that fuse to them: identical-frame stacking (multiple windows at the same origin),
or a coalesced/lagged CG snapshot that lists fewer rows than AX currently shows.
`match` is greedy + `cgTaken`: each CG row is consumed once, so with N AX windows
and M < N matching CG rows, **N − M AX windows are stranded** with `cg == nil`.
**Symptom:** exactly the surplus windows silently drop even though they are on
this Space. **Severity: P1** (Ghostty is 1 window/PID so this PID is safe, but any
multi-window app — browser, editor, Finder — hits it under occlusion or snapshot
lag). **Repro:** `BUG: 2 identical same-PID AX windows + 1 CG row -> exactly 1
stranded` and `greedy: the winner kept the high (exact) score 95`.

### MATCH-C5 (P1) — `looksManageable` filters the parked-sliver CG row
**Trigger:** a managed window parked in an inactive vertical workspace is shoved
off-screen; macOS clamps its on-screen CG sliver to a few px on the nearest
display edge. That CG row now has `bounds.width < 64` (or height), so
`candidates = cgWindows.filter { $0.looksManageable }` (IdentityMatcher.swift:48,
CGWindowSource.swift:18) **drops it as a candidate**, while AX still reports the
window's full off-screen frame. **Symptom:** no CG row remains to fuse → AX window
gets `cg == nil` → read as off-Space. **Severity: P1** (interacts badly with
parking; can mis-drive the Space-freeze and re-adopt logic). **Repro:**
`BUG: parked-sliver CG (<64px wide) filtered by looksManageable -> AX dropped`.

### MATCH-C6 (P2) — partial-title substring bonus is too weak even WITH a title
**Trigger:** even in the rare case CG titles ARE available (Screen Recording
granted), a moved window relies on the title term, but a **substring** match
(`cgTitle.contains(axTitle)` etc.) is only **+10**: 40 + 8 (moved) + 10 = 58 is
fine, but 40 + 0 (moved & resized) + 10 = 50 is a knife-edge, and an **empty or
`~`-style title that is not a substring** of the CG title adds 0. Many Ghostty
windows are titled `~` (per the live data); a `~` substring is dangerously
promiscuous (matches any path containing `~`) AND when the AX title is empty the
`!axTitle.isEmpty` guard skips the term entirely. **Severity: P2** (only relevant
if Screen Recording is ever enabled; documents that the title path is both weak
and, for `~`, prone to FALSE matches that would fuse the WRONG CG row — see C7).

### MATCH-C7 (P2) — wrong CG row consumed → a real window scored below 50
**Trigger:** corollary of C4+C6. With many same-PID, same-frame, same-`~`-title
windows, greedy best-score can assign a CG row to AX window A that *should* have
gone to AX window B (ties broken by enumeration order via the stable sort). The
mis-assigned row is then `cgTaken`, so B must find another row; if none scores
≥ 50, **B drops** even though a valid row existed — it was consumed by the wrong
twin. **Symptom:** under dense identical-frame stacks, an arbitrary member drops
each cycle (consistent with the flapping count). **Severity: P2** (needs
near-identical duplicates; the dominant production driver is still C1/C2).
**Repro idea:** extend the C4 case to 3 AX / 2 CG identical rows and assert the
count of `cg == nil` equals AX−CG (1), independent of which specific twin loses.

### MATCH-C8 (P2) — coordinate-origin drift between AX and CG
**Trigger:** `score()` assumes "AX and CG both use global top-left-origin
coordinates" (IdentityMatcher.swift:23). On a multi-display arrangement with a
non-primary display above/left of the primary, or a display scale change, a
systematic constant offset between the two coordinate spaces would push every
delta > 8px, dropping whole displays' worth of windows. **Severity: P2** (single
LG display in the live data makes this latent here, but it is a fusion-gate
failure mode worth recording for the multi-display strip work).

---

## What a fix must flip (sketch, minimal + idiomatic)

The tests above are PASSING assertions of today's behavior; a fix flips the
`// BUG:` checks. Ordered by leverage:

1. **Give fusion an identity signal that survives motion (kills C1+C2+C3, the P0
   core).** PID alone is 40; one more robust, motion-invariant signal ≥ +10 makes
   a moved-but-present window match without ever trusting a same-instant frame.
   Cheapest: when an app's PID has **exactly one** standard CG candidate and one
   standard AX window, fuse them regardless of frame (count-based disambiguation
   — the common Ghostty case is 1:1). More general: score the **set** per PID
   (Hungarian/■min-cost assignment over PID-grouped candidates) instead of a
   global greedy frame race, so the only same-PID CG row is always claimed.

2. **Stop using a same-instant frame as the current-Space oracle (kills C5+C8).**
   Decouple "is this window on the current Space?" from "do these two frames
   line up?". Prefer matching AX↔CG by a **PID-grouped membership** test
   (does the WindowServer list ANY manageable row for this PID/window?) and
   reserve the frame delta for *disambiguating multiple* candidates, not for the
   binary on-Space decision. Relaxing `looksManageable` for *already-managed*
   parked windows (or matching on the pre-park stored frame) closes C5.

3. **Make greedy assignment exhaustive per PID (kills C4+C7).** After the
   high-confidence passes, give every still-unmatched AX window that has an
   unconsumed same-PID CG candidate that row (best-effort), so surplus windows
   are never stranded when rows actually exist.

4. **Lower-risk stopgap:** raise the "same size, moved" bonus from +8 so a
   same-size moved window reaches 50 (40 + ≥10). This alone flips C1's
   same-size case to a match (it does NOT help the moved+resized = 40 case, nor
   C4/C5), so treat it as a mitigation, not the fix.

Each change should land with the corresponding `// BUG:` assertion inverted in
`IdentityMatcherFusionTests` plus a headless `applyResync`/`fastAdopt` assertion
(via `HeadlessHarness`) that the previously-dropped window is now adopted.

---

## MASTER-TABLE BLOCK (paste into FINDINGS.md)

| ID | Title | Gate / file:line | Trigger | Symptom | Sev | Repro |
|---|---|---|---|---|---|---|
| MATCH-C1 | Frame race during churn drops a real current-Space window | `IdentityMatcher.score`/`match`, drop at `ScrollWMApp.swift:922`, `LifecycleMonitor.swift:255`, `:447`, `FloatingWindows.swift:92` | AX & CG snapshots taken in separate syscalls disagree > 8px while windows are mid-move/park (Ghostty parked at x=-854/1880) | score ≤ 48 < 50 → `cg==nil` → off-Space → never tiled, never floating; reappears when motion stops | P0 | `IdentityMatcherFusionTests`: `BUG: churned same-size move -> UNMATCHED` + control |
| MATCH-C2 | Title bonus is dead in production | `IdentityMatcher.swift:38` | `cg.title==nil` always (no Screen Recording; Accessibility-only contract) | fusion is frame-only → C1 has no fallback | P0 | `root: WITH a CG title ...68` / `... turns 68 -> 48` |
| MATCH-C3 | Fusion-dropped window is invisible as floating too | `FloatingWindows.swift:92` | any C1/C2 miss | window absent from BOTH strip and floating menu → unreachable | P0 | `BUG: fusion-dropped window is ALSO absent from the floating list` |
| MATCH-C4 | Greedy "each CG used once" strands surplus AX windows | `IdentityMatcher.match:46-70` | app with more current-Space AX windows than fusable CG rows (identical-frame stacking / lagged CG snapshot) | N−M surplus windows drop with `cg==nil` | P1 | `BUG: 2 identical same-PID AX + 1 CG -> 1 stranded` |
| MATCH-C5 | `looksManageable` filters the parked-sliver CG row | `IdentityMatcher.swift:48` + `CGWindowSource.swift:18` | parked window's on-screen CG sliver clamped < 64px while AX shows full frame | no CG candidate → `cg==nil` → read off-Space | P1 | `BUG: parked-sliver CG (<64px) filtered -> AX dropped` |
| MATCH-C6 | Substring/`~` title bonus too weak (and promiscuous) | `IdentityMatcher.swift:38-41` | empty/`~` AX titles; substring only +10; empty title skips term | even with Screen Recording the title path barely helps and `~` risks false matches | P2 | code trace (latent unless SR granted) |
| MATCH-C7 | Wrong CG row consumed → real window scored below 50 | `IdentityMatcher.match` greedy + stable sort | many same-PID/frame/`~` twins; a row claimed by the wrong twin | an arbitrary twin drops each cycle (flapping count) | P2 | extend C4 to 3 AX / 2 CG, assert dropped==AX−CG |
| MATCH-C8 | AX↔CG coordinate-origin drift | `IdentityMatcher.swift:23` | non-primary display offset / scale change makes all deltas > 8px | whole-display windows drop | P2 | code trace (latent on single display) |
