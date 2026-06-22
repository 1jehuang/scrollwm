import Foundation
import AppKit
import ApplicationServices

/// Single source of truth for ScrollWM's one and only permission: Accessibility.
///
/// Why this type exists
/// --------------------
/// The raw `AXIsProcessTrusted()` boolean is not enough to drive a good
/// onboarding experience:
///
///   1. **Stale `false` after launch.** For the first moments after a process
///      starts, `AXIsProcessTrusted()` can report `false` even when permission
///      is actually granted. Trusting that single reading made the app flash a
///      "waiting for Accessibility" UI and fire a system prompt on *every*
///      launch. So we must debounce a short grace window before believing a
///      `false`. The whole point: **never ask when it's already on.**
///
///   2. **A bool can't tell "never asked" from "explicitly off".** First-run
///      (never prompted) deserves friendly onboarding; an explicit deny that
///      stays off deserves troubleshooting copy ("toggle it off and on"). We
///      persist a tiny marker the first time we show the system prompt so we
///      can tell these apart.
///
///   3. **Live updates, no relaunch.** macOS will not let any app flip the
///      Accessibility toggle for the user, so the user must do it by hand. We
///      poll so the instant they flip it, the whole app reacts: onboarding
///      dismisses, the controller starts, the menu updates. No relaunch, and
///      no second prompt.
final class AccessibilityPermission {
    enum State: Equatable {
        /// Trusted: we may drive the Accessibility API.
        case granted
        /// Never prompted on this machine: show first-run onboarding.
        case notDetermined
        /// Prompted before but currently off: show troubleshooting copy.
        case denied

        var isGranted: Bool { self == .granted }
    }

    static let shared = AccessibilityPermission()

    /// Current best-known state. Updated live by the poll timer.
    private(set) var state: State = .notDetermined

    private var observers: [(State) -> Void] = []
    private var pollTimer: Timer?

    private init() {
        state = Self.resolveImmediate(hasPrompted: hasPrompted)
    }

    /// Live trust reading, bypassing the cached `state` (which only updates on
    /// the poll tick). Use this anywhere a decision must reflect *right now*,
    /// especially before doing anything that could surface the system modal.
    var isTrustedNow: Bool { AXIsProcessTrusted() }

    // MARK: - Prompt policy (pure, unit-tested)

    /// Should onboarding auto-fire the one-time system Accessibility modal?
    ///
    /// Only on a *genuine first run*: currently untrusted AND never prompted
    /// before on this machine. This is the single guard that stops the
    /// "ScrollWM keeps asking me to turn on Accessibility" dialog spam:
    ///   - Trusted already   -> never (the modal must never appear when we
    ///     don't actually need the user; a stale-`false` must not trigger it).
    ///   - Already prompted  -> never auto-fire again; deep-link to Settings
    ///     and poll instead, so repeat launches are silent.
    static func shouldAutoPrompt(isTrusted: Bool, hasPrompted: Bool) -> Bool {
        !isTrusted && !hasPrompted
    }

    // MARK: - Persisted "we have prompted" marker

    /// A zero-byte marker file written the first time we surface the system
    /// prompt. Its presence means "the user has seen the ask before", which
    /// turns `notDetermined` into `denied` once trust is genuinely absent.
    private static var promptedMarkerURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScrollWM", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ax-prompted")
    }

    private(set) var hasPrompted: Bool {
        get { FileManager.default.fileExists(atPath: Self.promptedMarkerURL.path) }
        set { if newValue { try? Data().write(to: Self.promptedMarkerURL, options: .atomic) } }
    }

    /// A zero-byte marker written the first time trust is ever observed. Its
    /// presence means "Accessibility has been granted on this machine before",
    /// which lets us treat a launch-time `false` as a stale/transient reading
    /// (TCC not yet attached, a signature re-evaluation, a WindowServer hiccup)
    /// rather than a real denial — so we wait silently instead of popping any
    /// onboarding UI or prompt.
    private static var grantedMarkerURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScrollWM", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ax-granted")
    }

    private(set) var hasEverBeenGranted: Bool {
        get { FileManager.default.fileExists(atPath: Self.grantedMarkerURL.path) }
        set { if newValue { try? Data().write(to: Self.grantedMarkerURL, options: .atomic) } }
    }

    // MARK: - State resolution

    private static func resolveImmediate(hasPrompted: Bool) -> State {
        if AXIsProcessTrusted() { return .granted }
        return hasPrompted ? .denied : .notDetermined
    }

    /// Recompute and broadcast if the state changed. Cheap; safe to call often.
    @discardableResult
    private func refresh() -> State {
        let next = Self.resolveImmediate(hasPrompted: hasPrompted)
        if next == .granted && !hasEverBeenGranted { hasEverBeenGranted = true }
        if next != state {
            state = next
            for observer in observers { observer(next) }
        }
        return next
    }

    // MARK: - Public API

    /// Subscribe to live state changes. The closure is invoked on the main
    /// thread whenever the resolved state changes (e.g. the user flips the
    /// Accessibility toggle). Returns the current state immediately too.
    @discardableResult
    func observe(_ block: @escaping (State) -> Void) -> State {
        observers.append(block)
        ensurePolling()
        return state
    }

    /// Resolve the launch-time state, tolerating the stale-`false` window.
    ///
    /// If trust shows up (immediately or within `graceSeconds`), completes with
    /// `.granted` and the app should start silently — no UI, no prompt. If the
    /// grace window elapses still-untrusted, completes with `.notDetermined`
    /// or `.denied` so the caller can show onboarding.
    func resolveAtLaunch(graceSeconds: TimeInterval = 2.0,
                         completion: @escaping (State) -> Void) {
        let deadline = Date().addingTimeInterval(graceSeconds)

        func tick() {
            if refresh() == .granted {
                ensurePolling()
                completion(.granted)
                return
            }
            if Date() < deadline {
                // Still inside the stale-false grace window: re-check soon,
                // showing no UI and firing no prompt.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: tick)
                return
            }
            // Genuinely untrusted after the grace window.
            ensurePolling()
            completion(state)
        }
        tick()
    }

    /// Fire the one-time system Accessibility prompt (adds ScrollWM to the
    /// list and flips the per-app switch into view). Records that we've asked.
    ///
    /// Hardened so it can never become a source of repeated modals:
    ///   - If we're already trusted, this is a no-op (returns `true`) and the
    ///     modal is never requested. macOS would not draw the dialog when
    ///     trusted anyway, but we refuse to even ask, defensively.
    ///   - The "prompted" marker is only written when we actually fire, so a
    ///     short-circuit here never burns the genuine first-run prompt.
    @discardableResult
    func requestSystemPrompt() -> Bool {
        if isTrustedNow {
            refresh()
            return true
        }
        hasPrompted = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        refresh()
        return trusted
    }

    /// Deep-link straight to the Accessibility pane in System Settings.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Continuous live polling so a hand-flipped toggle is detected within a
    /// fraction of a second, with no relaunch. Idempotent.
    private func ensurePolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Common-mode so polling continues while menus/sheets are tracking.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
}
