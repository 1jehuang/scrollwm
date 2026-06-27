# 02 — Strip ⟷ Space ownership model (Track 2)

Status: investigation + design. No behavior shipped. Every claim is backed by a
code ref (`file:line`) or the headless repro in
`docs/spaces/repro/ownership_repro.swift` (run: `swift docs/spaces/repro/ownership_repro.swift`,
exits 0, all checks pass).

Scope of this track: the *conceptual* ownership model — what a strip "belongs
to" relative to a native macOS Space, what today actually does across Space
scenarios, and what the right model is. Detection of the Space-change signal is
Track 1; window-movement/removal correctness is Track 4; sim Space-modeling
infra is Track 5; fullscreen/multi-display Spaces is Track 3. I coordinate with
those but did not edit their files.

---

## 0. TL;DR

- Today there is **one strip per *display*, with zero awareness of which native
  Space it was built on** (`DisplayStrip.swift:16-40`; the only identity it
  carries is `displayID`, never a Space id). The strip "freezes" whenever **none
  of its managed windows are on the Space currently being viewed**
  (`ResyncPlanner.swift:48-62`). The freeze keys off *window location*, not the
  user's Space.
- This produces four sharp behaviors (all reproduced headlessly):
  - **(a)** New window opened on a *different* Space → **ignored** (strip stays
    frozen, window left unmanaged).
  - **(b)** Switch to a Space that already has windows → **frozen**, B's windows
    are never tiled. There is no strip for B.
  - **(c)** Return to the origin Space → **clean thaw**, identical layout/focus.
  - **(d)** A managed window dragged to another Space → **kept** in the strip
    (stranded column), and focusing it **teleports the user to that Space**.
