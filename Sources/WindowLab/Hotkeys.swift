import Foundation
import Carbon
import AppKit

/// Carbon global hotkeys. These require NO TCC permission, which is what
/// keeps ScrollWM Accessibility-only.
final class HotkeyManager {
    typealias Handler = () -> Void

    private var handlers: [UInt32: Handler] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    /// (keyCode, carbonModifiers) -> handler, so the headless test harness can
    /// deliver a synthetic Carbon hotkey without RegisterEventHotKey delivery
    /// (which would require a real keypress reaching the focused app).
    private var byChord: [UInt64: Handler] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// Carbon modifier masks.
    static let ctrlOpt: UInt32 = UInt32(controlKey | optionKey)
    static let opt: UInt32 = UInt32(optionKey)
    static let cmd: UInt32 = UInt32(cmdKey)

    /// Virtual key codes (ANSI layout).
    enum Key: UInt32 {
        case left = 123, right = 124, down = 125, up = 126
        case one = 18, two = 19, three = 20, four = 21, five = 23
        case six = 22, seven = 26, eight = 28, nine = 25
        case escape = 53
        case h = 4, l = 37, q = 12

        static let digits: [Key] = [.one, .two, .three, .four, .five, .six, .seven, .eight, .nine]

        /// Keycode as Int64, for CGEvent keycode comparisons.
        var rawValueInt64: Int64 { Int64(rawValue) }
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

    /// Register a global hotkey. Returns the assigned id (for later
    /// `unregister`), or nil if Carbon refused the registration.
    @discardableResult
    func register(_ key: Key, modifiers: UInt32 = HotkeyManager.ctrlOpt, handler: @escaping Handler) -> UInt32? {
        registerRaw(keyCode: key.rawValue, modifiers: modifiers, handler: handler)
    }

    /// Register a global hotkey by raw virtual keycode (config-driven chords).
    /// Returns the assigned id, or nil if Carbon refused the registration
    /// (e.g. a chord macOS reserves, like Cmd+H).
    @discardableResult
    func registerRaw(keyCode: UInt32, modifiers: UInt32, handler: @escaping Handler) -> UInt32? {
        let id = nextID
        nextID += 1

        // Headless test mode: do NOT register a REAL global Carbon hotkey (it
        // would grab the user's actual Ctrl+Opt+Arrow / jump chords system-wide
        // while a test runs). Record the binding so `debugDeliver` can exercise
        // it; skip the live registration entirely.
        if AXSource.backend != nil {
            handlers[id] = handler
            byChord[Self.chordKey(keyCode: keyCode, modifiers: modifiers)] = handler
            return id
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x53574D31), id: id) // 'SWM1'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref {
            handlers[id] = handler
            refs[id] = ref
            byChord[Self.chordKey(keyCode: keyCode, modifiers: modifiers)] = handler
            return id
        } else {
            print("warning: hotkey registration failed for keyCode \(keyCode) mods \(modifiers) (status \(status))")
            return nil
        }
    }

    /// Pack a (keyCode, carbonModifiers) pair into one lookup key.
    private static func chordKey(keyCode: UInt32, modifiers: UInt32) -> UInt64 {
        (UInt64(keyCode) << 32) | UInt64(modifiers)
    }

    /// Headless test seam: invoke the handler registered for a Carbon chord
    /// directly, modeling delivery without a real keypress (which would reach the
    /// user's focused app). Returns true if a handler was registered.
    @discardableResult
    func debugDeliver(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard let handler = byChord[Self.chordKey(keyCode: keyCode, modifiers: modifiers)] else { return false }
        handler()
        return true
    }

    /// Unregister a specific set of previously registered hotkeys.
    func unregister(ids: [UInt32]) {
        for id in ids {
            if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
            handlers.removeValue(forKey: id)
        }
    }

    func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
        byChord.removeAll()
    }
}
