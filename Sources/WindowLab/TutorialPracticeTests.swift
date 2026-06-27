import Foundation
import AppKit
import CoreGraphics

/// Tests for the interactive practice drill: the pure `TutorialPractice` state
/// machine (correct advances, wrong = miss, completion, reset, empty/edge
/// config, tolerant matching, key-event → chord) plus a small offscreen-render
/// smoke test of `TutorialPracticeView` (constructs, lays out, drives a full
/// deliver(chord:) sequence — must not crash).
///
/// Run with: `WindowLab practicetest` (wired into `unittest` by the coordinator).
enum TutorialPracticeTests {

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        let config = ScrollWMConfig.default

        // MARK: - Challenge generation

        var drill = TutorialPractice(config: config)
        check("one challenge per core action",
              drill.challenges.count == KeyAction.coreActions.count)
        check("challenge order matches coreActions",
              drill.challenges.map { $0.action } == KeyAction.coreActions)
        check("every challenge has accepted chords",
              drill.challenges.allSatisfy { !$0.chords.isEmpty && !$0.accepts.isEmpty })
        check("every challenge has a non-empty prompt + pretty chord",
              drill.challenges.allSatisfy { !$0.prompt.isEmpty && !$0.prettyChord.isEmpty })
        check("starts at index 0, nothing done", drill.index == 0 && drill.doneCount == 0)
        check("initial fraction is 0", drill.fraction == 0)
        check("current is first challenge", drill.current?.action == KeyAction.coreActions.first)

        // MARK: - Correct chord advances

        let first = drill.current!
        let firstChord = first.chords.first!     // e.g. "cmd+h" for focusLeft
        let out1 = drill.handle(chord: firstChord)
        check("correct chord advances", out1 == .advanced)
        check("index moved to 1", drill.index == 1)
        check("first marked done", drill.doneCount == 1)
        check("attempt recorded on first", drill.attempts[0] == 1)
        check("fraction reflects 1 done",
              abs(drill.fraction - 1.0 / Double(drill.challenges.count)) < 1e-9)

        // MARK: - Tolerant matching (modifier order + glyph spelling)

        var tol = TutorialPractice(config: config)
        // focusLeft default is "cmd+h"; the pretty glyph form must also match.
        check("glyph form matches", { var d = tol; return d.handle(chord: "⌘H") == .advanced }())
        // Reordered modifiers match: moveColumnLeft default "cmd+shift+h".
        if let moveIdx = tol.challenges.firstIndex(where: { $0.action == .moveColumnLeft }) {
            // Advance up to that challenge with its correct chords, then feed a
            // reordered-modifier spelling.
            for i in 0..<moveIdx { _ = tol.handle(chord: tol.challenges[i].chords.first!) }
            check("reordered modifiers match", tol.handle(chord: "shift+cmd+h") == .advanced)
        } else {
            check("moveColumnLeft present", false)
        }

        // MARK: - Wrong chord is a miss without advancing

        var miss = TutorialPractice(config: config)
        let beforeIdx = miss.index
        let outMiss = miss.handle(chord: "ctrl+opt+z")   // not bound to the first challenge
        check("wrong chord = repeatedWrong", outMiss == .repeatedWrong)
        check("wrong chord does not advance", miss.index == beforeIdx)
        check("wrong chord still records an attempt", miss.attempts[0] == 1)
        check("wrong chord leaves nothing done", miss.doneCount == 0)
        // Garbage / empty / modifier-only chords are misses, never crashes.
        check("empty chord = miss", miss.handle(chord: "") == .repeatedWrong)
        check("modifier-only chord = miss", miss.handle(chord: "cmd+shift") == .repeatedWrong)
        check("garbage chord = miss", miss.handle(chord: "+++") == .repeatedWrong)
        check("still at first after misses", miss.index == 0 && miss.attempts[0] == 4)

        // MARK: - Full completion

        var run = TutorialPractice(config: config)
        var outcomes: [TutorialPractice.Outcome] = []
        for c in run.challenges { outcomes.append(run.handle(chord: c.chords.first!)) }
        check("all but last advanced",
              outcomes.dropLast().allSatisfy { $0 == .advanced })
        check("last challenge completes", outcomes.last == .complete)
        check("isComplete after running all", run.isComplete)
        check("fraction is 1 when complete", run.fraction == 1.0)
        check("headline announces completion", run.headline.contains("practiced"))
        // Extra presses after completion are inert + stay complete.
        check("handle after complete stays complete", run.handle(chord: "cmd+h") == .complete)
        check("doneCount equals challenge count", run.doneCount == run.challenges.count)

        // MARK: - Reset

        run.reset()
        check("reset returns to index 0", run.index == 0)
        check("reset clears done", run.doneCount == 0)
        check("reset clears attempts", run.totalAttempts == 0)
        check("reset fraction back to 0", run.fraction == 0)
        check("reset re-enables progress", run.handle(chord: run.challenges.first!.chords.first!) == .advanced)

        // MARK: - Empty / edge config

        let empty = TutorialPractice(challenges: [])
        check("empty drill is complete", empty.isComplete)
        check("empty drill fraction is 1", empty.fraction == 1.0)
        check("empty drill has no current", empty.current == nil)
        check("empty headline mentions none", empty.headline.lowercased().contains("no"))
        var emptyMut = empty
        check("empty handle returns complete", emptyMut.handle(chord: "cmd+h") == .complete)

