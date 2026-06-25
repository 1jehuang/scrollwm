import Foundation
import AppKit

/// Glue between the pure `Updater` and the running app: schedules background
/// checks, persists "last checked" / "skipped version" so we don't nag, and
/// presents the user-facing prompts (or installs silently when configured).
///
/// Lifecycle: the controller creates one after launch (`startUpdates`) and
/// reconfigures it on config reload. It is a no-op when `config.update.enabled`
/// is false, except for explicit, user-initiated checks (menu / CLI), which
/// always work.
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

    /// Persisted, tiny state so we don't recheck too often or re-nag about a
    /// version the user chose to skip.
    private struct State: Codable {
        var lastCheck: Date?
        var skippedVersion: String?
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

    /// Background check: only prompts when there's a not-skipped update.
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
                if !userInitiated, self.state.skippedVersion == release.version.description {
                    return  // user asked us not to nag about this one
                }
                if self.config.automatic {
                    self.beginInstall(release, announce: true)
                } else {
                    self.presentUpdatePrompt(release, current: cur)
                }
            case .success(.noUsableAsset):
                if userInitiated { self.presentUpToDate(current: AppVersion.current) }
            case .failure(let err):
                if userInitiated { self.presentError(err) }
                else { print("update: background check failed: \(err.localizedDescription)") }
            }
        }
    }

    // MARK: - Install

    /// Download + verify + stage, then swap and relaunch. When `announce` is
    /// true (automatic mode) a brief heads-up is shown before relaunch.
    func beginInstall(_ release: ReleaseInfo, announce: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            // Dev binary: can't self-replace. Point the user at the page.
            presentDevCannotInstall(release)
            return
        }
        isBusy = true
        updater.downloadAndStage(release) { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            switch result {
            case .success(let stagedApp):
                self.swapAndRelaunch(stagedApp: stagedApp, release: release, announce: announce)
            case .failure(let err):
                self.presentError(err)
            }
        }
    }

    private func swapAndRelaunch(stagedApp: URL, release: ReleaseInfo, announce: Bool) {
        do {
            try updater.installAndRelaunch(stagedApp: stagedApp)
        } catch {
            presentError((error as? UpdateError) ?? .installFailed(error.localizedDescription))
            return
        }
        if announce {
            // Brief, non-blocking heads-up so an automatic update isn't a
            // surprise relaunch. (Kept simple: no UserNotifications entitlement.)
            print("update: installing v\(release.version); ScrollWM will restore windows and relaunch")
        }
        // Quit cleanly so windows are restored before the swapper takes over.
        // A short delay lets the detached swapper get scheduled first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.controller?.quit()
        }
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
            beginInstall(release, announce: false)
        case .alertSecondButtonReturn:
            if let url = URL(string: release.htmlURL.isEmpty
                             ? "https://github.com/\(Updater.owner)/\(Updater.repo)/releases"
                             : release.htmlURL) {
                NSWorkspace.shared.open(url)
            }
            // Re-prompt next cycle; treat "view" as "later".
        case .alertThirdButtonReturn:
            state.skippedVersion = release.version.description
            saveState()
        default:
            break  // Later
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
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = err.localizedDescription
            + "\n\nYou can always download the latest from GitHub."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Releases")
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "https://github.com/\(Updater.owner)/\(Updater.repo)/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentDevCannotInstall(_ release: ReleaseInfo) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Update available: \(release.version)"
        alert.informativeText = "This is a development build, so it won't replace "
            + "itself. Pull + rebuild, or download the release from GitHub."
        alert.addButton(withTitle: "Open Releases")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: release.htmlURL.isEmpty
                         ? "https://github.com/\(Updater.owner)/\(Updater.repo)/releases"
                         : release.htmlURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
