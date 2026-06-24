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
        // Persist EVERY workspace's windows (not just the visible strip) so a
        // crash restores windows parked in inactive vertical workspaces too.
        let entries = engine.allManagedSlots.map { slot in
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

    /// Best-effort recovery after an unclean exit: match windows by
    /// PID (+ title when possible) and put them back at their saved frames.
    ///
    /// Retries with app activation: apps that were never activated (or whose
    /// AX server state went stale after our crash) can report zero windows
    /// until they are poked.
    @discardableResult
    static func recover() -> (restored: Int, total: Int) {
        let entries = pendingEntries()
        guard !entries.isEmpty else { return (0, 0) }

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

                let posOK = AXSource.setPoint(target.element, kAXPositionAttribute as String,
                                              CGPoint(x: entry.x, y: entry.y)) == .success
                let sizeOK = AXSource.setSize(target.element, kAXSizeAttribute as String,
                                              CGSize(width: entry.w, height: entry.h)) == .success
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
