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

    private(set) var isManaging = false

    override init() {
        guard let screen = NSScreen.main else { fatalError("no screen") }
        let vf = screen.visibleFrame
        let axFrame = CGRect(
            x: vf.origin.x,
            y: screen.frame.height - vf.maxY,
            width: vf.width,
            height: vf.height
        )
        engine = TeleportEngine(screenFrame: axFrame)
        super.init()

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
        menuBar.refresh()
        print("arranged \(engine.slots.count) windows into strip (\(String(format: "%.1f", engine.lastTeleportMs))ms)")
    }

    func release() {
        guard isManaging else { return }
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

    // MARK: - Hotkeys

    private func installHotkeys() {
        hotkeys.install()
        hotkeys.register(.right) { [weak self] in self?.focusNext() }
        hotkeys.register(.left) { [weak self] in self?.focusPrevious() }
        for (i, key) in HotkeyManager.Key.digits.enumerated() {
            hotkeys.register(key) { [weak self] in self?.focus(index: i) }
        }
        // ctrl+opt+escape: toggle arrange/release (panic switch).
        hotkeys.register(.escape) { [weak self] in self?.toggle() }
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
        statusItem = NSStatusBar.system.statusItem(withLength: 26)
        statusItem.autosaveName = NSStatusItem.AutosaveName(Self.autosaveName)
        statusItem.button?.imageScaling = .scaleNone
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
        statusItem.button?.image = renderIcon()
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

    private func renderIcon() -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let state = engine.stripState
        let managing = controller.isManaging

        return NSImage(size: size, flipped: false) { rect in
            guard managing, !state.slots.isEmpty else {
                // Dormant: subtle strip glyph (2 dashed columns).
                NSColor.secondaryLabelColor.setStroke()
                for i in 0..<2 {
                    let r = NSRect(x: 3 + CGFloat(i) * 9, y: 5, width: 7, height: rect.height - 10)
                    let p = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
                    p.setLineDash([2, 1.5], count: 2, phase: 0)
                    p.lineWidth = 1
                    p.stroke()
                }
                return true
            }

            let canvasMin = state.slots.map { $0.canvasX }.min() ?? 0
            let canvasMax = state.slots.map { $0.canvasX + $0.width }.max() ?? 1
            let viewLeft = state.viewportX
            let viewRight = state.viewportX + state.viewportWidth
            let fullMin = min(canvasMin, viewLeft)
            let span = max(max(canvasMax, viewRight) - fullMin, 1)
            let scale = rect.width / span
            func toIcon(_ x: CGFloat) -> CGFloat { (x - fullMin) * scale }

            for (i, slot) in state.slots.enumerated() {
                let r = NSRect(x: toIcon(slot.canvasX), y: 5,
                               width: max(slot.width * scale - 1, 2), height: rect.height - 10)
                let p = NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5)
                (i == state.focusIndex ? NSColor.controlAccentColor
                    : slot.healthy ? NSColor.secondaryLabelColor
                    : NSColor.systemRed.withAlphaComponent(0.6)).setFill()
                p.fill()
            }

            let vx = toIcon(viewLeft)
            let vw = max((viewRight - viewLeft) * scale, 4)
            let vp = NSBezierPath(roundedRect: NSRect(x: vx, y: 1.5, width: min(vw, rect.width - vx), height: rect.height - 3),
                                  xRadius: 3, yRadius: 3)
            vp.lineWidth = 1.2
            NSColor.labelColor.setStroke()
            vp.stroke()
            return true
        }
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
        } else {
            let header = NSMenuItem(title: "ScrollWM — dormant (not touching any window)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())

            let arrangeItem = NSMenuItem(title: "Arrange Windows into Strip", action: #selector(arrangeAction), keyEquivalent: "")
            arrangeItem.target = self
            menu.addItem(arrangeItem)
        }

        menu.addItem(.separator())
        let help = NSMenuItem(title: "Hotkeys: ⌃⌥←/→ navigate · ⌃⌥1-9 jump · ⌃⌥esc toggle", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)

        let axOK = AXSource.isTrusted
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
    @objc private func quitAction() { controller.quit() }
    @objc private func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// MARK: - Entry

func runScrollWM(selftest: Bool, crashPhase: CrashTestPhase = .none) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    func startController() {
        let controller = ScrollWMController()
        scrollWMControllerKeepAlive = controller
        print("ScrollWM running (dormant). Use the menu bar item or ⌃⌥esc to arrange.")
        if selftest { runScrollWMSelftest(controller: controller) }
        if crashPhase == .crash { runCrashPhase(controller: controller) }
    }

    if AXSource.isTrusted {
        startController()
    } else {
        print("""
        ScrollWM needs Accessibility permission (its only permission).
        Grant it in: System Settings -> Privacy & Security -> Accessibility
        Waiting for grant... (the app will start automatically)
        """)
        _ = AXSource.promptForTrustIfNeeded()

        // Placeholder menu bar presence while waiting: hourglass icon with
        // a menu that deep-links to the Accessibility pane.
        let waitingItem = NSStatusBar.system.statusItem(withLength: 26)
        waitingItem.button?.title = "⏳"
        let waitingMenu = NSMenu()
        let info = NSMenuItem(title: "ScrollWM: waiting for Accessibility permission", action: nil, keyEquivalent: "")
        info.isEnabled = false
        waitingMenu.addItem(info)
        waitingMenu.addItem(NSMenuItem.separator())
        let openSettings = NSMenuItem(title: "Open Accessibility Settings", action: #selector(NSApp.openAccessibilitySettings(_:)), keyEquivalent: "")
        openSettings.target = NSApp
        waitingMenu.addItem(openSettings)
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        waitingMenu.addItem(quit)
        waitingItem.menu = waitingMenu

        // Poll until trusted, then start WITHOUT requiring a relaunch.
        var waited = 0
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
            waited += 2
            if AXSource.isTrusted {
                timer.invalidate()
                NSStatusBar.system.removeStatusItem(waitingItem)
                print("Accessibility granted. Starting.")
                startController()
            } else if waited > 1800 {
                print("No permission after 30 minutes; exiting.")
                exit(2)
            }
        }
    }

    app.run()
}

extension NSApplication {
    @objc func openAccessibilitySettings(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

/// Keeps the controller alive for the app lifetime (created in a closure).
var scrollWMControllerKeepAlive: ScrollWMController?

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
