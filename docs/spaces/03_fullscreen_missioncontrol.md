# Track 3 — Native fullscreen Spaces, Mission Control, and "Displays have separate Spaces"

Status: INVESTIGATION + headless repro. No production behavior changed. New
headless test `WindowLab fullscreentest` (18 checks, in the `headlesstest`
suite) reproduces the core gaps. All claims are backed by `file:line` or a repro
assertion in `Sources/WindowLab/FullscreenSpaceTests.swift`.

TL;DR of the macOS facts this track covers:

- A window in **native macOS fullscreen** lives on its **own dedicated Space**.
  Entering fullscreen = (a) `AXFullScreen` flips true and (b) the window leaves
  the current Space's on-screen list and becomes the sole resident of a new
  Space that immediately becomes active.
- **"Displays have separate Spaces"** (System Settings ▸ Desktop & Dock) is a
  global toggle. ON (the modern default): every display has its OWN, independent
  set of Spaces and its OWN menu bar. OFF (legacy): ONE Space spans all displays.
- **Mission Control / Show-All-Windows / App Exposé** are WindowServer visual
  modes; they do not create/destroy app windows, but they transiently change the
  WindowServer on-screen geometry/layer the CG list reports.

ScrollWM has **no Space API at all** (`00_BRIEF.md`); it infers "current Space"
purely by intersecting AX (all Spaces) with the CG on-screen list (current
Space). That heuristic is exactly where the special Space types bite.

---

## 0. Where the "overlay" actually is (correcting a premise)

The brief asks about "the overlay's `.canJoinAllSpaces` + `.fullScreenAuxiliary`"
(`MetalOverlay.swift:385`). **That overlay is NOT in the production window
manager.** `MetalOverlay.runOverlay(...)` is only reached by the standalone
`overlay` benchmark verb (`main.swift:188-190`) — a Metal scroll-latency harness.
The production app draws its strip indicator as a **menu-bar `NSStatusItem`
mini-map** (`MenuBar.swift:41`, `ProductionMenuBar` `ScrollWMApp.swift:1387`),
not a full-screen `NSWindow`. ScrollWM moves the user's real app windows directly
(`TeleportEngine.teleport()` AX writes, `TeleportEngine.swift:650`); there is no
always-on-top canvas window over the desktop.

Consequence: point 4 below is reframed around the **status-item mini-map**, which
is what the user actually sees on a fullscreen Space. (If a future design adds a
real overlay canvas, the `MetalOverlay` collectionBehavior analysis becomes live;
I cover that as a forward-looking note in §4.)

---

## 1. NATIVE FULLSCREEN: strip + overlay when a managed window goes fullscreen

### What ScrollWM does today (trace)

Adoption deliberately **excludes** fullscreen windows at every entry point:

- `arrange` adopt filter: `!$0.ax.isMinimized && !$0.ax.isFullscreen`
  (`TeleportEngine.adopt`, `TeleportEngine.swift:232-234`).
- Resync adoptable set: `standard = standardExisting.filter { !$0.isMinimized && !$0.isFullscreen }`
  (`LifecycleMonitor.swift:174`).
- Fast-adopt: `... && !$0.isFullscreen` (`LifecycleMonitor.swift:368`).
- `AXFullScreen` is read at `AXSource.swift:186`.

But **existence ≠ adoptability**. The resync keeps a SECOND, unfiltered set
`standardExisting` (`LifecycleMonitor.swift:171-173`) and feeds *that* to the
planner as `axIDs` and to the removal test (`LifecycleMonitor.swift:204,
219-221, 241-243`). The explicit rationale is in the comment at
`LifecycleMonitor.swift:168-170`: *"A managed minimized/fullscreen window still
exists and must not be silently dropped from the strip."* So once a column is
managed, going fullscreen does **not** remove it.

Now combine that with the dedicated-Space fact. Two sub-cases, and they behave
very differently:

#### 1a. NON-solo: other managed columns remain on the origin Space → PHANTOM STRAND

When a managed window enters fullscreen it moves to its own Space (now active),
but the OTHER managed columns are still on the origin Space. In the planner's
terms (`ResyncPlanner.decide`, `ResyncPlanner.swift:48`):

- `stripPresentInAX` = all columns (all still exist in AX) → the freeze guard
  (`ResyncPlanner.swift:58-62`) checks whether ANY managed window is on the
  current Space. The fullscreen window IS on the current (its own) Space, so the
  strip is judged "present here" and is **NOT** `frozenDifferentSpace`.
