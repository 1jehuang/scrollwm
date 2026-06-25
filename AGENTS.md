# AGENTS.md — ScrollWM

Guidance for AI agents (and humans) working in this repo.

## What this is

ScrollWM is a scrolling/PaperWM-style window manager for macOS. Windows live in
columns on a horizontal strip; navigation teleports the viewport. The product
binary is `WindowLab` (the `run` subcommand is the production app; other
subcommands are the lab/test harness). The installed app bundle is
`~/Applications/ScrollWM.app`.

## GOLDEN RULE: test in the sandbox, never against the user's real windows

This tool moves the user's real, live windows. When iterating, **do not arrange
the user's actual session**. Use sandbox mode, which runs the REAL production
controller but is hard-locked to disposable windows it spawns:

```bash
swift build
.build/debug/WindowLab sandbox 4      # spawn 4 throwaway windows, arrange them
```

Why it is safe (see `Sources/WindowLab/Sandbox.swift`):
- `ScrollWMController.sandboxPIDs` forces EVERY arrange path (menu, hotkey,
  direct call) through that PID filter, and the `LifecycleMonitor` only
  observes/adopts those PIDs. The user's real windows are never enumerated or
  moved.
- `RestoreStore.subdirectory` is redirected to `ScrollWM-Sandbox/`, so the
  sandbox's crash-recovery file can never clobber/recover the real session.
- Ctrl-C / Quit restores and terminates the spawned windows.

Only `WindowLab cycle` and a bare `WindowLab run` + manual Arrange touch real
windows. Avoid those while developing; prefer `sandbox`.

## Testing / verification

The integration tests are **HEADLESS BY DEFAULT**: they run the REAL engine +
controller logic against an in-memory window world (`SimWindowWorld`, installed
as `AXSource.backend`). Nothing is spawned, moved, focused, or closed on your
real desktop, and no global keystroke is ever injected, so they are safe to run
anytime, even while you work. Pass `--live` to exercise the old real-window path.

```bash
.build/debug/WindowLab unittest       # pure logic: strip ops, ResyncPlanner, config (no AX)
.build/debug/WindowLab headlesstest   # ALL integration suites, headless (see below)
.build/debug/WindowLab opstest        # width/move/close/focus-sync (headless; --live = real AX)
.build/debug/WindowLab e2etest        # real controller + synthetic chords (headless; --live = real keys)
.build/debug/WindowLab revealtest     # "Arrange All" reveals + adopts hidden/minimized (headless; --live)
.build/debug/WindowLab spawnlatency   # new-window adoption latency (headless; --live = real AX)
.build/debug/WindowLab displaytest    # multi-display placement/parking/rebind (headless 2-display; --live)
.build/debug/WindowLab sandbox [n] [--display M]
                                      # live, interactive, isolated to spawned windows
                                      #   (--display M tiles them on monitor M, 0-based L->R)
```

`make test` runs `unittest` + `animtest` + `headlesstest`. Always run it before
claiming a change is done; it never touches your real windows or focus.

### How headless works (the seam)

`AXSource` and `CGWindowSource` route every window read/write/action through an
optional `WindowBackend` (`AXSource.backend`). In production it is `nil` and the
exact prior C-API path runs. A test installs a `SimWindowWorld` that models the
parts the engine actually depends on: per-window CFEqual-stable element tokens,
app size MINIMUMS (`setSize` below the floor clamps yet returns `.success`), the
current-Space on-screen list (minimized/app-hidden windows drop out), the macOS
off-screen clamp (parked-window sliver lands on the nearest display), system
keyboard focus, and `kAXWindowCreated`/`Destroyed` events for the fast-adopt
path. `HotkeyManager`/`KeyboardEventTap` skip real registration under a backend
and expose `debugDeliver`, and `ScrollWMController.debugDeliverChord` routes a
synthetic chord through the same tap->Carbon precedence as a real keypress, with
NO CGEvent posted. The menu-bar status item is suppressed too. When you change
behavior, prefer extending the sim + a headless assertion over a `--live` test.

Add a test for any behavior you change; prefer extracting pure functions (e.g.
`ResyncPlanner`, `viewportTarget`) so logic is unit-testable without AX.

## Architecture (Sources/WindowLab/)

- `TeleportEngine.swift`     strip model, viewport, teleport commits (focus/move/width)
- `StripOps.swift`           width/move/close ops on the focused column
- `LifecycleMonitor.swift`   keeps strip in sync: AX observer + NSWorkspace + 2s poll
- `WindowEventObserver.swift` AXObserver on kAXWindowCreated -> fast adoption (~85ms)
- `ResyncPlanner.swift`      PURE Space-aware adopt/drop policy (unit-tested)
- `AXSource.swift`           timeout-protected AXUIElement wrapper +
                             `WindowBackend` seam (nil in prod; sim in tests)
