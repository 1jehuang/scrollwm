import Foundation
import ApplicationServices
import AppKit

/// Reveal windows that are hidden from the current Space so "Arrange All
/// Windows" can adopt EVERYTHING, not just what is already on-screen.
///
/// Two kinds of "hidden" are handled, both of which bring the window back onto
/// the user's CURRENT Space (so the Space-safety contract in `arrange`/`resync`
/// is preserved - we never reach into another Space and teleport the user):
///
///   1. App hidden (Cmd+H): every window of the app is off-screen. We `unhide()`
///      the running application.
///   2. Window minimized (to the Dock): the AX `kAXMinimizedAttribute` is true.
///      We clear it, which de-miniaturizes the window onto the current Space.
///
/// The reveal is a precondition step: after the windows materialize on-screen,
/// the ordinary (Space-aware) adopt path in `arrange`/`resync` picks them up
/// with no special-casing - they are simply no longer hidden or minimized.
///
/// The pure predicates are factored out so the policy is unit-testable without
/// Accessibility permission or real windows.
enum WindowReveal {

    /// PURE: from each app's hidden flag, the pids that should be unhidden.
    static func appsToUnhide(_ apps: [(pid: pid_t, isHidden: Bool)]) -> [pid_t] {
        apps.filter { $0.isHidden }.map { $0.pid }
    }

    /// PURE: should this AX window be de-miniaturized? We key on the ROLE
    /// (`AXWindow` = a genuine top-level window), NOT the subrole: macOS mutates
    /// a window's subrole while it is minimized (a standard window can report
    /// `AXDialog` in the Dock), so a subrole gate would miss exactly the windows
    /// we want to restore. De-miniaturizing is also low-stakes: the downstream
    /// `adopt` filter still only TILES standard windows, so an un-minimized
    /// dialog simply becomes reachable (floating), never wrongly tiled.
    static func shouldUnminimize(role: String?, isMinimized: Bool) -> Bool {
        isMinimized && role == kAXWindowRole as String
    }

    /// Counts of what a reveal pass acted on (for logging / tests).
    struct Result: Equatable {
        var unhiddenApps: Int = 0
        var unminimizedWindows: Int = 0
        /// True when anything was revealed, so the caller should wait for the
        /// unhide / de-miniaturize animation to land before enumerating again.
        var didReveal: Bool { unhiddenApps > 0 || unminimizedWindows > 0 }
    }

    /// IMPURE: unhide hidden apps and de-miniaturize minimized standard windows.
    ///
    /// `pidFilter` (when set) restricts the pass to those pids - this is what
    /// keeps sandbox/test mode hard-locked to its own disposable windows, since
    /// the controller passes its `sandboxPIDs` straight through. With a filter we
    /// enumerate exactly those pids (no activation-policy gate, mirroring
    /// `arrange`'s filtered path so accessory test windows are reachable); with
    /// no filter we sweep every regular app, matching `AXSource.allWindows`.
    @discardableResult
    static func reveal(pidFilter: Set<pid_t>? = nil) -> Result {
        // Headless backend: the sim world owns hidden/minimized state, so resolve
        // pids + reveal through it (a fake/accessory pid has no NSRunningApplication).
        if let backend = AXSource.backend {
            let pids: [pid_t] = pidFilter.map { Array($0) } ?? backend.regularAppPIDs()
            var result = Result()
            for pid in pids {
                if backend.appIsHidden(pid: pid), backend.unhideApp(pid: pid) {
                    result.unhiddenApps += 1
                }
                for w in backend.windows(forPID: pid)
                where shouldUnminimize(role: w.role, isMinimized: w.isMinimized) {
                    if AXSource.setBool(w.element, kAXMinimizedAttribute as String, false) == .success {
                        result.unminimizedWindows += 1
                    }
                }
            }
            return result
        }

        let apps: [NSRunningApplication]
        if let pidFilter {
            apps = pidFilter.compactMap { NSRunningApplication(processIdentifier: $0) }
                .filter { !$0.isTerminated }
        } else {
            apps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && !$0.isTerminated
            }
        }

        var result = Result()
        for app in apps {
            // Unhide the whole app first (a hidden app's windows are all off the
            // current Space). `unhide()` is a no-op + false when not hidden.
            if app.isHidden, app.unhide() {
                result.unhiddenApps += 1
            }
            // De-miniaturize any minimized top-level windows.
            for w in AXSource.windows(for: app)
            where shouldUnminimize(role: w.role, isMinimized: w.isMinimized) {
                if AXSource.setBool(w.element, kAXMinimizedAttribute as String, false) == .success {
                    result.unminimizedWindows += 1
                }
            }
        }
        return result
    }
}
