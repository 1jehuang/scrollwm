import Foundation

/// Conformance tests for the control-plane integration contract (the wire
/// surface documented in `docs/INTEGRATION.md` that jcode and other clients
/// depend on). Pure logic: no Accessibility, no windows. Invoked from
/// `StripOpsTests.run` so it runs under `WindowLab unittest`.
///
/// The point is to fail loudly if the advertised `version`/`capabilities`
/// handshake ever drifts from the actual control verb set, so the doc + the
/// integration never silently rot.
enum ControlContractTests {
    static func run(_ check: (String, Bool) -> Void) {
        // The capability list must be a subset of the verbs the CLI recognizes
        // (`controlVerbs` in main.swift): we never advertise a capability the
        // app can't actually service.
        let caps = Set(ScrollWMController.controlCapabilities)
        check(
            "contract: capabilities ⊆ controlVerbs",
            caps.isSubset(of: controlVerbs)
        )

        // Every alias the server's switch accepts MUST be routable by the CLI,
        // i.e. present in `controlVerbs` - otherwise `scrollwm <alias>` falls
        // through to the local help/error path and never reaches the app. This
        // is what made `loginitem` dead before the fix. Guard all known aliases.
        let switchAliases = [
            "hello", "ws", "focusmode", "reload-config",
            "proficiency", "launch-at-login", "loginitem", "update-check",
        ]
        for alias in switchAliases {
            check("contract: alias '\(alias)' is routable via controlVerbs",
                  controlVerbs.contains(alias))
        }

        // The core verbs jcode relies on must always be advertised.
        for required in ["ping", "status", "version", "arrange", "focus", "reload"] {
            check("contract: advertises \(required)", caps.contains(required))
        }

        // Stable, user-facing verbs that integrators feature-detect on must be
        // advertised so the handshake never understates the surface (the
        // `update`/`quit`/`login`/etc. omission this test now prevents).
        for advertised in ["close", "display", "skills", "login", "tutorial", "update", "quit"] {
            check("contract: capabilities include \(advertised)", caps.contains(advertised))
        }

        // The protocol revision is a positive integer (the coarse compat gate).
        check(
            "contract: protocol revision >= 1",
            ScrollWMController.controlProtocolRevision >= 1
        )

        // `version` JSON is well-formed and carries the handshake fields with the
        // expected types/values.
        let controller = ScrollWMController()
        let versionJSON = controller.controlVersionJSON()
        let versionObj = (try? JSONSerialization.jsonObject(
            with: Data(versionJSON.utf8))) as? [String: Any]
        check("contract: version JSON parses", versionObj != nil)
        check(
            "contract: version.name == ScrollWM",
            (versionObj?["name"] as? String) == "ScrollWM"
        )
        check(
            "contract: version.protocol matches constant",
            (versionObj?["protocol"] as? Int) == ScrollWMController.controlProtocolRevision
        )
        check(
            "contract: version.capabilities matches list",
            (versionObj?["capabilities"] as? [String]) == ScrollWMController.controlCapabilities
        )

        // `status` (while dormant) is well-formed and mirrors the handshake
        // fields so a single call gives integrators version + protocol.
        let statusJSON = controller.controlStatusJSON()
        let statusObj = (try? JSONSerialization.jsonObject(
            with: Data(statusJSON.utf8))) as? [String: Any]
        check("contract: status JSON parses", statusObj != nil)
        check(
            "contract: status carries protocol",
            (statusObj?["protocol"] as? Int) == ScrollWMController.controlProtocolRevision
        )
        check(
            "contract: status carries managing flag",
            statusObj?["managing"] != nil
        )
    }
}