- Removal keys on AX existence (`ResyncPlanner.swift:78`, mirrored at
  `LifecycleMonitor.swift:241-243`): the fullscreen window is still in AX → not
  removed.

Net: the fullscreen window's strip **column is retained but stranded**. The
engine still owns its geometry and will overwrite the OS-owned fullscreen frame
on the next teleport/resize pass. Repro (`fullscreentest`, Scenario 1):

```
✓ Scenario 1: fullscreen column is NOT dropped (still in AX) - phantom strand
✓ Scenario 1: fullscreen window still managed by the strip
✓ Scenario 1: engine OVERWRITES the OS-owned fullscreen frame (active strand)
```

The third assertion stamps the window to the full-display frame (modelling
macOS owning a fullscreen window), then runs a normal `setWidthFraction(0.25)` on
that very column; the engine writes a narrow strip width straight onto the
fullscreen window (`StripOps.setFocusedWidth`, `StripOps.swift:103`). On real
hardware this is the "ScrollWM fights macOS for the fullscreen window" symptom:
size/resize verbs and `teleport()` target a window the OS is animating.

Note also `reconcileSizes` (`LifecycleMonitor.swift:288`, `TeleportEngine.swift:581`)
will pull the *fullscreen* frame (≈ whole display) back INTO the model as that
column's width on the next poll, which then makes `compactStrip` shove every
later column a full screen-width to the right — the **strip visually explodes**
the moment the poll reconciles a fullscreen column's size. (Not yet asserted in
the repro; flagged as a strong follow-up test once a sim fullscreen-frame model
exists.)

#### 1b. SOLO: the only managed window goes fullscreen → WHOLE STRIP FREEZES

If the fullscreen window is the *only* managed one, then after it leaves, NO
managed window is on the current Space, so `stripPresentInAX` is non-empty but
none are current → `frozenDifferentSpace` (`ResyncPlanner.swift:58-62`). The
strip goes inert: the column is retained (not removed) and **adoption is
blocked** even for new windows opened on that fullscreen Space. Repro
(`fullscreentest`, Scenario 2):

```
✓ Scenario 2: solo-fullscreen strip is frozen, column retained (not removed)
✓ Scenario 2: frozen strip does NOT adopt a new window on the fullscreen Space
```

So the SAME user action (enter fullscreen) yields **opposite** strip states
depending only on how many columns exist — a coherence bug: there is no single
"a managed window went fullscreen" concept, only the emergent freeze/strand
split.

#### 1c. Return from fullscreen → converges

Coming back re-lists the window on the shared Space; one resync re-fits it. No
permanent strand (Scenario 1/4):

```
✓ Scenario 4: returning from fullscreen re-converges to 3 columns
✓ Scenario 2: after return, strip thaws and reconciles (>= 1 column)
```

The damage window is therefore bounded by the 2s safety-net poll
(`LifecycleMonitor.interval`, `LifecycleMonitor.swift:73`) — but during that
window (and during 1a indefinitely) the column is wrong.

### Viewport impact

A stranded fullscreen column still occupies `width`/`canvasX` in the model, so
`compactStrip` (`LifecycleMonitor.swift:562`) reserves a slot-width gap for a
window the user cannot see on this Space, and the viewport math
(`viewportTarget`, `TeleportEngine.swift:575`) scrolls past dead space. With 1a's
`reconcileSizes` blow-up the viewport can scroll an entire screen-width to reach
the next real column.

---

## 2. "Displays have separate Spaces" vs ScrollWM's per-display strip model

### The two macOS modes

- **Separate Spaces = ON (default):** each display is its own Space domain with
  its own menu bar; Mission Control shows per-display Space rows; a fullscreen
  window only takes over ITS display. The CG on-screen list
  (`CGWindowListCopyWindowInfo(onScreenOnly)`, `CGWindowSource.swift:28-35`) then
  contains the union of *each display's currently-active Space*.
- **Separate Spaces = OFF (legacy):** ONE Space spans every display; switching
  Space switches all monitors together. This is the mode `AdoptionScope` already
  reasons about — see its doc: *"With `spans-displays=1` a single Mission Control
  Space covers BOTH monitors"* (`AdoptionScope.swift:11-19`).

### How ScrollWM's model interacts

