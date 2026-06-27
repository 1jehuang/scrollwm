import Foundation
import AppKit
import QuartzCore

/// The interactive practice page — goal-oriented, with real moving windows.
///
/// It renders the live `TutorialPractice.World` as a small strip of window cards:
/// the focused card is outlined, the goal is marked (a glowing target card to
/// focus, or a dashed empty slot to move a window into), and the instruction sits
/// above. Pressing the focus/move shortcuts slides + re-focuses the cards (spring
/// animated) until the goal is reached, then it advances to the next task. When
/// every task is done it shows a short "all done" line with a Reset button.
///
/// IMPORTANT — this view NEVER registers a real event tap. The app forwards
/// observed presses via `deliver(chord:)` ONLY while this page is visible and
/// `isCapturing` is true (gated through `onCaptureChange`).
final class TutorialPracticeView: NSView {

    // MARK: - Public API (coordinator-facing)

    private(set) var isCapturing: Bool = false {
        didSet { if oldValue != isCapturing { onCaptureChange?(isCapturing) } }
    }

    /// Fired whenever `isCapturing` flips; the coordinator wires this to start /
    /// stop forwarding key presses from the app's key monitor.
    var onCaptureChange: ((Bool) -> Void)?

    /// Begin capturing. Idempotent. Call when the practice section shows.
    func start() {
        isCapturing = true
        render(animated: false)
        strip.start()
    }

    /// Stop capturing. Idempotent. Call when the section hides / window closes.
    func stop() {
        isCapturing = false
        strip.stop()
    }

    /// Feed a detected chord into the drill. Tolerant matching; no-op while not
    /// capturing. Animates the reaction and advances the task.
    @discardableResult
    func deliver(chord: String) -> TutorialPractice.Outcome? {
        guard isCapturing else { return nil }
        let outcome = practice.handle(chord: chord)
        react(to: outcome)
        return outcome
    }

    /// Rebuild from a fresh config (e.g. after a live config reload) and reset.
    func reload(config: ScrollWMConfig) {
        self.config = config
        practice = TutorialPractice(config: config)
        strip.set(world: practice.world, goal: practice.current?.goal, animated: false)
        render(animated: false)
    }

    /// Restart the drill from the first task.
    func resetDrill() {
        practice.reset()
        strip.set(world: practice.world, goal: practice.current?.goal, animated: true)
        render(animated: true)
    }

    /// Read-only snapshots for the coordinator / tests.
    var fraction: Double { practice.fraction }
    var headlineText: String { practice.headline }
    var isComplete: Bool { practice.isComplete }

    // MARK: - State

    private var practice: TutorialPractice
    /// The live config, kept so the key-hint line shows the user's real chords.
    private var config: ScrollWMConfig

    // MARK: - Subviews

    private let instruction = NSTextField(labelWithString: "")
    private let strip = PracticeStripView()
    private let keyHint = NSTextField(labelWithString: "")
    private let reaction = NSTextField(labelWithString: "")
    private let againButton = NSButton()
    private let column = NSStackView()

    // MARK: - Init

