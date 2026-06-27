import AppKit
import QuartzCore

// MARK: - TutorialStripDiagramView
//
// The tutorial's hero animation. It SHOWS the scrolling-strip metaphor: a row
// of colored "window cards" packed on one long horizontal strip, with a glowing
// viewport frame that smoothly teleports between columns as focus moves, plus
// columns that reorder (move) and resize (width presets). It auto-plays a gentle
// scripted loop (`StripDiagramModel.demoScript`) so the idea lands at a glance.
//
// All scrolling/reorder/resize LOGIC lives in the pure `StripDiagramModel`; this
// view only eases logical geometry into pixels with cosmetic per-column springs
// and paints it. Respects Reduce Motion (static labeled fallback) and light/dark.
//
// Self-contained: `init()` builds a sensible default; the controller calls
// `start()` / `stop()` when the page shows / hides.

final class TutorialStripDiagramView: NSView {

    // MARK: Per-column cosmetic animation (pixels follow the model's logic)

    /// Smoothly-eased visual state for one column. The logical truth is in the
    /// model; these springs make reorder/resize/focus read as motion, not jumps.
    private final class ColumnVisual {
        let id: Int
        var x: Spring         // logical left edge (viewport units)
        var w: Spring         // logical width (viewport units)
        var focus: Spring     // 0 = unfocused, 1 = focused (drives glow/brightness)
        var pop: Spring       // transient lift on reorder/resize

        init(id: Int, x: Double, w: Double, focused: Bool) {
            self.id = id
            self.x = Spring(x, response: 0.42, dampingFraction: 0.86)
            self.w = Spring(w, response: 0.42, dampingFraction: 0.86)
            self.focus = Spring(focused ? 1 : 0, response: 0.3, dampingFraction: 0.9)
            self.pop = Spring(0, response: 0.45, dampingFraction: 0.6)
        }
        func step(_ dt: Double) { x.step(dt); w.step(dt); focus.step(dt); pop.step(dt) }
        var settled: Bool { x.isSettled && w.isSettled && focus.isSettled && pop.isSettled }
    }

    // MARK: State

    private var model: StripDiagramModel
    private var visuals: [Int: ColumnVisual] = [:]
    private var colorCache: [Int: NSColor] = [:]

    // Scripted-loop playback.
    private let script: [StripDiagramModel.Action]
    private var scriptIndex = 0
    private var dwellElapsed: Double = 0
    /// Seconds each step is held before the next action fires.
    var stepInterval: Double = 1.35

    // Display link / clock.
    private var link: CADisplayLink?
    private var lastTickNs: UInt64 = 0
    private var didSeedVisuals = false

    /// Force the static (reduced-motion) rendering regardless of system setting.
    /// Used by the offscreen smoke test; defaults to following the system.
    var forceReducedMotion = false

