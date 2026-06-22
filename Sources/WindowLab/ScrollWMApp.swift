import Foundation
import AppKit

/// ScrollWM: the production teleport-tier app.
///
/// Safety model (the "don't break the user's desktop" contract):
///   1. Launches DORMANT: no window is touched until the user invokes Arrange.
///   2. Original frames are captured before any move and persisted to disk.
///   3. Release (menu or hotkey) restores every window exactly.
///   4. Quit restores automatically. SIGINT/SIGTERM restore too.
///   5. After a crash/kill -9, next launch offers recovery from the restore file.
///   6. Accessibility only. No capture, no input monitoring.
final class ScrollWMController: NSObject {
    private var engine: TeleportEngine
    private var lifecycle: LifecycleMonitor?
    private var menuBar: ProductionMenuBar!
    private let hotkeys = HotkeyManager()
    /// Keyboard tap for the move bindings (Cmd+H/L) that Carbon cannot grab.
    private var moveTap: KeyboardEventTap?

    /// Lazily-created tutorial window controller (config-driven cheat sheet).
    private lazy var tutorial = TutorialWindowController(configProvider: { [weak self] in
        self?.config ?? .default
    })

    private(set) var isManaging = false

    /// All user settings, loaded from the config file (single source of truth).
    private(set) var config: ScrollWMConfig

    override init() {
        guard let screen = NSScreen.main else { fatalError("no screen") }
        let vf = screen.visibleFrame
        let axFrame = CGRect(
            x: vf.origin.x,
            y: screen.frame.height - vf.maxY,
            width: vf.width,
            height: vf.height
        )
        config = ScrollWMConfig.load()
        engine = TeleportEngine(screenFrame: axFrame)
        super.init()

        applyConfigToEngine()

        menuBar = ProductionMenuBar(controller: self, engine: engine)
        installHotkeys()
        installSignalHandlers()

        // Crash recovery from a previous unclean exit. Runs in background:
        // recover() retries with sleeps and must not block app startup.
        let pending = RestoreStore.pendingEntries()
        if !pending.isEmpty {
            print("found restore file from previous session (\(pending.count) windows); recovering...")
            DispatchQueue.global(qos: .userInitiated).async {
                let result = RestoreStore.recover()
                print("recovered \(result.restored)/\(result.total) windows from previous session")
            }
        }
    }

    /// Push layout/focus settings from the config into the live engine.
    private func applyConfigToEngine() {
        engine.gap = config.layout.columnGap
        engine.minColumnWidth = config.layout.minColumnWidth
        engine.widthPresets = config.layout.widthPresets
        engine.focusMode = config.focusMode
    }

    /// Re-read the config file and apply it live. Keybindings are reinstalled
    /// so edits take effect without a relaunch. If currently managing, the
    /// strip is re-laid-out so layout changes (gap/width) show immediately.
    func reloadConfig() {
        config = ScrollWMConfig.load()
        applyConfigToEngine()
        // Reinstall global hotkeys with the new chords.
        hotkeys.unregisterAll()
        installHotkeys()
        if isManaging {
            unregisterManagementHotkeys()
            registerManagementHotkeys()
            engine.compactStrip()
            engine.focus(index: engine.focusIndex)
        }
        menuBar.refresh()
        print("config reloaded from \(ScrollWMConfig.fileURL.path)")
    }

    // MARK: - Tutorial / config UX

    /// Show the in-app tutorial window (config-driven cheat sheet).
    func showTutorial() { tutorial.present() }

    /// Open the config file in the user's editor, creating the documented
    /// default first if it doesn't exist yet.
    func openConfigFile() {
        ScrollWMConfig.writeDefaultFileIfMissing()
        NSWorkspace.shared.open(ScrollWMConfig.fileURL)
    }

