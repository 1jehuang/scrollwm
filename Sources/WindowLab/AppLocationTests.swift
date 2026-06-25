import Foundation

/// Lane A unit tests: launch-location classification (`AppLocation`) and the
/// pure relocation policy (`AppRelocation`).
///
/// These are HEADLESS and SAFE: every function under test is pure (no
/// filesystem, AppKit, TCC, or window access), so this never touches the user's
/// real machine. The coordinator wires `AppLocationTests.run()` into the
/// `unittest`/`headlesstest` runner.
///
/// Coverage goal: `AppLocation.classify` is TOTAL — every real-world launch
/// path lands in exactly one bucket — and every behavioral branch of
/// `AppRelocation` has a dedicated assertion.
enum AppLocationTests {

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        let home = "/Users/tester"
        func loc(_ path: String, app: Bool = true, home h: String = home) -> AppLocation.Kind {
            AppLocation.classify(bundlePath: path, isAppBundle: app, homeDir: h)
        }

        // MARK: - devBinary (the dev/CLI workflow)
        check("classify: non-.app bare binary -> devBinary",
              loc("/Users/tester/scrollwm/.build/debug/WindowLab", app: false) == .devBinary)
        check("classify: even an install-path bare binary is devBinary",
              loc("/Applications/WindowLab", app: false) == .devBinary)

        // MARK: - translocated (Gatekeeper ghost; grant can NEVER stick)
        check("classify: AppTranslocation ghost -> translocated",
              loc("/private/var/folders/aa/bb/X/d/AppTranslocation/UUID/d/ScrollWM.app") == .translocated)
        check("classify: translocation wins over the /var/folders temp heuristic",
              loc("/var/folders/aa/bb/AppTranslocation/UUID/d/ScrollWM.app") == .translocated)
        check("classify: translocation match is case-insensitive",
              loc("/private/var/folders/x/apptranslocation/UUID/d/ScrollWM.app") == .translocated)

        // MARK: - installed (stable homes; grant sticks)
        check("classify: ~/Applications -> installed",
              loc("/Users/tester/Applications/ScrollWM.app") == .installed)
        check("classify: /Applications -> installed",
              loc("/Applications/ScrollWM.app") == .installed)
        check("classify: /Applications/Utilities subfolder -> installed",
              loc("/Applications/Utilities/ScrollWM.app") == .installed)
        // APFS data-volume firmlink: /System/Volumes/Data/Applications == /Applications.
        check("classify: data-volume firmlink /Applications -> installed",
              loc("/System/Volumes/Data/Applications/ScrollWM.app") == .installed)
        check("classify: data-volume firmlink ~/Applications -> installed",
              loc("/System/Volumes/Data/Users/tester/Applications/ScrollWM.app",
                  home: "/System/Volumes/Data/Users/tester") == .installed)
        // Default APFS volume is case-insensitive: a lowercased path still installs.
        check("classify: case-insensitive /applications -> installed",
              loc("/applications/ScrollWM.app") == .installed)

        // MARK: - removableOrTemporary (transient homes; grant evaporates)
        check("classify: mounted .dmg (/Volumes) -> removableOrTemporary",
              loc("/Volumes/ScrollWM 0.2.0/ScrollWM.app") == .removableOrTemporary)
        check("classify: ~/Downloads -> removableOrTemporary",
              loc("/Users/tester/Downloads/ScrollWM.app") == .removableOrTemporary)
        check("classify: ~/Downloads nested subfolder -> removableOrTemporary",
              loc("/Users/tester/Downloads/scrollwm-0.2.0/ScrollWM.app") == .removableOrTemporary)
        check("classify: ~/Desktop -> removableOrTemporary",
              loc("/Users/tester/Desktop/ScrollWM.app") == .removableOrTemporary)
        // iCloud Drive (Mobile Documents) — incl. an iCloud-synced Desktop/Documents,
        // which can be evicted to a dataless stub at any time.
        check("classify: iCloud Drive (Mobile Documents) -> removableOrTemporary",
              loc("/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/ScrollWM.app")
                == .removableOrTemporary)
        check("classify: iCloud Drive Desktop -> removableOrTemporary",
              loc("/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/Desktop/ScrollWM.app")
                == .removableOrTemporary)
        // Temp extraction (unzip into a temp dir) with and without the /private firmlink.
        check("classify: /private/var/folders temp extraction -> removableOrTemporary",
              loc("/private/var/folders/aa/bb/T/ScrollWM.app") == .removableOrTemporary)
        check("classify: bare /var/folders temp extraction -> removableOrTemporary",
              loc("/var/folders/aa/bb/T/ScrollWM.app") == .removableOrTemporary)
        check("classify: /tmp extraction -> removableOrTemporary",
              loc("/tmp/ScrollWM.app") == .removableOrTemporary)
        check("classify: /private/tmp extraction -> removableOrTemporary",
              loc("/private/tmp/ScrollWM.app") == .removableOrTemporary)
        // The injected process temp dir is matched exactly (both firmlink forms).
        check("classify: injected NSTemporaryDirectory is temporary",
              AppLocation.classify(bundlePath: "/private/var/folders/zz/T/scrollwm/ScrollWM.app",
                                   isAppBundle: true, homeDir: home,
                                   temporaryDir: "/var/folders/zz/T/scrollwm/") == .removableOrTemporary)

