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

// MARK: - Transient visual flourishes

/// Short-lived particle/effect overlaid on the mini-map. Each carries the
/// canvas coordinates it is anchored to (so it tracks the live mapping) and a
/// birth time; the view fades it out over `duration`.
private struct Flourish {
    enum Kind {
        case sparkle      // window opened: expanding burst at insertion point
        case poof         // window closed: dissolving ring
        case sweep        // arrange: bright vertical line crossing the map
        case focusPulse   // window switch: ring blooming on the new focus
    }
    let kind: Kind
    let canvasX: Double
    let birth: CFTimeInterval
    let duration: CFTimeInterval
    var hue: NSColor

    func progress(_ now: CFTimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, (now - birth) / duration))
    }
    func alive(_ now: CFTimeInterval) -> Bool { now - birth < duration }
}

// MARK: - Visual slot

/// One animated column. Geometry lives in canvas points (matching the engine's
/// strip model) and is mapped to icon pixels at draw time, so scrolling the
/// viewport and reflowing columns both read as continuous motion.
private final class VisualSlot {
    let id: UInt64
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

    private var slots: [VisualSlot] = []
    private var viewportX = Spring(0, response: 0.42, dampingFraction: 0.85)
    private var viewportW = Spring(1, response: 0.42, dampingFraction: 0.85)
    /// 0 = dormant glyph, 1 = live strip. Cross-fades the two presentations.
    private var modeFade = Spring(0, response: 0.34, dampingFraction: 0.9)
    /// Horizontal page slide for workspace switches (icon-widths, springs to 0).
    private var pageSlide = Spring(0, response: 0.5, dampingFraction: 0.8)
    /// Glowing selector that travels to the focused column (canvas center x).
    private var focusGlow = Spring(0, response: 0.32, dampingFraction: 0.7)
    private var focusGlowActive = false

    private var flourishes: [Flourish] = []

