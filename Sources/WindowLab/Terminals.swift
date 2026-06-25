import Foundation

/// Ranked catalog of macOS terminal emulators + the PURE logic for "spawn the
/// best installed terminal" and "make its background pure black if the user is
/// still on the app's default".
///
/// Why this exists
/// ---------------
/// ScrollWM is a tiling WM; opening a fresh terminal into the strip is a core
/// move (niri/PaperWM users live in the terminal). `cmd+enter` should Just Work
/// without the user having to hand-write a `spawn` binding for whatever terminal
/// they happen to have. We pick the "best" terminal they actually have
/// installed, walking a quality-ordered list (Ghostty > kitty > WezTerm >
/// Alacritty > iTerm2 > Warp > Hyper > Terminal.app), and open a new window.
///
/// Everything here that decides *what* to do is a PURE function of its inputs
/// (the set of installed bundle IDs, the current config file text), so it is
/// unit-tested headlessly with no AppKit / NSWorkspace / filesystem (see
/// `TerminalsTests`). The only impure part is `TerminalLauncher`, which reads
/// `NSWorkspace`, touches the config file, and runs `/usr/bin/open`.
///
/// Black-background policy (the "if default, make it black" request)
/// -----------------------------------------------------------------
/// We only ever *append* a background directive, and ONLY when the user's
/// config has no background directive at all (i.e. they are still on the app's
/// shipped default). We never rewrite or remove anything the user wrote, and
/// the operation is idempotent (a second run is a no-op because the directive
/// now exists). We restrict this to terminals whose config is a simple
/// line-oriented `key value` format where appending a later line safely
/// overrides earlier ones (Ghostty, kitty). TOML/Lua configs (Alacritty,
/// WezTerm) and plist/binary settings (iTerm2, Terminal.app, Warp) are launched
/// but never edited, because a naive append could corrupt them.
struct TerminalApp: Equatable {

    /// How ScrollWM may (or may not) force a pure-black background.
    struct ThemeRule: Equatable {
        /// Candidate config files, RELATIVE to the user's home directory, in
        /// priority order. The first one that exists is edited; if none exist,
        /// the first is created (so the directive lands where the app expects).
        let configPaths: [String]
        /// The directive key that sets the background (e.g. "background"). We
        /// match it as a whole leading token so `background_opacity` /
        /// `background-image` never count as "the user set a background".
        let backgroundKey: String
        /// The exact line we append to force a pure-black background, in the
        /// app's own config syntax (e.g. "background = 000000" for Ghostty,
        /// "background #000000" for kitty).
        let blackLine: String

        /// True when `contents` already contains a (non-comment) line that sets
        /// the background. Comments (`#…`) never count.
        func hasBackgroundDirective(in contents: String) -> Bool {
            for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                // The key is the leading token, terminated by whitespace or '='.
                let key = line.prefix { $0 != "=" && !$0.isWhitespace }
                if key.lowercased() == backgroundKey.lowercased() { return true }
            }
            return false
        }

        /// Given the current config text (`nil` if the file does not exist yet),
        /// return the NEW text that forces a black background, or `nil` if no
        /// change is needed (the user already set a background, so we leave it
        /// alone). Idempotent.
        func applyingBlackBackground(to existing: String?) -> String? {
            let current = existing ?? ""
            if hasBackgroundDirective(in: current) { return nil }
            var out = current
            // Keep exactly one blank line between the user's content and ours,
            // and always end with a trailing newline.
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            if !out.isEmpty { out += "\n" }
            out += "# Added by ScrollWM: pure-black background (remove or edit to customize)\n"
            out += blackLine + "\n"
            return out
        }
    }

    /// Stable id (also used in logs).
    let id: String
    /// Human name, shown in the menu-bar key-hint flash.
    let displayName: String
    /// Bundle identifiers that count as "this terminal is installed". Listed so
    /// renamed/forked variants (e.g. old vs new Alacritty id) all match.
    let bundleIDs: [String]
    /// Quality rank; LOWER is better (0 = most preferred).
    let rank: Int
    /// How (or whether) to force a black background. `nil` = launch but never
    /// touch its config.
    let theme: ThemeRule?

    /// `/usr/bin/open` arguments to launch a NEW window/instance of this app at
    /// `bundlePath`. `-n` forces a fresh instance so every press yields a new
    /// window that the strip can adopt, uniform across every terminal. PURE.
    func openArguments(bundlePath: String) -> [String] {
        ["-n", bundlePath]
    }
}

/// The ranked terminal catalog. Order here is the canonical preference order;
/// `rank` mirrors the array index so the two never drift.
enum TerminalCatalog {

