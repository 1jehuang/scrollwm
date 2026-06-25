import Foundation
import AppKit

/// Where ScrollWM is running FROM, and how to fix the locations that silently
/// break onboarding.
///
/// Why this exists
/// ---------------
/// ScrollWM's one permission (Accessibility) is granted by macOS TCC to a
/// SPECIFIC on-disk app path + code signature. Several launch locations make
/// that grant fail in ways that look like "I turned the switch on and nothing
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
///   2. **Running in place from Downloads / a mounted .dmg / the Desktop / a
///      temp extraction / iCloud Drive.** Even without translocation, granting
///      Accessibility to a copy sitting in `~/Downloads` (or a disk image that
///      later unmounts, or an iCloud-synced Desktop that gets evicted to a
///      dataless stub) means the grant evaporates when the file moves, the
///      volume ejects, or iCloud reclaims the bytes.
///
/// The fix is the well-established "move me to Applications" pattern: detect
/// these locations and relocate to `~/Applications` (a stable, quarantine-free
/// home) so the grant is asked for ONCE and sticks forever.
///
/// The classification is a PURE, TOTAL function of the bundle path so it is
/// unit tested without a real bundle or any AppKit/TCC state (see
/// `AppLocationTests` and `StripOpsTests`). It normalizes the things real macOS
/// paths vary by — trailing slashes, case (the default APFS volume is
/// case-insensitive), the APFS data-volume firmlink
/// (`/System/Volumes/Data/Applications` == `/Applications`), and the `/private`
/// firmlink in front of the temp dirs — so every real launch path lands in
/// exactly one bucket.
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
        /// A mounted volume (`.dmg`), `~/Downloads`, `~/Desktop`, a temp
        /// extraction, or iCloud Drive: a transient home where the grant will
        /// not survive a move/eject/eviction. Offer to relocate.
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
    /// This thin wrapper supplies the process temp dir so callers keep the
    /// historical 3-argument signature; the real logic lives in the fully-pure
    /// `classify(bundlePath:isAppBundle:homeDir:temporaryDir:)` overload so the
    /// temp-dir branch is unit-testable with a controlled value.
    ///
    /// - Parameters:
    ///   - bundlePath: the `.app` bundle path (e.g. `Bundle.main.bundleURL.path`).
    ///   - isAppBundle: whether we were launched as an `.app` (vs. dev binary).
    ///   - homeDir: the user's home directory (`NSHomeDirectory()`).
    static func classify(bundlePath: String, isAppBundle: Bool, homeDir: String) -> Kind {
        classify(bundlePath: bundlePath, isAppBundle: isAppBundle,
                 homeDir: homeDir, temporaryDir: NSTemporaryDirectory())
    }

    /// Fully-pure classification. `temporaryDir` is injected (normally
    /// `NSTemporaryDirectory()`) so the per-user temp folder is matched exactly
    /// in addition to the well-known temp roots.
    static func classify(bundlePath: String, isAppBundle: Bool,
                         homeDir: String, temporaryDir: String) -> Kind {
        guard isAppBundle else { return .devBinary }

        // 1. Translocation ghost path — check first; it lives under
        //    /private/var/folders too, so it must win over the temp heuristic.
        //    Match case-insensitively for safety (the directory name is always
        //    `AppTranslocation`, but normalization here costs nothing).
        if bundlePath.range(of: "/AppTranslocation/", options: .caseInsensitive) != nil {
            return .translocated
        }

        let home = stripTrailingSlash(homeDir)

        // 2. A stable, grant-friendly install location.
        if isUnder(bundlePath, dir: home + "/Applications")
            || isUnder(bundlePath, dir: "/Applications") {
            return .installed
        }

        // 3. Transient homes where a grant will not survive.
        if isUnder(bundlePath, dir: "/Volumes")                      // mounted .dmg / external disk
            || isUnder(bundlePath, dir: home + "/Downloads")
            || isUnder(bundlePath, dir: home + "/Desktop")
            || isUnder(bundlePath, dir: home + "/Library/Mobile Documents") // iCloud Drive (incl. synced Desktop/Documents)
            || isTemporary(bundlePath, temporaryDir: temporaryDir) { // extracted into a temp dir
            return .removableOrTemporary
        }

        // 4. A deliberate custom location: leave it be.
        return .otherLocation
    }

    /// The canonical relocation destination for a bundle named `bundleName`
    /// (e.g. `ScrollWM.app`). PURE. Returns a REAL path (not normalized for
    /// case), since this is where we actually copy to.
    static func destination(forBundleNamed bundleName: String, homeDir: String) -> String {
        stripTrailingSlash(homeDir) + "/Applications/" + bundleName
    }

    // MARK: - Pure path helpers

    /// True when `path` is a well-known transient/temporary directory or nested
    /// inside one. Covers the `/private` firmlink form and the bare form of the
    /// per-user `/var/folders` cache, `/tmp`, and the injected process temp dir.
    /// PURE.
    static func isTemporary(_ path: String, temporaryDir: String) -> Bool {
        var dirs = [
            "/private/var/folders", "/var/folders",   // per-user darwin cache (with/without /private)
            "/private/tmp", "/tmp",                   // classic temp (with/without /private)
        ]
        let temp = stripTrailingSlash(temporaryDir)
        if !temp.isEmpty && temp != "/" {
            dirs.append(temp)
            // Match whether the caller's temp dir carried the /private firmlink
            // prefix or not (NSTemporaryDirectory has reported it both ways).
            if temp.hasPrefix("/private/") {
                dirs.append(String(temp.dropFirst("/private".count)))
            } else {
                dirs.append("/private" + temp)
            }
        }
        return dirs.contains { isUnder(path, dir: $0) }
    }

    /// True when `path` is the directory `dir` itself or nested inside it.
    /// Normalizes trailing slashes, case (default APFS is case-insensitive), and
    /// the APFS data-volume firmlink so `/Applications`, `/applications/`, and
    /// `/System/Volumes/Data/Applications` all match. PURE.
    static func isUnder(_ path: String, dir: String) -> Bool {
        let p = normalizedForCompare(path)
        let d = normalizedForCompare(dir)
        return p == d || p.hasPrefix(d + "/")
    }

    /// Lowercased + firmlink-collapsed + trailing-slash-stripped form, used ONLY
    /// for path comparison (never for paths we write to). PURE.
    static func normalizedForCompare(_ s: String) -> String {
        var p = stripTrailingSlash(s)
        // APFS data-volume firmlink: /System/Volumes/Data/<x> is the same node
        // as /<x> (Catalina+ split system/data volumes). Collapse it so an
        // install reported through the data volume still classifies as installed.
        let dataVol = "/System/Volumes/Data"
        if p == dataVol {
            p = "/"
        } else if p.hasPrefix(dataVol + "/") {
            p = String(p.dropFirst(dataVol.count))
        }
        return p.lowercased()
    }

    private static func stripTrailingSlash(_ s: String) -> String {
        var out = s
        while out.count > 1 && out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

// MARK: - Relocation policy (pure: no filesystem, AppKit, or relaunch)

/// The pure decisions behind `AppRelocator`. Splitting them out keeps every
/// behavioral branch unit-testable (see `AppLocationTests`) while the impure
/// `AppRelocator` stays a thin, documented shell around `ditto`/`xattr`/`open`
/// and the launch-time modal.
enum AppRelocation {

    /// What `AppRelocator` should do for a given location + destination state.
    enum Action: Equatable {
        /// Location is fine (or not an offered kind): continue a normal launch.
        case runInPlace
        /// A DIFFERENT, already-present install exists at the destination: open
        /// THAT copy and step aside. We never overwrite a good install without
        /// consent, so an accidental double-click of a download can't downgrade it.
        case surfaceExisting
        /// No install yet (or we already are it): ask once, then copy + relaunch.
        case offerMove
    }

    /// Decide the relocation action. PURE.
    /// - Parameters:
    ///   - kind: the classified launch location.
    ///   - destinationExists: does something already live at `~/Applications/<name>`?
    ///   - bundleIsDestination: is the thing at the destination actually us?
    static func action(kind: AppLocation.Kind,
                       destinationExists: Bool,
                       bundleIsDestination: Bool) -> Action {
        guard kind.shouldOfferRelocation else { return .runInPlace }
        if destinationExists && !bundleIsDestination { return .surfaceExisting }
        return .offerMove
    }

    /// When the user declines the move, do we still need to warn that the grant
    /// won't stick? Translocation is *broken*, not merely sub-optimal, so the
    /// "Run Anyway" path must always warn. A transient home at least works for
    /// this session, so no second modal. PURE.
    static func shouldWarnRunInPlace(kind: AppLocation.Kind) -> Bool {
        kind == .translocated
    }

    /// Did `ditto` produce something that actually looks like an app bundle?
    /// Guards against a partial/aborted copy being moved into place and then
    /// failing to launch. PURE.
    static func isPlausibleAppBundle(hasInfoPlist: Bool, hasExecutable: Bool) -> Bool {
        hasInfoPlist && hasExecutable
    }

    /// Overall success gate for a relocate: the copy tool exited cleanly AND the
    /// resulting bundle is plausible. (Quarantine stripping is best-effort and
    /// does NOT gate success — a relocated copy that still has the flag launches
    /// fine, it just shows the one-time Gatekeeper prompt.) PURE.
    static func relocationSucceeded(copyExitedClean: Bool, destinationPlausible: Bool) -> Bool {
        copyExitedClean && destinationPlausible
    }

    /// User-facing copy for the relocation modals. Kept here, pure, so the
    /// wording can't silently drift and is asserted by tests.
    enum Copy {
        static let confirmTitle = "Move ScrollWM to your Applications folder?"
        static let moveButton = "Move to Applications"
        static let runAnywayButton = "Run Anyway"
        static let warnTitle = "Accessibility won't stick in this location"
        static let failureTitle = "Couldn't move ScrollWM automatically"

        /// Why this location is a problem, tailored to the kind.
        static func rationale(for kind: AppLocation.Kind) -> String {
            switch kind {
            case .translocated:
                return "macOS is running ScrollWM from a temporary, read-only copy "
                    + "(App Translocation). If you grant Accessibility here it will "
                    + "NOT stick, and ScrollWM won't be able to move your windows."
            case .removableOrTemporary:
                return "ScrollWM is running from a download, a disk image, or another "
                    + "temporary place. The Accessibility permission is tied to the "
                    + "app's location, so a stable home keeps it working."
            default:
                return ""
            }
        }

        /// The full body of the "Move to Applications?" modal.
        static func confirmInformative(for kind: AppLocation.Kind) -> String {
            let why = rationale(for: kind)
            let action = "ScrollWM will move itself to your Applications folder and "
                + "reopen from there, so you only grant Accessibility once."
            return why.isEmpty ? action : why + "\n\n" + action
        }

        /// The warning shown when the user runs a TRANSLOCATED copy in place.
        static let warnBody = "macOS is running ScrollWM from a temporary copy, so any "
            + "Accessibility permission you grant will be forgotten. To fix this, drag "
            + "ScrollWM into your Applications folder and open it from there."

        /// The body shown when an automatic move fails.
        static func failureBody(_ error: String) -> String {
            "ScrollWM will keep running from its current location. For the Accessibility "
                + "permission to stick, drag ScrollWM into your Applications folder and "
                + "reopen it.\n\n(\(error))"
        }
    }
}

// MARK: - Runtime relocation (impure: filesystem + relaunch)

/// Moves a transient/translocated copy of ScrollWM into `~/Applications` so the
/// Accessibility grant is asked for once and sticks forever, then relaunches
/// from the stable copy. Driven once, very early in `run`, before we touch any
/// window or start the control plane.
///
/// All decisions are delegated to the pure `AppRelocation`/`AppLocation`
/// policy; this enum is only the thin, documented filesystem + modal shell.
enum AppRelocator {

    /// A relocation that failed in a way worth surfacing rather than silently
    /// continuing with a half-written copy.
    enum RelocationError: LocalizedError {
        case copyFailed
        case incompleteCopy

        var errorDescription: String? {
            switch self {
            case .copyFailed:    return "The copy could not be completed."
            case .incompleteCopy: return "The copied app appeared to be incomplete."
            }
        }
    }

    /// If we are running from a translocated/transient location, relocate to
    /// `~/Applications` (or surface an already-installed copy) and relaunch,
    /// then terminate this process.
    ///
    /// - Returns: `true` when relocation was initiated and the caller MUST stop
    ///   launching (we are about to exit). `false` to continue a normal launch.
    @discardableResult
    static func relocateIfNeeded() -> Bool {
        let fm = FileManager.default
        let bundleURL = Bundle.main.bundleURL

        // Resolve symlinks so a symlinked home (or a firmlinked/relative path)
        // classifies against its real on-disk location. classify() is pure and
        // tolerant of the data-volume firmlink and trailing slashes regardless.
        let realBundlePath = bundleURL.resolvingSymlinksInPath().path
        let realHome = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path

        let kind = AppLocation.classify(bundlePath: realBundlePath,
                                        isAppBundle: bundleURL.pathExtension == "app",
                                        homeDir: realHome)

        let bundleName = bundleURL.lastPathComponent   // "ScrollWM.app"
        let destPath = AppLocation.destination(forBundleNamed: bundleName, homeDir: realHome)
        let destURL = URL(fileURLWithPath: destPath)
        let destExists = fm.fileExists(atPath: destPath)
        let bundleIsDest = URL(fileURLWithPath: realBundlePath).standardizedFileURL
            == destURL.standardizedFileURL

        switch AppRelocation.action(kind: kind,
                                    destinationExists: destExists,
                                    bundleIsDestination: bundleIsDest) {
        case .runInPlace:
            return false

        case .surfaceExisting:
            // A canonical install already exists and it is not us: just surface
            // it and step aside. `open` activates an already-running instance
            // rather than launching a second one, so this also handles
            // "destination already running". We NEVER overwrite the user's
            // installed copy here.
            dropQuarantine(destURL)
            launch(destURL)
            return true

        case .offerMove:
            // Ask once, then move + relaunch. (Translocation is simply broken,
            // but a one-line, one-click explanation is far less alarming than the
            // app silently relocating itself.)
            guard confirmRelocation(kind: kind) else {
                // The user chose to run in place this time. Translocation means
                // the Accessibility grant still won't stick, so make that
                // explicit rather than letting them hit the invisible wall.
                if AppRelocation.shouldWarnRunInPlace(kind: kind) { warnTranslocatedRunInPlace() }
                return false
            }
            do {
                try copyBundle(from: bundleURL, to: destURL)
                launch(destURL)
                return true
            } catch {
                // Relocation failed (e.g. permissions, partial copy): clean up
                // and fall back to running in place rather than refusing to start.
                reportRelocationFailure(error)
                return false
            }
        }
    }

    // MARK: - Filesystem

    /// Faithfully copy the bundle into `~/Applications`, hardened against
    /// partial/aborted copies and against clobbering a good install:
    ///   1. `ditto` into a hidden sibling STAGING dir (resource forks, symlinks,
    ///      signature preserved better than FileManager for an `.app`).
    ///   2. Verify the staged copy is a plausible app bundle; bail if not.
    ///   3. Strip quarantine on the staged copy BEFORE it goes live.
    ///   4. Atomically swap it into place (so a crash mid-copy never leaves a
    ///      half-written `.app` where the finished one should be).
    ///   5. Re-check the live copy and re-strip quarantine (belt + suspenders).
    private static func copyBundle(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        let parent = dst.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let staging = parent.appendingPathComponent(
            ".\(dst.lastPathComponent).scrollwm-staging-\(UUID().uuidString)")
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }   // no-op once moved into place

        guard run("/usr/bin/ditto", [src.path, staging.path]) else {
            throw RelocationError.copyFailed
        }
        guard isPlausibleBundle(staging) else { throw RelocationError.incompleteCopy }

        dropQuarantine(staging)

        // Atomic swap. `offerMove` is only reached with consent (or no prior
        // install), so this never silently clobbers a good install.
        if fm.fileExists(atPath: dst.path) {
            _ = try fm.replaceItemAt(dst, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: dst)
        }

        guard isPlausibleBundle(dst) else { throw RelocationError.incompleteCopy }
        // Quarantine re-check: if the move re-applied a flag, strip it again so
        // the relocated copy launches without the right-click-Open dance.
        if hasQuarantine(dst) { dropQuarantine(dst) }
    }

    /// FS-side plausibility probe feeding the pure `AppRelocation` decision: a
    /// real bundle has `Contents/Info.plist` and a non-empty `Contents/MacOS`.
    private static func isPlausibleBundle(_ url: URL) -> Bool {
        let fm = FileManager.default
        let hasInfoPlist = fm.fileExists(atPath:
            url.appendingPathComponent("Contents/Info.plist").path)
        let macOSDir = url.appendingPathComponent("Contents/MacOS")
        var isDir: ObjCBool = false
        let macOSExists = fm.fileExists(atPath: macOSDir.path, isDirectory: &isDir) && isDir.boolValue
        let hasExecutable = macOSExists
            && ((try? fm.contentsOfDirectory(atPath: macOSDir.path))?.isEmpty == false)
        return AppRelocation.isPlausibleAppBundle(hasInfoPlist: hasInfoPlist,
                                                  hasExecutable: hasExecutable)
    }

    /// Strip the Gatekeeper quarantine flag so the relocated copy launches
    /// normally (no translocation, no right-click-Open dance).
    private static func dropQuarantine(_ url: URL) {
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path])
    }

    /// True when the bundle still carries a quarantine flag (`xattr -p` exits 0
    /// iff the attribute is present).
    private static func hasQuarantine(_ url: URL) -> Bool {
        run("/usr/bin/xattr", ["-p", "com.apple.quarantine", url.path])
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

    // MARK: - UI (modal at launch). All wording lives in AppRelocation.Copy.

    private static func confirmRelocation(kind: AppLocation.Kind) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = AppRelocation.Copy.confirmTitle
        alert.informativeText = AppRelocation.Copy.confirmInformative(for: kind)
        alert.addButton(withTitle: AppRelocation.Copy.moveButton)
        alert.addButton(withTitle: AppRelocation.Copy.runAnywayButton)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func warnTranslocatedRunInPlace() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppRelocation.Copy.warnTitle
        alert.informativeText = AppRelocation.Copy.warnBody
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func reportRelocationFailure(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppRelocation.Copy.failureTitle
        alert.informativeText = AppRelocation.Copy.failureBody(error.localizedDescription)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
