import Foundation
import ApplicationServices
import AppKit

/// Crash-safety net: persists original window frames to disk while windows
/// are managed, so a crashed/killed ScrollWM can restore them on next launch.
///
/// File lives in ~/Library/Application Support/ScrollWM/restore.json.
/// Written on every adoption change; deleted on clean release.
enum RestoreStore {
    struct Entry: Codable {
        let pid: pid_t
        let appName: String
        let title: String
        let x: Double, y: Double, w: Double, h: Double
    }

    /// Subdirectory under Application Support. Sandbox mode points this at a
    /// separate folder so its crash-recovery file can never clobber or trigger
    /// recovery of the user's REAL managed windows.
    static var subdirectory = "ScrollWM"

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(subdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("restore.json")
    }

    static func save(engine: TeleportEngine) {
        save(engines: [engine])
    }

    /// Persist the original frames of every window managed by ANY of the given
    /// engines, so multi-display setups (one engine per monitor) survive a crash
    /// just like the single-strip case. The single-engine `save(engine:)` is a
    /// thin wrapper, so existing callers are unchanged.
    static func save(engines: [TeleportEngine]) {
        // Persist EVERY workspace's windows (not just the visible strip) so a
        // crash restores windows parked in inactive vertical workspaces too, AND
        // every NATIVE-Space strip (`allSpacesManagedSlots`) so a window managed
        // on a Desktop the user is not currently viewing is saved as well. With
        // per-Space strips off this equals the old `allManagedSlots`.
        let entries = engines.flatMap { $0.allSpacesManagedSlots }.map { slot in
            Entry(
                pid: slot.window.pid,
                appName: slot.window.appName,
                title: slot.window.title,
                x: slot.window.originalFrame.origin.x,
                y: slot.window.originalFrame.origin.y,
                w: slot.window.originalFrame.width,
                h: slot.window.originalFrame.height
            )
        }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func pendingEntries() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    /// PURE display-safe restore target for a saved entry: the saved frame,
    /// pulled onto a currently-available display only when it is not mostly
    /// visible (e.g. its monitor was unplugged between the crash and recovery).
    ///
    /// A crash-recovery frame is captured against whatever displays existed when
    /// ScrollWM last ran; by the time we recover, that monitor may be gone, which
    /// would strand the window fully off-screen. Clamping here mirrors
    /// `TeleportEngine.releaseAll`'s policy so both restore paths are safe, and
    /// keeps the logic unit-testable (no AX). The common case (frame still
    /// visible) is returned unchanged.
    static func safeTarget(for entry: Entry, displays: [CGRect]) -> CGRect {
        let saved = CGRect(x: entry.x, y: entry.y, width: entry.w, height: entry.h)
        return DisplayGeometry.ensureVisible(saved, displays: displays)
    }

    /// Best-effort recovery after an unclean exit: match windows by
    /// PID (+ title when possible) and put them back at their saved frames.
    ///
    /// Each saved frame is clamped onto a CURRENTLY-available display
    /// (`safeTarget`) so a monitor unplugged since the crash can never strand a
    /// window off-screen; the clamp is a no-op when the frame is still visible.
    ///
    /// Retries with app activation: apps that were never activated (or whose
    /// AX server state went stale after our crash) can report zero windows
    /// until they are poked.
    ///
    /// `displays` defaults to the live `NSScreen` layout; tests inject a fixed
    /// set to exercise the unplugged-monitor clamp without AX.
    @discardableResult
    static func recover(displays: [CGRect]? = nil) -> (restored: Int, total: Int) {
        let entries = pendingEntries()
        guard !entries.isEmpty else { return (0, 0) }
        let displays = displays ?? DisplayGeometry.currentVisibleAXDisplays()

        var remaining = entries
        var restored = 0

        for attempt in 0..<5 {
            guard !remaining.isEmpty else { break }
            var stillPending: [Entry] = []

            for entry in remaining {
                guard let app = NSRunningApplication(processIdentifier: entry.pid),
                      !app.isTerminated else { continue } // app gone: nothing to restore
                var windows = AXSource.windows(for: app)
                if windows.isEmpty && attempt > 0 {
                    // Poke the app: activation re-registers its AX window list.
                    app.activate()
                    Thread.sleep(forTimeInterval: 0.3)
                    windows = AXSource.windows(for: app)
                }
                let target = windows.first { $0.title == entry.title }
                    ?? (windows.count == 1 ? windows[0] : nil)
                guard let target else {
                    stillPending.append(entry)
                    continue
                }

                // Clamp the saved frame onto an available display before placing
                // it, so a window whose original monitor is gone is rescued onto
                // a screen that still exists instead of vanishing off-screen.
                let safe = safeTarget(for: entry, displays: displays)
                let posOK = AXSource.setPoint(target.element, kAXPositionAttribute as String,
                                              safe.origin) == .success
                let sizeOK = AXSource.setSize(target.element, kAXSizeAttribute as String,
                                              safe.size) == .success
                if posOK && sizeOK {
                    restored += 1
                } else {
                    stillPending.append(entry)
                }
            }
            remaining = stillPending
            if !remaining.isEmpty && attempt < 4 {
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        clear()
        return (restored, entries.count)
    }
}