- **Recommendation:** Move to a **strip-per-(display, Space)** ownership model
  (each native Space gets its own column layout + viewport on each display), the
  PaperWM/niri "one scroller per workspace" shape — *but* gate the full version
  on Track 1 landing a **stable Space identity**. Because a stable Space id is
  not available through public API, ship an **incremental two-step**: (1) a pure
  model refactor that introduces a `SpaceKey` indirection and fixes the two
  *unambiguous bugs* (the (d) stranded-column teleport and the (a)/(e) "user is
  on this Space but the strip is frozen" trap) using only same-process inference,
  then (2) swap in real per-Space strips once a stable key exists.
- **Restore/crash:** `restore.json` is a flat list of frames with **no Space
  tag** (`RestoreStore.swift:11-16,38-55`). After a crash it re-places windows at
  saved frames *wherever those windows currently are*; a window the user since
  moved to another Space gets repositioned on that other Space (off the user's
  view), and the post-recovery strip will then freeze. Restore must become
  Space-aware in lockstep with the model.

---

## 1. Today's model, precisely

### 1.1 What a strip is bound to

`ScrollWMController` holds `strips: [DisplayStrip]`, one per managed *display*
(`ScrollWMApp.swift:14-18`). A `DisplayStrip` bundles an `engine`, a
`lifecycle` monitor, and a **`displayID: CGDirectDisplayID?`** — the *only*
identity it stores (`DisplayStrip.swift:21-30`). **There is no Space field
anywhere.** `bindStrip(_:to:)` sets `displayID` and display geometry
(`ScrollWMApp.swift:774-782`); nothing reads or writes a Space.

ScrollWM has **no Space-change signal**: it never observes
`NSWorkspace.activeSpaceDidChangeNotification` or any Space API (confirmed: the
only matches in `Sources/` are doc comments in `SimWindowWorld.swift`, the
Track-5 sim hook — production code has none). It *infers* "current Space" by
intersecting the AX window list (all Spaces) with the WindowServer on-screen
list (`CGWindowSource.listWindows(onscreenOnly: true)` = current Space only),
fused by `IdentityMatcher` (`LifecycleMonitor.swift:199-210`).

### 1.2 The freeze rule

`ResyncPlanner.decide(stripIDs:axIDs:currentSpaceIDs:)` is the pure policy
(`ResyncPlanner.swift:48-84`). The relevant clause:

```
let stripPresentInAX = stripIDs.filter { axSet.contains($0) }
if !stripPresentInAX.isEmpty
    && !stripPresentInAX.contains(where: { currentSpaceIDs.contains($0) }) {
    return .frozenDifferentSpace          // ResyncPlanner.swift:58-62
}
```

In words: *if the strip still owns windows that exist in AX, but none of them
are on the Space currently visible, do nothing.* `applyResync` early-returns on
`.frozenDifferentSpace` — **no add, no remove** (`LifecycleMonitor.swift:228-235`).
`fastAdopt` enforces the same guard via `stripIsOnCurrentSpace`
(`LifecycleMonitor.swift:411-418,482-494`).

The key property: **"frozen" is defined by where the strip's *windows* are, not
by which Space the user is on.** ScrollWM cannot tell "user switched Space" from
"all my windows moved to another Space" — both look identical (none of my
windows are on-screen). Scenarios (a) and (e) below are the cost of that.

### 1.3 Scenario trace (all reproduced)

Run `swift docs/spaces/repro/ownership_repro.swift`. The script vendors
`decide(...)` verbatim from `ResyncPlanner.swift:48-84` and the add/remove
plumbing from `applyResync` (`LifecycleMonitor.swift:228-276`), so the trace
cannot drift from production.

| # | Action | `decide` result | Outcome | Verdict |
|---|--------|-----------------|---------|---------|
| **(a)** | Arrange on A, switch to **empty** B, open a window on B | `frozenDifferentSpace` | New window **not adopted**; strip inert on B | Window left unmanaged until the user returns to A and re-arranges |
| **(b)** | Switch to B that **already has windows** | `frozenDifferentSpace` | B's windows **never tiled**; no strip for B | B behaves like an unmanaged desktop |
| **(c)** | Return to A | `apply(remove:[], add:[])` | **Clean thaw**: same columns, same order, same focus | Correct (modulo viewport, §1.4) |
| **(d)** | Drag managed window 2 → B, **stay on A** | `apply(remove:[], add:[])` | Window 2 **kept** in strip (window 1 still on A → not frozen) | **Stranded column**: engine keeps teleporting an off-Space window; focusing it teleports the user to B |
| **(e)** | Drag **all** managed windows off A, stay on A | `frozenDifferentSpace` | Strip freezes on the Space the user is **actually viewing**; a new window opened on A is also ignored | Freeze keys off window location, not user Space |

Why (a) and (b) freeze even though there are adoptable windows present: the
freeze clause returns **before** `add` is ever computed
(`ResyncPlanner.swift:58-62` precedes the `add` computation at line 82). So the
moment the strip's *own* windows are all off-screen, ScrollWM adopts nothing,
regardless of what is on the current Space.

Why (d) keeps the moved window: a window dragged to another Space **still exists
in AX** (it is not closed), so it is not in `remove` (`ResyncPlanner.swift:78`);
and the strip is not frozen because window 1 is still on A. The result is a
column the engine still owns and repositions, whose window lives on a Space the
user is not viewing. The teleport hazard: `focus(index:)` →
`raiseAndFocus` → `AXSource.activateApp(pid:)` (`TeleportEngine.swift:290-301,
863-872`) — activating an app whose front window is on another Space **switches
the user to that Space**. `focus()` has **no Space guard**
(`TeleportEngine.swift:290-301`). This is the single most user-hostile current
behavior; Track 4 owns the removal/cleanup fix, I own the *model* statement that
the invariant exists.

### 1.4 Viewport correctness on return (scenario (c) caveat)

The strip model (`slots`, `viewportX`, `focusIndex`) is pure in-memory state and
is **never mutated while frozen** (early return). So on return the columns,
order, and focus are byte-identical (repro (c) asserts this). The *physical*
window positions, however, are only re-asserted when a teleport runs. Two
sub-cases:

- If macOS preserved the windows' frames across the Space round-trip (the normal
  case), the first post-thaw `apply` that changes anything calls
  `engine.teleport()`/`refitViewportToFocused()` (`LifecycleMonitor.swift:294-319`),
  re-committing positions. But an `apply(remove:[], add:[])` with no size change
  takes the `else { engine.teleport() }` branch **only inside the
  `if removed > 0 || !newWindows.isEmpty || sizeChanged` guard**
  (`LifecycleMonitor.swift:294`), which is **false** for a no-op apply. So a
  pure return with nothing changed does **not** force a re-teleport. This is fine
  *today* because nothing moved, but it is a latent gap: if anything nudged a
  window's frame while away (an app reflow, a display change), the strip will not
  self-correct until the next real add/remove/resize. A Space-aware model should
  re-teleport on Space-enter unconditionally.

