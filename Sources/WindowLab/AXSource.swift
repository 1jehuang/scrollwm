import Foundation
import ApplicationServices
import AppKit

/// A window as seen through the Accessibility API.
struct AXWindowInfo {
    let pid: pid_t
    let appName: String
    let element: AXUIElement
    let title: String?
    let role: String?
    let subrole: String?
    let frame: CGRect // AX global coordinates (top-left origin)
    let isMinimized: Bool
    let isFullscreen: Bool
}

enum AXProbeError: Error, CustomStringConvertible {
    case notTrusted
    case axError(AXError, String)

    var description: String {
        switch self {
        case .notTrusted: return "process is not AX-trusted (grant Accessibility permission)"
        case .axError(let code, let context): return "AX error \(code.rawValue) (\(axErrorName(code))) during \(context)"
        }
    }
}

func axErrorName(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "unknown(\(e.rawValue))"
    }
}

/// A pluggable window backend. The DEFAULT is the real Accessibility/WindowServer
/// stack (every call below maps to a C API). Tests install an in-memory
/// `SimWindowWorld` so the EXACT production engine/controller logic can run fully
/// headless: no real windows are spawned, moved, focused, or closed, and no
/// global keystrokes are ever injected.
///
/// The seam is intentionally narrow: only the operations the engine actually
/// performs on windows. When `AXSource.backend == nil` (production), none of
/// these are consulted and behavior is byte-for-byte the legacy C-API path.
protocol WindowBackend: AnyObject {
    /// All windows belonging to `pid` (any state), mirroring `windows(for:)`.
    func windows(forPID pid: pid_t) -> [AXWindowInfo]
    /// Every window the backend knows about (mirrors `allWindows()`).
    func allWindows() -> [AXWindowInfo]
    /// The WindowServer on-screen list (current Space), mirrors `CGWindowSource`.
    func cgWindows(onscreenOnly: Bool) -> [CGWindowInfo]
    /// PIDs of "regular" apps (drives the unfiltered reveal/observe sweeps).
    func regularAppPIDs() -> [pid_t]

    func position(of element: AXUIElement) -> CGPoint?
    func size(of element: AXUIElement) -> CGSize?
    func setPosition(_ element: AXUIElement, _ point: CGPoint) -> AXError
    func setSize(_ element: AXUIElement, _ size: CGSize) -> AXError
    func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> AXError

    /// Raise a window above its app's others (records focus in the sim).
    func raise(_ element: AXUIElement) -> AXError
    /// Press a window's close button; true if it had one (sim destroys it).
    func pressCloseButton(_ element: AXUIElement) -> Bool
    /// The window that currently holds keyboard focus, system-wide.
    func systemFocusedWindow() -> AXUIElement?
    /// Bring an app forward (sim records focus only; never steals real focus).
    func activateApp(pid: pid_t)
    func appIsHidden(pid: pid_t) -> Bool
    func unhideApp(pid: pid_t) -> Bool

    /// The active native-Space id (read-only) for a given physical display,
    /// mirroring `SpaceProbe`'s live CGS query. `nil` display means "the main
    /// display" (the single-display / spans-displays case). Per-display ids
    /// matter under "Displays have separate Spaces", where each monitor shows its
    /// own Space independently. Headless backends answer from their modeled
    /// Spaces; a `nil` result means "no stable Space id available" (the caller
    /// then stays on the single-strip model).
    func currentSpaceID(forDisplay displayID: CGDirectDisplayID?) -> Int?
}

/// Thin, timeout-protected wrapper over the AXUIElement C API.
enum AXSource {
    /// When set, every window read/write below is routed to this in-memory
    /// backend instead of the live C API. Set ONLY by the headless test harness;
    /// always nil in production, so the live path is unchanged.
    static var backend: WindowBackend?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrustIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Per-element messaging timeout. Critical: a hung app must not hang us.
    static func setTimeout(_ element: AXUIElement, seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? T
    }

