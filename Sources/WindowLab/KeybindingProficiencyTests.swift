import Foundation

/// Pure-logic tests for `KeybindingProficiency` — the model that detects when a
/// user has LEARNED, is still LEARNING, or has UNLEARNED a core keybinding. No
/// disk, AppKit, AX, or wall clock (timestamps are injected), so it runs in CI
/// alongside the other `unittest` lanes.
///
/// The properties we prove:
///   - cold start reads `.unknown` until `minSamples`;
///   - sustained keyboard use reaches `.proficient` and pins the peak;
///   - a mastered action that drifts to the pointer goes `.rusty` then
///     `.unlearned` (this is the whole point of the feature);
///   - `regressionScore` is zero unless mastered-then-slipped, and grows with
///     the slip, so it ranks the rustiest bindings;
///   - the `SkillTracker` shell fires a `Regression` exactly once per worsening
///     transition and round-trips its history through disk.
enum KeybindingProficiencyTests {

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func at(_ secs: Double) -> Date { t0.addingTimeInterval(secs) }

        // Fold a channel sequence into a fresh record.
        func fold(_ channels: [SkillChannel]) -> ActionSkill {
            var s = ActionSkill.empty
            for (i, c) in channels.enumerated() {
                s = KeybindingProficiency.updated(s, channel: c, at: at(Double(i)))
            }
            return s
        }
        let kb = SkillChannel.keyboard
        let pt = SkillChannel.pointer

        // MARK: - Cold start / sample floor

        check("empty record is .unknown",
              KeybindingProficiency.assess(.empty) == .unknown)
        check("below minSamples stays .unknown",
              KeybindingProficiency.assess(fold([kb, kb, kb])) == .unknown)

        // MARK: - Learning -> proficient

        let learned = fold(Array(repeating: kb, count: 8))
        check("sustained keyboard use is .proficient",
              KeybindingProficiency.assess(learned) == .proficient)
        check("proficient peak is high",
              learned.peakKeyboardEwma >= KeybindingProficiency.proficientThreshold)

        // A user who only ever clicks the menu is "learning" (never mastered),
        // NOT "unlearned" — you can't unlearn what you never knew.
        let neverLearned = fold(Array(repeating: pt, count: 8))
        check("menu-only user is .learning (never mastered)",
              KeybindingProficiency.assess(neverLearned) == .learning)
        check("menu-only regression score is 0 (never mastered)",
              KeybindingProficiency.regressionScore(neverLearned) == 0)

        // MARK: - The core signal: master, then revert to the pointer

        // Master it (lots of keyboard), then switch to clicking the menu.
        var slipping = fold(Array(repeating: kb, count: 10))
        check("mastered before slip", KeybindingProficiency.assess(slipping) == .proficient)
        let peak = slipping.peakKeyboardEwma

        // A couple of menu clicks: rusty (dropped off the peak, not yet gone).
        slipping = KeybindingProficiency.updated(slipping, channel: pt, at: at(20))
        slipping = KeybindingProficiency.updated(slipping, channel: pt, at: at(21))
        check("master + a few menu clicks -> .rusty",
              KeybindingProficiency.assess(slipping) == .rusty)
        check("peak is retained across the slip",
              abs(slipping.peakKeyboardEwma - peak) < 1e-9)
        check("regression score grows with the slip",
              KeybindingProficiency.regressionScore(slipping) > 0)

        // Keep clicking the menu: the keybinding is effectively unlearned.
        for i in 0..<10 {
            slipping = KeybindingProficiency.updated(slipping, channel: pt, at: at(30 + Double(i)))
        }
        check("master + sustained menu use -> .unlearned",
              KeybindingProficiency.assess(slipping) == .unlearned)
        check("unlearned score is larger than rusty score",
              KeybindingProficiency.regressionScore(slipping)
                  >= KeybindingProficiency.rustyDrop)

        // MARK: - Recovery: pick the keybinding back up

        var recovering = slipping
        for i in 0..<12 {
            recovering = KeybindingProficiency.updated(recovering, channel: kb, at: at(60 + Double(i)))
        }
        check("re-learning a keybinding returns to .proficient",
              KeybindingProficiency.assess(recovering) == .proficient)

        // MARK: - regressionRank monotonicity (drives "nudge only on worsening")

        check("rank proficient < rusty < unlearned",
              KeybindingProficiency.Level.proficient.regressionRank
                  < KeybindingProficiency.Level.rusty.regressionRank
              && KeybindingProficiency.Level.rusty.regressionRank
                  < KeybindingProficiency.Level.unlearned.regressionRank)
        check("good levels are not flagged regressed",
              !KeybindingProficiency.Level.proficient.isRegressed
              && !KeybindingProficiency.Level.learning.isRegressed
              && !KeybindingProficiency.Level.unknown.isRegressed)
        check("rusty + unlearned are flagged regressed",
              KeybindingProficiency.Level.rusty.isRegressed
              && KeybindingProficiency.Level.unlearned.isRegressed)

        // MARK: - SkillTracker shell: fires once per worsening, persists

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrollwm-skilltest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var clock = at(0)
        let tracker = SkillTracker(fileURL: tmp, now: { clock })

        // Master the close-window keybinding by keyboard.
        var regressions: [SkillTracker.Regression] = []
        for i in 0..<10 {
            clock = at(Double(i))
            if let r = tracker.record(.closeWindow, channel: .keyboard) { regressions.append(r) }
        }
        check("no regression while mastering", regressions.isEmpty)
        check("tracker reports .proficient after mastering",
              tracker.level(.closeWindow) == .proficient)

        // Now revert to the menu. Expect a worsening transition to fire.
        var nudges = 0
        var firstNudge: SkillTracker.Regression?
        for i in 0..<14 {
            clock = at(Double(20 + i))
            if let r = tracker.record(.closeWindow, channel: .pointer) {
                nudges += 1
                if firstNudge == nil { firstNudge = r }
            }
        }
        check("reverting to the menu fires at least one regression nudge", nudges >= 1)
        // It should fire on a worsening step, not on every click of a steady
        // bad state: proficient->rusty and rusty->unlearned are the only two
        // possible worsenings, so at most 2 nudges across the whole revert.
        check("nudges fire only on worsening transitions (<= 2)", nudges <= 2)
        check("first nudge names the right action", firstNudge?.action == .closeWindow)
        check("tracker ends .unlearned for the reverted action",
              tracker.level(.closeWindow) == .unlearned)
        check("regressedActions lists the unlearned binding",
              tracker.regressedActions().contains { $0.action == .closeWindow })

        // Persistence round-trip: a fresh tracker over the same file sees it.
        tracker.flush()
        let reloaded = SkillTracker(fileURL: tmp, now: { clock })
        check("history survives a reload (still .unlearned)",
              reloaded.level(.closeWindow) == .unlearned)

        // A steady good action never appears in the regressed list.
        check("never-regressed action absent from regressedActions",
              !tracker.regressedActions().contains { $0.action == .focusNext })

        print("\n[unittest] keybinding proficiency: \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