Invariant to lock: **on return to a strip's Space, the engine re-commits the
full strip layout once** (today: only conditionally).

---

## 2. The core design question: one following strip vs. strip-per-Space

### 2.1 The two models

- **Model A — "one following strip" (today).** A single strip per display that
  follows the user across Spaces by freeze/thaw. Pro: dead simple, no Space id
  needed, zero state to key. Con: the strip only ever "works" on the Space its
  windows happen to be on; every *other* Space is unmanaged (scenarios a, b),
  and window moves strand columns (d) and can teleport the user (d).

- **Model B — "strip per (display, Space)".** Each native Space gets its own
  column layout + viewport on each display, exactly like PaperWM/niri give each
  *workspace* its own scroller. Switching Spaces swaps which strip is live; each
  Space is independently managed. Pro: matches the PaperWM/niri mental model
  users coming to ScrollWM expect; no stranded columns; opening a window on any
  Space tiles it there. Con: requires a **stable key per Space** to file each
  strip under, and Space identity is the hard constraint (§2.3).

### 2.2 Relationship to ScrollWM's *internal* vertical workspaces

ScrollWM already has a per-Space-shaped abstraction internally: **vertical
workspaces** (`TeleportEngine.swift:60-103`, Cmd+J/K). Each `Workspace` is an
independent `{slots, viewportX, focusIndex}` strip; switching parks the outgoing
Space's windows off-screen and loads the destination
(`TeleportEngine.activateWorkspace`, `TeleportEngine.swift:392-434`). This is
*precisely* Model B's data shape, applied to an *internal* axis instead of the
native-Space axis.

Two architectural options follow:

