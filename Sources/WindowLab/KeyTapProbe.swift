import Foundation
import CoreGraphics
import AppKit

/// Probe: can a keyboard CGEventTap capture Cmd+H / Cmd+L using only the
/// Accessibility permission this app already holds? Carbon RegisterEventHotKey
/// provably cannot (system reserves Cmd+H). If this tap receives the events,
/// it is the correct native mechanism for the move bindings.
///
/// Run with: `WindowLab keytapprobe [secs]`
func runKeyTapProbe(seconds: Int) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    final class Box { var cmdH = 0; var cmdL = 0; var port: CFMachPort? }
    let box = Box()
    let userInfo = Unmanaged.passUnretained(box).toOpaque()

    let mask = (1 << CGEventType.keyDown.rawValue)
    let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let box = Unmanaged<Box>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let p = box.port { CGEvent.tapEnable(tap: p, enable: true) }
                return nil
            }
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let f = event.flags
            let cmd = f.contains(.maskCommand)
            let onlyCmd = cmd && !f.contains(.maskControl) && !f.contains(.maskAlternate) && !f.contains(.maskShift)
            if onlyCmd && key == 4 { // h
                box.cmdH += 1
                print("  keytap: Cmd+H captured (count \(box.cmdH)) -> SUPPRESSED")
                return nil // swallow so TextEdit doesn't hide
            }
            if onlyCmd && key == 37 { // l
                box.cmdL += 1
                print("  keytap: Cmd+L captured (count \(box.cmdL)) -> SUPPRESSED")
                return nil
            }
            return Unmanaged.passUnretained(event)
        },
        userInfo: userInfo
    )

    guard let tap else {
        print("[keytapprobe] FAILED to create keyboard event tap (permission insufficient).")
        exit(1)
    }
    box.port = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("[keytapprobe] keyboard event tap created. Press Cmd+H / Cmd+L. Reporting in \(seconds)s.")

    DispatchQueue.global().async {
        Thread.sleep(forTimeInterval: TimeInterval(seconds))
        print("\n[keytapprobe] results: Cmd+H=\(box.cmdH)  Cmd+L=\(box.cmdL)")
        print(box.cmdH > 0 && box.cmdL > 0
              ? "[keytapprobe] PASS: event tap captures Cmd+H/L with Accessibility only."
              : "[keytapprobe] FAIL: combos not delivered to the tap.")
        exit(0)
    }
    app.run()
}
