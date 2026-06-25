# Onboarding Polish Swarm — Task Graph

Goal: make **every inch of ScrollWM's onboarding production-ready and polished** —
from download/install, through relocation, the Accessibility grant, the
onboarding window, first-grant auto-arrange, and the first-run tutorial.

You are ONE lane in a parallel swarm. A coordinator owns the shared/integration
surface and merges your work. Stay strictly inside your lane's **owned files**.

---

## GOLDEN RULE (non-negotiable — this runs on the user's real machine)

This tool moves the user's REAL, live windows. NEVER arrange the user's actual
session. NEVER run a bare `WindowLab run` + Arrange, and NEVER call `arrange()`
without a PID filter. For any live behavior, use sandbox / spawned disposable
windows ONLY (`.build/debug/WindowLab sandbox [n]`). Tests are HEADLESS by
default and safe — prefer them. Do not touch Accessibility/TCC state, do not
fire the system permission modal, do not move/quit the running ScrollWM.

---

## Isolation: git worktrees

You work in your OWN git worktree on your OWN branch, forked from
`feature/multi-display`. Your worktree path and branch are in your spawn prompt.
Do NOT `cd` out of your worktree. Do NOT touch other worktrees. Commit to YOUR
branch only with focused messages explaining WHY. The coordinator merges.

---

## File ownership (do not edit files outside your lane)

These are RESERVED for the coordinator (integration surface). If your lane needs
a change here, DO NOT edit it — describe the exact change in your final report
and the coordinator will apply it:

- `Sources/WindowLab/ScrollWMApp.swift`  (controller wiring, launch flow)
- `Sources/WindowLab/main.swift`         (subcommand dispatch)
- `Sources/WindowLab/Config.swift`       (config schema/defaults)
- `Sources/WindowLab/StripOpsTests.swift` (the `unittest` runner)
- `Sources/WindowLab/HeadlessTests.swift` / `HeadlessHarness.swift` (suite runner)

To add tests WITHOUT touching the shared runner: create a NEW file
`Sources/WindowLab/<Lane>Tests.swift` exposing `enum <Lane>Tests { static func run() -> Bool }`
that prints `PASS/FAIL` lines and returns success. The coordinator wires it into
`unittest`/`headlesstest` in a single edit. Prefer extracting PURE functions
(like `ResyncPlanner`, `UpdatePolicy`, `AppLocation`) into NEW files so logic is
unit-testable without AppKit/AX and merges cleanly.

---

## Definition of done (every lane)

1. `swift build` clean — zero new warnings.
2. Your new `*Tests.swift` `run()` returns true; logic is covered.
3. You did NOT edit any reserved file; cross-lane needs are in your report.
4. Committed to your branch, focused messages explaining WHY.
5. `swarm report` (status=ready) summarizing: what changed, new files/types,
   new tests, how you verified, and any change you need the coordinator to make
   in a reserved file (exact location + desired edit).

---

## Lanes

### Lane A — Launch location & relocation (the #1 onboarding cliff)
Owned: `Sources/WindowLab/AppLocation.swift` (+ new `AppLocationTests.swift`).
Polish goals:
- Audit `AppLocation.classify` for every real-world launch path: translocation
  ghost, `/Volumes/*.dmg`, `~/Downloads`, `~/Desktop`, `~/Applications`,
  `/Applications`, iCloud Drive Desktop (`~/Library/Mobile Documents/...`),
  symlinked homes, trailing slashes, case. Add missing transient-home cases.
- Harden `AppRelocator`: confirm the modal copy works for `ditto` failures,
  destination already running, partial copies, and that we NEVER overwrite a
  good installed copy without consent. Make sure "Run Anyway" on translocation
  always warns. Consider a quarantine re-check after relocate.
- Every behavioral branch needs a PURE function + a unit test. The impure
  filesystem/relaunch parts stay thin and documented.
Acceptance: classify is total and tested for all cases above; relocation copy
is robust; tests green.

### Lane B — Accessibility permission engine
Owned: `Sources/WindowLab/AccessibilityPermission.swift` (+ new
`PermissionPolicyTests.swift`). Optionally a new `PermissionPolicy.swift` for
extracted pure logic.
Polish goals:
- The state machine (`granted`/`notDetermined`/`denied`), `shouldAutoPrompt`,
  `resolveImmediate`, stale-`false` grace, the prompted/granted markers, and the
  silent-wait-when-`hasEverBeenGranted` path are the heart of "never ask when
  it's already on." Extract ALL of this decision logic into PURE, testable
  functions (input: isTrusted/hasPrompted/hasEverBeenGranted/elapsed → output:
  action). Cover: first run, repeat launch granted, repeat launch denied, stale
  false after update, real revocation after grace.
- Verify markers are written exactly once and never burn the genuine first-run
  prompt; verify poll/observe teardown is clean.
- Do NOT change observable launch behavior without noting it for the coordinator
  (the launch flow lives in the reserved `ScrollWMApp.swift`).
Acceptance: pure policy fully extracted + tested; no regression to the
"silent when already granted" guarantee.

