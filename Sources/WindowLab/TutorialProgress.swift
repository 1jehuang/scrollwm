import Foundation

/// PURE model for the tutorial's "keys you've learned vs not learned" panel.
///
/// The tutorial grades only the CORE keybindings (`KeyAction.coreActions`: the
/// vim-style navigation/move/workspace keys plus close-window and new-terminal).
/// It turns each action's `KeybindingProficiency.Level` — the same signal the
/// menu-bar nudge uses — into a glanceable learn state, and rolls the set up
/// into a "you've learned N of M core shortcuts" summary with a progress
/// fraction. No AppKit/disk/clock here (the caller supplies the per-action
/// levels), so the whole thing is unit-testable like `KeybindingProficiency`.
enum TutorialProgress {

    /// One core keybinding's status, as the tutorial presents it.
    enum LearnState: String, Equatable {
        /// Never driven by keyboard yet (proficiency `.unknown`): the user has
        /// not started learning this shortcut.
        case notStarted
        /// Building the habit (`.learning`): used sometimes, not yet dominant.
        case learning
        /// Mastered and still using it (`.proficient`): learned. ✓
        case learned
        /// Mastered once but slipping back to the menu (`.rusty`/`.unlearned`):
        /// a learned skill going stale — worth a refresher.
        case rusty

        /// True for the one state we count as "learned" in the summary.
        var isLearned: Bool { self == .learned }

        /// A small status glyph for the row (color is layered on in the view).
        var glyph: String {
            switch self {
            case .learned:    return "✓"
            case .rusty:      return "↻"
            case .learning:   return "…"
            case .notStarted: return "○"
            }
        }

        /// A terse caption shown beside the glyph.
        var caption: String {
            switch self {
            case .learned:    return "Learned"
            case .rusty:      return "Getting rusty"
            case .learning:   return "Learning"
            case .notStarted: return "Not learned yet"
            }
        }
    }

    /// Map a proficiency level to a tutorial learn state. The two regressed
    /// levels (`.rusty`/`.unlearned`) both collapse to `.rusty` because, in the
    /// tutorial, the actionable message is identical: "you knew this, give it a
    /// refresh."
    static func state(for level: KeybindingProficiency.Level) -> LearnState {
        switch level {
        case .proficient:           return .learned
        case .rusty, .unlearned:    return .rusty
        case .learning:             return .learning
        case .unknown:              return .notStarted
        }
    }

    /// One graded core action: which action, its current learn state.
    struct Row: Equatable {
        let action: KeyAction
        let state: LearnState
    }

    /// Build the graded rows for every core action, in teaching order
    /// (`KeyAction.coreActions`). `levels` supplies each action's proficiency
    /// (missing entries read as `.unknown`), so a fresh user with no history
    /// shows every core key as "not learned yet".
    static func rows(levels: [KeyAction: KeybindingProficiency.Level]) -> [Row] {
        KeyAction.coreActions.map { action in
            Row(action: action, state: state(for: levels[action] ?? .unknown))
        }
    }

    /// Rolled-up progress over the core set: how many are learned, the total,
    /// and the fraction in [0, 1]. Drives the tutorial's "N of M" headline and
    /// its progress bar.
    struct Summary: Equatable {
        let learned: Int
        let total: Int
        var fraction: Double { total > 0 ? Double(learned) / Double(total) : 0 }
        /// Human headline, e.g. "You've learned 3 of 10 core shortcuts".
        var headline: String {
            if total == 0 { return "No core shortcuts to learn" }
            if learned == total { return "You've learned all \(total) core shortcuts 🎉" }
            return "You've learned \(learned) of \(total) core shortcuts"
        }
    }

    /// Summarize the learn states of the core set.
    static func summary(levels: [KeyAction: KeybindingProficiency.Level]) -> Summary {
        let rows = rows(levels: levels)
        let learned = rows.filter { $0.state.isLearned }.count
        return Summary(learned: learned, total: rows.count)
    }
}