ScrollWM keys everything off **displays**, never Spaces. One `DisplayStrip` per
physical display (`DisplayStrip.swift:16`), each with its own engine + lifecycle
monitor (`DisplayStrip.swift:19,30`). Adoption is partitioned by best display
overlap so two strips never fight over one window
(`AdoptionScope.partition`, `AdoptionScope.swift:112`; used at
`ScrollWMApp.arrangeMultiDisplay`, `ScrollWMApp.swift:865`). The default single-
strip mode scopes adoption to the strip's own display via
`filterByAdoptScope` (`TeleportEngine.swift:214`, `AdoptionScope.filter`
`AdoptionScope.swift:79`).

This geometry rule is **correct and orthogonal to the separate-Spaces toggle** —
a window belongs to the display it overlaps regardless of mode. The repro pins
that down so we can isolate the real problem to the CG gate, not the geometry:

```
✓ scope: window on strip display belongs to strip
✓ scope: window on the other display does NOT belong to strip
✓ scope: partition is disjoint (no window adopted by two strips)
```

### Where ScrollWM assumes ONE Space spans displays — and breaks under separate-Spaces

The implicit "one Space spans displays" assumption lives in the **shared current-
Space gate**: there is a single `CGWindowSource.listWindows(onscreenOnly:true)`
call per resync (`LifecycleMonitor.swift:175`) and per arrange
(`ScrollWMApp.swift:819`), and its result is fed to EVERY strip's planner via
`currentSpaceIDs`. The `AdoptionScope` doc explicitly frames the multi-display
case as one Space covering both monitors (`AdoptionScope.swift:11-13`).

Under **separate Spaces ON**, that single gate is the union of each display's
independently-active Space. Concrete breakages:

1. **Per-display Space switch freezes the WRONG strip, or neither.** If display A
   switches Space while display B does not, the union CG list still contains B's
   windows. The freeze rule (`ResyncPlanner.swift:58-62`) asks "is ANY of THIS
   strip's managed windows on the current Space" — but "current Space" is now
   ambiguous across displays. Strip A's windows vanish from the union → A
   correctly freezes; but the per-strip monitors share the model and there is no
   notion of "A's Space changed but B's did not," so the freeze is inferred only
   from window membership, not from a Space signal. It mostly works by accident
   because membership still distinguishes them — but a strip whose display is
   showing an EMPTY Space (no managed windows visible, none closed) lands in
   `frozenDifferentSpace` correctly, while a strip whose managed windows happen
   to overlap into the union can mis-adopt (see 2).

2. **Cross-display fullscreen takeover.** Separate-Spaces ON means a fullscreen
   window only claims its own display. The OTHER display's strip is untouched by
   macOS, but ScrollWM's single union gate now lacks the fullscreen display's
   former windows. For the strip on the fullscreen display this is the §1 strand/
   freeze; for the OTHER display's strip it is a no-op only because
   `filterByAdoptScope`/`partition` keep its windows display-scoped. So the
   display-scope geometry is what *saves* multi-display here — but it cannot save
   the fullscreen display's own strip (§1).

3. **`spans-displays` / `allDisplays` scope is a legacy-mode-only concept.** The
   `allDisplays` scope (`AdoptionScope.Scope.allDisplays`, `AdoptionScope.swift:31`)
   means "one strip swallows every monitor." That is coherent ONLY under separate-
   Spaces OFF (one Space really does span displays). Under separate-Spaces ON,
   `allDisplays` will pull windows from a *different display's currently-active
   Space* into one strip, and a per-display Space switch will then strand half of
   them. There is no code that detects the toggle and refuses `allDisplays`.

Bottom line: the per-display *geometry* model is right; the **single shared
current-Space gate** silently assumes the legacy "one Space spans displays"
world, and is the place that misbehaves when separate-Spaces is ON and displays
switch Spaces independently.

---

## 3. Mission Control / Show-All-Windows / App Exposé: spurious freeze/adopt/remove?

### Why a destructive event is unlikely

- **No spurious REMOVE.** Removal keys purely on AX existence
  (`ResyncPlanner.swift:78`, `LifecycleMonitor.swift:241-243`). Mission Control /
  Exposé do NOT remove app windows from AX, so managed columns are never dropped
  during them. Confirmed by construction (the removal predicate is `!standardExisting.contains{CFEqual…}`).
- **No spurious fast-path ADOPT.** The fast path is triggered ONLY by
  `kAXWindowCreated` (`WindowEventObserver` → `fastAdopt`,
  `LifecycleMonitor.swift:84,352`). Mission Control creates no app window, so it
  fires no create event; the fast path stays dormant.
- **Degradation guard.** Even if AX momentarily returned little, `skipDegraded`
  (`ResyncPlanner.swift:71-73`) skips a cycle that lost >half of a ≥4 strip.

