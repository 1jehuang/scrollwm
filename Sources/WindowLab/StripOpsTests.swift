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

        // --- Config: JSONC parsing (comments + overrides) ---
        let jsonc = """
        {
          // a comment with a fake "key": value inside a string-ish // sequence
          "layout": { "columnGap": 20, "minColumnWidth": 150,
                      "widthPresets": [0.3, 0.6, 0.9] },
          "focusMode": "centered",
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
            check("config focusMode parsed", parsed.focusMode == .centered)
            check("config keybinding override", parsed.keybindings[.focusNext] == ["ctrl+opt+k"])
            check("config keybinding array", parsed.keybindings[.width25] == ["opt+1", "cmd+1"])
            // Untouched bindings keep their defaults.
            check("config default kept for unset action",
                  parsed.keybindings[.toggleArrange] == KeyAction.defaultChords[.toggleArrange])
        } catch {
            check("config JSONC parses", false)
        }

        // Malformed JSON throws (caller falls back to defaults).
        var threw = false
        do { _ = try ScrollWMConfig.parse(jsonc: "{ not json ]") } catch { threw = true }
        check("malformed config throws", threw)

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
        // fully past the viewport must be parked at one shared corner instead of
        // leaving stacked slivers along the edge.
        let ep = makeEngine(count: 3, width: 400, screenWidth: 1000)
        // Slot fully within the viewport -> natural strip position.
        ep.setViewportXForTest(0)
        let inView = ep.slots[0] // canvasX=0,w=400 -> [0,400) visible
        let inTarget = ep.onScreenTarget(for: inView)
        check("in-view column placed at natural position",
              abs(inTarget.x - (ep.screenFrame.origin.x + inView.canvasX - ep.viewportX)) < 0.5)
        // A column scrolled fully off the right parks at the shared corner.
        var off = ep.slots[1]
        off.canvasX = 5000 // far right of any viewport
        let offTarget = ep.onScreenTarget(for: off)
        check("fully-offscreen column parks at corner", offTarget == ep.parkingPoint)
        // A column scrolled fully off the LEFT also parks.
        var offL = ep.slots[1]
        offL.canvasX = 0
        offL.width = 100
        ep.setViewportXForTest(5000) // viewport far right -> column at [0,100) is off-left
        check("fully-offscreen-left column parks at corner",
              ep.onScreenTarget(for: offL) == ep.parkingPoint)
        // A partially-visible column (last column overflowing right) is NOT parked.
        ep.setViewportXForTest(0)
        var partial = ep.slots[1]
        partial.canvasX = 900 // [900,1300), viewport [0,1000): partly visible
        partial.width = 400
        check("partially-visible column is not parked",
              ep.onScreenTarget(for: partial) != ep.parkingPoint)

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

        print("\n[unittest] \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
