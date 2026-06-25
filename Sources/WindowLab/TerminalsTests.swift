import Foundation

/// Unit tests for the ranked terminal catalog (`TerminalCatalog`) and the
/// pure black-background policy (`TerminalApp.ThemeRule`).
///
/// HEADLESS and SAFE: every function under test is pure (no NSWorkspace,
/// filesystem, or process launch), so this never touches the user's machine.
/// Wired into the `unittest` runner alongside the other onboarding lanes.
enum TerminalsTests {

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        print("\n[unittest] terminal catalog:")

        // MARK: - Ranking is consistent and stable.
        let ranked = TerminalCatalog.ranked()
        check("catalog is non-empty", !ranked.isEmpty)
        check("rank mirrors array index (no drift)",
              TerminalCatalog.all.enumerated().allSatisfy { $0.offset == $0.element.rank })
        check("ranks are strictly increasing best-first",
              zip(ranked, ranked.dropFirst()).allSatisfy { $0.rank < $1.rank })
        check("ranks are unique",
              Set(ranked.map { $0.rank }).count == ranked.count)
        check("ids are unique",
              Set(ranked.map { $0.id }).count == ranked.count)
        check("bundle ids are globally unique across the catalog",
              ranked.flatMap { $0.bundleIDs }.count
                == Set(ranked.flatMap { $0.bundleIDs }).count)
        check("Ghostty is the top pick", ranked.first?.id == "ghostty")
        check("Apple Terminal is the universal fallback (last)", ranked.last?.id == "appleTerminal")

        // MARK: - best(installed:) walks the preference order.
        check("best: nothing installed -> nil",
              TerminalCatalog.best(installed: []) == nil)
        check("best: only Terminal.app -> Terminal.app",
              TerminalCatalog.best(installed: ["com.apple.Terminal"])?.id == "appleTerminal")
        check("best: kitty + Terminal -> kitty (higher rank wins)",
              TerminalCatalog.best(installed: ["net.kovidgoyal.kitty", "com.apple.Terminal"])?.id == "kitty")
        check("best: Ghostty beats everything",
              TerminalCatalog.best(installed: ["com.apple.Terminal", "net.kovidgoyal.kitty",
                                               "com.mitchellh.ghostty", "com.googlecode.iterm2"])?.id == "ghostty")
        check("best: an unknown bundle id is ignored",
              TerminalCatalog.best(installed: ["com.example.notaterminal"]) == nil)
        check("best: Alacritty matches either bundle id variant",
              TerminalCatalog.best(installed: ["io.alacritty"])?.id == "alacritty"
                && TerminalCatalog.best(installed: ["org.alacritty"])?.id == "alacritty")

        // MARK: - openArguments always forces a fresh instance.
        check("openArguments uses -n + the bundle path",
              ranked[0].openArguments(bundlePath: "/Applications/Ghostty.app")
                == ["-n", "/Applications/Ghostty.app"])

        // MARK: - Black-background policy (the "if default, make it black" rule).
        let ghostty = TerminalCatalog.all.first { $0.id == "ghostty" }!
        let rule = ghostty.theme!

        // Missing file (nil) -> create with our directive.
        let created = rule.applyingBlackBackground(to: nil)
        check("theme: missing config -> writes black line",
              created?.contains("background = 000000") == true)

        // Empty file -> same.
        check("theme: empty config -> writes black line",
              rule.applyingBlackBackground(to: "")?.contains("background = 000000") == true)

        // A config WITHOUT a background -> append (and keep the user's content).
        let userCfg = "keybind = cmd+enter=new_window\nconfirm-close-surface = false\n"
        let appended = rule.applyingBlackBackground(to: userCfg)
        check("theme: appends to a config that lacks a background",
              appended?.hasPrefix(userCfg) == true && appended?.contains("background = 000000") == true)

        // Idempotent: feeding the result back in is a no-op.
        check("theme: idempotent (second apply is nil)",
              rule.applyingBlackBackground(to: appended!) == nil)

        // A user who ALREADY set a background -> never touched.
        check("theme: respects an existing background = ff0000",
              rule.applyingBlackBackground(to: "background = ff0000\n") == nil)
        check("theme: respects 'background=ff0000' (no spaces)",
              rule.applyingBlackBackground(to: "background=ff0000\n") == nil)

        // A commented-out background does NOT count as set.
        check("theme: a commented background still gets a real one",
              rule.applyingBlackBackground(to: "# background = ff0000\n")?.contains("background = 000000") == true)

        // `background-image` / `background_opacity` must NOT count as a background color.
        check("theme: background-image is not a background directive",
              !rule.hasBackgroundDirective(in: "background-image = foo.png\n"))
        check("theme: background_opacity is not a background directive",
              !rule.hasBackgroundDirective(in: "background_opacity = 0.8\n"))

        // kitty uses its own syntax ("background #000000").
        let kitty = TerminalCatalog.all.first { $0.id == "kitty" }!
        check("theme: kitty black line uses kitty syntax",
              kitty.theme!.applyingBlackBackground(to: nil)?.contains("background #000000") == true)
        check("theme: kitty respects an existing background",
              kitty.theme!.applyingBlackBackground(to: "background #112233\n") == nil)

        // Terminals with binary/structured configs are launch-only (no theming).
        for id in ["wezterm", "alacritty", "iterm2", "warp", "hyper", "appleTerminal"] {
            let app = TerminalCatalog.all.first { $0.id == id }!
            check("theme: \(id) has no theme rule (launch-only)", app.theme == nil)
        }

        print("\n[unittest] terminal catalog: \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
