# 01 — Space-change DETECTION & signal (Track 1)

How should ScrollWM *know* the active macOS Space changed, and how should the
current-Space membership of a window be determined, robustly and promptly, using
**public APIs only**?

Scope: the *signal* layer. Membership/freeze *policy* (`ResyncPlanner`),
fullscreen Spaces (Track 3), cross-Space window movement (Track 4), and the
sim-Space model (Track 5) are their own docs; this doc cites them but does not
re-derive them.

Every claim below is backed by a `file:line` ref or the headless reproduction
`WindowLab spacedetecttest` (`Sources/WindowLab/SpaceDetectionTests.swift`),
which is wired into `make test` and passes 9/9.

---

## 0. TL;DR

- ScrollWM observes **no Space-change signal at all**. The only Space input is
  the *implicit* one: `CGWindowListCopyWindowInfo(onScreenOnly)` returns only
  current-Space windows (`CGWindowSource.swift:35`), and that list is sampled
  **only** when something else triggers a resync: a window create/destroy AX
  event, an app launch/terminate, or the **2 s safety-net poll**
  (`LifecycleMonitor.swift:73,102`). A *pure* native Space switch fires **none**
  of those, so nothing re-samples.
- Consequence: after a native Space switch (Ctrl-←/→, Mission Control, an app
  activation that follows a window to another Space), the strip is **stale for
  up to one poll interval (~2 s, worst case ~4 s — see §1)**. Reproduced
  headlessly: **zero** resyncs run across two Space switches
  (`spacedetecttest`, "GAP" assertions).
- `NSWorkspace.activeSpaceDidChangeNotification` is **public** and is the right
  signal. It fires on every active-Space transition, sub-frame latency, but
  carries **no** Space identifier in `userInfo`. Wiring it to the *existing*
  `LifecycleMonitor.resync()` collapses the staleness to a single signal-fast
  resync (**~12–14 ms** headless; one cross-process enumeration on device).
  Reproduced: `spacedetecttest` "FIX" assertions.
- "Current Space = AX ∩ CG-onscreen" is the correct public-only membership test,
  but it has documented misclassification edges (multi-Space apps,
  all-Spaces windows, mid-transition frames, fullscreen Spaces, locked/screen-off).
  See §3.
- There is **no public way** to get a stable Space identifier. `CGSGetActiveSpace` /
  `CGSManagedDisplayGetCurrentSpace` / `CGSCopySpaces` are private SkyLight
  (off-limits per `00_BRIEF.md:33`, `AGENTS.md`). Best public-only approximation:
  an **identity-set fingerprint** of the windows on a Space (§4).

---

## 1. Today: no Space-change event → how long is the strip stale?

### What drives a resync today

`LifecycleMonitor.start()` wires exactly four resync triggers
(`LifecycleMonitor.swift:78-107`):

| Trigger | Source | Fires on a pure Space switch? |
|---|---|---|
| `kAXWindowCreated` → `fastAdopt` | `WindowEventObserver` | **No** — no window is created |
| `kAXUIElementDestroyed` → `resync` | `WindowEventObserver` | **No** — no window is destroyed |
| `didLaunch/didTerminateApplication` (+0.5 s) | `NSWorkspace` | **No** — no app launches/quits |
| **2 s periodic poll** | `Timer` (`interval` default `2.0`, `:73,:102`) | Only incidentally, ≤2 s later |

The "current Space" is never read except *inside* a resync:
`applyResync` (`:175`) and `fastAdopt` (`:387`) each call
`CGWindowSource.listWindows(onscreenOnly: true)`, and `arrange` does the same at
adopt time (`ScrollWMApp.swift:819`). With no trigger, that sample is never
taken — the strip's model of "what's on this Space" is frozen at the last
trigger.

### Staleness window

- **Typical**: up to the poll interval, **2 s** (`LifecycleMonitor.swift:73`).
- **Worst case ~4 s**: the poll **coalesces** — if a poll fires mid–Space-switch
  while a background enumeration is already in flight, the overlapping tick is
  *dropped* (`enumerating` guard, `:152`). So a switch that lands just after a
  poll started can wait nearly two full intervals before the *next* effective
  sample.
- The poll enumeration itself costs ~10 ms typical but up to ~260 ms when an app
  is cold/busy (`:142-145`), and runs off-main, so it adds latency on top of the
  scheduling gap but never hitches the UI.

