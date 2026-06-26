import Foundation

/// PURE keybinding-proficiency model: decides, from a per-action usage history,
/// whether the user has LEARNED a core keybinding, is still learning it, or has
/// "unlearned" it (mastered it once, then reverted to the menu/pointer for the
/// same action). No AppKit, AX, disk, or clock-of-its-own — every input is an
/// argument — so the whole policy is deterministic and unit-testable, the same
/// way `ResyncPlanner` / `UpdatePolicy` keep their decisions out of the I/O.
///
/// Why this is possible at all
/// ---------------------------
/// Every ScrollWM action can be invoked two ways: by its keybinding (the
/// "skilled" path) or by a pointer fallback — the menu-bar menu duplicates the
/// same verbs (Arrange/Release == the toggle key, "select column N" == the jump
/// key). So for each action we can watch the BALANCE between keyboard and
/// pointer invocations over time and notice when a previously keyboard-driven
/// action drifts back to the mouse.
///
/// The signal: an exponentially-weighted "keyboard fraction"
/// ---------------------------------------------------------
/// `keyboardEwma` is the recency-weighted fraction of invocations that used the
/// keyboard (1.0 = always the keybind, 0.0 = always the menu). It moves toward 1
/// on a keyboard use and toward 0 on a pointer use, so it tracks *recent* habit,
/// not lifetime totals. `peakKeyboardEwma` records the best level ever reached —
/// the high-water mark that proves the user once had the skill. "Unlearning" is
/// exactly: a high peak (they mastered it) plus a current EWMA that has fallen
/// well below that peak (they stopped using it).
enum KeybindingProficiency {

    // MARK: - Tunables (all pure constants so the policy is fully specified)

    /// EWMA smoothing. 0.3 means each invocation shifts the fraction ~30% toward
    /// its channel, so a habit forms (or decays) over a handful of uses rather
    /// than instantly or never. Reaching `proficientThreshold` from cold takes
    /// `minSamples` consecutive keyboard uses, by construction.
    static let alpha: Double = 0.3

    /// Minimum invocations (either channel) before we claim to know anything.
    /// Below this an action is `.unknown` so a single click never reads as a
    /// verdict.
    static let minSamples: Int = 4

    /// Keyboard fraction at/above which the user is driving the action by
    /// keybinding — "proficient".
    static let proficientThreshold: Double = 0.7

    /// Once mastered (peak >= `proficientThreshold`), a drop of at least this
    /// much below the peak (while also below `proficientThreshold`) means the
    /// user is sliding back to the pointer: "rusty".
    static let rustyDrop: Double = 0.3

    /// Once mastered, a current fraction below this means the keybinding is, in
    /// practice, gone — "unlearned".
    static let unlearnedEwma: Double = 0.25

    /// A regression score at/above which it's worth gently reminding the user of
    /// the keybinding they're no longer using.
    static let nudgeScore: Double = 0.3

    // MARK: - Levels

    /// How well the user currently wields one action's keybinding.
    enum Level: String, Equatable {
        /// Not enough data yet.
        case unknown
        /// Building the habit; keyboard not yet dominant, never mastered.
        case learning
        /// Driving it by keybinding (now, or still).
        case proficient
        /// Mastered it once, but recently drifting back to the pointer.
        case rusty
        /// Mastered it once, now effectively back on the pointer for it.
        case unlearned

        /// Ordered "badness" for regression, so we only nudge on a WORSENING
        /// transition (proficient -> rusty -> unlearned) and never spam while a
        /// level merely persists. Good levels share rank 0.
        var regressionRank: Int {
            switch self {
            case .unknown, .learning, .proficient: return 0
            case .rusty:     return 1
            case .unlearned: return 2
            }
        }

        /// True when the action's keybinding has measurably decayed.
        var isRegressed: Bool { self == .rusty || self == .unlearned }
    }

    // MARK: - Pure transitions

    /// Fold one invocation into a skill record. `channel` is how the user
    /// invoked the action this time; `now` timestamps it (caller supplies the
    /// clock). Returns a NEW record — the input is never mutated.
    static func updated(_ skill: ActionSkill, channel: SkillChannel, at now: Date) -> ActionSkill {
        var s = skill
        let target = (channel == .keyboard) ? 1.0 : 0.0
        s.keyboardEwma = alpha * target + (1 - alpha) * s.keyboardEwma
        s.peakKeyboardEwma = max(s.peakKeyboardEwma, s.keyboardEwma)
        switch channel {
        case .keyboard:
            s.keyboardCount += 1
            s.lastKeyboardAt = now
        case .pointer:
            s.pointerCount += 1
            s.lastPointerAt = now
        }
        return s
    }

    /// Classify a skill record. Pure: depends only on the record.
    static func assess(_ skill: ActionSkill) -> Level {
        let total = skill.keyboardCount + skill.pointerCount
        guard total >= minSamples else { return .unknown }
        let mastered = skill.peakKeyboardEwma >= proficientThreshold
        if mastered {
            if skill.keyboardEwma < unlearnedEwma { return .unlearned }
            if skill.keyboardEwma < proficientThreshold,
               (skill.peakKeyboardEwma - skill.keyboardEwma) >= rustyDrop {
                return .rusty
            }
            return .proficient
        }
        return skill.keyboardEwma >= proficientThreshold ? .proficient : .learning
    }

    /// How far an action's keyboard habit has fallen from its mastered peak,
    /// in [0, 1]. Zero unless the action was once mastered AND has slipped, so
    /// it ranks the "rustiest" bindings and decides whether to nudge.
    static func regressionScore(_ skill: ActionSkill) -> Double {
        guard skill.peakKeyboardEwma >= proficientThreshold else { return 0 }
        return max(0, skill.peakKeyboardEwma - skill.keyboardEwma)
    }
}

/// How a ScrollWM action was invoked one time.
enum SkillChannel: String, Equatable {
    /// The action's keybinding (the skilled path).
    case keyboard
    /// A pointer-driven fallback that duplicates the action (the menu).
    case pointer
}

/// Per-action usage history. Codable so it persists across launches (an
/// in-session-only counter would never observe a slow, weeks-long unlearning).
/// All fields are plain data; every decision over them lives in the pure
/// `KeybindingProficiency`.
struct ActionSkill: Codable, Equatable {
    var keyboardCount: Int = 0
    var pointerCount: Int = 0
    /// Recency-weighted fraction of invocations that used the keyboard, [0, 1].
    var keyboardEwma: Double = 0
    /// High-water mark of `keyboardEwma` — proof the skill was once held.
    var peakKeyboardEwma: Double = 0
    var lastKeyboardAt: Date? = nil
    var lastPointerAt: Date? = nil

    static let empty = ActionSkill()
}
