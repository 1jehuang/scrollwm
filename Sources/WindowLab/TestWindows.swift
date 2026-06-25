import Foundation
import AppKit

/// `WindowLab testwindow <x> <y> <w> <h> <title> [minW] [minH]` opens one
/// plain window and runs until killed. scrollbench spawns N of these as child
/// processes to get realistic cross-process AX targets without touching the
/// user's real apps. The optional `minW`/`minH` set a hard `contentMinSize`,
/// which lets us reproduce apps (e.g. Apple Music) that refuse to shrink past
/// their minimum.
func runTestWindow(args: [String]) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let x = Double(args.count > 0 ? args[0] : "100") ?? 100
    let y = Double(args.count > 1 ? args[1] : "100") ?? 100
    let w = Double(args.count > 2 ? args[2] : "400") ?? 400
    let h = Double(args.count > 3 ? args[3] : "300") ?? 300
    let title = args.count > 4 ? args[4] : "TestWindow"
    let minW = args.count > 5 ? Double(args[5]) : nil
    let minH = args.count > 6 ? Double(args[6]) : nil

    let window = NSWindow(
        contentRect: NSRect(x: x, y: y, width: w, height: h),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = title
    if let minW, let minH {
        window.contentMinSize = NSSize(width: minW, height: minH)
    }
    let hue = CGFloat(abs(title.hashValue % 100)) / 100.0
    window.backgroundColor = NSColor(hue: hue, saturation: 0.5, brightness: 0.8, alpha: 1.0)
    window.orderFrontRegardless()

    // SIGUSR1 -> open a SECOND window in THIS already-running process. This lets
    // the spawn-latency test model the common case ("open another window in an
    // app the strip already observes") rather than a brand-new app launch.
    var extraWindows: [NSWindow] = [] // retain so they are not deallocated
    signal(SIGUSR1, SIG_IGN)
    let sigSrc = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    sigSrc.setEventHandler {
        let extra = NSWindow(
            contentRect: NSRect(x: x + 60, y: y - 60, width: w, height: h),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        extra.title = "\(title)-2"
        extra.backgroundColor = NSColor(hue: hue, saturation: 0.6, brightness: 0.7, alpha: 1.0)
        extra.orderFrontRegardless()
        extraWindows.append(extra)
    }
    sigSrc.resume()

    // SIGUSR2 -> close the most-recently-opened extra window WITHOUT exiting the
    // process, so the close-latency test exercises the kAXUIElementDestroyed
    // observer (not app termination).
    signal(SIGUSR2, SIG_IGN)
    let sigSrc2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
    sigSrc2.setEventHandler {
        guard let last = extraWindows.popLast() else { return }
        last.close()
    }
    sigSrc2.resume()

    app.run()
}

/// Resolve a 0-based display index to an `NSScreen`, ordered LEFT-to-RIGHT by
/// AppKit X then top-to-bottom by Y, so `--display 0` is the leftmost monitor
/// regardless of which one macOS calls "main". Returns nil for an out-of-range
/// index (caller falls back to the default display).
func displayForIndex(_ index: Int) -> NSScreen? {
    let ordered = NSScreen.screens.sorted {
        $0.frame.origin.x != $1.frame.origin.x
            ? $0.frame.origin.x < $1.frame.origin.x
            : $0.frame.origin.y < $1.frame.origin.y
    }
    return ordered.indices.contains(index) ? ordered[index] : nil
}

/// One tiled test-window placement (AppKit coords, bottom-left origin).
struct TestWindowTile: Equatable {
    var x, y, width, height: Double
}

/// PURE tiling math for `spawnTestWindows`: lay `count` windows out as a grid on
/// `displayFrame` (the target display's AppKit frame, bottom-left origin). Kept
/// pure (no AppKit/Process) so the multi-display origin offset is unit-testable
/// without spawning anything: every tile is anchored to the display's OWN
/// origin, so a monitor placed left of / above the primary (negative origin)
/// gets windows on ITS surface, not the primary's. For the primary display
/// (origin (0,0)) this reduces to the original single-display layout exactly.
func testWindowTiles(count: Int, displayFrame f: CGRect,
                     cols: Int = 4, width: Double = 320, height: Double = 240) -> [TestWindowTile] {
    (0..<max(0, count)).map { i in
        let col = i % cols
        let row = i / cols
        let x = Double(f.origin.x) + 40.0 + Double(col) * (width + 20)
        // NSWindow y is bottom-left origin; offset by the display's own origin.
        let y = Double(f.origin.y) + Double(f.height) - 120.0 - Double(row) * (height + 30) - height
        return TestWindowTile(x: x, y: y, width: width, height: height)
    }
}

/// Spawn N test windows as child processes; returns Process handles.
/// Windows are tiled across the target screen.
///
/// `onDisplay` chooses WHICH monitor to tile the windows on. When nil (the
/// default) it targets `NSScreen.main`, so existing callers are byte-for-byte
/// unchanged on a single-display setup. Passing a non-primary screen honors that
/// display's AppKit origin (which can be negative in X and/or Y for a monitor
/// placed left of / above the built-in panel), so the disposable windows land
/// ON the external monitor — exactly what the multi-display `displaytest` and
/// `sandbox --display N` need to exercise cross-display behavior live.
func spawnTestWindows(count: Int, onDisplay screen: NSScreen? = nil) -> [Process] {
    guard let exe = Bundle.main.executablePath ?? CommandLine.arguments.first else { return [] }
    // AppKit frame of the target display (bottom-left origin, Y up). The default
    // (main) display reduces to origin (0,0), preserving the old layout exactly.
    let frame = (screen ?? NSScreen.main)?.frame ?? CGRect(x: 0, y: 0, width: 1470, height: 956)

    var processes: [Process] = []
    for (i, t) in testWindowTiles(count: count, displayFrame: frame).enumerated() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["testwindow", "\(t.x)", "\(t.y)", "\(t.width)", "\(t.height)", "ScrollBench-\(i)"]
        do {
            try p.run()
        } catch {
            FileHandle.standardError.write("spawnTestWindows: failed to launch '\(exe)': \(error)\n".data(using: .utf8)!)
        }
        processes.append(p)
    }
    return processes
}

/// Spawn a single test window with a hard `contentMinSize` (mimics apps like
/// Apple Music that refuse to shrink below a minimum). Used by the integration
/// test to verify the strip model tracks the real clamped width.
func spawnTestWindowWithMin(width: Double, height: Double, minWidth: Double, minHeight: Double = 200, title: String = "MinWidthApp") -> Process {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1470, height: 956)
    let x = 60.0
    let y = screen.height - 120.0 - height
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = ["testwindow", "\(x)", "\(y)", "\(width)", "\(height)", title, "\(minWidth)", "\(minHeight)"]
    try? p.run()
    return p
}
