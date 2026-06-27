import Foundation

/// PURE, data-driven paged content model for the in-app tutorial.
///
/// Lane 2 of the tutorial redesign. This replaces the single long scroll in
/// `TutorialWindowController` with a render-agnostic page spec the coordinator
/// turns into segmented pages/tabs. There is NO AppKit here: a `Page` is just a
/// title, a short intro, and an ordered list of `Item`s (prose, a bullet, a
/// config path, or a keybinding row). The coordinator decides how each `Item`
/// looks; this type only decides WHAT is shown and in WHICH order.
///
/// Keybinding rows are generated from the LIVE `ScrollWMConfig` via
/// `ChordFormatter` (the single source of truth for chord rendering), so the
/// shown keys always match what is actually bound - there is no second copy of
/// the keymap to drift out of sync, and nothing is hardcoded.
///
/// Coverage is verifiable: every keybinding row carries the `KeyAction`s it
/// documents, so a unit test can assert EVERY user-facing action appears on
/// exactly one page (parallel to `ChordFormatter.keyTableRows`).
///
/// `pages(config:)` is **total**: any `ScrollWMConfig` produces the same stable
/// set of pages in the same order, every page has a non-empty title + intro,
/// and chords never render blank (they fall back to the built-in defaults).
enum TutorialContent {

    /// One stable page identity, in teaching order. `allCases` IS the page
    /// order, so the coordinator can build a segmented selector directly from
    /// it and the order can be asserted in tests.
    enum PageID: String, CaseIterable, Equatable {
        case welcome      // the scrolling-strip concept + the safety rule
        case navigate     // focus / jump between columns
        case arrange      // move / resize / add / close windows
        case workspaces   // vertical workspaces
        case displays     // multiple monitors
        case settings     // the config file + how keys are delivered
    }

    /// A single piece of content within a page. Render-agnostic: the coordinator
    /// maps each case to a view (body label, bullet row, mono path, keycap row).
    enum Item: Equatable {
        /// A paragraph of explanatory copy.
        case prose(String)
        /// A single bullet point.
        case bullet(String)
        /// A filesystem / config path to render monospaced (e.g. the config
        /// file location). Selectable in the UI.
        case configPath(String)
        /// A keybinding row: a human label, the chord(s) it fires (already
        /// resolved + display-ready from the live config), and the `KeyAction`s
        /// it documents so coverage stays checkable.
        case keybinding(KeybindingRow)
    }

    /// A keybinding row: a human label, the resolved display chord(s), and the
    /// `KeyAction`s it documents.
    ///
    /// `chords` is produced from the live config via `ChordFormatter.chordText`
    /// (e.g. `"⌘H / ⌘L"`), so the coordinator can render it as text or split it
    /// per-action into keycaps. `covers` makes coverage testable: the union of
    /// every row's `covers` must equal `KeyAction.allCases`, each exactly once.
    struct KeybindingRow: Equatable {
        let label: String
        let covers: [KeyAction]
        let chords: String
    }

    /// One tutorial page: a stable id, a title, a short intro, and ordered items.
    struct Page: Equatable {
        let id: PageID
        let title: String
        let intro: String
        let items: [Item]
    }

    // MARK: - Public entry point

