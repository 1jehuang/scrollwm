import Foundation
import ApplicationServices
import AppKit

/// Keeps the strip in sync with reality: adopts newly created windows,
/// drops closed ones, reacts to app launch/termination.
///
/// Strategy (validated by `watch`: full resync ~9ms p50):
///   - AX `kAXWindowCreated` observer (see `WindowEventObserver`) -> near
///     instant resync when a window opens in any app, so it is adopted before
///     the user perceives a misplacement (this is the fast path)
///   - NSWorkspace launch/terminate notifications -> resync on app changes
///   - periodic reconciliation every `interval` seconds as the safety net
///     (AX notifications can be missed; polling cannot)
/// Identity: AXUIElement supports CFEqual for the same underlying window.
final class LifecycleMonitor {
    private let engine: TeleportEngine
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var windowEvents: WindowEventObserver?
    private let interval: TimeInterval

    /// Restrict adoption to these PIDs (test mode). Nil = all regular apps.
    var pidFilter: Set<pid_t>? {
        didSet { windowEvents?.pidFilter = pidFilter }
    }

    private(set) var adoptedCount = 0
    private(set) var removedCount = 0
    private(set) var resyncCount = 0
    private(set) var lastResyncMs: Double = 0

    var onChange: ((_ adopted: Int, _ removed: Int) -> Void)?

    init(engine: TeleportEngine, interval: TimeInterval = 2.0) {
        self.engine = engine
        self.interval = interval
    }

    func start() {
        // Fast path: react to window-created events almost immediately.
        let events = WindowEventObserver { [weak self] in self?.resync() }
        events.pidFilter = pidFilter
        events.start()
        windowEvents = events

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Slight delay: a launching app needs a beat before AX sees windows.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.resync()
                }
            })
        }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.resync()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        windowEvents?.stop()
        windowEvents = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers.removeAll()
    }

    /// True when the user session is active and unlocked. While locked,
    /// AX queries fail with attributeUnsupported (-25205) for everything;
    /// trusting them would mass-remove the strip and clobber restore data.
    static func sessionIsActive() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        let locked = (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
        let onConsole = (dict[kCGSessionOnConsoleKey as String] as? Bool) ?? true
        return !locked && onConsole
    }

    /// Diff current AX reality against the strip.
    ///
    /// Space-aware (see `ResyncPlanner`): adoption is scoped to windows on the
    /// Space the user is currently viewing, exactly like `arrange`. While the
    /// user is on a different Space than the strip, this is inert, so native
    /// Space switching never pulls foreign windows into the strip or teleports
    /// the user around.
    func resync() {
        let start = Clock.nowAbsNs()

        // Guard 1: never resync while the session is locked/inactive.
        guard Self.sessionIsActive() else { return }
        resyncCount += 1

        // Enumerate current standard windows (AX spans ALL Spaces).
        let current: [AXWindowInfo]
        if let pids = pidFilter {
            current = pids.flatMap { pid -> [AXWindowInfo] in
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return [] }
                return AXSource.windows(for: app)
            }
        } else {
            current = AXSource.allWindows()
        }
        let standard = current.filter {
            $0.subrole == kAXStandardWindowSubrole as String && !$0.isMinimized && !$0.isFullscreen
        }

        // Determine which standard windows are on the CURRENT Space. The
        // WindowServer's on-screen list only contains current-Space windows;
        // fuse it with AX exactly as `arrange` does (PID+frame+title scoring).
        // A window we manage that sits on another Space still appears in `ax`
        // but NOT here, which is precisely what drives the Space-freeze rule.
        let cg = CGWindowSource.listWindows(onscreenOnly: true)
        let matched = IdentityMatcher.match(axWindows: standard, cgWindows: cg)

        // Map each window to an opaque token (= index into `standard`) so the
        // pure planner can reason without touching AXUIElements.
        let axIDs = Array(standard.indices)
        var currentSpaceIDs = Set<Int>()
        for (i, m) in matched.enumerated() where m.cg != nil { currentSpaceIDs.insert(i) }

        // Strip tokens: managed windows that AX still reports map to their
        // `standard` index; genuinely-closed ones get a negative sentinel that
        // is never in `axIDs`/`currentSpaceIDs` (so they read as removed).
        let stripIDs: [Int] = engine.slots.enumerated().map { (s, slot) in
            standard.firstIndex { CFEqual($0.element, slot.window.element) } ?? -(s + 1)
        }

        let decision = ResyncPlanner.decide(
            stripIDs: stripIDs,
            axIDs: axIDs,
            currentSpaceIDs: currentSpaceIDs
        )
        let addTokens: [Int]
        switch decision {
        case .frozenDifferentSpace, .skipDegraded:
            // Strip belongs to another Space, or AX looks degraded: stay inert.
            return
        case .apply(_, let add):
            addTokens = add
        }

        // Removals: strip windows whose AX element no longer exists among
        // current standard windows. CFEqual matches AXUIElements of the same
        // underlying window, so a closed window simply stops matching. Windows
        // merely on another Space still exist in AX, so they are NOT removed.
        let removed = engine.removeSlots { slot in
            !standard.contains { CFEqual($0.element, slot.window.element) }
        }

        // Additions: new windows ON THE CURRENT SPACE (per the planner). Insert
        // each immediately to the RIGHT of the focused column (PaperWM/niri
        // style) and focus the newest so the viewport follows the window the
        // user just opened. Cross-Space windows are intentionally skipped.
        let newWindows = addTokens.map { standard[$0] }
        var lastInsertedIndex: Int?
        if !newWindows.isEmpty {
            // Insertion point sits just after the current focus. Inserting at
            // focusIndex+1 never shifts the focused window's own index, so the
            // anchor stays valid as we insert successive new windows in order.
            var insertAt = engine.slots.isEmpty ? 0 : engine.focusIndex + 1
            for info in newWindows {
                engine.insert(window: info, at: insertAt)
                lastInsertedIndex = insertAt
                insertAt += 1
            }
        }

        adoptedCount += newWindows.count
        removedCount += removed
        lastResyncMs = Double(Clock.nowAbsNs() &- start) / 1e6

        if removed > 0 || !newWindows.isEmpty {
            engine.compactStrip()
            if let lastInsertedIndex {
                // Focus + scroll the viewport to reveal the newly opened window.
                engine.focus(index: lastInsertedIndex)
            } else {
                engine.teleport()
            }
            onChange?(newWindows.count, removed)
        }
    }

}

