import Foundation
import CoreGraphics
import AppKit

/// Keyboard CGEventTap for the move bindings (Cmd+H / Cmd+L).
///
/// Why a tap and not Carbon? `RegisterEventHotKey` cannot capture Cmd+H:
/// macOS reserves it as the system-wide "Hide" shortcut and never delivers it
/// to a Carbon hotkey. We proved this empirically (`WindowLab hotkeyprobe`:
/// Cmd+H/L delivered 0 presses) and proved the tap works with Accessibility
/// alone (`WindowLab keytapprobe`: captured + suppressed). So the move keys
/// ride a keyboard tap; width (Alt+1-4) and close (Cmd+Q) stay on Carbon,
/// which delivers them fine.
///
/// Runs on its own thread + run loop (like ScrollEventTap) so a busy main
/// thread can never starve the tap and trigger a system disable. Handlers are
/// dispatched to main, where all AX window mutation must happen.
///
/// Lifecycle: started on Arrange, stopped on Release. While dormant the tap
/// does not exist, so Cmd+H keeps its normal "Hide" behavior on the desktop.
final class KeyboardEventTap {
    /// One key combo: a virtual keycode plus an exact modifier set, and the
    /// action to run on the main thread when it fires.
    struct Combo {
        let keyCode: Int64
        let flags: CGEventFlags   // exact match among cmd/shift/ctrl/alt
        let handler: () -> Void
    }

    /// Modifiers we consider when matching (others, e.g. the always-present
    /// non-coalesced bit or fn, are ignored).
    static let relevantFlags: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]

    private var combos: [Combo] = []
    private var tapPort: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    private(set) var captured = 0
    private(set) var disableCount = 0

    /// Add a combo that fires when `keyCode` is pressed with exactly `flags`
    /// (among cmd/shift/ctrl/alt). Call before `start()`.
    func addCombo(keyCode: Int64, flags: CGEventFlags, handler: @escaping () -> Void) {
        combos.append(Combo(keyCode: keyCode, flags: flags, handler: handler))
    }

    func start() -> Bool {
        guard tapPort == nil else { return true }
        var created = false
        let semaphore = DispatchSemaphore(value: 0)

        let thread = Thread { [weak self] in
            guard let self else { semaphore.signal(); return }
            let mask = (1 << CGEventType.keyDown.rawValue)
            let userInfo = Unmanaged.passUnretained(self).toOpaque()

            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let tap = Unmanaged<KeyboardEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                    return tap.handle(type: type, event: event)
                },
                userInfo: userInfo
            )

            if let tap {
                self.tapPort = tap
                self.runLoop = CFRunLoopGetCurrent()
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
        thread.name = "scrollwm.keytap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread

        semaphore.wait()
        return created
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            disableCount += 1
            if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
            return nil
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let masked = event.flags.intersection(Self.relevantFlags)
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if let combo = combos.first(where: { $0.keyCode == key && $0.flags == masked }) {
            captured += 1
            DispatchQueue.main.async { combo.handler() }
            return nil // suppress: focused app must not also act on this combo
        }
        return Unmanaged.passUnretained(event)
    }

    func stop() {
        if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: false) }
        // Stop the tap thread's run loop so CFRunLoopRun() returns and the
        // thread exits cleanly instead of spinning forever.
        if let runLoop { CFRunLoopStop(runLoop) }
        tapPort = nil
        runLoop = nil
        thread = nil
        combos.removeAll()
    }
}