### The real transient: CG geometry shifts → planner sees "off current Space"

During Mission Control / Exposé the WindowServer reports SCALED, REPOSITIONED
thumbnails. `IdentityMatcher` scores AX↔CG on PID+frame(+title)
(`IdentityMatcher.swift:19-44`) with `minimumScore = 50`; PID alone is only 40,
and a scaled thumbnail's frame won't land within the 8px window. Without Screen
Recording, CG titles are nil (`IdentityMatcher.swift:37-41`), so frame is
decisive. So during these modes managed windows can **fail to match CG** →
`currentSpaceIDs` shrinks → the strip is judged off-Space.

Crucially, that lands on `frozenDifferentSpace` (`ResyncPlanner.swift:58-62`),
which makes the resync return EARLY (`LifecycleMonitor.swift:230-231`) — **inert,
no teleport, no removal**. So the *correct* outcome (do nothing while the user is
in Mission Control) is reached, but for the *wrong reason* (freeze, not "the user
is mid-gesture"). Is the 2s poll + `skipDegraded` enough?

- **For correctness: yes, mostly.** A poll landing mid-Mission-Control freezes
  (inert) and the next poll after it closes converges. No flicker on the *strip*
  because frozen resyncs don't reposition.
- **Residual risk to verify in sandbox (cannot confirm headlessly):** whether a
  poll that lands exactly as thumbnails are at "rest" could frame-match a managed
  AX window to a DIFFERENT window's thumbnail (a false `cg` match → wrong
  `currentSpaceIDs`). `minimumScore=50` + the 8px frame gate make this unlikely
  but not provably impossible. Flagged as a sandbox check, not a headless one
  (Mission Control's CG geometry is not modeled in the sim and is private to the
  WindowServer).

### Verdict

Mission Control / Exposé do not cause spurious adopt or remove. They can cause a
transient, harmless `frozenDifferentSpace` for the duration of the gesture. The
guards are sufficient for safety; the only open item is the low-probability
false-frame-match, to be checked live.

---

## 4. The status-item mini-map (the real "overlay") across fullscreen Spaces

As established in §0, production has no canvas overlay; the user-visible strip
indicator is the menu-bar `NSStatusItem` mini-map (`MenuBar.swift:41`,
`ProductionMenuBar` `ScrollWMApp.swift:1387`). Behavior across Spaces:

- A status item lives in the system menu bar and is therefore present on EVERY
  Space, including fullscreen Spaces (where the menu bar auto-hides but is
  revealed on hover). So it never "fails to appear" the way a `.canJoinAllSpaces`
  NSWindow might.
- **It can show a STALE strip on a fullscreen Space.** The mini-map binds to ONE
  engine: in single-display, the sole engine; in multi-display, the ACTIVE
  strip's engine (`menuBar = ProductionMenuBar(controller:self, engine:engine)`
  with `engine == activeStrip.engine`, `ScrollWMApp.swift:38,149`). On a fullscreen
  Space the underlying strip is frozen/stranded (§1), so the mini-map keeps
  drawing the origin Space's columns. It is not "the wrong strip" so much as the
  origin strip frozen in time — but to the user it looks like ScrollWM thinks
  windows are present that this Space does not show.
- **Multi-display caveat:** the mini-map follows `activeStrip`, but there is no
  Space-aware rebind, so when a fullscreen window takes over one display the
  mini-map still reflects whichever strip is "active," which may be the frozen
  one.

Forward-looking (`MetalOverlay`): IF a real overlay canvas is ever added, its
current `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
.stationary, .ignoresCycle]` (`MetalOverlay.swift:385`) is the RIGHT set to make
it appear over fullscreen Spaces too — but `.canJoinAllSpaces` would then make it
draw the SAME (origin-Space) strip on a fullscreen Space it does not belong to,
re-introducing exactly the "wrong strip on a fullscreen Space" bug at the render
layer. Any such overlay must gate its content on the per-Space membership, not
just join all Spaces.

---

## 5. Recommendations (public-API only; private-API cases flagged)

### R1 — Treat "a managed window went fullscreen" as a first-class transition (public API: YES)

`AXFullScreen` is already read (`AXSource.swift:186`) and observable: register
the per-app `AXObserver` (already used for create/destroy,
`WindowEventObserver`) ALSO for `kAXWindowMiniaturizedNotification` /
`kAXWindowDeminiaturizedNotification` and, for fullscreen, watch
`kAXWindowResizedNotification` + re-read `AXFullScreen` (there is no dedicated
public fullscreen-changed notification, but resize fires on the
enter/exit-fullscreen animation). On detecting a managed column become
fullscreen:

