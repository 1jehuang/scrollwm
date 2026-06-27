import Foundation
import AppKit

/// Pure, AppKit-free chord formatting + tutorial key-table spec.
///
/// All of the logic that decides *what text the tutorial shows* lives here so it
/// can be unit-tested without building an `NSWindow`. `TutorialWindowController`
/// is a thin AppKit shell on top of this.
///
/// `pretty` is the single source of truth for rendering a config chord string
/// (e.g. `"cmd+shift+h"`) as a glanceable symbol string (e.g. `"⌘⇧H"`). It is
/// **total**: every possible input produces output, never a crash, and unknown
/// tokens fall back to an upper-cased literal. It is also **idempotent** —
/// `pretty(pretty(x)) == pretty(x)` — because the modifier glyphs it emits are
/// re-tokenized on a second pass.
enum ChordFormatter {

    /// Modifier tokens (and the glyphs they emit) accepted on input. The glyph
    /// keys make `pretty` idempotent: feeding `"⌘"` back in re-emits `"⌘"`.
    static let modifierSymbols: [String: String] = [
        "cmd": "⌘", "command": "⌘", "⌘": "⌘",
        "opt": "⌥", "option": "⌥", "alt": "⌥", "⌥": "⌥",
        "ctrl": "⌃", "control": "⌃", "⌃": "⌃",
        "shift": "⇧", "⇧": "⇧",
    ]

    /// Named keys that render as a glyph or a tidy word. Covers every special
    /// key ScrollWM can bind plus the spoken punctuation names the config
    /// parser accepts, so a chord typed by name renders cleanly.
    static let keySymbols: [String: String] = [
        // Arrows.
        "left": "←", "right": "→", "up": "↑", "down": "↓",
        // Editing / whitespace keys.
        "escape": "⎋", "esc": "⎋",
        "space": "Space",
        "return": "↩", "enter": "↩",
        "tab": "⇥",
        "delete": "⌫", "backspace": "⌫",
        // Spoken punctuation -> glyph (matches Chord.keyCodes' named aliases).
        "backslash": "\\",
        "slash": "/",
        "semicolon": ";",
        "quote": "'", "apostrophe": "'",
        "comma": ",",
        "period": ".", "dot": ".",
        "equal": "=", "equals": "=",
        "grave": "`", "backtick": "`",
        "leftbracket": "[", "rightbracket": "]",
        "minus": "-", "hyphen": "-",
    ]

