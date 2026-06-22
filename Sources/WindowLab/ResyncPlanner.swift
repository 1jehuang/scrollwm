import Foundation

/// Pure resync policy: given what the strip currently manages, what the
/// Accessibility API reports, and which windows live on the *current* Space,
/// decide what to adopt/drop this cycle.
///
/// Factored out of `LifecycleMonitor` so the Space-awareness rules are
/// unit-testable without Accessibility permission or real windows. Identities
/// are opaque integer tokens here; the monitor maps real AXUIElements to tokens
/// (via CFEqual) before calling `decide`.
///
/// ## Why this exists (the Spaces bug)
///
/// `arrange` only adopts windows on the current Space (it intersects AX windows
/// with the WindowServer's on-screen list). But the periodic resync used to
/// enumerate AX windows *across all Spaces* and treat any it had not seen as
/// "new", so:
///   - windows living on other Spaces got sucked into the strip, and
///   - focusing such a window called `app.activate()`, yanking the user to a
///     different Space unexpectedly.
///
/// The fix: scope adoption to the current Space, and freeze entirely while the
/// user is viewing a Space other than the one the strip was built on.
enum ResyncPlanner {

    /// What the monitor should do this cycle.
    enum Decision: Equatable {
        /// The user is on a different Space than the strip (none of the managed
        /// windows are on the current Space). Do nothing: the strip "belongs" to
        /// its origin Space and resumes when the user returns.
        case frozenDifferentSpace
        /// Accessibility looks degraded (lock-screen edge, WindowServer hiccup):
        /// most of the strip vanished from AX at once. Skip and let a later
        /// healthy cycle converge, rather than mass-removing real windows.
        case skipDegraded
        /// Apply these changes: drop `remove` (closed windows) and adopt `add`
        /// (new windows on the current Space). Either may be empty.
        case apply(remove: [Int], add: [Int])
    }

    /// - Parameters:
    ///   - stripIDs: identity tokens of windows the strip currently manages,
    ///               in strip order.
    ///   - axIDs: tokens of all standard windows Accessibility reports right
    ///            now (across every Space), in enumeration order.
    ///   - currentSpaceIDs: tokens of windows the WindowServer reports as
    ///                      on-screen, i.e. on the Space the user is viewing.
    static func decide(stripIDs: [Int], axIDs: [Int], currentSpaceIDs: Set<Int>) -> Decision {
        let axSet = Set(axIDs)

        // 1. Space freeze. If the windows we manage still EXIST in Accessibility
        // (so they were not closed) but none are on the current Space, the user
        // has switched Spaces. Adopting here would pull the new Space's windows
        // into a strip laid out for a different Space (and focusing them could
        // teleport the user around), so stay inert. Windows that are simply gone
        // from AX (closed) do not count toward "still present", so a strip whose
        // windows were all closed falls through to normal removal below.
        let stripPresentInAX = stripIDs.filter { axSet.contains($0) }
        if !stripPresentInAX.isEmpty
            && !stripPresentInAX.contains(where: { currentSpaceIDs.contains($0) }) {
            return .frozenDifferentSpace
        }

        let missing = stripIDs.reduce(into: 0) { count, id in
            if !axSet.contains(id) { count += 1 }
        }

        // 2. Degradation guard. If AX suddenly reports most of a non-trivial
        // strip gone, that is far more likely AX degradation than the user
        // really closing everything at once. Skip this cycle.
        if stripIDs.count >= 4 && missing * 2 > stripIDs.count {
            return .skipDegraded
        }

        let stripSet = Set(stripIDs)
        // Removals: managed windows AX no longer reports at all. A window merely
        // on another Space still appears in AX, so it is NOT removed.
        let remove = stripIDs.filter { !axSet.contains($0) }
        // Additions: standard windows we do not manage yet AND that live on the
        // current Space. This mirrors `arrange`'s current-Space scoping and is
        // the heart of the fix: cross-Space windows are never adopted.
        let add = axIDs.filter { !stripSet.contains($0) && currentSpaceIDs.contains($0) }
        return .apply(remove: remove, add: add)
    }
}
