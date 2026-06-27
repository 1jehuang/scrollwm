import AppKit

/// Reusable AppKit building blocks for the redesigned ScrollWM tutorial window,
/// all styled with `TutorialTheme`. The coordinator composes the window from
/// these so the look stays consistent and the assembly code stays declarative.
///
/// Every type here is self-contained and constructible from the shared APIs
/// (`ChordFormatter`, `KeyAction`, `TutorialProgress.LearnState`). View types
/// use Auto Layout (`translatesAutoresizingMaskIntoConstraints = false`) and
/// report a correct `intrinsicContentSize`/`fittingSize` so the coordinator can
/// drop them into a stack view without extra constraints. They also re-resolve
/// their layer colors on `viewDidChangeEffectiveAppearance` so light/dark
/// switches are live.
///
/// Namespace of light-weight factories for the plain text roles; the richer
/// pieces are dedicated `NSView` subclasses below.
enum TutorialComponents {

    // MARK: - Text factories

    /// A non-wrapping label in a given role font + text tier.
    static func label(_ text: String,
                      font: NSFont = TutorialTheme.Font.body,
                      color: NSColor = TutorialTheme.Palette.textPrimary) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = font
        f.textColor = color
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    /// A wrapping body label (reflows to its container width).
    static func wrapping(_ text: String,
                         font: NSFont = TutorialTheme.Font.body,
                         color: NSColor = TutorialTheme.Palette.textSecondary) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = font
        f.textColor = color
        f.translatesAutoresizingMaskIntoConstraints = false
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    /// A bullet line ("•  ...") in the wrapping body style.
    static func bullet(_ text: String) -> NSTextField {
        wrapping("•  " + text)
    }

    /// A selectable monospaced path / code label (tertiary tier).
    static func mono(_ text: String,
                     color: NSColor = TutorialTheme.Palette.textTertiary) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = TutorialTheme.Font.mono
        f.textColor = color
        f.isSelectable = true
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }
}

// MARK: - Flipped container

/// A top-left-origin container so scrolled tutorial content starts at the top.
/// Public so the coordinator can reuse it for the document view.
final class TutorialFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Hero header

/// The tutorial's hero header: a big title, a tagline, and an accent bar/wash so
/// the top of the window reads as a finished product banner. Rounded card-like
/// surface tinted with the brand accent.
final class TutorialHeroHeader: NSView {
    private let titleLabel: NSTextField
    private let taglineLabel: NSTextField
    private let accentBar = NSView()

    /// - Parameters:
    ///   - title: the big headline (e.g. "ScrollWM").
    ///   - tagline: the supporting one-liner under it.
    ///   - showAccent: when true, draws the accent side-bar + soft wash. Default true.
    init(title: String, tagline: String, showAccent: Bool = true) {
        titleLabel = TutorialComponents.label(title, font: TutorialTheme.Font.hero,
                                              color: TutorialTheme.Palette.textPrimary)
        taglineLabel = TutorialComponents.wrapping(tagline, font: TutorialTheme.Font.section,
                                                  color: TutorialTheme.Palette.textSecondary)
        taglineLabel.font = .systemFont(ofSize: TutorialTheme.FontSize.section, weight: .regular)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = TutorialTheme.Radius.hero

        accentBar.translatesAutoresizingMaskIntoConstraints = false
        accentBar.wantsLayer = true
        accentBar.layer?.cornerRadius = 2
        accentBar.isHidden = !showAccent

        let textStack = NSStackView(views: [titleLabel, taglineLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = TutorialTheme.Spacing.xs
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(accentBar)
        addSubview(textStack)

        let pad = TutorialTheme.Spacing.lg
        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            accentBar.topAnchor.constraint(equalTo: textStack.topAnchor, constant: 2),
            accentBar.bottomAnchor.constraint(equalTo: textStack.bottomAnchor, constant: -2),
            accentBar.widthAnchor.constraint(equalToConstant: 4),

            textStack.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: showAccent ? pad * 0.66 : 0),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ])
        applyStyle()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = TutorialTheme.Palette.accentSoft.cgColor
            accentBar.layer?.backgroundColor = TutorialTheme.Palette.accent.cgColor
        }
    }
}

