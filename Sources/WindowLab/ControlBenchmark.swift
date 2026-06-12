import Foundation
import ApplicationServices
import AppKit

/// Milestone 2: measure AX move/resize latency and reliability per window.
///
/// Safety: every mutated window is restored to its original frame afterwards.
enum ControlBenchmark {
    struct Result {
        let appName: String
        let title: String
        var moveLatenciesMs: [Double] = []
        var resizeLatenciesMs: [Double] = []
        var moveErrors: [AXError] = []
        var resizeErrors: [AXError] = []
        var verified: Bool = false
        var restored: Bool = false
    }

    /// Move/resize each candidate window by a small delta N times, verify, restore.
    static func run(
        matched: [MatchedWindow],
        iterations: Int = 5,
        maxWindows: Int = 8,
        recorder: LatencyRecorder
    ) -> [Result] {
        // Only standard, non-minimized, non-fullscreen windows of decent size.
        let candidates = matched.filter {
            $0.ax.subrole == kAXStandardWindowSubrole as String
                && !$0.ax.isMinimized
                && !$0.ax.isFullscreen
                && $0.ax.frame.width >= 200
                && $0.ax.frame.height >= 150
        }.prefix(maxWindows)

        var results: [Result] = []

        for window in candidates {
            let ax = window.ax
            var result = Result(appName: ax.appName, title: ax.title ?? "(untitled)")
            let originalFrame = ax.frame
            let element = ax.element
            AXSource.setTimeout(element, seconds: 0.1)

            // Move benchmark: jitter +8/-8 px.
            for i in 0..<iterations {
                let offset: CGFloat = (i % 2 == 0) ? 8 : -8
                let target = CGPoint(x: originalFrame.origin.x + offset, y: originalFrame.origin.y)
                let start = Clock.nowNs()
                let err = AXSource.setPoint(element, kAXPositionAttribute as String, target)
                let elapsed = Double(Clock.nowNs() - start) / 1_000_000.0
                if err == .success {
                    result.moveLatenciesMs.append(elapsed)
                    recorder.record("ax.move", ms: elapsed)
                } else {
                    result.moveErrors.append(err)
                }
            }

            // Resize benchmark: jitter width +8/-8 px.
            for i in 0..<iterations {
                let offset: CGFloat = (i % 2 == 0) ? 8 : -8
                let target = CGSize(width: originalFrame.width + offset, height: originalFrame.height)
                let start = Clock.nowNs()
                let err = AXSource.setSize(element, kAXSizeAttribute as String, target)
                let elapsed = Double(Clock.nowNs() - start) / 1_000_000.0
                if err == .success {
                    result.resizeLatenciesMs.append(elapsed)
                    recorder.record("ax.resize", ms: elapsed)
                } else {
                    result.resizeErrors.append(err)
                }
            }

            // Restore original frame (position then size), then verify.
            let restorePos = AXSource.setPoint(element, kAXPositionAttribute as String, originalFrame.origin)
            let restoreSize = AXSource.setSize(element, kAXSizeAttribute as String, originalFrame.size)
            result.restored = (restorePos == .success && restoreSize == .success)

            // Read back: did the window actually end up where we put it?
            if let pos = AXSource.copyPoint(element, kAXPositionAttribute as String),
               let size = AXSource.copySize(element, kAXSizeAttribute as String) {
                let posOK = abs(pos.x - originalFrame.origin.x) <= 2 && abs(pos.y - originalFrame.origin.y) <= 2
                let sizeOK = abs(size.width - originalFrame.width) <= 2 && abs(size.height - originalFrame.height) <= 2
                result.verified = posOK && sizeOK
            }

            results.append(result)
        }

        return results
    }

    static func printReport(_ results: [Result]) {
        print("\n== AX control benchmark (per window) ==")
        print(String(
            format: "  %-22@ %-30@ %10@ %12@ %8@ %8@",
            "app" as NSString, "title" as NSString,
            "move p50" as NSString, "resize p50" as NSString,
            "ok?" as NSString, "restored" as NSString
        ))
        for r in results {
            let movP50 = LatencyStats(label: "", samples: r.moveLatenciesMs).percentile(50)
            let rszP50 = LatencyStats(label: "", samples: r.resizeLatenciesMs).percentile(50)
            let errs = (r.moveErrors + r.resizeErrors).map { axErrorName($0) }
            let status = errs.isEmpty ? (r.verified ? "yes" : "DRIFT") : errs.joined(separator: ",")
            print(String(
                format: "  %-22@ %-30@ %8.2fms %10.2fms %8@ %8@",
                String(r.appName.prefix(22)) as NSString,
                String(r.title.prefix(30)) as NSString,
                movP50, rszP50,
                status as NSString,
                (r.restored ? "yes" : "NO") as NSString
            ))
        }
    }
}
