import Foundation

/// PURE decision logic for the updater's "should I, and how?" questions, split
/// out from the side-effecting `Updater`/`UpdateCoordinator` so it is unit
/// tested with no network, AppKit, or filesystem (`WindowLab unittest`).
///
/// The coordinator owns timing and IO; this owns the policy that keeps a silent
/// auto-update from being brittle: don't loop on a failing version, don't yank
/// the strip out from under an active user, and be honest about a grant that
/// won't survive.
enum UpdatePolicy {

    /// Persisted, per-version attempt record so a silently-failing install can
    /// never become an infinite check -> install -> relaunch loop.
    struct AttemptRecord: Codable, Equatable {
        var version: String
        var count: Int
    }

    /// How many times we will AUTO-install a given version before giving up and
    /// falling back to a one-time notice. (Manual "Install" is never blocked.)
    static let maxAutoAttempts = 2

    /// Should the automatic path try to install `candidate` right now?
    ///
    /// - `available`: the newer version string the check found.
    /// - `lastAttempt`: persisted record of prior auto-install attempts.
    /// - `skipped`: a version the user explicitly chose to skip.
    /// Returns false when we've exhausted attempts for this version (so a broken
    /// release can't loop) or the user skipped it.
    static func shouldAutoInstall(available: String,
                                  lastAttempt: AttemptRecord?,
                                  skipped: String?) -> Bool {
        if skipped == available { return false }
        if let a = lastAttempt, a.version == available, a.count >= maxAutoAttempts {
            return false
        }
        return true
    }

    /// Update the attempt record for a fresh auto-install attempt at `version`.
    /// Resets the count when the version changes (a new release deserves its own
    /// budget).
    static func recordingAttempt(_ prior: AttemptRecord?, version: String) -> AttemptRecord {
        if let p = prior, p.version == version {
            return AttemptRecord(version: version, count: p.count + 1)
        }
        return AttemptRecord(version: version, count: 1)
    }

    /// When should a verified, staged update actually be applied (swap +
    /// relaunch)? Applying immediately while the user is actively managing
    /// windows would discard their arranged strip, so we defer that case until
    /// the app next quits.
    enum ApplyTiming: Equatable {
        /// Safe to swap + relaunch now (app is dormant: nothing to disrupt).
        case now
        /// Stage it and apply on the next quit, so we don't destroy the live
        /// layout mid-session.
        case onQuit
    }

    /// Decide apply timing. `isManaging` = the strip currently holds the user's
    /// windows. `automatic` = silent mode (the only mode that defers; a manual
    /// "Install & Relaunch" click is an explicit request to do it now).
    static func applyTiming(isManaging: Bool, automatic: Bool) -> ApplyTiming {
        if !automatic { return .now }          // user clicked Install: honor it
        return isManaging ? .onQuit : .now
    }

    /// After a relaunch following an attempted install, did the version
    /// actually advance to (at least) what we were installing? Used to detect a
    /// silently-failed swap so we can stop retrying and tell the user.
    static func installSucceeded(attempted: String, runningNow: String) -> Bool {
        guard let want = SemVer(attempted), let have = SemVer(runningNow) else {
            return attempted == runningNow
        }
        return have >= want
    }

    /// Classify an install destination for pre-flight. Mirrors the brittleness
    /// the audits flagged: a Homebrew-cask install must NOT be clobbered (it
    /// desyncs brew), and a non-writable destination (e.g. /Applications for a
    /// standard user) must not enter the install/relaunch cycle.
    enum InstallTarget: Equatable {
        case selfUpdatable          // our own ~/Applications-style install: go
        case homebrewManaged        // installed by `brew install --cask`: defer to brew
        case notWritable            // can't write the bundle: tell the user
        case notAppBundle           // dev binary: never self-replace
    }

    /// Pure classifier. `isAppBundle` from the bundle path; `bundlePath` the
    /// installed `.app`; `parentWritable` from an access(W_OK) probe;
    /// `brewPrefixes` the Homebrew prefixes to test containment against
    /// (e.g. ["/opt/homebrew", "/usr/local"]).
    static func classifyTarget(isAppBundle: Bool,
                               bundlePath: String,
                               parentWritable: Bool,
                               brewPrefixes: [String]) -> InstallTarget {
        if !isAppBundle { return .notAppBundle }
        for prefix in brewPrefixes where !prefix.isEmpty {
            // A cask `app` artifact is copied to /Applications, but Caskroom
            // metadata lives under <prefix>/Caskroom. We treat a bundle living
            // UNDER a brew prefix (e.g. a symlinked/Caskroom-staged install) as
            // brew-managed; the common /Applications copy is detected by the
            // coordinator via a Caskroom receipt probe (impure) instead.
            if AppLocation.isUnder(bundlePath, dir: prefix + "/Caskroom")
                || AppLocation.isUnder(bundlePath, dir: prefix + "/Cellar") {
                return .homebrewManaged
            }
        }
        if !parentWritable { return .notWritable }
        return .selfUpdatable
    }
}
