import Foundation
import AppKit
import QuartzCore

// MARK: - Spring

/// A damped harmonic oscillator parameterized the SwiftUI way: `response`
/// (the perceptual "speed", roughly the period of one oscillation in seconds)
/// and `dampingFraction` (1 = critically damped / no overshoot, < 1 = bouncy).
///
/// Pure value type, integrated with a fixed-substep semi-implicit Euler so it
/// stays stable even when a frame hitches. No AppKit dependency: unit-testable
/// in isolation (see `MenuBarAnimationTests`).
struct Spring {
    var value: Double
    var target: Double
    var velocity: Double = 0

    /// Period-like responsiveness in seconds. Smaller = snappier.
    var response: Double = 0.32
    /// 1 = critically damped (no overshoot); < 1 overshoots and settles.
    var dampingFraction: Double = 0.78

    init(_ value: Double = 0, response: Double = 0.32, dampingFraction: Double = 0.78) {
        self.value = value
        self.target = value
        self.response = response
        self.dampingFraction = dampingFraction
    }

    /// Stiffness (omega^2) from response: omega = 2*pi/response.
    private var stiffness: Double {
        let omega = 2 * Double.pi / max(response, 0.0001)
        return omega * omega
    }
    /// Damping coefficient: 2 * zeta * omega.
    private var dampingCoeff: Double {
        let omega = 2 * Double.pi / max(response, 0.0001)
        return 2 * dampingFraction * omega
    }

    /// Advance by `dt` seconds toward `target`. Sub-stepped for stability.
    mutating func step(_ dt: Double) {
        guard dt > 0 else { return }
        let maxStep = 1.0 / 240.0
        var remaining = min(dt, 0.1) // clamp pathological hitches
        let k = stiffness
        let c = dampingCoeff
        while remaining > 0 {
            let h = min(remaining, maxStep)
            let accel = -k * (value - target) - c * velocity
            velocity += accel * h
            value += velocity * h
            remaining -= h
        }
    }

    /// Add an instantaneous velocity impulse (for "pop"/pulse effects).
    mutating func kick(_ impulse: Double) { velocity += impulse }

    /// Snap to a value with no motion (used to seed initial state).
    mutating func reset(to v: Double) { value = v; target = v; velocity = 0 }

    var isSettled: Bool {
        abs(value - target) < 0.0015 && abs(velocity) < 0.0015
    }
}

// MARK: - Action inference

/// A user-meaningful change inferred by diffing two `StripState` snapshots.
/// Pure data so the inference can be unit-tested without a live menu bar.
enum MenuBarAction: Equatable {
    case arrange                                   // dormant -> managing
    case release                                   // managing -> dormant
    case focusChanged(toID: UInt64, direction: Int) // window switch (dir: -1 left, +1 right)
    case added([UInt64])                           // windows opened
    case removed([UInt64])                         // windows closed
    case resized([UInt64])                         // column width changed
    case reordered([UInt64])                       // columns swapped order
}

enum MenuBarDiff {
    /// Infer the set of expressive actions between two states.
    ///
    /// Ordering matters for the view: structural changes (arrange/release/
    /// add/remove/reorder) are reported before focus so flourishes layer
    /// sensibly, but each is independent and the view handles any subset.
    static func infer(
        old: TeleportEngine.StripState?,
        oldManaging: Bool,
        new: TeleportEngine.StripState,
        newManaging: Bool
    ) -> [MenuBarAction] {
        var actions: [MenuBarAction] = []

        // Mode transitions dominate: arranging/releasing reframes everything,
        // so we don't also report the whole initial set as individual
        // adds/reorders — the arrange/release flourish covers it.
        if !oldManaging && newManaging {
            if !new.slots.isEmpty { actions.append(.arrange) }
            return actions
        }
        if oldManaging && !newManaging {
            actions.append(.release)
            return actions
        }
        // Below here both snapshots are in the same managing regime; only then
        // are per-window adds/removes/reorders/resizes meaningful.
        guard oldManaging && newManaging else { return actions }

        let oldIDs = old?.slots.map { $0.id } ?? []
        let newIDs = new.slots.map { $0.id }
        let oldSet = Set(oldIDs)
        let newSet = Set(newIDs)

        let added = newIDs.filter { !oldSet.contains($0) }
        let removed = oldIDs.filter { !newSet.contains($0) }
        if !added.isEmpty { actions.append(.added(added)) }
        if !removed.isEmpty { actions.append(.removed(removed)) }

        // Reorder: survivors whose relative order flipped.
        let survivorsOld = oldIDs.filter { newSet.contains($0) }
        let survivorsNew = newIDs.filter { oldSet.contains($0) }
        if survivorsOld != survivorsNew && Set(survivorsOld) == Set(survivorsNew) {
            actions.append(.reordered(survivorsNew))
        }

        // Resize: survivors whose width changed materially.
        if let old {
            var oldWidth: [UInt64: CGFloat] = [:]
            for s in old.slots { oldWidth[s.id] = s.width }
            let resized = new.slots.compactMap { s -> UInt64? in
                guard let w = oldWidth[s.id] else { return nil }
                return abs(w - s.width) > 1.0 ? s.id : nil
            }
            if !resized.isEmpty { actions.append(.resized(resized)) }
        }

        // Focus change: compare the focused window's stable id.
        let oldFocusID = focusedID(old)
        let newFocusID = focusedID(new)
        if let newFocusID, newFocusID != oldFocusID {
            // Direction from canvas position when both known, else index sign.
            var direction = 1
            if let old, let oldFocusID,
               let a = old.slots.first(where: { $0.id == oldFocusID })?.canvasX,
               let b = new.slots.first(where: { $0.id == newFocusID })?.canvasX {
                direction = b >= a ? 1 : -1
            }
            actions.append(.focusChanged(toID: newFocusID, direction: direction))
        }

        return actions
    }

    private static func focusedID(_ state: TeleportEngine.StripState?) -> UInt64? {
        guard let state, state.slots.indices.contains(state.focusIndex) else { return nil }
        return state.slots[state.focusIndex].id
    }
}

// MARK: - Width metrics (pure, unit-testable)

