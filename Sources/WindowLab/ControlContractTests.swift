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

        // The core verbs jcode relies on must always be advertised.
        for required in ["ping", "status", "version", "arrange", "focus", "reload"] {
            check("contract: advertises \(required)", caps.contains(required))
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
