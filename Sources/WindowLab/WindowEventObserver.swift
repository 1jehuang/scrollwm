import Foundation
import ApplicationServices
import AppKit

/// Watches regular apps for the Accessibility "window created" event so the
/// strip can adopt a new window in ~tens of milliseconds instead of waiting for
/// the periodic poll.
///
/// ## Why this exists (the new-window latency bug)
///
/// `LifecycleMonitor` originally learned about new windows two ways:
///   - `NSWorkspace.didLaunchApplication` — but that only fires when a brand
///     new *app* launches, NOT when an already-running app opens another
///     window (the common case), and
///   - a 2-second polling timer.
///
/// So opening a window in a running app could sit at its native position for up
/// to ~2s before the poll noticed it, then visibly snap into the strip. That is
/// the "latency" and "incorrect movement that gets corrected" the strip showed.
///
/// This observer closes that gap: one `AXObserver` per app, registered on the
/// application element for `kAXWindowCreatedNotification`. When a window is
/// created the callback fires almost immediately and we trigger a fast resync,
/// so adoption happens before the user perceives a misplacement. The poll
/// remains as a safety net for missed events and removals.
final class WindowEventObserver {
    /// One AXObserver per observed app PID.
    private var observers: [pid_t: AXObserver] = [:]
    /// The notifications each observed pid still needs ATTACHED. Populated in
    /// `register(app:)` and drained by `attachNotifications` as each
    /// `AXObserverAddNotification` succeeds; a transiently-failed attach (the
    /// app's AX server not ready the instant it launched) stays here and is
    /// retried with a bounded backoff. Empty / absent = fully attached. Keeping
    /// it per-pid means a retry only re-adds the MISSING notifications, never
    /// double-registering one that already took.
    private var pendingNotes: [pid_t: [String]] = [:]
    /// The notifications we attach to every observed app element: a created
    /// window (warm fast-adopt) and any element teardown (fast removal).
    private static let observedNotifications: [String] = [
        kAXWindowCreatedNotification as String,
        kAXUIElementDestroyedNotification as String,
    ]
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Called with the PIDs that fired a window-created event since the last
    /// delivery, IN FIRE ORDER (deduped), so the monitor can do a SCOPED
    /// adoption (enumerate only those apps) instead of a full all-apps sweep.
    /// Order matters: when several windows open inside one coalesce window (an
    /// app launching with multiple windows, a session restore), they must be
    /// adopted in the order they were created so they land as a contiguous,
    /// in-order run right of the focus with the newest focused. A `Set` here
    /// scrambled that order, landing a burst out of sequence and focusing the
    /// wrong window.
    private let onWindowCreated: ([pid_t]) -> Void
    /// Called (coalesced) when a UI element was destroyed, so the monitor can
    /// reconcile removals promptly instead of waiting for the poll.
    private let onWindowDestroyed: () -> Void
    /// Called the instant a brand-NEW app (process) launches, BEFORE its
    /// `kAXWindowCreated` observer could ever have been attached. This is the
    /// cold-start fast path: a new process's first window never fires our
    /// per-app create observer (it does not exist yet at window-creation time),
    /// so without this the first window waited for the slow launch-resync / poll.
    /// The monitor responds by kicking off a bounded progressive fast-adopt for
    /// that pid, landing the first window as fast as a warm one.
    private let onAppLaunched: (pid_t) -> Void
    private var coalesceScheduled = false
    private var destroyScheduled = false
    /// Firing PIDs accumulated for the next coalesced delivery, kept in fire
    /// order with duplicates collapsed (window counts per burst are tiny, so a
    /// linear de-dup is cheaper than the ordering bugs a Set caused).
    private var pendingPIDs: [pid_t] = []

