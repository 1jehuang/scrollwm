import Foundation

/// A tiny, dependency-free semantic version used by the in-app updater to
/// decide whether a published GitHub release is newer than what's running.
///
/// Why hand-rolled: ScrollWM ships no third-party packages (see `Package.swift`)
/// and our versions are simple (`MAJOR.MINOR.PATCH` with an optional `-dev`
/// or other pre-release suffix). Keeping this PURE makes the "is this newer?"
/// decision unit-testable with no network and no AppKit (`WindowLab unittest`).
///
/// Ordering rules (a subset of semver.org, which is all we need):
///   - Compare numeric MAJOR, then MINOR, then PATCH.
///   - A version WITH a pre-release suffix (`0.2.0-dev`, `0.2.0-rc.1`) is LOWER
///     than the same version without one (`0.2.0`). This is what makes a local
///     `0.0.0-dev` build never out-rank a real release, and keeps an unfinished
///     `-dev` of the next version from being offered as "newer" than its final.
///   - Pre-release identifiers themselves compare lexically/numerically per the
///     spec, which is enough to order `rc.1` < `rc.2` deterministically.
struct SemVer: Equatable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// Dot-separated pre-release identifiers (empty for a normal release).
    let prerelease: [String]

    /// Parse `"v0.1.2"`, `"0.1.2"`, `"0.2.0-dev"`, `"1.0.0-rc.1"`, etc.
    /// A leading `v`/`V` and surrounding whitespace are tolerated. Missing
    /// minor/patch components default to 0 (`"1"` -> `1.0.0`). Returns nil only
    /// if there is no leading integer to anchor on.
    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        guard !s.isEmpty else { return nil }

        // Split off the pre-release (`-...`) and ignore any `+build` metadata.
        let noBuild = s.split(separator: "+", maxSplits: 1).first.map(String.init) ?? s
        let dashParts = noBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = String(dashParts[0])
        let pre = dashParts.count > 1 ? String(dashParts[1]) : ""

        let nums = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let maj = Int(nums.first ?? "") else { return nil }
        self.major = maj
        self.minor = nums.count > 1 ? (Int(nums[1]) ?? 0) : 0
        self.patch = nums.count > 2 ? (Int(nums[2]) ?? 0) : 0
        self.prerelease = pre.isEmpty
            ? []
            : pre.split(separator: ".").map(String.init)
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // Equal cores: a build WITH a pre-release is lower than one without.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false          // both final, equal
        case (true, false): return false         // lhs final > rhs pre-release
        case (false, true): return true          // lhs pre-release < rhs final
        case (false, false):
            return comparePrerelease(lhs.prerelease, rhs.prerelease) == .orderedAscending
        }
    }

    /// Spec-style pre-release comparison: numeric identifiers compare
    /// numerically, others lexically; a numeric id is always lower than a
    /// non-numeric one; a shorter run of equal identifiers is lower.
    private static func comparePrerelease(_ a: [String], _ b: [String]) -> ComparisonResult {
        for (x, y) in zip(a, b) {
            if x == y { continue }
            switch (Int(x), Int(y)) {
            case let (xi?, yi?): return xi < yi ? .orderedAscending : .orderedDescending
            case (_?, nil):      return .orderedAscending   // numeric < alphanumeric
            case (nil, _?):      return .orderedDescending
            case (nil, nil):     return x < y ? .orderedAscending : .orderedDescending
            }
        }
        if a.count == b.count { return .orderedSame }
        return a.count < b.count ? .orderedAscending : .orderedDescending
    }
}
