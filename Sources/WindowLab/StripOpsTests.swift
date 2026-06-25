import Foundation
import ApplicationServices
import AppKit

/// Pure-logic tests for the strip operations (width/move/close). These do not
/// require Accessibility permission: AX calls on the synthetic elements simply
/// fail and are ignored; we assert on the engine's canvas model, which is the
/// source of truth the menu bar and teleport pass read from.
///
/// Run with: `WindowLab unittest`
enum StripOpsTests {

    /// Build an engine pre-populated with `count` synthetic columns, each
    /// `width` wide, laid out left-to-right with the engine's gap.
    static func makeEngine(count: Int, width: CGFloat = 400, screenWidth: CGFloat = 1600) -> TeleportEngine {
        let screen = CGRect(x: 0, y: 0, width: screenWidth, height: 1000)
        let engine = TeleportEngine(screenFrame: screen)
        var x: CGFloat = 0
        for i in 0..<count {
            // A synthetic, non-functional AX element. Geometry calls on it fail
            // harmlessly; we only care about the model bookkeeping.
            let element = AXUIElementCreateApplication(pid_t(90000 + i))
            let ref = TeleportEngine.ManagedWindowRef(
                element: element,
                pid: pid_t(90000 + i),
                appName: "App\(i)",
                title: "Win\(i)",
                originalFrame: CGRect(x: x, y: 0, width: width, height: 300)
            )
            engine.slots.append(TeleportEngine.Slot(
                window: ref, canvasX: x, width: width, y: 0, height: 300
            ))
            x += width + engine.gap
        }
        engine.focusIndex = 0
        return engine
    }

    /// canvasX values must be a gap-separated left-to-right packing that opens
    /// with a leading `gap` margin (symmetric with the trailing margin).
    static func isCompact(_ engine: TeleportEngine) -> Bool {
        var x: CGFloat = engine.gap
        for slot in engine.slots {
            if abs(slot.canvasX - x) > 0.5 { return false }
            x += slot.width + engine.gap
        }
        return true
    }

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        // --- width(forFraction:) math ---
        // The strip lays out as `gap | col | gap | col | ... | gap`. A fraction
        // f = 1/N must size a column so exactly N of them tile the viewport V:
        //   w(f) = f*(V - gap) - gap
        let e = makeEngine(count: 3)
        let V = e.screenFrame.width            // 1600
        let g = e.gap                          // 12
        func expectedWidth(_ f: CGFloat) -> CGFloat { (f * (V - g) - g).rounded() }
        check("width 25% gap-correct", abs(e.width(forFraction: 0.25) - expectedWidth(0.25)) < 0.5)
        check("width 50% gap-correct", abs(e.width(forFraction: 0.50) - expectedWidth(0.50)) < 0.5)
        check("width 75% gap-correct", abs(e.width(forFraction: 0.75) - expectedWidth(0.75)) < 0.5)
        check("width 100% == V - 2*gap",  abs(e.width(forFraction: 1.0) - (V - 2 * g)) < 0.5)
        check("width clamps to minColumnWidth", e.width(forFraction: 0.001) == e.minColumnWidth)
        check("width clamps fraction >1 to 100%", e.width(forFraction: 5.0) == (V - 2 * g).rounded())
        check("presets are [0.25,0.5,0.75,1.0]", TeleportEngine.widthPresets == [0.25, 0.5, 0.75, 1.0])

        // --- tiling invariant: exactly N columns at fraction 1/N fill V ---
        // Build N columns each sized to 1/N, pack them with a leading gap, and
        // assert the strip's right edge lands at V - gap (symmetric margins),
        // and the next column would start beyond V (so N is the exact maximum).
        func tilingFits(_ n: Int) -> Bool {
            let eng = makeEngine(count: n)
            let w = eng.width(forFraction: 1.0 / CGFloat(n))
            for i in eng.slots.indices { eng.slots[i].width = w }
            eng.compactStrip()
            let last = eng.slots.last!
            let rightEdge = last.canvasX + last.width          // should be ~ V - gap
            let nextStart = rightEdge + eng.gap                // an (N+1)th column start
            // N columns end one gap short of the screen's right edge ...
            let exactRight = abs(rightEdge - (V - g)) < 1.0
            // ... and an extra column would overflow the viewport.
            let noRoomForMore = nextStart + eng.minColumnWidth > V
            return exactRight && noRoomForMore
        }
        check("2 columns @ 50% tile exactly", tilingFits(2))
        check("4 columns @ 25% tile exactly", tilingFits(4))
        check("1 column @ 100% tiles exactly", tilingFits(1))

        // --- compactStrip opens with a leading gap margin (symmetric) ---
        let eMargin = makeEngine(count: 2)
        eMargin.compactStrip()
        check("strip starts at leading gap margin", abs(eMargin.slots[0].canvasX - eMargin.gap) < 0.5)

        // --- setFocusedWidth resizes focused column and recompacts ---
        let e1 = makeEngine(count: 3)
        e1.focusIndex = 1
        let ok1 = e1.setFocusedWidth(fraction: 0.5)
        check("setFocusedWidth returns true", ok1)
        check("focused width updated to 50%", abs(e1.slots[1].width - e1.width(forFraction: 0.5)) < 0.5)
        check("strip stays compact after resize", isCompact(e1))
        check("focus preserved on resized column", e1.focusIndex == 1)

        // --- setFocusedWidth on empty engine is a no-op ---
        let eEmpty = makeEngine(count: 0)
        check("setFocusedWidth on empty == false", eEmpty.setFocusedWidth(fraction: 0.5) == false)

        // --- setFocusedWidth must NOT touch the model for an UNHEALTHY window ---
        // An unreachable window gets no AX write and no readback, so writing the
        // requested width would strand the column at a size the real window
        // never adopts (the "all columns claim the same width but several really
        // differ" desync). The model must keep the last known real size.
        let eUnhealthy = makeEngine(count: 3, width: 735)
        eUnhealthy.focusIndex = 1
        eUnhealthy.slots[1].window.healthy = false
        let okUnhealthy = eUnhealthy.setFocusedWidth(fraction: 0.5)
        check("setFocusedWidth still returns true for unhealthy", okUnhealthy)
        check("unhealthy column keeps its real width (not the request)",
              abs(eUnhealthy.slots[1].width - 735) < 0.5)

        // --- reconcileSizes pulls model widths back to the live AX frame ---
        // Simulate the real-world desync: the model thinks every column is 717
        // but the live frames report a couple at 735. A resync must heal them.
        let eRec = makeEngine(count: 4, width: 717)
        var liveFrames: [AXWindowInfo] = []
        for (i, slot) in eRec.slots.enumerated() {
            let realW: CGFloat = (i == 1 || i == 3) ? 735 : 717
            liveFrames.append(AXWindowInfo(
                pid: slot.window.pid,
                appName: slot.window.appName,
                element: slot.window.element,
                title: slot.window.title,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                frame: CGRect(x: 0, y: 0, width: realW, height: slot.height),
                isMinimized: false,
                isFullscreen: false
            ))
        }
        let recChanged = eRec.reconcileSizes(from: liveFrames)
        check("reconcileSizes reports a change", recChanged)
        check("reconcileSizes heals col1 to live 735", abs(eRec.slots[1].width - 735) < 0.5)
        check("reconcileSizes heals col3 to live 735", abs(eRec.slots[3].width - 735) < 0.5)
        check("reconcileSizes leaves matching col0 at 717", abs(eRec.slots[0].width - 717) < 0.5)
        check("strip recompacts cleanly after size reconcile",
              { eRec.compactStrip(); return isCompact(eRec) }())

        // --- reconcileSizes is a no-op when sizes already match ---
        let recNoop = eRec.reconcileSizes(from: liveFrames)
        check("reconcileSizes no-op when already in sync", recNoop == false)

        // --- reconcileSizes recovers a window's health on reappearance ---
        // A past transient AX failure marked the window unhealthy; seeing it in a
        // fresh enumeration proves it is reachable, so health must be restored or
        // resize/teleport would skip it forever.
        let eHeal = makeEngine(count: 2, width: 717)
        eHeal.slots[0].window.healthy = false
        let healFrames = eHeal.slots.map { slot in
            AXWindowInfo(
                pid: slot.window.pid, appName: slot.window.appName,
                element: slot.window.element, title: slot.window.title,
                role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String,
                frame: CGRect(x: 0, y: 0, width: 717, height: slot.height),
                isMinimized: false, isFullscreen: false
            )
        }
        let healChanged = eHeal.reconcileSizes(from: healFrames)
        check("reconcileSizes recovers stale unhealthy flag", eHeal.slots[0].window.healthy)
        check("reconcileSizes reports change on health recovery alone", healChanged)

        // --- moveFocused reorders columns ---
        let e2 = makeEngine(count: 3) // titles Win0,Win1,Win2
        e2.focusIndex = 0
        let movedR = e2.moveFocused(by: 1)
        check("move right returns true", movedR)
        check("order after move-right == Win1,Win0,Win2",
              e2.slots.map { $0.window.title } == ["Win1", "Win0", "Win2"])
        check("focus follows moved window (index 1)", e2.focusIndex == 1)
        check("strip compact after move", isCompact(e2))

        let movedL = e2.moveFocused(by: -1)
        check("move left returns true", movedL)
        check("order back to Win0,Win1,Win2",
              e2.slots.map { $0.window.title } == ["Win0", "Win1", "Win2"])
        check("focus back at index 0", e2.focusIndex == 0)

        // --- moveFocused at edges returns false ---
        check("move left at left edge == false", e2.moveFocused(by: -1) == false)
        e2.focusIndex = 2
        check("move right at right edge == false", e2.moveFocused(by: 1) == false)

        // --- moveFocused with single window == false ---
        let eOne = makeEngine(count: 1)
        check("move with one window == false", eOne.moveFocused(by: 1) == false)

        // --- closeFocused drops the focused column ---
        let e3 = makeEngine(count: 3)
        e3.focusIndex = 1
        _ = e3.closeFocused() // returns false (synthetic element has no close button)
        check("close removes one column", e3.slots.count == 2)
        check("closed window (Win1) gone", e3.slots.allSatisfy { $0.window.title != "Win1" })
        check("strip compact after close", isCompact(e3))
        check("focus index clamped in range", e3.focusIndex >= 0 && e3.focusIndex < e3.slots.count)

        // --- closeFocused down to empty ---
        let e4 = makeEngine(count: 1)
        _ = e4.closeFocused()
        check("close last window leaves empty strip", e4.slots.isEmpty)
        check("closeFocused on empty == false", e4.closeFocused() == false)

        // --- refitViewportToFocused follows a window that GREW past the edge ---
        // Reproduces the async-resize bug: an app reports the new (larger) size
        // only on a later run-loop turn, so the model width is updated AFTER the
        // initial focus(). Without a re-fit, the viewport would stay put and the
        // grown window would hang off the right edge. After updating the model
        // width and re-fitting, the viewport must scroll to reveal it fully.
        let eg = makeEngine(count: 3, width: 300, screenWidth: 1600)
        eg.focusMode = .fit
        eg.focus(index: 2) // canvasX=2*(300+12)+12=636, right=936: fully visible, no scroll
        check("grow-refit: viewport initially unmoved (column fits)", eg.viewportX == 0)
        // Simulate the app finally growing the focused column to near-full width.
        let grown = eg.width(forFraction: 1.0) // 1576 on a 1600 strip
        eg.slots[eg.focusIndex].width = grown
        eg.compactStrip()
        eg.refitViewportToFocused()
        let gslot = eg.slots[eg.focusIndex]
        // The focused column must now be fully visible within the viewport.
        let visibleLeft = gslot.canvasX - eg.viewportX
        let visibleRight = visibleLeft + gslot.width
        check("grow-refit: viewport scrolled so grown column is visible", eg.viewportX > 0)
        check("grow-refit: grown column fully within viewport",
              visibleLeft >= -0.5 && visibleRight <= eg.screenFrame.width + 0.5)

        // A column that grows but still fits must NOT move the viewport.
        let eg2 = makeEngine(count: 3, width: 300, screenWidth: 1600)
        eg2.focusMode = .fit
        eg2.focus(index: 0) // at left edge, viewportX stays 0
        eg2.slots[0].width = 360 // slightly wider, still well within the screen
        eg2.compactStrip()
        eg2.refitViewportToFocused()
        check("grow-refit: no scroll when grown column still fits", eg2.viewportX == 0)

        // --- viewportTarget: centered mode always centers ---
        let ec = makeEngine(count: 5, width: 400, screenWidth: 1600)
        let slot2 = ec.slots[2] // canvasX = 2*(400+12) = 824
        let centered = ec.viewportTarget(for: slot2, mode: .centered, currentViewportX: 0)
        // expected: canvasX - (screenW - width)/2 = 824 - (1600-400)/2 = 824 - 600 = 224
        check("centered: viewport = 224", abs(centered - 224) < 0.5)

        // --- viewportTarget: fit mode does NOT move when already visible ---
        let ef = makeEngine(count: 5, width: 300, screenWidth: 1600)
        // viewport at 0 shows [0,1600). slot1 canvasX=312, right=612: fully visible.
        let slot1 = ef.slots[1]
        let fitNoMove = ef.viewportTarget(for: slot1, mode: .fit, currentViewportX: 0)
        check("fit: no move when fully visible", fitNoMove == 0)

        // --- fit mode: scrolls minimally when column overflows right ---
        // slot at canvasX=2000, width=300 -> right=2300. viewport [0,1600).
        var farSlot = ef.slots[1]
        farSlot.canvasX = 2000
        farSlot.width = 300
        let fitRight = ef.viewportTarget(for: farSlot, mode: .fit, currentViewportX: 0)
        // expected: slotRight - screenW + gap = 2300 - 1600 + 12 = 712
        check("fit: overflow right scrolls minimally to 712", abs(fitRight - 712) < 0.5)

        // --- fit mode: scrolls left when column is left of viewport ---
        var leftSlot = ef.slots[1]
        leftSlot.canvasX = 100
        leftSlot.width = 300
        // viewport currently at 500 -> shows [500,2100). slot at [100,400) is left.
        let fitLeft = ef.viewportTarget(for: leftSlot, mode: .fit, currentViewportX: 500)
        // expected: max(-gap, slotLeft - gap) = max(-12, 100-12) = 88
        check("fit: overflow left scrolls to 88", abs(fitLeft - 88) < 0.5)

        // --- fit mode: column wider than screen aligns to its left edge ---
        var bigSlot = ef.slots[1]
        bigSlot.canvasX = 500
        bigSlot.width = 2000 // wider than 1600
        let fitBig = ef.viewportTarget(for: bigSlot, mode: .fit, currentViewportX: 0)
        // expected: slotLeft - gap = 500 - 12 = 488
        check("fit: oversized column aligns left to 488", abs(fitBig - 488) < 0.5)

