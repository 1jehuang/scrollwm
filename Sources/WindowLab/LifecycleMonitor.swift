import Foundation
import ApplicationServices
import AppKit

/// Keeps the strip in sync with reality: adopts newly created windows,
/// drops closed ones, reacts to app launch/termination.
///
/// Strategy (validated by `watch`: full resync ~9ms p50):
///   - NSWorkspace launch/terminate notifications -> immediate resync
///   - periodic reconciliation every `interval` seconds as the safety net
///     (AX notifications can be missed; polling cannot)
/// Identity: AXUIElement supports CFEqual for the same underlying window.
final class LifecycleMonitor {
    private let engine: TeleportEngine
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let interval: TimeInterval

    /// Restrict adoption to these PIDs (test mode). Nil = all regular apps.
    var pidFilter: Set<pid_t>?

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
    func resync() {
        let start = Clock.nowAbsNs()

        // Guard 1: never resync while the session is locked/inactive.
        guard Self.sessionIsActive() else { return }
        resyncCount += 1

        // Enumerate current standard windows.
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

        // Guard 2: mass-removal protection. If AX suddenly reports most of
        // the strip gone (>50% of 4+ windows), that is far more likely AX
        // degradation (lock screen edge, login transition, WindowServer
        // hiccup) than the user really closing everything at once. Skip and
        // let a later healthy resync converge.
        let matchedCount = engine.slots.filter { slot in
            standard.contains { CFEqual($0.element, slot.window.element) }
        }.count
        let missingCount = engine.slots.count - matchedCount
        if engine.slots.count >= 4 && missingCount * 2 > engine.slots.count {
            return
        }

        // Removals: strip windows whose AX element no longer exists among
        // current standard windows. CFEqual matches AXUIElements of the same
        // underlying window, so a closed window simply stops matching.
        let removed = engine.removeSlots { slot in
            !standard.contains { CFEqual($0.element, slot.window.element) }
        }

        // Additions: AX windows not yet in the strip. Insert each one
        // immediately to the RIGHT of the focused column (PaperWM/niri-style)
        // rather than at the far right end of the strip, and focus the newest
        // so the viewport follows the window the user just opened.
        let newWindows = standard.filter { info in
            !engine.slots.contains { CFEqual(info.element, $0.window.element) }
        }
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
    func compactStrip() {
        let gap: CGFloat = 12
        var x: CGFloat = 0
        for i in slots.indices {
            slots[i].canvasX = x
            x += slots[i].width + gap
        }
    }
}