    /// Split a chord string into its tokens, lower-cased. Mirrors
    /// `Chord.init(string:)`: separators are `+`, `-` and space, and glued
    /// modifier glyphs (`"⌘⇧L"`) are first re-spaced so they tokenize like
    /// `"cmd+shift+l"`. This is what makes `pretty` idempotent.
    static func tokenize(_ chord: String) -> [String] {
        var s = chord.lowercased()
        for sym in ["⌘", "⌥", "⌃", "⇧"] {
            s = s.replacingOccurrences(of: sym, with: "+\(sym)+")
        }
        return s
            .split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Render a single token. Modifiers and named keys map to glyphs; anything
    /// else (letters, digits, function keys like `f1`, unknown words) falls
    /// back to an upper-cased literal so the function is total.
    static func symbol(for token: String) -> String {
        if let m = modifierSymbols[token] { return m }
        if let k = keySymbols[token] { return k }
        return token.uppercased()
    }

    /// Render `"cmd+shift+h"` as `"⌘⇧H"` for display. Total + idempotent.
    /// Empty / separator-only input returns the original string unchanged.
    static func pretty(_ chord: String) -> String {
        let tokens = tokenize(chord)
        guard !tokens.isEmpty else { return chord }
        let out = tokens.map(symbol(for:)).joined()
        return out.isEmpty ? chord : out
    }

    /// Split a chord into the individual symbols to render as separate KEYCAPS
    /// (one rounded "physical key" per element), e.g. `"cmd+shift+h"` ->
    /// `["⌘", "⇧", "H"]`. Modifiers keep their glyphs; the main key renders as
    /// its glyph (arrows/escape/…) or an upper-cased literal. Total: degenerate
    /// input yields an empty array (the caller falls back to the pretty string).
    /// Modifiers are emitted first (in canonical ⌃⌥⇧⌘-ish input order they were
    /// typed), then the single non-modifier key, mirroring how a chord reads.
    static func keycaps(_ chord: String) -> [String] {
        tokenize(chord).map(symbol(for:)).filter { !$0.isEmpty }
    }

    /// Keycaps for the FIRST chord bound to `action` in `config` (or the
    /// built-in default), e.g. `[⌘, ⇧, H]`. The tutorial renders these as
    /// individual keys; multi-chord actions (width via Opt+N or Cmd+N) are
    /// documented in the keys text, but the keycap graphic shows the primary.
    static func keycaps(_ config: ScrollWMConfig, _ action: KeyAction) -> [String] {
        let chords = config.keybindings[action] ?? KeyAction.defaultChords[action] ?? []
        guard let first = chords.first else { return [] }
        return keycaps(first)
    }

    /// The pretty, display-ready chord(s) bound to `action` in `config`,
    /// falling back to the built-in defaults when unset, joined with " or " when
    /// an action has multiple triggers. Pure: depends only on its inputs.
    static func chordText(_ config: ScrollWMConfig, _ action: KeyAction) -> String {
        let chords = config.keybindings[action] ?? KeyAction.defaultChords[action] ?? []
        return chords.map(pretty).joined(separator: " or ")
    }

    /// One row of the tutorial's key table: a human label, the set of
    /// `KeyAction`s it documents (so coverage is verifiable), and a pure
    /// function producing the keys cell from the live config.
    struct KeyTableRow {
        let label: String
        let covers: [KeyAction]
        let keys: (ScrollWMConfig) -> String

        init(_ label: String, _ covers: [KeyAction], keys: @escaping (ScrollWMConfig) -> String) {
            self.label = label
            self.covers = covers
            self.keys = keys
        }
    }

    /// The full key table, data-driven so a unit test can assert it covers
    /// EVERY user-facing `KeyAction` exactly once (no stale or missing rows).
    static func keyTableRows() -> [KeyTableRow] {
        [
            KeyTableRow("Toggle arrange / release", [.toggleArrange]) {
                chordText($0, .toggleArrange)
            },
            KeyTableRow("Focus previous / next column", [.focusPrevious, .focusNext]) {
                "\(chordText($0, .focusPrevious)) / \(chordText($0, .focusNext))"
            },
            KeyTableRow("Focus left / right", [.focusLeft, .focusRight]) {
                "\(chordText($0, .focusLeft)) / \(chordText($0, .focusRight))"
            },
            KeyTableRow("Jump to column 1–9", [.jumpModifier]) {
                "\(chordText($0, .jumpModifier)) + 1…9"
            },
            KeyTableRow("Move column left / right", [.moveColumnLeft, .moveColumnRight]) {
                "\(chordText($0, .moveColumnLeft)) / \(chordText($0, .moveColumnRight))"
            },
            KeyTableRow("Workspace down / up", [.workspaceDown, .workspaceUp]) {
                "\(chordText($0, .workspaceDown)) / \(chordText($0, .workspaceUp))"
            },
            KeyTableRow("Send window to workspace down / up", [.moveToWorkspaceDown, .moveToWorkspaceUp]) {
                "\(chordText($0, .moveToWorkspaceDown)) / \(chordText($0, .moveToWorkspaceUp))"
            },
            KeyTableRow("Focus next / previous display", [.focusDisplayNext, .focusDisplayPrevious]) {
                "\(chordText($0, .focusDisplayNext)) / \(chordText($0, .focusDisplayPrevious))"
            },
            KeyTableRow("Send window to next / previous display", [.moveToDisplayNext, .moveToDisplayPrevious]) {
                "\(chordText($0, .moveToDisplayNext)) / \(chordText($0, .moveToDisplayPrevious))"
            },
            KeyTableRow("Width 25% / 50% / 75% / 100%", [.width25, .width50, .width75, .width100]) { c in
                [KeyAction.width25, .width50, .width75, .width100]
                    .map { chordText(c, $0) }.joined(separator: "  ")
            },
            KeyTableRow("Close focused window", [.closeWindow]) {
                chordText($0, .closeWindow)
            },
            KeyTableRow("New terminal window", [.spawnTerminal]) {
                chordText($0, .spawnTerminal)
            },
        ]
    }
}

/// In-app tutorial / cheat-sheet window for ScrollWM.
///
/// Opened from the menu bar ("How to use ScrollWM") and, on a genuine first
/// run, automatically once the controller starts so a brand-new user always
/// learns the basics. Content is generated from the live config so the shown
/// keys always match what is actually bound — there is no second copy of the
/// keymap to drift out of sync.
final class TutorialWindowController: NSObject {
    private var window: NSWindow?
    private let configProvider: () -> ScrollWMConfig
    private let levelsProvider: () -> [KeyAction: KeybindingProficiency.Level]