    private var reduceMotion: Bool {
        forceReducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Init

    /// Build with a custom model + script (script defaults to the model's own
    /// demo choreography).
    init(model: StripDiagramModel, script: [StripDiagramModel.Action]? = nil) {
        self.model = model
        self.script = script ?? StripDiagramModel.demoScript
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 200))
        wantsLayer = true
        layer?.isOpaque = false
    }

    /// Sensible default: the demo strip + demo script.
    convenience init() {
        self.init(model: .demo(), script: StripDiagramModel.demoScript)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }   // y grows down; simpler card layout

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { start() } else { stop() }
    }

    /// Begin the auto-play loop. Safe to call repeatedly. A no-op (beyond a
    /// single static paint) under Reduce Motion.
    func start() {
        seedVisualsIfNeeded()
        guard !reduceMotion else { needsDisplay = true; return }
        guard window != nil, link == nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        let maxFPS = Float(window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maxFPS, preferred: maxFPS)
        l.add(to: .main, forMode: .common)
        link = l
        lastTickNs = 0
    }

    /// Stop the loop and release the display link.
    func stop() {
        link?.invalidate()
        link = nil
    }

    deinit { link?.invalidate() }

    // MARK: Animation driving

    @objc private func tick(_ link: CADisplayLink) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let dt = lastTickNs == 0 ? 1.0 / 60.0 : Double(nowNs &- lastTickNs) / 1e9
        lastTickNs = nowNs
        advance(dt: min(dt, 0.1))
    }

    /// Integrate one frame: run the script clock, ease all springs, redraw.
    /// Pure of the display link so the offscreen smoke test can drive frames
    /// with a fixed dt and no window.
    func advance(dt: Double) {
        seedVisualsIfNeeded()

        if !script.isEmpty {
            dwellElapsed += dt
            if dwellElapsed >= stepInterval {
                dwellElapsed = 0
                applyScriptStep()
            }
        }

        model.step(dt)
        syncVisualTargets()
        for v in visuals.values { v.step(dt) }
        needsDisplay = true
    }

    private func applyScriptStep() {
        let action = script[scriptIndex % script.count]
        scriptIndex = (scriptIndex + 1) % max(script.count, 1)
        let movedOrSized: Bool
        switch action {
        case .moveLeft, .moveRight, .cycleWidth: movedOrSized = true
        default: movedOrSized = false
        }
        model.apply(action)
        // A little lift on the focused column when it reorders/resizes so the
        // change reads as a deliberate motion, not a teleport.
        if movedOrSized, let v = visuals[model.focusedColumn.id] { v.pop.kick(6) }
    }

    // MARK: Visual <-> model sync

    private func seedVisualsIfNeeded() {
        guard !didSeedVisuals else { return }
        didSeedVisuals = true
        for (i, col) in model.columns.enumerated() {
            visuals[col.id] = ColumnVisual(id: col.id, x: model.x(of: i),
                                           w: model.width(of: i), focused: i == model.focusIndex)
            colorCache[col.id] = AppColors.color(appName: col.appName, title: col.title)
        }
        model.snapViewport()
    }

    /// Point every column's springs at its current logical geometry + focus.
    private func syncVisualTargets() {
        for (i, col) in model.columns.enumerated() {
            guard let v = visuals[col.id] else { continue }
            v.x.target = model.x(of: i)
            v.w.target = model.width(of: i)
            v.focus.target = (i == model.focusIndex) ? 1 : 0
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.cgContext.clear(bounds)
        ctx.shouldAntialias = true
        seedVisualsIfNeeded()

        let dark = isDark
        drawBackground(dark: dark)

        if reduceMotion {
            // Static labeled fallback: snap to the settled layout, draw it once,
            // and add a one-line caption explaining the metaphor.
            model.snapViewport()
            for (i, col) in model.columns.enumerated() {
                visuals[col.id]?.x.reset(to: model.x(of: i))
                visuals[col.id]?.w.reset(to: model.width(of: i))
                visuals[col.id]?.focus.reset(to: i == model.focusIndex ? 1 : 0)
            }
            drawStrip(dark: dark)
            drawCaption("Focus slides the viewport along the strip", dark: dark)
        } else {
            drawStrip(dark: dark)
        }
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func drawBackground(dark: Bool) {
        let bg = dark ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        bg.setFill(); r.fill()
        (dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.06)).setStroke()
        r.lineWidth = 1; r.stroke()
    }

    /// Layout band: a horizontal area centered vertically, padded on all sides.
    private var stripBand: NSRect {
        bounds.insetBy(dx: 22, dy: 30)
    }

    /// Pixel mapping uses the ANIMATED geometry (spring values) so reorder /
    /// resize / scroll all glide. Scale fits the union of all columns and the
    /// viewport so nothing ever clips as widths cycle.
    private func currentScale(in band: NSRect) -> (scale: CGFloat, minX: Double) {
        var minX = model.viewport.value
        var maxX = model.viewport.value + model.viewportWidth
        for v in visuals.values {
            minX = min(minX, v.x.value)
            maxX = max(maxX, v.x.value + v.w.value)
        }
        let span = max(maxX - minX, model.viewportWidth)
        return (band.width / CGFloat(span), minX)
    }

    private func drawStrip(dark: Bool) {
        let band = stripBand
        guard band.width > 4, band.height > 4 else { return }
        let (scale, minX) = currentScale(in: band)
        func mapX(_ x: Double) -> CGFloat { band.minX + CGFloat(x - minX) * scale }

        // Strip baseline rail: a subtle groove the cards sit on.
        let rail = NSBezierPath(roundedRect:
            NSRect(x: band.minX - 6, y: band.midY - band.height * 0.34,
                   width: band.width + 12, height: band.height * 0.68),
            xRadius: 10, yRadius: 10)
        (dark ? NSColor(white: 1, alpha: 0.04) : NSColor(white: 0, alpha: 0.035)).setFill()
        rail.fill()

        let cardH = band.height * 0.6
        let cardY = band.midY - cardH / 2

        // Columns, ordered by id-stable visuals but positioned by their springs.
        for (i, col) in model.columns.enumerated() {
            guard let v = visuals[col.id] else { continue }
            let focus = CGFloat(max(0, min(1, v.focus.value)))
            let lift = CGFloat(max(0, v.pop.value)) * 2.0
            let x = mapX(v.x.value)
            let w = max(CGFloat(v.w.value) * scale - 6, 8)   // 6px gutter between cards
            let h = cardH + lift * 2
            let y = cardY - lift
            drawCard(rect: NSRect(x: x + 3, y: y, width: w, height: h),
                     color: colorCache[col.id] ?? NSColor.systemGray,
                     title: col.title, focus: focus, dark: dark, index: i)
        }

        // Glowing viewport frame: hugs the eased viewport window over the strip.
        let vx = mapX(model.viewport.value)
        let vw = CGFloat(model.viewportWidth) * scale
        let vRect = NSRect(x: vx + 1, y: band.minY - 6,
                           width: max(vw - 2, 10), height: band.height + 12)
        drawViewportFrame(vRect, dark: dark)
    }

    private func drawCard(rect: NSRect, color: NSColor, title: String,
                          focus: CGFloat, dark: Bool, index: Int) {
        guard rect.width > 1, rect.height > 1 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)

        // Body: a neutral surface that brightens + saturates toward the app color
        // as it gains focus. Unfocused cards read as quiet, dimmed panes.
        let baseWhite: CGFloat = dark ? 0.20 : 0.86
        let body = NSColor(white: baseWhite, alpha: 1)
        body.setFill(); path.fill()

        // App-color wash, stronger when focused (so the focused pane "lights up").
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let topAlpha = 0.30 + 0.45 * focus
        let grad = NSGradient(colors: [color.withAlphaComponent(topAlpha),
                                       color.withAlphaComponent(topAlpha * 0.25)])
        grad?.draw(in: rect, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Titlebar with three traffic-light dots.
        let barH = min(rect.height * 0.26, 14)
        let barRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: barH)
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        clip.addClip()
        (dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 1, alpha: 0.55)).setFill()
        NSBezierPath(rect: barRect).fill()
        NSGraphicsContext.restoreGraphicsState()

        let dotColors = [NSColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1),
                         NSColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                         NSColor(srgbRed: 0.24, green: 0.79, blue: 0.29, alpha: 1)]
        let dotR: CGFloat = min(3, barH * 0.28)
        if rect.width > dotR * 10 {
            for d in 0..<3 {
                let cx = rect.minX + 8 + CGFloat(d) * (dotR * 2 + 3)
                let dot = NSBezierPath(ovalIn: NSRect(x: cx, y: barRect.midY - dotR,
                                                      width: dotR * 2, height: dotR * 2))
                dotColors[d].withAlphaComponent(0.5 + 0.5 * focus).setFill()
                dot.fill()
            }
        }

        // Title text (clipped) when the card is wide enough to read.
        if rect.width > 48 {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let labelColor = dark ? NSColor(white: 0.92, alpha: 0.6 + 0.4 * focus)
                                  : NSColor(white: 0.12, alpha: 0.55 + 0.45 * focus)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: labelColor,
                .paragraphStyle: para,
            ]
            let tRect = NSRect(x: rect.minX + 8, y: rect.minY + barH + 4,
                               width: rect.width - 12, height: 14)
            (title as NSString).draw(in: tRect, withAttributes: attrs)
        }

        // Border, accented under focus.
        let border = focus > 0.5
            ? NSColor.controlAccentColor.withAlphaComponent(0.0)   // accent handled by viewport glow
            : (dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.10))
        border.setStroke(); path.lineWidth = 1; path.stroke()
    }

    private func drawViewportFrame(_ rect: NSRect, dark: Bool) {
        let accent = NSColor.controlAccentColor
        // Outer glow: a few expanding translucent strokes.
        for (i, spread) in [6.0, 4.0, 2.0].enumerated() {
            let glow = NSBezierPath(roundedRect: rect.insetBy(dx: -CGFloat(spread), dy: -CGFloat(spread)),
                                    xRadius: 12, yRadius: 12)
            accent.withAlphaComponent(0.06 + 0.04 * Double(i)).setStroke()
            glow.lineWidth = 2
            glow.stroke()
        }
        // Crisp viewport outline.
        let frame = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        accent.withAlphaComponent(0.95).setStroke()
        frame.lineWidth = 2.5
        frame.stroke()

        // "VIEWPORT" tab label above the top-left of the frame.
        let para = NSMutableParagraphStyle(); para.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: accent,
            .paragraphStyle: para,
        ]
        let label = "VIEWPORT" as NSString
        let ls = label.size(withAttributes: attrs)
        let ly = max(rect.minY - ls.height - 1, bounds.minY + 2)
        label.draw(in: NSRect(x: rect.minX + 2, y: ly, width: ls.width + 4, height: ls.height),
                   withAttributes: attrs)
    }

    private func drawCaption(_ text: String, dark: Bool) {
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: dark ? NSColor(white: 0.8, alpha: 1) : NSColor(white: 0.25, alpha: 1),
            .paragraphStyle: para,
        ]
        let s = text as NSString
        let h = s.size(withAttributes: attrs).height
        s.draw(in: NSRect(x: bounds.minX + 12, y: bounds.maxY - h - 8,
                          width: bounds.width - 24, height: h), withAttributes: attrs)
    }
}
