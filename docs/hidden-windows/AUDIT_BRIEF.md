# Hidden-Windows Audit Brief (ScrollWM)

Goal: make sure EVERY edge case around hidden / minimized windows in `arrange`
is fully resolved, well handled, thought through, and that the behavior is very
clear to the user.

You are ONE auditor in a headless swarm. You are READ-ONLY:
- Do NOT modify any file.
- Do NOT run `swift build`, `make`, or any test binary (the coordinator owns the
  build/test/worktree; parallel builds corrupt `.build`).
- You MAY read code, grep, and reason. You MAY read (not run) the test files.

## Current behavior (branch: feature/per-space-strips)

`ScrollWMController.arrange(pidFilter:)` (Sources/WindowLab/ScrollWMApp.swift ~L1290):
1. Guards `LifecycleMonitor.sessionIsActive()`.
2. Calls `WindowReveal.reveal(pidFilter: sandboxPIDs ?? pidFilter)` to un-hide
   Cmd+H apps and de-miniaturize minimized standard windows.
3. If `reveal.didReveal`: calls `arrangeAdoptNow(pidFilter:)` immediately, then
   schedules a deferred (0.45s) pass that either resyncs every managing strip
   (if already managing) or calls `arrangeAdoptNow` again (if still dormant).
4. Else: calls `arrangeAdoptNow(pidFilter:)` directly.

`arrangeAdoptNow` (~L1334): if managing -> resync every strip; else enumerate AX
windows, fuse with the CG on-screen (current-Space) list, scope to display,
adopt, start lifecycle, focus 0.

`arrangeAllWindows` (~L1496): the menu "Arrange All Windows (reveal + fit on
screen)" - reveals, waits, then `adoptEverythingNow` which arranges + equalizes.

`WindowReveal.reveal` (Sources/WindowLab/WindowReveal.swift): headless path uses
`AXSource.backend`; production path uses NSWorkspace + AX. `shouldUnminimize`
keys on role==AXWindow (not subrole). `appsToUnhide` is a pure helper.

CLI: `scrollwm arrange [width]` (Sources/WindowLab/ControlCommands.swift ~L34)
returns synchronously after `arrange()`.

Menu labels (ScrollWMApp.swift ~L2638/2645/2654/2658):
- "Arrange Windows into Strip (incl. hidden & minimized)"
- "Arrange All Windows (reveal + fit on screen)"

Headless seam: `SimWindowWorld` models hidden/minimized + on-screen list +
native Spaces. Tests: `WindowLab revealtest` (headless `runHeadlessRevealTest`
in HeadlessTests.swift, live `runWindowRevealTest` in WindowRevealTest.swift),
reveal predicates in StripOpsTests.swift, TileabilityTests.swift.

## Key invariants (must NOT be broken)
- Space safety: never reach into another native Space and teleport the user.
  `arrange`/`resync` adopt only CURRENT-Space windows (AX ∩ on-screen CG).
- Sandbox lock: `sandboxPIDs` forces every path through that PID filter.
- AX readback: apps clamp sizes/positions silently; read back real frame.
- Only one permission (Accessibility). No new permissions/private APIs.

## What to deliver
Return a findings report (markdown). For each finding give:
- ID + one-line title
- Facet
- Severity: BUG (wrong/unsafe) | UX (unclear/confusing) | GAP (missing test) | NIT
- Concretely: the scenario, current behavior, why it is wrong/unclear, and a
  specific recommended fix (code location + approach). Prefer fixes that extend
  the SimWindowWorld + a headless assertion.
- Confidence (high/med/low) that this is a real issue.

Be concrete and skeptical. Trace the actual code; cite file:line. Do not invent
issues; if a path is correct, say so briefly. Cross-check your facet against
adjacent code.