// MARK: - TeleportEngine lifecycle extensions

extension TeleportEngine {
    /// Insert a newly discovered window into the strip at array index `at`
    /// (clamped into range). `canvasX` here is provisional; callers re-pack
    /// with `compactStrip()` so the only thing that matters for ordering is
    /// the array position.
    func insert(window info: AXWindowInfo, at index: Int) {
        AXSource.setTimeout(info.element, seconds: 0.08)
        let gap: CGFloat = 12
        let width = min(info.frame.width, screenFrame.width - gap * 2)
        let height = min(info.frame.height, screenFrame.height)
        let slot = Slot(
            window: ManagedWindowRef(
                element: info.element,
                pid: info.pid,
                appName: info.appName,
                title: info.title ?? "(untitled)",
                originalFrame: info.frame
            ),
            canvasX: 0,
            width: width,
            y: screenFrame.origin.y,
            height: height
        )
        let clamped = max(0, min(index, slots.count))
        slots.insert(slot, at: clamped)
        onLayoutChange?()
    }

    /// Append a newly discovered window to the right end of the strip.
    func append(window info: AXWindowInfo) {
        insert(window: info, at: slots.count)
    }

    /// Remove slots matching the predicate. Returns count removed.
    /// Keeps focus on the same window when possible.
    func removeSlots(where predicate: (Slot) -> Bool) -> Int {
        guard !slots.isEmpty else { return 0 }
        let focusedWindow = slots.indices.contains(focusIndex) ? slots[focusIndex].window : nil
        let before = slots.count
        slots.removeAll(where: predicate)
        let removed = before - slots.count
        if removed > 0 {
            if let fw = focusedWindow,
               let newIndex = slots.firstIndex(where: { $0.window === fw }) {
                focusIndex = newIndex
            } else {
                focusIndex = max(0, min(focusIndex, slots.count - 1))
            }
            onLayoutChange?()
        }
        return removed
    }

    /// Re-pack columns left-to-right, removing gaps left by closed windows.
    /// Opens with a `gap` leading margin (symmetric with the trailing margin).
    func compactStrip() {
        let gap: CGFloat = 12
        var x: CGFloat = gap
        for i in slots.indices {
            slots[i].canvasX = x
            x += slots[i].width + gap
        }
    }
}