// MARK: - Card

/// A rounded, elevated surface with subtle border + shadow and interior padding.
/// Add content with `setContent(_:)` (the card pins it with the configured
/// padding) or add subviews directly and lay them out yourself.
final class TutorialCard: NSView {
    private let contentContainer = NSView()
    private var contentConstraints: [NSLayoutConstraint] = []

    /// Interior padding on every side. Defaults to `Spacing.lg` (24).
    let padding: CGFloat

    /// - Parameter padding: interior inset on all four sides (default 24).
    init(padding: CGFloat = TutorialTheme.Spacing.lg) {
        self.padding = padding
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = TutorialTheme.Radius.card
        layer?.borderWidth = 1
        // Soft elevation shadow.
        shadow = NSShadow()
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            contentContainer.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])
        applyStyle()
    }

    required init?(coder: NSCoder) { nil }

    /// Place a single content view inside the card, pinned to the padded box.
    func setContent(_ view: NSView) {
        NSLayoutConstraint.deactivate(contentConstraints)
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        contentConstraints = [
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(contentConstraints)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = TutorialTheme.Palette.cardSurface.cgColor
            layer?.borderColor = TutorialTheme.Palette.border.cgColor
            layer?.shadowColor = TutorialTheme.Palette.shadow.cgColor
        }
    }
}

// MARK: - Section header

/// A section header: an accent tick + a title in the section font, with an
/// optional trailing subtitle. Used to introduce a group of rows inside a card.
final class TutorialSectionHeader: NSView {
    private let tick = NSView()
    private let titleLabel: NSTextField
    private var subtitleLabel: NSTextField?

    /// - Parameters:
    ///   - title: the section title.
    ///   - subtitle: optional trailing detail, right-aligned (e.g. "from your config").
    init(title: String, subtitle: String? = nil) {
        titleLabel = TutorialComponents.label(title, font: TutorialTheme.Font.section,
                                              color: TutorialTheme.Palette.textPrimary)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        tick.translatesAutoresizingMaskIntoConstraints = false
        tick.wantsLayer = true
        tick.layer?.cornerRadius = 1.5
        addSubview(tick)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            tick.leadingAnchor.constraint(equalTo: leadingAnchor),
            tick.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            tick.widthAnchor.constraint(equalToConstant: 3),
            tick.heightAnchor.constraint(equalToConstant: TutorialTheme.FontSize.section),

            titleLabel.leadingAnchor.constraint(equalTo: tick.trailingAnchor, constant: TutorialTheme.Spacing.xs),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if let subtitle, !subtitle.isEmpty {
            let sub = TutorialComponents.label(subtitle, font: TutorialTheme.Font.caption,
                                              color: TutorialTheme.Palette.textTertiary)
            addSubview(sub)
            subtitleLabel = sub
            NSLayoutConstraint.activate([
                sub.trailingAnchor.constraint(equalTo: trailingAnchor),
                sub.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
                sub.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor,
                                             constant: TutorialTheme.Spacing.sm),
            ])
        } else {
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).isActive = true
        }
        applyStyle()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            tick.layer?.backgroundColor = TutorialTheme.Palette.accent.cgColor
        }
    }
}

// MARK: - Keycap

/// A refined "physical key" pill that draws one symbol (⌘, ⇧, H, ←, Space...).
/// A crisper take on the existing `KeycapView`: themed radius/typography, a
/// 1px top highlight + bottom shadow for depth, and an optional `pressed` state
/// (for Lane 4's practice mode) that inverts to the accent color and sinks the
/// cap. Sizes itself to its content with a key-like minimum footprint.
final class TutorialKeycap: NSView {
    private let label = NSTextField(labelWithString: "")
    private let symbol: String

