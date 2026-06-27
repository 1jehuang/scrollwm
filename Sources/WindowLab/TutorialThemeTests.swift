import AppKit

/// Tests for Lane 3 (visual theme + reusable components).
///
/// Two layers:
/// 1. **Pure assertions** on the deterministic parts of `TutorialTheme` — the
///    spacing scale, corner-radius tiers, font ramp ordering, and the WCAG-style
///    color math (`relativeLuminance`, `contrastRatio`, `mix`,
///    `readableForeground`). These need no AppKit appearance and run anywhere.
/// 2. An **offscreen-render smoke test** that constructs each `TutorialComponents`
///    view, forces layout, and asserts a non-zero fitting size with no crash —
///    in BOTH light and dark appearances. This catches constraint cycles,
///    nil-color crashes, and zero-size collapses without a visible window.
///
/// Run via `<Lane>Tests.run()`, wired into `unittest` by the coordinator.
enum TutorialThemeTests {

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        // MARK: - Spacing scale

        let sp = TutorialTheme.Spacing.scale
        check("spacing scale non-empty", !sp.isEmpty)
        check("spacing all positive", sp.allSatisfy { $0 > 0 })
        check("spacing strictly increasing", zip(sp, sp.dropFirst()).allSatisfy { $0 < $1 })
        check("spacing on 4pt grid",
              sp.allSatisfy { $0.truncatingRemainder(dividingBy: TutorialTheme.Spacing.unit) == 0 })
        check("spacing step(0) == 0", TutorialTheme.Spacing.step(0) == 0)
        check("spacing step(3) == 12", TutorialTheme.Spacing.step(3) == 12)
        check("spacing md == 16", TutorialTheme.Spacing.md == 16)

        // MARK: - Radius tiers

        let radii = TutorialTheme.Radius.scale
        check("radius tiers non-empty", !radii.isEmpty)
        check("radius all positive", radii.allSatisfy { $0 > 0 })
        check("radius strictly increasing", zip(radii, radii.dropFirst()).allSatisfy { $0 < $1 })
        check("badge radius < card radius", TutorialTheme.Radius.badge < TutorialTheme.Radius.card)

        // MARK: - Font ramp

        let ramp = TutorialTheme.FontSize.ramp
        check("font ramp non-empty", !ramp.isEmpty)
        check("font ramp strictly decreasing", zip(ramp, ramp.dropFirst()).allSatisfy { $0 > $1 })
        check("hero is largest font", TutorialTheme.FontSize.hero == ramp.max())
        check("caption is smallest in ramp", TutorialTheme.FontSize.caption == ramp.min())
        check("body font resolves", TutorialTheme.Font.body.pointSize == TutorialTheme.FontSize.body)
        check("mono is monospaced", TutorialTheme.Font.mono.isFixedPitch)
        check("title is not monospaced", !TutorialTheme.Font.title.isFixedPitch)

        // MARK: - Color math: luminance

        typealias RGBA = TutorialTheme.RGBA
        let lumWhite = TutorialTheme.relativeLuminance(.white)
        let lumBlack = TutorialTheme.relativeLuminance(.black)
        check("luminance white ≈ 1", abs(lumWhite - 1.0) < 1e-6)
        check("luminance black == 0", lumBlack == 0)
        check("luminance white > black", lumWhite > lumBlack)
        // Green contributes more luminance than red than blue (WCAG weights).
        let lumR = TutorialTheme.relativeLuminance(RGBA(1, 0, 0))
        let lumG = TutorialTheme.relativeLuminance(RGBA(0, 1, 0))
        let lumB = TutorialTheme.relativeLuminance(RGBA(0, 0, 1))
        check("green brighter than red brighter than blue", lumG > lumR && lumR > lumB)
        // Monotonic in a gray ramp.
        let grays = stride(from: CGFloat(0), through: 1, by: 0.1).map { RGBA($0, $0, $0) }
        let lums = grays.map { TutorialTheme.relativeLuminance($0) }
        check("luminance monotonic over gray ramp",
              zip(lums, lums.dropFirst()).allSatisfy { $0 <= $1 })

        // MARK: - Color math: contrast

