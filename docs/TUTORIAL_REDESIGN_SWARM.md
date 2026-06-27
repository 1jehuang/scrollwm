# Tutorial Redesign Swarm — Task Graph

Goal: redesign ScrollWM's in-app tutorial window ("How to use ScrollWM") from a
flat single-scroll cheat sheet into a **polished, paged, visually-rich, and
interactive** experience. High-impact polish: a hero animation that SHOWS the
scrolling-strip metaphor, a themed card-based visual style, a paged/segmented
information architecture, and an interactive "practice the keys" mode.

You are ONE lane in a parallel swarm. A coordinator owns the integration surface
(the `TutorialWindowController` shell + app wiring) and merges your work. Stay
strictly inside your lane's **owned files** (all of which are NEW files you
create — you must not edit any existing file).

---

## GOLDEN RULE (non-negotiable — this runs on the user's real machine)

This tool moves the user's REAL, live windows. NEVER arrange the user's actual
session. NEVER run a bare `WindowLab run` + Arrange, and NEVER call `arrange()`.
For any live behavior use the sandbox ONLY (`.build/debug/WindowLab sandbox 4`).
Tests are HEADLESS by default and safe — prefer them. Do not touch
Accessibility/TCC state, do not move/quit the running ScrollWM.

The tutorial UI is pure AppKit chrome — it does NOT move windows — so you can
build + visually preview your own views without any sandbox. But never wire
anything into the live arrange path.

---

## Isolation: git worktrees

You work in your OWN git worktree on your OWN branch, forked from
`tutorial-redesign-integration` (base commit shared by all lanes). Your worktree
path and branch are in your spawn prompt. Do NOT `cd` out of your worktree. Do
NOT touch other worktrees. Commit to YOUR branch only, focused messages
explaining WHY. The coordinator merges.

---

## Build / test

```bash
swift build                      # debug build (must stay clean, zero new warnings)
.build/debug/WindowLab unittest  # pure-logic suite (your new tests get wired here by coordinator)
```

To add tests WITHOUT touching the shared runner: create a NEW file
`Sources/WindowLab/<Lane>Tests.swift` exposing
`enum <Lane>Tests { static func run() -> Bool }` that prints `PASS`/`FAIL` lines
and returns success. The coordinator wires it into `unittest`. Prefer extracting
PURE functions (no AppKit) so logic is unit-testable and merges cleanly. AppKit
view code lives in separate files and is exercised by a small offscreen-render
smoke test where practical.

---

## Reserved files (DO NOT EDIT — coordinator owns these)

- `Sources/WindowLab/TutorialWindow.swift`   (the controller shell + assembly)
- `Sources/WindowLab/ScrollWMApp.swift`      (controller wiring, key tap)
- `Sources/WindowLab/main.swift`             (subcommand dispatch)
- `Sources/WindowLab/Config.swift`           (KeyAction, config schema)
- `Sources/WindowLab/StripOpsTests.swift`    (the `unittest` runner)
- existing `TutorialProgress.swift`, `TutorialTests.swift`, `ChordFormatter`

If you need a change in a reserved file, DO NOT edit it. Describe the EXACT
change (file + location + desired API) in your final `swarm report` and the
coordinator will apply it.

## Shared APIs you can rely on (already exist; read them, don't change them)

- `ChordFormatter` (in `TutorialWindow.swift`): `pretty(_:)`, `keycaps(_:)`,
  `keycaps(_ config:_ action:)`, `chordText(_ config:_ action:)`,
  `keyTableRows()`. Use these for rendering chords — do not reinvent.
- `KeyAction` (in `Config.swift`): `.allCases`, `.coreActions`, `.isCore`,
  `.displayName`, `.defaultChords`.
- `TutorialProgress` (pure): `rows(levels:)`, `summary(levels:)`,
  `LearnState` (+ `.glyph`, `.caption`, `.isLearned`).
