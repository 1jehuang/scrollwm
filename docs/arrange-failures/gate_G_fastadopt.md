# GATE-G — Fast-adopt event path + churn

**Gate:** `LifecycleMonitor.fastAdopt` (the low-latency `kAXWindowCreated`
handler) + the poll timer, the path meant to CATCH a new window before it can
look "floating."
**Files:** `LifecycleMonitor.swift:395-500` (`fastAdopt`,
`scheduleFastAdoptRetry`, `stripIsOnCurrentSpace`), `WindowEventObserver.swift`
(AX notification registration + pidFilter), `ScrollWMApp.swift:777-779`
(`startLifecycle`).

## Why this matters for the user
The user spawns dozens of Ghostty processes in bursts (jcode "forest" swarm). The
fast path is what should adopt each new window within a few frames. Every place it
bails falls back to the poll, and the poll can itself freeze/coalesce (GATE-F),
so a fast-path miss can become an indefinitely-floating window.

## Edge cases

### FAST-G1 (P1) — bounded retries lapse -> handed to a poll that may freeze
**Where:** when the new window is not yet on the CG on-screen list, `fastAdopt`
calls `scheduleFastAdoptRetry` a bounded number of times then gives up
(`LifecycleMonitor.swift:442-453`). **Trigger:** the WindowServer publish lags the
`kAXWindowCreated` event beyond the retry budget (common when dozens of windows
spawn at once and the WindowServer is busy). **Symptom:** the window falls to the
slow poll; if the poll coalesces (FAST-G2) or freezes (GATE-F1), the window floats
until something else triggers a healthy resync. **Severity: P1.** **Fix sketch:**
make the retry budget adaptive to in-flight spawn load; ensure a lapsed fast-adopt
ALWAYS schedules a guaranteed (non-coalescable) reconcile.

### FAST-G2 (P1) — `enumerating` coalesce + in-flight bursts lose coverage
**Where:** `fastAdopt`/`resync` share the `enumerating` guard
(`LifecycleMonitor.swift:197`, and `fastAdopt`'s own re-entrancy). **Trigger:** a
flurry of window-created events while one enumeration runs. **Symptom:** events
that arrive mid-enumeration are not all reflected; some new windows are skipped
until a later cycle. **Severity: P1** (this is the churn signature the live data
showed). **Fix sketch:** queue created-PIDs seen during an in-flight enumeration
and immediately re-run for exactly those after it drains.

### FAST-G3 (P1) — a brand-NEW app's window isn't observed until registration
**Where:** `WindowEventObserver` only delivers `kAXWindowCreated` for apps it has
registered an observer on; a newly launched PROCESS must be picked up by a
registration sweep first. **Trigger:** launching a brand-new app/process (each
Ghostty `open -na` is a new PID). **Symptom:** the first window of a new process
can miss the fast path entirely and wait for the poll -> transient (or, with
GATE-F, persistent) floating. **Severity: P1.** **Fix sketch:** observe
`NSWorkspace.didLaunchApplication` and register the AX observer immediately, then
fast-adopt that PID.

### FAST-G4 (P2) — `stripIsOnCurrentSpace` bail mid-burst
**Where:** `fastAdopt` bails if the strip has slots but none are on the current
Space (`LifecycleMonitor.swift:458`). **Trigger:** during a burst, if the managed
columns transiently fail the current-Space test (GATE-C/B), the fast path treats
the user as "on another Space" and defers. **Symptom:** new windows not adopted
during the bail window. **Severity: P2** (shares root with GATE-F1).

### FAST-G5 (P2) — stale destroyed-window slot blocks re-adoption
**Where:** `unmanaged = appWindows.filter { !engine.isManaged($0.element) }`
(`LifecycleMonitor.swift:419`) uses CFEqual against current slots. **Trigger:** a
destroyed-window event race leaves a stale slot whose element CFEquals a recycled
window. **Symptom:** a genuinely new window is considered already-managed and not
re-adopted. **Severity: P2.**

### FAST-G6 (P2) — pidFilter / observer scope mismatch
**Where:** `fastAdopt` targets `pidFilter`-intersected pids
(`LifecycleMonitor.swift:406`) and the observer's `pidFilter`
(`:63, 97`). **Trigger:** a filter/observer scope drift in non-sandbox runs.
**Symptom:** events for an in-scope app dropped. **Severity: P2** (mostly a test-
mode concern).

## Master-table rows
| ID | Title | Gate / file:line | Trigger | Symptom | Sev | Repro |
|---|---|---|---|---|---|---|
| FAST-G1 | Bounded retries lapse to a freezable poll | `LifecycleMonitor.swift:442-453` | WindowServer publish lags beyond retry budget under burst | window floats until a healthy resync | P1 | extend SpawnLatencyTest with publish lag + frozen poll |
| FAST-G2 | `enumerating` coalesce loses burst coverage | `LifecycleMonitor.swift:197` | many created events during one enumeration | some new windows skipped | P1 | reentrancy churn test |
| FAST-G3 | New process not observed until registration | `WindowEventObserver.swift` | launching a brand-new PID (each `open -na` Ghostty) | first window misses fast path | P1 | NewWindowAdoptTest with fresh PID |
| FAST-G4 | `stripIsOnCurrentSpace` bail mid-burst | `LifecycleMonitor.swift:458` | managed columns transiently off current-Space (GATE-C/B) | new windows deferred | P2 | shares GATE-F1 repro |
| FAST-G5 | Stale destroyed-slot blocks re-adoption | `LifecycleMonitor.swift:419` | destroy-event race, recycled element | new window seen as already-managed | P2 | code trace |
| FAST-G6 | pidFilter/observer scope drift | `LifecycleMonitor.swift:406,63,97` | filter/observer mismatch | in-scope events dropped | P2 | code trace |
