import Foundation

/// Millisecond-resolution latency statistics over a set of samples.
struct LatencyStats {
    let label: String
    let samples: [Double] // milliseconds

    var count: Int { samples.count }
    var mean: Double { samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count) }
    var min: Double { samples.min() ?? 0 }
    var max: Double { samples.max() ?? 0 }

    func percentile(_ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let rank = p / 100.0 * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Swift.min(lo + 1, sorted.count - 1)
        let frac = rank - Double(lo)
        return sorted[lo] * (1 - frac) + sorted[hi] * frac
    }

    var summaryRow: String {
        String(
            format: "%-38@ n=%-5d mean=%7.3f  p50=%7.3f  p95=%7.3f  p99=%7.3f  min=%7.3f  max=%8.3f ms",
            label as NSString, count, mean, percentile(50), percentile(95), percentile(99), min, max
        )
    }
}

/// High-resolution timer based on mach continuous time.
enum Clock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nowNs() -> UInt64 {
        let t = mach_continuous_time()
        return t * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    /// mach_absolute_time in ns. CGEvent.timestamp uses this timebase,
    /// so input-age math must use this clock, not the continuous one.
    static func nowAbsNs() -> UInt64 {
        let t = mach_absolute_time()
        return t * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    /// Run `block`, return elapsed milliseconds.
    @discardableResult
    static func measureMs(_ block: () -> Void) -> Double {
        let start = nowNs()
        block()
        let end = nowNs()
        return Double(end - start) / 1_000_000.0
    }
}

/// Collects named latency samples.
final class LatencyRecorder {
    private var buckets: [String: [Double]] = [:]
    private var order: [String] = []

    func record(_ label: String, ms: Double) {
        if buckets[label] == nil { order.append(label) }
        buckets[label, default: []].append(ms)
    }

    func measure<T>(_ label: String, _ block: () throws -> T) rethrows -> T {
        let start = Clock.nowNs()
        let result = try block()
        let end = Clock.nowNs()
        record(label, ms: Double(end - start) / 1_000_000.0)
        return result
    }

    func stats() -> [LatencyStats] {
        order.map { LatencyStats(label: $0, samples: buckets[$0] ?? []) }
    }

    func printSummary(title: String) {
        print("\n== \(title) ==")
        for s in stats() {
            print("  " + s.summaryRow)
        }
    }
}
