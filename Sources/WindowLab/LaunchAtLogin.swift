import Foundation
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// PURE launch-at-login reconciliation policy.
///
/// Decides what to DO to the macOS login-item registration given the user's
/// desired setting, the registration's current state, and whether this process
/// is even an installable `.app` bundle (a dev `WindowLab` binary can't be a
/// login item). No `SMAppService`, disk, or AppKit here — every input is an
/// argument — so the whole decision is deterministic and unit-testable, the way
/// `UpdatePolicy` / `KeybindingProficiency` keep their logic out of the I/O.
/// `LaunchAtLoginManager` is the thin shell that reads the real status, asks
/// this for the action, and performs it.
enum LaunchAtLoginPolicy {

    /// The registration state as ScrollWM cares about it — a small, stable view
    /// of `SMAppService.Status` (plus an "unsupported"/dev-binary case) so the
    /// policy is independent of the OS enum.
    enum Status: Equatable {
        /// Registered and active: ScrollWM WILL launch at login.
        case enabled
        /// Not registered (default / after an unregister).
        case notRegistered
        /// Registered but the user must approve it in System Settings > General
        /// > Login Items (macOS may require a manual toggle on first register).
        case requiresApproval
        /// Not an installable app bundle (dev `WindowLab` binary): login items
        /// don't apply, so there is nothing to reconcile.
        case unsupported
    }

    /// What the shell should do to converge the real registration on the user's
    /// desire.
    enum Action: Equatable {
        /// Register the main app as a login item.
        case register
        /// Unregister the login item.
        case unregister
        /// Already converged (or can't act): do nothing.
        case none
    }

    /// Decide the action that moves the current `status` toward `desired`.
    ///
    /// Rules:
    ///   - A dev binary (`.unsupported`) can never register: always `.none`.
    ///   - Want ON: register unless already `.enabled`. `.requiresApproval`
    ///     still maps to `.register` — re-registering is harmless and is what
    ///     re-surfaces the System Settings approval the user must flip.
    ///   - Want OFF: unregister only if currently registered in any form
    ///     (`.enabled`/`.requiresApproval`); otherwise nothing to do.
    static func reconcile(desired: Bool, status: Status) -> Action {
        guard status != .unsupported else { return .none }
        if desired {
            return status == .enabled ? .none : .register
        } else {
            switch status {
            case .enabled, .requiresApproval: return .unregister
            case .notRegistered, .unsupported: return .none
            }
        }
    }

    /// A short, human-readable description of the effective state, for the menu
    /// item's secondary text / CLI reply. Pure so it's testable.
    static func describe(desired: Bool, status: Status) -> String {
        switch status {
        case .unsupported:
            return "unavailable (run the installed ScrollWM.app to enable)"
        case .enabled:
            return desired ? "on" : "on (turning off…)"
        case .requiresApproval:
            return "needs approval in System Settings ▸ General ▸ Login Items"
        case .notRegistered:
            return desired ? "off (turning on…)" : "off"
        }
    }
}

/// Thin, impure shell that registers/unregisters ScrollWM as a macOS login item
/// via `SMAppService` and reconciles it against the config setting. All decision
/// logic lives in the pure `LaunchAtLoginPolicy`; this file only reads the live
/// `SMAppService.Status` and performs the chosen action.
///
/// Only meaningful for the installed `ScrollWM.app`. When running as the bare
/// `WindowLab` dev/CLI binary (or under a headless test backend), every method
/// is a safe no-op so tests and dev runs never touch the user's real login
/// items.
enum LaunchAtLoginManager {

    /// True when this process is the installed `.app` (the only context where a
    /// login item is meaningful) and not running under a headless test backend.
    static var isSupported: Bool {
        guard AXSource.backend == nil else { return false }
        return Bundle.main.bundleURL.pathExtension == "app"
    }

    /// The current login-item status, mapped into the pure policy's `Status`.
    static func status() -> LaunchAtLoginPolicy.Status {
        guard isSupported else { return .unsupported }
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:           return .enabled
            case .notRegistered:     return .notRegistered
            case .requiresApproval:  return .requiresApproval
            case .notFound:          return .notRegistered
            @unknown default:        return .notRegistered
            }
        }
        #endif
        return .unsupported
    }

    /// Whether ScrollWM is currently set to launch at login (best-effort live
    /// read). False on unsupported platforms / dev binaries.
    static var isEnabled: Bool { status() == .enabled }

    /// Reconcile the real login-item registration toward `desired`. Returns the
    /// action taken (`.none` when already converged / unsupported). Logs but
    /// never throws — a failed register/unregister must not crash the app.
    @discardableResult
    static func apply(desired: Bool) -> LaunchAtLoginPolicy.Action {
        let action = LaunchAtLoginPolicy.reconcile(desired: desired, status: status())
        guard action != .none else { return .none }
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            do {
                switch action {
                case .register:
                    try SMAppService.mainApp.register()
                    print("launch-at-login: registered (status now \(SMAppService.mainApp.status.rawValue))")
                case .unregister:
                    try SMAppService.mainApp.unregister()
                    print("launch-at-login: unregistered")
                case .none:
                    break
                }
            } catch {
                print("launch-at-login: \(action) failed: \(error.localizedDescription)")
            }
        }
        #endif
        return action
    }

    /// A one-line, human-readable status for the CLI / menu.
    static func describe(desired: Bool) -> String {
        LaunchAtLoginPolicy.describe(desired: desired, status: status())
    }
}
