# 05 — Empirical reproduction + Sim Space-modeling infrastructure (Track 5)

Owner: Track 5. Two jobs: (A) build the shared headless sim Space-modeling
infrastructure other tracks test against; (B) empirically anchor the real-world
Spaces glitches. Golden rule obeyed throughout: **no real user window was ever
arranged, moved, focused, or closed.** Live work is sandbox-only.

---

## JOB A — Shared sim Space-modeling infrastructure (DELIVERED)

Status: **done, committed (`31ff024`), `make test` green, `spacetest` 22/22.**
Announced to the swarm via `swarm share key:sim_space_api`.

### What macOS actually does (the fidelity we needed)

`CGWindowListCopyWindowInfo(_:_)` with `kCGWindowListOptionOnScreenOnly` returns
**only the windows on the Space the user is currently viewing**. A window living
on another Space (another Desktop, or a fullscreen Space) is *absent* from that
on-screen list, yet still fully present in the Accessibility tree
(`AXUIElementCopyAttributeValue(app, kAXWindowsAttribute)` spans all Spaces).
ScrollWM has no Space API; it *infers* the current Space by intersecting AX with
the CG on-screen list (`CGWindowSource.swift:29`, `IdentityMatcher`,
`LifecycleMonitor.applyResync` `LifecycleMonitor.swift:193`).

**Empirically confirmed against the real WindowServer (read-only probe, this
machine, 2026-06-27 01:40Z):**

```
REAL WindowServer probe (layer-0 / normal windows):
  ALL spaces      layer0 windows: 170
  ONSCREEN (curr) layer0 windows:  23
  in ALL but NOT onscreen (other Spaces / hidden): 147
```

So 147 of 170 normal windows are on *other* Spaces and correctly vanish from the
`onScreenOnly` list while remaining enumerable. This is exactly the behavior the
sim now models, so headless tests exercise the production current-Space scoping.

### The minimal additive model (what I built)

All edits are in `SimWindowWorld.swift` (I am the sole owner of its Space edits)
plus thin helpers in `HeadlessHarness.swift`. **Production is byte-identical**:
the backend is only consulted when `AXSource.backend != nil`, which is only ever
true in headless tests.

Per-window state (`SimWindowWorld.Win`, `SimWindowWorld.swift:59`):

- `var nativeSpace: Int` — the Mission Control Desktop the window lives on.
  Defaults to the world's active Space at creation, so any test that never
  touches the Space API sees one Space (id 1) and is unchanged.

World state (`SimWindowWorld.swift:116`):

- `private var activeSpaceID: Int = 1` — the Space the user is viewing.
- `private var onActiveSpaceChanged: ((Int) -> Void)?` — the
  `NSWorkspace.activeSpaceDidChangeNotification` stand-in.

Test-facing API (`SimWindowWorld.swift:209`–`266`):

| API | Models |
| --- | --- |
| `addWindow(..., nativeSpace: Int? = nil)` | open a window on the current Space (`nil`) or explicitly on another Space |
| `var activeSpace: Int` | which Space is being viewed (read-only) |
| `setActiveSpace(_ space: Int)` | Ctrl-Left/Right, Mission Control, fullscreen-Space toggle. No-op if unchanged. Fires the hook async-on-main *after* the switch |
| `setNativeSpace(_ el, _ space)` | "send window to Desktop N" without moving its frame |
| `nativeSpace(of:)`, `knownSpaces()` | assertions |
| `subscribeActiveSpace(_ handler:)` | subscribe/unsubscribe the activeSpaceDidChange hook |

The one behavioral change that matters: `cgWindows(onscreenOnly:true)` now drops
any window whose `nativeSpace != activeSpaceID`
(`SimWindowWorld.swift:312`), with **no** `isMinimized`/app-hidden side effects
(unlike the prior `setAppHidden` lever, which the engine treats differently).
This is the single seam that drives `ResyncPlanner.frozenDifferentSpace`
(`ResyncPlanner.swift:61`) and the `arrange`/`fastAdopt` current-Space gates.

Harness sugar (`HeadlessHarness.swift:80`–125):

- `Headless.arrangeCurrentSpace(engine, pids:)` — fuse + adopt current-Space
  windows exactly as production `arrange` does.
- `Headless.resyncDecision(engine, pids:)` — run the *exact* `applyResync` token
  mapping and return the `ResyncPlanner.Decision`, so a test can assert
  freeze-vs-apply without spinning the 2 s safety-net poll.

