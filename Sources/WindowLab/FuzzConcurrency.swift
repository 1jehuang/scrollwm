import Foundation

// CONCURRENCY & LIFECYCLE fuzzer (owned by the `fuzzconc` swarm agent).
//
// Goal: drive the REAL async stack — `LifecycleMonitor` (poll + fast-adopt
// retries), `WindowEventObserver`, `scheduleWidthReconcile`, the controller's
// DispatchQueue.main hops — against `SimWindowWorld` with INTERLEAVED, randomly
// timed window create/destroy/resize/minimize/focus events, pumping the run
// loop between steps. Asserts the same model invariants the synchronous engine
// fuzzer does, plus async-specific ones (no double-adopt under coalescing, the
// strip converges after the poll, no lost/duplicated windows across a burst).
//
// Reuse `SplitMix64` from Fuzz.swift. Keep ALL logic self-contained in this
// file; encode any bug you find as a fixed deterministic seed so re-running the
// subcommand is the regression test. Entry point wired in main.swift.
func runFuzzConcurrency(args: [String]) -> Never {
    print("fuzzconc: not yet implemented")
    exit(0)
}
