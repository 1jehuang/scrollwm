import Foundation
import AppKit

/// Offscreen render harness for the redesigned tutorial. It captures two things
/// without needing a visible (or unlocked) screen:
///   1. A contact sheet of the interactive practice strip being driven through a
///      task to its goal (so the "real moving windows" can be eyeballed).
///   2. A single tall snapshot of the whole tutorial window content column (the
///      one continuous scroll) so the simplified styling can be reviewed.
///
/// Run with: `WindowLab tutorialrender [out_prefix]`  (writes
/// `<prefix>_practice.png` and `<prefix>_window.png`).
enum TutorialRender {

    static func run(outPrefix: String) -> Bool {
        let okA = renderPracticeSheet(out: outPrefix + "_practice.png")
        let okB = renderWindowColumn(out: outPrefix + "_window.png")
        return okA && okB
    }

    // MARK: - Practice strip contact sheet

    private static func renderPracticeSheet(out: String) -> Bool {
        let scale: CGFloat = 2
        let w = 460, h = 320
        let view = TutorialPracticeView(config: .default)
        view.frame = NSRect(x: 0, y: 0, width: w, height: h)
        view.appearance = NSAppearance(named: .darkAqua)
        view.start()
        view.layoutSubtreeIfNeeded()

        // A sequence of chords that solves the default first few tasks, so the
        // sheet shows focus moving, a task completing, then a window moving.
        let chords = ["", "cmd+h", "cmd+h",          // task 1: focus left to goal
                      "cmd+l", "cmd+l", "cmd+l",      // task 2: focus right to goal
                      "cmd+shift+h", "cmd+shift+h"]   // task 3: move left to slot

        var frames: [(String, NSImage)] = []
        func snap(_ label: String) {
            // Settle the springs a touch between presses.
            for _ in 0..<14 { view.layoutSubtreeIfNeeded() }
            if let img = snapshot(view: view, scale: scale) { frames.append((label, img)) }
        }
        snap("start")
        for chord in chords {
            if !chord.isEmpty { _ = view.deliver(chord: chord) }
            // Drive a few animation frames on the strip so motion is captured.
            for _ in 0..<10 { advanceStrip(in: view, dt: 1.0 / 60.0) }
            snap(chord.isEmpty ? "idle" : chord)
        }

        guard let sheet = composeSheet(frames, cellW: Int(CGFloat(w) * scale),
                                       cellH: Int(CGFloat(h) * scale)) else { return false }
        return write(sheet, to: out, what: "\(frames.count)-frame practice sheet")
    }

    /// Reach the PracticeStripView via the view tree and advance its springs.
    private static func advanceStrip(in view: NSView, dt: Double) {
        for sub in view.subviews {
            if let strip = sub as? PracticeStripView { strip.advance(dt: dt) }
            else { advanceStrip(in: sub, dt: dt) }
        }
    }

    private static func snapshot(view: NSView, scale: CGFloat) -> NSImage? {
        let bounds = view.bounds
        guard bounds.width > 0, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        guard let cg = rep.cgImage else { return nil }
        let img = NSImage(size: NSSize(width: bounds.width * scale, height: bounds.height * scale))
        img.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return nil }
        ctx.setFillColor(NSColor(white: 0.10, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: img.size))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(origin: .zero, size: img.size))
        img.unlockFocus()
        return img
    }

    private static func composeSheet(_ frames: [(String, NSImage)], cellW: Int, cellH: Int) -> NSImage? {
        guard !frames.isEmpty else { return nil }
        let cols = 3
        let rows = (frames.count + cols - 1) / cols
        let pad = 12, labelH = 18
        let cw = cellW + pad * 2, ch = cellH + labelH + pad
        let sheet = NSImage(size: NSSize(width: cw * cols, height: ch * rows))
        sheet.lockFocus()
        NSColor(white: 0.18, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: cw * cols, height: ch * rows).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        for (i, frame) in frames.enumerated() {
            let col = i % cols, row = i / cols
            let x = col * cw + pad
            let yTop = row * ch
            let y = Int(sheet.size.height) - yTop - ch + pad
            frame.1.draw(in: NSRect(x: x, y: y + labelH, width: cellW, height: cellH))
            ("\(i): \(frame.0)" as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
        sheet.unlockFocus()
        return sheet
    }

    // MARK: - Whole window column snapshot

    private static func renderWindowColumn(out: String) -> Bool {
        let width: CGFloat = 560
        let controller = TutorialWindowController(configProvider: { .default })
        guard let column = controller.debugBuildColumn(width: width) else {
            print("tutorialrender: could not build column"); return false
        }
        column.appearance = NSAppearance(named: .darkAqua)
        // Lay out at a fixed width and let height grow to fit.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1200))
        host.appearance = NSAppearance(named: .darkAqua)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            column.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        let fit = column.fittingSize
        let totalH = max(fit.height, 200)
        host.frame = NSRect(x: 0, y: 0, width: width, height: totalH)
        host.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let cg = rep.cgImage else { return false }
        let img = NSImage(size: NSSize(width: width * scale, height: totalH * scale))
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
            ctx.fill(CGRect(origin: .zero, size: img.size))
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(origin: .zero, size: img.size))
        }
        img.unlockFocus()
        return write(img, to: out, what: "window column (\(Int(width))x\(Int(totalH)))")
    }

    // MARK: - PNG IO

    private static func write(_ image: NSImage, to path: String, what: String) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("tutorialrender: failed to encode \(what)"); return false
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("tutorialrender: wrote \(what) to \(path)")
            return true
        } catch {
            print("tutorialrender: write failed: \(error)"); return false
        }
    }
}
