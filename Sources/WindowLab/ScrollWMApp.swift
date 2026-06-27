import Foundation
import AppKit

/// ScrollWM: the production teleport app.
///
/// Safety model (the "don't break the user's desktop" contract):
///   1. Launches DORMANT: no window is touched until the user invokes Arrange.
///   2. Original frames are captured before any move and persisted to disk.
///   3. Release (menu or hotkey) restores every window exactly.
///   4. Quit restores automatically. SIGINT/SIGTERM restore too.
///   5. After a crash/kill -9, next launch offers recovery from the restore file.
///   6. Accessibility only. No capture, no input monitoring.
final class ScrollWMController: NSObject {
    /// One independent scrolling strip per managed display. Always has at least
    /// one entry; a single-display setup uses exactly one, so behavior matches
    /// the historical single-engine controller. The strips share configuration
    /// but each owns its own engine, viewport, workspaces, and lifecycle.
    private var strips: [DisplayStrip]

    /// Index into `strips` of the strip the user's focus is currently on. Global
    /// navigation/width/move/workspace actions route to this strip, so a hotkey
    /// acts on the monitor the user is looking at ("focus follows display").
    /// Always a valid index into `strips`.
    private var activeStripIndex = 0

    /// The strip that currently owns user actions. Convenience over
    /// `strips[activeStripIndex]`, clamped so it can never be out of range.
    private var activeStrip: DisplayStrip {
        if strips.indices.contains(activeStripIndex) { return strips[activeStripIndex] }
        return strips[0]
    }

    /// The active strip's engine. The vast majority of controller code drives a
    /// single strip (the focused one), so this computed accessor lets every
    /// existing per-strip call site stay unchanged while the array holds the
    /// rest. Paths that must touch EVERY display (arrange/release/display
    /// geometry) iterate `strips` explicitly instead of using this.
    private var engine: TeleportEngine { activeStrip.engine }

    /// The active strip's lifecycle monitor (nil while that strip is dormant).
    private var lifecycle: LifecycleMonitor? {
        get { activeStrip.lifecycle }
        set { activeStrip.lifecycle = newValue }
    }
    private var menuBar: ProductionMenuBar!
    private let hotkeys = HotkeyManager()
    /// CLI control plane (Unix socket). Started only by the production `run`
    /// path via `startControlServer()`; sandbox/tests never expose it.
    private var controlServer: ControlServer?
    /// Keyboard tap for the move bindings (Cmd+H/L) that Carbon cannot grab.
    private var moveTap: KeyboardEventTap?

    /// In-app updater: checks GitHub Releases so users actually receive new
    /// versions. Created by the production `run` path (`startUpdates()`); nil in
    /// sandbox/tests so they never phone home.
    private var updateCoordinator: UpdateCoordinator?

    /// Per-action keybinding-proficiency history. Tracks whether the user drives
    /// each core action by its keybinding or by the pointer (menu) fallback, so
    /// we can detect when a once-mastered shortcut has been "unlearned" (reverted
    /// to clicking the menu). Created ONLY by the production `run` path
    /// (`startSkillTracking()`); nil in sandbox/headless/tests so they never
    /// write the user's real history. All decisions live in the pure
    /// `KeybindingProficiency`.
    private var skillTracker: SkillTracker?

    /// Pending coalesced re-evaluation of a display change. macOS fires
    /// `didChangeScreenParameters` SEVERAL times in quick succession for a
    /// single hotplug / resolution change (each intermediate arrangement is its
    /// own event). We debounce the burst into one re-bind from the SETTLED
    /// geometry, so the strip never thrashes through every transient layout.
    private var displayChangeDebounce: DispatchWorkItem?
    /// Debounce window for `screenParametersChanged`: long enough to swallow a
    /// hotplug burst, short enough to feel instant.
    private let displayChangeDebounceInterval: TimeInterval = 0.25

    /// Stable `CGDirectDisplayID` of the display the ACTIVE strip is bound to.
    /// Tracked per strip (see `DisplayStrip.displayID`) so `applySettledDisplayChange`
    /// can follow each strip's PHYSICAL display by identity across an arrangement
    /// swap or a large resolution change - cases pure geometry overlap gets wrong.
    /// Updated on every bind (`refreshDisplayGeometry`, `bindStripToDisplay`).
    private var stripDisplayID: CGDirectDisplayID? {
        get { activeStrip.displayID }
        set { activeStrip.displayID = newValue }
    }

    /// Lazily-created tutorial window controller (config-driven cheat sheet).
    private lazy var tutorial = TutorialWindowController(
        configProvider: { [weak self] in self?.config ?? .default },
        levelsProvider: { [weak self] in
            self?.proficiencyLevels()
                ?? Dictionary(uniqueKeysWithValues: KeyAction.allCases.map { ($0, .unknown) })
        })

