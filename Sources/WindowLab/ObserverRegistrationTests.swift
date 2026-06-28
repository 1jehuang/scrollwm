import Foundation
import ApplicationServices

/// PURE unit tests for `ObserverRegistration`, the retry policy behind the
/// robust cold-start observer attach. No AX server, no AppKit, fully
/// deterministic - so the "register the instant a process launches, retry the
/// AXObserverAddNotification with a bounded backoff if the AX server is not
/// ready yet" decision is verified without a live process.
enum ObserverRegistrationTests {
    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  \u{2713} \(name)") }
            else { failed += 1; print("  \u{2717} \(name)") }
        }

        print("\n[unittest] ObserverRegistration (cold-start attach retry):")

        // --- attachSucceeded: which AXErrors mean "stop retrying" ---
        // .success obviously took.
        check("attach .success -> succeeded", ObserverRegistration.attachSucceeded(.success))
        // Already-registered means a prior pass took: terminal, don't re-add.
        check("attach .notificationAlreadyRegistered -> terminal (no retry)",
              ObserverRegistration.attachSucceeded(.notificationAlreadyRegistered))
        // The app vanished mid-launch: the element/observer is invalid; retrying
        // can never help, so treat it as done (avoid spinning on a dead pid).
        check("attach .invalidUIElement -> terminal (app gone)",
              ObserverRegistration.attachSucceeded(.invalidUIElement))
        check("attach .invalidUIElementObserver -> terminal (observer gone)",
              ObserverRegistration.attachSucceeded(.invalidUIElementObserver))
        // The actual cold-start failure: the AX server has not finished spinning
        // up. THESE must be retryable, or the warm fast path stays dead.
        check("attach .cannotComplete -> RETRYABLE (AX not ready)",
              !ObserverRegistration.attachSucceeded(.cannotComplete))
        check("attach .failure -> RETRYABLE",
              !ObserverRegistration.attachSucceeded(.failure))
        check("attach .notImplemented -> RETRYABLE",
              !ObserverRegistration.attachSucceeded(.notImplemented))

        // --- retryDelay: bounded, monotonic-nondecreasing, gives up at the end ---
        let delays = ObserverRegistration.retryDelays
        check("retry schedule is non-empty", !delays.isEmpty)
        check("every retry delay is positive", delays.allSatisfy { $0 > 0 })
        // Progressive backoff: tight first, never shrinking.
        var nonDecreasing = true
        for i in 1..<delays.count where delays[i] < delays[i - 1] { nonDecreasing = false }
        check("retry schedule is non-decreasing (progressive backoff)", nonDecreasing)
        check("first retry delay is small (<= 20ms, adopt fast when AX is nearly ready)",
              delays.first! <= 0.02)

        // retryDelay(forAttempt:) indexes the schedule, then returns nil.
        check("retryDelay(0) == first delay",
              ObserverRegistration.retryDelay(forAttempt: 0) == delays.first)
        check("retryDelay(last index) == last delay",
              ObserverRegistration.retryDelay(forAttempt: delays.count - 1) == delays.last)
        check("retryDelay past the end -> nil (bounded: give up to the poll)",
              ObserverRegistration.retryDelay(forAttempt: delays.count) == nil)
        check("retryDelay far past the end -> nil",
              ObserverRegistration.retryDelay(forAttempt: delays.count + 50) == nil)
        check("retryDelay(negative) -> nil (defensive)",
              ObserverRegistration.retryDelay(forAttempt: -1) == nil)

        // Total budget stays comfortably under the 2s safety-net poll, so a
        // genuinely stuck app never hangs registration - it falls through.
        let total = delays.reduce(0, +)
        check(String(format: "total retry budget < 2s poll (got %.2fs)", total), total < 2.0)
        // ...but it is long enough to outlast a slow process's spin-up (the warm
        // window of a sluggish app still gets a working observer).
        check(String(format: "total retry budget >= 0.5s (covers a slow launch, got %.2fs)", total),
              total >= 0.5)

        print("[unittest] ObserverRegistration: \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
