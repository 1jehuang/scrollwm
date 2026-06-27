import Foundation
import CoreGraphics

/// Pure, AppKit-free state machine driving the tutorial's interactive "Practice
/// the keys" drill.
///
/// The practice page walks the user through ONE challenge per core `KeyAction`
/// (`KeyAction.coreActions`): it shows a prompt ("Try Focus → : ⌘L"), waits for
/// the user to physically press that chord, celebrates, and advances. All of
/// the decision logic lives here so it can be unit-tested without building an
/// `NSView` or touching the keyboard — the view (`TutorialPracticeView`) is a
/// thin reactive shell that feeds delivered chords into `handle(chord:)`.
///
/// Matching is **tolerant**: a delivered chord is normalised with the same
/// tokenizer the rest of the tutorial uses (`ChordFormatter.tokenize`), so
/// modifier order does not matter (`⌘⇧L` == `shift+cmd+l`) and every spelling
/// of a modifier (`cmd`/`command`/`⌘`) collapses to one canonical form. That
/// lets the app forward a chord in whatever shape is convenient (raw config
/// string, glyph string, or one rebuilt from a key event) and still match.
struct TutorialPractice {

    /// A chord reduced to a comparison key: the *set* of modifier glyphs (order
    /// independent) plus the single non-modifier key symbol. Two chords are the
    /// same challenge-press iff their `NormalizedChord`s are equal.
    struct NormalizedChord: Hashable {
        /// Modifier glyphs present, e.g. `["⌘", "⇧"]`. A set, so order and
        /// spelling never matter.
        let modifiers: Set<String>
        /// The single non-modifier key, rendered through `ChordFormatter`
        /// (`"l"` -> `"L"`, `"left"` -> `"←"`, `"return"` -> `"↩"`).
        let key: String
    }

    /// One drill: the action being taught, its human label, the accepted chord
    /// strings (the live config bindings, falling back to defaults), the keycaps
    /// to render for the primary binding, and the precomputed accept set.
    struct Challenge: Equatable {
        let action: KeyAction
        /// Short human label (e.g. "Focus →"), from `KeyAction.displayName`.
        let label: String
        /// The raw chord strings that satisfy this challenge (e.g. `["cmd+l"]`).
        let chords: [String]
        /// Keycap symbols for the PRIMARY chord, e.g. `["⌘", "L"]`, for the view.
        let keycaps: [String]
        /// Pretty, display-ready accepted chord(s), e.g. `"⌘L"`.
        let prettyChord: String
        /// Precomputed normalised accept set (so `matches` is O(1) and pure).
        let accepts: Set<NormalizedChord>

        /// The instruction line the view shows, e.g. "Try Focus →".
        var prompt: String { "Try \(label)" }

        static func == (lhs: Challenge, rhs: Challenge) -> Bool {
            lhs.action == rhs.action && lhs.chords == rhs.chords
        }

        func matches(_ pressed: NormalizedChord) -> Bool { accepts.contains(pressed) }
    }

    /// The result of feeding a chord to `handle(chord:)`.
    enum Outcome: Equatable {
        /// Correct chord; moved on to the next challenge (more remain).
        case advanced
        /// Wrong chord (or an unmatchable press); a miss, no advance.
        case repeatedWrong
        /// Correct chord on the LAST challenge (or already finished): all done.
        case complete
    }

    /// The ordered challenges (one per core action that has a usable binding).
    let challenges: [Challenge]
    /// Index of the active challenge; equals `challenges.count` when finished.
    private(set) var index: Int = 0
    /// Per-challenge completion flags, parallel to `challenges`.
    private(set) var done: [Bool]
    /// Per-challenge press counts (correct + wrong), parallel to `challenges`.
    private(set) var attempts: [Int]

    // MARK: - Construction

    /// Build the drill from the live config. Generates one challenge per
    /// `KeyAction.coreActions` that has at least one parseable chord (an action
    /// explicitly unbound to nothing is skipped, so every challenge is always
    /// completable). Pure: depends only on `config`.
    init(config: ScrollWMConfig) {
        self.init(challenges: TutorialPractice.challenges(config: config))
    }

    /// Direct initializer (used by tests for edge cases like an empty drill).
    init(challenges: [Challenge]) {
        self.challenges = challenges
        self.done = Array(repeating: false, count: challenges.count)
        self.attempts = Array(repeating: 0, count: challenges.count)
    }

