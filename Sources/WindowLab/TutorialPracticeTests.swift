import Foundation
import AppKit
import CoreGraphics

/// Tests for the goal-oriented practice drill: the pure `TutorialPractice` state
/// machine (focus/move sim, goal completion, task progression, blocked moves,
/// ignored chords, reset, tolerant matching, key-event → chord) plus a small
/// offscreen-render smoke test of `TutorialPracticeView` (constructs, lays out,
/// drives a full goal-reaching sequence — must not crash).
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

        // MARK: - World mechanics (focus + move, clamped)

        func w(_ id: Int) -> TutorialPractice.Window {
            TutorialPractice.Window(id: id, appName: "A", title: "t\(id)")
        }
        var world = TutorialPractice.World(windows: [w(0), w(1), w(2)], focus: 1)
        world.moveFocus(by: 1)
        check("focus right moves to next", world.focus == 2)
        world.moveFocus(by: 1)
        check("focus right clamps at end", world.focus == 2)
        world.moveFocus(by: -5)
        check("focus left clamps at start", world.focus == 0)

        var mw = TutorialPractice.World(windows: [w(0), w(1), w(2)], focus: 2)
        mw.moveWindow(by: -1)
        check("move swaps with neighbour", mw.windows.map { $0.id } == [0, 2, 1])
        check("focus follows the moved window", mw.focus == 1)
        mw.moveWindow(by: -1)
        check("move again reaches the front", mw.windows.map { $0.id } == [2, 0, 1])
        check("focus at front", mw.focus == 0)
        mw.moveWindow(by: -1)
        check("move past edge is a no-op", mw.windows.map { $0.id } == [2, 0, 1] && mw.focus == 0)
        check("index(of:) finds a present window", mw.index(of: 0) == 1)

        // MARK: - Task generation from the default progression

        var drill = TutorialPractice(config: config)
        check("default drill has tasks", !drill.tasks.isEmpty)
        check("every task has an instruction + moves",
              drill.tasks.allSatisfy { !$0.instruction.isEmpty && !$0.moves.isEmpty })
        check("every start world is non-empty",
              drill.tasks.allSatisfy { !$0.start.windows.isEmpty })
        check("starts at task 0, nothing done", drill.index == 0 && drill.doneCount == 0)
        check("initial fraction is 0", drill.fraction == 0)
        check("current is first task", drill.current == drill.tasks.first)
        check("world seeded from first task", drill.world == drill.tasks.first!.start)
        // Every goal is reachable from its start with the task's moves.
        check("every default task is solvable", drill.tasks.allSatisfy { isSolvable($0, config: config) })

        // MARK: - Driving the first task (focus left) to its goal

        // Task 1: focus index 2 -> goal focus id 0; press focus-left twice.
        let out1 = drill.handle(chord: "cmd+h")   // focus left default
        check("a focus move applies", out1 == .moved)
        check("attempt recorded", drill.attempts == 1)
        let out2 = drill.handle(chord: "cmd+h")   // reaches the left end (goal)
        check("reaching goal completes task", out2 == .taskComplete)
        check("advanced to task 2", drill.index == 1)
        check("first task marked done", drill.doneCount == 1)
        check("world reseeded to task 2 start", drill.world == drill.tasks[1].start)

        // MARK: - Blocked move (hit a wall) does not advance

        var blk = TutorialPractice(config: config)
        // Task 1 starts at the right end focused; focus-right is a wall.
        let outB = blk.handle(chord: "cmd+l")     // focus right at right edge
        check("blocked move reported", outB == .blocked)
        check("blocked move records an attempt", blk.attempts == 1)
        check("blocked move does not advance", blk.index == 0)

        // MARK: - Ignored chords (not a practice move)

        var ign = TutorialPractice(config: config)
        check("unrelated chord is ignored", ign.handle(chord: "cmd+q") == .ignored)
        check("garbage chord is ignored", ign.handle(chord: "+++") == .ignored)
        check("empty chord is ignored", ign.handle(chord: "") == .ignored)
        check("ignored chords record no attempt", ign.attempts == 0)
        check("ignored chords don't advance", ign.index == 0)

        // MARK: - Tolerant matching (modifier order + glyph spelling)

        var tol = TutorialPractice(config: config)
        check("glyph spelling matches a move", tol.handle(chord: "⌘H") == .moved)
        var tol2 = TutorialPractice(config: config)
        // moveColumnLeft default is cmd+shift+h; a reordered spelling must still
        // map to the move (task 1 starts focused at the right end, so moving the
        // window left changes the world).
        check("reordered modifiers match a move", tol2.handle(chord: "shift+cmd+h") == .moved)

        // MARK: - Full completion across all tasks

        var run = TutorialPractice(config: config)
        var finalOutcome: TutorialPractice.Outcome = .ignored
        var guardCount = 0
        while !run.isComplete && guardCount < 100 {
            guard let task = run.current,
                  let chord = solutionChord(for: task, world: run.world, config: config) else { break }
            finalOutcome = run.handle(chord: chord)
            guardCount += 1
        }
        check("drill completes by solving every task", run.isComplete)
        check("last outcome is allComplete", finalOutcome == .allComplete)
        check("fraction is 1 when complete", run.fraction == 1.0)
        check("headline announces completion", run.headline.lowercased().contains("done"))
        check("doneCount equals task count", run.doneCount == run.tasks.count)
        // Extra presses after completion are inert + stay complete.
        check("handle after complete stays complete", run.handle(chord: "cmd+h") == .allComplete)

        // MARK: - Reset

        run.reset()
        check("reset returns to task 0", run.index == 0)
        check("reset clears done", run.doneCount == 0)
        check("reset clears attempts", run.attempts == 0)
        check("reset reseeds the first world", run.world == run.tasks.first!.start)
        check("reset fraction back to 0", run.fraction == 0)

        // MARK: - Empty / edge config

        let empty = TutorialPractice(tasks: [])
        check("empty drill is complete", empty.isComplete)
        check("empty drill fraction is 1", empty.fraction == 1.0)
        check("empty drill has no current", empty.current == nil)
        check("empty headline mentions none", empty.headline.lowercased().contains("nothing"))
        var emptyMut = empty
        check("empty handle returns allComplete", emptyMut.handle(chord: "cmd+h") == .allComplete)

        // A custom override is honoured by the matcher.
        var custom = ScrollWMConfig.default
        custom.keybindings[.focusLeft] = ["ctrl+opt+a"]
        var customDrill = TutorialPractice(config: custom)
        check("custom binding rejects old default", customDrill.handle(chord: "cmd+h") == .ignored)
        check("custom binding accepts override", customDrill.handle(chord: "ctrl+opt+a") == .moved)

        // A cleared binding falls back to the default (still drivable).
        var cleared = ScrollWMConfig.default
        cleared.keybindings[.focusLeft] = []
        var clearedDrill = TutorialPractice(config: cleared)
        check("cleared binding falls back to default", clearedDrill.handle(chord: "cmd+h") == .moved)

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

        let hChord = TutorialPractice.chordString(keyCode: 4, flags: [.maskCommand])
        check("chordString builds cmd+h", hChord != nil)
        check("rebuilt cmd+h matches focusLeft",
              hChord.flatMap { TutorialPractice.normalize($0) } == TutorialPractice.normalize("cmd+h"))
        let stack = TutorialPractice.chordString(keyCode: 38, // j
                                                 flags: [.maskCommand, .maskControl, .maskAlternate, .maskShift])
        check("chordString canonical mod order", stack == "ctrl+opt+shift+cmd+j")
        check("chordString nil for unmapped keycode",
              TutorialPractice.chordString(keyCode: 9999, flags: []) == nil)
        // Round-trip: every focus/move default chord, rebuilt from its parsed
        // Chord, drives the same move (proves tap→deliver wiring lines up).
        let moveActions: [KeyAction] = [.focusLeft, .focusRight, .moveColumnLeft, .moveColumnRight]
        let bindings = TutorialPractice.moveBindings(config: config)
        for action in moveActions {
            guard let raw = KeyAction.defaultChords[action]?.first,
                  let parsed = Chord(string: raw), parsed.hasKey else { continue }
            let rebuilt = TutorialPractice.chordString(keyCode: parsed.keyCode, flags: parsed.cgFlags)
            let ok = rebuilt.flatMap { TutorialPractice.normalize($0) }
                .flatMap { bindings[$0] } != nil
            check("key-event round-trip drives \(action): \(raw)", ok)
        }

        // MARK: - Offscreen-render smoke test of the view

        check("view smoke render", smokeRenderView(config: config))

        print("\n[practicetest] \(passed) passed, \(failed) failed")
        return failed == 0
    }

    // MARK: - Solver helpers (a deterministic optimal play to drive tests)

    /// The chord that makes optimal progress on `task` from `world`, or nil if no
    /// move helps. Greedy + always-converging for the focus/place goals used.
    private static func solutionChord(for task: TutorialPractice.Task,
                                      world: TutorialPractice.World,
                                      config: ScrollWMConfig) -> String? {
        switch task.goal {
        case .focus(let id):
            guard let target = world.index(of: id) else { return nil }
            if target < world.focus { return chord(.focusLeft, config) }
            if target > world.focus { return chord(.focusRight, config) }
            return nil
        case .place(let id, let at):
            guard let cur = world.index(of: id) else { return nil }
            // First make sure the window is focused, then slide it to the slot.
            if world.focus != cur {
                return world.focus < cur ? chord(.focusRight, config) : chord(.focusLeft, config)
            }
            if cur > at { return chord(.moveColumnLeft, config) }
            if cur < at { return chord(.moveColumnRight, config) }
            return nil
        }
    }

    private static func chord(_ action: KeyAction, _ config: ScrollWMConfig) -> String {
        let configured = config.keybindings[action] ?? []
        let chords = configured.isEmpty ? (KeyAction.defaultChords[action] ?? []) : configured
        return chords.first ?? ""
    }

    /// Whether a task's goal is reachable from its start using its solver.
    private static func isSolvable(_ task: TutorialPractice.Task, config: ScrollWMConfig) -> Bool {
        var world = task.start
        var guardCount = 0
        while !task.goal.isSatisfied(by: world) && guardCount < 50 {
            guard let c = solutionChord(for: task, world: world, config: config),
                  let move = TutorialPractice.normalize(c).flatMap({ TutorialPractice.moveBindings(config: config)[$0] })
            else { return false }
            switch move {
            case .focusLeft:  world.moveFocus(by: -1)
            case .focusRight: world.moveFocus(by: 1)
            case .moveLeft:   world.moveWindow(by: -1)
            case .moveRight:  world.moveWindow(by: 1)
            }
            guardCount += 1
        }
        return task.goal.isSatisfied(by: world)
    }

    /// Construct the view, force layout, drive a full goal-reaching sequence, and
    /// assert nothing crashes and progress tracks. Pure offscreen — no window
    /// shown, no event tap, no real keys.
    private static func smokeRenderView(config: ScrollWMConfig) -> Bool {
        let view = TutorialPracticeView(config: config)
        view.frame = NSRect(x: 0, y: 0, width: 460, height: 320)

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

        // An ignored chord, then solve every task to completion (mirror the model
        // to know the optimal plays).
        _ = view.deliver(chord: "cmd+q")   // ignored
        var mirror = TutorialPractice(config: config)
        var guardCount = 0
        while !mirror.isComplete && guardCount < 200 {
            guard let task = mirror.current,
                  let chord = solutionChord(for: task, world: mirror.world, config: config) else { break }
            _ = view.deliver(chord: chord)
            _ = mirror.handle(chord: chord)
            guardCount += 1
        }
        guard view.isComplete, view.fraction == 1.0 else {
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

        guard captureEvents.contains(true) && captureEvents.contains(false) else {
            print("  ✗ onCaptureChange did not report start/stop"); return false
        }
        return true
    }
}