/// Maps a strip's canvas extent to the icon's on-screen content width.
///
/// The mini-map uses a FIXED density rather than always compressing the whole
/// strip into a constant-width icon: one full screen of strip maps to
/// `pointsPerScreen` icon points, so a 25% column is always a quarter of that,
/// a 50% column always half, regardless of how many windows exist. As the
/// strip grows past one screen the icon grows too, until it hits `maxWidth`
/// (so it never eats the menu bar); only then does the map compress to fit.
enum MenuBarMetrics {
    /// Icon content width (points) for a strip whose live canvas spans `span`
    /// points, where one screen equals `screenWidth` canvas points. Clamped to
    /// `[minWidth, maxWidth]`.
    static func contentWidth(span: CGFloat, screenWidth: CGFloat,
                             pointsPerScreen: CGFloat,
                             minWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
        guard screenWidth > 0, span > 0 else { return minWidth }
        let raw = (span / screenWidth) * pointsPerScreen
        return min(max(raw, minWidth), max(minWidth, maxWidth))
    }
}

// MARK: - Visual slot

/// One animated column. Geometry lives in canvas points (matching the engine's
/// strip model) and is mapped to icon pixels at draw time, so scrolling the
/// viewport and reflowing columns both read as continuous motion.
private final class VisualSlot {
    let id: UInt64
    /// App identity, used to tint the column (kept fresh on reconcile so a
    /// terminal that switches to a different agent recolors live).
    var appColor: NSColor = NSColor.secondaryLabelColor
    var x: Spring               // canvasX (left edge)
    var width: Spring
    var focus = Spring(0, response: 0.26, dampingFraction: 0.9)
    var presence: Spring        // 0 = gone, 1 = present (enter/exit)
    var health = Spring(1, response: 0.4, dampingFraction: 1.0)
    var pop = Spring(0, response: 0.34, dampingFraction: 0.62) // transient pulse
    var exiting = false
    /// Don't integrate until this time (used to stagger the arrange sweep).
    var activateAt: CFTimeInterval = 0

    init(id: UInt64, canvasX: Double, width: Double, present: Double, enter: Bool) {
        self.id = id
        self.x = Spring(canvasX, response: 0.34, dampingFraction: 0.8)
        // Entering columns grow from zero width; established ones start at size.
        self.width = Spring(enter ? max(2, width * 0.15) : width,
                            response: 0.34, dampingFraction: 0.74)
        self.width.target = width
        self.presence = Spring(present, response: 0.32, dampingFraction: 0.86)
    }

    func step(_ dt: Double, now: CFTimeInterval) {
        guard now >= activateAt else { return }
        x.step(dt); width.step(dt); focus.step(dt)
        presence.step(dt); health.step(dt); pop.step(dt)
    }

    var settled: Bool {
        x.isSettled && width.isSettled && focus.isSettled &&
        presence.isSettled && health.isSettled && pop.isSettled
    }
}

// MARK: - The view

/// High-refresh, custom-drawn menu bar mini-map. Replaces the static `NSImage`
/// rendering with a `CADisplayLink`-driven animation that springs between
/// states and overlays expressive flourishes for each window-manager action.
///
/// Energy: the display link runs ONLY while something is in motion (springs
/// unsettled or flourishes alive) and stops itself once everything settles, so
/// the menu bar costs nothing at rest yet animates at the display's full
/// refresh rate (incl. 120 Hz ProMotion) during actions.
final class MenuBarStripView: NSView {

    // Layout insets within the icon (points).
    private let hInset: CGFloat = 2
    private let vInset: CGFloat = 3

    // MARK: - Adaptive width

    /// Icon points one full screen-width of strip maps to. Higher = each window
    /// is drawn wider, so the icon grows faster as windows are added.
    var pointsPerScreen: CGFloat = 30
    /// Smallest content width the icon ever shrinks to (one tight screen / the
    /// dormant glyph). Keeps a sensible minimum on an empty or single-screen strip.
    var minContentWidth: CGFloat = 30
    /// Largest content width the icon may grow to. Past this the map compresses
    /// the whole strip to fit, so it never overruns the menu bar.
    var maxContentWidth: CGFloat = 220

    /// Draw the active vertical-workspace NUMBER (1-based) in a small left
    /// gutter on the icon, when there is more than one workspace. Config-driven.
    var showWorkspaceNumber: Bool = true
    /// Draw EVERY workspace's strip stacked top-to-bottom (active row
    /// highlighted) instead of only the active one. Only takes effect when there
    /// is more than one workspace. Config-driven.
    var showAllWorkspaces: Bool = false