### Tests (`SpaceSimTests.swift`, verb `WindowLab spacetest`, in `make test`)

22 assertions through the **real** `LifecycleMonitor` + `ResyncPlanner`, fully
headless. They pin both correct behavior and a current bug:

1. Switching the active Space empties the on-screen list while off-Space windows
   stay in AX (the core fidelity).
2. Strip built on Space 1, user on empty Space 2 ⇒ planner returns
   `frozenDifferentSpace`; the monitor adds/removes nothing.
3. A window opened on the non-active Space 2 is **not** adopted into the Space-1
   strip (the "new window on another Space" case).
4. Returning to Space 1 resumes management with identical columns; the Space-2
   window is never adopted.
5. **Phantom column (current bug, pinned):** sending a *managed* window to
   another Space while the user stays put leaves it in the strip as a stale
   column — it left the on-screen list but still exists in AX, so the planner
   keeps it (`ResyncPlanner` only removes windows AX no longer reports at all,
   `ResyncPlanner.swift:78`).
6. `activeSpaceDidChange` fires once per real switch, never on a no-op.

```
[headless-spacetest] 22 passed, 0 failed
ALL headless integration tests PASSED (6 suites)
```

### How Tracks 1/4/3 consume it

- Track 1 (detection): `subscribeActiveSpace` is the headless
  `activeSpaceDidChangeNotification`; their `spacedetecttest` proves
  signal-fast adopt vs poll-late staleness.
- Track 4 (movement/removal): `setNativeSpace` models send-to-Desktop /
  parking-sliver oscillation without `setAppHidden` side effects.
- Track 3 (fullscreen): a fullscreen Space is just another `nativeSpace` id;
  `setActiveSpace` toggles into/out of it. (They may keep their `setAppHidden`
  approximation; both work.)

---

## JOB B — Live reproduction (sandbox only)

### Environment captured

- Single built-in display (2560×1664 Retina), `com.apple.spaces spans-displays
  = 1` (one Mission Control Space spans all displays).
- 4 regular Desktops present (ManagedSpaceID 1, 3, 4, 31) + at least one
  fullscreen Space historically; Ctrl-Left/Right (`AppleSymbolicHotKeys` 79/81)
  and Mission Control (32) all enabled.
- The user's **real** ScrollWM.app (pid 27088, v0.1.5) is running and was
  actively managing real windows (Firefox, …). Sandbox windows spawn as
  `.accessory` apps (`TestWindows.swift:12`), which the real app's
  regular-apps-only monitor never enumerates, so a sandbox cannot collide with
  the real session.

### Blocker hit: screen was LOCKED during this work window

At the time of the live attempt the GUI session was **locked**
(`CGSSessionScreenIsLocked = 1`). Two empirical consequences, both recorded:

1. **`arrange` refuses while locked** — the sandbox launched and spawned its 4
   windows, but `arrange` logged `arrange: session locked/inactive, refusing`
   and adopted 0 windows. This is by design: `LifecycleMonitor.sessionIsActive()`
   gates every resync (`LifecycleMonitor.swift:121`, read at `:148` and `:353`).