    /// When true the cap renders "pressed": accent fill, light glyph, sunk
    /// shadow. Animatable via `setPressed(_:animated:)`.
    var pressed: Bool = false {
        didSet { if pressed != oldValue { applyStyle() } }
    }

    /// - Parameter symbol: the glyph/letter to show (typically from
    ///   `ChordFormatter.keycaps`), e.g. "⌘", "H", "Space".
    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // Multi-char glyphs (Space, F12) get a slightly smaller font so they fit.
        label.stringValue = symbol
        label.font = symbol.count > 1 ? TutorialTheme.Font.keycapSmall : TutorialTheme.Font.keycap
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        addSubview(label)

        let hPad: CGFloat = 9, vPad: CGFloat = 5
        // Exactly hug content (so a grid cell never stretches a lone cap),
        // yielding to the key-like minimum width for narrow glyphs.
        let exactWidth = widthAnchor.constraint(equalTo: label.widthAnchor, constant: hPad * 2)
        exactWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
            exactWidth,
            widthAnchor.constraint(greaterThanOrEqualToConstant: 26),
            heightAnchor.constraint(equalToConstant: 26),
            label.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -vPad * 2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(symbol)

        applyStyle()
    }

    required init?(coder: NSCoder) { nil }

    /// Toggle the pressed look, optionally animating the color/shadow change.
    func setPressed(_ value: Bool, animated: Bool) {
        guard animated else { pressed = value; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            pressed = value
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.cornerRadius = TutorialTheme.Radius.keycap
            layer?.borderWidth = 1
            if pressed {
                layer?.backgroundColor = TutorialTheme.Palette.accent.cgColor
                layer?.borderColor = TutorialTheme.Palette.accent.cgColor
                label.textColor = TutorialTheme.Palette.onAccent
                layer?.shadowOpacity = 0
            } else {
                layer?.backgroundColor = TutorialTheme.Palette.inset.cgColor
                layer?.borderColor = TutorialTheme.Palette.border.cgColor
                label.textColor = TutorialTheme.Palette.textPrimary
                // Subtle downward shadow for a raised-key feel.
                layer?.shadowColor = TutorialTheme.Palette.shadow.cgColor
                layer?.shadowOpacity = 1
                layer?.shadowRadius = 1.5
                layer?.shadowOffset = CGSize(width: 0, height: -1)
            }
        }
    }
}

// MARK: - Keycaps row

/// A horizontal run of `TutorialKeycap`s for one chord, e.g. ⌘ ⇧ H. Falls back
/// to a single cap of the `fallback` text when the chord can't be split
/// (degenerate / modifier-only). Hugs tightly so it never stretches in a grid.
final class TutorialKeycapRow: NSView {
    /// The individual caps, in order, so a caller (Lane 4) can drive a pressed
    /// animation per key.
    private(set) var keycaps: [TutorialKeycap] = []
    private let stack = NSStackView()

    /// - Parameters:
    ///   - caps: the per-key symbols (e.g. from `ChordFormatter.keycaps`).
    ///   - fallback: shown as one cap when `caps` is empty.
    init(caps: [String], fallback: String = "") {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = TutorialTheme.Spacing.xxs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let symbols = caps.isEmpty ? (fallback.isEmpty ? [] : [fallback]) : caps
        for sym in symbols {
            let cap = TutorialKeycap(symbol: sym)
            keycaps.append(cap)
            stack.addArrangedSubview(cap)
        }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(symbols.joined(separator: " "))
    }

    /// Convenience: build the row from a config + action via `ChordFormatter`.
    convenience init(config: ScrollWMConfig, action: KeyAction) {
        self.init(caps: ChordFormatter.keycaps(config, action),
                  fallback: ChordFormatter.chordText(config, action))
    }

    required init?(coder: NSCoder) { nil }