    /// Width (points) of the left gutter reserved for the workspace-number
    /// badge. Zero unless the badge is actually shown.
    private let workspaceBadgeWidth: CGFloat = 13
    /// Max workspace rows the stacked overview draws before it stops adding more
    /// (so a tall stack stays legible in the ~22pt-tall icon).
    private let maxStackRows = 6
    /// Latest full vertical stack from `apply`, used by the stacked overview.
    /// Inactive workspaces are drawn statically from this snapshot; the active
    /// one animates through the spring-backed `slots` in single-strip mode.
    private var allWorkspaces: [TeleportEngine.StripState.WorkspaceStrip] = []
    /// Bold monospaced-digit font for the workspace-number badge.
    private static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)

    // MARK: - Multi-display overview

    /// One physical display's strip, as the menu-bar overview consumes it. When
    /// the user runs a per-monitor strip on more than one display, the icon draws
    /// EVERY display's strip side-by-side (the focused/active one highlighted)
    /// instead of only the monitor the keyboard is currently on.
    struct DisplayPanelState {
        /// 1-based display number, drawn as a small badge on each panel.
        let index: Int
        /// That display's live strip (its active vertical workspace's columns).
        let state: TeleportEngine.StripState
        /// Whether that display's strip is actively managing windows.
        let managing: Bool
        /// Whether this is the strip global hotkeys act on (focus follows display).
        let isActive: Bool
    }

    /// The displays drawn in the side-by-side overview. Empty in the ordinary
    /// single-display case, where the rich animated single-strip path is used
    /// instead (see `apply`). Populated only by `applyDisplays` with >1 display.
    private var displayPanels: [DisplayPanelState] = []
    /// True while the icon is drawing the multi-display overview rather than the
    /// single animated strip.
    private var multiDisplay: Bool { displayPanels.count > 1 }

    /// Smallest map width (points) one display's strip ever shrinks to in the
    /// overview, so an empty/one-window display still reads as a panel.
    private let multiPanelMinWidth: CGFloat = 22
    /// Largest map width a single display's strip grows to in the overview,
    /// before its own strip compresses to fit (keeps any one busy monitor from
    /// eating the whole icon).
    private let multiPanelMaxWidth: CGFloat = 130
    /// Left-gutter width per panel for the display-number badge.
    private let multiBadgeGutter: CGFloat = 11
    /// Width reserved for the hairline divider drawn between adjacent panels.
    private let multiDivider: CGFloat = 8
    /// How much WIDER than `maxContentWidth` the icon may grow to host the
    /// side-by-side multi-display overview. The host adds this to its length
    /// ceiling so several displays fit without being clipped.
    static let maxMultiDisplayExtraWidth: CGFloat = 260

    /// Called when the icon's desired CONTENT width changes (points, excluding
    /// the host's horizontal padding). The host resizes its status item to fit.
    var onDesiredContentWidthChange: ((CGFloat) -> Void)?
    /// Last width reported through `onDesiredContentWidthChange`, to suppress
    /// no-op churn (and the implied status-item teardown/relayout).
    private var lastReportedContentWidth: CGFloat = -1

    /// Content width the icon wants for the most recently applied state, given
    /// the current density and clamps. Pure function of the state's geometry.
    private func desiredContentWidth(for state: TeleportEngine.StripState, managing: Bool) -> CGFloat {
        guard managing, !state.slots.isEmpty || (stackingActive(state) && state.workspaces.contains { !$0.slots.isEmpty }) else { return minContentWidth }
        // Width of the strip map itself (excludes the left workspace-number
        // gutter, which is added back below). In the stacked overview every
        // workspace shares one horizontal scale, so the map must be wide enough
        // for the WIDEST workspace; otherwise just the active strip.
        let (span, screenWidth): (CGFloat, CGFloat)
        if stackingActive(state) {
            (span, screenWidth) = globalCanvasSpan(state)
        } else {
            var minX = state.viewportX
            var maxX = state.viewportX + state.viewportWidth
            for s in state.slots {
                minX = min(minX, s.canvasX)
                maxX = max(maxX, s.canvasX + s.width)
            }
            (span, screenWidth) = (maxX - minX, state.viewportWidth)
        }
        let mapW = MenuBarMetrics.contentWidth(
            span: span,
            screenWidth: screenWidth,
            pointsPerScreen: pointsPerScreen,
            minWidth: minContentWidth,
            maxWidth: maxContentWidth
        )
        return mapW + badgeGutterWidth(for: state)
    }

    /// True if the stacked all-workspaces overview should be drawn for `state`:
    /// the feature is enabled AND there is more than one workspace. Single-
    /// workspace users always get the plain single-strip presentation.
    private func stackingActive(_ state: TeleportEngine.StripState) -> Bool {
        showAllWorkspaces && state.workspaceCount > 1 && !state.workspaces.isEmpty
    }

    /// Left-gutter width reserved for the workspace-number badge, or 0 when it
    /// is not shown (feature off or only one workspace).
    private func badgeGutterWidth(for state: TeleportEngine.StripState) -> CGFloat {
        (showWorkspaceNumber && state.workspaceCount > 1) ? workspaceBadgeWidth : 0
    }

    /// Canvas span shared across all workspaces in the stacked overview: the
    /// widest workspace's extent, so every row draws at one common horizontal
    /// scale (a narrower workspace reads as a shorter strip). Returns the span
    /// and the screen-width used as the density unit.
    private func globalCanvasSpan(_ state: TeleportEngine.StripState) -> (span: CGFloat, screenWidth: CGFloat) {
        var span: CGFloat = 1
        var screenWidth = max(state.viewportWidth, 1)
        for ws in state.workspaces {
            var minX = ws.viewportX
            var maxX = ws.viewportX + ws.viewportWidth
            for s in ws.slots {
                minX = min(minX, s.canvasX)
                maxX = max(maxX, s.canvasX + s.width)
            }
            span = max(span, maxX - minX)
            screenWidth = max(screenWidth, ws.viewportWidth)
        }
        return (span, screenWidth)
    }

    private var slots: [VisualSlot] = []
    private var viewportX = Spring(0, response: 0.42, dampingFraction: 0.85)
    private var viewportW = Spring(1, response: 0.42, dampingFraction: 0.85)
    /// 0 = dormant glyph, 1 = live strip. Cross-fades the two presentations.
    private var modeFade = Spring(0, response: 0.34, dampingFraction: 0.9)
    /// Horizontal page slide for workspace switches (icon-widths, springs to 0).
    private var pageSlide = Spring(0, response: 0.5, dampingFraction: 0.8)
    /// Vertical page slide for VERTICAL workspace switches (icon-heights ->0).
    private var pageSlideY = Spring(0, response: 0.5, dampingFraction: 0.82)
    /// Active workspace index + count, for the little stacked indicator and to
    /// detect a switch between two `apply` calls.
    private var activeWorkspace = 0
    private var workspaceCount = 1
    /// Whether the last `apply` selected the stacked all-workspaces overview.
    private var stackedMode = false
    /// Whether the last `apply` wants the workspace-number badge drawn.
    private var showBadge = false
    /// Glowing selector that travels to the focused column (canvas center x).
    private var focusGlow = Spring(0, response: 0.32, dampingFraction: 0.7)
    private var focusGlowActive = false

    private var displayLink: CADisplayLink?
    private var lastTickNs: UInt64 = 0
    private var dormant = true

    // MARK: - Key-hint HUD

    /// Whether a hint is currently flashing. Set by `flashKeyHint`; the HUD
    /// cross-fades over the mini-map then clears itself.
    private var hintActive = false
    /// The chord just pressed (e.g. "⌘L"), drawn inside a rounded keycap box.
    /// nil when the fired action has no chord (then only the action shows).
    private var hintChord: String?
    /// The action label (e.g. "Focus →"), drawn after the keycap.
    private var hintAction = ""
    /// HUD opacity: 0 hidden, 1 fully shown. Snappy in (no overshoot), held for
    /// `hintHold` seconds, then eased out so the mini-map returns.
    private var hintFade = Spring(0, response: 0.16, dampingFraction: 1.0)
    /// Per-press size pop on the keycap box: kicked on every `flashKeyHint`, so
    /// even repeated presses of the SAME chord visibly "punch" the keycap. The
    /// box scales by `1 + value * hintPopScale` around its center; the reported
    /// HUD width is unaffected so the status item never relayouts mid-pop.
    private var hintPop = Spring(0, response: 0.28, dampingFraction: 0.55)
    /// How much the keycap grows at the peak of a pop (fraction of its size).
    private let hintPopScale: CGFloat = 0.22
    /// Media-clock time the HUD should START fading out (after the hold).
    private var hintHoldUntil: CFTimeInterval = 0
    /// How long the HUD stays fully visible before fading back to the mini-map.
    private let hintHold: CFTimeInterval = 0.85
    /// Base mini-map content width from the last `apply`, used so the HUD can
    /// grow the icon to fit the text and shrink back without re-deriving geometry.
    private var lastStripContentWidth: CGFloat = 30
    /// Bold chord font for the keycap glyphs.
    private static let hintChordFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    /// Medium action-label font, drawn to the right of the keycap.
    private static let hintActionFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// Trailing padding after the HUD text before the icon's right edge (points).
    private let hudTrailingInset: CGFloat = 5
    /// Gap between the mini-map and the keycap box drawn to its right (points).
    private let hintGap: CGFloat = 6
    /// Inner horizontal padding inside the keycap box around the chord (points).
    private let keycapPadX: CGFloat = 5
    /// Gap between the keycap box and the action label (points).
    private let keycapGap: CGFloat = 5
    /// How much WIDER than `maxContentWidth` the icon may grow to fit the
    /// transient key-hint text appended to the right of the mini-map. The strip
    /// itself still self-limits to `maxContentWidth`; this only covers the HUD.
    static let maxHintExtraWidth: CGFloat = 220

    /// Flash a key-hint over the icon: the chord just pressed + the action it
    /// triggered (e.g. "⌘L" / "Focus →"). The chord rides a little rounded
    /// keycap box that POPS (springs bigger then settles) on every press; the
    /// icon grows to fit, holds, then fades back to the mini-map. Rapid presses
    /// retarget the same HUD and re-pop the keycap.
    func flashKeyHint(chord: String, action: String, now: CFTimeInterval = CACurrentMediaTime()) {
        hintActive = true
        hintChord = chord.isEmpty ? nil : chord
        hintAction = action
        hintFade.target = 1
        hintHoldUntil = now + hintHold
        // Re-pop the keycap on every press, even a repeat of the same chord.
        hintPop.value = 0
        hintPop.velocity = 0
        hintPop.target = 0
        hintPop.kick(9)
        // Recompute the icon's desired width right away so it starts growing
        // toward the text, then report it on every animated frame.
        reportDesiredWidthIfChanged()
        ensureAnimating()
        needsDisplay = true
    }

    /// The HUD text currently displayed (for headless tests + introspection).
    /// Mirrors the old combined "⌘L  Focus →" form so callers stay stable.
    var debugHintText: String? {
        guard hintActive else { return nil }
        guard let hintChord else { return hintAction }
        return "\(hintChord)  \(hintAction)"
    }

    /// Whether the last `apply` chose the stacked all-workspaces overview
    /// (headless-test introspection).
    var debugStackedMode: Bool { stackedMode }
    /// Whether the last `apply` wants the workspace-number badge drawn.
    var debugShowsBadge: Bool { showBadge }
    /// The 1-based workspace number the badge would render.
    var debugBadgeLabel: String { "\(min(activeWorkspace, max(workspaceCount - 1, 0)) + 1)" }
    /// Number of workspace rows the stacked overview holds (for tests).
    var debugWorkspaceRowCount: Int { allWorkspaces.count }
    /// The icon's desired CONTENT width for `state` (pure; headless tests).
    func debugDesiredContentWidth(for state: TeleportEngine.StripState, managing: Bool) -> CGFloat {
        desiredContentWidth(for: state, managing: managing)
    }

    // Diff bookkeeping.
    private var lastState: TeleportEngine.StripState?
    private var lastManaging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { true }

    /// Clicks must reach the NSStatusBarButton behind us so the menu opens.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { ensureAnimating() }
        else { stopAnimating() }
    }

    // MARK: - Public entry: apply a new strip state

    /// Diff `state` against the last applied state, infer the actions that
    /// occurred, retarget the springs, and spawn flourishes. Safe to call as
    /// often as the engine fires `onLayoutChange`.
    ///
    /// `now` is injectable so the offscreen render harness can drive a virtual
    /// clock; in production it defaults to the real media clock.
    func apply(state: TeleportEngine.StripState, managing: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        let actions = MenuBarDiff.infer(
            old: lastState, oldManaging: lastManaging,
            new: state, newManaging: managing
        )
        let firstApply = lastState == nil
        dormant = !managing || state.slots.isEmpty
        modeFade.target = dormant ? 0 : 1

        // Detect a vertical workspace switch and play the page slide. Direction
        // mirrors the strip: switching DOWN (active index grows) slides the new
        // workspace UP from below. Skip on first apply / mode changes.
        if !firstApply && managing && lastManaging
            && state.activeWorkspace != activeWorkspace {
            animateWorkspaceSwitchVertical(
                direction: state.activeWorkspace > activeWorkspace ? 1 : -1)
        }
        activeWorkspace = state.activeWorkspace
        workspaceCount = state.workspaceCount
        allWorkspaces = state.workspaces
        stackedMode = stackingActive(state) && managing
        showBadge = badgeGutterWidth(for: state) > 0 && managing

        // 1. Reconcile slot set against the new state (by stable id).
        reconcile(state: state, firstApply: firstApply, now: now)

        // 2. Viewport + focus targets.
        viewportX.target = Double(state.viewportX)
        viewportW.target = Double(state.viewportWidth)
        if state.slots.indices.contains(state.focusIndex) {
            let f = state.slots[state.focusIndex]
            focusGlow.target = Double(f.canvasX + f.width / 2)
            if !focusGlowActive { focusGlow.reset(to: focusGlow.target); focusGlowActive = true }
        }

        // 3. Per-action flourishes + accents.
        for action in actions { perform(action, state: state, now: now, firstApply: firstApply) }

        lastState = state
        lastManaging = managing

        // Report the icon's desired content width so the host can grow/shrink
        // the status item. Quantized + thresholded to avoid churn on tiny deltas.
        lastStripContentWidth = desiredContentWidth(for: state, managing: managing)
        reportDesiredWidthIfChanged()

        ensureAnimating()
        needsDisplay = true
    }

    /// Measured size of the chord glyphs in the keycap font (zero if no chord).
    private func chordTextSize() -> CGSize {
        guard let hintChord else { return .zero }
        return (hintChord as NSString).size(withAttributes: [.font: Self.hintChordFont])
    }

    /// Measured size of the action label in its font (zero if empty).
    private func actionTextSize() -> CGSize {
        guard !hintAction.isEmpty else { return .zero }
        return (hintAction as NSString).size(withAttributes: [.font: Self.hintActionFont])
    }

    /// Width of the rounded keycap box that wraps the chord glyphs (padding on
    /// both sides). Zero when the fired action carries no chord. This is the
    /// box's RESTING width; the per-press pop only scales it visually, so the
    /// reported HUD width — and thus the status item — never jitters mid-pop.
    private func keycapWidth() -> CGFloat {
        let cw = chordTextSize().width
        guard cw > 0 else { return 0 }
        return ceil(cw) + keycapPadX * 2
    }

    /// Extra width (points) the HUD needs to the RIGHT of the mini-map: the gap,
    /// the keycap box, the gap to the action label, the label, and a trailing
    /// inset. Zero when no HUD is up. The mini-map keeps its own width; this is
    /// appended, never substituted.
    private func hintTrailingWidth() -> CGFloat {
        guard hintActive else { return 0 }
        let cap = keycapWidth()
        let act = ceil(actionTextSize().width)
        var w = hintGap
        w += cap
        if cap > 0 && act > 0 { w += keycapGap }
        w += act + hudTrailingInset
        return min(w, Self.maxHintExtraWidth)
    }

    /// Report the icon's desired CONTENT width to the host (status-item length).
    /// The HUD, when active, APPENDS its text to the right of the mini-map (the
    /// strip keeps its full width); otherwise the strip's own desired width
    /// drives it. Thresholded so we only resize the status item on a real change
    /// (relayout is not free).
    private func reportDesiredWidthIfChanged() {
        var desired = lastStripContentWidth
        if hintActive { desired += hintTrailingWidth() }
        if abs(desired - lastReportedContentWidth) >= 1 {
            lastReportedContentWidth = desired
            onDesiredContentWidthChange?(desired)
        }
    }

    /// Slide the whole strip like turning a page. Call when switching
    /// workspaces (`direction`: -1 = a workspace to the left becomes active,
    /// +1 = to the right). Wired for when workspaces land; safe to call now.
    func animateWorkspaceSwitch(direction: Int) {
        let w = Double(max(bounds.width, 24))
        pageSlide.value = Double(direction) * w
        pageSlide.target = 0
        ensureAnimating()
    }

    /// Slide the strip VERTICALLY like flipping through stacked workspaces.
    /// `direction`: +1 = switched to a workspace BELOW (new content rises up
    /// from the bottom), -1 = a workspace ABOVE (drops in from the top).
    func animateWorkspaceSwitchVertical(direction: Int) {
        let h = Double(max(bounds.height, 12))
        // New content starts offset opposite the travel direction and springs
        // home: going down means it enters from below (negative y in flipped-up
        // AppKit coords), so seed +/- accordingly.
        pageSlideY.value = Double(-direction) * h
        pageSlideY.target = 0
        ensureAnimating()
    }

    // MARK: - Reconcile / actions

    private func reconcile(state: TeleportEngine.StripState, firstApply: Bool, now: CFTimeInterval) {
        var byID: [UInt64: VisualSlot] = [:]
        for s in slots { byID[s.id] = s }
        let liveIDs = Set(state.slots.map { $0.id })

        var rebuilt: [VisualSlot] = []
        for s in state.slots {
            let tint = AppColors.color(appName: s.appName, title: s.title)
            if let existing = byID[s.id] {
                existing.exiting = false
                existing.appColor = tint
                existing.x.target = Double(s.canvasX)
                existing.width.target = Double(s.width)
                existing.presence.target = 1
                existing.health.target = s.healthy ? 1 : 0
                rebuilt.append(existing)
            } else {
                let v = VisualSlot(
                    id: s.id, canvasX: Double(s.canvasX), width: Double(s.width),
                    present: firstApply ? 1 : 0, enter: !firstApply
                )
                v.appColor = tint
                v.health.reset(to: s.healthy ? 1 : 0)
                rebuilt.append(v)
            }
        }
        // Keep exiting (closed) columns around so they can collapse + fade.
        for s in slots where !liveIDs.contains(s.id) {
            s.exiting = true
            s.presence.target = 0
            s.width.target = 0
            rebuilt.append(s)
        }
        // Preserve canvas order with exiting columns dropped to the back so
        // they don't reflow surviving neighbors.
        slots = rebuilt
    }

    private func perform(_ action: MenuBarAction, state: TeleportEngine.StripState,
                         now: CFTimeInterval, firstApply: Bool) {
        switch action {
        case .arrange:
            // Stagger the columns in left-to-right for a "deal the cards" sweep.
            for (i, v) in slots.enumerated() where !v.exiting {
                v.activateAt = now + Double(i) * 0.035
                v.presence.value = 0
            }

        case .release:
            for v in slots { v.presence.target = 0; v.width.target = max(2, v.width.value * 0.2) }

        case .focusChanged(let toID, _):
            for v in slots { v.focus.target = (v.id == toID) ? 1 : 0 }
            // Gentle scale pop on the newly focused column.
            slots.first(where: { $0.id == toID })?.pop.kick(7.5)

        case .added(let ids):
            // Pop the new column in; no overlay particles.
            for id in ids { slots.first(where: { $0.id == id })?.pop.kick(6) }

        case .removed:
            // Columns collapse + fade via their springs; no overlay particles.
            break

        case .resized(let ids):
            for id in ids { slots.first(where: { $0.id == id })?.pop.kick(4) }

        case .reordered:
            // The x springs already animate to swapped positions; lift the
            // focused/moved column slightly so the swap reads as a glide.
            if state.slots.indices.contains(state.focusIndex) {
                let fid = state.slots[state.focusIndex].id
                slots.first(where: { $0.id == fid })?.pop.kick(5)
            }
        }
    }

    // MARK: - Display link

    private func ensureAnimating() {
        guard window != nil, displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        let maxFPS = Float(NSScreen.main?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maxFPS, preferred: maxFPS)
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTickNs = 0
    }

    private func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let nowNs = Clock.nowAbsNs()
        let dt = lastTickNs == 0 ? 1.0 / 120.0 : Double(nowNs &- lastTickNs) / 1e9
        lastTickNs = nowNs
        advance(dt: dt, now: CACurrentMediaTime())
        if everythingSettled() { stopAnimating() }
    }

    /// Integrate one animation step and request a redraw. Separated from `tick`
    /// so the offscreen render harness (`animrender`) can drive frames with a
    /// fixed dt and deterministic clock for visual verification + screenshots.
    func advance(dt: Double, now: CFTimeInterval) {
        modeFade.step(dt)
        viewportX.step(dt); viewportW.step(dt)
        pageSlide.step(dt); pageSlideY.step(dt); focusGlow.step(dt)
        for s in slots { s.step(dt, now: now) }

        // Key-hint HUD: once the hold window elapses, ease it out. When fully
        // faded we clear the hint and let the icon shrink back to the mini-map.
        if hintActive {
            hintPop.step(dt)
            if hintFade.target > 0, now >= hintHoldUntil { hintFade.target = 0 }
            hintFade.step(dt)
            if hintFade.target == 0 && hintFade.value < 0.02 {
                hintActive = false
                hintChord = nil
                hintAction = ""
                hintFade.reset(to: 0)
                hintPop.reset(to: 0)
            }
            reportDesiredWidthIfChanged()
        }

        // Reap fully-exited columns.
        slots.removeAll { $0.exiting && $0.presence.value < 0.02 && $0.presence.isSettled }

        needsDisplay = true
    }

    private func everythingSettled() -> Bool {
        modeFade.isSettled && viewportX.isSettled && viewportW.isSettled &&
        pageSlide.isSettled && pageSlideY.isSettled && focusGlow.isSettled &&
        !hintActive && slots.allSatisfy { $0.settled }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.cgContext.clear(bounds)
        ctx.shouldAntialias = true

        let live = 1 - modeFade.value      // dormant weight
        let managingWeight = modeFade.value

        // The key-hint is drawn to the RIGHT of the mini-map, never on top of
        // it: the windows graphic keeps its own region on the left at full
        // brightness, and the icon simply grows to make room for the HUD text.
        let hud = hintActive ? CGFloat(hintFade.value) : 0
        let trailing = hintTrailingWidth()  // 0 when no HUD is set
        // The mini-map keeps the same pixel width it has with no HUD: the icon
        // grew by exactly `trailing` to host the text, so the leftover is the
        // map's region. Clamp so a one-frame resize lag can't squish the map.
        let mapW = trailing > 0 ? max(bounds.width - trailing, 0) : bounds.width
        let mapRect = NSRect(x: bounds.minX, y: bounds.minY, width: mapW, height: bounds.height)

        // Carve a left gutter for the workspace-number badge (drawn last, on
        // top of nothing else, so it never overlaps a column). The strip/dormant
        // graphic uses the remaining region to its right.
        let gutter: CGFloat = (showBadge && managingWeight > 0.01) ? workspaceBadgeWidth : 0
        let contentRect = NSRect(x: mapRect.minX + gutter, y: mapRect.minY,
                                 width: max(mapRect.width - gutter, 0), height: mapRect.height)

        if live > 0.01 { drawDormant(in: contentRect, alpha: live) }
        if managingWeight > 0.01 {
            if stackedMode {
                drawStackedStrips(in: contentRect, alpha: managingWeight)
            } else {
                drawStrip(in: contentRect, alpha: managingWeight)
            }
        }
        if gutter > 0 {
            let badgeRect = NSRect(x: mapRect.minX, y: mapRect.minY,
                                   width: gutter, height: mapRect.height)
            drawWorkspaceBadge(in: badgeRect, alpha: managingWeight)
        }
        if hud > 0.01, hintActive {
            let hintRect = NSRect(x: mapRect.maxX, y: bounds.minY,
                                  width: max(bounds.maxX - mapRect.maxX, 0),
                                  height: bounds.height)
            drawKeyHint(in: hintRect, alpha: hud)
        }
    }

    /// Draw the key-hint HUD: the chord inside a rounded keycap box that pops on
    /// each press, then the action label to its right. `rect` is the region
    /// appended to the RIGHT of the mini-map; the map is never covered or dimmed.
    private func drawKeyHint(in rect: NSRect, alpha: CGFloat) {
        var cursorX = rect.minX + hintGap

        // 1. Keycap box (chord). Scales with the per-press pop around its center.
        if let hintChord {
            let cap = keycapWidth()
            let capH = min(rect.height - 4, 18)
            let capRect = NSRect(
                x: cursorX, y: rect.minY + (rect.height - capH) / 2,
                width: cap, height: capH)

            // Pop: scale the box (and its glyphs) about its own center. Width
            // stays reserved at rest so the status item never relayouts.
            let pop = CGFloat(max(0, hintPop.value))
            let scale = 1 + pop * hintPopScale
            NSGraphicsContext.saveGraphicsState()
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.translateBy(x: capRect.midX, y: capRect.midY)
            ctx?.scaleBy(x: scale, y: scale)
            ctx?.translateBy(x: -capRect.midX, y: -capRect.midY)

            // Rounded keycap: subtle filled body + hairline border, brighter at
            // the pop peak so the press reads as a flash of light.
            let glow = min(1, pop * 0.5)
            let radius: CGFloat = 4
            let box = NSBezierPath(roundedRect: capRect, xRadius: radius, yRadius: radius)
            NSColor.labelColor.withAlphaComponent((0.10 + 0.12 * glow) * alpha).setFill()
            box.fill()
            box.lineWidth = 1
            NSColor.labelColor.withAlphaComponent((0.45 + 0.4 * glow) * alpha).setStroke()
            box.stroke()

            // Chord glyphs centered in the keycap.
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byClipping
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.hintChordFont,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha),
                .paragraphStyle: para,
            ]
            let cSize = chordTextSize()
            let cRect = NSRect(
                x: capRect.minX, y: capRect.minY + (capRect.height - cSize.height) / 2,
                width: capRect.width, height: cSize.height)
            (hintChord as NSString).draw(in: cRect, withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()

            cursorX = capRect.maxX + keycapGap
        }

        // 2. Action label, vertically centered after the keycap.
        if !hintAction.isEmpty {
            let para = NSMutableParagraphStyle()
            para.alignment = .left
            para.lineBreakMode = .byClipping
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.hintActionFont,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha),
                .paragraphStyle: para,
            ]
            let aSize = actionTextSize()
            let aRect = NSRect(
                x: cursorX, y: rect.minY + (rect.height - aSize.height) / 2,
                width: max(rect.maxX - cursorX, 0), height: aSize.height)
            (hintAction as NSString).draw(in: aRect, withAttributes: attrs)
        }
    }

    private func drawDormant(in rect: NSRect, alpha: Double) {
        let stroke = NSColor.secondaryLabelColor.withAlphaComponent(0.9 * alpha)
        stroke.setStroke()
        let colW: CGFloat = 7, gap: CGFloat = 2
        let totalW = colW * 2 + gap
        let startX = rect.minX + (rect.width - totalW) / 2
        for i in 0..<2 {
            let r = NSRect(x: startX + CGFloat(i) * (colW + gap), y: vInset + 2,
                           width: colW, height: rect.height - (vInset + 2) * 2)
            let p = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            p.setLineDash([2, 1.5], count: 2, phase: 0)
            p.lineWidth = 1
            p.stroke()
        }
    }

    private func drawStrip(in contentRect: NSRect, alpha: Double) {
        guard !slots.isEmpty else { return }
        let rect = contentRect.insetBy(dx: hInset, dy: 0)

        // Canvas range from the animated geometry (union of columns + viewport).
        var minX = viewportX.value
        var maxX = viewportX.value + viewportW.value
        for s in slots {
            minX = min(minX, s.x.value)
            maxX = max(maxX, s.x.value + s.width.value)
        }
        let span = max(maxX - minX, 1)
        let scale = rect.width / CGFloat(span)
        let slidePx = CGFloat(pageSlide.value)
        func mapX(_ x: Double) -> CGFloat { rect.minX + CGFloat(x - minX) * scale + slidePx }

        // Vertical workspace-switch slide: nudge the whole strip band up/down.
        let slideY = CGFloat(pageSlideY.value)
        let top = rect.minY + vInset + slideY
        let bottomH = rect.height - vInset * 2

        // (Focus glow halo removed: the focused column is highlighted directly
        // in the column pass below, so no traveling accent halo is drawn.)

        // 2. Columns.
        for s in slots {
            let present = s.presence.value
            guard present > 0.01 else { continue }
            let x = mapX(s.x.value)
            let w = max(CGFloat(s.width.value) * scale - 1, 1.5)
            // Enter/exit grow vertically from the center line; pop scales it.
            let popScale = 1 + max(0, s.pop.value) * 0.05
            let h = bottomH * CGFloat(present) * popScale
            let y = top + (bottomH - h) / 2
            let r = NSRect(x: x, y: y, width: w, height: h)
            let path = NSBezierPath(roundedRect: r, xRadius: 1.6, yRadius: 1.6)

            let focus = s.focus.value
            let health = s.health.value

            // Neutral pill body. The top stays uncolored; focus brightens it.
            let bodyWhite = 0.42 + 0.40 * focus
            let body = NSColor(white: CGFloat(bodyWhite), alpha: 1)
            body.withAlphaComponent(CGFloat(present) * alpha).setFill()
            path.fill()

            // App color tints only the BOTTOM HALF, as a gradient fading up to
            // the middle. Unhealthy windows shift toward red; unfocused dim.
            var tint = blend(s.appColor, NSColor.systemRed, CGFloat(1 - health) * 0.8)
            if focus < 0.5 { tint = blend(tint, NSColor(white: 0.30, alpha: 1), CGFloat(0.45 * (1 - focus))) }
            let tintTopAlpha = CGFloat((0.78 + 0.22 * focus) * present) * alpha

            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let half = NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.5)
            let gradient = NSGradient(colors: [tint.withAlphaComponent(tintTopAlpha),
                                               tint.withAlphaComponent(0)])
            gradient?.draw(in: half, angle: 90) // bottom -> up, fading at mid
            NSGraphicsContext.restoreGraphicsState()
        }

        // 3. Viewport frame: a thin outline that hugs the in-viewport columns.
        let vInsetY: CGFloat = vInset + 1   // tuck inside the column band
        let vx = mapX(viewportX.value) + 0.5
        let vw = max(CGFloat(viewportW.value) * scale - 1, 3)
        let vRect = NSRect(x: vx, y: rect.minY + vInsetY,
                           width: min(vw, rect.maxX - vx - 0.5),
                           height: rect.height - vInsetY * 2)
        let vPath = NSBezierPath(roundedRect: vRect, xRadius: 2, yRadius: 2)
        vPath.lineWidth = 0.75
        NSColor.labelColor.withAlphaComponent(0.95 * alpha).setStroke()
        vPath.stroke()

        // 4. Vertical-workspace indicator: a tiny stack of dots at the top-left,
        // one per workspace, the active one filled. Only when >1 workspace, and
        // suppressed when the numeric badge is shown (they'd be redundant).
        if !showBadge { drawWorkspaceIndicator(in: rect, alpha: alpha) }
    }

    /// Draw the numeric workspace badge (1-based active index) in the reserved
    /// left gutter. Only called when `showBadge` and there is >1 workspace.
    private func drawWorkspaceBadge(in rect: NSRect, alpha: Double) {
        guard alpha > 0.01 else { return }
        let label = "\(min(activeWorkspace, workspaceCount - 1) + 1)"
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byClipping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.badgeFont,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.95 * alpha),
            .paragraphStyle: para,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        let tRect = NSRect(x: rect.minX, y: rect.minY + (rect.height - size.height) / 2,
                           width: rect.width, height: size.height)
        (label as NSString).draw(in: tRect, withAttributes: attrs)
        // A faint hairline separating the badge gutter from the strip.
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: rect.maxX - 0.5, y: rect.minY + 3))
        sep.line(to: NSPoint(x: rect.maxX - 0.5, y: rect.maxY - 3))
        sep.lineWidth = 0.75
        NSColor.labelColor.withAlphaComponent(0.18 * alpha).setStroke()
        sep.stroke()
    }

    /// Draw EVERY workspace's strip stacked top-to-bottom: index 0 (the topmost
    /// workspace) at the top of the icon, the active one highlighted. Each row
    /// shares ONE horizontal scale (`globalCanvasSpan`) so a narrower workspace
    /// reads as a shorter strip. Rows past `maxStackRows` are dropped with a
    /// small "+N" overflow marker. Static (no per-column springs): the stack is
    /// an at-a-glance overview, redrawn whole on each `apply`.
    private func drawStackedStrips(in contentRect: NSRect, alpha: Double) {
        guard !allWorkspaces.isEmpty else { return }
        let rect = contentRect.insetBy(dx: hInset, dy: vInset)
        guard rect.height > 4, rect.width > 4 else { return }

        let total = allWorkspaces.count
        let shown = min(total, maxStackRows)
        let rowGap: CGFloat = 2
        let rowH = (rect.height - rowGap * CGFloat(shown - 1)) / CGFloat(shown)
        guard rowH > 1 else { return }

        // Shared horizontal mapping across all rows.
        let (span, _) = globalCanvasSpan(lastStateForStack)
        let scale = rect.width / CGFloat(max(span, 1))

        for row in 0..<shown {
            let ws = allWorkspaces[row]
            // Top-to-bottom: row 0 at the top (AppKit y grows up).
            let top = rect.maxY - CGFloat(row) * (rowH + rowGap)
            let rowRect = NSRect(x: rect.minX, y: top - rowH, width: rect.width, height: rowH)
            drawWorkspaceRow(ws, in: rowRect, scale: scale, alpha: alpha)
        }

        // Overflow marker if more workspaces exist than rows shown.
        if total > shown {
            let label = "+\(total - shown)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.9 * alpha),
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(
                at: NSPoint(x: rect.maxX - size.width, y: rect.minY - 1), withAttributes: attrs)
        }
    }

    /// The state used by the stacked overview's shared scale. Captured on each
    /// `apply` so `drawStackedStrips` can recompute the global span without the
    /// full `StripState` on hand.
    private var lastStateForStack: TeleportEngine.StripState {
        // Reconstruct a minimal state from the cached stack so globalCanvasSpan
        // (which only reads `workspaces`/`viewportWidth`) works unchanged.
        TeleportEngine.StripState(
            slots: [], viewportX: 0,
            viewportWidth: allWorkspaces.first?.viewportWidth ?? 1,
            focusIndex: 0, lastTeleportMs: 0,
            activeWorkspace: activeWorkspace, workspaceCount: workspaceCount,
            workspaces: allWorkspaces)
    }

    /// Draw one workspace's columns into a single row of the stacked overview.
    /// The active workspace's row is full brightness with a viewport outline;
    /// inactive rows are dimmed. Columns are tinted by app color like the live
    /// strip but without per-column animation.
    private func drawWorkspaceRow(_ ws: TeleportEngine.StripState.WorkspaceStrip,
                                  in rowRect: NSRect, scale: CGFloat, alpha: Double) {
        let activeRow = ws.isActive
        let rowAlpha = (activeRow ? 1.0 : 0.5) * alpha

        // Active row gets a subtle backing so the eye finds "where I am" fast.
        if activeRow {
            let bg = NSBezierPath(roundedRect: rowRect.insetBy(dx: -1, dy: 0), xRadius: 2, yRadius: 2)
            NSColor.labelColor.withAlphaComponent(0.06 * alpha).setFill()
            bg.fill()
        }

        // Canvas origin = the row's own min across its columns + viewport, so
        // every row left-aligns at the same x=0 reference (the global scale
        // already sizes the widest one to fill the width).
        var minX = ws.viewportX
        for s in ws.slots { minX = min(minX, s.canvasX) }
        func mapX(_ x: CGFloat) -> CGFloat { rowRect.minX + (x - minX) * scale }

        // Empty workspace: a faint placeholder dash so the row still reads.
        if ws.slots.isEmpty {
            let dashH = max(rowRect.height * 0.4, 1.5)
            let r = NSRect(x: rowRect.minX, y: rowRect.midY - dashH / 2,
                           width: min(rowRect.width, 8), height: dashH)
            let p = NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1)
            p.setLineDash([2, 1.5], count: 2, phase: 0)
            p.lineWidth = 0.75
            NSColor.secondaryLabelColor.withAlphaComponent(0.5 * rowAlpha).setStroke()
            p.stroke()
            return
        }

        for (i, s) in ws.slots.enumerated() {
            let x = mapX(s.canvasX)
            let w = max(s.width * scale - 1, 1.5)
            let r = NSRect(x: x, y: rowRect.minY, width: w, height: rowRect.height)
            let path = NSBezierPath(roundedRect: r, xRadius: 1.4, yRadius: 1.4)
            let focused = i == ws.focusIndex
            let tint = AppColors.color(appName: s.appName, title: s.title)

            // Neutral body, brighter for the focused column in its workspace.
            let bodyWhite = (focused ? 0.7 : 0.42)
            NSColor(white: CGFloat(bodyWhite), alpha: 1)
                .withAlphaComponent(rowAlpha).setFill()
            path.fill()

            // App tint on the bottom half, like the live strip.
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let half = NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.55)
            let gradient = NSGradient(colors: [tint.withAlphaComponent(CGFloat(0.8) * rowAlpha),
                                               tint.withAlphaComponent(0)])
            gradient?.draw(in: half, angle: 90)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Viewport outline on the ACTIVE row only (where it is meaningful).
        if activeRow {
            let vx = mapX(ws.viewportX) + 0.5
            let vw = max(ws.viewportWidth * scale - 1, 3)
            let vRect = NSRect(x: vx, y: rowRect.minY + 0.5,
                               width: min(vw, rowRect.maxX - vx - 0.5),
                               height: rowRect.height - 1)
            let vPath = NSBezierPath(roundedRect: vRect, xRadius: 1.6, yRadius: 1.6)
            vPath.lineWidth = 0.75
            NSColor.labelColor.withAlphaComponent(0.9 * alpha).setStroke()
            vPath.stroke()
        }
    }

    /// Stacked dots showing which vertical workspace is active (niri-style).
    /// Drawn only when there is more than one workspace so single-workspace
    /// users see no extra chrome.
    private func drawWorkspaceIndicator(in rect: NSRect, alpha: Double) {
        guard workspaceCount > 1 else { return }
        let dot: CGFloat = 1.6
        let spacing: CGFloat = 1.3
        let n = min(workspaceCount, 6)            // cap so a tall stack still fits
        let totalH = CGFloat(n) * dot + CGFloat(n - 1) * spacing
        var y = rect.midY + totalH / 2 - dot      // top-down (AppKit y grows up)
        let x = rect.minX + 0.5
        for i in 0..<n {
            let on = i == min(activeWorkspace, n - 1)
            let r = NSRect(x: x, y: y, width: dot, height: dot)
            let p = NSBezierPath(ovalIn: r)
            NSColor.labelColor.withAlphaComponent((on ? 0.95 : 0.35) * alpha).setFill()
            p.fill()
            y -= dot + spacing
        }
    }

    // MARK: - Helpers

    private func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let t = max(0, min(1, t))
        guard let ca = a.usingColorSpace(.deviceRGB), let cb = b.usingColorSpace(.deviceRGB) else { return a }
        return NSColor(
            deviceRed: ca.redComponent + (cb.redComponent - ca.redComponent) * t,
            green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
            blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t,
            alpha: ca.alphaComponent + (cb.alphaComponent - ca.alphaComponent) * t
        )
    }

    deinit { displayLink?.invalidate() }
}