    private var displayLink: CADisplayLink?
    private var lastTickNs: UInt64 = 0
    private var dormant = true

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
        ensureAnimating()
        needsDisplay = true
    }

    /// Slide the whole strip like turning a page. Call when switching
    /// workspaces (`direction`: -1 = a workspace to the left becomes active,
    /// +1 = to the right). Wired for when workspaces land; safe to call now.
    func animateWorkspaceSwitch(direction: Int) {
        let w = Double(max(bounds.width, 24))
        pageSlide.value = Double(direction) * w
        pageSlide.target = 0
        // A bright sweep in the travel direction sells the transition.
        flourishes.append(Flourish(
            kind: .sweep, canvasX: 0, birth: CACurrentMediaTime(),
            duration: 0.42, hue: NSColor.controlAccentColor
        ))
        ensureAnimating()
    }

    // MARK: - Reconcile / actions

    private func reconcile(state: TeleportEngine.StripState, firstApply: Bool, now: CFTimeInterval) {
        var byID: [UInt64: VisualSlot] = [:]
        for s in slots { byID[s.id] = s }
        let liveIDs = Set(state.slots.map { $0.id })

        var rebuilt: [VisualSlot] = []
        for s in state.slots {
            if let existing = byID[s.id] {
                existing.exiting = false
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
            flourishes.append(Flourish(kind: .sweep, canvasX: 0, birth: now,
                                       duration: 0.45, hue: .controlAccentColor))

        case .release:
            for v in slots { v.presence.target = 0; v.width.target = max(2, v.width.value * 0.2) }

        case .focusChanged(let toID, _):
            for v in slots { v.focus.target = (v.id == toID) ? 1 : 0 }
            if let v = slots.first(where: { $0.id == toID }) {
                v.pop.kick(7.5) // gentle scale pop on the newly focused column
                // (Blue focus-pulse ring removed.)
            }

        case .added(let ids):
            for id in ids {
                if let v = slots.first(where: { $0.id == id }) {
                    v.pop.kick(6)
                    flourishes.append(Flourish(kind: .sparkle, canvasX: v.x.target + v.width.target / 2,
                                               birth: now, duration: 0.5, hue: .controlAccentColor))
                }
            }

        case .removed(let ids):
            for id in ids {
                if let v = slots.first(where: { $0.id == id }) {
                    flourishes.append(Flourish(kind: .poof, canvasX: v.x.value + v.width.value / 2,
                                               birth: now, duration: 0.45, hue: .secondaryLabelColor))
                }
            }

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
        pageSlide.step(dt); focusGlow.step(dt)
        for s in slots { s.step(dt, now: now) }

        // Reap fully-exited columns and dead flourishes.
        slots.removeAll { $0.exiting && $0.presence.value < 0.02 && $0.presence.isSettled }
        flourishes.removeAll { !$0.alive(now) }

        needsDisplay = true
    }

    private func everythingSettled() -> Bool {
        modeFade.isSettled && viewportX.isSettled && viewportW.isSettled &&
        pageSlide.isSettled && focusGlow.isSettled &&
        flourishes.isEmpty && slots.allSatisfy { $0.settled }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.cgContext.clear(bounds)
        ctx.shouldAntialias = true

        let live = 1 - modeFade.value      // dormant weight
        let managingWeight = modeFade.value

        if live > 0.01 { drawDormant(alpha: live) }
        if managingWeight > 0.01 { drawStrip(alpha: managingWeight) }
    }

    private func drawDormant(alpha: Double) {
        let rect = bounds
        let stroke = NSColor.secondaryLabelColor.withAlphaComponent(0.9 * alpha)
        stroke.setStroke()
        let colW: CGFloat = 7, gap: CGFloat = 2
        let totalW = colW * 2 + gap
        let startX = (rect.width - totalW) / 2
        for i in 0..<2 {
            let r = NSRect(x: startX + CGFloat(i) * (colW + gap), y: vInset + 2,
                           width: colW, height: rect.height - (vInset + 2) * 2)
            let p = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            p.setLineDash([2, 1.5], count: 2, phase: 0)
            p.lineWidth = 1
            p.stroke()
        }
    }

    private func drawStrip(alpha: Double) {
        guard !slots.isEmpty else { return }
        let rect = bounds.insetBy(dx: hInset, dy: 0)

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

        let top = rect.minY + vInset
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
            let base = blend(NSColor.secondaryLabelColor, NSColor.controlAccentColor, CGFloat(focus))
            let color = blend(base, NSColor.systemRed, CGFloat(1 - health) * 0.7)
            color.withAlphaComponent(CGFloat(present) * alpha).setFill()
            path.fill()
        }

        // 3. Viewport frame.
        let vx = mapX(viewportX.value)
        let vw = max(CGFloat(viewportW.value) * scale, 4)
        let vRect = NSRect(x: vx, y: rect.minY + 1.5,
                           width: min(vw, rect.maxX - vx), height: rect.height - 3)
        let vPath = NSBezierPath(roundedRect: vRect, xRadius: 3, yRadius: 3)
        vPath.lineWidth = 1.2
        NSColor.labelColor.withAlphaComponent(0.95 * alpha).setStroke()
        vPath.stroke()

        // 4. Flourishes on top.
        let now = CACurrentMediaTime()
        for f in flourishes { drawFlourish(f, now: now, mapX: mapX, top: top, bottomH: bottomH, alpha: alpha) }
    }

    private func drawFlourish(_ f: Flourish, now: CFTimeInterval,
                              mapX: (Double) -> CGFloat, top: CGFloat, bottomH: CGFloat, alpha: Double) {
        let p = f.progress(now)
        let cy = top + bottomH / 2
        switch f.kind {
        case .focusPulse:
            let cx = mapX(f.canvasX)
            let radius = 2 + CGFloat(easeOut(p)) * (bottomH * 0.9)
            let a = (1 - p) * 0.6 * alpha
            let ring = NSBezierPath(ovalIn: NSRect(x: cx - radius, y: cy - radius,
                                                   width: radius * 2, height: radius * 2))
            ring.lineWidth = 1.4
            f.hue.withAlphaComponent(CGFloat(a)).setStroke()
            ring.stroke()

        case .sparkle:
            let cx = mapX(f.canvasX)
            let reach = 2 + CGFloat(easeOut(p)) * 6
            let a = (1 - p) * 0.9 * alpha
            f.hue.withAlphaComponent(CGFloat(a)).setStroke()
            let star = NSBezierPath()
            star.lineWidth = 1.2
            for ang in stride(from: 0.0, to: Double.pi * 2, by: Double.pi / 2) {
                let dx = CGFloat(cos(ang)) * reach, dy = CGFloat(sin(ang)) * reach
                star.move(to: NSPoint(x: cx, y: cy))
                star.line(to: NSPoint(x: cx + dx, y: cy + dy))
            }
            star.stroke()

        case .poof:
            let cx = mapX(f.canvasX)
            let radius = 1 + CGFloat(easeOut(p)) * (bottomH * 0.7)
            let a = (1 - p) * 0.7 * alpha
            let ring = NSBezierPath(ovalIn: NSRect(x: cx - radius, y: cy - radius,
                                                   width: radius * 2, height: radius * 2))
            ring.lineWidth = 1.2
            f.hue.withAlphaComponent(CGFloat(a)).setStroke()
            ring.stroke()

        case .sweep:
            // A bright vertical bar wiping across the whole map.
            let x = bounds.minX + CGFloat(easeInOut(p)) * bounds.width
            let a = sin(p * Double.pi) * 0.8 * alpha // fade in and out
            let bar = NSBezierPath(rect: NSRect(x: x - 1.5, y: top, width: 3, height: bottomH))
            f.hue.withAlphaComponent(CGFloat(a)).setFill()
            bar.fill()
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

    private func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    private func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    deinit { displayLink?.invalidate() }
}