        // A config that clears a core binding to [] falls back to the default,
        // so the challenge count is unchanged (never an unbeatable challenge).
        var cleared = ScrollWMConfig.default
        cleared.keybindings[.focusLeft] = []
        let clearedDrill = TutorialPractice(config: cleared)
        check("cleared binding falls back to default (count unchanged)",
              clearedDrill.challenges.count == KeyAction.coreActions.count)
        check("cleared binding challenge still completable",
              clearedDrill.challenges.first(where: { $0.action == .focusLeft })
                .map { !$0.accepts.isEmpty } ?? false)

        // A custom override is honoured by the matcher.
        var custom = ScrollWMConfig.default
        custom.keybindings[.focusLeft] = ["ctrl+opt+a"]
        var customDrill = TutorialPractice(config: custom)
        check("custom binding rejects old default", customDrill.handle(chord: "cmd+h") == .repeatedWrong)
        check("custom binding accepts override", customDrill.handle(chord: "ctrl+opt+a") == .advanced)

        // MARK: - normalize() unit behaviour

        check("normalize is order-insensitive",
              TutorialPractice.normalize("cmd+shift+h") == TutorialPractice.normalize("shift+cmd+h"))
        check("normalize collapses modifier spellings",
              TutorialPractice.normalize("command+l") == TutorialPractice.normalize("⌘L"))
        check("normalize differs on different key",
              TutorialPractice.normalize("cmd+h") != TutorialPractice.normalize("cmd+l"))
        check("normalize differs on different modifiers",
              TutorialPractice.normalize("cmd+h") != TutorialPractice.normalize("cmd+shift+h"))
        check("normalize nil for empty", TutorialPractice.normalize("") == nil)
        check("normalize nil for modifier-only", TutorialPractice.normalize("cmd+shift") == nil)
        check("normalize maps arrow keys",
              TutorialPractice.normalize("ctrl+opt+left")?.key == "←")

        // MARK: - chordString(keyCode:flags:) reverse mapping

        // h = keycode 4. cmd+h must rebuild to a chord that matches focusLeft.
        let hChord = TutorialPractice.chordString(keyCode: 4, flags: [.maskCommand])
        check("chordString builds cmd+h", hChord != nil)
        check("rebuilt cmd+h matches focusLeft",
              hChord.flatMap { TutorialPractice.normalize($0) } == TutorialPractice.normalize("cmd+h"))
        // Full mod stack ordering is canonical (ctrl, opt, shift, cmd, key).
        let stack = TutorialPractice.chordString(keyCode: 38, // j
                                                 flags: [.maskCommand, .maskControl, .maskAlternate, .maskShift])
        check("chordString canonical mod order", stack == "ctrl+opt+shift+cmd+j")
        check("chordString nil for unmapped keycode",
              TutorialPractice.chordString(keyCode: 9999, flags: []) == nil)
        // Round-trip: every core default chord, rebuilt from its parsed Chord,
        // matches the original (proves tap→deliver wiring will line up).
        for action in KeyAction.coreActions {
            guard let raw = KeyAction.defaultChords[action]?.first,
                  let parsed = Chord(string: raw), parsed.hasKey else { continue }
            let rebuilt = TutorialPractice.chordString(keyCode: parsed.keyCode, flags: parsed.cgFlags)
            let ok = rebuilt.flatMap { TutorialPractice.normalize($0) } == TutorialPractice.normalize(raw)
            check("key-event round-trip matches \(action): \(raw)", ok)
        }

        // MARK: - Offscreen-render smoke test of the view

        check("view smoke render", smokeRenderView(config: config))

        print("\n[practicetest] \(passed) passed, \(failed) failed")
        return failed == 0
    }

    /// Construct the view, force layout, drive a full deliver(chord:) sequence
    /// (a miss, then every correct chord to completion, then reset), and assert
    /// nothing crashes and progress tracks. Pure offscreen — no window shown, no
    /// event tap, no real keys.
    private static func smokeRenderView(config: ScrollWMConfig) -> Bool {
        let view = TutorialPracticeView(config: config)
        view.frame = NSRect(x: 0, y: 0, width: 460, height: 360)

        // Capture-change hook should fire on start/stop.
        var captureEvents: [Bool] = []
        view.onCaptureChange = { captureEvents.append($0) }

        // While not capturing, deliver is inert.
        if view.deliver(chord: "cmd+h") != nil { print("  ✗ deliver before start should be nil"); return false }

        view.start()
        view.layoutSubtreeIfNeeded()
        guard view.fittingSize.width > 0, view.fittingSize.height > 0 else {
            print("  ✗ view has zero fitting size"); return false
        }
        guard view.isComplete == false else { print("  ✗ drill should not start complete"); return false }

        // A miss then the full correct run.
        _ = view.deliver(chord: "ctrl+opt+z")               // miss
        var lastOutcome: TutorialPractice.Outcome? = nil
        let drill = TutorialPractice(config: config)         // mirror to know the chords
        for c in drill.challenges {
            lastOutcome = view.deliver(chord: c.chords.first!)
        }
        guard lastOutcome == .complete, view.isComplete, view.fraction == 1.0 else {
            print("  ✗ view did not reach completion via deliver"); return false
        }

        // Offscreen bitmap render must not crash.
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
        }

        // Reset via the public API, then stop.
        view.resetDrill()
        guard view.fraction == 0 else { print("  ✗ resetDrill did not clear progress"); return false }
        view.stop()

        // start() then stop() must have toggled capture at least on→off.
        guard captureEvents.contains(true) && captureEvents.contains(false) else {
            print("  ✗ onCaptureChange did not report start/stop"); return false
        }
        return true
    }
}
