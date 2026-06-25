import Foundation
import Carbon
import CoreGraphics

// CONTROLLER / CONFIG / CONTROL-SOCKET fuzzer (owned by the `fuzzctrl` agent).
//
// Goal: fuzz the full app surface that touches untrusted input:
//   - random CHORD sequences (interleaved with safe `scrollwm <verb>` control
//     commands) through the real `ScrollWMController` (`debugDeliverChord` +
//     `handleControlCommand`) after a headless arrange, asserting it never
//     crashes / desyncs and management state stays coherent;
//   - JSONC `ScrollWMConfig.parse` on random/garbled/huge/nested input (never
//     traps, always returns a config that honors its clamps or throws cleanly);
//   - `ControlCommands` verb+arg parsing (the `scrollwm <verb>` surface);
//   - `Chord(string:)` and width/arg parsing on arbitrary unicode/ascii.
//
// Reuse `SplitMix64` from Fuzz.swift. Production edits allowed ONLY in
// Config.swift / ControlCommands.swift / ControlCLI.swift / FuzzController.swift;
// report anything else to the coordinator. Keep all logic self-contained here;
// encode regressions as fixed seeds. Entry point wired in main.swift.
//
// Everything is fully HEADLESS: the controller runs against an in-memory
// `SimWindowWorld` (installed as `AXSource.backend`), `RestoreStore` is
// redirected to the sandbox subdir, the menu-bar status item is suppressed, and
// `debugDeliverChord` routes a chord through the SAME tap->Carbon precedence as
// a real keypress with NO CGEvent posted. So no real window is ever spawned,
// moved, focused, or closed, and no global keystroke is injected.

// MARK: - String fuzz vocabulary

private enum FuzzText {
    /// Scalars that stress the tokenizers/JSON-comment-stripper: ascii letters,
    /// digits, JSON punctuation, the chord modifier glyphs + arrows, quotes,
    /// backslashes, slashes, whitespace, control chars, and a few wide/emoji
    /// scalars. Drawn uniformly, so most strings are pure garbage (the point).
    static let scalars: [Unicode.Scalar] = {
        var s: [Unicode.Scalar] = []
        func add(_ r: ClosedRange<UInt32>) { for v in r { if let u = Unicode.Scalar(v) { s.append(u) } } }
        add(0x20...0x7E)                 // printable ascii (covers + - { } [ ] " : , / \ etc.)
        add(0x09...0x0D)                 // tab/newlines/CR
        add(0x00...0x08)                 // low control chars
        // Chord modifier glyphs + arrows + a couple of multibyte / emoji scalars.
        for v: UInt32 in [0x2318, 0x2325, 0x2303, 0x21E7,            // ⌘ ⌥ ⌃ ⇧
                          0x2190, 0x2191, 0x2192, 0x2193,            // ← ↑ → ↓
                          0x00E9, 0x4E2D, 0x1F600, 0x1F4A9, 0x0301,  // é 中 😀 💩 combining acute
                          0xFEFF] {                                  // BOM/zero-width
            if let u = Unicode.Scalar(v) { s.append(u) }
        }
        return s
    }()

    /// A random string of `len` scalars from the salad above.
    static func salad(_ rng: inout SplitMix64, len: Int) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(len)
        for _ in 0..<len { out.append(scalars[rng.int(scalars.count)]) }
        return String(out)
    }

    /// Chord-flavored tokens: real modifier/key names, glyphs, separators, and
    /// junk, glued with random separators so `Chord(string:)` sees plausible and
    /// malformed input alike.
    static let chordTokens = [
        "cmd", "command", "opt", "option", "alt", "ctrl", "control", "shift",
        "⌘", "⌥", "⌃", "⇧", "+", "-", " ", "++", "--", "+-",
        "a", "z", "h", "l", "1", "9", "0", "left", "right", "up", "down",
        "escape", "esc", "space", "return", "enter", "tab", "delete",
        "\\", "backslash", "/", "slash", ";", "'", ",", ".", "=", "`",
        "[", "]", "minus", "hyphen", "fn", "meta", "super", "hyper", "",
        "f1", "f13", "пробел", "中", "😀", "cmdcmd", "shiftshift",
    ]

    static func chordString(_ rng: inout SplitMix64) -> String {
        switch rng.int(10) {
        case 0, 1: return salad(&rng, len: rng.int(in: 0...12))            // pure garbage
        case 2: return ""
        default:
            let n = rng.int(in: 1...6)
            return (0..<n).map { _ in chordTokens[rng.int(chordTokens.count)] }
                .joined(separator: rng.bool() ? "+" : (rng.bool() ? "-" : " "))
        }
    }

    /// Width-argument flavored tokens for `parseWidthFraction`.
    static let widthTokens = [
        "25", "50", "75", "100", "0", "0.0", "0.25", "0.5", "1", "1.0", "2",
        "-1", "-0.5", "1e9", "1e-9", "inf", "-inf", "infinity", "nan", "NaN",
        "0x10", "50%", " 50 ", "", "abc", "1.0.0", "99999999999999999999",
        ".5", "5.", "+0.5", "0,5", "🤡", "1_000",
    ]

    static func widthString(_ rng: inout SplitMix64) -> String {
        rng.int(4) == 0 ? salad(&rng, len: rng.int(in: 0...8))
                        : widthTokens[rng.int(widthTokens.count)]
    }
}

