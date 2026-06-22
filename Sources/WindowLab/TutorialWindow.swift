import Foundation
import AppKit

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

    init(configProvider: @escaping () -> ScrollWMConfig) {
        self.configProvider = configProvider
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

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "How to use ScrollWM"
        win.isReleasedWhenClosed = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        body.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
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

        body.addArrangedSubview(heading("ScrollWM in 30 seconds"))
        body.addArrangedSubview(para(
            "ScrollWM lays your windows out as columns on one long horizontal "
            + "strip. You don't see the whole strip at once — you teleport the "
            + "viewport to the column you want. It's PaperWM/niri-style, but "
            + "Accessibility-only and instant."))

        body.addArrangedSubview(heading("The one rule that keeps you safe"))
        body.addArrangedSubview(para(
            "ScrollWM is DORMANT until you choose Arrange. It captures every "
            + "window's exact position first, and Release (or Quit) puts "
            + "everything back. Panic key: \(chordText(config, .toggleArrange)) "
            + "toggles arrange/release at any time."))

        body.addArrangedSubview(heading("Getting started"))
        body.addArrangedSubview(bullet("Click the menu bar icon → Arrange. Your current-Space windows snap into the strip."))
        body.addArrangedSubview(bullet("Navigate with \(chordText(config, .focusPrevious)) / \(chordText(config, .focusNext)) or \(chordText(config, .focusLeft)) / \(chordText(config, .focusRight))."))
        body.addArrangedSubview(bullet("Resize the focused column with the width keys below."))
        body.addArrangedSubview(bullet("Done? Menu → Release restores every window exactly. ScrollWM goes dormant again."))

        body.addArrangedSubview(heading("Keys (from your current config)"))
        body.addArrangedSubview(keyTable(config))

        body.addArrangedSubview(heading("Changing settings — config file only"))
        body.addArrangedSubview(para(
            "Every setting (keybindings, column gap, width presets, focus mode) "
            + "lives in one human-editable file:"))
        body.addArrangedSubview(monoPath(ScrollWMConfig.fileURL.path))
        body.addArrangedSubview(bullet("Menu → Open Config File opens it in your editor. It's commented JSON."))
        body.addArrangedSubview(bullet("Save your edits, then Menu → Reload Config. Changes apply live — no relaunch."))
        body.addArrangedSubview(para(
            "Modifiers: cmd, opt, ctrl, shift. Note: navigation/width/close use "
            + "permission-free Carbon hotkeys (which can't use Cmd+H/Cmd+M); "
            + "focus-left/right and move-left/right use a keyboard tap, so those "
            + "can use Cmd+H/L. The config file documents this inline."))

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
        body.addArrangedSubview(buttons)
    }

    // MARK: - Content rendering

    private func keyTable(_ config: ScrollWMConfig) -> NSView {
        let rows: [(String, KeyAction?)] = [
            ("Toggle arrange / release", .toggleArrange),
            ("Focus previous / next column", .focusPrevious),
            ("Focus left / right", .focusLeft),
            ("Jump to column 1–9", .jumpModifier),
            ("Move column left / right", .moveColumnLeft),
            ("Width 25% / 50% / 75% / 100%", .width25),
            ("Close focused window", .closeWindow),
        ]
        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 18
        grid.translatesAutoresizingMaskIntoConstraints = false
        for (label, action) in rows {
            let keys: String
            switch action {
            case .focusPrevious:
                keys = "\(chordText(config, .focusPrevious)) / \(chordText(config, .focusNext))"
            case .focusLeft:
                keys = "\(chordText(config, .focusLeft)) / \(chordText(config, .focusRight))"
            case .moveColumnLeft:
                keys = "\(chordText(config, .moveColumnLeft)) / \(chordText(config, .moveColumnRight))"
            case .jumpModifier:
                keys = "\(chordText(config, .jumpModifier)) + 1…9"
            case .width25:
                keys = [KeyAction.width25, .width50, .width75, .width100]
                    .map { chordText(config, $0) }.joined(separator: "  ")
            case .some(let a):
                keys = chordText(config, a)
            case .none:
                keys = ""
            }
            let left = label14(label); left.textColor = .secondaryLabelColor
            let right = monoLabel(keys)
            grid.addRow(with: [left, right])
        }
        return grid
    }

    private func chordText(_ config: ScrollWMConfig, _ action: KeyAction) -> String {
        let chords = config.keybindings[action] ?? KeyAction.defaultChords[action] ?? []
        return chords.map(Self.pretty).joined(separator: " or ")
    }

    /// Render "cmd+shift+h" as "⌘⇧H" for display.
    static func pretty(_ chord: String) -> String {
        var out = ""
        let tokens = chord.lowercased().split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " }).map(String.init)
        let symbols: [String: String] = [
            "cmd": "⌘", "command": "⌘", "opt": "⌥", "option": "⌥", "alt": "⌥",
            "ctrl": "⌃", "control": "⌃", "shift": "⇧",
            "left": "←", "right": "→", "up": "↑", "down": "↓",
            "escape": "⎋", "esc": "⎋", "space": "Space", "return": "↩", "enter": "↩", "tab": "⇥",
        ]
        for token in tokens {
            if let sym = symbols[token] { out += sym }
            else { out += token.uppercased() }
        }
        return out.isEmpty ? chord : out
    }

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
        f.preferredMaxLayoutWidth = 452
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
        let f = NSTextField(labelWithString: s)
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

extension ScrollWMConfig {
    static func writeDefaultFileIfMissing() {
        if !FileManager.default.fileExists(atPath: fileURL.path) { writeDefaultFile() }
    }
}
