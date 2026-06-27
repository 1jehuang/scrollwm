import Foundation
import AppKit
import QuartzCore

/// The interactive "Practice the keys" page.
///
/// Reactive drill view built on top of the pure `TutorialPractice` state
/// machine. It shows the current challenge ("Try Focus →") with big keycaps and
/// a "press it now" hint, a progress bar, and animates a green success flash
/// (advance) or an orange shake (miss). When the whole drill is finished it
/// shows a celebratory completion card with a "Practice again" button.
///
/// IMPORTANT — this view NEVER registers a real event tap. The app's existing
/// keyboard tap (`KeyboardEventTap` in `ScrollWMApp`) owns key capture; the
/// coordinator forwards observed presses here via `deliver(chord:)` ONLY while
/// this page is visible and `isCapturing` is true. The view tells the
/// coordinator when to start/stop forwarding through `onCaptureChange`.
///
/// Coordinator usage:
///   let practice = TutorialPracticeView(config: configProvider())
///   practice.onCaptureChange = { capturing in app.setPracticeCapture(capturing) }
///   // when the practice page becomes visible:  practice.start()
///   // when it is hidden / window closes:        practice.stop()
///   // from the key tap, while practice.isCapturing:
///   //     practice.deliver(chord: chordString)   // any spelling; tolerant match
final class TutorialPracticeView: NSView {

    // MARK: - Public API (coordinator-facing)

    /// Whether the view currently wants real key presses forwarded to it. The
    /// coordinator should only call `deliver(chord:)` while this is `true`, and
    /// should gate its key-tap forwarding on it. Toggled by `start()`/`stop()`.
    private(set) var isCapturing: Bool = false {
        didSet { if oldValue != isCapturing { onCaptureChange?(isCapturing) } }
    }

    /// Fired whenever `isCapturing` flips. The coordinator wires this to begin /
    /// end forwarding key presses from the app's keyboard tap. Set this BEFORE
    /// calling `start()` if you want the initial enable to be observed.
    var onCaptureChange: ((Bool) -> Void)?

    /// Begin capturing: the coordinator should now forward observed chords to
    /// `deliver(chord:)`. Idempotent. Call when the practice page shows.
    func start() {
        isCapturing = true
        render(animated: false)
    }

    /// Stop capturing: the coordinator should stop forwarding chords. Idempotent.
    /// Call when the practice page hides or the window closes.
    func stop() {
        isCapturing = false
    }

    /// Feed a detected chord into the drill. Accepts any chord spelling
    /// (`"cmd+l"`, `"⌘L"`, `"shift+cmd+l"`); matching is tolerant. No-op (returns
    /// without advancing) while not capturing, so a stray forward can't corrupt
    /// progress. Animates the reaction and advances the prompt.
    @discardableResult
    func deliver(chord: String) -> TutorialPractice.Outcome? {
        guard isCapturing else { return nil }
        let outcome = practice.handle(chord: chord)
        react(to: outcome)
        return outcome
    }

    /// Rebuild from a fresh config (e.g. after a live config reload) and reset
    /// progress. Safe to call any time.
    func reload(config: ScrollWMConfig) {
        practice = TutorialPractice(config: config)
        render(animated: false)
    }

    /// Restart the drill from the first challenge.
    func resetDrill() {
        practice.reset()
        render(animated: true)
    }

    /// Read-only snapshot of drill progress for the coordinator / tests.
    var fraction: Double { practice.fraction }
    var headlineText: String { practice.headline }
    var isComplete: Bool { practice.isComplete }

    // MARK: - State

    private var practice: TutorialPractice

    // MARK: - Subviews

    private let promptLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let keycapRow = NSStackView()
    private let reactionLabel = NSTextField(labelWithString: "")
    private let headline = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let againButton = NSButton()
    private let column = NSStackView()

    // MARK: - Init

