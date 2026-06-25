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
    /// CLI control plane (Unix socket). Started only by the production `run`
    /// path via `startControlServer()`; sandbox/tests never expose it.
    private var controlServer: ControlServer?
    /// Keyboard tap for the move bindings (Cmd+H/L) that Carbon cannot grab.
    private var moveTap: KeyboardEventTap?

    /// Pending coalesced re-evaluation of a display change. macOS fires
    /// `didChangeScreenParameters` SEVERAL times in quick succession for a
    /// single hotplug / resolution change (each intermediate arrangement is its
    /// own event). We debounce the burst into one re-bind from the SETTLED
    /// geometry, so the strip never thrashes through every transient layout.
    private var displayChangeDebounce: DispatchWorkItem?
    /// Debounce window for `screenParametersChanged`: long enough to swallow a
    /// hotplug burst, short enough to feel instant.
    private let displayChangeDebounceInterval: TimeInterval = 0.25

    /// Lazily-created tutorial window controller (config-driven cheat sheet).
    private lazy var tutorial = TutorialWindowController(configProvider: { [weak self] in
        self?.config ?? .default
    })

    private(set) var isManaging = false

    /// Sandbox lock. When set, the controller can ONLY ever adopt/manage these
    /// PIDs: `toggle()` and the menu/hotkey arrange path force this filter, so
    /// no code path can touch the user's real windows. Used by `sandbox` mode
    /// (spawned disposable windows) to test safely against a live session.
    var sandboxPIDs: Set<pid_t>?

    /// All user settings, loaded from the config file (single source of truth).
    private(set) var config: ScrollWMConfig

    override init() {
        guard NSScreen.main != nil else { fatalError("no screen") }
        config = ScrollWMConfig.load()
        // [md-select] Bind the strip to the display the user configured
        // (layout.stripDisplay), defaulting to NSScreen.main. Falls back to main
        // if the spec is unknown / out of range.
        let screen = Self.screen(forSpec: config.layout.stripDisplay) ?? NSScreen.main!
        let vf = screen.visibleFrame
        let axFrame = CGRect(
            x: vf.origin.x,
            y: screen.frame.height - vf.maxY,
            width: vf.width,
            height: vf.height
        )
        engine = TeleportEngine(screenFrame: axFrame)
        super.init()

        applyConfigToEngine()
        refreshDisplayGeometry(stripDisplay: screen)

        // Keep parking display-aware across monitor hotplug / rearrange.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

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
        engine.spawnWidthFraction = config.layout.spawnWidth
        engine.focusMode = config.focusMode
        engine.adoptScope = config.layout.adoptScope
    }

    /// Feed the multi-display layout (in AX top-left global coordinates) to the
    /// engine so its off-screen "parking corner" lands the unavoidable ~40px
    /// macOS clamp sliver on the STRIP's own display, never on a neighbor
    /// monitor, AND keep the strip's own layout frame in sync with the live
    /// geometry of the display it lives on (resolution/scale/arrangement change).
    ///
    /// AX global coords share one plane with the origin at the PRIMARY display's
    /// top-left and Y growing downward; `DisplayGeometry.axFrame` does the flip
    /// around the primary display's height.
    ///
    /// When `relayout` is true and we are managing, the strip is re-bound to the
    /// new visible frame and every window is relaid out onto it (handles the
    /// laptop-panel <-> external resolution mismatch). Pass false during initial
    /// setup, before any window is adopted.
    private func refreshDisplayGeometry(stripDisplay: NSScreen, relayout: Bool = false) {
        // The primary display is the one whose frame origin is (0,0) in AppKit.
        // Its height defines the Y-flip used across the whole AX coordinate plane.
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.main ?? stripDisplay).frame.height
        func axFull(_ s: NSScreen) -> CGRect {
            DisplayGeometry.axFrame(appKitFrame: s.frame, primaryHeight: primaryHeight)
        }
        func axVisible(_ s: NSScreen) -> CGRect {
            DisplayGeometry.axFrame(appKitFrame: s.visibleFrame, primaryHeight: primaryHeight)
        }
        engine.stripDisplayFrame = axFull(stripDisplay)
        engine.otherDisplayFrames = NSScreen.screens
            .filter { $0 !== stripDisplay }
            .map(axFull)

        // Re-bind the strip's own usable area to the live visible frame so a
        // resolution/scale change (or the strip moving displays) relays the
        // whole strip onto the new geometry instead of leaving stale coords.
        let visible = axVisible(stripDisplay)
        if relayout && isManaging {
            engine.rebindStripDisplay(to: visible)
            RestoreStore.save(engine: engine)
            menuBar.refresh()
        }
    }

    /// Re-evaluate the display layout when monitors are plugged/unplugged or
    /// rearranged. macOS fires this several times for one physical change, so we
    /// DEBOUNCE the burst and act once on the settled geometry.
    @objc private func screenParametersChanged() {
        displayChangeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applySettledDisplayChange()
        }
        displayChangeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + displayChangeDebounceInterval,
                                      execute: work)
    }

    /// Decide where the strip should live after a (debounced) display change and
    /// re-bind to it. Handles the catastrophic case where the strip's OWN
    /// display was unplugged: `StripDisplayResolver` detects that no surviving
    /// display still overlaps the strip and MIGRATES the strip to the best
    /// survivor, rescuing windows that would otherwise be orphaned off-screen.
    /// A display being ADDED back is the same code path: it simply becomes a
    /// candidate the resolver may pick (or, more often, leaves the strip put).
    private func applySettledDisplayChange() {
        let screens = NSScreen.screens
        // No screens at all (all monitors asleep/disconnected): keep the last
        // geometry untouched until one reappears (resolver case 3).
        guard !screens.isEmpty else { return }

        let primaryHeight = (screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.main ?? screens[0]).frame.height
        // Visible AX frames of every available display, parallel to `screens`.
        let visibleFrames = screens.map {
            DisplayGeometry.axFrame(appKitFrame: $0.visibleFrame, primaryHeight: primaryHeight)
        }

        // Pure policy: same display (resized) -> follow it; strip display gone
        // -> migrate to the best survivor; no displays -> keep put.
        let decision = StripDisplayResolver.resolve(
            stripFrame: engine.screenFrame, displays: visibleFrames)
        guard let idx = decision.displayIndex else { return }

        if decision.migrated {
            print("display change: strip's display gone; migrating strip to "
                  + "\(screens[idx].localizedName)")
        }
        refreshDisplayGeometry(stripDisplay: screens[idx], relayout: true)
    }

    // MARK: - Strip display selection ([md-select])

    /// Map `NSScreen.screens` (the order CLI/config indices reference) to the
    /// pure `DisplaySelector.DisplayInfo` view of them, tagging which is `main`
    /// (active display) and which is `primary` (AppKit origin). Keeping the
    /// AppKit -> pure conversion in one place lets `DisplaySelector.pick` stay
    /// unit-testable while production and tests agree on the policy.
    private static func displayInfos() -> [DisplaySelector.DisplayInfo] {
        let main = NSScreen.main
        return NSScreen.screens.map { s in
            DisplaySelector.DisplayInfo(
                frame: s.frame,
                isMain: s === main,
                isPrimary: s.frame.origin == .zero)
        }
    }

    /// Resolve a strip-display spec ("main"/"primary"/"largest"/"next"/index) to
    /// a concrete `NSScreen`, or nil when the spec is unknown / out of range.
    /// `current` is the strip's present display index, used only by `"next"`.
    private static func screen(forSpec spec: String, current: Int? = nil) -> NSScreen? {
        guard let idx = DisplaySelector.pick(spec: spec, displays: displayInfos(), current: current),
              NSScreen.screens.indices.contains(idx) else { return nil }
        return NSScreen.screens[idx]
    }

    /// Index (into `NSScreen.screens`) of the display the strip currently lives
    /// on, by maximum overlap with the engine's live AX frame. nil if it cannot
    /// be identified. Drives the `"next"` cycle so it advances from where we are.
    private func currentStripDisplayIndex() -> Int? {
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.main)?.frame.height ?? engine.screenFrame.height
        let target = engine.screenFrame
        var best: Int?
        var bestArea: CGFloat = -1
        for (i, s) in NSScreen.screens.enumerated() {
            let f = DisplayGeometry.axFrame(appKitFrame: s.visibleFrame, primaryHeight: primaryHeight)
            let a = DisplayGeometry.overlapArea(target, f)
            if a > bestArea { bestArea = a; best = i }
        }
        return best
    }

    /// Move the scrolling strip to another monitor at runtime. `spec` is
    /// "next"/"main"/"primary"/"largest"/index. Re-identifies the target
    /// `NSScreen`, rebinds the engine to its visible AX frame and relays every
    /// managed window onto it (display-aware parking is refreshed too). Returns a
    /// one-line, human-readable result for the control reply / CLI.
    @discardableResult
    func moveStripToDisplay(_ spec: String) -> String {
        let current = currentStripDisplayIndex()
        guard let idx = DisplaySelector.pick(spec: spec, displays: Self.displayInfos(), current: current),
              NSScreen.screens.indices.contains(idx) else {
            return "error: no such display '\(spec)' (use next|main|primary|largest|1-\(NSScreen.screens.count))"
        }
        let target = NSScreen.screens[idx]
        // Relayout only matters while managing; when dormant we just re-bind the
        // engine's geometry so the next arrange lands on the chosen display.
        refreshDisplayGeometry(stripDisplay: target, relayout: isManaging)
        if !isManaging {
            // Dormant: refreshDisplayGeometry skips the rebind, so do it here so a
            // subsequent arrange uses the new display's visible frame.
            let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                                 ?? NSScreen.main ?? target).frame.height
            engine.rebindStripDisplay(to: DisplayGeometry.axFrame(
                appKitFrame: target.visibleFrame, primaryHeight: primaryHeight))
        }
        menuBar.refresh()
        let name = target.localizedName
        return "ok: strip on display \(idx + 1) (\(name))\(isManaging ? ", \(engine.slots.count) windows relaid" : "")"
    }

    /// Snapshot of the connected displays for the menu / status: (1-based index,
    /// name, isCurrentStrip).
    func displayChoices() -> [(index: Int, name: String, isStrip: Bool)] {
        let cur = currentStripDisplayIndex()
        return NSScreen.screens.enumerated().map { (i, s) in
            (index: i + 1, name: s.localizedName, isStrip: i == cur)
        }
    }

    /// Bind the strip to a SPECIFIC display (its visible frame becomes the
    /// strip's usable area; its full frame the parking reference; every other
    /// screen the "other" set). Unlike `refreshDisplayGeometry`, this updates the
    /// strip's own `screenFrame` even when dormant, so a caller can place the
    /// strip on a chosen monitor BEFORE arranging (used by `sandbox --display N`
    /// to run the whole sandbox on an external screen). Relays any already-
    /// managed windows onto the new geometry.
    func bindStripToDisplay(_ stripDisplay: NSScreen) {
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.main ?? stripDisplay).frame.height
        func axFull(_ s: NSScreen) -> CGRect {
            DisplayGeometry.axFrame(appKitFrame: s.frame, primaryHeight: primaryHeight)
        }
        engine.stripDisplayFrame = axFull(stripDisplay)
        engine.otherDisplayFrames = NSScreen.screens.filter { $0 !== stripDisplay }.map(axFull)
        // rebindStripDisplay sets `screenFrame` and relays; on an empty strip the
        // relay is a no-op, so this safely repositions the strip pre-arrange.
        engine.rebindStripDisplay(
            to: DisplayGeometry.axFrame(appKitFrame: stripDisplay.visibleFrame, primaryHeight: primaryHeight)
        )
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
        menuBar.applyConfig(config)
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
        // Sandbox lock takes precedence: if a sandbox PID set is configured, the
        // controller may ONLY ever see those PIDs, no matter how arrange was
        // invoked (menu, hotkey, or direct call). This guarantees the user's
        // real windows are never enumerated or moved while sandboxing.
        let effectiveFilter = sandboxPIDs ?? pidFilter
        let axWindows: [AXWindowInfo]
        if let effectiveFilter {
            // Direct PID enumeration: works for accessory apps (test windows).
            axWindows = effectiveFilter.flatMap { pid -> [AXWindowInfo] in
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
        // Scope adoption to the strip's own display (default). With one Space
        // spanning multiple monitors, "onscreen" includes windows on OTHER
        // displays; without this filter arrange would yank them onto the strip.
        // `allDisplays` keeps the legacy whole-desktop behavior. Pure policy +
        // the engine's live display geometry live in `filterByAdoptScope`.
        let scoped = engine.filterByAdoptScope(onscreen) { $0.ax.frame }
        engine.adopt(matched: scoped)
        guard !engine.slots.isEmpty else {
            print("arrange: no manageable windows found")
            return
        }
        RestoreStore.save(engine: engine)
        isManaging = true

        let monitor = LifecycleMonitor(engine: engine)
        monitor.pidFilter = effectiveFilter
        monitor.onChange = { [weak self] _, _ in
            guard let self else { return }
            RestoreStore.save(engine: self.engine)
        }
        monitor.onFloatingChange = { [weak self] in
            // Floating set changed (a dialog opened/closed, a window not on the
            // strip appeared): refresh the menu-bar status item so its badge and
            // the next menu build reflect reality.
            self?.menuBar.refresh()
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

    /// "Show All Windows": equalize every managed column so all windows are
    /// visible on screen at once (an overview), scrolled to the strip's start.
    /// No-op while dormant. Persists the new frames for crash recovery.
    func showAllWindows() {
        guard isManaging else { return }
        engine.fitAllColumns()
        RestoreStore.save(engine: engine)
        menuBar.refresh()
        print("show all: equalized \(engine.slots.count) columns to fit")
    }

    /// "Arrange All Windows": arrange the desktop when dormant, or force a full
    /// resync when already managing so any windows opened since the last arrange
    /// are adopted, then show them all. This is the one-shot "tidy everything"
    /// action from the menu.
    func arrangeAllWindows() {
        if !isManaging {
            arrange()
            // Equalize right after arranging so the user sees everything at once.
            if isManaging { engine.fitAllColumns(); RestoreStore.save(engine: engine); menuBar.refresh() }
            return
        }
        // Already managing: pull in any newly-opened current-Space windows, then
        // equalize so the freshly-adopted ones are visible too. `resync` runs its
        // heavy enumeration on a background queue and applies on main, so we
        // equalize once now (current columns) and again shortly after for any
        // windows the resync adopts.
        lifecycle?.resync()
        engine.fitAllColumns()
        RestoreStore.save(engine: engine)
        menuBar.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isManaging else { return }
            self.engine.fitAllColumns()
            RestoreStore.save(engine: self.engine)
            self.menuBar.refresh()
        }
        print("arrange all: resynced + equalized \(engine.slots.count) columns")
    }

    func quit() {
        stopControlServer()
        release()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Navigation passthrough

    func focusNext() { if isManaging { engine.focusNext() } }
    func focusPrevious() { if isManaging { engine.focusPrevious() } }
    func focus(index: Int) { if isManaging { engine.focus(index: index) } }

    // MARK: - Floating windows (open, but not on the strip)

    /// Windows on the current Space that ScrollWM is NOT tiling: dialogs,
    /// palettes, and any normal window not (yet) adopted. Drives the menu-bar
    /// "Floating" section. Empty while dormant (we enumerate nothing then).
    var floatingWindows: [FloatingWindow] {
        isManaging ? (lifecycle?.floatingWindows ?? []) : []
    }

    /// Bring a floating window to the front WITHOUT tiling it (for dialogs /
    /// palettes, or just to peek at a window). Activates its app so keyboard
    /// focus follows, mirroring the strip's own raise behavior.
    func focusFloating(_ window: FloatingWindow) {
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXSource.setBool(window.element, kAXMainAttribute as String, true)
        AXSource.setBool(window.element, kAXFocusedAttribute as String, true)
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate()
        }
    }

    /// Pull a floating (tileable) window onto the strip: insert it just right of
    /// the focused column, re-pack, and focus it. Dialogs/panels (`!canTile`)
    /// are only raised - tiling a modal sheet or palette is wrong.
    func tileFloating(_ window: FloatingWindow) {
        guard isManaging else { return }
        guard window.canTile else { focusFloating(window); return }
        // Already managed? (raced with an auto-adopt) Just focus it.
        if let i = engine.slots.firstIndex(where: { CFEqual($0.window.element, window.element) }) {
            engine.focus(index: i)
            menuBar.refresh()
            return
        }
        let insertAt = engine.slots.isEmpty ? 0 : engine.focusIndex + 1
        engine.insert(window: window.info, at: insertAt)
        engine.compactStrip()
        engine.focus(index: insertAt)
        RestoreStore.save(engine: engine)
        menuBar.refresh()
    }

    /// Tile every tileable floating window onto the strip in one shot.
    func tileAllFloating() {
        guard isManaging else { return }
        let tileable = floatingWindows.filter { $0.canTile }
        guard !tileable.isEmpty else { return }
        var insertAt = engine.slots.isEmpty ? 0 : engine.focusIndex + 1
        var lastInserted = insertAt
        for w in tileable {
            if engine.slots.contains(where: { CFEqual($0.window.element, w.element) }) { continue }
            engine.insert(window: w.info, at: insertAt)
            lastInserted = insertAt
            insertAt += 1
        }
        engine.compactStrip()
        engine.focus(index: lastInserted)
        RestoreStore.save(engine: engine)
        menuBar.refresh()
    }

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

    /// Switch the active vertical workspace (Cmd+J down / Cmd+K up). `delta` is
    /// +1 for down, -1 for up. No-op while dormant.
    func switchWorkspace(by delta: Int) {
        guard isManaging else { return }
        engine.switchWorkspace(by: delta)
        RestoreStore.save(engine: engine)
        menuBar.refresh()
    }

    /// Send the focused window to the workspace `delta` away and follow it
    /// (Cmd+Shift+J down / Cmd+Shift+K up). No-op while dormant.
    func moveFocusedToWorkspace(by delta: Int) {
        guard isManaging else { return }
        engine.moveFocusedToWorkspace(by: delta)
        RestoreStore.save(engine: engine)
        menuBar.refresh()
    }

    /// Resize the focused column to an arbitrary fraction of the strip width
    /// (CLI `width` verb; the preset keys use `setWidthPreset`).
    func setWidthFraction(_ fraction: CGFloat) {
        guard isManaging else { return }
        _ = engine.setFocusedWidth(fraction: fraction)
        engine.refitViewportToFocused()
        menuBar.refresh()
    }

    /// Per-column snapshot for the CLI `status` command.
    func controlColumns() -> [[String: Any]] {
        engine.slots.enumerated().map { (i, slot) in
            [
                "index": i + 1,
                "app": slot.window.appName,
                "title": slot.window.title,
                "width": Int(slot.width.rounded()),
                "focused": i == engine.focusIndex,
                "healthy": slot.window.healthy,
            ]
        }
    }

    /// Start listening for `scrollwm` CLI commands on the control socket.
    /// Production-only (the `run` path calls this); the handler runs on the
    /// main thread, so it can touch AX/AppKit safely.
    func startControlServer() {
        guard controlServer == nil else { return }
        let server = ControlServer { [weak self] line in
            guard let self else { return "error: controller gone" }
            return self.handleControlCommand(line)
        }
        if server.start() {
            controlServer = server
            print("control socket: \(ControlSocket.path())")
        }
    }

    func stopControlServer() {
        controlServer?.stop()
        controlServer = nil
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
    var debugActiveWorkspace: Int { engine.stripState.activeWorkspace }
    var debugWorkspaceCount: Int { engine.stripState.workspaceCount }

    // --- Multi-display debug accessors (for the `displaytest` integration) ---
    // These read/relay the SAME engine the production controller drives, so the
    // test asserts real behavior, not a parallel mock.

    /// The strip's current usable (visible) frame in AX global coords.
    var debugScreenFrame: CGRect { engine.screenFrame }
    /// Full AX frame of the display the strip is bound to (parking reference).
    var debugStripDisplayFrame: CGRect? { engine.stripDisplayFrame }
    /// Full AX frames of every OTHER display (drives the parking-corner choice).
    var debugOtherDisplayFrames: [CGRect] { engine.otherDisplayFrames }
    /// The shared off-screen parking corner the engine would park columns at.
    var debugParkingPoint: CGPoint { engine.parkingPoint }
    /// Live AX origin the focused column is committed at (nil if none/unhealthy).
    var debugFocusedCommittedOrigin: CGPoint? {
        engine.slots.indices.contains(engine.focusIndex)
            ? engine.slots[engine.focusIndex].window.lastCommittedOrigin : nil
    }
    /// Re-bind the strip onto new display geometry at runtime and relay every
    /// managed window onto it, exactly as a real monitor hotplug/rearrange would
    /// via `screenParametersChanged`. `stripFull`/`others` are the parking
    /// references (strip's own display vs every other), `visible` is the new
    /// usable frame the strip should fill — all in AX global (top-left) coords.
    /// Returns the number of AX position writes the relay issued. Used by
    /// `displaytest` to simulate "the strip moved to the other monitor" (or, on a
    /// single-display rig, onto a sub-region) and verify the windows follow.
    @discardableResult
    func debugRebindStrip(visible: CGRect, stripFull: CGRect, others: [CGRect]) -> Int {
        engine.stripDisplayFrame = stripFull
        engine.otherDisplayFrames = others
        return engine.rebindStripDisplay(to: visible)
    }

    /// Jump directly to a 1-based workspace index (CLI `workspace N`).
    func focusWorkspace(_ oneBased: Int) {
        guard isManaging else { return }
        engine.focusWorkspace(oneBased - 1)
        RestoreStore.save(engine: engine)
        menuBar.refresh()
    }

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

        // niri-style spawn bindings: chord -> shell command (always-on).
        for (chord, command) in config.spawnBindings() {
            hotkeys.registerRaw(keyCode: chord.keyCode, modifiers: chord.carbonModifiers) { [weak self] in
                self?.runSpawn(command)
            }
        }
    }

    /// Run a configured `spawn` command in the background via `/bin/sh -c`.
    /// Detached and non-blocking so the main thread (hotkeys/teleport/menu) is
    /// never stalled by the launched process.
    private func runSpawn(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        do {
            try process.run()
            print("spawn: launched `\(command)`")
        } catch {
            print("spawn: failed to launch `\(command)`: \(error.localizedDescription)")
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
        bind(.workspaceDown) { [weak self] in self?.switchWorkspace(by: 1) }
        bind(.workspaceUp) { [weak self] in self?.switchWorkspace(by: -1) }
        bind(.moveToWorkspaceDown) { [weak self] in self?.moveFocusedToWorkspace(by: 1) }
        bind(.moveToWorkspaceUp) { [weak self] in self?.moveFocusedToWorkspace(by: -1) }

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
    /// Horizontal padding around the mini-map inside the status item (points),
    /// split across both edges. The status item length is content + this.
    static let hPadding: CGFloat = 4
    /// The mini-map's current desired CONTENT width (points). Driven by the
    /// view as the strip grows/shrinks; the status item length tracks it.
    private var contentWidth: CGFloat = 30

    static let autosaveName = "ScrollWMMain"

    init(controller: ScrollWMController, engine: TeleportEngine) {
        self.controller = controller
        self.engine = engine
        super.init()

        // Seed the mini-map sizing from config and start at the configured floor.
        let mb = controller.config.menuBar
        stripView.pointsPerScreen = mb.pointsPerScreen
        stripView.minContentWidth = mb.minWidth
        stripView.maxContentWidth = mb.maxWidth
        contentWidth = mb.minWidth

        // Notch workaround (see MenuBarController).
        let positionKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(400.0, forKey: positionKey)
        }

        // Grow/shrink the status item as the strip changes size.
        stripView.onDesiredContentWidthChange = { [weak self] width in
            self?.setContentWidth(width)
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
        // Length tracks the live mini-map width (content + padding). Starts at
        // the configured floor; grows/shrinks as windows are added/removed.
        statusItem = NSStatusBar.system.statusItem(withLength: contentWidth + Self.hPadding)
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

    /// Update the status item's length to fit a new mini-map content width.
    /// Called from the view's width callback as the strip grows/shrinks. Setting
    /// `statusItem.length` resizes the button in place (no teardown), so the
    /// hosted view animates the new geometry smoothly.
    private func setContentWidth(_ width: CGFloat) {
        let clamped = max(stripView.minContentWidth, min(width, stripView.maxContentWidth))
        guard abs(clamped - contentWidth) >= 0.5 else { return }
        contentWidth = clamped
        if Self.profileStatusItem {
            let ms = Clock.measureMs { statusItem?.length = clamped + Self.hPadding }
            FileHandle.standardError.write(
                Data(String(format: "[statusprofile] length=%.0f set in %.3f ms\n", clamped + Self.hPadding, ms).utf8))
        } else {
            statusItem?.length = clamped + Self.hPadding
        }
    }

    /// Opt-in live profiling of the status-item resize on the real menu bar
    /// (set SCROLLWM_PROFILE_STATUSITEM=1). Logs each `.length` write's cost.
    static let profileStatusItem = ProcessInfo.processInfo.environment["SCROLLWM_PROFILE_STATUSITEM"] == "1"

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

    /// Re-read mini-map sizing from config (called on Reload Config) and apply
    /// it live: the next `refresh()` re-evaluates the desired width.
    func applyConfig(_ config: ScrollWMConfig) {
        let mb = config.menuBar
        stripView.pointsPerScreen = mb.pointsPerScreen
        stripView.minContentWidth = mb.minWidth
        stripView.maxContentWidth = mb.maxWidth
        // Re-clamp the current item to the new bounds immediately.
        setContentWidth(contentWidth)
        refresh()
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
            let wsSuffix = state.workspaceCount > 1
                ? String(format: " · workspace %d/%d", state.activeWorkspace + 1, state.workspaceCount)
                : ""
            let header = NSMenuItem(
                title: String(format: "Managing %d windows · teleport %.1f ms%@", state.slots.count, state.lastTeleportMs, wsSuffix),
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

            // Floating windows: open on this Space but NOT on the strip
            // (dialogs, palettes, or windows not adopted). Listed so every
            // on-screen window stays reachable from the menu bar; selecting one
            // tiles it (or just raises a dialog/panel).
            let floating = controller.floatingWindows
            if !floating.isEmpty {
                let fHeader = NSMenuItem(
                    title: "Floating (not on strip): \(floating.count)",
                    action: nil, keyEquivalent: ""
                )
                fHeader.isEnabled = false
                menu.addItem(fHeader)

                for (i, w) in floating.enumerated() {
                    // ◇ = tileable normal window, · = dialog/panel (raise only).
                    let marker = w.canTile ? "◇ " : "· "
                    let hint = w.canTile ? "" : "  (dialog)"
                    let item = NSMenuItem(
                        title: String("\(marker)\(w.appName) — \(w.title)\(hint)".prefix(60)),
                        action: #selector(selectFloating(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.tag = i
                    item.toolTip = w.canTile
                        ? "Tile this window onto the strip"
                        : "Bring this dialog/panel to the front"
                    menu.addItem(item)
                }

                if floating.contains(where: { $0.canTile }) {
                    let tileAll = NSMenuItem(
                        title: "Tile All Floating Windows onto Strip",
                        action: #selector(tileAllFloatingAction), keyEquivalent: ""
                    )
                    tileAll.target = self
                    menu.addItem(tileAll)
                }
                menu.addItem(.separator())
            }

            let releaseItem = NSMenuItem(title: "Release Windows (restore original positions)", action: #selector(releaseAction), keyEquivalent: "")
            releaseItem.target = self
            menu.addItem(releaseItem)

            let showAllItem = NSMenuItem(title: "Show All Windows (fit on screen)", action: #selector(showAllAction), keyEquivalent: "")
            showAllItem.target = self
            menu.addItem(showAllItem)

            let arrangeAllItem = NSMenuItem(title: "Arrange All Windows (adopt new + fit)", action: #selector(arrangeAllAction), keyEquivalent: "")
            arrangeAllItem.target = self
            menu.addItem(arrangeAllItem)

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

            let arrangeAllItem = NSMenuItem(title: "Arrange All Windows (adopt new + fit)", action: #selector(arrangeAllAction), keyEquivalent: "")
            arrangeAllItem.target = self
            menu.addItem(arrangeAllItem)

            let showAllItem = NSMenuItem(title: "Show All Windows (fit on screen)", action: nil, keyEquivalent: "")
            showAllItem.isEnabled = false // nothing managed yet
            menu.addItem(showAllItem)

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

        // [md-select] "Move strip to display" submenu, only when >1 monitor.
        let displays = controller.displayChoices()
        if displays.count > 1 {
            let dispItem = NSMenuItem(title: "Move Strip to Display", action: nil, keyEquivalent: "")
            let dispMenu = NSMenu()
            for d in displays {
                let mi = NSMenuItem(title: "Display \(d.index): \(d.name)",
                                    action: #selector(moveStripToDisplayAction(_:)), keyEquivalent: "")
                mi.target = self
                mi.state = d.isStrip ? .on : .off
                mi.representedObject = String(d.index)
                dispMenu.addItem(mi)
            }
            dispItem.submenu = dispMenu
            menu.addItem(dispItem)
        }


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
    @objc private func selectFloating(_ sender: NSMenuItem) {
        let floating = controller.floatingWindows
        guard floating.indices.contains(sender.tag) else { return }
        // Tile a normal window onto the strip; just raise a dialog/panel.
        controller.tileFloating(floating[sender.tag])
    }
    @objc private func tileAllFloatingAction() { controller.tileAllFloating() }
    @objc private func arrangeAction() { controller.arrange() }
    @objc private func releaseAction() { controller.release() }
    @objc private func showAllAction() { controller.showAllWindows() }
    @objc private func arrangeAllAction() { controller.arrangeAllWindows() }
    @objc private func setFocusModeAction(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let mode = TeleportEngine.FocusMode(rawValue: raw) {
            controller.setFocusMode(mode)
        }
    }
    // [md-select] Move the strip to the chosen display (1-based index in tag).
    @objc private func moveStripToDisplayAction(_ sender: NSMenuItem) {
        if let spec = sender.representedObject as? String {
            _ = controller.moveStripToDisplay(spec)
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

    // Create the controller and bring up the control plane IMMEDIATELY, before
    // (and independent of) the Accessibility check. The controller is dormant
    // until `arrange`, so this touches nothing; but it means the `scrollwm` CLI
    // and the menu bar work the instant the app launches — even while AX is
    // still resolving (or not yet granted). `arrange` itself still requires AX
    // and fails gracefully without it.
    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller
    controller.startControlServer()

    // One-time, AX-gated "ready" actions (tutorial, selftest, crash phase).
    var readyDone = false
    func onReady() {
        guard !readyDone else { return }
        readyDone = true
        print("ScrollWM running (dormant). Use the menu bar item, the toggle key, or the `scrollwm` CLI to arrange.")
        controller.showTutorialOnFirstRunIfNeeded()
        if selftest { runScrollWMSelftest(controller: controller) }
        if crashPhase == .crash { runCrashPhase(controller: controller) }
    }

    // Single source of truth for the Accessibility permission. It debounces the
    // stale-`false` reading that `AXIsProcessTrusted()` returns right after
    // launch, so a granted machine starts silently — no waiting UI, no prompt.
    // Only after the grace window, if still genuinely untrusted, do we show the
    // onboarding window. Once granted (now or later, with no relaunch), the
    // ready actions fire.
    var started = false
    func startOnce() {
        guard !started else { return }
        started = true
        onReady()
    }

    AccessibilityPermission.shared.resolveAtLaunch { state in
        if state == .granted {
            startOnce()
            return
        }
        func presentOnboarding() {
            let ob = OnboardingWindowController()
            ob.onGranted = { startOnce() }
            ob.present()
            onboardingKeepAlive = ob
        }

        // If Accessibility has ever been granted on this machine, a launch-time
        // `false` is almost certainly a stale/transient TCC reading (signature
        // re-eval after an update, WindowServer hiccup), NOT a real revocation.
        // Wait silently (no UI, no prompt) and start the instant trust returns.
        // Only if it stays untrusted well past any plausible stale window do we
        // surface onboarding — and even then it will NOT fire the system modal,
        // because we've prompted before (see OnboardingWindow). This is the core
        // of "never ask the user when it's already on".
        if AccessibilityPermission.shared.hasEverBeenGranted {
            print("ScrollWM: Accessibility not yet readable at launch; waiting silently (no prompt).")
            let silentDeadline = Date().addingTimeInterval(8.0)
            AccessibilityPermission.shared.observe { state in
                if state == .granted {
                    startOnce()
                } else if !started && Date() >= silentDeadline && onboardingKeepAlive == nil {
                    // Genuinely still off after the extended grace: show help
                    // (troubleshooting copy, no modal) so a real revocation
                    // isn't an invisible dead end.
                    presentOnboarding()
                }
            }
            return
        }
        print("""
        ScrollWM needs Accessibility permission (its only permission).
        Grant it in: System Settings -> Privacy & Security -> Accessibility
        Waiting for grant... (the app will start automatically)
        """)
        presentOnboarding()
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
