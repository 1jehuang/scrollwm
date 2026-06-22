# ScrollWM

A scrolling window manager for macOS. Windows live in columns on a horizontal
strip (PaperWM-style); navigation teleports the viewport instantly.

**One permission: Accessibility.** No Screen Recording, no Input Monitoring,
no private APIs, no daemons.

## Safety contract

ScrollWM is built around a "never break the desktop" rule:

1. **Dormant by default.** Launching it does nothing to your windows.
   Management starts only when you explicitly Arrange.
2. **Exact restore.** Every window's original position and size is captured
   before the first move. Release / Quit puts everything back exactly.
3. **Crash-proof.** Original frames are persisted to
   `~/Library/Application Support/ScrollWM/restore.json` while managing.
   If ScrollWM crashes or is `kill -9`ed, the next launch restores all
   windows automatically.
4. **Panic switch.** `ctrl+opt+esc` toggles arrange/release at any time.

## Install

```bash
./scripts/install.sh            # installs ScrollWM.app to ~/Applications
open ~/Applications/ScrollWM.app
```

On first launch ScrollWM shows a one-step onboarding window explaining its
single permission and opens the right Settings pane for you. Flip the
**Accessibility** switch for ScrollWM and the app continues automatically —
no relaunch. If permission is already granted, ScrollWM starts silently with
no prompt and no waiting UI (it never asks when it doesn't need to).

> Stuck? The onboarding window has a "Copy setup steps for my AI assistant"
> button that puts plain instructions on your clipboard for any assistant you
> already use. This is an optional escape hatch, never a dependency.

## Updating

To run the latest code after a change:

```bash
./scripts/update.sh             # rebuild, reinstall in place, relaunch
```

By default the build is **ad-hoc signed**, so macOS sees each rebuild as a new
app and drops the Accessibility grant (you must re-enable it after every
update). To keep the permission across updates, create a stable self-signed
identity **once**:

```bash
./scripts/setup-signing.sh      # one-time: makes a local code-signing cert
./scripts/update.sh             # now installs signed with the stable identity
```

After granting Accessibility one more time post-setup, future `update.sh` runs
keep the permission (the app's signing identity no longer changes per build).

## Use

| Control | Action |
|---|---|
| menu bar icon → Arrange | adopt current-Space windows into the strip |
| `⌃⌥←` / `⌃⌥→` | focus previous/next column |
| `⌃⌥1`..`⌃⌥9` | jump to column N |
| `⌥1` / `⌥2` / `⌥3` / `⌥4` | set focused column width to 25% / 50% / 75% / 100% |
| `⌘H` / `⌘L` | move focused column left / right |
| `⌘Q` | close focused window |
| `⌃⌥esc` | toggle arrange/release |
| menu bar icon → window | jump to that window |
| menu → Release | restore all windows, go dormant |
| menu → Quit | restore all windows and exit |

The width/move/close keys are **only active while managing**, and are torn down
on Release so the desktop behaves normally (`⌘Q` quits apps, `⌘H` hides them)
when ScrollWM is dormant.

> **Implementation note.** `⌥1-4` (width) and `⌘Q` (close) use permission-free
> Carbon global hotkeys. `⌘H`/`⌘L` cannot: macOS reserves `⌘H` for "Hide" and
> never delivers it to a Carbon hotkey (verified via `WindowLab hotkeyprobe`).
> So the move keys ride a keyboard `CGEventTap`, which works with the
> Accessibility permission the app already holds (verified via `keytapprobe`).
> No Input Monitoring permission is required.


The menu bar icon is a live mini-map: columns are windows, the outline is
your viewport, blue is the focused window.

## Architecture

```
Sources/WindowLab/
  AXSource.swift             timeout-protected Accessibility wrapper
  AccessibilityPermission.swift  single source of truth for the AX grant
  OnboardingWindow.swift     first-run permission onboarding UI
  CGWindowSource.swift       WindowServer enumeration (CGWindowList)
  IdentityMatcher.swift      AX<->CG window fusion (PID+frame+title scoring)
  TeleportEngine.swift       strip layout, viewport, prioritized commits
  LifecycleMonitor.swift     adopt new / drop closed windows (notif + poll)
  RestoreStore.swift         crash-recovery frame persistence
  ScrollWMApp.swift          production app: controller, menu bar, signals
  Hotkeys.swift              Carbon global hotkeys (permission-free)
  MenuBar.swift              lab-mode mini-map status item
  ...benchmarks              measurement harness (see below)
```

### The lab

`WindowLab` doubles as a measurement harness. Every architectural decision
in this repo was validated against measured numbers on real hardware:

```bash
swift build
.build/debug/WindowLab probe -v        # enumerate + match windows, latency
.build/debug/WindowLab bench           # AX move/resize cost per window
.build/debug/WindowLab scrollbench 16 60 --spawn   # real-window animation jank
.build/debug/WindowLab pan 10 8 --spawn --selftest # scroll-driven panning
.build/debug/WindowLab overlay 8 --selftest        # Metal overlay + event tap
.build/debug/WindowLab capturebench 5  # SCK capture latency (needs Screen Rec)
.build/debug/WindowLab teleport --spawn --selftest # teleport tier e2e
.build/debug/WindowLab run --selftest  # production round trip
.build/debug/WindowLab run --crashtest # crash phase (then relaunch to recover)
```

Measured on M-series MacBook (macOS 26):

| Operation | p50 | p95 |
|---|---|---|
| AX move window | 0.4 ms | 0.6 ms |
| Full-strip teleport (8 windows) | 3.4 ms | 5.0 ms |
| 16 real windows animated @60Hz | 4.0 ms/tick | 8.0 ms (budget 16.7) |
| SCK capture age | 0.5 ms | 0.9 ms |
| IOSurface→MTLTexture | 0.01 ms | 0.05 ms |

### Roadmap tiers

- **Tier 0 (this app): teleport.** Accessibility only. Instant navigation.
- **Tier 1: smooth pan.** + Input Monitoring (scroll event tap). Real windows
  animated at 60Hz — validated viable by `scrollbench`.
- **Tier 2: cinematic.** + Screen Recording. Metal compositor scrolls live
  window textures at 120Hz (`overlay` + `capturebench` prove the budget).