        // REGRESSION (fuzz): an oversized column near the strip's leading edge
        // must clamp the viewport target at 0, never go negative (which would
        // push the strip's start off the left of the screen). Other fit/centered
        // branches already clamp at 0; the wide-column branch used to not.
        var bigEdge = ef.slots[1]
        bigEdge.canvasX = ef.gap            // 12, the leading margin
        bigEdge.width = 2000                 // wider than the 1600 screen
        let fitBigEdge = ef.viewportTarget(for: bigEdge, mode: .fit, currentViewportX: 0)
        check("fit: oversized column at the leading edge clamps viewport at 0 (not negative)",
              fitBigEdge >= -0.0001)

        // --- FocusMode round-trips through rawValue ---
        check("FocusMode rawValue round-trip centered",
              TeleportEngine.FocusMode(rawValue: "centered") == .centered)
        check("FocusMode rawValue round-trip fit",
              TeleportEngine.FocusMode(rawValue: "fit") == .fit)
        check("FocusMode has 2 cases", TeleportEngine.FocusMode.allCases.count == 2)

        // --- insert(window:at:): new windows land where requested ---
        func synthInfo(_ n: Int) -> AXWindowInfo {
            AXWindowInfo(
                pid: pid_t(80000 + n),
                appName: "New\(n)",
                element: AXUIElementCreateApplication(pid_t(80000 + n)),
                title: "New\(n)",
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                isMinimized: false,
                isFullscreen: false
            )
        }

        // A new window inserted to the right of the focused column lands at
        // focusIndex+1, not at the far right end of the strip.
        let ei = makeEngine(count: 3) // Win0,Win1,Win2
        ei.focusIndex = 1
        ei.insert(window: synthInfo(9), at: ei.focusIndex + 1)
        ei.compactStrip()
        check("insert right-of-focus lands at focusIndex+1",
              ei.slots.map { $0.window.title } == ["Win0", "Win1", "New9", "Win2"])
        check("strip compact after insert", isCompact(ei))

        // append still goes to the far right (used as the empty/fallback path).
        let ea = makeEngine(count: 2)
        ea.append(window: synthInfo(8))
        check("append lands at far right",
              ea.slots.map { $0.window.title } == ["Win0", "Win1", "New8"])

        // Inserting into an empty strip places it at index 0.
        let ez = makeEngine(count: 0)
        ez.insert(window: synthInfo(7), at: 0)
        check("insert into empty strip lands at index 0",
              ez.slots.map { $0.window.title } == ["New7"])