    /// Build the practice view from the live config. The drill order + accepted
    /// chords come straight from `TutorialPractice(config:)`.
    init(config: ScrollWMConfig) {
        self.practice = TutorialPractice(config: config)
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 360))
        translatesAutoresizingMaskIntoConstraints = false
        build()
        render(animated: false)
    }

    /// Test-friendly initializer that takes a prebuilt state machine (so tests
    /// can drive edge cases like an empty drill through the real view).
    init(practice: TutorialPractice) {
        self.practice = practice
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 360))
        translatesAutoresizingMaskIntoConstraints = false
        build()
        render(animated: false)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Layout

    private func build() {
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 16
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
        ])

        promptLabel.font = .systemFont(ofSize: 20, weight: .bold)
        promptLabel.alignment = .center

        keycapRow.orientation = .horizontal
        keycapRow.alignment = .centerY
        keycapRow.spacing = 8

        hintLabel.font = .systemFont(ofSize: 13, weight: .regular)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center

        reactionLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        reactionLabel.alignment = .center
        reactionLabel.stringValue = " "

        headline.font = .systemFont(ofSize: 13, weight: .medium)
        headline.textColor = .secondaryLabelColor
        headline.alignment = .center

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .regular
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 260).isActive = true

        againButton.title = "Practice again"
        againButton.bezelStyle = .rounded
        againButton.target = self
        againButton.action = #selector(againTapped)

        column.addArrangedSubview(promptLabel)
        column.addArrangedSubview(keycapRow)
        column.addArrangedSubview(hintLabel)
        column.addArrangedSubview(reactionLabel)
        column.addArrangedSubview(progress)
        column.addArrangedSubview(headline)
        column.addArrangedSubview(againButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("ScrollWM keyboard practice")
    }

    /// Rebuild the keycap row to show the current challenge's primary chord.
    private func rebuildKeycaps(_ caps: [String], fallback: String) {
        keycapRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let symbols = caps.isEmpty ? (fallback.isEmpty ? [] : [fallback]) : caps
        for sym in symbols {
            keycapRow.addArrangedSubview(KeycapView(symbol: sym))
        }
        keycapRow.isHidden = symbols.isEmpty
    }

    /// Reflect the current state-machine state into the UI.
    private func render(animated: Bool) {
        progress.doubleValue = practice.fraction
        headline.stringValue = practice.headline

        if let challenge = practice.current {
            promptLabel.stringValue = challenge.prompt
            rebuildKeycaps(challenge.keycaps, fallback: challenge.prettyChord)
            hintLabel.stringValue = isCapturing
                ? "Press it now — \(challenge.prettyChord)"
                : "Press “Practice” to start, then hit \(challenge.prettyChord)"
            hintLabel.isHidden = false
            againButton.isHidden = true
            setAccessibilityValueDescription("\(challenge.prompt): \(challenge.prettyChord)")
        } else {
            // Finished (or empty) drill: celebratory / informational card.
            promptLabel.stringValue = practice.challenges.isEmpty ? "Nothing to practice" : "Nice work! 🎉"
            rebuildKeycaps([], fallback: "")
            hintLabel.stringValue = practice.challenges.isEmpty
                ? "No core shortcuts are bound in your config."
                : "You ran every core shortcut. Practice again to keep it sharp."
            hintLabel.isHidden = false
            againButton.isHidden = practice.challenges.isEmpty
            setAccessibilityValueDescription(practice.headline)
        }

        if animated { pulse(promptLabel) }
    }

    // MARK: - Reactions

    private func react(to outcome: TutorialPractice.Outcome) {
        switch outcome {
        case .advanced:
            flashReaction("✓ Yes!", color: .systemGreen)
            render(animated: true)
        case .complete:
            flashReaction("✓ Complete!", color: .systemGreen)
            render(animated: true)
        case .repeatedWrong:
            flashReaction("✗ Not quite — try again", color: .systemOrange)
            shake(keycapRow)
        }
    }

    private func flashReaction(_ text: String, color: NSColor) {
        reactionLabel.stringValue = text
        reactionLabel.textColor = color
        pulse(reactionLabel)
    }

    /// Subtle scale pulse via layer transform. Guarded for offscreen / no-layer
    /// contexts so a smoke test never crashes.
    private func pulse(_ view: NSView) {
        guard respectsMotion else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: "pulse")
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 0.85
        anim.toValue = 1.0
        anim.duration = 0.22
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "pulse")
    }

    /// Horizontal shake to signal a wrong key.
    private func shake(_ view: NSView) {
        guard respectsMotion else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: "shake")
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0, -7, 7, -5, 5, -2, 0]
        anim.duration = 0.32
        layer.add(anim, forKey: "shake")
    }

    /// Honour the system "reduce motion" setting; also false in headless smoke
    /// tests where there is no real run loop to drive Core Animation.
    private var respectsMotion: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @objc private func againTapped() { resetDrill() }
}
