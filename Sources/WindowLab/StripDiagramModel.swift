import Foundation

// MARK: - StripDiagramModel
//
// PURE model behind the tutorial's hero animation: a row of "window columns"
// living on one long horizontal strip, with a viewport that teleports between
// columns as focus moves (PaperWM-style). No AppKit dependency, so every rule
// (focus wrap/clamp, reorder, width-cycle, keep-the-focus-visible viewport
// scrolling) is unit-testable in isolation (see `StripDiagramTests`).
//
// Coordinate space: everything is measured in *viewport widths*. One viewport
// is `viewportWidth == 1.0` (think "one screen"). A column's `widthFraction`
// is its width as a fraction of the viewport, so a 0.5 column is a half-screen
// pane. Columns are packed left-to-right with no gaps; the strip's logical
// length is the sum of the column widths. The viewport offset is the strip
// coordinate of the viewport's LEFT edge, eased by a spring so teleports glide.
//
// The view (`TutorialStripDiagramView`) reads this model every frame and adds
// purely cosmetic per-column springs (slide/grow/glow); it never owns the
// scrolling rule — that lives here so it can be proven correct.

/// One window "column" on the strip. Colors are resolved by the view via
/// `AppColors.color(appName:title:)`, so the model stays AppKit-free and pure.
struct DiagramColumn: Equatable {
    let id: Int
    var appName: String
    var title: String
    /// Width as a fraction of one viewport (e.g. 0.5 == half-screen pane).
    var widthFraction: Double
}

struct StripDiagramModel {

    /// The discrete actions the strip understands. Each maps to one pure
    /// mutating step; the demo loop and the tests both drive the model through
    /// these so behavior is identical on screen and under test.
    enum Action: Equatable {
        case focusLeft
        case focusRight
        case moveLeft
        case moveRight
        case cycleWidth
    }

    // MARK: Stored state

    private(set) var columns: [DiagramColumn]
    private(set) var focusIndex: Int

    /// Spring-eased viewport LEFT-edge offset (strip coordinates). `value` is
    /// the animated position; `target` is where the scrolling rule wants it.
    var viewport: Spring

    /// One viewport == one "screen". Fixed; columns size relative to it.
    let viewportWidth: Double = 1.0

    /// Whether focus wraps around the ends (true) or clamps at them (false).
    /// The demo loop wraps so it can run forever; tests cover both.
    var wrapsFocus: Bool

    /// The width presets a column cycles through, smallest -> largest, as
    /// fractions of the viewport. Mirrors the app's quarter/third/half/full feel.
    static let widthPresets: [Double] = [1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0]

    // MARK: Init

    init(columns: [DiagramColumn], focusIndex: Int = 0, wrapsFocus: Bool = true,
         response: Double = 0.5, dampingFraction: Double = 0.82) {
        precondition(!columns.isEmpty, "StripDiagramModel needs at least one column")
        self.columns = columns
        self.focusIndex = min(max(focusIndex, 0), columns.count - 1)
        self.wrapsFocus = wrapsFocus
        self.viewport = Spring(0, response: response, dampingFraction: dampingFraction)
        // Seed the viewport on the initial focus with no motion.
        self.viewport.reset(to: viewportTargetOffset())
    }

    /// A pleasant default arrangement: a handful of varied "apps" wide enough
    /// that the strip overflows the viewport, so the teleport is visible.
    static func demo() -> StripDiagramModel {
        let cols = [
            DiagramColumn(id: 0, appName: "Ghostty", title: "✳ claude", widthFraction: 0.5),
            DiagramColumn(id: 1, appName: "Cursor", title: "TeleportEngine.swift", widthFraction: 2.0 / 3.0),
            DiagramColumn(id: 2, appName: "Safari", title: "docs", widthFraction: 0.5),
            DiagramColumn(id: 3, appName: "Ghostty", title: "nvim", widthFraction: 1.0 / 3.0),
            DiagramColumn(id: 4, appName: "Spotify", title: "Now Playing", widthFraction: 0.5),
            DiagramColumn(id: 5, appName: "Messages", title: "Chat", widthFraction: 1.0 / 3.0),
        ]
        return StripDiagramModel(columns: cols, focusIndex: 1)
    }

    /// The default auto-play choreography: drift right, reorder, resize, drift
    /// back. Wrapping makes it loopable. Kept here (not in the view) so a test
    /// can replay the whole script and assert the model stays valid.
    static let demoScript: [Action] = [
        .focusRight, .focusRight, .moveLeft, .focusRight,
        .cycleWidth, .focusRight, .focusLeft, .cycleWidth,
        .focusLeft, .moveRight, .focusLeft, .focusLeft,
    ]

    // MARK: Geometry (pure)

    var count: Int { columns.count }

    /// Logical width (in viewport units) of column `i`.
    func width(of i: Int) -> Double {
        guard columns.indices.contains(i) else { return 0 }
        return columns[i].widthFraction * viewportWidth
    }

    /// Logical x (left edge) of column `i` = sum of widths to its left.
    func x(of i: Int) -> Double {
        guard columns.indices.contains(i) else { return 0 }
        var acc = 0.0
        for j in 0..<i { acc += width(of: j) }
        return acc
    }

