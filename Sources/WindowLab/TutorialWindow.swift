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
/// Redesigned (tutorial-redesign swarm) into a paged, themed, partly-animated,
/// interactive window. It is composed entirely from the lane modules:
///   - `TutorialTheme` / `TutorialComponents`  — the visual language + widgets.
///   - `TutorialContent`                        — the pure, paged content spec
///                                                (generated from the live config).
///   - `TutorialStripDiagram`                   — the hero animation that SHOWS
///                                                the scrolling-strip metaphor.
///   - `TutorialPractice` / `TutorialPracticeView` — the interactive drill.
///
/// A hero header sits above a segmented page selector; selecting a segment swaps
/// the content area between the reference pages (themed cards of keycap rows
/// generated from the live config, so the shown keys never drift) and an
/// interactive Practice page. The Practice page reacts to REAL key presses via a
/// window-local `NSEvent` monitor that is installed only while that page is
/// visible — it never registers a global tap and never touches the user's
/// windows. Opened from the menu bar ("How to use ScrollWM"), the `scrollwm
/// tutorial` CLI, and automatically once on a genuine first run.
final class TutorialWindowController: NSObject, NSWindowDelegate {
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
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        buildWindow()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Segments

    /// One entry in the page selector: either a content page (from
    /// `TutorialContent`) or the interactive Practice page.
    private enum Segment: Equatable {
        case page(TutorialContent.PageID)
        case practice
    }

    /// The selector order: the content pages in teaching order, with the
    /// interactive Practice page inserted just before Settings.
    private let segments: [Segment] = [
        .page(.welcome), .page(.navigate), .page(.arrange),
        .page(.workspaces), .page(.displays), .practice, .page(.settings),
    ]

    /// A short, selector-friendly title for a segment.
    private func shortTitle(_ s: Segment) -> String {
        switch s {
        case .practice: return "Practice"
        case .page(let id):
            switch id {
            case .welcome:    return "Welcome"
            case .navigate:   return "Navigate"
            case .arrange:    return "Arrange"
            case .workspaces: return "Workspaces"
            case .displays:   return "Displays"
            case .settings:   return "Settings"
            }
        }
    }

    // MARK: - Window state

    private var selector: TutorialSegmentedSelector?
    private var pageContainer: NSView?
    private var selectedIndex = 0

    /// Horizontal inset used for wrapping content inside a page's scroll view.
    private let pageInset = TutorialTheme.Spacing.lg