    init(config: ScrollWMConfig) {
        self.practice = TutorialPractice(config: config)
        self.config = config
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 320))
        translatesAutoresizingMaskIntoConstraints = false
        build()
        strip.set(world: practice.world, goal: practice.current?.goal, animated: false)
        render(animated: false)
    }

    /// Test-friendly initializer that takes a prebuilt state machine.
    init(practice: TutorialPractice) {
        self.practice = practice
        self.config = .default
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 320))
        translatesAutoresizingMaskIntoConstraints = false
        build()
        strip.set(world: practice.world, goal: practice.current?.goal, animated: false)
        render(animated: false)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Layout

    private func build() {
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        instruction.font = .systemFont(ofSize: 15, weight: .semibold)
        instruction.alignment = .center
        instruction.textColor = .labelColor
        instruction.maximumNumberOfLines = 2
        instruction.lineBreakMode = .byWordWrapping
        (instruction.cell as? NSTextFieldCell)?.wraps = true

        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.heightAnchor.constraint(equalToConstant: 150).isActive = true

        keyHint.font = .systemFont(ofSize: 12, weight: .regular)
        keyHint.alignment = .center
        keyHint.textColor = .secondaryLabelColor

        reaction.font = .systemFont(ofSize: 13, weight: .semibold)
        reaction.alignment = .center
        reaction.stringValue = " "

        againButton.title = "Reset practice"
        againButton.bezelStyle = .rounded
        againButton.target = self
        againButton.action = #selector(againTapped)

        column.addArrangedSubview(instruction)
        column.addArrangedSubview(strip)
        column.addArrangedSubview(keyHint)
        column.addArrangedSubview(reaction)
        column.addArrangedSubview(againButton)
        instruction.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        strip.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("ScrollWM practice")
    }

    /// Reflect the current state into the UI (instruction + key hint + buttons).
    private func render(animated: Bool) {
        if let task = practice.current {
            instruction.stringValue = task.instruction
            keyHint.stringValue = hintText(for: task)
            keyHint.isHidden = false
            againButton.isHidden = true
            setAccessibilityValueDescription(task.instruction)
        } else {
            instruction.stringValue = practice.tasks.isEmpty
                ? "Nothing to practice." : "Nice — you ran every move."
            keyHint.stringValue = practice.tasks.isEmpty
                ? "" : "Use these moves any time to drive the strip."
            keyHint.isHidden = false
            againButton.isHidden = practice.tasks.isEmpty
            setAccessibilityValueDescription(practice.headline)
        }
    }

    /// The "use these keys" line for a task, listing each move's live chord.
    private func hintText(for task: TutorialPractice.Task) -> String {
        let parts = task.moves.map { move -> String in
            "\(label(for: move)) \(ChordFormatter.chordText(config, move.action))"
        }
        return parts.joined(separator: "    ")
    }

    private func label(for move: TutorialPractice.Move) -> String {
        switch move {
        case .focusLeft:  return "Focus ←"
        case .focusRight: return "Focus →"
        case .moveLeft:   return "Move ←"
        case .moveRight:  return "Move →"
        }
    }

    // MARK: - Reactions

    private func react(to outcome: TutorialPractice.Outcome) {
        switch outcome {
        case .moved:
            strip.set(world: practice.world, goal: practice.current?.goal, animated: true)
        case .blocked:
            strip.set(world: practice.world, goal: practice.current?.goal, animated: true)
            strip.shake()
        case .taskComplete:
            flash("✓ Done — next task", color: .systemGreen)
            strip.set(world: practice.world, goal: practice.current?.goal, animated: true)
            render(animated: true)
        case .allComplete:
            flash("✓ All done!", color: .systemGreen)
            strip.set(world: practice.world, goal: nil, animated: true)
            render(animated: true)
        case .ignored:
            break
        }
    }

    private func flash(_ text: String, color: NSColor) {
        reaction.stringValue = text
        reaction.textColor = color
        guard respectsMotion, let layer = reactionLayer() else { return }
        layer.removeAnimation(forKey: "pulse")
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 0.85
        anim.toValue = 1.0
        anim.duration = 0.2
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "pulse")
    }

    private func reactionLayer() -> CALayer? {
        reaction.wantsLayer = true
        return reaction.layer
    }

    private var respectsMotion: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @objc private func againTapped() { resetDrill() }
}

// MARK: - PracticeStripView

/// Draws a small strip of window cards, the focused outline, and the goal
/// marker, easing card positions with springs so focus/move read as motion.
/// Pure-ish: it renders whatever `World` + `Goal` it's given; no key handling.
final class PracticeStripView: NSView {