        let cWB = TutorialTheme.contrastRatio(.white, .black)
        check("white/black contrast == 21", abs(cWB - 21.0) < 1e-6)
        check("contrast is symmetric",
              abs(TutorialTheme.contrastRatio(.white, .black)
                  - TutorialTheme.contrastRatio(.black, .white)) < 1e-9)
        check("identical color contrast == 1",
              abs(TutorialTheme.contrastRatio(.white, .white) - 1.0) < 1e-9)
        check("contrast in [1, 21]", (1...21).contains(Int(cWB.rounded())))

        // MARK: - Color math: mix

        let mid = TutorialTheme.mix(.black, .white, 0.5)
        check("mix midpoint is gray 0.5", abs(mid.r - 0.5) < 1e-9 && mid.r == mid.g && mid.g == mid.b)
        check("mix t=0 returns a", TutorialTheme.mix(.black, .white, 0) == .black)
        check("mix t=1 returns b", TutorialTheme.mix(.black, .white, 1) == .white)
        check("mix clamps t<0", TutorialTheme.mix(.black, .white, -5) == .black)
        check("mix clamps t>1", TutorialTheme.mix(.black, .white, 5) == .white)
        let mixA = TutorialTheme.mix(RGBA(0, 0, 0, 0), RGBA(1, 1, 1, 1), 0.25)
        check("mix interpolates alpha", abs(mixA.a - 0.25) < 1e-9)

        // MARK: - Color math: readable foreground

        let onWhite = TutorialTheme.readableForeground(on: .white)
        let onBlack = TutorialTheme.readableForeground(on: .black)
        check("dark text on white", TutorialTheme.relativeLuminance(onWhite) < 0.5)
        check("light text on black", TutorialTheme.relativeLuminance(onBlack) > 0.5)
        // The chosen foreground always meets at least the WCAG AA large-text bar.
        for bg in [RGBA.white, .black, RGBA(0.5, 0.5, 0.5), RGBA(0.2, 0.4, 0.8),
                   RGBA(0.95, 0.85, 0.1)] {
            let fg = TutorialTheme.readableForeground(on: bg)
            check("readable fg meets AA-large on bg(\(bg.r),\(bg.g),\(bg.b))",
                  TutorialTheme.contrastRatio(fg, bg) >= 3.0)
        }

