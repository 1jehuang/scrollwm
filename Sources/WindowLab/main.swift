import Foundation
import AppKit

// WindowLab: reality-test harness for the scrolling window manager.
//
// Subcommands:
//   probe    - Milestone 1: enumerate CG + AX windows, match identities, report latency
//   bench    - Milestone 2: AX move/resize benchmark (restores all windows afterwards)
//   watch    - repeated probe loop, prints timing each second (for stability testing)

func runProbe(verbose: Bool) {
    let recorder = LatencyRecorder()

    // CG enumeration (repeat to get stable latency numbers).
    var cgWindows: [CGWindowInfo] = []
    for _ in 0..<10 {
        cgWindows = recorder.measure("cg.listWindows.onscreen") {
            CGWindowSource.listWindows(onscreenOnly: true)
        }
    }
    let manageable = cgWindows.filter { $0.looksManageable }

    print("CG windows: \(cgWindows.count) total, \(manageable.count) look manageable")

    let cgTitlesVisible = manageable.contains { ($0.title?.isEmpty == false) }
    if !cgTitlesVisible {
        print("note: CG window titles are empty -> Screen Recording permission not granted (matching uses PID+frame only)")
    }

    // AX enumeration.
    guard AXSource.isTrusted else {
        print("\nAX: NOT TRUSTED. Grant Accessibility permission to this binary, then re-run.")
        print("   System Settings -> Privacy & Security -> Accessibility")
        _ = AXSource.promptForTrustIfNeeded()
        exit(2)
    }

    let axWindows = recorder.measure("ax.allWindows.total") {
        AXSource.allWindows(recorder: recorder)
    }
    print("AX windows: \(axWindows.count) across regular apps")

    // Identity matching.
    let matched = recorder.measure("match.ax-cg") {
        IdentityMatcher.match(axWindows: axWindows, cgWindows: cgWindows)
    }
    let matchedCount = matched.filter { $0.cg != nil }.count
    print("Matched: \(matchedCount)/\(matched.count) AX windows fused to CG windows")

    if verbose {
        print("\n== Window table ==")
        for m in matched {
            let cgID = m.cg.map { String($0.windowID) } ?? "-"
            let flags = [
                m.ax.isMinimized ? "min" : nil,
                m.ax.isFullscreen ? "fs" : nil,
                m.ax.subrole == kAXStandardWindowSubrole as String ? nil : (m.ax.subrole ?? "?")
            ].compactMap { $0 }.joined(separator: ",")
            print(String(
                format: "  %-20@ cg=%-8@ score=%-3d  %4.0fx%-4.0f @ (%5.0f,%5.0f)  %@ %@",
                String(m.ax.appName.prefix(20)) as NSString,
                cgID as NSString,
                m.matchScore,
                m.ax.frame.width, m.ax.frame.height,
                m.ax.frame.origin.x, m.ax.frame.origin.y,
                String((m.ax.title ?? "").prefix(40)) as NSString,
                flags.isEmpty ? "" : "[\(flags)]" as NSString
            ))
        }
    }

    recorder.printSummary(title: "Latency")
}

func runBench() {
    guard AXSource.isTrusted else {
        print("AX: NOT TRUSTED. Grant Accessibility permission first (run `probe`).")
        exit(2)
    }
    let recorder = LatencyRecorder()
    let cgWindows = CGWindowSource.listWindows(onscreenOnly: true)
    let axWindows = AXSource.allWindows()
    let matched = IdentityMatcher.match(axWindows: axWindows, cgWindows: cgWindows)

    print("Benchmarking AX move/resize on up to 8 standard windows (5 iterations each).")
    print("All windows will be restored to their original frames.")
    let results = ControlBenchmark.run(matched: matched, recorder: recorder)
    ControlBenchmark.printReport(results)
    recorder.printSummary(title: "Aggregate control latency")

    let unrestored = results.filter { !$0.restored }
    if !unrestored.isEmpty {
        print("\nWARNING: \(unrestored.count) window(s) may not be fully restored:")
        for r in unrestored { print("  - \(r.appName): \(r.title)") }
    }
}

func runWatch(seconds: Int) {
    guard AXSource.isTrusted else {
        print("AX: NOT TRUSTED. Grant Accessibility permission first (run `probe`).")
        exit(2)
    }
    print("Watching for \(seconds)s: full CG+AX resync every second...")
    let recorder = LatencyRecorder()
    for i in 0..<seconds {
        let cycleStart = Clock.nowNs()
        let cg = CGWindowSource.listWindows(onscreenOnly: true)
        let ax = AXSource.allWindows()
        let matched = IdentityMatcher.match(axWindows: ax, cgWindows: cg)
        let elapsed = Double(Clock.nowNs() - cycleStart) / 1_000_000.0
        recorder.record("resync.full", ms: elapsed)
        let matchedCount = matched.filter { $0.cg != nil }.count
        print(String(format: "  [%2ds] resync %6.1f ms  cg=%d ax=%d matched=%d",
                     i + 1, elapsed, cg.count, ax.count, matchedCount))
        Thread.sleep(forTimeInterval: max(0, 1.0 - elapsed / 1000.0))
    }
    recorder.printSummary(title: "Resync latency")
}

// MARK: - Entry point

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "probe"

switch command {
case "probe":
    runProbe(verbose: args.contains("-v") || args.contains("--verbose"))
case "bench":
    runBench()
case "watch":
    let seconds = args.dropFirst().compactMap { Int($0) }.first ?? 10
    runWatch(seconds: seconds)
default:
    print("""
    WindowLab - scrolling window manager reality-test harness

    usage:
      WindowLab probe [-v]     enumerate CG+AX windows, match, report latency
      WindowLab bench          AX move/resize benchmark (windows restored after)
      WindowLab watch [secs]   repeated full resync loop with timing
    """)
}
