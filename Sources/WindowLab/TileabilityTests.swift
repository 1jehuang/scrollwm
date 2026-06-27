import Foundation
import ApplicationServices
import AppKit

/// GATE-E (Tileability classification) audit tests.
///
/// The "tileability gate" is the eligibility test that decides whether a window
/// that has already SURVIVED enumeration + identity-match + current-Space +
/// adopt-scope is actually placed as a TILED column, vs left floating (or made
/// invisible to the manager entirely). Two code sites implement the SAME pure
/// predicate and must stay in lock-step:
///
///   1. `TeleportEngine.adopt` (cold arrange): keeps only
///      `subrole == AXStandardWindow && !isMinimized && !isFullscreen`
///      (`TeleportEngine.swift:232-234`).
///   2. `LifecycleMonitor.resync`/`applyResync`/`fastAdopt` (live path): the
///      `standard` / `standardAdoptable` filters apply the identical predicate
///      (`LifecycleMonitor.swift:216-219, 413`).
///
/// `FloatingWindows.classify` is the SIBLING policy: it decides whether a
/// non-tiled window is at least LISTED in the menu bar (reachable) as floating.
/// The user-facing failure modes all live in the GAP between "what the user
/// perceives as a tileable window" and "what reports `AXStandardWindow`":
///
///   - A window whose true subrole is `AXDialog` / `AXFloatingWindow` /
///     `AXSystemDialog` is classify-`listOnly` (reachable, never tiled) -> it
///     floats forever even though the user thinks of it as their main window.
///   - A window with a NIL or `AXUnknown` subrole is classify-`nil` -> it is
///     neither tiled NOR listed: completely invisible to the manager.
///
/// These tests feed SYNTHETIC subroles through the real `adopt` filter and the
/// real `classify` policy, so the eligibility boundary is pinned without AX
/// permission or real windows (matching `StripOpsTests` conventions: AX writes
/// on synthetic elements fail harmlessly and we assert on the engine model).
enum TileabilityTests {

    // Subrole constants under test (the four a top-level window can really
    // report, plus the degenerate transition/unknown cases).
    private static let std = kAXStandardWindowSubrole as String   // "AXStandardWindow"
    private static let dlg = kAXDialogSubrole as String           // "AXDialog"
    private static let sysDlg = kAXSystemDialogSubrole as String  // "AXSystemDialog"
    private static let floatW = kAXFloatingWindowSubrole as String // "AXFloatingWindow"

