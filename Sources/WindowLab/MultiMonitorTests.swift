import Foundation

/// Aggregator for the multi-monitor swarm's pure-policy test lanes. Wired into
/// `WindowLab mmtest` (and `make test`) so every worker's tests run headlessly
/// in CI with no AX permission or real monitors.
///
/// Each worker owns ONE `*Tests.run()` below; this file only sums them, so it
/// rarely needs editing (coordinator-owned). Add a new lane here if the swarm
/// grows a new pure module.
enum MultiMonitorTests {
    static func run() -> Bool {
        var ok = true
        ok = IndicatorPlacementTests.run() && ok
        ok = FocusFollowsDisplayTests.run() && ok
        ok = AutoTilePolicyTests.run() && ok
        print(ok ? "\n[mmtest] ALL PASSED" : "\n[mmtest] FAILURES")
        return ok
    }
}