    /// Total logical length of the strip (sum of all column widths).
    var totalWidth: Double {
        columns.reduce(0) { $0 + $1.widthFraction } * viewportWidth
    }

    /// Furthest-right the viewport may scroll while never showing empty space
    /// past the strip's end. Zero when the whole strip fits in one viewport.
    var maxOffset: Double { max(0, totalWidth - viewportWidth) }

    var focusedColumn: DiagramColumn { columns[focusIndex] }
    var focusX: Double { x(of: focusIndex) }
    var focusWidth: Double { width(of: focusIndex) }

    /// The scrolling rule, as a PURE function of the current focus:
    /// keep the focused column fully inside the viewport with the least motion
    /// (PaperWM "scroll just enough"), then clamp so we never overscroll past
    /// the strip ends. The result always satisfies
    /// `offset <= focusX` and `focusX + focusWidth <= offset + viewportWidth`
    /// whenever the focused column fits in a viewport.
    func viewportTargetOffset() -> Double {
        let fx = focusX
        let fw = focusWidth
        // A column wider than the viewport can't fit; pin its LEFT edge so the
        // user sees its start (and it stays in view), never overscrolling.
        if fw >= viewportWidth {
            return min(max(fx, 0), max(maxOffset, fx))
        }
        var offset = viewport.target
        if fx < offset {
            offset = fx                              // scroll left to reveal it
        } else if fx + fw > offset + viewportWidth {
            offset = fx + fw - viewportWidth         // scroll right to reveal it
        }
        // Never reveal empty space beyond the strip.
        return min(max(offset, 0), maxOffset)
    }

    /// True when column `i` is fully within the current eased viewport window.
    func isFullyVisible(_ i: Int, slack: Double = 1e-9) -> Bool {
        let l = x(of: i), r = l + width(of: i)
        return l >= viewport.value - slack && r <= viewport.value + viewportWidth + slack
    }

    // MARK: Steps (pure mutations)

    /// Apply one demo action. Single entry point so screen + tests share logic.
    mutating func apply(_ action: Action) {
        switch action {
        case .focusLeft:  focus(by: -1)
        case .focusRight: focus(by: 1)
        case .moveLeft:   moveFocused(by: -1)
        case .moveRight:  moveFocused(by: 1)
        case .cycleWidth: cycleWidth()
        }
    }

    /// Focus an absolute column index (clamped to a valid range) and retarget
    /// the viewport. Used to jump directly (e.g. a "jump to N" gesture).
    mutating func setFocus(_ index: Int) {
        guard count > 0 else { return }
        focusIndex = min(max(index, 0), count - 1)
        retargetViewport()
    }

    /// Move focus by `delta` columns. Wraps around the ends when `wrapsFocus`,
    /// otherwise clamps. Retargets the viewport so the new focus is visible.
    mutating func focus(by delta: Int) {
        guard count > 0 else { return }
        if wrapsFocus {
            focusIndex = ((focusIndex + delta) % count + count) % count
        } else {
            focusIndex = min(max(focusIndex + delta, 0), count - 1)
        }
        retargetViewport()
    }

    /// Reorder: swap the focused column with its neighbor `delta` away. Focus
    /// follows the moved column. Clamps at the ends (no wrap for reorder, which
    /// matches the app — you can't move a column off the end of the strip).
    @discardableResult
    mutating func moveFocused(by delta: Int) -> Bool {
        let target = focusIndex + delta
        guard columns.indices.contains(target) else { return false }
        columns.swapAt(focusIndex, target)
        focusIndex = target
        retargetViewport()
        return true
    }

    /// Cycle the focused column's width to the next preset (`delta` steps
    /// through `widthPresets`, wrapping). Retargets so a now-wider column that
    /// spills past the viewport edge scrolls back into view.
    mutating func cycleWidth(by delta: Int = 1) {
        let presets = Self.widthPresets
        guard !presets.isEmpty else { return }
        let current = columns[focusIndex].widthFraction
        // Find the nearest preset index to the current width, then step.
        let nearest = presets.indices.min(by: {
            abs(presets[$0] - current) < abs(presets[$1] - current)
        }) ?? 0
        let next = ((nearest + delta) % presets.count + presets.count) % presets.count
        columns[focusIndex].widthFraction = presets[next]
        retargetViewport()
    }

    /// Recompute the viewport target from the scrolling rule (does NOT snap;
    /// the spring eases `value` toward it over subsequent `step` calls).
    mutating func retargetViewport() {
        viewport.target = viewportTargetOffset()
    }

    /// Advance the viewport spring by `dt` seconds (call once per frame).
    mutating func step(_ dt: Double) {
        viewport.step(dt)
    }

    /// Snap the viewport to its target with no motion (initial seed / reduced
    /// motion). Leaves the logical layout untouched.
    mutating func snapViewport() {
        viewport.reset(to: viewportTargetOffset())
    }

    /// True once the viewport spring has settled on its target.
    var isSettled: Bool { viewport.isSettled }
}
