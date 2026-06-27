import Foundation
import CoreGraphics

/// Pure, AppKit-free state machine driving the tutorial's interactive practice.
///
/// Practice is GOAL-oriented, not key-by-key. Each task shows a small strip of
/// real "window columns" with one of them you're focused on and a goal marked on
/// the strip (a window to focus, or a slot to move a window into). The user
/// drives the strip from the keyboard — focus left/right, move left/right — and
/// the windows actually slide and re-focus until the goal is reached, then the
/// next task begins. All of the decision + simulation logic lives here so it is
/// unit-testable without an `NSView` or the keyboard; the view is a thin shell
/// that renders `world` and feeds chords into `handle(chord:)`.
///
/// Matching is tolerant: a delivered chord is normalised with the same tokenizer
/// the rest of the tutorial uses (`ChordFormatter.tokenize`), so modifier order
/// and spelling never matter, and a chord can arrive as a raw config string, a
/// glyph string, or one rebuilt from a key event and still map to its move.
struct TutorialPractice {

    // MARK: - World model (the live strip the user manipulates)

    /// One window "column" on the practice strip. Colors are resolved by the
    /// view from `appName`/`title`, so this stays AppKit-free + pure.
    struct Window: Equatable {
        let id: Int
        let appName: String
        let title: String
    }

    /// The live strip state: an ordered row of windows and which one has focus.
    /// Focus and move CLAMP at the ends (no wrap) so every goal is reachable
    /// with a deterministic, finite set of presses.
    struct World: Equatable {
        var windows: [Window]
        var focus: Int

        /// The focused window's id (or -1 for an empty world).
        var focusedID: Int { windows.indices.contains(focus) ? windows[focus].id : -1 }

        /// The current index of the window with `id`, if present.
        func index(of id: Int) -> Int? { windows.firstIndex { $0.id == id } }

        /// Move focus by `delta`, clamped to the ends.
        mutating func moveFocus(by delta: Int) {
            guard !windows.isEmpty else { return }
            focus = min(max(focus + delta, 0), windows.count - 1)
        }

        /// Swap the focused window with its neighbour `delta` away; focus follows
        /// the moved window. Clamped at the ends (a no-op past either edge).
        mutating func moveWindow(by delta: Int) {
            let target = focus + delta
            guard windows.indices.contains(target) else { return }
            windows.swapAt(focus, target)
            focus = target
        }
    }

    /// The four strip moves practice teaches, each backed by a `KeyAction` so the
    /// view can render the live keycaps and the matcher can accept the config
    /// bindings.
    enum Move: Equatable {
        case focusLeft, focusRight, moveLeft, moveRight

        /// The `KeyAction` this move corresponds to (for keycap rendering).
        var action: KeyAction {
            switch self {
            case .focusLeft:  return .focusLeft
            case .focusRight: return .focusRight
            case .moveLeft:   return .moveColumnLeft
            case .moveRight:  return .moveColumnRight
            }
        }
    }

    /// What a task wants the user to achieve.
    enum Goal: Equatable {
        /// Put keyboard focus on the window with this id.
        case focus(id: Int)
        /// Get the window with this id into strip slot `at` (0 == far left).
        case place(id: Int, at: Int)

        func isSatisfied(by world: World) -> Bool {
            switch self {
            case .focus(let id):       return world.focusedID == id
            case .place(let id, let at): return world.index(of: id) == at
            }
        }

        /// The id of the window the goal marks (the one to focus or move).
        var targetID: Int {
            switch self {
            case .focus(let id):        return id
            case .place(let id, _):     return id
            }
        }

        /// For a `place` goal, the slot to draw as the empty target; nil for focus.
        var targetSlot: Int? {
            switch self {
            case .focus:               return nil
            case .place(_, let at):    return at
            }
        }
    }

    /// One practice task: an instruction, the strip it starts from, the goal, and
    /// the moves it teaches (so the view can show just the relevant keys).
    struct Task: Equatable {
        let instruction: String
        let start: World
        let goal: Goal
        let moves: [Move]
    }

    /// The result of feeding a chord to `handle(chord:)`.
    enum Outcome: Equatable {
        /// A practice move was applied; the strip changed but the goal isn't met.
        case moved
        /// A practice move was recognised but the strip couldn't change (a wall).
        case blocked
        /// The goal was reached and another task is now active.
        case taskComplete
        /// The goal was reached on the LAST task — the whole drill is done.
        case allComplete
        /// The chord isn't one of the moves this drill uses (ignored).
        case ignored
    }