    static func copyPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        if let backend, attribute == kAXPositionAttribute as String { return backend.position(of: element) }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func copySize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        if let backend, attribute == kAXSizeAttribute as String { return backend.size(of: element) }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    static func setPoint(_ element: AXUIElement, _ attribute: String, _ point: CGPoint) -> AXError {
        if let backend, attribute == kAXPositionAttribute as String { return backend.setPosition(element, point) }
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return .failure }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    static func setSize(_ element: AXUIElement, _ attribute: String, _ size: CGSize) -> AXError {
        if let backend, attribute == kAXSizeAttribute as String { return backend.setSize(element, size) }
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return .failure }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    /// Set a boolean AX attribute (e.g. kAXMainAttribute / kAXFocusedAttribute).
    @discardableResult
    static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> AXError {
        if let backend { return backend.setBool(element, attribute, value) }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value as CFBoolean)
    }

    /// Enumerate AX windows for one application.
    static func windows(for app: NSRunningApplication, timeoutSeconds: Float = 0.15) -> [AXWindowInfo] {
        windows(forPID: app.processIdentifier, timeoutSeconds: timeoutSeconds)
    }

    /// Enumerate AX windows for one PID. Production resolves a live
    /// `NSRunningApplication`; the headless backend answers from its sim world,
    /// so an accessory/non-existent pid still yields its simulated windows.
    static func windows(forPID pid: pid_t, timeoutSeconds: Float = 0.15) -> [AXWindowInfo] {
        if let backend { return backend.windows(forPID: pid) }
        let appElement = AXUIElementCreateApplication(pid)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        return windowsFromAppElement(appElement, pid: pid, appName: appName, timeoutSeconds: timeoutSeconds)
    }

    private static func windowsFromAppElement(_ appElement: AXUIElement, pid: pid_t, appName: String, timeoutSeconds: Float) -> [AXWindowInfo] {
        setTimeout(appElement, seconds: timeoutSeconds)

        var windowsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard err == .success, let windowElements = windowsRef as? [AXUIElement] else { return [] }

        return windowElements.compactMap { window in
            setTimeout(window, seconds: timeoutSeconds)
            guard
                let position = copyPoint(window, kAXPositionAttribute as String),
                let size = copySize(window, kAXSizeAttribute as String)
            else { return nil }

            let minimized: Bool = (copyAttribute(window, kAXMinimizedAttribute as String) as NSNumber?)?.boolValue ?? false
            let fullscreen: Bool = (copyAttribute(window, "AXFullScreen") as NSNumber?)?.boolValue ?? false

            return AXWindowInfo(
                pid: pid,
                appName: appName,
                element: window,
                title: copyAttribute(window, kAXTitleAttribute as String) as String?,
                role: copyAttribute(window, kAXRoleAttribute as String) as String?,
                subrole: copyAttribute(window, kAXSubroleAttribute as String) as String?,
                frame: CGRect(origin: position, size: size),
                isMinimized: minimized,
                isFullscreen: fullscreen
            )
        }
    }

    /// All regular-app AX windows on the system, with per-app latency recording.
    static func allWindows(recorder: LatencyRecorder? = nil) -> [AXWindowInfo] {
        if let backend { return backend.allWindows() }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        var result: [AXWindowInfo] = []
        for app in apps {
            let start = Clock.nowNs()
            let wins = windows(for: app)
            let elapsed = Double(Clock.nowNs() - start) / 1_000_000.0
            recorder?.record("ax.enumerate.app", ms: elapsed)
            if elapsed > 50 {
                print(String(format: "  [slow] AX enumerate %@: %.1f ms (%d windows)",
                             app.localizedName ?? "?", elapsed, wins.count))
            }
            result.append(contentsOf: wins)
        }
        return result
    }

    // MARK: - High-level window actions (backend-routable)
    //
    // The engine/controller perform a few window ACTIONS beyond raw geometry:
    // raise, press-close-button, read system focus, and activate an app. These
    // wrappers route through the headless backend when installed (so the sim can
    // model focus + window destruction with zero real side effects) and fall
    // back to the exact prior C-API calls in production.

    /// Raise a window above its app's other windows.
    @discardableResult
    static func raise(_ element: AXUIElement) -> AXError {
        if let backend { return backend.raise(element) }
        return AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Press a window's AX close button. Returns true when a close button
    /// existed and the press succeeded.
    static func pressCloseButton(_ element: AXUIElement) -> Bool {
        if let backend { return backend.pressCloseButton(element) }
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &buttonRef) == .success,
              let buttonRef, CFGetTypeID(buttonRef) == AXUIElementGetTypeID() else { return false }
        let button = buttonRef as! AXUIElement
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// The AX window element that currently holds keyboard focus, system-wide,
    /// or nil if it cannot be resolved.
    static func systemFocusedWindow() -> AXUIElement? {
        if let backend { return backend.systemFocusedWindow() }
        let systemWide = AXUIElementCreateSystemWide()
        setTimeout(systemWide, seconds: 0.1)

        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let appRef, CFGetTypeID(appRef) == AXUIElementGetTypeID() else { return nil }
        let appElement = appRef as! AXUIElement
        setTimeout(appElement, seconds: 0.1)

        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRef, CFGetTypeID(winRef) == AXUIElementGetTypeID() else { return nil }
        return (winRef as! AXUIElement)
    }

    /// Bring an app forward so keyboard focus follows a raised window. In
    /// production this is a real `NSRunningApplication.activate()`; the headless
    /// backend records focus only and never steals the user's real focus.
    static func activateApp(pid: pid_t) {
        if let backend { backend.activateApp(pid: pid); return }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}