    /// Small delay before reacting. Its ONLY remaining job is to coalesce the
    /// burst of notifications a single new window (or a multi-window restore)
    /// emits within the same runloop turn into one adoption pass.
    ///
    /// It deliberately does NOT wait for the WindowServer to publish the window
    /// on-screen: that race is now owned end-to-end by `LifecycleMonitor`'s
    /// bounded fast-adopt retry, which re-checks every few ms until the window
    /// is listed. So this delay is kept tiny (a fraction of a frame) to shave
    /// the always-paid latency off the visible "spawn floating, then snap into
    /// the strip" gap, instead of the old 35ms (~2 frames) flat wait.
    private let coalesceDelay: TimeInterval

    /// Restrict to these PIDs (test mode). Nil = all regular apps. Setting this
    /// re-scans so the targeted pids are observed even if they are accessory
    /// processes (which never appear in the regular-app scan or post launch
    /// notifications).
    var pidFilter: Set<pid_t>? {
        didSet {
            guard started else { return }
            DispatchQueue.main.async { [weak self] in self?.registerTargets() }
        }
    }

    private var started = false

    init(coalesceDelay: TimeInterval = 0.008,
         onWindowCreated: @escaping ([pid_t]) -> Void,
         onWindowDestroyed: @escaping () -> Void,
         onAppLaunched: @escaping (pid_t) -> Void = { _ in }) {
        self.coalesceDelay = coalesceDelay
        self.onWindowCreated = onWindowCreated
        self.onWindowDestroyed = onWindowDestroyed
        self.onAppLaunched = onAppLaunched
    }

