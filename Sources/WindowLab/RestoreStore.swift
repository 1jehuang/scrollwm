import Foundation
import ApplicationServices
import AppKit

/// Crash-safety net: persists original window frames to disk while windows
/// are managed, so a crashed/killed ScrollWM can restore them on next launch.
///
/// File lives in ~/Library/Application Support/ScrollWM/restore.json.
/// Written on every adoption change; deleted on clean release.
///
/// **Space-aware (Model B):** each entry is tagged with the native macOS Space
/// (Mission Control "Desktop") its window was managed on (`Entry.space`, `nil`
/// when per-Space tracking is off). Recovery uses that tag (`mayActivate`) to
/// refuse to `activate` a window on a Desktop the user is not viewing, so
/// startup recovery can never teleport the user to another Space - the hazard
/// flagged in `docs/spaces/02_ownership.md` §3.
enum RestoreStore {
    struct Entry: Codable {
        let pid: pid_t
        let appName: String
        let title: String
        let x: Double, y: Double, w: Double, h: Double
        /// Native macOS Space (Mission Control "Desktop") id the window was
        /// managed on, or `nil` when per-Space tracking was off / the id was
        /// unknown. Optional so restore files written before Space-aware recovery
        /// decode cleanly (and so existing callers can omit it). Recovery uses it
        /// to refuse to `activate` (and thus teleport the user to) a window that
        /// lives on a Desktop the user is not currently viewing.
        let space: Int?

        init(pid: pid_t, appName: String, title: String,
             x: Double, y: Double, w: Double, h: Double, space: Int? = nil) {
            self.pid = pid
            self.appName = appName
            self.title = title
            self.x = x; self.y = y; self.w = w; self.h = h
            self.space = space
        }
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
        // every NATIVE-Space strip (`allSpacesManagedSlotsTagged`) so a window
        // managed on a Desktop the user is not currently viewing is saved as well,
        // TAGGED with that Desktop's Space id. With per-Space strips off this
        // equals the old `allManagedSlots` and every tag is `nil`.
        let entries = engines.flatMap { $0.allSpacesManagedSlotsTagged }.map { tagged in
            Entry(
                pid: tagged.slot.window.pid,
                appName: tagged.slot.window.appName,
                title: tagged.slot.window.title,
                x: tagged.slot.window.originalFrame.origin.x,
                y: tagged.slot.window.originalFrame.origin.y,
                w: tagged.slot.window.originalFrame.width,
                h: tagged.slot.window.originalFrame.height,
                space: tagged.space
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

    /// PURE Space-safety gate for crash recovery: may we `activate` this entry's
    /// app to poke its AX window list?
    ///
    /// `app.activate()` brings an app's front window forward, and on macOS that
    /// **switches the user to whatever Space that window lives on**. During
    /// startup recovery that means a window the user has since sent to another
    /// Desktop would yank the user off the Desktop they launched on - the exact
    /// "restore can teleport your Space at startup" hazard from
    /// `docs/spaces/02_ownership.md` §3.
    ///
    /// Rule: refuse activation only when we KNOW the window is on a DIFFERENT
    /// Space than the one the user is viewing. When either id is unknown
    /// (`nil` - per-Space tracking off, a legacy restore file, or the live probe
    /// unavailable) we allow it, preserving the historical single-strip behavior
    /// exactly. Pure + total so it is exhaustively unit-testable without AX.
    static func mayActivate(for entry: Entry, currentSpace: Int?) -> Bool {
        guard let entrySpace = entry.space, let currentSpace else { return true }
        return entrySpace == currentSpace
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
    /// until they are poked. That poke is **gated by Space** (`mayActivate`): a
    /// window known to live on another Desktop is never activated, so recovery
    /// can never teleport the user off the Space they launched on. If the app
    /// already exposes the window (no poke needed) its frame is still restored
    /// even when off-Space (position/size writes are safe AX no-ops for the
    /// active Space); only the activation poke is withheld. A deferred off-Space
    /// window is left where it is - with per-Space strips the live monitor
    /// re-adopts and re-tiles it when the user returns to that Desktop.
    ///
    /// `displays` defaults to the live `NSScreen` layout; tests inject a fixed
    /// set to exercise the unplugged-monitor clamp without AX. `currentSpace`
    /// defaults to the live `SpaceProbe`; tests inject a fixed id.
    @discardableResult
    static func recover(displays: [CGRect]? = nil,
                        currentSpace: Int?? = nil) -> (restored: Int, total: Int) {
        let entries = pendingEntries()
        guard !entries.isEmpty else { return (0, 0) }
        let displays = displays ?? DisplayGeometry.currentVisibleAXDisplays()
        // Resolve the active Space once so the activation gate is stable for the
        // whole recovery pass. `??` unwraps the caller's explicit override
        // (including an explicit `nil`); otherwise probe live.
        let currentSpace = currentSpace ?? SpaceProbe.currentSpaceID()

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
                    // SKIP the poke for a window known to be on another Desktop -
                    // activating it would teleport the user there. Such an entry
                    // is deferred (it stays in `stillPending`); a later poll on
                    // the user's return to that Desktop will restore it without a
                    // startup teleport.
                    if mayActivate(for: entry, currentSpace: currentSpace) {
                        app.activate()
                        Thread.sleep(forTimeInterval: 0.3)
                        windows = AXSource.windows(for: app)
                    } else {
                        stillPending.append(entry)
                        continue
                    }
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