    /// Build the full ordered page set from the live config. Pure + total: the
    /// only input is `config`, the output order is always `PageID.allCases`, and
    /// every chord falls back to the built-in default when a binding is unset so
    /// no row ever renders blank.
    static func pages(config: ScrollWMConfig) -> [Page] {
        // Resolve a single action's display chord from the live config (with the
        // built-in default as a fallback) - never hardcode a chord here.
        func ct(_ action: KeyAction) -> String { ChordFormatter.chordText(config, action) }
        // A "left / right"-style pair rendered as one row.
        func pair(_ a: KeyAction, _ b: KeyAction) -> String { "\(ct(a)) / \(ct(b))" }
        func key(_ label: String, _ covers: [KeyAction], _ chords: String) -> Item {
            .keybinding(KeybindingRow(label: label, covers: covers, chords: chords))
        }

        let welcome = Page(
            id: .welcome,
            title: "Welcome to ScrollWM",
            intro: "ScrollWM lays your windows out as columns on one long "
                + "horizontal strip. You never see the whole strip at once - you "
                + "teleport the viewport to the column you want. Think PaperWM or "
                + "niri, but Accessibility-only and instant.",
            items: [
                .prose("ScrollWM stays dormant until you choose Arrange. It "
                    + "snapshots every window's exact position first, and Release "
                    + "(or Quit) puts everything back - so it can never strand "
                    + "your desktop."),
                key("Arrange / Release (panic key)", [.toggleArrange], ct(.toggleArrange)),
                .bullet("Feeling lost? That same key releases everything and "
                    + "hands your windows back exactly as they were."),
                .prose("Once arranged, you drive the strip entirely from the "
                    + "keyboard. The next pages cover navigating, rearranging, "
                    + "stacking workspaces, and spanning displays."),
            ]
        )

        let navigate = Page(
            id: .navigate,
            title: "Navigate the strip",
            intro: "Move your focus between columns. The strip scrolls just "
                + "enough to keep the focused column in view, and focus wraps "
                + "around the ends.",
            items: [
                key("Focus left / right", [.focusLeft, .focusRight],
                    pair(.focusLeft, .focusRight)),
                key("Focus previous / next column", [.focusPrevious, .focusNext],
                    pair(.focusPrevious, .focusNext)),
                key("Jump to column 1-9", [.jumpModifier], "\(ct(.jumpModifier)) + 1…9"),
                .bullet("Focus left/right ride a keyboard tap, so they can use "
                    + "⌘H/⌘L; the rest are permission-free Carbon hotkeys."),
            ]
        )

        let arrange = Page(
            id: .arrange,
            title: "Rearrange & resize",
            intro: "Reorder columns, snap their widths to presets, and add or "
                + "close windows. Every action applies to the focused column.",
            items: [
                key("Move column left / right", [.moveColumnLeft, .moveColumnRight],
                    pair(.moveColumnLeft, .moveColumnRight)),
                key("Set width 25 / 50 / 75 / 100%",
                    [.width25, .width50, .width75, .width100],
                    [KeyAction.width25, .width50, .width75, .width100]
                        .map(ct).joined(separator: "  ")),
                key("Close focused window", [.closeWindow], ct(.closeWindow)),
                key("Open a new terminal window", [.spawnTerminal], ct(.spawnTerminal)),
                .bullet("Width presets come from your config; a new terminal is "
                    + "adopted into the strip right of the focused column."),
            ]
        )

        let workspaces = Page(
            id: .workspaces,
            title: "Vertical workspaces",
            intro: "The strip you see is one workspace; stack more above and "
                + "below it. Switching parks the other workspace's windows "
                + "off-screen until you come back.",
            items: [
                key("Switch workspace down / up", [.workspaceDown, .workspaceUp],
                    pair(.workspaceDown, .workspaceUp)),
                key("Send window to workspace down / up",
                    [.moveToWorkspaceDown, .moveToWorkspaceUp],
                    pair(.moveToWorkspaceDown, .moveToWorkspaceUp)),
                .bullet("Going down past the last workspace creates a fresh empty "
                    + "one, niri-style."),
            ]
        )

        let displays = Page(
            id: .displays,
            title: "Multiple displays",
            intro: "With more than one monitor, move your focus between each "
                + "display's strip and fling the focused window to another "
                + "screen. On a single display these do nothing.",
            items: [
                key("Focus next / previous display",
                    [.focusDisplayNext, .focusDisplayPrevious],
                    pair(.focusDisplayNext, .focusDisplayPrevious)),
                key("Send window to next / previous display",
                    [.moveToDisplayNext, .moveToDisplayPrevious],
                    pair(.moveToDisplayNext, .moveToDisplayPrevious)),
                .bullet("Pick which monitor the strip binds to with the "
                    + "layout.stripDisplay setting, or move it live with "
                    + "`scrollwm display <next|main|primary|largest|N>`."),
            ]
        )

        let settings = Page(
            id: .settings,
            title: "Settings & config",
            intro: "Every setting - keybindings, column gap, width presets, "
                + "focus mode - lives in one human-editable file. There is no "
                + "hidden state: what's in the file is exactly what the app uses.",
            items: [
                .configPath(ScrollWMConfig.fileURL.path),
                .bullet("Menu → Open Config File opens it in your editor. It's "
                    + "commented JSON (JSONC)."),
                .bullet("Save your edits, then Menu → Reload Config. Changes "
                    + "apply live - no relaunch."),
                .prose("Modifiers are cmd, opt, ctrl, and shift. Navigation, "
                    + "jump, width, close, and the arrange toggle use "
                    + "permission-free Carbon hotkeys, which can't capture ⌘H or "
                    + "⌘M. Focus-left/right and move-left/right use a keyboard tap "
                    + "(active only while managing), so those can use ⌘H/⌘L. The "
                    + "config file documents this inline."),
            ]
        )

        // Built strictly in PageID.allCases order so the order is stable and
        // assertable.
        let byID: [PageID: Page] = [
            .welcome: welcome, .navigate: navigate, .arrange: arrange,
            .workspaces: workspaces, .displays: displays, .settings: settings,
        ]
        return PageID.allCases.map { byID[$0]! }
    }

    // MARK: - Coverage helpers (used by tests + available to the coordinator)

    /// Every keybinding row across all pages, in page+item order.
    static func keybindingRows(config: ScrollWMConfig) -> [KeybindingRow] {
        pages(config: config).flatMap { page in
            page.items.compactMap { item -> KeybindingRow? in
                if case let .keybinding(row) = item { return row }
                return nil
            }
        }
    }

    /// Every `KeyAction` documented across all pages, in order (with duplicates
    /// if any row mistakenly double-covers - a coverage test asserts there are
    /// none).
    static func coveredActions(config: ScrollWMConfig) -> [KeyAction] {
        keybindingRows(config: config).flatMap { $0.covers }
    }
}
