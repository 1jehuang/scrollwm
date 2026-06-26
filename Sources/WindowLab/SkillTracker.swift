import Foundation

/// Stateful, on-disk companion to the pure `KeybindingProficiency`.
///
/// `SkillTracker` is the thin I/O shell: it holds one `ActionSkill` per
/// `KeyAction`, persists the map across launches (unlearning unfolds over days
/// or weeks, so an in-memory counter would never see it), and asks the pure
/// policy for every decision. Each `record(...)` returns a `Regression` ONLY on
/// a worsening transition (proficient -> rusty -> unlearned), so the caller can
/// nudge exactly once per slip instead of every keypress.
///
/// Test-safety: the production `run` path is the only caller that constructs a
/// tracker (see `ScrollWMController.startSkillTracking`), so the headless suites
/// — which build the controller but never call that — never touch this file.
/// The store also honors `RestoreStore.subdirectory`, so sandbox/headless runs
/// that redirect it can't write the user's real history. A clock is injectable
/// so tests are deterministic.
final class SkillTracker {

    /// The live per-action history. Keyed by `KeyAction`; missing entries read
    /// as `.empty`.
    private var skills: [KeyAction: ActionSkill]

    /// Where the JSON history lives. Injected in tests; defaults under the app
    /// support dir (honoring the sandbox subdirectory redirect).
    private let fileURL: URL

    /// Clock seam. Defaults to `Date()`; tests inject a controllable clock.
    private let now: () -> Date

    /// Coalesced background save (records arrive at human keypress speed; we
    /// don't want a synchronous disk write on the hotkey path).
    private var pendingSave: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "scrollwm.skilltracker.save", qos: .utility)

    /// A worsening transition worth surfacing to the user.
    struct Regression: Equatable {
        let action: KeyAction
        let level: KeybindingProficiency.Level
        let score: Double
    }

    init(fileURL: URL = SkillTracker.defaultFileURL,
         now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        self.skills = SkillTracker.load(from: fileURL)
    }

    /// Default history file, under the same app-support dir as the config and
    /// restore files. Honors `RestoreStore.subdirectory` so a sandbox/headless
    /// redirect keeps the real history untouched.
    static var defaultFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(RestoreStore.subdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("skills.json")
    }

    // MARK: - Recording

    /// Fold one invocation of `action` into its history. Returns a `Regression`
    /// iff this invocation pushed the action's proficiency to a WORSE level than
    /// before (so a nudge fires once per slip, never on a steady state).
    @discardableResult
    func record(_ action: KeyAction, channel: SkillChannel) -> Regression? {
        let before = skills[action] ?? .empty
        let beforeRank = KeybindingProficiency.assess(before).regressionRank
        let after = KeybindingProficiency.updated(before, channel: channel, at: now())
        skills[action] = after
        scheduleSave()

        let afterLevel = KeybindingProficiency.assess(after)
        guard afterLevel.regressionRank > beforeRank else { return nil }
        return Regression(action: action, level: afterLevel,
                          score: KeybindingProficiency.regressionScore(after))
    }

    // MARK: - Queries

    /// Current proficiency level for one action.
    func level(_ action: KeyAction) -> KeybindingProficiency.Level {
        KeybindingProficiency.assess(skills[action] ?? .empty)
    }

    /// The raw record (for reporting / tests).
    func skill(_ action: KeyAction) -> ActionSkill { skills[action] ?? .empty }

    /// Every action that has regressed (rusty or unlearned), worst first, so the
    /// menu / CLI can surface "keybindings you've stopped using."
    func regressedActions() -> [(action: KeyAction, level: KeybindingProficiency.Level, score: Double)] {
        KeyAction.allCases.compactMap { action in
            let s = skills[action] ?? .empty
            let level = KeybindingProficiency.assess(s)
            guard level.isRegressed else { return nil }
            return (action, level, KeybindingProficiency.regressionScore(s))
        }
        .sorted { $0.score > $1.score }
    }

    // MARK: - Persistence

    /// Flush any pending save synchronously (clean shutdown).
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        SkillTracker.write(skills, to: fileURL)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = skills
        let url = fileURL
        let work = DispatchWorkItem { SkillTracker.write(snapshot, to: url) }
        pendingSave = work
        // Coalesce a burst of records into one write a moment later.
        saveQueue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Serialize keyed by the action's stable rawValue so the file is readable
    /// and survives enum reordering.
    private static func write(_ skills: [KeyAction: ActionSkill], to url: URL) {
        let keyed = Dictionary(uniqueKeysWithValues: skills.map { ($0.key.rawValue, $0.value) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(keyed) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func load(from url: URL) -> [KeyAction: ActionSkill] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let keyed = try? decoder.decode([String: ActionSkill].self, from: data) else { return [:] }
        var out: [KeyAction: ActionSkill] = [:]
        for (raw, skill) in keyed {
            if let action = KeyAction(rawValue: raw) { out[action] = skill }
        }
        return out
    }
}
