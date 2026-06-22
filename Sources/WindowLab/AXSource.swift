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

/// Thin, timeout-protected wrapper over the AXUIElement C API.
enum AXSource {
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
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func copySize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    static func setPoint(_ element: AXUIElement, _ attribute: String, _ point: CGPoint) -> AXError {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return .failure }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    static func setSize(_ element: AXUIElement, _ attribute: String, _ size: CGSize) -> AXError {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return .failure }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    /// Set a boolean AX attribute (e.g. kAXMainAttribute / kAXFocusedAttribute).
    @discardableResult
    static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFBoolean)
    }

    /// Enumerate AX windows for one application.
    static func windows(for app: NSRunningApplication, timeoutSeconds: Float = 0.15) -> [AXWindowInfo] {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
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
                appName: app.localizedName ?? "pid \(pid)",
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
}
