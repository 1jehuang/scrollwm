import Foundation
import ApplicationServices
import AppKit

/// `WindowLab sizeprobe [targetWidth]` — empirical check of how real native
/// macOS apps respond to an Accessibility `setSize` request.
///
/// ScrollWM does NOT resize windows on spawn today (adopt/insert store the
/// native frame), so a "suggested column width" only ever lands when the user
/// presses a width key. The recurring complaint is that "native apps don't
/// spawn at the suggested size": many AppKit/Catalyst apps silently CLAMP a
/// resize to their own `contentMinSize` while STILL returning `.success`, or
/// snap to size increments (terminals), or apply the new size asynchronously so
/// the immediate read-back is stale.
///
/// This probe quantifies that per app, reversibly:
///   1. record the window's original frame,
///   2. request `targetWidth` (default a typical 25% column),
///   3. read back IMMEDIATELY and again after a short settle,
///   4. classify: honored / clamped-to-minimum / increment-rounded / ignored,
///   5. restore the original frame and verify.
///
/// Every window is put back before the next one is touched, so running it
/// leaves the desktop exactly as it was (same risk profile as `bench`).
enum SizeProbe {
    struct Outcome {
        let app: String
        let title: String
        let original: CGSize
        let requested: CGFloat
        let immediate: CGSize
        let settled: CGSize
        let restored: Bool
    }

    /// How a window reacted to the resize request.
    enum Verdict: String {
        case honored        // settled width within tolerance of requested
        case clampedWider   // app refused to shrink; settled wider than requested
        case asyncSettled   // immediate read-back lied; settled value differs
        case grewOrMoved    // ended up larger than original (unexpected)
        case ignored        // size did not change at all
    }

    static func classify(_ o: Outcome, tolerance: CGFloat = 4) -> Verdict {
        let reqDelta = abs(o.settled.width - o.requested)
        if reqDelta <= tolerance { return .honored }
        if abs(o.settled.width - o.original.width) <= tolerance { return .ignored }
        if abs(o.immediate.width - o.settled.width) > tolerance { return .asyncSettled }
        if o.settled.width > o.requested + tolerance {
            return o.settled.width > o.original.width + tolerance ? .grewOrMoved : .clampedWider
        }
        return .grewOrMoved
    }

    static func run(targetWidth: CGFloat, settleSeconds: Double = 0.18) {
        guard AXSource.isTrusted else {
            print("sizeprobe: needs Accessibility permission. Grant it and re-run.")
            exit(2)
        }
        let cg = CGWindowSource.listWindows(onscreenOnly: true)
        let ax = AXSource.allWindows()
        let matched = IdentityMatcher.match(axWindows: ax, cgWindows: cg)

        // Only real, on-screen, standard windows of a non-trivial size; skip our
        // own process so the probe never resizes the menu-bar agent.
        let selfPID = getpid()
        let candidates = matched.filter {
            $0.cg != nil
                && $0.ax.pid != selfPID
                && $0.ax.subrole == kAXStandardWindowSubrole as String
                && !$0.ax.isMinimized && !$0.ax.isFullscreen
                && $0.ax.frame.width >= 120 && $0.ax.frame.height >= 80
        }

        print("sizeprobe: requesting width \(Int(targetWidth))px on \(candidates.count) live window(s).")
        print("           every window is restored immediately after measurement.\n")
        print(String(format: "  %-20@ %-26@ %7@ %7@ %7@ %7@  %@",
                     "app" as NSString, "title" as NSString,
                     "orig" as NSString, "req" as NSString,
                     "now" as NSString, "settled" as NSString, "verdict" as NSString))

        var outcomes: [Outcome] = []
        for m in candidates {
            let el = m.ax.element
            AXSource.setTimeout(el, seconds: 0.2)
            let original = m.ax.frame.size

            // Keep height; only the column width is what the strip cares about.
            let target = CGSize(width: targetWidth, height: original.height)
            _ = AXSource.setSize(el, kAXSizeAttribute as String, target)
            let immediate = AXSource.copySize(el, kAXSizeAttribute as String) ?? original
            Thread.sleep(forTimeInterval: settleSeconds)
            let settled = AXSource.copySize(el, kAXSizeAttribute as String) ?? immediate

            // Restore immediately and verify before moving on. Some apps (e.g.
            // terminals that snap to whole character cells) won't land on the
            // exact original from a single shrink, so retry a few times, briefly
            // overshooting larger to force a re-flow back onto the original cell.
            var back = original
            var restored = false
            for attempt in 0..<4 {
                if attempt > 0 {
                    // Overshoot wider, then request the original again: a terminal
                    // resists shrinking onto a smaller cell unless nudged.
                    _ = AXSource.setSize(el, kAXSizeAttribute as String,
                                         CGSize(width: original.width + 80, height: original.height))
                    Thread.sleep(forTimeInterval: 0.08)
                }
                _ = AXSource.setSize(el, kAXSizeAttribute as String, original)
                Thread.sleep(forTimeInterval: 0.06)
                back = AXSource.copySize(el, kAXSizeAttribute as String) ?? .zero
                if abs(back.width - original.width) <= 2 && abs(back.height - original.height) <= 2 {
                    restored = true
                    break
                }
            }

            let o = Outcome(app: m.ax.appName, title: m.ax.title ?? "(untitled)",
                            original: original, requested: targetWidth,
                            immediate: immediate, settled: settled, restored: restored)
            outcomes.append(o)
            print(String(format: "  %-20@ %-26@ %6.0f  %6.0f  %6.0f  %6.0f  %@%@",
                         String(o.app.prefix(20)) as NSString,
                         String(o.title.prefix(26)) as NSString,
                         original.width, targetWidth, immediate.width, settled.width,
                         classify(o).rawValue as NSString,
                         (restored ? "" : "  !! NOT RESTORED") as NSString))
        }

        // Summary by verdict.
        var counts: [Verdict: Int] = [:]
        for o in outcomes { counts[classify(o), default: 0] += 1 }
        print("\n== summary ==")
        let order: [Verdict] = [.honored, .clampedWider, .asyncSettled, .grewOrMoved, .ignored]
        for v in order where (counts[v] ?? 0) > 0 {
            print(String(format: "  %-13@ %d", v.rawValue as NSString, counts[v] ?? 0))
        }
        let clampers = outcomes.filter { classify($0) == .clampedWider }
        if !clampers.isEmpty {
            print("\nApps that refused to shrink to \(Int(targetWidth))px (their minimum width):")
            for o in clampers.sorted(by: { $0.settled.width < $1.settled.width }) {
                print(String(format: "  %-20@ min ≈ %.0fpx", String(o.app.prefix(20)) as NSString, o.settled.width))
            }
        }
        let unrestored = outcomes.filter { !$0.restored }
        if !unrestored.isEmpty {
            print("\nWARNING: \(unrestored.count) window(s) may not be fully restored:")
            for o in unrestored { print("  - \(o.app): \(o.title)") }
        }
    }
}