    func start() {
        started = true

        // Headless backend: there are no real AXObservers/NSWorkspace apps to
        // watch. Subscribe to the sim world's create/destroy events instead, so
        // the fast-adopt / fast-remove paths still run end-to-end. We route a
        // created event through the SAME coalescing + pid-filter logic as the
        // real path.
        if let sim = AXSource.backend as? SimWindowWorld {
            sim.subscribeEvents(
                created: { [weak self] pids in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        // Preserve the sim's fire order; only drop pids outside
                        // an explicit filter (test/sandbox mode). The sim fires
                        // one pid per created window, so each delivery is already
                        // ordered; we just intersect with the filter when set.
                        let allowed = self.pidFilter.map { f in pids.filter { f.contains($0) } } ?? Array(pids)
                        for pid in allowed { self.windowCreated(pid: pid) }
                    }
                },
                destroyed: { [weak self] in
                    DispatchQueue.main.async { self?.windowMaybeDestroyed() }
                },
                launched: { [weak self] pid in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        // The cold-start launch stand-in: a brand-new process's
                        // FIRST window never fired a per-app create observer
                        // (none was attached yet), exactly like real macOS. Route
                        // it through the launch fast path, honoring an explicit
                        // pid filter (sandbox/test mode).
                        if let f = self.pidFilter, !f.contains(pid) { return }
                        self.onAppLaunched(pid)
                    }
                }
            )
            return
        }

        registerTargets()

        // Apps that launch later need their own observer; apps that quit should
        // have theirs torn down. (Only fires for regular apps; the filtered
        // test path registers its pids eagerly via `pidFilter`'s didSet.)
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            if let f = self.pidFilter, !f.contains(pid) { return }
            // COLD-START FAST PATH. A brand-new app's very FIRST window is created
            // before we could ever attach its `kAXWindowCreated` observer, so that
            // first window never fires the warm create path - it used to wait for
            // the slow launch-resync / 2s poll (the visible "new app floats, then
            // snaps in late"). Two fixes here:
            //  1. Register the AX observer IMMEDIATELY (not after a flat 0.4s), so
            //     any SUBSEQUENT window of this app rides the warm fast path. The
            //     app element exists the instant the process is running; adding a
            //     notification to a not-yet-ready element simply no-ops and the
            //     re-register below (when its first window adopts) covers it.
            //  2. Drive a bounded progressive fast-adopt for this pid right now,
            //     which polls AX every few ms until the first window is published
            //     and adopts it - landing a cold-start window as fast as a warm
            //     one instead of paying the launch-resync latency.
            self.register(app: app)
            self.onAppLaunched(pid)
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.unregister(pid: app.processIdentifier)
        })
    }

    func stop() {
        started = false
        (AXSource.backend as? SimWindowWorld)?.unsubscribeEvents()
        for (_, obs) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        observers.removeAll()
        pendingNotes.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        for o in workspaceObservers { center.removeObserver(o) }
        workspaceObservers.removeAll()
    }

    // MARK: - Registration

    /// Register observers for the current target set: the explicit pid filter if
    /// present (test mode, any activation policy), otherwise all regular apps.
    private func registerTargets() {
        if let pids = pidFilter {
            for pid in pids {
                guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
                register(app: app)
            }
        } else {
            let apps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && !$0.isTerminated
            }
            for app in apps { register(app: app) }
        }
    }

    private func register(app: NSRunningApplication) {
        let pid = app.processIdentifier
        if let pids = pidFilter, !pids.contains(pid) { return }
        guard pid > 0, !app.isTerminated, observers[pid] == nil else { return }

        var observer: AXObserver?
        // The refcon carries a per-PID box so the C callback knows which app
        // fired without enumerating anything.
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let box = Unmanaged<FireBox>.fromOpaque(refcon).takeUnretainedValue()
            box.owner?.eventFired(pid: box.pid, notification: notification as String)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let box = FireBox(owner: self, pid: pid)
        fireBoxes[pid] = box
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
        // Every notification still needs attaching. `attachNotifications` adds
        // the ones that take and leaves any that transiently fail in
        // `pendingNotes` for a bounded retry (see below).
        pendingNotes[pid] = Self.observedNotifications
        attachNotifications(pid: pid, attempt: 0)
    }

    /// Attach every still-pending notification for `pid`'s observer. Window
    /// created -> fast adoption; element destroyed (fired on the app element for
    /// a child window's teardown) -> fast removal, so a closed window's gap
    /// closes immediately instead of lingering until the poll.
    ///
    /// The robustness this adds: a brand-new process registers its observer the
    /// INSTANT it launches (so any SUBSEQUENT window rides the warm fast path),
    /// but at that instant the process's AX server may not be ready yet, so
    /// `AXObserverAddNotification` can fail (e.g. `cannotComplete`). The old code
    /// fired-and-forgot, recording the observer as if attached; the notification
    /// never took and the warm fast path was silently dead for that app. Here we
    /// only DROP a notification from `pendingNotes` once its add returns
    /// `.success` (or a terminal, non-retryable error), and re-schedule a bounded
    /// backoff for the rest. Re-entry is safe: an already-attached notification
    /// is never re-added because it was removed from `pendingNotes`.
    private func attachNotifications(pid: pid_t, attempt: Int) {
        guard let observer = observers[pid], let box = fireBoxes[pid] else { return }
        guard let pending = pendingNotes[pid], !pending.isEmpty else {
            pendingNotes[pid] = nil
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(box).toOpaque()
        var stillPending: [String] = []
        for note in pending {
            let err = AXObserverAddNotification(observer, appElement, note as CFString, refcon)
            if !ObserverRegistration.attachSucceeded(err) {
                // Retryable failure (the AX server is not ready yet): keep it so
                // the next attempt re-adds ONLY this notification.
                stillPending.append(note)
            }
        }
        if stillPending.isEmpty {
            pendingNotes[pid] = nil
            return
        }
        pendingNotes[pid] = stillPending
        // Bounded backoff: schedule the next retry if any budget remains. When
        // it lapses we simply give up the warm fast path for this app and rely
        // on the safety-net poll - never a leak or a hang.
        guard let delay = ObserverRegistration.retryDelay(forAttempt: attempt) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // The app may have quit (unregister cleared its observer) in the
            // meantime; `attachNotifications` no-ops safely if so.
            self.attachNotifications(pid: pid, attempt: attempt + 1)
        }
    }

    private func unregister(pid: pid_t) {
        pendingNotes[pid] = nil
        guard let obs = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        fireBoxes[pid] = nil
    }

    // MARK: - Coalescing

    /// Per-PID refcon box so the C callback can report which app fired.
    private final class FireBox {
        weak var owner: WindowEventObserver?
        let pid: pid_t
        init(owner: WindowEventObserver, pid: pid_t) { self.owner = owner; self.pid = pid }
    }
    private var fireBoxes: [pid_t: FireBox] = [:]

    /// Routed from the C callback (AXObserver runloop -> main). A created event
    /// drives scoped adoption; a destroyed event drives a (cheap, off-main)
    /// reconciliation so a closed window's gap closes immediately. Destroyed
    /// fires for ANY element teardown, so it is coalesced and only triggers the
    /// general resync (which no-ops when nothing actually changed).
    private func eventFired(pid: pid_t, notification: String) {
        // Already on the AXObserver's runloop source (main runloop here), but
        // hop explicitly to be safe about thread-confined state.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if notification == (kAXWindowCreatedNotification as String) {
                self.windowCreated(pid: pid)
            } else {
                self.windowMaybeDestroyed()
            }
        }
    }

    /// A window was created in `pid`. Record it (in fire order, de-duped) and
    /// schedule one coalesced delivery carrying every PID that fired in the
    /// window, in order, so a multi-window burst is adopted in sequence.
    private func windowCreated(pid: pid_t) {
        if !pendingPIDs.contains(pid) { pendingPIDs.append(pid) }
        if coalesceScheduled { return }
        coalesceScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceDelay) { [weak self] in
            guard let self else { return }
            self.coalesceScheduled = false
            let pids = self.pendingPIDs
            self.pendingPIDs.removeAll(keepingCapacity: true)
            self.onWindowCreated(pids)
        }
    }

    /// Something was destroyed; reconcile soon (coalesced). Drives the general
    /// resync, which removes any managed window AX no longer reports.
    private func windowMaybeDestroyed() {
        if destroyScheduled { return }
        destroyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceDelay) { [weak self] in
            guard let self else { return }
            self.destroyScheduled = false
            self.onWindowDestroyed()
        }
    }
}

