import Foundation

/// Headless, PURE tests for `PermissionPolicy` — the decision brain behind
/// ScrollWM's single Accessibility permission.
///
/// These never touch real TCC state and NEVER fire the system modal: every
/// input is a plain value, so the full behavior matrix is provable offline.
/// The contract under test is the central guarantee: **never ask the user when
/// it's already on**, while still giving a genuine first run a friendly prompt
/// and a real revocation a non-dead-end troubleshooting path.
///
/// Kept in its OWN file (per the swarm rules) exposing `run() -> Bool` that
/// prints `PASS`/`FAIL`; the coordinator wires it into `unittest`/`headlesstest`.
///
/// Run (once wired): `WindowLab permissiontest` or via the suite runner.
enum PermissionPolicyTests {

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        typealias P = PermissionPolicy

        print("PermissionPolicyTests:")

        // ===================== resolveState ===================================
        // Trust always wins, regardless of the prompted marker.
        check("state: trusted -> granted (never asked)",
              P.resolveState(isTrusted: true, hasPrompted: false) == .granted)
        check("state: trusted -> granted (asked before)",
              P.resolveState(isTrusted: true, hasPrompted: true) == .granted)
        // The prompted marker is the ONLY thing separating first-run from deny.
        check("state: untrusted + never asked -> notDetermined (first run)",
              P.resolveState(isTrusted: false, hasPrompted: false) == .notDetermined)
        check("state: untrusted + asked before -> denied (troubleshoot)",
              P.resolveState(isTrusted: false, hasPrompted: true) == .denied)
        check("state: .granted.isGranted is true",
              P.State.granted.isGranted)
        check("state: non-granted.isGranted is false",
              !P.State.denied.isGranted && !P.State.notDetermined.isGranted)

        // ===================== shouldAutoPrompt ===============================
        // The macOS system modal must auto-fire ONLY on a genuine first run.
        check("autoprompt: genuine first run (untrusted, never asked) -> prompt",
              P.shouldAutoPrompt(isTrusted: false, hasPrompted: false) == true)
        check("autoprompt: already trusted -> never prompt (even if never asked)",
              P.shouldAutoPrompt(isTrusted: true, hasPrompted: false) == false)
        check("autoprompt: already trusted + asked before -> never prompt",
              P.shouldAutoPrompt(isTrusted: true, hasPrompted: true) == false)
        check("autoprompt: untrusted but asked before -> never re-prompt",
              P.shouldAutoPrompt(isTrusted: false, hasPrompted: true) == false)

        // ===================== graceTick (stale-false debounce) ===============
        // Trust at any instant resolves immediately, even before the grace ends.
        check("grace: trusted mid-window -> resolvedGranted",
              P.graceTick(isTrusted: true, elapsed: 0.0, graceSeconds: 2.0) == .resolvedGranted)
        check("grace: untrusted inside window -> keepWaiting (debounce stale false)",
              P.graceTick(isTrusted: false, elapsed: 1.0, graceSeconds: 2.0) == .keepWaiting)
        // Boundary is exclusive: at exactly graceSeconds the grace has expired.
        check("grace: untrusted just before boundary -> keepWaiting",
              P.graceTick(isTrusted: false, elapsed: 1.999, graceSeconds: 2.0) == .keepWaiting)
        check("grace: untrusted at boundary -> graceExpired",
              P.graceTick(isTrusted: false, elapsed: 2.0, graceSeconds: 2.0) == .graceExpired)
        check("grace: untrusted past window -> graceExpired",
              P.graceTick(isTrusted: false, elapsed: 5.0, graceSeconds: 2.0) == .graceExpired)
        // A zero grace expires at once for an untrusted reading.
        check("grace: zero grace, untrusted -> graceExpired immediately",
              P.graceTick(isTrusted: false, elapsed: 0.0, graceSeconds: 0.0) == .graceExpired)
        check("grace: zero grace, trusted -> resolvedGranted",
              P.graceTick(isTrusted: true, elapsed: 0.0, graceSeconds: 0.0) == .resolvedGranted)

        // ===================== launchAction: the whole-launch brain ===========
        // Helper with production-default grace windows (launch 2s, silent 10s).
        func action(_ trusted: Bool, _ prompted: Bool, _ everGranted: Bool, _ elapsed: TimeInterval)
            -> P.LaunchAction {
            P.launchAction(isTrusted: trusted, hasPrompted: prompted,
                           hasEverBeenGranted: everGranted, elapsed: elapsed)
        }

        // --- Scenario 1: GENUINE FIRST RUN -----------------------------------
        // Never trusted, never prompted, never granted. Inside the launch grace
        // we still wait silently (the very first reading is often a stale false).
        check("scenario/first-run: inside launch grace -> waitSilently (no UI yet)",
              action(false, false, false, 1.0) == .waitSilently)
        // After the grace, surface onboarding AND auto-fire the one-time modal —
        // this is the ONE place the prompt is allowed.
        check("scenario/first-run: after grace -> showOnboarding(autoPrompt: true)",
              action(false, false, false, 2.5) == .showOnboarding(autoPrompt: true))
        // If trust appears at any moment (user granted during the prompt) -> start.
        check("scenario/first-run: trust appears -> start (silent)",
              action(true, true, false, 3.0) == .start)

        // --- Scenario 2: REPEAT LAUNCH, ALREADY GRANTED ----------------------
        // Trusted: start silently the instant we read trust, no matter the
        // history or how long we've waited. This is the guarantee.
        check("scenario/granted: trusted at t=0 -> start",
              action(true, true, true, 0.0) == .start)
        check("scenario/granted: trusted late -> still start (never any UI)",
              action(true, true, true, 99.0) == .start)