        // --- REGRESSION: layout must honor the CONFIGURED gap everywhere ---
        // `insert`/`compactStrip` used to hardcode gap=12, ignoring the engine's
        // config-driven `gap`. With any non-default columnGap, a newly opened
        // window was packed at 12px while width math assumed the real gap, so
        // columns no longer tiled and the new window appeared at the wrong size/
        // offset. Build an engine with a non-default gap and assert the strip
        // stays compact AT THAT GAP after an insert.
        let eGap = TeleportEngine(screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        eGap.gap = 30
        eGap.insert(window: synthInfo(1), at: 0)
        eGap.insert(window: synthInfo(2), at: 1)
        eGap.compactStrip()
        check("insert honors configured gap (col0 at gap)",
              abs(eGap.slots[0].canvasX - 30) < 0.5)
        check("insert honors configured gap (col1 packed at gap)",
              abs(eGap.slots[1].canvasX - (30 + eGap.slots[0].width + 30)) < 0.5)
        check("strip compact at non-default gap", isCompact(eGap))

        // --- REGRESSION: a new window stores its REAL size, not a clamped one ---
        // The teleport pass only repositions windows (never resizes), so the
        // model width MUST equal the real frame width. `insert` used to clamp
        // the stored width to the usable area (screenW - 2*gap); a window wider
        // than that ended up modeled NARROWER than it really was, so compaction
        // packed the next column too close and the new window bled past the
        // viewport edge - the "slightly wrong size / ignores gaps" symptom.
        let eWide = TeleportEngine(screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        let wideInfo = AXWindowInfo(
            pid: 81234, appName: "Wide", element: AXUIElementCreateApplication(81234),
            title: "Wide", role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            frame: CGRect(x: 0, y: 0, width: 2000, height: 1200), // wider/taller than screen
            isMinimized: false, isFullscreen: false
        )
        eWide.insert(window: wideInfo, at: 0)
        check("new window keeps its real (un-clamped) width", eWide.slots[0].width == 2000)
        check("new window keeps its real (un-clamped) height", eWide.slots[0].height == 1200)

        // --- SPAWN WIDTH: a new window snaps to the configured fraction ---
        // With `spawnWidthFraction` set, a freshly inserted column should be
        // resized toward that fraction of the usable width. (Synthetic windows
        // have no live AX size, so the optimistic model update is what we assert;
        // the integration test `opstest` covers the real-AX readback/clamp.)
        let eSpawn = TeleportEngine(screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        eSpawn.spawnWidthFraction = 0.5
        let halfTarget = eSpawn.width(forFraction: 0.5)
        eSpawn.insert(window: synthInfo(3), at: 0)   // synthInfo width 400 != target
        eSpawn.applySpawnWidth(toSlotAt: 0)
        check("spawn width resizes a new column to the configured fraction",
              abs(eSpawn.slots[0].width - halfTarget) < 0.5)

        // Nil spawn width preserves the window's native size (old behavior).
        let eNoSpawn = TeleportEngine(screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        eNoSpawn.spawnWidthFraction = nil
        eNoSpawn.insert(window: synthInfo(4), at: 0) // native width 400
        eNoSpawn.applySpawnWidth(toSlotAt: 0)
        check("nil spawn width preserves native size", eNoSpawn.slots[0].width == 400)

        // An out-of-range index is a safe no-op (never crashes).
        eNoSpawn.applySpawnWidth(toSlotAt: 99)
        check("spawn width on a bad index is a no-op", eNoSpawn.slots.count == 1)

        // --- SPAWN GRID SNAP-UP: nextPresetWidth rounds a clamp-resistant
        // window UP to the smallest preset that fits, so a window the app refuses
        // to shrink still tiles on the grid (spawn path only). ---
        let eSnap = TeleportEngine(screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        eSnap.widthPresets = [0.25, 0.5, 0.75, 1.0]
        let w25 = eSnap.width(forFraction: 0.25)
        let w50 = eSnap.width(forFraction: 0.50)
        let w75 = eSnap.width(forFraction: 0.75)
        let w100 = eSnap.width(forFraction: 1.0)
        // A window clamped just above the 25% column rounds up to the 50% preset.
        check("snap-up: width just over 25% rounds up to 50%",
              eSnap.nextPresetWidth(atLeast: w25 + 10) == w50)
        // A width exactly at a preset stays at that preset (>= comparison).
        check("snap-up: width exactly at 50% stays 50%",
              eSnap.nextPresetWidth(atLeast: w50) == w50)
        // Just over 50% rounds up to 75%.
        check("snap-up: width just over 50% rounds up to 75%",
              eSnap.nextPresetWidth(atLeast: w50 + 10) == w75)
        // A width below the smallest preset rounds up to that smallest preset.
        check("snap-up: tiny width rounds up to the smallest preset",
              eSnap.nextPresetWidth(atLeast: 10) == w25)
        // Wider than the 100% column: no preset fits, returns nil (leave as-is).
        check("snap-up: wider than 100% column returns nil",
              eSnap.nextPresetWidth(atLeast: w100 + 50) == nil)

        // --- Config: chord parsing ---
        if let c = Chord(string: "cmd+shift+h") {
            check("chord cmd+shift+h keyCode is H (4)", c.keyCode == 4)
            check("chord cmd+shift+h has cmd flag", c.cgFlags.contains(.maskCommand))
            check("chord cmd+shift+h has shift flag", c.cgFlags.contains(.maskShift))
            check("chord cmd+shift+h has key", c.hasKey)
        } else { check("chord cmd+shift+h parses", false) }

        check("chord ctrl+opt+left parses", Chord(string: "ctrl+opt+left")?.keyCode == 123)
        check("modifier-only chord has no key", Chord(string: "ctrl+opt")?.hasKey == false)
        check("unknown key rejected", Chord(string: "cmd+squimbus") == nil)
        check("double key rejected", Chord(string: "a+b") == nil)
        check("symbol modifiers parse", Chord(string: "⌘⇧l")?.keyCode == 37)
        // Punctuation keys: literal glyph and spoken name both resolve.
        check("chord cmd+\\ parses to backslash keycode", Chord(string: "cmd+\\")?.keyCode == 42)
        check("chord cmd+backslash parses to same keycode", Chord(string: "cmd+backslash")?.keyCode == 42)
        check("chord cmd+/ parses to slash keycode", Chord(string: "cmd+/")?.keyCode == 44)
        check("chord cmd+; parses to semicolon keycode", Chord(string: "cmd+;")?.keyCode == 41)

        // --- Config: JSONC parsing (comments + overrides) ---
        let jsonc = """
        {
          // a comment with a fake "key": value inside a string-ish // sequence
          "layout": { "columnGap": 20, "minColumnWidth": 150,
                      "widthPresets": [0.3, 0.6, 0.9], "stripDisplay": "largest" },
          "focusMode": "centered",
          "arrangeOnFirstGrant": false,
          "keybindings": {
            "focusNext": "ctrl+opt+k",           // override
            "width25": ["opt+1", "cmd+1"]
          }
        }
        """
        do {
            let parsed = try ScrollWMConfig.parse(jsonc: jsonc)
            check("config columnGap parsed", parsed.layout.columnGap == 20)
            check("config minColumnWidth parsed", parsed.layout.minColumnWidth == 150)
            check("config widthPresets parsed", parsed.layout.widthPresets == [0.3, 0.6, 0.9])
            check("config stripDisplay parsed", parsed.layout.stripDisplay == "largest")  // [md-select]
            check("config focusMode parsed", parsed.focusMode == .centered)
            check("config arrangeOnFirstGrant parsed (false override)", parsed.arrangeOnFirstGrant == false)
            check("config keybinding override", parsed.keybindings[.focusNext] == ["ctrl+opt+k"])
            check("config keybinding array", parsed.keybindings[.width25] == ["opt+1", "cmd+1"])
            // Untouched bindings keep their defaults.
            check("config default kept for unset action",
                  parsed.keybindings[.toggleArrange] == KeyAction.defaultChords[.toggleArrange])
            // spawnWidth unset in this JSON -> keeps the default (0.5).
            check("config spawnWidth defaults when unset", parsed.layout.spawnWidth == 0.5)
            // arrangeOnFirstGrant defaults to on (the no-extra-click first run).
            check("config arrangeOnFirstGrant defaults on",
                  ScrollWMConfig.default.arrangeOnFirstGrant == true)
        } catch {
            check("config JSONC parses", false)
        }

        // spawnWidth: a number is parsed and clamped into (0, 1].
        do {
            let p = try ScrollWMConfig.parse(jsonc: #"{ "layout": { "spawnWidth": 0.75 } }"#)
            check("config spawnWidth number parsed", p.layout.spawnWidth == 0.75)
            let pHigh = try ScrollWMConfig.parse(jsonc: #"{ "layout": { "spawnWidth": 5 } }"#)
            check("config spawnWidth clamped to 1.0", pHigh.layout.spawnWidth == 1.0)
        } catch { check("config spawnWidth number parses", false) }

        // spawnWidth: explicit null preserves native size (nil fraction).
        do {
            let p = try ScrollWMConfig.parse(jsonc: #"{ "layout": { "spawnWidth": null } }"#)
            check("config spawnWidth null -> nil (native size)", p.layout.spawnWidth == nil)
        } catch { check("config spawnWidth null parses", false) }

        // Malformed JSON throws (caller falls back to defaults).
        var threw = false
        do { _ = try ScrollWMConfig.parse(jsonc: "{ not json ]") } catch { threw = true }
        check("malformed config throws", threw)

        // --- Config: niri-style spawn bindings ---
        let spawnJsonc = """
        {
          "spawn": {
            "ctrl+opt+j": "open -na Ghostty --args -e jcode",
            "ctrl+opt": "echo modifier-only ignored at use time"
          }
        }
        """
        do {
            let parsed = try ScrollWMConfig.parse(jsonc: spawnJsonc)
            check("spawn binding parsed", parsed.spawn["ctrl+opt+j"] == "open -na Ghostty --args -e jcode")
            // spawnBindings() resolves chords and drops modifier-only ones.
            let resolved = parsed.spawnBindings()
            check("spawn resolves chord with key", resolved.contains { $0.command == "open -na Ghostty --args -e jcode" && $0.chord.keyCode == 38 })
            check("spawn drops modifier-only chord", !resolved.contains { $0.command.contains("modifier-only") })
        } catch {
            check("spawn config parses", false)
        }
        // Defaults ship with no spawn bindings (no personal config in product).
        check("default config has empty spawn", ScrollWMConfig.default.spawn.isEmpty)
        // [md-select] Default strip display is "main" (NSScreen.main).
        check("default config stripDisplay is 'main'", ScrollWMConfig.default.layout.stripDisplay == "main")

        // Every action has a parseable default chord (or is modifier-only).
        let allDefaultsParse = KeyAction.allCases.allSatisfy { action in
            (KeyAction.defaultChords[action] ?? []).allSatisfy { Chord(string: $0) != nil }
        }
        check("all default chords parse", allDefaultsParse)

        // Default file round-trips: parsing the documented template equals
        // the in-code defaults (keeps the file and code in sync).
        do {
            let fromFile = try ScrollWMConfig.parse(jsonc: ScrollWMConfig.defaultFileContents)
            check("default file matches code defaults", fromFile == ScrollWMConfig.default)
        } catch {
            check("default file parses", false)
        }

        // --- Off-screen parking: fully-offscreen columns collapse to a corner ---
        // macOS clamps positions to keep ~40px on screen, so columns scrolled
        // fully past the viewport must be parked at a shared corner instead of
        // leaving stacked slivers along the edge. The corner now mirrors the
        // SIDE the column scrolled off (off-left -> left edge, off-right ->
        // right edge) so the nub appears where the content went.
        let ep = makeEngine(count: 3, width: 400, screenWidth: 1000)
        // Slot fully within the viewport -> natural strip position.
        ep.setViewportXForTest(0)
        let inView = ep.slots[0] // canvasX=0,w=400 -> [0,400) visible
        let inTarget = ep.onScreenTarget(for: inView)
        check("in-view column placed at natural position",
              abs(inTarget.x - (ep.screenFrame.origin.x + inView.canvasX - ep.viewportX)) < 0.5)
        // A column scrolled fully off the RIGHT parks at the right corner.
        var off = ep.slots[1]
        off.canvasX = 5000 // far right of any viewport
        let offTarget = ep.onScreenTarget(for: off)
        check("fully-offscreen-right column parks at right corner",
              offTarget == ep.parkingPoint(prefer: .right))
        // A column scrolled fully off the LEFT parks at the LEFT corner (the new
        // directional behavior: it is on the opposite side from the right park).
        var offL = ep.slots[1]
        offL.canvasX = 0
        offL.width = 100
        ep.setViewportXForTest(5000) // viewport far right -> column at [0,100) is off-left
        check("fully-offscreen-left column parks at left corner",
              ep.onScreenTarget(for: offL) == ep.parkingPoint(prefer: .left))
        check("left and right park corners differ (single display)",
              ep.parkingPoint(prefer: .left) != ep.parkingPoint(prefer: .right))
        // A partially-visible column (last column overflowing right) is NOT parked.
        ep.setViewportXForTest(0)
        var partial = ep.slots[1]
        partial.canvasX = 900 // [900,1300), viewport [0,1000): partly visible
        partial.width = 400
        check("partially-visible column is not parked",
              ep.onScreenTarget(for: partial) != ep.parkingPoint(prefer: .left)
                  && ep.onScreenTarget(for: partial) != ep.parkingPoint(prefer: .right))

        // --- Display-aware parking corner (multi-monitor "peeking" fix) -------
        // macOS clamps a window to keep ~40px on screen, so a parked column
        // always leaves one sliver. The corner must be chosen so that sliver
        // lands on the STRIP's OWN display, on an edge with no neighbor monitor,
        // instead of peeking onto an adjacent screen.
        let mainDisp = CGRect(x: 0, y: 0, width: 1470, height: 956)

        // Single display: legacy behavior (push past bottom-right corner).
        do {
            let p = TeleportEngine.computeParkingPoint(stripDisplay: mainDisp, others: [], margin: 4000)
            check("park single-display: bottom-right corner",
                  p == CGPoint(x: 1470 + 4000, y: 956 + 4000))
        }

        // External display to the RIGHT (user's real setup): the right edge is
        // blocked, so park toward the LEFT so the sliver stays on the built-in.
        do {
            let ext = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
            let p = TeleportEngine.computeParkingPoint(stripDisplay: mainDisp, others: [ext], margin: 4000)
            check("park external-right: goes left (off-strip-display, away from neighbor)",
                  p.x == mainDisp.minX - 4000)
            check("park external-right: vertical stays bottom (free edge)",
                  p.y == mainDisp.maxY + 4000)
            // The resulting corner must NOT be inside/toward the external display.
            check("park external-right: x is left of the external screen",
                  p.x < ext.minX)
        }

        // External display to the LEFT: left edge blocked -> park toward RIGHT.
        do {
            let leftExt = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
            let p = TeleportEngine.computeParkingPoint(stripDisplay: mainDisp, others: [leftExt], margin: 4000)
            check("park external-left: goes right", p.x == mainDisp.maxX + 4000)
        }

        // Display directly BELOW (stacked): bottom blocked -> park toward TOP.
        do {
            let below = CGRect(x: 0, y: 956, width: 1470, height: 900)
            let p = TeleportEngine.computeParkingPoint(stripDisplay: mainDisp, others: [below], margin: 4000)
            check("park display-below: goes up", p.y == mainDisp.minY - 4000)
            check("park display-below: x stays right (free)", p.x == mainDisp.maxX + 4000)
        }

        // Diagonally-offset display does NOT block a straight push: a screen at
        // the bottom-right corner only overlaps diagonally, so the legacy
        // bottom-right corner is still fine (no perpendicular-axis overlap).
        do {
            let diag = CGRect(x: 1470, y: 956, width: 800, height: 600)
            let p = TeleportEngine.computeParkingPoint(stripDisplay: mainDisp, others: [diag], margin: 4000)
            check("park diagonal neighbor: still bottom-right (no axis overlap)",
                  p == CGPoint(x: 1470 + 4000, y: 956 + 4000))
        }

        // Hemmed in on both horizontal sides: fall back to legacy right.
        do {
            let l = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
            let r = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
            let p = TeleportEngine.computeParkingPoint(stripDisplay: mainDisp, others: [l, r], margin: 4000)
            check("park hemmed both sides: legacy right fallback", p.x == mainDisp.maxX + 4000)
        }

        // --- Directional parking: honor the side a column scrolled off --------
        // Single display: off-left parks to the LEFT edge, off-right to the
        // RIGHT edge, so the nub appears on the side the content disappeared.
        do {
            let pl = TeleportEngine.computeParkingPoint(stripDisplay: mainDisp, others: [], prefer: .left, margin: 4000)
            let pr = TeleportEngine.computeParkingPoint(stripDisplay: mainDisp, others: [], prefer: .right, margin: 4000)
            check("directional park: left side goes to left edge", pl.x == mainDisp.minX - 4000)
            check("directional park: right side goes to right edge", pr.x == mainDisp.maxX + 4000)
            check("directional park: sides differ", pl.x != pr.x)
        }

        // A neighbor on the requested side forces a flip to the free edge so the
        // sliver never peeks onto that neighbor: with a display to the RIGHT, a
        // column scrolled off the right must park LEFT (the only free edge).
        do {
            let ext = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
            let p = TeleportEngine.computeParkingPoint(stripDisplay: mainDisp, others: [ext], prefer: .right, margin: 4000)
            check("directional park: right blocked flips to free left edge",
                  p.x == mainDisp.minX - 4000)
        }
        // Symmetric: a display to the LEFT forces an off-left park to flip RIGHT.
        do {
            let leftExt = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
            let p = TeleportEngine.computeParkingPoint(stripDisplay: mainDisp, others: [leftExt], prefer: .left, margin: 4000)
            check("directional park: left blocked flips to free right edge",
                  p.x == mainDisp.maxX + 4000)
        }
        // Both sides blocked: respect the caller's preferred side (unavoidable).
        do {
            let l = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
            let r = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
            let pl = TeleportEngine.computeParkingPoint(stripDisplay: mainDisp, others: [l, r], prefer: .left, margin: 4000)
            let pr = TeleportEngine.computeParkingPoint(stripDisplay: mainDisp, others: [l, r], prefer: .right, margin: 4000)
            check("directional park: both blocked keeps preferred left", pl.x == mainDisp.minX - 4000)
            check("directional park: both blocked keeps preferred right", pr.x == mainDisp.maxX + 4000)
        }

        // --- ResyncPlanner: Space-aware adoption/removal policy ---

        // Nothing managed yet, two windows on the current Space -> adopt both.
        check("planner adopts current-Space windows on empty strip",
              ResyncPlanner.decide(stripIDs: [], axIDs: [1, 2], currentSpaceIDs: [1, 2])
                == .apply(remove: [], add: [1, 2]))

        // Strip on current Space; a NEW window appears on ANOTHER Space (in AX
        // but not on-screen). It must NOT be adopted (the core bug fix).
        check("planner ignores new window on another Space",
              ResyncPlanner.decide(stripIDs: [1], axIDs: [1, 2], currentSpaceIDs: [1])
                == .apply(remove: [], add: []))

        // Strip on current Space; a new window opens ON the current Space ->
        // adopt only that one, not the other-Space window (id 3).
        check("planner adopts only current-Space additions",
              ResyncPlanner.decide(stripIDs: [1], axIDs: [1, 2, 3], currentSpaceIDs: [1, 2])
                == .apply(remove: [], add: [2]))

        // User switched to a Space with none of the managed windows -> freeze.
        check("planner freezes on a different Space",
              ResyncPlanner.decide(stripIDs: [1, 2], axIDs: [1, 2, 9], currentSpaceIDs: [9])
                == .frozenDifferentSpace)

        // While frozen, windows on the other Space are NOT removed even though
        // they are absent from currentSpaceIDs (they still exist in AX).
        check("planner does not drop strip windows while on another Space",
              ResyncPlanner.decide(stripIDs: [1, 2], axIDs: [1, 2], currentSpaceIDs: [7])
                == .frozenDifferentSpace)

        // A genuinely-closed window (gone from AX) on the current Space is
        // removed; sentinel -1 models "no longer in AX".
        check("planner removes closed window",
              ResyncPlanner.decide(stripIDs: [1, -1], axIDs: [1], currentSpaceIDs: [1])
                == .apply(remove: [-1], add: []))

        // Degradation guard: >50% of a 4+ window strip vanished from AX at once
        // -> skip rather than mass-remove. Here 3 of 4 are gone.
        check("planner skips on AX degradation",
              ResyncPlanner.decide(stripIDs: [1, -2, -3, -4], axIDs: [1], currentSpaceIDs: [1])
                == .skipDegraded)

        // Exactly 50% missing on a 4-window strip is NOT degradation -> apply.
        check("planner applies at exactly 50% missing",
              ResyncPlanner.decide(stripIDs: [1, 2, -3, -4], axIDs: [1, 2], currentSpaceIDs: [1, 2])
                == .apply(remove: [-3, -4], add: []))

        // Small strips never trip the degradation guard (count < 4).
        check("planner removes from small strip without degradation skip",
              ResyncPlanner.decide(stripIDs: [-1, -2], axIDs: [], currentSpaceIDs: [])
                == .apply(remove: [-1, -2], add: []))

        // Simultaneous removal (closed) + addition (new on current Space).
        check("planner handles concurrent remove+add",
              ResyncPlanner.decide(stripIDs: [1, -2], axIDs: [1, 3], currentSpaceIDs: [1, 3])
                == .apply(remove: [-2], add: [3]))

        // --- Accessibility prompt policy -------------------------------------
        // The macOS system modal must auto-fire ONLY on a genuine first run.
        // This is the guard against "ScrollWM keeps asking to turn on
        // Accessibility" when it is already enabled.
        check("autoprompt: genuine first run (untrusted, never asked) -> prompt",
              AccessibilityPermission.shouldAutoPrompt(isTrusted: false, hasPrompted: false) == true)
        check("autoprompt: already trusted -> never prompt (even if not yet asked)",
              AccessibilityPermission.shouldAutoPrompt(isTrusted: true, hasPrompted: false) == false)
        check("autoprompt: already trusted + asked before -> never prompt",
              AccessibilityPermission.shouldAutoPrompt(isTrusted: true, hasPrompted: true) == false)
        check("autoprompt: untrusted but asked before -> never re-prompt (deep-link instead)",
              AccessibilityPermission.shouldAutoPrompt(isTrusted: false, hasPrompted: true) == false)

        // --- App launch-location policy (translocation / transient homes) ----
        // PURE classification that drives "move me to ~/Applications so the
        // Accessibility grant sticks". The whole point is to kill the silent
        // onboarding cliff where a granted switch does nothing.
        let home = "/Users/tester"
        func loc(_ path: String, app: Bool = true) -> AppLocation.Kind {
            AppLocation.classify(bundlePath: path, isAppBundle: app, homeDir: home)
        }
        // The dev/CLI binary is never relocated.
        check("location: non-.app is devBinary",
              loc("/Users/tester/scrollwm/.build/debug/WindowLab", app: false) == .devBinary)
        // Gatekeeper translocation ghost -> must relocate (grant can't stick).
        check("location: AppTranslocation ghost -> translocated",
              loc("/private/var/folders/aa/bb/X/d/AppTranslocation/UUID/d/ScrollWM.app") == .translocated)
        // Stable installs run in place.
        check("location: ~/Applications -> installed",
              loc("/Users/tester/Applications/ScrollWM.app") == .installed)
        check("location: /Applications -> installed",
              loc("/Applications/ScrollWM.app") == .installed)
        // Transient homes are offered relocation.
        check("location: mounted .dmg (/Volumes) -> removableOrTemporary",
              loc("/Volumes/ScrollWM 0.2.0/ScrollWM.app") == .removableOrTemporary)
        check("location: ~/Downloads -> removableOrTemporary",
              loc("/Users/tester/Downloads/ScrollWM.app") == .removableOrTemporary)
        check("location: ~/Desktop -> removableOrTemporary",
              loc("/Users/tester/Desktop/ScrollWM.app") == .removableOrTemporary)
        // A deliberate custom location is left alone (no nag).
        check("location: custom dir -> otherLocation",
              loc("/Users/tester/dev/ScrollWM.app") == .otherLocation)
        // Only translocated + transient offer relocation.
        check("location: translocated offers relocation",
              AppLocation.Kind.translocated.shouldOfferRelocation == true)
        check("location: removableOrTemporary offers relocation",
              AppLocation.Kind.removableOrTemporary.shouldOfferRelocation == true)
        check("location: installed does NOT offer relocation",
              AppLocation.Kind.installed.shouldOfferRelocation == false)
        check("location: otherLocation does NOT offer relocation",
              AppLocation.Kind.otherLocation.shouldOfferRelocation == false)
        check("location: devBinary does NOT offer relocation",
              AppLocation.Kind.devBinary.shouldOfferRelocation == false)
        // Destination + path helpers.
        check("location: destination is ~/Applications/<name>",
              AppLocation.destination(forBundleNamed: "ScrollWM.app", homeDir: home)
                == "/Users/tester/Applications/ScrollWM.app")
        check("location: isUnder treats dir itself as inside",
              AppLocation.isUnder("/Applications", dir: "/Applications") == true)
        check("location: isUnder matches nested, not sibling prefixes",
              AppLocation.isUnder("/Applications/ScrollWM.app", dir: "/Applications") == true
                && AppLocation.isUnder("/ApplicationsX/ScrollWM.app", dir: "/Applications") == false)
        check("location: trailing slash on home is normalized",
              AppLocation.classify(bundlePath: "/Users/tester/Applications/ScrollWM.app",
                                   isAppBundle: true, homeDir: "/Users/tester/") == .installed)

        // MARK: - CLI width parsing (scrollwm width <arg>)
        // Accepts percents (25/50/75/100) and fractions (0.0-1.0); rejects junk.
        func widthApprox(_ s: String, _ want: CGFloat) -> Bool {
            guard let f = ScrollWMController.parseWidthFraction(s) else { return false }
            return abs(f - want) < 0.0001
        }
        check("width parse: '50' -> 0.5", widthApprox("50", 0.5))
        check("width parse: '100' -> 1.0", widthApprox("100", 1.0))
        check("width parse: '25' -> 0.25", widthApprox("25", 0.25))
        check("width parse: '0.5' -> 0.5", widthApprox("0.5", 0.5))
        check("width parse: '1' -> 1.0 (treated as fraction)", widthApprox("1", 1.0))
        check("width parse: '0' rejected", ScrollWMController.parseWidthFraction("0") == nil)
        check("width parse: '150' rejected (>100%)", ScrollWMController.parseWidthFraction("150") == nil)
        check("width parse: 'abc' rejected", ScrollWMController.parseWidthFraction("abc") == nil)
        check("width parse: '-25' rejected", ScrollWMController.parseWidthFraction("-25") == nil)

        // --- fitAllColumns: equalize every column to fit on screen ---
        // Equal-share width is exactly width(forFraction: 1/count), so N columns
        // tile the viewport with symmetric gaps. After fit, the strip is compact,
        // the viewport is reset to the origin, and (for counts that fit above the
        // min width) the last column ends one gap short of the screen edge.
        let efit = makeEngine(count: 4, width: 700, screenWidth: 1600)
        efit.focusIndex = 2
        efit.setViewportXForTest(5000) // pretend we'd scrolled far away
        let shareW = efit.equalShareWidth(count: 4)
        check("equalShareWidth == width(1/4)", abs(shareW - efit.width(forFraction: 0.25)) < 0.5)
        efit.fitAllColumns()
        check("fitAll: every column equalized to share width",
              efit.slots.allSatisfy { abs($0.width - shareW) < 0.5 })
        check("fitAll: strip stays compact", isCompact(efit))
        check("fitAll: viewport reset to origin", efit.viewportX == 0)
        let lastFit = efit.slots.last!
        check("fitAll: last column ends one gap short of the screen edge",
              abs((lastFit.canvasX + lastFit.width) - (efit.screenFrame.width - efit.gap)) < 1.0)

        // fitAllColumns on an empty strip is a harmless no-op.
        let efitEmpty = makeEngine(count: 0)
        efitEmpty.fitAllColumns()
        check("fitAll on empty strip is a no-op", efitEmpty.slots.isEmpty)

        // Too many windows to fit: columns floor at minColumnWidth (never zero).
        let efitMany = makeEngine(count: 50, width: 300, screenWidth: 1600)
        efitMany.fitAllColumns()
        check("fitAll: crowded strip floors at minColumnWidth",
              efitMany.slots.allSatisfy { $0.width >= efitMany.minColumnWidth - 0.5 })

        // --- FloatingWindows.classify (pure floating-window policy) ---
        let std = kAXStandardWindowSubrole as String
        let dlg = kAXDialogSubrole as String
        // A normal current-Space window not on the strip is tileable floating.
        check("classify: standard current-Space -> tileable",
              FloatingWindows.classify(subrole: std, isMinimized: false, isFullscreen: false,
                                       onCurrentSpace: true, isSelf: false) == .tileable)
        // A dialog is listed but not tileable.
        check("classify: dialog current-Space -> listOnly",
              FloatingWindows.classify(subrole: dlg, isMinimized: false, isFullscreen: false,
                                       onCurrentSpace: true, isSelf: false) == .listOnly)
        // Off-Space windows are never floating "here".
        check("classify: off-Space -> nil",
              FloatingWindows.classify(subrole: std, isMinimized: false, isFullscreen: false,
                                       onCurrentSpace: false, isSelf: false) == nil)
        // Minimized / fullscreen / our own windows are excluded.
        check("classify: minimized -> nil",
              FloatingWindows.classify(subrole: std, isMinimized: true, isFullscreen: false,
                                       onCurrentSpace: true, isSelf: false) == nil)
        check("classify: fullscreen -> nil",
              FloatingWindows.classify(subrole: std, isMinimized: false, isFullscreen: true,
                                       onCurrentSpace: true, isSelf: false) == nil)
        check("classify: self window -> nil",
              FloatingWindows.classify(subrole: std, isMinimized: false, isFullscreen: false,
                                       onCurrentSpace: true, isSelf: true) == nil)
        // Unknown subrole (content view, sheet, nil) is not surfaced.
        check("classify: unknown subrole -> nil",
              FloatingWindows.classify(subrole: "AXUnknown", isMinimized: false, isFullscreen: false,
                                       onCurrentSpace: true, isSelf: false) == nil)
        check("classify: nil subrole -> nil",
              FloatingWindows.classify(subrole: nil, isMinimized: false, isFullscreen: false,
                                       onCurrentSpace: true, isSelf: false) == nil)

        // --- FloatingWindows.compute (end-to-end over synthetic AX+CG) ---
        // Build three AX windows for one fake app: a tiled one (already on the
        // strip), an untiled normal one (should surface as tileable floating),
        // and a dialog (should surface as list-only). Each gets a matching CG
        // entry so the current-Space fuse succeeds.
        func ax(_ pidBase: Int, _ sub: String, _ rect: CGRect, title: String) -> AXWindowInfo {
            AXWindowInfo(
                pid: pid_t(pidBase), appName: "FloatApp", element: AXUIElementCreateApplication(pid_t(pidBase)),
                title: title, role: kAXWindowRole as String, subrole: sub,
                frame: rect, isMinimized: false, isFullscreen: false
            )
        }
        func cg(_ pidBase: Int, _ rect: CGRect, title: String) -> CGWindowInfo {
            CGWindowInfo(
                windowID: CGWindowID(pidBase), ownerPID: pid_t(pidBase), ownerName: "FloatApp",
                title: title, bounds: rect, layer: 0, alpha: 1.0, isOnscreen: true, memoryUsage: 0
            )
        }
        let stdSub = kAXStandardWindowSubrole as String
        let dlgSub = kAXDialogSubrole as String
        let tiled  = ax(70001, stdSub, CGRect(x: 0,   y: 0, width: 400, height: 300), title: "Tiled")
        let normal = ax(70002, stdSub, CGRect(x: 500, y: 0, width: 400, height: 300), title: "Untiled")
        let dialog = ax(70003, dlgSub, CGRect(x: 900, y: 0, width: 300, height: 200), title: "Save?")
        // An off-Space window: present in AX, but NO matching CG entry.
        let offspace = ax(70004, stdSub, CGRect(x: 50, y: 900, width: 400, height: 300), title: "OtherSpace")
        let cgList = [
            cg(70001, tiled.frame, title: "Tiled"),
            cg(70002, normal.frame, title: "Untiled"),
            cg(70003, dialog.frame, title: "Save?"),
            // no CG for offspace -> not on current Space
        ]
        let floating = FloatingWindows.compute(
            axWindows: [tiled, normal, dialog, offspace],
            cgWindows: cgList,
            managed: [tiled.element],   // `tiled` is on the strip
            selfPID: 99999              // none of these are us
        )
        check("compute: tiled window excluded", !floating.contains { CFEqual($0.element, tiled.element) })
        check("compute: off-Space window excluded", !floating.contains { CFEqual($0.element, offspace.element) })
        check("compute: untiled normal surfaces as tileable",
              floating.contains { CFEqual($0.element, normal.element) && $0.canTile })
        check("compute: dialog surfaces as list-only",
              floating.contains { CFEqual($0.element, dialog.element) && !$0.canTile })
        check("compute: exactly 2 floating windows", floating.count == 2)
        // Our own windows are never listed even if untiled + on current Space.
        let mine = FloatingWindows.compute(
            axWindows: [normal], cgWindows: [cg(70002, normal.frame, title: "Untiled")],
            managed: [], selfPID: 70002
        )
        check("compute: self windows never floating", mine.isEmpty)

        // --- Vertical workspaces (niri-style) ------------------------------
        // AX position writes on synthetic elements fail harmlessly, so we only
        // assert on the engine's model: which windows live in which workspace,
        // the active index, and that switching preserves/moves columns.

        // A fresh engine has exactly one workspace, active index 0.
        let ew0 = makeEngine(count: 3)
        check("workspaces: start with 1 workspace", ew0.workspaceCount == 1)
        check("workspaces: start active index 0", ew0.stripState.activeWorkspace == 0)

        // Switching DOWN from a non-empty workspace creates a new empty one and
        // moves there; the old strip's windows leave the live `slots`.
        let ew1 = makeEngine(count: 3)
        let titles0 = ew1.slots.map { $0.window.title }
        ew1.switchWorkspace(by: 1)
        check("workspaces: switch down creates workspace 2", ew1.workspaceCount == 2)
        check("workspaces: now on workspace index 1", ew1.stripState.activeWorkspace == 1)
        check("workspaces: new workspace is empty", ew1.slots.isEmpty)

        // Switching back UP returns to the original strip intact.
        ew1.switchWorkspace(by: -1)
        check("workspaces: switch up returns to workspace 0", ew1.stripState.activeWorkspace == 0)
        check("workspaces: original 3 columns restored", ew1.slots.count == 3)
        check("workspaces: original column order preserved",
              ew1.slots.map { $0.window.title } == titles0)

        // The empty trailing workspace we created but left is pruned away.
        check("workspaces: trailing empty workspace pruned", ew1.workspaceCount == 1)

        // Switching up at the top edge is a no-op (no workspace above index 0).
        let ewTop = makeEngine(count: 2)
        ewTop.switchWorkspace(by: -1)
        check("workspaces: switch up at top is a no-op", ewTop.stripState.activeWorkspace == 0)
        check("workspaces: no-op did not add a workspace", ewTop.workspaceCount == 1)

        // Switching down from an EMPTY workspace is a no-op (no blank stacking).
        let ewEmpty = makeEngine(count: 0)
        ewEmpty.switchWorkspace(by: 1)
        check("workspaces: switch down from empty is a no-op", ewEmpty.workspaceCount == 1)

        // moveFocusedToWorkspace: send the focused column down and follow it.
        let ewMove = makeEngine(count: 3)
        ewMove.focusIndex = 1
        let movedTitle = ewMove.slots[1].window.title
        let okMove = ewMove.moveFocusedToWorkspace(by: 1)
        check("workspaces: moveFocusedToWorkspace returns true", okMove)
        check("workspaces: followed window down to workspace 1", ewMove.stripState.activeWorkspace == 1)
        check("workspaces: destination has just the moved window", ewMove.slots.count == 1)
        check("workspaces: destination column is the moved one",
              ewMove.slots.first?.window.title == movedTitle)
        // The source workspace lost exactly that column.
        ewMove.switchWorkspace(by: -1)
        check("workspaces: source workspace now has 2 columns", ewMove.slots.count == 2)
        check("workspaces: moved column gone from source",
              !ewMove.slots.contains { $0.window.title == movedTitle })

        // moveFocusedToWorkspace up off the top edge is a no-op.
        let ewMoveTop = makeEngine(count: 2)
        check("workspaces: move up at top edge is a no-op",
              ewMoveTop.moveFocusedToWorkspace(by: -1) == false)
        check("workspaces: failed move kept both columns", ewMoveTop.slots.count == 2)

        // --- REGRESSION (fuzz seed 12345): overshooting workspace switch/move ---
        // A jump of |delta| >= 2 past the last workspace used to append exactly
        // ONE trailing workspace but then index at `activeWorkspace + delta`,
        // which is STILL out of range -> a hard `Index out of range` trap.
        // niri keeps only one trailing empty workspace, so an overshoot must
        // clamp to that single new workspace, never crash.
        let ewOver = makeEngine(count: 2)
        let ovTitles = ewOver.slots.map { $0.window.title }
        let ovEnded = ewOver.switchWorkspace(by: 3)   // from ws0 (only ws); used to TRAP
        check("workspaces: switch down by 3 does not crash and lands on ws1",
              ovEnded == 1 && ewOver.activeWorkspace == 1)
        check("workspaces: overshoot switch created exactly one trailing workspace",
              ewOver.workspaceCount == 2)
        check("workspaces: overshoot switch destination is empty", ewOver.slots.isEmpty)
        ewOver.switchWorkspace(by: -5)                // overshoot UP clamps to the top
        check("workspaces: overshoot up clamps to ws0", ewOver.activeWorkspace == 0)
        check("workspaces: overshoot up restored the original columns",
              ewOver.slots.map { $0.window.title } == ovTitles)

        // moveFocusedToWorkspace with the same overshoot also must not trap.
        let ewMoveOver = makeEngine(count: 2)
        ewMoveOver.focusIndex = 0
        let movedOverTitle = ewMoveOver.slots[0].window.title
        let okOver = ewMoveOver.moveFocusedToWorkspace(by: 4)  // used to TRAP
        check("workspaces: move-to-workspace by 4 does not crash", okOver)
        check("workspaces: overshoot move landed on a single new trailing workspace",
              ewMoveOver.activeWorkspace == 1 && ewMoveOver.workspaceCount == 2)
        check("workspaces: overshoot move carried the focused column",
              ewMoveOver.slots.count == 1 && ewMoveOver.slots.first?.window.title == movedOverTitle)

        // --- REGRESSION (state-space, shortest path 1 op): moving the LAST
        // window out of a workspace must collapse the now-empty SOURCE, even
        // when it is not the trailing workspace. The old prune only trimmed the
        // tail, so `moveFocusedToWorkspace(by:1)` from a single-window strip left
        // a phantom empty workspace ABOVE the active one ([empty, populated]).
        let ewPhantom = makeEngine(count: 1)        // ws0 = [one window]
        ewPhantom.focusIndex = 0
        ewPhantom.moveFocusedToWorkspace(by: 1)     // move that lone window down
        check("workspaces: emptied source workspace collapses (no phantom)",
              ewPhantom.workspaceCount == 1)
        check("workspaces: active index valid after source collapse",
              ewPhantom.activeWorkspace == 0
                && ewPhantom.activeWorkspace < ewPhantom.workspaceCount)
        check("workspaces: the moved window survived the collapse",
              ewPhantom.slots.count == 1)

        // Same bug via a 3-workspace stack: empty a MIDDLE workspace and confirm
        // it collapses (no empty workspace wedged between two populated ones).
        // Build [a][b] then move b down to its own workspace, then move a down
        // into b's, leaving the middle empty; it must not persist.
        let ewMid2 = makeEngine(count: 2)           // ws0 = [a, b]
        ewMid2.focusIndex = 1
        ewMid2.moveFocusedToWorkspace(by: 1)        // ws0=[a], ws1=[b] (active ws1)
        ewMid2.focusIndex = 0
        ewMid2.moveFocusedToWorkspace(by: 1)        // move b down again: ws1 emptied
        check("workspaces: no empty workspace wedged between populated ones",
              (0..<ewMid2.workspaceCount).allSatisfy { i in
                  i == ewMid2.activeWorkspace || !ewMid2.allManagedSlots.isEmpty
              } && ewMid2.workspaceCount >= 1)
        // Stronger structural check: at most ONE empty workspace and only if active.
        do {
            // Reconstruct per-workspace emptiness via allManagedSlots + active.
            // After the moves every non-active workspace must be non-empty.
            let snap = ewMid2.workspacesSnapshot
            let badEmpty = snap.workspaces.enumerated().contains { (i, w) in
                w.ids.isEmpty && i != snap.activeWorkspace
            }
            check("workspaces: no non-active empty workspace after middle-empty", !badEmpty)
        }

        // allManagedSlots + isManaged span every workspace (used by restore +
        // lifecycle so parked windows are never lost or re-adopted).
        let ewSpan = makeEngine(count: 2)
        let keepEl = ewSpan.slots[0].window.element
        ewSpan.focusIndex = 0
        ewSpan.moveFocusedToWorkspace(by: 1)     // now on ws1 with 1 window
        check("workspaces: allManagedSlots spans both workspaces", ewSpan.allManagedSlots.count == 2)
        check("workspaces: isManaged finds a parked window", ewSpan.isManaged(keepEl))
        let strangerEl = AXUIElementCreateApplication(pid_t(12345))
        check("workspaces: isManaged false for unmanaged element", !ewSpan.isManaged(strangerEl))

        // focusWorkspace jumps directly to an index (clamped) and releaseAll
        // resets the whole stack to a single workspace.
        let ewJump = makeEngine(count: 1)
        ewJump.switchWorkspace(by: 1)            // ws0 has 1 window -> creates ws1
        check("workspaces: focusWorkspace clamps high index",
              ewJump.focusWorkspace(99) == ewJump.workspaceCount - 1)
        ewJump.releaseAll()
        check("workspaces: releaseAll resets to single workspace", ewJump.workspaceCount == 1)
        check("workspaces: releaseAll resets active index", ewJump.stripState.activeWorkspace == 0)

        // --- DisplayGeometry: pure coordinate + clamp helpers ----------------
        // The user's REAL setup: built-in primary 1470x956 at AppKit (0,0); a
        // taller external 2560x1440 at AppKit (-225, 956) ABOVE the built-in.
        let primaryH: CGFloat = 956

        // AppKit (bottom-left) -> AX (top-left). The primary sits at AX y=0.
        let builtinAX = DisplayGeometry.axFrame(
            appKitFrame: CGRect(x: 0, y: 0, width: 1470, height: 956), primaryHeight: primaryH)
        check("geom: primary maps to AX origin", builtinAX == CGRect(x: 0, y: 0, width: 1470, height: 956))
        // The external is ABOVE the primary in AppKit (y=956); in the top-left
        // AX plane that becomes a NEGATIVE y (above the origin), with its own
        // negative x carried through unchanged.
        let extAX = DisplayGeometry.axFrame(
            appKitFrame: CGRect(x: -225, y: 956, width: 2560, height: 1440), primaryHeight: primaryH)
        check("geom: external-above maps to negative AX y",
              extAX == CGRect(x: -225, y: -1440, width: 2560, height: 1440))
        // Round-trip back to AppKit is exact.
        check("geom: axFrame round-trips",
              DisplayGeometry.appKitFrame(axFrame: extAX, primaryHeight: primaryH)
                == CGRect(x: -225, y: 956, width: 2560, height: 1440))

        let displays = [builtinAX, extAX]
        // A window centered on the external overlaps it most.
        check("geom: best-overlap picks the external",
              DisplayGeometry.display(bestOverlapping:
                CGRect(x: 100, y: -1200, width: 800, height: 600), displays: displays) == extAX)
        // A window straddling the bezel goes to whichever it covers more of.
        check("geom: best-overlap resolves a straddling window",
              DisplayGeometry.display(bestOverlapping:
                CGRect(x: 0, y: -200, width: 600, height: 600), displays: displays) != nil)
        check("geom: no displays -> nil overlap",
              DisplayGeometry.display(bestOverlapping: builtinAX, displays: []) == nil)

        // Visibility: a frame fully on a display is visible; one parked far away
        // (e.g. its monitor was unplugged) is not.
        check("geom: on-display frame is visible",
              DisplayGeometry.isMostlyVisible(CGRect(x: 50, y: 50, width: 400, height: 300), on: displays))
        check("geom: orphaned frame is not visible",
              !DisplayGeometry.isMostlyVisible(CGRect(x: 9000, y: 9000, width: 400, height: 300), on: displays))

        // ensureVisible leaves an on-screen frame untouched but pulls an orphan
        // back onto an available display (and never larger than that display).
        let keep = CGRect(x: 100, y: 100, width: 400, height: 300)
        check("geom: ensureVisible keeps an on-screen frame",
              DisplayGeometry.ensureVisible(keep, displays: displays) == keep)
        let rescued = DisplayGeometry.ensureVisible(
            CGRect(x: 9000, y: 9000, width: 400, height: 300), displays: displays)
        check("geom: ensureVisible rescues an orphan onto a display",
              DisplayGeometry.isMostlyVisible(rescued, on: displays))
        // A window larger than the target display is shrunk to fit it.
        let huge = DisplayGeometry.clamp(
            CGRect(x: 9000, y: 9000, width: 5000, height: 5000), into: builtinAX)
        check("geom: clamp shrinks an oversize window to the display",
              huge.width <= builtinAX.width && huge.height <= builtinAX.height
                && builtinAX.contains(huge))

        // --- TeleportEngine.rebindStripDisplay: relay onto new geometry ------
        // Strip built on a 1600-wide display; rebind to a different display
        // (origin shifted, shorter) and verify the model follows: slots re-pin
        // their top Y, heights clamp to the new usable height, screenFrame moves.
        let reb = makeEngine(count: 3, width: 400, screenWidth: 1600)
        for i in reb.slots.indices { reb.slots[i].height = 900 }  // tall windows
        let newFrame = CGRect(x: -225, y: -1440, width: 2560, height: 700)
        reb.rebindStripDisplay(to: newFrame)
        check("rebind: screenFrame updated", reb.screenFrame == newFrame)
        check("rebind: slots re-pinned to new display top",
              reb.slots.allSatisfy { $0.y == newFrame.origin.y })
        check("rebind: tall slots clamped to new usable height",
              reb.slots.allSatisfy { $0.height <= newFrame.height })
        check("rebind: canvas X packing preserved (strip not torn up)",
              reb.slots.map { $0.canvasX } == StripOpsTests.makeEngine(count: 3, width: 400).slots.map { $0.canvasX })
        // A no-op rebind to the same frame keeps everything put.
        let reb2 = makeEngine(count: 2)
        let before = reb2.screenFrame
        reb2.rebindStripDisplay(to: before)
        check("rebind: same-frame rebind is stable", reb2.screenFrame == before)

        // DORMANT rebind ([md-hotplug]): a strip with NO adopted windows (the
        // dormant state) must still update `screenFrame` when its display's
        // geometry changes, so the NEXT arrange lands on the display's CURRENT
        // frame instead of a stale (unplugged/resized) one. This is the engine
        // guarantee `refreshDisplayGeometry` relies on now that it rebinds even
        // while dormant. The relay issues zero AX writes (no windows).
        let dormant = TeleportEngine(screenFrame: CGRect(x: -225, y: -1440, width: 2560, height: 1440))
        let migratedFrame = CGRect(x: 0, y: 0, width: 1470, height: 923)
        let writes = dormant.rebindStripDisplay(to: migratedFrame)
        check("rebind: dormant (empty) strip still adopts the new screenFrame",
              dormant.screenFrame == migratedFrame)
        check("rebind: dormant rebind issues no AX writes (no windows)", writes == 0)

        // --- StripDisplayResolver: hotplug strip-migration policy ------------
        // Pure decision for "which display does the strip bind to after a
        // monitor plug/unplug?". AX top-left plane; mirrors the user's real rig:
        // built-in primary at AX (0,0,1470x956); external above-left at
        // (-225,-1440,2560x1440).
        let rBuiltin = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let rExternal = CGRect(x: -225, y: -1440, width: 2560, height: 1440)

        // Strip on the built-in, both displays present -> stay on the built-in
        // (its display is still here; bind to its current visible frame).
        do {
            let d = StripDisplayResolver.resolve(
                stripFrame: rBuiltin, displays: [rBuiltin, rExternal])
            check("resolver: strip display present -> same display",
                  d.frame == rBuiltin && d.displayIndex == 0 && !d.migrated)
        }

        // Strip on the EXTERNAL, then the external is UNPLUGGED (only built-in
        // survives) -> MIGRATE the strip to the built-in so its windows are
        // rescued instead of orphaned off-screen. This is the catastrophic case.
        do {
            let d = StripDisplayResolver.resolve(
                stripFrame: rExternal, displays: [rBuiltin])
            check("resolver: strip display gone -> migrate to survivor",
                  d.frame == rBuiltin && d.displayIndex == 0 && d.migrated)
        }

        // Strip display gone with SEVERAL survivors -> pick the largest by area
        // (most room for the strip), deterministically.
        do {
            let small = CGRect(x: 0, y: 0, width: 1000, height: 800)
            let big   = CGRect(x: 2000, y: 0, width: 2560, height: 1440)
            let d = StripDisplayResolver.resolve(
                stripFrame: rExternal, displays: [small, big])
            check("resolver: migrate picks the largest survivor",
                  d.frame == big && d.displayIndex == 1 && d.migrated)
        }

        // Strip display merely RESIZED (same origin region, dropped resolution)
        // -> recognized as the same screen and followed onto the new frame, NOT
        // treated as gone (no spurious migration).
        do {
            let resized = CGRect(x: 0, y: 0, width: 1280, height: 720)
            let d = StripDisplayResolver.resolve(
                stripFrame: rBuiltin, displays: [resized, rExternal])
            check("resolver: resized strip display is followed, not migrated",
                  d.frame == resized && d.displayIndex == 0 && !d.migrated)
        }

        // A display being ADDED back: strip is on the built-in, the external
        // reappears -> strip stays put (the new display is just a candidate).
        do {
            let d = StripDisplayResolver.resolve(
                stripFrame: rBuiltin, displays: [rBuiltin, rExternal])
            check("resolver: re-added display leaves the strip put",
                  d.frame == rBuiltin && !d.migrated)
        }

        // No displays at all (all monitors asleep): keep the last frame and
        // report no choice so the caller leaves the strip untouched.
        do {
            let d = StripDisplayResolver.resolve(stripFrame: rBuiltin, displays: [])
            check("resolver: no displays -> keep last frame, no index",
                  d.frame == rBuiltin && d.displayIndex == nil && !d.migrated)
        }

        // A strip stranded entirely off every display (its monitor vanished and
        // the survivor does not overlap at all) migrates to that survivor.
        do {
            let orphanStrip = CGRect(x: 9000, y: 9000, width: 1470, height: 956)
            let d = StripDisplayResolver.resolve(
                stripFrame: orphanStrip, displays: [rBuiltin])
            check("resolver: fully-orphaned strip migrates to the survivor",
                  d.frame == rBuiltin && d.migrated)
        }

        // Just below the overlap threshold counts as gone (migrate); just above
        // counts as present (follow). Use a 20% default: a survivor overlapping
        // 10% of the strip is "gone", one overlapping 30% is "present".
        do {
            let strip = CGRect(x: 0, y: 0, width: 1000, height: 1000) // area 1e6
            // Display overlaps a 100x1000 = 1e5 = 10% sliver -> gone.
            let sliver = CGRect(x: 900, y: 0, width: 1000, height: 1000)
            let dGone = StripDisplayResolver.resolve(stripFrame: strip, displays: [sliver])
            check("resolver: 10% overlap is below threshold -> migrate", dGone.migrated)
            // Display overlaps a 300x1000 = 3e5 = 30% region -> present.
            let chunk = CGRect(x: 700, y: 0, width: 1000, height: 1000)
            let dHere = StripDisplayResolver.resolve(stripFrame: strip, displays: [chunk])
            check("resolver: 30% overlap is above threshold -> follow", !dHere.migrated)
        }

        // --- StripDisplayResolver: STABLE DISPLAY IDENTITY ([md-hotplug]) -----
        // Geometry overlap alone is ambiguous on two real macOS hotplug events:
        //   (e) ARRANGEMENT SWAP: two displays exchange origins. The strip's
        //       OLD frame is now occupied by the OTHER physical monitor, so a
        //       pure-overlap resolver binds the strip to the WRONG screen.
        //   (d) BIG RESOLUTION/SCALE CHANGE: the strip's own display shrinks so
        //       much (or its visible frame shifts under a scale change) that the
        //       overlap with its NEW frame drops below threshold, and a pure
        //       overlap resolver spuriously MIGRATES off a display that is in
        //       fact still present.
        // When the caller supplies stable CGDirectDisplayIDs, the resolver must
        // track the strip's OWN display by identity and follow it, regardless of
        // how its geometry moved.
        let idBuiltin: CGDirectDisplayID = 1   // built-in panel
        let idExternal: CGDirectDisplayID = 2  // external monitor

        // (e) Arrangement swap: strip lives on the EXTERNAL (id 2) at its old
        // frame; the user swaps the two displays' origins so the BUILT-IN now
        // occupies the external's old region. Geometry says "bind to whatever is
        // at the old frame" (the built-in). Identity says "follow display 2 to
        // its NEW frame". Identity must win and it is NOT a migration (same
        // physical screen, just rearranged).
        do {
            let extOldFrame = rExternal                                  // (-225,-1440,2560,1440)
            let builtinNowHere = CGRect(x: -225, y: -1440, width: 1470, height: 956) // built-in moved into ext's spot
            let extNowThere    = CGRect(x: 0, y: 0, width: 2560, height: 1440)        // ext moved to the origin region
            let d = StripDisplayResolver.resolve(
                stripFrame: extOldFrame,
                displays:   [builtinNowHere, extNowThere],
                stripDisplayID: idExternal,
                displayIDs: [idBuiltin, idExternal])
            check("resolver: arrangement swap follows the strip's display by ID",
                  d.frame == extNowThere && d.displayIndex == 1 && !d.migrated)
        }

        // (d) Big resolution drop with NO overlap: the strip's display (id 2) is
        // still attached but its new visible frame no longer overlaps the old
        // one at all, AND a DIFFERENT display is the largest survivor. Pure
        // geometry would MIGRATE to that other display; identity recognizes id 2
        // as the SAME screen and follows it (no spurious migration).
        do {
            let extOld = rExternal                                         // (-225,-1440,2560,1440)
            let extResizedFar = CGRect(x: 4000, y: 0, width: 1280, height: 720) // moved far, zero overlap
            let d = StripDisplayResolver.resolve(
                stripFrame: extOld,
                displays:   [rBuiltin, extResizedFar],
                stripDisplayID: idExternal,
                displayIDs: [idBuiltin, idExternal])
            check("resolver: same display by ID is followed even with zero overlap",
                  d.frame == extResizedFar && d.displayIndex == 1 && !d.migrated)
        }

        // Strip's display id is GONE from the live id set (truly unplugged):
        // identity cannot find it, so we MIGRATE to the largest survivor exactly
        // as the geometry path would. Proves identity does not mask a real unplug.
        do {
            let d = StripDisplayResolver.resolve(
                stripFrame: rExternal,
                displays:   [rBuiltin],
                stripDisplayID: idExternal,
                displayIDs: [idBuiltin])
            check("resolver: strip display id absent -> migrate to survivor",
                  d.frame == rBuiltin && d.displayIndex == 0 && d.migrated)
        }

        // Defensive: malformed identity input (id count != display count) must
        // not crash or pick out of range; the resolver falls back to geometry.
        do {
            let d = StripDisplayResolver.resolve(
                stripFrame: rBuiltin,
                displays:   [rBuiltin, rExternal],
                stripDisplayID: idBuiltin,
                displayIDs: [idBuiltin])   // wrong length on purpose
            check("resolver: mismatched id array falls back to geometry safely",
                  d.frame == rBuiltin && d.displayIndex == 0 && !d.migrated)
        }

        // Identity supplied but the strip's own id is unknown (nil): behave like
        // the pure-geometry path (no identity to anchor on).
        do {
            let d = StripDisplayResolver.resolve(
                stripFrame: rBuiltin,
                displays:   [rBuiltin, rExternal],
                stripDisplayID: nil,
                displayIDs: [idBuiltin, idExternal])
            check("resolver: nil strip id falls back to geometry",
                  d.frame == rBuiltin && d.displayIndex == 0 && !d.migrated)
        }

        // (b) RE-PLUG: the strip lives on the built-in (id 1); the OTHER display
        // (the external) is unplugged and then re-plugged. After re-plug both
        // displays are present again; identity keeps the strip on id 1 (no
        // surprise jump onto the freshly-returned monitor).
        do {
            // External gone: only the built-in survives, strip stays on id 1.
            let gone = StripDisplayResolver.resolve(
                stripFrame: rBuiltin, displays: [rBuiltin],
                stripDisplayID: idBuiltin, displayIDs: [idBuiltin])
            check("resolver: re-plug step 1, other display gone leaves strip on id",
                  gone.frame == rBuiltin && gone.displayIndex == 0 && !gone.migrated)
            // External back: both present, strip still on id 1, no migration.
            let back = StripDisplayResolver.resolve(
                stripFrame: rBuiltin, displays: [rBuiltin, rExternal],
                stripDisplayID: idBuiltin, displayIDs: [idBuiltin, idExternal])
            check("resolver: re-plug step 2, returned display does not yank strip",
                  back.frame == rBuiltin && back.displayIndex == 0 && !back.migrated)
        }

        // (f) ALL DISPLAYS ASLEEP then WAKE: the strip is on the external (id 2).
        // During sleep macOS reports NO screens, so the resolver keeps the last
        // frame and signals "no choice" (caller leaves the strip put). On wake
        // both displays return; identity rebinds to id 2's frame, not migrated.
        do {
            let asleep = StripDisplayResolver.resolve(
                stripFrame: rExternal, displays: [],
                stripDisplayID: idExternal, displayIDs: [])
            check("resolver: all displays asleep -> keep last frame, no choice",
                  asleep.frame == rExternal && asleep.displayIndex == nil && !asleep.migrated)
            let awake = StripDisplayResolver.resolve(
                stripFrame: rExternal, displays: [rBuiltin, rExternal],
                stripDisplayID: idExternal, displayIDs: [idBuiltin, idExternal])
            check("resolver: wake rebinds the strip to its own display by id",
                  awake.frame == rExternal && awake.displayIndex == 1 && !awake.migrated)
        }

        // --- Display-safe RESTORE: monitor unplugged before Release ----------
        // A window's originalFrame / crash-recovery frame can point at a display
        // that has since been unplugged. Restore must pull it onto a surviving
        // display instead of stranding it fully off-screen — but must NOT perturb
        // a window whose saved frame is still mostly visible.
        let builtin = builtinAX                                   // (0,0,1470,956)
        let external = extAX                                      // (-225,-1440,2560,1440)
        let bothDisplays = [builtin, external]
        let builtinOnly = [builtin]                              // external unplugged

        // restoreFrame: a frame on the surviving display is untouched.
        let onBuiltin = CGRect(x: 100, y: 100, width: 600, height: 400)
        check("restore: keeps a frame on a surviving display",
              TeleportEngine.restoreFrame(original: onBuiltin, displays: builtinOnly) == onBuiltin)
        // restoreFrame: a frame on the now-gone external is rescued onto the
        // built-in (mostly visible there) and never larger than it.
        let onExternal = CGRect(x: -100, y: -1200, width: 800, height: 600)
        let rescuedFrame = TeleportEngine.restoreFrame(original: onExternal, displays: builtinOnly)
        check("restore: rescues an orphaned frame onto a surviving display",
              DisplayGeometry.isMostlyVisible(rescuedFrame, on: builtinOnly))
        check("restore: rescued frame fits the surviving display",
              builtin.contains(rescuedFrame))
        // With BOTH displays present the same external frame is left alone (no
        // perturbation of the common case).
        check("restore: leaves an external frame alone when its display is present",
              TeleportEngine.restoreFrame(original: onExternal, displays: bothDisplays) == onExternal)
        // Degenerate: no displays -> leave the frame as-is (caller has no screen).
        check("restore: no displays leaves the frame unchanged",
              TeleportEngine.restoreFrame(original: onExternal, displays: []) == onExternal)

        // restorePlan: releaseAll's actual plan. Build an engine whose windows
        // were originally on the external, then "unplug" it and confirm EVERY
        // restore target lands on the surviving built-in display.
        let rel = makeEngine(count: 3)
        for i in rel.slots.indices {
            // Re-home each window's originalFrame onto the external monitor.
            let f = CGRect(x: -100 - CGFloat(i) * 50, y: -1200, width: 700, height: 500)
            let old = rel.slots[i].window
            rel.slots[i].window = TeleportEngine.ManagedWindowRef(
                element: old.element, pid: old.pid, appName: old.appName,
                title: old.title, originalFrame: f)
        }
        let plan = rel.restorePlan(displays: builtinOnly)
        check("restore: plan covers every managed window", plan.count == 3)
        check("restore: every planned target is visible after unplug",
              plan.allSatisfy { DisplayGeometry.isMostlyVisible($0.target, on: builtinOnly) })
        check("restore: every planned target fits the surviving display",
              plan.allSatisfy { builtin.contains($0.target) })
        // releaseAll consumes the plan (AX no-ops on synthetic elements) and
        // still tears the strip down to a clean single workspace.
        rel.releaseAll(displays: builtinOnly)
        check("restore: releaseAll(displays:) resets to a single workspace",
              rel.workspaceCount == 1 && rel.slots.isEmpty)

        // RestoreStore.safeTarget: crash-recovery entry on a gone monitor is
        // clamped onto a surviving display; an on-screen entry is untouched.
        let goneEntry = RestoreStore.Entry(
            pid: 1, appName: "App", title: "Win", x: -100, y: -1200, w: 800, h: 600)
        let safeGone = RestoreStore.safeTarget(for: goneEntry, displays: builtinOnly)
        check("restore: crash entry on a gone monitor is pulled on-screen",
              DisplayGeometry.isMostlyVisible(safeGone, on: builtinOnly) && builtin.contains(safeGone))
        let liveEntry = RestoreStore.Entry(
            pid: 1, appName: "App", title: "Win", x: 100, y: 100, w: 600, h: 400)
        check("restore: crash entry already on-screen is left untouched",
              RestoreStore.safeTarget(for: liveEntry, displays: builtinOnly)
                == CGRect(x: 100, y: 100, width: 600, height: 400))

        // --- AdoptionScope: which displays' windows the strip adopts ----------
        // Ground the policy in the user's REAL hardware so the test proves the
        // multi-display "yank" fix: built-in primary 1470x956 at AX (0,0); the
        // external Samsung 5K above-and-left at AX (-225,-1440,2560,1440).
        let scopeStrip = CGRect(x: 0, y: 0, width: 1470, height: 956)            // built-in (strip)
        let scopeExt   = CGRect(x: -225, y: -1440, width: 2560, height: 1440)    // external
        // Two candidate windows: one squarely on the built-in, one on the
        // external. AX frames (top-left global).
        let scopeOnBuiltin  = CGRect(x: 200, y: 100, width: 900, height: 600)
        let scopeOnExternal = CGRect(x: 100, y: -1200, width: 1200, height: 800)

        // belongsToStripDisplay: built-in window stays, external window goes.
        check("scope: built-in window belongs to the strip display",
              AdoptionScope.belongsToStripDisplay(scopeOnBuiltin, stripDisplay: scopeStrip, others: [scopeExt]))
        check("scope: external window does NOT belong to the strip display",
              !AdoptionScope.belongsToStripDisplay(scopeOnExternal, stripDisplay: scopeStrip, others: [scopeExt]))

        // filter(stripDisplay): keep ONLY the built-in window (index 0).
        let scopeFrames = [scopeOnBuiltin, scopeOnExternal]
        check("scope: stripDisplay keeps only the strip-display window",
              AdoptionScope.filter(frames: scopeFrames, stripDisplay: scopeStrip,
                                   others: [scopeExt], scope: .stripDisplay) == [0])
        // filter(allDisplays): legacy behavior keeps BOTH windows.
        check("scope: allDisplays keeps every window (legacy)",
              AdoptionScope.filter(frames: scopeFrames, stripDisplay: scopeStrip,
                                   others: [scopeExt], scope: .allDisplays) == [0, 1])

        // Single-display setup (no `others`): nothing is ever dropped, even
        // under stripDisplay, because every window is on the strip's display.
        check("scope: single display keeps everything under stripDisplay",
              AdoptionScope.filter(frames: scopeFrames, stripDisplay: scopeStrip,
                                   others: [], scope: .stripDisplay) == [0, 1])

        // Safety bias: a window overlapping NO display (e.g. parked far away) is
        // KEPT rather than silently lost.
        let orphan = CGRect(x: 9000, y: 9000, width: 400, height: 300)
        check("scope: window overlapping no display is kept (never lose a window)",
              AdoptionScope.belongsToStripDisplay(orphan, stripDisplay: scopeStrip, others: [scopeExt]))

        // A window straddling the bezel goes to whichever display it covers more
        // of; tilt it mostly onto the external and confirm it is dropped.
        let mostlyExternal = CGRect(x: -200, y: -1100, width: 1000, height: 700)
        check("scope: bezel-straddling window follows its majority display",
              !AdoptionScope.belongsToStripDisplay(mostlyExternal, stripDisplay: scopeStrip, others: [scopeExt]))

        // Scope string parsing is tolerant of case/aliases; unknown -> nil.
        check("scope: parse 'stripDisplay'", AdoptionScope.Scope(configValue: "stripDisplay") == .stripDisplay)
        check("scope: parse 'allDisplays'", AdoptionScope.Scope(configValue: "allDisplays") == .allDisplays)
        check("scope: parse is case-insensitive", AdoptionScope.Scope(configValue: "ALLDISPLAYS") == .allDisplays)
        check("scope: unknown scope -> nil", AdoptionScope.Scope(configValue: "moon") == nil)

        // Config plumbing: the new key parses, defaults to stripDisplay, and
        // round-trips through the documented default file.
        check("scope: config default is stripDisplay",
              ScrollWMConfig.default.layout.adoptScope == .stripDisplay)
        do {
            let parsedAll = try ScrollWMConfig.parse(jsonc: """
            { "layout": { "adoptScope": "allDisplays" } }
            """)
            check("scope: config parses adoptScope override", parsedAll.layout.adoptScope == .allDisplays)
            let parsedBad = try ScrollWMConfig.parse(jsonc: """
            { "layout": { "adoptScope": "bogus" } }
            """)
            check("scope: bad adoptScope falls back to default",
                  parsedBad.layout.adoptScope == .stripDisplay)
        } catch {
            check("scope: adoptScope config parses", false)
        }

        // The engine glue (`filterByAdoptScope`) applies the same rule using its
        // own display geometry. Build an engine bound to the built-in with the
        // external registered, feed it two MatchedWindow-like frames, and check
        // both scopes. This is the EXACT path arrange/resync take.
        func scopeEngine(_ scope: AdoptionScope.Scope) -> TeleportEngine {
            let eng = TeleportEngine(screenFrame: scopeStrip)
            eng.stripDisplayFrame = scopeStrip
            eng.otherDisplayFrames = [scopeExt]
            eng.adoptScope = scope
            return eng
        }
        let frames = [scopeOnBuiltin, scopeOnExternal]
        let keptStrip = scopeEngine(.stripDisplay).filterByAdoptScope(frames) { $0 }
        check("scope-engine: stripDisplay keeps only the built-in frame",
              keptStrip == [scopeOnBuiltin])
        let keptAll = scopeEngine(.allDisplays).filterByAdoptScope(frames) { $0 }
        check("scope-engine: allDisplays keeps both frames", keptAll == frames)
        // With NO other displays registered, even stripDisplay keeps everything
        // (degenerate single-monitor case): never drop a window.
        let engNoOthers = TeleportEngine(screenFrame: scopeStrip)
        engNoOthers.stripDisplayFrame = scopeStrip
        engNoOthers.adoptScope = .stripDisplay
        check("scope-engine: single display keeps everything",
              engNoOthers.filterByAdoptScope(frames) { $0 } == frames)

        // === AdoptionScope on the REAL negative-origin external ([md-newwin]) ==
        // The block above used a hypothetical 2560x1440 external. Pin the policy
        // to the ACTUAL live hardware this swarm runs on, so these are a faithful
        // regression guard for BOTH the multi-display "yank" bug (arrange/resync)
        // and the new-window adoption path (the kAXWindowCreated fast path):
        //   strip (built-in, full AX frame): (0,0,1470x956)
        //   external (full AX frame):        (-225,-1080,1920x1080) ABOVE-AND-LEFT
        // The external sits ABOVE the built-in (its AX maxY == the built-in's
        // minY == 0), so the seam between them is HORIZONTAL: a straddling window
        // crosses the y=0 line.
        let nwStrip = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let nwExt   = CGRect(x: -225, y: -1080, width: 1920, height: 1080)
        let nwStripWin = CGRect(x: 120, y: 80, width: 900, height: 600)     // squarely on built-in
        let nwExtWin   = CGRect(x: -100, y: -800, width: 1000, height: 700) // squarely on external

        // (a) THE YANK BUG: a window living on the real external must NOT be
        // classified onto the strip's display, so arrange/resync never yank it.
        check("md-newwin (a): real external window does NOT belong to the strip",
              !AdoptionScope.belongsToStripDisplay(nwExtWin, stripDisplay: nwStrip, others: [nwExt]))
        check("md-newwin: built-in window belongs to the strip",
              AdoptionScope.belongsToStripDisplay(nwStripWin, stripDisplay: nwStrip, others: [nwExt]))
        let nwFrames = [nwStripWin, nwExtWin]
        check("md-newwin (a): stripDisplay scope drops the external window (no yank)",
              AdoptionScope.filter(frames: nwFrames, stripDisplay: nwStrip,
                                   others: [nwExt], scope: .stripDisplay) == [0])
        // (e) Legacy allDisplays still adopts EVERYTHING across monitors.
        check("md-newwin (e): allDisplays scope adopts every window",
              AdoptionScope.filter(frames: nwFrames, stripDisplay: nwStrip,
                                   others: [nwExt], scope: .allDisplays) == [0, 1])

        // (d) Bezel straddle, classified by best-overlap. An EXACT 50/50 split
        // across the y=0 seam (equal area on each monitor) resolves IN FAVOR of
        // the strip (the strip is weighed first, and best-overlap keeps the first
        // maximum). x∈[200,1100] is inside BOTH displays' x-range, so the
        // horizontal overlap is identical; y∈[-300,300] is 300pt on each side.
        let nwTie = CGRect(x: 200, y: -300, width: 900, height: 600)
        check("md-newwin (d): exact bezel tie favors the strip display",
              AdoptionScope.belongsToStripDisplay(nwTie, stripDisplay: nwStrip, others: [nwExt]))
        // Tilt the SAME window majority-onto-external (500 ext vs 100 strip) ->
        // dropped; majority-onto-strip (100 ext vs 500 strip) -> kept.
        let nwMostlyExt   = CGRect(x: 200, y: -500, width: 900, height: 600)
        let nwMostlyStrip = CGRect(x: 200, y: -100, width: 900, height: 600)
        check("md-newwin (d): majority-on-external straddler is dropped",
              !AdoptionScope.belongsToStripDisplay(nwMostlyExt, stripDisplay: nwStrip, others: [nwExt]))
        check("md-newwin (d): majority-on-strip straddler is kept",
              AdoptionScope.belongsToStripDisplay(nwMostlyStrip, stripDisplay: nwStrip, others: [nwExt]))

        // (b)+(c) NEW-window adoption runs through the SAME engine glue the
        // fast-adopt (kAXWindowCreated) and resync paths call
        // (`filterByAdoptScope`). Build an engine bound to the built-in with the
        // real external registered and feed it the AX frames a freshly-opened
        // window would carry. This is the exact decision `LifecycleMonitor`
        // makes for a brand-new window.
        func nwEngine(_ scope: AdoptionScope.Scope) -> TeleportEngine {
            let eng = TeleportEngine(screenFrame: nwStrip)
            eng.stripDisplayFrame = nwStrip
            eng.otherDisplayFrames = [nwExt]
            eng.adoptScope = scope
            return eng
        }
        // (b) a new window opened ON the external is IGNORED by a stripDisplay
        // strip (the fast path drops it before insert -> no yank).
        check("md-newwin (b): new window on the external is ignored (fast-adopt scope)",
              nwEngine(.stripDisplay).filterByAdoptScope([nwExtWin]) { $0 } == [])
        // (c) a new window opened on the STRIP display IS adopted.
        check("md-newwin (c): new window on the strip display is adopted",
              nwEngine(.stripDisplay).filterByAdoptScope([nwStripWin]) { $0 } == [nwStripWin])
        // A mixed burst (one window per monitor opening together, as the
        // coalesced kAXWindowCreated path can deliver) adopts ONLY the strip one.
        check("md-newwin (b+c): mixed new-window burst adopts only the strip window",
              nwEngine(.stripDisplay).filterByAdoptScope([nwExtWin, nwStripWin]) { $0 } == [nwStripWin])
        // (e) allDisplays keeps both even through the engine glue.
        check("md-newwin (e): allDisplays engine glue adopts both new windows",
              nwEngine(.allDisplays).filterByAdoptScope([nwExtWin, nwStripWin]) { $0 } == [nwExtWin, nwStripWin])

        // Multi-external robustness (3 displays): a SECOND external further left
        // must not confuse scoping - a window on EITHER external is dropped, only
        // the strip's own survives. Guards the >2-display layouts the hotplug
        // resolver allows, where two non-strip displays could tie each other.
        let nwExt2    = CGRect(x: -2145, y: -1080, width: 1920, height: 1080) // further left
        let nwExt2Win = CGRect(x: -2000, y: -800, width: 1000, height: 700)   // squarely on ext2
        check("md-newwin: 3-display keeps only strip-display windows",
              AdoptionScope.filter(frames: [nwStripWin, nwExtWin, nwExt2Win],
                                   stripDisplay: nwStrip, others: [nwExt, nwExt2],
                                   scope: .stripDisplay) == [0])

        // Single-display fallback at the REAL strip geometry: once the external
        // is unplugged (`others` empty) every window is on the strip, so even a
        // frame that WOULD have been on the external is kept (never dropped onto
        // a monitor that no longer exists).
        let nwUnplugged = TeleportEngine(screenFrame: nwStrip)
        nwUnplugged.stripDisplayFrame = nwStrip
        nwUnplugged.otherDisplayFrames = []          // external gone
        nwUnplugged.adoptScope = .stripDisplay
        check("md-newwin: single-display keeps the would-be-external window",
              nwUnplugged.filterByAdoptScope([nwExtWin]) { $0 } == [nwExtWin])
        // Safety bias on the real geometry: a window overlapping NONE of the 3
        // displays (degenerate / far-parked frame) is KEPT, never silently lost.
        let nwOrphan = CGRect(x: 50_000, y: 50_000, width: 400, height: 300)
        check("md-newwin: window overlapping no display is kept (never lose a window)",
              AdoptionScope.belongsToStripDisplay(nwOrphan, stripDisplay: nwStrip, others: [nwExt, nwExt2]))

        // --- DisplaySelector: pure strip-display PICK policy ([md-select]) ----
        // Model the user's REAL hardware in NSScreen.screens order: built-in
        // primary 1470x956 at AppKit (0,0) (also `main`), and the bigger external
        // 2560x1440 at AppKit (-225, 956). `largest` must pick the external.
        let selBuiltin = DisplaySelector.DisplayInfo(
            frame: CGRect(x: 0, y: 0, width: 1470, height: 956), isMain: true, isPrimary: true)
        let selExternal = DisplaySelector.DisplayInfo(
            frame: CGRect(x: -225, y: 956, width: 2560, height: 1440), isMain: false, isPrimary: false)
        let twoDisplays = [selBuiltin, selExternal]

        check("select: empty spec defaults to main (built-in @ 0)",
              DisplaySelector.pick(spec: "", displays: twoDisplays) == 0)
        check("select: 'main' picks the active display (built-in @ 0)",
              DisplaySelector.pick(spec: "main", displays: twoDisplays) == 0)
        check("select: 'MAIN' is case-insensitive",
              DisplaySelector.pick(spec: "MAIN", displays: twoDisplays) == 0)
        check("select: ' largest ' trims whitespace",
              DisplaySelector.pick(spec: " largest ", displays: twoDisplays) == 1)
        check("select: 'primary' picks the AppKit-origin display (built-in @ 0)",
              DisplaySelector.pick(spec: "primary", displays: twoDisplays) == 0)
        check("select: 'largest' picks the EXTERNAL (bigger area, @ 1)",
              DisplaySelector.pick(spec: "largest", displays: twoDisplays) == 1)
        check("select: index '2' picks the second display (1-based)",
              DisplaySelector.pick(spec: "2", displays: twoDisplays) == 1)
        check("select: index '1' picks the first display",
              DisplaySelector.pick(spec: "1", displays: twoDisplays) == 0)
        check("select: out-of-range index '3' -> nil",
              DisplaySelector.pick(spec: "3", displays: twoDisplays) == nil)
        check("select: index '0' (not 1-based) -> nil",
              DisplaySelector.pick(spec: "0", displays: twoDisplays) == nil)
        check("select: garbage spec -> nil",
              DisplaySelector.pick(spec: "banana", displays: twoDisplays) == nil)
        check("select: empty display list -> nil",
              DisplaySelector.pick(spec: "main", displays: []) == nil)

        // 'next' cycles through NSScreen order, wrapping, anchored on `current`.
        check("select: 'next' from 0 -> 1",
              DisplaySelector.pick(spec: "next", displays: twoDisplays, current: 0) == 1)
        check("select: 'next' from 1 wraps -> 0",
              DisplaySelector.pick(spec: "next", displays: twoDisplays, current: 1) == 0)
        check("select: 'next' with no current starts from main, -> 1",
              DisplaySelector.pick(spec: "next", displays: twoDisplays, current: nil) == 1)

        // When `main` is the EXTERNAL (user dragged the menu bar there), 'main'
        // and 'primary' diverge: primary stays the AppKit-origin built-in.
        let extIsMain = [
            DisplaySelector.DisplayInfo(frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                        isMain: false, isPrimary: true),
            DisplaySelector.DisplayInfo(frame: CGRect(x: -225, y: 956, width: 2560, height: 1440),
                                        isMain: true, isPrimary: false),
        ]
        check("select: 'main' follows the active display (external @ 1)",
              DisplaySelector.pick(spec: "main", displays: extIsMain) == 1)
        check("select: 'primary' stays the AppKit-origin display (@ 0)",
              DisplaySelector.pick(spec: "primary", displays: extIsMain) == 0)

        // Single-display fallbacks: every spec resolves to the only screen.
        let one = [selBuiltin]
        check("select: single display, 'largest' -> 0",
              DisplaySelector.pick(spec: "largest", displays: one) == 0)
        check("select: single display, 'next' wraps to itself -> 0",
              DisplaySelector.pick(spec: "next", displays: one, current: 0) == 0)

        // 'next' from an out-of-range / nonsense `current` must not crash and
        // must land in range (defends moveStripToDisplay when the strip's index
        // could not be identified). `current` -1 -> (-1+1)%2 == 0.
        check("select: 'next' from current -1 stays in range (0)",
              DisplaySelector.pick(spec: "next", displays: twoDisplays, current: -1) == 0)
        // Whitespace-only / blank spec behaves like empty -> main.
        check("select: blank '   ' spec defaults to main",
              DisplaySelector.pick(spec: "   ", displays: twoDisplays) == 0)
        // A non-integer numeric-looking spec is rejected (not silently floored).
        check("select: '1.5' is not a valid index -> nil",
              DisplaySelector.pick(spec: "1.5", displays: twoDisplays) == nil)
        check("select: negative index '-1' -> nil",
              DisplaySelector.pick(spec: "-1", displays: twoDisplays) == nil)

        // --- StripDisplayBinding: launch/move AX flip ([md-move]) -------------
        // REPRODUCE the launch bug: the strip on a NON-PRIMARY external must use
        // the PRIMARY display's height for the Y-flip, not its own height.
        // Real hardware in NSScreen order: built-in primary (0,0,1470,956) is
        // also `main`; external (-225,956,1920,1080) sits ABOVE-and-LEFT.
        let bdBuiltin = StripDisplayBinding.DisplayFrames(
            full: CGRect(x: 0, y: 0, width: 1470, height: 956),
            visible: CGRect(x: 0, y: 33, width: 1470, height: 890))   // menu bar @ top
        let bdExternal = StripDisplayBinding.DisplayFrames(
            full: CGRect(x: -225, y: 956, width: 1920, height: 1080),
            visible: CGRect(x: -225, y: 956, width: 1920, height: 1080)) // no menu bar
        let bdDisplays = [bdBuiltin, bdExternal]

        // Strip on the PRIMARY built-in (index 0): AX == AppKit flipped about its
        // own height (the two heights are the same here), the historical case.
        let bindBuiltin = StripDisplayBinding.bind(displays: bdDisplays, stripIndex: 0, mainIndex: 0)
        check("bind: builtin strip full flips about primary height (AX y=0)",
              bindBuiltin?.stripFull == CGRect(x: 0, y: 0, width: 1470, height: 956))
        check("bind: builtin strip visible AX top under the menu bar (y=33)",
              bindBuiltin?.stripVisible == CGRect(x: 0, y: 33, width: 1470, height: 890))
        check("bind: builtin strip's 'other' is the external, flipped to AX y=-1080",
              bindBuiltin?.others == [CGRect(x: -225, y: -1080, width: 1920, height: 1080)])

        // Strip on the NON-PRIMARY external (index 1): the WHOLE point. AX y must
        // be primaryHeight(956) - extMaxY(2036) = -1080 (the brief's ground
        // truth). The OLD hand-rolled flip used the external's own height 1080,
        // giving y = 1080 - 2036 = -956 — 124px too low, off the display.
        let bindExternal = StripDisplayBinding.bind(displays: bdDisplays, stripIndex: 1, mainIndex: 0)
        check("bind: external strip uses PRIMARY height for Y-flip (AX y=-1080)",
              bindExternal?.stripVisible == CGRect(x: -225, y: -1080, width: 1920, height: 1080))
        check("bind: external strip full matches (negative-origin external)",
              bindExternal?.stripFull == CGRect(x: -225, y: -1080, width: 1920, height: 1080))
        check("bind: external strip's 'other' is the built-in at AX y=0",
              bindExternal?.others == [CGRect(x: 0, y: 0, width: 1470, height: 956)])
        // The exact regression guard: the buggy own-height flip would have put
        // the external strip 124px too low. Assert we are NOT there.
        check("bind: external strip is NOT at the buggy own-height y (-956)",
              bindExternal?.stripVisible.origin.y == -1080 && bindExternal?.stripVisible.origin.y != -956)

        // Out-of-range / empty are clean nils (caller keeps prior binding).
        check("bind: out-of-range stripIndex -> nil",
              StripDisplayBinding.bind(displays: bdDisplays, stripIndex: 2, mainIndex: 0) == nil)
        check("bind: empty display list -> nil",
              StripDisplayBinding.bind(displays: [], stripIndex: 0, mainIndex: nil) == nil)

        // primaryHeight resolution order: origin-(0,0) display wins even when it
        // is NOT main; falls back to main, then strip, in degenerate layouts.
        check("bind: primaryHeight prefers the AppKit-origin display (956)",
              StripDisplayBinding.primaryHeight(displays: bdDisplays, mainIndex: 1, stripIndex: 1) == 956)
        let noOrigin = [
            StripDisplayBinding.DisplayFrames(full: CGRect(x: -225, y: 956, width: 1920, height: 1080),
                                              visible: CGRect(x: -225, y: 956, width: 1920, height: 1080)),
            StripDisplayBinding.DisplayFrames(full: CGRect(x: 100, y: 100, width: 800, height: 600),
                                              visible: CGRect(x: 100, y: 100, width: 800, height: 600)),
        ]
        check("bind: no origin display -> falls back to main's height (1080)",
              StripDisplayBinding.primaryHeight(displays: noOrigin, mainIndex: 0, stripIndex: 1) == 1080)
        check("bind: no origin + no main -> falls back to strip's height (600)",
              StripDisplayBinding.primaryHeight(displays: noOrigin, mainIndex: nil, stripIndex: 1) == 600)

        // --- rebindStripDisplay: cross-size relay (1470 -> 1920) ([md-move]) --
        // Moving the strip from the narrow built-in onto the wider external must
        // re-anchor every column's vertical band to the NEW display top and let
        // width fractions scale to the NEW viewport width — the size-mismatch the
        // brief calls out (1470 wide vs 1920 wide).
        let narrow = CGRect(x: 0, y: 33, width: 1470, height: 890)   // built-in visible
        let wide   = CGRect(x: -225, y: -1080, width: 1920, height: 1080) // external visible (AX)
        let relayEng = makeEngine(count: 3, width: 300, screenWidth: narrow.width)
        // Seed realistic top/heights as if arranged on the built-in.
        for i in relayEng.slots.indices { relayEng.slots[i].y = narrow.minY; relayEng.slots[i].height = 600 }
        let widthHalfNarrow = relayEng.width(forFraction: 0.5)
        relayEng.rebindStripDisplay(to: wide)
        check("rebind: screenFrame follows to the wide external",
              relayEng.screenFrame.width == 1920)
        check("rebind: every column re-pinned to the NEW display top (AX y=-1080)",
              relayEng.slots.allSatisfy { abs($0.y - wide.minY) < 0.5 })
        let widthHalfWide = relayEng.width(forFraction: 0.5)
        check("rebind: a 50% width is WIDER on the 1920 display than the 1470 one",
              widthHalfWide > widthHalfNarrow)
        check("rebind: 50% width tracks the new viewport math exactly",
              abs(widthHalfWide - (0.5 * (1920 - relayEng.gap) - relayEng.gap)) < 0.5)
        // Heights TALLER than the new usable height are clamped; shorter kept.
        let tallEng = makeEngine(count: 1, width: 300, screenWidth: 1470)
        tallEng.slots[0].height = 2000                 // taller than 1080
        tallEng.rebindStripDisplay(to: wide)
        check("rebind: an over-tall column is clamped to the new display height",
              tallEng.slots[0].height == wide.height)
        let shortEng = makeEngine(count: 1, width: 300, screenWidth: 1470)
        shortEng.slots[0].height = 500
        shortEng.rebindStripDisplay(to: wide)
        check("rebind: a column shorter than the new height is left unchanged",
              shortEng.slots[0].height == 500)

        // No-op rebind to the SAME geometry leaves the layout untouched
        // (display-already-on safety: moving the strip to the display it is
        // already on must not tear up the horizontal packing or corrupt heights).
        // rebind always re-pins each column to the display TOP, which is a no-op
        // here because an already-arranged strip's columns sit at that top
        // (`y == screenFrame.minY`). The controller's moveStripToDisplay calls
        // rebind unconditionally, so this is the model guarantee that "move to
        // the current display" is harmless.
        let sameEng = makeEngine(count: 3, width: 300, screenWidth: 1470)
        for i in sameEng.slots.indices { sameEng.slots[i].y = sameEng.screenFrame.minY; sameEng.slots[i].height = 500 }
        let ysBefore = sameEng.slots.map { $0.y }
        let xsBefore = sameEng.slots.map { $0.canvasX }
        let hsBefore = sameEng.slots.map { $0.height }
        sameEng.rebindStripDisplay(to: sameEng.screenFrame)
        check("rebind: same-frame rebind keeps every slot y/canvasX/height stable",
              sameEng.slots.map { $0.y } == ysBefore
                  && sameEng.slots.map { $0.canvasX } == xsBefore
                  && sameEng.slots.map { $0.height } == hsBefore)

        // --- testWindowTiles: multi-display spawn placement (pure) -----------
        // Primary display (origin 0,0): layout is unchanged from the original
        // single-display tiling, so existing callers spawn identically.
        let tilePrimary = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let pTiles = testWindowTiles(count: 4, displayFrame: tilePrimary)
        check("tiles: count matches request", pTiles.count == 4)
        check("tiles: first window at the historical (40, top) origin",
              pTiles[0].x == 40 && pTiles[0].y == 956 - 120 - 240)
        check("tiles: columns step by width+20",
              pTiles[1].x == 40 + 320 + 20 && pTiles[1].y == pTiles[0].y)
        // A monitor placed ABOVE-and-LEFT of the primary (negative AppKit origin,
        // like the real external Samsung at (-225, 956)): every tile must be
        // anchored to THAT display's origin so windows land on it, not on (0,0).
        let tileExternal = CGRect(x: -225, y: 956, width: 2560, height: 1440)
        let eTiles = testWindowTiles(count: 4, displayFrame: tileExternal)
        check("tiles: external tiles carry the display's negative X origin",
              eTiles[0].x == -225 + 40)
        check("tiles: external tiles sit on the external's Y band",
              eTiles[0].y == 956 + 1440 - 120 - 240)
        check("tiles: every external tile lies within the external AppKit frame",
              eTiles.allSatisfy { t in
                  t.x >= tileExternal.minX && t.x + t.width <= tileExternal.maxX
                      && t.y >= tileExternal.minY && t.y + t.height <= tileExternal.maxY
              })
        // Grid wraps to a new row after `cols` windows (default 4).
        let wrap = testWindowTiles(count: 5, displayFrame: tilePrimary)
        check("tiles: 5th window wraps to a new (lower) row",
              wrap[4].x == wrap[0].x && wrap[4].y < wrap[0].y)
        check("tiles: zero count yields no tiles",
              testWindowTiles(count: 0, displayFrame: tilePrimary).isEmpty)

        // --- WindowReveal: which apps/windows "Arrange All" reveals (pure) ----
        // Only hidden apps are unhidden; visible ones are left alone.
        let revealApps: [(pid: pid_t, isHidden: Bool)] =
            [(1, true), (2, false), (3, true), (4, false)]
        check("reveal: unhides exactly the hidden apps",
              WindowReveal.appsToUnhide(revealApps) == [1, 3])
        check("reveal: no hidden apps -> nothing to unhide",
              WindowReveal.appsToUnhide([(7, false), (8, false)]).isEmpty)

        // Only MINIMIZED top-level windows (role AXWindow) are de-miniaturized.
        // We key on ROLE not subrole because macOS flips a minimized window's
        // subrole to AXDialog in the Dock; a subrole gate would miss them.
        let winRole = kAXWindowRole as String
        check("reveal: minimized AXWindow -> unminimize",
              WindowReveal.shouldUnminimize(role: winRole, isMinimized: true))
        check("reveal: visible AXWindow -> leave alone",
              !WindowReveal.shouldUnminimize(role: winRole, isMinimized: false))
        check("reveal: minimized non-window role (e.g. AXSheet) -> leave alone",
              !WindowReveal.shouldUnminimize(role: "AXSheet", isMinimized: true))
        check("reveal: minimized unknown role -> leave alone",
              !WindowReveal.shouldUnminimize(role: nil, isMinimized: true))

        // Result.didReveal is true iff something was acted on.
        check("reveal: didReveal false when nothing revealed",
              !WindowReveal.Result().didReveal)
        check("reveal: didReveal true when an app was unhidden",
              WindowReveal.Result(unhiddenApps: 1, unminimizedWindows: 0).didReveal)
        check("reveal: didReveal true when a window was unminimized",
              WindowReveal.Result(unhiddenApps: 0, unminimizedWindows: 2).didReveal)

        // --- Negative-origin external hardening (own file, merges clean) ------
        // Parking/restore/round-trip correctness pinned to the LIVE 1920x1080
        // external at AX (-225,-1080) — both axes negative, stacked above the
        // built-in. See GeometryHardeningTests for the rationale per check.
        GeometryHardeningTests.run(check)

        // --- SemVer parse + ordering (in-app updater) -----------------------
        func sv(_ s: String) -> SemVer? { SemVer(s) }
        check("semver: parses plain", sv("1.2.3") == SemVer("1.2.3"))
        check("semver: tolerates leading v", sv("v0.1.2")?.description == "0.1.2")
        check("semver: missing components default to 0",
              sv("1")?.description == "1.0.0" && sv("1.4")?.description == "1.4.0")
        check("semver: rejects non-numeric", sv("nightly") == nil)
        check("semver: patch ordering", sv("0.1.1")! < sv("0.1.2")!)
        check("semver: minor ordering", sv("0.1.9")! < sv("0.2.0")!)
        check("semver: major ordering", sv("0.9.9")! < sv("1.0.0")!)
        check("semver: prerelease < final of same core",
              sv("0.2.0-dev")! < sv("0.2.0")!)
        check("semver: dev build never outranks a real release",
              sv("0.0.0-dev")! < sv("0.1.1")!)
        check("semver: prerelease ordering rc.1 < rc.2",
              sv("1.0.0-rc.1")! < sv("1.0.0-rc.2")!)
        check("semver: equal versions are not <",
              !(sv("0.1.1")! < sv("0.1.1")!))
        check("semver: build metadata ignored", sv("1.2.3+abc")?.description == "1.2.3")

        // --- Updater: SHA256SUMS parsing (pure) -----------------------------
        let sums = """
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  ScrollWM-0.1.2.zip
        deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef0  ScrollWM-0.1.2.dmg
        """
        check("updater: expectedSHA256 finds the zip line",
              Updater.expectedSHA256(fromSums: sums, fileName: "ScrollWM-0.1.2.zip")
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        check("updater: expectedSHA256 nil for unknown file",
              Updater.expectedSHA256(fromSums: sums, fileName: "nope.zip") == nil)
        check("updater: expectedSHA256 tolerates binary '*' marker",
              Updater.expectedSHA256(fromSums: "abc123  *ScrollWM-9.9.9.zip\n",
                                     fileName: "ScrollWM-9.9.9.zip") == "abc123")

        // --- Updater: release JSON parse + evaluate (pure) ------------------
        let releaseJSON = """
        [
          {
            "tag_name": "v0.2.0",
            "draft": false,
            "prerelease": false,
            "html_url": "https://example.com/v0.2.0",
            "body": "notes here",
            "assets": [
              {"name": "ScrollWM-0.2.0.zip", "browser_download_url": "https://example.com/ScrollWM-0.2.0.zip"},
              {"name": "SHA256SUMS.txt", "browser_download_url": "https://example.com/SHA256SUMS.txt"}
            ]
          },
          {
            "tag_name": "v0.2.1-rc.1",
            "draft": false,
            "prerelease": true,
            "html_url": "https://example.com/rc",
            "assets": [
              {"name": "ScrollWM-0.2.1-rc.1.zip", "browser_download_url": "https://example.com/rc.zip"}
            ]
          },
          {
            "tag_name": "v0.3.0",
            "draft": true,
            "assets": []
          },
          {
            "tag_name": "v0.1.0",
            "draft": false,
            "prerelease": false,
            "assets": [
              {"name": "ScrollWM-0.1.0.zip", "browser_download_url": "https://example.com/old.zip"}
            ]
          }
        ]
        """.data(using: .utf8)!
        let parsed = Updater.parseReleases(releaseJSON)
        check("updater: parses non-draft releases with a zip (drops draft v0.3.0)",
              parsed.count == 3)
        check("updater: parsed release captures zip + sums URLs",
              parsed.first(where: { $0.tagName == "v0.2.0" })?.sha256SumsURL == "https://example.com/SHA256SUMS.txt")

        // Stable channel: ignore the rc, offer v0.2.0 over an older current.
        let stable = Updater.evaluate(releases: parsed, current: SemVer("0.1.1")!, allowPrerelease: false)
        check("updater: stable channel offers v0.2.0 update",
              stable == .updateAvailable(parsed.first(where: { $0.tagName == "v0.2.0" })!, current: SemVer("0.1.1")!))

        // Pre-release channel: the rc (0.2.1-rc.1) outranks 0.2.0.
        if case let .updateAvailable(rel, _) = Updater.evaluate(releases: parsed, current: SemVer("0.1.1")!, allowPrerelease: true) {
            check("updater: prerelease channel offers the rc", rel.tagName == "v0.2.1-rc.1")
        } else {
            check("updater: prerelease channel offers the rc", false)
        }

        // Already current: up to date, no nag.
        check("updater: up to date when current >= newest stable",
              Updater.evaluate(releases: parsed, current: SemVer("0.2.0")!, allowPrerelease: false)
                == .upToDate(current: SemVer("0.2.0")!))

        // Empty input -> up to date (never a spurious update).
        check("updater: no releases -> up to date",
              Updater.evaluate(releases: [], current: SemVer("0.1.1")!, allowPrerelease: false)
                == .upToDate(current: SemVer("0.1.1")!))

        // --- UpdatePolicy: attempt guard (no relaunch loop) -----------------
        check("policy: first auto-install attempt is allowed",
              UpdatePolicy.shouldAutoInstall(available: "0.2.0", lastAttempt: nil, skipped: nil))
        let attempt1 = UpdatePolicy.recordingAttempt(nil, version: "0.2.0")
        check("policy: recording first attempt -> count 1",
              attempt1 == UpdatePolicy.AttemptRecord(version: "0.2.0", count: 1))
        check("policy: still allowed after 1 attempt",
              UpdatePolicy.shouldAutoInstall(available: "0.2.0", lastAttempt: attempt1, skipped: nil))
        let attempt2 = UpdatePolicy.recordingAttempt(attempt1, version: "0.2.0")
        check("policy: recording second attempt -> count 2",
              attempt2.count == 2)
        check("policy: BLOCKED after maxAutoAttempts for same version",
              !UpdatePolicy.shouldAutoInstall(available: "0.2.0", lastAttempt: attempt2, skipped: nil))
        check("policy: a NEW version resets the attempt budget",
              UpdatePolicy.shouldAutoInstall(available: "0.3.0", lastAttempt: attempt2, skipped: nil))
        check("policy: recording a new version resets count to 1",
              UpdatePolicy.recordingAttempt(attempt2, version: "0.3.0").count == 1)
        check("policy: a skipped version is never auto-installed",
              !UpdatePolicy.shouldAutoInstall(available: "0.2.0", lastAttempt: nil, skipped: "0.2.0"))

        // --- UpdatePolicy: apply timing (don't disrupt an active session) ---
        check("policy: dormant + automatic -> apply now",
              UpdatePolicy.applyTiming(isManaging: false, automatic: true) == .now)
        check("policy: managing + automatic -> defer to quit",
              UpdatePolicy.applyTiming(isManaging: true, automatic: true) == .onQuit)
        check("policy: managing + manual click -> apply now (explicit request)",
              UpdatePolicy.applyTiming(isManaging: true, automatic: false) == .now)
        check("policy: dormant + manual click -> apply now",
              UpdatePolicy.applyTiming(isManaging: false, automatic: false) == .now)

        // --- UpdatePolicy: post-relaunch success detection ------------------
        check("policy: install succeeded when running version advanced",
              UpdatePolicy.installSucceeded(attempted: "0.2.0", runningNow: "0.2.0"))
        check("policy: install succeeded when running is even newer",
              UpdatePolicy.installSucceeded(attempted: "0.2.0", runningNow: "0.2.1"))
        check("policy: install FAILED when still on old version",
              !UpdatePolicy.installSucceeded(attempted: "0.2.0", runningNow: "0.1.1"))

        // --- UpdatePolicy: install-target classification --------------------
        check("policy: dev binary is never self-replaced",
              UpdatePolicy.classifyTarget(isAppBundle: false, bundlePath: "/x/WindowLab",
                                          parentWritable: true, brewPrefixes: ["/opt/homebrew"]) == .notAppBundle)
        check("policy: writable ~/Applications install is self-updatable",
              UpdatePolicy.classifyTarget(isAppBundle: true, bundlePath: "/Users/me/Applications/ScrollWM.app",
                                          parentWritable: true, brewPrefixes: ["/opt/homebrew"]) == .selfUpdatable)
        check("policy: non-writable /Applications install is notWritable",
              UpdatePolicy.classifyTarget(isAppBundle: true, bundlePath: "/Applications/ScrollWM.app",
                                          parentWritable: false, brewPrefixes: ["/opt/homebrew"]) == .notWritable)
        check("policy: bundle under a brew Caskroom is homebrewManaged",
              UpdatePolicy.classifyTarget(isAppBundle: true,
                                          bundlePath: "/opt/homebrew/Caskroom/scrollwm/0.1.1/ScrollWM.app",
                                          parentWritable: true, brewPrefixes: ["/opt/homebrew"]) == .homebrewManaged)

        print("\n[unittest] StripOps/config/policy: \(passed) passed, \(failed) failed")

        // --- Onboarding polish swarm: per-lane pure-logic suites ------------
        // Each lane extracted its decision logic into a PURE, headless-testable
        // module (no AppKit/AX/TCC) and ships its own `*Tests.run()`. Aggregate
        // them here so a single `unittest` covers the whole onboarding surface:
        //   A: launch-location classify + relocation policy   (AppLocationTests)
        //   B: Accessibility permission decisions             (PermissionPolicyTests)
        //   C: onboarding window state -> presentation        (OnboardingCopyTests)
        //   D: tutorial chord rendering + key table           (TutorialTests)
        print("\n[unittest] onboarding lanes:")
        var lanesOK = true
        lanesOK = AppLocationTests.run() && lanesOK
        lanesOK = PermissionPolicyTests.run() && lanesOK
        lanesOK = OnboardingCopyTests.run() && lanesOK
        lanesOK = TutorialTests.run() && lanesOK

        let allOK = failed == 0 && lanesOK
        print("\n[unittest] overall: \(allOK ? "PASS" : "FAIL")")
        return allOK
    }
}
