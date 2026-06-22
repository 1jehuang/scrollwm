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
    private var workspaceObservers: [NSObjectProtocol] = []
    private let onWindowCreated: () -> Void
    private var coalesceScheduled = false

    /// Small delay before reacting, so the WindowServer has a beat to register
    /// the new window as on-screen (the current-Space check reads the on-screen
    /// list). Also coalesces the burst of notifications a single new window
    /// emits into one resync.
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

    init(coalesceDelay: TimeInterval = 0.06, onWindowCreated: @escaping () -> Void) {
        self.coalesceDelay = coalesceDelay
        self.onWindowCreated = onWindowCreated
    }

    func start() {
        started = true
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
            // A launching app needs a beat before its AX element is ready.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.register(app: app)
            }
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
        for (_, obs) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        observers.removeAll()
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
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<WindowEventObserver>.fromOpaque(refcon).takeUnretainedValue()
            me.scheduleCoalescedResync()
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Window created is the signal that matters for fast adoption.
        AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func unregister(pid: pid_t) {
        guard let obs = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
    }

    // MARK: - Coalescing

    /// Coalesce the burst of notifications a single new window emits into one
    /// resync, slightly delayed so the WindowServer can mark it on-screen.
    private func scheduleCoalescedResync() {
        if coalesceScheduled { return }
        coalesceScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceDelay) { [weak self] in
            guard let self else { return }
            self.coalesceScheduled = false
            self.onWindowCreated()
        }
    }
}