    init(configProvider: @escaping () -> ScrollWMConfig,
         levelsProvider: @escaping () -> [KeyAction: KeybindingProficiency.Level] = {
             Dictionary(uniqueKeysWithValues: KeyAction.allCases.map { ($0, .unknown) })
         }) {
        self.configProvider = configProvider
        self.levelsProvider = levelsProvider
    }

    func present() {
        if window != nil {
            rebuildBody()
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        buildWindow()
        window?.makeKeyAndOrderFront(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Window

    private var bodyStack: NSStackView?

    /// Horizontal inset on each side of the body content. Wrapping labels are
    /// constrained to `body.width - 2 * bodyInset` so text reflows (instead of
    /// clipping) as the window is resized.
    private let bodyInset: CGFloat = 28

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "How to use ScrollWM"
        win.isReleasedWhenClosed = false
        // Floor the size so content can never be squeezed into clipping.
        win.minSize = NSSize(width: 480, height: 420)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        body.edgeInsets = NSEdgeInsets(top: 24, left: bodyInset, bottom: 24, right: bodyInset)
        body.translatesAutoresizingMaskIntoConstraints = false

        let clip = FlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: clip.topAnchor),
            body.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            body.bottomAnchor.constraint(lessThanOrEqualTo: clip.bottomAnchor),
        ])
        scroll.documentView = clip
        // Pin the document width to the scroll view so content reflows to the
        // window width and only ever scrolls vertically.
        NSLayoutConstraint.activate([
            clip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        win.contentView = scroll
        self.window = win
        self.bodyStack = body
        rebuildBody()
    }

    private func rebuildBody() {
        guard let body = bodyStack else { return }
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let config = configProvider()
        let levels = levelsProvider()

        addArranged(heading("ScrollWM in 30 seconds"), to: body)
        addArranged(para(
            "ScrollWM lays your windows out as columns on one long horizontal "
            + "strip. You don't see the whole strip at once — you teleport the "
            + "viewport to the column you want. It's PaperWM/niri-style, but "
            + "Accessibility-only and instant."), to: body, wraps: true)

        addArranged(heading("The one rule that keeps you safe"), to: body)
        addArranged(para(
            "ScrollWM is DORMANT until you choose Arrange. It captures every "
            + "window's exact position first, and Release (or Quit) puts "
            + "everything back. Panic key: \(chordText(config, .toggleArrange)) "
            + "toggles arrange/release at any time."), to: body, wraps: true)

        // Core keys + your progress: the heart of the tutorial. Each core
        // shortcut is shown as keycap graphics with a learned/not-learned
        // badge, plus a rolled-up "N of M" progress bar.
        addArranged(heading("Core shortcuts — your progress"), to: body)
        addArranged(progressPanel(config, levels), to: body, wraps: true)
        addArranged(para(
            "These are the vim-style keys (plus close & new-terminal) that drive "
            + "the strip from the keyboard. Use a shortcut a few times and it "
            + "flips to “Learned”. Drift back to the menu and it goes rusty — a "
            + "nudge that you're leaving the keyboard."), to: body, wraps: true)

        addArranged(heading("Other keys (from your config)"), to: body)
        addArranged(keyTable(config), to: body)

        addArranged(heading("Changing settings — config file only"), to: body)
        addArranged(para(
            "Every setting (keybindings, column gap, width presets, focus mode) "
            + "lives in one human-editable file:"), to: body, wraps: true)
        addArranged(monoPath(ScrollWMConfig.fileURL.path), to: body, wraps: true)
        addArranged(bullet("Menu → Open Config File opens it in your editor. It's commented JSON."), to: body, wraps: true)
        addArranged(bullet("Save your edits, then Menu → Reload Config. Changes apply live — no relaunch."), to: body, wraps: true)
        addArranged(para(
            "Modifiers: cmd, opt, ctrl, shift. Note: navigation/width/close use "
            + "permission-free Carbon hotkeys (which can't use Cmd+H/Cmd+M); "
            + "focus-left/right and move-left/right use a keyboard tap, so those "
            + "can use Cmd+H/L. The config file documents this inline."), to: body, wraps: true)

        // Footer buttons.
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let openConfig = NSButton(title: "Open Config File", target: self, action: #selector(openConfig))
        openConfig.bezelStyle = .rounded
        let done = NSButton(title: "Got it", target: self, action: #selector(closeWindow))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        buttons.addArrangedSubview(openConfig)
        buttons.addArrangedSubview(done)
        addArranged(buttons, to: body)
    }

    /// Add a view to the body stack, optionally constraining its width so text
    /// reflows with the window instead of clipping.
    private func addArranged(_ view: NSView, to body: NSStackView, wraps: Bool = false) {
        body.addArrangedSubview(view)
        if wraps {
            view.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -bodyInset * 2).isActive = true
        }
    }

    // MARK: - Content rendering

    /// The "other keys" reference table: every key-table row whose actions are
    /// NOT in the core set (toggle, focus prev/next, jump, width). The core
    /// shortcuts get the richer keycap + progress treatment above instead, so we
    /// don't duplicate them here.
    private func keyTable(_ config: ScrollWMConfig) -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 18
        grid.translatesAutoresizingMaskIntoConstraints = false
        for row in ChordFormatter.keyTableRows() where !row.covers.contains(where: { $0.isCore }) {
            let left = label14(row.label); left.textColor = .secondaryLabelColor
            let right = monoLabel(row.keys(config))
            grid.addRow(with: [left, right])
        }
        return grid
    }

    /// The core-shortcuts learning panel: a progress summary + bar, then one row
    /// per core action with keycap graphics and a learned/not-learned badge.
    private func progressPanel(_ config: ScrollWMConfig,
                               _ levels: [KeyAction: KeybindingProficiency.Level]) -> NSView {
        let panel = NSStackView()
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 10
        panel.translatesAutoresizingMaskIntoConstraints = false

        // Headline + progress bar.
        let summary = TutorialProgress.summary(levels: levels)
        let headline = NSTextField(labelWithString: summary.headline)
        headline.font = .systemFont(ofSize: 13, weight: .semibold)
        panel.addArrangedSubview(headline)

        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = summary.fraction
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 240).isActive = true
        panel.addArrangedSubview(bar)

        // One row per core action: label · keycaps · status badge.
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 16
        grid.translatesAutoresizingMaskIntoConstraints = false
        for row in TutorialProgress.rows(levels: levels) {
            let name = label14(row.action.displayName)
            name.textColor = .labelColor
            let caps = keycapRow(ChordFormatter.keycaps(config, row.action),
                                 fallback: chordText(config, row.action))
            let badge = statusBadge(row.state)
            grid.addRow(with: [name, caps, badge])
        }
        // Left-align all three columns (safe only after rows exist, so the
        // columns have been created).
        if grid.numberOfColumns > 0 {
            for c in 0..<grid.numberOfColumns { grid.column(at: c).xPlacement = .leading }
        }
        panel.addArrangedSubview(grid)
        return panel
    }