### Lane C — Onboarding window UI/UX & accessibility
Owned: `Sources/WindowLab/OnboardingWindow.swift` (+ new `OnboardingCopy.swift`
for any extracted pure copy/state-text logic + its tests).
Polish goals:
- Tighten the visual + copy polish: title, steps, live status row, denied
  troubleshooting, button hierarchy. Ensure the window looks finished in light
  AND dark mode, never clips, and the status transitions
  (waiting→granted→arranging) read perfectly.
- VoiceOver / accessibility: every control has an accessibility label; the
  status dot's meaning is conveyed to assistive tech (color is not the only
  signal); focus order is sane; the window is reachable by keyboard.
- Make the status-text + dot-color decision a PURE function of state (so it is
  unit-testable and can't drift), and test it.
- Verify "Show in Finder" no-ops for the dev binary and the agent-instructions
  copy text is accurate.
Acceptance: state→(label,color,troubleshooting,buttonEnabled) is a tested pure
function; a11y labels present; copy reviewed.

### Lane D — First-run tutorial / education
Owned: `Sources/WindowLab/TutorialWindow.swift` (+ new `TutorialTests.swift`).
Polish goals:
- The tutorial is generated from live config so shown keys match bindings. Audit
  `pretty()` chord rendering for every modifier/key token (arrows, fn keys,
  digits, space/return/esc/tab, unknown tokens) and make it total + tested.
- Make sure the key table covers every user-facing action with no stale entries,
  reads cleanly, and the "edit config + reload" guidance is accurate.
- Polish layout (scroll view sizing, dark mode, no clipping). Ensure the
  first-run auto-open marker logic is correct (shown exactly once).
- Extract `pretty()` (and any chord-formatting) so it's unit-tested without
  AppKit; cover the full token set.
Acceptance: `pretty()` total + fully tested; key table complete; layout polished.

### Lane E — Install & distribution
Owned: `scripts/web-install.sh`, `scripts/install.sh`, `Casks/scrollwm.rb`,
`README.md` (Install + First launch + Updating sections only).
Polish goals:
- web-install.sh: robust release-asset resolution (handle missing asset, network
  failure, `.zip` vs `.dmg`), idempotent reinstall, clean quit-of-running
  instance, accurate post-install next-steps that match the in-app onboarding
  copy. `shellcheck`-clean if available.
- install.sh: verify it builds + installs to `~/Applications` and the messaging
  matches reality.
- Cask: version/sha plumbing correct; quarantine strip; uninstall/zap paths
  correct; auto_updates rationale accurate.
- README: the Install / First launch / Updating prose must exactly match what
  the app actually does (relocation, single permission, no-relaunch grant,
  dormant-until-arrange). Fix any drift.
Acceptance: scripts are robust + idempotent; docs match real behavior; no
shellcheck regressions.

---

## Coordinator (integration) responsibilities — NOT a lane

- Wire each lane's `*Tests.swift` into `unittest`/`headlesstest`.
- Apply requested edits to reserved files (`ScrollWMApp.swift`, `main.swift`,
  `Config.swift`).
- Add a headless `onboardingtest` suite that drives the real launch decision
  logic end-to-end against the pure policies the lanes extract.
- Merge all branches, run `make test`, resolve conflicts, final polish pass.

---

## Status: COMPLETE (delivered on branch `onboarding-integration`)

All five lanes finished, merged, and verified by the coordinator.

| Lane | Branch | New pure module | Tests added |
|------|--------|-----------------|-------------|
| A — launch location & relocation | `feature/onboard-a-location` | hardened `AppLocation` (iCloud Drive, firmlink, case-insensitive, total classify) | `AppLocationTests` (75) |
| B — permission engine | `feature/onboard-b-permission` | `PermissionPolicy` (pure launch/grace/prompt decisions) | `PermissionPolicyTests` (35) |
| C — onboarding window UI/a11y | `feature/onboard-c-window` | `OnboardingCopy` (state→presentation + VoiceOver labels) | `OnboardingCopyTests` (44) |
| D — first-run tutorial | `feature/onboard-d-tutorial` | total `pretty()` chord rendering, data-driven key table | `TutorialTests` (123) |
| E — install & distribution | `feature/onboard-e-install` | robust `web-install.sh`, accurate cask/README | (script lint) |

Coordinator integration commits:
- Wired the four lane suites into `WindowLab unittest` (715 assertions, all green).
- Rewired the live launch flow in `ScrollWMApp.swift` to delegate to the PURE
  `PermissionPolicy.launchAction` (the tested logic is now the logic that runs),
  fixing a latent invisible dead-end on genuine post-grant revocation.

Verification: `make test` green end-to-end (unit + animation + 5 headless
integration suites + 5 fuzzers, 0 violations). Zero new compiler warnings in
lane-owned files.

### Landing
`onboarding-integration` is a clean superset of the current `feature/multi-display`
tip. To land once the main worktree is free:
```bash
git checkout feature/multi-display && git merge --ff-only onboarding-integration
```