### User-visible glitches during the stale window

For a strip that is **on** the Space the user just returned to (the common case
of switching away and back, or an app following a window onto the strip's Space):

1. **Windows adopted late.** A window opened on the strip's Space *while the user
   was away* generates a `kAXWindowCreated`, but the fast path's current-Space
   gate (`fastAdopt`, `:387-409`) rejects it (it is not on-screen yet because its
   Space is not active), and the retry budget (~0.36 s, `:47-48`) lapses long
   before the user returns. On return there is **no new trigger**, so the window
   is **not** in the strip until the 2 s poll. Reproduced: `spacedetecttest`
   "GAP: window present on the strip's Space is NOT adopted on return".
2. **Viewport / layout wrong.** Because adoption and `reconcileSizes`
   (`:288`) only run inside a resync, a column resized/moved on the strip's Space
   while away is not reconciled until the poll: the menu-bar mini-map and the
   teleport layout are out of date for up to 2 s.
3. **Overlay shows the old strip briefly.** The Metal overlay window is
   `.canJoinAllSpaces + .stationary` (`MetalOverlay.swift:385`), so it is drawn
   on *every* Space immediately, but its **content** is the strip model, which is
   stale until the next resync — so for up to 2 s the overlay can paint the
   previous Space's strip on the new Space.

For a strip the user **switched away from** (strip belongs to Space A, user is
now on Space B): the strip *correctly* goes inert, but only **once a resync
runs** and `ResyncPlanner` returns `.frozenDifferentSpace`
(`ResyncPlanner.swift:61`, `LifecycleMonitor.swift:230`). Until then the strip is
neither updated nor frozen-by-decision — it is simply not looked at. The freeze
is *eventually* correct but *not promptly* applied. Reproduced: the pure policy
already returns `.frozenDifferentSpace` for the off-Space view
(`spacedetecttest` "policy: strip is frozen while viewing another Space"), but
nothing *runs* that policy without a trigger ("GAP: ZERO resyncs ran across two
native Space switches").

> Net: the bug is not wrong *policy* — `ResyncPlanner` is already Space-aware and
> exhaustively verified (`statespace`). The bug is **latency of detection**: the
> right decision is delayed by up to a poll interval because there is no
> Space-change signal to run it.

---

## 2. `NSWorkspace.activeSpaceDidChangeNotification` (PUBLIC)

### Facts

- **Public.** AppKit, available since 10.6. Posted on
  `NSWorkspace.shared.notificationCenter` — the *same* center ScrollWM already
  uses for launch/terminate (`LifecycleMonitor.swift:91`) and for
  `didActivateApplicationNotification` (`ScrollWMApp.swift:1483-1484`). No new
  permission; no private framework. Fully inside the hard contract
  (`00_BRIEF.md:33`).
- **Fires on every relevant transition**: Ctrl-←/→ between Desktops, Mission
  Control Space selection, switching into/out of a fullscreen Space, and an app
  activation that drags the active Space to follow a window. (Per Apple docs and
  community testing; verify on-device in Track 5's live `sandbox` repro — see
  §5 "On-device validation".)
- **Latency**: posted right after the WindowServer commits the switch — sub-frame
  in practice, far below the 2 s poll. It can fire *slightly before* the
  WindowServer's on-screen list fully reflects the new Space (the same publish
  race the fast path already handles with bounded retries, `:47-48`), so the
  resync it triggers should inherit that retry/debounce tolerance (§5).
- **Does NOT tell you WHICH Space.** `userInfo` is `nil`/empty; there is no Space
  id, index, or name in the public payload. You learn *that* it changed, not
  *to what*. This is the crux of §4: the signal is a **"recompute now"** edge,
  not a Space identity source.

### How to use it (combine with the existing CG intersection)

`activeSpaceDidChange` is purely a *trigger*. It says nothing about membership;
membership still comes from the CG on-screen intersection ScrollWM already
computes. So the minimal, correct wiring is:

```
observe activeSpaceDidChangeNotification
  → (debounced) monitor.resync()
      → resync already re-samples CGWindowSource.listWindows(onscreenOnly:true)
        and runs ResyncPlanner.decide(...) → adopt new-Space windows / freeze
```

No new policy, no new permission, no membership logic — it reuses the entire
existing `applyResync` path (`LifecycleMonitor.swift:146-322`). The only thing
missing today is the *edge that calls it*. This is exactly what the repro wires
through the sim hook and times at ~12–14 ms (`spacedetecttest`, "FIX").

---

## 3. Reliability of "current Space = AX ∩ CG-onscreen"

`IdentityMatcher.match(axWindows:cgWindows:)` fuses the all-Spaces AX list with
the current-Space CG on-screen list on PID+frame+title
(`IdentityMatcher.swift:19-78`); a window counts as "current Space" iff it gets a
CG match (`m.cg != nil`), used identically in `arrange`
(`ScrollWMApp.swift:824`), `applyResync` (`LifecycleMonitor.swift:204-210`),
`fastAdopt` (`:388-396`), and `FloatingWindows.compute`
(`FloatingWindows.swift:84-94`). This is the correct public-only test, but it
misclassifies in these edges:

1. **Apps with windows on multiple Spaces.** AX returns *all* of an app's
   windows regardless of Space; CG-onscreen returns only the ones on the active
   Space. The intersection is per-*window*, so this is handled correctly **as
   long as the per-window match is unambiguous**. The risk is the *matcher*, not
   the set logic: two same-PID windows with near-identical frames/titles (e.g.
   two empty editor windows) can mis-fuse, so a window on Space B can borrow the
   CG entry of its twin on Space A and be misclassified as on-Space. Mitigated by
   the greedy best-score + "ambiguous → unmatched" rule (`IdentityMatcher.swift:60-77`),
   but frame-collision across Spaces is the worst input for it.
2. **Always-on-all-Spaces windows** (`.canJoinAllSpaces`, e.g. our own overlay,
   some palettes/menubar-extras). These are on-screen on *every* Space, so they
   are *always* "current Space" by this test. ScrollWM's own windows are excluded
   by `selfPID` (`FloatingWindows.swift:92`) and only standard-subrole windows
   are adopted (`adopt`, `TeleportEngine.swift:232-234`), so the practical blast
   radius is small — but a third-party all-Spaces *standard* window would be
   (re)classified as present on whatever Space you're viewing, and could be
   re-adopted on each Space. Flag for Track 4 (movement/lifecycle).
3. **Windows mid-transition.** During the Space animation the WindowServer's
   on-screen list is briefly inconsistent (a window may be absent from *both*
   the old and new Space sample, or transiently present in both). A resync that
   samples *during* the animation can under- or over-count current-Space
   windows. This is why the Space signal must be **debounced** and the resync
   **retry-tolerant** (§5), not fired once at the leading edge.
4. **Fullscreen Spaces.** A fullscreen app is its own Space; its window is
   on-screen only while that Space is active, and AX `AXFullScreen` is true
   (`AXSource.swift:186`). `adopt`/`applyResync` already exclude
   `isFullscreen` windows from *adoption* (`TeleportEngine.swift:233-234`,
   `LifecycleMonitor.swift:174`), but the *membership* test still treats them as
   current-Space when active. Track 3 owns the fullscreen-Space semantics; for
   detection the relevant fact is that entering/leaving a fullscreen Space **does**
   fire `activeSpaceDidChange`, so it is covered by the same signal.
5. **Screen off / locked / fast-user-switch.** While locked, AX returns nothing
   (`attributeUnsupported`), so AX ∩ CG would be **empty** and naively read as
   "everything left this Space" → mass removal. This is already guarded:
   `sessionIsActive()` (`LifecycleMonitor.swift:121-131`) gates every `resync`
   and `fastAdopt`, and `ResyncPlanner.skipDegraded` (`ResyncPlanner.swift:71`)
   catches a sudden mass-vanish. **Any** Space-signal-driven resync must keep the
   *same* `sessionIsActive()` guard at its head — which it does for free if it
   calls `resync()` (the guard is `:148`). A screen-off DPMS event can also fire
   spurious display-reconfig churn; the signal handler should not assume a Space
   change means windows changed.

> Bottom line: the intersection is sound; its failure modes are (a) matcher
> ambiguity across Spaces, (b) all-Spaces windows, and (c) sampling *during* the
> transition. (a)/(b) are membership concerns shared with Tracks 4/3; (c) is a
> detection concern this track owns and is solved by debounce + retry (§5).

---

## 4. Is there a public, stable Space identifier?

**No.** Every API that yields a Space id is private SkyLight/CGS:
`CGSGetActiveSpace`, `CGSManagedDisplayGetCurrentSpace`, `CGSCopySpaces`,
`CGSCopyManagedDisplaySpaces`, `CGSCopySpacesForWindows`,
`CGSAddWindowsToSpaces`. These are explicitly **off-limits** (`00_BRIEF.md:33,36`,
`AGENTS.md` "NO private APIs"). `NSWorkspace.activeSpaceDidChange` deliberately
omits the id (§2). So a strip **cannot** durably remember "I belong to Space #N"
using public APIs — there is no N to store.

### Best PUBLIC-only approximation: an identity-set fingerprint

Because a Space has no public name, approximate its identity by **the set of
windows currently on it**. Concretely, derive a fingerprint from the current
on-screen window identities:

- **Identity tokens**: per CG window, a stable-enough key is
  `(ownerPID, looksManageable frame bucket)` — or, fused via `IdentityMatcher`,
  the AX element's effective identity. CG `windowID` is stable for a window's
  lifetime but is *not* a Space id and is not stable across relaunch.
- **Fingerprint**: the *unordered set* of those tokens for the active on-screen
  list, e.g. a sorted hash of `{ownerPID:title}` over `looksManageable` windows.
  Two consecutive samples with the *same* fingerprint ≈ "same Space"; a changed
  fingerprint after an `activeSpaceDidChange` edge ≈ "different Space".

Properties and limits (be honest about these):

- **Good for**: "is this the same Space I built the strip on?" (compare the
  strip's adopt-time fingerprint to the current one) — which is exactly what a
  strip needs to decide *resume vs stay-frozen*. This is strictly more than the
  current code knows (it has no Space memory at all).
- **Fails when**: two Spaces happen to hold the *same* window set (e.g. two empty
  Desktops → both fingerprint to ∅), windows are opened/closed/moved between
  samples (fingerprint drifts without a Space change), or all-Spaces windows
  dominate the set. So it is a **heuristic equality check, not an identifier** —
  never use it as a dictionary key for persistent per-Space state across reboots.
- **Recommended use**: pair it with the signal. On `activeSpaceDidChange`, take a
  fresh fingerprint; if it differs from the strip's origin fingerprint, the strip
  is "away" (freeze); if it matches, "home" (resume + reconcile). This makes the
  *freeze/resume* decision prompt and self-correcting without any private id.

> If the human ever decides a true per-Space identity is worth one documented
> private-API opt-in, `CGSCopySpacesForWindows` + `CGSGetActiveSpace` are the
> minimal pair — but that breaks the one-permission/no-private-API contract and
> should be a deliberate, isolated, flagged decision, not a default.

---

## 5. Recommended signal architecture

### Observe

1. **`NSWorkspace.activeSpaceDidChangeNotification`** on
   `NSWorkspace.shared.notificationCenter` — the primary Space edge. Register it
   right beside the existing launch/terminate observers in
   `LifecycleMonitor.start()` (`LifecycleMonitor.swift:91-100`) and tear it down
   in `stop()` (`:114`). One observer per `LifecycleMonitor` (i.e. per
   `DisplayStrip`); all strips react to the same global edge, each re-evaluating
   its own display via its own `resync()`.
2. **Keep** the existing `didActivate/didLaunch/didTerminate` and AX
   create/destroy triggers — they cover the non-Space causes of strip drift.
   `activeSpaceDidChange` is *additive*, closing only the Space-switch gap.

### Debounce

- Space transitions can fire `activeSpaceDidChange` **before** the on-screen list
  settles (mid-animation, §3.3) and can **burst** (rapid Ctrl-←/→). So:
  - Coalesce edges within a short window (~the existing 8 ms coalesce used by the
    AX observer, `WindowEventObserver.swift:75`, or a dedicated ~50–100 ms
    debounce), running **one** resync per settled transition.
  - Reuse the existing **fast-adopt retry ladder** (`:47-48`) so a resync that
    samples a half-published on-screen list re-checks a few frames later rather
    than locking in a wrong membership. Calling `resync()` already routes through
    that machinery; a single `resync()` per debounced edge is the minimal change.
- The handler must remain a thin edge → `resync()`. `resync()` already:
  guards `sessionIsActive()` (`:148`), coalesces overlapping enumerations
  (`:152`), runs off-main (`:156`), and applies the Space-aware
  `ResyncPlanner` decision (`:223-235`). **No policy changes are required.**

### Trigger (recommended production wiring — NOT shipped here)

```swift
// in LifecycleMonitor.start(), alongside the launch/terminate observers:
observers.append(center.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil, queue: .main
) { [weak self] _ in
    // Debounced single resync; resync() already re-samples the current-Space
    // CG list, applies ResyncPlanner, and inherits the publish-race retry.
    self?.scheduleSpaceResync()   // ~50ms debounce → resync()
})
```

This is a **clearly-isolated, low-risk** change (one observer + one debounce),
but per the brief I did **not** ship it into production — it is left as the
documented recommendation and is *proven* by the headless repro wiring the same
edge through the sim hook.

### Headless tests (implemented)

Track 5 already extended `SimWindowWorld` with the active-Space model and the
`activeSpaceDidChange` analogue:
- `setActiveSpace(_:)` switches the active Space; `cgWindows(onscreenOnly:true)`
  omits off-active-Space windows (`SimWindowWorld.swift:312`), exactly mirroring
  `CGWindowListCopyWindowInfo(onScreenOnly)`.
- `subscribeActiveSpace(_:)` is the public-notification stand-in: a main-queue
  closure fired after each real transition (`SimWindowWorld.swift:244-266`).
- `setNativeSpace(_:_:)` / `nativeSpace(of:)` model per-window Space membership.

**This track adds** `Sources/WindowLab/SpaceDetectionTests.swift` (verb
`spacedetecttest`, in the `make test` headless suite), which runs the **real
production `LifecycleMonitor`** against that sim and asserts:

- **GAP (no signal observed):** across two native Space switches with a window
  opened on the strip's Space while away, **zero** resyncs run and the window is
  **not** adopted within a sub-poll window — the strip is provably stale.
- **FIX (observe the hook):** wiring `subscribeActiveSpace → monitor.resync()`
  (no production change) adopts the on-Space window on return in **~12–14 ms**,
  i.e. signal-fast, not the (deliberately slow 5 s) poll.

Result: `[headless-spacedetect] 9 passed, 0 failed`; full `make test` green (483
unit + 7 headless suites incl. this one + 5 fuzzers + state-space).

### On-device validation (deferred to Track 5 / a follow-up)

The one claim a headless sim *cannot* prove is that the **real**
`activeSpaceDidChangeNotification` actually fires for each transition class
(Ctrl-arrow, Mission Control, fullscreen enter/exit, app-follow) and how it
races the on-screen publish. That needs a live `sandbox` run on the user's own
test Spaces (golden rule: never the real session). Recommended check: a tiny
probe verb that logs each `activeSpaceDidChange` with a timestamp and the
resulting on-screen fingerprint delta. Flagged for Track 5's live repro.

---

## 6. Concrete gaps (ranked)

1. **No Space-change signal at all** → up to ~2 s (worst ~4 s) strip staleness
   after any native Space switch. *Fix:* observe
   `activeSpaceDidChangeNotification` → debounced `resync()`. (Proven:
   `spacedetecttest`.) **Biggest gap.**
2. **Freeze decision is delayed, not wrong.** `ResyncPlanner.frozenDifferentSpace`
   is correct but only applied when a resync happens to run; the same signal
   fixes promptness.
3. **No Space memory.** A strip cannot tell "my Space" from "another Space"
   except by live AX∩CG; no public id exists. *Mitigation:* identity-set
   fingerprint (§4) for resume-vs-freeze.
4. **Membership misclassification edges** (multi-Space same-PID frame collisions;
   all-Spaces standard windows; mid-transition sampling). *Mitigation:* debounce
   + publish-race retry (owned here); matcher hardening + all-Spaces handling
   shared with Tracks 3/4.

---

## 7. Files

- New (this track): `Sources/WindowLab/SpaceDetectionTests.swift`
  (`runHeadlessSpaceDetectionTest`, verb `spacedetecttest`).
- Wiring (this track, shared dispatch — minimal appends, coordinated with Track 5):
  `main.swift` `case "spacedetecttest"`; `HeadlessHarness.swift`
  `runHeadlessSuite` verbs array.
- Consumed read-only (owned by Track 5): `SimWindowWorld` Space API,
  `Headless.arrangeCurrentSpace`, `Headless.resyncDecision`.
- **No production behavior changed.** The recommended observer wiring (§5) is
  documented, not shipped.