        // MARK: - Accent contrast (onAccent must read on accent in both modes)

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: appearanceName),
                  let accent = TutorialTheme.rgba(TutorialTheme.Palette.accent, in: appearance),
                  let onAccent = TutorialTheme.rgba(TutorialTheme.Palette.onAccent, in: appearance) else {
                check("accent resolves in \(appearanceName.rawValue)", false); continue
            }
            let ratio = TutorialTheme.contrastRatio(accent, onAccent)
            check("onAccent contrast >= 3 in \(appearanceName.rawValue) (got \(String(format: "%.2f", ratio)))",
                  ratio >= 3.0)
        }

        // MARK: - Status colors: distinct + paired with non-color signals

        let states: [TutorialProgress.LearnState] = [.learned, .learning, .rusty, .notStarted]
        let glyphs = states.map { $0.glyph }
        let captions = states.map { $0.caption }
        check("status glyphs all distinct", Set(glyphs).count == states.count)
        check("status captions all distinct", Set(captions).count == states.count)
        check("status glyph + caption non-empty (color not sole signal)",
              states.allSatisfy { !$0.glyph.isEmpty && !$0.caption.isEmpty })
        check("statusFill is a tint of statusColor (lower alpha)",
              states.allSatisfy { st in
                  TutorialTheme.statusFill(for: st).alphaComponent
                      < TutorialTheme.statusColor(for: st).alphaComponent
              })

        // MARK: - Offscreen render smoke test (both appearances)

        let renderOK = renderSmoke(check: check)
        check("offscreen render smoke (all components, both appearances)", renderOK)

        print("\n[unittest] tutorial theme: \(passed) passed, \(failed) failed")
        return failed == 0
    }

    /// Construct each component, force layout under both appearances, and assert
    /// a non-zero fitting size with no crash. Runs on the main thread (AppKit).
    private static func renderSmoke(check: (String, Bool) -> Void) -> Bool {
        var allOK = true
        func smoke(_ name: String, _ make: () -> NSView) {
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                guard let appearance = NSAppearance(named: appearanceName) else {
                    check("appearance \(appearanceName.rawValue) available", false)
                    allOK = false; continue
                }
                let view = make()
                view.appearance = appearance
                // Give it a sensible width so wrapping/equal-fill layouts settle.
                let host = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 400))
                host.appearance = appearance
                host.wantsLayer = true
                host.addSubview(view)
                view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    view.topAnchor.constraint(equalTo: host.topAnchor),
                    view.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor),
                ])
                host.layoutSubtreeIfNeeded()
                // Drive the appearance-resolving code paths.
                view.layoutSubtreeIfNeeded()
                let fitting = view.fittingSize
                // Render into an offscreen bitmap to exercise the draw path.
                var drew = true
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds.isEmpty
                                                                  ? NSRect(x: 0, y: 0, width: max(fitting.width, 1), height: max(fitting.height, 1))
                                                                  : view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                } else {
                    drew = false
                }
                let ok = fitting.width > 0 && fitting.height > 0 && drew
                if !ok { allOK = false }
                check("\(name) fits + renders in \(appearanceName.rawValue) (\(Int(fitting.width))x\(Int(fitting.height)))", ok)
            }
        }

        let config = ScrollWMConfig.default

        smoke("HeroHeader") {
            TutorialHeroHeader(title: "ScrollWM",
                               tagline: "Your windows on one long scrolling strip.")
        }
        smoke("HeroHeader (no accent)") {
            TutorialHeroHeader(title: "ScrollWM", tagline: "Tagline.", showAccent: false)
        }
        smoke("Card with content") {
            let card = TutorialCard()
            card.setContent(TutorialComponents.wrapping(
                "A card wraps content in a padded, rounded, elevated surface."))
            return card
        }
        smoke("SectionHeader") {
            TutorialSectionHeader(title: "Navigate", subtitle: "from your config")
        }
        smoke("SectionHeader (no subtitle)") {
            TutorialSectionHeader(title: "Arrange windows")
        }
        smoke("Keycap ⌘") { TutorialKeycap(symbol: "⌘") }
        smoke("Keycap pressed") {
            let k = TutorialKeycap(symbol: "H"); k.pressed = true; return k
        }
        smoke("Keycap Space (multi-char)") { TutorialKeycap(symbol: "Space") }
        smoke("KeycapRow ⌘⇧H") {
            TutorialKeycapRow(caps: ChordFormatter.keycaps("cmd+shift+h"))
        }
        smoke("KeycapRow from config") {
            TutorialKeycapRow(config: config, action: .focusRight)
        }
        smoke("KeycapRow empty -> fallback") {
            TutorialKeycapRow(caps: [], fallback: "⌃⌥")
        }
        for st in [TutorialProgress.LearnState.learned, .learning, .rusty, .notStarted] {
            smoke("StatusBadge \(st.rawValue)") { TutorialStatusBadge(state: st) }
        }
        smoke("KeybindingRow with badge") {
            TutorialKeybindingRow(config: config, action: .focusLeft, state: .learned)
        }
        smoke("KeybindingRow no badge") {
            TutorialKeybindingRow(config: config, action: .closeWindow)
        }
        smoke("SegmentedSelector") {
            TutorialSegmentedSelector(titles: ["Welcome", "Navigate", "Arrange", "Practice"],
                                      selectedIndex: 1)
        }
        smoke("SegmentedSelector single") {
            TutorialSegmentedSelector(titles: ["Only"])
        }

        smoke("KeycapRow flash (no crash)") {
            let r = TutorialKeycapRow(caps: ["⌘", "L"]); r.flashPressed(); return r
        }

        // Selector behavior: clicking-equivalent selection + clamping (pure-ish).
        let sel = TutorialSegmentedSelector(titles: ["A", "B", "C"], selectedIndex: 99)
        check("selector clamps initial index", sel.selectedIndex == 2)
        sel.select(0)
        check("selector select(0)", sel.selectedIndex == 0)
        sel.select(-5)
        check("selector select clamps low", sel.selectedIndex == 0)
        var fired: Int? = nil
        sel.onSelect = { fired = $0 }
        sel.select(1)
        check("programmatic select does not fire onSelect", fired == nil)

        return allOK
    }
}