    /// True if ANY strip is actively managing its display. Aggregated over all
    /// strips so the menu bar / CLI report "managing" whenever at least one
    /// monitor's strip is live, matching the historical single-strip semantics.
    var isManaging: Bool { strips.contains { $0.isManaging } }

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
        // The strip's usable area in AX top-left coords. Use the SHARED pure
        // binding (primary-display Y-flip) rather than a hand-rolled
        // `screen.frame.height - vf.maxY`: that local flip is only correct when
        // the configured strip display IS the primary. On a non-primary strip
        // (e.g. a configured external with a negative AppKit origin) it shoved
        // the whole strip vertically by (stripHeight - primaryHeight) — 124px on
        // the real hardware — landing every window off the intended display.
        let axFrame: CGRect = {
            if let i = NSScreen.screens.firstIndex(of: screen),
               let b = StripDisplayBinding.bind(displays: Self.displayFrames(),
                                                stripIndex: i,
                                                mainIndex: Self.mainScreenIndex()) {
                return b.stripVisible
            }
            // Single-display / degenerate fallback: a primary strip flips
            // identically under either height, so this is exact there.
            let vf = screen.visibleFrame
            return CGRect(x: vf.origin.x, y: screen.frame.height - vf.maxY,
                          width: vf.width, height: vf.height)
        }()
        // Start with a single strip on the configured display. Additional
        // strips for other displays are created lazily as they are arranged.
        strips = [DisplayStrip(engine: TeleportEngine(screenFrame: axFrame))]
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
            Log.warn("found restore file from previous session (\(pending.count) windows); recovering...", "restore")
            DispatchQueue.global(qos: .userInitiated).async {
                let result = RestoreStore.recover()
                Log.info("recovered \(result.restored)/\(result.total) windows from previous session", "restore")
            }
        }
    }

    /// Push layout/focus settings from the config into EVERY strip's engine, so
    /// all displays share one configuration (the config is global, not per
    /// display). On a single-display setup this touches the one strip.
    private func applyConfigToEngine() {
        for strip in strips {
            let engine = strip.engine
            engine.gap = config.layout.columnGap
            engine.minColumnWidth = config.layout.minColumnWidth
            engine.peekInset = config.layout.peekInset
            engine.widthPresets = config.layout.widthPresets
            engine.spawnWidthFraction = config.layout.spawnWidth
            engine.fillHeight = config.layout.fillHeight
            engine.focusMode = config.focusMode
            engine.adoptScope = config.layout.adoptScope
        }
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
        refreshDisplayGeometry(for: activeStrip, stripDisplay: stripDisplay, relayout: relayout)
    }

    /// Bind a SPECIFIC strip's engine to `stripDisplay`'s live geometry. Same as
    /// the active-strip overload but lets the multi-display arrange/hotplug paths
    /// rebind each per-monitor strip independently. The "other displays" parking
    /// reference is every screen EXCEPT this strip's own, so a parked column's
    /// sliver always lands on the strip's own monitor regardless of how many
    /// strips exist.
    ///
    /// Thin AppKit shim: snapshot the live `NSScreen` set, find this display's
    /// index, and delegate to the pure snapshot core (`refreshDisplayGeometry(
    /// for:displays:stripIndex:)`). Keeping the geometry math in the snapshot
    /// core lets the settled-display-change / clamshell path be driven headlessly.
    private func refreshDisplayGeometry(for strip: DisplayStrip,
                                        stripDisplay: NSScreen,
                                        relayout: Bool = false) {
        let displays = Self.snapshots(of: NSScreen.screens)
        guard let idx = NSScreen.screens.firstIndex(of: stripDisplay) else {
            // Degenerate: the chosen screen is not in the live set (never observed
            // in practice). Build a one-display snapshot so the strip still binds.
            let solo = [Self.snapshot(of: stripDisplay)]
            refreshDisplayGeometry(for: strip, displays: solo, stripIndex: 0, relayout: relayout)
            return
        }
        refreshDisplayGeometry(for: strip, displays: displays, stripIndex: idx, relayout: relayout)
    }

    /// PURE-input core of the display rebind: bind `strip` to `displays[stripIndex]`
    /// using AX (top-left global) geometry flipped around the SETTLED primary
    /// height. Every other display becomes the parking "others" set. Shared by the
    /// production (`NSScreen`) path and the headless settled-change/clamshell test
    /// (which injects synthetic `DisplaySnapshot`s), so both run identical logic.
    ///
    /// The primary height is recomputed from `displays` on EVERY call: when the
    /// primary display itself changes (e.g. the laptop lid closes and an external
    /// takes over the AppKit origin), the Y-flip anchor for the WHOLE AX plane
    /// shifts, so a stale primary height would land the strip at the wrong AX Y.
    private func refreshDisplayGeometry(for strip: DisplayStrip,
                                        displays: [DisplaySnapshot],
                                        stripIndex: Int,
                                        relayout: Bool = false) {
        guard displays.indices.contains(stripIndex) else { return }
        let engine = strip.engine
        let primaryHeight = Self.primaryHeight(of: displays)
        func axFull(_ d: DisplaySnapshot) -> CGRect {
            DisplayGeometry.axFrame(appKitFrame: d.fullAppKit, primaryHeight: primaryHeight)
        }
        func axVisible(_ d: DisplaySnapshot) -> CGRect {
            DisplayGeometry.axFrame(appKitFrame: d.visibleAppKit, primaryHeight: primaryHeight)
        }
        let stripDisplay = displays[stripIndex]
        engine.stripDisplayFrame = axFull(stripDisplay)
        engine.otherDisplayFrames = displays.indices
            .filter { $0 != stripIndex }
            .map { axFull(displays[$0]) }
        // Remember which PHYSICAL display the strip is bound to, so a later
        // hotplug can follow it by stable id across arrangement/resolution change.
        strip.displayID = stripDisplay.id

        // Re-bind the strip's own usable area to the live visible frame so a
        // resolution/scale change (or the strip moving displays) relays the
        // whole strip onto the new geometry instead of leaving stale coords.
        // The rebind runs even while DORMANT: on an empty strip it is a pure
        // no-op except updating `screenFrame`, which is exactly what we need so
        // the NEXT arrange lands on the display's CURRENT geometry rather than a
        // stale (possibly unplugged/resized) frame. Persistence + menu refresh
        // only matter while actively managing.
        let visible = axVisible(stripDisplay)
        if relayout {
            engine.rebindStripDisplay(to: visible)
            if strip.isManaging {
                RestoreStore.save(engines: strips.map { $0.engine })
                menuBar.refresh()
            }
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
    ///
    /// Thin AppKit shim: snapshot the live `NSScreen` set and delegate to the
    /// pure snapshot core so the whole decision (including the clamshell case
    /// where the laptop's built-in display turns off and an external becomes the
    /// new primary) is driven identically in production and in headless tests.
    private func applySettledDisplayChange() {
        applySettledDisplayChange(displays: Self.snapshots(of: NSScreen.screens))
    }

    /// PURE-input core of the settled-display-change policy. Given the SETTLED
    /// display set (already debounced), resolve where the strip should bind via
    /// `StripDisplayResolver` (follow the strip's own display by stable id, else
    /// migrate to a survivor) and relay the strip onto it. Both the production
    /// `NSScreen` path and the headless clamshell/hotplug test funnel through
    /// here, so they share one source of truth.
    private func applySettledDisplayChange(displays: [DisplaySnapshot]) {
        // No screens at all (all monitors asleep/disconnected): keep the last
        // geometry untouched until one reappears (resolver case 3).
        guard !displays.isEmpty else { return }

        let primaryHeight = Self.primaryHeight(of: displays)
        // Visible AX frames of every available display, parallel to `displays`.
        let visibleFrames = displays.map {
            DisplayGeometry.axFrame(appKitFrame: $0.visibleAppKit, primaryHeight: primaryHeight)
        }
        // Parallel stable display ids (same order as `displays`/`visibleFrames`).
        // Only pass them through when EVERY screen vended one, so the resolver's
        // well-formed-arrays guard either uses identity for all or none of them
        // (a partial id list would silently disable identity tracking anyway).
        let ids = displays.map { $0.id }
        let displayIDs: [CGDirectDisplayID]? = ids.allSatisfy { $0 != nil }
            ? ids.compactMap { $0 } : nil

        // Pure policy: same display (by stable id, else resized/overlap) -> follow
        // it; strip display gone -> migrate to the best survivor; none -> keep put.
        let decision = StripDisplayResolver.resolve(
            stripFrame: engine.screenFrame,
            displays: visibleFrames,
            stripDisplayID: stripDisplayID,
            displayIDs: displayIDs)
        guard let idx = decision.displayIndex else { return }

        if decision.migrated {
            print("display change: strip's display gone; migrating strip to "
                  + "\(displays[idx].name)")
        }
        refreshDisplayGeometry(for: activeStrip, displays: displays,
                               stripIndex: idx, relayout: true)
    }

    /// AppKit-free snapshot of one connected display, captured at a single point
    /// in time. Decoupling the geometry from a live `NSScreen` lets the display-
    /// change / clamshell policy run headlessly: a test injects synthetic
    /// snapshots (e.g. "built-in display gone, two equal externals") and drives
    /// the exact production resolve + rebind logic with no real monitors.
    struct DisplaySnapshot {
        /// AppKit full frame (bottom-left origin, primary at `(0,0)`). The
        /// AppKit->AX flip around the SETTLED primary height happens downstream.
        var fullAppKit: CGRect
        /// AppKit visible frame (full minus the menu bar / Dock).
        var visibleAppKit: CGRect
        /// Stable `CGDirectDisplayID`, or nil if AppKit did not vend one.
        var id: CGDirectDisplayID?
        /// Human-readable name (for the migration log).
        var name: String
    }

    /// Snapshot a live `NSScreen` into an AppKit-free `DisplaySnapshot`.
    private static func snapshot(of s: NSScreen) -> DisplaySnapshot {
        DisplaySnapshot(fullAppKit: s.frame, visibleAppKit: s.visibleFrame,
                        id: s.displayID, name: s.localizedName)
    }

    /// Snapshot the live `NSScreen` set, preserving order (CLI/config indices).
    private static func snapshots(of screens: [NSScreen]) -> [DisplaySnapshot] {
        screens.map(snapshot(of:))
    }

    /// The Y-flip anchor for the AX coordinate plane: the height of the PRIMARY
    /// display (AppKit origin `(0,0)`), falling back to the first display when no
    /// snapshot sits exactly at the origin (e.g. mid-reconfiguration). Recomputed
    /// from the SETTLED set so a primary-display change (clamshell) re-anchors the
    /// whole plane instead of flipping around a vanished display's height.
    private static func primaryHeight(of displays: [DisplaySnapshot]) -> CGFloat {
        (displays.first { $0.fullAppKit.origin == .zero } ?? displays.first)?
            .fullAppKit.height ?? 0
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

    /// Map `NSScreen.screens` to the pure `StripDisplayBinding.DisplayFrames`
    /// view (full + visible AppKit frames, parallel order), so the AppKit ->
    /// AX flip lives in ONE unit-tested place (`StripDisplayBinding.bind`) used
    /// by launch, runtime move, and the sandbox bind alike.
    private static func displayFrames() -> [StripDisplayBinding.DisplayFrames] {
        NSScreen.screens.map {
            StripDisplayBinding.DisplayFrames(full: $0.frame, visible: $0.visibleFrame)
        }
    }

    /// Index of `NSScreen.main` within `NSScreen.screens` (the active display),
    /// or nil if it cannot be found. Feeds `StripDisplayBinding`'s primary-height
    /// fallback so the pure result matches production in degenerate layouts.
    private static func mainScreenIndex() -> Int? {
        guard let main = NSScreen.main else { return nil }
        return NSScreen.screens.firstIndex(of: main)
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
        // Prefer stable identity: if we know the strip's display id and it is
        // still attached, that index is authoritative even after an arrangement
        // swap moved the strip's frame onto another screen's old origin.
        if let id = stripDisplayID,
           let idx = NSScreen.screens.firstIndex(where: { $0.displayID == id }) {
            return idx
        }
        // Fallback (no id, or the id is gone): best geometry overlap.
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
        guard let idx = NSScreen.screens.firstIndex(of: stripDisplay),
              let b = StripDisplayBinding.bind(displays: Self.displayFrames(),
                                               stripIndex: idx,
                                               mainIndex: Self.mainScreenIndex()) else {
            return
        }
        engine.stripDisplayFrame = b.stripFull
        engine.otherDisplayFrames = b.others
        // Track the strip's PHYSICAL display by stable id so a later hotplug can
        // follow it across an arrangement/resolution change (see hotplug fix).
        stripDisplayID = stripDisplay.displayID
        // rebindStripDisplay sets `screenFrame` and relays; on an empty strip the
        // relay is a no-op, so this safely repositions the strip pre-arrange.
        engine.rebindStripDisplay(to: b.stripVisible)
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
        updateCoordinator?.updateConfig(config.update)
        print("config reloaded from \(ScrollWMConfig.fileURL.path)")
    }

    // MARK: - Updates

    /// Stand up the in-app updater (production `run` path only). Reconciles a
    /// just-completed update (version advanced? grant reset?), then schedules
    /// the background check per config; manual checks always work regardless.
    func startUpdates() {
        guard updateCoordinator == nil else { return }
        let coord = UpdateCoordinator(controller: self, config: config.update)
        updateCoordinator = coord
        coord.reconcileAfterRelaunch()
        coord.start()
    }

    /// Whether the updater is live (used to gate the menu item).
    var updatesEnabled: Bool { updateCoordinator != nil }

    // MARK: - Launch at login

    /// Reconcile the macOS login item with the config's `launchAtLogin` setting.
    /// Called once on launch (production `run` path) so a fresh install with the
    /// default `launchAtLogin: true` registers itself the first time it runs,
    /// and a later config edit is honored on the next launch. Safe + no-op on a
    /// dev binary / headless backend (see `LaunchAtLoginManager.isSupported`).
    func reconcileLaunchAtLogin() {
        guard LaunchAtLoginManager.isSupported else { return }
        LaunchAtLoginManager.apply(desired: config.launchAtLogin)
    }

    /// Whether ScrollWM is currently registered to launch at login (live read).
    var launchAtLoginEnabled: Bool { LaunchAtLoginManager.isEnabled }

    /// Whether the login-item feature is available in this context (installed
    /// app, not a dev binary / headless test). Gates the menu item.
    var launchAtLoginSupported: Bool { LaunchAtLoginManager.isSupported }

    /// Flip launch-at-login on/off: persist the new desire to the config (single
    /// source of truth) and register/unregister the login item to match. Driven
    /// by the menu-bar toggle and the `scrollwm login` CLI.
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> String {
        config.launchAtLogin = enabled
        config.save()
        guard LaunchAtLoginManager.isSupported else {
            return "error: launch-at-login unavailable (run the installed ScrollWM.app)"
        }
        LaunchAtLoginManager.apply(desired: enabled)
        menuBar?.refresh()
        return "ok: launch at login \(LaunchAtLoginManager.describe(desired: enabled))"
    }

    /// One-line launch-at-login status for the CLI (`scrollwm login`).
    func launchAtLoginStatus() -> String {
        "ok: launch at login \(LaunchAtLoginManager.describe(desired: config.launchAtLogin))"
    }

    /// Live Accessibility-trust reading, for the updater's post-relaunch
    /// re-grant detection.
    var accessibilityIsTrusted: Bool { AccessibilityPermission.shared.isTrustedNow }

    /// User-initiated "Check for Updates…" (menu). Always reports an outcome.
    func checkForUpdates() {
        guard let coord = updateCoordinator else {
            // Updater not wired (e.g. AX still resolving): build a one-shot.
            let coord = UpdateCoordinator(controller: self, config: config.update)
            updateCoordinator = coord
            coord.checkNow()
            return
        }
        coord.checkNow()
    }

    /// CLI `scrollwm update [--install]`: synchronously check GitHub and return
    /// a one-line reply. With `install`, an available update is downloaded +
    /// verified + applied asynchronously AFTER this reply is sent (the app then
    /// restores windows and relaunches). Runs on the main thread (control plane).
    func controlUpdateCheck(install: Bool) -> String {
        let updater = Updater(allowPrerelease: config.update.allowPrerelease)
        switch updater.checkSync() {
        case .failure(let err):
            return "error: \(err.localizedDescription)"
        case .success(.upToDate(let cur)):
            return "ok: up to date (v\(cur))"
        case .success(.noUsableAsset(let rel)):
            return "ok: newer tag \(rel.tagName) found but no installable asset yet"
        case .success(.updateAvailable(let rel, let cur)):
            if !install {
                return "ok: update available v\(rel.version) (you have v\(cur)). "
                    + "Run `scrollwm update --install` or use the menu."
            }
            guard Bundle.main.bundleURL.pathExtension == "app" else {
                return "error: update v\(rel.version) available, but this is a dev build (won't self-replace). "
                    + "Download: \(rel.htmlURL)"
            }
            // Install after the reply is sent so the CLI sees confirmation.
            let coord = updateCoordinator ?? {
                let c = UpdateCoordinator(controller: self, config: config.update)
                updateCoordinator = c
                return c
            }()
            DispatchQueue.main.async { coord.beginInstall(rel, mode: .userClicked) }
            return "ok: installing v\(rel.version)… ScrollWM will restore windows and relaunch"
        }
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

    /// Flash the menu-bar key-hint for a fired binding: the pretty chord (e.g.
    /// "⌘L") plus the action's short label ("Focus →"). `chordOverride` lets the
    /// caller supply the exact chord that fired (e.g. the jump digit), otherwise
    /// the action's first configured chord is shown. No-op unless enabled.
    func flashKeybinding(_ action: KeyAction, chordOverride: String? = nil) {
        // Skill tracking is independent of the visual hint: record EVERY
        // keyboard-driven invocation (this is the single seam every hotkey
        // handler funnels through) before the flash, so proficiency is measured
        // even when the menu-bar key-hint HUD is turned off.
        recordKeyboardUse(action)
        guard config.menuBar.showKeyHints else { return }
        let chord = chordOverride ?? (config.keybindings[action] ?? KeyAction.defaultChords[action] ?? [])
            .first.map(TutorialWindowController.pretty) ?? ""
        menuBar.flashKeyHint(chord: chord, action: action.displayName)
    }

    // MARK: - Keybinding proficiency ("are you still using the shortcut?")

    /// Construct the on-disk skill tracker. Called ONLY from the production
    /// `run` path so sandbox/headless/tests (which never invoke it) leave the
    /// user's real history untouched. Idempotent.
    func startSkillTracking() {
        guard skillTracker == nil, AXSource.backend == nil else { return }
        skillTracker = SkillTracker()
    }

    /// Record that the user invoked `action` via its KEYBINDING. No-op until the
    /// tracker is started (sandbox/tests), so the hot keypress path stays cheap.
    private func recordKeyboardUse(_ action: KeyAction) {
        skillTracker?.record(action, channel: .keyboard)
    }

    /// Record that the user invoked `action` via a POINTER fallback (the menu),
    /// and gently nudge them about the keybinding the FIRST time an action slips
    /// from "proficient" toward "unlearned" — never on a steady state, so it is
    /// not nagging. Returns nothing; the nudge is a non-modal menu-bar flash.
    /// Public so the menu-bar handlers (the pointer channel) can report the
    /// menu-clicked equivalent of a keybinding.
    func recordPointerUse(_ action: KeyAction) {
        guard let regression = skillTracker?.record(action, channel: .pointer) else { return }
        nudgeRustyKeybinding(regression)
    }

    /// Surface a rusty/unlearned keybinding as a brief, non-intrusive menu-bar
    /// flash: the chord they used to press and a short "still works" hint. Uses
    /// the same HUD as the key-hint flash so it costs nothing extra and never
    /// steals focus or pops a modal.
    private func nudgeRustyKeybinding(_ regression: SkillTracker.Regression) {
        guard config.menuBar.showKeyHints else { return }
        let chord = (config.keybindings[regression.action]
                     ?? KeyAction.defaultChords[regression.action] ?? [])
            .first.map(TutorialWindowController.pretty) ?? ""
        guard !chord.isEmpty else { return }
        let verb = regression.level == .unlearned ? "still works" : "tip"
        menuBar.flashKeyHint(chord: chord, action: "\(regression.action.displayName) · \(verb)")
    }

    /// One-line, human-readable proficiency report for the `scrollwm skills`
    /// CLI and tests. Lists the keybindings the user has stopped using (worst
    /// first), or a friendly "all good" when nothing has regressed.
    func skillReport() -> String {
        guard let tracker = skillTracker else {
            return "skill tracking not active (only the running app records usage)"
        }
        let regressed = tracker.regressedActions()
        guard !regressed.isEmpty else {
            return "ok: no rusty keybindings — you're driving every action by shortcut"
        }
        let lines = regressed.map { item -> String in
            let chord = (config.keybindings[item.action]
                         ?? KeyAction.defaultChords[item.action] ?? [])
                .first.map(TutorialWindowController.pretty) ?? "?"
            return "  \(item.level.rawValue.uppercased()): \(item.action.displayName) (\(chord))"
        }
        return "rusty keybindings (you've drifted back to the menu):\n" + lines.joined(separator: "\n")
    }

    /// A one-line menu hint for the single rustiest keybinding, or nil when the
    /// user is keeping all their shortcuts sharp (or tracking is off). Drives the
    /// optional "Tip: …" row in the menu so the nudge is glanceable, not modal.
    var rustyKeybindingHint: String? {
        guard let top = skillTracker?.regressedActions().first else { return nil }
        let chord = (config.keybindings[top.action] ?? KeyAction.defaultChords[top.action] ?? [])
            .first.map(TutorialWindowController.pretty) ?? "?"
        let lead = top.level == .unlearned ? "Forgotten shortcut" : "Rusty shortcut"
        return "\(lead): \(top.action.displayName) is \(chord)"
    }

    /// Per-action proficiency levels for the tutorial's "learned vs not learned"
    /// panel. When skill tracking is inactive (sandbox/headless/tests, or the
    /// rare pre-`startSkillTracking` window) every action reads `.unknown`, so
    /// the tutorial honestly shows the whole core set as "not learned yet"
    /// rather than guessing.
    func proficiencyLevels() -> [KeyAction: KeybindingProficiency.Level] {
        skillTracker?.allLevels()
            ?? Dictionary(uniqueKeysWithValues: KeyAction.allCases.map { ($0, .unknown) })
    }


    // MARK: - Arrange / Release

    /// Start a per-strip `LifecycleMonitor` so this strip adopts/drops windows on
    /// its OWN display independently of the others. Factored out so the single-
    /// and multi-display arrange paths wire monitors identically.
    private func startLifecycle(for strip: DisplayStrip, filter: Set<pid_t>?) {
        let monitor = LifecycleMonitor(engine: strip.engine)
        monitor.pidFilter = filter
        // Space-safety: never activate (and thus teleport the user to) a window
        // whose app has NO window on the Space the user is currently viewing. We
        // judge "on the current Space" by the WindowServer on-screen list (the
        // same current-Space signal arrange/resync use). A window dragged to
        // another Desktop, or left on a different Space, still exists in AX as a
        // stranded strip column; focusing it must NOT yank the user across Spaces.
        // macOS only follows an activation across Spaces when ALL of the app's
        // windows are off the current Space, so we allow activation as long as the
        // app has at least one on-screen window (covers multi-window apps and the
        // common single-Space case). Sandbox/headless installs the same rule.
        strip.engine.activationKeepsCurrentSpace = { window in
            let onscreen = CGWindowSource.listWindows(onscreenOnly: true)
            // No on-screen list at all (degraded/locked) -> assume safe rather
            // than refusing focus; the session guards elsewhere handle lock.
            guard !onscreen.isEmpty else { return true }
            return onscreen.contains { $0.ownerPID == window.pid }
        }
        monitor.onChange = { [weak self] _, _ in
            guard let self else { return }
            RestoreStore.save(engines: self.strips.map { $0.engine })
        }
        monitor.onFloatingChange = { [weak self] in
            // Floating set changed (a dialog opened/closed, a window not on the
            // strip appeared): refresh the menu-bar status item so its badge and
            // the next menu build reflect reality.
            self?.menuBar.refresh()
        }
        // No-background-windows guarantee: when on (default), the monitor's add
        // path auto-tiles any window that appears on THIS strip's display + Space
        // so nothing is left un-arranged behind the strip. Off leaves new windows
        // floating until the user tiles them. Per-display strips (multiDisplay)
        // give EVERY monitor its own auto-adopting strip, so this guarantee holds
        // on external monitors too, not just the strip's own display.
        monitor.autoTileEnabled = config.layout.autoTileNewWindows
        monitor.start()
        strip.lifecycle = monitor
    }

    /// Rebuild `strips` so there is exactly one per connected display, each bound
    /// to its display's live geometry and seeded with the shared config. Used by
    /// the multi-display arrange path. Safe to call while dormant (it discards
    /// the placeholder strips and makes fresh ones). The strip whose display is
    /// `NSScreen.main` becomes active so the first hotkey targets the focused
    /// monitor.
    private func rebuildStripsForAllDisplays() {
        let displays = managedDisplays()
        guard !displays.isEmpty else { return }
        strips = displays.map { _ in
            DisplayStrip(engine: TeleportEngine(screenFrame: .zero))
        }
        applyConfigToEngine()
        for (i, d) in displays.enumerated() {
            bindStrip(strips[i], to: d)
        }
        let mainIdx = displays.firstIndex { $0.isMain } ?? 0
        activeStripIndex = strips.indices.contains(mainIdx) ? mainIdx : 0
    }

    /// One connected display described in AX (top-left global) coordinates - the
    /// plane the engine commits positions in. Built from `NSScreen` in
    /// production; a headless test injects synthetic ones via
    /// `debugManagedDisplaysOverride` so the multi-display arrange/partition path
    /// can run against the sim on a single-display CI.
    struct ManagedDisplay {
        var visible: CGRect   // usable area (becomes engine.screenFrame)
        var full: CGRect      // whole display (parking reference)
        var id: CGDirectDisplayID?
        var isMain: Bool
    }

    /// Test-only override for the managed-display set. When non-nil, the
    /// multi-display arrange path uses these synthetic displays instead of
    /// `NSScreen`, so a 1-display CI can exercise the real per-strip logic.
    var debugManagedDisplaysOverride: [ManagedDisplay]?

    /// The displays ScrollWM should run a strip on, in a stable order. Production
    /// maps `NSScreen.screens` to AX frames (one strip per monitor); tests inject
    /// `debugManagedDisplaysOverride`.
    private func managedDisplays() -> [ManagedDisplay] {
        if let override = debugManagedDisplaysOverride { return override }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }
        let primaryHeight = (screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.main ?? screens[0]).frame.height
        let main = NSScreen.main
        return screens.map { s in
            ManagedDisplay(
                visible: DisplayGeometry.axFrame(appKitFrame: s.visibleFrame, primaryHeight: primaryHeight),
                full: DisplayGeometry.axFrame(appKitFrame: s.frame, primaryHeight: primaryHeight),
                id: s.displayID,
                isMain: s === main)
        }
    }

    /// Bind one strip's engine to a managed display's AX geometry: its own
    /// visible area becomes `screenFrame`, its full frame the parking reference,
    /// and every OTHER managed display the parking "others" set (so a parked
    /// column's sliver lands on this strip's own monitor). Shared by the
    /// production (NSScreen) and headless (injected) multi-display paths.
    private func bindStrip(_ strip: DisplayStrip, to display: ManagedDisplay) {
        let others = managedDisplays()
            .filter { $0.full != display.full }
            .map { $0.full }
        strip.engine.stripDisplayFrame = display.full
        strip.engine.otherDisplayFrames = others
        strip.displayID = display.id
        strip.engine.rebindStripDisplay(to: display.visible)
    }

    func arrange(pidFilter: Set<pid_t>? = nil) {
        guard LifecycleMonitor.sessionIsActive() else {
            Log.warn("arrange: session locked/inactive, refusing", "arrange")
            return
        }
        // Reveal hidden apps (Cmd+H) and minimized windows up front so a plain
        // "arrange" tidies EVERYTHING on the current Space, not just what is
        // already visible: the user expects "arrange" to pull hidden/minimized
        // windows onto the strip too. Revealing brings them back onto the
        // CURRENT Space first, so the Space-safety contract still holds (we
        // never reach into another Space). The sandbox/test lock flows straight
        // through, so this can only ever touch the locked pids.
        let reveal = WindowReveal.reveal(pidFilter: sandboxPIDs ?? pidFilter)
        if reveal.didReveal {
            Log.info("arrange: revealed \(reveal.unhiddenApps) hidden app(s), "
                     + "\(reveal.unminimizedWindows) minimized window(s)", "arrange")
            // Adopt what is visible now, then resync after the unhide/
            // de-miniaturize animation lands so the freshly-revealed windows are
            // pulled in too (they are not in the WindowServer on-screen list
            // until the animation finishes). The immediate adopt keeps the
            // synchronous CLI reply meaningful; the deferred pass catches the
            // rest (and starts management even when EVERY window was hidden).
            arrangeAdoptNow(pidFilter: pidFilter)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self else { return }
                if self.isManaging {
                    for strip in self.strips where strip.isManaging { strip.lifecycle?.resync() }
                    self.menuBar.refresh()
                } else {
                    self.arrangeAdoptNow(pidFilter: pidFilter)
                }
            }
            return
        }
        arrangeAdoptNow(pidFilter: pidFilter)
    }

    /// The adopt half of `arrange`: reconcile the current Space's windows into
    /// the strip with NO reveal step (callers reveal first when they want hidden
    /// windows). While ALREADY managing this resyncs every managing strip
    /// (adopting any that appeared, dropping any that closed); from dormant it
    /// adopts the current-Space windows and starts management. The menu-bar
    /// "Arrange Windows into Strip" item and `scrollwm arrange` share this ONE
    /// behavior in every state instead of diverging.
    private func arrangeAdoptNow(pidFilter: Set<pid_t>? = nil) {
        if isManaging {
            // Resync EVERY managing strip so each display reconciles its own
            // windows (one strip in the single-display case).
            for strip in strips where strip.isManaging { strip.lifecycle?.resync() }
            menuBar.refresh()
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
                AXSource.windows(forPID: pid)
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

        if config.layout.multiDisplay && managedDisplays().count > 1 {
            arrangeMultiDisplay(onscreen: onscreen, filter: effectiveFilter)
            return
        }

        // Scope adoption to the strip's own display (default). With one Space
        // spanning multiple monitors, "onscreen" includes windows on OTHER
        // displays; without this filter arrange would yank them onto the strip.
        // `allDisplays` keeps the legacy whole-desktop behavior. Pure policy +
        // the engine's live display geometry live in `filterByAdoptScope`.
        let scoped = engine.filterByAdoptScope(onscreen) { $0.ax.frame }
        engine.adopt(matched: scoped)
        guard !engine.slots.isEmpty else {
            Log.warn("arrange: no manageable windows found", "arrange")
            return
        }
        RestoreStore.save(engine: engine)
        activeStrip.isManaging = true

        startLifecycle(for: activeStrip, filter: effectiveFilter)

        engine.focus(index: 0)
        registerManagementHotkeys()
        menuBar.refresh()
        Log.info("arranged \(engine.slots.count) windows into strip (\(String(format: "%.1f", engine.lastTeleportMs))ms)", "arrange")
    }

    /// Multi-display arrange: one independent strip per monitor. Partitions the
    /// current-Space windows across displays (each window to the display it best
    /// overlaps, exactly once - so two strips never fight over a window), adopts
    /// each slice into that display's engine, and starts a per-strip lifecycle
    /// monitor. Displays with no windows still get a (dormant) strip so a window
    /// opened there later is adopted by its own monitor.
    private func arrangeMultiDisplay(onscreen: [MatchedWindow], filter: Set<pid_t>?) {
        rebuildStripsForAllDisplays()
        // Partition by best display overlap, in NSScreen order (parallel to
        // `strips`). A window overlapping no display falls back to the active
        // strip so it is never lost (mirrors the single-strip safety bias).
        let displayFrames = strips.map { $0.engine.stripDisplayFrame ?? $0.engine.screenFrame }
        let buckets = AdoptionScope.partition(
            frames: onscreen.map { $0.ax.frame },
            displays: displayFrames,
            fallbackIndex: activeStripIndex)

        var totalAdopted = 0
        for (i, strip) in strips.enumerated() {
            let slice = buckets[i].map { onscreen[$0] }
            strip.engine.adopt(matched: slice)
            guard !strip.engine.slots.isEmpty else { continue }
            strip.isManaging = true
            startLifecycle(for: strip, filter: filter)
            strip.engine.focus(index: 0)
            totalAdopted += strip.engine.slots.count
        }
        guard isManaging else {
            print("arrange: no manageable windows found")
            return
        }
        RestoreStore.save(engines: strips.map { $0.engine })
        registerManagementHotkeys()
        menuBar.refresh()
        let live = strips.filter { $0.isManaging }.count
        print("arranged \(totalAdopted) windows across \(live) display strip(s)")
    }

    func release() {
        guard isManaging else { return }
        unregisterManagementHotkeys()
        var failures = 0
        for strip in strips where strip.isManaging {
            strip.lifecycle?.stop()
            strip.lifecycle = nil
            failures += strip.engine.releaseAll()
            strip.isManaging = false
        }
        RestoreStore.clear()
        menuBar.refresh()
        if failures > 0 {
            Log.warn("released: all windows placed (\(failures) failures)", "release")
        } else {
            Log.info("released: all windows placed", "release")
        }
    }

    func toggle() {
        isManaging ? release() : arrange()
    }

    /// Arrange immediately after the user grants Accessibility in first-run
    /// onboarding, so ScrollWM's first visible act is to tidy the desktop with
    /// zero extra clicks. Gated on the `arrangeOnFirstGrant` config (default on)
    /// and a no-op if the user already arranged (e.g. via the CLI in the gap).
    /// Adopts everything on the current Space, including hidden/minimized
    /// windows, exactly like the "Arrange All Windows" menu action.
    func arrangeOnFirstGrant() {
        guard config.arrangeOnFirstGrant else {
            print("first grant: arrangeOnFirstGrant disabled; staying dormant")
            return
        }
        guard !isManaging else { return }
        print("first grant: arranging the desktop automatically")
        arrangeAllWindows()
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

    /// "Arrange All Windows": adopt EVERY window into the strip, even ones that
    /// are currently hidden (Cmd+H'd app) or minimized to the Dock. Hidden and
    /// minimized windows are first revealed onto the CURRENT Space (so the
    /// Space-safety contract still holds - we never reach into another Space),
    /// then the ordinary adopt path picks them up. Arranges the desktop when
    /// dormant, or forces a full resync when already managing. The one-shot
    /// "tidy everything" action from the menu.
    func arrangeAllWindows() {
        // Reveal hidden apps + minimized windows first so they materialize on
        // the current Space and become adoptable. Sandbox/test lock flows
        // straight through, so this can only ever touch the locked pids.
        let reveal = WindowReveal.reveal(pidFilter: sandboxPIDs)
        if reveal.didReveal {
            print("arrange all: revealed \(reveal.unhiddenApps) hidden app(s), "
                  + "\(reveal.unminimizedWindows) minimized window(s)")
        }
        // Unhide / de-miniaturize is animated and lands the windows on-screen a
        // beat later, so adopt after a short delay (skip the wait when nothing
        // was revealed - the common case stays snappy).
        let settle = reveal.didReveal ? 0.45 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            self?.adoptEverythingNow()
        }
    }

    /// Adopt all current-Space windows into the strip and equalize so they are
    /// all visible. Assumes any hidden/minimized windows were already revealed.
    private func adoptEverythingNow() {
        if !isManaging {
            arrange()
            // Equalize right after arranging so the user sees everything at once.
            if isManaging { engine.fitAllColumns(); RestoreStore.save(engine: engine); menuBar.refresh() }
            return
        }
        // Already managing: pull in any newly-revealed/opened current-Space
        // windows, then equalize so the freshly-adopted ones are visible too.
        // `resync` runs its heavy enumeration on a background queue and applies
        // on main, so we equalize once now (current columns) and again shortly
        // after for any windows the resync adopts.
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
        skillTracker?.flush()
        release()
        // If a verified update is staged for on-quit application, launch the
        // detached swapper now: windows have just been restored by release(),
        // and the swapper waits for THIS process to exit before replacing the
        // bundle and relaunching the new version.
        updateCoordinator?.applyPendingUpdateOnQuit()
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
        AXSource.raise(window.element)
        AXSource.setBool(window.element, kAXMainAttribute as String, true)
        AXSource.setBool(window.element, kAXFocusedAttribute as String, true)
        AXSource.activateApp(pid: window.pid)
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

    // MARK: - Multi-display focus / move

    /// Indices of strips that are currently MANAGING a display, in `strips`
    /// (display) order. These are the targets the cross-display focus/move
    /// hotkeys cycle through; a dormant strip (no windows yet) is skipped.
    private var managingStripIndices: [Int] {
        strips.indices.filter { strips[$0].isManaging }
    }

    /// Move keyboard focus to the next/previous MONITOR's strip
    /// (Ctrl+Opt+Cmd+J / K). Focus-follows-display means hotkeys act on whichever
    /// strip is active, so this just advances `activeStripIndex` to the next
    /// managing strip and focuses that strip's focused column (raising its app so
    /// the keyboard follows). No-op with fewer than two managing displays.
    func focusDisplay(by delta: Int) {
        guard isManaging else { return }
        let managing = managingStripIndices
        guard managing.count > 1 else { return }
        // Where does the active strip sit within the managing set? Default to the
        // first if the active strip is somehow dormant.
        let here = managing.firstIndex(of: activeStripIndex) ?? 0
        let next = managing[((here + delta) % managing.count + managing.count) % managing.count]
        guard next != activeStripIndex else { return }
        activeStripIndex = next
        // Focus the destination strip's current column so keyboard input lands
        // there (engine.focus raises + activates the app, moving the OS focus to
        // that monitor). Re-fit if the strip is empty (nothing to focus).
        let dest = strips[next].engine
        if !dest.slots.isEmpty {
            dest.focus(index: dest.focusIndex)
        }
        menuBar.refresh()
    }

    /// Send the focused window to the next/previous MONITOR's strip and follow it
    /// there (Ctrl+Opt+Cmd+Shift+J / K). The window is detached from the current
    /// display's engine and inserted just right of the destination strip's focus,
    /// then physically teleported onto that monitor. No-op with fewer than two
    /// managing displays or nothing focused.
    func moveFocusedToDisplay(by delta: Int) {
        guard isManaging else { return }
        let managing = managingStripIndices
        guard managing.count > 1 else { return }
        let here = managing.firstIndex(of: activeStripIndex) ?? 0
        let destIndex = managing[((here + delta) % managing.count + managing.count) % managing.count]
        guard destIndex != activeStripIndex else { return }

        let source = activeStrip.engine
        source.syncFocusToSystemFocusedWindow()
        guard let moved = source.detachFocusedSlot() else { return }

        let dest = strips[destIndex].engine
        // Insert just right of the destination's focused column (PaperWM-style),
        // adopting the slot's existing identity/size so the window keeps its
        // dimensions, then re-pack + focus it so it teleports onto the new
        // monitor and the viewport reveals it.
        let insertAt = dest.slots.isEmpty ? 0 : dest.focusIndex + 1
        dest.adoptDetachedSlot(moved, at: insertAt)
        activeStripIndex = destIndex
        dest.focus(index: insertAt)

        RestoreStore.save(engines: strips.map { $0.engine })
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

    /// Resize EVERY column to the same fraction of the strip width
    /// (CLI `width all <N>` and `arrange <N>`). Returns the number of columns a
    /// resize was issued for, so the caller can report it. No-op while dormant.
    @discardableResult
    func setAllWidthsFraction(_ fraction: CGFloat) -> Int {
        guard isManaging else { return 0 }
        let n = engine.setAllWidths(fraction: fraction)
        menuBar.refresh()
        return n
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
    var debugFocusIndex: Int { engine.focusIndex }
    var debugSlotTitles: [String] { engine.slots.map { $0.window.title } }
    /// Count of current-Space windows the active strip is NOT tiling (the
    /// "floating" set). Headless-test introspection for the auto-tile invariant.
    var debugFloatingCount: Int { floatingWindows.count }
    /// Force a synchronous resync of the active strip's lifecycle monitor (the
    /// 2s safety-net poll, but now). Headless tests use it to drive the
    /// floating-recompute + auto-tile sweep deterministically instead of waiting
    /// on the timer. No-op while dormant.
    func debugTriggerResync() { lifecycle?.resync() }
    /// Widen/replace the active strip lifecycle monitor's PID filter at runtime.
    /// Headless tests use it to bring a stray sim window (opened after arrange,
    /// with a different PID) into the monitor's scope so the auto-tile sweep can
    /// see it. No-op while dormant.
    func debugSetLifecyclePIDFilter(_ pids: Set<pid_t>?) { lifecycle?.pidFilter = pids }
    /// Toggle the active strip's auto-tile flag live (headless test of the
    /// flag-off path). Mirrors what `reloadConfig` would push from config.
    func debugSetAutoTile(_ enabled: Bool) {
        config.layout.autoTileNewWindows = enabled
        for strip in strips { strip.lifecycle?.autoTileEnabled = enabled }
    }
    /// Titles of the columns the engine has SUSPENDED (native fullscreen or
    /// diverged to another Space): kept in the strip but excluded from layout +
    /// every AX write. For the Space/fullscreen integration tests.
    var debugSuspendedTitles: [String] {
        engine.slots.filter { $0.window.suspended }.map { $0.window.title }
    }
    /// canvasX of each column (strip order), so a test can prove a suspended
    /// column reserves no gap (its right neighbor slides in).
    var debugSlotCanvasX: [CGFloat] { engine.slots.map { $0.canvasX } }
    /// Per-column widths (strip order), for the bulk-width (`width all` /
    /// `arrange N`) integration assertions.
    var debugColumnWidths: [CGFloat] { engine.slots.map { $0.width } }

    /// Per-strip slot titles (display order), for the multi-display focus/move
    /// integration test. Reads the SAME engines production drives.
    var debugStripTitles: [[String]] { strips.map { $0.engine.slots.map { $0.window.title } } }
    /// Index of the strip global hotkeys currently act on (focus-follows-display).
    var debugActiveStripIndex: Int { activeStripIndex }
    /// Drive the cross-display focus verb (Ctrl+Opt+Cmd+J/K) in a headless test.
    func debugFocusDisplay(by delta: Int) { focusDisplay(by: delta) }
    /// Drive the cross-display move verb (Ctrl+Opt+Cmd+Shift+J/K) in a test.
    func debugMoveFocusedToDisplay(by delta: Int) { moveFocusedToDisplay(by: delta) }

    /// Headless seam: turn on the multi-display arrange path and inject a
    /// synthetic set of displays, so the per-monitor strip routing (and the
    /// cross-display focus/move verbs) can be exercised on a single-display CI
    /// against the sim. Call BEFORE `arrange()`. `displays` are AX (top-left
    /// global) frames; the first is treated as primary/main.
    func debugEnableMultiDisplay(_ displays: [(full: CGRect, visible: CGRect)]) {
        config.layout.multiDisplay = true
        debugManagedDisplaysOverride = displays.enumerated().map { (i, d) in
            ManagedDisplay(visible: d.visible, full: d.full,
                           id: CGDirectDisplayID(1000 + i), isMain: i == 0)
        }
    }
    var debugFocusedTitle: String {
        engine.slots.indices.contains(engine.focusIndex) ? engine.slots[engine.focusIndex].window.title : ""
    }
    var debugFocusedWidth: CGFloat {
        engine.slots.indices.contains(engine.focusIndex) ? engine.slots[engine.focusIndex].width : 0
    }
    func debugWidth(forFraction f: CGFloat) -> CGFloat { engine.width(forFraction: f) }
    var debugActiveWorkspace: Int { engine.stripState.activeWorkspace }
    var debugWorkspaceCount: Int { engine.stripState.workspaceCount }
    /// The key-hint text the menu-bar icon is currently flashing (nil if idle).
    var debugHintText: String? { menuBar.debugHintText }

    /// Headless test seam: deliver a key chord exactly as a real keypress would
    /// route through ScrollWM, with NO CGEvent injected (so nothing leaks to the
    /// user's focused app). Routing mirrors production precedence: the management
    /// keyboard tap is head-insert and suppresses any chord it matches BEFORE the
    /// focused app or Carbon see it; only if the tap does not consume the chord
    /// do the always-on Carbon hotkeys (navigation/jump/toggle) get it. Returns
    /// true if some binding handled it.
    @discardableResult
    func debugDeliverChord(keyCode: UInt32, cgFlags: CGEventFlags, carbonModifiers: UInt32) -> Bool {
        if let tap = moveTap, tap.debugDeliver(keyCode: Int64(keyCode), flags: cgFlags) {
            return true
        }
        return hotkeys.debugDeliver(keyCode: keyCode, modifiers: carbonModifiers)
    }

    /// Convenience: deliver a parsed `Chord` (uses both its CG flags for the tap
    /// and its Carbon modifiers for the hotkey path).
    @discardableResult
    func debugDeliverChord(_ chord: Chord) -> Bool {
        debugDeliverChord(keyCode: chord.keyCode, cgFlags: chord.cgFlags, carbonModifiers: chord.carbonModifiers)
    }

    // --- Multi-display debug accessors (for the `displaytest` integration) ---
    // These read/relay the SAME engine the production controller drives, so the
    // test asserts real behavior, not a parallel mock.

    /// The strip's current usable (visible) frame in AX global coords.
    var debugScreenFrame: CGRect { engine.screenFrame }
    /// Peek lane (px) reserved at each screen edge for parked-window slivers.
    var debugPeekInset: CGFloat { engine.peekInset }
    /// The usable content region (screen inset by the peek lane on each side),
    /// in AX global coords. On-screen columns are confined to this rect's x-span.
    var debugContentRegionX: (origin: CGFloat, width: CGFloat) {
        (engine.contentOriginX, engine.contentWidth)
    }
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

    /// Drive the REAL settled-display-change policy (`applySettledDisplayChange`)
    /// from a headless test with an injected display set, bypassing only the live
    /// `NSScreen` read + the debounce timer. Each tuple is one connected display
    /// in AppKit coordinates (full frame, visible frame, stable id), in NSScreen
    /// order. This exercises the exact production resolve + AppKit->AX re-flip +
    /// rebind used when a monitor is plugged/unplugged or the laptop lid closes
    /// (clamshell), so the clamshell/equal-display glitch is reproducible with no
    /// real monitors.
    func debugApplyDisplayChange(_ displays: [(full: CGRect, visible: CGRect, id: CGDirectDisplayID?)]) {
        let snaps = displays.enumerated().map { (i, d) in
            DisplaySnapshot(fullAppKit: d.full, visibleAppKit: d.visible, id: d.id,
                            name: "SimDisplay-\(i)")
        }
        applySettledDisplayChange(displays: snaps)
    }

    /// Bind the active strip to an injected display set BEFORE arranging, for the
    /// headless display-change test (the equivalent of launching on a given
    /// monitor layout). Same snapshot core as production launch/move.
    func debugBindStrip(to displays: [(full: CGRect, visible: CGRect, id: CGDirectDisplayID?)],
                        stripIndex: Int) {
        let snaps = displays.enumerated().map { (i, d) in
            DisplaySnapshot(fullAppKit: d.full, visibleAppKit: d.visible, id: d.id,
                            name: "SimDisplay-\(i)")
        }
        refreshDisplayGeometry(for: activeStrip, displays: snaps,
                               stripIndex: stripIndex, relayout: true)
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
            hotkeys.registerRaw(keyCode: chord.keyCode, modifiers: chord.carbonModifiers) { [weak self] in
                self?.focusNext(); self?.flashKeybinding(.focusNext)
            }
        }
        for chord in config.chords(for: .focusPrevious) where chord.hasKey {
            hotkeys.registerRaw(keyCode: chord.keyCode, modifiers: chord.carbonModifiers) { [weak self] in
                self?.focusPrevious(); self?.flashKeybinding(.focusPrevious)
            }
        }
        for chord in config.chords(for: .toggleArrange) where chord.hasKey {
            hotkeys.registerRaw(keyCode: chord.keyCode, modifiers: chord.carbonModifiers) { [weak self] in
                self?.toggle(); self?.flashKeybinding(.toggleArrange)
            }
        }
        // Jump: the modifier-only `jumpModifier` chord + digit keys 1-9.
        if let jumpStr = (config.keybindings[.jumpModifier] ?? KeyAction.defaultChords[.jumpModifier] ?? []).first,
           let jump = Chord(string: jumpStr) {
            let jumpPretty = TutorialWindowController.pretty(jumpStr)
            for (i, key) in HotkeyManager.Key.digits.enumerated() {
                hotkeys.registerRaw(keyCode: key.rawValue, modifiers: jump.carbonModifiers) { [weak self] in
                    self?.focus(index: i)
                    self?.flashKeybinding(.jumpModifier, chordOverride: "\(jumpPretty)\(i + 1)")
                }
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
        //
        // Each binding also flashes the chord + action in the menu-bar icon
        // (see `flashKeybinding`), so the user sees what they pressed. We bind
        // per CONFIGURED chord string (not the parsed `Chord`) so the flash
        // shows the exact trigger that fired (e.g. Opt+1 vs Cmd+1 for width).
        func bind(_ action: KeyAction, _ handler: @escaping () -> Void) {
            for str in config.keybindings[action] ?? KeyAction.defaultChords[action] ?? [] {
                guard let chord = Chord(string: str), chord.hasKey else { continue }
                let pretty = TutorialWindowController.pretty(str)
                tap.addCombo(keyCode: Int64(chord.keyCode), flags: chord.cgFlags) { [weak self] in
                    handler()
                    self?.flashKeybinding(action, chordOverride: pretty)
                }
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
        bind(.focusDisplayNext) { [weak self] in self?.focusDisplay(by: 1) }
        bind(.focusDisplayPrevious) { [weak self] in self?.focusDisplay(by: -1) }
        bind(.moveToDisplayNext) { [weak self] in self?.moveFocusedToDisplay(by: 1) }
        bind(.moveToDisplayPrevious) { [weak self] in self?.moveFocusedToDisplay(by: -1) }
        bind(.spawnTerminal) { TerminalLauncher.launchBest() }

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
                Log.warn("signal received: restoring windows and exiting", "lifecycle")
                Log.flush()
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

    /// Periodic visibility re-check so the item re-heals if another app pushes
    /// it out of the menu bar after launch (see `ensureVisible`).
    private var visibilityWatchdog: Timer?
    /// Observer for app-activation, the usual trigger for our item being pushed
    /// out of the menu bar; lets us re-heal immediately rather than on the next
    /// watchdog tick. Removed in `deinit`.
    private var appActivationObserver: NSObjectProtocol?

    static let autosaveName = "ScrollWMMain"

    /// Preferred status-item position (points from the right of the status
    /// area). Small = high priority: it sits next to the system cluster so it
    /// is the LAST third-party item macOS hides when the bar runs out of room.
    static let priorityPosition: Double = 8.0

    init(controller: ScrollWMController, engine: TeleportEngine) {
        self.controller = controller
        self.engine = engine
        super.init()

        // Seed the mini-map sizing from config and start at the configured floor.
        let mb = controller.config.menuBar
        stripView.pointsPerScreen = mb.pointsPerScreen
        stripView.minContentWidth = mb.minWidth
        stripView.maxContentWidth = mb.maxWidth
        stripView.showWorkspaceNumber = mb.showWorkspaceNumber
        stripView.showAllWorkspaces = mb.showAllWorkspaces
        contentWidth = mb.minWidth

        // Priority placement + notch workaround (see MenuBarController).
        // The "Preferred Position" is measured from the RIGHT of the status
        // area: SMALL values land near the system cluster (clock / Control
        // Center), which is the highest-priority slot because macOS hides the
        // LEFTMOST third-party items first when the bar gets crowded (e.g. an
        // app with a wide menu activates). Seeding a small value makes ScrollWM
        // the last item to be hidden, so it stays "always showing."
        //
        // When `pinHighPriority` is on (the default) we FORCE that top slot on
        // every launch so ScrollWM reliably wins it even if a prior drag (or a
        // value AppKit persisted) parked us in a lower-priority position. With
        // the pin off we only seed when unset, so a user's manual drag wins.
        let positionKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if controller.config.menuBar.pinHighPriority {
            UserDefaults.standard.set(Self.priorityPosition, forKey: positionKey)
        } else if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(Self.priorityPosition, forKey: positionKey)
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

        // Watchdog: another app can push us out of view later (e.g. it
        // activates with a wide menu bar). Re-check periodically and re-heal so
        // ScrollWM stays "always showing" rather than only at launch. Reassert
        // `isVisible` every tick too: it is cheap and pins the item shown even
        // if something flips the flag. A 2s cadence re-heals promptly without
        // measurable cost (the check is a couple of frame reads).
        visibilityWatchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.statusItem?.isVisible = true
            if !self.isVisibleInMenuBar {
                self.healAttempt = 0
                self.ensureVisible()
            }
        }

        // Event-driven re-heal: the usual cause of our item being squeezed out
        // is ANOTHER app activating with a wide menu bar (which shrinks the
        // third-party status area). React the moment that happens instead of
        // waiting up to a full watchdog tick, so the icon never visibly
        // disappears. A short delay lets the system settle the new menu bar
        // layout before we measure + re-place.
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                self.statusItem?.isVisible = true
                if !self.isVisibleInMenuBar {
                    self.healAttempt = 0
                    self.ensureVisible()
                }
            }
        }

        engine.onLayoutChange = { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    private func createStatusItem() {
        // Headless test mode: do NOT create a real menu-bar status item. It would
        // briefly add an icon to the user's menu bar during a test run, which is
        // visible desktop noise (even if it never steals focus). The controller
        // logic the headless tests exercise does not depend on it.
        if AXSource.backend != nil { return }

        // Length tracks the live mini-map width (content + padding). Starts at
        // the configured floor; grows/shrinks as windows are added/removed.
        statusItem = NSStatusBar.system.statusItem(withLength: contentWidth + Self.hPadding)
        statusItem.autosaveName = NSStatusItem.AutosaveName(Self.autosaveName)
        // "Always showing" contract: force the item visible (defends against a
        // visibility=false that AppKit may have persisted under our autosaveName
        // from a prior run or an errant drag) and forbid user removal, so the
        // icon cannot be dragged out of the menu bar. The user asked for it to
        // never leave the bar, so we override any saved-hidden state.
        statusItem.isVisible = true
        statusItem.behavior = []   // no .removalAllowed -> cannot be removed

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
        // The strip self-limits to maxContentWidth; the key-hint HUD may append
        // text to its right and request a wider icon. Allow that extra room so
        // the hint is never clipped, but still cap the total so a runaway width
        // can't eat the menu bar.
        let ceiling = stripView.maxContentWidth + MenuBarStripView.maxHintExtraWidth
        let clamped = max(stripView.minContentWidth, min(width, ceiling))
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
        // No status item in headless test mode; nothing to place.
        if statusItem == nil { return }
        guard !isVisibleInMenuBar else {
            if healAttempt > 0 {
                print("menubar: item visible after \(healAttempt) placement attempt(s)")
            }
            healAttempt = 0
            return
        }
        // Candidate preferred positions (points from the right edge area).
        // SMALL values sit nearest the system cluster, the highest-priority
        // slots that stay visible longest.
        //
        // When pinned (the default), we REASSERT the top-priority slot first,
        // a few times: re-seeding the smallest position makes macOS keep
        // ScrollWM and hide the LEFTMORE third-party items instead, which is
        // exactly "stay visible even when the bar is crowded." Only if the bar
        // is so full that even the top slot can't land do we walk outward as a
        // last resort so the icon is at least reachable somewhere. With the pin
        // off we walk outward from the start (ordinary item behavior).
        let candidates: [Double]
        if controller.config.menuBar.pinHighPriority {
            candidates = [Self.priorityPosition, Self.priorityPosition, Self.priorityPosition,
                          24, 48, 80, 120, 180, 260, 360]
        } else {
            candidates = [Self.priorityPosition, 24, 48, 80, 120, 180, 260, 360]
        }
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

    deinit {
        visibilityWatchdog?.invalidate()
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
    }

    func refresh() {
        // Feed the live engine state into the animated view; it diffs against
        // the previous state and animates the change at the display's refresh
        // rate, then idles its display link once everything settles.
        stripView.apply(state: engine.stripState, managing: controller.isManaging)
    }

    /// Flash a key-hint over the menu-bar icon: the chord just pressed and the
    /// action it triggered. No-op when the feature is disabled in config, so the
    /// hot keypress path stays cheap. Called on the main thread (hotkey handlers).
    func flashKeyHint(chord: String, action: String) {
        guard controller.config.menuBar.showKeyHints else { return }
        stripView.flashKeyHint(chord: chord, action: action)
    }

    /// The HUD text currently shown (headless-test introspection).
    var debugHintText: String? { stripView.debugHintText }

    /// Re-read mini-map sizing from config (called on Reload Config) and apply
    /// it live: the next `refresh()` re-evaluates the desired width.
    func applyConfig(_ config: ScrollWMConfig) {
        let mb = config.menuBar
        stripView.pointsPerScreen = mb.pointsPerScreen
        stripView.minContentWidth = mb.minWidth
        stripView.maxContentWidth = mb.maxWidth
        stripView.showWorkspaceNumber = mb.showWorkspaceNumber
        stripView.showAllWorkspaces = mb.showAllWorkspaces
        // Re-clamp the current item to the new bounds immediately.
        setContentWidth(contentWidth)
        // If the high-priority pin is ON, reclaim the top slot now (config
        // reload is a deliberate, infrequent action). Re-seed the preference
        // and recreate the item so the new preferred position takes effect (it
        // is only read at creation time), then re-heal if the bar is crowded.
        if mb.pinHighPriority, statusItem != nil {
            UserDefaults.standard.set(Self.priorityPosition,
                                      forKey: "NSStatusItem Preferred Position \(Self.autosaveName)")
            NSStatusBar.system.removeStatusItem(statusItem)
            createStatusItem()
            healAttempt = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.ensureVisible()
            }
        }
        refresh()
    }

    var isVisibleInMenuBar: Bool {
        guard let statusItem, statusItem.isVisible, let window = statusItem.button?.window else { return false }
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

            let arrangeAllItem = NSMenuItem(title: "Arrange All Windows (reveal + fit on screen)", action: #selector(arrangeAllAction), keyEquivalent: "")
            arrangeAllItem.target = self
            menu.addItem(arrangeAllItem)

            // Same verb as the `scrollwm arrange` CLI: re-adopt the current
            // Space's windows into the strip (idempotent while managing). Kept
            // enabled so the menu item and the command always do the same thing.
            let arrangeItem = NSMenuItem(title: "Arrange Windows into Strip (incl. hidden & minimized)", action: #selector(arrangeAction), keyEquivalent: "")
            arrangeItem.target = self
            menu.addItem(arrangeItem)
        } else {
            let header = NSMenuItem(title: "ScrollWM — dormant (not touching any window)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())

            let arrangeItem = NSMenuItem(title: "Arrange Windows into Strip (incl. hidden & minimized)", action: #selector(arrangeAction), keyEquivalent: "")
            arrangeItem.target = self
            menu.addItem(arrangeItem)

            let arrangeAllItem = NSMenuItem(title: "Arrange All Windows (reveal + fit on screen)", action: #selector(arrangeAllAction), keyEquivalent: "")
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

        // Gentle, non-modal nudge: if the user has mastered a core shortcut and
        // then drifted back to the menu for it, show the keybinding they've
        // stopped using. Disabled (info-only) row; absent when all sharp.
        if let rusty = controller.rustyKeybindingHint {
            let tip = NSMenuItem(title: "💡 \(rusty)", action: nil, keyEquivalent: "")
            tip.isEnabled = false
            menu.addItem(tip)
        }

        let tutorial = NSMenuItem(title: "How to Use ScrollWM…", action: #selector(showTutorial), keyEquivalent: "")
        tutorial.target = self
        menu.addItem(tutorial)

        let openConfig = NSMenuItem(title: "Open Config File", action: #selector(openConfigFile), keyEquivalent: "")
        openConfig.target = self
        menu.addItem(openConfig)

        let reload = NSMenuItem(title: "Reload Config", action: #selector(reloadConfigAction), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)

        let checkUpdates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        checkUpdates.target = self
        menu.addItem(checkUpdates)

        // Info-only row: the running app's version, so users can confirm what
        // they're on (mirrors `scrollwm --version`). Click copies it to the
        // clipboard for easy bug reports.
        let version = NSMenuItem(title: "Version \(AppVersion.currentString)", action: #selector(copyVersionAction), keyEquivalent: "")
        version.target = self
        version.toolTip = "Click to copy the version"
        menu.addItem(version)

        // Launch at login: a checkbox toggle. Only meaningful for the installed
        // ScrollWM.app, so it is disabled (info-only) on a dev binary. The check
        // mark reflects the LIVE registration so the user sees the real state.
        if controller.launchAtLoginSupported {
            let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLoginAction), keyEquivalent: "")
            login.target = self
            login.state = controller.launchAtLoginEnabled ? .on : .off
            menu.addItem(login)
        }

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

    @objc private func selectWindow(_ sender: NSMenuItem) {
        // Pointer equivalent of the jump-to-column keybinding (⌃⌥+digit).
        controller.recordPointerUse(.jumpModifier)
        controller.focus(index: sender.tag)
    }
    @objc private func selectFloating(_ sender: NSMenuItem) {
        let floating = controller.floatingWindows
        guard floating.indices.contains(sender.tag) else { return }
        // Tile a normal window onto the strip; just raise a dialog/panel.
        controller.tileFloating(floating[sender.tag])
    }
    @objc private func tileAllFloatingAction() { controller.tileAllFloating() }
    @objc private func arrangeAction() {
        // Clicking "Arrange" from a dormant state is the pointer equivalent of
        // the arrange/release toggle key; while already managing this item just
        // re-syncs (no keybinding equivalent), so only the toggle counts.
        let wasDormant = !controller.isManaging
        controller.arrange()
        if wasDormant, controller.isManaging { controller.recordPointerUse(.toggleArrange) }
    }
    @objc private func releaseAction() {
        // Release is the pointer equivalent of the arrange/release toggle key.
        controller.recordPointerUse(.toggleArrange)
        controller.release()
    }
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
    @objc private func checkForUpdatesAction() { controller.checkForUpdates() }
    @objc private func copyVersionAction() {
        // Copy the bare version string (e.g. "0.1.5") so it pastes cleanly into
        // a bug report. Uses the same source as the menu title / `scrollwm --version`.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(AppVersion.currentString, forType: .string)
    }
    @objc private func toggleLaunchAtLoginAction() {
        // Flip to the opposite of the live registration state.
        _ = controller.setLaunchAtLogin(!controller.launchAtLoginEnabled)
    }
}

// MARK: - Entry

func runScrollWM(selftest: Bool, crashPhase: CrashTestPhase = .none) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // Durable logging: capture uncaught exceptions + fatal signals (so a crash
    // like the tutorial NSRangeException leaves a symbolicated trail), and mark
    // the start of this session in the on-disk log. No-ops under a test backend.
    Log.installCrashHandlers()
    Log.info("ScrollWM \(AppVersion.currentString) starting (pid \(getpid()))", "lifecycle")

    // Before anything else: if we are running from a Gatekeeper-translocated
    // ghost path or a transient home (a download / mounted .dmg), the
    // Accessibility grant can never stick. Relocate to ~/Applications and
    // relaunch from there so the user grants the permission exactly once.
    // Skipped automatically during tests/dev (selftest, or non-`.app` binary).
    if !selftest && crashPhase == .none && AppRelocator.relocateIfNeeded() {
        // We've launched the stable copy and are about to exit; do not start
        // the controller, menu bar, or AX flow from this throwaway process.
        DispatchQueue.main.async { NSApp.terminate(nil) }
        app.run()
        return
    }

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
        Log.info("ScrollWM running (dormant). Use the menu bar item, the toggle key, or the `scrollwm` CLI to arrange.", "lifecycle")
        controller.showTutorialOnFirstRunIfNeeded()
        controller.startUpdates()
        controller.startSkillTracking()
        controller.reconcileLaunchAtLogin()
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

    // Present the onboarding window (idempotent). Wired into the launch
    // decision below; the window itself decides whether to fire the one-time
    // system modal via `AccessibilityPermission.shouldAutoPrompt`, so this is
    // safe to call on both a genuine first run and a real later revocation.
    func presentOnboarding() {
        guard !started, onboardingKeepAlive == nil else { return }
        let ob = OnboardingWindowController()
        ob.onGranted = {
            startOnce()
            // This is a FRESH, user-initiated grant via onboarding (not a
            // transient relaunch of an already-trusted app), so arrange the
            // desktop right away — ScrollWM's first visible act tidies the
            // windows with zero extra clicks. Defer a beat so the onboarding
            // window has finished closing / restoring hidden apps first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                controller.arrangeOnFirstGrant()
            }
        }
        ob.present()
        onboardingKeepAlive = ob
    }

    // The launch decision (start silently / wait silently for a stale `false`
    // to clear / surface onboarding) is the PURE `PermissionPolicy.launchAction`
    // — the SAME function the unit tests pin down — so the tested logic is the
    // logic that actually runs. It encodes the central guarantee: never ask the
    // user when Accessibility is already on, and never re-fire the system modal
    // on a machine that has been granted before (a launch-time `false` there is
    // almost always a stale TCC reading after an update, not a real revocation).
    let perm = AccessibilityPermission.shared
    let launchStart = Date()
    var announcedSilentWait = false

    func evaluateLaunch() {
        let action = PermissionPolicy.launchAction(
            isTrusted: perm.isTrustedNow,
            hasPrompted: perm.hasPrompted,
            hasEverBeenGranted: perm.hasEverBeenGranted,
            elapsed: Date().timeIntervalSince(launchStart))
        switch action {
        case .start:
            launchPollKeepAlive?.invalidate(); launchPollKeepAlive = nil
            perm.startLiveUpdates()
            startOnce()
        case .waitSilently:
            // Inside a grace window: show nothing, fire nothing. On an
            // ever-granted machine the wait is extended (a `false` is stale),
            // so note it once for the logs.
            if perm.hasEverBeenGranted && !announcedSilentWait {
                announcedSilentWait = true
                print("ScrollWM: Accessibility not yet readable at launch; waiting silently (no prompt).")
            }
        case .showOnboarding:
            launchPollKeepAlive?.invalidate(); launchPollKeepAlive = nil
            perm.startLiveUpdates()
            if !perm.hasEverBeenGranted {
                print("""
                ScrollWM needs Accessibility permission (its only permission).
                Grant it in: System Settings -> Privacy & Security -> Accessibility
                Waiting for grant... (the app will start automatically)
                """)
            }
            presentOnboarding()
        }
    }

    // Evaluate immediately (a granted machine starts with zero delay), then on
    // a fixed cadence until the decision is terminal. A repeating timer — not a
    // state-change observer — is what makes the extended silent window actually
    // resolve to onboarding when trust never returns (the prior observer-only
    // path could leave a genuine revocation as an invisible dead end, because
    // the observer fires only on a state CHANGE that never came).
    evaluateLaunch()
    if !started {
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in evaluateLaunch() }
        RunLoop.main.add(timer, forMode: .common)
        launchPollKeepAlive = timer
    }

    app.run()
}

/// Keep app-lifetime objects created inside closures from being deallocated.
var scrollWMControllerKeepAlive: ScrollWMController?
var onboardingKeepAlive: OnboardingWindowController?
/// The launch-time permission poll timer (drives `PermissionPolicy.launchAction`
/// on a fixed cadence until the decision is terminal). Held so it isn't
/// deallocated mid-resolution; invalidated and cleared once we start or show
/// onboarding.
var launchPollKeepAlive: Timer?

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