    /// Auto-show the tutorial exactly once on a genuine first run, so a new
    /// user always learns the basics. Marker lives next to the config.
    func showTutorialOnFirstRunIfNeeded() {
        let marker = ScrollWMConfig.dirURL.appendingPathComponent("tutorial-seen")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try? Data().write(to: marker, options: .atomic)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.showTutorial()
        }
    }

    /// One-line cheat sheet built from the live config, for the menu.
    var cheatSheetLine: String {
        func k(_ a: KeyAction) -> String {
            (config.keybindings[a] ?? KeyAction.defaultChords[a] ?? [])
                .first.map(TutorialWindowController.pretty) ?? "—"
        }
        return "\(k(.focusPrevious))/\(k(.focusNext)) navigate · \(k(.jumpModifier))+1-9 jump · "
            + "\(k(.width25))… width · \(k(.focusLeft))/\(k(.focusRight)) focus · "
            + "\(k(.closeWindow)) close · \(k(.toggleArrange)) toggle"
    }

    // MARK: - Arrange / Release

    func arrange(pidFilter: Set<pid_t>? = nil) {
        guard !isManaging else { return }
        guard LifecycleMonitor.sessionIsActive() else {
            print("arrange: session locked/inactive, refusing")
            return
        }
        let axWindows: [AXWindowInfo]
        if let pidFilter {
            // Direct PID enumeration: works for accessory apps (test windows).
            axWindows = pidFilter.flatMap { pid -> [AXWindowInfo] in
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return [] }
                return AXSource.windows(for: app)
            }
        } else {
            axWindows = AXSource.allWindows()
        }
        let matched = IdentityMatcher.match(
            axWindows: axWindows,
            cgWindows: CGWindowSource.listWindows(onscreenOnly: true)
        )
        // Only adopt windows that are actually onscreen (current Space):
        // offscreen AX windows belong to other Spaces; moving them would
        // surprise the user later.
        let onscreen = matched.filter { $0.cg != nil }
        engine.adopt(matched: onscreen)
        guard !engine.slots.isEmpty else {
            print("arrange: no manageable windows found")
            return
        }
        RestoreStore.save(engine: engine)
        isManaging = true

        let monitor = LifecycleMonitor(engine: engine)
        monitor.pidFilter = pidFilter
        monitor.onChange = { [weak self] _, _ in
            guard let self else { return }
            RestoreStore.save(engine: self.engine)
        }
        monitor.start()
        lifecycle = monitor

        engine.focus(index: 0)
        registerManagementHotkeys()
        menuBar.refresh()
        print("arranged \(engine.slots.count) windows into strip (\(String(format: "%.1f", engine.lastTeleportMs))ms)")
    }

    func release() {
        guard isManaging else { return }
        unregisterManagementHotkeys()
        lifecycle?.stop()
        lifecycle = nil
        let failures = engine.releaseAll()
        RestoreStore.clear()
        isManaging = false
        menuBar.refresh()
        print("released: all windows restored\(failures > 0 ? " (\(failures) failures)" : "")")
    }

    func toggle() {
        isManaging ? release() : arrange()
    }

    func quit() {
        release()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Navigation passthrough

    func focusNext() { if isManaging { engine.focusNext() } }
    func focusPrevious() { if isManaging { engine.focusPrevious() } }
    func focus(index: Int) { if isManaging { engine.focus(index: index) } }

    // MARK: - Window operations passthrough

    /// Resize focused column to a width preset (width keys -> presets[i]).
    func setWidthPreset(_ index: Int) {
        guard isManaging, engine.widthPresets.indices.contains(index) else { return }
        engine.setFocusedWidth(fraction: engine.widthPresets[index])
        menuBar.refresh()
    }
    /// Move focused column left/right within the strip (Cmd+H / Cmd+L).
    func moveFocused(by delta: Int) {
        if isManaging { engine.moveFocused(by: delta); menuBar.refresh() }
    }
    /// Close the focused window (Cmd+Q).
    func closeFocused() {
        if isManaging { engine.closeFocused(); menuBar.refresh() }
    }

    // MARK: - Focus mode

    var focusMode: TeleportEngine.FocusMode { engine.focusMode }

    /// Switch how the viewport follows focus (centered vs fit) and persist it
    /// to the config file (the single source of truth).
    func setFocusMode(_ mode: TeleportEngine.FocusMode) {
        engine.focusMode = mode
        config.focusMode = mode
        config.save()
        // Re-apply to the current focus so the change is visible immediately.
        if isManaging { engine.focus(index: engine.focusIndex) }
        menuBar.refresh()
    }

    // MARK: - Debug accessors (for the e2e keybinding test)

    var debugSlotCount: Int { engine.slots.count }
    var debugSlotTitles: [String] { engine.slots.map { $0.window.title } }
    var debugFocusIndex: Int { engine.focusIndex }
    var debugFocusedTitle: String {
        engine.slots.indices.contains(engine.focusIndex) ? engine.slots[engine.focusIndex].window.title : ""
    }
    var debugFocusedWidth: CGFloat {
        engine.slots.indices.contains(engine.focusIndex) ? engine.slots[engine.focusIndex].width : 0
    }
    func debugWidth(forFraction f: CGFloat) -> CGFloat { engine.width(forFraction: f) }

    // MARK: - Hotkeys

    /// Install the always-on global hotkeys (navigation, jump, toggle) from the
    /// config's chords via permission-free Carbon hotkeys.
    private func installHotkeys() {
        hotkeys.install()

        for chord in config.chords(for: .focusNext) where chord.hasKey {
            hotkeys.registerRaw(keyCode: chord.keyCode, modifiers: chord.carbonModifiers) { [weak self] in self?.focusNext() }
        }
        for chord in config.chords(for: .focusPrevious) where chord.hasKey {
            hotkeys.registerRaw(keyCode: chord.keyCode, modifiers: chord.carbonModifiers) { [weak self] in self?.focusPrevious() }
        }
        for chord in config.chords(for: .toggleArrange) where chord.hasKey {
            hotkeys.registerRaw(keyCode: chord.keyCode, modifiers: chord.carbonModifiers) { [weak self] in self?.toggle() }
        }
        // Jump: the modifier-only `jumpModifier` chord + digit keys 1-9.
        if let jump = config.chords(for: .jumpModifier).first {
            for (i, key) in HotkeyManager.Key.digits.enumerated() {
                hotkeys.registerRaw(keyCode: key.rawValue, modifiers: jump.carbonModifiers) { [weak self] in self?.focus(index: i) }
            }
        }
    }

    /// Hotkeys that only make sense while managing, and that would otherwise
    /// shadow system shortcuts (e.g. Cmd+Q quit, Cmd+H hide). Registered on
    /// Arrange, torn down on Release so the desktop behaves normally when
    /// dormant. All of these ride the keyboard tap (see `registerManagementHotkeys`).
    private func registerManagementHotkeys() {
        guard moveTap == nil else { return }
        let tap = KeyboardEventTap()

        // All management chords ride the keyboard tap. The tap is head-insert
        // in the session and active only while managing, so it intercepts
        // every chord ahead of apps and suppresses it — including the ones
        // Carbon cannot deliver: Cmd+H/Cmd+M (macOS-reserved) and Cmd+digit
        // (claimed by the frontmost app). Using one channel for all management
        // keys keeps behavior uniform and rebindable to any chord. It works
        // with the Accessibility permission we already hold (verified via
        // `keytapprobe`); no extra permission. Dormant => no tap => the desktop
        // behaves normally (Cmd+Q quits, Cmd+H hides).
        func bind(_ action: KeyAction, _ handler: @escaping () -> Void) {
            for chord in config.chords(for: action) where chord.hasKey {
                tap.addCombo(keyCode: Int64(chord.keyCode), flags: chord.cgFlags, handler: handler)
            }
        }

        let widthActions: [KeyAction] = [.width25, .width50, .width75, .width100]
        for (i, action) in widthActions.enumerated() {
            bind(action) { [weak self] in self?.setWidthPreset(i) }
        }
        bind(.closeWindow) { [weak self] in self?.closeFocused() }
        bind(.focusLeft) { [weak self] in self?.focusPrevious() }
        bind(.focusRight) { [weak self] in self?.focusNext() }
        bind(.moveColumnLeft) { [weak self] in self?.moveFocused(by: -1) }
        bind(.moveColumnRight) { [weak self] in self?.moveFocused(by: 1) }

        if tap.start() {
            moveTap = tap
        } else {
            print("warning: could not start keyboard tap; management keys disabled")
        }
    }

    private func unregisterManagementHotkeys() {
        moveTap?.stop()
        moveTap = nil
    }

    // MARK: - Clean shutdown on signals

    private func installSignalHandlers() {
        // dispatch sources are safe (signal handlers proper cannot call AX).
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                print("\nsignal received: restoring windows and exiting")
                self?.release()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
    private var signalSources: [DispatchSourceSignal] = []
}

// MARK: - Production menu bar

final class ProductionMenuBar: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private unowned let controller: ScrollWMController
    private let engine: TeleportEngine

    /// High-refresh animated mini-map hosted inside the status button.
    private let stripView = MenuBarStripView(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
    /// Status item width: a touch wider than the old 26 to give the animation
    /// breathing room while still fitting crowded/notched menu bars.
    static let itemWidth: CGFloat = 30

    static let autosaveName = "ScrollWMMain"

    init(controller: ScrollWMController, engine: TeleportEngine) {
        self.controller = controller
        self.engine = engine
        super.init()

        // Notch workaround (see MenuBarController).
        let positionKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(400.0, forKey: positionKey)
        }

        createStatusItem()

        // Self-healing placement: on crowded/notched menu bars macOS silently
        // parks items that don't fit (frame.x < 0). Detect and walk candidate
        // positions until visible. Each retry recreates the item, because the
        // preferred position is only read at creation time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.ensureVisible()
        }

        engine.onLayoutChange = { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    private func createStatusItem() {
        // Compact width: crowded menu bars may have very little free space.
        statusItem = NSStatusBar.system.statusItem(withLength: Self.itemWidth)
        statusItem.autosaveName = NSStatusItem.AutosaveName(Self.autosaveName)

        // Host the high-refresh animated mini-map inside the status button. The
        // view is click-through (hitTest -> nil) so the button still receives
        // clicks and opens the menu; the image stays nil so only our view draws.
        if let button = statusItem.button {
            button.image = nil
            button.title = ""
            stripView.removeFromSuperview()
            stripView.frame = button.bounds
            stripView.autoresizingMask = [.width, .height]
            button.addSubview(stripView)
        }
        refresh()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private var healAttempt = 0
    private func ensureVisible() {
        guard !isVisibleInMenuBar else {
            if healAttempt > 0 {
                print("menubar: item visible after \(healAttempt) placement attempt(s)")
            }
            return
        }
        // Candidate preferred positions (points from the right edge area);
        // small values sit near the system cluster which is always visible.
        let candidates: [Double] = [150, 200, 250, 100, 300, 350, 50, 450]
        guard healAttempt < candidates.count else {
            print("menubar: could not find visible slot (menu bar full). Use ⌃⌥esc to toggle; the app still works.")
            return
        }
        let position = candidates[healAttempt]
        healAttempt += 1

        NSStatusBar.system.removeStatusItem(statusItem)
        UserDefaults.standard.set(position, forKey: "NSStatusItem Preferred Position \(Self.autosaveName)")
        createStatusItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.ensureVisible()
        }
    }

    func refresh() {
        // Feed the live engine state into the animated view; it diffs against
        // the previous state and animates the change at the display's refresh
        // rate, then idles its display link once everything settles.
        stripView.apply(state: engine.stripState, managing: controller.isManaging)
    }

    var isVisibleInMenuBar: Bool {
        guard statusItem.isVisible, let window = statusItem.button?.window else { return false }
        let frame = window.frame // AppKit coords, bottom-left origin
        guard frame.width > 0, frame.origin.x >= 0 else { return false }
        // On notched displays, real status items live RIGHT of the notch.
        // Parked items get placed at the far left (x near 0) or offscreen.
        if let screen = NSScreen.main, let right = screen.auxiliaryTopRightArea {
            return frame.origin.x >= right.minX
        }
        return true
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let managing = controller.isManaging

        if managing {
            let state = engine.stripState
            let header = NSMenuItem(
                title: String(format: "Managing %d windows · teleport %.1f ms", state.slots.count, state.lastTeleportMs),
                action: nil, keyEquivalent: ""
            )
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())

            for (i, slot) in state.slots.enumerated() {
                let inViewport = slot.canvasX + slot.width > state.viewportX
                    && slot.canvasX < state.viewportX + state.viewportWidth
                let marker = i == state.focusIndex ? "● " : (inViewport ? "○ " : "   ")
                let item = NSMenuItem(
                    title: String("\(marker)\(slot.appName) — \(slot.title)".prefix(60)),
                    action: #selector(selectWindow(_:)),
                    keyEquivalent: i < 9 ? "\(i + 1)" : ""
                )
                item.keyEquivalentModifierMask = [.control, .option]
                item.target = self
                item.tag = i
                menu.addItem(item)
            }
            menu.addItem(.separator())

            let releaseItem = NSMenuItem(title: "Release Windows (restore original positions)", action: #selector(releaseAction), keyEquivalent: "")
            releaseItem.target = self
            menu.addItem(releaseItem)

            let arrangeItem = NSMenuItem(title: "Arrange Windows into Strip", action: nil, keyEquivalent: "")
            arrangeItem.isEnabled = false // already managing
            menu.addItem(arrangeItem)
        } else {
            let header = NSMenuItem(title: "ScrollWM — dormant (not touching any window)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())

            let arrangeItem = NSMenuItem(title: "Arrange Windows into Strip", action: #selector(arrangeAction), keyEquivalent: "")
            arrangeItem.target = self
            menu.addItem(arrangeItem)

            let releaseItem = NSMenuItem(title: "Release Windows (restore original positions)", action: nil, keyEquivalent: "")
            releaseItem.isEnabled = false // nothing to release while dormant
            menu.addItem(releaseItem)
        }

        // Focus mode submenu (Centered vs Fit).
        menu.addItem(.separator())
        let focusModeItem = NSMenuItem(title: "Focus Follows: \(controller.focusMode.label)", action: nil, keyEquivalent: "")
        let focusSubmenu = NSMenu()
        for mode in TeleportEngine.FocusMode.allCases {
            let mi = NSMenuItem(title: mode.label, action: #selector(setFocusModeAction(_:)), keyEquivalent: "")
            mi.target = self
            mi.state = (controller.focusMode == mode) ? .on : .off
            mi.representedObject = mode.rawValue
            focusSubmenu.addItem(mi)
        }
        focusModeItem.submenu = focusSubmenu
        menu.addItem(focusModeItem)


        menu.addItem(.separator())

        // Help + settings (config-file only). The cheat sheet line is built
        // from the live config so it always matches the real bindings.
        let help = NSMenuItem(title: controller.cheatSheetLine, action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)

        let tutorial = NSMenuItem(title: "How to Use ScrollWM…", action: #selector(showTutorial), keyEquivalent: "")
        tutorial.target = self
        menu.addItem(tutorial)

        let openConfig = NSMenuItem(title: "Open Config File", action: #selector(openConfigFile), keyEquivalent: "")
        openConfig.target = self
        menu.addItem(openConfig)

        let reload = NSMenuItem(title: "Reload Config", action: #selector(reloadConfigAction), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)

        let axOK = AccessibilityPermission.shared.state.isGranted
        let perm = NSMenuItem(title: axOK ? "Accessibility: granted ✓" : "Accessibility: MISSING — click to open Settings",
                              action: axOK ? nil : #selector(openAXSettings), keyEquivalent: "")
        perm.target = self
        perm.isEnabled = !axOK
        menu.addItem(perm)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit ScrollWM (restores windows)", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func selectWindow(_ sender: NSMenuItem) { controller.focus(index: sender.tag) }
    @objc private func arrangeAction() { controller.arrange() }
    @objc private func releaseAction() { controller.release() }
    @objc private func setFocusModeAction(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let mode = TeleportEngine.FocusMode(rawValue: raw) {
            controller.setFocusMode(mode)
        }
    }
    @objc private func quitAction() { controller.quit() }
    @objc private func openAXSettings() {
        AccessibilityPermission.shared.openSystemSettings()
    }
    @objc private func showTutorial() { controller.showTutorial() }
    @objc private func openConfigFile() { controller.openConfigFile() }
    @objc private func reloadConfigAction() { controller.reloadConfig() }
}

// MARK: - Entry

func runScrollWM(selftest: Bool, crashPhase: CrashTestPhase = .none) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    func startController() {
        let controller = ScrollWMController()
        scrollWMControllerKeepAlive = controller
        print("ScrollWM running (dormant). Use the menu bar item or the toggle key to arrange.")
        controller.showTutorialOnFirstRunIfNeeded()
        if selftest { runScrollWMSelftest(controller: controller) }
        if crashPhase == .crash { runCrashPhase(controller: controller) }
    }

    // Single source of truth for the Accessibility permission. It debounces the
    // stale-`false` reading that `AXIsProcessTrusted()` returns right after
    // launch, so a granted machine starts silently — no waiting UI, no prompt.
    // Only after the grace window, if still genuinely untrusted, do we show the
    // onboarding window. Once granted (now or later, with no relaunch), the
    // controller starts automatically.
    // onboarding window/controller (created lazily below).
    var started = false
    func startOnce() {
        guard !started else { return }
        started = true
        startController()
    }

    AccessibilityPermission.shared.resolveAtLaunch { state in
        if state == .granted {
            startOnce()
            return
        }
        print("""
        ScrollWM needs Accessibility permission (its only permission).
        Grant it in: System Settings -> Privacy & Security -> Accessibility
        Waiting for grant... (the app will start automatically)
        """)
        let ob = OnboardingWindowController()
        ob.onGranted = { startOnce() }
        ob.present()
        onboardingKeepAlive = ob
    }

    app.run()
}

/// Keep app-lifetime objects created inside closures from being deallocated.
var scrollWMControllerKeepAlive: ScrollWMController?
var onboardingKeepAlive: OnboardingWindowController?

enum CrashTestPhase { case none, crash }

/// Scripted real-window validation: snapshot -> arrange -> release -> verify.
/// The only WindowLab mode that touches the user's real windows, and it
/// holds them for ~3 seconds before exact restore.
func runCycleTest() {
    guard AXSource.isTrusted else {
        print("needs Accessibility")
        exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let controller = ScrollWMController()

    DispatchQueue.global().async {
        Thread.sleep(forTimeInterval: 0.5)

        // Snapshot real window frames before.
        func snapshot() -> [(pid: pid_t, title: String, frame: CGRect)] {
            AXSource.allWindows()
                .filter { $0.subrole == kAXStandardWindowSubrole as String && !$0.isMinimized && !$0.isFullscreen }
                .map { ($0.pid, $0.title ?? "", $0.frame) }
                .sorted { ($0.pid, $0.title) < ($1.pid, $1.title) }
        }
        let before = snapshot()
        print("[cycle] \(before.count) real windows before arrange")

        print("[cycle] arranging real windows...")
        DispatchQueue.main.sync { controller.arrange() }
        Thread.sleep(forTimeInterval: 1.0)

        print("[cycle] navigating strip...")
        DispatchQueue.main.sync { controller.focusNext() }
        Thread.sleep(forTimeInterval: 0.5)
        DispatchQueue.main.sync { controller.focusPrevious() }
        Thread.sleep(forTimeInterval: 0.5)

        print("[cycle] releasing...")
        DispatchQueue.main.sync { controller.release() }
        Thread.sleep(forTimeInterval: 1.0)

        let after = snapshot()
        var mismatches = 0
        for b in before {
            guard let a = after.first(where: { $0.pid == b.pid && $0.title == b.title }) else {
                print("[cycle] MISSING after: \(b.title)")
                mismatches += 1
                continue
            }
            if abs(a.frame.origin.x - b.frame.origin.x) > 2 || abs(a.frame.origin.y - b.frame.origin.y) > 2
                || abs(a.frame.width - b.frame.width) > 2 || abs(a.frame.height - b.frame.height) > 2 {
                print("[cycle] MISMATCH \(b.title): \(b.frame) -> \(a.frame)")
                mismatches += 1
            }
        }
        print("[cycle] verified \(before.count - mismatches)/\(before.count) windows restored exactly")
        exit(mismatches == 0 ? 0 : 1)
    }

    app.run()
}

/// Phase 1 of the crash-recovery test: spawn DETACHED test windows (they
/// outlive us), arrange them, then SIGKILL ourselves mid-management.
/// Phase 2 is just launching `run` again: the controller recovers on init.
private func runCrashPhase(controller: ScrollWMController) {
    DispatchQueue.global().async {
        Thread.sleep(forTimeInterval: 1.0)
        print("[crashtest] spawning detached test windows...")
        let exe = CommandLine.arguments[0]
        var pids: Set<pid_t> = []
        for (i, x) in [100.0, 550.0, 1000.0].enumerated() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["testwindow", "\(x)", "250", "380", "280", "CrashTest-\(i)"]
            try? p.run()
            pids.insert(p.processIdentifier)
        }
        Thread.sleep(forTimeInterval: 1.5)

        print("[crashtest] arranging...")
        DispatchQueue.main.sync { controller.arrange(pidFilter: pids) }
        Thread.sleep(forTimeInterval: 0.3)
        print("[crashtest] restore file: \(FileManager.default.fileExists(atPath: RestoreStore.fileURL.path))")
        print("[crashtest] SIGKILL self NOW (windows are displaced; relaunch must recover)")
        kill(getpid(), SIGKILL)
    }
}

/// Production round trip: spawn windows -> arrange -> navigate -> verify
/// restore-file exists -> release -> verify windows back at original frames.
private func runScrollWMSelftest(controller: ScrollWMController) {
    DispatchQueue.global().async {
        Thread.sleep(forTimeInterval: 1.0)
        print("[selftest] spawning 4 test windows...")
        let spawned = spawnTestWindows(count: 4)
        Thread.sleep(forTimeInterval: 1.5)

        // Capture pre-arrange frames of the test windows.
        let pids = Set(spawned.map { $0.processIdentifier })
        func testFrames() -> [CGRect] {
            pids.flatMap { pid -> [CGRect] in
                guard let app = NSRunningApplication(processIdentifier: pid) else { return [] }
                return AXSource.windows(for: app).map { $0.frame }
            }.sorted { ($0.origin.x, $0.origin.y) < ($1.origin.x, $1.origin.y) }
        }
        let before = testFrames()

        print("[selftest] arrange (scoped to test windows only)...")
        DispatchQueue.main.sync { controller.arrange(pidFilter: pids) }
        Thread.sleep(forTimeInterval: 0.5)

        let restoreExists = FileManager.default.fileExists(atPath: RestoreStore.fileURL.path)
        print("[selftest] restore file exists: \(restoreExists)")

        print("[selftest] navigating...")
        for i in 0..<6 {
            DispatchQueue.main.sync { controller.focus(index: i % 4) }
            Thread.sleep(forTimeInterval: 0.2)
        }

        print("[selftest] release...")
        DispatchQueue.main.sync { controller.release() }
        Thread.sleep(forTimeInterval: 0.8)

        let after = testFrames()
        let restoreCleared = !FileManager.default.fileExists(atPath: RestoreStore.fileURL.path)

        var framesMatch = before.count == after.count
        if framesMatch {
            for (b, a) in zip(before, after) {
                if abs(b.origin.x - a.origin.x) > 2 || abs(b.origin.y - a.origin.y) > 2
                    || abs(b.width - a.width) > 2 || abs(b.height - a.height) > 2 {
                    framesMatch = false
                    print("[selftest] MISMATCH: \(b) -> \(a)")
                }
            }
        }

        print("""
        [selftest] results:
          restore file written:   \(restoreExists)
          restore file cleared:   \(restoreCleared)
          frames restored exactly: \(framesMatch) (\(before.count) windows)
        """)
        for p in spawned { p.terminate() }
        exit(restoreExists && restoreCleared && framesMatch ? 0 : 1)
    }
}
