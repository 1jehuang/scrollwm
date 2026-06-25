import Foundation
import CoreGraphics
import AppKit

/// A window as seen by the WindowServer via CGWindowList.
struct CGWindowInfo {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let title: String?
    let bounds: CGRect // CG global coordinates (top-left origin)
    let layer: Int
    let alpha: Double
    let isOnscreen: Bool
    let memoryUsage: Int64

    /// Heuristic: is this a normal app window we would manage?
    var looksManageable: Bool {
        layer == 0
            && alpha > 0.05
            && bounds.width >= 64
            && bounds.height >= 64
    }
}

enum CGWindowSource {
    /// Enumerate windows from the WindowServer.
    /// `onscreenOnly` maps to kCGWindowListOptionOnScreenOnly.
    static func listWindows(onscreenOnly: Bool = true) -> [CGWindowInfo] {
        // Headless test backend: answer from the in-memory sim world so the
        // current-Space / identity-fusion logic runs with zero WindowServer access.
        if let backend = AXSource.backend { return backend.cgWindows(onscreenOnly: onscreenOnly) }

        var options: CGWindowListOption = [.excludeDesktopElements]
        if onscreenOnly { options.insert(.optionOnScreenOnly) }

        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return raw.compactMap { dict in
            guard
                let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
                let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
                let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            return CGWindowInfo(
                windowID: windowID,
                ownerPID: pid,
                ownerName: dict[kCGWindowOwnerName as String] as? String ?? "?",
                title: dict[kCGWindowName as String] as? String,
                bounds: bounds,
                layer: dict[kCGWindowLayer as String] as? Int ?? 0,
                alpha: dict[kCGWindowAlpha as String] as? Double ?? 1.0,
                isOnscreen: dict[kCGWindowIsOnscreen as String] as? Bool ?? onscreenOnly,
                memoryUsage: dict[kCGWindowMemoryUsage as String] as? Int64 ?? 0
            )
        }
    }
}