    // MARK: - State

    let tasks: [Task]
    /// Index of the active task; equals `tasks.count` when the drill is done.
    private(set) var index: Int = 0
    /// The live strip for the active task (reset to the next task's start on
    /// completion).
    private(set) var world: World
    /// Per-task completion flags, parallel to `tasks`.
    private(set) var done: [Bool]
    /// Total recognised presses across the whole drill.
    private(set) var attempts: Int = 0

    /// Precomputed chord → move map from the live config (so matching is O(1)).
    private let moveForChord: [NormalizedChord: Move]

    // MARK: - Construction

    /// Build the drill from the live config (the default task progression, with
    /// the focus/move bindings taken from the config). Pure: depends only on
    /// `config`.
    init(config: ScrollWMConfig) {
        self.init(tasks: TutorialPractice.defaultTasks,
                  moveForChord: TutorialPractice.moveBindings(config: config))
    }

    /// Direct initializer (tests supply tasks + bindings to cover edge cases).
    init(tasks: [Task],
         moveForChord: [NormalizedChord: Move] = TutorialPractice.moveBindings(config: .default)) {
        self.tasks = tasks
        self.world = tasks.first?.start ?? World(windows: [], focus: 0)
        self.done = Array(repeating: false, count: tasks.count)
        self.moveForChord = moveForChord
    }

    /// Map every config chord bound to the four strip moves to its `Move`,
    /// falling back to the built-in defaults for an unset (or cleared) action so
    /// the drill is always drivable.
    static func moveBindings(config: ScrollWMConfig) -> [NormalizedChord: Move] {
        var map: [NormalizedChord: Move] = [:]
        func add(_ action: KeyAction, _ move: Move) {
            let configured = config.keybindings[action] ?? []
            let chords = configured.isEmpty ? (KeyAction.defaultChords[action] ?? []) : configured
            for chord in chords { if let n = normalize(chord) { map[n] = move } }
        }
        add(.focusLeft, .focusLeft)
        add(.focusRight, .focusRight)
        add(.moveColumnLeft, .moveLeft)
        add(.moveColumnRight, .moveRight)
        return map
    }

    /// The default task progression: focus a window to your left, then to your
    /// right, then move a window to the front, then a combined focus-then-move.
    /// A handful of recognisable "apps" give the columns colour + a title.
    static let defaultTasks: [Task] = {
        func w(_ id: Int, _ app: String, _ title: String) -> Window {
            Window(id: id, appName: app, title: title)
        }

        // 1) Focus left: you're on the right end, the goal is the far-left window.
        let t1 = Task(
            instruction: "Focus the highlighted window on the left.",
            start: World(windows: [
                w(0, "Safari", "Docs"),
                w(1, "Ghostty", "nvim"),
                w(2, "Cursor", "main.swift"),
            ], focus: 2),
            goal: .focus(id: 0),
            moves: [.focusLeft])

        // 2) Focus right: you're on the left end, reach across to the far right.
        let t2 = Task(
            instruction: "Now focus the highlighted window on the right.",
            start: World(windows: [
                w(0, "Ghostty", "claude"),
                w(1, "Cursor", "TeleportEngine.swift"),
                w(2, "Safari", "Docs"),
                w(3, "Spotify", "Now Playing"),
            ], focus: 0),
            goal: .focus(id: 3),
            moves: [.focusRight])

        // 3) Move: slide the focused window all the way to the front (slot 0).
        let t3 = Task(
            instruction: "Move the focused window into the empty slot on the left.",
            start: World(windows: [
                w(0, "Cursor", "main.swift"),
                w(1, "Safari", "Docs"),
                w(2, "Ghostty", "nvim"),
            ], focus: 2),
            goal: .place(id: 2, at: 0),
            moves: [.moveLeft])

        // 4) Combine: focus the highlighted window, then move it into the slot.
        let t4 = Task(
            instruction: "Focus the highlighted window, then move it into the slot.",
            start: World(windows: [
                w(0, "Messages", "Chat"),
                w(1, "Safari", "Docs"),
                w(2, "Cursor", "main.swift"),
                w(3, "Ghostty", "nvim"),
            ], focus: 0),
            goal: .place(id: 3, at: 0),
            moves: [.focusRight, .moveLeft])

        return [t1, t2, t3, t4]
    }()

    // MARK: - Derived state