        // --- Scenario 3: REPEAT LAUNCH, GENUINELY DENIED ---------------------
        // Prompted before, never actually granted, still untrusted. Inside the
        // grace -> wait; after it -> onboarding but NEVER re-fire the modal
        // (we deep-link to Settings instead, so repeat launches don't spam).
        check("scenario/denied: inside grace -> waitSilently",
              action(false, true, false, 1.0) == .waitSilently)
        check("scenario/denied: after grace -> showOnboarding(autoPrompt: false)",
              action(false, true, false, 2.5) == .showOnboarding(autoPrompt: false))

        // --- Scenario 4: STALE FALSE AFTER AN UPDATE -------------------------
        // Was granted before (marker present); a launch-time false is almost
        // certainly a transient TCC re-eval. We must wait SILENTLY across the
        // whole extended silent window — never show UI, never prompt — and the
        // moment trust returns, start.
        check("scenario/stale: ever-granted, untrusted in launch grace -> waitSilently",
              action(false, true, true, 1.0) == .waitSilently)
        check("scenario/stale: ever-granted, untrusted past launch grace -> still waitSilently",
              action(false, true, true, 5.0) == .waitSilently)
        check("scenario/stale: ever-granted, untrusted just before silent deadline -> waitSilently",
              action(false, true, true, 9.99) == .waitSilently)
        check("scenario/stale: trust returns after the hiccup -> start (no prompt)",
              action(true, true, true, 6.0) == .start)
        // Crucially, an ever-granted machine NEVER auto-prompts, even if (somehow)
        // the prompted marker were missing — being granted before forbids re-asking.
        check("scenario/stale: ever-granted never auto-prompts (even if prompt marker absent)",
              action(false, false, true, 11.0) == .showOnboarding(autoPrompt: false))

        // --- Scenario 5: REAL REVOCATION AFTER THE GRACE ---------------------
        // The user genuinely turned Accessibility OFF after having granted it.
        // We wait silently through the extended window (in case it's a hiccup),
        // then surface troubleshooting help — but STILL never fire the modal.
        check("scenario/revocation: ever-granted, untrusted past silent deadline -> showOnboarding",
              action(false, true, true, 10.0) == .showOnboarding(autoPrompt: false))
        check("scenario/revocation: well past silent deadline -> showOnboarding, no prompt",
              action(false, true, true, 30.0) == .showOnboarding(autoPrompt: false))

        // ===================== Cross-cutting invariants =======================
        // INVARIANT A: trust => .start, for EVERY combination of the markers and
        // EVERY elapsed value. ("Never ask / never show UI when it's on.")
        var trustAlwaysStarts = true
        for prompted in [false, true] {
            for everGranted in [false, true] {
                for elapsed in [0.0, 0.5, 2.0, 5.0, 10.0, 100.0] {
                    if action(true, prompted, everGranted, elapsed) != .start {
                        trustAlwaysStarts = false
                    }
                }
            }
        }
        check("invariant: trusted => .start for ALL (hasPrompted, hasEverBeenGranted, elapsed)",
              trustAlwaysStarts)

        // INVARIANT B: an ever-granted machine NEVER auto-prompts, for every
        // combination. (A re-prompt on a machine that was ever on is the bug.)
        var everGrantedNeverPrompts = true
        for trusted in [false, true] {
            for prompted in [false, true] {
                for elapsed in [0.0, 1.0, 2.0, 9.0, 10.0, 50.0] {
                    if case let .showOnboarding(autoPrompt) = action(trusted, prompted, true, elapsed),
                       autoPrompt {
                        everGrantedNeverPrompts = false
                    }
                }
            }
        }
        check("invariant: ever-granted => never showOnboarding(autoPrompt: true)",
              everGrantedNeverPrompts)

        // INVARIANT C: auto-prompt can ONLY happen on a genuine first run
        // (untrusted, never prompted, never granted). It is the single doorway
        // for the system modal.
        var promptOnlyFirstRun = true
        for trusted in [false, true] {
            for prompted in [false, true] {
                for everGranted in [false, true] {
                    for elapsed in [0.0, 2.0, 5.0, 20.0] {
                        if case let .showOnboarding(autoPrompt) = action(trusted, prompted, everGranted, elapsed),
                           autoPrompt {
                            let genuineFirstRun = !trusted && !prompted && !everGranted
                            if !genuineFirstRun { promptOnlyFirstRun = false }
                        }
                    }
                }
            }
        }
        check("invariant: showOnboarding(autoPrompt: true) ONLY on genuine first run",
              promptOnlyFirstRun)

        // INVARIANT D: never show onboarding while still inside the launch grace
        // (the universal stale-false debounce protects every path equally).
        var noUIInsideLaunchGrace = true
        for trusted in [false] {                 // trusted resolves to .start anyway
            for prompted in [false, true] {
                for everGranted in [false, true] {
                    let a = action(trusted, prompted, everGranted, 1.0)  // elapsed < 2.0 grace
                    if case .showOnboarding = a { noUIInsideLaunchGrace = false }
                    _ = a
                }
            }
        }
        check("invariant: no onboarding UI inside the launch grace window",
              noUIInsideLaunchGrace)

        print("PermissionPolicyTests: \(passed) passed, \(failed) failed")
        return summarize(failed: failed)
    }

    /// Print the PASS/FAIL line and return success. Kept separate from `run()`
    /// so `failed` arrives as an opaque parameter: inside `run` the counter is
    /// only mutated through the nested `check` closure, which makes the compiler
    /// constant-fold a `failed == 0` branch and warn it "will never be executed".
    private static func summarize(failed: Int) -> Bool {
        print(failed == 0 ? "PASS" : "FAIL")
        return failed == 0
    }
}
