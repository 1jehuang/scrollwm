import Foundation

/// Pure-logic tests for the first-run tutorial's chord rendering and key-table
/// spec (`ChordFormatter`). No AppKit window is built, so these run headless in
/// CI. The goal is to prove `pretty()` is **total** (every token renders, never
/// crashes), the key table covers **every** user-facing `KeyAction` with no
/// stale or duplicate entries, and the displayed chords stay in sync with the
/// live config.
///
/// Run with: `WindowLab tutorialtest` (wired by the coordinator).
enum TutorialTests {

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }
        func eq(_ name: String, _ got: String, _ want: String) {
            check("\(name)  (\"\(got)\" == \"\(want)\")", got == want)
        }

        let pretty = ChordFormatter.pretty

        // MARK: - Modifiers (every spelling -> the right glyph)

        eq("cmd glyph", pretty("cmd"), "⌘")
        eq("command glyph", pretty("command"), "⌘")
        eq("opt glyph", pretty("opt"), "⌥")
        eq("option glyph", pretty("option"), "⌥")
        eq("alt glyph", pretty("alt"), "⌥")
        eq("ctrl glyph", pretty("ctrl"), "⌃")
        eq("control glyph", pretty("control"), "⌃")
        eq("shift glyph", pretty("shift"), "⇧")

        // MARK: - Special keys

        eq("left arrow", pretty("left"), "←")
        eq("right arrow", pretty("right"), "→")
        eq("up arrow", pretty("up"), "↑")
        eq("down arrow", pretty("down"), "↓")
        eq("escape", pretty("escape"), "⎋")
        eq("esc alias", pretty("esc"), "⎋")
        eq("space", pretty("space"), "Space")
        eq("return", pretty("return"), "↩")
        eq("enter alias", pretty("enter"), "↩")
        eq("tab", pretty("tab"), "⇥")
        eq("delete", pretty("delete"), "⌫")

        // MARK: - Named punctuation -> glyph

        eq("backslash", pretty("backslash"), "\\")
        eq("slash", pretty("slash"), "/")
        eq("semicolon", pretty("semicolon"), ";")
        eq("quote", pretty("quote"), "'")
        eq("comma", pretty("comma"), ",")
        eq("period", pretty("period"), ".")
        eq("equal", pretty("equal"), "=")
        eq("grave", pretty("grave"), "`")
        eq("leftbracket", pretty("leftbracket"), "[")
        eq("rightbracket", pretty("rightbracket"), "]")
        eq("minus name", pretty("minus"), "-")

        // MARK: - Letters / digits / function keys (literal upper-case)

        eq("letter h", pretty("h"), "H")
        eq("letter already upper", pretty("L"), "L")
        eq("digit", pretty("5"), "5")
        for d in 0...9 { eq("digit \(d)", pretty("\(d)"), "\(d)") }
        eq("fn key f1", pretty("f1"), "F1")
        eq("fn key f12", pretty("f12"), "F12")

        // MARK: - Unknown tokens fall back to upper-case (totality)

        eq("unknown word", pretty("frobnicate"), "FROBNICATE")
        eq("lone glyph passes through", pretty("\\"), "\\")

        // MARK: - Multi-token chords

        eq("two modifiers", pretty("ctrl+opt"), "⌃⌥")
        eq("mod + letter", pretty("cmd+h"), "⌘H")
        eq("three tokens", pretty("cmd+shift+h"), "⌘⇧H")
        eq("mod + digit", pretty("opt+1"), "⌥1")
        eq("mod + arrow", pretty("ctrl+opt+left"), "⌃⌥←")
        eq("mod + escape", pretty("ctrl+opt+escape"), "⌃⌥⎋")
        eq("hyphen separator", pretty("cmd-shift-l"), "⌘⇧L")
        eq("space separator", pretty("cmd shift l"), "⌘⇧L")
        eq("mixed case input", pretty("CMD+Shift+H"), "⌘⇧H")

        // MARK: - Degenerate input is total (no crash, returns original)

        eq("empty string", pretty(""), "")
        eq("separators only", pretty("+"), "+")
        eq("trailing plus", pretty("cmd+"), "⌘")
        eq("leading plus", pretty("+cmd"), "⌘")

        // MARK: - Idempotency: pretty(pretty(x)) == pretty(x)

        let zoo = [
            "cmd+shift+h", "ctrl+opt+left", "opt+1", "ctrl+opt", "cmd+q",
            "ctrl+opt+escape", "space", "return", "tab", "delete", "f7",
            "cmd-shift-l", "frobnicate", "", "+", "down",
        ]
        for chord in zoo {
            let once = pretty(chord)
            eq("idempotent: \(chord.isEmpty ? "<empty>" : chord)", pretty(once), once)
        }
        // Idempotency must also hold for EVERY default chord shipped in the app.
        for (_, chords) in KeyAction.defaultChords {
            for chord in chords {
                let once = pretty(chord)
                check("idempotent default \(chord)", pretty(once) == once)
            }
        }

        // MARK: - Round-trip: glued pretty form re-parses to the same Chord.
        // The Config comment promises a user can paste the glyph form back in.
        // This holds for modifier-only and letter/digit chords (glyph keys like
        // arrows/escape are display-only and intentionally not re-parseable).
        let roundTrippable = ["cmd+shift+h", "cmd+l", "opt+1", "cmd+2", "ctrl+opt", "cmd+q"]
        for chord in roundTrippable {
            guard let original = Chord(string: chord) else {
                check("round-trip base parses: \(chord)", false); continue
            }
            let reparsed = Chord(string: pretty(chord))
            check("round-trip \(chord) -> \(pretty(chord))", reparsed == original)
        }

        // MARK: - Key table completeness

        let rows = ChordFormatter.keyTableRows()
        let covered = rows.flatMap { $0.covers }
        let coveredSet = Set(covered)
        let allActions = Set(KeyAction.allCases)

        check("table covers every KeyAction", coveredSet == allActions)
        check("table has no stale actions", coveredSet.isSubset(of: allActions))
        check("table has no missing actions", allActions.isSubset(of: coveredSet))
        check("table covers each action exactly once", covered.count == coveredSet.count)
        check("every row has a non-empty label", rows.allSatisfy { !$0.label.isEmpty })

        // Every row renders non-empty keys for the default config (catches a
        // row that points at an unbound action).
        let defaultConfig = ScrollWMConfig.default
        for row in rows {
            check("row keys non-empty: \(row.label)", !row.keys(defaultConfig).trimmingCharacters(in: .whitespaces).isEmpty)
        }

        // MARK: - chordText reflects the LIVE config (no drift)

        // Default config renders the default chord.
        eq("chordText default focusLeft",
           ChordFormatter.chordText(defaultConfig, .focusLeft), "⌘H")

        // A user override is reflected immediately.
        var custom = ScrollWMConfig.default
        custom.keybindings[.focusLeft] = ["ctrl+opt+left"]
        eq("chordText honours override",
           ChordFormatter.chordText(custom, .focusLeft), "⌃⌥←")

        // Multiple chords join with " or ".
        var multi = ScrollWMConfig.default
        multi.keybindings[.closeWindow] = ["cmd+q", "cmd+w"]
        eq("chordText joins multiple", ChordFormatter.chordText(multi, .closeWindow), "⌘Q or ⌘W")

        // An action explicitly cleared in config falls back to the built-in
        // default (never renders blank).
        var cleared = ScrollWMConfig.default
        cleared.keybindings[.toggleArrange] = nil
        check("chordText falls back to default when unset",
              !ChordFormatter.chordText(cleared, .toggleArrange).isEmpty)

        // Width row shows all four presets, space-separated.
        let widthRow = rows.first { $0.covers.contains(.width25) }!
        let widthKeys = widthRow.keys(defaultConfig)
        check("width row shows all four presets",
              widthKeys.contains("⌥1") && widthKeys.contains("⌥2")
              && widthKeys.contains("⌥3") && widthKeys.contains("⌥4"))

        // Jump row documents the 1…9 digit range.
        let jumpRow = rows.first { $0.covers.contains(.jumpModifier) }!
        check("jump row documents 1…9", jumpRow.keys(defaultConfig).contains("1…9"))

        print("\n[tutorialtest] \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
