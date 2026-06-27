import Foundation

/// Pure-logic tests for the paged tutorial content model (`TutorialContent`).
///
/// Lane 2. No AppKit window is built, so these run headless. The goal mirrors
/// the existing `ChordFormatter.keyTableRows` coverage test, but for the new
/// paged structure: prove the page set is stable + total, copy is non-empty,
/// chords come from the live config (no hardcoding / no drift), and EVERY
/// user-facing `KeyAction` is documented on exactly one page (no missing,
/// stale, or duplicated bindings).
///
/// Run with: `WindowLab unittest` (wired by the coordinator).
enum TutorialContentTests {

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        let defaultConfig = ScrollWMConfig.default
        let pages = TutorialContent.pages(config: defaultConfig)

        // MARK: - Page set is stable + ordered

        check("one page per PageID", pages.count == TutorialContent.PageID.allCases.count)
        check("page order matches PageID.allCases",
              pages.map { $0.id } == TutorialContent.PageID.allCases)
        check("page ids are unique", Set(pages.map { $0.id }).count == pages.count)
        // Pin the actual teaching order so a reorder is a conscious, tested change.
        check("teaching order is welcome→navigate→arrange→workspaces→displays→settings",
              pages.map { $0.id } == [.welcome, .navigate, .arrange, .workspaces, .displays, .settings])

        // MARK: - Every page has non-empty title + intro + items

        for page in pages {
            check("page \(page.id.rawValue) has a title",
                  !page.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            check("page \(page.id.rawValue) has intro copy",
                  !page.intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            check("page \(page.id.rawValue) has items", !page.items.isEmpty)
        }

        // Every prose/bullet/configPath string is non-empty too (no blank rows).
        for page in pages {
            for item in page.items {
                switch item {
                case .prose(let s), .bullet(let s), .configPath(let s):
                    check("page \(page.id.rawValue) item copy non-empty",
                          !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                case .keybinding(let row):
                    check("page \(page.id.rawValue) kb row '\(row.label)' has label",
                          !row.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    check("page \(page.id.rawValue) kb row '\(row.label)' has chords",
                          !row.chords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    check("page \(page.id.rawValue) kb row '\(row.label)' covers >=1 action",
                          !row.covers.isEmpty)
                }
            }
        }

        // MARK: - KeyAction coverage: every action documented EXACTLY once

        let covered = TutorialContent.coveredActions(config: defaultConfig)
        let coveredSet = Set(covered)
        let allActions = Set(KeyAction.allCases)

        check("pages cover every KeyAction", coveredSet == allActions)
        check("pages have no stale actions", coveredSet.isSubset(of: allActions))
        check("pages have no missing actions", allActions.isSubset(of: coveredSet))
        check("each action documented exactly once", covered.count == coveredSet.count)
        // Same coverage guarantee the existing key table makes - kept parallel
        // so the two surfaces can never disagree about which actions exist.
        let tableCovered = Set(ChordFormatter.keyTableRows().flatMap { $0.covers })
        check("page coverage matches keyTableRows coverage", coveredSet == tableCovered)

        // MARK: - Chords come from the LIVE config (no hardcoding / no drift)

        // Default config: the toggle row shows the default chord glyphs.
        if let toggleRow = keybindingRow(in: pages, covering: .toggleArrange) {
            check("toggle row renders default chord",
                  toggleRow.chords == ChordFormatter.chordText(defaultConfig, .toggleArrange))
            check("toggle row shows ⌃⌥⎋", toggleRow.chords.contains("⌃⌥⎋"))
        } else { check("toggle row exists", false) }

        // A user override is reflected immediately (proves nothing is hardcoded).
        var custom = ScrollWMConfig.default
        custom.keybindings[.focusLeft] = ["ctrl+opt+left"]
        let customPages = TutorialContent.pages(config: custom)
        if let focusRow = keybindingRow(in: customPages, covering: .focusLeft) {
            check("focus row honours config override", focusRow.chords.contains("⌃⌥←"))
        } else { check("focus row exists", false) }

        // MARK: - pages(config:) is total over odd inputs

        // Empty keybindings: still total, still full coverage (chords fall back
        // to the built-in defaults, so no row renders blank).
        var emptyKB = ScrollWMConfig.default
        emptyKB.keybindings = [:]
        let emptyPages = TutorialContent.pages(config: emptyKB)
        check("empty-keybindings config still yields all pages",
              emptyPages.map { $0.id } == TutorialContent.PageID.allCases)
        check("empty-keybindings config still covers every action",
              Set(TutorialContent.coveredActions(config: emptyKB)) == allActions)
        for row in TutorialContent.keybindingRows(config: emptyKB) {
            check("fallback chords non-empty: \(row.label)",
                  !row.chords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        // MARK: - The config page surfaces the real config file path

        if let settings = pages.first(where: { $0.id == .settings }) {
            let hasPath = settings.items.contains { item in
                if case let .configPath(p) = item { return p == ScrollWMConfig.fileURL.path }
                return false
            }
            check("settings page shows the live config path", hasPath)
        } else { check("settings page exists", false) }

        print("\n[tutorialcontenttest] \(passed) passed, \(failed) failed")
        return failed == 0
    }

    /// Find the first keybinding row across all pages that documents `action`.
    private static func keybindingRow(in pages: [TutorialContent.Page],
                                      covering action: KeyAction) -> TutorialContent.KeybindingRow? {
        for page in pages {
            for item in page.items {
                if case let .keybinding(row) = item, row.covers.contains(action) { return row }
            }
        }
        return nil
    }
}
