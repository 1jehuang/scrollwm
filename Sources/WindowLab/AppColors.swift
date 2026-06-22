import AppKit

/// App-aware colors for the strip mini-map, mirroring the niri-workspaces-rs
/// scheme: terminals are colored by the agent/program running inside (detected
/// from the window title), GUI apps by their name.
enum AppColors {

    /// Color for a window given its app name (AX localized name) and title.
    static func color(appName: String, title: String) -> NSColor {
        let app = appName.lowercased()
        let t = title.lowercased()

        // Terminals: color by what's running inside (title-based, like niri).
        if isTerminal(app) {
            if t.contains("jcode") { return hex(0x999999) }
            if t.contains("claude") || title.contains("✳") { return hex(0xF5A623) }
            if t.contains("codex") { return hex(0x56B6C2) }
            if t.contains("nvim") || t.contains("vim") { return hex(0x98C379) }
            if t.contains("aider") { return hex(0xCBA6F7) }
            return hex(0x8A8A8A)
        }

        // Editors / IDEs.
        if app.contains("cursor") { return hex(0x4F9CF6) }
        if app.contains("code") { return hex(0x2F9BF4) }          // VS Code
        if app.contains("neovim") || app.contains("nvim") { return hex(0x98C379) }
        if app.contains("xcode") { return hex(0x1C8FFF) }
        if app.contains("zed") { return hex(0x6F8FF5) }

        // Browsers.
        if app.contains("chrome") || app.contains("chromium") { return hex(0xEA4335) }
        if app.contains("brave") { return hex(0xFB542B) }
        if app.contains("firefox") { return hex(0xFF7139) }
        if app.contains("safari") { return hex(0x1AA3FF) }
        if app.contains("arc") { return hex(0xFB6D8C) }
        if app.contains("edge") { return hex(0x35B4D6) }

        // Comms / media / misc.
        if app.contains("discord") || app.contains("vesktop") { return hex(0xC678DD) }
        if app.contains("slack") { return hex(0x36C5F0) }
        if app.contains("spotify") { return hex(0x1DB954) }
        if app.contains("music") { return hex(0xFA2D48) }
        if app.contains("messages") { return hex(0x34DA50) }
        if app.contains("telegram") { return hex(0x2AABEE) }
        if app.contains("mail") { return hex(0xE5C07B) }
        if app.contains("notes") { return hex(0xFFD60A) }
        if app.contains("finder") { return hex(0x49B2FF) }
        if app.contains("todoist") { return hex(0xE06C75) }
        if app.contains("preview") { return hex(0x7AA2F7) }

        return hex(0x9AA0A6) // neutral fallback
    }

    static func isTerminal(_ app: String) -> Bool {
        let terms = ["terminal", "iterm", "kitty", "alacritty", "ghostty",
                     "foot", "wezterm", "warp", "rio", "tabby", "hyper"]
        return terms.contains { app.contains($0) }
    }

    private static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: 1)
    }
}