    /// The reused hero animation. Auto start/stops with window membership; we
    /// re-add it to the Welcome page each time that page is built.
    private lazy var diagram: TutorialStripDiagramView = {
        let v = TutorialStripDiagramView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 184).isActive = true
        return v
    }()

    /// The reused interactive practice view. Built from the live config; its
    /// progress persists while the window is open.
    private lazy var practiceView = TutorialPracticeView(config: configProvider())

    /// The window-local key monitor that feeds real presses into the practice
    /// drill. Installed only while the Practice page is visible.
    private var keyMonitor: Any?

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "How to use ScrollWM"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 600, height: 540)
        win.delegate = self

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let hero = TutorialHeroHeader(
            title: "ScrollWM",
            tagline: "A scrolling window manager for macOS. Your windows live in "
                + "columns on one long horizontal strip you teleport across.")
        hero.translatesAutoresizingMaskIntoConstraints = false

        let sel = TutorialSegmentedSelector(titles: segments.map(shortTitle), selectedIndex: 0)
        sel.onSelect = { [weak self] i in self?.selectSegment(i) }
        self.selector = sel

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.pageContainer = container

        let footer = buildFooter()

        content.addSubview(hero)
        content.addSubview(sel)
        content.addSubview(container)
        content.addSubview(footer)

        let pad = TutorialTheme.Spacing.lg
        let gap = TutorialTheme.Spacing.md
        NSLayoutConstraint.activate([
            hero.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            hero.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            hero.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            sel.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: gap),
            sel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            sel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            container.topAnchor.constraint(equalTo: sel.bottomAnchor, constant: gap),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            footer.topAnchor.constraint(equalTo: container.bottomAnchor, constant: gap),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
        ])

        win.contentView = content
        self.window = win
        selectSegment(0)
    }

    /// The persistent footer: an overall progress line on the left, and the
    /// Open Config File / Got it buttons on the right.
    private func buildFooter() -> NSView {
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        let summary = TutorialProgress.summary(levels: levelsProvider())
        let prog = TutorialComponents.label(summary.headline,
                                            font: TutorialTheme.Font.caption,
                                            color: TutorialTheme.Palette.textTertiary)
        prog.lineBreakMode = .byTruncatingTail
        prog.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let openConfig = NSButton(title: "Open Config File", target: self, action: #selector(openConfig))
        openConfig.bezelStyle = .rounded
        let done = NSButton(title: "Got it", target: self, action: #selector(closeWindow))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [openConfig, done])
        buttons.orientation = .horizontal
        buttons.spacing = TutorialTheme.Spacing.sm
        buttons.translatesAutoresizingMaskIntoConstraints = false

        footer.addSubview(prog)
        footer.addSubview(buttons)
        NSLayoutConstraint.activate([
            prog.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            prog.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: footer.topAnchor),
            buttons.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            prog.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor,
                                           constant: -TutorialTheme.Spacing.sm),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        return footer
    }

    // MARK: - Page swapping

    /// Select segment `index`, swap the content area, and manage the per-page
    /// lifecycle (hero animation + practice capture).
    private func selectSegment(_ index: Int) {
        guard segments.indices.contains(index), let container = pageContainer else { return }
        selectedIndex = index
        selector?.select(index)

        let segment = segments[index]
        let page = makePageView(for: segment)
        container.subviews.forEach { $0.removeFromSuperview() }
        page.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: container.topAnchor),
            page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        if case .practice = segment { startPractice() } else { stopPractice() }
    }

    private func makePageView(for segment: Segment) -> NSView {
        switch segment {
        case .practice:
            return makePracticePage()
        case .page(let id):
            let config = configProvider()
            let page = TutorialContent.pages(config: config).first { $0.id == id }
                ?? TutorialContent.pages(config: config)[0]
            return makeContentPage(page, config: config, levels: levelsProvider())
        }
    }

    // MARK: - Content pages

    /// Render one `TutorialContent.Page` as a vertically-scrolling stack of
    /// themed cards: a section header + intro, the hero diagram (Welcome only),
    /// a progress summary (Welcome only), and the page's items, with runs of
    /// keybinding rows grouped into cards.
    private func makeContentPage(_ page: TutorialContent.Page,
                                 config: ScrollWMConfig,
                                 levels: [KeyAction: KeybindingProficiency.Level]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = TutorialTheme.Spacing.md
        stack.edgeInsets = NSEdgeInsets(top: TutorialTheme.Spacing.xs, left: pageInset,
                                        bottom: pageInset, right: pageInset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        func add(_ view: NSView, wraps: Bool = false) {
            stack.addArrangedSubview(view)
            if wraps {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                            constant: -pageInset * 2).isActive = true
            }
        }

        add(TutorialSectionHeader(title: page.title, subtitle: "from your config"), wraps: true)

        if page.id == .welcome {
            let card = TutorialCard(padding: TutorialTheme.Spacing.md)
            card.setContent(diagram)
            add(card, wraps: true)
        }

        add(TutorialComponents.wrapping(page.intro), wraps: true)

        if page.id == .welcome {
            add(progressSummaryCard(levels: levels), wraps: true)
        }

        // Group consecutive keybinding items into a single card; render prose /
        // bullets / paths inline between cards.
        var pendingRows: [NSView] = []
        func flushRows() {
            guard !pendingRows.isEmpty else { return }
            add(card(rows: pendingRows), wraps: true)
            pendingRows = []
        }
        for item in page.items {
            switch item {
            case .prose(let s):
                flushRows(); add(TutorialComponents.wrapping(s), wraps: true)
            case .bullet(let s):
                flushRows(); add(TutorialComponents.bullet(s), wraps: true)
            case .configPath(let p):
                flushRows()
                let pathCard = TutorialCard(padding: TutorialTheme.Spacing.md)
                let mono = TutorialComponents.mono(p)
                pathCard.setContent(mono)
                mono.widthAnchor.constraint(lessThanOrEqualTo: pathCard.widthAnchor,
                                            constant: -TutorialTheme.Spacing.md * 2).isActive = true
                add(pathCard, wraps: true)
            case .keybinding(let row):
                pendingRows.append(contentsOf: keybindingRowViews(row, config: config, levels: levels))
            }
        }
        flushRows()

        return makeScroll(content: stack)
    }

    /// One keycap row per `KeyAction` a content row documents, so even paired
    /// rows ("Focus left / right") render as individual keycap rows with their
    /// own learn-state badge for the core shortcuts.
    private func keybindingRowViews(_ row: TutorialContent.KeybindingRow,
                                    config: ScrollWMConfig,
                                    levels: [KeyAction: KeybindingProficiency.Level]) -> [NSView] {
        row.covers.map { action in
            let state: TutorialProgress.LearnState? = action.isCore
                ? TutorialProgress.state(for: levels[action] ?? .unknown)
                : nil
            return TutorialKeybindingRow(config: config, action: action, state: state)
        }
    }

    /// Wrap a set of rows in a themed card with an internal vertical stack.
    private func card(rows: [NSView]) -> TutorialCard {
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = TutorialTheme.Spacing.sm
        inner.translatesAutoresizingMaskIntoConstraints = false
        for r in rows { inner.addArrangedSubview(r) }
        let card = TutorialCard()
        card.setContent(inner)
        for r in rows { r.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true }
        return card
    }

    /// The Welcome page's "learned vs not learned" summary: a headline, a
    /// progress bar over the core shortcuts, and a one-line nudge toward Practice.
    private func progressSummaryCard(levels: [KeyAction: KeybindingProficiency.Level]) -> NSView {
        let summary = TutorialProgress.summary(levels: levels)
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = TutorialTheme.Spacing.xs
        inner.translatesAutoresizingMaskIntoConstraints = false

        let head = TutorialComponents.label(summary.headline,
                                            font: TutorialTheme.Font.section,
                                            color: TutorialTheme.Palette.textPrimary)
        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = summary.fraction
        bar.controlSize = .regular
        bar.translatesAutoresizingMaskIntoConstraints = false
        let caption = TutorialComponents.wrapping(
            "Use a shortcut a few times and it flips to “Learned”. Open the "
            + "Practice tab to drill them, or drift back to the menu and a key "
            + "goes rusty — a nudge that you're leaving the keyboard.")

        inner.addArrangedSubview(head)
        inner.addArrangedSubview(bar)
        inner.addArrangedSubview(caption)

        let card = TutorialCard()
        card.setContent(inner)
        bar.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        caption.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        return card
    }

    /// A vertical scroll view whose document reflows to the scroll width and
    /// only ever scrolls vertically.
    private func makeScroll(content: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let clip = TutorialFlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: clip.bottomAnchor),
        ])
        scroll.documentView = clip
        NSLayoutConstraint.activate([
            clip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    // MARK: - Practice page

    private func makePracticePage() -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        practiceView.removeFromSuperview()
        practiceView.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(practiceView)
        let pad = TutorialTheme.Spacing.lg
        NSLayoutConstraint.activate([
            practiceView.topAnchor.constraint(equalTo: wrap.topAnchor, constant: pad),
            practiceView.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: pad),
            practiceView.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -pad),
            practiceView.bottomAnchor.constraint(lessThanOrEqualTo: wrap.bottomAnchor, constant: -pad),
            practiceView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        return wrap
    }

    /// Begin forwarding real key presses into the drill. Installs a
    /// window-LOCAL `NSEvent` monitor (fires only for events delivered to this
    /// app while our window is key) gated on `practiceView.isCapturing`. We
    /// intercept only chords carrying a ⌘/⌃/⌥ modifier so plain keys (Return,
    /// Space, Tab, Esc) still reach the buttons, and so an accidental ⌘W/⌘Q
    /// can't fall through to a menu action while the user is drilling.
    private func startPractice() {
        practiceView.start()
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.practiceView.isCapturing else { return event }
            let wm = event.modifierFlags.intersection([.command, .control, .option])
            guard !wm.isEmpty else { return event }
            var flags: CGEventFlags = []
            if event.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
            if event.modifierFlags.contains(.shift)   { flags.insert(.maskShift) }
            if event.modifierFlags.contains(.control) { flags.insert(.maskControl) }
            if event.modifierFlags.contains(.option)  { flags.insert(.maskAlternate) }
            if let chord = TutorialPractice.chordString(keyCode: UInt32(event.keyCode), flags: flags) {
                self.practiceView.deliver(chord: chord)
                return nil   // swallow so the practice chord never hits a menu
            }
            return event
        }
    }

    private func stopPractice() {
        practiceView.stop()
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopPractice()
        diagram.stop()
    }

    // MARK: - Static rendering entry point

    /// Render "cmd+shift+h" as "⌘⇧H" for display. Kept as a static entry point
    /// (used by the menu-bar cheat sheet + key-hint flash) that delegates to the
    /// pure, fully-tested `ChordFormatter`.
    static func pretty(_ chord: String) -> String { ChordFormatter.pretty(chord) }

    // MARK: - Actions

    @objc private func openConfig() {
        ScrollWMConfig.writeDefaultFileIfMissing()
        NSWorkspace.shared.open(ScrollWMConfig.fileURL)
    }
    @objc private func closeWindow() {
        window?.close()
    }
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