- `KeybindingProficiency.Level` (`.unknown/.learning/.proficient/.rusty/.unlearned`).
- `ScrollWMConfig` (`.default`, `.keybindings`, `.layout`, `ScrollWMConfig.fileURL`).
- `AppColors.color(appName:title:)` for per-app strip colors.

---

## Definition of done (every lane)

1. `swift build` clean — zero new warnings.
2. Your new `<Lane>Tests.swift` `run()` returns true; logic covered.
3. You did NOT edit any reserved/existing file; cross-lane needs in your report.
4. Committed to YOUR branch, focused messages explaining WHY.
5. `swarm report` (status=ready) summarizing: new files + public types/APIs
   (exact signatures the coordinator will call to assemble the window), new
   tests, how you verified, and any reserved-file change you need.

CRITICAL for integration: your public types must be **self-contained and
constructible by the coordinator** with the shared APIs above. Expose a clear
entry point (e.g. `TutorialStripDiagramView(...)`, `TutorialContent.pages(...)`,
`TutorialTheme`, `TutorialPracticeView(...)`). Document every initializer.

---

## Lanes

### Lane 1 — Hero strip-diagram animation
Owned (new files): `StripDiagramModel.swift`, `TutorialStripDiagram.swift`,
`StripDiagramTests.swift`.
Build a small, looping, beautiful animation that SHOWS the core concept: a row
of colored window "columns" on a long horizontal strip, with a viewport
rectangle that smoothly teleports between columns (focus left/right), and
columns that resize (width presets) and reorder (move). This is the single most
important "aha" for a new user.
- PURE model (`StripDiagramModel`): N columns with width fractions + colors, a
  focused index, a viewport offset; pure step functions for focus-next/prev,
  move, width-cycle; and a spring-eased viewport offset (you may reuse the
  `Spring` value type in `MenuBarStripView.swift` — read it, do not edit it; if
  you need it shared, copy a minimal pure spring into your own file). Fully
  unit-tested: focus wraps/clamps, viewport target keeps focus visible, totals.
- VIEW (`TutorialStripDiagramView: NSView`): renders the model with a
  CADisplayLink/timer, auto-plays a gentle scripted loop (focus →, →, move,
  width, focus ←…) so the strip metaphor is obvious at a glance. Light/dark
  mode, rounded "window" cards with titlebar dots, a glowing viewport frame.
  Respect reduced-motion (fall back to a static labeled diagram).
- Keep it self-contained: `init(config:)` or `init()` with sensible defaults;
  a `start()`/`stop()` the controller can call when the page shows/hides.
Acceptance: model total + tested; view renders offscreen without crashing in a
smoke test; animation loops; reduced-motion fallback.

### Lane 2 — Paged information architecture (content spec)
Owned (new files): `TutorialContent.swift`, `TutorialContentTests.swift`.
Turn the one long scroll into a clean PAGED structure. Define a PURE,
data-driven content model the coordinator renders as segmented pages/tabs:
- A `TutorialPage` enum/struct set, e.g. Welcome (concept), Navigate (focus/jump),
  Arrange windows (move/width/close), Workspaces, Multi-display, Settings/Config.
- Each page = title, short intro copy, and an ordered list of "items" where an
  item is either prose, a bullet, a config path, or a **keybinding row**
  (label + the `KeyAction`s it documents, so coverage is checkable).
- Generate keybinding rows from live `ScrollWMConfig` via `ChordFormatter` (do
  NOT hardcode chords). Provide `TutorialContent.pages(config:)`.
- A unit test must assert EVERY user-facing `KeyAction` appears on exactly one
  page (no missing/stale), parallel to the existing `keyTableRows` coverage
  test. Also assert page order + that copy is non-empty + total over inputs.
- Keep copy tight, friendly, accurate (read the current `TutorialWindow.swift`
  copy for the facts: dormant-until-arrange, panic key, Carbon vs tap hotkeys,
  config file + reload). Improve wording; keep it true.
Acceptance: `TutorialContent.pages(config:)` pure + tested; full KeyAction
coverage exactly-once; page model is render-agnostic.

