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

        case "version", "hello":
            // Capability handshake for integrators (e.g. jcode). Reports the
            // marketing version, a monotonic control-protocol revision, and the
            // live verb list so clients can feature-detect without sniffing the
            // app bundle. See docs/INTEGRATION.md.
            return controlVersionJSON()

        case "status":
            return controlStatusJSON()

        case "arrange":
            // Idempotent: while managing, this reconciles the current Space's
            // windows into the strip (same path as the menu-bar "Arrange
            // Windows into Strip" item), so the command and the menu match.
            //
            // Optional trailing width arg: `arrange 50` (or any 25/50/75/100 or
            // 0.0-1.0 fraction) arranges THEN sizes every column to that width,
            // so "tidy everything to half-width" is one command.
            var widthArg: CGFloat? = nil
            if let arg = args.first {
                guard let f = Self.parseWidthFraction(arg) else {
                    return "error: arrange width must be 25/50/75/100 or a fraction 0.0-1.0"
                }
                widthArg = f
            }
            let wasManaging = isManaging
            arrange()
            guard isManaging else {
                return "error: nothing to arrange (no manageable windows on this Space)"
            }
            if let widthArg {
                let n = setAllWidthsFraction(widthArg)
                let pct = Int((widthArg * 100).rounded())
                let verb = wasManaging ? "re-arranged" : "arranged"
                return "ok: \(verb) \(debugSlotCount) windows, set \(n) to \(pct)% width"
            }
            if wasManaging { return "ok: re-arranged \(debugSlotCount) windows" }
            return "ok: arranged \(debugSlotCount) windows"

        case "release":
            if !isManaging { return "ok: already released (dormant)" }
            release()
            return "ok: released, all windows placed"

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
            guard let arg = args.first else { return "error: usage: width [all] <25|50|75|100|0.0-1.0>" }
            // `width all <N>` resizes EVERY column; `width <N>` only the focused
            // one (back-compat).
            if arg.lowercased() == "all" {
                guard let widthArg = args.dropFirst().first else {
                    return "error: usage: width all <25|50|75|100|0.0-1.0>"
                }
                guard let fraction = Self.parseWidthFraction(widthArg) else {
                    return "error: width must be 25/50/75/100 or a fraction 0.0-1.0"
                }
                let n = setAllWidthsFraction(fraction)
                return "ok: set \(n) columns to \(Int((fraction * 100).rounded()))% width"
            }
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
            return "error: unknown command '\(verb)'. Try: version status arrange release toggle focus move workspace width close display focus-mode reload skills login update quit"
        }
    }

    /// Monotonic control-protocol revision. Bump ONLY on a breaking change to an
    /// existing verb's arguments or the status/version JSON shape. Adding a new
    /// verb or a new capability flag is non-breaking and must NOT bump this.
    /// Integrators gate features on this integer (coarse) plus `capabilities`
    /// (fine-grained). See docs/INTEGRATION.md.
    static let controlProtocolRevision = 1

    /// The capability flags advertised to integrators. Derived from the actual
    /// verb set so the handshake never drifts from what the app really supports.
    static var controlCapabilities: [String] {
        [
            "ping", "status", "version",
            "arrange", "release", "toggle",
            "focus", "move", "workspace", "width", "close",
            "display", "focus-mode", "reload",
        ]
    }

    /// Machine-readable capability handshake (the `version` verb).
    func controlVersionJSON() -> String {
        let obj: [String: Any] = [
            "name": "ScrollWM",
            "version": AppVersion.currentString,
            "protocol": ScrollWMController.controlProtocolRevision,
            "capabilities": ScrollWMController.controlCapabilities,
            // Back-compat alias some clients read instead of `capabilities`.
            "verbs": ScrollWMController.controlCapabilities,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"could not serialize version\"}"
        }
        return json
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
            // Handshake fields mirrored from `version` so a single `status`
            // call gives integrators version + protocol without a second round
            // trip. See docs/INTEGRATION.md.
            "version": AppVersion.currentString,
            "protocol": ScrollWMController.controlProtocolRevision,
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