    var isComplete: Bool { index >= tasks.count }
    /// The active task, or nil when finished / empty.
    var current: Task? { tasks.indices.contains(index) ? tasks[index] : nil }
    var doneCount: Int { done.lazy.filter { $0 }.count }
    /// Completion fraction in `0...1`. An empty drill is vacuously complete (1).
    var fraction: Double { tasks.isEmpty ? 1.0 : Double(doneCount) / Double(tasks.count) }

    /// A short status line, e.g. "Task 2 of 4".
    var headline: String {
        if tasks.isEmpty { return "Nothing to practice." }
        if isComplete { return "All \(tasks.count) tasks done." }
        return "Task \(index + 1) of \(tasks.count)"
    }

    // MARK: - Transition

    /// Feed a delivered chord. A chord bound to a strip move applies it and may
    /// complete the task; anything else is ignored (so reading-keys never break
    /// the drill). Once complete it stays complete.
    @discardableResult
    mutating func handle(chord: String) -> Outcome {
        guard !isComplete else { return .allComplete }
        guard let pressed = TutorialPractice.normalize(chord),
              let move = moveForChord[pressed] else { return .ignored }

        attempts += 1
        let before = world
        switch move {
        case .focusLeft:  world.moveFocus(by: -1)
        case .focusRight: world.moveFocus(by: 1)
        case .moveLeft:   world.moveWindow(by: -1)
        case .moveRight:  world.moveWindow(by: 1)
        }

        if let goal = current?.goal, goal.isSatisfied(by: world) {
            done[index] = true
            index += 1
            if index < tasks.count {
                world = tasks[index].start
                return .taskComplete
            }
            return .allComplete
        }
        return world == before ? .blocked : .moved
    }

    /// Restart from the first task, clearing progress.
    mutating func reset() {
        index = 0
        world = tasks.first?.start ?? World(windows: [], focus: 0)
        done = Array(repeating: false, count: tasks.count)
        attempts = 0
    }

    // MARK: - Chord normalisation (pure, shared)

    /// A chord reduced to a comparison key: the *set* of modifier glyphs (order
    /// independent) plus the single non-modifier key symbol.
    struct NormalizedChord: Hashable {
        let modifiers: Set<String>
        let key: String
    }

    /// Reduce a chord string to a `NormalizedChord` for tolerant comparison, or
    /// nil when it has no usable non-modifier key (empty / modifier-only /
    /// malformed). Reuses `ChordFormatter` tokenisation so it matches every chord
    /// spelling the rest of the app accepts.
    static func normalize(_ chord: String) -> NormalizedChord? {
        let tokens = ChordFormatter.tokenize(chord)
        guard !tokens.isEmpty else { return nil }
        var modifiers = Set<String>()
        var key: String? = nil
        for token in tokens {
            if let glyph = ChordFormatter.modifierSymbols[token] {
                modifiers.insert(glyph)
            } else {
                if key != nil { return nil }   // a real key event carries one key
                key = ChordFormatter.symbol(for: token)
            }
        }
        guard let key, !key.isEmpty else { return nil }
        return NormalizedChord(modifiers: modifiers, key: key)
    }

    // MARK: - Key-event → chord string (for the app-side wiring)

    /// Build a config-style chord string (e.g. `"ctrl+opt+cmd+l"`) from a raw
    /// keyboard event's keycode + CGEvent modifier flags. The coordinator's key
    /// monitor turns a physical press into a chord it forwards to
    /// `TutorialPracticeView.deliver(chord:)`. Returns nil for an unmapped
    /// keycode. Pure: a deterministic reverse of `Chord.keyCodes`.
    static func chordString(keyCode: UInt32, flags: CGEventFlags) -> String? {
        guard let key = keyName(for: keyCode) else { return nil }
        var parts: [String] = []
        if flags.contains(.maskControl)   { parts.append("ctrl") }
        if flags.contains(.maskAlternate) { parts.append("opt") }
        if flags.contains(.maskShift)     { parts.append("shift") }
        if flags.contains(.maskCommand)   { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// The canonical config name for a virtual keycode (deterministic reverse of
    /// `Chord.keyCodes`).
    static func keyName(for keyCode: UInt32) -> String? { keyNameByCode[keyCode] }

    private static let keyNameByCode: [UInt32: String] = {
        var map: [UInt32: String] = [:]
        for (name, code) in Chord.keyCodes.sorted(by: { $0.key < $1.key }) where map[code] == nil {
            map[code] = name
        }
        return map
    }()
}