    /// All known terminals, best-first. Apple's Terminal.app is last: it is the
    /// universal fallback that is always present, so we only use it when nothing
    /// nicer is installed.
    static let all: [TerminalApp] = [
        TerminalApp(
            id: "ghostty", displayName: "Ghostty",
            bundleIDs: ["com.mitchellh.ghostty"], rank: 0,
            theme: .init(
                configPaths: [".config/ghostty/config",
                              "Library/Application Support/com.mitchellh.ghostty/config"],
                backgroundKey: "background",
                blackLine: "background = 000000")),
        TerminalApp(
            id: "kitty", displayName: "kitty",
            bundleIDs: ["net.kovidgoyal.kitty"], rank: 1,
            theme: .init(
                configPaths: [".config/kitty/kitty.conf"],
                backgroundKey: "background",
                blackLine: "background #000000")),
        TerminalApp(
            id: "wezterm", displayName: "WezTerm",
            bundleIDs: ["com.github.wez.wezterm"], rank: 2,
            theme: nil),   // Lua config: launch, never edit.
        TerminalApp(
            id: "alacritty", displayName: "Alacritty",
            bundleIDs: ["org.alacritty", "io.alacritty"], rank: 3,
            theme: nil),   // TOML config: launch, never edit.
        TerminalApp(
            id: "iterm2", displayName: "iTerm2",
            bundleIDs: ["com.googlecode.iterm2"], rank: 4,
            theme: nil),   // Binary plist profiles: launch, never edit.
        TerminalApp(
            id: "warp", displayName: "Warp",
            bundleIDs: ["dev.warp.Warp-Stable"], rank: 5,
            theme: nil),
        TerminalApp(
            id: "hyper", displayName: "Hyper",
            bundleIDs: ["co.zeit.hyper"], rank: 6,
            theme: nil),
        TerminalApp(
            id: "appleTerminal", displayName: "Terminal",
            bundleIDs: ["com.apple.Terminal"], rank: 7,
            theme: nil),   // Binary plist profiles: launch, never edit.
    ]

    /// The catalog sorted best-first (defensive: independent of array order).
    static func ranked() -> [TerminalApp] { all.sorted { $0.rank < $1.rank } }

    /// The best terminal whose bundle id is in `installed`, or `nil` if none of
    /// our known terminals are installed. PURE.
    static func best(installed: Set<String>) -> TerminalApp? {
        ranked().first { app in app.bundleIDs.contains { installed.contains($0) } }
    }
}

// MARK: - Launcher (impure: NSWorkspace + filesystem + /usr/bin/open)

#if canImport(AppKit)
import AppKit

/// Detects which catalog terminals are installed, applies the black-background
/// policy to the chosen one, and opens a new window. The pure decisions live in
/// `TerminalCatalog` / `TerminalApp.ThemeRule`; this is just the I/O shell.
enum TerminalLauncher {

    /// Resolve the on-disk bundle path for a bundle id, or `nil` if not
    /// installed. Uses the modern LaunchServices lookup.
    static func bundlePath(forBundleID id: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path
    }

    /// The set of catalog bundle ids that are currently installed.
    static func installedBundleIDs() -> Set<String> {
        var found: Set<String> = []
        for app in TerminalCatalog.all {
            for id in app.bundleIDs where bundlePath(forBundleID: id) != nil {
                found.insert(id)
            }
        }
        return found
    }

    /// The best installed terminal together with a concrete bundle path, or
    /// `nil` if none are installed.
    static func bestInstalled() -> (app: TerminalApp, bundlePath: String)? {
        guard let app = TerminalCatalog.best(installed: installedBundleIDs()) else { return nil }
        for id in app.bundleIDs {
            if let path = bundlePath(forBundleID: id) { return (app, path) }
        }
        return nil
    }

    /// Force a pure-black background for `app` IF it uses a line-based config
    /// and the user has not set any background yet. No-op otherwise. Returns the
    /// path written, or `nil` if nothing was changed.
    @discardableResult
    static func applyBlackBackgroundIfDefault(_ app: TerminalApp,
                                              homeDir: String = NSHomeDirectory()) -> String? {
        guard let rule = app.theme else { return nil }
        let fm = FileManager.default

        // Edit the first existing config; if none exist, create the first.
        let resolved = rule.configPaths.map { (homeDir as NSString).appendingPathComponent($0) }
        let target = resolved.first { fm.fileExists(atPath: $0) } ?? resolved[0]

        let existing = try? String(contentsOfFile: target, encoding: .utf8)
        guard let updated = rule.applyingBlackBackground(to: existing) else { return nil }

        do {
            try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try updated.write(toFile: target, atomically: true, encoding: .utf8)
            print("terminal: set pure-black background in \(target)")
            return target
        } catch {
            print("terminal: could not write \(target): \(error.localizedDescription)")
            return nil
        }
    }

    /// Open a new window of the best installed terminal, theming it black first
    /// if it is still on its default background. Returns `true` if a launch was
    /// initiated. Non-blocking.
    @discardableResult
    static func launchBest() -> Bool {
        guard let (app, bundlePath) = bestInstalled() else {
            print("terminal: no known terminal installed; nothing to spawn")
            return false
        }
        applyBlackBackgroundIfDefault(app)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = app.openArguments(bundlePath: bundlePath)
        do {
            try process.run()
            print("terminal: launched \(app.displayName) (\(bundlePath))")
            return true
        } catch {
            print("terminal: failed to launch \(app.displayName): \(error.localizedDescription)")
            return false
        }
    }
}
#endif