    /// Build a `MatchedWindow` with a chosen subrole / minimized / fullscreen,
    /// matched to a CG entry (current-Space) so only the tileability gate, not
    /// the current-Space gate, decides its fate.
    private static func matched(
        _ pidBase: Int,
        subrole: String?,
        minimized: Bool = false,
        fullscreen: Bool = false,
        role: String = kAXWindowRole as String,
        frame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 300),
        onCurrentSpace: Bool = true
    ) -> MatchedWindow {
        let ax = AXWindowInfo(
            pid: pid_t(pidBase),
            appName: "App\(pidBase)",
            element: AXUIElementCreateApplication(pid_t(pidBase)),
            title: "Win\(pidBase)",
            role: role,
            subrole: subrole,
            frame: frame,
            isMinimized: minimized,
            isFullscreen: fullscreen
        )
        let cg: CGWindowInfo? = onCurrentSpace ? CGWindowInfo(
            windowID: CGWindowID(pidBase), ownerPID: pid_t(pidBase), ownerName: "App\(pidBase)",
            title: "Win\(pidBase)", bounds: frame, layer: 0, alpha: 1.0,
            isOnscreen: true, memoryUsage: 0
        ) : nil
        return MatchedWindow(ax: ax, cg: cg, matchScore: cg == nil ? 0 : 95)
    }

    private static func freshEngine() -> TeleportEngine {
        TeleportEngine(screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
    }

    /// Run `adopt` over a single matched window and report whether it became a
    /// tiled slot (the gate's observable outcome).
    private static func adoptTiles(_ m: MatchedWindow) -> Bool {
        let e = freshEngine()
        e.adopt(matched: [m])
        return e.slots.count == 1 && CFEqual(e.slots[0].window.element, m.ax.element)
    }

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        print("\n[tileability] GATE-E: adopt eligibility + classify gap")

        // ============================================================
        // 1. The adopt gate accepts ONLY AXStandardWindow (non-min, non-fs).
        //    This is the canonical happy path.
        // ============================================================
        check("adopt: AXStandardWindow tiles",
              adoptTiles(matched(80001, subrole: std)))

        // ------------------------------------------------------------
        // (1) NON-STANDARD subrole on a window the user perceives as PRIMARY.
        //     Real apps whose main window is NOT AXStandardWindow:
        //       - AXDialog: single-window utility/preference apps, some
        //         password managers / installers, the macOS "Open/Save" host
        //         window of a document-less app, certain Qt/wxWidgets apps that
        //         create their main window as a dialog, JetBrains "Welcome to
        //         IntelliJ" launcher, DBeaver/older SWT splash-then-main.
        //       - AXFloatingWindow: tool-palette-first apps (some audio plugins,
        //         color pickers, PixelSnap, Hidden Bar config), apps whose ONLY
        //         window is a non-activating panel.
        //       - AXSystemDialog: system-driven sheets/dialogs.
        //     ALL of these are dropped by adopt -> never tiled, only floated.
        // ------------------------------------------------------------
        check("adopt: AXDialog primary window NOT tiled (floats)",
              !adoptTiles(matched(80002, subrole: dlg)))
        check("adopt: AXFloatingWindow primary window NOT tiled (floats)",
              !adoptTiles(matched(80003, subrole: floatW)))
        check("adopt: AXSystemDialog NOT tiled (floats)",
              !adoptTiles(matched(80004, subrole: sysDlg)))

        // ------------------------------------------------------------
        // (2) NIL subrole entirely. Real culprits: some Electron builds before
        //     the window finishes initializing, raw GLFW/SDL/Java-AWT windows,
        //     a few games and emulators, custom NSWindow subclasses that never
        //     set a subrole. classify returns nil -> NOT EVEN LISTED as
        //     floating: completely invisible to the manager.
        // ------------------------------------------------------------
        check("adopt: nil subrole NOT tiled",
              !adoptTiles(matched(80005, subrole: nil)))

        // ------------------------------------------------------------
        // (3) Mid-transition AXUnknown subrole (window being torn down or not
        //     yet committed). Dropped by adopt AND classify.
        // ------------------------------------------------------------
        check("adopt: AXUnknown subrole NOT tiled",
              !adoptTiles(matched(80006, subrole: "AXUnknown")))

        // ------------------------------------------------------------
        // (4) Fullscreen / minimized false-positives: a standard window that is
        //     minimized or in a native fullscreen Space is intentionally not
        //     tiled (it is not on the visible strip Space).
        // ------------------------------------------------------------
        check("adopt: minimized AXStandardWindow NOT tiled",
              !adoptTiles(matched(80007, subrole: std, minimized: true)))
        check("adopt: fullscreen AXStandardWindow NOT tiled",
              !adoptTiles(matched(80008, subrole: std, fullscreen: true)))

        // ============================================================
        // 2. Mixed batch: adopt keeps ONLY the standard, visible windows and
        //    silently drops every non-tileable one (the live failure shape:
        //    "arrange tiled some, left the rest floating").
        // ============================================================
        do {
            let e = freshEngine()
            e.adopt(matched: [
                matched(80101, subrole: std),                 // tiled
                matched(80102, subrole: dlg),                 // dropped (dialog)
                matched(80103, subrole: nil),                 // dropped (nil)
                matched(80104, subrole: std, minimized: true),// dropped (min)
                matched(80105, subrole: std),                 // tiled
                matched(80106, subrole: floatW),              // dropped (float)
                matched(80107, subrole: std, fullscreen: true)// dropped (fs)
            ])
            check("adopt: mixed batch tiles exactly the 2 standard windows",
                  e.slots.count == 2)
            check("adopt: mixed batch keeps creation order of tiled windows",
                  e.slots.count == 2
                  && CFEqual(e.slots[0].window.element, AXUIElementCreateApplication(80101))
                  && CFEqual(e.slots[1].window.element, AXUIElementCreateApplication(80105)))
        }

        // ============================================================
        // 3. The ASYMMETRY: adopt (tile) vs classify (list). A non-standard
        //    primary window is dropped by adopt yet SURFACED by classify -> the
        //    user sees it in the floating menu but it can never be pulled into
        //    a column. A nil-subrole window is dropped by BOTH -> invisible.
        // ============================================================
        // AXDialog: not tiled, but at least listed (reachable).
        check("gap: AXDialog -> adopt drops AND classify lists (floating-but-reachable)",
              !adoptTiles(matched(80201, subrole: dlg))
              && FloatingWindows.classify(subrole: dlg, isMinimized: false, isFullscreen: false,
                                          onCurrentSpace: true, isSelf: false) == .listOnly)
        // AXFloatingWindow: same — listed, never tiled.
        check("gap: AXFloatingWindow -> dropped by adopt, listOnly in classify",
              !adoptTiles(matched(80202, subrole: floatW))
              && FloatingWindows.classify(subrole: floatW, isMinimized: false, isFullscreen: false,
                                          onCurrentSpace: true, isSelf: false) == .listOnly)
        // nil subrole: the WORST case — dropped by adopt and INVISIBLE to
        // classify (returns nil). Electron/GLFW/SDL/Java primary windows.
        check("gap: nil subrole -> dropped by adopt AND invisible to classify (NOT listed)",
              !adoptTiles(matched(80203, subrole: nil))
              && FloatingWindows.classify(subrole: nil, isMinimized: false, isFullscreen: false,
                                          onCurrentSpace: true, isSelf: false) == nil)
        // AXUnknown: also invisible to classify.
        check("gap: AXUnknown subrole -> dropped by adopt AND invisible to classify",
              !adoptTiles(matched(80204, subrole: "AXUnknown"))
              && FloatingWindows.classify(subrole: "AXUnknown", isMinimized: false, isFullscreen: false,
                                          onCurrentSpace: true, isSelf: false) == nil)

        // ============================================================
        // 4. WindowReveal asymmetry: `shouldUnminimize` keys on ROLE (AXWindow),
        //    NOT subrole, because macOS mutates a minimized window's subrole.
        //    So reveal restores a window that adopt may then STILL drop if its
        //    settled subrole is non-standard — it becomes floating, not tiled.
        //    This is by design (low-stakes de-miniaturize), but documents the
        //    flow end-to-end so the gap is explicit.
        // ============================================================
        // A genuine top-level window (role AXWindow) is un-minimized regardless
        // of the (possibly mutated) subrole it reports in the Dock.
        check("reveal: minimized AXWindow is un-minimized even if subrole reads AXDialog",
              WindowReveal.shouldUnminimize(role: kAXWindowRole as String, isMinimized: true))
        // After reveal, if the window's TRUE subrole is AXDialog, adopt drops it.
        check("reveal->adopt: revealed AXDialog window still floats (not tiled)",
              !adoptTiles(matched(80301, subrole: dlg, minimized: false)))
        // A non-window role (sheet content, etc.) is never un-minimized.
        check("reveal: non-AXWindow role is not un-minimized",
              !WindowReveal.shouldUnminimize(role: "AXSheet", isMinimized: true))
        check("reveal: nil role is not un-minimized",
              !WindowReveal.shouldUnminimize(role: nil, isMinimized: true))

        // ============================================================
        // 5. classify totality over the full subrole space, so the policy can
        //    never silently start tiling a dialog or listing an unknown.
        // ============================================================
        let allSubroles: [String?] = [std, dlg, sysDlg, floatW, "AXUnknown",
                                       "AXSystemFloatingWindow", "", nil]
        for s in allSubroles {
            let k = FloatingWindows.classify(subrole: s, isMinimized: false, isFullscreen: false,
                                             onCurrentSpace: true, isSelf: false)
            let label = s ?? "nil"
            switch s {
            case std:
                check("classify total: \(label) -> tileable", k == .tileable)
            case dlg, sysDlg, floatW:
                check("classify total: \(label) -> listOnly", k == .listOnly)
            default:
                // AXUnknown, AXSystemFloatingWindow, "", nil -> not surfaced.
                check("classify total: \(label) -> nil", k == nil)
            }
        }
        // Tileable + listable sets are disjoint (a subrole is never both).
        check("classify: tileable/listable subrole sets are disjoint",
              FloatingWindows.tileableSubroles.isDisjoint(with: FloatingWindows.listableSubroles))
        // The adopt gate's tileable set is EXACTLY classify's tileableSubroles
        // (single source of truth; if adopt widened, this would catch drift).
        check("invariant: only AXStandardWindow is tileable in classify",
              FloatingWindows.tileableSubroles == [std])

        // ============================================================
        // 6. Empty adopt: a batch of ONLY non-tileable windows yields an empty
        //    strip (the controller then logs "no manageable windows found").
        //    This is the user-visible "arrange did nothing" when every window
        //    happens to be a dialog/panel/nil-subrole app.
        // ============================================================
        do {
            let e = freshEngine()
            e.adopt(matched: [
                matched(80401, subrole: dlg),
                matched(80402, subrole: floatW),
                matched(80403, subrole: nil),
                matched(80404, subrole: sysDlg),
            ])
            check("adopt: all-non-tileable batch yields empty strip", e.slots.isEmpty)
        }

        print("[tileability] GATE-E: \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
