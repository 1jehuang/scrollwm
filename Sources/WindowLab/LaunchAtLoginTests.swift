import Foundation

/// Pure-logic tests for `LaunchAtLoginPolicy` — the reconciliation that decides
/// whether to register/unregister ScrollWM's macOS login item given the user's
/// desired setting and the live registration status. No `SMAppService`, disk, or
/// AppKit (the shell `LaunchAtLoginManager` owns that), so this runs headless in
/// CI alongside the other `unittest` lanes.
enum LaunchAtLoginTests {

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        typealias P = LaunchAtLoginPolicy
        func reconcile(_ desired: Bool, _ s: P.Status) -> P.Action {
            P.reconcile(desired: desired, status: s)
        }

        // MARK: - Want ON

        check("want on + notRegistered -> register",
              reconcile(true, .notRegistered) == .register)
        check("want on + enabled -> none (already converged)",
              reconcile(true, .enabled) == .none)
        check("want on + requiresApproval -> register (re-surface approval)",
              reconcile(true, .requiresApproval) == .register)

        // MARK: - Want OFF

        check("want off + enabled -> unregister",
              reconcile(false, .enabled) == .unregister)
        check("want off + requiresApproval -> unregister",
              reconcile(false, .requiresApproval) == .unregister)
        check("want off + notRegistered -> none",
              reconcile(false, .notRegistered) == .none)

        // MARK: - Dev binary / unsupported is always inert

        check("unsupported never registers (want on)",
              reconcile(true, .unsupported) == .none)
        check("unsupported never unregisters (want off)",
              reconcile(false, .unsupported) == .none)

        // MARK: - Idempotence: applying the converged state is a fixed point.
        // After a successful register, status becomes .enabled; reconciling the
        // SAME desire against it must be .none (no flapping / relaunch loop).
        check("on is a fixed point once enabled",
              reconcile(true, .enabled) == .none)
        check("off is a fixed point once notRegistered",
              reconcile(false, .notRegistered) == .none)

        // MARK: - describe() is total + sensible

        check("describe enabled+on says on",
              P.describe(desired: true, status: .enabled) == "on")
        check("describe notRegistered+off says off",
              P.describe(desired: false, status: .notRegistered) == "off")
        check("describe unsupported mentions installed app",
              P.describe(desired: true, status: .unsupported).contains("ScrollWM.app"))
        check("describe requiresApproval mentions Login Items",
              P.describe(desired: true, status: .requiresApproval).contains("Login Items"))
        // Every combination produces a non-empty string (totality).
        for d in [true, false] {
            for s in [P.Status.enabled, .notRegistered, .requiresApproval, .unsupported] {
                check("describe non-empty (\(d), \(s))", !P.describe(desired: d, status: s).isEmpty)
            }
        }

        print("\n[unittest] launch-at-login policy: \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
