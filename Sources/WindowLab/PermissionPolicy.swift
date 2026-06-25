import Foundation

/// PURE decision logic for ScrollWM's one and only permission: Accessibility.
///
/// Why this type exists (separately from `AccessibilityPermission`)
/// ----------------------------------------------------------------
/// `AccessibilityPermission` is the *impure* shell: it reads the live
/// `AXIsProcessTrusted()` boolean, persists the on-disk markers, runs the poll
/// timer, and drives AppKit. None of that is unit-testable without real TCC
/// state and a system modal we must NEVER fire on the user's machine.
///
/// Every actual *decision* the permission engine makes, however, is a pure
/// function of four observable facts:
///
///   - `isTrusted`            — the live trust reading right now.
///   - `hasPrompted`          — have we ever surfaced the system modal here?
///   - `hasEverBeenGranted`   — has trust ever been observed on this machine?
///   - `elapsed`              — seconds since launch resolution began.
///
/// Pulling those decisions out into this enum lets us cover the full behavior
/// matrix — genuine first run, repeat-launch granted, repeat-launch denied,
/// stale-`false` after an update, a real revocation after the grace window —
/// in headless tests, and makes the central guarantee ("never ask the user
/// when it's already on") something we can *prove* rather than hope for.
///
/// `AccessibilityPermission` delegates here; `PermissionPolicyTests` exercises
/// every branch.
enum PermissionPolicy {

    // MARK: - Resolved state

    /// The resolved permission state, derived from a raw trust reading plus the
    /// persisted "we have prompted before" marker. A bare bool cannot tell
    /// "never asked" (deserves friendly onboarding) from "explicitly off"
    /// (deserves troubleshooting copy), which is the whole reason this enum,
    /// and the `hasPrompted` marker, exist.
    enum State: Equatable {
        /// Trusted: we may drive the Accessibility API.
        case granted
        /// Never prompted on this machine: show first-run onboarding.
        case notDetermined
        /// Prompted before but currently off: show troubleshooting copy.
        case denied

        var isGranted: Bool { self == .granted }
    }

    /// Resolve `State` purely from the trust reading and the prompted marker.
    ///
    /// Trusted always wins. Otherwise the prompted marker disambiguates a
    /// genuine first run (`notDetermined`) from an explicit/lingering deny
    /// (`denied`).
    static func resolveState(isTrusted: Bool, hasPrompted: Bool) -> State {
        if isTrusted { return .granted }
        return hasPrompted ? .denied : .notDetermined
    }

    // MARK: - System-modal policy

    /// Should onboarding auto-fire the one-time system Accessibility modal?
    ///
    /// Only on a *genuine first run*: currently untrusted AND never prompted
    /// before on this machine. This is the single guard that stops the
    /// "ScrollWM keeps asking me to turn on Accessibility" dialog spam:
    ///   - Trusted already  -> never (a stale-`false` must not trigger it).
    ///   - Already prompted -> never auto-fire again; deep-link to Settings and
    ///     poll instead, so repeat launches are silent.
    static func shouldAutoPrompt(isTrusted: Bool, hasPrompted: Bool) -> Bool {
        !isTrusted && !hasPrompted
    }

    // MARK: - Launch grace (the universal stale-`false` debounce)

    /// What a single tick of the launch-time resolution loop should do.
    ///
    /// For the first moments after a process starts, `AXIsProcessTrusted()` can
    /// report `false` even when permission is actually granted (TCC not yet
    /// attached, a signature re-eval, a WindowServer hiccup). Trusting that lone
    /// reading made the app flash a "waiting" UI and fire a prompt on *every*
    /// launch. So we debounce: inside the grace window an untrusted reading is
    /// not believed; we re-check silently.
    enum GraceTick: Equatable {
        /// Trust is present -> resolve as granted and start silently.
        case resolvedGranted
        /// Still inside the grace window and untrusted -> re-check soon, show
        /// nothing, fire nothing.
        case keepWaiting
        /// Grace elapsed and still untrusted -> resolve the final state.
        case graceExpired
    }