    private final class CardVisual {
        let id: Int
        var slot: Spring   // logical slot index (0-based, left to right)
        var focus: Spring  // 0..1 focused-ness
        init(id: Int, slot: Int, focused: Bool) {
            self.id = id
            self.slot = Spring(Double(slot), response: 0.36, dampingFraction: 0.82)
            self.focus = Spring(focused ? 1 : 0, response: 0.28, dampingFraction: 0.9)
        }
        func step(_ dt: Double) { slot.step(dt); focus.step(dt) }
        var settled: Bool { slot.isSettled && focus.isSettled }
    }

    private var world = TutorialPractice.World(windows: [], focus: 0)
    private var goal: TutorialPractice.Goal?
    private var visuals: [Int: CardVisual] = [:]
    private var colorCache: [Int: NSColor] = [:]
    private var shakePhase: Double = 0

    private var link: CADisplayLink?
    private var lastTickNs: UInt64 = 0

    /// Force the static (reduced-motion) snapshot; used by the smoke test.
    var forceReducedMotion = false
    private var reduceMotion: Bool {
        forceReducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { start() } else { stop() }
    }

    // MARK: Public state

    /// Point the visuals at a new world + goal. With `animated`, the springs
    /// glide; otherwise they snap. Seeds/retires visuals as windows appear/leave.
    func set(world: TutorialPractice.World, goal: TutorialPractice.Goal?, animated: Bool) {
        self.world = world
        self.goal = goal
        // Ensure a visual exists per window; retire stale ones.
        let liveIDs = Set(world.windows.map { $0.id })
        for (i, win) in world.windows.enumerated() {
            let focused = i == world.focus
            if let v = visuals[win.id] {
                v.slot.target = Double(i)
                v.focus.target = focused ? 1 : 0
                if !animated { v.slot.reset(to: Double(i)); v.focus.reset(to: focused ? 1 : 0) }
            } else {
                visuals[win.id] = CardVisual(id: win.id, slot: i, focused: focused)
                colorCache[win.id] = AppColors.color(appName: win.appName, title: win.title)
            }
        }
        visuals = visuals.filter { liveIDs.contains($0.key) }
        if !animated { needsDisplay = true }
    }

    /// A quick horizontal shake to signal a blocked move (hit a wall).
    func shake() {
        guard respectsMotion else { return }
        shakePhase = 1
    }

    func start() {
        guard !reduceMotion else { needsDisplay = true; return }
        guard window != nil, link == nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastTickNs = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    deinit { link?.invalidate() }

    private var respectsMotion: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @objc private func tick(_ link: CADisplayLink) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let dt = lastTickNs == 0 ? 1.0 / 60.0 : Double(nowNs &- lastTickNs) / 1e9
        lastTickNs = nowNs
        advance(dt: min(dt, 0.1))
    }

    /// Integrate one frame: ease springs, decay the shake, redraw. Pure of the
    /// display link so the smoke test can drive fixed-dt frames windowless.
    func advance(dt: Double) {
        for v in visuals.values { v.step(dt) }
        if shakePhase > 0 { shakePhase = max(0, shakePhase - dt / 0.3) }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.cgContext.clear(bounds)
        ctx.shouldAntialias = true

        let dark = isDark
        // Background panel.
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        panel.fill()
        (dark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.07)).setStroke()
        panel.lineWidth = 1; panel.stroke()

        guard !world.windows.isEmpty else { return }

        let band = bounds.insetBy(dx: 18, dy: 22)
        let slots = max(world.windows.count, (goal?.targetSlot).map { $0 + 1 } ?? 0)
        guard slots > 0, band.width > 4 else { return }
        let gap: CGFloat = 8
        let slotW = (band.width - gap * CGFloat(slots - 1)) / CGFloat(slots)
        let cardH = band.height
        let shakeDX = shakePhase > 0 ? CGFloat(sin(shakePhase * .pi * 6)) * 6 * CGFloat(shakePhase) : 0

        func slotX(_ slot: Double) -> CGFloat {
            band.minX + CGFloat(slot) * (slotW + gap)
        }