// MARK: - Config JSONC parse fuzz

private enum ConfigFuzz {
    /// Build a random JSON-ish string. Mixes: structurally-valid random objects,
    /// near-valid configs with adversarial values, deep nesting, byte salad, and
    /// mutated copies of the documented default file (to exercise the comment
    /// stripper). Returned as raw text; parse must never trap on any of it.
    static func makeInput(_ rng: inout SplitMix64) -> String {
        switch rng.int(8) {
        case 0:
            return FuzzText.salad(&rng, len: rng.int(in: 0...400))
        case 1:
            // Huge but shallow: a long array / string the parser must chew without
            // stack growth.
            let n = rng.int(in: 1000...60_000)
            return "[" + String(repeating: rng.bool() ? "0," : "\"x\"," , count: n) + "0]"
        case 2:
            // Deeply nested: JSONSerialization has a depth cap and must THROW
            // (caught by parse), never trap.
            let depth = rng.int(in: 100...2000)
            return String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        case 3:
            return mutateDefault(&rng)
        case 4:
            // Comment-stripper stress: lines with quotes, slashes, escapes.
            return commentSalad(&rng)
        default:
            return jsonValue(&rng, depth: rng.int(in: 0...4))
        }
    }

    /// A random JSON value (object/array/string/number/literal) with bounded depth.
    private static func jsonValue(_ rng: inout SplitMix64, depth: Int) -> String {
        if depth <= 0 || rng.int(3) == 0 {
            switch rng.int(6) {
            case 0: return jsonNumber(&rng)
            case 1: return "\"" + escaped(FuzzText.salad(&rng, len: rng.int(in: 0...10))) + "\""
            case 2: return "true"
            case 3: return "false"
            case 4: return "null"
            default: return jsonNumber(&rng)
            }
        }
        let n = rng.int(in: 0...5)
        if rng.bool() {
            // Object: bias keys toward real config keys so value-typed branches run.
            let keys = ["layout", "menuBar", "update", "focusMode", "arrangeOnFirstGrant",
                        "keybindings", "spawn", "columnGap", "minColumnWidth", "widthPresets",
                        "spawnWidth", "adoptScope", "stripDisplay", "pointsPerScreen",
                        "showKeyHints", "enabled", "automatic", "checkIntervalHours",
                        "allowPrerelease", "focusNext", "width25", FuzzText.salad(&rng, len: 4)]
            let pairs = (0..<n).map { _ -> String in
                let k = escaped(keys[rng.int(keys.count)])
                return "\"\(k)\":\(jsonValue(&rng, depth: depth - 1))"
            }
            return "{" + pairs.joined(separator: ",") + "}"
        } else {
            let items = (0..<n).map { _ in jsonValue(&rng, depth: depth - 1) }
            return "[" + items.joined(separator: ",") + "]"
        }
    }

    private static func jsonNumber(_ rng: inout SplitMix64) -> String {
        switch rng.int(8) {
        case 0: return "0"
        case 1: return "-1"
        case 2: return String(rng.int(in: -1000...1000))
        case 3: return "0.\(rng.int(in: 0...999))"
        case 4: return "1e\(rng.int(in: -40...40))"
        case 5: return "\(rng.int(in: 0...100)).\(rng.int(in: 0...999))"
        case 6: return "999999999999999999999999"
        default: return "-\(rng.int(in: 0...500)).\(rng.int(in: 0...999))"
        }
    }

