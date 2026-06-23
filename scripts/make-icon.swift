// make-icon.swift - render the ScrollWM app icon at a given pixel size.
//
// Draws a macOS "squircle" tile (Big Sur+ proportions: ~80% of the canvas with
// transparent margin) containing a PaperWM-style strip: several gray columns
// with one accent-blue focused column and a viewport outline. This matches the
// menu-bar mini-map metaphor the app uses.
//
// Usage: swift make-icon.swift <pixelSize> <outPath.png>
import Cocoa

func makeIcon(size: Int) -> Data {
    let px = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("ctx") }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Tile geometry: ~81.5% of canvas, centered, squircle corners.
    let inset = px * 0.0925
    let tile = CGRect(x: inset, y: inset, width: px - 2 * inset, height: px - 2 * inset)
    let radius = tile.width * 0.2237
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Background gradient (deep indigo -> near-black).
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bgColors = [
        CGColor(red: 0.16, green: 0.18, blue: 0.30, alpha: 1.0),
        CGColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 1.0),
    ] as CFArray
    if let grad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
            start: CGPoint(x: tile.minX, y: tile.maxY),
            end: CGPoint(x: tile.maxX, y: tile.minY),
            options: [])
    }
    ctx.restoreGState()

    // Strip area inside the tile.
    let pad = tile.width * 0.135
    let strip = tile.insetBy(dx: pad, dy: pad * 1.18)

    // Columns: relative widths summing to a canvas wider than the strip so we
    // can show a viewport window over a subset (the "scroll" idea).
    // widths (in canvas units), focused index, gap.
    let widths: [CGFloat] = [0.62, 1.0, 0.46, 0.78, 0.55]
    let focused = 1
    let gapUnit: CGFloat = 0.14
    let totalUnits = widths.reduce(0, +) + gapUnit * CGFloat(widths.count - 1)
    // Scale so columns slightly overflow -> emphasises horizontal scroll.
    let unit = strip.width / (totalUnits * 0.86)
    let gap = gapUnit * unit
    let colRadius = unit * 0.12

    let gray = CGColor(red: 0.74, green: 0.78, blue: 0.86, alpha: 1.0)
    let grayDim = CGColor(red: 0.52, green: 0.56, blue: 0.66, alpha: 1.0)
    let accentTop = CGColor(red: 0.32, green: 0.62, blue: 1.0, alpha: 1.0)
    let accentBot = CGColor(red: 0.18, green: 0.45, blue: 0.95, alpha: 1.0)

    var x = strip.minX - unit * 0.32 // start slightly off the left edge
    let colHeights: [CGFloat] = [0.78, 1.0, 0.66, 0.88, 0.72]
    for (i, w) in widths.enumerated() {
        let cw = w * unit
        let ch = colHeights[i] * strip.height
        let cy = strip.minY + (strip.height - ch) / 2
        let rect = CGRect(x: x, y: cy, width: cw, height: ch)
        // Clip-draw only the portion within the strip bounds (scroll clipping).
        ctx.saveGState()
        ctx.clip(to: strip)
        let path = CGPath(roundedRect: rect, cornerWidth: colRadius, cornerHeight: colRadius, transform: nil)
        ctx.addPath(path)
        if i == focused {
            ctx.clip()
            if let grad = CGGradient(colorsSpace: cs, colors: [accentTop, accentBot] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(grad,
                    start: CGPoint(x: rect.minX, y: rect.maxY),
                    end: CGPoint(x: rect.minX, y: rect.minY),
                    options: [])
            }
        } else {
            ctx.addPath(path)
            ctx.clip()
            if let grad = CGGradient(colorsSpace: cs, colors: [gray, grayDim] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(grad,
                    start: CGPoint(x: rect.minX, y: rect.maxY),
                    end: CGPoint(x: rect.minX, y: rect.minY),
                    options: [])
            }
        }
        ctx.restoreGState()
        x += cw + gap
    }

    guard let img = ctx.makeImage() else { fatalError("img") }
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    return data
}

let args = CommandLine.arguments
guard args.count == 3, let size = Int(args[1]) else {
    FileHandle.standardError.write("usage: make-icon.swift <size> <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let data = makeIcon(size: size)
try data.write(to: URL(fileURLWithPath: args[2]))