    /// Render a chord's symbols as individual rounded "keycap" views in a row,
    /// e.g. ⌘ ⇧ H. Falls back to a single keycap of the pretty chord text when
    /// the chord can't be split (degenerate / modifier-only).
    private func keycapRow(_ caps: [String], fallback: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        // Hug the caps tightly so the row reports its compact fitting width and
        // the grid cell never stretches a single cap across the column.
        row.setContentHuggingPriority(.required, for: .horizontal)
        row.setContentCompressionResistancePriority(.required, for: .horizontal)
        let symbols = caps.isEmpty ? [fallback] : caps
        for sym in symbols {
            row.addArrangedSubview(keycap(sym))
        }
        return row
    }

    /// A single rounded keycap showing one symbol, styled like a physical key.
    private func keycap(_ symbol: String) -> NSView {
        let cap = KeycapView(symbol: symbol)
        return cap
    }

    /// The learned/learning/rusty/not-started badge for a core action: a small
    /// colored glyph + caption. Color carries the gist; the caption carries the
    /// meaning so it survives color blindness.
    private func statusBadge(_ state: TutorialProgress.LearnState) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        let color = Self.color(for: state)
        let glyph = NSTextField(labelWithString: state.glyph)
        glyph.font = .systemFont(ofSize: 13, weight: .bold)
        glyph.textColor = color
        let caption = NSTextField(labelWithString: state.caption)
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = color
        row.addArrangedSubview(glyph)
        row.addArrangedSubview(caption)
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel(state.caption)
        return row
    }

