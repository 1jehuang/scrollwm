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
        /// Width a newly opened window is snapped to, as a fraction of the usable
        /// strip width. Many native apps open at an oversized frame that ignores
        /// the column layout; resizing on adoption makes them land at a tidy
        /// column. `nil` preserves each window's native size. Apps that enforce a
        /// larger minimum keep their size (we read back the real frame), so this
        /// is best-effort and never corrupts the layout. Defaults to 0.5.
        var spawnWidth: CGFloat? = 0.5
        /// Which displays' windows the strip adopts. `stripDisplay` (default)
        /// manages ONLY the strip's own monitor and leaves the others alone;
        /// `allDisplays` is the legacy "one strip swallows every monitor"
        /// behavior. See `AdoptionScope`.
        var adoptScope: AdoptionScope.Scope = .stripDisplay
        // [md-select] Which monitor the strip binds to at launch. One of
        // "main" (default; the active display), "primary" (laptop panel),
        // "largest" (the external on a laptop+monitor setup), or a 1-based
        // display index ("1", "2", …). Resolved by DisplaySelector.pick.
        var stripDisplay: String = "main"
    }

    /// Menu-bar mini-map sizing. The icon grows with the strip instead of being
    /// a fixed width: one full screen of strip maps to `pointsPerScreen` icon
    /// points, so a 25%/50%/etc. column is always the same size regardless of
    /// how many windows exist. The icon grows as windows are added until it hits
    /// `maxWidth`, after which the whole strip is compressed to fit so it never
    /// overruns the menu bar.
    struct MenuBar: Equatable {
        var pointsPerScreen: CGFloat = 30
        var minWidth: CGFloat = 30
        var maxWidth: CGFloat = 220
        /// Briefly flash the chord + action name in the menu-bar icon whenever a
        /// ScrollWM keybinding fires (e.g. "⌘L  Focus →"). A live cheat sheet so
        /// you learn the bindings as you use them. On by default; set false to
        /// keep the icon as a pure mini-map.
        var showKeyHints: Bool = true
    }

    /// In-app updater behavior. ScrollWM checks GitHub Releases for a newer
    /// build so users actually receive what you cut, instead of being frozen on
    /// whatever they first installed. Nothing is downloaded or replaced without
    /// either an explicit click (`automatic: false`, the default) or an opt-in
    /// to silent install (`automatic: true`).
    struct Update: Equatable {
        /// Master switch for the background check. When false, ScrollWM never
        /// contacts GitHub on its own (the menu's "Check for Updates…" and the
        /// `scrollwm update` CLI still work on demand).
        var enabled: Bool = true
        /// When true, a found update is downloaded, verified, and installed
        /// automatically (the app relaunches into it). When false (default),
        /// the user is told and chooses; we never swap the app behind their back.
        var automatic: Bool = false
        /// Hours between background checks. Clamped to a sane floor so a typo
        /// can't hammer the API. Also checked ~shortly after launch.
        var checkIntervalHours: Double = 24
        /// Offer pre-release (`-dev`/`-rc`) tags too. Off by default so stable
        /// users only ever see stable releases.
        var allowPrerelease: Bool = false
    }

    var layout = Layout()
    var menuBar = MenuBar()
    var update = Update()
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
                // A configured fraction, or JSON null to preserve native size.
                "spawnWidth": layout.spawnWidth.map { Double($0) } ?? NSNull(),
                "adoptScope": layout.adoptScope.rawValue,
                "stripDisplay": layout.stripDisplay,  // [md-select]
            ],
            "menuBar": [
                "pointsPerScreen": Double(menuBar.pointsPerScreen),
                "minWidth": Double(menuBar.minWidth),
                "maxWidth": Double(menuBar.maxWidth),
                "showKeyHints": menuBar.showKeyHints,
            ],
            "update": [
                "enabled": update.enabled,
                "automatic": update.automatic,
                "checkIntervalHours": update.checkIntervalHours,
                "allowPrerelease": update.allowPrerelease,
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
            // spawnWidth: a number snaps new windows to that fraction; an
            // explicit null (or any non-number) preserves native size. Clamp to
            // a sane (0, 1] range so a typo can never request a degenerate width.
            if layout.keys.contains("spawnWidth") {
                if let sw = layout["spawnWidth"] as? NSNumber {
                    config.layout.spawnWidth = min(1.0, max(0.05, CGFloat(sw.doubleValue)))
                } else {
                    config.layout.spawnWidth = nil
                }
            }
            if let s = layout["adoptScope"] as? String {
                if let scope = AdoptionScope.Scope(configValue: s) {
                    config.layout.adoptScope = scope
                } else {
                    print("config: unknown layout.adoptScope '\(s)' (expected 'stripDisplay' or 'allDisplays'); using default")
                }
            }
            // [md-select] Initial strip display: "main"/"primary"/"largest"/index.
            if let sd = layout["stripDisplay"] as? String { config.layout.stripDisplay = sd }
            else if let sd = layout["stripDisplay"] as? NSNumber { config.layout.stripDisplay = "\(sd.intValue)" }
        }
        if let mb = obj["menuBar"] as? [String: Any] {
            if let p = mb["pointsPerScreen"] as? NSNumber { config.menuBar.pointsPerScreen = CGFloat(p.doubleValue) }
            if let n = mb["minWidth"] as? NSNumber { config.menuBar.minWidth = CGFloat(n.doubleValue) }
            if let x = mb["maxWidth"] as? NSNumber { config.menuBar.maxWidth = CGFloat(x.doubleValue) }
            if let h = mb["showKeyHints"] as? Bool { config.menuBar.showKeyHints = h }
            // Keep the clamps sane regardless of what's in the file.
            config.menuBar.pointsPerScreen = max(8, config.menuBar.pointsPerScreen)
            config.menuBar.minWidth = max(12, config.menuBar.minWidth)
            config.menuBar.maxWidth = max(config.menuBar.minWidth, config.menuBar.maxWidth)
        }
        if let up = obj["update"] as? [String: Any] {
            if let e = up["enabled"] as? Bool { config.update.enabled = e }
            if let a = up["automatic"] as? Bool { config.update.automatic = a }
            if let h = up["checkIntervalHours"] as? NSNumber {
                // Floor at 1h so a typo can't hammer the GitHub API.
                config.update.checkIntervalHours = max(1.0, h.doubleValue)
            }
            if let p = up["allowPrerelease"] as? Bool { config.update.allowPrerelease = p }
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
        "widthPresets": [0.25, 0.50, 0.75, 1.0],  // fractions for the width keys

        // Width a NEWLY opened window snaps to, as a fraction of the usable
        // strip width. Many native apps (Messages, Discord, Calendar, ...) open
        // at an oversized frame that ignores the column layout; this resizes
        // them on adoption so they land at a tidy column. Set to null to keep
        // each window's own native size instead. Apps that enforce a larger
        // minimum keep their size (we never shrink below what the app allows).
        "spawnWidth": 0.5,

        // Which displays' windows the strip manages:
        //   "stripDisplay" = ONLY the monitor the strip lives on; windows on
        //                    other monitors are left exactly where they are
        //                    (PaperWM/niri-style; the default).
        //   "allDisplays"  = legacy: one strip swallows every current-Space
        //                    window across ALL monitors.
        "adoptScope": "stripDisplay",

        // Which monitor the scrolling strip binds to at launch:
        //   "main"    = the active display (default)
        //   "primary" = the macOS primary display (usually the laptop panel)
        //   "largest" = the biggest display (the external on a laptop+monitor)
        //   "1"/"2"/… = a 1-based display index
        // Move it at runtime too: `scrollwm display <next|main|primary|largest|N>`.
        "stripDisplay": "main"
      },

      // Menu-bar mini-map sizing. The icon GROWS with the strip instead of
      // being a fixed width, so a 25%/50%/75%/100% column is always the same
      // size on the map no matter how many windows you have. As you open more
      // windows the icon widens, until it reaches maxWidth — then the whole
      // strip compresses to fit so it never takes over the menu bar.
      "menuBar": {
        "pointsPerScreen": 30,    // icon px that ONE full screen of strip maps to
        "minWidth": 30,           // px the icon never shrinks below (empty strip)
        "maxWidth": 220,          // px cap; past this the map compresses to fit
        "showKeyHints": true      // flash the chord + action (e.g. "⌘L Focus →") on each keypress
      },

      // In-app updates. ScrollWM checks GitHub Releases so you actually receive
      // new versions instead of being stuck on whatever you first installed.
      // Check manually anytime from the menu ("Check for Updates…") or the CLI
      // (`scrollwm update` / `scrollwm update --install`).
      "update": {
        "enabled": true,          // check GitHub for newer releases in the background
        "automatic": false,       // false: notify + let you click; true: download+install silently
        "checkIntervalHours": 24, // hours between background checks (min 1)
        "allowPrerelease": false  // also offer -dev / -rc tags
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

        // Vertical workspaces (niri-style): the strip you see is one workspace;
        // stack more above/below. Switching parks the other workspace's windows
        // off-screen. Going "down" past the last workspace makes a new empty one.
        "workspaceDown":       "cmd+j",         // (tap) switch to workspace below
        "workspaceUp":         "cmd+k",         // (tap) switch to workspace above
        "moveToWorkspaceDown": "cmd+shift+j",   // (tap) send focused window down + follow
        "moveToWorkspaceUp":   "cmd+shift+k",   // (tap) send focused window up + follow

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
      //   // Use Ghostty's --command= (NOT -e): the -e flag triggers Ghostty's
      //   // unskippable "Allow Ghostty to execute ..." security prompt every time.
      //   "ctrl+opt+j": "open -na Ghostty --args --working-directory=$HOME/scrollwm --command=$HOME/.local/bin/jcode",
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
    case workspaceDown
    case workspaceUp
    case moveToWorkspaceDown
    case moveToWorkspaceUp
    case width25
    case width50
    case width75
    case width100
    case closeWindow

    /// Short, human label for the menu-bar key-hint flash (e.g. "Focus →").
    /// Distinct from the longer tutorial descriptions; kept terse so it fits
    /// the menu-bar HUD. Directional arrows make left/right pairs scannable.
    var displayName: String {
        switch self {
        case .toggleArrange:      return "Arrange / Release"
        case .focusPrevious:      return "Focus prev"
        case .focusNext:          return "Focus next"
        case .jumpModifier:       return "Jump to column"
        case .focusLeft:          return "Focus ←"
        case .focusRight:         return "Focus →"
        case .moveColumnLeft:     return "Move ←"
        case .moveColumnRight:    return "Move →"
        case .workspaceDown:      return "Workspace ↓"
        case .workspaceUp:        return "Workspace ↑"
        case .moveToWorkspaceDown: return "Send ↓"
        case .moveToWorkspaceUp:   return "Send ↑"
        case .width25:            return "Width 25%"
        case .width50:            return "Width 50%"
        case .width75:            return "Width 75%"
        case .width100:           return "Width 100%"
        case .closeWindow:        return "Close window"
        }
    }

    static let defaultChords: [KeyAction: [String]] = [
        .toggleArrange:   ["ctrl+opt+escape"],
        .focusPrevious:   ["ctrl+opt+left"],
        .focusNext:       ["ctrl+opt+right"],
        .jumpModifier:    ["ctrl+opt"],
        .focusLeft:       ["cmd+h"],
        .focusRight:      ["cmd+l"],
        .moveColumnLeft:  ["cmd+shift+h"],
        .moveColumnRight: ["cmd+shift+l"],
        .workspaceDown:       ["cmd+j"],
        .workspaceUp:         ["cmd+k"],
        .moveToWorkspaceDown: ["cmd+shift+j"],
        .moveToWorkspaceUp:   ["cmd+shift+k"],
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
        // Punctuation. Both the literal glyph and a spoken name are accepted so
        // chords like "cmd+\\" or "cmd+backslash" both parse. (The tokenizer
        // splits on "+", "-", and space, so those three keys can only be named,
        // not given as a glyph.)
        "\\": 42, "backslash": 42,
        "/": 44, "slash": 44,
        ";": 41, "semicolon": 41,
        "'": 39, "quote": 39, "apostrophe": 39,
        ",": 43, "comma": 43,
        ".": 47, "period": 47, "dot": 47,
        "=": 24, "equal": 24, "equals": 24,
        "`": 50, "grave": 50, "backtick": 50,
        "[": 33, "leftbracket": 33,
        "]": 30, "rightbracket": 30,
        "minus": 27, "hyphen": 27,
    ]
}