### Lane 3 — Visual theme + reusable components
Owned (new files): `TutorialTheme.swift`, `TutorialComponents.swift`,
`TutorialThemeTests.swift`.
Define the visual language and the reusable AppKit building blocks the
coordinator composes the window from. Make it look finished and modern.
- `TutorialTheme` (mostly pure where possible): palette (accent, surfaces,
  text tiers), corner radii, spacing scale, font ramp (title/section/body/mono),
  all resolving correctly in light AND dark mode (system colors / dynamic).
- `TutorialComponents`: factory funcs/`NSView` subclasses for — a hero header
  (title + tagline + optional accent), a Card container (rounded surface, subtle
  border/shadow, padding), a section header, a refined keycap pill (improve on
  the existing `KeycapView` look — crisper, optional "pressed" state for Lane 4),
  a keybinding row (label · keycaps · optional status badge), a status badge
  (learned/learning/rusty/not-started using `TutorialProgress.LearnState`),
  and a segmented page selector (or expose one the coordinator can use).
- Provide a small offscreen-render smoke test (construct each component, force
  layout, assert non-zero fitting size, no crash). Pure parts (color math,
  spacing scale, any text helpers) get real unit assertions.
- Do NOT edit the existing `KeycapView`; create your own improved component
  (e.g. `TutorialKeycap`) so the coordinator can swap to it.
Acceptance: theme resolves light/dark; components construct + render offscreen;
pure helpers tested.

### Lane 4 — Interactive practice mode
Owned (new files): `TutorialPractice.swift`, `TutorialPracticeView.swift`,
`TutorialPracticeTests.swift`.
A "Practice" page that turns learning into a guided, reactive drill: it asks the
user to press a specific shortcut ("Try Focus → : ⌘L"), detects the matching
chord, celebrates, and advances to the next challenge, tracking progress.
- PURE state machine (`TutorialPractice`): an ordered list of challenges (one per
  core `KeyAction`, generated from config via `ChordFormatter`), current index,
  per-challenge done/attempts, and a pure `handle(chord:) -> Outcome`
  (`.advanced/.repeatedWrong/.complete`) plus completion fraction + headline.
  Matching must be tolerant (compare normalized chord, reuse `ChordFormatter`
  tokenization). Fully unit-tested: correct advances, wrong key counts as a
  miss without advancing, completion, reset, empty/edge config.
- VIEW (`TutorialPracticeView: NSView`): shows the current prompt with big
  keycaps, a "press it now" hint, a progress indicator, and animates a
  success/again reaction. Expose a method the coordinator can call to feed a
  detected chord string: `func deliver(chord: String)` (so the app's key tap
  routes real presses here ONLY while the practice page is visible and the user
  opted in). Provide an `onChordObservedRequest`/enable-disable hook so the
  coordinator knows when to start/stop forwarding keys. Do NOT register any real
  event tap yourself — the coordinator owns that in `ScrollWMApp.swift`.
- Document for the coordinator EXACTLY what app-side wiring you need (e.g. "call
  `view.deliver(chord:)` from the key tap while `view.isCapturing`; the existing
  tap is `KeyboardEventTap`/`debugDeliver` in `ScrollWMApp`/`Hotkeys`").
Acceptance: practice state machine pure + fully tested; view reacts to delivered
chords; clear wiring spec for the coordinator; never registers a real tap.

---

## Coordinator (integration) responsibilities — NOT a lane

- Rewrite `TutorialWindowController` (`TutorialWindow.swift`) into a paged,
  themed window: hero header + Lane 1 diagram on the Welcome page, Lane 3 theme
  + components throughout, Lane 2 paged content for the reference pages, Lane 4
  Practice as its own page. Keep the menu / CLI / first-run entry points working.
- Wire the Practice key capture into `ScrollWMApp.swift` (forward observed chords
  to the practice view only while that page is visible + capturing).
- Wire every lane's `*Tests.swift` into `unittest`.
- Merge all branches, run `make test`, install + relaunch, screenshot review.