    /// Generate the challenge list from config. Exposed (static, pure) so the
    /// view and tests share exactly one ordering.
    static func challenges(config: ScrollWMConfig) -> [Challenge] {
        KeyAction.coreActions.compactMap { action in
            // Prefer the user's binding; fall back to the built-in default; an
            // explicitly-empty binding is treated as "use default" so a cleared
            // entry never produces an unbeatable challenge.
            let configured = config.keybindings[action] ?? []
            let chords = configured.isEmpty ? (KeyAction.defaultChords[action] ?? []) : configured
            // Keep only chords that normalise to a real key press.
            let usable = chords.filter { normalize($0) != nil }
            guard let primary = usable.first else { return nil }
            let accepts = Set(usable.compactMap(normalize))
            return Challenge(
                action: action,
                label: action.displayName,
                chords: usable,
                keycaps: ChordFormatter.keycaps(primary),
                prettyChord: usable.map(ChordFormatter.pretty).joined(separator: " or "),
                accepts: accepts
            )
        }
    }

    // MARK: - Derived state

    var isComplete: Bool { index >= challenges.count }
    /// The active challenge, or `nil` when finished / empty.
    var current: Challenge? { challenges.indices.contains(index) ? challenges[index] : nil }
    /// Number of challenges marked done.
    var doneCount: Int { done.lazy.filter { $0 }.count }
    /// Completion fraction in `0...1`. An empty drill is vacuously complete (1).
    var fraction: Double {
        challenges.isEmpty ? 1.0 : Double(doneCount) / Double(challenges.count)
    }
    /// Total presses delivered across all challenges.
    var totalAttempts: Int { attempts.reduce(0, +) }

    /// A rolled-up status line for the progress indicator.
    var headline: String {
        if challenges.isEmpty { return "No shortcuts configured to practice." }
        if isComplete { return "All \(challenges.count) shortcuts practiced! 🎉" }
        return "\(doneCount) of \(challenges.count) practiced"
    }

    // MARK: - Transition

    /// Feed a delivered chord string. Pure (mutates `self`, returns the outcome).
    /// A correct chord advances (or completes); anything else is a miss that
    /// records an attempt but does not advance. Once complete it stays complete.
    @discardableResult
    mutating func handle(chord: String) -> Outcome {
        guard !isComplete else { return .complete }
        attempts[index] += 1
        let target = challenges[index]
        if let pressed = TutorialPractice.normalize(chord), target.matches(pressed) {
            done[index] = true
            index += 1
            return isComplete ? .complete : .advanced
        }
        return .repeatedWrong
    }

    /// Restart the drill from the first challenge, clearing progress.
    mutating func reset() {
        index = 0
        done = Array(repeating: false, count: challenges.count)
        attempts = Array(repeating: 0, count: challenges.count)
    }

    // MARK: - Normalisation (pure, shared)

    /// Reduce a chord string to a `NormalizedChord` for tolerant comparison, or
    /// `nil` when it has no usable non-modifier key (empty / modifier-only /
    /// malformed). Reuses `ChordFormatter` tokenisation so it matches every
    /// chord spelling the rest of the app accepts.
    static func normalize(_ chord: String) -> NormalizedChord? {
        let tokens = ChordFormatter.tokenize(chord)
        guard !tokens.isEmpty else { return nil }
        var modifiers = Set<String>()
        var key: String? = nil
        for token in tokens {
            if let glyph = ChordFormatter.modifierSymbols[token] {
                modifiers.insert(glyph)
            } else {
                // First non-modifier token wins; a second one means a malformed
                // chord, which we reject (real key events only carry one key).
                if key != nil { return nil }
                key = ChordFormatter.symbol(for: token)
            }
        }
        guard let key, !key.isEmpty else { return nil }
        return NormalizedChord(modifiers: modifiers, key: key)
    }

    // MARK: - Key-event → chord string (for the app-side wiring)

    /// Build a config-style chord string (e.g. `"ctrl+opt+cmd+l"`) from a raw
    /// keyboard event's keycode + CGEvent modifier flags. The coordinator's key
    /// tap can call this to turn a physical press into a chord it forwards to
    /// `TutorialPracticeView.deliver(chord:)`. Returns `nil` for an unmapped
    /// keycode. Pure: a deterministic reverse of `Chord.keyCodes`.
    static func chordString(keyCode: UInt32, flags: CGEventFlags) -> String? {
        guard let key = keyName(for: keyCode) else { return nil }
        var parts: [String] = []
        if flags.contains(.maskControl)   { parts.append("ctrl") }
        if flags.contains(.maskAlternate) { parts.append("opt") }
        if flags.contains(.maskShift)     { parts.append("shift") }
        if flags.contains(.maskCommand)   { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// The canonical config name for a virtual keycode (deterministic reverse of
    /// `Chord.keyCodes`; ties resolved by the lexicographically-first name, which
    /// is irrelevant to matching since aliases normalise identically).
    static func keyName(for keyCode: UInt32) -> String? { keyNameByCode[keyCode] }

    private static let keyNameByCode: [UInt32: String] = {
        var map: [UInt32: String] = [:]
        for (name, code) in Chord.keyCodes.sorted(by: { $0.key < $1.key }) where map[code] == nil {
            map[code] = name
        }
        return map
    }()
}
