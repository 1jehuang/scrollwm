import Foundation
import Carbon
import CoreGraphics

/// ScrollWM settings live in ONE place: a human-editable config file at
/// `~/Library/Application Support/ScrollWM/config.json`.
///
/// Design notes
/// ------------
///   - The file is the single source of truth. There is no hidden state in
///     `UserDefaults`; what you see in the file is what the app uses.
///   - It is JSON with `//` line comments allowed (stripped before parsing),
///     so the default file we write can document every option inline.
///   - On first run (or if the file is missing) we write a fully-commented
///     default file, so the user always has a working, self-documenting
///     starting point.
///   - A malformed file never bricks the app: we log a clear error and fall
///     back to defaults.
///
/// Keybinding channels (why some keys can't be freely rebound)
/// ----------------------------------------------------------
/// macOS constrains how global shortcuts can be captured, and ScrollWM stays
/// permission-light by using two mechanisms, each with limits:
///   - **Carbon global hotkeys** (no extra permission): used for navigation,
///     jump, width, close, and the arrange/release toggle. Carbon CANNOT
///     capture `Cmd+H`/`Cmd+M` (macOS reserves them), so don't bind those
///     here.
///   - **Keyboard event tap** (works with the Accessibility permission we
///     already hold; active only while managing): used for focus-left/right
///     and move-left/right, which default to `Cmd+H`/`Cmd+L`.
/// Each action keeps its channel; you may change the *chord*, but pick chords
/// the channel can deliver. The tutorial window explains this too.
struct ScrollWMConfig: Equatable {
    struct Layout: Equatable {
        var columnGap: CGFloat = 12
        var minColumnWidth: CGFloat = 200
        var widthPresets: [CGFloat] = [0.25, 0.50, 0.75, 1.0]
    }

    var layout = Layout()
    var focusMode: TeleportEngine.FocusMode = .fit

    /// Action -> one or more chords. Multiple chords let an action have
    /// several triggers (e.g. width via both Opt+1 and Cmd+1).
    var keybindings: [KeyAction: [String]] = KeyAction.defaultChords

    /// niri-style "spawn" bindings: a chord -> an arbitrary shell command run
    /// (via `/bin/sh -c`) when the chord fires. These are always-on global
    /// Carbon hotkeys (active even when not managing), so they CANNOT use
    /// macOS-reserved chords like Cmd+H/Cmd+M. Empty by default; users opt in.
    var spawn: [String: String] = [:]

    // MARK: - Defaults

    static let `default` = ScrollWMConfig()

    // MARK: - File location

    static var dirURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScrollWM", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var fileURL: URL { dirURL.appendingPathComponent("config.json") }

    // MARK: - Load / save