2. **AX collapses under lock.** Read-only `WindowLab probe`:
   - Unlocked (01:29Z): `AX windows: 18 across regular apps`, 16/18 fused.
   - Locked   (01:40Z): `AX windows: 1 across regular apps`, 0/1 fused — while
     CG still reported 23 on-screen / 37 total.

   This is the precise scenario the `skipDegraded` rule defends against
   (`ResyncPlanner.swift:72`: "AX suddenly reports most of a non-trivial strip
   gone"). If the strip were managing when the screen locked, a naive resync
   would see almost every window vanish from AX and mass-remove the strip; the
   degradation guard + `sessionIsActive()` lock guard are what prevent that.
   **Real ground truth for why both guards exist.**

I cleaned up the idle sandbox immediately (no leaked windows) and did **not**
force the lock or touch the real session.

### Repro automation prepared (sandbox-only, lock-guarded)

`scripts/track5-spaces-repro.sh` drives only `WindowLab sandbox N` over a private
control socket and records, with millisecond timestamps, the sandbox strip state
(`scrollwm status` JSON) and the WindowServer on-screen count before/after each
scripted Space event (E1 switch away/back, E2 open-window-on-other-Space, E3
send-window-to-Desktop, E4 enter/exit fullscreen). It **aborts if the screen is
locked** (verified) and cleans up on exit. It is interactive (the human performs
each Ctrl-arrow / Mission Control / fullscreen step, then presses RETURN), which
keeps the manual Space actions in the human's hands while the harness captures
ground truth. To run once unlocked:

```
scripts/track5-spaces-repro.sh 4
```

### Predicted live symptoms (to confirm with the harness), each tied to code

These follow directly from the architecture + the headless repro (`spacetest`),
and are the things to time/confirm live:

| # | Action | Expected glitch | Why (code) |
| - | ------ | --------------- | ---------- |
| E1 | Ctrl-Right away from sandbox Space, then back | While away: strip is a **stale snapshot**, no updates. On return there can be up to a **2 s lag** before the strip reconciles, because adoption resumes only on the next safety-net poll. | Monitor freezes on a different Space (`ResyncPlanner.frozenDifferentSpace`, acted on at `LifecycleMonitor.swift:230`); no Space-change signal exists, so resync is poll-driven (`interval = 2.0`, `LifecycleMonitor.swift:73`). |
| E2 | Open a sandbox window while on another Space | New window is **not** adopted until you return to the sandbox Space (then up to one poll later it snaps in). | `fastAdopt` gates on the current-Space CG list and bails when the strip isn't on the current Space (`LifecycleMonitor.swift:413`); retries lapse, poll converges. |
| E3 | Send a managed sandbox window to another Desktop | **Phantom column:** the strip keeps a slot for a window that is no longer on this Space; the viewport reserves space for it / shows a gap. | The window still exists in AX, so `ResyncPlanner` never removes it (`ResyncPlanner.swift:78`); proven headless in `spacetest` assertion "PHANTOM COLUMN". |
| E4 | Fullscreen a sandbox window then exit | Entering fullscreen creates a new Space ⇒ same freeze as E1; the **overlay**, which is `.canJoinAllSpaces` + `.fullScreenAuxiliary` + `.stationary` (`MetalOverlay.swift:385`), may render on the wrong Space / over the fullscreen app. On exit the window returns minus its fullscreen size, and the strip may re-fit with a viewport jump. | Fullscreen Space == another `nativeSpace`; overlay collection behavior pins it across Spaces. |

These are exactly the theories Tracks 1–4 are designing fixes for; the headless
`spacetest` already reproduces E1–E3 deterministically, and the real-WindowServer
probe confirms the underlying on-screen/all-Spaces split that makes them happen.

---

## Recommendations (public-API only)

1. **Adopt a real Space-change signal.** Observe
   `NSWorkspace.shared.notificationCenter` for
   `activeSpaceDidChangeNotification` and trigger an immediate resync instead of
   waiting up to 2 s. Public API, one notification, no private frameworks. The
   sim's `subscribeActiveSpace` hook is the headless mirror so this is testable
   now (Track 1 owns the production wiring).
2. **Distinguish "removed" from "on another Space" for managed windows.** Today
   `ResyncPlanner` can only tell *closed* (gone from AX) from *present*; a window
   sent to another Space stays a phantom column. A correct fix needs a
   per-window Space identity. **This is the one place a fully correct fix may be
   impossible with public API only:** there is no public AX/CG attribute that
   reports a window's Space id (the CGS/SkyLight Space APIs are off-limits per
   AGENTS.md). Options: (a) heuristically treat "in AX but off the on-screen list
   for N polls while the strip IS on the current Space" as moved-away and stash
   it; (b) document the limitation. Tracks 2/4 own the policy; the sim now lets
   either be tested (`setNativeSpace` + `resyncDecision`).
3. **Keep the lock/degradation guards.** The locked-session probe above is
   concrete evidence they are load-bearing; do not weaken `sessionIsActive()` or
   `skipDegraded`.

## Files

- `Sources/WindowLab/SimWindowWorld.swift` — native-Space model (Track 5 owned).
- `Sources/WindowLab/HeadlessHarness.swift` — `arrangeCurrentSpace`,
  `resyncDecision`, suite wiring.
- `Sources/WindowLab/SpaceSimTests.swift` — `spacetest` (22 assertions).
- `Sources/WindowLab/main.swift` — `spacetest` dispatch case.
- `scripts/track5-spaces-repro.sh` — sandbox-only, lock-guarded live harness.
