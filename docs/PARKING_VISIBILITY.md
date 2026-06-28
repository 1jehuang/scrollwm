# Parking visibility — can we hide parked windows entirely?

Question: the off-screen "parking sliver" confuses users. Can we park columns so
the user **never sees them at all**?

## TL;DR

**No — not by window position alone.** macOS (AppKit `constrainFrameRect`, the
"keep the title bar reachable" rule) forces a ~40px sliver of any standard window
to stay visible on *some* display, at *every* edge. This is the same constraint
other no-private-API tiling WMs (AeroSpace, etc.) hit. To make a parked window
truly invisible you must either **minimize** it (full-hide but animated + Dock
clutter) or **cover** the sliver with something ScrollWM controls.

## Evidence (measured on this machine, 2026-06-27)

Two independent methods agree:
1. Real Accessibility path (`AXUIElementSetAttributeValue` position), measured
   while the debug binary still had its AX grant.
2. Self-move of a process's own `NSWindow` (needs no permission), which exposes
   the identical WindowServer/AppKit clamp.

| Strategy | Result |
|---|---|
| Park x = `maxX + 4000` (today's production parking) | clamped back; **40px sliver** at the right edge, `isOnscreen=true` |
| Park x = `-50000` (far left) | clamped; **40px sliver** at the left edge |
| Park y = `maxY + 50000` (far down) | clamped; **32px title-bar sliver** at the bottom |
| Shrink to 1×1 then park | still a **40px sliver** (chrome floor) |
| Push "up" off the top edge | **only "hid" because a 2nd display is stacked above** — the window just moved onto that monitor. Re-checking against *all* displays: visible. On a single display the top edge keeps a sliver too. |
| Borderless window (no title bar) self-move | escapes the clamp entirely (fully off-screen) — but we do **not** own the user's windows and cannot change their style mask. |
| AX minimize (`kAXMinimized=true`) | **fully hidden** (drops from on-screen list), but ~**578ms** genie animation + lands in the Dock; un-minimize ~70ms + animation |

### Other measured facts that constrain the design
- **`AXRaise` does NOT change the frontmost app / keyboard focus.** So we can
  re-order z-order freely without stealing focus.
- A parked window (sliver, or covered) **stays in the WindowServer on-screen
  list with `isOnscreen=true`.** Important: `ResyncPlanner` relies on parked
  windows looking "still on the current Space," so any new scheme must preserve
  this (minimize would NOT — it drops out of the list).

## Why the current design shows it on purpose
`peekInset` (default 48, commit 804ee19) deliberately *reserves a lane* so the
unavoidable sliver peeks through as a "navigation hint." That is exactly the
thing users read as a stray/broken window. The sliver is an OS artifact; the
peek lane just stopped on-screen columns from covering it.

## Options to actually achieve "never see it"

1. **Minimize parked columns** — true full-hide, but the genie animation fires on
   *every* scroll-off (parking happens constantly during nav) and the Dock fills
   up. Too disruptive. Reject as the default.

2. **Cover the sliver via z-order + edge-to-edge layout** — set `peekInset = 0`
   and raise on-screen columns above parked ones each teleport. **MEASURED
   UNRELIABLE — rejected.** macOS z-orders windows *per app*, and `NSApp.activate`
   is all-or-nothing. ScrollWM MUST activate the focused column's app to route
   keyboard focus, which raises *every* window of that app — including any PARKED
   ones — above other apps' on-screen columns. So in the common "several windows
   of one app" case, focusing one column pops the others' parked slivers in front
   of the covering columns. Verified with a 2-app experiment: after the parked
   app is activated, its sliver sits in front of the other app's edge column.
   AXRaise has no "lower" counterpart, so we cannot push one app's window below
   another's reliably.

3. **Owned opaque edge scrim** — ScrollWM draws a thin borderless `.floating`
   window IT owns over the sliver region on each side that has parked columns.
   **MEASURED RELIABLE.** A `.floating`-level borderless window composites ABOVE
   every normal app window (including a just-activated parked app), and
   `orderFrontRegardless` from the long-running accessory agent does NOT change
   the frontmost app (no focus theft). Verified: `frontAtRightEdge=SCRIM` across
   samples including right after the parked app re-activates, with the real app
   staying frontmost. Cost: a solid bar at the very edge; style it as an
   intentional "more windows that way" affordance (subtle gradient/handle), which
   turns the OS artifact into a deliberate signal. Preserves the on-screen-list
   invariant (parked windows still report on-screen), so `ResyncPlanner` is
   unaffected.

### Recommended (decided)
**Ship (3): the owned edge scrim + `peekInset = 0`.** This is the only approach
that guarantees the user never sees a confusing window sliver, in every layout,
without minimize's animation/Dock cost. (2) is rejected on measured evidence;
minimize stays rejected for the scroll path. The scrim is shown per-side ONLY
when at least one column is parked off that side and reaches the display edge.
