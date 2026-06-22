import Foundation
import AppKit

/// Offscreen render harness for the animated menu-bar mini-map. Drives the
/// real `MenuBarStripView` with a virtual clock through scripted window-manager
/// actions, captures key frames, and writes a contact-sheet PNG so the
/// animation can be verified visually without disturbing the live menu bar.
///
/// Run with: `WindowLab animrender [out.png]`
enum MenuBarAnimationRender {

    /// A synthetic strip state builder (mirrors the engine's gap layout).
    /// IDs map to realistic app identities so the app-color tinting is exercised
    /// in the rendered contact sheet.
    private static func identity(_ id: UInt64) -> (app: String, title: String) {
        switch id {
        case 1: return ("kitty", "claude — repo")
        case 2: return ("kitty", "codex session")
        case 3: return ("Google Chrome", "GitHub — PR")
        case 4: return ("Firefox", "Hacker News")
        case 5: return ("kitty", "nvim main.swift")
        case 6: return ("Spotify", "Lofi beats")
        default: return ("Discord", "general")
        }
    }

    private static func state(_ ids: [UInt64], focus: Int, widths: [CGFloat]? = nil,
                              viewportX: CGFloat = 0, viewportWidth: CGFloat = 1600) -> TeleportEngine.StripState {
        var x: CGFloat = 12
        var slots: [(id: UInt64, appName: String, title: String, canvasX: CGFloat, width: CGFloat, healthy: Bool)] = []
        for (i, id) in ids.enumerated() {
            let w = widths?[i] ?? 360
            let who = identity(id)
            slots.append((id: id, appName: who.app, title: who.title, canvasX: x, width: w, healthy: true))
            x += w + 12
        }
        return TeleportEngine.StripState(slots: slots, viewportX: viewportX,
                                         viewportWidth: viewportWidth, focusIndex: focus, lastTeleportMs: 1.0)
    }

    private struct Step {
        let label: String
        let apply: (() -> Void)?
        let holdFrames: Int
    }

    static func run(outPath: String) -> Bool {
        let scale: CGFloat = 6           // upscale so the tiny icon is legible
        let iconW: CGFloat = 30, iconH: CGFloat = 22
        let cellW = Int(iconW * scale), cellH = Int(iconH * scale)
        let fps = 60.0, dt = 1.0 / fps

        let view = MenuBarStripView(frame: NSRect(x: 0, y: 0, width: iconW, height: iconH))

        // Virtual clock: flourish birth times and frame advances share one base.
        let base = CACurrentMediaTime()
        var vt = base

        // Scripted timeline of window-manager actions. Each step applies a new
        // state (or nil for a pure hold) then renders `holdFrames` frames; we
        // snapshot the most expressive frame partway through each hold.
        let timeline: [Step] = [
            Step(label: "dormant",   apply: { view.apply(state: state([], focus: 0), managing: false, now: vt) }, holdFrames: 12),
            Step(label: "arrange",   apply: { view.apply(state: state([1,2,3,4], focus: 0), managing: true, now: vt) }, holdFrames: 22),
            Step(label: "focus->2",  apply: { view.apply(state: state([1,2,3,4], focus: 1), managing: true, now: vt) }, holdFrames: 18),
            Step(label: "focus->4",  apply: { view.apply(state: state([1,2,3,4], focus: 3), managing: true, now: vt) }, holdFrames: 18),
            Step(label: "open win5", apply: { view.apply(state: state([1,2,3,4,5], focus: 4), managing: true, now: vt) }, holdFrames: 20),
            Step(label: "widen #5",  apply: { view.apply(state: state([1,2,3,4,5], focus: 4, widths: [360,360,360,360,760]), managing: true, now: vt) }, holdFrames: 18),
            Step(label: "move #5<-", apply: { view.apply(state: state([1,2,3,5,4], focus: 3, widths: [360,360,360,760,360]), managing: true, now: vt) }, holdFrames: 18),
            Step(label: "close #3",  apply: { view.apply(state: state([1,2,5,4], focus: 2, widths: [360,360,760,360]), managing: true, now: vt) }, holdFrames: 20),
            Step(label: "workspace", apply: { view.animateWorkspaceSwitch(direction: 1) }, holdFrames: 24),
            Step(label: "release",   apply: { view.apply(state: state([], focus: 0), managing: false, now: vt) }, holdFrames: 18),
        ]

        var frames: [(label: String, image: NSImage)] = []
        for step in timeline {
            step.apply?()
            let snapAt = step.holdFrames / 3   // capture early, while motion is liveliest
            for f in 0..<step.holdFrames {
                view.advance(dt: dt, now: vt)
                vt += dt
                if f == snapAt {
                    if let img = snapshot(view: view, cellW: cellW, cellH: cellH) {
                        frames.append((step.label, img))
                    }
                }
            }
        }

        guard let sheet = composeContactSheet(frames: frames, cellW: cellW, cellH: cellH) else {
            print("render: failed to compose contact sheet")
            return false
        }
        guard let png = pngData(sheet) else {
            print("render: failed to encode PNG")
            return false
        }
        do {
            try png.write(to: URL(fileURLWithPath: outPath))
            print("render: wrote \(frames.count)-frame contact sheet to \(outPath)")
            return true
        } catch {
            print("render: write failed: \(error)")
            return false
        }
    }

    /// Render the view's current state into an offscreen bitmap, upscaled.
    private static func snapshot(view: MenuBarStripView, cellW: Int, cellH: Int) -> NSImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let small = rep.cgImage else { return nil }

        let img = NSImage(size: NSSize(width: cellW, height: cellH))
        img.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return nil }
        // Menu-bar-like dark backdrop so light strokes read.
        ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: cellW, height: cellH))
        ctx.interpolationQuality = .none
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: cellW, height: cellH))
        img.unlockFocus()
        return img
    }

    private static func composeContactSheet(frames: [(label: String, image: NSImage)],
                                            cellW: Int, cellH: Int) -> NSImage? {
        guard !frames.isEmpty else { return nil }
        let cols = 2
        let rows = (frames.count + cols - 1) / cols
        let pad = 10, labelH = 18
        let cw = cellW + pad * 2
        let ch = cellH + labelH + pad
        let sheet = NSImage(size: NSSize(width: cw * cols, height: ch * rows))
        sheet.lockFocus()
        NSColor(white: 0.18, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: cw * cols, height: ch * rows).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        for (i, frame) in frames.enumerated() {
            let col = i % cols
            let row = i / cols
            // Top-left origin layout (flip rows for AppKit's bottom-left).
            let x = col * cw + pad
            let yTop = row * ch
            let y = Int(sheet.size.height) - yTop - ch + pad
            frame.image.draw(in: NSRect(x: x, y: y + labelH, width: cellW, height: cellH))
            ("\(i): \(frame.label)" as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
        sheet.unlockFocus()
        return sheet
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
