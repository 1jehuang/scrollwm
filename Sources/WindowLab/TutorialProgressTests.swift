import Foundation

/// Pure-logic tests for `TutorialProgress` — the model behind the tutorial's
/// "core shortcuts you've learned vs not learned" panel — plus the keycap
/// splitter `ChordFormatter.keycaps`. No AppKit (the window shell owns that), so
/// this runs headless in CI alongside the other `unittest` lanes.
enum TutorialProgressTests {

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        // MARK: - keycaps splitter

        check("keycaps splits cmd+shift+h into ⌘ ⇧ H",
              ChordFormatter.keycaps("cmd+shift+h") == ["⌘", "⇧", "H"])
        check("keycaps splits ctrl+opt+left into ⌃ ⌥ ←",
              ChordFormatter.keycaps("ctrl+opt+left") == ["⌃", "⌥", "←"])
        check("keycaps single key", ChordFormatter.keycaps("q") == ["Q"])
        check("keycaps modifier-only ctrl+opt", ChordFormatter.keycaps("ctrl+opt") == ["⌃", "⌥"])
        check("keycaps empty is empty", ChordFormatter.keycaps("") == [])
        check("keycaps return glyph", ChordFormatter.keycaps("cmd+return") == ["⌘", "↩"])
        // Joining the caps reproduces pretty() (the two stay consistent).
        for chord in ["cmd+shift+h", "cmd+l", "opt+1", "ctrl+opt+escape", "cmd+return"] {
            check("keycaps join == pretty (\(chord))",
                  ChordFormatter.keycaps(chord).joined() == ChordFormatter.pretty(chord))
        }
        // Config overload reads the first chord (default config).
        let dflt = ScrollWMConfig.default
        check("keycaps(config, focusLeft) == ⌘ H",
              ChordFormatter.keycaps(dflt, .focusLeft) == ["⌘", "H"])
        check("keycaps(config, moveColumnRight) == ⌘ ⇧ L",
              ChordFormatter.keycaps(dflt, .moveColumnRight) == ["⌘", "⇧", "L"])

        // MARK: - level -> learn-state mapping

        typealias TP = TutorialProgress
        check("proficient -> learned", TP.state(for: .proficient) == .learned)
        check("rusty -> rusty", TP.state(for: .rusty) == .rusty)
        check("unlearned -> rusty", TP.state(for: .unlearned) == .rusty)
        check("learning -> learning", TP.state(for: .learning) == .learning)
        check("unknown -> notStarted", TP.state(for: .unknown) == .notStarted)
        check("only learned counts as learned",
              TP.LearnState.learned.isLearned
              && !TP.LearnState.rusty.isLearned
              && !TP.LearnState.learning.isLearned
              && !TP.LearnState.notStarted.isLearned)
        // Captions + glyphs are non-empty for every state (totality).
        for s in [TP.LearnState.learned, .rusty, .learning, .notStarted] {
            check("state \(s) has caption + glyph", !s.caption.isEmpty && !s.glyph.isEmpty)
        }

        // MARK: - rows cover exactly the core set, in teaching order

        let emptyLevels: [KeyAction: KeybindingProficiency.Level] = [:]
        let rows = TP.rows(levels: emptyLevels)
        check("rows count == coreActions count", rows.count == KeyAction.coreActions.count)
        check("rows are the core actions in order",
              rows.map { $0.action } == KeyAction.coreActions)
        check("every core action is core", KeyAction.coreActions.allSatisfy { $0.isCore })
        check("a non-core action is not core", !KeyAction.width25.isCore && !KeyAction.toggleArrange.isCore)
        check("fresh user: all core rows are notStarted",
              rows.allSatisfy { $0.state == .notStarted })

        // MARK: - summary roll-up

        let s0 = TP.summary(levels: emptyLevels)
        check("fresh summary: 0 of N learned", s0.learned == 0 && s0.total == KeyAction.coreActions.count)
        check("fresh summary fraction is 0", s0.fraction == 0)
        check("fresh summary headline says 0 of N",
              s0.headline.contains("0 of \(KeyAction.coreActions.count)"))

        // Mark two core actions proficient, one rusty, one learning.
        var levels: [KeyAction: KeybindingProficiency.Level] = [:]
        levels[.focusLeft] = .proficient
        levels[.focusRight] = .proficient
        levels[.closeWindow] = .rusty
        levels[.workspaceDown] = .learning
        let s1 = TP.summary(levels: levels)
        check("two proficient -> learned == 2", s1.learned == 2)
        check("rusty/learning do not count as learned", s1.learned == 2)
        check("partial fraction is 2/total",
              abs(s1.fraction - 2.0 / Double(KeyAction.coreActions.count)) < 1e-9)

        // All core actions proficient -> "all learned".
        var allProf: [KeyAction: KeybindingProficiency.Level] = [:]
        for a in KeyAction.coreActions { allProf[a] = .proficient }
        let sAll = TP.summary(levels: allProf)
        check("all learned: learned == total", sAll.learned == sAll.total)
        check("all learned: fraction == 1", sAll.fraction == 1.0)
        check("all learned headline celebrates", sAll.headline.contains("all"))

        // Non-core proficiency never leaks into the core summary.
        var noiseLevels: [KeyAction: KeybindingProficiency.Level] = [:]
        for a in KeyAction.allCases where !a.isCore { noiseLevels[a] = .proficient }
        check("non-core proficiency contributes 0 learned",
              TP.summary(levels: noiseLevels).learned == 0)

        print("\n[unittest] tutorial progress: \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
