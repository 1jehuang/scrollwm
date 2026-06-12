import Foundation
import Carbon
import AppKit

/// Carbon global hotkeys. These require NO TCC permission, which is what
/// makes the teleport tier Accessibility-only.
final class HotkeyManager {
    typealias Handler = () -> Void

    private var handlers: [UInt32: Handler] = [:]
    private var hotkeyRefs: [EventHotKeyRef?] = []
    private var eventHandlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// Carbon modifier masks.
    static let ctrlOpt: UInt32 = UInt32(controlKey | optionKey)

    /// Virtual key codes (ANSI layout).
    enum Key: UInt32 {
        case left = 123, right = 124, down = 125, up = 126
        case one = 18, two = 19, three = 20, four = 21, five = 23
        case six = 22, seven = 26, eight = 28, nine = 25
        case escape = 53

        static let digits: [Key] = [.one, .two, .three, .four, .five, .six, .seven, .eight, .nine]
    }

    func install() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                manager.handlers[hotKeyID.id]?()
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    func register(_ key: Key, modifiers: UInt32 = HotkeyManager.ctrlOpt, handler: @escaping Handler) {
        let id = nextID
        nextID += 1
        handlers[id] = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x53574D31), id: id) // 'SWM1'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            key.rawValue, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr {
            hotkeyRefs.append(ref)
        } else {
            print("warning: hotkey registration failed for key \(key) (status \(status))")
        }
    }

    func unregisterAll() {
        for ref in hotkeyRefs { if let ref { UnregisterEventHotKey(ref) } }
        hotkeyRefs.removeAll()
        handlers.removeAll()
    }
}
