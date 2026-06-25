import Foundation
import AppKit

/// Glue between the pure `Updater`/`UpdatePolicy` and the running app:
/// schedules background checks, persists tiny state, enforces the safety policy
/// (no relaunch loops, don't disrupt an active session, never silently break
/// the Accessibility grant), and presents the user-facing prompts or installs
/// silently when configured.
///
/// Lifecycle: the controller creates one after launch (`startUpdates`) and
/// reconfigures it on config reload. The background check is a no-op when
/// `config.update.enabled` is false; explicit user checks (menu / CLI) always
/// work.
///
/// Threading: every method here runs on the main thread. `Updater`'s network
/// callbacks already hop back to main, and the public entry points (timer,
/// menu, CLI dispatch on the control socket) are all main-thread.
final class UpdateCoordinator {
    private weak var controller: ScrollWMController?
    private var config: ScrollWMConfig.Update
    private var updater: Updater
    private var timer: Timer?

    /// True while a check or download is in flight, so we never run two at once
    /// (e.g. the periodic timer firing during a manual check).
    private(set) var isBusy = false

    /// A verified, staged update waiting to be applied on quit (the
    /// `.onQuit` apply-timing case, so we don't destroy the live strip
    /// mid-session). Consumed by `applyPendingUpdateOnQuit()`.
    private var pendingStagedApp: URL?
    private var pendingRelease: ReleaseInfo?

    /// Persisted, tiny state: throttles checks, remembers a skipped version, and
    /// records auto-install attempts so a broken release can't loop forever.
    private struct State: Codable {
        var lastCheck: Date?
        var skippedVersion: String?
        var lastAttempt: UpdatePolicy.AttemptRecord?
    }
    private var state: State

    init(controller: ScrollWMController, config: ScrollWMConfig.Update) {
        self.controller = controller
        self.config = config
        self.updater = Updater(allowPrerelease: config.allowPrerelease)
        self.state = Self.loadState()
    }

    // MARK: - Scheduling

    /// Start background checking per config. Safe to call repeatedly (it tears
    /// down any existing schedule first). Does an initial check shortly after
    /// launch if enough time has elapsed since the last one.
    func start() {
        timer?.invalidate()
        timer = nil
        guard config.enabled else { return }

        // A light check ~8s after launch (don't compete with startup work), but
        // only if we're actually due, so relaunch-loops don't spam the API.
        let interval = max(3600.0, config.checkIntervalHours * 3600.0)
        let due: Bool = {
            guard let last = state.lastCheck else { return true }
            return Date().timeIntervalSince(last) >= interval
        }()
        if due {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                self?.checkInBackground()
            }
        }