        // MARK: - otherLocation (deliberate custom home; leave it be)
        check("classify: custom ~/dev dir -> otherLocation",
              loc("/Users/tester/dev/ScrollWM.app") == .otherLocation)
        check("classify: /opt custom dir -> otherLocation",
              loc("/opt/scrollwm/ScrollWM.app") == .otherLocation)
        // A SIBLING-prefixed path must NOT be mistaken for an install/Downloads.
        check("classify: /ApplicationsBackup is NOT installed",
              loc("/ApplicationsBackup/ScrollWM.app") == .otherLocation)
        check("classify: ~/DownloadsArchive is NOT a transient home",
              loc("/Users/tester/DownloadsArchive/ScrollWM.app") == .otherLocation)
        check("classify: /VolumesData is NOT a mounted volume",
              loc("/VolumesData/ScrollWM.app") == .otherLocation)

        // MARK: - normalization (trailing slash, symlinked/quirky home, case)
        check("classify: trailing slash on home is normalized",
              AppLocation.classify(bundlePath: "/Users/tester/Applications/ScrollWM.app",
                                   isAppBundle: true, homeDir: "/Users/tester/") == .installed)
        check("classify: trailing slash on bundle path is normalized",
              loc("/Applications/ScrollWM.app/") == .installed)
        check("classify: symlinked-style home still detects ~/Downloads",
              loc("/Users/tester/Downloads/ScrollWM.app", home: "/Users/tester///") == .removableOrTemporary)

        // MARK: - totality: every kind is reachable + classify never traps
        let everyKind: Set<AppLocation.Kind> = [
            loc("/x/WindowLab", app: false),                      // devBinary
            loc("/d/AppTranslocation/u/d/ScrollWM.app"),          // translocated
            loc("/Applications/ScrollWM.app"),                    // installed
            loc("/Volumes/D/ScrollWM.app"),                       // removableOrTemporary
            loc("/Users/tester/dev/ScrollWM.app"),                // otherLocation
        ]
        check("classify: all five Kinds are reachable", everyKind.count == 5)
        // Degenerate inputs must still classify without trapping.
        check("classify: empty bundle path is handled (otherLocation)",
              loc("") == .otherLocation)
        check("classify: root bundle path is handled",
              loc("/") == .otherLocation)
        check("classify: empty home does not crash",
              loc("/Applications/ScrollWM.app", home: "") == .installed)

        // MARK: - shouldOfferRelocation (only the broken/transient kinds)
        check("offer: translocated offers relocation",
              AppLocation.Kind.translocated.shouldOfferRelocation == true)
        check("offer: removableOrTemporary offers relocation",
              AppLocation.Kind.removableOrTemporary.shouldOfferRelocation == true)
        check("offer: installed does NOT offer relocation",
              AppLocation.Kind.installed.shouldOfferRelocation == false)
        check("offer: otherLocation does NOT offer relocation",
              AppLocation.Kind.otherLocation.shouldOfferRelocation == false)
        check("offer: devBinary does NOT offer relocation",
              AppLocation.Kind.devBinary.shouldOfferRelocation == false)

        // MARK: - destination + path helpers
        check("destination: ~/Applications/<name>",
              AppLocation.destination(forBundleNamed: "ScrollWM.app", homeDir: home)
                == "/Users/tester/Applications/ScrollWM.app")
        check("destination: trailing slash on home is normalized",
              AppLocation.destination(forBundleNamed: "ScrollWM.app", homeDir: "/Users/tester/")
                == "/Users/tester/Applications/ScrollWM.app")
        check("isUnder: treats the dir itself as inside",
              AppLocation.isUnder("/Applications", dir: "/Applications") == true)
        check("isUnder: matches nested paths",
              AppLocation.isUnder("/Applications/ScrollWM.app", dir: "/Applications") == true)
        check("isUnder: rejects sibling prefixes",
              AppLocation.isUnder("/ApplicationsX/ScrollWM.app", dir: "/Applications") == false)
        check("isUnder: is case-insensitive (default APFS)",
              AppLocation.isUnder("/APPLICATIONS/ScrollWM.app", dir: "/Applications") == true)
        check("isUnder: collapses the data-volume firmlink",
              AppLocation.isUnder("/System/Volumes/Data/Applications/ScrollWM.app", dir: "/Applications") == true)
        check("isUnder: trailing slashes on both sides normalize",
              AppLocation.isUnder("/Applications/", dir: "/Applications/") == true)
        check("isTemporary: /var/folders is temporary",
              AppLocation.isTemporary("/var/folders/x/y/ScrollWM.app", temporaryDir: "/var/folders/x/T/") == true)
        check("isTemporary: an install path is NOT temporary",
              AppLocation.isTemporary("/Applications/ScrollWM.app", temporaryDir: "/var/folders/x/T/") == false)

