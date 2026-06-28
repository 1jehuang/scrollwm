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
   so on-screen columns span to the screen edge, and raise on-screen columns
   above parked ones each teleport (AXRaise, no focus theft). Zero new chrome,
   cheap. Hides the sliver **whenever an on-screen column reaches that edge**
   (the common case: content fills the viewport). Gap case (few columns, a
   narrow focused column floating with empty viewport on a side that also has a
   parked column) can still expose a sliver.

3. **Owned opaque edge scrim** — ScrollWM draws a thin borderless window over the
   sliver region on each side that has parked columns. Robust regardless of
   viewport gaps (always sits exactly over the sliver). Cost: a visible solid bar
   at the edge; can be styled as an intentional "more windows that way"
   affordance instead of a confusing window sliver.

### Recommended
Layered: **(2) as the default** (no chrome, kills the confusing sliver in the
normal case) + **(3) as an opt-in/fallback** for a hard "never, ever a pixel"
guarantee. Both preserve the on-screen-list invariant so `ResyncPlanner` is
unaffected. Minimize stays rejected for the scroll path.