    /// Flash all caps pressed then released (a brief "key pressed" affordance).
    func flashPressed() {
        keycaps.forEach { $0.setPressed(true, animated: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            self?.keycaps.forEach { $0.setPressed(false, animated: true) }
        }
    }
}

// MARK: - Status badge

/// A pill badge for a `TutorialProgress.LearnState`: a colored glyph + caption on
/// a tinted background. Crucially, color is NOT the only signal — the glyph and
/// the text caption both encode the state, so it survives color blindness and
/// reads as an accessibility static-text element.
final class TutorialStatusBadge: NSView {
    let state: TutorialProgress.LearnState
    private let glyphLabel: NSTextField
    private let captionLabel: NSTextField

    /// - Parameter state: the learn state to display.
    init(state: TutorialProgress.LearnState) {
        self.state = state
        glyphLabel = TutorialComponents.label(state.glyph, font: TutorialTheme.Font.captionEmphasis)
        captionLabel = TutorialComponents.label(state.caption, font: TutorialTheme.Font.caption)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = TutorialTheme.Radius.badge

        let stack = NSStackView(views: [glyphLabel, captionLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = TutorialTheme.Spacing.xxs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let hPad = TutorialTheme.Spacing.xs, vPad = TutorialTheme.Spacing.xxs - 1
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: vPad),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vPad),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(state.caption)
        applyStyle()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            let color = TutorialTheme.statusColor(for: state)
            layer?.backgroundColor = TutorialTheme.statusFill(for: state).cgColor
            glyphLabel.textColor = color
            captionLabel.textColor = color
        }
    }
}

// MARK: - Keybinding row

/// One reference row: a label on the left, the keycaps in the middle, and an
/// optional status badge on the right. The coordinator stacks several of these
/// in a card to document a group of shortcuts.
final class TutorialKeybindingRow: NSView {
    let action: KeyAction?
    private let labelField: NSTextField
    let keycapRow: TutorialKeycapRow
    let badge: TutorialStatusBadge?

