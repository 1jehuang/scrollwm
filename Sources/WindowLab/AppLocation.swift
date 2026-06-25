import Foundation
import AppKit

/// Where ScrollWM is running FROM, and how to fix the locations that silently
/// break onboarding.
///
/// Why this exists
/// ---------------
/// ScrollWM's one permission (Accessibility) is granted by macOS TCC to a
/// SPECIFIC on-disk app path + code signature. Two launch locations make that
/// grant fail in ways that look like "I turned the switch on and nothing
/// happened", which is the #1 onboarding cliff:
///
///   1. **App Translocation (Gatekeeper).** When a *quarantined* app (anything
///      just downloaded/unzipped) is launched from outside `/Applications`,
///      macOS runs a read-only COPY from a randomized ghost path like
///      `/private/var/folders/…/AppTranslocation/<uuid>/d/ScrollWM.app`. The
///      user flips Accessibility for that ghost, but the path is different on
///      every launch, so the grant can never stick. The app appears trusted in
///      Settings yet `AXIsProcessTrusted()` stays false. This is invisible and
///      maddening.
///
///   2. **Running in place from Downloads / a mounted .dmg / the Desktop.**
///      Even without translocation, granting Accessibility to a copy sitting in
///      `~/Downloads` (or a disk image that later unmounts) means the grant
///      evaporates when the file moves or the volume ejects.
///
/// The fix is the well-established "move me to Applications" pattern: detect
/// these locations and relocate to `~/Applications` (a stable, quarantine-free
/// home) so the grant is asked for ONCE and sticks forever.
///
/// The classification is a PURE function of the bundle path so it is unit
/// tested without a real bundle or any AppKit/TCC state (see StripOpsTests).
enum AppLocation {

    /// Where the running bundle lives, from the perspective of "will the
    /// Accessibility grant stick here?".
    enum Kind: Equatable {
        /// Not an `.app` at all (the bare `WindowLab` dev/CLI binary). Never
        /// relocate; this is the developer workflow.
        case devBinary
        /// Running from a Gatekeeper AppTranslocation ghost path. The grant can
        /// NEVER stick here. Must relocate.
        case translocated
        /// A stable install location (`~/Applications` or `/Applications`).
        /// The grant sticks; run normally.
        case installed
        /// A mounted volume (`.dmg`), `~/Downloads`, or `~/Desktop`: a
        /// transient home where the grant will not survive a move/eject.
        /// Offer to relocate.
        case removableOrTemporary
        /// Some other user-chosen location (e.g. `~/dev/ScrollWM.app`). Respect
        /// the choice; run in place without nagging.
        case otherLocation

        /// Should we proactively offer to move into `~/Applications`?
        /// Translocation is always fixed (it is simply broken); a transient
        /// home is offered. Deliberate custom locations are left alone.
        var shouldOfferRelocation: Bool {
            self == .translocated || self == .removableOrTemporary
        }
    }

    /// Classify a bundle path. PURE: no filesystem or TCC access.
    ///
    /// - Parameters:
    ///   - bundlePath: the `.app` bundle path (e.g. `Bundle.main.bundleURL.path`).
    ///   - isAppBundle: whether we were launched as an `.app` (vs. dev binary).
    ///   - homeDir: the user's home directory (`NSHomeDirectory()`).
    static func classify(bundlePath: String, isAppBundle: Bool, homeDir: String) -> Kind {
        guard isAppBundle else { return .devBinary }

        // 1. Translocation ghost path — check first; it lives under
        //    /private/var/folders too, so it must win over the temp heuristic.
        if bundlePath.contains("/AppTranslocation/") { return .translocated }

        let home = stripTrailingSlash(homeDir)

        // 2. A stable, grant-friendly install location.
        if isUnder(bundlePath, dir: home + "/Applications") || isUnder(bundlePath, dir: "/Applications") {
            return .installed
        }

        // 3. Transient homes where a grant will not survive.
        if bundlePath.hasPrefix("/Volumes/")                       // mounted .dmg / external disk
            || isUnder(bundlePath, dir: home + "/Downloads")
            || isUnder(bundlePath, dir: home + "/Desktop")
            || bundlePath.hasPrefix("/private/var/folders/")       // extracted into a temp dir
            || bundlePath.hasPrefix(stripTrailingSlash(NSTemporaryDirectory())) {
            return .removableOrTemporary
        }

        // 4. A deliberate custom location: leave it be.
        return .otherLocation
    }

    /// The canonical relocation destination for a bundle named `bundleName`
    /// (e.g. `ScrollWM.app`). PURE.
    static func destination(forBundleNamed bundleName: String, homeDir: String) -> String {
        stripTrailingSlash(homeDir) + "/Applications/" + bundleName
    }

    // MARK: - Pure path helpers

