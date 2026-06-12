import Foundation
import AppKit

/// `WindowLab testwindow <x> <y> <w> <h> <title>` opens one plain window and
/// runs until killed. scrollbench spawns N of these as child processes to get
/// realistic cross-process AX targets without touching the user's real apps.
func runTestWindow(args: [String]) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let x = Double(args.count > 0 ? args[0] : "100") ?? 100
    let y = Double(args.count > 1 ? args[1] : "100") ?? 100
    let w = Double(args.count > 2 ? args[2] : "400") ?? 400
    let h = Double(args.count > 3 ? args[3] : "300") ?? 300
    let title = args.count > 4 ? args[4] : "TestWindow"

    let window = NSWindow(
        contentRect: NSRect(x: x, y: y, width: w, height: h),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = title
    let hue = CGFloat(abs(title.hashValue % 100)) / 100.0
    window.backgroundColor = NSColor(hue: hue, saturation: 0.5, brightness: 0.8, alpha: 1.0)
    window.orderFrontRegardless()

    app.run()
}

/// Spawn N test windows as child processes; returns Process handles.
/// Windows are tiled across the screen.
func spawnTestWindows(count: Int) -> [Process] {
    guard let exe = Bundle.main.executablePath ?? CommandLine.arguments.first else { return [] }
    let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1470, height: 956)

    var processes: [Process] = []
    let cols = 4
    let w = 320.0, h = 240.0
    for i in 0..<count {
        let col = i % cols
        let row = i / cols
        let x = 40.0 + Double(col) * (w + 20)
        // NSWindow y is bottom-left origin.
        let y = screen.height - 120.0 - Double(row) * (h + 30) - h

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["testwindow", "\(x)", "\(y)", "\(w)", "\(h)", "ScrollBench-\(i)"]
        try? p.run()
        processes.append(p)
    }
    return processes
}