    /// Semantic color for a learn state (system colors so they read in light
    /// and dark mode).
    static func color(for state: TutorialProgress.LearnState) -> NSColor {
        switch state {
        case .learned:    return .systemGreen
        case .rusty:      return .systemOrange
        case .learning:   return .systemBlue
        case .notStarted: return .tertiaryLabelColor
        }
    }

    private func chordText(_ config: ScrollWMConfig, _ action: KeyAction) -> String {
        ChordFormatter.chordText(config, action)
    }

    /// Render "cmd+shift+h" as "⌘⇧H" for display. Kept as a static entry point
    /// (used by the menu-bar cheat sheet + key-hint flash) that delegates to the
    /// pure, fully-tested `ChordFormatter`.
    static func pretty(_ chord: String) -> String { ChordFormatter.pretty(chord) }

    // MARK: - Label helpers

    private func heading(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 15, weight: .bold)
        return f
    }
    private func para(_ s: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = .systemFont(ofSize: 13)
        f.textColor = .secondaryLabelColor
        return f
    }
    private func bullet(_ s: String) -> NSTextField { para("•  " + s) }
    private func label14(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s); f.font = .systemFont(ofSize: 13); return f
    }
    private func monoLabel(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        return f
    }
    private func monoPath(_ s: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        f.textColor = .tertiaryLabelColor
        f.isSelectable = true
        return f
    }

    // MARK: - Actions

    @objc private func openConfig() {
        ScrollWMConfig.writeDefaultFileIfMissing()
        NSWorkspace.shared.open(ScrollWMConfig.fileURL)
    }
    @objc private func closeWindow() {
        window?.close()
    }
}

/// A top-left-origin container so the scrolled tutorial content starts at the
/// top rather than the bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A rounded "physical key" view that draws one symbol (e.g. ⌘, ⇧, H, ←) with a
/// keycap-style border + subtle fill, so the tutorial's chords read as actual
/// keys rather than plain text. Sizes itself to its content with a minimum
/// square-ish footprint, and adapts to light/dark mode via system colors.
final class KeycapView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(symbol: String) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        // Multi-char glyphs (Space, F12) get a slightly smaller font so they fit.
        let size: CGFloat = symbol.count > 1 ? 11 : 14
        label.stringValue = symbol
        label.font = .systemFont(ofSize: size, weight: .semibold)
        label.alignment = .center
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        addSubview(label)

        // Pad the symbol inside the cap and pin the cap to EXACTLY hug its
        // content (with a key-like minimum width), so a grid cell never
        // stretches a lone cap across its column. A `>=` minimum alone leaves
        // the width unbounded above, which AppKit then stretches to fill.
        let hPad: CGFloat = 8, vPad: CGFloat = 4
        let exactWidth = widthAnchor.constraint(equalTo: label.widthAnchor, constant: hPad * 2)
        exactWidth.priority = .defaultHigh   // yields to the 24pt floor for narrow glyphs
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: label.heightAnchor, constant: vPad * 2),
            exactWidth,
            widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        // Don't let the cap stretch in the row.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        // The whole cap is one a11y element that speaks the symbol.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(symbol)

        applyStyle()
    }

    required init?(coder: NSCoder) { nil }

    /// Re-apply the keycap style when the system appearance changes (light/dark).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        // Resolve CG colors against THIS view's effective appearance so the cap
        // matches light/dark mode.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 5
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.9).cgColor
        }
    }
}

extension ScrollWMConfig {
    static func writeDefaultFileIfMissing() {
        if !FileManager.default.fileExists(atPath: fileURL.path) { writeDefaultFile() }
    }
}