        // Goal marker: a dashed empty slot for a `place` goal.
        if let slot = goal?.targetSlot {
            let rect = NSRect(x: slotX(Double(slot)), y: band.minY, width: slotW, height: cardH)
            drawGoalSlot(rect, dark: dark)
        }

        // Cards, drawn in world order so later (right) ones overlap on top.
        for win in world.windows {
            guard let v = visuals[win.id] else { continue }
            let focus = CGFloat(max(0, min(1, v.focus.value)))
            let x = slotX(v.slot.value) + (focus > 0.5 ? shakeDX : 0)
            let rect = NSRect(x: x, y: band.minY, width: slotW, height: cardH)
            let isGoalTarget = (goal?.targetID == win.id)
            drawCard(rect: rect, color: colorCache[win.id] ?? .systemGray,
                     title: win.title, focus: focus,
                     goalTarget: isGoalTarget && goal?.targetSlot == nil,
                     dark: dark)
        }
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func drawGoalSlot(_ rect: NSRect, dark: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
        path.stroke()
        // "Move here" caption.
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.systemBlue,
            .paragraphStyle: para,
        ]
        let s = "move here" as NSString
        let h = s.size(withAttributes: attrs).height
        s.draw(in: NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h),
               withAttributes: attrs)
    }

    private func drawCard(rect: NSRect, color: NSColor, title: String,
                          focus: CGFloat, goalTarget: Bool, dark: Bool) {
        guard rect.width > 1, rect.height > 1 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)

        let baseWhite: CGFloat = dark ? 0.22 : 0.88
        NSColor(white: baseWhite, alpha: 1).setFill(); path.fill()

        // App-color wash, stronger when focused.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let topAlpha = 0.28 + 0.45 * focus
        let grad = NSGradient(colors: [color.withAlphaComponent(topAlpha),
                                       color.withAlphaComponent(topAlpha * 0.25)])
        grad?.draw(in: rect, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Titlebar with three dots.
        let barH = min(rect.height * 0.2, 14)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        (dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 1, alpha: 0.55)).setFill()
        NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: barH)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let dotColors = [NSColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1),
                         NSColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                         NSColor(srgbRed: 0.24, green: 0.79, blue: 0.29, alpha: 1)]
        let dotR: CGFloat = min(3, barH * 0.28)
        if rect.width > dotR * 10 {
            for d in 0..<3 {
                let cx = rect.minX + 8 + CGFloat(d) * (dotR * 2 + 3)
                let dot = NSBezierPath(ovalIn: NSRect(x: cx, y: rect.minY + barH / 2 - dotR,
                                                      width: dotR * 2, height: dotR * 2))
                dotColors[d].withAlphaComponent(0.5 + 0.5 * focus).setFill()
                dot.fill()
            }
        }

        // Title text when wide enough.
        if rect.width > 48 {
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            let labelColor = dark ? NSColor(white: 0.92, alpha: 0.6 + 0.4 * focus)
                                  : NSColor(white: 0.12, alpha: 0.55 + 0.45 * focus)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: labelColor,
                .paragraphStyle: para,
            ]
            (title as NSString).draw(in: NSRect(x: rect.minX + 8, y: rect.minY + barH + 5,
                                                width: rect.width - 12, height: 14),
                                     withAttributes: attrs)
        }

        // Goal target glow (a window to focus): a soft blue dashed ring + label.
        if goalTarget {
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), xRadius: 10, yRadius: 10)
            ring.lineWidth = 2
            ring.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
            ring.stroke()
        }

        // Focused outline: a crisp accent border.
        if focus > 0.01 {
            let outline = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            NSColor.controlAccentColor.withAlphaComponent(0.95 * focus).setStroke()
            outline.lineWidth = 2.5
            outline.stroke()
        } else {
            (dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1)).setStroke()
            path.lineWidth = 1; path.stroke()
        }
    }
}