    /// - Parameters:
    ///   - label: the human label (e.g. "Focus right").
    ///   - caps: the keycap symbols (e.g. `ChordFormatter.keycaps(config, action)`).
    ///   - fallback: fallback chord text if `caps` is empty.
    ///   - state: optional learn state; when present a badge is shown on the right.
    ///   - action: optional `KeyAction` this row documents (for the caller's bookkeeping).
    init(label: String,
         caps: [String],
         fallback: String = "",
         state: TutorialProgress.LearnState? = nil,
         action: KeyAction? = nil) {
        self.action = action
        labelField = TutorialComponents.label(label, font: TutorialTheme.Font.body,
                                              color: TutorialTheme.Palette.textPrimary)
        keycapRow = TutorialKeycapRow(caps: caps, fallback: fallback)
        badge = state.map { TutorialStatusBadge(state: $0) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        labelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelField.lineBreakMode = .byTruncatingTail

        addSubview(labelField)
        addSubview(keycapRow)
        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
            topAnchor.constraint(lessThanOrEqualTo: labelField.topAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: labelField.bottomAnchor),
            keycapRow.centerYAnchor.constraint(equalTo: centerYAnchor),
            keycapRow.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            keycapRow.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        if let badge {
            addSubview(badge)
            NSLayoutConstraint.activate([
                keycapRow.leadingAnchor.constraint(greaterThanOrEqualTo: labelField.trailingAnchor,
                                                   constant: TutorialTheme.Spacing.md),
                badge.leadingAnchor.constraint(greaterThanOrEqualTo: keycapRow.trailingAnchor,
                                               constant: TutorialTheme.Spacing.sm),
                badge.trailingAnchor.constraint(equalTo: trailingAnchor),
                badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                keycapRow.leadingAnchor.constraint(greaterThanOrEqualTo: labelField.trailingAnchor,
                                                   constant: TutorialTheme.Spacing.md),
                keycapRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        // A comfortable minimum row height.
        heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
    }

    /// Convenience: build a row straight from config + action, with an optional
    /// learn state, using `ChordFormatter` + `KeyAction.displayName`.
    convenience init(config: ScrollWMConfig,
                     action: KeyAction,
                     state: TutorialProgress.LearnState? = nil) {
        self.init(label: action.displayName,
                  caps: ChordFormatter.keycaps(config, action),
                  fallback: ChordFormatter.chordText(config, action),
                  state: state,
                  action: action)
    }

    required init?(coder: NSCoder) { nil }
}

// MARK: - Segmented page selector

/// A themed segmented control the coordinator can use as the page selector.
/// Custom-drawn (not `NSSegmentedControl`) so it matches the tutorial theme: a
/// recessed track with an accent "pill" sliding under the selected title.
/// Reports selection through `onSelect`.
final class TutorialSegmentedSelector: NSView {
    /// Called with the newly-selected index when the user clicks a segment.
    var onSelect: ((Int) -> Void)?

    private(set) var selectedIndex: Int
    private let titles: [String]
    private var buttons: [NSButton] = []
    private let pill = NSView()
    private let stack = NSStackView()
    private var pillConstraints: [NSLayoutConstraint] = []

    /// - Parameters:
    ///   - titles: the segment titles, left to right.
    ///   - selectedIndex: the initially-selected index (clamped to range).
    init(titles: [String], selectedIndex: Int = 0) {
        self.titles = titles
        self.selectedIndex = titles.isEmpty ? 0 : min(max(selectedIndex, 0), titles.count - 1)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = TutorialTheme.Radius.control

        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = TutorialTheme.Radius.control - 2
        addSubview(pill)

        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let inset: CGFloat = 3
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            heightAnchor.constraint(equalToConstant: 32),
        ])

        for (i, title) in titles.enumerated() {
            let b = NSButton(title: title, target: self, action: #selector(segmentClicked(_:)))
            b.tag = i
            b.isBordered = false
            b.bezelStyle = .inline
            b.font = TutorialTheme.Font.bodyEmphasis
            b.setButtonType(.momentaryChange)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.contentTintColor = TutorialTheme.Palette.textSecondary
            buttons.append(b)
            stack.addArrangedSubview(b)
        }
        applyStyle()
        updateSelectionAppearance()
    }

    required init?(coder: NSCoder) { nil }

    /// Programmatically select an index (does NOT fire `onSelect`).
    func select(_ index: Int) {
        guard !titles.isEmpty else { return }
        selectedIndex = min(max(index, 0), titles.count - 1)
        updateSelectionAppearance()
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        guard sender.tag != selectedIndex else { return }
        selectedIndex = sender.tag
        updateSelectionAppearance()
        onSelect?(selectedIndex)
    }

    private func updateSelectionAppearance() {
        guard selectedIndex < buttons.count else { pill.isHidden = true; return }
        pill.isHidden = false
        let target = buttons[selectedIndex]
        NSLayoutConstraint.deactivate(pillConstraints)
        pillConstraints = [
            pill.leadingAnchor.constraint(equalTo: target.leadingAnchor, constant: 2),
            pill.trailingAnchor.constraint(equalTo: target.trailingAnchor, constant: -2),
            pill.topAnchor.constraint(equalTo: stack.topAnchor),
            pill.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
        ]
        NSLayoutConstraint.activate(pillConstraints)
        for (i, b) in buttons.enumerated() {
            b.contentTintColor = (i == selectedIndex)
                ? TutorialTheme.Palette.textPrimary
                : TutorialTheme.Palette.textSecondary
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = TutorialTheme.Palette.inset.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = TutorialTheme.Palette.border.cgColor
            pill.layer?.backgroundColor = TutorialTheme.Palette.cardSurface.cgColor
            pill.layer?.borderWidth = 1
            pill.layer?.borderColor = TutorialTheme.Palette.border.cgColor
            // Subtle lift on the selected pill.
            pill.layer?.shadowColor = TutorialTheme.Palette.shadow.cgColor
            pill.layer?.shadowOpacity = 1
            pill.layer?.shadowRadius = 2
            pill.layer?.shadowOffset = CGSize(width: 0, height: -1)
            updateSelectionAppearance()
        }
    }
}