1. **Map native Spaces onto internal vertical workspaces** (reuse `Workspace`).
   Tempting (the machinery exists) but **wrong**: internal workspaces *move
   windows* (they park them off-screen, `parkWindows`, `TeleportEngine.swift:442-453`)
   and are driven by *us*. Native Spaces move windows via the *WindowServer*, are
   driven by the *user/Mission Control*, and we must never relocate a window
   across a native Space (that is the user's spatial memory). Conflating them
   would make a native Space switch try to AX-park windows that macOS already
   moved, and make Cmd+J/K fight Mission Control. They are **orthogonal axes**:
   internal workspaces are "vertical scroll within the current Space"; native
   Spaces are "which desktop am I on."

2. **Keep them independent: a strip-bundle per (display, Space), each bundle
   owning its own set of vertical workspaces.** This is the recommended shape.
   The full state becomes `strip[display][nativeSpace] = TeleportEngine` (and
   each engine still has its `workspaces[]` internally). A native Space switch
   *re-points* the live engine for that display; it never parks/moves windows.

### 2.3 The hard constraint: stable Space identity (coordinate w/ Track 1)

Model B needs a key to file each strip under. The brief's contract forbids
private APIs (SkyLight/CGS Space ids are private). Without a stable Space id:

- We can detect *that* the Space changed (Track 1: infer from the on-screen set
  flipping, or `NSWorkspace.activeSpaceDidChangeNotification` which fires but
  carries **no Space identifier**).
- We **cannot reliably name** *which* Space we landed on across time. The
  WindowServer on-screen set is a fingerprint, but it is unstable: it changes as
  windows open/close/move, and two empty Spaces are indistinguishable.

Track 1's finding (coordinated conceptually): a *stable* Space id needs private
APIs (`CGSGetActiveSpace`/`SLSCopyManagedDisplaySpaces`). So Model B in full
fidelity is **impossible under the public-API-only contract** — flag this
explicitly. What *is* possible publicly:

- A **content fingerprint key** (sorted set of stable window identities on the
  Space). Good enough to *re-recognize* a Space you have seen *while its windows
  persist*; degrades for empty Spaces and across full window turnover.
- An **opt-in** to a single private call (`CGSGetActiveSpace`) behind a
  documented flag (per the brief's "explicit, documented opt-in" clause) — this
  is the only way to get crisp Model B. Recommend Track 1 cost this out.

### 2.4 Recommendation

**Target Model B (strip per (display, Space)), shipped in two steps:**

**Step 1 — pure model refactor + fix the unambiguous bugs (public API only).**
Introduce a `SpaceKey` indirection without yet maintaining multiple live strips,
and fix the two behaviors that are *wrong under any model*:

- **(d) stranded-column teleport.** Add a Space guard to focus/activation: never
  `activateApp` a window that is not on the current Space (the on-screen
  fingerprint already tells us). This directly enforces "never teleport the user
  to another Space." (Track 4 owns the removal side; this is the focus side.)
- **(a)/(e) "frozen on the Space I'm actually viewing" trap.** Distinguish
  "user switched Space" from "my windows left." With a real Space-change signal
  (Track 1) we can *thaw and re-arrange* when the user is demonstrably still on
  the origin Space but the windows moved away — instead of going inert on a
  Space the user is looking at.

**Step 2 — real per-Space strips.** Once a stable `SpaceKey` exists (fingerprint
for the public build, or the opt-in private id), maintain `engineFor(space)` per
display and swap the live engine on Space-enter. Each Space gets its own column
layout/viewport; opening a window on any Space tiles it there.

Tradeoffs of Model B vs staying on Model A:

| Dimension | Model A (today) | Model B (recommended) |
|-----------|-----------------|------------------------|
| Matches PaperWM/niri mental model | No (only one Space ever managed) | Yes |
| Needs stable Space id | No | Yes (public fingerprint is approximate; crisp version needs opt-in private id) |
| Stranded columns on window move | Yes (d) | No (window adopted by destination Space's strip) |
| New window on other Space | Ignored (a) | Tiled on that Space |
| Memory / state | 1 engine/display | up to N engines/display (one per visited Space) — small; engines are light |
| Risk of teleporting the user | High (d) | Low (per-Space strips never reach across) |
| Implementation cost | — | Moderate; the engine/workspace machinery is reusable |

Net: Model A is a *local optimum* that is fine for single-Space users and
actively wrong for multi-Space users. Model B is the correct long-term model;
its only blocker is Space identity, which is a Track 1 deliverable.

---

## 3. RestoreStore / crash-recovery implications

`RestoreStore.Entry` is `{pid, appName, title, x, y, w, h}` — **no Space tag**
(`RestoreStore.swift:11-16`). `save(engines:)` flattens `allManagedSlots` across
all displays and all vertical workspaces into one list
(`RestoreStore.swift:38-55`). `recover()` matches each entry by pid(+title) and
writes the saved frame back, clamped only for *display* availability, never Space
(`RestoreStore.swift:96-146`, `safeTarget` at 77-80).

What breaks under Spaces:

- **Wrong-Space restore.** `recover()` calls
  `AXSource.setPoint/​setSize` on whatever AX element currently matches the
  pid+title — regardless of which Space that window now lives on. If, since the
  crash, the user (or another tool) moved a window to a different Space, restore
  repositions it **on that other Space**, off the user's current view, with no
  way to know it landed wrong. The frames look "restored" but are invisible.
- **Activation side effects.** `recover()` calls `app.activate()` to coax a
  stale AX server into listing windows (`RestoreStore.swift:112-116`). For an app
  whose front window is on another Space, that **switches the user's Space during
  startup** — a jarring, unexplained teleport right after a crash.
- **Strip rebuilt then immediately frozen.** After recovery the controller
  arranges and a strip forms from whatever is on the current Space; any restored
  window that landed on another Space is then a stranded column (scenario d) or,
  if all of them did, the strip freezes on the Space the user is viewing
  (scenario e). Recovery "succeeds" (`restored == total`) yet the desktop is
  wrong.

Required model change: restore entries must carry a **Space key** (the same
`SpaceKey` from §2), and `recover()` must (1) only restore a window if it can
confirm the target Space matches, or (2) defer restore of off-current-Space
windows until the user visits that Space, and (3) never `app.activate()` a
window on a non-current Space during recovery. Until then, restore is only safe
for single-Space sessions — which should be stated as a known limitation.

---

## 4. Invariants the ownership model must guarantee

These are the contracts any chosen model (A-hardened or B) must satisfy. Each is
checkable headlessly (proposed assertions in §5).

1. **Never teleport the user to another Space.** No focus/adopt/restore path may
   `activateApp`/raise a window that is not on the Space the user is currently
   viewing. (Violated today by scenario (d) focus and by `recover()`’s
   `app.activate()`.)
2. **Never pull a foreign-Space window onto a strip.** Adoption is gated to the
   current Space — already true in steady state (`ResyncPlanner.swift:82`,
   `AdoptionScope`), but must remain true through the model change, including the
   fast-adopt path (`LifecycleMonitor.swift:386-409`).
3. **Never strand a strip on a Space the user is viewing.** If the user is
   demonstrably on Space S (Track 1 signal) the strip for (display, S) must be
   live and adopting — not frozen because its *windows* wandered off. (Violated
   by (a)/(e).)
4. **Never silently drop a managed window.** A window moved to another Space is
   not "closed"; it must be either re-homed to that Space's strip (Model B) or
   retained safely without being repositioned/teleported (Model A-hardened),
   never removed just for leaving the current Space (today: kept — correct — but
   as a stranded column, which violates #1 on focus).
5. **Viewport correctness on Space-enter.** On entering a strip's Space, the
   engine re-commits its layout exactly once so positions match the model
   (tighten the conditional re-teleport, §1.4).
6. **Restore lands windows on their original Space or defers.** No restore writes
   a frame to a window on a non-current Space without confirmation (§3).
7. **Idempotent freeze/thaw.** A freeze→thaw round-trip with no real change is a
   no-op on the model (today: holds — repro (c)); must continue to hold.

---

## 5. Proposed data-model changes + tests

### 5.1 Data model (proposal, not yet implemented)

```
// A stable-ish handle for a native Space. Public build = content fingerprint;
// opt-in build = wraps CGSGetActiveSpace(). Track 1 owns the construction.
struct SpaceKey: Hashable { /* fingerprint or opaque id */ }

// DisplayStrip gains a per-Space engine map instead of a single engine.
final class DisplayStrip {
    var displayID: CGDirectDisplayID?
    var engines: [SpaceKey: TeleportEngine]   // one strip per Space on this display
    var liveSpace: SpaceKey                    // which engine is currently active
    var engine: TeleportEngine { engines[liveSpace]! }  // back-compat accessor
}

// RestoreStore.Entry gains a Space tag.
struct Entry: Codable { /* …existing… */ var space: SpaceKey? }
```

Step-1 (no stable key yet) variant: keep one engine but add a `SpaceGuard`
helper — a pure function `canActivate(window, currentSpaceIDs) -> Bool` and
`isUserOnStripSpace(signal) -> Bool` — so the focus/restore guards and the
"thaw because the user is here" logic are unit-testable without a real key.

### 5.2 Headless tests to lock the behavior

Track 5 has already added a real Space API to the sim
(`SimWindowWorld.setActiveSpace(_:)`, `setWindowSpace`/`nativeSpace`,
`subscribeActiveSpace`, `knownSpaces()` — `SimWindowWorld.swift:108-122,
235-266`). The tests below should drive *that* infra (not my standalone repro,
which only proves the *current* behavior). Proposed assertions, keyed to the
invariants:

- **T1 (inv #1, the d-teleport):** Adopt 2 windows on Space 1; move one to Space
  2 via `setWindowSpace`; stay on Space 1; `engine.focus(index:)` onto the moved
  column. Assert **no** `activateApp(pid:)` fired for the off-Space window (add a
  spy to the sim's `activateApp`), i.e. the user is not yanked to Space 2.
- **T2 (inv #3, the a/e-trap):** Adopt on Space 1; `setActiveSpace(2)`; open a
  window on Space 2 (`addWindow(... nativeSpace: 2, notify: true)`). Under
  Model B (or A-hardened with the Track-1 signal): assert the window **is** tiled
  on Space 2's strip. Under today's code this is the *negative* control — assert
  it is currently ignored, documenting the gap.
- **T3 (inv #4):** Move a managed window to Space 2; assert it is **not removed**
  from management and its frame is **not rewritten** while the user is on Space 1
  (no stranded teleport).
- **T4 (inv #5):** Freeze on Space 2, return to Space 1; assert the engine issued
  a full re-commit (`engine.totalCommits` increased / positions match the model).
- **T5 (inv #6, restore):** Save a strip spanning Spaces 1 and 2; simulate crash;
  `recover()` while on Space 1; assert windows tagged Space 2 are **not**
  repositioned/activated until `setActiveSpace(2)`.
- **T6 (inv #7):** Round-trip Space switch with no change is a model no-op
  (already proven by `ownership_repro.swift` scenario (c); port to the sim once
  Model B exists).

These belong in a new `func runHeadlessSpacesOwnershipTest()` (a verb like
`spacestest`) so they live alongside the other headless suites and run under
`make test` — but I deliberately did **not** add them to the shared
`HeadlessTests.swift`/`main.swift` now, because Tracks 1/3/4/5 are concurrently
editing those exact files; the shared sim Space API they need is still in flight.
The standalone `docs/spaces/repro/ownership_repro.swift` is the runnable
artifact for *this* track and is self-contained.

### 5.3 What I implemented here

`docs/spaces/repro/ownership_repro.swift` — a self-contained, dependency-free
reproduction of all five current behaviors (a, b, c, d, e), vendoring the exact
`ResyncPlanner.decide` logic and `applyResync` plumbing so it cannot drift. It is
the empirical backing for §1.3 and the most surprising findings (the (a)/(e)
"frozen on a Space you're viewing" trap and the (d) stranded-column teleport).
It does not touch real windows, does not require Accessibility, and does not
modify any tracked source — keeping `make test` green.

---

## 6. Coordination notes

- **Track 1 (Space detection):** Model B's `SpaceKey` is *your* deliverable. The
  public-API fingerprint vs opt-in `CGSGetActiveSpace` decision gates whether
  Model B is crisp or approximate. My §2.3/§2.4 assume your finding that a stable
  id needs private APIs.
- **Track 4 (movement/removal):** I own the *focus/activation* side of the
  stranded-column bug (inv #1); you own the *removal/cleanup* side. They must
  agree: a moved window should be re-homed (Model B) or retained-without-teleport
  (Model A-hardened), never dropped for leaving the Space.
- **Track 5 (sim infra):** my proposed tests (§5.2) target your
  `setActiveSpace`/`nativeSpace` API. Once it lands, T1–T6 can be written against
  it directly.
- **Track 3 (fullscreen/multi-display Spaces):** "Displays have separate Spaces"
  multiplies Model B's key space to `(display, Space)` — already reflected in my
  data model. Fullscreen apps are their own Space; the same ownership rules
  apply.