    /// Load the config from disk, writing a documented default file first if
    /// none exists. Never throws: malformed input falls back to defaults.
    static func load() -> ScrollWMConfig {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            writeDefaultFile()
            return .default
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            print("config: could not read \(url.path); using defaults")
            return .default
        }
        do {
            return try parse(jsonc: raw)
        } catch {
            print("config: \(error.localizedDescription) — using defaults. Fix \(url.path) and relaunch.")
            return .default
        }
    }

    /// Persist the given config (compact, machine-written form). Used when the
    /// user changes a setting from the menu so the file stays authoritative.
    func save() {
        let dict: [String: Any] = [
            "layout": [
                "columnGap": Double(layout.columnGap),
                "minColumnWidth": Double(layout.minColumnWidth),
                "widthPresets": layout.widthPresets.map { Double($0) },
            ],
            "focusMode": focusMode.rawValue,
            "keybindings": Dictionary(uniqueKeysWithValues: keybindings.map { ($0.key.rawValue, $0.value) }),
            "spawn": spawn,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - Parsing

    enum ConfigError: LocalizedError {
        case malformedJSON(String)
        var errorDescription: String? {
            switch self {
            case .malformedJSON(let why): return "malformed config (\(why))"
            }
        }
    }

    static func parse(jsonc: String) throws -> ScrollWMConfig {
        let cleaned = stripLineComments(jsonc)
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.malformedJSON("not valid JSON")
        }
        var config = ScrollWMConfig.default

        if let layout = obj["layout"] as? [String: Any] {
            if let g = layout["columnGap"] as? NSNumber { config.layout.columnGap = CGFloat(g.doubleValue) }
            if let m = layout["minColumnWidth"] as? NSNumber { config.layout.minColumnWidth = CGFloat(m.doubleValue) }
            if let presets = layout["widthPresets"] as? [NSNumber], !presets.isEmpty {
                config.layout.widthPresets = presets.map { CGFloat($0.doubleValue) }
            }
        }
        if let fm = obj["focusMode"] as? String, let mode = TeleportEngine.FocusMode(rawValue: fm) {
            config.focusMode = mode
        }
        if let kb = obj["keybindings"] as? [String: Any] {
            for (key, value) in kb {
                guard let action = KeyAction(rawValue: key) else {
                    print("config: unknown keybinding action '\(key)' (ignored)")
                    continue
                }
                let chords: [String]
                if let s = value as? String { chords = [s] }
                else if let arr = value as? [String] { chords = arr }
                else { print("config: keybinding '\(key)' must be a string or array of strings"); continue }
                config.keybindings[action] = chords
            }
        }
        if let sp = obj["spawn"] as? [String: Any] {
            for (chord, value) in sp {
                guard let command = value as? String else {
                    print("config: spawn binding '\(chord)' must map to a command string (ignored)")
                    continue
                }
                config.spawn[chord] = command
            }
        }
        return config
    }

    /// Strip `//` line comments that are not inside a JSON string literal.
    private static func stripLineComments(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var inString = false
            var escaped = false
            var cut = line.endIndex
            var i = line.startIndex
            while i < line.endIndex {
                let c = line[i]
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString.toggle() }
                else if c == "/", !inString {
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "/" { cut = i; break }
                }
                i = line.index(after: i)
            }
            out += line[line.startIndex..<cut]
            out += "\n"
        }
        return out
    }

    // MARK: - Resolved chords

    /// Parse all configured chords for an action into usable Chord values,
    /// skipping (with a warning) any that fail to parse.
    func chords(for action: KeyAction) -> [Chord] {
        (keybindings[action] ?? KeyAction.defaultChords[action] ?? []).compactMap { str in
            if let chord = Chord(string: str) { return chord }
            print("config: could not parse chord '\(str)' for \(action.rawValue) (ignored)")
            return nil
        }
    }

    /// Parse all configured `spawn` bindings into (chord, command) pairs,
    /// skipping (with a warning) any chord that fails to parse or is
    /// modifier-only (a spawn binding needs a real key to fire).
    func spawnBindings() -> [(chord: Chord, command: String)] {
        spawn.compactMap { (chordStr, command) in
            guard let chord = Chord(string: chordStr) else {
                print("config: could not parse spawn chord '\(chordStr)' (ignored)")
                return nil
            }
            guard chord.hasKey else {
                print("config: spawn chord '\(chordStr)' has no key; needs a real key (ignored)")
                return nil
            }
            return (chord, command)
        }
    }

    // MARK: - Default file

    static func writeDefaultFile() {
        try? defaultFileContents.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    /// A fully-commented JSONC template documenting every option.
    static let defaultFileContents = """
    // ScrollWM configuration. This file is the single source of truth for all
    // settings. Edit it, then choose "Reload Config" from the menu bar icon
    // (or relaunch). Comments starting with // are allowed.
    {
      "layout": {
        "columnGap": 12,          // px between columns and screen edges
        "minColumnWidth": 200,    // px floor; a column never shrinks below this
        "widthPresets": [0.25, 0.50, 0.75, 1.0]  // fractions for the width keys
      },

      // How the viewport follows the focused column:
      //   "fit"      = scroll only when the focused column is off screen
      //   "centered" = always center the focused column
      "focusMode": "fit",

      // Keybindings. Modifiers: cmd, opt (alt), ctrl, shift. Keys: letters,
      // digits, "left"/"right"/"up"/"down", "escape", "space", "return", "tab".
      // A value may be a single chord or a list of chords.
      //
      // NOTE: navigation/jump/width/close/toggle use permission-free Carbon
      // hotkeys, which CANNOT capture Cmd+H or Cmd+M. focusLeft/focusRight and
      // moveColumnLeft/Right use a keyboard tap (active only while managing),
      // so they CAN use Cmd+H/Cmd+L.
      "keybindings": {
        "toggleArrange":   "ctrl+opt+escape",  // arrange <-> release (panic switch)
        "focusPrevious":   "ctrl+opt+left",
        "focusNext":       "ctrl+opt+right",
        "jumpModifier":    "ctrl+opt",          // + digit 1-9 jumps to that column

        "focusLeft":       "cmd+h",             // (tap) focus column to the left
        "focusRight":      "cmd+l",             // (tap) focus column to the right
        "moveColumnLeft":  "cmd+shift+h",       // (tap) move focused column left
        "moveColumnRight": "cmd+shift+l",       // (tap) move focused column right

        "width25":  ["opt+1", "cmd+1"],
        "width50":  ["opt+2", "cmd+2"],
        "width75":  ["opt+3", "cmd+3"],
        "width100": ["opt+4", "cmd+4"],

        "closeWindow": "cmd+q"                  // close focused window (while managing)
      }
      // Optionally, niri-style "spawn" bindings: a chord -> a shell command run
      // (via /bin/sh -c) when you press it. These are always-on global hotkeys,
      // so they CANNOT use macOS-reserved chords (Cmd+H/Cmd+M). Each chord must
      // include a real key (a modifier-only chord won't fire). Example:
      //
      // ,
      // "spawn": {
      //   "ctrl+opt+j": "open -na Ghostty --args --working-directory=$HOME/scrollwm -e $HOME/.local/bin/jcode",
      //   "ctrl+opt+return": "open -na Ghostty"
      // }
    }

    """
}