    /// True when `path` is the directory `dir` itself or nested inside it.
    /// Normalizes trailing slashes so `/Applications` matches `/Applications/`.
    static func isUnder(_ path: String, dir: String) -> Bool {
        let p = stripTrailingSlash(path)
        let d = stripTrailingSlash(dir)
        return p == d || p.hasPrefix(d + "/")
    }

    private static func stripTrailingSlash(_ s: String) -> String {
        var out = s
        while out.count > 1 && out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

// MARK: - Runtime relocation (impure: filesystem + relaunch)

/// Moves a transient/translocated copy of ScrollWM into `~/Applications` so the
/// Accessibility grant is asked for once and sticks forever, then relaunches
/// from the stable copy. Driven once, very early in `run`, before we touch any
/// window or start the control plane.
enum AppRelocator {

    /// If we are running from a translocated/transient location, relocate to
    /// `~/Applications` (or surface an already-installed copy) and relaunch,
    /// then terminate this process.
    ///
    /// - Returns: `true` when relocation was initiated and the caller MUST stop
    ///   launching (we are about to exit). `false` to continue a normal launch.
    @discardableResult
    static func relocateIfNeeded() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        let kind = AppLocation.classify(bundlePath: bundleURL.path,
                                        isAppBundle: bundleURL.pathExtension == "app",
                                        homeDir: NSHomeDirectory())
        guard kind.shouldOfferRelocation else { return false }

        let bundleName = bundleURL.lastPathComponent   // "ScrollWM.app"
        let destPath = AppLocation.destination(forBundleNamed: bundleName, homeDir: NSHomeDirectory())
        let destURL = URL(fileURLWithPath: destPath)

        // A canonical install already exists and it is not us: just surface it
        // and step aside. We NEVER overwrite the user's installed copy without
        // consent, so an accidental double-click of a download can't downgrade
        // a good install.
        if FileManager.default.fileExists(atPath: destPath),
           destURL.standardizedFileURL != bundleURL.standardizedFileURL {
            dropQuarantine(destURL)
            launch(destURL)
            return true
        }

        // No install yet: ask once, then move + relaunch. (Translocation is
        // simply broken, but a one-line, one-click explanation is far less
        // alarming than the app silently relocating itself.)
        guard confirmRelocation(kind: kind, destination: destURL) else {
            // The user chose to run in place this time. Translocation means the
            // Accessibility grant still won't stick, so make that explicit
            // rather than letting them hit the invisible wall.
            if kind == .translocated { warnTranslocatedRunInPlace() }
            return false
        }

        do {
            try copyBundle(from: bundleURL, to: destURL)
            dropQuarantine(destURL)
            launch(destURL)
            return true
        } catch {
            // Relocation failed (e.g. permissions): fall back to running in
            // place rather than refusing to start.
            reportRelocationFailure(error)
            return false
        }
    }

    // MARK: - Filesystem

    private static func copyBundle(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        // Use ditto: faithfully copies the bundle (resource forks, symlinks,
        // signature) better than FileManager for an .app.
        run("/usr/bin/ditto", [src.path, dst.path])
    }

    /// Strip the Gatekeeper quarantine flag so the relocated copy launches
    /// normally (no translocation, no right-click-Open dance).
    private static func dropQuarantine(_ url: URL) {
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path])
    }

    private static func launch(_ url: URL) {
        run("/usr/bin/open", [url.path])
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: - UI (modal at launch)

    private static func confirmRelocation(kind: AppLocation.Kind, destination: URL) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Move ScrollWM to your Applications folder?"
        let why: String
        switch kind {
        case .translocated:
            why = "macOS is running ScrollWM from a temporary, read-only copy "
                + "(App Translocation). If you grant Accessibility here it will "
                + "NOT stick, and ScrollWM won't be able to move your windows.\n\n"
        case .removableOrTemporary:
            why = "ScrollWM is running from a download or a disk image. The "
                + "Accessibility permission is tied to the app's location, so a "
                + "stable home keeps it working.\n\n"
        default:
            why = ""
        }
        alert.informativeText = why
            + "ScrollWM will move itself to your Applications folder and reopen "
            + "from there, so you only grant Accessibility once."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Run Anyway")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func warnTranslocatedRunInPlace() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility won't stick in this location"
        alert.informativeText = "macOS is running ScrollWM from a temporary copy, "
            + "so any Accessibility permission you grant will be forgotten. To fix "
            + "this, drag ScrollWM into your Applications folder and open it from there."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func reportRelocationFailure(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't move ScrollWM automatically"
        alert.informativeText = "ScrollWM will keep running from its current "
            + "location. For the Accessibility permission to stick, drag "
            + "ScrollWM into your Applications folder and reopen it.\n\n"
            + "(\(error.localizedDescription))"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
