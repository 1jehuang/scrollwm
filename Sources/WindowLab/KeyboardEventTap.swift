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
    /// One key combo: a virtual keycode plus an exact modifier match, and the
    /// action to run on the main thread when it fires.
    struct Combo {
        let keyCode: Int64
        let handler: () -> Void
    }

    private var combos: [Combo] = []
    private var tapPort: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    private(set) var captured = 0
    private(set) var disableCount = 0

    /// Add a combo that fires when `keyCode` is pressed with Command held and
    /// no other modifiers (control/option/shift). Call before `start()`.
    func addCommandCombo(keyCode: Int64, handler: @escaping () -> Void) {
        combos.append(Combo(keyCode: keyCode, handler: handler))
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

        let f = event.flags
        // Exactly Command (ignore the always-present non-coalesced bits).
        let onlyCommand = f.contains(.maskCommand)
            && !f.contains(.maskControl)
            && !f.contains(.maskAlternate)
            && !f.contains(.maskShift)
        guard onlyCommand else { return Unmanaged.passUnretained(event) }

        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if let combo = combos.first(where: { $0.keyCode == key }) {
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
