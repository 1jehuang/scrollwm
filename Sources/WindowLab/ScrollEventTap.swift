import Foundation
import CoreGraphics

/// One normalized scroll input sample from the event tap.
struct ScrollSample {
    let deltaX: Double          // points
    let deltaY: Double          // points
    let eventTimestampNs: UInt64 // CGEvent timestamp (mach_absolute_time-based ns)
    let isMomentum: Bool
}

/// Mutex-protected SPSC queue. The critical section is a few instructions;
/// contention is one producer (event tap thread) and one consumer (render).
/// Good enough for the lab; production would use a lock-free ring buffer.
final class ScrollInputQueue: @unchecked Sendable {
    private var samples: [ScrollSample] = []
    private let lock = NSLock()

    func push(_ sample: ScrollSample) {
        lock.lock()
        samples.append(sample)
        lock.unlock()
    }

    func drain() -> [ScrollSample] {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return [] }
        let out = samples
        samples.removeAll(keepingCapacity: true)
        return out
    }
}

/// CGEventTap that intercepts scroll events while ctrl+option are held,
/// suppresses them, and forwards deltas to the input queue.
///
/// Runs on its own thread with its own run loop so a busy main thread can
/// never starve (and so the system never disables) the tap.
final class ScrollEventTap {
    private let queue: ScrollInputQueue
    private var tapPort: CFMachPort?
    private var thread: Thread?

    /// Statistics (read from any thread; written only by tap thread).
    private(set) var eventsCaptured: Int = 0
    private(set) var tapDisableCount: Int = 0

    init(queue: ScrollInputQueue) {
        self.queue = queue
    }

    /// Modifier chord that activates canvas panning.
    static let requiredFlags: CGEventFlags = [.maskControl, .maskAlternate]

    func start() -> Bool {
        var created = false
        let semaphore = DispatchSemaphore(value: 0)

        let thread = Thread { [weak self] in
            guard let self else { semaphore.signal(); return }

            let mask = (1 << CGEventType.scrollWheel.rawValue)
            let userInfo = Unmanaged.passUnretained(self).toOpaque()

            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let tap = Unmanaged<ScrollEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                    return tap.handle(type: type, event: event)
                },
                userInfo: userInfo
            )

            if let tap {
                self.tapPort = tap
                let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                created = true
                semaphore.signal()
                CFRunLoopRun()
            } else {
                semaphore.signal()
            }
        }
        thread.name = "scrollwm.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread

        semaphore.wait()
        return created
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables taps it considers slow or during secure input.
        // Re-enable immediately and count it; repeated disables are a red flag.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tapDisableCount += 1
            if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
            return nil
        }

        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

        // Only capture while the pan chord is held; pass everything else through.
        let flags = event.flags
        guard flags.contains(Self.requiredFlags) else {
            return Unmanaged.passUnretained(event)
        }

        let dy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let dx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0

        queue.push(ScrollSample(
            deltaX: dx,
            deltaY: dy,
            eventTimestampNs: event.timestamp,
            isMomentum: momentum
        ))
        eventsCaptured += 1

        // Suppress: the app under the cursor must not also scroll.
        return nil
    }

    func stop() {
        if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: false) }
    }
}