        // MARK: - AppRelocation.action (the relocate decision)
        // A stable/other/dev location never relocates regardless of destination.
        check("action: installed -> runInPlace",
              AppRelocation.action(kind: .installed, destinationExists: true,
                                   bundleIsDestination: true) == .runInPlace)
        check("action: otherLocation -> runInPlace",
              AppRelocation.action(kind: .otherLocation, destinationExists: false,
                                   bundleIsDestination: false) == .runInPlace)
        check("action: devBinary -> runInPlace",
              AppRelocation.action(kind: .devBinary, destinationExists: false,
                                   bundleIsDestination: false) == .runInPlace)
        // A transient/translocated launch with NO existing install -> offer move.
        check("action: translocated, no install -> offerMove",
              AppRelocation.action(kind: .translocated, destinationExists: false,
                                   bundleIsDestination: false) == .offerMove)
        check("action: removable, no install -> offerMove",
              AppRelocation.action(kind: .removableOrTemporary, destinationExists: false,
                                   bundleIsDestination: false) == .offerMove)
        // A DIFFERENT existing install -> surface it, never clobber it.
        check("action: transient + a different existing install -> surfaceExisting",
              AppRelocation.action(kind: .removableOrTemporary, destinationExists: true,
                                   bundleIsDestination: false) == .surfaceExisting)
        check("action: translocated + a different existing install -> surfaceExisting",
              AppRelocation.action(kind: .translocated, destinationExists: true,
                                   bundleIsDestination: false) == .surfaceExisting)
        // If WE are already the destination, never surface ourselves: offer move
        // (the copyBundle path then no-ops/atomically swaps in place).
        check("action: destination exists but it is US -> offerMove (no self-surface)",
              AppRelocation.action(kind: .removableOrTemporary, destinationExists: true,
                                   bundleIsDestination: true) == .offerMove)

        // MARK: - AppRelocation.shouldWarnRunInPlace
        // "Run Anyway" on a TRANSLOCATED copy must always warn (it is broken).
        check("warn: translocated run-in-place warns",
              AppRelocation.shouldWarnRunInPlace(kind: .translocated) == true)
        // A transient home at least works for this session -> no second modal.
        check("warn: removable run-in-place does NOT warn",
              AppRelocation.shouldWarnRunInPlace(kind: .removableOrTemporary) == false)
        check("warn: installed never warns",
              AppRelocation.shouldWarnRunInPlace(kind: .installed) == false)

        // MARK: - AppRelocation copy completeness / success gates
        check("copy: a bundle with plist + executable is plausible",
              AppRelocation.isPlausibleAppBundle(hasInfoPlist: true, hasExecutable: true) == true)
        check("copy: missing Info.plist is NOT plausible (partial copy)",
              AppRelocation.isPlausibleAppBundle(hasInfoPlist: false, hasExecutable: true) == false)
        check("copy: missing executable is NOT plausible (partial copy)",
              AppRelocation.isPlausibleAppBundle(hasInfoPlist: true, hasExecutable: false) == false)
        check("copy: empty staging dir is NOT plausible",
              AppRelocation.isPlausibleAppBundle(hasInfoPlist: false, hasExecutable: false) == false)
        // Success requires BOTH a clean ditto exit AND a plausible destination.
        check("success: clean exit + plausible bundle -> succeeded",
              AppRelocation.relocationSucceeded(copyExitedClean: true, destinationPlausible: true) == true)
        check("success: ditto failure -> NOT succeeded",
              AppRelocation.relocationSucceeded(copyExitedClean: false, destinationPlausible: true) == false)
        check("success: clean exit but incomplete bundle -> NOT succeeded",
              AppRelocation.relocationSucceeded(copyExitedClean: true, destinationPlausible: false) == false)

        // MARK: - AppRelocation.Copy (wording can't drift; tailored per kind)
        check("copy text: translocation rationale names App Translocation",
              AppRelocation.Copy.rationale(for: .translocated).contains("App Translocation"))
        check("copy text: removable rationale mentions a stable home",
              AppRelocation.Copy.rationale(for: .removableOrTemporary).contains("stable home"))
        check("copy text: non-offered kinds have an empty rationale",
              AppRelocation.Copy.rationale(for: .installed).isEmpty)
        check("copy text: confirm body always explains the one-time grant",
              AppRelocation.Copy.confirmInformative(for: .translocated).contains("only grant Accessibility once")
                && AppRelocation.Copy.confirmInformative(for: .removableOrTemporary).contains("only grant Accessibility once"))
        check("copy text: confirm body for a translocated launch includes its rationale",
              AppRelocation.Copy.confirmInformative(for: .translocated).contains("App Translocation"))
        check("copy text: warn body tells the user to drag into Applications",
              AppRelocation.Copy.warnBody.contains("Applications folder"))
        check("copy text: failure body surfaces the underlying error",
              AppRelocation.Copy.failureBody("disk full").contains("disk full"))
        check("copy text: buttons are stable",
              AppRelocation.Copy.moveButton == "Move to Applications"
                && AppRelocation.Copy.runAnywayButton == "Run Anyway")

        print("\n[apploctest] \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