- **Park, don't strand.** Mark the slot `suspended` (new flag) so `teleport()`
  (`TeleportEngine.swift:640-657`), `reconcileSizes`
  (`TeleportEngine.swift:581`), and resize verbs SKIP it (same mechanism as the
  existing `healthy` guard, `TeleportEngine.swift:642`). This stops the strand
  fight (§1a) AND the `reconcileSizes` width blow-up, while keeping the column so
  exiting fullscreen restores it in place. This unifies 1a and 1b into one
  coherent "fullscreen column is suspended" state.
- Public-API only; no SkyLight/CGS needed.

### R2 — Decouple "current Space" per display (public API: PARTIAL)

The single shared CG gate (§2) should become per-display: filter the on-screen CG
list to each strip's display before computing that strip's `currentSpaceIDs`
(the geometry to do this already exists — `stripDisplayFrame`/`otherDisplayFrames`
on the engine, `TeleportEngine.swift:693,703`, and `DisplayGeometry`). This makes
the freeze/adopt decision honor "this display's active Space" instead of the
union, fixing separate-Spaces independent switching.

- Public API suffices for the *display* split (CG bounds + NSScreen geometry).
- **Private-API-only gap:** knowing *which* Space a window/display is on, or that
  separate-Spaces is even enabled, is not in any public API. `NSScreen
  .screensHaveSeparateSpaces()` exists and IS public — recommend using it to pick
  behavior — but mapping a window to a Space id needs CGS/SkyLight
  (`CGSCopyManagedDisplaySpaces`, `CGSGetWindowWorkspace`), which AGENTS.md
  forbids. So R2 can make the gate display-correct, but cannot make it truly
  Space-id-correct without the forbidden APIs. Document this as the hard ceiling.

### R3 — Detect separate-Spaces mode and constrain `allDisplays` (public API: YES)

Call `NSScreen.screensHaveSeparateSpaces()` (public) at arrange/reload. When it
returns true (separate-Spaces ON) AND `adoptScope == .allDisplays`, warn/refuse:
`allDisplays` is only coherent under the legacy spanning mode (§2.3). Cheap,
public, prevents the cross-display mis-adopt.

### R4 — Mission Control: keep current guards; add a sandbox false-match check (public API: YES)

No code change needed for safety (§3). Add a LIVE sandbox probe (not headless)
that opens Mission Control over arranged sandbox windows and asserts no
remove/adopt and stable columns, to close the low-probability false-frame-match
question. Headless cannot model Mission Control's private CG geometry.

### R5 — Status-item mini-map staleness (public API: YES)

When a strip is frozen/suspended (§1, §4), render the mini-map in a visibly
"paused/off-Space" state rather than as a live strip, so the user is not misled
on a fullscreen Space. Pure UI; reads existing engine state.

---

## 6. Tests delivered + proposed

### Delivered (headless, in `make test` via `headlesstest`)

`Sources/WindowLab/FullscreenSpaceTests.swift` → `WindowLab fullscreentest`
(18 checks, green). Uses Track 5's sim Space API
(`SimWindowWorld.setNativeSpace/setActiveSpace`) + the fullscreen flag, never
touches a real window:

- Pure `ResyncPlanner` contrast: non-solo fullscreen → `apply` (no freeze, no
  remove); solo off-Space → `frozenDifferentSpace`; return → `apply`; helper on
  fullscreen Space is an ADD candidate.
- Pure `AdoptionScope`: display-belonging + disjoint partition (separate-Spaces
  geometry is unaffected).
- Integration Scenario 1: non-solo fullscreen → phantom strand retained + engine
  overwrites the OS-owned fullscreen frame.
- Integration Scenario 2: solo fullscreen → whole strip frozen; new window on the
  fullscreen Space is NOT adopted; thaws on return.

### Proposed (once infra/decisions land)

- **Strip-explosion test (1a):** model a fullscreen window's full-display frame
  and assert `reconcileSizes` does NOT balloon the column width once R1's
  `suspended` skip lands (today it would — a regression guard for R1).
- **Per-display Space gate test (R2):** two sim displays, switch one display's
  Space, assert only that display's strip freezes and the other keeps adopting.
- **`allDisplays` + separate-Spaces refusal (R3):** unit-assert the mode check.
- **Live sandbox Mission Control probe (R4):** `WindowLab sandbox` + manual or
  scripted Mission Control, assert column stability.