- `CGWindowSource.swift`     WindowServer enumeration (current-Space = on-screen list)
- `IdentityMatcher.swift`    AX<->CG fusion (PID+frame+title scoring)
- `RestoreStore.swift`       crash-recovery frame persistence
- `ScrollWMApp.swift`        production controller, menu bar, hotkeys, signals
- `ControlServer.swift`      Unix-socket control plane (server + client) for the CLI
- `ControlCommands.swift`    maps `scrollwm <verb>` requests to controller actions
- `ControlCLI.swift`         `scrollwm` CLI: connect to the running app, print reply
- `Updater.swift`            in-app updater: GitHub Releases check (pure parse/
                             evaluate) + download/verify(SHA-256)/stage/validate
- `UpdateCoordinator.swift`  schedules checks; enforces safety policy (no
                             relaunch loop, apply-on-quit while managing, brew/
                             writable pre-flight, TCC-aware silent refusal);
                             prompts/installs; post-relaunch reconcile + re-grant
- `UpdatePolicy.swift`       PURE update policy: attempt guard, apply timing,
                             install-target classification (unit-tested)
- `CodeSigning.swift`        SecCode introspection: will an update PRESERVE the
                             Accessibility grant? (designated-requirement match)
                             + staged-bundle signature/arch/id checks
- `InstallSwap.swift`        atomic bundle swap via the detached `__update-swap`
                             re-exec (FileManager.replaceItem, rollback, logging)
- `SemVer.swift`             PURE semantic-version parse + ordering (unit-tested)
- `Sandbox.swift`            sandbox mode (safe live testing)
- `SimWindowWorld.swift`     in-memory `WindowBackend`: headless stand-in for AX/
                             WindowServer (min-size clamp, focus, parking, events)
- `HeadlessHarness.swift`    headless test scaffolding + `headlesstest` suite runner
- `HeadlessTests.swift`      headless ops/e2e/reveal/spawnlatency/display suites
- `Config.swift`             JSONC config file (single source of truth for keybinds)
- `AppLocation.swift`        PURE launch-location classifier (translocation /
                             download / dmg) + relocate-to-`~/Applications` so
                             the Accessibility grant sticks (unit-tested)

## Key invariants / gotchas

- **Spaces:** `arrange` and `resync` adopt only CURRENT-Space windows (AX spans
  ALL Spaces; intersect with the on-screen CG list). While the user is on a
  different Space than the strip, the monitor FREEZES (see `ResyncPlanner`).
  Removals key on AX existence, so a window merely on another Space is kept.
- **New windows:** `NSWorkspace.didLaunchApplication` only fires for new *apps*,
  not new windows in a running app. The `kAXWindowCreated` observer is the fast
  path; the 2s poll is only a safety net.
- **AX readback:** apps clamp sizes silently while still returning `.success`.
  Always read back the real frame and store that, never trust the request.
- **Hotkeys:** `⌘H`/`⌘L` (and `⌘1-4`) cannot be Carbon hotkeys (macOS reserves
  them); they ride a CGEvent keyboard tap. Width/`⌘Q` use Carbon. The tap and
  Carbon hotkeys are torn down on Release so the desktop behaves normally.
- **No private APIs, one permission (Accessibility).** Do not add Screen
  Recording / Input Monitoring / private framework dependencies without an
  explicit, documented opt-in (e.g. true 3-finger gestures would need the
  private MultitouchSupport framework and would break this contract).

## Build / install / signing

```bash
swift build                       # debug, fast iteration
./scripts/install.sh              # release build -> ~/Applications/ScrollWM.app
./scripts/setup-signing.sh        # once: stable self-signed identity so the
                                  # Accessibility grant persists across rebuilds
```

Signing identity is auto-detected by `scripts/signing-lib.sh`
(**Developer ID > "ScrollWM Self-Signed" > ad-hoc**; override with
`SCROLLWM_SIGN_ID`). With a Developer ID cert, `make-bundle.sh` adds the
hardened runtime + entitlements (`Resources/ScrollWM.entitlements`) + timestamp,
and `scripts/notarize.sh <ver>` submits to Apple and staples the ticket so
downloads open with no Gatekeeper warning. The bundle's main executable is the
real Mach-O (`CFBundleExecutable=ScrollWM`, no shell wrapper); it defaults to
`run` when launched as an `.app` and dispatches subcommands otherwise. Full
details: `docs/SIGNING.md`.

If `codesign` fails with `errSecInternalComponent` after creating the identity,
run:
`security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" ~/Library/Keychains/login.keychain-db`

A signature change (e.g. ad-hoc -> stable) requires re-granting Accessibility
once; toggle ScrollWM off/on in System Settings > Privacy & Security >
Accessibility.

## Style

- Commit as you go with focused messages explaining the WHY.
- Keep the "never break the user's desktop" safety contract front of mind.
