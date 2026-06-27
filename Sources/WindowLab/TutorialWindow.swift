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
/// One simple, continuous vertical scroll: a short title, the live practice
/// drill (real moving windows you drive to a goal), and a plain reference list
/// of every shortcut generated from the live config. No tabs, no cards, no
/// progress badges — just text + the interactive strip. The practice section
/// reacts to REAL key presses via a window-local `NSEvent` monitor installed
/// only while the window is key; it never registers a global tap and never
/// touches the user's windows. Opened from the menu bar, the `scrollwm
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
        startPractice()
    }

    // MARK: - Window state

    /// Outer horizontal padding for the single scroll column.
    private let pad: CGFloat = 24

    /// The interactive practice view (built from the live config; progress
    /// persists while the window is open).
    private lazy var practiceView = TutorialPracticeView(config: configProvider())

    /// The window-local key monitor that feeds real presses into the practice
    /// drill. Installed while the window is open.
    private var keyMonitor: Any?

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "How to use ScrollWM"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 460, height: 480)
        win.delegate = self

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let column = buildColumn(config: configProvider())
        let clip = TutorialFlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: clip.topAnchor),
            column.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
        scroll.documentView = clip
        clip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        win.contentView = scroll
        self.window = win
    }

    /// Build the one continuous content column: title + intro, the practice
    /// drill, the shortcut reference, and the config footer line.
    private func buildColumn(config: ScrollWMConfig) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
        stack.translatesAutoresizingMaskIntoConstraints = false

        func add(_ view: NSView, fullWidth: Bool = true) {
            stack.addArrangedSubview(view)
            if fullWidth {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                            constant: -pad * 2).isActive = true
            }
        }

        add(plainTitle("ScrollWM"))
        add(body("Your windows live in columns on one long horizontal strip. You "
            + "never see the whole strip at once — you teleport the viewport to the "
            + "column you want, all from the keyboard. ScrollWM stays dormant until "
            + "you Arrange, and Release puts every window back exactly as it was."))

        // Practice section.
        add(sectionHeading("Practice"))
        add(body("Drive the strip to each goal using the shortcuts shown. The "
            + "windows below really move."))
        practiceView.removeFromSuperview()
        practiceView.translatesAutoresizingMaskIntoConstraints = false
        add(practiceView)

        // Shortcut reference — every action, plainly listed from the live config.
        add(sectionHeading("All shortcuts"))
        for page in TutorialContent.pages(config: config) {
            let actions = page.items.flatMap { item -> [KeyAction] in
                if case let .keybinding(row) = item { return row.covers }
                return []
            }
            guard !actions.isEmpty else { continue }   // skip pages with no shortcuts
            add(groupHeading(page.title))
            for action in actions {
                add(shortcutRow(label: action.displayName,
                                chord: ChordFormatter.chordText(config, action)))
            }
        }

        // Config footer.
        add(sectionHeading("Config"))
        add(body("Every keybinding lives in one editable file. Edit it, then "
            + "Menu → Reload Config — changes apply live."))
        add(monoPath(ScrollWMConfig.fileURL.path))
        add(buildButtons())

        return stack
    }

    // MARK: - Plain components (no cards / badges / heavy theming)

    private func plainTitle(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 24, weight: .bold)
        f.textColor = .labelColor
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func sectionHeading(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 17, weight: .semibold)
        f.textColor = .labelColor
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func groupHeading(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 12, weight: .semibold)
        f.textColor = .secondaryLabelColor
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func body(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: 13)
        f.textColor = .secondaryLabelColor
        f.translatesAutoresizingMaskIntoConstraints = false
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    private func monoPath(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        f.textColor = .tertiaryLabelColor
        f.isSelectable = true
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    /// One reference line: "Focus left" on the left, "⌘H" on the right.
    private func shortcutRow(label: String, chord: String) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 13)
        name.textColor = .labelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let keys = NSTextField(labelWithString: chord)
        keys.font = .systemFont(ofSize: 13, weight: .medium)
        keys.textColor = .secondaryLabelColor
        keys.alignment = .right
        keys.translatesAutoresizingMaskIntoConstraints = false
        keys.setContentHuggingPriority(.required, for: .horizontal)
        keys.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(name)
        row.addSubview(keys)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            name.topAnchor.constraint(equalTo: row.topAnchor),
            name.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            keys.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            keys.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            keys.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 12),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        return row
    }

    private func buildButtons() -> NSView {
        let openConfig = NSButton(title: "Open Config File", target: self, action: #selector(openConfig))
        openConfig.bezelStyle = .rounded
        let done = NSButton(title: "Got it", target: self, action: #selector(closeWindow))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [openConfig, done])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        return buttons
    }

    // MARK: - Practice key forwarding

    /// Begin forwarding real key presses into the drill. Installs a
    /// window-LOCAL `NSEvent` monitor (fires only for events delivered to this
    /// app while our window is key) gated on `practiceView.isCapturing`. We
    /// intercept only chords carrying a ⌘/⌃/⌥ modifier so plain keys still reach
    /// the buttons and an accidental ⌘W/⌘Q can't hit a menu while drilling.
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
            if let chord = TutorialPractice.chordString(keyCode: UInt32(event.keyCode), flags: flags),
               self.practiceView.deliver(chord: chord) != .ignored {
                return nil   // swallow only chords the drill actually consumed
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
    }

    // MARK: - Static rendering entry point

    /// Render "cmd+shift+h" as "⌘⇧H" for display. Kept as a static entry point
    /// (used by the menu-bar cheat sheet + key-hint flash) that delegates to the
    /// pure, fully-tested `ChordFormatter`.
    static func pretty(_ chord: String) -> String { ChordFormatter.pretty(chord) }

    /// Test/render hook: build the content column at a fixed width without a
    /// window. Returns nil only on an unexpected layout failure.
    func debugBuildColumn(width: CGFloat) -> NSView? {
        let column = buildColumn(config: configProvider())
        column.widthAnchor.constraint(equalToConstant: width).isActive = true
        return column
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

/// A top-left-origin container so scrolled tutorial content starts at the top.
final class TutorialFlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension ScrollWMConfig {
    static func writeDefaultFileIfMissing() {
        if !FileManager.default.fileExists(atPath: fileURL.path) { writeDefaultFile() }
    }
}