    /// Pure decision for one launch-resolution tick. `elapsed` is seconds since
    /// resolution began; the boundary is exclusive (`elapsed >= graceSeconds`
    /// means the grace has expired) so a `graceSeconds` of 0 expires at once.
    static func graceTick(isTrusted: Bool,
                          elapsed: TimeInterval,
                          graceSeconds: TimeInterval) -> GraceTick {
        if isTrusted { return .resolvedGranted }
        return elapsed < graceSeconds ? .keepWaiting : .graceExpired
    }

    // MARK: - The whole-launch decision

    /// What the launch flow should DO right now, as a total pure function of
    /// the four observable facts. This is the single brain behind
    /// "start vs wait silently vs show onboarding (and may we prompt?)".
    enum LaunchAction: Equatable {
        /// Trust is present: start the controller silently. No UI, no prompt.
        case start
        /// Untrusted, but inside a grace window where a `false` is likely
        /// stale/transient. Keep polling silently; show nothing, fire nothing.
        case waitSilently
        /// Genuinely untrusted past every grace window: surface onboarding.
        /// `autoPrompt` is whether onboarding may fire the one-time system
        /// modal — true ONLY on a genuine first run.
        case showOnboarding(autoPrompt: Bool)
    }

    /// Default grace windows (seconds), matching the production launch flow:
    ///   - `launchGrace`: the universal stale-`false` debounce applied to EVERY
    ///     launch (granted or not).
    ///   - `silentGrace`: the EXTENDED window we wait, still silently, when
    ///     trust was ever observed on this machine before — because a
    ///     launch-time `false` there is overwhelmingly a stale TCC reading, not
    ///     a real revocation. Measured from launch start, it equals the launch
    ///     grace plus the extra silent settle time (2.0 + 8.0 in production).
    static let defaultLaunchGrace: TimeInterval = 2.0
    static let defaultSilentGrace: TimeInterval = 10.0

    /// The core launch decision. PURE.
    ///
    /// Branch order encodes the guarantees:
    ///   1. Trusted at any moment            -> `.start` (never any UI/prompt).
    ///   2. Inside the launch grace          -> `.waitSilently` (debounce a
    ///      stale `false`, regardless of history).
    ///   3. Grace expired but EVER granted   -> keep `.waitSilently` through the
    ///      extended window; only past it show onboarding, and NEVER prompt
    ///      (it has been granted before, so a `false` is stale or a revocation —
    ///      either way we must not re-ask). This is the heart of "never ask
    ///      when it's already on."
    ///   4. Grace expired, never granted     -> `.showOnboarding`, auto-firing
    ///      the modal only on a genuine first run (`shouldAutoPrompt`).
    static func launchAction(isTrusted: Bool,
                             hasPrompted: Bool,
                             hasEverBeenGranted: Bool,
                             elapsed: TimeInterval,
                             launchGrace: TimeInterval = defaultLaunchGrace,
                             silentGrace: TimeInterval = defaultSilentGrace) -> LaunchAction {
        // 1 & 2: the universal launch grace (trust wins; otherwise debounce).
        switch graceTick(isTrusted: isTrusted, elapsed: elapsed, graceSeconds: launchGrace) {
        case .resolvedGranted: return .start
        case .keepWaiting:     return .waitSilently
        case .graceExpired:    break
        }

        // 3: ever-granted machine -> silent extended wait, then help (no modal).
        if hasEverBeenGranted {
            if elapsed < silentGrace { return .waitSilently }
            return .showOnboarding(autoPrompt: false)
        }

        // 4: never granted -> genuine onboarding; prompt only on a true first run.
        return .showOnboarding(autoPrompt: shouldAutoPrompt(isTrusted: isTrusted,
                                                            hasPrompted: hasPrompted))
    }
}
