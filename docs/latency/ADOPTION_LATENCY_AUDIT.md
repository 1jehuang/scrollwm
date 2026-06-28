# Adoption / re-placement latency audit

Goal (user ask): "in all situations things should be very fast" - verify EVERY
way a window enters / re-enters the strip is event-fast, not poll-bound.

Harness: `WindowLab adoptlatency` (headless, part of `make test`). Drives the
REAL engine + `LifecycleMonitor` against `SimWindowWorld` with a deliberately
SLOW 5s poll, so any sub-second result PROVES an event-driven fast path (not the
poll). Each scenario establishes the precondition (the window really left / is
off the active strip) before timing the return, so a false-"fast" cannot slip
through.

## Paths and results

| # | Situation | Trigger | Result |
|---|-----------|---------|--------|
| A | New window in a running app (warm) | `kAXWindowCreated` -> `fastAdopt` (frame-paced retry) | FAST ~10ms |
| - | New app's FIRST window (cold start) | `didLaunchApplication` -> `fastAdopt(coldStart)` | FAST (see `coldstartflash*`) |
| B | Un-minimize a managed window | (column HELD; never dropped) | INSTANT ~13ms |
| C | Exit native fullscreen | `activeSpaceDidChange` (fullscreen = own Space) -> resync un-suspends | FAST ~65ms |
| D | Un-hide app (Cmd-H undo) | (column HELD; never dropped) | INSTANT ~13ms |
| E | Switch to a Space holding a managed window | `activeSpaceDidChange` -> resync re-places | FAST ~15ms |

All FAST. Two findings worth recording:

### B/D are not a latency path at all (by design)
A managed window the user MINIMIZES or HIDES (Cmd-H) is NOT removed from the
strip: removal keys on AX existence/role (`existing.filter role == AXWindow`),
and a minimized/hidden window still exists with role `AXWindow`. So its column is
HELD in place; restoring it needs no re-adoption and there is zero latency. The
earlier intuition "un-minimize waits for the poll" was wrong - there is nothing
to wait for.

### C/E ride the existing native-Space signal
`LifecycleMonitor` observes `NSWorkspace.activeSpaceDidChangeNotification`
(debounced 50ms -> `resync`). Entering/leaving native fullscreen moves the window
to/from its own Space, and switching Spaces fires the same edge, so both re-place
within one debounced resync (~tens of ms), not the 2s poll.

## Change made

Added four more AX notifications to `WindowEventObserver.observedNotifications`:
`kAXWindowMiniaturized`, `kAXWindowDeminiaturized`, `kAXApplicationShown`,
`kAXApplicationHidden`. They route through the existing coalesced general resync
(no-op when nothing changed). The audit shows A-E are already fast WITHOUT them
(Space changes + held columns cover everything), so this is hardening, not a
fix: it makes the menu mini-map / size-reconcile react immediately to a
same-Space minimize/hide/restore (which fires NO Space change and NO create
event), instead of lagging up to one poll interval. These are rare user actions,
the resync is coalesced, so the cost is negligible.

## Not addressed (pre-existing, orthogonal to latency)

A managed window whose POSITION drifts with NO size change (e.g. an app moving
its own window without resizing) is not re-teleported by `applyResync` - the
re-place only fires on `removed || evicted || added || sizeChanged ||
suspensionChanged`. This is a correctness gap, not a latency gap, and is not a
real macOS behavior for the transitions audited here (restored windows keep their
frame). Flagged for a separate change if it ever bites.