    /// Minimal JSON string escaping so generated strings stay parseable.
    private static func escaped(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) }
                else { out.unicodeScalars.append(ch) }
            }
        }
        return out
    }

    /// Take the documented default file and randomly perturb it: inject `//`
    /// comments mid-line, flip quotes, splice salad, drop braces.
    private static func mutateDefault(_ rng: inout SplitMix64) -> String {
        var lines = ScrollWMConfig.defaultFileContents
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let edits = rng.int(in: 0...8)
        for _ in 0..<edits {
            guard !lines.isEmpty else { break }
            let i = rng.int(lines.count)
            switch rng.int(6) {
            case 0: lines[i] += " // \(FuzzText.salad(&rng, len: rng.int(in: 0...8)))"
            case 1: lines[i] = lines[i].replacingOccurrences(of: "\"", with: rng.bool() ? "'" : "")
            case 2: lines[i] = String(lines[i].reversed())
            case 3: lines.remove(at: i)
            case 4: lines[i] = lines[i].replacingOccurrences(of: ":", with: "")
            default: lines[i] += FuzzText.salad(&rng, len: rng.int(in: 0...6))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Lines crafted to exercise the `//`-comment stripper's in-string / escape
    /// state machine with quotes, slashes, and trailing backslashes.
    private static func commentSalad(_ rng: inout SplitMix64) -> String {
        let frags = ["{", "}", "\"key\": \"a//b\",", "// comment", "\"x\": \"c:\\\\\",",
                     "\"u\": \"http://example\",", "value, // trail", "\"\\\"\",",
                     "\"unterminated", "/ not a comment", "\\\\", "\"end\\", ""]
        let n = rng.int(in: 0...20)
        return (0..<n).map { _ in frags[rng.int(frags.count)] }.joined(separator: "\n")
    }

    /// Run `iters` parse attempts; returns failure messages (empty == pass).
    /// A trap inside `parse` aborts the process and the seed pinpoints it; a
    /// thrown ConfigError is a legal outcome. A RETURNED config must honor every
    /// clamp the parser documents.
    static func run(seed: UInt64, iters: Int) -> [String] {
        var rng = SplitMix64(seed: seed)
        var fails: [String] = []
        func bad(_ s: String, _ input: String) {
            if fails.count < 12 {
                let snip = input.count > 200 ? String(input.prefix(200)) + "…(\(input.count))" : input
                fails.append("config parse seed \(seed): \(s)\n      input: \(snip.debugDescription)")
            }
        }
        for _ in 0..<iters {
            let input = makeInput(&rng)
            let cfg: ScrollWMConfig
            do { cfg = try ScrollWMConfig.parse(jsonc: input) }
            catch { continue }   // clean throw is acceptable
            // Returned config must satisfy the documented clamps/guarantees.
            if let sw = cfg.layout.spawnWidth, !(sw >= 0.05 && sw <= 1.0) {
                bad("spawnWidth \(sw) outside clamp [0.05, 1.0]", input)
            }
            if cfg.layout.widthPresets.isEmpty { bad("widthPresets ended up empty", input) }
            if cfg.menuBar.pointsPerScreen < 8 { bad("menuBar.pointsPerScreen \(cfg.menuBar.pointsPerScreen) < 8", input) }
            if cfg.menuBar.minWidth < 12 { bad("menuBar.minWidth \(cfg.menuBar.minWidth) < 12", input) }
            if cfg.menuBar.maxWidth < cfg.menuBar.minWidth { bad("menuBar.maxWidth < minWidth", input) }
            if cfg.update.checkIntervalHours < 1.0 { bad("update.checkIntervalHours \(cfg.update.checkIntervalHours) < 1", input) }
            if !cfg.menuBar.pointsPerScreen.isFinite || !cfg.menuBar.maxWidth.isFinite {
                bad("menuBar sizing went non-finite", input)
            }
        }
        return fails
    }
}

// MARK: - Pure parser primitives (Chord, width fraction)

private enum PrimitiveFuzz {
    static func run(seed: UInt64, iters: Int) -> [String] {
        var rng = SplitMix64(seed: seed)
        var fails: [String] = []
        func bad(_ s: String) { if fails.count < 12 { fails.append("primitive seed \(seed): \(s)") } }

        for _ in 0..<iters {
            // --- Chord(string:): never traps; deterministic; key flag consistent. ---
            let s = rng.bool() ? FuzzText.chordString(&rng) : FuzzText.salad(&rng, len: rng.int(in: 0...20))
            let a = Chord(string: s)
            let b = Chord(string: s)
            if a != b { bad("Chord(\(s.debugDescription)) not deterministic") }
            if let c = a {
                if c.hasKey != (c.keyCode != UInt32.max) {
                    bad("Chord(\(s.debugDescription)) hasKey/keyCode mismatch")
                }
                // A parsed key must be one of the codes we accept (or "none").
                if c.keyCode != UInt32.max && !Chord.keyCodes.values.contains(c.keyCode) {
                    bad("Chord(\(s.debugDescription)) produced unknown keyCode \(c.keyCode)")
                }
            }

            // --- parseWidthFraction: never traps; nil or a finite (0,1] fraction. ---
            let ws = FuzzText.widthString(&rng)
            if let f = ScrollWMController.parseWidthFraction(ws) {
                if !f.isFinite || f <= 0 || f > 1 {
                    bad("parseWidthFraction(\(ws.debugDescription)) -> \(f) outside (0,1]")
                }
            }
        }
        return fails
    }
}

// MARK: - Stateful controller session fuzzer (chords + control commands)

/// Drives a REAL `ScrollWMController` headlessly: arranges seeded sim windows,
/// then fires a random mix of chord deliveries and safe `scrollwm` control
/// commands, asserting management state stays coherent after each, and that
/// `release()` fully cleans up. A trap or invariant break is deterministic from
/// (seed, op log).
private final class ControllerSession {
    private let seed: UInt64
    private var rng: SplitMix64
    private let world: SimWindowWorld
    private let controller: ScrollWMController
    private var pids: [pid_t] = []
    private(set) var log: [String] = []
    var verbose = false

    /// Verbs with real-world side effects (quit/relaunch/network/disk-config/
    /// window UI) that must NEVER be exercised by the fuzzer. We replicate
    /// `handleControlCommand`'s own tokenization to gate on the parsed verb, so a
    /// random token can never trip one even if generated verbatim.
    private static let dangerousVerbs: Set<String> = [
        "quit", "update", "update-check", "tutorial", "reload", "reload-config",
        "display", "focus-mode", "focusmode",
    ]

    /// Real binding chords (drive actual handlers) + the jump combos.
    private static let bindingChords: [String] = {
        var c = KeyAction.defaultChords.values.flatMap { $0 }
        c += (1...9).map { "ctrl+opt+\($0)" }   // jump-to-column
        return c
    }()

    private func record(_ op: String) {
        log.append(op)
        if verbose { print(String(format: "  %4d  %@", log.count - 1, op as NSString)) }
    }

    init(seed: UInt64) {
        self.seed = seed
        self.rng = SplitMix64(seed: seed)
        // Isolate crash-recovery state from the real session BEFORE building the
        // controller (its init reads the restore file).
        RestoreStore.subdirectory = "ScrollWM-Sandbox"
        RestoreStore.clear()
        self.world = Headless.install()
        self.controller = ScrollWMController()
        scrollWMControllerKeepAlive = controller
        // Hard-lock every arrange path to the seeded pids, so even a `toggle`/
        // `arrange` control command can only ever touch sim windows.
        // (Belt-and-suspenders with the explicit pidFilter below.)
        // sandboxPIDs is filled in `start()` once pids are seeded.
    }

    /// Seed windows + arrange. Returns false if nothing got managed (skip run).
    func start() -> Bool {
        let count = rng.int(in: 1...6)
        let frame = controller.debugScreenFrame
        let (seeded, _) = Headless.seedWindows(
            world, count: count, startPID: 6000,
            within: frame, width: CGFloat(rng.int(in: 240...420)),
            height: CGFloat(rng.int(in: 240...420)), titlePrefix: "SimWin")
        pids = seeded
        let pidSet = Set(seeded)
        controller.sandboxPIDs = pidSet
        record("arrange(\(count))")
        controller.arrange(pidFilter: pidSet)
        Headless.pump(0.08)
        return controller.isManaging && controller.debugSlotCount > 0
    }

    /// Run `ops` random operations, checking invariants after each. Returns nil
    /// on success or the first failure description.
    func run(ops: Int) -> String? {
        guard start() else { return nil }   // degenerate seed: nothing to manage
        if let v = checkInvariants(after: "arrange") { return v }
        for step in 0..<ops {
            performRandomOp()
            Headless.pump(0.04)
            if let v = checkInvariants(after: "step \(step)") { return v }
        }
        return finish()
    }

    private func performRandomOp() {
        switch rng.int(10) {
        case 0...4:
            // Real binding chord (drives an actual handler).
            let s = Self.bindingChords[rng.int(Self.bindingChords.count)]
            if let c = Chord(string: s) {
                record("chord \(s)")
                _ = controller.debugDeliverChord(c)
            }
        case 5, 6:
            // Chord parsed from a random/garbled string (most miss harmlessly).
            let s = FuzzText.chordString(&rng)
            if let c = Chord(string: s) {
                record("chord? \(s.debugDescription)")
                _ = controller.debugDeliverChord(c)
            }
        case 7:
            // Raw arbitrary chord straight through the routing seam (no Chord
            // construction): random keycode + modifier flags.
            let kc = rng.bool() ? UInt32.max : UInt32(rng.int(in: 0...140))
            var flags: CGEventFlags = []
            var carbon: UInt32 = 0
            if rng.bool() { flags.insert(.maskCommand); carbon |= UInt32(cmdKey) }
            if rng.bool() { flags.insert(.maskAlternate); carbon |= UInt32(optionKey) }
            if rng.bool() { flags.insert(.maskControl); carbon |= UInt32(controlKey) }
            if rng.bool() { flags.insert(.maskShift); carbon |= UInt32(shiftKey) }
            record("rawChord kc=\(kc) carbon=\(carbon)")
            _ = controller.debugDeliverChord(keyCode: kc, cgFlags: flags, carbonModifiers: carbon)
        default:
            // Safe control command (the `scrollwm <verb>` surface).
            let line = makeControlLine()
            // Mirror handleControlCommand's tokenizer to gate dangerous verbs.
            let verb = line.split(separator: " ").first.map { $0.lowercased() } ?? ""
            if Self.dangerousVerbs.contains(verb) { return }
            record("cmd \(line.debugDescription)")
            let reply = controller.handleControlCommand(line)
            if reply.isEmpty { /* fall through to invariant */ }
            lastReply = reply
            lastWasStatus = (verb == "status")
        }
    }

    private var lastReply: String?
    private var lastWasStatus = false

    private func makeControlLine() -> String {
        // Safe verb vocabulary (dangerous verbs deliberately excluded) + args.
        let verbs = ["ping", "status", "arrange", "release", "toggle", "focus",
                     "move", "workspace", "ws", "width", "close", ""]
        let args = ["next", "prev", "previous", "left", "right", "up", "down",
                    "1", "2", "0", "-1", "99", "25", "50", "75", "100", "0.5",
                    "fit", "centered", "garbage", FuzzText.salad(&rng, len: rng.int(in: 0...6))]
        var tokens: [String]
        if rng.int(6) == 0 {
            // Pure salad line (hits the unknown-verb branch and tokenizer edges).
            tokens = [FuzzText.salad(&rng, len: rng.int(in: 0...10))]
        } else {
            tokens = [verbs[rng.int(verbs.count)]]
            let extra = rng.int(in: 0...3)
            for _ in 0..<extra { tokens.append(args[rng.int(args.count)]) }
        }
        // Random whitespace joins (single/multiple/leading spaces) to stress split.
        return (rng.bool() ? "" : " ") + tokens.joined(separator: rng.bool() ? " " : "  ")
    }

    /// Release + assert teardown, mirroring the e2e cleanup checks.
    private func finish() -> String? {
        record("release")
        controller.release()
        Headless.pump(0.08)
        if controller.isManaging { return fail("controller still managing after release()") }
        if controller.debugSlotCount != 0 { return fail("strip not empty after release(): \(controller.debugSlotCount)") }
        // Management tap is gone: a management chord must no longer be consumed.
        if let h = Chord(string: "cmd+h"), controller.debugDeliverChord(h) {
            return fail("management chord still handled after release()")
        }
        return nil
    }

    /// Tear down the world + global keep-alive so the controller (and its timers/
    /// observers) deallocate before the next session.
    func teardown() {
        if controller.isManaging { controller.release() }
        controller.sandboxPIDs = nil
        scrollWMControllerKeepAlive = nil
        Headless.uninstall()
        RestoreStore.clear()
        Headless.pump(0.05)
    }

    private func fail(_ s: String) -> String {
        """
        CONTROLLER INVARIANT VIOLATION: \(s)
          seed: \(seed)
          replay: WindowLab fuzzctrl --replay \(seed)
          ops (\(log.count)):
            \(log.suffix(60).joined(separator: "\n    "))
        """
    }

    private func checkInvariants(after ctx: String) -> String? {
        func bad(_ s: String) -> String { fail("after \(ctx): \(s)") }

        let slotCount = controller.debugSlotCount
        let titles = controller.debugSlotTitles
        let focus = controller.debugFocusIndex
        let aw = controller.debugActiveWorkspace
        let wc = controller.debugWorkspaceCount

        // 1. Titles array tracks the slot count.
        if titles.count != slotCount { return bad("slotTitles.count \(titles.count) != slotCount \(slotCount)") }

        // 2. Workspace bounds.
        if wc < 1 { return bad("workspaceCount \(wc) < 1") }
        if aw < 0 || aw >= wc { return bad("activeWorkspace \(aw) out of range 0..<\(wc)") }

        // 3. Focus bounds.
        if slotCount == 0 {
            if focus != 0 { return bad("focusIndex \(focus) on empty strip (expected 0)") }
        } else if focus < 0 || focus >= slotCount {
            return bad("focusIndex \(focus) out of range 0..<\(slotCount)")
        }

        // 4. No duplicate managed windows (seeded titles are unique, so a dup is
        // the classic double-adopt desync).
        if Set(titles).count != titles.count { return bad("duplicate managed window titles: \(titles)") }

        // 5. Focused width finite and positive when managing a non-empty strip.
        if slotCount > 0 {
            let w = controller.debugFocusedWidth
            if !w.isFinite || w <= 0 { return bad("focused width not sane: \(w)") }
            // 6. Model-vs-reality width parity for the focused (healthy) window:
            // the engine reads back the real frame, so model must equal the sim
            // frame. A divergence is the desync class of bug we guard against.
            let ft = controller.debugFocusedTitle
            if let realW = simWidth(forTitle: ft), abs(realW - w) > 2.0 {
                return bad("width desync for \(ft): model \(w) vs real \(realW)")
            }
        }

        // 7. status JSON must be valid JSON (it is the script-facing contract).
        if lastWasStatus, let reply = lastReply {
            if reply.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) == nil {
                return bad("status returned non-JSON: \(reply.prefix(120))")
            }
            lastWasStatus = false
        }
        // 8. Any control reply is non-empty (every verb returns a line).
        if let reply = lastReply, reply.isEmpty { return bad("control command returned empty reply") }
        lastReply = nil
        return nil
    }

    /// Current real (sim) width of the managed window with the given title.
    private func simWidth(forTitle title: String) -> CGFloat? {
        guard !title.isEmpty else { return nil }
        for pid in pids {
            for w in AXSource.windows(forPID: pid) where w.title == title { return w.frame.width }
        }
        return nil
    }
}

// MARK: - Entry point

/// Run `body` with the process's stdout (fd 1) redirected to /dev/null, then
/// restored. The fuzzed production paths (`parse`, `arrange`, `release`) print
/// diagnostics that would bury the fuzz summary at high iteration counts; the
/// signal we care about (a trap, or a returned failure string) is unaffected.
/// stderr is left alone. No-op-safe: restores fd 1 even if redirection fails.
private func withSuppressedStdout<T>(_ body: () -> T) -> T {
    fflush(stdout)
    let saved = dup(1)
    let devnull = open("/dev/null", O_WRONLY)
    if devnull >= 0 { dup2(devnull, 1); close(devnull) }
    defer {
        fflush(stdout)
        if saved >= 0 { dup2(saved, 1); close(saved) }
    }
    return body()
}


/// `WindowLab fuzzctrl [seed] [--iters N] [--runs K] [--ops M]
///                     [--config-only] [--primitive-only] [--controller-only]
///                     [--replay SEED]`
///
/// Default: parse + primitive property fuzz at `iters` iterations, plus K
/// stateful controller sessions of M ops each, all derived from the base seed.
/// Deterministic: a CI failure replays exactly. `--replay SEED` re-runs one
/// controller session verbosely and prints the full op log.
func runFuzzController(args: [String]) -> Never {
    func intArg(_ flag: String, _ def: Int) -> Int {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return def }
        return Int(args[i + 1]) ?? def
    }
    func u64Arg(_ flag: String) -> UInt64? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return UInt64(args[i + 1])
    }

    func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { max(lo, min(hi, v)) }

    let baseSeed = args.dropFirst().first.flatMap { UInt64($0) }
        ?? UInt64(Date().timeIntervalSince1970)
    let iters = intArg("--iters", 2000)
    let runs = intArg("--runs", clamp(iters / 600, 3, 24))
    let ops = intArg("--ops", clamp(iters / 10, 80, 800))
    let configOnly = args.contains("--config-only")
    let primitiveOnly = args.contains("--primitive-only")
    let controllerOnly = args.contains("--controller-only")

    // --replay: one controller session, verbose, prints the op log regardless.
    if let replay = u64Arg("--replay") {
        print("== fuzzctrl replay: controller session seed \(replay), \(ops) ops ==")
        let session = ControllerSession(seed: replay)
        session.verbose = true
        print("ops (live; the LAST line printed is the culprit if it hard-crashes):")
        let result = session.run(ops: ops)
        session.teardown()
        if let v = result { print("\n\(v)"); exit(1) }
        print("\nno violation for seed \(replay) (\(session.log.count) ops)")
        exit(0)
    }

    print("== ScrollWM fuzzctrl ==  base seed \(baseSeed)")
    var totalFail = 0

    if !primitiveOnly && !controllerOnly {
        print("\n-- config JSONC parse fuzz: \(iters) iters --")
        let seed = baseSeed &+ 0xC0FFEE
        let fs = withSuppressedStdout { ConfigFuzz.run(seed: seed, iters: iters) }
        if fs.isEmpty { print("  \u{2713} config parse: \(iters) inputs, never trapped, all clamps held") }
        else { totalFail += fs.count; for f in fs { print("  \u{2717} \(f)") } }
    }

    if !configOnly && !controllerOnly {
        print("\n-- primitive parse fuzz (Chord + width): \(iters) iters --")
        let seed = baseSeed &+ 0xBADC0DE
        let fs = PrimitiveFuzz.run(seed: seed, iters: iters)
        if fs.isEmpty { print("  \u{2713} Chord(string:) + parseWidthFraction: \(iters * 2) inputs, never trapped") }
        else { totalFail += fs.count; for f in fs { print("  \u{2717} \(f)") } }
    }

    if !configOnly && !primitiveOnly {
        print("\n-- controller chord/command sessions: \(runs) runs x \(ops) ops --")
        var firstFail: String?
        for k in 0..<runs {
            let seed = baseSeed &+ UInt64(k) &* 0x100000001B3
            let session = ControllerSession(seed: seed)
            let v = withSuppressedStdout { () -> String? in
                let r = session.run(ops: ops)
                session.teardown()
                return r
            }
            if let v {
                totalFail += 1
                if firstFail == nil { firstFail = v }
                print("  \u{2717} session seed \(seed) FAILED")
            }
            print("JCODE_PROGRESS {\"current\":\(k + 1),\"total\":\(runs),\"unit\":\"sessions\",\"message\":\"controller fuzz\"}")
        }
        if let f = firstFail {
            print("\n\(f)")
        } else {
            print("  \u{2713} controller fuzz: all \(runs) sessions passed (\(runs * ops) ops, state stayed coherent, release cleaned up)")
        }
    }

    print("\n========================================")
    if totalFail == 0 {
        print("FUZZCTRL PASSED (no violations)")
        exit(0)
    } else {
        print("FUZZCTRL FAILED: \(totalFail) violation(s)")
        exit(1)
    }
}
