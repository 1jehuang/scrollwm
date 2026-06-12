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

    /// Diff current AX reality against the strip.
    func resync() {
        let start = Clock.nowAbsNs()
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

        // Removals: strip windows whose AX element no longer exists among
        // current standard windows. CFEqual matches AXUIElements of the same
        // underlying window, so a closed window simply stops matching.
        let removed = engine.removeSlots { slot in
            !standard.contains { CFEqual($0.element, slot.window.element) }
        }

        // Additions: AX windows not yet in the strip.
        let newWindows = standard.filter { info in
            !engine.slots.contains { CFEqual(info.element, $0.window.element) }
        }
        for info in newWindows {
            engine.append(window: info)
        }

        adoptedCount += newWindows.count
        removedCount += removed
        lastResyncMs = Double(Clock.nowAbsNs() &- start) / 1e6

        if removed > 0 || !newWindows.isEmpty {
            engine.compactStrip()
            engine.teleport()
            onChange?(newWindows.count, removed)
        }
    }

}

// MARK: - TeleportEngine lifecycle extensions

extension TeleportEngine {
    /// Append a newly discovered window to the right end of the strip.
    func append(window info: AXWindowInfo) {
        AXSource.setTimeout(info.element, seconds: 0.08)
        let lastEdge = slots.map { $0.canvasX + $0.width }.max() ?? 0
        let gap: CGFloat = 12
        let width = min(info.frame.width, screenFrame.width - gap * 2)
        let height = min(info.frame.height, screenFrame.height)
        slots.append(Slot(
            window: ManagedWindowRef(
                element: info.element,
                pid: info.pid,
                appName: info.appName,
                title: info.title ?? "(untitled)",
                originalFrame: info.frame
            ),
            canvasX: slots.isEmpty ? 0 : lastEdge + gap,
            width: width,
            y: screenFrame.origin.y,
            height: height
        ))
        onLayoutChange?()
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