/// PURE policy for the robust observer-attach retry (no AX, no AppKit), so the
/// cold-start "register the instant the process launches" decision is unit
/// testable without a live AX server. Two questions, both deterministic:
///   - did an `AXObserverAddNotification` actually TAKE? and
///   - if not, how long until the next bounded retry (nil = give up)?
enum ObserverRegistration {
    /// Backoff schedule (seconds) between attach attempts. Index `attempt` is the
    /// wait BEFORE attempt `attempt + 1`; running off the end means the budget is
    /// exhausted and we give up the warm fast path (the safety-net poll still
    /// adopts the app's windows). Tight at first because a just-launched process
    /// usually has its AX server ready within a frame or two, widening for a slow
    /// one; total budget ~1.0s, comfortably under the 2s poll so a stuck app
    /// never hangs registration.
    static let retryDelays: [TimeInterval] =
        [0.01, 0.02, 0.04, 0.08, 0.12, 0.18, 0.25, 0.3]

    /// The wait before the next attempt, or nil once the bounded budget is spent.
    /// `attempt` is the count of attach passes already made (0 = the immediate
    /// first attempt that just failed).
    static func retryDelay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 0, attempt < retryDelays.count else { return nil }
        return retryDelays[attempt]
    }

    /// Did the attach take? `.success` obviously did. A handful of errors are
    /// TERMINAL (retrying can never help): the notification is already
    /// registered (it took on a prior pass), or the element/observer is invalid
    /// (the app is gone) - treat those as "done, stop retrying" so we never spin.
    /// Everything else (notably `cannotComplete` / `failure` from an AX server
    /// that has not finished spinning up) is RETRYABLE.
    static func attachSucceeded(_ err: AXError) -> Bool {
        switch err {
        case .success,
             .notificationAlreadyRegistered,
             .invalidUIElement,
             .invalidUIElementObserver:
            return true
        default:
            return false
        }
    }
}