/// Every rebindable action. Each carries its default chord(s).
enum KeyAction: String, CaseIterable {
    case toggleArrange
    case focusPrevious
    case focusNext
    case jumpModifier        // modifier-only; combined with digits 1-9
    case focusLeft
    case focusRight
    case moveColumnLeft
    case moveColumnRight
    case width25
    case width50
    case width75
    case width100
    case closeWindow

    static let defaultChords: [KeyAction: [String]] = [
        .toggleArrange:   ["ctrl+opt+escape"],
        .focusPrevious:   ["ctrl+opt+left"],
        .focusNext:       ["ctrl+opt+right"],
        .jumpModifier:    ["ctrl+opt"],
        .focusLeft:       ["cmd+h"],
        .focusRight:      ["cmd+l"],
        .moveColumnLeft:  ["cmd+shift+h"],
        .moveColumnRight: ["cmd+shift+l"],
        .width25:         ["opt+1", "cmd+1"],
        .width50:         ["opt+2", "cmd+2"],
        .width75:         ["opt+3", "cmd+3"],
        .width100:        ["opt+4", "cmd+4"],
        .closeWindow:     ["cmd+q"],
    ]
}

/// A parsed key chord: a virtual keycode plus modifier masks for both the
/// Carbon and CGEvent APIs (so the same chord can drive either channel).
struct Chord: Equatable {
    let keyCode: UInt32          // virtual keycode; UInt32.max means "none" (modifier-only)
    let carbonModifiers: UInt32
    let cgFlags: CGEventFlags

    var hasKey: Bool { keyCode != UInt32.max }

    /// Parse "cmd+shift+h", "ctrl+opt+left", "opt+1", or modifier-only "ctrl+opt".
    init?(string: String) {
        var carbon: UInt32 = 0
        var flags: CGEventFlags = []
        var key: UInt32? = nil

        // Insert separators around glued modifier symbols (e.g. "⌘⇧L") so they
        // tokenize like "cmd+shift+l". pretty() emits this glued form, so a
        // user pasting it back must still parse.
        var normalized = string.lowercased()
        for sym in ["⌘", "⌥", "⌃", "⇧"] { normalized = normalized.replacingOccurrences(of: sym, with: "+\(sym)+") }

        let tokens = normalized
            .split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        for token in tokens {
            switch token {
            case "cmd", "command", "⌘":
                carbon |= UInt32(cmdKey); flags.insert(.maskCommand)
            case "opt", "option", "alt", "⌥":
                carbon |= UInt32(optionKey); flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃":
                carbon |= UInt32(controlKey); flags.insert(.maskControl)
            case "shift", "⇧":
                carbon |= UInt32(shiftKey); flags.insert(.maskShift)
            default:
                guard let code = Chord.keyCodes[token] else { return nil }
                if key != nil { return nil } // more than one non-modifier key
                key = code
            }
        }
        self.keyCode = key ?? UInt32.max
        self.carbonModifiers = carbon
        self.cgFlags = flags
    }

    /// ANSI virtual keycodes for the names we accept in config.
    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
        "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
        "7": 26, "8": 28, "9": 25, "0": 29,
        "return": 36, "enter": 36, "tab": 48, "space": 49,
        "delete": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}