        // Repeating timer for long-running sessions.
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkInBackground()
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func updateConfig(_ newConfig: ScrollWMConfig.Update) {
        config = newConfig
        updater = Updater(allowPrerelease: newConfig.allowPrerelease)
        start()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Checks

    /// Background check: only acts when there's a not-skipped update.
    private func checkInBackground() {
        guard config.enabled, !isBusy else { return }
        runCheck(userInitiated: false)
    }

    /// User-initiated check (menu / CLI). Always reports the outcome, including
    /// "you're up to date", and ignores the per-version skip.
    func checkNow(userInitiated: Bool = true) {
        guard !isBusy else { return }
        runCheck(userInitiated: userInitiated)
    }

    private func runCheck(userInitiated: Bool) {
        isBusy = true
        state.lastCheck = Date()
        saveState()
        updater.check { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            switch result {
            case .success(.upToDate(let cur)):
                if userInitiated { self.presentUpToDate(current: cur) }
            case .success(.updateAvailable(let release, let cur)):
                self.handleAvailable(release, current: cur, userInitiated: userInitiated)
            case .success(.noUsableAsset):
                if userInitiated { self.presentUpToDate(current: AppVersion.current) }
            case .failure(let err):
                if userInitiated { self.presentError(err) }
                else { print("update: background check failed: \(err.localizedDescription)") }
            }
        }
    }

    private func handleAvailable(_ release: ReleaseInfo, current: SemVer, userInitiated: Bool) {
        let version = release.version.description

        if userInitiated {
            // Manual check: always offer, even if skipped/attempt-exhausted.
            presentUpdatePrompt(release, current: current)
            return
        }

        // Background path.
        if !config.automatic {
            // Notify-only mode: prompt unless the user skipped this version.
            if state.skippedVersion == version { return }
            presentUpdatePrompt(release, current: current)
            return
        }

        // Automatic mode: respect skip + the per-version attempt guard so a
        // broken release can't loop check->install->relaunch forever.
        guard UpdatePolicy.shouldAutoInstall(available: version,
                                             lastAttempt: state.lastAttempt,
                                             skipped: state.skippedVersion) else {
            // Exhausted automatic attempts: fall back to a one-time prompt so
            // the user isn't stuck, then stop nagging.
            if state.skippedVersion != version {
                print("update: auto-install of v\(version) exhausted attempts; prompting once")
                presentUpdatePrompt(release, current: current)
            }
            return
        }
        beginInstall(release, mode: .automatic)
    }

    // MARK: - Install

    enum InstallMode { case automatic, userClicked }

    /// Pre-flight, then download + verify + stage + validate, then apply per
    /// policy (now, or deferred to quit while the user is actively managing).
    func beginInstall(_ release: ReleaseInfo, mode: InstallMode) {
        guard !isBusy else { return }
        let bundleURL = Bundle.main.bundleURL

        // 1. Classify the install target (pre-flight) so we never enter the
        //    install/relaunch cycle when it can't or shouldn't succeed.
        let target = classifyInstallTarget(bundleURL: bundleURL)
        switch target {
        case .notAppBundle:
            presentDevCannotInstall(release); return
        case .homebrewManaged:
            presentHomebrewManaged(release); return
        case .notWritable:
            presentNotWritable(release); return
        case .selfUpdatable:
            break
        }

        let automatic = (mode == .automatic)
        if automatic {
            // Record the attempt up front so a crash/loop is still bounded.
            state.lastAttempt = UpdatePolicy.recordingAttempt(state.lastAttempt, version: release.version.description)
            saveState()
        }

        isBusy = true
        updater.downloadAndStage(release,
                                 requireChecksum: automatic,
                                 stageNear: bundleURL) { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            switch result {
            case .success(let stagedApp):
                self.afterStage(stagedApp, release: release, mode: mode)
            case .failure(let err):
                if automatic { print("update: auto-install failed: \(err.localizedDescription)") }
                else { self.presentError(err) }
            }
        }
    }

    /// Validate the staged bundle, check whether the Accessibility grant will
    /// survive, then apply now or defer to quit.
    private func afterStage(_ stagedApp: URL, release: ReleaseInfo, mode: InstallMode) {
        let bundleURL = Bundle.main.bundleURL

        // Validate the staged bundle before it can replace the live app.
        if let reason = updater.validateStaged(stagedApp, expectedMinVersion: release.version) {
            let msg = "staged update rejected: \(reason)"
            if mode == .automatic { print("update: \(msg)") }
            else { presentError(.installFailed(reason)) }
            return
        }

        // Will TCC keep the Accessibility grant after the swap? If not (e.g.
        // an ad-hoc -> ad-hoc change of cdhash), an AUTOMATIC silent install
        // would leave a window manager that can't move windows. Refuse the
        // silent path in that case and prompt instead, so the user is never
        // silently broken. (A manual install is the user's explicit choice;
        // we proceed but warn.)
        let preserves = CodeSigning.willPreserveAccessibility(currentBundle: bundleURL, stagedBundle: stagedApp)
        if !preserves && mode == .automatic {
            print("update: auto-install would not preserve Accessibility; prompting instead")
            // Reset the attempt budget we consumed; this isn't a failed install.
            presentGrantWillResetPrompt(release, stagedApp: stagedApp)
            return
        }

        let timing = UpdatePolicy.applyTiming(isManaging: controller?.isManaging ?? false,
                                              automatic: mode == .automatic)
        switch timing {
        case .now:
            applyNow(stagedApp: stagedApp, release: release, announce: mode == .automatic, grantWillReset: !preserves)
        case .onQuit:
            pendingStagedApp = stagedApp
            pendingRelease = release
            print("update: v\(release.version) staged; will install when you quit (so your layout isn't disrupted)")
        }
    }

    /// Apply immediately: record a pending marker (so the relaunched app can
    /// confirm success / detect a lost grant), spawn the swapper, then quit
    /// cleanly so windows are restored before the swap.
    private func applyNow(stagedApp: URL, release: ReleaseInfo, announce: Bool, grantWillReset: Bool) {
        writePendingMarker(version: release.version.description, grantWillReset: grantWillReset)
        do {
            try updater.installAndRelaunch(stagedApp: stagedApp)
        } catch {
            clearPendingMarker()
            presentError((error as? UpdateError) ?? .installFailed(error.localizedDescription))
            return
        }
        if announce {
            print("update: installing v\(release.version); ScrollWM will restore windows and relaunch")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.controller?.quit()
        }
    }

    /// Called by the controller from `quit()`: if a verified update is staged
    /// for on-quit application, spawn the swapper now (windows are about to be
    /// restored by the quit path). Returns true if a swap was launched.
    @discardableResult
    func applyPendingUpdateOnQuit() -> Bool {
        guard let staged = pendingStagedApp, let release = pendingRelease else { return false }
        pendingStagedApp = nil
        pendingRelease = nil
        let preserves = CodeSigning.willPreserveAccessibility(currentBundle: Bundle.main.bundleURL, stagedBundle: staged)
        writePendingMarker(version: release.version.description, grantWillReset: !preserves)
        do {
            try updater.installAndRelaunch(stagedApp: staged)
            print("update: applying staged v\(release.version) on quit")
            return true
        } catch {
            clearPendingMarker()
            print("update: on-quit install failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Called early at launch (production run): if we just relaunched from an
    /// update, verify it actually advanced the version, surface a re-grant
    /// notice if the Accessibility grant reset, and clear the marker.
    func reconcileAfterRelaunch() {
        guard let marker = readPendingMarker() else { return }
        clearPendingMarker()
        let running = AppVersion.currentString
        if UpdatePolicy.installSucceeded(attempted: marker.version, runningNow: running) {
            print("update: now running v\(running) (updated from a previous version)")
            // Clear the attempt record: this version installed successfully.
            if state.lastAttempt?.version == marker.version {
                state.lastAttempt = nil
                saveState()
            }
            // If the grant reset, guide the user to re-enable it.
            if marker.grantWillReset || !(controller?.accessibilityIsTrusted ?? true) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.maybePresentRegrantAfterUpdate()
                }
            }
        } else {
            // The swap silently failed; we're still on the old version. The
            // attempt record (incremented before install) caps further tries.
            print("update: relaunched but still on v\(running) (expected v\(marker.version)); install may have failed (see \(InstallSwap.logURL.path))")
        }
    }

    private func maybePresentRegrantAfterUpdate() {
        guard let controller, !controller.accessibilityIsTrusted else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Re-enable Accessibility for ScrollWM"
        alert.informativeText = """
        ScrollWM just updated. macOS reset its Accessibility permission because \
        the update changed the app's code signature.

        Open System Settings > Privacy & Security > Accessibility, then remove \
        ScrollWM (–) and add it again (or toggle it off and on). ScrollWM will \
        start managing windows as soon as the permission is back.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            AccessibilityPermission.shared.openSystemSettings()
        }
    }

    // MARK: - Pre-flight classification (impure: filesystem)

    private func classifyInstallTarget(bundleURL: URL) -> UpdatePolicy.InstallTarget {
        let isApp = bundleURL.pathExtension == "app"
        let parent = bundleURL.deletingLastPathComponent().path
        let writable = access(parent, W_OK) == 0
        let pure = UpdatePolicy.classifyTarget(isAppBundle: isApp,
                                               bundlePath: bundleURL.path,
                                               parentWritable: writable,
                                               brewPrefixes: Self.brewPrefixes)
        // The common case: a cask copies the .app to /Applications (NOT under a
        // brew prefix), so the pure check misses it. Probe the Caskroom receipt.
        if pure == .selfUpdatable, Self.isHomebrewCaskInstalled() {
            return .homebrewManaged
        }
        return pure
    }

    private static let brewPrefixes = ["/opt/homebrew", "/usr/local"]

    /// True if a `scrollwm` cask receipt exists in any Homebrew Caskroom.
    private static func isHomebrewCaskInstalled() -> Bool {
        for prefix in brewPrefixes {
            let caskroom = prefix + "/Caskroom/scrollwm"
            if FileManager.default.fileExists(atPath: caskroom) { return true }
        }
        return false
    }

    // MARK: - State persistence

    private static var stateURL: URL {
        ScrollWMConfig.dirURL.appendingPathComponent("update-state.json")
    }
    private static func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return s
    }
    private func saveState() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    // MARK: - Pending-install marker (survives the swap)

    private struct PendingMarker: Codable { var version: String; var grantWillReset: Bool }
    private func writePendingMarker(version: String, grantWillReset: Bool) {
        let m = PendingMarker(version: version, grantWillReset: grantWillReset)
        if let data = try? JSONEncoder().encode(m) {
            try? data.write(to: InstallSwap.pendingMarkerURL, options: .atomic)
        }
    }
    private func readPendingMarker() -> PendingMarker? {
        guard let data = try? Data(contentsOf: InstallSwap.pendingMarkerURL) else { return nil }
        return try? JSONDecoder().decode(PendingMarker.self, from: data)
    }
    private func clearPendingMarker() {
        try? FileManager.default.removeItem(at: InstallSwap.pendingMarkerURL)
    }

    // MARK: - UI

    private func presentUpdatePrompt(_ release: ReleaseInfo, current: SemVer) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ScrollWM \(release.version) is available"
        var info = "You have \(current). Update now? ScrollWM will restore your "
            + "windows, replace itself, and relaunch."
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            info += "\n\nRelease notes:\n" + String(notes.prefix(600))
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "View on GitHub")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            beginInstall(release, mode: .userClicked)
        case .alertSecondButtonReturn:
            openReleasePage(release)
        case .alertThirdButtonReturn:
            state.skippedVersion = release.version.description
            saveState()
        default:
            break  // Later
        }
    }

    /// Shown when an AUTOMATIC install would reset the Accessibility grant
    /// (ad-hoc signing): we never silently break the WM, so we ask first and
    /// explain the one-time re-grant.
    private func presentGrantWillResetPrompt(_ release: ReleaseInfo, stagedApp: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ScrollWM \(release.version) is available"
        alert.informativeText = """
        A new version is ready. Installing it will require you to re-enable \
        ScrollWM in System Settings > Privacy & Security > Accessibility once \
        afterward (this build's signature isn't stable across updates).

        Install now and relaunch?
        """
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "View on GitHub")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // User consented: apply (now if dormant, on quit if managing).
            let timing = UpdatePolicy.applyTiming(isManaging: controller?.isManaging ?? false, automatic: false)
            if timing == .now {
                applyNow(stagedApp: stagedApp, release: release, announce: false, grantWillReset: true)
            } else {
                pendingStagedApp = stagedApp
                pendingRelease = release
            }
        case .alertSecondButtonReturn:
            openReleasePage(release)
        case .alertThirdButtonReturn:
            state.skippedVersion = release.version.description
            saveState()
        default:
            break
        }
    }

    private func presentUpToDate(current: SemVer) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "ScrollWM \(current) is the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentError(_ err: UpdateError) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't update ScrollWM"
        alert.informativeText = err.localizedDescription
            + "\n\nYou can always download the latest from GitHub."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Releases")
        if alert.runModal() == .alertSecondButtonReturn { openReleasesIndex() }
    }

    private func presentDevCannotInstall(_ release: ReleaseInfo) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Update available: \(release.version)"
        alert.informativeText = "This is a development build, so it won't replace "
            + "itself. Pull + rebuild, or download the release from GitHub."
        alert.addButton(withTitle: "Open Releases")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn { openReleasePage(release) }
    }

    private func presentHomebrewManaged(_ release: ReleaseInfo) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ScrollWM \(release.version) is available"
        alert.informativeText = """
        ScrollWM was installed with Homebrew, so it updates through Homebrew to \
        keep everything in sync. Run:

            brew upgrade --cask scrollwm
        """
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew upgrade --cask scrollwm", forType: .string)
        }
    }

    private func presentNotWritable(_ release: ReleaseInfo) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ScrollWM \(release.version) is available"
        alert.informativeText = """
        ScrollWM can't update itself because it doesn't have permission to \
        write to its install location (\(Bundle.main.bundleURL.deletingLastPathComponent().path)).

        Download the new version from GitHub and replace the app, or move \
        ScrollWM to your user Applications folder (~/Applications).
        """
        alert.addButton(withTitle: "Open Releases")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { openReleasePage(release) }
    }

    private func openReleasePage(_ release: ReleaseInfo) {
        let s = release.htmlURL.isEmpty
            ? "https://github.com/\(Updater.owner)/\(Updater.repo)/releases"
            : release.htmlURL
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
    private func openReleasesIndex() {
        if let url = URL(string: "https://github.com/\(Updater.owner)/\(Updater.repo)/releases") {
            NSWorkspace.shared.open(url)
        }
    }
}
