import Foundation

// CLI command dispatch for the running ScrollWM app.
//
// The control socket (ControlServer) hands each request line here; we run on
// the main thread already (the server marshals us there). Every verb maps to a
// controller action and returns a one-line, human-readable reply. `status`
// returns JSON so scripts can parse it.
//
// Keep this list in sync with the `scrollwm` CLI help in main.swift.

extension ScrollWMController {

    /// Parse + execute one control command line, return the reply string.
    func handleControlCommand(_ line: String) -> String {
        let parts = line.split(separator: " ").map(String.init)
        guard let verb = parts.first?.lowercased() else { return "error: empty command" }
        let args = Array(parts.dropFirst())

        switch verb {
        case "ping":
            return "pong"

        case "status":
            return controlStatusJSON()

        case "arrange":
            // Idempotent: while managing, this reconciles the current Space's
            // windows into the strip (same path as the menu-bar "Arrange
            // Windows into Strip" item), so the command and the menu match.
            let wasManaging = isManaging
            arrange()
            if wasManaging { return "ok: re-arranged \(debugSlotCount) windows" }
            return isManaging
                ? "ok: arranged \(debugSlotCount) windows"
                : "error: nothing to arrange (no manageable windows on this Space)"

        case "release":
            if !isManaging { return "ok: already released (dormant)" }
            release()
            return "ok: released, all windows restored"

        case "toggle":
            toggle()
            return isManaging ? "ok: arranged \(debugSlotCount) windows" : "ok: released"

        case "focus":
            guard isManaging else { return "error: not managing; run `scrollwm arrange` first" }
            guard let arg = args.first else { return "error: usage: focus <next|prev|left|right|N>" }
            switch arg.lowercased() {
            case "next", "right": focusNext()
            case "prev", "previous", "left": focusPrevious()
            default:
                guard let n = Int(arg), n >= 1 else { return "error: column must be a positive number or next/prev" }
                focus(index: n - 1) // CLI is 1-based, engine is 0-based
            }
            return "ok: focused column \(debugFocusIndex + 1) (\(debugFocusedTitle))"

        case "move":
            guard isManaging else { return "error: not managing; run `scrollwm arrange` first" }
            guard let dir = args.first?.lowercased() else { return "error: usage: move <left|right>" }
            switch dir {
            case "left":  moveFocused(by: -1)
            case "right": moveFocused(by: 1)
            case "up":    moveFocusedToWorkspace(by: -1)
            case "down":  moveFocusedToWorkspace(by: 1)
            default: return "error: usage: move <left|right>"
            }
            return "ok: moved to column \(debugFocusIndex + 1)"

        case "workspace", "ws":
            guard isManaging else { return "error: not managing; run `scrollwm arrange` first" }
            guard let arg = args.first?.lowercased() else {
                return "ok: workspace \(debugActiveWorkspace + 1) of \(debugWorkspaceCount)"
            }
            switch arg {
            case "down", "next": switchWorkspace(by: 1)
            case "up", "prev", "previous": switchWorkspace(by: -1)
            default:
                guard let n = Int(arg), n >= 1 else {
                    return "error: usage: workspace <up|down|N>"
                }
                focusWorkspace(n)
            }
            return "ok: on workspace \(debugActiveWorkspace + 1) of \(debugWorkspaceCount)"

        case "width":
            guard isManaging else { return "error: not managing; run `scrollwm arrange` first" }
            guard let arg = args.first else { return "error: usage: width <25|50|75|100|0.0-1.0>" }
            guard let fraction = Self.parseWidthFraction(arg) else {
                return "error: width must be 25/50/75/100 or a fraction 0.0-1.0"
            }
            setWidthFraction(fraction)
            return "ok: set focused width to \(Int((fraction * 100).rounded()))%"

        case "close":
            guard isManaging else { return "error: not managing" }
            guard debugSlotCount > 0 else { return "error: no focused window" }
            let title = debugFocusedTitle
            closeFocused()
            return "ok: closed \(title)"

        // [md-select] Move the scrolling strip to another monitor at runtime.
        // Works whether or not we're managing (dormant just re-binds geometry
        // for the next arrange). The controller returns the one-line reply.
        case "display":
            guard let arg = args.first else {
                let list = displayChoices().map {
                    "\($0.index):\($0.name)\($0.isStrip ? "*" : "")"
                }.joined(separator: ", ")
                return "ok: displays: \(list) (usage: display <next|main|primary|largest|N>)"
            }
            return moveStripToDisplay(arg)

        case "focus-mode", "focusmode":
            guard let arg = args.first?.lowercased() else {
                return "ok: focus-mode is \(focusMode.rawValue)"
            }
            guard let mode = TeleportEngine.FocusMode(rawValue: arg) else {
                let opts = TeleportEngine.FocusMode.allCases.map { $0.rawValue }.joined(separator: "|")
                return "error: focus-mode must be one of: \(opts)"
            }
            setFocusMode(mode)
            return "ok: focus-mode set to \(mode.rawValue)"

        case "reload", "reload-config":
            reloadConfig()
            return "ok: config reloaded"

        case "tutorial":
            showTutorial()
            return "ok: opened tutorial"

        case "skills", "proficiency":
            // Report keybindings the user has mastered then drifted away from
            // (back to the menu). See `KeybindingProficiency`.
            return skillReport()

        case "login", "launch-at-login", "loginitem":
            // `scrollwm login` reports; `scrollwm login on|off` sets it.
            guard let arg = args.first?.lowercased() else { return launchAtLoginStatus() }
            switch arg {
            case "on", "enable", "true", "yes":   return setLaunchAtLogin(true)
            case "off", "disable", "false", "no": return setLaunchAtLogin(false)
            default: return "error: usage: login <on|off>"
            }

        case "update", "update-check":
            // `scrollwm update` checks; `scrollwm update --install` applies it.
            let install = args.contains("--install") || args.contains("install")
            return controlUpdateCheck(install: install)

        case "quit":
            // Reply BEFORE terminating so the CLI sees confirmation.
            DispatchQueue.main.async { [weak self] in self?.quit() }
            return "ok: quitting (windows restored)"

        default:
            return "error: unknown command '\(verb)'. Try: status arrange release toggle focus move workspace width close display focus-mode reload skills login update quit"
        }
    }

    /// Accept "25"/"50"/"75"/"100" (percent) or "0.0".."1.0" (fraction).
    static func parseWidthFraction(_ s: String) -> CGFloat? {
        guard let v = Double(s) else { return nil }
        let f = v > 1.0 ? v / 100.0 : v
        guard f > 0.0, f <= 1.0 else { return nil }
        return CGFloat(f)
    }

    /// Machine-readable snapshot of the live strip.
    func controlStatusJSON() -> String {
        var obj: [String: Any] = [
            "managing": isManaging,
            "focusMode": focusMode.rawValue,
            "windowCount": debugSlotCount,
        ]
        if isManaging {
            obj["focusedColumn"] = debugFocusIndex + 1
            obj["columns"] = controlColumns()
            obj["workspace"] = debugActiveWorkspace + 1
            obj["workspaceCount"] = debugWorkspaceCount
            let floating = floatingWindows
            obj["floatingCount"] = floating.count
            obj["floating"] = floating.map { w -> [String: Any] in
                ["app": w.appName, "title": w.title, "canTile": w.canTile]
            }
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"could not serialize status\"}"
        }
        return json
    }
}
